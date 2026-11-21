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
        approveBrowserAfterConsent("firefox")
    }

    /// Records consent the user gave in another BrowSync prompt for this exact
    /// browser. An explicit denial is never overridden.
    @discardableResult
    func approveBrowserAfterConsent(_ browserID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !deniedBrowsers.contains(browserID) else { return false }
        pendingBrowsers.remove(browserID)
        approvedBrowsers.insert(browserID)
        defaults.set(approvedBrowsers.sorted(), forKey: Self.approvedBrowsersKey)
        defaults.synchronize()
        return true
    }

    /// Non-mutating check; `evaluateBrowser` marks unknown browsers pending.
    func isBrowserApproved(_ browserID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return approvedBrowsers.contains(browserID) && !deniedBrowsers.contains(browserID)
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

// MARK: - Loopback peer identity

/// Identifies the app that owns the client end of a loopback connection. An
/// extension's own report cannot tell Chromium (or Gecko) hosts apart: Chrome,
/// Arc and an embedded Chromium all say "chrome". The kernel's TCP table names
/// the process behind every socket. It is an opportunistic signal only: a
/// team-signed sandboxed build is shown just its own sockets, and every caller
/// must keep working (with its previous inference) when this returns nil.
enum LoopbackPeer {
    struct SocketRecord: Equatable {
        var localPort: UInt16
        var foreignPort: UInt16
        var uid: UInt32
        var lastPID: Int32
        var effectivePID: Int32
    }

    // xnu bsd/netinet/in_pcb.h (xinpcb_n) and sys/socketvar.h (xsocket_n),
    // the structures `netstat` reads. The layout is verified on every lookup
    // against this process's own accepted socket before any peer is trusted.
    private static let xinpgenSize = 24
    private static let kindSocket: UInt32 = 0x001
    private static let kindInpcb: UInt32 = 0x010
    private static let foreignPortOffset = 16, localPortOffset = 18
    private static let uidOffset = 64, lastPIDOffset = 68, effectivePIDOffset = 72

    /// Parses `net.inet.tcp.pcblist_n`. Malformed input yields no records.
    static func records(fromPCBList data: [UInt8]) -> [SocketRecord] {
        func u32(_ offset: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) } }
        func i32(_ offset: Int) -> Int32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) } }
        func port(_ offset: Int) -> UInt16 { UInt16(data[offset]) << 8 | UInt16(data[offset + 1]) }
        guard data.count >= xinpgenSize else { return [] }
        var records: [SocketRecord] = []
        var ports: (local: UInt16, foreign: UInt16)?
        var offset = (Int(u32(0)) + 7) & ~7
        while offset + 8 <= data.count {
            let length = Int(u32(offset)), kind = u32(offset + 4)
            // The list ends with another xinpgen.
            guard length > xinpgenSize, offset + length <= data.count else { break }
            if kind == kindInpcb, length >= localPortOffset + 2 {
                ports = (port(offset + localPortOffset), port(offset + foreignPortOffset))
            } else if kind == kindSocket, length >= effectivePIDOffset + 4, let current = ports {
                records.append(SocketRecord(localPort: current.local, foreignPort: current.foreign, uid: u32(offset + uidOffset),
                                            lastPID: i32(offset + lastPIDOffset), effectivePID: i32(offset + effectivePIDOffset)))
                ports = nil
            }
            offset += (length + 7) & ~7
        }
        return records
    }

    /// The client end of one of our accepted connections, or nil when it
    /// cannot be determined unambiguously.
    static func peer(in records: [SocketRecord], clientPort: UInt16, serverPort: UInt16,
                     serverPID: Int32, serverUID: UInt32) -> SocketRecord? {
        // Layout self-check: one of our own sockets on this port must carry our
        // uid and pid in the fields read below. Our end of this connection may
        // not be listed yet while the registration is handled (Network.framework
        // accepts lazily), but our listening socket always is.
        guard records.contains(where: {
            $0.localPort == serverPort && ($0.foreignPort == clientPort || $0.foreignPort == 0) &&
                $0.uid == serverUID && $0.lastPID == serverPID
        }) else { return nil }
        let peers = records.filter { $0.localPort == clientPort && $0.foreignPort == serverPort }
        guard peers.count == 1, peers[0].lastPID > 0, peers[0].lastPID != serverPID else { return nil }
        return peers[0]
    }

    /// The app behind a peer socket. The self-checked last process decides;
    /// only when it lives outside any app (WebKit's networking service acting
    /// for Safari or Orion) is the delegating app, recorded as the effective
    /// process, used instead.
    static func hostAppURL(of peer: SocketRecord, executablePath: (Int32) -> String?) -> URL? {
        if let path = executablePath(peer.lastPID), let app = hostAppURL(forExecutablePath: path) { return app }
        guard peer.effectivePID > 0, peer.effectivePID != peer.lastPID,
              let path = executablePath(peer.effectivePID) else { return nil }
        return hostAppURL(forExecutablePath: path)
    }

    /// The outermost app bundle containing an executable; helpers live inside
    /// their browser (`Google Chrome.app/…/Google Chrome Helper.app/…`).
    static func hostAppURL(forExecutablePath path: String) -> URL? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])))
    }

    private static func readPCBList() -> [SocketRecord]? {
        var size = 0
        guard sysctlbyname("net.inet.tcp.pcblist_n", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        // Connections come and go between the two calls.
        var data = [UInt8](repeating: 0, count: size + 16_384)
        var length = data.count
        guard sysctlbyname("net.inet.tcp.pcblist_n", &data, &length, nil, 0) == 0 else { return nil }
        return records(fromPCBList: Array(data.prefix(length)))
    }

    private static func bundleID(of peer: SocketRecord) -> String? {
        let app = hostAppURL(of: peer) { pid in
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            return proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : nil
        }
        return app.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// The bundle ID of the app that opened the loopback connection from
    /// `clientPort` to our `serverPort`.
    static func hostBundleID(clientPort: UInt16, serverPort: UInt16) -> String? {
        guard let records = readPCBList(),
              let peer = peer(in: records, clientPort: clientPort, serverPort: serverPort,
                              serverPID: getpid(), serverUID: getuid()) else { return nil }
        return bundleID(of: peer)
    }

    /// Every currently open connection to `serverPort` with its host app,
    /// nil where it could not be resolved. Used while a WebSocket handshake is
    /// pending, before the connection is known by its port.
    static func connectedHosts(serverPort: UInt16) -> [(clientPort: UInt16, bundleID: String?)] {
        guard let records = readPCBList() else { return [] }
        return records.filter { $0.foreignPort == serverPort }.map { client in
            let peer = peer(in: records, clientPort: client.localPort, serverPort: serverPort,
                            serverPID: getpid(), serverUID: getuid())
            return (client.localPort, peer.flatMap(bundleID(of:)))
        }
    }
}
