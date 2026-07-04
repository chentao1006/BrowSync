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
    let iCloudSyncManager = ICloudSyncManager()
    let purchaseService = PurchaseService()

    private var cancellables = Set<AnyCancellable>()
    
    var openWindowAction: ((String) -> Void)?

    // Published state
    @Published var browserInfos: [BrowserInfo] = Browser.allCases.map { .placeholder(for: $0) }
    @Published var isScanning: Bool = false

    // Active domain mock fields
    @Published var activeDomain: String? = "github.com"
    @Published var activeDomainSyncEnabled: Bool = true
    @Published var activeDomainStrategy: String = "Merge"

    // Tab Sharing state
    @Published var remoteTabsCache: [Browser: [BrowserTab]] = [:] {
        didSet {
            iCloudSyncManager.uploadTabs(remoteTabsCache)
        }
    }


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
            broadcastSettings()
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

            
        iCloudSyncManager.setup(settingsService: settingsService)
        purchaseService.start()
        
        checkFullDiskAccess()
    }
    
    func checkFullDiskAccess() {
#if APP_STORE
        hasFullDiskAccess = false
#else
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
        hasFullDiskAccess = FileManager.default.isReadableFile(atPath: url.path)
#endif
    }

    // MARK: - Startup

    func onAppear() async {
        // Start daemon
        daemon.start()

        // Initial browser scan
        await refreshBrowsers()
        
        // Check default browser status
        checkDefaultBrowser()
        
        // Fetch remote disabled domains
        Task {
            await fetchDisabledDomains()
        }
    }
    
    private func fetchDisabledDomains() async {
        guard let url = URL(string: "https://browsync.ct106.com/disabled-domains.json") else { return }
        do {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
            let (data, _) = try await URLSession.shared.data(for: request)
            if let domains = try? JSONDecoder().decode([String].self, from: data), !domains.isEmpty {
                WebsiteSyncSetting.syncDisabledDomains = domains
                self.broadcastSettings()
            }
        } catch {
            print("Failed to fetch disabled domains: \(error)")
        }
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
        
        let rulesToEvaluate = purchaseService.isProUnlocked ? routerRules : Array(routerRules.prefix(ProLimits.freeRouterRuleCount))
        for rule in rulesToEvaluate {
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
        let allBrowsers = Browser.standardBrowsers + settingsService.general.customBrowsers
        let infos = await scanner.scanAll(browsers: allBrowsers)

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
                // Scanner found extension in filesystem but no prior connection record
                let isRunning = !NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == info.browser.bundleIdentifier }.isEmpty
                if !isRunning {
                    updated.extensionStatus = .offline
                } else {
                    updated.extensionStatus = .waitingConnection
                }
            }
            
            return updated
        }
        isScanning = false
    }

    func updateConnectionStatus(for browser: Browser, connected: Bool) {
        if let idx = browserInfos.firstIndex(where: { $0.browser == browser }) {
            let lastConnectedKey = "extension_last_connected_\(browser.rawValue)"
            
            if connected {
                let previousStatus = browserInfos[idx].extensionStatus
                browserInfos[idx].extensionStatus = .connected
                UserDefaults.standard.set(true, forKey: "extension_installed_\(browser.rawValue)")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastConnectedKey)
                
                let shouldNotify = previousStatus == .offline || previousStatus == .notInstalled || previousStatus == .extensionDisabled
                if shouldNotify && settingsService.general.notifyBrowserConnected {
                    notificationService.notifyBrowserConnected(browser)
                }
            } else {
                browserInfos[idx].extensionStatus = .waitingConnection
                
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s grace period
                    await MainActor.run {
                        if let currentIdx = self.browserInfos.firstIndex(where: { $0.browser == browser }), 
                           self.browserInfos[currentIdx].extensionStatus != .connected {
                            
                            let isRunning = !NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == browser.bundleIdentifier }.isEmpty
                            if !isRunning {
                                self.browserInfos[currentIdx].extensionStatus = .offline
                            } else {
                                self.browserInfos[currentIdx].extensionStatus = .waitingConnection
                            }
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
        let stats = await syncService.syncNow(categories: categories)
        if settingsService.general.notifySyncComplete {
            let enabled = Array(categories ?? settingsService.syncSettings.enabledCategories)
            notificationService.notifySyncComplete(stats: stats, categories: enabled)
        }
    }
    
    func requestTabSharingPull() {
        let msg = WSMessage.pull(category: "tabSharing")
        daemon.broadcast(msg)
    }
}


// MARK: - DaemonServerDelegate

extension AppState: DaemonServerDelegate {
    nonisolated func daemonServer(_ server: DaemonServer, didConnect client: ConnectedClient) {
        Task { @MainActor in
            self.updateConnectionStatus(for: client.browser, connected: true)
            self.broadcastSettings(to: client)
        }
    }

    nonisolated func daemonServer(_ server: DaemonServer, didDisconnect clientId: String, browser: Browser) {
        Task { @MainActor in
            if !server.isConnected(browser: browser) {
                self.updateConnectionStatus(for: browser, connected: false)
                
                // Clear the cache for this browser
                self.remoteTabsCache.removeValue(forKey: browser)
                
                // Broadcast an empty tab list to inform other extensions that this browser is offline
                let msg = WSMessage(
                    type: .sync,
                    browser: browser.rawValue,
                    category: "tabSharing",
                    payload: .tabs([]),
                    messageId: UUID().uuidString,
                    timestamp: Date().timeIntervalSince1970
                )
                server.broadcast(msg)
            }
        }
    }

    nonisolated func daemonServer(_ server: DaemonServer, didReceiveSync message: WSMessage, from clientId: String) {
        Task { @MainActor in
            self.syncService.receive(message: message, from: clientId)
        }
    }
    
    nonisolated func daemonServer(_ server: DaemonServer, didReceiveOpenSettingsFrom clientId: String) {
        Task { @MainActor in
            if (NSApp.delegate as? AppDelegate)?.showExistingSettingsWindowIfPossible() != true {
                (NSApp.delegate as? AppDelegate)?.prepareToOpenSettingsWindow()
                self.openWindowAction?("SettingsWindow")
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func daemonServer(_ server: DaemonServer, didReceiveOpenURL message: WSMessage, from clientId: String) {
        Task { @MainActor in
            guard case .raw(let raw) = message.payload,
                  let targetBrowserRaw = raw["targetBrowser"]?.value as? String,
                  let targetBrowser = Browser(rawValue: targetBrowserRaw),
                  let urlString = raw["url"]?.value as? String,
                  let url = URL(string: urlString),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let appURL = self.appURL(forBrowserId: targetBrowser.rawValue) else {
                return
            }

            self.syncService.log("Opening '\(url.absoluteString)' from [\(clientId)] in \(targetBrowser.displayName)")
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }


    nonisolated func daemonServer(_ server: DaemonServer, didReceivePullBookmarks clientId: String) {
        Task { @MainActor in
            guard self.settingsService.syncSettings.enabledCategories.contains(.bookmarks) else { return }
            let strategy = self.settingsService.syncSettings.bookmarkSyncStrategy
            let sourceBrowser = self.settingsService.syncSettings.bookmarkSourceBrowser
            
            // Safari extension does not support the WebExtension bookmarks API (it uses native sync instead)
            // so we should never push bookmarks to the Safari extension.
            if clientId.contains("safari") { return }
            
            // Do not push bookmarks back to the browser that is the source of truth
            if sourceBrowser == .chrome && clientId.contains("chrome") { return }
            
            var bookmarksToSend: [Bookmark]? = nil
            var currentSafariBms: [SyncBookmark] = []
            
            if sourceBrowser == .safari {
#if APP_STORE
                return
#else
                let safariSvc = SafariBookmarkService()
                currentSafariBms = safariSvc.readBookmarks()
                if !currentSafariBms.isEmpty {
                    bookmarksToSend = currentSafariBms.map { b in
                        Bookmark(id: b.id, title: b.title, url: b.url, parentId: b.parentId, isFolder: b.isFolder, inBookmarksBar: b.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
                    }
                }
#endif
            } else {
                if let snapshot = self.backupService.getSnapshot(sourceBrowser: sourceBrowser.rawValue) {
                    bookmarksToSend = snapshot
                }
            }
            
            guard let bookmarks = bookmarksToSend, !bookmarks.isEmpty else { return }
            
            // ── Offline Deletion Sync ────────────────────────────────────────────
            // Compare Safari's current state to this client's last known snapshot.
            // Any bookmark that was in the client's snapshot but is no longer in
            // Safari was deleted while the client was offline. Send explicit
            // bookmarks_removed so the client removes them on reconnect.
            // We compare by URL (for leaves) and title (for folders) — not by UUID
            // — to avoid false positives from Safari's UUID drift.
            if sourceBrowser == .safari && !currentSafariBms.isEmpty,
               let clientSnapshot = self.backupService.getSnapshot(sourceBrowser: clientId) {
                let currentUrls = Set(currentSafariBms.compactMap { $0.url }.map { $0.lowercased() })
                let currentFolderTitles = Set(currentSafariBms.filter { $0.isFolder }.map { $0.title.lowercased() })
                
                let offlineDeleted = clientSnapshot.filter { bm in
                    if let urlOpt = bm.url, let url = urlOpt, currentUrls.contains(url.lowercased()) { return false }
                    if bm.isFolder == true && currentFolderTitles.contains(bm.title.lowercased()) { return false }
                    return true
                }
                
                if !offlineDeleted.isEmpty {
                    self.syncService.log("Sending \(offlineDeleted.count) offline deletions to [\(clientId)]")
                    for deletedBm in offlineDeleted {
                        let delMsg = WSMessage(
                            type: .sync,
                            site: "*",
                            category: "bookmarks_removed",
                            payload: .bookmarksRemoved(deletedBm),
                            messageId: UUID().uuidString,
                            timestamp: Date().timeIntervalSince1970
                        )
                        server.send(delMsg, toClientId: clientId)
                    }
                }
            }
            // ────────────────────────────────────────────────────────────────────
            
            var msg = WSMessage(
                type: .sync,
                site: "*",
                category: "bookmarks",
                payload: .bookmarks(bookmarks),
                messageId: UUID().uuidString,
                timestamp: Date().timeIntervalSince1970
            )
            msg.isFullMirror = (strategy == .oneWay) // Full mirror if one-way, otherwise just merge
            // Only send to the requesting client
            let sourceName = sourceBrowser == .safari ? "Safari" : "Chrome"
            self.syncService.log("Answering pull request from [\(clientId)]: Pushed \(bookmarks.count) \(sourceName) bookmarks (isFullMirror: \(msg.isFullMirror ?? false))")
            server.send(msg, toClientId: clientId)
        }
    }

    nonisolated func daemonServer(_ server: DaemonServer, didReceiveSettings message: WSMessage, from clientId: String) {
        Task { @MainActor in
            guard let browserId = clientId.components(separatedBy: "-").first,
                  let browser = Browser(rawValue: browserId),
                  case .raw(let raw) = message.payload else { return }
            
            var changed = false
            
            if let stateSync = raw["stateSync"]?.value as? Bool {
                if stateSync {
                    if self.purchaseService.isProUnlocked ||
                        self.settingsService.syncSettings.stateParticipatingBrowsers.contains(browser) ||
                        self.settingsService.syncSettings.stateParticipatingBrowsers.count < ProLimits.freeSyncBrowserCount {
                        self.settingsService.syncSettings.stateParticipatingBrowsers.insert(browser)
                    }
                } else {
                    self.settingsService.syncSettings.stateParticipatingBrowsers.remove(browser)
                }
                changed = true
            }
            
            if let bookmarkSync = raw["bookmarkSync"]?.value as? Bool {
                if bookmarkSync {
                    if self.purchaseService.isProUnlocked ||
                        self.settingsService.syncSettings.bookmarkParticipatingBrowsers.contains(browser) ||
                        self.settingsService.syncSettings.bookmarkParticipatingBrowsers.count < ProLimits.freeSyncBrowserCount {
                        self.settingsService.syncSettings.bookmarkParticipatingBrowsers.insert(browser)
                    }
                } else {
                    self.settingsService.syncSettings.bookmarkParticipatingBrowsers.remove(browser)
                }
                changed = true
            }
            
            if let tabSharing = raw["tabSharing"]?.value as? Bool {
                if tabSharing {
                    self.settingsService.syncSettings.tabSharingParticipatingBrowsers.insert(browser)
                } else {
                    self.settingsService.syncSettings.tabSharingParticipatingBrowsers.remove(browser)
                }
                changed = true
            }
            
            if let routerDefault = raw["routerDefault"]?.value as? Bool {
                if routerDefault {
                    self.fallbackBrowserId = browser.rawValue
                }
                changed = true
            }
            
            if let siteSync = raw["toggleSiteSync"]?.value as? [String: Any],
               let domain = siteSync["domain"] as? String,
               let value = siteSync["value"] as? Bool {
                let policy = self.settingsService.syncSettings.websiteListPolicy
                let shouldBeInList = (policy == .allowList && value) || (policy == .blockList && !value)
                
                if shouldBeInList {
                    if !self.settingsService.syncSettings.websiteSettings.contains(where: { $0.domain == domain }) {
                        if self.purchaseService.isProUnlocked ||
                            self.settingsService.syncSettings.websiteSettings.count < ProLimits.freeWebsiteRuleCount {
                            self.settingsService.syncSettings.websiteSettings.append(WebsiteSyncSetting(domain: domain, strategy: nil))
                        }
                    }
                } else {
                    self.settingsService.syncSettings.websiteSettings.removeAll(where: { $0.domain == domain })
                }
                changed = true
            }
            
            if let siteStrat = raw["updateSiteStrategy"]?.value as? [String: Any],
               let domain = siteStrat["domain"] as? String {
                let strategyStr = siteStrat["strategy"] as? String
                let strat = strategyStr.flatMap { BrowserDataSyncStrategy(rawValue: $0) }
                if let idx = self.settingsService.syncSettings.websiteSettings.firstIndex(where: { $0.domain == domain }) {
                    self.settingsService.syncSettings.websiteSettings[idx].strategy = strat
                } else {
                    if self.purchaseService.isProUnlocked ||
                        self.settingsService.syncSettings.websiteSettings.count < ProLimits.freeWebsiteRuleCount {
                        self.settingsService.syncSettings.websiteSettings.append(WebsiteSyncSetting(domain: domain, strategy: strat))
                    }
                }
                changed = true
            }

            if let siteBrowser = raw["updateSiteSourceBrowser"]?.value as? [String: Any],
               let domain = siteBrowser["domain"] as? String {
                let browserStr = siteBrowser["browser"] as? String
                let browser = browserStr.flatMap { Browser(rawValue: $0) }
                if let idx = self.settingsService.syncSettings.websiteSettings.firstIndex(where: { $0.domain == domain }) {
                    self.settingsService.syncSettings.websiteSettings[idx].sourceBrowser = browser
                } else {
                    if self.purchaseService.isProUnlocked ||
                        self.settingsService.syncSettings.websiteSettings.count < ProLimits.freeWebsiteRuleCount {
                        self.settingsService.syncSettings.websiteSettings.append(WebsiteSyncSetting(domain: domain, strategy: nil, sourceBrowser: browser))
                    }
                }
                changed = true
            }

            if changed {
                self.settingsService.save()
                self.broadcastSettings()
            }
        }
    }

    func broadcastSettings(to client: ConnectedClient? = nil) {
        let isProUnlocked = purchaseService.isProUnlocked
        let isStateSync = effectiveSyncBrowsers(settingsService.syncSettings.stateParticipatingBrowsers, isProUnlocked: isProUnlocked)
        let isBookmarkSync = effectiveSyncBrowsers(settingsService.syncSettings.bookmarkParticipatingBrowsers, isProUnlocked: isProUnlocked)
        let isTabSharing = settingsService.syncSettings.tabSharingParticipatingBrowsers
        let routerDefault = fallbackBrowserId
        var payload: [String: AnyCodable] = [
            "routerDefault": AnyCodable(routerDefault ?? ""),
            "tabSharingEnabled": AnyCodable(settingsService.syncSettings.tabSharingEnabled)
        ]
        var stateMap: [String: AnyCodable] = [:]
        for b in Browser.allCases {
            stateMap[b.rawValue] = AnyCodable(isStateSync.contains(b))
        }
        
        let installedBrowsers = browserInfos.filter { $0.isInstalled }.map { $0.browser.rawValue }
        payload["installedBrowsers"] = AnyCodable(installedBrowsers)
        var bookmarkMap: [String: AnyCodable] = [:]
        for b in Browser.allCases {
            bookmarkMap[b.rawValue] = AnyCodable(isBookmarkSync.contains(b))
        }
        var tabSharingMap: [String: AnyCodable] = [:]
        for b in Browser.allCases {
            tabSharingMap[b.rawValue] = AnyCodable(isTabSharing.contains(b))
        }
        payload["stateParticipatingBrowsers"] = AnyCodable(stateMap)
        payload["bookmarkParticipatingBrowsers"] = AnyCodable(bookmarkMap)
        payload["tabSharingParticipatingBrowsers"] = AnyCodable(tabSharingMap)
        
        let effectiveWebsiteSettings = ProLimits.limitedWebsiteSettings(settingsService.syncSettings.websiteSettings, isProUnlocked: isProUnlocked)
        if let data = try? JSONEncoder().encode(effectiveWebsiteSettings),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            payload["websiteSettings"] = AnyCodable(array)
        }
        payload["websiteListPolicy"] = AnyCodable(settingsService.syncSettings.websiteListPolicy.rawValue)
        payload["syncDisabledDomains"] = AnyCodable(WebsiteSyncSetting.syncDisabledDomains)

        let msg = WSMessage(
            type: .settings,
            payload: .raw(payload),
            messageId: UUID().uuidString,
            timestamp: Date().timeIntervalSince1970
        )
        
        if let client = client {
            daemon.sendWSMessage(msg, to: client)
        } else {
            daemon.broadcast(msg)
        }
    }

    private func effectiveSyncBrowsers(_ browsers: Set<Browser>, isProUnlocked: Bool) -> Set<Browser> {
        guard !isProUnlocked else { return browsers }
        let ordered = Browser.allCases.filter { browsers.contains($0) }
        return Set(ordered.prefix(ProLimits.freeSyncBrowserCount))
    }
}
