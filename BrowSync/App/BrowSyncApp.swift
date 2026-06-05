// BrowSyncApp.swift
// BrowSync — App entry point

import SwiftUI
import AppKit
import Sparkle

@main
struct BrowSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var langBundle = LanguageBundle(language: .system)

    var body: some Scene {
        // Menu Bar Extra (macOS 13+)
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(langBundle)
                .environment(\.locale, currentLocale)
        } label: {
            MenuBarLabelView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("BrowSync", id: "SettingsWindow") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(langBundle)
                .environment(\.locale, currentLocale)
                .frame(width: 750, height: 600)
                .onAppear {
                    appDelegate.settingsWindowDidAppear()
                    langBundle.apply(language: appState.settingsService.general.language)
                }
                .onChange(of: appState.settingsService.general.language) { _, newLang in
                    langBundle.apply(language: newLang)
                }
        }
        .handlesExternalEvents(matching: ["browsync"])
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    private var currentLocale: Locale {
        let lang = appState.settingsService.general.language
        if lang == .system {
            return Locale(identifier: Locale.preferredLanguages.first ?? "en")
        } else {
            return Locale(identifier: lang.rawValue)
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState { AppState.shared }
    let updaterController: SPUStandardUpdaterController
    private var shouldShowSettingsWindow = false
    private var pendingURLRequests: [(url: URL, sourceAppBundleId: String?)] = []
    private var lastActiveAppBundleId: String?

    override init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register for Apple Events to handle HTTP/HTTPS URLs BEFORE applicationDidFinishLaunching
        // Otherwise the initial URL that launched the app will be dropped
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))

        if SettingsService().general.hideWindowOnStartup {
            hideDockIcon()
            NSApp.hide(nil) // Hide the entire app immediately to prevent the main window from flashing
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create data directories
        createAppDirectories()
        
        Task {
            await appState.onAppear()
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsWindowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        
        // Track the last active application to reliably identify the source app even during URL routing focus jumps
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                self?.lastActiveAppBundleId = app.bundleIdentifier
            }
        }
        
        let settingsService = SettingsService()
        if settingsService.general.hideWindowOnStartup {
            hideDockIcon()
        } else {
            showDockIcon()
            if !hasVisibleSettingsWindow() {
                if let url = URL(string: "browsync://open") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    func settingsWindowDidAppear() {
        shouldShowSettingsWindow = false
        flushPendingURLRequests()
        updateDockIconForVisibleWindows()
    }

    func prepareToOpenSettingsWindow() {
        shouldShowSettingsWindow = true
        showDockIcon()
    }

    func showExistingSettingsWindowIfPossible() -> Bool {
        guard let window = settingsWindow else { return false }

        shouldShowSettingsWindow = true
        showDockIcon()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func showDockIcon() {
        // Disabled to prevent SwiftUI MenuBarExtra freezing bug on macOS
    }

    func hideDockIcon() {
        // Disabled to prevent SwiftUI MenuBarExtra freezing bug on macOS
    }

    @objc private func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateDockIconForVisibleWindows()
        }
    }

    @objc private func settingsWindowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isSettingsWindow(window)
        else { return }
        showDockIcon()
    }

    private var settingsWindow: NSWindow? {
        NSApp.windows.first(where: isSettingsWindow)
    }

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.canBecomeMain && window.title == "BrowSync"
    }

    private func hasVisibleSettingsWindow() -> Bool {
        NSApp.windows.contains { window in
            isSettingsWindow(window) && window.isVisible && !window.isMiniaturized
        }
    }

    private func updateDockIconForVisibleWindows() {
        if hasVisibleSettingsWindow() {
            showDockIcon()
        } else {
            hideDockIcon()
        }
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }

        hideDockIconIfNoVisibleMainWindow()
        
        let sourceAppBundleId = sourceBundleIdentifier(from: event)
        processURL(url, sourceAppBundleId: sourceAppBundleId)
    }
    
    private func processURL(_ url: URL, sourceAppBundleId: String?) {
        appState.handleIncomingURL(url, sourceAppBundleId: sourceAppBundleId)
        hideDockIconIfNoVisibleMainWindow()
    }

    private func flushPendingURLRequests() {
        guard !pendingURLRequests.isEmpty else { return }
        let requests = pendingURLRequests
        pendingURLRequests.removeAll()

        for request in requests {
            appState.handleIncomingURL(request.url, sourceAppBundleId: request.sourceAppBundleId)
        }
        hideDockIconIfNoVisibleMainWindow()
    }

    private func hideDockIconIfNoVisibleMainWindow() {
        if !hasVisibleSettingsWindow() {
            hideDockIcon()
        }
    }

    private func sourceBundleIdentifier(from event: NSAppleEventDescriptor) -> String? {
        let selfBundleId = Bundle.main.bundleIdentifier
        
        // Attempt 1: Extract the true sender PID directly from the Apple Event (macOS 10.15+)
        if let pidDescriptor = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr)) {
            let pid = pid_t(pidDescriptor.int32Value)
            if let app = NSRunningApplication(processIdentifier: pid),
               let bundleId = app.bundleIdentifier,
               bundleId != selfBundleId,
               !bundleId.contains("com.apple.coreservices") {
                return bundleId
            }
        }
        
        let attributeKeys: [AEKeyword] = [keyOriginalAddressAttr, keyAddressAttr]

        for key in attributeKeys {
            guard let address = event.attributeDescriptor(forKeyword: key),
                  let bundleId = bundleIdentifier(fromAddressDescriptor: address),
                  bundleId != selfBundleId
            else { continue }
            return bundleId
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != selfBundleId {
            return frontmost.bundleIdentifier
        }

        if #available(macOS 13.0, *) {
            if let menuBarApp = NSWorkspace.shared.menuBarOwningApplication,
               menuBarApp.bundleIdentifier != selfBundleId {
                return menuBarApp.bundleIdentifier
            }
        }

        for app in NSWorkspace.shared.runningApplications {
            if app.isActive && app.bundleIdentifier != selfBundleId {
                return app.bundleIdentifier
            }
        }
        
        if let lastActive = lastActiveAppBundleId {
            return lastActive
        }

        return nil
    }

    private func bundleIdentifier(fromAddressDescriptor descriptor: NSAppleEventDescriptor) -> String? {
        if descriptor.descriptorType == typeApplicationBundleID,
           let bundleId = descriptor.stringValue {
            return bundleId
        }

        if let bundleDescriptor = descriptor.coerce(toDescriptorType: typeApplicationBundleID),
           let bundleId = bundleDescriptor.stringValue {
            return bundleId
        }

        if let pidDescriptor = descriptor.coerce(toDescriptorType: typeKernelProcessID) {
            let pid = pid_t(pidDescriptor.int32Value)
            if pid > 0 {
                return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            }
        }

        return nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running as menu bar app
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return !SettingsService().general.hideWindowOnStartup
    }

    private func createAppDirectories() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dirs = [
            "BrowSync",
            "BrowSync/sites",
            "BrowSync/bookmarks",
            "BrowSync/logs",
        ]
        for dir in dirs {
            let url = appSupport.appendingPathComponent(dir)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

struct MenuBarLabelView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var appState: AppState

    var body: some View {
        Image("MenuBarIcon")
            .onAppear {
                appState.openWindowAction = { id in
                    openWindow(id: id)
                }
            }
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var langBundle: LanguageBundle
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(String(localized: "Open BrowSync", bundle: langBundle.bundle)) {
            if (NSApp.delegate as? AppDelegate)?.showExistingSettingsWindowIfPossible() != true {
                (NSApp.delegate as? AppDelegate)?.prepareToOpenSettingsWindow()
                openWindow(id: "SettingsWindow")
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        
        Menu(String(localized: "Sync Now", bundle: langBundle.bundle)) {
            Button(String(localized: "Sync All", bundle: langBundle.bundle)) {
                Task { await appState.syncAll() }
            }
            Button(String(localized: "Sync State", bundle: langBundle.bundle)) {
                Task { await appState.sync(categories: [.browserState, .browserData, .localStorage, .history]) }
            }
            Button(String(localized: "Sync Bookmarks", bundle: langBundle.bundle)) {
                Task { await appState.sync(categories: [.bookmarks]) }
            }
        }
        
        Divider()

        // Installed Browsers Section
        ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
            Menu {
                Button(String(localized: "Open \(info.displayName)", bundle: langBundle.bundle)) {
                    if let appURL = info.appURL {
                        NSWorkspace.shared.open(appURL)
                    }
                }
            } label: {
                Label {
                    Text("\(info.displayName)\(info.isDefault ? " (" + String(localized: "Default", bundle: langBundle.bundle) + ")" : "") • \(info.extensionStatus.displayName)")
                } icon: {
                    if let appURL = info.appURL {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    } else {
                        Image(systemName: info.id.sfSymbol)
                    }
                }
            }
        }

        Divider()


        // Actions Section

        Button(String(localized: "Check for Updates...", bundle: langBundle.bundle)) {
            (NSApp.delegate as? AppDelegate)?.updaterController.checkForUpdates(nil)
        }

        Divider()

        Button(String(localized: "Quit", bundle: langBundle.bundle)) {
            NSApp.terminate(nil)
        }
    }
}
