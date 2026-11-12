import SwiftUI

enum AgentSelectedFilesTab {
    case files
    case codemaps
}

extension AgentSelectedFilesRowSplit {
    func rows(for tab: AgentSelectedFilesTab) -> [AgentContextExportRow] {
        switch tab {
        case .files: fileRows
        case .codemaps: codemapRows
        }
    }
}

@MainActor
func adjustAgentSelectedFilesTab(_ activeTab: Binding<AgentSelectedFilesTab>, fileCount: Int, codemapCount: Int) {
    if activeTab.wrappedValue == .files, fileCount == 0, codemapCount > 0 {
        activeTab.wrappedValue = .codemaps
    } else if activeTab.wrappedValue == .codemaps, codemapCount == 0, fileCount > 0 {
        activeTab.wrappedValue = .files
    }
}

@MainActor
func agentSelectedFilesEmptyState(title: String, fontPreset: FontScalePreset) -> some View {
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

@MainActor
func agentSelectedFilesTabButton(icon: String, label: String, count: Int, isActive: Bool, fontPreset: FontScalePreset, padding: CGSize, minHeight: CGFloat, inactiveLineOpacity: Double, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
            Text(label)
                .font(fontPreset.captionFont.weight(.semibold))
            Text("\(count)")
                .font(fontPreset.captionFont.weight(.medium))
        }
        .padding(.horizontal, padding.width)
        .padding(.vertical, padding.height)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .foregroundColor(isActive ? Color.accentColor : Color.secondary)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isActive ? Color.accentColor : Color.secondary.opacity(inactiveLineOpacity))
                .frame(height: isActive ? 2 : 1)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isActive)
}

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
    @State private var activeTab: AgentSelectedFilesTab = .files

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var rows: [AgentContextExportRow] {
        model?.rows ?? []
    }

    var body: some View {
        let split = AgentSelectedFilesRowSplit(rows: rows)

        VStack(alignment: .leading, spacing: 6) {
            header(split: split)
            Divider().padding(.vertical, 2)
            tabSwitcher(split: split)

            if isLoading, model == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if split.rows.isEmpty {
                agentSelectedFilesEmptyState(title: "No files selected", fontPreset: fontPreset)
            } else {
                let activeRows = split.rows(for: activeTab)
                if activeRows.isEmpty {
                    agentSelectedFilesEmptyState(title: activeTab == .files ? "No files in Agent context" : "No codemaps in Agent context", fontPreset: fontPreset)
                } else {
                    rowList(activeRows)
                }
            }
        }
        .padding(8)
        .onAppear {
            onRefresh()
            adjustAgentSelectedFilesTab($activeTab, fileCount: split.fileRows.count, codemapCount: split.codemapRows.count)
        }
        .onChange(of: split.fileRows.count) { _, _ in
            adjustAgentSelectedFilesTab($activeTab, fileCount: split.fileRows.count, codemapCount: split.codemapRows.count)
        }
        .onChange(of: split.codemapRows.count) { _, _ in
            adjustAgentSelectedFilesTab($activeTab, fileCount: split.fileRows.count, codemapCount: split.codemapRows.count)
        }
        .onChange(of: activeTab) { _, _ in
            previewCoordinator.reconcileVisibleRows(split.rows(for: activeTab))
        }
        .onChange(of: split.rows.map(\.id)) { _, _ in
            previewCoordinator.reconcileVisibleRows(split.rows(for: activeTab))
        }
    }

    private func header(split: AgentSelectedFilesRowSplit) -> some View {
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

    private func tabSwitcher(split: AgentSelectedFilesRowSplit) -> some View {
        HStack(spacing: 0) {
            agentSelectedFilesTabButton(icon: "doc.text", label: "Files", count: split.fileRows.count, isActive: activeTab == .files, fontPreset: fontPreset, padding: CGSize(width: 14, height: 8), minHeight: 34, inactiveLineOpacity: 0.2) {
                activeTab = .files
            }
            agentSelectedFilesTabButton(icon: "square.grid.2x2", label: "Codemaps", count: split.codemapRows.count, isActive: activeTab == .codemaps, fontPreset: fontPreset, padding: CGSize(width: 14, height: 8), minHeight: 34, inactiveLineOpacity: 0.2) {
                activeTab = .codemaps
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, -12)
        .padding(.vertical, -6)
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
}
