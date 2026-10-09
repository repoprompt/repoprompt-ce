import Foundation

extension AgentSessionDataService {
    /// Rewrites only organizational placement for a session that has no live tab, mirroring
    /// `renameAgentSession`. Spawn provenance (`parentSessionID`, `createdByOverseerSessionID`) is
    /// never touched.
    ///
    /// - Returns: `true` when a session file was found (whether or not it changed).
    @discardableResult
    func updateDelegationPlacement(
        id: UUID,
        organizationalParentID: UUID?,
        delegationScopeID: UUID?,
        for workspace: WorkspaceModel
    ) async throws -> Bool {
        guard var session = try await loadAgentSession(id: id, for: workspace) else { return false }
        guard session.organizationalParentID != organizationalParentID
            || session.delegationScopeID != delegationScopeID
        else { return true }
        session.organizationalParentID = organizationalParentID
        session.delegationScopeID = delegationScopeID
        _ = try await saveAgentSession(session, for: workspace)
        return true
    }
}
