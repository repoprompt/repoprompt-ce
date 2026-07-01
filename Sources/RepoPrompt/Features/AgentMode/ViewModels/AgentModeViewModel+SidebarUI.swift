import SwiftUI

@MainActor
extension AgentModeViewModel {
    func syncSidebarUIState(
        refresh: Bool = false,
        reason: SidebarRefreshReason = .explicit,
        sidebarTabs: [ComposeTabState]? = nil
    ) {
        #if DEBUG
            let syncStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
            let storeUpdateStartMS = syncStartMS
        #endif
        ui.sessionSidebar.update(
            searchText: sessionSidebarSearchText,
            visibleSessionCount: sessionSidebarVisibleSessionCount
        )
        #if DEBUG
            let storeUpdateDurationMS = storeUpdateStartMS.map { AgentModePerfDiagnostics.elapsedMS(since: $0) }
            func emitSidebarSync(
                result: String,
                fingerprintDurationMS: Double? = nil,
                fingerprint: AgentSessionSidebarContentFingerprint? = nil,
                fingerprintDelta: AgentSidebarFingerprintDeltaDiagnostics? = nil
            ) {
                guard let syncStartMS else { return }
                var fields: [String: String] = [
                    "currentTabID": AgentModePerfDiagnostics.shortID(currentTabID),
                    "fingerprintDuration": fingerprintDurationMS.map { AgentModePerfDiagnostics.formatMS($0) } ?? "n/a",
                    "reason": reason.rawValue,
                    "refresh": String(refresh),
                    "result": result,
                    "sessionCount": String(sessions.count),
                    "sessionIndexCount": String(sessionIndex.count),
                    "sortDateCount": String(sessionListSortDates.count),
                    "storeUpdateDuration": storeUpdateDurationMS.map { AgentModePerfDiagnostics.formatMS($0) } ?? "n/a",
                    "total": AgentModePerfDiagnostics.formatElapsedMS(since: syncStartMS)
                ]
                if let fingerprint {
                    fields["sessionSignatureCount"] = String(fingerprint.sessionSignatures.count)
                    fields["tabMetadataCount"] = String(fingerprint.tabMetadataSignatures.count)
                } else {
                    fields["sessionSignatureCount"] = "n/a"
                    fields["tabMetadataCount"] = String(sidebarTabs?.count ?? sidebarContentFingerprintTabs.count)
                }
                if let fingerprintDelta {
                    fields.merge(fingerprintDelta.eventFields) { _, new in new }
                }
                AgentModePerfDiagnostics.event("sidebar.sync", fields: fields)
            }
        #endif
        guard refresh else {
            #if DEBUG
                emitSidebarSync(result: "snapshotOnly")
            #endif
            return
        }

        #if DEBUG
            let fingerprintStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let nextFingerprint = makeSessionSidebarContentFingerprint(for: sidebarTabs)
        #if DEBUG
            let fingerprintDurationMS = fingerprintStartMS.map { AgentModePerfDiagnostics.elapsedMS(since: $0) }
            let fingerprintDelta = nextFingerprint.debugDeltaDiagnostics(from: lastSidebarContentFingerprint)
        #endif
        if let previous = lastSidebarContentFingerprint, previous == nextFingerprint {
            #if DEBUG
                AgentModePerfDiagnostics.increment("store.sessionSidebar.refreshSkipped")
                var skipFields = ["reason": reason.rawValue]
                skipFields.merge(fingerprintDelta.eventFields) { _, new in new }
                AgentModePerfDiagnostics.event(
                    "store.sessionSidebar.refreshSkipped",
                    fields: skipFields
                )
                emitSidebarSync(
                    result: "skippedDuplicate",
                    fingerprintDurationMS: fingerprintDurationMS,
                    fingerprint: nextFingerprint,
                    fingerprintDelta: fingerprintDelta
                )
            #endif
            return
        }
        lastSidebarContentFingerprint = nextFingerprint
        #if DEBUG
            var publishFields = ["reason": reason.rawValue]
            publishFields.merge(fingerprintDelta.eventFields) { _, new in new }
            AgentModePerfDiagnostics.event(
                "store.sessionSidebar.refreshPublished",
                fields: publishFields
            )
        #endif
        ui.sessionSidebar.refresh()
        #if DEBUG
            emitSidebarSync(
                result: "published",
                fingerprintDurationMS: fingerprintDurationMS,
                fingerprint: nextFingerprint,
                fingerprintDelta: fingerprintDelta
            )
        #endif
    }

    func setSessionSidebarSearchText(_ text: String) {
        guard sessionSidebarSearchText != text else { return }
        sessionSidebarSearchText = text
    }

    func clearSessionSidebarSearchText() {
        setSessionSidebarSearchText("")
    }

    func showMoreSidebarSessions() {
        sessionSidebarVisibleSessionCount += Self.sessionSidebarPageSize
        syncSidebarUIState()
    }

    func sidebarSearchBinding() -> Binding<String> {
        Binding(
            get: { [weak self] in self?.ui.sessionSidebar.snapshot.searchText ?? "" },
            set: { [weak self] text in self?.setSessionSidebarSearchText(text) }
        )
    }

    enum SidebarCollapseAllState: Equatable {
        case hidden
        case canCollapse
        case canExpand
    }

    func sidebarCollapseAllState(
        for tabs: [ComposeTabState],
        currentTabID: UUID?,
        searchText: String,
        diagnosticSource: String? = nil
    ) -> SidebarCollapseAllState {
        #if DEBUG
            let startMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let source = diagnosticSource ?? "unknown"
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys: [AgentSidebarThreadKey]
        let state: SidebarCollapseAllState
        if trimmedSearch.isEmpty {
            keys = collapsibleSidebarThreadKeys(
                for: tabs,
                currentTabID: currentTabID,
                searchText: searchText,
                diagnosticSource: source
            )
            if keys.isEmpty {
                state = .hidden
            } else {
                let collapsedThreadKeys = ui.sessionSidebar.snapshot.collapsedThreadKeys
                let allCollapsed = keys.allSatisfy { collapsedThreadKeys.contains($0) }
                state = allCollapsed ? .canExpand : .canCollapse
            }
        } else {
            keys = []
            state = .hidden
        }
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(
                "sidebar.collapseAllState",
                startMS: startMS,
                fields: [
                    "currentTabID": AgentModePerfDiagnostics.shortID(currentTabID),
                    "keyCount": String(keys.count),
                    "searchActive": String(!trimmedSearch.isEmpty),
                    "source": source,
                    "state": String(describing: state)
                ]
            )
        #endif
        return state
    }

    func collapseAllSidebarThreads(for tabs: [ComposeTabState], currentTabID: UUID?) {
        let keys = collapsibleSidebarThreadKeys(
            for: tabs,
            currentTabID: currentTabID,
            searchText: ui.sessionSidebar.snapshot.searchText,
            diagnosticSource: "collapseAllButton.applyCollapse"
        )
        for key in keys {
            ui.sessionSidebar.setThreadCollapsed(true, for: key)
        }
    }

    func expandAllSidebarThreads(for tabs: [ComposeTabState], currentTabID: UUID?) {
        let keys = collapsibleSidebarThreadKeys(
            for: tabs,
            currentTabID: currentTabID,
            searchText: "",
            diagnosticSource: "collapseAllButton.applyExpand"
        )
        ui.sessionSidebar.expandAllSidebarThreads(eligibleKeys: keys)
    }

    func isSidebarThreadCollapsed(_ key: AgentSidebarThreadKey) -> Bool {
        ui.sessionSidebar.isThreadCollapsed(key)
    }

    func setSidebarThreadCollapsed(_ collapsed: Bool, for key: AgentSidebarThreadKey) {
        ui.sessionSidebar.setThreadCollapsed(collapsed, for: key)
    }

    func toggleSidebarThreadCollapse(_ key: AgentSidebarThreadKey) {
        ui.sessionSidebar.toggleThreadCollapse(key)
    }

    // MARK: - Sidebar run-state attention

    //
    // SEARCH-HELPER: Sidebar, Attention, UnseenBadge, RunState, Completed,
    // Failed, Waiting, BackgroundRun
    //
    // Flow:
    // 1. Provider coordinators (Claude / Codex / headless ACP / cancel path)
    //    mutate `session.runState` and then call `requestUIRefresh(tabID:)`
    //    or `updateBindingsFromSession(_:)`. That makes the run-state
    //    transition visible to the sidebar.
    // 2. `observeSidebarRunStateTransition(for:)` is invoked from those central
    //    routing points. It compares the session's new state against the last
    //    observed state in `sidebarObservedRunStateByTabID` and marks unseen
    //    attention on `AgentSessionSidebarUIStore` when the new state is
    //    attention-eligible AND the tab is not the current tab.
    // 3. Interaction paths — `onTabChanged(_:)`, `setAgentRunActive(_:isActive:true)`,
    //    and the row hover "dismiss" action — call
    //    `acknowledgeSidebarRunAttention(tabID:)` to clear the badge.
    // 4. Tab close / stash cleanup calls `cleanupSidebarRunAttention(tabIDs:)`
    //    so we don't keep stale entries for tabs that no longer exist.

    func observeSidebarRunStateTransition(for session: TabSession) {
        let tabID = session.tabID
        let newState = session.runState
        let oldState = sidebarObservedRunStateByTabID[tabID]
        guard oldState != newState else { return }

        // Seed on first observation so restored persisted sessions don't show
        // an unseen badge just because we're seeing their run state for the
        // first time this VM's lifetime.
        guard let oldState else {
            sidebarObservedRunStateByTabID[tabID] = newState
            return
        }

        sidebarObservedRunStateByTabID[tabID] = newState

        // A resumed/started run supersedes any stale terminal badge for the
        // same tab — the old "completed in background" has been acknowledged
        // by the user kicking off a new turn.
        if newState == .running {
            let didPublishClear = ui.sessionSidebar.clearRunStateAttention(tabID: tabID)
            if !didPublishClear, oldState != .running {
                // Make sure the sidebar row picks up the new running arc even
                // if no attention clear was needed.
                syncSidebarUIState(refresh: true, reason: .runState)
            }
            return
        }

        // The user is already looking at this tab — no unseen badge needed.
        if tabID == currentTabID {
            _ = ui.sessionSidebar.clearRunStateAttention(tabID: tabID)
            return
        }

        if AgentSessionSidebarUIStore.isAttentionEligible(newState) {
            _ = ui.sessionSidebar.markRunStateAttention(tabID: tabID, state: newState)
            return
        }

        // Non-attention state (e.g. idle, cancelled). Drop any stale badge but
        // don't force a separate refresh — the ordinary run-state refresh
        // path already handles row updates for these transitions.
        _ = ui.sessionSidebar.clearRunStateAttention(tabID: tabID)
    }

    /// Clear unseen-run-state attention for the given tab, typically because
    /// the user has opened/selected/resumed it or explicitly dismissed the
    /// badge. Safe to call for tabs without an active badge.
    func acknowledgeSidebarRunAttention(tabID: UUID) {
        _ = ui.sessionSidebar.clearRunStateAttention(tabID: tabID)
    }

    /// User-initiated dismissal from the row hover action. Behaves the same as
    /// acknowledging on selection but exists as a distinct entry point so
    /// future UI callers (and diagnostics) can distinguish intentional
    /// dismissal from incidental selection.
    func dismissSidebarRunAttention(tabID: UUID) {
        _ = ui.sessionSidebar.clearRunStateAttention(tabID: tabID)
    }

    /// Remove observed-state entries and pending attention badges for tabs
    /// that are going away. Called from `handleComposeTabsWillClose(...)`.
    func cleanupSidebarRunAttention(tabIDs: Set<UUID>) {
        guard !tabIDs.isEmpty else { return }
        for tabID in tabIDs {
            sidebarObservedRunStateByTabID.removeValue(forKey: tabID)
        }
        _ = ui.sessionSidebar.clearRunStateAttention(for: tabIDs)
    }

    /// Captures the current VM-level sidebar inputs (compose tab titles/metadata,
    /// sessions, sessionIndex, sort dates, badges, tree state, current tab, etc.)
    /// into a value-type fingerprint. Snapshotting every `TabSession` into
    /// `AgentSessionSidebarTabSignature` keeps the fingerprint equatable and
    /// independent of class identity.
    func makeSessionSidebarContentFingerprint(for sidebarTabs: [ComposeTabState]? = nil) -> AgentSessionSidebarContentFingerprint {
        let tabs = sidebarTabs ?? sidebarContentFingerprintTabs
        let tabMetadataSignatures: [AgentSessionSidebarTabMetadataSignature] = tabs
            .enumerated()
            .map { index, tab in
                AgentSessionSidebarTabMetadataSignature(
                    tabID: tab.id,
                    order: index,
                    normalizedName: AgentSessionRestoreSupport.normalizedSessionTitle(tab.name),
                    activeAgentSessionID: tab.activeAgentSessionID,
                    isPinned: tab.isPinned,
                    lastModified: tab.lastModified
                )
            }
        let signatures: [AgentSessionSidebarTabSignature] = sessions
            .keys
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { tabID -> AgentSessionSidebarTabSignature? in
                guard let session = sessions[tabID] else { return nil }
                return AgentSessionSidebarTabSignature(
                    tabID: session.tabID,
                    activeAgentSessionID: session.activeAgentSessionID,
                    parentSessionID: session.parentSessionID,
                    hasLoadedPersistedState: session.hasLoadedPersistedState,
                    itemsIsEmpty: session.items.isEmpty,
                    runState: session.runState,
                    lastActivityAt: session.lastActivityAt,
                    lastUserMessageAt: session.lastUserMessageAt
                )
            }
        return AgentSessionSidebarContentFingerprint(
            currentTabID: currentTabID,
            sessionListCacheReady: ownerValidatedSessionListCacheReady,
            tabsWithActiveAgentRun: tabsWithActiveAgentRun,
            mcpControlledTabIDs: mcpControlledTabIDs,
            tabMetadataSignatures: tabMetadataSignatures,
            sessionSignatures: signatures,
            sessionIndex: ownerValidatedSessionIndex,
            sessionListSortDates: ownerValidatedSessionListSortDates,
            sidebarRestoreFrozenOrderByTabID: ownerValidatedSidebarRestoreFrozenOrderByTabID
        )
    }
}

#if DEBUG
    struct AgentSidebarFingerprintDeltaDiagnostics: Equatable {
        let categories: [String]
        let changedSessionSignatureCount: Int
        let changedSessionLastActivityCount: Int
        let changedSessionLastUserMessageCount: Int
        let changedSessionRunStateCount: Int
        let changedTabMetadataCount: Int
        let changedTabLastModifiedCount: Int
        let changedTabNameCount: Int
        let sessionIndexChanged: Bool
        let sortDatesChanged: Bool

        var eventFields: [String: String] {
            [
                "fingerprintDeltaCategories": categories.joined(separator: ","),
                "fingerprintChangedSessionSignatures": String(changedSessionSignatureCount),
                "fingerprintChangedSessionLastActivity": String(changedSessionLastActivityCount),
                "fingerprintChangedSessionLastUserMessage": String(changedSessionLastUserMessageCount),
                "fingerprintChangedSessionRunState": String(changedSessionRunStateCount),
                "fingerprintChangedTabMetadata": String(changedTabMetadataCount),
                "fingerprintChangedTabLastModified": String(changedTabLastModifiedCount),
                "fingerprintChangedTabName": String(changedTabNameCount),
                "fingerprintSessionIndexChanged": String(sessionIndexChanged),
                "fingerprintSortDatesChanged": String(sortDatesChanged)
            ]
        }
    }

    extension AgentModeViewModel.AgentSessionSidebarContentFingerprint {
        func debugDeltaDiagnostics(
            from previous: AgentModeViewModel.AgentSessionSidebarContentFingerprint?
        ) -> AgentSidebarFingerprintDeltaDiagnostics {
            guard let previous else { return Self.makeDebugDelta(categories: ["initial"]) }
            guard previous != self else { return Self.makeDebugDelta(categories: ["none"]) }

            var categories = Set<String>()
            if previous.currentTabID != currentTabID { categories.insert("currentTabID") }
            if previous.sessionListCacheReady != sessionListCacheReady { categories.insert("sessionListCacheReady") }
            if previous.tabsWithActiveAgentRun != tabsWithActiveAgentRun { categories.insert("tabsWithActiveAgentRun") }
            if previous.mcpControlledTabIDs != mcpControlledTabIDs { categories.insert("mcpControlledTabIDs") }
            if previous.sidebarRestoreFrozenOrderByTabID != sidebarRestoreFrozenOrderByTabID { categories.insert("sidebarRestoreFrozenOrder") }

            let tabChanges = debugTabMetadataChanges(from: previous, categories: &categories)
            let sessionChanges = debugSessionSignatureChanges(from: previous, categories: &categories)
            let sessionIndexChanged = previous.sessionIndex != sessionIndex
            let sortDatesChanged = previous.sessionListSortDates != sessionListSortDates
            if sessionIndexChanged { categories.insert("sessionIndex") }
            if sortDatesChanged { categories.insert("sessionListSortDates") }

            return AgentSidebarFingerprintDeltaDiagnostics(
                categories: Self.orderedCategories(from: categories),
                changedSessionSignatureCount: sessionChanges.changedSignatureCount,
                changedSessionLastActivityCount: sessionChanges.changedLastActivityCount,
                changedSessionLastUserMessageCount: sessionChanges.changedLastUserMessageCount,
                changedSessionRunStateCount: sessionChanges.changedRunStateCount,
                changedTabMetadataCount: tabChanges.changedMetadataCount,
                changedTabLastModifiedCount: tabChanges.changedLastModifiedCount,
                changedTabNameCount: tabChanges.changedNameCount,
                sessionIndexChanged: sessionIndexChanged,
                sortDatesChanged: sortDatesChanged
            )
        }

        private struct DebugTabMetadataChanges {
            var changedMetadataCount = 0
            var changedLastModifiedCount = 0
            var changedNameCount = 0
        }

        private struct DebugSessionSignatureChanges {
            var changedSignatureCount = 0
            var changedLastActivityCount = 0
            var changedLastUserMessageCount = 0
            var changedRunStateCount = 0
        }

        private static func makeDebugDelta(categories: [String]) -> AgentSidebarFingerprintDeltaDiagnostics {
            AgentSidebarFingerprintDeltaDiagnostics(
                categories: categories,
                changedSessionSignatureCount: 0,
                changedSessionLastActivityCount: 0,
                changedSessionLastUserMessageCount: 0,
                changedSessionRunStateCount: 0,
                changedTabMetadataCount: 0,
                changedTabLastModifiedCount: 0,
                changedTabNameCount: 0,
                sessionIndexChanged: false,
                sortDatesChanged: false
            )
        }

        private func debugTabMetadataChanges(
            from previous: AgentModeViewModel.AgentSessionSidebarContentFingerprint,
            categories: inout Set<String>
        ) -> DebugTabMetadataChanges {
            var changes = DebugTabMetadataChanges()
            if previous.tabMetadataSignatures.count != tabMetadataSignatures.count { categories.insert("tabMetadata.count") }
            if previous.tabMetadataSignatures.map(\.tabID) != tabMetadataSignatures.map(\.tabID) { categories.insert("tabMetadata.order") }

            let previousByID = Dictionary(uniqueKeysWithValues: previous.tabMetadataSignatures.map { ($0.tabID, $0) })
            let currentByID = Dictionary(uniqueKeysWithValues: tabMetadataSignatures.map { ($0.tabID, $0) })
            for tabID in Set(previousByID.keys).union(currentByID.keys) {
                guard let previousTab = previousByID[tabID], let currentTab = currentByID[tabID] else {
                    changes.changedMetadataCount += 1
                    continue
                }
                var changed = false
                if previousTab.order != currentTab.order { categories.insert("tabMetadata.order")
                    changed = true
                }
                if previousTab.normalizedName != currentTab.normalizedName {
                    categories.insert("tabMetadata.name")
                    changes.changedNameCount += 1
                    changed = true
                }
                if previousTab.activeAgentSessionID != currentTab.activeAgentSessionID { categories.insert("tabMetadata.activeAgentSessionID")
                    changed = true
                }
                if previousTab.isPinned != currentTab.isPinned { categories.insert("tabMetadata.isPinned")
                    changed = true
                }
                if previousTab.lastModified != currentTab.lastModified {
                    categories.insert("tabMetadata.lastModified")
                    changes.changedLastModifiedCount += 1
                    changed = true
                }
                if changed { changes.changedMetadataCount += 1 }
            }
            return changes
        }

        private func debugSessionSignatureChanges(
            from previous: AgentModeViewModel.AgentSessionSidebarContentFingerprint,
            categories: inout Set<String>
        ) -> DebugSessionSignatureChanges {
            var changes = DebugSessionSignatureChanges()
            if previous.sessionSignatures.count != sessionSignatures.count { categories.insert("session.count") }

            let previousByID = Dictionary(uniqueKeysWithValues: previous.sessionSignatures.map { ($0.tabID, $0) })
            let currentByID = Dictionary(uniqueKeysWithValues: sessionSignatures.map { ($0.tabID, $0) })
            for tabID in Set(previousByID.keys).union(currentByID.keys) {
                guard let previousSession = previousByID[tabID], let currentSession = currentByID[tabID] else {
                    changes.changedSignatureCount += 1
                    continue
                }
                var changed = false
                if previousSession.activeAgentSessionID != currentSession.activeAgentSessionID { categories.insert("session.activeAgentSessionID")
                    changed = true
                }
                if previousSession.parentSessionID != currentSession.parentSessionID { categories.insert("session.parentSessionID")
                    changed = true
                }
                if previousSession.hasLoadedPersistedState != currentSession.hasLoadedPersistedState { categories.insert("session.hasLoadedPersistedState")
                    changed = true
                }
                if previousSession.itemsIsEmpty != currentSession.itemsIsEmpty { categories.insert("session.itemsIsEmpty")
                    changed = true
                }
                if previousSession.runState != currentSession.runState {
                    categories.insert("session.runState")
                    changes.changedRunStateCount += 1
                    changed = true
                }
                if previousSession.lastActivityAt != currentSession.lastActivityAt {
                    categories.insert("session.lastActivityAt")
                    changes.changedLastActivityCount += 1
                    changed = true
                }
                if previousSession.lastUserMessageAt != currentSession.lastUserMessageAt {
                    categories.insert("session.lastUserMessageAt")
                    changes.changedLastUserMessageCount += 1
                    changed = true
                }
                if changed { changes.changedSignatureCount += 1 }
            }
            return changes
        }

        private static func orderedCategories(from categories: Set<String>) -> [String] {
            let preferredOrder = [
                "currentTabID", "sessionListCacheReady", "tabsWithActiveAgentRun", "mcpControlledTabIDs",
                "tabMetadata.count", "tabMetadata.order", "tabMetadata.name", "tabMetadata.activeAgentSessionID",
                "tabMetadata.isPinned", "tabMetadata.lastModified", "session.count", "session.activeAgentSessionID",
                "session.parentSessionID", "session.hasLoadedPersistedState", "session.itemsIsEmpty", "session.runState",
                "session.lastActivityAt", "session.lastUserMessageAt", "sessionIndex", "sessionListSortDates",
                "sidebarRestoreFrozenOrder"
            ]
            return preferredOrder.filter(categories.contains) + categories.subtracting(preferredOrder).sorted()
        }
    }
#endif
