import Foundation

package enum WorkspaceCodemapMarkerReadinessState: Hashable {
    case ready
    case unavailable
    case securityExcluded
}

package struct WorkspaceCodemapMarkerReadinessChange: Hashable {
    package let fileID: UUID
    let standardizedRelativePath: String
    package let requestGeneration: UInt64
    package let pathGeneration: UInt64
    package let state: WorkspaceCodemapMarkerReadinessState
}

/// Small immutable publication emitted after durable projection state changes.
/// Consumers validate the root epoch and per-path generation before caching it.
struct WorkspaceCodemapMarkerReadinessUpdate: Hashable {
    package let rootEpoch: WorkspaceCodemapRootEpoch
    package let changes: [WorkspaceCodemapMarkerReadinessChange]
}

package struct WorkspaceCodemapMarkerReadinessEvent: Hashable {
    package let rootEpoch: WorkspaceCodemapRootEpoch
    let revision: UInt64
    package let changes: [WorkspaceCodemapMarkerReadinessChange]
}
