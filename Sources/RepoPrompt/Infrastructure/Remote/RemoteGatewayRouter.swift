import Foundation
import RepoPromptRemoteProtocol

struct RemoteGatewayRequestContext: Equatable {
    let endpointID: String
    let deviceID: String
    let authorizationHeader: String?
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
    case pairIroh(RemoteIrohPairingRequest, authenticatedPeerEndpointID: String)
    case unpair
    case snapshot
    case diagnostics
    case workspaces
    case sessions
    case agents
    case workflows
    case history(RemoteHistoryRPCRequest)
    case transcript(RemoteGatewayTranscriptRequest)
    case imageAttachment(RemoteImageAttachmentRequest)
    case workspaceVoice(RemoteWorkspaceVoiceRequest)
    case workspacePresentation(RemoteWorkspacePresentation)
    case events(after: UInt64?)
    case command(RemoteCommandRequest, endpoint: RemoteGatewayCommandEndpoint)

    var requiresConfirmedSync: Bool {
        switch self {
        case .command, .workspacePresentation: true
        case let .workspaceVoice(request): request.action == .start
        default: false
        }
    }
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

enum RemoteGatewayCommandResult {
    case success(RemoteCommandResponse)
    case rejected(String)
    case failed
    case unavailable
}

typealias RemoteDispatchAuthorization = @MainActor () throws -> Void

@MainActor
struct RemoteGatewayRoutingServices {
    var authorize: (RemoteGatewayRequestContext) -> Bool
    var pairIroh: (RemoteIrohPairingRequest, String) -> Result<RemoteIrohPairingResponse, Error>
    var confirmIroh: (RemotePairingConfirmation, String) throws -> Void
    var unpair: () -> RemoteGatewayRevocationResult
    var snapshot: () async -> RemoteSnapshot?
    var bootstrapSnapshot: () async -> RemoteSnapshot?
    var diagnostics: () async -> RemoteDiagnostics?
    var history: (RemoteHistoryRPCRequest) async throws -> RemoteHistoryPage?
    var transcript: (RemoteGatewayTranscriptRequest) async -> RemoteGatewayTranscriptResult
    var imageAttachment: (RemoteImageAttachmentRequest) async throws -> RemoteImageAttachmentChunk?
    var replay: (UInt64?) async -> RemoteEventReplayResult
    var authorizationState: () -> RemoteAuthorizationState
    var commandGeneration: () -> UInt64
    var execute: (RemoteCommandRequest, @escaping RemoteDispatchAuthorization) async -> RemoteGatewayCommandResult
    var eventCursor: () async -> UInt64
    var workspaceVoiceConsent: () -> Bool
    var workspaceVoice: (RemoteWorkspaceVoiceRequest, RemoteGatewayRequestContext) throws -> RemoteWorkspaceVoiceStatus
    var workspacePresentation: (RemoteWorkspacePresentation, @escaping RemoteDispatchAuthorization) async throws -> Void

    init(
        authorize: @escaping (RemoteGatewayRequestContext) -> Bool,
        unpair: @escaping () -> RemoteGatewayRevocationResult,
        snapshot: @escaping () async -> RemoteSnapshot?,
        diagnostics: @escaping () async -> RemoteDiagnostics?,
        history: @escaping (RemoteHistoryRPCRequest) async throws -> RemoteHistoryPage?,
        transcript: @escaping (RemoteGatewayTranscriptRequest) async -> RemoteGatewayTranscriptResult,
        replay: @escaping (UInt64?) async -> RemoteEventReplayResult,
        authorizationState: @escaping () -> RemoteAuthorizationState,
        commandGeneration: @escaping () -> UInt64,
        execute: @escaping (RemoteCommandRequest, @escaping RemoteDispatchAuthorization) async -> RemoteGatewayCommandResult,
        eventCursor: @escaping () async -> UInt64,
        imageAttachment: @escaping (RemoteImageAttachmentRequest) async throws -> RemoteImageAttachmentChunk? = { _ in nil },
        pairIroh: @escaping (RemoteIrohPairingRequest, String) -> Result<RemoteIrohPairingResponse, Error> = { _, _ in
            .failure(RemoteGatewayRouterError.irohUnavailable)
        },
        confirmIroh: @escaping (RemotePairingConfirmation, String) throws -> Void = { _, _ in
            throw RemoteGatewayRouterError.irohUnavailable
        },
        bootstrapSnapshot: (() async -> RemoteSnapshot?)? = nil,
        workspaceVoiceConsent: @escaping () -> Bool = { false },
        workspaceVoice: @escaping (RemoteWorkspaceVoiceRequest, RemoteGatewayRequestContext) throws -> RemoteWorkspaceVoiceStatus = { _, _ in
            throw RemoteWorkspaceVoiceError.unavailable
        },
        workspacePresentation: @escaping (RemoteWorkspacePresentation, @escaping RemoteDispatchAuthorization) async throws -> Void = { _, _ in
            throw RemoteAgentControlServiceError.commandRejected("Workspace controls are unavailable.")
        }
    ) {
        self.confirmIroh = confirmIroh
        self.authorize = authorize
        self.pairIroh = pairIroh
        self.unpair = unpair
        self.snapshot = snapshot
        self.bootstrapSnapshot = bootstrapSnapshot ?? snapshot
        self.diagnostics = diagnostics
        self.history = history
        self.transcript = transcript
        self.imageAttachment = imageAttachment
        self.replay = replay
        self.authorizationState = authorizationState
        self.commandGeneration = commandGeneration
        self.execute = execute
        self.eventCursor = eventCursor
        self.workspaceVoiceConsent = workspaceVoiceConsent
        self.workspaceVoice = workspaceVoice
        self.workspacePresentation = workspacePresentation
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
/// The Iroh adapter translates wire frames into `RemoteGatewayRequest`
/// values and serialize the returned JSON or ordered events. Authorization,
/// authority enforcement, command behavior, and application errors stay here
/// after the adapter authenticates each peer.
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

    func confirmIroh(_ confirmation: RemotePairingConfirmation, peerEndpointID: String) throws {
        try services.confirmIroh(confirmation, peerEndpointID)
    }

    func route(
        _ request: RemoteGatewayRequest,
        context: RemoteGatewayRequestContext
    ) async -> RemoteGatewayResponse {
        switch request {
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
        case .pairIroh:
            preconditionFailure("Pairing is handled before authorization.")

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
            guard let snapshot = await services.bootstrapSnapshot() else { return unavailableReadResponse() }
            return encodeSnapshot(snapshot)

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

        case let .imageAttachment(request):
            guard request.isValid else {
                return .error(.init(code: "invalid_image_attachment", message: "Invalid image attachment request."), status: 400)
            }
            do {
                guard let image = try await services.imageAttachment(request) else { return unavailableReadResponse() }
                return encode(image)
            } catch RemoteImageReadError.changed {
                return .error(.init(code: "image_changed", message: "The image changed. Reopen it to retry."), status: 409)
            } catch RemoteImageReadError.invalidImage {
                return .error(.init(code: "invalid_image", message: "This attachment cannot be displayed as an image."), status: 422)
            } catch {
                return .error(
                    .init(code: "image_unavailable", message: "The image is unavailable on the Mac.", retryable: true),
                    status: 404
                )
            }

        case let .workspaceVoice(request):
            guard request.isValid else {
                return .error(.init(code: "invalid_voice_request", message: "Invalid voice session request."), status: 400)
            }
            guard services.authorizationState().allows(.control) else {
                return .error(.init(code: "forbidden", message: "Workspace Voice requires Control permission on the Mac."), status: 403)
            }
            guard request.action != .start || services.workspaceVoiceConsent() else {
                return .error(.init(
                    code: "workspace_voice_consent_required",
                    message: "Allow OpenAI data sharing for Workspace Voice in Remote settings on the Mac."
                ), status: 403)
            }
            do {
                return try encode(services.workspaceVoice(request, context))
            } catch let error as RemoteWorkspaceVoiceError {
                return .error(.init(code: "workspace_voice", message: error.localizedDescription), status: 409)
            } catch {
                return .error(.init(code: "workspace_voice", message: "The Mac could not open Workspace Voice."), status: 503)
            }

        case let .workspacePresentation(request):
            guard services.authorizationState().allows(.control) else {
                return .error(.init(code: "forbidden", message: "Opening and closing workspaces requires Control permission on the Mac."), status: 403)
            }
            do {
                try await services.workspacePresentation(request, authorizeDispatch(context, requiring: .control))
                return encode(request)
            } catch let error as RemoteAgentControlServiceError {
                return .error(.init(code: "workspace_presentation", message: error.localizedDescription), status: 409)
            } catch let error as RemoteWorkspaceVoiceError {
                return .error(.init(code: "workspace_presentation", message: error.localizedDescription), status: 409)
            } catch {
                return .error(.init(code: "workspace_presentation", message: "The Mac could not change the workspace."), status: 503)
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
            return await routeCommand(command, endpoint: endpoint, context: context)
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
            .error(Self.pairingError(error), status: 403)
        }
    }

    static func pairingError(_ error: Error) -> RemoteErrorResponse {
        (error as? RemoteGatewaySecurityError)?.response ?? .init(
            code: "pairing_storage_unavailable",
            message: "The Mac could not access or save pairing in Keychain. Check Remote settings on your Mac and retry.",
            retryable: true
        )
    }

    private func routeCommand(
        _ command: RemoteCommandRequest,
        endpoint: RemoteGatewayCommandEndpoint,
        context: RemoteGatewayRequestContext
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
            // Re-enable only when the Mac, not the client, owns the relay destination.
            return .error(
                .init(code: "notifications_unavailable", message: "This Mac does not support Remote push notifications."),
                status: 503
            )
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

        switch await services.execute(command, authorizeDispatch(context, requiring: requiredAuthority)) {
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

    private func authorizeDispatch(
        _ context: RemoteGatewayRequestContext,
        requiring authority: RemoteAuthorityLevel
    ) -> RemoteDispatchAuthorization {
        let generation = services.commandGeneration()
        return {
            guard generation == self.services.commandGeneration(),
                  self.services.authorize(context),
                  self.services.authorizationState().allows(authority)
            else {
                throw RemoteAgentControlServiceError.commandRejected(
                    "Remote access changed before this command could be dispatched."
                )
            }
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

    private func encodeSnapshot(_ snapshot: RemoteSnapshot) -> RemoteGatewayResponse {
        encodeJSON { try RemoteSnapshotBootstrap.encode(snapshot, with: encoder) }
    }

    private func encode(_ value: some Encodable, status: Int = 200) -> RemoteGatewayResponse {
        encodeJSON(status: status) { try encoder.encode(value) }
    }

    private func encodeJSON(status: Int = 200, _ data: () throws -> Data) -> RemoteGatewayResponse {
        do {
            return try RemoteGatewayResponse(status: status, content: .json(data()))
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
        case .configureTools:
            .danger
        case .startRun, .configureSession, .followUp, .steer, .cancel, .resume, .contextBuilder, .uploadAttachment:
            .control
        case .registerNotifications:
            .observe
        }
    }
}
