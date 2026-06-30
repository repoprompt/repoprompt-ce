import Foundation

struct WorkspaceCodemapLogicalPresentationPath: Hashable {
    let rootDisplayName: String
    let standardizedRelativePath: String

    var displayPath: String {
        rootDisplayName + "/" + standardizedRelativePath
    }

    init?(
        rootDisplayName: String,
        standardizedRelativePath: String
    ) {
        guard !rootDisplayName.isEmpty,
              !rootDisplayName.contains("/"),
              !StandardizedPath.containsNUL(rootDisplayName),
              !standardizedRelativePath.isEmpty,
              !standardizedRelativePath.hasPrefix("/"),
              !StandardizedPath.containsNUL(standardizedRelativePath),
              StandardizedPath.relative(standardizedRelativePath) == standardizedRelativePath,
              standardizedRelativePath != "..",
              !standardizedRelativePath.hasPrefix("../")
        else {
            return nil
        }

        self.rootDisplayName = rootDisplayName
        self.standardizedRelativePath = standardizedRelativePath
    }
}

struct WorkspaceCodemapPresentationRequest {
    let ticket: WorkspaceCodemapArtifactDemandTicket
    let logicalPath: WorkspaceCodemapLogicalPresentationPath
}

struct WorkspaceCodemapFrozenPresentationBundleID: Hashable {
    private let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct WorkspaceCodemapFrozenPresentationEntry: Equatable {
    let ticket: WorkspaceCodemapArtifactDemandTicket
    let logicalPath: WorkspaceCodemapLogicalPresentationPath
    let artifactKey: CodeMapArtifactKey
    let outcome: WorkspaceCodemapLiveArtifactOutcome
}

private final class WorkspaceCodemapPresentationLease: @unchecked Sendable {
    let handles: [WorkspaceCodemapLiveFrozenArtifactHandle]

    init(handles: [WorkspaceCodemapLiveFrozenArtifactHandle]) {
        self.handles = handles
    }
}

struct WorkspaceCodemapFrozenPresentationBundle {
    let id: WorkspaceCodemapFrozenPresentationBundleID
    let rootEpoch: WorkspaceCodemapRootEpoch
    let entries: [WorkspaceCodemapFrozenPresentationEntry]

    private let lease: WorkspaceCodemapPresentationLease

    init(
        id: WorkspaceCodemapFrozenPresentationBundleID = .init(),
        rootEpoch: WorkspaceCodemapRootEpoch,
        entries: [WorkspaceCodemapFrozenPresentationEntry],
        handles: [WorkspaceCodemapLiveFrozenArtifactHandle]
    ) {
        precondition(entries.count == handles.count)
        self.id = id
        self.rootEpoch = rootEpoch
        self.entries = entries
        lease = WorkspaceCodemapPresentationLease(handles: handles)
    }
}

struct WorkspaceCodemapRenderedPresentationEntry: Equatable {
    let ticket: WorkspaceCodemapArtifactDemandTicket
    let logicalPath: WorkspaceCodemapLogicalPresentationPath
    let artifactKey: CodeMapArtifactKey
    let outcome: WorkspaceCodemapLiveArtifactOutcome
    let text: String
    let tokenCount: Int
}

enum WorkspaceCodemapPresentationFreezeUnavailableReason: Equatable {
    case emptyRequest
    case entryLimitExceeded(limit: Int)
    case retainedBundleLimitExceeded(limit: Int)
    case duplicateFileID(UUID)
    case mixedRootEpoch
    case pending(WorkspaceCodemapArtifactDemandTicket)
    case demandUnavailable(
        WorkspaceCodemapArtifactDemandTicket,
        WorkspaceCodemapArtifactDemandUnavailableReason
    )
    case logicalPathMismatch(UUID)
    case staleCurrentness
    case handleRevoked(UUID)
}

enum WorkspaceCodemapPresentationFreezeDisposition {
    case ready(WorkspaceCodemapFrozenPresentationBundle)
    case unavailable(WorkspaceCodemapPresentationFreezeUnavailableReason)
}

enum WorkspaceCodemapPresentationRenderUnavailableReason: Equatable {
    case bundleNotRetained
    case bundleMetadataMismatch
    case staleCurrentness(WorkspaceCodemapArtifactDemandTicket)
    case handleRevoked(UUID)
    case noRenderableCodemap(UUID)
}

enum WorkspaceCodemapPresentationRenderDisposition {
    case ready([WorkspaceCodemapRenderedPresentationEntry])
    case unavailable(WorkspaceCodemapPresentationRenderUnavailableReason)
}
