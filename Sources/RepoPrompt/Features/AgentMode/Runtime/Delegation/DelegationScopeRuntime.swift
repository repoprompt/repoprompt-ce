import Combine
import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptPersistence

/// One `request_scope` awaiting (or past) the user's decision on its grant card.
struct DelegationScopeRequest: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case granted(scopeID: UUID)
        case denied(reason: String?)
        case cancelled(reason: String)

        var label: String {
            switch self {
            case .pending: "pending_user_approval"
            case .granted: "granted"
            case .denied: "denied"
            case .cancelled: "cancelled"
            }
        }
    }

    let id: UUID
    let requesterSessionID: UUID
    /// The tab whose Agent Mode view shows the card. The card is shown only while this tab is still
    /// bound to `requesterSessionID`; a session change cancels the request.
    let requesterTabID: UUID?
    /// Physical window presenting the explicit binding at request time; never inferred at approval.
    let requesterWindowID: Int?
    /// The requesting session's title at request time, for the card.
    var requesterTitle: String?
    /// Resolved name of a `.workspace` scope's workspace, for the card.
    var workspaceName: String?
    let kind: DomainDelegationScopeKind
    let capabilities: Set<DomainDelegationScopeCapability>
    /// Requested limits. `expiresAt` is always `nil` here; see `expiresInSeconds`.
    let guardrails: DomainDelegationScopeGuardrails
    /// Requested lifetime, counted from the user's approval rather than from the request, so a slow
    /// decision neither shortens the scope nor makes an identical retry look different.
    let expiresInSeconds: Int?
    let reason: String?
    let idempotencyKey: String?
    let createdAt: Date
    var state: State = .pending

    fileprivate func matches(
        kind: DomainDelegationScopeKind,
        capabilities: Set<DomainDelegationScopeCapability>,
        guardrails: DomainDelegationScopeGuardrails,
        expiresInSeconds: Int?,
        reason: String?
    ) -> Bool {
        self.kind == kind && self.capabilities == capabilities && self.guardrails == guardrails
            && self.expiresInSeconds == expiresInSeconds && self.reason == reason
    }
}

/// One in-flight creation counted against its scopes' guardrails until released.
struct DelegationScopeReservation: Hashable {
    let id: UUID
    let scopeIDs: [UUID]
    let sessions: Int
    let worktrees: Int
    /// Binding reservations carry identities; concurrent binds of the same worktree count once.
    var worktreeIDs: Set<String> = []
}

enum DelegationDecisionDeliveryOutcome: Equatable {
    case submitted
    case retry
    case persisted(AgentSessionLinkSendDelivery)
    case indeterminate
}

enum DelegationScopeRequestError: Error, Equatable {
    case invalid(DomainDelegationScopeDenial)
    case idempotencyConflict
    case tooManyPending
}

/// Main-actor owner of delegation-scope state for the process.
///
/// Wraps the pure `DomainDelegationScopeAuthority` (the only place scope decisions are made), the
/// durable `DelegationScopeStore`, pending `request_scope` grant cards, and the
/// `BatchConfirmationCoordinator`. Scope authority is an *input* to the four oversight owners and
/// never replaces them: nothing here touches link grants, passive notices, claims, or wake policy.
///
/// Held by `AgentSessionLinkRuntimeBridge.shared.delegationScopes`; it is not itself a singleton.
@MainActor
final class DelegationScopeRuntime: ObservableObject {
    enum PersistenceMode: Equatable {
        case requiresStore
        case ephemeral
    }

    enum Availability: Equatable {
        case awaitingStore
        case ready
        case ephemeral
        case blocked(String)
        case terminating
    }

    @Published private(set) var availability: Availability

    var canUseAuthority: Bool {
        availability != .terminating // Continuity availability is never a veto on a real live decision.
    }

    var authorityUnavailableReason: String? {
        switch availability {
        case .ready, .ephemeral, .awaitingStore, .blocked: nil
        case .terminating: "Delegation authority is closed because RepoPrompt is quitting."
        }
    }

    /// Session deletion is a live user decision, not contingent on continuity storage.
    var durableDeletionUnavailableReason: String? {
        availability == .terminating ? "RepoPrompt is quitting." : nil
    }

    var persistenceStatusMessage: String? {
        if pendingSaves.contains(where: { !$0.revoked.isEmpty || !$0.deletedSessions.isEmpty }) {
            return "Continuity is unsettled: revoked/deleted authority is denied in this process, but its transaction is not acknowledged. If the app exits before saving succeeds, the next launch can recover only the last committed state, which may still contain those grants. Keep the app open and retry saving. \(store?.diagnostic ?? "")"
        }
        if let rejected = rejectedOperations.values.sorted().first { return rejected }
        if case let .blocked(message) = availability { return store?.diagnostic ?? message }
        if persistenceFailed { return store?.diagnostic ?? "Continuity save failed. Live approvals and revocations still apply in this process; saving will retry." }
        if !pendingSaves.isEmpty || availability == .awaitingStore { return "Live decisions apply now. Continuity saving is pending; these changes are not yet durable or shared with another process." }
        return store?.diagnostic
    }

    static let maxPendingRequestsPerSession = 4
    static let maxReasonUTF8Bytes = 500
    static let minimumExpirySeconds = 60
    /// Agent-proposed lifetimes are capped at 30 days.
    static let maximumExpirySeconds = 30 * 24 * 60 * 60
    /// Bounded retention of decided requests so `scope_status` can still report them.
    static let maxRetainedRequests = 256

    @Published private(set) var requests: [UUID: DelegationScopeRequest] = [:]
    /// Requester sessions the user approved with "Grant all for this session". Later requests from
    /// these sessions are approved without another card until the user stops it, revokes one of the
    /// session's scopes, the session is deleted, or the app quits. Only the user-facing Grant all
    /// action adds to this set; no MCP argument can.
    @Published private(set) var sessionWideApprovals: Set<UUID> = []
    /// Global user setting (Settings › Agent Permissions), off by default. When on, every agent
    /// delegation request is approved as requested without a card. Deliberately not exposed through
    /// MCP `app_settings`, so an agent cannot enable it.
    static let autoApproveAllRequestsKey = OverseerGlobalAutoApprove.defaultsKey
    /// Raw setting input, injectable per runtime for tests. Only `authorization` (the engine) reads it.
    var isGlobalAutoApproveEnabled: @MainActor () -> Bool = { OverseerGlobalAutoApprove.isEnabled() }

    /// This runtime's single authorization engine: full access versus restricted delegation.
    private(set) lazy var authorization = OverseerAuthorizationEngine(scopes: self)

    /// Bumped on every authority change so presentation can refresh.
    @Published private(set) var revision: UInt64 = 0
    /// Separate continuity result. Grants save asynchronously; terminal decisions attempt a
    /// synchronous transaction before returning, without undoing the live denial on failure.
    @Published private(set) var lastPersistenceOutcome: DelegationScopeWriteOutcome?

    var persistenceFailed: Bool {
        lastPersistenceOutcome == .writeFailed || lastPersistenceOutcome == .blocked || lastPersistenceOutcome == .rejected || !rejectedOperations.isEmpty
    }

    let confirmations: BatchConfirmationCoordinator

    private var authority = DomainDelegationScopeAuthority()
    private var store: DelegationScopeStore?
    private struct DecisionDelivery {
        let tabID: UUID
        let stopFence: AgentRunStartStopFence
        var messages: [String]
        var observation: AnyCancellable?
        var isDelivering = false
        var pendingStart: (text: String, delivery: AgentSessionLinkSendDelivery)?
        var retryScheduled = false
        var startRetryAttempts = 0
    }

    private var decisions: [UUID: DecisionDelivery] = [:]
    // One grant decision per scope, not one per request settled by that same standing grant.
    // Request-specific continuation outcomes intentionally do not use this set.
    private var announcedGrantDecisions: Set<UUID> = []
    let linkConsent = DomainDelegationScopeLinkConsent()
    var liveScopesDidChange: (@MainActor () -> Void)?
    var scopesDidInvalidate: (@MainActor (Set<UUID>) -> Void)?
    private var overseeContinuations: [UUID: @MainActor (DomainDelegationScopeRecord) async -> Void] = [:]
    // Initial link/delivery receipts are task facts, not authority. Keep them with the bounded
    // request ledger so an unchanged client key can inspect a partial result without redelivery.
    private var overseeInitialRequests: Set<UUID> = []
    private var overseeInitialOutcomes: [UUID: Value] = [:]
    private var overseeInitialWaiters: [UUID: [UUID: CheckedContinuation<Value, Never>]] = [:]

    // Retain only process-local task identity, never consent. A short completed-task window
    // absorbs client retries without making a later deliberate repeat impossible.
    private var overseeContinuationTasks: [UUID: (scopeID: UUID, task: Task<Void, Never>, request: DelegationScopeRequest, digest: String, completedAt: Date?)] = [:]
    private static let completedOverseeRetryWindow: TimeInterval = 30
    #if DEBUG
        var test_scopeDecision: ((UUID, String) -> Void)?
        var test_decisionStartRetryDelay: Duration?
        var test_pendingDecisionCount: Int {
            decisions.count
        }

        var test_pendingDecisionStartCount: Int {
            decisions.values.count { $0.pendingStart != nil }
        }

        /// Unit fixtures must explicitly opt into provider delivery; ordinary scope tests do not
        /// accidentally start installed CLIs merely by approving their synthetic grant cards.
        var test_suppressDecisionDelivery = AppLaunchConfiguration.isUnitTestProcess
    #endif
    private var reservations: [UUID: DelegationScopeReservation] = [:]
    private var requestOrder: [UUID] = []
    private var requestIDByKey: [String: UUID] = [:]
    let persistenceMode: PersistenceMode
    private struct PendingSave {
        let id: UUID
        let grants: [DomainDelegationScopeGrant]
        let revoked: [UUID]
        var deletedSessions: [UUID] = []
        var deletionEndings: [UUID: OverseerScopeEnding] = [:]
        var endings: [UUID: OverseerEndedScope] = [:]
        var earlierTerminalMutations: [OverseerContinuityMutation] = []
    }

    private var pendingSaves: [PendingSave] = []
    private var rejectedOperations: [UUID: String] = [:]
    private var queuedGrantIDs: Set<UUID> = []
    private var saveTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryDelay: UInt64 = 1
    @Published private(set) var lastContinuityOperationID: UUID?
    @Published private(set) var continuityRecoveryOffers: [DelegationScopeRecoveryOffer] = []
    @Published private(set) var continuityRecoveryMessage: String?
    private var reviewedRecoverySources: Set<String> = []

    var unsettledScopeIDs: [UUID] {
        Array(Set(pendingSaves.flatMap(\.revoked))).sorted { $0.uuidString < $1.uuidString }
    }

    var continuityState: String {
        if persistenceFailed || { if case .blocked = availability { return true }
            return false
        }() { return "failed" }
        if !pendingSaves.isEmpty || availability == .awaitingStore { return "pending" }
        return persistenceMode == .ephemeral || availability == .ephemeral ? "not_persisted" : "saved"
    }

    /// Revoked/released scope IDs, newest last. Persisted as tombstones honored by `reactivate`.
    private var revokedScopeIDs: [UUID] = []
    private var scopeEndings: [UUID: OverseerEndedScope] = [:] {
        didSet { endingRecordsByGrantee = nil
            recentEndingCache = nil
        }
    }

    private var endingRecordsByGrantee: [UUID: [DomainDelegationScopeRecord]]?
    private var recentEndingCache: [EndingSummary]?

    private func buildEndingIndexIfNeeded() {
        guard endingRecordsByGrantee == nil else { return }
        var index: [UUID: [DomainDelegationScopeRecord]] = [:]
        let ordered = scopeEndings.keys.sorted {
            let a = scopeEndings[$0]?.ending.at ?? .distantPast
            let b = scopeEndings[$1]?.ending.at ?? .distantPast
            return a == b ? $0.uuidString < $1.uuidString : a > b
        }
        var summaries: [EndingSummary] = []
        for id in ordered {
            let record = endedRecord(id: id)
            if let record, index[record.grant.granteeSessionID, default: []].count < 16 {
                index[record.grant.granteeSessionID, default: []].append(record)
            }
            if summaries.count < 16, let ending = scopeEndings[id]?.ending {
                summaries.append(.init(id: id, ending: ending, granteeSessionID: record?.grant.granteeSessionID))
            }
        }
        endingRecordsByGrantee = index
        recentEndingCache = summaries
    }

    struct EndingSummary: Identifiable {
        let id: UUID
        let ending: OverseerScopeEnding
        let granteeSessionID: UUID?
    }

    /// Bounded monitor projection; terminal identities remain in continuity storage.
    var recentScopeEndings: [EndingSummary] {
        buildEndingIndexIfNeeded()
        return recentEndingCache ?? []
    }

    func endingGrantee(for scopeID: UUID) -> UUID? {
        endedRecord(id: scopeID)?.grant.granteeSessionID
    }

    func ending(for scopeID: UUID) -> OverseerScopeEnding? {
        scopeEndings[scopeID]?.ending
    }

    private func endedRecord(id: UUID) -> DomainDelegationScopeRecord? {
        guard let ended = scopeEndings[id],
              let grant = try? JSONDecoder().decode(DomainDelegationScopeGrant.self, from: ended.originalPayload), grant.id == id else { return nil }
        return .init(grant: grant, generation: 0, state: ended.ending.reason == .expired ? .expired : .revoked)
    }

    private func captureEndings(_ records: [DomainDelegationScopeRecord], reason: OverseerScopeEnding.Reason, origin: UUID? = nil, session: UUID? = nil, actor: UUID? = nil, at date: Date? = nil, evidence: OverseerScopeEnding? = nil) {
        let endingDate = date ?? now()
        for record in records where scopeEndings[record.id] == nil {
            guard let payload = try? JSONEncoder().encode(record.grant) else { continue }
            scopeEndings[record.id] = .init(ending: evidence ?? .init(reason: reason, at: endingDate, actorSessionID: actor, originatingScopeID: origin, originatingSessionID: session), originalPayload: payload)
        }
    }

    private var deletedSessionIDs: Set<UUID> = []
    private let windows: @MainActor () -> [WindowState]
    private let now: () -> Date
    private let makeUUID: () -> UUID
    private let notifyCatalogChanged: (UUID) -> Void

    init(
        persistenceMode: PersistenceMode,
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init,
        confirmations: BatchConfirmationCoordinator? = nil,
        windows: @escaping @MainActor () -> [WindowState] = { WindowStatesManager.shared.allWindows },
        notifyCatalogChanged: @escaping (UUID) -> Void = { sessionID in
            // Forced: a scope change alters `session_admin` eligibility without changing any link
            // fact, so the link-only change detection would otherwise skip the relist.
            Task { await ServerNetworkManager.shared.notifyToolListChangedForAgentSession(sessionID, forceRelist: true) }
        }
    ) {
        self.persistenceMode = persistenceMode
        availability = persistenceMode == .ephemeral ? .ephemeral : .awaitingStore
        self.windows = windows
        self.now = now
        self.makeUUID = makeUUID
        self.confirmations = confirmations ?? BatchConfirmationCoordinator(now: now, makeUUID: makeUUID)
        self.notifyCatalogChanged = notifyCatalogChanged
    }

    // MARK: - Launch

    /// Restore validated continuity, independently of current user-backed live decisions.
    func bootstrap(store: DelegationScopeStore) async {
        guard persistenceMode == .requiresStore, self.store == nil, availability != .terminating else { return }
        self.store = store
        await recoverContinuity()
    }

    /// Recovery can install compatible saved continuity, but never replaces a newer live decision.
    private func recoverContinuity() async {
        guard let store, availability != .terminating else { return }
        let loaded = await Task.detached { store.loadForLaunch() }.value
        let recoveryNow = now()
        let offers = await Task.detached { store.recoveryOffers(now: recoveryNow) }.value
        continuityRecoveryOffers = offers.filter { !reviewedRecoverySources.contains($0.id) }
        guard availability != .terminating else { return }
        switch loaded {
        case let .ready(_, grants, revoked):
            // Recovery offers were read across an await; classify and install against one current
            // snapshot so a grant expiring during that read cannot disappear without evidence.
            let restorationDate = now()
            scopeEndings.merge(store.endedScopes) { live, _ in live }
            revokedScopeIDs = Array(Set(revokedScopeIDs).union(revoked))
            queuedGrantIDs.formUnion(grants.map(\.id))
            let savedByID = Dictionary(uniqueKeysWithValues: grants.map { ($0.id, $0) })
            var expiredOnLaunch: [UUID] = []
            for grant in grants {
                var cursor: DomainDelegationScopeGrant? = grant
                var seen: Set<UUID> = []
                var chain: [DomainDelegationScopeGrant] = []
                while let candidate = cursor, seen.insert(candidate.id).inserted {
                    chain.append(candidate)
                    cursor = candidate.parentScopeID.flatMap { savedByID[$0] }
                }
                if let origin = Self.expiryOrigin(chain, at: restorationDate) {
                    captureEndings([.init(grant: grant, generation: 0, state: .expired)], reason: .expired, origin: origin, at: restorationDate)
                    expiredOnLaunch.append(grant.id)
                }
            }
            let compatible = grants.filter { grant in
                guard scopeEndings[grant.id] == nil else { return false }
                guard !deletedSessionIDs.contains(grant.granteeSessionID) else { return false }
                if case let .session(target) = grant.kind { return !deletedSessionIDs.contains(target) }
                if case let .tree(root) = grant.kind { return !deletedSessionIDs.contains(root) }
                return true
            }
            let installed = authority.reactivate(compatible, revokedScopeIDs: Set(revokedScopeIDs), now: restorationDate)
            availability = .ready
            if pendingSaves.isEmpty { lastPersistenceOutcome = .unchanged }
            didChange(grantees: Set(installed.map(\.grant.granteeSessionID)), invalidated: expiredOnLaunch)
        case let .blocked(reason):
            availability = .blocked(reason.message)
            lastPersistenceOutcome = .blocked
            scheduleContinuityRetry()
        case .suppressed:
            // Explicit launch policy, never a fallback from failed production I/O.
            availability = .ephemeral
        }
        startSaving()
    }

    /// Wait for the current save attempt, not an unbounded retry loop. Failure stays visible.
    func flushPersistence() async {
        startSaving()
        await saveTask?.value
    }

    func retryContinuityNow() async {
        retryTask?.cancel()
        retryTask = nil
        if availability != .ready, availability != .ephemeral { await recoverContinuity() }
        startSaving()
        await saveTask?.value
    }

    /// UI-only explicit approval of displayed mixed-source root grant descriptions. This does
    /// not activate arbitrary legacy IDs, revive revocations, or convert attenuated grants to roots.
    /// No MCP operation or target-supplied message can invoke this user-decision path.
    func approveContinuityRecovery(sourceID: String) {
        guard canUseAuthority, let offer = continuityRecoveryOffers.first(where: { $0.id == sourceID }),
              reviewedRecoverySources.insert(sourceID).inserted else { return }
        continuityRecoveryOffers.removeAll { $0.id == sourceID }
        var count = 0
        for original in offer.grants {
            guard !deletedSessionIDs.contains(original.granteeSessionID) else { continue }
            if case let .session(target) = original.kind, deletedSessionIDs.contains(target) { continue }
            if case let .tree(root) = original.kind, deletedSessionIDs.contains(root) { continue }
            do {
                let request = try requestScope(
                    requesterSessionID: original.granteeSessionID,
                    requesterTabID: nil,
                    kind: original.kind,
                    capabilities: original.capabilities,
                    guardrails: original.guardrails,
                    reason: "User explicitly approved a new grant from a preserved continuity description.",
                    idempotencyKey: nil
                ).get()
                _ = try approve(requestID: request.id, guardrails: original.guardrails).get()
                count += 1
            } catch {
                continuityRecoveryMessage = "Recovery description was preserved but could not be approved: \(error). Request a new explicit scope with valid capabilities/limits."
                return
            }
        }
        continuityRecoveryMessage = "Approved \(count) new live grants. Original source and other rows remain preserved; continuity saving is \(continuityState)."
    }

    /// Closes live authority for quit. No shutdown seal controls restoration; pending saves remain
    /// separately observable. `allowRestoration` is retained only for call-site compatibility.
    func freezeForTermination(allowRestoration _: Bool = true) {
        guard availability != .terminating else { return }
        let active = authority.activeGrants
        retryTask?.cancel()
        retryTask = nil
        availability = .terminating
        linkConsent.replace([])
        overseeContinuations.removeAll()
        overseeInitialRequests.removeAll()
        for running in overseeContinuationTasks.values {
            running.task.cancel()
        }
        overseeContinuationTasks.removeAll()
        let waiters = overseeInitialWaiters
        overseeInitialWaiters.removeAll()
        for (id, pending) in waiters {
            for waiter in pending.values {
                waiter.resume(returning: overseeWaitInterrupted(requestID: id))
            }
        }
        revision &+= 1
        for grant in active {
            confirmations.invalidate(scopeID: grant.id)
        }
    }

    /// A snapshot of settlement, not a finalization seal. Late deletion callbacks still enqueue
    /// transactions. A blocked writer is never structurally joined past this absolute deadline.
    func settleForTermination(timeout: TimeInterval = 2) async -> Bool {
        if availability != .terminating { freezeForTermination() }
        guard let attempt = saveTask else { return pendingSaves.isEmpty && !persistenceFailed }
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, timeout)))
        var timer: Task<Void, Never>?
        let settled = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = TerminationSettlementGate(continuation)
            timer = Task { @MainActor in
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                gate.finish(false)
            }
            Task { @MainActor [weak self] in
                await attempt.value
                gate.finish(self?.pendingSaves.isEmpty == true && self?.persistenceFailed == false)
            }
        }
        timer?.cancel()
        return settled
    }

    private final class TerminationSettlementGate {
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func finish(_ settled: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: settled)
        }
    }

    // MARK: - Queries

    /// Catalog discovery is read-only, including memory-only tool admission. Time-based
    /// eligibility fails closed without expiring other grants or scheduling persistence.
    func hasLiveScopeForCatalog(grantedTo sessionID: UUID) -> Bool {
        guard canUseAuthority else { return false }
        return authority.hasLiveScope(grantedTo: sessionID, now: now())
    }

    func hasLiveScope(grantedTo sessionID: UUID) -> Bool {
        guard canUseAuthority else { return false }
        expireDueScopes()
        return authority.hasLiveScope(grantedTo: sessionID, now: now())
    }

    func liveScopes(grantedTo sessionID: UUID) -> [DomainDelegationScopeRecord] {
        guard canUseAuthority else { return [] }
        expireDueScopes()
        return authority.liveScopes(grantedTo: sessionID, now: now())
    }

    func scopes(grantedTo sessionID: UUID) -> [DomainDelegationScopeRecord] {
        guard canUseAuthority else { return [] }
        expireDueScopes()
        let live = authority.scopes(grantedTo: sessionID)
        let known = Set(live.map(\.id))
        buildEndingIndexIfNeeded()
        let ended = (endingRecordsByGrantee?[sessionID] ?? []).filter { !known.contains($0.id) }
        let active = live.filter(\.isActive)
        let history = (live.filter { !$0.isActive } + ended).sorted {
            let a = scopeEndings[$0.id]?.ending.at ?? .distantPast
            let b = scopeEndings[$1.id]?.ending.at ?? .distantPast
            return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
        }
        return active + history.prefix(16)
    }

    /// History is presentation-only and must never enter authorization lookup.
    func statusRecord(id: UUID) -> DomainDelegationScopeRecord? {
        record(id: id) ?? endedRecord(id: id)
    }

    func record(id: UUID) -> DomainDelegationScopeRecord? {
        guard canUseAuthority else { return nil }
        expireDueScopes()
        return authority.record(id: id)
    }

    func scopeChain(from scopeID: UUID) -> [DomainDelegationScopeRecord] {
        guard canUseAuthority else { return [] }
        expireDueScopes()
        return authority.scopeChain(from: scopeID)
    }

    /// Every live scope, for the user's "Active delegations" list. A pure query (safe from a view
    /// body): expired-by-time scopes are filtered out without mutating state.
    func allLiveScopes() -> [DomainDelegationScopeRecord] {
        guard canUseAuthority else { return [] }
        return authority.activeGrants
            .compactMap { authority.liveRecord(id: $0.id, now: now()) }
            .sorted { $0.grant.grantedAt < $1.grant.grantedAt }
    }

    // MARK: - In-flight reservations

    /// Sessions and worktrees being created under a scope but not yet visible to the projector.
    ///
    /// Taken synchronously right after a guardrail check (no suspension in between) and released when
    /// creation finishes or fails, so two concurrent creations can never both pass a limit of one.
    func reserve(scopeIDs: [UUID], sessions: Int = 0, worktrees: Int = 0, worktreeIDs: Set<String> = []) -> DelegationScopeReservation {
        let reservation = DelegationScopeReservation(
            id: makeUUID(), scopeIDs: Array(Set(scopeIDs)), sessions: sessions, worktrees: worktrees, worktreeIDs: worktreeIDs
        )
        if canUseAuthority { reservations[reservation.id] = reservation }
        return reservation
    }

    func release(_ reservation: DelegationScopeReservation?) {
        guard let reservation else { return }
        reservations.removeValue(forKey: reservation.id)
    }

    /// Projected usage plus in-flight reservations on the same scope.
    func usageIncludingReservations(_ usage: DomainDelegationScopeUsage) -> DomainDelegationScopeUsage {
        let held = reservations.values.filter { $0.scopeIDs.contains(usage.scopeID) }
        let pendingIDs = held.reduce(into: Set<String>()) { $0.formUnion($1.worktreeIDs) }
        return DomainDelegationScopeUsage(
            scopeID: usage.scopeID,
            liveSessionCount: usage.liveSessionCount + held.reduce(0) { $0 + $1.sessions },
            worktreeCount: usage.worktreeCount + held.reduce(0) { $0 + $1.worktrees }
                + pendingIDs.subtracting(usage.countedWorktreeIDs).count,
            spawnParentDepth: usage.spawnParentDepth,
            countedWorktreeIDs: usage.countedWorktreeIDs.union(pendingIDs)
        )
    }

    /// Creation guardrails for a scope and every ancestor — `maxLiveSessions`/`maxDepth` for a session
    /// (`adminSpawn`, `adminFork`), `maxWorktrees` for a worktree (`adminWorktreeCreate`) — for scopes
    /// the new session or worktree counts toward beyond the caller's own. `usageByScopeID` must cover
    /// the chain.
    func evaluateCreationGuardrails(
        scopeID: UUID,
        operation: DomainAgentSessionTargetOperation,
        usageByScopeID: [UUID: DomainDelegationScopeUsage]
    ) -> DomainDelegationScopeDenial? {
        guard canUseAuthority else { return .unknownScope }
        expireDueScopes()
        return authority.evaluateGuardrails(scopeID: scopeID, operation: operation, usageByScopeID: usageByScopeID)
    }

    /// Grantees and tree roots of every live scope. Placement never moves one of them into another
    /// scope (`adopt`, or an `agent_run` start into an unplaced tab).
    func liveScopeAnchors() -> Set<UUID> {
        var anchors: Set<UUID> = []
        for record in allLiveScopes() {
            anchors.insert(record.grant.granteeSessionID)
            if case let .session(target) = record.grant.kind { anchors.insert(target) }
            if case let .tree(root) = record.grant.kind { anchors.insert(root) }
        }
        return anchors
    }

    /// Roots of every live `.tree` scope, for placement decisions (`reparent`, `adopt`).
    func liveTreeScopeRoots() -> [DomainDelegationTreeScopeRoot] {
        guard canUseAuthority else { return [] }
        expireDueScopes()
        return authority.liveRecords(now: now()).compactMap { record in
            guard case let .tree(rootSessionID) = record.grant.kind else { return nil }
            return DomainDelegationTreeScopeRoot(scopeID: record.id, rootSessionID: rootSessionID)
        }
    }

    /// The request, but only for the session that made it.
    func request(id: UUID, requesterSessionID: UUID) -> DelegationScopeRequest? {
        guard let request = requests[id], request.requesterSessionID == requesterSessionID else { return nil }
        return request
    }

    /// Pending cards for one tab, shown only while the tab is still bound to the requesting session.
    func pendingRequests(forTab tabID: UUID, sessionID: UUID?) -> [DelegationScopeRequest] {
        guard let sessionID else { return [] }
        return requestOrder.compactMap { requests[$0] }.filter {
            $0.requesterTabID == tabID && $0.requesterSessionID == sessionID && $0.state == .pending
        }
    }

    /// Cancels pending requests raised in `tabID` by a session that is no longer the tab's session, so
    /// a card can never be approved on behalf of the wrong session.
    func cancelStaleRequests(tabID: UUID, currentSessionID: UUID?) {
        for id in requestOrder {
            guard var request = requests[id], request.state == .pending, request.requesterTabID == tabID,
                  request.requesterSessionID != currentSessionID
            else { continue }
            request.state = .cancelled(reason: "The tab's session changed before approval.")
            overseeContinuations.removeValue(forKey: id)
            overseeInitialRequests.remove(id)
            requests[id] = request
        }
    }

    // MARK: - Single authority check

    /// Decision steps 1–5 against current state. The only scope authorization entry point.
    func authorize(_ request: DomainDelegationScopeAuthorizationRequest) -> DomainDelegationScopeAuthorizationOutcome {
        guard canUseAuthority else { return .denied(.unknownScope, sessionID: nil) }
        expireDueScopes()
        return authority.authorize(request, now: now())
    }

    /// Whether a lease issued earlier still authorizes. Handlers must re-check after every
    /// suspension point before mutating, exactly like link leases: a revocation, release, or expiry
    /// that lands mid-operation stops authority immediately.
    func isCurrent(_ lease: DomainDelegationScopeLease) -> Bool {
        guard canUseAuthority else { return false }
        expireDueScopes()
        return authority.isCurrent(lease, now: now())
    }

    // MARK: - request_scope

    /// Records a pending grant request. Nothing is granted until the user approves the card.
    func requestScope(
        requesterSessionID: UUID,
        requesterTabID: UUID?,
        kind: DomainDelegationScopeKind,
        capabilities: Set<DomainDelegationScopeCapability>,
        guardrails requestedGuardrails: DomainDelegationScopeGuardrails,
        expiresInSeconds: Int? = nil,
        reason: String?,
        idempotencyKey: String?,
        requesterTitle: String? = nil,
        workspaceName: String? = nil,
        reusePendingOnly: Bool = false
    ) -> Result<DelegationScopeRequest, DelegationScopeRequestError> {
        guard availability != .terminating else { return .failure(.invalid(.unknownScope)) }
        var guardrails = requestedGuardrails
        guardrails.expiresAt = nil
        // An agent may only propose guardrails at least as strict as the defaults; loosening the bulk
        // card threshold is the user's call alone.
        guardrails.bulkConfirmationThreshold = min(
            guardrails.bulkConfirmationThreshold,
            DomainDelegationScopeGuardrails.defaultBulkConfirmationThreshold
        )
        if let expiresInSeconds,
           expiresInSeconds < Self.minimumExpirySeconds || expiresInSeconds > Self.maximumExpirySeconds
        {
            return .failure(.invalid(.expiryInPast))
        }
        if let denial = DomainDelegationScopeAuthority.validate(
            kind: kind,
            capabilities: capabilities,
            guardrails: guardrails,
            now: now(),
            // Global auto-approve answers any request with an unrestricted grant, so no capability is
            // refused for its kind before that.
            unrestricted: authorization.validatesScopeRequestsWithoutCeiling
        ) {
            return .failure(.invalid(denial))
        }
        if reusePendingOnly, let existing = existingOverseeContinuation(requester: requesterSessionID, kind: kind, reason: reason),
           let running = overseeContinuationTasks[existing]
        {
            return .success(running.request)
        }
        let key = idempotencyKey.map { "\(requesterSessionID.uuidString)|\($0)" }
        if let key, let existingID = requestIDByKey[key], let existing = requests[existingID],
           !reusePendingOnly || existing.state == .pending || overseeInitialOutcomes[existingID] != nil || overseeInitialRequests.contains(existingID)
        {
            return existing.matches(
                kind: kind,
                capabilities: capabilities,
                guardrails: guardrails,
                expiresInSeconds: expiresInSeconds,
                reason: reason
            )
                ? .success(existing)
                : .failure(.idempotencyConflict)
        }
        let pendingCount = requests.values.count(where: {
            $0.requesterSessionID == requesterSessionID && $0.state == .pending
        })
        guard pendingCount < Self.maxPendingRequestsPerSession else { return .failure(.tooManyPending) }
        let request = DelegationScopeRequest(
            id: makeUUID(),
            requesterSessionID: requesterSessionID,
            requesterTabID: requesterTabID,
            requesterWindowID: requesterTabID.flatMap { explicitPresentationWindow(tabID: $0, sessionID: requesterSessionID)?.windowID },
            requesterTitle: requesterTitle,
            workspaceName: workspaceName,
            kind: kind,
            capabilities: capabilities,
            guardrails: guardrails,
            expiresInSeconds: expiresInSeconds,
            reason: reason,
            idempotencyKey: idempotencyKey,
            createdAt: now()
        )
        requests[request.id] = request
        requestOrder.append(request.id)
        if let key { requestIDByKey[key] = request.id }
        trimRequestRetention()
        return .success(request)
    }

    func beginOverseeInitialOutcome(requestID: UUID) {
        guard requests[requestID]?.state == .pending else { return }
        overseeInitialRequests.insert(requestID)
    }

    func overseeInitialOutcome(requestID: UUID) -> Value? {
        overseeInitialOutcomes[requestID]
    }

    func completeOverseeInitialOutcome(requestID: UUID, value: Value) {
        guard overseeInitialOutcomes[requestID] == nil else { return }
        overseeInitialOutcomes[requestID] = value
        overseeInitialRequests.remove(requestID)
        let waiters = overseeInitialWaiters.removeValue(forKey: requestID) ?? [:]
        for waiter in waiters.values {
            waiter.resume(returning: value)
        }
    }

    /// Waiting on the first committed outcome never joins the ongoing target-status watch.
    /// Cancelling this tool's wait does not cancel the app-owned approved assignment.
    func waitForOverseeInitialOutcome(requestID: UUID) async -> Value {
        if let value = overseeInitialOutcomes[requestID] { return value }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let value = overseeInitialOutcomes[requestID] { continuation.resume(returning: value) }
                else if Task.isCancelled { continuation.resume(returning: overseeWaitInterrupted(requestID: requestID)) }
                else { overseeInitialWaiters[requestID, default: [:]][waiterID] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let waiter = overseeInitialWaiters[requestID]?.removeValue(forKey: waiterID) else { return }
                waiter.resume(returning: overseeWaitInterrupted(requestID: requestID))
            }
        }
    }

    private func overseeWaitInterrupted(requestID: UUID) -> Value {
        .object([
            "result": .string("partial"), "code": .string("continuation_pending"),
            "subreason": .string("caller_wait_interrupted"), "request_id": .string(requestID.uuidString),
            "detail": .string("The approved assignment may still be running. Retry the identical request to inspect its receipt; do not send a duplicate task."),
            "next_call": .string("Retry the identical become_overseer request with the same idempotency_key."),
            "retryable": .bool(true)
        ])
    }

    /// Registers the already-requested exact-target task, not approval. Only the user's real
    /// approval transition below may start it. Repeating a tool call cannot replace its payload.
    func installOverseeContinuation(
        requestID: UUID, continuation: @escaping @MainActor (DomainDelegationScopeRecord) async -> Void
    ) -> Bool {
        guard requests[requestID]?.state == .pending, overseeContinuations[requestID] == nil else { return false }
        overseeContinuations[requestID] = continuation
        return true
    }

    /// Reuse only this owner's live, exact-target user decision. A tool argument or saved link alone
    /// cannot mark a new request approved. This also avoids another card after a normal restart.
    func continueOverseeWithExistingConsent(requestID: UUID) -> Bool {
        guard var request = requests[requestID] ?? overseeContinuationTasks[requestID]?.request else { return false }
        if let existing = existingOverseeContinuation(requester: request.requesterSessionID, kind: request.kind, reason: request.reason) {
            return existing == requestID // Point at that task; never start another continuation.
        }
        guard request.state == .pending,
              case let .session(target) = request.kind,
              let record = liveScopes(grantedTo: request.requesterSessionID).first(where: {
                  $0.grant.kind == request.kind && $0.grant.capabilities.isSuperset(of: request.capabilities)
              }), linkConsent.permits(scopeID: record.id, observer: request.requesterSessionID, target: target, at: now()),
              let continuation = overseeContinuations.removeValue(forKey: requestID) else { return false }
        request.state = .granted(scopeID: record.id)
        requests[requestID] = request
        startOverseeContinuation(request: request, record: record, continuation: continuation)
        return true
    }

    private func existingOverseeContinuation(requester: UUID, kind: DomainDelegationScopeKind, reason: String?) -> UUID? {
        let date = now()
        overseeContinuationTasks = overseeContinuationTasks.filter {
            $0.value.completedAt.map { date.timeIntervalSince($0) < Self.completedOverseeRetryWindow } ?? true
        }
        guard case let .session(target) = kind else { return nil }
        let digest = AgentSessionLinkMessageDigest.steerDigest(message: reason ?? "")
        return overseeContinuationTasks.first {
            $0.value.request.requesterSessionID == requester && $0.value.request.kind == kind && $0.value.digest == digest
                && linkConsent.permits(scopeID: $0.value.scopeID, observer: requester, target: target, at: date)
        }?.key
    }

    private func startOverseeContinuation(
        request: DelegationScopeRequest, record: DomainDelegationScopeRecord,
        continuation: @escaping @MainActor (DomainDelegationScopeRecord) async -> Void
    ) {
        #if DEBUG
            test_activeOverseeContinuationCount += 1
        #endif
        let task = Task { @MainActor [weak self] in
            #if DEBUG
                defer { self?.test_activeOverseeContinuationCount -= 1 }
            #endif
            await continuation(record)
            guard let self else { return }
            overseeContinuationTasks[request.id]?.completedAt = now()
        }
        overseeContinuationTasks[request.id] = (
            record.id, task, request, AgentSessionLinkMessageDigest.steerDigest(message: request.reason ?? ""), nil
        )
    }

    #if DEBUG
        private(set) var test_activeOverseeContinuationCount = 0
    #endif

    func notifyOverseeContinuation(
        sessionID: UUID, tabID: UUID, requestID: UUID, result: String, continuing: Bool = false,
        deliveredNothing: Bool = false
    ) {
        // A task that delivered nothing (refused or failed before any effect) must not absorb a
        // corrected retry as though it were a recently completed assignment. Decided from the
        // typed outcome, never by parsing notice text.
        if deliveredNothing {
            overseeContinuationTasks.removeValue(forKey: requestID)
        }
        enqueueDecision(sessionID: sessionID, tabID: tabID, result: result, identifier: requestID, automaticContinuation: continuing)
    }

    /// Approves a just-recorded pending request from the user's standing consent: "Grant all for
    /// this session" for its requester, or the global auto-approve setting. Goes through the same
    /// `approve` path as the card, so the grant, requester notice and oversee continuation are
    /// identical. Returns false (card shown as usual) when no standing consent applies.
    @discardableResult
    func approveWithStandingConsent(requestID: UUID) -> Bool {
        guard let request = requests[requestID], request.state == .pending else { return false }
        // Global is global: answer any request with the one unrestricted grant, however narrow.
        if let global = ensureGlobalAutoApproveScope(for: request.requesterSessionID) {
            settleGranted(requestID: requestID, record: global)
            return true
        }
        guard sessionWideApprovals.contains(request.requesterSessionID) else { return false }
        if case .success = approve(requestID: requestID, grantAllForSession: true) { return true }
        return false
    }

    /// The user's global auto-approve (Overseer yolo) grant for `grantee`: `.allSessions`, every
    /// capability, unrestricted (no all-sessions capability limit, no confirmation cards), no expiry.
    /// Minted once and reused; nil when the setting is off or authority is unavailable. It is an
    /// ordinary recorded grant, so it shows in Active delegations and can be revoked.
    @discardableResult
    func ensureGlobalAutoApproveScope(for grantee: UUID) -> DomainDelegationScopeRecord? {
        guard canUseAuthority, authorization.issuesFullAccessGrant, !deletedSessionIDs.contains(grantee) else { return nil }
        expireDueScopes()
        if let existing = liveScopes(grantedTo: grantee).first(where: \.grant.unrestricted) { return existing }
        let request = DomainDelegationScopeGrantRequest(
            granteeSessionID: grantee,
            kind: .allSessions,
            capabilities: DomainDelegationScopeCapability.fullPreset,
            guardrails: .init(),
            unrestricted: true
        )
        guard case let .success(record) = authority.grant(request, scopeID: makeUUID(), now: now()) else { return nil }
        didChange(grantees: [grantee], invalidated: [])
        return record
    }

    /// Off means off: revoke every global grant once the setting is turned off. Called when the
    /// setting changes and before each scoped administration decision.
    func reconcileGlobalAutoApprove(userInitiated: Bool = false) {
        guard canUseAuthority, !authorization.issuesFullAccessGrant else { return }
        let global = authority.liveRecords(now: now()).filter(\.grant.unrestricted)
        guard !global.isEmpty else { return }
        var changed: [DomainDelegationScopeRecord] = []
        for record in global {
            let revoked = authority.revoke(scopeID: record.id)
            captureEndings(revoked, reason: userInitiated ? .fullAccessDisabled : .fullAccessReconciled, origin: record.id)
            changed.append(contentsOf: revoked)
        }
        recordRevocations(changed)
    }

    /// Marks a pending request granted by an existing grant and runs the same notice and oversee
    /// continuation as a card approval.
    private func settleGranted(requestID: UUID, record: DomainDelegationScopeRecord) {
        guard var request = requests[requestID], request.state == .pending else { return }
        request.state = .granted(scopeID: record.id)
        requests[requestID] = request
        let continuation = overseeContinuations.removeValue(forKey: requestID)
        if let continuation {
            startOverseeContinuation(request: request, record: record, continuation: continuation)
        }
        enqueueDecision(
            sessionID: request.requesterSessionID,
            tabID: request.requesterTabID,
            result: "granted",
            identifier: record.id,
            automaticContinuation: continuation != nil
        )
    }

    /// User action from Active delegations: stop approving this session's requests automatically.
    /// Existing grants stay until revoked individually.
    func endSessionWideApproval(sessionID: UUID) {
        sessionWideApprovals.remove(sessionID)
    }

    /// Re-read the app-owned binding at the synchronous grant boundary. A stale rendered card,
    /// a rebound tab, or a duplicate tab in another physical window can never approve a grant.
    @discardableResult
    func approve(
        requestID: UUID,
        presentedWindowID: Int,
        presentedTabID: UUID,
        presentedSessionID: UUID,
        capabilities: Set<DomainDelegationScopeCapability>? = nil,
        guardrails: DomainDelegationScopeGuardrails? = nil,
        grantAllForSession: Bool = false
    ) -> Result<DomainDelegationScopeRecord, DomainDelegationScopeDenial> {
        guard let request = requests[requestID], request.state == .pending,
              request.requesterTabID == presentedTabID,
              request.requesterSessionID == presentedSessionID,
              request.requesterWindowID == presentedWindowID,
              explicitPresentationWindow(tabID: presentedTabID, sessionID: presentedSessionID)?.windowID == presentedWindowID
        else { return .failure(.unknownScope) }
        return approve(requestID: requestID, capabilities: capabilities, guardrails: guardrails, grantAllForSession: grantAllForSession)
    }

    /// The physical, loaded presentation shared by scope and batch approval. Catalog copies in
    /// inactive workspaces are knowledge, not presenters. Actual loaded duplicates fail closed.
    static func loadedPresentation(forTab tabID: UUID, in windows: [WindowState]) -> (window: WindowState, sessionID: UUID)? {
        let bound = windows.compactMap { window -> (window: WindowState, sessionID: UUID)? in
            guard let sessionID = window.agentModeViewModel.sessions[tabID]?.activeAgentSessionID else { return nil }
            return (window, sessionID)
        }
        return bound.count == 1 ? bound[0] : nil
    }

    private func explicitPresentationWindow(tabID: UUID, sessionID: UUID) -> WindowState? {
        guard let presentation = Self.loadedPresentation(forTab: tabID, in: windows()),
              presentation.sessionID == sessionID
        else { return nil }
        return presentation.window
    }

    /// The user approved the grant card, optionally narrowing capabilities or adjusting guardrails.
    ///
    /// Approved capabilities must be a subset of the requested ones (refused otherwise, request left
    /// pending). The requested lifetime starts now and is kept unless the user sets a stricter expiry.
    /// If the approved values fail validation the request is closed as denied rather than left
    /// pending, so the card can never get stuck.
    @discardableResult
    func approve(
        requestID: UUID,
        capabilities: Set<DomainDelegationScopeCapability>? = nil,
        guardrails: DomainDelegationScopeGuardrails? = nil,
        grantAllForSession: Bool = false
    ) -> Result<DomainDelegationScopeRecord, DomainDelegationScopeDenial> {
        guard canUseAuthority else { return .failure(.unknownScope) }
        guard var request = requests[requestID], request.state == .pending else { return .failure(.unknownScope) }
        // Only the explicit user-facing Grant all action sets this flag. No MCP argument can.
        let allCapabilities: Set<DomainDelegationScopeCapability> = request.kind == .allSessions
            ? DomainDelegationScopeCapability.allSessionsPermitted : DomainDelegationScopeCapability.fullPreset
        let approvedCapabilities = grantAllForSession ? allCapabilities : capabilities ?? request.capabilities
        guard grantAllForSession || approvedCapabilities.isSubset(of: request.capabilities) else {
            return .failure(.approvalExceedsRequest)
        }
        let approvedAt = now()
        var approvedGuardrails = guardrails ?? request.guardrails
        let requestedExpiry = request.expiresInSeconds.map { approvedAt.addingTimeInterval(TimeInterval($0)) }
        approvedGuardrails.expiresAt = switch (requestedExpiry, guardrails?.expiresAt) {
        case let (requested?, chosen?): min(requested, chosen)
        case let (requested?, nil): requested
        case let (nil, chosen): chosen
        }
        if grantAllForSession { approvedGuardrails.expiresAt = nil }
        let grantRequest = DomainDelegationScopeGrantRequest(
            granteeSessionID: request.requesterSessionID,
            kind: request.kind,
            capabilities: approvedCapabilities,
            guardrails: approvedGuardrails
        )
        let result = authority.grant(grantRequest, scopeID: makeUUID(), now: approvedAt)
        switch result {
        case let .success(record):
            request.state = .granted(scopeID: record.id)
            requests[requestID] = request
            if grantAllForSession { sessionWideApprovals.insert(request.requesterSessionID) }
            didChange(grantees: [record.grant.granteeSessionID], invalidated: [])
            let continuation = overseeContinuations.removeValue(forKey: requestID)
            if let continuation {
                startOverseeContinuation(request: request, record: record, continuation: continuation)
            }
            enqueueDecision(
                sessionID: request.requesterSessionID,
                tabID: request.requesterTabID,
                result: "granted",
                identifier: record.id,
                automaticContinuation: continuation != nil
            )
        case let .failure(denial):
            overseeContinuations.removeValue(forKey: requestID)
            overseeInitialRequests.remove(requestID)
            request.state = .denied(reason: "Approval failed validation (\(denial.diagnosticLabel)).")
            requests[requestID] = request
            enqueueDecision(
                sessionID: request.requesterSessionID,
                tabID: request.requesterTabID,
                result: "denied",
                identifier: request.id
            )
        }
        return result
    }

    func deny(requestID: UUID, reason: String? = nil) {
        guard var request = requests[requestID], request.state == .pending else { return }
        request.state = .denied(reason: reason)
        overseeContinuations.removeValue(forKey: requestID)
        overseeInitialRequests.remove(requestID)
        requests[requestID] = request
        enqueueDecision(
            sessionID: request.requesterSessionID,
            tabID: request.requesterTabID,
            result: "denied",
            identifier: request.id
        )
    }

    /// The requester may withdraw its own undecided card. Retaining its identity makes retries
    /// deterministic and prevents a delayed approval action from granting a cancelled request.
    func withdrawRequest(id: UUID, requesterSessionID: UUID) -> DelegationScopeRequest? {
        guard var request = requests[id], request.requesterSessionID == requesterSessionID else { return nil }
        if request.state == .pending {
            request.state = .cancelled(reason: "Withdrawn by the requesting session.")
            overseeContinuations.removeValue(forKey: id)
            overseeInitialRequests.remove(id)
            requests[id] = request
        }
        return request
    }

    // MARK: - Revocation

    /// User revocation (sidebar, monitor pill, or settings). Cascades to attenuated descendants.
    @discardableResult
    func revoke(scopeID: UUID) -> [DomainDelegationScopeRecord] {
        guard canUseAuthority else { return [] }
        let changed = authority.revoke(scopeID: scopeID)
        captureEndings(changed, reason: .userRevoked, origin: scopeID)
        // Revoking any of a session's grants also withdraws its standing "Grant all" approval;
        // otherwise its next request would silently re-grant what the user just took away.
        for record in changed {
            sessionWideApprovals.remove(record.grant.granteeSessionID)
        }
        recordRevocations(changed)
        return changed
    }

    /// Revokes every scope granted to, or rooted at, a durably deleted session.
    @discardableResult
    func revokeAll(involving sessionID: UUID, origin: AgentSessionDeletionOrigin = .unknown, fileRemoved: Bool? = nil) -> [DomainDelegationScopeRecord] {
        let evidence = OverseerScopeEnding(reason: .sessionDeleted, at: now(), actorSessionID: origin.actorSessionID, originatingSessionID: sessionID, deletionOrigin: origin.kind, fileRemoved: fileRemoved)
        deletedSessionIDs.insert(sessionID)
        sessionWideApprovals.remove(sessionID)
        if availability == .terminating { return revokeAllWhileTerminating(involving: sessionID, evidence: evidence) }
        guard canUseAuthority else { return [] }
        let changed = authority.revokeAll(involving: sessionID)
        captureEndings(changed, reason: .sessionDeleted, evidence: evidence)
        recordRevocations(changed)
        persist(invalidated: [], deletedSessions: [sessionID], deletionEndings: [sessionID: evidence])
        return changed
    }

    /// Grantee self-revocation (`release_scope`).
    func release(
        scopeID: UUID,
        caller: DomainAgentSessionCallerIdentity
    ) -> Result<[DomainDelegationScopeRecord], DomainDelegationScopeDenial> {
        guard canUseAuthority else { return .failure(.unknownScope) }
        let result = authority.release(scopeID: scopeID, caller: caller)
        if case let .success(changed) = result {
            captureEndings(changed, reason: .granteeReleased, origin: scopeID, actor: caller.agentSessionID)
            recordRevocations(changed)
        }
        return result
    }

    /// Nested sub-scope for a member overseer (Lane C's `attenuate`). No prompt.
    func attenuate(
        parentScopeID: UUID,
        presentedGeneration: UInt64,
        caller: DomainAgentSessionCallerIdentity,
        newGranteeSessionID: UUID,
        newGranteeMemberships: [DomainDelegationScopeMembershipProof],
        capabilities: Set<DomainDelegationScopeCapability>,
        guardrails: DomainDelegationScopeGuardrails
    ) -> Result<DomainDelegationScopeRecord, DomainDelegationScopeDenial> {
        guard canUseAuthority else { return .failure(.unknownScope) }
        expireDueScopes()
        let result = authority.attenuate(
            parentScopeID: parentScopeID,
            presentedGeneration: presentedGeneration,
            caller: caller,
            newGranteeSessionID: newGranteeSessionID,
            newGranteeMemberships: newGranteeMemberships,
            capabilities: capabilities,
            guardrails: guardrails,
            childScopeID: makeUUID(),
            now: now()
        )
        if case let .success(record) = result {
            didChange(grantees: [record.grant.granteeSessionID], invalidated: [])
        }
        return result
    }

    // MARK: - Private

    private static func expiryOrigin(_ chain: [DomainDelegationScopeGrant], at date: Date) -> UUID? {
        chain.last { $0.guardrails.isExpired(at: date) }?.id
    }

    private func expireDueScopes() {
        guard canUseAuthority else { return }
        let date = now()
        let expired = authority.expire(now: date)
        guard !expired.isEmpty else { return }
        for record in expired {
            let chain = authority.scopeChain(from: record.id)
            let origin = Self.expiryOrigin(chain.map(\.grant), at: date) ?? record.id
            captureEndings([record], reason: .expired, origin: origin, at: date)
        }
        didChange(grantees: Set(expired.map(\.grant.granteeSessionID)), invalidated: expired.map(\.id))
    }

    /// A committed deletion is a proven-permanent fact, so it is recorded even while quitting: the
    /// next launch must not restore authority granted to, or rooted at, a deleted session.
    private func revokeAllWhileTerminating(involving sessionID: UUID, evidence: OverseerScopeEnding) -> [DomainDelegationScopeRecord] {
        let changed = authority.revokeAll(involving: sessionID)
        captureEndings(changed, reason: .sessionDeleted, evidence: evidence)
        revokedScopeIDs.append(contentsOf: changed.map(\.id))
        persist(invalidated: changed.map(\.id), deletedSessions: [sessionID], deletionEndings: [sessionID: evidence])
        return changed
    }

    private func recordRevocations(_ changed: [DomainDelegationScopeRecord]) {
        guard !changed.isEmpty else { return }
        revokedScopeIDs.append(contentsOf: changed.map(\.id))
        let invalidated = Set(changed.map(\.id))
        announcedGrantDecisions.subtract(invalidated)
        for (id, running) in overseeContinuationTasks where invalidated.contains(running.scopeID) {
            running.task.cancel()
            overseeContinuationTasks.removeValue(forKey: id)
        }
        didChange(grantees: Set(changed.map(\.grant.granteeSessionID)), invalidated: changed.map(\.id))
        for record in changed {
            let tabID = requests.values.first { $0.state == .granted(scopeID: record.id) }?.requesterTabID
            enqueueDecision(
                sessionID: record.grant.granteeSessionID,
                tabID: tabID,
                result: "revoked",
                identifier: record.id
            )
        }
    }

    /// This is an app-owned decision notification, not target attention or an oversight grant.
    /// It never traverses the passive reducer, changes wake policy, or interrupts a running turn.
    private func enqueueDecision(sessionID: UUID, tabID: UUID?, result: String, identifier: UUID, automaticContinuation: Bool = false) {
        if result == "granted", !announcedGrantDecisions.insert(identifier).inserted { return }
        let guidance = automaticContinuation
            ? "The app is automatically continuing the approved exact-target oversight request. Do not duplicate its link/message or ask the user for a filler turn; its result will resume you."
            : "Call session_admin scope_status to inspect current authority before continuing the user's existing work."
        let text = "[RepoPrompt delegation decision: \(result); id=\(identifier.uuidString). \(guidance) This notice grants no authority or new task.]"
        #if DEBUG
            test_scopeDecision?(sessionID, text)
            if test_suppressDecisionDelivery { return }
        #endif
        let candidates = windows().filter { !$0.isClosing }.flatMap { window in
            window.agentModeViewModel.sessions.values.filter { $0.activeAgentSessionID == sessionID }.map(\.tabID)
        }
        guard let tabID = tabID ?? (candidates.count == 1 ? candidates[0] : nil),
              let presentation = Self.loadedPresentation(forTab: tabID, in: windows()),
              presentation.sessionID == sessionID,
              let session = presentation.window.agentModeViewModel.sessions[tabID]
        else { return }
        if let pending = decisions[sessionID], !pending.stopFence.permitsQueuedDelivery(to: session) {
            decisions.removeValue(forKey: sessionID)
        }
        if decisions[sessionID] == nil {
            let observation = session.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self, weak session] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard session?.activeAgentSessionID == sessionID else {
                        self.decisions.removeValue(forKey: sessionID)
                        return
                    }
                    self.drainDecisions(sessionID: sessionID)
                }
            }
            decisions[sessionID] = DecisionDelivery(tabID: tabID, stopFence: AgentRunStartStopFence(session: session), messages: [], observation: observation)
        }
        decisions[sessionID]?.messages.append(text)
        // Approval must finish its authority mutation before a provider can observe the result.
        Task { @MainActor [weak self] in self?.drainDecisions(sessionID: sessionID) }
    }

    private func drainDecisions(sessionID: UUID) {
        guard canUseAuthority else {
            decisions.removeValue(forKey: sessionID)
            return
        }
        // Publications during the save/start await must not drop the in-flight batch or start it twice.
        if decisions[sessionID]?.isDelivering == true || decisions[sessionID]?.retryScheduled == true { return }
        guard let pending = decisions[sessionID], !pending.messages.isEmpty || pending.pendingStart != nil,
              let presentation = Self.loadedPresentation(forTab: pending.tabID, in: windows()),
              !presentation.window.isClosing,
              presentation.sessionID == sessionID,
              let session = presentation.window.agentModeViewModel.sessions[pending.tabID],
              pending.stopFence.permitsQueuedDelivery(to: session)
        else {
            decisions.removeValue(forKey: sessionID)
            return
        }
        if pending.pendingStart == nil { decisions[sessionID]?.messages = [] }
        decisions[sessionID]?.isDelivering = true
        let text = pending.pendingStart?.text ?? pending.messages.joined(separator: "\n")
        Task { @MainActor [weak self] in
            let outcome = await presentation.window.agentModeViewModel.submitDelegationDecision(
                text, tabID: pending.tabID, expectedSessionID: sessionID,
                stopFence: pending.stopFence, resuming: pending.pendingStart?.delivery
            )
            guard let self, var current = decisions[sessionID], current.stopFence == pending.stopFence else { return }
            current.isDelivering = false
            switch outcome {
            case .submitted, .indeterminate:
                current.pendingStart = nil
                current.startRetryAttempts = 0
            case .retry:
                if pending.pendingStart == nil { current.messages = pending.messages + current.messages }
            case let .persisted(delivery): current.pendingStart = (text, delivery)
            }
            if current.messages.isEmpty, current.pendingStart == nil {
                decisions.removeValue(forKey: sessionID)
            } else {
                decisions[sessionID] = current
                if outcome == .submitted || outcome == .indeterminate { drainDecisions(sessionID: sessionID) }
                else if current.pendingStart != nil, !current.retryScheduled {
                    // At most five start-only retries, with 1/2/4/8/16-second backoff. Publications
                    // cannot bypass the delay or recreate the saved row. Stop/binding still fence it.
                    guard current.startRetryAttempts < 5 else {
                        current.pendingStart = nil
                        current.startRetryAttempts = 0
                        if current.messages.isEmpty { decisions.removeValue(forKey: sessionID) }
                        else { decisions[sessionID] = current }
                        if let session = presentation.window.agentModeViewModel.sessions[pending.tabID],
                           session.activeAgentSessionID == sessionID, pending.stopFence.permitsStart(of: session)
                        {
                            session.appendItem(.error("The saved approval notice could not resume this session after five retries. Automatic retries stopped; the saved notice was not duplicated. Check the provider and resume this session to inspect it.", sequenceIndex: session.nextSequenceIndex))
                        }
                        if !current.messages.isEmpty { drainDecisions(sessionID: sessionID) }
                        return
                    }
                    let delay = Duration.seconds(1 << current.startRetryAttempts)
                    decisions[sessionID]?.startRetryAttempts += 1
                    decisions[sessionID]?.retryScheduled = true
                    Task { @MainActor [weak self] in
                        var retryDelay = delay
                        #if DEBUG
                            retryDelay = self?.test_decisionStartRetryDelay ?? delay
                        #endif
                        try? await Task.sleep(for: retryDelay)
                        guard let self, decisions[sessionID]?.stopFence == pending.stopFence else { return }
                        decisions[sessionID]?.retryScheduled = false
                        drainDecisions(sessionID: sessionID)
                    }
                }
            }
        }
    }

    private func didChange(grantees: Set<UUID>, invalidated: [UUID]) {
        linkConsent.replace(authority.liveRecords(now: now()).map(\.grant))
        if !invalidated.isEmpty { scopesDidInvalidate?(Set(invalidated)) }
        liveScopesDidChange?()
        revision &+= 1
        for scopeID in invalidated {
            confirmations.invalidate(scopeID: scopeID)
        }
        persist(invalidated: invalidated)
        for sessionID in grantees.sorted(by: { $0.uuidString < $1.uuidString }) {
            notifyCatalogChanged(sessionID)
        }
    }

    /// Immutable row deltas from a live decision, never a replacement snapshot.
    private func persist(invalidated: [UUID], deletedSessions: [UUID] = [], deletionEndings: [UUID: OverseerScopeEnding] = [:]) {
        guard persistenceMode == .requiresStore, availability != .ephemeral else { return }
        let grants = authority.activeGrants.filter { !queuedGrantIDs.contains($0.id) }
        guard !grants.isEmpty || !invalidated.isEmpty || !deletedSessions.isEmpty else { return }
        // A live revoke supersedes an unsaved create, but never erases its permanent terminal fact.
        pendingSaves.removeAll { pending in
            pending.revoked.isEmpty && pending.deletedSessions.isEmpty && !pending.grants.isEmpty
                && pending.grants.allSatisfy { invalidated.contains($0.id) }
        }
        queuedGrantIDs.formUnion(grants.map(\.id))
        // A revoke must not sit behind a failed/poisoned grant. Fence live authority first (the
        // domain already did), then attempt its own terminal transaction before acknowledging
        // durability. If the entire write fails, only this process knows the deny; report that
        // limitation honestly and retain the exact operation for retry.
        if !invalidated.isEmpty || !deletedSessions.isEmpty {
            // New terminal saves enter the front of the queue. Replay older decisions first in
            // this transaction, including deletion-only facts about children absent from runtime.
            // Compose each queued decision's own delta once, not its already-composed retry prefix.
            let earlierTerminalMutations = pendingSaves.reversed().flatMap { pending in
                DelegationScopeStore.terminalMutations(revoked: pending.revoked, deletedSessions: pending.deletedSessions, deletionEndings: pending.deletionEndings, endings: pending.endings)
            }
            let terminal = PendingSave(id: makeUUID(), grants: [], revoked: invalidated, deletedSessions: deletedSessions, deletionEndings: deletionEndings, endings: scopeEndings.filter { invalidated.contains($0.key) }, earlierTerminalMutations: earlierTerminalMutations)
            let outcome = store?.record(operationID: terminal.id, grants: [], revoked: terminal.revoked, deletedSessions: terminal.deletedSessions, deletionEndings: terminal.deletionEndings, endings: terminal.endings, earlierTerminalMutations: terminal.earlierTerminalMutations) ?? .pending
            lastPersistenceOutcome = outcome
            if outcome == .applied || outcome == .unchanged {
                lastContinuityOperationID = terminal.id
            } else {
                pendingSaves.insert(terminal, at: 0)
            }
        }
        // Independent grant rows cannot poison each other's save, nor roll back a revoke.
        for grant in grants {
            pendingSaves.append(PendingSave(id: makeUUID(), grants: [grant], revoked: []))
        }
        if !grants.isEmpty, !persistenceFailed { lastPersistenceOutcome = .pending }
        startSaving()
    }

    private func startSaving() {
        guard saveTask == nil, let store, !pendingSaves.isEmpty else { return }
        saveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let pending = pendingSaves.first {
                let outcome = await Task.detached {
                    store.record(operationID: pending.id, grants: pending.grants, revoked: pending.revoked, deletedSessions: pending.deletedSessions, deletionEndings: pending.deletionEndings, endings: pending.endings, earlierTerminalMutations: pending.earlierTerminalMutations)
                }.value
                guard let index = pendingSaves.firstIndex(where: { $0.id == pending.id }) else { continue }
                lastPersistenceOutcome = outcome
                if outcome == .rejected {
                    rejectedOperations[pending.id] = "Scope continuity operation \(pending.id) was rejected and is not durable. \(store.diagnostic ?? "Inspect the saved identity before a fresh user decision.") Other saves continue."
                    pendingSaves.remove(at: index)
                    continue
                }
                guard outcome == .applied || outcome == .unchanged else { break }
                pendingSaves.remove(at: index)
                lastContinuityOperationID = pending.id
                retryDelay = 1
            }
            saveTask = nil
            if !pendingSaves.isEmpty { scheduleContinuityRetry() }
        }
    }

    private func scheduleContinuityRetry() {
        guard retryTask == nil, availability != .terminating else { return }
        let delay = retryDelay
        retryDelay = min(30, retryDelay * 2)
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            guard let self else { return }
            retryTask = nil
            if availability != .ready { await recoverContinuity() }
            startSaving()
        }
    }

    private func trimRequestRetention() {
        while requestOrder.count > Self.maxRetainedRequests {
            // Never evict a pending request; drop the oldest decided one instead.
            guard let index = requestOrder.firstIndex(where: {
                requests[$0]?.state != .pending && !overseeInitialRequests.contains($0)
                    && (overseeContinuationTasks[$0] == nil || overseeContinuationTasks[$0]?.completedAt != nil)
            }) else { return }
            let id = requestOrder.remove(at: index)
            overseeInitialOutcomes.removeValue(forKey: id)
            if let removed = requests.removeValue(forKey: id), let key = removed.idempotencyKey {
                let scopedKey = "\(removed.requesterSessionID.uuidString)|\(key)"
                if requestIDByKey[scopedKey] == id { requestIDByKey.removeValue(forKey: scopedKey) }
            }
        }
    }
}
