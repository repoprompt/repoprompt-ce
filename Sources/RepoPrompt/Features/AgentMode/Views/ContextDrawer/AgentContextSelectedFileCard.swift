import SwiftUI

struct AgentContextSelectedFileCardMetricRowPresentation: Equatable {
    enum Content: Equatable {
        case known(AgentContextExportRow.Metrics.Known)
        case pathOnly(String)
        case hidden
    }

    let content: Content
    let accessibilityLabel: String?

    static func make(
        rowKind: AgentContextExportRow.Kind,
        metrics: AgentContextExportRow.Metrics,
        parentPathDisplay: String?,
        displayPath: String,
        sliceCountText: String?
    ) -> AgentContextSelectedFileCardMetricRowPresentation {
        switch metrics {
        case let .known(values):
            AgentContextSelectedFileCardMetricRowPresentation(
                content: .known(values),
                accessibilityLabel: knownAccessibilityLabel(
                    rowKind: rowKind,
                    metrics: values,
                    sliceCountText: sliceCountText
                )
            )
        case .unknown where rowKind == .codemap:
            AgentContextSelectedFileCardMetricRowPresentation(content: .hidden, accessibilityLabel: nil)
        case .unknown:
            AgentContextSelectedFileCardMetricRowPresentation(
                content: .pathOnly(parentPathDisplay ?? displayPath),
                accessibilityLabel: pathAccessibilityLabel(displayPath: displayPath, sliceCountText: sliceCountText)
            )
        }
    }

    static func percentText(for metrics: AgentContextExportRow.Metrics.Known) -> String {
        let percentage = metrics.tokenPercentage
        if percentage <= 0 { return "0%" }
        if percentage < 0.01 { return "<1%" }
        return "\(Int((percentage * 100).rounded()))%"
    }

    static func tokenTooltip(for metrics: AgentContextExportRow.Metrics.Known) -> String {
        "≈\(metrics.tokenCount.formatted(.number.grouping(.automatic))) tokens"
    }

    private static func knownAccessibilityLabel(
        rowKind: AgentContextExportRow.Kind,
        metrics: AgentContextExportRow.Metrics.Known,
        sliceCountText: String?
    ) -> String {
        var components = [
            "Approximate tokens: \(AgentContextIndicator.formatTokens(metrics.tokenCount))",
            "Share of selected context: \(percentText(for: metrics))"
        ]
        if rowKind != .codemap, let lineCount = metrics.lineCount {
            components.append("Included lines: \(lineCount)")
        }
        if let sliceCountText {
            components.append("Selected slice ranges: \(sliceCountText)")
        }
        return components.joined(separator: ", ")
    }

    private static func pathAccessibilityLabel(displayPath: String, sliceCountText: String?) -> String {
        var components = ["Path: \(displayPath)"]
        if let sliceCountText {
            components.append("Selected slice ranges: \(sliceCountText)")
        }
        return components.joined(separator: ", ")
    }
}

struct AgentContextSelectedFileCard: View {
    let row: AgentContextExportRow
    let canRemove: Bool
    @ObservedObject var previewCoordinator: AgentSelectedFilePreviewLoadCoordinator
    let onLoadContent: (AgentContextExportRow, AgentContextExportRow.ContentPurpose) async -> String?
    let onPromoteToFullFile: ((AgentContextExportRow) -> Void)?
    let onDemoteToCodemap: ((AgentContextExportRow) -> Void)?
    let onClearSlices: ((AgentContextExportRow) -> Void)?
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
            return "Expanded from a selected folder; remove the folder selection to remove this file"
        }
        if !canRemove {
            return "Selection mutation is unavailable for this Agent context"
        }
        return nil
    }

    private var canPromoteToFullFile: Bool {
        canRemove && row.canPromoteToFullFile && onPromoteToFullFile != nil
    }

    private var canDemoteToCodemap: Bool {
        canRemove && row.canDemoteToCodemap && onDemoteToCodemap != nil
    }

    private var canClearSlices: Bool {
        canRemove && row.canClearSlices && onClearSlices != nil
    }

    private var sliceCountText: String? {
        guard row.kind == .slices, let count = row.lineRanges?.count, count > 0 else { return nil }
        return "\(count)"
    }

    private var parentPathDisplay: String? {
        let parent = (row.relativePath as NSString).deletingLastPathComponent
        guard parent != ".", !parent.isEmpty else { return nil }
        let components = parent.split(separator: "/").map(String.init)
        guard components.count > 2 else { return parent }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: leadingIconName)
                .symbolRenderingMode(.monochrome)
                .foregroundColor(accentColor)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .medium))
                .imageScale(.medium)
                .frame(width: 18, height: 18)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                titleRow
                detailRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isHovered
                        ? Color(NSColor.controlBackgroundColor).opacity(0.34)
                        : Color(NSColor.controlBackgroundColor).opacity(0.16)
                )
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

    private var titleRow: some View {
        HStack(spacing: 7) {
            Text(row.displayName)
                .font(fontPreset.standardFont.weight(.medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .accessibilityLabel(row.displayPath)
                .accessibilityHint(pathTooltip)

            if row.showRootPill, !row.rootDisplayName.isEmpty {
                rootPill
            }

            Spacer(minLength: 0)

            if let sliceCountText {
                Text(sliceCountText)
                    .font(fontPreset.captionFont.weight(.semibold).monospacedDigit())
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .fixedSize()
                    .hoverTooltip("\(sliceCountText) selected slice ranges")
                    .accessibilityLabel("\(sliceCountText) selected slice ranges")
            }
        }
    }

    private var rootPill: some View {
        Text(row.rootDisplayName)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
            .foregroundColor(Color(red: 0.72, green: 0.82, blue: 0.74))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 0.37, green: 0.56, blue: 0.42).opacity(0.28))
            )
            .fixedSize(horizontal: true, vertical: false)
            .hoverTooltip(pathTooltip)
            .accessibilityLabel("Root: \(row.rootDisplayName)")
    }

    private var detailRow: some View {
        HStack(spacing: 8) {
            metricsPathRow
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            actionControls
        }
    }

    @ViewBuilder
    private var metricsPathRow: some View {
        switch metricRowPresentation.content {
        case let .known(metrics):
            knownMetricsPathRow(metrics)
        case let .pathOnly(pathText):
            Text(pathText)
                .font(fontPreset.captionFont.monospacedDigit())
                .foregroundColor(.secondary.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.middle)
                .hoverTooltip(pathTooltip)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(metricRowPresentation.accessibilityLabel ?? row.displayPath)
                .accessibilityHint(pathTooltip)
        case .hidden:
            EmptyView()
                .accessibilityHidden(true)
        }
    }

    private func knownMetricsPathRow(_ metrics: AgentContextExportRow.Metrics.Known) -> some View {
        let percentText = AgentContextSelectedFileCardMetricRowPresentation.percentText(for: metrics)
        return HStack(spacing: 6) {
            Text("~\(AgentContextIndicator.formatTokens(metrics.tokenCount))")
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .hoverTooltip(AgentContextSelectedFileCardMetricRowPresentation.tokenTooltip(for: metrics))

            metricsSeparator

            Text(percentText)
                .hoverTooltip("\(percentText) of selected context")

            if row.kind != .codemap {
                if let lineCount = metrics.lineCount {
                    metricsSeparator

                    Text("\(lineCount)")
                        .hoverTooltip("\(lineCount) \(lineCount == 1 ? "line" : "lines")")
                }

                if let parentPathDisplay {
                    metricsSeparator

                    Text(parentPathDisplay)
                        .foregroundColor(.secondary.opacity(0.72))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .hoverTooltip(pathTooltip)
                }
            }
        }
        .font(fontPreset.captionFont.monospacedDigit())
        .foregroundColor(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metricRowPresentation.accessibilityLabel ?? row.displayPath)
        .accessibilityHint(pathTooltip)
    }

    private var metricRowPresentation: AgentContextSelectedFileCardMetricRowPresentation {
        AgentContextSelectedFileCardMetricRowPresentation.make(
            rowKind: row.kind,
            metrics: row.metrics,
            parentPathDisplay: parentPathDisplay,
            displayPath: row.displayPath,
            sliceCountText: sliceCountText
        )
    }

    private var metricsSeparator: some View {
        Text("·")
            .foregroundColor(.secondary.opacity(0.5))
    }

    private var pathTooltip: String {
        var lines = [row.displayPath]
        if !row.rootDisplayName.isEmpty {
            lines.append("Root: \(row.rootDisplayName)")
        }
        if let physicalPath = row.physicalPath, physicalPath != row.displayPath {
            lines.append(physicalPath)
        }
        return lines.joined(separator: "\n")
    }

    private var actionControls: some View {
        HStack(spacing: 3) {
            AgentContextFileActionButton(
                systemName: "eye",
                tooltip: "Preview",
                rowIsHovered: isHovered,
                isLoading: previewCoordinator.isLoadingPreview(for: row),
                action: openPreview
            )

            AgentContextFileActionButton(
                systemName: "doc.on.doc",
                tooltip: row.kind == .codemap ? "Copy codemap" : "Copy file content",
                rowIsHovered: isHovered,
                isLoading: isCopying,
                isDisabled: isCopying,
                action: copyToClipboard
            )

            AgentContextFileActionMenu(
                rowIsHovered: isHovered,
                canPromoteToFullFile: canPromoteToFullFile,
                canDemoteToCodemap: canDemoteToCodemap,
                canClearSlices: canClearSlices,
                hasPhysicalPath: row.physicalPath != nil,
                onPromoteToFullFile: { onPromoteToFullFile?(row) },
                onDemoteToCodemap: { onDemoteToCodemap?(row) },
                onClearSlices: { onClearSlices?(row) },
                onCopyAbsolutePath: copyAbsolutePath,
                onCopyRelativePath: copyRelativePath,
                onOpenFile: openFile,
                onRevealInFinder: revealInFinder
            )

            removeControl
        }
        .fixedSize()
    }

    @ViewBuilder
    private var removeControl: some View {
        if let disabledRemoveExplanation {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .regular))
                .imageScale(.medium)
                .foregroundColor(.secondary.opacity(isHovered ? 1 : 0.55))
                .frame(width: 26, height: 26)
                .hoverTooltip(disabledRemoveExplanation)
                .accessibilityLabel(disabledRemoveExplanation)
        } else {
            AgentContextFileActionButton(
                systemName: "minus.circle",
                tooltip: "Remove from Agent selection",
                rowIsHovered: isHovered,
                hoverColor: .red,
                action: { onRemove(row) }
            )
        }
    }

    private func openPreview() {
        previewCoordinator.openPreview(row: row, loadContent: onLoadContent)
    }

    private func copyAbsolutePath() {
        guard let physicalPath = row.physicalPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(physicalPath, forType: .string)
    }

    private func copyRelativePath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.relativePath, forType: .string)
    }

    private func openFile() {
        guard let physicalPath = row.physicalPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: physicalPath))
    }

    private func revealInFinder() {
        guard let physicalPath = row.physicalPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: physicalPath)])
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

private struct AgentContextFileActionButton: View {
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
        .accessibilityLabel(tooltip)
        .onHover { hovering in
            isButtonHovered = hovering
        }
    }
}

private struct AgentContextFileActionMenu: View {
    let rowIsHovered: Bool
    let canPromoteToFullFile: Bool
    let canDemoteToCodemap: Bool
    let canClearSlices: Bool
    let hasPhysicalPath: Bool
    let onPromoteToFullFile: () -> Void
    let onDemoteToCodemap: () -> Void
    let onClearSlices: () -> Void
    let onCopyAbsolutePath: () -> Void
    let onCopyRelativePath: () -> Void
    let onOpenFile: () -> Void
    let onRevealInFinder: () -> Void

    @State private var isButtonHovered = false

    private var foregroundColor: Color {
        if isButtonHovered { return .primary }
        return .secondary.opacity(rowIsHovered ? 1 : 0.55)
    }

    var body: some View {
        Menu {
            if canPromoteToFullFile {
                Button(action: onPromoteToFullFile) {
                    Label("Convert to Full File", systemImage: "doc.text")
                }
            }
            if canDemoteToCodemap {
                Button(action: onDemoteToCodemap) {
                    Label("Convert to Codemap", systemImage: "square.grid.2x2")
                }
            }
            if canClearSlices {
                Button(action: onClearSlices) {
                    Label("Clear Slices", systemImage: "scissors.badge.ellipsis")
                }
            }

            if canPromoteToFullFile || canDemoteToCodemap || canClearSlices {
                Divider()
            }

            Button(action: onCopyAbsolutePath) {
                Label("Copy Absolute Path", systemImage: "link.circle")
            }
            .disabled(!hasPhysicalPath)

            Button(action: onCopyRelativePath) {
                Label("Copy Relative Path", systemImage: "link")
            }

            Button(action: onOpenFile) {
                Label("Open File", systemImage: "arrow.up.right.square")
            }
            .disabled(!hasPhysicalPath)

            Button(action: onRevealInFinder) {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(!hasPhysicalPath)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .regular))
                .imageScale(.medium)
                .foregroundColor(foregroundColor)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverTooltip("More actions")
        .accessibilityLabel("More actions")
        .onHover { hovering in
            isButtonHovered = hovering
        }
    }
}
