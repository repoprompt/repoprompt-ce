import Foundation

enum WorkspaceCodemapMarkerReadinessState: Hashable {
    case ready
    case unavailable
}

struct WorkspaceCodemapMarkerReadinessChange: Hashable {
    let fileID: UUID
    let standardizedRelativePath: String
    let requestGeneration: UInt64
    let pathGeneration: UInt64
    let state: WorkspaceCodemapMarkerReadinessState
}

/// Small immutable publication emitted after durable projection state changes.
/// Consumers validate the root epoch and per-path generation before caching it.
struct WorkspaceCodemapMarkerReadinessUpdate: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let changes: [WorkspaceCodemapMarkerReadinessChange]
}

struct WorkspaceCodemapMarkerReadinessEvent: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let revision: UInt64
    let changes: [WorkspaceCodemapMarkerReadinessChange]
}
