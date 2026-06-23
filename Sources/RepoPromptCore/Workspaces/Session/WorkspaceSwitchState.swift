import Foundation

package enum WorkspaceSwitchPhase: String, Equatable, Codable {
    case idle
    case preparing
    case flushing
    case unloadingRoots
    case restoring
    case awaitingPresentation
    case hydratingRoots
    case committed
    case recovering
    case failed
}

package struct WorkspaceSwitchOperationID: Hashable, Codable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

package enum WorkspaceSwitchReason: Equatable, Codable {
    case user
    case restoration
    case workspaceDeleted
    case recovery
    case other(String)
}

package struct WorkspaceSwitchState: Equatable, Codable {
    package var operationID: WorkspaceSwitchOperationID?
    package var phase: WorkspaceSwitchPhase
    package var sourceWorkspaceID: UUID?
    package var targetWorkspaceID: UUID?
    package var reason: WorkspaceSwitchReason?
    package var destructiveBoundaryCrossed: Bool
    package var commitBoundaryCrossed: Bool
    package var message: String?

    package static let idle = WorkspaceSwitchState()

    package init(
        operationID: WorkspaceSwitchOperationID? = nil,
        phase: WorkspaceSwitchPhase = .idle,
        sourceWorkspaceID: UUID? = nil,
        targetWorkspaceID: UUID? = nil,
        reason: WorkspaceSwitchReason? = nil,
        destructiveBoundaryCrossed: Bool = false,
        commitBoundaryCrossed: Bool = false,
        message: String? = nil
    ) {
        self.operationID = operationID
        self.phase = phase
        self.sourceWorkspaceID = sourceWorkspaceID
        self.targetWorkspaceID = targetWorkspaceID
        self.reason = reason
        self.destructiveBoundaryCrossed = destructiveBoundaryCrossed
        self.commitBoundaryCrossed = commitBoundaryCrossed
        self.message = message
    }
}

package enum WorkspaceSwitchResult: Equatable {
    case switched(WorkspaceSessionCommandReceipt)
    case unchanged(WorkspaceSessionCommandReceipt)
    case cancelledBeforeDestructiveBoundary
    case recovered(WorkspaceSessionSnapshot)
    case failed(WorkspaceSessionFailure)
}
