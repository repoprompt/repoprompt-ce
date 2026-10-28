import Foundation

/// Location evidence for a registered workspace. It grants no session administration authority.
struct HistoryWorkspaceLocation: Equatable {
    let runtimeID: UUID
    let lifecycleGeneration: UInt64
    let locationGeneration: UInt64
    let workspaceID: UUID
    let name: String
    let directory: URL

    init(
        runtimeID: UUID, lifecycleGeneration: UInt64 = 1, locationGeneration: UInt64 = 1,
        workspaceID: UUID, name: String, directory: URL
    ) {
        self.runtimeID = runtimeID
        self.lifecycleGeneration = lifecycleGeneration
        self.locationGeneration = locationGeneration
        self.workspaceID = workspaceID
        self.name = name
        self.directory = directory.standardizedFileURL
    }
}

enum HistoryWorkspaceSelector: Equatable {
    case id(UUID)
    case exactName(String)
}

enum HistoryWorkspaceSelection: Equatable {
    case matched(HistoryWorkspaceLocation)
    case ambiguous
    case unavailable
    case notReady
    case notRegistered
}

struct HistoryWorkspaceLocationResolver {
    let resolve: @Sendable (HistoryWorkspaceSelector) async -> HistoryWorkspaceSelection
}
