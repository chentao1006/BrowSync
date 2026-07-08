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
    
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "BackupService")
    private let backupsDir: URL
    
    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        backupsDir = appSupport.appendingPathComponent("BrowSync/Backups/Bookmarks")
        
        do {
            try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create backups directory: \(error)")
        }
        
        loadDeletedItems()
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
        let prefix = "snapshot_\(sourceBrowser.replacingOccurrences(of: "/", with: "_"))"
        do {
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
    
    func addDeletedBookmarks(_ newBookmarks: [DeletedBookmark]) {
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
        deletedBookmarks.removeAll { $0.id == id }
        saveDeletedItems()
    }
    
    func clearAllDeletedBookmarks() {
        deletedBookmarks.removeAll()
        saveDeletedItems()
    }
    
    private func loadDeletedItems() {
        let fileURL = backupsDir.appendingPathComponent("trash.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            deletedBookmarks = try JSONDecoder().decode([DeletedBookmark].self, from: data)
        } catch {
            logger.error("Failed to load trash.json: \(error)")
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
