// Browser.swift
// BrowSync — Browser data model

import Foundation
import AppKit

// MARK: - Browser

enum Browser: String, CaseIterable, Codable, Identifiable, Hashable {
    case safari = "safari"
    case chrome = "chrome"
    case arc = "arc"
    case edge = "edge"
    case brave = "brave"
    case firefox = "firefox"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .arc: return "Arc"
        case .edge: return "Edge"
        case .brave: return "Brave"
        case .firefox: return "Firefox"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .arc: return "company.thebrowser.Browser"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        case .firefox: return "org.mozilla.firefox"
        }
    }

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    var sfSymbol: String {
        switch self {
        case .safari: return "safari"
        case .chrome: return "circle.grid.cross"
        case .arc: return "arc.circle"
        case .edge: return "e.circle"
        case .brave: return "b.circle"
        case .firefox: return "f.circle"
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
        case .firefox: return nil
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
