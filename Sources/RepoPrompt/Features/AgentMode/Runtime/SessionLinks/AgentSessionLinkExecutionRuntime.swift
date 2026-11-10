import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptInstrumentation
import RepoPromptMCPServer
import RepoPromptSettingsCore

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
        let modelAvailability: @MainActor () -> AgentModelCatalog.AvailabilityContext?
        let workspaceID: @MainActor (AgentTabSession) -> UUID?
        let input: AgentSessionProviderInputRuntime
        let workspacePaths: @MainActor () -> [String]
        let inputWorkspace: @MainActor (AgentTabSession) -> AgentSessionProviderInputRuntime.WorkspaceSource?
        let initialThreadInput: @MainActor (AgentTabSession) -> AgentSessionProviderInputRuntime.InitialThreadInput?
        let modelDisplayName: @MainActor (AgentTabSession) -> String
        let start: @MainActor (AgentTabSession, String, AgentDirectRunStartOptions, AgentRunStartOutcomeRecorder?, AgentProviderSwitchSendPreparation?) async -> CodexAgentModeCoordinator.NativeSendOutcome?
        let settleSelfCompact: @MainActor (AgentTabSession) -> Void
        let selfCompactBlocksWake: @MainActor (AgentTabSession) -> Bool
        let selfCompactHoldsWakeAcquisition: @MainActor (AgentTabSession) -> Bool
    }

    private(set) weak var scope: AgentSessionRuntimeStore.Scope?
    struct PendingSendEffect {
        let sessionIdentity: ObjectIdentifier
        let task: Task<Void, Never>
    }

    var pendingSendEffects: [UUID: PendingSendEffect] = [:]
    var pendingStopEffects: [UUID: PendingSendEffect] = [:]
    let routeID: Int
    let commands: Commands
    let catalogDiagnosticsSink: any AgentSessionLinkCatalogEventSink
    var perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()
    weak var codexCoordinator: CodexAgentModeCoordinator?
    /// Display labels are optional and never participate in authority or receipt qualification.
    var displayProps: (@MainActor (DomainAgentSessionLinkEndpointIdentity) -> AgentMonitorPillProps?)?

    init(scope: AgentSessionRuntimeStore.Scope, routeID: Int, commands: Commands, diagnostics: any AgentSessionLinkCatalogEventSink) {
        self.scope = scope
        self.routeID = routeID
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
        var test_endpointRead: (() -> Void)?
        var test_selfCompactAfterSupport: (() async -> Void)?
        var test_beforeRoutineIdleFollowUpStart: ((AgentTabSession, UUID) -> Bool)?
        var test_agentSessionLinkAfterProviderInputRouteReadiness: (() async -> Void)?
        var test_agentSessionLinkHasActiveOutboundLink: ((DomainAgentSessionLinkEndpointIdentity) async -> Bool)?
        var test_agentSessionLinkAuthoritativeRunCatalogRouteToken: ((UUID, Int, UUID) async -> AgentSessionLinkRunCatalogRouteToken?)?
        var test_agentSessionLinkAwaitAuthoritativeRunCatalogRouteToken: ((UUID, Int, UUID, TimeInterval) async -> AgentSessionLinkRunCatalogRouteToken?)?
        var test_agentSessionLinkCurrentRunCatalogRouteToken: ((AgentSessionLinkRunCatalogRouteToken, UUID) -> Bool)?
        var test_agentSessionLinkLocalInputDecoration: ((AgentSessionLinkPromptRenderResult) -> AgentSessionLinkLocalInputDecoration?)?
        var test_agentSessionLinkLocalInputReadProof: ((AgentSessionLinkLocalInputDecoration) async -> Bool)?
        var test_agentSessionLinkManagedMetadataProof: ((DomainAgentSessionLinkEndpointIdentity, [DomainAgentSessionManagedObservationRequirement]) async -> [DomainAgentSessionLinkCommitAuthorization]?)?
    #endif

    func agentSessionLinkObserverEndpoint(tabID: UUID) -> DomainAgentSessionLinkEndpointIdentity? {
        #if DEBUG
            test_endpointRead?()
        #endif
        guard let scope, !scope.hasReleasedWriterClaims,
              let session = scope.sessions[tabID], let sessionID = session.activeAgentSessionID,
              case let .unique(writer) = scope.resolveWriter(sessionID: sessionID),
              writer.scope === scope, writer.session === session else { return nil }
        return DomainAgentSessionLinkEndpointIdentity(
            windowID: routeID, workspaceID: writer.identity.workspaceID,
            tabID: tabID, sessionID: sessionID,
            persistentBindingGeneration: writer.binding.generation,
            bindingTransitionGeneration: session.bindingTransitionGeneration
        )
    }

    func admit(_ candidate: AgentSessionLinkEndpointCandidate) -> AgentSessionRuntimeStore.Command? {
        admit(endpoint: candidate.domainEndpoint)
    }

    func admit(endpoint: DomainAgentSessionLinkEndpointIdentity) -> AgentSessionRuntimeStore.Command? {
        guard let scope,
              case let .unique(writer) = scope.resolveWriter(
                  sessionID: endpoint.sessionID, expectedWorkspaceID: endpoint.workspaceID
              ), writer.scope === scope, writer.session.tabID == endpoint.tabID,
              agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint
        else { return nil }
        return try? writer.admitCommand().get()
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

    func makeComposerSubmitTarget(tabID: UUID?, session: AgentTabSession?) -> AgentComposerSubmitTarget? {
        guard let scope, let tabID, let session = session ?? scope.sessions[tabID],
              session.tabID == tabID, let id = session.activeAgentSessionID,
              case let .unique(writer) = scope.resolveWriter(sessionID: id),
              writer.scope === scope, writer.session === session,
              let command = try? writer.admitCommand().get() else { return nil }
        return scope.submissions.programmaticTarget(command)
    }

    func claimComposerSubmitAttempt(_ attempt: AgentComposerSubmitAttempt) -> AgentComposerSubmitClaim? {
        guard let scope, attempt.target.route == .existingAgentSession,
              case let .claimed(claim) = scope.submissions.claim(attempt) else { return nil }
        return claim
    }

    func composerSubmitClaimIsCurrent(_ claim: AgentComposerSubmitClaim) -> Bool {
        scope === claim.scope && claim.scope.submissions.isCurrent(claim)
    }

    @discardableResult
    func releaseComposerSubmitClaim(_ claim: AgentComposerSubmitClaim) -> Bool {
        guard scope === claim.scope else { return false }
        return claim.scope.submissions.release(claim)
    }
}
