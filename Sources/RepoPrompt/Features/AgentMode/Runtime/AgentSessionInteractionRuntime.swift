import Foundation
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

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
    case codexHookReviewChanged
}

@MainActor
final class AgentSessionInteractionRuntime {
    private(set) weak var scope: AgentSessionRuntimeStore.Scope?
    private(set) weak var claudeCommands: ClaudeAgentModeCoordinator?
    var codexHookApprovalSettings: (any CodexHookApprovalSettingsProviding)?

    func installClaudeCancellationCommands(_ claude: ClaudeAgentModeCoordinator) {
        precondition(claudeCommands == nil || claudeCommands === claude)
        claudeCommands = claude
    }

    /// Admit an effect synchronously, retaining its exact owner until the effect has joined.
    @discardableResult
    func performEffect(for session: AgentTabSession, operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let owner = scope
        let task = Task { [self, owner] in
            defer {
                pendingEffects.removeValue(forKey: id)
                owner?.noteSettlementChanged()
                _ = owner
            }
            await operation()
        }
        pendingEffects[id] = PendingEffect(sessionIdentity: ObjectIdentifier(session), task: task)
        return task
    }

    let routeID: Int
    let approvalStore: ApplyEditsApprovalStore
    weak var observer: (any AgentRunInteractionStateObserving)?
    @MainActor
    private final class ApprovalSync {
        weak var session: AgentTabSession?
        let identity: AgentSessionRuntimeStore.MembershipIdentity
        let binding: AgentPersistentSessionBindingIdentity?
        let hydrated: Bool
        var lease: UUID?
        var listener: Task<Void, Never>?

        init(identity: AgentSessionRuntimeStore.MembershipIdentity, session: AgentTabSession) {
            self.identity = identity
            self.session = session
            binding = session.persistentSessionBindingIdentity
            hydrated = session.hasLoadedPersistedState
        }
    }

    private var approvalSyncs: [ObjectIdentifier: ApprovalSync] = [:]
    private var approvalTails: [ApplyEditsApprovalScope: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Request-lifetime identities fence delayed caller cancellation from a subsequent question,
    /// even when a caller reuses its public interaction ID on the same session object.
    struct QuestionWait {
        let id: UUID
        let writer: AgentSessionRuntimeStore.WriterIdentity
        let runID: UUID?
        let runAttemptID: UUID?
    }

    var questionWaits: [ObjectIdentifier: QuestionWait] = [:]
    private struct CancellationCutoff {
        weak var session: AgentTabSession?
        let instant: ContinuousClock.Instant
        let membership: AgentSessionRuntimeStore.MembershipIdentity?
        let reviewID: UUID?
    }

    private var cancellationCutoffs: [ObjectIdentifier: CancellationCutoff] = [:]
    private struct PendingEffect {
        let sessionIdentity: ObjectIdentifier
        let task: Task<Void, Never>
    }

    private var pendingEffects: [UUID: PendingEffect] = [:]

    #if DEBUG
        var test_beforeApprovalCancellation: (@MainActor () async -> Void)?
        var test_beforeApprovalSyncCommit: (@MainActor () async -> Void)?
        var test_onApprovalEffectEnqueued: (@MainActor (AgentTabSession) -> Void)?
        var test_onApprovalListenerJoin: (@MainActor () -> Void)?
        var test_beforeApprovalSyncCleanup: (@MainActor () async -> Void)?
        var test_beforeApprovalSnapshot: (@MainActor () async -> Void)?
        var test_beforeAutoEditWrite: (@MainActor () async -> Void)?
        var test_beforeApprovalDecision: (@MainActor () async -> Void)?
        var test_onHookGateCoalescedWaiterInstalled: (@MainActor () -> Void)?
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

    /// Transactions explicitly join their predecessor; actor scheduling is not an ordering
    /// guarantee. Stream listeners stay outside this finite effect queue.
    @discardableResult
    private func enqueueApprovalEffect(
        for session: AgentTabSession, operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let address = approvalScope(for: session)
        let predecessor = approvalTails[address]?.task
        let id = UUID()
        let task = performEffect(for: session) { [self] in
            await predecessor?.value
            await operation()
            if approvalTails[address]?.id == id { approvalTails.removeValue(forKey: address) }
        }
        approvalTails[address] = (id, task)
        #if DEBUG
            test_onApprovalEffectEnqueued?(session)
        #endif
        return task
    }

    /// The projection fence is reference-free; the listener cannot retain its owning scope.
    /// Store preparation followed by membership revalidation and CAS also fences late seeds.
    func adoptReadyApprovalPayload(for session: AgentTabSession) {
        ensureApprovalSync(for: session, adoptPayload: true)
    }

    func ensureApprovalSync(for session: AgentTabSession, adoptPayload: Bool = false) {
        guard let scope, let membership = scope.membership(of: session),
              membership.permitsBindingPreparation else { return }
        let identity = ObjectIdentifier(session)
        let candidate = approvalSyncs[identity]
        let previous = candidate?.session === session ? candidate : nil
        if !adoptPayload, let previous, previous.identity == membership.identity,
           previous.hydrated == session.hasLoadedPersistedState,
           session.applyEditsApprovalSubscriptionTask != nil { return }
        let oldListener = previous?.listener ?? session.applyEditsApprovalSubscriptionTask
        oldListener?.cancel()
        let record = ApprovalSync(identity: membership.identity, session: session)
        approvalSyncs[identity] = record
        let address = approvalScope(for: session)
        let initialAutoEdit = session.autoEditEnabled
        let replacePayload = previous == nil || previous?.binding != record.binding
        let store = approvalStore
        session.applyEditsApprovalSubscriptionID = nil
        // A finite begin transaction installs the listener, then completes. Cleanup and
        // manual writes capture this record, never whichever record later occupies the key.
        let begin = enqueueApprovalEffect(for: session) { [weak self, weak scope, weak session, record] in
            var installedListener = false
            defer {
                if !installedListener, self?.approvalSyncs[identity] === record {
                    session?.applyEditsApprovalSubscriptionID = nil
                    session?.applyEditsApprovalSubscriptionTask = nil
                }
            }
            await oldListener?.value
            while let self, let scope, let session,
                  approvalSyncs[identity] === record,
                  scope.holds(record.identity, for: session),
                  scope.membership(of: session)?.permitsBindingPreparation == true
            {
                let preparation = await store.prepareSync(scope: address)
                #if DEBUG
                    await test_beforeApprovalSyncCommit?()
                #endif
                guard approvalSyncs[identity] === record,
                      scope.holds(record.identity, for: session),
                      scope.membership(of: session)?.permitsBindingPreparation == true
                else {
                    await store.abandonSync(preparation)
                    return
                }
                guard let subscription = await store.commitSync(
                    preparation, initialValue: initialAutoEdit, replacePayload: replacePayload
                ) else { continue }
                record.lease = subscription.lease
                guard approvalSyncs[identity] === record, scope.holds(record.identity, for: session) else {
                    await store.unsubscribe(scope: address, id: subscription.id)
                    return
                }
                session.applyEditsApprovalSubscriptionID = subscription.id
                installedListener = true
                session.applyEditsApprovalSubscriptionTask = Task { [weak self, weak scope, weak session, weak record] in
                    for await snapshot in subscription.stream {
                        #if DEBUG
                            await self?.test_beforeApprovalSnapshot?()
                        #endif
                        guard !Task.isCancelled, let self, let session, let record,
                              approvalSyncs[identity] === record,
                              scope?.holds(record.identity, for: session) == true,
                              snapshot.syncLease == record.lease else { break }
                        applyApprovalSnapshot(snapshot, to: session)
                    }
                    await store.unsubscribe(scope: address, id: subscription.id)
                    record?.listener = nil
                    if let self, let record, approvalSyncs[identity] === record {
                        session?.applyEditsApprovalSubscriptionID = nil
                        session?.applyEditsApprovalSubscriptionTask = nil
                    }
                }
                record.listener = session.applyEditsApprovalSubscriptionTask
                return
            }
        }
        session.applyEditsApprovalSubscriptionTask = begin
    }

    /// Ensure the admitted session's payload is syncing, then capture its underlying
    /// preference after already-admitted seed, cleanup and manual-write transactions settle.
    /// This may start sync for a newly ready session. The override's apply/release CAS remains the
    /// authority for changes that arrive after this finite preparation transaction.
    func prepareControlAutoEditOverride(
        command: AgentSessionRuntimeStore.Command
    ) async -> ApplyEditsApprovalStore.AutoEditOverride? {
        guard let scope, command.writer.scope === scope, command.isCurrent else { return nil }
        let session = command.writer.session
        ensureApprovalSync(for: session)
        let address = approvalScope(for: session)
        var receipt: ApplyEditsApprovalStore.AutoEditOverride?
        let preparation = enqueueApprovalEffect(for: session) { [approvalStore] in
            guard command.isCurrent else { return }
            receipt = await approvalStore.prepareAutoEditOverride(for: address)
        }
        await preparation.value
        return receipt
    }

    /// Manual UI commands use the canonical writer; only genuine unbound drafts use
    /// membership admission. The no-tab global preference remains a presentation concern.
    @discardableResult
    func setAutoEditEnabled(_ enabled: Bool, for session: AgentTabSession) -> Task<Void, Never>? {
        guard let scope, let membership = scope.membership(of: session), membership.permitsBindingPreparation else { return nil }
        let command: AgentSessionRuntimeStore.Command?
        if session.activeAgentSessionID != nil {
            guard let admitted = try? scope.admit(session: session) else { return nil }
            command = admitted
        } else { command = nil }
        ensureApprovalSync(for: session)
        guard let record = approvalSyncs[ObjectIdentifier(session)] else { return nil }
        let address = approvalScope(for: session)
        let store = approvalStore
        return enqueueApprovalEffect(for: session) { [weak self, weak scope, weak session] in
            #if DEBUG
                await self?.test_beforeAutoEditWrite?()
            #endif
            guard let scope, let session, scope.holds(record.identity, for: session),
                  command?.isCurrent != false, let lease = record.lease else { return }
            _ = await store.setAutoEditEnabled(enabled, for: address, lease: lease, updateGlobalDefault: true)
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
            guard let cutoff else { return false }
            if let membership = cutoff.membership, scope.holds(membership, for: session) {
                return review.admissionTime <= cutoff.instant
            }
            return cutoff.reviewID == review.id
        } == true
        session.pendingApplyEditsReview = cancelled ? nil : snapshot.pendingReview
        Self.reconcileInteractiveRunState(session)
        scope.presentation.makeRunHooks().requestUIRefresh(session, true)
    }

    func teardownApprovalSync(for session: AgentTabSession, cleanupScope: Bool) async {
        let identity = ObjectIdentifier(session)
        let record = approvalSyncs.removeValue(forKey: identity)
        let mayClean = cleanupScope && record.map { record in
            scope?.sessions[session.tabID] == nil || scope?.holds(record.identity, for: session) == true
        } == true
        // Ephemeral session cleanup may already have cleared the compatibility task field.
        // The interaction owner retains the original listener until unsubscribe is joined.
        let task = record?.listener ?? session.applyEditsApprovalSubscriptionTask
        let cutoff = ContinuousClock.now
        task?.cancel()
        session.applyEditsApprovalSubscriptionTask = nil
        session.applyEditsApprovalSubscriptionID = nil
        let store = approvalStore
        let address = approvalScope(for: session)
        // Enqueue before the first await. A successor's begin joins this exact cleanup,
        // and an unrelated runtime's successor lease is independently protected by CAS.
        let cleanup = enqueueApprovalEffect(for: session) { [weak self] in
            #if DEBUG
                self?.test_onApprovalListenerJoin?()
            #endif
            await task?.value
            #if DEBUG
                await self?.test_beforeApprovalSyncCleanup?()
            #endif
            if mayClean, let lease = record?.lease {
                await store.cleanupSync(scope: address, lease: lease, admittedAtOrBefore: cutoff)
            }
        }
        await cleanup.value
        await drainPendingEffects(for: session)
    }

    func cancelPendingApplyEditsReview(for session: AgentTabSession, reason: String) {
        let reviewID = session.pendingApplyEditsReview?.id
        let cutoff = ContinuousClock.now
        cancellationCutoffs = cancellationCutoffs.filter { $0.value.session != nil }
        let membershipAtCutoff = scope?.membership(of: session)
        cancellationCutoffs[ObjectIdentifier(session)] = .init(
            session: session, instant: cutoff, membership: membershipAtCutoff?.identity, reviewID: reviewID
        )
        // This is originating cleanup, not a new command after the suspension. Capture
        // authority now; a detached caller must not acquire it by being re-added later.
        // The store-side cutoff protects all reviews admitted by a subsequent incarnation.
        let ownedScopeAtCutoff = membershipAtCutoff?.isCurrent == true
        session.pendingApplyEditsReview = nil
        let address = approvalScope(for: session)
        let store = approvalStore
        let id = UUID()
        // Retain the exact owner through the admitted store effect. This does not retain a
        // presenter, and a cancelled waiter is not evidence that cancellation has drained.
        let owner = scope
        let task = Task { [self, owner] in
            defer { pendingEffects.removeValue(forKey: id)
                owner?.noteSettlementChanged()
                _ = owner
            }
            #if DEBUG
                await test_beforeApprovalCancellation?()
            #endif
            if ownedScopeAtCutoff {
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

    var hasPendingEffects: Bool {
        !pendingEffects.isEmpty
    }

    func hasPendingEffects(for session: AgentTabSession) -> Bool {
        pendingEffects.values.contains { $0.sessionIdentity == ObjectIdentifier(session) }
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
        questionWaits.removeValue(forKey: ObjectIdentifier(session))
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
        let wait = session.instructionWait
        session.instructionWait = nil
        wait?.timeoutTask?.cancel()
        wait?.timeoutTask = nil
        session.waitingPrompt = nil
        wait?.continuation.resume(throwing: CancellationError())
    }
}
