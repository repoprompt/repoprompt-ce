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
    /// failed write is retried on the next change; until then a revocation is enforced in memory and
    /// by its tombstone at the next successful write, but not yet on disk.
    @Published private(set) var lastPersistenceOutcome: DelegationScopeWriteOutcome?

    var persistenceFailed: Bool {
        lastPersistenceOutcome == .writeFailed
    }

    let confirmations: BatchConfirmationCoordinator

    private var authority = DomainDelegationScopeAuthority()
    private var store: DelegationScopeStore?
    private var requestOrder: [UUID] = []
    private var requestIDByKey: [String: UUID] = [:]
    private var persistChain: Task<Void, Never>?
    /// Revoked/released scope IDs, newest last. Persisted as tombstones honored by `reactivate`.
    private var revokedScopeIDs: [UUID] = []
    private let now: () -> Date
    private let makeUUID: () -> UUID
    private let notifyCatalogChanged: (UUID) -> Void

    init(
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init,
        confirmations: BatchConfirmationCoordinator? = nil,
        notifyCatalogChanged: @escaping (UUID) -> Void = { sessionID in
            // Forced: a scope change alters `session_admin` eligibility without changing any link
            // fact, so the link-only change detection would otherwise skip the relist.
            Task { await ServerNetworkManager.shared.notifyToolListChangedForAgentSession(sessionID, forceRelist: true) }
        }
    ) {
        self.now = now
        self.makeUUID = makeUUID
        self.confirmations = confirmations ?? BatchConfirmationCoordinator(now: now, makeUUID: makeUUID)
        self.notifyCatalogChanged = notifyCatalogChanged
    }

    // MARK: - Launch

    /// Loads durable grants once and reactivates them under fresh generations.
    func bootstrap(store: DelegationScopeStore) async {
        guard self.store == nil else { return }
        self.store = store
        guard case let .ready(_, grants, revoked) = await store.loadForLaunch() else { return }
        revokedScopeIDs = revoked
        let installed = authority.reactivate(grants, revokedScopeIDs: Set(revoked), now: now())
        // A reload may drop expired or orphaned rows; persisting keeps the file equal to authority.
        didChange(grantees: Set(installed.map(\.grant.granteeSessionID)), invalidated: [])
    }

    /// Waits for every queued write. Tests and shutdown use this as a linearization point.
    func flushPersistence() async {
        await persistChain?.value
    }

    /// Synchronous, bounded write of the current grants and tombstones for `applicationWillTerminate`.
    ///
    /// Queued main-actor writes cannot run while the main thread is terminating, so this writes the
    /// latest state straight through the store actor (which runs off the main thread) and waits at
    /// most `timeout`. The store serializes it after any write already in flight, so the newest state
    /// lands last.
    func flushForTermination(timeout: TimeInterval = 2) {
        guard let store else { return }
        let grants = authority.activeGrants
        let revoked = revokedScopeIDs
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await store.replace(with: grants, revokedScopeIDs: revoked)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    // MARK: - Queries

    func hasLiveScope(grantedTo sessionID: UUID) -> Bool {
        expireDueScopes()
        return authority.hasLiveScope(grantedTo: sessionID, now: now())
    }

    func liveScopes(grantedTo sessionID: UUID) -> [DomainDelegationScopeRecord] {
        expireDueScopes()
        return authority.liveScopes(grantedTo: sessionID, now: now())
    }

    func scopes(grantedTo sessionID: UUID) -> [DomainDelegationScopeRecord] {
        expireDueScopes()
        return authority.scopes(grantedTo: sessionID)
    }

    func record(id: UUID) -> DomainDelegationScopeRecord? {
        expireDueScopes()
        return authority.record(id: id)
    }

    func scopeChain(from scopeID: UUID) -> [DomainDelegationScopeRecord] {
        authority.scopeChain(from: scopeID)
    }

    /// Every live scope, for the user's "Active delegations" list. A pure query (safe from a view
    /// body): expired-by-time scopes are filtered out without mutating state.
    func allLiveScopes() -> [DomainDelegationScopeRecord] {
        authority.activeGrants
            .compactMap { authority.liveRecord(id: $0.id, now: now()) }
            .sorted { $0.grant.grantedAt < $1.grant.grantedAt }
    }

    /// Roots of every live `.tree` scope, for placement decisions (`reparent`, `adopt`).
    func liveTreeScopeRoots() -> [DomainDelegationTreeScopeRoot] {
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
        expireDueScopes()
        return authority.authorize(request, now: now())
    }

    /// Whether a lease issued earlier still authorizes. Handlers must re-check after every
    /// suspension point before mutating, exactly like link leases: a revocation, release, or expiry
    /// that lands mid-operation stops authority immediately.
    func isCurrent(_ lease: DomainDelegationScopeLease) -> Bool {
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

    // MARK: - Revocation

    /// User revocation (sidebar, monitor pill, or settings). Cascades to attenuated descendants.
    @discardableResult
    func revoke(scopeID: UUID) -> [DomainDelegationScopeRecord] {
        let changed = authority.revoke(scopeID: scopeID)
        recordRevocations(changed)
        return changed
    }

    /// Revokes every scope granted to, or rooted at, a durably deleted session.
    @discardableResult
    func revokeAll(involving sessionID: UUID) -> [DomainDelegationScopeRecord] {
        let changed = authority.revokeAll(involving: sessionID)
        recordRevocations(changed)
        return changed
    }

    /// Grantee self-revocation (`release_scope`).
    func release(
        scopeID: UUID,
        caller: DomainAgentSessionCallerIdentity
    ) -> Result<[DomainDelegationScopeRecord], DomainDelegationScopeDenial> {
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
        guard let store else { return }
        let grants = authority.activeGrants
        let revoked = revokedScopeIDs
        let previous = persistChain
        persistChain = Task { @MainActor [weak self] in
            await previous?.value
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
