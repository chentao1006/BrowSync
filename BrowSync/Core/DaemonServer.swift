// DaemonServer.swift
// BrowSync — WebSocket server using Network.framework NWProtocolWebSocket
// Listens on ws://127.0.0.1:62333

import Foundation
import Network
import os.log

// MARK: - Connected Client

final class ConnectedClient {
    let id: String           // instanceId from register message
    let browser: Browser
    let connection: NWConnection
    var lastSeen: Date
    var stateCache: [String: Data] = [:]  // site -> last sync payload

    init(id: String, browser: Browser, connection: NWConnection) {
        self.id = id
        self.browser = browser
        self.connection = connection
        self.lastSeen = Date()
    }
}

// MARK: - Daemon Server Delegate

protocol DaemonServerDelegate: AnyObject {
    func daemonServer(_ server: DaemonServer, didConnect client: ConnectedClient)
    func daemonServer(_ server: DaemonServer, didDisconnect clientId: String, browser: Browser)
    func daemonServer(_ server: DaemonServer, didReceiveSync message: WSMessage, from clientId: String)
}

// MARK: - Daemon Server

@MainActor
final class DaemonServer: ObservableObject {
    static let port: UInt16 = 62333
    static let heartbeatInterval: TimeInterval = 30
    static let heartbeatTimeout: TimeInterval = 120

    private let logger = Logger(subsystem: "com.ct106.browsync", category: "DaemonServer")

    private var listener: NWListener?
    /// Connections that haven't registered yet
    private var pendingConnections: [ObjectIdentifier: NWConnection] = [:]
    /// Registered clients keyed by instanceId
    private var clients: [String: ConnectedClient] = [:]
    private var heartbeatTimer: Timer?

    @Published var isRunning: Bool = false
    @Published var connectedBrowsers: Set<Browser> = []

    weak var delegate: DaemonServerDelegate?

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        // Build WebSocket parameters over TCP
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.maximumMessageSize = 50_000_000
        wsOptions.autoReplyPing = true  // let the stack handle WebSocket pings automatically

        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        params.allowLocalEndpointReuse = true

        do {
            let port = NWEndpoint.Port(rawValue: DaemonServer.port)!
            listener = try NWListener(using: params, on: port)
        } catch {
            logger.error("Failed to create WebSocket listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleListenerState(state) }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.handleNewConnection(connection) }
        }

        listener?.start(queue: .global(qos: .userInitiated))
        startHeartbeatTimer()
        isRunning = true
        logger.info("DaemonServer (WebSocket) started on port \(DaemonServer.port)")
    }

    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        listener?.cancel()
        listener = nil
        for (_, client) in clients { client.connection.cancel() }
        for (_, conn) in pendingConnections { conn.cancel() }
        clients.removeAll()
        pendingConnections.removeAll()
        connectedBrowsers.removeAll()
        isRunning = false
        logger.info("DaemonServer stopped")
    }

    // MARK: - Listener State

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.info("WebSocket listener ready on port \(DaemonServer.port)")
        case .failed(let error):
            logger.error("Listener failed: \(error)")
            isRunning = false
            // Retry after 3 seconds
            Task { try? await Task.sleep(nanoseconds: 3_000_000_000); self.start() }
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    // MARK: - New Connection

    private func handleNewConnection(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        pendingConnections[key] = connection

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

                self.receiveNextMessage(on: connection)
            }
        }
    }

    private func processMessageData(_ data: Data, from connection: NWConnection) {
        let logFile = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/BrowSync/logs/sync.log")
        do {
            let message = try JSONDecoder().decode(WSMessage.self, from: data)
            routeMessage(message, from: connection)
        } catch {
            logger.warning("Failed to decode WebSocket message: \(error)")
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                let errStr = "[DECODE ERROR] \(error)\n"
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

        switch message.type {
        case .register:
            handleRegister(message, connection: connection)

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

            // Save to persistent global store
            GlobalStateStore.shared.save(message: message)

            // Broadcast to all other registered clients
            broadcast(message, excluding: client.id)

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
            
            let payloads = GlobalStateStore.shared.pull(site: message.site, category: message.category)
            for payloadData in payloads {
                sendData(payloadData, on: client.connection)
            }

        case .disconnect:
            removeConnection(connection)

        default:
            break
        }
    }

    // MARK: - Register

    private func handleRegister(_ message: WSMessage, connection: NWConnection) {
        guard
            let browserRaw = message.browser,
            let browser = Browser(rawValue: browserRaw),
            let instanceId = message.instanceId
        else {
            logger.warning("Invalid register message: \(String(describing: message))")
            return
        }

        // Disconnect existing client with same instanceId (reconnect)
        if let existing = clients[instanceId] {
            existing.connection.cancel()
            clients.removeValue(forKey: instanceId)
        }

        pendingConnections.removeValue(forKey: ObjectIdentifier(connection))

        let client = ConnectedClient(id: instanceId, browser: browser, connection: connection)
        clients[instanceId] = client
        connectedBrowsers.insert(browser)

        logger.info("✅ Registered: \(instanceId) (\(browser.displayName))")
        delegate?.daemonServer(self, didConnect: client)

        // ACK the registration
        if let msgId = message.messageId {
            sendWSMessage(WSMessage.ack(messageId: msgId), to: client)
        }

        // Continue receiving
        receiveNextMessage(on: connection)
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

    func broadcast(_ message: WSMessage, excluding excludedId: String? = nil) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        for (id, client) in clients {
            if id == excludedId { continue }
            sendData(data, on: client.connection)
        }
    }

    // MARK: - Cleanup

    private func removeConnection(_ connection: NWConnection) {
        connection.cancel()
        pendingConnections.removeValue(forKey: ObjectIdentifier(connection))

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
            let key = "\(category)_\(site)"
            if let data = try? JSONEncoder().encode(message) {
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
            self.stateCache = cache
        }
    }
}
