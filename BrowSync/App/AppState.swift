// AppState.swift
// BrowSync — Global observable state

import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    // Services
    let daemon = DaemonServer()
    let scanner = BrowserScanner()
    let syncService = SyncService()
    let settingsService = SettingsService()
    let notificationService = NotificationService()
    let focusManager = FocusManager()
    let defaultBrowserHandler = DefaultBrowserHandler()
    let browserLauncher = BrowserLauncher()

    // Computed
    let rulesEngine = RulesEngine()

    // Published state
    @Published var browserInfos: [BrowserInfo] = Browser.allCases.map { .placeholder(for: $0) }
    @Published var isScanning: Bool = false

    init() {
        // Wire up services
        syncService.daemon = daemon
        syncService.settings = settingsService.syncSettings
        defaultBrowserHandler.rulesEngine = rulesEngine

        // Wire daemon delegate
        daemon.delegate = self as? DaemonServerDelegate  // Set in BrowSyncApp
    }

    // MARK: - Startup

    func onAppear() async {
        // Request notification permissions
        await notificationService.requestPermission()

        // Start daemon if enabled
        if settingsService.general.startBackgroundService {
            daemon.start()
        }

        // Initial browser scan
        await refreshBrowsers()
    }

    // MARK: - Browser Refresh

    func refreshBrowsers() async {
        isScanning = true
        let infos = await scanner.scanAll()

        // Overlay connection status from daemon
        browserInfos = infos.map { info in
            var updated = info
            if daemon.isConnected(browser: info.browser) {
                updated.extensionStatus = .connected
            }
            return updated
        }
        isScanning = false
    }

    func updateConnectionStatus(for browser: Browser, connected: Bool) {
        if let idx = browserInfos.firstIndex(where: { $0.browser == browser }) {
            browserInfos[idx].extensionStatus = connected ? .connected : .waitingConnection
        }
    }

    // MARK: - Rules

    var rules: [BrowserRule] {
        get { settingsService.rules }
        set {
            settingsService.rules = newValue
            rulesEngine.rules = newValue
            rulesEngine.defaultBrowser = settingsService.syncSettings.primaryBrowser
        }
    }

    func syncAll() async {
        await syncService.syncNow()
        if settingsService.general.notifySyncComplete {
            let enabled = Array(settingsService.syncSettings.enabledCategories)
            notificationService.notifySyncComplete(categories: enabled)
        }
    }
}


// MARK: - DaemonServerDelegate

extension AppState: DaemonServerDelegate {
    func daemonServer(_ server: DaemonServer, didConnect client: ConnectedClient) {
        Task { @MainActor in
            self.updateConnectionStatus(for: client.browser, connected: true)
        }
    }

    func daemonServer(_ server: DaemonServer, didDisconnect clientId: String, browser: Browser) {
        Task { @MainActor in
            if !server.isConnected(browser: browser) {
                self.updateConnectionStatus(for: browser, connected: false)
            }
        }
    }

    func daemonServer(_ server: DaemonServer, didReceiveSync message: WSMessage, from clientId: String) {
        Task { @MainActor in
            self.syncService.receive(message: message, from: clientId)
        }
    }
}
