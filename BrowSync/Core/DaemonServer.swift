// DaemonServer.swift
// BrowSync — WebSocket server using Network.framework NWProtocolWebSocket
// Listens on ws://127.0.0.1:62333

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
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())
        let logFile = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/BrowSync/logs/sync-\(dateString).log")
        do {
            let message = try JSONDecoder().decode(WSMessage.self, from: data)
            routeMessage(message, from: connection)
        } catch {
            logger.warning("Failed to decode WebSocket message: \(error)")
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                let rawString = String(data: data, encoding: .utf8) ?? "unknown"
                let errStr = "[DECODE ERROR] \(error)\nRAW DATA: \(rawString)\n"
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
        guard let browserRaw = message.browser, let originalInstanceId = message.instanceId else {
            logger.warning("Invalid register message: \(String(describing: message))")
            return
        }
        
        var realBrowserId = browserRaw
        if let inferredId = inferBrowserId(from: connection) {
            logger.info("Daemon: Inferred real browser ID: \(inferredId) (client reported: \(browserRaw))")
            realBrowserId = inferredId
        }
        
        let allBrowsers = Browser.standardBrowsers + AppState.shared.settingsService.general.customBrowsers
        guard let browser = allBrowsers.first(where: { $0.id == realBrowserId }) else {
            logger.warning("Unknown browser id: \(realBrowserId)")
            return
        }
        
        let instanceId = originalInstanceId.replacingOccurrences(of: browserRaw, with: realBrowserId)

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
            sendWSMessage(WSMessage.ack(messageId: msgId, browserId: realBrowserId), to: client)
        }

        // Continue receiving
        receiveNextMessage(on: connection)
    }

    // MARK: - Native Browser Inference
    
    private func inferBrowserId(from connection: NWConnection) -> String? {
        guard case .hostPort(_, let port) = connection.endpoint else { return nil }
        let clientPort = port.rawValue
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(clientPort)", "-sTCP:ESTABLISHED"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            
            let myBundleId = Bundle.main.bundleIdentifier ?? "com.ct106.browsync"
            let lines = output.components(separatedBy: .newlines)
            
            for line in lines {
                let columns = line.split(separator: " ", omittingEmptySubsequences: true)
                if columns.count >= 2, let pid = pid_t(String(columns[1])) {
                    logger.info("Daemon: Found PID \(pid, privacy: .public) for port \(clientPort, privacy: .public)")
                    if let app = NSRunningApplication(processIdentifier: pid) {
                        let appBundleId = app.bundleIdentifier
                        logger.info("Daemon: Checking app with PID \(pid, privacy: .public), bundle ID: \(appBundleId ?? "nil", privacy: .public)")
                        if let appBundleId = appBundleId, appBundleId != myBundleId {
                            let allBrowsers = Browser.standardBrowsers + AppState.shared.settingsService.general.customBrowsers
                            if let browser = allBrowsers.first(where: { 
                                appBundleId == $0.bundleIdentifier || appBundleId.hasPrefix($0.bundleIdentifier + ".") 
                            }) {
                                logger.info("Daemon: App matched: \(browser.id, privacy: .public) for bundle: \(appBundleId, privacy: .public)")
                                return browser.id
                            }
                        }
                    } else {
                        logger.warning("Daemon: NSRunningApplication returned nil for PID \(pid, privacy: .public). Trying ps fallback...")
                        let psProcess = Process()
                        psProcess.executableURL = URL(fileURLWithPath: "/bin/ps")
                        psProcess.arguments = ["-p", "\(pid)", "-o", "comm="]
                        let psPipe = Pipe()
                        psProcess.standardOutput = psPipe
                        try? psProcess.run()
                        psProcess.waitUntilExit()
                        
                        if let data = try? psPipe.fileHandleForReading.readToEnd(),
                           let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !path.isEmpty {
                            logger.info("Daemon: ps path is \(path, privacy: .public)")
                            var currentURL = URL(fileURLWithPath: path)
                            var fallbackBundleId: String? = nil
                            while currentURL.path != "/" && currentURL.path.count > 1 {
                                if currentURL.pathExtension == "app" {
                                    if let bId = Bundle(url: currentURL)?.bundleIdentifier {
                                        fallbackBundleId = bId
                                        break
                                    }
                                }
                                currentURL = currentURL.deletingLastPathComponent()
                            }
                            
                            logger.info("Daemon: fallbackBundleId is \(fallbackBundleId ?? "nil", privacy: .public)")
                            if let appBundleId = fallbackBundleId, appBundleId != myBundleId {
                                let allBrowsers = Browser.standardBrowsers + AppState.shared.settingsService.general.customBrowsers
                                if let browser = allBrowsers.first(where: { 
                                    appBundleId == $0.bundleIdentifier || appBundleId.hasPrefix($0.bundleIdentifier + ".") 
                                }) {
                                    logger.info("Daemon: App matched via ps fallback: \(browser.id, privacy: .public)")
                                    return browser.id
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            logger.warning("Failed to run lsof for inference: \(error.localizedDescription)")
        }
        return nil
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
