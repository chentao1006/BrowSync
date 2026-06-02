// BrowSyncApp.swift
// BrowSync — App entry point

import SwiftUI
import AppKit
import Sparkle

@main
struct BrowSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup(id: "SettingsWindow") {
            ContentView()
                .environmentObject(appState)
                .frame(width: 750, height: 600)
                .onAppear {
                    appDelegate.appState = appState
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Menu Bar Extra (macOS 13+)
        MenuBarExtra("BrowSync", systemImage: "arrow.triangle.2.circlepath.circle.fill") {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    let updaterController: SPUStandardUpdaterController

    override init() {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create data directories
        createAppDirectories()
        
        // Register for Apple Events to handle HTTP/HTTPS URLs
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        
        let settingsService = SettingsService()
        if settingsService.general.hideWindowOnStartup {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                NSApp.windows.first?.close()
            }
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }

        // Attempt to extract source application bundle ID
        var sourceAppBundleId: String? = nil
        
        // keyAESourceProcessName / keyEventSourceApplicationBundleID equivalent workaround since some are private
        // Usually, the easiest way is to ask NSWorkspace for frontmost app, though imperfect
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            if frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
                sourceAppBundleId = frontmost.bundleIdentifier
            }
        }
        
        // Also check Address descriptor if present
        if let addrDesc = event.attributeDescriptor(forKeyword: keyAddressAttr) {
            // Not straightforward to extract bundle ID from address descriptor without private APIs
            // So we rely on frontmostApplication or similar
        }

        Task { @MainActor in
            appState?.handleIncomingURL(url, sourceAppBundleId: sourceAppBundleId)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running as menu bar app
    }

    private func createAppDirectories() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dirs = [
            "BrowSync",
            "BrowSync/sites",
            "BrowSync/bookmarks",
            "BrowSync/history",
            "BrowSync/logs",
        ]
        for dir in dirs {
            let url = appSupport.appendingPathComponent(dir)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        // Installed Browsers Section
        ForEach(appState.browserInfos.filter { $0.isInstalled }) { info in
            Menu {
                Button(String(localized: "设为默认")) {
                    // Placeholder for set default
                    print("Set default: \(info.displayName)")
                }
                .disabled(info.isDefault)

                Button(String(localized: "打开 \(info.displayName)")) {
                    if let appURL = info.appURL {
                        NSWorkspace.shared.open(appURL)
                    }
                }
            } label: {
                Label {
                    Text("\(info.displayName)\(info.isDefault ? " (默认)" : "") • \(info.extensionStatus.displayName)")
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

        // Current Domain Section
        if let domain = appState.activeDomain {
            Menu {
                Button("添加到网站名单") {
                    let newSetting = WebsiteSyncSetting(domain: domain, strategy: nil)
                    if !appState.settingsService.syncSettings.websiteSettings.contains(where: { $0.domain == domain }) {
                        appState.objectWillChange.send()
                        appState.settingsService.syncSettings.websiteSettings.append(newSetting)
                        appState.settingsService.save()
                    }
                }
            } label: {
                Text("当前网站 \(domain)")
            }

            Divider()
        }

        // Actions Section
        Button(String(localized: "立即同步")) {
            Task { await appState.syncAll() }
        }

        Button(String(localized: "设置")) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }

        Button(String(localized: "检查更新...")) {
            (NSApp.delegate as? AppDelegate)?.updaterController.checkForUpdates(nil)
        }

        Divider()

        Button(String(localized: "退出")) {
            NSApp.terminate(nil)
        }
    }
}
