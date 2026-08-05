import Foundation

@MainActor
extension AgentModeViewModel {
    /// Computes the legacy archive policy as a read-only suggestion. Callers must
    /// not treat the decision as authorization to mutate tabs or sessions.
    func sidebarAutoArchiveSuggestion(now: Date = Date()) -> AgentModeSidebarAutoArchivePolicy.Decision {
        guard ownerValidatedSessionListCacheReady,
              let promptManager,
              let workspaceID = workspaceManager?.activeWorkspace?.id,
              sidebarAutoArchiveOwner(workspaceID: workspaceID) != nil
        else {
            return .empty(evaluatedSessionCount: 0)
        }

        let sidebarRows = sidebarSessions(for: promptManager.currentComposeTabs)
        guard sidebarRows.count > sidebarAutoArchivePolicy.configuration.baseVisibleSessionLimit else {
            return .empty(evaluatedSessionCount: sidebarRows.count)
        }

        return sidebarAutoArchivePolicy.decision(
            for: sidebarRows,
            currentTabID: currentTabID,
            protectedTabIDs: sidebarAutoArchiveProtectedTabIDs(for: sidebarRows),
            now: now
        )
    }

    func sidebarAutoArchiveProtectedTabIDs(for sidebarRows: [SidebarSession]) -> Set<UUID> {
        var protectedTabIDs = Set<UUID>()
        if let currentTabID {
            protectedTabIDs.insert(currentTabID)
        }

        let currentIndex = ownerValidatedSessionIndex
        for row in sidebarRows {
            let persistedEntry = row.sessionID.flatMap { currentIndex[$0] }
                ?? preferredSidebarEntry(for: row.tabID, tabName: row.title)
            if isComposeTabProtectedFromSidebarArchiveSuggestion(row.tabID)
                || row.isMCPControlled
                || persistedEntry?.isMCPOriginated == true
                || isProtectedPersistedRunState(persistedEntry?.lastRunStateRaw)
            {
                protectedTabIDs.insert(row.tabID)
            }
        }
        return protectedTabIDs
    }

    private func isProtectedPersistedRunState(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        if let runState = AgentSessionRunState(rawValue: rawValue) {
            return runState.isActive
        }
        let normalized = rawValue.lowercased()
        return normalized.contains("running")
            || normalized.contains("waiting")
            || normalized.contains("approval")
            || normalized.contains("question")
    }
}
