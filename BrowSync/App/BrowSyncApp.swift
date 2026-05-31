// BrowSyncApp.swift
// BrowSync — App entry point

import SwiftUI
import AppKit

@main
struct BrowSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 700, minHeight: 500)
        }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create data directories
        createAppDirectories()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let appState else { return }
        for url in urls {
            appState.defaultBrowserHandler.handle(url: url, sourceAppBundleId: nil)
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
        VStack(alignment: .leading, spacing: 4) {
            Text("BrowSync")
                .font(.headline)
                .padding(.bottom, 4)

            Divider()

            // Connection status
            ForEach(appState.browserInfos) { info in
                HStack {
                    Image(systemName: info.extensionStatus == .connected ? "circle.fill" : "circle")
                        .foregroundStyle(info.extensionStatus == .connected ? Color.green : Color.secondary)
                        .font(.caption)
                    Text(info.displayName)
                        .font(.body)
                    Spacer()
                    Text(info.extensionStatus.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button(String(localized: "Sync Now")) {
                Task { await appState.syncAll() }
            }

            Button(String(localized: "Open BrowSync")) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }

            Divider()

            Button(String(localized: "Quit")) {
                NSApp.terminate(nil)
            }
        }
        .padding(8)
        .frame(width: 260)
    }
}
