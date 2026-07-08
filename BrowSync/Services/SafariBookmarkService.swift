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
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var isWritingInternally = false
    private let logger = Logger(subsystem: "com.ct106.browsync", category: "SafariBookmarks")

    private var bookmarksURL: URL? {
#if APP_STORE
        // Must be called inside withSafariAccess so the security-scoped resource is active.
        // SandboxAccessManager caches the resolved URL for this purpose.
        return SandboxAccessManager.shared.safariBookmarksPlistURL
#else
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent("Library/Safari/Bookmarks.plist")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
#endif
    }

    private var isSafariRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Safari" }
    }

    // MARK: - Apply bookmarks from another browser

    /// Returns the number of bookmarks applied or staged.
    @discardableResult
    func applyBookmarks(_ bookmarks: [SyncBookmark], from sourceBrowser: String, isFullMirror: Bool = false) -> Int {
        return SandboxAccessManager.shared.withSafariAccess {
            guard let url = bookmarksURL else {
                logger.warning("Safari Bookmarks.plist not found, skipping")
                return 0
            }

            fileMonitor?.setEventHandler { [weak self] in
                guard let self = self else { return }
                if self.isWritingInternally {
                    self.logger.debug("Ignoring Bookmarks.plist change because it was triggered by a sync write")
                    return
                }
                print("[\(Date().ISO8601Format())] Safari Bookmarks.plist changed! Triggering auto-sync...")
                NotificationCenter.default.post(name: NSNotification.Name("SafariBookmarksChanged"), object: nil)
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
                        self.isWritingInternally = true
                        let newData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                        try newData.write(to: url, options: .atomic)
                        self.logger.info("Wrote \(added) bookmarks to Safari Bookmarks.plist from \(sourceBrowser)")
                        
                        // Reset the flag after a delay to allow file system events to clear
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.isWritingInternally = false
                        }
                    } catch {
                        self.logger.error("Failed to write Safari bookmarks: \(error)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.isWritingInternally = false
                        }
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

        let systemRootIds = Set(["0", "1", "2", "3"])
        // Exclude system root folders themselves, and any item parented to the mobile bookmarks root ("3")
        // Mobile bookmarks have no corresponding location in Safari's plist structure.
        let validBookmarks = bookmarks.filter {
            !systemRootIds.contains($0.id) && ($0.parentId == nil || !systemRootIds.subtracting(["1","2"]).contains($0.parentId!))
        }
        var addedCount = 0

        var extractedLeaves = [String: [[String: Any]]]()
        var extractedFolders = [String: [[String: Any]]]()

        func extractExistingNodes(from nodes: inout [[String: Any]]) {
            for i in (0..<nodes.count).reversed() {
                if let url = nodes[i]["URLString"] as? String {
                    if validBookmarks.contains(where: { !$0.isFolder && $0.url == url }) {
                        let removed = nodes.remove(at: i)
                        extractedLeaves[url, default: []].append(removed)
                    }
                } else if let type = nodes[i]["WebBookmarkType"] as? String, type == "WebBookmarkTypeList", let title = nodes[i]["Title"] as? String {
                    if validBookmarks.contains(where: { $0.isFolder && $0.title == title }) {
                        var removed = nodes.remove(at: i)
                        if var subChildren = removed["Children"] as? [[String: Any]] {
                            extractExistingNodes(from: &subChildren)
                            removed["Children"] = subChildren
                        }
                        extractedFolders[title, default: []].append(removed)
                    } else if var subChildren = nodes[i]["Children"] as? [[String: Any]] {
                        extractExistingNodes(from: &subChildren)
                        nodes[i]["Children"] = subChildren
                    }
                } else if var subChildren = nodes[i]["Children"] as? [[String: Any]] {
                    extractExistingNodes(from: &subChildren)
                    nodes[i]["Children"] = subChildren
                }
            }
        }
        
        extractExistingNodes(from: &children)

        func buildNode(from bookmark: SyncBookmark, allBookmarks: [SyncBookmark]) -> [String: Any]? {
            var uuid = UUID().uuidString.lowercased()
            if bookmark.isFolder {
                var nodeBase: [String: Any]? = nil
                if var existingList = extractedFolders[bookmark.title], !existingList.isEmpty {
                    nodeBase = existingList.removeLast()
                    extractedFolders[bookmark.title] = existingList
                    if let oldUuid = nodeBase?["WebBookmarkUUID"] as? String {
                        uuid = oldUuid
                    }
                }
                
                let children = allBookmarks.filter { $0.parentId == bookmark.id }
                var childNodes = children.compactMap { buildNode(from: $0, allBookmarks: allBookmarks) }
                
                // Preserve any Safari-only children that were inside this folder but not in Chrome
                if let oldChildren = nodeBase?["Children"] as? [[String: Any]] {
                    childNodes.append(contentsOf: oldChildren)
                }
                
                return [
                    "WebBookmarkType": "WebBookmarkTypeList",
                    "Title": bookmark.title,
                    "WebBookmarkUUID": uuid,
                    "Children": childNodes,
                    "BrowSyncSourceRoot": bookmark.parentId ?? "2"
                ]
            } else {
                guard let urlStr = bookmark.url else { return nil }
                
                if var existingNodesList = extractedLeaves[urlStr], !existingNodesList.isEmpty {
                    var existingNode = existingNodesList.removeLast()
                    extractedLeaves[urlStr] = existingNodesList
                    
                    existingNode["Title"] = bookmark.title
                    var uriDict = existingNode["URIDictionary"] as? [String: Any] ?? [String: Any]()
                    uriDict["title"] = bookmark.title
                    existingNode["URIDictionary"] = uriDict
                    return existingNode
                }
                
                return [
                    "WebBookmarkType": "WebBookmarkTypeLeaf",
                    "URLString": urlStr,
                    "WebBookmarkUUID": uuid,
                    "ReadingListNonSync": false,
                    "URIDictionary": ["title": bookmark.title],
                    "BrowSyncSourceRoot": bookmark.parentId ?? "2"
                ]
            }
        }

        let rootChromeIds = Set(["0", "1", "2", "3"])

        func mergeLevel(chromeNodes: [SyncBookmark], safariNodes: inout [[String: Any]], isRoot: Bool = false) {
            var newSafariNodes = [[String: Any]]()
            var systemNodes = [(Int, [String: Any])]() // index, node
            
            if isRoot {
                let systemTitles = Set(["BookmarksBar", "BookmarksMenu", "History", "com.apple.ReadingList"])
                for (i, child) in safariNodes.enumerated().reversed() {
                    let isSystemTitle = (child["Title"] as? String).map { systemTitles.contains($0) } ?? false
                    let isReadingList = (child["ReadingListNonSync"] as? Bool) ?? false
                    let type = child["WebBookmarkType"] as? String
                    let isSystemType = (type != "WebBookmarkTypeList" && type != "WebBookmarkTypeLeaf")
                    
                    if isSystemTitle || isReadingList || isSystemType {
                        systemNodes.append((i, safariNodes.remove(at: i)))
                    }
                }
                systemNodes.reverse() // Keep original ascending order
            }
            
            for bookmark in chromeNodes {
                if bookmark.isFolder {
                    if let idx = safariNodes.firstIndex(where: { ($0["WebBookmarkType"] as? String) == "WebBookmarkTypeList" && ($0["Title"] as? String) == bookmark.title }) {
                        var existingFolder = safariNodes.remove(at: idx)
                        var subChildren = existingFolder["Children"] as? [[String: Any]] ?? []
                        let chromeSub = validBookmarks.filter { $0.parentId == bookmark.id }
                        mergeLevel(chromeNodes: chromeSub, safariNodes: &subChildren, isRoot: false)
                        existingFolder["Children"] = subChildren
                        newSafariNodes.append(existingFolder)
                    } else {
                        if let node = buildNode(from: bookmark, allBookmarks: bookmarks) {
                            newSafariNodes.append(node)
                            addedCount += 1
                        }
                    }
                } else if let urlStr = bookmark.url {
                    if var existingNodesList = extractedLeaves[urlStr], !existingNodesList.isEmpty {
                        var existingNode = existingNodesList.removeLast()
                        extractedLeaves[urlStr] = existingNodesList
                        
                        existingNode["Title"] = bookmark.title
                        var uriDict = existingNode["URIDictionary"] as? [String: Any] ?? [String: Any]()
                        uriDict["title"] = bookmark.title
                        existingNode["URIDictionary"] = uriDict
                        newSafariNodes.append(existingNode)
                        addedCount += 1
                    } else {
                        if let node = buildNode(from: bookmark, allBookmarks: bookmarks) {
                            newSafariNodes.append(node)
                            addedCount += 1
                        }
                    }
                }
            }
            
            // Append any remaining Safari-only items that were not in Chrome
            newSafariNodes.append(contentsOf: safariNodes)
            
            if isRoot {
                // Re-insert system nodes at their original indices (or as close as possible)
                for (originalIndex, node) in systemNodes {
                    let insertIndex = min(originalIndex, newSafariNodes.count)
                    newSafariNodes.insert(node, at: insertIndex)
                }
            }
            
            safariNodes = newSafariNodes
        }

        func processRoot(chromeParentId: String, safariTitle: String?, children: inout [[String: Any]]) {
            let topLevelBookmarks = bookmarks.filter {
                guard !rootChromeIds.contains($0.id) else { return false }
                let pid = $0.parentId ?? "1"
                if chromeParentId == "1" {
                    return pid == "1" || pid == "0"
                } else {
                    return pid == chromeParentId
                }
            }

            if let safariTitle = safariTitle {
                guard let idx = children.firstIndex(where: { ($0["Title"] as? String) == safariTitle }),
                      var nodeChildren = children[idx]["Children"] as? [[String: Any]] else { return }

                if isFullMirror {
                    nodeChildren = topLevelBookmarks.compactMap { buildNode(from: $0, allBookmarks: bookmarks) }
                    addedCount += topLevelBookmarks.count
                } else {
                    mergeLevel(chromeNodes: topLevelBookmarks, safariNodes: &nodeChildren, isRoot: false)
                }
                children[idx]["Children"] = nodeChildren
            } else {
                if isFullMirror {
                    let systemTitles = Set(["BookmarksBar", "BookmarksMenu", "History", "com.apple.ReadingList"])
                    children.removeAll { child in
                        if let title = child["Title"] as? String, systemTitles.contains(title) { return false }
                        if let isReadingList = child["ReadingListNonSync"] as? Bool, isReadingList { return false }
                        if let type = child["WebBookmarkType"] as? String, type != "WebBookmarkTypeList" && type != "WebBookmarkTypeLeaf" { return false }
                        return true
                    }
                    let newNodes = topLevelBookmarks.compactMap { buildNode(from: $0, allBookmarks: bookmarks) }
                    children.append(contentsOf: newNodes)
                    addedCount += newNodes.count
                } else {
                    mergeLevel(chromeNodes: topLevelBookmarks, safariNodes: &children, isRoot: true)
                }
            }
        }

        processRoot(chromeParentId: "1", safariTitle: "BookmarksBar", children: &children)
        processRoot(chromeParentId: "2", safariTitle: nil, children: &children)

        // Restore any extracted nodes that weren't placed back (e.g., they were moved to a system folder not managed here)
        for (_, nodesList) in extractedLeaves {
            children.append(contentsOf: nodesList)
        }
        for (_, nodesList) in extractedFolders {
            children.append(contentsOf: nodesList)
        }

        plist["Children"] = children
        return addedCount
    }
    
    // MARK: - Read Safari Bookmarks

    func readBookmarks() -> [SyncBookmark] {
        return SandboxAccessManager.shared.withSafariAccess {
            guard let url = bookmarksURL else { return [] }
            do {
                let data = try Data(contentsOf: url)
                guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let children = plist["Children"] as? [[String: Any]] else {
                    return []
                }

                var result: [SyncBookmark] = []
                
                func traverse(nodes: [[String: Any]], parentId: String?, rootChromeId: String?) {
                    for child in nodes {
                        // Skip any item that was written by BrowSync from Chrome's Mobile Bookmarks root.
                        // These were inserted erroneously in a previous sync and should not be read back.
                        if let sourceRoot = child["BrowSyncSourceRoot"] as? String, sourceRoot == "3" {
                            continue
                        }
                        let isFolder = (child["WebBookmarkType"] as? String) == "WebBookmarkTypeList"
                        let titleDict = child["URIDictionary"] as? [String: Any]
                        let titleStr = titleDict?["title"] as? String ?? child["Title"] as? String ?? child["URLString"] as? String ?? "Untitled"
                        let urlStr = child["URLString"] as? String
                        let id = (child["WebBookmarkUUID"] as? String) ?? UUID().uuidString
                        
                        let effectiveParentId = parentId ?? rootChromeId
                        
                        result.append(SyncBookmark(id: id, title: titleStr, url: urlStr, parentId: effectiveParentId, isFolder: isFolder, inBookmarksBar: effectiveParentId == "1"))
                        
                        if isFolder, let subChildren = child["Children"] as? [[String: Any]] {
                            traverse(nodes: subChildren, parentId: id, rootChromeId: rootChromeId)
                        }
                    }
                }
                
                if let barIdx = children.firstIndex(where: { ($0["Title"] as? String) == "BookmarksBar" }),
                   let barChildren = children[barIdx]["Children"] as? [[String: Any]] {
                    result.append(SyncBookmark(id: "1", title: String(localized: "Favorites", bundle: Bundle.main), url: nil, parentId: "0", isFolder: true, inBookmarksBar: true))
                    traverse(nodes: barChildren, parentId: nil, rootChromeId: "1")
                }
                
                if let menuIdx = children.firstIndex(where: { ($0["Title"] as? String) == "BookmarksMenu" }),
                   let menuChildren = children[menuIdx]["Children"] as? [[String: Any]] {
                    result.append(SyncBookmark(id: "2", title: String(localized: "Bookmarks Menu", bundle: Bundle.main), url: nil, parentId: "0", isFolder: true, inBookmarksBar: false))
                    traverse(nodes: menuChildren, parentId: nil, rootChromeId: "2")
                }
                
                // Process any root-level bookmarks that are not system folders
                let systemTitles = Set(["BookmarksBar", "BookmarksMenu", "History", "com.apple.ReadingList"])
                let rootItems = children.filter { child in
                    if let title = child["Title"] as? String, systemTitles.contains(title) { return false }
                    if let isReadingList = child["ReadingListNonSync"] as? Bool, isReadingList { return false }
                    // Check if it's a proxy or something we shouldn't sync
                    if let type = child["WebBookmarkType"] as? String, type != "WebBookmarkTypeList" && type != "WebBookmarkTypeLeaf" { return false }
                    return true
                }
                if !rootItems.isEmpty {
                    traverse(nodes: rootItems, parentId: nil, rootChromeId: "2")
                }
                
                return result
            } catch {
                logger.error("Failed to read Safari bookmarks: \(error)")
                return []
            }
        }
    }

    // MARK: - Cleanup Mobile Bookmark Contamination

    /// Removes items that were incorrectly synced from Chrome's Mobile Bookmarks root into Safari.
    /// This runs on app startup to clean up contamination from older versions of BrowSync.
    ///
    /// Detection strategy (in priority order, no name matching for ongoing use):
    ///   1. Nodes tagged with BrowSyncSourceRoot="3" — written by the new metadata-aware code.
    ///   2. Root-level folders whose title exactly matches known mobile bookmark folder names
    ///      from major browsers — this is a one-time migration for pre-metadata contamination only.
    func cleanupMobileBookmarkContamination() {
        SandboxAccessManager.shared.withSafariAccess {
            guard let url = bookmarksURL,
                  let data = try? Data(contentsOf: url),
                  var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  var children = plist["Children"] as? [[String: Any]] else { return }

            let knownMobileTitles: Set<String> = [
                "Mobile Bookmarks",      // Chrome/Edge EN
                "移动设备上的书签",        // Chrome/Edge zh-CN (most common)
                "移动设备书签",            // Chrome/Edge zh-CN (variant)
                "移动设备的书签",          // Edge zh-CN (variant)
                "行動裝置書籤",            // zh-TW
                "Marcadores del dispositivo móvil", // ES
                "Mobil yer imleri",       // TR
                "Mobilní záložky",        // CS
            ]

            var didChange = false

            func removeContamination(from nodes: inout [[String: Any]], isAtRoot: Bool) {
                nodes = nodes.filter { node in
                    // Priority 1: metadata tag (ID-based, language-independent)
                    if let sourceRoot = node["BrowSyncSourceRoot"] as? String, sourceRoot == "3" {
                        logger.info("[Cleanup] Removing BrowSync mobile-root node: \(node["Title"] as? String ?? "(unknown)")")
                        didChange = true
                        return false
                    }
                    // Priority 2: one-time name-based migration for pre-metadata contamination
                    // Only at root level to avoid false positives (user could have a similarly-named folder inside another folder)
                    if isAtRoot,
                       let title = node["Title"] as? String,
                       knownMobileTitles.contains(title) {
                        logger.info("[Cleanup] Removing pre-metadata mobile bookmark contamination: \"\(title)\"")
                        didChange = true
                        return false
                    }
                    return true
                }
            }

            // Check Safari root level items (not system folders)
            let systemTitles = Set(["BookmarksBar", "BookmarksMenu", "History", "com.apple.ReadingList"])
            var rootUserItems = children.filter {
                guard let t = $0["Title"] as? String else { return true }
                return !systemTitles.contains(t)
            }
            removeContamination(from: &rootUserItems, isAtRoot: true)

            // Rebuild children with cleaned root items
            var cleanedChildren = children.filter {
                if let t = $0["Title"] as? String, systemTitles.contains(t) { return true }
                return false
            }
            cleanedChildren.append(contentsOf: rootUserItems)

            // Also clean inside BookmarksBar and BookmarksMenu (non-root, metadata-only)
            for i in 0..<cleanedChildren.count {
                if var subChildren = cleanedChildren[i]["Children"] as? [[String: Any]] {
                    removeContamination(from: &subChildren, isAtRoot: false)
                    cleanedChildren[i]["Children"] = subChildren
                }
            }

            guard didChange else { return }

            plist["Children"] = cleanedChildren
            isWritingInternally = true
            if let newData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? newData.write(to: url, options: .atomic)
                logger.info("[Cleanup] Safari plist cleaned of mobile bookmark contamination.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.isWritingInternally = false
            }
        }
    }

    // MARK: - Ensure Folder Exists

    
    func ensureFolderExists(path: String) {
        let bookmarks = readBookmarks()
        var targetTree = bookmarks.map { Bookmark(id: $0.id, title: $0.title, url: $0.url, parentId: $0.parentId, isFolder: $0.isFolder, inBookmarksBar: $0.inBookmarksBar, dateAdded: Date(), sourceBrowser: .safari) }
        
        let components = path.components(separatedBy: "/")
        _ = BookmarkTreeMerger.ensureFolderPath(components: components, in: &targetTree)
        
        let finalBookmarks = targetTree.compactMap { b -> SyncBookmark? in
            let urlStr: String?
            if let urlOpt = b.url { urlStr = urlOpt } else { urlStr = nil }
            if !b.isFolder && urlStr == nil { return nil }
            return SyncBookmark(id: b.id, title: b.title, url: urlStr, parentId: b.parentId, isFolder: b.isFolder, inBookmarksBar: b.inBookmarksBar ?? false)
        }
        
        _ = applyBookmarks(finalBookmarks, from: "Local UI", isFullMirror: true)
    }

    // MARK: - Remove Safari Bookmark

    @discardableResult
    func removeBookmark(id: String, title: String? = nil, url: String? = nil) -> Bool {
        guard let urlPath = bookmarksURL else { return false }
        do {
            let data = try Data(contentsOf: urlPath)
            guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  var children = plist["Children"] as? [[String: Any]] else {
                return false
            }
            
            var didRemove = false
            func traverseAndRemove(nodes: inout [[String: Any]]) {
                nodes.removeAll { node in
                    if let uuid = node["WebBookmarkUUID"] as? String, uuid == id {
                        didRemove = true
                        return true
                    }
                    if let t = title, let u = url, let nodeU = node["URLString"] as? String {
                        let nodeT = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? node["Title"] as? String
                        if nodeU == u && nodeT == t {
                            didRemove = true
                            return true
                        }
                    } else if let t = title, url == nil, (node["WebBookmarkType"] as? String) == "WebBookmarkTypeList" {
                        if let nodeT = node["Title"] as? String, nodeT == t {
                            didRemove = true
                            return true
                        }
                    }
                    return false
                }
                for i in 0..<nodes.count {
                    if var subChildren = nodes[i]["Children"] as? [[String: Any]] {
                        traverseAndRemove(nodes: &subChildren)
                        nodes[i]["Children"] = subChildren
                    }
                }
            }
            
            traverseAndRemove(nodes: &children)
            
            if didRemove {
                plist["Children"] = children
                let newData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try newData.write(to: urlPath, options: .atomic)
                logger.info("Removed Safari bookmark with ID: \(id) or title: \(title ?? "")")
                return true
            }
            return false
        } catch {
            logger.error("Failed to remove Safari bookmark: \(error)")
            return false
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
import Foundation
import os.log

@MainActor
final class SafariCleanup {
    static func cleanDirtyBookmarks() {
        let logger = Logger(subsystem: "com.ct106.browsync", category: "SafariCleanup")
        // SafariCleanup must also go through withSafariAccess on App Store builds
        // to get a security-scoped resource for the real ~/Library/Safari path.
        SandboxAccessManager.shared.withSafariAccess {
#if APP_STORE
            let bookmarksPlistURL = SandboxAccessManager.shared.safariBookmarksPlistURL
#else
            let bookmarksPlistURL: URL? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
#endif
            guard let url = bookmarksPlistURL,
                  let data = try? Data(contentsOf: url),
                  var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  var children = plist["Children"] as? [[String: Any]] else {
                return
            }

            let dirtyNames: Set<String> = ["bookmarks bar", "书签栏", "favorites", "收藏夹栏", "other bookmarks", "其他书签", "其他收藏夹"]
            var modified = false

            func cleanNode(_ nodeChildren: inout [[String: Any]]) {
                var newChildren = [[String: Any]]()
                for child in nodeChildren {
                    if let type = child["WebBookmarkType"] as? String, type == "WebBookmarkTypeList",
                       let title = child["Title"] as? String, dirtyNames.contains(title.lowercased()) {
                        logger.info("Found dirty folder: \(title), extracting its contents...")
                        if let subChildren = child["Children"] as? [[String: Any]] {
                            newChildren.append(contentsOf: subChildren)
                        }
                        modified = true
                    } else {
                        var cleanChild = child
                        if var subChildren = cleanChild["Children"] as? [[String: Any]] {
                            cleanNode(&subChildren)
                            cleanChild["Children"] = subChildren
                        }
                        newChildren.append(cleanChild)
                    }
                }
                nodeChildren = newChildren
            }

            if let barIdx = children.firstIndex(where: { ($0["Title"] as? String) == "BookmarksBar" }),
               var barChildren = children[barIdx]["Children"] as? [[String: Any]] {
                cleanNode(&barChildren)
                children[barIdx]["Children"] = barChildren
            }

            if let menuIdx = children.firstIndex(where: { ($0["Title"] as? String) == "BookmarksMenu" }),
               var menuChildren = children[menuIdx]["Children"] as? [[String: Any]] {
                cleanNode(&menuChildren)
                children[menuIdx]["Children"] = menuChildren
            }

            if modified {
                plist["Children"] = children
                do {
                    let newData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                    try newData.write(to: url, options: .atomic)
                    logger.info("Successfully cleaned up dirty bookmarks!")
                } catch {
                    logger.error("Failed to save: \(error)")
                }
            }
        } // end withSafariAccess
    } // end cleanDirtyBookmarks
} // end SafariCleanup
