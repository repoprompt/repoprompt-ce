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

private struct AgentSidebarSelectionRenderIdentity: Equatable {
    let workspaceID: UUID?
    let renderedOrder: [AgentSidebarSelectionIdentity]
}

/// Compact, evenly-sized pill used for the sidebar bulk-action row. Renders an
/// SF Symbol plus the affected-chat count and matches the app's plain,
/// `fontPreset`-scaled chip language rather than bordered system buttons.
private struct BulkActionChip: View {
    let systemImage: String
    let verb: String
    let count: Int
    var isDestructive = false
    var tooltip: String?
    let action: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var isHovered = false
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var cornerRadius: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    private var horizontalPadding: CGFloat {
        fontPreset.scaledClamped(6, max: 9)
    }

    private var verticalPadding: CGFloat {
        fontPreset.scaledClamped(5, max: 7)
    }

    private var iconSize: CGFloat {
        fontPreset.scaledClamped(11, max: 14)
    }

    private var fillColor: Color {
        if isDestructive {
            return Color.red.opacity(isHovered ? 0.22 : 0.12)
        }
        return Color(NSColor.labelColor).opacity(isHovered ? 0.14 : 0.07)
    }

    private var foreground: Color {
        if isDestructive { return .red }
        return isHovered ? Color(NSColor.labelColor) : .secondary
    }

    private var accessibilityText: String {
        "\(verb) \(count) \(count == 1 ? "chat" : "chats")"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .semibold))
                Text("\(count)")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fillColor)
            )
            .foregroundStyle(foreground)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .hoverTooltip(tooltip ?? verb)
        .accessibilityLabel(accessibilityText)
    }
}

struct AgentModeSessionsListView: View {
    let agentModeVM: AgentModeViewModel
    @ObservedObject var sidebarUI: AgentSessionSidebarUIStore
    @ObservedObject var promptManager: PromptViewModel
    let currentTabID: UUID?
    @State private var archivedSessionsExpanded = false
    @State private var showingClearArchivedConfirmation = false
    @State private var showingBulkDeleteConfirmation = false
    @AppStorage(SettingKeys.agentModeShowComposeTabsWithoutAgentSessions)
    private var showComposeTabsWithoutAgentSessions = false
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

    private var bulkBarRowSpacing: CGFloat {
        fontPreset.scaledClamped(8, max: 10)
    }

    private var bulkChipSpacing: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    private var bulkBarInnerHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    private var bulkBarInnerVerticalPadding: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    private var bulkBarCornerRadius: CGFloat {
        fontPreset.scaledClamped(12, max: 16)
    }

    var body: some View {
        #if DEBUG
            let _ = Self.recordBodyMetric()
        #endif
        let sidebarSnapshot = sidebarUI.snapshot
        let activeWorkspaceID = agentModeVM.workspaceManager?.activeWorkspaceID
        let workspaceSnapshot = promptManager.sidebarWorkspaceSnapshot.flatMap { snapshot in
            activeWorkspaceID == snapshot.workspaceID ? snapshot : nil
        }
        let snapshot = agentModeVM.sidebarListProjection(
            workspaceID: workspaceSnapshot?.workspaceID,
            composeTabs: workspaceSnapshot?.composeTabs ?? [],
            stashedTabs: workspaceSnapshot?.stashedTabs ?? [],
            currentTabID: currentTabID,
            sidebarSnapshot: sidebarSnapshot,
            archivedSessionsExpanded: archivedSessionsExpanded,
            showComposeTabsWithoutAgentSessions: showComposeTabsWithoutAgentSessions
        )
        let selectionRenderIdentity = AgentSidebarSelectionRenderIdentity(
            workspaceID: snapshot.workspaceID,
            renderedOrder: snapshot.renderedSelectionOrder
        )
        let defaultCollapseSeedKeys = snapshot.defaultCollapseSeedKeys
        let activeSections = AgentSidebarDateSectionBuilder.activeSections(for: snapshot.pagedSessions)
        let firstActiveSectionID = activeSections.first?.id
        let selectionState = sidebarUI.selectionState
        VStack(spacing: 4) {
            if selectionState.isSelectionMode {
                if let bulkTargets = agentModeVM.sidebarBulkMutationTargets(
                    selection: selectionState.selectedIdentities,
                    selectionWorkspaceID: selectionState.workspaceID,
                    projection: snapshot,
                    composeTabs: workspaceSnapshot?.composeTabs ?? [],
                    stashedTabs: workspaceSnapshot?.stashedTabs ?? []
                ) {
                    bulkActionBar(
                        selectionState: selectionState,
                        targets: bulkTargets,
                        renderedOrder: snapshot.renderedSelectionOrder
                    )
                }
            } else if let notice = selectionState.notice {
                bulkNotice(notice)
                    .padding(.horizontal, listHorizontalPadding)
                    .padding(.top, 4)
            }
            ScrollView {
                VStack(spacing: listRowSpacing) {
                    ForEach(activeSections) { section in
                        AgentSidebarDateSectionHeader(
                            title: section.bucket.title,
                            isFirst: section.id == firstActiveSectionID
                        )

                        ForEach(section.groups) { group in
                            ForEach(group.rows, id: \.id) { session in
                                let hasAgentSession = session.sessionID != nil
                                let runState: AgentSessionRunState = hasAgentSession
                                    ? agentModeVM.runState(for: session.tabID)
                                    : .idle
                                let attentionRunState: AgentSessionRunState? = hasAgentSession
                                    ? sidebarUI.snapshot.attentionRunStateByTabID[session.tabID]
                                    : nil
                                let toggleThreadAction: (() -> Void)? = session.hasThreadChildren
                                    ? { agentModeVM.requestSidebarThreadDisclosureToggle(for: session) }
                                    : nil
                                let stashAction: (() -> Void)? = session.canStash
                                    ? { performSingleActiveBulkAction(.stash, tabID: session.tabID, workspaceID: snapshot.workspaceID) }
                                    : nil
                                let dismissAttentionAction: (() -> Void)? = hasAgentSession
                                    ? {
                                        guard agentModeVM.workspaceManager?.activeWorkspaceID == snapshot.workspaceID else { return }
                                        agentModeVM.dismissSidebarRunAttention(tabID: session.tabID)
                                    }
                                    : nil

                                AgentSessionRow(
                                    title: session.title,
                                    isActive: session.tabID == currentTabID,
                                    isPinned: session.isPinned,
                                    isMCPControlled: session.isMCPControlled,
                                    runState: runState,
                                    attentionRunState: attentionRunState,
                                    worktree: session.worktree,
                                    worktreeMergeAttention: session.worktreeMergeAttention,
                                    threadDepth: session.depth,
                                    hasThreadChildren: session.hasThreadChildren,
                                    isThreadCollapsed: session.isThreadCollapsed,
                                    hiddenThreadDescendantCount: session.hiddenThreadDescendantCount,
                                    hiddenThreadDescendantAttentionCount: session.hiddenThreadDescendantAttentionCount,
                                    onToggleThreadCollapse: toggleThreadAction,
                                    isSelected: selectionState.selectedIdentities.contains(.active(tabID: session.tabID)),
                                    isSelectionMode: selectionState.isSelectionMode,
                                    isSelectionEnabled: selectionState.inFlightAction == nil,
                                    onSelectionGesture: { gesture in
                                        agentModeVM.handleSidebarSelectionGesture(
                                            gesture,
                                            identity: .active(tabID: session.tabID),
                                            renderedOrder: snapshot.renderedSelectionOrder,
                                            workspaceID: snapshot.workspaceID
                                        )
                                    },
                                    onSelect: {
                                        Task {
                                            guard agentModeVM.workspaceManager?.activeWorkspaceID == snapshot.workspaceID else { return }
                                            await promptManager.switchComposeTab(session.tabID)
                                        }
                                    },
                                    onTogglePin: {
                                        performSingleActiveBulkAction(
                                            session.isPinned ? .unpin : .pin,
                                            tabID: session.tabID,
                                            workspaceID: snapshot.workspaceID
                                        )
                                    },
                                    onStash: stashAction,
                                    onDelete: {
                                        #if DEBUG
                                            agentModeVM.debugBeginSidebarDeleteRequest(
                                                tabID: session.tabID,
                                                source: "AgentSessionsSidebarView.rowDelete",
                                                reason: "row_delete_confirmation"
                                            )
                                        #endif
                                        performSingleActiveBulkAction(.delete, tabID: session.tabID, workspaceID: snapshot.workspaceID)
                                    },
                                    onRename: { newName in
                                        guard agentModeVM.workspaceManager?.activeWorkspaceID == snapshot.workspaceID else { return }
                                        agentModeVM.renameSession(tabID: session.tabID, to: newName)
                                    },
                                    onDismissAttention: dismissAttentionAction,
                                    sessionIDCopyAction: .systemClipboard(sessionID: session.sessionID)
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
                                .disabled(selectionState.isSelectionMode)
                                .popover(isPresented: $showingClearArchivedConfirmation, arrowEdge: .bottom) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("Clear archived sessions?")
                                            .font(.headline)
                                        Text("This permanently deletes \(snapshot.archivedSessionTabsForHeader.count) archived sessions. Related active and archived sub-agent chats may also be deleted.")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        HStack {
                                            Spacer()
                                            Button("Cancel") {
                                                showingClearArchivedConfirmation = false
                                            }
                                            Button("Clear") {
                                                showingClearArchivedConfirmation = false
                                                guard let workspaceID = snapshot.workspaceID else { return }
                                                let archivedTargets = Set(snapshot.archivedSessionTabsForHeader.map {
                                                    PromptViewModel.ArchivedTabMutationTarget(
                                                        stashedTabID: $0.id,
                                                        tabID: $0.tab.id
                                                    )
                                                })
                                                performBulkAction(.delete, targets: .init(
                                                    workspaceID: workspaceID,
                                                    activeDeleteTabIDs: [],
                                                    archivedDeleteTargets: archivedTargets,
                                                    stashTabIDs: [],
                                                    pinTabIDs: [],
                                                    unpinTabIDs: []
                                                ))
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
                                ArchivedSessionsList(
                                    tabs: snapshot.pagedArchivedSessionTabsForRows,
                                    hasMore: snapshot.hasMoreArchivedSessions,
                                    remainingCount: snapshot.remainingArchivedSessionCount,
                                    dateInfoByStashedTabID: snapshot.archivedDateInfoByStashedTabID,
                                    sessionIDByStashedTabID: snapshot.archivedSessionIDByStashedTabID,
                                    workspaceID: snapshot.workspaceID,
                                    selectionState: selectionState,
                                    renderedOrder: snapshot.renderedSelectionOrder,
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
        .id(snapshot.workspaceID)
        .task(id: activeWorkspaceID) {
            showingClearArchivedConfirmation = false
            showingBulkDeleteConfirmation = false
        }
        .task(id: defaultCollapseSeedKeys) {
            agentModeVM.seedDefaultCollapsedSidebarThreads(defaultCollapseSeedKeys)
        }
        .task(id: selectionRenderIdentity) {
            sidebarUI.reconcileSelection(
                renderedOrder: selectionRenderIdentity.renderedOrder,
                workspaceID: selectionRenderIdentity.workspaceID
            )
            if snapshot.renderedSelectionOrder.isEmpty { showingBulkDeleteConfirmation = false }
        }
    }

    private func bulkActionBar(
        selectionState: AgentSidebarSelectionState,
        targets: AgentModeViewModel.SidebarBulkMutationTargets,
        renderedOrder: [AgentSidebarSelectionIdentity]
    ) -> some View {
        let selectedCount = selectionState.selectedIdentities.count
        let deleteCount = targets.activeDeleteTabIDs.count + targets.archivedDeleteTargets.count
        let isBusy = selectionState.inFlightAction != nil
        let canSelectAll = !isBusy && selectedCount != renderedOrder.count
        return VStack(alignment: .leading, spacing: bulkBarRowSpacing) {
            HStack(spacing: 8) {
                Text("\(selectedCount) selected")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button("Select All") {
                    sidebarUI.selectAll(renderedOrder: renderedOrder, workspaceID: targets.workspaceID)
                }
                .buttonStyle(.plain)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                .foregroundStyle(canSelectAll ? Color.accentColor : Color.secondary.opacity(0.5))
                .disabled(!canSelectAll)
                Button("Cancel") { sidebarUI.clearSelection() }
                    .buttonStyle(.plain)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                    .foregroundStyle(isBusy ? Color.secondary.opacity(0.5) : .secondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
            }

            if let operation = selectionState.inFlightAction {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(operation.kind.rawValue.capitalized) \(operation.targetCount) chats…")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: bulkChipSpacing) {
                    if !targets.pinTabIDs.isEmpty {
                        BulkActionChip(systemImage: "pin", verb: "Pin", count: targets.pinTabIDs.count) {
                            performBulkAction(.pin, targets: targets)
                        }
                    }
                    if !targets.unpinTabIDs.isEmpty {
                        BulkActionChip(systemImage: "pin.slash", verb: "Unpin", count: targets.unpinTabIDs.count) {
                            performBulkAction(.unpin, targets: targets)
                        }
                    }
                    if !targets.stashTabIDs.isEmpty {
                        BulkActionChip(
                            systemImage: "tray.and.arrow.down",
                            verb: "Stash",
                            count: targets.stashTabIDs.count,
                            tooltip: "Stash — related sub-agent chats may also be stashed"
                        ) {
                            performBulkAction(.stash, targets: targets)
                        }
                    }
                    BulkActionChip(
                        systemImage: "trash",
                        verb: "Delete",
                        count: deleteCount,
                        isDestructive: true
                    ) {
                        showingBulkDeleteConfirmation = true
                    }
                    .popover(isPresented: $showingBulkDeleteConfirmation, arrowEdge: .bottom) {
                        bulkDeleteConfirmation(targets: targets)
                    }
                }
            }

            if let notice = selectionState.notice { bulkNotice(notice) }
        }
        .padding(.horizontal, bulkBarInnerHorizontalPadding)
        .padding(.vertical, bulkBarInnerVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: bulkBarCornerRadius, style: .continuous)
                .fill(Color(NSColor.systemGray).opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: bulkBarCornerRadius, style: .continuous)
                        .stroke(Color(NSColor.systemGray).opacity(0.3), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, listHorizontalPadding)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func bulkDeleteConfirmation(targets: AgentModeViewModel.SidebarBulkMutationTargets) -> some View {
        let count = targets.activeDeleteTabIDs.count + targets.archivedDeleteTargets.count
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete \(count) chats?").font(.headline)
            Text("This permanently deletes \(targets.activeDeleteTabIDs.count) active chats and \(targets.archivedDeleteTargets.count) archived chats. Related sub-agent chats may also be removed. This cannot be undone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showingBulkDeleteConfirmation = false }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    showingBulkDeleteConfirmation = false
                    performBulkAction(.delete, targets: targets)
                }
            }
        }
        .padding()
        .frame(width: 340)
    }

    private func bulkNotice(_ notice: AgentSidebarBulkActionNotice) -> some View {
        let presentation: (icon: String, color: Color, accessibilityPrefix: String) = switch notice.severity {
        case .error:
            ("exclamationmark.triangle.fill", .red, "Error")
        case .warning:
            ("exclamationmark.triangle", .orange, "Warning")
        case .information:
            ("info.circle", .secondary, "Information")
        }
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: presentation.icon)
                .font(.system(size: fontPreset.scaledClamped(11, max: 14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                Text(notice.message).font(fontPreset.swiftUIFont(sizeAtNormal: 10))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(presentation.accessibilityPrefix): \(notice.title). \(notice.message)")
            Spacer(minLength: 0)
            Button { sidebarUI.dismissBulkActionNotice() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .font(.system(size: fontPreset.scaledClamped(10, max: 13)))
                .accessibilityLabel("Dismiss bulk action notice")
        }
        .foregroundStyle(presentation.color)
    }

    private func performSingleActiveBulkAction(
        _ action: AgentSidebarBulkActionKind,
        tabID: UUID,
        workspaceID: UUID?
    ) {
        guard let workspaceID else { return }
        performBulkAction(action, targets: .init(
            workspaceID: workspaceID,
            activeDeleteTabIDs: action == .delete ? [tabID] : [],
            archivedDeleteTargets: [],
            stashTabIDs: action == .stash ? [tabID] : [],
            pinTabIDs: action == .pin ? [tabID] : [],
            unpinTabIDs: action == .unpin ? [tabID] : []
        ))
    }

    private func performBulkAction(
        _ action: AgentSidebarBulkActionKind,
        targets: AgentModeViewModel.SidebarBulkMutationTargets
    ) {
        Task {
            await agentModeVM.performSidebarBulkAction(
                action,
                targets: targets,
                promptManager: promptManager
            )
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

// MARK: - Archived Sessions List

struct ArchivedSessionsList: View {
    let tabs: [StashedTab]
    let hasMore: Bool
    let remainingCount: Int
    let dateInfoByStashedTabID: [UUID: AgentModeViewModel.SidebarSessionDateInfo]
    let sessionIDByStashedTabID: [UUID: UUID]
    let workspaceID: UUID?
    let selectionState: AgentSidebarSelectionState
    let renderedOrder: [AgentSidebarSelectionIdentity]
    let agentModeVM: AgentModeViewModel
    @ObservedObject var promptManager: PromptViewModel
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private func deleteArchived(_ stashed: StashedTab) {
        guard let workspaceID else { return }
        let target = PromptViewModel.ArchivedTabMutationTarget(
            stashedTabID: stashed.id,
            tabID: stashed.tab.id
        )
        let targets = AgentModeViewModel.SidebarBulkMutationTargets(
            workspaceID: workspaceID,
            activeDeleteTabIDs: [],
            archivedDeleteTargets: [target],
            stashTabIDs: [],
            pinTabIDs: [],
            unpinTabIDs: []
        )
        Task {
            await agentModeVM.performSidebarBulkAction(.delete, targets: targets, promptManager: promptManager)
        }
    }

    var body: some View {
        let sections = AgentSidebarDateSectionBuilder.archivedSections(
            for: tabs,
            dateInfo: { dateInfoByStashedTabID[$0.id] ?? agentModeVM.archivedSessionDateInfo(for: $0) }
        )
        let firstSectionID = sections.first?.id
        VStack(spacing: fontPreset.scaledClamped(2, max: 3)) {
            ForEach(sections) { section in
                AgentSidebarDateSectionHeader(title: section.bucket.title, isFirst: section.id == firstSectionID)
                ForEach(section.rows) { row in
                    let stashed = row.stashed
                    let identity = AgentSidebarSelectionIdentity.archived(
                        stashedTabID: stashed.id,
                        tabID: stashed.tab.id
                    )
                    AgentStashedSessionRow(
                        stashed: stashed,
                        isSelected: selectionState.selectedIdentities.contains(identity),
                        isSelectionMode: selectionState.isSelectionMode,
                        isSelectionEnabled: selectionState.inFlightAction == nil,
                        onSelectionGesture: { gesture in
                            agentModeVM.handleSidebarSelectionGesture(
                                gesture,
                                identity: identity,
                                renderedOrder: renderedOrder,
                                workspaceID: workspaceID
                            )
                        },
                        onRestore: {
                            Task {
                                guard agentModeVM.workspaceManager?.activeWorkspaceID == workspaceID else { return }
                                await promptManager.unstashTab(stashed.id)
                            }
                        },
                        onDelete: { deleteArchived(stashed) },
                        sessionIDCopyAction: .systemClipboard(
                            sessionID: sessionIDByStashedTabID[stashed.id]
                        )
                    )
                }
            }
            if hasMore {
                Button {
                    agentModeVM.showMoreArchivedSidebarSessions()
                } label: {
                    Text("Show more (\(remainingCount))")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, fontPreset.scaledClamped(10, max: 14))
                .padding(.vertical, fontPreset.scaledClamped(8, max: 12))
                .foregroundColor(.accentColor)
            }
        }
        .padding(.top, fontPreset.scaledClamped(4, max: 6))
    }
}
