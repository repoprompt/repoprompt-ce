import Foundation

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
