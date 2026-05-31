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

    /// Returns the number of bookmarks applied, or -1 if Safari was running and a HTML file was exported instead.
    @discardableResult
    func applyBookmarks(_ bookmarks: [SyncBookmark], from sourceBrowser: String) -> Int {
        if isSafariRunning {
            // Safari is running — write to plist directly (often overwritten) and export HTML
            let plistCount = writeToPlist(bookmarks, from: sourceBrowser)
            if let html = exportHTML(bookmarks, from: sourceBrowser) {
                logger.info("Safari is running. HTML exported to \(html.path). Manual import required.")
            }
            return plistCount
        } else {
            // Safari is not running — safe to write plist
            return writeToPlist(bookmarks, from: sourceBrowser)
        }
    }

    // MARK: - Plist Write (works when Safari is quit)

    private func writeToPlist(_ bookmarks: [SyncBookmark], from sourceBrowser: String) -> Int {
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

            let added = insertBookmarks(bookmarks, into: &plist, sourceBrowser: sourceBrowser)
            if added == 0 {
                logger.info("No new bookmarks to add from \(sourceBrowser)")
                return 0
            }

            let newData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try newData.write(to: url, options: .atomic)
            logger.info("Wrote \(added) bookmarks to Safari Bookmarks.plist from \(sourceBrowser)")
            return added
        } catch {
            logger.error("Failed to write Safari bookmarks: \(error)")
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

    private func insertBookmarks(_ bookmarks: [SyncBookmark], into plist: inout [String: Any], sourceBrowser: String) -> Int {
        guard var children = plist["Children"] as? [[String: Any]] else { return 0 }

        var barIdx = children.firstIndex { ($0["Title"] as? String) == "BookmarksBar" }
        if barIdx == nil {
            barIdx = children.firstIndex { ($0["WebBookmarkType"] as? String) == "WebBookmarkTypeList" }
        }

        guard let idx = barIdx else { return 0 }
        guard var barChildren = children[idx]["Children"] as? [[String: Any]] else { return 0 }

        let folderTitle = "BrowSync (\(sourceBrowser))"
        let folderIdx = barChildren.firstIndex { ($0["Title"] as? String) == folderTitle }
        var folder: [String: Any]
        var folderChildren: [[String: Any]]

        if let fi = folderIdx {
            folder = barChildren[fi]
            folderChildren = folder["Children"] as? [[String: Any]] ?? []
        } else {
            folder = [
                "WebBookmarkType": "WebBookmarkTypeList",
                "Title": folderTitle,
                "WebBookmarkUUID": UUID().uuidString.lowercased(),
                "Children": [[String: Any]]()
            ]
            folderChildren = []
        }

        let existingURLs = Set(folderChildren.compactMap { $0["URLString"] as? String })
        var addedCount = 0
        for bookmark in bookmarks {
            guard let urlStr = bookmark.url, !existingURLs.contains(urlStr) else { continue }
            let entry: [String: Any] = [
                "WebBookmarkType": "WebBookmarkTypeLeaf",
                "URLString": urlStr,
                "WebBookmarkUUID": UUID().uuidString.lowercased(),
                "ReadingListNonSync": false,
                "URIDictionary": ["title": bookmark.title]
            ]
            folderChildren.append(entry)
            addedCount += 1
        }

        folder["Children"] = folderChildren
        if let fi = folderIdx {
            barChildren[fi] = folder
        } else {
            barChildren.append(folder)
        }
        children[idx]["Children"] = barChildren
        plist["Children"] = children
        return addedCount
    }
}

// Lightweight struct for the bookmark data from the extension
struct SyncBookmark {
    let title: String
    let url: String?
    let isFolder: Bool
}
