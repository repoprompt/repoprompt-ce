import Foundation

#if DEBUG
    enum CodemapFullLoadSwitchResult: String, Equatable {
        case pending
        case switched
        case cancelled
        case blocked
    }

    struct CodemapFullLoadCorrelation: Equatable {
        let armID: UUID
        let targetWorkspaceID: UUID
        let targetWorkspaceName: String
        let pollIntervalMilliseconds: Int
        let timeoutMilliseconds: Int
        let armedUptimeNanoseconds: UInt64
        var operationID: UUID?
        var acceptedUptimeNanoseconds: UInt64?
        var switchResult: CodemapFullLoadSwitchResult
        var invalidReason: String?

        mutating func recordAccepted(
            operationID: UUID,
            targetWorkspaceID: UUID,
            uptimeNanoseconds: UInt64
        ) -> Bool {
            guard invalidReason == nil,
                  self.targetWorkspaceID == targetWorkspaceID,
                  self.operationID == nil
            else { return false }
            self.operationID = operationID
            acceptedUptimeNanoseconds = uptimeNanoseconds
            switchResult = .pending
            return true
        }

        mutating func recordCompletion(
            operationID: UUID,
            result: WorkspaceSwitchResult
        ) -> Bool {
            guard invalidReason == nil, self.operationID == operationID else { return false }
            switch result {
            case .switched:
                switchResult = .switched
            case .cancelled:
                switchResult = .cancelled
                invalidReason = "switch_cancelled"
            case .blocked:
                switchResult = .blocked
                invalidReason = "switch_blocked"
            }
            return true
        }
    }

    enum CodemapFullLoadArmError: Error, Equatable {
        case targetNotFound
        case targetAmbiguous
        case targetAlreadyActive
    }

#endif
