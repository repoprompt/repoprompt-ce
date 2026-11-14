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
        /// Nil command is reserved for the existing unbound local-draft recovery path.
        /// Canonical hosts require the supplied command and never elect a replacement writer.
        let inputWorkspace: @MainActor (AgentTabSession, AgentSessionRuntimeStore.Command?) async throws -> AgentSessionProviderInputRuntime.WorkspaceSource?
        let initialThreadInput: @MainActor (AgentTabSession, AgentSessionRuntimeStore.Command?) async throws -> AgentSessionProviderInputRuntime.InitialThreadInput?
        let modelDisplayName: @MainActor (AgentTabSession) -> String
        let start: @MainActor (AgentSessionRuntimeStore.Command, String, AgentDirectRunStartOptions, AgentRunStartOutcomeRecorder?, AgentProviderSwitchSendPreparation?) async -> CodexAgentModeCoordinator.NativeSendOutcome?
        let settleSelfCompact: @MainActor (AgentTabSession) -> Void
        let selfCompactBlocksWake: @MainActor (AgentTabSession) -> Bool
        let selfCompactHoldsWakeAcquisition: @MainActor (AgentTabSession) -> Bool
    }

    private(set) weak var scope: AgentSessionRuntimeStore.Scope?
    struct PendingSendEffect {
        let sessionIdentity: ObjectIdentifier
        let task: Task<Void, Never>
    }

    /// Effect inventory only: request supersession closes dispatch admission, not originating IO.
    struct SelfCompactEffect {
        let session: AgentTabSession
        let requestID: UUID
        let task: Task<Void, Never>
    }

    var pendingSelfCompactEffects: [UUID: SelfCompactEffect] = [:]
    var pendingSendEffects: [UUID: PendingSendEffect] = [:]
    /// Provider producers join separately from terminal-save effects to avoid a terminal cycle.
    var pendingManagedInputEffects: [UUID: PendingSendEffect] = [:]
    var pendingStopEffects: [UUID: PendingSendEffect] = [:]
    let routeID: Int
    let commands: Commands
    let catalogDiagnosticsSink: any AgentSessionLinkCatalogEventSink
    var perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()
    weak var codexCoordinator: CodexAgentModeCoordinator?
    /// Required host-owned drain probe. Absence blocks terminal dispatch.
    var activeMCPToolProbe: (@MainActor (UUID) -> Bool)?
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

    func agentSessionLinkClearWaitingOnAfterAcceptedTurn(_ session: AgentTabSession) {
        session.clearAgentSessionLinkWaitingOnAfterAcceptedTurn()
    }

    func startAgentRun(command: AgentSessionRuntimeStore.Command, initialMessage: String, directStartOptions: AgentDirectRunStartOptions, startOutcome: AgentRunStartOutcomeRecorder? = nil, providerSwitchPreparation: AgentProviderSwitchSendPreparation?) async -> CodexAgentModeCoordinator.NativeSendOutcome? {
        precondition(command.writer.scope === scope, "Startup must use its originating link executor")
        do { try command.requireCurrent() }
        catch {
            let message = AgentRunExecutionContracts.providerStartupFailureMessage(for: error)
            startOutcome?.recordStartFailure(message: message)
            return .failed(message: message)
        }
        return await commands.start(command, initialMessage, directStartOptions, startOutcome, providerSwitchPreparation)
    }

    func claimEmptyComposer(for candidate: AgentSessionLinkEndpointCandidate, session: TabSession) -> AgentComposerSubmitClaim? {
        guard let target = makeComposerSubmitTarget(tabID: candidate.tabID, session: session),
              target.route == .existingAgentSession,
              target.expectedSourceAgentSessionID == candidate.sessionID else { return nil }
        // Cross-session input never owns or clears the local composer's draft.
        return claimComposerSubmitAttempt(AgentComposerSubmitAttempt(
            id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: ""
        ))
    }

    func makeComposerSubmitTarget(tabID: UUID?, session: AgentTabSession?) -> AgentComposerSubmitTarget? {
        guard let scope, let tabID, let session = session ?? scope.sessions[tabID],
              session.tabID == tabID, let command = try? scope.admit(session: session) else { return nil }
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
