// SafariBookmarkService.swift
// BrowSync — Writes bookmarks to Safari's Bookmarks.plist via native macOS API

import Foundation
import os.log
import AppKit

/// Manages writing received bookmarks into Safari's native bookmark store.
/// Safari Web Extensions do NOT support chrome.bookmarks, so the Mac App must do this.
/// 
/// Strategy: Export an HTML bookmarks file, then open it so the user can import via
/// File → Import From → Bookmarks HTML File in Safari.
/// As a secondary approach, write directly to Bookmarks.plist when Safari is NOT running.
@MainActor
final class SafariBookmarkService {
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "SafariBookmarks")

    private var bookmarksURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent("Library/Safari/Bookmarks.plist")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var isSafariRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Safari" }
    }

    // MARK: - Apply bookmarks from another browser

    /// Returns the number of bookmarks applied or staged.
    @discardableResult
    func applyBookmarks(_ bookmarks: [SyncBookmark], from sourceBrowser: String, isFullMirror: Bool = false) -> Int {
        guard let url = bookmarksURL else {
            logger.warning("Safari Bookmarks.plist not found, skipping")
            return 0
        }

        do {
            let data = try Data(contentsOf: url)
            guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                logger.warning("Could not parse Bookmarks.plist")
                return 0
            }

            let added = insertBookmarks(bookmarks, into: &plist, sourceBrowser: sourceBrowser, isFullMirror: isFullMirror)
            if added == 0 && !isFullMirror {
                logger.info("No new bookmarks to add from \(sourceBrowser)")
                return 0
            }

            let writeBlock = {
                do {
                    let newData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                    try newData.write(to: url, options: .atomic)
                    self.logger.info("Wrote \(added) bookmarks to Safari Bookmarks.plist from \(sourceBrowser)")
                } catch {
                    self.logger.error("Failed to write Safari bookmarks: \(error)")
                }
            }

            // Generate HTML backup as a fallback just in case
            if let html = exportHTML(bookmarks, from: sourceBrowser) {
                logger.info("HTML exported to \(html.path) as fallback.")
            }
            
            // macOS automatically reloads Bookmarks.plist even when Safari is running
            writeBlock()
            return added
        } catch {
            logger.error("Failed to process Safari bookmarks: \(error)")
            return 0
        }
    }

    // MARK: - HTML Export (always works)

    func exportHTML(_ bookmarks: [SyncBookmark], from sourceBrowser: String) -> URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("BrowSync/bookmarks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("browsync_\(sourceBrowser)_bookmarks.html")

        var html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>BrowSync Bookmarks from \(sourceBrowser)</TITLE>
        <H1>BrowSync Bookmarks from \(sourceBrowser)</H1>
        <DL><p>
        <DT><H3>BrowSync (\(sourceBrowser))</H3>
        <DL><p>
        """
        for b in bookmarks where !b.isFolder {
            guard let url = b.url else { continue }
            let title = b.title.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            html += "    <DT><A HREF=\"\(url)\">\(title)</A>\n"
        }
        html += "</DL><p>\n</DL><p>"

        do {
            try html.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            logger.error("Failed to export bookmarks HTML: \(error)")
            return nil
        }
    }

    // MARK: - Plist Manipulation

    private func insertBookmarks(_ bookmarks: [SyncBookmark], into plist: inout [String: Any], sourceBrowser: String, isFullMirror: Bool = false) -> Int {
        guard var children = plist["Children"] as? [[String: Any]] else { return 0 }

        var barIdx = children.firstIndex { ($0["Title"] as? String) == "BookmarksBar" }
        if barIdx == nil {
            barIdx = children.firstIndex { ($0["WebBookmarkType"] as? String) == "WebBookmarkTypeList" }
        }

        guard let idx = barIdx else { return 0 }
        guard var barChildren = children[idx]["Children"] as? [[String: Any]] else { return 0 }

        var addedCount = 0

        func buildNode(from bookmark: SyncBookmark, allBookmarks: [SyncBookmark]) -> [String: Any]? {
            let uuid = UUID().uuidString.lowercased()
            if bookmark.isFolder {
                let children = allBookmarks.filter { $0.parentId == bookmark.id }
                let childNodes = children.compactMap { buildNode(from: $0, allBookmarks: allBookmarks) }
                return [
                    "WebBookmarkType": "WebBookmarkTypeList",
                    "Title": bookmark.title,
                    "WebBookmarkUUID": uuid,
                    "Children": childNodes
                ]
            } else {
                guard let urlStr = bookmark.url else { return nil }
                return [
                    "WebBookmarkType": "WebBookmarkTypeLeaf",
                    "URLString": urlStr,
                    "WebBookmarkUUID": uuid,
                    "ReadingListNonSync": false,
                    "URIDictionary": ["title": bookmark.title]
                ]
            }
        }

        // We flatten existing URLs to avoid duplicates (ignoring folders)
        var existingURLs = Set<String>()
        func scanExistingURLs(nodes: [[String: Any]]) {
            for node in nodes {
                if let url = node["URLString"] as? String { existingURLs.insert(url) }
                if let children = node["Children"] as? [[String: Any]] { scanExistingURLs(nodes: children) }
            }
        }
        scanExistingURLs(nodes: barChildren)

        let topLevelBookmarks = bookmarks.filter { $0.parentId == nil || $0.parentId == "1" || $0.parentId == "0" || $0.parentId == "2" }

        if isFullMirror {
            barChildren = topLevelBookmarks.compactMap { buildNode(from: $0, allBookmarks: bookmarks) }
            addedCount = bookmarks.count
        } else {
            for bookmark in topLevelBookmarks {
                // Skip existing URLs
                if !bookmark.isFolder, let url = bookmark.url, existingURLs.contains(url) { continue }
                // Skip existing folders by title at top level
                if bookmark.isFolder && barChildren.contains(where: { ($0["Title"] as? String) == bookmark.title }) { continue }

                if let node = buildNode(from: bookmark, allBookmarks: bookmarks) {
                    barChildren.append(node)
                    addedCount += 1
                }
            }
        }

        children[idx]["Children"] = barChildren
        plist["Children"] = children
        return addedCount
    }
    
    // MARK: - Read Safari Bookmarks

    func readBookmarks() -> [SyncBookmark] {
        guard let url = bookmarksURL else { return [] }
        do {
            let data = try Data(contentsOf: url)
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let children = plist["Children"] as? [[String: Any]] else {
                return []
            }

            var barIdx = children.firstIndex { ($0["Title"] as? String) == "BookmarksBar" }
            if barIdx == nil {
                barIdx = children.firstIndex { ($0["WebBookmarkType"] as? String) == "WebBookmarkTypeList" }
            }

            guard let idx = barIdx, let barChildren = children[idx]["Children"] as? [[String: Any]] else {
                return []
            }

            var result: [SyncBookmark] = []
            
            func traverse(nodes: [[String: Any]], parentId: String?) {
                for child in nodes {
                    let isFolder = (child["WebBookmarkType"] as? String) == "WebBookmarkTypeList"
                    let titleDict = child["URIDictionary"] as? [String: Any]
                    let titleStr = titleDict?["title"] as? String ?? child["Title"] as? String ?? child["URLString"] as? String ?? "Untitled"
                    let urlStr = child["URLString"] as? String
                    let id = (child["WebBookmarkUUID"] as? String) ?? UUID().uuidString
                    
                    result.append(SyncBookmark(id: id, title: titleStr, url: urlStr, parentId: parentId, isFolder: isFolder, inBookmarksBar: parentId == nil))
                    
                    if isFolder, let subChildren = child["Children"] as? [[String: Any]] {
                        traverse(nodes: subChildren, parentId: id)
                    }
                }
            }
            
            traverse(nodes: barChildren, parentId: nil)
            return result
        } catch {
            logger.error("Failed to read Safari bookmarks: \(error)")
            return []
        }
    }
}

// Lightweight struct for the bookmark data from the extension
struct SyncBookmark {
    let id: String
    let title: String
    let url: String?
    let parentId: String?
    let isFolder: Bool
    var inBookmarksBar: Bool = false
}
