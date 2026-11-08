import Combine
import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptMCPServer

struct AgentRunEpochTransitionIntent: Equatable {
    let token: UUID
    let kind: AgentRunEpochTransitionKind
    let expectedCurrentEpoch: AgentRunTurnEpoch?
}

struct AgentMCPControlContext: Equatable {
    let sessionID: UUID
    let activationID: UUID
    let registration: AgentRunSessionStore.Registration
    var currentEpoch: AgentRunTurnEpoch?
    var preparedEpoch: AgentRunTurnEpoch?
    var pendingEpochTransition: AgentRunEpochTransitionIntent?
    let originatingConnectionID: UUID?
    let interactionTransport: AgentRunInteractionTransport
    let suppressUserNotifications: Bool
    let forceAutoEditEnabled: Bool
    let autoEditEnabledBeforeOverride: Bool
    /// The task label kind for this MCP-controlled run (e.g. explore, engineer).
    /// Used to customize tool advertisement and system prompts for role-specific behavior.
    let taskLabelKind: AgentModelCatalog.TaskLabelKind?

    func replacingRegistration(_ registration: AgentRunSessionStore.Registration) -> Self {
        Self(
            sessionID: sessionID,
            activationID: activationID,
            registration: registration,
            currentEpoch: currentEpoch,
            preparedEpoch: preparedEpoch,
            pendingEpochTransition: pendingEpochTransition,
            originatingConnectionID: originatingConnectionID,
            interactionTransport: interactionTransport,
            suppressUserNotifications: suppressUserNotifications,
            forceAutoEditEnabled: forceAutoEditEnabled,
            autoEditEnabledBeforeOverride: autoEditEnabledBeforeOverride,
            taskLabelKind: taskLabelKind
        )
    }
}

/// Runtime-owned remote projections and publication. DomainAgentRunSessionStore and the
/// terminal commit barrier remain the only lifecycle/terminal authorities. Presentation
/// attachment is not required to build snapshots, wake waiters or publish a committed turn.
@MainActor
final class AgentSessionMCPRuntime {
    /// The domain registration owns this capability before control is published. It retains
    /// the exact runtime scope, not its optional presenter, until domain cleanup/drain releases it.
    /// A cancellation delivered during setup prevents publication; one delivered afterwards
    /// joins the existing run service's teardown, never a replacement session's run.
    @MainActor
    final class ControlActivationCancellation {
        private let scope: AgentSessionRuntimeStore.Scope
        private let session: AgentTabSession
        private let binding: AgentSessionRestorationBindingToken?
        private let activationID: UUID
        private let activationGeneration: UInt64
        private let cancelInstalledRun: (AgentTabSession) async -> Void
        private(set) var cancellationRequested = false

        init(
            scope: AgentSessionRuntimeStore.Scope, session: AgentTabSession,
            activationID: UUID, cancelInstalledRun: @escaping (AgentTabSession) async -> Void
        ) {
            self.scope = scope
            self.session = session
            binding = session.currentRestorationBindingToken
            self.activationID = activationID
            activationGeneration = session.mcpControlActivationGeneration
            self.cancelInstalledRun = cancelInstalledRun
        }

        var permitsPublication: Bool {
            !cancellationRequested && !scope.isRetiring && isCurrent
        }

        private var isCurrent: Bool {
            ownsPersistentIncarnation
                && session.currentRestorationBindingToken == binding
                && !session.bindingTransitionInProgress
                && session.mcpControlActivationGeneration == activationGeneration
        }

        private var ownsPersistentIncarnation: Bool {
            !scope.hasReleasedWriterClaims
                && scope.sessions[session.tabID] === session
                && binding != nil && session.persistentSessionBindingIdentity == binding?.bindingIdentity
        }

        func cancel(registration: AgentRunSessionStore.Registration) async {
            cancellationRequested = true
            // An installed run still needs its drain while deactivation/binding preparation is
            // in progress. Do not require setup's transition generation, but never cross into a
            // replacement persistent binding, even when its UUIDs or context were copied.
            guard ownsPersistentIncarnation,
                  session.activeAgentSessionID == registration.sessionID,
                  let context = session.mcpControlContext,
                  context.activationID == activationID,
                  context.registration == registration
            else { return }
            AgentSessionInteractionRuntime.cancelPendingInstruction(for: session)
            await cancelInstalledRun(session)
        }
    }

    /// Prepare the existing domain epoch without a presentation owner. Recovery installs its
    /// exact cancellation capability atomically with registration, before publishing control.
    func prepareRunEpoch(
        session: AgentTabSession,
        stopFence: AgentRunStartStopFence,
        transitionToken: UUID?,
        store: DomainAgentRunSessionStore,
        cancelInstalledRun: @escaping @MainActor (AgentTabSession) async -> Void,
        afterEpochBegan: (@MainActor () async -> Void)? = nil
    ) async {
        guard let scope, !scope.isRetiring, !scope.hasReleasedWriterClaims, scope.sessions[session.tabID] === session else { return }
        defer { withExtendedLifetime(scope) {} }
        guard stopFence.permitsStart(of: session), !session.runState.isActive,
              let originalContext = session.mcpControlContext
        else { return }
        if originalContext.preparedEpoch != nil {
            return
        }
        let scopedTransitionIntent = originalContext.pendingEpochTransition.flatMap { intent -> AgentRunEpochTransitionIntent? in
            guard intent.token == transitionToken,
                  intent.expectedCurrentEpoch == originalContext.currentEpoch
            else { return nil }
            return intent
        }
        let transitionKind: AgentRunEpochTransitionKind = if let scopedTransitionIntent {
            scopedTransitionIntent.kind
        } else if originalContext.currentEpoch == nil {
            .initial
        } else if originalContext.pendingEpochTransition != nil {
            .unrelated
        } else if session.mcpFollowUpRunPending {
            .relatedFollowUp
        } else {
            .unrelated
        }
        let activationGeneration = session.mcpControlActivationGeneration
        var recoveryCancellation: ControlActivationCancellation?
        var registration = originalContext.registration
        var result = await store.beginEpoch(
            registration: registration,
            activationID: originalContext.activationID,
            expectedCurrentEpoch: originalContext.currentEpoch,
            transitionKind: transitionKind
        )
        // A stale result means the existing record advanced to another epoch; only rejected
        // results are eligible for missing-record recovery through registerIfMissing.
        if case .rejected = result {
            let cancellation = ControlActivationCancellation(
                scope: scope, session: session, activationID: originalContext.activationID,
                cancelInstalledRun: cancelInstalledRun
            )
            recoveryCancellation = cancellation
            // Control activation already requires a persistent incarnation. An unbound or
            // retiring projection cannot recover a missing registration as a new writer.
            guard stopFence.permitsStart(of: session),
                  session.mcpControlActivationGeneration == activationGeneration,
                  let context = session.mcpControlContext,
                  context.activationID == originalContext.activationID,
                  context.registration == originalContext.registration,
                  context.currentEpoch == originalContext.currentEpoch,
                  cancellation.permitsPublication,
                  let recoveredRegistration = await store.registerIfMissing(
                      recovering: originalContext.registration,
                      cancellationHandler: { await cancellation.cancel(registration: $0) }
                  )
            else {
                return
            }
            guard cancellation.permitsPublication, stopFence.permitsStart(of: session),
                  session.mcpControlActivationGeneration == activationGeneration,
                  let context = session.mcpControlContext,
                  context.activationID == originalContext.activationID,
                  context.registration == originalContext.registration,
                  context.currentEpoch == originalContext.currentEpoch
            else {
                await store.cleanup(registration: recoveredRegistration)
                return
            }
            registration = recoveredRegistration
            result = await store.beginEpoch(
                registration: registration,
                activationID: originalContext.activationID,
                expectedCurrentEpoch: nil,
                transitionKind: transitionKind
            )
        }
        await afterEpochBegan?()
        // Preserve an already-admitted original epoch even if presentation/scope membership
        // changed during the actor hop. Only new recovery control requires publication admission.
        guard recoveryCancellation?.permitsPublication != false,
              case let .accepted(epoch) = result,
              stopFence.binding == session.persistentSessionBindingIdentity,
              !session.bindingTransitionInProgress,
              session.mcpControlActivationGeneration == activationGeneration,
              var context = session.mcpControlContext,
              context.activationID == originalContext.activationID,
              context.registration == originalContext.registration,
              context.currentEpoch == originalContext.currentEpoch || context.currentEpoch == epoch
        else {
            if registration != originalContext.registration {
                await store.cleanup(registration: registration)
            }
            return
        }
        context = context.replacingRegistration(registration)
        context.currentEpoch = epoch
        context.preparedEpoch = epoch
        let pendingTransitionToken = context.pendingEpochTransition?.token
        let shouldClearPendingTransition = pendingTransitionToken == scopedTransitionIntent?.token
            || pendingTransitionToken == transitionToken
        if shouldClearPendingTransition {
            context.pendingEpochTransition = nil
        }
        session.mcpControlContext = context
        // An accepted epoch belongs to this binding even if Stop won during the actor hop.
        // Retain it unconsumed for the next start; never leave the store ahead of its owner.
        guard scope.sessions[session.tabID] === session, !scope.hasReleasedWriterClaims,
              !scope.isRetiring, stopFence.permitsStart(of: session), !Task.isCancelled else { return }
        session.mcpFollowUpRunPendingUpdatedAt = Date()
        if !session.mcpFollowUpRunPending {
            session.mcpFollowUpRunPending = true
            handleObservedMCPStateChange(for: session, store: store)
        }
    }

    struct Metadata {
        let sessionName: (AgentTabSession, UUID) -> String?
        let parentIsWorktreeBound: (UUID) -> Bool?
    }

    private weak var scope: AgentSessionRuntimeStore.Scope?
    var metadata: Metadata?
    /// Recovery claims are runtime state. The workspace check remains a read-only resource
    /// input until the window-free catalog host is installed; it never selects a writer.
    var outstandingProvisionalTargets: [UUID: AgentModeViewModel.MCPSessionTarget] = [:]
    var workspaceHasProvisionalClaim: ((UUID, UUID) -> Bool)?

    func settledSession(for writer: AgentSessionRuntimeStore.Writer) -> AgentTabSession? {
        guard writer.scope === scope, writer.isCurrent,
              workspaceHasProvisionalClaim?(writer.identity.workspaceID, writer.identity.sessionID) != true,
              !outstandingProvisionalTargets.values.contains(where: { target in
                  target.sessionID == writer.identity.sessionID
                      && target.recoveryClaim?.state != .accepted
                      && target.recoveryClaim?.state != .complete
              }) else { return nil }
        return writer.session
    }

    /// Retains the actual mapping projection, never its presentation model. Cleanup
    /// shares this storage; transport and owner-availability fences reject stale maps.
    private var runRoute: (id: Int, bindings: MCPRunRouteBindings)?

    func installRunRoute(id: Int, bindings: MCPRunRouteBindings) {
        if let runRoute {
            precondition(runRoute.id == id && runRoute.bindings === bindings)
            return
        }
        runRoute = (id, bindings)
    }

    func hasCurrentRunCatalogRouteToken(_ token: AgentSessionLinkRunCatalogRouteToken, tabID: UUID) -> Bool {
        guard let runRoute, token.observerEndpoint.windowID == runRoute.id else { return false }
        return runRoute.bindings.hasCurrentCatalogRouteToken(token, expectedTabID: tabID)
    }

    weak var codexCoordinator: CodexAgentModeCoordinator?
    weak var claudeCoordinator: ClaudeAgentModeCoordinator?
    var pendingAgentRunOracleReviewContextsBySessionID: [UUID: PendingAgentRunOracleReviewContext] = [:]
    var delegatedAgentRunOracleReviewContextsByKey: [AgentRunOracleReviewKey: DelegatedAgentRunOracleReviewContext] = [:]
    #if DEBUG
        var test_terminalPublicationOverride: ((AgentRunTerminalCommitRevision, AgentRunEpochTransitionKind?, AgentTabSession) async -> AgentRunTerminalPublicationResult)?
        var test_afterDomainTerminalPublication: (@MainActor () async -> Void)?
    #endif

    init(scope: AgentSessionRuntimeStore.Scope) {
        self.scope = scope
    }

    private nonisolated static func steeringDebugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
            guard UserDefaults.standard.bool(forKey: "enableSteeringDebugLogging") else { return }
            print(message())
        #endif
    }

    func installStateObservation(for session: AgentTabSession) {
        session.mcpStateObservationCancellable?.cancel()
        let publishers: [AnyPublisher<Void, Never>] = [
            session.$runState.map { _ in () }.eraseToAnyPublisher(),
            session.$runningStatusText.map { _ in () }.eraseToAnyPublisher(),
            session.$waitingPrompt.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingAskUser.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingUserInputRequest.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingApproval.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingCodexHookReview.map { _ in () }.eraseToAnyPublisher(),
            session.$codexHookGateAudit.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingPermissionsRequest.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingMCPElicitationRequest.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingApplyEditsReview.map { _ in () }.eraseToAnyPublisher(),
            session.$pendingWorktreeMergeReview.map { _ in () }.eraseToAnyPublisher(),
            session.$items.map { _ in () }.eraseToAnyPublisher()
        ]
        session.mcpStateObservationCancellable = Publishers.MergeMany(publishers)
            .sink { [weak self, weak session] _ in
                guard let self, let session else { return }
                handleObservedMCPStateChange(for: session)
            }
    }

    func makeBindingObservationHooks() -> AgentModeRunService.RunBindingObservationHooks {
        .init(updateBindings: { [self] session in
            scope?.presentation.bindingChanged(session)
            handleObservedMCPStateChange(for: session)
        })
    }

    func mcpSnapshot(
        for session: AgentTabSession,
        canonicalTerminalState: AgentSessionRunState? = nil,
        canonicalProviderRunID: UUID? = nil,
        canonicalFailureReason: AgentRunMCPSnapshot.FailureReason? = nil
    ) -> AgentRunMCPSnapshot? {
        guard let context = session.mcpControlContext else { return nil }
        let interaction = canonicalTerminalState == nil ? mcpPendingInteraction(for: session) : nil
        let status: AgentRunMCPSnapshot.Status = {
            if let canonicalTerminalState {
                switch canonicalTerminalState {
                case .completed:
                    return .completed
                case .failed:
                    return .failed
                case .cancelled:
                    return .cancelled
                case .idle, .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
                    return .completed
                }
            }
            if interaction != nil {
                return .waitingForInput
            }
            let terminalStatus: AgentRunMCPSnapshot.Status? = {
                switch session.runState {
                case .completed:
                    return .completed
                case .failed:
                    return .failed
                case .cancelled:
                    return .cancelled
                case .idle:
                    if let terminalState = session.transcript.turns.last?.terminalState {
                        switch terminalState {
                        case .completed:
                            return .completed
                        case .failed:
                            return .failed
                        case .cancelled:
                            return .cancelled
                        case .idle, .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
                            break
                        }
                    }
                    return .completed
                case .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
                    return nil
                }
            }()
            let now = Date()
            let followUpMaskIsStale = session.mcpFollowUpRunPending
                && session.mcpFollowUpRunPendingUpdatedAt.map { now.timeIntervalSince($0) > 15 } == true
            let supersedingMaskIsStale = session.pendingSupersedingTurnCompletions > 0
                && session.pendingSupersedingTurnCompletionsUpdatedAt.map { now.timeIntervalSince($0) > 15 } == true
            if let terminalStatus,
               context.currentEpoch != nil,
               followUpMaskIsStale || supersedingMaskIsStale,
               session.agentTask == nil,
               session.pendingInstructions.isEmpty,
               session.claudeSteeringFlushTask == nil,
               session.acpSteeringFlushTask == nil,
               claudeCoordinator?.hasPendingProviderWork(for: session) == false
            {
                Self.steeringDebugLog("[AgentRunSteeringWake] clearing stale MCP running mask sessionID=\(context.sessionID) tab=\(session.tabID) runState=\(session.runState.rawValue) terminal=\(terminalStatus.rawValue) followUp=\(session.mcpFollowUpRunPending) superseding=\(session.pendingSupersedingTurnCompletions)")
                session.mcpFollowUpRunPending = false
                session.pendingSupersedingTurnCompletions = 0
            }
            if session.mcpFollowUpRunPending || session.pendingSupersedingTurnCompletions > 0 {
                if let terminalStatus {
                    Self.steeringDebugLog("[AgentRunSteeringWake] MCP snapshot preserving active running mask over terminal state sessionID=\(context.sessionID) terminal=\(terminalStatus.rawValue) followUp=\(session.mcpFollowUpRunPending) superseding=\(session.pendingSupersedingTurnCompletions)")
                }
                return .running
            }
            if let terminalStatus {
                return terminalStatus
            }
            switch session.runState {
            case .running:
                return .running
            case .waitingForUser, .waitingForQuestion, .waitingForApproval:
                return .waitingForInput
            case .completed, .failed, .cancelled, .idle:
                return .completed
            }
        }()
        let transcriptItemCount = max(
            session.transcriptProjectionCounts.canonicalVisibleRowCount,
            session.items.count
        )
        let resolvedStatusText: String? = {
            if canonicalTerminalState == nil,
               let existing = session.runningStatusText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !existing.isEmpty
            {
                return existing
            }
            if canonicalTerminalState == nil, session.mcpFollowUpRunPending {
                return AgentRunMCPSnapshot.startupPendingStatusText
            }
            switch status {
            case .failed:
                return AgentTranscriptIO.latestErrorText(from: session.transcript, latestTurnOnly: true)
                    ?? AgentTranscriptIO.latestErrorText(from: session.transcript, latestTurnOnly: false)
                    ?? "Run failed without additional error details."
            case .cancelled:
                return "Run cancelled."
            default:
                return nil
            }
        }()
        let resolvedSessionID = context.sessionID
        let resolvedSessionName: String? = metadata?.sessionName(session, resolvedSessionID) ?? "Agent Session"
        let providerRunID: UUID? = if canonicalTerminalState != nil {
            canonicalProviderRunID ?? AgentModeProcessRunIdentity.mostRecentTranscriptProcessRunID(for: session)
        } else if status.isTerminal {
            session.runID ?? AgentModeProcessRunIdentity.mostRecentTranscriptProcessRunID(for: session)
        } else {
            session.runID
        }
        let failureReason: AgentRunMCPSnapshot.FailureReason? = {
            if let canonicalFailureReason {
                return canonicalFailureReason
            }
            // Live post-terminal polls reuse the reason stamped by the terminal
            // commit barrier; the terminal-state and run-identity guards keep a
            // stale revision from another terminal state/attempt from
            // contaminating this snapshot. Text classification remains only as
            // the restored/legacy fallback.
            if canonicalTerminalState == nil,
               let revision = session.lastTerminalCommitRevision,
               let stampedReason = revision.failureReason,
               revision.terminalState.mcpTerminalSnapshotStatus == status,
               revision.expectedRunID == providerRunID
            {
                return stampedReason
            }
            return AgentRunMCPSnapshot.FailureReason.classify(status: status, statusText: resolvedStatusText)
        }()
        return AgentRunMCPSnapshot(
            sessionID: resolvedSessionID,
            runID: providerRunID,
            tabID: session.tabID,
            sessionName: resolvedSessionName,
            agentRaw: session.selectedAgent.rawValue,
            agentDisplayName: session.selectedAgent.displayName,
            modelRaw: session.selectedModelRaw,
            reasoningEffortRaw: session.selectedReasoningEffortRaw,
            modelParameterSelections: AgentMCPModelParameterSupport.effectiveSelections(
                session.acpModelParameterSelections,
                agentRaw: session.selectedAgent.rawValue,
                modelRaw: session.selectedModelRaw
            ).map {
                AgentRunMCPSnapshot.ModelParameterSelection(
                    providerID: $0.providerID.rawValue,
                    baseModelRaw: $0.baseModelRaw,
                    kind: $0.kind.rawValue,
                    configID: $0.configID,
                    valueRaw: $0.valueRaw
                )
            },
            status: status,
            statusText: resolvedStatusText,
            latestAssistantPreview: mcpResolvedAssistantPreview(session: session, status: status),
            interaction: interaction,
            hookGate: session.codexHookGateAudit.map { AgentRunMCPSnapshot.HookGate(audit: $0) },
            transcriptItemCount: transcriptItemCount,
            updatedAt: Date(),
            parentSessionID: session.parentSessionID,
            failureReason: failureReason,
            worktreeBindings: session.worktreeBindings.map { AgentRunMCPSnapshot.WorktreeBinding(binding: $0) },
            appActiveWorktreeMerges: session.worktreeMergeOperations.activeWorktreeMergeSummaries,
            // Publishes whether the parent holds bindings so an unbound task-aware child can be
            // flagged in start/poll responses (#400). Unresolvable parents stay `nil`.
            parentIsWorktreeBound: session.parentSessionID.flatMap { parentSessionID in
                metadata?.parentIsWorktreeBound(parentSessionID)
            }
        )
    }

    func mcpApprovalDecisionOptions(for approval: AgentApprovalRequest, session: AgentTabSession) -> [AgentRunMCPSnapshot.Interaction.Option] {
        mcpApprovalDecisionLabels(for: approval, session: session, includeAliases: false).map { label in
            let description: String? = switch label {
            case "accept":
                "Allow this action"
            case "accept_for_session":
                approval.sessionApprovalScope == .editsSession
                    ? "Allow edits for the rest of this session" : "Allow this action for the rest of the session"
            case "accept_with_amendment":
                "Allow with exec policy amendment (provide amendment field)"
            case "decline":
                "Reject this action"
            case "cancel":
                "Cancel the run"
            default:
                nil
            }
            return .init(label: label, description: description)
        }
    }

    func mcpApprovalDecisionLabels(for approval: AgentApprovalRequest, session: AgentTabSession, includeAliases: Bool = true) -> [String] {
        func allows(_ decision: AgentApprovalDecision) -> Bool {
            CodexAgentModeCoordinator.allowsApprovalDecision(decision, request: approval, session: session)
        }
        var labels = allows(.accept) ? ["accept"] : []
        if allows(.acceptForSession) {
            labels.append("accept_for_session")
        }
        // Legacy requests permit caller-supplied amendments; present lists require an advertised payload.
        let allowsRememberedDecision: Bool = if case .codex = approval.requestID {
            CodexAgentModeCoordinator.computerUseAllowsDecision(.acceptForSession, session: session)
        } else { true }
        if approval.supportsExecpolicyAmendment, allowsRememberedDecision {
            labels.append("accept_with_amendment")
        }
        if allows(.decline) {
            labels.append("decline")
            if includeAliases { labels.append("reject") }
        }
        if allows(.cancel) { labels.append("cancel") }
        return labels
    }

    func mcpCodexHookDecisionOptions(
        for request: AgentCodexHookReviewRequest,
        strictModeEnabled: Bool
    ) -> [AgentRunMCPSnapshot.Interaction.Option] {
        var actions = [MCPCodexHookAction]()
        if request.phase.allowsTrustDecision {
            actions.append(contentsOf: [.approveSelected, .trustAll])
        }
        if request.phase.allowsDiscoveryRetry {
            actions.append(.retry)
        }
        if request.phase.allowsContinueWithoutHooks, !strictModeEnabled {
            actions.append(.continueWithoutHooks)
        }
        return actions.map(\.option)
    }

    func mcpCodexHookInteraction(
        for request: AgentCodexHookReviewRequest,
        strictModeEnabled: Bool
    ) -> AgentRunMCPSnapshot.Interaction {
        var details: [AgentRunMCPSnapshot.Interaction.Detail] = [
            .init(label: "Execution Directory", value: request.executionCWD, isCode: true),
            .init(label: "Phase", value: request.phase.rawValue, isCode: false)
        ]
        if let errorMessage = request.errorMessage, !errorMessage.isEmpty {
            details.append(.init(label: "Error", value: errorMessage, isCode: false))
        }
        for warning in request.warnings {
            details.append(.init(label: "Warning", value: warning, isCode: false))
        }
        for (index, hook) in request.hooks.enumerated() {
            let prefix = "Hook \(index + 1)"
            details.append(.init(label: "\(prefix) Key", value: hook.key, isCode: true))
            details.append(.init(label: "\(prefix) Event", value: hook.eventName, isCode: false))
            details.append(.init(label: "\(prefix) Source", value: hook.sourcePath, isCode: true))
            details.append(.init(label: "\(prefix) Enabled", value: hook.enabled ? "true" : "false", isCode: false))
            details.append(.init(label: "\(prefix) Trust", value: hook.trustStatus.rawValue, isCode: false))
            details.append(.init(label: "\(prefix) Current Hash", value: hook.currentHash, isCode: true))
            if let command = hook.commandOrHandler, !command.isEmpty {
                details.append(.init(label: "\(prefix) Command / Handler", value: command, isCode: true))
            }
        }
        let fields: [AgentRunMCPSnapshot.Interaction.Field] = if request.hooks.isEmpty {
            []
        } else {
            [
                .init(
                    id: "hook_keys",
                    prompt: "Hooks to approve",
                    context: "Provide exact hook keys only when response is approve_selected.",
                    isSecret: false,
                    allowsOther: false,
                    allowsMultiple: true,
                    allowsCustom: false,
                    emitAllowsOther: false,
                    options: request.hooks.map { hook in
                        .init(
                            label: hook.key,
                            description: "\(hook.eventName) · \(hook.sourcePath) · \(hook.trustStatus.rawValue)"
                        )
                    }
                )
            ]
        }
        return .init(
            id: request.id,
            kind: .hookApproval,
            responseType: .decision,
            title: "Project Hook Approval",
            prompt: "The initial Codex turn is blocked pending project-hook trust.",
            context: "Execution directory: \(request.executionCWD)",
            allowsMultiple: nil,
            options: mcpCodexHookDecisionOptions(for: request, strictModeEnabled: strictModeEnabled),
            fields: fields,
            details: details
        )
    }

    func mcpPendingInteraction(for session: AgentTabSession) -> AgentRunMCPSnapshot.Interaction? {
        if let request = session.pendingCodexHookReview {
            return mcpCodexHookInteraction(
                for: request,
                strictModeEnabled: codexCoordinator?.isCodexHookApprovalStrictModeEnabled(for: session) ?? true
            )
        }
        if let review = session.pendingWorktreeMergeReview {
            var details: [AgentRunMCPSnapshot.Interaction.Detail] = [
                .init(label: "Operation ID", value: review.operationID, isCode: false),
                .init(label: "Source", value: "\(review.sourceLabel) @ \(review.sourcePath)", isCode: false),
                .init(label: "Target", value: "\(review.targetLabel) @ \(review.targetPath)", isCode: false),
                .init(label: "Source HEAD", value: review.sourceHead, isCode: true),
                .init(label: "Target HEAD", value: review.targetHead, isCode: true),
                .init(label: "Merge Base", value: review.mergeBase, isCode: true),
                .init(label: "Visualization", value: review.visualization, isCode: true)
            ]
            if let summary = review.summary {
                details.append(.init(label: "Summary", value: "\(summary.commits) commits, \(summary.files) files (+\(summary.insertions) -\(summary.deletions))", isCode: false))
            }
            if let artifacts = review.artifacts {
                details.append(.init(label: "Preview Artifacts", value: artifacts.snapshotDirectory, isCode: true))
            }
            return .init(
                id: review.id,
                kind: .approval,
                responseType: .decision,
                title: "Worktree Merge Review",
                prompt: "Review and approve merging \(review.sourceLabel) into \(review.targetLabel).",
                context: nil,
                allowsMultiple: nil,
                options: [
                    .init(label: "accept", description: "Apply the merge after stale validation"),
                    .init(label: "decline", description: "Reject without mutating the target worktree"),
                    .init(label: "cancel", description: "Cancel without mutating the target worktree")
                ],
                fields: [],
                details: details
            )
        }
        // Note: pendingApplyEditsReview is not surfaced here because MCP-controlled sessions
        // always have autoEditEnabled=true, so apply_edits reviews never appear on this path.
        if let approval = session.pendingApproval {
            var details: [AgentRunMCPSnapshot.Interaction.Detail] = []
            details.append(.init(label: "Approval Type", value: approval.kind.rawValue, isCode: false))
            if let command = approval.command, !command.isEmpty {
                details.append(.init(label: "Command", value: command, isCode: true))
            }
            if let cwd = approval.cwd, !cwd.isEmpty {
                details.append(.init(label: "Working Directory", value: cwd, isCode: false))
            }
            if let grantRoot = approval.grantRoot, !grantRoot.isEmpty {
                details.append(.init(label: "Requested Scope", value: grantRoot, isCode: false))
            }
            if let amendment = approval.presentedExecpolicyAmendmentJSON, !amendment.isEmpty {
                details.append(.init(label: "Suggested Amendment", value: amendment, isCode: true))
            }
            for detail in approval.details {
                details.append(.init(label: detail.label, value: detail.value, isCode: detail.isCode))
            }
            return .init(
                id: approval.id,
                kind: .approval,
                responseType: .decision,
                title: approval.title,
                prompt: approval.reason,
                context: nil,
                allowsMultiple: nil,
                options: mcpApprovalDecisionOptions(for: approval, session: session),
                fields: [],
                details: details
            )
        }
        if let request = session.pendingPermissionsRequest {
            var details: [AgentRunMCPSnapshot.Interaction.Detail] = [
                .init(label: "Approval Type", value: "permissions", isCode: false),
                .init(label: "Working Directory", value: request.cwd, isCode: true)
            ]
            if let reason = request.reason, !reason.isEmpty {
                details.append(.init(label: "Reason", value: reason, isCode: false))
            }
            details.append(.init(label: "Requested Permissions", value: request.permissionsJSON, isCode: true))
            return .init(
                id: request.id,
                kind: .approval,
                responseType: .decision,
                title: request.title,
                prompt: request.reason,
                context: nil,
                allowsMultiple: nil,
                options: [
                    .init(label: "accept", description: "Allow these permissions for this turn"),
                    .init(label: "accept_for_session", description: "Allow these permissions for the rest of the session"),
                    .init(label: "decline", description: "Reject these permissions"),
                    .init(label: "cancel", description: "Reject these permissions and cancel the run")
                ],
                fields: [],
                details: details
            )
        }
        if let request = session.pendingMCPElicitationRequest {
            var details: [AgentRunMCPSnapshot.Interaction.Detail] = []
            if let serverName = request.serverName, !serverName.isEmpty {
                details.append(.init(label: "Server", value: serverName, isCode: false))
            }
            if let toolName = request.toolName, !toolName.isEmpty {
                details.append(.init(label: "Tool", value: toolName, isCode: false))
            }
            for detail in request.details {
                details.append(.init(label: detail.label, value: detail.value, isCode: detail.isCode))
            }
            return .init(
                id: request.id,
                kind: .mcpElicitation,
                responseType: .elicitation,
                title: request.title,
                prompt: request.prompt ?? request.message,
                context: "Codex requested input or approval from MCP server \(request.serverName ?? "unknown").",
                allowsMultiple: nil,
                options: [
                    .init(label: "accept", description: "Accept this MCP elicitation and send content"),
                    .init(label: "decline", description: "Decline this MCP elicitation"),
                    .init(label: "cancel", description: "Cancel the run")
                ],
                fields: [],
                details: details
            )
        }
        if let request = session.pendingUserInputRequest {
            return .init(
                id: request.id,
                kind: .userInput,
                responseType: .structured,
                title: "User Input Requested",
                prompt: request.questions.count == 1
                    ? request.questions[0].question
                    : "Provide the requested structured input to continue.",
                context: nil,
                allowsMultiple: nil,
                options: [],
                fields: request.questions.map { question in
                    .init(
                        id: question.id,
                        header: question.header,
                        prompt: question.question,
                        isSecret: question.isSecret,
                        allowsOther: question.isOtherOptionEnabled,
                        options: question.options.map {
                            .init(label: $0.label, description: $0.description)
                        }
                    )
                },
                details: []
            )
        }
        if let pendingAskUser = session.pendingAskUser {
            let interaction = pendingAskUser.interaction
            return .init(
                id: interaction.id,
                kind: .question,
                responseType: .structured,
                title: interaction.title ?? "Questions",
                prompt: interaction.questions.count == 1
                    ? interaction.questions[0].question
                    : "Provide the requested answers to continue.",
                context: interaction.context,
                allowsMultiple: nil,
                options: [],
                fields: interaction.questions.map { question in
                    .init(
                        id: question.id,
                        header: question.header,
                        prompt: question.question,
                        context: question.context,
                        isSecret: false,
                        allowsOther: question.allowsCustom,
                        allowsMultiple: question.allowsMultiple,
                        allowsCustom: question.allowsCustom,
                        emitAllowsOther: false,
                        options: question.options.map { .init(label: $0.label, description: $0.description) }
                    )
                },
                details: []
            )
        }
        if session.instructionContinuation != nil || session.waitingPrompt != nil {
            return .init(
                id: session.instructionWaitID ?? session.mcpControlContext?.sessionID ?? UUID(),
                kind: .instruction,
                responseType: .text,
                title: "Awaiting Instruction",
                prompt: session.waitingPrompt ?? "What would you like me to do next?",
                context: nil,
                allowsMultiple: nil,
                options: [],
                fields: [],
                details: []
            )
        }
        return nil
    }

    func mcpResolvedAssistantPreview(session: AgentTabSession, status: AgentRunMCPSnapshot.Status) -> String? {
        switch status {
        case .expired:
            return nil
        case .running, .waitingForInput:
            if session.mcpFollowUpRunPending {
                return nil
            }
            guard let lastTurn = session.transcript.turns.last else {
                // Fallback for transcriptless sessions: only use items if latest assistant is newer than latest user
                let latestAssistant = session.items.reversed().first(where: { $0.hasDisplayableAssistantBody })
                let latestUser = session.items.reversed().first(where: { $0.kind == .user })
                guard let assistant = latestAssistant else { return nil }
                if let user = latestUser, user.timestamp >= assistant.timestamp {
                    return nil
                }
                return assistant.text
            }
            if lastTurn.isCompleted, status == .running {
                return nil
            }
            return AgentTranscriptIO.latestAssistantPreviewText(in: lastTurn)
        case .completed, .failed, .cancelled:
            let transcriptPreview = session.transcript.turns.last.flatMap {
                AgentTranscriptIO.terminalAssistantResponseText(in: $0)
            }
            let sourcePreview = AgentTranscriptIO.terminalAssistantResponseText(from: session.items)
            let projectionProtection = AgentSessionTranscriptRefreshRuntime.transcriptProjectionProtection(
                for: session,
                transcript: session.transcript
            )
            if AgentSessionTranscriptRefreshRuntime.canReuseDerivedTranscriptForSave(
                for: session,
                projectionProtection: projectionProtection
            ) {
                return transcriptPreview ?? sourcePreview
            }
            return session.items.isEmpty ? transcriptPreview : sourcePreview
        }
    }

    enum MCPCodexHookAction: String {
        case approveSelected = "approve_selected"
        case trustAll = "trust_all"
        case continueWithoutHooks = "continue_without_hooks"
        case retry

        var option: AgentRunMCPSnapshot.Interaction.Option {
            switch self {
            case .approveSelected:
                .init(label: rawValue, description: "Trust only the hook_keys answer and continue")
            case .trustAll:
                .init(label: rawValue, description: "Trust every hook shown and continue")
            case .continueWithoutHooks:
                .init(
                    label: rawValue,
                    description: "Continue this Codex session without enabling the shown project hooks"
                )
            case .retry:
                .init(label: rawValue, description: "Retry project-hook discovery")
            }
        }
    }

    func mcpControlContextMatches(
        tabID: UUID,
        sessionID: UUID,
        activationID: UUID,
        registration: AgentRunSessionStore.Registration
    ) -> Bool {
        guard let session = scope?.sessions[tabID],
              let context = session.mcpControlContext
        else {
            return false
        }
        return context.sessionID == sessionID
            && context.activationID == activationID
            && context.registration == registration
            && session.activeAgentSessionID == sessionID
    }

    func handleObservedMCPStateChange(
        for session: AgentTabSession,
        store: DomainAgentRunSessionStore = AgentRunSessionStore.shared
    ) {
        guard !session.terminalCommitInProgress else { return }
        // Terminal waiter publication is owned exclusively by AgentRunTerminalCommitBarrier.
        // Legacy/special-purpose state changes without a canonical revision must not race it.
        if session.runState.isTerminalForCommit {
            return
        }
        guard let snapshot = mcpSnapshot(for: session),
              let context = session.mcpControlContext
        else {
            return
        }
        guard let scope, scope.sessions[session.tabID] === session else { return }
        let tabID = session.tabID
        let binding = session.currentRestorationBindingToken

        let cursor = AgentRunSessionStore.WaitCursor(
            registration: context.registration,
            epoch: context.currentEpoch
        )
        Task { [self, scope, session] in
            guard scope.sessions[tabID] === session,
                  session.currentRestorationBindingToken == binding,
                  mcpControlContextMatches(
                      tabID: tabID,
                      sessionID: snapshot.sessionID,
                      activationID: context.activationID,
                      registration: context.registration
                  ) == true
            else {
                return
            }
            await store.noteSnapshot(snapshot, cursor: cursor)
        }

        if snapshot.status.isTerminal {
            if session.mcpControlCleanupTask == nil {
                session.mcpControlCleanupTask = Task {}
            }
        } else {
            session.mcpControlCleanupTask?.cancel()
            session.mcpControlCleanupTask = nil
        }
    }

    func makeTerminalPublicationEnvelope(
        for session: AgentTabSession,
        ownership: AgentRunOwnership,
        terminalState: AgentSessionRunState,
        providerRunID: UUID?,
        failureReason: AgentRunMCPSnapshot.FailureReason?
    ) -> AgentRunTerminalPublicationEnvelope? {
        guard let epoch = ownership.turnEpoch,
              let context = session.mcpControlContext,
              context.sessionID == epoch.sessionID,
              context.activationID == epoch.activationID,
              context.registration.generation == epoch.registrationGeneration,
              let snapshot = mcpSnapshot(
                  for: session,
                  canonicalTerminalState: terminalState,
                  canonicalProviderRunID: providerRunID,
                  canonicalFailureReason: failureReason
              )
        else {
            return nil
        }
        return AgentRunTerminalPublicationEnvelope(epoch: epoch, snapshot: snapshot)
    }

    func publishTerminalCommit(
        _ revision: AgentRunTerminalCommitRevision,
        successorKind: AgentRunEpochTransitionKind?,
        for session: AgentTabSession
    ) async -> AgentRunTerminalPublicationResult {
        // The existing activation/registration owns terminal publication even after its
        // presentation drops the object. Scope membership only gates local successor effects.
        let scope = scope
        let binding = session.currentRestorationBindingToken
        let sessionID = session.activeAgentSessionID
        let result = await publishTerminal(revision, successorKind: successorKind, for: session, scope: scope, binding: binding)
        if result.isResolved, let sessionID, let runID = revision.expectedRunID {
            mcpRemoveAgentRunOracleReviewContext(sessionID: sessionID, runID: runID)
        }
        return result
    }

    private func publishTerminal(
        _ revision: AgentRunTerminalCommitRevision,
        successorKind: AgentRunEpochTransitionKind?,
        for session: AgentTabSession,
        scope: AgentSessionRuntimeStore.Scope?,
        binding: AgentSessionRestorationBindingToken?
    ) async -> AgentRunTerminalPublicationResult {
        #if DEBUG
            if let test_terminalPublicationOverride {
                return await test_terminalPublicationOverride(
                    revision,
                    successorKind,
                    session
                )
            }
        #endif
        guard let envelope = revision.mcpPublicationEnvelope else {
            return session.mcpControlContext == nil
                ? .accepted(successorEpoch: nil)
                : .rejected(reason: "missing_terminal_publication_envelope")
        }
        guard let context = session.mcpControlContext,
              context.sessionID == envelope.epoch.sessionID,
              context.activationID == envelope.epoch.activationID,
              context.registration.generation == envelope.epoch.registrationGeneration
        else {
            return .rejected(reason: "activation_replaced")
        }
        var result = await AgentRunSessionStore.publishTerminal(
            envelope,
            registration: context.registration,
            commitID: revision.commitID,
            successorKind: successorKind
        )
        #if DEBUG
            await test_afterDomainTerminalPublication?()
        #endif
        if successorKind != nil,
           case .accepted(successorEpoch: nil) = result
        {
            result = .rejected(reason: "missing_successor_epoch")
        }
        // Publication may have committed in the domain store during suspension. Keep that
        // result honest, but never apply its successor epoch to a rebound/replaced object.
        guard scope?.sessions[session.tabID] === session,
              session.currentRestorationBindingToken == binding,
              session.mcpControlContext?.activationID == context.activationID,
              session.mcpControlContext?.registration == context.registration
        else { return result }
        if let successorEpoch = result.successorEpoch,
           var liveContext = session.mcpControlContext,
           liveContext.activationID == context.activationID,
           liveContext.registration == context.registration
        {
            liveContext.currentEpoch = successorEpoch
            liveContext.preparedEpoch = successorEpoch
            session.mcpControlContext = liveContext
        }
        if result.isResolved, session.mcpControlCleanupTask == nil {
            session.mcpControlCleanupTask = Task {}
        }
        return result
    }

    func signalMCPInstructionDelivered(for session: AgentTabSession) async {
        guard let scope, scope.sessions[session.tabID] === session else { return }
        guard let snapshot = mcpSnapshot(for: session),
              let context = session.mcpControlContext
        else {
            Self.steeringDebugLog("[AgentRunSteeringWake] skip delivered signal: missing snapshot/control context tab=\(session.tabID) runState=\(session.runState.rawValue)")
            return
        }
        guard mcpControlContextMatches(
            tabID: session.tabID,
            sessionID: snapshot.sessionID,
            activationID: context.activationID,
            registration: context.registration
        ) else {
            Self.steeringDebugLog("[AgentRunSteeringWake] skip delivered signal: control context mismatch sessionID=\(snapshot.sessionID) tab=\(session.tabID)")
            return
        }
        Self.steeringDebugLog("[AgentRunSteeringWake] signal delivered sessionID=\(snapshot.sessionID) tab=\(session.tabID) status=\(snapshot.status.rawValue) runState=\(session.runState.rawValue)")
        await AgentRunSessionStore.signalSnapshotAndWakeWaiters(
            snapshot,
            cursor: .init(registration: context.registration, epoch: context.currentEpoch),
            reason: .instructionDelivered
        )
    }

    func signalMCPInstructionDeliveredFireAndForget(for session: AgentTabSession) {
        guard let snapshot = mcpSnapshot(for: session),
              let context = session.mcpControlContext
        else {
            Self.steeringDebugLog("[AgentRunSteeringWake] skip delivered signal fire-and-forget: missing snapshot/control context tab=\(session.tabID) runState=\(session.runState.rawValue)")
            return
        }
        guard let scope, scope.sessions[session.tabID] === session else { return }
        let tabID = session.tabID
        let binding = session.currentRestorationBindingToken
        Task { @MainActor [self, scope, session] in
            guard scope.sessions[tabID] === session,
                  session.currentRestorationBindingToken == binding,
                  mcpControlContextMatches(
                      tabID: tabID,
                      sessionID: snapshot.sessionID,
                      activationID: context.activationID,
                      registration: context.registration
                  ) == true
            else {
                Self.steeringDebugLog("[AgentRunSteeringWake] skip delivered signal fire-and-forget: control context mismatch sessionID=\(snapshot.sessionID) tab=\(tabID)")
                return
            }
            Self.steeringDebugLog("[AgentRunSteeringWake] fire delivered signal sessionID=\(snapshot.sessionID) tab=\(tabID) status=\(snapshot.status.rawValue)")
            await AgentRunSessionStore.signalSnapshotAndWakeWaiters(
                snapshot,
                cursor: .init(registration: context.registration, epoch: context.currentEpoch),
                reason: .instructionDelivered
            )
        }
    }

    struct AgentRunOracleReviewKey: Hashable {
        let sessionID: UUID
        let runID: UUID
    }

    @discardableResult
    func mcpBindPendingAgentRunOracleReviewContext(
        tabID: UUID,
        runID: UUID
    ) -> DelegatedAgentRunOracleReviewContext? {
        guard let session = scope?.sessions[tabID],
              let sessionID = session.activeAgentSessionID,
              let controlContext = session.mcpControlContext,
              controlContext.sessionID == sessionID
        else { return nil }

        let key = AgentRunOracleReviewKey(sessionID: sessionID, runID: runID)
        if let existing = delegatedAgentRunOracleReviewContextsByKey[key],
           existing.target.tabID == tabID,
           existing.target.activationID == controlContext.activationID
        {
            return existing
        }
        guard let pending = pendingAgentRunOracleReviewContextsBySessionID[sessionID] else {
            return nil
        }

        var validationFailure = pending.target.validationFailure
        if pending.target.tabID != tabID
            || pending.target.activationID != controlContext.activationID
            || pending.target.agentSessionID != sessionID
        {
            validationFailure = .targetActivationMismatch
        }
        if delegatedAgentRunOracleReviewContextsByKey.contains(where: {
            $0.key.sessionID == sessionID && $0.key.runID != runID
        }) {
            validationFailure = .pendingContextAlreadyConsumed
        }

        let target = AgentRunOracleReviewTargetSnapshot(
            tabID: pending.target.tabID,
            workspaceID: pending.target.workspaceID,
            agentSessionID: pending.target.agentSessionID,
            activationID: pending.target.activationID,
            expectedParentSessionID: pending.target.expectedParentSessionID,
            worktreeBindings: pending.target.worktreeBindings,
            validationFailure: validationFailure
        )
        let delegated = DelegatedAgentRunOracleReviewContext(
            source: pending.source,
            target: target,
            targetRunID: runID
        )
        pendingAgentRunOracleReviewContextsBySessionID.removeValue(forKey: sessionID)
        delegatedAgentRunOracleReviewContextsByKey = delegatedAgentRunOracleReviewContextsByKey.filter {
            $0.key.sessionID != sessionID
        }
        delegatedAgentRunOracleReviewContextsByKey[key] = delegated
        return delegated
    }

    func mcpRemoveAgentRunOracleReviewContexts(sessionID: UUID) {
        pendingAgentRunOracleReviewContextsBySessionID.removeValue(forKey: sessionID)
        delegatedAgentRunOracleReviewContextsByKey = delegatedAgentRunOracleReviewContextsByKey.filter {
            $0.key.sessionID != sessionID
        }
    }

    func mcpRemoveAgentRunOracleReviewContext(sessionID: UUID, runID: UUID) {
        delegatedAgentRunOracleReviewContextsByKey.removeValue(
            forKey: AgentRunOracleReviewKey(sessionID: sessionID, runID: runID)
        )
    }
}
