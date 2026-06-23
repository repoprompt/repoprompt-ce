import Foundation

package struct WorkspaceSessionWorktreeOwnershipToken: Hashable {
    package let ownerID: UUID
    package let generation: UInt64
}

package struct WorkspaceSessionWorktreeOwnedRoot: Hashable {
    package let rootID: UUID
    package let lifetimeID: UUID
    package let standardizedPhysicalPath: String
}

/// Ephemeral authority for one exact root owned by an Agent session. This value is
/// request-local and is never persisted or encoded.
package struct WorkspaceSessionRootAuthorization: Hashable {
    package let sessionID: UUID
    package let ownershipGeneration: UInt64
    package let root: WorkspaceRootRef
    package let lifetimeID: UUID

    package init(sessionID: UUID, ownershipGeneration: UInt64, root: WorkspaceRootRef, lifetimeID: UUID) {
        self.sessionID = sessionID
        self.ownershipGeneration = ownershipGeneration
        self.root = root
        self.lifetimeID = lifetimeID
    }
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

package struct WorkspaceSessionWorktreeOwnershipPreparation {
    package let token: WorkspaceSessionWorktreeOwnershipToken
    let bindingFingerprint: String
    package let roots: [WorkspaceSessionWorktreeOwnedRoot]
    package let reusesInstalledOwnership: Bool
}

package enum WorkspaceSessionWorktreeOwnershipError: LocalizedError, Equatable {
    case staleUpdate
    case unavailableRoot(String)
    case invalidRootKind(String)

    package var errorDescription: String? {
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
