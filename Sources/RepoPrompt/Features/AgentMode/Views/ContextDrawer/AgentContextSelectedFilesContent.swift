import SwiftUI

enum AgentContextSelectedFilesLayout: Equatable {
    case list
    case adaptiveGrid(minimumWidth: CGFloat)
}

struct AgentContextSelectedFilesContent: View {
    let model: AgentContextExportModel?
    let isLoading: Bool
    let canMutate: Bool
    let layout: AgentContextSelectedFilesLayout
    let onRefresh: () -> Void
    let onLoadContent: (AgentContextExportRow, AgentContextExportRow.ContentPurpose) async -> String?
    let onRemove: (AgentContextExportRow, AgentContextExportModel) -> Void
    let onClear: (AgentContextExportModel) -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    @StateObject private var previewCoordinator = AgentSelectedFilePreviewLoadCoordinator()
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
                    rowList(activeRows)
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
        .onChange(of: activeTab) { _, _ in
            previewCoordinator.reconcileVisibleRows(split.rows(for: activeTab))
        }
        .onChange(of: split.rows.map(\.id)) { _, _ in
            previewCoordinator.reconcileVisibleRows(split.rows(for: activeTab))
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

    private func rowList(_ activeRows: [AgentContextExportRow]) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            switch layout {
            case .list:
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(activeRows) { row in
                        selectedFileCard(row: row)
                    }
                }
                .padding(.trailing, 4)
            case let .adaptiveGrid(minimumWidth):
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: 8, alignment: .top)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(activeRows) { row in
                        selectedFileCard(row: row)
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func selectedFileCard(row: AgentContextExportRow) -> some View {
        AgentContextSelectedFileCard(
            row: row,
            canRemove: canMutate && row.canRemove,
            previewCoordinator: previewCoordinator,
            onLoadContent: onLoadContent,
            onPromoteToFullFile: nil,
            onDemoteToCodemap: nil,
            onClearSlices: nil,
            onRemove: { row in
                guard let model else { return }
                onRemove(row, model)
            }
        )
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
