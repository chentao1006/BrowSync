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
        ([bundleIdentifier] + Self.bundleAliases[id, default: []]).lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    /// Installed on this Mac (Safari always is).
    var isInstalledApp: Bool { self == .safari || appURL != nil }

    // MARK: Standard Browsers
    static let safari = Browser(id: "safari", displayName: "Safari", bundleIdentifier: "com.apple.Safari", sfSymbol: "safari", extensionBasePath: nil, isCustom: false)
    static let chrome = Browser(id: "chrome", displayName: "Chrome", bundleIdentifier: "com.google.Chrome", sfSymbol: "circle.grid.cross", extensionBasePath: "Google/Chrome", isCustom: false)
    static let arc = Browser(id: "arc", displayName: "Arc", bundleIdentifier: "company.thebrowser.Browser", sfSymbol: "arc.circle", extensionBasePath: "Arc/User Data", isCustom: false)
    static let edge = Browser(id: "edge", displayName: "Edge", bundleIdentifier: "com.microsoft.edgemac", sfSymbol: "e.circle", extensionBasePath: "Microsoft Edge", isCustom: false)
    static let brave = Browser(id: "brave", displayName: "Brave", bundleIdentifier: "com.brave.Browser", sfSymbol: "b.circle", extensionBasePath: "BraveSoftware/Brave-Browser", isCustom: false)
    static let firefox = Browser(id: "firefox", displayName: "Firefox", bundleIdentifier: "org.mozilla.firefox", sfSymbol: "f.circle", extensionBasePath: nil, isCustom: false)
    static let libreWolf = Browser(id: "librewolf", displayName: "LibreWolf", bundleIdentifier: "net.librewolf.librewolf", sfSymbol: "l.circle", extensionBasePath: nil, isCustom: false)
    static let vivaldi = Browser(id: "vivaldi", displayName: "Vivaldi", bundleIdentifier: "com.vivaldi.Vivaldi", sfSymbol: "v.circle", extensionBasePath: "Vivaldi", isCustom: false)
    static let opera = Browser(id: "opera", displayName: "Opera", bundleIdentifier: "com.operasoftware.Opera", sfSymbol: "o.circle", extensionBasePath: "com.operasoftware.Opera", isCustom: false)
    static let yandex = Browser(id: "yandex", displayName: "Yandex", bundleIdentifier: "ru.yandex.desktop.yandex-browser", sfSymbol: "y.circle", extensionBasePath: "Yandex/YandexBrowser", isCustom: false)
    static let orion = Browser(id: "orion", displayName: "Orion", bundleIdentifier: "com.kagi.kagimacOS", sfSymbol: "o.circle", extensionBasePath: nil, isCustom: false) // Orion uses WebKit, but supports Chrome extensions
    static let helium = Browser(id: "helium", displayName: "Helium", bundleIdentifier: "net.imput.helium", sfSymbol: "h.circle", extensionBasePath: "net.imput.helium", isCustom: false)
    static let browseros = Browser(id: "browseros", displayName: "BrowserOS", bundleIdentifier: "com.browseros.browser", sfSymbol: "b.circle", extensionBasePath: "BrowserOS", isCustom: false)

    private static let builtInBrowsers: [Browser] = [
        .safari, .chrome, .arc, .edge, .brave, .firefox, .libreWolf, .vivaldi, .opera, .yandex, .orion, .helium, .browseros
    ]
    
    // Keep the shipped IDs readable even when a browser is uninstalled:
    // settings, approvals and archived bookmarks refer to these IDs.
    private static let discoveryLock = NSLock()
    private static var discovered = scanInstalledBrowsers()
    private static var lastDiscovery = Date()
    /// Bundle IDs the user already added as custom browsers. Discovery must not
    /// give those apps a second ID, or their existing settings would be orphaned.
    private static var reservedBrowsers: [Browser] = []

    private static func scanInstalledBrowsers() -> (browsers: [Browser], gecko: Set<String>) {
        guard let url = URL(string: "https://example.com") else { return ([], []) }
        return discoverBrowsers(at: NSWorkspace.shared.urlsForApplications(toOpen: url))
    }

    /// Rescans installed apps. `minimumInterval` throttles repeated scans
    /// (an unpaired extension retries registration every few seconds).
    static func refreshDiscovery(minimumInterval: TimeInterval = 0) {
        discoveryLock.lock()
        let isRecent = Date().timeIntervalSince(lastDiscovery) < minimumInterval
        discoveryLock.unlock()
        guard !isRecent else { return }
        let result = scanInstalledBrowsers()
        discoveryLock.lock()
        discovered = result
        lastDiscovery = Date()
        discoveryLock.unlock()
    }

    static func reserveCustomBrowsers(_ custom: [Browser]) {
        discoveryLock.lock()
        reservedBrowsers = custom
        discoveryLock.unlock()
    }

    /// Other bundle IDs shipped for the same built-in browser. Firefox channels
    /// are listed explicitly: Gecko forks built without a distribution ID
    /// (older LibreWolf releases) also use `org.mozilla.<name>`.
    private static let bundleAliases: [String: [String]] = [
        "firefox": ["org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"],
        "librewolf": ["org.mozilla.librewolf"],
    ]

    private var ownedBundleIDs: [String] {
        ([bundleIdentifier] + Self.bundleAliases[id, default: []]).map { $0.lowercased() }
    }

    /// True when an app with `bundleID` is this browser: the exact app, a known
    /// alias, or a channel of it (Chrome Canary, Edge Beta…), which has always
    /// shared the stable channel's identity and settings.
    func ownsBundleID(_ bundleID: String) -> Bool {
        matchLength(bundleID) != nil
    }

    /// Length of the owned ID that matched; an exact match ranks above every prefix.
    private func matchLength(_ bundleID: String) -> Int? {
        let candidate = bundleID.lowercased()
        if ownedBundleIDs.contains(candidate) { return Int.max }
        return ownedBundleIDs.filter { candidate.hasPrefix($0 + ".") }.map(\.count).max()
    }

    /// The registered browser a running app belongs to. The most specific
    /// owner wins, so a custom "Chrome Canary" entry is not also Chrome.
    static func owner(ofBundleID bundleID: String, in browsers: [Browser]) -> Browser? {
        // On an equal match a user's custom entry wins over a built-in alias.
        browsers.compactMap { browser in browser.matchLength(bundleID).map { (browser, $0) } }
            .max { ($0.1, $0.0.isCustom ? 1 : 0) < ($1.1, $1.0.isCustom ? 1 : 0) }?.0
    }

    /// Registered browsers with a running app, in registry order.
    static func runningBrowsers(in browsers: [Browser], runningBundleIDs: [String]) -> [Browser] {
        let owners = Set(runningBundleIDs.compactMap { owner(ofBundleID: $0, in: browsers)?.id })
        return browsers.filter { owners.contains($0.id) }
    }

    static func discoverBrowsers(at urls: [URL]) -> (browsers: [Browser], gecko: Set<String>) {
        var candidates: [String: [Browser]] = [:]
        var gecko: Set<String> = []
        for url in urls {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { continue }
            let isGecko = isGeckoApp(at: url)
            // Record the engine before the ownership skip: a custom entry may
            // own a bundle that a built-in alias also matches.
            if isGecko { gecko.insert(bundleID) }
            guard !builtInBrowsers.contains(where: { $0.ownsBundleID(bundleID) }) else { continue }
            let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            guard isGecko || hasChromiumFramework(in: url) else { continue }
            // A dash separates browser and instance in the existing wire format.
            let id = bundleID.lowercased().replacingOccurrences(of: "-", with: "%2d")
            guard !id.isEmpty, !builtInBrowsers.contains(where: { $0.id == id }) else { continue }
            let candidate = Browser(id: id, displayName: displayName, bundleIdentifier: bundleID,
                                    sfSymbol: "globe", extensionBasePath: nil, isCustom: false)
            if candidates[id]?.contains(where: { $0.bundleIdentifier == bundleID }) != true {
                candidates[id, default: []].append(candidate)
            }
        }
        let unique = candidates.values.compactMap { $0.count == 1 ? $0.first : nil }
        return (unique.sorted { $0.id < $1.id }, gecko)
    }

    private static func isGeckoApp(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/XUL").path)
    }

    private static func hasChromiumFramework(in url: URL) -> Bool {
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil) else { return false }
        // Electron and CEF apps embed the same Chromium resources but cannot
        // run the extension.
        let embedders: Set<String> = ["Electron Framework.framework", "Chromium Embedded Framework.framework"]
        if entries.contains(where: { embedders.contains($0.lastPathComponent) }) { return false }
        return entries.contains { framework in
            framework.pathExtension == "framework" &&
                FileManager.default.fileExists(atPath: framework.appendingPathComponent("Resources/resources.pak").path) &&
                FileManager.default.fileExists(atPath: framework.appendingPathComponent("Resources/icudtl.dat").path)
        }
    }

    /// Whether the app at `url` can run the Gecko (`gecko`) or the Chromium extension.
    static func isBrowserApp(at url: URL, gecko: Bool) -> Bool {
        gecko ? isGeckoApp(at: url) : hasChromiumFramework(in: url)
    }

    /// Names of running apps with the same engine that no registered browser
    /// owns. While one runs, a generic "chrome"/"firefox" registration may come
    /// from it, so the only registered candidate cannot be inferred.
    static func unregisteredRunningBrowserApps(gecko: Bool, registry: [Browser],
                                               running: [(bundleID: String, url: URL, name: String)]) -> [String] {
        running.filter { app in
            owner(ofBundleID: app.bundleID, in: registry) == nil && declaresWebURLs(at: app.url) &&
                isBrowserApp(at: app.url, gecko: gecko)
        }.map(\.name).sorted()
    }

    /// Browsers register for http/https; XUL or Chromium apps that do not
    /// (Thunderbird, Zotero, NW.js tools) cannot be where a user browses.
    private static func declaresWebURLs(at url: URL) -> Bool {
        let types = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return types.contains { type in
            ((type["CFBundleURLSchemes"] as? [String]) ?? []).contains { ["http", "https"].contains($0.lowercased()) }
        }
    }

    static var standardBrowsers: [Browser] {
        discoveryLock.lock()
        defer { discoveryLock.unlock() }
        let reservedBundles = Set(reservedBrowsers.map(\.bundleIdentifier))
        return builtInBrowsers + discovered.browsers.filter { !reservedBundles.contains($0.bundleIdentifier) }
    }

    static func registeredBrowsers(including custom: [Browser]) -> [Browser] {
        // A custom browser keeps its own ID even when discovery also finds it.
        discoveryLock.lock()
        defer { discoveryLock.unlock() }
        return registry(custom: custom)
    }

    /// Called with discoveryLock held so discovery and custom entries form one snapshot.
    private static func registry(custom: [Browser]) -> [Browser] {
        let customBundles = Set(custom.map(\.bundleIdentifier))
        let standard = builtInBrowsers + discovered.browsers.filter { !customBundles.contains($0.bundleIdentifier) }
        let bundles = Set(standard.map(\.bundleIdentifier))
        return standard + custom.filter { !bundles.contains($0.bundleIdentifier) }
    }

    var isBuiltIn: Bool { Self.builtInBrowsers.contains { $0.id == id } }

    enum PairingDecision: Equatable {
        case host(Browser)
        case choose
        case unavailable
    }

    /// - Parameter trustsReportedID: whether `reportedID` names the product
    ///   reliably. Gecko reports its product name; Chromium's ID comes from
    ///   user-agent tokens that sibling apps share (Opera and Opera GX), so it
    ///   may only veto a candidate, never select one among several.
    static func pairingDecision(candidates: [Browser], reportedID: String, savedBundleID: String?,
                                trustsReportedID: Bool) -> PairingDecision {
        if let savedBundleID {
            guard let saved = candidates.first(where: { $0.bundleIdentifier == savedBundleID }) else { return .unavailable }
            return .host(saved)
        }
        guard !candidates.isEmpty else { return .unavailable }
        // "safari" is the Chromium worker's fallback for a WebKit user agent
        // (Orion without its token); Safari itself never runs this extension.
        let isGeneric = ["firefox", "chrome", "safari"].contains(reportedID)
        if candidates.count == 1 {
            let candidate = candidates[0]
            // A specific product that is not this candidate means the real host
            // is missing from the registry or not yet listed as running. Never
            // bind it, and never ask "Allow <candidate>?" for another app; this
            // is not persisted, so a later registration can still pair.
            // Gecko names its product; Chromium user-agent tokens are shared
            // by sibling apps (Opera GX reports Opera), so they only contradict
            // a built-in candidate.
            let contradicts = !isGeneric && reportedID != candidate.id &&
                (candidate.isBuiltIn || (trustsReportedID && builtInBrowsers.contains { $0.id == reportedID }))
            return contradicts ? .unavailable : .host(candidate)
        }
        if trustsReportedID, !isGeneric {
            let matches = candidates.filter { $0.id == reportedID }
            if matches.count == 1 { return .host(matches[0]) }
        }
        return .choose
    }

    var usesFirefoxExtension: Bool {
        if self == .firefox || self == .libreWolf { return true }
        Self.discoveryLock.lock()
        let discoveredGecko = Self.discovered.gecko.contains(bundleIdentifier)
        Self.discoveryLock.unlock()
        if discoveredGecko { return true }
        // A custom entry for an app that is not an https handler is never
        // scanned; decide from its bundle rather than assume Chromium.
        return isCustom && appURL.map(Self.isGeckoApp) == true
    }

    static var allCases: [Browser] {
        Self.discoveryLock.lock()
        defer { Self.discoveryLock.unlock() }
        return registry(custom: reservedBrowsers)
    }

    init?(rawValue: String) {
        let candidates = Self.allCases
        if let exact = candidates.first(where: { $0.id == rawValue }) {
            self = exact
            return
        }
        let matches = candidates.filter { $0.id.caseInsensitiveCompare(rawValue) == .orderedSame }
        guard matches.count == 1 else { return nil }
        self = matches[0]
    }
    
    /// Archived snapshot and backup names may contain a legacy instance suffix.
    /// Overlapping registered IDs cannot establish ownership from a prefix alone.
    static func archivedBrowser(for identifier: String) -> Browser? {
        if let exact = Browser(rawValue: identifier) { return exact }
        let key = identifier.lowercased()
        let matches = allCases.filter { key.hasPrefix($0.id.lowercased() + "-") }
        return matches.count == 1 ? matches[0] : nil
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
            guard let browser = Browser(rawValue: stringValue) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown browser ID")
            }
            self = browser
            return
        }
        
        // Otherwise decode as a dictionary
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(String.self, forKey: .id)
        let decodedCustom = try container.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
        // A discovered browser's name can change with an app update; equality
        // compares every field, so settings must resolve to the live entry.
        if !decodedCustom, let standard = Browser.standardBrowsers.first(where: { $0.id == decodedID }) {
            self = standard
            return
        }
        self.id = decodedID
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        self.sfSymbol = try container.decode(String.self, forKey: .sfSymbol)
        self.extensionBasePath = try container.decodeIfPresent(String.self, forKey: .extensionBasePath)
        self.isCustom = try container.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
    }

    func encode(to encoder: Encoder) throws {
        if isCustom || !isBuiltIn {
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
