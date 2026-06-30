import Foundation

struct WorkspaceSessionWorktreeOwnershipToken: Hashable {
    let ownerID: UUID
    let generation: UInt64
}

struct WorkspaceSessionWorktreeOwnedRoot: Hashable {
    let rootID: UUID
    let lifetimeID: UUID
    let standardizedPhysicalPath: String
}

/// Ephemeral authority for one exact root owned by an Agent session. This value is
/// request-local and is never persisted or encoded.
struct WorkspaceSessionRootAuthorization: Hashable {
    let sessionID: UUID
    let ownershipGeneration: UInt64
    let root: WorkspaceRootRef
    let lifetimeID: UUID
}

enum WorkspaceSessionRootAuthorizationMismatch: String, Equatable {
    case token
    case generation
    case rootClaim
    case rootID
    case lifetime
    case kind
    case path
}

enum WorkspaceAuthorizedSelectionCandidateRoute: String, Equatable {
    case catalogFile
    case materializedFile
    case catalogFolder
}

enum WorkspaceAuthorizedSelectionCandidateBlock: String, Equatable {
    case invalidPath
    case outsideAuthorizedRoot
    case symbolicLink
    case symlinkComponent
    case outsideCanonicalRoot
    case nonRegularFile
    case materializationFailed
}

enum WorkspaceAuthorizedSelectionCandidateResolution: Equatable {
    case resolved(files: [WorkspaceFileRecord], route: WorkspaceAuthorizedSelectionCandidateRoute)
    case noCandidate
    case blockedOrAmbiguous(WorkspaceAuthorizedSelectionCandidateBlock)
    case staleAuthority(WorkspaceSessionRootAuthorizationMismatch)
}

struct WorkspaceRootSeedShadowScope: Hashable {
    let token: WorkspaceSessionWorktreeOwnershipToken
    let bindingFingerprint: String
    let rootID: UUID
    let lifetimeID: UUID
    let standardizedPhysicalPath: String
    let catalogGeneration: UInt64
    let appliedIndexGeneration: UInt64
}

struct WorkspaceRootSeedShadowPreparation {
    let scope: WorkspaceRootSeedShadowScope
    let snapshot: WorkspaceRootReusableSnapshot
    let planHandle: WorkspaceRootTargetSeedPlanHandle
}

struct WorkspaceSessionWorktreeOwnershipPreparation {
    let token: WorkspaceSessionWorktreeOwnershipToken
    let bindingFingerprint: String
    let roots: [WorkspaceSessionWorktreeOwnedRoot]
    let reusesInstalledOwnership: Bool
    let materializationHintObservationsByPhysicalRootPath: [
        String: WorkspaceRootMaterializationHintObservation
    ]
    let rootSeedShadowPreparations: [WorkspaceRootSeedShadowPreparation]
    let pendingSeededRootPreparations: [WorkspacePendingSeededRootPreparation]

    init(
        token: WorkspaceSessionWorktreeOwnershipToken,
        bindingFingerprint: String,
        roots: [WorkspaceSessionWorktreeOwnedRoot],
        reusesInstalledOwnership: Bool,
        materializationHintObservationsByPhysicalRootPath: [
            String: WorkspaceRootMaterializationHintObservation
        ] = [:],
        rootSeedShadowPreparations: [WorkspaceRootSeedShadowPreparation] = [],
        pendingSeededRootPreparations: [WorkspacePendingSeededRootPreparation] = []
    ) {
        self.token = token
        self.bindingFingerprint = bindingFingerprint
        self.roots = roots
        self.reusesInstalledOwnership = reusesInstalledOwnership
        self.materializationHintObservationsByPhysicalRootPath = materializationHintObservationsByPhysicalRootPath
        self.rootSeedShadowPreparations = rootSeedShadowPreparations
        self.pendingSeededRootPreparations = pendingSeededRootPreparations
    }
}

enum WorkspaceSessionWorktreeOwnershipError: LocalizedError, Equatable {
    case staleUpdate
    case unavailableRoot(String)
    case invalidRootKind(String)

    var errorDescription: String? {
        switch self {
        case .staleUpdate:
            "The Agent session worktree ownership changed while it was being prepared."
        case let .unavailableRoot(path):
            "The Agent session worktree root is unavailable: \(path)"
        case let .invalidRootKind(path):
            "The requested Agent worktree path is already loaded with incompatible ownership: \(path)"
        }
    }
}
