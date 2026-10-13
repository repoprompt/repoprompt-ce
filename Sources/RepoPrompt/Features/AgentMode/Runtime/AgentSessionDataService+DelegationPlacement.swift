import Foundation

extension AgentSessionDataService {
    /// Rewrites only organizational placement for a session that has no live tab, mirroring
    /// `renameAgentSession`. Spawn provenance (`parentSessionID`, `createdByOverseerSessionID`) is
    /// never touched.
    ///
    /// Missing storage is a failed commit, never a successful no-op.
    func updateDelegationPlacement(
        id: UUID,
        organizationalParentID: UUID?,
        delegationScopeID: UUID?,
        for workspace: WorkspaceModel
    ) async throws {
        guard var session = try await loadAgentSession(id: id, for: workspace) else {
            throw DelegationPlacementPersistenceError.sessionFileMissing
        }
        guard session.organizationalParentID != organizationalParentID
            || session.delegationScopeID != delegationScopeID
        else { return }
        session.organizationalParentID = organizationalParentID
        session.delegationScopeID = delegationScopeID
        _ = try await saveAgentSession(session, for: workspace)
    }
}
