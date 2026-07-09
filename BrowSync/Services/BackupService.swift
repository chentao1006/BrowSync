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

@MainActor
final class BackupService: ObservableObject {
    @Published var deletedBookmarks: [DeletedBookmark] = []
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
