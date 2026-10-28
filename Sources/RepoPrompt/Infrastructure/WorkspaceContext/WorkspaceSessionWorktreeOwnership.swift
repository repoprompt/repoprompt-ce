import Foundation
import RepoPromptWorkspaceCore

package struct WorkspaceSessionWorktreeOwnershipToken: Hashable {
    let ownerID: UUID
    let generation: UInt64
}

struct WorkspaceSessionWorktreeOwnedRoot: Hashable {
    let rootID: UUID
    package let lifetimeID: UUID
    let standardizedPhysicalPath: String
}

/// Ephemeral authority for one exact root owned by an Agent session. This value is
/// request-local and is never persisted or encoded.
package struct WorkspaceSessionRootAuthorization: Hashable {
    package let sessionID: UUID
    package let ownershipGeneration: UInt64
    package let root: WorkspaceRootRef
    package let lifetimeID: UUID
}

package enum WorkspaceSessionRootAuthorizationMismatch: String, Equatable {
    case token
    case generation
    case rootClaim
    case rootID
    case lifetime
    case kind
    case path
}

package enum WorkspaceAuthorizedSelectionCandidateRoute: String, Equatable {
    case catalogFile
    case materializedFile
    case catalogFolder
}

package enum WorkspaceAuthorizedSelectionCandidateBlock: String, Equatable {
    case invalidPath
    case outsideAuthorizedRoot
    case symbolicLink
    case symlinkComponent
    case outsideCanonicalRoot
    case nonRegularFile
    case materializationFailed
}

package enum WorkspaceAuthorizedSelectionCandidateResolution: Equatable {
    case resolved(files: [WorkspaceFileRecord], route: WorkspaceAuthorizedSelectionCandidateRoute)
    case noCandidate
    case blockedOrAmbiguous(WorkspaceAuthorizedSelectionCandidateBlock)
    case staleAuthority(WorkspaceSessionRootAuthorizationMismatch)
}

struct WorkspaceRootSeedShadowScope: Hashable {
    package let token: WorkspaceSessionWorktreeOwnershipToken
    let bindingFingerprint: String
    let rootID: UUID
    package let lifetimeID: UUID
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
    package let token: WorkspaceSessionWorktreeOwnershipToken
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
            "The requested Agent worktree path is already loaded as a workspace folder with incompatible ownership: \(path). Remove that folder from this workspace before binding, or use a separate workspace. The existing folder ownership was not changed."
        }
    }
}
