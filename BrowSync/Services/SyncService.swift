// SyncService.swift
// BrowSync — Orchestrates sync operations between browsers via the Daemon

import Foundation
import os.log

struct SyncStats {
    var bookmarks: Int = 0
    var bookmarksAdded: Int = 0
    var bookmarksDeleted: Int = 0
    var bookmarksModified: Int = 0
    
    var tabs: Int = 0
    var cookies: Int = 0
    var localStorage: Int = 0
    var sessionStorage: Int = 0
    
    var stateItems: Int { cookies + localStorage + sessionStorage }
    var isEmpty: Bool { bookmarks == 0 && tabs == 0 && stateItems == 0 && bookmarksAdded == 0 && bookmarksDeleted == 0 && bookmarksModified == 0 }
}

@MainActor
final class SyncService: ObservableObject {
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "SyncService")
    private let dataDir: URL

    @Published var lastSyncDate: Date? = nil
    @Published var isSyncing: Bool = false
    @Published var syncLog: [SyncLogEntry] = []
    
    private var currentManualSyncStats = SyncStats()

    var daemon: DaemonServer?
    var settingsService: SettingsService?
    var settings: SyncSettings {
        var current = settingsService?.syncSettings ?? SyncSettings()
        guard !AppState.shared.purchaseService.isProUnlocked else { return current }

        current.bookmarkParticipatingBrowsers = Set(Browser.allCases.filter {
            current.bookmarkParticipatingBrowsers.contains($0)
        }.prefix(ProLimits.freeSyncBrowserCount))
        current.stateParticipatingBrowsers = Set(Browser.allCases.filter {
            current.stateParticipatingBrowsers.contains($0)
        }.prefix(ProLimits.freeSyncBrowserCount))
        current.websiteSettings = ProLimits.limitedWebsiteSettings(current.websiteSettings, isProUnlocked: false)
        current.bookmarkAutoSync = false
        current.automaticSync = false
        return current
    }
    var backupService: BackupService?
    private let safariBookmarks = SafariBookmarkService()
    private var latestCookieVersions: [String: Double] = [:]
    private var latestCookieClients: [String: String] = [:]
    // Tracks cookie keys where the current winner is a tombstone (deletion).
    // When a live cookie beats a tombstone, the sender may have already had
    // its cookie deleted by the tombstone broadcast, so we must send it back.
    private var tombstoneWinnerKeys: Set<String> = []
    
    // Safari Bookmark Monitor
    private var safariMonitorSource: DispatchSourceFileSystemObject?
    private var safariMonitorFileDescriptor: Int32 = -1
    private var safariBookmarkDebounceTask: Task<Void, Never>?
    private var lastNetworkSyncTime: Date = Date.distantPast

    init() {
#if !APP_STORE
        SafariCleanup.cleanDirtyBookmarks()
#endif
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dataDir = appSupport.appendingPathComponent("BrowSync")
        createDataDirectories()
#if !APP_STORE
        startSafariBookmarkMonitor()
#endif
    }
    
    deinit {
        safariMonitorSource?.cancel()
        if safariMonitorFileDescriptor != -1 {
            close(safariMonitorFileDescriptor)
        }
    }

    // MARK: - Data Directories

    private func createDataDirectories() {
        let dirs = ["sites", "bookmarks", "history", "logs"]
        for dir in dirs {
            let url = dataDir.appendingPathComponent(dir)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - Safari Bookmark Monitor
    
    private func startSafariBookmarkMonitor() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent("Library/Safari/Bookmarks.plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        
        safariMonitorFileDescriptor = open(url.path, O_EVTONLY)
        guard safariMonitorFileDescriptor != -1 else { return }
        
        safariMonitorSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: safariMonitorFileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        
        safariMonitorSource?.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = Date()
            
            // 1. Re-arm monitor if file was deleted/replaced (e.g., atomic save)
            // This MUST be checked before returning, otherwise the monitor will detach forever
            let data = self.safariMonitorSource?.data
            if data?.contains(.delete) == true || data?.contains(.rename) == true {
                self.safariMonitorSource?.cancel()
                if self.safariMonitorFileDescriptor != -1 { close(self.safariMonitorFileDescriptor) }
                self.safariMonitorSource = nil
                self.safariMonitorFileDescriptor = -1
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.startSafariBookmarkMonitor()
                }
            }
            
            // 2. Echo Cancellation: Ignore changes triggered by our own writes
            if now.timeIntervalSince(self.lastNetworkSyncTime) < 10.0 {
                self.log("Ignoring Safari Bookmarks.plist change (echo cancellation)")
                return
            }
            
            // 3. Debounce: Wait for 10 seconds of silence before triggering sync
            self.safariBookmarkDebounceTask?.cancel()
            self.safariBookmarkDebounceTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                    if Task.isCancelled { return }
                    
                    if self.settings.bookmarkAutoSync || self.settings.automaticSync {
                        self.log("Safari Bookmarks.plist changed! Triggering auto-sync...")
                        await self.syncCategory(.bookmarks)
                    }
                } catch {
                    // Task cancelled
                }
            }
        }
        
        safariMonitorSource?.resume()
        log("Started Safari Bookmarks.plist monitor for real-time sync")
    }

    // MARK: - Sync Now

    func syncNow(categories: Set<SyncCategory>? = nil) async -> SyncStats {
        guard !isSyncing else { return SyncStats() }
        isSyncing = true
        currentManualSyncStats = SyncStats()
        
        let connectedClients = daemon?.connectedClients.map { "\($0.browser.rawValue)-\($0.id)" }.joined(separator: ", ") ?? "none"
        log("Starting manual sync... Connected clients: \(connectedClients)")

        let targetCategories = categories ?? settings.enabledCategories
#if APP_STORE
        let preSyncSafariBookmarks: [SyncBookmark] = []
#else
        let preSyncSafariBookmarks = targetCategories.contains(.bookmarks) ? safariBookmarks.readBookmarks() : []
#endif
        for category in SyncCategory.allCases where targetCategories.contains(category) {
            await syncCategory(category)
        }
        
        // Wait for clients to respond before ending manual sync window
        // But don't wait at all if no clients connected
        let hasClients = (daemon?.connectedClients.isEmpty == false)
        if hasClients {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
        }

        lastSyncDate = Date()
        isSyncing = false
        if targetCategories.contains(.bookmarks) {
#if APP_STORE
            currentManualSyncStats.bookmarks = 0
#else
            let postSyncSafariBookmarks = safariBookmarks.readBookmarks()
            currentManualSyncStats.bookmarks = postSyncSafariBookmarks.count
            
            let prevMap = Dictionary(uniqueKeysWithValues: preSyncSafariBookmarks.map { ($0.id, $0) })
            let newMap = Dictionary(uniqueKeysWithValues: postSyncSafariBookmarks.map { ($0.id, $0) })
            
            for (id, bm) in newMap {
                if let p = prevMap[id] {
                    if p.title != bm.title || p.url != bm.url || p.parentId != bm.parentId {
                        currentManualSyncStats.bookmarksModified += 1
                    }
                } else {
                    currentManualSyncStats.bookmarksAdded += 1
                }
            }
            for id in prevMap.keys {
                if newMap[id] == nil {
                    currentManualSyncStats.bookmarksDeleted += 1
                }
            }
#endif
        }
        log("Sync complete (Bookmarks: \(currentManualSyncStats.bookmarks), Cookies: \(currentManualSyncStats.cookies), LocalStorage: \(currentManualSyncStats.localStorage), SessionStorage: \(currentManualSyncStats.sessionStorage))")
        return currentManualSyncStats
    }

    private func syncCategory(_ category: SyncCategory) async {
        log("Syncing: \(category.displayName)")

        let strategy = settings.bookmarkSyncStrategy
        let sourceBrowser = settings.bookmarkSourceBrowser

        if category == .bookmarks {
            // Determine if we should push Safari to others
#if APP_STORE
            let shouldPushSafari = false
#else
            let shouldPushSafari = (strategy == .twoWayMerge || (strategy == .oneWay && sourceBrowser == .safari)) && settings.bookmarkParticipatingBrowsers.contains(.safari)
#endif
            
            if shouldPushSafari {
                let safariBms = safariBookmarks.readBookmarks()
                if !safariBms.isEmpty {
                    // Check for deletions comparing to the last hidden snapshot.
                    // IMPORTANT: We compare by URL (for leaves) and title (for folders), NOT by UUID.
                    // Safari's Bookmarks.plist may regenerate UUIDs when rewritten, so UUID mismatches
                    // do NOT indicate a real deletion. If the URL/title still exists in Safari, it was NOT deleted.
                    if let lastSafariBms = backupService?.getSnapshot(sourceBrowser: "safari") {
                        let currentIds = Set(safariBms.map { $0.id })
                        let currentUrls = Set(safariBms.compactMap { $0.url.flatMap { $0 } }.map { $0.lowercased() })
                        let currentFolderTitles = Set(safariBms.filter { $0.isFolder }.map { $0.title.lowercased() })
                        
                        let deletedBms = lastSafariBms.filter { bm in
                            // Still present by ID → not deleted
                            if currentIds.contains(bm.id) { return false }
                            // Leaf: still present by URL → UUID drift, not a real deletion
                            if let urlOpt = bm.url, let url = urlOpt, currentUrls.contains(url.lowercased()) { return false }
                            // Folder: still present by title → UUID drift, not a real deletion
                            if bm.isFolder && currentFolderTitles.contains(bm.title.lowercased()) { return false }
                            // Truly gone from Safari
                            return true
                        }
                        
                        if !deletedBms.isEmpty {
                            log("Detected \(deletedBms.count) bookmark deletions in Safari, adding to trash...")
                            
                            let deletedItems = buildDeletedBookmarkForest(from: deletedBms, sourceBrowser: "Safari")
                            backupService?.addDeletedBookmarks(deletedItems)
                            
                            for deletedBm in deletedBms {
                                let msg = WSMessage(
                                    type: .sync,
                                    site: "*",
                                    category: "bookmarks_removed",
                                    payload: .bookmarksRemoved(deletedBm),
                                    messageId: UUID().uuidString,
                                    timestamp: Date().timeIntervalSince1970
                                )
                                daemon?.broadcast(msg, participatingBrowsers: settings.bookmarkParticipatingBrowsers)
                                // NOTE: Do NOT save bookmarks_removed to GlobalStateStore.
                                // These are point-in-time events; replaying them to reconnecting
                                // clients causes destructive false deletions.
                            }
                            if self.isSyncing {
                                self.currentManualSyncStats.bookmarksDeleted += deletedBms.count
                            }
                        }
                    }

                    let bookmarks = safariBms.map { b in
                        Bookmark(id: b.id, title: b.title, url: b.url.flatMap { $0 }, parentId: b.parentId, isFolder: b.isFolder, inBookmarksBar: b.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
                    }
                    
                    backupService?.saveSnapshot(bookmarks: bookmarks, sourceBrowser: "safari")
                    
                    var pushMsg = WSMessage(
                        type: .sync,
                        site: "*",
                        category: category.rawValue,
                        payload: .bookmarks(bookmarks),
                        messageId: UUID().uuidString,
                        timestamp: Date().timeIntervalSince1970
                    )
                    pushMsg.isFullMirror = (strategy == .oneWay) // Full mirror if one-way, otherwise just merge
                    daemon?.broadcast(pushMsg, participatingBrowsers: settings.bookmarkParticipatingBrowsers)
                    log("Pushed \(bookmarks.count) Safari bookmarks to clients")
                } else {
                    log("No Safari bookmarks found to sync")
                }
            }

            // Determine if we should pull from others
            let shouldPullOthers = strategy == .twoWayMerge || (strategy == .oneWay && sourceBrowser != .safari)
            if shouldPullOthers {
                let requestMessage = WSMessage(
                    type: .sync,
                    site: "*",
                    category: category.rawValue,
                    payload: nil,
                    messageId: UUID().uuidString,
                    timestamp: Date().timeIntervalSince1970
                )
                daemon?.broadcast(requestMessage, participatingBrowsers: settings.bookmarkParticipatingBrowsers)
            }
        } else {
            // For other categories, we just pull from everyone for now
            let requestMessage = WSMessage(
                type: .sync,
                site: "*",
                category: category.rawValue,
                payload: nil,
                messageId: UUID().uuidString,
                timestamp: Date().timeIntervalSince1970
            )
            daemon?.broadcast(requestMessage)
            
            // Proactively push the globally cached state from the central app.
            // This ensures that if the primary state source browser is not running,
            // we still sync the latest accumulated state to all connected browsers.
            let cachedPayloads = GlobalStateStore.shared.pull(category: category.rawValue)
            for payloadData in cachedPayloads {
                if let msg = try? JSONDecoder().decode(WSMessage.self, from: payloadData) {
                    if msg.category == "cookies", case .cookies(let cookies) = msg.payload {
                        let liveOnly = cookies.filter { $0.removed != true }
                        if liveOnly.isEmpty { continue }
                        var cleaned = msg
                        cleaned.payload = .cookies(liveOnly)
                        daemon?.broadcast(cleaned)
                    } else {
                        daemon?.broadcast(msg)
                    }
                }
            }
        }
    }

    // MARK: - Receive Sync Data

    func receive(message: WSMessage, from clientId: String) {
        guard message.type == .sync, let category = message.category else { return }
        
        var filteredMessage = message
        
        // Capture previous snapshot for auto-sync notifications before it gets overwritten
        let preSyncAutoBookmarks = backupService?.getSnapshot(sourceBrowser: clientId) ?? []
        
        if category == "bookmarks" || category == "bookmark_incremental" || category == "bookmarks_removed" || category == "bookmark_backup" || category == "tabSharing" {
            let browserId = clientId.components(separatedBy: "-").first ?? clientId
            if let browser = Browser(rawValue: browserId) {
                // Ensure the message carries the verified true sender ID
                filteredMessage.browser = browserId
                
                let participating = category == "tabSharing" ? settings.tabSharingParticipatingBrowsers : settings.bookmarkParticipatingBrowsers
                if !participating.contains(browser) {
                    log("Ignored \(category) data from [\(clientId)] because it is not participating in sync.")
                    return
                }
            }
        }
        
        // Respect One-Way Sync Strategy for ALL incoming bookmark data
        let strategy = settings.bookmarkSyncStrategy
        let sourceBrowser = settings.bookmarkSourceBrowser
        let isBookmarkCategory = (category == "bookmarks" || category == "bookmark_incremental" || category == "bookmarks_removed")
        
        if isBookmarkCategory && strategy == .oneWay && sourceBrowser == .safari {
            if clientId.lowercased().contains("chrome") || clientId.lowercased().contains("edge") {
                log("Ignored \(category) from [\(clientId)] due to one-way sync strategy (Safari is primary)")
                return
            }
        }
        if strategy == .oneWay && category == "bookmarks" {
            // In one-way sync, the target should exactly mirror the source.
            // Setting isFullMirror = true ensures the target prunes local items not present in the payload.
            filteredMessage.isFullMirror = true
        }
        if category == "bookmarks", case .bookmarks(let bms) = filteredMessage.payload {
            // We no longer perform implicit deletion diffing for Chrome/Edge clients.
            // It was causing mass-deletions when the extension's idMap was cleared.
            // Now we strictly rely on explicit "bookmarks_removed" payloads sent by the extensions.
            backupService?.saveSnapshot(bookmarks: bms, sourceBrowser: clientId)
        }

        if category == "bookmarks_removed" {
            if case .bookmarksRemoved(let bm) = filteredMessage.payload {
                safariBookmarks.removeBookmark(id: bm.id, title: bm.title, url: bm.url ?? nil)
                log("Removed bookmark '\(bm.title)' from Safari (triggered by [\(clientId)])")
                let shouldSync = settings.bookmarkAutoSync || settings.automaticSync || isSyncing
                if shouldSync {
                    daemon?.broadcast(filteredMessage, excluding: clientId)
                    // NOTE: Do NOT save bookmarks_removed to GlobalStateStore.
                    // These are point-in-time events; replaying them to reconnecting
                    // clients causes destructive false deletions.
                }
            }
            return
        }

        if category == "cookie_apply_result" {
            if case .raw(let raw) = filteredMessage.payload,
               let summary = raw["summary"]?.value as? String {
                if !summary.hasSuffix("0 failed") {
                    log("Cookie apply result from [\(clientId)]: \(summary)")
                }
            }
            return
        }
        
        // Filter incoming browser data based on website list policy
        if category == "browserData" || category == "localStorage" || category == "sessionStorage" || category == "cookies", let payload = message.payload {
            let policy = settings.websiteListPolicy
            
            switch payload {
            case .cookies(let cookies):
                let filtered = filterCookies(cookies, clientId: clientId, policy: policy)
                if filtered.isEmpty {
                    return
                }
                filteredMessage.payload = .cookies(filtered)
                logCookieDomains(filtered, clientId: clientId)
            case .localStorage(let items):
                let filtered = filterStorageItems(items, clientId: clientId, policy: policy)
                if filtered.isEmpty {
                    return
                }
                filteredMessage.payload = .localStorage(filtered)
            case .sessionStorage(let items):
                let filtered = filterStorageItems(items, clientId: clientId, policy: policy)
                if filtered.isEmpty {
                    return
                }
                filteredMessage.payload = .sessionStorage(filtered)
            default: break
            }
        }

        if category == "tabSharing", case .tabs(let tabs) = filteredMessage.payload {
            let limitedTabs = ProLimits.limitedTabsForSharing(tabs, isProUnlocked: AppState.shared.purchaseService.isProUnlocked)
            filteredMessage.payload = .tabs(limitedTabs)
        }
        
        var countStr = ""
        if let payload = filteredMessage.payload {
            switch payload {
            case .bookmarks(let b): 
                countStr = " (\(b.count) items)"
            case .tabs(let t): 
                countStr = " (\(t.count) items)"
                if isSyncing { currentManualSyncStats.tabs += t.count }
            case .cookies(let c): 
                countStr = " (\(c.count) items)"
                if isSyncing { currentManualSyncStats.cookies += c.count }
            case .localStorage(let l): 
                countStr = " (\(l.count) items)"
                if isSyncing { currentManualSyncStats.localStorage += l.count }
            case .sessionStorage(let s): 
                countStr = " (\(s.count) items)"
                if isSyncing { currentManualSyncStats.sessionStorage += s.count }
            default: break
            }
        }
        
        log("Received sync data from [\(clientId)]: \(category)\(countStr)")

        // Apply conflict resolution and persist
        if let payload = filteredMessage.payload {
            persist(payload: payload, category: category, from: clientId, isFullMirror: filteredMessage.isFullMirror ?? false)
            
            if category == "tabSharing", case .tabs(let tabs) = payload {
                let browserId = clientId.components(separatedBy: "-").first ?? clientId
                if let browser = Browser(rawValue: browserId) {
                    let localDeviceName = Host.current().localizedName ?? "Local Device"
                    let localTabs = tabs.map { tab -> BrowserTab in
                        var modifiedTab = tab
                        modifiedTab.deviceName = localDeviceName
                        return modifiedTab
                    }
                    
                    let existingRemote = AppState.shared.remoteTabsCache[browser]?.filter { $0.id.hasPrefix("icloud_") } ?? []
                    AppState.shared.remoteTabsCache[browser] = localTabs + existingRemote
                }
            }
            
            // Auto-sync Notification
            if !isSyncing && AppState.shared.settingsService.general.notifySyncComplete {
                var autoStats = SyncStats()
                switch payload {
                case .bookmarks(let b): 
                    autoStats.bookmarks = b.count
                    let prevMap = Dictionary(preSyncAutoBookmarks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let newMap = Dictionary(b.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    
                    for (id, bm) in newMap {
                        if let p = prevMap[id] {
                            if p.title != bm.title || p.url != bm.url || p.parentId != bm.parentId {
                                autoStats.bookmarksModified += 1
                            }
                        } else {
                            autoStats.bookmarksAdded += 1
                        }
                    }
                    for id in prevMap.keys {
                        if newMap[id] == nil {
                            autoStats.bookmarksDeleted += 1
                        }
                    }
                    
                case .cookies(let c): autoStats.cookies = c.count
                case .localStorage(let l): autoStats.localStorage = l.count
                case .sessionStorage(let s): autoStats.sessionStorage = s.count
                default: break
                }
                
                if !autoStats.isEmpty {
                    var categories: [SyncCategory] = []
                    if autoStats.bookmarksAdded > 0 || autoStats.bookmarksDeleted > 0 || autoStats.bookmarksModified > 0 {
                        categories.append(.bookmarks)
                    }
                    if autoStats.stateItems > 0 { categories.append(.browserData) }
                    
                    if !categories.isEmpty {
                        AppState.shared.notificationService.notifySyncComplete(stats: autoStats, categories: categories)
                    }
                }
            }
            
            let isBookmarkCategory = (category == "bookmarks" || category == "bookmarks_removed" || category == "bookmark_backup")
            let shouldSync = isBookmarkCategory ? (settings.bookmarkAutoSync || settings.automaticSync || isSyncing) : (settings.automaticSync || isSyncing)
            
            if shouldSync {
                // Don't cache bookmarks in GlobalStateStore — they must always reflect
                // the current state of the source browser, not a stale snapshot.
                if category != "bookmarks" && category != "bookmark_backup" {
                    if filteredMessage.site == nil {
                        switch filteredMessage.payload {
                        case .cookies(let cookies):
                            let byDomain = Dictionary(grouping: cookies, by: { $0.domain })
                            for (domain, domainCookies) in byDomain {
                                var msg = filteredMessage
                                msg.site = domain
                                msg.payload = .cookies(domainCookies)
                                GlobalStateStore.shared.save(message: msg)
                            }
                        case .localStorage(let items):
                            let byOrigin = Dictionary(grouping: items, by: { $0.origin })
                            for (origin, originItems) in byOrigin {
                                var msg = filteredMessage
                                msg.site = origin
                                msg.payload = .localStorage(originItems)
                                GlobalStateStore.shared.save(message: msg)
                            }
                        case .sessionStorage(let items):
                            let byOrigin = Dictionary(grouping: items, by: { $0.origin })
                            for (origin, originItems) in byOrigin {
                                var msg = filteredMessage
                                msg.site = origin
                                msg.payload = .sessionStorage(originItems)
                                GlobalStateStore.shared.save(message: msg)
                            }
                        default: break
                        }
                    } else {
                        GlobalStateStore.shared.save(message: filteredMessage)
                    }
                }
                
                // Broadcast cookies to all clients.
                // If any live cookie just beat a tombstone winner, the sender's cookie
                // may have already been deleted by the tombstone broadcast — send it back
                // to everyone (including the sender) so it gets restored.
                if category == "cookies", case .cookies(let cookies) = filteredMessage.payload {
                    let hasResurrection = cookies.contains { c in
                        let removed = c.removed == true
                        return !removed && tombstoneWinnerKeys.contains(cookieVersionKey(c))
                    }
                    if hasResurrection {
                        log("Broadcasting cookies to ALL (including sender) — live cookie resurrects a previously deleted one")
                        daemon?.broadcast(filteredMessage, excluding: nil)
                    } else {
                        daemon?.broadcast(filteredMessage, excluding: clientId)
                    }
                } else {
                    daemon?.broadcast(filteredMessage, excluding: clientId)
                }
            } else if category == "tabSharing" {
                // For tab sharing, we always broadcast to others immediately, without checking auto-sync rules
                daemon?.broadcast(filteredMessage, excluding: clientId)
            } else {
                log("Automatic sync is disabled. Received data but did not broadcast.")
            }
        }
    }

    private func filterStorageItems(_ items: [StorageItem], clientId: String, policy: WebsiteListPolicy) -> [StorageItem] {
        items.filter { item in
            let origin = item.origin.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let host = URL(string: origin)?.host ?? origin
            let cleanHost = host.starts(with: ".") ? String(host.dropFirst()) : host

            let siteMatch = settings.websiteSettings.first { site in
                let listed = site.domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !listed.isEmpty else { return false }
                let cleanListed = listed.starts(with: ".") ? String(listed.dropFirst()) : listed
                return cleanHost == cleanListed || cleanHost.hasSuffix("." + cleanListed) || cleanListed.hasSuffix("." + cleanHost)
            }
            let isListed = siteMatch != nil

            if policy == .allowList && !isListed { return false }
            if policy == .blockList && isListed { return false }

            let strategy = siteMatch?.strategy ?? settings.browserDataSyncStrategy
            if strategy == .primaryWins {
                let source = siteMatch?.sourceBrowser ?? settings.stateSourceBrowser
                if !clientId.lowercased().starts(with: source.rawValue.lowercased()) {
                    return false // Drop because this client is not the primary source
                }
            }
            return true
        }
    }

    private func filterCookies(_ cookies: [SyncCookie], clientId: String, policy: WebsiteListPolicy) -> [SyncCookie] {
        cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanDomain = domain.starts(with: ".") ? String(domain.dropFirst()) : domain

            let siteMatch = settings.websiteSettings.first { site in
                let listed = site.domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !listed.isEmpty else { return false }
                let cleanListed = listed.starts(with: ".") ? String(listed.dropFirst()) : listed
                return cleanDomain == cleanListed || cleanDomain.hasSuffix("." + cleanListed) || cleanListed.hasSuffix("." + cleanDomain)
            }
            let isListed = siteMatch != nil

            if policy == .allowList && !isListed { return false }
            if policy == .blockList && isListed { return false }

            let strategy = siteMatch?.strategy ?? settings.browserDataSyncStrategy
            
            switch strategy {
            case .primaryWins:
                let source = siteMatch?.sourceBrowser ?? settings.stateSourceBrowser
                return clientId.lowercased().starts(with: source.rawValue.lowercased())
            case .latestWins:
                return acceptLatestCookie(cookie, clientId: clientId)
            }
        }
    }

    private func acceptLatestCookie(_ cookie: SyncCookie, clientId: String) -> Bool {
        let key = cookieVersionKey(cookie)
        let incomingTime = cookie.updatedAt ?? 0
        let isTombstone = cookie.removed == true
        
        if let lastTime = latestCookieVersions[key] {
            let lastClient = latestCookieClients[key] ?? ""
            
            // Tombstones must be STRICTLY newer to win — never win via tie-breaker.
            // On equal timestamps, a live cookie always beats a deletion.
            let wins: Bool
            if isTombstone {
                wins = incomingTime > lastTime
            } else {
                wins = incomingTime > lastTime || (incomingTime == lastTime && clientId > lastClient)
            }
            
            if wins {
                latestCookieVersions[key] = incomingTime
                latestCookieClients[key] = clientId
                if isTombstone {
                    tombstoneWinnerKeys.insert(key)
                    log("🔴 DELETING \(cookie.domain)\(cookie.path)::\(cookie.name) (Tombstone from [\(clientId)] time \(incomingTime) strictly > last \(lastTime) from [\(lastClient)])")
                } else {
                    // Live cookie wins — if it was previously a tombstone winner, it's a resurrection
                    tombstoneWinnerKeys.remove(key)
                    log("🟢 ACCEPTING \(cookie.domain)\(cookie.path)::\(cookie.name) (Update from [\(clientId)] time \(incomingTime) > last \(lastTime) from [\(lastClient)])")
                }
                return true
            }
            
            if isTombstone {
                log("⚪️ DROPPING Tombstone for \(cookie.domain)\(cookie.path)::\(cookie.name) from [\(clientId)] (time \(incomingTime) NOT > last \(lastTime) from [\(lastClient)], live cookie wins)")
            } else {
                log("⚪️ DROPPING Update for \(cookie.domain)\(cookie.path)::\(cookie.name) from [\(clientId)] (time \(incomingTime) <= last \(lastTime) from [\(lastClient)])")
            }
            return false
        }
        
        // First time we see this key
        latestCookieVersions[key] = incomingTime
        latestCookieClients[key] = clientId
        if isTombstone {
            tombstoneWinnerKeys.insert(key)
            log("🔴 DELETING \(cookie.domain)\(cookie.path)::\(cookie.name) (Tombstone from [\(clientId)] accepted as first seen. Time: \(incomingTime))")
        }
        return true
    }

    private func logCookieDomains(_ cookies: [SyncCookie], clientId: String) {
        guard !cookies.isEmpty else { return }
        let domains = Dictionary(grouping: cookies) { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return domain.starts(with: ".") ? String(domain.dropFirst()) : domain
        }
        let summary = domains
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.count)" }
            .joined(separator: ", ")
        log("Accepted cookies from [\(clientId)]: \(summary)")

        let githubCookies = cookies.filter { cookie in
            cookie.domain.lowercased().contains("github.com")
        }
        if !githubCookies.isEmpty {
            let details = githubCookies
                .sorted { $0.name < $1.name }
                .map { cookie in
                    "\(cookie.domain)\(cookie.path)::\(cookie.name) hostOnly=\(cookie.hostOnly.map(String.init) ?? "unknown")"
                }
                .joined(separator: ", ")
            log("Accepted GitHub cookie names from [\(clientId)]: \(details)")
        }
    }

    private func cookieVersionKey(_ cookie: SyncCookie) -> String {
        var domain = cookie.domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Normalize: strip leading dot so ".ct106.cc" and "ct106.cc" share the same key
        if domain.hasPrefix(".") { domain = String(domain.dropFirst()) }
        let path = cookie.path.isEmpty ? "/" : cookie.path
        return "\(domain)::\(path)::\(cookie.name)"
    }

    private func buildDeletedBookmarkForest(from deletedBms: [Bookmark], sourceBrowser: String) -> [DeletedBookmark] {
        var nodeDict = [String: DeletedBookmark]()
        let now = Date()
        
        for b in deletedBms {
            nodeDict[b.id] = DeletedBookmark(id: b.id, title: b.title, url: b.url?.flatMap { $0 }, parentId: b.parentId, isFolder: b.isFolder, deletedAt: now, sourceBrowser: sourceBrowser, children: nil)
        }
        
        var roots = [DeletedBookmark]()
        let allIds = Set(deletedBms.map { $0.id })
        
        let rootIds = deletedBms.filter {
            guard let pid = $0.parentId else { return true }
            return !allIds.contains(pid)
        }.map { $0.id }
        
        func buildTree(for id: String) -> DeletedBookmark? {
            guard var node = nodeDict[id] else { return nil }
            let children = deletedBms.filter { $0.parentId == id }
            if !children.isEmpty {
                node.children = children.compactMap { buildTree(for: $0.id) }
            }
            return node
        }
        
        for rootId in rootIds {
            if let rootNode = buildTree(for: rootId) {
                roots.append(rootNode)
            }
        }
        
        return roots
    }

    // MARK: - Persistence

    private func persist(payload: WSPayload, category: String, from clientId: String, isFullMirror: Bool = false) {
        switch payload {
        case .bookmarks(let bookmarks):
            let targetDir = dataDir.appendingPathComponent("bookmarks")
            if category == "bookmarks" {
                save(bookmarks, to: targetDir.appendingPathComponent("\(clientId).json"))
            }
            
            // Also write natively into Safari if the source is a Chromium browser, AND the category is an actual sync (not a backup)
            if category != "bookmark_backup" && !clientId.lowercased().contains("safari") && settings.bookmarkParticipatingBrowsers.contains(.safari) {
#if APP_STORE
                log("Skipping native Safari bookmark write in App Store build")
#else
                // Ensure strategy allows it (oneWay from Safari should not accept writes)
                let strategy = settings.bookmarkSyncStrategy
                let sourceBrowser = settings.bookmarkSourceBrowser
                if !(strategy == .oneWay && sourceBrowser == .safari) {
                    let syncBookmarks = bookmarks.compactMap { b -> SyncBookmark? in
                        let urlStr: String?
                        if let urlOpt = b.url { urlStr = urlOpt } else { urlStr = nil }
                        if !b.isFolder && urlStr == nil { return nil }
                        return SyncBookmark(id: b.id, title: b.title, url: urlStr, parentId: b.parentId, isFolder: b.isFolder, inBookmarksBar: b.inBookmarksBar ?? false)
                    }
                    let sourceName = clientId.components(separatedBy: "-").first ?? clientId
                    self.lastNetworkSyncTime = Date() // Record time to prevent echo
                    let count = safariBookmarks.applyBookmarks(syncBookmarks, from: sourceName, isFullMirror: isFullMirror)
                    if count >= 0 {
                        log("Wrote \(count) bookmarks into Safari natively")
                        // CRITICAL: Immediately update Safari snapshot after writing.
                        // Without this, the next auto-sync will diff the new Safari state
                        // (possibly with changed folder UUIDs) against the old snapshot,
                        // incorrectly detecting mass deletions and broadcasting bookmarks_removed.
                        let freshSafariBms = safariBookmarks.readBookmarks()
                        if !freshSafariBms.isEmpty {
                            let snapshotBms = freshSafariBms.map { b in
                                Bookmark(id: b.id, title: b.title, url: b.url.flatMap { $0 }, parentId: b.parentId, isFolder: b.isFolder, inBookmarksBar: b.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
                            }
                            backupService?.saveSnapshot(bookmarks: snapshotBms, sourceBrowser: "safari")
                            log("Updated Safari snapshot after write (\(snapshotBms.count) items)")
                        }
                    } else {
                        log("Safari is running. Exported HTML for manual import instead.")
                    }
                }
#endif
            }
        case .history(let entries):
            let histDir = dataDir.appendingPathComponent("history")
            save(entries, to: histDir.appendingPathComponent("\(clientId).json"))
        default:
            // For storage/cookie sync, not persisting to disk in MVP
            break
        }
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomicWrite)
        } catch {
            logger.error("Failed to save sync data: \(error)")
        }
    }

    // MARK: - Log

    func log(_ message: String) {
        let entry = SyncLogEntry(date: Date(), message: message)
        syncLog.append(entry)
        logger.info("\(message)")

        // Persist log line
        let logDir = dataDir.appendingPathComponent("logs")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: entry.date)
        let logFile = logDir.appendingPathComponent("sync-\(dateString).log")
        let line = "[\(ISO8601DateFormatter().string(from: entry.date))] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    // MARK: - Internal Write
    
    func recordInternalWrite() {
        self.lastNetworkSyncTime = Date()
    }
}

// MARK: - Sync Log Entry

struct SyncLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
}
