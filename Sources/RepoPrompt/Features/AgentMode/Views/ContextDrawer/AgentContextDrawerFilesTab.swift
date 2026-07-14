import SwiftUI

func presentedSelectedContextCount(
    authoritativeRowCount: Int?,
    isSwitchBlankingRows: Bool
) -> Int? {
    guard !isSwitchBlankingRows else { return nil }
    return authoritativeRowCount
}

struct AgentContextDrawerFilesTab: View {
    @ObservedObject var detailStore: AgentContextDrawerDetailStore
    @ObservedObject var modelCoordinator: AgentSelectedFilesModelCoordinator
    let exportContext: AgentContextExportViewContext
    let isSwitchBlankingRows: Bool

    @ObservedObject private var fontScale = FontScaleManager.shared
    @StateObject private var previewCoordinator = AgentSelectedFilePreviewLoadCoordinator()

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var currentModel: AgentContextExportModel? {
        modelCoordinator.model
    }

    private var isSwitchHidingRows: Bool {
        isSwitchBlankingRows && !modelCoordinator.displayedModelMatches(exportContext.modelRequestIdentity)
    }

    private var rows: [AgentContextExportRow] {
        isSwitchHidingRows ? [] : modelCoordinator.rowSplit.rows
    }

    private var selectedContextCount: Int? {
        let authoritativeRowCount = modelCoordinator.displayedModelMatches(exportContext.modelRequestIdentity)
            ? modelCoordinator.rowSplit.rows.count
            : nil
        return presentedSelectedContextCount(
            authoritativeRowCount: authoritativeRowCount,
            isSwitchBlankingRows: isSwitchBlankingRows
        )
    }

    private var isResolvingWithoutModel: Bool {
        modelCoordinator.isLoading && currentModel == nil
    }

    private var trimmedFilterText: String {
        detailStore.fileFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasActiveFilter: Bool {
        !trimmedFilterText.isEmpty
    }

    private var filteredRows: [AgentContextExportRow] {
        let query = trimmedFilterText
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            row.displayName.localizedCaseInsensitiveContains(query)
                || row.displayPath.localizedCaseInsensitiveContains(query)
                || row.rootDisplayName.localizedCaseInsensitiveContains(query)
                || (row.physicalPath?.localizedCaseInsensitiveContains(query) ?? false)
                || (row.directoryDisplay?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var sortedRows: [AgentContextExportRow] {
        detailStore.selectionSort.sortedRows(filteredRows)
    }

    private var fileRows: [AgentContextExportRow] {
        sortedRows.filter { $0.kind != .codemap }
    }

    private var codemapRows: [AgentContextExportRow] {
        sortedRows.filter { $0.kind == .codemap }
    }

    private var displayedCountReadiness: AgentContextFileCodemapCountReadiness? {
        guard !isSwitchHidingRows else { return nil }
        return modelCoordinator.displayedFileCodemapCountReadiness(for: exportContext.modelRequestIdentity)
    }

    private var fileSubtabCountReadiness: AgentContextCountReadiness {
        guard let displayedCountReadiness else { return .unknown }
        return switch displayedCountReadiness.file {
        case .known:
            .known(fileRows.count)
        case .unknown:
            .unknown
        }
    }

    private var codemapSubtabCountReadiness: AgentContextCountReadiness {
        guard let displayedCountReadiness else { return .unknown }
        return switch displayedCountReadiness.codemap {
        case let .known(count) where count == modelCoordinator.rowSplit.codemapRows.count:
            .known(codemapRows.count)
        case let .known(count):
            hasActiveFilter ? .unknown : .known(count)
        case .unknown:
            .unknown
        }
    }

    private var isAwaitingCodemapRows: Bool {
        guard detailStore.filesSubtab == .codemaps, codemapRows.isEmpty else { return false }
        return switch codemapSubtabCountReadiness {
        case .known:
            false
        case .unknown:
            true
        }
    }

    private var activeRows: [AgentContextExportRow] {
        switch detailStore.filesSubtab {
        case .files: fileRows
        case .codemaps: codemapRows
        }
    }

    private var previewVisibleRows: [AgentContextExportRow] {
        isSwitchHidingRows ? [] : activeRows
    }

    private var canMutateCurrentModel: Bool {
        guard !isSwitchBlankingRows else { return false }
        guard !exportContext.promptManager.isSwitchingComposeTab else { return false }
        guard modelCoordinator.canMutateDisplayedModel else { return false }
        guard let model = currentModel,
              let sourceTabID = model.source.tabID,
              let selectionCoordinator = exportContext.selectionCoordinator
        else { return false }
        return selectionCoordinator.activeTabID() == sourceTabID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            subtabSwitcher
            content
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .onAppear {
            refreshIfNeeded()
            adjustActiveSubtab()
        }
        .onDisappear {
            previewCoordinator.reconcileVisibleRows([])
            if !isSwitchBlankingRows {
                modelCoordinator.cancelLoading(keepLoadedModel: true)
            }
        }
        .onReceive(exportContext.selectionChangesPublisher) { change in
            guard !isSwitchBlankingRows else { return }
            guard !exportContext.promptManager.isSwitchingComposeTab else { return }
            handleSelectionChange(change, isVisible: true)
        }
        .onChange(of: exportContext.modelRequestIdentity) { _, _ in
            guard !isSwitchBlankingRows else { return }
            guard !exportContext.promptManager.isSwitchingComposeTab else { return }
            resetOrRefresh(isVisible: true)
        }
        .onChange(of: fileRows.count) { _, _ in adjustActiveSubtab() }
        .onChange(of: codemapRows.count) { _, _ in adjustActiveSubtab() }
        .onChange(of: isAwaitingCodemapRows) { _, _ in adjustActiveSubtab() }
        .onChange(of: detailStore.filesSubtab) { _, _ in
            previewCoordinator.reconcileVisibleRows(previewVisibleRows)
        }
        .onChange(of: sortedRows.map(\.id)) { _, _ in
            previewCoordinator.reconcileVisibleRows(previewVisibleRows)
        }
        .onChange(of: isSwitchHidingRows) { _, _ in
            previewCoordinator.reconcileVisibleRows(previewVisibleRows)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                filterField
                sortControl
            }

            HStack(spacing: 8) {
                if let selectedContextCount {
                    Text("Selected context: \(selectedContextCount)")
                        .font(fontPreset.captionFont.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if hasActiveFilter {
                    Text("\(filteredRows.count) matching")
                        .font(fontPreset.captionFont)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    guard let model = currentModel else { return }
                    clearSelection(for: model)
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                        .font(fontPreset.captionFont)
                }
                .buttonStyle(CustomButtonStyle(verticalPadding: 4, horizontalPadding: 9))
                .disabled(rows.isEmpty || !canMutateCurrentModel || currentModel == nil)
                .hoverTooltip(canMutateCurrentModel ? "Clear selected context" : "Selection mutation is unavailable for this Agent context")
            }
        }
    }

    private var filterField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter selected files", text: $detailStore.fileFilterText)
                .textFieldStyle(.plain)
            if !detailStore.fileFilterText.isEmpty {
                Button {
                    detailStore.fileFilterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .hoverTooltip("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.textBackgroundColor).opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var sortControl: some View {
        Menu {
            ForEach(AgentContextDrawerUIStore.SelectionSort.allCases) { sort in
                Button {
                    detailStore.selectionSort = sort
                } label: {
                    HStack {
                        Text(sort.label)
                        if sort == detailStore.selectionSort {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                Text("Sort")
                Text(detailStore.selectionSort.label)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            .font(fontPreset.captionFont)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(NSColor.textBackgroundColor).opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .hoverTooltip("Sort selected context")
    }

    private var subtabSwitcher: some View {
        HStack(spacing: 0) {
            subtabButton(icon: "doc.text", title: "Files", count: fileSubtabCountReadiness, subtab: .files)
            subtabButton(
                icon: "square.grid.2x2",
                title: "Codemaps",
                count: codemapSubtabCountReadiness,
                subtab: .codemaps
            )
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
        )
    }

    private func subtabButton(
        icon: String,
        title: String,
        count: AgentContextCountReadiness,
        subtab: AgentContextDrawerUIStore.FilesSubtab
    ) -> some View {
        let isActive = detailStore.filesSubtab == subtab
        return Button {
            detailStore.filesSubtab = subtab
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                Text(title)
                    .font(fontPreset.captionFont.weight(.semibold))
                countText(count)
                    .font(fontPreset.captionFont.weight(.medium))
                    .foregroundStyle(countForegroundStyle(count, isActive: isActive))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .background(isActive ? Color.accentColor.opacity(0.16) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isActive)
    }

    private func countText(_ readiness: AgentContextCountReadiness) -> Text {
        switch readiness {
        case let .known(count):
            Text("\(count)")
        case .unknown:
            Text("—")
        }
    }

    private func countForegroundStyle(
        _ readiness: AgentContextCountReadiness,
        isActive: Bool
    ) -> HierarchicalShapeStyle {
        switch readiness {
        case .known:
            isActive ? .primary : .secondary
        case .unknown:
            .secondary
        }
    }

    @ViewBuilder
    private var content: some View {
        if isSwitchHidingRows || (modelCoordinator.isLoading && currentModel == nil) {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            emptyState(
                icon: "doc.text.magnifyingglass",
                title: "No selected context",
                subtitle: "Selections appear here when the agent or workspace selection adds files."
            )
        } else if isAwaitingCodemapRows {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredRows.isEmpty {
            emptyState(
                icon: "line.3.horizontal.decrease.circle",
                title: "No matches",
                subtitle: "No selected files match this filter."
            )
        } else if activeRows.isEmpty {
            emptyState(
                icon: detailStore.filesSubtab == .files ? "doc.text" : "square.grid.2x2",
                title: detailStore.filesSubtab == .files ? "No files" : "No codemaps",
                subtitle: detailStore.filesSubtab == .files
                    ? "Full files and sliced files appear in this subtab."
                    : "Codemap-only files appear in this subtab."
            )
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(activeRows) { row in
                        selectedFileCard(row)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
                .padding(.bottom, 20)
            }
        }
    }

    private func selectedFileCard(_ row: AgentContextExportRow) -> some View {
        AgentContextSelectedFileCard(
            row: row,
            canRemove: canMutateCurrentModel && row.canRemove,
            previewCoordinator: previewCoordinator,
            onLoadContent: { row, purpose in
                guard let model = currentModel else { return nil }
                return await AgentContextExportResolver.loadRowContent(
                    for: row,
                    model: model,
                    store: exportContext.promptManager.workspaceFileContextStore,
                    purpose: purpose
                )
            },
            onPromoteToFullFile: canMutateCurrentModel ? { row in
                guard let model = currentModel else { return }
                promoteToFullFile(row, from: model)
            } : nil,
            onDemoteToCodemap: canMutateCurrentModel ? { row in
                guard let model = currentModel else { return }
                demoteToCodemap(row, from: model)
            } : nil,
            onClearSlices: canMutateCurrentModel ? { row in
                guard let model = currentModel else { return }
                clearSlices(row, from: model)
            } : nil,
            onRemove: { row in
                guard let model = currentModel else { return }
                remove(row, from: model)
            }
        )
    }

    private func refreshIfNeeded(force: Bool = false, preserveDisplayedModel: Bool = false) {
        guard !isSwitchBlankingRows else { return }
        guard !exportContext.promptManager.isSwitchingComposeTab else { return }
        modelCoordinator.refreshIfNeeded(
            exportContext.makeModelRequest(flushPendingUI: true),
            force: force,
            preserveDisplayedModel: preserveDisplayedModel
        )
    }

    private func resetOrRefresh(isVisible: Bool) {
        guard !isSwitchBlankingRows else { return }
        guard !exportContext.promptManager.isSwitchingComposeTab else { return }
        modelCoordinator.invalidate()
        if isVisible {
            refreshIfNeeded()
        }
    }

    private func handleSelectionChange(_ change: WorkspaceSelectionCoordinator.Change, isVisible: Bool) {
        guard exportContext.tabMatchesSelectionChange(change) else { return }
        if isVisible {
            refreshIfNeeded(force: true, preserveDisplayedModel: true)
        } else {
            modelCoordinator.invalidate()
        }
    }

    private func clearSelection(for model: AgentContextExportModel) {
        guard let target = exportContext.activeSelectionMutationTarget(for: model.source) else { return }
        let updated = AgentContextExportResolver.removeSelectionSnapshot(
            model.source.selection,
            from: target.expectedSelection
        )
        Task {
            await exportContext.persistSelection(updated, target: target)
            await MainActor.run { refreshIfNeeded(force: true) }
        }
    }

    private func remove(_ row: AgentContextExportRow, from model: AgentContextExportModel) {
        guard row.canRemove,
              let target = exportContext.activeSelectionMutationTarget(for: model.source)
        else { return }
        Task {
            let updated = await AgentContextExportResolver.removeRow(
                row,
                from: target.expectedSelection,
                lookupContext: model.lookupContext,
                store: exportContext.promptManager.workspaceFileContextStore
            )
            await exportContext.persistSelection(updated, target: target)
            await MainActor.run { refreshIfNeeded(force: true) }
        }
    }

    private func promoteToFullFile(_ row: AgentContextExportRow, from model: AgentContextExportModel) {
        guard row.canPromoteToFullFile else { return }
        mutateSelectionPath(row, model: model) { selectionCoordinator, path, lookupContext, target in
            await selectionCoordinator.promotePathsInSelection(
                paths: [path],
                for: target.identity,
                expectedCurrentSelection: target.expectedSelection,
                lookupContext: lookupContext
            )
        }
    }

    private func demoteToCodemap(_ row: AgentContextExportRow, from model: AgentContextExportModel) {
        guard row.canDemoteToCodemap else { return }
        mutateSelectionPath(row, model: model) { selectionCoordinator, path, lookupContext, target in
            await selectionCoordinator.demotePathsInSelection(
                paths: [path],
                for: target.identity,
                expectedCurrentSelection: target.expectedSelection,
                lookupContext: lookupContext
            )
        }
    }

    private func clearSlices(_ row: AgentContextExportRow, from model: AgentContextExportModel) {
        guard row.canClearSlices else { return }
        mutateSelectionPath(row, model: model) { selectionCoordinator, path, lookupContext, target in
            await selectionCoordinator.clearSlicesInSelection(
                paths: [path],
                for: target.identity,
                expectedCurrentSelection: target.expectedSelection,
                lookupContext: lookupContext
            )
        }
    }

    private func mutateSelectionPath(
        _ row: AgentContextExportRow,
        model: AgentContextExportModel,
        operation: @escaping (
            WorkspaceSelectionCoordinator,
            String,
            WorkspaceLookupContext,
            AgentContextSelectionMutationTarget
        ) async -> Void
    ) {
        guard let selectionCoordinator = exportContext.selectionCoordinator,
              let target = exportContext.activeSelectionMutationTarget(for: model.source)
        else { return }
        let path = row.physicalPath ?? row.displayPath
        Task {
            await operation(selectionCoordinator, path, model.lookupContext, target)
            await MainActor.run { refreshIfNeeded(force: true) }
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.secondary.opacity(0.45))
            Text(title)
                .font(fontPreset.standardFont.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(fontPreset.captionFont)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func adjustActiveSubtab() {
        guard !isSwitchBlankingRows else { return }
        guard !exportContext.promptManager.isSwitchingComposeTab else { return }
        guard !isResolvingWithoutModel else { return }
        if detailStore.filesSubtab == .files, fileRows.isEmpty, !codemapRows.isEmpty {
            detailStore.filesSubtab = .codemaps
        } else if detailStore.filesSubtab == .codemaps, codemapRows.isEmpty, !fileRows.isEmpty, !isAwaitingCodemapRows {
            detailStore.filesSubtab = .files
        }
    }
}
