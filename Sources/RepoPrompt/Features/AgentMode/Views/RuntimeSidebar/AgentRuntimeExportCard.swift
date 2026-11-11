import Combine
import RepoPromptInstrumentation
import RepoPromptSettingsCore
import RepoPromptWorkspaceContext
import SwiftUI

@MainActor
private protocol AgentContextExportSourceView: View {
    var promptManager: PromptViewModel { get }
    var selectionCoordinator: WorkspaceSelectionCoordinator? { get }
    var currentTabID: UUID? { get }
    var activeAgentSessionID: UUID? { get }
    var worktreeBindingsProvider: (@MainActor (UUID, UUID?) -> [AgentSessionWorktreeBinding])? { get }
}

private extension AgentContextExportSourceView {
    func makeExportSource(flushPendingUI: Bool = true) -> AgentContextExportSource {
        let requestedTabID = currentTabID ?? promptManager.activeComposeTabID
        let selectionSnapshot = requestedTabID.flatMap {
            selectionCoordinator?.selectionSnapshot(for: $0, flushPendingUIIfActive: flushPendingUI)
        }
        return AgentContextExportSourceBuilder.makeSource(
            AgentContextExportSourceBuildRequest(
                requestedTabID: requestedTabID,
                activeComposeTabID: promptManager.activeComposeTabID,
                activePromptText: promptManager.promptText,
                selectionSnapshot: selectionSnapshot,
                composeTabs: promptManager.currentComposeTabs,
                explicitActiveAgentSessionID: activeAgentSessionID,
                worktreeBindingsProvider: { sessionID, tabID in
                    worktreeBindingsProvider?(sessionID, tabID) ?? []
                }
            )
        )
    }
}

@MainActor
private protocol AgentSelectedFilesManaging: AgentContextExportSourceView {
    var perfRecorder: any AgentModePerfRecording { get }
    var modelCoordinator: AgentSelectedFilesModelCoordinator { get }
    var activePopoverTab: AgentSelectedFilesTab { get }
    var exportComponent: String { get }
}

private extension AgentSelectedFilesManaging {
    func selectedFilesPopover(placeholderFileCount: Int, activeTab: Binding<AgentSelectedFilesTab>) -> some View {
        AgentSelectedFilesPopover(
            model: modelCoordinator.model,
            rowSplit: modelCoordinator.rowSplit,
            isLoading: modelCoordinator.isLoading,
            canMutateDisplayedModel: modelCoordinator.canMutateDisplayedModel,
            placeholderFileCount: placeholderFileCount,
            activeTab: activeTab,
            canMutate: selectionCoordinator != nil,
            onLoadContent: { row, purpose in
                guard let model = modelCoordinator.model else { return nil }
                return await loadRowContent(row, model: model, purpose: purpose)
            },
            onRemove: { row, model in remove(row, from: model) },
            onClear: { model in clearSelection(for: model) }
        )
    }

    func acceptSelectionChange(
        _ change: WorkspaceSelectionCoordinator.Change,
        isPresented: @autoclosure () -> Bool? = nil
    ) -> Bool {
        let tabID = currentTabID ?? selectionCoordinator?.activeTabID() ?? promptManager.activeComposeTabID
        var fields = AgentSelectedFilesDiagnostics.selectionFields(change.selection)
        fields["component"] = exportComponent
        fields["changeTabID"] = AgentSelectedFilesDiagnostics.shortID(change.tabID)
        fields["targetTabID"] = AgentSelectedFilesDiagnostics.shortID(tabID)
        if let isPresented = isPresented() {
            fields["isPresented"] = String(isPresented)
        }
        guard change.tabID == tabID else {
            fields["ignored"] = "tabMismatch"
            AgentSelectedFilesDiagnostics(perfRecorder: perfRecorder).event("view.selectionChange", fields: fields)
            return false
        }
        AgentSelectedFilesDiagnostics(perfRecorder: perfRecorder).event("view.selectionChange", fields: fields, includeStack: true)
        return true
    }

    var selectionChangesPublisher: AnyPublisher<WorkspaceSelectionCoordinator.Change, Never> {
        selectionCoordinator?.changes ?? Empty<WorkspaceSelectionCoordinator.Change, Never>(completeImmediately: false).eraseToAnyPublisher()
    }

    func makeModelRequest(flushPendingUI: Bool = true) -> AgentSelectedFilesModelRequest {
        let startMS = AgentSelectedFilesDiagnostics(perfRecorder: perfRecorder).timestampMSIfEnabled()
        let source = makeExportSource(flushPendingUI: flushPendingUI)
        let cfg = promptManager.resolvePromptContext(BuiltInCopyPresets.standard, custom: nil)
        let codeMapUsage = effectiveCodeMapUsage(for: activePopoverTab, configuredUsage: cfg.codeMapUsage)
        var fields = AgentSelectedFilesDiagnostics.sourceFields(source)
        fields["component"] = exportComponent
        fields["flushPendingUI"] = String(flushPendingUI)
        fields["activeTab"] = String(describing: activePopoverTab)
        fields["configuredCodeMapUsage"] = String(describing: cfg.codeMapUsage)
        fields["codeMapUsage"] = String(describing: codeMapUsage)
        fields.merge(AgentSelectedFilesDiagnostics(perfRecorder: perfRecorder).elapsedFields(since: startMS)) { _, new in new }
        AgentSelectedFilesDiagnostics(perfRecorder: perfRecorder).event("view.makeModelRequest", fields: fields)
        return AgentSelectedFilesModelRequest(
            identity: AgentSelectedFilesModelIdentity(
                exportContextIdentity: source.exportContextIdentity,
                filePathDisplay: promptManager.filePathDisplayOption,
                codeMapUsage: codeMapUsage
            ),
            source: source,
            store: promptManager.workspaceFileContextStore,
            filePathDisplay: promptManager.filePathDisplayOption,
            codeMapUsage: codeMapUsage,
            entryMetricsSnapshot: AgentSelectedFilesRequestMetricsSnapshotResolver.activeTokenMetricsSnapshot(
                source: source,
                promptManager: promptManager,
                codeMapUsage: codeMapUsage,
                filePathDisplay: promptManager.filePathDisplayOption
            )
        )
    }

    func effectiveCodeMapUsage(
        for activeTab: AgentSelectedFilesTab,
        configuredUsage: CodeMapUsage
    ) -> CodeMapUsage {
        activeTab == .codemaps ? configuredUsage : .none
    }

    func refreshExportModel(force: Bool = false, preserveDisplayedModel: Bool = false) {
        modelCoordinator.perfRecorder = perfRecorder
        let request = makeModelRequest(flushPendingUI: true)
        var fields = AgentSelectedFilesDiagnostics.requestFields(request)
        fields["component"] = exportComponent
        fields["force"] = String(force)
        fields["preserveDisplayedModel"] = String(preserveDisplayedModel)
        let outcome = modelCoordinator.refreshIfNeeded(
            request,
            force: force,
            preserveDisplayedModel: preserveDisplayedModel
        )
        fields["outcome"] = String(describing: outcome)
        AgentSelectedFilesDiagnostics(perfRecorder: perfRecorder).event("view.refresh", fields: fields, includeStack: true)
    }

    func loadRowContent(
        _ row: AgentContextExportRow,
        model: AgentContextExportModel,
        purpose: AgentContextExportRow.ContentPurpose
    ) async -> String? {
        await AgentContextExportResolver.loadRowContent(
            for: row,
            model: model,
            store: promptManager.workspaceFileContextStore,
            purpose: purpose
        )
    }

    func remove(_ row: AgentContextExportRow, from model: AgentContextExportModel) {
        guard row.canRemove else { return }
        Task {
            let latestSelection = await MainActor.run { self.latestSelection(for: model.source) }
            let updated = await AgentContextExportResolver.removeRow(
                row,
                from: latestSelection,
                lookupContext: model.lookupContext,
                store: promptManager.workspaceFileContextStore
            )
            await persistSelection(updated, source: model.source)
            await MainActor.run { refreshExportModel(force: true) }
        }
    }

    func clearSelection(for model: AgentContextExportModel) {
        Task {
            let latestSelection = await MainActor.run { self.latestSelection(for: model.source) }
            let updated = AgentContextExportResolver.removeSelectionSnapshot(model.source.selection, from: latestSelection)
            await persistSelection(updated, source: model.source)
            await MainActor.run { refreshExportModel(force: true) }
        }
    }

    @MainActor
    func latestSelection(for source: AgentContextExportSource) -> StoredSelection {
        guard let tabID = source.tabID else { return source.selection }
        if let snapshot = selectionCoordinator?.selectionSnapshot(for: tabID, flushPendingUIIfActive: true) {
            return snapshot.selection
        }
        return promptManager.currentComposeTabs.first { $0.id == tabID }?.selection ?? source.selection
    }

    @MainActor
    func persistSelection(_ selection: StoredSelection, source: AgentContextExportSource) async {
        guard let selectionCoordinator else { return }
        if let tabID = source.tabID,
           let workspaceID = selectionCoordinator.activeSelectionIdentity()?.workspaceID
        {
            _ = await selectionCoordinator.persistSelection(
                selection,
                for: WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID),
                source: .runtimeMutation
            )
        }
    }
}

struct AgentExportCard: View, AgentContextExportSourceView {
    @ObservedObject var promptManager: PromptViewModel
    @ObservedObject var tokenCounter: TokenCountingViewModel
    let selectionCoordinator: WorkspaceSelectionCoordinator?
    let fileCount: Int?
    let selectionTokens: Int?
    let showsFilesButton: Bool
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let worktreeBindingsProvider: (@MainActor (UUID, UUID?) -> [AgentSessionWorktreeBinding])?

    private var displayTokens: Int? {
        if let selectionTokens, selectionTokens > 0 {
            return selectionTokens
        }
        if fileCount != nil {
            return nil
        }
        let fallbackTokens = tokenCounter.copyContextTotalTokens
        return fallbackTokens > 0 ? fallbackTokens : nil
    }

    private var tokenColor: Color {
        guard let tokens = displayTokens else { return .secondary }
        if tokens > 100_000 { return .red }
        if tokens >= 60000 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Export Context")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)

                if let tokens = displayTokens {
                    Text("~\(AgentContextIndicator.formatTokens(tokens))")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(tokenColor)
                }

                Spacer()

                if showsFilesButton {
                    filesButton
                }

                Button {
                    let cfg = promptManager.resolvePromptContext(BuiltInCopyPresets.standard, custom: nil)
                    Task {
                        let clipboard = await buildAgentClipboard(for: cfg)
                        await MainActor.run {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(clipboard, forType: .string)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 10))
                        Text("Copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(CustomButtonStyle(
                    verticalPadding: 5,
                    horizontalPadding: 10,
                    height: 26
                ))
            }

            instructionsEditor
        }
    }

    // MARK: - Files Button

    private var filesButton: some View {
        AgentSelectedFilesPopoverTrigger(
            promptManager: promptManager,
            selectionCoordinator: selectionCoordinator,
            currentTabID: currentTabID,
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingsProvider: worktreeBindingsProvider,
            summaryOverride: nil
        ) { _ in
            HStack(spacing: 5) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Files")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
    }

    private func buildAgentClipboard(for cfg: PromptContextResolved) async -> String {
        let source = await MainActor.run { makeExportSource() }
        let lookupContext = await AgentContextExportResolver.lookupContext(
            source: source,
            store: promptManager.workspaceFileContextStore
        )
        let meta = await MainActor.run {
            promptManager.metaInstructions(for: cfg, selectedPromptIDsOverride: source.selectedMetaPromptIDs)
        }
        let reviewGitContext = await promptManager.freezePromptGitReviewContext(
            tabID: source.tabID,
            sessionID: source.activeAgentSessionID,
            bindings: source.worktreeBindings
        )
        let request = await MainActor.run {
            AgentContextClipboardRequest(
                cfg: cfg,
                source: source,
                store: promptManager.workspaceFileContextStore,
                lookupContext: lookupContext,
                filePathDisplay: promptManager.filePathDisplayOption,
                onlyIncludeRootsWithSelectedFiles: promptManager.onlyIncludeRootsWithSelectedFiles,
                showCodeMapMarkers: !promptManager.codeMapsGloballyDisabled,
                metaInstructions: meta,
                includeDatetimeInUserInstructions: promptManager.includeDatetimeInUserInstructions,
                promptSectionsOrder: promptManager.promptSectionsOrder,
                disabledPromptSections: promptManager.disabledPromptSections,
                duplicateUserInstructionsAtTop: promptManager.duplicateUserInstructionsAtTop,
                reviewGitContext: reviewGitContext,
                completeGitDiffProvider: {
                    await promptManager.gitViewModel.getDiffUsing(inclusionMode: .all, forceRefreshStatus: true) ?? ""
                }
            )
        }
        return await AgentContextExportResolver.buildClipboardContent(request)
    }

    // MARK: - Instructions Editor

    private static let placeholderText = """
    Tell the receiving model what to do with this context — e.g. "Plan a fix for the login crash" or "Help me debug the auth flow".

    Tip: Ask the agent to write this prompt for you.
    """

    private var instructionsEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $promptManager.promptText)
                .font(.system(size: 11))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 150, maxHeight: 150)

            if promptManager.promptText.isEmpty {
                Text(Self.placeholderText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .padding(6)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }
}

struct AgentSelectedFilesPopoverTrigger<Label: View>: View, AgentSelectedFilesManaging {
    fileprivate var exportComponent: String {
        "trigger"
    }

    @ObservedObject var promptManager: PromptViewModel
    let selectionCoordinator: WorkspaceSelectionCoordinator?
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let worktreeBindingsProvider: (@MainActor (UUID, UUID?) -> [AgentSessionWorktreeBinding])?
    let summaryOverride: AgentContextSelectionSummary?
    @ViewBuilder let label: (AgentContextSelectionSummary) -> Label

    @Environment(\.agentModePerfRecorder) fileprivate var perfRecorder
    @StateObject fileprivate var modelCoordinator = AgentSelectedFilesModelCoordinator()
    @State private var showSelectedFilesPopover = false
    @State fileprivate var activePopoverTab: AgentSelectedFilesTab = .files

    private var selectionSummary: AgentContextSelectionSummary {
        if let summaryOverride {
            return summaryOverride
        }
        return AgentContextExportResolver.selectionSummary(
            for: makeExportSource(flushPendingUI: false).selection
        )
    }

    var body: some View {
        let summary = selectionSummary
        let selectionCount = summary.totalExplicitFileCount

        Button {
            showSelectedFilesPopover.toggle()
        } label: {
            label(summary)
        }
        .buttonStyle(.plain)
        .hoverTooltip("View selected files: \(summary.headlineText)")
        .accessibilityLabel("View selected files: \(summary.compactText)")
        .accessibilityHint("Opens details for selected files and codemaps")
        .popover(isPresented: $showSelectedFilesPopover) {
            selectedFilesPopover(placeholderFileCount: selectionCount, activeTab: $activePopoverTab)
                .frame(width: 420)
                .frame(
                    minHeight: 124,
                    idealHeight: selectedFilesPopoverHeight(rowCount: modelCoordinator.model?.fileCount ?? selectionCount),
                    maxHeight: 440
                )
        }
        .onChange(of: activePopoverTab) { _, _ in
            guard showSelectedFilesPopover else { return }
            refreshExportModel(preserveDisplayedModel: true)
        }
        .onChange(of: showSelectedFilesPopover) { _, isPresented in
            AgentSelectedFilesDiagnostics(perfRecorder: perfRecorder).event(
                "trigger.popover.visibilityChanged",
                fields: ["isPresented": String(isPresented)],
                includeStack: true
            )
            if isPresented {
                activePopoverTab = .files
                refreshExportModel()
            } else {
                modelCoordinator.cancelLoading(keepLoadedModel: true)
            }
        }
        .onChange(of: currentTabID) { oldValue, newValue in
            AgentSelectedFilesDiagnostics(perfRecorder: perfRecorder).event(
                "trigger.currentTab.changed",
                fields: [
                    "old": AgentSelectedFilesDiagnostics.shortID(oldValue),
                    "new": AgentSelectedFilesDiagnostics.shortID(newValue)
                ],
                includeStack: true
            )
            resetOrRefreshExportModelForContextChange()
        }
        .onChange(of: activeAgentSessionID) { oldValue, newValue in
            AgentSelectedFilesDiagnostics(perfRecorder: perfRecorder).event(
                "trigger.activeSession.changed",
                fields: [
                    "old": AgentSelectedFilesDiagnostics.shortID(oldValue),
                    "new": AgentSelectedFilesDiagnostics.shortID(newValue)
                ],
                includeStack: true
            )
            resetOrRefreshExportModelForContextChange()
        }
        .onReceive(selectionChangesPublisher) { change in
            handleSelectionChange(change)
        }
    }

    private func selectedFilesPopoverHeight(rowCount: Int) -> Double {
        let visibleRows = min(max(rowCount, 3), 8)
        return min(440, Double(visibleRows) * 40 + 64)
    }

    private func resetOrRefreshExportModelForContextChange() {
        AgentSelectedFilesDiagnostics(perfRecorder: perfRecorder).event(
            "trigger.resetForContextChange",
            fields: ["isPresented": String(showSelectedFilesPopover)],
            includeStack: true
        )
        modelCoordinator.invalidate()
        if showSelectedFilesPopover {
            refreshExportModel()
        }
    }

    private func handleSelectionChange(_ change: WorkspaceSelectionCoordinator.Change) {
        guard acceptSelectionChange(change, isPresented: showSelectedFilesPopover) else { return }
        if showSelectedFilesPopover {
            refreshExportModel(preserveDisplayedModel: true)
        } else {
            modelCoordinator.invalidate()
        }
    }
}

struct AgentSelectedFilesInlineManager: View, AgentSelectedFilesManaging {
    fileprivate var exportComponent: String {
        "inline"
    }

    @ObservedObject var promptManager: PromptViewModel
    let selectionCoordinator: WorkspaceSelectionCoordinator?
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let worktreeBindingsProvider: (@MainActor (UUID, UUID?) -> [AgentSessionWorktreeBinding])?
    let summary: AgentContextSelectionSummary

    @Environment(\.agentModePerfRecorder) fileprivate var perfRecorder
    @StateObject fileprivate var modelCoordinator = AgentSelectedFilesModelCoordinator()
    @State fileprivate var activePopoverTab: AgentSelectedFilesTab = .files

    var body: some View {
        selectedFilesPopover(placeholderFileCount: summary.totalExplicitFileCount, activeTab: $activePopoverTab)
            .onAppear {
                modelCoordinator.perfRecorder = perfRecorder
                AgentSelectedFilesDiagnostics(perfRecorder: perfRecorder).event("inline.onAppear", includeStack: true)
                refreshExportModel()
            }
            .onChange(of: activePopoverTab) { _, _ in
                refreshExportModel(preserveDisplayedModel: true)
            }
            .onDisappear {
                AgentSelectedFilesDiagnostics(perfRecorder: perfRecorder).event("inline.onDisappear", includeStack: true)
                modelCoordinator.cancelLoading(keepLoadedModel: true)
            }
            .onChange(of: currentTabID) { oldValue, newValue in
                AgentSelectedFilesDiagnostics(perfRecorder: perfRecorder).event(
                    "inline.currentTab.changed",
                    fields: [
                        "old": AgentSelectedFilesDiagnostics.shortID(oldValue),
                        "new": AgentSelectedFilesDiagnostics.shortID(newValue)
                    ],
                    includeStack: true
                )
                resetAndRefreshExportModelForContextChange()
            }
            .onChange(of: activeAgentSessionID) { oldValue, newValue in
                AgentSelectedFilesDiagnostics(perfRecorder: perfRecorder).event(
                    "inline.activeSession.changed",
                    fields: [
                        "old": AgentSelectedFilesDiagnostics.shortID(oldValue),
                        "new": AgentSelectedFilesDiagnostics.shortID(newValue)
                    ],
                    includeStack: true
                )
                resetAndRefreshExportModelForContextChange()
            }
            .onReceive(selectionChangesPublisher) { change in
                handleSelectionChange(change)
            }
    }

    private func resetAndRefreshExportModelForContextChange() {
        AgentSelectedFilesDiagnostics(perfRecorder: perfRecorder).event("inline.resetForContextChange", includeStack: true)
        modelCoordinator.invalidate()
        refreshExportModel()
    }

    private func handleSelectionChange(_ change: WorkspaceSelectionCoordinator.Change) {
        guard acceptSelectionChange(change) else { return }
        refreshExportModel(preserveDisplayedModel: true)
    }
}

private struct AgentSelectedFilesPopover: View {
    let model: AgentContextExportModel?
    let rowSplit: AgentSelectedFilesRowSplit
    let isLoading: Bool
    let canMutateDisplayedModel: Bool
    let placeholderFileCount: Int
    @Binding var activeTab: AgentSelectedFilesTab
    let canMutate: Bool
    let onLoadContent: (AgentContextExportRow, AgentContextExportRow.ContentPurpose) async -> String?
    let onRemove: (AgentContextExportRow, AgentContextExportModel) -> Void
    let onClear: (AgentContextExportModel) -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    @StateObject private var previewCoordinator = AgentSelectedFilePreviewLoadCoordinator()

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            tabSwitcher(split: rowSplit)

            if isLoading, model == nil {
                loadingSkeletonRows(count: placeholderFileCount)
            } else if rowSplit.rows.isEmpty {
                agentSelectedFilesEmptyState(title: "No files selected", fontPreset: fontPreset)
            } else {
                let activeRows = rowSplit.rows(for: activeTab)
                if isLoading, activeTab == .codemaps, rowSplit.codemapRows.isEmpty {
                    loadingSkeletonRows(count: 2)
                } else if activeRows.isEmpty {
                    agentSelectedFilesEmptyState(title: activeTab == .files ? "No files in Agent context" : "No codemaps in Agent context", fontPreset: fontPreset)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(activeRows) { row in
                                AgentSelectedFileRow(
                                    row: row,
                                    canRemove: canMutateDisplayedRows && row.canRemove,
                                    previewCoordinator: previewCoordinator,
                                    onLoadContent: onLoadContent,
                                    onRemove: { row in
                                        guard let model else { return }
                                        onRemove(row, model)
                                    }
                                )
                            }
                        }
                        .padding(.trailing, 4)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .onAppear {
            adjustAgentSelectedFilesTab($activeTab, fileCount: rowSplit.fileRows.count, codemapCount: rowSplit.codemapRows.count)
        }
        .onChange(of: rowSplit.fileRows.count) { _, _ in
            adjustAgentSelectedFilesTab($activeTab, fileCount: rowSplit.fileRows.count, codemapCount: rowSplit.codemapRows.count)
        }
        .onChange(of: rowSplit.codemapRows.count) { _, _ in
            adjustAgentSelectedFilesTab($activeTab, fileCount: rowSplit.fileRows.count, codemapCount: rowSplit.codemapRows.count)
        }
        .onChange(of: activeTab) { _, _ in
            previewCoordinator.reconcileVisibleRows(rowSplit.rows(for: activeTab))
        }
        .onChange(of: rowSplit.rows.map(\.id)) { _, _ in
            previewCoordinator.reconcileVisibleRows(rowSplit.rows(for: activeTab))
        }
    }

    private func tabSwitcher(split: AgentSelectedFilesRowSplit) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 0) {
                agentSelectedFilesTabButton(icon: "doc.text", label: "Files", count: displayFileCount(split: split), isActive: activeTab == .files, fontPreset: fontPreset, padding: CGSize(width: 12, height: 7), minHeight: 32, inactiveLineOpacity: 0.18) {
                    activeTab = .files
                }
                agentSelectedFilesTabButton(icon: "square.grid.2x2", label: "Codemaps", count: split.codemapRows.count, isActive: activeTab == .codemaps, fontPreset: fontPreset, padding: CGSize(width: 12, height: 7), minHeight: 32, inactiveLineOpacity: 0.18) {
                    activeTab = .codemaps
                }
            }
            .frame(maxWidth: .infinity)

            clearButton(split: split)
        }
        .padding(.horizontal, -4)
        .padding(.bottom, 2)
    }

    private func clearButton(split: AgentSelectedFilesRowSplit) -> some View {
        Button {
            guard let model else { return }
            onClear(model)
        } label: {
            Text("Clear")
                .font(fontPreset.captionFont.weight(.medium))
        }
        .buttonStyle(CustomButtonStyle(verticalPadding: 3, horizontalPadding: 8))
        .disabled(split.rows.isEmpty || !canMutateDisplayedRows)
        .hoverTooltip(canMutate ? "Clear selection" : "Unavailable")
        .accessibilityHint(canMutate ? "Clear selection" : "Selection unavailable")
    }

    private var canMutateDisplayedRows: Bool {
        canMutate && canMutateDisplayedModel && model != nil
    }

    private func displayFileCount(split: AgentSelectedFilesRowSplit) -> Int {
        if isLoading, model == nil, placeholderFileCount > 0 {
            return placeholderFileCount
        }
        return split.fileRows.count
    }

    private func loadingSkeletonRows(count: Int) -> some View {
        let rowCount = min(max(count, 1), 6)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(0 ..< rowCount, id: \.self) { _ in
                HStack(spacing: 9) {
                    Circle()
                        .fill(Color.secondary.opacity(0.14))
                        .frame(width: 14, height: 14)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.16))
                            .frame(width: 170, height: 10)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.10))
                            .frame(width: 110, height: 8)
                    }
                    Spacer()
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .redacted(reason: .placeholder)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel("Loading selected files")
    }
}

private struct AgentSelectedFileRow: View, AgentSelectedFilePresenting {
    let row: AgentContextExportRow
    let canRemove: Bool
    @ObservedObject var previewCoordinator: AgentSelectedFilePreviewLoadCoordinator
    let onLoadContent: (AgentContextExportRow, AgentContextExportRow.ContentPurpose) async -> String?
    let onRemove: (AgentContextExportRow) -> Void

    @State var copyTask: Task<Void, Never>?
    @State var isCopying = false
    @State private var isHovered = false
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var disabledRemoveExplanation: String? {
        if !row.canRemove {
            return "Added via folder — remove the folder to drop this file"
        }
        if !canRemove {
            return "Unavailable"
        }
        return nil
    }

    var body: some View {
        presentingFilePreview {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: leadingIconName)
                    .symbolRenderingMode(.monochrome)
                    .foregroundColor(accentColor)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .medium))
                    .imageScale(.medium)
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: parentPathDisplay == nil ? 0 : 2) {
                    Text(row.displayName)
                        .font(fontPreset.standardFont.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)

                    if let parentPathDisplay {
                        Text(parentPathDisplay)
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .hoverTooltip(row.displayPath)
                .accessibilityLabel(row.displayPath)

                trailingControls
            }
            .padding(.horizontal, 7)
            .padding(.vertical, parentPathDisplay == nil ? 6 : 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color(NSColor.controlBackgroundColor).opacity(0.26) : Color(NSColor.controlBackgroundColor).opacity(0.10))
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
        }
    }

    private var trailingControls: some View {
        HStack(spacing: 3) {
            sliceCountIndicator
                .frame(width: 18, height: 26)

            AgentFileRowActionButton(
                systemName: "eye",
                tooltip: "Preview",
                rowIsHovered: isHovered,
                isLoading: previewCoordinator.isLoadingPreview(for: row),
                action: openPreview
            )

            AgentFileRowActionButton(
                systemName: "doc.on.doc",
                tooltip: "Copy contents",
                rowIsHovered: isHovered,
                isLoading: isCopying,
                isDisabled: isCopying,
                action: copyToClipboard
            )

            removeControl
        }
        .frame(width: 108, alignment: .trailing)
    }

    @ViewBuilder
    private var sliceCountIndicator: some View {
        if let sliceCountText {
            Text(sliceCountText)
                .font(fontPreset.captionFont.weight(.semibold).monospacedDigit())
                .foregroundColor(accentColor)
                .lineLimit(1)
                .accessibilityLabel("\(sliceCountText) selected slice ranges")
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var removeControl: some View {
        if let disabledRemoveExplanation {
            agentDisabledFileRemovalHint(fontSize: 13, isHovered: isHovered, explanation: disabledRemoveExplanation)
        } else {
            AgentFileRowActionButton(
                systemName: "minus.circle",
                tooltip: "Remove",
                rowIsHovered: isHovered,
                hoverColor: .red,
                isDisabled: !canRemove,
                action: { onRemove(row) }
            )
        }
    }
}

private struct AgentFileRowActionButton: View, AgentFileActionPresenting {
    let systemName: String
    let tooltip: String
    let rowIsHovered: Bool
    var hoverColor: Color = .primary
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    @State var isButtonHovered = false

    var body: some View {
        actionButton
            .onHover { hovering in
                isButtonHovered = hovering
            }
    }
}
