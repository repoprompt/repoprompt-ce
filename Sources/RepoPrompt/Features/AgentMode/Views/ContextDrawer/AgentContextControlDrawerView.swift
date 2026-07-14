import SwiftUI

private struct AgentContextDrawerSwitchKey: Equatable {
    let tabID: UUID?
    let activeAgentSessionID: UUID?
}

@MainActor
@discardableResult
func refreshSelectedFilesModelAfterTokenMetricsCompletion(
    request: AgentSelectedFilesModelRequest,
    coordinator: AgentSelectedFilesModelCoordinator
) -> AgentSelectedFilesRefreshOutcome? {
    coordinator.refreshAfterTokenMetricsCompletion(request)
}

struct AgentContextControlDrawerView: View {
    let drawerStore: AgentContextDrawerUIStore
    @ObservedObject var detailStore: AgentContextDrawerDetailStore
    let isPresented: Bool
    @ObservedObject var promptManager: PromptViewModel
    @ObservedObject var runtimeVM: AgentRuntimeSidebarViewModel
    let contextBuilderAgentVM: ContextBuilderAgentViewModel
    let oracleViewModel: OracleViewModel
    let selectionCoordinator: WorkspaceSelectionCoordinator
    let windowID: Int
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let worktreeBindingsProvider: @MainActor (UUID, UUID?) -> [AgentSessionWorktreeBinding]

    @StateObject private var modelCoordinator = AgentSelectedFilesModelCoordinator()
    @State private var hoveredTab: AgentContextDrawerUIStore.Tab?
    @State private var observedSwitchKey: AgentContextDrawerSwitchKey?
    @State private var selectedFilesBlankingIdentity: AgentSelectedFilesModelIdentity?
    @State private var tokenBlankingSelection: StoredSelection?
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var exportContext: AgentContextExportViewContext {
        AgentContextExportViewContext(
            promptManager: promptManager,
            selectionCoordinator: selectionCoordinator,
            currentTabID: currentTabID,
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingsProvider: worktreeBindingsProvider
        )
    }

    private var selectionSummary: AgentContextSelectionSummary {
        exportContext.selectionSummary
    }

    private var currentSwitchKey: AgentContextDrawerSwitchKey {
        AgentContextDrawerSwitchKey(
            tabID: currentTabID ?? promptManager.activeComposeTabID,
            activeAgentSessionID: activeAgentSessionID
        )
    }

    private var hasPendingSwitchKeyChange: Bool {
        guard let observedSwitchKey else { return false }
        return observedSwitchKey != currentSwitchKey
    }

    private var isSwitchBlankingSelectedFiles: Bool {
        hasPendingSwitchKeyChange || selectedFilesBlankingIdentity != nil
    }

    private var isSwitchBlankingTokenEstimate: Bool {
        tokenBlankingSelection != nil
    }

    private var resolvedFileCodemapCountSummary: AgentContextFileCodemapCountSummary? {
        modelCoordinator.loadedFileCodemapCountSummary(for: exportContext.modelRequestIdentity)
    }

    private var fileCodemapCountSummary: AgentContextFileCodemapCountSummary {
        resolvedFileCodemapCountSummary ?? AgentContextFileCodemapCountSummary.intent(from: selectionSummary)
    }

    private var fileCodemapCountReadiness: AgentContextFileCodemapCountReadiness {
        let identity = exportContext.modelRequestIdentity
        if hasPendingSwitchKeyChange { return unknownFileCodemapCountReadiness }
        if selectedFilesBlankingIdentity == identity {
            return modelCoordinator.displayedFileCodemapCountReadiness(for: identity) ?? unknownFileCodemapCountReadiness
        }
        if let displayedReadiness = modelCoordinator.displayedFileCodemapCountReadiness(for: identity) {
            return displayedReadiness
        }
        return AgentSelectedFilesModelCoordinator.unresolvedFileCodemapCountReadiness(
            for: identity,
            summary: fileCodemapCountSummary
        )
    }

    private var unknownFileCodemapCountReadiness: AgentContextFileCodemapCountReadiness {
        AgentContextFileCodemapCountReadiness(file: .unknown, codemap: .unknown)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            topTabs
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .clipped()
        .onAppear {
            if observedSwitchKey == nil {
                observedSwitchKey = currentSwitchKey
            }
            if isPresented {
                handleDrawerPresented()
            }
        }
        .onChange(of: isPresented) { _, isPresented in
            if isPresented {
                handleDrawerPresented()
                return
            }
            cleanupModelCoordinator()
        }
        .onChange(of: currentSwitchKey) { _, newKey in
            handleSwitchKeyChange(newKey)
        }
        .onReceive(exportContext.selectionChangesPublisher) { change in
            guard exportContext.tabMatchesSelectionChange(change) else { return }
            updateBlankingTargetsIfNeeded()
        }
        .onChange(of: exportContext.modelRequestIdentity) { _, _ in
            updateBlankingTargetsIfNeeded()
        }
        .onChange(of: modelCoordinator.isLoading) { _, _ in
            clearCompletedSelectedFilesBlankingIfNeeded()
        }
        .onReceive(promptManager.tokenCountingViewModel.tokenCalculationCompletedPublisher) { _ in
            handleTokenMetricsCompletion()
        }
        .onDisappear {
            cleanupModelCoordinator()
        }
    }

    private var topTabs: some View {
        HStack(spacing: 0) {
            topTabButton(tab: .files, title: "Selections") {
                selectionCountPill
            }
            topTabButton(tab: .prompt, title: "Prompt") {
                Image(systemName: "wand.and.stars")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
            }
            topTabButton(tab: .builder, title: "Context Builder") {
                Image(systemName: "sparkles")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.12))
    }

    /// Compact `files | codemaps` count pill shown before the Selections tab label.
    /// Resolved models use materialized row counts so this matches the Files/Codemaps subtabs.
    private var selectionCountPill: some View {
        let readiness = fileCodemapCountReadiness
        return HStack(spacing: 4) {
            countText(readiness.file)
                .foregroundColor(countForegroundColor(readiness.file))
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 1, height: fontPreset.scaledMetric(9))
            countText(readiness.codemap)
                .foregroundColor(codemapCountForegroundColor(readiness.codemap))
        }
        .font(fontPreset.captionFont.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private func countText(_ readiness: AgentContextCountReadiness) -> Text {
        switch readiness {
        case let .known(count):
            Text("\(count)")
        case .unknown:
            Text("—")
        }
    }

    private func countForegroundColor(_ readiness: AgentContextCountReadiness) -> Color? {
        switch readiness {
        case .known:
            nil
        case .unknown:
            Color.secondary
        }
    }

    private func codemapCountForegroundColor(_ readiness: AgentContextCountReadiness) -> Color? {
        switch readiness {
        case .known:
            Color.accentColor
        case .unknown:
            Color.secondary
        }
    }

    private func topTabButton(
        tab: AgentContextDrawerUIStore.Tab,
        title: String,
        @ViewBuilder leading: () -> some View
    ) -> some View {
        let isActive = detailStore.activeTab == tab
        let isHovered = hoveredTab == tab
        return Button {
            drawerStore.open(tab: tab)
        } label: {
            HStack(spacing: 5) {
                leading()
                Text(title)
                    .font(fontPreset.captionFont.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .padding(.horizontal, 6)
            .background(isHovered ? Color.primary.opacity(0.1) : Color.clear)
            .foregroundColor(isActive ? Color.accentColor : Color.secondary)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(height: isActive ? 2 : 1)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
            }
        }
        .buttonStyle(.plain)
        .disabled(isActive)
    }

    private func cleanupModelCoordinator() {
        if isSwitchBlankingSelectedFiles {
            modelCoordinator.cancelLoading(keepLoadedModel: false)
            return
        }
        modelCoordinator.cancelLoading(keepLoadedModel: true)
        guard !isSwitchBlankingTokenEstimate else { return }
        selectedFilesBlankingIdentity = nil
        tokenBlankingSelection = nil
        observedSwitchKey = currentSwitchKey
    }

    private func handleDrawerPresented() {
        if isSwitchBlankingSelectedFiles {
            beginSwitchBlanking(for: currentSwitchKey)
        } else {
            clearCompletedSelectedFilesBlankingIfNeeded()
            updateTokenBlankingSelectionIfNeeded()
        }
    }

    private func handleSwitchKeyChange(_ newKey: AgentContextDrawerSwitchKey) {
        guard isPresented else {
            modelCoordinator.cancelLoading(keepLoadedModel: false)
            return
        }
        beginSwitchBlanking(for: newKey)
    }

    private func beginSwitchBlanking(for newKey: AgentContextDrawerSwitchKey) {
        let request = exportContext.makeModelRequest(flushPendingUI: false)
        modelCoordinator.cancelLoading(keepLoadedModel: false)
        selectedFilesBlankingIdentity = request.identity
        captureTokenBlankingSelection()
        modelCoordinator.refreshIfNeeded(request, force: true, preserveDisplayedModel: false)
        observedSwitchKey = newKey
        clearCompletedSelectedFilesBlankingIfNeeded(currentIdentity: request.identity)
        clearCompletedTokenBlankingIfNeeded()
    }

    private func updateBlankingTargetsIfNeeded() {
        if isSwitchBlankingSelectedFiles {
            updateSwitchBlankingTargetIfNeeded()
        } else {
            updateTokenBlankingSelectionIfNeeded()
        }
    }

    private func updateSwitchBlankingTargetIfNeeded() {
        guard isPresented else { return }
        guard isSwitchBlankingSelectedFiles else { return }
        guard !hasPendingSwitchKeyChange else { return }
        let request = exportContext.makeModelRequest(flushPendingUI: false)
        let shouldRefreshTarget = selectedFilesBlankingIdentity != request.identity
        selectedFilesBlankingIdentity = request.identity
        captureTokenBlankingSelection()
        if shouldRefreshTarget {
            modelCoordinator.refreshIfNeeded(request, force: true, preserveDisplayedModel: false)
        }
        clearCompletedSelectedFilesBlankingIfNeeded(currentIdentity: request.identity)
        clearCompletedTokenBlankingIfNeeded()
    }

    private func updateTokenBlankingSelectionIfNeeded() {
        guard isPresented else { return }
        guard tokenBlankingSelection != nil else { return }
        captureTokenBlankingSelection()
        clearCompletedTokenBlankingIfNeeded()
    }

    private func captureTokenBlankingSelection() {
        tokenBlankingSelection = promptManager.tokenCountingViewModel.currentExpectedSelectionForPublishedSnapshot()
    }

    private func clearCompletedSelectedFilesBlankingIfNeeded(
        currentIdentity: AgentSelectedFilesModelIdentity? = nil
    ) {
        let identity = currentIdentity ?? exportContext.modelRequestIdentity
        guard selectedFilesBlankingIdentity == identity else { return }
        guard modelCoordinator.completedModelMatches(identity) else { return }
        selectedFilesBlankingIdentity = nil
    }

    private func handleTokenMetricsCompletion() {
        clearCompletedTokenBlankingIfNeeded()
        guard isPresented else { return }
        let request = exportContext.makeModelRequest(flushPendingUI: false)
        refreshSelectedFilesModelAfterTokenMetricsCompletion(
            request: request,
            coordinator: modelCoordinator
        )
    }

    private func clearCompletedTokenBlankingIfNeeded() {
        guard let tokenBlankingSelection else { return }
        let snapshot = promptManager.tokenCountingViewModel.latestPublishedTokenSnapshot(
            for: tokenBlankingSelection,
            scheduleRefreshIfNeeded: false
        )
        guard snapshot.isComplete, !snapshot.isStale, !snapshot.refreshPending else { return }
        self.tokenBlankingSelection = nil
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Compose")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 15, weight: .semibold))

            AgentContextDrawerTokenEstimatePill(
                tokenCounter: promptManager.tokenCountingViewModel,
                runtimeVM: runtimeVM,
                fontPreset: fontPreset,
                tokenBlankingSelection: tokenBlankingSelection
            )

            Spacer()

            Button {
                drawerStore.close()
            } label: {
                Image(systemName: "xmark")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .hoverTooltip("Close Compose")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch detailStore.activeTab {
        case .files:
            AgentContextDrawerFilesTab(
                detailStore: detailStore,
                modelCoordinator: modelCoordinator,
                exportContext: exportContext,
                isSwitchBlankingRows: isSwitchBlankingSelectedFiles
            )
        case .builder:
            AgentContextDrawerBuilderTab(
                contextBuilderAgentVM: contextBuilderAgentVM,
                oracleViewModel: oracleViewModel,
                windowID: windowID
            )
        case .prompt:
            AgentContextDrawerPromptTab(
                promptManager: promptManager,
                modelCoordinator: modelCoordinator,
                exportContext: exportContext,
                isSwitchBlankingSelectedFiles: isSwitchBlankingSelectedFiles
            )
        }
    }
}
