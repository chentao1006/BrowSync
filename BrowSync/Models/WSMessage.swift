// WSMessage.swift
// BrowSync — WebSocket protocol message types

import Foundation

// MARK: - Message Type

enum WSMessageType: String, Codable {
    case register
    case heartbeat
    case sync
    case pull
    case ack
    case error
    case disconnect
    case settings
    case openSettings = "open_settings"
    case openURL = "open_url"
}

// MARK: - Base Message

/// Base envelope — always has `type`. Decode the specific payload based on type.
struct WSMessage: Codable {
    var type: WSMessageType
    var browser: String?
    var instanceId: String?
    var site: String?
    var category: String?
    var payload: WSPayload?
    var messageId: String?
    var timestamp: Double?
    var error: String?
    var isFullMirror: Bool?

    // MARK: Factory Methods

    static func register(browser: Browser, instanceId: String) -> WSMessage {
        WSMessage(
            type: .register,
            browser: browser.rawValue,
            instanceId: instanceId,
            payload: nil,
            messageId: UUID().uuidString,
            timestamp: Date().timeIntervalSince1970
        )
    }

    static func heartbeat() -> WSMessage {
        WSMessage(type: .heartbeat, timestamp: Date().timeIntervalSince1970)
    }

    static func sync(site: String, category: SyncCategory, payload: WSPayload) -> WSMessage {
        WSMessage(
            type: .sync,
            site: site,
            category: category.rawValue,
            payload: payload,
            messageId: UUID().uuidString,
            timestamp: Date().timeIntervalSince1970,
            isFullMirror: nil
        )
    }

    static func ack(messageId: String, browserId: String? = nil) -> WSMessage {
        WSMessage(type: .ack, browser: browserId, messageId: messageId, timestamp: Date().timeIntervalSince1970)
    }

    static func pull(site: String? = nil, category: String? = nil) -> WSMessage {
        WSMessage(
            type: .pull,
            site: site,
            category: category,
            messageId: UUID().uuidString,
            timestamp: Date().timeIntervalSince1970
        )
    }
}

// MARK: - Payload

enum WSPayload: Codable {
    case bookmarks([Bookmark])
    case tabs([BrowserTab])
    case browserState([BrowserTab])
    case localStorage([StorageItem])
    case sessionStorage([StorageItem])
    case cookies([SyncCookie])
    case history([HistoryEntry])
    case bookmarksRemoved(Bookmark)
    case raw([String: AnyCodable])

    private enum CodingKeys: String, CodingKey {
        case kind, bookmarks, tabs, localStorage, sessionStorage, cookies, history, raw, id, bookmark
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "bookmarks":
            self = .bookmarks(try container.decode([Bookmark].self, forKey: .bookmarks))
        case "tabs":
            self = .tabs(try container.decode([BrowserTab].self, forKey: .tabs))
        case "browserState":
            self = .browserState(try container.decode([BrowserTab].self, forKey: .tabs))
        case "localStorage":
            self = .localStorage(try container.decode([StorageItem].self, forKey: .localStorage))
        case "sessionStorage":
            self = .sessionStorage(try container.decode([StorageItem].self, forKey: .sessionStorage))
        case "cookies":
            self = .cookies(try container.decode([SyncCookie].self, forKey: .cookies))
        case "history":
            self = .history(try container.decode([HistoryEntry].self, forKey: .history))
        case "bookmarks_removed":
            if let str = try? container.decode(String.self, forKey: .id) {
                self = .bookmarksRemoved(Bookmark(id: str, title: "", url: nil, parentId: nil, isFolder: false, dateAdded: Date(), sourceBrowser: .safari))
            } else {
                let bm = try container.decode(Bookmark.self, forKey: .bookmark)
                self = .bookmarksRemoved(bm)
            }
        default:
            self = .raw(try container.decode([String: AnyCodable].self, forKey: .raw))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bookmarks(let v):
            try container.encode("bookmarks", forKey: .kind)
            try container.encode(v, forKey: .bookmarks)
        case .tabs(let v):
            try container.encode("tabs", forKey: .kind)
            try container.encode(v, forKey: .tabs)
        case .browserState(let v):
            try container.encode("browserState", forKey: .kind)
            try container.encode(v, forKey: .tabs)
        case .localStorage(let v):
            try container.encode("localStorage", forKey: .kind)
            try container.encode(v, forKey: .localStorage)
        case .sessionStorage(let v):
            try container.encode("sessionStorage", forKey: .kind)
            try container.encode(v, forKey: .sessionStorage)
        case .cookies(let v):
            try container.encode("cookies", forKey: .kind)
            try container.encode(v, forKey: .cookies)
        case .history(let v):
            try container.encode("history", forKey: .kind)
            try container.encode(v, forKey: .history)
        case .bookmarksRemoved(let bookmark):
            try container.encode("bookmarks_removed", forKey: .kind)
            try container.encode(bookmark, forKey: .bookmark)
        case .raw(let v):
            try container.encode("raw", forKey: .kind)
            try container.encode(v, forKey: .raw)
        }
    }
}

// MARK: - AnyCodable (type-erased JSON value)

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        if let codable = value as? AnyCodable {
            self.value = codable.value
        } else if let v = value as? [AnyCodable] {
            self.value = v
        } else if let v = value as? [String: AnyCodable] {
            self.value = v
        } else if let v = value as? [Any] {
            self.value = v.map { AnyCodable($0) }
        } else if let v = value as? [String: Any] {
            self.value = v.mapValues { AnyCodable($0) }
        } else {
            self.value = value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self.value = v }
        else if let v = try? container.decode(Int.self) { self.value = v }
        else if let v = try? container.decode(Double.self) { self.value = v }
        else if let v = try? container.decode(String.self) { self.value = v }
        else if let v = try? container.decode([AnyCodable].self) { self.value = v.map(\.value) }
        else if let v = try? container.decode([String: AnyCodable].self) { self.value = v.mapValues(\.value) }
        else { self.value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [AnyCodable]: try container.encode(v)
        case let v as [String: AnyCodable]: try container.encode(v)
        case is NSNull: try container.encodeNil()
        default: try container.encodeNil()
        }
    }
}
