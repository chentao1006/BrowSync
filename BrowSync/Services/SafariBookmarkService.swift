// SafariBookmarkService.swift
// BrowSync — Writes bookmarks to Safari's Bookmarks.plist via native macOS API

import Foundation
import os.log
import AppKit
import CryptoKit

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
    private static let maxOrphanedFolderPruneCount = 2
    /// Returned by `applyBookmarks` when a guarded write was held for confirmation.
    static let blockedLargeChange = -2
    static let writeFailed = -3
    static let unauthorizedWrite = -4

    /// How many existing, user-visible Safari items a write would remove or
    /// relocate. Only an item whose own parent changes counts as moved; the
    /// contents of a moved folder travel with it.
    struct WriteImpact: Equatable {
        let added: Int
        let removed: Int
        let moved: Int
        /// Existing items whose title or URL would be rewritten in place.
        let modified: Int
        let total: Int
        /// Stable description of the change. Items BrowSync would create get a
        /// random UUID on every computation, so they are described by content
        /// instead; recomputing the same change yields the same signature.
        let signature: String
        /// The same, ignoring additions: a rejected removal/move/rewrite stays
        /// rejected even when the source browser later adds something.
        let destructiveSignature: String
        var affected: Int { removed + moved + modified }
        var changeCount: Int { added + affected }
        var requiresConfirmation: Bool { affected > max(8, total / 20) }
    }

    /// A computed write held for review. `resultPlist` is exactly what the
    /// review window shows and exactly what `commitHeldWrite` writes.
    struct HeldWrite {
        let impact: WriteImpact
        let preview: BookmarkChangePreview
        fileprivate let originalData: Data
        fileprivate let resultPlist: [String: Any]
        fileprivate let added: Int
    }
    private(set) var lastBlockedWrite: HeldWrite?

    private var bookmarksURL: URL? {
        // Must be called inside withSafariAccess so the security-scoped resource is active.
        // SandboxAccessManager caches the resolved URL for this purpose.
        return SandboxAccessManager.shared.safariBookmarksPlistURL
    }

    private var isSafariRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Safari" }
    }

    /// Final write-boundary policy. Callers cannot bypass bookmark OFF or a
    /// one-way source by reaching a maintenance/restore helper directly.
    private func safariWriteIsAuthorized(explicitRestore: Bool = false) -> Bool {
        let settings = AppState.shared.settingsService.syncSettings
        guard BookmarkWritePolicy.allowsWrite(to: .safari, settings: settings, explicitRestore: explicitRestore) else {
            logger.warning("Refusing Safari bookmark write: sync is off, Safari is not participating, or Safari is the read-only one-way source")
            return false
        }
        return true
    }

    // MARK: - Apply bookmarks from another browser

    /// Returns the number of bookmarks applied or staged.
    /// - Parameter guardLargeChanges: refuse (returning `blockedLargeChange`
    ///   and setting `lastBlockedWrite`) a write that would remove or move many
    ///   existing items. Automatic syncs set this; user-initiated restores and
    ///   edits do not.
    @discardableResult
    func applyBookmarks(_ bookmarks: [SyncBookmark], from sourceBrowser: String, isFullMirror: Bool = false, guardLargeChanges: Bool = false,
                        bypassSafeModeReview: Bool = false, explicitRestore: Bool = false) -> Int {
        guard safariWriteIsAuthorized(explicitRestore: explicitRestore) else { return Self.unauthorizedWrite }
        return SandboxAccessManager.shared.withSafariAccess {
            guard let url = bookmarksURL else {
                logger.warning("Safari Bookmarks.plist not found, skipping")
                return Self.writeFailed
            }

            installMonitorEventHandler()
            
            do {
                let data = try Data(contentsOf: url)
                guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    logger.warning("Could not parse Bookmarks.plist")
                    return Self.writeFailed
                }

                let originalPlist = plist
                let added = insertBookmarks(bookmarks, into: &plist, sourceBrowser: sourceBrowser, isFullMirror: isFullMirror)
                guard added >= 0 else {
                    logger.error("Safari bookmark merge validation failed; nothing was written.")
                    return Self.writeFailed
                }
                if added == 0 && !isFullMirror {
                    logger.info("No new bookmarks to add from \(sourceBrowser)")
                    return 0
                }

                lastBlockedWrite = nil
                if !bypassSafeModeReview && (guardLargeChanges || AppState.shared.settingsService.syncSettings.bookmarkSafeMode) {
                    let impact = Self.writeImpact(before: originalPlist, after: plist)
                    if impact.requiresConfirmation || (AppState.shared.settingsService.syncSettings.bookmarkSafeMode && (impact.affected > 0 || added > 0)) {
                        logger.warning("Holding Safari write from \(sourceBrowser): \(impact.removed) removed, \(impact.moved) moved of \(impact.total).")
                        lastBlockedWrite = HeldWrite(
                            impact: impact,
                            preview: Self.changePreview(before: originalPlist, after: plist),
                            originalData: data,
                            resultPlist: plist,
                            added: added
                        )
                        return Self.blockedLargeChange
                    }
                }

                // Generate HTML backup as a fallback just in case
                if let html = exportHTML(bookmarks, from: sourceBrowser) {
                    logger.info("HTML exported to \(html.path) as fallback.")
                }
                
                // macOS automatically reloads Bookmarks.plist even when Safari is running
                return writePlist(plist, to: url, added: added, sourceBrowser: sourceBrowser, explicitRestore: explicitRestore) ? added : Self.writeFailed
            } catch {
                logger.error("Failed to process Safari bookmarks: \(error)")
                return Self.writeFailed
            }
        }
    }

    /// Writes a held result exactly as it was reviewed, provided Bookmarks.plist
    /// is byte-for-byte what it was when the result was computed. Returns nil
    /// when Safari's bookmarks changed in the meantime; the caller must then
    /// recompute and ask again rather than write something nobody reviewed.
    func commitHeldWrite(_ held: HeldWrite, from sourceBrowser: String, explicitRestore: Bool = false) -> Int? {
        guard safariWriteIsAuthorized(explicitRestore: explicitRestore) else { return nil }
        return SandboxAccessManager.shared.withSafariAccess {
            guard let url = bookmarksURL,
                  let current = try? Data(contentsOf: url),
                  current == held.originalData else { return nil }
            installMonitorEventHandler()
            return writePlist(held.resultPlist, to: url, added: held.added, sourceBrowser: sourceBrowser, explicitRestore: explicitRestore) ? held.added : nil
        }
    }

    /// Commits only the reviewed node changes. Unselected changes are rebuilt
    /// from the original plist, so they remain eligible for a future preview.
    func commitHeldWrite(_ held: HeldWrite, selectedNodeIds: Set<String>, from sourceBrowser: String, explicitRestore: Bool = false) -> Int? {
        guard safariWriteIsAuthorized(explicitRestore: explicitRestore) else { return nil }
        return SandboxAccessManager.shared.withSafariAccess {
            guard let url = bookmarksURL,
                  let current = try? Data(contentsOf: url),
                  current == held.originalData,
                  let original = try? PropertyListSerialization.propertyList(from: held.originalData, format: nil) as? [String: Any] else { return nil }
            let before = Self.visibleNodes(original)
            let after = Self.visibleNodes(held.resultPlist)
            var result = original

            func remove(_ id: String, nodes: inout [[String: Any]]) -> [String: Any]? {
                if let index = nodes.firstIndex(where: { $0["WebBookmarkUUID"] as? String == id }) { return nodes.remove(at: index) }
                for index in nodes.indices {
                    var children = nodes[index]["Children"] as? [[String: Any]] ?? []
                    if let found = remove(id, nodes: &children) { nodes[index]["Children"] = children; return found }
                }
                return nil
            }
            func insert(_ node: [String: Any], parent: String, index: Int, nodes: inout [[String: Any]]) -> Bool {
                if parent.isEmpty { nodes.insert(node, at: min(index, nodes.count)); return true }
                for i in nodes.indices {
                    if nodes[i]["WebBookmarkUUID"] as? String == parent {
                        var children = nodes[i]["Children"] as? [[String: Any]] ?? []
                        children.insert(node, at: min(index, children.count)); nodes[i]["Children"] = children; return true
                    }
                    var children = nodes[i]["Children"] as? [[String: Any]] ?? []
                    if insert(node, parent: parent, index: index, nodes: &children) { nodes[i]["Children"] = children; return true }
                }
                return false
            }
            func find(_ id: String, nodes: [[String: Any]]) -> [String: Any]? {
                for node in nodes {
                    if node["WebBookmarkUUID"] as? String == id { return node }
                    if let found = find(id, nodes: node["Children"] as? [[String: Any]] ?? []) { return found }
                }
                return nil
            }
            var nodes = result["Children"] as? [[String: Any]] ?? []
            for id in selectedNodeIds where before[id] != nil && after[id] == nil { _ = remove(id, nodes: &nodes) }
            for id in selectedNodeIds {
                guard let new = after[id], let afterNode = find(id, nodes: held.resultPlist["Children"] as? [[String: Any]] ?? []) else { continue }
                let old = before[id]
                if old == nil || old?.parent != new.parent || old?.index != new.index {
                    let existing = remove(id, nodes: &nodes) ?? afterNode
                    _ = insert(existing, parent: new.parent, index: new.index, nodes: &nodes)
                }
                if old != nil, old?.content != new.content || old?.title != new.title {
                    if var currentNode = remove(id, nodes: &nodes) {
                        let children = currentNode["Children"]
                        currentNode = afterNode
                        if let children { currentNode["Children"] = children }
                        _ = insert(currentNode, parent: new.parent, index: new.index, nodes: &nodes)
                    }
                }
            }
            result["Children"] = nodes
            let added = selectedNodeIds.filter { before[$0] == nil && after[$0] != nil }.count
            installMonitorEventHandler()
            return writePlist(result, to: url, added: added, sourceBrowser: sourceBrowser, explicitRestore: explicitRestore) ? added : nil
        }
    }

    private func installMonitorEventHandler() {
        fileMonitor?.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.isWritingInternally {
                self.logger.debug("Ignoring Bookmarks.plist change because it was triggered by a sync write")
                return
            }
            print("[\(Date().ISO8601Format())] Safari Bookmarks.plist changed! Triggering auto-sync...")
            NotificationCenter.default.post(name: NSNotification.Name("SafariBookmarksChanged"), object: nil)
        }
    }

    @discardableResult
    private func writePlist(_ plist: [String: Any], to url: URL, added: Int, sourceBrowser: String, explicitRestore: Bool = false) -> Bool {
        // Final write boundary. Only a user-confirmed restore may write to a
        // one-way source; OFF and non-participation always refuse.
        guard safariWriteIsAuthorized(explicitRestore: explicitRestore) else { return false }
        do {
            isWritingInternally = true
            let newData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try newData.write(to: url, options: .atomic)
            let persisted = try Data(contentsOf: url)
            guard persisted == newData else {
                logger.error("Safari bookmark verification failed after atomic replacement")
                isWritingInternally = false
                return false
            }
            logger.info("Wrote \(added) bookmarks to Safari Bookmarks.plist from \(sourceBrowser)")
        } catch {
            logger.error("Failed to write Safari bookmarks: \(error)")
            isWritingInternally = false
            return false
        }
        // Reset the flag after a delay to allow file system events to clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.isWritingInternally = false
        }
        return true
    }

    /// History, Reading List and other special nodes are not shown in the
    /// review, so they are not counted either.
    nonisolated private static func isHiddenSystemNode(_ node: [String: Any]) -> Bool {
        SafariPlist.isHiddenSystemNode(node)
    }

    /// Visible nodes as UUID -> (parent UUID, content description, title).
    nonisolated private static func visibleNodes(_ plist: [String: Any]) -> [String: (parent: String, index: Int, content: String, title: String)] {
        SafariPlist.visibleNodes(plist)
    }

    private static func writeImpact(before: [String: Any], after: [String: Any]) -> WriteImpact {
        let old = visibleNodes(before)
        let new = visibleNodes(after)
        // Existing nodes keep their UUID; new ones are identified by content
        // path, because their UUID is regenerated on every computation.
        var stableIds = [String: String]()
        func stableId(_ uuid: String) -> String {
            if old[uuid] != nil { return uuid }
            if let cached = stableIds[uuid] { return cached }
            guard let node = new[uuid] else { return "" }
            let id = (node.parent.isEmpty ? "" : stableId(node.parent)) + "/" + node.content + "|" + node.title
            stableIds[uuid] = id
            return id
        }
        var removed = 0
        var moved = 0
        var modified = 0
        var changes = [String]()
        for (uuid, node) in old {
            guard let newNode = new[uuid] else {
                removed += 1
                changes.append("-" + uuid)
                continue
            }
            if newNode.parent != node.parent || newNode.index != node.index {
                moved += 1
                changes.append(">" + uuid + "@" + stableId(newNode.parent))
            }
            if newNode.content != node.content || newNode.title != node.title {
                modified += 1
                changes.append("~" + uuid + "=" + newNode.content + "|" + newNode.title)
            }
        }
        let destructive = changes.sorted()
        let additions = new.keys.filter { old[$0] == nil }.map { "+" + stableId($0) }
        func digest(_ lines: [String]) -> String {
            SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return WriteImpact(
            added: additions.count,
            removed: removed,
            moved: moved,
            modified: modified,
            total: old.count,
            signature: digest(destructive + additions.sorted()),
            destructiveSignature: digest(destructive)
        )
    }

    /// Both trees as the user sees them in Safari, each node marked by what
    /// the write does to it. Only a node whose own parent changes is "moved";
    /// its contents travel with it and stay unmarked.
    static func changePreview(before: [String: Any], after: [String: Any]) -> BookmarkChangePreview {
        func locations(_ plist: [String: Any]) -> [String: (parent: String, index: Int)] {
            var result = [String: (parent: String, index: Int)]()
            func walk(_ nodes: [[String: Any]], parent: String) {
                for (index, node) in nodes.enumerated() {
                    guard let uuid = node["WebBookmarkUUID"] as? String else { continue }
                    result[uuid] = (parent, index)
                    walk(node["Children"] as? [[String: Any]] ?? [], parent: uuid)
                }
            }
            walk(plist["Children"] as? [[String: Any]] ?? [], parent: "")
            return result
        }
        let oldLocations = locations(before)
        let newLocations = locations(after)
        let oldContent = visibleNodes(before).mapValues { $0.content + "|" + $0.title }
        let newContent = visibleNodes(after).mapValues { $0.content + "|" + $0.title }

        let langBundle = LanguageBundle(language: AppState.shared.settingsService.general.language).bundle
        func displayTitle(_ node: [String: Any]) -> String {
            let identifier = node["WebBookmarkIdentifier"] as? String
            let title = node["Title"] as? String
            if identifier == "BookmarksBar" || title == "BookmarksBar" { return String(localized: "Favorites", bundle: langBundle) }
            if identifier == "BookmarksMenu" || title == "BookmarksMenu" { return String(localized: "Bookmarks Menu", bundle: langBundle) }
            return (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? title ?? ""
        }

        func build(_ nodes: [[String: Any]], isBefore: Bool) -> [BookmarkReviewNode] {
            nodes.enumerated().compactMap { index, node in
                guard !isHiddenSystemNode(node) else { return nil }
                let uuid = node["WebBookmarkUUID"] as? String
                var change = BookmarkReviewNode.Change.unchanged
                if let uuid {
                    let ownSide = isBefore ? oldLocations : newLocations
                    let otherSide = isBefore ? newLocations : oldLocations
                    if let otherLocation = otherSide[uuid] {
                        if let ownLocation = ownSide[uuid], otherLocation.parent != ownLocation.parent || otherLocation.index != ownLocation.index {
                            change = .moved
                        } else if let a = oldContent[uuid], let b = newContent[uuid], a != b {
                            change = .modified
                        }
                    } else {
                        change = isBefore ? .removed : .added
                    }
                }
                let url = node["URLString"] as? String
                return BookmarkReviewNode(
                    id: uuid ?? "\(isBefore)-\(index)-\(displayTitle(node))",
                    title: displayTitle(node),
                    url: url,
                    isFolder: url == nil,
                    change: change,
                    children: build(node["Children"] as? [[String: Any]] ?? [], isBefore: isBefore)
                )
            }
        }

        return BookmarkChangePreview(
            before: build(before["Children"] as? [[String: Any]] ?? [], isBefore: true),
            after: build(after["Children"] as? [[String: Any]] ?? [], isBefore: false)
        )
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
        let syncableRootIds = Set(["1", "2"])
        // “Restore Missing Items” must be additive. Never let its merge path
        // prune folders merely because they are absent from a backup.
        let pruneOrphanedManagedFolders = sourceBrowser != "Backup Restore"
        let shouldFilterBrowserSystemRoots = !sourceBrowser.localizedCaseInsensitiveContains("safari") && sourceBrowser != "Local UI"
        var byId: [String: SyncBookmark] = [:]
        for bookmark in bookmarks {
            byId[bookmark.id] = bookmark
        }
        var exclusionMemo: [String: Bool] = [:]
        var visitingIds = Set<String>()

        func isBrowserSystemRoot(_ bookmark: SyncBookmark) -> Bool {
            let rootLikeId = bookmark.id == "3" || bookmark.id.lowercased().hasPrefix("mobile")
            return shouldFilterBrowserSystemRoots &&
            bookmark.isFolder &&
            bookmark.url == nil &&
            (rootLikeId ||
             (bookmark.dateAdded == nil &&
              (bookmark.parentId.map { $0 == "0" || syncableRootIds.contains($0) } ?? true)))
        }

        func isExcludedFromSafari(_ bookmark: SyncBookmark) -> Bool {
            if let cached = exclusionMemo[bookmark.id] { return cached }
            if visitingIds.contains(bookmark.id) { return true }
            visitingIds.insert(bookmark.id)
            defer { visitingIds.remove(bookmark.id) }

            let excluded: Bool
            if systemRootIds.contains(bookmark.id) {
                excluded = true
            } else if isBrowserSystemRoot(bookmark) {
                excluded = true
            } else if let parentId = bookmark.parentId {
                if syncableRootIds.contains(parentId) {
                    excluded = false
                } else if parentId == "0" || systemRootIds.contains(parentId) {
                    excluded = true
                } else if let parent = byId[parentId] {
                    excluded = isExcludedFromSafari(parent)
                } else {
                    excluded = false
                }
            } else {
                excluded = false
            }

            exclusionMemo[bookmark.id] = excluded
            return excluded
        }

        // Exclude browser system roots and every descendant of non-syncable roots.
        // This intentionally uses structural parent IDs, not localized folder titles.
        let validBookmarks = bookmarks.filter { !isExcludedFromSafari($0) }
        var addedCount = 0

        func syncServerId(of node: [String: Any]) -> String? {
            (node["Sync"] as? [String: Any])?["ServerID"] as? String
        }

        func isBookmarksBarNode(_ node: [String: Any]) -> Bool {
            (node["Title"] as? String) == "BookmarksBar" ||
            (node["WebBookmarkIdentifier"] as? String) == "BookmarksBar" ||
            syncServerId(of: node) == "Favorites Bar"
        }

        func isBookmarksMenuNode(_ node: [String: Any]) -> Bool {
            (node["Title"] as? String) == "BookmarksMenu" ||
            (node["WebBookmarkIdentifier"] as? String) == "BookmarksMenu" ||
            syncServerId(of: node) == "Bookmarks Menu"
        }

        func isSafariSystemNode(_ node: [String: Any]) -> Bool {
            if isBookmarksBarNode(node) || isBookmarksMenuNode(node) { return true }
            if (node["WebBookmarkIdentifier"] as? String) == "History" { return true }
            if (node["Title"] as? String) == "History" || (node["Title"] as? String) == "com.apple.ReadingList" { return true }
            if (node["ReadingListNonSync"] as? Bool) == true { return true }
            if let type = node["WebBookmarkType"] as? String, type != "WebBookmarkTypeList" && type != "WebBookmarkTypeLeaf" { return true }
            return false
        }

        var extractedLeavesByID = [String: [String: Any]]()
        var extractedLeavesByURL = [String: [[String: Any]]]()
        var extractedFolders = [String: [[String: Any]]]()
        // A folder renamed in another browser keeps its Safari UUID as its sync
        // ID; matching by title alone would rebuild it as a new folder and
        // count every child as moved.
        var extractedFoldersByID = [String: [String: Any]]()
        struct ExtractedOrigin {
            let parentUUID: String?
            let index: Int
            let depth: Int
            let systemRoot: String?
        }
        var extractedOrigins = [String: ExtractedOrigin]()
        let incomingFolderIDs = Set(validBookmarks.filter(\.isFolder).map(\.id))

        let incomingLeafIDs = Set(validBookmarks.filter { !$0.isFolder }.map(\.id))
        let incomingLeafURLs = Set(validBookmarks.compactMap { bookmark -> String? in
            guard !bookmark.isFolder else { return nil }
            return bookmark.url.flatMap { $0 }
        })

        func rememberOrigin(of node: [String: Any], parentUUID: String?, index: Int, depth: Int, systemRoot: String?) {
            guard let uuid = node["WebBookmarkUUID"] as? String else { return }
            extractedOrigins[uuid] = ExtractedOrigin(parentUUID: parentUUID, index: index, depth: depth, systemRoot: systemRoot)
        }

        func extractExistingNodes(from nodes: inout [[String: Any]], parentUUID: String? = nil, depth: Int = 0, systemRoot: String? = nil) {
            for i in (0..<nodes.count).reversed() {
                // Reading List, History and other special nodes are not
                // bookmarks; a matching URL there must never be pulled out.
                if Self.isHiddenSystemNode(nodes[i]) { continue }
                if let url = nodes[i]["URLString"] as? String {
                    let uuid = nodes[i]["WebBookmarkUUID"] as? String
                    if let uuid, incomingLeafIDs.contains(uuid) {
                        let removed = nodes.remove(at: i)
                        rememberOrigin(of: removed, parentUUID: parentUUID, index: i, depth: depth, systemRoot: systemRoot)
                        extractedLeavesByID[uuid] = removed
                    } else if incomingLeafURLs.contains(url) {
                        let removed = nodes.remove(at: i)
                        rememberOrigin(of: removed, parentUUID: parentUUID, index: i, depth: depth, systemRoot: systemRoot)
                        extractedLeavesByURL[url, default: []].append(removed)
                    }
                } else if let type = nodes[i]["WebBookmarkType"] as? String, type == "WebBookmarkTypeList",
                          let uuid = nodes[i]["WebBookmarkUUID"] as? String, incomingFolderIDs.contains(uuid),
                          !isSafariSystemNode(nodes[i]) {
                    var removed = nodes.remove(at: i)
                    rememberOrigin(of: removed, parentUUID: parentUUID, index: i, depth: depth, systemRoot: systemRoot)
                    if var subChildren = removed["Children"] as? [[String: Any]] {
                        extractExistingNodes(from: &subChildren, parentUUID: uuid, depth: depth + 1, systemRoot: systemRoot)
                        removed["Children"] = subChildren
                    }
                    if extractedFoldersByID[uuid] == nil {
                        extractedFoldersByID[uuid] = removed
                    } else {
                        // Corrupt plist with a duplicate UUID: keep the second
                        // folder through the title path instead of dropping it.
                        extractedFolders[(removed["Title"] as? String) ?? "", default: []].append(removed)
                    }
                } else if let type = nodes[i]["WebBookmarkType"] as? String, type == "WebBookmarkTypeList", let title = nodes[i]["Title"] as? String {
                    if validBookmarks.contains(where: { $0.isFolder && $0.title == title }) {
                        var removed = nodes.remove(at: i)
                        rememberOrigin(of: removed, parentUUID: parentUUID, index: i, depth: depth, systemRoot: systemRoot)
                        if var subChildren = removed["Children"] as? [[String: Any]] {
                            extractExistingNodes(from: &subChildren, parentUUID: removed["WebBookmarkUUID"] as? String,
                                                 depth: depth + 1, systemRoot: systemRoot)
                            removed["Children"] = subChildren
                        }
                        extractedFolders[title, default: []].append(removed)
                    } else if var subChildren = nodes[i]["Children"] as? [[String: Any]] {
                        let childRoot = isBookmarksBarNode(nodes[i]) ? "bar" : (isBookmarksMenuNode(nodes[i]) ? "menu" : systemRoot)
                        extractExistingNodes(from: &subChildren, parentUUID: nodes[i]["WebBookmarkUUID"] as? String,
                                             depth: depth + 1, systemRoot: childRoot)
                        nodes[i]["Children"] = subChildren
                    }
                } else if var subChildren = nodes[i]["Children"] as? [[String: Any]] {
                    let childRoot = isBookmarksBarNode(nodes[i]) ? "bar" : (isBookmarksMenuNode(nodes[i]) ? "menu" : systemRoot)
                    extractExistingNodes(from: &subChildren, parentUUID: nodes[i]["WebBookmarkUUID"] as? String,
                                         depth: depth + 1, systemRoot: childRoot)
                    nodes[i]["Children"] = subChildren
                }
            }
        }
        
        extractExistingNodes(from: &children)

        func incomingSystemRoot(for bookmark: SyncBookmark) -> String {
            var parent = bookmark.parentId ?? "1"
            var seen = Set<String>()
            while seen.insert(parent).inserted {
                if parent == "2" { return "menu" }
                if parent == "1" || parent == "0" { return "bar" }
                guard let ancestor = byId[parent] else { break }
                parent = ancestor.parentId ?? "1"
            }
            return "bar"
        }

        func originMatches(_ node: [String: Any], bookmark: SyncBookmark) -> Bool {
            guard let uuid = node["WebBookmarkUUID"] as? String,
                  let origin = extractedOrigins[uuid] else { return false }
            let desired = incomingSystemRoot(for: bookmark)
            // Legacy BrowSync versions stored Other Bookmarks directly at the
            // plist top level. Treat that legacy location as BookmarksMenu,
            // never as Favorites/Bookmarks Bar.
            return origin.systemRoot == desired || (origin.systemRoot == nil && desired == "menu")
        }

        func takeLeafByURL(_ url: String, for bookmark: SyncBookmark) -> [String: Any]? {
            guard var candidates = extractedLeavesByURL[url],
                  let index = candidates.firstIndex(where: { originMatches($0, bookmark: bookmark) }) else { return nil }
            let node = candidates.remove(at: index)
            extractedLeavesByURL[url] = candidates
            return node
        }

        func takeFolderByTitle(_ title: String, for bookmark: SyncBookmark) -> [String: Any]? {
            guard var candidates = extractedFolders[title],
                  let index = candidates.firstIndex(where: { originMatches($0, bookmark: bookmark) }) else { return nil }
            let node = candidates.remove(at: index)
            extractedFolders[title] = candidates
            return node
        }

        func buildNode(from bookmark: SyncBookmark, allBookmarks: [SyncBookmark]) -> [String: Any]? {
            var uuid = UUID().uuidString.lowercased()
            if bookmark.isFolder {
                var nodeBase: [String: Any]? = extractedFoldersByID.removeValue(forKey: bookmark.id)
                if let byID = nodeBase, let oldUuid = byID["WebBookmarkUUID"] as? String {
                    uuid = oldUuid
                } else if let existing = takeFolderByTitle(bookmark.title, for: bookmark) {
                    nodeBase = existing
                    if let oldUuid = nodeBase?["WebBookmarkUUID"] as? String {
                        uuid = oldUuid
                    }
                }
                
                let children = orderedSiblings(allBookmarks.filter { $0.parentId == bookmark.id })
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

                var existingNode = extractedLeavesByID.removeValue(forKey: bookmark.id)
                if existingNode == nil { existingNode = takeLeafByURL(urlStr, for: bookmark) }

                if var existingNode {
                    existingNode["URLString"] = urlStr
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

        func orderedSiblings(_ nodes: [SyncBookmark]) -> [SyncBookmark] {
            // Older peers omit sortIndex; keep their payload order as the fallback.
            nodes.enumerated().sorted { lhs, rhs in
                let left = lhs.element.sortIndex ?? lhs.offset
                let right = rhs.element.sortIndex ?? rhs.offset
                return left == right ? lhs.offset < rhs.offset : left < right
            }.map(\.element)
        }

        func mergeLevel(chromeNodes: [SyncBookmark], safariNodes: inout [[String: Any]], isRoot: Bool = false, pruneOrphanedManagedFolders: Bool = false) {
            var newSafariNodes = [[String: Any]]()
            var systemNodes = [(Int, [String: Any])]() // index, node
            let incomingFolderTitles = Set(chromeNodes.filter(\.isFolder).map(\.title))
            
            if isRoot {
                for (i, child) in safariNodes.enumerated().reversed() {
                    if isSafariSystemNode(child) {
                        systemNodes.append((i, safariNodes.remove(at: i)))
                    }
                }
                systemNodes.reverse() // Keep original ascending order
            }
            
            for bookmark in orderedSiblings(chromeNodes) {
                if bookmark.isFolder {
                    if let idx = safariNodes.firstIndex(where: { ($0["WebBookmarkType"] as? String) == "WebBookmarkTypeList" && ($0["WebBookmarkUUID"] as? String) == bookmark.id })
                    ?? safariNodes.firstIndex(where: { ($0["WebBookmarkType"] as? String) == "WebBookmarkTypeList" && ($0["Title"] as? String) == bookmark.title }) {
                        var existingFolder = safariNodes.remove(at: idx)
                        existingFolder["Title"] = bookmark.title
                        var subChildren = existingFolder["Children"] as? [[String: Any]] ?? []
                        let chromeSub = orderedSiblings(validBookmarks.filter { $0.parentId == bookmark.id })
                        mergeLevel(chromeNodes: chromeSub, safariNodes: &subChildren, isRoot: false)
                        existingFolder["Children"] = subChildren
                        newSafariNodes.append(existingFolder)
                    } else {
                        if let node = buildNode(from: bookmark, allBookmarks: validBookmarks) {
                            newSafariNodes.append(node)
                            addedCount += 1
                        }
                    }
                } else if let urlStr = bookmark.url {
                    var existingNode = extractedLeavesByID.removeValue(forKey: bookmark.id)
                    if existingNode == nil { existingNode = takeLeafByURL(urlStr, for: bookmark) }

                    if var existingNode {
                        existingNode["URLString"] = urlStr
                        existingNode["Title"] = bookmark.title
                        var uriDict = existingNode["URIDictionary"] as? [String: Any] ?? [String: Any]()
                        uriDict["title"] = bookmark.title
                        existingNode["URIDictionary"] = uriDict
                        newSafariNodes.append(existingNode)
                        addedCount += 1
                    } else {
                        if let node = buildNode(from: bookmark, allBookmarks: validBookmarks) {
                            newSafariNodes.append(node)
                            addedCount += 1
                        }
                    }
                }
            }
            
            // Append remaining Safari-only items. At the managed top level, drop
            // folders that BrowSync previously wrote but the current source tree no
            // longer has; this removes stale browser-system-root contamination
            // without relying on localized folder names.
            var orphanedFolderIndices = Set<Int>()
            for (idx, node) in safariNodes.enumerated() {
                guard pruneOrphanedManagedFolders,
                      (node["WebBookmarkType"] as? String) == "WebBookmarkTypeList",
                      node["BrowSyncSourceRoot"] != nil,
                      let title = node["Title"] as? String,
                      !incomingFolderTitles.contains(title) else { continue }
                orphanedFolderIndices.insert(idx)
            }
            // An incoming payload that's missing most folder titles (a bad read,
            // a filter bug, a stale tombstone) looks identical to "these folders
            // were really deleted" from here. Pruning more than a couple at once
            // is far more likely to be the former, so refuse and keep everything.
            let retainedSafariOnlyNodes: [[String: Any]]
            if orphanedFolderIndices.count > Self.maxOrphanedFolderPruneCount {
                logger.warning("Refusing to prune \(orphanedFolderIndices.count) previously-synced folders in one pass from \(sourceBrowser) — keeping them instead of risking a false mass deletion.")
                retainedSafariOnlyNodes = safariNodes
            } else {
                retainedSafariOnlyNodes = safariNodes.enumerated()
                    .filter { !orphanedFolderIndices.contains($0.offset) }
                    .map(\.element)
            }
            addedCount += safariNodes.count - retainedSafariOnlyNodes.count
            newSafariNodes.append(contentsOf: retainedSafariOnlyNodes)
            
            if isRoot {
                // Re-insert system nodes at their original indices (or as close as possible)
                for (originalIndex, node) in systemNodes {
                    let insertIndex = min(originalIndex, newSafariNodes.count)
                    newSafariNodes.insert(node, at: insertIndex)
                }
            }
            
            safariNodes = newSafariNodes
        }

        func processRoot(chromeParentId: String, rootMatcher: (([String: Any]) -> Bool)?, children: inout [[String: Any]]) {
            let topLevelBookmarks = orderedSiblings(validBookmarks.filter {
                guard !rootChromeIds.contains($0.id) else { return false }
                let pid = $0.parentId ?? "1"
                if chromeParentId == "1" {
                    return pid == "1" || pid == "0"
                } else {
                    return pid == chromeParentId
                }
            })

            if let rootMatcher = rootMatcher {
                guard let idx = children.firstIndex(where: rootMatcher) else {
                    logger.warning("Safari bookmark root was not found while applying bookmarks from \(sourceBrowser).")
                    return
                }
                // A brand-new or completely empty Safari profile can omit the
                // Children key from its BookmarksBar node. Treat that exactly
                // like an empty array; otherwise a one-way sync silently skips
                // every bookmark in the source browser's bookmarks bar.
                var nodeChildren = children[idx]["Children"] as? [[String: Any]] ?? []

                if isFullMirror {
                    nodeChildren = topLevelBookmarks.compactMap { buildNode(from: $0, allBookmarks: validBookmarks) }
                    addedCount += topLevelBookmarks.count
                } else {
                    mergeLevel(chromeNodes: topLevelBookmarks, safariNodes: &nodeChildren, isRoot: false, pruneOrphanedManagedFolders: pruneOrphanedManagedFolders)
                }
                children[idx]["Children"] = nodeChildren
            } else {
                if isFullMirror {
                    children.removeAll { child in
                        !isSafariSystemNode(child)
                    }
                    let newNodes = topLevelBookmarks.compactMap { buildNode(from: $0, allBookmarks: validBookmarks) }
                    children.append(contentsOf: newNodes)
                    addedCount += newNodes.count
                } else {
                    mergeLevel(chromeNodes: topLevelBookmarks, safariNodes: &children, isRoot: true, pruneOrphanedManagedFolders: pruneOrphanedManagedFolders)
                }
            }
        }

        processRoot(chromeParentId: "1", rootMatcher: isBookmarksBarNode, children: &children)
        let hasBookmarksMenu = children.contains(where: isBookmarksMenuNode)
        if hasBookmarksMenu {
            processRoot(chromeParentId: "2", rootMatcher: isBookmarksMenuNode, children: &children)
        } else {
            processRoot(chromeParentId: "2", rootMatcher: nil, children: &children)
        }

        // Older BrowSync builds treated Safari's plist top level as Chrome's
        // Other Bookmarks root, even though Safari stores that root inside the
        // BookmarksMenu node. Keep those legacy root-level items during a
        // merge, but remove them for an authoritative full mirror. Otherwise
        // an empty Chrome Other Bookmarks folder can never clear the items the
        // user sees at Safari's root.
        if isFullMirror && hasBookmarksMenu {
            children.removeAll { !isSafariSystemNode($0) }
        }

        // A merge keeps unmatched extracted nodes because they may be Safari-
        // only copies. A full mirror is authoritative: restoring an unmatched
        // URL/title duplicate here would recreate the very root-level item the
        // source tree omitted (for example, a Safari-root copy of a bookmark
        // that Chrome contains only in its Bookmarks Bar).
        if !isFullMirror {
            var couldRestoreEveryLeftover = true
            var leftovers = Array(extractedLeavesByID.values)
            leftovers.append(contentsOf: extractedLeavesByURL.values.flatMap { $0 })
            leftovers.append(contentsOf: extractedFolders.values.flatMap { $0 })
            leftovers.append(contentsOf: extractedFoldersByID.values)
            leftovers.sort {
                let left = ($0["WebBookmarkUUID"] as? String).flatMap { extractedOrigins[$0] }
                let right = ($1["WebBookmarkUUID"] as? String).flatMap { extractedOrigins[$0] }
                if left?.depth != right?.depth { return (left?.depth ?? 0) < (right?.depth ?? 0) }
                return (left?.index ?? 0) < (right?.index ?? 0)
            }

            func insert(_ node: [String: Any], intoParent parentUUID: String, nodes: inout [[String: Any]], index: Int) -> Bool {
                for i in nodes.indices {
                    if nodes[i]["WebBookmarkUUID"] as? String == parentUUID {
                        var sub = nodes[i]["Children"] as? [[String: Any]] ?? []
                        sub.insert(node, at: min(index, sub.count))
                        nodes[i]["Children"] = sub
                        return true
                    }
                    var sub = nodes[i]["Children"] as? [[String: Any]] ?? []
                    if insert(node, intoParent: parentUUID, nodes: &sub, index: index) {
                        nodes[i]["Children"] = sub
                        return true
                    }
                }
                return false
            }

            for node in leftovers {
                guard let uuid = node["WebBookmarkUUID"] as? String,
                      let origin = extractedOrigins[uuid] else {
                    logger.error("An unmatched extracted Safari bookmark has no provable original location.")
                    couldRestoreEveryLeftover = false
                    continue
                }
                if let parentUUID = origin.parentUUID,
                   insert(node, intoParent: parentUUID, nodes: &children, index: origin.index) {
                    continue
                }
                if origin.parentUUID == nil {
                    children.insert(node, at: min(origin.index, children.count))
                    continue
                }
                let rootIndex = children.firstIndex {
                    origin.systemRoot == "bar" ? isBookmarksBarNode($0) :
                    origin.systemRoot == "menu" ? isBookmarksMenuNode($0) : false
                }
                if let rootIndex {
                    var sub = children[rootIndex]["Children"] as? [[String: Any]] ?? []
                    sub.insert(node, at: min(origin.index, sub.count))
                    children[rootIndex]["Children"] = sub
                } else {
                    logger.error("Could not restore unmatched extracted Safari bookmark \(uuid) to its original parent.")
                    couldRestoreEveryLeftover = false
                }
            }
            guard couldRestoreEveryLeftover else { return Self.writeFailed }
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
                guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    return []
                }
                return Self.parseBookmarks(plist)
            } catch {
                logger.error("Failed to read Safari bookmarks: \(error)")
                return []
            }
        }
    }

    /// Safari's visible bookmarks in sync form: Favorites is root "1", the
    /// Bookmarks Menu (and loose top-level items) root "2".
    static func parseBookmarks(_ plist: [String: Any]) -> [SyncBookmark] {
        SafariPlist.parseBookmarks(plist)
    }

    // MARK: - App-planned native operations

    /// Safari's current tree as a native planning context. The input token is
    /// a digest of Bookmarks.plist, so an approved plan can only be executed
    /// against exactly the file it was computed from.
    func nativePlanContext(folderPath: String?) -> (context: BookmarkNativeTreeContext?, error: String?) {
        SandboxAccessManager.shared.withSafariAccess {
            guard let url = bookmarksURL,
                  let data = try? Data(contentsOf: url),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
                return (nil, "Safari bookmarks are not readable")
            }
            return SafariPlist.nativeContext(plist: plist, data: data, folderPath: folderPath)
        }
    }

    struct NativePlanResult {
        let applied: Bool
        let writes: Int
        let error: String?
    }

    /// Executes app-planned operations as one atomic plist replacement. Nothing
    /// is written unless every operation applies, nodes outside the selected
    /// scope are untouched, and the resulting values match the plan.
    func applyNativePlan(_ operations: [BookmarkMutationOperation], inputToken: String, scopeRootId: String?,
                         explicitRestore: Bool = false) -> NativePlanResult {
        guard safariWriteIsAuthorized(explicitRestore: explicitRestore) else { return .init(applied: false, writes: 0, error: "Safari bookmark write is not authorized") }
        guard !operations.isEmpty else { return .init(applied: true, writes: 0, error: nil) }
        return SandboxAccessManager.shared.withSafariAccess {
            guard let url = bookmarksURL,
                  let data = try? Data(contentsOf: url),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
                return .init(applied: false, writes: 0, error: "Safari bookmarks are not readable")
            }
            guard SafariPlist.digest(data) == inputToken else {
                return .init(applied: false, writes: 0, error: "Safari bookmarks changed after preview")
            }
            let result = SafariPlist.applying(operations, to: plist, scopeRootId: scopeRootId)
            guard let updated = result.plist else {
                return .init(applied: false, writes: 0, error: result.error ?? "planned write could not be verified")
            }
            installMonitorEventHandler()
            let added = operations.filter { $0.kind == .create }.count
            guard writePlist(updated, to: url, added: added, sourceBrowser: explicitRestore ? "Backup Restore" : "BrowSync plan",
                             explicitRestore: explicitRestore) else {
                return .init(applied: false, writes: 0, error: "Safari bookmark file could not be written")
            }
            return .init(applied: true, writes: operations.count, error: nil)
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

    /// Removal matching applied to a plist in memory (used only to preview a
    /// held removal): by UUID, else by URL and title, else (folders) by title.
    private static func removing(_ removals: [(id: String, title: String?, url: String?)], from plist: [String: Any]) -> ([String: Any], Bool) {
        var plist = plist
        guard var children = plist["Children"] as? [[String: Any]] else { return (plist, false) }
        var didRemove = false
        // A folder is matched by title only if exactly one folder has it;
        // otherwise an unrelated folder of the same name would be deleted.
        func folderTitleCount(_ title: String, in nodes: [[String: Any]]) -> Int {
            nodes.reduce(0) { count, node in
                let own = (node["WebBookmarkType"] as? String) == "WebBookmarkTypeList" && (node["Title"] as? String) == title ? 1 : 0
                return count + own + folderTitleCount(title, in: node["Children"] as? [[String: Any]] ?? [])
            }
        }
        for removal in removals {
            let folderTitleIsUnique = removal.url == nil && removal.title.map { folderTitleCount($0, in: children) == 1 } == true
            func traverseAndRemove(nodes: inout [[String: Any]]) {
                nodes.removeAll { node in
                    if let uuid = node["WebBookmarkUUID"] as? String, uuid == removal.id {
                        didRemove = true
                        return true
                    }
                    if let t = removal.title, let u = removal.url, let nodeU = node["URLString"] as? String {
                        let nodeT = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? node["Title"] as? String
                        if nodeU == u && nodeT == t {
                            didRemove = true
                            return true
                        }
                    } else if let t = removal.title, removal.url == nil, folderTitleIsUnique, (node["WebBookmarkType"] as? String) == "WebBookmarkTypeList" {
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
        }
        plist["Children"] = children
        return (plist, didRemove)
    }

    /// A write computed from Safari's current file by `transform` (applied to
    /// its top-level children), returned for review instead of written.
    private func previewTransform(_ transform: (inout [[String: Any]]) -> Bool) -> HeldWrite? {
        SandboxAccessManager.shared.withSafariAccess {
            guard let url = bookmarksURL,
                  let data = try? Data(contentsOf: url),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  var children = plist["Children"] as? [[String: Any]] else { return nil }
            guard transform(&children) else { return nil }
            var result = plist
            result["Children"] = children
            return HeldWrite(
                impact: Self.writeImpact(before: plist, after: result),
                preview: Self.changePreview(before: plist, after: result),
                originalData: data,
                resultPlist: result,
                added: 0
            )
        }
    }

    /// Dissolves folders that BrowSync itself once created from another
    /// browser's root (e.g. a "书签栏" folder inside Favorites), moving their
    /// contents up. Only nodes BrowSync tagged when writing them are touched,
    /// never a user's own folder that happens to have such a name.
    func previewLeakedRootFolderCleanup() -> HeldWrite? {
        let leakedNames: Set<String> = ["bookmarks bar", "书签栏", "favorites", "收藏夹栏", "other bookmarks", "其他书签", "其他收藏夹"]
        return previewTransform { children in
            var modified = false
            func clean(_ nodes: inout [[String: Any]]) {
                var result = [[String: Any]]()
                for node in nodes {
                    if (node["WebBookmarkType"] as? String) == "WebBookmarkTypeList",
                       node["BrowSyncSourceRoot"] != nil,
                       let title = node["Title"] as? String, leakedNames.contains(title.lowercased()) {
                        result.append(contentsOf: node["Children"] as? [[String: Any]] ?? [])
                        modified = true
                    } else {
                        var copy = node
                        if var sub = copy["Children"] as? [[String: Any]] {
                            clean(&sub)
                            copy["Children"] = sub
                        }
                        result.append(copy)
                    }
                }
                nodes = result
            }
            for index in children.indices where ["BookmarksBar", "BookmarksMenu"].contains(children[index]["Title"] as? String ?? "") {
                var sub = children[index]["Children"] as? [[String: Any]] ?? []
                clean(&sub)
                children[index]["Children"] = sub
            }
            return modified
        }
    }

    /// Removes mobile-bookmark folders BrowSync once copied into Safari.
    func previewMobileContaminationCleanup() -> HeldWrite? {
        let knownMobileTitles: Set<String> = [
            "Mobile Bookmarks", "移动设备上的书签", "移动设备书签", "移动设备的书签", "行動裝置書籤",
            "Marcadores del dispositivo móvil", "Mobil yer imleri", "Mobilní záložky"
        ]
        return previewTransform { children in
            var didChange = false
            func removeContamination(from nodes: inout [[String: Any]], isAtRoot: Bool) {
                nodes = nodes.filter { node in
                    // Metadata tag first (language-independent); names only at the
                    // root, for contamination written before the tag existed.
                    if let sourceRoot = node["BrowSyncSourceRoot"] as? String, sourceRoot == "3" {
                        didChange = true
                        return false
                    }
                    if isAtRoot, let title = node["Title"] as? String, knownMobileTitles.contains(title) {
                        didChange = true
                        return false
                    }
                    return true
                }
            }
            let systemTitles = Set(["BookmarksBar", "BookmarksMenu", "History", "com.apple.ReadingList"])
            var rootUserItems = children.filter { ($0["Title"] as? String).map { !systemTitles.contains($0) } ?? true }
            removeContamination(from: &rootUserItems, isAtRoot: true)
            var cleaned = children.filter { ($0["Title"] as? String).map { systemTitles.contains($0) } ?? false }
            cleaned.append(contentsOf: rootUserItems)
            for index in cleaned.indices {
                if var sub = cleaned[index]["Children"] as? [[String: Any]] {
                    removeContamination(from: &sub, isAtRoot: false)
                    cleaned[index]["Children"] = sub
                }
            }
            children = cleaned
            return didChange
        }
    }

    /// Dry run of a batch of removal events against Safari's current file:
    /// what they would remove (whole subtrees count) and both trees for review.
    /// The result can be committed with `commitHeldWrite`.
    func previewRemovals(_ removals: [(id: String, title: String?, url: String?)]) -> HeldWrite? {
        SandboxAccessManager.shared.withSafariAccess {
            guard let url = bookmarksURL,
                  let data = try? Data(contentsOf: url),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
            let (result, _) = Self.removing(removals, from: plist)
            return HeldWrite(
                impact: Self.writeImpact(before: plist, after: result),
                preview: Self.changePreview(before: plist, after: result),
                originalData: data,
                resultPlist: result,
                added: 0
            )
        }
    }
}
