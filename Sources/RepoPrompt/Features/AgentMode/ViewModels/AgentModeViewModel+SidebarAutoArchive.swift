import Foundation

@MainActor
extension AgentModeViewModel {
    enum SidebarAutoArchiveReason: String, Equatable {
        case sessionListReady
        case sessionIndexChanged
        case liveSessionSetChanged
        case runProtectionChanged
        case mcpProtectionChanged
        case explicitTest
    }

    func scheduleSidebarAutoArchiveIfReady(reason: SidebarAutoArchiveReason) {
        guard ownerValidatedSessionListCacheReady else { return }
        scheduleSidebarAutoArchive(reason: reason)
    }

    func scheduleSidebarAutoArchive(reason: SidebarAutoArchiveReason) {
        guard ownerValidatedSessionListCacheReady, canRunSidebarAutoArchive, !isApplyingSidebarAutoArchive else { return }
        sidebarAutoArchiveTask?.cancel()
        sidebarAutoArchiveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.performSidebarAutoArchiveIfNeeded(reason: reason)
        }
    }

    @discardableResult
    func performSidebarAutoArchiveIfNeeded(
        reason: SidebarAutoArchiveReason,
        now: Date = Date()
    ) async -> Set<UUID> {
        guard ownerValidatedSessionListCacheReady, canRunSidebarAutoArchive, !isApplyingSidebarAutoArchive else { return [] }
        guard let promptManager,
              let workspaceID = workspaceManager?.activeWorkspace?.id,
              let owner = sidebarAutoArchiveOwner(workspaceID: workspaceID)
        else {
            return []
        }

        let openTabs = promptManager.currentComposeTabs
        let sidebarRows = sidebarSessions(for: openTabs)
        guard sidebarRows.count > sidebarAutoArchivePolicy.configuration.baseVisibleSessionLimit else { return [] }

        let protectedTabIDs = sidebarAutoArchiveProtectedTabIDs(for: sidebarRows)

        let decision = sidebarAutoArchivePolicy.decision(
            for: sidebarRows,
            currentTabID: currentTabID,
            protectedTabIDs: protectedTabIDs,
            now: now
        )
        guard !decision.tabIDsToArchive.isEmpty else { return [] }

        isApplyingSidebarAutoArchive = true
        defer { isApplyingSidebarAutoArchive = false }

        let archivedTabIDs = await promptManager.autoArchiveComposeTabsForSidebarPolicy(
            withIDs: decision.tabIDsToArchive,
            expectedWorkspaceID: workspaceID,
            isArchiveContextCurrent: { [weak self] in
                guard !Task.isCancelled, let self else { return false }
                return sidebarAutoArchiveOwner(workspaceID: workspaceID) == owner
            }
        )
        guard sidebarAutoArchiveOwner(workspaceID: workspaceID) == owner else { return [] }
        if !archivedTabIDs.isEmpty {
            syncSidebarUIState(refresh: true, reason: .sessionList)
        }
        return archivedTabIDs
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
            if !isComposeTabEligibleForAutomaticStash(row.tabID)
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
