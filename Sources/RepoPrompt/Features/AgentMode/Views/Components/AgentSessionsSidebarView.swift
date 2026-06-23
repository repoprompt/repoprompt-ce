import SwiftUI

// MARK: - Sessions Sidebar

struct AgentModeSessionsSidebarView: View {
    let rootsStore: AgentWorkspaceRootsSidebarStore
    let agentModeVM: AgentModeViewModel
    @ObservedObject var sidebarUI: AgentSessionSidebarUIStore
    @ObservedObject var promptManager: PromptViewModel
    /// Plain `let` — this view only forwards the reference into the workspace
    /// roots section; it does not read any published state. Observing would
    /// invalidate the entire sessions sidebar on unrelated API settings
    /// changes (model lists, connection state, etc.).
    let apiSettingsVM: APISettingsViewModel
    let currentTabID: UUID?
    let onManageWorkspaces: () -> Void

    @State private var isCollapseAllThreadsButtonHovered = false
    @State private var isCollapseAllThreadsButtonFlashing = false
    @State private var collapseAllThreadsButtonClickTick = 0
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var searchHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 12)
    }

    private var searchVerticalPadding: CGFloat {
        fontPreset.scaledClamped(6, max: 9)
    }

    private var searchCornerRadius: CGFloat {
        fontPreset.scaledClamped(16, max: 20)
    }

    private var searchControlHeight: CGFloat {
        fontPreset.scaledClamped(30, min: 30, max: 40)
    }

    private var searchIconSize: CGFloat {
        fontPreset.scaledClamped(14, max: 18)
    }

    private var searchClearIconSize: CGFloat {
        fontPreset.scaledClamped(12, max: 16)
    }

    private var topBarSpacing: CGFloat {
        fontPreset.scaledClamped(4, max: 6)
    }

    private var topBarHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 12)
    }

    private var topBarVerticalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    private var collapseButtonHitSize: CGFloat {
        min(max(24, searchControlHeight), 32)
    }

    /// Worktree indicators for the active session, keyed by logical
    /// workspace-root path. Drives the `WT <label>` capsules on bound root
    /// rows. Empty when there is no active tab or it has no worktree bindings.
    private var worktreeIndicatorsByLogicalRootPath: [String: AgentWorktreeIndicator] {
        guard let currentTabID else { return [:] }
        return agentModeVM.worktreeIndicatorsByLogicalRootPath(forTabID: currentTabID)
    }

    /// Worktree merge attentions for the active session, keyed by logical
    /// workspace-root path. Drives the `MERGE → <target>` capsules on bound
    /// root rows. Empty when there is no active tab or no live merge.
    private var worktreeMergeAttentionsByLogicalRootPath: [String: AgentWorktreeMergeAttention] {
        guard let currentTabID else { return [:] }
        return agentModeVM.worktreeMergeAttentionsByLogicalRootPath(forTabID: currentTabID)
    }

    var body: some View {
        #if DEBUG
            let _ = Self.recordBodyMetric()
        #endif
        VStack(spacing: 0) {
            // Search box at top
            HStack(spacing: topBarSpacing) {
                sessionSearchBox
                    .frame(maxWidth: .infinity)
                collapseAllThreadsButton
            }
            .padding(.horizontal, topBarHorizontalPadding)
            .padding(.vertical, topBarVerticalPadding)
            .animation(.easeInOut(duration: 0.15), value: agentModeVM.sidebarCollapseAllState(
                for: promptManager.currentComposeTabs,
                currentTabID: currentTabID,
                searchText: sidebarUI.snapshot.searchText,
                diagnosticSource: "sidebarTopBar.animation"
            ))

            AgentModeSessionsListView(
                agentModeVM: agentModeVM,
                sidebarUI: sidebarUI,
                promptManager: promptManager,
                currentTabID: currentTabID
            )

            // Always-visible workspace roots section at bottom
            AgentWorkspaceRootsSectionView(
                rootsStore: rootsStore,
                promptManager: promptManager,
                apiSettingsVM: apiSettingsVM,
                onManageWorkspaces: onManageWorkspaces,
                worktreeIndicatorsByLogicalRootPath: worktreeIndicatorsByLogicalRootPath,
                worktreeMergeAttentionsByLogicalRootPath: worktreeMergeAttentionsByLogicalRootPath,
                branchSwitchActions: AgentWorkspaceBranchSwitchActions(
                    loadOptions: { row in
                        try await promptManager.gitViewModel.loadGitBranchSwitchOptions(forRootPath: row.fullPath)
                    },
                    preflight: { row, branchName in
                        try await promptManager.gitViewModel.preflightGitBranchSwitch(
                            branchName: branchName,
                            forRootPath: row.fullPath
                        )
                    },
                    switchBranch: { row, preflight in
                        try await agentModeVM.switchGitBranchFromWorkspaceRoot(
                            row,
                            preflight: preflight,
                            gitViewModel: promptManager.gitViewModel,
                            currentTabID: currentTabID
                        )
                    },
                    isAgentRunActive: {
                        agentModeVM.isAgentRunActive(tabID: currentTabID)
                    }
                )
            )
        }
    }

    @ViewBuilder
    private var collapseAllThreadsButton: some View {
        let tabs = promptManager.currentComposeTabs
        let search = sidebarUI.snapshot.searchText
        let state = agentModeVM.sidebarCollapseAllState(
            for: tabs,
            currentTabID: currentTabID,
            searchText: search,
            diagnosticSource: "collapseAllButton.body"
        )
        if state != .hidden {
            let tooltip = state == .canCollapse ? "Collapse all sub-agent threads" : "Expand all sub-agent threads"
            Button {
                collapseAllThreadsButtonClickTick &+= 1
                isCollapseAllThreadsButtonFlashing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    isCollapseAllThreadsButtonFlashing = false
                }
                withAnimation(.easeInOut(duration: 0.15)) {
                    switch agentModeVM.sidebarCollapseAllState(
                        for: tabs,
                        currentTabID: currentTabID,
                        searchText: sidebarUI.snapshot.searchText,
                        diagnosticSource: "collapseAllButton.action"
                    ) {
                    case .canCollapse:
                        agentModeVM.collapseAllSidebarThreads(for: tabs, currentTabID: currentTabID)
                    case .canExpand:
                        agentModeVM.expandAllSidebarThreads(for: tabs, currentTabID: currentTabID)
                    case .hidden:
                        break
                    }
                }
            } label: {
                Image(systemName: state == .canCollapse ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(collapseAllThreadsButtonColor)
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .symbolEffect(.bounce.down, value: collapseAllThreadsButtonClickTick)
                    .frame(width: collapseButtonHitSize, height: collapseButtonHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isCollapseAllThreadsButtonHovered = $0 }
            .hoverTooltip(tooltip)
            .accessibilityLabel(tooltip)
            .accessibilityHint("Double tap to toggle whether sub-agent chats are shown inline or collapsed under their parent.")
            .accessibilityAddTraits(.isButton)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    #if DEBUG
        private static func recordBodyMetric() {
            AgentModePerfDiagnostics.increment("ui.body.agentSessionsSidebar")
        }
    #endif

    private var collapseAllThreadsButtonColor: Color {
        if isCollapseAllThreadsButtonFlashing {
            return .accentColor
        }
        if isCollapseAllThreadsButtonHovered {
            return Color(NSColor.labelColor).opacity(0.85)
        }
        return Color(NSColor.secondaryLabelColor).opacity(0.6)
    }

    /// Search box for filtering sessions.
    private var sessionSearchBox: some View {
        HStack(spacing: fontPreset.scaledClamped(6, max: 8)) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Color(NSColor.labelColor).opacity(0.6))
                .font(.system(size: searchIconSize))

            TextField("Search", text: agentModeVM.sidebarSearchBinding())
                .textFieldStyle(PlainTextFieldStyle())
                .font(fontPreset.swiftUIFont(sizeAtNormal: 13))
                .foregroundColor(Color(NSColor.labelColor))
                .onKeyPress(.escape) {
                    if !sidebarUI.snapshot.searchText.isEmpty {
                        agentModeVM.clearSessionSidebarSearchText()
                        return .handled
                    }
                    return .ignored
                }

            if !sidebarUI.snapshot.searchText.isEmpty {
                Button(action: { agentModeVM.clearSessionSidebarSearchText() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: searchClearIconSize))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, searchHorizontalPadding)
        .padding(.vertical, searchVerticalPadding)
        .frame(minHeight: searchControlHeight)
        .background(Color.clear)
        .cornerRadius(searchCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: searchCornerRadius)
                .stroke(Color(NSColor.systemGray).opacity(0.75), lineWidth: 0.5)
        )
    }
}

// MARK: - Sessions List

struct AgentModeSessionsListView: View {
    let agentModeVM: AgentModeViewModel
    @ObservedObject var sidebarUI: AgentSessionSidebarUIStore
    @ObservedObject var promptManager: PromptViewModel
    let currentTabID: UUID?
    @State private var archivedSessionsExpanded = false
    @State private var showingClearArchivedConfirmation = false
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var listRowSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    private var listHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 12)
    }

    private var showMoreHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    private var showMoreVerticalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 12)
    }

    private var dividerVerticalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 12)
    }

    private var archivedHeaderSpacing: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    private var archivedHeaderHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    private var archivedHeaderBottomPadding: CGFloat {
        fontPreset.scaledClamped(4, max: 6)
    }

    private struct SidebarListSnapshot {
        let filteredSessions: [AgentModeViewModel.SidebarSession]
        let pagedSessions: [AgentModeViewModel.SidebarSession]
        let effectiveVisibleSessionCount: Int
        let archivedSessionTabsForHeader: [StashedTab]
        let sortedArchivedSessionTabsForRows: [StashedTab]
        let archivedDateInfoByStashedTabID: [UUID: AgentModeViewModel.SidebarSessionDateInfo]

        var hasMoreSessions: Bool {
            filteredSessions.count > effectiveVisibleSessionCount
        }

        var remainingSessionCount: Int {
            max(0, filteredSessions.count - effectiveVisibleSessionCount)
        }
    }

    /// Session-first sidebar list. Sessions remain stable regardless of tab switching.
    private var sidebarListSnapshot: SidebarListSnapshot {
        #if DEBUG
            let snapshotStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let sidebarSnapshot = sidebarUI.snapshot
        let filteredSessions = agentModeVM.filteredSidebarSessions(
            for: promptManager.currentComposeTabs,
            currentTabID: currentTabID,
            searchText: sidebarSnapshot.searchText,
            diagnosticSource: "listSnapshot"
        )
        let effectiveVisibleSessionCount = agentModeVM.effectiveSidebarVisibleSessionCount(
            filteredSessions: filteredSessions,
            currentTabID: currentTabID,
            visibleSessionCount: sidebarSnapshot.visibleSessionCount
        )
        let pagedSessions = agentModeVM.pagedSidebarSessions(
            filteredSessions: filteredSessions,
            currentTabID: currentTabID,
            visibleSessionCount: effectiveVisibleSessionCount
        )
        let archivedSessionTabs = agentModeVM.archivedSessionTabsForSidebarSnapshot(
            promptManager.currentStashedTabs,
            searchText: sidebarSnapshot.searchText,
            prepareSortedRows: archivedSessionsExpanded
        )
        let archivedSessionTabsForHeader = archivedSessionTabs.filteredTabs
        let sortedArchivedSessionTabsForRows = archivedSessionTabs.sortedTabs
        let snapshot = SidebarListSnapshot(
            filteredSessions: filteredSessions,
            pagedSessions: pagedSessions,
            effectiveVisibleSessionCount: effectiveVisibleSessionCount,
            archivedSessionTabsForHeader: archivedSessionTabsForHeader,
            sortedArchivedSessionTabsForRows: sortedArchivedSessionTabsForRows,
            archivedDateInfoByStashedTabID: archivedSessionTabs.dateInfoByStashedTabID
        )
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(
                "sidebar.listSnapshot",
                startMS: snapshotStartMS,
                fields: [
                    "archivedCount": String(archivedSessionTabsForHeader.count),
                    "archivedFilteredCount": String(archivedSessionTabsForHeader.count),
                    "archivedSortedCount": String(sortedArchivedSessionTabsForRows.count),
                    "archivedSortedPrepared": String(archivedSessionsExpanded),
                    "composeTabCount": String(promptManager.currentComposeTabs.count),
                    "currentTabID": AgentModePerfDiagnostics.shortID(currentTabID),
                    "effectiveVisibleSessionCount": String(effectiveVisibleSessionCount),
                    "filteredCount": String(filteredSessions.count),
                    "pagedCount": String(pagedSessions.count),
                    "searchActive": String(!sidebarSnapshot.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                    "stashedTabCount": String(promptManager.currentStashedTabs.count)
                ]
            )
        #endif
        return snapshot
    }

    var body: some View {
        #if DEBUG
            let _ = Self.recordBodyMetric()
        #endif
        let snapshot = sidebarListSnapshot
        let activeSections = AgentSidebarDateSectionBuilder.activeSections(for: snapshot.pagedSessions)
        let firstActiveSectionID = activeSections.first?.id
        ScrollView {
            VStack(spacing: listRowSpacing) {
                ForEach(activeSections) { section in
                    AgentSidebarDateSectionHeader(
                        title: section.bucket.title,
                        isFirst: section.id == firstActiveSectionID
                    )

                    ForEach(section.groups) { group in
                        ForEach(group.rows, id: \.id) { session in
                            AgentSessionRow(
                                title: session.title,
                                isActive: session.tabID == currentTabID,
                                isPinned: session.isPinned,
                                isMCPControlled: session.isMCPControlled,
                                runState: agentModeVM.runState(for: session.tabID),
                                isWaiting: agentModeVM.isTabWaiting(session.tabID),
                                attentionRunState: sidebarUI.snapshot.attentionRunStateByTabID[session.tabID],
                                worktree: session.worktree,
                                worktreeMergeAttention: session.worktreeMergeAttention,
                                threadDepth: session.depth,
                                hasThreadChildren: session.hasThreadChildren,
                                isThreadCollapsed: session.isThreadCollapsed,
                                hiddenThreadDescendantCount: session.hiddenThreadDescendantCount,
                                hiddenThreadDescendantAttentionCount: session.hiddenThreadDescendantAttentionCount,
                                onToggleThreadCollapse: session.hasThreadChildren
                                    ? {
                                        guard let key = session.threadKey else { return }
                                        agentModeVM.toggleSidebarThreadCollapse(key)
                                    }
                                    : nil,
                                onSelect: {
                                    Task { await promptManager.switchComposeTab(session.tabID) }
                                },
                                onTogglePin: {
                                    promptManager.toggleComposeTabPinned(session.tabID)
                                },
                                onStash: {
                                    Task { await promptManager.stashTab(session.tabID) }
                                },
                                onDelete: {
                                    #if DEBUG
                                        agentModeVM.debugBeginSidebarDeleteRequest(
                                            tabID: session.tabID,
                                            source: "AgentSessionsSidebarView.rowDelete",
                                            reason: "row_delete_confirmation"
                                        )
                                    #endif
                                    Task { await promptManager.closeComposeTab(session.tabID) }
                                },
                                onRename: { newName in
                                    Task {
                                        await agentModeVM.renameSession(tabID: session.tabID, to: newName)
                                    }
                                },
                                onDismissAttention: {
                                    agentModeVM.dismissSidebarRunAttention(tabID: session.tabID)
                                }
                            )
                        }
                    }
                }

                if snapshot.hasMoreSessions {
                    Button {
                        agentModeVM.showMoreSidebarSessions()
                    } label: {
                        Text("Show more (\(snapshot.remainingSessionCount))")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, showMoreHorizontalPadding)
                    .padding(.vertical, showMoreVerticalPadding)
                    .foregroundColor(.accentColor)
                }

                if !snapshot.archivedSessionTabsForHeader.isEmpty {
                    Divider()
                        .padding(.vertical, dividerVerticalPadding)

                    VStack(spacing: listRowSpacing) {
                        HStack(spacing: archivedHeaderSpacing) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    archivedSessionsExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: archivedHeaderSpacing) {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: fontPreset.scaledClamped(11, max: 14), weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .rotationEffect(.degrees(archivedSessionsExpanded ? 90 : 0))
                                        .animation(.easeInOut(duration: 0.15), value: archivedSessionsExpanded)
                                    Image(systemName: "archivebox")
                                        .font(.system(size: fontPreset.scaledClamped(13, max: 16)))
                                        .foregroundStyle(.secondary)
                                    Text("Archived Sessions")
                                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text("\(snapshot.archivedSessionTabsForHeader.count)")
                                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button("Clear…") {
                                showingClearArchivedConfirmation = true
                            }
                            .buttonStyle(.plain)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .popover(isPresented: $showingClearArchivedConfirmation, arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Clear archived sessions?")
                                        .font(.headline)
                                    Text("This removes \(snapshot.archivedSessionTabsForHeader.count) archived sessions from stashed tabs.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    HStack {
                                        Spacer()
                                        Button("Cancel") {
                                            showingClearArchivedConfirmation = false
                                        }
                                        Button("Clear") {
                                            showingClearArchivedConfirmation = false
                                            Task {
                                                await promptManager.deleteStashedTabs(withIDs: Set(snapshot.archivedSessionTabsForHeader.map(\.id)))
                                            }
                                        }
                                        .keyboardShortcut(.defaultAction)
                                    }
                                }
                                .padding()
                                .frame(width: 300)
                            }
                        }
                        .padding(.horizontal, archivedHeaderHorizontalPadding)
                        .padding(.bottom, archivedHeaderBottomPadding)

                        if archivedSessionsExpanded {
                            ArchivedSessionsPagedList(
                                allTabs: snapshot.sortedArchivedSessionTabsForRows,
                                isSearching: !sidebarUI.snapshot.searchText.isEmpty,
                                dateInfoByStashedTabID: snapshot.archivedDateInfoByStashedTabID,
                                agentModeVM: agentModeVM,
                                promptManager: promptManager
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, listHorizontalPadding)
        }
    }

    #if DEBUG
        private static func recordBodyMetric() {
            AgentModePerfDiagnostics.increment("ui.body.agentSessionsList")
        }
    #endif
}

/// Date-bucket section header used by the Agent Mode sidebar (`Today` /
/// `Yesterday` / `Previous`).
///
/// Visual language:
/// - Title-case label at 11pt `.medium` / `.secondary` so the separator reads
///   as structural navigation rather than a bold heading — it stays
///   subordinate to the top-level "Archived Sessions" label (12pt semibold)
///   and to active row titles (13pt regular/semibold).
/// - No hairline divider: groups are broken by whitespace alone to stay out
///   of the way of the rounded pill row backgrounds that dominate the list.
/// - `isFirst` collapses the top padding on the leading header so the search
///   box / "Archived Sessions" affordance above doesn't produce a double gap,
///   while subsequent headers get a deliberate breathing-room break.
private struct AgentSidebarDateSectionHeader: View {
    let title: String
    var isFirst: Bool = false
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var horizontalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    private var topPadding: CGFloat {
        isFirst ? fontPreset.scaledClamped(2, max: 3) : fontPreset.scaledClamped(14, max: 20)
    }

    private var bottomPadding: CGFloat {
        fontPreset.scaledClamped(4, max: 6)
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(nil)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

enum AgentSidebarDateSectionBucket: CaseIterable, Hashable, Identifiable {
    case today
    case yesterday
    case previous

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .today:
            "Today"
        case .yesterday:
            "Yesterday"
        case .previous:
            "Previous"
        }
    }

    static func bucket(
        for date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> AgentSidebarDateSectionBucket {
        let clampedDate = min(date, now)
        let todayStart = calendar.startOfDay(for: now)
        let dateStart = calendar.startOfDay(for: clampedDate)
        if dateStart == todayStart {
            return .today
        }
        if let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart),
           calendar.isDate(dateStart, inSameDayAs: yesterdayStart)
        {
            return .yesterday
        }
        return .previous
    }
}

struct AgentSidebarActiveDateGroup: Identifiable {
    let id: UUID
    let bucket: AgentSidebarDateSectionBucket
    let rows: [AgentModeViewModel.SidebarSession]
}

struct AgentSidebarActiveDateSection: Identifiable {
    let id: UUID
    let bucket: AgentSidebarDateSectionBucket
    let groups: [AgentSidebarActiveDateGroup]
}

struct AgentSidebarArchivedDateRow: Identifiable {
    let stashed: StashedTab
    let dateInfo: AgentModeViewModel.SidebarSessionDateInfo

    var id: UUID {
        stashed.id
    }
}

struct AgentSidebarArchivedDateSection: Identifiable {
    let id: UUID
    let bucket: AgentSidebarDateSectionBucket
    let rows: [AgentSidebarArchivedDateRow]
}

enum AgentSidebarDateSectionBuilder {
    static func activeSections(
        for rows: [AgentModeViewModel.SidebarSession],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [AgentSidebarActiveDateSection] {
        #if DEBUG
            let startMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let groups = activeGroups(for: rows, now: now, calendar: calendar)
        var sections: [AgentSidebarActiveDateSection] = []
        for group in groups {
            if let lastSection = sections.last, lastSection.bucket == group.bucket {
                sections[sections.count - 1] = AgentSidebarActiveDateSection(
                    id: lastSection.id,
                    bucket: lastSection.bucket,
                    groups: lastSection.groups + [group]
                )
            } else {
                sections.append(AgentSidebarActiveDateSection(
                    id: group.id,
                    bucket: group.bucket,
                    groups: [group]
                ))
            }
        }
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(
                "sidebar.dateSections.active",
                startMS: startMS,
                fields: [
                    "groupCount": String(groups.count),
                    "rowCount": String(rows.count),
                    "sectionCount": String(sections.count)
                ]
            )
        #endif
        return sections
    }

    static func activeGroups(
        for rows: [AgentModeViewModel.SidebarSession],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [AgentSidebarActiveDateGroup] {
        var groups: [AgentSidebarActiveDateGroup] = []
        var currentRows: [AgentModeViewModel.SidebarSession] = []

        func flushCurrentRows() {
            guard let firstRow = currentRows.first else { return }
            let date = currentRows
                .map { $0.threadActivityDate ?? $0.lastUserMessageAt ?? $0.activityDate }
                .max() ?? firstRow.activityDate
            let bucket = AgentSidebarDateSectionBucket.bucket(
                for: date,
                relativeTo: now,
                calendar: calendar
            )
            groups.append(AgentSidebarActiveDateGroup(
                id: firstRow.id,
                bucket: bucket,
                rows: currentRows
            ))
            currentRows.removeAll(keepingCapacity: true)
        }

        for row in rows {
            if row.depth == 0 {
                flushCurrentRows()
            }
            currentRows.append(row)
        }
        flushCurrentRows()
        return groups
    }

    static func archivedSections(
        for tabs: [StashedTab],
        now: Date = Date(),
        calendar: Calendar = .current,
        dateInfo: (StashedTab) -> AgentModeViewModel.SidebarSessionDateInfo
    ) -> [AgentSidebarArchivedDateSection] {
        #if DEBUG
            let startMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        var sections: [AgentSidebarArchivedDateSection] = []
        for stashed in tabs {
            let info = dateInfo(stashed)
            let bucketDate = info.lastEngagementAt ?? info.activityDate ?? stashed.stashedAt
            let bucket = AgentSidebarDateSectionBucket.bucket(
                for: bucketDate,
                relativeTo: now,
                calendar: calendar
            )
            let row = AgentSidebarArchivedDateRow(stashed: stashed, dateInfo: info)
            if let lastSection = sections.last, lastSection.bucket == bucket {
                sections[sections.count - 1] = AgentSidebarArchivedDateSection(
                    id: lastSection.id,
                    bucket: lastSection.bucket,
                    rows: lastSection.rows + [row]
                )
            } else {
                sections.append(AgentSidebarArchivedDateSection(
                    id: stashed.id,
                    bucket: bucket,
                    rows: [row]
                ))
            }
        }
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(
                "sidebar.dateSections.archived",
                startMS: startMS,
                fields: [
                    "rowCount": String(sections.reduce(0) { $0 + $1.rows.count }),
                    "sectionCount": String(sections.count),
                    "tabCount": String(tabs.count)
                ]
            )
        #endif
        return sections
    }
}

// MARK: - Archived Sessions Paged List

/// Paginated list of archived (stashed) agent sessions.
/// Owns its own page count so the parent view doesn't recompute on every page tap.
/// When `isSearching` is true, all matching tabs are shown without pagination.
struct ArchivedSessionsPagedList: View {
    let allTabs: [StashedTab]
    let isSearching: Bool
    let dateInfoByStashedTabID: [UUID: AgentModeViewModel.SidebarSessionDateInfo]
    let agentModeVM: AgentModeViewModel
    @ObservedObject var promptManager: PromptViewModel
    @State private var visibleCount = 20
    @ObservedObject private var fontScale = FontScaleManager.shared
    private static let pageSize = 20
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var rowSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    private var showMoreHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    private var showMoreVerticalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 12)
    }

    private var topPadding: CGFloat {
        fontPreset.scaledClamped(4, max: 6)
    }

    private var displayedTabs: ArraySlice<StashedTab> {
        isSearching ? allTabs[...] : allTabs.prefix(visibleCount)
    }

    private var hasMore: Bool {
        !isSearching && allTabs.count > visibleCount
    }

    var body: some View {
        #if DEBUG
            let _ = Self.recordBodyMetric()
        #endif
        let sections = AgentSidebarDateSectionBuilder.archivedSections(
            for: Array(displayedTabs),
            dateInfo: { stashed in
                dateInfoByStashedTabID[stashed.id] ?? agentModeVM.archivedSessionDateInfo(for: stashed)
            }
        )
        let firstSectionID = sections.first?.id
        VStack(spacing: rowSpacing) {
            ForEach(sections) { section in
                AgentSidebarDateSectionHeader(
                    title: section.bucket.title,
                    isFirst: section.id == firstSectionID
                )

                ForEach(section.rows) { row in
                    let stashed = row.stashed
                    AgentStashedSessionRow(
                        stashed: stashed,
                        onRestore: {
                            Task { await promptManager.unstashTab(stashed.id) }
                        },
                        onDelete: {
                            Task { await promptManager.deleteStashedTab(stashed.id) }
                        }
                    )
                }
            }

            if hasMore {
                Button {
                    visibleCount += Self.pageSize
                } label: {
                    Text("Show more (\(allTabs.count - visibleCount))")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, showMoreHorizontalPadding)
                .padding(.vertical, showMoreVerticalPadding)
                .foregroundColor(.accentColor)
            }
        }
        .padding(.top, topPadding)
    }

    #if DEBUG
        private static func recordBodyMetric() {
            AgentModePerfDiagnostics.increment("ui.body.archivedSessionsPagedList")
        }
    #endif
}
