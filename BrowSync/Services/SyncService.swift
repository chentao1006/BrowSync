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
    var settings: SyncSettings = SyncSettings()
    private let safariBookmarks = SafariBookmarkService()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dataDir = appSupport.appendingPathComponent("BrowSync")
        createDataDirectories()
    }

    // MARK: - Data Directories

    private func createDataDirectories() {
        let dirs = ["sites", "bookmarks", "history", "logs"]
        for dir in dirs {
            let url = dataDir.appendingPathComponent(dir)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Sync Now

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        
        let connectedClients = daemon?.connectedClients.map { "\($0.browser.rawValue)-\($0.id)" }.joined(separator: ", ") ?? "none"
        log("Starting manual sync... Connected clients: \(connectedClients)")

        for category in SyncCategory.allCases where settings.enabledCategories.contains(category) {
            await syncCategory(category)
        }

        lastSyncDate = Date()
        isSyncing = false
        log("Sync complete")
    }

    private func syncCategory(_ category: SyncCategory) async {
        log("Syncing: \(category.displayName)")
        // In MVP, sync is triggered by broadcasting a request to all clients
        // The extension will respond with the current data
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

    // MARK: - Receive Sync Data

    func receive(message: WSMessage, from clientId: String) {
        guard message.type == .sync, let category = message.category else { return }
        
        var countStr = ""
        if let payload = message.payload {
            switch payload {
            case .bookmarks(let b): countStr = " (\(b.count) items)"
            case .tabs(let t): countStr = " (\(t.count) items)"
            case .cookies(let c): countStr = " (\(c.count) items)"
            case .localStorage(let l): countStr = " (\(l.count) items)"
            default: break
            }
        }
        
        log("Received sync data from [\(clientId)]: \(category)\(countStr)")

        // Apply conflict resolution and persist
        if let payload = message.payload {
            persist(payload: payload, category: category, from: clientId)
            // Broadcast to other clients (daemon handles this, but we might filter here)
        }
    }

    // MARK: - Persistence

    private func persist(payload: WSPayload, category: String, from clientId: String) {
        switch payload {
        case .bookmarks(let bookmarks):
            let targetDir = dataDir.appendingPathComponent("bookmarks")
            save(bookmarks, to: targetDir.appendingPathComponent("\(clientId).json"))
            // Also write natively into Safari if the source is a Chromium browser
            if !clientId.lowercased().contains("safari") {
                let syncBookmarks = bookmarks.compactMap { b -> SyncBookmark? in
                    guard let urlOpt = b.url, let url = urlOpt else { return nil }
                    return SyncBookmark(title: b.title, url: url, isFolder: b.isFolder)
                }
                let sourceName = clientId.components(separatedBy: "-").first ?? clientId
                let count = safariBookmarks.applyBookmarks(syncBookmarks, from: sourceName)
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
        let logFile = logDir.appendingPathComponent("sync.log")
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
