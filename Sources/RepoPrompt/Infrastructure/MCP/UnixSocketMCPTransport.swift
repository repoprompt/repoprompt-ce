//
//  UnixSocketMCPTransport.swift
//  RepoPrompt
//
//  UNIX domain socket transport for local MCP connections.
//  Uses DispatchSourceRead for event-driven I/O (no polling).
//

import Foundation
import Logging
import MCP
import RepoPromptDomainRuntime
import RepoPromptShared

#if DEBUG
    private var unixSocketMCPTransportDebugLoggingEnabled = ProcessInfo.processInfo.environment["REPOPROMPT_MCP_DEBUG"] == "1"
    private func unixSocketMCPTransportDebugLog(_ message: @autoclosure () -> String) {
        guard unixSocketMCPTransportDebugLoggingEnabled else { return }
        print("[UnixSocketMCPTransport] \(message())")
    }
#else
    private func unixSocketMCPTransportDebugLog(_ message: @autoclosure () -> String) {}
#endif

#if DEBUG
    private final class UnixSocketMCPTransportCallbackGate: @unchecked Sendable {
        enum Kind: Hashable {
            case terminal
            case cancellation
        }

        private let lock = NSLock()
        private var heldKinds: Set<Kind> = []
        private var pendingCallbacks: [Kind: [@Sendable () -> Void]] = [:]

        func hold(_ kind: Kind) {
            lock.lock()
            heldKinds.insert(kind)
            lock.unlock()
        }

        func submit(_ kind: Kind, callback: @escaping @Sendable () -> Void) {
            lock.lock()
            guard heldKinds.contains(kind) else {
                lock.unlock()
                callback()
                return
            }
            pendingCallbacks[kind, default: []].append(callback)
            lock.unlock()
        }

        func release(_ kind: Kind) {
            lock.lock()
            heldKinds.remove(kind)
            let callbacks = pendingCallbacks.removeValue(forKey: kind) ?? []
            lock.unlock()
            callbacks.forEach { $0() }
        }

        func pendingCount(_ kind: Kind) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return pendingCallbacks[kind]?.count ?? 0
        }
    }

    struct UnixSocketMCPTransportCleanupSnapshot {
        let hasActiveReader: Bool
        let pendingReaderCancellationCount: Int
        let earlyReaderCancellationCount: Int
        let readerIsRetained: Bool
        let terminalCallbackCount: Int
        let pendingTerminalCallbackCount: Int
        let cancellationCallbackCount: Int
        let finalizationCount: Int
        let descriptorCloseCount: Int
        let staleCancellationCount: Int
        let staleTerminalCount: Int
        let socketIsOwned: Bool
    }
#endif

private final class MCPTransportIngressGate: @unchecked Sendable {
    enum OfferResult {
        case accepted
        case overflow(MCPReceiveBufferOverflowError)
        case terminal
    }

    private let lock = NSLock()
    private let capacity: Int
    private var acceptedFrameCount = 0
    private var droppedFrameCount = 0
    private var highWaterMark = 0
    private var isTerminal = false
    private var terminalCause: MCPTransportTerminalCause?

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func offer(
        _ frame: Data,
        to continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    ) -> OfferResult {
        lock.lock()
        defer { lock.unlock() }

        guard !isTerminal else {
            return .terminal
        }

        switch continuation.yield(frame) {
        case let .enqueued(remainingCapacity):
            acceptedFrameCount += 1
            highWaterMark = max(highWaterMark, capacity - remainingCapacity)
            return .accepted
        case .dropped:
            droppedFrameCount += 1
            highWaterMark = capacity
            isTerminal = true
            terminalCause = .receiveBufferOverflow
            return .overflow(MCPReceiveBufferOverflowError(
                capacity: capacity,
                highWaterMark: highWaterMark
            ))
        case .terminated:
            isTerminal = true
            return .terminal
        @unknown default:
            isTerminal = true
            return .terminal
        }
    }

    func closeAndSnapshot() -> MCPTransportIngressSnapshot {
        lock.lock()
        isTerminal = true
        let snapshot = makeSnapshot()
        lock.unlock()
        return snapshot
    }

    func snapshot() -> MCPTransportIngressSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshot()
    }

    private func makeSnapshot() -> MCPTransportIngressSnapshot {
        MCPTransportIngressSnapshot(
            receiveBufferCapacity: capacity,
            acceptedFrameCount: acceptedFrameCount,
            droppedFrameCount: droppedFrameCount,
            receiveBufferHighWaterMark: highWaterMark,
            isTerminal: isTerminal,
            terminalCause: terminalCause
        )
    }
}

typealias MCPTransportResponseDeliveryGate = MCPDomainResponseDeliveryTracker

final class MCPExportResponseDeliveryDeadlineRegistry: @unchecked Sendable {
    struct Token: Hashable {
        fileprivate let connectionID: String
        fileprivate let connectionGeneration: UInt64
        fileprivate let requestID: JSONRPCBridgeID
    }

    struct DispatchIdentity: Equatable {
        let connectionID: String
        let connectionGeneration: UInt64
        let requestID: JSONRPCBridgeID
    }

    struct Deadline: @unchecked Sendable {
        let instant: Duration
        let now: @Sendable () -> Duration

        var hasExpired: Bool {
            now() >= instant
        }

        var remainingSeconds: TimeInterval {
            let remaining = instant - now()
            guard remaining > .zero else { return 0 }
            let components = remaining.components
            return TimeInterval(components.seconds)
                + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        }
    }

    static let shared = MCPExportResponseDeliveryDeadlineRegistry()

    static let requestIdentityArgumentKey = "_repoprompt_transport_request_identity"

    private let lock = NSLock()
    private var pendingRequests: Set<Token> = []
    private var deadlines: [Token: Deadline] = [:]

    private init() {}

    /// Carries the transport-observed JSON-RPC identity through SDK dispatch without
    /// relying on handler admission order, which may differ from socket frame order.
    @discardableResult
    func recordAcceptedClientFrame(
        _ frame: Data,
        connectionID: String,
        connectionGeneration: UInt64
    ) -> Data {
        let hadNewline = frame.last == UInt8(ascii: "\n")
        guard let json = try? JSONSerialization.jsonObject(with: frame) else { return frame }
        var recordedTokens: [Token] = []

        func annotate(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                guard object["method"] as? String == "tools/call",
                      let requestID = JSONRPCBridgeID.parseJSONValue(object["id"]),
                      requestID != .null,
                      var params = object["params"] as? [String: Any],
                      let toolName = params["name"] as? String,
                      toolName == "prompt" || toolName == "workspace_context"
                else { return object }
                var arguments: [String: Any] = [:]
                if let presentArguments = params["arguments"] {
                    // Only absent arguments may be synthesized. Substituting an empty object for a
                    // present-but-malformed value would hand the SDK a well-formed call and silently
                    // run the default read, so leave such a request untouched for validation to reject.
                    guard let objectArguments = presentArguments as? [String: Any] else { return object }
                    arguments = objectArguments
                }
                arguments[Self.requestIdentityArgumentKey] = [
                    "connection_id": connectionID,
                    "connection_generation": String(connectionGeneration),
                    "request_id": requestID.description
                ]
                params["arguments"] = arguments
                object["params"] = params
                recordedTokens.append(Token(
                    connectionID: connectionID,
                    connectionGeneration: connectionGeneration,
                    requestID: requestID
                ))
                return object
            }
            if let batch = value as? [Any] {
                return batch.map(annotate)
            }
            return value
        }

        let annotated = annotate(json)
        guard !recordedTokens.isEmpty,
              var encoded = try? JSONSerialization.data(withJSONObject: annotated, options: [.sortedKeys])
        else { return frame }
        if hadNewline { encoded.append(UInt8(ascii: "\n")) }
        lock.withLock { pendingRequests.formUnion(recordedTokens) }
        return encoded
    }

    static func dispatchIdentity(from value: Value?) -> DispatchIdentity? {
        guard let object = value?.objectValue,
              let connectionID = object["connection_id"]?.stringValue,
              let generationString = object["connection_generation"]?.stringValue,
              let connectionGeneration = UInt64(generationString),
              let requestIDString = object["request_id"]?.stringValue,
              let requestID = JSONRPCBridgeID.parseFaultSelector(requestIDString),
              requestID != .null
        else { return nil }
        return DispatchIdentity(
            connectionID: connectionID,
            connectionGeneration: connectionGeneration,
            requestID: requestID
        )
    }

    func claimToolRequest(
        connectionID: String,
        connectionGeneration: UInt64,
        requestID: JSONRPCBridgeID
    ) -> Token? {
        let token = Token(
            connectionID: connectionID,
            connectionGeneration: connectionGeneration,
            requestID: requestID
        )
        return lock.withLock {
            guard pendingRequests.remove(token) != nil else { return nil }
            return token
        }
    }

    #if DEBUG
        func deadlineForTesting(
            connectionID: String,
            connectionGeneration: UInt64,
            requestID: JSONRPCBridgeID
        ) -> Deadline? {
            lock.withLock {
                deadlines[Token(
                    connectionID: connectionID,
                    connectionGeneration: connectionGeneration,
                    requestID: requestID
                )]
            }
        }
    #endif

    func install(_ deadline: Deadline, for token: Token) {
        lock.withLock { deadlines[token] = deadline }
    }

    func deadline(
        forServerFrame frame: Data,
        connectionID: String,
        connectionGeneration: UInt64
    ) -> Deadline? {
        let responseIDs = JSONRPCBridgeFrameInspector.inspectPermissively(
            frame,
            direction: .serverToClient
        ).compactMap(\.id)
        return lock.withLock {
            responseIDs.compactMap { requestID in
                deadlines[Token(
                    connectionID: connectionID,
                    connectionGeneration: connectionGeneration,
                    requestID: requestID
                )]
            }.min { $0.instant < $1.instant }
        }
    }

    func completeServerFrame(
        _ frame: Data,
        connectionID: String,
        connectionGeneration: UInt64
    ) {
        let responseIDs = JSONRPCBridgeFrameInspector.inspectPermissively(
            frame,
            direction: .serverToClient
        ).compactMap(\.id)
        lock.withLock {
            for requestID in responseIDs {
                deadlines.removeValue(forKey: Token(
                    connectionID: connectionID,
                    connectionGeneration: connectionGeneration,
                    requestID: requestID
                ))
            }
        }
    }

    func removeConnection(connectionID: String, connectionGeneration: UInt64) {
        lock.withLock {
            pendingRequests = pendingRequests.filter {
                $0.connectionID != connectionID
                    || $0.connectionGeneration != connectionGeneration
            }
            deadlines = deadlines.filter {
                $0.key.connectionID != connectionID
                    || $0.key.connectionGeneration != connectionGeneration
            }
        }
    }
}

/// A Transport implementation using UNIX domain sockets for local MCP communication.
///
/// This transport connects to a UNIX socket created by the CLI within a connection folder.
/// It provides efficient, low-latency communication using event-driven I/O via
/// DispatchSourceRead, avoiding the CPU overhead of polling.
public actor UnixSocketMCPTransport: Transport {
    private let socketURL: URL?
    private let timelineConnectionID: String?
    private let timelineCorrelationConnectionID: String?
    private let timelineConnectionGeneration: UInt64
    public let logger: Logger

    private var socketFD: Int32 = -1
    private var isConnected = false
    private var isStopping = false
    private var streamFinished = false

    /// If true, this transport was created with an existing FD (no connect needed)
    private let ownsExistingFD: Bool

    private struct InboundChannel {
        let stream: AsyncThrowingStream<Data, Swift.Error>
        let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
        let gate: MCPTransportIngressGate

        init(capacity: Int) {
            var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
            stream = AsyncThrowingStream(
                Data.self,
                bufferingPolicy: .bufferingOldest(capacity)
            ) { continuation = $0 }
            self.continuation = continuation
            gate = MCPTransportIngressGate(capacity: capacity)
        }
    }

    private struct CloseChannel {
        let stream: AsyncStream<MCPTransportCloseSnapshot>
        let continuation: AsyncStream<MCPTransportCloseSnapshot>.Continuation

        init() {
            var continuation: AsyncStream<MCPTransportCloseSnapshot>.Continuation!
            stream = AsyncStream(MCPTransportCloseSnapshot.self) { continuation = $0 }
            self.continuation = continuation
        }
    }

    /// Connection-local inbound and close channels. URL-backed transports replace
    /// these after teardown so a successor connection cannot inherit terminal state.
    private let receiveBufferCapacity: Int
    private var inboundChannel: InboundChannel
    private var closeChannel: CloseChannel
    private var closeSignaled = false
    private var firstCloseSnapshot: MCPTransportCloseSnapshot?

    /// Event-driven read source (replaces poll loop)
    private let readQueue = DispatchQueue(label: "com.repoprompt.mcp.unix.read", qos: .userInitiated)

    private var nextReadSourceToken: UInt64 = 0

    private struct ReaderIdentity: Hashable {
        let fd: Int32
        let token: UInt64
        let socketOwnershipGeneration: UInt64
    }

    private struct ActiveReaderOwnership {
        let identity: ReaderIdentity
        let reader: NewlineDelimitedSocketReader
    }

    /// Retains cancelled readers until their delayed cancel handlers perform final close.
    /// The transport retainer intentionally forms a temporary cycle so cleanup does not
    /// depend on an external manager keeping this actor alive after disconnect returns.
    private struct PendingReaderCancellation {
        let identity: ReaderIdentity
        let reader: NewlineDelimitedSocketReader
        let transportRetainer: UnixSocketMCPTransport
    }

    private var activeReaderOwnership: ActiveReaderOwnership?
    private var pendingReaderCancellations: [UInt64: PendingReaderCancellation] = [:]
    private var earlyReaderCancellations: Set<ReaderIdentity> = []

    /// Changes whenever socketFD is replaced or synchronously closed.
    private var socketOwnershipGeneration: UInt64 = 0

    #if DEBUG
        private nonisolated let callbackGate = UnixSocketMCPTransportCallbackGate()
        private weak var debugLastReader: NewlineDelimitedSocketReader?
        private var debugTerminalCallbackCount = 0
        private var debugCancellationCallbackCount = 0
        private var debugReaderFinalizationCount = 0
        private var debugDescriptorCloseCount = 0
        private var debugStaleCancellationCount = 0
        private var debugStaleTerminalCount = 0
        /// Forces the adopted-FD startup path to fail after preparation but before reader ownership.
        private var failNextExistingFDConnectBeforeReaderStart = false
        /// Leaves a selected overflow pending so tests can race it with another teardown path.
        private var deferNextReceiveOverflowTeardown = false
        private var debugBeforeInboundFrameOfferForTesting: (@Sendable () -> Void)?
        private var debugAfterWriteProgressForTesting: (@Sendable (_ bytesWritten: Int) -> Void)?
    #endif

    /// Generation counter that increments on each connection close/open cycle.
    /// Used to detect FD reuse races in the write path.
    private var fdGeneration: UInt64 = 0

    private var lastActivityTime: Date?
    private let responseDeliveryGate = MCPDomainResponseDeliveryTracker()

    /// Connection timeout when waiting for socket to appear and accept connections
    private let connectionTimeout: TimeInterval = 30.0

    /// Maximum time a write may make no forward progress before the connection is failed closed.
    private let writeStallTimeout: TimeInterval

    /// Maximum poll interval while waiting for socket writability under backpressure.
    private let writePollIntervalMilliseconds: Int32

    /// Retry interval when waiting for socket
    private let retryInterval: UInt64 = 50_000_000 // 50ms in nanoseconds

    /// Creates a transport that will connect to the given socket URL.
    public init(
        socketURL: URL,
        logger: Logger? = nil,
        writeStallTimeout: TimeInterval = MCPTimeoutPolicy.transportWriteStallTimeoutSeconds,
        writePollIntervalMilliseconds: Int32 = 250,
        receiveBufferCapacity: Int = 1024
    ) {
        let sanitizedReceiveBufferCapacity = max(1, receiveBufferCapacity)
        self.socketURL = socketURL
        timelineConnectionID = nil
        timelineCorrelationConnectionID = nil
        timelineConnectionGeneration = 1
        ownsExistingFD = false
        self.logger = Self.createLogger(logger)
        self.writeStallTimeout = writeStallTimeout
        self.writePollIntervalMilliseconds = Self.sanitizedWritePollIntervalMilliseconds(writePollIntervalMilliseconds)
        self.receiveBufferCapacity = sanitizedReceiveBufferCapacity
        inboundChannel = InboundChannel(capacity: sanitizedReceiveBufferCapacity)
        closeChannel = CloseChannel()
    }

    /// Creates a transport using an already-connected file descriptor.
    /// Use this when accepting connections from BootstrapSocketServer.
    /// - Parameters:
    ///   - connectedFD: An already-connected UNIX socket file descriptor
    ///   - logger: Optional logger
    public init(
        connectedFD: Int32,
        connectionID: UUID? = nil,
        correlationConnectionID: String? = nil,
        connectionGeneration: UInt64 = 1,
        logger: Logger? = nil,
        writeStallTimeout: TimeInterval = MCPTimeoutPolicy.transportWriteStallTimeoutSeconds,
        writePollIntervalMilliseconds: Int32 = 250,
        receiveBufferCapacity: Int = 1024
    ) throws {
        let sanitizedReceiveBufferCapacity = max(1, receiveBufferCapacity)
        do {
            try POSIXDescriptorSupport.setCloseOnExec(connectedFD)
        } catch {
            POSIXDescriptorSupport.shutdownSocketReadWrite(connectedFD)
            if connectedFD >= 0 {
                Darwin.close(connectedFD)
            }
            throw error
        }

        socketURL = nil
        timelineConnectionID = connectionID?.uuidString
        timelineCorrelationConnectionID = correlationConnectionID ?? connectionID?.uuidString
        timelineConnectionGeneration = connectionGeneration
        socketFD = connectedFD
        ownsExistingFD = true
        isConnected = false
        self.logger = Self.createLogger(logger)
        self.writeStallTimeout = writeStallTimeout
        self.writePollIntervalMilliseconds = Self.sanitizedWritePollIntervalMilliseconds(writePollIntervalMilliseconds)
        self.receiveBufferCapacity = sanitizedReceiveBufferCapacity
        inboundChannel = InboundChannel(capacity: sanitizedReceiveBufferCapacity)
        closeChannel = CloseChannel()
    }

    private static func createLogger(_ logger: Logger?) -> Logger {
        var l = logger ?? Logger(label: "com.repoprompt.mcp.unix.transport") {
            _ in SwiftLogNoOpLogHandler()
        }
        #if DEBUG
            l.logLevel = unixSocketMCPTransportDebugLoggingEnabled ? .debug : .notice
        #else
            l.logLevel = .notice
        #endif
        return l
    }

    private nonisolated static func sanitizedWritePollIntervalMilliseconds(_ value: Int32) -> Int32 {
        max(1, value)
    }

    // MARK: - Transport Protocol

    /// Connects to the UNIX socket, waiting for it to appear if necessary.
    /// If this transport was created with an existing FD, this just starts the read source.
    public func connect() async throws {
        if ownsExistingFD {
            try connectExistingFD()
            return
        }

        guard !isConnected else { return }

        guard let socketURL else {
            throw MCPError.internalError("No socket URL and no existing FD")
        }

        unixSocketMCPTransportDebugLog("connecting to \(socketURL.path)")

        prepareForConnectionAttempt()

        // Wait for socket file to appear and connect
        let startTime = Date()
        var lastError: Swift.Error?

        while Date().timeIntervalSince(startTime) < connectionTimeout {
            if Task.isCancelled {
                let error = CancellationError()
                tearDownSocket(
                    error: error,
                    cause: .connectCancelled,
                    initiator: .app
                )
                throw error
            }

            // Check if socket file exists
            if FileManager.default.fileExists(atPath: socketURL.path) {
                do {
                    try connectToSocket()

                    // Start event-driven read source (replaces poll loop) before marking connected.
                    try startReadSource(fd: socketFD)
                    isConnected = true
                    lastActivityTime = Date()

                    unixSocketMCPTransportDebugLog("connected successfully")
                    return
                } catch let error as POSIXError where error.code == .ECONNREFUSED || error.code == .ENOENT {
                    // Socket exists but not ready yet, or was removed - retry
                    lastError = error
                } catch {
                    // Other error - fail this connection attempt cleanly.
                    tearDownSocket(
                        error: error,
                        cause: .connectFailure,
                        initiator: .transport,
                        errno: Self.errnoValue(from: error)
                    )
                    throw error
                }
            }

            // Wait before retrying
            try? await Task.sleep(nanoseconds: retryInterval)
        }

        // Timeout reached
        logger.error("UnixSocketMCPTransport connection timeout after \(connectionTimeout)s")
        let error = lastError ?? MCPError.internalError("Timeout connecting to UNIX socket at \(socketURL.path)")
        tearDownSocket(
            error: error,
            cause: .connectFailure,
            initiator: .transport,
            errno: Self.errnoValue(from: error)
        )
        throw error
    }

    /// Disconnects from the UNIX socket.
    /// Order: shutdown socket → cancel reader → close directly only when no reader owns cleanup.
    public func disconnect() async {
        guard isConnected || !isStopping else { return }

        mcpConnectionLog("UnixSocketMCPTransport disconnecting")
        tearDownSocket(
            error: MCPError.connectionClosed,
            cause: .localDisconnect,
            initiator: .app
        )
        mcpConnectionLog("UnixSocketMCPTransport disconnect requested")
    }

    /// Sends a message through the socket.
    public func send(_ message: Data) async throws {
        mcpTransportLog("UnixSocketMCPTransport send called with \(message.count) bytes")
        guard isConnected, socketFD >= 0 else {
            logger.error("UnixSocketMCPTransport send failed: not connected (isConnected=\(isConnected), socketFD=\(socketFD))")
            throw MCPError.connectionClosed
        }

        let framed = Self.frameWithNewlineIfNeeded(message)
        let responseDeadline: MCPExportResponseDeliveryDeadlineRegistry.Deadline? = if let timelineConnectionID {
            MCPExportResponseDeliveryDeadlineRegistry.shared.deadline(
                forServerFrame: framed,
                connectionID: timelineConnectionID,
                connectionGeneration: timelineConnectionGeneration
            )
        } else {
            nil
        }
        #if DEBUG
            let recordedResponses: [MCPRequestTimelineRegistry.RecordedMessage] = if let timelineConnectionID {
                MCPRequestTimelineRegistry.shared.recordedResponses(
                    in: framed,
                    connectionID: timelineConnectionID,
                    connectionGeneration: timelineConnectionGeneration
                )
            } else {
                []
            }
        #endif
        func emitResponseWriteTrace(
            phase: String,
            terminalReason: String? = nil
        ) {
            #if DEBUG
                if recordedResponses.isEmpty {
                    MCPResponseDeliveryTracer.emitFrame(
                        layer: "app_uds_transport",
                        phase: phase,
                        frame: framed,
                        direction: .serverToClient,
                        connectionID: timelineCorrelationConnectionID,
                        connectionGeneration: timelineConnectionGeneration,
                        terminalReason: terminalReason
                    )
                } else {
                    for response in recordedResponses {
                        MCPResponseDeliveryTracer.emit(MCPResponseDeliveryTraceEvent(
                            layer: "app_uds_transport",
                            phase: phase,
                            connectionID: response.identity.connectionID ?? timelineCorrelationConnectionID,
                            connectionGeneration: timelineConnectionGeneration,
                            direction: .serverToClient,
                            id: response.metadata.id,
                            method: response.metadata.method,
                            tool: response.metadata.tool,
                            requestOrdinal: response.metadata.requestOrdinal,
                            framedByteCount: framed.count,
                            framedSHA256: MCPResponseDeliveryTracer.sha256Hex(framed),
                            terminalReason: terminalReason,
                            requestIdentity: response.identity,
                            providerActive: false,
                            networkScopeActive: false,
                            permitActive: false,
                            publicationPending: phase != "transport_write_completed",
                            terminalBarrier: terminalReason != nil
                        ))
                    }
                }
            #else
                MCPResponseDeliveryTracer.emitFrame(
                    layer: "app_uds_transport",
                    phase: phase,
                    frame: framed,
                    direction: .serverToClient,
                    connectionGeneration: fdGeneration,
                    terminalReason: terminalReason
                )
            #endif
        }

        emitResponseWriteTrace(phase: "sdk_encode_completed")
        do {
            try Task.checkCancellation()
            try enforceResponseDeliveryDeadline(responseDeadline, framedByteCount: framed.count)
            // Encoding proves the SDK produced a response frame; this boundary proves the
            // transport began attempting the write, which distinguishes a later stall or close.
            emitResponseWriteTrace(phase: "transport_write_started")
            try await writeAll(framed, responseDeadline: responseDeadline)
            try enforceResponseDeliveryDeadline(responseDeadline, framedByteCount: framed.count)
        } catch {
            // A cancelled partial frame cannot leave the connection reusable because its
            // remaining bytes would corrupt the next JSON-RPC frame.
            if isConnected {
                closeAfterSendFailure(error, cause: .writeFailure)
            }
            // writeAll may close the transport before returning. Keep the response identities
            // captured before the write so terminal failure still joins to its invocation.
            emitResponseWriteTrace(
                phase: "transport_write_failed",
                terminalReason: firstCloseSnapshot?.cause.rawValue ?? "app_uds_send_failed"
            )
            throw error
        }
        responseDeliveryGate.recordDeliveredServerFrame(framed)
        lastActivityTime = Date()
        if let timelineConnectionID {
            MCPExportResponseDeliveryDeadlineRegistry.shared.completeServerFrame(
                framed,
                connectionID: timelineConnectionID,
                connectionGeneration: timelineConnectionGeneration
            )
        }
        emitResponseWriteTrace(phase: "transport_write_completed")
        #if DEBUG
            if let timelineConnectionID {
                MCPRequestTimelineRegistry.shared.completeResponses(
                    recordedResponses,
                    connectionID: timelineConnectionID,
                    connectionGeneration: timelineConnectionGeneration
                )
            }
        #endif
        mcpTransportLog("UnixSocketMCPTransport sent \(framed.count) bytes successfully")
    }

    /// Appends a newline delimiter if the message doesn't already end with one.
    /// This makes framing idempotent so callers don't need to know whether the
    /// transport adds a newline — sending pre-framed or unframed data is equally safe.
    private nonisolated static func frameWithNewlineIfNeeded(_ data: Data) -> Data {
        guard data.last != UInt8(ascii: "\n") else { return data }
        var framed = Data()
        framed.reserveCapacity(data.count + 1)
        framed.append(data)
        framed.append(UInt8(ascii: "\n"))
        return framed
    }

    /// Returns the async stream of received messages.
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        inboundChannel.stream
    }

    /// Returns the close notification stream.
    /// Use this to detect when the socket closes so connections can be cleaned up promptly.
    public func closed() -> AsyncStream<MCPTransportCloseSnapshot> {
        closeChannel.stream
    }

    public func closeSnapshot() -> MCPTransportCloseSnapshot? {
        firstCloseSnapshot
    }

    func ingressSnapshot() -> MCPTransportIngressSnapshot {
        inboundChannel.gate.snapshot()
    }

    /// Returns seconds since last activity, or nil if never active.
    public func secondsSinceLastActivity() -> TimeInterval? {
        guard let lastActivityTime else { return nil }
        return Date().timeIntervalSince(lastActivityTime)
    }

    func responseDeliverySnapshot() async -> MCPResponseDeliverySnapshot {
        responseDeliveryGate.snapshot()
    }

    func waitUntilResponseDeliveryDrained() async -> Bool {
        await responseDeliveryGate.waitUntilDrained()
    }

    // MARK: - Private Implementation

    private func prepareForConnectionAttempt() {
        responseDeliveryGate.reset()
        isStopping = false
        if streamFinished || closeSignaled {
            inboundChannel = InboundChannel(capacity: receiveBufferCapacity)
            closeChannel = CloseChannel()
        }
        streamFinished = false
        closeSignaled = false
        firstCloseSnapshot = nil
    }

    /// Connects to the UNIX socket at socketURL.
    private func connectToSocket() throws {
        guard let socketURL else {
            throw MCPError.internalError("No socket URL configured")
        }

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }

        do {
            try POSIXDescriptorSupport.setCloseOnExec(fd)
        } catch {
            Darwin.close(fd)
            throw error
        }

        // Set up socket address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw MCPError.internalError("Socket path too long: \(path)")
        }

        // Copy path to sun_path without raw-pointer rebinding/casts.
        var sunPath = addr.sun_path
        let sunPathSize = MemoryLayout.size(ofValue: sunPath)
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &sunPath.0) { dst in
                // Safer than strcpy; always NUL-terminates.
                _ = Darwin.strlcpy(dst, cstr, sunPathSize)
            }
        }
        addr.sun_path = sunPath

        // Connect
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }

        if result < 0 {
            let err = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .ECONNREFUSED)
        }

        // Disable SIGPIPE on this socket
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Set non-blocking mode for non-blocking writes
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        socketOwnershipGeneration &+= 1
        socketFD = fd
    }

    /// Closes the socket if open. Callers that own teardown must issue shutdown first.
    private func closeSocket() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            #if DEBUG
                debugDescriptorCloseCount += 1
            #endif
            socketFD = -1
            socketOwnershipGeneration &+= 1
        }
    }

    /// Wakes blocked I/O and deterministically transfers final-close responsibility.
    /// If a reader exists, its cancel handler remains the sole final-close owner to
    /// avoid a stale callback closing a reused descriptor number.
    private func tearDownSocket(
        error proposedError: Swift.Error?,
        cause proposedCause: MCPTransportTerminalCause,
        initiator proposedInitiator: MCPTerminalInitiator,
        errno proposedErrno: Int32? = nil
    ) {
        guard !streamFinished else { return }
        responseDeliveryGate.close()
        if let timelineConnectionID {
            MCPExportResponseDeliveryDeadlineRegistry.shared.removeConnection(
                connectionID: timelineConnectionID,
                connectionGeneration: timelineConnectionGeneration
            )
        }
        #if DEBUG
            if let timelineConnectionID {
                MCPRequestTimelineRegistry.shared.removeConnection(
                    connectionID: timelineConnectionID,
                    connectionGeneration: timelineConnectionGeneration
                )
            }
        #endif
        let ingressSnapshot = inboundChannel.gate.closeAndSnapshot()
        let overflowError = MCPReceiveBufferOverflowError(
            capacity: ingressSnapshot.receiveBufferCapacity,
            highWaterMark: ingressSnapshot.receiveBufferHighWaterMark
        )
        let resolvedError: Swift.Error? = if ingressSnapshot.terminalCause == .receiveBufferOverflow {
            overflowError
        } else {
            proposedError
        }
        if firstCloseSnapshot == nil {
            firstCloseSnapshot = MCPTransportCloseSnapshot(
                cause: ingressSnapshot.terminalCause == .receiveBufferOverflow
                    ? .receiveBufferOverflow
                    : proposedCause,
                initiator: ingressSnapshot.terminalCause == .receiveBufferOverflow
                    ? .transport
                    : proposedInitiator,
                errno: ingressSnapshot.terminalCause == .receiveBufferOverflow
                    ? nil
                    : proposedErrno,
                errorDescription: resolvedError.map { String(describing: $0) }
            )
        }
        if ingressSnapshot.terminalCause == .receiveBufferOverflow {
            logger.error("UnixSocketMCPTransport ingress terminated: \(String(describing: resolvedError))")
        }
        isConnected = false
        isStopping = true

        if socketFD >= 0 {
            POSIXDescriptorSupport.shutdownSocketReadWrite(socketFD)
        }
        stopReadSource()
        if !pendingReaderCancellationOwnsCurrentSocket() {
            closeSocket()
        }
        transitionToClosed(error: resolvedError)
    }

    private func connectExistingFD() throws {
        if isConnected {
            guard activeReaderOwnership != nil else {
                let error = MCPError.connectionClosed
                tearDownSocket(
                    error: error,
                    cause: .connectFailure,
                    initiator: .transport
                )
                throw error
            }
            return
        }

        guard !streamFinished, !closeSignaled, socketFD >= 0 else {
            let error = MCPError.connectionClosed
            tearDownSocket(
                error: error,
                cause: .connectFailure,
                initiator: .transport
            )
            throw error
        }

        do {
            try ReadSourceFDPreflight.validateOpenFD(socketFD, label: "UnixSocketMCPTransport existing socket")
            try Self.ensureNonBlocking(fd: socketFD)

            // Disable SIGPIPE on this socket.
            var noSigPipe: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            #if DEBUG
                if failNextExistingFDConnectBeforeReaderStart {
                    failNextExistingFDConnectBeforeReaderStart = false
                    throw DebugExistingFDConnectFailure()
                }
            #endif

            try startReadSource(fd: socketFD)
            isConnected = true
            isStopping = false
            lastActivityTime = Date()
            unixSocketMCPTransportDebugLog("started with existing FD \(socketFD)")
        } catch {
            tearDownSocket(
                error: error,
                cause: .connectFailure,
                initiator: .transport,
                errno: Self.errnoValue(from: error)
            )
            throw error
        }
    }

    private nonisolated static func errnoValue(from error: Swift.Error) -> Int32? {
        if let posixError = error as? POSIXError {
            return posixError.code.rawValue
        }
        return nil
    }

    private nonisolated static func readErrorInitiator(errno: Int32?) -> MCPTerminalInitiator {
        errno == ECONNRESET ? .peer : .transport
    }

    private nonisolated static func isPeerWriteHangupErrno(_ errno: Int32) -> Bool {
        errno == EPIPE || errno == ECONNRESET || errno == ENOTCONN
    }

    #if DEBUG
        private struct DebugExistingFDConnectFailure: Swift.Error {}

        func debugSocketHasCloseOnExec() -> Bool? {
            guard socketFD >= 0 else { return nil }
            let flags = fcntl(socketFD, F_GETFD)
            guard flags >= 0 else { return nil }
            return flags & FD_CLOEXEC != 0
        }

        func debugFailNextExistingFDConnectBeforeReaderStart() {
            failNextExistingFDConnectBeforeReaderStart = true
        }

        func debugDeferNextReceiveOverflowTeardown() {
            deferNextReceiveOverflowTeardown = true
        }

        func debugHoldReaderTerminalCallback() {
            callbackGate.hold(.terminal)
        }

        func debugReleaseReaderTerminalCallbacks() {
            callbackGate.release(.terminal)
        }

        func debugHoldReaderCancellationCallback() {
            callbackGate.hold(.cancellation)
        }

        func debugReleaseReaderCancellationCallbacks() {
            callbackGate.release(.cancellation)
        }

        func debugSetBeforeInboundFrameOfferForTesting(
            _ handler: (@Sendable () -> Void)?
        ) {
            debugBeforeInboundFrameOfferForTesting = handler
        }

        func debugSetAfterWriteProgressForTesting(
            _ handler: (@Sendable (_ bytesWritten: Int) -> Void)?
        ) {
            debugAfterWriteProgressForTesting = handler
        }

        func debugTriggerReadErrorForCleanupTest(_ code: POSIXErrorCode = .EIO) {
            guard let identity = activeReaderOwnership?.identity else { return }
            handleReaderTerminal(.error(POSIXError(code)), from: identity)
        }

        func debugCleanupSnapshot() -> UnixSocketMCPTransportCleanupSnapshot {
            UnixSocketMCPTransportCleanupSnapshot(
                hasActiveReader: activeReaderOwnership != nil,
                pendingReaderCancellationCount: pendingReaderCancellations.count,
                earlyReaderCancellationCount: earlyReaderCancellations.count,
                readerIsRetained: debugLastReader != nil,
                terminalCallbackCount: debugTerminalCallbackCount,
                pendingTerminalCallbackCount: callbackGate.pendingCount(.terminal),
                cancellationCallbackCount: debugCancellationCallbackCount,
                finalizationCount: debugReaderFinalizationCount,
                descriptorCloseCount: debugDescriptorCloseCount,
                staleCancellationCount: debugStaleCancellationCount,
                staleTerminalCount: debugStaleTerminalCount,
                socketIsOwned: socketFD >= 0
            )
        }
    #endif

    private nonisolated func scheduleReaderTerminalCallback(_ callback: @escaping @Sendable () -> Void) {
        #if DEBUG
            callbackGate.submit(.terminal, callback: callback)
        #else
            callback()
        #endif
    }

    private nonisolated func scheduleReaderCancellationCallback(_ callback: @escaping @Sendable () -> Void) {
        #if DEBUG
            callbackGate.submit(.cancellation, callback: callback)
        #else
            callback()
        #endif
    }

    private nonisolated static func ensureNonBlocking(fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else {
            throw MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EBADF))
        }
        guard flags & O_NONBLOCK == 0 else { return }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
    }

    /// Writes all data to the socket, handling partial writes.
    /// Uses non-blocking writes plus bounded POLLOUT waits for backpressure.
    /// The stall deadline resets whenever any bytes are successfully written.
    /// Guards against FD reuse races by checking fdGeneration after each sleep.
    private func writeAll(
        _ data: Data,
        responseDeadline: MCPExportResponseDeliveryDeadlineRegistry.Deadline?
    ) async throws {
        // Fast-fail if we're obviously disconnected
        guard isConnected, socketFD >= 0 else {
            throw MCPError.connectionClosed
        }

        // Capture the FD and the connection generation at the time this write starts.
        // fdGeneration protects against FD reuse; if the connection closes and
        // reconnects (possibly with the same FD number), generation will differ.
        let fd = socketFD
        let gen = fdGeneration
        do {
            try Self.ensureNonBlocking(fd: fd)
        } catch {
            closeAfterSendFailure(error, cause: .writeFailure, errno: Self.errnoValue(from: error))
            throw error
        }
        var remaining = data
        var lastProgressAt = Date()

        while !remaining.isEmpty {
            try Task.checkCancellation()
            try enforceResponseDeliveryDeadline(responseDeadline, framedByteCount: data.count)
            // Re-check that we're still talking to the same connection epoch.
            guard isConnected, fdGeneration == gen else {
                throw MCPError.connectionClosed
            }
            if Date().timeIntervalSince(lastProgressAt) >= writeStallTimeout {
                let error = MCPError.transportError(UnixSocketWriteStalledError(
                    stallTimeout: writeStallTimeout,
                    bytesRemaining: remaining.count,
                    totalBytes: data.count
                ))
                closeAfterSendFailure(error, cause: .writeStall)
                throw error
            }

            let written = remaining.withUnsafeBytes { buf in
                Darwin.write(fd, buf.baseAddress!, buf.count)
            }

            if written < 0 {
                let err = errno
                if err == EINTR {
                    continue // Interrupted, retry
                } else if err == EAGAIN || err == EWOULDBLOCK {
                    try waitForSocketWritable(
                        fd: fd,
                        generation: gen,
                        lastProgressAt: lastProgressAt,
                        totalBytes: data.count,
                        bytesRemaining: remaining.count,
                        responseDeadline: responseDeadline
                    )
                    continue
                } else if Self.isPeerWriteHangupErrno(err) {
                    closeAfterSendFailure(MCPError.connectionClosed, cause: .writeHangup, initiator: .peer, errno: err)
                    throw MCPError.connectionClosed
                } else {
                    let error = MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO))
                    closeAfterSendFailure(error, cause: .writeFailure, errno: err)
                    throw error
                }
            } else if written == 0 {
                // On sockets, a 0-length write generally means closed / unusable
                closeAfterSendFailure(MCPError.connectionClosed, cause: .writeHangup, initiator: .peer)
                throw MCPError.connectionClosed
            }

            remaining = remaining.dropFirst(written)
            lastProgressAt = Date()
            #if DEBUG
                debugAfterWriteProgressForTesting?(written)
            #endif
            try enforceResponseDeliveryDeadline(responseDeadline, framedByteCount: data.count)
        }
    }

    private func waitForSocketWritable(
        fd: Int32,
        generation: UInt64,
        lastProgressAt: Date,
        totalBytes: Int,
        bytesRemaining: Int,
        responseDeadline: MCPExportResponseDeliveryDeadlineRegistry.Deadline?
    ) throws {
        while true {
            try Task.checkCancellation()
            try enforceResponseDeliveryDeadline(responseDeadline, framedByteCount: totalBytes)
            guard isConnected, fdGeneration == generation else {
                throw MCPError.connectionClosed
            }

            let remainingStallSeconds = writeStallTimeout - Date().timeIntervalSince(lastProgressAt)
            if remainingStallSeconds <= 0 {
                let error = MCPError.transportError(UnixSocketWriteStalledError(
                    stallTimeout: writeStallTimeout,
                    bytesRemaining: bytesRemaining,
                    totalBytes: totalBytes
                ))
                closeAfterSendFailure(error, cause: .writeStall)
                throw error
            }

            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let remainingMs = max(1, Int32(remainingStallSeconds * 1000))
            let deadlineMs = responseDeadline.map {
                max(0, Int32(min(TimeInterval(Int32.max), $0.remainingSeconds * 1000)))
            } ?? Int32.max
            let pollTimeout = min(writePollIntervalMilliseconds, min(remainingMs, deadlineMs))
            let result = poll(&pfd, 1, pollTimeout)

            if result < 0 {
                if errno == EINTR { continue }
                let err = errno
                let error = MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO))
                closeAfterSendFailure(error, cause: .writeFailure, errno: err)
                throw error
            }

            if result == 0 {
                continue
            }

            if pfd.revents & Int16(POLLNVAL) != 0 {
                let error = MCPError.transportError(POSIXError(.EBADF))
                closeAfterSendFailure(error, cause: .writeFailure, errno: EBADF)
                throw error
            }

            if pfd.revents & Int16(POLLHUP | POLLERR) != 0 {
                closeAfterSendFailure(MCPError.connectionClosed, cause: .writeHangup, initiator: .peer)
                throw MCPError.connectionClosed
            }

            if pfd.revents & Int16(POLLOUT) != 0 {
                return
            }
        }
    }

    private func enforceResponseDeliveryDeadline(
        _ deadline: MCPExportResponseDeliveryDeadlineRegistry.Deadline?,
        framedByteCount: Int
    ) throws {
        guard deadline?.hasExpired == true else { return }
        let error = MCPError.transportError(UnixSocketResponseDeliveryDeadlineExceededError(
            framedByteCount: framedByteCount
        ))
        closeAfterSendFailure(error, cause: .writeFailure)
        throw error
    }

    private func closeAfterSendFailure(
        _ error: Swift.Error,
        cause: MCPTransportTerminalCause,
        initiator: MCPTerminalInitiator = .transport,
        errno: Int32? = nil
    ) {
        logger.error("UnixSocketMCPTransport send failed; closing transport: \(String(describing: error))")
        tearDownSocket(
            error: error,
            cause: cause,
            initiator: initiator,
            errno: errno
        )
    }

    private struct UnixSocketResponseDeliveryDeadlineExceededError: Swift.Error, CustomStringConvertible {
        let framedByteCount: Int

        var description: String {
            "Unix socket response delivery exceeded its absolute deadline (frame bytes: \(framedByteCount))"
        }
    }

    private struct UnixSocketWriteStalledError: Swift.Error, CustomStringConvertible {
        let stallTimeout: TimeInterval
        let bytesRemaining: Int
        let totalBytes: Int

        var description: String {
            "Unix socket write made no progress for \(stallTimeout)s (remaining \(bytesRemaining)/\(totalBytes) bytes)"
        }
    }

    // MARK: - DispatchSourceRead Event-Driven Receive

    /// Starts the DispatchSourceRead to receive data without polling.
    private func startReadSource(fd: Int32) throws {
        try ReadSourceFDPreflight.validateOpenFD(fd, label: "UnixSocketMCPTransport read socket")
        stopReadSource()

        nextReadSourceToken &+= 1
        let identity = ReaderIdentity(
            fd: fd,
            token: nextReadSourceToken,
            socketOwnershipGeneration: socketOwnershipGeneration
        )

        let inboundChannel = inboundChannel
        let log = logger
        #if DEBUG
            let debugBeforeInboundFrameOfferForTesting = debugBeforeInboundFrameOfferForTesting
        #endif

        let newReader = NewlineDelimitedSocketReader(
            fd: fd,
            queue: readQueue,
            logger: log,
            onFrame: { [weak self] frame in
                guard let self else { return }
                responseDeliveryGate.recordAcceptedClientFrame(frame)
                let dispatchFrame: Data = if let timelineConnectionID {
                    MCPExportResponseDeliveryDeadlineRegistry.shared.recordAcceptedClientFrame(
                        frame,
                        connectionID: timelineConnectionID,
                        connectionGeneration: timelineConnectionGeneration
                    )
                } else {
                    frame
                }
                #if DEBUG
                    let recordedTimelineRequests: [MCPRequestTimelineRegistry.RecordedMessage] = if let timelineConnectionID {
                        MCPRequestTimelineRegistry.shared.recordAcceptedFrame(
                            frame,
                            connectionID: timelineConnectionID,
                            correlationConnectionID: timelineCorrelationConnectionID ?? timelineConnectionID,
                            connectionGeneration: timelineConnectionGeneration
                        )
                    } else {
                        []
                    }
                    // Handler dispatch can run as soon as offer resumes a waiting consumer,
                    // so correlation identity must already be claimable at this boundary.
                    debugBeforeInboundFrameOfferForTesting?()
                #endif
                switch inboundChannel.gate.offer(dispatchFrame, to: inboundChannel.continuation) {
                case .accepted:
                    #if DEBUG
                        if let timelineConnectionID {
                            for request in recordedTimelineRequests {
                                MCPResponseDeliveryTracer.emit(MCPResponseDeliveryTraceEvent(
                                    layer: "app_uds_transport",
                                    phase: "frame_accepted",
                                    connectionID: request.identity.connectionID ?? timelineCorrelationConnectionID,
                                    connectionGeneration: timelineConnectionGeneration,
                                    direction: .clientToServer,
                                    id: request.metadata.id,
                                    method: request.metadata.method,
                                    tool: request.metadata.tool,
                                    requestOrdinal: request.metadata.requestOrdinal,
                                    framedByteCount: frame.count,
                                    framedSHA256: MCPResponseDeliveryTracer.sha256Hex(frame),
                                    requestIdentity: request.identity
                                ))
                            }
                        }
                    #endif
                    mcpTransportLog("UnixSocketMCPTransport accepted message of \(frame.count) bytes")
                case let .overflow(error):
                    mcpConnectionLog("UnixSocketMCPTransport receive buffer overflow; terminating connection")
                    let transport = self
                    Task { await transport.handleReceiveBufferOverflow(error, from: identity) }
                case .terminal:
                    break
                }
            },
            onTerminal: { [weak self] terminal in
                guard let transport = self else { return }
                transport.scheduleReaderTerminalCallback {
                    Task { await transport.handleReaderTerminal(terminal, from: identity) }
                }
            },
            onBytesRead: { [weak self] in
                guard let transport = self else { return }
                Task { await transport.noteActivity(from: identity) }
            },
            onCancel: { [weak self] in
                guard let transport = self else { return }
                mcpConnectionLog(
                    "UnixSocketMCPTransport read source cancelled for fd=\(identity.fd) token=\(identity.token)"
                )
                transport.scheduleReaderCancellationCallback {
                    Task { await transport.readSourceDidCancel(identity) }
                }
            }
        )

        activeReaderOwnership = ActiveReaderOwnership(identity: identity, reader: newReader)
        #if DEBUG
            debugLastReader = newReader
        #endif
        do {
            try newReader.start()
        } catch {
            if activeReaderOwnership?.identity == identity {
                activeReaderOwnership = nil
            }
            throw error
        }
        mcpConnectionLog("UnixSocketMCPTransport read source started for fd=\(fd)")
    }

    /// Moves active reader ownership to the cancellation finalizer before requesting cancellation.
    private func stopReadSource() {
        guard let activeOwnership = activeReaderOwnership else { return }
        activeReaderOwnership = nil

        let identity = activeOwnership.identity
        pendingReaderCancellations[identity.token] = PendingReaderCancellation(
            identity: identity,
            reader: activeOwnership.reader,
            transportRetainer: self
        )
        activeOwnership.reader.stop()

        if earlyReaderCancellations.contains(identity) {
            finalizeReaderCancellation(identity)
        }
    }

    private func pendingReaderCancellationOwnsCurrentSocket() -> Bool {
        pendingReaderCancellations.values.contains { ownership in
            ownership.identity.fd == socketFD &&
                ownership.identity.socketOwnershipGeneration == socketOwnershipGeneration
        }
    }

    /// Called by the read source's cancel handler. Cancellation may beat terminal teardown.
    private func readSourceDidCancel(_ identity: ReaderIdentity) {
        #if DEBUG
            debugCancellationCallbackCount += 1
        #endif

        if pendingReaderCancellations[identity.token]?.identity == identity {
            finalizeReaderCancellation(identity)
            return
        }

        if activeReaderOwnership?.identity == identity {
            earlyReaderCancellations.insert(identity)
            return
        }

        #if DEBUG
            debugStaleCancellationCount += 1
        #endif
    }

    /// Sole final-close owner for a reader cancellation identity.
    private func finalizeReaderCancellation(_ identity: ReaderIdentity) {
        guard pendingReaderCancellations[identity.token]?.identity == identity,
              let ownership = pendingReaderCancellations.removeValue(forKey: identity.token)
        else {
            return
        }
        earlyReaderCancellations.remove(identity)
        withExtendedLifetime(ownership) {
            #if DEBUG
                debugReaderFinalizationCount += 1
            #endif

            if socketFD == identity.fd,
               socketOwnershipGeneration != identity.socketOwnershipGeneration
            {
                logger.warning(
                    "UnixSocketMCPTransport skipping stale reader cancellation close for reused fd=\(identity.fd)"
                )
                return
            }

            Darwin.close(identity.fd)
            #if DEBUG
                debugDescriptorCloseCount += 1
            #endif
            if socketFD == identity.fd {
                socketFD = -1
                socketOwnershipGeneration &+= 1
            }
        }
    }

    private func handleReceiveBufferOverflow(
        _ error: MCPReceiveBufferOverflowError,
        from identity: ReaderIdentity
    ) {
        guard activeReaderOwnership?.identity == identity else { return }
        guard !streamFinished else { return }
        #if DEBUG
            if deferNextReceiveOverflowTeardown {
                deferNextReceiveOverflowTeardown = false
                return
            }
        #endif
        tearDownSocket(
            error: error,
            cause: .receiveBufferOverflow,
            initiator: .transport
        )
    }

    private func handleReaderTerminal(
        _ terminal: NewlineDelimitedSocketReaderTerminal,
        from identity: ReaderIdentity
    ) {
        #if DEBUG
            debugTerminalCallbackCount += 1
        #endif

        guard activeReaderOwnership?.identity == identity else {
            #if DEBUG
                debugStaleTerminalCount += 1
            #endif
            return
        }

        switch terminal {
        case let .error(error):
            let errorNumber = Self.errnoValue(from: error)
            tearDownSocket(
                error: error,
                cause: .readError,
                initiator: Self.readErrorInitiator(errno: errorNumber),
                errno: errorNumber
            )
        case let .eof(hasResidualData):
            mcpConnectionLog("UnixSocketMCPTransport received EOF")
            guard hasResidualData else {
                tearDownSocket(
                    error: nil,
                    cause: .peerEOF,
                    initiator: .peer
                )
                return
            }
            // Treat residual incomplete frame as a protocol error
            let truncationError = MCPError.internalError("Connection closed with incomplete frame data")
            tearDownSocket(
                error: truncationError,
                cause: .incompleteEOF,
                initiator: .peer
            )
        }
    }

    /// Single entry point for transitioning to closed state.
    /// Finishes streams and signals closed, idempotently.
    private func transitionToClosed(error: Swift.Error?) {
        isConnected = false

        // Increment generation to invalidate any in-flight writers.
        // This protects against FD reuse races where an old writer might
        // otherwise write to a new connection that happens to get the same FD.
        fdGeneration &+= 1

        finishStream(error: error)
        signalClosedOnce()
    }

    /// Updates the activity timestamp (called from read handler).
    private func noteActivity(from identity: ReaderIdentity) {
        guard activeReaderOwnership?.identity == identity else { return }
        lastActivityTime = Date()
    }

    /// Finishes the message stream exactly once.
    private func finishStream(error: Swift.Error? = nil) {
        guard !streamFinished else { return }
        streamFinished = true
        if let error {
            inboundChannel.continuation.finish(throwing: error)
        } else {
            inboundChannel.continuation.finish()
        }
    }

    /// Signals the close stream exactly once.
    private func signalClosedOnce() {
        guard !closeSignaled else { return }
        closeSignaled = true
        if let firstCloseSnapshot {
            closeChannel.continuation.yield(firstCloseSnapshot)
        }
        closeChannel.continuation.finish()
    }
}
