import Combine
import Foundation
import RepoPromptDomainRuntime

// MARK: - Observation token

/// Retains one target-scoped Combine observation. Teardown is always explicit: an implicit `deinit`
/// hop would let a torn-down window's observation outlive the link it belongs to.
@MainActor
final class AgentSessionLinkObservationToken {
    private var cancel: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    func invalidate() {
        let cancel = cancel
        self.cancel = nil
        cancel?()
    }
}

// MARK: - Status projection

/// The only fields Oversee's UI rows actually render for a target.
///
/// Deliberately separate from `DomainAgentSessionObservationSnapshot`: that value carries the
/// agent-facing assistant preview, which now costs a scan of the transcript items plus a pass of the
/// oversight-scoped redaction regexes. Rendering a status pill must not pay for text an observer never
/// sees, once per outbound row, on every status refresh of a streaming target.
struct AgentSessionLinkStatusProjection: Equatable {
    let status: DomainAgentSessionLinkStatus
    let pendingInteractionKind: DomainAgentSessionLinkPendingInteractionKind?
    let lastActivityAt: Date?

    init(
        status: DomainAgentSessionLinkStatus,
        pendingInteractionKind: DomainAgentSessionLinkPendingInteractionKind?,
        lastActivityAt: Date? = nil
    ) {
        self.status = status
        self.pendingInteractionKind = pendingInteractionKind
        self.lastActivityAt = lastActivityAt
    }
}

/// Diagnostic result of best-effort one-level Handoff/Fork link inheritance.
///
/// Counts only the parent's authority-active outbound inventory captured at the source snapshot.
/// Every child link is still minted by the ordinary durable Add transaction.
struct AgentSessionLinkForkInheritanceSummary: Equatable {
    let consideredCount: Int
    let addedCount: Int
    let alreadyLinkedCount: Int
    let skippedCount: Int

    static let empty = AgentSessionLinkForkInheritanceSummary(
        consideredCount: 0,
        addedCount: 0,
        alreadyLinkedCount: 0,
        skippedCount: 0
    )
}

// MARK: - Endpoint host

/// The narrow app-side surface the bridge needs. Keeping it a protocol means the bridge never
/// imports `WindowState`/`AgentModeViewModel`, and the whole lifecycle can be exercised in tests
/// without constructing windows.
///
/// Every method must be side-effect free with respect to focus: resolving, snapshotting, and
/// observing a target must never switch, activate, or focus its window.
@MainActor
protocol AgentSessionLinkEndpointHost: AnyObject {
    /// All live compose-tab/session bindings across every non-closing window.
    func agentSessionLinkCandidates() -> [AgentSessionLinkEndpointCandidate]

    /// Sanitized observation snapshot for one exact live candidate.
    ///
    /// This is the agent-facing path: it materializes and redacts the latest assistant preview, so it
    /// belongs to target publication and `poll`, not to UI status rendering.
    func agentSessionLinkObservationSnapshot(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> DomainAgentSessionObservationSnapshot

    /// Status/activity-only projection for one exact live candidate.
    ///
    /// Reads only the run-state, pending-interaction, and canonical activity fields. It must never materialize, scan, or
    /// redact transcript text. `nil` means the endpoint has no live session to report on.
    func agentSessionLinkStatusProjection(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> AgentSessionLinkStatusProjection?

    /// The exact observer session's persisted **Auto-wake on updates** setting.
    ///
    /// Session configuration, not runtime state: it survives relaunch with the session, and it is
    /// read here rather than mirrored into the bridge so a rebind or session switch cannot leave the
    /// dashboard rendering a value the session no longer holds.
    func agentSessionLinkAutoWakeOnUpdatesEnabled(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> Bool

    func agentSessionLinkAutoWakeTargetSessionIDs(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> Set<UUID>

    /// Writes that setting to one exact observer incarnation, returning `false` when the endpoint no
    /// longer resolves to a live hydrated session.
    @discardableResult
    func agentSessionLinkSetAutoWakeOnUpdatesEnabled(
        _ enabled: Bool,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool

    @discardableResult
    func agentSessionLinkSetAutoWakeTargetSessionIDs(
        _ targetSessionIDs: Set<UUID>,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool

    @discardableResult
    func agentSessionLinkSetWaitingOn(
        _ waitingOn: DomainAgentSessionWaitingOn?,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool

    /// Pure Auto-wake snooze read for one exact observer incarnation and link generation.
    ///
    /// Observational only: a conforming host must not remove records, arm or cancel tasks, publish
    /// monitor changes, or re-enter the wake pipeline from it. An elapsed record reports
    /// `success(nil)` rather than being cleaned up by the read.
    func agentSessionLinkAutoWakeSnoozeProjection(
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        expectedReference: DomainAgentSessionLinkReference
    ) -> Result<AgentSessionLinkAutoWakeSnoozeProjection?, AgentSessionLinkAutoWakeSnoozeFailure>

    /// Applies one Auto-wake snooze set/extend/clear to the exact live observer incarnation.
    ///
    /// Observer-local policy only. It must not apply a receipt, mutate durable selection, touch link
    /// authority or target state, or start a turn; the coordinator owns the single reevaluation each
    /// accepted command performs.
    func agentSessionLinkMutateAutoWakeSnooze(
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        expectedReference: DomainAgentSessionLinkReference,
        command: AgentSessionLinkAutoWakeSnoozeCommand,
        origin: AgentSessionLinkAutoWakeSnoozeOrigin
    ) -> Result<AgentSessionLinkAutoWakeSnoozeMutationOutcome, AgentSessionLinkAutoWakeSnoozeFailure>

    /// Installs the target-state observation for one endpoint, returning `nil` when the endpoint is
    /// no longer live. `onChange` fires on MainActor for every observation input, including the
    /// non-`@Published` readiness inputs that publish through an explicit revision counter.
    func agentSessionLinkInstallObservation(
        for candidate: AgentSessionLinkEndpointCandidate,
        onChange: @escaping @MainActor () -> Void
    ) -> AgentSessionLinkObservationToken?

    /// Publishes a refreshed Oversee projection to one exact endpoint incarnation.
    ///
    /// Addressed by endpoint rather than by session UUID: a duplicate live incarnation of the same
    /// UUID in another window must never be handed the granted incarnation's rows.
    func agentSessionLinkPublishProjection(
        _ props: AgentMonitorPillProps,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    )

    /// Publishes the authoritative outbound link inventory to one exact endpoint incarnation.
    ///
    /// This is the *ordinary* publication path, emitted from the same pass that rebuilds the UI
    /// projection. It is not the only one: a membership write fences this endpoint and publishes the
    /// post-write inventory from its own disposition, ahead of the refresh that rebuilds the pill, so
    /// the two projections can briefly describe different membership. Only the observer link-set
    /// revision inside it gates prompt injection; status churn republishes an equal value and is
    /// therefore a no-op.
    ///
    /// Refused while the endpoint is fenced — see `agentSessionLinkWithholdPromptInventory(for:)`.
    func agentSessionLinkPublishPromptInventory(
        _ inventory: AgentSessionLinkPromptInventory,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    )

    /// Publishes one exact observer incarnation's passive status-notice queue.
    ///
    /// Typed and routed separately from the prompt inventory on purpose: membership is authority
    /// state that decides what the agent may be *told*, while this is observer-local delivery state
    /// that decides what is currently *owed*. The two are joined only at dispatch, and only while
    /// their link-set revisions still match, so a queue reduced against a superseded membership can
    /// never be delivered against the current one.
    ///
    /// Emitted only from the ordinary authoritative projection pass and from an explicit preference
    /// change, and only for an observer that has switched passive notices on at least once. A host
    /// that cannot route it to that exact incarnation must drop it rather than hand it to a session
    /// that merely shares the UUID.
    func agentSessionLinkPublishPassiveStatusNotices(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    )

    /// Fences one incarnation's published inventory, so nothing can be claimed against a membership
    /// snapshot that is about to stop being true, and returns the fence's token.
    ///
    /// The fence exists because a membership write commits inside the authority actor while this
    /// caller is still suspended on the hop — no publication made after the call returns, however
    /// synchronous, is early enough to cover that. It has to be state the *host* holds rather than a
    /// local of the writing function: an already-running projection refresh can be suspended on its
    /// own authority hop holding an inventory it read before the fence went up, and it would
    /// otherwise republish that value into the window.
    ///
    /// Concurrent raises for the same endpoint join one shared fence rather than superseding each
    /// other, and it stays up until the last of them is released — so a caller may assume only that
    /// *its own* release settles *its own* participation, never that the release publishes.
    ///
    /// Returns `nil` when no incarnation could be fenced, in which case the matching release is a
    /// no-op. Every raise must be paired with exactly one
    /// `agentSessionLinkReleasePromptInventoryHold(_:for:publishing:)` on every exit.
    func agentSessionLinkWithholdPromptInventory(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> UInt64?

    /// Settles `token`'s participation in the fence and reports this write's outcome: the post-write
    /// inventory the write itself observed, or `nil` because the write did not commit.
    ///
    /// Not necessarily a publication. Overlapping writes share one fence, so this lowers it only when
    /// the last participant settles, and what it then publishes is the highest-revision inventory any
    /// of them committed — or the pre-fence value if none did. A rejection is therefore never able to
    /// restore a stale inventory over a sibling that committed, in either release order.
    func agentSessionLinkReleasePromptInventoryHold(
        _ token: UInt64?,
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        publishing inventory: AgentSessionLinkPromptInventory?
    )

    /// Sanitized, bounded transcript page for one exact live candidate.
    ///
    /// Reading must never focus, activate, or switch the target window, and must never expose the
    /// target window's presentation/reveal state as the history boundary.
    ///
    /// `async` because the implementation materializes the canonical projection off the `@MainActor`
    /// and re-proves the exact endpoint incarnation afterwards; a conforming host must keep that
    /// revalidation rather than treating the suspension point as free.
    func agentSessionLinkTranscriptPage(
        for candidate: AgentSessionLinkEndpointCandidate,
        anchor: AgentSessionLinkTranscriptAnchor?,
        direction: AgentSessionLinkReadDirectionInput,
        maxItems: Int,
        maxOutputBytes: Int,
        readerSessionID: UUID?
    ) async -> Result<AgentSessionLinkTranscriptPage, AgentSessionLinkReadUnavailableReason>

    /// Synchronous liveness of both endpoint incarnations of one send, plus the target window's
    /// teardown state, answered in a single MainActor pass.
    ///
    /// The transaction runs on the *target's* view model, which can see only its own window. Observer
    /// liveness and the target window's real closing state are therefore facts only the host that
    /// owns every window can supply. Reading them must never focus, activate, or switch a window.
    func agentSessionLinkSendLiveness(
        observer: DomainAgentSessionLinkEndpointIdentity,
        target: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSessionLinkSendLiveness

    /// Runs the whole cross-session send transaction on the target's MainActor.
    ///
    /// The host owns every step that must not be split across an actor hop: readiness admission, the
    /// local composer claim, the authorization commit fence, durable persistence, and provider
    /// dispatch. Returning a value outcome keeps the bridge free of view-model types.
    ///
    /// - Parameter liveness: host-backed probe re-read at every fence the transaction crosses.
    func agentSessionLinkPerformSend(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkSendRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkSendTransactionOutcome

    // MARK: Launch restoration inputs

    /// Identity-only descriptors for every compose-tab binding in every active workspace.
    ///
    /// This is what lets a launch-loaded intent tell "that session is present but its background tab
    /// has not been visited" apart from "that session is not open anywhere". Reading it must hydrate
    /// nothing.
    func agentSessionLinkComposeTabDescriptors() -> [AgentSessionLinkComposeTabDescriptor]

    /// Current discovery level of every registered window.
    ///
    /// An empty result means no window has described its bindings yet, which is "not described" —
    /// never "nothing to describe".
    func agentSessionLinkDiscoveryStates() -> [AgentSessionLinkDiscoveryState]

    /// Why the outer window-restore gate became idle.
    func agentSessionLinkRestoreTopologyState() -> AgentSessionOversightRestoreTopologyState

    /// Broadcasts the process-wide durable-oversight level to every non-closing window, including
    /// tabs that hold no links at all.
    func agentSessionLinkPublishPersistencePresentation(
        _ presentation: AgentSessionOversightPersistencePresentation
    )
}

/// Defaults for the launch-restoration surface.
///
/// Declared in the protocol body (so a real host's overrides dispatch dynamically) but defaulted
/// here, because the focused bridge tests build hosts that model endpoints only and have no window
/// topology at all. The defaults are the conservative ones: no descriptors, no discovery level, and a
/// pending topology, which together mean automatic restoration never runs against such a host.
extension AgentSessionLinkEndpointHost {
    func agentSessionLinkSetWaitingOn(
        _: DomainAgentSessionWaitingOn?,
        for _: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        false
    }

    func agentSessionLinkComposeTabDescriptors() -> [AgentSessionLinkComposeTabDescriptor] {
        []
    }

    func agentSessionLinkDiscoveryStates() -> [AgentSessionLinkDiscoveryState] {
        []
    }

    func agentSessionLinkRestoreTopologyState() -> AgentSessionOversightRestoreTopologyState {
        .pending
    }

    func agentSessionLinkPublishPersistencePresentation(
        _: AgentSessionOversightPersistencePresentation
    ) {}

    /// Fail-closed defaults for the auto-wake setting.
    ///
    /// A host that does not model per-session settings reports it as off and refuses to write it,
    /// which is the conservative answer in both directions: no host can opt a session into automatic
    /// turns by omission.
    func agentSessionLinkAutoWakeOnUpdatesEnabled(
        for _: AgentSessionLinkEndpointCandidate
    ) -> Bool {
        false
    }

    func agentSessionLinkAutoWakeTargetSessionIDs(
        for _: AgentSessionLinkEndpointCandidate
    ) -> Set<UUID> {
        []
    }

    @discardableResult
    func agentSessionLinkSetAutoWakeOnUpdatesEnabled(
        _: Bool,
        for _: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        false
    }

    @discardableResult
    func agentSessionLinkSetAutoWakeTargetSessionIDs(
        _: Set<UUID>,
        for _: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        false
    }

    /// Fail-closed defaults for snooze routing.
    ///
    /// A host that models no live view model cannot own observer-local policy, so it reports the
    /// endpoint as unavailable in both directions rather than inventing an empty projection.
    func agentSessionLinkAutoWakeSnoozeProjection(
        for _: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID _: UUID,
        expectedReference _: DomainAgentSessionLinkReference
    ) -> Result<AgentSessionLinkAutoWakeSnoozeProjection?, AgentSessionLinkAutoWakeSnoozeFailure> {
        .failure(.observerUnavailable)
    }

    func agentSessionLinkMutateAutoWakeSnooze(
        for _: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID _: UUID,
        expectedReference _: DomainAgentSessionLinkReference,
        command _: AgentSessionLinkAutoWakeSnoozeCommand,
        origin _: AgentSessionLinkAutoWakeSnoozeOrigin
    ) -> Result<AgentSessionLinkAutoWakeSnoozeMutationOutcome, AgentSessionLinkAutoWakeSnoozeFailure> {
        .failure(.observerUnavailable)
    }
}

// MARK: - Candidate readiness signal

/// Process-wide seam for "an oversight eligibility input changed without any authority event".
///
/// Hydration finishing, a binding transition completing, MCP control attaching, a task-label policy
/// change, and a deletion transition all change whether a session may be granted — or may keep — an
/// oversight link, and none of them produces a `DomainAgentSessionLinkChangeEvent`. Without this the
/// launch coordinator would have to poll, which is exactly what the design forbids.
///
/// Deliberately payload-free: it is a wake-up, never authority. Every consumer rereads current state.
@MainActor
enum AgentSessionLinkCandidateReadinessSignal {
    static var onChange: (() -> Void)?

    static func didChange() {
        onChange?()
    }
}

// MARK: - Location invalidation sink

/// Process-wide seam for "an authoritative execution-location input changed for endpoints someone
/// may be rendering an Oversee row for".
///
/// Presentation only, in both directions. Nothing here is authority: the handler repaints outbound
/// rows and does nothing else, and the mutation sites that fire it neither know nor care whether a
/// link exists. The closures stay `nil` until a bridge attaches to a live host, so a workspace rename
/// or a global worktree-label edit in a headless context — or in a focused test — never forces
/// domain-runtime composition just to repaint a label.
@MainActor
enum AgentSessionLinkLocationInvalidationSink {
    /// Exact target incarnations whose effective location label just changed.
    static var refreshExactTargets: ((Set<DomainAgentSessionLinkEndpointIdentity>) -> Void)?
    /// Conservative scan for the label inputs that carry no tab identity — a workspace rename or a
    /// global worktree label. `nil` means every observed target incarnation.
    static var refreshObservedTargets: ((UUID?) -> Void)?

    static func locationChanged(
        forExactTargetEndpoints endpoints: Set<DomainAgentSessionLinkEndpointIdentity>
    ) {
        refreshExactTargets?(endpoints)
    }

    static func locationLabelsChanged(inWorkspace workspaceID: UUID?) {
        refreshObservedTargets?(workspaceID)
    }
}

// MARK: - Invalidation sink

/// Process-wide seam that lets low-level lifecycle code revoke links without importing the bridge.
///
/// It stays `nil` until a bridge attaches to a live host, so unit tests and headless contexts that
/// tear down compose tabs never force domain-runtime composition just to fire a revocation.
///
/// The seam is deliberately `(window, tab)`-scoped rather than session-UUID-scoped. A session UUID
/// can be live in more than one window at once, so escalating one removed tab to a UUID-wide
/// invalidation would revoke a different window's still-valid grants.
@MainActor
enum AgentSessionLinkInvalidationSink {
    static var invalidateBinding: ((Int, UUID, DomainAgentSessionLinkRevocationReason) -> Void)?

    /// Revokes only the endpoint incarnations of one exact `(window, tab)` that are no longer live.
    static func bindingEnded(
        windowID: Int,
        tabID: UUID,
        reason: DomainAgentSessionLinkRevocationReason
    ) {
        invalidateBinding?(windowID, tabID, reason)
    }
}

// MARK: - Bridge

/// MainActor bridge between live window/tab/session bindings and the process-wide
/// `DomainAgentSessionLinkAuthority`.
///
/// Responsibilities:
/// - Map live bindings to exact domain endpoint identities.
/// - Seed the first inbound link **synchronously** before activation returns, so `poll` can never
///   race an uninitialized active link.
/// - Own one retained serial publication chain per observed target with a monotonically increasing
///   source publication sequence, so a late MainActor task can never regress status.
/// - Revoke eagerly on every lifecycle seam and lazily on every identity revalidation.
/// - Refetch and publish both endpoints' UI projections from authority change events.
@MainActor
final class AgentSessionLinkRuntimeBridge {
    static let shared = AgentSessionLinkRuntimeBridge(
        authority: AppDomainRuntimeComposition.shared.runtime.agentSessionLinkAuthority
    )

    /// One observed target: its exact endpoint incarnation, its retained observation, and the tail of
    /// its serial publication chain.
    /// How much of the projection tree one refresh pass has to rebuild.
    ///
    /// Status churn on a busy target is by far the highest-frequency event, and it can only change
    /// the outbound rows of that target's observers. Rebuilding every projection in every window for
    /// each token of streamed output would be quadratic in windows × candidates.
    private enum ProjectionRefreshScope {
        case full
        case sessions(Set<UUID>)

        func merged(with other: ProjectionRefreshScope) -> ProjectionRefreshScope {
            switch (self, other) {
            case (.full, _), (_, .full):
                .full
            case let (.sessions(lhs), .sessions(rhs)):
                .sessions(lhs.union(rhs))
            }
        }

        var isFull: Bool {
            if case .full = self { return true }
            return false
        }
    }

    private final class TargetPublicationChain {
        let endpoint: DomainAgentSessionLinkEndpointIdentity
        var token: AgentSessionLinkObservationToken?
        var tail: Task<Void, Never>?
        /// Monotonic canonical activity for this exact target incarnation.
        var activityHighWater: Date?

        init(endpoint: DomainAgentSessionLinkEndpointIdentity, activityHighWater: Date? = nil) {
            self.endpoint = endpoint
            self.activityHighWater = activityHighWater
        }

        @discardableResult
        func noteActivity(_ date: Date?) -> Date? {
            guard let date else { return activityHighWater }
            if let activityHighWater {
                if date > activityHighWater { self.activityHighWater = date }
            } else {
                activityHighWater = date
            }
            return activityHighWater
        }
    }

    /// One observer's acknowledgement watermark for one generation-qualified link.
    /// `activityWatermark` is optional because a link can be granted before its target has any valid
    /// activity at all. That baseline renders read — there is nothing to have missed — and the first
    /// later valid activity is what becomes unread.
    private struct MonitorSeenRecord: Equatable {
        let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
        let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
        let activityWatermark: Date?
    }

    /// Optional exact-incarnation constraints used by Handoff/Fork inheritance and sidebar Add.
    ///
    /// Pasted-ID Add and launch restoration pass no constraints and retain their existing UUID
    /// resolution semantics. Exact callers supply both endpoints so duplicate UUID incarnations do
    /// not introduce ambiguity and a stale presentation can never mint against a replacement.
    private struct AddEndpointExpectations: Equatable, Hashable {
        let observer: DomainAgentSessionLinkEndpointIdentity?
        let target: DomainAgentSessionLinkEndpointIdentity?
        /// Sidebar target-management may only extend authority already held by this exact observer.
        /// Other Add callers leave this false so they can still create an observer's first link.
        let requiresExistingOutboundLink: Bool

        init(
            observer: DomainAgentSessionLinkEndpointIdentity?,
            target: DomainAgentSessionLinkEndpointIdentity?,
            requiresExistingOutboundLink: Bool = false
        ) {
            self.observer = observer
            self.target = target
            self.requiresExistingOutboundLink = requiresExistingOutboundLink
        }

        var isEmpty: Bool {
            observer == nil && target == nil
        }

        func matches(
            observer actualObserver: DomainAgentSessionLinkEndpointIdentity,
            target actualTarget: DomainAgentSessionLinkEndpointIdentity
        ) -> Bool {
            (observer == nil || observer == actualObserver)
                && (target == nil || target == actualTarget)
        }
    }

    /// Identifies one attempt to establish a durable pair under one durable token.
    ///
    /// Keyed by token, not by pair: a Stop followed immediately by a re-add produces token A and
    /// token B for the same pair, and a task table keyed by pair alone would let the re-add join —
    /// and then be settled or compensated by — the retiring attempt.
    private struct EstablishmentKey: Hashable {
        let pair: AgentSessionOversightIntent
        /// `nil` when no durable layer is installed. Concurrent callers with the same exact endpoint
        /// constraints still join, which is the same linearization pair keying would give, without
        /// pretending a token exists. A constrained inheritance attempt never joins an unconstrained
        /// manual/restoration attempt whose valid incarnation could differ.
        let token: AgentSessionOversightIntentToken?
        let expectedEndpoints: AddEndpointExpectations
    }

    /// What one reservation or grant reference belongs to.
    ///
    /// Bookkeeping only: it never authorizes anything. Its purpose is to let a Stop, compensation, or
    /// lifecycle owner identify *its own* token before removing durable state, so a stale owner
    /// cannot delete an intent a newer token reasserted.
    private struct ReferenceBookkeeping: Equatable {
        let pair: AgentSessionOversightIntent
        let token: AgentSessionOversightIntentToken?
        /// The pair's assertion generation this reference belongs to.
        ///
        /// The token alone is not enough. An idempotent re-add of an existing pair deliberately
        /// *reuses* it, so a lifecycle owner suspended on an authority hop would resume holding a
        /// token that is still current and delete the intent the user reasserted in the meantime.
        /// The generation is what makes that owner compare out.
        let assertionGeneration: UInt64?
    }

    private enum IntentPersistenceAdmission {
        /// No durable layer is installed in this process.
        case noDurableLayer
        case available(AgentSessionOversightIntentStore)
        case refused(String)
    }

    /// What one fresh establishment attempt produced.
    ///
    /// Richer than the popover outcome on purpose: the launch coordinator has to remember the exact
    /// incarnations and grant reference it was activated against, or it can never audit an active
    /// entry for a late duplicate, a permanent ineligibility, or observed binding drift.
    struct EstablishmentResult {
        let outcome: AgentMonitorAddOutcome
        var observerEndpoint: DomainAgentSessionLinkEndpointIdentity?
        var targetEndpoint: DomainAgentSessionLinkEndpointIdentity?
        var reference: DomainAgentSessionLinkReference?
        /// An exact-endpoint inheritance attempt can discover a pre-existing grant owned by a
        /// different incarnation. That grant and its durable intent belong to earlier work, so the
        /// mismatch must fail without compensating or revoking either one.
        var preservesDurableIntentOnFailure: Bool

        init(
            outcome: AgentMonitorAddOutcome,
            observerEndpoint: DomainAgentSessionLinkEndpointIdentity? = nil,
            targetEndpoint: DomainAgentSessionLinkEndpointIdentity? = nil,
            reference: DomainAgentSessionLinkReference? = nil,
            preservesDurableIntentOnFailure: Bool = false
        ) {
            self.outcome = outcome
            self.observerEndpoint = observerEndpoint
            self.targetEndpoint = targetEndpoint
            self.reference = reference
            self.preservesDurableIntentOnFailure = preservesDurableIntentOnFailure
        }

        var isAlreadyLinked: Bool {
            if case .alreadyLinked = outcome { return true }
            return false
        }
    }

    /// One pair-exclusive durable retirement in flight.
    ///
    /// Identified so the lane can release itself *before* its task finishes: a waiter that resumes to
    /// find its own lane still installed would otherwise have no way to tell "the release is queued
    /// behind me" from "a newer lane took over", which is what made the old bounded spin necessary.
    private struct PairRetirementLane {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// One complete Add or restoration transaction for a semantic UUID pair.
    ///
    /// Durable intent is pair-keyed, while authority grants are exact-endpoint-keyed. Serializing the
    /// complete transaction prevents two incarnations of the same UUID pair from
    /// activating sibling grants against one durable token.
    private struct PairEstablishmentLane {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// One-shot gate shared by a shutdown phase and the total deadline that bounds it.
    ///
    /// MainActor-confined, so the single-resume guarantee is a plain flag rather than a lock, and the
    /// losing branch is abandoned rather than awaited.
    @MainActor
    private final class ShutdownPhaseGate {
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func finish(_ completed: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: completed)
        }
    }

    private let authority: DomainAgentSessionLinkAuthority
    private weak var host: AgentSessionLinkEndpointHost?
    /// Durable oversight intent, installed by app composition.
    ///
    /// Deliberately not constructed here. The bridge is a process singleton, so a self-bootstrapping
    /// store would perform production Application Support I/O inside every focused test that builds a
    /// bridge. Until one is installed, Add and Stop still linearize by pair but persist nothing.
    private var intentStore: AgentSessionOversightIntentStore?
    /// Bounded automatic reauthorization of the launch snapshot. Created lazily so a bridge with no
    /// durable layer never allocates one.
    private var launchCoordinator: AgentSessionOversightLaunchCoordinator?
    /// The single process-wide durable-oversight level every window renders.
    private var persistencePresentation = AgentSessionOversightPersistencePresentation.noDurableLayer
    /// Termination freeze. Set synchronously, before any async shutdown work, and never cleared:
    /// after it, no Add/Stop/cleanup is admitted and no teardown callback may delete durable intent.
    private var isFrozenForTermination = false
    /// Bridge-registered pre-freeze transactions. Bounded settlement waits only for these.
    private var registeredTransactionIDs: Set<UUID> = []
    /// Resumed by whichever of "last transaction finished" and "deadline elapsed" happens first.
    /// Both branches run on MainActor, so nilling it here is a sufficient one-shot guard.
    private var intentSettlementContinuation: CheckedContinuation<Bool, Never>?
    /// In-flight fresh establishments. Same-key callers join rather than racing a second reservation.
    private var establishmentTasks: [EstablishmentKey: Task<EstablishmentResult, Never>] = [:]
    /// One retirement lane per pair. Every durable removal for a pair — user Stop, launch
    /// retirement, and cleanup retry alike — runs in it, and an Add holds it across its own insert,
    /// so a stale cleanup can never commit between the reassertion and the state change that would
    /// have retired it.
    private var pairRetirementBarriers: [AgentSessionOversightIntent: PairRetirementLane] = [:]
    /// Adds and restoration are serialized by semantic UUID pair across preflight, durable assertion,
    /// establishment, and compensation. This is distinct from the retirement lane so Stop can still
    /// settle an in-flight establishment without deadlocking its rollback.
    private var pairEstablishmentBarriers: [AgentSessionOversightIntent: PairEstablishmentLane] = [:]
    private var bookkeepingByReference: [DomainAgentSessionLinkReference: ReferenceBookkeeping] = [:]
    /// Process-memory, observer-local unread baselines. Never persisted and never agent-visible.
    private var monitorSeenByReference: [DomainAgentSessionLinkReference: MonitorSeenRecord] = [:]
    /// Lane status-change queues, one per **exact observer incarnation**.
    ///
    /// Created automatically for any observer that resolves at least one direct outbound target, and
    /// dropped again after one terminal empty snapshot when its last link goes away. Keyed by
    /// endpoint rather than session UUID so a rebound or re-added observer baselines fresh instead
    /// of resuming a backlog its previous incarnation collected under authority it no longer holds.
    private var passiveNoticesByObserver:
        [DomainAgentSessionLinkEndpointIdentity: AgentSessionLinkPassiveStatusNotices] = [:]
    private var chains: [UUID: TargetPublicationChain] = [:]
    /// Never reset per target record. A re-installed chain therefore continues above any high-water
    /// mark a previous incarnation left behind, so its first publication is never rejected as stale.
    private var nextSourcePublicationSequenceBySession: [UUID: UInt64] = [:]
    /// Endpoint incarnations this bridge has activated links for, split by the role they played.
    ///
    /// Eager lifecycle hooks can always be missed, so every projection refresh sweeps these against
    /// the live candidate set and revokes anything that no longer exists byte-for-byte. Splitting the
    /// sets keeps the revocation reason accurate at each end of the link.
    private var knownObserverEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = []
    private var knownTargetEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = []
    /// Last snapshot accepted for each observed target.
    ///
    /// `@Published` inputs replay their current value to every new subscriber, so installing an
    /// observation immediately produces a burst of identical rebuilds. Publishing those would advance
    /// the authority's `change_sequence` and wake waiters for a state that never changed.
    private var lastPublishedSnapshotBySession: [UUID: DomainAgentSessionObservationSnapshot] = [:]
    /// At most one pre-authorized send per **current link generation**.
    ///
    /// Deliberately a plain main-actor dictionary rather than a queue subsystem: there is no
    /// persistence, no history, no priority, no second message, and no timer. Every entry is keyed by
    /// the exact generation it was admitted under, so a revoked or re-added link starts empty rather
    /// than inheriting work the user granted under authority they have since removed.
    private var pendingSendsByReference: [DomainAgentSessionLinkReference: AgentSessionLinkPendingSend] = [:]
    /// The single terminal outcome each link retains for its observer's `poll`.
    ///
    /// Overwritten by the next queue mutation and dropped with the link. It exists so a queued
    /// delivery that settled between two polls is still observable without a notification subsystem.
    private var pendingSendResultsByReference:
        [DomainAgentSessionLinkReference: AgentSessionLinkPendingSendResult] = [:]
    /// Injected so the bridge never imports the MCP connection actor in tests.
    private let toolAdvertisementInvalidator: @Sendable (UUID) async -> Void
    /// Reconciliation clock for status-edge timestamps. Injected so a test can assert that the
    /// stamped time is the status edge rather than render time.
    private let now: @Sendable () -> Date
    private var changeFeedTask: Task<Void, Never>?
    private var inboundAdvertisementCountByTargetSession: [UUID: Int] = [:]
    private var refreshTask: Task<Void, Never>?
    private var pendingRefreshScope: ProjectionRefreshScope?
    /// Exact target incarnations whose effective location label changed and whose observers still
    /// have to be repainted. Coalesced: a burst of worktree/branch/workspace edits costs one pass.
    private var pendingMonitorTargetEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = []
    /// Exact observers already known to need a presentation-only projection repaint for location,
    /// Seen, settings, sidebar-menu eligibility, or observer-role presentation.
    private var pendingMonitorObserverEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = []
    private var monitorProjectionRefreshTask: Task<Void, Never>?
    private var bindingChangeCancellable: AnyCancellable?

    #if DEBUG
        /// Deterministic interleaving seam after authority revocation and before durable cleanup enters
        /// the pair lane. Tests use it to reassert the same token in the exact stale-owner window.
        var test_beforeDurableIntentSettlement: (@MainActor (AgentSessionOversightIntent) async -> Void)?
        /// Deterministic interleaving seam after activation is live and bookkeeping is installed, but
        /// before the post-activation deletion/token fence.
        var test_afterActivationBeforeDeletionFence: (@MainActor (AgentSessionOversightIntent) async -> Void)?
        /// Deterministic interleaving seam after a fresh authority reservation is owned by this
        /// transaction, but before its final live-candidate checks and activation.
        var test_afterReservationBeforeActivation:
            (@MainActor (AgentSessionOversightIntent) async -> Void)?
        /// Signals that an Add is waiting behind another complete establishment for the same
        /// semantic UUID pair. Tests use it instead of timing assumptions.
        var test_beforePairEstablishmentWait:
            (@MainActor (AgentSessionOversightIntent) async -> Void)?
        /// Suspends Seen's final lease validation so tests can advance live endpoint state before the
        /// post-validation synchronous commit.
        var test_duringFinalSeenLeaseValidation: (@MainActor () async -> Void)?
        /// Observes only the domain operation selected for Seen authorization.
        var test_observeSeenAuthorizationOperation:
            (@MainActor (DomainAgentSessionTargetOperation) -> Void)?
    #endif

    init(
        authority: DomainAgentSessionLinkAuthority,
        host: AgentSessionLinkEndpointHost? = nil,
        toolAdvertisementInvalidator: @escaping @Sendable (UUID) async -> Void = { sessionID in
            await ServerNetworkManager.shared.notifyToolListChangedForAgentSession(sessionID)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authority = authority
        self.host = host
        self.toolAdvertisementInvalidator = toolAdvertisementInvalidator
        self.now = now
    }

    // MARK: - Attachment

    func attach(host: AgentSessionLinkEndpointHost) {
        self.host = host
        AgentSessionLinkInvalidationSink.invalidateBinding = { [weak self] windowID, tabID, reason in
            guard let self else { return }
            Task { @MainActor in
                await self.invalidateBinding(windowID: windowID, tabID: tabID, reason: reason)
            }
        }
        AgentSessionLinkCandidateReadinessSignal.onChange = { [weak self] in
            self?.noteCandidateReadinessChanged()
        }
        AgentSessionLinkLocationInvalidationSink.refreshExactTargets = { [weak self] endpoints in
            self?.requestMonitorLocationRefresh(forExactTargetEndpoints: endpoints)
        }
        AgentSessionLinkLocationInvalidationSink.refreshObservedTargets = { [weak self] workspaceID in
            self?.requestMonitorLocationRefreshForObservedTargets(inWorkspace: workspaceID)
        }
        // Awaited by the registry rather than spawned: the deleting caller must not proceed to
        // metadata cleanup, the next batch file, or view-model teardown while this UUID's grants are
        // still live and its saved rows still on disk.
        AgentSessionDeletionRegistry.shared.commitObserver = { [weak self] sessionID in
            await self?.handleCommittedSessionDeletion(sessionID)
        }
        AgentSessionDeletionRegistry.shared.changeObserver = { [weak self] in
            self?.noteCandidateReadinessChanged()
        }
        observeBindingChangesIfNeeded()
        startChangeFeedIfNeeded()
        // An attach can arrive *after* the store load, the restore gate, or a discovery level already
        // settled. Republishing the current level and marking reconciliation dirty is what keeps a
        // late window from losing all three; attach itself still restores nothing.
        host.agentSessionLinkPublishPersistencePresentation(persistencePresentation)
        noteTopologyMayHaveChanged()
    }

    /// Subscribes to the authoritative persistent-binding seam.
    ///
    /// `sessions.didSet` only sees a tab appearing or disappearing; it cannot see a tab that stays
    /// alive while its binding is replaced in place. `installPersistentSessionBinding` is the single
    /// mutation point for that, and it posts `.agentSessionBindingDidChange` for unbind, rebind, and
    /// delete alike. Observing it reads no window state and changes no focus.
    private func observeBindingChangesIfNeeded() {
        guard bindingChangeCancellable == nil else { return }
        bindingChangeCancellable = NotificationCenter.default
            .publisher(for: .agentSessionBindingDidChange)
            .compactMap { note -> (Int, UUID)? in
                guard let windowID = note.userInfo?["windowID"] as? Int,
                      let tabID = note.userInfo?["tabID"] as? UUID
                else { return nil }
                return (windowID, tabID)
            }
            .sink { [weak self] windowID, tabID in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.invalidateBinding(windowID: windowID, tabID: tabID) }
                }
            }
    }

    private func startChangeFeedIfNeeded() {
        guard changeFeedTask == nil else { return }
        changeFeedTask = Task { [weak self, authority] in
            let events = await authority.changeEvents()
            for await event in events {
                guard let self else { return }
                // Activation retracts catalog readiness before active inventory can publish; revocation
                // publishes the reduced inventory before retracting the obsolete catalog observation.
                switch event.kind {
                case .activated:
                    await invalidateToolAdvertisement(for: event)
                    await requestProjectionRefresh(scope(for: event))
                case .revoked, .targetStateChanged, .draining, .shutdown:
                    await requestProjectionRefresh(scope(for: event))
                    await invalidateToolAdvertisement(for: event)
                }
            }
        }
    }

    /// Narrowest projection scope that can possibly have changed for one authority event.
    private func scope(for event: DomainAgentSessionLinkChangeEvent) async -> ProjectionRefreshScope {
        switch event.kind {
        case .targetStateChanged:
            // Status-only: link membership did not change, so only the *observers* of this target can
            // render differently — their outbound rows carry its status. The target's own projection
            // lists inbound observers and is unaffected by its own status.
            guard let targetSessionID = event.targetSessionID else { return .full }
            let observers = await authority.links(forTarget: targetSessionID).items.map(\.observerSessionID)
            return .sessions(Set(observers))
        case .activated, .revoked:
            // Every target menu intersects live candidates with the authority-wide set of exact
            // endpoints holding outbound grants. A membership change can cross an observer's 0↔1
            // boundary and therefore change availability in otherwise unrelated target rows.
            return .full
        case .draining, .shutdown:
            return .full
        }
    }

    /// Re-advertises `agent_session_link` for either endpoint whose any-link catalog state changed.
    ///
    /// Outbound membership still decides observer operations, while any exact inbound or outbound
    /// grant decides catalog visibility. Advertisement is never authority, so a lost or late
    /// notification only costs one stale `tools/list`; execution recomputes the exact live grant.
    private func invalidateToolAdvertisement(for event: DomainAgentSessionLinkChangeEvent) async {
        switch event.kind {
        case .activated, .revoked:
            if event.observerLinkSetRevision != nil,
               let observerSessionID = event.observerSessionID
            {
                await toolAdvertisementInvalidator(observerSessionID)
            }
            if let targetSessionID = event.targetSessionID {
                switch event.kind {
                case .activated:
                    let previous = inboundAdvertisementCountByTargetSession[targetSessionID] ?? 0
                    inboundAdvertisementCountByTargetSession[targetSessionID] = previous + 1
                    if previous == 0 {
                        await toolAdvertisementInvalidator(targetSessionID)
                    }
                case .revoked:
                    let previous = inboundAdvertisementCountByTargetSession[targetSessionID] ?? 1
                    let remaining = max(0, previous - 1)
                    inboundAdvertisementCountByTargetSession[targetSessionID] = remaining
                    if remaining == 0 {
                        inboundAdvertisementCountByTargetSession.removeValue(forKey: targetSessionID)
                        await toolAdvertisementInvalidator(targetSessionID)
                    }
                case .targetStateChanged, .draining, .shutdown:
                    break
                }
            }
        case .targetStateChanged, .draining, .shutdown:
            return
        }
    }

    /// Invalidates one observer's advertisement directly, without routing through the change feed.
    ///
    /// The feed is `bufferingNewest`, so a burst of authority events can drop the very event that
    /// would have refreshed `tools/list`. Every membership mutation already refreshes its projections
    /// inline; advertisement rides the same call so a dropped event cannot leave an observer
    /// permanently advertising the wrong tool set. Both paths are idempotent — the duplicate
    /// notification a delivered event produces is one redundant `tools/list`, whereas a lost one is
    /// stale until the next unrelated membership change.
    private func invalidateToolAdvertisement(forObserverSession sessionID: UUID) async {
        await toolAdvertisementInvalidator(sessionID)
    }

    #if DEBUG
        /// Test seam: drains any queued projection refresh so assertions observe settled state.
        func test_settleProjections() async {
            await requestProjectionRefresh()
        }

        /// Test seam: starts the authority change feed alone.
        ///
        /// `attach(host:)` also installs the process-wide invalidation sink and a Combine binding
        /// subscription, neither of which a focused bridge test wants. Starting just the feed lets a
        /// test exercise the real event dispatch path — scope selection and tool-advertisement
        /// invalidation — instead of reimplementing that routing in the test.
        func test_startChangeFeed() {
            startChangeFeedIfNeeded()
        }
    #endif

    // MARK: - Durable intent store

    /// Installs (or clears) the durable intent store this process uses.
    ///
    /// Idempotent and explicit. Called by app composition once the launch policy is known.
    func installIntentStore(_ store: AgentSessionOversightIntentStore?) {
        intentStore = store
        guard store == nil else { return }
        persistencePresentation = .noDurableLayer
        publishPersistencePresentation()
    }

    /// Bootstraps durable oversight for this launch: install the store, perform the one launch read,
    /// publish the resulting level, and seed the bounded automatic worklist.
    ///
    /// Deliberately independent of window-session restore. The manifest is loaded even when
    /// auto-restore is off — dormant intent must survive, not be silently discarded because the user
    /// turned window restoration off for one launch.
    func bootstrapIntentStore(_ store: AgentSessionOversightIntentStore) async {
        guard !isFrozenForTermination else { return }
        intentStore = store
        let mode = await store.persistenceMode
        // Rechecked after every hop. A bootstrap suspended on the store actor can resume *after* the
        // freeze, and resuming would otherwise install a fresh, unfrozen coordinator and seed it with
        // a launch worklist during shutdown.
        guard !isFrozenForTermination else { return }
        let result = await store.loadForLaunch()
        guard !isFrozenForTermination else { return }
        switch result {
        case .suppressed:
            persistencePresentation.availability = .suppressed
        case let .blocked(reason):
            persistencePresentation.availability = .blocked(
                AgentSessionOversightPersistenceCopy.message(for: reason)
            )
        case let .ready(load):
            persistencePresentation.availability = mode.allowsAutomaticRestore ? .ready : .dormant
            if load.source == .quarantined {
                persistencePresentation.appendWarning(
                    id: AgentSessionOversightWarningID.quarantined,
                    message: AgentSessionOversightPersistenceCopy.quarantined
                )
            }
            launchCoordinatorIfNeeded().loadLaunchEntries(
                load,
                automaticRestoreEnabled: mode.allowsAutomaticRestore
            )
        }
        publishPersistencePresentation()
        noteTopologyMayHaveChanged()
    }

    private func launchCoordinatorIfNeeded() -> AgentSessionOversightLaunchCoordinator {
        if let launchCoordinator { return launchCoordinator }
        let coordinator = AgentSessionOversightLaunchCoordinator(delegate: self)
        // Born frozen when the process already is. The freeze is a one-way latch on the bridge, so a
        // coordinator created afterwards has to inherit it rather than start a reconciliation drain
        // that quitting has no way to stop.
        if isFrozenForTermination { coordinator.freeze() }
        launchCoordinator = coordinator
        return coordinator
    }

    // MARK: - Persistence presentation

    /// Current durable-oversight level. Read by the owning window when it rebuilds Oversee props.
    var currentPersistencePresentation: AgentSessionOversightPersistencePresentation {
        persistencePresentation
    }

    private func publishPersistencePresentation() {
        persistencePresentation.hasPendingCleanupRetry = launchCoordinator?.hasPendingCleanup ?? false
        host?.agentSessionLinkPublishPersistencePresentation(persistencePresentation)
    }

    /// Records a bounded, identifier-free warning and repaints every window.
    func reportPersistenceWarning(id: String, message: String) {
        guard persistencePresentation.appendWarning(id: id, message: message) else {
            publishPersistencePresentation()
            return
        }
        publishPersistencePresentation()
    }

    /// Dismisses the app-level warnings the user is currently looking at.
    ///
    /// It never discards pending cleanup: the disk work is still owed, and **Retry saving** is how the
    /// user asks for it. Clearing the message must not clear the obligation.
    func dismissPersistenceWarnings(ids: Set<String>) {
        guard persistencePresentation.dismissWarnings(ids: ids) else { return }
        publishPersistencePresentation()
    }

    /// One of the few permitted cleanup retry triggers.
    func retryPendingIntentCleanup() async {
        guard !isFrozenForTermination else { return }
        await launchCoordinator?.retryPendingCleanup()
        publishPersistencePresentation()
    }

    // MARK: - Reconciliation triggers

    /// Re-reads the outer restore topology and marks launch reconciliation dirty.
    ///
    /// Called on attach, window registration/unregistration, restore-gate transitions, and discovery
    /// completion. The event never carries state; the coordinator always rereads the level snapshot.
    func noteTopologyMayHaveChanged() {
        guard !isFrozenForTermination, let launchCoordinator else { return }
        if let host {
            launchCoordinator.updateTopologyState(host.agentSessionLinkRestoreTopologyState())
        }
        launchCoordinator.markDirty()
    }

    /// An eligibility input changed with no authority event behind it.
    ///
    /// Two consumers: launch reconciliation (a waiting intent may now be establishable), and an eager
    /// re-audit of *existing* grants. The second matters because a session can lose the capability to
    /// oversee — MCP control attaching, the effective task-label role changing — without its endpoint
    /// identity changing at all, so neither the stale-endpoint sweep nor identity revalidation would
    /// ever notice.
    func noteCandidateReadinessChanged() {
        guard !isFrozenForTermination else { return }
        launchCoordinator?.markDirty()
        requestCandidatePresentationRefresh()
        guard !knownObserverEndpoints.isEmpty else { return }
        Task { @MainActor [weak self] in
            await self?.auditObserverEligibility()
        }
    }

    /// Revokes the outbound grants of every known observer that permanently lost the capability.
    ///
    /// Transient states (hydrating, rebinding) are deliberately left alone: revoking a healthy link
    /// every time the user reloads a thread would destroy exactly the relationship this feature
    /// exists to keep.
    private func auditObserverEligibility() async {
        guard !isFrozenForTermination, let host else { return }
        let live = host.agentSessionLinkCandidates()
        for endpoint in knownObserverEndpoints {
            guard let candidate = live.first(where: { $0.domainEndpoint == endpoint }) else { continue }
            guard AgentSessionLinkEndpointEligibility.observerOperationEligibility(
                candidate.eligibilityInput,
                roleAllowsOutboundMonitoring: candidate.roleAllowsOutboundMonitoring
            ) == .disqualified else {
                continue
            }
            await revokeOutboundLinks(
                observerEndpoint: candidate.domainEndpoint,
                reason: .observerNoLongerEligible
            )
        }
    }

    #if DEBUG
        /// Test seam: drains the launch coordinator's queued reconciliation.
        func test_settleLaunchReconciliation() async {
            await launchCoordinator?.settle()
        }

        func test_launchEntryState(
            for pair: AgentSessionOversightIntent
        ) -> AgentSessionOversightLaunchCoordinator.EntryState? {
            launchCoordinator?.state(for: pair)
        }

        func test_launchReservationStartCount() -> Int {
            launchCoordinator?.reservationStartCount ?? 0
        }

        /// Test seam: runs the eager observer-eligibility audit synchronously.
        ///
        /// `noteCandidateReadinessChanged()` fires it from a detached task because its callers are
        /// synchronous `didSet` hooks; a test needs it settled before asserting.
        func test_auditObserverEligibility() async {
            await auditObserverEligibility()
        }
    #endif

    /// Classifies whether persistence currently admits a mutation.
    ///
    /// `loadForLaunch()` is idempotent and reports the settled classification, so Add and Stop both
    /// observe exactly what the launch load decided rather than re-reading the file.
    private func intentPersistenceAdmission() async -> IntentPersistenceAdmission {
        guard let intentStore else { return .noDurableLayer }
        switch await intentStore.loadForLaunch() {
        case .ready:
            return .available(intentStore)
        case .suppressed:
            return .refused(AgentSessionOversightPersistenceCopy.suppressedLaunch)
        case let .blocked(reason):
            return .refused(AgentSessionOversightPersistenceCopy.message(for: reason))
        }
    }

    /// Whether this establishment's durable token is still the current one for its pair.
    ///
    /// Re-read at every authority hop. A token that stopped being current means a Stop, a lifecycle
    /// cleanup, or a deletion already retired this attempt, and it must not go on to reserve,
    /// activate, or keep a grant.
    private func tokenIsCurrent(_ token: AgentSessionOversightIntentToken?) async -> Bool {
        guard let token else { return true }
        guard let intentStore else { return false }
        return await intentStore.isCurrent(token)
    }

    /// Linearization fence between establishment and durable deletion.
    ///
    /// An attempt already in progress when establishment reaches a hop is reversible, so the same
    /// establishment waits for it rather than retiring intent. Failure resumes ordinary eligibility;
    /// commit returns `false`. The final state recheck is synchronous on MainActor, so a new attempt
    /// cannot begin between that check and this method returning.
    private func deletionFenceAllowsEstablishment(_ pair: AgentSessionOversightIntent) async -> Bool {
        let registry = AgentSessionDeletionRegistry.shared
        let sessionIDs = [pair.observerSessionID, pair.targetSessionID]
        while true {
            for sessionID in sessionIDs {
                if registry.isDeletionInProgress(sessionID: sessionID) {
                    _ = await registry.waitForDeletionAttemptToSettle(sessionID: sessionID)
                }
                if registry.isPermanentlyDeleted(sessionID: sessionID) { return false }
            }
            // An attempt can begin while the other endpoint's waiter was suspended. Loop until both
            // endpoints are simultaneously stable in one MainActor turn.
            if sessionIDs.contains(where: { registry.isDeletionInProgress(sessionID: $0) }) {
                continue
            }
            return !sessionIDs.contains(where: { registry.isPermanentlyDeleted(sessionID: $0) })
        }
    }

    // MARK: - Termination freeze and bounded settlement

    /// Whether the process has entered its synchronous termination freeze.
    var isFrozenForShutdown: Bool {
        isFrozenForTermination
    }

    /// One named, injectable total deadline for intent settlement. A shutdown bound, not a poll.
    ///
    /// `nonisolated` so it can serve as a default argument: a MainActor-isolated constant cannot be
    /// evaluated in the nonisolated context a default argument expression lives in.
    nonisolated static let defaultIntentSettlementSeconds: TimeInterval = 2

    /// Synchronous freeze. Idempotent, and safe to call from `applicationWillTerminate`.
    ///
    /// After this, no Add/Stop/cleanup is admitted, launch reconciliation stops, and every teardown
    /// callback is barred from deleting durable intent — quitting must preserve the user's saved
    /// oversight, not tear it down one window-close notification at a time.
    func freezeForTermination() {
        guard !isFrozenForTermination else { return }
        isFrozenForTermination = true
        // Presentation-only work is dropped rather than drained: a queued projection repaint has no
        // durable or agent-visible consequence, so nothing about quitting has to wait for it.
        pendingMonitorTargetEndpoints.removeAll()
        pendingMonitorObserverEndpoints.removeAll()
        monitorSeenByReference.removeAll()
        // Queued sends die with the process by design. They are pre-authorization for a delivery the
        // user is not present for, and quitting ends the turn that authorized them; nothing about a
        // queued message is expected back next launch.
        pendingSendsByReference.removeAll()
        pendingSendResultsByReference.removeAll()
        // Queued notices die with the process by design: they were only ever owed to a *future*
        // naturally started turn, and quitting means there is none.
        passiveNoticesByObserver.removeAll()
        monitorProjectionRefreshTask?.cancel()
        launchCoordinator?.freeze()
        // In-flight establishment is marked shutting-down. Cancellation is only the wake-up: none of
        // the authority or store calls below check it, so the fence that actually holds is the
        // freeze recheck every phase of `performFreshEstablishment` performs before it reserves,
        // activates, or reports success.
        for task in establishmentTasks.values {
            task.cancel()
        }
    }

    /// Waits, within one total deadline, for pre-freeze Add/Stop transactions to reach a settled
    /// durable state, then confirms the store's ordering.
    ///
    /// The deadline is total and the losing branch is never awaited: a transaction stuck behind a
    /// hung filesystem must not hold up quit. Anything unsettled is logged as a count and abandoned;
    /// the write-through store means every *reported* Add or Stop is already durable.
    func settleIntentTransactions(
        deadlineSeconds: TimeInterval = AgentSessionLinkRuntimeBridge.defaultIntentSettlementSeconds
    ) async {
        freezeForTermination()
        // One absolute deadline for the whole sequence, not one per phase. A non-registered store
        // operation — a launch cleanup, a deletion cleanup, a bootstrap load, or a writer already
        // occupying the store actor — could otherwise hold termination open indefinitely inside the
        // barrier, which is the one phase that has no work of its own to abandon.
        let deadline = Date().addingTimeInterval(max(0, deadlineSeconds))
        var reachedDeadline = false

        if !registeredTransactionIDs.isEmpty {
            let transactionsSettled = await awaitRegisteredTransactions(deadline: deadline)
            reachedDeadline = !transactionsSettled
        }
        if !reachedDeadline {
            // Exactly one retry of cleanup that was already queued before the freeze. Nothing new is
            // admitted here: `retryPendingCleanup` only walks entries that already owe a write.
            let cleanupSettled = await withinDeadline(deadline) { [weak self] in
                await self?.launchCoordinator?.retryPendingCleanup(ignoringFreeze: true)
            }
            reachedDeadline = !cleanupSettled
        }
        if !reachedDeadline {
            // Write-through, so this is a linearization point rather than a flush: it only confirms
            // that every operation registered before it crossed the store actor.
            let barrierSettled = await withinDeadline(deadline) { [weak self] in
                await self?.intentStore?.serializationBarrier()
            }
            reachedDeadline = !barrierSettled
        }
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "oversight.termination",
                fields: [
                    "outcome": reachedDeadline ? "deadline_reached" : "settled",
                    "unsettledTransactions": String(registeredTransactionIDs.count),
                    "pendingCleanup": String(launchCoordinator?.hasPendingCleanup == true ? 1 : 0)
                ]
            )
        #endif
    }

    /// Waits for every pre-freeze Add/Stop transaction, or gives up at the total deadline.
    ///
    /// - Returns: `false` when the deadline elapsed first.
    private func awaitRegisteredTransactions(deadline: Date) async -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        let timeout = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            } catch {
                return
            }
            self?.resumeIntentSettlement(timedOut: true)
        }
        let timedOut = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // Runs synchronously on MainActor before suspension, so this cannot miss a transaction
            // that finished between the check above and the store below.
            if registeredTransactionIDs.isEmpty {
                continuation.resume(returning: false)
            } else {
                intentSettlementContinuation = continuation
            }
        }
        timeout.cancel()
        return !timedOut
    }

    /// Runs one shutdown phase, abandoning it when the total deadline elapses first.
    ///
    /// The losing branch is never awaited and never structurally joined: a phase stuck behind a hung
    /// filesystem must not hold up quit, and the write-through store means everything already
    /// reported to the user is already durable.
    ///
    /// - Returns: `false` when the deadline elapsed before the phase completed.
    private func withinDeadline(
        _ deadline: Date,
        _ operation: @escaping @MainActor () async -> Void
    ) async -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        var timeout: Task<Void, Never>?
        let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = ShutdownPhaseGate(continuation)
            timeout = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                } catch {
                    return
                }
                gate.finish(false)
            }
            Task { @MainActor in
                await operation()
                gate.finish(true)
            }
        }
        timeout?.cancel()
        return completed
    }

    /// Registers one user-facing durable transaction for bounded shutdown settlement.
    private func registerTransaction() -> UUID {
        let id = UUID()
        registeredTransactionIDs.insert(id)
        return id
    }

    private func finishTransaction(_ id: UUID) {
        registeredTransactionIDs.remove(id)
        guard registeredTransactionIDs.isEmpty else { return }
        resumeIntentSettlement(timedOut: false)
    }

    /// One-shot, MainActor-guarded resume shared by the completion and deadline branches.
    private func resumeIntentSettlement(timedOut: Bool) {
        guard let continuation = intentSettlementContinuation else { return }
        intentSettlementContinuation = nil
        continuation.resume(returning: timedOut)
    }

    // MARK: - Durable-intent lifetime policy

    /// What one revocation reason means for the *saved* relationship.
    enum DurableIntentPolicy: Equatable {
        /// Quitting. The relationship is expected back next launch.
        case preserveIntent
        /// Any ordinary lifecycle end. v1 creates no invisible dormant subscriptions.
        case removeIntent
    }

    /// Exhaustive by design — deliberately no `default`.
    ///
    /// A new revocation reason must be classified explicitly: silently defaulting either way is the
    /// difference between losing a user's saved oversight and resurrecting one they ended.
    static func durableIntentPolicy(
        for reason: DomainAgentSessionLinkRevocationReason
    ) -> DurableIntentPolicy {
        switch reason {
        case .runtimeShutdown, .appTerminating:
            .preserveIntent
        case .userRequested,
             .observerEndpointInvalidated,
             .targetEndpointInvalidated,
             .observerIdentityDrift,
             .observerNoLongerEligible,
             .targetIdentityDrift,
             .tabClosed,
             .windowClosed,
             .workspaceSwitched,
             .bindingChanged,
             .sessionDeleted,
             .activationSeedFailed:
            .removeIntent
        }
    }

    /// Applies the durable-intent policy for a batch of revocations.
    ///
    /// Ordering is the security contract: the authority revocation already happened before this runs,
    /// so a disk failure here can never leave a live grant behind. Removal is always expected-token,
    /// captured with the reference before the authority call, so a stale owner cannot delete an intent
    /// a newer token reasserted.
    private func settleDurableIntent(
        after notices: [DomainAgentSessionLinkRevocationNotice],
        capturedBookkeeping: [DomainAgentSessionLinkReference: ReferenceBookkeeping]
    ) async {
        guard !notices.isEmpty else { return }
        for notice in notices {
            let reference = DomainAgentSessionLinkReference(
                linkID: notice.linkID,
                generation: notice.generation
            )
            // Read from the caller's *pre-hop* capture, never from the mutable table. Every
            // invalidation entry point crosses at least one reentrant actor hop before it gets here,
            // and a concurrent Stop, re-add, or rebind can remove or replace this reference's
            // bookkeeping in that window — leaving this owner to either skip its own removal or act
            // on a mapping newer work installed.
            let bookkeeping = capturedBookkeeping[reference]
            if let bookkeeping, bookkeepingByReference[reference] == bookkeeping {
                bookkeepingByReference.removeValue(forKey: reference)
            }
            guard let bookkeeping else { continue }
            guard Self.durableIntentPolicy(for: notice.reason) == .removeIntent else { continue }
            // Termination freeze overrides later teardown callbacks: quitting tears every window down,
            // and honouring those notices would erase exactly the state quit is meant to preserve.
            guard !isFrozenForTermination else { continue }
            guard let token = bookkeeping.token, let intentStore else {
                launchCoordinator?.noteRevocation(
                    pair: bookkeeping.pair,
                    assertedAt: bookkeeping.assertionGeneration,
                    preservesIntent: false
                )
                continue
            }

            #if DEBUG
                await test_beforeDurableIntentSettlement?(bookkeeping.pair)
            #endif
            // The authority hop happened before this method. Entering the same pair lane Add holds
            // prevents a later reassertion from interleaving with the write; the assertion generation
            // compares out a reassertion that already completed during that authority hop.
            let receipt = await withPairRetirementLane(bookkeeping.pair) {
                await intentStore.remove(
                    bookkeeping.pair,
                    ifCurrent: token,
                    assertedAt: bookkeeping.assertionGeneration
                )
            }
            switch receipt.outcome {
            case .applied, .unchanged, .absent:
                launchCoordinator?.noteRevocation(
                    pair: bookkeeping.pair,
                    assertedAt: bookkeeping.assertionGeneration,
                    preservesIntent: false
                )
            case .tokenMismatch:
                // Same-token explicit reassertion won. It owns both the durable row and any replacement
                // grant; stale lifecycle work must not terminalize either one.
                continue
            case .writeFailed, .blocked:
                // Authority stays revoked. The saved row survives and may be restored next launch, so
                // the user is told rather than left with a silent inconsistency.
                launchCoordinator?.noteRevocation(
                    pair: bookkeeping.pair,
                    assertedAt: bookkeeping.assertionGeneration,
                    preservesIntent: false
                )
                launchCoordinatorIfNeeded().noteCleanupPending(
                    pair: bookkeeping.pair,
                    token: token,
                    assertedAt: bookkeeping.assertionGeneration
                )
                reportPersistenceWarning(
                    id: AgentSessionOversightWarningID.cleanupFailed,
                    message: AgentSessionOversightPersistenceCopy.automaticCleanupFailed
                )
            }
        }
    }

    // MARK: - Durable deletion fence

    /// A session's durable deletion committed. Irreversible, so this never reports failure upward.
    ///
    /// Runtime authority is invalidated first and UUID-wide: the transcript is gone, so no incarnation
    /// of that UUID in any window may still be read through a grant. Only then is durable intent
    /// removed, and a disk failure there is recorded as a warning rather than pretending the deletion
    /// rolled back.
    private func handleCommittedSessionDeletion(_ sessionID: UUID) async {
        await invalidateSession(sessionID, reason: .sessionDeleted)
        guard !isFrozenForTermination, let intentStore else { return }
        // `removeAll` snapshots every attempted current token and assertion generation in the same
        // actor turn as the write. A separate read would leave a hop where an intervening row could be
        // missed by both the failed mutation and retry bookkeeping.
        let receipt = await intentStore.removeAll(containing: sessionID)
        for transition in receipt.transitions {
            // Committed deletion is process-lifetime authority, so it terminalizes unconditionally.
            launchCoordinator?.noteRevocation(
                pair: transition.pair,
                assertedAt: nil,
                preservesIntent: false
            )
        }
        switch receipt.outcome {
        case .writeFailed, .blocked:
            let coordinator = launchCoordinatorIfNeeded()
            for (pair, attempted) in receipt.attemptedCurrentByPair {
                coordinator.noteCleanupPending(
                    pair: pair,
                    token: attempted.token,
                    assertedAt: attempted.assertionGeneration
                )
            }
            reportPersistenceWarning(
                id: AgentSessionOversightWarningID.cleanupFailed,
                message: AgentSessionOversightPersistenceCopy.automaticCleanupFailed
            )
            publishPersistencePresentation()
        case .applied, .unchanged, .absent, .tokenMismatch:
            break
        }
    }

    /// Refuses both endpoints of a pair whose session is being, or has been, durably deleted.
    private static func deletionRefusal(for pair: AgentSessionOversightIntent) -> AgentMonitorAddOutcome? {
        let registry = AgentSessionDeletionRegistry.shared
        // Admission, not retirement: a running attempt refuses new oversight without implying the
        // session is gone, and only a committed tombstone ever ends a saved relationship.
        if registry.blocksNewOversight(sessionID: pair.observerSessionID) {
            return .rejected(message: AgentSessionLinkEndpointEligibility.roleDeniedReason)
        }
        if registry.blocksNewOversight(sessionID: pair.targetSessionID) {
            return .failed(.closing)
        }
        return nil
    }

    // MARK: - Pair lanes

    #if DEBUG
        /// Debug-only, opt-in `(pair, token)` lane transitions, shared with window/workspace restore
        /// instrumentation.
        ///
        /// Only the lane outcome and truncated endpoint prefixes are emitted. Full session UUIDs,
        /// session names, transcript content, delivered messages, and worktree/backup paths are never
        /// written here — this is the surface that carries another session's transcript, so its
        /// diagnostics stay strictly structural.
        private func logPairLane(pair: AgentSessionOversightIntent, outcome: String) {
            WorkspaceRestorePerfLog.event(
                "oversight.pairLane",
                fields: [
                    "outcome": outcome,
                    "observer": WorkspaceRestorePerfLog.shortID(pair.observerSessionID),
                    "target": WorkspaceRestorePerfLog.shortID(pair.targetSessionID)
                ]
            )
        }
    #endif

    /// Blocks until this pair has no in-flight retirement.
    ///
    /// Unbounded, because every durable removal for a pair now runs in this lane: a bounded spin
    /// would let an Add proceed while a later retirement was still installed, which is precisely the
    /// overlap the lane exists to prevent. Termination is unaffected — quitting freezes admission
    /// rather than waiting here.
    private func awaitPairRetirement(_ pair: AgentSessionOversightIntent) async {
        while let lane = pairRetirementBarriers[pair] {
            await lane.task.value
            // A lane releases itself before its task finishes, so a surviving entry is normally a
            // *newer* lane and must also be waited for. Finding the same identity means the release
            // was lost; clearing it here is the only branch that could otherwise spin.
            guard pairRetirementBarriers[pair]?.id != lane.id else {
                pairRetirementBarriers.removeValue(forKey: pair)
                return
            }
        }
    }

    /// Runs one pair-exclusive durable mutation as this pair's retirement lane.
    ///
    /// Every durable removal a pair can suffer — user Stop, automatic launch retirement, and the
    /// **Retry saving** cleanup — goes through here, and Add holds the same lane across its insert.
    /// Without that, a cleanup already suspended on the store actor would still commit its
    /// expected-token removal after an explicit Add reused the very token it holds, deleting the
    /// intent the user just reasserted.
    private func withPairRetirementLane<T: Sendable>(
        _ pair: AgentSessionOversightIntent,
        operation: @escaping @MainActor () async -> T
    ) async -> T {
        await awaitPairRetirement(pair)
        let id = UUID()
        let work = Task { @MainActor [weak self] in
            let value = await operation()
            self?.releasePairRetirementLane(pair, id: id)
            return value
        }
        // Installed synchronously, before the first suspension, so a concurrent caller can never
        // observe an unlaned window between the lane's creation and its registration.
        pairRetirementBarriers[pair] = PairRetirementLane(
            id: id,
            task: Task { @MainActor in _ = await work.value }
        )
        return await work.value
    }

    private func releasePairRetirementLane(_ pair: AgentSessionOversightIntent, id: UUID) {
        guard pairRetirementBarriers[pair]?.id == id else { return }
        pairRetirementBarriers.removeValue(forKey: pair)
    }

    /// Runs one complete Add or restoration at a time for a semantic UUID pair.
    ///
    /// The retirement lane alone cannot provide this ownership boundary because it deliberately ends
    /// after durable insertion. This lane remains held through authority establishment and any outer
    /// compensation, so another incarnation cannot reassert the token or reserve a sibling grant in
    /// the gap before the first relationship becomes active.
    private func withPairEstablishmentLane<T: Sendable>(
        _ pair: AgentSessionOversightIntent,
        operation: @escaping @MainActor () async -> T
    ) async -> T {
        while let lane = pairEstablishmentBarriers[pair] {
            #if DEBUG
                await test_beforePairEstablishmentWait?(pair)
            #endif
            await lane.task.value
            guard pairEstablishmentBarriers[pair]?.id != lane.id else {
                pairEstablishmentBarriers.removeValue(forKey: pair)
                break
            }
        }
        let id = UUID()
        let work = Task { @MainActor [weak self] in
            let value = await operation()
            self?.releasePairEstablishmentLane(pair, id: id)
            return value
        }
        pairEstablishmentBarriers[pair] = PairEstablishmentLane(
            id: id,
            task: Task { @MainActor in _ = await work.value }
        )
        return await work.value
    }

    private func releasePairEstablishmentLane(_ pair: AgentSessionOversightIntent, id: UUID) {
        guard pairEstablishmentBarriers[pair]?.id == id else { return }
        pairEstablishmentBarriers.removeValue(forKey: pair)
    }

    /// Starts or joins the `(pair, token)` establishment.
    private func establish(
        pair: AgentSessionOversightIntent,
        token: AgentSessionOversightIntentToken?,
        assertedAt generation: UInt64?,
        proof: AgentSessionOversightRestorationProof? = nil,
        expectedEndpoints: AddEndpointExpectations = AddEndpointExpectations(observer: nil, target: nil)
    ) async -> EstablishmentResult {
        let key = EstablishmentKey(
            pair: pair,
            token: token,
            expectedEndpoints: expectedEndpoints
        )
        if let existing = establishmentTasks[key] {
            #if DEBUG
                logPairLane(pair: pair, outcome: "joined")
            #endif
            let result = await validateCompletedEstablishment(
                existing.value,
                pair: pair,
                token: token,
                expectedEndpoints: expectedEndpoints,
                preserveOnExpectationMismatch: true
            )
            // Same-token explicit assertions join one establishment. Adopt the newer assertion only
            // after the older task finished writing its bookkeeping, so it cannot overwrite us.
            if result.outcome.failureMessage == nil, let reference = result.reference {
                bookkeepingByReference[reference] = ReferenceBookkeeping(
                    pair: pair,
                    token: token,
                    assertionGeneration: generation
                )
            }
            return result
        }
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return EstablishmentResult(outcome: .rejected(message: Self.unavailableMessage))
            }
            return await performFreshEstablishment(
                pair: pair,
                token: token,
                assertedAt: generation,
                proof: proof,
                expectedEndpoints: expectedEndpoints
            )
        }
        establishmentTasks[key] = task
        #if DEBUG
            logPairLane(pair: pair, outcome: "inserted")
        #endif
        let outcome = await validateCompletedEstablishment(
            task.value,
            pair: pair,
            token: token,
            expectedEndpoints: expectedEndpoints,
            preserveOnExpectationMismatch: false
        )
        if establishmentTasks[key] == task {
            establishmentTasks.removeValue(forKey: key)
        }
        return outcome
    }

    /// Final caller-side fence after the retained task completes.
    ///
    /// Task completion and the awaiting continuation are distinct MainActor turns. Stop, deletion, or
    /// termination can settle the grant between them, so no caller may report the cached success
    /// without re-proving current token, deletion admission, freeze, and exact reference ownership.
    private func validateCompletedEstablishment(
        _ result: EstablishmentResult,
        pair: AgentSessionOversightIntent,
        token: AgentSessionOversightIntentToken?,
        expectedEndpoints: AddEndpointExpectations,
        preserveOnExpectationMismatch: Bool
    ) async -> EstablishmentResult {
        guard result.outcome.failureMessage == nil, let reference = result.reference else { return result }
        if !expectedEndpoints.isEmpty {
            guard let observerEndpoint = result.observerEndpoint,
                  let targetEndpoint = result.targetEndpoint,
                  expectedEndpoints.matches(observer: observerEndpoint, target: targetEndpoint)
            else {
                if preserveOnExpectationMismatch || result.isAlreadyLinked {
                    return EstablishmentResult(
                        outcome: .failed(.rebinding),
                        preservesDurableIntentOnFailure: true
                    )
                }
                await revoke(reference: reference, settlesDurableIntent: false)
                return EstablishmentResult(outcome: .failed(.rebinding))
            }
        }
        guard await deletionFenceAllowsEstablishment(pair) else {
            await revoke(
                reference: reference,
                reason: .sessionDeleted,
                settlesDurableIntent: false
            )
            return EstablishmentResult(outcome: .failed(.closing))
        }
        guard await tokenIsCurrent(token) else {
            await revoke(reference: reference, settlesDurableIntent: false)
            return EstablishmentResult(outcome: .rejected(message: Self.retiredMessage))
        }
        let registry = AgentSessionDeletionRegistry.shared
        guard !isFrozenForTermination,
              !registry.blocksNewOversight(sessionID: pair.observerSessionID),
              !registry.blocksNewOversight(sessionID: pair.targetSessionID),
              let bookkeeping = bookkeepingByReference[reference],
              bookkeeping.pair == pair,
              bookkeeping.token == token
        else {
            await revoke(
                reference: reference,
                reason: isFrozenForTermination ? .appTerminating : .sessionDeleted,
                settlesDurableIntent: false
            )
            return EstablishmentResult(outcome: .rejected(message: Self.retiredMessage))
        }
        if !expectedEndpoints.isEmpty,
           !liveCandidatesStillMatch(expectedEndpoints, pair: pair)
        {
            if preserveOnExpectationMismatch || result.isAlreadyLinked {
                return EstablishmentResult(
                    outcome: .failed(.rebinding),
                    preservesDurableIntentOnFailure: true
                )
            }
            await revoke(reference: reference, settlesDurableIntent: false)
            return EstablishmentResult(outcome: .failed(.rebinding))
        }
        return result
    }

    /// Waits for one exact `(pair, token)` establishment to finish, without starting one.
    private func settleEstablishment(
        pair: AgentSessionOversightIntent,
        token: AgentSessionOversightIntentToken?
    ) async {
        let tasks = establishmentTasks.compactMap { key, task in
            key.pair == pair && key.token == token ? task : nil
        }
        for task in tasks {
            _ = await task.value
        }
    }

    // MARK: - Add

    /// Durable-intent transaction around one user-authorized Add.
    ///
    /// Ordering is the contract: persistence commits *before* the reservation, so a reported Add
    /// always implies a committed insert, and a crash between the two can only leave an intent that
    /// the next launch re-derives from scratch — never a grant with no durable record. Everything
    /// after the insert runs through the same fresh authorization path automatic restoration uses.
    func addMonitorLink(
        observerSessionID: UUID,
        rawTargetSessionID: String
    ) async -> AgentMonitorAddOutcome {
        guard host != nil else { return .rejected(message: Self.unavailableMessage) }
        // Freeze is checked before anything is parsed: the honest answer during shutdown is that
        // nothing changed, not a resolution error the user might act on.
        guard !isFrozenForTermination else {
            return .rejected(message: AgentSessionOversightPersistenceCopy.shutdownBeforeInsert)
        }
        guard let targetSessionID = AgentSessionLinkEndpointResolver.parseSessionID(rawTargetSessionID) else {
            return .failed(.malformedIdentifier)
        }
        guard targetSessionID != observerSessionID else { return .failed(.selfMonitor) }
        return await addMonitorLink(
            pair: AgentSessionOversightIntent(
                observerSessionID: observerSessionID,
                targetSessionID: targetSessionID
            )
        )
    }

    /// Exact endpoint Add used by target-centric relationship management.
    ///
    /// This is only an addressing overload. Persistence, pair serialization, reservation, seed,
    /// activation, compensation, and publication all remain owned by the shared durable core below.
    func addMonitorLink(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) async -> AgentMonitorAddOutcome {
        await addMonitorLink(
            pair: AgentSessionOversightIntent(
                observerSessionID: observerEndpoint.sessionID,
                targetSessionID: targetEndpoint.sessionID
            ),
            expectedObserverEndpoint: observerEndpoint,
            expectedTargetEndpoint: targetEndpoint
        )
    }

    /// Exact endpoint Add from the target-centric sidebar menu.
    ///
    /// Unlike general Add, this may only extend an exact observer that still holds authority for at
    /// least one outbound link. The same authority that projects the menu enforces the precondition
    /// again at reservation and activation, closing a stale-menu race without preventing other
    /// surfaces from creating an observer's first link.
    func addSidebarMonitorLink(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) async -> AgentMonitorAddOutcome {
        await addMonitorLink(
            pair: AgentSessionOversightIntent(
                observerSessionID: observerEndpoint.sessionID,
                targetSessionID: targetEndpoint.sessionID
            ),
            expectedObserverEndpoint: observerEndpoint,
            expectedTargetEndpoint: targetEndpoint,
            requiresExistingOutboundLink: true
        )
    }

    /// Complete durable Add transaction for one canonical pair.
    ///
    /// Passing neither exact endpoint preserves pasted-ID Add and launch-restoration behavior.
    /// Passing expectations adds fail-closed incarnation fences without bypassing any persistence,
    /// pair-lane, reservation, activation, publication, invalidation, or compensation step.
    func addMonitorLink(
        pair: AgentSessionOversightIntent,
        expectedObserverEndpoint: DomainAgentSessionLinkEndpointIdentity? = nil,
        expectedTargetEndpoint: DomainAgentSessionLinkEndpointIdentity? = nil,
        requiresExistingOutboundLink: Bool = false
    ) async -> AgentMonitorAddOutcome {
        let expectedEndpoints = AddEndpointExpectations(
            observer: expectedObserverEndpoint,
            target: expectedTargetEndpoint,
            requiresExistingOutboundLink: requiresExistingOutboundLink
        )
        return await withPairEstablishmentLane(pair) { [weak self] in
            guard let self else {
                return .rejected(message: Self.unavailableMessage)
            }
            return await performAddMonitorLink(
                pair: pair,
                expectedEndpoints: expectedEndpoints
            )
        }
    }

    private func performAddMonitorLink(
        pair: AgentSessionOversightIntent,
        expectedEndpoints: AddEndpointExpectations
    ) async -> AgentMonitorAddOutcome {
        guard host != nil else { return .rejected(message: Self.unavailableMessage) }
        guard !isFrozenForTermination else {
            return .rejected(message: AgentSessionOversightPersistenceCopy.shutdownBeforeInsert)
        }
        guard pair.observerSessionID != pair.targetSessionID else { return .failed(.selfMonitor) }
        // A deleted transcript is not an oversight endpoint, however live its tab still looks: the
        // view-model teardown that removes it from the candidate sweep runs several awaits after the
        // file is gone.
        if let refusal = Self.deletionRefusal(for: pair) { return refusal }

        let transaction = registerTransaction()
        defer { finishTransaction(transaction) }

        let store: AgentSessionOversightIntentStore?
        switch await intentPersistenceAdmission() {
        case .noDurableLayer:
            store = nil
        case let .available(value):
            store = value
        case let .refused(message):
            // Persistence failure blocks the action outright: a session-only link that silently
            // disappears on the next launch is worse than a refusal the user can act on.
            return .rejected(message: message)
        }

        // Token B may not reserve until token A's removal and establishment have settled, and the
        // insert itself runs *inside* the lane: an automatic cleanup suspended on the store actor
        // would otherwise commit its expected-token removal after this Add reused that same token.
        let insertion = await withPairRetirementLane(pair) { [weak self] () -> AddInsertion in
            guard let self else {
                return .refused(.rejected(message: Self.unavailableMessage))
            }
            // Rechecked inside the lane: a freeze can land while an older retirement settles, and
            // the honest answer then is that nothing changed.
            guard !isFrozenForTermination else {
                return .refused(
                    .rejected(message: AgentSessionOversightPersistenceCopy.shutdownBeforeInsert)
                )
            }
            // Preflight the live resolver before writing anything. This is for the popover's precise
            // messages only — it is not authorization, and the shared path below re-resolves
            // everything.
            if let refusal = preflightAddRefusal(
                pair: pair,
                expectedEndpoints: expectedEndpoints
            ) {
                return .refused(refusal)
            }
            if await activePairUsesDifferentExpectedEndpoints(
                pair: pair,
                expectedEndpoints: expectedEndpoints
            ) {
                return .refused(.failed(.rebinding))
            }
            if expectedEndpoints.requiresExistingOutboundLink {
                guard let observerEndpoint = expectedEndpoints.observer,
                      await authority.hasActiveOutboundLink(observerEndpoint: observerEndpoint)
                else {
                    return .refused(.rejected(message: Self.existingOverseerRequiredMessage))
                }
            }
            guard let store else {
                return .inserted(
                    token: nil,
                    assertionGeneration: nil,
                    insertedDurableIntent: false
                )
            }
            let receipt = await store.insert(pair)
            switch receipt.outcome {
            case .applied, .unchanged:
                // Idempotent: an existing pair reuses its token rather than superseding it, so an
                // explicit Add of a launch-loaded pair joins that token instead of racing it.
                guard let token = receipt.token(for: pair),
                      let assertionGeneration = receipt.assertionGeneration
                else {
                    return .refused(.rejected(message: AgentSessionOversightPersistenceCopy.unreadable))
                }
                #if DEBUG
                    if receipt.outcome == .unchanged { logPairLane(pair: pair, outcome: "reused") }
                #endif
                // Retires any failed automatic cleanup for this pair, still holding the lane: the
                // user has reasserted it, so neither a queued **Retry saving** nor a launch
                // retirement may delete what they just recreated.
                launchCoordinator?.noteInteractiveTokenChange(
                    pair: pair,
                    token: token,
                    assertedAt: assertionGeneration
                )
                return .inserted(
                    token: token,
                    assertionGeneration: assertionGeneration,
                    insertedDurableIntent: receipt.outcome == .applied
                )
            case .writeFailed:
                return .refused(.rejected(message: AgentSessionOversightPersistenceCopy.addWriteFailed))
            case .blocked, .absent, .tokenMismatch:
                return .refused(.rejected(message: AgentSessionOversightPersistenceCopy.unreadable))
            }
        }
        let token: AgentSessionOversightIntentToken?
        let assertionGeneration: UInt64?
        let insertedDurableIntent: Bool
        switch insertion {
        case let .refused(refusal):
            return refusal
        case let .inserted(value, generation, inserted):
            token = value
            assertionGeneration = generation
            insertedDurableIntent = inserted
        }

        // The insert is committed. A freeze that lands now preserves the token for the next launch
        // rather than compensating it away: the user's request is durable, it just cannot start here.
        if isFrozenForTermination {
            return .rejected(message: AgentSessionOversightPersistenceCopy.shutdownAfterInsert)
        }
        publishPersistencePresentation()

        let establishment = await establish(
            pair: pair,
            token: token,
            assertedAt: assertionGeneration,
            expectedEndpoints: expectedEndpoints
        )
        let outcome = establishment.outcome
        guard !establishment.preservesDurableIntentOnFailure else { return outcome }
        // An idempotent `.unchanged` insertion reasserted a row that predates this attempt. A later
        // transient resolution failure must never compensate that existing durable relationship away.
        guard insertedDurableIntent else { return outcome }
        guard outcome.failureMessage != nil, let store, let token else { return outcome }
        // Shutdown is not a failure that owes a compensation — see above.
        guard !isFrozenForTermination else {
            return .rejected(message: AgentSessionOversightPersistenceCopy.shutdownAfterInsert)
        }

        // Compensation is expected-token *and* laned: a concurrent re-add's token B must survive this
        // failure, and a launch cleanup must not interleave with it.
        let compensation = await withPairRetirementLane(pair) { [store, pair, token, assertionGeneration] in
            await store.remove(pair, ifCurrent: token, assertedAt: assertionGeneration)
        }
        switch compensation.outcome {
        case .writeFailed, .blocked:
            reportPersistenceWarning(
                id: AgentSessionOversightWarningID.compensationFailed,
                message: AgentSessionOversightPersistenceCopy.addCompensationFailed
            )
            launchCoordinatorIfNeeded().noteCleanupPending(
                pair: pair,
                token: token,
                assertedAt: assertionGeneration
            )
            publishPersistencePresentation()
            return .rejected(message: AgentSessionOversightPersistenceCopy.addCompensationFailed)
        case .tokenMismatch:
            // A newer explicit Add reasserted the same token while this failed establishment was
            // compensating. Its durable row and coordinator entry belong to that newer assertion.
            return outcome
        case .applied, .unchanged, .absent:
            launchCoordinator?.noteInteractiveTokenChange(
                pair: pair,
                token: nil,
                assertedAt: assertionGeneration
            )
            publishPersistencePresentation()
            return outcome
        }
    }

    /// Best-effort one-level inheritance of a parent's authority-active outbound targets.
    ///
    /// The single authority projection read is the membership linearization point. Every target is
    /// then re-resolved and added sequentially through the complete durable Add transaction with
    /// exact child/target endpoint constraints. Failures are isolated per target and successful
    /// grants are never rolled back.
    func inheritActiveOutboundTargets(
        from parentEndpoint: DomainAgentSessionLinkEndpointIdentity,
        to childEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) async -> AgentSessionLinkForkInheritanceSummary {
        guard !isFrozenForTermination,
              parentEndpoint != childEndpoint,
              let host
        else {
            return .empty
        }

        let initialCandidates = host.agentSessionLinkCandidates()
        guard inheritanceObserverCandidate(
            endpoint: parentEndpoint,
            candidates: initialCandidates
        ) != nil,
            inheritanceObserverCandidate(
                endpoint: childEndpoint,
                candidates: initialCandidates
            ) != nil
        else {
            return .empty
        }

        let inputs = await authority.projectionInputs(forEndpoint: parentEndpoint)
        guard !isFrozenForTermination, let host = self.host else { return .empty }
        let confirmedCandidates = host.agentSessionLinkCandidates()
        guard inheritanceObserverCandidate(
            endpoint: parentEndpoint,
            candidates: confirmedCandidates
        ) != nil,
            inheritanceObserverCandidate(
                endpoint: childEndpoint,
                candidates: confirmedCandidates
            ) != nil
        else {
            return .empty
        }

        let frozenTargets = inputs.outbound.items
            .map { item in
                (
                    sessionID: item.targetSessionID,
                    endpoint: inputs.outboundTargetEndpoints[item.linkID]
                )
            }
            .sorted { lhs, rhs in
                lhs.sessionID.uuidString < rhs.sessionID.uuidString
            }

        var addedCount = 0
        var alreadyLinkedCount = 0
        var skippedCount = 0
        for (index, frozen) in frozenTargets.enumerated() {
            if Task.isCancelled || isFrozenForTermination {
                skippedCount += frozenTargets.count - index
                break
            }
            guard let expectedTargetEndpoint = frozen.endpoint,
                  expectedTargetEndpoint.sessionID == frozen.sessionID,
                  let host = self.host
            else {
                skippedCount += 1
                continue
            }

            let candidates = host.agentSessionLinkCandidates()
            guard inheritanceObserverCandidate(
                endpoint: childEndpoint,
                candidates: candidates
            ) != nil,
                case let .success(target) = AgentSessionLinkEndpointResolver.resolve(
                    sessionID: frozen.sessionID,
                    candidates: candidates
                ),
                target.domainEndpoint == expectedTargetEndpoint
            else {
                skippedCount += 1
                continue
            }

            let outcome = await addMonitorLink(
                pair: AgentSessionOversightIntent(
                    observerSessionID: childEndpoint.sessionID,
                    targetSessionID: frozen.sessionID
                ),
                expectedObserverEndpoint: childEndpoint,
                expectedTargetEndpoint: expectedTargetEndpoint
            )
            switch outcome {
            case .added:
                addedCount += 1
            case .alreadyLinked:
                alreadyLinkedCount += 1
            case .failed, .rejected:
                skippedCount += 1
            }
        }

        return AgentSessionLinkForkInheritanceSummary(
            consideredCount: frozenTargets.count,
            addedCount: addedCount,
            alreadyLinkedCount: alreadyLinkedCount,
            skippedCount: skippedCount
        )
    }

    private func inheritanceObserverCandidate(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        candidates: [AgentSessionLinkEndpointCandidate]
    ) -> AgentSessionLinkEndpointCandidate? {
        guard let candidate = candidates.first(where: { $0.domainEndpoint == endpoint }),
              AgentSessionLinkEndpointEligibility.addDisabledReason(
                  candidate.eligibilityInput,
                  roleAllowsOutboundMonitoring: candidate.roleAllowsOutboundMonitoring
              ) == nil
        else {
            return nil
        }
        return candidate
    }

    /// The durable half of one Add, decided while holding the pair lane.
    private enum AddInsertion {
        case inserted(
            token: AgentSessionOversightIntentToken?,
            assertionGeneration: UInt64?,
            insertedDurableIntent: Bool
        )
        case refused(AgentMonitorAddOutcome)
    }

    /// Detects a UUID-identical active pair owned by another exact observer/target incarnation.
    ///
    /// This runs inside the pair lane and before durable insertion. The endpoint-scoped projection
    /// proves whether the expected observer owns the pair; the UUID inventory detects an active pair
    /// that exists elsewhere. A later race is still fenced in fresh establishment.
    private func activePairUsesDifferentExpectedEndpoints(
        pair: AgentSessionOversightIntent,
        expectedEndpoints: AddEndpointExpectations
    ) async -> Bool {
        guard let expectedObserver = expectedEndpoints.observer else { return false }
        let exactInputs = await authority.projectionInputs(forEndpoint: expectedObserver)
        if let item = exactInputs.outbound.items.first(where: {
            $0.targetSessionID == pair.targetSessionID
        }) {
            guard let exactTarget = exactInputs.outboundTargetEndpoints[item.linkID] else { return true }
            return expectedEndpoints.target.map { $0 != exactTarget } ?? false
        }
        let sessionInventory = await authority.links(forObserver: pair.observerSessionID)
        return sessionInventory.items.contains { $0.targetSessionID == pair.targetSessionID }
    }

    /// Resolves one Add endpoint by the caller's addressing mode.
    ///
    /// Pasted-ID and restoration callers retain the fail-closed UUID ambiguity contract. Exact
    /// callers may select one presented incarnation from that ambiguous set, but only when the full
    /// endpoint identity still exists exactly once and remains target-eligible. A same-UUID
    /// replacement therefore reports rebinding instead of being silently adopted.
    private func resolveAddCandidate(
        sessionID: UUID,
        expectedEndpoint: DomainAgentSessionLinkEndpointIdentity?,
        candidates: [AgentSessionLinkEndpointCandidate]
    ) -> Result<AgentSessionLinkEndpointCandidate, AgentSessionLinkResolveFailure> {
        guard let expectedEndpoint else {
            return AgentSessionLinkEndpointResolver.resolve(
                sessionID: sessionID,
                candidates: candidates
            )
        }
        guard expectedEndpoint.sessionID == sessionID else { return .failure(.rebinding) }
        let sessionMatches = candidates.filter { $0.sessionID == sessionID }
        guard !sessionMatches.isEmpty else { return .failure(.notFound) }
        let exactMatches = sessionMatches.filter { $0.domainEndpoint == expectedEndpoint }
        guard !exactMatches.isEmpty else { return .failure(.rebinding) }
        guard exactMatches.count == 1 else { return .failure(.ambiguous) }
        let match = exactMatches[0]
        if let failure = AgentSessionLinkEndpointEligibility.targetResolveFailure(for: match) {
            return .failure(failure)
        }
        return .success(match)
    }

    /// Live resolver/eligibility preflight, phrased exactly as the popover renders it.
    private func preflightAddRefusal(
        pair: AgentSessionOversightIntent,
        expectedEndpoints: AddEndpointExpectations = AddEndpointExpectations(observer: nil, target: nil)
    ) -> AgentMonitorAddOutcome? {
        guard let host else { return .rejected(message: Self.unavailableMessage) }
        if let refusal = Self.deletionRefusal(for: pair) { return refusal }
        let candidates = host.agentSessionLinkCandidates()
        let observer: AgentSessionLinkEndpointCandidate
        switch resolveAddCandidate(
            sessionID: pair.observerSessionID,
            expectedEndpoint: expectedEndpoints.observer,
            candidates: candidates
        ) {
        case let .success(resolved):
            observer = resolved
        case let .failure(failure):
            return .rejected(message: Self.observerMessage(for: failure))
        }
        if let reason = AgentSessionLinkEndpointEligibility.addDisabledReason(
            observer.eligibilityInput,
            roleAllowsOutboundMonitoring: observer.roleAllowsOutboundMonitoring
        ) {
            return .rejected(message: reason)
        }
        let target: AgentSessionLinkEndpointCandidate
        switch resolveAddCandidate(
            sessionID: pair.targetSessionID,
            expectedEndpoint: expectedEndpoints.target,
            candidates: candidates
        ) {
        case let .success(resolved):
            target = resolved
        case let .failure(failure):
            return .failed(failure)
        }
        guard expectedEndpoints.matches(
            observer: observer.domainEndpoint,
            target: target.domainEndpoint
        ) else {
            return .failed(.rebinding)
        }
        return nil
    }

    // MARK: - Shared fresh establishment

    /// The single fresh authorization path, shared by manual Add and automatic launch restoration.
    ///
    /// Nothing may bypass or reorder it: candidate snapshot, unique observer resolution, observer
    /// eligibility and role policy, self-link rejection, unique target resolution, non-authorizing
    /// reservation, collateral revocation reconciliation, a fresh exact-incarnation reread, the
    /// synchronous sanitized seed, the prompt-inventory hold, activation, hold release with the
    /// authority-returned inventory, and observation install/projection refresh/advertisement
    /// invalidation.
    ///
    /// A durable pair is never authority: knowing a `(observer, target)` UUID pair grants nothing,
    /// which is why restoration enters here rather than reconstructing a grant from what it read.
    ///
    /// The seed snapshot is built synchronously on MainActor between reservation and activation. If
    /// seeding is impossible or either identity drifts, the reservation is rolled back and no active
    /// link is ever visible in an uninitialized state.
    /// - Parameter proof: the exact incarnations and binding-qualified hydration outcomes an
    ///   automatic restoration was classified against, or `nil` for a manual Add. Restoration adds
    ///   this precondition on top of the shared path rather than beside it: the resolver deliberately
    ///   gates on the legacy `hasLoadedPersistedState` latch, which is also true for a missing
    ///   payload, a superseded revision, and a thrown load error, so re-deriving readiness here would
    ///   authorize exactly the state the proof exists to exclude.
    private func performFreshEstablishment(
        pair: AgentSessionOversightIntent,
        token: AgentSessionOversightIntentToken?,
        assertedAt assertionGeneration: UInt64?,
        proof: AgentSessionOversightRestorationProof? = nil,
        expectedEndpoints: AddEndpointExpectations = AddEndpointExpectations(observer: nil, target: nil)
    ) async -> EstablishmentResult {
        guard let host else {
            return EstablishmentResult(outcome: .rejected(message: Self.unavailableMessage))
        }
        // Re-read rather than trusted from the caller's preflight: a deletion can commit while an Add
        // is resolving, and restoration enters here without a preflight at all.
        if let refusal = Self.deletionRefusal(for: pair) { return EstablishmentResult(outcome: refusal) }
        guard !isFrozenForTermination else {
            return EstablishmentResult(
                outcome: .rejected(message: AgentSessionOversightPersistenceCopy.shutdownBeforeInsert)
            )
        }
        let observerSessionID = pair.observerSessionID
        let targetSessionID = pair.targetSessionID

        let candidates = host.agentSessionLinkCandidates()
        let observer: AgentSessionLinkEndpointCandidate
        switch resolveAddCandidate(
            sessionID: observerSessionID,
            expectedEndpoint: expectedEndpoints.observer,
            candidates: candidates
        ) {
        case let .success(resolved):
            observer = resolved
        case let .failure(failure):
            return EstablishmentResult(outcome: .rejected(message: Self.observerMessage(for: failure)))
        }
        if let reason = AgentSessionLinkEndpointEligibility.addDisabledReason(
            observer.eligibilityInput,
            roleAllowsOutboundMonitoring: observer.roleAllowsOutboundMonitoring
        ) {
            return EstablishmentResult(outcome: .rejected(message: reason))
        }
        guard targetSessionID != observerSessionID else {
            return EstablishmentResult(outcome: .failed(.selfMonitor))
        }

        let target: AgentSessionLinkEndpointCandidate
        switch resolveAddCandidate(
            sessionID: targetSessionID,
            expectedEndpoint: expectedEndpoints.target,
            candidates: candidates
        ) {
        case let .success(resolved):
            target = resolved
        case let .failure(failure):
            return EstablishmentResult(outcome: .failed(failure))
        }

        // First restoration/expectation fence: the incarnations resolved here must be byte-for-byte
        // the ones the caller proved before entering this transaction.
        if let proof, !proof.matches(observer: observer, target: target) {
            return EstablishmentResult(outcome: .failed(.rebinding))
        }
        guard expectedEndpoints.matches(
            observer: observer.domainEndpoint,
            target: target.domainEndpoint
        ) else {
            return EstablishmentResult(outcome: .failed(.rebinding))
        }

        // Last check before the first authority mutation: a Stop that committed while this task was
        // resolving must not be followed by a reservation for the token it just retired.
        guard await tokenIsCurrent(token) else {
            return EstablishmentResult(outcome: .rejected(message: Self.retiredMessage))
        }
        guard await deletionFenceAllowsEstablishment(pair) else {
            return EstablishmentResult(outcome: .failed(.closing))
        }
        guard !isFrozenForTermination else {
            return EstablishmentResult(
                outcome: .rejected(message: AgentSessionOversightPersistenceCopy.shutdownBeforeInsert)
            )
        }

        let observerEndpoint = observer.domainEndpoint
        let targetEndpoint = target.domainEndpoint
        // Exact callers add one more incarnation fence immediately before reservation. Ordinary
        // Add/restoration pass no expectations and retain their existing candidate-read count.
        if !expectedEndpoints.isEmpty,
           !liveCandidatesStillMatch(expectedEndpoints, pair: pair)
        {
            return EstablishmentResult(outcome: .failed(.rebinding))
        }
        let capturedBookkeeping = bookkeepingByReference
        let reservation: DomainAgentSessionLinkPendingReservation
        var collateralRevocations: [DomainAgentSessionLinkRevocationNotice] = []
        switch await authority.reserveLink(
            observer: observerEndpoint,
            target: targetEndpoint,
            requiresExistingOutboundLink: expectedEndpoints.requiresExistingOutboundLink
        ) {
        case let .reserved(pending, collateral):
            reservation = pending
            collateralRevocations = collateral
            // Registered immediately, before activation: a Stop or lifecycle owner that arrives
            // while this reservation is in flight has to be able to recognize it as *this* token's
            // work rather than guessing.
            bookkeepingByReference[Self.reference(for: pending)] = ReferenceBookkeeping(
                pair: pair,
                token: token,
                assertionGeneration: assertionGeneration
            )
            #if DEBUG
                await test_afterReservationBeforeActivation?(pair)
            #endif
            guard await deletionFenceAllowsEstablishment(pair) else {
                await authority.abandonReservation(pending)
                bookkeepingByReference.removeValue(forKey: Self.reference(for: pending))
                return EstablishmentResult(outcome: .failed(.closing))
            }
        case let .existing(grant):
            let reference = Self.reference(for: grant)
            // A relationship owned by another exact incarnation is not this inheritance attempt's
            // work. Fail without adopting, revoking, or compensating its durable intent.
            guard expectedEndpoints.matches(observer: grant.observer, target: grant.target),
                  expectedEndpoints.isEmpty || liveCandidatesStillMatch(expectedEndpoints, pair: pair)
            else {
                return EstablishmentResult(
                    outcome: .failed(.rebinding),
                    preservesDurableIntentOnFailure: true
                )
            }
            // Joining an existing grant still crossed an authority hop, so it owes the same fences a
            // fresh activation does before it may be reported as success: a Stop that retired this
            // token, a freeze, or an incarnation that drifted underneath it all invalidate the claim.
            //
            // A failed fence deliberately neither claims nor revokes this reference. This task did
            // not create the grant, and a pair that was stopped and re-added while this attempt was
            // suspended leaves it owned by token B — adopting the mapping would relabel B's grant as
            // A's, and revoking it would let stale work terminate a newer explicit re-add.
            guard await tokenIsCurrent(token), !isFrozenForTermination else {
                return EstablishmentResult(outcome: .rejected(message: Self.retiredMessage))
            }
            guard await deletionFenceAllowsEstablishment(pair) else {
                await revoke(
                    reference: reference,
                    reason: .sessionDeleted,
                    settlesDurableIntent: false
                )
                return EstablishmentResult(outcome: .failed(.closing))
            }
            if let proof, !liveCandidatesStillMatch(proof) {
                return EstablishmentResult(outcome: .failed(.rebinding))
            }
            bookkeepingByReference[reference] = ReferenceBookkeeping(
                pair: pair,
                token: token,
                assertionGeneration: assertionGeneration
            )
            await requestProjectionRefresh()
            guard await tokenIsCurrent(token) else {
                await revoke(reference: reference, settlesDurableIntent: false)
                return EstablishmentResult(outcome: .rejected(message: Self.retiredMessage))
            }
            // Last suspension before success. Deletion is checked after the token hop so a commit
            // during that hop cannot slip through.
            guard await deletionFenceAllowsEstablishment(pair) else {
                await revoke(
                    reference: reference,
                    reason: .sessionDeleted,
                    settlesDurableIntent: false
                )
                return EstablishmentResult(outcome: .failed(.closing))
            }
            return EstablishmentResult(
                outcome: .alreadyLinked(linkID: grant.id, targetSessionID: grant.target.sessionID),
                observerEndpoint: grant.observer,
                targetEndpoint: grant.target,
                reference: reference
            )
        case let .rejected(rejection):
            return EstablishmentResult(outcome: .rejected(message: Self.message(for: rejection)))
        }

        // Reserving can revoke a stale target incarnation's inbound links inside the authority. Those
        // belong to *other* observers, so they get the same follow-through as any other revocation —
        // observation teardown, endpoint pruning, projection refresh, and advertisement invalidation —
        // rather than depending on the lossy change feed to repair them.
        if !collateralRevocations.isEmpty {
            await reconcile(after: collateralRevocations, capturedBookkeeping: capturedBookkeeping)
        }
        guard await deletionFenceAllowsEstablishment(pair) else {
            await authority.abandonReservation(reservation)
            bookkeepingByReference.removeValue(forKey: Self.reference(for: reservation))
            return EstablishmentResult(outcome: .failed(.closing))
        }

        // Synchronous seed: revalidate both live identities on MainActor, then build the initial
        // sanitized snapshot before the link can become visible to any operation.
        let liveCandidates = host.agentSessionLinkCandidates()
        guard let liveTarget = liveCandidates.first(where: { $0.domainEndpoint == targetEndpoint }),
              liveCandidates.contains(where: { $0.domainEndpoint == observerEndpoint }),
              expectedEndpoints.isEmpty || liveCandidatesMatch(
                  expectedEndpoints,
                  pair: pair,
                  candidates: liveCandidates
              )
        else {
            await authority.abandonReservation(reservation)
            bookkeepingByReference.removeValue(forKey: Self.reference(for: reservation))
            return EstablishmentResult(outcome: .failed(.rebinding))
        }
        // Second restoration fence, taken from the same MainActor pass as the seed: an incarnation
        // that rebound during the reserve hop can present the same endpoint identity with a fresh
        // pending proof, and reauthorizing that would grant against a transcript this process has
        // not proved it read.
        if let proof, !proof.matches(liveCandidates: liveCandidates) {
            await authority.abandonReservation(reservation)
            bookkeepingByReference.removeValue(forKey: Self.reference(for: reservation))
            return EstablishmentResult(outcome: .failed(.rebinding))
        }
        // Second token fence: the reservation authorizes nothing, so a Stop that committed during
        // the reserve hop is settled by abandoning here rather than by revoking a grant that this
        // task would otherwise be about to create.
        guard await tokenIsCurrent(token), !isFrozenForTermination else {
            await authority.abandonReservation(reservation)
            bookkeepingByReference.removeValue(forKey: Self.reference(for: reservation))
            return EstablishmentResult(outcome: .rejected(message: Self.retiredMessage))
        }
        guard await deletionFenceAllowsEstablishment(pair) else {
            await authority.abandonReservation(reservation)
            bookkeepingByReference.removeValue(forKey: Self.reference(for: reservation))
            return EstablishmentResult(outcome: .failed(.closing))
        }
        let seed = host.agentSessionLinkObservationSnapshot(for: liveTarget)
        let seedSequence = allocateSourcePublicationSequence(for: targetEndpoint.sessionID)

        // Prompt claiming is linearized with this observer's membership write, and the fence has to
        // be raised *before* the hop: `activateLink` inserts the grant inside the authority actor
        // while this task is suspended, so from that instant the tool is advertised and callable
        // while the last published inventory still describes the pre-activation membership. A
        // dispatch composed in that window against an empty published inventory renders the terminal
        // revocation notice — telling the model oversight has ended and its tool is gone, at a moment
        // when the replacement link is already live and the tool already answers.
        //
        // Fencing is deliberately all this does. The supplement stays owed, so the window costs at
        // most one undecorated dispatch; the alternative — leaving a claimable snapshot up and
        // repairing the model's belief afterwards — cannot unsay a terminal notice.
        //
        // The fence is host state, not a local here, because this task is not the only publisher.
        // `performProjectionRefresh` can be suspended on its own `projectionInputs` hop holding the
        // pre-activation inventory; it resumes and publishes inside this window, and the retraction
        // alone would not stop it.
        let hold = host.agentSessionLinkWithholdPromptInventory(for: observerEndpoint)
        let disposition = await authority.activateLink(
            reservation: reservation,
            initialSnapshot: seed,
            sourcePublicationSequence: seedSequence
        )
        let activation: DomainAgentSessionLinkActivation
        switch disposition {
        case let .activated(value):
            activation = value
            // The manager-owned catalog projection must become unready before active inventory is
            // published. Awaiting the existing invalidation path keeps the prompt hold across both
            // authority activation and projection application.
            await invalidateToolAdvertisement(forObserverSession: observerEndpoint.sessionID)
            host.agentSessionLinkReleasePromptInventoryHold(
                hold,
                for: observerEndpoint,
                publishing: AgentSessionLinkPromptInventory(value.observerInventory)
            )
        case let .rejected(rejection):
            // The authority already dropped the reservation on every rejection path, so there is no
            // pending record left to roll back here. *This* write changed no membership, so it
            // reports no inventory — which is a request to return the endpoint to its pre-fence
            // value, not an assertion that nothing changed. An overlapping sibling may have committed
            // meanwhile; the host settles that by revision, so this rejection cannot undo it.
            host.agentSessionLinkReleasePromptInventoryHold(
                hold,
                for: observerEndpoint,
                publishing: nil
            )
            // The restore hands back the value the first withhold retracted, which is stale if an
            // ordinary publication was refused while the fence was up — a revocation refresh dropped
            // there is dropped for good, leaving the endpoint over-reporting a link that is gone.
            // Re-deriving from the authority after the fence settles is what repairs it; the
            // activated arm already refreshes for its own reasons, so only this arm needed it.
            await requestProjectionRefresh(.sessions([observerEndpoint.sessionID]))
            bookkeepingByReference.removeValue(forKey: Self.reference(for: reservation))
            return EstablishmentResult(outcome: .rejected(message: Self.message(for: rejection)))
        }

        let grantReference = Self.reference(for: activation.grant)
        bookkeepingByReference.removeValue(forKey: Self.reference(for: reservation))
        bookkeepingByReference[grantReference] = ReferenceBookkeeping(
            pair: pair,
            token: token,
            assertionGeneration: assertionGeneration
        )

        #if DEBUG
            await test_afterActivationBeforeDeletionFence?(pair)
        #endif
        // Third token fence. The grant is live from the instant `activateLink` committed, so a Stop
        // that removed this token while this task was suspended on that hop has already reported the
        // link gone. Revoking here — rather than leaving it and trusting a later sweep — is what
        // makes "reported Stop implies the grant is settled" true.
        guard await tokenIsCurrent(token), !isFrozenForTermination else {
            await revoke(reference: grantReference, settlesDurableIntent: false)
            return EstablishmentResult(outcome: .rejected(message: Self.retiredMessage))
        }
        // Checked after the token actor hop: a deletion beginning during that suspension is either
        // awaited to failure or observed committed before any post-activation work continues.
        guard await deletionFenceAllowsEstablishment(pair) else {
            await revoke(
                reference: grantReference,
                reason: .sessionDeleted,
                settlesDurableIntent: false
            )
            return EstablishmentResult(outcome: .failed(.closing))
        }
        // Third restoration fence, for the same reason the token has one: the grant is live from the
        // instant activation committed, so a proof that stopped holding across that hop has to be
        // revoked rather than left for a sweep that only looks at identity.
        if let proof, !liveCandidatesStillMatch(proof) {
            await revoke(reference: grantReference)
            return EstablishmentResult(outcome: .failed(.rebinding))
        }
        if !expectedEndpoints.isEmpty,
           !liveCandidatesStillMatch(expectedEndpoints, pair: pair)
        {
            // Runtime rollback only. The outer Add transaction compensates its own fresh insert,
            // while an idempotent `.unchanged` assertion preserves the durable intent it found.
            await revoke(reference: grantReference, settlesDurableIntent: false)
            return EstablishmentResult(outcome: .failed(.rebinding))
        }

        knownObserverEndpoints.insert(activation.grant.observer)
        knownTargetEndpoints.insert(activation.grant.target)

        // The activation that actually created the target record owns the observation and its
        // publication chain. A provisionally elected reservation can be abandoned or invalidated, so
        // only this flag is authoritative.
        //
        // The publication-dedupe entry is seeded on exactly the same condition, and never
        // unconditionally: `activateLink` deliberately ignores the seed of an activation that joins
        // an existing target record, so recording that ignored seed as "already published" would
        // make the installing chain's next identical rebuild compare equal and be dropped, leaving
        // `change_sequence` frozen and every `poll`/`wait` stale until an unrelated mutation.
        if activation.installsTargetObservation {
            // This activation seeded the authority with exactly `seed`, so the observation's initial
            // replay burst reproduces it and is correctly dropped instead of advancing
            // `change_sequence`.
            lastPublishedSnapshotBySession[targetEndpoint.sessionID] = seed
            installObservation(for: liveTarget, initialActivity: seed.lastActivityAt)
        } else if chains[targetEndpoint.sessionID] == nil {
            // The authority already has a target record but this process lost its chain (for example
            // the previous installer's window closed between activations). Reinstalling keeps status
            // flowing; the never-reset sequence allocator guarantees the next publication is accepted.
            //
            // The authority kept its own stored snapshot and ignored this caller's seed, so the live
            // state may be strictly newer. Clear the dedupe entry and publish it rather than marking
            // an unpublished value as published.
            lastPublishedSnapshotBySession.removeValue(forKey: targetEndpoint.sessionID)
            installObservation(for: liveTarget, initialActivity: seed.lastActivityAt)
            publishTargetSnapshot(forTargetSession: targetEndpoint.sessionID)
        }
        // Otherwise this activation joined a record whose live chain already owns the dedupe state;
        // overwriting it would discard that chain's next publication.

        await requestProjectionRefresh()
        if activation.installsTargetObservation {
            let targetHoldsOutboundLink = await authority.hasActiveOutboundLink(
                observerEndpoint: targetEndpoint
            )
            if !targetHoldsOutboundLink {
                await toolAdvertisementInvalidator(targetEndpoint.sessionID)
            }
        }
        // Both calls above suspend. A deletion committed in either hop must not be followed by a
        // success report for a grant that the commit observer already invalidated.
        guard await tokenIsCurrent(token) else {
            await revoke(reference: grantReference, settlesDurableIntent: false)
            return EstablishmentResult(outcome: .rejected(message: Self.retiredMessage))
        }
        guard await deletionFenceAllowsEstablishment(pair) else {
            await revoke(
                reference: grantReference,
                reason: .sessionDeleted,
                settlesDurableIntent: false
            )
            return EstablishmentResult(outcome: .failed(.closing))
        }
        // The projection refresh, authority lookup, and advertisement invalidation above all
        // suspend. Exact Add must not report success if either selected incarnation rebound, closed,
        // or lost eligibility during that tail work. Restoration proofs get the same final fence.
        if let proof, !liveCandidatesStillMatch(proof) {
            await revoke(reference: grantReference)
            return EstablishmentResult(outcome: .failed(.rebinding))
        }
        if !expectedEndpoints.isEmpty,
           !liveCandidatesStillMatch(expectedEndpoints, pair: pair)
        {
            // As above, durable compensation belongs solely to the Add that created the intent.
            await revoke(reference: grantReference, settlesDurableIntent: false)
            return EstablishmentResult(outcome: .failed(.rebinding))
        }
        return EstablishmentResult(
            outcome: .added(
                linkID: activation.grant.id,
                targetSessionID: activation.grant.target.sessionID
            ),
            observerEndpoint: activation.grant.observer,
            targetEndpoint: activation.grant.target,
            reference: grantReference
        )
    }

    /// Whether both proved incarnations are still live with the same authoritative hydration proof.
    private func liveCandidatesStillMatch(_ proof: AgentSessionOversightRestorationProof) -> Bool {
        guard let host else { return false }
        return proof.matches(liveCandidates: host.agentSessionLinkCandidates())
    }

    private func liveCandidatesStillMatch(
        _ expectations: AddEndpointExpectations,
        pair: AgentSessionOversightIntent
    ) -> Bool {
        guard let host else { return false }
        return liveCandidatesMatch(
            expectations,
            pair: pair,
            candidates: host.agentSessionLinkCandidates()
        )
    }

    private func liveCandidatesMatch(
        _ expectations: AddEndpointExpectations,
        pair: AgentSessionOversightIntent,
        candidates: [AgentSessionLinkEndpointCandidate]
    ) -> Bool {
        guard case let .success(observer) = resolveAddCandidate(
            sessionID: pair.observerSessionID,
            expectedEndpoint: expectations.observer,
            candidates: candidates
        ),
            case let .success(target) = resolveAddCandidate(
                sessionID: pair.targetSessionID,
                expectedEndpoint: expectations.target,
                candidates: candidates
            ),
            AgentSessionLinkEndpointEligibility.addDisabledReason(
                observer.eligibilityInput,
                roleAllowsOutboundMonitoring: observer.roleAllowsOutboundMonitoring
            ) == nil
        else {
            return false
        }
        return expectations.matches(
            observer: observer.domainEndpoint,
            target: target.domainEndpoint
        )
    }

    // MARK: - Stop

    private static let staleRelationshipMessage = "That oversight relationship is no longer active."

    /// Legacy UUID-addressed adapter. Authority supplies the exact endpoints, then the exact Stop
    /// core below performs every validation and mutation.
    func stopMonitorLink(
        observerSessionID: UUID,
        targetSessionID: UUID,
        linkID: UUID,
        generation: UInt64
    ) async -> AgentMonitorStopOutcome {
        guard !isFrozenForTermination else {
            return .failed(message: AgentSessionOversightPersistenceCopy.shutdownBeforeInsert)
        }
        let reference = DomainAgentSessionLinkReference(linkID: linkID, generation: generation)
        guard let grant = await authority.activeGrant(for: reference) else { return .alreadyStopped }
        guard grant.observer.sessionID == observerSessionID,
              grant.target.sessionID == targetSessionID
        else {
            return .failed(message: Self.staleRelationshipMessage)
        }
        return await stopMonitorLink(
            observerEndpoint: grant.observer,
            targetEndpoint: grant.target,
            expectedReference: reference
        )
    }

    /// Authority-first durable Stop for one exact observer-target relationship.
    ///
    /// The authority grant is the proof. Neither endpoint has to remain in the live candidate list,
    /// which lets a target unlink an observer whose window already disappeared. Durable removal
    /// still commits before revocation, and both operations are generation and pair qualified.
    func stopMonitorLink(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
        expectedReference: DomainAgentSessionLinkReference
    ) async -> AgentMonitorStopOutcome {
        let pair = AgentSessionOversightIntent(
            observerSessionID: observerEndpoint.sessionID,
            targetSessionID: targetEndpoint.sessionID
        )
        guard !isFrozenForTermination else {
            return .failed(message: AgentSessionOversightPersistenceCopy.shutdownBeforeInsert)
        }
        let transaction = registerTransaction()
        defer { finishTransaction(transaction) }
        // The lane is installed *before* the removal is awaited, so an Add racing this Stop blocks
        // on it instead of reserving against a token that is being retired.
        let outcome = await withPairRetirementLane(pair) { [weak self] () -> AgentMonitorStopOutcome in
            guard let self else { return .alreadyStopped }
            guard !isFrozenForTermination else {
                return .failed(message: AgentSessionOversightPersistenceCopy.shutdownBeforeInsert)
            }
            guard let grant = await authority.activeGrant(for: expectedReference) else {
                // Never infer a replacement from the UUID pair. A retired generation is simply
                // already stopped, even if this pair has since been re-added.
                return .alreadyStopped
            }
            guard !isFrozenForTermination else {
                return .failed(message: AgentSessionOversightPersistenceCopy.shutdownBeforeInsert)
            }
            guard grant.observer == observerEndpoint, grant.target == targetEndpoint else {
                return .failed(message: Self.staleRelationshipMessage)
            }
            return await performPairRetirement(pair: pair, reference: expectedReference)
        }
        #if DEBUG
            logPairLane(pair: pair, outcome: "retired")
        #endif
        if outcome == .stopped,
           let host,
           let observer = host.agentSessionLinkCandidates().first(where: {
               $0.domainEndpoint == observerEndpoint
           })
        {
            var selected = host.agentSessionLinkAutoWakeTargetSessionIDs(for: observer)
            if selected.remove(targetEndpoint.sessionID) != nil {
                _ = host.agentSessionLinkSetAutoWakeTargetSessionIDs(
                    selected,
                    for: observerEndpoint
                )
            }
        }
        return outcome
    }

    private func performPairRetirement(
        pair: AgentSessionOversightIntent,
        reference: DomainAgentSessionLinkReference
    ) async -> AgentMonitorStopOutcome {
        let mapped = bookkeepingByReference[reference]
        if let mapped, mapped.pair != pair {
            // The authority endpoints matched before entry, so a different bookkeeping pair is an
            // internal stale-owner mismatch. Neither the durable row nor the grant may be guessed at.
            return .failed(message: Self.staleRelationshipMessage)
        }

        // Never derived from the pair alone. A stale row for reference A can arrive long after the
        // pair was stopped and re-added under token B; looking the pair up would find B, remove it,
        // settle B's establishment, and revoke B's grants — a stale UI action terminating a newer
        // explicit re-add. A missing mapping is an invariant failure, so persistence fails closed and
        // only the exact runtime reference may be considered.
        guard let intentStore else {
            #if DEBUG
                if mapped == nil { logPairLane(pair: pair, outcome: "unmapped_reference") }
            #endif
            return await revoke(reference: reference) ? .stopped : .alreadyStopped
        }
        guard let mapped, let token = mapped.token else {
            // Production persistence is installed but this exact reference owns no durable token.
            // Revoking would report success while leaving an intent that can resurrect next launch.
            return .failed(message: Self.staleRelationshipMessage)
        }

        // Rechecked immediately before the durable removal: `stopMonitorLink` admitted this Stop
        // before waiting for an older retirement, and a freeze landing in that window must leave the
        // saved relationship exactly as it was.
        guard !isFrozenForTermination else {
            return .failed(message: AgentSessionOversightPersistenceCopy.shutdownBeforeInsert)
        }

        let receipt = await intentStore.remove(
            pair,
            ifCurrent: token,
            assertedAt: mapped.assertionGeneration
        )
        switch receipt.outcome {
        case .writeFailed:
            // The grant and the token both stay valid. Reporting success here would tell the user
            // oversight ended while it is still live and still saved.
            return .failed(message: AgentSessionOversightPersistenceCopy.stopWriteFailed)
        case .blocked:
            return .failed(message: AgentSessionOversightPersistenceCopy.unreadable)
        case .absent, .tokenMismatch:
            // A newer token is current, or the pair was already removed. Settle only this stale
            // token's work and revoke only the authority-validated expected reference; never remove
            // the newer token or infer a replacement reference from the UUID pair.
            #if DEBUG
                logPairLane(
                    pair: pair,
                    outcome: receipt.outcome == .tokenMismatch ? "token_mismatch" : "absent"
                )
            #endif
            await settleEstablishment(pair: pair, token: token)
            if bookkeepingByReference[reference] == mapped {
                bookkeepingByReference.removeValue(forKey: reference)
            }
            return await revoke(
                reference: reference,
                settlesDurableIntent: false
            ) ? .stopped : .alreadyStopped
        case .applied, .unchanged:
            break
        }

        // Token A is gone from disk. Settle its establishment first so an in-flight activation
        // cannot leave its grant behind the removal, then retire only the expected reference.
        await settleEstablishment(pair: pair, token: token)
        // Stop already removed this token durably while holding the pair lane. Clearing this exact
        // bookkeeping before the authority hop prevents common revocation follow-through from
        // trying to remove the same row by recursively acquiring this lane.
        bookkeepingByReference.removeValue(forKey: reference)
        return await revoke(reference: reference) ? .stopped : .alreadyStopped
    }

    // MARK: - Revoke

    /// Either endpoint may revoke. Both windows update from the same authority transition.
    func revokeLink(linkID: UUID, generation: UInt64) async {
        await revoke(reference: DomainAgentSessionLinkReference(linkID: linkID, generation: generation))
    }

    @discardableResult
    private func revoke(
        reference: DomainAgentSessionLinkReference,
        reason: DomainAgentSessionLinkRevocationReason = .userRequested,
        settlesDurableIntent: Bool = true
    ) async -> Bool {
        // Captured before the authority hop, exactly like every other lifecycle owner: the mapping
        // this revocation owns has to be read from a value it took while it still held MainActor,
        // not from a table concurrent work may have replaced meanwhile.
        let capturedBookkeeping = bookkeepingByReference
        let disposition = await authority.revoke(
            linkID: reference.linkID,
            generation: reference.generation,
            reason: reason
        )
        // Routed through the common reconcile so a manual Stop prunes the known endpoint sets on the
        // same path lifecycle invalidation does; otherwise a revoked incarnation would linger and a
        // later sweep could act on it. The reference mapping is deliberately *not* dropped first:
        // `settleDurableIntent` needs it to identify which durable token this revocation owns, and
        // guessing is exactly the mistake the mapping exists to prevent.
        if case let .revoked(notice) = disposition {
            if !settlesDurableIntent {
                bookkeepingByReference.removeValue(forKey: reference)
            }
            await reconcile(
                after: [notice],
                capturedBookkeeping: settlesDurableIntent ? capturedBookkeeping : [:]
            )
            return true
        }
        bookkeepingByReference.removeValue(forKey: reference)
        monitorSeenByReference.removeValue(forKey: reference)
        await requestProjectionRefresh()
        return false
    }

    // MARK: - Lifecycle invalidation

    func invalidate(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        reason: DomainAgentSessionLinkRevocationReason
    ) async {
        let capturedBookkeeping = bookkeepingByReference
        let notices = await authority.invalidate(endpoint: endpoint, reason: reason)
        await reconcile(after: notices, capturedBookkeeping: capturedBookkeeping)
        noteLifecycleEnded(sessionIDs: [endpoint.sessionID])
    }

    /// Revokes every link touching `sessionID` in **every** window, regardless of incarnation.
    ///
    /// Valid only when the session itself is known to be gone process-wide — a real delete — never for
    /// tab teardown or rebinding. One session UUID can be live in several windows at once, so routing
    /// an ordinary tab close through here revokes grants other windows still legitimately hold; use
    /// `invalidateBinding(windowID:tabID:reason:)` for anything endpoint-local.
    func invalidateSession(_ sessionID: UUID, reason: DomainAgentSessionLinkRevocationReason) async {
        let capturedBookkeeping = bookkeepingByReference
        let notices = await authority.invalidateSession(sessionID: sessionID, reason: reason)
        await reconcile(after: notices, capturedBookkeeping: capturedBookkeeping)
        noteLifecycleEnded(sessionIDs: [sessionID])
    }

    func invalidateWindow(_ windowID: Int, reason: DomainAgentSessionLinkRevocationReason) async {
        let capturedBookkeeping = bookkeepingByReference
        let notices = await authority.invalidateWindow(windowID: windowID, reason: reason)
        await reconcile(after: notices, capturedBookkeeping: capturedBookkeeping)
        noteLifecycleEnded(sessionIDs: Set(notices.flatMap { [$0.observerSessionID, $0.targetSessionID] }))
    }

    func invalidateWorkspace(
        _ workspaceID: UUID,
        windowID: Int?,
        reason: DomainAgentSessionLinkRevocationReason
    ) async {
        let capturedBookkeeping = bookkeepingByReference
        let notices = await authority.invalidateWorkspace(
            workspaceID: workspaceID,
            windowID: windowID,
            reason: reason
        )
        await reconcile(after: notices, capturedBookkeeping: capturedBookkeeping)
        noteLifecycleEnded(sessionIDs: Set(notices.flatMap { [$0.observerSessionID, $0.targetSessionID] }))
    }

    /// Hands one teardown directly to launch reconciliation.
    ///
    /// A *waiting* launch entry holds no grant, so no authority notice is produced when its window,
    /// tab, or workspace goes away and `settleDurableIntent` has nothing to remove. Without this, an
    /// ordinary close of a saved-but-never-granted pair would leave the intent durable under an
    /// uncertain topology and let it reactivate later, despite the user closing it.
    private func noteLifecycleEnded(sessionIDs: Set<UUID>) {
        guard !isFrozenForTermination, !sessionIDs.isEmpty else { return }
        launchCoordinator?.noteLifecycleEnded(sessionIDs: sessionIDs)
    }

    /// Eager, incarnation-scoped invalidation for one tab whose persistent binding just changed.
    ///
    /// Covers observer-side unbind, rebind, and delete. It revokes only the endpoint incarnations of
    /// that exact `(window, tab)` that are no longer live, so re-binding tab A from S1 to S2 never
    /// disturbs a different window's still-valid link to S2, and a binding-generation change with an
    /// unchanged session UUID is still caught.
    func invalidateBinding(
        windowID: Int,
        tabID: UUID,
        reason: DomainAgentSessionLinkRevocationReason = .bindingChanged
    ) async {
        guard let host else { return }
        let live = Set(host.agentSessionLinkCandidates().map(\.domainEndpoint))
        let affected = knownObserverEndpoints.union(knownTargetEndpoints).filter {
            $0.windowID == windowID && $0.tabID == tabID && !live.contains($0)
        }
        guard !affected.isEmpty else {
            // Still a lifecycle fact even with no grant to revoke — that is exactly the shape a
            // waiting launch entry has.
            launchCoordinator?.markDirty()
            return
        }

        let capturedBookkeeping = bookkeepingByReference
        var notices: [DomainAgentSessionLinkRevocationNotice] = []
        for endpoint in affected {
            notices += await authority.invalidate(endpoint: endpoint, reason: reason)
            knownObserverEndpoints.remove(endpoint)
            knownTargetEndpoints.remove(endpoint)
            removeChain(forTargetSession: endpoint.sessionID, matching: endpoint)
        }
        await reconcile(after: notices, capturedBookkeeping: capturedBookkeeping)
        noteLifecycleEnded(sessionIDs: Set(affected.map(\.sessionID)))
    }

    /// Lazy revalidation entry point for callers outside a refresh pass (workspace switches, window
    /// lifecycle, tests).
    func revalidateLiveEndpoints() async {
        await requestProjectionRefresh()
    }

    /// Revokes every known endpoint incarnation that is no longer live.
    ///
    /// Runs inline inside a refresh pass and therefore must never call `requestProjectionRefresh`:
    /// the invalidations it performs publish authority events that schedule the next pass on their
    /// own. Everything *else* the revocation follow-through does still has to happen here — in
    /// particular advertisement invalidation, which used to reach these observers only through the
    /// lossy change feed, on exactly the lifecycle path that exists to repair stale state.
    private func sweepStaleEndpoints(liveCandidates: [AgentSessionLinkEndpointCandidate]) async {
        guard !knownObserverEndpoints.isEmpty || !knownTargetEndpoints.isEmpty else { return }
        let live = Set(liveCandidates.map(\.domainEndpoint))
        let capturedBookkeeping = bookkeepingByReference
        var notices: [DomainAgentSessionLinkRevocationNotice] = []

        for endpoint in knownObserverEndpoints.subtracting(live) {
            notices += await authority.invalidate(
                endpoint: endpoint,
                reason: .observerEndpointInvalidated
            )
            knownObserverEndpoints.remove(endpoint)
        }
        for endpoint in knownTargetEndpoints.subtracting(live) {
            notices += await authority.invalidate(
                endpoint: endpoint,
                reason: .targetEndpointInvalidated
            )
            knownTargetEndpoints.remove(endpoint)
            // Incarnation-scoped: a stale endpoint E1 must never tear down the chain a newer
            // incarnation E2 installed for the same session UUID.
            removeChain(forTargetSession: endpoint.sessionID, matching: endpoint)
        }

        await reconcile(
            after: notices,
            capturedBookkeeping: capturedBookkeeping,
            refreshingProjections: false
        )
    }

    /// Common follow-through for a set of revocations.
    ///
    /// - Parameter refreshingProjections: `false` only for callers already running inside a
    ///   projection refresh pass. Re-entering the coalescer from there would make the pass wait on
    ///   itself; that pass republishes the affected endpoints as soon as the sweep returns.
    private func reconcile(
        after notices: [DomainAgentSessionLinkRevocationNotice],
        capturedBookkeeping: [DomainAgentSessionLinkReference: ReferenceBookkeeping],
        refreshingProjections: Bool = true
    ) async {
        for notice in notices {
            let reference = DomainAgentSessionLinkReference(
                linkID: notice.linkID,
                generation: notice.generation
            )
            // Seen state is generation-qualified: a fresh re-add of the same pair baselines against
            // current activity instead of inheriting an acknowledgement made under removed authority.
            monitorSeenByReference.removeValue(forKey: reference)
        }
        // Generation-qualified for the same reason, and released before anything republishes: a
        // queued message must never outlive the exact grant that admitted it.
        releasePendingSends(after: notices)
        var touched = Set(notices.map(\.targetSessionID))
        touched.formUnion(notices.map(\.observerSessionID))
        // Runs before the projection work so a revoked link's saved row is already gone by the time
        // the surviving endpoint repaints. Authority was revoked before this call, so a disk failure
        // here can only affect what comes back next launch, never what is operable now.
        await settleDurableIntent(after: notices, capturedBookkeeping: capturedBookkeeping)
        await reconcile(afterTargetSessions: Set(notices.map(\.targetSessionID)))
        await pruneKnownEndpoints(sessionIDs: touched)
        if refreshingProjections {
            await requestProjectionRefresh()
        }
        // Every revocation path — manual Stop, lifecycle invalidation, stale-endpoint sweep — funnels
        // through here, so this is the one place that covers losing a link the way the add path covers
        // gaining one.
        for observerSessionID in Set(notices.map(\.observerSessionID)) {
            await invalidateToolAdvertisement(forObserverSession: observerSessionID)
        }
        for targetEndpoint in Set(notices.compactMap(\.targetEndpoint)) {
            let remainsLinked = await authority.hasActiveLink(endpoint: targetEndpoint)
            guard !remainsLinked else { continue }
            await toolAdvertisementInvalidator(targetEndpoint.sessionID)
        }
    }

    private func reconcile(afterTargetSessions sessionIDs: Set<UUID>) async {
        for targetSessionID in sessionIDs {
            await reconcileObservation(forTargetSession: targetSessionID)
        }
    }

    /// Drops endpoint incarnations that no longer back any link.
    ///
    /// Without this, a revoked incarnation E1 stays in the known sets forever; a later sweep would
    /// still see it as "not live" and invalidate it, and — before the incarnation-scoped teardown
    /// below — would tear down the chain a newer E2 had installed for the same session UUID.
    private func pruneKnownEndpoints(sessionIDs: Set<UUID>) async {
        for sessionID in sessionIDs {
            let outbound = await authority.links(forObserver: sessionID)
            if outbound.isEmpty {
                knownObserverEndpoints = knownObserverEndpoints.filter { $0.sessionID != sessionID }
            }
            let inbound = await authority.links(forTarget: sessionID)
            if inbound.isEmpty {
                knownTargetEndpoints = knownTargetEndpoints.filter { $0.sessionID != sessionID }
            }
        }
    }

    /// Tears the observation down only after the last inbound link for that target is gone.
    private func reconcileObservation(forTargetSession sessionID: UUID) async {
        guard let endpoint = chains[sessionID]?.endpoint else { return }
        let inbound = await authority.links(forTarget: sessionID)
        guard inbound.isEmpty else { return }
        removeChain(forTargetSession: sessionID, matching: endpoint)
    }

    // MARK: - Observation and serial publication

    private func installObservation(
        for candidate: AgentSessionLinkEndpointCandidate,
        initialActivity: Date?
    ) {
        guard let host else { return }
        let endpoint = candidate.domainEndpoint
        if let existing = chains[endpoint.sessionID]?.endpoint {
            removeChain(forTargetSession: endpoint.sessionID, matching: existing)
        }
        let chain = TargetPublicationChain(endpoint: endpoint, activityHighWater: initialActivity)
        chains[endpoint.sessionID] = chain
        chain.token = host.agentSessionLinkInstallObservation(for: candidate) { [weak self] in
            self?.publishTargetSnapshot(forTargetSession: endpoint.sessionID)
        }
        guard chain.token != nil else {
            // The endpoint disappeared between activation and observation install. Fail closed.
            chains.removeValue(forKey: endpoint.sessionID)
            lastPublishedSnapshotBySession.removeValue(forKey: endpoint.sessionID)
            Task { [weak self] in
                await self?.invalidate(endpoint: endpoint, reason: .activationSeedFailed)
            }
            return
        }
    }

    /// Removes a chain **only** when it still belongs to `endpoint`.
    ///
    /// `chains` is keyed by session UUID, but a session UUID can be re-bound to a new incarnation
    /// while a stale incarnation is still queued for cleanup. An unqualified removal would silently
    /// stop publishing for the live incarnation.
    private func removeChain(
        forTargetSession sessionID: UUID,
        matching endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let chain = chains[sessionID], chain.endpoint == endpoint else { return }
        chains.removeValue(forKey: sessionID)
        lastPublishedSnapshotBySession.removeValue(forKey: sessionID)
        chain.token?.invalidate()
        chain.token = nil
        chain.tail = nil
    }

    /// Builds the sanitized snapshot on MainActor, allocates its source publication sequence
    /// synchronously, then appends the publish to this target's retained serial chain.
    ///
    /// Sequence allocation happens before the actor hop, so ordering is decided by MainActor order
    /// rather than by task scheduling; the authority's high-water rule is the second line of defence.
    private func publishTargetSnapshot(forTargetSession sessionID: UUID) {
        guard let chain = chains[sessionID], let host else { return }
        let endpoint = chain.endpoint
        // Resolved by exact incarnation, never by session UUID. A UUID lookup that demands a unique
        // match reports "ambiguous" the moment a second live incarnation of this UUID opens, which
        // would revoke this still-valid grant as `.targetIdentityDrift`; a lookup that tolerated
        // ambiguity would publish some other incarnation's state under this grant.
        guard let candidate = host.agentSessionLinkCandidates()
            .first(where: { $0.domainEndpoint == endpoint })
        else {
            // Identity drift: revoke rather than publish state for a different incarnation.
            removeChain(forTargetSession: sessionID, matching: endpoint)
            Task { [weak self] in
                await self?.invalidate(endpoint: endpoint, reason: .targetIdentityDrift)
            }
            return
        }

        let snapshot = host.agentSessionLinkObservationSnapshot(for: candidate)
        observeActivity(snapshot.lastActivityAt, for: endpoint)
        // Drop no-op rebuilds (notably the replay burst every new `@Published` subscription emits) so
        // an unchanged target never advances `change_sequence` or wakes a parked waiter.
        guard lastPublishedSnapshotBySession[sessionID] != snapshot else { return }
        lastPublishedSnapshotBySession[sessionID] = snapshot
        // The one readiness trigger a queued send has. It hangs off an *accepted* publication, so an
        // unchanged target produces none at all and nothing ever polls for readiness.
        if snapshot.idleForSend {
            notePendingSendReadiness(forTargetSession: sessionID)
        }
        let sequence = allocateSourcePublicationSequence(for: sessionID)
        let previous = chain.tail
        chain.tail = Task { [authority] in
            await previous?.value
            _ = await authority.publishTargetSnapshot(
                endpoint: endpoint,
                snapshot: snapshot,
                sourcePublicationSequence: sequence
            )
        }
    }

    private func allocateSourcePublicationSequence(for sessionID: UUID) -> UInt64 {
        let next = (nextSourcePublicationSequenceBySession[sessionID] ?? 0) &+ 1
        nextSourcePublicationSequenceBySession[sessionID] = next
        return next
    }

    // MARK: - Projections

    /// Coalesces refreshes so a burst of authority events produces one projection pass.
    ///
    /// Scopes merge rather than overwrite: a status-only refresh queued behind a membership change
    /// must not narrow that pending full rebuild.
    private func requestProjectionRefresh(_ scope: ProjectionRefreshScope = .full) async {
        pendingRefreshScope = pendingRefreshScope?.merged(with: scope) ?? scope
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            while let scope = pendingRefreshScope {
                pendingRefreshScope = nil
                await performProjectionRefresh(scope)
            }
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func performProjectionRefresh(_ scope: ProjectionRefreshScope) async {
        guard let host else { return }
        var candidates = host.agentSessionLinkCandidates()
        if scope.isFull {
            // Only a full pass sweeps: status churn cannot invalidate an endpoint, and lifecycle
            // seams (window/workspace/binding/session) all request a full refresh.
            await sweepStaleEndpoints(liveCandidates: candidates)
            // Re-read after the sweep so a projection is never built from a candidate the sweep just
            // proved stale.
            candidates = host.agentSessionLinkCandidates()
        }
        // Keyed by exact incarnation. A `[sessionID: candidate]` map with first-wins uniquing picks
        // an arbitrary incarnation when one session UUID is live in two windows, which would source
        // outbound status/provider/location and inbound names from the wrong one.
        let byEndpoint = Dictionary(
            candidates.map { ($0.domainEndpoint, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let rebuilt: [AgentSessionLinkEndpointCandidate] = switch scope {
        case .full:
            candidates
        case let .sessions(sessionIDs):
            candidates.filter { sessionIDs.contains($0.sessionID) }
        }
        for candidate in rebuilt {
            let projection = await makeProjection(
                for: candidate,
                candidates: candidates,
                candidatesByEndpoint: byEndpoint
            )
            host.agentSessionLinkPublishProjection(projection.props, to: candidate.domainEndpoint)
            // Both projections are built from one authority read, but only the pill is published
            // unconditionally. The prompt inventory here was read before this line — possibly several
            // hops ago, since each candidate costs its own `projectionInputs` — and a membership
            // write may have fenced this endpoint in between. The host refuses the write in that
            // case; the write's own release publishes the post-mutation inventory instead, and the
            // refresh this method is called from again afterwards reconciles the pill.
            host.agentSessionLinkPublishPromptInventory(
                projection.promptInventory,
                to: candidate.domainEndpoint
            )
            // Published after the inventory it will later be joined to, and only for an observer
            // holding a queue. A fenced endpoint refuses the inventory above while accepting this,
            // which is exactly the state the revision match is for: the snapshot simply stays
            // undeliverable until the pass after the membership write republishes both.
            if let passiveNotices = projection.passiveNotices {
                host.agentSessionLinkPublishPassiveStatusNotices(
                    passiveNotices,
                    to: candidate.domainEndpoint
                )
            }
        }
        if scope.isFull {
            prunePassiveNotices(liveEndpoints: Set(candidates.map(\.domainEndpoint)))
            await reconcilePendingSends()
        }
    }

    /// One endpoint's refreshed projections: the Oversee rows the user sees and the inventory the
    /// observing agent may be told about. Built together from one authority read so the two can never
    /// be sourced from different membership snapshots.
    private struct EndpointProjection {
        let props: AgentMonitorPillProps
        let promptInventory: AgentSessionLinkPromptInventory
        /// Present for every observer that currently holds — or has just stopped holding — a
        /// collectable direct outbound link.
        let passiveNotices: AgentSessionLinkPassiveStatusNotices.Snapshot?
    }

    private func makeProjection(
        for candidate: AgentSessionLinkEndpointCandidate,
        candidates: [AgentSessionLinkEndpointCandidate],
        candidatesByEndpoint: [DomainAgentSessionLinkEndpointIdentity: AgentSessionLinkEndpointCandidate]
    ) async -> EndpointProjection {
        // Endpoint-scoped on every axis, read in one authority turn: a second live incarnation of
        // this session UUID owns neither these outbound grants nor these inbound observers nor these
        // notices, and must not render or be told about them.
        let inputs = await authority.projectionInputs(forEndpoint: candidate.domainEndpoint)
        let monitor = await makeMonitorProjection(
            for: candidate,
            inputs: inputs,
            candidates: candidates,
            candidatesByEndpoint: candidatesByEndpoint,
            collectsStatusSamples: true
        )
        // Reconciled here rather than inside the row builder, because this is the only pass that is
        // authoritative about membership *and* status at once.
        let passiveNotices = reconcilePassiveNotices(
            for: candidate,
            samples: monitor.statusSamples,
            linkSetRevision: inputs.outbound.linkSetRevision
        )
        return EndpointProjection(
            props: monitor.props,
            // Built from the authority inventory, not from the UI rows: those substitute a live
            // candidate's name and status when the grant carries none, and neither substitution may
            // leak into agent-facing prompt text.
            promptInventory: AgentSessionLinkPromptInventory(inputs.outbound),
            passiveNotices: passiveNotices
        )
    }

    /// One endpoint's Oversee rows plus the passive status samples those same rows were built from.
    private struct MonitorProjection {
        let props: AgentMonitorPillProps
        /// Consumed only by the authoritative pass. Presentation-only projection refreshes discard
        /// these samples, so location, Seen, settings, sidebar-menu, and observer-role repaints cannot
        /// narrate a transition, queue passive work, or trigger Auto-wake.
        let statusSamples: [AgentSessionLinkPassiveStatusNotices.Sample]
    }

    /// The Oversee rows for one endpoint, and nothing else.
    ///
    /// Deliberately separate from `makeProjection`: presentation-only refreshes publish this value
    /// alone, and factoring it out is what makes location, Seen, settings, sidebar-menu, and
    /// observer-role repaints incapable of emitting prompt inventory or reconciling passive work.
    private func makeMonitorProjection(
        for candidate: AgentSessionLinkEndpointCandidate,
        inputs: DomainAgentSessionLinkEndpointProjectionInputs,
        candidates: [AgentSessionLinkEndpointCandidate],
        candidatesByEndpoint: [DomainAgentSessionLinkEndpointIdentity: AgentSessionLinkEndpointCandidate],
        collectsStatusSamples: Bool = false
    ) async -> MonitorProjection {
        let sessionID = candidate.sessionID
        let endpoint = candidate.domainEndpoint

        var outbound: [AgentMonitorPillProps.Outbound] = []
        var statusSamples: [AgentSessionLinkPassiveStatusNotices.Sample] = []
        for item in inputs.outbound.items {
            // The grant's own target incarnation, not "some live session with that UUID".
            guard let targetEndpoint = inputs.outboundTargetEndpoints[item.linkID] else {
                assertionFailure("Active outbound oversight link is missing its exact target endpoint.")
                continue
            }
            let target = candidatesByEndpoint[targetEndpoint]
            let presentation = targetPresentation(for: target, exactEndpoint: targetEndpoint)
            let reference = DomainAgentSessionLinkReference(
                linkID: item.linkID,
                generation: item.generation
            )
            let hasUnreadActivity = monitorHasUnreadActivity(
                for: reference,
                observerEndpoint: endpoint,
                targetEndpoint: targetEndpoint,
                currentActivity: presentation.lastActivityAt
            )
            let targetRoute = AgentSessionDeepLinkRoute(
                windowID: targetEndpoint.windowID,
                workspaceID: targetEndpoint.workspaceID,
                tabID: targetEndpoint.tabID,
                sessionID: targetEndpoint.sessionID
            )
            if collectsStatusSamples {
                // Readiness and preview come from the agent-facing observation snapshot, never from
                // the row presentation below: the row substitutes a live candidate's name when the
                // grant carries none and knows nothing about send readiness, and neither substitution
                // may reach a queued notice. Materializing the redacted preview is why this runs only
                // on the authoritative pass, never on a location, Seen, settings, sidebar-menu, or
                // observer-role repaint.
                let observation = await authority.observationSnapshot(forTargetEndpoint: targetEndpoint)
                statusSamples.append(AgentSessionLinkPassiveStatusNotices.Sample(
                    reference: reference,
                    targetEndpoint: targetEndpoint,
                    targetSessionID: item.targetSessionID,
                    // The grant's own name, never the live candidate substitute the row below uses:
                    // a queued notice is agent-facing, exactly like the prompt inventory.
                    displayName: item.displayName,
                    status: AgentSessionLinkPassiveStatusNotices.Status(presentation.status),
                    idleForSend: observation?.idleForSend ?? false,
                    idleSince: observation?.idleSince,
                    waitingOn: observation?.waitingOn,
                    latestVisibleAssistantPreview: observation?.latestVisibleAssistantPreview
                ))
            }
            outbound.append(AgentMonitorPillProps.Outbound(
                linkID: item.linkID,
                generation: item.generation,
                targetSessionID: item.targetSessionID,
                targetEndpoint: targetEndpoint,
                displayName: item.displayName ?? target?.resolvedDisplayName
                    ?? AgentMonitorSessionIDFormatter.short(item.targetSessionID),
                providerDisplayName: target?.providerDisplayName,
                locationLabel: target?.locationLabel,
                status: presentation.status,
                lastActivityAt: presentation.lastActivityAt,
                hasUnreadActivity: hasUnreadActivity,
                targetRoute: targetRoute
            ))
        }

        let inbound: [AgentMonitorPillProps.Inbound] = inputs.inbound.items.compactMap { item in
            guard let observerEndpoint = inputs.inboundObserverEndpoints[item.linkID] else {
                assertionFailure("Active inbound oversight link is missing its exact observer endpoint.")
                return nil
            }
            let observer = candidatesByEndpoint[observerEndpoint]
            return AgentMonitorPillProps.Inbound(
                linkID: item.linkID,
                generation: item.generation,
                observerSessionID: item.observerSessionID,
                observerEndpoint: observerEndpoint,
                displayName: observer?.resolvedDisplayName
                    ?? AgentMonitorSessionIDFormatter.short(item.observerSessionID),
                // UI only, exactly as on the outbound rows: the observing session's window is what
                // the user needs to identify here, and it never reaches an agent-facing payload.
                //
                // Deliberately no location. Nothing observes an *observer's* session, so no
                // observer-side change schedules a refresh of this projection, and an execution-location
                // change neither drifts the endpoint identity nor feeds the oversight change channel.
                // A location rendered here would freeze. Provider survives that because it is locked
                // at first send, not because anything refreshes it.
                providerDisplayName: observer?.providerDisplayName
            )
        }

        let props = AgentMonitorPillProps(
            sessionID: sessionID,
            endpoint: endpoint,
            sidebarOversightMenu: AgentSidebarOversightMenuProjection.make(
                target: candidate,
                inputs: inputs,
                candidates: candidates
            ),
            outbound: outbound,
            inbound: inbound,
            recentNotices: inputs.notices.map { notice in
                AgentMonitorPillProps.Notice(
                    linkID: notice.linkID,
                    generation: notice.generation,
                    message: AgentMonitorNoticeFormatter.message(
                        for: notice,
                        endpointSessionID: sessionID,
                        // Resolved from the incarnations the revoked grant actually joined, which
                        // the notice carries: the grant record is gone, and a session-UUID lookup
                        // could label this ending with a duplicate incarnation's tab name.
                        observerDisplayName: notice.observerEndpoint
                            .flatMap { candidatesByEndpoint[$0] }?.resolvedDisplayName,
                        targetDisplayName: notice.targetEndpoint
                            .flatMap { candidatesByEndpoint[$0] }?.resolvedDisplayName
                    )
                )
            },
            canAddReason: AgentSessionLinkEndpointEligibility.addDisabledReason(
                candidate.eligibilityInput,
                roleAllowsOutboundMonitoring: candidate.roleAllowsOutboundMonitoring
            ),
            // The persisted observer-session setting, read straight from the exact live incarnation.
            // Unlike the queue it schedules against, it is session configuration rather than runtime
            // state, so it renders identically on an authoritative pass and a presentation-only repaint.
            autoWakeOnUpdatesEnabled: host?
                .agentSessionLinkAutoWakeOnUpdatesEnabled(for: candidate) ?? false,
            autoWakeTargetSessionIDs: host?
                .agentSessionLinkAutoWakeTargetSessionIDs(for: candidate) ?? [],
            autoWakeUnavailableReason: Self.autoWakeUnavailableReason(
                for: candidate,
                isFrozenForTermination: isFrozenForTermination
            )
        )
        return MonitorProjection(props: props, statusSamples: statusSamples)
    }

    /// Why this exact incarnation cannot take a setting write, or `nil` when it can.
    ///
    /// Deliberately only lifecycle states in which the write itself would fail. Zero links and
    /// temporary prompt-ineligibility are *not* reasons: the setting is session configuration, it is
    /// saved either way, and turning it off has to stay reachable from every state it can be on in.
    private static func autoWakeUnavailableReason(
        for candidate: AgentSessionLinkEndpointCandidate,
        isFrozenForTermination: Bool
    ) -> String? {
        if isFrozenForTermination { return AgentMonitorAutoWakeCopy.missingReason }
        if candidate.isClosing { return AgentMonitorAutoWakeCopy.closingReason }
        if !candidate.hasLoadedPersistedState || candidate.bindingTransitionInProgress {
            return AgentMonitorAutoWakeCopy.loadingReason
        }
        return nil
    }

    private struct MonitorTargetPresentation {
        let status: AgentMonitorLinkStatus
        let lastActivityAt: Date?
    }

    /// Cheap live status plus the monotonic activity high-water for one exact target incarnation.
    private func targetPresentation(
        for candidate: AgentSessionLinkEndpointCandidate?,
        exactEndpoint: DomainAgentSessionLinkEndpointIdentity?
    ) -> MonitorTargetPresentation {
        let chain = exactEndpoint.flatMap { endpoint in
            chains[endpoint.sessionID].flatMap { $0.endpoint == endpoint ? $0 : nil }
        }
        guard let projection = liveStatusProjection(for: candidate) else {
            return MonitorTargetPresentation(
                status: .unavailable,
                lastActivityAt: chain?.activityHighWater
            )
        }
        let highWater = exactEndpoint.map {
            observeActivity(projection.lastActivityAt, for: $0)
        } ?? projection.lastActivityAt
        return MonitorTargetPresentation(
            status: Self.monitorStatus(projection),
            lastActivityAt: highWater
        )
    }

    /// One exact live incarnation's cheap status/activity projection, or `nil` when there is nothing
    /// live to report on.
    private func liveStatusProjection(
        for candidate: AgentSessionLinkEndpointCandidate?
    ) -> AgentSessionLinkStatusProjection? {
        guard let candidate, let host else { return nil }
        return host.agentSessionLinkStatusProjection(for: candidate)
    }

    /// The single mapping from an observed projection to a rendered status.
    ///
    /// Shared by the rows and by the passive samples so a queued notice can never disagree with the
    /// row the user is looking at about what a target is doing.
    private static func monitorStatus(
        _ projection: AgentSessionLinkStatusProjection?
    ) -> AgentMonitorLinkStatus {
        guard let projection else { return .unavailable }
        return AgentMonitorLinkStatus(
            status: projection.status,
            pendingInteraction: projection.pendingInteractionKind
        )
    }

    /// Resolves one generation-qualified unread state while building the authoritative row, and
    /// establishes the baseline the first time this exact reference is rendered.
    ///
    /// Baselining here rather than at Add time is deliberate: the first authoritative row is the
    /// first moment the observer could have seen anything, so activity that predates the grant is
    /// never announced as new. The record is only *advanced* by an explicit acknowledgement — an
    /// unread row that keeps being repainted must stay unread.
    private func monitorHasUnreadActivity(
        for reference: DomainAgentSessionLinkReference,
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
        currentActivity: Date?
    ) -> Bool {
        guard let record = monitorSeenByReference[reference],
              record.observerEndpoint == observerEndpoint,
              record.targetEndpoint == targetEndpoint
        else {
            // First construction, or an endpoint replacement carrying the same reference: rebaseline
            // against current state rather than inferring a transition across the gap.
            monitorSeenByReference[reference] = MonitorSeenRecord(
                observerEndpoint: observerEndpoint,
                targetEndpoint: targetEndpoint,
                activityWatermark: currentActivity
            )
            return false
        }
        guard let currentActivity else { return false }
        guard let watermark = record.activityWatermark else { return true }
        return currentActivity > watermark
    }

    /// Advances one exact target's monotonic high-water and reconciles every observer against it.
    @discardableResult
    private func observeActivity(
        _ activity: Date?,
        for targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Date? {
        let chain = chains[targetEndpoint.sessionID].flatMap {
            $0.endpoint == targetEndpoint ? $0 : nil
        }
        return chain?.noteActivity(activity) ?? activity
    }

    // MARK: - Presentation-only monitor projection refresh

    /// Repaints the Oversee rows that render one target's execution location, and nothing else.
    ///
    /// Location lives only on observer-side outbound rows, is rebuilt from live window state, and is
    /// absent from every domain observation, prompt inventory, and MCP payload. A worktree, branch,
    /// workspace-name, or global-label edit therefore changes what the user should see while changing
    /// nothing the authority models — no change event is emitted, and the ordinary refresh would
    /// deduplicate the identical location-free snapshot anyway.
    ///
    /// Deliberately *not* an axis on `requestProjectionRefresh`: this path has no authority at all.
    /// It never sweeps, never invalidates or revokes a drifted endpoint, never publishes a target
    /// snapshot or prompt inventory, never invalidates tool advertisement, never advances the change
    /// sequence, and never wakes a waiter. Drift found on either hop is simply skipped and left to
    /// the authoritative paths that own it.
    func requestMonitorLocationRefresh(
        forExactTargetEndpoints endpoints: Set<DomainAgentSessionLinkEndpointIdentity>
    ) {
        guard !isFrozenForTermination else { return }
        // Only incarnations some observer actually renders: a location change on a session nobody
        // oversees has no row to repaint.
        let queued = endpoints.intersection(knownTargetEndpoints)
        guard !queued.isEmpty else { return }
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "oversight.locationRefresh",
                fields: [
                    "scope": "exact",
                    "requested": String(endpoints.count),
                    "queued": String(queued.count)
                ]
            )
        #endif
        requestMonitorProjectionRefresh(forExactTargetEndpoints: queued)
    }

    /// Conservative scan for the label inputs that carry no tab identity.
    ///
    /// A workspace rename or a global worktree label can change many endpoints' labels at once and
    /// names none of them. Scanning the observed targets — optionally narrowed to one workspace — is
    /// bounded by the number of live grants, and equal props deduplicate at the publication boundary.
    func requestMonitorLocationRefreshForObservedTargets(inWorkspace workspaceID: UUID? = nil) {
        let targets = workspaceID.map { id in
            knownTargetEndpoints.filter { $0.workspaceID == id }
        } ?? knownTargetEndpoints
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "oversight.locationRefresh",
                fields: [
                    "scope": "global",
                    "observedTargets": String(targets.count),
                    "workspaceScoped": workspaceID == nil ? "0" : "1"
                ]
            )
        #endif
        requestMonitorLocationRefresh(forExactTargetEndpoints: targets)
    }

    /// Resolves the exact observers of each changed target, revalidating the target across its own
    /// authority hop.
    private func resolveMonitorObservers(
        forExactTargetEndpoints targets: Set<DomainAgentSessionLinkEndpointIdentity>
    ) async -> Set<DomainAgentSessionLinkEndpointIdentity> {
        var observers: Set<DomainAgentSessionLinkEndpointIdentity> = []
        for target in targets {
            guard !isFrozenForTermination, monitorProjectionEndpointIsLive(target) else { continue }
            let inputs = await authority.projectionInputs(forEndpoint: target)
            // Re-proved after the hop: the tab may have closed or rebound while suspended, and a
            // superseded incarnation must not drag its former observers into a repaint.
            guard !isFrozenForTermination, monitorProjectionEndpointIsLive(target) else { continue }
            observers.formUnion(inputs.inboundObserverEndpoints.values)
        }
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "oversight.locationRefresh",
                fields: [
                    "scope": "drained",
                    "targets": String(targets.count),
                    "observers": String(observers.count)
                ]
            )
        #endif
        return observers
    }

    /// Queues observers already known to need a presentation-only projection repaint.
    private func requestMonitorProjectionRefresh(
        forExactObserverEndpoints endpoints: Set<DomainAgentSessionLinkEndpointIdentity>
    ) {
        guard !isFrozenForTermination else { return }
        pendingMonitorObserverEndpoints.formUnion(endpoints)
        scheduleMonitorProjectionRefresh()
    }

    /// Repaints every exact observer of the supplied targets through the same presentation-only lane.
    private func requestMonitorProjectionRefresh(
        forExactTargetEndpoints endpoints: Set<DomainAgentSessionLinkEndpointIdentity>
    ) {
        guard !isFrozenForTermination else { return }
        pendingMonitorTargetEndpoints.formUnion(endpoints)
        scheduleMonitorProjectionRefresh()
    }

    /// Repaints every live endpoint after candidate-local eligibility changes that carry no
    /// authority event.
    ///
    /// A session becoming hydrated, MCP-controlled, role-denied, or settled after a rebind changes
    /// both whether it appears as an available observer and whether its own target menu exists. This
    /// uses the presentation-only lane so the repaint cannot publish prompt inventory, consume its
    /// discarded `statusSamples`, reconcile passive work, advance target activity, or trigger Auto-wake.
    private func requestCandidatePresentationRefresh() {
        guard let host else { return }
        requestMonitorProjectionRefresh(
            forExactObserverEndpoints: Set(host.agentSessionLinkCandidates().map(\.domainEndpoint))
        )
    }

    private func scheduleMonitorProjectionRefresh() {
        guard monitorProjectionRefreshTask == nil else { return }
        monitorProjectionRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !isFrozenForTermination,
                  !pendingMonitorTargetEndpoints.isEmpty || !pendingMonitorObserverEndpoints.isEmpty
            {
                let targets = pendingMonitorTargetEndpoints
                var observers = pendingMonitorObserverEndpoints
                pendingMonitorTargetEndpoints.removeAll()
                pendingMonitorObserverEndpoints.removeAll()
                await observers.formUnion(
                    resolveMonitorObservers(forExactTargetEndpoints: targets)
                )
                await performMonitorProjectionRefresh(forExactObserverEndpoints: observers)
            }
            monitorProjectionRefreshTask = nil
        }
    }

    /// Rebuilds and publishes monitor props for each exact observer incarnation.
    private func performMonitorProjectionRefresh(
        forExactObserverEndpoints endpoints: Set<DomainAgentSessionLinkEndpointIdentity>
    ) async {
        for observer in endpoints {
            guard !isFrozenForTermination, monitorProjectionEndpointIsLive(observer) else { continue }
            let inputs = await authority.projectionInputs(forEndpoint: observer)
            guard !isFrozenForTermination, let host else { return }
            // One candidate read after the hop backs both the observer's own revalidation and the
            // peer lookup, so the rows cannot mix two window snapshots.
            let candidates = host.agentSessionLinkCandidates()
            guard let candidate = candidates.first(where: { $0.domainEndpoint == observer }) else {
                continue
            }
            let byEndpoint = Dictionary(
                candidates.map { ($0.domainEndpoint, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            // Rows only: `statusSamples` are deliberately dropped here. Location, Seen, settings,
            // sidebar-menu, and observer-role repaints are not authoritative status observations;
            // presentation work cannot queue a notice or trigger Auto-wake.
            let monitor = await makeMonitorProjection(
                for: candidate,
                inputs: inputs,
                candidates: candidates,
                candidatesByEndpoint: byEndpoint
            )
            host.agentSessionLinkPublishProjection(monitor.props, to: observer)
        }
    }

    private func monitorProjectionEndpointIsLive(
        _ endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        host?.agentSessionLinkCandidates().contains { $0.domainEndpoint == endpoint } ?? false
    }

    #if DEBUG
        /// Test seam: drains queued presentation-only projection refreshes, including work a drain
        /// enqueues, so assertions observe settled rows.
        func test_settleMonitorProjectionRefresh() async {
            while let task = monitorProjectionRefreshTask {
                await task.value
            }
        }
    #endif

    func dismissNotices(forEndpoint endpoint: DomainAgentSessionLinkEndpointIdentity) async {
        await authority.clearRecentRevocationNotices(forEndpoint: endpoint)
        await requestProjectionRefresh()
    }

    // MARK: - Unread acknowledgement

    /// One authorized, fully revalidated Seen action.
    ///
    /// Returned with both endpoint incarnations proved live and the target's activity high-water
    /// already advanced, so the caller commits its record with no further suspension.
    private struct AuthorizedSeenCommit {
        let lease: DomainAgentSessionLinkLease
        /// Activity already settled on the live target at the commit boundary.
        let activityHighWater: Date?
    }

    private enum SeenCommitAuthorization {
        case authorized(AuthorizedSeenCommit)
        case denied(message: String)
    }

    /// Authorizes Seen through the target's `.monitorPoll` proof, then revalidates the exact grant,
    /// endpoint incarnations, and live activity before returning a synchronous commit boundary.
    private func authorizeSeenCommit(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        expectedReference: DomainAgentSessionLinkReference
    ) async -> SeenCommitAuthorization {
        let staleMessage = "That oversight link is no longer active."
        let shutdownMessage = "RepoPrompt is shutting down, so new activity wasn’t marked seen."
        guard !isFrozenForTermination else {
            return .denied(message: shutdownMessage)
        }

        #if DEBUG
            test_observeSeenAuthorizationOperation?(.monitorPoll)
        #endif

        let authorized: AuthorizedTarget
        switch await authorizeTarget(
            operation: .monitorPoll,
            observerEndpoint: observerEndpoint,
            targetSessionID: targetSessionID
        ) {
        case let .success(target):
            authorized = target
        case .failure(.shuttingDown):
            return .denied(message: shutdownMessage)
        case .failure(.denied):
            return .denied(message: staleMessage)
        }

        let lease = authorized.lease
        let actualReference = DomainAgentSessionLinkReference(
            linkID: lease.linkID,
            generation: lease.linkGeneration
        )
        guard actualReference == expectedReference,
              lease.observer == observerEndpoint,
              lease.target == authorized.candidate.domainEndpoint
        else {
            return .denied(message: staleMessage)
        }

        guard await finalSeenLeaseValidation(lease) == nil,
              let host
        else {
            return .denied(message: staleMessage)
        }

        let currentCandidates = host.agentSessionLinkCandidates()
        guard currentCandidates.contains(where: { $0.domainEndpoint == lease.observer }),
              let currentTarget = currentCandidates.first(where: { $0.domainEndpoint == lease.target })
        else {
            return .denied(message: staleMessage)
        }

        let liveActivity = host.agentSessionLinkStatusProjection(for: currentTarget)?.lastActivityAt
        return .authorized(AuthorizedSeenCommit(
            lease: lease,
            activityHighWater: observeActivity(liveActivity, for: lease.target)
        ))
    }

    /// Acknowledges one row's newest activity as reviewed.
    ///
    /// Observer-local and presentation-only: it changes no target or authority, adds no MCP
    /// operation, and has no agent-visible effect. It is deliberately *not* invoked by View Agent —
    /// routing proves the exact target opened, not that its newest activity was read.
    func markMonitorActivitySeen(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        expectedReference: DomainAgentSessionLinkReference
    ) async -> AgentMonitorSeenOutcome {
        let commit: AuthorizedSeenCommit
        switch await authorizeSeenCommit(
            observerEndpoint: observerEndpoint,
            targetSessionID: targetSessionID,
            expectedReference: expectedReference
        ) {
        case let .authorized(value):
            commit = value
        case let .denied(message):
            return .failed(message: message)
        }

        guard let activityHighWater = commit.activityHighWater else {
            return .failed(message: "Current activity is unavailable. Try again.")
        }
        let record = MonitorSeenRecord(
            observerEndpoint: observerEndpoint,
            targetEndpoint: commit.lease.target,
            activityWatermark: activityHighWater
        )
        guard monitorSeenByReference[expectedReference] != record else {
            return .alreadySeen
        }
        monitorSeenByReference[expectedReference] = record
        requestMonitorProjectionRefresh(forExactTargetEndpoints: [commit.lease.target])
        return .marked
    }

    private func finalSeenLeaseValidation(
        _ lease: DomainAgentSessionLinkLease
    ) async -> DomainAgentSessionLinkError? {
        #if DEBUG
            await test_duringFinalSeenLeaseValidation?()
        #endif
        return await authority.validate(lease: lease)
    }

    // MARK: - Lane status notices

    /// Switches one exact observer incarnation's persisted **Auto-wake on updates** setting.
    ///
    /// Only the dashboard lands here; there is deliberately no agent-facing surface for it. It
    /// changes observer-session configuration only — no target is polled or mutated, no capability is
    /// minted, no link authority moves, and no turn is started here. Status collection and natural
    /// delivery are unaffected either way: they are always on for a live, eligible direct link, and
    /// this switch only decides whether already-pending actionable content may reserve one
    /// system-origin follow-up.
    ///
    /// Unlike the preference it replaces, it is symmetric and needs no links: the setting is saved
    /// with the session and is simply inert while the observer oversees nothing.
    func setAutoWakeOnOversightUpdates(
        _ enabled: Bool,
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) async -> AgentMonitorPassiveNoticeOutcome {
        let staleMessage = "That Agent session is no longer active."
        guard !isFrozenForTermination else {
            return .failed(message: "RepoPrompt is shutting down, so auto-wake wasn’t changed.")
        }
        guard let host,
              let candidate = host.agentSessionLinkCandidates()
              .first(where: { $0.domainEndpoint == observerEndpoint })
        else {
            return .failed(message: staleMessage)
        }
        let activeLinkCount = await authority
            .projectionInputs(forEndpoint: observerEndpoint).outbound.items.count
        // Re-proved after the hop: a tab that closed or rebound while this was suspended must not
        // have a setting written for the incarnation that replaced it.
        guard !isFrozenForTermination,
              let host = self.host,
              host.agentSessionLinkCandidates()
              .contains(where: { $0.domainEndpoint == observerEndpoint })
        else {
            return .failed(message: staleMessage)
        }
        guard host.agentSessionLinkAutoWakeOnUpdatesEnabled(for: candidate) != enabled else {
            return .alreadyInRequestedState(enabled: enabled, activeLinkCount: activeLinkCount)
        }
        guard host.agentSessionLinkSetAutoWakeOnUpdatesEnabled(enabled, for: observerEndpoint) else {
            return .failed(message: staleMessage)
        }
        // Republishes the rows carrying the settled value and re-evaluates the current queue: enabling
        // may schedule already-pending actionable content, and disabling cancels not-yet-accepted wake
        // work without ever clearing the lane queue.
        await requestProjectionRefresh(.sessions([observerEndpoint.sessionID]))
        return .changed(enabled: enabled, activeLinkCount: activeLinkCount)
    }

    func setAutoWakeTargetSelection(
        targetSessionIDs: Set<UUID>,
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) async -> AgentMonitorPassiveNoticeOutcome {
        let staleMessage = "That Agent session is no longer active."
        guard !isFrozenForTermination, let host,
              let candidate = host.agentSessionLinkCandidates()
              .first(where: { $0.domainEndpoint == observerEndpoint })
        else { return .failed(message: staleMessage) }
        let activeLinkCount = await authority
            .projectionInputs(forEndpoint: observerEndpoint).outbound.items.count
        guard !isFrozenForTermination,
              let host = self.host,
              host.agentSessionLinkCandidates().contains(where: { $0.domainEndpoint == observerEndpoint })
        else { return .failed(message: staleMessage) }
        let current = host.agentSessionLinkAutoWakeTargetSessionIDs(for: candidate)
        guard current != targetSessionIDs else {
            return .alreadyInRequestedState(enabled: true, activeLinkCount: activeLinkCount)
        }
        guard host.agentSessionLinkSetAutoWakeTargetSessionIDs(targetSessionIDs, for: observerEndpoint) else {
            return .failed(message: staleMessage)
        }
        await requestProjectionRefresh(.sessions([observerEndpoint.sessionID]))
        return .changed(enabled: true, activeLinkCount: activeLinkCount)
    }

    func setAutoWakeTargetSelection(
        targetSessionIDs: Set<UUID>,
        observerSessionID: UUID
    ) async -> AgentMonitorPassiveNoticeOutcome {
        guard let endpoint = host?.agentSessionLinkCandidates()
            .first(where: { $0.sessionID == observerSessionID })?.domainEndpoint
        else { return .failed(message: "That Agent session is no longer active.") }
        return await setAutoWakeTargetSelection(
            targetSessionIDs: targetSessionIDs,
            observerEndpoint: endpoint
        )
    }

    /// One observer's saved Auto-wake target selection, addressed by session UUID.
    ///
    /// An inbound row renders the *overseen* session's projection, whose selections belong to that
    /// session and never to the observer above it. Unlink recovery therefore has to ask for the
    /// observer's value by ID instead of reading the props it was invoked from.
    func autoWakeTargetSelection(observerSessionID: UUID) -> Set<UUID> {
        guard !isFrozenForTermination,
              let host,
              let observer = host.agentSessionLinkCandidates()
              .first(where: { $0.sessionID == observerSessionID })
        else { return [] }
        return host.agentSessionLinkAutoWakeTargetSessionIDs(for: observer)
    }

    /// Re-selects one target for an observer after a successful Undo re-link.
    ///
    /// Additive against whatever the observer holds *now*, so a selection the user changed during
    /// the recovery window survives the restore rather than being overwritten by a stale set.
    @discardableResult
    func restoreAutoWakeTargetSelection(
        targetSessionID: UUID,
        observerSessionID: UUID
    ) async -> AgentMonitorPassiveNoticeOutcome {
        await setAutoWakeTargetSelection(
            targetSessionIDs: autoWakeTargetSelection(observerSessionID: observerSessionID)
                .union([targetSessionID]),
            observerSessionID: observerSessionID
        )
    }

    // MARK: Auto-wake snooze routing

    /// Routes one pure Auto-wake snooze read to the live owning observer session.
    ///
    /// The bridge stores no snooze state, schedules no deadline, and decides no admission policy. It
    /// is the trusted *routing* boundary and nothing more: it re-resolves the current directional
    /// outbound link and re-proves the exact observer endpoint, target session, link ID, and
    /// generation before the coordinator is allowed to answer.
    func autoWakeSnoozeProjection(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        expectedReference: DomainAgentSessionLinkReference
    ) async -> Result<AgentSessionLinkAutoWakeSnoozeProjection?, AgentSessionLinkAutoWakeSnoozeFailure> {
        switch await resolveAutoWakeSnoozeHost(
            observerEndpoint: observerEndpoint,
            targetSessionID: targetSessionID,
            expectedReference: expectedReference
        ) {
        case let .failure(failure):
            .failure(failure)
        case let .success(host):
            host.agentSessionLinkAutoWakeSnoozeProjection(
                for: observerEndpoint,
                targetSessionID: targetSessionID,
                expectedReference: expectedReference
            )
        }
    }

    /// Routes one exact-reference Auto-wake snooze mutation to the live owning observer session.
    ///
    /// Same validation as the read, for the same reason: an unlink/relink reuses the target session
    /// UUID under a new generation, and an in-place observer rebind keeps the session UUID while
    /// advancing the endpoint's generations. Only a byte-for-byte current pairing may mutate.
    func mutateAutoWakeSnooze(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        expectedReference: DomainAgentSessionLinkReference,
        command: AgentSessionLinkAutoWakeSnoozeCommand,
        origin: AgentSessionLinkAutoWakeSnoozeOrigin
    ) async -> Result<AgentSessionLinkAutoWakeSnoozeMutationOutcome, AgentSessionLinkAutoWakeSnoozeFailure> {
        let host: AgentSessionLinkEndpointHost
        switch await resolveAutoWakeSnoozeHost(
            observerEndpoint: observerEndpoint,
            targetSessionID: targetSessionID,
            expectedReference: expectedReference
        ) {
        case let .failure(failure):
            return .failure(failure)
        case let .success(resolved):
            host = resolved
        }
        // The repaint is deliberately *not* requested here. Set, extend, clear, expiry, and pruning
        // all change the same map, and only one of them arrives through this method; owning the
        // refresh here would have left the other three silently stale. The coordinator requests it
        // from its single map-change commit instead.
        return host.agentSessionLinkMutateAutoWakeSnooze(
            for: observerEndpoint,
            targetSessionID: targetSessionID,
            expectedReference: expectedReference,
            command: command,
            origin: origin
        )
    }

    /// Republishes one exact observer's own monitor rows after its local Auto-wake policy changed.
    ///
    /// Nothing installs an observation on an *observer's* session — observations are installed per
    /// overseen target — so no target event will ever carry this change, and `requestUIRefresh` alone
    /// only re-renders the cached props. Presentation only: it republishes rows and moves no
    /// authority, reads no target, and never re-enters the wake pipeline.
    func requestObserverLocalPolicyRepaint(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        requestMonitorProjectionRefresh(forExactObserverEndpoints: [endpoint])
    }

    /// The shared fence both snooze entry points cross.
    ///
    /// Re-proved *after* the authority hop as well as before it, because a tab that closed or rebound
    /// while this was suspended must not have policy read or written for the incarnation that
    /// replaced it.
    private func resolveAutoWakeSnoozeHost(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        expectedReference: DomainAgentSessionLinkReference
    ) async -> Result<AgentSessionLinkEndpointHost, AgentSessionLinkAutoWakeSnoozeFailure> {
        guard !isFrozenForTermination else { return .failure(.shuttingDown) }
        guard let host,
              host.agentSessionLinkCandidates().contains(where: { $0.domainEndpoint == observerEndpoint })
        else { return .failure(.observerUnavailable) }
        guard await revalidateObserver(endpoint: observerEndpoint) else {
            return .failure(.observerUnavailable)
        }
        let outbound = await authority.projectionInputs(forEndpoint: observerEndpoint).outbound
        guard outbound.items.contains(where: {
            $0.linkID == expectedReference.linkID
                && $0.generation == expectedReference.generation
                && $0.targetSessionID == targetSessionID
        }) else {
            return .failure(.staleReference)
        }
        guard !isFrozenForTermination, let host = self.host,
              host.agentSessionLinkCandidates().contains(where: { $0.domainEndpoint == observerEndpoint })
        else { return .failure(.observerUnavailable) }
        return .success(host)
    }

    /// Applies one accepted provider receipt to the exact observer's queue.
    ///
    /// Synchronous because it runs at the provider's acceptance signal, on the same MainActor pass as
    /// the dispatch it acknowledges. The reducer enforces epoch scoping, monotonicity, and
    /// idempotence; the immediate republish is what stops a second natural dispatch from reclaiming a
    /// batch that was already physically delivered.
    func applyPassiveMonitorNoticeReceipt(
        _ receipt: AgentSessionLinkPassiveStatusNotices.Receipt,
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard var notices = passiveNoticesByObserver[observerEndpoint] else { return }
        notices.apply(receipt)
        passiveNoticesByObserver[observerEndpoint] = notices
        // No row repaint: the dashboard renders live status, never queue contents.
        publishPassiveNotices(notices.snapshot, to: observerEndpoint)
    }

    /// Reconciles one observer's queue against the authoritative sample set for this pass.
    ///
    /// Collection is an always-on property of a live, eligible, direct oversight relationship rather
    /// than something the user switches on: a reducer is created and silently baselined the first
    /// time an observer resolves a direct outbound target, and is torn down after one terminal empty
    /// snapshot when its last link goes away. Returns `nil` only for an endpoint that has never had
    /// one and still has nothing to collect, so an unrelated observer publishes nothing at all.
    private func reconcilePassiveNotices(
        for candidate: AgentSessionLinkEndpointCandidate,
        samples: [AgentSessionLinkPassiveStatusNotices.Sample],
        linkSetRevision: UInt64
    ) -> AgentSessionLinkPassiveStatusNotices.Snapshot? {
        let endpoint = candidate.domainEndpoint
        let existing = passiveNoticesByObserver[endpoint]
        guard existing != nil || !samples.isEmpty else { return nil }
        // Eligibility is re-read after this pass's authority hop rather than taken from the candidate
        // captured before it. Eligibility produces no authority event and no revision to compare, so
        // a suppression that landed during the hop has nothing else to catch it — and an observer that
        // cannot be told anything must stop accumulating rather than keep a backlog. Fails closed: an
        // endpoint that vanished during the hop is not deliverable.
        let current = host?.agentSessionLinkCandidates()
            .first { $0.domainEndpoint == endpoint }
        let deliverable = current.map(Self.passiveDeliveryIsPermitted) ?? false
        var notices = existing
            ?? AgentSessionLinkPassiveStatusNotices(observerEndpoint: endpoint)
        // One clock value per reconciliation, so a single sample set cannot stamp two edges with two
        // different "now"s, and so the timestamp names the status edge rather than render time.
        let observedAt = now()
        notices.enable(
            samples: samples,
            linkSetRevision: linkSetRevision,
            deliverable: deliverable,
            observedAt: observedAt
        )
        let masterEnabled = current.map {
            host?.agentSessionLinkAutoWakeOnUpdatesEnabled(for: $0) ?? false
        } ?? false
        let selectedTargetIDs = current.map {
            host?.agentSessionLinkAutoWakeTargetSessionIDs(for: $0) ?? []
        } ?? []
        let autoWakeLanes = samples.map { sample in
            AgentSessionLinkPassiveStatusNotices.AutoWakeLane(
                reference: sample.reference,
                targetEndpoint: sample.targetEndpoint,
                targetSessionID: sample.targetSessionID,
                isEffectivelySelected: masterEnabled || selectedTargetIDs.contains(sample.targetSessionID)
            )
        }
        notices.setAutoWakeLanes(autoWakeLanes)
        let snapshot = notices.snapshot
        if samples.isEmpty {
            // The last direct link went away. Publish one terminal empty snapshot so the view model
            // cannot keep serving deliverable content, then drop the reducer: a later re-add gets a
            // fresh queue epoch and a silent baseline rather than resuming this one's history.
            passiveNoticesByObserver.removeValue(forKey: endpoint)
        } else {
            passiveNoticesByObserver[endpoint] = notices
        }
        return snapshot
    }

    private func publishPassiveNotices(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard !isFrozenForTermination, let host else { return }
        host.agentSessionLinkPublishPassiveStatusNotices(snapshot, to: endpoint)
    }

    /// Drops queues whose exact observer incarnation is gone.
    ///
    /// Endpoint-scoped because a rebound tab keeps its session UUID, and a preference that survived
    /// the rebind would resume narrating targets the replacement incarnation was never granted.
    private func prunePassiveNotices(liveEndpoints: Set<DomainAgentSessionLinkEndpointIdentity>) {
        for endpoint in passiveNoticesByObserver.keys where !liveEndpoints.contains(endpoint) {
            passiveNoticesByObserver.removeValue(forKey: endpoint)
        }
    }

    /// Whether this observer incarnation may currently be handed an oversight supplement at all.
    ///
    /// Reuses the prompt eligibility predicate rather than inventing a second rule, so a suspended
    /// observer stops accumulating a backlog for exactly as long as it could not be told about it.
    private static func passiveDeliveryIsPermitted(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> Bool {
        AgentSessionLinkPromptEligibility.allowsSupplement(
            AgentSessionLinkPromptEligibility.Input(
                isChildSession: !candidate.isTopLevel,
                isMCPControlled: candidate.isMCPControlled,
                isMCPOriginated: candidate.isMCPOriginated,
                roleAllowsOutboundMonitoring: candidate.roleAllowsOutboundMonitoring
            )
        )
    }

    // MARK: - Operation-time authorization

    /// One authorized oversight target: the authority's short-lived lease plus the live candidate whose
    /// identity was just revalidated byte-for-byte against the grant endpoint.
    struct AuthorizedTarget {
        let lease: DomainAgentSessionLinkLease
        let candidate: AgentSessionLinkEndpointCandidate
    }

    enum AuthorizationFailure: Error, Equatable {
        /// Indistinguishable denial. Never reveals whether an ungranted UUID exists.
        case denied
        case shuttingDown

        init(_ error: DomainAgentSessionLinkError) {
            self = error == .runtimeShuttingDown ? .shuttingDown : .denied
        }
    }

    enum AttentionRequestDisposition: Equatable {
        case accepted
        case atCapacity
        /// Candidate UUIDs are present only when the caller omitted `observer_session_id`.
        case ambiguous(candidateObserverSessionIDs: [UUID]?, omittedCandidateCount: Int)
        case denied
        case shuttingDown
    }

    /// Enqueues one target-originated attention occurrence under an exact inverse grant.
    ///
    /// The authority proof is capability-free because this is not an observer operation. Stale exact
    /// endpoints are pruned before selector cardinality, the selected observer's delivery eligibility
    /// is checked without changing the target's role requirements, and final proof validation is the
    /// last suspension point before the already-baselined reducer mutates.
    func requestAttention(
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
        observerSessionID: UUID?
    ) async -> AttentionRequestDisposition {
        guard !isFrozenForTermination else { return .shuttingDown }
        guard let initialCandidates = await attentionCandidatesAfterPruning(
            targetEndpoint: targetEndpoint
        ) else {
            return .denied
        }
        let initialLiveEndpoints = Set(initialCandidates.map(\.domainEndpoint))

        let authorization: DomainAgentSessionLinkAuthority.RequestAttentionAuthorization
        switch await authority.authorizeRequestAttention(
            requesterEndpoint: targetEndpoint,
            observerSessionID: observerSessionID,
            liveEndpoints: initialLiveEndpoints
        ) {
        case let .success(value):
            authorization = value
        case let .failure(error):
            return Self.attentionDisposition(for: error, selectorWasOmitted: observerSessionID == nil)
        }

        guard let host else { return .denied }
        let registry = AgentSessionDeletionRegistry.shared
        if registry.isPermanentlyDeleted(sessionID: authorization.target.sessionID) {
            await invalidate(endpoint: authorization.target, reason: .sessionDeleted)
            return .denied
        }
        if registry.isPermanentlyDeleted(sessionID: authorization.observer.sessionID) {
            await invalidate(endpoint: authorization.observer, reason: .sessionDeleted)
            return .denied
        }
        if registry.isDeletionInProgress(sessionID: authorization.target.sessionID)
            || registry.isDeletionInProgress(sessionID: authorization.observer.sessionID)
        {
            return .denied
        }

        var currentCandidates = host.agentSessionLinkCandidates()
        guard currentCandidates.contains(where: { $0.domainEndpoint == authorization.target }) else {
            await invalidate(endpoint: authorization.target, reason: .targetIdentityDrift)
            return .denied
        }
        guard let observer = currentCandidates.first(where: {
            $0.domainEndpoint == authorization.observer
        }) else {
            await invalidate(endpoint: authorization.observer, reason: .observerIdentityDrift)
            return .denied
        }
        guard await revalidateObserverCapability(observer) else { return .denied }

        // Capability revalidation may revoke the link and may itself allow topology to move. Re-read
        // exact endpoints, then make the authority's validator the final suspension point.
        currentCandidates = host.agentSessionLinkCandidates()
        let currentLiveEndpoints = Set(currentCandidates.map(\.domainEndpoint))
        guard currentLiveEndpoints.contains(authorization.target),
              currentLiveEndpoints.contains(authorization.observer),
              let currentObserver = currentCandidates.first(where: {
                  $0.domainEndpoint == authorization.observer
              }),
              Self.passiveDeliveryIsPermitted(for: currentObserver)
        else {
            return .denied
        }
        guard !isFrozenForTermination else { return .shuttingDown }
        if let error = await authority.validateRequestAttentionAuthorization(
            authorization,
            liveEndpoints: currentLiveEndpoints
        ) {
            return Self.attentionDisposition(for: error, selectorWasOmitted: observerSessionID == nil)
        }
        guard !isFrozenForTermination else { return .shuttingDown }

        // The authority hop above releases MainActor. Fence the host-owned half of the proof too:
        // endpoint routing, selector-cardinality inputs, deletion state, and passive eligibility can
        // all move without changing the authority record that just validated. Any topology change is
        // a conservative denial; a retry will resolve the new stable cardinality truthfully.
        let finalCandidates = host.agentSessionLinkCandidates()
        let finalLiveEndpoints = Set(finalCandidates.map(\.domainEndpoint))
        guard finalLiveEndpoints == currentLiveEndpoints,
              finalLiveEndpoints.contains(authorization.target),
              let finalObserver = finalCandidates.first(where: {
                  $0.domainEndpoint == authorization.observer
              }),
              Self.passiveDeliveryIsPermitted(for: finalObserver),
              !registry.isPermanentlyDeleted(sessionID: authorization.target.sessionID),
              !registry.isPermanentlyDeleted(sessionID: authorization.observer.sessionID),
              !registry.isDeletionInProgress(sessionID: authorization.target.sessionID),
              !registry.isDeletionInProgress(sessionID: authorization.observer.sessionID)
        else {
            return .denied
        }

        // No `await` below this line: the proof, reducer revision, exact link generation, mutation,
        // storage, and publication form one MainActor pass.
        guard var notices = passiveNoticesByObserver[authorization.observer] else {
            return .denied
        }
        let previousQueueRevision = notices.snapshot.queueRevision
        let result = notices.requestAttention(
            reference: authorization.reference,
            targetEndpoint: authorization.target,
            targetSessionID: authorization.target.sessionID,
            linkSetRevision: authorization.observerLinkSetRevision,
            requestedAt: now()
        )
        switch result {
        case .accepted:
            passiveNoticesByObserver[authorization.observer] = notices
            if notices.snapshot.queueRevision != previousQueueRevision {
                publishPassiveNotices(notices.snapshot, to: authorization.observer)
            }
            return .accepted
        case .atCapacity:
            return .atCapacity
        case .unavailable:
            return .denied
        }
    }

    /// Removes stale exact endpoints before inverse selector cardinality is evaluated.
    ///
    /// Transiently ineligible or deletion-in-progress observers remain in the cardinality set and
    /// cause the request to deny rather than silently selecting a sibling. Only an endpoint that is
    /// actually absent or permanently deleted is pruned from authority.
    private func attentionCandidatesAfterPruning(
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) async -> [AgentSessionLinkEndpointCandidate]? {
        guard let host else { return nil }
        let registry = AgentSessionDeletionRegistry.shared
        var candidates = host.agentSessionLinkCandidates()
        guard candidates.contains(where: { $0.domainEndpoint == targetEndpoint }) else {
            await invalidate(endpoint: targetEndpoint, reason: .targetIdentityDrift)
            return nil
        }
        if registry.isPermanentlyDeleted(sessionID: targetEndpoint.sessionID) {
            await invalidate(endpoint: targetEndpoint, reason: .sessionDeleted)
            return nil
        }
        if registry.isDeletionInProgress(sessionID: targetEndpoint.sessionID) { return nil }

        let liveEndpoints = Set(candidates.map(\.domainEndpoint))
        let projection = await authority.projectionInputs(forEndpoint: targetEndpoint)
        let staleObservers = Set(projection.inboundObserverEndpoints.values).filter { endpoint in
            !liveEndpoints.contains(endpoint)
                || registry.isPermanentlyDeleted(sessionID: endpoint.sessionID)
        }
        for endpoint in staleObservers {
            await invalidate(
                endpoint: endpoint,
                reason: registry.isPermanentlyDeleted(sessionID: endpoint.sessionID)
                    ? .sessionDeleted
                    : .observerIdentityDrift
            )
        }
        if !staleObservers.isEmpty {
            candidates = host.agentSessionLinkCandidates()
        }
        return candidates
    }

    private static func attentionDisposition(
        for error: DomainAgentSessionLinkAuthority.RequestAttentionAuthorizationError,
        selectorWasOmitted: Bool
    ) -> AttentionRequestDisposition {
        switch error {
        case .denied:
            .denied
        case let .ambiguousObserver(candidateObserverSessionIDs, omittedCandidateCount):
            .ambiguous(
                candidateObserverSessionIDs: selectorWasOmitted ? candidateObserverSessionIDs : nil,
                omittedCandidateCount: selectorWasOmitted ? omittedCandidateCount : 0
            )
        case .runtimeShuttingDown:
            .shuttingDown
        }
    }

    /// Authorizes one target operation and revalidates both live endpoint incarnations.
    ///
    /// The lease alone is not durable authority: a link can outlive a lifecycle notification this
    /// process missed. Any drift atomically revokes the link *before* the denial is returned, so a
    /// stale endpoint can never be operated on twice.
    func authorizeTarget(
        operation: DomainAgentSessionTargetOperation,
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID
    ) async -> Result<AuthorizedTarget, AuthorizationFailure> {
        let leaseResult = await authority.authorize(
            operation: operation,
            observerEndpoint: observerEndpoint,
            targetSessionID: targetSessionID
        )
        let lease: DomainAgentSessionLinkLease
        switch leaseResult {
        case let .success(value):
            lease = value
        case let .failure(error):
            return .failure(AuthorizationFailure(error))
        }
        guard let candidate = await revalidateEndpoints(for: lease) else {
            return .failure(.denied)
        }
        return .success(AuthorizedTarget(lease: lease, candidate: candidate))
    }

    /// All-or-nothing authorization for a multi-target request.
    ///
    /// Every requested target is authorized and revalidated before any snapshot is returned, so a
    /// response can never mix authorized rows with a denial for another requested UUID.
    func authorizeTargets(
        operation: DomainAgentSessionTargetOperation,
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionIDs: [UUID]
    ) async -> Result<[AuthorizedTarget], AuthorizationFailure> {
        var authorized: [AuthorizedTarget] = []
        authorized.reserveCapacity(targetSessionIDs.count)
        for targetSessionID in targetSessionIDs {
            switch await authorizeTarget(
                operation: operation,
                observerEndpoint: observerEndpoint,
                targetSessionID: targetSessionID
            ) {
            case let .success(target):
                authorized.append(target)
            case let .failure(failure):
                return .failure(failure)
            }
        }
        return .success(authorized)
    }

    /// Byte-for-byte, generation-for-generation revalidation of both endpoints of one lease, plus a
    /// re-check of the observer's *current* capability to oversee.
    ///
    /// Identity equality alone is not enough. A session keeps the same endpoint incarnation when it
    /// is attached to external MCP control or when its effective role/tool policy changes, so an
    /// identity-only check would let a session that can no longer be granted oversight keep
    /// exercising a grant it was given earlier.
    ///
    /// - Returns: the live target candidate, or `nil` after revoking whatever became invalid.
    func revalidateEndpoints(
        for lease: DomainAgentSessionLinkLease
    ) async -> AgentSessionLinkEndpointCandidate? {
        guard let host else { return nil }
        // A deleted transcript is not operable, whatever the candidate sweep still says. The tombstone
        // outlives the tab, so this check also covers the window between the file being removed and
        // the view model tearing the endpoint down.
        let registry = AgentSessionDeletionRegistry.shared
        if registry.isPermanentlyDeleted(sessionID: lease.target.sessionID) {
            await invalidate(endpoint: lease.target, reason: .sessionDeleted)
            return nil
        }
        if registry.isPermanentlyDeleted(sessionID: lease.observer.sessionID) {
            await invalidate(endpoint: lease.observer, reason: .sessionDeleted)
            return nil
        }
        // A deletion that is only running denies this operation and leaves the grant alone. Invalidating
        // here would revoke the link — and delete its saved row — for an attempt that can still fail.
        if registry.isDeletionInProgress(sessionID: lease.target.sessionID)
            || registry.isDeletionInProgress(sessionID: lease.observer.sessionID)
        {
            return nil
        }
        let candidates = host.agentSessionLinkCandidates()
        let liveTarget = candidates.first { $0.domainEndpoint == lease.target }
        let liveObserver = candidates.first { $0.domainEndpoint == lease.observer }

        // Fail closed and eagerly: a missed lifecycle hook must not leave an operable grant behind.
        if liveObserver == nil {
            await invalidate(endpoint: lease.observer, reason: .observerIdentityDrift)
        }
        if liveTarget == nil {
            await invalidate(endpoint: lease.target, reason: .targetIdentityDrift)
        }
        guard let liveTarget, let liveObserver else { return nil }

        guard await revalidateObserverCapability(liveObserver) else { return nil }
        return liveTarget
    }

    /// Re-checks one live observer's capability, revoking its outbound grants on permanent loss.
    ///
    /// - Returns: `true` when the observer may proceed.
    @discardableResult
    private func revalidateObserverCapability(
        _ observer: AgentSessionLinkEndpointCandidate
    ) async -> Bool {
        switch AgentSessionLinkEndpointEligibility.observerOperationEligibility(
            observer.eligibilityInput,
            roleAllowsOutboundMonitoring: observer.roleAllowsOutboundMonitoring
        ) {
        case .eligible:
            return true
        case .transientlyUnavailable:
            // Same session, momentary state: deny this operation but keep the grant.
            return false
        case .disqualified:
            await revokeOutboundLinks(
                observerEndpoint: observer.domainEndpoint,
                reason: .observerNoLongerEligible
            )
            return false
        }
    }

    /// Revokes only the links this exact endpoint incarnation *observes through*.
    ///
    /// Deliberately not `invalidate(endpoint:)`: that would also drop links where this session is the
    /// target, and being observed requires no outbound eligibility at all. An incarnation that loses
    /// the ability to oversee must keep being overseeable and must not revoke a live sibling's grants.
    private func revokeOutboundLinks(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        reason: DomainAgentSessionLinkRevocationReason
    ) async {
        let capturedBookkeeping = bookkeepingByReference
        let inventory = await authority.links(forObserverEndpoint: observerEndpoint)
        guard !inventory.isEmpty else { return }
        var notices: [DomainAgentSessionLinkRevocationNotice] = []
        for item in inventory.items {
            if case let .revoked(notice) = await authority.revoke(
                linkID: item.linkID,
                generation: item.generation,
                reason: reason
            ) {
                notices.append(notice)
            }
        }
        await reconcile(after: notices, capturedBookkeeping: capturedBookkeeping)
    }

    /// Resolves and re-checks the caller for a targetless operation.
    ///
    /// `list` presents no per-target proof, so without this it would remain callable by an observer
    /// that had already lost the capability. The lookup is by exact endpoint rather than by session
    /// UUID: a duplicate live incarnation must not satisfy the check on the granted one's behalf.
    private func revalidateObserver(
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) async -> Bool {
        guard let host else { return false }
        let registry = AgentSessionDeletionRegistry.shared
        if registry.isPermanentlyDeleted(sessionID: endpoint.sessionID) {
            await invalidate(endpoint: endpoint, reason: .sessionDeleted)
            return false
        }
        if registry.isDeletionInProgress(sessionID: endpoint.sessionID) { return false }
        guard let observer = host.agentSessionLinkCandidates()
            .first(where: { $0.domainEndpoint == endpoint })
        else {
            await invalidate(endpoint: endpoint, reason: .observerIdentityDrift)
            return false
        }
        return await revalidateObserverCapability(observer)
    }

    /// Authoritative outbound inventory for a targetless `list`.
    ///
    /// `list` names no target, so it is authorized against the caller's own grant set and exists only
    /// while at least one outbound link remains.
    func inventory(
        forObserverEndpoint observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) async -> Result<DomainAgentSessionLinkInventory, AuthorizationFailure> {
        guard await revalidateObserver(endpoint: observerEndpoint) else {
            return .failure(.denied)
        }
        return await authority.authorizeInventory(observerEndpoint: observerEndpoint)
            .mapError(AuthorizationFailure.init)
    }

    func setWaitingOn(
        summary: String?,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) async -> Bool {
        guard let host,
              host.agentSessionLinkCandidates().contains(where: { $0.domainEndpoint == endpoint }),
              await authority.hasActiveLink(endpoint: endpoint)
        else { return false }
        let value: DomainAgentSessionWaitingOn?
        if let summary {
            guard let waitingOn = DomainAgentSessionWaitingOn(summary: summary, declaredAt: now()) else {
                return false
            }
            value = waitingOn
        } else {
            value = nil
        }
        return host.agentSessionLinkSetWaitingOn(value, for: endpoint)
    }

    /// Current sanitized target state plus a freshly minted successor wait cursor.
    func targetState(
        for lease: DomainAgentSessionLinkLease
    ) async -> DomainAgentSessionLinkTargetState? {
        await authority.targetState(for: lease)
    }

    /// Bounded, event-driven wait. The authority owns one-waiter admission and atomic multi-target
    /// slot reservation; this is a pure forward so the service never holds the authority itself.
    func wait(
        requests: [DomainAgentSessionLinkWaitRequest],
        until predicate: DomainAgentSessionLinkWaitPredicate,
        timeoutSeconds: TimeInterval
    ) async -> DomainAgentSessionLinkWaitResult {
        await authority.wait(requests: requests, until: predicate, timeoutSeconds: timeoutSeconds)
    }

    func openReadCursor(
        lease: DomainAgentSessionLinkLease,
        anchor: DomainAgentSessionLinkReadAnchor,
        direction: DomainAgentSessionLinkReadDirection
    ) async -> Result<DomainAgentSessionLinkReadCursorState, DomainAgentSessionLinkError> {
        await authority.openReadCursor(lease: lease, anchor: anchor, direction: direction)
    }

    func resolveReadCursor(
        lease: DomainAgentSessionLinkLease,
        opaqueCursor: String
    ) async -> DomainAgentSessionLinkReadCursorDisposition {
        await authority.resolveReadCursor(lease: lease, opaqueCursor: opaqueCursor)
    }

    /// Whether the exact caller endpoint incarnation currently holds at least one outbound link.
    ///
    /// This remains the live readiness and authorization input for observer operations. Dynamic tool
    /// visibility uses the separate exact-link predicate below, so an inbound-only caller can reach
    /// its narrow inverse operation without acquiring outbound oversight.
    func hasActiveOutboundLink(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) async -> Bool {
        await authority.hasActiveOutboundLink(observerEndpoint: observerEndpoint)
    }

    /// Whether the exact caller endpoint holds any inbound or outbound grant.
    ///
    /// Catalog visibility only. Observer operations continue to authorize through the outbound-only
    /// paths above, and `request_attention` continues to authorize through its exact inverse proof.
    func hasActiveLink(endpoint: DomainAgentSessionLinkEndpointIdentity) async -> Bool {
        await authority.hasActiveLink(endpoint: endpoint)
    }

    // MARK: - Sanitized read

    /// Reads one sanitized transcript page for an already-authorized, already-revalidated target.
    func transcriptPage(
        for target: AuthorizedTarget,
        anchor: AgentSessionLinkTranscriptAnchor?,
        direction: AgentSessionLinkReadDirectionInput,
        maxItems: Int,
        maxOutputBytes: Int
    ) async -> Result<AgentSessionLinkTranscriptPage, AgentSessionLinkReadUnavailableReason> {
        guard let host else { return .failure(.endpointInvalidated) }
        return await host.agentSessionLinkTranscriptPage(
            for: target.candidate,
            anchor: anchor,
            direction: direction,
            maxItems: maxItems,
            maxOutputBytes: maxOutputBytes,
            readerSessionID: target.lease.observer.sessionID
        )
    }

    // MARK: - Atomic idle-only send

    /// Why a send never reached the delivery transaction at all.
    ///
    /// These are distinct from `AgentSessionLinkSendFailure`: they are decided by the authority's
    /// ledger before the target is touched, so no target state was ever inspected or mutated.
    enum SendRejection: String, Equatable {
        case idempotencyConflict = "idempotency_conflict"
        case sendAlreadyInProgress = "send_already_in_progress"
        /// Transient saturation of the in-flight send limit. Keeps the original wire string because
        /// this is the case its "try again shortly" wording was always true for.
        case deliveryLedgerFull = "delivery_ledger_full"
        /// Exhaustion of the retained settled-outcome limit. A separate result because it is not
        /// transient: only revoking a link generation or restarting the runtime releases retained
        /// outcomes, so a caller that treats it as a retry signal spins forever.
        case deliveryLedgerExhausted = "delivery_ledger_exhausted"
        case shuttingDown = "shutting_down"
        case denied
    }

    enum SendOutcome: Equatable {
        /// A durably accepted delivery, or the exact stored receipt for a duplicate retry.
        case receipt(DomainAgentSessionLinkSendReceipt)
        /// The transaction ran and refused without delivering.
        case blocked(AgentSessionLinkSendFailure)
        /// The ledger refused before the transaction started.
        case rejected(SendRejection)
        /// The caller named a workflow nothing currently answers to. A caller mistake rather than an
        /// operational state, so the service raises it as an invalid parameter; the reservation it
        /// was resolving for is abandoned, leaving the key free for a corrected retry.
        case workflowUnavailable(reference: String)
    }

    /// How the one-shot workflow for one delivery is supplied.
    private enum SendWorkflowInput {
        /// An immediate send: the caller's reference, resolved only after the ledger has answered.
        case unresolved(AgentWorkflowReference?)
        /// A queued drain: resolved and frozen when the entry was admitted, never re-read. Re-reading
        /// the store at delivery time would let a rename or delete change what the user authorized.
        case resolved(AgentWorkflowDefinition?)
    }

    /// Main-actor hooks a queued drain installs around the authority commit fence.
    ///
    /// Immediate sends pass none: there is no pending entry to invalidate, so the fence is the
    /// authority's alone.
    private struct SendCommitFence {
        /// Runs immediately before the authority hop. `false` abandons the delivery with no target
        /// mutation; `true` closes the cancellation window for good.
        let willCommit: @MainActor () -> Bool
        /// Runs immediately after a successful commit, still on the main actor.
        let didCommit: @MainActor () -> Void
    }

    /// Orchestrates one attributed send across the authority ledger and the target's MainActor.
    ///
    /// The reservation is settled on exactly one path: a delivered outcome retains a stable receipt,
    /// and every refusal abandons the reservation so a later retry with the same key may proceed.
    /// A retry after a *delivered* send replays the stored receipt instead of delivering twice.
    ///
    /// A named workflow is resolved *after* the ledger answers, never before. An already-settled key
    /// replays its stored receipt without a workflow lookup, so a retry stays idempotent even if the
    /// workflow it originally named has since been renamed or deleted.
    func send(
        target: AuthorizedTarget,
        message: String,
        idempotencyKey: String,
        workflowReference: AgentWorkflowReference?
    ) async -> SendOutcome {
        await performSend(
            target: target,
            message: message,
            idempotencyKey: idempotencyKey,
            messageDigest: AgentSessionLinkMessageDigest.digest(
                message: message,
                workflowSelector: AgentWorkflowReference.canonicalSelector(for: workflowReference)
            ),
            workflow: .unresolved(workflowReference),
            commitFence: nil
        )
    }

    /// The single delivery path both an immediate `send` and a queued drain run through.
    ///
    /// - Parameters:
    ///   - messageDigest: the caller's canonical request identity. Passed in rather than derived so a
    ///     queued entry commits under the digest it was admitted with, not one recomputed from a
    ///     workflow selector it no longer holds.
    private func performSend(
        target: AuthorizedTarget,
        message: String,
        idempotencyKey: String,
        messageDigest: String,
        workflow workflowInput: SendWorkflowInput,
        commitFence: SendCommitFence?
    ) async -> SendOutcome {
        guard let host else { return .rejected(.denied) }
        // The observer's own live candidate supplies the attribution name. Requiring an exact
        // identity match here means a drifted observer cannot have its send attributed to the
        // incarnation that was granted the link.
        guard let observer = host.agentSessionLinkCandidates()
            .first(where: { $0.domainEndpoint == target.lease.observer })
        else {
            await invalidate(endpoint: target.lease.observer, reason: .observerIdentityDrift)
            return .rejected(.denied)
        }

        let disposition = await authority.beginSend(
            lease: target.lease,
            idempotencyKey: idempotencyKey,
            messageDigest: messageDigest
        )
        let reservation: DomainAgentSessionLinkSendReservation
        switch disposition {
        case let .reserved(value):
            reservation = value
        case let .duplicate(receipt):
            return .receipt(receipt)
        case .inProgress:
            return .rejected(.sendAlreadyInProgress)
        case .indeterminate:
            // A spent key whose durable outcome was never established. Replaying the same terminal
            // answer is the only safe response: there is no receipt to return and re-delivering could
            // duplicate a row that did commit.
            return .blocked(.persistenceIndeterminate)
        case .conflict:
            return .rejected(.idempotencyConflict)
        case .inFlightLimitReached:
            return .rejected(.deliveryLedgerFull)
        case .retainedOutcomeLimitReached:
            return .rejected(.deliveryLedgerExhausted)
        case let .rejected(error):
            return .rejected(error == .runtimeShuttingDown ? .shuttingDown : .denied)
        }

        // Only a *fresh* reservation resolves a workflow, and only after the link was authorized:
        // resolving earlier would let an unauthorized caller learn which workflows exist, and
        // resolving on the duplicate path would fail a legitimate retry over a workflow the user
        // edited away. Resolution is a synchronous read of the main-actor store, so it introduces no
        // new suspension point between the reservation and the transaction's own fences.
        var workflow: AgentWorkflowDefinition?
        switch workflowInput {
        case let .resolved(value):
            workflow = value
        case let .unresolved(workflowReference):
            if let workflowReference {
                guard let resolved = workflowReference.resolved() else {
                    // Nothing is staged yet, so releasing the reservation is the whole rollback: no
                    // row, no transcript mutation, and the same key may be retried with a valid
                    // reference.
                    await authority.abandonSend(reservation: reservation)
                    // Releasing a reservation is a ledger settlement like any other. Skipping the
                    // trigger here would strand every entry parked on this link's in-flight send or
                    // on authority-wide saturation, because the slot this call just freed produced
                    // no other event.
                    notePendingSendLedgerSettled(on: target.lease.reference)
                    return .workflowUnavailable(reference: workflowReference.reference)
                }
                workflow = resolved
            }
        }

        let request = AgentSessionLinkSendRequest(
            linkID: target.lease.linkID,
            linkGeneration: target.lease.linkGeneration,
            // The exact granted incarnation, not its session UUID. The transaction crosses two awaits
            // after this point, and only the full identity can prove the observer that was
            // authorized is still the observer that exists.
            observerEndpoint: target.lease.observer,
            observerDisplayName: observer.resolvedDisplayName,
            message: message,
            workflow: workflow
        )
        // Re-read at every fence the transaction crosses. It is deliberately pure endpoint/window
        // liveness and never consults the authority: after the commit fence, manual revocation is
        // intentionally allowed to lose, so link liveness must not gate the post-persistence recheck.
        let liveness: AgentSessionLinkSendLivenessProbe = { [weak self] in
            guard let self, let host = self.host else { return .unavailable }
            return host.agentSessionLinkSendLiveness(
                observer: request.observerEndpoint,
                target: target.lease.target
            )
        }
        let authority = authority
        let outcome = await host.agentSessionLinkPerformSend(
            to: target.candidate,
            request: request,
            liveness: liveness,
            commitAuthorization: {
                // A queued drain's cancellation cutoff, taken synchronously on the bridge's main
                // actor immediately before the authority hop. Refusing here is indistinguishable
                // from losing the authority race: nothing is staged yet, so the delivery unwinds
                // with no transcript mutation at all.
                if let commitFence, !commitFence.willCommit() {
                    return .linkRevoked
                }
                let outcome = await AgentSessionLinkSendCommitOutcome(
                    authority.commitSendAuthorization(
                        reservation: reservation,
                        linkGeneration: reservation.linkGeneration
                    )
                )
                if outcome == .committed {
                    commitFence?.didCommit()
                }
                return outcome
            }
        )

        switch outcome {
        case let .delivered(delivery):
            let receipt = DomainAgentSessionLinkSendReceipt(
                targetSessionID: target.lease.target.sessionID,
                targetItemID: delivery.targetItemID.uuidString,
                acceptedAt: delivery.acceptedAt,
                deliveryState: delivery.deliveryState,
                resultingRunState: delivery.resultingRunState
            )
            await authority.completeSend(reservation: reservation, receipt: receipt)
            // Publish immediately so both endpoints show the target as running without waiting for
            // the observation pipeline's next main-queue hop.
            publishTargetSnapshot(forTargetSession: target.lease.target.sessionID)
            notePendingSendLedgerSettled(on: target.lease.reference)
            return .receipt(receipt)
        case let .blocked(failure):
            if failure.isDeliveryIndeterminate {
                // The transaction could neither commit nor prove a rollback. Settling a terminal
                // tombstone keeps the key permanently spent, so a retry can never be admitted as a
                // fresh delivery against a row that may already be on disk.
                await authority.settleIndeterminateSend(reservation: reservation)
            } else {
                await authority.abandonSend(reservation: reservation)
            }
            notePendingSendLedgerSettled(on: target.lease.reference)
            return .blocked(failure)
        }
    }

    // MARK: - One pending send per link generation

    /// What a queue admission or cancellation produced.
    enum QueueOutcome: Equatable {
        /// The entry is now pending. `replaced` reports that it displaced a different key;
        /// `duplicate` reports an idempotent same-key, same-payload retry.
        case queued(replaced: Bool, duplicate: Bool)
        /// A queue-state result with no delivery attempt: `pending_send_exists`, `cancelled`,
        /// `not_pending`, `pending_send_mismatch`, or `too_late`.
        case result(AgentSessionLinkQueueResult)
        /// The ordinary send path answered: the entry drained immediately, the ledger replayed a
        /// settled outcome for its key, or admission itself was refused.
        case send(SendOutcome)
    }

    /// Admits one pre-authorized send for delivery when the target next becomes sendable.
    ///
    /// Admission carries no proof about the caller's own turn. The user's exact direct grant is the
    /// delegation, and the observer is responsible under the trusted prompt contract for queueing
    /// only in service of an explicit current or standing instruction from its own user. Everything
    /// structural — the link, both endpoint incarnations, the target's readiness — is proven again
    /// at every drain, because those facts genuinely can change.
    ///
    /// The order below is the contract. The slot is arbitrated before anything is resolved, so an
    /// idempotent retry never re-resolves a workflow; the ledger is consulted before the workflow is
    /// resolved, so an already-settled key replays even if the workflow it named is gone; and the
    /// slot is arbitrated a second time after those awaits, because both of them suspend.
    func queueSend(
        target: AuthorizedTarget,
        message: String,
        idempotencyKey: String,
        workflowReference: AgentWorkflowReference?,
        replacePending: Bool
    ) async -> QueueOutcome {
        guard !isFrozenForTermination else { return .send(.rejected(.shuttingDown)) }
        guard let host else { return .send(.rejected(.denied)) }
        // Exact granted incarnation only: a stale or duplicate live incarnation of the same session
        // UUID must not install an entry against a lease it was never granted.
        guard host.agentSessionLinkCandidates()
            .contains(where: { $0.domainEndpoint == target.lease.observer })
        else {
            await invalidate(endpoint: target.lease.observer, reason: .observerIdentityDrift)
            return .send(.rejected(.denied))
        }

        let reference = target.lease.reference
        let digest = AgentSessionLinkMessageDigest.digest(
            message: message,
            workflowSelector: AgentWorkflowReference.canonicalSelector(for: workflowReference)
        )

        // First arbitration: short-circuits everything that needs no lookup at all.
        switch AgentSessionLinkPendingSend.slotDecision(
            current: pendingSendsByReference[reference],
            idempotencyKey: idempotencyKey,
            requestDigest: digest,
            replacePending: replacePending
        ) {
        case let .replay(revision):
            return await drainAndReport(
                reference: reference,
                revision: revision,
                replaced: false,
                duplicate: true
            )
        case .conflict:
            return .send(.rejected(.idempotencyConflict))
        case .occupied:
            return .result(.pendingSendExists)
        case .tooLate:
            return .result(.tooLate)
        case .install:
            break
        }

        // Consulted before the workflow is resolved: a key whose delivery already settled has to
        // replay its stored outcome even when the workflow it originally named has since been
        // renamed or deleted. This reserves nothing, so no in-flight slot is held while the message
        // waits for the target.
        switch await authority.probeSend(
            lease: target.lease,
            idempotencyKey: idempotencyKey,
            messageDigest: digest
        ) {
        case .unused:
            break
        case let .duplicate(receipt):
            return .send(.receipt(receipt))
        case .inProgress:
            return .send(.rejected(.sendAlreadyInProgress))
        case .indeterminate:
            return .send(.blocked(.persistenceIndeterminate))
        case .conflict:
            return .send(.rejected(.idempotencyConflict))
        case let .rejected(error):
            return .send(.rejected(error == .runtimeShuttingDown ? .shuttingDown : .denied))
        }

        // Resolved before the slot is touched. A reference nothing answers to therefore leaves any
        // existing entry exactly as it was, which is the whole point of validating the replacement
        // in full before installing it.
        var workflow: AgentWorkflowDefinition?
        if let workflowReference {
            guard let resolved = workflowReference.resolved() else {
                return .send(.workflowUnavailable(reference: workflowReference.reference))
            }
            workflow = resolved
        }

        // Second arbitration. The probe suspended, so the entry this call decided to displace may
        // have drained, been cancelled, or been replaced meanwhile.
        let replaced: Bool
        switch AgentSessionLinkPendingSend.slotDecision(
            current: pendingSendsByReference[reference],
            idempotencyKey: idempotencyKey,
            requestDigest: digest,
            replacePending: replacePending
        ) {
        case let .replay(revision):
            return await drainAndReport(
                reference: reference,
                revision: revision,
                replaced: false,
                duplicate: true
            )
        case .conflict:
            return .send(.rejected(.idempotencyConflict))
        case .occupied:
            return .result(.pendingSendExists)
        case .tooLate:
            return .result(.tooLate)
        case let .install(wasReplaced):
            replaced = wasReplaced
        }

        // Atomic on the main actor: the old entry stops existing and the new one starts in the same
        // synchronous step, so no drain can ever observe a slot that is momentarily empty or doubly
        // occupied. A drain already suspended on the old revision compares out at its next fence.
        let entry = AgentSessionLinkPendingSend(
            revision: UUID(),
            reference: reference,
            observerEndpoint: target.lease.observer,
            targetSessionID: target.lease.target.sessionID,
            message: message,
            idempotencyKey: idempotencyKey,
            requestDigest: digest,
            workflow: workflow,
            queuedAt: now()
        )
        pendingSendsByReference[reference] = entry
        pendingSendResultsByReference.removeValue(forKey: reference)
        return await drainAndReport(
            reference: reference,
            revision: entry.revision,
            replaced: replaced,
            duplicate: false
        )
    }

    /// Removes this link's pending entry, if the caller still identifies it and it has not crossed
    /// its commit cutoff.
    ///
    /// Four exact checks, and nothing at all about what started the caller's turn. The caller must
    /// present the exact granted observer incarnation — a drifted or duplicate one invalidates the
    /// endpoint instead of mutating a queue it does not hold the lease for. The entry must exist under
    /// this link's current reference, so a cancel aimed at a replaced generation removes nothing. Its
    /// `idempotency_key` must match the queued message, so a stale cancel cannot discard a newer
    /// replacement that took the slot. And the entry must still be in a cancellable phase: past the
    /// commit fence the send is no longer stoppable, and `too_late` is the only honest answer.
    func cancelPendingSend(
        target: AuthorizedTarget,
        idempotencyKey: String
    ) async -> QueueOutcome {
        guard let host else { return .send(.rejected(.denied)) }
        // Exact granted incarnation only, for the same reason admission requires it: a drifted or
        // duplicate incarnation must not mutate a queue it does not hold the lease for.
        guard host.agentSessionLinkCandidates()
            .contains(where: { $0.domainEndpoint == target.lease.observer })
        else {
            await invalidate(endpoint: target.lease.observer, reason: .observerIdentityDrift)
            return .send(.rejected(.denied))
        }
        let reference = target.lease.reference
        guard let entry = pendingSendsByReference[reference] else { return .result(.notPending) }
        // Matched on both the current link reference and the key, so a stale cancel issued against an
        // entry that has since been replaced removes nothing.
        guard entry.idempotencyKey == idempotencyKey else { return .result(.pendingSendMismatch) }
        guard entry.phase.isCancellable else { return .result(.tooLate) }
        pendingSendsByReference.removeValue(forKey: reference)
        // A cancellation is a queue mutation like any other, so the outcome the slot was retaining
        // stops being current with it.
        pendingSendResultsByReference.removeValue(forKey: reference)
        return .result(.cancelled)
    }

    /// This link's observer-facing queue state.
    func pendingSendProjection(
        for lease: DomainAgentSessionLinkLease
    ) -> AgentSessionLinkPendingSendProjection {
        AgentSessionLinkPendingSendProjection(
            pending: pendingSendsByReference[lease.reference],
            lastResult: pendingSendResultsByReference[lease.reference]
        )
    }

    /// Queue state for several leases at once, keyed by target session UUID.
    ///
    /// Exists for `wait`, which resumes off the main actor and needs one hop rather than one per
    /// target. Keyed by target session because that is how the response addresses its rows; the
    /// lookup itself is still generation-exact, so a lease whose link was revoked while the wait was
    /// parked simply contributes nothing.
    func pendingSendProjections(
        for leases: [DomainAgentSessionLinkLease]
    ) -> [UUID: AgentSessionLinkPendingSendProjection] {
        var result: [UUID: AgentSessionLinkPendingSendProjection] = [:]
        for lease in leases {
            let projection = pendingSendProjection(for: lease)
            guard !projection.isEmpty else { continue }
            result[lease.target.sessionID] = projection
        }
        return result
    }

    // MARK: Drain

    /// Runs one drain for a freshly installed or replayed entry and reports what it produced.
    ///
    /// A busy target leaves the entry pending and answers `queued`; an already-sendable one delivers
    /// through the ordinary send path and answers with that receipt, which is what makes
    /// `when_sendable` degrade to an immediate send rather than an extra round trip.
    private func drainAndReport(
        reference: DomainAgentSessionLinkReference,
        revision: UUID,
        replaced: Bool,
        duplicate: Bool
    ) async -> QueueOutcome {
        await drainPendingSend(reference: reference)
        if pendingSendsByReference[reference]?.revision == revision {
            return .queued(replaced: replaced, duplicate: duplicate)
        }
        guard let result = pendingSendResultsByReference[reference], result.revision == revision else {
            // Cleared with no retained outcome: the link ended underneath the entry, which is the
            // same answer every other operation on a dead link gives.
            return .send(.rejected(.denied))
        }
        return .send(sendOutcome(for: result.outcome))
    }

    /// Delivers one pending entry, if it is still the current one and the target now accepts it.
    ///
    /// Every drain reauthorizes from scratch. Queue-time authorization proved the *user* asked for
    /// this message; it never proved the link, the endpoint incarnations, or the target's readiness
    /// are still what they were, and all three are re-proven here and again inside the transaction
    /// after every await it crosses.
    private func drainPendingSend(reference: DomainAgentSessionLinkReference) async {
        guard !isFrozenForTermination else {
            pendingSendsByReference.removeValue(forKey: reference)
            return
        }
        guard var entry = pendingSendsByReference[reference], entry.phase == .pending else { return }
        let revision = entry.revision
        // Opening the window also discards whatever it recorded earlier: this drain is about to
        // observe the target and the ledger for itself, so only edges that land from here on are
        // ones it can miss.
        entry.beginDrainWindow()
        pendingSendsByReference[reference] = entry

        let authorization = await authorizeTarget(
            operation: .monitorSend,
            observerEndpoint: entry.observerEndpoint,
            targetSessionID: entry.targetSessionID
        )
        // The authorization suspended; a replacement or cancellation may have landed in that window.
        guard pendingSendsByReference[reference]?.revision == revision else { return }
        guard case let .success(target) = authorization, target.lease.reference == reference else {
            // Either the grant is gone, or a *new* generation now owns this pair. A queued message
            // belongs to the exact generation that admitted it, so it is dropped rather than migrated
            // onto authority the user granted separately.
            clearPendingSend(
                reference: reference,
                revision: revision,
                idempotencyKey: entry.idempotencyKey,
                retaining: nil
            )
            return
        }

        let outcome = await performSend(
            target: target,
            message: entry.message,
            idempotencyKey: entry.idempotencyKey,
            messageDigest: entry.requestDigest,
            workflow: .resolved(entry.workflow),
            commitFence: SendCommitFence(
                willCommit: { [weak self] in
                    self?.beginPendingSendCommit(reference: reference, revision: revision) ?? false
                },
                didCommit: { [weak self] in
                    self?.notePendingSendCommitted(reference: reference, revision: revision)
                }
            )
        )
        settlePendingSend(
            reference: reference,
            revision: revision,
            idempotencyKey: entry.idempotencyKey,
            outcome: outcome
        )
    }

    /// The cancellation cutoff.
    ///
    /// Taken synchronously on the main actor immediately before the authority commit hop, and never
    /// re-taken. Everything before it may still be invalidated by replace, cancel, or unlink; nothing
    /// after it may be. That is what makes `too_late` a truthful answer rather than a race: the entry
    /// is already past the point where refusing it would leave the transaction with nothing to do.
    ///
    /// - Returns: `false` when the entry was superseded, in which case the delivery unwinds with no
    ///   transcript mutation at all.
    private func beginPendingSendCommit(
        reference: DomainAgentSessionLinkReference,
        revision: UUID
    ) -> Bool {
        guard var entry = pendingSendsByReference[reference],
              entry.revision == revision,
              entry.phase == .draining
        else { return false }
        entry.phase = .committing
        pendingSendsByReference[reference] = entry
        return true
    }

    private func notePendingSendCommitted(
        reference: DomainAgentSessionLinkReference,
        revision: UUID
    ) {
        guard var entry = pendingSendsByReference[reference], entry.revision == revision else { return }
        entry.phase = .committed
        pendingSendsByReference[reference] = entry
    }

    /// Files one drain's outcome: park the entry for a later event, or end it and retain the single
    /// terminal result the observer can poll.
    private func settlePendingSend(
        reference: DomainAgentSessionLinkReference,
        revision: UUID,
        idempotencyKey: String,
        outcome: SendOutcome
    ) {
        // Past the cutoff the entry has to reach a terminal state. Re-parking it would resurrect a
        // delivery that already answered `too_late` to a cancel, and deliver a message the user
        // asked to stop.
        let crossedCutoff = pendingSendsByReference[reference]
            .map { $0.revision == revision && !$0.phase.isCancellable } ?? false

        func park(_ reason: AgentSessionLinkPendingSend.ParkReason, failure: AgentSessionLinkSendFailure?) {
            guard !crossedCutoff else {
                clearPendingSend(
                    reference: reference,
                    revision: revision,
                    idempotencyKey: idempotencyKey,
                    retaining: failure.map { .failed($0) }
                )
                return
            }
            guard var entry = pendingSendsByReference[reference], entry.revision == revision else { return }
            let releasedMidDrain = entry.park(reason: reason)
            pendingSendsByReference[reference] = entry
            guard releasedMidDrain else { return }
            // The only edge this park waits for already passed, inside the drain that just ended.
            // Re-driving it here is what makes the trigger lossless without a timer: the event is
            // still the sole cause, it is simply consumed one step later than it arrived.
            Task { [weak self] in await self?.drainPendingSend(reference: reference) }
        }

        func clear(_ retained: AgentSessionLinkPendingSendOutcome?) {
            clearPendingSend(
                reference: reference,
                revision: revision,
                idempotencyKey: idempotencyKey,
                retaining: retained
            )
        }

        switch outcome {
        case let .receipt(receipt):
            clear(.delivered(receipt))
        case let .blocked(failure):
            switch failure {
            case .targetNotIdle, .targetLoading:
                // The target became busy or is still hydrating. Nothing was mutated, so the entry
                // waits for the next accepted readiness publication rather than retrying on a timer.
                park(.targetReadiness, failure: failure)
            case .persistenceFailed, .persistenceIndeterminate:
                // Terminal for this entry. `persistence_failed` is retryable by the caller, but only
                // by explicitly queuing again — never by a background loop over failing storage.
                clear(.failed(failure))
            case .endpointInvalidated, .linkRevoked, .shuttingDown:
                // The link, an endpoint, or the process is gone, so there is no surviving `poll` a
                // retained result could ever be read through. This also covers the cutoff refusal:
                // the entry was already replaced or cancelled, and the guard below drops the write.
                clear(nil)
            }
        case let .rejected(rejection):
            switch rejection {
            case .sendAlreadyInProgress:
                park(.sendInProgress, failure: nil)
            case .deliveryLedgerFull:
                park(.ledgerSaturated, failure: nil)
            case .idempotencyConflict:
                clear(.rejected(.idempotencyConflict))
            case .deliveryLedgerExhausted:
                // Permanent for this generation: retained outcomes are released only by revoking a
                // link or restarting, so waiting cannot clear it and retrying only re-rejects.
                clear(.rejected(.deliveryLedgerExhausted))
            case .denied, .shuttingDown:
                clear(nil)
            }
        case .workflowUnavailable:
            // Unreachable: a queued drain hands the transaction an already-resolved workflow and
            // never performs a lookup. Fail closed rather than leave the entry pending forever on an
            // outcome this path cannot produce.
            assertionFailure("A queued oversight send resolved a workflow reference at delivery time.")
            clear(nil)
        }
    }

    private func clearPendingSend(
        reference: DomainAgentSessionLinkReference,
        revision: UUID,
        idempotencyKey: String,
        retaining outcome: AgentSessionLinkPendingSendOutcome?
    ) {
        guard pendingSendsByReference[reference]?.revision == revision else { return }
        pendingSendsByReference.removeValue(forKey: reference)
        guard let outcome else { return }
        pendingSendResultsByReference[reference] = AgentSessionLinkPendingSendResult(
            revision: revision,
            idempotencyKey: idempotencyKey,
            outcome: outcome,
            settledAt: now()
        )
    }

    private func sendOutcome(for outcome: AgentSessionLinkPendingSendOutcome) -> SendOutcome {
        switch outcome {
        case let .delivered(receipt):
            .receipt(receipt)
        case let .failed(failure):
            .blocked(failure)
        case let .rejected(rejection):
            .rejected(rejection.sendRejection)
        }
    }

    // MARK: Drain triggers

    /// Readiness trigger: an accepted publication reporting this target will now take a send.
    ///
    /// Event-driven by construction — it runs only from an accepted (deduplicated) target
    /// publication, so an unchanged target produces no drains at all and nothing polls.
    private func notePendingSendReadiness(forTargetSession sessionID: UUID) {
        let references = pendingSendsByReference
            .filter { $0.value.targetSessionID == sessionID }
            .map(\.key)
        for reference in references {
            notePendingSendTrigger(
                on: reference,
                releasing: AgentSessionLinkPendingSend.parkReasonsReleasedByTargetReadiness
            )
        }
    }

    /// Settlement trigger.
    ///
    /// Same-link settlement releases an entry parked on `send_already_in_progress`; settlement on
    /// *any* link may free an authority-wide in-flight slot, so entries parked by that saturation are
    /// retried across links. Detached rather than awaited so one settlement cannot recurse into the
    /// call stack of the send that produced it.
    private func notePendingSendLedgerSettled(on reference: DomainAgentSessionLinkReference) {
        for candidate in Array(pendingSendsByReference.keys) {
            notePendingSendTrigger(
                on: candidate,
                releasing: AgentSessionLinkPendingSend.parkReasonsReleased(
                    bySendSettlementOn: reference,
                    forEntryOn: candidate
                )
            )
        }
    }

    /// Delivers one drain trigger to one entry, losslessly.
    ///
    /// A parked entry is drained now. An entry whose drain is already in flight cannot be scheduled
    /// — and is exactly the entry that can lose the edge, because the drain reads its inputs before
    /// the event and decides how to park after it — so the trigger is recorded on it instead and
    /// consumed by that drain's own park. Past the cancellation cutoff there is nothing to deliver:
    /// the entry must reach a terminal state and can never park again.
    private func notePendingSendTrigger(
        on reference: DomainAgentSessionLinkReference,
        releasing reasons: Set<AgentSessionLinkPendingSend.ParkReason>
    ) {
        guard var entry = pendingSendsByReference[reference] else { return }
        switch entry.phase {
        case .pending:
            guard reasons.contains(entry.parkReason) else { return }
            Task { [weak self] in await self?.drainPendingSend(reference: reference) }
        case .draining:
            entry.noteMissedDrainTriggers(reasons)
            pendingSendsByReference[reference] = entry
        case .committing, .committed:
            break
        }
    }

    // MARK: Lifecycle release

    /// Drops every entry and retained outcome a set of revocations ended.
    private func releasePendingSends(after notices: [DomainAgentSessionLinkRevocationNotice]) {
        for notice in notices {
            let reference = DomainAgentSessionLinkReference(
                linkID: notice.linkID,
                generation: notice.generation
            )
            pendingSendsByReference.removeValue(forKey: reference)
            pendingSendResultsByReference.removeValue(forKey: reference)
        }
    }

    /// Reconciles the map against authoritative membership.
    ///
    /// Revocation notices reach `reconcile(after:)` on every in-process path, but the change feed
    /// that backs some of them is lossy by design, so a stranded entry has to be impossible rather
    /// than merely unlikely. Each entry is re-checked against the authority directly rather than
    /// against a membership set captured earlier in the pass: a set read before an admission would
    /// drop the entry that admission had just installed.
    private func reconcilePendingSends() async {
        // Snapshotted before the authority reads below, and only these entries are eligible to be
        // dropped. An entry admitted *during* those reads belongs to a link this pass never asked
        // about, so judging it by the membership this pass collected would delete the message a
        // caller was just told is queued.
        let audited = pendingSendsByReference
        guard !audited.isEmpty else { return }
        var active: Set<DomainAgentSessionLinkReference> = []
        var queried: Set<UUID> = []
        for entry in audited.values {
            guard queried.insert(entry.observerEndpoint.sessionID).inserted else { continue }
            for item in await authority.links(forObserver: entry.observerEndpoint.sessionID).items {
                active.insert(DomainAgentSessionLinkReference(
                    linkID: item.linkID,
                    generation: item.generation
                ))
            }
        }
        for (reference, entry) in audited where !active.contains(reference) {
            // Revision-checked as well, so a replacement installed during the reads survives even
            // though its predecessor was the entry this pass audited.
            guard pendingSendsByReference[reference]?.revision == entry.revision else { continue }
            pendingSendsByReference.removeValue(forKey: reference)
            pendingSendResultsByReference.removeValue(forKey: reference)
        }
    }

    // MARK: - Resolution preview

    /// Builds the pre-authorization preview. Resolution never focuses, activates, or switches the
    /// target window, and knowing a UUID still grants nothing.
    func resolvePreview(
        observerSessionID: UUID?,
        rawTargetSessionID: String,
        existingOutboundTargetIDs: Set<UUID>
    ) -> Result<AgentMonitorResolvedPreview, AgentSessionLinkResolveFailure> {
        guard let host else { return .failure(.notFound) }
        guard let targetSessionID = AgentSessionLinkEndpointResolver.parseSessionID(rawTargetSessionID) else {
            return .failure(.malformedIdentifier)
        }
        if let observerSessionID, targetSessionID == observerSessionID {
            return .failure(.selfMonitor)
        }
        if existingOutboundTargetIDs.contains(targetSessionID) {
            return .failure(.alreadyMonitoring)
        }
        return AgentSessionLinkEndpointResolver.resolve(
            sessionID: targetSessionID,
            candidates: host.agentSessionLinkCandidates()
        ).map { candidate in
            AgentMonitorResolvedPreview(
                sessionID: candidate.sessionID,
                displayName: candidate.resolvedDisplayName,
                providerDisplayName: candidate.providerDisplayName,
                locationLabel: candidate.locationLabel,
                status: targetPresentation(
                    for: candidate,
                    exactEndpoint: candidate.domainEndpoint
                ).status
            )
        }
    }

    // MARK: - References

    /// Reference for a reservation that has not activated yet.
    ///
    /// Built here rather than added to the domain DTOs: `DomainAgentSessionLinkModels` is an
    /// unchanged boundary, and this mapping is app-side bookkeeping.
    private static func reference(
        for reservation: DomainAgentSessionLinkPendingReservation
    ) -> DomainAgentSessionLinkReference {
        DomainAgentSessionLinkReference(linkID: reservation.linkID, generation: reservation.generation)
    }

    private static func reference(
        for grant: DomainAgentSessionLinkGrant
    ) -> DomainAgentSessionLinkReference {
        DomainAgentSessionLinkReference(linkID: grant.id, generation: grant.generation)
    }

    // MARK: - Messages

    static let unavailableMessage = "Oversight is unavailable right now."

    /// Shown when an establishment discovers its own durable token was retired underneath it.
    ///
    /// From the user's side the link they asked for did not start, and the reason is that the same
    /// pair was stopped in the meantime — so the honest phrasing is that it was stopped, not that
    /// something failed.
    static let retiredMessage = "Oversight for that session was unlinked before it could start."

    static let existingOverseerRequiredMessage =
        "That Agent session is no longer available as an overseer."

    /// Observer-side resolution message.
    ///
    /// Lifecycle reasons stay specific so the user can act on them ("still loading", "changing its
    /// binding", "closing"), while every role/eligibility reason collapses to one generic sentence so
    /// a denied observer learns nothing about why it was refused.
    private static func observerMessage(for failure: AgentSessionLinkResolveFailure) -> String {
        switch failure {
        case .loading, .rebinding, .closing, .bindingUnresolved, .ambiguous:
            failure.uiMessage
        case .childSession, .notFound, .malformedIdentifier, .selfMonitor, .alreadyMonitoring:
            AgentSessionLinkEndpointEligibility.roleDeniedReason
        }
    }

    private static func message(for rejection: DomainAgentSessionLinkReservationRejection) -> String {
        switch rejection {
        case .shuttingDown:
            "RepoPrompt is shutting down."
        case .selfMonitor:
            AgentSessionLinkResolveFailure.selfMonitor.uiMessage
        case .observerBindingUnresolved:
            AgentSessionLinkEndpointEligibility.noDurableBindingReason
        case .targetBindingUnresolved:
            AgentSessionLinkResolveFailure.bindingUnresolved.uiMessage
        case .reservationAlreadyPending:
            "That session is already being added."
        case .observerHasNoActiveOutboundLink:
            existingOverseerRequiredMessage
        }
    }

    private static func message(for rejection: DomainAgentSessionLinkActivationRejection) -> String {
        switch rejection {
        case .shuttingDown:
            "RepoPrompt is shutting down."
        case .unknownReservation:
            "Oversight could not be started. Try again."
        case .endpointDrift:
            AgentSessionLinkResolveFailure.rebinding.uiMessage
        case .snapshotSessionMismatch:
            "That session changed while it was being added. Try again."
        case .observerHasNoActiveOutboundLink:
            existingOverseerRequiredMessage
        }
    }
}

// MARK: - Launch coordinator delegate

/// The bridge is the coordinator's only route to authority and disk.
///
/// Keeping the conformance here — rather than giving the coordinator its own store and authority
/// handles — is what guarantees automatic restoration cannot bypass the shared establishment path,
/// the pair retirement barrier, or expected-token removal.
extension AgentSessionLinkRuntimeBridge: AgentSessionOversightLaunchCoordinatorDelegate {
    var launchCoordinatorHost: AgentSessionLinkEndpointHost? {
        host
    }

    var launchCoordinatorIsFrozen: Bool {
        isFrozenForTermination
    }

    func launchCoordinatorEstablish(
        pair: AgentSessionOversightIntent,
        token: AgentSessionOversightIntentToken?,
        assertedAt generation: UInt64?,
        proof: AgentSessionOversightRestorationProof?
    ) async -> EstablishmentResult {
        guard !isFrozenForTermination else {
            return EstablishmentResult(
                outcome: .rejected(message: AgentSessionOversightPersistenceCopy.shutdownBeforeInsert)
            )
        }
        // Restoration takes the same lane a manual Add does: a user Stop in flight for this pair must
        // settle before the automatic entry may reserve.
        await awaitPairRetirement(pair)
        guard !isFrozenForTermination else {
            return EstablishmentResult(
                outcome: .rejected(message: AgentSessionOversightPersistenceCopy.shutdownBeforeInsert)
            )
        }
        return await withPairEstablishmentLane(pair) { [weak self] in
            guard let self else {
                return EstablishmentResult(outcome: .rejected(message: Self.unavailableMessage))
            }
            guard !isFrozenForTermination else {
                return EstablishmentResult(
                    outcome: .rejected(message: AgentSessionOversightPersistenceCopy.shutdownBeforeInsert)
                )
            }
            return await establish(
                pair: pair,
                token: token,
                assertedAt: generation,
                proof: proof
            )
        }
    }

    func launchCoordinatorRemoveIntent(
        pair: AgentSessionOversightIntent,
        token: AgentSessionOversightIntentToken,
        assertedAt generation: UInt64?
    ) async -> AgentSessionOversightIntentMutationReceipt {
        guard let intentStore else {
            return AgentSessionOversightIntentMutationReceipt(
                outcome: .absent,
                storeRevisionBefore: 0,
                storeRevisionAfter: 0,
                transitions: [],
                wroteFile: false
            )
        }
        // The same lane a user Stop and a user Add take. Launch retirement and **Retry saving** are
        // durable removals like any other, and running them outside the lane is what would let a
        // cleanup already suspended on the store actor delete a token an explicit Add just reused.
        return await withPairRetirementLane(pair) { [intentStore, pair, token, generation] in
            await intentStore.remove(pair, ifCurrent: token, assertedAt: generation)
        }
    }

    func launchCoordinatorRevoke(reference: DomainAgentSessionLinkReference) async {
        await revoke(reference: reference)
    }

    func launchCoordinatorReportWarning(id: String, message: String) {
        reportPersistenceWarning(id: id, message: message)
    }
}

// MARK: - Passive status vocabulary

private extension AgentSessionLinkPassiveStatusNotices.Status {
    /// Maps the rendered row status onto the queue's vocabulary.
    ///
    /// Declared here rather than on the reducer so the reducer stays free of UI models, and written
    /// as an exhaustive switch so a new status has to be classified rather than silently narrated as
    /// something else.
    init(_ status: AgentMonitorLinkStatus) {
        switch status {
        case .idle: self = .idle
        case .running: self = .running
        case .awaitingUser: self = .waiting
        case .unavailable: self = .unavailable
        }
    }
}

// MARK: - Result helper

private extension Result {
    var success: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }
}
