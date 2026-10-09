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
    /// Defensive bound on subtree walks (`adopt` card items, depth checks).
    package static let maxSubtreeSize = 1024

    /// Target-first organizational ancestry (`[session, parent, grandparent, …]`) following
    /// `parent`, or `nil` when the walk revisits a session or exceeds `maxLength`.
    ///
    /// A session whose provenance is not loaded is `.unknown`, which is different from `.root`: the
    /// walk stops there and marks the chain truncated, because a live scope may be rooted above it.
    package static func ancestry(
        of sessionID: UUID,
        parent: (UUID) -> DomainDelegationOrganizationalParent
    ) -> DomainDelegationOrganizationalAncestry? {
        var chain = [sessionID]
        var seen: Set<UUID> = [sessionID]
        var cursor = sessionID
        while true {
            switch parent(cursor) {
            case .root:
                return DomainDelegationOrganizationalAncestry(chain: chain, isTruncated: false)
            case .unknown:
                return DomainDelegationOrganizationalAncestry(chain: chain, isTruncated: true)
            case let .parent(next):
                guard chain.count < maxLength, seen.insert(next).inserted else { return nil }
                chain.append(next)
                cursor = next
            }
        }
    }

    /// Breadth-first organizational subtree of `rootSessionID` (the root at depth 0), or `nil` when it
    /// exceeds `maxSubtreeSize` or revisits a session.
    package static func subtree(
        of rootSessionID: UUID,
        children: (UUID) -> [UUID]
    ) -> [DomainDelegationSubtreeNode]? {
        var nodes = [DomainDelegationSubtreeNode(sessionID: rootSessionID, depth: 0)]
        var seen: Set<UUID> = [rootSessionID]
        var index = 0
        while index < nodes.count {
            let node = nodes[index]
            index += 1
            for child in children(node.sessionID).sorted(by: { $0.uuidString < $1.uuidString }) {
                guard seen.insert(child).inserted, nodes.count < maxSubtreeSize else { return nil }
                nodes.append(DomainDelegationSubtreeNode(sessionID: child, depth: node.depth + 1))
            }
        }
        return nodes
    }
}

/// One step of an organizational walk.
package enum DomainDelegationOrganizationalParent: Hashable, Sendable {
    /// The session is known and has no parent.
    case root
    case parent(UUID)
    /// The session's provenance is not loaded (closed workspace, unloaded session).
    case unknown
}

/// Target-first organizational ancestry. When `isTruncated`, the last element's own parent is
/// unknown, so nothing is known about the chain above it.
package struct DomainDelegationOrganizationalAncestry: Hashable, Sendable {
    package let chain: [UUID]
    package let isTruncated: Bool

    package init(chain: [UUID], isTruncated: Bool) {
        self.chain = chain
        self.isTruncated = isTruncated
    }
}

package struct DomainDelegationSubtreeNode: Hashable, Sendable {
    package let sessionID: UUID
    /// Depth below the subtree root (root = 0).
    package let depth: Int

    package init(sessionID: UUID, depth: Int) {
        self.sessionID = sessionID
        self.depth = depth
    }
}

/// A `.tree` scope's `maxDepth`, for placement depth checks.
package struct DomainDelegationTreeDepthLimit: Hashable, Sendable {
    package let rootSessionID: UUID
    package let maxDepth: Int

    package init(rootSessionID: UUID, maxDepth: Int) {
        self.rootSessionID = rootSessionID
        self.maxDepth = maxDepth
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
    /// The destination is the moved session or one of its organizational descendants, or a chain
    /// revisits a session.
    case cycle
    /// A chain runs into a session whose provenance is not loaded and the two chains do not share
    /// that unknown tail, so the membership change cannot be decided.
    case unresolved
    /// The move would change the membership (join *or* leave) of this many live scopes, none of which
    /// is on the caller's own scope chain. Only a count is disclosed, never other scopes' IDs.
    case affectsOtherScopes(count: Int)
    /// `adopt` under an attenuated (nested) scope would enlarge an ancestor scope without that being
    /// shown on the user's card. Refused in Milestone 1.
    case adoptionRequiresUserGrantedScope
    /// The adoptee (or a session in its subtree) is the grantee or root of a live scope; adopting it
    /// would put another overseer under this scope.
    case adopteeAnchorsScope

    package var publicCode: String {
        switch self {
        case .cycle: "placement_cycle"
        case .unresolved: "placement_unresolved"
        case .affectsOtherScopes: "placement_affects_other_scopes"
        case .adoptionRequiresUserGrantedScope: "adopt_requires_user_granted_scope"
        case .adopteeAnchorsScope: "adopt_target_anchors_scope"
        }
    }

    package var affectedScopeCount: Int? {
        guard case let .affectsOtherScopes(count) = self else { return nil }
        return count
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
    /// Live tree scopes whose membership the move changes, sorted by UUID string, or `nil` when it
    /// cannot be decided.
    ///
    /// Truncated chains are comparable only when both stop at the same unknown session: everything
    /// above that tail is then identical on both sides and cannot change. Any other truncation is
    /// unresolved, because a live scope could be rooted in the unknown part of one chain only.
    package static func affectedTreeScopes(
        movedSessionID: UUID,
        previousAncestry: DomainDelegationOrganizationalAncestry,
        destinationAncestry: DomainDelegationOrganizationalAncestry,
        liveTreeScopes: [DomainDelegationTreeScopeRoot]
    ) -> [UUID]? {
        switch (previousAncestry.isTruncated, destinationAncestry.isTruncated) {
        case (false, false):
            break
        case (true, true) where previousAncestry.chain.last == destinationAncestry.chain.last:
            break
        default:
            return nil
        }
        let previous = Set(previousAncestry.chain)
        let next = Set([movedSessionID] + destinationAncestry.chain)
        let changedRoots = previous.symmetricDifference(next)
        return liveTreeScopes
            .filter { changedRoots.contains($0.rootSessionID) }
            .map(\.scopeID)
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// `maxLiveSessions` / `maxWorktrees` after an adoption adds `addedLiveSessions` live sessions and
    /// `addedWorktrees` worktrees (the adoptees and their subtrees) to a scope whose current usage
    /// (including in-flight reservations) is `usage`. `current` in a denial is the pre-adopt count.
    package static func adoptionGuardrailViolation(
        guardrails: DomainDelegationScopeGuardrails,
        usage: DomainDelegationScopeUsage,
        addedLiveSessions: Int,
        addedWorktrees: Int
    ) -> DomainDelegationScopeDenial? {
        if let limit = guardrails.maxLiveSessions, usage.liveSessionCount + addedLiveSessions > limit {
            return .guardrailExceeded(guardrail: .maxLiveSessions, limit: limit, current: usage.liveSessionCount)
        }
        if let limit = guardrails.maxWorktrees, usage.worktreeCount + addedWorktrees > limit {
            return .guardrailExceeded(guardrail: .maxWorktrees, limit: limit, current: usage.worktreeCount)
        }
        return nil
    }

    /// `maxDepth` after moving a subtree of height `movedSubtreeHeight` under the destination, for
    /// each tree scope (on the destination's chain) that sets one.
    package static func depthViolation(
        destinationAncestry: DomainDelegationOrganizationalAncestry,
        movedSubtreeHeight: Int,
        limits: [DomainDelegationTreeDepthLimit]
    ) -> DomainDelegationScopeDenial? {
        for limit in limits {
            guard let destinationDepth = destinationAncestry.chain.firstIndex(of: limit.rootSessionID) else { continue }
            let deepest = destinationDepth + 1 + movedSubtreeHeight
            if deepest > limit.maxDepth {
                return .guardrailExceeded(guardrail: .maxDepth, limit: limit.maxDepth, current: deepest)
            }
        }
        return nil
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
        sourceAncestry: DomainDelegationOrganizationalAncestry?,
        destinationAncestry: DomainDelegationOrganizationalAncestry?,
        liveTreeScopes: [DomainDelegationTreeScopeRoot],
        callerScopeChain: Set<UUID>
    ) -> DomainDelegationScopePlacementDenial? {
        guard source != destination,
              let sourceAncestry,
              let destinationAncestry,
              !destinationAncestry.chain.contains(source)
        else { return .cycle }
        guard let affected = affectedTreeScopes(
            movedSessionID: source,
            previousAncestry: sourceAncestry,
            destinationAncestry: destinationAncestry,
            liveTreeScopes: liveTreeScopes
        ) else { return .unresolved }
        let foreign = affected.filter { !callerScopeChain.contains($0) }
        return foreign.isEmpty ? nil : .affectsOtherScopes(count: foreign.count)
    }

    /// `adopt`: the adoptee is outside the caller's scope; the destination was proven a member.
    ///
    /// Only a user-granted (non-attenuated) scope may adopt, so the only scope the adoptee joins on
    /// purpose is the one the user's card names. Any other membership change is refused.
    ///
    /// - Parameters:
    ///   - adopteeSubtree: the adoptee and every organizational descendant (they move with it), or
    ///     `nil` when the subtree could not be enumerated.
    ///   - scopeAnchors: the grantee and root session of every live scope.
    package static func validateAdopt(
        adoptee: UUID,
        destination: UUID,
        adopteeAncestry: DomainDelegationOrganizationalAncestry?,
        destinationAncestry: DomainDelegationOrganizationalAncestry?,
        adopteeSubtree: Set<UUID>?,
        scopeAnchors: Set<UUID>,
        liveTreeScopes: [DomainDelegationTreeScopeRoot],
        callerScope: DomainDelegationScopeGrant
    ) -> DomainDelegationScopePlacementDenial? {
        guard callerScope.parentScopeID == nil else { return .adoptionRequiresUserGrantedScope }
        guard let adopteeSubtree else { return .unresolved }
        guard adopteeSubtree.union([adoptee]).isDisjoint(with: scopeAnchors) else { return .adopteeAnchorsScope }
        guard adoptee != destination,
              let adopteeAncestry,
              let destinationAncestry,
              !destinationAncestry.chain.contains(adoptee)
        else { return .cycle }
        guard let affected = affectedTreeScopes(
            movedSessionID: adoptee,
            previousAncestry: adopteeAncestry,
            destinationAncestry: destinationAncestry,
            liveTreeScopes: liveTreeScopes
        ) else { return .unresolved }
        let foreign = affected.filter { $0 != callerScope.id }
        return foreign.isEmpty ? nil : .affectsOtherScopes(count: foreign.count)
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
        // A worktree bound again (by any session) is in use, whatever an earlier release recorded.
        if isReleased, boundSessionCount == 0 { flags.append(.released) }
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
