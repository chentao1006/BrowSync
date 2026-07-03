// BrowSyncApp.swift
// BrowSync — App entry point

import SwiftUI
import AppKit
#if !APP_STORE
import Sparkle
#endif

@main
struct BrowSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var langBundle = LanguageBundle(language: .system)

    init() {
        AnalyticsManager.shared.initialize()
    }

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

        Window("BrowSync", id: "SettingsWindow") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(langBundle)
                .environment(\.locale, currentLocale)
                .frame(width: 750, height: 600)
                .onAppear {
                    appDelegate.settingsWindowDidAppear()
                    langBundle.apply(language: appState.settingsService.general.language)
                }
                .onChange(of: appState.settingsService.general.language) { newLang in
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
    static private(set) var shared: AppDelegate!
    
    var appState: AppState { AppState.shared }
#if !APP_STORE
    let updaterController: SPUStandardUpdaterController
#endif
    private var shouldShowSettingsWindow = false
    private var pendingURLRequests: [(url: URL, sourceAppBundleId: String?)] = []
    private var lastActiveAppBundleId: String?

    override init() {
#if !APP_STORE
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
#endif
        super.init()
        AppDelegate.shared = self
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
        
#if !APP_STORE
        // Sparkle Auto Update
        updaterController.updater.automaticallyChecksForUpdates = settingsService.general.autoUpdate
#endif
        
        if settingsService.general.firstLaunchDate == nil {
            settingsService.general.firstLaunchDate = Date()
            settingsService.save()
        }
    }
    
    private func promptForAnalyticsOptIn() {
        // Double check in case it was toggled
        let settingsService = SettingsService()
        guard !settingsService.general.analyticsOptInPrompted else { return }
        
        let alert = NSAlert()
        alert.messageText = String(localized: "Help Improve BrowSync", bundle: LanguageBundle.systemBundle)
        alert.informativeText = String(localized: "Would you like to send anonymous usage statistics to help us improve BrowSync? You can change this later in the About tab.", bundle: LanguageBundle.systemBundle)
        alert.addButton(withTitle: String(localized: "Yes, share anonymously", bundle: LanguageBundle.systemBundle))
        alert.addButton(withTitle: String(localized: "No, thanks", bundle: LanguageBundle.systemBundle))
        
        NSApp.activate(ignoringOtherApps: true)
        
        // If there's a window, show as sheet, else show as modal
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            alert.beginSheetModal(for: window) { response in
                settingsService.general.analyticsEnabled = (response == .alertFirstButtonReturn)
                settingsService.general.analyticsOptInPrompted = true
                settingsService.save()
                if settingsService.general.analyticsEnabled {
                    AnalyticsManager.shared.trackEvent("Analytics Enabled")
                }
            }
        } else {
            let response = alert.runModal()
            settingsService.general.analyticsEnabled = (response == .alertFirstButtonReturn)
            settingsService.general.analyticsOptInPrompted = true
            settingsService.save()
            if settingsService.general.analyticsEnabled {
                AnalyticsManager.shared.trackEvent("Analytics Enabled")
            }
        }
    }

    func settingsWindowDidAppear() {
        shouldShowSettingsWindow = false
        flushPendingURLRequests()
        updateDockIconForVisibleWindows()
        
        let settingsService = SettingsService()
        if !settingsService.general.analyticsOptInPrompted {
            let firstLaunch = settingsService.general.firstLaunchDate ?? Date()
            let timeSinceLaunch = Date().timeIntervalSince(firstLaunch)
            
            if timeSinceLaunch >= 120 {
                // 已经超过 2 分钟，直接在当前窗口弹出（加 0.5 秒动画缓冲）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if self.hasVisibleSettingsWindow() && !settingsService.general.analyticsOptInPrompted {
                        self.promptForAnalyticsOptIn()
                    }
                }
            } else {
                // 还没到 2 分钟，等待剩下的时间。如果时间到了窗口还开着，就弹出。
                let remaining = 120 - timeSinceLaunch
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                    let currentSettings = SettingsService()
                    if self.hasVisibleSettingsWindow() && !currentSettings.general.analyticsOptInPrompted {
                        self.promptForAnalyticsOptIn()
                    }
                }
            }
        }
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
        NSApp.setActivationPolicy(.regular)
    }

    func hideDockIcon() {
        NSApp.setActivationPolicy(.accessory)
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

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            hideDockIconIfNoVisibleMainWindow()
            let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
            processURL(url, sourceAppBundleId: source)
        }
    }
    
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        if userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL {
            hideDockIconIfNoVisibleMainWindow()
            processURL(url, sourceAppBundleId: "Handoff")
            return true
        }
        return false
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if !showExistingSettingsWindowIfPossible() {
                if let url = URL(string: "browsync://open") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        return true
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
        let appName = Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? "BrowSync"
        
        Text(appName)
            .font(.headline)
            .disabled(true)
        
        Divider()
        
        Menu(String(localized: "Sync Now", bundle: langBundle.bundle)) {
            Button(String(localized: "Sync All", bundle: langBundle.bundle)) {
                AnalyticsManager.shared.trackEvent("Menu Action", props: ["action": "Sync All"])
                Task { await appState.syncAll() }
            }
            Button(String(localized: "Sync Bookmarks", bundle: langBundle.bundle)) {
                AnalyticsManager.shared.trackEvent("Menu Action", props: ["action": "Sync Bookmarks"])
                Task { await appState.sync(categories: [.bookmarks]) }
            }
            Button(String(localized: "Sync State", bundle: langBundle.bundle)) {
                AnalyticsManager.shared.trackEvent("Menu Action", props: ["action": "Sync State"])
                Task { await appState.sync(categories: [.browserState, .browserData, .localStorage, .history]) }
            }
        }
        
        Divider()

        // Installed Browsers Section
        ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
            Menu {
                Button(String(localized: "Open \(info.displayName)", bundle: langBundle.bundle)) {
                    AnalyticsManager.shared.trackEvent("Menu Action", props: ["action": "Open Browser", "browser": info.id.rawValue])
                    if let appURL = info.appURL {
                        NSWorkspace.shared.open(appURL)
                    }
                }
                
                Divider()
                
                let isRouterDefault = appState.fallbackBrowserId == info.id.rawValue
                let isBookmarkSync = appState.settingsService.syncSettings.bookmarkParticipatingBrowsers.contains(info.id)
                let isStateSync = appState.settingsService.syncSettings.stateParticipatingBrowsers.contains(info.id)
                
                Button {
                    appState.fallbackBrowserId = info.id.rawValue
                } label: {
                    if isRouterDefault {
                        Text(String(localized: "Set as Default", bundle: langBundle.bundle) + " ✓")
                    } else {
                        Text(String(localized: "Set as Default", bundle: langBundle.bundle))
                    }
                }
                .disabled(isRouterDefault)
                
                Button {
                    if isBookmarkSync {
                        appState.settingsService.syncSettings.bookmarkParticipatingBrowsers.remove(info.id)
                    } else {
                        appState.settingsService.syncSettings.bookmarkParticipatingBrowsers.insert(info.id)
                    }
                    appState.settingsService.save()
                    appState.broadcastSettings()
                } label: {
                    if isBookmarkSync {
                        Text(String(localized: "Turn off Bookmark Sync", bundle: langBundle.bundle))
                    } else {
                        Text(String(localized: "Turn on Bookmark Sync", bundle: langBundle.bundle))
                    }
                }
                
                Button {
                    if isStateSync {
                        appState.settingsService.syncSettings.stateParticipatingBrowsers.remove(info.id)
                    } else {
                        appState.settingsService.syncSettings.stateParticipatingBrowsers.insert(info.id)
                    }
                    appState.settingsService.save()
                    appState.broadcastSettings()
                } label: {
                    if isStateSync {
                        Text(String(localized: "Turn off State Sync", bundle: langBundle.bundle))
                    } else {
                        Text(String(localized: "Turn on State Sync", bundle: langBundle.bundle))
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
        Button(String(localized: "Settings...", bundle: langBundle.bundle)) {
            if (NSApp.delegate as? AppDelegate)?.showExistingSettingsWindowIfPossible() != true {
                (NSApp.delegate as? AppDelegate)?.prepareToOpenSettingsWindow()
                openWindow(id: "SettingsWindow")
            }
            NSApp.activate(ignoringOtherApps: true)
        }

#if !APP_STORE
        Button(String(localized: "Check for Updates...", bundle: langBundle.bundle)) {
            NSApp.activate(ignoringOtherApps: true)
            AppDelegate.shared.updaterController.checkForUpdates(nil)
        }
#endif

        Divider()

        Button(String(localized: "Quit", bundle: langBundle.bundle)) {
            NSApp.terminate(nil)
        }
    }
}
