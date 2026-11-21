import Foundation
import RepoPromptRemoteProtocol

enum RemoteGatewayTransportContext: Equatable {
    case legacyHTTPS
    case authenticatedPeer(endpointID: String, deviceID: String)
}

struct RemoteGatewayRequestContext: Equatable {
    let transport: RemoteGatewayTransportContext
    let authorizationHeader: String?

    static func legacyHTTPS(authorizationHeader: String?) -> Self {
        Self(transport: .legacyHTTPS, authorizationHeader: authorizationHeader)
    }
}

enum RemoteGatewayCommandEndpoint: Equatable {
    case commands
    case contextBuilder
}

struct RemoteGatewayTranscriptRequest: Equatable {
    let sessionID: UUID
    let paging: RemoteTranscriptPageRequest
    let limit: Int
    let includeDetails: Bool
}

enum RemoteGatewayRequest {
    case pair(RemotePairingRequest)
    case pairIroh(RemoteIrohPairingRequest, authenticatedPeerEndpointID: String)
    case transportBootstrap
    case bindIrohEndpoint(RemoteIrohBindingRequest)
    case unpair
    case snapshot
    case diagnostics
    case workspaces
    case sessions
    case agents
    case workflows
    case history(RemoteHistoryRPCRequest)
    case transcript(RemoteGatewayTranscriptRequest)
    case events(after: UInt64?)
    case command(RemoteCommandRequest, endpoint: RemoteGatewayCommandEndpoint)
}

enum RemoteGatewayResponseContent {
    case json(Data)
    case events([RemoteEvent])
    case error(RemoteErrorResponse)
}

struct RemoteGatewayResponse {
    let status: Int
    let content: RemoteGatewayResponseContent

    static func error(_ error: RemoteErrorResponse, status: Int) -> Self {
        Self(status: status, content: .error(error))
    }
}

enum RemoteGatewayPairingResult {
    case success(RemotePairingResponse)
    case forbidden(String)
    case failed
}

enum RemoteGatewayRevocationResult {
    case success
    case failed
}

enum RemoteGatewayTranscriptResult {
    case success(RemoteTranscriptPage)
    case sessionNotFound(String)
    case itemNotFound(String)
    case invalidCursor(String)
    case failed
    case unavailable
}

enum RemoteGatewayRegistrationResult {
    case success
    case failed
}

enum RemoteGatewayCommandResult {
    case success(RemoteCommandResponse)
    case rejected(String)
    case failed
    case unavailable
}

@MainActor
struct RemoteGatewayRoutingServices {
    var authorize: (RemoteGatewayRequestContext) -> Bool
    var pair: (RemotePairingRequest) -> RemoteGatewayPairingResult
    var pairIroh: (RemoteIrohPairingRequest, String) -> Result<RemoteIrohPairingResponse, Error>
    var transportBootstrap: () -> RemoteTransportBootstrapResponse?
    var bindIrohEndpoint: (RemoteIrohBindingRequest, String?) -> Result<RemoteIrohBindingResponse, Error>
    var unpair: () -> RemoteGatewayRevocationResult
    var snapshot: () async -> RemoteSnapshot?
    var diagnostics: () async -> RemoteDiagnostics?
    var history: (RemoteHistoryRPCRequest) async throws -> RemoteHistoryPage?
    var transcript: (RemoteGatewayTranscriptRequest) async -> RemoteGatewayTranscriptResult
    var replay: (UInt64?) async -> RemoteEventReplayResult
    var registerNotifications: (RemoteNotificationRegistration) -> RemoteGatewayRegistrationResult
    var authorizationState: () -> RemoteAuthorizationState
    var execute: (RemoteCommandRequest) async -> RemoteGatewayCommandResult
    var eventCursor: () async -> UInt64

    init(
        authorize: @escaping (RemoteGatewayRequestContext) -> Bool,
        pair: @escaping (RemotePairingRequest) -> RemoteGatewayPairingResult,
        unpair: @escaping () -> RemoteGatewayRevocationResult,
        snapshot: @escaping () async -> RemoteSnapshot?,
        diagnostics: @escaping () async -> RemoteDiagnostics?,
        history: @escaping (RemoteHistoryRPCRequest) async throws -> RemoteHistoryPage?,
        transcript: @escaping (RemoteGatewayTranscriptRequest) async -> RemoteGatewayTranscriptResult,
        replay: @escaping (UInt64?) async -> RemoteEventReplayResult,
        registerNotifications: @escaping (RemoteNotificationRegistration) -> RemoteGatewayRegistrationResult,
        authorizationState: @escaping () -> RemoteAuthorizationState,
        execute: @escaping (RemoteCommandRequest) async -> RemoteGatewayCommandResult,
        eventCursor: @escaping () async -> UInt64,
        pairIroh: @escaping (RemoteIrohPairingRequest, String) -> Result<RemoteIrohPairingResponse, Error> = { _, _ in
            .failure(RemoteGatewayRouterError.irohUnavailable)
        },
        transportBootstrap: @escaping () -> RemoteTransportBootstrapResponse? = { nil },
        bindIrohEndpoint: @escaping (RemoteIrohBindingRequest, String?) -> Result<RemoteIrohBindingResponse, Error> = { _, _ in
            .failure(RemoteGatewayRouterError.irohUnavailable)
        }
    ) {
        self.authorize = authorize
        self.pair = pair
        self.pairIroh = pairIroh
        self.transportBootstrap = transportBootstrap
        self.bindIrohEndpoint = bindIrohEndpoint
        self.unpair = unpair
        self.snapshot = snapshot
        self.diagnostics = diagnostics
        self.history = history
        self.transcript = transcript
        self.replay = replay
        self.registerNotifications = registerNotifications
        self.authorizationState = authorizationState
        self.execute = execute
        self.eventCursor = eventCursor
    }
}

enum RemoteGatewayRouterError: LocalizedError {
    case irohUnavailable

    var errorDescription: String? {
        "Iroh transport is not available."
    }
}

/// Transport-independent application router for the desktop Remote gateway.
///
/// Network adapters translate their wire format into `RemoteGatewayRequest`
/// values and serialize the returned JSON or ordered events. Authorization,
/// authority enforcement, command behavior, and application errors stay here
/// so additional transports cannot create a second routing policy.
@MainActor
final class RemoteGatewayRequestRouter {
    private let services: RemoteGatewayRoutingServices
    private let encoder = JSONEncoder()

    init(services: RemoteGatewayRoutingServices) {
        self.services = services
    }

    func isAuthorized(_ context: RemoteGatewayRequestContext) -> Bool {
        services.authorize(context)
    }

    func route(
        _ request: RemoteGatewayRequest,
        context: RemoteGatewayRequestContext
    ) async -> RemoteGatewayResponse {
        switch request {
        case let .pair(pairingRequest):
            return routePairing(pairingRequest)
        case let .pairIroh(pairingRequest, authenticatedPeerEndpointID):
            return routeIrohPairing(pairingRequest, authenticatedPeerEndpointID: authenticatedPeerEndpointID)
        default:
            break
        }

        guard services.authorize(context) else {
            return .error(
                .init(code: "unauthorized", message: "A valid paired-device credential is required."),
                status: 401
            )
        }

        switch request {
        case .pair, .pairIroh:
            preconditionFailure("Pairing is handled before authorization.")

        case .transportBootstrap:
            guard let response = services.transportBootstrap() else {
                return .error(
                    .init(code: "iroh_unavailable", message: "Iroh transport is not available.", retryable: true),
                    status: 503
                )
            }
            return encode(response)

        case let .bindIrohEndpoint(request):
            guard case .legacyHTTPS = context.transport else {
                return .error(
                    .init(
                        code: "endpoint_binding_requires_legacy_https",
                        message: "Iroh endpoint binding must be authorized through the pinned HTTPS transport."
                    ),
                    status: 403
                )
            }
            switch services.bindIrohEndpoint(request, context.authorizationHeader) {
            case let .success(response):
                return encode(response)
            case let .failure(error):
                return .error(.init(code: "endpoint_binding_failed", message: error.localizedDescription), status: 403)
            }

        case .unpair:
            guard case .success = services.unpair() else {
                return .error(
                    .init(
                        code: "revocation_failed",
                        message: "The paired-device credential could not be durably revoked.",
                        retryable: true
                    ),
                    status: 500
                )
            }
            return encode(RemoteUnpairResponse())

        case .snapshot:
            guard let snapshot = await services.snapshot() else { return unavailableReadResponse() }
            return encode(snapshot)

        case .diagnostics:
            guard let diagnostics = await services.diagnostics() else { return unavailableReadResponse() }
            return encode(diagnostics)

        case .workspaces:
            guard let snapshot = await services.snapshot() else { return unavailableReadResponse() }
            return encode(snapshot.workspaces)

        case .sessions:
            guard let snapshot = await services.snapshot() else { return unavailableReadResponse() }
            return encode(snapshot.sessions)

        case .agents:
            guard let snapshot = await services.snapshot() else { return unavailableReadResponse() }
            return encode(snapshot.agentCatalog)

        case .workflows:
            guard let snapshot = await services.snapshot() else { return unavailableReadResponse() }
            return encode(snapshot.workflowCatalog)

        case let .history(request):
            guard request.before == nil || request.workspaceID != nil else {
                return .error(.init(code: "invalid_history_request", message: "Invalid workspace history request."), status: 400)
            }
            do {
                guard let page = try await services.history(request) else { return unavailableReadResponse() }
                return encode(page)
            } catch RemoteReadServiceError.workspaceNotFound {
                return .error(.init(code: "workspace_not_found", message: "The requested workspace was not found."), status: 404)
            } catch {
                return .error(
                    .init(code: "history_failed", message: "The Mac could not load this workspace’s saved chats.", retryable: true),
                    status: 500
                )
            }

        case let .transcript(request):
            switch await services.transcript(request) {
            case let .success(page):
                return encode(page)
            case let .sessionNotFound(message):
                return .error(.init(code: "session_not_found", message: message), status: 404)
            case let .itemNotFound(message):
                return .error(
                    .init(code: "transcript_item_not_found", message: message, retryable: true),
                    status: 404
                )
            case let .invalidCursor(message):
                return .error(.init(code: "invalid_transcript_cursor", message: message), status: 400)
            case .failed:
                return .error(
                    .init(code: "transcript_failed", message: "The transcript could not be loaded.", retryable: true),
                    status: 500
                )
            case .unavailable:
                return unavailableReadResponse()
            }

        case let .events(cursor):
            switch await services.replay(cursor) {
            case let .events(events):
                return RemoteGatewayResponse(status: 200, content: .events(events))
            case .snapshotRequired:
                return .error(
                    .init(
                        code: "snapshot_required",
                        message: "The event cursor is no longer retained.",
                        retryable: true
                    ),
                    status: 409
                )
            }

        case let .command(command, endpoint):
            return await routeCommand(command, endpoint: endpoint)
        }
    }

    private func routeIrohPairing(
        _ request: RemoteIrohPairingRequest,
        authenticatedPeerEndpointID: String
    ) -> RemoteGatewayResponse {
        switch services.pairIroh(request, authenticatedPeerEndpointID) {
        case let .success(response):
            encode(response)
        case let .failure(error):
            .error(.init(code: "pairing_failed", message: error.localizedDescription), status: 403)
        }
    }

    private func routePairing(_ request: RemotePairingRequest) -> RemoteGatewayResponse {
        switch services.pair(request) {
        case let .success(response):
            encode(response)
        case let .forbidden(message):
            .error(.init(code: "pairing_failed", message: message), status: 403)
        case .failed:
            .error(
                .init(code: "pairing_failed", message: "Pairing could not be completed."),
                status: 500
            )
        }
    }

    private func routeCommand(
        _ command: RemoteCommandRequest,
        endpoint: RemoteGatewayCommandEndpoint
    ) async -> RemoteGatewayResponse {
        if endpoint == .contextBuilder, command.operation != .contextBuilder {
            return .error(
                .init(
                    code: "invalid_context_builder_command",
                    message: "The context-builder endpoint accepts only context_builder commands."
                ),
                status: 400
            )
        }

        if command.operation == .registerNotifications {
            guard let registration = command.notificationRegistration else {
                return .error(
                    .init(
                        code: "invalid_notification_registration",
                        message: "A notification registration is required."
                    ),
                    status: 400
                )
            }
            switch services.registerNotifications(registration) {
            case .success:
                return await encode(RemoteCommandResponse(
                    commandID: command.commandID,
                    accepted: true,
                    message: "Notification registration saved.",
                    eventCursor: services.eventCursor()
                ))
            case .failed:
                return .error(
                    .init(
                        code: "notification_registration_failed",
                        message: "Notification registration could not be saved."
                    ),
                    status: 409
                )
            }
        }

        let requiredAuthority = Self.requiredAuthority(for: command.operation)
        guard services.authorizationState().allows(requiredAuthority) else {
            return .error(
                .init(
                    code: "forbidden",
                    message: "The paired device does not have sufficient authority for this command."
                ),
                status: 403
            )
        }

        switch await services.execute(command) {
        case let .success(response):
            return await encode(Self.attachingEventCursor(
                to: response,
                eventCursor: services.eventCursor()
            ))
        case let .rejected(message):
            return .error(.init(code: "command_rejected", message: message), status: 409)
        case .failed:
            return .error(
                .init(code: "command_failed", message: "The remote command could not be completed."),
                status: 500
            )
        case .unavailable:
            return .error(
                .init(code: "unavailable", message: "Remote control services are not ready.", retryable: true),
                status: 503
            )
        }
    }

    static func attachingEventCursor(
        to response: RemoteCommandResponse,
        eventCursor: UInt64
    ) -> RemoteCommandResponse {
        RemoteCommandResponse(
            protocolVersion: response.protocolVersion,
            commandID: response.commandID,
            accepted: response.accepted,
            workspaceID: response.workspaceID,
            sessionID: response.sessionID,
            runState: response.runState,
            message: response.message,
            eventCursor: eventCursor,
            contextBuilderResult: response.contextBuilderResult,
            resolvedSelection: response.resolvedSelection,
            resolvedToolCatalog: response.resolvedToolCatalog
        )
    }

    private func encode(_ value: some Encodable, status: Int = 200) -> RemoteGatewayResponse {
        do {
            return try RemoteGatewayResponse(status: status, content: .json(encoder.encode(value)))
        } catch {
            return .error(
                .init(code: "encoding_failed", message: "The response could not be encoded."),
                status: 500
            )
        }
    }

    private func unavailableReadResponse() -> RemoteGatewayResponse {
        .error(
            .init(code: "unavailable", message: "Remote read services are not ready.", retryable: true),
            status: 503
        )
    }

    static func requiredAuthority(for operation: RemoteCommandOperation) -> RemoteAuthorityLevel {
        switch operation {
        case .respond:
            .respond
        case .startRun, .configureSession, .configureTools, .followUp, .steer, .cancel, .resume, .contextBuilder, .uploadAttachment:
            .control
        case .registerNotifications:
            .observe
        }
    }
}
