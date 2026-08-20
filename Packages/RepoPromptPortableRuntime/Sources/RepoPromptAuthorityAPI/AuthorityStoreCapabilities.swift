import Foundation
import RepoPromptRuntimeModel

/// Narrow persistence capabilities consumed by individual portable services.
/// Hosts may compose these independently; `RepoPromptAuthorityStore` is the
/// compatibility aggregate for the established prototype authority.
public protocol ComposerAttachmentStore: Sendable {
    func composerAttachment(attachmentID: UUID) async throws -> StoredComposerAttachment?
    func composerAttachments(actorID: String?, projectID: UUID?, lifecycle: ComposerAttachmentLifecycle?) async throws -> [StoredComposerAttachment]
    func deleteComposerAttachment(attachmentID: UUID) async throws
    func upsertComposerAttachment(_ record: StoredComposerAttachment) async throws
}

public protocol ComposerCatalogStore: Sendable {
    func composerProviderCatalog(providerID: ProviderSettingsID) async throws -> StoredComposerProviderCatalog?
    func nextTurnDefaults(sessionID: UUID) async throws -> SessionNextTurnDefaultsRecord?
    func persistComposerProviderCatalog(_ record: StoredComposerProviderCatalog) async throws
    func providerModelCatalog(providerID: ProviderSettingsID) async throws -> ProviderModelCatalogSnapshot?
    func workflowRepositorySnapshot() async throws -> ServerWorkflowRepositorySnapshot
}

public protocol AgentSubmissionStore: Sendable {
    func agentSubmission(actorID: String, targetKey: String, operation: String, publicKey: String) async throws -> AgentSubmissionRecord?
    func agentSubmission(submissionID: UUID) async throws -> AgentSubmissionRecord?
    func agentSubmissions(state: AgentSubmissionState?, dispatchState: String?, limit: Int) async throws -> [AgentSubmissionRecord]
    func commitAgentSubmission(
        record: AgentSubmissionRecord,
        turn: SemanticTurnRecord,
        nextDefaults: SessionNextTurnDefaultsRecord,
        runPresentation: RunPresentationSnapshot,
        receipt: SubmissionReceipt,
        newSession: PreparedNewAgentSession?
    ) async throws -> NewAgentSessionAcceptanceEvents?
    func markSubmissionDispatch(submissionID: UUID, state: String, at date: Date) async throws
    func nextTurnDefaults(sessionID: UUID) async throws -> SessionNextTurnDefaultsRecord?
    func prepareAgentSubmission(_ record: AgentSubmissionRecord) async throws -> AgentSubmissionRecord
    func rejectAgentSubmission(submissionID: UUID, code: String, at date: Date) async throws
    func runPresentation(sessionID: UUID) async throws -> RunPresentationSnapshot?
    func semanticTurn(runID: UUID) async throws -> SemanticTurnRecord?
    func settleSemanticTurn(runID: UUID, terminalState: String, at date: Date) async throws
    func upsertRunPresentation(_ snapshot: RunPresentationSnapshot) async throws
    func upsertSemanticActivity(_ record: SemanticActivityRecord) async throws
    func workflowRepositorySnapshot() async throws -> ServerWorkflowRepositorySnapshot
}

public protocol AgentTranscriptStore: Sendable {
    func advanceSemanticWatermark(sessionID: UUID, semanticSequence: Int64, legacySequence: Int64, gapDetected: Bool, at date: Date) async throws
    func latestSemanticSequence(sessionID: UUID) async throws -> Int64
    func semanticActivities(turnID: UUID) async throws -> [SemanticActivityRecord]
    func semanticTools(turnID: UUID) async throws -> [SemanticToolRecord]
    func semanticTurns(sessionID: UUID, beforeSequence: Int64?, limit: Int) async throws -> [SemanticTurnRecord]
    func semanticWatermark(sessionID: UUID) async throws -> SemanticIngestionWatermark?
}

public protocol ProviderSettingsStore: Sendable {
    func appendProviderConnectionAudit(providerID: ProviderSettingsID, connectionID: UUID?, operation: String, attribution: ProviderMutationAttribution, authenticationMethod: ProviderAuthenticationMethod?, result: String) async throws
    func deleteProviderConnection(providerID: ProviderSettingsID, expectedRevision: Int64, audit: ProviderConnectionAuditMutation?) async throws
    func providerConnections() async throws -> [StoredProviderConnection]
    func providerModelCatalog(providerID: ProviderSettingsID) async throws -> ProviderModelCatalogSnapshot?
    func providerModelCatalogs() async throws -> [ProviderModelCatalogSnapshot]
    func providerSettings() async throws -> [ProviderSettingsPreference]
    func replaceProviderModelCatalog(providerID: ProviderSettingsID, models: [ProviderModelCatalogEntry], expectedRevision: Int64) async throws -> ProviderModelCatalogSnapshot
    func upsertProviderConnection(_ value: StoredProviderConnection, expectedRevision: Int64, audit: ProviderConnectionAuditMutation?) async throws -> StoredProviderConnection
    func upsertProviderSettings(_ value: ProviderSettingsPreference, expectedRevision: Int64, audit: ProviderConnectionAuditMutation?) async throws -> ProviderSettingsPreference
}

public protocol WorkflowRepositoryStore: Sendable {
    func bootstrapWorkflowRepository(builtins: [WorkflowSnapshot], now: Date) async throws
    func installWorkflows(_ workflows: [WorkflowSnapshot]) async throws
    func replaceWorkflowCleanupGuidance(_ includeSessionCleanupGuidance: Bool, audit: ServerSettingsAuditMutation) async throws -> ServerWorkflowRepositorySnapshot
    func replaceWorkflowRepositorySnapshot(_ snapshot: ServerWorkflowRepositorySnapshot, expectedRevision: Int64, audit: ServerSettingsAuditMutation) async throws -> ServerWorkflowRepositorySnapshot
    func workflowRepositorySnapshot() async throws -> ServerWorkflowRepositorySnapshot
}
