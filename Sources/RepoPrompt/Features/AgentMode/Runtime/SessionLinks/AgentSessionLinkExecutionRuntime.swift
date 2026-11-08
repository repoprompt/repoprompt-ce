import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptInstrumentation
import RepoPromptMCPServer

struct AgentSessionComposerSubmitClaim {
    let attempt: AgentComposerSubmitAttempt
    let sourceSession: AgentTabSession
    let draftMutationGeneration: UInt64
}

/// Scope-owned provider-input composition and wake scheduling. Membership authority, passive
/// delivery, claim accounting and wake reservations retain their existing, disjoint owners.
/// Commands are required composition inputs, not optional presentation callbacks. The legacy
/// adapter still supplies run-start/placement admission until the independent host cutover.
@MainActor
final class AgentSessionLinkExecutionRuntime {
    typealias TabSession = AgentTabSession
    typealias AgentComposerSubmitClaim = AgentSessionComposerSubmitClaim
    typealias ProviderSwitchSendPreparation = AgentProviderSwitchSendPreparation

    struct Commands {
        /// Command-owner lifetime, not link consent or endpoint currency. During the legacy
        /// adapter phase this preserves the old all-or-nothing late-hook behavior after VM loss.
        /// A nonvisual host supplies its own lifetime independently of presentation.
        let isAvailable: @MainActor () -> Bool
        let endpoint: @MainActor (UUID) -> DomainAgentSessionLinkEndpointIdentity?
        let workspaceID: @MainActor (AgentTabSession) -> UUID?
        let augment: @MainActor (AgentTabSession, String, [AgentFileAttachment], [AgentTaggedFileAttachment], Bool) async -> String
        let initialMessage: @MainActor (AgentTabSession, String) async -> String
        let modelDisplayName: @MainActor (AgentTabSession) -> String
        let start: @MainActor (AgentTabSession, String, AgentDirectRunStartOptions, AgentRunStartOutcomeRecorder?, AgentProviderSwitchSendPreparation?) async -> CodexAgentModeCoordinator.NativeSendOutcome?
        let resume: @MainActor (AgentTabSession, String, AgentSessionLinkOutboundPromptClaim?, UserInstructionResponse.Origin, AgentSessionLinkProviderInputRelease.Proof?, String?) -> Bool
        let settleSelfCompact: @MainActor (AgentTabSession) -> Void
        let selfCompactBlocksWake: @MainActor (AgentTabSession) -> Bool
        let composerTarget: @MainActor (UUID?, AgentTabSession?) -> AgentComposerSubmitTarget?
        let claimComposer: @MainActor (AgentComposerSubmitAttempt) -> AgentComposerSubmitClaim?
        let composerIsCurrent: @MainActor (AgentComposerSubmitClaim) -> Bool
        let releaseComposer: @MainActor (AgentComposerSubmitClaim) -> Bool
    }

    private(set) weak var scope: AgentSessionRuntimeStore.Scope?
    struct PendingSendEffect {
        let sessionIdentity: ObjectIdentifier
        let task: Task<Void, Never>
    }

    var pendingSendEffects: [UUID: PendingSendEffect] = [:]
    let commands: Commands
    let catalogDiagnosticsSink: any AgentSessionLinkCatalogEventSink
    var perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()
    weak var codexCoordinator: CodexAgentModeCoordinator?
    /// Display labels are optional and never participate in authority or receipt qualification.
    var displayProps: (@MainActor (DomainAgentSessionLinkEndpointIdentity) -> AgentMonitorPillProps?)?

    init(scope: AgentSessionRuntimeStore.Scope, commands: Commands, diagnostics: any AgentSessionLinkCatalogEventSink) {
        self.scope = scope
        self.commands = commands
        catalogDiagnosticsSink = diagnostics
    }

    var sessions: [UUID: AgentTabSession] {
        scope?.sessions ?? [:]
    }

    var agentSessionLinkPromptInventoryBySessionID: [UUID: AgentSessionLinkPublishedPromptInventory] = [:]
    var agentSessionLinkRunCatalogProjectionByEndpoint: [DomainAgentSessionLinkEndpointIdentity: AgentSessionLinkRunCatalogProjection] = [:]
    var agentSessionLinkPromptInventoryHoldsByEndpoint: [DomainAgentSessionLinkEndpointIdentity: AgentSessionLinkPromptInventoryHold] = [:]
    var agentSessionLinkNextPromptInventoryHoldToken: UInt64 = 0
    var agentSessionLinkPassiveNoticesBySessionID: [UUID: AgentSessionLinkPassiveStatusNotices.Snapshot] = [:]
    let agentSessionLinkPromptClaimStore = AgentSessionLinkOutboundPromptClaimStore()
    var agentSessionLinkPeriodicObserverIsLive: (DomainAgentSessionLinkEndpointIdentity) -> Bool = {
        AgentSessionLinkRuntimeBridge.shared.isPeriodicWakeObserverLive(for: $0)
    }

    #if DEBUG
        var test_beforeRoutineIdleFollowUpStart: ((AgentTabSession, UUID) -> Bool)?
        var test_agentSessionLinkHasActiveOutboundLink: ((DomainAgentSessionLinkEndpointIdentity) async -> Bool)?
        var test_agentSessionLinkAuthoritativeRunCatalogRouteToken: ((UUID, Int, UUID) async -> AgentSessionLinkRunCatalogRouteToken?)?
        var test_agentSessionLinkAwaitAuthoritativeRunCatalogRouteToken: ((UUID, Int, UUID, TimeInterval) async -> AgentSessionLinkRunCatalogRouteToken?)?
        var test_agentSessionLinkCurrentRunCatalogRouteToken: ((AgentSessionLinkRunCatalogRouteToken, UUID) -> Bool)?
        var test_agentSessionLinkLocalInputDecoration: ((AgentSessionLinkPromptRenderResult) -> AgentSessionLinkLocalInputDecoration?)?
        var test_agentSessionLinkLocalInputReadProof: ((AgentSessionLinkLocalInputDecoration) async -> Bool)?
        var test_agentSessionLinkManagedMetadataProof: ((DomainAgentSessionLinkEndpointIdentity, [DomainAgentSessionManagedObservationRequirement]) async -> [DomainAgentSessionLinkCommitAuthorization]?)?
    #endif

    func agentSessionLinkObserverEndpoint(tabID: UUID) -> DomainAgentSessionLinkEndpointIdentity? {
        guard let scope, !scope.hasReleasedWriterClaims, scope.sessions[tabID] != nil else { return nil }
        return commands.endpoint(tabID)
    }

    func hasCurrentRunCatalogRouteTokenInCurrentMCPServer(_ token: AgentSessionLinkRunCatalogRouteToken, tabID: UUID) -> Bool {
        scope?.mcp.hasCurrentRunCatalogRouteToken(token, tabID: tabID) == true
    }

    func requestUIRefresh(tabID: UUID, urgent: Bool = false) {
        guard let scope, let session = scope.sessions[tabID] else { return }
        scope.presentation.makeRunHooks().requestUIRefresh(session, urgent)
    }

    func scheduleSave(for session: AgentTabSession) {
        scope?.persistence.scheduleSave(for: session)
    }

    func scheduleSave(for tabID: UUID) {
        guard let session = sessions[tabID] else { return }
        scheduleSave(for: session)
    }

    func agentSelfCompactSettleStaleParkedNote(_ session: AgentTabSession) {
        commands.settleSelfCompact(session)
    }

    func agentSelfCompactBlocksNotificationWake(_ session: AgentTabSession) -> Bool {
        commands.selfCompactBlocksWake(session)
    }

    func agentSessionLinkClearWaitingOnAfterAcceptedTurn(_ session: AgentTabSession) {
        session.clearAgentSessionLinkWaitingOnAfterAcceptedTurn()
    }

    func startAgentRun(tabID: UUID, initialMessage: String, directStartOptions: AgentDirectRunStartOptions, startOutcome: AgentRunStartOutcomeRecorder? = nil, providerSwitchPreparation: AgentProviderSwitchSendPreparation?) async -> CodexAgentModeCoordinator.NativeSendOutcome? {
        guard let session = sessions[tabID] else { return nil }
        return await commands.start(session, initialMessage, directStartOptions, startOutcome, providerSwitchPreparation)
    }

    func resumeWaitingInstructionContinuation(session: AgentTabSession, providerText: String, claim: AgentSessionLinkOutboundPromptClaim?, origin: UserInstructionResponse.Origin, inputProof: AgentSessionLinkProviderInputRelease.Proof?, undecoratedProviderText: String?) -> Bool {
        commands.resume(session, providerText, claim, origin, inputProof, undecoratedProviderText)
    }

    func makeComposerSubmitTarget(tabID: UUID?, session: AgentTabSession?) -> AgentComposerSubmitTarget? {
        commands.composerTarget(tabID, session)
    }

    func composerSubmitClaimIsCurrent(_ claim: AgentComposerSubmitClaim) -> Bool {
        commands.composerIsCurrent(claim)
    }

    @discardableResult
    func releaseComposerSubmitClaim(_ claim: AgentComposerSubmitClaim) -> Bool {
        commands.releaseComposer(claim)
    }
}
