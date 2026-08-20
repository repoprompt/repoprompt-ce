import Foundation
import RepoPromptRuntimeModel

public struct AuthorityStoreMetadata: Codable, Hashable, Sendable {
    public let storeID: UUID
    public let schemaVersion: Int
    public let nextGlobalSequence: Int64
    public let replayFloor: Int64
    public let lastCleanShutdown: Bool
    public let activationState: String
    public let activationGeneration: Int64
    public let activationInstanceID: UUID?

    public init(
        storeID: UUID,
        schemaVersion: Int,
        nextGlobalSequence: Int64,
        replayFloor: Int64,
        lastCleanShutdown: Bool,
        activationState: String,
        activationGeneration: Int64,
        activationInstanceID: UUID?
    ) {
        self.storeID = storeID
        self.schemaVersion = schemaVersion
        self.nextGlobalSequence = nextGlobalSequence
        self.replayFloor = replayFloor
        self.lastCleanShutdown = lastCleanShutdown
        self.activationState = activationState
        self.activationGeneration = activationGeneration
        self.activationInstanceID = activationInstanceID
    }
}

/// Behavior-preserving persistence seam extracted from the prototype store.
/// The raw requirements intentionally have distinct names so public convenience
/// methods can retain the prototype's default-argument semantics on existentials.
public protocol RepoPromptAuthorityStore:
    ComposerAttachmentStore,
    ComposerCatalogStore,
    AgentSubmissionStore,
    AgentTranscriptStore,
    ProviderSettingsStore,
    WorkflowRepositoryStore,
    Sendable
{
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_advanceSemanticWatermark(sessionID: UUID, semanticSequence: Int64, legacySequence: Int64, gapDetected: Bool, at date: Date) async throws
    /// ServerSettingsRepositories.swift
    func authorityStore_advancedServerSettingsDocument() async throws -> StoredSettingsDocument<AdvancedServerSettings>?
    /// ServerSettingsRepositories.swift
    func authorityStore_agentModelsDocument(scopeID: String) async throws -> StoredSettingsDocument<AgentModelsScopeDocument>?
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_agentSubmission(actorID: String, targetKey: String, operation: String, publicKey: String) async throws -> AgentSubmissionRecord?
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_agentSubmission(submissionID: UUID) async throws -> AgentSubmissionRecord?
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_agentSubmissions(state: AgentSubmissionState?, dispatchState: String?, limit: Int) async throws -> [AgentSubmissionRecord]
    /// SQLiteServiceStore.swift
    func authorityStore_agents(rootSessionID: UUID?) async throws -> [AgentSnapshot]
    /// SQLiteServiceStore.swift
    func authorityStore_allProjects() async throws -> [ProjectSnapshot]
    /// SQLiteServiceStore.swift
    func authorityStore_allSessions() async throws -> [SessionSnapshot]
    /// SQLiteServiceStore.swift
    func authorityStore_allSessionsWithInteractions() async throws -> [SessionSnapshot]
    /// SQLiteServiceStore.swift
    func authorityStore_appendProviderConnectionAudit(providerID: ProviderSettingsID, connectionID: UUID?, operation: String, attribution: ProviderMutationAttribution, authenticationMethod: ProviderAuthenticationMethod?, result: String) async throws
    /// SQLiteServiceStore.swift
    func authorityStore_artifact(id: UUID) async throws -> (snapshot: ArtifactSnapshot, storageReference: String)?
    /// SQLiteServiceStore.swift
    func authorityStore_artifacts(sessionID: UUID) async throws -> [(snapshot: ArtifactSnapshot, storageReference: String)]
    /// WorkflowRepositoryStore.swift
    func authorityStore_bootstrapWorkflowRepository(builtins: [WorkflowSnapshot], now: Date) async throws
    /// SQLiteServiceStore.swift
    func authorityStore_checkpoint() async throws
    /// SQLiteServiceStore.swift
    func authorityStore_collaboration(sessionID: UUID) async throws -> CollaborationMetadataSnapshot?
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_commitAgentSubmission(
        record: AgentSubmissionRecord,
        turn: SemanticTurnRecord,
        nextDefaults: SessionNextTurnDefaultsRecord,
        runPresentation: RunPresentationSnapshot,
        receipt: SubmissionReceipt,
        newSession: PreparedNewAgentSession?
    ) async throws -> NewAgentSessionAcceptanceEvents?
    /// ComposerAttachmentRepository.swift
    func authorityStore_composerAttachment(attachmentID: UUID) async throws -> StoredComposerAttachment?
    /// ComposerAttachmentRepository.swift
    func authorityStore_composerAttachments(actorID: String?, projectID: UUID?, lifecycle: ComposerAttachmentLifecycle?) async throws -> [StoredComposerAttachment]
    /// ComposerProviderCatalogCacheRepository.swift
    func authorityStore_composerProviderCatalog(providerID: ProviderSettingsID) async throws -> StoredComposerProviderCatalog?
    /// ServerSettingsRepositories.swift
    func authorityStore_contextBuilderDocument(scopeID: String) async throws -> StoredSettingsDocument<ContextBuilderScopeDocument>?
    /// ComposerAttachmentRepository.swift
    func authorityStore_deleteComposerAttachment(attachmentID: UUID) async throws
    /// SQLiteServiceStore.swift
    func authorityStore_deleteProviderConnection(
        providerID: ProviderSettingsID,
        expectedRevision: Int64,
        audit: ProviderConnectionAuditMutation?
    ) async throws
    /// ServerSettingsRepositories.swift
    func authorityStore_directAgentPermissionDocument() async throws -> StoredSettingsDocument<DirectAgentPermissionsSettings>?
    /// SQLiteServiceStore.swift
    func authorityStore_events(after cursor: ServiceCursor?, limit: Int) async throws -> EventPage
    /// SQLiteServiceStore.swift
    func authorityStore_idempotencyResult(_ input: IdempotencyInput) async throws -> (response: Data, status: Int)?
    /// SQLiteServiceStore.swift
    func authorityStore_installInitialPolicies(permissions: ExecutionPermissionSnapshot, collaboration: CollaborationMetadataSnapshot) async throws
    /// SQLiteServiceStore.swift
    func authorityStore_installWorkflows(_ workflows: [WorkflowSnapshot]) async throws
    /// SQLiteServiceStore.swift
    func authorityStore_interactions(sessionID: UUID) async throws -> [InteractionSnapshot]
    /// SQLiteServiceStore.swift
    func authorityStore_latestRun(sessionID: UUID) async throws -> ProviderRunSnapshot?
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_latestSemanticSequence(sessionID: UUID) async throws -> Int64
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_markSubmissionDispatch(submissionID: UUID, state: String, at date: Date) async throws
    /// ServerSettingsRepositories.swift
    func authorityStore_mcpDisabledToolsDocument() async throws -> StoredSettingsDocument<MCPDisabledToolsSettings>?
    /// ServerSettingsRepositories.swift
    func authorityStore_mcpModelPresetsDocument() async throws -> StoredSettingsDocument<[MCPModelPreset]>?
    /// ServerSettingsRepositories.swift
    func authorityStore_mcpShowModelPresetsDocument() async throws -> StoredSettingsDocument<MCPShowModelPresetsSettings>?
    /// SQLiteServiceStore.swift
    func authorityStore_metadata() async throws -> AuthorityStoreMetadata
    /// SQLiteServiceStore.swift
    func authorityStore_nextCursor() async throws -> ServiceCursor
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_nextTurnDefaults(sessionID: UUID) async throws -> SessionNextTurnDefaultsRecord?
    /// SQLiteServiceStore.swift
    func authorityStore_oracleChat(chatID: UUID) async throws -> OracleChatState?
    /// SQLiteServiceStore.swift
    func authorityStore_permissions(sessionID: UUID) async throws -> ExecutionPermissionSnapshot?
    /// SQLiteServiceStore.swift
    func authorityStore_persistAgent(_ snapshot: AgentSnapshot, projectID: UUID, actor: ExternalActor?, correlationID: UUID, eventType: EventType) async throws -> EventEnvelope
    /// SQLiteServiceStore.swift
    func authorityStore_persistArtifact(_ snapshot: ArtifactSnapshot, storageReference: String, actor: ExternalActor?, correlationID: UUID) async throws -> EventEnvelope
    /// SQLiteServiceStore.swift
    func authorityStore_persistCollaboration(_ metadata: CollaborationMetadataSnapshot, session: SessionSnapshot, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput, idempotencyResponse: Data?) async throws -> [EventEnvelope]
    /// ComposerProviderCatalogCacheRepository.swift
    func authorityStore_persistComposerProviderCatalog(_ record: StoredComposerProviderCatalog) async throws
    /// SQLiteServiceStore.swift
    func authorityStore_persistInteraction(_ snapshot: InteractionSnapshot, session: SessionSnapshot, actor: ExternalActor?, correlationID: UUID, idempotency: IdempotencyInput?) async throws -> EventEnvelope
    /// SQLiteServiceStore.swift
    func authorityStore_persistInteractionDeliveryState(_ snapshot: InteractionSnapshot, sessionID: UUID, actor: ExternalActor?) async throws
    /// SQLiteServiceStore.swift
    func authorityStore_persistNewSession(
        _ snapshot: SessionSnapshot,
        agent: AgentSnapshot,
        actor: ExternalActor,
        correlationID: UUID,
        agentCorrelationID: UUID,
        idempotency: IdempotencyInput,
        initialSelection: SelectionSnapshot,
        initialPermissions: ExecutionPermissionSnapshot,
        initialCollaboration: CollaborationMetadataSnapshot,
        initialWorktrees: [WorktreeBindingSnapshot]
    ) async throws -> (session: EventEnvelope, agent: EventEnvelope, worktrees: [EventEnvelope])
    /// SQLiteServiceStore.swift
    func authorityStore_persistOracleChat(_ chat: OracleChatState) async throws
    /// SQLiteServiceStore.swift
    func authorityStore_persistPermissions(_ snapshot: ExecutionPermissionSnapshot, projectID: UUID, rootSessionID: UUID, correlationID: UUID, idempotency: IdempotencyInput?) async throws -> EventEnvelope
    /// SQLiteServiceStore.swift
    func authorityStore_persistProject(
        _ snapshot: ProjectSnapshot,
        rootIdentities: [UUID: String],
        eventType: EventType,
        actor: ExternalActor,
        correlationID: UUID,
        idempotency: IdempotencyInput?,
        expectedRevision: Int64?,
        idempotencyResponse: Data?,
        idempotencyStatus: Int?
    ) async throws -> EventEnvelope
    /// SQLiteServiceStore.swift
    func authorityStore_persistRun(_ snapshot: ProviderRunSnapshot) async throws
    /// SQLiteServiceStore.swift
    func authorityStore_persistSelection(_ snapshot: SelectionSnapshot, projectID: UUID, rootSessionID: UUID, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput?) async throws -> EventEnvelope
    /// SQLiteServiceStore.swift
    func authorityStore_persistSelectionTemplate(_ snapshot: ProjectSelectionTemplateSnapshot, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput) async throws -> EventEnvelope
    /// SQLiteServiceStore.swift
    func authorityStore_persistServiceDiagnostic(
        projectID: UUID,
        actor: ExternalActor?,
        correlationID: UUID,
        payload: Data
    ) async throws -> EventEnvelope
    /// SQLiteServiceStore.swift
    func authorityStore_persistSession(
        _ snapshot: SessionSnapshot,
        eventType: EventType,
        actor: ExternalActor?,
        correlationID: UUID,
        idempotency: IdempotencyInput?,
        idempotencyResponse: Data?,
        initialSelection: SelectionSnapshot?
    ) async throws -> EventEnvelope
    /// SQLiteServiceStore.swift
    func authorityStore_persistSessionContext(
        _ snapshot: SessionContextSnapshot,
        session: SessionSnapshot,
        actor: ExternalActor,
        correlationID: UUID
    ) async throws -> EventEnvelope
    /// SQLiteServiceStore.swift
    func authorityStore_persistToolInvocation(
        _ snapshot: ToolInvocationSnapshot,
        session: SessionSnapshot,
        actor: ExternalActor?,
        correlationID: UUID,
        eventType: EventType
    ) async throws -> EventEnvelope
    /// SQLiteServiceStore.swift
    func authorityStore_persistWorktree(_ snapshot: WorktreeBindingSnapshot, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput?) async throws -> EventEnvelope
    /// SQLiteServiceStore.swift
    func authorityStore_persistWorktreeBinding(_ worktree: WorktreeBindingSnapshot, selection: SelectionSnapshot, session: SessionSnapshot, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput) async throws -> (worktree: EventEnvelope, selection: EventEnvelope)
    /// SQLiteServiceStore.swift
    func authorityStore_persistWorktrees(
        _ snapshots: [WorktreeBindingSnapshot],
        actor: ExternalActor,
        correlationID: UUID
    ) async throws -> [EventEnvelope]
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_prepareAgentSubmission(_ record: AgentSubmissionRecord) async throws -> AgentSubmissionRecord
    /// SQLiteServiceStore.swift
    func authorityStore_projectRootIdentities(projectID: UUID) async throws -> [UUID: String]
    /// ServerSettingsRepositories.swift
    func authorityStore_projectSelectionPresetsDocument(projectID: UUID) async throws -> StoredSettingsDocument<[ProjectSelectionPreset]>?
    /// SQLiteServiceStore.swift
    func authorityStore_providerConnections() async throws -> [StoredProviderConnection]
    /// DirectProviderStore.swift
    func authorityStore_providerModelCatalog(providerID: ProviderSettingsID) async throws -> ProviderModelCatalogSnapshot?
    /// DirectProviderStore.swift
    func authorityStore_providerModelCatalogs() async throws -> [ProviderModelCatalogSnapshot]
    /// SQLiteServiceStore.swift
    func authorityStore_providerSettings() async throws -> [ProviderSettingsPreference]
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_rejectAgentSubmission(submissionID: UUID, code: String, at date: Date) async throws
    /// SQLiteServiceStore.swift
    func authorityStore_replaceEmbeddedWorktrees(
        _ snapshots: [WorktreeBindingSnapshot],
        session: SessionSnapshot,
        actor: ExternalActor,
        correlationID: UUID
    ) async throws -> [EventEnvelope]
    /// DirectProviderStore.swift
    func authorityStore_replaceProviderModelCatalog(
        providerID: ProviderSettingsID,
        models: [ProviderModelCatalogEntry],
        expectedRevision: Int64
    ) async throws -> ProviderModelCatalogSnapshot
    /// WorkflowRepositoryStore.swift
    func authorityStore_replaceWorkflowCleanupGuidance(
        _ includeSessionCleanupGuidance: Bool,
        audit: ServerSettingsAuditMutation
    ) async throws -> ServerWorkflowRepositorySnapshot
    /// WorkflowRepositoryStore.swift
    func authorityStore_replaceWorkflowRepositorySnapshot(
        _ snapshot: ServerWorkflowRepositorySnapshot,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> ServerWorkflowRepositorySnapshot
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_runPresentation(sessionID: UUID) async throws -> RunPresentationSnapshot?
    /// SQLiteServiceStore.swift
    func authorityStore_selection(sessionID: UUID) async throws -> SelectionSnapshot?
    /// SQLiteServiceStore.swift
    func authorityStore_selectionTemplate(projectID: UUID) async throws -> ProjectSelectionTemplateSnapshot?
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_semanticActivities(turnID: UUID) async throws -> [SemanticActivityRecord]
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_semanticActivity(activityID: UUID) async throws -> SemanticActivityRecord?
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_semanticTools(turnID: UUID) async throws -> [SemanticToolRecord]
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_semanticTurn(runID: UUID) async throws -> SemanticTurnRecord?
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_semanticTurns(sessionID: UUID, beforeSequence: Int64?, limit: Int) async throws -> [SemanticTurnRecord]
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_semanticWatermark(sessionID: UUID) async throws -> SemanticIngestionWatermark?
    /// SQLiteServiceStore.swift
    func authorityStore_sessionContext(sessionID: UUID) async throws -> SessionContextSnapshot?
    /// SQLiteServiceStore.swift
    func authorityStore_sessionWithInteractions(id: UUID) async throws -> SessionSnapshot?
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_settleSemanticTurn(runID: UUID, terminalState: String, at date: Date) async throws
    /// ServerSettingsRepositories.swift
    func authorityStore_subagentPermissionDocument() async throws -> StoredSettingsDocument<SubagentPermissionSettings>?
    /// ServerSettingsRepositories.swift
    func authorityStore_upsertAdvancedServerSettingsDocument(
        _ document: StoredSettingsDocument<AdvancedServerSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<AdvancedServerSettings>
    /// ServerSettingsRepositories.swift
    func authorityStore_upsertAgentModelsDocument(
        _ document: StoredSettingsDocument<AgentModelsScopeDocument>,
        scopeID: String,
        projectID: UUID?,
        expectedRevision: Int64,
        expectedGlobalRevision: Int64?,
        expectedSourceScopeID: String?,
        expectedSourceRevision: Int64?,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<AgentModelsScopeDocument>
    /// ComposerAttachmentRepository.swift
    func authorityStore_upsertComposerAttachment(_ record: StoredComposerAttachment) async throws
    /// ServerSettingsRepositories.swift
    func authorityStore_upsertContextBuilderDocument(
        _ document: StoredSettingsDocument<ContextBuilderScopeDocument>,
        scopeID: String,
        projectID: UUID?,
        expectedRevision: Int64,
        expectedGlobalRevision: Int64?,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<ContextBuilderScopeDocument>
    /// SQLiteServiceStore.swift
    func authorityStore_upsertContextUsage(_ usage: ContextUsageWireSnapshot, sessionID: UUID) async throws
    /// ServerSettingsRepositories.swift
    func authorityStore_upsertDirectAgentPermissionDocument(
        _ document: StoredSettingsDocument<DirectAgentPermissionsSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<DirectAgentPermissionsSettings>
    /// ServerSettingsRepositories.swift
    func authorityStore_upsertMCPDisabledToolsDocument(
        _ document: StoredSettingsDocument<MCPDisabledToolsSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<MCPDisabledToolsSettings>
    /// ServerSettingsRepositories.swift
    func authorityStore_upsertMCPModelPresetsDocument(
        _ document: StoredSettingsDocument<[MCPModelPreset]>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<[MCPModelPreset]>
    /// ServerSettingsRepositories.swift
    func authorityStore_upsertMCPShowModelPresetsDocument(
        _ document: StoredSettingsDocument<MCPShowModelPresetsSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<MCPShowModelPresetsSettings>
    /// ServerSettingsRepositories.swift
    func authorityStore_upsertProjectSelectionPresetsDocument(
        _ document: StoredSettingsDocument<[ProjectSelectionPreset]>,
        projectID: UUID,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<[ProjectSelectionPreset]>
    /// SQLiteServiceStore.swift
    func authorityStore_upsertProviderConnection(
        _ value: StoredProviderConnection,
        expectedRevision: Int64,
        audit: ProviderConnectionAuditMutation?
    ) async throws -> StoredProviderConnection
    /// SQLiteServiceStore.swift
    func authorityStore_upsertProviderSettings(
        _ value: ProviderSettingsPreference,
        expectedRevision: Int64,
        audit: ProviderConnectionAuditMutation?
    ) async throws -> ProviderSettingsPreference
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_upsertRunPresentation(_ snapshot: RunPresentationSnapshot) async throws
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_upsertSemanticActivity(_ record: SemanticActivityRecord) async throws
    /// AgentSemanticLedgerRepository.swift
    func authorityStore_upsertSemanticTool(_ record: SemanticToolRecord) async throws
    /// ServerSettingsRepositories.swift
    func authorityStore_upsertSubagentPermissionDocument(
        _ document: StoredSettingsDocument<SubagentPermissionSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<SubagentPermissionSettings>
    /// ServerSettingsRepositories.swift
    func authorityStore_upsertWorkspaceApprovalDocument(
        _ document: StoredSettingsDocument<WorkspaceApprovalSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<WorkspaceApprovalSettings>
    /// WorkflowRepositoryStore.swift
    func authorityStore_workflowRepositorySnapshot() async throws -> ServerWorkflowRepositorySnapshot
    /// ServerSettingsRepositories.swift
    func authorityStore_workspaceApprovalDocument() async throws -> StoredSettingsDocument<WorkspaceApprovalSettings>?
    /// SQLiteServiceStore.swift
    func authorityStore_worktree(bindingID: UUID) async throws -> WorktreeBindingSnapshot?
    /// SQLiteServiceStore.swift
    func authorityStore_worktrees(projectID: UUID) async throws -> [WorktreeBindingSnapshot]
}

public extension RepoPromptAuthorityStore {
    func advanceSemanticWatermark(sessionID: UUID, semanticSequence: Int64, legacySequence: Int64, gapDetected: Bool, at date: Date) async throws {
        try await authorityStore_advanceSemanticWatermark(sessionID: sessionID, semanticSequence: semanticSequence, legacySequence: legacySequence, gapDetected: gapDetected, at: date)
    }

    func advancedServerSettingsDocument() async throws -> StoredSettingsDocument<AdvancedServerSettings>? {
        try await authorityStore_advancedServerSettingsDocument()
    }

    func agentModelsDocument(scopeID: String) async throws -> StoredSettingsDocument<AgentModelsScopeDocument>? {
        try await authorityStore_agentModelsDocument(scopeID: scopeID)
    }

    func agentSubmission(actorID: String, targetKey: String, operation: String, publicKey: String) async throws -> AgentSubmissionRecord? {
        try await authorityStore_agentSubmission(actorID: actorID, targetKey: targetKey, operation: operation, publicKey: publicKey)
    }

    func agentSubmission(submissionID: UUID) async throws -> AgentSubmissionRecord? {
        try await authorityStore_agentSubmission(submissionID: submissionID)
    }

    func agentSubmissions(state: AgentSubmissionState? = nil, dispatchState: String? = nil, limit: Int = 500) async throws -> [AgentSubmissionRecord] {
        try await authorityStore_agentSubmissions(state: state, dispatchState: dispatchState, limit: limit)
    }

    func agents(rootSessionID: UUID? = nil) async throws -> [AgentSnapshot] {
        try await authorityStore_agents(rootSessionID: rootSessionID)
    }

    func allProjects() async throws -> [ProjectSnapshot] {
        try await authorityStore_allProjects()
    }

    func allSessions() async throws -> [SessionSnapshot] {
        try await authorityStore_allSessions()
    }

    func allSessionsWithInteractions() async throws -> [SessionSnapshot] {
        try await authorityStore_allSessionsWithInteractions()
    }

    func appendProviderConnectionAudit(providerID: ProviderSettingsID, connectionID: UUID?, operation: String, attribution: ProviderMutationAttribution, authenticationMethod: ProviderAuthenticationMethod?, result: String) async throws {
        try await authorityStore_appendProviderConnectionAudit(providerID: providerID, connectionID: connectionID, operation: operation, attribution: attribution, authenticationMethod: authenticationMethod, result: result)
    }

    func artifact(id: UUID) async throws -> (snapshot: ArtifactSnapshot, storageReference: String)? {
        try await authorityStore_artifact(id: id)
    }

    func artifacts(sessionID: UUID) async throws -> [(snapshot: ArtifactSnapshot, storageReference: String)] {
        try await authorityStore_artifacts(sessionID: sessionID)
    }

    func bootstrapWorkflowRepository(builtins: [WorkflowSnapshot], now: Date = Date()) async throws {
        try await authorityStore_bootstrapWorkflowRepository(builtins: builtins, now: now)
    }

    func checkpoint() async throws {
        try await authorityStore_checkpoint()
    }

    func collaboration(sessionID: UUID) async throws -> CollaborationMetadataSnapshot? {
        try await authorityStore_collaboration(sessionID: sessionID)
    }

    func commitAgentSubmission(
        record: AgentSubmissionRecord,
        turn: SemanticTurnRecord,
        nextDefaults: SessionNextTurnDefaultsRecord,
        runPresentation: RunPresentationSnapshot,
        receipt: SubmissionReceipt,
        newSession: PreparedNewAgentSession? = nil
    ) async throws -> NewAgentSessionAcceptanceEvents? {
        try await authorityStore_commitAgentSubmission(record: record, turn: turn, nextDefaults: nextDefaults, runPresentation: runPresentation, receipt: receipt, newSession: newSession)
    }

    func composerAttachment(attachmentID: UUID) async throws -> StoredComposerAttachment? {
        try await authorityStore_composerAttachment(attachmentID: attachmentID)
    }

    func composerAttachments(actorID: String? = nil, projectID: UUID? = nil, lifecycle: ComposerAttachmentLifecycle? = nil) async throws -> [StoredComposerAttachment] {
        try await authorityStore_composerAttachments(actorID: actorID, projectID: projectID, lifecycle: lifecycle)
    }

    func composerProviderCatalog(providerID: ProviderSettingsID) async throws -> StoredComposerProviderCatalog? {
        try await authorityStore_composerProviderCatalog(providerID: providerID)
    }

    func contextBuilderDocument(scopeID: String) async throws -> StoredSettingsDocument<ContextBuilderScopeDocument>? {
        try await authorityStore_contextBuilderDocument(scopeID: scopeID)
    }

    func deleteComposerAttachment(attachmentID: UUID) async throws {
        try await authorityStore_deleteComposerAttachment(attachmentID: attachmentID)
    }

    func deleteProviderConnection(
        providerID: ProviderSettingsID,
        expectedRevision: Int64,
        audit: ProviderConnectionAuditMutation? = nil
    ) async throws {
        try await authorityStore_deleteProviderConnection(providerID: providerID, expectedRevision: expectedRevision, audit: audit)
    }

    func directAgentPermissionDocument() async throws -> StoredSettingsDocument<DirectAgentPermissionsSettings>? {
        try await authorityStore_directAgentPermissionDocument()
    }

    func events(after cursor: ServiceCursor?, limit: Int) async throws -> EventPage {
        try await authorityStore_events(after: cursor, limit: limit)
    }

    func idempotencyResult(_ input: IdempotencyInput) async throws -> (response: Data, status: Int)? {
        try await authorityStore_idempotencyResult(input)
    }

    func installInitialPolicies(permissions: ExecutionPermissionSnapshot, collaboration: CollaborationMetadataSnapshot) async throws {
        try await authorityStore_installInitialPolicies(permissions: permissions, collaboration: collaboration)
    }

    func installWorkflows(_ workflows: [WorkflowSnapshot]) async throws {
        try await authorityStore_installWorkflows(workflows)
    }

    func interactions(sessionID: UUID) async throws -> [InteractionSnapshot] {
        try await authorityStore_interactions(sessionID: sessionID)
    }

    func latestRun(sessionID: UUID) async throws -> ProviderRunSnapshot? {
        try await authorityStore_latestRun(sessionID: sessionID)
    }

    func latestSemanticSequence(sessionID: UUID) async throws -> Int64 {
        try await authorityStore_latestSemanticSequence(sessionID: sessionID)
    }

    func markSubmissionDispatch(submissionID: UUID, state: String, at date: Date) async throws {
        try await authorityStore_markSubmissionDispatch(submissionID: submissionID, state: state, at: date)
    }

    func mcpDisabledToolsDocument() async throws -> StoredSettingsDocument<MCPDisabledToolsSettings>? {
        try await authorityStore_mcpDisabledToolsDocument()
    }

    func mcpModelPresetsDocument() async throws -> StoredSettingsDocument<[MCPModelPreset]>? {
        try await authorityStore_mcpModelPresetsDocument()
    }

    func mcpShowModelPresetsDocument() async throws -> StoredSettingsDocument<MCPShowModelPresetsSettings>? {
        try await authorityStore_mcpShowModelPresetsDocument()
    }

    func metadata() async throws -> AuthorityStoreMetadata {
        try await authorityStore_metadata()
    }

    func nextCursor() async throws -> ServiceCursor {
        try await authorityStore_nextCursor()
    }

    func nextTurnDefaults(sessionID: UUID) async throws -> SessionNextTurnDefaultsRecord? {
        try await authorityStore_nextTurnDefaults(sessionID: sessionID)
    }

    func oracleChat(chatID: UUID) async throws -> OracleChatState? {
        try await authorityStore_oracleChat(chatID: chatID)
    }

    func permissions(sessionID: UUID) async throws -> ExecutionPermissionSnapshot? {
        try await authorityStore_permissions(sessionID: sessionID)
    }

    func persistAgent(_ snapshot: AgentSnapshot, projectID: UUID, actor: ExternalActor?, correlationID: UUID, eventType: EventType) async throws -> EventEnvelope {
        try await authorityStore_persistAgent(snapshot, projectID: projectID, actor: actor, correlationID: correlationID, eventType: eventType)
    }

    func persistArtifact(_ snapshot: ArtifactSnapshot, storageReference: String, actor: ExternalActor?, correlationID: UUID) async throws -> EventEnvelope {
        try await authorityStore_persistArtifact(snapshot, storageReference: storageReference, actor: actor, correlationID: correlationID)
    }

    func persistCollaboration(_ metadata: CollaborationMetadataSnapshot, session: SessionSnapshot, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput, idempotencyResponse: Data? = nil) async throws -> [EventEnvelope] {
        try await authorityStore_persistCollaboration(metadata, session: session, actor: actor, correlationID: correlationID, idempotency: idempotency, idempotencyResponse: idempotencyResponse)
    }

    func persistComposerProviderCatalog(_ record: StoredComposerProviderCatalog) async throws {
        try await authorityStore_persistComposerProviderCatalog(record)
    }

    func persistInteraction(_ snapshot: InteractionSnapshot, session: SessionSnapshot, actor: ExternalActor?, correlationID: UUID, idempotency: IdempotencyInput? = nil) async throws -> EventEnvelope {
        try await authorityStore_persistInteraction(snapshot, session: session, actor: actor, correlationID: correlationID, idempotency: idempotency)
    }

    func persistInteractionDeliveryState(_ snapshot: InteractionSnapshot, sessionID: UUID, actor: ExternalActor?) async throws {
        try await authorityStore_persistInteractionDeliveryState(snapshot, sessionID: sessionID, actor: actor)
    }

    func persistNewSession(
        _ snapshot: SessionSnapshot,
        agent: AgentSnapshot,
        actor: ExternalActor,
        correlationID: UUID,
        agentCorrelationID: UUID,
        idempotency: IdempotencyInput,
        initialSelection: SelectionSnapshot,
        initialPermissions: ExecutionPermissionSnapshot,
        initialCollaboration: CollaborationMetadataSnapshot,
        initialWorktrees: [WorktreeBindingSnapshot] = []
    ) async throws -> (session: EventEnvelope, agent: EventEnvelope, worktrees: [EventEnvelope]) {
        try await authorityStore_persistNewSession(snapshot, agent: agent, actor: actor, correlationID: correlationID, agentCorrelationID: agentCorrelationID, idempotency: idempotency, initialSelection: initialSelection, initialPermissions: initialPermissions, initialCollaboration: initialCollaboration, initialWorktrees: initialWorktrees)
    }

    func persistOracleChat(_ chat: OracleChatState) async throws {
        try await authorityStore_persistOracleChat(chat)
    }

    func persistPermissions(_ snapshot: ExecutionPermissionSnapshot, projectID: UUID, rootSessionID: UUID, correlationID: UUID, idempotency: IdempotencyInput? = nil) async throws -> EventEnvelope {
        try await authorityStore_persistPermissions(snapshot, projectID: projectID, rootSessionID: rootSessionID, correlationID: correlationID, idempotency: idempotency)
    }

    func persistProject(
        _ snapshot: ProjectSnapshot,
        rootIdentities: [UUID: String] = [:],
        eventType: EventType,
        actor: ExternalActor,
        correlationID: UUID,
        idempotency: IdempotencyInput?,
        expectedRevision: Int64? = nil,
        idempotencyResponse: Data? = nil,
        idempotencyStatus: Int? = nil
    ) async throws -> EventEnvelope {
        try await authorityStore_persistProject(snapshot, rootIdentities: rootIdentities, eventType: eventType, actor: actor, correlationID: correlationID, idempotency: idempotency, expectedRevision: expectedRevision, idempotencyResponse: idempotencyResponse, idempotencyStatus: idempotencyStatus)
    }

    func persistRun(_ snapshot: ProviderRunSnapshot) async throws {
        try await authorityStore_persistRun(snapshot)
    }

    func persistSelection(_ snapshot: SelectionSnapshot, projectID: UUID, rootSessionID: UUID, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput? = nil) async throws -> EventEnvelope {
        try await authorityStore_persistSelection(snapshot, projectID: projectID, rootSessionID: rootSessionID, actor: actor, correlationID: correlationID, idempotency: idempotency)
    }

    func persistSelectionTemplate(_ snapshot: ProjectSelectionTemplateSnapshot, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput) async throws -> EventEnvelope {
        try await authorityStore_persistSelectionTemplate(snapshot, actor: actor, correlationID: correlationID, idempotency: idempotency)
    }

    func persistServiceDiagnostic(
        projectID: UUID,
        actor: ExternalActor?,
        correlationID: UUID,
        payload: Data
    ) async throws -> EventEnvelope {
        try await authorityStore_persistServiceDiagnostic(projectID: projectID, actor: actor, correlationID: correlationID, payload: payload)
    }

    func persistSession(
        _ snapshot: SessionSnapshot,
        eventType: EventType,
        actor: ExternalActor?,
        correlationID: UUID,
        idempotency: IdempotencyInput?,
        idempotencyResponse: Data? = nil,
        initialSelection: SelectionSnapshot? = nil
    ) async throws -> EventEnvelope {
        try await authorityStore_persistSession(snapshot, eventType: eventType, actor: actor, correlationID: correlationID, idempotency: idempotency, idempotencyResponse: idempotencyResponse, initialSelection: initialSelection)
    }

    func persistSessionContext(
        _ snapshot: SessionContextSnapshot,
        session: SessionSnapshot,
        actor: ExternalActor,
        correlationID: UUID
    ) async throws -> EventEnvelope {
        try await authorityStore_persistSessionContext(snapshot, session: session, actor: actor, correlationID: correlationID)
    }

    func persistToolInvocation(
        _ snapshot: ToolInvocationSnapshot,
        session: SessionSnapshot,
        actor: ExternalActor?,
        correlationID: UUID,
        eventType: EventType
    ) async throws -> EventEnvelope {
        try await authorityStore_persistToolInvocation(snapshot, session: session, actor: actor, correlationID: correlationID, eventType: eventType)
    }

    func persistWorktree(_ snapshot: WorktreeBindingSnapshot, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput? = nil) async throws -> EventEnvelope {
        try await authorityStore_persistWorktree(snapshot, actor: actor, correlationID: correlationID, idempotency: idempotency)
    }

    func persistWorktreeBinding(_ worktree: WorktreeBindingSnapshot, selection: SelectionSnapshot, session: SessionSnapshot, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput) async throws -> (worktree: EventEnvelope, selection: EventEnvelope) {
        try await authorityStore_persistWorktreeBinding(worktree, selection: selection, session: session, actor: actor, correlationID: correlationID, idempotency: idempotency)
    }

    func persistWorktrees(
        _ snapshots: [WorktreeBindingSnapshot],
        actor: ExternalActor,
        correlationID: UUID
    ) async throws -> [EventEnvelope] {
        try await authorityStore_persistWorktrees(snapshots, actor: actor, correlationID: correlationID)
    }

    func prepareAgentSubmission(_ record: AgentSubmissionRecord) async throws -> AgentSubmissionRecord {
        try await authorityStore_prepareAgentSubmission(record)
    }

    func projectRootIdentities(projectID: UUID) async throws -> [UUID: String] {
        try await authorityStore_projectRootIdentities(projectID: projectID)
    }

    func projectSelectionPresetsDocument(projectID: UUID) async throws -> StoredSettingsDocument<[ProjectSelectionPreset]>? {
        try await authorityStore_projectSelectionPresetsDocument(projectID: projectID)
    }

    func providerConnections() async throws -> [StoredProviderConnection] {
        try await authorityStore_providerConnections()
    }

    func providerModelCatalog(providerID: ProviderSettingsID) async throws -> ProviderModelCatalogSnapshot? {
        try await authorityStore_providerModelCatalog(providerID: providerID)
    }

    func providerModelCatalogs() async throws -> [ProviderModelCatalogSnapshot] {
        try await authorityStore_providerModelCatalogs()
    }

    func providerSettings() async throws -> [ProviderSettingsPreference] {
        try await authorityStore_providerSettings()
    }

    func rejectAgentSubmission(submissionID: UUID, code: String, at date: Date) async throws {
        try await authorityStore_rejectAgentSubmission(submissionID: submissionID, code: code, at: date)
    }

    func replaceEmbeddedWorktrees(
        _ snapshots: [WorktreeBindingSnapshot],
        session: SessionSnapshot,
        actor: ExternalActor,
        correlationID: UUID
    ) async throws -> [EventEnvelope] {
        try await authorityStore_replaceEmbeddedWorktrees(snapshots, session: session, actor: actor, correlationID: correlationID)
    }

    func replaceProviderModelCatalog(
        providerID: ProviderSettingsID,
        models: [ProviderModelCatalogEntry],
        expectedRevision: Int64
    ) async throws -> ProviderModelCatalogSnapshot {
        try await authorityStore_replaceProviderModelCatalog(providerID: providerID, models: models, expectedRevision: expectedRevision)
    }

    func replaceWorkflowCleanupGuidance(
        _ includeSessionCleanupGuidance: Bool,
        audit: ServerSettingsAuditMutation
    ) async throws -> ServerWorkflowRepositorySnapshot {
        try await authorityStore_replaceWorkflowCleanupGuidance(includeSessionCleanupGuidance, audit: audit)
    }

    func replaceWorkflowRepositorySnapshot(
        _ snapshot: ServerWorkflowRepositorySnapshot,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> ServerWorkflowRepositorySnapshot {
        try await authorityStore_replaceWorkflowRepositorySnapshot(snapshot, expectedRevision: expectedRevision, audit: audit)
    }

    func runPresentation(sessionID: UUID) async throws -> RunPresentationSnapshot? {
        try await authorityStore_runPresentation(sessionID: sessionID)
    }

    func selection(sessionID: UUID) async throws -> SelectionSnapshot? {
        try await authorityStore_selection(sessionID: sessionID)
    }

    func selectionTemplate(projectID: UUID) async throws -> ProjectSelectionTemplateSnapshot? {
        try await authorityStore_selectionTemplate(projectID: projectID)
    }

    func semanticActivities(turnID: UUID) async throws -> [SemanticActivityRecord] {
        try await authorityStore_semanticActivities(turnID: turnID)
    }

    func semanticActivity(activityID: UUID) async throws -> SemanticActivityRecord? {
        try await authorityStore_semanticActivity(activityID: activityID)
    }

    func semanticTools(turnID: UUID) async throws -> [SemanticToolRecord] {
        try await authorityStore_semanticTools(turnID: turnID)
    }

    func semanticTurn(runID: UUID) async throws -> SemanticTurnRecord? {
        try await authorityStore_semanticTurn(runID: runID)
    }

    func semanticTurns(sessionID: UUID, beforeSequence: Int64? = nil, limit: Int = 50) async throws -> [SemanticTurnRecord] {
        try await authorityStore_semanticTurns(sessionID: sessionID, beforeSequence: beforeSequence, limit: limit)
    }

    func semanticWatermark(sessionID: UUID) async throws -> SemanticIngestionWatermark? {
        try await authorityStore_semanticWatermark(sessionID: sessionID)
    }

    func sessionContext(sessionID: UUID) async throws -> SessionContextSnapshot? {
        try await authorityStore_sessionContext(sessionID: sessionID)
    }

    func sessionWithInteractions(id: UUID) async throws -> SessionSnapshot? {
        try await authorityStore_sessionWithInteractions(id: id)
    }

    func settleSemanticTurn(runID: UUID, terminalState: String, at date: Date) async throws {
        try await authorityStore_settleSemanticTurn(runID: runID, terminalState: terminalState, at: date)
    }

    func subagentPermissionDocument() async throws -> StoredSettingsDocument<SubagentPermissionSettings>? {
        try await authorityStore_subagentPermissionDocument()
    }

    func upsertAdvancedServerSettingsDocument(
        _ document: StoredSettingsDocument<AdvancedServerSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<AdvancedServerSettings> {
        try await authorityStore_upsertAdvancedServerSettingsDocument(document, expectedRevision: expectedRevision, audit: audit)
    }

    func upsertAgentModelsDocument(
        _ document: StoredSettingsDocument<AgentModelsScopeDocument>,
        scopeID: String,
        projectID: UUID?,
        expectedRevision: Int64,
        expectedGlobalRevision: Int64? = nil,
        expectedSourceScopeID: String? = nil,
        expectedSourceRevision: Int64? = nil,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<AgentModelsScopeDocument> {
        try await authorityStore_upsertAgentModelsDocument(document, scopeID: scopeID, projectID: projectID, expectedRevision: expectedRevision, expectedGlobalRevision: expectedGlobalRevision, expectedSourceScopeID: expectedSourceScopeID, expectedSourceRevision: expectedSourceRevision, audit: audit)
    }

    func upsertComposerAttachment(_ record: StoredComposerAttachment) async throws {
        try await authorityStore_upsertComposerAttachment(record)
    }

    func upsertContextBuilderDocument(
        _ document: StoredSettingsDocument<ContextBuilderScopeDocument>,
        scopeID: String,
        projectID: UUID?,
        expectedRevision: Int64,
        expectedGlobalRevision: Int64? = nil,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<ContextBuilderScopeDocument> {
        try await authorityStore_upsertContextBuilderDocument(document, scopeID: scopeID, projectID: projectID, expectedRevision: expectedRevision, expectedGlobalRevision: expectedGlobalRevision, audit: audit)
    }

    func upsertContextUsage(_ usage: ContextUsageWireSnapshot, sessionID: UUID) async throws {
        try await authorityStore_upsertContextUsage(usage, sessionID: sessionID)
    }

    func upsertDirectAgentPermissionDocument(
        _ document: StoredSettingsDocument<DirectAgentPermissionsSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<DirectAgentPermissionsSettings> {
        try await authorityStore_upsertDirectAgentPermissionDocument(document, expectedRevision: expectedRevision, audit: audit)
    }

    func upsertMCPDisabledToolsDocument(
        _ document: StoredSettingsDocument<MCPDisabledToolsSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<MCPDisabledToolsSettings> {
        try await authorityStore_upsertMCPDisabledToolsDocument(document, expectedRevision: expectedRevision, audit: audit)
    }

    func upsertMCPModelPresetsDocument(
        _ document: StoredSettingsDocument<[MCPModelPreset]>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<[MCPModelPreset]> {
        try await authorityStore_upsertMCPModelPresetsDocument(document, expectedRevision: expectedRevision, audit: audit)
    }

    func upsertMCPShowModelPresetsDocument(
        _ document: StoredSettingsDocument<MCPShowModelPresetsSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<MCPShowModelPresetsSettings> {
        try await authorityStore_upsertMCPShowModelPresetsDocument(document, expectedRevision: expectedRevision, audit: audit)
    }

    func upsertProjectSelectionPresetsDocument(
        _ document: StoredSettingsDocument<[ProjectSelectionPreset]>,
        projectID: UUID,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<[ProjectSelectionPreset]> {
        try await authorityStore_upsertProjectSelectionPresetsDocument(document, projectID: projectID, expectedRevision: expectedRevision, audit: audit)
    }

    func upsertProviderConnection(
        _ value: StoredProviderConnection,
        expectedRevision: Int64,
        audit: ProviderConnectionAuditMutation? = nil
    ) async throws -> StoredProviderConnection {
        try await authorityStore_upsertProviderConnection(value, expectedRevision: expectedRevision, audit: audit)
    }

    func upsertProviderSettings(
        _ value: ProviderSettingsPreference,
        expectedRevision: Int64,
        audit: ProviderConnectionAuditMutation? = nil
    ) async throws -> ProviderSettingsPreference {
        try await authorityStore_upsertProviderSettings(value, expectedRevision: expectedRevision, audit: audit)
    }

    func upsertRunPresentation(_ snapshot: RunPresentationSnapshot) async throws {
        try await authorityStore_upsertRunPresentation(snapshot)
    }

    func upsertSemanticActivity(_ record: SemanticActivityRecord) async throws {
        try await authorityStore_upsertSemanticActivity(record)
    }

    func upsertSemanticTool(_ record: SemanticToolRecord) async throws {
        try await authorityStore_upsertSemanticTool(record)
    }

    func upsertSubagentPermissionDocument(
        _ document: StoredSettingsDocument<SubagentPermissionSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<SubagentPermissionSettings> {
        try await authorityStore_upsertSubagentPermissionDocument(document, expectedRevision: expectedRevision, audit: audit)
    }

    func upsertWorkspaceApprovalDocument(
        _ document: StoredSettingsDocument<WorkspaceApprovalSettings>,
        expectedRevision: Int64,
        audit: ServerSettingsAuditMutation
    ) async throws -> StoredSettingsDocument<WorkspaceApprovalSettings> {
        try await authorityStore_upsertWorkspaceApprovalDocument(document, expectedRevision: expectedRevision, audit: audit)
    }

    func workflowRepositorySnapshot() async throws -> ServerWorkflowRepositorySnapshot {
        try await authorityStore_workflowRepositorySnapshot()
    }

    func workspaceApprovalDocument() async throws -> StoredSettingsDocument<WorkspaceApprovalSettings>? {
        try await authorityStore_workspaceApprovalDocument()
    }

    func worktree(bindingID: UUID) async throws -> WorktreeBindingSnapshot? {
        try await authorityStore_worktree(bindingID: bindingID)
    }

    func worktrees(projectID: UUID) async throws -> [WorktreeBindingSnapshot] {
        try await authorityStore_worktrees(projectID: projectID)
    }
}
