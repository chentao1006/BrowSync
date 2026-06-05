// AppState.swift
// BrowSync — Global observable state

import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    // Services
    let daemon = DaemonServer()
    let scanner = BrowserScanner()
    let syncService = SyncService()
    let settingsService = SettingsService()
    let notificationService = NotificationService()
    let backupService = BackupService()

    private var cancellables = Set<AnyCancellable>()
    
    var openWindowAction: ((String) -> Void)?

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
        syncService.settingsService = settingsService
        syncService.backupService = backupService
        
        isRouterEnabled = settingsService.routerSettings.isEnabled
        fallbackBrowserId = settingsService.routerSettings.fallbackBrowserId
        routerRules = settingsService.routerSettings.rules

        // Wire daemon delegate
        daemon.delegate = self
        
        settingsService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        
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
            if url.host == "open" {
                openWindowAction?("SettingsWindow")
            }
            // App is already brought to front by macOS, nothing else to do
            return
        }

        let urlString = url.absoluteString
        let sourceName = sourceAppBundleId ?? "unknown"

        guard isRouterEnabled else {
            openInDefaultFallback(url: url, sourceName: sourceName, reason: "Router disabled")
            return
        }
        
        for rule in routerRules {
            if rule.evaluate(url: url, sourceAppBundleId: sourceAppBundleId) {
                if let targetId = rule.targetBrowserId,
                   let targetAppURL = appURL(forBrowserId: targetId) {
                    syncService.log("🔀 Routed '\(urlString)' (from \(sourceName)) ➡️ \(targetId) (Rule Matched: '\(rule.name)')")
                    NSWorkspace.shared.open([url], withApplicationAt: targetAppURL, configuration: NSWorkspace.OpenConfiguration())
                    return
                } else if rule.targetBrowserId == nil {
                    openInDefaultFallback(url: url, sourceName: sourceName, reason: "Rule Matched: '\(rule.name)' (Action: Default Browser)")
                    return
                }
            }
        }
        
        // Fallback
        openInDefaultFallback(url: url, sourceName: sourceName, reason: "No rule matched")
    }
    
    private func openInDefaultFallback(url: URL, sourceName: String, reason: String) {
        let fallbackInfo: BrowserInfo?
        if let fallbackId = fallbackBrowserId {
            fallbackInfo = browserInfos.first(where: { $0.id.rawValue == fallbackId })
        } else {
            fallbackInfo = browserInfos.first(where: { $0.isDefault }) ?? browserInfos.first(where: { $0.browser == .safari })
        }
        
        let targetAppURL = fallbackInfo?.appURL
            ?? fallbackBrowserId.flatMap { appURL(forBrowserId: $0) }
            ?? browserInfos.first(where: { $0.isDefault })?.appURL
            ?? Browser.safari.appURL
            
        let targetName = fallbackInfo?.id.rawValue ?? fallbackBrowserId ?? "Default Browser"
        syncService.log("🔀 Routed '\(url.absoluteString)' (from \(sourceName)) ➡️ \(targetName) (\(reason))")
        
        if let appURL = targetAppURL {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func appURL(forBrowserId browserId: String) -> URL? {
        if let appURL = browserInfos.first(where: { $0.id.rawValue == browserId })?.appURL {
            return appURL
        }

        guard let browser = Browser(rawValue: browserId) else { return nil }
        return browser.appURL
    }

    // MARK: - Browser Refresh

    func refreshBrowsers() async {
        isScanning = true
        let infos = await scanner.scanAll()

        // Overlay connection status from daemon
        browserInfos = infos.map { info in
            var updated = info
            
            let lastConnectedKey = "extension_last_connected_\(info.browser.rawValue)"
            let wasInstalled = UserDefaults.standard.bool(forKey: "extension_installed_\(info.browser.rawValue)")
            
            if daemon.isConnected(browser: info.browser) {
                updated.extensionStatus = .connected
                UserDefaults.standard.set(true, forKey: "extension_installed_\(info.browser.rawValue)")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastConnectedKey)
            } else if wasInstalled {
                // UserDefaults records a successful past connection — trust this over the filesystem scan.
                // The scanner can miss the extension when the browser is closed (profile locked, etc.)
                let isRunning = !NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == info.browser.bundleIdentifier }.isEmpty
                
                if !isRunning {
                    updated.extensionStatus = .offline
                } else {
                    let lastConnected = UserDefaults.standard.double(forKey: lastConnectedKey)
                    // If it disconnected more than 10 seconds ago, it's effectively offline 
                    // (either the service worker went to sleep or the extension crashed/was disabled)
                    if Date().timeIntervalSince1970 - lastConnected < 10 {
                        updated.extensionStatus = .waitingConnection
                    } else {
                        updated.extensionStatus = .offline
                    }
                }
            } else if updated.extensionStatus == .waitingConnection {
                // Scanner found extension in filesystem but no prior connection record — keep it
                updated.extensionStatus = .waitingConnection
            }
            
            return updated
        }
        isScanning = false
    }

    func updateConnectionStatus(for browser: Browser, connected: Bool) {
        if let idx = browserInfos.firstIndex(where: { $0.browser == browser }) {
            let lastConnectedKey = "extension_last_connected_\(browser.rawValue)"
            
            if connected {
                browserInfos[idx].extensionStatus = .connected
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastConnectedKey)
            } else {
                browserInfos[idx].extensionStatus = .waitingConnection
                
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s grace period
                    await MainActor.run {
                        if let currentIdx = self.browserInfos.firstIndex(where: { $0.browser == browser }), 
                           self.browserInfos[currentIdx].extensionStatus != .connected {
                            self.browserInfos[currentIdx].extensionStatus = .offline
                        }
                    }
                }
            }
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
            
            // Safari extension does not support the WebExtension bookmarks API (it uses native sync instead)
            // so we should never push bookmarks to the Safari extension.
            if clientId.contains("safari") { return }
            
            // Do not push bookmarks back to the browser that is the source of truth
            if sourceBrowser == .chrome && clientId.contains("chrome") { return }
            
            var bookmarksToSend: [Bookmark]? = nil
            
            if sourceBrowser == .safari {
                let safariSvc = SafariBookmarkService()
                let safariBms = safariSvc.readBookmarks()
                if !safariBms.isEmpty {
                    bookmarksToSend = safariBms.map { b in
                        Bookmark(id: b.id, title: b.title, url: b.url, parentId: b.parentId, isFolder: b.isFolder, inBookmarksBar: b.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
                    }
                }
            } else {
                if let latestBackup = self.backupService.backups.first(where: { $0.sourceBrowser.starts(with: sourceBrowser.rawValue) }) {
                    bookmarksToSend = self.backupService.getBookmarks(for: latestBackup.id)
                }
            }
            
            guard let bookmarks = bookmarksToSend, !bookmarks.isEmpty else { return }
            
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
            let sourceName = sourceBrowser == .safari ? "Safari" : "Chrome"
            self.syncService.log("Answering pull request from [\(clientId)]: Pushed \(bookmarks.count) \(sourceName) bookmarks (isFullMirror: \(msg.isFullMirror ?? false))")
            server.send(msg, toClientId: clientId)
        }
    }
}
