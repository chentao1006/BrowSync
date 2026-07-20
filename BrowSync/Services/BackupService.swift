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
    var sourceBrowser: String
    var children: [DeletedBookmark]?
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
        do {
            let data = try JSONEncoder().encode(bookmarks)
            try data.write(to: fileURL)
            Task { @MainActor in
                self.lastSnapshotUpdate = Date()
            }
        } catch {
            logger.error("Failed to save snapshot for \(sourceBrowser): \(error)")
        }
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
    func savePreSyncBackup(bookmarks: [Bookmark], sourceBrowser: String, folderPath: String?) -> Bool {
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
            if Date().timeIntervalSince(previousBackup.createdAt) < 30 {
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
        let expired = recentBookmarkBackups.dropFirst(30)
        for backup in expired {
            let fileURL = backupsDir.appendingPathComponent("backup_\(backup.id).json")
            try? FileManager.default.removeItem(at: fileURL)
        }
        if recentBookmarkBackups.count > 30 {
            recentBookmarkBackups = Array(recentBookmarkBackups.prefix(30))
        }
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
    
    func addDeletedBookmarks(_ newBookmarks: [DeletedBookmark]) {
        ensureDeletedItemsLoadedForMutation()
        // Prevent duplicates based on ID and Title
        let existingSignatures = Set(deletedBookmarks.map { "\($0.id)-\($0.title)" })
        let uniqueNew = newBookmarks.filter { !existingSignatures.contains("\($0.id)-\($0.title)") }
        
        guard !uniqueNew.isEmpty else { return }
        
        deletedBookmarks.insert(contentsOf: uniqueNew, at: 0)
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
