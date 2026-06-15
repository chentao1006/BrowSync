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
    var dateAdded: Date
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
        case conflictStrategy, bookmarkSyncStrategy, bookmarkSourceBrowser, bookmarkAutoSync, bookmarkParticipatingBrowsers, browserDataSyncStrategy, stateSourceBrowser, stateParticipatingBrowsers, websiteListPolicy, websiteSettings, tabSharingParticipatingBrowsers, tabSharingEnabled, enabledCategories, automaticSync, iCloudSync
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conflictStrategy = try container.decodeIfPresent(ConflictStrategy.self, forKey: .conflictStrategy) ?? .primaryWins
        bookmarkSyncStrategy = try container.decodeIfPresent(BookmarkSyncStrategy.self, forKey: .bookmarkSyncStrategy) ?? .twoWayMerge
        bookmarkSourceBrowser = try container.decodeIfPresent(Browser.self, forKey: .bookmarkSourceBrowser) ?? .safari
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
