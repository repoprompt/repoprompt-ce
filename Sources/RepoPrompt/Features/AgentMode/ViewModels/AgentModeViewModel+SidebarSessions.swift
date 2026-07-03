import Foundation

@MainActor
extension AgentModeViewModel {
    /// Side-effect-free sort date used by the session sidebar.
    /// Uses only the timestamp of the last sent agent-mode message.
    func sessionListSortDate(for tabID: UUID) -> Date? {
        if let session = sessions[tabID] {
            if let lastUserMessageAt = session.lastUserMessageAt {
                return lastUserMessageAt
            }
            if let computed = computeLastUserMessageDate(in: session.items) {
                return computed
            }
        }
        return ownerValidatedSessionListSortDates[tabID]
    }

    struct SidebarSessionDateInfo: Equatable {
        let lastEngagementAt: Date?
        let activityDate: Date?
    }

    struct ArchivedSidebarSessionTabsSnapshot {
        let filteredTabs: [StashedTab]
        let sortedTabs: [StashedTab]
        let dateInfoByStashedTabID: [UUID: SidebarSessionDateInfo]
    }

    private struct ArchivedSidebarSessionLookup {
        let entriesByExplicitSessionID: [UUID: AgentSessionIndexEntry]
        let entriesByTabID: [UUID: [AgentSessionIndexEntry]]

        init(sessionIndex: [UUID: AgentSessionIndexEntry]) {
            entriesByExplicitSessionID = sessionIndex
            entriesByTabID = Dictionary(grouping: sessionIndex.values, by: \.tabID)
        }

        func explicitEntry(for sessionID: UUID?) -> AgentSessionIndexEntry? {
            guard let sessionID else { return nil }
            return entriesByExplicitSessionID[sessionID]
        }

        func entries(for tabID: UUID) -> [AgentSessionIndexEntry] {
            entriesByTabID[tabID] ?? []
        }

        func hasEntries(for tabID: UUID) -> Bool {
            entriesByTabID[tabID]?.isEmpty == false
        }
    }

    private func sessionIndexEntryHasConversationContent(_ entry: AgentSessionIndexEntry) -> Bool {
        AgentModeSidebarSessionBuilder.sessionIndexEntryHasConversationContent(entry)
    }

    private func archivedSidebarSessionLookup() -> ArchivedSidebarSessionLookup {
        ArchivedSidebarSessionLookup(sessionIndex: ownerValidatedSessionIndex)
    }

    private func preferredArchivedSidebarEntry(
        for tabID: UUID,
        tabName: String?,
        lookup: ArchivedSidebarSessionLookup
    ) -> AgentSessionIndexEntry? {
        AgentModeSidebarSessionBuilder.preferredSidebarEntry(
            for: tabID,
            tabName: tabName,
            entries: lookup.entries(for: tabID)
        )
    }

    private func shouldFreezeSidebarOrdering(for tabs: [ComposeTabState]) -> Bool {
        let frozenOrder = ownerValidatedSidebarRestoreFrozenOrderByTabID
        guard !ownerValidatedSessionListCacheReady, !frozenOrder.isEmpty else { return false }
        return tabs.allSatisfy { frozenOrder[$0.id] != nil }
    }

    private func frozenSidebarOrderIndex(for tabID: UUID, fallback: Int) -> Int {
        ownerValidatedSidebarRestoreFrozenOrderByTabID[tabID] ?? fallback
    }

    func preferredSidebarEntry(for tabID: UUID, tabName: String? = nil) -> AgentSessionIndexEntry? {
        AgentModeSidebarSessionBuilder.preferredSidebarEntry(
            for: tabID,
            tabName: tabName,
            sessionIndex: ownerValidatedSessionIndex
        )
    }

    func shouldShowArchivedSession(for stashedTab: StashedTab) -> Bool {
        shouldShowArchivedSession(for: stashedTab, lookup: archivedSidebarSessionLookup())
    }

    private func shouldShowArchivedSession(
        for stashedTab: StashedTab,
        lookup: ArchivedSidebarSessionLookup
    ) -> Bool {
        if let explicitEntry = lookup.explicitEntry(for: stashedTab.tab.activeAgentSessionID) {
            return sessionIndexEntryHasConversationContent(explicitEntry)
        }
        guard stashedTab.tab.activeAgentSessionID != nil || lookup.hasEntries(for: stashedTab.tab.id) else {
            return false
        }
        guard let entry = preferredArchivedSidebarEntry(for: stashedTab.tab.id, tabName: stashedTab.tab.name, lookup: lookup) else {
            return false
        }
        return sessionIndexEntryHasConversationContent(entry)
    }

    func archivedSessionDateInfo(for stashedTab: StashedTab) -> SidebarSessionDateInfo {
        archivedSessionDateInfo(for: stashedTab, lookup: archivedSidebarSessionLookup())
    }

    private func archivedSessionDateInfo(
        for stashedTab: StashedTab,
        lookup: ArchivedSidebarSessionLookup
    ) -> SidebarSessionDateInfo {
        let entry = lookup.explicitEntry(for: stashedTab.tab.activeAgentSessionID)
            ?? preferredArchivedSidebarEntry(for: stashedTab.tab.id, tabName: stashedTab.tab.name, lookup: lookup)

        return SidebarSessionDateInfo(
            lastEngagementAt: entry?.lastUserMessageAt,
            activityDate: entry.map(AgentSessionRestoreSupport.sidebarActivityDate(for:)) ?? stashedTab.tab.lastModified
        )
    }

    func archivedSessionTabsForSidebarSnapshot(
        _ stashedTabs: [StashedTab],
        searchText: String? = nil,
        prepareSortedRows: Bool
    ) -> ArchivedSidebarSessionTabsSnapshot {
        let lookup = archivedSidebarSessionLookup()
        let trimmedSearch = searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let filteredTabs = filteredArchivedSessionTabs(
            stashedTabs,
            searchText: searchText,
            lookup: lookup
        )
        guard prepareSortedRows else {
            return ArchivedSidebarSessionTabsSnapshot(
                filteredTabs: filteredTabs,
                sortedTabs: [],
                dateInfoByStashedTabID: [:]
            )
        }
        let dateInfoByID = archivedSessionDateInfoByID(for: filteredTabs, lookup: lookup)
        let sortedTabs = sortedFilteredArchivedSessionTabs(
            filteredTabs,
            diagnosticInputStashedCount: stashedTabs.count,
            diagnosticSearchActive: !trimmedSearch.isEmpty,
            dateInfoByID: dateInfoByID
        )
        return ArchivedSidebarSessionTabsSnapshot(
            filteredTabs: filteredTabs,
            sortedTabs: sortedTabs,
            dateInfoByStashedTabID: dateInfoByID
        )
    }

    func filteredArchivedSessionTabs(
        _ stashedTabs: [StashedTab],
        searchText: String? = nil
    ) -> [StashedTab] {
        filteredArchivedSessionTabs(
            stashedTabs,
            searchText: searchText,
            lookup: archivedSidebarSessionLookup()
        )
    }

    private func filteredArchivedSessionTabs(
        _ stashedTabs: [StashedTab],
        searchText: String?,
        lookup: ArchivedSidebarSessionLookup
    ) -> [StashedTab] {
        #if DEBUG
            let startMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let trimmedSearch = searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let filteredTabs = stashedTabs.filter { stashed in
            guard trimmedSearch.isEmpty || stashed.tab.name.localizedCaseInsensitiveContains(trimmedSearch) else {
                return false
            }
            return shouldShowArchivedSession(for: stashed, lookup: lookup)
        }
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(
                "sidebar.filteredArchivedTabs",
                startMS: startMS,
                fields: [
                    "filteredCount": String(filteredTabs.count),
                    "inputStashedCount": String(stashedTabs.count),
                    "searchActive": String(!trimmedSearch.isEmpty)
                ]
            )
        #endif
        return filteredTabs
    }

    /// Sorts archived tabs that have already been filtered by `filteredArchivedSessionTabs(_:searchText:)`.
    /// Use `sortedArchivedSessionTabs(_:searchText:)` when callers need the full filter + sort behavior.
    func sortedFilteredArchivedSessionTabs(_ filteredTabs: [StashedTab]) -> [StashedTab] {
        sortedFilteredArchivedSessionTabs(
            filteredTabs,
            diagnosticInputStashedCount: filteredTabs.count,
            diagnosticSearchActive: nil,
            lookup: archivedSidebarSessionLookup()
        )
    }

    /// Sorts archived tabs that have already been filtered, preserving search attribution for DEBUG metrics.
    func sortedFilteredArchivedSessionTabs(_ filteredTabs: [StashedTab], searchActive: Bool) -> [StashedTab] {
        sortedFilteredArchivedSessionTabs(
            filteredTabs,
            diagnosticInputStashedCount: filteredTabs.count,
            diagnosticSearchActive: searchActive,
            lookup: archivedSidebarSessionLookup()
        )
    }

    func sortedArchivedSessionTabs(
        _ stashedTabs: [StashedTab],
        searchText: String? = nil
    ) -> [StashedTab] {
        archivedSessionTabsForSidebarSnapshot(
            stashedTabs,
            searchText: searchText,
            prepareSortedRows: true
        ).sortedTabs
    }

    private func archivedSessionDateInfoByID(
        for filteredTabs: [StashedTab],
        lookup: ArchivedSidebarSessionLookup
    ) -> [UUID: SidebarSessionDateInfo] {
        Dictionary(
            filteredTabs.map { stashed in
                (stashed.id, archivedSessionDateInfo(for: stashed, lookup: lookup))
            },
            uniquingKeysWith: { existing, _ in existing }
        )
    }

    private func sortedFilteredArchivedSessionTabs(
        _ filteredTabs: [StashedTab],
        diagnosticInputStashedCount: Int,
        diagnosticSearchActive: Bool?,
        lookup: ArchivedSidebarSessionLookup
    ) -> [StashedTab] {
        let dateInfoByID = archivedSessionDateInfoByID(for: filteredTabs, lookup: lookup)
        return sortedFilteredArchivedSessionTabs(
            filteredTabs,
            diagnosticInputStashedCount: diagnosticInputStashedCount,
            diagnosticSearchActive: diagnosticSearchActive,
            dateInfoByID: dateInfoByID
        )
    }

    private func sortedFilteredArchivedSessionTabs(
        _ filteredTabs: [StashedTab],
        diagnosticInputStashedCount: Int,
        diagnosticSearchActive: Bool?,
        dateInfoByID: [UUID: SidebarSessionDateInfo]
    ) -> [StashedTab] {
        #if DEBUG
            let startMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let sortedTabs = filteredTabs.sorted { lhs, rhs in
            if lhs.tab.isPinned != rhs.tab.isPinned {
                return lhs.tab.isPinned && !rhs.tab.isPinned
            }
            let lhsActivityDate = dateInfoByID[lhs.id]?.activityDate ?? .distantPast
            let rhsActivityDate = dateInfoByID[rhs.id]?.activityDate ?? .distantPast
            if lhsActivityDate != rhsActivityDate {
                return lhsActivityDate > rhsActivityDate
            }
            if lhs.stashedAt != rhs.stashedAt {
                return lhs.stashedAt > rhs.stashedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        #if DEBUG
            var fields = [
                "filteredCount": String(filteredTabs.count),
                "inputStashedCount": String(diagnosticInputStashedCount)
            ]
            if let diagnosticSearchActive {
                fields["searchActive"] = String(diagnosticSearchActive)
            } else {
                fields["preFiltered"] = "true"
            }
            AgentModePerfDiagnostics.durationEvent(
                "sidebar.sortedArchivedTabs",
                startMS: startMS,
                fields: fields
            )
        #endif
        return sortedTabs
    }

    private func prefixedPinnedTabs(_ tabs: [ComposeTabState]) -> [ComposeTabState] {
        let pinned = tabs.filter(\.isPinned)
        guard !pinned.isEmpty else { return tabs }
        let unpinned = tabs.filter { !$0.isPinned }
        return pinned + unpinned
    }

    /// Session-linked sidebar data source.
    /// Blank compose tabs stay hidden until they are explicitly linked to an agent session.
    func sidebarSessions(for tabs: [ComposeTabState]) -> [SidebarSession] {
        let currentIndex = ownerValidatedSessionIndex
        let indexEntriesByTabID = Dictionary(grouping: currentIndex.values, by: \.tabID)
        let authoritativeSessionIDByTabID = Dictionary(
            uniqueKeysWithValues: tabs.compactMap { tab in
                authoritativeSessionID(for: tab).map { (tab.id, $0) }
            }
        )
        let explicitTabIDBySessionID = Dictionary(
            authoritativeSessionIDByTabID.map { ($0.value, $0.key) },
            uniquingKeysWith: { _, latest in latest }
        )
        let linkedTabs = tabs.filter { tab in
            if authoritativeSessionIDByTabID[tab.id] != nil {
                return true
            }
            let candidateEntries = (indexEntriesByTabID[tab.id] ?? []).filter { entry in
                guard let explicitTabID = explicitTabIDBySessionID[entry.id] else { return true }
                return explicitTabID == tab.id
            }
            return AgentModeSidebarSessionBuilder.preferredSidebarEntry(
                for: tab.id,
                tabName: tab.name,
                entries: candidateEntries
            ) != nil
        }
        return AgentModeSidebarSessionBuilder(
            allTabs: tabs,
            linkedTabs: linkedTabs,
            sessions: sessions,
            authoritativeSessionIDByTabID: authoritativeSessionIDByTabID,
            sessionIndex: currentIndex,
            sessionListSortDates: ownerValidatedSessionListSortDates,
            sessionListCacheReady: ownerValidatedSessionListCacheReady,
            sidebarRestoreFrozenOrderByTabID: ownerValidatedSidebarRestoreFrozenOrderByTabID,
            mcpControlledTabIDs: mcpControlledTabIDs
        ).build()
    }

    func collapsibleSidebarThreadKeys(
        for tabs: [ComposeTabState],
        currentTabID: UUID?,
        searchText: String,
        diagnosticSource: String? = nil
    ) -> [AgentSidebarThreadKey] {
        filteredSidebarSessions(
            for: tabs,
            currentTabID: currentTabID,
            searchText: searchText,
            diagnosticSource: diagnosticSource
        )
        .compactMap { row in
            guard row.depth == 0, row.hasThreadChildren, let key = row.threadKey else { return nil }
            return key
        }
    }

    func filteredSidebarSessions(
        for tabs: [ComposeTabState],
        currentTabID: UUID?,
        searchText: String? = nil,
        diagnosticSource: String? = nil
    ) -> [SidebarSession] {
        #if DEBUG
            let startMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let source = diagnosticSource ?? "unknown"
        let sortedSessions = sidebarSessions(for: tabs)
        let effectiveSearchText = searchText ?? sessionSidebarSearchText
        let searchTrimmed = effectiveSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: [SidebarSession]
        if searchTrimmed.isEmpty {
            result = sidebarRowsApplyingThreadCollapse(
                sortedSessions,
                currentTabID: currentTabID,
                searchText: effectiveSearchText,
                diagnosticSource: source
            )
        } else {
            // Build session ID lookup for ancestor inclusion
            let sessionByID: [UUID: SidebarSession] = Dictionary(
                sortedSessions.compactMap { s -> (UUID, SidebarSession)? in
                    guard let sid = s.sessionID else { return nil }
                    return (sid, s)
                },
                uniquingKeysWith: { _, new in new }
            )

            // Collect direct matches
            var matchedIDs = Set<UUID>()
            for session in sortedSessions {
                if session.title.localizedCaseInsensitiveContains(searchTrimmed) {
                    matchedIDs.insert(session.id)
                    // Include ancestor chain
                    var cursor = session.parentSessionID
                    var visitedSessionIDs: Set<UUID> = []
                    while let pid = cursor,
                          visitedSessionIDs.insert(pid).inserted,
                          let parent = sessionByID[pid]
                    {
                        matchedIDs.insert(parent.id)
                        cursor = parent.parentSessionID
                    }
                }
            }

            // Include active session's ancestor chain
            if let activeTabID = currentTabID,
               let activeSession = sortedSessions.first(where: { $0.tabID == activeTabID })
            {
                matchedIDs.insert(activeSession.id)
                var cursor = activeSession.parentSessionID
                var visitedSessionIDs: Set<UUID> = []
                while let pid = cursor,
                      visitedSessionIDs.insert(pid).inserted,
                      let parent = sessionByID[pid]
                {
                    matchedIDs.insert(parent.id)
                    cursor = parent.parentSessionID
                }
            }

            let filtered = sortedSessions.filter { matchedIDs.contains($0.id) }
            result = sidebarRowsApplyingThreadCollapse(
                filtered,
                currentTabID: currentTabID,
                searchText: effectiveSearchText,
                diagnosticSource: source
            )
        }
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(
                "sidebar.filteredSessions",
                startMS: startMS,
                fields: [
                    "canonicalCount": String(sortedSessions.count),
                    "currentTabID": AgentModePerfDiagnostics.shortID(currentTabID),
                    "filteredCount": String(result.count),
                    "inputTabCount": String(tabs.count),
                    "searchActive": String(!searchTrimmed.isEmpty),
                    "source": source
                ]
            )
        #endif
        return result
    }

    private func sidebarRowsApplyingThreadCollapse(
        _ rows: [SidebarSession],
        currentTabID: UUID?,
        searchText: String,
        diagnosticSource: String
    ) -> [SidebarSession] {
        #if DEBUG
            let startMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let source = diagnosticSource.isEmpty ? "unknown" : diagnosticSource
        let collapsedThreadKeys = ui.sessionSidebar.snapshot.collapsedThreadKeys
        guard !rows.isEmpty else {
            #if DEBUG
                AgentModePerfDiagnostics.durationEvent(
                    "sidebar.threadCollapse",
                    startMS: startMS,
                    fields: [
                        "collapsedThreadKeyCount": String(collapsedThreadKeys.count),
                        "displayedRowCount": "0",
                        "hasCurrentTab": String(currentTabID != nil),
                        "hiddenDescendantTotal": "0",
                        "inputRowCount": "0",
                        "searchActive": String(isSearching),
                        "source": source
                    ]
                )
            #endif
            return []
        }
        var parentIndexByIndex = [Int?](repeating: nil, count: rows.count)
        var stack: [Int] = []

        for index in rows.indices {
            while let candidateParentIndex = stack.last,
                  rows[candidateParentIndex].depth >= rows[index].depth
            {
                stack.removeLast()
            }
            parentIndexByIndex[index] = stack.last
            stack.append(index)
        }

        var subtreeSizes = Array(repeating: 1, count: rows.count)
        var subtreeActivityDates = rows.map { sidebarThreadActivityDate(for: $0) }
        var subtreeContainsActiveTab = rows.map { row in
            guard let currentTabID else { return false }
            return row.tabID == currentTabID
        }
        // Count how many rows in each row's subtree carry an unseen
        // run-state attention badge. If a collapsed parent hides a descendant
        // that needs attention, we surface that on the parent's collapsed-
        // count chip.
        let attentionByTabID = ui.sessionSidebar.snapshot.attentionRunStateByTabID
        var subtreeAttentionCounts = rows.map { row in
            attentionByTabID[row.tabID] != nil ? 1 : 0
        }
        for index in rows.indices.reversed() {
            guard let parentIndex = parentIndexByIndex[index] else { continue }
            subtreeSizes[parentIndex] += subtreeSizes[index]
            if subtreeActivityDates[index] > subtreeActivityDates[parentIndex] {
                subtreeActivityDates[parentIndex] = subtreeActivityDates[index]
            }
            subtreeContainsActiveTab[parentIndex] = subtreeContainsActiveTab[parentIndex] || subtreeContainsActiveTab[index]
            subtreeAttentionCounts[parentIndex] += subtreeAttentionCounts[index]
        }

        var hasChildren = Array(repeating: false, count: rows.count)
        for parentIndex in parentIndexByIndex.compactMap(\.self) {
            hasChildren[parentIndex] = true
        }

        var hiddenByCollapsedAncestor = Array(repeating: false, count: rows.count)
        var displayedRows: [SidebarSession] = []
        var hiddenDescendantTotal = 0
        displayedRows.reserveCapacity(rows.count)

        for index in rows.indices {
            guard !hiddenByCollapsedAncestor[index] else { continue }
            let key = AgentSidebarThreadKey.key(sessionID: rows[index].sessionID, tabID: rows[index].tabID)
            let rowIsActive = currentTabID.map { rows[index].tabID == $0 } ?? false
            let descendantContainsActiveTab = subtreeContainsActiveTab[index] && !rowIsActive
            let shouldCollapse = hasChildren[index]
                && !isSearching
                && collapsedThreadKeys.contains(key)
                && !descendantContainsActiveTab
            let hiddenDescendantCount = shouldCollapse ? max(0, subtreeSizes[index] - 1) : 0
            hiddenDescendantTotal += hiddenDescendantCount
            // Subtract the parent's own attention (if any) — the parent row
            // keeps its own indicator and we only want to report attention
            // hidden *beneath* the collapsed chevron.
            let selfAttention = attentionByTabID[rows[index].tabID] != nil ? 1 : 0
            let hiddenAttentionCount = shouldCollapse
                ? max(0, subtreeAttentionCounts[index] - selfAttention)
                : 0

            displayedRows.append(sidebarRow(
                rows[index],
                threadKey: key,
                hasThreadChildren: hasChildren[index],
                isThreadCollapsed: shouldCollapse,
                hiddenThreadDescendantCount: hiddenDescendantCount,
                hiddenThreadDescendantAttentionCount: hiddenAttentionCount,
                threadActivityDate: subtreeActivityDates[index]
            ))

            guard shouldCollapse, hiddenDescendantCount > 0 else { continue }
            let firstDescendantIndex = index + 1
            let endIndex = min(rows.count, firstDescendantIndex + hiddenDescendantCount)
            for descendantIndex in firstDescendantIndex ..< endIndex {
                hiddenByCollapsedAncestor[descendantIndex] = true
            }
        }
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(
                "sidebar.threadCollapse",
                startMS: startMS,
                fields: [
                    "collapsedThreadKeyCount": String(collapsedThreadKeys.count),
                    "displayedRowCount": String(displayedRows.count),
                    "hasCurrentTab": String(currentTabID != nil),
                    "hiddenDescendantTotal": String(hiddenDescendantTotal),
                    "inputRowCount": String(rows.count),
                    "searchActive": String(isSearching),
                    "source": source
                ]
            )
        #endif
        return displayedRows
    }

    private func sidebarThreadActivityDate(for row: SidebarSession) -> Date {
        row.lastUserMessageAt ?? row.activityDate
    }

    private func sidebarRow(
        _ row: SidebarSession,
        threadKey: AgentSidebarThreadKey,
        hasThreadChildren: Bool,
        isThreadCollapsed: Bool,
        hiddenThreadDescendantCount: Int,
        hiddenThreadDescendantAttentionCount: Int,
        threadActivityDate: Date
    ) -> SidebarSession {
        SidebarSession(
            id: row.id,
            tabID: row.tabID,
            title: row.title,
            lastUserMessageAt: row.lastUserMessageAt,
            activityDate: row.activityDate,
            isPinned: row.isPinned,
            sessionID: row.sessionID,
            parentSessionID: row.parentSessionID,
            depth: row.depth,
            isMCPControlled: row.isMCPControlled,
            worktree: row.worktree,
            worktreeMergeAttention: row.worktreeMergeAttention,
            threadKey: threadKey,
            hasThreadChildren: hasThreadChildren,
            isThreadCollapsed: isThreadCollapsed,
            hiddenThreadDescendantCount: hiddenThreadDescendantCount,
            hiddenThreadDescendantAttentionCount: hiddenThreadDescendantAttentionCount,
            threadActivityDate: threadActivityDate
        )
    }

    func effectiveSidebarVisibleSessionCount(
        filteredSessions: [SidebarSession],
        currentTabID: UUID?,
        visibleSessionCount: Int? = nil
    ) -> Int {
        #if DEBUG
            let startMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let requestedVisibleCount = max(0, visibleSessionCount ?? sessionSidebarVisibleSessionCount)
        let activeIndex: Int?
        let result: Int
        if let currentTabID,
           let foundActiveIndex = filteredSessions.firstIndex(where: { $0.tabID == currentTabID })
        {
            activeIndex = foundActiveIndex
            result = min(filteredSessions.count, max(requestedVisibleCount, foundActiveIndex + 1))
        } else {
            activeIndex = nil
            result = min(filteredSessions.count, requestedVisibleCount)
        }
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(
                "sidebar.visibleCount.effective",
                startMS: startMS,
                fields: [
                    "activeIndex": activeIndex.map(String.init) ?? "n/a",
                    "currentTabID": AgentModePerfDiagnostics.shortID(currentTabID),
                    "effectiveVisibleCount": String(result),
                    "expandedForActive": String(result > requestedVisibleCount),
                    "filteredCount": String(filteredSessions.count),
                    "requestedVisibleCount": String(requestedVisibleCount)
                ]
            )
        #endif
        return result
    }

    func effectiveSidebarVisibleSessionCount(
        for tabs: [ComposeTabState],
        currentTabID: UUID?,
        searchText: String? = nil,
        visibleSessionCount: Int? = nil
    ) -> Int {
        let filtered = filteredSidebarSessions(
            for: tabs,
            currentTabID: currentTabID,
            searchText: searchText
        )
        return effectiveSidebarVisibleSessionCount(
            filteredSessions: filtered,
            currentTabID: currentTabID,
            visibleSessionCount: visibleSessionCount
        )
    }

    func pagedSidebarSessions(
        filteredSessions: [SidebarSession],
        currentTabID: UUID?,
        visibleSessionCount: Int? = nil
    ) -> [SidebarSession] {
        let limit = effectiveSidebarVisibleSessionCount(
            filteredSessions: filteredSessions,
            currentTabID: currentTabID,
            visibleSessionCount: visibleSessionCount
        )
        return Array(filteredSessions.prefix(limit))
    }

    func pagedSidebarSessions(
        for tabs: [ComposeTabState],
        currentTabID: UUID?,
        searchText: String? = nil,
        visibleSessionCount: Int? = nil
    ) -> [SidebarSession] {
        let filtered = filteredSidebarSessions(
            for: tabs,
            currentTabID: currentTabID,
            searchText: searchText
        )
        return pagedSidebarSessions(
            filteredSessions: filtered,
            currentTabID: currentTabID,
            visibleSessionCount: visibleSessionCount
        )
    }

    func sessionSidebarOrderedTabIDs(
        for tabs: [ComposeTabState],
        currentTabID: UUID?,
        searchText: String? = nil
    ) -> [UUID] {
        filteredSidebarSessions(
            for: tabs,
            currentTabID: currentTabID,
            searchText: searchText
        )
        .map(\.tabID)
    }

    func adjacentSidebarSessionTabID(
        from activeTabID: UUID?,
        forward: Bool,
        in tabs: [ComposeTabState],
        currentTabID: UUID?,
        searchText: String? = nil,
        visibleSessionCount: Int? = nil
    ) -> UUID? {
        let orderedTabIDs = pagedSidebarSessions(
            for: tabs,
            currentTabID: currentTabID,
            searchText: searchText,
            visibleSessionCount: visibleSessionCount
        )
        .map(\.tabID)
        guard !orderedTabIDs.isEmpty else { return nil }
        guard orderedTabIDs.count > 1 else { return orderedTabIDs.first }
        guard let activeTabID,
              let currentIndex = orderedTabIDs.firstIndex(of: activeTabID)
        else {
            return forward ? orderedTabIDs.first : orderedTabIDs.last
        }
        let offset = forward ? 1 : -1
        let nextIndex = (currentIndex + offset + orderedTabIDs.count) % orderedTabIDs.count
        return orderedTabIDs[nextIndex]
    }

    func sessionSidebarShortcutTabID(
        at index: Int,
        in tabs: [ComposeTabState],
        currentTabID: UUID?,
        searchText: String? = nil,
        visibleSessionCount: Int? = nil
    ) -> UUID? {
        guard index >= 0 else { return nil }
        let pagedSessions = pagedSidebarSessions(
            for: tabs,
            currentTabID: currentTabID,
            searchText: searchText,
            visibleSessionCount: visibleSessionCount
        )
        guard index < pagedSessions.count else { return nil }
        return pagedSessions[index].tabID
    }

    func adjacentParentSidebarSessionTabID(
        from activeTabID: UUID?,
        forward: Bool,
        in tabs: [ComposeTabState]
    ) -> UUID? {
        Self.adjacentParentSidebarSessionTabID(
            from: activeTabID,
            forward: forward,
            rows: sidebarSessions(for: tabs)
        )
    }

    static func adjacentParentSidebarSessionTabID(
        from activeTabID: UUID?,
        forward: Bool,
        rows: [SidebarSession]
    ) -> UUID? {
        let rootIndices = rows.indices.filter { rows[$0].depth == 0 }
        guard !rootIndices.isEmpty else { return nil }
        guard rootIndices.count > 1 else {
            let rootIndex = rootIndices[0]
            let rootTabID = rows[rootIndex].tabID
            guard let activeTabID,
                  let activeIndex = rows.firstIndex(where: { $0.tabID == activeTabID })
            else {
                return rootTabID
            }
            return activeIndex == rootIndex ? nil : rootTabID
        }
        guard let activeTabID,
              let activeIndex = rows.firstIndex(where: { $0.tabID == activeTabID })
        else {
            return rows[forward ? rootIndices[0] : rootIndices[rootIndices.count - 1]].tabID
        }

        let currentRootOrdinal = rootIndices.lastIndex(where: { $0 <= activeIndex }) ?? 0
        let offset = forward ? 1 : -1
        let nextRootOrdinal = (currentRootOrdinal + offset + rootIndices.count) % rootIndices.count
        return rows[rootIndices[nextRootOrdinal]].tabID
    }

    /// Deterministic ordering for the Agent Mode tab sidebar fallback.
    func sortTabsForSessionSidebar(_ tabs: [ComposeTabState]) -> [ComposeTabState] {
        let sortDates = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, sessionListSortDate(for: $0.id)) })
        let originalOrder = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.id, $0) })
        let useFrozenRestoreOrder = shouldFreezeSidebarOrdering(for: tabs)
        let baseSortedTabs = tabs.sorted { lhs, rhs in
            let lhsIndex = originalOrder[lhs.id] ?? .max
            let rhsIndex = originalOrder[rhs.id] ?? .max
            if useFrozenRestoreOrder {
                let lhsFrozenIndex = frozenSidebarOrderIndex(for: lhs.id, fallback: lhsIndex)
                let rhsFrozenIndex = frozenSidebarOrderIndex(for: rhs.id, fallback: rhsIndex)
                if lhsFrozenIndex != rhsFrozenIndex {
                    return lhsFrozenIndex < rhsFrozenIndex
                }
            }

            let lhsDate = sortDates[lhs.id] ?? nil
            let rhsDate = sortDates[rhs.id] ?? nil
            switch (lhsDate, rhsDate) {
            case let (lhsDate?, rhsDate?):
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }

            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return prefixedPinnedTabs(baseSortedTabs)
    }

    func computeLastUserMessageDate(in items: [AgentChatItem]) -> Date? {
        Self.computeLastUserMessageDateNonisolated(in: items)
    }

    private nonisolated static func computeLastUserMessageDateNonisolated(in items: [AgentChatItem]) -> Date? {
        AgentTranscriptIO.lastUserInteractionDate(in: items)
    }
}

// MARK: - Worktree visual indicators

@MainActor
extension AgentModeViewModel {
    /// Worktree visual indicators for the Agent session bound to `tabID`, in
    /// binding order. Reads live-session bindings when available, otherwise the
    /// persisted session index entry so restored sessions still resolve.
    func worktreeIndicators(forTabID tabID: UUID) -> [AgentWorktreeIndicator] {
        AgentWorktreeIndicatorResolver.indicators(for: worktreeBindingSummaries(forTabID: tabID))
    }

    /// Worktree indicators for `tabID` keyed by logical workspace-root path.
    /// Both the raw and standardized path forms are inserted so callers can
    /// match a workspace root row regardless of how its path was recorded.
    func worktreeIndicatorsByLogicalRootPath(forTabID tabID: UUID) -> [String: AgentWorktreeIndicator] {
        var map: [String: AgentWorktreeIndicator] = [:]
        for indicator in worktreeIndicators(forTabID: tabID) {
            let raw = indicator.logicalRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            map[raw] = indicator
            map[URL(fileURLWithPath: raw).standardizedFileURL.path] = indicator
        }
        return map
    }

    private func worktreeBindingSummaries(forTabID tabID: UUID) -> [AgentSessionWorktreeBindingSummary] {
        if let liveSession = sessions[tabID], !liveSession.worktreeBindings.isEmpty {
            return liveSession.worktreeBindings.worktreeBindingSummaries
        }
        return preferredSidebarEntry(for: tabID)?.worktreeBindingSummaries ?? []
    }

    /// Worktree merge attentions for `tabID` keyed by logical workspace-root
    /// paths. The active merge attention is attached to every root that is
    /// either bound as the merge source or whose path matches the merge target
    /// worktree path so the workspace roots section can render a `MERGE → X`
    /// capsule without layout jitter.
    func worktreeMergeAttentionsByLogicalRootPath(forTabID tabID: UUID) -> [String: AgentWorktreeMergeAttention] {
        let operations = worktreeMergeOperations(forTabID: tabID)
        guard let attention = AgentWorktreeMergeBlockerSelector.sidebarAttention(in: operations) else {
            return [:]
        }
        let bindings = worktreeBindingSummaries(forTabID: tabID)
        var map: [String: AgentWorktreeMergeAttention] = [:]
        let registerPath: (String) -> Void = { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            map[trimmed] = attention
            map[URL(fileURLWithPath: trimmed).standardizedFileURL.path] = attention
        }
        for binding in bindings {
            registerPath(binding.logicalRootPath)
        }
        registerPath(attention.targetPath)
        return map
    }

    private func worktreeMergeOperations(forTabID tabID: UUID) -> [AgentSessionWorktreeMergeOperation] {
        if let liveSession = sessions[tabID], !liveSession.worktreeMergeOperations.isEmpty {
            return liveSession.worktreeMergeOperations
        }
        return []
    }
}
