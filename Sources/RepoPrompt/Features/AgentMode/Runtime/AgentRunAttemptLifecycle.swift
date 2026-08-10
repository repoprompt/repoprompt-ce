import Foundation

// MARK: - App-host run-attempt lifecycle facade

/// Single named owner of one tab-session's transient run-attempt lifecycle and
/// terminal-settlement bookkeeping.
///
/// This type consolidates what used to be a stored field cluster on
/// `AgentTabSession` (run identity, the attempt tracker, provider
/// drain generation, the terminal-commit phase flag, the settled terminal
/// revision/publication result, and exactly-once terminal resources) behind
/// named single-writer operations.
///
/// Authority boundaries:
/// - Canonical durable lifecycle stays owned by `DomainAgentRunSessionStore`;
///   this facade never publishes durable state and never makes settlement
///   decisions.
/// - `AgentRunTerminalCommitBarrier` remains the only settlement driver; the
///   phased terminal-commit operations below exist so the barrier's observable
///   ordering (revision staged before publication resolves; the in-progress
///   flag cleared only after publication and teardown registration) stays
///   representable across its suspension points.
/// - Live tab/session binding remains owned by `AgentTabSession`; binding currency
///   validation composes this facade's attempt check with the session's own
///   binding comparison.
///
/// The facade is provider-neutral and presentation-free: it must not touch
/// transcript, UI, persistence, provider, or MCP state, must not launch tasks,
/// and must not retain the barrier or hooks.
@MainActor
final class AgentRunAttemptLifecycle {
    /// Atomic snapshot of the host-owned values captured when an attempt
    /// begins. Carries no live session or provider references.
    struct AttemptContext {
        let tabID: UUID
        let persistentSessionID: UUID?
        let persistentBindingGeneration: UUID?
        let bindingTransitionGeneration: UInt64
        let turnEpoch: AgentRunTurnEpoch?

        init(
            tabID: UUID,
            persistentSessionID: UUID?,
            persistentBindingGeneration: UUID? = nil,
            bindingTransitionGeneration: UInt64 = 0,
            turnEpoch: AgentRunTurnEpoch? = nil
        ) {
            self.tabID = tabID
            self.persistentSessionID = persistentSessionID
            self.persistentBindingGeneration = persistentBindingGeneration
            self.bindingTransitionGeneration = bindingTransitionGeneration
            self.turnEpoch = turnEpoch
        }
    }

    // MARK: Owned state (externally read-only)

    private var tracker = AgentRunLifecycleTracker()

    /// Provider process run identity for the active or most recent run.
    private(set) var currentRunID: UUID?
    private(set) var providerTerminalDrainGeneration: UInt64 = 0
    private(set) var terminalCommitInProgress = false
    private(set) var lastTerminalCommitRevision: AgentRunTerminalCommitRevision?
    private(set) var lastTerminalPublicationResult: AgentRunTerminalPublicationResult?
    private(set) var terminalResources: AgentRunAttemptTerminalResources?

    var activeOwnership: AgentRunOwnership? {
        tracker.activeOwnership
    }

    var liveness: AgentRunLivenessSnapshot? {
        tracker.liveness
    }

    // MARK: Attempt lifecycle

    /// Begins a new run attempt: resets the transient terminal-settlement state
    /// and starts tracker ownership from the supplied context.
    ///
    /// Intentionally preserves `currentRunID`: the app host installs the fresh
    /// process run identity before beginning the attempt.
    @discardableResult
    func beginAttempt(context: AttemptContext, attemptID: UUID = UUID()) -> AgentRunOwnership {
        assert(
            terminalResources == nil || terminalResources?.isClaimed == true,
            "Beginning a run attempt with unclaimed terminal resources leaks the prior attempt's teardown"
        )
        terminalResources = nil
        terminalCommitInProgress = false
        lastTerminalCommitRevision = nil
        lastTerminalPublicationResult = nil
        providerTerminalDrainGeneration = 0
        return tracker.begin(
            tabID: context.tabID,
            persistentSessionID: context.persistentSessionID,
            persistentBindingGeneration: context.persistentBindingGeneration,
            bindingTransitionGeneration: context.bindingTransitionGeneration,
            attemptID: attemptID,
            turnEpoch: context.turnEpoch
        )
    }

    /// Ends tracker ownership only. Never clears the run ID, terminal revision,
    /// publication result, or terminal resources implicitly.
    @discardableResult
    func endAttempt(ifCurrent ownership: AgentRunOwnership) -> Bool {
        tracker.end(ifCurrent: ownership)
    }

    func isCurrentAttempt(_ ownership: AgentRunOwnership, expectedRunID: UUID? = nil) -> Bool {
        guard activeOwnership == ownership else { return false }
        if let expectedRunID {
            return currentRunID == expectedRunID
        }
        return true
    }

    @discardableResult
    func recordProgress(
        ownership: AgentRunOwnership,
        kind: AgentRunLivenessSignalKind,
        stage: AgentRunLifecycleStage,
        retryIntent: AgentRunRetryIntent = .none,
        timestampUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> AgentRunProgressAcceptance {
        tracker.record(
            ownership: ownership,
            kind: kind,
            stage: stage,
            retryIntent: retryIntent,
            timestampUptimeNanoseconds: timestampUptimeNanoseconds
        )
    }

    @discardableResult
    func acceptProgress(_ signal: AgentRunProgressSignal) -> AgentRunProgressAcceptance {
        tracker.accept(signal)
    }

    // MARK: Run identity

    func installRunID(_ runID: UUID) {
        currentRunID = runID
    }

    /// Clears the run ID only when it still matches the caller's run, so stale
    /// provider cleanup cannot clear a successor run's identity.
    @discardableResult
    func clearRunID(ifCurrent runID: UUID) -> Bool {
        guard currentRunID == runID else { return false }
        currentRunID = nil
        return true
    }

    /// Host-authoritative force reset: unconditionally clears the run ID,
    /// including a successor's. Reserved for teardown paths whose contract is
    /// "no run may survive this transition" (tab/window close, session delete,
    /// provider identity change, workspace switch, execution-location change).
    /// Run-scoped cleanup must use `clearRunID(ifCurrent:)` instead. Callers
    /// reach this through `AgentModeProcessRunIdentity.clearProcessRunID(for:)`.
    func forceClearRunID() {
        currentRunID = nil
    }

    // MARK: Provider terminal drain generation

    func bumpProviderTerminalDrainGeneration() {
        providerTerminalDrainGeneration &+= 1
    }

    // MARK: Terminal resources (exactly-once teardown)

    func installTerminalResources(
        ownership: AgentRunOwnership,
        prepare: @escaping AgentRunAttemptTerminalResources.Prepare
    ) {
        guard isCurrentAttempt(ownership) else { return }
        terminalResources = AgentRunAttemptTerminalResources(
            ownership: ownership,
            prepare: prepare
        )
    }

    /// Claims the installed terminal teardown exactly once for the matching
    /// ownership. A stale-ownership claim attempt leaves the resources
    /// installed for the owning attempt.
    func claimTerminalTeardown(
        ownership: AgentRunOwnership,
        terminalState: AgentSessionRunState
    ) -> AgentRunAttemptTerminalResources.Teardown? {
        guard let resources = terminalResources else { return nil }
        let teardown = resources.claim(for: ownership, terminalState: terminalState)
        if resources.isClaimed {
            terminalResources = nil
        }
        return teardown
    }

    // MARK: Phased terminal commit

    // The terminal commit is not one operation: a revision becomes visible
    // before canonical publication resolves, and the in-progress flag clears
    // only after publication and teardown registration. The phases below map
    // one-to-one onto the barrier's existing mutation points and must not be
    // collapsed.

    /// Acquires the terminal-commit phase. Returns `false` when a commit is
    /// already in progress.
    @discardableResult
    func beginTerminalCommit() -> Bool {
        guard !terminalCommitInProgress else { return false }
        terminalCommitInProgress = true
        return true
    }

    /// Releases the phase after a post-acquisition validation failure without
    /// touching the staged revision or publication result.
    func abortTerminalCommit() {
        terminalCommitInProgress = false
    }

    /// Stores the settled revision and clears the prior publication result.
    /// Does not end the terminal-commit phase.
    func stageTerminalRevision(_ revision: AgentRunTerminalCommitRevision) {
        lastTerminalCommitRevision = revision
        lastTerminalPublicationResult = nil
    }

    /// Records the canonical publication result. Intentionally unguarded: a
    /// duplicate-commit retry records a result while no terminal commit is in
    /// progress, and a binding transition may clear the revision while
    /// publication is suspended.
    func recordTerminalPublicationResult(_ result: AgentRunTerminalPublicationResult) {
        lastTerminalPublicationResult = result
    }

    /// Ends the terminal-commit phase, preserving revision and result.
    func completeTerminalCommit() {
        terminalCommitInProgress = false
    }

    /// A rebind must not carry the runtime-only terminal classification or
    /// publication result into another session. Clears only the revision and
    /// result; ownership, run ID, drain generation, and any active
    /// terminal-commit phase are preserved.
    func invalidateTerminalRevisionForBindingTransition() {
        lastTerminalCommitRevision = nil
        lastTerminalPublicationResult = nil
    }
}
