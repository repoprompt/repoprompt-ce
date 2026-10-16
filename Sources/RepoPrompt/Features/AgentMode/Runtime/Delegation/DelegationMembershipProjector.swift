import Foundation
import RepoPromptDomainRuntime

/// Persisted placement facts for one session, read from app-owned state only.
///
/// Spawn provenance (`parentSessionID`, `createdByOverseerSessionID`) is immutable; the operation
/// authorizer depends on it. `organizationalParentID` is the mutable, persisted tree placement written
/// only by scope administration (`reparent`, `adopt`, scoped creation); `nil` falls back to spawn
/// provenance.
struct DelegationSessionProvenance: Hashable {
    let sessionID: UUID
    let workspaceID: UUID?
    let parentSessionID: UUID?
    let createdByOverseerSessionID: UUID?
    /// Mutable organizational parent. When set it wins over spawn provenance.
    let organizationalParentID: UUID?
    /// The scope this session was stamped into by scoped creation or `adopt`, if any. Decides whether
    /// a `.workspace` scope's guardrails bound this session's own spawns.
    let delegationScopeID: UUID?
    /// Counts toward `maxLiveSessions`.
    let isLive: Bool
    /// Counts toward `maxWorktrees` when `boundWorktreeIDs` is empty (sources without identities).
    let worktreeCount: Int
    /// Distinct worktrees this session binds. Shared worktrees count once per scope.
    let boundWorktreeIDs: Set<String>
    /// Run state for state-dependent requirements (`retire` of a running target needs `control`).
    let runState: DomainDelegationScopeTargetState

    init(
        sessionID: UUID,
        workspaceID: UUID?,
        parentSessionID: UUID?,
        createdByOverseerSessionID: UUID?,
        organizationalParentID: UUID? = nil,
        delegationScopeID: UUID? = nil,
        isLive: Bool,
        worktreeCount: Int = 0,
        boundWorktreeIDs: Set<String> = [],
        runState: DomainDelegationScopeTargetState = .unknown
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.parentSessionID = parentSessionID
        self.createdByOverseerSessionID = createdByOverseerSessionID
        self.organizationalParentID = organizationalParentID
        self.delegationScopeID = delegationScopeID
        self.isLive = isLive
        self.worktreeCount = worktreeCount
        self.boundWorktreeIDs = boundWorktreeIDs
        self.runState = runState
    }

    /// Tree placement: organizational parent, else spawn parent, else lane creator.
    var effectiveOrganizationalParentID: UUID? {
        organizationalParentID ?? parentSessionID ?? createdByOverseerSessionID
    }
}

/// Placement-only facts cannot accidentally supply liveness or worktree guardrail values.
struct DelegationSessionPlacement {
    let sessionID: UUID
    let workspaceID: UUID?
    let effectiveOrganizationalParentID: UUID?
}

extension DelegationSessionProvenance {
    var placement: DelegationSessionPlacement {
        .init(sessionID: sessionID, workspaceID: workspaceID, effectiveOrganizationalParentID: effectiveOrganizationalParentID)
    }
}

/// Read-only source of session provenance. Never consults tool arguments.
@MainActor
protocol DelegationProvenanceSource {
    func provenance(for sessionID: UUID) -> DelegationSessionProvenance?
    func provenance(for sessionIDs: Set<UUID>) -> [UUID: DelegationSessionProvenance]
    /// Fresh placement only; ancestry checks do not need a live-binding census per ancestor.
    func placement(for sessionID: UUID) -> DelegationSessionPlacement?
    func allKnownSessions() -> [DelegationSessionProvenance]
    /// Carries conflicts separately from accounting; ambiguity is never absence.
    func pointSnapshot(for sessionIDs: Set<UUID>) -> DelegationProvenanceSnapshot
    func resolutionState(for sessionID: UUID) -> DelegationSessionResolutionState
    func censusSnapshot() -> DelegationProvenanceSnapshot
}

extension DelegationProvenanceSource {
    func resolutionState(for sessionID: UUID) -> DelegationSessionResolutionState {
        provenance(for: sessionID) == nil ? .absent : .indexOnly
    }

    func pointSnapshot(for sessionIDs: Set<UUID>) -> DelegationProvenanceSnapshot {
        let records = provenance(for: sessionIDs)
        return .init(records: records, states: records.mapValues { _ in .indexOnly })
    }

    func censusSnapshot() -> DelegationProvenanceSnapshot {
        let records = Dictionary(allKnownSessions().map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        return .init(records: records, states: records.mapValues { _ in .indexOnly })
    }

    func provenance(for sessionIDs: Set<UUID>) -> [UUID: DelegationSessionProvenance] {
        Dictionary(uniqueKeysWithValues: sessionIDs.compactMap { id in
            provenance(for: id).map { (id, $0) }
        })
    }

    func placement(for sessionID: UUID) -> DelegationSessionPlacement? {
        provenance(for: sessionID)?.placement
    }
}

/// Computes scope membership proofs and usage from persisted provenance, for presentation to
/// `DomainDelegationScopeAuthority`. The authority validates proof consistency; this type is the only
/// place that decides which sessions a scope covers.
@MainActor
protocol DelegationMembershipProjector {
    /// One fresh synchronous read region. Its projector must not escape the closure or be retained
    /// across an await/mutation; return derived values only, never an authority cache.
    func withSynchronousCensus<Result>(_ body: (any DelegationMembershipProjector) -> Result) -> Result
    /// Fresh point reads for explicit targets and their ancestry; no global usage projection.
    func withSynchronousTargets<Result>(_ targets: Set<UUID>, _ body: (any DelegationMembershipProjector) -> Result) -> Result
    func membershipProof(
        for targetSessionID: UUID,
        in scope: DomainDelegationScopeGrant
    ) -> DomainDelegationScopeMembershipProof?
    func members(of scope: DomainDelegationScopeGrant) -> [UUID]
    func usage(of scope: DomainDelegationScopeGrant, spawnParentSessionID: UUID?) -> DomainDelegationScopeUsage
    /// App-observed run state; `unknown` (treated as running) when it cannot be established.
    func targetState(for sessionID: UUID) -> DomainDelegationScopeTargetState
    /// Target-first organizational ancestry (truncated where provenance is not loaded), or `nil` when
    /// cyclic or too long.
    func organizationalAncestry(of sessionID: UUID) -> DomainDelegationOrganizationalAncestry?
    /// The session and every organizational descendant this projector knows (root at depth 0), or
    /// `nil` when it cannot be enumerated.
    func organizationalSubtree(of sessionID: UUID) -> [DomainDelegationSubtreeNode]?
    /// The loaded provenance of one session (liveness, bound worktrees, placement), if any.
    func knownProvenance(for sessionID: UUID) -> DelegationSessionProvenance?
    func pointResolutionState(for sessionID: UUID) -> DelegationSessionResolutionState
    func authorityConflictInAncestry(of sessionID: UUID) -> Bool
    /// Capacity decisions consume this optional proof, never an incomplete numeric projection.
    func usageEvidence(of scope: DomainDelegationScopeGrant, spawnParentSessionID: UUID?) -> DomainDelegationScopeUsage?
}

extension DelegationMembershipProjector {
    func pointResolutionState(for sessionID: UUID) -> DelegationSessionResolutionState {
        knownProvenance(for: sessionID) == nil ? .absent : .indexOnly
    }

    func authorityConflictInAncestry(of _: UUID) -> Bool {
        false
    }

    func usageEvidence(of scope: DomainDelegationScopeGrant, spawnParentSessionID: UUID?) -> DomainDelegationScopeUsage? {
        usage(of: scope, spawnParentSessionID: spawnParentSessionID)
    }

    func withSynchronousTargets<Result>(_: Set<UUID>, _ body: (any DelegationMembershipProjector) -> Result) -> Result {
        body(self)
    }

    func withSynchronousCensus<Result>(_ body: (any DelegationMembershipProjector) -> Result) -> Result {
        body(self)
    }

    /// Fails closed for projectors that cannot walk placement: every placement change is refused.
    func organizationalAncestry(of _: UUID) -> DomainDelegationOrganizationalAncestry? {
        nil
    }

    func organizationalSubtree(of _: UUID) -> [DomainDelegationSubtreeNode]? {
        nil
    }

    func knownProvenance(for _: UUID) -> DelegationSessionProvenance? {
        nil
    }
}

/// Membership from spawn provenance, with the organizational-parent seam.
@MainActor
struct SpawnProvenanceDelegationMembershipProjector: DelegationMembershipProjector {
    /// Defensive bound on parent-chain walks; a longer or cyclic chain is not a member.
    static let maxChainLength = 256

    let source: any DelegationProvenanceSource
    /// Worktrees created by any of the given sessions under a scope and not yet released
    /// (`WorktreeOwnershipStore`). Counted toward `maxWorktrees` even while unbound.
    var ownedUnreleasedWorktreeIDs: @MainActor (_ createdBy: Set<UUID>) -> Set<String> = { _ in [] }
    /// Optional operation-count witness; not retained in an authority proof.
    var onAncestryLookup: ((UUID) -> Void)?

    func withSynchronousCensus<Result>(_ body: (any DelegationMembershipProjector) -> Result) -> Result {
        var projector = Self(source: census(), onAncestryLookup: onAncestryLookup)
        projector.ownedUnreleasedWorktreeIDs = ownedUnreleasedWorktreeIDs
        return body(projector)
    }

    func withSynchronousTargets<Result>(_ targets: Set<UUID>, _ body: (any DelegationMembershipProjector) -> Result) -> Result {
        let points = TargetSource(source: source, targets: targets)
        var projector = Self(source: points, onAncestryLookup: onAncestryLookup)
        projector.ownedUnreleasedWorktreeIDs = ownedUnreleasedWorktreeIDs
        return body(projector)
    }

    /// Memoized only for this synchronous call. A later call must reread ownership and liveness.
    private final class TargetSource: DelegationProvenanceSource {
        let source: any DelegationProvenanceSource
        let targets: Set<UUID>
        let snapshot: DelegationProvenanceSnapshot
        var placements: [UUID: DelegationSessionPlacement] = [:]
        var readPlacements: Set<UUID> = []

        init(source: any DelegationProvenanceSource, targets: Set<UUID>) {
            self.source = source
            self.targets = targets
            snapshot = source.pointSnapshot(for: targets)
        }

        func provenance(for sessionID: UUID) -> DelegationSessionProvenance? {
            targets.contains(sessionID) ? snapshot.authorityRecord(for: sessionID) : source.provenance(for: sessionID)
        }

        func placement(for sessionID: UUID) -> DelegationSessionPlacement? {
            if readPlacements.insert(sessionID).inserted {
                placements[sessionID] = targets.contains(sessionID)
                    ? snapshot.authorityRecord(for: sessionID)?.placement : source.placement(for: sessionID)
            }
            return placements[sessionID]
        }

        func allKnownSessions() -> [DelegationSessionProvenance] {
            source.allKnownSessions()
        }

        func pointSnapshot(for ids: Set<UUID>) -> DelegationProvenanceSnapshot {
            if ids.isSubset(of: targets) { return snapshot.restricted(to: ids) }
            return source.pointSnapshot(for: ids)
        }

        func censusSnapshot() -> DelegationProvenanceSnapshot {
            source.censusSnapshot()
        }

        func resolutionState(for id: UUID) -> DelegationSessionResolutionState {
            targets.contains(id) ? snapshot.states[id] ?? .absent : source.resolutionState(for: id)
        }
    }

    private struct CensusSource: DelegationProvenanceSource {
        let snapshot: DelegationProvenanceSnapshot
        let records: [DelegationSessionProvenance]
        let byID: [UUID: DelegationSessionProvenance]
        let ancestry: DomainAgentSessionAncestryIndex

        init(snapshot: DelegationProvenanceSnapshot) {
            self.snapshot = snapshot
            records = Array(snapshot.records.values)
            byID = snapshot.records
            ancestry = DomainAgentSessionAncestryIndex(parents: byID.compactMapValues(\.effectiveOrganizationalParentID))
        }

        func provenance(for sessionID: UUID) -> DelegationSessionProvenance? {
            snapshot.authorityRecord(for: sessionID)
        }

        func allKnownSessions() -> [DelegationSessionProvenance] {
            records
        }

        func pointSnapshot(for ids: Set<UUID>) -> DelegationProvenanceSnapshot {
            snapshot.restricted(to: ids)
        }

        func censusSnapshot() -> DelegationProvenanceSnapshot {
            snapshot
        }

        func resolutionState(for id: UUID) -> DelegationSessionResolutionState {
            snapshot.states[id] ?? .absent
        }
    }

    /// Target-first organizational ancestry over this source. A session with no loaded provenance is
    /// `.unknown` (the chain is truncated there), never mistaken for a root.
    func organizationalAncestry(of sessionID: UUID) -> DomainDelegationOrganizationalAncestry? {
        var conflict = false
        let result = DomainDelegationOrganizationalChain.ancestry(of: sessionID) { id in
            let state = pointResolutionState(for: id)
            if state == .ambiguous || state == .unproven { conflict = true
                return .unknown
            }
            guard let provenance = source.placement(for: id) else { return .unknown }
            return provenance.effectiveOrganizationalParentID.map { .parent($0) } ?? .root
        }
        return conflict ? nil : result
    }

    func knownProvenance(for sessionID: UUID) -> DelegationSessionProvenance? {
        source.provenance(for: sessionID)
    }

    func pointResolutionState(for sessionID: UUID) -> DelegationSessionResolutionState {
        source.resolutionState(for: sessionID)
    }

    func authorityConflictInAncestry(of sessionID: UUID) -> Bool {
        var cursor: UUID? = sessionID
        var seen: Set<UUID> = []
        while let id = cursor, seen.count < Self.maxChainLength, seen.insert(id).inserted {
            let state = pointResolutionState(for: id)
            if state == .ambiguous || state == .unproven { return true }
            cursor = source.placement(for: id)?.effectiveOrganizationalParentID
        }
        return false
    }

    func usageEvidence(of scope: DomainDelegationScopeGrant, spawnParentSessionID: UUID?) -> DomainDelegationScopeUsage? {
        let census = census()
        guard census.snapshot.hasCompletePlacement(for: scope) else { return nil }
        return Self(source: census, ownedUnreleasedWorktreeIDs: ownedUnreleasedWorktreeIDs, onAncestryLookup: onAncestryLookup)
            .usage(of: scope, spawnParentSessionID: spawnParentSessionID)
    }

    func organizationalSubtree(of sessionID: UUID) -> [DomainDelegationSubtreeNode]? {
        let snapshot = source.censusSnapshot()
        guard snapshot.placementConflicts.isEmpty else { return nil }
        var children: [UUID: [UUID]] = [:]
        for session in snapshot.records.values {
            if let parent = session.effectiveOrganizationalParentID {
                children[parent, default: []].append(session.sessionID)
            }
        }
        guard let result = DomainDelegationOrganizationalChain.subtree(of: sessionID, children: { children[$0] ?? [] }),
              result.allSatisfy({ snapshot.states[$0.sessionID] != .ambiguous && snapshot.states[$0.sessionID] != .unproven }) else { return nil }
        return result
    }

    func membershipProof(
        for targetSessionID: UUID,
        in scope: DomainDelegationScopeGrant
    ) -> DomainDelegationScopeMembershipProof? {
        guard pointResolutionState(for: targetSessionID) != .ambiguous,
              let target = source.placement(for: targetSessionID) else { return nil }
        return membershipProof(for: target, in: scope, lookup: { source.placement(for: $0) })
    }

    private func membershipProof(
        for target: DelegationSessionProvenance,
        in scope: DomainDelegationScopeGrant,
        lookup: (UUID) -> DelegationSessionProvenance?
    ) -> DomainDelegationScopeMembershipProof? {
        membershipProof(for: target.placement, in: scope, lookup: { lookup($0)?.placement })
    }

    private func membershipProof(
        for target: DelegationSessionPlacement,
        in scope: DomainDelegationScopeGrant,
        lookup: (UUID) -> DelegationSessionPlacement?
    ) -> DomainDelegationScopeMembershipProof? {
        let targetSessionID = target.sessionID
        switch scope.kind {
        case let .tree(rootSessionID):
            let rootState = pointResolutionState(for: rootSessionID)
            guard rootState != .ambiguous, rootState != .unproven,
                  let path = treePath(from: target, to: rootSessionID, lookup: lookup) else { return nil }
            return DomainDelegationScopeMembershipProof(
                scopeID: scope.id,
                targetSessionID: targetSessionID,
                basis: .treePath(path)
            )
        case let .workspace(workspaceID):
            guard target.workspaceID == workspaceID else { return nil }
            return DomainDelegationScopeMembershipProof(
                scopeID: scope.id,
                targetSessionID: targetSessionID,
                basis: .workspace(workspaceID)
            )
        case .allSessions:
            return DomainDelegationScopeMembershipProof(
                scopeID: scope.id,
                targetSessionID: targetSessionID,
                basis: .allSessions
            )
        }
    }

    func targetState(for sessionID: UUID) -> DomainDelegationScopeTargetState {
        source.provenance(for: sessionID)?.runState ?? .unknown
    }

    private func census() -> CensusSource {
        (source as? CensusSource) ?? CensusSource(snapshot: source.censusSnapshot())
    }

    private func contains(_ record: DelegationSessionProvenance, in scope: DomainDelegationScopeGrant, census: CensusSource) -> Bool {
        switch scope.kind {
        case .allSessions: true
        case let .workspace(id): record.workspaceID == id
        case let .tree(root):
            census.ancestry.distance(from: record.sessionID, to: root, onLookup: onAncestryLookup).map { $0 < Self.maxChainLength } ?? false
        }
    }

    func members(of scope: DomainDelegationScopeGrant) -> [UUID] {
        let census = census()
        return census.records.filter { contains($0, in: scope, census: census) }.map(\.sessionID)
    }

    func usage(of scope: DomainDelegationScopeGrant, spawnParentSessionID: UUID?) -> DomainDelegationScopeUsage {
        // Census and placement lookup are local immutable values. No source callback or suspension
        // can substitute a later census halfway through this guardrail computation.
        let census = census()
        let members = census.records.filter { contains($0, in: scope, census: census) }
        let memberIDs = Set(members.map(\.sessionID))
        let parentDepth: Int? = if case let .tree(root) = scope.kind, let parent = spawnParentSessionID,
                                   census.byID[parent] != nil, let distance = census.ancestry.distance(from: parent, to: root, onLookup: onAncestryLookup),
                                   distance < Self.maxChainLength
        {
            distance
        } else {
            nil
        }
        let identities = members.reduce(into: Set<String>()) { $0.formUnion($1.boundWorktreeIDs) }
            .union(ownedUnreleasedWorktreeIDs(memberIDs))
        let distinct = identities.count
        let anonymous = members.filter(\.boundWorktreeIDs.isEmpty).reduce(0) { $0 + $1.worktreeCount }
        return DomainDelegationScopeUsage(
            scopeID: scope.id,
            liveSessionCount: members.filter(\.isLive).count,
            worktreeCount: distinct + anonymous,
            spawnParentDepth: parentDepth,
            countedWorktreeIDs: identities
        )
    }

    /// Target-first chain ending at `rootSessionID`, or `nil` when the chain never reaches it.
    private func treePath(
        from target: DelegationSessionPlacement,
        to rootSessionID: UUID,
        lookup: (UUID) -> DelegationSessionPlacement?
    ) -> [UUID]? {
        var path = [target.sessionID]
        var seen: Set<UUID> = [target.sessionID]
        var cursor = target
        while cursor.sessionID != rootSessionID {
            guard path.count < Self.maxChainLength,
                  let parentID = cursor.effectiveOrganizationalParentID,
                  seen.insert(parentID).inserted
            else { return nil }
            let parentState = pointResolutionState(for: parentID)
            guard parentState != .ambiguous, parentState != .unproven else { return nil }
            path.append(parentID)
            if parentID == rootSessionID { break }
            guard let parent = lookup(parentID) else { return nil }
            cursor = parent
        }
        return path
    }
}

/// Display names for delegation cards and the "Active delegations" list. Presentation only.
@MainActor
enum DelegationDisplayNames {
    static func sessionTitle(_ sessionID: UUID) -> String? {
        for window in WindowStatesManager.shared.allWindows {
            if let name = window.agentModeViewModel.sessionIndex[sessionID]?.name, !name.isEmpty { return name }
        }
        return nil
    }

    static func workspaceName(_ workspaceID: UUID) -> String? {
        for window in WindowStatesManager.shared.allWindows {
            if let workspace = window.workspaceManager.workspaces.first(where: { $0.id == workspaceID }) {
                return workspace.name
            }
        }
        return nil
    }
}
