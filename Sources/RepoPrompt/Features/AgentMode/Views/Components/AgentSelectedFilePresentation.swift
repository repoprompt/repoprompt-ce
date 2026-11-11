import SwiftUI

@MainActor
protocol AgentSelectedFilePresenting: View {
    var row: AgentContextExportRow { get }
    var previewCoordinator: AgentSelectedFilePreviewLoadCoordinator { get }
    var onLoadContent: (AgentContextExportRow, AgentContextExportRow.ContentPurpose) async -> String? { get }
    var copyTask: Task<Void, Never>? { get nonmutating set }
    var isCopying: Bool { get nonmutating set }
}

extension AgentSelectedFilePresenting {
    var accentColor: Color {
        switch row.kind {
        case .codemap: .purple
        case .slices: .orange
        case .full: .accentColor
        }
    }

    var leadingIconName: String {
        switch row.kind {
        case .codemap: "square.grid.2x2"
        case .slices: "curlybraces"
        case .full: "doc.text"
        }
    }

    var sliceCountText: String? {
        guard row.kind == .slices, let count = row.lineRanges?.count, count > 0 else { return nil }
        return "\(count)"
    }

    var parentPathDisplay: String? {
        let parent = (row.relativePath as NSString).deletingLastPathComponent
        guard parent != ".", !parent.isEmpty else { return nil }
        let components = parent.split(separator: "/").map(String.init)
        guard components.count > 2 else { return parent }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    func presentingFilePreview(@ViewBuilder content: () -> some View) -> some View {
        content()
            .popover(
                isPresented: Binding(
                    get: { previewCoordinator.isPreviewPresented(for: row) },
                    set: { previewCoordinator.handlePreviewPresentationChanged(row: row, isPresented: $0) }
                ),
                arrowEdge: .bottom
            ) {
                AgentResolvedFilePreviewPopover(row: row, previewCoordinator: previewCoordinator)
            }
            .onDisappear {
                previewCoordinator.handleRowDisappear(row: row)
                copyTask?.cancel()
            }
    }

    func openPreview() {
        previewCoordinator.openPreview(row: row, loadContent: onLoadContent)
    }

    func copyToClipboard() {
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

@MainActor
protocol AgentFileActionPresenting: View {
    var systemName: String { get }
    var tooltip: String { get }
    var rowIsHovered: Bool { get }
    var hoverColor: Color { get }
    var isLoading: Bool { get }
    var isDisabled: Bool { get }
    var action: () -> Void { get }
    var isButtonHovered: Bool { get }
}

extension AgentFileActionPresenting {
    private var foregroundColor: Color {
        guard !isDisabled else { return .secondary.opacity(0.35) }
        if isButtonHovered { return hoverColor }
        return .secondary.opacity(rowIsHovered ? 1 : 0.55)
    }

    var actionButton: some View {
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
    }
}
