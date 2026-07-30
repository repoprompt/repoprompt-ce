import Foundation

struct WorkspaceCodemapArtifactDemandTicket: Hashable {
    let retainID: UUID
    let requestID: UUID
    let rootEpoch: WorkspaceCodemapRootEpoch
    let fileID: UUID
    let requestGeneration: UInt64
    let catalogGeneration: UInt64
    let pathGeneration: UInt64
    let ingressGeneration: UInt64
}

enum WorkspaceCodemapArtifactDemandUnavailableReason: Equatable {
    case rootNotLoaded
    case fileNotCataloged
    case unsupportedFileType
    case gitTerminal(WorkspaceCodemapGitTerminalUnavailableReason)
    case gitTransient(WorkspaceCodemapGitTransientUnavailableReason)
    case demandUnavailable(WorkspaceCodemapBindingDemandUnavailableReason)
    case busy(retryAfterMilliseconds: Int?)
    case rejected(WorkspaceCodemapBindingDemandRejection)
    case routeConflict
    case registrationFailed
    case runtimeFailure
    case staleCurrentness
    case cancelled
}

struct WorkspaceCodemapArtifactDemandReady {
    let ticket: WorkspaceCodemapArtifactDemandTicket
    let identity: WorkspaceCodemapArtifactBindingIdentity
    let snapshot: WorkspaceCodemapLiveReadySnapshot
    let handle: WorkspaceCodemapLiveFrozenArtifactHandle
}

enum WorkspaceCodemapArtifactDemandResult {
    case unavailable(WorkspaceCodemapArtifactDemandUnavailableReason)
    case pending(WorkspaceCodemapArtifactDemandTicket)
    case ready(WorkspaceCodemapArtifactDemandReady)
}

enum WorkspaceCodemapArtifactDemandOwnershipDisposition {
    case notAcquired
    case created(WorkspaceCodemapArtifactDemandTicket)
    case joined(WorkspaceCodemapArtifactDemandTicket)
}

struct WorkspaceCodemapArtifactDemandOwnedResult {
    let result: WorkspaceCodemapArtifactDemandResult
    let ownership: WorkspaceCodemapArtifactDemandOwnershipDisposition
}
