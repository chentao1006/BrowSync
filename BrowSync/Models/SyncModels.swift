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
    var sameSite: String?
    var removed: Bool? // True if deleted
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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bookmarks: return String(localized: "书签")
        case .browserState: return String(localized: "浏览器状态")
        case .browserData: return String(localized: "浏览器数据")
        case .localStorage: return String(localized: "本地存储")
        case .history: return String(localized: "历史记录")
        }
    }

    var sfSymbol: String {
        switch self {
        case .bookmarks: return "bookmark"
        case .browserState: return "doc.on.doc"
        case .browserData: return "externaldrive"
        case .localStorage: return "internaldrive"
        case .history: return "clock"
        }
    }

    var description: String {
        switch self {
        case .bookmarks:
            return String(localized: "书签、文件夹和收藏夹")
        case .browserState:
            return String(localized: "当前 URL、标签页和活动标签")
        case .browserData:
            return String(localized: "Cookie、localStorage、sessionStorage")
        case .localStorage:
            return String(localized: "各站点的 localStorage 数据")
        case .history:
            return String(localized: "URL、标题、访问时间和次数")
        }
    }

    /// History is off by default per spec
    var defaultEnabled: Bool {
        self != .history
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
        case .primaryWins: return String(localized: "Primary Wins")
        case .latestWins: return String(localized: "Latest Wins")
        case .merge: return String(localized: "Merge")
        }
    }
}

// MARK: - Sync Settings

struct SyncSettings: Codable, Equatable {
    var primaryBrowser: Browser = .safari
    var conflictStrategy: ConflictStrategy = .primaryWins
    var enabledCategories: Set<SyncCategory> = Set(SyncCategory.allCases.filter { $0.defaultEnabled })
    var automaticSync: Bool = false  // PRO
    var iCloudSync: Bool = false     // PRO
}
