// DaemonServer.swift
// BrowSync — WebSocket server using Network.framework NWProtocolWebSocket
// Listens exclusively on 127.0.0.1:62333 and [::1]:62333

import Foundation
import Network
import os.log
import AppKit

// MARK: - Connected Client

final class ConnectedClient {
    let id: String           // instanceId from register message
    let browser: Browser
    let connection: NWConnection
    let installationID: UUID?
    var lastSeen: Date
    var stateCache: [String: Data] = [:]  // site -> last sync payload
    /// From the register message; empty for extension builds that predate it.
    var capabilities: Set<String> = []
    /// An old Gecko build in a non-Firefox host (e.g. LibreWolf). It keeps
    /// calling itself "firefox" and ignores the assigned ID, so messages to it
    /// present this browser's settings under "firefox".
    var presentsAsFirefox = false

    init(id: String, browser: Browser, connection: NWConnection, installationID: UUID?) {
        self.installationID = installationID
        self.id = id
        self.browser = browser
        self.connection = connection
        self.lastSeen = Date()
    }
}

private final class ApprovalAlertAction: NSObject {
    let decide: (Bool) -> Void

    init(decide: @escaping (Bool) -> Void) {
        self.decide = decide
    }

    @objc func allow() { decide(true) }
    @objc func deny() { decide(false) }
}

private final class HostPickerAction: NSObject {
    let allowButton: NSButton

    init(_ allowButton: NSButton) { self.allowButton = allowButton }

    @objc func selected(_ sender: NSPopUpButton) {
        allowButton.isEnabled = sender.indexOfSelectedItem > 0
    }
}

// MARK: - Daemon Server Delegate

protocol DaemonServerDelegate: AnyObject {
    func daemonServer(_ server: DaemonServer, didConnect client: ConnectedClient)
    func daemonServer(_ server: DaemonServer, didDisconnect clientId: String, browser: Browser)
    func daemonServer(_ server: DaemonServer, didReceiveSync message: WSMessage, from clientId: String)
    func daemonServer(_ server: DaemonServer, didReceivePullBookmarks clientId: String)
    func daemonServer(_ server: DaemonServer, didReceiveSettings message: WSMessage, from clientId: String)
    func daemonServer(_ server: DaemonServer, didReceiveOpenSettingsFrom clientId: String)
    func daemonServer(_ server: DaemonServer, didReceiveOpenURL message: WSMessage, from clientId: String)
    /// Another extension installation replaced the one paired with `browser`.
    func daemonServer(_ server: DaemonServer, didReplaceInstallationOf browser: Browser)
    /// Bookmark observations stored under `browser` came from another app.
    /// That browser is not installed, so nothing of its own is pending.
    func daemonServer(_ server: DaemonServer, didFindForeignObservationsOf browser: Browser)
}

// MARK: - Daemon Server

@MainActor
final class DaemonServer: ObservableObject {
    static let port: UInt16 = 62333
    static let heartbeatInterval: TimeInterval = 30
    static let heartbeatTimeout: TimeInterval = 120

    private let logger = Logger(subsystem: "com.ct106.browsync", category: "DaemonServer")

    private var listeners: [NWListener] = []
    private var readyListeners: Set<ObjectIdentifier> = []
    private var restartTask: Task<Void, Never>?
    private let connectionPolicy = DaemonConnectionPolicy()
    private var originApprovalQueue: [String] = []
    private static let pairingDefaultsKey = "extensionHostPairingsByInstallation"
    /// Pairing values: a host bundle ID, `deniedPairing` (shown in Settings),
    /// or `explicitPairing` (reauthorized; the next pairing must be confirmed
    /// in a prompt, never inferred from an earlier browser approval).
    private static let deniedPairing = ""
    private static let explicitPairing = "?"
    @Published private var hostPairings = UserDefaults.standard.dictionary(forKey: DaemonServer.pairingDefaultsKey) as? [String: String] ?? [:]
    private var pairingUnderReview: String?
    private static let resolvedLegacyIdentitiesKey = "resolvedLegacyExtensionIdentities"
    /// "<host bundle ID>><legacy browser ID>" pairs whose misfiled
    /// observations were already discarded, so it happens once per pair.
    private var resolvedLegacyIdentities = Set(UserDefaults.standard.stringArray(forKey: DaemonServer.resolvedLegacyIdentitiesKey) ?? [])
    /// When the user last allowed a Gecko extension Origin without knowing its
    /// host app. With exactly one running Gecko host, that consent also pairs
    /// the extension, so LibreWolf users see one prompt instead of two.
    private var geckoOriginConsentAt: Date?
    private var unmatchedPairingsLogged: Set<String> = []
    /// Apps connected while an Origin's handshake awaited approval.
    private var originApprovalHosts: [String: [(clientPort: UInt16, bundleID: String?)]] = [:]
    /// Unpaired installations whose host matches no registered running
    /// browser, keyed by pairing key, with the product they reported. Not
    /// persisted: the worker keeps retrying and pairs once the host is known.
    @Published private(set) var unmatchedExtensionReports: [String: String] = [:]
    private var browserApprovalQueue: [Browser] = []
    private var approvalAlert: NSAlert?
    private var approvalAlertAction: ApprovalAlertAction?
    private var approvalGeneration = UUID()
    private var activeApprovalSession: UUID?
    private var pendingSince: [ObjectIdentifier: Date] = [:]
    /// Connections that haven't registered yet
    private var pendingConnections: [ObjectIdentifier: NWConnection] = [:]
    /// Registered clients keyed by instanceId
    private var clients: [String: ConnectedClient] = [:]
    private var heartbeatTimer: Timer?

    @Published var isRunning: Bool = false
    @Published var connectedBrowsers: Set<Browser> = []
    @Published private(set) var deniedBrowserIDs: [String] = []
    @Published private(set) var deniedExtensionOrigins: [String] = []

    weak var delegate: DaemonServerDelegate?
    /// Returns true when the app took ownership of a bookmark mutation and the
    /// original payload must not be dispatched.
    var bookmarkMutationInterceptor: ((WSMessage, ConnectedClient) -> Bool)?

    init() {
        deniedBrowserIDs = connectionPolicy.deniedBrowserIDs
        deniedExtensionOrigins = connectionPolicy.deniedOrigins
    }

    // MARK: - Lifecycle

    func start() {
        guard listeners.isEmpty else { return }
        restartTask?.cancel()
        restartTask = nil
        let session = connectionPolicy.cancelPendingApprovals()
        activeApprovalSession = session

        do {
            for host in DaemonConnectionPolicy.loopbackHosts {
                let wsOptions = NWProtocolWebSocket.Options()
                wsOptions.maximumMessageSize = 50_000_000
                wsOptions.autoReplyPing = true
                let policy = connectionPolicy
                let serverPort = Self.port
                wsOptions.setClientRequestHandler(.global(qos: .userInitiated)) { [weak self] _, headers in
                    switch policy.evaluate(headers: headers, session: session) {
                    case .allow:
                        return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
                    case .requestApproval(let origin):
                        // The handshake's TCP connection is open now; it is
                        // closed by the rejection below. Record which apps are
                        // connected so the prompt can name the browser.
                        let hosts = LoopbackPeer.connectedHosts(serverPort: serverPort)
                        Task { @MainActor [weak self] in self?.requestOriginApproval(origin, session: session, connectedHosts: hosts) }
                    case .reject:
                        break
                    }
                    // No WebSocket traffic or registration is accepted before
                    // approval. Existing extensions retry automatically.
                    return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
                }
                let params = DaemonConnectionPolicy.parameters(host: host, port: Self.port, webSocket: wsOptions)
                let listener = try NWListener(using: params)
                listeners.append(listener)
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    Task { @MainActor in
                        guard let self, let listener,
                              self.listeners.contains(where: { $0 === listener }) else { return }
                        self.handleListenerState(state, listener: listener)
                    }
                }
                listener.newConnectionHandler = { [weak self, weak listener] connection in
                    Task { @MainActor in
                        guard let self, let listener,
                              self.listeners.contains(where: { $0 === listener }) else {
                            connection.cancel()
                            return
                        }
                        self.handleNewConnection(connection)
                    }
                }
            }
        } catch {
            logger.error("Failed to create loopback WebSocket listeners: \(error)")
            stop()
            return
        }

        for listener in listeners { listener.start(queue: .global(qos: .userInitiated)) }
        startHeartbeatTimer()
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        let oldListeners = listeners
        listeners.removeAll()
        activeApprovalSession = nil
        readyListeners.removeAll()
        for listener in oldListeners { listener.cancel() }
        for client in Array(clients.values) { removeConnection(client.connection) }
        for (_, conn) in pendingConnections { conn.cancel() }
        clients.removeAll()
        pendingConnections.removeAll()
        pendingSince.removeAll()
        connectedBrowsers.removeAll()
        cancelApprovalDialogs()
        isRunning = false
        logger.info("DaemonServer stopped")
    }

    // MARK: - Listener State

    private func handleListenerState(_ state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            readyListeners.insert(ObjectIdentifier(listener))
            isRunning = readyListeners.count == listeners.count
            logger.info("Loopback WebSocket listener ready: \(String(describing: listener.parameters.requiredLocalEndpoint))")
        case .failed(let error):
            logger.error("Listener failed: \(error)")
            stop()
            restartTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                self?.start()
            }
        default:
            break
        }
    }

    // MARK: - Browser Authorization

    private func approvalContent(for browser: Browser?, message: String) -> NSView {
        func iconView(_ image: NSImage, size: CGFloat) -> NSImageView {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: size),
                view.heightAnchor.constraint(equalToConstant: size)
            ])
            return view
        }

        let appIcon = iconView(NSApp.applicationIconImage, size: 64)
        let linkIcon = iconView(NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage(), size: 26)
        linkIcon.contentTintColor = .secondaryLabelColor
        let browserImage = browser?.appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
        let browserIcon = iconView(browserImage, size: 64)

        let icons = NSStackView(views: [appIcon, linkIcon, browserIcon])
        icons.orientation = .horizontal
        icons.alignment = .centerY
        icons.spacing = 16
        icons.frame = NSRect(x: 0, y: 0, width: 186, height: 68)

        let messageField = NSTextField(wrappingLabelWithString: message)
        messageField.font = .systemFont(ofSize: NSFont.systemFontSize)
        messageField.textColor = .secondaryLabelColor
        messageField.alignment = .natural
        messageField.translatesAutoresizingMaskIntoConstraints = false
        messageField.widthAnchor.constraint(equalToConstant: 420).isActive = true

        let content = NSStackView(views: [icons, messageField])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 16
        content.frame = NSRect(origin: .zero, size: content.fittingSize)
        return content
    }

    private func removeDefaultIconLayout(from alert: NSAlert) {
        alert.layout()
        guard let contentView = alert.window.contentView,
              let iconView = contentView.subviews.first(where: { $0 is NSImageView }) else { return }
        let remainingViews = contentView.subviews.filter { $0 !== iconView }
        let frames = remainingViews.map { ($0, $0.frame) }
        let contentWidth = contentView.frame.width
        let contentHeight = (remainingViews.map(\.frame.maxY).max() ?? contentView.frame.height) + 20
        iconView.removeFromSuperview()
        alert.window.setContentSize(NSSize(width: contentWidth, height: contentHeight))
        // Resizing an NSAlert moves its labels because they are top anchored.
        // Restore the original frames so the title, message and accessory keep
        // their standard spacing, with only the icon row removed.
        for (view, frame) in frames { view.frame = frame }
    }

    private func showApprovalAlert(_ alert: NSAlert, completion: @escaping (Bool) -> Void) {
        removeDefaultIconLayout(from: alert)
        let action = ApprovalAlertAction { [weak self, weak alert] allowed in
            guard let self, let alert, self.approvalAlert === alert else { return }
            if let parent = alert.window.sheetParent {
                parent.endSheet(alert.window)
            } else {
                alert.window.orderOut(nil)
            }
            self.approvalAlert = nil
            self.approvalAlertAction = nil
            completion(allowed)
        }
        approvalAlert = alert
        approvalAlertAction = action
        // Allow is the default (Return) button; Escape always denies.
        alert.buttons[0].target = action
        alert.buttons[0].action = #selector(ApprovalAlertAction.allow)
        alert.buttons[1].target = action
        alert.buttons[1].action = #selector(ApprovalAlertAction.deny)
        alert.buttons[1].keyEquivalent = "\u{1b}"

        if let window = NSApp.windows.first(where: {
            $0.title == "BrowSync" && $0.isVisible && $0.attachedSheet == nil
        }) {
            window.beginSheet(alert.window)
        } else {
            alert.window.level = .normal
            alert.window.orderFront(nil)
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func requestOriginApproval(_ origin: String, session: UUID,
                                       connectedHosts: [(clientPort: UInt16, bundleID: String?)] = []) {
        guard !listeners.isEmpty, connectionPolicy.isOriginPending(origin, session: session) else { return }
        originApprovalHosts[origin] = connectedHosts
        originApprovalQueue.append(origin)
        presentNextOriginApproval()
    }

    /// The one registered browser of `origin`'s engine with an open, not yet
    /// registered connection while that origin's handshake was pending; nil
    /// when none or several match.
    private func originHost(_ origin: String, registry: [Browser]) -> Browser? {
        let registeredPorts = Set(clients.values.compactMap { client -> UInt16? in
            guard case .hostPort(_, let port) = client.connection.endpoint else { return nil }
            return port.rawValue
        })
        let gecko = origin.hasPrefix("moz-extension://")
        let pending = (originApprovalHosts[origin] ?? []).filter { !registeredPorts.contains($0.clientPort) }
        // Any unresolved connection could be the requester itself.
        guard !pending.isEmpty, pending.allSatisfy({ $0.bundleID != nil }) else { return nil }
        let bundleIDs = pending.compactMap(\.bundleID)
        // An unregistered app of the same engine could be the requester.
        let unknownSameEngine = bundleIDs.contains { bundleID in
            Browser.owner(ofBundleID: bundleID, in: registry) == nil &&
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                    .map { Browser.isBrowserApp(at: $0, gecko: gecko) } == true
        }
        let hosts = Set(bundleIDs.compactMap { Browser.owner(ofBundleID: $0, in: registry) }
            .filter { $0 != .safari && $0.usesFirefoxExtension == gecko })
        // A denied browser is not offered: allowing would only approve the Origin.
        guard !unknownSameEngine, hosts.count == 1, let host = hosts.first,
              !connectionPolicy.deniedBrowserIDs.contains(host.id) else { return nil }
        return host
    }

    private func presentNextOriginApproval() {
        guard approvalAlert == nil, !originApprovalQueue.isEmpty else {
            if originApprovalQueue.isEmpty { presentNextBrowserApproval() }
            return
        }
        let origin = originApprovalQueue.removeFirst()
        let bundle = LanguageBundle(language: AppState.shared.settingsService.general.language).bundle
        let registry = Browser.registeredBrowsers(including: AppState.shared.settingsService.general.customBrowsers)
        let isGecko = origin.hasPrefix("moz-extension://")
        // An extension Origin names no host app (a Gecko origin is a profile
        // UUID); the connection's owner does. Without it, Firefox is assumed
        // only when no other Gecko browser is installed.
        let verifiedHost = originHost(origin, registry: registry)
        originApprovalHosts.removeValue(forKey: origin)
        // Without a verified host (the connection table may only list our own
        // sockets), the only running browser of the origin's engine is named.
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let sameEngine = Browser.runningBrowsers(in: registry, runningBundleIDs: running).filter {
            $0 != .safari && $0.usesFirefoxExtension == isGecko && !connectionPolicy.deniedBrowserIDs.contains($0.id)
        }
        let browser: Browser? = verifiedHost ?? (sameEngine.count == 1 ? sameEngine.first : nil)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = browser.map {
            String(format: String(localized: "BrowSync: Allow %@ to Connect?", bundle: bundle), $0.displayName)
        } ?? (isGecko
            ? String(localized: "BrowSync: Allow a Firefox-based Browser to Connect?", bundle: bundle)
            : String(localized: "BrowSync: Allow a Chromium-based Browser to Connect?", bundle: bundle))
        let message = String(localized: "Only allow this request if you just enabled BrowSync in your browser. The extension can use your enabled sync features. Your choice is remembered on this Mac for future connections.", bundle: bundle)
        alert.informativeText = ""
        alert.accessoryView = approvalContent(for: browser, message: message)
        alert.addButton(withTitle: String(localized: "Allow Connection", bundle: bundle))
        alert.addButton(withTitle: String(localized: "Don't Allow", bundle: bundle))
        let generation = approvalGeneration
        showApprovalAlert(alert) { [weak self] allowed in
            guard let self, self.approvalGeneration == generation else { return }
            self.connectionPolicy.resolveOrigin(origin, allow: allowed)
            if allowed, let browser {
                // The prompt named this browser: that is its consent too, so
                // pairing does not ask a second time.
                self.connectionPolicy.approveBrowserAfterConsent(browser.id)
                self.deniedBrowserIDs = self.connectionPolicy.deniedBrowserIDs
            }
            if allowed, browser == nil, isGecko { self.geckoOriginConsentAt = Date() }
            self.deniedExtensionOrigins = self.connectionPolicy.deniedOrigins
            self.presentNextOriginApproval()
        }
    }

    private func requestBrowserApproval(_ browser: Browser, session: UUID) {
        guard activeApprovalSession == session,
              connectionPolicy.isBrowserPending(browser.id, session: session) else { return }
        browserApprovalQueue.append(browser)
        presentNextBrowserApproval()
    }

    private func presentNextBrowserApproval() {
        guard approvalAlert == nil, originApprovalQueue.isEmpty,
              let session = activeApprovalSession else { return }
        while let browser = browserApprovalQueue.first,
              !connectionPolicy.isBrowserPending(browser.id, session: session) {
            browserApprovalQueue.removeFirst()
        }
        guard !browserApprovalQueue.isEmpty else { return }
        let browser = browserApprovalQueue.removeFirst()
        let bundle = LanguageBundle(language: AppState.shared.settingsService.general.language).bundle
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: String(localized: "BrowSync: Allow %@ to Connect?", bundle: bundle), browser.displayName)
        let message = String(localized: "Only allow this request if you just enabled BrowSync in your browser. The extension can use your enabled sync features. Your choice is remembered on this Mac for future connections.", bundle: bundle)
        alert.informativeText = ""
        alert.accessoryView = approvalContent(for: browser, message: message)
        alert.addButton(withTitle: String(localized: "Allow Connection", bundle: bundle))
        alert.addButton(withTitle: String(localized: "Don't Allow", bundle: bundle))
        let generation = approvalGeneration
        showApprovalAlert(alert) { [weak self] allowed in
            guard let self, self.approvalGeneration == generation else { return }
            self.connectionPolicy.resolveBrowser(browser.id, allow: allowed)
            self.deniedBrowserIDs = self.connectionPolicy.deniedBrowserIDs
            self.presentNextOriginApproval()
        }
    }

    private func cancelApprovalDialogs() {
        approvalGeneration = UUID()
        pairingUnderReview = nil
        geckoOriginConsentAt = nil
        originApprovalHosts.removeAll()
        originApprovalQueue.removeAll()
        browserApprovalQueue.removeAll()
        connectionPolicy.cancelPendingApprovals()
        if let alert = approvalAlert {
            if let parent = alert.window.sheetParent {
                parent.endSheet(alert.window, returnCode: .abort)
            } else {
                NSApp.abortModal()
                alert.window.orderOut(nil)
            }
        }
        approvalAlert = nil
        approvalAlertAction = nil
    }

    func resetExtensionApprovals() {
        stop()
        connectionPolicy.reset()
        hostPairings.removeAll()
        unmatchedExtensionReports.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.pairingDefaultsKey)
        deniedBrowserIDs = []
        deniedExtensionOrigins = []
        start()
    }

    func reviewDeniedBrowser(_ browser: Browser) {
        guard let session = activeApprovalSession,
              connectionPolicy.retryDeniedBrowser(browser.id, session: session) else { return }
        deniedBrowserIDs = connectionPolicy.deniedBrowserIDs
        requestBrowserApproval(browser, session: session)
    }

    func reviewDeniedOrigin(_ origin: String) {
        guard let session = activeApprovalSession,
              connectionPolicy.retryDeniedOrigin(origin, session: session) else { return }
        deniedExtensionOrigins = connectionPolicy.deniedOrigins
        requestOriginApproval(origin, session: session)
    }

    // MARK: - New Connection

    private func handleNewConnection(_ connection: NWConnection) {
        // Bound idle/half-open connections, including rejected handshakes.
        guard pendingConnections.count < 32 else { connection.cancel(); return }
        let key = ObjectIdentifier(connection)
        pendingConnections[key] = connection
        pendingSince[key] = Date()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    self.logger.debug("WebSocket connection ready — awaiting register message")
                    self.receiveNextMessage(on: connection)
                case .failed(let error):
                    self.logger.warning("Connection failed: \(error)")
                    self.removeConnection(connection)
                case .cancelled:
                    self.removeConnection(connection)
                default:
                    break
                }
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
    }

    // MARK: - WebSocket Receive

    private func receiveNextMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.logger.warning("Receive error: \(error)")
                    self.removeConnection(connection)
                    return
                }

                // Verify this is a WebSocket data message
                if let context,
                   let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                    switch metadata.opcode {
                    case .text, .binary:
                        if let data, !data.isEmpty {
                            self.processMessageData(data, from: connection)
                        }
                    case .close:
                        self.removeConnection(connection)
                        return
                    default:
                        break
                    }
                }

                let key = ObjectIdentifier(connection)
                guard self.pendingConnections[key] != nil || self.clients.values.contains(where: { $0.connection === connection }) else { return }
                self.receiveNextMessage(on: connection)
            }
        }
    }

    /// Coding paths can contain user data (e.g. storage keys inside a raw
    /// payload), so only the kind of failure and the path depth are recorded.
    private static func decodingErrorSummary(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return String(describing: type(of: error)) }
        switch error {
        case .keyNotFound(_, let context): return "keyNotFound (depth \(context.codingPath.count))"
        case .typeMismatch(_, let context): return "typeMismatch (depth \(context.codingPath.count))"
        case .valueNotFound(_, let context): return "valueNotFound (depth \(context.codingPath.count))"
        case .dataCorrupted(let context): return "dataCorrupted (depth \(context.codingPath.count))"
        @unknown default: return "unknown decoding error"
        }
    }

    private func processMessageData(_ data: Data, from connection: NWConnection) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())
        let logFile = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/BrowSync/logs/sync-\(dateString).log")
        do {
            let message = try JSONDecoder().decode(WSMessage.self, from: data)
            routeMessage(message, from: connection)
        } catch {
            logger.warning("Failed to decode WebSocket message: \(Self.decodingErrorSummary(error))")
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                // Payloads carry bookmarks, cookies and storage. Persist only the
                // envelope fields needed to identify the sender, never the body.
                let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let field = { (key: String) in (envelope?[key] as? String).map { String($0.prefix(64)) } ?? "?" }
                let errStr = "[DECODE ERROR] \(Self.decodingErrorSummary(error))\nMESSAGE: type=\(field("type")) browser=\(field("browser")) category=\(field("category")) bytes=\(data.count)\n"
                handle.write(errStr.data(using: .utf8)!)
                try? handle.close()
            }
            // Try stripping trailing newline/whitespace
            if let trimmed = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .data(using: .utf8),
               let message = try? JSONDecoder().decode(WSMessage.self, from: trimmed) {
                routeMessage(message, from: connection)
            }
        }
    }

    // MARK: - Message Routing

    private func routeMessage(_ message: WSMessage, from connection: NWConnection) {
        let connKey = ObjectIdentifier(connection)

        // The handshake already requires an approved extension Origin. Do not
        // dispatch anything until that connection has registered, either.
        let registered = clients.values.contains { $0.connection === connection }
        guard message.type == .register || registered else {
            removeConnection(connection)
            return
        }
        if message.type == .register && registered {
            removeConnection(connection)
            return
        }

        switch message.type {
        case .register:
            handleRegister(message, connection: connection)

        case .ack:
            break

        case .heartbeat:
            for (_, client) in clients where ObjectIdentifier(client.connection) == connKey {
                client.lastSeen = Date()
                logger.debug("Heartbeat from \(client.id)")
            }
            
        case .sync:
            guard let client = clients.values.first(where: {
                ObjectIdentifier($0.connection) == connKey
            }) else { return }
            client.lastSeen = Date()

            // An old Gecko build in another browser labels its data "firefox";
            // state sync attributes data by this field.
            var received = message
            if client.presentsAsFirefox { received.browser = client.browser.id }
            delegate?.daemonServer(self, didReceiveSync: received, from: client.id)

            // Send ack
            if let msgId = message.messageId {
                sendWSMessage(WSMessage.ack(messageId: msgId), to: client)
            }

        case .pull:
            guard let client = clients.values.first(where: {
                ObjectIdentifier($0.connection) == connKey
            }) else { return }
            client.lastSeen = Date()

            // Reject delayed extension navigation pulls while State Sync is
            // off. Otherwise an old worker can repopulate a tab from cached
            // cookies even after the app-side master switch was disabled.
            if message.category == "browserData",
               !AppState.shared.settingsService.syncSettings.enabledCategories.contains(.browserData) {
                logger.debug("Ignored browser-data pull from \(client.id) because State Sync is disabled")
                return
            }
            
            // For bookmarks, always serve fresh state (not stale cache)
            if message.category == nil || message.category == "bookmarks" {
                delegate?.daemonServer(self, didReceivePullBookmarks: client.id)
            }
            
            if message.category == "tabSharing" {
                // Broadcast a sync pull request to all other participating browsers locally
                let requestMessage = WSMessage(
                    type: .sync,
                    category: "tabSharing",
                    payload: nil,
                    messageId: UUID().uuidString,
                    timestamp: Date().timeIntervalSince1970
                )
                broadcast(requestMessage, excluding: client.id)
                
                // ALSO send the currently cached tabs (including iCloud remote tabs) to the requester
                let isProUnlocked = AppState.shared.purchaseService.isProUnlocked
                for (browser, tabs) in AppState.shared.remoteTabsCache {
                    let purelyLocalTabs = tabs.filter { !$0.id.hasPrefix("icloud_") }
                    let icloudTabs = tabs.filter { $0.id.hasPrefix("icloud_") }
                    let localTabsToSend = ProLimits.limitedTabsForSharing(purelyLocalTabs, isProUnlocked: isProUnlocked)
                    
                    if browser != client.browser && !localTabsToSend.isEmpty {
                        let cacheMessage = WSMessage(
                            type: .sync,
                            browser: browser.rawValue,
                            category: "tabSharing",
                            payload: .tabs(localTabsToSend),
                            messageId: UUID().uuidString,
                            timestamp: Date().timeIntervalSince1970
                        )
                        send(cacheMessage, toClientId: client.id)
                    }
                    
                    let grouped = Dictionary(grouping: icloudTabs) { tab -> String in
                        let parts = tab.id.components(separatedBy: "_")
                        if parts.count >= 3 { return parts[1] }
                        return "unknown"
                    }
                    
                    for (device, deviceTabs) in grouped {
                        let deviceTabsToSend = ProLimits.limitedTabsForSharing(deviceTabs, isProUnlocked: isProUnlocked)
                        guard !deviceTabsToSend.isEmpty else { continue }

                        // Use a composite browser ID to prevent Chrome extension from dropping tabs that match its own browser ID,
                        // and to prevent overwriting tabs from multiple devices.
                        let sendBrowserId = "\(browser.rawValue)_\(device)"
                        
                        let cacheMessage = WSMessage(
                            type: .sync,
                            browser: sendBrowserId,
                            category: "tabSharing",
                            payload: .tabs(deviceTabsToSend),
                            messageId: UUID().uuidString,
                            timestamp: Date().timeIntervalSince1970
                        )
                        send(cacheMessage, toClientId: client.id)
                    }
                }
                return
            }
            
            if message.category == "browserData" && message.site != nil {
                AppState.shared.syncService.prepareSilentBrowserDataPull(to: client.id, site: message.site)

                let requestMessage = WSMessage.pull(site: message.site, category: "browserData")
                broadcast(requestMessage, excluding: client.id)
            }
            
            if message.category != "bookmarks" {
                let categoriesToPull: [String]
                if message.category == "browserData" {
                    categoriesToPull = ["cookies", "localStorage", "sessionStorage"]
                } else if let cat = message.category {
                    categoriesToPull = [cat]
                } else {
                    categoriesToPull = []
                }
                
                var payloads: [Data] = []
                if categoriesToPull.isEmpty {
                    payloads = GlobalStateStore.shared.pull(site: message.site, category: nil)
                } else {
                    for cat in categoriesToPull {
                        payloads.append(contentsOf: GlobalStateStore.shared.pull(site: message.site, category: cat))
                    }
                }
                
                for payloadData in payloads {
                    // Strip tombstones before sending cached cookie state.
                    // Tombstones in GlobalState are stale remnants from previous syncs.
                    // Sending them here bypasses filterCookies/acceptLatestCookie entirely,
                    // causing silent cookie deletions with no log. Only send live cookies.
                    if let msg = try? JSONDecoder().decode(WSMessage.self, from: payloadData),
                       msg.category == "cookies",
                       case .cookies(let cookies) = msg.payload {
                        let liveOnly = cookies.filter { $0.removed != true }
                        if liveOnly.isEmpty { continue }
                        if liveOnly.count < cookies.count {
                            // Had tombstones — rebuild message without them
                            var cleaned = msg
                            cleaned.payload = .cookies(liveOnly)
                            if let cleanData = try? JSONEncoder().encode(cleaned) {
                                sendData(cleanData, on: client.connection)
                            }
                        } else {
                            sendData(payloadData, on: client.connection)
                        }
                    } else {
                        sendData(payloadData, on: client.connection)
                    }
                }
            }

        case .settings:
            guard let client = clients.values.first(where: {
                ObjectIdentifier($0.connection) == connKey
            }) else { return }
            client.lastSeen = Date()
            delegate?.daemonServer(self, didReceiveSettings: message, from: client.id)
            
        case .openSettings:
            guard let client = clients.values.first(where: {
                ObjectIdentifier($0.connection) == connKey
            }) else { return }
            client.lastSeen = Date()
            delegate?.daemonServer(self, didReceiveOpenSettingsFrom: client.id)

        case .openURL:
            guard let client = clients.values.first(where: {
                ObjectIdentifier($0.connection) == connKey
            }) else { return }
            client.lastSeen = Date()
            delegate?.daemonServer(self, didReceiveOpenURL: message, from: client.id)

        case .disconnect:
            removeConnection(connection)
            
        case .error:
            break
        }
    }

    // MARK: - Register

    private func savePairing(_ bundleID: String, key: String) {
        unmatchedExtensionReports.removeValue(forKey: key)
        hostPairings[key] = bundleID
        UserDefaults.standard.set(hostPairings, forKey: Self.pairingDefaultsKey)
    }

    var deniedPairingKeys: [String] {
        hostPairings.compactMap { $0.value == Self.deniedPairing ? $0.key : nil }.sorted()
    }

    func retryDeniedPairing(_ key: String) {
        guard hostPairings[key] == Self.deniedPairing else { return }
        // The worker's next registration still needs explicit host consent.
        savePairing(Self.explicitPairing, key: key)
    }

    /// Other installations (profiles, or the extension before a reinstall)
    /// paired with the same host app. Only one may own a browser ID: two trees
    /// under one ID would read as mass edits against the other's baseline.
    private func otherPairings(of bundleID: String, except key: String) -> [String] {
        hostPairings.filter { $0.key != key && $0.value == bundleID }.map(\.key).sorted()
    }

    /// Hands the browser to `key`: every other installation paired with the
    /// same host is denied (reauthorizable in Settings) and disconnected.
    private func pairExclusively(_ host: Browser, key: String) {
        let bundleID = host.bundleIdentifier
        let replaced = otherPairings(of: bundleID, except: key)
        for other in replaced {
            hostPairings[other] = Self.deniedPairing
            let otherID = other.split(separator: ".").last.map(String.init)
            for client in clients.values where client.installationID?.uuidString == otherID {
                removeConnection(client.connection)
            }
        }
        savePairing(bundleID, key: key)
        // Before the new installation's first snapshot arrives.
        if !replaced.isEmpty { delegate?.daemonServer(self, didReplaceInstallationOf: host) }
        // Legacy extensions reported every Gecko host as "firefox". With no
        // Firefox channel on this Mac, observations stored under that ID came
        // from a fork (e.g. LibreWolf) and must not become Firefox's baseline.
        if host.usesFirefoxExtension, host != .firefox, Browser.firefox.appURL == nil {
            delegate?.daemonServer(self, didFindForeignObservationsOf: .firefox)
        }
    }

    private func chooseHost(for key: String, candidates: [Browser], session: UUID, unknownApps: [String] = []) {
        // The worker retries registration. Only one consent UI may be active.
        guard approvalAlert == nil, originApprovalQueue.isEmpty, browserApprovalQueue.isEmpty else { return }
        let bundle = LanguageBundle(language: AppState.shared.settingsService.general.language).bundle
        let alert = NSAlert()
        let uniqueHost = candidates.count == 1 ? candidates[0] : nil
        let title = String(localized: "Choose the browser where you enabled BrowSync", bundle: bundle)
        alert.messageText = uniqueHost.map {
            String(format: String(localized: "BrowSync: Allow %@ to Connect?", bundle: bundle), $0.displayName)
        } ?? title
        alert.informativeText = String(localized: "Only allow this request if you just enabled BrowSync in your browser. The extension can use your enabled sync features. Your choice is remembered on this Mac for future connections.", bundle: bundle)
        if candidates.contains(where: { !otherPairings(of: $0.bundleIdentifier, except: key).isEmpty }) {
            alert.informativeText += "\n\n" + String(localized: "If this browser already has another paired BrowSync installation (another profile, or the extension before it was reinstalled), allowing this one replaces it. The other installation stops syncing until you reauthorize it in Settings.", bundle: bundle)
        }
        if !unknownApps.isEmpty {
            alert.informativeText += "\n\n" + String(format: String(localized: "%@ is also running, but BrowSync does not know it as a browser. If you enabled BrowSync there, choose Don't Allow, add it in the Browsers tab, then reauthorize the extension in Settings.", bundle: bundle),
                                                       ListFormatter.localizedString(byJoining: unknownApps))
        }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        picker.autoenablesItems = false
        picker.addItem(withTitle: title)
        let denied = Set(connectionPolicy.deniedBrowserIDs)
        for browser in candidates {
            // Bundle IDs also disambiguate two installations with the same name.
            let item = NSMenuItem(title: "\(browser.displayName) (\(browser.bundleIdentifier))", action: nil, keyEquivalent: "")
            // Shown so the user can recognize the host, but a denied browser
            // must be reauthorized in Settings before it can be chosen.
            item.isEnabled = !denied.contains(browser.id)
            picker.menu?.addItem(item)
        }
        alert.accessoryView = uniqueHost == nil ? picker : approvalContent(for: uniqueHost, message: alert.informativeText)
        if uniqueHost != nil { alert.informativeText = "" }
        let allow = alert.addButton(withTitle: String(localized: "Allow Connection", bundle: bundle))
        alert.addButton(withTitle: String(localized: "Don't Allow", bundle: bundle))
        allow.isEnabled = uniqueHost != nil
        let pickerAction = HostPickerAction(allow)
        picker.target = pickerAction
        picker.action = #selector(HostPickerAction.selected(_:))
        pairingUnderReview = key
        showApprovalAlert(alert) { [weak self, pickerAction] allowed in
            guard let self, self.activeApprovalSession == session else { return }
            self.pairingUnderReview = nil
            defer { self.presentNextOriginApproval() }
            guard allowed else {
                self.savePairing(Self.deniedPairing, key: key)
                return
            }
            guard pickerAction.allowButton.isEnabled else { return }
            let index = uniqueHost == nil ? picker.indexOfSelectedItem - 1 : 0
            guard candidates.indices.contains(index) else { return }
            let selected = candidates[index]
            let registry = Browser.registeredBrowsers(including: AppState.shared.settingsService.general.customBrowsers)
            let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            guard Browser.runningBrowsers(in: registry, runningBundleIDs: running).contains(selected) else { return }
            switch self.connectionPolicy.evaluateBrowser(selected.id, session: session) {
            case .requestApproval:
                self.connectionPolicy.resolveBrowser(selected.id, allow: true)
            case .allow: break
            case .reject: return
            }
            self.pairExclusively(selected, key: key)
        }
    }

    /// Observations an earlier app stored for `host` under another browser's
    /// ID are discarded once; that browser then rejoins like a new participant
    /// (only narrowing sync authority). Once per (host, legacy ID), so the same
    /// evidence seen again later — a legacy build updating its extension —
    /// never wipes data stored since.
    private func forgetMisfiledObservations(of legacyID: String, host: Browser, registry: [Browser]) {
        guard legacyID != host.id, let legacy = registry.first(where: { $0.id == legacyID }), legacy != .safari,
              markLegacyIdentityResolved(legacyID, host: host) else { return }
        logger.info("Observations stored as \(legacyID, privacy: .public) came from \(host.id, privacy: .public); discarding them once")
        if legacy.isInstalledApp {
            delegate?.daemonServer(self, didReplaceInstallationOf: legacy)
        } else {
            delegate?.daemonServer(self, didFindForeignObservationsOf: legacy)
        }
    }

    @discardableResult
    private func markLegacyIdentityResolved(_ legacyID: String, host: Browser) -> Bool {
        guard resolvedLegacyIdentities.insert("\(host.bundleIdentifier)>\(legacyID)").inserted else { return false }
        UserDefaults.standard.set(resolvedLegacyIdentities.sorted(), forKey: Self.resolvedLegacyIdentitiesKey)
        return true
    }

    private func connectionHostBundleID(_ connection: NWConnection) -> String? {
        guard case .hostPort(_, let port) = connection.endpoint else { return nil }
        return LoopbackPeer.hostBundleID(clientPort: port.rawValue, serverPort: Self.port)
    }

    private static func appDisplayName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        let bundle = Bundle(url: url)
        return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func unregisteredRunningBrowserApps(gecko: Bool, registry: [Browser]) -> [String] {
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> (bundleID: String, url: URL, name: String)? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, let url = app.bundleURL else { return nil }
            return (id, url, app.localizedName ?? url.deletingPathExtension().lastPathComponent)
        }
        return Browser.unregisteredRunningBrowserApps(gecko: gecko, registry: registry, running: running)
    }

    private func handleRegister(_ message: WSMessage, connection: NWConnection) {
        guard pendingConnections[ObjectIdentifier(connection)] != nil,
              let browserRaw = message.browser, let originalInstanceId = message.instanceId,
              !originalInstanceId.isEmpty, originalInstanceId.utf8.count <= 256 else {
            logger.warning("Invalid register message")
            removeConnection(connection)
            return
        }
        
        var realBrowserId = browserRaw
        
        // Chromium-derived browsers may expose an indistinguishable Chrome UA
        // to an extension service worker. Resolve that fallback against the
        // complete browser registry, not a hand-picked subset of browsers.
        let reportsGeckoProduct = message.capabilities?.contains("geckoProductIdentity") == true
        // The product a Gecko build names (LibreWolf, Zen…); `browser` stays
        // "firefox" for older apps.
        let reportedProduct = reportsGeckoProduct ? (message.browserProduct ?? browserRaw) : browserRaw
        let pairingKey = message.installationID.map { (reportsGeckoProduct ? "gecko." : "chromium.") + $0.uuidString }
        if let pairingKey, [nil, Self.explicitPairing].contains(hostPairings[pairingKey]), approvalAlert == nil {
            // A fork can be installed and launched after the last settings scan.
            // The worker retries every few seconds; do not rescan on each try.
            Browser.refreshDiscovery(minimumInterval: 10)
        }
        let allBrowsers = Browser.registeredBrowsers(including: AppState.shared.settingsService.general.customBrowsers)
        // The kernel names the app that opened this socket. When it is known it
        // decides the host, whatever the extension reports: an embedded
        // Chromium (e.g. an app's built-in browser) also says "chrome".
        let usesGeckoTransport = reportsGeckoProduct || (pairingKey == nil && browserRaw == "firefox")
        var verifiedHostBundleID = connectionHostBundleID(connection)
        if browserRaw == "safari", verifiedHostBundleID?.hasPrefix("com.apple.Safari") == true {
            // Safari (and Technology Preview) keep their own extension path.
            verifiedHostBundleID = nil
        }
        let verifiedHost = verifiedHostBundleID.flatMap { Browser.owner(ofBundleID: $0, in: allBrowsers) }
        var legacyGeckoAsFirefox = false
        if let bundleID = verifiedHostBundleID {
            let reportKey = pairingKey ?? "legacy.\(bundleID)"
            // Old Gecko builds ignore the assigned ID and keep enforcing
            // Firefox's settings, so they may only run as Firefox. Where no
            // Firefox is installed they keep the "firefox" identity they had
            // with earlier apps (both sides then agree on it); with Firefox
            // installed that would mix two browsers' trees under one ID.
            // With Firefox installed the build runs as its real host and is
            // sent that host's settings under "firefox" (see presentsAsFirefox).
            legacyGeckoAsFirefox = pairingKey == nil && usesGeckoTransport && verifiedHost != .firefox &&
                verifiedHost?.usesFirefoxExtension == true && Browser.firefox.appURL == nil
            guard let host = verifiedHost, host != .safari, host.usesFirefoxExtension == usesGeckoTransport else {
                // Not a registered browser of this extension's engine: never
                // attribute its bookmarks to another browser.
                if verifiedHost == nil, hostPairings[reportKey] == nil || pairingKey == nil {
                    unmatchedExtensionReports[reportKey] = Self.appDisplayName(bundleID)
                }
                if unmatchedPairingsLogged.insert(reportKey).inserted {
                    logger.warning("Refused an extension connection from \(bundleID, privacy: .public): not a registered browser for this extension build")
                }
                removeConnection(connection)
                return
            }
            unmatchedExtensionReports.removeValue(forKey: "legacy.\(bundleID)")
        }
        if let pairingKey {
            guard let session = activeApprovalSession, pairingUnderReview != pairingKey else {
                removeConnection(connection)
                return
            }
            let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            // Denied browsers still count as candidates: dropping them could make
            // an ambiguous registration look like it belongs to another browser.
            let candidates = verifiedHost.map { [$0] } ?? Browser.runningBrowsers(in: allBrowsers, runningBundleIDs: running).filter { browser in
                browser != .safari && browser.usesFirefoxExtension == reportsGeckoProduct
            }
            if let verifiedHost, let saved = hostPairings[pairingKey], saved != Self.deniedPairing,
               saved != Self.explicitPairing, saved != verifiedHost.bundleIdentifier {
                // Paired by inference before the host could be verified, and
                // to the wrong app. Show it as denied; reauthorizing asks again.
                logger.warning("Extension installation paired with \(saved, privacy: .public) runs in \(verifiedHost.bundleIdentifier, privacy: .public); pairing revoked")
                savePairing(Self.deniedPairing, key: pairingKey)
                removeConnection(connection)
                return
            }
            let stored = hostPairings[pairingKey]
            if let stored, stored != Self.deniedPairing, stored != Self.explicitPairing,
               !allBrowsers.contains(where: { $0.bundleIdentifier == stored }) {
                // The paired host is running (this installation is connecting)
                // but no longer registered, e.g. its custom entry was removed.
                // Show it as denied so the user can reauthorize with a prompt;
                // forgetting it would let it bind silently to another browser.
                savePairing(Self.deniedPairing, key: pairingKey)
                removeConnection(connection)
                return
            }
            let mustConfirm = stored == Self.explicitPairing
            let savedBundleID = mustConfirm ? nil : stored
            // A verified host is the answer; the reported product cannot veto it.
            switch Browser.pairingDecision(candidates: candidates, reportedID: verifiedHost?.id ?? reportedProduct, savedBundleID: savedBundleID,
                                           trustsReportedID: reportsGeckoProduct || verifiedHost != nil) {
            case .host(let host):
                if savedBundleID == nil {
                    let unknownApps = verifiedHost != nil ? [] : unregisteredRunningBrowserApps(gecko: reportsGeckoProduct, registry: allBrowsers)
                    // Existing installs approved this browser before pairing
                    // existed; an unambiguous host keeps that consent instead
                    // of asking again after the extension update. Replacing
                    // another installation of this browser, or a pairing the
                    // user reauthorized, always needs an explicit prompt.
                    // An unregistered browser of the same engine might be the
                    // real host of a generic report: never infer consent then.
                    let mayInferConsent = !mustConfirm && unknownApps.isEmpty &&
                        otherPairings(of: host.bundleIdentifier, except: pairingKey).isEmpty
                    let consentedByOrigin = mayInferConsent && reportsGeckoProduct &&
                        geckoOriginConsentAt.map { Date().timeIntervalSince($0) < 120 } == true &&
                        connectionPolicy.approveBrowserAfterConsent(host.id)
                    if consentedByOrigin { geckoOriginConsentAt = nil }
                    guard consentedByOrigin || (mayInferConsent && connectionPolicy.isBrowserApproved(host.id)) else {
                        if !connectionPolicy.deniedBrowserIDs.contains(host.id) {
                            chooseHost(for: pairingKey, candidates: [host], session: session, unknownApps: unknownApps)
                        }
                        removeConnection(connection)
                        return
                    }
                    pairExclusively(host, key: pairingKey)
                }
                realBrowserId = host.id
            case .choose:
                if candidates.contains(where: { !connectionPolicy.deniedBrowserIDs.contains($0.id) }) {
                    chooseHost(for: pairingKey, candidates: candidates, session: session,
                               unknownApps: unregisteredRunningBrowserApps(gecko: reportsGeckoProduct, registry: allBrowsers))
                }
                removeConnection(connection)
                return
            case .unavailable:
                if savedBundleID == nil {
                    // Shown in Settings so the user can add the browser.
                    unmatchedExtensionReports[pairingKey] = reportedProduct
                }
                // The worker retries for as long as it runs; log once per installation.
                if unmatchedPairingsLogged.insert(pairingKey).inserted {
                    logger.warning("No running registered browser matches an extension installation reporting \(reportedProduct, privacy: .public) (\(candidates.count) candidates)")
                }
                removeConnection(connection)
                return
            }
        } else if let verifiedHost {
            // A legacy build (no installation ID) in a verified host.
            realBrowserId = legacyGeckoAsFirefox ? Browser.firefox.id : verifiedHost.id
        } else if realBrowserId == "firefox" {
            // A legacy Gecko build (no installation ID, always "firefox") whose
            // host could not be verified. With exactly one Gecko browser
            // running it must be that one; it then runs as that browser (and
            // is sent that browser's settings under "firefox"), or keeps the
            // "firefox" identity it had with earlier apps where Firefox is not
            // installed. Otherwise earlier apps' behavior is kept: Firefox.
            let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            let gecko = Browser.runningBrowsers(in: allBrowsers, runningBundleIDs: running).filter(\.usesFirefoxExtension)
            if gecko.count == 1, let host = gecko.first, host != .firefox, Browser.firefox.appURL != nil {
                realBrowserId = host.id
                logger.info("Legacy Gecko extension runs in the only running Gecko browser, \(host.id, privacy: .public)")
            }
        } else if realBrowserId == "chrome", !reportsGeckoProduct {
            // A legacy Chromium build whose host could not be verified: the
            // inference earlier apps used, so no existing setup stops working.
            let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            let runningChromiumBrowsers = Browser.runningBrowsers(in: allBrowsers, runningBundleIDs: running).filter { browser in
                // Safari and Firefox have their own extension transports. Every
                // other registered browser (including custom ones) is eligible
                // for the shared Chromium extension transport.
                !browser.usesFirefoxExtension && browser != .safari
            }
            let unconnectedCandidates = runningChromiumBrowsers.filter { !connectedBrowsers.contains($0) }
            if runningChromiumBrowsers.count == 1 {
                realBrowserId = runningChromiumBrowsers[0].id
            } else if unconnectedCandidates.count == 1 {
                realBrowserId = unconnectedCandidates[0].id
            }
        }
        guard let browser = allBrowsers.first(where: { $0.id == realBrowserId }),
              !reportsGeckoProduct || browser.usesFirefoxExtension else {
            logger.warning("Unknown browser id: \(realBrowserId)")
            removeConnection(connection)
            return
        }

        if browser != .safari, let session = activeApprovalSession {
            switch connectionPolicy.evaluateBrowser(browser.id, session: session) {
            case .allow:
                break
            case .requestApproval:
                requestBrowserApproval(browser, session: session)
                removeConnection(connection)
                return
            case .reject:
                removeConnection(connection)
                return
            }
        } else if browser != .safari {
            removeConnection(connection)
            return
        }
        
        let instanceId = pairingKey == nil
            ? originalInstanceId.replacingOccurrences(of: browserRaw, with: realBrowserId)
            : "\(realBrowserId)-main"

        // Disconnect existing client with same instanceId (reconnect)
        if let existing = clients[instanceId] {
            // A connection from an extension build that predates installation
            // IDs may be replaced by the updated extension in the same browser.
            guard existing.installationID == nil || existing.installationID == message.installationID else {
                logger.warning("Registration refused: another extension profile owns the active browser connection")
                removeConnection(connection)
                return
            }
            existing.connection.cancel()
            clients.removeValue(forKey: instanceId)
        }

        pendingConnections.removeValue(forKey: ObjectIdentifier(connection))
        pendingSince.removeValue(forKey: ObjectIdentifier(connection))

        if let pairingKey {
            unmatchedExtensionReports.removeValue(forKey: pairingKey)
            unmatchedPairingsLogged.remove(pairingKey)
            // A pre-pairing build of this installation was connected as another
            // browser (old Gecko builds always said "firefox"): what was stored
            // under that ID may be this browser's tree. Discarding it only makes
            // that browser rejoin like a new participant.
            if let legacyID = message.legacyBrowserID {
                forgetMisfiledObservations(of: legacyID, host: browser, registry: allBrowsers)
            }
        } else if usesGeckoTransport, browser != .firefox {
            // From now on this host's data is stored under its own ID. When its
            // extension updates, the "firefox" it then reports comes from the
            // old build's start-up write, not from an app having filed it
            // there, so it must not wipe Firefox. (Without such evidence
            // nothing is discarded: Firefox's unsynced changes stay pending.)
            markLegacyIdentityResolved(Browser.firefox.id, host: browser)
        }
        let client = ConnectedClient(id: instanceId, browser: browser, connection: connection, installationID: message.installationID)
        client.capabilities = Set(message.capabilities ?? [])
        client.presentsAsFirefox = pairingKey == nil && usesGeckoTransport && browser != .firefox
        clients[instanceId] = client
        connectedBrowsers.insert(browser)

        logger.info("✅ Registered: \(instanceId) (\(browser.displayName))")
        // ACK the registration
        if let msgId = message.messageId {
            var ack = WSMessage.ack(messageId: msgId, browserId: realBrowserId)
            // Tells current extensions this app applied installation pairing
            // and the legacy identity; older apps' acks lack it.
            ack.capabilities = ["hostPairing"]
            sendWSMessage(ack, to: client)
        }

        delegate?.daemonServer(self, didConnect: client)

        // The receive loop schedules the next read after routing returns.
    }


    // MARK: - WebSocket Send

    private static let bookmarkMutationCategories: Set<String> = [
        SyncCategory.bookmarks.rawValue,
        SyncService.removalBatchCategory,
        "bookmark_incremental",
        "bookmarks_removed",
        "bookmark_apply_plan"
    ]
    private static let bookmarkPlanningInputCategories = bookmarkMutationCategories.subtracting(["bookmark_apply_plan"])

    /// The app owns the final dispatch boundary for every bookmark mutation,
    /// regardless of which service or compatibility path produced it.
    private func messageForDelivery(_ message: WSMessage, to browser: Browser) -> WSMessage? {
        guard message.type == .sync,
              let category = message.category,
              Self.bookmarkMutationCategories.contains(category),
              message.payload != nil else { return message }
        var secured = message
        let settings = AppState.shared.settingsService.syncSettings
        secured.bookmarkSyncEnabled = settings.enabledCategories.contains(.bookmarks)
        secured.bookmarkSafeMode = settings.bookmarkSafeMode
        let explicitRestore = message.isExplicitDeletedBookmarkRestore == true || message.isExplicitBookmarkRestore == true
        secured.bookmarkWriteAllowed = BookmarkWritePolicy.allowsWrite(to: browser, settings: settings, explicitRestore: explicitRestore)
        secured.bookmarkSyncStrategy = settings.bookmarkSyncStrategy.rawValue
        secured.bookmarkSourceBrowser = settings.bookmarkSourceBrowser.rawValue
        // OFF, non-participation and a one-way source are hard app-side
        // prohibitions. Do not rely on an extension to reject the payload.
        guard secured.bookmarkWriteAllowed == true else {
            logger.warning("Dropped bookmark mutation before dispatch to \(browser.rawValue, privacy: .public): app write policy refused it")
            return nil
        }
        return secured
    }

    private func presented(_ message: WSMessage, to client: ConnectedClient) -> WSMessage {
        client.presentsAsFirefox ? message.presentedAsFirefox(realBrowserID: client.browser.id) : message
    }

    func sendWSMessage(_ message: WSMessage, to client: ConnectedClient) {
        if Self.bookmarkPlanningInputCategories.contains(message.category ?? ""),
           message.payload != nil,
           bookmarkMutationInterceptor?(message, client) == true { return }
        guard let delivered = messageForDelivery(message, to: client.browser).map({ presented($0, to: client) }) else { return }
        guard let data = try? JSONEncoder().encode(delivered) else { return }
        sendData(data, on: client.connection)
    }

    /// Control-plane messages never contain bookmark mutations and therefore
    /// bypass the planning interceptor.
    func sendBookmarkControlMessage(_ message: WSMessage, to client: ConnectedClient) {
        guard let data = try? JSONEncoder().encode(presented(message, to: client)) else { return }
        sendData(data, on: client.connection)
    }

    private func sendData(_ data: Data, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "browsync.message",
            metadata: [metadata]
        )
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.logger.warning("Send error: \(error)")
            }
        })
    }

    func broadcast(_ message: WSMessage, excluding excludedId: String? = nil, participatingBrowsers: Set<Browser>? = nil) {
        for (id, client) in clients {
            if id == excludedId { continue }
            if let participating = participatingBrowsers, !participating.contains(client.browser) { continue }
            if Self.bookmarkPlanningInputCategories.contains(message.category ?? ""),
               message.payload != nil,
               bookmarkMutationInterceptor?(message, client) == true { continue }
            guard let delivered = messageForDelivery(message, to: client.browser).map({ presented($0, to: client) }) else { continue }
            guard let data = try? JSONEncoder().encode(delivered) else { continue }
            sendData(data, on: client.connection)
        }
    }
    
    func send(_ message: WSMessage, toClientId clientId: String) {
        guard let client = clients[clientId] else { return }
        if Self.bookmarkPlanningInputCategories.contains(message.category ?? ""),
           message.payload != nil,
           bookmarkMutationInterceptor?(message, client) == true { return }
        guard let delivered = messageForDelivery(message, to: client.browser).map({ presented($0, to: client) }) else { return }
        guard let data = try? JSONEncoder().encode(delivered) else { return }
        sendData(data, on: client.connection)
    }

    // MARK: - Cleanup

    private func removeConnection(_ connection: NWConnection) {
        connection.cancel()
        pendingConnections.removeValue(forKey: ObjectIdentifier(connection))
        pendingSince.removeValue(forKey: ObjectIdentifier(connection))

        if let (id, client) = clients.first(where: {
            ObjectIdentifier($0.value.connection) == ObjectIdentifier(connection)
        }) {
            clients.removeValue(forKey: id)
            connectedBrowsers = Set(clients.values.map(\.browser))
            delegate?.daemonServer(self, didDisconnect: id, browser: client.browser)
            logger.info("Disconnected: \(id)")
        }
    }

    // MARK: - Heartbeat Monitor

    private func startHeartbeatTimer() {
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: DaemonServer.heartbeatInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.checkHeartbeats() }
        }
    }

    private func checkHeartbeats() {
        let now = Date()
        let expired = pendingSince.filter { now.timeIntervalSince($0.value) > 30 }.map(\.key)
        for key in expired {
            if let connection = pendingConnections[key] { removeConnection(connection) }
        }
        var timedOut: [String] = []
        for (id, client) in clients {
            if now.timeIntervalSince(client.lastSeen) > DaemonServer.heartbeatTimeout {
                logger.info("Client \(id) heartbeat timeout")
                timedOut.append(id)
            }
        }
        for id in timedOut {
            if let client = clients[id] {
                client.connection.cancel()
                clients.removeValue(forKey: id)
                connectedBrowsers = Set(clients.values.map(\.browser))
                delegate?.daemonServer(self, didDisconnect: id, browser: client.browser)
            }
        }
    }

    // MARK: - Accessors

    var connectedClients: [ConnectedClient] { Array(clients.values) }

    func isConnected(browser: Browser) -> Bool {
        clients.values.contains { $0.browser == browser }
    }
}


// MARK: - Global State Store

final class GlobalStateStore {
    static let shared = GlobalStateStore()
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.browsync.globalstore")

    // Key: "\(category)_\(site)", Value: WSMessage data
    private var stateCache: [String: Data] = [:]

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("BrowSync")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.fileURL = appSupport.appendingPathComponent("global_state.json")
        self.load()
    }

    func save(message: WSMessage) {
        queue.async {
            guard let category = message.category, let site = message.site else { return }
            var key = "\(category)_\(site)"
            if category == "bookmarks_removed" {
                if case .bookmarksRemoved(let bm) = message.payload {
                    key = "\(category)_\(bm.id)"
                }
            }
            
            var msgToSave = message
            
            if let existingData = self.stateCache[key],
               let existingMsg = try? JSONDecoder().decode(WSMessage.self, from: existingData),
               let existingPayload = existingMsg.payload,
               let newPayload = message.payload {
                
                var mergedPayload = newPayload
                
                switch (existingPayload, newPayload) {
                case (.cookies(let existingCookies), .cookies(let newCookies)):
                    var dict = [String: SyncCookie]()
                    for c in existingCookies { dict["\(c.name)_\(c.domain)_\(c.path)"] = c }
                    for c in newCookies { dict["\(c.name)_\(c.domain)_\(c.path)"] = c }
                    mergedPayload = .cookies(Array(dict.values))
                    
                case (.localStorage(let existingItems), .localStorage(let newItems)):
                    var dict = [String: StorageItem]()
                    for item in existingItems { dict[item.key] = item }
                    for item in newItems { dict[item.key] = item }
                    mergedPayload = .localStorage(Array(dict.values))
                    
                case (.sessionStorage(let existingItems), .sessionStorage(let newItems)):
                    var dict = [String: StorageItem]()
                    for item in existingItems { dict[item.key] = item }
                    for item in newItems { dict[item.key] = item }
                    mergedPayload = .sessionStorage(Array(dict.values))
                    
                default:
                    break
                }
                msgToSave.payload = mergedPayload
            }

            if let data = try? JSONEncoder().encode(msgToSave) {
                self.stateCache[key] = data
                self.persist()
            }
        }
    }

    func pull(site: String? = nil, category: String? = nil) -> [Data] {
        queue.sync {
            return self.stateCache.compactMap { key, value in
                if let site = site, !key.hasSuffix("_\(site)") { return nil }
                if let cat = category, !key.hasPrefix("\(cat)_") { return nil }
                return value
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(self.stateCache) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let cache = try? JSONDecoder().decode([String: Data].self, from: data) {
            // Drop cached bookmark trees AND bookmarks_removed tombstones.
            // bookmarks_removed are point-in-time events: replaying stale tombstones
            // to a newly connected extension would erroneously wipe its bookmarks.
            self.stateCache = cache.filter { !$0.key.hasPrefix("bookmarks_") }
        }
    }
}
