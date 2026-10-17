import Foundation
import RepoPromptDomainRuntime

/// Execution checkpoints: the permission re-checks an admitted operation meets after authorization
/// (capabilities, membership, link ceilings, quotas). Handlers and the front door execute and ask
/// here; they do not reinterpret permissions themselves.
///
/// Two kinds of membership are kept apart on purpose:
/// - `isPlacedMember` is a **fact** about current placement (projector proofs). It decides placement
///   data (whether a fork joins the scope, who an adoption adds, what a scoped read shows) and is
///   never an authorization gate by itself.
/// - `permitsMember` is the **permission** restriction "membership never grows"
///   (`scopeMembership`), which full access waives.
extension OverseerAuthorizationEngine {
    // MARK: - Membership

    /// Fact: `sessionID` is placed in the scope and every ancestor scope (valid projector proofs).
    func isPlacedMember(
        _ sessionID: UUID,
        ofChainFrom scope: DomainDelegationScopeRecord,
        projector: any DelegationMembershipProjector
    ) -> Bool {
        guard let scopes else { return false }
        let chain = scopes.scopeChain(from: scope.id)
        guard !chain.isEmpty else { return false }
        return chain.allSatisfy { record in
            guard let proof = projector.membershipProof(for: sessionID, in: record.grant) else { return false }
            return DomainDelegationScopeAuthority.isValid(proof, for: record.grant, targetSessionID: sessionID)
        }
    }

    /// Permission (`scopeMembership`): the operation may reach `sessionID` through `scope`.
    func permitsMember(
        _ sessionID: UUID,
        ofChainFrom scope: DomainDelegationScopeRecord,
        projector: any DelegationMembershipProjector
    ) -> Bool {
        waives(.scopeMembership) || isPlacedMember(sessionID, ofChainFrom: scope, projector: projector)
    }

    /// The write-time checkpoint for one admitted target: authority continuity (the lease is current,
    /// so OFF revocation, release, and expiry stop the operation; a full-access lease ends when the
    /// setting is turned off), the canonical write owner for mutations (`canonicalMutationOwner`),
    /// and the membership restriction (`scopeMembership`, waived by full access).
    func checkpointTarget(
        _ lease: DomainDelegationScopeLease,
        scope: DomainDelegationScopeRecord,
        projector: any DelegationMembershipProjector,
        requiresMutationOwner: Bool = true,
        operation: DomainAgentSessionTargetOperation? = nil
    ) -> Bool {
        guard let scopes, !Task.isCancelled, scopes.isCurrent(lease) else { return false }
        if requiresMutationOwner, !hasMutationOwner(for: lease.targetSessionID, operation: operation, projector: projector) {
            return false
        }
        return permitsMember(lease.targetSessionID, ofChainFrom: scope, projector: projector)
    }

    func hasMutationOwner(
        for sessionID: UUID, operation: DomainAgentSessionTargetOperation?,
        projector: any DelegationMembershipProjector
    ) -> Bool {
        guard projector.pointResolutionState(for: sessionID) == .replicated else { return true }
        guard let operation else { return false }
        switch operation {
        case .adminSetModel, .adminSetEffort, .adminWorktreeCreate, .adminWorktreeBind,
             .adminWorktreeUnbind, .adminWorktreeRelease:
            return projector.knownProvenance(for: sessionID)?.hasUniqueRuntimeOwner == true
        default:
            return false
        }
    }

    // MARK: - Capabilities

    /// The scope chain is live and holds `capability` (`scopeCapability`, and the all-sessions ceiling
    /// `allSessionsCapabilityCeiling`). Full access waives the capability limits only; a revoked,
    /// released, or expired chain never holds anything.
    func scopeChainHolds(_ capability: DomainDelegationScopeCapability, scope: DomainDelegationScopeRecord) -> Bool {
        guard let scopes else { return false }
        let chain = scopes.scopeChain(from: scope.id)
        let capabilityWaived = waives(.scopeCapability)
        let ceilingWaived = waives(.allSessionsCapabilityCeiling)
        return !chain.isEmpty && chain.allSatisfy { record in
            guard record.isActive else { return false }
            if capabilityWaived { return true }
            guard record.grant.capabilities.contains(capability) else { return false }
            if case .allSessions = record.grant.kind, !record.grant.unrestricted, !ceilingWaived {
                return DomainDelegationScopeCapability.allSessionsPermitted.contains(capability)
            }
            return true
        }
    }

    /// The scope is still the live generation it was and its chain holds `control`. Used when a target
    /// admitted as idle is found running before a stop or stash.
    func holdsControl(_ scope: DomainDelegationScopeRecord) -> Bool {
        guard let live = scopes?.record(id: scope.id), live.isActive, live.generation == scope.generation else {
            return false
        }
        return scopeChainHolds(.control, scope: live)
    }

    // MARK: - Links under a scope

    /// `observerMustBeCaller`: a scope only mints links its own grantee observes.
    var requiresScopeLinksObservedByCaller: Bool {
        !waives(.observerMustBeCaller)
    }

    /// `linkCapabilityCeiling`: a link created under a scope may carry no capability the scope chain
    /// lacks. Returns the first missing capability, or `nil`.
    func linkCeilingMissingCapability(
        minted: Set<DomainAgentSessionLinkCapability>,
        scope: DomainDelegationScopeRecord
    ) -> DomainDelegationScopeCapability? {
        guard let scopes, !waives(.linkCapabilityCeiling) else { return nil }
        for record in scopes.scopeChain(from: scope.id) {
            if let missing = DomainDelegationScopeLinkPolicy.missingCapability(linkCapabilities: minted, grant: record.grant) {
                return missing
            }
        }
        return nil
    }

    // MARK: - Placement (reparent / adopt)

    /// Re-parent placement. Structural refusals (`cycle`, `unresolved`) hold in both modes; moving the
    /// subtree between other live scopes (`otherScopeMembershipMove`) is waived by full access.
    func reparentPlacementDenial(
        source: UUID,
        destination: UUID,
        sourceAncestry: DomainDelegationOrganizationalAncestry?,
        destinationAncestry: DomainDelegationOrganizationalAncestry?,
        liveTreeScopes: [DomainDelegationTreeScopeRoot],
        callerScopeChain: Set<UUID>
    ) -> DomainDelegationScopePlacementDenial? {
        let denial = DomainDelegationScopePlacementPolicy.validateReparent(
            source: source, destination: destination, sourceAncestry: sourceAncestry,
            destinationAncestry: destinationAncestry, liveTreeScopes: liveTreeScopes, callerScopeChain: callerScopeChain
        )
        if case .affectsOtherScopes = denial, waives(.otherScopeMembershipMove) { return nil }
        return denial
    }

    /// Adoption placement. Restricted mode runs the domain rule unchanged. Full access waives the
    /// permission refusals (a nested scope may adopt, an adoptee may anchor another scope, other scopes'
    /// membership may change) and keeps the structural core: an enumerable subtree, no cycle, and
    /// resolvable, comparable ancestry. The domain rule checks permissions before structure, so the
    /// structural core is evaluated on its own here rather than by skipping a returned denial.
    func adoptPlacementDenial(
        adoptee: UUID,
        destination: UUID,
        adopteeAncestry: DomainDelegationOrganizationalAncestry?,
        destinationAncestry: DomainDelegationOrganizationalAncestry?,
        adopteeSubtree: Set<UUID>?,
        scopeAnchors: Set<UUID>,
        liveTreeScopes: [DomainDelegationTreeScopeRoot],
        callerScope: DomainDelegationScopeGrant
    ) -> DomainDelegationScopePlacementDenial? {
        guard waives(.restrictedScopeNarrowing), waives(.scopeAnchorMoveRestriction), waives(.otherScopeMembershipMove) else {
            return DomainDelegationScopePlacementPolicy.validateAdopt(
                adoptee: adoptee, destination: destination, adopteeAncestry: adopteeAncestry,
                destinationAncestry: destinationAncestry, adopteeSubtree: adopteeSubtree, scopeAnchors: scopeAnchors,
                liveTreeScopes: liveTreeScopes, callerScope: callerScope
            )
        }
        guard adopteeSubtree != nil else { return .unresolved }
        let structural = DomainDelegationScopePlacementPolicy.validateReparent(
            source: adoptee, destination: destination, sourceAncestry: adopteeAncestry,
            destinationAncestry: destinationAncestry, liveTreeScopes: liveTreeScopes, callerScopeChain: []
        )
        if case .affectsOtherScopes = structural { return nil }
        return structural
    }

    enum PlacementDepthDenial: Equatable {
        /// The destination ancestry or moved subtree cannot be resolved for a configured limit.
        case unresolved
        case exceeded(DomainDelegationScopeDenial)
    }

    /// `maxDepth` of every tree scope on the admitted chain after moving `sessionID`'s subtree under a
    /// destination. Restricted mode only (`sessionQuota`); full access never refuses for depth.
    func placementDepthDenial(
        scope: DomainDelegationScopeRecord,
        moving sessionID: UUID,
        destinationAncestry: DomainDelegationOrganizationalAncestry?,
        projector: any DelegationMembershipProjector
    ) -> PlacementDepthDenial? {
        guard let scopes, !waives(.sessionQuota) else { return nil }
        let limits = scopes.scopeChain(from: scope.id).compactMap { record -> DomainDelegationTreeDepthLimit? in
            guard case let .tree(root) = record.grant.kind, let maxDepth = record.grant.guardrails.maxDepth else { return nil }
            return DomainDelegationTreeDepthLimit(rootSessionID: root, maxDepth: maxDepth)
        }
        guard !limits.isEmpty else { return nil }
        guard let destinationAncestry,
              let height = projector.organizationalSubtree(of: sessionID)?.map(\.depth).max()
        else { return .unresolved }
        return DomainDelegationScopePlacementPolicy.depthViolation(
            destinationAncestry: destinationAncestry, movedSubtreeHeight: height, limits: limits
        ).map(PlacementDepthDenial.exceeded)
    }

    /// Adoption brings sessions from outside the admitted scope into it, so restricted mode refuses an
    /// adoptee that is already placed there ("use reparent"). Under full access the admitted scope may
    /// be the full-access grant, which every session belongs to; adoption then performs its placement
    /// (and stamp) instead of being refused (`scopeMembership`).
    func adoptionRefusesPlacedAdoptee(
        _ adoptee: UUID,
        scope: DomainDelegationScopeRecord,
        projector: any DelegationMembershipProjector
    ) -> Bool {
        !waives(.scopeMembership) && isPlacedMember(adoptee, ofChainFrom: scope, projector: projector)
    }

    /// The scope an adoption stamps onto the moved subtree. Normally the caller's admitted scope, which
    /// must contain the destination so the stamp is consistent with placement. Full access never
    /// refuses for that: when the destination is outside the admitted scope it stamps the caller's
    /// full-access grant instead, which every session belongs to, so the metadata stays valid.
    /// Restricted mode returns `nil` (the uniform denial).
    func adoptionStampScope(
        admitted scope: DomainDelegationScopeRecord,
        callerSessionID: UUID,
        destination: UUID,
        projector: any DelegationMembershipProjector
    ) -> DomainDelegationScopeRecord? {
        if isPlacedMember(destination, ofChainFrom: scope, projector: projector) { return scope }
        guard waives(.scopeMembership) else { return nil }
        return scopes?.ensureGlobalAutoApproveScope(for: callerSessionID)
    }

    // MARK: - Quotas

    /// `maxLiveSessions` / `maxWorktrees` against post-adopt membership: the scope's current usage
    /// (with in-flight reservations) plus every session that would join. Unknown liveness counts as
    /// live so the check only gets stricter. Full access waives it (`sessionQuota`, `worktreeQuota`).
    func adoptionQuotaDenial(
        scope: DomainDelegationScopeRecord,
        moved: Set<UUID>,
        projector: any DelegationMembershipProjector
    ) -> DomainDelegationScopeDenial? {
        guard let scopes, !waives(.sessionQuota), !waives(.worktreeQuota) else { return nil }
        let joining = moved.filter { !isPlacedMember($0, ofChainFrom: scope, projector: projector) }
        let addedLive = joining.count { projector.knownProvenance(for: $0)?.isLive ?? true }
        let addedWorktrees = joining.reduce(into: Set<String>()) {
            $0.formUnion(projector.knownProvenance(for: $1)?.boundWorktreeIDs ?? [])
        }.count
        for record in scopes.scopeChain(from: scope.id) {
            guard let evidence = projector.usageEvidence(of: record.grant, spawnParentSessionID: nil) else {
                return .usageProofMissing
            }
            let usage = scopes.usageIncludingReservations(evidence)
            if let denial = DomainDelegationScopePlacementPolicy.adoptionGuardrailViolation(
                guardrails: record.grant.guardrails, usage: usage,
                addedLiveSessions: addedLive, addedWorktrees: addedWorktrees
            ) {
                return denial
            }
        }
        return nil
    }

    /// The host facts a worktree binding is counted against.
    struct WorktreeBindingCensus {
        /// Worktree ID → sessions binding it, across every loaded session.
        let bound: [String: Set<UUID>]
        /// The target's bindings in other windows that survive replacing its selected-window binding.
        let retainedTargetIDs: Set<String>
        let ownership: WorktreeOwnershipStore
    }

    /// Admits binding `desiredIDs` to `target` under `scope` against every restricted `maxWorktrees`
    /// the target (and reactivated creators) count toward, and reserves the added identities.
    /// Full access waives it (`worktreeQuota`): nothing is counted or reserved.
    func admitWorktreeBinding(
        _ desiredIDs: Set<String>,
        target: UUID,
        scope: DomainDelegationScopeRecord,
        census: WorktreeBindingCensus,
        projector: any DelegationMembershipProjector
    ) throws -> [DelegationScopeReservation] {
        guard let scopes, !waives(.worktreeQuota) else { return [] }
        let reactivated = desiredIDs.compactMap { census.ownership.record(worktreeID: $0) }
            .filter { $0.releasedAt != nil && $0.createdBySessionID != nil }
        var records = try scopes.scopeChain(from: scope.id)
            + DelegationSpawnAdmission.guardrailScopes(forCreator: target, scopes: scopes, projector: projector)
        for creator in Set(reactivated.compactMap(\.createdBySessionID)) {
            records += try DelegationSpawnAdmission.guardrailScopes(forCreator: creator, scopes: scopes, projector: projector)
        }
        // A target can count toward overlapping creator scopes and their restricted ancestors,
        // even when the authorizing scope itself is unrestricted.
        records = records.flatMap { scopes.scopeChain(from: $0.id) }
        let byID = Dictionary(
            records.filter { !$0.grant.unrestricted && $0.grant.guardrails.maxWorktrees != nil }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var admitted: [(UUID, Set<String>)] = []
        for record in byID.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let projected = projector.usageEvidence(of: record.grant, spawnParentSessionID: nil) else {
                throw SessionAdminHostError.usageEvidenceUnavailable
            }
            let members = Set(projector.members(of: record.grant))
            let owned = census.ownership.ownedUnreleasedWorktreeIDs(createdBy: members)
            let currentIDs = Set(census.bound.filter { !$0.value.isDisjoint(with: members) }.keys).union(owned)
            let addedIDs = (members.contains(target) ? desiredIDs : [])
                .union(reactivated.filter { $0.createdBySessionID.map(members.contains) ?? false }.map(\.worktreeID))
            // Replace this target's selected-window contribution while retaining bindings in other
            // windows, another member's bindings, and unreleased ownership rows.
            let postIDs = Set(census.bound.filter { !$0.value.subtracting([target]).isDisjoint(with: members) }.keys)
                .union(members.contains(target) ? census.retainedTargetIDs : [])
                .union(owned).union(addedIDs)
            let anonymous = max(0, projected.worktreeCount - projected.countedWorktreeIDs.count)
            let postUsage = scopes.usageIncludingReservations(DomainDelegationScopeUsage(
                scopeID: record.id, liveSessionCount: projected.liveSessionCount,
                worktreeCount: postIDs.count + anonymous, countedWorktreeIDs: postIDs
            ))
            if let limit = record.grant.guardrails.maxWorktrees, postUsage.worktreeCount > limit {
                let current = scopes.usageIncludingReservations(DomainDelegationScopeUsage(
                    scopeID: record.id, liveSessionCount: projected.liveSessionCount,
                    worktreeCount: currentIDs.count + anonymous, countedWorktreeIDs: currentIDs
                )).worktreeCount
                throw SessionAdminHostError.guardrailExceeded(limit: limit, current: current)
            }
            admitted.append((record.id, addedIDs))
        }
        // Every check and all reservations are synchronous, so no competing bind can pass between the
        // census and the reservation. Identity reservations remain held independently by each
        // admitted bind, even if another bind of the same identity later fails.
        return admitted.map { scopes.reserve(scopeIDs: [$0.0], worktreeIDs: $0.1) }
    }
}
