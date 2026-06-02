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
    var backupService: BackupService?
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
            let shouldPushSafari = strategy == .twoWayMerge || (strategy == .oneWay && sourceBrowser == .safari)
            
            if shouldPushSafari {
                let safariBms = safariBookmarks.readBookmarks()
                if !safariBms.isEmpty {
                    let bookmarks = safariBms.map { b in
                        Bookmark(id: b.id, title: b.title, url: b.url, parentId: b.parentId, isFolder: b.isFolder, inBookmarksBar: b.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari)
                    }
                    var pushMsg = WSMessage(
                        type: .sync,
                        site: "*",
                        category: category.rawValue,
                        payload: .bookmarks(bookmarks),
                        messageId: UUID().uuidString,
                        timestamp: Date().timeIntervalSince1970
                    )
                    pushMsg.isFullMirror = (strategy == .oneWay)
                    daemon?.broadcast(pushMsg)
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
                daemon?.broadcast(requestMessage)
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
        
        if category == "bookmarks" {
            let strategy = settings.bookmarkSyncStrategy
            let sourceBrowser = settings.bookmarkSourceBrowser
            if strategy == .oneWay && sourceBrowser == .safari {
                log("Ignored bookmark from [\(clientId)] due to one-way sync strategy (Safari is primary)")
                return
            }
            if strategy == .oneWay {
                filteredMessage.isFullMirror = true
            }
            if case .bookmarks(let bms) = filteredMessage.payload {
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
        
        // Filter incoming browser data based on website list policy
        if category == "browserData" || category == "localStorage" || category == "cookies", let payload = message.payload {
            let policy = settings.websiteListPolicy
            let sites = settings.websiteSettings.map { $0.domain.lowercased() }
            
            switch payload {
            case .cookies(let cookies):
                let filtered = cookies.filter { c in
                    let d = c.domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    let cleanD = d.starts(with: ".") ? String(d.dropFirst()) : d
                    
                    let siteMatch = settings.websiteSettings.first { site in
                        let listed = site.domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !listed.isEmpty else { return false }
                        let cleanListed = listed.starts(with: ".") ? String(listed.dropFirst()) : listed
                        return cleanD == cleanListed || cleanD.hasSuffix("." + cleanListed) || cleanListed.hasSuffix("." + cleanD)
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
                filteredMessage.payload = .cookies(filtered)
            case .localStorage(let items):
                let filtered = items.filter { i in
                    let o = i.origin.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    let host = URL(string: o)?.host ?? o
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
                filteredMessage.payload = .localStorage(filtered)
            default: break
            }
            
            // If everything was filtered out, we can drop the message
            switch filteredMessage.payload {
            case .cookies(let c) where c.isEmpty: return
            case .localStorage(let l) where l.isEmpty: return
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
            default: break
            }
        }
        
        log("Received sync data from [\(clientId)]: \(category)\(countStr)")

        // Apply conflict resolution and persist
        if let payload = filteredMessage.payload {
            persist(payload: payload, category: category, from: clientId, isFullMirror: filteredMessage.isFullMirror ?? false)
            
            if settings.automaticSync || isSyncing {
                // Don't cache bookmarks in GlobalStateStore — they must always reflect
                // the current state of the source browser, not a stale snapshot.
                if category != "bookmarks" && category != "bookmark_backup" {
                    GlobalStateStore.shared.save(message: filteredMessage)
                }
                // Broadcast the filtered payload to other clients
                daemon?.broadcast(filteredMessage, excluding: clientId)
            } else {
                log("Automatic sync is disabled. Received data but did not broadcast.")
            }
        }
    }

    // MARK: - Persistence

    private func persist(payload: WSPayload, category: String, from clientId: String, isFullMirror: Bool = false) {
        switch payload {
        case .bookmarks(let bookmarks):
            let targetDir = dataDir.appendingPathComponent("bookmarks")
            save(bookmarks, to: targetDir.appendingPathComponent("\(clientId).json"))
            // Also write natively into Safari if the source is a Chromium browser
            if !clientId.lowercased().contains("safari") {
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
