import Foundation
import Network
import Darwin

// No real preferences, browser profiles or bookmark data are touched.
private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func synchronize() -> Bool { true }
}

@main
struct DaemonConnectionPolicyTests {
    static func expect(_ value: @autoclosure () -> Bool, _ description: String) {
        guard value() else { fatalError(description) }
    }

    static func main() throws {
        setbuf(stdout, nil)
        let defaults = MemoryDefaults()
        let policy = DaemonConnectionPolicy(defaults: defaults)
        let origin = "chrome-extension://nahmlhblgjnkkcmaiicngaepeepofpkh"
        let headers = [(name: "Origin", value: origin)]
        expect(policy.evaluate(headers: []) == .reject, "Missing Origin")
        expect(policy.evaluate(headers: headers + headers) == .reject, "Duplicate Origin")
        for invalid in ["null", "https://example.com", "http://127.0.0.1", origin + "/", origin + ":80", origin + "?a=b", origin + "#x", "chrome-extension://user@host", "chrome-extension://a%62c", "chrome-extension://", "chrome-extension://a,b"] {
            expect(policy.evaluate(headers: [("Origin", invalid)]) == .reject, "Reject \(invalid)")
        }
        expect(policy.evaluate(headers: headers) == .allow, "Valid extension Origin passes syntax gate")
        let developmentChromiumOrigin = "chrome-extension://fakeextension"
        expect(policy.evaluate(headers: [("Origin", developmentChromiumOrigin)]) == .requestApproval(developmentChromiumOrigin), "Unpacked Chromium extension needs consent")
        expect(policy.evaluate(headers: [("Origin", developmentChromiumOrigin)]) == .reject, "Chromium retries do not duplicate dialogs")
        policy.resolveOrigin(developmentChromiumOrigin, allow: true)
        expect(policy.evaluate(headers: [("Origin", developmentChromiumOrigin)]) == .allow, "Approved unpacked Chromium extension reconnects")
        let firefoxOrigin = "moz-extension://12345678-abcd-1234-abcd-123456789abc"
        expect(policy.evaluate(headers: [("Origin", firefoxOrigin)]) == .requestApproval(firefoxOrigin), "Firefox extension source needs consent")
        expect(policy.evaluate(headers: [("Origin", firefoxOrigin)]) == .reject, "Firefox retries do not duplicate dialogs")
        policy.resolveOrigin(firefoxOrigin, allow: true)
        policy.approveFirefoxAfterOriginConsent()
        expect(policy.evaluate(headers: [("Origin", firefoxOrigin)]) == .allow, "Approved Firefox extension reconnects")
        expect(policy.evaluate(headers: [("Origin", "safari-web-extension://12345678-abcd-1234-abcd-123456789abc")]) == .allow, "Safari Origin passes syntax gate")
        let session = policy.cancelPendingApprovals()
        expect(policy.evaluateBrowser("chrome", session: session) == .requestApproval("chrome"), "Chrome needs browser approval")
        expect(policy.evaluateBrowser("firefox", session: session) == .allow, "Firefox consent does not prompt twice")
        expect(policy.evaluateBrowser("chrome", session: session) == .reject, "Retries do not duplicate dialogs")
        policy.resolveBrowser("chrome", allow: true)
        expect(policy.evaluateBrowser("chrome", session: session) == .allow, "Chrome reconnects without another prompt")
        expect(policy.evaluateBrowser("edge", session: session) == .requestApproval("edge"), "Chrome approval cannot authorize Edge")
        policy.resolveBrowser("edge", allow: false)
        expect(policy.evaluateBrowser("edge", session: session) == .reject, "Denied Edge stays blocked")
        expect(policy.deniedBrowserIDs == ["edge"], "Denied Edge appears in browser list")
        let deniedRestart = DaemonConnectionPolicy(defaults: defaults)
        let deniedRestartSession = deniedRestart.cancelPendingApprovals()
        expect(deniedRestart.evaluateBrowser("edge", session: deniedRestartSession) == .reject, "Denied Edge stays blocked after app restart")
        expect(deniedRestart.deniedBrowserIDs == ["edge"], "Restart preserves Edge denial for the browser list")
        let conflictingDefaults = MemoryDefaults()
        conflictingDefaults.set(["edge"], forKey: "approvedLocalExtensionBrowsers")
        conflictingDefaults.set(["edge"], forKey: "deniedLocalExtensionBrowsers")
        let conflictingPolicy = DaemonConnectionPolicy(defaults: conflictingDefaults)
        let conflictingSession = conflictingPolicy.cancelPendingApprovals()
        expect(conflictingPolicy.evaluateBrowser("edge", session: conflictingSession) == .reject, "Denial wins if stored browser states conflict")
        expect(!policy.retryDeniedBrowser("edge", session: UUID()), "Stale session cannot retry")
        expect(policy.retryDeniedBrowser("edge", session: session), "Edge can be reviewed")
        expect(policy.evaluateBrowser("edge", session: session) == .reject, "Review does not bypass confirmation")
        policy.resolveBrowser("edge", allow: true)
        expect(policy.evaluateBrowser("edge", session: session) == .allow, "Approved Edge reconnects")
        let restarted = DaemonConnectionPolicy(defaults: defaults)
        let restartedSession = restarted.cancelPendingApprovals()
        expect(restarted.evaluateBrowser("chrome", session: restartedSession) == .allow, "Chrome approval survives restart")
        expect(restarted.evaluateBrowser("edge", session: restartedSession) == .allow, "Edge approval survives restart")
        let deniedFirefox = DaemonConnectionPolicy(defaults: MemoryDefaults())
        let deniedFirefoxSession = deniedFirefox.cancelPendingApprovals()
        expect(deniedFirefox.evaluateBrowser("firefox", session: deniedFirefoxSession) == .requestApproval("firefox"), "Firefox browser asks separately when needed")
        deniedFirefox.resolveBrowser("firefox", allow: false)
        expect(deniedFirefox.evaluate(headers: [("Origin", firefoxOrigin)]) == .requestApproval(firefoxOrigin), "New Firefox Origin still needs consent")
        deniedFirefox.resolveOrigin(firefoxOrigin, allow: true)
        deniedFirefox.approveFirefoxAfterOriginConsent()
        expect(deniedFirefox.evaluateBrowser("firefox", session: deniedFirefoxSession) == .reject, "New Origin consent cannot override Firefox denial")
        policy.reset()
        let resetSession = policy.cancelPendingApprovals()
        expect(policy.evaluateBrowser("chrome", session: resetSession) == .requestApproval("chrome"), "Reset revokes browser approval")
        expect(policy.evaluate(headers: headers) == .allow, "Published Chromium extension passes Origin check")
        policy.resolveBrowser("chrome", allow: true)
        let staleSession = policy.cancelPendingApprovals()
        let currentSession = policy.cancelPendingApprovals()
        expect(policy.evaluateBrowser("chrome", session: staleSession) == .reject, "Stopped listener cannot authorize")
        expect(policy.evaluateBrowser("chrome", session: currentSession) == .allow, "Current listener reconnects")
        try verifyListeners(policy: policy, origin: origin)
        print("PASS: extension Origin gate, per-browser Chrome/Edge consent, remembered reconnects, reset, IPv4/IPv6 binding and WebSocket handshakes")
    }

    static func verifyListeners(policy: DaemonConnectionPolicy, origin: String) throws {
        let queue = DispatchQueue(label: "browsync-security-tests")
        var listeners: [NWListener] = []
        var port: UInt16 = 0
        defer { listeners.forEach { $0.cancel() } }
        for host in DaemonConnectionPolicy.loopbackHosts {
            let options = NWProtocolWebSocket.Options()
            options.setClientRequestHandler(queue) { _, headers in
                return NWProtocolWebSocket.Response(status: policy.evaluate(headers: headers) == .allow ? .accept : .reject, subprotocol: nil)
            }
            let parameters = DaemonConnectionPolicy.parameters(host: host, port: port, webSocket: options)
            guard case .hostPort(let boundHost, _) = parameters.requiredLocalEndpoint else { fatalError("Explicit endpoint required") }
            expect(String(describing: boundHost) == host, "Bind only to \(host)")
            let listener = try NWListener(using: parameters)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed: ready.signal()
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.stateUpdateHandler = { state in
                    if case .ready = state {
                        connection.receiveMessage { _, _, _, _ in connection.cancel() }
                    }
                }
                connection.start(queue: queue)
            }
            listener.start(queue: queue)
            expect(ready.wait(timeout: .now() + 5) == .success, "Listener startup timeout")
            expect(listener.state == .ready, "Listener \(host) ready: \(listener.state)")
            port = listener.port!.rawValue
            listeners.append(listener)
        }
        let inspection = Process()
        inspection.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        inspection.arguments = ["-nP", "-a", "-p", String(ProcessInfo.processInfo.processIdentifier), "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        inspection.standardOutput = pipe
        try inspection.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        inspection.waitUntilExit()
        let sockets = String(decoding: data, as: UTF8.self)
        expect(inspection.terminationStatus == 0, "Inspect listener sockets")
        expect(sockets.contains("127.0.0.1:\(port)") && sockets.contains("[::1]:\(port)"), "Both loopback sockets exist")
        expect(!sockets.contains("*:\(port)"), "No wildcard socket")
        print("Verified sockets: 127.0.0.1:\(port) and [::1]:\(port), no wildcard listener")
        for host in DaemonConnectionPolicy.loopbackHosts {
            verifyExclusiveBind(host: host, port: port, queue: queue)
            // Legacy clients send no token or WebSocket subprotocol.
            verifyHandshake(host: host, port: port, origin: origin, allowed: true, queue: queue)
            verifyHandshake(host: host, port: port, origin: "safari-web-extension://87654321-dcba-4321-dcba-abcdef123456", allowed: true, queue: queue)
            verifyHandshake(host: host, port: port, origin: "https://example.com", allowed: false, queue: queue)
            verifyHandshake(host: host, port: port, origin: nil, allowed: false, queue: queue)
            verifyHandshake(host: host, port: port, origin: "moz-extension://unapproved", allowed: false, queue: queue)
        }
    }

    static func verifyExclusiveBind(host: String, port: UInt16, queue: DispatchQueue) {
        let parameters = DaemonConnectionPolicy.parameters(host: host, port: port, webSocket: NWProtocolWebSocket.Options())
        guard let competingListener = try? NWListener(using: parameters) else { return }
        let completed = DispatchSemaphore(value: 0)
        competingListener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed: completed.signal()
            default: break
            }
        }
        competingListener.start(queue: queue)
        expect(completed.wait(timeout: .now() + 5) == .success, "Competing bind timeout")
        expect(competingListener.state != .ready, "Another process could bind \(host):\(port)")
        competingListener.cancel()
    }

    static func verifyHandshake(host: String, port: UInt16, origin: String?, allowed: Bool, queue: DispatchQueue) {
        let options = NWProtocolWebSocket.Options()
        if let origin { options.setAdditionalHeaders([("Origin", origin)]) }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let urlHost = host.contains(":") ? "[\(host)]" : host
        let connection = NWConnection(to: .url(URL(string: "ws://\(urlHost):\(port)/")!), using: parameters)
        let completed = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                expect(allowed, "Unauthorized handshake accepted: \(origin ?? "missing")")
                completed.signal()
            case .failed, .waiting:
                expect(!allowed, "Approved legacy handshake rejected: \(host)")
                completed.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        expect(completed.wait(timeout: .now() + 5) == .success, "Handshake timeout: \(origin ?? "missing")")
        connection.cancel()
    }
}
