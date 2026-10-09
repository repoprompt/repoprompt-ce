import Foundation

/// Per-session serialization of placement writes, so two administrations of the same session can
/// never interleave their load/rewrite of an unloaded session file.
@MainActor
enum DelegationPlacementWriteQueue {
    private static var tails: [UUID: Task<Void, Never>] = [:]

    static func enqueue<T>(
        _ sessionID: UUID,
        _ body: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let previous = tails[sessionID]
        let work = Task { @MainActor () -> Result<T, Error> in
            await previous?.value
            do { return try await .success(body()) } catch { return .failure(error) }
        }
        let tail = Task { @MainActor in _ = await work.value }
        tails[sessionID] = tail
        let result = await work.value
        if tails[sessionID] == tail { tails.removeValue(forKey: sessionID) }
        return try result.get()
    }
}

extension AgentModeViewModel {
    /// Writes mutable organizational placement for one session this window owns.
    ///
    /// Placement is presentation-free administration state: it updates the owner-validated index
    /// entry (which feeds `.tree` scope membership immediately) and the live tab when there is one —
    /// even before the session has an index entry, as for a just-created `agent_run`/`agent_manage`
    /// target — and persists through the ordinary save path for a live tab, or a placement-only
    /// rewrite for a session with no live tab. Spawn provenance is never written here. Writes for one
    /// session are serialized.
    ///
    /// - Returns: `false` when this window owns neither an index entry nor a live tab for the session.
    @discardableResult
    func setDelegationPlacement(
        sessionID: UUID,
        organizationalParentID: UUID?,
        delegationScopeID: UUID?
    ) async throws -> Bool {
        try await DelegationPlacementWriteQueue.enqueue(sessionID) { [weak self] in
            guard let self else { return false }
            return try await applyDelegationPlacement(
                sessionID: sessionID,
                organizationalParentID: organizationalParentID,
                delegationScopeID: delegationScopeID
            )
        }
    }

    private func applyDelegationPlacement(
        sessionID: UUID,
        organizationalParentID: UUID?,
        delegationScopeID: UUID?
    ) async throws -> Bool {
        let live = try authoritativeLiveSession(for: sessionID)
        let entry = ownerValidatedSessionIndex[sessionID]
        guard live != nil || entry != nil else { return false }
        if var entry, entry.organizationalParentID != organizationalParentID || entry.delegationScopeID != delegationScopeID {
            entry.organizationalParentID = organizationalParentID
            entry.delegationScopeID = delegationScopeID
            sessionIndexStore.applyLocalUpsert(entry)
        }
        if let session = live {
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

    /// Whether an `agent_run start` into `tabID` would add a session to its spawn parent's subtree:
    /// a new tab, a tab with no bound session, or a bound session with no spawn parent yet (the spawn
    /// parent is write-once, so an already-parented session never moves).
    func delegationSpawnTargetJoinsAsNewMember(tabID: UUID?) -> Bool {
        guard let tabID, let sessionID = boundSessionID(for: tabID) else { return true }
        let live = try? authoritativeLiveSession(for: sessionID)
        let parent = live?.parentSessionID ?? ownerValidatedSessionIndex[sessionID]?.parentSessionID
        return parent == nil
    }
}
