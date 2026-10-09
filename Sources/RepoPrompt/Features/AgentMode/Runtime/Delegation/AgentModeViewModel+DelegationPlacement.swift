import Foundation

extension AgentModeViewModel {
    /// Writes mutable organizational placement for one session this window owns.
    ///
    /// Placement is presentation-free administration state: it updates the owner-validated index
    /// entry (which feeds `.tree` scope membership immediately) and persists through the ordinary
    /// save path for a live tab, or a placement-only rewrite for a session with no live tab. Spawn
    /// provenance is never written here.
    ///
    /// - Returns: `false` when this window does not own the session.
    @discardableResult
    func setDelegationPlacement(
        sessionID: UUID,
        organizationalParentID: UUID?,
        delegationScopeID: UUID?
    ) async throws -> Bool {
        guard var entry = ownerValidatedSessionIndex[sessionID] else { return false }
        if entry.organizationalParentID != organizationalParentID || entry.delegationScopeID != delegationScopeID {
            entry.organizationalParentID = organizationalParentID
            entry.delegationScopeID = delegationScopeID
            sessionIndexStore.applyLocalUpsert(entry)
        }
        if let session = try authoritativeLiveSession(for: sessionID) {
            guard session.organizationalParentID != organizationalParentID
                || session.delegationScopeID != delegationScopeID
            else { return true }
            session.organizationalParentID = organizationalParentID
            session.delegationScopeID = delegationScopeID
            session.isDirty = true
            scheduleSave(for: session.tabID)
            return true
        }
        guard let workspace = workspaceManager?.activeWorkspace else { return true }
        try await AgentSessionDataService.shared.updateDelegationPlacement(
            id: sessionID,
            organizationalParentID: organizationalParentID,
            delegationScopeID: delegationScopeID,
            for: workspace
        )
        return true
    }
}
