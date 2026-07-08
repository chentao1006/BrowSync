// SyncModels.swift
// BrowSync — Sync data models

import Foundation

// MARK: - Bookmark

struct Bookmark: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var url: String??
    var parentId: String?
    var isFolder: Bool
    var inBookmarksBar: Bool? // True if it belongs to the Favorites/Bookmarks Bar
    var dateAdded: Date?
    var dateModified: Date?
    var sourceBrowser: Browser

    var children: [Bookmark]? // only populated for folders when serializing
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

    /// History is off by default per spec
    var defaultEnabled: Bool {
        self != .history && self != .tabSharing
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
    
    static var syncDisabledDomains: [String] = []
}

// MARK: - Sync Settings

struct SyncSettings: Codable, Equatable {
    var conflictStrategy: ConflictStrategy = .primaryWins
    var bookmarkSyncStrategy: BookmarkSyncStrategy = .twoWayMerge
    var bookmarkSourceBrowser: Browser = .safari
    var bookmarkSyncFolder: String? = nil
    var bookmarkAutoSync: Bool = false
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
        case conflictStrategy, bookmarkSyncStrategy, bookmarkSourceBrowser, bookmarkSyncFolder, bookmarkAutoSync, bookmarkParticipatingBrowsers, browserDataSyncStrategy, stateSourceBrowser, stateParticipatingBrowsers, websiteListPolicy, websiteSettings, tabSharingParticipatingBrowsers, tabSharingEnabled, enabledCategories, automaticSync, iCloudSync
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conflictStrategy = try container.decodeIfPresent(ConflictStrategy.self, forKey: .conflictStrategy) ?? .primaryWins
        bookmarkSyncStrategy = try container.decodeIfPresent(BookmarkSyncStrategy.self, forKey: .bookmarkSyncStrategy) ?? .twoWayMerge
        bookmarkSourceBrowser = try container.decodeIfPresent(Browser.self, forKey: .bookmarkSourceBrowser) ?? .safari
        bookmarkSyncFolder = try container.decodeIfPresent(String.self, forKey: .bookmarkSyncFolder)
        bookmarkAutoSync = try container.decodeIfPresent(Bool.self, forKey: .bookmarkAutoSync) ?? false
        bookmarkParticipatingBrowsers = try container.decodeIfPresent(Set<Browser>.self, forKey: .bookmarkParticipatingBrowsers) ?? []
        browserDataSyncStrategy = try container.decodeIfPresent(BrowserDataSyncStrategy.self, forKey: .browserDataSyncStrategy) ?? .latestWins
        stateSourceBrowser = try container.decodeIfPresent(Browser.self, forKey: .stateSourceBrowser) ?? .safari
        stateParticipatingBrowsers = try container.decodeIfPresent(Set<Browser>.self, forKey: .stateParticipatingBrowsers) ?? []
        websiteListPolicy = try container.decodeIfPresent(WebsiteListPolicy.self, forKey: .websiteListPolicy) ?? .allowList
        websiteSettings = try container.decodeIfPresent([WebsiteSyncSetting].self, forKey: .websiteSettings) ?? []
        tabSharingParticipatingBrowsers = try container.decodeIfPresent(Set<Browser>.self, forKey: .tabSharingParticipatingBrowsers) ?? []
        tabSharingEnabled = try container.decodeIfPresent(Bool.self, forKey: .tabSharingEnabled) ?? false
        enabledCategories = try container.decodeIfPresent(Set<SyncCategory>.self, forKey: .enabledCategories) ?? []
        automaticSync = try container.decodeIfPresent(Bool.self, forKey: .automaticSync) ?? false
        iCloudSync = try container.decodeIfPresent(Bool.self, forKey: .iCloudSync) ?? false
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
    
    private static func matchRootComponent(_ component: String) -> String? {
        let barNames = [
            "Bookmarks Bar", "书签栏", "書籤列", "Favorites", "Favorites Bar",
            String(localized: "Bookmarks Bar", bundle: Bundle.main),
            String(localized: "Favorites", bundle: Bundle.main)
        ]
        let otherNames = [
            "Other Bookmarks", "其他书签", "其他書籤", "Bookmarks Menu", "Other Favorites",
            String(localized: "Other Bookmarks", bundle: Bundle.main),
            String(localized: "Bookmarks Menu", bundle: Bundle.main)
        ]
        let mobileNames = [
            "Mobile Bookmarks", "移动设备书签", "行動裝置書籤",
            String(localized: "Mobile Bookmarks", bundle: Bundle.main)
        ]
        
        if barNames.contains(component) { return "1" }
        if otherNames.contains(component) { return "2" }
        if mobileNames.contains(component) { return "3" }
        return nil
    }

    private static func findFolderId(pathComponents: [String], in tree: [Bookmark]) -> String? {
        let rootIds = Set(["0", "1", "2", "3"])
        var currentParentIds = rootIds

        var currentId: String? = nil
        
        for (index, component) in pathComponents.enumerated() {
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
