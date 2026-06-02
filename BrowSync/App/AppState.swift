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
    let backupService = BackupService()

    // Published state
    @Published var browserInfos: [BrowserInfo] = Browser.allCases.map { .placeholder(for: $0) }
    @Published var isScanning: Bool = false

    // Active domain mock fields
    @Published var activeDomain: String? = "github.com"
    @Published var activeDomainSyncEnabled: Bool = true
    @Published var activeDomainStrategy: String = "Merge"

    // Router state
    @Published var isRouterEnabled: Bool = true {
        didSet {
            settingsService.routerSettings.isEnabled = isRouterEnabled
            settingsService.save()
        }
    }
    @Published var routerRules: [RouterRule] = [] {
        didSet {
            settingsService.routerSettings.rules = routerRules
            settingsService.save()
        }
    }
    @Published var fallbackBrowserId: String? = nil {
        didSet {
            settingsService.routerSettings.fallbackBrowserId = fallbackBrowserId
            settingsService.save()
        }
    }
    @Published var isDefaultBrowser: Bool = false
    @Published var hasFullDiskAccess: Bool = false

    init() {
        // Wire up services
        syncService.daemon = daemon
        syncService.settings = settingsService.syncSettings
        syncService.backupService = backupService
        
        isRouterEnabled = settingsService.routerSettings.isEnabled
        fallbackBrowserId = settingsService.routerSettings.fallbackBrowserId
        routerRules = settingsService.routerSettings.rules

        // Wire daemon delegate
        daemon.delegate = self as? DaemonServerDelegate  // Set in BrowSyncApp
        
        checkFullDiskAccess()
    }
    
    func checkFullDiskAccess() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
        hasFullDiskAccess = FileManager.default.isReadableFile(atPath: url.path)
    }

    // MARK: - Startup

    func onAppear() async {
        // Request notification permissions
        await notificationService.requestPermission()

        // Start daemon
        daemon.start()

        // Initial browser scan
        await refreshBrowsers()
        
        // Check default browser status
        checkDefaultBrowser()
    }

    // MARK: - Router & URL Handling
    
    func checkDefaultBrowser() {
        if let defaultURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "http://apple.com")!) {
            isDefaultBrowser = defaultURL.lastPathComponent == "BrowSync.app" || defaultURL.absoluteString.contains("BrowSync")
        }
    }
    
    func promptSetDefaultBrowser() {
        guard let appURL = Bundle.main.bundleURL as URL? else { return }
        
        if #available(macOS 12.0, *) {
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http") { error in
                if let error = error {
                    print("Failed to set default for http: \(error)")
                }
            }
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "https") { error in
                if let error = error {
                    print("Failed to set default for https: \(error)")
                }
                Task { @MainActor in self.checkDefaultBrowser() }
            }
        } else {
            if let prefURL = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings") {
                NSWorkspace.shared.open(prefURL)
            }
        }
    }
    
    func handleIncomingURL(_ url: URL, sourceAppBundleId: String?) {
        if url.scheme == "browsync" {
            // App is already brought to front by macOS, nothing else to do
            return
        }

        guard isRouterEnabled else {
            openInDefaultFallback(url: url)
            return
        }
        
        for rule in routerRules {
            if rule.evaluate(url: url, sourceAppBundleId: sourceAppBundleId) {
                if let targetId = rule.targetBrowserId,
                   let targetInfo = browserInfos.first(where: { $0.id.rawValue == targetId }),
                   let targetAppURL = targetInfo.appURL {
                    NSWorkspace.shared.open([url], withApplicationAt: targetAppURL, configuration: NSWorkspace.OpenConfiguration())
                    return
                }
            }
        }
        
        // Fallback
        openInDefaultFallback(url: url)
    }
    
    private func openInDefaultFallback(url: URL) {
        let fallbackInfo: BrowserInfo?
        if let fallbackId = fallbackBrowserId {
            fallbackInfo = browserInfos.first(where: { $0.id.rawValue == fallbackId })
        } else {
            fallbackInfo = browserInfos.first(where: { $0.isDefault }) ?? browserInfos.first(where: { $0.browser == .safari })
        }
        
        let targetAppURL = fallbackInfo?.appURL ?? browserInfos.first(where: { $0.isDefault })?.appURL
        if let appURL = targetAppURL {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Browser Refresh

    func refreshBrowsers() async {
        isScanning = true
        let infos = await scanner.scanAll()

        // Overlay connection status from daemon
        browserInfos = infos.map { info in
            var updated = info
            
            let lastConnectedKey = "extension_last_connected_\(info.browser.rawValue)"
            
            if daemon.isConnected(browser: info.browser) {
                updated.extensionStatus = .connected
                UserDefaults.standard.set(true, forKey: "extension_installed_\(info.browser.rawValue)")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastConnectedKey)
            } else if UserDefaults.standard.bool(forKey: "extension_installed_\(info.browser.rawValue)") {
                let isRunning = !NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == info.browser.bundleIdentifier }.isEmpty
                
                if !isRunning {
                    updated.extensionStatus = .offline
                } else if updated.extensionStatus == .extensionRequired || updated.extensionStatus == .notInstalled {
                    updated.extensionStatus = .waitingConnection
                }
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

    // MARK: - Sync

    func syncAll() async {
        await sync(categories: nil)
    }

    func sync(categories: Set<SyncCategory>?) async {
        await syncService.syncNow(categories: categories)
        if settingsService.general.notifySyncComplete {
            let enabled = Array(categories ?? settingsService.syncSettings.enabledCategories)
            notificationService.notifySyncComplete(categories: enabled)
        }
    }
}


// MARK: - DaemonServerDelegate

extension AppState: DaemonServerDelegate {
    nonisolated func daemonServer(_ server: DaemonServer, didConnect client: ConnectedClient) {
        Task { @MainActor in
            self.updateConnectionStatus(for: client.browser, connected: true)
        }
    }

    nonisolated func daemonServer(_ server: DaemonServer, didDisconnect clientId: String, browser: Browser) {
        Task { @MainActor in
            if !server.isConnected(browser: browser) {
                self.updateConnectionStatus(for: browser, connected: false)
            }
        }
    }

    nonisolated func daemonServer(_ server: DaemonServer, didReceiveSync message: WSMessage, from clientId: String) {
        Task { @MainActor in
            self.syncService.receive(message: message, from: clientId)
        }
    }
    
    nonisolated func daemonServer(_ server: DaemonServer, didReceivePullBookmarks clientId: String) {
        Task { @MainActor in
            let strategy = self.settingsService.syncSettings.bookmarkSyncStrategy
            let sourceBrowser = self.settingsService.syncSettings.bookmarkSourceBrowser
            // Only respond if Safari is the source (or twoWayMerge)
            guard strategy == .twoWayMerge || (strategy == .oneWay && sourceBrowser == .safari) else { return }
            let safariSvc = SafariBookmarkService()
            let safariBms = safariSvc.readBookmarks()
            guard !safariBms.isEmpty else { return }
            let bookmarks = safariBms.map { b in
                Bookmark(id: b.id, title: b.title, url: b.url, parentId: b.parentId, isFolder: b.isFolder, inBookmarksBar: b.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
            }
            var msg = WSMessage(
                type: .sync,
                site: "*",
                category: "bookmarks",
                payload: .bookmarks(bookmarks),
                messageId: UUID().uuidString,
                timestamp: Date().timeIntervalSince1970
            )
            msg.isFullMirror = (strategy == .oneWay)
            // Only send to the requesting client
            server.send(msg, toClientId: clientId)
        }
    }
}
