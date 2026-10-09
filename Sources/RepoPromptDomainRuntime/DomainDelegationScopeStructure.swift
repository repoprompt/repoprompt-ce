import Foundation

// Pure policies for the structural delegation operations (Milestone 1, Lane C): the link
// capability ceiling, organizational placement (re-parent and adopt), organizational-chain walks,
// and worktree staleness.
//
// Everything here is AppKit-free and decides from app-presented facts only. Membership itself is
// still proven through `DomainDelegationScopeMembershipProof` and `DomainDelegationScopeAuthority`;
// these helpers add the operation-specific rules that sit on top of an already-authorized lease.

// MARK: - Link capability ceiling

/// The maximum oversight-link capabilities a scope grantee may give a link it creates.
///
/// A scope never mints link authority it does not itself hold:
/// - read-side link capabilities (`poll`, `wait`, `read`) need scope `observe`;
/// - `send_when_idle` and `manage` (which carries steer, respond, stop, and set-model) need scope
///   `control`.
///
/// Without `control` a link may therefore carry at most `poll`/`wait`/`read`. The ceiling only gates
/// *creation*: an existing link is never upgraded or otherwise mutated by scope authority.
package enum DomainDelegationScopeLinkPolicy {
    package static let readCapabilities: Set<DomainAgentSessionLinkCapability> = [.poll, .wait, .read]
    package static let controlCapabilities: Set<DomainAgentSessionLinkCapability> = [.sendWhenIdle, .manage]

    package static func requiredScopeCapabilities(
        for linkCapabilities: Set<DomainAgentSessionLinkCapability>
    ) -> Set<DomainDelegationScopeCapability> {
        var required: Set<DomainDelegationScopeCapability> = []
        for capability in linkCapabilities {
            switch capability {
            case .poll, .wait, .read:
                required.insert(.observe)
            case .sendWhenIdle, .manage:
                required.insert(.control)
            }
        }
        return required
    }

    /// The largest link capability set `grant` may mint. `.allSessions` scopes are re-restricted
    /// here exactly as in the authority, so a malformed record can never mint `control`-class links.
    package static func ceiling(for grant: DomainDelegationScopeGrant) -> Set<DomainAgentSessionLinkCapability> {
        var ceiling: Set<DomainAgentSessionLinkCapability> = []
        if holds(.observe, in: grant) { ceiling.formUnion(readCapabilities) }
        if holds(.control, in: grant) { ceiling.formUnion(controlCapabilities) }
        return ceiling
    }

    /// The first scope capability, in canonical order, that a link carrying `linkCapabilities` needs
    /// but `grant` does not hold; `nil` when the link is within the ceiling.
    package static func missingCapability(
        linkCapabilities: Set<DomainAgentSessionLinkCapability>,
        grant: DomainDelegationScopeGrant
    ) -> DomainDelegationScopeCapability? {
        let required = requiredScopeCapabilities(for: linkCapabilities)
        return DomainDelegationScopeCapability.allCases.first { required.contains($0) && !holds($0, in: grant) }
    }

    /// Whether a link carrying exactly `linkCapabilities` may be created under `grant`.
    package static func permits(
        linkCapabilities: Set<DomainAgentSessionLinkCapability>,
        grant: DomainDelegationScopeGrant
    ) -> Bool {
        !linkCapabilities.isEmpty && linkCapabilities.isSubset(of: ceiling(for: grant))
    }

    private static func holds(_ capability: DomainDelegationScopeCapability, in grant: DomainDelegationScopeGrant) -> Bool {
        guard grant.capabilities.contains(capability) else { return false }
        if case .allSessions = grant.kind {
            return DomainDelegationScopeCapability.allSessionsPermitted.contains(capability)
        }
        return true
    }
}

// MARK: - Organizational chain

package enum DomainDelegationOrganizationalChain {
    /// Defensive bound shared with the app projector; a longer chain is treated as cyclic.
    package static let maxLength = 256

    /// Target-first organizational ancestry (`[session, parent, grandparent, …]`) following
    /// `parent`, or `nil` when the walk revisits a session or exceeds `maxLength`.
    package static func ancestry(of sessionID: UUID, parent: (UUID) -> UUID?) -> [UUID]? {
        var chain = [sessionID]
        var seen: Set<UUID> = [sessionID]
        var cursor = sessionID
        while let next = parent(cursor) {
            guard chain.count < maxLength, seen.insert(next).inserted else { return nil }
            chain.append(next)
            cursor = next
        }
        return chain
    }
}

// MARK: - Organizational placement (re-parent, adopt)

/// One live `.tree` scope, as the app presents it to the placement policy.
package struct DomainDelegationTreeScopeRoot: Hashable, Sendable {
    package let scopeID: UUID
    package let rootSessionID: UUID

    package init(scopeID: UUID, rootSessionID: UUID) {
        self.scopeID = scopeID
        self.rootSessionID = rootSessionID
    }
}

/// Why a placement change was refused after the authority admitted its endpoints.
package enum DomainDelegationScopePlacementDenial: Error, Hashable, Sendable {
    /// The destination is the moved session or one of its organizational descendants, or an
    /// organizational chain could not be resolved.
    case cycle
    /// The move would change the membership (join *or* leave) of these live scopes, none of which is
    /// on the caller's own scope chain. Sorted by UUID string for stable output.
    case affectsOtherScopes([UUID])
    /// `adopt` under an attenuated (nested) scope would enlarge an ancestor scope without that being
    /// shown on the user's card. Refused in Milestone 1.
    case adoptionRequiresUserGrantedScope

    package var publicCode: String {
        switch self {
        case .cycle: "placement_cycle"
        case .affectsOtherScopes: "placement_affects_other_scopes"
        case .adoptionRequiresUserGrantedScope: "adopt_requires_user_granted_scope"
        }
    }

    package var affectedScopeIDs: [UUID] {
        guard case let .affectsOtherScopes(ids) = self else { return [] }
        return ids
    }
}

/// Decides whether moving a session to a new organizational parent is permitted.
///
/// `.tree` membership is "the scope root is on my organizational chain". Moving a session (and, with
/// it, its whole subtree) under `destination` changes its chain from `sourceAncestry` to
/// `[source] + destinationAncestry`, so it joins every tree scope rooted only on the new chain and
/// leaves every tree scope rooted only on the old one. `.workspace` and `.allSessions` membership
/// never depends on placement.
///
/// The rule is conservative: a placement change may not alter the membership of **any** live scope
/// outside the caller's own scope chain (its scope and that scope's ancestors). Re-parent endpoints
/// are already members of every scope on that chain, so the chain itself never changes; an `adopt`
/// joins exactly the caller's (user-granted, root) scope, and that is what its user card shows.
package enum DomainDelegationScopePlacementPolicy {
    /// Live tree scopes whose membership the move changes, sorted by UUID string.
    package static func affectedTreeScopes(
        movedSessionID: UUID,
        previousAncestry: [UUID],
        destinationAncestry: [UUID],
        liveTreeScopes: [DomainDelegationTreeScopeRoot]
    ) -> [UUID] {
        let previous = Set(previousAncestry)
        let next = Set([movedSessionID] + destinationAncestry)
        let changedRoots = previous.symmetricDifference(next)
        return liveTreeScopes
            .filter { changedRoots.contains($0.rootSessionID) }
            .map(\.scopeID)
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// `reparent`: source and destination were both proven members of the caller's scope chain.
    ///
    /// - Parameters:
    ///   - sourceAncestry: the source's current target-first ancestry, or `nil` when unresolved.
    ///   - destinationAncestry: the destination's target-first ancestry, or `nil` when unresolved.
    ///   - callerScopeChain: the caller's scope and every ancestor scope.
    package static func validateReparent(
        source: UUID,
        destination: UUID,
        sourceAncestry: [UUID]?,
        destinationAncestry: [UUID]?,
        liveTreeScopes: [DomainDelegationTreeScopeRoot],
        callerScopeChain: Set<UUID>
    ) -> DomainDelegationScopePlacementDenial? {
        guard source != destination,
              let sourceAncestry,
              let destinationAncestry,
              !destinationAncestry.contains(source)
        else { return .cycle }
        let foreign = affectedTreeScopes(
            movedSessionID: source,
            previousAncestry: sourceAncestry,
            destinationAncestry: destinationAncestry,
            liveTreeScopes: liveTreeScopes
        ).filter { !callerScopeChain.contains($0) }
        return foreign.isEmpty ? nil : .affectsOtherScopes(foreign)
    }

    /// `adopt`: the adoptee is outside the caller's scope; the destination was proven a member.
    ///
    /// Only a user-granted (non-attenuated) scope may adopt, so the only scope the adoptee joins on
    /// purpose is the one the user's card names. Any other membership change is refused.
    package static func validateAdopt(
        adoptee: UUID,
        destination: UUID,
        adopteeAncestry: [UUID]?,
        destinationAncestry: [UUID]?,
        liveTreeScopes: [DomainDelegationTreeScopeRoot],
        callerScope: DomainDelegationScopeGrant
    ) -> DomainDelegationScopePlacementDenial? {
        guard callerScope.parentScopeID == nil else { return .adoptionRequiresUserGrantedScope }
        guard adoptee != destination,
              let adopteeAncestry,
              let destinationAncestry,
              !destinationAncestry.contains(adoptee)
        else { return .cycle }
        let foreign = affectedTreeScopes(
            movedSessionID: adoptee,
            previousAncestry: adopteeAncestry,
            destinationAncestry: destinationAncestry,
            liveTreeScopes: liveTreeScopes
        ).filter { $0 != callerScope.id }
        return foreign.isEmpty ? nil : .affectsOtherScopes(foreign)
    }
}

// MARK: - Worktree staleness

/// Flags `worktree_inventory` reports so an overseer (and ultimately the user) can find worktrees to
/// release. Flags only describe; removing or pruning a worktree stays human-only.
package enum DomainDelegationWorktreeStaleFlag: String, CaseIterable, Hashable, Sendable {
    /// Released through `worktree_release` (unbound and marked stale for human cleanup).
    case released
    /// No member session currently binds it.
    case unbound
    /// Git reports the worktree as prunable, or its directory no longer exists.
    case prunable
    /// No binding or creation activity for longer than the requested idle threshold.
    case idle
}

package enum DomainDelegationWorktreeStaleness {
    package static func flags(
        isReleased: Bool,
        boundSessionCount: Int,
        isPrunable: Bool,
        lastActivityAt: Date?,
        idleThresholdDays: Int?,
        now: Date
    ) -> [DomainDelegationWorktreeStaleFlag] {
        var flags: [DomainDelegationWorktreeStaleFlag] = []
        if isReleased { flags.append(.released) }
        if boundSessionCount == 0 { flags.append(.unbound) }
        if isPrunable { flags.append(.prunable) }
        if let idleThresholdDays, let lastActivityAt,
           now.timeIntervalSince(lastActivityAt) > TimeInterval(idleThresholdDays) * 86400
        {
            flags.append(.idle)
        }
        return flags
    }

    /// Worktrees a scope's guardrail counts: every distinct worktree bound by a member, plus every
    /// worktree created under the scope (or a nested scope) that has not been released.
    package static func guardrailCount(boundWorktreeIDs: Set<String>, ownedUnreleasedWorktreeIDs: Set<String>) -> Int {
        boundWorktreeIDs.union(ownedUnreleasedWorktreeIDs).count
    }
}
