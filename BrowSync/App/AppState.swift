// AppState.swift
// BrowSync — Global observable state

import Foundation
import SwiftUI
import Combine
import AppKit

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    private static let disabledDomainsCacheKey = "syncDisabledDomainsCache"
    // Services
    // SettingsService performs the one-time direct-install → sandbox migration
    // during initialization. It must come first so the daemon, sync service,
    // and backup service load the migrated files rather than an empty container.
    let settingsService = SettingsService()
    let daemon = DaemonServer()
    let scanner = BrowserScanner()
    let syncService = SyncService()
    let notificationService = NotificationService()
    let backupService = BackupService()
    let iCloudSyncManager = ICloudSyncManager()
    let purchaseService = PurchaseService()

    private var cancellables = Set<AnyCancellable>()
    private var hasFinishedInitialSetup = false
    
    var openWindowAction: ((String) -> Void)?

    // Published state
    @Published var browserInfos: [BrowserInfo] = Browser.allCases.map { .placeholder(for: $0) }
    @Published var isScanning: Bool = false
    @Published var bookmarkFolderManagerOpenRequest: Int = 0
    @Published var recentBookmarkBackupsOpenRequest: Int = 0
    /// Bookmark plans waiting for an explicit user decision.
    @Published var pendingBookmarkReviewClientIds: [String] = [] {
        didSet {
            // A single badge is deliberately state-only: it says there is
            // something waiting, not how many writes are safe to make.
            NSApp.dockTile.badgeLabel = pendingBookmarkReviewClientIds.isEmpty ? nil : "!"
            NSApp.dockTile.display()
        }
    }
    /// Browsers whose bookmark sync into Safari is paused by "Keep Safari As Is".
    @Published var pausedBookmarkSyncClientIds: [String] = []
    @Published private(set) var syncDisabledDomains: [String] = []

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
    @Published var isRouterEnabled: Bool = false {
        didSet {
            settingsService.routerSettings.isEnabled = isRouterEnabled
            settingsService.save()
            guard hasFinishedInitialSetup else { return }
            broadcastSettings()
            if oldValue && !isRouterEnabled {
                requestSystemDefaultBrowserReplacementIfNeeded()
            } else if !oldValue && isRouterEnabled {
                requestBrowSyncAsDefaultBrowserIfNeeded()
            }
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

    init() {
        // Wire up services
        syncService.daemon = daemon
        syncService.settingsService = settingsService
        syncService.backupService = backupService
        daemon.bookmarkMutationInterceptor = { [weak syncService] message, client in
            syncService?.stageBrowserBookmarkMutation(message, to: client) ?? false
        }
        
        isRouterEnabled = settingsService.routerSettings.isEnabled
        fallbackBrowserId = settingsService.routerSettings.fallbackBrowserId
        routerRules = settingsService.routerSettings.rules

        // Wire daemon delegate
        daemon.delegate = self
        
        pausedBookmarkSyncClientIds = syncService.rejectedBookmarkSyncClientIds

        // Unlocking Pro (e.g. purchase status loading after launch) can add
        // participating browsers without a reconnect; recompute pending changes.
        purchaseService.$isProUnlocked
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.syncService.scheduleBookmarkSyncSession()
                }
            }
            .store(in: &cancellables)

        settingsService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                // objectWillChange fires before the new value is stored. A held
                // bookmark change computed under other settings is dropped.
                DispatchQueue.main.async {
                    self?.syncService.discardStalePendingSafariWrites()
                }
            }
            .store(in: &cancellables)

            
        iCloudSyncManager.setup(settingsService: settingsService)
        purchaseService.start()
        loadCachedDisabledDomains()
        if syncDisabledDomains.isEmpty {
            loadBundledDisabledDomains()
        }
        
        hasFinishedInitialSetup = true
    }

    // MARK: - Startup

    func onAppear() async {
        // Browser scanning must not delay the policy that extensions receive at launch.
        Task {
            await fetchDisabledDomains()
        }

        // Start daemon
        daemon.start()

        // Initial browser scan
        await refreshBrowsers()
        
        // Check default browser status
        checkDefaultBrowser()

        // `isRouterEnabled`'s didSet (which calls this when the router is
        // switched off) never fires for the assignment made in init() — Swift
        // property observers don't run for assignments inside the declaring
        // type's own initializer. Without this call, a user who quit with the
        // router disabled but BrowSync still set as the system default browser
        // would never get it restored. The function itself no-ops unless the
        // router is actually off and BrowSync actually is the current default.
        requestSystemDefaultBrowserReplacementIfNeeded()

#if SAFARI_SCOPED_ACCESS
        SandboxAccessManager.shared.promptForSafariAccessAfterUpgradeIfNeeded(
            syncSettings: settingsService.syncSettings
        ) { [weak self] in
            // The initial monitor setup ran before this security-scoped access
            // existed, so restart it immediately after the user grants access.
            self?.syncService.startSafariBookmarkMonitor()
        }
#endif
        
    }
    
    private func loadCachedDisabledDomains() {
        guard let domains = UserDefaults.standard.stringArray(forKey: Self.disabledDomainsCacheKey), !domains.isEmpty else {
            return
        }
        applyDisabledDomains(domains)
    }

    private func loadBundledDisabledDomains() {
        guard let url = Bundle.main.url(forResource: "disabled-domains", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let domains = try? JSONDecoder().decode([String].self, from: data),
              !domains.isEmpty else {
            return
        }
        applyDisabledDomains(domains)
    }

    private func applyDisabledDomains(_ domains: [String]) {
        let normalized = Array(Set(domains.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        guard !normalized.isEmpty else { return }
        WebsiteSyncSetting.syncDisabledDomains = normalized
        syncDisabledDomains = normalized
        UserDefaults.standard.set(normalized, forKey: Self.disabledDomainsCacheKey)
    }

    private func fetchDisabledDomains() async {
        guard let url = URL(string: "https://browsync.ct106.com/disabled-domains.json") else { return }
        do {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                print("Failed to fetch disabled domains: unexpected HTTP response")
                return
            }
            let domains = try JSONDecoder().decode([String].self, from: data)
            guard !domains.isEmpty else { return }
            applyDisabledDomains(domains)
            broadcastSettings()
        } catch {
            print("Failed to fetch disabled domains: \(error)")
        }
    }

    // MARK: - Router & URL Handling
    
    func checkDefaultBrowser() {
        guard let probeURL = URL(string: "http://apple.com"),
              let defaultURL = NSWorkspace.shared.urlForApplication(toOpen: probeURL) else {
            isDefaultBrowser = false
            return
        }
        let resolvedDefaultURL = defaultURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedAppURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let isThisBundle = Bundle(url: defaultURL)?.bundleIdentifier == Bundle.main.bundleIdentifier
        isDefaultBrowser = isThisBundle || resolvedDefaultURL == resolvedAppURL
    }

    /// Default-handler changes are committed asynchronously after the system
    /// consent sheet closes. Refresh a few times so the router warning updates
    /// without requiring the user to reopen this screen.
    private func refreshDefaultBrowserStatusAfterSystemChange() {
        Task { @MainActor [weak self] in
            for delay in [0, 250_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay))
                }
                self?.checkDefaultBrowser()
            }
        }
    }

    /// A disabled router cannot safely remain the system default handler: URLs
    /// would keep opening BrowSync only to be forwarded elsewhere. Request the
    /// same system consent dialog used when BrowSync becomes the default, but
    /// point it at the selected fallback browser instead.
    func requestSystemDefaultBrowserReplacementIfNeeded() {
        guard !isRouterEnabled else { return }
        checkDefaultBrowser()
        guard isDefaultBrowser else { return }

        let replacementURL = fallbackBrowserId
            .flatMap { appURL(forBrowserId: $0) }
            ?? browserInfos.first(where: { $0.browser == .safari && $0.isInstalled })?.appURL
            ?? Browser.safari.appURL
        guard let replacementURL else { return }

        if #available(macOS 12.0, *) {
            NSWorkspace.shared.setDefaultApplication(at: replacementURL, toOpenURLsWithScheme: "http") { error in
                if let error {
                    print("Failed to request the default browser replacement for http: \(error)")
                }
            }
            NSWorkspace.shared.setDefaultApplication(at: replacementURL, toOpenURLsWithScheme: "https") { [weak self] error in
                if let error {
                    print("Failed to request the default browser replacement for https: \(error)")
                }
                Task { @MainActor in self?.refreshDefaultBrowserStatusAfterSystemChange() }
            }
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
                Task { @MainActor in self.refreshDefaultBrowserStatusAfterSystemChange() }
            }
        } else {
            if let prefURL = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings") {
                NSWorkspace.shared.open(prefURL)
            }
        }
    }

    func requestBrowSyncAsDefaultBrowserIfNeeded() {
        checkDefaultBrowser()
        guard !isDefaultBrowser else { return }
        promptSetDefaultBrowser()
    }
    
    func handleIncomingURL(_ url: URL, sourceAppBundleId: String?) {
        if url.scheme == "browsync" {
            if url.host == "open" {
                openWindowAction?("SettingsWindow")
            }
            // App is already brought to front by macOS, nothing else to do
            return
        }

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
                    syncService.log("🔀 Routed a link (from \(sourceName)) ➡️ \(targetId) (Rule Matched: \(rule.id.uuidString.prefix(8)))")
                    NSWorkspace.shared.open([url], withApplicationAt: targetAppURL, configuration: NSWorkspace.OpenConfiguration())
                    return
                } else if rule.targetBrowserId == nil {
                    openInDefaultFallback(url: url, sourceName: sourceName, reason: "Rule Matched: \(rule.id.uuidString.prefix(8)) (Action: Default Browser)")
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
        syncService.log("🔀 Routed a link (from \(sourceName)) ➡️ \(targetName) (\(reason))")
        
        if let appURL = targetAppURL {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func requestOpenBookmarkFolderManager() {
        openWindowAction?("SettingsWindow")
        bookmarkFolderManagerOpenRequest += 1
    }

    func requestOpenRecentBookmarkBackups() {
        openWindowAction?("SettingsWindow")
        recentBookmarkBackupsOpenRequest += 1
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
        // Extension clients may connect before the initial scan completes.
        // Re-send settings so their browser icon metadata reflects the actual
        // installed applications rather than an empty startup snapshot.
        broadcastSettings()
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
            // Changes it missed while offline are still pending against its
            // per-pair baselines; its fresh snapshot lets a session plan them.
            if self.settingsService.syncSettings.enabledCategories.contains(.bookmarks),
               self.settingsService.syncSettings.bookmarkParticipatingBrowsers.contains(client.browser),
               client.browser != .safari {
                let refresh = WSMessage(type: .sync, site: "*", category: "bookmarks",
                                        payload: nil, messageId: UUID().uuidString,
                                        timestamp: Date().timeIntervalSince1970)
                server.sendWSMessage(refresh, to: client)
            }
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

            self.syncService.log("Opening a shared tab from [\(clientId)] in \(targetBrowser.displayName)")
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }


    /// A bookmark pull never receives another browser's tree: that would
    /// turn a cross-browser difference into writes outside the session
    /// planner. Its fresh snapshot is requested instead; a session plans it.
    nonisolated func daemonServer(_ server: DaemonServer, didReceivePullBookmarks clientId: String) {
        Task { @MainActor in
            let settings = self.settingsService.syncSettings
            guard settings.enabledCategories.contains(.bookmarks),
                  let client = server.connectedClients.first(where: { $0.id == clientId }),
                  client.browser != .safari,
                  settings.bookmarkParticipatingBrowsers.contains(client.browser) else { return }
            let refresh = WSMessage(type: .sync, site: "*", category: "bookmarks", payload: nil,
                                    messageId: UUID().uuidString, timestamp: Date().timeIntervalSince1970)
            server.sendWSMessage(refresh, to: client)
            self.syncService.log("Bookmark pull from [\(clientId)] answered with a snapshot request; changes are planned by a sync session.")
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
               let domain = siteStrat["domain"] as? String,
               self.settingsService.syncSettings.websiteListPolicy == .allowList {
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
               let domain = siteBrowser["domain"] as? String,
               self.settingsService.syncSettings.websiteListPolicy == .allowList {
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
            "routerEnabled": AnyCodable(isRouterEnabled),
            "interfaceLanguage": AnyCodable(resolvedExtensionLanguage()),
            "bookmarkSyncEnabled": AnyCodable(settingsService.syncSettings.enabledCategories.contains(.bookmarks)),
            "bookmarkSyncStrategy": AnyCodable(settingsService.syncSettings.bookmarkSyncStrategy.rawValue),
            "bookmarkSourceBrowser": AnyCodable(settingsService.syncSettings.bookmarkSourceBrowser.rawValue),
            "bookmarkSafeMode": AnyCodable(settingsService.syncSettings.bookmarkSafeMode),
            "stateSyncEnabled": AnyCodable(settingsService.syncSettings.enabledCategories.contains(.browserData)),
            // Extensions use this value to decide whether navigation and cookie
            // changes may start an automatic state pull.  Keep it aligned with
            // the master State Sync switch, not only the secondary real-time
            // setting.
            "automaticSync": AnyCodable(isProUnlocked && settingsService.syncSettings.automaticSync && settingsService.syncSettings.enabledCategories.contains(.browserData)),
            "tabSharingEnabled": AnyCodable(settingsService.syncSettings.tabSharingEnabled)
        ]
        var stateMap: [String: AnyCodable] = [:]
        for b in Browser.allCases {
            stateMap[b.rawValue] = AnyCodable(isStateSync.contains(b))
        }
        
        let installedBrowsers = browserInfos.filter { $0.isInstalled }.map { $0.browser.rawValue }
        payload["installedBrowsers"] = AnyCodable(installedBrowsers)
        let installedBrowserDetails: [[String: AnyCodable]] = browserInfos.compactMap { info in
            guard info.isInstalled, let appURL = info.appURL else { return nil }
            return [
                "id": AnyCodable(info.browser.rawValue),
                "displayName": AnyCodable(browserDisplayName(for: appURL)),
                "iconDataURL": AnyCodable(browserIconDataURL(for: appURL) ?? "")
            ]
        }
        payload["installedBrowserDetails"] = AnyCodable(installedBrowserDetails)
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
        payload["bookmarkSyncFolders"] = AnyCodable(settingsService.syncSettings.bookmarkSyncFolders.compactMapValues { BookmarkFolderPath.canonicalized($0) })
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

    private func resolvedExtensionLanguage() -> String {
        let selectedLanguage = settingsService.general.language
        guard selectedLanguage == .system else { return selectedLanguage.rawValue }

        let preferred = Bundle.preferredLocalizations(
            from: Bundle.main.localizations,
            forPreferences: Locale.preferredLanguages
        ).first?.lowercased() ?? "en"
        if preferred.hasPrefix("zh") { return AppLanguage.chineseSimplified.rawValue }
        if preferred.hasPrefix("ja") { return AppLanguage.japanese.rawValue }
        if preferred.hasPrefix("ko") { return AppLanguage.korean.rawValue }
        if preferred.hasPrefix("de") { return AppLanguage.german.rawValue }
        if preferred.hasPrefix("fr") { return AppLanguage.french.rawValue }
        if preferred.hasPrefix("it") { return AppLanguage.italian.rawValue }
        if preferred.hasPrefix("es") { return AppLanguage.spanish.rawValue }
        return AppLanguage.english.rawValue
    }

    private func browserIconDataURL(for appURL: URL) -> String? {
        let side = CGFloat(64)
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    private func browserDisplayName(for appURL: URL) -> String {
        if let bundle = Bundle(url: appURL) {
            if let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String, !name.isEmpty {
                return name
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !name.isEmpty {
                return name
            }
        }
        return appURL.deletingPathExtension().lastPathComponent
    }

    private func effectiveSyncBrowsers(_ browsers: Set<Browser>, isProUnlocked: Bool) -> Set<Browser> {
        guard !isProUnlocked else { return browsers }
        let ordered = Browser.allCases.filter { browsers.contains($0) }
        return Set(ordered.prefix(ProLimits.freeSyncBrowserCount))
    }
}
