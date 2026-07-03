import Foundation

/// Compact per-root codemap projection activity derived from accepted
/// `WorkspaceCodemapRootProjectionProgressEvent`s. Keyed by root UUID
/// (`FolderViewModel.id` / `WorkspaceRootShellProjection.id`); never keyed by path.
enum WorkspaceRootCodemapActivity: Equatable {
    /// Projection scan/publish in flight. `total` is known only once the
    /// projection catalog has completed paging; a nil total renders as
    /// indeterminate progress.
    case scanning(processed: UInt64, total: UInt64?)
    /// Projection coverage is sealed/complete for the root's current generation.
    case ready(processed: UInt64)

    init(event: WorkspaceCodemapRootProjectionProgressEvent) {
        let processed = event.progress.counts.processedCandidateCount
        if event.isSealed || event.progress.phase == .complete {
            self = .ready(processed: processed)
        } else {
            self = .scanning(
                processed: processed,
                total: event.progress.catalogCompletion?.supportedCandidateCount
            )
        }
    }
}
