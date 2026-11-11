// SyncModels.swift
// BrowSync — Sync data models

import Foundation
import CryptoKit

enum BookmarkFolderPath {
    static let rootBar = "browsync-root-bar"
    static let rootMenu = "browsync-root-menu"
    static let rootOther = "browsync-root-other"
    static let rootMobile = "browsync-root-mobile"
    static let rootFavorites = "browsync-root-favorites"

    static func displayComponent(_ component: String, bundle: Bundle = .main) -> String {
        switch component {
        case rootBar:
            return String(localized: "Bookmarks Bar", bundle: bundle)
        case rootMenu:
            return String(localized: "Bookmarks Menu", bundle: bundle)
        case rootOther:
            return String(localized: "Other Bookmarks", bundle: bundle)
        case rootMobile:
            return String(localized: "Mobile Bookmarks", bundle: bundle)
        case rootFavorites:
            return String(localized: "Favorites", bundle: bundle)
        default:
            return component
        }
    }

    static func displayPath(_ path: String?, bundle: Bundle = .main) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return path.components(separatedBy: "/")
            .filter { !$0.isEmpty }
            .map { displayComponent($0, bundle: bundle) }
            .joined(separator: "/")
    }

    static func canonicalized(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        var components = path.components(separatedBy: "/").filter { !$0.isEmpty }
        guard let first = components.first else { return nil }
        components[0] = canonicalRootComponent(first) ?? first
        return components.joined(separator: "/")
    }

    private static func canonicalRootComponent(_ component: String) -> String? {
        let barNames = [
            rootBar, rootFavorites,
            "Bookmarks Bar", "Bookmarks Toolbar", "Favorites", "Favorites Bar", "Favorites bar",
            "书签栏", "收藏夹栏", "書籤列", "收藏列",
            String(localized: "Bookmarks Bar", bundle: Bundle.main),
            String(localized: "Favorites", bundle: Bundle.main)
        ]
        let menuNames = [
            rootMenu,
            "Bookmarks Menu", "书签菜单", "書籤選單",
            String(localized: "Bookmarks Menu", bundle: Bundle.main)
        ]
        let otherNames = [
            rootOther,
            "Other Bookmarks", "Other Favorites", "Other favorites", "Other Favourites", "Other favourites",
            "其他书签", "其他收藏夹", "其他收藏", "其他書籤",
            String(localized: "Other Bookmarks", bundle: Bundle.main)
        ]
        let mobileNames = [
            rootMobile,
            "Mobile Bookmarks", "移动书签", "移动设备书签", "行動裝置書籤",
            String(localized: "Mobile Bookmarks", bundle: Bundle.main)
        ]

        if barNames.contains(component) { return rootBar }
        if menuNames.contains(component) { return rootMenu }
        if otherNames.contains(component) { return rootOther }
        if mobileNames.contains(component) { return rootMobile }
        return nil
    }
}

// MARK: - Bookmark

struct Bookmark: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var url: String??
    var parentId: String?
    var isFolder: Bool
    /// Position among all siblings. Folders and bookmarks deliberately share one sequence.
    var sortIndex: Int? = nil
    var inBookmarksBar: Bool? // True if it belongs to the Favorites/Bookmarks Bar
    var dateAdded: Date?
    var dateModified: Date?
    var sourceBrowser: Browser

    var children: [Bookmark]? // only populated for folders when serializing

    private enum CodingKeys: String, CodingKey {
        case id, title, url, parentId, isFolder, sortIndex, index, inBookmarksBar
        case dateAdded, dateModified, sourceBrowser, children
    }

    init(
        id: String,
        title: String,
        url: String??,
        parentId: String?,
        isFolder: Bool,
        sortIndex: Int? = nil,
        inBookmarksBar: Bool? = nil,
        dateAdded: Date?,
        dateModified: Date? = nil,
        sourceBrowser: Browser,
        children: [Bookmark]? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.parentId = parentId
        self.isFolder = isFolder
        self.sortIndex = sortIndex
        self.inBookmarksBar = inBookmarksBar
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.sourceBrowser = sourceBrowser
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = try container.decodeIfPresent(String?.self, forKey: .url)
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        isFolder = try container.decodeIfPresent(Bool.self, forKey: .isFolder) ?? (url == nil)
        // Older Chromium-family extensions used the WebExtensions field name
        // `index`; accept it so archived sibling order is not lost.
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex)
            ?? (try container.decodeIfPresent(Int.self, forKey: .index))
        inBookmarksBar = try container.decodeIfPresent(Bool.self, forKey: .inBookmarksBar)
        dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded)
        dateModified = try container.decodeIfPresent(Date.self, forKey: .dateModified)
        sourceBrowser = try container.decodeIfPresent(Browser.self, forKey: .sourceBrowser) ?? .chrome
        children = try container.decodeIfPresent([Bookmark].self, forKey: .children)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(parentId, forKey: .parentId)
        try container.encode(isFolder, forKey: .isFolder)
        try container.encodeIfPresent(sortIndex, forKey: .sortIndex)
        try container.encodeIfPresent(inBookmarksBar, forKey: .inBookmarksBar)
        try container.encodeIfPresent(dateAdded, forKey: .dateAdded)
        try container.encodeIfPresent(dateModified, forKey: .dateModified)
        try container.encode(sourceBrowser, forKey: .sourceBrowser)
        try container.encodeIfPresent(children, forKey: .children)
    }
}

// MARK: - Snapshot diff

struct BookmarkSnapshotRecord: Identifiable, Codable, Equatable {
    let id: String
    let capturedAt: Date
    let sourceBrowser: String
    let bookmarks: [Bookmark]
}

struct BookmarkSnapshotChange: Identifiable, Equatable {
    enum Kind: String, Codable { case added, removed, moved, reordered, modified }
    var id: String { "\(kind.rawValue)|\(nodeId)" }
    let kind: Kind
    let nodeId: String
    let before: Bookmark?
    let after: Bookmark?
}

struct BookmarkSnapshotDelta: Equatable {
    let sourceBrowser: String
    let fromSnapshotId: String
    let toSnapshotId: String
    let observedAt: Date
    let changes: [BookmarkSnapshotChange]

    var isEmpty: Bool { changes.isEmpty }
    var removed: [Bookmark] { changes.compactMap { $0.kind == .removed ? $0.before : nil } }
    var changedNodeIds: Set<String> { Set(changes.compactMap { $0.after?.id }) }
}

enum BookmarkSnapshotDiffer {
    static func diff(older: BookmarkSnapshotRecord, newer: BookmarkSnapshotRecord) -> BookmarkSnapshotDelta {
        let oldById = Dictionary(older.bookmarks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newById = Dictionary(newer.bookmarks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldIds = Set(oldById.keys)
        let newIds = Set(newById.keys)
        var changes: [BookmarkSnapshotChange] = []

        for id in newIds.subtracting(oldIds).sorted() {
            changes.append(.init(kind: .added, nodeId: id, before: nil, after: newById[id]))
        }

        // A removed folder already represents its complete subtree. Do not
        // emit a second deletion for every descendant.
        let missingIds = oldIds.subtracting(newIds)
        for id in missingIds.sorted() {
            guard let node = oldById[id], node.parentId.map({ !missingIds.contains($0) }) ?? true else { continue }
            changes.append(.init(kind: .removed, nodeId: id, before: node, after: nil))
        }

        let commonIds = oldIds.intersection(newIds)
        for id in commonIds.sorted() {
            guard let old = oldById[id], let new = newById[id] else { continue }
            if old.parentId != new.parentId {
                changes.append(.init(kind: .moved, nodeId: id, before: old, after: new))
            }
            if old.title != new.title || canonicalURL(old.url) != canonicalURL(new.url) || old.isFolder != new.isFolder {
                changes.append(.init(kind: .modified, nodeId: id, before: old, after: new))
            }
        }

        // Do not infer user-visible reorders from sibling indexes. Browsers
        // normalize those indexes differently (and may rewrite a whole folder
        // after an unrelated add/remove), so an index-only difference is not
        // reliable evidence of a user operation. A real relocation is already
        // represented above by a parent-id change.

        return BookmarkSnapshotDelta(sourceBrowser: newer.sourceBrowser, fromSnapshotId: older.id,
                                     toSnapshotId: newer.id, observedAt: newer.capturedAt,
                                     changes: changes.sorted { $0.id < $1.id })
    }

    /// Changed nodes plus the folders needed to reconstruct their current
    /// parent chains. Removed nodes are represented only in `delta.removed`.
    static func payload(for delta: BookmarkSnapshotDelta, current: [Bookmark]) -> [Bookmark] {
        let byId = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ids = delta.changedNodeIds
        var queue = Array(ids)
        // Walk every changed node's chain. A chain that reaches a root or an
        // already-collected folder ends only that chain, not the whole walk;
        // otherwise a second change in another folder lost its parent and the
        // target plan failed closed with "missing target parent identity".
        while let id = queue.popLast() {
            guard let parent = byId[id]?.parentId,
                  !["0", "1", "2", "3"].contains(parent),
                  ids.insert(parent).inserted else { continue }
            queue.append(parent)
        }
        // A newly added folder carries its new subtree.
        let children = Dictionary(grouping: current, by: { $0.parentId ?? "" })
        var descendants = delta.changes.filter { $0.kind == .added && $0.after?.isFolder == true }.map(\.nodeId)
        while let parent = descendants.popLast() {
            for child in children[parent] ?? [] where ids.insert(child.id).inserted {
                descendants.append(child.id)
            }
        }
        return current.filter { ids.contains($0.id) }
    }

    private static func canonicalURL(_ value: String??) -> String? {
        guard let value, let raw = value else { return nil }
        return URL(string: raw)?.absoluteString ?? raw
    }

    /// Extensions report a node under the ID of the bookmark it was synced
    /// from once that mapping exists, so the same unchanged node can appear
    /// under a new ID. A removal and an addition with identical content (and,
    /// for folders, the same parent) are such an identity change, not edits.
    static func ignoringIdentityDrift(_ delta: BookmarkSnapshotDelta) -> BookmarkSnapshotDelta {
        func key(_ node: Bookmark) -> String {
            node.isFolder ? "f|\(node.parentId ?? "")|\(node.title)" : "b|\(node.title)|\(canonicalURL(node.url) ?? "")"
        }
        var removedByKey: [String: [String]] = [:]
        for change in delta.changes where change.kind == .removed {
            if let node = change.before { removedByKey[key(node), default: []].append(change.nodeId) }
        }
        var dropped = Set<String>()
        for change in delta.changes where change.kind == .added {
            guard let node = change.after, var ids = removedByKey[key(node)], !ids.isEmpty else { continue }
            dropped.insert(change.id)
            dropped.insert("removed|\(ids.removeFirst())")
            removedByKey[key(node)] = ids
        }
        guard !dropped.isEmpty else { return delta }
        return BookmarkSnapshotDelta(sourceBrowser: delta.sourceBrowser, fromSnapshotId: delta.fromSnapshotId,
                                     toSnapshotId: delta.toSnapshotId, observedAt: delta.observedAt,
                                     changes: delta.changes.filter { !dropped.contains($0.id) })
    }

}

/// Finds genuine competing bookmark values in two *stable* browser snapshots.
/// This deliberately produces conflicts only, never a merge operation: a
/// quiet browser is not permission to mirror an entire tree into another one.
enum BookmarkStableConflictDetector {
    static func conflicts(source: [Bookmark], target: [Bookmark]) -> [BookmarkConflict] {
        func canonicalURL(_ value: String??) -> String? {
            guard let outer = value, let raw = outer else { return nil }
            return URL(string: raw)?.absoluteString ?? raw
        }

        func rootRole(_ id: String) -> String? {
            switch id.lowercased() {
            case "1", "browsync-root-bar", "browsync-root-favorites", "firefox-toolbar-root": return "bar"
            case "2", "browsync-root-other", "firefox-menu-root": return "other"
            case "3", "browsync-root-mobile", "firefox-mobile-root": return "mobile"
            default: return nil
            }
        }

        func parentPaths(_ nodes: [Bookmark]) -> [String: String] {
            let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var cache: [String: String] = [:]
            func path(for id: String, seen: Set<String> = []) -> String? {
                if let cached = cache[id] { return cached }
                if let role = rootRole(id) { return role }
                guard let node = byID[id], !seen.contains(id) else { return nil }
                let parent = node.parentId.flatMap { path(for: $0, seen: seen.union([id])) } ?? "root"
                let result = parent + "/" + node.title
                cache[id] = result
                return result
            }
            return Dictionary(uniqueKeysWithValues: nodes.map { node in
                (node.id, node.parentId.flatMap { path(for: $0) } ?? "root")
            })
        }

        let sourcePaths = parentPaths(source)
        let targetPaths = parentPaths(target)
        var result: [BookmarkConflict] = []
        var claimedTargetIDs = Set<String>()
        for sourceNode in source where !sourceNode.isFolder {
            guard let parentPath = sourcePaths[sourceNode.id] else { continue }
            let candidates = target.filter { !$0.isFolder && targetPaths[$0.id] == parentPath && !claimedTargetIDs.contains($0.id) }
            let sameURL = candidates.filter {
                canonicalURL($0.url) == canonicalURL(sourceNode.url) && $0.title != sourceNode.title
            }
            let sameTitle = candidates.filter {
                $0.title == sourceNode.title && canonicalURL($0.url) != canonicalURL(sourceNode.url)
            }
            let selected: (Bookmark, BookmarkConflict.Reason)?
            if sameURL.count == 1 { selected = (sameURL[0], .title) }
            else if sameTitle.count == 1 { selected = (sameTitle[0], .url) }
            else { selected = nil }
            guard let (targetNode, reason) = selected else { continue }
            claimedTargetIDs.insert(targetNode.id)
            result.append(.init(id: "stable|\(sourceNode.id)|\(targetNode.id)", source: sourceNode, target: targetNode, reason: reason))
        }
        return result.sorted { $0.id < $1.id }
    }
}

// MARK: - Browser Tab

struct BrowserTab: Identifiable, Codable, Equatable {
    var id: String
    var url: String?
    var title: String
    var isActive: Bool
    var windowId: String?
    var index: Int
    var favIconURL: String?
    var sourceBrowser: Browser
    var capturedAt: Date
    var deviceName: String?
}

// MARK: - Storage Item

struct StorageItem: Codable, Equatable {
    var key: String
    var value: String? // Null means deleted
    var origin: String // e.g. "https://chatgpt.com"
}

// MARK: - Cookie

struct SyncCookie: Codable, Equatable {
    var name: String
    var value: String? // Null means deleted
    var domain: String
    var path: String
    var expirationDate: Double?
    var secure: Bool
    var httpOnly: Bool
    var hostOnly: Bool?
    var sameSite: String?
    var removed: Bool? // True if deleted
    var updatedAt: Double? // Milliseconds since epoch, set by the browser extension when observed
}

// MARK: - History Entry

struct HistoryEntry: Identifiable, Codable, Equatable {
    var id: String
    var url: String?
    var title: String?
    var visitTime: Date
    var visitCount: Int
    var sourceBrowser: Browser
}

// MARK: - Sync Category

enum SyncCategory: String, CaseIterable, Codable, Identifiable {
    case bookmarks
    case browserState   // tabs + active URL
    case browserData    // cookies + localStorage + sessionStorage
    case localStorage   // localStorage only (separate pull)
    case history
    case tabSharing     // realtime tab sharing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bookmarks: return "Bookmarks"
        case .browserState: return "Browser State"
        case .browserData: return "Browser Data"
        case .localStorage: return "Local Storage"
        case .history: return "History"
        case .tabSharing: return "Tab Sharing"
        }
    }

    var sfSymbol: String {
        switch self {
        case .bookmarks: return "bookmark"
        case .browserState: return "doc.on.doc"
        case .browserData: return "externaldrive"
        case .localStorage: return "internaldrive"
        case .history: return "clock"
        case .tabSharing: return "square.and.arrow.up.on.square"
        }
    }

    var description: String {
        switch self {
        case .bookmarks:
            return "Bookmarks, folders, and favorites"
        case .browserState:
            return "Current URL, tabs, and active tab"
        case .browserData:
            return "Cookies, localStorage, sessionStorage"
        case .localStorage:
            return "localStorage data for each site"
        case .history:
            return "URLs, titles, visit times and counts"
        case .tabSharing:
            return "Share open tabs between browsers"
        }
    }

}

// MARK: - Conflict Strategy

enum ConflictStrategy: String, CaseIterable, Codable, Identifiable {
    case primaryWins = "primary_wins"
    case latestWins = "latest_wins"
    case merge = "merge"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .primaryWins: return "Primary Wins"
        case .latestWins: return "Latest Wins"
        case .merge: return "Merge"
        }
    }
}

// MARK: - Bookmark Sync Strategy

enum BookmarkSyncStrategy: String, CaseIterable, Codable, Identifiable {
    case oneWay = "one_way"
    case twoWayMerge = "two_way_merge"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oneWay: return "Primary Only (One-way Sync)"
        case .twoWayMerge: return "Two-way Merge"
        }
    }
}

// MARK: - Browser Data Sync Strategy

enum BrowserDataSyncStrategy: String, CaseIterable, Codable, Identifiable {
    case primaryWins = "primary_wins"
    case latestWins = "latest_wins"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .primaryWins: return "Primary Wins (One-way)"
        case .latestWins: return "Latest Activity Wins"
        }
    }
}

// MARK: - Website List Policy

enum WebsiteListPolicy: String, CaseIterable, Codable, Identifiable {
    case allowList = "allow_list"
    case blockList = "block_list"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .allowList: return "Only sync listed websites"
        case .blockList: return "Exclude listed websites"
        }
    }
}

// MARK: - Website Sync Setting

struct WebsiteSyncSetting: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var domain: String
    var strategy: BrowserDataSyncStrategy? // nil means use default
    var sourceBrowser: Browser? // nil means use default
    
    /// Populated from disabled-domains.json by AppState at launch.
    static var syncDisabledDomains: [String] = []
}

// MARK: - Sync Settings

struct SyncSettings: Codable, Equatable {
    /// New installations start with every sync category disabled.  This list is
    /// used only when decoding settings written before `enabledCategories`
    /// existed, so upgrading a long-time user preserves their historic choices.
    private static let legacyEnabledCategories: Set<SyncCategory> = [
        .bookmarks, .browserData, .browserState, .localStorage
    ]

    var conflictStrategy: ConflictStrategy = .primaryWins
    var bookmarkSyncStrategy: BookmarkSyncStrategy = .twoWayMerge
    var bookmarkSourceBrowser: Browser = .safari
    var bookmarkSyncFolder: String? = nil
    var bookmarkSyncFolders: [String: String] = [:]
    var bookmarkAutoSync: Bool = false
    /// When enabled, every non-empty bookmark mutation is held for review,
    /// regardless of its size or whether it is destructive.
    var bookmarkSafeMode: Bool = true
    var bookmarkParticipatingBrowsers: Set<Browser> = []
    
    // Browser Data (Cookies & LocalStorage) Settings
    var browserDataSyncStrategy: BrowserDataSyncStrategy = .latestWins
    var stateSourceBrowser: Browser = .safari
    var stateParticipatingBrowsers: Set<Browser> = []
    var websiteListPolicy: WebsiteListPolicy = .allowList
    var websiteSettings: [WebsiteSyncSetting] = []
    
    // Tab Sharing Settings
    var tabSharingParticipatingBrowsers: Set<Browser> = []
    var tabSharingEnabled: Bool = false
    
    var enabledCategories: Set<SyncCategory> = []
    var automaticSync: Bool = false  // PRO
    var iCloudSync: Bool = false     // PRO

    private enum CodingKeys: String, CodingKey {
        case conflictStrategy, bookmarkSyncStrategy, bookmarkSourceBrowser, bookmarkSyncFolder, bookmarkSyncFolders, bookmarkAutoSync, bookmarkSafeMode, bookmarkParticipatingBrowsers, browserDataSyncStrategy, stateSourceBrowser, stateParticipatingBrowsers, websiteListPolicy, websiteSettings, tabSharingParticipatingBrowsers, tabSharingEnabled, enabledCategories, automaticSync, iCloudSync
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conflictStrategy = try container.decodeIfPresent(ConflictStrategy.self, forKey: .conflictStrategy) ?? .primaryWins
        bookmarkSyncStrategy = try container.decodeIfPresent(BookmarkSyncStrategy.self, forKey: .bookmarkSyncStrategy) ?? .twoWayMerge
        bookmarkSourceBrowser = try container.decodeIfPresent(Browser.self, forKey: .bookmarkSourceBrowser) ?? .safari
        bookmarkSyncFolder = try container.decodeIfPresent(String.self, forKey: .bookmarkSyncFolder)
        bookmarkSyncFolders = try container.decodeIfPresent([String: String].self, forKey: .bookmarkSyncFolders) ?? [:]
        if bookmarkSyncFolders.isEmpty, let bookmarkSyncFolder {
            for browser in Browser.allCases {
                bookmarkSyncFolders[browser.rawValue] = bookmarkSyncFolder
            }
        }
        bookmarkAutoSync = try container.decodeIfPresent(Bool.self, forKey: .bookmarkAutoSync) ?? false
        bookmarkSafeMode = try container.decodeIfPresent(Bool.self, forKey: .bookmarkSafeMode) ?? true
        bookmarkParticipatingBrowsers = try container.decodeIfPresent(Set<Browser>.self, forKey: .bookmarkParticipatingBrowsers) ?? []
        browserDataSyncStrategy = try container.decodeIfPresent(BrowserDataSyncStrategy.self, forKey: .browserDataSyncStrategy) ?? .latestWins
        stateSourceBrowser = try container.decodeIfPresent(Browser.self, forKey: .stateSourceBrowser) ?? .safari
        stateParticipatingBrowsers = try container.decodeIfPresent(Set<Browser>.self, forKey: .stateParticipatingBrowsers) ?? []
        websiteListPolicy = try container.decodeIfPresent(WebsiteListPolicy.self, forKey: .websiteListPolicy) ?? .allowList
        websiteSettings = try container.decodeIfPresent([WebsiteSyncSetting].self, forKey: .websiteSettings) ?? []
        tabSharingParticipatingBrowsers = try container.decodeIfPresent(Set<Browser>.self, forKey: .tabSharingParticipatingBrowsers) ?? []
        tabSharingEnabled = try container.decodeIfPresent(Bool.self, forKey: .tabSharingEnabled) ?? false
        // `enabledCategories` was introduced after the original settings file
        // format. An explicit empty set is a user's choice and remains empty.
        // A missing value means this is an older installation, whose historic
        // enabled categories must be preserved during the upgrade.
        if container.contains(.enabledCategories) {
            enabledCategories = try container.decodeIfPresent(Set<SyncCategory>.self, forKey: .enabledCategories) ?? []
        } else {
            enabledCategories = Self.legacyEnabledCategories
        }
        automaticSync = try container.decodeIfPresent(Bool.self, forKey: .automaticSync) ?? false
        iCloudSync = try container.decodeIfPresent(Bool.self, forKey: .iCloudSync) ?? false
    }

    func bookmarkFolder(for browser: Browser) -> String? {
        BookmarkFolderPath.canonicalized(bookmarkSyncFolders[browser.rawValue].flatMap { $0.isEmpty ? nil : $0 })
    }

    mutating func setBookmarkFolder(_ folder: String?, for browser: Browser) {
        if let folder, !folder.isEmpty {
            bookmarkSyncFolders[browser.rawValue] = folder
        } else {
            bookmarkSyncFolders.removeValue(forKey: browser.rawValue)
        }
        bookmarkSyncFolder = bookmarkSyncFolders.isEmpty ? nil : bookmarkSyncFolder
    }
}

/// Browser-independent final write policy. Every native or extension write
/// boundary must enforce the same OFF/participation/one-way-source rules.
enum BookmarkWritePolicy {
    static func allowsWrite(to target: Browser, settings: SyncSettings, explicitRestore: Bool = false) -> Bool {
        settings.enabledCategories.contains(.bookmarks)
            && settings.bookmarkParticipatingBrowsers.contains(target)
            && (explicitRestore || settings.bookmarkSyncStrategy != .oneWay || settings.bookmarkSourceBrowser != target)
    }
}

// MARK: - Native bookmark planning

/// Browser extensions expose native trees and replay these operations, but do
/// not decide what a sync should change. Planning, signatures and review live
/// in the app so every browser follows one implementation.
struct BookmarkMutationOperation: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case create, update, move, removeTree }
    var id: String
    var sourceId: String? = nil
    var kind: Kind
    var parentId: String?
    var index: Int?
    var title: String?
    var url: String?
}

struct BookmarkNativeTreeContext: Codable, Equatable {
    var inputToken: String
    var browser: Browser
    var nodes: [Bookmark]
    /// Portable system role (1/2/3) -> browser-native root ID.
    var rootIds: [String: String]
    /// Source bookmark ID -> browser-native bookmark ID.
    var sourceToNativeIds: [String: String]
    var scopeRootId: String?
}

struct NativeBookmarkPlan: Equatable {
    var inputToken: String
    var operations: [BookmarkMutationOperation]
    var impact: NativeBookmarkImpact
    var changes: [NativeBookmarkChange]
    var conflicts: [BookmarkConflict] = []
    var validationError: String? = nil
    /// The target tree as it would look after `operations` (virtual IDs for
    /// planned creations). Lets several sources be planned in sequence
    /// against one native input token.
    var resultingNodes: [Bookmark] = []
}

/// Two bookmarks occupy the same intended slot but disagree on user data.
/// This is deliberately not reduced to a create/update heuristic: a user
/// must choose the source version, target version, or keep both.
struct BookmarkConflict: Identifiable, Equatable {
    enum Reason: String, Equatable { case title, url }
    let id: String
    let source: Bookmark
    let target: Bookmark
    let reason: Reason
    /// Display names of the browsers holding each version (review UI).
    var sourceLabel: String? = nil
    var targetLabel: String? = nil
    /// Browsers holding each version (review icons).
    var sourceBrowsers: [Browser] = []
    var targetBrowsers: [Browser] = []
    /// Set for a multi-version sync conflict: every version, each with its
    /// URL and holders. The choice is a version's `key` (or keep all).
    var versions: [Version] = []

    struct Version: Equatable, Identifiable {
        let key: String
        let title: String
        let url: String?
        let browsers: [Browser]
        var id: String { key }
    }
}

enum BookmarkConflictResolution: String, CaseIterable, Codable, Identifiable {
    case source
    case target
    case both
    var id: String { rawValue }
}

struct NativeBookmarkImpact: Equatable {
    var added: Int
    var removed: Int
    var moved: Int
    var modified: Int
    var total: Int
    var signature: String
    var destructiveSignature: String
}

struct NativeBookmarkChange: Equatable {
    enum Kind: String { case added, removed, moved, modified }
    var id: String
    var title: String
    var url: String?
    var isFolder: Bool
    var kind: Kind
    var parentId: String?
    var containingPath: String
    /// True for the node as the plan leaves it (added, or a move/edit's new
    /// state); false for the node as it is now (removed, or a move/edit's
    /// old state). A move or edit has one row of each, so a review can show
    /// "old → new" instead of the new state twice.
    var isResult = false
}

enum NativeBookmarkPlanner {
    static func makeRemovalPlan(removals: [Bookmark], context: BookmarkNativeTreeContext) -> NativeBookmarkPlan {
        let existing = Dictionary(uniqueKeysWithValues: context.nodes.map { ($0.id, $0) })
        var operations: [BookmarkMutationOperation] = []
        var ambiguous = false
        func inScope(_ node: Bookmark) -> Bool {
            guard let scope = context.scopeRootId else { return true }
            var parent = node.parentId
            var seen = Set<String>()
            while let current = parent, seen.insert(current).inserted {
                if current == scope { return true }
                parent = existing[current]?.parentId
            }
            return false
        }
        for item in removals {
            if let nativeId = context.sourceToNativeIds[item.id], let node = existing[nativeId], inScope(node) {
                operations.append(.init(id: nativeId, sourceId: item.id, kind: .removeTree))
                continue
            }
            let matches = context.nodes.filter { node in
                guard inScope(node) else { return false }
                guard node.isFolder == item.isFolder, node.title == item.title else { return false }
                if item.isFolder { return true }
                return node.url.flatMap { $0 } == item.url.flatMap { $0 }
            }
            if matches.count == 1 { operations.append(.init(id: matches[0].id, sourceId: item.id, kind: .removeTree)) }
            else if matches.count > 1 { ambiguous = true }
        }
        var result = existing
        operations.forEach { result.removeValue(forKey: $0.id) }
        var plan = summarize(context: context, resulting: result, operations: ambiguous ? [] : operations)
        if ambiguous { plan.validationError = "ambiguous target bookmark identity" }
        return plan
    }

    /// Builds a deterministic plan against the exact native tree supplied by
    /// an extension. Ambiguous content matches are never guessed.
    static func makePlan(
        desired: [Bookmark],
        context: BookmarkNativeTreeContext,
        fullMirror: Bool,
        conflictResolutions: [String: BookmarkConflictResolution] = [:],
        virtualIdPrefix: String = "browsync-app-planned-",
        movedSourceIds: Set<String> = []
    ) -> NativeBookmarkPlan {
        var existing = Dictionary(uniqueKeysWithValues: context.nodes.map { ($0.id, $0) })
        let children = Dictionary(grouping: context.nodes) { $0.parentId ?? "" }
        var claimed = Set<String>()
        var resolved = context.sourceToNativeIds.filter { existing[$0.value] != nil }
        var operations: [BookmarkMutationOperation] = []
        var virtualCounter = 0
        var validationError: String?
        var conflicts: [BookmarkConflict] = []

        // `1`, `2`, and `3` are portable root roles, not folders to create.
        // Chromium and Firefox omit immutable roots from ordinary snapshots,
        // while Safari includes role placeholders. Creating the placeholders
        // made duplicate "Bookmarks Menu" / "Favorites" folders forever.
        func isPortableSystemRoot(_ bookmark: Bookmark) -> Bool {
            bookmark.isFolder && bookmark.parentId == "0" && ["1", "2", "3"].contains(bookmark.id)
        }

        for root in desired where isPortableSystemRoot(root) {
            guard let nativeRoot = context.rootIds[root.id], existing[nativeRoot] != nil else {
                validationError = "missing native system root"
                break
            }
            resolved[root.id] = nativeRoot
            claimed.insert(nativeRoot)
        }

        func isInBoundScope(_ node: Bookmark) -> Bool {
            guard let scope = context.scopeRootId else { return true }
            if node.id == scope { return true }
            var parent = node.parentId
            var seen = Set<String>()
            while let current = parent, seen.insert(current).inserted {
                if current == scope { return true }
                parent = existing[current]?.parentId
            }
            return false
        }

        func canonicalURL(_ value: String??) -> String? {
            guard let outer = value, let raw = outer else { return nil }
            return URL(string: raw)?.absoluteString ?? raw
        }
        func nativeParent(for bookmark: Bookmark) -> String? {
            guard let parent = bookmark.parentId else { return context.scopeRootId ?? context.rootIds["1"] }
            if let scope = context.scopeRootId, ["0", "1", "2", "3"].contains(parent) { return scope }
            return context.rootIds[parent] ?? resolved[parent] ?? parent
        }
        func uniqueMatch(_ bookmark: Bookmark, parentId: String?) -> String? {
            let candidates = (children[parentId ?? ""] ?? []).filter { !claimed.contains($0.id) }
            let matches: [Bookmark]
            if bookmark.isFolder {
                matches = candidates.filter { $0.isFolder && $0.title == bookmark.title }
            } else {
                matches = candidates.filter {
                    !$0.isFolder && $0.title == bookmark.title && canonicalURL($0.url) == canonicalURL(bookmark.url)
                }
            }
            if matches.count > 1 { validationError = "ambiguous target bookmark identity" }
            return matches.count == 1 ? matches[0].id : nil
        }

        func conflictCandidate(_ bookmark: Bookmark, parentId: String?, mappedId: String?) -> BookmarkConflict? {
            guard !bookmark.isFolder else { return nil }
            // A prior native-ID mapping proves historical lineage, not that a
            // newer source and target value agree.  In particular, a title or
            // URL edited independently after the last sync must never be
            // silently turned into an update merely because it has a mapping.
            if let mappedId, let mapped = existing[mappedId],
               mapped.parentId == parentId,
               (mapped.title != bookmark.title || canonicalURL(mapped.url) != canonicalURL(bookmark.url)) {
                let reason: BookmarkConflict.Reason = canonicalURL(mapped.url) == canonicalURL(bookmark.url) ? .title : .url
                return BookmarkConflict(id: "mapped|\(bookmark.id)|\(mapped.id)", source: bookmark, target: mapped, reason: reason)
            }
            let candidates = (children[parentId ?? ""] ?? []).filter { !$0.isFolder && !claimed.contains($0.id) }
            let sameURL = candidates.filter { canonicalURL($0.url) == canonicalURL(bookmark.url) && $0.title != bookmark.title }
            if sameURL.count == 1 {
                return BookmarkConflict(id: "url|\(bookmark.id)|\(sameURL[0].id)", source: bookmark, target: sameURL[0], reason: .title)
            }
            let sameTitle = candidates.filter { $0.title == bookmark.title && canonicalURL($0.url) != canonicalURL(bookmark.url) }
            if sameTitle.count == 1 {
                return BookmarkConflict(id: "title|\(bookmark.id)|\(sameTitle[0].id)", source: bookmark, target: sameTitle[0], reason: .url)
            }

            // A portable parent can be absent from the target tree while the
            // app is reconstructing a cross-browser root/folder chain.  Do
            // not let that implementation detail turn two clearly competing
            // bookmarks into a silent create (or a malformed move).  A unique
            // same-URL/different-title or same-title/different-URL candidate
            // anywhere inside the bound target scope is still a conflict. The
            // user can explicitly keep either version or keep both; we never
            // guess from browser-native parent IDs.
            let scoped = context.nodes.filter { !($0.isFolder) && isInBoundScope($0) && !claimed.contains($0.id) }
            let scopedSameURL = scoped.filter {
                canonicalURL($0.url) == canonicalURL(bookmark.url) && $0.title != bookmark.title
            }
            if scopedSameURL.count == 1 {
                return BookmarkConflict(id: "url-scope|\(bookmark.id)|\(scopedSameURL[0].id)", source: bookmark, target: scopedSameURL[0], reason: .title)
            }
            let scopedSameTitle = scoped.filter {
                $0.title == bookmark.title && canonicalURL($0.url) != canonicalURL(bookmark.url)
            }
            if scopedSameTitle.count == 1 {
                return BookmarkConflict(id: "title-scope|\(bookmark.id)|\(scopedSameTitle[0].id)", source: bookmark, target: scopedSameTitle[0], reason: .url)
            }
            return nil
        }

        // Parents precede children; sortIndex is shared by folders/bookmarks.
        var remaining = desired.filter { !isPortableSystemRoot($0) }
        var safety = desired.count + 1
        while !remaining.isEmpty && safety > 0 {
            safety -= 1
            var progressed = false
            for bookmark in remaining {
                if let parent = bookmark.parentId,
                   !["0", "1", "2", "3"].contains(parent),
                   resolved[parent] == nil,
                   existing[parent] == nil,
                   // Wait only when the missing parent is another source
                   // node that this same payload will resolve first.  If it
                   // is absent from the payload altogether, still inspect the
                   // leaf for an in-scope conflict before failing closed.
                   remaining.contains(where: { $0.id == parent }) { continue }
                let parentId = nativeParent(for: bookmark)
                if let parentId, let existingParent = existing[parentId],
                   (!existingParent.isFolder || !isInBoundScope(existingParent)) {
                    validationError = "target parent is outside the selected scope"
                    remaining.removeAll { $0.id == bookmark.id }
                    progressed = true
                    continue
                }
                var mapped = resolved[bookmark.id].flatMap { existing[$0] == nil ? nil : $0 }
                // A bookmark created in this target and never mapped has no
                // ID lineage here. When the source moved it, the move is the
                // evidence that it already exists: take the target's only
                // in-scope copy with the same title and URL, so the move is
                // replayed as a move instead of a duplicate creation.
                if mapped == nil, !bookmark.isFolder, movedSourceIds.contains(bookmark.id) {
                    let copies = existing.values.filter {
                        !$0.isFolder && !claimed.contains($0.id) && isInBoundScope($0)
                            && $0.title == bookmark.title && canonicalURL($0.url) == canonicalURL(bookmark.url)
                    }
                    if copies.count == 1 { mapped = copies[0].id }
                }
                if let conflict = conflictCandidate(bookmark, parentId: parentId, mappedId: mapped) {
                    switch conflictResolutions[conflict.id] {
                    case .source:
                        mapped = conflict.target.id
                    case .target:
                        claimed.insert(conflict.target.id)
                        remaining.removeAll { $0.id == bookmark.id }
                        progressed = true
                        continue
                    case .both:
                        // Deliberately forget the historical mapping: keeping
                        // both means creating a distinct target node rather
                        // than updating the mapped one.  The old target must
                        // still be claimed, otherwise a full-mirror tail pass
                        // would immediately schedule it for removal.
                        claimed.insert(conflict.target.id)
                        resolved.removeValue(forKey: bookmark.id)
                        mapped = nil
                    case nil:
                        conflicts.append(conflict)
                        remaining.removeAll { $0.id == bookmark.id }
                        progressed = true
                        continue
                    }
                }
                // Source node IDs are not portable across browsers.  A
                // non-system parent must have been resolved from a current
                // target folder (or already be a target-native ID); otherwise
                // dispatching a create would let an executor pick an
                // arbitrary root.  Run this after conflict detection so a
                // unique competing bookmark can still be presented to the
                // user instead of being hidden behind an internal ID issue.
                if let sourceParent = bookmark.parentId,
                   !["0", "1", "2", "3"].contains(sourceParent),
                   resolved[sourceParent] == nil,
                   existing[sourceParent] == nil {
                    validationError = "missing or invalid target parent identity"
                    remaining.removeAll { $0.id == bookmark.id }
                    progressed = true
                    continue
                }
                if let mapped, let mappedNode = existing[mapped], !isInBoundScope(mappedNode) {
                    validationError = "mapped target bookmark is outside the selected scope"
                    remaining.removeAll { $0.id == bookmark.id }
                    progressed = true
                    continue
                }
                if let id = mapped ?? uniqueMatch(bookmark, parentId: parentId), var current = existing[id] {
                    resolved[bookmark.id] = id
                    claimed.insert(id)
                    if current.title != bookmark.title || canonicalURL(current.url) != canonicalURL(bookmark.url) {
                        operations.append(.init(id: id, sourceId: bookmark.id, kind: .update, title: bookmark.title, url: bookmark.url.flatMap { $0 }))
                        current.title = bookmark.title
                        current.url = bookmark.url
                    }
                    // Browser root implementations freely rewrite sibling
                    // indexes while adding, importing and account-syncing.
                    // An index-only difference is not evidence of a user move
                    // across browsers, and treating it as one turns a single
                    // addition into a mass "reorder" plan. Preserve target
                    // sibling order unless the item's parent actually changed.
                    if current.parentId != parentId {
                        operations.append(.init(id: id, sourceId: bookmark.id, kind: .move, parentId: parentId, index: bookmark.sortIndex))
                        current.parentId = parentId
                        current.sortIndex = bookmark.sortIndex
                    }
                    existing[id] = current
                } else {
                    let id = "\(virtualIdPrefix)\(virtualCounter)"
                    virtualCounter += 1
                    resolved[bookmark.id] = id
                    claimed.insert(id)
                    operations.append(.init(id: id, sourceId: bookmark.id, kind: .create, parentId: parentId, index: bookmark.sortIndex,
                                            title: bookmark.title, url: bookmark.url.flatMap { $0 }))
                    existing[id] = Bookmark(id: id, title: bookmark.title, url: bookmark.url, parentId: parentId,
                                            isFolder: bookmark.isFolder, sortIndex: bookmark.sortIndex,
                                            inBookmarksBar: bookmark.inBookmarksBar, dateAdded: bookmark.dateAdded,
                                            sourceBrowser: context.browser)
                }
                remaining.removeAll { $0.id == bookmark.id }
                progressed = true
            }
            if !progressed { break }
        }

        if !remaining.isEmpty, validationError == nil {
            validationError = "missing or invalid target parent identity"
        }

        if validationError == nil && fullMirror {
            let scopeRoots = Set(context.scopeRootId.map { [$0] } ?? context.rootIds.values.map { $0 })
            let removable = context.nodes.filter { isInBoundScope($0) && !claimed.contains($0.id) && !scopeRoots.contains($0.id) }
            let removableIds = Set(removable.map(\.id))
            for node in removable where !removableIds.contains(node.parentId ?? "") {
                operations.append(.init(id: node.id, kind: .removeTree))
            }
        }

        // Every create/move must land in a node of this target tree (or one
        // planned earlier in the same plan). Anything else would make the
        // executor fail mid-way after other operations already ran.
        if validationError == nil {
            let known = Set(context.nodes.map(\.id))
            var planned = Set<String>()
            for op in operations {
                if op.kind == .create || op.kind == .move,
                   let parent = op.parentId, !known.contains(parent), !planned.contains(parent) {
                    validationError = "planned parent is not in the target tree"
                    break
                }
                if op.kind == .create { planned.insert(op.id) }
            }
        }

        // No subset of an unresolved conflict is executable.  The user must
        // see the complete conflict set before any accompanying operations
        // can mutate a browser.
        if !conflicts.isEmpty { operations.removeAll() }
        var plan = summarize(context: context, resulting: existing, operations: validationError == nil ? operations : [])
        plan.conflicts = conflicts.sorted { $0.id < $1.id }
        plan.validationError = validationError
        return plan
    }

    static func summarize(context: BookmarkNativeTreeContext, resulting: [String: Bookmark], operations: [BookmarkMutationOperation]) -> NativeBookmarkPlan {
        let before = Dictionary(uniqueKeysWithValues: context.nodes.map { ($0.id, $0) })
        let added = operations.filter { $0.kind == .create }.count
        let removed = operations.filter { $0.kind == .removeTree }.count
        let moved = operations.filter { $0.kind == .move }.count
        let modified = operations.filter { $0.kind == .update }.count
        let lines = operations.map { "\($0.kind.rawValue)|\($0.id)|\($0.parentId ?? "")|\($0.index ?? -1)|\($0.title ?? "")|\($0.url ?? "")" }
        let signature = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        let destructiveLines = zip(lines, operations).filter { $0.1.kind != .create }.map(\.0)
        let destructive = SHA256.hash(data: Data(destructiveLines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()

        func containingPath(of bookmark: Bookmark, in nodes: [String: Bookmark]) -> String {
            var titles: [String] = []
            var current = bookmark.parentId
            var visited = Set<String>()
            while let id = current, visited.insert(id).inserted {
                if let role = context.rootIds.first(where: { $0.value == id })?.key {
                    switch role {
                    case "1": titles.insert(String(localized: "Bookmarks Bar"), at: 0)
                    case "2": titles.insert(String(localized: "Other Bookmarks"), at: 0)
                    case "3": titles.insert(String(localized: "Mobile Bookmarks"), at: 0)
                    default: break
                    }
                    break
                }
                guard let parent = nodes[id] else { break }
                if !parent.title.isEmpty { titles.insert(parent.title, at: 0) }
                current = parent.parentId
            }
            return "/" + titles.joined(separator: "/")
        }
        func change(_ bookmark: Bookmark, kind: NativeBookmarkChange.Kind, nodes: [String: Bookmark]) -> NativeBookmarkChange {
            NativeBookmarkChange(id: bookmark.id, title: bookmark.title, url: bookmark.url.flatMap { $0 },
                                 isFolder: bookmark.isFolder, kind: kind, parentId: bookmark.parentId,
                                 containingPath: containingPath(of: bookmark, in: nodes))
        }
        let beforeChanges = operations.compactMap { op -> NativeBookmarkChange? in
            guard let bookmark = before[op.id] else { return nil }
            switch op.kind {
            case .removeTree: return change(bookmark, kind: .removed, nodes: before)
            case .move: return change(bookmark, kind: .moved, nodes: before)
            case .update: return change(bookmark, kind: .modified, nodes: before)
            case .create: return nil
            }
        }
        let afterChanges = operations.compactMap { op -> NativeBookmarkChange? in
            guard let bookmark = resulting[op.id] else { return nil }
            var result: NativeBookmarkChange
            switch op.kind {
            case .create: result = change(bookmark, kind: .added, nodes: resulting)
            case .move: result = change(bookmark, kind: .moved, nodes: resulting)
            case .update: result = change(bookmark, kind: .modified, nodes: resulting)
            case .removeTree: return nil
            }
            result.isResult = true
            return result
        }
        return NativeBookmarkPlan(
            inputToken: context.inputToken,
            operations: operations,
            impact: .init(added: added, removed: removed, moved: moved, modified: modified,
                          total: before.count, signature: signature, destructiveSignature: destructive),
            changes: beforeChanges + afterChanges,
            resultingNodes: Array(resulting.values)
        )
    }
}

// MARK: - Ignored review rows

/// A change the user chose to ignore is identified by its target and its exact
/// content, so a later, different change to the same bookmark is shown again.
enum BookmarkIgnore {
    static func changeKey(target: Browser, change: NativeBookmarkChange) -> String {
        let url = BookmarkSyncConflict.canonicalURL(change.url) ?? ""
        let location = change.kind == .moved ? change.containingPath : ""
        return [target.rawValue, change.kind.rawValue, change.isFolder ? "f" : "b", change.title, url, location]
            .joined(separator: "|")
    }

    static func conflictKey(_ conflictId: String) -> String { "conflict|" + conflictId }

    /// The newest description of every changed node in a route.
    static func lastChanges(_ route: BookmarkRoutePlan) -> [String: NativeBookmarkChange] {
        var result: [String: NativeBookmarkChange] = [:]
        for change in route.changes { result[change.id] = change }
        return result
    }

    /// Removes ignored changes (and operations that depended on them) from the
    /// ordinary routes. The conflict-resolution step is left as is.
    static func filtered(_ plan: BookmarkTargetPlan, ignored: Set<String>) -> BookmarkTargetPlan {
        guard !ignored.isEmpty else { return plan }
        var dropped = Set<String>()
        for route in plan.routes {
            for (id, change) in lastChanges(route) where ignored.contains(changeKey(target: plan.target, change: change)) {
                dropped.insert(id)
            }
        }
        guard !dropped.isEmpty else { return plan }
        let ordinary = plan.routes.flatMap(\.operations).filter { !dropped.contains($0.id) }
        let kept = Set(BookmarkAggregatePlanner.pruneDependencies(ordinary).map(\.id))
        var result = plan
        result.routes = plan.routes.map { route in
            var route = route
            route.operations = route.operations.filter { kept.contains($0.id) }
            route.changes = route.changes.filter { kept.contains($0.id) }
            return route
        }
        return result
    }
}

// MARK: - Aggregate bookmark sync planning

/// One source browser's local changes since its last synchronized baseline,
/// prepared for a particular target.
struct BookmarkSourceContribution: Equatable {
    var source: Browser
    /// Changed nodes plus the folders needed for their parent chains.
    var desired: [Bookmark]
    /// Nodes removed in the source (a removed folder stands for its subtree).
    var removals: [Bookmark]
    /// Source IDs of bookmarks the source moved to another folder. A move
    /// proves the bookmark already exists, so a target without an ID mapping
    /// for it may locate it by content instead of creating a duplicate.
    var moved: Set<String> = []
}

/// One version of a disputed bookmark and every browser that holds it.
struct BookmarkConflictSide: Equatable {
    var bookmark: Bookmark
    var browsers: Set<Browser>
    /// Ancestor folders (outermost first) followed by the bookmark, in the
    /// portable form used by sync payloads (top-level parent 1/2/3).
    var chain: [Bookmark]
    /// Browser-native ID of this version, where known.
    var nativeIds: [Browser: String] = [:]

    var contentKey: String { BookmarkSyncConflict.contentKey(bookmark) }
    var sortedBrowsers: [Browser] { browsers.sorted { $0.rawValue < $1.rawValue } }
}

/// One logical bookmark that exists in several versions across browsers.
/// It is identified by the content of all its versions, so overlapping
/// disputes (A↔B, B↔C, A↔C) are one conflict with three versions, and the
/// same dispute seen from several routes is one row. The user keeps exactly
/// one version (its content key) or every version (`keepAll`).
struct BookmarkSyncConflict: Identifiable, Equatable {
    static let keepAll = "*"
    private(set) var id: String = ""
    private(set) var versions: [BookmarkConflictSide] = []
    var reason: BookmarkConflict.Reason

    init?(_ sides: [BookmarkConflictSide], reason: BookmarkConflict.Reason) {
        self.reason = reason
        for side in sides { add(side) }
        guard versions.count >= 2 else { return nil }
    }

    init?(_ a: BookmarkConflictSide, _ b: BookmarkConflictSide, reason: BookmarkConflict.Reason) {
        self.init([a, b], reason: reason)
    }

    private mutating func add(_ side: BookmarkConflictSide) {
        if let index = versions.firstIndex(where: { $0.contentKey == side.contentKey }) {
            versions[index].browsers.formUnion(side.browsers)
            versions[index].nativeIds.merge(side.nativeIds) { current, _ in current }
        } else {
            versions.append(side)
        }
        versions.sort { $0.contentKey < $1.contentKey }
        id = versions.map(\.contentKey).joined(separator: "||")
    }

    static func contentKey(_ bookmark: Bookmark) -> String {
        "\(bookmark.title)|\(canonicalURL(bookmark.url) ?? "")"
    }

    static func canonicalURL(_ value: String??) -> String? {
        guard let outer = value, let raw = outer else { return nil }
        return URL(string: raw)?.absoluteString ?? raw
    }

    var contentKeys: Set<String> { Set(versions.map(\.contentKey)) }

    func overlaps(_ other: BookmarkSyncConflict) -> Bool { !contentKeys.isDisjoint(with: other.contentKeys) }

    mutating func merge(_ other: BookmarkSyncConflict) {
        other.versions.forEach { add($0) }
    }

    /// The versions a choice keeps; empty for an unknown choice.
    func winners(_ choice: String) -> [BookmarkConflictSide] {
        choice == Self.keepAll ? versions : versions.filter { $0.contentKey == choice }
    }

    func side(withContentKey key: String) -> BookmarkConflictSide? {
        versions.first { $0.contentKey == key }
    }
}

/// The operations one source contributes to one target.
struct BookmarkRoutePlan: Equatable {
    /// nil for the step that applies the user's conflict choices.
    var source: Browser?
    var operations: [BookmarkMutationOperation]
    var changes: [NativeBookmarkChange]
    var impact: NativeBookmarkImpact
    var validationError: String?
}

/// Everything one target receives in one sync, planned against a single
/// native input token so it can be executed as one verified write.
struct BookmarkTargetPlan: Equatable {
    var target: Browser
    var inputToken: String
    var routes: [BookmarkRoutePlan]
    var resolution: BookmarkRoutePlan?
    var conflicts: [BookmarkSyncConflict]

    var operations: [BookmarkMutationOperation] {
        routes.flatMap(\.operations) + (resolution?.operations ?? [])
    }
}

enum BookmarkAggregatePlanner {
    static let virtualIdPrefix = "browsync-"

    /// Plans every source's contribution into one target, in order, against
    /// one native tree. Leaves that take part in `conflicts` are left out of
    /// the ordinary routes; with `resolutions` the chosen versions are then
    /// applied by a final resolution step. Without resolutions, newly found
    /// conflicts are returned so the caller can unify them across targets.
    static func plan(
        target: Browser,
        context: BookmarkNativeTreeContext,
        contributions: [BookmarkSourceContribution],
        conflicts known: [BookmarkSyncConflict],
        resolutions: [String: String]? = nil,
        ignoredConflicts: Set<String> = []
    ) -> BookmarkTargetPlan {
        var working = context
        var routes: [BookmarkRoutePlan] = []
        var discovered: [BookmarkSyncConflict] = []
        let excludedKeys = Set(known.flatMap(\.contentKeys))

        for contribution in contributions where contribution.source != target {
            let routeStart = working
            var operations: [BookmarkMutationOperation] = []
            var routeError: String?

            if !contribution.removals.isEmpty {
                let removal = NativeBookmarkPlanner.makeRemovalPlan(removals: contribution.removals, context: working)
                if let error = removal.validationError {
                    routeError = error
                } else {
                    operations += removal.operations
                    working = removing(removal.operations.map(\.id), from: working)
                }
            }

            var desired = contribution.desired.map { node -> Bookmark in
                var node = node
                node.sourceBrowser = contribution.source
                return node
            }.filter { $0.isFolder || !excludedKeys.contains(BookmarkSyncConflict.contentKey($0)) }

            var plan = NativeBookmarkPlanner.makePlan(
                desired: desired, context: working, fullMirror: false,
                virtualIdPrefix: "\(virtualIdPrefix)\(contribution.source.rawValue)-planned-",
                movedSourceIds: contribution.moved
            )
            var attempts = 0
            while !plan.conflicts.isEmpty && attempts < 8 {
                attempts += 1
                for conflict in plan.conflicts {
                    if let unified = unifiedConflict(conflict, source: contribution.source, desired: desired, context: working) {
                        append(unified, to: &discovered)
                    }
                }
                let conflicted = Set(plan.conflicts.map(\.source.id))
                desired.removeAll { conflicted.contains($0.id) }
                plan = NativeBookmarkPlanner.makePlan(
                    desired: desired, context: working, fullMirror: false,
                    virtualIdPrefix: "\(virtualIdPrefix)\(contribution.source.rawValue)-planned-",
                    movedSourceIds: contribution.moved
                )
            }
            if let error = plan.validationError ?? (plan.conflicts.isEmpty ? nil : "unresolved bookmark conflict") {
                routeError = routeError ?? error
            } else {
                operations += plan.operations
                working = advancing(working, to: plan, attributedTo: contribution.source)
            }
            routes.append(route(source: contribution.source, start: routeStart, end: working,
                                operations: operations, error: routeError))
        }

        var resolutionRoute: BookmarkRoutePlan?
        if let resolutions, !known.isEmpty {
            resolutionRoute = resolve(target: target, context: working,
                                      conflicts: known.filter { !ignoredConflicts.contains($0.id) },
                                      resolutions: resolutions)
        }

        return BookmarkTargetPlan(target: target, inputToken: context.inputToken, routes: routes,
                                  resolution: resolutionRoute, conflicts: discovered)
    }

    /// Adds `conflict` to `list`, merging every conflict that shares a
    /// version with it into one multi-version conflict.
    static func append(_ conflict: BookmarkSyncConflict, to list: inout [BookmarkSyncConflict]) {
        var merged = conflict
        while let index = list.firstIndex(where: { $0.overlaps(merged) }) {
            merged.merge(list.remove(at: index))
        }
        list.append(merged)
    }

    /// Conflicts already present in two quiet browsers (no delta involved).
    static func stableConflicts(snapshots: [Browser: [Bookmark]]) -> [BookmarkSyncConflict] {
        let browsers = snapshots.keys.sorted { $0.rawValue < $1.rawValue }
        var result: [BookmarkSyncConflict] = []
        for (index, a) in browsers.enumerated() {
            for b in browsers[(index + 1)...] {
                let left = snapshots[a] ?? [], right = snapshots[b] ?? []
                for conflict in BookmarkStableConflictDetector.conflicts(source: left, target: right) {
                    let first = BookmarkConflictSide(
                        bookmark: conflict.source, browsers: [a], chain: portableChain(of: conflict.source, in: left),
                        nativeIds: a == .safari ? [a: conflict.source.id] : [:])
                    let second = BookmarkConflictSide(
                        bookmark: conflict.target, browsers: [b], chain: portableChain(of: conflict.target, in: right),
                        nativeIds: b == .safari ? [b: conflict.target.id] : [:])
                    if let unified = BookmarkSyncConflict(first, second, reason: conflict.reason) {
                        append(unified, to: &result)
                    }
                }
            }
        }
        return result
    }

    /// Drops selected-away operations and any operation that depends on a
    /// planned creation that is no longer part of the write.
    static func pruneDependencies(_ operations: [BookmarkMutationOperation]) -> [BookmarkMutationOperation] {
        var kept = operations
        while true {
            let created = Set(kept.filter { $0.kind == .create }.map(\.id))
            func available(_ id: String?) -> Bool {
                guard let id, id.hasPrefix(virtualIdPrefix) else { return true }
                return created.contains(id)
            }
            let next = kept.filter { op in
                (op.kind == .create || available(op.id)) && available(op.parentId)
            }
            if next.count == kept.count { return next }
            kept = next
        }
    }

    // MARK: Internals

    private static func route(source: Browser?, start: BookmarkNativeTreeContext, end: BookmarkNativeTreeContext,
                              operations: [BookmarkMutationOperation], error: String?) -> BookmarkRoutePlan {
        var resulting = Dictionary(end.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Removed nodes are absent from `end`; summarize needs only survivors.
        for op in operations where op.kind == .removeTree { resulting.removeValue(forKey: op.id) }
        let summary = NativeBookmarkPlanner.summarize(context: start, resulting: resulting, operations: operations)
        return BookmarkRoutePlan(source: source, operations: operations, changes: summary.changes,
                                 impact: summary.impact, validationError: error)
    }

    private static func removing(_ ids: [String], from context: BookmarkNativeTreeContext) -> BookmarkNativeTreeContext {
        var removed = Set(ids)
        var changed = true
        while changed {
            changed = false
            for node in context.nodes where !removed.contains(node.id) {
                if let parent = node.parentId, removed.contains(parent) {
                    removed.insert(node.id)
                    changed = true
                }
            }
        }
        var next = context
        next.nodes = context.nodes.filter { !removed.contains($0.id) }
        return next
    }

    private static func advancing(_ context: BookmarkNativeTreeContext, to plan: NativeBookmarkPlan,
                                  attributedTo source: Browser) -> BookmarkNativeTreeContext {
        let touched = Set(plan.operations.filter { $0.kind == .create || $0.kind == .update }.map(\.id))
        var next = context
        next.nodes = plan.resultingNodes.map { node in
            var node = node
            if touched.contains(node.id) { node.sourceBrowser = source }
            return node
        }.sorted { $0.id < $1.id }
        for op in plan.operations {
            if let sourceId = op.sourceId { next.sourceToNativeIds[sourceId] = op.id }
        }
        return next
    }

    /// Ancestors (outermost first) plus the node, within one tree. The chain
    /// stops at portable roots (0/1/2/3); a dangling parent becomes root 2.
    static func portableChain(of leaf: Bookmark, in nodes: [Bookmark]) -> [Bookmark] {
        let byId = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chain = [leaf]
        var seen = Set([leaf.id])
        while let parent = chain[0].parentId, !["0", "1", "2", "3"].contains(parent) {
            guard let node = byId[parent], seen.insert(parent).inserted else {
                chain[0].parentId = "2"
                break
            }
            chain.insert(node, at: 0)
        }
        return chain
    }

    /// Chain of a node inside a native target context, mapped to portable
    /// roots: native system roots become their role, a selected scope root
    /// becomes the portable target root 2.
    private static func nativeChain(of leaf: Bookmark, in context: BookmarkNativeTreeContext) -> [Bookmark] {
        let byId = Dictionary(context.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func role(_ id: String) -> String? {
            if id == context.scopeRootId { return "2" }
            return ["1", "2", "3"].first { context.rootIds[$0] == id }
        }
        var chain = [leaf]
        var seen = Set([leaf.id])
        while let parent = chain[0].parentId {
            if let role = role(parent) { chain[0].parentId = role; break }
            guard let node = byId[parent], seen.insert(parent).inserted else { chain[0].parentId = "2"; break }
            chain.insert(node, at: 0)
        }
        return chain
    }

    private static func unifiedConflict(_ conflict: BookmarkConflict, source: Browser, desired: [Bookmark],
                                        context: BookmarkNativeTreeContext) -> BookmarkSyncConflict? {
        let holder = conflict.target.sourceBrowser
        let sourceSide = BookmarkConflictSide(
            bookmark: conflict.source, browsers: [source],
            chain: portableChain(of: conflict.source, in: desired),
            nativeIds: source == .safari ? [source: conflict.source.id] : [:])
        let targetSide = BookmarkConflictSide(
            bookmark: conflict.target, browsers: [holder],
            chain: nativeChain(of: conflict.target, in: context),
            nativeIds: holder == context.browser && !conflict.target.id.hasPrefix(virtualIdPrefix)
                ? [holder: conflict.target.id] : [:])
        return BookmarkSyncConflict(sourceSide, targetSide, reason: conflict.reason)
    }

    /// Applies the user's choices to one target.
    /// - The chosen version is introduced once (with its folder chain, each
    ///   folder once per path) where this target does not hold it.
    /// - With a single chosen version, one losing version held here is
    ///   rewritten in place; any further losing copy here — or every losing
    ///   copy when this target already holds the chosen version — is removed,
    ///   so the target ends with exactly the chosen version.
    /// - Keep all introduces every missing version and removes nothing.
    private static func resolve(target: Browser, context: BookmarkNativeTreeContext,
                                conflicts: [BookmarkSyncConflict],
                                resolutions: [String: String]) -> BookmarkRoutePlan {
        var desired: [Bookmark] = []
        var working = context
        var error: String?
        var removals: [String] = []
        var injectedVersions = Set<String>()
        var injectedFolders: [String: String] = [:]
        let byId = Dictionary(context.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func inScope(_ node: Bookmark) -> Bool {
            guard let scope = context.scopeRootId else { return true }
            var parent = node.parentId
            var seen = Set<String>()
            while let current = parent, seen.insert(current).inserted {
                if current == scope { return true }
                parent = byId[current]?.parentId
            }
            return false
        }
        /// Native nodes in this target holding a version (known ID, else content).
        func nodes(holding side: BookmarkConflictSide) -> [String] {
            if let known = side.nativeIds[target], byId[known] != nil { return [known] }
            return context.nodes.filter {
                !$0.isFolder && inScope($0) && BookmarkSyncConflict.contentKey($0) == side.contentKey
            }.map(\.id)
        }

        for conflict in conflicts {
            guard let choice = resolutions[conflict.id], !conflict.winners(choice).isEmpty else {
                error = "unresolved bookmark conflict"
                continue
            }
            let winners = conflict.winners(choice)
            let losers = conflict.versions.filter { version in !winners.contains { $0.contentKey == version.contentKey } }
            // What this target holds is decided from its live tree: a version
            // can be present here without having been one side of a detected
            // pair (for example after an earlier duplicate was created).
            var losingNodes = losers.flatMap(nodes(holding:))
            let holdsWinner = winners.contains { !nodes(holding: $0).isEmpty }
            if choice != BookmarkSyncConflict.keepAll {
                if holdsWinner {
                    removals += losingNodes
                    losingNodes = []
                } else if losingNodes.count > 1 {
                    removals += losingNodes.dropFirst()
                    losingNodes = Array(losingNodes.prefix(1))
                }
            }
            for side in winners where nodes(holding: side).isEmpty {
                guard injectedVersions.insert(side.contentKey).inserted, let leaf = side.chain.last else { continue }
                var parent = side.chain.first?.parentId ?? "2"
                if ["0"].contains(parent) { parent = "2" }
                var path = parent
                for folder in side.chain.dropLast() {
                    path += "/" + folder.title
                    if let existing = injectedFolders[path] {
                        parent = existing
                        continue
                    }
                    var copy = folder
                    copy.id = "conflict-folder-\(injectedFolders.count)"
                    copy.parentId = parent
                    injectedFolders[path] = copy.id
                    desired.append(copy)
                    parent = copy.id
                }
                var copy = leaf
                copy.id = "conflict-version-\(injectedVersions.count)"
                copy.parentId = parent
                copy.sourceBrowser = side.sortedBrowsers.first ?? leaf.sourceBrowser
                if choice != BookmarkSyncConflict.keepAll, let loser = losingNodes.first {
                    working.sourceToNativeIds[copy.id] = loser
                }
                desired.append(copy)
            }
        }

        let prefix = "\(virtualIdPrefix)conflict-planned-"
        let probe = NativeBookmarkPlanner.makePlan(desired: desired, context: working, fullMirror: false, virtualIdPrefix: prefix)
        var planned: [String: BookmarkConflictResolution] = [:]
        for found in probe.conflicts {
            let key = BookmarkSyncConflict.contentKey(found.source)
            let other = BookmarkSyncConflict.contentKey(found.target)
            guard let conflict = conflicts.first(where: { $0.contentKeys.contains(key) && $0.contentKeys.contains(other) }),
                  let choice = resolutions[conflict.id] else {
                error = error ?? "bookmark conflict changed since review"
                continue
            }
            if choice == BookmarkSyncConflict.keepAll { planned[found.id] = .both }
            else if choice == key { planned[found.id] = .source }
            else if choice == other { planned[found.id] = .target }
            else { error = error ?? "bookmark conflict changed since review" }
        }
        let plan = NativeBookmarkPlanner.makePlan(desired: desired, context: working, fullMirror: false,
                                                  conflictResolutions: planned, virtualIdPrefix: prefix)
        let failure = error ?? plan.validationError ?? (plan.conflicts.isEmpty ? nil : "bookmark conflict changed since review")
        guard failure == nil else {
            return route(source: nil, start: working, end: working, operations: [], error: failure)
        }
        let rewritten = Set(plan.operations.map(\.id))
        var seenRemovals = Set<String>()
        let removalOps = removals.filter { !rewritten.contains($0) && seenRemovals.insert($0).inserted }
            .map { BookmarkMutationOperation(id: $0, kind: .removeTree) }
        let operations = plan.operations + removalOps
        let end = removing(removalOps.map(\.id), from: advancing(working, to: plan, attributedTo: target))
        return route(source: nil, start: working, end: end, operations: operations, error: nil)
    }
}

/// Persisted per-browser "last synchronized" state. A local change is the
/// difference between this baseline and the browser's newest snapshot, so a
/// change that was cancelled, unchecked or failed is still detected by the
/// next sync instead of disappearing with the next observation.
enum BookmarkBaseline {
    /// The new baseline after a sync: `observed`, except that every change in
    /// `unhandled` is reverted so it is detected again next time.
    static func advanced(observed: [Bookmark], reverting unhandled: [BookmarkSnapshotChange]) -> [Bookmark] {
        var byId = Dictionary(observed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var order = observed.map(\.id)
        for change in unhandled {
            switch change.kind {
            case .added:
                byId.removeValue(forKey: change.nodeId)
            case .removed:
                if let before = change.before, byId[before.id] == nil {
                    byId[before.id] = before
                    order.append(before.id)
                }
            case .moved, .modified, .reordered:
                guard let before = change.before, var current = byId[change.nodeId] else { continue }
                if change.kind == .moved { current.parentId = before.parentId; current.sortIndex = before.sortIndex }
                if change.kind == .modified { current.title = before.title; current.url = before.url; current.isFolder = before.isFolder }
                byId[change.nodeId] = current
            }
        }
        var seen = Set<String>()
        return order.compactMap { id in seen.insert(id).inserted ? byId[id] : nil }
    }
}

extension BookmarkBaseline {
    private static func contentKey(_ node: Bookmark) -> String {
        node.isFolder ? "f|\(node.title)" : "b|\(node.title)|\(BookmarkSyncConflict.canonicalURL(node.url) ?? "")"
    }

    /// Changes between the pre-write observation and the post-write tree that
    /// the verified operations do not account for. They are edits the user
    /// made around the write and must stay detectable as local changes.
    static func unexplainedChanges(observed: [Bookmark], fresh: [Bookmark],
                                   operations: [BookmarkMutationOperation],
                                   nativeNodes: [Bookmark]) -> [BookmarkSnapshotChange] {
        let native = Dictionary(nativeNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let children = Dictionary(grouping: nativeNodes, by: { $0.parentId ?? "" })
        var created: [String: Int] = [:], removed: [String: Int] = [:]
        var updated = Set<String>(), moved = Set<String>()
        var finalValues: [String: Bookmark] = [:]
        for op in operations {
            switch op.kind {
            case .create:
                let node = Bookmark(id: op.id, title: op.title ?? "", url: op.url, parentId: op.parentId,
                                    isFolder: op.url == nil, dateAdded: nil, sourceBrowser: .safari)
                created[contentKey(node), default: 0] += 1
            case .update:
                guard var node = native[op.id] else { continue }
                node.title = op.title ?? ""
                if !node.isFolder { node.url = op.url }
                finalValues[op.id] = node
                updated.insert(contentKey(node))
            case .move, .removeTree:
                break
            }
        }
        for op in operations {
            if op.kind == .move, let node = finalValues[op.id] ?? native[op.id] { moved.insert(contentKey(node)) }
            if op.kind == .removeTree, let root = native[op.id] {
                var queue = [root]
                while let node = queue.popLast() {
                    removed[contentKey(node), default: 0] += 1
                    queue.append(contentsOf: children[node.id] ?? [])
                }
            }
        }
        let delta = BookmarkSnapshotDiffer.ignoringIdentityDrift(BookmarkSnapshotDiffer.diff(
            older: BookmarkSnapshotRecord(id: "observed", capturedAt: .distantPast, sourceBrowser: "", bookmarks: observed),
            newer: BookmarkSnapshotRecord(id: "fresh", capturedAt: Date(), sourceBrowser: "", bookmarks: fresh)))
        return delta.changes.filter { change in
            switch change.kind {
            case .added:
                guard let key = change.after.map(contentKey), let count = created[key], count > 0 else { return true }
                created[key] = count - 1
                return false
            case .removed:
                guard let key = change.before.map(contentKey), let count = removed[key], count > 0 else { return true }
                removed[key] = count - 1
                return false
            case .modified:
                return !(change.after.map { updated.contains(contentKey($0)) } ?? false)
            case .moved:
                return !(change.after.map { moved.contains(contentKey($0)) } ?? false)
            case .reordered:
                return false
            }
        }
    }
}

/// A recorded deletion (Recently Deleted) used as evidence by reconciliation.
struct BookmarkDeletionEvidence: Equatable {
    let url: String
    let browser: Browser
    let deletedAt: Date
}

/// Differences between the browsers' current trees that no pending change
/// explains (for example a change whose snapshot difference was missed).
/// Keyed by "source>target" like session deltas.
struct BookmarkReconciliation: Equatable {
    var additions: [String: [Bookmark]] = [:]
    var removals: [String: [Bookmark]] = [:]
    var isEmpty: Bool { additions.isEmpty && removals.isEmpty }
}

enum BookmarkReconciler {
    static func pairKey(_ source: Browser, _ target: Browser) -> String { "\(source.rawValue)>\(target.rawValue)" }

    /// Evidence-based reconciliation of bookmarks present in some live trees
    /// and absent from others. Absence alone is never treated as a deletion:
    ///  - no lacking browser ever had it  → a missed addition;
    ///  - a lacking browser had it and lost it (its own snapshot history or a
    ///    recorded deletion) → the newer event wins: a holder that added it
    ///    after that loss re-added it, otherwise the deletion is propagated.
    static func reconcile(observed: [Browser: [Bookmark]],
                          live: [Browser: BookmarkNativeTreeContext],
                          history: [Browser: [BookmarkSnapshotRecord]],
                          deletions: [BookmarkDeletionEvidence],
                          pendingURLs: Set<String>,
                          now: Date = Date()) -> BookmarkReconciliation {
        func url(_ node: Bookmark) -> String? { node.isFolder ? nil : BookmarkSyncConflict.canonicalURL(node.url) }
        func scopedURLs(_ context: BookmarkNativeTreeContext) -> Set<String> {
            let byId = Dictionary(context.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            func inScope(_ node: Bookmark) -> Bool {
                guard let scope = context.scopeRootId else { return true }
                var parent = node.parentId
                var seen = Set<String>()
                while let current = parent, seen.insert(current).inserted {
                    if current == scope { return true }
                    parent = byId[current]?.parentId
                }
                return false
            }
            return Set(context.nodes.filter(inScope).compactMap(url))
        }
        let browsers = live.keys.sorted { $0.rawValue < $1.rawValue }
        let liveURLs = Dictionary(uniqueKeysWithValues: browsers.map { ($0, scopedURLs(live[$0]!)) })
        let wholeTreeURLs = Dictionary(uniqueKeysWithValues: browsers.map { ($0, Set(live[$0]!.nodes.compactMap(url))) })
        let records = history.mapValues { list in
            list.sorted { $0.capturedAt < $1.capturedAt }.map { (date: $0.capturedAt, urls: Set($0.bookmarks.compactMap(url))) }
        }
        func lossTime(_ browser: Browser, _ link: String) -> Date? {
            var result: Date?
            let list = records[browser] ?? []
            if let last = list.lastIndex(where: { $0.urls.contains(link) }) {
                result = last == list.count - 1 ? now : list[last + 1].date
            }
            for deletion in deletions where deletion.browser == browser && deletion.url == link {
                result = max(result ?? .distantPast, deletion.deletedAt)
            }
            return result
        }
        func firstSeen(_ browser: Browser, _ link: String) -> Date {
            let list = records[browser] ?? []
            guard var index = list.lastIndex(where: { $0.urls.contains(link) }) else { return now }
            while index > 0 && list[index - 1].urls.contains(link) { index -= 1 }
            return index == 0 ? .distantPast : list[index].date
        }

        var result = BookmarkReconciliation()
        let allURLs = liveURLs.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for link in allURLs.sorted() where !pendingURLs.contains(link) {
            let holders = browsers.filter { liveURLs[$0]?.contains(link) == true }
            let lacking = browsers.filter { liveURLs[$0]?.contains(link) != true }
            guard !holders.isEmpty, !lacking.isEmpty else { continue }
            // Present elsewhere in a lacking browser (outside its selected
            // folder): neither a deletion nor a missing bookmark.
            if lacking.contains(where: { wholeTreeURLs[$0]?.contains(link) == true }) { continue }
            let losses = lacking.compactMap { browser in lossTime(browser, link).map { (browser, $0) } }
            let newestLoss = losses.max { $0.1 < $1.1 }
            let newestAddition = holders.map { firstSeen($0, link) }.max() ?? .distantPast
            if let newestLoss, newestAddition <= newestLoss.1 {
                // The deletion is newer than every holder's copy.
                for holder in holders {
                    guard let node = observed[holder]?.first(where: { url($0) == link }) else { continue }
                    result.removals[pairKey(newestLoss.0, holder), default: []].append(node)
                }
            } else {
                guard let holder = holders.first(where: { browser in observed[browser]?.contains { url($0) == link } == true }),
                      let snapshot = observed[holder],
                      let node = snapshot.first(where: { url($0) == link }) else { continue }
                let chain = BookmarkAggregatePlanner.portableChain(of: node, in: snapshot)
                for target in lacking {
                    var list = result.additions[pairKey(holder, target)] ?? []
                    for item in chain where !list.contains(where: { $0.id == item.id }) { list.append(item) }
                    result.additions[pairKey(holder, target)] = list
                }
            }
        }
        return result
    }
}

// MARK: - Backup restore planning

/// A backup is restored only into the browser it was taken from, inside that
/// browser's currently selected folder. Other browsers follow through the
/// normal sync session, under the user's direction, folders and Safe Mode.
enum BookmarkRestorePlanner {
    /// What a restore of one backup into its browser covers.
    struct Scope: Equatable {
        /// Folder bound in the live browser (nil = whole library).
        var effectiveFolder: String?
        /// Folder whose contents are taken from the archive (nil = all of it).
        var archiveSourceFolder: String?
        /// Archived node IDs that will be restored (shown undimmed).
        var restorableIds: Set<String>
        /// Replace only when the archive covers exactly the bound folder.
        var allowsReplace: Bool
        var isRestorable: Bool
    }

    /// The live browser's selected folder decides the scope. A whole-library
    /// backup restored into a browser that syncs one folder contributes only
    /// that folder; a folder backup restored into a whole-library browser
    /// goes back into that same folder.
    static func scope(archive: [Bookmark], archiveFolder: String?, targetFolder: String?) -> Scope {
        let archiveFolder = (archiveFolder?.isEmpty ?? true) ? nil : archiveFolder
        let targetFolder = (targetFolder?.isEmpty ?? true) ? nil : targetFolder
        let effective = targetFolder ?? archiveFolder
        let source: String? = archiveFolder ?? targetFolder
        let sameFolder = archiveFolder == nil || targetFolder == nil
            || BookmarkFolderPath.canonicalized(archiveFolder) == BookmarkFolderPath.canonicalized(targetFolder)
        guard let source else {
            return Scope(effectiveFolder: nil, archiveSourceFolder: nil, restorableIds: Set(archive.map(\.id)),
                         allowsReplace: true, isRestorable: !archive.isEmpty)
        }
        guard let folderId = BookmarkTreeMerger.folderId(tree: archive, folderPath: source)
                ?? legacyArchiveFolderId(archive: archive, archiveFolder: archiveFolder, source: source) else {
            return Scope(effectiveFolder: effective, archiveSourceFolder: source, restorableIds: [],
                         allowsReplace: false, isRestorable: false)
        }
        let children = Dictionary(grouping: archive, by: { $0.parentId ?? "" })
        var ids = Set([folderId])
        var queue = [folderId]
        while let id = queue.popLast() {
            for child in children[id] ?? [] where ids.insert(child.id).inserted { queue.append(child.id) }
        }
        return Scope(effectiveFolder: effective, archiveSourceFolder: source, restorableIds: ids,
                     allowsReplace: sameFolder, isRestorable: ids.count > 1)
    }

    /// A native tree is usable only if it is bound to exactly what was asked:
    /// a requested folder must come back as a scope node present in the
    /// tree; no folder means no scope. Otherwise planning fails closed.
    static func contextMatchesRequestedScope(_ context: BookmarkNativeTreeContext, requestedFolder: String?) -> Bool {
        let requested = !(requestedFolder?.isEmpty ?? true)
        guard let scope = context.scopeRootId else { return !requested }
        return requested && context.nodes.contains { $0.id == scope && $0.isFolder }
    }

    /// Backups made before ancestor chains were archived hold only the folder
    /// and its contents. When the archive is that folder's backup, its single
    /// top-level folder with the path's last title is the folder.
    private static func legacyArchiveFolderId(archive: [Bookmark], archiveFolder: String?, source: String) -> String? {
        guard let archiveFolder, BookmarkFolderPath.canonicalized(archiveFolder) == BookmarkFolderPath.canonicalized(source),
              let title = source.components(separatedBy: "/").filter({ !$0.isEmpty }).last else { return nil }
        let ids = Set(archive.map(\.id))
        let tops = archive.filter { $0.isFolder && $0.title == title && !ids.contains($0.parentId ?? "") }
        return tops.count == 1 ? tops[0].id : nil
    }

    /// A pre-write backup of a native target tree: the bound scope with its
    /// ancestor chain (or the whole tree), with browser-native root IDs
    /// rewritten to the portable roles 1/2/3 so the folder path resolves.
    static func archive(of context: BookmarkNativeTreeContext) -> [Bookmark] {
        var roleById: [String: String] = [:]
        for role in ["3", "2", "1"] { if let native = context.rootIds[role] { roleById[native] = role } }
        let nodes = context.scopeRootId.map { BookmarkTreeMerger.subtreeWithAncestors(of: $0, in: context.nodes) } ?? context.nodes
        return nodes.map { node in
            var node = node
            if let role = roleById[node.id] { node.id = role; node.parentId = "0" }
            if let parent = node.parentId, let role = roleById[parent] { node.parentId = role }
            return node
        }
    }

    /// The archived content as a portable payload: the scope's folder
    /// contents (or the whole archive), browser-owned roots removed and their
    /// children re-parented to the portable roles 1/2/3.
    static func portableTree(archive: [Bookmark], scope: Scope) -> [Bookmark] {
        let selection: [Bookmark]
        if let folder = scope.archiveSourceFolder {
            selection = BookmarkTreeMerger.extractExistingSubtreeAsRoot(sourceTree: archive, folderPath: folder,
                                                                       portableParentId: "2") ?? []
        } else {
            selection = archive
        }
        func canonicalRootID(for bookmark: Bookmark) -> String? {
            let id = bookmark.id.lowercased()
            if id == "0" { return "0" }
            // Archives name roots several ways: "1", "browsync-root-bar",
            // Firefox's "firefox-toolbar-root" / "firefox-menu-root" ...
            if id == "1" || id.contains("root-bar") || id.contains("root-favorites") || id.hasSuffix("toolbar-root") { return "1" }
            if id == "2" || id.contains("root-menu") || id.contains("root-other") || id.hasSuffix("menu-root") || id.hasSuffix("other-root") { return "2" }
            if id == "3" || id.contains("root-mobile") || id.hasSuffix("mobile-root") { return "3" }
            return nil
        }
        let rootMappings = Dictionary(selection.compactMap { bookmark in canonicalRootID(for: bookmark).map { (bookmark.id, $0) } },
                                      uniquingKeysWith: { first, _ in first })
        return selection.compactMap { bookmark in
            if rootMappings[bookmark.id] != nil { return nil }
            var node = bookmark
            if let parent = bookmark.parentId, let role = rootMappings[parent] {
                node.parentId = role
                node.inBookmarksBar = role == "1"
            }
            return node
        }
    }

    /// A Recently Deleted restore: only the recorded items, additive, each at
    /// its recorded parent. A parent must be another restored item, a node
    /// that exists in the target, or a portable root (1/2/3). Items whose
    /// parent cannot be found (another browser's ID space, or a folder that
    /// no longer exists) are returned as unplaceable, together with their
    /// restored descendants, instead of being dropped into a guessed folder.
    static func deletedItemsPlan(_ items: [Bookmark], context: BookmarkNativeTreeContext)
        -> (plan: NativeBookmarkPlan, unplaceable: Set<String>) {
        let itemIds = Set(items.map(\.id))
        let targetIds = Set(context.nodes.map(\.id))
        let mappedIds = Set(context.sourceToNativeIds.compactMap { targetIds.contains($0.value) ? $0.key : nil })
        func placeable(_ parent: String?) -> Bool {
            guard let parent else { return true }
            return ["1", "2", "3"].contains(parent) || itemIds.contains(parent)
                || targetIds.contains(parent) || mappedIds.contains(parent)
        }
        var unplaceable = Set(items.filter { !placeable($0.parentId) }.map(\.id))
        var changed = true
        while changed {
            changed = false
            for item in items where !unplaceable.contains(item.id) {
                if let parent = item.parentId, unplaceable.contains(parent) {
                    unplaceable.insert(item.id)
                    changed = true
                }
            }
        }
        let desired = items.filter { !unplaceable.contains($0.id) }
        return (plan(desired: desired, context: context, replacing: false), unplaceable)
    }

    /// Incremental restore only creates what is missing: it never removes,
    /// renames or moves an existing bookmark, and a differing existing value
    /// wins. Replace restore makes the bound scope equal to the backup
    /// (backup values win); nothing outside the scope is planned.
    static func plan(desired: [Bookmark], context input: BookmarkNativeTreeContext, replacing: Bool) -> NativeBookmarkPlan {
        // Archived IDs are only trustworthy in the browser's own ID space:
        // Safari archives use Safari's UUIDs. An extension's syncIdMap maps
        // *other* browsers' IDs and small numeric IDs collide, so extension
        // restores match by content alone.
        var context = input
        if context.browser != .safari { context.sourceToNativeIds = [:] }
        var resolutions: [String: BookmarkConflictResolution] = [:]
        var plan = NativeBookmarkPlanner.makePlan(desired: desired, context: context, fullMirror: replacing,
                                                  virtualIdPrefix: "browsync-restore-planned-")
        var attempts = 0
        while !plan.conflicts.isEmpty && attempts < 8 {
            attempts += 1
            for conflict in plan.conflicts {
                // A same-slot (or mapped) difference: Replace takes the backup,
                // Incremental keeps the existing value. A match found only
                // elsewhere in the folder is a different bookmark: keep both.
                let elsewhere = conflict.id.hasPrefix("url-scope|") || conflict.id.hasPrefix("title-scope|")
                resolutions[conflict.id] = elsewhere ? .both : (replacing ? .source : .target)
            }
            plan = NativeBookmarkPlanner.makePlan(desired: desired, context: context, fullMirror: replacing,
                                                  conflictResolutions: resolutions,
                                                  virtualIdPrefix: "browsync-restore-planned-")
        }
        if !plan.conflicts.isEmpty, plan.validationError == nil { plan.validationError = "unresolved bookmark conflict" }
        guard !replacing else { return plan }
        plan.operations = plan.operations.filter { $0.kind == .create }
        let created = Set(plan.operations.map(\.id))
        plan.changes = plan.changes.filter { $0.kind == .added && created.contains($0.id) }
        plan.impact = NativeBookmarkImpact(added: plan.operations.count, removed: 0, moved: 0, modified: 0,
                                           total: plan.impact.total, signature: plan.impact.signature,
                                           destructiveSignature: "")
        return plan
    }
}

// MARK: - Safari Bookmarks.plist (pure, testable)

/// Lightweight bookmark row read from Safari's Bookmarks.plist.
struct SyncBookmark {
    let id: String
    let title: String
    let url: String?
    let parentId: String?
    let isFolder: Bool
    var sortIndex: Int? = nil
    var inBookmarksBar: Bool = false
    var dateAdded: Date? = nil
}

/// Pure transformations of Safari's Bookmarks.plist. `SafariBookmarkService`
/// owns file access, authorization and the atomic write; everything that
/// decides what the file becomes lives here so it can be tested with
/// synthetic plists.
enum SafariPlist {
    static func isHiddenSystemNode(_ node: [String: Any]) -> Bool {
        let identifier = node["WebBookmarkIdentifier"] as? String
        let title = node["Title"] as? String
        if identifier == "BookmarksBar" || identifier == "BookmarksMenu" || title == "BookmarksBar" || title == "BookmarksMenu" { return false }
        if identifier == "History" || title == "History" || title == "com.apple.ReadingList" { return true }
        if (node["ReadingListNonSync"] as? Bool) == true { return true }
        let type = node["WebBookmarkType"] as? String
        return type != "WebBookmarkTypeList" && type != "WebBookmarkTypeLeaf"
    }

    static func visibleNodes(_ plist: [String: Any]) -> [String: (parent: String, index: Int, content: String, title: String)] {
        var result = [String: (parent: String, index: Int, content: String, title: String)]()
        func walk(_ nodes: [[String: Any]], parent: String) {
            for (index, node) in nodes.enumerated() where !isHiddenSystemNode(node) {
                guard let uuid = node["WebBookmarkUUID"] as? String else { continue }
                let content = (node["URLString"] as? String).map { "u:" + $0 }
                    ?? "f:" + ((node["WebBookmarkIdentifier"] as? String) ?? (node["Title"] as? String) ?? "")
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? (node["Title"] as? String) ?? ""
                result[uuid] = (parent, index, content, title)
                walk(node["Children"] as? [[String: Any]] ?? [], parent: uuid)
            }
        }
        walk(plist["Children"] as? [[String: Any]] ?? [], parent: "")
        return result
    }

    static func parseBookmarks(_ plist: [String: Any]) -> [SyncBookmark] {
        guard let children = plist["Children"] as? [[String: Any]] else { return [] }
        var result: [SyncBookmark] = []

        func traverse(nodes: [[String: Any]], parentId: String?, rootChromeId: String?) {
            for (sortIndex, child) in nodes.enumerated() {
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

                result.append(SyncBookmark(id: id, title: titleStr, url: urlStr, parentId: effectiveParentId, isFolder: isFolder, sortIndex: sortIndex, inBookmarksBar: effectiveParentId == "1"))

                if isFolder, let subChildren = child["Children"] as? [[String: Any]] {
                    traverse(nodes: subChildren, parentId: id, rootChromeId: rootChromeId)
                }
            }
        }

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

        if let barIdx = children.firstIndex(where: isBookmarksBarNode),
           let barChildren = children[barIdx]["Children"] as? [[String: Any]] {
            result.append(SyncBookmark(id: "1", title: String(localized: "Favorites", bundle: Bundle.main), url: nil, parentId: "0", isFolder: true, inBookmarksBar: true))
            traverse(nodes: barChildren, parentId: nil, rootChromeId: "1")
        }

        if let menuIdx = children.firstIndex(where: isBookmarksMenuNode),
           let menuChildren = children[menuIdx]["Children"] as? [[String: Any]] {
            result.append(SyncBookmark(id: "2", title: String(localized: "Bookmarks Menu", bundle: Bundle.main), url: nil, parentId: "0", isFolder: true, inBookmarksBar: false))
            traverse(nodes: menuChildren, parentId: nil, rootChromeId: "2")
        }

        // Process any root-level bookmarks that are not system folders
        let rootItems = children.filter { child in
            !isSafariSystemNode(child)
        }
        if !rootItems.isEmpty {
            traverse(nodes: rootItems, parentId: nil, rootChromeId: "2")
        }

        return result
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Safari's tree as a native planning context. The input token is the
    /// digest of the exact file bytes the plan is computed from.
    static func nativeContext(plist: [String: Any], data: Data, folderPath: String?) -> (context: BookmarkNativeTreeContext?, error: String?) {
        let nodes = parseBookmarks(plist).map {
            Bookmark(id: $0.id, title: $0.title, url: $0.url, parentId: $0.parentId, isFolder: $0.isFolder,
                     sortIndex: $0.sortIndex, inBookmarksBar: $0.inBookmarksBar, dateAdded: nil, sourceBrowser: .safari)
        }
        var rootIds: [String: String] = [:]
        if nodes.contains(where: { $0.id == "1" }) { rootIds["1"] = "1" }
        if nodes.contains(where: { $0.id == "2" }) { rootIds["2"] = "2"; rootIds["3"] = "2" }
        var scopeRootId: String?
        if let folderPath, !folderPath.isEmpty {
            guard let folderId = BookmarkTreeMerger.folderId(tree: nodes, folderPath: folderPath) else {
                return (nil, "target folder missing or ambiguous")
            }
            scopeRootId = folderId
        }
        // Safari bookmark IDs are its own UUIDs; other browsers report nodes
        // that came from Safari under those same IDs.
        var identity: [String: String] = [:]
        for node in nodes where !["0", "1", "2", "3"].contains(node.id) { identity[node.id] = node.id }
        return (BookmarkNativeTreeContext(inputToken: digest(data), browser: .safari, nodes: nodes,
                                          rootIds: rootIds, sourceToNativeIds: identity, scopeRootId: scopeRootId), nil)
    }

    /// Applies app-planned operations to a plist in memory. Returns nil plus
    /// a reason unless every operation applies, nothing outside the selected
    /// scope changes, and the resulting values match the plan.
    static func applying(_ operations: [BookmarkMutationOperation], to input: [String: Any], scopeRootId: String?) -> (plist: [String: Any]?, error: String?) {
        var plist = input
        guard var nodes = plist["Children"] as? [[String: Any]] else { return (nil, "Safari bookmarks are not readable") }
        let original = plist
        func uuid(_ node: [String: Any]) -> String? { node["WebBookmarkUUID"] as? String }
        func isBar(_ node: [String: Any]) -> Bool {
            (node["Title"] as? String) == "BookmarksBar" || (node["WebBookmarkIdentifier"] as? String) == "BookmarksBar"
                || ((node["Sync"] as? [String: Any])?["ServerID"] as? String) == "Favorites Bar"
        }
        func isMenu(_ node: [String: Any]) -> Bool {
            (node["Title"] as? String) == "BookmarksMenu" || (node["WebBookmarkIdentifier"] as? String) == "BookmarksMenu"
                || ((node["Sync"] as? [String: Any])?["ServerID"] as? String) == "Bookmarks Menu"
        }
        var roots: [String: String] = [:]
        if let bar = nodes.first(where: isBar).flatMap(uuid) { roots["1"] = bar }
        if let menu = nodes.first(where: isMenu).flatMap(uuid) { roots["2"] = menu; roots["3"] = menu }
        let protectedIds = Set(roots.values)

        func remove(_ id: String, from list: inout [[String: Any]]) -> [String: Any]? {
            if let index = list.firstIndex(where: { uuid($0) == id }) { return list.remove(at: index) }
            for index in list.indices {
                guard var children = list[index]["Children"] as? [[String: Any]] else { continue }
                if let found = remove(id, from: &children) { list[index]["Children"] = children; return found }
            }
            return nil
        }
        func insert(_ node: [String: Any], into parent: String, at index: Int?, list: inout [[String: Any]]) -> Bool {
            for i in list.indices {
                if uuid(list[i]) == parent {
                    guard (list[i]["WebBookmarkType"] as? String) == "WebBookmarkTypeList" else { return false }
                    var children = list[i]["Children"] as? [[String: Any]] ?? []
                    children.insert(node, at: min(max(index ?? children.count, 0), children.count))
                    list[i]["Children"] = children
                    return true
                }
                guard var children = list[i]["Children"] as? [[String: Any]] else { continue }
                if insert(node, into: parent, at: index, list: &children) { list[i]["Children"] = children; return true }
            }
            return false
        }
        func find(_ id: String, in list: [[String: Any]], parent: String? = nil) -> (node: [String: Any], parent: String?)? {
            for node in list {
                if uuid(node) == id { return (node, parent) }
                if let found = find(id, in: node["Children"] as? [[String: Any]] ?? [], parent: uuid(node)) { return found }
            }
            return nil
        }

        func mutate(_ id: String, in list: inout [[String: Any]], _ change: (inout [String: Any]) -> Void) -> Bool {
            for i in list.indices {
                if uuid(list[i]) == id { change(&list[i]); return true }
                guard var children = list[i]["Children"] as? [[String: Any]] else { continue }
                if mutate(id, in: &children, change) { list[i]["Children"] = children; return true }
            }
            return false
        }

        var created: [String: String] = [:]
        func real(_ id: String?) -> String? {
            guard let id else { return nil }
            return created[id] ?? roots[id] ?? id
        }
        for op in operations {
            switch op.kind {
            case .create:
                guard let parent = real(op.parentId ?? "2") else { return (nil, "missing parent") }
                let newId = UUID().uuidString.uppercased()
                let node: [String: Any]
                if let link = op.url {
                    node = ["WebBookmarkType": "WebBookmarkTypeLeaf", "WebBookmarkUUID": newId, "URLString": link,
                            "URIDictionary": ["title": op.title ?? ""]]
                } else {
                    node = ["WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": newId, "Title": op.title ?? "",
                            "Children": [[String: Any]]()]
                }
                guard insert(node, into: parent, at: op.index, list: &nodes) else {
                    return (nil, "planned parent not found")
                }
                created[op.id] = newId
            case .update:
                guard let id = real(op.id), !protectedIds.contains(id),
                      mutate(id, in: &nodes, { node in
                          if (node["WebBookmarkType"] as? String) == "WebBookmarkTypeList" {
                              node["Title"] = op.title ?? ""
                          } else {
                              var uri = node["URIDictionary"] as? [String: Any] ?? [:]
                              uri["title"] = op.title ?? ""
                              node["URIDictionary"] = uri
                              if let link = op.url { node["URLString"] = link }
                          }
                      }) else {
                    return (nil, "bookmark to update not found")
                }
            case .move:
                guard let id = real(op.id), !protectedIds.contains(id), let parent = real(op.parentId),
                      let node = remove(id, from: &nodes), insert(node, into: parent, at: op.index, list: &nodes) else {
                    return (nil, "bookmark move failed")
                }
            case .removeTree:
                guard let id = real(op.id), !protectedIds.contains(id), remove(id, from: &nodes) != nil else {
                    return (nil, "bookmark to remove not found")
                }
            }
        }
        plist["Children"] = nodes

        // Nothing outside the selected scope may change.
        if let scope = real(scopeRootId) {
            func outside(_ tree: [String: Any]) -> [String] {
                let visible = Self.visibleNodes(tree)
                func inScope(_ id: String) -> Bool {
                    var current: String? = id
                    var seen = Set<String>()
                    while let value = current, seen.insert(value).inserted {
                        if value == scope { return true }
                        current = visible[value]?.parent
                    }
                    return false
                }
                return visible.filter { !inScope($0.key) || $0.key == scope }
                    .map { "\($0.key)|\($0.value.parent)|\($0.value.index)|\($0.value.content)|\($0.value.title)" }
                    .sorted()
            }
            guard outside(original) == outside(plist) else {
                return (nil, "bookmarks outside the selected scope would change")
            }
        }

        // Verify the computed tree before replacing the file.
        for op in operations {
            guard let id = real(op.id) else { return (nil, "verification failed") }
            let found = find(id, in: nodes)
            if op.kind == .removeTree {
                if found != nil { return (nil, "removed bookmark still present") }
                continue
            }
            guard let found else { return (nil, "planned bookmark missing") }
            if op.kind == .create || op.kind == .update {
                let title = (found.node["URIDictionary"] as? [String: Any])?["title"] as? String ?? found.node["Title"] as? String
                if title != (op.title ?? "") || (op.url != nil && found.node["URLString"] as? String != op.url) {
                    return (nil, "planned bookmark values differ")
                }
            }
            if op.kind == .create || op.kind == .move, found.parent != real(op.parentId) {
                return (nil, "planned bookmark location differs")
            }
        }

        return (plist, nil)
    }
}

/// Whole-library Safari repairs (mobile contamination, leaked root folders)
/// may only be proposed when Safari may be written and syncs its whole
/// library; with a selected folder they would reach outside that scope.
enum BookmarkMaintenancePolicy {
    static func allowsSafariCleanup(settings: SyncSettings) -> Bool {
        BookmarkWritePolicy.allowsWrite(to: .safari, settings: settings)
            && (settings.bookmarkFolder(for: .safari)?.isEmpty ?? true)
    }
}

// BookmarkTreeMerger.swift
// BrowSync — Utility to merge specific bookmark folders

import Foundation

struct BookmarkTreeMerger {
    
    /// Overlays the `folderPath` from `sourceTree` onto `targetTree`.
    /// Items outside `folderPath` in `targetTree` are preserved.
    /// Items inside `folderPath` in `targetTree` are replaced by items from `sourceTree`.
    static func overlay(sourceTree: [Bookmark], targetTree: [Bookmark], folderPath: String) -> [Bookmark] {
        let components = folderPath.components(separatedBy: "/").filter { !$0.isEmpty }
        guard !components.isEmpty else { return targetTree }
        
        // 1. Find source folder
        let sourceFolderId = findFolderId(pathComponents: components, in: sourceTree)
        
        // 2. Extract source items under sourceFolderId
        var sourceItemsToMigrate: [Bookmark] = []
        if let sourceFolderId = sourceFolderId {
            sourceItemsToMigrate = extractDescendants(of: sourceFolderId, in: sourceTree)
        }
        
        // 3. Find or create target folder path in targetTree
        var modifiedTargetTree = targetTree
        let targetFolderId = ensureFolderPath(components: components, in: &modifiedTargetTree)
        
        // 4. Remove all existing descendants of target folder in targetTree
        modifiedTargetTree = removeDescendants(of: targetFolderId, in: modifiedTargetTree)
        
        // 5. Append source items, remapping their parentId if they are top-level children
        for var item in sourceItemsToMigrate {
            if item.parentId == sourceFolderId {
                item.parentId = targetFolderId
            }
            modifiedTargetTree.append(item)
        }
        
        return modifiedTargetTree
    }
    
    /// Extracts a subtree from `sourceTree` at `folderPath`, and maps its root to the corresponding folder in `targetTree`.
    /// Returns the mapped subtree, including any intermediate folders created to reach the target path.
    static func extractSubtreeAndMapRoot(sourceTree: [Bookmark], targetTree: [Bookmark], folderPath: String) -> [Bookmark] {
        let components = folderPath.components(separatedBy: "/").filter { !$0.isEmpty }
        guard !components.isEmpty else { return sourceTree }
        
        var modifiedTargetTree = targetTree
        let targetFolderId = ensureFolderPath(components: components, in: &modifiedTargetTree)
        
        // Identify newly created intermediate folders
        let originalTargetIds = Set(targetTree.map { $0.id })
        let newlyCreatedFolders = modifiedTargetTree.filter { !originalTargetIds.contains($0.id) }
        
        let sourceFolderId = findFolderId(pathComponents: components, in: sourceTree)
        var extractedItems: [Bookmark] = []
        if let sourceFolderId = sourceFolderId {
            extractedItems = extractDescendants(of: sourceFolderId, in: sourceTree)
            // Remap parent ID
            for i in 0..<extractedItems.count {
                if extractedItems[i].parentId == sourceFolderId {
                    extractedItems[i].parentId = targetFolderId
                }
            }
        }
        
        var parentPathNodes: [Bookmark] = []
        var currentPid = targetFolderId
        let roots = Set(["0", "1", "2", "3"])
        while !roots.contains(currentPid) {
            if let p = modifiedTargetTree.first(where: { $0.id == currentPid }) {
                if !newlyCreatedFolders.contains(where: { $0.id == p.id }) {
                    parentPathNodes.append(p)
                }
                currentPid = p.parentId ?? "2"
            } else {
                break
            }
        }
        
        return parentPathNodes + newlyCreatedFolders + extractedItems
    }
    
    /// Returns a Set of URLs and Titles that are strictly inside the `folderPath` of the given tree.
    static func getIdentifiersInFolder(tree: [Bookmark], folderPath: String) -> (urls: Set<String>, titles: Set<String>) {
        let components = folderPath.components(separatedBy: "/").filter { !$0.isEmpty }
        if components.isEmpty {
            return ([], [])
        }
        
        guard let folderId = findFolderId(pathComponents: components, in: tree) else {
            return ([], [])
        }
        
        let descendants = extractDescendants(of: folderId, in: tree)
        let urls = Set(descendants.compactMap { if let u = $0.url, let actual = u { return actual.lowercased() } else { return nil } })
        
        var titles = Set(descendants.filter { $0.isFolder }.map { $0.title.lowercased() })
        // Include the target folder itself
        if let targetFolder = tree.first(where: { $0.id == folderId }) {
            titles.insert(targetFolder.title.lowercased())
        }
        
        return (urls, titles)
    }

    static func folderExists(tree: [Bookmark], folderPath: String) -> Bool {
        let components = folderPath.components(separatedBy: "/").filter { !$0.isEmpty }
        guard !components.isEmpty else { return true }
        return findFolderId(pathComponents: components, in: tree) != nil
    }

    /// The unique folder at `folderPath`; nil when it is missing or ambiguous.
    static func folderId(tree: [Bookmark], folderPath: String) -> String? {
        let components = folderPath.components(separatedBy: "/").filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }
        return findFolderId(pathComponents: components, in: tree)
    }

    static func idsInFolderIncludingRoot(tree: [Bookmark], folderPath: String?) -> Set<String> {
        guard let folderPath, !folderPath.isEmpty else { return Set(tree.map(\.id)) }
        let components = folderPath.components(separatedBy: "/").filter { !$0.isEmpty }
        guard let folderId = findFolderId(pathComponents: components, in: tree) else { return [] }
        var ids = Set([folderId])
        ids.formUnion(extractDescendants(of: folderId, in: tree).map(\.id))
        return ids
    }

    static func extractExistingSubtreeAsRoot(
        sourceTree: [Bookmark],
        folderPath: String?,
        portableParentId: String = "1"
    ) -> [Bookmark]? {
        guard let folderPath, !folderPath.isEmpty else { return sourceTree }
        let components = folderPath.components(separatedBy: "/").filter { !$0.isEmpty }
        guard let folderId = findFolderId(pathComponents: components, in: sourceTree) else { return nil }
        var descendants = extractDescendants(of: folderId, in: sourceTree)
        for index in descendants.indices where descendants[index].parentId == folderId {
            descendants[index].parentId = portableParentId
        }
        return descendants
    }

    /// Converts native system roots into ordinary folders for the one case in
    /// which identity mapping is impossible: syncing a browser root into a
    /// user-selected non-root destination. Root-to-root callers must not use
    /// this transformation; they retain parent IDs 1/2/3 for native mapping.
    static func wrappingSystemRootsForNonRootTarget(
        sourceTree: [Bookmark],
        sourceBrowser: Browser
    ) -> [Bookmark] {
        let barPortableId = sourceBrowser == .safari ? BookmarkFolderPath.rootFavorites : BookmarkFolderPath.rootBar
        let barTitle = sourceBrowser == .safari ? String(localized: "Favorites") : String(localized: "Bookmarks Bar")
        let roots: [(nativeId: String, portableId: String, title: String, inBookmarksBar: Bool, sortIndex: Int)] = [
            ("1", barPortableId, barTitle, true, 0),
            ("2", BookmarkFolderPath.rootOther, String(localized: "Other Bookmarks"), false, 1),
            ("3", BookmarkFolderPath.rootMobile, String(localized: "Mobile Bookmarks"), false, 2)
        ]
        let parentIDs = Set(sourceTree.compactMap(\.parentId))
        let existingIDs = Set(sourceTree.map(\.id))
        let nativeRootIDs = Set(roots.map(\.nativeId))
        let existingRoots = sourceTree.reduce(into: [String: Bookmark]()) { rootsById, bookmark in
            if nativeRootIDs.contains(bookmark.id), rootsById[bookmark.id] == nil {
                rootsById[bookmark.id] = bookmark
            }
        }
        var result = sourceTree.filter { !nativeRootIDs.contains($0.id) }
        let originalIndices = result.indices

        for root in roots where parentIDs.contains(root.nativeId) || existingRoots[root.nativeId] != nil {
            let portableId = existingIDs.contains(root.portableId)
                ? "\(root.portableId)-\(sourceBrowser.rawValue)"
                : root.portableId
            for index in originalIndices where result[index].parentId == root.nativeId {
                result[index].parentId = portableId
            }
            result.append(
                Bookmark(
                    id: portableId,
                    title: existingRoots[root.nativeId]?.title ?? root.title,
                    url: nil,
                    parentId: "2",
                    isFolder: true,
                    sortIndex: root.sortIndex,
                    inBookmarksBar: root.inBookmarksBar,
                    dateAdded: Date(),
                    sourceBrowser: sourceBrowser
                )
            )
        }
        return result
    }

    /// The selected folder, everything below it, and its ancestor folders up
    /// to the root (ancestors only, never their other children). Backups keep
    /// this chain so a nested folder can be located again on restore.
    static func extractExistingSubtreeWithAncestors(sourceTree: [Bookmark], folderPath: String?) -> [Bookmark]? {
        guard let folderPath, !folderPath.isEmpty else { return sourceTree }
        let components = folderPath.components(separatedBy: "/").filter { !$0.isEmpty }
        guard let folderId = findFolderId(pathComponents: components, in: sourceTree) else { return nil }
        return subtreeWithAncestors(of: folderId, in: sourceTree)
    }

    static func subtreeWithAncestors(of folderId: String, in tree: [Bookmark]) -> [Bookmark] {
        let byId = Dictionary(tree.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var included = Set([folderId])
        included.formUnion(extractDescendants(of: folderId, in: tree).map(\.id))
        var parent = byId[folderId]?.parentId
        while let id = parent, byId[id] != nil, included.insert(id).inserted {
            parent = byId[id]?.parentId
        }
        return tree.filter { included.contains($0.id) }
    }

    /// Extracts a selected folder together with its descendants for archival.
    /// Unlike `extractExistingSubtreeAsRoot`, this keeps the folder node and its
    /// native parent relationship so browser-provided roots such as Chrome's
    /// Bookmarks Bar remain visible and recoverable in backups.
    static func extractExistingSubtreeIncludingRoot(sourceTree: [Bookmark], folderPath: String?) -> [Bookmark]? {
        guard let folderPath, !folderPath.isEmpty else { return sourceTree }
        let components = folderPath.components(separatedBy: "/").filter { !$0.isEmpty }
        guard let folderId = findFolderId(pathComponents: components, in: sourceTree) else { return nil }
        var includedIds = Set([folderId])
        includedIds.formUnion(extractDescendants(of: folderId, in: sourceTree).map(\.id))
        return sourceTree.filter { includedIds.contains($0.id) }
    }

    static func replaceExistingFolderContents(sourceTree: [Bookmark], targetTree: [Bookmark], targetFolderPath: String?) -> [Bookmark]? {
        guard let targetFolderPath, !targetFolderPath.isEmpty else { return sourceTree }
        let components = targetFolderPath.components(separatedBy: "/").filter { !$0.isEmpty }
        guard let targetFolderId = findFolderId(pathComponents: components, in: targetTree) else { return nil }
        let topSourceIds = Set(sourceTree.filter { ($0.parentId ?? "1") == "1" || ($0.parentId ?? "1") == "0" || ($0.parentId ?? "1") == "2" }.map(\.id))
        let existingDescendants = Set(extractDescendants(of: targetFolderId, in: targetTree).map(\.id))
        var result = targetTree.filter { !existingDescendants.contains($0.id) }
        for var bookmark in sourceTree {
            if topSourceIds.contains(bookmark.id) {
                bookmark.parentId = targetFolderId
            }
            result.append(bookmark)
        }
        return result
    }

    static func mergeIntoExistingFolder(sourceTree: [Bookmark], targetTree: [Bookmark], targetFolderPath: String?) -> [Bookmark]? {
        guard let targetFolderPath, !targetFolderPath.isEmpty else { return sourceTree }
        let components = targetFolderPath.components(separatedBy: "/").filter { !$0.isEmpty }
        guard let targetFolderId = findFolderId(pathComponents: components, in: targetTree) else { return nil }
        let topSourceIds = Set(sourceTree.filter { ($0.parentId ?? "1") == "1" || ($0.parentId ?? "1") == "0" || ($0.parentId ?? "1") == "2" }.map(\.id))
        let targetDescendants = extractDescendants(of: targetFolderId, in: targetTree)
        let duplicateTargetIds = duplicateURLBookmarkIds(in: targetDescendants)
        var existingURLs = Set(targetDescendants.filter { !duplicateTargetIds.contains($0.id) }.compactMap { normalizedURL($0) })
        var existingFoldersByParentAndTitle: [String: String] = [:]
        for bookmark in targetDescendants where bookmark.isFolder {
            existingFoldersByParentAndTitle[folderIdentityKey(bookmark)] = bookmark.id
        }

        var result = targetTree.filter { !duplicateTargetIds.contains($0.id) }
        var remappedFolderIds: [String: String] = [:]

        for var bookmark in sourceTree {
            if let parentId = bookmark.parentId, let remappedParentId = remappedFolderIds[parentId] {
                bookmark.parentId = remappedParentId
            } else if topSourceIds.contains(bookmark.id) {
                bookmark.parentId = targetFolderId
            }

            if bookmark.isFolder {
                let key = folderIdentityKey(bookmark)
                if let existingFolderId = existingFoldersByParentAndTitle[key] {
                    remappedFolderIds[bookmark.id] = existingFolderId
                    continue
                }
                existingFoldersByParentAndTitle[key] = bookmark.id
                result.append(bookmark)
                continue
            }

            if let url = normalizedURL(bookmark) {
                if existingURLs.contains(url) {
                    continue
                }
                existingURLs.insert(url)
            }
            result.append(bookmark)
        }
        return result
    }

    static func deduplicatedBookmarksInFolder(tree: [Bookmark], folderPath: String?) -> [Bookmark]? {
        guard let folderPath, !folderPath.isEmpty else {
            return tree
        }
        let components = folderPath.components(separatedBy: "/").filter { !$0.isEmpty }
        guard let folderId = findFolderId(pathComponents: components, in: tree) else { return nil }
        let duplicateIds = duplicateURLBookmarkIds(in: extractDescendants(of: folderId, in: tree))
        return tree.filter { !duplicateIds.contains($0.id) }
    }

    private static func duplicateURLBookmarkIds(in bookmarks: [Bookmark]) -> Set<String> {
        var seenURLs = Set<String>()
        var duplicateIds = Set<String>()
        for bookmark in bookmarks where !bookmark.isFolder {
            guard let url = normalizedURL(bookmark) else { continue }
            if seenURLs.contains(url) {
                duplicateIds.insert(bookmark.id)
            } else {
                seenURLs.insert(url)
            }
        }
        return duplicateIds
    }

    private static func normalizedURL(_ bookmark: Bookmark) -> String? {
        guard let url = bookmark.url.flatMap({ $0 })?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else {
            return nil
        }
        return url.lowercased()
    }

    private static func folderIdentityKey(_ bookmark: Bookmark) -> String {
        let parentId = bookmark.parentId ?? ""
        let title = bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(parentId)|\(title)"
    }
    
    private static func matchRootComponent(_ component: String) -> String? {
        rootIdsMatching(component).first
    }

    private static func rootIdsMatching(_ component: String) -> [String] {
        let barNames = [
            BookmarkFolderPath.rootBar, BookmarkFolderPath.rootFavorites,
            "Bookmarks Bar", "书签栏", "書籤列", "Favorites", "Favorites Bar", "Favorites bar",
            "收藏夹栏", "收藏列",
            String(localized: "Bookmarks Bar", bundle: Bundle.main),
            String(localized: "Favorites", bundle: Bundle.main)
        ]
        let menuNames = [
            BookmarkFolderPath.rootMenu,
            "Bookmarks Menu", "书签菜单", "書籤選單",
            String(localized: "Bookmarks Menu", bundle: Bundle.main)
        ]
        let otherNames = [
            BookmarkFolderPath.rootOther,
            "Other Bookmarks", "其他书签", "其他書籤", "Other Favorites", "Other favorites", "Other Favourites", "Other favourites",
            "其他收藏夹", "其他收藏", "其他我的收藏",
            String(localized: "Other Bookmarks", bundle: Bundle.main),
        ]
        let mobileNames = [
            BookmarkFolderPath.rootMobile,
            "Mobile Bookmarks", "移动书签", "移动设备书签", "行動裝置書籤",
            String(localized: "Mobile Bookmarks", bundle: Bundle.main)
        ]
        
        if barNames.contains(component) { return ["1", BookmarkFolderPath.rootBar, BookmarkFolderPath.rootFavorites, "firefox-toolbar-root"] }
        if menuNames.contains(component) { return ["2", BookmarkFolderPath.rootMenu, "firefox-menu-root"] }
        if otherNames.contains(component) { return ["2", BookmarkFolderPath.rootOther, "firefox-other-root"] }
        if mobileNames.contains(component) { return ["3", BookmarkFolderPath.rootMobile, "firefox-mobile-root"] }
        return []
    }

    private static func findFolderId(pathComponents: [String], in tree: [Bookmark]) -> String? {
        let rootIds = Set(["0", "1", "2", "3"])
        var currentParentIds = rootIds

        var currentId: String? = nil
        
        for (index, component) in pathComponents.enumerated() {
            if index == 0 {
                let matchingRootIds = rootIdsMatching(component)
                if !matchingRootIds.isEmpty {
                    let canonicalComponent = BookmarkFolderPath.canonicalized(component) ?? component
                    var preferredRootIds: [String] = []
                    for rootId in [component, canonicalComponent] + matchingRootIds where !preferredRootIds.contains(rootId) {
                        preferredRootIds.append(rootId)
                    }

                    let existingRootId = preferredRootIds.first { rootId in
                        tree.contains { $0.id == rootId }
                    } ?? preferredRootIds.first { rootId in
                        rootIds.contains(rootId)
                    } ?? preferredRootIds[0]
                    currentId = existingRootId
                    currentParentIds = Set(preferredRootIds)
                    currentParentIds.formUnion(tree.filter {
                        $0.isFolder && preferredRootIds.contains($0.id)
                    }.map(\.id))
                    continue
                }
            }

            let directRootMatches = tree.filter {
                $0.isFolder && $0.title == component && currentParentIds.contains($0.id)
            }
            if directRootMatches.count > 1 { return nil }
            if let match = directRootMatches.first {
                currentId = match.id
                currentParentIds = [match.id]
                continue
            }
            
            let matches = tree.filter { $0.isFolder && $0.title == component && currentParentIds.contains($0.parentId ?? "") }
            if matches.count > 1 { return nil }
            if let match = matches.first {
                currentId = match.id
                currentParentIds = [match.id]
            } else {
                return nil
            }
        }
        
        return currentId
    }
    
    private static func extractDescendants(of parentId: String, in tree: [Bookmark]) -> [Bookmark] {
        var descendants: [Bookmark] = []
        var queue = [parentId]
        
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let children = tree.filter { $0.parentId == current }
            descendants.append(contentsOf: children)
            queue.append(contentsOf: children.filter { $0.isFolder }.map { $0.id })
        }
        
        return descendants
    }
    
    private static func removeDescendants(of parentId: String, in tree: [Bookmark]) -> [Bookmark] {
        var toRemove = Set<String>()
        var queue = [parentId]
        
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let children = tree.filter { $0.parentId == current }
            for child in children {
                toRemove.insert(child.id)
                if child.isFolder {
                    queue.append(child.id)
                }
            }
        }
        
        return tree.filter { !toRemove.contains($0.id) }
    }
     static func ensureFolderPath(components: [String], in tree: inout [Bookmark]) -> String {
        let rootIds = Set(["0", "1", "2", "3"])
        var currentParentIds = rootIds

        var currentId: String = "2" // Default to Other Bookmarks (Safari Root)
        
        for (index, component) in components.enumerated() {
            if index == 0, let rootId = matchRootComponent(component) {
                currentId = rootId
                currentParentIds = [rootId]
                continue
            }
            
            let matches = tree.filter { $0.isFolder && $0.title == component && currentParentIds.contains($0.parentId ?? "") }
            if let match = matches.first {
                currentId = match.id
                currentParentIds = [match.id]
            } else {
                // Create missing folder
                let newId = UUID().uuidString
                let effectiveParent = currentId
                let newFolder = Bookmark(
                    id: newId,
                    title: component,
                    url: nil,
                    parentId: effectiveParent,
                    isFolder: true,
                    inBookmarksBar: effectiveParent == "1",
                    dateAdded: Date(),
                    sourceBrowser: .safari // dummy value
                )
                tree.append(newFolder)
                currentId = newId
                currentParentIds = [newId]
            }
        }
        
        return currentId
    }
}
