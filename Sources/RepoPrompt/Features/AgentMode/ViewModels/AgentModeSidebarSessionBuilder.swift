import Foundation

@MainActor
struct AgentModeSidebarSessionBuilder {
    typealias SidebarSession = AgentModeViewModel.SidebarSession
    typealias TabSession = AgentModeViewModel.TabSession

    let allTabs: [ComposeTabState]
    let linkedTabs: [ComposeTabState]
    let sessions: [UUID: TabSession]
    let authoritativeSessionIDByTabID: [UUID: UUID]
    let sessionIndex: [UUID: AgentSessionIndexEntry]
    let sessionListSortDates: [UUID: Date]
    let sessionListCacheReady: Bool
    let sidebarRestoreFrozenOrderByTabID: [UUID: Int]
    let mcpControlledTabIDs: Set<UUID>

    private struct BuildContext {
        let tabByID: [UUID: ComposeTabState]
        let tabNameByID: [UUID: String]
        let tabOrder: [UUID: Int]
        let sortDateByTabID: [UUID: Date]
        let explicitSessionIDByTabID: [UUID: UUID]
        let bestEntryByTabID: [UUID: AgentSessionIndexEntry]
        let useFrozenRestoreOrder: Bool
    }

    func build() -> [SidebarSession] {
        #if DEBUG
            let startMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let context = makeBuildContext()
        let rows = linkedTabs.map { tab in
            sidebarRow(for: tab, context: context)
        }
        let baseSortedSessions = sortedSidebarRows(rows, context: context)
        let result = finalizedSidebarRows(from: baseSortedSessions, context: context)
        #if DEBUG
            let hasParentMetadata = sessions.values.contains { $0.parentSessionID != nil }
                || sessionIndex.values.contains { $0.parentSessionID != nil }
            AgentModePerfDiagnostics.durationEvent(
                "sidebar.builder.build",
                startMS: startMS,
                fields: [
                    "allTabCount": String(allTabs.count),
                    "hasParentMetadata": String(hasParentMetadata),
                    "linkedTabCount": String(linkedTabs.count),
                    "mcpControlledCount": String(mcpControlledTabIDs.count),
                    "resultCount": String(result.count),
                    "sessionCount": String(sessions.count),
                    "sessionIndexCount": String(sessionIndex.count),
                    "sortDateCount": String(sessionListSortDates.count)
                ]
            )
        #endif
        return result
    }

    static func preferredSidebarEntry(
        for tabID: UUID,
        tabName: String? = nil,
        sessionIndex: [UUID: AgentSessionIndexEntry]
    ) -> AgentSessionIndexEntry? {
        preferredSidebarEntry(
            for: tabID,
            tabName: tabName,
            entries: sessionIndex.values.filter { $0.tabID == tabID }
        )
    }

    static func sessionIndexEntryHasConversationContent(_ entry: AgentSessionIndexEntry) -> Bool {
        entry.itemCount > 0 || entry.lastUserMessageAt != nil || entry.hasUnknownConversationContent
    }

    private func makeBuildContext() -> BuildContext {
        var tabByID: [UUID: ComposeTabState] = [:]
        for tab in allTabs where tabByID[tab.id] == nil {
            tabByID[tab.id] = tab
        }
        let tabNameByID = sidebarTabNameLookup(for: linkedTabs)
        let tabOrder = sidebarTabOrder(for: linkedTabs)
        let explicitSessionIDByTabID = authoritativeSessionIDByTabID.filter { tabID, _ in
            linkedTabs.contains(where: { $0.id == tabID })
        }
        let explicitTabIDBySessionID = Dictionary(
            explicitSessionIDByTabID.map { ($0.value, $0.key) },
            uniquingKeysWith: { _, latest in latest }
        )
        let indexEntriesByTabID = Dictionary(grouping: sessionIndex.values, by: \.tabID)
        let bestEntryByTabID = sidebarEntryMap(
            for: linkedTabs,
            tabNameByID: tabNameByID,
            explicitSessionIDByTabID: explicitSessionIDByTabID,
            explicitTabIDBySessionID: explicitTabIDBySessionID,
            indexEntriesBySessionID: sessionIndex,
            indexEntriesByTabID: indexEntriesByTabID
        )
        let sortDateByTabID = sidebarSortDateLookup(
            for: linkedTabs,
            explicitSessionIDByTabID: explicitSessionIDByTabID,
            bestEntryByTabID: bestEntryByTabID
        )
        return BuildContext(
            tabByID: tabByID,
            tabNameByID: tabNameByID,
            tabOrder: tabOrder,
            sortDateByTabID: sortDateByTabID,
            explicitSessionIDByTabID: explicitSessionIDByTabID,
            bestEntryByTabID: bestEntryByTabID,
            useFrozenRestoreOrder: shouldFreezeSidebarOrdering(for: linkedTabs)
        )
    }

    private func sidebarTabNameLookup(for tabs: [ComposeTabState]) -> [UUID: String] {
        var tabNameByID: [UUID: String] = [:]
        for tab in tabs where tabNameByID[tab.id] == nil {
            tabNameByID[tab.id] = Self.normalizedSessionTitle(tab.name)
        }
        return tabNameByID
    }

    private func sidebarTabOrder(for tabs: [ComposeTabState]) -> [UUID: Int] {
        var tabOrder: [UUID: Int] = [:]
        for (index, tab) in tabs.enumerated() where tabOrder[tab.id] == nil {
            tabOrder[tab.id] = index
        }
        return tabOrder
    }

    private func sidebarSortDateLookup(
        for tabs: [ComposeTabState],
        explicitSessionIDByTabID: [UUID: UUID],
        bestEntryByTabID: [UUID: AgentSessionIndexEntry]
    ) -> [UUID: Date] {
        var sortDateByTabID: [UUID: Date] = [:]
        for tab in tabs where sortDateByTabID[tab.id] == nil {
            let liveSession: TabSession? = if let session = sessions[tab.id],
                                              session.activeAgentSessionID == explicitSessionIDByTabID[tab.id],
                                              session.hasLoadedPersistedState
            {
                session
            } else {
                nil
            }
            guard let sortDate = Self.sessionListSortDate(
                liveSession: liveSession,
                indexEntry: bestEntryByTabID[tab.id]
            ) else {
                continue
            }
            sortDateByTabID[tab.id] = sortDate
        }
        return sortDateByTabID
    }

    private func shouldFreezeSidebarOrdering(for tabs: [ComposeTabState]) -> Bool {
        guard !sessionListCacheReady, !sidebarRestoreFrozenOrderByTabID.isEmpty else { return false }
        return tabs.allSatisfy { sidebarRestoreFrozenOrderByTabID[$0.id] != nil }
    }

    private func frozenSidebarOrderIndex(for tabID: UUID, fallback: Int) -> Int {
        sidebarRestoreFrozenOrderByTabID[tabID] ?? fallback
    }

    private func sidebarEntryMap(
        for tabs: [ComposeTabState],
        tabNameByID: [UUID: String],
        explicitSessionIDByTabID: [UUID: UUID],
        explicitTabIDBySessionID: [UUID: UUID],
        indexEntriesBySessionID: [UUID: AgentSessionIndexEntry],
        indexEntriesByTabID: [UUID: [AgentSessionIndexEntry]]
    ) -> [UUID: AgentSessionIndexEntry] {
        var entryByTabID: [UUID: AgentSessionIndexEntry] = [:]
        for tab in tabs where entryByTabID[tab.id] == nil {
            if let explicitSessionID = explicitSessionIDByTabID[tab.id],
               let explicitEntry = indexEntriesBySessionID[explicitSessionID]
            {
                entryByTabID[tab.id] = Self.sidebarEntry(
                    from: explicitEntry,
                    tabID: tab.id,
                    tabName: tabNameByID[tab.id]
                )
                continue
            }
            let candidateEntries = (indexEntriesByTabID[tab.id] ?? []).filter { entry in
                guard let explicitTabID = explicitTabIDBySessionID[entry.id] else { return true }
                return explicitTabID == tab.id
            }
            guard let entry = Self.preferredSidebarEntry(
                for: tab.id,
                tabName: tabNameByID[tab.id],
                entries: candidateEntries
            ) else {
                continue
            }
            entryByTabID[tab.id] = entry
        }
        return entryByTabID
    }

    private static func sidebarEntry(
        from entry: AgentSessionIndexEntry,
        tabID: UUID,
        tabName: String?
    ) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: entry.id,
            tabID: tabID,
            name: tabName.map(normalizedSessionTitle) ?? normalizedSessionTitle(entry.name),
            lastUserMessageAt: entry.lastUserMessageAt,
            savedAt: entry.savedAt,
            lastRunStateRaw: entry.lastRunStateRaw,
            itemCount: entry.itemCount,
            agentKindRaw: entry.agentKindRaw,
            agentModelRaw: entry.agentModelRaw,
            agentReasoningEffortRaw: entry.agentReasoningEffortRaw,
            autoEditEnabled: entry.autoEditEnabled,
            parentSessionID: entry.parentSessionID,
            hasUnknownConversationContent: entry.hasUnknownConversationContent,
            isMCPOriginated: entry.isMCPOriginated,
            worktreeBindingSummaries: entry.worktreeBindingSummaries,
            activeWorktreeMergeSummaries: entry.activeWorktreeMergeSummaries
        )
    }

    static func preferredSidebarEntry(
        for tabID: UUID,
        tabName: String?,
        entries: [AgentSessionIndexEntry]
    ) -> AgentSessionIndexEntry? {
        let preferredName = tabName.map(normalizedSessionTitle)
        let resolvedEntries = entries.lazy.compactMap { entry -> AgentSessionIndexEntry? in
            guard entry.tabID == tabID else { return nil }
            var resolved = entry
            resolved.name = preferredName ?? normalizedSessionTitle(entry.name)
            return resolved
        }

        return AgentSessionRestoreSupport.preferredEntriesByTabID(from: resolvedEntries)[tabID]
    }

    private func sidebarRow(
        for tab: ComposeTabState,
        context: BuildContext
    ) -> SidebarSession {
        let authoritativeSessionID = context.explicitSessionIDByTabID[tab.id]
            ?? context.bestEntryByTabID[tab.id]?.id
        let boundLiveSession: TabSession? = if let session = sessions[tab.id],
                                               session.activeAgentSessionID == authoritativeSessionID
        {
            session
        } else {
            nil
        }
        let metadataLiveSession = boundLiveSession?.hasLoadedPersistedState == true
            ? boundLiveSession
            : nil
        let entry = context.bestEntryByTabID[tab.id]
        let title = sidebarRowTitle(
            for: tab,
            liveSession: boundLiveSession,
            entry: entry,
            context: context
        )
        let lastUserMessageAt = Self.freshestDate(
            entry?.lastUserMessageAt,
            context.sortDateByTabID[tab.id]
        )
        let savedAt = sidebarSavedAt(for: tab, liveSession: metadataLiveSession, indexEntry: entry)
        let activityDate = Self.sidebarActivityDate(lastUserMessageAt: lastUserMessageAt, savedAt: savedAt)
        let resolvedSessionID = authoritativeSessionID ?? entry?.id
        let resolvedParentSessionID = metadataLiveSession?.parentSessionID ?? entry?.parentSessionID

        return SidebarSession(
            id: tab.id,
            tabID: tab.id,
            title: title,
            lastUserMessageAt: lastUserMessageAt,
            activityDate: activityDate,
            isPinned: tab.isPinned,
            sessionID: resolvedSessionID,
            parentSessionID: resolvedParentSessionID,
            depth: 0,
            isMCPControlled: mcpControlledTabIDs.contains(tab.id),
            worktree: sidebarRowWorktree(liveSession: metadataLiveSession, entry: entry),
            worktreeMergeAttention: sidebarRowWorktreeMergeAttention(liveSession: metadataLiveSession, entry: entry)
        )
    }

    /// Resolves the active worktree merge attention summary for a session row.
    /// Prefers live-session operations, falling back to the persisted session
    /// index entry so restored sessions still surface merge state.
    private func sidebarRowWorktreeMergeAttention(
        liveSession: TabSession?,
        entry: AgentSessionIndexEntry?
    ) -> AgentWorktreeMergeAttention? {
        if let liveSession,
           !liveSession.worktreeMergeOperations.isEmpty
        {
            return AgentWorktreeMergeBlockerSelector.sidebarAttention(
                in: liveSession.worktreeMergeOperations
            )
        }
        guard let summaries = entry?.activeWorktreeMergeSummaries,
              let primary = summaries.sorted(by: { $0.updatedAt > $1.updatedAt }).first,
              primary.status == .conflicted
              || primary.status == .awaitingCommit
              || primary.status == .awaitingApproval
        else {
            return nil
        }
        return AgentWorktreeMergeAttention(summary: primary)
    }

    /// Resolves the representative worktree indicator for a session row.
    /// Prefers live-session bindings, falling back to the persisted session
    /// index entry so restored rows still show worktree identity. Sessions
    /// bound to multiple roots surface their first binding.
    private func sidebarRowWorktree(
        liveSession: TabSession?,
        entry: AgentSessionIndexEntry?
    ) -> AgentWorktreeIndicator? {
        let summaries: [AgentSessionWorktreeBindingSummary] =
            if let liveSession, !liveSession.worktreeBindings.isEmpty {
                liveSession.worktreeBindings.worktreeBindingSummaries
            } else {
                entry?.worktreeBindingSummaries ?? []
            }
        guard let representative = summaries.first else { return nil }
        return AgentWorktreeIndicatorResolver.indicator(for: representative)
    }

    private func sidebarRowTitle(
        for tab: ComposeTabState,
        liveSession: TabSession?,
        entry: AgentSessionIndexEntry?,
        context: BuildContext
    ) -> String {
        if let entry {
            return sidebarTitle(for: entry, liveSession: liveSession)
        }
        if let liveSession,
           liveSession.activeAgentSessionID != nil,
           !liveSession.hasLoadedPersistedState
        {
            return context.tabNameByID[tab.id] ?? Self.normalizedSessionTitle(nil)
        }
        let hasTranscript = liveSession?.items.isEmpty == false
        let hasSentUserMessage = context.sortDateByTabID[tab.id] != nil
        return (!hasTranscript && !hasSentUserMessage)
            ? emptySidebarTitle(named: context.tabNameByID[tab.id])
            : (context.tabNameByID[tab.id] ?? Self.normalizedSessionTitle(nil))
    }

    private func sidebarTitle(for entry: AgentSessionIndexEntry, liveSession: TabSession?) -> String {
        if let liveSession,
           liveSession.activeAgentSessionID != nil,
           !liveSession.hasLoadedPersistedState
        {
            // Hydrating sessions should keep a stable title to avoid "New Chat" flicker.
            return Self.normalizedSessionTitle(entry.name)
        }
        let hasTranscript = (liveSession?.items.isEmpty == false) || entry.itemCount > 0
        let hasSentUserMessage = entry.lastUserMessageAt != nil
        if !hasTranscript, !hasSentUserMessage, !entry.hasUnknownConversationContent {
            return emptySidebarTitle(named: entry.name)
        }
        return Self.normalizedSessionTitle(entry.name)
    }

    private func emptySidebarTitle(named rawName: String?) -> String {
        let normalized = Self.normalizedSessionTitle(rawName)
        return Self.isDefaultBlankSessionTitle(normalized) ? "New Chat" : normalized
    }

    private static func isDefaultBlankSessionTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "New Chat" || trimmed == "New Session" || trimmed == "Agent Session" {
            return true
        }
        guard trimmed.count >= 2 else { return false }
        let prefix = trimmed.prefix(1)
        guard prefix == "T" || prefix == "t" else { return false }
        return Int(trimmed.dropFirst()) != nil
    }

    private func sortedSidebarRows(
        _ rows: [SidebarSession],
        context: BuildContext
    ) -> [SidebarSession] {
        rows.sorted { lhs, rhs in
            let lhsIndex = context.tabOrder[lhs.tabID] ?? Int.max
            let rhsIndex = context.tabOrder[rhs.tabID] ?? Int.max
            if context.useFrozenRestoreOrder {
                let lhsFrozenIndex = frozenSidebarOrderIndex(for: lhs.tabID, fallback: lhsIndex)
                let rhsFrozenIndex = frozenSidebarOrderIndex(for: rhs.tabID, fallback: rhsIndex)
                if lhsFrozenIndex != rhsFrozenIndex {
                    return lhsFrozenIndex < rhsFrozenIndex
                }
            }
            return sidebarRowPrecedes(lhs, rhs, tabOrder: context.tabOrder)
        }
    }

    private func sidebarRowPrecedes(
        _ lhs: SidebarSession,
        _ rhs: SidebarSession,
        tabOrder: [UUID: Int]
    ) -> Bool {
        if lhs.activityDate != rhs.activityDate {
            return lhs.activityDate > rhs.activityDate
        }
        let lhsIndex = tabOrder[lhs.tabID] ?? Int.max
        let rhsIndex = tabOrder[rhs.tabID] ?? Int.max
        if lhsIndex != rhsIndex {
            return lhsIndex < rhsIndex
        }
        return lhs.tabID.uuidString < rhs.tabID.uuidString
    }

    private func sidebarSavedAt(
        for tab: ComposeTabState,
        liveSession: TabSession?,
        indexEntry: AgentSessionIndexEntry? = nil
    ) -> Date {
        if let liveSession {
            return [tab.lastModified, liveSession.lastActivityAt, indexEntry?.savedAt]
                .compactMap(\.self)
                .max() ?? tab.lastModified
        }
        return indexEntry?.savedAt ?? tab.lastModified
    }

    private func finalizedSidebarRows(
        from baseSortedSessions: [SidebarSession],
        context: BuildContext
    ) -> [SidebarSession] {
        if context.useFrozenRestoreOrder {
            return sidebarSessionsPreservingFlatOrder(
                prefixedPinnedSidebarSessions(baseSortedSessions)
            )
        }
        if baseSortedSessions.contains(where: { $0.parentSessionID != nil }) {
            return threadedSidebarSessions(
                from: baseSortedSessions,
                tabOrder: context.tabOrder
            )
        }
        return sidebarSessionsPreservingFlatOrder(
            prefixedPinnedSidebarSessions(baseSortedSessions)
        )
    }

    private func prefixedPinnedSidebarSessions(_ sessions: [SidebarSession]) -> [SidebarSession] {
        let pinned = sessions.filter(\.isPinned)
        guard !pinned.isEmpty else { return sessions }
        let unpinned = sessions.filter { !$0.isPinned }
        return pinned + unpinned
    }

    /// Preserves the incoming row order while annotating child depth only when the
    /// parent already appears earlier in the list. This avoids visible row movement
    /// during persisted restore while still surfacing limited thread structure.
    private func sidebarSessionsPreservingFlatOrder(_ flat: [SidebarSession]) -> [SidebarSession] {
        var sessionIDToIndex: [UUID: Int] = [:]
        for (index, session) in flat.enumerated() {
            if let sessionID = session.sessionID {
                sessionIDToIndex[sessionID] = index
            }
        }

        var cachedDepthByIndex: [Int: Int] = [:]
        var visiting = Set<Int>()

        func stableDepth(for index: Int) -> Int {
            if let cached = cachedDepthByIndex[index] {
                return cached
            }
            guard let parentSessionID = flat[index].parentSessionID,
                  let sessionID = flat[index].sessionID,
                  parentSessionID != sessionID,
                  let parentIndex = sessionIDToIndex[parentSessionID],
                  parentIndex < index,
                  !visiting.contains(index)
            else {
                cachedDepthByIndex[index] = 0
                return 0
            }

            visiting.insert(index)
            let depth = stableDepth(for: parentIndex) + 1
            visiting.remove(index)
            cachedDepthByIndex[index] = depth
            return depth
        }

        return flat.enumerated().map { index, session in
            row(session, depth: stableDepth(for: index))
        }
    }

    /// Builds a thread-aware flattened list from flat sidebar sessions.
    /// Child sessions are nested under their parent with incrementing depth.
    /// Cycles and missing parents degrade children to root level.
    private func threadedSidebarSessions(
        from flat: [SidebarSession],
        tabOrder: [UUID: Int]
    ) -> [SidebarSession] {
        // Build lookup: sessionID -> index in flat list
        var sessionIDToIndex: [UUID: Int] = [:]
        for (i, session) in flat.enumerated() {
            if let sid = session.sessionID {
                sessionIDToIndex[sid] = i
            }
        }

        // Determine parent-child relationships
        // A session is a child if: parentSessionID != nil, parent is in the visible set,
        // parent != self, and attaching wouldn't create a cycle.
        var childrenByParent: [UUID: [Int]] = [:] // parentSessionID -> [child flat indices]
        var isChild = Set<Int>()

        for (i, session) in flat.enumerated() {
            guard let parentSID = session.parentSessionID,
                  let selfSID = session.sessionID,
                  parentSID != selfSID,
                  sessionIDToIndex[parentSID] != nil
            else {
                continue
            }
            // Cycle detection: walk parent chain
            var visited: Set<UUID> = [selfSID]
            var cursor: UUID? = parentSID
            var hasCycle = false
            while let c = cursor {
                if visited.contains(c) { hasCycle = true
                    break
                }
                visited.insert(c)
                let parentSession = sessionIDToIndex[c].flatMap { flat[$0] }
                cursor = parentSession?.parentSessionID
            }
            guard !hasCycle else { continue }

            childrenByParent[parentSID, default: []].append(i)
            isChild.insert(i)
        }

        // If no threading needed, return flat list as-is
        guard !childrenByParent.isEmpty else { return flat }

        // DFS flattening: roots first, then children in original order.
        // Root order uses the earliest flat-list position from each visible subtree,
        // so a reopened child keeps its parent+subtree anchored at the child's
        // recency instead of dropping the whole subtree to the older parent's row.
        var result: [SidebarSession] = []
        result.reserveCapacity(flat.count)

        var subtreePriorityByIndex: [Int: Int] = [:]
        func subtreePriority(for index: Int) -> Int {
            if let cached = subtreePriorityByIndex[index] {
                return cached
            }
            var priority = index
            if let sid = flat[index].sessionID,
               let children = childrenByParent[sid]
            {
                for childIndex in children {
                    priority = min(priority, subtreePriority(for: childIndex))
                }
            }
            subtreePriorityByIndex[index] = priority
            return priority
        }

        var subtreeContainsPinnedByIndex: [Int: Bool] = [:]
        func subtreeContainsPinned(_ index: Int) -> Bool {
            if let cached = subtreeContainsPinnedByIndex[index] {
                return cached
            }
            let containsPinned = flat[index].isPinned
                || flat[index].sessionID
                .flatMap { childrenByParent[$0] }?
                .contains(where: subtreeContainsPinned) == true
            subtreeContainsPinnedByIndex[index] = containsPinned
            return containsPinned
        }

        func emit(_ index: Int, depth: Int) {
            let session = flat[index]
            result.append(row(session, depth: depth))
            if let sid = session.sessionID, let children = childrenByParent[sid] {
                let orderedChildren = children.sorted { lhs, rhs in
                    let lhsContainsPinned = subtreeContainsPinned(lhs)
                    let rhsContainsPinned = subtreeContainsPinned(rhs)
                    if lhsContainsPinned != rhsContainsPinned {
                        return lhsContainsPinned && !rhsContainsPinned
                    }
                    return sidebarRowPrecedes(flat[lhs], flat[rhs], tabOrder: tabOrder)
                }
                for childIndex in orderedChildren {
                    emit(childIndex, depth: depth + 1)
                }
            }
        }

        let rootIndices = flat.indices.filter { !isChild.contains($0) }
        for rootIndex in rootIndices.sorted(by: { lhs, rhs in
            let lhsContainsPinned = subtreeContainsPinned(lhs)
            let rhsContainsPinned = subtreeContainsPinned(rhs)
            if lhsContainsPinned != rhsContainsPinned {
                return lhsContainsPinned && !rhsContainsPinned
            }
            let lhsPriority = subtreePriority(for: lhs)
            let rhsPriority = subtreePriority(for: rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs < rhs
        }) {
            emit(rootIndex, depth: 0)
        }
        return result
    }

    private func row(_ session: SidebarSession, depth: Int) -> SidebarSession {
        SidebarSession(
            id: session.id,
            tabID: session.tabID,
            title: session.title,
            lastUserMessageAt: session.lastUserMessageAt,
            activityDate: session.activityDate,
            isPinned: session.isPinned,
            sessionID: session.sessionID,
            parentSessionID: session.parentSessionID,
            depth: depth,
            isMCPControlled: session.isMCPControlled,
            worktree: session.worktree,
            worktreeMergeAttention: session.worktreeMergeAttention
        )
    }

    private static func normalizedSessionTitle(_ raw: String?) -> String {
        AgentSessionRestoreSupport.normalizedSessionTitle(raw)
    }

    private static func sessionListSortDate(
        liveSession: TabSession?,
        indexEntry: AgentSessionIndexEntry?
    ) -> Date? {
        [
            liveSession?.lastUserMessageAt,
            liveSession.flatMap { AgentTranscriptIO.lastUserInteractionDate(in: $0.items) },
            indexEntry?.lastUserMessageAt
        ]
        .compactMap(\.self)
        .max()
    }

    private static func freshestDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        [lhs, rhs].compactMap(\.self).max()
    }

    private static func sidebarActivityDate(lastUserMessageAt: Date?, savedAt: Date) -> Date {
        AgentSessionRestoreSupport.sidebarActivityDate(
            lastUserMessageAt: lastUserMessageAt,
            savedAt: savedAt
        )
    }
}
