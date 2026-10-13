import Combine
import Foundation
import RepoPromptDomainRuntime

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
    @Published private(set) var recoveryNotice: String?

    var canUseAuthority: Bool {
        availability == .ready || availability == .ephemeral
    }

    var authorityUnavailableReason: String? {
        switch availability {
        case .ready, .ephemeral: nil
        case .awaitingStore: "Delegation approval is unavailable while saved authority is being opened."
        case let .blocked(message): message
        case .terminating: "Delegation authority is closed because RepoPrompt is quitting."
        }
    }

    /// A physical session removal may invalidate saved grant anchors. Production must hold an
    /// acknowledged open scope document before deletion can begin, even when no scope is currently
    /// live. Explicit ephemeral fixtures have no durable authority to invalidate; a suppressed
    /// production launch is different because it has deliberately left the shared file untouched.
    var durableDeletionUnavailableReason: String? {
        switch availability {
        case .ready:
            nil
        case .ephemeral:
            persistenceMode == .ephemeral ? nil
                : "This launch suppresses delegation persistence. Restart RepoPrompt normally before deleting saved sessions."
        case .awaitingStore:
            "Saved delegation authority has not opened safely yet. Wait for startup to finish before deleting saved sessions."
        case let .blocked(message):
            message
        case .terminating:
            "RepoPrompt is quitting."
        }
    }

    var persistenceStatusMessage: String? {
        if let authorityUnavailableReason { return authorityUnavailableReason }
        if persistenceFailed {
            return "Delegation changes could not be saved. Revocations still apply; a restart may require approval again."
        }
        return recoveryNotice
    }

    static let maxPendingRequestsPerSession = 4
    static let maxReasonUTF8Bytes = 500
    static let minimumExpirySeconds = 60
    /// Agent-proposed lifetimes are capped at 30 days.
    static let maximumExpirySeconds = 30 * 24 * 60 * 60
    /// Revocation tombstones kept in memory and on disk.
    static let maxRevokedScopeIDs = DelegationScopeDocument.maxRevokedScopeIDs
    /// Bounded retention of decided requests so `scope_status` can still report them.
    static let maxRetainedRequests = 256

    @Published private(set) var requests: [UUID: DelegationScopeRequest] = [:]
    /// Bumped on every authority change so presentation can refresh.
    @Published private(set) var revision: UInt64 = 0
    /// Last durable write outcome, published so the delegations list can surface a failure. A
    /// revocation applies immediately in memory. If no final snapshot is acknowledged, the open
    /// launch fence prevents any stale saved authority from returning after restart.
    @Published private(set) var lastPersistenceOutcome: DelegationScopeWriteOutcome?

    var persistenceFailed: Bool {
        lastPersistenceOutcome == .writeFailed || lastPersistenceOutcome == .blocked
    }

    let confirmations: BatchConfirmationCoordinator

    private var authority = DomainDelegationScopeAuthority()
    private var store: DelegationScopeStore?
    private var reservations: [UUID: DelegationScopeReservation] = [:]
    private var requestOrder: [UUID] = []
    private var requestIDByKey: [String: UUID] = [:]
    private var persistChain: Task<Void, Never>?
    let persistenceMode: PersistenceMode
    private var frozenSnapshot: (grants: [DomainDelegationScopeGrant], revoked: [UUID])?
    private var terminationRequiresReapproval = false
    private var terminationWrite: Task<DelegationScopeWriteOutcome, Never>?
    /// Revoked/released scope IDs, newest last. Persisted as tombstones honored by `reactivate`.
    private var revokedScopeIDs: [UUID] = []
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

    /// The store must acknowledge the open-launch fence before any persisted authority is installed.
    func bootstrap(store: DelegationScopeStore) async {
        guard persistenceMode == .requiresStore, self.store == nil,
              availability == .awaitingStore else { return }
        self.store = store
        let loaded = await store.loadForLaunch()
        // Quit can begin while the store actor is reading or opening the document.
        guard availability == .awaitingStore else { return }
        switch loaded {
        case let .ready(source, grants, revoked):
            revokedScopeIDs = revoked
            switch source {
            case .legacyRequiresApproval:
                recoveryNotice = "Saved delegations need approval again after this safety update."
            case .uncleanRequiresApproval:
                recoveryNotice = "Saved delegations need approval again because the previous launch did not finish saving its authority."
            case .missing, .loaded, .quarantined:
                break
            }
            let installed = authority.reactivate(grants, revokedScopeIDs: Set(revoked), now: now())
            availability = .ready
            didChange(grantees: Set(installed.map(\.grant.granteeSessionID)), invalidated: [])
        case let .blocked(reason):
            availability = .blocked(reason.message)
            lastPersistenceOutcome = .blocked
        case .suppressed:
            // Explicit launch policy, never a fallback from failed production I/O.
            availability = .ephemeral
        }
    }

    func flushPersistence() async {
        await persistChain?.value
    }

    /// Synchronous admission fence. The caller may allow a clean seal only after the existing
    /// per-session deletion owner has closed admission and proved no reported attempt or commit
    /// callback is pending. An uncertain shutdown leaves the launch open instead of trusting those
    /// potentially incomplete revocations. Whole-workspace deletion has a separate lifecycle.
    func freezeForTermination(allowRestoration: Bool) {
        guard availability != .terminating else { return }
        let active = authority.activeGrants
        if availability == .ready {
            if allowRestoration {
                frozenSnapshot = (active, revokedScopeIDs)
            } else {
                terminationRequiresReapproval = true
            }
        }
        availability = .terminating
        revision &+= 1
        for grant in active {
            confirmations.invalidate(scopeID: grant.id)
        }
    }

    /// One bounded async final write. Timeout never reopens authority or releases the store lock.
    /// A late completion is safe because the captured snapshot cannot change after the freeze.
    func settleForTermination(timeout: TimeInterval = 2) async -> Bool {
        // A caller that skipped the synchronous shutdown proof may close execution, but cannot
        // silently claim a safe restorable snapshot.
        if availability != .terminating { freezeForTermination(allowRestoration: false) }
        guard let store, let frozenSnapshot else { return !terminationRequiresReapproval }
        if terminationWrite == nil {
            terminationWrite = Task {
                await store.finishLaunch(with: frozenSnapshot.grants, revokedScopeIDs: frozenSnapshot.revoked)
            }
        }
        guard let write = terminationWrite else { return false }
        let seconds = timeout.isFinite ? max(0, min(timeout, 60)) : 2
        return await withCheckedContinuation { continuation in
            let gate = TerminationSettlement(continuation)
            let deadline = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                catch { return }
                gate.finish(false)
            }
            Task { @MainActor [weak self] in
                let outcome = await write.value
                self?.lastPersistenceOutcome = outcome
                deadline.cancel()
                gate.finish(outcome == .applied || outcome == .unchanged)
            }
        }
    }

    private final class TerminationSettlement {
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func finish(_ result: Bool) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: result)
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
        return authority.scopes(grantedTo: sessionID)
    }

    func record(id: UUID) -> DomainDelegationScopeRecord? {
        guard canUseAuthority else { return nil }
        expireDueScopes()
        return authority.record(id: id)
    }

    func scopeChain(from scopeID: UUID) -> [DomainDelegationScopeRecord] {
        guard canUseAuthority else { return [] }
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
        workspaceName: String? = nil
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
            now: now()
        ) {
            return .failure(.invalid(denial))
        }
        let key = idempotencyKey.map { "\(requesterSessionID.uuidString)|\($0)" }
        if let key, let existingID = requestIDByKey[key], let existing = requests[existingID] {
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

    /// Re-read the app-owned binding at the synchronous grant boundary. A stale rendered card,
    /// a rebound tab, or a duplicate tab in another physical window can never approve a grant.
    @discardableResult
    func approve(
        requestID: UUID,
        presentedWindowID: Int,
        presentedTabID: UUID,
        presentedSessionID: UUID,
        capabilities: Set<DomainDelegationScopeCapability>? = nil,
        guardrails: DomainDelegationScopeGuardrails? = nil
    ) -> Result<DomainDelegationScopeRecord, DomainDelegationScopeDenial> {
        guard let request = requests[requestID], request.state == .pending,
              request.requesterTabID == presentedTabID,
              request.requesterSessionID == presentedSessionID,
              request.requesterWindowID == presentedWindowID,
              explicitPresentationWindow(tabID: presentedTabID, sessionID: presentedSessionID)?.windowID == presentedWindowID
        else { return .failure(.unknownScope) }
        return approve(requestID: requestID, capabilities: capabilities, guardrails: guardrails)
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
        guardrails: DomainDelegationScopeGuardrails? = nil
    ) -> Result<DomainDelegationScopeRecord, DomainDelegationScopeDenial> {
        guard canUseAuthority else { return .failure(.unknownScope) }
        guard var request = requests[requestID], request.state == .pending else { return .failure(.unknownScope) }
        let approvedCapabilities = capabilities ?? request.capabilities
        guard approvedCapabilities.isSubset(of: request.capabilities) else {
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
            didChange(grantees: [record.grant.granteeSessionID], invalidated: [])
        case let .failure(denial):
            request.state = .denied(reason: "Approval failed validation (\(denial.diagnosticLabel)).")
            requests[requestID] = request
        }
        return result
    }

    func deny(requestID: UUID, reason: String? = nil) {
        guard var request = requests[requestID], request.state == .pending else { return }
        request.state = .denied(reason: reason)
        requests[requestID] = request
    }

    /// The requester may withdraw its own undecided card. Retaining its identity makes retries
    /// deterministic and prevents a delayed approval action from granting a cancelled request.
    func withdrawRequest(id: UUID, requesterSessionID: UUID) -> DelegationScopeRequest? {
        guard var request = requests[id], request.requesterSessionID == requesterSessionID else { return nil }
        if request.state == .pending {
            request.state = .cancelled(reason: "Withdrawn by the requesting session.")
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
        recordRevocations(changed)
        return changed
    }

    /// Revokes every scope granted to, or rooted at, a durably deleted session.
    @discardableResult
    func revokeAll(involving sessionID: UUID) -> [DomainDelegationScopeRecord] {
        guard canUseAuthority else { return [] }
        let changed = authority.revokeAll(involving: sessionID)
        recordRevocations(changed)
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

    private func expireDueScopes() {
        guard canUseAuthority else { return }
        let expired = authority.expire(now: now())
        guard !expired.isEmpty else { return }
        didChange(grantees: Set(expired.map(\.grant.granteeSessionID)), invalidated: expired.map(\.id))
    }

    private func recordRevocations(_ changed: [DomainDelegationScopeRecord]) {
        guard !changed.isEmpty else { return }
        revokedScopeIDs.append(contentsOf: changed.map(\.id))
        if revokedScopeIDs.count > Self.maxRevokedScopeIDs {
            revokedScopeIDs.removeFirst(revokedScopeIDs.count - Self.maxRevokedScopeIDs)
        }
        didChange(grantees: Set(changed.map(\.grant.granteeSessionID)), invalidated: changed.map(\.id))
    }

    private func didChange(grantees: Set<UUID>, invalidated: [UUID]) {
        revision &+= 1
        for scopeID in invalidated {
            confirmations.invalidate(scopeID: scopeID)
        }
        persist()
        for sessionID in grantees.sorted(by: { $0.uuidString < $1.uuidString }) {
            notifyCatalogChanged(sessionID)
        }
    }

    /// Serialized write-through of the authority's active grants.
    ///
    /// Each write carries the authority's *current* grants, so any later change (including the next
    /// expiry check) rewrites a previously failed revocation. A failed write is retried once
    /// immediately; the outcome is retained for diagnostics.
    private func persist() {
        guard availability == .ready, let store else { return }
        let grants = authority.activeGrants
        let revoked = revokedScopeIDs
        let previous = persistChain
        persistChain = Task { @MainActor [weak self] in
            await previous?.value
            guard self?.availability == .ready else { return }
            var outcome = await store.replace(with: grants, revokedScopeIDs: revoked)
            if outcome == .writeFailed {
                outcome = await store.replace(with: grants, revokedScopeIDs: revoked)
            }
            self?.lastPersistenceOutcome = outcome
        }
    }

    private func trimRequestRetention() {
        while requestOrder.count > Self.maxRetainedRequests {
            // Never evict a pending request; drop the oldest decided one instead.
            guard let index = requestOrder.firstIndex(where: { requests[$0]?.state != .pending }) else { return }
            let id = requestOrder.remove(at: index)
            if let removed = requests.removeValue(forKey: id), let key = removed.idempotencyKey {
                requestIDByKey.removeValue(forKey: "\(removed.requesterSessionID.uuidString)|\(key)")
            }
        }
    }
}
