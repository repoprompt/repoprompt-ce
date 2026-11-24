import Foundation
import OSLog
import RepoPromptIrohTransport
import RepoPromptRemoteProtocol

enum RemoteIrohPhoneReadiness: Equatable {
    case offline
    case syncing
    case legacyActive
    case connected
}

struct RemoteIrohGatewayDiagnostics: Equatable {
    var state = "stopped"
    var endpointID: String?
    var path: RemoteIrohPathKind = .unknown
    var activePeerCount = 0
    var phoneReadiness: RemoteIrohPhoneReadiness = .offline
    var lastTransitionAt: Date?
    var lastError: String?
    var lastSyncedActivityAt: Date?
}

/// Production framed-QUIC adapter. Rust owns Iroh/QUIC and reports the
/// cryptographically authenticated peer endpoint for every request; Swift
/// performs pairing, credential/binding checks, routing, and Codable framing.
@MainActor
final class RemoteIrohGatewayAdapter {
    private static let unpairLogger = Logger(subsystem: "com.pvncher.repoprompt.ce", category: "RemoteUnpair")

    typealias StateChanged = (RemoteIrohGatewayDiagnostics) -> Void
    typealias RequestCallback = () -> Void

    struct SyncState {
        let sessionID: UUID?
        private(set) var ticket: UUID?
        private(set) var lastActivityAt: Date?
        private(set) var hasConfirmedSync = false

        init(sessionID: UUID?) {
            self.sessionID = sessionID
        }

        mutating func issueTicket() -> UUID? {
            guard sessionID != nil, !hasConfirmedSync else { return nil }
            if let ticket {
                return ticket
            }
            let ticket = UUID()
            self.ticket = ticket
            return ticket
        }

        mutating func confirm(_ ticket: UUID, at date: Date = Date()) -> Bool {
            guard ticket == self.ticket else { return false }
            hasConfirmedSync = true
            recordActivity(at: date)
            return true
        }

        mutating func recordActivity(at date: Date = Date()) {
            lastActivityAt = date
        }

        func readiness(at date: Date = Date()) -> RemoteIrohPhoneReadiness {
            guard let lastActivityAt, date.timeIntervalSince(lastActivityAt) < 25 else {
                return .offline
            }
            if hasConfirmedSync {
                return .connected
            }
            return sessionID == nil ? .legacyActive : .syncing
        }
    }

    private struct Session {
        let deviceID: String
        let authorizationHeader: String
        var sync: SyncState

        func context(endpointID: String) -> RemoteGatewayRequestContext {
            .init(endpointID: endpointID, deviceID: deviceID, authorizationHeader: authorizationHeader)
        }
    }

    private let router: RemoteGatewayRequestRouter
    private let authenticationUnavailable: () -> Bool
    private let stateChanged: StateChanged
    private let requestReceived: RequestCallback
    private let successfulResponseSent: RequestCallback
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var endpoint: TransportEndpoint?
    private var acceptTask: Task<Void, Never>?
    private var sessions: [String: Session] = [:]
    private var diagnostics = RemoteIrohGatewayDiagnostics()
    private var serverAddress: RemoteIrohEndpointAddress?
    private var desktopInstanceID: String?
    private var activeGeneration: UInt64?

    init(
        router: RemoteGatewayRequestRouter,
        authenticationUnavailable: @escaping () -> Bool = { false },
        stateChanged: @escaping StateChanged = { _ in },
        requestReceived: @escaping RequestCallback = {},
        successfulResponseSent: @escaping RequestCallback = {}
    ) {
        self.router = router
        self.authenticationUnavailable = authenticationUnavailable
        self.stateChanged = stateChanged
        self.requestReceived = requestReceived
        self.successfulResponseSent = successfulResponseSent
    }

    var currentAddress: RemoteIrohEndpointAddress? {
        if let endpoint, let snapshot = try? endpoint.snapshot() {
            return .init(endpointID: snapshot.endpointId, transportAddressJSON: snapshot.addressJson)
        }
        return serverAddress
    }

    func refreshLiveness() {
        publishSessionCount()
    }

    func start(
        secret: Data,
        desktopInstanceID: String,
        relayEnabled: Bool = true,
        generation: UInt64
    ) async throws -> RemoteIrohEndpointAddress {
        guard endpoint == nil else {
            guard let serverAddress else { throw RemoteIrohGatewayAdapterError.notRunning }
            return serverAddress
        }
        activeGeneration = generation
        update { $0.state = "starting" }
        var candidate: TransportEndpoint?
        do {
            let endpoint = try await RepoPromptIrohSpike.startApplication(
                secret: secret,
                relayEnabled: relayEnabled,
                generation: generation
            )
            candidate = endpoint
            let snapshot: EndpointSnapshot = if let onlineSnapshot = try? await endpoint.waitUntilOnline(timeoutMillis: 5000) {
                onlineSnapshot
            } else {
                try endpoint.snapshot()
            }
            guard activeGeneration == generation else { throw CancellationError() }
            guard !snapshot.endpointId.isEmpty else {
                throw RemoteIrohGatewayAdapterError.invalidEndpoint
            }
            let address = RemoteIrohEndpointAddress(
                endpointID: snapshot.endpointId,
                transportAddressJSON: snapshot.addressJson
            )
            self.endpoint = endpoint
            self.desktopInstanceID = desktopInstanceID
            serverAddress = address
            update {
                $0.state = "running"
                $0.endpointID = snapshot.endpointId
                $0.lastError = nil
            }
            startAcceptLoop(endpoint)
            return address
        } catch {
            if let candidate { try? await candidate.shutdown() }
            if activeGeneration == generation {
                activeGeneration = nil
                update {
                    $0.state = "failed"
                    $0.lastError = error.localizedDescription
                }
            }
            throw error
        }
    }

    func stop() {
        acceptTask?.cancel()
        acceptTask = nil
        sessions.removeAll()
        let stopping = endpoint
        endpoint = nil
        serverAddress = nil
        desktopInstanceID = nil
        activeGeneration = nil
        update {
            $0.state = "stopped"
            $0.activePeerCount = 0
            $0.phoneReadiness = .offline
            $0.lastSyncedActivityAt = nil
            $0.path = .unknown
        }
        if let stopping {
            Task { try? await stopping.shutdown() }
        }
    }

    func revokePeerSessions() {
        sessions.removeAll()
        publishSessionCount()
    }

    private func startAcceptLoop(_ endpoint: TransportEndpoint) {
        acceptTask?.cancel()
        acceptTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let request = try await endpoint.acceptRequest()
                    guard !Task.isCancelled else {
                        request.close()
                        return
                    }
                    if diagnostics.state == "degraded" {
                        update {
                            $0.state = "running"
                            $0.lastError = nil
                        }
                    }
                    Task { @MainActor [weak self] in
                        await self?.handle(request)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    update {
                        $0.state = "degraded"
                        $0.lastError = error.localizedDescription
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    private func handle(_ request: IncomingRequest) async {
        guard request.generation() == activeGeneration else {
            request.close()
            return
        }
        let peerEndpointID = request.peerEndpointId()
        requestReceived()
        update {
            $0.path = Self.pathKind(from: request.pathSummary())
            $0.lastError = nil
        }

        var messageID: UUID?
        do {
            let data = request.payload()
            guard data.count <= RemoteWireProtocol.maximumClientFrameBytes else {
                throw RemoteIrohGatewayAdapterError.frameTooLarge
            }
            let frame = try decoder.decode(RemoteWireFrame.self, from: data)
            messageID = frame.messageID
            let isUnpairRequest = isUnpairRPC(frame)
            let originalContext: RemoteGatewayRequestContext? = if !isUnpairRequest,
                                                                   frame.kind == .rpcRequest || frame.kind == .eventSubscribe
            {
                try authenticatedSession(peerEndpointID, sessionID: frame.sessionID).context(endpointID: peerEndpointID)
            } else {
                nil
            }
            let response = try await response(
                to: frame,
                peerEndpointID: peerEndpointID
            )
            let encoded = try encoder.encode(response)
            let direction: RemoteWireDirection = response.kind == .event ? .serverEvent : .serverResponse
            guard encoded.count <= direction.maximumEncodedFrameBytes else {
                throw RemoteIrohGatewayAdapterError.responseTooLarge
            }
            guard request.generation() == activeGeneration else {
                request.close()
                return
            }
            if let originalContext {
                guard router.isAuthorized(originalContext) else {
                    throw RemoteIrohGatewayAdapterError.unauthorizedPeer
                }
                _ = try authenticatedSession(peerEndpointID, sessionID: frame.sessionID)
            }
            if isUnpairRequest {
                Self.unpairLogger.info("Sending framed Iroh Unpair response after durable revocation")
            }
            try await request.respond(payload: encoded)
            if isUnpairRequest {
                Self.unpairLogger.info("Framed Iroh Unpair response delivery completed")
            }
            if request.generation() == activeGeneration, originalContext != nil,
               response.kind != .streamError,
               var session = try? authenticatedSession(peerEndpointID, sessionID: frame.sessionID)
            {
                session.sync.recordActivity()
                sessions[peerEndpointID] = session
                publishSessionCount()
                successfulResponseSent()
            }
        } catch {
            guard request.generation() == activeGeneration else {
                request.close()
                return
            }
            let frame = makeStreamError(error, messageID: messageID)
            if let encoded = try? encoder.encode(frame) {
                try? await request.respond(payload: encoded)
            } else {
                request.close()
            }
            update { $0.lastError = error.localizedDescription }
        }
    }

    private func isUnpairRPC(_ frame: RemoteWireFrame) -> Bool {
        guard frame.kind == .rpcRequest,
              let rpc = try? frame.decodedPayload(
                  as: RemoteRPCRequest.self,
                  expectedKind: .rpcRequest
              )
        else { return false }
        return rpc.operation == .unpair
    }

    private func response(
        to frame: RemoteWireFrame,
        peerEndpointID: String
    ) async throws -> RemoteWireFrame {
        guard frame.wireVersion == RemoteWireProtocol.currentVersion else {
            throw RemoteIrohGatewayAdapterError.unsupportedWireVersion
        }

        switch frame.kind {
        case .pairingHello:
            throw RemoteIrohGatewayAdapterError.remote(RemoteGatewaySecurityError.confirmationRequired.response)

        case .pairingPrepare:
            let hello = try frame.decodedPayload(as: RemotePairingHello.self, expectedKind: .pairingPrepare)
            let routed = await router.route(
                .pairIroh(hello.request, authenticatedPeerEndpointID: peerEndpointID),
                context: .init(endpointID: peerEndpointID, deviceID: "", authorizationHeader: nil)
            )
            let payload = try successfulJSON(from: routed)
            return RemoteWireFrame(kind: .helloAccepted, messageID: frame.messageID, payload: payload)

        case .pairingConfirm:
            let confirmation = try frame.decodedPayload(
                as: RemotePairingConfirmation.self,
                expectedKind: .pairingConfirm
            )
            do {
                try router.confirmIroh(confirmation, peerEndpointID: peerEndpointID)
            } catch {
                throw RemoteIrohGatewayAdapterError.remote(RemoteGatewayRequestRouter.pairingError(error))
            }
            return try RemoteWireFrame(
                kind: .pairingConfirmed, messageID: frame.messageID, encoding: confirmation.attemptID
            )

        case .syncConfirm:
            var session = try authenticatedSession(peerEndpointID, sessionID: frame.sessionID)
            let ticket = try frame.decodedPayload(as: UUID.self, expectedKind: .syncConfirm)
            guard session.sync.confirm(ticket) else {
                throw RemoteIrohGatewayAdapterError.syncRequired
            }
            sessions[peerEndpointID] = session
            publishSessionCount()
            return try RemoteWireFrame(kind: .syncConfirmed, messageID: frame.messageID, encoding: ticket)

        case .authenticatedHello:
            try checkCredentialStorage()
            let hello = try frame.decodedPayload(
                as: RemoteAuthenticatedHello.self,
                expectedKind: .authenticatedHello
            )
            guard RemoteProtocol.supports(hello.protocolVersion) else {
                throw RemoteIrohGatewayAdapterError.remote(.init(
                    code: "unsupported_protocol_version",
                    message: "This version of RepoPrompt Remote is not supported by the Mac."
                ))
            }
            guard hello.expectedServerEndpointID == serverAddress?.endpointID,
                  hello.desktopInstanceID == desktopInstanceID
            else {
                throw RemoteIrohGatewayAdapterError.serverEndpointMismatch
            }
            let context = RemoteGatewayRequestContext(
                endpointID: peerEndpointID, deviceID: hello.deviceID,
                authorizationHeader: "Bearer \(hello.credential)"
            )
            guard router.isAuthorized(context) else {
                throw RemoteIrohGatewayAdapterError.unauthorizedPeer
            }
            let sessionID = hello.supportsSyncConfirmation == true ? UUID() : nil
            var sync = SyncState(sessionID: sessionID)
            sync.recordActivity()
            sessions[peerEndpointID] = Session(
                deviceID: hello.deviceID,
                authorizationHeader: "Bearer \(hello.credential)",
                sync: sync
            )
            publishSessionCount()
            let accepted = RemoteHelloAccepted(
                desktopInstanceID: desktopInstanceID ?? "",
                serverEndpointID: serverAddress?.endpointID ?? "",
                clientEndpointID: peerEndpointID,
                deviceID: hello.deviceID,
                sessionID: sessionID,
                serverAddress: currentAddress
            )
            return try RemoteWireFrame(kind: .helloAccepted, messageID: frame.messageID, encoding: accepted)

        case .rpcRequest:
            let session = try authenticatedSession(peerEndpointID, sessionID: frame.sessionID)
            let rpc = try frame.decodedPayload(as: RemoteRPCRequest.self, expectedKind: .rpcRequest)
            let request = try gatewayRequest(for: rpc)
            if case .command = request, session.sync.sessionID != nil, !session.sync.hasConfirmedSync {
                throw RemoteIrohGatewayAdapterError.syncRequired
            }
            if case .unpair = request {
                Self.unpairLogger.info("Iroh Unpair RPC received over authenticated peer path")
            }
            let routed = await router.route(
                request,
                context: .init(
                    endpointID: peerEndpointID, deviceID: session.deviceID,
                    authorizationHeader: session.authorizationHeader
                )
            )
            if case .unpair = request {
                if (200 ..< 300).contains(routed.status) {
                    Self.unpairLogger.info("Iroh Unpair RPC produced a successful revocation response")
                } else {
                    Self.unpairLogger.error("Iroh Unpair RPC failed with status \(routed.status, privacy: .public)")
                }
            }
            var ticket: UUID?
            if rpc.operation == .snapshot, case .json = routed.content {
                var current = try authenticatedSession(peerEndpointID, sessionID: frame.sessionID)
                ticket = current.sync.issueTicket()
                sessions[peerEndpointID] = current
            }
            let rpcResponse = rpcResponse(from: routed, syncTicket: ticket)
            return try RemoteWireFrame(
                kind: .rpcResponse,
                messageID: frame.messageID,
                encoding: rpcResponse
            )

        case .eventSubscribe:
            let session = try authenticatedSession(peerEndpointID, sessionID: frame.sessionID)
            let subscription = try frame.decodedPayload(
                as: RemoteEventSubscriptionRequest.self,
                expectedKind: .eventSubscribe
            )
            guard subscription.desktopInstanceID == desktopInstanceID else {
                throw RemoteIrohGatewayAdapterError.serverEndpointMismatch
            }
            let routed = await router.route(
                .events(after: subscription.after),
                context: .init(
                    endpointID: peerEndpointID, deviceID: session.deviceID,
                    authorizationHeader: session.authorizationHeader
                )
            )
            switch routed.content {
            case let .events(events):
                if events.isEmpty {
                    return try RemoteWireFrame(
                        kind: .heartbeat,
                        messageID: frame.messageID,
                        encoding: RemoteHeartbeat()
                    )
                }
                return try boundedEventFrame(events, messageID: frame.messageID)
            case let .error(error):
                return try RemoteWireFrame(kind: .streamError, messageID: frame.messageID, encoding: error)
            case .json:
                throw RemoteIrohGatewayAdapterError.invalidRouterResponse
            }

        case .helloAccepted, .pairingConfirmed, .syncConfirmed, .rpcResponse, .event, .heartbeat, .streamError:
            throw RemoteIrohGatewayAdapterError.unexpectedClientFrame
        }
    }

    private func boundedEventFrame(
        _ events: [RemoteEvent],
        messageID: UUID?
    ) throws -> RemoteWireFrame {
        var selected: [RemoteEvent] = []
        for event in events.prefix(64) {
            let candidate = try RemoteWireFrame(
                kind: .event,
                messageID: messageID,
                encoding: selected + [event]
            )
            do {
                try candidate.validateEncodedLimit(direction: .serverEvent)
                selected.append(event)
            } catch RemoteWireContractError.frameTooLarge {
                break
            }
        }
        guard !selected.isEmpty else {
            return try RemoteWireFrame(
                kind: .streamError,
                messageID: messageID,
                encoding: RemoteErrorResponse(
                    code: "snapshot_required",
                    message: "The next event exceeds the replay limit. Refresh the snapshot.",
                    retryable: true
                )
            )
        }
        return try RemoteWireFrame(kind: .event, messageID: messageID, encoding: selected)
    }

    private func checkCredentialStorage() throws {
        if authenticationUnavailable() {
            throw RemoteIrohGatewayAdapterError.remote(.init(
                code: "pairing_storage_unavailable",
                message: "Open Remote settings on the Mac to recover its pairing storage.",
                retryable: true
            ))
        }
    }

    private func authenticatedSession(_ peerEndpointID: String, sessionID: UUID?) throws -> Session {
        try checkCredentialStorage()
        guard let session = sessions[peerEndpointID], sessionID == session.sync.sessionID else {
            throw RemoteIrohGatewayAdapterError.sessionRequired
        }
        let context = RemoteGatewayRequestContext(
            endpointID: peerEndpointID, deviceID: session.deviceID,
            authorizationHeader: session.authorizationHeader
        )
        guard router.isAuthorized(context) else {
            sessions.removeValue(forKey: peerEndpointID)
            publishSessionCount()
            throw RemoteIrohGatewayAdapterError.unauthorizedPeer
        }
        return session
    }

    private func gatewayRequest(for rpc: RemoteRPCRequest) throws -> RemoteGatewayRequest {
        switch rpc.operation {
        case .unpair: return .unpair
        case .snapshot: return .snapshot
        case .diagnostics: return .diagnostics
        case .workspaces: return .workspaces
        case .sessions: return .sessions
        case .agents: return .agents
        case .workflows: return .workflows
        case .history:
            let request = try decodePayload(RemoteHistoryRPCRequest.self, from: rpc.payload)
            return .history(request)
        case .transcript:
            let request = try decodePayload(RemoteTranscriptRPCRequest.self, from: rpc.payload)
            return .transcript(.init(
                sessionID: request.sessionID,
                paging: Self.transcriptPaging(for: request),
                limit: request.limit,
                includeDetails: request.includeDetails
            ))
        case .imageAttachment:
            return try .imageAttachment(decodePayload(RemoteImageAttachmentRequest.self, from: rpc.payload))
        case .command:
            return try .command(
                decodePayload(RemoteCommandRequest.self, from: rpc.payload),
                endpoint: .commands
            )
        case .contextBuilder:
            return try .command(
                decodePayload(RemoteCommandRequest.self, from: rpc.payload),
                endpoint: .contextBuilder
            )
        }
    }

    static func transcriptPaging(for request: RemoteTranscriptRPCRequest) -> RemoteTranscriptPageRequest {
        if let itemID = request.itemID {
            return .exactItem(itemID)
        }
        if request.pagingMode == .legacyForward {
            return .legacyForward(afterSequenceIndex: request.afterSequenceIndex)
        }
        if request.pagingMode == .recentBackward || request.before != nil {
            return .recentBackward(before: request.before)
        }
        // The first Iroh Remote build omitted pagingMode and sent a nil before
        // cursor for its initial recent-first page. Preserve that wire behavior.
        return .recentBackward(before: nil)
    }

    private func decodePayload<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do { return try decoder.decode(type, from: data) }
        catch { throw RemoteIrohGatewayAdapterError.malformedPayload }
    }

    private func successfulJSON(from response: RemoteGatewayResponse) throws -> Data {
        guard (200 ..< 300).contains(response.status) else {
            if case let .error(error) = response.content {
                throw RemoteIrohGatewayAdapterError.remote(error)
            }
            throw RemoteIrohGatewayAdapterError.invalidRouterResponse
        }
        guard case let .json(data) = response.content else {
            throw RemoteIrohGatewayAdapterError.invalidRouterResponse
        }
        return data
    }

    private func rpcResponse(from response: RemoteGatewayResponse, syncTicket: UUID?) -> RemoteRPCResponse {
        switch response.content {
        case let .json(data):
            RemoteRPCResponse(result: data, syncTicket: syncTicket)
        case let .error(error):
            RemoteRPCResponse(error: error)
        case .events:
            RemoteRPCResponse(error: .init(code: "invalid_response", message: "Invalid RPC response."))
        }
    }

    private func makeStreamError(_ error: Error, messageID: UUID?) -> RemoteWireFrame {
        let response: RemoteErrorResponse = switch error {
        case let RemoteIrohGatewayAdapterError.remote(remote): remote
        case RemoteIrohGatewayAdapterError.responseTooLarge:
            RemoteErrorResponse(code: "response_too_large", message: error.localizedDescription)
        case RemoteIrohGatewayAdapterError.sessionRequired:
            RemoteErrorResponse(code: "session_required", message: error.localizedDescription, retryable: true)
        case RemoteIrohGatewayAdapterError.syncRequired:
            RemoteErrorResponse(code: "sync_required", message: error.localizedDescription, retryable: true)
        case RemoteIrohGatewayAdapterError.unauthorizedPeer:
            RemoteErrorResponse(code: "unauthorized", message: error.localizedDescription)
        case RemoteIrohGatewayAdapterError.serverEndpointMismatch:
            RemoteErrorResponse(code: "endpoint_mismatch", message: error.localizedDescription)
        default:
            RemoteErrorResponse(code: "transport_error", message: error.localizedDescription)
        }
        return (try? RemoteWireFrame(kind: .streamError, messageID: messageID, encoding: response))
            ?? RemoteWireFrame(kind: .streamError, messageID: messageID)
    }

    private func update(_ mutation: (inout RemoteIrohGatewayDiagnostics) -> Void) {
        mutation(&diagnostics)
        diagnostics.lastTransitionAt = Date()
        stateChanged(diagnostics)
    }

    private func publishSessionCount() {
        let now = Date()
        let active = sessions.values.filter { $0.sync.readiness(at: now) != .offline }
        let lastSyncedActivity = active.filter(\.sync.hasConfirmedSync).compactMap(\.sync.lastActivityAt).max()
        let readiness = if lastSyncedActivity != nil {
            RemoteIrohPhoneReadiness.connected
        } else if active.contains(where: { $0.sync.sessionID != nil }) {
            RemoteIrohPhoneReadiness.syncing
        } else {
            active.isEmpty ? RemoteIrohPhoneReadiness.offline : .legacyActive
        }
        guard diagnostics.activePeerCount != active.count || diagnostics.phoneReadiness != readiness
            || diagnostics.lastSyncedActivityAt != lastSyncedActivity
        else {
            return
        }
        update {
            $0.activePeerCount = active.count
            $0.phoneReadiness = readiness
            $0.lastSyncedActivityAt = lastSyncedActivity
        }
    }

    private static func pathKind(from summary: String) -> RemoteIrohPathKind {
        let lower = summary.lowercased()
        if lower.contains("relay") { return .relay }
        if lower.contains("192.168.") || lower.contains("10.") || lower.contains("172.16.") {
            return .localDirect
        }
        if lower.contains("direct") || lower.contains("udp") { return .internetDirect }
        return .unknown
    }
}

enum RemoteIrohGatewayAdapterError: LocalizedError {
    case notRunning
    case invalidEndpoint
    case frameTooLarge
    case responseTooLarge
    case unsupportedWireVersion
    case serverEndpointMismatch
    case unauthorizedPeer
    case sessionRequired
    case syncRequired
    case unexpectedClientFrame
    case invalidRouterResponse
    case malformedPayload
    case remote(RemoteErrorResponse)

    var errorDescription: String? {
        switch self {
        case .notRunning: "The Iroh endpoint is not running."
        case .invalidEndpoint: "The Iroh endpoint did not provide a valid identity."
        case .responseTooLarge: "The Mac snapshot exceeds the Remote response limit. Close unused workspaces on the Mac and reconnect."
        case .frameTooLarge: "The Iroh request exceeded the one-megabyte limit."
        case .unsupportedWireVersion: "The Iroh wire version is unsupported."
        case .serverEndpointMismatch: "The authenticated server endpoint did not match the pairing record."
        case .sessionRequired: "The Mac session ended. Reconnect and sync again."
        case .syncRequired: "Confirm the first snapshot before using this session."
        case .unauthorizedPeer: "The authenticated Iroh peer is not paired."
        case .unexpectedClientFrame: "The client sent an unexpected Iroh frame."
        case .invalidRouterResponse: "The application router returned an invalid response."
        case .malformedPayload: "The Iroh request payload is malformed."
        case let .remote(error): error.message
        }
    }
}
