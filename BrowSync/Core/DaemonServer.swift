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
    var lastSeen: Date
    var stateCache: [String: Data] = [:]  // site -> last sync payload
    /// From the register message; empty for extension builds that predate it.
    var capabilities: Set<String> = []

    init(id: String, browser: Browser, connection: NWConnection) {
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

// MARK: - Daemon Server Delegate

protocol DaemonServerDelegate: AnyObject {
    func daemonServer(_ server: DaemonServer, didConnect client: ConnectedClient)
    func daemonServer(_ server: DaemonServer, didDisconnect clientId: String, browser: Browser)
    func daemonServer(_ server: DaemonServer, didReceiveSync message: WSMessage, from clientId: String)
    func daemonServer(_ server: DaemonServer, didReceivePullBookmarks clientId: String)
    func daemonServer(_ server: DaemonServer, didReceiveSettings message: WSMessage, from clientId: String)
    func daemonServer(_ server: DaemonServer, didReceiveOpenSettingsFrom clientId: String)
    func daemonServer(_ server: DaemonServer, didReceiveOpenURL message: WSMessage, from clientId: String)
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
                wsOptions.setClientRequestHandler(.global(qos: .userInitiated)) { [weak self] _, headers in
                    switch policy.evaluate(headers: headers, session: session) {
                    case .allow:
                        return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
                    case .requestApproval(let origin):
                        Task { @MainActor [weak self] in self?.requestOriginApproval(origin, session: session) }
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

    private func approvalContent(for browser: Browser, message: String) -> NSView {
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
        let browserImage = browser.appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
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
        alert.buttons[0].target = action
        alert.buttons[0].action = #selector(ApprovalAlertAction.deny)
        alert.buttons[1].target = action
        alert.buttons[1].action = #selector(ApprovalAlertAction.allow)

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

    private func requestOriginApproval(_ origin: String, session: UUID) {
        guard !listeners.isEmpty, connectionPolicy.isOriginPending(origin, session: session) else { return }
        originApprovalQueue.append(origin)
        presentNextOriginApproval()
    }

    private func presentNextOriginApproval() {
        guard approvalAlert == nil, !originApprovalQueue.isEmpty else {
            if originApprovalQueue.isEmpty { presentNextBrowserApproval() }
            return
        }
        let origin = originApprovalQueue.removeFirst()
        let bundle = LanguageBundle(language: AppState.shared.settingsService.general.language).bundle
        let browser: Browser = origin.hasPrefix("chrome-extension://") ? .chrome : .firefox
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: String(localized: "BrowSync: Allow %@ to Connect?", bundle: bundle), browser.displayName)
        let message = String(localized: "Only allow this request if you just enabled BrowSync in your browser. The extension can use your enabled sync features. Your choice is remembered on this Mac for future connections.", bundle: bundle)
        alert.informativeText = ""
        alert.accessoryView = approvalContent(for: browser, message: message)
        alert.addButton(withTitle: String(localized: "Don't Allow", bundle: bundle))
        alert.addButton(withTitle: String(localized: "Allow Connection", bundle: bundle))
        let generation = approvalGeneration
        showApprovalAlert(alert) { [weak self] allowed in
            guard let self, self.approvalGeneration == generation else { return }
            self.connectionPolicy.resolveOrigin(origin, allow: allowed)
            if allowed, browser == .firefox { self.connectionPolicy.approveFirefoxAfterOriginConsent() }
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
        alert.addButton(withTitle: String(localized: "Don't Allow", bundle: bundle))
        alert.addButton(withTitle: String(localized: "Allow Connection", bundle: bundle))
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

            // Notify delegate
            delegate?.daemonServer(self, didReceiveSync: message, from: client.id)

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

    private func handleRegister(_ message: WSMessage, connection: NWConnection) {
        guard pendingConnections[ObjectIdentifier(connection)] != nil,
              let browserRaw = message.browser, let originalInstanceId = message.instanceId,
              !originalInstanceId.isEmpty, originalInstanceId.utf8.count <= 256 else {
            logger.warning("Invalid register message")
            removeConnection(connection)
            return
        }
        
        var realBrowserId = browserRaw
        let allBrowsers = Browser.standardBrowsers + AppState.shared.settingsService.general.customBrowsers
        
        // Chromium-derived browsers may expose an indistinguishable Chrome UA
        // to an extension service worker. Resolve that fallback against the
        // complete browser registry, not a hand-picked subset of browsers.
        if realBrowserId == "chrome" {
            let runningChromiumBrowsers = allBrowsers.filter { browser in
                // Safari and Firefox have their own extension transports. Every
                // other registered browser (including custom ones) is eligible
                // for the shared Chromium extension transport.
                browser != .firefox && browser != .safari &&
                !NSWorkspace.shared.runningApplications.filter({ $0.bundleIdentifier == browser.bundleIdentifier || $0.bundleIdentifier?.hasPrefix(browser.bundleIdentifier + ".") == true }).isEmpty
            }

            let unconnectedCandidates = runningChromiumBrowsers.filter { !self.connectedBrowsers.contains($0) }
            
            if runningChromiumBrowsers.count == 1 {
                realBrowserId = runningChromiumBrowsers[0].id
                logger.info("Daemon: Inferred real browser ID from single running app: \(realBrowserId)")
            } else if unconnectedCandidates.count == 1 {
                realBrowserId = unconnectedCandidates[0].id
                logger.info("Daemon: Inferred real browser ID from single unconnected running app: \(realBrowserId)")
            }
        }
        guard let browser = allBrowsers.first(where: { $0.id == realBrowserId }) else {
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
        
        let instanceId = originalInstanceId.replacingOccurrences(of: browserRaw, with: realBrowserId)

        // Disconnect existing client with same instanceId (reconnect)
        if let existing = clients[instanceId] {
            existing.connection.cancel()
            clients.removeValue(forKey: instanceId)
        }

        pendingConnections.removeValue(forKey: ObjectIdentifier(connection))
        pendingSince.removeValue(forKey: ObjectIdentifier(connection))

        let client = ConnectedClient(id: instanceId, browser: browser, connection: connection)
        client.capabilities = Set(message.capabilities ?? [])
        clients[instanceId] = client
        connectedBrowsers.insert(browser)

        logger.info("✅ Registered: \(instanceId) (\(browser.displayName))")
        delegate?.daemonServer(self, didConnect: client)

        // ACK the registration
        if let msgId = message.messageId {
            sendWSMessage(WSMessage.ack(messageId: msgId, browserId: realBrowserId), to: client)
        }

        // The receive loop schedules the next read after routing returns.
    }


    // MARK: - WebSocket Send

    func sendWSMessage(_ message: WSMessage, to client: ConnectedClient) {
        guard let data = try? JSONEncoder().encode(message) else { return }
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
        guard let data = try? JSONEncoder().encode(message) else { return }
        for (id, client) in clients {
            if id == excludedId { continue }
            if let participating = participatingBrowsers, !participating.contains(client.browser) { continue }
            sendData(data, on: client.connection)
        }
    }
    
    func send(_ message: WSMessage, toClientId clientId: String) {
        guard let data = try? JSONEncoder().encode(message),
              let client = clients[clientId] else { return }
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
