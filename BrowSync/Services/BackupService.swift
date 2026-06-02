// BackupService.swift
// BrowSync — Bookmark Backup & Restore Service

import Foundation
import os.log

struct BookmarkBackup: Identifiable, Codable, Equatable {
    var id: String { filename }
    var timestamp: Date
    var sourceBrowser: String
    var itemCount: Int
    var filename: String
}

@MainActor
final class BackupService: ObservableObject {
    @Published var backups: [BookmarkBackup] = []
    
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "BackupService")
    private let backupsDir: URL
    private let maxBackups = 20
    
    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        backupsDir = appSupport.appendingPathComponent("BrowSync/Backups/Bookmarks")
        
        do {
            try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create backups directory: \(error)")
        }
        
        loadBackups()
    }
    
    func createBackup(bookmarks: [Bookmark], sourceBrowser: String) {
        let timestamp = Date()
        let formatter = ISO8601DateFormatter()
        let filename = "backup_\(sourceBrowser)_\(formatter.string(from: timestamp)).json"
        let fileURL = backupsDir.appendingPathComponent(filename)
        
        do {
            let data = try JSONEncoder().encode(bookmarks)
            try data.write(to: fileURL)
            
            let backup = BookmarkBackup(
                timestamp: timestamp,
                sourceBrowser: sourceBrowser,
                itemCount: bookmarks.count,
                filename: filename
            )
            
            backups.insert(backup, at: 0)
            enforceLimit()
            saveIndex()
            
            logger.info("Created bookmark backup: \(filename) (\(bookmarks.count) items)")
        } catch {
            logger.error("Failed to create backup: \(error)")
        }
    }
    
    func getBookmarks(for backupId: String) -> [Bookmark]? {
        let fileURL = backupsDir.appendingPathComponent(backupId)
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([Bookmark].self, from: data)
        } catch {
            logger.error("Failed to load backup data for \(backupId): \(error)")
            return nil
        }
    }
    
    func deleteBackup(id: String) {
        let fileURL = backupsDir.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: fileURL)
        backups.removeAll { $0.id == id }
        saveIndex()
    }
    
    private func loadBackups() {
        let indexURL = backupsDir.appendingPathComponent("index.json")
        do {
            let data = try Data(contentsOf: indexURL)
            backups = try JSONDecoder().decode([BookmarkBackup].self, from: data)
        } catch {
            // Index doesn't exist or is corrupted, rebuild it
            rebuildIndex()
        }
    }
    
    private func saveIndex() {
        let indexURL = backupsDir.appendingPathComponent("index.json")
        do {
            let data = try JSONEncoder().encode(backups)
            try data.write(to: indexURL)
        } catch {
            logger.error("Failed to save backup index: \(error)")
        }
    }
    
    private func enforceLimit() {
        while backups.count > maxBackups {
            if let oldest = backups.popLast() {
                let fileURL = backupsDir.appendingPathComponent(oldest.filename)
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
    
    private func rebuildIndex() {
        backups = []
        do {
            let files = try FileManager.default.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: [.creationDateKey])
            for file in files where file.pathExtension == "json" && file.lastPathComponent != "index.json" {
                if let data = try? Data(contentsOf: file),
                   let bookmarks = try? JSONDecoder().decode([Bookmark].self, from: data) {
                    
                    let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
                    let creationDate = attrs?[.creationDate] as? Date ?? Date()
                    let source = file.lastPathComponent.components(separatedBy: "_").dropFirst().first ?? "Unknown"
                    
                    let backup = BookmarkBackup(
                        timestamp: creationDate,
                        sourceBrowser: source,
                        itemCount: bookmarks.count,
                        filename: file.lastPathComponent
                    )
                    backups.append(backup)
                }
            }
            backups.sort { $0.timestamp > $1.timestamp }
            enforceLimit()
            saveIndex()
        } catch {
            logger.error("Failed to rebuild backup index: \(error)")
        }
    }
}
