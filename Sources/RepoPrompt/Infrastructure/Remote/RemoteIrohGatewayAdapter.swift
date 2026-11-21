import Foundation
import OSLog
import RepoPromptIrohTransport
import RepoPromptRemoteProtocol

struct RemoteIrohGatewayDiagnostics: Equatable {
    var state = "stopped"
    var endpointID: String?
    var path: RemoteIrohPathKind = .unknown
    var activePeerCount = 0
    var lastTransitionAt: Date?
    var lastError: String?
}

/// Production framed-QUIC adapter. Rust owns Iroh/QUIC and reports the
/// cryptographically authenticated peer endpoint for every request; Swift
/// performs pairing, credential/binding checks, routing, and Codable framing.
@MainActor
final class RemoteIrohGatewayAdapter {
    private static let unpairLogger = Logger(subsystem: "com.pvncher.repoprompt.ce", category: "RemoteUnpair")

    typealias StateChanged = (RemoteIrohGatewayDiagnostics) -> Void
    typealias RequestCallback = () -> Void

    private struct Session {
        let deviceID: String
        let authorizationHeader: String
    }

    private let router: RemoteGatewayRequestRouter
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
        stateChanged: @escaping StateChanged = { _ in },
        requestReceived: @escaping RequestCallback = {},
        successfulResponseSent: @escaping RequestCallback = {}
    ) {
        self.router = router
        self.stateChanged = stateChanged
        self.requestReceived = requestReceived
        self.successfulResponseSent = successfulResponseSent
    }

    var currentAddress: RemoteIrohEndpointAddress? {
        serverAddress
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
        update { $0.state = "starting" }
        do {
            let endpoint = try await RepoPromptIrohSpike.startApplication(
                secret: secret,
                relayEnabled: relayEnabled,
                generation: generation
            )
            let snapshot: EndpointSnapshot = if let onlineSnapshot = try? await endpoint.waitUntilOnline(timeoutMillis: 5000) {
                onlineSnapshot
            } else {
                try endpoint.snapshot()
            }
            guard !snapshot.endpointId.isEmpty else {
                throw RemoteIrohGatewayAdapterError.invalidEndpoint
            }
            let address = RemoteIrohEndpointAddress(
                endpointID: snapshot.endpointId,
                transportAddressJSON: snapshot.addressJson
            )
            self.endpoint = endpoint
            self.desktopInstanceID = desktopInstanceID
            activeGeneration = generation
            serverAddress = address
            update {
                $0.state = "running"
                $0.endpointID = snapshot.endpointId
                $0.lastError = nil
            }
            startAcceptLoop(endpoint)
            return address
        } catch {
            update {
                $0.state = "failed"
                $0.lastError = error.localizedDescription
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
            $0.path = .unknown
        }
        if let stopping {
            Task { try? await stopping.shutdown() }
        }
    }

    func revokePeerSessions() {
        sessions.removeAll()
        update { $0.activePeerCount = 0 }
    }

    private func startAcceptLoop(_ endpoint: TransportEndpoint) {
        acceptTask?.cancel()
        acceptTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let request = try await endpoint.acceptRequest()
                    guard !Task.isCancelled else { return }
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

        do {
            let data = request.payload()
            guard data.count <= RemoteWireProtocol.maximumClientFrameBytes else {
                throw RemoteIrohGatewayAdapterError.frameTooLarge
            }
            let frame = try decoder.decode(RemoteWireFrame.self, from: data)
            try frame.validateEncodedLimit(direction: .clientToServer)
            let response = try await response(
                to: frame,
                peerEndpointID: peerEndpointID
            )
            let encoded = try encoder.encode(response)
            try response.validateEncodedLimit(
                direction: response.kind == .event ? .serverEvent : .serverResponse
            )
            let isUnpairRequest = isUnpairRPC(frame)
            if isUnpairRequest {
                Self.unpairLogger.info("Sending framed Iroh Unpair response after durable revocation")
            }
            try await request.respond(payload: encoded)
            if isUnpairRequest {
                Self.unpairLogger.info("Framed Iroh Unpair response delivery completed")
            }
            successfulResponseSent()
        } catch {
            let frame = makeStreamError(error)
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
            let hello = try frame.decodedPayload(as: RemotePairingHello.self, expectedKind: .pairingHello)
            let routed = await router.route(
                .pairIroh(hello.request, authenticatedPeerEndpointID: peerEndpointID),
                context: .init(transport: .authenticatedPeer(
                    endpointID: peerEndpointID,
                    deviceID: "pairing"
                ), authorizationHeader: nil)
            )
            let payload = try successfulJSON(from: routed)
            let pairing = try decoder.decode(RemoteIrohPairingResponse.self, from: payload)
            sessions.removeAll()
            sessions[peerEndpointID] = Session(
                deviceID: pairing.pairingResponse.deviceID,
                authorizationHeader: "Bearer \(pairing.pairingResponse.credential)"
            )
            publishSessionCount()
            return RemoteWireFrame(kind: .helloAccepted, messageID: frame.messageID, payload: payload)

        case .authenticatedHello:
            let hello = try frame.decodedPayload(
                as: RemoteAuthenticatedHello.self,
                expectedKind: .authenticatedHello
            )
            guard hello.expectedServerEndpointID == serverAddress?.endpointID,
                  hello.desktopInstanceID == desktopInstanceID
            else {
                throw RemoteIrohGatewayAdapterError.serverEndpointMismatch
            }
            let context = RemoteGatewayRequestContext(
                transport: .authenticatedPeer(endpointID: peerEndpointID, deviceID: hello.deviceID),
                authorizationHeader: "Bearer \(hello.credential)"
            )
            guard router.isAuthorized(context) else {
                sessions.removeValue(forKey: peerEndpointID)
                publishSessionCount()
                throw RemoteIrohGatewayAdapterError.unauthorizedPeer
            }
            sessions[peerEndpointID] = Session(
                deviceID: hello.deviceID,
                authorizationHeader: "Bearer \(hello.credential)"
            )
            publishSessionCount()
            let accepted = RemoteHelloAccepted(
                desktopInstanceID: desktopInstanceID ?? "",
                serverEndpointID: serverAddress?.endpointID ?? "",
                clientEndpointID: peerEndpointID,
                deviceID: hello.deviceID
            )
            return try RemoteWireFrame(kind: .helloAccepted, messageID: frame.messageID, encoding: accepted)

        case .rpcRequest:
            let session = try authenticatedSession(peerEndpointID)
            let rpc = try frame.decodedPayload(as: RemoteRPCRequest.self, expectedKind: .rpcRequest)
            let request = try gatewayRequest(for: rpc)
            if case .unpair = request {
                Self.unpairLogger.info("Iroh Unpair RPC received over authenticated peer path")
            }
            let routed = await router.route(
                request,
                context: .init(
                    transport: .authenticatedPeer(endpointID: peerEndpointID, deviceID: session.deviceID),
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
            let rpcResponse = rpcResponse(from: routed)
            return try RemoteWireFrame(
                kind: .rpcResponse,
                messageID: frame.messageID,
                encoding: rpcResponse
            )

        case .eventSubscribe:
            let session = try authenticatedSession(peerEndpointID)
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
                    transport: .authenticatedPeer(endpointID: peerEndpointID, deviceID: session.deviceID),
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

        case .helloAccepted, .rpcResponse, .event, .heartbeat, .streamError:
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
        guard !selected.isEmpty else { throw RemoteIrohGatewayAdapterError.frameTooLarge }
        return try RemoteWireFrame(kind: .event, messageID: messageID, encoding: selected)
    }

    private func authenticatedSession(_ peerEndpointID: String) throws -> Session {
        guard let session = sessions[peerEndpointID] else {
            throw RemoteIrohGatewayAdapterError.unauthorizedPeer
        }
        let context = RemoteGatewayRequestContext(
            transport: .authenticatedPeer(endpointID: peerEndpointID, deviceID: session.deviceID),
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
            return .history(query: request.query, limit: request.limit)
        case .transcript:
            let request = try decodePayload(RemoteTranscriptRPCRequest.self, from: rpc.payload)
            return .transcript(.init(
                sessionID: request.sessionID,
                paging: Self.transcriptPaging(for: request),
                limit: request.limit,
                includeDetails: request.includeDetails
            ))
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
        case .transportBootstrap:
            return .transportBootstrap
        case .bindIrohEndpoint:
            return try .bindIrohEndpoint(
                decodePayload(RemoteIrohBindingRequest.self, from: rpc.payload)
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

    private func rpcResponse(from response: RemoteGatewayResponse) -> RemoteRPCResponse {
        switch response.content {
        case let .json(data):
            RemoteRPCResponse(result: data)
        case let .error(error):
            RemoteRPCResponse(error: error)
        case .events:
            RemoteRPCResponse(error: .init(code: "invalid_response", message: "Invalid RPC response."))
        }
    }

    private func makeStreamError(_ error: Error) -> RemoteWireFrame {
        let response: RemoteErrorResponse = switch error {
        case let RemoteIrohGatewayAdapterError.remote(remote): remote
        case RemoteIrohGatewayAdapterError.unauthorizedPeer:
            RemoteErrorResponse(code: "unauthorized", message: error.localizedDescription)
        case RemoteIrohGatewayAdapterError.serverEndpointMismatch:
            RemoteErrorResponse(code: "endpoint_mismatch", message: error.localizedDescription)
        default:
            RemoteErrorResponse(code: "transport_error", message: error.localizedDescription)
        }
        return (try? RemoteWireFrame(kind: .streamError, encoding: response))
            ?? RemoteWireFrame(kind: .streamError)
    }

    private func update(_ mutation: (inout RemoteIrohGatewayDiagnostics) -> Void) {
        mutation(&diagnostics)
        diagnostics.lastTransitionAt = Date()
        stateChanged(diagnostics)
    }

    private func publishSessionCount() {
        update { $0.activePeerCount = sessions.count }
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
    case unsupportedWireVersion
    case serverEndpointMismatch
    case unauthorizedPeer
    case unexpectedClientFrame
    case invalidRouterResponse
    case malformedPayload
    case remote(RemoteErrorResponse)

    var errorDescription: String? {
        switch self {
        case .notRunning: "The Iroh endpoint is not running."
        case .invalidEndpoint: "The Iroh endpoint did not provide a valid identity."
        case .frameTooLarge: "The Iroh request exceeded the one-megabyte limit."
        case .unsupportedWireVersion: "The Iroh wire version is unsupported."
        case .serverEndpointMismatch: "The authenticated server endpoint did not match the pairing record."
        case .unauthorizedPeer: "The authenticated Iroh peer is not paired."
        case .unexpectedClientFrame: "The client sent an unexpected Iroh frame."
        case .invalidRouterResponse: "The application router returned an invalid response."
        case .malformedPayload: "The Iroh request payload is malformed."
        case let .remote(error): error.message
        }
    }
}
