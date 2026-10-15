import Foundation
import RepoPromptDomainRuntime

/// Identity ambiguity is neither missing history nor runtime uncertainty.
enum DelegationSessionResolutionState: Equatable {
    case absent
    case indexOnly
    /// A physical/live claim exists, but its owner has no placement metadata to prove authority.
    case unproven
    case unique
    /// One logical carrier has agreeing window replicas but no proven canonical mutation owner.
    case replicated
    case ambiguous
}

/// Accounting retains every known identity, including those that cannot authorize a mutation.
struct DelegationProvenanceSnapshot {
    var records: [UUID: DelegationSessionProvenance]
    var states: [UUID: DelegationSessionResolutionState]
    var placementConflicts: [UUID: Set<UUID>] = [:]

    func authorityRecord(for id: UUID) -> DelegationSessionProvenance? {
        guard let state = states[id], state != .absent, state != .ambiguous, state != .unproven else { return nil }
        return records[id]
    }

    func restricted(to ids: Set<UUID>) -> Self {
        .init(
            records: records.filter { ids.contains($0.key) },
            states: states.filter { ids.contains($0.key) },
            placementConflicts: placementConflicts.filter { ids.contains($0.key) }
        )
    }

    func hasCompletePlacement(for scope: DomainDelegationScopeGrant) -> Bool {
        switch scope.kind {
        case let .session(target):
            placementConflicts[target] == nil && placementConflicts[scope.granteeSessionID] == nil
        case let .workspace(workspaceID):
            !placementConflicts.values.contains { $0.isEmpty || $0.contains(workspaceID) }
        case .tree, .allSessions:
            // A disputed ancestor could hide descendants from a tree census. Never count its
            // absence as free capacity; resolving that disagreement belongs to its real owner.
            placementConflicts.isEmpty
        }
    }
}

/// Current owner-valid metadata and physical carrier evidence are joined in one synchronous read.
/// Runtime reduction is for accounting only; it cannot make an ambiguous identity actionable.
@MainActor
struct OpenWindowsDelegationProvenanceSource: DelegationProvenanceSource {
    private let windows: @MainActor () -> [WindowState]

    init(windows: @escaping @MainActor () -> [WindowState] = { WindowStatesManager.shared.sessionRuntimeWindows }) {
        self.windows = windows
    }

    func placement(for sessionID: UUID) -> DelegationSessionPlacement? {
        capture(sessionIDs: [sessionID], includeRuntime: false).authorityRecord(for: sessionID)?.placement
    }

    func resolutionState(for sessionID: UUID) -> DelegationSessionResolutionState {
        capture(sessionIDs: [sessionID], includeRuntime: false).states[sessionID] ?? .absent
    }

    func provenance(for sessionID: UUID) -> DelegationSessionProvenance? {
        pointSnapshot(for: [sessionID]).authorityRecord(for: sessionID)
    }

    func provenance(for sessionIDs: Set<UUID>) -> [UUID: DelegationSessionProvenance] {
        let snapshot = pointSnapshot(for: sessionIDs)
        return snapshot.records.filter { snapshot.authorityRecord(for: $0.key) != nil }
    }

    func pointSnapshot(for sessionIDs: Set<UUID>) -> DelegationProvenanceSnapshot {
        capture(sessionIDs: sessionIDs, includeRuntime: true)
    }

    func censusSnapshot() -> DelegationProvenanceSnapshot {
        capture(sessionIDs: nil, includeRuntime: true)
    }

    func allKnownSessions() -> [DelegationSessionProvenance] {
        Array(censusSnapshot().records.values)
    }

    private func capture(sessionIDs: Set<UUID>?, includeRuntime: Bool) -> DelegationProvenanceSnapshot {
        let windows = windows().filter { !$0.isClosing }
        let carriers = AgentSessionCarrierResolver.capture(windows: windows, sessionIDs: sessionIDs)
        let ids = sessionIDs ?? carriers.sessionIDs
        let runtime = includeRuntime ? windows.map { $0.agentModeViewModel.authoritativeLiveSessionStates(for: ids) } : []
        var result = DelegationProvenanceSnapshot(records: [:], states: [:])
        for id in ids {
            let metadata = carriers.metadata[id] ?? []
            let agreed = metadata.first
            let placementConflict = carriers.placementConflictSessionIDs.contains(id)
            let missingPlacement = metadata.isEmpty && carriers.sessionIDs.contains(id)
            let observed = runtime.compactMap { $0[id] }
            let ambiguous = carriers.ambiguousSessionIDs.contains(id) || observed.contains(.ambiguous)
            result.states[id] = ambiguous ? .ambiguous : missingPlacement ? .unproven
                : carriers.replicatedSessionIDs.contains(id) ? .replicated
                : carriers.uniqueLocations[id] != nil ? .unique : metadata.isEmpty ? .absent : .indexOnly
            if placementConflict || missingPlacement {
                result.placementConflicts[id] = carriers.affectedWorkspaceIDs(for: id)
            }
            guard !metadata.isEmpty else { continue }
            let boundWorktrees = metadata.reduce(into: Set<String>()) { ids, row in
                ids.formUnion(row.entry.worktreeBindingSummaries.map(\.worktreeID))
            }
            let isLive = ambiguous || observed.contains(.idle) || observed.contains(.running)
            let runState: DomainDelegationScopeTargetState = observed.contains(.running) ? .running : ambiguous ? .unknown : .idle
            result.records[id] = DelegationSessionProvenance(
                sessionID: id, workspaceID: placementConflict ? nil : agreed?.workspaceID,
                parentSessionID: placementConflict ? nil : agreed?.entry.parentSessionID,
                createdByOverseerSessionID: placementConflict ? nil : agreed?.entry.createdByOverseerSessionID,
                organizationalParentID: placementConflict ? nil : agreed?.entry.organizationalParentID,
                delegationScopeID: placementConflict ? nil : agreed?.entry.delegationScopeID,
                isLive: isLive, worktreeCount: boundWorktrees.count, boundWorktreeIDs: boundWorktrees, runState: runState
            )
        }
        return result
    }
}
