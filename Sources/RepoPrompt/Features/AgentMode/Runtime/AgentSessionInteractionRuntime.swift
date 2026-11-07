import Foundation
import RepoPromptDomainRuntime

/// Provider interaction state and approval-store work belong to the runtime scope, not its
/// presentation. The route ID preserves the existing MCP approval namespace; it is not a window
/// reference. Approval and run lifecycle authorities remain unchanged.
@MainActor
protocol AgentRunInteractionStateObserving: AnyObject {
    func runInteractionStateChanged(for session: AgentTabSession, reason: AgentRunInteractionStateChangeReason)
}

enum AgentRunInteractionStateChangeReason: String, Equatable {
    case userInputResponseSubmitted
    case pendingQuestionCancelled
    case pendingApprovalCancelled
    case approvalResponseSubmitted
    case permissionsResponseSubmitted
    case mcpElicitationResponseSubmitted
}

@MainActor
final class AgentSessionInteractionRuntime {
    private(set) weak var scope: AgentSessionRuntimeStore.Scope?
    private(set) weak var codexCommands: CodexAgentModeCoordinator?
    private(set) weak var claudeCommands: ClaudeAgentModeCoordinator?

    func installProviderCommands(codex: CodexAgentModeCoordinator, claude: ClaudeAgentModeCoordinator) {
        precondition(codexCommands == nil || codexCommands === codex)
        precondition(claudeCommands == nil || claudeCommands === claude)
        codexCommands = codex
        claudeCommands = claude
    }

    /// Admit an effect synchronously, retaining its exact owner until the effect has joined.
    func performEffect(for session: AgentTabSession, operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        let owner = scope
        let task = Task { [self, owner] in
            defer {
                pendingEffects.removeValue(forKey: id)
                _ = owner
            }
            await operation()
        }
        pendingEffects[id] = PendingEffect(sessionIdentity: ObjectIdentifier(session), task: task)
    }

    let routeID: Int
    let approvalStore: ApplyEditsApprovalStore
    weak var observer: (any AgentRunInteractionStateObserving)?
    private var subscriptions: [ObjectIdentifier: UUID] = [:]
    // Request-lifetime identities fence delayed caller cancellation from a subsequent question,
    // even when a caller reuses its public interaction ID on the same session object.
    var questionWaitIDs: [ObjectIdentifier: UUID] = [:]
    private struct CancellationCutoff {
        weak var session: AgentTabSession?
        let instant: ContinuousClock.Instant
    }

    private var cancellationCutoffs: [ObjectIdentifier: CancellationCutoff] = [:]
    private struct PendingEffect {
        let sessionIdentity: ObjectIdentifier
        let task: Task<Void, Never>
    }

    private var pendingEffects: [UUID: PendingEffect] = [:]

    #if DEBUG
        var test_beforeApprovalCancellation: (@MainActor () async -> Void)?
    #endif

    init(scope: AgentSessionRuntimeStore.Scope, routeID: Int, approvalStore: ApplyEditsApprovalStore) {
        self.scope = scope
        self.routeID = routeID
        self.approvalStore = approvalStore
    }

    func approvalScope(for session: AgentTabSession) -> ApplyEditsApprovalScope {
        .init(windowID: routeID, tabID: session.tabID)
    }

    func publishRunInteractionStateChange(for session: AgentTabSession, reason: AgentRunInteractionStateChangeReason) {
        observer?.runInteractionStateChanged(for: session, reason: reason)
    }

    func makeRunHooks() -> AgentModeRunService.RunInteractionHooks {
        .init(
            cancelPendingQuestion: { [self] in cancelPendingQuestion(for: $0) },
            cancelPendingApproval: { [self] in cancelPendingApproval(for: $0) },
            cancelPendingApplyEditsReview: { [self] in cancelPendingApplyEditsReview(for: $0, reason: $1) },
            cancelPendingWorktreeMergeReview: { [self] in cancelPendingWorktreeMergeReview(for: $0, reason: $1) },
            drainPendingEffects: { [self] in await drainPendingEffects(for: $0) }
        )
    }

    /// Exact-object subscription: a late snapshot never gets routed by tab UUID to a replacement.
    /// The task does not retain the scope forever; the host owns the subscription lifetime.
    func ensureApprovalSync(for session: AgentTabSession) {
        guard session.applyEditsApprovalSubscriptionTask == nil,
              let scope, scope.sessions[session.tabID] === session else { return }
        let identity = ObjectIdentifier(session)
        let generation = UUID()
        subscriptions[identity] = generation
        let address = approvalScope(for: session)
        let initialAutoEdit = session.autoEditEnabled
        let store = approvalStore
        session.applyEditsApprovalSubscriptionTask = Task { [weak self, weak scope, weak session] in
            await store.setAutoEditEnabled(initialAutoEdit, for: address, updateGlobalDefault: false)
            let (subscriptionID, stream) = await store.subscribe(scope: address)
            if self?.subscriptions[identity] == generation, !Task.isCancelled {
                session?.applyEditsApprovalSubscriptionID = subscriptionID
                for await snapshot in stream {
                    guard !Task.isCancelled, let self, let session,
                          subscriptions[identity] == generation,
                          scope?.sessions[session.tabID] === session else { break }
                    applyApprovalSnapshot(snapshot, to: session)
                }
            }
            await store.unsubscribe(scope: address, id: subscriptionID)
            if let self, subscriptions[identity] == generation {
                subscriptions.removeValue(forKey: identity)
                session?.applyEditsApprovalSubscriptionID = nil
                session?.applyEditsApprovalSubscriptionTask = nil
            }
        }
    }

    func applyApprovalSnapshot(_ snapshot: ApplyEditsApprovalSnapshot, to session: AgentTabSession) {
        guard let scope, scope.sessions[session.tabID] === session,
              snapshot.scope == approvalScope(for: session) else { return }
        let changed = session.autoEditEnabled != snapshot.autoEditEnabled
        session.autoEditEnabled = snapshot.autoEditEnabled
        if changed, session.mcpControlContext == nil {
            session.isDirty = true
            scope.persistence.scheduleSave(for: session)
        }
        scope.presentation.permissionsChanged(session)
        let cutoff = cancellationCutoffs[ObjectIdentifier(session)]
        let cancelled = cutoff?.session === session && snapshot.pendingReview.map { review in
            cutoff.map { review.admissionTime <= $0.instant } ?? false
        } == true
        session.pendingApplyEditsReview = cancelled ? nil : snapshot.pendingReview
        Self.reconcileInteractiveRunState(session)
        scope.presentation.makeRunHooks().requestUIRefresh(session, true)
    }

    func teardownApprovalSync(for session: AgentTabSession, cleanupScope: Bool) async {
        let identity = ObjectIdentifier(session)
        subscriptions.removeValue(forKey: identity)
        let task = session.applyEditsApprovalSubscriptionTask
        task?.cancel()
        session.applyEditsApprovalSubscriptionTask = nil
        session.applyEditsApprovalSubscriptionID = nil
        // Join the original subscription before allowing cleanup to finish. Cancel alone does
        // not acknowledge an in-flight subscribe/unsubscribe actor hop.
        await task?.value
        await drainPendingEffects(for: session)
        if cleanupScope, subscriptions[identity] == nil,
           scope?.sessions[session.tabID] == nil || scope?.sessions[session.tabID] === session
        {
            await approvalStore.cleanupScope(approvalScope(for: session))
        }
    }

    func cancelPendingApplyEditsReview(for session: AgentTabSession, reason: String) {
        let reviewID = session.pendingApplyEditsReview?.id
        let cutoff = ContinuousClock.now
        cancellationCutoffs = cancellationCutoffs.filter { $0.value.session != nil }
        cancellationCutoffs[ObjectIdentifier(session)] = .init(session: session, instant: cutoff)
        let binding = session.persistentSessionBindingIdentity
        let restoration = session.currentRestorationBindingToken
        session.pendingApplyEditsReview = nil
        let address = approvalScope(for: session)
        let store = approvalStore
        let id = UUID()
        // Retain the exact owner through the admitted store effect. This does not retain a
        // presenter, and a cancelled waiter is not evidence that cancellation has drained.
        let owner = scope
        let task = Task { [self, owner] in
            defer { pendingEffects.removeValue(forKey: id)
                _ = owner
            }
            #if DEBUG
                await test_beforeApprovalCancellation?()
            #endif
            if owner?.sessions[session.tabID] === session,
               session.persistentSessionBindingIdentity == binding,
               session.currentRestorationBindingToken == restoration
            {
                // Cancel all already-admitted work for this exact stopping owner, including
                // a newer review whose snapshot has not reached the runtime yet. A review
                // admitted after Stop cannot be consumed by this delayed store operation.
                await store.cancelPendingReview(scope: address, reason: reason, admittedAtOrBefore: cutoff)
            } else if let reviewID {
                // Detached terminal work may settle its known original review, never the
                // replacement's entire namespace, even when it shares the same tab UUID.
                await store.resolveReview(scope: address, reviewID: reviewID, decision: .cancelled(reason: reason))
            }
        }
        pendingEffects[id] = PendingEffect(sessionIdentity: ObjectIdentifier(session), task: task)
    }

    func drainPendingEffects(for session: AgentTabSession? = nil) async {
        let identity = session.map(ObjectIdentifier.init)
        while true {
            let pending = pendingEffects.values.filter { identity == nil || $0.sessionIdentity == identity }
            guard !pending.isEmpty else { return }
            for effect in pending {
                await effect.task.value
            }
        }
    }

    func finishPendingWorktreeMergeReview(session: AgentTabSession) {
        session.worktreeMergeReviewTimeoutTask?.cancel()
        session.worktreeMergeReviewTimeoutTask = nil
        session.worktreeMergeReviewContinuation = nil
        session.pendingWorktreeMergeReview = nil
        Self.reconcileInteractiveRunState(session)
        scope?.presentation.makeRunHooks().requestUIRefresh(session, true)
    }

    func cancelPendingWorktreeMergeReview(for session: AgentTabSession, reason: String) {
        let operationID = session.pendingWorktreeMergeReview?.operationID
        let continuation = session.worktreeMergeReviewContinuation
        finishPendingWorktreeMergeReview(session: session)
        if let operationID {
            do {
                try AgentWorktreeMergeCoordinator.update(operationID: operationID, in: &session.worktreeMergeOperations) {
                    $0.status = .cancelled
                    $0.completedAt = Date()
                    $0.lastError = reason
                }
                session.isDirty = true
                scope?.presentation.worktreeOperationsChanged(session)
                scope?.mcp.handleObservedMCPStateChange(for: session)
                scope?.presentation.bindingChanged(session)
                scope?.persistence.scheduleSave(for: session)
            } catch {
                // Preserve the existing best-effort cancellation when the operation was removed.
            }
        }
        continuation?.resume(returning: .cancelled(reason: reason))
    }

    static func reconcileInteractiveRunState(_ session: AgentTabSession) {
        let nextState: AgentSessionRunState? = if session.pendingApplyEditsReview != nil || session.pendingWorktreeMergeReview != nil || session.pendingApproval != nil || session.hasPendingCodexHookReviewRequest || session.pendingPermissionsRequest != nil || session.pendingMCPElicitationRequest != nil {
            .waitingForApproval
        } else if session.hasPendingQuestionUI {
            .waitingForQuestion
        } else if session.waitingPrompt != nil || session.instructionContinuation != nil {
            .waitingForUser
        } else if session.runState.isActive,
                  session.runState == .waitingForApproval
                  || session.runState == .waitingForQuestion
                  || session.runState == .waitingForUser
        {
            .running
        } else {
            nil
        }

        guard let nextState else { return }
        session.runState = nextState
        if nextState == .waitingForApproval || nextState == .waitingForQuestion || nextState == .waitingForUser {
            session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
            session.setRunningStatus(nil, source: nil)
        }
    }

    static func invalidatePendingAskUserTimeout(for session: AgentTabSession) {
        session.pendingAskUserTimeoutGeneration &+= 1
        session.askUserTimeoutTask?.cancel()
        session.askUserTimeoutTask = nil
        if var pending = session.pendingAskUser {
            pending.timeoutStartedAt = nil
            session.pendingAskUser = pending
        }
    }

    func cancelPendingQuestion(for session: AgentTabSession) {
        Self.invalidatePendingAskUserTimeout(for: session)
        let continuation = session.askUserContinuation
        session.askUserContinuation = nil
        session.pendingAskUser = nil
        session.pendingPermissionsRequest = nil
        session.pendingMCPElicitationRequest = nil
        session.queuedUserInputRequests.removeAll()
        session.queuedMCPElicitationRequests.removeAll()
        Self.reconcileInteractiveRunState(session)
        continuation?.resume(throwing: CancellationError())
        publishRunInteractionStateChange(for: session, reason: .pendingQuestionCancelled)
    }

    func cancelPendingApproval(for session: AgentTabSession) {
        session.pendingApproval = nil
        if session.hasActiveCodexHookGateOperation {
            session.resetCodexHookGateBinding()
        }
        session.pendingPermissionsRequest = nil
        session.pendingMCPElicitationRequest = nil
        session.queuedMCPElicitationRequests.removeAll()
        Self.reconcileInteractiveRunState(session)
        publishRunInteractionStateChange(for: session, reason: .pendingApprovalCancelled)
    }

    static func cancelPendingInstruction(for session: AgentTabSession) {
        session.instructionTimeoutTask?.cancel()
        session.instructionTimeoutTask = nil
        if let continuation = session.instructionContinuation {
            continuation.resume(throwing: CancellationError())
        }
        session.instructionContinuation = nil
        session.instructionWaitID = nil
        session.waitingPrompt = nil
    }
}
