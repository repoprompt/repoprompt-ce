import SwiftUI

// MARK: - Selected Files Grid View

struct SelectedFilesGrid: View {
    enum FileDisplayKind: Int {
        case codemap = 0
        case slices = 1
        case full = 2

        var iconName: String {
            switch self {
            case .codemap: "square.grid.2x2"
            case .slices: "scissors"
            case .full: "doc.text"
            }
        }

        var accentColor: Color {
            switch self {
            case .codemap: Color.purple
            case .slices: Color.orange
            case .full: Color.accentColor
            }
        }

        func badgeText(for entry: PromptFileEntry) -> String? {
            switch self {
            case .codemap:
                return "Codemap"
            case .slices:
                let count = entry.ranges?.count ?? 0
                return count > 0 ? "Slices ×\(count)" : "Slices"
            case .full:
                return nil
            }
        }
    }

    let entries: [PromptFileEntry]
    let fileManager: WorkspaceFilesViewModel
    let onRemove: (PromptFileEntry) -> Void

    @State private var activeTab: Tab = .files
    @State private var hoveredTab: Tab?
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private enum Tab {
        case files
        case codemaps
    }

    private var sortedEntries: [(entry: PromptFileEntry, kind: FileDisplayKind)] {
        let computed = entries.map { entry -> (PromptFileEntry, FileDisplayKind) in
            let kind: FileDisplayKind = if entry.isCodemap {
                .codemap
            } else if let ranges = entry.ranges, !ranges.isEmpty {
                .slices
            } else {
                .full
            }
            return (entry, kind)
        }

        return computed.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1.rawValue < rhs.1.rawValue }
            let leftName = lhs.0.file.nameSortKey
            let rightName = rhs.0.file.nameSortKey
            if leftName != rightName { return leftName < rightName }
            if lhs.0.file.name != rhs.0.file.name { return lhs.0.file.name < rhs.0.file.name }
            let leftPath = lhs.0.file.uniqueRelativePathSortKey
            let rightPath = rhs.0.file.uniqueRelativePathSortKey
            if leftPath != rightPath { return leftPath < rightPath }
            return lhs.0.file.uniqueRelativePath < rhs.0.file.uniqueRelativePath
        }
    }

    var body: some View {
        let fileItems = sortedEntries.filter { $0.kind != .codemap }
        let codemapItems = sortedEntries.filter { $0.kind == .codemap }

        VStack(alignment: .leading, spacing: 6) {
            header(fileCount: fileItems.count)

            Divider()
                .padding(.vertical, 2)

            tabSwitcher(filesCount: fileItems.count, codemapsCount: codemapItems.count)

            if entries.isEmpty {
                emptyState(icon: "doc.text", title: "No files selected", size: 36)
            } else {
                let activeItems = activeTab == .files ? fileItems : codemapItems
                if activeItems.isEmpty {
                    emptyState(
                        icon: activeTab == .files ? "doc.text" : "square.grid.2x2",
                        title: activeTab == .files ? "No files in prompt" : "No codemaps in prompt",
                        size: 32
                    )
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(activeItems.enumerated()), id: \.element.entry.file.id) { index, element in
                                PromptFileTagRow(
                                    entry: element.entry,
                                    kind: element.kind,
                                    fileManager: fileManager,
                                    onRemove: onRemove,
                                    rowIndex: index
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
            adjustActiveTab(fileCount: fileItems.count, codemapCount: codemapItems.count)
        }
        .onChange(of: fileItems.count) { _, newValue in
            adjustActiveTab(fileCount: newValue, codemapCount: codemapItems.count)
        }
        .onChange(of: codemapItems.count) { _, newValue in
            adjustActiveTab(fileCount: fileItems.count, codemapCount: newValue)
        }
    }

    private func header(fileCount: Int) -> some View {
        HStack(alignment: .center) {
            Text("Prompt Files")
                .font(fontPreset.standardFont.weight(.medium))
                .foregroundColor(.primary)

            Circle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 4, height: 4)

            Text("\(fileCount)")
                .font(fontPreset.captionFont.weight(.medium))
                .foregroundColor(.secondary)

            Spacer()

            Button {
                Task { await fileManager.clearSelection(persistWorkspace: true) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    Text("Clear All")
                        .font(fontPreset.captionFont)
                }
            }
            .buttonStyle(CustomButtonStyle(verticalPadding: 3, horizontalPadding: 8))
            .disabled(entries.isEmpty)
            .hoverTooltip(entries.isEmpty ? "No files to clear" : "Remove all selected files and codemaps")
            .accessibilityHint(entries.isEmpty ? "No files to clear" : "Remove all selected files and codemaps")
        }
    }

    private func emptyState(icon: String, title: String, size: CGFloat) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundColor(.secondary.opacity(0.4))
            Text(title)
                .font(fontPreset.standardFont)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tabSwitcher(filesCount: Int, codemapsCount: Int) -> some View {
        HStack(spacing: 0) {
            tabButton(icon: "doc.text", label: "Files", count: filesCount, tab: .files) {
                activeTab = .files
            }

            tabButton(icon: "square.grid.2x2", label: "Codemaps", count: codemapsCount, tab: .codemaps) {
                activeTab = .codemaps
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, -12)
        .padding(.vertical, -6)
    }

    @ViewBuilder
    private func tabButton(
        icon: String,
        label: String,
        count: Int,
        tab: Tab,
        action: @escaping () -> Void
    ) -> some View {
        let isActive = activeTab == tab
        Button(action: action) {
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
            .background(hoveredTab == tab && !isActive ? Color.primary.opacity(0.08) : Color.clear)
            .foregroundColor(isActive ? Color.accentColor : (hoveredTab == tab ? Color.primary : Color.secondary))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(height: isActive ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isActive)
        .onHover { hovering in
            hoveredTab = hovering ? tab : nil
        }
    }

    private func adjustActiveTab(fileCount: Int, codemapCount: Int) {
        if activeTab == .files, fileCount == 0, codemapCount > 0 {
            activeTab = .codemaps
        } else if activeTab == .codemaps, codemapCount == 0, fileCount > 0 {
            activeTab = .files
        }
    }
}

private struct PromptFileTagRow: View {
    let entry: PromptFileEntry
    let kind: SelectedFilesGrid.FileDisplayKind
    let fileManager: WorkspaceFilesViewModel
    let onRemove: (PromptFileEntry) -> Void
    let rowIndex: Int

    @State private var showPopover = false
    @State private var hoveringPreview = false
    @State private var hoveringCopy = false
    @State private var hoveringRemove = false
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var accentColor: Color {
        kind.accentColor
    }

    private var directoryDisplay: String? {
        let unique = entry.file.uniqueRelativePath
        if let lastSlash = unique.lastIndex(of: "/") {
            let directory = String(unique[..<lastSlash])
            if !directory.isEmpty { return directory }
        }
        let root = entry.file.rootFolderName
        return root.isEmpty ? nil : root
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor.opacity(0.65))
                .frame(width: 4, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: kind.iconName)
                        .foregroundColor(accentColor)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))

                    Text(entry.file.name)
                        .font(fontPreset.standardFont.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let badge = kind.badgeText(for: entry) {
                        Text(badge)
                            .font(fontPreset.captionFont.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(accentColor.opacity(0.15))
                            .foregroundColor(accentColor)
                            .cornerRadius(6)
                    }

                    Spacer(minLength: 0)
                }

                if let directory = directoryDisplay {
                    Text(directory)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button {
                    showPopover = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(hoveringPreview ? accentColor : .primary)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(hoveringPreview ? accentColor.opacity(0.12) : Color.clear))
                }
                .buttonStyle(.plain)
                .hoverTooltip("Preview File")
                .onHover { hoveringPreview = $0 }

                Button(action: copyToClipboard) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(hoveringCopy ? accentColor : .primary)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(hoveringCopy ? accentColor.opacity(0.12) : Color.clear))
                }
                .buttonStyle(.plain)
                .hoverTooltip(kind == .codemap ? "Copy Codemap" : "Copy File Content")
                .onHover { hoveringCopy = $0 }

                Button {
                    onRemove(entry)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(hoveringRemove ? Color.red : .secondary)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(hoveringRemove ? Color.red.opacity(0.12) : Color.clear))
                }
                .buttonStyle(.plain)
                .hoverTooltip("Remove")
                .onHover { hoveringRemove = $0 }
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
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            FilePreviewPopover(
                file: entry.file,
                fileSlices: entry.ranges,
                codemapEntry: entry.codemap,
                fileManager: fileManager,
                showPreview: $showPopover
            )
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        if let codemap = entry.codemap {
            NSPasteboard.general.setString(codemap.text, forType: .string)
        } else if let content = entry.file.cachedContent {
            NSPasteboard.general.setString(content, forType: .string)
        } else {
            NSPasteboard.general.setString("", forType: .string)
        }
    }
}
