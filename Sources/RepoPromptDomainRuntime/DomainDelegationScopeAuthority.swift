import Foundation

/// A user's grant request, before it becomes a scope.
package struct DomainDelegationScopeGrantRequest: Hashable, Sendable {
    package let granteeSessionID: UUID
    package let kind: DomainDelegationScopeKind
    package let capabilities: Set<DomainDelegationScopeCapability>
    package let guardrails: DomainDelegationScopeGuardrails

    package init(
        granteeSessionID: UUID,
        kind: DomainDelegationScopeKind,
        capabilities: Set<DomainDelegationScopeCapability>,
        guardrails: DomainDelegationScopeGuardrails
    ) {
        self.granteeSessionID = granteeSessionID
        self.kind = kind
        self.capabilities = capabilities
        self.guardrails = guardrails
    }
}

/// Everything the single scope authority check needs for one call, all app-presented.
///
/// `memberships` and `usage` are computed by the app from persisted provenance and live state; the
/// MCP layer must never derive them from tool arguments.
package struct DomainDelegationScopeAuthorizationRequest: Sendable {
    package let operation: DomainAgentSessionTargetOperation
    package let caller: DomainAgentSessionCallerIdentity
    package let scopeID: UUID
    /// The generation the caller's service captured before any suspension.
    package let presentedGeneration: UInt64
    /// Target sessions in request order. Empty for scope-level operations.
    package let targetSessionIDs: [UUID]
    /// Per target, one proof for the scope **and each ancestor scope**: an attenuated scope covers
    /// only sessions that are also members of every scope it descends from.
    package let memberships: [UUID: [DomainDelegationScopeMembershipProof]]
    /// Usage of the scope and every ancestor, keyed by scope ID. Needed only for guardrail operations.
    package let usageByScopeID: [UUID: DomainDelegationScopeUsage]
    /// App-presented run state per target, for state-dependent requirements (`retire`). A missing
    /// entry is `unknown`, which is treated as `running`.
    package let targetStates: [UUID: DomainDelegationScopeTargetState]
    /// `DomainDelegationScopeArgumentsDigest` of this call's arguments; a presented card must match.
    package let argumentsDigest: String
    package let idempotencyKey: String?
    package let confirmation: DomainDelegationScopeConfirmation?

    package init(
        operation: DomainAgentSessionTargetOperation,
        caller: DomainAgentSessionCallerIdentity,
        scopeID: UUID,
        presentedGeneration: UInt64,
        targetSessionIDs: [UUID] = [],
        memberships: [UUID: [DomainDelegationScopeMembershipProof]] = [:],
        usageByScopeID: [UUID: DomainDelegationScopeUsage] = [:],
        targetStates: [UUID: DomainDelegationScopeTargetState] = [:],
        argumentsDigest: String = "",
        idempotencyKey: String? = nil,
        confirmation: DomainDelegationScopeConfirmation? = nil
    ) {
        self.argumentsDigest = argumentsDigest
        self.operation = operation
        self.caller = caller
        self.scopeID = scopeID
        self.presentedGeneration = presentedGeneration
        self.targetSessionIDs = targetSessionIDs
        self.memberships = memberships
        self.usageByScopeID = usageByScopeID
        self.targetStates = targetStates
        self.idempotencyKey = idempotencyKey
        self.confirmation = confirmation
    }
}

package enum DomainDelegationScopeAuthorizationOutcome: Equatable, Sendable {
    /// Every admitted target is authorized; `requires_control` items are set aside, not failed.
    /// Scope-level operations return no leases.
    case authorized(DomainDelegationScopeAuthorizedItems)
    /// Steps 1–4 passed for the admitted items, but a batch card must be approved first. The card
    /// lists exactly the admitted items.
    case confirmationRequired(DomainDelegationScopeConfirmationReason, DomainDelegationScopeAuthorizedItems)
    /// The first failing check. `sessionID` names the failing target when there is one.
    case denied(DomainDelegationScopeDenial, sessionID: UUID?)

    package var isAuthorized: Bool {
        guard case .authorized = self else { return false }
        return true
    }

    package var denial: DomainDelegationScopeDenial? {
        switch self {
        case .authorized:
            nil
        case let .confirmationRequired(reason, _):
            .confirmationRequired(reason: reason)
        case let .denied(denial, _):
            denial
        }
    }
}

/// Pure, value-typed authority over delegation scopes.
///
/// It owns scope records, generations, attenuation, cascade revocation, expiry, membership-proof
/// validation, guardrail math, and the confirmation requirement. It performs no I/O and holds no
/// clock: every time-dependent call takes `now`. The app wraps one instance in a main-actor runtime
/// that persists `activeGrants` and serializes access.
///
/// Decision order for a target-bearing operation (design §2.7):
/// 1. the caller's scope is live (granted to this caller, active, not expired, generation matches);
/// 2. the state-independent capabilities are held — checked before membership because they do
///    not depend on the target, so a capability denial reveals nothing about membership;
/// 3. each target's app-presented membership proofs are valid for the scope and every ancestor;
///    a member whose run state demands more (`retire` of a running target needs `control`) is set
///    aside as `requires_control` rather than failing the batch, and is never granted implicitly;
/// 4. guardrails allow the operation (spawn and worktree creation);
/// 5. a batch confirmation card is not required for the admitted items, or a matching approved
///    one is presented.
package struct DomainDelegationScopeAuthority: Sendable {
    private var records: [UUID: DomainDelegationScopeRecord] = [:]
    private var lastGeneration: UInt64 = 0

    package init() {}

    // MARK: - Queries

    package func record(id: UUID) -> DomainDelegationScopeRecord? {
        records[id]
    }

    /// The record when it is active and not past its expiry at `now`.
    package func liveRecord(id: UUID, now: Date) -> DomainDelegationScopeRecord? {
        guard let record = records[id], record.isActive, !record.grant.guardrails.isExpired(at: now) else {
            return nil
        }
        return record
    }

    package func liveScopes(grantedTo sessionID: UUID, now: Date) -> [DomainDelegationScopeRecord] {
        records.values
            .filter { $0.grant.granteeSessionID == sessionID && liveRecord(id: $0.id, now: now) != nil }
            .sorted { $0.grant.grantedAt < $1.grant.grantedAt }
    }

    package func hasLiveScope(grantedTo sessionID: UUID, now: Date) -> Bool {
        records.values.contains {
            $0.grant.granteeSessionID == sessionID && liveRecord(id: $0.id, now: now) != nil
        }
    }

    /// Every record the caller was ever granted in this process, including revoked/expired ones,
    /// so `scope_status` can report why a scope stopped working.
    package func scopes(grantedTo sessionID: UUID) -> [DomainDelegationScopeRecord] {
        records.values
            .filter { $0.grant.granteeSessionID == sessionID }
            .sorted { $0.grant.grantedAt < $1.grant.grantedAt }
    }

    /// Durable payload: the grants of every currently active record.
    package var activeGrants: [DomainDelegationScopeGrant] {
        records.values.filter(\.isActive).map(\.grant).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// The scope followed by each ancestor, nearest first.
    package func scopeChain(from scopeID: UUID) -> [DomainDelegationScopeRecord] {
        var chain: [DomainDelegationScopeRecord] = []
        var seen: Set<UUID> = []
        var cursor: UUID? = scopeID
        while let id = cursor, let record = records[id], seen.insert(id).inserted {
            chain.append(record)
            cursor = record.grant.parentScopeID
        }
        return chain
    }

    package func descendants(of scopeID: UUID) -> [UUID] {
        var result: [UUID] = []
        var frontier = [scopeID]
        var seen: Set<UUID> = [scopeID]
        while let next = frontier.popLast() {
            for record in records.values where record.grant.parentScopeID == next && seen.insert(record.id).inserted {
                result.append(record.id)
                frontier.append(record.id)
            }
        }
        return result
    }

    // MARK: - Grant

    /// Structural validation shared by user grants and attenuation.
    package static func validate(
        kind: DomainDelegationScopeKind,
        capabilities: Set<DomainDelegationScopeCapability>,
        guardrails: DomainDelegationScopeGuardrails,
        now: Date
    ) -> DomainDelegationScopeDenial? {
        guard !capabilities.isEmpty else { return .capabilitiesEmpty }
        if case .allSessions = kind {
            let forbidden = capabilities.subtracting(DomainDelegationScopeCapability.allSessionsPermitted)
            if let first = DomainDelegationScopeCapability.allCases.first(where: forbidden.contains) {
                return .capabilityNotPermittedForKind(first)
            }
        }
        guard guardrails.isWellFormed else { return .guardrailsMalformed }
        // Depth is measured from a tree root; on any other kind it could never be evaluated and would
        // silently block every spawn.
        if guardrails.maxDepth != nil {
            guard case .tree = kind else { return .guardrailsMalformed }
        }
        guard !guardrails.isExpired(at: now) else { return .expiryInPast }
        return nil
    }

    /// Creates a user-granted scope. Only the user's approval path may call this.
    package mutating func grant(
        _ request: DomainDelegationScopeGrantRequest,
        scopeID: UUID,
        now: Date
    ) -> Result<DomainDelegationScopeRecord, DomainDelegationScopeDenial> {
        if let denial = Self.validate(
            kind: request.kind,
            capabilities: request.capabilities,
            guardrails: request.guardrails,
            now: now
        ) {
            return .failure(denial)
        }
        guard records[scopeID] == nil else { return .failure(.duplicateScopeID) }
        let grant = DomainDelegationScopeGrant(
            id: scopeID,
            granteeSessionID: request.granteeSessionID,
            kind: request.kind,
            capabilities: request.capabilities,
            guardrails: request.guardrails,
            origin: .user,
            grantedAt: now
        )
        return .success(install(grant, state: .active))
    }

    /// Creates a nested sub-scope for a member overseer without a prompt.
    ///
    /// Requires `spawn` in the parent scope and valid membership proofs for the new grantee in the
    /// parent and every ancestor. The child is a `.tree` rooted at its grantee, its capabilities are a
    /// subset of the parent's, its guardrails are no looser, and its expiry is no later. Its leases
    /// additionally require membership in every ancestor, so the child never covers a session the
    /// parent could not reach.
    package mutating func attenuate(
        parentScopeID: UUID,
        presentedGeneration: UInt64,
        caller: DomainAgentSessionCallerIdentity,
        newGranteeSessionID newGrantee: UUID,
        newGranteeMemberships: [DomainDelegationScopeMembershipProof],
        capabilities: Set<DomainDelegationScopeCapability>,
        guardrails: DomainDelegationScopeGuardrails,
        childScopeID: UUID,
        now: Date
    ) -> Result<DomainDelegationScopeRecord, DomainDelegationScopeDenial> {
        // The lease checks caller and grantee identity first, so a non-grantee learns nothing.
        if case let .failure(denial) = lease(
            scopeID: parentScopeID,
            presentedGeneration: presentedGeneration,
            caller: caller,
            operation: .adminAttenuate,
            targetSessionID: newGrantee,
            memberships: newGranteeMemberships,
            now: now
        ) {
            return .failure(denial)
        }
        guard caller.agentSessionID != newGrantee else {
            return .failure(.selfTarget)
        }
        guard let parent = liveRecord(id: parentScopeID, now: now) else {
            return .failure(.attenuationParentInactive)
        }
        guard capabilities.isSubset(of: parent.grant.capabilities) else {
            return .failure(.attenuationWidensCapabilities)
        }
        guard guardrails.isNoLooserThan(parent.grant.guardrails) else {
            return .failure(.attenuationLoosensGuardrails)
        }
        let kind = DomainDelegationScopeKind.tree(rootSessionID: newGrantee)
        if let denial = Self.validate(kind: kind, capabilities: capabilities, guardrails: guardrails, now: now) {
            return .failure(denial)
        }
        guard records[childScopeID] == nil else { return .failure(.duplicateScopeID) }
        let grant = DomainDelegationScopeGrant(
            id: childScopeID,
            granteeSessionID: newGrantee,
            kind: kind,
            capabilities: capabilities,
            guardrails: guardrails,
            origin: .attenuatedFrom(scopeID: parentScopeID),
            grantedAt: now
        )
        return .success(install(grant, state: .active))
    }

    // MARK: - Revocation, release, expiry

    /// Revokes a scope and every attenuated descendant. Each affected record gets a new generation,
    /// so any lease or captured generation stops authorizing immediately. Sessions keep running and
    /// links remain until released; only authority stops.
    ///
    /// - Returns: the records that changed state, the requested scope first.
    @discardableResult
    package mutating func revoke(scopeID: UUID) -> [DomainDelegationScopeRecord] {
        transition([scopeID] + descendants(of: scopeID), to: .revoked)
    }

    /// Self-revocation by the grantee (`release_scope`). Cascades like `revoke`.
    package mutating func release(
        scopeID: UUID,
        caller: DomainAgentSessionCallerIdentity
    ) -> Result<[DomainDelegationScopeRecord], DomainDelegationScopeDenial> {
        guard let callerSessionID = caller.agentSessionID else { return .failure(.callerNotAgentSession) }
        guard let record = records[scopeID] else { return .failure(.unknownScope) }
        guard record.grant.granteeSessionID == callerSessionID else { return .failure(.granteeMismatch) }
        return .success(revoke(scopeID: scopeID))
    }

    /// Marks every active scope whose expiry has passed, plus its descendants, as expired.
    @discardableResult
    package mutating func expire(now: Date) -> [DomainDelegationScopeRecord] {
        let due = records.values
            .filter { $0.isActive && $0.grant.guardrails.isExpired(at: now) }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        var ids: [UUID] = []
        for id in due {
            ids.append(id)
            ids.append(contentsOf: descendants(of: id))
        }
        return transition(ids, to: .expired)
    }

    /// Revokes every scope granted to `sessionID` or rooted at it (and their descendants). Used when
    /// the session is durably deleted: nothing may keep acting for or over a session that is gone.
    @discardableResult
    package mutating func revokeAll(involving sessionID: UUID) -> [DomainDelegationScopeRecord] {
        let ids = records.values
            .filter { record in
                guard record.isActive else { return false }
                if record.grant.granteeSessionID == sessionID { return true }
                if case let .tree(rootSessionID) = record.grant.kind { return rootSessionID == sessionID }
                return false
            }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        var changed: [DomainDelegationScopeRecord] = []
        for id in ids {
            changed.append(contentsOf: revoke(scopeID: id))
        }
        return changed
    }

    /// Launch reload: installs persisted grants under fresh generations.
    ///
    /// Grants whose expiry has passed, grants named by a revocation tombstone, and attenuated grants
    /// whose parent is missing, inactive, or tombstoned are dropped, so neither a cascade nor a
    /// revocation can be undone by a reload — even if a stale file still lists the grant. An
    /// attenuated row must also still satisfy the attenuation invariants against its parent (a tree
    /// rooted at its grantee, capabilities a subset, guardrails no looser), so a tampered or corrupted
    /// child row can never come back wider than its parent.
    @discardableResult
    package mutating func reactivate(
        _ grants: [DomainDelegationScopeGrant],
        revokedScopeIDs: Set<UUID> = [],
        now: Date
    ) -> [DomainDelegationScopeRecord] {
        var pending = grants.filter { records[$0.id] == nil && !revokedScopeIDs.contains($0.id) }
        var installed: [DomainDelegationScopeRecord] = []
        var progressed = true
        while progressed {
            progressed = false
            var remaining: [DomainDelegationScopeGrant] = []
            for grant in pending {
                if let parentID = grant.parentScopeID {
                    guard let parent = records[parentID] else {
                        remaining.append(grant)
                        continue
                    }
                    guard parent.isActive,
                          grant.kind == .tree(rootSessionID: grant.granteeSessionID),
                          grant.capabilities.isSubset(of: parent.grant.capabilities),
                          grant.guardrails.isNoLooserThan(parent.grant.guardrails)
                    else { continue }
                }
                guard Self.validate(
                    kind: grant.kind,
                    capabilities: grant.capabilities,
                    guardrails: grant.guardrails,
                    now: now
                ) == nil else { continue }
                installed.append(install(grant, state: .active))
                progressed = true
            }
            pending = remaining
        }
        return installed
    }

    // MARK: - Leases

    /// Issues a lease for one target after decision steps 1–3.
    ///
    /// - Parameter targetState: the target's app-presented run state; only state-dependent
    ///   operations read it. `unknown` (the default) is treated as `running`.
    package func lease(
        scopeID: UUID,
        presentedGeneration: UInt64,
        caller: DomainAgentSessionCallerIdentity,
        operation: DomainAgentSessionTargetOperation,
        targetSessionID: UUID,
        memberships: [DomainDelegationScopeMembershipProof],
        targetState: DomainDelegationScopeTargetState = .unknown,
        now: Date
    ) -> Result<DomainDelegationScopeLease, DomainDelegationScopeDenial> {
        let live: DomainDelegationScopeRecord
        switch liveScope(scopeID: scopeID, presentedGeneration: presentedGeneration, caller: caller, now: now) {
        case let .success(record): live = record
        case let .failure(denial): return .failure(denial)
        }
        guard !operation.isScopeLevel, let capability = operation.requiredScopeCapability else {
            return .failure(.operationNotScopeAuthorizable)
        }
        // Every ancestor must still be live: an attenuated scope never outlives its parents.
        if let denial = ancestorLivenessDenial(of: live, now: now) {
            return .failure(denial)
        }
        // The idle-state requirement does not depend on the target, so it is checked before
        // membership: a capability denial is identical for members and non-members and probes nothing.
        // It is checked against the whole chain, so a child can never exercise what a parent lacks.
        let baseline = operation.requiredScopeCapabilities(for: .idle)
        if let missing = DomainDelegationScopeCapability.allCases.first(where: {
            baseline.contains($0) && !chainHolds($0, from: live)
        }) {
            return .failure(.capabilityMissing(missing))
        }
        if operation.requiresScopeMembership || operation.family != .delegation {
            // An attenuated scope covers only sessions that are members of every ancestor too.
            for record in scopeChain(from: live.id) {
                guard let proof = memberships.first(where: { $0.scopeID == record.id }) else {
                    return .failure(.membershipProofMissing)
                }
                guard Self.isValid(proof, for: record.grant, targetSessionID: targetSessionID) else {
                    return .failure(.membershipProofInvalid)
                }
            }
        }
        if operation.deniesScopeSelfTarget, targetSessionID == caller.agentSessionID {
            return .failure(.selfTarget)
        }
        // State-dependent extras (stopping a running target needs `control`) are checked only for an
        // established member, and are never granted implicitly.
        let extra = operation.requiredScopeCapabilities(for: targetState).subtracting(baseline)
        if extra.contains(where: { !chainHolds($0, from: live) }) {
            return .failure(.requiresControl)
        }
        return .success(DomainDelegationScopeLease(
            scopeID: live.id,
            generation: live.generation,
            capability: capability,
            granteeSessionID: live.grant.granteeSessionID,
            targetSessionID: targetSessionID
        ))
    }

    /// Validates that a lease is still current. A revoked, expired, or re-generated scope fails.
    package func isCurrent(_ lease: DomainDelegationScopeLease, now: Date) -> Bool {
        guard let live = liveRecord(id: lease.scopeID, now: now) else { return false }
        return live.generation == lease.generation && live.grant.granteeSessionID == lease.granteeSessionID
    }

    // MARK: - Guardrails

    /// Decision step 4. Every scope in the chain counts its whole subtree, so a nested overseer's
    /// spawn is bounded by its own limits *and* every ancestor's.
    ///
    /// `current` in a `guardrailExceeded` denial is the count before the operation for count
    /// guardrails, and the depth the new session would have for `maxDepth`.
    ///
    /// - Parameter fallbackParentDepth: the spawning parent's depth in the requested scope, used
    ///   when that scope's usage carries no explicit `spawnParentDepth`.
    package func evaluateGuardrails(
        scopeID: UUID,
        operation: DomainAgentSessionTargetOperation,
        usageByScopeID: [UUID: DomainDelegationScopeUsage],
        fallbackParentDepth: Int? = nil
    ) -> DomainDelegationScopeDenial? {
        guard let use = operation.scopeGuardrailUse else { return nil }
        for record in scopeChain(from: scopeID) {
            let guardrails = record.grant.guardrails
            switch use {
            case .session:
                if let limit = guardrails.maxLiveSessions {
                    guard let usage = usageByScopeID[record.id] else { return .usageProofMissing }
                    if usage.liveSessionCount + 1 > limit {
                        return .guardrailExceeded(
                            guardrail: .maxLiveSessions,
                            limit: limit,
                            current: usage.liveSessionCount
                        )
                    }
                }
                if let limit = guardrails.maxDepth {
                    let explicitDepth = usageByScopeID[record.id]?.spawnParentDepth
                    let depth = explicitDepth ?? (record.id == scopeID ? fallbackParentDepth : nil)
                    guard let parentDepth = depth else { return .usageProofMissing }
                    if parentDepth + 1 > limit {
                        return .guardrailExceeded(guardrail: .maxDepth, limit: limit, current: parentDepth + 1)
                    }
                }
            case .worktree:
                if let limit = guardrails.maxWorktrees {
                    guard let usage = usageByScopeID[record.id] else { return .usageProofMissing }
                    if usage.worktreeCount + 1 > limit {
                        return .guardrailExceeded(
                            guardrail: .maxWorktrees,
                            limit: limit,
                            current: usage.worktreeCount
                        )
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Confirmation

    /// Decision step 5: whether a batch confirmation card is required.
    package static func confirmationRequirement(
        operation: DomainAgentSessionTargetOperation,
        itemCount: Int,
        guardrails: DomainDelegationScopeGuardrails
    ) -> DomainDelegationScopeConfirmationReason? {
        switch operation.scopeConfirmationClass {
        case .none:
            nil
        case .alwaysCarded:
            .destructive
        case .adoption:
            .adoption
        case .reversible:
            itemCount > guardrails.bulkConfirmationThreshold ? .bulkThreshold : nil
        }
    }

    /// An approved card authorizes exactly its bound scope generation, operation, key, and a subset
    /// of the items the user left ticked.
    package static func confirmationMatches(
        _ confirmation: DomainDelegationScopeConfirmation,
        scope: DomainDelegationScopeRecord,
        operation: DomainAgentSessionTargetOperation,
        idempotencyKey: String?,
        argumentsDigest: String = "",
        targetSessionIDs: [UUID]
    ) -> Bool {
        confirmation.scopeID == scope.id
            && confirmation.scopeGeneration == scope.generation
            && confirmation.operation == operation
            && confirmation.idempotencyKey == idempotencyKey
            && confirmation.argumentsDigest == argumentsDigest
            && !targetSessionIDs.isEmpty
            && Set(targetSessionIDs).isSubset(of: confirmation.approvedSessionIDs)
    }

    // MARK: - Single authority check

    /// Runs decision steps 1–5 for one call, in order, and reports the first failure.
    package func authorize(
        _ request: DomainDelegationScopeAuthorizationRequest,
        now: Date
    ) -> DomainDelegationScopeAuthorizationOutcome {
        let operation = request.operation
        guard !operation.isScopeLifecycle, operation.requiredScopeCapability != nil else {
            return .denied(.operationNotScopeAuthorizable, sessionID: nil)
        }
        let live: DomainDelegationScopeRecord
        switch liveScope(
            scopeID: request.scopeID,
            presentedGeneration: request.presentedGeneration,
            caller: request.caller,
            now: now
        ) {
        case let .success(record): live = record
        case let .failure(denial): return .denied(denial, sessionID: nil)
        }

        if operation.isScopeLevel {
            guard let capability = operation.requiredScopeCapability else {
                return .denied(.operationNotScopeAuthorizable, sessionID: nil)
            }
            if let denial = ancestorLivenessDenial(of: live, now: now) {
                return .denied(denial, sessionID: nil)
            }
            guard chainHolds(capability, from: live) else {
                return .denied(.capabilityMissing(capability), sessionID: nil)
            }
            return .authorized(DomainDelegationScopeAuthorizedItems())
        }

        guard !request.targetSessionIDs.isEmpty else {
            return .denied(.membershipProofMissing, sessionID: nil)
        }
        var leases: [DomainDelegationScopeLease] = []
        var bases: [DomainAgentSessionAuthorityBasis] = []
        var itemsRequiringControl: [UUID] = []
        for targetSessionID in request.targetSessionIDs {
            let issued = lease(
                scopeID: request.scopeID,
                presentedGeneration: request.presentedGeneration,
                caller: request.caller,
                operation: operation,
                targetSessionID: targetSessionID,
                memberships: request.memberships[targetSessionID] ?? [],
                targetState: request.targetStates[targetSessionID] ?? .unknown,
                now: now
            )
            switch issued {
            case .failure(.requiresControl):
                // A member the operation would have to stop: reported per item, never granted.
                itemsRequiringControl.append(targetSessionID)
            case let .failure(denial):
                return .denied(denial, sessionID: targetSessionID)
            case let .success(lease):
                // The operation authorizer independently binds the lease to this exact operation,
                // caller, and target, so the scope authority is never the only gate.
                let decision = DomainAgentSessionOperationAuthorizer.authorize(
                    operation: operation,
                    caller: request.caller,
                    target: .known(targetSessionID: targetSessionID, parentSessionID: nil),
                    scopeLease: lease
                )
                guard let basis = decision.basis else {
                    return .denied(.operationNotScopeAuthorizable, sessionID: targetSessionID)
                }
                leases.append(lease)
                bases.append(basis)
            }
        }

        if operation.scopeGuardrailUse != nil {
            // Session-creating operations name the new session's organizational parent as target.
            let fallbackDepth = request.targetSessionIDs.first.flatMap { target in
                request.memberships[target]?.first { $0.scopeID == request.scopeID }?.treeDepth
            }
            if let denial = evaluateGuardrails(
                scopeID: request.scopeID,
                operation: operation,
                usageByScopeID: request.usageByScopeID,
                fallbackParentDepth: fallbackDepth
            ) {
                return .denied(denial, sessionID: nil)
            }
        }

        let items = DomainDelegationScopeAuthorizedItems(
            leases: leases,
            bases: bases,
            itemsRequiringControl: itemsRequiringControl
        )
        // Only admitted items are carded or applied; with none admitted there is nothing to confirm.
        let admitted = items.admittedSessionIDs
        if !admitted.isEmpty,
           let reason = Self.confirmationRequirement(
               operation: operation,
               itemCount: admitted.count,
               guardrails: live.grant.guardrails
           )
        {
            guard let confirmation = request.confirmation else {
                return .confirmationRequired(reason, items)
            }
            guard Self.confirmationMatches(
                confirmation,
                scope: live,
                operation: operation,
                idempotencyKey: request.idempotencyKey,
                argumentsDigest: request.argumentsDigest,
                targetSessionIDs: admitted
            ) else {
                return .denied(.confirmationMismatch, sessionID: nil)
            }
        }
        return .authorized(items)
    }

    // MARK: - Private

    /// Decision step 1. Grantee identity is checked before any state is disclosed, so an unrelated
    /// caller learns nothing about a scope it was never granted.
    private func liveScope(
        scopeID: UUID,
        presentedGeneration: UInt64,
        caller: DomainAgentSessionCallerIdentity,
        now: Date
    ) -> Result<DomainDelegationScopeRecord, DomainDelegationScopeDenial> {
        guard let callerSessionID = caller.agentSessionID else { return .failure(.callerNotAgentSession) }
        guard let record = records[scopeID] else { return .failure(.unknownScope) }
        guard record.grant.granteeSessionID == callerSessionID else { return .failure(.granteeMismatch) }
        if let denial = Self.inactiveDenial(record, now: now) { return .failure(denial) }
        guard record.generation == presentedGeneration else { return .failure(.generationStale) }
        return .success(record)
    }

    /// Why a record no longer authorizes: revoked (or released) is reported as such, everything else
    /// that stopped being live as expired.
    private static func inactiveDenial(_ record: DomainDelegationScopeRecord, now: Date) -> DomainDelegationScopeDenial? {
        switch record.state {
        case .revoked:
            .revoked
        case .expired:
            .expired
        case .active:
            record.grant.guardrails.isExpired(at: now) ? .expired : nil
        }
    }

    /// The first ancestor that is no longer live, as a denial. Cascades normally keep this in step;
    /// it is re-checked so no ordering of events can let a child act after its parent stopped.
    private func ancestorLivenessDenial(of record: DomainDelegationScopeRecord, now: Date) -> DomainDelegationScopeDenial? {
        for ancestor in scopeChain(from: record.id).dropFirst() {
            if let denial = Self.inactiveDenial(ancestor, now: now) { return denial }
        }
        if let parentID = record.grant.parentScopeID, records[parentID] == nil { return .revoked }
        return nil
    }

    /// A capability is usable only if the scope and every ancestor hold it.
    private func chainHolds(_ capability: DomainDelegationScopeCapability, from record: DomainDelegationScopeRecord) -> Bool {
        scopeChain(from: record.id).allSatisfy { Self.holds(capability, in: $0.grant) }
    }

    /// The `.allSessions` restriction is re-checked here, not only at grant time, so no record that
    /// somehow carries a forbidden capability can exercise it.
    private static func holds(
        _ capability: DomainDelegationScopeCapability,
        in grant: DomainDelegationScopeGrant
    ) -> Bool {
        guard grant.capabilities.contains(capability) else { return false }
        if case .allSessions = grant.kind {
            return DomainDelegationScopeCapability.allSessionsPermitted.contains(capability)
        }
        return true
    }

    /// Membership-proof validation. The proof is app-presented; this checks that it is internally
    /// consistent and actually describes membership of *this* scope for *this* target.
    package static func isValid(
        _ proof: DomainDelegationScopeMembershipProof,
        for grant: DomainDelegationScopeGrant,
        targetSessionID: UUID
    ) -> Bool {
        guard proof.scopeID == grant.id, proof.targetSessionID == targetSessionID else { return false }
        switch (grant.kind, proof.basis) {
        case let (.tree(rootSessionID), .treePath(path)):
            return path.first == targetSessionID
                && path.last == rootSessionID
                && Set(path).count == path.count
        case let (.workspace(workspaceID), .workspace(proofWorkspaceID)):
            return workspaceID == proofWorkspaceID
        case (.allSessions, .allSessions):
            return true
        default:
            return false
        }
    }

    private mutating func nextGeneration() -> UInt64 {
        lastGeneration &+= 1
        return lastGeneration
    }

    private mutating func install(
        _ grant: DomainDelegationScopeGrant,
        state: DomainDelegationScopeState
    ) -> DomainDelegationScopeRecord {
        let record = DomainDelegationScopeRecord(grant: grant, generation: nextGeneration(), state: state)
        records[grant.id] = record
        return record
    }

    private mutating func transition(
        _ ids: [UUID],
        to state: DomainDelegationScopeState
    ) -> [DomainDelegationScopeRecord] {
        var changed: [DomainDelegationScopeRecord] = []
        for id in ids {
            guard let record = records[id], record.isActive else { continue }
            let next = DomainDelegationScopeRecord(grant: record.grant, generation: nextGeneration(), state: state)
            records[id] = next
            changed.append(next)
        }
        return changed
    }
}
