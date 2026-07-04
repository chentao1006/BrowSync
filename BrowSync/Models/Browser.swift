// Browser.swift
// BrowSync — Browser data model

import Foundation
import AppKit

// MARK: - Browser

struct Browser: Codable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var bundleIdentifier: String
    var sfSymbol: String
    var extensionBasePath: String?
    var isCustom: Bool

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    // MARK: Standard Browsers
    static let safari = Browser(id: "safari", displayName: "Safari", bundleIdentifier: "com.apple.Safari", sfSymbol: "safari", extensionBasePath: nil, isCustom: false)
    static let chrome = Browser(id: "chrome", displayName: "Chrome", bundleIdentifier: "com.google.Chrome", sfSymbol: "circle.grid.cross", extensionBasePath: "Google/Chrome", isCustom: false)
    static let arc = Browser(id: "arc", displayName: "Arc", bundleIdentifier: "company.thebrowser.Browser", sfSymbol: "arc.circle", extensionBasePath: "Arc/User Data", isCustom: false)
    static let edge = Browser(id: "edge", displayName: "Edge", bundleIdentifier: "com.microsoft.edgemac", sfSymbol: "e.circle", extensionBasePath: "Microsoft Edge", isCustom: false)
    static let brave = Browser(id: "brave", displayName: "Brave", bundleIdentifier: "com.brave.Browser", sfSymbol: "b.circle", extensionBasePath: "BraveSoftware/Brave-Browser", isCustom: false)
    static let firefox = Browser(id: "firefox", displayName: "Firefox", bundleIdentifier: "org.mozilla.firefox", sfSymbol: "f.circle", extensionBasePath: nil, isCustom: false)
    static let vivaldi = Browser(id: "vivaldi", displayName: "Vivaldi", bundleIdentifier: "com.vivaldi.Vivaldi", sfSymbol: "v.circle", extensionBasePath: "Vivaldi", isCustom: false)
    static let opera = Browser(id: "opera", displayName: "Opera", bundleIdentifier: "com.operasoftware.Opera", sfSymbol: "o.circle", extensionBasePath: "com.operasoftware.Opera", isCustom: false)
    static let yandex = Browser(id: "yandex", displayName: "Yandex", bundleIdentifier: "ru.yandex.desktop.yandex-browser", sfSymbol: "y.circle", extensionBasePath: "Yandex/YandexBrowser", isCustom: false)
    static let orion = Browser(id: "orion", displayName: "Orion", bundleIdentifier: "com.kagi.kagimacOS", sfSymbol: "o.circle", extensionBasePath: nil, isCustom: false) // Orion uses WebKit, but supports Chrome extensions
    static let helium = Browser(id: "helium", displayName: "Helium", bundleIdentifier: "net.imput.helium", sfSymbol: "h.circle", extensionBasePath: "net.imput.helium", isCustom: false)
    static let browseros = Browser(id: "browseros", displayName: "BrowserOS", bundleIdentifier: "com.browseros.browser", sfSymbol: "b.circle", extensionBasePath: "BrowserOS", isCustom: false)

    static let standardBrowsers: [Browser] = [
        .safari, .chrome, .arc, .edge, .brave, .firefox, .vivaldi, .opera, .yandex, .orion, .helium, .browseros
    ]
    
    // Support legacy allCases for compatibility if it's used heavily without our knowledge.
    static var allCases: [Browser] { standardBrowsers }
    
    // Lookup by ID
    init?(rawValue: String) {
        if let standard = Browser.standardBrowsers.first(where: { $0.id == rawValue }) {
            self = standard
        } else {
            return nil
        }
    }
    
    var rawValue: String { id }

    // MARK: Codable Support
    
    enum CodingKeys: String, CodingKey {
        case id, displayName, bundleIdentifier, sfSymbol, extensionBasePath, isCustom
    }

    init(id: String, displayName: String, bundleIdentifier: String, sfSymbol: String, extensionBasePath: String?, isCustom: Bool) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.sfSymbol = sfSymbol
        self.extensionBasePath = extensionBasePath
        self.isCustom = isCustom
    }

    init(from decoder: Decoder) throws {
        // Try decoding as a string first (backward compatibility for standard browsers)
        if let container = try? decoder.singleValueContainer(),
           let stringValue = try? container.decode(String.self) {
            if let standard = Browser.standardBrowsers.first(where: { $0.id == stringValue }) {
                self = standard
                return
            }
        }
        
        // Otherwise decode as a dictionary
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        self.sfSymbol = try container.decode(String.self, forKey: .sfSymbol)
        self.extensionBasePath = try container.decodeIfPresent(String.self, forKey: .extensionBasePath)
        self.isCustom = try container.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
    }

    func encode(to encoder: Encoder) throws {
        if isCustom {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(displayName, forKey: .displayName)
            try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
            try container.encode(sfSymbol, forKey: .sfSymbol)
            try container.encode(extensionBasePath, forKey: .extensionBasePath)
            try container.encode(isCustom, forKey: .isCustom)
        } else {
            var container = encoder.singleValueContainer()
            try container.encode(id)
        }
    }
}

// MARK: - Extension Status

enum ExtensionStatus: String, Codable, Equatable {
    case notInstalled = "not_installed"
    case extensionRequired = "extension_required"
    case extensionDisabled = "extension_disabled"
    case waitingConnection = "waiting_connection"
    case connected = "connected"
    case offline = "offline"

    var displayName: LocalizedStringResource {
        switch self {
        case .notInstalled: return "Not Installed"
        case .extensionRequired: return "Extension Required"
        case .extensionDisabled: return "Extension Disabled"
        case .waitingConnection: return "Waiting Connection"
        case .connected: return "Connected"
        case .offline: return "Offline"
        }
    }

    var color: String {
        switch self {
        case .notInstalled: return "gray"
        case .extensionRequired: return "orange"
        case .extensionDisabled: return "red"
        case .waitingConnection: return "yellow"
        case .connected: return "green"
        case .offline: return "gray"
        }
    }
}

// MARK: - Browser Info

struct BrowserInfo: Identifiable, Equatable {
    let id: Browser
    var browser: Browser { id }
    var displayName: String { browser.displayName }
    var version: String?
    var appURL: URL?
    var isInstalled: Bool
    var extensionStatus: ExtensionStatus
    var isDefault: Bool
    var lastSeen: Date?

    var isConnected: Bool {
        extensionStatus == .connected
    }

    static func placeholder(for browser: Browser) -> BrowserInfo {
        BrowserInfo(
            id: browser,
            version: nil,
            appURL: nil,
            isInstalled: false,
            extensionStatus: .notInstalled,
            isDefault: false,
            lastSeen: nil
        )
    }
}
