// Browser.swift
// BrowSync — Browser data model

import Foundation

// MARK: - Browser

enum Browser: String, CaseIterable, Codable, Identifiable, Hashable {
    case safari = "safari"
    case chrome = "chrome"
    case arc = "arc"
    case edge = "edge"
    case brave = "brave"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .arc: return "Arc"
        case .edge: return "Edge"
        case .brave: return "Brave"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .arc: return "company.thebrowser.Browser"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        }
    }

    var sfSymbol: String {
        switch self {
        case .safari: return "safari"
        case .chrome: return "circle.grid.cross"
        case .arc: return "arc.circle"
        case .edge: return "e.circle"
        case .brave: return "b.circle"
        }
    }

    // Extension directory path fragment for Chromium-based browsers
    var extensionBasePath: String? {
        switch self {
        case .safari: return nil
        case .chrome: return "Google/Chrome"
        case .arc: return "Arc/User Data"
        case .edge: return "Microsoft Edge"
        case .brave: return "BraveSoftware/Brave-Browser"
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

    var displayName: String {
        switch self {
        case .notInstalled: return String(localized: "Not Installed")
        case .extensionRequired: return String(localized: "Extension Required")
        case .extensionDisabled: return String(localized: "Extension Disabled")
        case .waitingConnection: return String(localized: "连接中...")
        case .connected: return String(localized: "已连接")
        case .offline: return String(localized: "已离线")
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
