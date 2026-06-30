import Foundation

/// Store-local identity for a root whose watcher and catalog are prepared before
/// any of its records become visible to workspace readers.
struct WorkspacePendingSeededRootID: Hashable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Opaque handle carried by the outer binding transaction. The corresponding
/// root remains private until the ownership preparation is committed.
struct WorkspacePendingSeededRootPreparation: Hashable {
    let id: WorkspacePendingSeededRootID
}

/// Closed lifecycle owned exclusively by `WorkspaceFileContextStore`.
enum WorkspacePendingSeededRootPhase: Equatable {
    case reserved
    case watcherCapturing
    case planning
    case seedInstalled
    case replaying(FileSystemWatcherIngressMailbox.Watermark)
    case preparingShard
    case readyForCommit
    case fallingBack(WorkspaceRootSeedFallbackReason)
    case published
    case aborted
}
