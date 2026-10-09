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

/// Read-only source of session provenance. Never consults tool arguments.
@MainActor
protocol DelegationProvenanceSource {
    func provenance(for sessionID: UUID) -> DelegationSessionProvenance?
    func allKnownSessions() -> [DelegationSessionProvenance]
}

/// Computes scope membership proofs and usage from persisted provenance, for presentation to
/// `DomainDelegationScopeAuthority`. The authority validates proof consistency; this type is the only
/// place that decides which sessions a scope covers.
@MainActor
protocol DelegationMembershipProjector {
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
}

extension DelegationMembershipProjector {
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

    /// Target-first organizational ancestry over this source. A session with no loaded provenance is
    /// `.unknown` (the chain is truncated there), never mistaken for a root.
    func organizationalAncestry(of sessionID: UUID) -> DomainDelegationOrganizationalAncestry? {
        DomainDelegationOrganizationalChain.ancestry(of: sessionID) { id in
            guard let provenance = source.provenance(for: id) else { return .unknown }
            return provenance.effectiveOrganizationalParentID.map { .parent($0) } ?? .root
        }
    }

    func knownProvenance(for sessionID: UUID) -> DelegationSessionProvenance? {
        source.provenance(for: sessionID)
    }

    func organizationalSubtree(of sessionID: UUID) -> [DomainDelegationSubtreeNode]? {
        var children: [UUID: [UUID]] = [:]
        for session in source.allKnownSessions() {
            if let parent = session.effectiveOrganizationalParentID {
                children[parent, default: []].append(session.sessionID)
            }
        }
        return DomainDelegationOrganizationalChain.subtree(of: sessionID) { children[$0] ?? [] }
    }

    func membershipProof(
        for targetSessionID: UUID,
        in scope: DomainDelegationScopeGrant
    ) -> DomainDelegationScopeMembershipProof? {
        guard let target = source.provenance(for: targetSessionID) else { return nil }
        switch scope.kind {
        case let .tree(rootSessionID):
            guard let path = treePath(from: target, to: rootSessionID) else { return nil }
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

    func members(of scope: DomainDelegationScopeGrant) -> [UUID] {
        source.allKnownSessions()
            .filter { membershipProof(for: $0.sessionID, in: scope) != nil }
            .map(\.sessionID)
    }

    func usage(of scope: DomainDelegationScopeGrant, spawnParentSessionID: UUID?) -> DomainDelegationScopeUsage {
        let memberIDs = Set(members(of: scope))
        let members = source.allKnownSessions().filter { memberIDs.contains($0.sessionID) }
        let parentDepth = spawnParentSessionID
            .flatMap { membershipProof(for: $0, in: scope) }?
            .treeDepth
        let distinct = DomainDelegationWorktreeStaleness.guardrailCount(
            boundWorktreeIDs: members.reduce(into: Set<String>()) { $0.formUnion($1.boundWorktreeIDs) },
            ownedUnreleasedWorktreeIDs: ownedUnreleasedWorktreeIDs(memberIDs)
        )
        let anonymous = members.filter(\.boundWorktreeIDs.isEmpty).reduce(0) { $0 + $1.worktreeCount }
        return DomainDelegationScopeUsage(
            scopeID: scope.id,
            liveSessionCount: members.filter(\.isLive).count,
            worktreeCount: distinct + anonymous,
            spawnParentDepth: parentDepth
        )
    }

    /// Target-first chain ending at `rootSessionID`, or `nil` when the chain never reaches it.
    private func treePath(from target: DelegationSessionProvenance, to rootSessionID: UUID) -> [UUID]? {
        var path = [target.sessionID]
        var seen: Set<UUID> = [target.sessionID]
        var cursor = target
        while cursor.sessionID != rootSessionID {
            guard path.count < Self.maxChainLength,
                  let parentID = cursor.effectiveOrganizationalParentID,
                  seen.insert(parentID).inserted
            else { return nil }
            path.append(parentID)
            if parentID == rootSessionID { break }
            guard let parent = source.provenance(for: parentID) else { return nil }
            cursor = parent
        }
        return path
    }
}

/// Production provenance over every open window's loaded workspace session index.
///
/// Mutations target loaded workspaces only (design §3.1), so unloaded workspaces contribute no
/// members here; history-wide inventory is Lane B's concern.
@MainActor
struct OpenWindowsDelegationProvenanceSource: DelegationProvenanceSource {
    func provenance(for sessionID: UUID) -> DelegationSessionProvenance? {
        // The entry's workspace is the workspace that owns the index it came from, never the
        // window's currently active workspace; only owner-validated (current) indexes are read.
        for window in WindowStatesManager.shared.allWindows {
            let store = window.agentModeViewModel.sessionIndexStore
            guard let entry = store.ownerValidatedSessionIndex[sessionID] else { continue }
            return Self.provenance(entry: entry, workspaceID: store.sessionIndexOwner?.workspaceID)
        }
        return nil
    }

    func allKnownSessions() -> [DelegationSessionProvenance] {
        var seen: Set<UUID> = []
        var result: [DelegationSessionProvenance] = []
        for window in WindowStatesManager.shared.allWindows {
            let store = window.agentModeViewModel.sessionIndexStore
            let workspaceID = store.sessionIndexOwner?.workspaceID
            for entry in store.ownerValidatedSessionIndex.values where seen.insert(entry.id).inserted {
                result.append(Self.provenance(entry: entry, workspaceID: workspaceID))
            }
        }
        return result
    }

    private static func provenance(entry: AgentSessionIndexEntry, workspaceID: UUID?) -> DelegationSessionProvenance {
        let (isLive, runState) = liveness(of: entry.id)
        return DelegationSessionProvenance(
            sessionID: entry.id,
            workspaceID: workspaceID,
            parentSessionID: entry.parentSessionID,
            createdByOverseerSessionID: entry.createdByOverseerSessionID,
            organizationalParentID: entry.organizationalParentID,
            delegationScopeID: entry.delegationScopeID,
            isLive: isLive,
            worktreeCount: entry.worktreeBindingSummaries.count,
            boundWorktreeIDs: Set(entry.worktreeBindingSummaries.map(\.worktreeID)),
            runState: runState
        )
    }

    /// Aggregated across every window, because one session can be live in more than one. Both facts
    /// fail closed: running if any window runs it; otherwise unknown (treated as running) if any
    /// lookup throws; a lookup failure also counts as live, so `maxLiveSessions` only gets stricter.
    private static func liveness(of sessionID: UUID) -> (isLive: Bool, runState: DomainDelegationScopeTargetState) {
        var isLive = false
        var running = false
        var unknown = false
        for window in WindowStatesManager.shared.allWindows {
            switch Result(catching: { try window.agentModeViewModel.authoritativeLiveSession(for: sessionID) }) {
            case let .success(session?):
                isLive = true
                running = running || session.runState.isActive
            case .success(nil):
                break
            case .failure:
                isLive = true
                unknown = true
            }
        }
        return (isLive, running ? .running : unknown ? .unknown : .idle)
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
