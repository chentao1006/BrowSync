// Local extension approvals are deliberately separate from synced app settings.
// Browser consent is keyed by reported browser ID. The browser-managed Origin
// helps reject other extensions, but local native clients can forge both.

import Foundation
import Network

final class DaemonConnectionPolicy: @unchecked Sendable {
    enum Decision: Equatable {
        case allow
        case requestApproval(String)
        case reject
    }

    static let loopbackHosts = ["127.0.0.1", "::1"]
    // Keep in sync with AppConfig.chromiumExtensionID. Chromium assigns this
    // Origin to the published BrowSync extension across Chromium browsers.
    static let chromiumExtensionOrigin = "chrome-extension://nahmlhblgjnkkcmaiicngaepeepofpkh"
    private static let defaultsKey = "approvedLocalExtensionOrigins"
    private static let deniedDefaultsKey = "deniedLocalExtensionOrigins"
    private static let approvedBrowsersKey = "approvedLocalExtensionBrowsers"
    private static let deniedBrowsersKey = "deniedLocalExtensionBrowsers"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var approvedOrigins: Set<String>
    private var deniedOriginsStore: Set<String>
    private var pendingOrigins: Set<String> = []
    private var approvedBrowsers: Set<String>
    private var deniedBrowsers: Set<String>
    private var pendingBrowsers: Set<String> = []
    private var session = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        approvedOrigins = Set((defaults.stringArray(forKey: Self.defaultsKey) ?? []).compactMap(Self.extensionOrigin))
        deniedOriginsStore = Set((defaults.stringArray(forKey: Self.deniedDefaultsKey) ?? []).compactMap(Self.extensionOrigin))
        approvedBrowsers = Set(defaults.stringArray(forKey: Self.approvedBrowsersKey) ?? [])
        deniedBrowsers = Set(defaults.stringArray(forKey: Self.deniedBrowsersKey) ?? [])
        approvedOrigins.subtract(deniedOriginsStore)
        approvedBrowsers.subtract(deniedBrowsers)
    }

    static func parameters(host: String, port: UInt16, webSocket: NWProtocolWebSocket.Options) -> NWParameters {
        precondition(loopbackHosts.contains(host))
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        // Keep IPv6 from claiming the IPv4 port through a dual-stack socket.
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = host == "::1" ? .v6 : .v4
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        // NWListener needs this to put the separate IPv4 and IPv6 loopback
        // sockets on the same port. The regression check also tests that a
        // competing listener cannot take either exact endpoint.
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    /// Only serialized browser-extension origins; never websites, null, missing,
    /// duplicate headers, credentials, ports, paths, queries or fragments.
    static func extensionOrigin(_ value: String) -> String? {
        guard let url = URLComponents(string: value),
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              ["chrome-extension", "moz-extension", "safari-web-extension"].contains(scheme),
              !host.isEmpty, host.count <= 255,
              host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              url.user == nil, url.password == nil, url.port == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil,
              value.lowercased() == "\(scheme)://\(host)" else { return nil }
        return "\(scheme)://\(host)"
    }

    func evaluate(headers: [(name: String, value: String)], session: UUID? = nil) -> Decision {
        let origins = headers.filter { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }
        guard origins.count == 1, let origin = Self.extensionOrigin(origins[0].value) else { return .reject }
        lock.lock()
        defer { lock.unlock() }
        if let session, session != self.session { return .reject }
        if origin.hasPrefix("safari-web-extension://") { return .allow }
        // The signed Web Store extension has a stable known Origin. An
        // unpacked development build gets a different Chromium-generated ID;
        // require the same explicit, persisted local approval used for Firefox
        // instead of returning a silent 400 at the handshake boundary.
        if origin == Self.chromiumExtensionOrigin { return .allow }
        if deniedOriginsStore.contains(origin) { return .reject }
        if approvedOrigins.contains(origin) { return .allow }
        guard !pendingOrigins.contains(origin), !deniedOriginsStore.contains(origin),
              pendingOrigins.count < 8, deniedOriginsStore.count < 128 else { return .reject }
        pendingOrigins.insert(origin)
        return .requestApproval(origin)
    }

    func resolveOrigin(_ origin: String, allow: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard pendingOrigins.remove(origin) != nil else { return }
        if allow {
            deniedOriginsStore.remove(origin)
            approvedOrigins.insert(origin)
            defaults.set(approvedOrigins.sorted(), forKey: Self.defaultsKey)
            defaults.set(deniedOriginsStore.sorted(), forKey: Self.deniedDefaultsKey)
        } else {
            approvedOrigins.remove(origin)
            deniedOriginsStore.insert(origin)
            defaults.set(approvedOrigins.sorted(), forKey: Self.defaultsKey)
            defaults.set(deniedOriginsStore.sorted(), forKey: Self.deniedDefaultsKey)
        }
        defaults.synchronize()
    }

    func isOriginPending(_ origin: String, session: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.session == session && pendingOrigins.contains(origin)
    }

    var deniedOrigins: [String] {
        lock.lock()
        defer { lock.unlock() }
        return deniedOriginsStore.sorted()
    }

    func retryDeniedOrigin(_ origin: String, session: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.session == session, deniedOriginsStore.contains(origin),
              pendingOrigins.count < 8 else { return false }
        deniedOriginsStore.remove(origin)
        pendingOrigins.insert(origin)
        defaults.set(deniedOriginsStore.sorted(), forKey: Self.deniedDefaultsKey)
        defaults.synchronize()
        return true
    }

    @discardableResult
    func cancelPendingApprovals() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        session = UUID()
        pendingOrigins.removeAll()
        pendingBrowsers.removeAll()
        return session
    }

    var deniedBrowserIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return deniedBrowsers.sorted()
    }

    func isBrowserPending(_ browserID: String, session: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.session == session && pendingBrowsers.contains(browserID)
    }

    func evaluateBrowser(_ browserID: String, session: UUID) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        guard self.session == session else { return .reject }
        if deniedBrowsers.contains(browserID) { return .reject }
        if approvedBrowsers.contains(browserID) { return .allow }
        guard !pendingBrowsers.contains(browserID), !deniedBrowsers.contains(browserID),
              pendingBrowsers.count < 8 else { return .reject }
        pendingBrowsers.insert(browserID)
        return .requestApproval(browserID)
    }

    func resolveBrowser(_ browserID: String, allow: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard pendingBrowsers.remove(browserID) != nil else { return }
        if allow {
            deniedBrowsers.remove(browserID)
            approvedBrowsers.insert(browserID)
            defaults.set(approvedBrowsers.sorted(), forKey: Self.approvedBrowsersKey)
            defaults.set(deniedBrowsers.sorted(), forKey: Self.deniedBrowsersKey)
        } else {
            approvedBrowsers.remove(browserID)
            deniedBrowsers.insert(browserID)
            defaults.set(approvedBrowsers.sorted(), forKey: Self.approvedBrowsersKey)
            defaults.set(deniedBrowsers.sorted(), forKey: Self.deniedBrowsersKey)
        }
        defaults.synchronize()
    }

    func approveFirefoxAfterOriginConsent() {
        lock.lock()
        defer { lock.unlock() }
        guard !deniedBrowsers.contains("firefox") else { return }
        approvedBrowsers.insert("firefox")
        defaults.set(approvedBrowsers.sorted(), forKey: Self.approvedBrowsersKey)
        defaults.synchronize()
    }

    func retryDeniedBrowser(_ browserID: String, session: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.session == session, deniedBrowsers.contains(browserID),
              pendingBrowsers.count < 8 else { return false }
        deniedBrowsers.remove(browserID)
        pendingBrowsers.insert(browserID)
        defaults.set(deniedBrowsers.sorted(), forKey: Self.deniedBrowsersKey)
        defaults.synchronize()
        return true
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        approvedOrigins.removeAll()
        deniedOriginsStore.removeAll()
        pendingOrigins.removeAll()
        approvedBrowsers.removeAll()
        deniedBrowsers.removeAll()
        pendingBrowsers.removeAll()
        defaults.removeObject(forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.deniedDefaultsKey)
        defaults.removeObject(forKey: Self.approvedBrowsersKey)
        defaults.removeObject(forKey: Self.deniedBrowsersKey)
        defaults.synchronize()
    }
}
