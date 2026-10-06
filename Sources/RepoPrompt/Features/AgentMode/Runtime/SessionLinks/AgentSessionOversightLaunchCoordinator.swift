import Foundation
import RepoPromptDomainRuntime
import RepoPromptInstrumentation

// Restores durable oversight intents into live links after launch and window restore.
//
// Owns the restore topology state, the terminal reasons a restore can end with, and the coordinator
// that waits on `AgentSessionLinkEndpointResolver` readiness for both endpoints before asking
// `AgentSessionLinkRuntimeBridge` to recreate each link; `AgentSessionOversightIntentStore` is its
// source and `AgentSessionDeletionRegistry` tells it which sessions are gone for good. Invariants:
// an intent is replayed against exact restoration-ready incarnations only, never against a UUID
// match alone; restore never starts a run, publishes prompt inventory, or arms an Auto-wake by
// itself — the bootstrap after restore goes through the ordinary publication path. The only
// hydration it causes is a passive transcript load of the background tabs a saved pair
// is actually waiting on, so saved oversight comes back at launch instead of only after the user
// happens to open every endpoint's tab.

// MARK: - Restore topology

/// Why the window-restore gate became idle.
///
/// The gate's idle edge is ambiguous by construction: it can mean *every* restore entry was claimed
/// by a window, or that leftover entries were abandoned after the grace period because their windows
/// never re-registered. Only the first proves the expected window topology was actually observed, so
/// only the first lets an absent session be classified as permanently gone.
enum AgentSessionOversightRestoreTopologyState: Equatable {
    /// Restore is still loading or applying.
    case pending
    /// Every restore entry was claimed. Absence after discovery settles is a fact.
    case completeAllEntriesConsumed
    /// Leftover entries were abandoned. Absence is uncertain and must not terminate an intent.
    case incompleteLeftoversAbandoned(count: Int)
    /// Window restoration is turned off. The manifest still loads; no automatic epoch starts.
    case dormantAutoRestoreDisabled
    /// Deterministic or persistence-suppressed launch.
    case suppressed

    /// Whether an automatic launch pass may run at all.
    var admitsAutomaticRestore: Bool {
        switch self {
        case .completeAllEntriesConsumed, .incompleteLeftoversAbandoned:
            true
        case .pending, .dormantAutoRestoreDisabled, .suppressed:
            false
        }
    }

    /// Whether a missing descriptor is a *definitive* fact rather than a window that never came back.
    var provesAbsence: Bool {
        self == .completeAllEntriesConsumed
    }

    /// Enum-like label for diagnostics. The abandoned count travels as its own numeric field.
    var diagnosticLabel: String {
        switch self {
        case .pending: "pending"
        case .completeAllEntriesConsumed: "all_consumed"
        case .incompleteLeftoversAbandoned: "leftovers_abandoned"
        case .dormantAutoRestoreDisabled: "dormant"
        case .suppressed: "suppressed"
        }
    }

    /// How many restore entries the grace valve gave up on, for diagnostics only.
    var abandonedEntryCount: Int {
        if case let .incompleteLeftoversAbandoned(count) = self { return count }
        return 0
    }
}

// MARK: - Terminal reasons

/// Why one automatic launch entry stopped being reauthorizable this launch.
///
/// Diagnostics only: these are enum-like outcome labels, never rendered with a session name or UUID.
enum AgentSessionOversightLaunchTerminalReason: String, Equatable {
    /// The saved UUID resolves to more than one live incarnation, so neither may be granted.
    case ambiguousDuplicate = "ambiguous_duplicate"
    /// No descriptor and no candidate, under a topology that proves absence.
    case missing
    /// Binding-qualified hydration proof came back terminal.
    case hydrationFailed = "hydration_failed"
    /// Child session, closing endpoint, or permanent observer policy denial.
    case ineligible
    /// The endpoint incarnation this entry was granted against no longer exists.
    case bindingDrift = "binding_drift"
    /// A committed deletion tombstone covers one of the endpoints.
    case deleted
    /// The shared establishment path refused for a non-shutdown reason.
    case activationFailed = "activation_failed"
    /// Lifecycle revoked the restored grant; only exact captured window-close ownership may requeue.
    case lifecycleRevoked = "lifecycle_revoked"
}

// MARK: - Delegate

/// The narrow slice of the bridge the coordinator drives.
///
/// A protocol rather than closures so the whole pass algorithm can be exercised without an authority,
/// a store, or a window — and so the coordinator can never reach past these five operations into
/// authority state it has no business touching.
@MainActor
protocol AgentSessionOversightLaunchCoordinatorDelegate: AnyObject {
    var launchCoordinatorHost: AgentSessionLinkEndpointHost? { get }
    /// Termination freeze. A frozen process makes no new missing classification and performs no
    /// cleanup, so grace-uncertain and lazy entries stay durable for the next launch.
    var launchCoordinatorIsFrozen: Bool { get }

    /// The one shared fresh-establishment path. Restoration never reconstructs a grant itself.
    ///
    /// - Parameter proof: the binding-qualified hydration proof this entry was classified against.
    ///   It travels *through* the shared path rather than being re-derived inside it, because the
    ///   resolver there deliberately gates on the legacy `hasLoadedPersistedState` latch.
    func launchCoordinatorEstablish(
        pair: AgentSessionOversightIntent,
        token: AgentSessionOversightIntentToken?,
        assertedAt generation: UInt64?,
        proof: AgentSessionOversightRestorationProof?
    ) async -> AgentSessionLinkRuntimeBridge.EstablishmentResult

    /// Expected-token removal, taken in the pair's retirement lane.
    ///
    /// A stale token can never delete an intent a newer re-add reasserted, and the lane additionally
    /// stops a cleanup already suspended on the store actor from committing after an explicit Add
    /// reused the exact token it holds.
    func launchCoordinatorRemoveIntent(
        pair: AgentSessionOversightIntent,
        token: AgentSessionOversightIntentToken,
        assertedAt generation: UInt64?
    ) async -> AgentSessionOversightIntentMutationReceipt

    /// Revokes one exact restored grant generation. Used only by the active-entry audit, which never
    /// requeues the entry afterwards.
    func launchCoordinatorRevoke(reference: DomainAgentSessionLinkReference) async

    /// Reports an aggregate, identifier-free warning for the persistence surface.
    func launchCoordinatorReportWarning(id: String, message: String)

    /// Asks the host to passively load the persisted state of these described-but-unhydrated
    /// sessions, so a waiting launch entry can reach restoration readiness without the user opening
    /// each tab. Fire-and-forget: readiness changes re-enter the pass through the ordinary signal.
    func launchCoordinatorRequestHydration(sessionIDs: Set<UUID>)
}

// MARK: - Coordinator

/// Reauthorizes launch-loaded and exact close-captured oversight intent after every barrier.
///
/// Three properties define it:
///
/// - It is *bounded*: launch-loaded pairs and reference-backed pairs captured at window close enter
///   the worklist. Other interactive pairs remain owned by the ordinary interactive path.
/// - It is *reason-aware*: it distinguishes "the window topology we expected was fully observed" from
///   "we gave up waiting", and only the former lets an absent session be classified as gone.
/// - It is *not a controller*: one MainActor task drains events, without timers or polling.
///   Described background endpoints receive bounded passive hydration requests.
///
/// Each automatic entry may reserve once, with one fresh allowance per exact captured window close.
/// Other lifecycle revocation ends the entry permanently; no-reference waiting pairs are not rearmed.
@MainActor
final class AgentSessionOversightLaunchCoordinator {
    private var restorePerfRecorder: any WorkspaceRestorePerfRecording

    func installRestorePerfRecorder(_ recorder: any WorkspaceRestorePerfRecording) {
        restorePerfRecorder = recorder
    }

    // MARK: Entry state

    enum EntryState: Equatable {
        /// Waiting on topology, discovery, lazy binding hydration, or readiness.
        case waiting
        /// Inside the shared establishment path.
        case establishing
        /// A live restored grant.
        case active
        /// Terminal, and its durable removal could not be written. Retried only on the permitted
        /// triggers, never by an ordinary topology event.
        case cleanupPending(AgentSessionOversightIntentToken)
        case terminal(AgentSessionOversightLaunchTerminalReason)
    }

    private struct Entry {
        let pair: AgentSessionOversightIntent
        var token: AgentSessionOversightIntentToken?
        var state: EntryState = .waiting
        /// Once true, no automatic retry is allowed unless exact window-close ownership rearms it.
        var didStartReservation = false
        /// Sessions this launch has actually seen described or live at least once.
        ///
        /// A session that was observed and then disappeared is a *positive* fact about this process,
        /// unlike a session that was never there: it survives an uncertain restore topology, which is
        /// what lets an ordinary close of a waiting, never-granted pair end the saved relationship
        /// instead of leaving it to reactivate later.
        var observedSessions: Set<UUID> = []
        /// The exact incarnations and grant generation this entry was activated against.
        ///
        /// Without them an active entry could never be re-audited: a late duplicate, a target that
        /// became a child or started closing, a permanent observer-policy loss, and observed binding
        /// drift are all invisible to a check that only knows the session UUIDs.
        var observerEndpoint: DomainAgentSessionLinkEndpointIdentity?
        var targetEndpoint: DomainAgentSessionLinkEndpointIdentity?
        var reference: DomainAgentSessionLinkReference?
        /// The pair's assertion generation this entry belongs to.
        ///
        /// Launch-loaded rows start at zero: they were restored, not asserted by anyone in this
        /// process. An explicit Add bumps it, which is what makes a retirement decided before that
        /// Add compare out instead of deleting what the user just recreated.
        var assertionGeneration: UInt64 = 0
        /// Non-nil rearms restoration; only this capture may authorize a pre-close Unlink.
        var parkedReference: DomainAgentSessionLinkReference?
        /// Retained after relink to fence delayed cleanup of a predecessor under the same token.
        var closedReferences: Set<DomainAgentSessionLinkReference> = []
        #if DEBUG
            /// A waiting entry is re-evaluated on every event, so its "still waiting" diagnostic is
            /// reported once per entry rather than once per pass.
            var didLogWaiting = false
        #endif
    }

    // MARK: State

    private weak var delegate: (any AgentSessionOversightLaunchCoordinatorDelegate)?
    /// Stable, serial pair order; extended only by exact close capture.
    private var launchPairOrder: [AgentSessionOversightIntent] = []
    private var entries: [AgentSessionOversightIntent: Entry] = [:]

    private var topology: AgentSessionOversightRestoreTopologyState = .pending
    private var automaticRestoreEnabled = false
    private var storeIsReady = false
    private var isFrozen = false
    private var didLoadLaunchEntries = false
    private var didReportTerminalSummary = false

    private var isDirty = false
    private var drainTask: Task<Void, Never>?

    init(
        delegate: (any AgentSessionOversightLaunchCoordinatorDelegate)? = nil,
        restorePerfRecorder: any WorkspaceRestorePerfRecording = NoopWorkspaceRestorePerfRecorder()
    ) {
        self.delegate = delegate
        self.restorePerfRecorder = restorePerfRecorder
    }

    func attach(delegate: any AgentSessionOversightLaunchCoordinatorDelegate) {
        self.delegate = delegate
    }

    // MARK: Inputs

    /// Installs the fixed launch worklist from the one and only ready load.
    ///
    /// Idempotent: a second load (a repeated bootstrap, an attach after the first) must not resurrect
    /// entries this launch already terminalized.
    func loadLaunchEntries(
        _ load: AgentSessionOversightIntentReadyLoad,
        automaticRestoreEnabled: Bool
    ) {
        storeIsReady = true
        self.automaticRestoreEnabled = automaticRestoreEnabled
        guard automaticRestoreEnabled, !didLoadLaunchEntries else {
            markDirty()
            return
        }
        didLoadLaunchEntries = true
        let ordered = load.tokenByPair.keys.sorted(by: AgentSessionOversightIntent.canonicallyOrdered)
        for pair in ordered where entries[pair] == nil {
            launchPairOrder.append(pair)
            entries[pair] = Entry(pair: pair, token: load.tokenByPair[pair])
        }
        markDirty()
    }

    func updateTopologyState(_ state: AgentSessionOversightRestoreTopologyState) {
        guard topology != state else { return }
        topology = state
        #if DEBUG
            restorePerfRecorder.event(
                "oversight.topology",
                fields: [
                    "state": state.diagnosticLabel,
                    "abandonedEntries": String(state.abandonedEntryCount),
                    "launchPairs": String(launchPairOrder.count)
                ]
            )
        #endif
        markDirty()
    }

    var currentTopologyState: AgentSessionOversightRestoreTopologyState {
        topology
    }

    /// The one reconciliation trigger. Every event funnels here; none of them carries authority.
    func markDirty() {
        guard !isFrozen else { return }
        isDirty = true
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            while let self, isDirty, !isFrozen {
                isDirty = false
                await performPass()
            }
            self?.drainTask = nil
        }
    }

    /// Waits for the currently queued reconciliation to settle. Test and shutdown seam only.
    func settle() async {
        while let task = drainTask {
            await task.value
            if drainTask == task { break }
        }
    }

    // MARK: Interactive and lifecycle notifications

    /// A user Add or Stop changed this pair's durable token.
    ///
    /// A launch entry whose pair the user just acted on is handed to the interactive path, and its
    /// at-most-once budget no longer constrains that explicit work.
    ///
    /// Crucially this also *retires any pending cleanup* for the pair. A user who explicitly re-adds
    /// a pair whose automatic cleanup failed has reasserted it; leaving the failed cleanup queued
    /// would let **Retry saving** later delete the intent they just recreated.
    func noteInteractiveTokenChange(
        pair: AgentSessionOversightIntent,
        token: AgentSessionOversightIntentToken?,
        assertedAt generation: UInt64?
    ) {
        guard var entry = entries[pair] else { return }
        entry.token = token
        entry.parkedReference = nil
        entry.closedReferences.removeAll()
        if let generation { entry.assertionGeneration = generation }
        entry.state = token == nil ? .terminal(.lifecycleRevoked) : .active
        // The interactive path owns this pair from here, so the automatic entry stops carrying an
        // incarnation to audit: a user Add is explicit work, not a launch entry whose grant this
        // coordinator may later revoke on its own initiative.
        entry.observerEndpoint = nil
        entry.targetEndpoint = nil
        entry.reference = nil
        entries[pair] = entry
        markDirty()
    }

    /// Runtime authority revoked a restored grant. Never requeued.
    ///
    /// Durable removal is the bridge's job — it captured `(reference, pair, token)` before the
    /// authority call and can compare-remove exactly its own token. This only records that the entry
    /// is finished for the rest of the launch.
    func noteRevocation(
        pair: AgentSessionOversightIntent,
        assertedAt generation: UInt64?,
        preservesIntent: Bool
    ) {
        guard var entry = entries[pair] else { return }
        guard !preservesIntent else { return }
        // A lifecycle owner captures this before its authority hop. An explicit Add can reassert the
        // same durable token while that hop is suspended, so token equality alone cannot authorize
        // terminalizing the newer interactive entry.
        guard generation.map({ $0 == entry.assertionGeneration }) ?? true else { return }
        entry.token = nil
        entry.reference = nil
        entry.parkedReference = nil
        entry.closedReferences.removeAll()
        // An audit that already recorded *why* this entry ended keeps its reason: the revocation it
        // triggered is the consequence, not the diagnosis.
        if case .terminal = entry.state {} else {
            entry.state = .terminal(.lifecycleRevoked)
        }
        entries[pair] = entry
    }

    /// Capture exact saved ownership synchronously, before close hides either endpoint.
    func noteWindowClose(
        pair: AgentSessionOversightIntent,
        token: AgentSessionOversightIntentToken,
        assertedAt generation: UInt64,
        reference: DomainAgentSessionLinkReference
    ) {
        guard !isFrozen else { return }
        var entry = entries[pair] ?? Entry(pair: pair, token: token)
        guard entry.token == token, entry.assertionGeneration <= generation else { return }
        if case .cleanupPending = entry.state { return }
        if entry.assertionGeneration != generation {
            entry.closedReferences.removeAll()
        }
        // Historical cleanup ownership cannot replace the successor's current parked owner.
        if entry.closedReferences.contains(reference), entry.parkedReference != reference { return }
        entry.assertionGeneration = generation
        entry.parkedReference = reference
        entry.closedReferences.insert(reference)
        entry.state = .terminal(.lifecycleRevoked)
        entry.reference = nil
        entry.observerEndpoint = nil
        entry.targetEndpoint = nil
        entries[pair] = entry
        if !launchPairOrder.contains(pair) { launchPairOrder.append(pair) }
        markDirty()
    }

    func permitsCloseRetirement(
        _ reference: DomainAgentSessionLinkReference,
        pair: AgentSessionOversightIntent,
        token: AgentSessionOversightIntentToken?,
        assertedAt generation: UInt64?
    ) -> Bool {
        entries[pair]?.parkedReference == reference
            && preservesClosedReference(reference, pair: pair, token: token, assertedAt: generation)
    }

    func preservesClosedReference(
        _ reference: DomainAgentSessionLinkReference,
        pair: AgentSessionOversightIntent,
        token: AgentSessionOversightIntentToken?,
        assertedAt generation: UInt64?
    ) -> Bool {
        guard let entry = entries[pair] else { return false }
        return entry.token == token && entry.assertionGeneration == generation
            && entry.closedReferences.contains(reference)
    }

    func permitsRemoval(pair: AgentSessionOversightIntent, token: AgentSessionOversightIntentToken) -> Bool {
        guard let entry = entries[pair], entry.token == token, entry.parkedReference == nil else { return false }
        switch entry.state {
        case .terminal, .cleanupPending: return true
        default: return false
        }
    }

    /// A window, tab, workspace, or binding teardown covering these sessions.
    ///
    /// Deliberately only a wake-up. A waiting entry holds no grant, so no authority notice ever
    /// mentions it and `settleDurableIntent` has nothing to remove — but only the reconciliation
    /// pass can read the resulting descriptor/candidate topology and tell an ordinary close apart
    /// from an in-place rebind, so the decision stays there.
    func noteLifecycleEnded(sessionIDs: Set<UUID>) {
        guard !isFrozen, !sessionIDs.isEmpty else { return }
        guard launchPairOrder.contains(where: {
            sessionIDs.contains($0.observerSessionID) || sessionIDs.contains($0.targetSessionID)
        }) else {
            return
        }
        markDirty()
    }

    /// Records a cleanup whose durable removal could not be written.
    func noteCleanupPending(
        pair: AgentSessionOversightIntent,
        token: AgentSessionOversightIntentToken,
        assertedAt generation: UInt64?
    ) {
        var entry = entries[pair] ?? Entry(pair: pair, token: token)
        guard generation.map({ $0 >= entry.assertionGeneration }) ?? true else { return }
        entry.token = token
        entry.parkedReference = nil
        entry.closedReferences.removeAll()
        if let generation { entry.assertionGeneration = generation }
        entry.state = .cleanupPending(token)
        entries[pair] = entry
        if !launchPairOrder.contains(pair) { launchPairOrder.append(pair) }
    }

    var hasPendingCleanup: Bool {
        entries.values.contains { if case .cleanupPending = $0.state { true } else { false } }
    }

    /// One of the few permitted cleanup retry triggers. Ordinary topology events never reach here.
    ///
    /// - Parameter ignoringFreeze: `true` only for the single bounded retry the termination sequence
    ///   performs inside its total deadline. It admits no new work: every entry it walks already owed
    ///   this exact expected-token write before the freeze.
    func retryPendingCleanup(ignoringFreeze: Bool = false) async {
        guard let delegate else { return }
        guard ignoringFreeze || (!isFrozen && !delegate.launchCoordinatorIsFrozen) else { return }
        #if DEBUG
            let attempted = pendingCleanupCount
        #endif
        for pair in launchPairOrder {
            guard case let .cleanupPending(token) = entries[pair]?.state,
                  let assertion = entries[pair]?.assertionGeneration
            else {
                continue
            }
            let receipt = await delegate.launchCoordinatorRemoveIntent(
                pair: pair,
                token: token,
                assertedAt: assertion
            )
            guard var entry = entries[pair],
                  case .cleanupPending = entry.state,
                  entry.assertionGeneration == assertion
            else {
                continue
            }
            switch receipt.outcome {
            case .applied, .unchanged, .absent:
                entry.state = .terminal(.lifecycleRevoked)
                entry.token = nil
                entry.parkedReference = nil
                entry.closedReferences.removeAll()
                entries[pair] = entry
            case .tokenMismatch:
                // A newer same-token assertion compared this retry out. Its interactive notification
                // normally replaced the entry already; if it has not arrived yet, leave this cleanup
                // pending rather than terminalizing the newer intent.
                guard receipt.assertionGeneration == assertion else { continue }
                entry.state = .terminal(.lifecycleRevoked)
                entry.token = nil
                entry.parkedReference = nil
                entry.closedReferences.removeAll()
                entries[pair] = entry
            case .writeFailed, .blocked:
                continue
            }
        }
        #if DEBUG
            let stillPending = pendingCleanupCount
            restorePerfRecorder.event(
                "oversight.cleanupRetry",
                fields: [
                    "attempted": String(attempted),
                    "cleared": String(attempted - stillPending),
                    "stillPending": String(stillPending)
                ]
            )
        #endif
    }

    /// Synchronous termination freeze: no new classification, no cleanup, no reservation.
    func freeze() {
        isFrozen = true
        isDirty = false
        drainTask?.cancel()
        drainTask = nil
    }

    // MARK: Diagnostics

    #if DEBUG
        /// Reported once per pending episode. Every candidate-readiness and topology event re-enters
        /// the pass, so an un-deduplicated "still waiting on discovery" line would drown the log.
        private var didLogDiscoveryPending = false

        private var pendingCleanupCount: Int {
            entries.values.count { if case .cleanupPending = $0.state { true } else { false } }
        }

        private func logDiscoveryPendingOnce(_ discovery: [AgentSessionLinkDiscoveryState]) {
            guard !launchPairOrder.isEmpty, !didLogDiscoveryPending else { return }
            didLogDiscoveryPending = true
            restorePerfRecorder.event(
                "oversight.discovery",
                fields: [
                    "state": "pending",
                    "windows": String(discovery.count),
                    "complete": String(discovery.count(where: \.isComplete))
                ]
            )
        }

        private func logWaitingOnce(pair: AgentSessionOversightIntent) {
            guard var entry = entries[pair], !entry.didLogWaiting else { return }
            entry.didLogWaiting = true
            entries[pair] = entry
            logReconcile(pair: pair, outcome: "waiting")
        }

        /// Endpoints are reported as truncated identifier prefixes, exactly as window restore reports
        /// workspaces. A full session UUID is an addressable oversight endpoint and is never logged;
        /// names, transcript content, and worktree paths never reach this surface at all.
        private func logReconcile(
            pair: AgentSessionOversightIntent,
            outcome: String,
            reason: String? = nil
        ) {
            var fields = [
                "outcome": outcome,
                "observer": restorePerfRecorder.shortID(pair.observerSessionID),
                "target": restorePerfRecorder.shortID(pair.targetSessionID)
            ]
            if let reason { fields["reason"] = reason }
            restorePerfRecorder.event("oversight.reconcile", fields: fields)
        }
    #endif

    // MARK: Introspection (diagnostics and tests)

    func state(for pair: AgentSessionOversightIntent) -> EntryState? {
        entries[pair]?.state
    }

    var reservationStartCount: Int {
        entries.values.count { $0.didStartReservation }
    }

    // MARK: Pass

    /// One reconciliation pass over the launch-loaded and close-captured worklist.
    ///
    /// Barriers first, and all of them: a ready store, a host, a non-pending outer topology, and a
    /// *complete current* discovery level for every registered window. Reserving before any of these
    /// would either grant against a half-built window or misclassify a session that simply has not
    /// been described yet.
    private func performPass() async {
        guard !isFrozen,
              storeIsReady,
              automaticRestoreEnabled,
              topology.admitsAutomaticRestore,
              let delegate,
              // The bridge's freeze is authoritative as well as this coordinator's own: a coordinator
              // created or seeded while a bootstrap was suspended can reach here after the process
              // already froze, and nothing automatic may run then.
              !delegate.launchCoordinatorIsFrozen,
              let host = delegate.launchCoordinatorHost
        else {
            return
        }
        let discovery = host.agentSessionLinkDiscoveryStates()
        // An empty set means no window has registered a level yet — that is "not described", not
        // "nothing to describe".
        guard !discovery.isEmpty, discovery.allSatisfy(\.isComplete) else {
            #if DEBUG
                logDiscoveryPendingOnce(discovery)
            #endif
            return
        }
        #if DEBUG
            didLogDiscoveryPending = false
        #endif

        let descriptors = host.agentSessionLinkComposeTabDescriptors()
        let candidates = host.agentSessionLinkCandidates()
        var descriptorCounts: [UUID: Int] = [:]
        for descriptor in descriptors {
            descriptorCounts[descriptor.sessionID, default: 0] += 1
        }
        var candidatesBySession: [UUID: [AgentSessionLinkEndpointCandidate]] = [:]
        for candidate in candidates {
            candidatesBySession[candidate.sessionID, default: []].append(candidate)
        }

        requestHydrationForWaitingEntries(
            descriptorCounts: descriptorCounts,
            candidatesBySession: candidatesBySession
        )

        for pair in launchPairOrder {
            guard !isFrozen, !isDirty else { return }
            guard var entry = entries[pair] else { continue }
            if entry.parkedReference != nil {
                let sessions = [pair.observerSessionID, pair.targetSessionID]
                guard sessions.allSatisfy({ sessionID in
                    (descriptorCounts[sessionID] ?? 0) == 1
                        && (candidatesBySession[sessionID] ?? []).count == 1
                        && candidatesBySession[sessionID]?.first?.isClosing == false
                        && !AgentSessionDeletionRegistry.shared.blocksNewOversight(sessionID: sessionID)
                }) else { continue }
                // Classify without consuming parking: a present candidate may still be hydrating.
                entry.state = .waiting
            }
            switch entry.state {
            case .waiting:
                let disposition = classify(
                    pair: pair,
                    descriptorCounts: descriptorCounts,
                    candidatesBySession: candidatesBySession
                )
                if case .wait = disposition {
                    #if DEBUG
                        logWaitingOnce(pair: pair)
                    #endif
                    continue
                }
                if entry.parkedReference != nil, var current = entries[pair] {
                    current.parkedReference = nil
                    current.didStartReservation = false
                    current.state = .waiting
                    entries[pair] = current
                }
                switch disposition {
                case .wait:
                    continue
                case let .terminal(reason):
                    await retire(pair: pair, reason: reason)
                case let .establish(proof):
                    #if DEBUG
                        logReconcile(pair: pair, outcome: "ready")
                    #endif
                    await establish(pair: pair, proof: proof)
                }
            case .active:
                // Restored grants are re-audited on every candidate/topology event. A late duplicate,
                // a target that became a child or started closing, a permanent observer-policy loss,
                // and drift of the exact incarnation the grant was issued against all end the entry.
                // Only synchronous window-close capture can preserve and rearm exact saved ownership.
                await auditActiveEntry(
                    pair: pair,
                    descriptorCounts: descriptorCounts,
                    candidatesBySession: candidatesBySession
                )
            case .establishing, .cleanupPending, .terminal:
                continue
            }
        }
    }

    /// Requests a passive load for every endpoint a waiting entry is blocked on only because its
    /// background tab has not been hydrated yet.
    ///
    /// Bounded to saved endpoints after restore barriers clear; the host deduplicates loads.
    /// Undescribed, ambiguous, or deleted sessions are left alone:
    /// hydration could not make it restorable, and classification decides its fate as before.
    private func requestHydrationForWaitingEntries(
        descriptorCounts: [UUID: Int],
        candidatesBySession: [UUID: [AgentSessionLinkEndpointCandidate]]
    ) {
        guard let delegate else { return }
        let registry = AgentSessionDeletionRegistry.shared
        var requested: Set<UUID> = []
        for pair in launchPairOrder {
            guard entries[pair]?.state == .waiting || entries[pair]?.parkedReference != nil else { continue }
            for sessionID in [pair.observerSessionID, pair.targetSessionID] {
                guard !registry.isPermanentlyDeleted(sessionID: sessionID),
                      !registry.isDeletionInProgress(sessionID: sessionID),
                      (descriptorCounts[sessionID] ?? 0) == 1
                else {
                    continue
                }
                let matches = candidatesBySession[sessionID] ?? []
                let needsHydration = switch matches.count {
                case 0:
                    true
                case 1:
                    switch matches[0].restorationReadiness {
                    case .pending, .unbound: true
                    case .authoritative, .terminal: false
                    }
                default:
                    false
                }
                if needsHydration { requested.insert(sessionID) }
            }
        }
        guard !requested.isEmpty else { return }
        #if DEBUG
            restorePerfRecorder.event(
                "oversight.hydrationRequested",
                fields: ["sessions": String(requested.count)]
            )
        #endif
        delegate.launchCoordinatorRequestHydration(sessionIDs: requested)
    }

    private enum Disposition {
        case wait
        case terminal(AgentSessionOversightLaunchTerminalReason)
        case establish(AgentSessionOversightRestorationProof)
    }

    /// Decision for one waiting pair. Both endpoints must clear every rule.
    ///
    /// Records which endpoints this launch has actually seen, which is what turns a later
    /// disappearance into a positive fact rather than the uncertainty an abandoned restore topology
    /// otherwise implies.
    private func classify(
        pair: AgentSessionOversightIntent,
        descriptorCounts: [UUID: Int],
        candidatesBySession: [UUID: [AgentSessionLinkEndpointCandidate]]
    ) -> Disposition {
        var resolved: [UUID: AgentSessionLinkEndpointCandidate] = [:]
        for sessionID in [pair.observerSessionID, pair.targetSessionID] {
            let descriptorCount = descriptorCounts[sessionID] ?? 0
            let matches = candidatesBySession[sessionID] ?? []

            // Deletion state outranks topology. A committed tombstone is permanent even after its
            // candidate disappeared; an in-progress attempt is reversible and therefore waits even
            // when the ordinary topology would otherwise prove absence.
            if AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: sessionID) {
                return .terminal(.deleted)
            }
            if AgentSessionDeletionRegistry.shared.isDeletionInProgress(sessionID: sessionID) {
                return .wait
            }

            // A duplicate is a *positive* fact even under an uncertain topology: two live
            // incarnations of one UUID mean neither may be granted, exactly as manual Add refuses.
            if descriptorCount > 1 || matches.count > 1 { return .terminal(.ambiguousDuplicate) }

            if descriptorCount == 0, matches.isEmpty {
                // An endpoint this launch already observed and then watched disappear is a fact about
                // *this* process, not the uncertainty an abandoned restore leftover represents: the
                // tab, window, or workspace holding it was torn down while we were looking. That ends
                // the saved relationship exactly as an ordinary close does.
                if entries[pair]?.observedSessions.contains(sessionID) == true {
                    return .terminal(.bindingDrift)
                }
                // Otherwise absence is only terminal when the topology proves the expected windows
                // were all observed. The entry waits — possibly for the whole process lifetime —
                // rather than deleting an intent whose window may simply never have come back.
                return topology.provesAbsence ? .terminal(.missing) : .wait
            }
            noteObserved(pair: pair, sessionID: sessionID)

            // A described-but-unhydrated background tab. Waiting here is the entire reason
            // descriptors exist: restoration must never force-hydrate a lazy tab.
            guard let candidate = matches.first else { continue }

            // Candidate construction carries the same transient marker for UI eligibility. Keep the
            // registry check above as the authority because it closes the gap before candidates update.
            if candidate.isDeletionInProgress { return .wait }
            if !candidate.isTopLevel { return .terminal(.ineligible) }
            if candidate.isClosing { return .terminal(.ineligible) }
            if sessionID == pair.observerSessionID, !candidate.roleAllowsOutboundMonitoring {
                return .terminal(.ineligible)
            }
            if sessionID == pair.observerSessionID, candidate.isMCPControlled || candidate.isMCPOriginated {
                return .terminal(.ineligible)
            }

            switch candidate.restorationReadiness {
            case .authoritative:
                resolved[sessionID] = candidate
            case let .terminal(_, failure):
                switch failure {
                case .missingPayload:
                    return .terminal(.hydrationFailed)
                case .loadFailed, .sourceRevisionSuperseded:
                    // A failed or superseded load proves no authority, not that the saved intent is gone.
                    // Still inspect the other endpoint for a proven terminal reason.
                    continue
                }
            case .pending, .unbound:
                return .wait
            }
        }
        guard let observer = resolved[pair.observerSessionID],
              let target = resolved[pair.targetSessionID],
              let proof = AgentSessionOversightRestorationProof(observer: observer, target: target)
        else {
            return .wait
        }
        return .establish(proof)
    }

    private func noteObserved(pair: AgentSessionOversightIntent, sessionID: UUID) {
        guard var entry = entries[pair], !entry.observedSessions.contains(sessionID) else { return }
        entry.observedSessions.insert(sessionID)
        entries[pair] = entry
    }

    /// Why one *active* restored entry may no longer keep its grant, or `nil` when it still may.
    ///
    /// Everything here is a permanent fact. Transient states are deliberately absent: revoking a
    /// healthy restored link because its target is momentarily rebinding would destroy exactly the
    /// relationship this feature exists to keep.
    private func activeAuditFailure(
        pair: AgentSessionOversightIntent,
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
        descriptorCounts: [UUID: Int],
        candidatesBySession: [UUID: [AgentSessionLinkEndpointCandidate]]
    ) -> AgentSessionOversightLaunchTerminalReason? {
        // Committed wins even when the other endpoint is transiently deleting. Returning early for
        // `.inProgress` would otherwise skip a committed tombstone on the second endpoint.
        for sessionID in [pair.observerSessionID, pair.targetSessionID]
            where AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: sessionID)
        {
            return .deleted
        }
        if [pair.observerSessionID, pair.targetSessionID].contains(where: {
            AgentSessionDeletionRegistry.shared.isDeletionInProgress(sessionID: $0)
        }) {
            return nil
        }
        for sessionID in [pair.observerSessionID, pair.targetSessionID] {
            let matches = candidatesBySession[sessionID] ?? []
            if (descriptorCounts[sessionID] ?? 0) > 1 || matches.count > 1 {
                return .ambiguousDuplicate
            }
        }
        guard let observer = (candidatesBySession[pair.observerSessionID] ?? [])
            .first(where: { $0.domainEndpoint == observerEndpoint }),
            let target = (candidatesBySession[pair.targetSessionID] ?? [])
            .first(where: { $0.domainEndpoint == targetEndpoint })
        else {
            return .bindingDrift
        }
        if !observer.isTopLevel || observer.isClosing { return .ineligible }
        if !observer.roleAllowsOutboundMonitoring || observer.isMCPControlled || observer.isMCPOriginated {
            return .ineligible
        }
        if !target.isTopLevel || target.isClosing { return .ineligible }
        return nil
    }

    /// Re-audits one active restored entry, revoking the **exact** generation it was granted.
    private func auditActiveEntry(
        pair: AgentSessionOversightIntent,
        descriptorCounts: [UUID: Int],
        candidatesBySession: [UUID: [AgentSessionLinkEndpointCandidate]]
    ) async {
        guard let entry = entries[pair],
              let observerEndpoint = entry.observerEndpoint,
              let targetEndpoint = entry.targetEndpoint
        else {
            return
        }
        guard let reason = activeAuditFailure(
            pair: pair,
            observerEndpoint: observerEndpoint,
            targetEndpoint: targetEndpoint,
            descriptorCounts: descriptorCounts,
            candidatesBySession: candidatesBySession
        ) else {
            return
        }
        var audited = entry
        // Recorded before the revocation so the revocation's own notice cannot relabel this ending as
        // a generic lifecycle revocation, and so a concurrent pass cannot re-audit the same entry.
        audited.state = .terminal(reason)
        entries[pair] = audited
        #if DEBUG
            logReconcile(pair: pair, outcome: "audited", reason: reason.rawValue)
        #endif
        if let reference = entry.reference, let delegate {
            // Security never waits for disk: the exact generation is revoked first, and the durable
            // removal that follows is expected-token.
            await delegate.launchCoordinatorRevoke(reference: reference)
        }
        // Runtime-only revocation: recheck durable ownership after the authority hop.
        guard let settled = entries[pair], settled.token != nil,
              settled.reference == entry.reference, settled.state == .terminal(reason),
              settled.assertionGeneration == entry.assertionGeneration,
              settled.closedReferences == entry.closedReferences
        else { return }
        await retire(pair: pair, reason: reason)
    }

    private func establish(
        pair: AgentSessionOversightIntent,
        proof: AgentSessionOversightRestorationProof
    ) async {
        guard let delegate, var entry = entries[pair] else { return }
        // At-most-once is enforced by launch-entry state, not by the bridge's task table: a joined
        // task would satisfy the table while still counting as a second automatic reservation.
        guard !entry.didStartReservation else { return }
        entry.didStartReservation = true
        entry.state = .establishing
        entries[pair] = entry
        let token = entry.token

        let result = await delegate.launchCoordinatorEstablish(
            pair: pair,
            token: token,
            assertedAt: entry.assertionGeneration,
            proof: proof
        )
        let outcome = result.outcome

        guard var settled = entries[pair], settled.state == .establishing else { return }
        switch outcome {
        case .added, .alreadyLinked:
            settled.state = .active
            // Retained so this entry can be re-audited and, if it must end, revoked at exactly the
            // generation it was granted rather than by session UUID.
            settled.observerEndpoint = result.observerEndpoint
            settled.targetEndpoint = result.targetEndpoint
            settled.reference = result.reference
            entries[pair] = settled
            #if DEBUG
                if case .added = outcome {
                    logReconcile(pair: pair, outcome: "activated")
                } else {
                    logReconcile(pair: pair, outcome: "existing")
                }
            #endif
        case .failed, .rejected:
            // A shutdown-shaped refusal preserves the intent for the next launch; anything else is a
            // real refusal and the saved request is removed.
            guard !isFrozen else {
                settled.state = .waiting
                entries[pair] = settled
                return
            }
            // A hydration outcome can supersede the classified proof inside the shared path's
            // authority hops. That refusal grants nothing, but is not proof the saved pair is gone.
            if case .failed(.rebinding) = outcome,
               let host = delegate.launchCoordinatorHost,
               transientHydrationDrift(from: proof, candidates: host.agentSessionLinkCandidates())
            {
                // The launch reservation budget is spent; retain intent for the next launch.
                settled.state = .waiting
                entries[pair] = settled
                return
            }
            settled.state = .waiting
            entries[pair] = settled
            await retire(pair: pair, reason: .activationFailed)
        }
    }

    private func transientHydrationDrift(
        from proof: AgentSessionOversightRestorationProof,
        candidates: [AgentSessionLinkEndpointCandidate]
    ) -> Bool {
        let observers = candidates.filter { $0.sessionID == proof.observerEndpoint.sessionID }
        let targets = candidates.filter { $0.sessionID == proof.targetEndpoint.sessionID }
        guard observers.count == 1, targets.count == 1,
              let observer = observers.first, let target = targets.first,
              observer.domainEndpoint == proof.observerEndpoint,
              target.domainEndpoint == proof.targetEndpoint,
              observer.isTopLevel, !observer.isClosing,
              observer.roleAllowsOutboundMonitoring,
              !observer.isMCPControlled, !observer.isMCPOriginated,
              target.isTopLevel, !target.isClosing
        else {
            return false
        }
        func isTransient(
            _ current: AgentSessionRestorationReadiness,
            insteadOf expected: AgentSessionRestorationReadiness
        ) -> Bool {
            guard case let .terminal(token, failure) = current,
                  token == expected.bindingToken
            else { return false }
            return switch failure {
            case .loadFailed, .sourceRevisionSuperseded: true
            case .missingPayload: false
            }
        }
        let observerTransient = isTransient(observer.restorationReadiness, insteadOf: proof.observerReadiness)
        let targetTransient = isTransient(target.restorationReadiness, insteadOf: proof.targetReadiness)
        return (observerTransient || observer.restorationReadiness == proof.observerReadiness)
            && (targetTransient || target.restorationReadiness == proof.targetReadiness)
            && (observerTransient || targetTransient)
    }

    /// Terminalizes one entry and removes exactly its own durable token.
    private func retire(
        pair: AgentSessionOversightIntent,
        reason: AgentSessionOversightLaunchTerminalReason
    ) async {
        guard !isFrozen, let delegate, !delegate.launchCoordinatorIsFrozen, var entry = entries[pair]
        else {
            return
        }
        guard let token = entry.token else {
            entry.parkedReference = nil
            entry.closedReferences.removeAll()
            entry.state = .terminal(reason)
            entries[pair] = entry
            #if DEBUG
                logReconcile(pair: pair, outcome: "terminal", reason: reason.rawValue)
            #endif
            reportTerminalSummaryIfNeeded()
            return
        }
        entry.state = .terminal(reason)
        entries[pair] = entry
        let assertion = entry.assertionGeneration
        let receipt = await delegate.launchCoordinatorRemoveIntent(
            pair: pair,
            token: token,
            assertedAt: assertion
        )
        guard var settled = entries[pair] else { return }
        // An explicit Add that landed while this removal was in flight reasserted the pair under the
        // same durable token. The store compared this retirement out; recording it as terminal would
        // still strand a live interactive link behind a finished entry.
        guard settled.assertionGeneration == assertion, settled.token == token,
              settled.state == entry.state, settled.closedReferences == entry.closedReferences,
              settled.parkedReference == nil
        else { return }
        switch receipt.outcome {
        case .applied, .unchanged, .absent:
            settled.state = .terminal(reason)
            settled.token = nil
            settled.reference = nil
            settled.parkedReference = nil
            settled.closedReferences.removeAll()
            entries[pair] = settled
            #if DEBUG
                logReconcile(pair: pair, outcome: "terminal", reason: reason.rawValue)
            #endif
            reportTerminalSummaryIfNeeded()
        case .tokenMismatch:
            // A generation mismatch is the store proving this retirement is stale. The explicit Add
            // will hand the entry to the interactive path; do not pre-emptively terminalize it.
            guard receipt.assertionGeneration == assertion else { return }
            settled.state = .terminal(reason)
            settled.token = nil
            settled.reference = nil
            settled.parkedReference = nil
            settled.closedReferences.removeAll()
            entries[pair] = settled
            #if DEBUG
                logReconcile(pair: pair, outcome: "terminal", reason: reason.rawValue)
            #endif
            reportTerminalSummaryIfNeeded()
        case .writeFailed, .blocked:
            // Suppressed for this launch and recorded token-qualified, so no topology event retries
            // it and no stale receipt can later delete a reasserted intent.
            settled.state = .cleanupPending(token)
            entries[pair] = settled
            #if DEBUG
                logReconcile(pair: pair, outcome: "cleanup_pending", reason: reason.rawValue)
            #endif
            delegate.launchCoordinatorReportWarning(
                id: AgentSessionOversightWarningID.cleanupFailed,
                message: AgentSessionOversightPersistenceCopy.automaticCleanupFailed
            )
        }
    }

    /// One aggregate summary per launch. Never names a session.
    private func reportTerminalSummaryIfNeeded() {
        guard !didReportTerminalSummary else { return }
        didReportTerminalSummary = true
        delegate?.launchCoordinatorReportWarning(
            id: AgentSessionOversightWarningID.terminalRestoration,
            message: AgentSessionOversightPersistenceCopy.terminalRestorationSummary
        )
    }
}
