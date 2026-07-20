// SyncService.swift
// BrowSync — Orchestrates sync operations between browsers via the Daemon

import Foundation
import os.log

struct SyncStats {
    var bookmarks: Int = 0
    var bookmarkFolders: Int = 0
    var bookmarksAdded: Int = 0
    var bookmarksDeleted: Int = 0
    var bookmarksModified: Int = 0
    var bookmarkFoldersAdded: Int = 0
    var bookmarkFoldersDeleted: Int = 0
    var bookmarkFoldersModified: Int = 0
    
    var tabs: Int = 0
    var cookies: Int = 0
    var localStorage: Int = 0
    var sessionStorage: Int = 0
    /// Domains/origins included in this sync, for the completion notification.
    var syncedSites = Set<String>()
    
    var stateItems: Int { cookies + localStorage + sessionStorage }
    var isEmpty: Bool {
        bookmarks == 0 && bookmarkFolders == 0 && tabs == 0 && stateItems == 0 &&
        bookmarksAdded == 0 && bookmarksDeleted == 0 && bookmarksModified == 0 &&
        bookmarkFoldersAdded == 0 && bookmarkFoldersDeleted == 0 && bookmarkFoldersModified == 0
    }
}

@MainActor
final class SyncService: ObservableObject {
    private struct PendingEmptyBookmarkSnapshot {
        let message: WSMessage
        let clientId: String
    }
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "SyncService")
    private let dataDir: URL

    @Published var lastSyncDate: Date? = nil
    @Published var isSyncing: Bool = false
    @Published var syncLog: [SyncLogEntry] = []
    /// Bookmark count per browser ID (e.g. "safari", "chrome"). Updated on sync.
    @Published var bookmarkCounts: [String: Int] = [:]
    
    private var currentManualSyncStats = SyncStats()
    private struct SilentBrowserDataPull {
        let requesterClientId: String
        let site: String?
        let expiresAt: Date
    }
    private var silentBrowserDataPulls: [SilentBrowserDataPull] = []
    private var pendingEmptyBookmarkSnapshots: [String: PendingEmptyBookmarkSnapshot] = [:]
    private var forceAcceptedEmptyBookmarkMessageIds = Set<String>()

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
    private var suppressSafariPreSyncBackupUntil: Date = .distantPast
    @Published var missingBookmarkFolders: [String: String] = [:]

    init() {
#if !APP_STORE
        SafariCleanup.cleanDirtyBookmarks()
#endif
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dataDir = appSupport.appendingPathComponent("BrowSync")
        createDataDirectories()
        loadBookmarkCountsFromDisk()
#if !APP_STORE
        startSafariBookmarkMonitor()
#endif
    }

    func bookmarkFolderMissing(_ browser: Browser, folder: String?) -> Bool {
        guard let folder, !folder.isEmpty else { return false }
        let tree = bookmarkTreeSnapshot(for: browser)
        guard !tree.isEmpty else { return false }
        return !BookmarkTreeMerger.folderExists(tree: tree, folderPath: folder)
    }

    func bookmarkFolderKnownExists(_ browser: Browser, folder: String?) -> Bool {
        guard let folder, !folder.isEmpty else { return true }
        let tree = bookmarkTreeSnapshot(for: browser)
        guard !tree.isEmpty else { return false }
        return BookmarkTreeMerger.folderExists(tree: tree, folderPath: folder)
    }

    private func bookmarkTreeSnapshot(for browser: Browser) -> [Bookmark] {
        if browser == .safari {
            if let cachedSafari = backupService?.getSnapshot(sourceBrowser: "safari"), !cachedSafari.isEmpty {
                return cachedSafari
            }
            return safariBookmarks.readBookmarks().map {
                Bookmark(id: $0.id, title: $0.title, url: $0.url.flatMap { $0 }, parentId: $0.parentId, isFolder: $0.isFolder, sortIndex: $0.sortIndex, inBookmarksBar: $0.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
            }
        }
        return backupService?.getSnapshot(sourceBrowser: browser.rawValue) ?? []
    }

    private func markMissingBookmarkFolder(_ browser: Browser, folder: String) {
        missingBookmarkFolders[browser.rawValue] = folder
        log("Bookmark sync skipped for \(browser.displayName): selected folder not found: \(folder)")
        AppState.shared.notificationService.notifyBookmarkSyncFailed(browser: browser, folder: folder)
    }

    private func clearMissingBookmarkFolder(_ browser: Browser) {
        missingBookmarkFolders.removeValue(forKey: browser.rawValue)
    }

    private func folderAdjustedBookmarksForSource(_ bookmarks: [Bookmark], browser: Browser) -> [Bookmark]? {
        let folder = settings.bookmarkFolder(for: browser)
        if let folder, !folder.isEmpty, !BookmarkTreeMerger.folderExists(tree: bookmarks, folderPath: folder) {
            markMissingBookmarkFolder(browser, folder: folder)
            return nil
        }
        clearMissingBookmarkFolder(browser)
        return BookmarkTreeMerger.extractExistingSubtreeAsRoot(sourceTree: bookmarks, folderPath: folder)
    }

    /// Backups deliberately retain the selected folder itself. Sync payloads
    /// flatten that folder to a portable root, but doing so in a backup loses
    /// browser-owned roots such as Chrome's Bookmarks Bar.
    private func backupBookmarksForSource(_ bookmarks: [Bookmark], browser: Browser) -> [Bookmark]? {
        let archivalTree = addingMissingSystemRootsToBackup(bookmarks, browser: browser)
        let folder = settings.bookmarkFolder(for: browser)
        if let folder, !folder.isEmpty, !BookmarkTreeMerger.folderExists(tree: archivalTree, folderPath: folder) {
            markMissingBookmarkFolder(browser, folder: folder)
            return nil
        }
        clearMissingBookmarkFolder(browser)
        return BookmarkTreeMerger.extractExistingSubtreeIncludingRoot(sourceTree: archivalTree, folderPath: folder)
    }

    /// Chrome-family sync snapshots intentionally omit their immutable root
    /// folders, while retaining the canonical parent IDs 1/2/3 on children.
    /// Rebuild those omitted nodes only for the archive so the displayed and
    /// restorable tree includes Bookmarks Bar and the other browser roots.
    private func addingMissingSystemRootsToBackup(_ bookmarks: [Bookmark], browser: Browser) -> [Bookmark] {
        let roots: [(id: String, title: String, inBookmarksBar: Bool)] = [
            ("1", String(localized: "Bookmarks Bar"), true),
            ("2", String(localized: "Other Bookmarks"), false),
            ("3", String(localized: "Mobile Bookmarks"), false)
        ]
        var result = bookmarks
        let existingIDs = Set(bookmarks.map(\.id))
        let parentIDs = Set(bookmarks.compactMap(\.parentId))
        for root in roots where parentIDs.contains(root.id) && !existingIDs.contains(root.id) {
            result.append(
                Bookmark(
                    id: root.id,
                    title: root.title,
                    url: nil,
                    parentId: "0",
                    isFolder: true,
                    sortIndex: nil,
                    inBookmarksBar: root.inBookmarksBar,
                    dateAdded: nil,
                    sourceBrowser: browser
                )
            )
        }
        return result
    }

    private func bookmarkDeletionIsInsideSelectedFolder(_ bookmark: Bookmark, browser: Browser, clientId: String) -> Bool {
        guard let folder = settings.bookmarkFolder(for: browser), !folder.isEmpty else { return true }
        guard let selectedSnapshot = BookmarkTreeMerger.extractExistingSubtreeAsRoot(sourceTree: snapshotForClient(clientId), folderPath: folder) else {
            markMissingBookmarkFolder(browser, folder: folder)
            return false
        }

        if selectedSnapshot.contains(where: { $0.id == bookmark.id }) { return true }
        if let url = bookmarkURL(bookmark)?.lowercased(),
           selectedSnapshot.contains(where: { bookmarkURL($0)?.lowercased() == url }) {
            return true
        }
        if bookmark.isFolder {
            let title = bookmark.title.lowercased()
            return selectedSnapshot.contains { $0.isFolder && $0.title.lowercased() == title }
        }
        return false
    }

    private func sendBookmarkMessage(_ message: WSMessage, to browser: Browser, excluding excludedId: String? = nil) {
        guard let daemon else { return }
        for client in daemon.connectedClients where client.browser == browser && client.id != excludedId {
            var targeted = message
            targeted.targetBookmarkFolder = settings.bookmarkFolder(for: browser)
            daemon.sendWSMessage(targeted, to: client)
        }
    }

    private func broadcastBookmarkMessage(_ message: WSMessage, excluding excludedId: String? = nil) {
        for browser in settings.bookmarkParticipatingBrowsers {
            sendBookmarkMessage(message, to: browser, excluding: excludedId)
        }
    }

    private func pushFinalSafariBookmarksToBookmarkParticipantsIfNeeded() {
        guard settings.bookmarkSyncStrategy == .twoWayMerge,
              settings.bookmarkParticipatingBrowsers.contains(.safari) else {
            return
        }

        var safariBookmarksToPush = safariBookmarks.readBookmarks().map {
            Bookmark(
                id: $0.id,
                title: $0.title,
                url: $0.url.flatMap { $0 },
                parentId: $0.parentId,
                isFolder: $0.isFolder,
                sortIndex: $0.sortIndex,
                inBookmarksBar: $0.inBookmarksBar,
                dateAdded: Date(),
                sourceBrowser: .safari
            )
        }

        if let dedupedBookmarks = BookmarkTreeMerger.deduplicatedBookmarksInFolder(
            tree: safariBookmarksToPush,
            folderPath: settings.bookmarkFolder(for: .safari)
        ), dedupedBookmarks.count != safariBookmarksToPush.count {
            let syncBookmarks = dedupedBookmarks.compactMap { bookmark -> SyncBookmark? in
                let url = bookmark.url.flatMap { $0 }
                if !bookmark.isFolder && url == nil { return nil }
                return SyncBookmark(
                    id: bookmark.id,
                    title: bookmark.title,
                    url: url,
                    parentId: bookmark.parentId,
                    isFolder: bookmark.isFolder,
                    sortIndex: bookmark.sortIndex,
                    inBookmarksBar: bookmark.inBookmarksBar ?? false,
                    dateAdded: bookmark.dateAdded
                )
            }
            let removedCount = safariBookmarksToPush.count - dedupedBookmarks.count
            prepareSafariForIncomingBookmarkMutation()
            recordInternalWrite()
            let writeCount = safariBookmarks.applyBookmarks(syncBookmarks, from: "safari", isFullMirror: true)
            if writeCount >= 0 {
                safariBookmarksToPush = safariBookmarks.readBookmarks().map {
                    Bookmark(
                        id: $0.id,
                        title: $0.title,
                        url: $0.url.flatMap { $0 },
                        parentId: $0.parentId,
                        isFolder: $0.isFolder,
                        inBookmarksBar: $0.inBookmarksBar,
                        dateAdded: Date(),
                        sourceBrowser: .safari
                    )
                }
                log("Removed \(removedCount) duplicate Safari bookmarks inside the selected sync folder before final convergence.")
            } else {
                safariBookmarksToPush = dedupedBookmarks
                log("Prepared duplicate-free Safari bookmark payload, but Safari native write did not complete.")
            }
        }

        guard !safariBookmarksToPush.isEmpty,
              let adjustedBookmarks = folderAdjustedBookmarksForSource(safariBookmarksToPush, browser: .safari) else {
            return
        }

        var message = WSMessage(
            type: .sync,
            site: "*",
            category: SyncCategory.bookmarks.rawValue,
            payload: .bookmarks(adjustedBookmarks),
            messageId: UUID().uuidString,
            timestamp: Date().timeIntervalSince1970
        )
        message.isFullMirror = false

        logSyncPayload(message, direction: "outgoing", clientId: "safari", note: "final-safari-convergence")
        for browser in settings.bookmarkParticipatingBrowsers where browser != .safari {
            sendBookmarkMessage(message, to: browser)
        }
        log("Pushed final Safari bookmark state to non-Safari participants (\(adjustedBookmarks.count) bookmarks)")
    }

    private func snapshotForClient(_ clientId: String) -> [Bookmark] {
        let browserId = clientId.components(separatedBy: "-").first ?? clientId
        return backupService?.getSnapshot(sourceBrowser: clientId)
            ?? backupService?.getSnapshot(sourceBrowser: browserId)
            ?? []
    }

    private func saveSnapshotAliases(bookmarks: [Bookmark], clientId: String) {
        backupService?.saveSnapshot(bookmarks: bookmarks, sourceBrowser: clientId)
        let browserId = clientId.components(separatedBy: "-").first ?? clientId
        if browserId != clientId {
            backupService?.saveSnapshot(bookmarks: bookmarks, sourceBrowser: browserId)
        }
    }

    /// A browser can briefly report an empty tree while its bookmark database is
    /// unavailable. Treating that as a full snapshot would erase every one-way
    /// target, so only accept it when this browser has never had bookmarks.
    private func shouldRejectUnexpectedEmptyBookmarkSnapshot(_ bookmarks: [Bookmark], from clientId: String) -> Bool {
        guard bookmarks.isEmpty else { return false }

        let browserId = clientId.components(separatedBy: "-").first ?? clientId
        let previousCount = max(
            snapshotForClient(clientId).count,
            bookmarkCounts[browserId] ?? 0
        )
        guard previousCount > 0 else { return false }

        log("Rejected empty bookmark snapshot from [\(clientId)]: previous snapshot had \(previousCount) items. Existing bookmarks were left unchanged.")
        return true
    }

    func forceAcceptPendingEmptyBookmarkSnapshot(from clientId: String) {
        guard let pending = pendingEmptyBookmarkSnapshots.removeValue(forKey: clientId) else { return }
        prepareSafariForIncomingBookmarkMutation()
        var forcedMessage = pending.message
        let messageId = forcedMessage.messageId ?? UUID().uuidString
        forcedMessage.messageId = messageId
        forceAcceptedEmptyBookmarkMessageIds.insert(messageId)
        log("User forced synchronization of the empty bookmark snapshot from [\(clientId)].")
        receive(message: forcedMessage, from: pending.clientId)
    }

    /// Capture the target's current selected tree before an incoming browser can
    /// mutate it. This is intentionally invoked immediately before the native
    /// Safari write, never from the post-write monitor callback.
    private func backupCurrentSafariBookmarkFolderBeforeIncomingSync() {
        guard Date() >= suppressSafariPreSyncBackupUntil else {
            log("Skipped Safari automatic backup: this is a follow-up snapshot from an incoming bookmark mutation.")
            return
        }
        let folderPath = settings.bookmarkFolder(for: .safari)
        let bookmarks = safariBookmarks.readBookmarks().map {
            Bookmark(
                id: $0.id,
                title: $0.title,
                url: $0.url,
                parentId: $0.parentId,
                isFolder: $0.isFolder,
                sortIndex: $0.sortIndex,
                inBookmarksBar: $0.inBookmarksBar,
                dateAdded: Date(),
                sourceBrowser: .safari
            )
        }
        guard let selectedBookmarks = backupBookmarksForSource(bookmarks, browser: .safari) else {
            return
        }
        if backupService?.savePreSyncBackup(bookmarks: selectedBookmarks, sourceBrowser: "safari", folderPath: folderPath) == true {
            log("Saved Safari pre-write bookmark backup with \(selectedBookmarks.count) items.")
        } else {
            log("Skipped Safari pre-write bookmark backup because it is empty or unchanged from Safari's previous backup.")
        }
    }

    /// A deletion event is followed by one or more complete browser snapshots.
    /// Capture Safari before the first mutation and prevent those follow-ups from
    /// creating newer, post-mutation Safari backups.
    private func prepareSafariForIncomingBookmarkMutation() {
        backupCurrentSafariBookmarkFolderBeforeIncomingSync()
        suppressSafariPreSyncBackupUntil = Date().addingTimeInterval(15)
    }
    
    deinit {
        safariMonitorSource?.cancel()
        if safariMonitorFileDescriptor != -1 {
            close(safariMonitorFileDescriptor)
        }
    }

    // MARK: - Data Directories

    private func createDataDirectories() {
        let dirs = ["sites", "bookmarks", "history", "logs", "logs/payloads"]
        for dir in dirs {
            let url = dataDir.appendingPathComponent(dir)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func loadBookmarkCountsFromDisk() {
        let bookmarksDir = dataDir.appendingPathComponent("bookmarks")
        guard let files = try? FileManager.default.contentsOfDirectory(at: bookmarksDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            let clientId = file.deletingPathExtension().lastPathComponent
            let browserId = clientId.components(separatedBy: "-").first ?? clientId
            guard let data = try? Data(contentsOf: file),
                  let bookmarks = try? JSONDecoder().decode([Bookmark].self, from: data) else { continue }
            let existing = bookmarkCounts[browserId] ?? 0
            bookmarkCounts[browserId] = max(existing, bookmarks.count)
        }
        // Load Safari count from snapshot (Safari doesn't send JSON like Chromium)
        Task {
            let count = safariBookmarks.readBookmarks().count
            if count > 0 { bookmarkCounts["safari"] = count }
        }
    }
    
    // MARK: - Safari Bookmark Monitor
    
    private func startSafariBookmarkMonitor() {
        SandboxAccessManager.shared.withSafariAccess {
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
                    
                    let isPro = AppState.shared.purchaseService.isProUnlocked
                    let isAutoSyncEnabled = isPro && self.settings.bookmarkAutoSync
                    if isAutoSyncEnabled {
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
    }

    // MARK: - Sync Now

    func syncNow(categories: Set<SyncCategory>? = nil) async -> SyncStats {
        guard !isSyncing else { return SyncStats() }
        isSyncing = true
        currentManualSyncStats = SyncStats()
        
        let connectedClients = daemon?.connectedClients.map { "\($0.browser.rawValue)-\($0.id)" }.joined(separator: ", ") ?? "none"
        log("Starting manual sync... Connected clients: \(connectedClients)")
        AppState.shared.broadcastSettings()

        let targetCategories = categories ?? settings.enabledCategories
        // Clean up any mobile bookmark contamination in Safari before syncing
        if targetCategories.contains(.bookmarks) {
            prepareSafariForIncomingBookmarkMutation()
            safariBookmarks.cleanupMobileBookmarkContamination()
        }
        // Read pre-sync Safari bookmarks on all builds (sandbox access handled inside readBookmarks)
        let preSyncSafariBookmarks = targetCategories.contains(.bookmarks) ? safariBookmarks.readBookmarks() : []
        if !preSyncSafariBookmarks.isEmpty { bookmarkCounts["safari"] = preSyncSafariBookmarks.count }
        for category in SyncCategory.allCases where targetCategories.contains(category) {
            await syncCategory(category)
        }
        
        // Wait for clients to respond before ending manual sync window
        // But don't wait at all if no clients connected
        let hasClients = (daemon?.connectedClients.isEmpty == false)
        if hasClients {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
        }

        if targetCategories.contains(.bookmarks) {
            pushFinalSafariBookmarksToBookmarkParticipantsIfNeeded()
        }

        lastSyncDate = Date()
        isSyncing = false
        if targetCategories.contains(.bookmarks) {
            let postSyncSafariBookmarks = safariBookmarks.readBookmarks()
            currentManualSyncStats.bookmarks = postSyncSafariBookmarks.filter { !$0.isFolder }.count
            currentManualSyncStats.bookmarkFolders = postSyncSafariBookmarks.filter(\.isFolder).count
            if !postSyncSafariBookmarks.isEmpty { bookmarkCounts["safari"] = postSyncSafariBookmarks.count }
            
            let prevMap = Dictionary(uniqueKeysWithValues: preSyncSafariBookmarks.map { ($0.id, $0) })
            let newMap = Dictionary(uniqueKeysWithValues: postSyncSafariBookmarks.map { ($0.id, $0) })
            
            for (id, bm) in newMap {
                if let p = prevMap[id] {
                    if p.title != bm.title || p.url != bm.url || p.parentId != bm.parentId {
                        if bm.isFolder {
                            currentManualSyncStats.bookmarkFoldersModified += 1
                        } else {
                            currentManualSyncStats.bookmarksModified += 1
                        }
                    }
                } else {
                    if bm.isFolder {
                        currentManualSyncStats.bookmarkFoldersAdded += 1
                    } else {
                        currentManualSyncStats.bookmarksAdded += 1
                    }
                }
            }
            for id in prevMap.keys {
                if newMap[id] == nil, let previous = prevMap[id] {
                    if previous.isFolder {
                        currentManualSyncStats.bookmarkFoldersDeleted += 1
                    } else {
                        currentManualSyncStats.bookmarksDeleted += 1
                    }
                }
            }
        }
        log("Sync complete (Bookmarks: \(currentManualSyncStats.bookmarks), Cookies: \(currentManualSyncStats.cookies), LocalStorage: \(currentManualSyncStats.localStorage), SessionStorage: \(currentManualSyncStats.sessionStorage))")
        return currentManualSyncStats
    }

    func prepareSilentBrowserDataPull(to requesterClientId: String, site: String?) {
        pruneExpiredSilentBrowserDataPulls()
        silentBrowserDataPulls.removeAll { $0.requesterClientId == requesterClientId }
        silentBrowserDataPulls.append(
            SilentBrowserDataPull(
                requesterClientId: requesterClientId,
                site: normalizedSite(site),
                expiresAt: Date().addingTimeInterval(12)
            )
        )
    }

    private func pruneExpiredSilentBrowserDataPulls() {
        let now = Date()
        silentBrowserDataPulls.removeAll { $0.expiresAt < now }
    }

    private func silentBrowserDataPullRequesters(for message: WSMessage, from clientId: String) -> [String] {
        guard let category = message.category,
              category == "cookies" || category == "localStorage" || category == "sessionStorage" else {
            return []
        }

        pruneExpiredSilentBrowserDataPulls()
        return silentBrowserDataPulls.compactMap { pull in
            guard pull.requesterClientId != clientId else { return nil }
            guard silentPull(pull, matches: message) else { return nil }
            return pull.requesterClientId
        }
    }

    private func silentPull(_ pull: SilentBrowserDataPull, matches message: WSMessage) -> Bool {
        guard let site = pull.site, site != "*" else { return true }
        if let messageSite = normalizedSite(message.site), messageSite == "*" || host(messageSite, matches: site) {
            return true
        }

        switch message.payload {
        case .cookies(let cookies):
            return cookies.contains { host($0.domain, matches: site) }
        case .localStorage(let items), .sessionStorage(let items):
            return items.contains { item in
                guard let originHost = URL(string: item.origin)?.host else { return host(item.origin, matches: site) }
                return host(originHost, matches: site)
            }
        default:
            return true
        }
    }

    private func normalizedSite(_ site: String?) -> String? {
        guard var site = site?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !site.isEmpty else { return nil }
        if let host = URL(string: site)?.host {
            site = host
        }
        if site.hasPrefix(".") { site.removeFirst() }
        return site
    }

    private func syncedSites(for payload: WSPayload, site: String?) -> Set<String> {
        func displaySite(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "*" else { return nil }
            let host = URL(string: trimmed)?.host ?? trimmed
            let normalized = host.hasPrefix(".") ? String(host.dropFirst()) : host
            return normalized.isEmpty ? nil : normalized
        }

        switch payload {
        case .cookies(let cookies):
            return Set(cookies.compactMap { displaySite($0.domain) })
        case .localStorage(let items), .sessionStorage(let items):
            return Set(items.compactMap { displaySite($0.origin) })
        default:
            return Set(site.flatMap(displaySite).map { [$0] } ?? [])
        }
    }

    private func host(_ host: String, matches site: String) -> Bool {
        let cleanHost = normalizedSite(host) ?? host.lowercased()
        let cleanSite = normalizedSite(site) ?? site.lowercased()
        return cleanHost == cleanSite || cleanHost.hasSuffix("." + cleanSite) || cleanSite.hasSuffix("." + cleanHost)
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
                                logSyncPayload(msg, direction: "outgoing", clientId: "safari", note: "safari-deletion")
                                broadcastBookmarkMessage(msg)
                                // NOTE: Do NOT save bookmarks_removed to GlobalStateStore.
                                // These are point-in-time events; replaying them to reconnecting
                                // clients causes destructive false deletions.
                            }
                            if self.isSyncing {
                                self.currentManualSyncStats.bookmarksDeleted += deletedBms.count
                            }
                        }
                    }

                    let rawBookmarks = safariBms.map { b in
                        Bookmark(id: b.id, title: b.title, url: b.url.flatMap { $0 }, parentId: b.parentId, isFolder: b.isFolder, sortIndex: b.sortIndex, inBookmarksBar: b.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
                    }
                    
                    if let adjustedBookmarks = folderAdjustedBookmarksForSource(rawBookmarks, browser: .safari),
                       let backupBookmarks = backupBookmarksForSource(rawBookmarks, browser: .safari) {
                        let bookmarks = adjustedBookmarks

                        backupService?.savePreSyncBackup(
                            bookmarks: backupBookmarks,
                            sourceBrowser: "safari",
                            folderPath: settings.bookmarkFolder(for: .safari)
                        )
                        backupService?.saveSnapshot(bookmarks: bookmarks, sourceBrowser: "safari")
                        bookmarkCounts["safari"] = bookmarks.count
                        
                        var pushMsg = WSMessage(
                            type: .sync,
                            site: "*",
                            category: category.rawValue,
                            payload: .bookmarks(bookmarks),
                            messageId: UUID().uuidString,
                            timestamp: Date().timeIntervalSince1970
                        )
                        pushMsg.isFullMirror = (strategy == .oneWay) // Root selection keeps the old full mirror behavior; targeted folders are handled per receiver.
                        logSyncPayload(pushMsg, direction: "outgoing", clientId: "safari", note: "push-safari-bookmarks")
                        broadcastBookmarkMessage(pushMsg)
                        log("Pushed \(bookmarks.count) Safari bookmarks to clients")
                        
                        // After pushing, update expected counts for all non-Safari receiving browsers
                        // so the UI reflects what was just sent (avoids stale counts after sync)
                        let targetDir = dataDir.appendingPathComponent("bookmarks")
                        for browser in settings.bookmarkParticipatingBrowsers where browser.id != "safari" {
                            bookmarkCounts[browser.id] = bookmarks.count
                            // Also persist this pushed state so it survives app restart
                            save(bookmarks, to: targetDir.appendingPathComponent("\(browser.id)-main.json"))
                        }
                    } else {
                        log("Skipped Safari bookmark push because its selected sync folder is missing; continuing with other browsers.")
                    }
                } else {
                    log("No Safari bookmarks found to sync")
                }
            }

            // Determine if we should pull from others. In one-way mode we must
            // only pull from the configured source browser; otherwise an empty
            // target browser can become the full-mirror source and wipe data.
            if strategy == .oneWay && sourceBrowser != .safari {
                guard settings.bookmarkParticipatingBrowsers.contains(sourceBrowser) else {
                    log("Skipped one-way bookmark pull because \(sourceBrowser.displayName) is not participating in sync.")
                    return
                }
                let requestMessage = WSMessage(
                    type: .sync,
                    site: "*",
                    category: category.rawValue,
                    payload: nil,
                    messageId: UUID().uuidString,
                    timestamp: Date().timeIntervalSince1970
                )
                logSyncPayload(requestMessage, direction: "outgoing", clientId: sourceBrowser.id, note: "bookmark-pull-request")
                daemon?.broadcast(requestMessage, participatingBrowsers: [sourceBrowser])
            } else if strategy == .twoWayMerge {
                let requestMessage = WSMessage(
                    type: .sync,
                    site: "*",
                    category: category.rawValue,
                    payload: nil,
                    messageId: UUID().uuidString,
                    timestamp: Date().timeIntervalSince1970
                )
                logSyncPayload(requestMessage, direction: "outgoing", clientId: "all-bookmark-participants", note: "bookmark-pull-request")
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
            logSyncPayload(requestMessage, direction: "outgoing", clientId: "all", note: "pull-request")
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
                        logSyncPayload(cleaned, direction: "outgoing", clientId: "cached-state", note: "cached-live-cookies")
                        daemon?.broadcast(cleaned)
                    } else {
                        logSyncPayload(msg, direction: "outgoing", clientId: "cached-state", note: "cached-state")
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
        logSyncPayload(message, direction: "incoming", clientId: clientId, note: "raw-received")

        if category == "bookmark_folder_missing" {
            let browserId = clientId.components(separatedBy: "-").first ?? clientId
            if let browser = Browser(rawValue: browserId),
               case .raw(let raw) = message.payload,
               let folder = raw["folder"]?.value as? String {
                markMissingBookmarkFolder(browser, folder: folder)
            }
            return
        }
        
        // Capture previous snapshot for auto-sync notifications before it gets overwritten.
        let preSyncAutoBookmarks = snapshotForClient(clientId)
        
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

        if isBookmarkCategory && strategy == .oneWay && !isClient(clientId, from: sourceBrowser) {
            log("Ignored \(category) from [\(clientId)] due to one-way sync strategy (\(sourceBrowser.displayName) is primary)")
            
            // Even though we ignore it for syncing, we MUST update this client's local snapshot/count
            // so the UI reflects its actual state (e.g. user deleted a bookmark in Chrome).
            if category == "bookmarks_removed" || category == "bookmark_incremental" {
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let req = WSMessage(
                        type: .sync,
                        site: "*",
                        category: "bookmarks",
                        payload: nil,
                        messageId: UUID().uuidString,
                        timestamp: Date().timeIntervalSince1970
                    )
                    await MainActor.run {
                        if let b = Browser(rawValue: clientId.components(separatedBy: "-").first ?? clientId) {
                            self.daemon?.broadcast(req, participatingBrowsers: [b])
                        }
                    }
                }
            }
            return
        }
        if strategy == .oneWay && category == "bookmarks" {
            // In one-way sync, the target should exactly mirror the source.
            // Setting isFullMirror = true ensures the target prunes local items not present in the payload.
            filteredMessage.isFullMirror = true
        }
        if category == "bookmark_backup", case .bookmarks(let bms) = filteredMessage.payload {
            // Browser extensions send this immediately before mutating their
            // local tree. Keep it both as the deletion-detection snapshot and
            // as a user-visible, restorable automatic backup.
            guard !shouldRejectUnexpectedEmptyBookmarkSnapshot(bms, from: clientId) else { return }
            let browserId = clientId.components(separatedBy: "-").first ?? clientId
            if let browser = Browser(rawValue: browserId),
               let backupBookmarks = backupBookmarksForSource(bms, browser: browser) {
                let didSaveBackup = backupService?.savePreSyncBackup(
                    bookmarks: backupBookmarks,
                    sourceBrowser: clientId,
                    folderPath: settings.bookmarkFolder(for: browser)
                ) ?? false
                log(didSaveBackup
                    ? "Saved pre-write bookmark backup from [\(clientId)] with \(backupBookmarks.count) items; backup is not broadcast as sync data."
                    : "Skipped pre-write bookmark backup from [\(clientId)] because it is empty or unchanged from that browser's previous backup.")
            }
            saveSnapshotAliases(bookmarks: bms, clientId: clientId)
            bookmarkCounts[browserId] = bms.count
            return
        }
        if category == "bookmarks", case .bookmarks(let bms) = filteredMessage.payload {
            let wasForceAccepted = filteredMessage.messageId.map {
                forceAcceptedEmptyBookmarkMessageIds.remove($0) != nil
            } ?? false
            if !wasForceAccepted, shouldRejectUnexpectedEmptyBookmarkSnapshot(bms, from: clientId) {
                let browserId = clientId.components(separatedBy: "-").first ?? clientId
                let previousCount = max(preSyncAutoBookmarks.count, bookmarkCounts[browserId] ?? 0)
                pendingEmptyBookmarkSnapshots[clientId] = PendingEmptyBookmarkSnapshot(message: filteredMessage, clientId: clientId)
                AppState.shared.notificationService.notifyUnexpectedEmptyBookmarkSnapshot(
                    source: clientId,
                    previousCount: previousCount
                )
                return
            }
            let browserId = clientId.components(separatedBy: "-").first ?? clientId
            let browser = Browser(rawValue: browserId)
            guard let sourceBrowserForFolder = browser else {
                return
            }

            // Explicit bookmarks_removed is preferred, but manual sync may only receive
            // a fresh full snapshot. Diff it against the previous same-browser snapshot
            // with URL/title fallbacks so offline Chrome-family deletions do not get
            // resurrected by Safari's older tree.
            let sanitizedBookmarks = sanitizeIncomingBookmarksForSafari(bms, from: clientId)
            if sanitizedBookmarks.count != bms.count {
                log("Sanitized \(bms.count - sanitizedBookmarks.count) non-Safari bookmark nodes from [\(clientId)] before snapshot/persist")
                filteredMessage.payload = .bookmarks(sanitizedBookmarks)
                logSyncPayload(filteredMessage, direction: "incoming", clientId: clientId, note: "sanitized-bookmarks")
            }
            guard let sourceAdjustedBookmarks = folderAdjustedBookmarksForSource(sanitizedBookmarks, browser: sourceBrowserForFolder) else {
                return
            }
            let previousForDeletion = BookmarkTreeMerger.extractExistingSubtreeAsRoot(
                sourceTree: preSyncAutoBookmarks,
                folderPath: settings.bookmarkFolder(for: sourceBrowserForFolder)
            ) ?? preSyncAutoBookmarks
            processDeletedBookmarksFromFullSnapshot(previous: previousForDeletion, current: sourceAdjustedBookmarks, from: clientId)
            saveSnapshotAliases(bookmarks: sanitizedBookmarks, clientId: clientId)
            filteredMessage.payload = .bookmarks(sourceAdjustedBookmarks)
        }

        if category == "bookmarks_removed" {
            if case .bookmarksRemoved(let bm) = filteredMessage.payload {
                let browserId = clientId.components(separatedBy: "-").first ?? clientId
                if let browser = Browser(rawValue: browserId),
                   !bookmarkDeletionIsInsideSelectedFolder(bm, browser: browser, clientId: clientId) {
                    log("Ignored bookmark deletion from [\(clientId)] outside selected sync folder: \(bm.title)")
                    return
                }
                backupService?.addDeletedBookmarks([
                    DeletedBookmark(
                        id: bm.id,
                        title: bm.title,
                        url: bm.url ?? nil,
                        parentId: bm.parentId,
                        isFolder: bm.isFolder,
                        deletedAt: Date(),
                        sourceBrowser: clientId,
                        children: nil
                    )
                ])
                prepareSafariForIncomingBookmarkMutation()
                safariBookmarks.removeBookmark(id: bm.id, title: bm.title, url: bm.url ?? nil)
                log("Removed bookmark '\(bm.title)' from Safari (triggered by [\(clientId)])")
                // Refresh Safari count after removal
                let updatedCount = safariBookmarks.readBookmarks().count
                if updatedCount > 0 { bookmarkCounts["safari"] = updatedCount }

                if !isSyncing && AppState.shared.settingsService.general.notifySyncComplete {
                    var deletionStats = SyncStats()
                    deletionStats.bookmarksDeleted = bm.isFolder ? 0 : 1
                    deletionStats.bookmarkFoldersDeleted = bm.isFolder ? 1 : 0
                    AppState.shared.notificationService.notifyAutoSyncComplete(
                        stats: deletionStats,
                        categories: [.bookmarks]
                    )
                }
                
                let isPro = AppState.shared.purchaseService.isProUnlocked
                let shouldSync = (isPro && settings.bookmarkAutoSync) || isSyncing
                if shouldSync {
                    logSyncPayload(filteredMessage, direction: "outgoing", clientId: clientId, note: "rebroadcast-bookmark-removal")
                    broadcastBookmarkMessage(filteredMessage, excluding: nil)
                    // NOTE: Do NOT save bookmarks_removed to GlobalStateStore.
                    // These are point-in-time events; replaying them to reconnecting
                    // clients causes destructive false deletions.
                    
                    // Request a fresh sync from all clients to update counts and snapshots accurately
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s debounce to let extensions process deletions
                        let req = WSMessage(
                            type: .sync,
                            site: "*",
                            category: "bookmarks",
                            payload: nil,
                            messageId: UUID().uuidString,
                            timestamp: Date().timeIntervalSince1970
                        )
                        await MainActor.run {
                            self.logSyncPayload(req, direction: "outgoing", clientId: "all-bookmark-participants", note: "post-removal-pull-request")
                            self.daemon?.broadcast(req, participatingBrowsers: self.settings.bookmarkParticipatingBrowsers)
                        }
                    }
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
            let involvedSites = syncedSites(for: payload, site: filteredMessage.site)
            if isSyncing {
                currentManualSyncStats.syncedSites.formUnion(involvedSites)
            }
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
                autoStats.syncedSites = syncedSites(for: payload, site: filteredMessage.site)
                switch payload {
                case .bookmarks(let bookmarks):
                    // A full tree is a state refresh, not an event log. It is
                    // used for content/order sync but must never manufacture
                    // add/delete notifications from transient differences.
                    // It can still safely report an actual rename, move, or
                    // reordering of a bookmark that exists in both snapshots.
                    populateAutomaticBookmarkChangeStats(
                        previous: preSyncAutoBookmarks,
                        current: bookmarks,
                        stats: &autoStats
                    )
                    
                case .cookies(let c): autoStats.cookies = c.count
                case .localStorage(let l): autoStats.localStorage = l.count
                case .sessionStorage(let s): autoStats.sessionStorage = s.count
                default: break
                }
                
                if !autoStats.isEmpty {
                    var categories: [SyncCategory] = []
                    if autoStats.bookmarksAdded > 0 || autoStats.bookmarksDeleted > 0 || autoStats.bookmarksModified > 0 ||
                        autoStats.bookmarkFoldersAdded > 0 || autoStats.bookmarkFoldersDeleted > 0 || autoStats.bookmarkFoldersModified > 0 {
                        categories.append(.bookmarks)
                    }
                    if autoStats.stateItems > 0 { categories.append(.browserData) }
                    
                    if !categories.isEmpty {
                        AppState.shared.notificationService.notifyAutoSyncComplete(stats: autoStats, categories: categories)
                    }
                }
            }
            
            let isBookmarkCategory = (category == "bookmarks" || category == "bookmarks_removed" || category == "bookmark_backup")
            let isPro = AppState.shared.purchaseService.isProUnlocked
            let effectiveBookmarkAutoSync = isPro && settings.bookmarkAutoSync
            let effectiveAutomaticSync = isPro && settings.automaticSync
            let shouldSync = isBookmarkCategory ? (effectiveBookmarkAutoSync || isSyncing) : (effectiveAutomaticSync || isSyncing)
            
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
                } else if isBookmarkCategory {
                    broadcastBookmarkMessage(filteredMessage, excluding: clientId)
                } else {
                    daemon?.broadcast(filteredMessage, excluding: clientId)
                }
            } else if category == "tabSharing" {
                // For tab sharing, we always broadcast to others immediately, without checking auto-sync rules
                daemon?.broadcast(filteredMessage, excluding: clientId)
            } else {
                for requesterId in silentBrowserDataPullRequesters(for: filteredMessage, from: clientId) {
                    logSyncPayload(filteredMessage, direction: "outgoing", clientId: requesterId, note: "silent-browser-data-pull-response")
                    daemon?.send(filteredMessage, toClientId: requesterId)
                }
                log("Automatic sync is disabled. Received data but did not broadcast.")
            }
        }
    }

    private func filterStorageItems(_ items: [StorageItem], clientId: String, policy: WebsiteListPolicy) -> [StorageItem] {
        items.filter { item in
            let origin = item.origin.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let host = URL(string: origin)?.host ?? origin
            let cleanHost = host.starts(with: ".") ? String(host.dropFirst()) : host
            guard !isSystemSyncDisabled(cleanHost) else { return false }

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
            guard !isSystemSyncDisabled(cleanDomain) else { return false }

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

    /// System security exclusions are never overridden by the user-facing site policy.
    private func isSystemSyncDisabled(_ host: String) -> Bool {
        let normalizedHost = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return WebsiteSyncSetting.syncDisabledDomains.contains { domain in
            let normalizedDomain = domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedDomain.isEmpty else { return false }
            return normalizedHost == normalizedDomain || normalizedHost.hasSuffix("." + normalizedDomain)
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

    private func isClient(_ clientId: String, from browser: Browser) -> Bool {
        let clientBrowserId = clientId.components(separatedBy: "-").first?.lowercased() ?? clientId.lowercased()
        return clientBrowserId == browser.id.lowercased()
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

    private func processDeletedBookmarksFromFullSnapshot(previous: [Bookmark], current: [Bookmark], from clientId: String) {
        guard !clientId.lowercased().contains("safari"),
              !previous.isEmpty,
              !current.isEmpty else { return }
        // A complete tree is not a deletion event. Browsers can briefly omit
        // entries while moving/reordering them, and browser-owned roots are
        // represented differently across snapshots. Inferring deletion here
        // previously turned a harmless move into a destructive broadcast.
        // Explicit `bookmarks_removed` events are the sole deletion authority.
        log("Ignored possible deletions from [\(clientId)] full snapshot; waiting for an explicit bookmarks_removed event.")
    }

    private func bookmarkURL(_ bookmark: Bookmark) -> String? {
        bookmark.url.flatMap { $0 }
    }

    /// Full bookmark trees are state refreshes, not event logs. They may omit
    /// a root or briefly differ while a browser is writing, so automatic
    /// notifications may only report safe updates to a bookmark found in both
    /// snapshots. Explicit `bookmarks_removed` messages remain the sole
    /// source of deletion notifications.
    private func populateAutomaticBookmarkChangeStats(previous: [Bookmark], current: [Bookmark], stats: inout SyncStats) {
        func isSystemRoot(_ bookmark: Bookmark) -> Bool {
            let id = bookmark.id.lowercased()
            return ["0", "1", "2", "3"].contains(id) ||
                (id.hasPrefix("firefox-") && id.hasSuffix("-root")) ||
                id.hasPrefix("browsync-root-")
        }

        func parentPaths(in tree: [Bookmark]) -> [String: String] {
            let byID = Dictionary(tree.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var cache: [String: String] = [:]
            func path(for bookmark: Bookmark, visited: Set<String> = []) -> String {
                if let cached = cache[bookmark.id] { return cached }
                if isSystemRoot(bookmark) {
                    // Native roots are often not included in browser payloads.
                    // Retain their semantic identity so a cross-root move can
                    // still be reported without relying on an unstable UUID.
                    let root: String
                    switch bookmark.id.lowercased() {
                    case "1", "browsync-root-bar": root = "bookmarks-bar"
                    case "2", "browsync-root-other": root = "other-bookmarks"
                    case "3", "browsync-root-mobile": root = "mobile-bookmarks"
                    default: root = "root"
                    }
                    cache[bookmark.id] = root
                    return root
                }
                guard !visited.contains(bookmark.id) else { return bookmark.title }
                let parentPath: String
                if let parentID = bookmark.parentId {
                    if let parent = byID[parentID] {
                        parentPath = path(for: parent, visited: visited.union([bookmark.id]))
                    } else {
                        // Browser payloads often omit native root nodes. Known
                        // IDs still identify the three standard roots; unknown
                        // IDs deliberately collapse to one neutral root instead
                        // of creating a false-positive move.
                        switch parentID {
                        case "1": parentPath = "bookmarks-bar"
                        case "2": parentPath = "other-bookmarks"
                        case "3": parentPath = "mobile-bookmarks"
                        default: parentPath = "root"
                        }
                    }
                } else {
                    parentPath = "root"
                }
                let result = "\(parentPath)/\(bookmark.title)"
                cache[bookmark.id] = result
                return result
            }
            return Dictionary(uniqueKeysWithValues: tree.map { bookmark in
                let parentPath: String
                if let parentID = bookmark.parentId, let parent = byID[parentID] {
                    parentPath = path(for: parent)
                } else if let parentID = bookmark.parentId {
                    switch parentID {
                    case "1": parentPath = "bookmarks-bar"
                    case "2": parentPath = "other-bookmarks"
                    case "3": parentPath = "mobile-bookmarks"
                    default: parentPath = "root"
                    }
                } else {
                    parentPath = "root"
                }
                return (bookmark.id, parentPath)
            })
        }

        /// Moving one item shifts the numeric index of its siblings. Compare
        /// the relative order instead, so only the item that actually moved is
        /// reported as adjusted. With unique keys, the unchanged items form a
        /// longest increasing subsequence of their old positions.
        func reorderedKeys(
            previous: [Bookmark],
            current: [Bookmark],
            previousParents: [String: String],
            currentParents: [String: String],
            key: (Bookmark) -> String?
        ) -> Set<String> {
            func orderedKeys(in tree: [Bookmark], parents: [String: String]) -> [String: [String]] {
                var entries: [String: [(key: String, order: Int, position: Int)]] = [:]
                var seen = Set<String>()
                for (position, bookmark) in tree.enumerated() {
                    guard let itemKey = key(bookmark), seen.insert(itemKey).inserted,
                          let parent = parents[bookmark.id] else { continue }
                    entries[parent, default: []].append((itemKey, bookmark.sortIndex ?? position, position))
                }
                return entries.mapValues { values in
                    values.sorted {
                        $0.order == $1.order ? $0.position < $1.position : $0.order < $1.order
                    }.map(\.key)
                }
            }

            let oldByParent = orderedKeys(in: previous, parents: previousParents)
            let newByParent = orderedKeys(in: current, parents: currentParents)
            var changed = Set<String>()
            for parent in Set(oldByParent.keys).intersection(newByParent.keys) {
                guard let old = oldByParent[parent], let new = newByParent[parent] else { continue }
                let oldPositions = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($0.element, $0.offset) })
                let sharedNew = new.filter { oldPositions[$0] != nil }
                guard sharedNew.count > 1 else { continue }

                var tails: [Int] = []
                var tailIndices: [Int] = []
                var predecessors = Array(repeating: -1, count: sharedNew.count)
                for (index, itemKey) in sharedNew.enumerated() {
                    guard let position = oldPositions[itemKey] else { continue }
                    var low = 0
                    var high = tails.count
                    while low < high {
                        let middle = (low + high) / 2
                        if tails[middle] < position { low = middle + 1 } else { high = middle }
                    }
                    if low > 0 { predecessors[index] = tailIndices[low - 1] }
                    if low == tails.count {
                        tails.append(position)
                        tailIndices.append(index)
                    } else {
                        tails[low] = position
                        tailIndices[low] = index
                    }
                }
                var unchanged = Set<String>()
                var index = tailIndices.last ?? -1
                while index >= 0 {
                    unchanged.insert(sharedNew[index])
                    index = predecessors[index]
                }
                changed.formUnion(Set(sharedNew).subtracting(unchanged))
            }
            return changed
        }

        let previousBookmarks = Dictionary(
            previous.compactMap { bookmark in bookmarkURL(bookmark).map { ($0.lowercased(), bookmark) } },
            uniquingKeysWith: { first, _ in first }
        )
        let currentBookmarks = Dictionary(
            current.compactMap { bookmark in bookmarkURL(bookmark).map { ($0.lowercased(), bookmark) } },
            uniquingKeysWith: { first, _ in first }
        )
        let previousParentPaths = parentPaths(in: previous)
        let currentParentPaths = parentPaths(in: current)
        let reorderedBookmarks = reorderedKeys(
            previous: previous,
            current: current,
            previousParents: previousParentPaths,
            currentParents: currentParentPaths,
            key: { bookmarkURL($0)?.lowercased() }
        )
        // A newly present URL is non-destructive and can be reported safely.
        // Missing URLs are intentionally *not* inferred as removals here: a
        // browser may expose a transient or partial tree while it is writing.
        stats.bookmarksAdded = Set(currentBookmarks.keys)
            .subtracting(previousBookmarks.keys)
            .count
        stats.bookmarksModified = Set(currentBookmarks.keys).intersection(previousBookmarks.keys).reduce(into: 0) { count, url in
            guard let old = previousBookmarks[url], let new = currentBookmarks[url] else { return }
            let reordered = reorderedBookmarks.contains(url)
            let moved = previousParentPaths[old.id] != currentParentPaths[new.id]
            if old.title != new.title || reordered || moved { count += 1 }
        }

        let previousFolders = Dictionary(
            previous.filter { $0.isFolder && !isSystemRoot($0) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentFolders = Dictionary(
            current.filter { $0.isFolder && !isSystemRoot($0) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let previousFolderLocations = Set(previousFolders.values.compactMap { folder -> String? in
            previousParentPaths[folder.id].map { "\($0)/\(folder.title)" }
        })
        // An unknown folder ID at a previously unseen location is a safe add.
        // Do not turn a missing folder into a deletion from a full snapshot.
        stats.bookmarkFoldersAdded = currentFolders.values.reduce(into: 0) { count, folder in
            guard previousFolders[folder.id] == nil,
                  let parentPath = currentParentPaths[folder.id],
                  !previousFolderLocations.contains("\(parentPath)/\(folder.title)")
            else { return }
            count += 1
        }
        let reorderedFolders = reorderedKeys(
            previous: Array(previousFolders.values),
            current: Array(currentFolders.values),
            previousParents: previousParentPaths,
            currentParents: currentParentPaths,
            key: { $0.id }
        )
        stats.bookmarkFoldersModified = Set(currentFolders.keys).intersection(previousFolders.keys).reduce(into: 0) { count, id in
            guard let old = previousFolders[id], let new = currentFolders[id] else { return }
            let reordered = reorderedFolders.contains(id)
            let moved = previousParentPaths[old.id] != currentParentPaths[new.id]
            if old.title != new.title || reordered || moved { count += 1 }
        }
    }

    private func folderKey(_ bookmark: Bookmark) -> String {
        "\(bookmark.parentId ?? "")|\(bookmark.title.lowercased())"
    }

    private func isBrowserMobileRoot(_ bookmark: Bookmark) -> Bool {
        guard bookmark.isFolder, bookmarkURL(bookmark) == nil else { return false }
        let id = bookmark.id.lowercased()
        return bookmark.id == "3" || id.hasPrefix("mobile")
    }

    private func sanitizeIncomingBookmarksForSafari(_ bookmarks: [Bookmark], from clientId: String) -> [Bookmark] {
        guard !clientId.lowercased().contains("safari") else { return bookmarks }

        let rootIds = Set(["0", "1", "2", "3"])
        let bookmarksById = Dictionary(bookmarks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let childrenByParent = Dictionary(grouping: bookmarks, by: { $0.parentId ?? "" })
        let browserId = clientId.components(separatedBy: "-").first ?? clientId
        let browser = Browser(rawValue: browserId)
        let selectedFolderIds: Set<String> = {
            guard let browser, let folder = settings.bookmarkFolder(for: browser) else { return [] }
            return BookmarkTreeMerger.idsInFolderIncludingRoot(tree: bookmarks, folderPath: folder)
        }()

        func deletedSignatures(from items: [DeletedBookmark]) -> (folders: Set<String>, urls: Set<String>) {
            var folderSignatures = Set<String>()
            var urls = Set<String>()
            let recentCutoff = Date().addingTimeInterval(-24 * 60 * 60)

            func visit(_ item: DeletedBookmark) {
                if item.deletedAt >= recentCutoff {
                    if item.isFolder, item.url == nil {
                        let parent = item.parentId ?? ""
                        folderSignatures.insert("\(parent)|\(item.title.lowercased())")
                    } else if let url = item.url?.lowercased() {
                        urls.insert(url)
                    }
                }
                item.children?.forEach(visit)
            }

            items.forEach(visit)
            return (folderSignatures, urls)
        }

        let deleted = deletedSignatures(from: backupService?.deletedBookmarks ?? [])

        func isDeletedByTombstone(_ bookmark: Bookmark) -> Bool {
            if bookmark.isFolder, bookmarkURL(bookmark) == nil {
                let parent = bookmark.parentId ?? ""
                return deleted.folders.contains("\(parent)|\(bookmark.title.lowercased())")
            }
            if let url = bookmarkURL(bookmark)?.lowercased() {
                return deleted.urls.contains(url)
            }
            return false
        }

        func shouldDropNode(_ bookmark: Bookmark) -> Bool {
            if rootIds.contains(bookmark.id) { return true }
            if isBrowserMobileRoot(bookmark) { return true }
            if !selectedFolderIds.contains(bookmark.id), isDeletedByTombstone(bookmark) { return true }
            return false
        }

        func shouldDropDescendants(of bookmark: Bookmark) -> Bool {
            if selectedFolderIds.contains(bookmark.id) { return false }
            return bookmark.id == "0" ||
            bookmark.id == "3" ||
            isBrowserMobileRoot(bookmark) ||
            isDeletedByTombstone(bookmark)
        }

        var excludedIds = Set(bookmarks.filter(shouldDropNode).map(\.id))
        var queue = bookmarks.filter(shouldDropDescendants).map(\.id)
        while let current = queue.popLast() {
            for child in childrenByParent[current] ?? [] {
                if excludedIds.insert(child.id).inserted {
                    queue.append(child.id)
                }
            }
        }

        guard !excludedIds.isEmpty else { return bookmarks }

        return bookmarks.filter { bookmark in
            if excludedIds.contains(bookmark.id) { return false }
            if let parentId = bookmark.parentId, excludedIds.contains(parentId) { return false }
            if let parentId = bookmark.parentId, let parent = bookmarksById[parentId], shouldDropDescendants(of: parent) { return false }
            return true
        }
    }

    // MARK: - Persistence

    private func persist(payload: WSPayload, category: String, from clientId: String, isFullMirror: Bool = false) {
        switch payload {
        case .bookmarks(let bookmarks):
            let targetDir = dataDir.appendingPathComponent("bookmarks")
            if category == "bookmarks" || category == "bookmark_backup" {
                save(bookmarks, to: targetDir.appendingPathComponent("\(clientId).json"))
                // Update bookmark count for this browser
                let browserId = clientId.components(separatedBy: "-").first ?? clientId
                bookmarkCounts[browserId] = bookmarks.count
            }
            let isPro = AppState.shared.purchaseService.isProUnlocked
            let shouldSyncToSafari = ((isPro && settings.bookmarkAutoSync) || isSyncing)
            
            // Also write natively into Safari if the source is a Chromium browser, AND the category is an actual sync (not a backup)
            if shouldSyncToSafari && category != "bookmark_backup" && !clientId.lowercased().contains("safari") && settings.bookmarkParticipatingBrowsers.contains(.safari) {
#if APP_STORE
                // In App Store sandbox, writing is gated by the security-scoped bookmark
                // that the user granted via requestSafariAccess(). applyBookmarks() and
                // readBookmarks() both call withSafariAccess internally.
                if SandboxAccessManager.shared.hasSafariAccess {
                    let strategy = settings.bookmarkSyncStrategy
                    let sourceBrowser = settings.bookmarkSourceBrowser
                    if !(strategy == .oneWay && sourceBrowser == .safari) {
                        var finalSyncBookmarks: [SyncBookmark] = []
                        var finalIsFullMirror = isFullMirror
                        
                        if let targetFolder = settings.bookmarkFolder(for: .safari) {
                            let safariTargetBms = safariBookmarks.readBookmarks().map { b in
                                Bookmark(id: b.id, title: b.title, url: b.url.flatMap { $0 }, parentId: b.parentId, isFolder: b.isFolder, sortIndex: b.sortIndex, inBookmarksBar: b.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
                            }
                            let mergedBookmarks = strategy == .oneWay
                                ? BookmarkTreeMerger.replaceExistingFolderContents(sourceTree: bookmarks, targetTree: safariTargetBms, targetFolderPath: targetFolder)
                                : BookmarkTreeMerger.mergeIntoExistingFolder(sourceTree: bookmarks, targetTree: safariTargetBms, targetFolderPath: targetFolder)
                            guard let finalBookmarksToSend = mergedBookmarks else {
                                markMissingBookmarkFolder(.safari, folder: targetFolder)
                                return
                            }
                            finalIsFullMirror = strategy == .oneWay
                            finalSyncBookmarks = finalBookmarksToSend.compactMap { b -> SyncBookmark? in
                                let urlStr: String?
                                if let urlOpt = b.url { urlStr = urlOpt } else { urlStr = nil }
                                if !b.isFolder && urlStr == nil { return nil }
                                return SyncBookmark(id: b.id, title: b.title, url: urlStr, parentId: b.parentId, isFolder: b.isFolder, sortIndex: b.sortIndex, inBookmarksBar: b.inBookmarksBar ?? false, dateAdded: b.dateAdded)
                            }
                    } else {
                        finalSyncBookmarks = bookmarks.compactMap { b -> SyncBookmark? in
                                let urlStr: String?
                                if let urlOpt = b.url { urlStr = urlOpt } else { urlStr = nil }
                                if !b.isFolder && urlStr == nil { return nil }
                                return SyncBookmark(id: b.id, title: b.title, url: urlStr, parentId: b.parentId, isFolder: b.isFolder, sortIndex: b.sortIndex, inBookmarksBar: b.inBookmarksBar ?? false, dateAdded: b.dateAdded)
                            }
                        }
                        
                        prepareSafariForIncomingBookmarkMutation()
                        let sourceName = clientId.components(separatedBy: "-").first ?? clientId
                        self.lastNetworkSyncTime = Date()
                        let count = safariBookmarks.applyBookmarks(finalSyncBookmarks, from: sourceName, isFullMirror: finalIsFullMirror)
                        if count >= 0 {
                            log("Wrote \(count) bookmarks into Safari natively (App Store)")
                            let freshSafariBms = safariBookmarks.readBookmarks()
                            if !freshSafariBms.isEmpty {
                                let snapshotBms = freshSafariBms.map { b in
                                    Bookmark(id: b.id, title: b.title, url: b.url.flatMap { $0 }, parentId: b.parentId, isFolder: b.isFolder, sortIndex: b.sortIndex, inBookmarksBar: b.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
                                }
                                backupService?.saveSnapshot(bookmarks: snapshotBms, sourceBrowser: "safari")
                                log("Updated Safari snapshot after write (\(snapshotBms.count) items)")
                            }
                        }
                    }
                } else {
                    log("Skipping Safari bookmark write: no folder access granted yet")
                }
#else
                // Ensure strategy allows it (oneWay from Safari should not accept writes)
                let strategy = settings.bookmarkSyncStrategy
                let sourceBrowser = settings.bookmarkSourceBrowser
                if !(strategy == .oneWay && sourceBrowser == .safari) {
                    var finalSyncBookmarks: [SyncBookmark] = []
                    var finalIsFullMirror = isFullMirror
                    
                    if let targetFolder = settings.bookmarkFolder(for: .safari) {
                        let safariTargetBms = safariBookmarks.readBookmarks().map { b in
                            Bookmark(id: b.id, title: b.title, url: b.url.flatMap { $0 }, parentId: b.parentId, isFolder: b.isFolder, sortIndex: b.sortIndex, inBookmarksBar: b.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
                        }
                        let mergedBookmarks = strategy == .oneWay
                            ? BookmarkTreeMerger.replaceExistingFolderContents(sourceTree: bookmarks, targetTree: safariTargetBms, targetFolderPath: targetFolder)
                            : BookmarkTreeMerger.mergeIntoExistingFolder(sourceTree: bookmarks, targetTree: safariTargetBms, targetFolderPath: targetFolder)
                        guard let finalBookmarksToSend = mergedBookmarks else {
                            markMissingBookmarkFolder(.safari, folder: targetFolder)
                            return
                        }
                        finalIsFullMirror = strategy == .oneWay
                        finalSyncBookmarks = finalBookmarksToSend.compactMap { b -> SyncBookmark? in
                            let urlStr: String?
                            if let urlOpt = b.url { urlStr = urlOpt } else { urlStr = nil }
                            if !b.isFolder && urlStr == nil { return nil }
                            return SyncBookmark(id: b.id, title: b.title, url: urlStr, parentId: b.parentId, isFolder: b.isFolder, sortIndex: b.sortIndex, inBookmarksBar: b.inBookmarksBar ?? false, dateAdded: b.dateAdded)
                        }
                    } else {
                        finalSyncBookmarks = bookmarks.compactMap { b -> SyncBookmark? in
                            let urlStr: String?
                            if let urlOpt = b.url { urlStr = urlOpt } else { urlStr = nil }
                            if !b.isFolder && urlStr == nil { return nil }
                            return SyncBookmark(id: b.id, title: b.title, url: urlStr, parentId: b.parentId, isFolder: b.isFolder, sortIndex: b.sortIndex, inBookmarksBar: b.inBookmarksBar ?? false, dateAdded: b.dateAdded)
                        }
                    }
                    
                    prepareSafariForIncomingBookmarkMutation()
                    let sourceName = clientId.components(separatedBy: "-").first ?? clientId
                    self.lastNetworkSyncTime = Date() // Record time to prevent echo
                    let count = safariBookmarks.applyBookmarks(finalSyncBookmarks, from: sourceName, isFullMirror: finalIsFullMirror)
                    if count >= 0 {
                        log("Wrote \(count) bookmarks into Safari natively")
                        // CRITICAL: Immediately update Safari snapshot after writing.
                        // Without this, the next auto-sync will diff the new Safari state
                        // (possibly with changed folder UUIDs) against the old snapshot,
                        // incorrectly detecting mass deletions and broadcasting bookmarks_removed.
                        let freshSafariBms = safariBookmarks.readBookmarks()
                        if !freshSafariBms.isEmpty {
                            let snapshotBms = freshSafariBms.map { b in
                                Bookmark(id: b.id, title: b.title, url: b.url.flatMap { $0 }, parentId: b.parentId, isFolder: b.isFolder, sortIndex: b.sortIndex, inBookmarksBar: b.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
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

    private func logSyncPayload(_ message: WSMessage, direction: String, clientId: String, note: String) {
        let payloadDir = dataDir.appendingPathComponent("logs/payloads")
        try? FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let category = message.category ?? "unknown"
        let messageId = message.messageId ?? UUID().uuidString
        let safeClientId = clientId.replacingOccurrences(of: "/", with: "_")
        let safeNote = note.replacingOccurrences(of: "/", with: "_")
        let fileURL = payloadDir.appendingPathComponent("\(timestamp)_\(direction)_\(safeClientId)_\(category)_\(safeNote)_\(messageId).json")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(message)
            try data.write(to: fileURL, options: .atomic)
            log("Payload \(direction) [\(clientId)] \(category) \(payloadSummary(message.payload)) note=\(note) file=\(fileURL.path)")
        } catch {
            logger.error("Failed to save sync payload log: \(error)")
        }
    }

    private func payloadSummary(_ payload: WSPayload?) -> String {
        guard let payload else { return "(request/no payload)" }
        switch payload {
        case .bookmarks(let items): return "(\(items.count) bookmarks)"
        case .tabs(let items): return "(\(items.count) tabs)"
        case .browserState(let items): return "(\(items.count) browserState tabs)"
        case .localStorage(let items): return "(\(items.count) localStorage)"
        case .sessionStorage(let items): return "(\(items.count) sessionStorage)"
        case .cookies(let items): return "(\(items.count) cookies)"
        case .history(let items): return "(\(items.count) history)"
        case .bookmarksRemoved(let item): return "(removed id=\(item.id) title=\(item.title))"
        case .raw(let raw): return "(\(raw.count) raw fields)"
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
