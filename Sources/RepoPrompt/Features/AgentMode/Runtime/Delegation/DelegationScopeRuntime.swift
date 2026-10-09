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
    /// The tab whose Agent Mode view shows the card.
    let requesterTabID: UUID?
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
    /// Bounded retention of decided requests so `scope_status` can still report them.
    static let maxRetainedRequests = 256

    @Published private(set) var requests: [UUID: DelegationScopeRequest] = [:]
    /// Bumped on every authority change so presentation can refresh.
    @Published private(set) var revision: UInt64 = 0
    /// Last durable write outcome. A failed write is retried on the next change; until then a
    /// revocation is enforced in memory but not yet on disk.
    private(set) var lastPersistenceOutcome: DelegationScopeWriteOutcome?

    let confirmations: BatchConfirmationCoordinator

    private var authority = DomainDelegationScopeAuthority()
    private var store: DelegationScopeStore?
    private var requestOrder: [UUID] = []
    private var requestIDByKey: [String: UUID] = [:]
    private var persistChain: Task<Void, Never>?
    private let now: () -> Date
    private let makeUUID: () -> UUID
    private let notifyCatalogChanged: (UUID) -> Void

    init(
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init,
        confirmations: BatchConfirmationCoordinator? = nil,
        notifyCatalogChanged: @escaping (UUID) -> Void = { sessionID in
            Task { await ServerNetworkManager.shared.notifyToolListChangedForAgentSession(sessionID) }
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
        guard case let .ready(_, grants) = await store.loadForLaunch() else { return }
        let installed = authority.reactivate(grants, now: now())
        // A reload may drop expired or orphaned rows; persisting keeps the file equal to authority.
        didChange(grantees: Set(installed.map(\.grant.granteeSessionID)), invalidated: [])
    }

    /// Waits for every queued write. Tests and shutdown use this as a linearization point.
    func flushPersistence() async {
        await persistChain?.value
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

    /// The request, but only for the session that made it.
    func request(id: UUID, requesterSessionID: UUID) -> DelegationScopeRequest? {
        guard let request = requests[id], request.requesterSessionID == requesterSessionID else { return nil }
        return request
    }

    func pendingRequests(forTab tabID: UUID) -> [DelegationScopeRequest] {
        requestOrder.compactMap { requests[$0] }.filter { $0.requesterTabID == tabID && $0.state == .pending }
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
        idempotencyKey: String?
    ) -> Result<DelegationScopeRequest, DelegationScopeRequestError> {
        var guardrails = requestedGuardrails
        guardrails.expiresAt = nil
        if let expiresInSeconds, expiresInSeconds < Self.minimumExpirySeconds {
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
        let pendingCount = requests.values.filter {
            $0.requesterSessionID == requesterSessionID && $0.state == .pending
        }.count
        guard pendingCount < Self.maxPendingRequestsPerSession else { return .failure(.tooManyPending) }
        let request = DelegationScopeRequest(
            id: makeUUID(),
            requesterSessionID: requesterSessionID,
            requesterTabID: requesterTabID,
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

    /// The user approved the grant card, optionally narrowing capabilities or tightening guardrails.
    ///
    /// A requested lifetime starts now. If the approved values fail validation the request is
    /// closed as denied rather than left pending, so the card can never get stuck.
    @discardableResult
    func approve(
        requestID: UUID,
        capabilities: Set<DomainDelegationScopeCapability>? = nil,
        guardrails: DomainDelegationScopeGuardrails? = nil
    ) -> Result<DomainDelegationScopeRecord, DomainDelegationScopeDenial> {
        guard var request = requests[requestID], request.state == .pending else { return .failure(.unknownScope) }
        let approvedAt = now()
        var approvedGuardrails = guardrails ?? request.guardrails
        if guardrails == nil, let seconds = request.expiresInSeconds {
            approvedGuardrails.expiresAt = approvedAt.addingTimeInterval(TimeInterval(seconds))
        }
        let grantRequest = DomainDelegationScopeGrantRequest(
            granteeSessionID: request.requesterSessionID,
            kind: request.kind,
            capabilities: capabilities ?? request.capabilities,
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
        didChange(grantees: Set(changed.map(\.grant.granteeSessionID)), invalidated: changed.map(\.id))
        return changed
    }

    /// Grantee self-revocation (`release_scope`).
    func release(
        scopeID: UUID,
        caller: DomainAgentSessionCallerIdentity
    ) -> Result<[DomainDelegationScopeRecord], DomainDelegationScopeDenial> {
        let result = authority.release(scopeID: scopeID, caller: caller)
        if case let .success(changed) = result {
            didChange(grantees: Set(changed.map(\.grant.granteeSessionID)), invalidated: changed.map(\.id))
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
        let previous = persistChain
        persistChain = Task { @MainActor [weak self] in
            await previous?.value
            var outcome = await store.replace(with: grants)
            if outcome == .writeFailed {
                outcome = await store.replace(with: grants)
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
