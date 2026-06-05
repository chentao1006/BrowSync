// SyncService.swift
// BrowSync — Orchestrates sync operations between browsers via the Daemon

import Foundation
import os.log

@MainActor
final class SyncService: ObservableObject {
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "SyncService")
    private let dataDir: URL

    @Published var lastSyncDate: Date? = nil
    @Published var isSyncing: Bool = false
    @Published var syncLog: [SyncLogEntry] = []

    var daemon: DaemonServer?
    var settingsService: SettingsService?
    var settings: SyncSettings {
        settingsService?.syncSettings ?? SyncSettings()
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
    private var lastSafariBookmarkSyncTime: Date = Date.distantPast

    init() {
        SafariCleanup.cleanDirtyBookmarks()
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dataDir = appSupport.appendingPathComponent("BrowSync")
        createDataDirectories()
        startSafariBookmarkMonitor()
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
            // Debounce for 2 seconds to avoid multiple triggers on a single save
            if now.timeIntervalSince(self.lastSafariBookmarkSyncTime) > 2.0 {
                self.lastSafariBookmarkSyncTime = now
                
                if self.settings.bookmarkAutoSync || self.settings.automaticSync {
                    self.log("Safari Bookmarks.plist changed! Triggering auto-sync...")
                    Task {
                        // Give Safari a moment to finish writing
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        await self.syncCategory(.bookmarks)
                    }
                }
            }
            
            // Re-arm monitor if file was deleted/replaced (e.g., atomic save)
            let data = self.safariMonitorSource?.data
            if data?.contains(.delete) == true || data?.contains(.rename) == true {
                self.safariMonitorSource?.cancel()
                if self.safariMonitorFileDescriptor != -1 { close(self.safariMonitorFileDescriptor) }
                // Wait briefly for the new file to be created
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.startSafariBookmarkMonitor()
                }
            }
        }
        
        safariMonitorSource?.resume()
        log("Started Safari Bookmarks.plist monitor for real-time sync")
    }

    // MARK: - Sync Now

    func syncNow(categories: Set<SyncCategory>? = nil) async {
        guard !isSyncing else { return }
        isSyncing = true
        
        let connectedClients = daemon?.connectedClients.map { "\($0.browser.rawValue)-\($0.id)" }.joined(separator: ", ") ?? "none"
        log("Starting manual sync... Connected clients: \(connectedClients)")

        let targetCategories = categories ?? settings.enabledCategories
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
        log("Sync complete")
    }

    private func syncCategory(_ category: SyncCategory) async {
        log("Syncing: \(category.displayName)")

        let strategy = settings.bookmarkSyncStrategy
        let sourceBrowser = settings.bookmarkSourceBrowser

        if category == .bookmarks {
            // Determine if we should push Safari to others
            let shouldPushSafari = (strategy == .twoWayMerge || (strategy == .oneWay && sourceBrowser == .safari)) && settings.bookmarkParticipatingBrowsers.contains(.safari)
            
            if shouldPushSafari {
                let safariBms = safariBookmarks.readBookmarks()
                if !safariBms.isEmpty {
                    // Check for deletions comparing to the last backup
                    if let lastSafariBackup = backupService?.backups.first(where: { $0.sourceBrowser == "safari" }),
                       let lastSafariBms = backupService?.getBookmarks(for: lastSafariBackup.id) {
                        
                        let currentIds = Set(safariBms.map { $0.id })
                        let deletedBms = lastSafariBms.filter { !currentIds.contains($0.id) }
                        
                        if !deletedBms.isEmpty {
                            log("Detected \(deletedBms.count) bookmark deletions in Safari, broadcasting removals...")
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
                                GlobalStateStore.shared.save(message: msg)
                            }
                        }
                    }

                    let bookmarks = safariBms.map { b in
                        Bookmark(id: b.id, title: b.title, url: b.url.flatMap { $0 }, parentId: b.parentId, isFolder: b.isFolder, inBookmarksBar: b.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
                    }
                    
                    backupService?.createBackup(bookmarks: bookmarks, sourceBrowser: "safari")
                    
                    var pushMsg = WSMessage(
                        type: .sync,
                        site: "*",
                        category: category.rawValue,
                        payload: .bookmarks(bookmarks),
                        messageId: UUID().uuidString,
                        timestamp: Date().timeIntervalSince1970
                    )
                    pushMsg.isFullMirror = (strategy == .oneWay)
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
        }
    }

    // MARK: - Receive Sync Data

    func receive(message: WSMessage, from clientId: String) {
        guard message.type == .sync, let category = message.category else { return }
        
        var filteredMessage = message
        
        if category == "bookmarks" || category == "bookmark_incremental" || category == "bookmarks_removed" || category == "bookmark_backup" || category == "tabSharing" {
            let browserId = clientId.components(separatedBy: "-").first ?? clientId
            if let browser = Browser(rawValue: browserId) {
                let participating = category == "tabSharing" ? settings.tabSharingParticipatingBrowsers : settings.bookmarkParticipatingBrowsers
                if !participating.contains(browser) {
                    log("Ignored \(category) data from [\(clientId)] because it is not participating in sync.")
                    return
                }
            }
        }

        if category == "bookmarks" || category == "bookmark_incremental" {
            let strategy = settings.bookmarkSyncStrategy
            let sourceBrowser = settings.bookmarkSourceBrowser
            if strategy == .oneWay && sourceBrowser == .safari {
                log("Ignored bookmark from [\(clientId)] due to one-way sync strategy (Safari is primary)")
                return
            }
            if strategy == .oneWay {
                filteredMessage.isFullMirror = true
            }
            if category == "bookmarks", case .bookmarks(let bms) = filteredMessage.payload {
                backupService?.createBackup(bookmarks: bms, sourceBrowser: clientId)
            }
        }
        
        // Handle pre-sync backups sent from Chrome before full-mirror overwrite
        if category == "bookmark_backup" {
            if case .bookmarks(let bms) = filteredMessage.payload {
                let label = "\(clientId)_before_sync"
                backupService?.createBackup(bookmarks: bms, sourceBrowser: label)
                log("Saved pre-sync backup from [\(clientId)]: \(bms.count) items")
            }
            return // Don't process further
        }

        if category == "bookmarks_removed" {
            if case .bookmarksRemoved(let bm) = filteredMessage.payload {
                safariBookmarks.removeBookmark(id: bm.id, title: bm.title, url: bm.url ?? nil)
                log("Removed bookmark '\(bm.title)' from Safari (triggered by [\(clientId)])")
                let shouldSync = settings.bookmarkAutoSync || settings.automaticSync || isSyncing
                if shouldSync {
                    daemon?.broadcast(filteredMessage, excluding: clientId)
                    GlobalStateStore.shared.save(message: filteredMessage)
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
        
        var countStr = ""
        if let payload = filteredMessage.payload {
            switch payload {
            case .bookmarks(let b): countStr = " (\(b.count) items)"
            case .tabs(let t): countStr = " (\(t.count) items)"
            case .cookies(let c): countStr = " (\(c.count) items)"
            case .localStorage(let l): countStr = " (\(l.count) items)"
            case .sessionStorage(let s): countStr = " (\(s.count) items)"
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
                    AppState.shared.remoteTabsCache[browser] = tabs
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
            
            if cookie.removed == true && strategy == .twoWayMerge {
                log("Dropped tombstone for \(cookie.domain)\(cookie.path)::\(cookie.name) from [\(clientId)]: additive-only policy (two-way merge)")
                return false
            }

            switch strategy {
            case .primaryWins:
                let source = siteMatch?.sourceBrowser ?? settings.stateSourceBrowser
                return clientId.lowercased().starts(with: source.rawValue.lowercased())
            case .latestWins:
                return acceptLatestCookie(cookie, clientId: clientId)
            case .twoWayMerge:
                return true
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

    // MARK: - Persistence

    private func persist(payload: WSPayload, category: String, from clientId: String, isFullMirror: Bool = false) {
        switch payload {
        case .bookmarks(let bookmarks):
            let targetDir = dataDir.appendingPathComponent("bookmarks")
            if category == "bookmarks" {
                save(bookmarks, to: targetDir.appendingPathComponent("\(clientId).json"))
            }
            // Also write natively into Safari if the source is a Chromium browser
            if !clientId.lowercased().contains("safari") && settings.bookmarkParticipatingBrowsers.contains(.safari) {
                let syncBookmarks = bookmarks.compactMap { b -> SyncBookmark? in
                    let urlStr: String?
                    if let urlOpt = b.url { urlStr = urlOpt } else { urlStr = nil }
                    if !b.isFolder && urlStr == nil { return nil }
                    return SyncBookmark(id: b.id, title: b.title, url: urlStr, parentId: b.parentId, isFolder: b.isFolder, inBookmarksBar: b.inBookmarksBar ?? false)
                }
                let sourceName = clientId.components(separatedBy: "-").first ?? clientId
                let count = safariBookmarks.applyBookmarks(syncBookmarks, from: sourceName, isFullMirror: isFullMirror)
                if count >= 0 {
                    log("Wrote \(count) bookmarks into Safari natively")
                } else {
                    log("Safari is running. Exported HTML for manual import instead.")
                }
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
}

// MARK: - Sync Log Entry

struct SyncLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
}
