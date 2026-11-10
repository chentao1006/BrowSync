// BackupService.swift
// BrowSync — Bookmark Backup & Restore Service (Now Acts as Trash Bin)

import Foundation
import os.log

struct DeletedBookmark: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var url: String?
    var parentId: String?
    var isFolder: Bool
    var deletedAt: Date
    var sourceBrowsers: Set<String>
    var children: [DeletedBookmark]?

    init(id: String, title: String, url: String?, parentId: String?, isFolder: Bool, deletedAt: Date, sourceBrowser: String, children: [DeletedBookmark]?) {
        self.id = id
        self.title = title
        self.url = url
        self.parentId = parentId
        self.isFolder = isFolder
        self.deletedAt = deletedAt
        self.sourceBrowsers = [Self.normalizedBrowserId(sourceBrowser)]
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, url, parentId, isFolder, deletedAt, sourceBrowser, sourceBrowsers, children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        isFolder = try container.decode(Bool.self, forKey: .isFolder)
        deletedAt = try container.decode(Date.self, forKey: .deletedAt)
        if let sources = try container.decodeIfPresent(Set<String>.self, forKey: .sourceBrowsers), !sources.isEmpty {
            sourceBrowsers = Set(sources.map(Self.normalizedBrowserId))
        } else {
            sourceBrowsers = [Self.normalizedBrowserId(try container.decode(String.self, forKey: .sourceBrowser))]
        }
        children = try container.decodeIfPresent([DeletedBookmark].self, forKey: .children)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(parentId, forKey: .parentId)
        try container.encode(isFolder, forKey: .isFolder)
        try container.encode(deletedAt, forKey: .deletedAt)
        try container.encode(sourceBrowsers, forKey: .sourceBrowsers)
        try container.encodeIfPresent(children, forKey: .children)
    }

    static func normalizedBrowserId(_ value: String) -> String {
        value.components(separatedBy: "-").first?.lowercased() ?? value.lowercased()
    }

    var browsers: Set<Browser> {
        Set(sourceBrowsers.compactMap(Browser.init(rawValue:)))
    }
}

/// A user-visible, point-in-time copy of the folder data that was about to be
/// synchronized. This is deliberately separate from the rolling `snapshot_*`
/// files used internally for deletion detection.
struct BookmarkBackup: Identifiable, Codable, Equatable {
    let id: String
    let createdAt: Date
    let sourceBrowser: String
    let folderPath: String?
    let bookmarks: [Bookmark]
    /// Taken with "Back Up Now". Manual backups are kept until the user
    /// deletes them; automatic ones expire after the retention period.
    /// Absent in backups written by earlier versions (= automatic).
    var isManual: Bool? = nil
}

/// Fields that define a restorable bookmark tree. Capture time and source browser
/// are intentionally excluded: they are regenerated while reading or relaying a
/// tree and must not create duplicate automatic backups.
private struct BookmarkBackupFingerprint: Equatable {
    private struct Item: Equatable {
        let id: String
        let title: String
        let url: String?
        let parentId: String?
        let isFolder: Bool
        let sortIndex: Int?
        let inBookmarksBar: Bool?
        let children: [Item]?

        init(_ bookmark: Bookmark) {
            id = bookmark.id
            title = bookmark.title
            if let url = bookmark.url {
                self.url = url
            } else {
                self.url = nil
            }
            parentId = bookmark.parentId
            isFolder = bookmark.isFolder
            sortIndex = bookmark.sortIndex
            inBookmarksBar = bookmark.inBookmarksBar
            children = bookmark.children.map { $0.map(Item.init).sorted(by: Self.isOrderedBefore) }
        }

        static func isOrderedBefore(_ lhs: Item, _ rhs: Item) -> Bool {
            if lhs.parentId != rhs.parentId { return (lhs.parentId ?? "") < (rhs.parentId ?? "") }
            if lhs.sortIndex != rhs.sortIndex { return (lhs.sortIndex ?? .max) < (rhs.sortIndex ?? .max) }
            return lhs.id < rhs.id
        }
    }

    private let items: [Item]

    init(bookmarks: [Bookmark]) {
        items = bookmarks.map(Item.init).sorted(by: Item.isOrderedBefore)
    }
}

@MainActor
final class BackupService: ObservableObject {
    static let bookmarkBackupRetention: TimeInterval = 7 * 24 * 60 * 60
    @Published var deletedBookmarks: [DeletedBookmark] = []
    @Published var recentBookmarkBackups: [BookmarkBackup] = []
    @Published var lastSnapshotUpdate: Date = Date()
    @Published var isLoadingDeletedBookmarks: Bool = false
    
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "BackupService")
    private let backupsDir: URL
    private var hasLoadedDeletedBookmarks = false
    private var loadDeletedItemsTask: Task<Void, Never>?
    
    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        backupsDir = appSupport.appendingPathComponent("BrowSync/Backups/Bookmarks")
        
        do {
            try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create backups directory: \(error)")
        }
        
        loadDeletedItemsIfNeeded()
        loadRecentBookmarkBackups()
    }
    
    // MARK: - Snapshot Management (for diffing)
    
    func saveSnapshot(bookmarks: [Bookmark], sourceBrowser: String) {
        let filename = sourceBrowser.replacingOccurrences(of: "/", with: "_")
        let fileURL = backupsDir.appendingPathComponent("snapshot_\(filename).json")
        let historyURL = backupsDir.appendingPathComponent("snapshot_history_\(filename).json")
        do {
            let data = try JSONEncoder().encode(bookmarks)
            try data.write(to: fileURL, options: .atomic)
            var history = (try? Data(contentsOf: historyURL)).flatMap { try? JSONDecoder().decode([BookmarkSnapshotRecord].self, from: $0) } ?? []
            history.append(.init(id: UUID().uuidString, capturedAt: Date(), sourceBrowser: sourceBrowser, bookmarks: bookmarks))
            let cutoff = Date().addingTimeInterval(-Self.bookmarkBackupRetention)
            history = Array(history.filter { $0.capturedAt >= cutoff }.suffix(256))
            try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
            Task { @MainActor in
                self.lastSnapshotUpdate = Date()
            }
        } catch {
            logger.error("Failed to save snapshot for \(sourceBrowser): \(error)")
        }
    }

    /// The source browser's tree as last synchronized into one target. Local
    /// changes for that pair are the difference between this baseline and the
    /// source's newest snapshot; it only advances past changes that were
    /// applied (or proved unnecessary) in the target.
    func saveSyncBaseline(bookmarks: [Bookmark], source: Browser, target: Browser) {
        let fileURL = backupsDir.appendingPathComponent("sync_baseline_\(source.rawValue)_to_\(target.rawValue).json")
        do {
            try JSONEncoder().encode(bookmarks).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save sync baseline \(source.rawValue) -> \(target.rawValue): \(error)")
        }
    }

    func getSyncBaseline(source: Browser, target: Browser) -> [Bookmark]? {
        let fileURL = backupsDir.appendingPathComponent("sync_baseline_\(source.rawValue)_to_\(target.rawValue).json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([Bookmark].self, from: data)
    }

    func getRecentSnapshots(sourceBrowser: String, limit: Int = 2) -> [BookmarkSnapshotRecord] {
        let filename = sourceBrowser.replacingOccurrences(of: "/", with: "_")
        let historyURL = backupsDir.appendingPathComponent("snapshot_history_\(filename).json")
        guard let data = try? Data(contentsOf: historyURL),
              let history = try? JSONDecoder().decode([BookmarkSnapshotRecord].self, from: data) else { return [] }
        return Array(history.sorted { $0.capturedAt < $1.capturedAt }.suffix(max(0, limit)))
    }
    
    func getSnapshot(sourceBrowser: String) -> [Bookmark]? {
        let filename = sourceBrowser.replacingOccurrences(of: "/", with: "_")
        let directFileURL = backupsDir.appendingPathComponent("snapshot_\(filename).json")
        do {
            // Fast path: snapshots are written to a stable filename.
            if FileManager.default.fileExists(atPath: directFileURL.path) {
                let data = try Data(contentsOf: directFileURL)
                return try JSONDecoder().decode([Bookmark].self, from: data)
            }

            // Backward-compatibility fallback for older builds that may have multiple files.
            let prefix = "snapshot_\(filename)"
            let files = try FileManager.default.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: [.creationDateKey])
            let matchingFiles = files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            
            let sorted = matchingFiles.sorted { u1, u2 in
                let d1 = (try? u1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                let d2 = (try? u2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                return d1 > d2
            }
            
            if let newest = sorted.first {
                let data = try Data(contentsOf: newest)
                return try JSONDecoder().decode([Bookmark].self, from: data)
            }
        } catch {
            logger.error("Failed to load snapshot for \(sourceBrowser): \(error)")
        }
        return nil
    }

    // MARK: - User-visible pre-sync backups

    @discardableResult
    /// - Parameter bypassBurstSuppression: a confirmed restore replays into a
    ///   target that may have been backed up seconds ago; that state must
    ///   still be captured. Identical content remains deduplicated.
    func savePreSyncBackup(bookmarks: [Bookmark], sourceBrowser: String, folderPath: String?,
                           bypassBurstSuppression: Bool = false) -> Bool {
        guard !bookmarks.isEmpty else {
            logger.debug("Skipped empty pre-sync bookmark backup for \(sourceBrowser)")
            return false
        }

        let currentFingerprint = BookmarkBackupFingerprint(bookmarks: bookmarks)
        if let previousBackup = recentBookmarkBackups.first(where: {
            $0.sourceBrowser == sourceBrowser && $0.folderPath == folderPath
        }) {
            // One incoming change can fan out into several extension callbacks.
            // The first capture is the only state guaranteed to be pre-write;
            // subsequent callbacks in the same burst may already be synced.
            if !bypassBurstSuppression, Date().timeIntervalSince(previousBackup.createdAt) < 30 {
                logger.debug("Skipped duplicate pre-sync bookmark backup in the current sync burst for \(sourceBrowser)")
                return false
            }
            if BookmarkBackupFingerprint(bookmarks: previousBackup.bookmarks) == currentFingerprint {
                logger.debug("Skipped unchanged pre-sync bookmark backup for \(sourceBrowser)")
                return false
            }
        }

        let backup = BookmarkBackup(
            id: UUID().uuidString,
            createdAt: Date(),
            sourceBrowser: sourceBrowser,
            folderPath: folderPath,
            bookmarks: bookmarks
        )
        let fileURL = backupsDir.appendingPathComponent("backup_\(backup.id).json")
        do {
            try JSONEncoder().encode(backup).write(to: fileURL)
            recentBookmarkBackups.insert(backup, at: 0)
            trimRecentBookmarkBackups()
            return true
        } catch {
            logger.error("Failed to save pre-sync bookmark backup: \(error)")
            return false
        }
    }

    /// A user-requested backup: always saved (no burst or duplicate
    /// suppression) and exempt from age-based expiry.
    @discardableResult
    func saveManualBackup(bookmarks: [Bookmark], sourceBrowser: String, folderPath: String?) -> Bool {
        guard !bookmarks.isEmpty else { return false }
        let backup = BookmarkBackup(id: UUID().uuidString, createdAt: Date(), sourceBrowser: sourceBrowser,
                                    folderPath: folderPath, bookmarks: bookmarks, isManual: true)
        let fileURL = backupsDir.appendingPathComponent("backup_\(backup.id).json")
        do {
            try JSONEncoder().encode(backup).write(to: fileURL)
            recentBookmarkBackups.insert(backup, at: 0)
            return true
        } catch {
            logger.error("Failed to save manual bookmark backup: \(error)")
            return false
        }
    }

    func removeRecentBookmarkBackup(id: String) {
        let fileURL = backupsDir.appendingPathComponent("backup_\(id).json")
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            recentBookmarkBackups.removeAll { $0.id == id }
        } catch {
            logger.error("Failed to remove bookmark backup: \(error)")
        }
    }

    private func loadRecentBookmarkBackups() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil)
            recentBookmarkBackups = files.compactMap { fileURL in
                guard fileURL.lastPathComponent.hasPrefix("backup_"), fileURL.pathExtension == "json",
                      let data = try? Data(contentsOf: fileURL) else { return nil }
                return try? JSONDecoder().decode(BookmarkBackup.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
            trimRecentBookmarkBackups()
        } catch {
            logger.error("Failed to load recent bookmark backups: \(error)")
        }
    }

    private func trimRecentBookmarkBackups() {
        let cutoff = Date().addingTimeInterval(-Self.bookmarkBackupRetention)
        let expired = recentBookmarkBackups.filter { $0.createdAt < cutoff && $0.isManual != true }
        for backup in expired {
            let fileURL = backupsDir.appendingPathComponent("backup_\(backup.id).json")
            try? FileManager.default.removeItem(at: fileURL)
        }
        recentBookmarkBackups.removeAll { $0.createdAt < cutoff && $0.isManual != true }
    }
    
    // MARK: - Trash Bin Management

    func loadDeletedItemsIfNeeded(force: Bool = false) {
        if !force, hasLoadedDeletedBookmarks { return }
        if loadDeletedItemsTask != nil { return }

        isLoadingDeletedBookmarks = true
        let fileURL = backupsDir.appendingPathComponent("trash.json")
        loadDeletedItemsTask = Task {
            let loaded = await Task.detached(priority: .utility) {
                Self.readDeletedItemsFromDisk(fileURL: fileURL)
            }.value

            await MainActor.run {
                self.deletedBookmarks = loaded
                self.hasLoadedDeletedBookmarks = true
                self.isLoadingDeletedBookmarks = false
                self.loadDeletedItemsTask = nil
            }
        }
    }
    
    /// Recently Deleted entries for sync decisions, read synchronously when
    /// the asynchronous UI load has not finished yet.
    func deletedBookmarksForSyncEvidence() -> [DeletedBookmark] {
        if hasLoadedDeletedBookmarks { return deletedBookmarks }
        return Self.readDeletedItemsFromDisk(fileURL: backupsDir.appendingPathComponent("trash.json"))
    }

    func addDeletedBookmarks(_ newBookmarks: [DeletedBookmark]) {
        ensureDeletedItemsLoadedForMutation()
        func signature(_ item: DeletedBookmark) -> String {
            item.url.map { "url:\($0.lowercased())" } ?? "folder:\(item.parentId ?? ""):\(item.title.lowercased())"
        }
        func merge(_ incoming: DeletedBookmark, into existing: inout DeletedBookmark) {
            existing.sourceBrowsers.formUnion(incoming.sourceBrowsers)
            existing.deletedAt = max(existing.deletedAt, incoming.deletedAt)
            var children = existing.children ?? []
            for child in incoming.children ?? [] {
                if let index = children.firstIndex(where: { signature($0) == signature(child) }) {
                    merge(child, into: &children[index])
                } else {
                    children.append(child)
                }
            }
            existing.children = children.isEmpty ? nil : children
        }
        for item in newBookmarks {
            if let index = deletedBookmarks.firstIndex(where: { signature($0) == signature(item) }) {
                merge(item, into: &deletedBookmarks[index])
            } else {
                deletedBookmarks.insert(item, at: 0)
            }
        }
        // Limit to 500 deleted items
        if deletedBookmarks.count > 500 {
            deletedBookmarks = Array(deletedBookmarks.prefix(500))
        }
        saveDeletedItems()
    }
    
    func removeDeletedBookmark(id: String) {
        ensureDeletedItemsLoadedForMutation()
        deletedBookmarks.removeAll { $0.id == id }
        saveDeletedItems()
    }

    func markDeletedBookmarksRestored(ids: Set<String>, from browser: Browser) {
        ensureDeletedItemsLoadedForMutation()
        let browserId = browser.rawValue
        deletedBookmarks = deletedBookmarks.compactMap { item in
            guard ids.contains(item.id) else { return item }
            var updated = item
            updated.sourceBrowsers.remove(browserId)
            return updated.sourceBrowsers.isEmpty ? nil : updated
        }
        saveDeletedItems()
    }

    /// Tombstones are matched by URL/title (not id) elsewhere, precisely so a
    /// browser regenerating ids doesn't defeat the match — but that same
    /// loose match means a bookmark the user manually restores still matches
    /// its old tombstone for up to 24h, silently suppressing it again on the
    /// next sync. Clear any tombstone whose signature reappears in a live tree.
    func resurrectDeletedBookmarks(seenIn bookmarks: [Bookmark], browser: Browser) {
        ensureDeletedItemsLoadedForMutation()
        guard !deletedBookmarks.isEmpty else { return }

        let liveURLs = Set(bookmarks.compactMap { $0.url.flatMap { $0 }?.lowercased() })
        // Folders are matched by title alone, not parentId: a folder's parentId
        // at deletion time may be a reporting browser's raw native id (e.g.
        // Chrome's own numeric id for a non-root parent), which won't match a
        // differently-sourced tree's id for that same folder later. Resurrection
        // should err toward clearing a stale tombstone, not toward re-suppressing
        // a folder the user restored, so title alone is the safer match here —
        // unlike the stricter parentId+title match used when deciding what to
        // exclude in the first place.
        let liveFolderTitles = Set(bookmarks.filter(\.isFolder).map { $0.title.lowercased() })

        func matchesLiveBookmark(_ item: DeletedBookmark) -> Bool {
            if item.isFolder, item.url == nil {
                return liveFolderTitles.contains(item.title.lowercased())
            } else if let url = item.url?.lowercased() {
                return liveURLs.contains(url)
            }
            return false
        }

        // If a tombstoned folder itself reappears, its captured children were
        // taken down along with it and are restored too — drop the whole
        // subtree. Otherwise recurse so an unrelated sibling's restoration
        // doesn't erase a deletion that's still real.
        func removingSource(_ browserId: String, from item: DeletedBookmark) -> DeletedBookmark? {
            var updated = item
            updated.sourceBrowsers.remove(browserId)
            updated.children = item.children.map { $0.compactMap { removingSource(browserId, from: $0) } }
            return updated.sourceBrowsers.isEmpty ? nil : updated
        }
        func filterStillDeleted(_ items: [DeletedBookmark]) -> [DeletedBookmark] {
            items.compactMap { item in
                if matchesLiveBookmark(item) {
                    return removingSource(browser.rawValue, from: item)
                }
                var updated = item
                updated.children = item.children.map(filterStillDeleted)
                return updated
            }
        }

        deletedBookmarks = filterStillDeleted(deletedBookmarks)
        saveDeletedItems()
    }
    
    func clearAllDeletedBookmarks() {
        ensureDeletedItemsLoadedForMutation()
        deletedBookmarks.removeAll()
        saveDeletedItems()
    }

    private func ensureDeletedItemsLoadedForMutation() {
        guard !hasLoadedDeletedBookmarks else { return }
        let fileURL = backupsDir.appendingPathComponent("trash.json")
        deletedBookmarks = Self.readDeletedItemsFromDisk(fileURL: fileURL)
        hasLoadedDeletedBookmarks = true
        loadDeletedItemsTask?.cancel()
        loadDeletedItemsTask = nil
        isLoadingDeletedBookmarks = false
    }

    nonisolated private static func readDeletedItemsFromDisk(fileURL: URL) -> [DeletedBookmark] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([DeletedBookmark].self, from: data)
        } catch {
            return []
        }
    }
    
    private func saveDeletedItems() {
        let fileURL = backupsDir.appendingPathComponent("trash.json")
        do {
            let data = try JSONEncoder().encode(deletedBookmarks)
            try data.write(to: fileURL)
        } catch {
            logger.error("Failed to save trash.json: \(error)")
        }
    }
}
