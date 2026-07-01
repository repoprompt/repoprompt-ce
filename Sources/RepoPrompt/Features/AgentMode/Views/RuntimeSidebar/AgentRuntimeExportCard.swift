import Combine
import SwiftUI

private enum AgentSelectedFilesPopoverTab {
    case files
    case codemaps
}

struct AgentExportCard: View {
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

    private func makeExportSource(flushPendingUI: Bool = true) -> AgentContextExportSource {
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

struct AgentSelectedFilesPopoverTrigger<Label: View>: View {
    @ObservedObject var promptManager: PromptViewModel
    let selectionCoordinator: WorkspaceSelectionCoordinator?
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let worktreeBindingsProvider: (@MainActor (UUID, UUID?) -> [AgentSessionWorktreeBinding])?
    let summaryOverride: AgentContextSelectionSummary?
    @ViewBuilder let label: (AgentContextSelectionSummary) -> Label

    @StateObject private var modelCoordinator = AgentSelectedFilesModelCoordinator()
    @State private var showSelectedFilesPopover = false
    @State private var activePopoverTab: AgentSelectedFilesPopoverTab = .files

    private var selectionSummary: AgentContextSelectionSummary {
        if let summaryOverride {
            return summaryOverride
        }
        return AgentContextExportResolver.selectionSummary(
            for: makeExportSource(flushPendingUI: false).selection
        )
    }

    private var selectionChangesPublisher: AnyPublisher<WorkspaceSelectionCoordinator.Change, Never> {
        selectionCoordinator?.changes ?? Empty<WorkspaceSelectionCoordinator.Change, Never>(completeImmediately: false).eraseToAnyPublisher()
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
            AgentSelectedFilesPopover(
                model: modelCoordinator.model,
                rowSplit: modelCoordinator.rowSplit,
                isLoading: modelCoordinator.isLoading,
                placeholderFileCount: selectionCount,
                activeTab: $activePopoverTab,
                canMutate: selectionCoordinator != nil,
                onLoadContent: { row, purpose in
                    guard let model = modelCoordinator.model else { return nil }
                    return await loadRowContent(row, model: model, purpose: purpose)
                },
                onRemove: { row, model in remove(row, from: model) },
                onClear: { model in clearSelection(for: model) }
            )
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
            AgentSelectedFilesDiagnostics.event(
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
            AgentSelectedFilesDiagnostics.event(
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
            AgentSelectedFilesDiagnostics.event(
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

    private func makeExportSource(flushPendingUI: Bool = true) -> AgentContextExportSource {
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

    private func makeModelRequest(flushPendingUI: Bool = true) -> AgentSelectedFilesModelRequest {
        let startMS = AgentSelectedFilesDiagnostics.timestampMSIfEnabled()
        let source = makeExportSource(flushPendingUI: flushPendingUI)
        let cfg = promptManager.resolvePromptContext(BuiltInCopyPresets.standard, custom: nil)
        let codeMapUsage = effectiveCodeMapUsage(for: activePopoverTab, configuredUsage: cfg.codeMapUsage)
        var fields = AgentSelectedFilesDiagnostics.sourceFields(source)
        fields["component"] = "trigger"
        fields["flushPendingUI"] = String(flushPendingUI)
        fields["activeTab"] = String(describing: activePopoverTab)
        fields["configuredCodeMapUsage"] = String(describing: cfg.codeMapUsage)
        fields["codeMapUsage"] = String(describing: codeMapUsage)
        fields.merge(AgentSelectedFilesDiagnostics.elapsedFields(since: startMS)) { _, new in new }
        AgentSelectedFilesDiagnostics.event("view.makeModelRequest", fields: fields)
        return AgentSelectedFilesModelRequest(
            identity: AgentSelectedFilesModelIdentity(
                exportContextIdentity: source.exportContextIdentity,
                filePathDisplay: promptManager.filePathDisplayOption,
                codeMapUsage: codeMapUsage
            ),
            source: source,
            store: promptManager.workspaceFileContextStore,
            filePathDisplay: promptManager.filePathDisplayOption,
            codeMapUsage: codeMapUsage
        )
    }

    private func effectiveCodeMapUsage(
        for activeTab: AgentSelectedFilesPopoverTab,
        configuredUsage: CodeMapUsage
    ) -> CodeMapUsage {
        activeTab == .codemaps ? configuredUsage : .none
    }

    private func refreshExportModel(force: Bool = false, preserveDisplayedModel: Bool = false) {
        let request = makeModelRequest(flushPendingUI: true)
        var fields = AgentSelectedFilesDiagnostics.requestFields(request)
        fields["component"] = "trigger"
        fields["force"] = String(force)
        fields["preserveDisplayedModel"] = String(preserveDisplayedModel)
        let outcome = modelCoordinator.refreshIfNeeded(
            request,
            force: force,
            preserveDisplayedModel: preserveDisplayedModel
        )
        fields["outcome"] = String(describing: outcome)
        AgentSelectedFilesDiagnostics.event("view.refresh", fields: fields, includeStack: true)
    }

    private func resetOrRefreshExportModelForContextChange() {
        AgentSelectedFilesDiagnostics.event(
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
        let tabID = currentTabID ?? selectionCoordinator?.activeTabID() ?? promptManager.activeComposeTabID
        var fields = AgentSelectedFilesDiagnostics.selectionFields(change.selection)
        fields["component"] = "trigger"
        fields["changeTabID"] = AgentSelectedFilesDiagnostics.shortID(change.tabID)
        fields["targetTabID"] = AgentSelectedFilesDiagnostics.shortID(tabID)
        fields["isPresented"] = String(showSelectedFilesPopover)
        guard change.tabID == tabID else {
            fields["ignored"] = "tabMismatch"
            AgentSelectedFilesDiagnostics.event("view.selectionChange", fields: fields)
            return
        }
        AgentSelectedFilesDiagnostics.event("view.selectionChange", fields: fields, includeStack: true)
        if showSelectedFilesPopover {
            refreshExportModel(preserveDisplayedModel: true)
        } else {
            modelCoordinator.invalidate()
        }
    }

    private func loadRowContent(
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

    private func remove(_ row: AgentContextExportRow, from model: AgentContextExportModel) {
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

    private func clearSelection(for model: AgentContextExportModel) {
        Task {
            let latestSelection = await MainActor.run { self.latestSelection(for: model.source) }
            let updated = AgentContextExportResolver.removeSelectionSnapshot(model.source.selection, from: latestSelection)
            await persistSelection(updated, source: model.source)
            await MainActor.run { refreshExportModel(force: true) }
        }
    }

    @MainActor
    private func latestSelection(for source: AgentContextExportSource) -> StoredSelection {
        guard let tabID = source.tabID else { return source.selection }
        if let snapshot = selectionCoordinator?.selectionSnapshot(for: tabID, flushPendingUIIfActive: true) {
            return snapshot.selection
        }
        return promptManager.currentComposeTabs.first { $0.id == tabID }?.selection ?? source.selection
    }

    @MainActor
    private func persistSelection(_ selection: StoredSelection, source: AgentContextExportSource) async {
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

struct AgentSelectedFilesInlineManager: View {
    @ObservedObject var promptManager: PromptViewModel
    let selectionCoordinator: WorkspaceSelectionCoordinator?
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let worktreeBindingsProvider: (@MainActor (UUID, UUID?) -> [AgentSessionWorktreeBinding])?
    let summary: AgentContextSelectionSummary

    @StateObject private var modelCoordinator = AgentSelectedFilesModelCoordinator()
    @State private var activePopoverTab: AgentSelectedFilesPopoverTab = .files

    private var selectionChangesPublisher: AnyPublisher<WorkspaceSelectionCoordinator.Change, Never> {
        selectionCoordinator?.changes ?? Empty<WorkspaceSelectionCoordinator.Change, Never>(completeImmediately: false).eraseToAnyPublisher()
    }

    var body: some View {
        AgentSelectedFilesPopover(
            model: modelCoordinator.model,
            rowSplit: modelCoordinator.rowSplit,
            isLoading: modelCoordinator.isLoading,
            placeholderFileCount: summary.totalExplicitFileCount,
            activeTab: $activePopoverTab,
            canMutate: selectionCoordinator != nil,
            onLoadContent: { row, purpose in
                guard let model = modelCoordinator.model else { return nil }
                return await loadRowContent(row, model: model, purpose: purpose)
            },
            onRemove: { row, model in remove(row, from: model) },
            onClear: { model in clearSelection(for: model) }
        )
        .onAppear {
            AgentSelectedFilesDiagnostics.event("inline.onAppear", includeStack: true)
            refreshExportModel()
        }
        .onChange(of: activePopoverTab) { _, _ in
            refreshExportModel(preserveDisplayedModel: true)
        }
        .onDisappear {
            AgentSelectedFilesDiagnostics.event("inline.onDisappear", includeStack: true)
            modelCoordinator.cancelLoading(keepLoadedModel: true)
        }
        .onChange(of: currentTabID) { oldValue, newValue in
            AgentSelectedFilesDiagnostics.event(
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
            AgentSelectedFilesDiagnostics.event(
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

    private func makeExportSource(flushPendingUI: Bool = true) -> AgentContextExportSource {
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

    private func makeModelRequest(flushPendingUI: Bool = true) -> AgentSelectedFilesModelRequest {
        let startMS = AgentSelectedFilesDiagnostics.timestampMSIfEnabled()
        let source = makeExportSource(flushPendingUI: flushPendingUI)
        let cfg = promptManager.resolvePromptContext(BuiltInCopyPresets.standard, custom: nil)
        let codeMapUsage = effectiveCodeMapUsage(for: activePopoverTab, configuredUsage: cfg.codeMapUsage)
        var fields = AgentSelectedFilesDiagnostics.sourceFields(source)
        fields["component"] = "inline"
        fields["flushPendingUI"] = String(flushPendingUI)
        fields["activeTab"] = String(describing: activePopoverTab)
        fields["configuredCodeMapUsage"] = String(describing: cfg.codeMapUsage)
        fields["codeMapUsage"] = String(describing: codeMapUsage)
        fields.merge(AgentSelectedFilesDiagnostics.elapsedFields(since: startMS)) { _, new in new }
        AgentSelectedFilesDiagnostics.event("view.makeModelRequest", fields: fields)
        return AgentSelectedFilesModelRequest(
            identity: AgentSelectedFilesModelIdentity(
                exportContextIdentity: source.exportContextIdentity,
                filePathDisplay: promptManager.filePathDisplayOption,
                codeMapUsage: codeMapUsage
            ),
            source: source,
            store: promptManager.workspaceFileContextStore,
            filePathDisplay: promptManager.filePathDisplayOption,
            codeMapUsage: codeMapUsage
        )
    }

    private func effectiveCodeMapUsage(
        for activeTab: AgentSelectedFilesPopoverTab,
        configuredUsage: CodeMapUsage
    ) -> CodeMapUsage {
        activeTab == .codemaps ? configuredUsage : .none
    }

    private func refreshExportModel(force: Bool = false, preserveDisplayedModel: Bool = false) {
        let request = makeModelRequest(flushPendingUI: true)
        var fields = AgentSelectedFilesDiagnostics.requestFields(request)
        fields["component"] = "inline"
        fields["force"] = String(force)
        fields["preserveDisplayedModel"] = String(preserveDisplayedModel)
        let outcome = modelCoordinator.refreshIfNeeded(
            request,
            force: force,
            preserveDisplayedModel: preserveDisplayedModel
        )
        fields["outcome"] = String(describing: outcome)
        AgentSelectedFilesDiagnostics.event("view.refresh", fields: fields, includeStack: true)
    }

    private func resetAndRefreshExportModelForContextChange() {
        AgentSelectedFilesDiagnostics.event("inline.resetForContextChange", includeStack: true)
        modelCoordinator.invalidate()
        refreshExportModel()
    }

    private func handleSelectionChange(_ change: WorkspaceSelectionCoordinator.Change) {
        let tabID = currentTabID ?? selectionCoordinator?.activeTabID() ?? promptManager.activeComposeTabID
        var fields = AgentSelectedFilesDiagnostics.selectionFields(change.selection)
        fields["component"] = "inline"
        fields["changeTabID"] = AgentSelectedFilesDiagnostics.shortID(change.tabID)
        fields["targetTabID"] = AgentSelectedFilesDiagnostics.shortID(tabID)
        guard change.tabID == tabID else {
            fields["ignored"] = "tabMismatch"
            AgentSelectedFilesDiagnostics.event("view.selectionChange", fields: fields)
            return
        }
        AgentSelectedFilesDiagnostics.event("view.selectionChange", fields: fields, includeStack: true)
        refreshExportModel(preserveDisplayedModel: true)
    }

    private func loadRowContent(
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

    private func remove(_ row: AgentContextExportRow, from model: AgentContextExportModel) {
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

    private func clearSelection(for model: AgentContextExportModel) {
        Task {
            let latestSelection = await MainActor.run { self.latestSelection(for: model.source) }
            let updated = AgentContextExportResolver.removeSelectionSnapshot(model.source.selection, from: latestSelection)
            await persistSelection(updated, source: model.source)
            await MainActor.run { refreshExportModel(force: true) }
        }
    }

    @MainActor
    private func latestSelection(for source: AgentContextExportSource) -> StoredSelection {
        guard let tabID = source.tabID else { return source.selection }
        if let snapshot = selectionCoordinator?.selectionSnapshot(for: tabID, flushPendingUIIfActive: true) {
            return snapshot.selection
        }
        return promptManager.currentComposeTabs.first { $0.id == tabID }?.selection ?? source.selection
    }

    @MainActor
    private func persistSelection(_ selection: StoredSelection, source: AgentContextExportSource) async {
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

private struct AgentSelectedFilesPopover: View {
    let model: AgentContextExportModel?
    let rowSplit: AgentSelectedFilesRowSplit
    let isLoading: Bool
    let placeholderFileCount: Int
    @Binding var activeTab: AgentSelectedFilesPopoverTab
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
                emptyState(title: "No files selected")
            } else {
                let activeRows = rows(for: activeTab)
                if activeRows.isEmpty {
                    emptyState(title: activeTab == .files ? "No files in Agent context" : "No codemaps in Agent context")
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(activeRows) { row in
                                AgentSelectedFileRow(
                                    row: row,
                                    canRemove: canMutate && row.canRemove,
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
            adjustActiveTab(fileCount: rowSplit.fileRows.count, codemapCount: rowSplit.codemapRows.count)
        }
        .onChange(of: rowSplit.fileRows.count) { _, _ in
            adjustActiveTab(fileCount: rowSplit.fileRows.count, codemapCount: rowSplit.codemapRows.count)
        }
        .onChange(of: rowSplit.codemapRows.count) { _, _ in
            adjustActiveTab(fileCount: rowSplit.fileRows.count, codemapCount: rowSplit.codemapRows.count)
        }
        .onChange(of: activeTab) { _, _ in
            previewCoordinator.reconcileVisibleRows(rows(for: activeTab))
        }
        .onChange(of: rowSplit.rows.map(\.id)) { _, _ in
            previewCoordinator.reconcileVisibleRows(rows(for: activeTab))
        }
    }

    private func rows(for tab: AgentSelectedFilesPopoverTab) -> [AgentContextExportRow] {
        switch tab {
        case .files: rowSplit.fileRows
        case .codemaps: rowSplit.codemapRows
        }
    }

    private func tabSwitcher(split: AgentSelectedFilesRowSplit) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 0) {
                tabButton(icon: "doc.text", label: "Files", count: displayFileCount(split: split), tab: .files) {
                    activeTab = .files
                }
                tabButton(icon: "square.grid.2x2", label: "Codemaps", count: split.codemapRows.count, tab: .codemaps) {
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
        .disabled(split.rows.isEmpty || !canMutate || model == nil)
        .hoverTooltip(canMutate ? "Clear selection" : "Unavailable")
        .accessibilityHint(canMutate ? "Clear selection" : "Selection unavailable")
    }

    private func tabButton(
        icon: String,
        label: String,
        count: Int,
        tab: AgentSelectedFilesPopoverTab,
        action: @escaping () -> Void
    ) -> some View {
        let isActive = activeTab == tab
        return Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                Text(label)
                    .font(fontPreset.captionFont.weight(.semibold))
                Text("\(count)")
                    .font(fontPreset.captionFont.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 32)
            .foregroundColor(isActive ? Color.accentColor : Color.secondary)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.18))
                    .frame(height: isActive ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isActive)
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

    private func emptyState(title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 34))
                .foregroundColor(.secondary.opacity(0.4))
            Text(title)
                .font(fontPreset.standardFont)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func adjustActiveTab(fileCount: Int, codemapCount: Int) {
        if activeTab == .files, fileCount == 0, codemapCount > 0 {
            activeTab = .codemaps
        } else if activeTab == .codemaps, codemapCount == 0, fileCount > 0 {
            activeTab = .files
        }
    }
}

@MainActor
final class AgentSelectedFilePreviewLoadCoordinator: ObservableObject {
    @Published private(set) var activePreviewRowID: ResolvedPromptFileEntryID?
    @Published private(set) var contentRevision = 0
    @Published private(set) var previewText: String? {
        didSet { contentRevision &+= 1 }
    }

    @Published private(set) var isLoadingPreview = false {
        didSet { contentRevision &+= 1 }
    }

    private var activePreviewRow: AgentContextExportRow?
    private var previewLoadTask: Task<Void, Never>?

    deinit {
        previewLoadTask?.cancel()
    }

    var hasPreviewLoadTask: Bool {
        previewLoadTask != nil
    }

    func isPreviewPresented(for row: AgentContextExportRow) -> Bool {
        activePreviewRowID == row.id
    }

    func isLoadingPreview(for row: AgentContextExportRow) -> Bool {
        activePreviewRowID == row.id && isLoadingPreview
    }

    func openPreview(
        row: AgentContextExportRow,
        loadContent: @escaping (AgentContextExportRow, AgentContextExportRow.ContentPurpose) async -> String?
    ) {
        closeActivePreview()
        activePreviewRow = row
        activePreviewRowID = row.id
        isLoadingPreview = true
        previewLoadTask = Task { [weak self] in
            let rowID = row.id
            let text = await loadContent(row, .preview)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard self?.activePreviewRow?.id == rowID else { return }
                self?.previewText = text
                self?.isLoadingPreview = false
                self?.previewLoadTask = nil
            }
        }
    }

    func displayText(for row: AgentContextExportRow) -> String {
        guard activePreviewRowID == row.id else { return "No preview content available" }
        if isLoadingPreview { return "Loading preview…" }
        return previewText ?? "No preview content available"
    }

    func handlePreviewPresentationChanged(row: AgentContextExportRow, isPresented: Bool) {
        if !isPresented, activePreviewRow == row {
            closeActivePreview()
        }
    }

    func handleRowDisappear(row: AgentContextExportRow) {
        if activePreviewRow == row {
            closeActivePreview()
        }
    }

    func reconcileVisibleRows(_ rows: [AgentContextExportRow]) {
        guard let activePreviewRow else { return }
        if !rows.contains(activePreviewRow) {
            closeActivePreview()
        }
    }

    private func closeActivePreview() {
        previewLoadTask?.cancel()
        previewLoadTask = nil
        activePreviewRow = nil
        activePreviewRowID = nil
        isLoadingPreview = false
        previewText = nil
    }
}

private struct AgentSelectedFileRow: View {
    let row: AgentContextExportRow
    let canRemove: Bool
    @ObservedObject var previewCoordinator: AgentSelectedFilePreviewLoadCoordinator
    let onLoadContent: (AgentContextExportRow, AgentContextExportRow.ContentPurpose) async -> String?
    let onRemove: (AgentContextExportRow) -> Void

    @State private var copyTask: Task<Void, Never>?
    @State private var isCopying = false
    @State private var isHovered = false
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var accentColor: Color {
        switch row.kind {
        case .codemap: .purple
        case .slices: .orange
        case .full: .accentColor
        }
    }

    private var leadingIconName: String {
        switch row.kind {
        case .codemap: "square.grid.2x2"
        case .slices: "curlybraces"
        case .full: "doc.text"
        }
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

    private var parentPathDisplay: String? {
        let parent = (row.relativePath as NSString).deletingLastPathComponent
        guard parent != ".", !parent.isEmpty else { return nil }
        let components = parent.split(separator: "/").map(String.init)
        guard components.count > 2 else { return parent }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    private var sliceCountText: String? {
        guard row.kind == .slices, let count = row.lineRanges?.count, count > 0 else { return nil }
        return "\(count)"
    }

    var body: some View {
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
        .popover(
            isPresented: Binding(
                get: { previewCoordinator.isPreviewPresented(for: row) },
                set: { previewCoordinator.handlePreviewPresentationChanged(row: row, isPresented: $0) }
            ),
            arrowEdge: .bottom
        ) {
            AgentResolvedFilePreviewPopover(
                row: row,
                previewCoordinator: previewCoordinator
            )
        }
        .onDisappear {
            previewCoordinator.handleRowDisappear(row: row)
            copyTask?.cancel()
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
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .regular))
                .imageScale(.medium)
                .foregroundColor(.secondary.opacity(isHovered ? 1 : 0.55))
                .frame(width: 26, height: 26)
                .hoverTooltip(disabledRemoveExplanation)
                .accessibilityLabel(disabledRemoveExplanation)
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

    private func openPreview() {
        previewCoordinator.openPreview(row: row, loadContent: onLoadContent)
    }

    private func copyToClipboard() {
        isCopying = true
        copyTask?.cancel()
        copyTask = Task {
            let text = await onLoadContent(row, .copy) ?? ""
            guard !Task.isCancelled else { return }
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                isCopying = false
                copyTask = nil
            }
        }
    }
}

private struct AgentFileRowActionButton: View {
    let systemName: String
    let tooltip: String
    let rowIsHovered: Bool
    var hoverColor: Color = .primary
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    @State private var isButtonHovered = false

    private var foregroundColor: Color {
        guard !isDisabled else { return .secondary.opacity(0.35) }
        if isButtonHovered { return hoverColor }
        return .secondary.opacity(rowIsHovered ? 1 : 0.55)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .regular))
                    .imageScale(.medium)
                    .opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.60)
                }
            }
            .foregroundColor(foregroundColor)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .hoverTooltip(tooltip)
        .onHover { hovering in
            isButtonHovered = hovering
        }
    }
}

private struct AgentResolvedFilePreviewPopover: View {
    let row: AgentContextExportRow
    @ObservedObject var previewCoordinator: AgentSelectedFilePreviewLoadCoordinator

    private var displayText: String {
        previewCoordinator.displayText(for: row)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(row.displayPath)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding()
            TextKitView(
                text: .constant(displayText),
                isEditable: false,
                isSpellCheckEnabled: false,
                useMonospacedFont: true,
                // Keep this wired to the coordinator: TextKitView avoids overwriting
                // first-responder AppKit text unless its external update tick changes.
                externalUpdateTick: previewCoordinator.contentRevision
            )
        }
        .frame(width: 900, height: 650)
    }
}
