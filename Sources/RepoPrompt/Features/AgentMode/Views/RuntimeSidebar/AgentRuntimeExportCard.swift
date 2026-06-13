import Combine
import SwiftUI

struct AgentExportCard: View {
    @ObservedObject var promptManager: PromptViewModel
    @ObservedObject var tokenCounter: TokenCountingViewModel
    let selectionCoordinator: WorkspaceSelectionCoordinator?
    let fileCount: Int?
    let selectionTokens: Int?
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let worktreeBindingsProvider: (@MainActor (UUID, UUID?) -> [AgentSessionWorktreeBinding])?

    @State private var showSelectedFilesPopover = false
    @State private var exportModel: AgentContextExportModel?
    @State private var exportModelRefreshID: UUID?
    @State private var exportModelRefreshTask: Task<Void, Never>?
    @State private var isLoadingExportModel = false

    private var currentExportModel: AgentContextExportModel? {
        guard let exportModel, modelMatchesCurrentContext(exportModel) else { return nil }
        return exportModel
    }

    private var currentExportContextIdentity: AgentContextExportIdentity {
        makeExportSource(flushPendingUI: false).exportContextIdentity
    }

    private var displayFileCount: Int {
        AgentContextExportResolver.displayFileCount(
            resolvedModel: currentExportModel,
            sourceSelection: makeExportSource(flushPendingUI: false).selection
        )
    }

    private var selectionChangesPublisher: AnyPublisher<WorkspaceSelectionCoordinator.Change, Never> {
        selectionCoordinator?.changes ?? Empty<WorkspaceSelectionCoordinator.Change, Never>(completeImmediately: false).eraseToAnyPublisher()
    }

    private var displayTokens: Int? {
        if let selectionTokens, selectionTokens > 0 {
            return selectionTokens
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

                filesButton

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
        .onReceive(selectionChangesPublisher) { change in
            handleSelectionChange(change)
        }
    }

    // MARK: - Files Button

    private var filesButton: some View {
        let selectionCount = displayFileCount

        return Button {
            showSelectedFilesPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(selectionCount) file\(selectionCount == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSelectedFilesPopover) {
            AgentSelectedFilesPopover(
                model: currentExportModel,
                isLoading: isLoadingExportModel,
                canMutate: selectionCoordinator != nil,
                onRefresh: { refreshExportModel() },
                onLoadContent: { row, purpose in await loadRowContent(row, purpose: purpose) },
                onRemove: { row, model in remove(row, from: model) },
                onClear: { model in clearSelection(for: model) }
            )
            .frame(width: 380)
            .frame(
                minHeight: 200,
                idealHeight: min(500, Double(max(currentExportModel?.fileCount ?? selectionCount, 1)) * 40 + 120),
                maxHeight: 500
            )
        }
        .onChange(of: showSelectedFilesPopover) { _, isPresented in
            if !isPresented {
                cancelExportModelRefresh()
            }
        }
        .onChange(of: currentTabID) { _, _ in resetExportModelForContextChange() }
        .onChange(of: activeAgentSessionID) { _, _ in resetExportModelForContextChange() }
        .onChange(of: currentExportContextIdentity) { _, _ in resetOrRefreshExportModelForContextChange() }
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

    private func refreshExportModel() {
        exportModelRefreshTask?.cancel()
        let source = makeExportSource()
        let cfg = promptManager.resolvePromptContext(BuiltInCopyPresets.standard, custom: nil)
        let refreshID = UUID()
        exportModelRefreshID = refreshID
        isLoadingExportModel = true
        exportModelRefreshTask = Task {
            let model = await AgentContextExportResolver.resolveModel(
                source: source,
                store: promptManager.workspaceFileContextStore,
                filePathDisplay: promptManager.filePathDisplayOption,
                codeMapUsage: cfg.codeMapUsage
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard exportModelRefreshID == refreshID else { return }
                exportModel = model
                isLoadingExportModel = false
                exportModelRefreshID = nil
                exportModelRefreshTask = nil
            }
        }
    }

    private func cancelExportModelRefresh() {
        exportModelRefreshTask?.cancel()
        exportModelRefreshTask = nil
        exportModelRefreshID = nil
        isLoadingExportModel = false
    }

    private func resetExportModelForContextChange() {
        cancelExportModelRefresh()
        exportModel = nil
    }

    private func resetOrRefreshExportModelForContextChange() {
        resetExportModelForContextChange()
        if showSelectedFilesPopover {
            refreshExportModel()
        }
    }

    private func handleSelectionChange(_ change: WorkspaceSelectionCoordinator.Change) {
        let tabID = currentTabID ?? selectionCoordinator?.activeTabID() ?? promptManager.activeComposeTabID
        guard change.tabID == tabID else { return }
        resetExportModelForContextChange()
        if showSelectedFilesPopover {
            refreshExportModel()
        }
    }

    private func modelMatchesCurrentContext(_ model: AgentContextExportModel) -> Bool {
        model.source.exportContextIdentity == currentExportContextIdentity
    }

    private func loadRowContent(
        _ row: AgentContextExportRow,
        purpose: AgentContextExportRow.ContentPurpose
    ) async -> String? {
        await AgentContextExportResolver.loadRowContent(
            for: row,
            store: promptManager.workspaceFileContextStore,
            purpose: purpose
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
                selectedGitDiffProvider: { paths in
                    await promptManager.gitViewModel.getDiffForAbsolutePaths(paths, forceRefreshStatus: true) ?? ""
                },
                completeGitDiffProvider: {
                    await promptManager.gitViewModel.getDiffUsing(inclusionMode: .all, forceRefreshStatus: true) ?? ""
                }
            )
        }
        return await AgentContextExportResolver.buildClipboardContent(request)
    }

    private func remove(_ row: AgentContextExportRow, from model: AgentContextExportModel) {
        guard row.canRemove else { return }
        Task {
            let latestSelection = await MainActor.run { self.latestSelection(for: model.source) }
            let updated = AgentContextExportResolver.removeRow(
                row,
                from: latestSelection,
                lookupContext: model.lookupContext
            )
            await persistSelection(updated, source: model.source)
            await MainActor.run { refreshExportModel() }
        }
    }

    private func clearSelection(for model: AgentContextExportModel) {
        Task {
            let latestSelection = await MainActor.run { self.latestSelection(for: model.source) }
            let updated = AgentContextExportResolver.removeSelectionSnapshot(model.source.selection, from: latestSelection)
            await persistSelection(updated, source: model.source)
            await MainActor.run { refreshExportModel() }
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

private struct AgentSelectedFilesPopover: View {
    let model: AgentContextExportModel?
    let isLoading: Bool
    let canMutate: Bool
    let onRefresh: () -> Void
    let onLoadContent: (AgentContextExportRow, AgentContextExportRow.ContentPurpose) async -> String?
    let onRemove: (AgentContextExportRow, AgentContextExportModel) -> Void
    let onClear: (AgentContextExportModel) -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var activeTab: Tab = .files

    private enum Tab {
        case files
        case codemaps
    }

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private struct RowSplit {
        let rows: [AgentContextExportRow]
        let fileRows: [AgentContextExportRow]
        let codemapRows: [AgentContextExportRow]

        init(rows: [AgentContextExportRow]) {
            self.rows = rows
            var fileRows: [AgentContextExportRow] = []
            var codemapRows: [AgentContextExportRow] = []
            fileRows.reserveCapacity(rows.count)
            codemapRows.reserveCapacity(rows.count)
            for row in rows {
                if row.kind == .codemap {
                    codemapRows.append(row)
                } else {
                    fileRows.append(row)
                }
            }
            self.fileRows = fileRows
            self.codemapRows = codemapRows
        }

        func rows(for tab: Tab) -> [AgentContextExportRow] {
            switch tab {
            case .files: fileRows
            case .codemaps: codemapRows
            }
        }
    }

    private var rows: [AgentContextExportRow] {
        model?.rows ?? []
    }

    var body: some View {
        let split = RowSplit(rows: rows)

        VStack(alignment: .leading, spacing: 6) {
            header(split: split)
            Divider().padding(.vertical, 2)
            tabSwitcher(split: split)

            if isLoading, model == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if split.rows.isEmpty {
                emptyState(title: "No files selected")
            } else {
                let activeRows = split.rows(for: activeTab)
                if activeRows.isEmpty {
                    emptyState(title: activeTab == .files ? "No files in Agent context" : "No codemaps in Agent context")
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(activeRows.enumerated()), id: \.element.id) { index, row in
                                AgentSelectedFileRow(
                                    row: row,
                                    rowIndex: index,
                                    canRemove: canMutate && row.canRemove,
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
        .padding(8)
        .onAppear {
            onRefresh()
            adjustActiveTab(fileCount: split.fileRows.count, codemapCount: split.codemapRows.count)
        }
        .onChange(of: split.fileRows.count) { _, _ in
            adjustActiveTab(fileCount: split.fileRows.count, codemapCount: split.codemapRows.count)
        }
        .onChange(of: split.codemapRows.count) { _, _ in
            adjustActiveTab(fileCount: split.fileRows.count, codemapCount: split.codemapRows.count)
        }
    }

    private func header(split: RowSplit) -> some View {
        HStack(alignment: .center) {
            Text("Agent Files")
                .font(fontPreset.standardFont.weight(.medium))
                .foregroundColor(.primary)
            Circle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 4, height: 4)
            Text("\(split.fileRows.count)")
                .font(fontPreset.captionFont.weight(.medium))
                .foregroundColor(.secondary)
            Spacer()
            Button {
                guard let model else { return }
                onClear(model)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    Text("Clear All")
                        .font(fontPreset.captionFont)
                }
            }
            .buttonStyle(CustomButtonStyle(verticalPadding: 3, horizontalPadding: 8))
            .disabled(split.rows.isEmpty || !canMutate || model == nil)
            .hoverTooltip(canMutate ? (split.rows.isEmpty ? "No Agent context files to clear" : "Clear the displayed Agent selection") : "Selection mutation is unavailable for this Agent context")
            .accessibilityHint(canMutate ? (split.rows.isEmpty ? "No Agent context files to clear" : "Clear the displayed Agent selection") : "Selection mutation is unavailable for this Agent context")
        }
    }

    private func tabSwitcher(split: RowSplit) -> some View {
        HStack(spacing: 0) {
            tabButton(icon: "doc.text", label: "Files", count: split.fileRows.count, tab: .files) {
                activeTab = .files
            }
            tabButton(icon: "square.grid.2x2", label: "Codemaps", count: split.codemapRows.count, tab: .codemaps) {
                activeTab = .codemaps
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, -12)
        .padding(.vertical, -6)
    }

    private func tabButton(
        icon: String,
        label: String,
        count: Int,
        tab: Tab,
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
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 34)
            .foregroundColor(isActive ? Color.accentColor : Color.secondary)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(height: isActive ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isActive)
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

private struct AgentSelectedFileRow: View {
    let row: AgentContextExportRow
    let rowIndex: Int
    let canRemove: Bool
    let onLoadContent: (AgentContextExportRow, AgentContextExportRow.ContentPurpose) async -> String?
    let onRemove: (AgentContextExportRow) -> Void

    @State private var showPreview = false
    @State private var previewText: String?
    @State private var isLoadingPreview = false
    @State private var previewLoadTask: Task<Void, Never>?
    @State private var copyTask: Task<Void, Never>?
    @State private var isCopying = false
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

    private var disabledRemoveExplanation: String? {
        if !row.canRemove {
            return "Expanded from a selected folder; remove the folder selection to remove this file"
        }
        if !canRemove {
            return "Selection mutation is unavailable for this Agent context"
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor.opacity(0.65))
                .frame(width: 4, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: row.kind.iconName)
                        .foregroundColor(accentColor)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    Text(row.displayName)
                        .font(fontPreset.standardFont.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let badge = row.kind.badgeText {
                        Text(row.kind == .slices ? "\(badge) ×\(row.lineRanges?.count ?? 0)" : badge)
                            .font(fontPreset.captionFont.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(accentColor.opacity(0.15))
                            .foregroundColor(accentColor)
                            .cornerRadius(6)
                    }
                    Spacer(minLength: 0)
                }
                if let directory = row.directoryDisplay {
                    Text(directory)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button(action: openPreview) {
                    Image(systemName: isLoadingPreview ? "hourglass" : "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .padding(6)
                }
                .buttonStyle(.plain)
                .hoverTooltip("Preview file content")

                Button(action: copyToClipboard) {
                    Image(systemName: isCopying ? "hourglass" : "doc.on.clipboard")
                        .font(.system(size: 13, weight: .medium))
                        .padding(6)
                }
                .buttonStyle(.plain)
                .disabled(isCopying)
                .hoverTooltip(row.kind == .codemap ? "Copy Codemap" : "Copy File Content")

                if let disabledRemoveExplanation {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(6)
                        .hoverTooltip(disabledRemoveExplanation)
                        .accessibilityLabel(disabledRemoveExplanation)
                }

                Button { onRemove(row) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .disabled(!canRemove)
                .hoverTooltip(canRemove ? "Remove from Agent selection" : "Remove unavailable")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
            .frame(minWidth: 90, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            rowIndex % 2 == 0
                ? Color(NSColor.controlBackgroundColor).opacity(0.24)
                : Color(NSColor.controlBackgroundColor).opacity(0.14)
        )
        .cornerRadius(8)
        .contentShape(Rectangle())
        .popover(isPresented: $showPreview, arrowEdge: .bottom) {
            AgentResolvedFilePreviewPopover(
                row: row,
                text: previewText,
                isLoading: isLoadingPreview
            )
        }
        .onChange(of: showPreview) { _, isPresented in
            if !isPresented {
                previewLoadTask?.cancel()
                previewLoadTask = nil
                isLoadingPreview = false
            }
        }
        .onDisappear {
            previewLoadTask?.cancel()
            copyTask?.cancel()
        }
    }

    private func openPreview() {
        showPreview = true
        previewText = nil
        isLoadingPreview = true
        previewLoadTask?.cancel()
        previewLoadTask = Task {
            let text = await onLoadContent(row, .preview)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                previewText = text
                isLoadingPreview = false
                previewLoadTask = nil
            }
        }
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

private struct AgentResolvedFilePreviewPopover: View {
    let row: AgentContextExportRow
    let text: String?
    let isLoading: Bool

    private var displayText: String {
        if isLoading { return "Loading preview…" }
        return text ?? "No preview content available"
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
                useMonospacedFont: true
            )
        }
        .frame(width: 900, height: 650)
    }
}
