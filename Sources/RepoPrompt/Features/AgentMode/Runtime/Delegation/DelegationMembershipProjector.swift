import Foundation
import RepoPromptDomainRuntime

/// Persisted placement facts for one session, read from app-owned state only.
///
/// Spawn provenance (`parentSessionID`, `createdByOverseerSessionID`) is immutable; the operation
/// authorizer depends on it. `organizationalParentID` is the mutable tree placement Lane C adds for
/// re-parenting; until then it is always `nil` and placement falls back to spawn provenance.
struct DelegationSessionProvenance: Hashable {
    let sessionID: UUID
    let workspaceID: UUID?
    let parentSessionID: UUID?
    let createdByOverseerSessionID: UUID?
    /// Seam for Lane C's mutable organizational parent. When set it wins over spawn provenance.
    let organizationalParentID: UUID?
    /// Counts toward `maxLiveSessions`.
    let isLive: Bool
    /// Counts toward `maxWorktrees`.
    let worktreeCount: Int
    /// Run state for state-dependent requirements (`retire` of a running target needs `control`).
    let runState: DomainDelegationScopeTargetState

    init(
        sessionID: UUID,
        workspaceID: UUID?,
        parentSessionID: UUID?,
        createdByOverseerSessionID: UUID?,
        organizationalParentID: UUID? = nil,
        isLive: Bool,
        worktreeCount: Int = 0,
        runState: DomainDelegationScopeTargetState = .unknown
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.parentSessionID = parentSessionID
        self.createdByOverseerSessionID = createdByOverseerSessionID
        self.organizationalParentID = organizationalParentID
        self.isLive = isLive
        self.worktreeCount = worktreeCount
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
    /// Fresh placement only; ancestry checks do not need a live-binding census per ancestor.
    func placement(for sessionID: UUID) -> DelegationSessionPlacement?
    func allKnownSessions() -> [DelegationSessionProvenance]
}

extension DelegationProvenanceSource {
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
    func membershipProof(
        for targetSessionID: UUID,
        in scope: DomainDelegationScopeGrant
    ) -> DomainDelegationScopeMembershipProof?
    func members(of scope: DomainDelegationScopeGrant) -> [UUID]
    func usage(of scope: DomainDelegationScopeGrant, spawnParentSessionID: UUID?) -> DomainDelegationScopeUsage
    /// App-observed run state; `unknown` (treated as running) when it cannot be established.
    func targetState(for sessionID: UUID) -> DomainDelegationScopeTargetState
}

extension DelegationMembershipProjector {
    func withSynchronousCensus<Result>(_ body: (any DelegationMembershipProjector) -> Result) -> Result {
        body(self)
    }
}

/// Membership from spawn provenance, with the organizational-parent seam.
@MainActor
struct SpawnProvenanceDelegationMembershipProjector: DelegationMembershipProjector {
    /// Defensive bound on parent-chain walks; a longer or cyclic chain is not a member.
    static let maxChainLength = 256

    let source: any DelegationProvenanceSource
    /// Optional operation-count witness; not retained in an authority proof.
    var onAncestryLookup: ((UUID) -> Void)?
    func withSynchronousCensus<Result>(_ body: (any DelegationMembershipProjector) -> Result) -> Result {
        let projector = Self(source: census(), onAncestryLookup: onAncestryLookup)
        return body(projector)
    }

    private struct CensusSource: DelegationProvenanceSource {
        let records: [DelegationSessionProvenance]
        let byID: [UUID: DelegationSessionProvenance]
        let ancestry: DomainAgentSessionAncestryIndex

        init(records: [DelegationSessionProvenance]) {
            self.records = records
            byID = Dictionary(records.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
            ancestry = DomainAgentSessionAncestryIndex(parents: byID.compactMapValues(\.effectiveOrganizationalParentID))
        }

        func provenance(for sessionID: UUID) -> DelegationSessionProvenance? {
            byID[sessionID]
        }

        func allKnownSessions() -> [DelegationSessionProvenance] {
            records
        }
    }

    func membershipProof(
        for targetSessionID: UUID,
        in scope: DomainDelegationScopeGrant
    ) -> DomainDelegationScopeMembershipProof? {
        guard let target = source.placement(for: targetSessionID) else { return nil }
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
            guard let path = treePath(from: target, to: rootSessionID, lookup: lookup) else { return nil }
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
        (source as? CensusSource) ?? CensusSource(records: source.allKnownSessions())
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
        let parentDepth: Int? = if case let .tree(root) = scope.kind, let parent = spawnParentSessionID,
                                   census.byID[parent] != nil, let distance = census.ancestry.distance(from: parent, to: root, onLookup: onAncestryLookup),
                                   distance < Self.maxChainLength
        {
            distance
        } else {
            nil
        }
        return DomainDelegationScopeUsage(
            scopeID: scope.id,
            liveSessionCount: members.filter(\.isLive).count,
            worktreeCount: members.reduce(0) { $0 + $1.worktreeCount },
            spawnParentDepth: parentDepth
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
            path.append(parentID)
            if parentID == rootSessionID { break }
            guard let parent = lookup(parentID) else { return nil }
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
    private let windows: @MainActor () -> [WindowState]

    init(windows: @escaping @MainActor () -> [WindowState] = { WindowStatesManager.shared.allWindows }) {
        self.windows = windows
    }

    func placement(for sessionID: UUID) -> DelegationSessionPlacement? {
        // Identical first owning index and fresh owner fence to the full provenance read, without
        // resolving liveness. This value is used only synchronously, never retained across an await.
        for window in windows() {
            let store = window.agentModeViewModel.sessionIndexStore
            guard let entry = store.ownerValidatedSessionIndex[sessionID] else { continue }
            return .init(
                sessionID: entry.id,
                workspaceID: store.sessionIndexOwner?.workspaceID,
                effectiveOrganizationalParentID: entry.parentSessionID ?? entry.createdByOverseerSessionID
            )
        }
        return nil
    }

    func provenance(for sessionID: UUID) -> DelegationSessionProvenance? {
        // The entry's workspace is the workspace that owns the index it came from, never the
        // window's currently active workspace; only owner-validated (current) indexes are read.
        let windows = windows()
        for window in windows {
            let store = window.agentModeViewModel.sessionIndexStore
            guard let entry = store.ownerValidatedSessionIndex[sessionID] else { continue }
            return Self.provenance(
                entry: entry, workspaceID: store.sessionIndexOwner?.workspaceID,
                liveness: Self.liveness(of: sessionID, windows: windows)
            )
        }
        return nil
    }

    func allKnownSessions() -> [DelegationSessionProvenance] {
        var seen: Set<UUID> = []
        var entries: [(AgentSessionIndexEntry, UUID?)] = []
        let windows = windows()
        for window in windows {
            let store = window.agentModeViewModel.sessionIndexStore
            let workspaceID = store.sessionIndexOwner?.workspaceID
            for entry in store.ownerValidatedSessionIndex.values where seen.insert(entry.id).inserted {
                entries.append((entry, workspaceID))
            }
        }
        let sessionIDs = Set(entries.map(\.0.id))
        let statesByWindow = windows.map { $0.agentModeViewModel.authoritativeLiveSessionStates(for: sessionIDs) }
        return entries.map { entry, workspaceID in
            Self.provenance(
                entry: entry, workspaceID: workspaceID,
                liveness: Self.liveness(states: statesByWindow.compactMap { $0[entry.id] })
            )
        }
    }

    private static func provenance(
        entry: AgentSessionIndexEntry,
        workspaceID: UUID?,
        liveness: (isLive: Bool, runState: DomainDelegationScopeTargetState)
    ) -> DelegationSessionProvenance {
        let (isLive, runState) = liveness
        return DelegationSessionProvenance(
            sessionID: entry.id,
            workspaceID: workspaceID,
            parentSessionID: entry.parentSessionID,
            createdByOverseerSessionID: entry.createdByOverseerSessionID,
            isLive: isLive,
            worktreeCount: entry.worktreeBindingSummaries.count,
            runState: runState
        )
    }

    /// Aggregated across every window, because one session can be live in more than one. Both facts
    /// fail closed: running if any window runs it; otherwise unknown (treated as running) if any
    /// lookup throws; a lookup failure also counts as live, so `maxLiveSessions` only gets stricter.
    private static func liveness(of sessionID: UUID, windows: [WindowState]) -> (isLive: Bool, runState: DomainDelegationScopeTargetState) {
        liveness(states: windows.flatMap { $0.agentModeViewModel.authoritativeLiveSessionStates(for: [sessionID]).values })
    }

    private static func liveness(states: [AgentModeViewModel.AuthoritativeLiveSessionState]) -> (isLive: Bool, runState: DomainDelegationScopeTargetState) {
        var isLive = false
        var running = false
        var unknown = false
        for state in states {
            switch state {
            case .running:
                isLive = true
                running = true
            case .idle:
                isLive = true
            case .notFound:
                break
            case .ambiguous:
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
