import Crypto
import Foundation
import Hummingbird
import NIOCore
import NIOSSL
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServerHost
import RepoPromptServiceHTTP
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

private extension ConnectProviderRequest {
    func runtimeInput() throws -> ProviderConnectionInput {
        guard keyHelperCommand == nil,
              workloadIdentityProvider == nil,
              workloadIdentityServiceAccount == nil
        else {
            throw ServiceAPIError(
                code: .capabilityMissing,
                message: "Structured provider credentials are not available"
            )
        }
        return .init(
            authenticationMethod: authenticationMethod,
            credential: credential.map { Data($0.utf8) },
            accountLabel: accountLabel,
            expiresAt: expiresAt
        )
    }
}

private extension ProviderAuthFlowKind {
    var runtimeKind: ProviderManagedAuthenticationFlowKind {
        switch self {
        case .browserOAuth: .browserOAuth
        case .deviceCodeBeta: .deviceCodeBeta
        case .externalProvisioning: .externalProvisioning
        }
    }
}

private extension ProviderAuthTransactionStatus {
    init(_ transaction: ProviderManagedAuthenticationTransaction) {
        let kind: ProviderAuthFlowKind = switch transaction.kind {
        case .browserOAuth: .browserOAuth
        case .deviceCodeBeta: .deviceCodeBeta
        case .externalProvisioning: .externalProvisioning
        }
        let state: ProviderAuthTransactionState = switch transaction.state {
        case .pending: .pending
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        case .expired: .expired
        }
        self.init(
            flowID: transaction.flowID,
            providerID: transaction.providerID,
            kind: kind,
            state: state,
            userCode: transaction.userCode,
            verificationURL: transaction.verificationURL,
            expiresAt: transaction.expiresAt,
            detail: transaction.detail
        )
    }
}

public struct RepoPromptHTTPService: Sendable {
    private enum SSEFrame {
        case event(EventEnvelope)
        case heartbeat
    }

    private enum HTTPReadAdmission: Equatable {
        case ordinary
        case subscription
    }

    private let authority: RepoPromptHeadlessAuthority
    private let store: SQLiteServiceStore
    private let authenticator: InternalRequestAuthenticator
    private let responseSigner: InternalResponseSigner
    private let certificateRoleResolver: CertificateIdentityRoleResolver?
    private let readiness: RepoPromptReadinessService
    private let mutationGate: AuthorityMutationGate
    private let durabilityOperations: DurabilityOperationsService?
    private let providerSettings: ProviderSettingsService?
    private let serverSettings: ServerSettingsService?
    private let composerCatalog: (any AgentComposerCatalogProviding)?
    private let composerAttachments: AgentComposerAttachmentStore?
    private let submissionCoordinator: AgentSubmissionCoordinator?
    private let submissionDispatchQueue: AgentSubmissionDispatchQueue?
    private let transcriptPresentation: AgentTranscriptPresentationService?
    private let portalDesktopSettings: PortalDesktopSettingsService
    private let portalPeerCertificateDER: Data?
    private let portalPasswordLoginEnabled: Bool

    public init(
        authority: RepoPromptHeadlessAuthority,
        store: SQLiteServiceStore,
        authenticator: InternalRequestAuthenticator,
        eventSigningKey: InternalSigningKey,
        certificateRoleResolver: CertificateIdentityRoleResolver? = nil,
        readiness: RepoPromptReadinessService? = nil,
        durabilityOperations: DurabilityOperationsService? = nil,
        providerSettings: ProviderSettingsService? = nil,
        serverSettings: ServerSettingsService? = nil,
        composerCatalog: (any AgentComposerCatalogProviding)? = nil,
        composerAttachments: AgentComposerAttachmentStore? = nil,
        submissionCoordinator: AgentSubmissionCoordinator? = nil,
        submissionDispatchQueue: AgentSubmissionDispatchQueue? = nil,
        transcriptPresentation: AgentTranscriptPresentationService? = nil,
        portalDesktopSettings: PortalDesktopSettingsService? = nil,
        portalPeerCertificateDER: Data? = nil,
        portalPasswordLoginEnabled: Bool = true,
        mutationGate: AuthorityMutationGate
    ) {
        self.authority = authority
        self.store = store
        self.authenticator = authenticator
        responseSigner = InternalResponseSigner(key: eventSigningKey)
        self.certificateRoleResolver = certificateRoleResolver
        self.mutationGate = mutationGate
        self.durabilityOperations = durabilityOperations
        self.providerSettings = providerSettings
        self.serverSettings = serverSettings
        self.composerCatalog = composerCatalog
        self.composerAttachments = composerAttachments
        self.submissionCoordinator = submissionCoordinator
        self.submissionDispatchQueue = submissionDispatchQueue ?? submissionCoordinator.map {
            AgentSubmissionDispatchQueue(authority: authority, coordinator: $0)
        }
        self.transcriptPresentation = transcriptPresentation
        self.portalDesktopSettings = portalDesktopSettings ?? PortalDesktopSettingsService(store: store)
        self.portalPeerCertificateDER = portalPeerCertificateDER
        self.portalPasswordLoginEnabled = portalPasswordLoginEnabled
        self.readiness = readiness ?? RepoPromptReadinessService(
            authority: authority,
            store: store,
            mutationGate: mutationGate
        )
    }

    public func healthRouter() -> Router<BasicRequestContext> {
        let router = Router<BasicRequestContext>()
        router.get("/health/live") { _, _ in Response(status: .ok) }
        router.get("/health/ready") { _, _ in
            do {
                let capability = await mutationGate.readCapability()
                let ready = try await capability.perform { [readiness] in
                    await readiness.snapshot().ready
                }
                return ready ? Response(status: .ok) : Response(status: .serviceUnavailable)
            } catch {
                return Response(status: .serviceUnavailable)
            }
        }
        return router
    }

    public func internalRouter() -> Router<RepoPromptRequestContext> {
        let router = Router<RepoPromptRequestContext>(context: RepoPromptRequestContext.self)
        router.get("/portal") { request, context in await portalRespond(request) {
            if request.uri.string.split(separator: "?", maxSplits: 1).first == "/portal" {
                return RepoPromptPortalAssets.canonicalRedirect()
            }
            return try RepoPromptPortalAssets.response(for: .index)
        } }
        router.get("/portal/assets/:name") { request, context in await portalRespond(request) {
            let name = try context.parameters.require("name")
            guard let asset = RepoPromptPortalAssets.Asset(routeName: name) else {
                throw ServiceAPIError(code: .notFound, message: "Portal asset not found")
            }
            return try RepoPromptPortalAssets.response(for: asset)
        } }
        router.get("/portal/api/v1/auth/status") { request, context in await portalRespond(request) {
            try portalJSON(await portalAuthStatus(request: request, context: context))
        } }
        router.post("/portal/api/v1/setup") { request, context in await portalRespond(request) {
            try validatePortalMutation(request)
            return try await completePortalSetup(request: request, context: context)
        } }
        router.post("/portal/api/v1/login") { request, context in await portalRespond(request) {
            try validatePortalMutation(request)
            return try await completePortalLogin(request: request)
        } }
        router.post("/portal/api/v1/logout") { request, context in await portalRespond(request) {
            try validatePortalMutation(request)
            return try await completePortalLogout(request: request)
        } }
        router.get("/portal/api/v1/bootstrap") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            let bootstrap = try await portalBootstrap()
            return try portalJSON(bootstrap)
        } }
        router.get("/portal/api/v1/sessions/:id/transcript") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let limit = request.uri.queryParameters.get("limit", as: Int.self) ?? 200
            let beforeSequence = request.uri.queryParameters.get("beforeSequence", as: Int64.self)
            let afterSequence = request.uri.queryParameters.get("afterSequence", as: Int64.self)
            let session = try await authority.sessionSnapshot(sessionID: sessionID)
            return try portalJSON(RepoPromptPortalSessionProjection.transcriptPage(
                session: session,
                limit: limit,
                beforeSequence: beforeSequence,
                afterSequence: afterSequence
            ))
        } }
        router.post("/portal/api/v1/sessions") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(PortalCreateSessionRequest.self, from: data)
            let catalog = try await requireProviderSettings().catalog(refreshCLI: false)
            let providerID: ProviderSettingsID
            let resolvedModel: String?
            let reasoningEffort: String?
            if let explicitProviderID = input.providerID {
                providerID = explicitProviderID
                resolvedModel = input.model
                reasoningEffort = nil
            } else {
                let target = input.routingTarget ?? .engineer
                guard let resolved = try await requireServerSettings().resolveAgentTarget(projectID: input.projectID, target: target) else {
                    throw ServiceAPIError(code: .dependencyUnavailable, message: "No Agent Model route is available for the new session", retryable: true)
                }
                providerID = resolved.providerID
                resolvedModel = resolved.modelID
                reasoningEffort = resolved.reasoningEffort
            }
            guard let provider = catalog.providers.first(where: { $0.providerID == providerID }) else {
                throw ServiceAPIError(code: .notFound, message: "Provider settings not found")
            }
            let runtimeDefaults = try await requirePortalDesktopSettings().runtimeDefaults(for: providerID)
            let createInput = try RepoPromptPortalSessionProjection.validatedCreateInput(
                input,
                provider: provider,
                resolvedModel: resolvedModel,
                reasoningEffort: reasoningEffort,
                runtimeDefaults: runtimeDefaults
            )
            let snapshot = try await authority.createSession(
                input: createInput,
                externalActor: principal.externalActor,
                idempotencyKey: portalIdempotencyKey(principal: principal, operationID: input.operationID),
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            return try portalJSON(RepoPromptPortalSessionProjection.project(snapshot), status: .accepted)
        } }
        router.post("/portal/api/v1/sessions/:id/messages") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(PortalSendMessageRequest.self, from: data)
            let command = try RepoPromptPortalSessionProjection.validatedSendCommand(input)
            let receipt = try await authority.execute(
                command: command,
                sessionID: sessionID,
                externalActor: principal.externalActor,
                idempotencyKey: portalIdempotencyKey(principal: principal, operationID: input.operationID),
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            return try portalJSON(receipt, status: .accepted)
        } }
        router.get("/portal/api/v1/desktop-settings") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requirePortalDesktopSettings().snapshot())
        } }
        router.patch("/portal/api/v1/desktop-settings") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(UpdatePortalDesktopSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requirePortalDesktopSettings().update(input))
        } }
        router.get("/portal/api/v1/settings/agent-models") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().agentModels())
        } }
        router.patch("/portal/api/v1/settings/agent-models") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceGlobalAgentModelsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceGlobalAgentModels(input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/settings/agent-models/apply-recommendations") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ApplyAgentModelRecommendationsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().applyGlobalAgentModelRecommendations(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/projects/:id/settings/agent-models") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            let projectID = try context.parameters.require("id", as: UUID.self)
            return try await portalJSON(requireServerSettings().agentModels(projectID: projectID))
        } }
        router.patch("/portal/api/v1/projects/:id/settings/agent-models") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceProjectAgentModelsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceProjectAgentModels(projectID: projectID, request: input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/projects/:id/settings/agent-models/copy-global") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(CopyGlobalAgentModelsToProjectRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().copyGlobalAgentModelsToProject(projectID: projectID, request: input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/projects/:id/settings/agent-models/copy-project") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(CopyProjectAgentModelsToGlobalRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().copyProjectAgentModelsToGlobal(projectID: projectID, request: input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/projects/:id/settings/agent-models/apply-recommendations") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(ApplyAgentModelRecommendationsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().applyProjectAgentModelRecommendations(projectID: projectID, request: input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/settings/subagent-permissions") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().subagentPermissions())
        } }
        router.patch("/portal/api/v1/settings/subagent-permissions") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceSubagentPermissionSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceSubagentPermissions(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/settings/direct-agent-permissions") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().directAgentPermissions())
        } }
        router.patch("/portal/api/v1/settings/direct-agent-permissions") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceDirectAgentPermissionsSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceDirectAgentPermissions(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/settings/context-builder") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().contextBuilder())
        } }
        router.patch("/portal/api/v1/settings/context-builder") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceGlobalContextBuilderSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceGlobalContextBuilder(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/projects/:id/settings/context-builder") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            let projectID = try context.parameters.require("id", as: UUID.self)
            return try await portalJSON(requireServerSettings().contextBuilder(projectID: projectID))
        } }
        router.patch("/portal/api/v1/projects/:id/settings/context-builder") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceProjectContextBuilderSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceProjectContextBuilder(projectID: projectID, request: input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/projects/:id/settings/context-builder/copy-global") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(CopyGlobalContextBuilderToProjectRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().copyGlobalContextBuilderToProject(projectID: projectID, request: input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/settings/model-presets") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().modelPresets())
        } }
        router.patch("/portal/api/v1/settings/model-presets") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceMCPModelPresetsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceModelPresets(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/settings/advanced") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().advanced())
        } }
        router.patch("/portal/api/v1/settings/advanced") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceAdvancedServerSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceAdvanced(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/settings/workspace-approvals") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().workspaceApprovals())
        } }
        router.patch("/portal/api/v1/settings/workspace-approvals") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceWorkspaceApprovalSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceWorkspaceApprovals(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/settings/mcp-disabled-tools") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().mcpDisabledTools())
        } }
        router.patch("/portal/api/v1/settings/mcp-disabled-tools") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceMCPDisabledToolsSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceMCPDisabledTools(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/settings/show-model-presets") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().showModelPresets())
        } }
        router.patch("/portal/api/v1/settings/show-model-presets") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceMCPShowModelPresetsSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceShowModelPresets(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/sessions/:id/selection") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            return try await portalJSON(authority.selectionSnapshot(sessionID: sessionID))
        } }
        router.get("/portal/api/v1/projects/:id/selection-presets") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            let projectID = try context.parameters.require("id", as: UUID.self)
            return try await portalJSON(authority.projectSelectionPresets(projectID: projectID))
        } }
        router.post("/portal/api/v1/projects/:id/selection-presets") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(CreateProjectSelectionPresetRequest.self, from: bodyData(request))
            return try await portalJSON(authority.createProjectSelectionPreset(projectID: projectID, request: input, attribution: principal.settingsAttribution), status: .created)
        } }
        router.patch("/portal/api/v1/projects/:id/selection-presets/:presetID") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let presetID = try context.parameters.require("presetID", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(UpdateProjectSelectionPresetRequest.self, from: bodyData(request))
            return try await portalJSON(authority.updateProjectSelectionPreset(projectID: projectID, presetID: presetID, request: input, attribution: principal.settingsAttribution))
        } }
        router.delete("/portal/api/v1/projects/:id/selection-presets/:presetID") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let presetID = try context.parameters.require("presetID", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(DeleteProjectSelectionPresetRequest.self, from: bodyData(request))
            return try await portalJSON(authority.deleteProjectSelectionPreset(projectID: projectID, presetID: presetID, request: input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/projects/:id/selection-presets/reorder") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(ReorderProjectSelectionPresetsRequest.self, from: bodyData(request))
            return try await portalJSON(authority.reorderProjectSelectionPresets(projectID: projectID, request: input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/projects/:id/selection-presets/capture") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(CaptureProjectSelectionPresetRequest.self, from: bodyData(request))
            return try await portalJSON(authority.captureProjectSelectionPreset(projectID: projectID, request: input, attribution: principal.settingsAttribution), status: .created)
        } }
        router.post("/portal/api/v1/projects/:id/selection-presets/apply") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(ApplyProjectSelectionPresetRequest.self, from: bodyData(request))
            return try await portalJSON(authority.applyProjectSelectionPreset(projectID: projectID, request: input, actor: principal.externalActor))
        } }
        router.get("/portal/api/v1/workflows") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(authority.workflowRepositorySnapshot())
        } }
        router.post("/portal/api/v1/workflows") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let data = try await bodyData(request)
            let input = try Self.decodeStrictWorkflowPayload(CreateServerWorkflowRequest.self, data: data, allowedKeys: ["expectedRevision", "name", "definition", "enabled", "visible", "featured"])
            return try await portalJSON(authority.createWorkflow(input, attribution: principal.settingsAttribution), status: .created)
        } }
        router.patch("/portal/api/v1/workflows/:id") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let workflowID = try context.parameters.require("id")
            let data = try await bodyData(request)
            let input = try Self.decodeStrictWorkflowPayload(UpdateServerWorkflowRequest.self, data: data, allowedKeys: ["expectedRevision", "expectedRowRevision", "name", "definition", "enabled", "visible", "featured"])
            return try await portalJSON(authority.updateWorkflow(workflowID: workflowID, request: input, attribution: principal.settingsAttribution))
        } }
        router.delete("/portal/api/v1/workflows/:id") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let workflowID = try context.parameters.require("id")
            let data = try await bodyData(request)
            let input = try Self.decodeStrictWorkflowPayload(DeleteServerWorkflowRequest.self, data: data, allowedKeys: ["expectedRevision", "expectedRowRevision"])
            return try await portalJSON(authority.deleteWorkflow(workflowID: workflowID, request: input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/workflows/:id/clone") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let workflowID = try context.parameters.require("id")
            let data = try await bodyData(request)
            let input = try Self.decodeStrictWorkflowPayload(CloneServerWorkflowRequest.self, data: data, allowedKeys: ["expectedRevision", "expectedSourceRowRevision", "name"])
            return try await portalJSON(authority.cloneWorkflow(workflowID: workflowID, request: input, attribution: principal.settingsAttribution), status: .created)
        } }
        router.patch("/portal/api/v1/workflows/:id/visibility") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let workflowID = try context.parameters.require("id")
            let data = try await bodyData(request)
            let input = try Self.decodeStrictWorkflowPayload(SetServerWorkflowVisibilityRequest.self, data: data, allowedKeys: ["expectedRevision", "expectedRowRevision", "visible"])
            return try await portalJSON(authority.setWorkflowVisibility(workflowID: workflowID, request: input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/workflows/reorder") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let data = try await bodyData(request)
            let input = try Self.decodeStrictWorkflowPayload(ReorderServerWorkflowsRequest.self, data: data, allowedKeys: ["expectedRevision", "featuredWorkflowIDs"])
            return try await portalJSON(authority.reorderWorkflows(input, attribution: principal.settingsAttribution))
        } }
        router.patch("/portal/api/v1/workflows/preferences") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let data = try await bodyData(request)
            let input = try Self.decodeStrictWorkflowPayload(UpdateServerWorkflowPreferencesRequest.self, data: data, allowedKeys: ["expectedRevision", "includeSessionCleanupGuidance"])
            return try await portalJSON(authority.updateWorkflowPreferences(input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/workflows/reload") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let data = try await bodyData(request)
            let input = try Self.decodeStrictWorkflowPayload(ReloadServerWorkflowsRequest.self, data: data, allowedKeys: ["expectedRevision"])
            return try await portalJSON(authority.reloadWorkflows(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/provider-settings") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            let catalog = try await requireProviderSettings().catalog()
            return try portalJSON(catalog)
        } }
        router.get("/portal/api/v1/provider-settings/:id/direct-configuration") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireProviderSettings().directConfiguration(providerID: providerSettingsID(context)))
        } }
        router.patch("/portal/api/v1/provider-settings/:id/direct-configuration") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(UpdateDirectProviderConfigurationRequest.self, from: bodyData(request))
            let configuration = try await requireProviderSettings().updateDirectConfiguration(
                providerID: providerSettingsID(context),
                request: input,
                attribution: principal.providerAttribution
            )
            return try portalJSON(configuration)
        } }
        router.patch("/portal/api/v1/provider-settings/:id") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let id = try context.parameters.require("id")
            guard let providerID = ProviderSettingsID(rawValue: id) else {
                throw ServiceAPIError(code: .notFound, message: "Provider settings not found")
            }
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(UpdateProviderSettingsRequest.self, from: data)
            let snapshot = try await requireProviderSettings().update(providerID: providerID, request: input, attribution: principal.providerAttribution)
            return try portalJSON(snapshot)
        } }
        router.post("/portal/api/v1/provider-settings/:id/enable") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(SetProviderEnabledRequest.self, from: bodyData(request))
            let snapshot = try await requireProviderSettings().setEnabled(providerID: providerSettingsID(context), enabled: true, request: input, attribution: principal.providerAttribution)
            return try portalJSON(snapshot)
        } }
        router.post("/portal/api/v1/provider-settings/:id/disable") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(SetProviderEnabledRequest.self, from: bodyData(request))
            let snapshot = try await requireProviderSettings().setEnabled(providerID: providerSettingsID(context), enabled: false, request: input, attribution: principal.providerAttribution)
            return try portalJSON(snapshot)
        } }
        router.post("/portal/api/v1/provider-settings/:id/auth-flows") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let id = try context.parameters.require("id")
            guard let providerID = ProviderSettingsID(rawValue: id) else {
                throw ServiceAPIError(code: .notFound, message: "Provider settings not found")
            }
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(StartProviderAuthFlowRequest.self, from: data)
            let challenge = try await requireProviderSettings().startAuthFlow(
                providerID: providerID,
                kind: input.kind.runtimeKind,
                attribution: principal.providerAttribution
            )
            return try portalJSON(ProviderAuthTransactionStatus(challenge), status: .accepted)
        } }
        router.post("/portal/api/v1/provider-settings/:id/connect") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let providerID = try providerSettingsID(context)
            let input = try await JSONDecoder.serviceDecoder.decode(ConnectProviderRequest.self, from: bodyData(request))
            let snapshot = try await requireProviderSettings().connect(providerID: providerID, input: input.runtimeInput(), attribution: principal.providerAttribution)
            return try portalJSON(snapshot, status: .created)
        } }
        router.post("/portal/api/v1/provider-settings/:id/test") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let snapshot = try await requireProviderSettings().testConnection(providerID: providerSettingsID(context), attribution: principal.providerAttribution)
            return try portalJSON(snapshot)
        } }
        router.post("/portal/api/v1/provider-settings/:id/disconnect") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let snapshot = try await requireProviderSettings().disconnect(providerID: providerSettingsID(context), attribution: principal.providerAttribution)
            return try portalJSON(snapshot)
        } }
        router.post("/portal/api/v1/provider-settings/:id/revoke") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let snapshot = try await requireProviderSettings().disconnect(providerID: providerSettingsID(context), attribution: principal.providerAttribution, revoke: true)
            return try portalJSON(snapshot)
        } }
        router.get("/portal/api/v1/provider-auth-flows/:flowID") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            let flowID = try context.parameters.require("flowID", as: UUID.self)
            let status = try await requireProviderSettings().pollAuthFlow(flowID: flowID, ownerID: principal.actorID)
            return try portalJSON(ProviderAuthTransactionStatus(status))
        } }
        router.delete("/portal/api/v1/provider-auth-flows/:flowID") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let flowID = try context.parameters.require("flowID", as: UUID.self)
            try await requireProviderSettings().cancelAuthFlow(flowID: flowID, ownerID: principal.actorID)
            return HTTPResponses.empty()
        } }
        router.get("/internal/v1/provider-settings") { request, context in await respond(request) {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app, .operatorRole], operation: "providerCatalog")
            return try await HTTPResponses.json(requireProviderSettings().catalog())
        } }
        router.get("/internal/v1/provider-settings/:id/direct-configuration") { request, context in await respond(request) {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app, .operatorRole], operation: "providerDirectConfigurationRead")
            return try await HTTPResponses.json(requireProviderSettings().directConfiguration(providerID: providerSettingsID(context)))
        } }
        router.patch("/internal/v1/provider-settings/:id/direct-configuration") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerDirectConfigurationUpdate")
            let input = try JSONDecoder.serviceDecoder.decode(UpdateDirectProviderConfigurationRequest.self, from: data)
            return try await HTTPResponses.json(requireProviderSettings().updateDirectConfiguration(
                providerID: providerSettingsID(context),
                request: input,
                attribution: providerAttribution(auth)
            ))
        } }
        router.patch("/internal/v1/provider-settings/:id") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerUpdate")
            let input = try JSONDecoder.serviceDecoder.decode(UpdateProviderSettingsRequest.self, from: data)
            return try await HTTPResponses.json(requireProviderSettings().update(providerID: providerSettingsID(context), request: input, attribution: providerAttribution(auth)))
        } }
        router.post("/internal/v1/provider-settings/:id/enable") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerEnable")
            let input = try JSONDecoder.serviceDecoder.decode(SetProviderEnabledRequest.self, from: data)
            return try await HTTPResponses.json(requireProviderSettings().setEnabled(providerID: providerSettingsID(context), enabled: true, request: input, attribution: providerAttribution(auth)))
        } }
        router.post("/internal/v1/provider-settings/:id/disable") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerDisable")
            let input = try JSONDecoder.serviceDecoder.decode(SetProviderEnabledRequest.self, from: data)
            return try await HTTPResponses.json(requireProviderSettings().setEnabled(providerID: providerSettingsID(context), enabled: false, request: input, attribution: providerAttribution(auth)))
        } }
        router.post("/internal/v1/provider-settings/:id/connect") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerConnect")
            let input = try JSONDecoder.serviceDecoder.decode(ConnectProviderRequest.self, from: data)
            let snapshot = try await requireProviderSettings().connect(providerID: providerSettingsID(context), input: input.runtimeInput(), attribution: providerAttribution(auth))
            return try HTTPResponses.json(snapshot, status: .created)
        } }
        router.post("/internal/v1/provider-settings/:id/test") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerTest")
            return try await HTTPResponses.json(requireProviderSettings().testConnection(providerID: providerSettingsID(context), attribution: providerAttribution(auth)))
        } }
        router.post("/internal/v1/provider-settings/:id/disconnect") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerDisconnect")
            return try await HTTPResponses.json(requireProviderSettings().disconnect(providerID: providerSettingsID(context), attribution: providerAttribution(auth)))
        } }
        router.post("/internal/v1/provider-settings/:id/revoke") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerRevoke")
            return try await HTTPResponses.json(requireProviderSettings().disconnect(providerID: providerSettingsID(context), attribution: providerAttribution(auth), revoke: true))
        } }
        router.post("/internal/v1/provider-settings/:id/auth-flows") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerAuthStart")
            let input = try JSONDecoder.serviceDecoder.decode(StartProviderAuthFlowRequest.self, from: data)
            let status = try await requireProviderSettings().startAuthFlow(providerID: providerSettingsID(context), kind: input.kind.runtimeKind, attribution: providerAttribution(auth))
            return try HTTPResponses.json(ProviderAuthTransactionStatus(status), status: .accepted)
        } }
        router.get("/internal/v1/provider-auth-flows/:flowID") { request, context in await respond(request) {
            let auth = try await authenticate(request, context: context, body: Data(), roles: [.app, .operatorRole], operation: "providerAuthPoll")
            let status = try await requireProviderSettings().pollAuthFlow(flowID: context.parameters.require("flowID", as: UUID.self), ownerID: providerAttribution(auth).actorID)
            return try HTTPResponses.json(ProviderAuthTransactionStatus(status))
        } }
        router.delete("/internal/v1/provider-auth-flows/:flowID") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerAuthCancel")
            try await requireProviderSettings().cancelAuthFlow(flowID: context.parameters.require("flowID", as: UUID.self), ownerID: providerAttribution(auth).actorID)
            return HTTPResponses.empty()
        } }
        router.get("/internal/v1/capabilities") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.app, .sync], operation: "capabilities")
            let meta = try await store.metadata()
            let models = try await composerCatalog?.compatibilityModels() ?? []
            return try await HTTPResponses.json(ServiceCapabilitiesResponse(
                protocolRange: .init(minimum: 1, maximum: 1),
                schemaVersion: meta.schemaVersion,
                storeID: meta.storeID,
                replayFloor: meta.replayFloor,
                providers: providerCatalog(),
                models: models,
                workflows: authority.workflowSnapshots(),
                executionModes: executionModeCatalog(),
                eventTypes: EventType.allCases,
                projectSources: authority.projectSourceCapabilities()
            ))
        } }
        router.get("/internal/v1/catalog/composer") { request, context in await respond(request) {
            let projectID = request.uri.queryParameters["projectId"].flatMap { UUID(uuidString: String($0)) }
            let sessionID = request.uri.queryParameters["sessionId"].flatMap { UUID(uuidString: String($0)) }
            guard (projectID != nil) != (sessionID != nil) else { throw ServiceAPIError(code: .invalidRequest, message: "Exactly one projectId or sessionId is required") }
            if let projectID {
                let auth = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getComposerCatalog", projectID: projectID)
                _ = try await authority.projectSnapshot(projectID: projectID)
                let actor = try requireActor(auth)
                return try await HTTPResponses.privateJSON(requireComposerCatalog().snapshot(context: .init(kind: .project, projectID: projectID, actorID: actor.userID)))
            }
            let resolvedSessionID = sessionID!
            let auth = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getComposerCatalog", sessionID: resolvedSessionID)
            let actor = try requireActor(auth)
            let snapshot = try await authority.authoritySessionSnapshot(sessionID: resolvedSessionID)
            let active = snapshot.activeRun.map { $0.endedAt == nil && $0.state == "running" } ?? false
            return try await HTTPResponses.privateJSON(requireComposerCatalog().snapshot(context: .init(kind: .session, projectID: snapshot.session.projectID, sessionID: resolvedSessionID, actorID: actor.userID, activeRun: active)))
        } }
        router.get("/internal/v1/catalog/composer-suggestions") { request, context in await respond(request) {
            let projectID = request.uri.queryParameters["projectId"].flatMap { UUID(uuidString: String($0)) }
            let sessionID = request.uri.queryParameters["sessionId"].flatMap { UUID(uuidString: String($0)) }
            guard (projectID != nil) != (sessionID != nil) else { throw ServiceAPIError(code: .invalidRequest, message: "Exactly one projectId or sessionId is required") }
            let query = String(request.uri.queryParameters["query"] ?? "")
            let kinds = Set(String(request.uri.queryParameters["kinds"] ?? "nativeCommand,skill,file").split(separator: ",").compactMap { ComposerSuggestionWire.Kind(rawValue: String($0)) })
            guard !kinds.isEmpty, kinds.count <= 3 else { throw ServiceAPIError(code: .invalidRequest, message: "Suggestion kinds are invalid") }
            if let projectID {
                let auth = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getComposerSuggestions", projectID: projectID)
                _ = try await authority.projectSnapshot(projectID: projectID)
                let actor = try requireActor(auth)
                return try await HTTPResponses.privateJSON(requireComposerCatalog().suggestions(context: .init(kind: .project, projectID: projectID, actorID: actor.userID), query: query, kinds: kinds, limit: 50))
            }
            let resolvedSessionID = sessionID!
            let auth = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getComposerSuggestions", sessionID: resolvedSessionID)
            let actor = try requireActor(auth)
            let snapshot = try await authority.authoritySessionSnapshot(sessionID: resolvedSessionID)
            let active = snapshot.activeRun.map { $0.endedAt == nil && $0.state == "running" } ?? false
            return try await HTTPResponses.privateJSON(requireComposerCatalog().suggestions(context: .init(kind: .session, projectID: snapshot.session.projectID, sessionID: resolvedSessionID, actorID: actor.userID, activeRun: active), query: query, kinds: kinds, limit: 50))
        } }
        router.get("/internal/v1/diagnostics") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.operatorRole], operation: "diagnostics")
            let meta = try await store.metadata()
            let currentReadiness = await readiness.snapshot(forceRefresh: true)
            return try await HTTPResponses.json(RepoPromptDiagnostics(
                storeID: meta.storeID,
                schemaVersion: meta.schemaVersion,
                nextGlobalSequence: meta.nextGlobalSequence,
                replayFloor: meta.replayFloor,
                readiness: currentReadiness,
                operational: currentReadiness.operational,
                drain: currentReadiness.drain,
                maintenance: durabilityOperations?.snapshot()
            ))
        } }
        router.get("/metrics") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.operatorRole], operation: "metrics")
            let meta = try await store.metadata()
            let currentReadiness = await readiness.snapshot()
            let operational = currentReadiness.operational
            var lines = [
                "repoprompt_ready \(currentReadiness.ready ? 1 : 0)",
                "repoprompt_event_latest_sequence \(max(0, meta.nextGlobalSequence - 1))",
                "repoprompt_event_replay_floor \(meta.replayFloor)",
                "repoprompt_event_live_count \(operational?.liveEventCount ?? 0)",
                "repoprompt_event_archive_segments \(operational?.archiveSegmentCount ?? 0)",
                "repoprompt_event_archive_events \(operational?.archivedEventCount ?? 0)",
                "repoprompt_event_archive_compressed_bytes \(operational?.compressedArchiveBytes ?? 0)",
                "repoprompt_active_sessions \(currentReadiness.activeSessionCount)",
                "repoprompt_degraded_projects \(currentReadiness.degradedProjectIDs.count)",
                "repoprompt_mutations_in_flight \(currentReadiness.drain.inFlightMutations)",
                "repoprompt_mutations_accepting \(currentReadiness.drain.acceptingMutations ? 1 : 0)",
                "repoprompt_process_families_active \(operational?.activeProcessFamilyCount ?? 0)",
                "repoprompt_sqlite_bytes \(operational?.databaseBytes ?? 0)",
                "repoprompt_sqlite_wal_bytes \(operational?.walBytes ?? 0)"
            ]
            for aggregate in operational?.ownedResources.aggregates ?? [] {
                lines.append("repoprompt_owned_resources{kind=\"\(aggregate.kind.rawValue)\",state=\"\(aggregate.state.rawValue)\"} \(aggregate.count)")
                lines.append("repoprompt_owned_resource_bytes{kind=\"\(aggregate.kind.rawValue)\",state=\"\(aggregate.state.rawValue)\"} \(aggregate.bytes)")
            }
            for checkpoint in operational?.checkpointCounts ?? [] {
                lines.append("repoprompt_checkpoints{retention=\"\(checkpoint.retentionClass)\"} \(checkpoint.count)")
            }
            let text = lines.joined(separator: "\n") + "\n"
            var headers = HTTPFields()
            headers[.contentType] = "text/plain; version=0.0.4"
            headers[.internalBodyDigest] = CanonicalSigning.bodyDigest(Data(text.utf8))
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: text)))
        } }

        router.get("/internal/v1/projects") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "listProjects")
            let projects = await authority.projectSnapshots().map(ProjectWireSnapshot.init)
            return try await HTTPResponses.json(page(projects, request: request, defaultLimit: 100, maximumLimit: 500) { $0.projectID.uuidString })
        } }
        router.post("/internal/v1/projects") { request, context in await respond(request) { let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "createProject")
            let input = try JSONDecoder.serviceDecoder.decode(CreateProjectWireInput.self, from: data)
            guard input.schemaVersion == 1, input.expectedRevision == 0 else {
                throw ServiceAPIError(code: .invalidRequest, message: "Project creation contract is invalid")
            }
            let actor = try requireActor(auth)
            let key = try requireIdempotency(request)
            let snapshot = try await authority.createProject(
                input: .init(name: input.name, roots: []),
                externalActor: actor,
                idempotencyKey: key,
                requestDigest: CanonicalSigning.bodyDigest(data),
                correlationID: input.operationID
            )
            return try HTTPResponses.json(ProjectWireSnapshot(snapshot), status: .created)
        } }
        router.post("/internal/v1/projects/:id/source-operations") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(
                request,
                context: context,
                body: data,
                roles: [.app],
                operation: "addProjectRepository",
                projectID: id
            )
            let input = try JSONDecoder.serviceDecoder.decode(AddProjectRepositoryInput.self, from: data)
            let actor = try requireActor(auth)
            let key = try requireIdempotency(request)
            let result = try await authority.addProjectRepository(
                projectID: id,
                input: input,
                externalActor: actor,
                idempotencyKey: key,
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            return try HTTPResponses.json(result, status: .created)
        } }
        router.patch("/internal/v1/projects/:id") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "renameProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(RenameProjectInput.self, from: data)
            let snapshot = try await authority.renameProject(projectID: id, input: input, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(ProjectWireSnapshot(snapshot))
        } }
        router.delete("/internal/v1/projects/:id") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "removeProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(RemoveProjectInput.self, from: data)
            try await authority.removeProject(projectID: id, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return HTTPResponses.empty()
        } }
        router.post("/internal/v1/projects/:id/composer-attachments") { request, context in await respond(request) {
            let projectID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request, maximumBytes: 10 * 1_024 * 1_024 + 64 * 1_024)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "createComposerAttachment", projectID: projectID)
            let actor = try requireActor(auth)
            let upload = try composerAttachmentUpload(data: data, contentType: request.headers[.contentType], fallbackDisplayName: String(request.uri.queryParameters["displayName"] ?? "image"))
            guard upload.displayName.utf8.count <= 256 else { throw ServiceAPIError(code: .invalidRequest, message: "Attachment display name exceeds its bound") }
            let attachment = try await requireComposerAttachments().stage(data: upload.data, displayName: upload.displayName, declaredMediaType: upload.mediaType, actorID: actor.userID, projectID: projectID)
            return try HTTPResponses.privateJSON(attachment, status: .created)
        } }
        router.post("/internal/v1/projects/:id/composer-attachments/resolve") { request, context in await respond(request) {
            let projectID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "resolveComposerAttachments", projectID: projectID)
            let input = try JSONDecoder.serviceDecoder.decode(ComposerAttachmentResolveRequest.self, from: data)
            let actor = try requireActor(auth)
            return try await HTTPResponses.privateJSON(requireComposerAttachments().resolve(attachmentIDs: input.attachmentIDs, actorID: actor.userID, projectID: projectID))
        } }
        router.get("/internal/v1/projects/:id/composer-attachments/:attachmentId/preview") { request, context in await respond(request) {
            let projectID = try context.parameters.require("id", as: UUID.self)
            let attachmentID = try context.parameters.require("attachmentId", as: UUID.self)
            let visibleSessionID = request.uri.queryParameters["sessionId"].flatMap { UUID(uuidString: String($0)) }
            let auth: AuthenticatedInternalRequest
            if let visibleSessionID {
                let session = try await authority.sessionSnapshot(sessionID: visibleSessionID)
                guard session.projectID == projectID else { throw ServiceAPIError(code: .notFound, message: "Attachment is unavailable") }
                auth = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "previewComposerAttachment", sessionID: visibleSessionID)
            } else {
                auth = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "previewComposerAttachment", projectID: projectID)
            }
            let actor = try requireActor(auth)
            let preview = try await requireComposerAttachments().preview(attachmentID: attachmentID, actorID: actor.userID, projectID: projectID, visibleSessionID: visibleSessionID)
            return HTTPResponses.privateBytes(preview.1, contentType: preview.0.mediaType)
        } }
        router.delete("/internal/v1/projects/:id/composer-attachments/:attachmentId") { request, context in await respond(request) {
            let projectID = try context.parameters.require("id", as: UUID.self)
            let attachmentID = try context.parameters.require("attachmentId", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "deleteComposerAttachment", projectID: projectID)
            let actor = try requireActor(auth)
                try await requireComposerAttachments().delete(attachmentID: attachmentID, actorID: actor.userID, projectID: projectID)
                return HTTPResponses.privateEmpty()
        } }
        router.get("/internal/v1/projects/:id/snapshot") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getProject", projectID: id)
            return try await HTTPResponses.json(ProjectWireSnapshot(authority.projectSnapshot(projectID: id)))
        } }
        router.get("/internal/v1/projects/:id/tree") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getProjectTree", projectID: id)
            let rootID = try requireQueryUUID(request, name: "rootId")
            let path = String(request.uri.queryParameters["path"] ?? "")
            let depth = request.uri.queryParameters.get("depth", as: Int.self) ?? 4
            let maximumEntries = request.uri.queryParameters.get("limit", as: Int.self) ?? 5000
            guard (0 ... 16).contains(depth), (1 ... 5000).contains(maximumEntries) else { throw ServiceAPIError(code: .invalidRequest, message: "Tree bounds exceed the v1 limit") }
            return try await HTTPResponses.json(authority.projectTree(projectID: id, request: ProjectTreeRequest(rootID: rootID, logicalPath: path, maximumDepth: depth, maximumEntries: maximumEntries)))
        } }
        router.post("/internal/v1/projects/:id/search") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.app], operation: "searchProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectSearchRequest.self, from: data)
            guard (1 ... 500).contains(input.maximumResults), (1 ... 2_097_152).contains(input.maximumFileBytes) else { throw ServiceAPIError(code: .invalidRequest, message: "Search bounds exceed the v1 limit") }
            return try await HTTPResponses.json(authority.projectSearch(projectID: id, request: input))
        } }
        router.post("/internal/v1/projects/:id/file") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.app], operation: "getFile", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectFileRequest.self, from: data)
            guard (1 ... 2_097_152).contains(input.maximumBytes) else { throw ServiceAPIError(code: .invalidRequest, message: "File bound exceeds the v1 limit") }
            return try await HTTPResponses.json(authority.projectFile(projectID: id, request: input))
        } }
        router.post("/internal/v1/projects/:id/codemap") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.app], operation: "getCodeMap", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectCodeMapRequest.self, from: data)
            guard (1 ... 5_242_880).contains(input.maximumBytes) else { throw ServiceAPIError(code: .invalidRequest, message: "CodeMap bound exceeds the v1 limit") }
            return try await HTTPResponses.json(authority.projectCodeMap(projectID: id, request: input))
        } }
        router.post("/internal/v1/projects/:id/diff") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.app], operation: "getDiff", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectDiffRequest.self, from: data)
            guard (1 ... 2_097_152).contains(input.maximumBytes) else { throw ServiceAPIError(code: .invalidRequest, message: "Diff bound exceeds the v1 limit") }
            return try await HTTPResponses.json(authority.projectDiff(projectID: id, request: input))
        } }
        router.get("/internal/v1/projects/:id/worktrees") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "listWorktrees", projectID: id)
            let worktrees = try await authority.worktreeSnapshots(projectID: id).map(WorktreeWireSnapshot.init)
            return try await HTTPResponses.json(page(worktrees, request: request, defaultLimit: 100, maximumLimit: 500) { $0.bindingID.uuidString })
        } }
        router.get("/internal/v1/projects/:id/worktrees/:worktreeId") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let bindingID = try context.parameters.require("worktreeId", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getWorktree", projectID: id)
            return try await HTTPResponses.json(WorktreeWireSnapshot(authority.worktreeSnapshot(projectID: id, bindingID: bindingID)))
        } }
        router.post("/internal/v1/projects/:id/refresh") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "refreshProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectRefreshInput.self, from: data)
            let snapshot = try await authority.refreshProject(projectID: id, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(ProjectWireSnapshot(snapshot))
        } }
        router.get("/internal/v1/projects/:id/context/selection-template") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getProject", projectID: id)
            return try await HTTPResponses.json(authority.projectSelectionTemplate(projectID: id))
        } }
        router.put("/internal/v1/projects/:id/context/selection-template") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "updateProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectSelectionTemplateMutationInput.self, from: data)
            return try await HTTPResponses.json(authority.replaceProjectSelectionTemplate(projectID: id, entries: input.entries, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data)))
        } }

        router.get("/internal/v1/sessions") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "listSessions")
            let sessions = try await authority.sessionSnapshots()
            return try await HTTPResponses.json(page(sessions, request: request, defaultLimit: 100, maximumLimit: 500) { $0.sessionID.uuidString })
        } }
        router.post("/internal/v1/sessions") { request, context in await respond(request) { let data = try await bodyData(request)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            let key = try requireIdempotency(request)
            if let structured = try? JSONDecoder.serviceDecoder.decode(AgentStartSessionWire.self, from: data) {
                guard let provider = structured.turn.configuration.providerID.runtimeKind else {
                    throw ServiceAPIError(code: .capabilityMissing, message: "Selected provider has no execution adapter")
                }
                let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "startSession", projectID: structured.projectID)
                let actor = try requireActor(auth)
                let selectedMessageContext = try structured.selectedMessageContext?.validated()
                let shell = CreateSessionInput(projectID: structured.projectID, provider: provider, model: structured.turn.configuration.modelID, visibility: structured.visibility, startImmediately: false)
                let accepted = try await authority.acceptStructuredSession(input: shell, coordinator: requireSubmissionCoordinator(), actor: actor, publicSubmissionKey: key, requestDigest: requestDigest, submission: structured.turn, selectedMessageContext: selectedMessageContext)
                try await requireSubmissionDispatchQueue().enqueue(accepted, actor: actor, requestDigest: requestDigest)
                return try HTTPResponses.privateJSON(accepted.receipt, status: .accepted)
            }
            let requestBody = try JSONDecoder.serviceDecoder.decode(CreateSessionRequest.self, from: data)
            let input: CreateSessionInput
            if requestBody.hasExplicitProviderRoute {
                input = try requestBody.explicitCreateSessionInput()
            } else {
                input = try await requireServerSettings().createSessionInput(from: requestBody)
            }
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "startSession", projectID: input.projectID)
            guard input.parentSessionID == nil else { throw ServiceAPIError(code: .invalidRequest, message: "Public session creation cannot specify parentSessionID; child agents are created by agent_manage") }
            let snapshot = try await authority.createSession(input: input, externalActor: requireActor(auth), idempotencyKey: key, requestDigest: requestDigest)
            return try HTTPResponses.privateJSON(snapshot, status: .accepted)
        } }
        router.get("/internal/v1/sessions/:id/snapshot") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getSession", sessionID: id)
            return try await HTTPResponses.privateJSON(authority.sessionDetailSnapshot(sessionID: id))
        } }
        router.get("/internal/v1/sessions/:id/transcript") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getTranscript", sessionID: id)
            let transcript = try await authority.sessionSnapshot(sessionID: id).transcript
            return try await HTTPResponses.json(page(transcript, request: request, defaultLimit: 200, maximumLimit: 1000) { String(format: "%020lld", $0.sessionSequence) })
        } }
        router.get("/internal/v1/sessions/:id/transcript/presentation") { request, context in await respond(request) {
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let auth = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getTranscriptPresentation", sessionID: sessionID)
            let actor = try requireActor(auth)
            let session = try await authority.sessionSnapshot(sessionID: sessionID)
            let metadata = try await authority.collaborationMetadata(sessionID: sessionID)
            let token = request.uri.queryParameters["pageToken"].map(String.init)
            let limit = request.uri.queryParameters.get("limit", as: Int.self) ?? 25
            let page = try await requireTranscriptPresentation().page(sessionID: sessionID, actorID: actor.userID, legacyTranscript: session.transcript, interactions: session.interactions, pageToken: token, limit: limit, mutableInteractions: metadata.controllerUserID == actor.userID)
            return try HTTPResponses.privateJSON(page)
        } }
        router.post("/internal/v1/sessions/:id/turns") { request, context in await respond(request) {
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "submitTurn", sessionID: sessionID)
            let actor = try requireActor(auth)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(AgentTurnSubmissionWire.self, from: data)
            let snapshot = try await authority.authoritySessionSnapshot(sessionID: sessionID)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: sessionID, actor: actor, operation: "submitTurn", requestDigest: requestDigest, authorizationDecision: auth.decision)
            let accepted = try await requireSubmissionCoordinator().acceptFollowup(session: snapshot.session, activeRun: snapshot.activeRun, actor: actor, publicSubmissionKey: key, requestDigest: requestDigest, submission: input)
            try await requireSubmissionDispatchQueue().enqueue(accepted, actor: actor, requestDigest: requestDigest)
            return try HTTPResponses.privateJSON(accepted.receipt, status: .accepted)
        } }
        router.post("/internal/v1/sessions/:id/commands") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let command = try JSONDecoder.serviceDecoder.decode(SessionCommand.self, from: data)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: command.operation, sessionID: id)
            let receipt = try await authority.execute(command: command, sessionID: id, externalActor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data), authorizationDecision: auth.decision)
            return try HTTPResponses.json(receipt, status: .accepted)
        } }
        router.get("/internal/v1/sessions/:id/context/selection") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getSelection", sessionID: id)
            return try await HTTPResponses.json(authority.selectionSnapshot(sessionID: id))
        } }
        router.put("/internal/v1/sessions/:id/context/selection") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "replaceSelection", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(SelectionMutationInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "replaceSelection", requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.replaceSelection(sessionID: id, entries: input.entries, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: key, requestDigest: requestDigest, authorizationDecision: auth.decision))
        } }
        router.post("/internal/v1/sessions/:id/context/selection/add") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "addToSelection", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(SelectionMutationInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "addToSelection", requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.addSelection(sessionID: id, entries: input.entries, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: key, requestDigest: requestDigest, authorizationDecision: auth.decision))
        } }
        router.post("/internal/v1/sessions/:id/context/selection/remove") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "removeFromSelection", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(SelectionRemovalInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "removeFromSelection", requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.removeSelection(sessionID: id, rootID: input.rootID, logicalPaths: input.logicalPaths, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: key, requestDigest: requestDigest, authorizationDecision: auth.decision))
        } }
        router.get("/internal/v1/sessions/:id/permissions") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getExecutionPermissions", sessionID: id)
            guard let snapshot = try await authority.permissionSnapshot(sessionID: id) else { return Response(status: .noContent) }
            return try HTTPResponses.json(snapshot)
        } }
        router.patch("/internal/v1/sessions/:id/permissions") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "updateExecutionPermissions", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(ExecutionPermissionUpdateInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "updateExecutionPermissions", requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.updatePermissions(sessionID: id, expectedRevision: input.expectedRevision, mode: input.mode, providerSettings: input.providerSettings, actor: requireActor(auth), idempotencyKey: key, requestDigest: requestDigest, authorizationDecision: auth.decision))
        } }
        router.patch("/internal/v1/sessions/:id/execution-permissions") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "updateExecutionPermissions", sessionID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ExecutionPermissionUpdateInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "updateExecutionPermissions", requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.updatePermissions(sessionID: id, expectedRevision: input.expectedRevision, mode: input.mode, providerSettings: input.providerSettings, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: requestDigest, authorizationDecision: auth.decision))
        } }
        router.patch("/internal/v1/sessions/:id/collaboration-metadata") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(CollaborationMetadataInput.self, from: data)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "setSessionVisibility", sessionID: id)
            return try await HTTPResponses.json(authority.updateCollaborationMetadata(sessionID: id, input: input, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data), authorizationDecision: auth.decision))
        } }
        router.get("/internal/v1/sessions/:id/interactions") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getInteractions", sessionID: id)
            let interactions = try await authority.interactionSnapshots(sessionID: id)
            return try await HTTPResponses.json(page(interactions, request: request, defaultLimit: 100, maximumLimit: 500) { $0.interactionID.uuidString })
        } }
        router.post("/internal/v1/sessions/:id/interactions/answer") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "answerInteraction", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(InteractionAnswerInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "answerInteraction", requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.answerInteraction(sessionID: id, interactionID: input.interactionID, expectedRevision: input.expectedRevision, payload: input.payload, actor: requireActor(auth), idempotencyKey: key, requestDigest: requestDigest, authorizationDecision: auth.decision))
        } }
        router.post("/internal/v1/sessions/:id/interactions/:interactionId/answer") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let interactionID = try context.parameters.require("interactionId", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "answerInteraction", sessionID: id)
            let input = try JSONDecoder.serviceDecoder.decode(InteractionAnswerInput.self, from: data)
            guard input.interactionID == interactionID else { throw ServiceAPIError(code: .invalidRequest, message: "Interaction path and body IDs do not match") }
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "answerInteraction", requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.answerInteraction(sessionID: id, interactionID: interactionID, expectedRevision: input.expectedRevision, payload: input.payload, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: requestDigest, authorizationDecision: auth.decision))
        } }
        router.post("/internal/v1/sessions/:id/worktrees") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "createWorktree", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(WorktreeCreateInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "createWorktree", requestDigest: requestDigest, authorizationDecision: auth.decision)
            let snapshot = try await authority.createWorktree(sessionID: id, rootID: input.rootID, baseRef: input.baseRef, branch: input.branch, actor: requireActor(auth), idempotencyKey: key, requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try HTTPResponses.json(WorktreeWireSnapshot(snapshot), status: .created)
        } }
        router.post("/internal/v1/sessions/:id/worktrees/merge") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "mergeWorktree", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(WorktreeMergeInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "mergeWorktree", requestDigest: requestDigest, authorizationDecision: auth.decision)
            let snapshot = try await authority.mergeWorktree(sessionID: id, bindingID: input.bindingID, strategy: input.strategy, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: key, requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try HTTPResponses.json(WorktreeWireSnapshot(snapshot))
        } }
        router.patch("/internal/v1/sessions/:id/worktree-binding") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "bindWorktree", sessionID: id)
            let input = try JSONDecoder.serviceDecoder.decode(WorktreeBindInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "bindWorktree", requestDigest: requestDigest, authorizationDecision: auth.decision)
            let snapshot = try await authority.bindWorktree(sessionID: id, bindingID: input.bindingID, expectedRevision: input.expectedRevision, expectedSelectionBindingRevision: input.expectedSelectionBindingRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try HTTPResponses.json(WorktreeWireSnapshot(snapshot))
        } }
        router.post("/internal/v1/sessions/:id/worktrees/:worktreeId/merge") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let bindingID = try context.parameters.require("worktreeId", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "mergeWorktree", sessionID: id)
            let input = try JSONDecoder.serviceDecoder.decode(WorktreeMergeInput.self, from: data)
            guard input.bindingID == bindingID else { throw ServiceAPIError(code: .invalidRequest, message: "Worktree path and body IDs do not match") }
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "mergeWorktree", requestDigest: requestDigest, authorizationDecision: auth.decision)
            let snapshot = try await authority.mergeWorktree(sessionID: id, bindingID: bindingID, strategy: input.strategy, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try HTTPResponses.json(WorktreeWireSnapshot(snapshot))
        } }
        router.get("/internal/v1/sessions/:id/artifacts") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getArtifacts", sessionID: id)
            let artifacts = try await authority.artifactSnapshots(sessionID: id)
            return try await HTTPResponses.json(page(artifacts, request: request, defaultLimit: 100, maximumLimit: 500) { $0.artifactID.uuidString })
        } }
        router.get("/internal/v1/sessions/:id/artifacts/:artifactId/content") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let artifactID = try context.parameters.require("artifactId", as: UUID.self)
            let requestedRange = try parseByteRange(request.headers[.range])
            let signedTarget = requestedRange.map {
                "\(request.uri.string)#range=bytes=\($0.lowerBound)-\($0.upperBound - 1)"
            } ?? request.uri.string
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "downloadArtifact", sessionID: id, pathAndQuery: signedTarget)
            let result = try await authority.artifactContent(sessionID: id, artifactID: artifactID, range: requestedRange)
            var headers = HTTPFields()
            headers[.contentType] = "application/octet-stream"
            headers[.cacheControl] = "no-store"
            headers[.contentLength] = String(result.1.count)
            headers[.internalBodyDigest] = CanonicalSigning.bodyDigest(result.1)
            let partial = result.2.lowerBound != 0 || result.2.upperBound != Int(result.0.size)
            if partial { headers[.contentRange] = "bytes \(result.2.lowerBound)-\(max(result.2.lowerBound, result.2.upperBound - 1))/\(result.0.size)" }
            return Response(status: partial ? .partialContent : .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: result.1)))
        } }
        router.get("/internal/v1/catalog/workflows") { request, context in await respond(request) {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "listWorkflows")
            let workflows = try await authority.workflowSnapshots()
            return try await HTTPResponses.json(page(workflows, request: request, defaultLimit: 100, maximumLimit: 500) { $0.workflowID })
        } }
        router.get("/internal/v1/catalog/workflows/:id") { request, context in await respond(request) {
            let id = try context.parameters.require("id")
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getWorkflow")
            return try await HTTPResponses.json(authority.workflowSnapshot(workflowID: id))
        } }
        router.get("/internal/v1/catalog/providers") { request, context in await respond(request) {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "listProviders")
            let providers = await providerCatalog()
            return try await HTTPResponses.json(page(providers, request: request, defaultLimit: 100, maximumLimit: 500) { $0.kind.rawValue })
        } }
        router.get("/internal/v1/catalog/models") { request, context in await respond(request) {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "listModels")
            let models = try await requireComposerCatalog().compatibilityModels()
            return try await HTTPResponses.json(page(models, request: request, defaultLimit: 100, maximumLimit: 500) { "\($0.providerID?.rawValue ?? $0.provider.rawValue):\($0.id)" })
        } }
        router.get("/internal/v1/catalog/execution-modes") { request, context in await respond(request) {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "listExecutionModes")
            return try await HTTPResponses.json(page(executionModeCatalog(), request: request, defaultLimit: 100, maximumLimit: 500) { $0.id })
        } }
        router.get("/internal/v1/sessions/:id/children") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "listSessionChildren", sessionID: id)
            let children = try await authority.childSessionSnapshots(parentSessionID: id)
            return try await HTTPResponses.json(page(children, request: request, defaultLimit: 100, maximumLimit: 500) { $0.sessionID.uuidString })
        } }
        router.post("/internal/v1/sessions/:id/context/build") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "buildContext", sessionID: id)
            _ = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(ContextBuildInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            return try await HTTPResponses.json(authority.buildContext(sessionID: id, expectedSelectionRevision: input.expectedSelectionRevision, include: input.include, actor: requireActor(auth), requestDigest: requestDigest, authorizationDecision: auth.decision), status: .created)
        } }
        router.post("/internal/v1/sessions/:id/context/context-builder") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "runContextBuilder", sessionID: id)
            _ = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(ContextBuilderInput.self, from: data)
            if let budget = input.budget, !(1 ... 1_000_000).contains(budget) {
                throw ServiceAPIError(code: .invalidRequest, message: "Context Builder budget exceeds the v1 bound")
            }
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "runContextBuilder", requestDigest: CanonicalSigning.bodyDigest(data), authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.runContextBuilder(sessionID: id, input: input, actor: requireActor(auth), origin: .internal, requestDigest: CanonicalSigning.bodyDigest(data), authorizationDecision: auth.decision))
        } }
        router.post("/internal/v1/sessions/:id/context/oracle") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "askOracle", sessionID: id)
            _ = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(OracleInput.self, from: data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "askOracle", requestDigest: CanonicalSigning.bodyDigest(data), authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.askOracle(sessionID: id, input: input, actor: requireActor(auth), requestDigest: CanonicalSigning.bodyDigest(data), authorizationDecision: auth.decision))
        } }

        router.get("/internal/v1/events") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.sync], operation: "events")
            let cursor = try parseCursor(request)
            let limit = request.uri.queryParameters.get("limit", as: Int.self) ?? 500
            guard (1 ... 1000).contains(limit) else {
                throw ServiceAPIError(code: .invalidRequest, message: "Event replay limit is outside the v1 bound")
            }
            return try await HTTPResponses.json(authority.events(after: cursor, limit: limit))
        } }
        router.get("/internal/v1/events/stream") { request, context in await respond(request, readAdmission: .subscription) { _ = try await authenticate(request, context: context, body: Data(), roles: [.sync], operation: "eventStream")
            let stream: AsyncThrowingStream<EventEnvelope, Error>
            do {
                stream = try await authority.subscribe(after: parseCursor(request))
            } catch let error as ServiceAPIError where error.code == .cursorExpired {
                return try cursorExpiredStream(error)
            }
            var headers = HTTPFields()
            headers[.contentType] = "text/event-stream"
            headers[.cacheControl] = "no-store"
            headers[.internalBodyDigest] = CanonicalSigning.bodyDigest(Data())
            return Response(status: .ok, headers: headers, body: ResponseBody { writer in try await writer.write(ByteBuffer(string: ": repoprompt-stream-v1\n\n"))
                for try await frame in heartbeatFrames(stream) {
                    switch frame {
                    case let .event(event):
                        let json = try String(decoding: JSONEncoder.serviceEncoder.encode(event), as: UTF8.self)
                        try await writer.write(ByteBuffer(string: "id: \(event.storeID.uuidString):\(event.globalSequence)\nevent: \(event.eventType.rawValue)\ndata: \(json)\n\n"))
                    case .heartbeat:
                        try await writer.write(ByteBuffer(string: ": heartbeat\n\n"))
                    }
                }
                try await writer.finish(nil)
            })
        } }
        router.get("/internal/v1/snapshot") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.sync], operation: "snapshot")
            let snapshot = try await authority.authoritativeSnapshot()
            let agents = try await authority.agentSnapshots()
            let titles = RepoPromptPortalSessionProjection.snapshotTitles(sessions: snapshot.sessions, agents: agents)
            return try HTTPResponses.json(AuthoritativeWireSnapshot(snapshot, sessionTitles: titles))
        } }
        router.post("/internal/v1/admin/checkpoint") { request, context in await respond(request) { let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.operatorRole], operation: "checkpoint")
            try await store.checkpoint()
            return HTTPResponses.empty()
        } }
        router.post("/internal/v1/admin/quiesce") { request, context in await respond(request) { let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.operatorRole], operation: "quiesce")
            await mutationGate.beginDraining()
            try await authority.quiesce()
            return HTTPResponses.empty(status: .accepted)
        } }

        return router
    }

    private func respond(
        _ request: Request,
        readAdmission: HTTPReadAdmission = .ordinary,
        _ operation: @escaping @Sendable () async throws -> Response
    ) async -> Response {
        let method = String(describing: request.method).uppercased()
        let path = request.uri.string
        let isMutation = method == "POST" || method == "PUT" || method == "PATCH" || method == "DELETE"
        let response: Response
        do {
            if isMutation {
                let capability = await mutationGate.capability()
                response = try await capability.perform(operation)
            } else {
                let capability = await mutationGate.readCapability(
                    subscription: readAdmission == .subscription
                )
                response = try await capability.perform(operation)
            }
        } catch {
            response = HTTPResponses.error(error)
        }
        return responseSigner.sign(response, requestPathAndQuery: path)
    }

    private func portalRespond(_ request: Request, _ operation: @escaping @Sendable () async throws -> Response) async -> Response {
        let method = String(describing: request.method).uppercased()
        let isMutation = method == "POST" || method == "PUT" || method == "PATCH" || method == "DELETE"
        let response: Response
        do {
            if isMutation {
                let capability = await mutationGate.capability()
                response = try await capability.perform(operation)
            } else {
                let capability = await mutationGate.readCapability()
                response = try await capability.perform(operation)
            }
        } catch { response = portalError(error) }
        return response
    }

    private struct PortalAuthenticatedPrincipal {
        let actorID: String
        let providerAttribution: ProviderMutationAttribution
        let settingsAttribution: SettingsMutationAttribution
        let externalActor: ExternalActor
    }

    private struct PortalAuthStatusResponse: Encodable {
        let needsSetup: Bool
        let authenticated: Bool
        let username: String?
        let passwordLoginEnabled: Bool
    }

    private struct PortalSetupRequest: Decodable {
        let password: String
        let passwordConfirmation: String
        let setupToken: String?
    }

    private struct PortalLoginRequest: Decodable {
        let username: String?
        let password: String
    }

    private func portalAuthStatus(request: Request, context: RepoPromptRequestContext) async throws -> PortalAuthStatusResponse {
        let hasAccount = try await store.hasOperatorAccount()
        let needsSetup = portalPasswordLoginEnabled && !hasAccount
        let principal = try? await authenticatePortal(request: request, context: context)
        return PortalAuthStatusResponse(
            needsSetup: needsSetup,
            authenticated: principal != nil,
            username: principal.map { $0.externalActor.username },
            passwordLoginEnabled: portalPasswordLoginEnabled
        )
    }

    private func completePortalSetup(request: Request, context: RepoPromptRequestContext) async throws -> Response {
        guard portalPasswordLoginEnabled else {
            throw ServiceAPIError(code: .invalidRequest, message: "Password setup is not enabled for this server")
        }
        let input = try JSONDecoder.serviceDecoder.decode(PortalSetupRequest.self, from: try await bodyData(request))
        guard input.password == input.passwordConfirmation else {
            throw ServiceAPIError(code: .invalidRequest, message: "Password confirmation does not match")
        }
        try await store.createOperatorAccount(
            password: input.password,
            setupToken: input.setupToken,
            allowMissingSetupToken: isLoopback(context)
        )
        let token = try await store.createOperatorSession()
        return portalSessionResponse(token: token, status: .created)
    }

    private func completePortalLogin(request: Request) async throws -> Response {
        guard portalPasswordLoginEnabled else {
            throw ServiceAPIError(code: .invalidRequest, message: "Password login is not enabled for this server")
        }
        let input = try JSONDecoder.serviceDecoder.decode(PortalLoginRequest.self, from: try await bodyData(request))
        let username = (input.username?.isEmpty == false ? input.username : nil) ?? SQLiteServiceStore.defaultOperatorUsername
        guard try await store.verifyOperatorPassword(username: username, password: input.password) else {
            throw ServiceAPIError(code: .internalAuthFailed, message: "Operator username or password is incorrect")
        }
        let token = try await store.createOperatorSession(username: username)
        return portalSessionResponse(token: token)
    }

    private func completePortalLogout(request: Request) async throws -> Response {
        if let token = operatorSessionToken(from: request) {
            try await store.deleteOperatorSession(token: token)
        }
        var response = try portalJSON(["ok": true])
        response.headers[.setCookie] = "rpce_operator_session=; Path=/portal; HttpOnly; SameSite=Strict; Secure; Max-Age=0"
        return response
    }

    private func portalSessionResponse(token: String, status: HTTPResponse.Status = .ok) -> Response {
        var response = (try? portalJSON(["ok": true], status: status)) ?? Response(status: status)
        response.headers[.setCookie] = "rpce_operator_session=\(token); Path=/portal; HttpOnly; SameSite=Strict; Secure; Max-Age=43200"
        return response
    }

    private func operatorSessionToken(from request: Request) -> String? {
        guard let header = request.headers[.cookie] else { return nil }
        return header.split(separator: ";").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("rpce_operator_session=") }
            .map { String($0.dropFirst("rpce_operator_session=".count)) }
    }

    private func isLoopback(_ context: RepoPromptRequestContext) -> Bool {
        guard let ip = context.channel.remoteAddress?.ipAddress else { return false }
        return ip == "127.0.0.1" || ip == "::1" || ip == "0:0:0:0:0:0:0:1"
    }

    private func authenticatePortal(request: Request, context: RepoPromptRequestContext) async throws -> PortalAuthenticatedPrincipal {
        if let token = operatorSessionToken(from: request),
           let username = try await store.operatorSessionUsername(token: token)
        {
            let actorID = "operator:\(username)"
            let actorLabel = "\(username) portal"
            return PortalAuthenticatedPrincipal(
                actorID: actorID,
                providerAttribution: ProviderMutationAttribution(actorID: actorID, actorLabel: actorLabel, channel: "portal-password"),
                settingsAttribution: SettingsMutationAttribution(actorID: actorID, actorLabel: actorLabel, channel: "portal-password"),
                externalActor: ExternalActor(userID: actorID, username: username, displayName: actorLabel)
            )
        }
        if portalPasswordLoginEnabled {
            throw ServiceAPIError(code: .internalAuthFailed, message: "Sign in to the operator portal")
        }
        guard let certificateRoleResolver else {
            throw ServiceAPIError(code: .internalAuthFailed, message: "Sign in to the operator portal")
        }
        let certificate: NIOSSLCertificate
        if let portalPeerCertificateDER {
            certificate = try NIOSSLCertificate(bytes: [UInt8](portalPeerCertificateDER), format: .der)
        } else {
            let peer: NIOSSLCertificate?
            do {
                peer = try await context.channel.nioSSL_peerCertificate().get()
            } catch {
                peer = nil
            }
            guard let peer else {
                throw ServiceAPIError(code: .internalAuthFailed, message: "An authorized portal client certificate is required")
            }
            certificate = peer
        }
        let role = try certificateRoleResolver.role(certificate: certificate)
        guard RepoPromptPortalCertificateAuthorization.allows(role) else {
            throw ServiceAPIError(code: .internalAuthFailed, message: "An authorized portal client certificate is required")
        }
        let digest = try SHA256.hash(data: Data(certificate.toDERBytes())).map { String(format: "%02x", $0) }.joined()
        let actorID = "certificate:\(digest)"
        let actorLabel = "\(role.rawValue) portal"
        return PortalAuthenticatedPrincipal(
            actorID: actorID,
            providerAttribution: ProviderMutationAttribution(actorID: actorID, actorLabel: actorLabel, channel: "portal-mtls"),
            settingsAttribution: SettingsMutationAttribution(actorID: actorID, actorLabel: actorLabel, channel: "portal-mtls"),
            externalActor: ExternalActor(userID: actorID, username: actorLabel, displayName: actorLabel)
        )
    }

    private func portalIdempotencyKey(principal: PortalAuthenticatedPrincipal, operationID: UUID) -> String {
        "portal:\(principal.actorID):\(operationID.uuidString.lowercased())"
    }

    private func providerSettingsID(_ context: RepoPromptRequestContext) throws -> ProviderSettingsID {
        let id = try context.parameters.require("id")
        guard let providerID = ProviderSettingsID(rawValue: id) else {
            throw ServiceAPIError(code: .notFound, message: "Provider settings not found")
        }
        return providerID
    }

    private func requirePortalDesktopSettings() -> PortalDesktopSettingsService {
        portalDesktopSettings
    }

    private func requireProviderSettings() throws -> ProviderSettingsService {
        guard let providerSettings else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider settings are unavailable", retryable: true)
        }
        return providerSettings
    }

    private func requireServerSettings() throws -> ServerSettingsService {
        guard let serverSettings else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Server settings are unavailable", retryable: true)
        }
        return serverSettings
    }

    private func requireComposerCatalog() throws -> any AgentComposerCatalogProviding {
        guard let composerCatalog else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Agent composer catalog is unavailable", retryable: true) }
        return composerCatalog
    }

    private func requireComposerAttachments() throws -> AgentComposerAttachmentStore {
        guard let composerAttachments else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Agent composer attachments are unavailable", retryable: true) }
        return composerAttachments
    }

    private func requireSubmissionCoordinator() throws -> AgentSubmissionCoordinator {
        guard let submissionCoordinator else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Agent submission coordinator is unavailable", retryable: true) }
        return submissionCoordinator
    }

    private func requireSubmissionDispatchQueue() throws -> AgentSubmissionDispatchQueue {
        guard let submissionDispatchQueue else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Agent submission dispatch queue is unavailable", retryable: true) }
        return submissionDispatchQueue
    }

    private func requireTranscriptPresentation() throws -> AgentTranscriptPresentationService {
        guard let transcriptPresentation else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Agent transcript presentation is unavailable", retryable: true) }
        return transcriptPresentation
    }

    private func providerAttribution(_ auth: AuthenticatedInternalRequest) -> ProviderMutationAttribution {
        if let actor = auth.decision?.actor {
            return .init(actorID: actor.userID, actorLabel: actor.username, channel: "app")
        }
        return .init(actorID: "signing-key:\(auth.keyID)", actorLabel: auth.role.rawValue, channel: "internal-hmac")
    }

    static func decodeStrictWorkflowPayload<Value: Decodable>(
        _ type: Value.Type,
        data: Data,
        allowedKeys: Set<String>
    ) throws -> Value {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: allowedKeys) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Workflow request contains unsupported fields")
        }
        return try JSONDecoder.serviceDecoder.decode(type, from: data)
    }

    private func portalJSON(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try JSONEncoder.serviceEncoder.encode(value)
        var headers = RepoPromptPortalAssets.securityHeaders(contentType: "application/json; charset=utf-8")
        headers[.cacheControl] = "private, no-store"
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private func portalError(_ error: Error) -> Response {
        let apiError = error as? ServiceAPIError ?? ServiceAPIError(code: .dependencyUnavailable, message: "Portal dependency failed", retryable: true)
        let status: HTTPResponse.Status = switch apiError.code {
        case .invalidRequest: .badRequest
        case .internalAuthFailed: .unauthorized
        case .authorizationDecisionRejected: .forbidden
        case .notFound: .notFound
        case .staleRevision, .controllerChanged: .conflict
        case .rateLimited: .tooManyRequests
        case .dependencyUnavailable, .quiescing, .persistenceUnavailable, .serviceDraining, .staleCapability: .serviceUnavailable
        default: .unprocessableContent
        }
        return (try? portalJSON(apiError, status: status)) ?? Response(status: .internalServerError)
    }

    private func validatePortalMutation(_ request: Request) throws {
        try RepoPromptPortalRequestProtection.validateMutation(
            origin: request.headers[.init("Origin")!],
            host: request.head.authority,
            fetchSite: request.headers[.init("Sec-Fetch-Site")!],
            contentType: request.headers[.contentType],
            csrfHeader: request.headers[.init("X-RepoPrompt-Portal-CSRF")!]
        )
    }

    private func portalBootstrap() async throws -> PortalBootstrapResponse {
        let projects = await authority.projectSnapshots().map(RepoPromptPortalSessionProjection.project)
        let sessions = try await authority.sessionSnapshots().map(RepoPromptPortalSessionProjection.project)
        let workflowRepository = try await authority.workflowRepositorySnapshot()
        let workflows = try await authority.workflowSnapshots().map {
            PortalWorkflowSummary(
                workflowID: $0.workflowID,
                name: $0.name,
                source: ServerWorkflowSource(rawValue: $0.source) ?? .builtin,
                enabled: $0.enabled,
                visible: $0.visible,
                featuredOrder: $0.featuredOrder,
                rowRevision: $0.rowRevision
            )
        }
        return PortalBootstrapResponse(
            projects: projects,
            sessions: sessions,
            workflows: workflows,
            tools: RepoPromptPortalSessionProjection.tools(),
            workflowRepositoryRevision: workflowRepository.revision,
            includeSessionCleanupGuidance: workflowRepository.includeSessionCleanupGuidance
        )
    }

    private struct PageToken: Codable {
        let storeID: UUID
        let globalSequence: Int64
        let offset: Int

        private enum CodingKeys: String, CodingKey {
            case storeID = "storeId"
            case globalSequence, offset
        }
    }

    private func page<Item: Codable & Sendable>(
        _ items: [Item],
        request: Request,
        defaultLimit: Int,
        maximumLimit: Int,
        sortKey: (Item) -> String
    ) async throws -> Page<Item> {
        let requestedLimit = request.uri.queryParameters.get("limit", as: Int.self) ?? defaultLimit
        guard requestedLimit > 0, requestedLimit <= maximumLimit else {
            throw ServiceAPIError(code: .invalidRequest, message: "Pagination limit is outside the v1 bound")
        }
        let metadata = try await store.metadata()
        let cursor = ServiceCursor(storeID: metadata.storeID, globalSequence: max(0, metadata.nextGlobalSequence - 1))
        let offset: Int
        if let encoded = request.uri.queryParameters["pageToken"] {
            guard let data = CanonicalSigning.base64URLDecode(String(encoded)),
                  let token = try? JSONDecoder.serviceDecoder.decode(PageToken.self, from: data),
                  token.storeID == cursor.storeID,
                  token.globalSequence == cursor.globalSequence,
                  token.offset >= 0
            else {
                throw ServiceAPIError(code: .staleRevision, message: "Pagination token is stale or invalid", cursor: cursor)
            }
            offset = token.offset
        } else {
            offset = 0
        }
        let ordered = items.sorted { sortKey($0) < sortKey($1) }
        guard offset <= ordered.count else { throw ServiceAPIError(code: .invalidRequest, message: "Pagination offset is invalid") }
        let end = min(ordered.count, offset + requestedLimit)
        let nextToken: String? = if end < ordered.count {
            try CanonicalSigning.base64URLEncode(JSONEncoder.serviceEncoder.encode(PageToken(storeID: cursor.storeID, globalSequence: cursor.globalSequence, offset: end)))
        } else {
            nil
        }
        return Page(items: Array(ordered[offset ..< end]), nextPageToken: nextToken, cursor: cursor)
    }

    private func providerCatalog() async -> [ProviderCatalogItem] {
        await authority.providerCapabilities().map { capability in
            ProviderCatalogItem(
                kind: capability.kind,
                enabled: capability.enabled,
                version: capability.version,
                protocolVersion: capability.protocolVersion,
                supportsResume: capability.supportsResume,
                supportsSteering: capability.supportsSteering,
                reasonUnavailable: capability.reasonUnavailable == nil ? nil : "provider_unavailable"
            )
        }
    }

    private func executionModeCatalog() -> [ExecutionModeCatalogItem] {
        let providers = ProviderKind.allCases
        return [
            .init(id: "readOnly", displayName: "Read only", allowsWorkspaceWrites: false, allowsUnrestrictedHostAccess: false, providers: providers),
            .init(id: "workspaceWrite", displayName: "Workspace write", allowsWorkspaceWrites: true, allowsUnrestrictedHostAccess: false, providers: providers),
            .init(id: "fullAccess", displayName: "Full access", allowsWorkspaceWrites: true, allowsUnrestrictedHostAccess: true, providers: providers)
        ]
    }

    private func bodyData(_ request: Request, maximumBytes: Int = 1_048_576) async throws -> Data {
        let buffer = try await request.body.collect(upTo: maximumBytes)
        return Data(buffer.readableBytesView)
    }

    private func composerAttachmentUpload(data: Data, contentType: String?, fallbackDisplayName: String) throws -> (data: Data, mediaType: String?, displayName: String) {
        guard let contentType, contentType.lowercased().hasPrefix("multipart/form-data") else {
            return (data, contentType?.split(separator: ";", maxSplits: 1).first.map(String.init), fallbackDisplayName)
        }
        let parameters = contentType.split(separator: ";").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        guard let boundaryParameter = parameters.first(where: { $0.lowercased().hasPrefix("boundary=") }) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Multipart attachment boundary is missing")
        }
        var boundary = String(boundaryParameter.dropFirst("boundary=".count))
        if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") { boundary = String(boundary.dropFirst().dropLast()) }
        guard !boundary.isEmpty, boundary.utf8.count <= 200 else { throw ServiceAPIError(code: .invalidRequest, message: "Multipart attachment boundary is invalid") }
        let headerTerminator = Data("\r\n\r\n".utf8)
        let nextBoundary = Data("\r\n--\(boundary)".utf8)
        guard let headerEnd = data.range(of: headerTerminator), headerEnd.lowerBound <= 16 * 1_024,
              let bodyEnd = data.range(of: nextBoundary, in: headerEnd.upperBound ..< data.endIndex),
              let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
        else { throw ServiceAPIError(code: .invalidRequest, message: "Multipart attachment body is malformed") }
        let lines = headerText.components(separatedBy: "\r\n")
        let disposition = lines.first { $0.lowercased().hasPrefix("content-disposition:") } ?? ""
        guard disposition.lowercased().contains("form-data"), disposition.lowercased().contains("name=\"file\"") else {
            throw ServiceAPIError(code: .invalidRequest, message: "Multipart attachment requires one file field")
        }
        let filename = disposition.range(of: "filename=\"").flatMap { start -> String? in
            let suffix = disposition[start.upperBound...]
            guard let end = suffix.firstIndex(of: "\"") else { return nil }
            return String(suffix[..<end])
        }
        let mediaType = lines.first { $0.lowercased().hasPrefix("content-type:") }.map { String($0.dropFirst("content-type:".count)).trimmingCharacters(in: .whitespaces) }
        let payload = Data(data[headerEnd.upperBound ..< bodyEnd.lowerBound])
        guard payload.count <= 10 * 1_024 * 1_024 else { throw ServiceAPIError(code: .invalidRequest, message: "Image exceeds the 10 MiB item limit") }
        return (payload, mediaType, filename ?? fallbackDisplayName)
    }

    private func authenticate(_ request: Request, context: RepoPromptRequestContext, body: Data, roles: Set<InternalRouteRole>, operation: String, projectID: UUID? = nil, sessionID: UUID? = nil, pathAndQuery: String? = nil) async throws -> AuthenticatedInternalRequest {
        guard let keyID = request.headers[.internalKeyID], let timestamp = request.headers[.internalTimestamp], let nonce = request.headers[.internalNonce], let bodyDigest = request.headers[.internalBodyDigest], let signature = request.headers[.internalSignature] else { throw ServiceAPIError(code: .internalAuthFailed, message: "Signed internal headers are required") }
        let decisionHeader = request.headers[.authorizationDecision]
        let decisionData = decisionHeader.flatMap(CanonicalSigning.base64URLDecode)
        let authenticated = try await authenticator.verify(SignedInternalRequest(method: String(describing: request.method), pathAndQuery: pathAndQuery ?? request.uri.string, timestamp: timestamp, nonce: nonce, body: body, bodyDigest: bodyDigest, authorizationDecisionData: decisionData, authorizationDecisionDigest: request.headers[.internalAuthorizationDigest], keyID: keyID, signature: signature), allowedRoles: roles, operation: operation, projectID: projectID, sessionID: sessionID)
        if let certificateRoleResolver {
            guard let certificate = try await context.channel.nioSSL_peerCertificate().get() else { throw ServiceAPIError(code: .internalAuthFailed, message: "A client certificate is required") }
            guard try certificateRoleResolver.role(certificate: certificate) == authenticated.role else { throw ServiceAPIError(code: .internalAuthFailed, message: "Client certificate and HMAC roles do not match") }
        }
        return authenticated
    }

    private func requireActor(_ auth: AuthenticatedInternalRequest) throws -> ExternalActor {
        guard let actor = auth.decision?.actor else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Human actor attribution is required") }
        return actor
    }

    private func requireIdempotency(_ request: Request) throws -> String {
        guard let value = request.headers[.idempotencyKey], !value.isEmpty else { throw ServiceAPIError(code: .invalidRequest, message: "Idempotency-Key is required") }
        return value
    }

    private func requireQueryUUID(_ request: Request, name: String) throws -> UUID {
        guard let value = request.uri.queryParameters[Substring(name)], let id = UUID(uuidString: String(value)) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Query parameter \(name) must be a UUID")
        }
        return id
    }

    private func parseCursor(_ request: Request) throws -> ServiceCursor? {
        let query = request.uri.queryParameters["after"].map(String.init)
        let header = request.headers[.init("Last-Event-ID")!]
        if let query, let header, query != header {
            throw ServiceAPIError(code: .invalidRequest, message: "after and Last-Event-ID cursors disagree")
        }
        guard let after = query ?? header else { return nil }
        let parts = after.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let storeID = UUID(uuidString: String(parts[0])), let sequence = Int64(parts[1]), sequence >= 0 else { throw ServiceAPIError(code: .invalidRequest, message: "Cursor must be storeId:sequence") }
        return ServiceCursor(storeID: storeID, globalSequence: sequence)
    }

    private func parseByteRange(_ value: String?) throws -> Range<Int>? {
        guard let value else { return nil }
        guard value.hasPrefix("bytes="), !value.contains(",") else { throw ServiceAPIError(code: .invalidRequest, message: "Only one bounded byte range is supported") }
        let bounds = value.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let lower = Int(bounds[0]), let inclusiveUpper = Int(bounds[1]), lower >= 0, inclusiveUpper >= lower, inclusiveUpper < Int.max, inclusiveUpper - lower < 8 * 1024 * 1024 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Byte range must be bytes=start-end")
        }
        return lower ..< inclusiveUpper + 1
    }

    private func heartbeatFrames(_ source: AsyncThrowingStream<EventEnvelope, Error>) -> AsyncThrowingStream<SSEFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await event in source {
                                continuation.yield(.event(event))
                            }
                        }
                        group.addTask {
                            while !Task.isCancelled {
                                try await Task.sleep(for: .seconds(15))
                                continuation.yield(.heartbeat)
                            }
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func cursorExpiredStream(_ error: ServiceAPIError) throws -> Response {
        guard let cursor = error.cursor else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Cursor transition metadata is unavailable", retryable: true)
        }
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-store"
        let transition = CursorExpiredResponse(storeID: cursor.storeID, replayFloor: cursor.globalSequence)
        let payload = try String(decoding: JSONEncoder.serviceEncoder.encode(transition), as: UTF8.self)
        return Response(status: .ok, headers: headers, body: ResponseBody { writer in
            try await writer.write(ByteBuffer(string: "event: cursor_expired\ndata: \(payload)\n\n"))
            try await writer.finish(nil)
        })
    }
}
