import Foundation

package enum OracleGroupTerminalPublisher {
    package static func publish(
        terminal: OracleGroupDocument,
        expectedRevision: UInt64,
        store: any OracleGroupStore
    ) async throws -> OracleGroupDocument {
        let intent = try OracleTerminalPublicationIntent(
            terminal: terminal,
            expectedRevision: expectedRevision
        )
        let priority = Task.currentPriority
        return try await Task.detached(priority: priority) {
            let firstStagingError: Error?
            do {
                try await store.stageTerminalPublication(intent)
                firstStagingError = nil
            } catch {
                firstStagingError = error
            }

            let firstReconciliationError: Error
            do {
                return try await reconcileExact(intent, store: store)
            } catch {
                firstReconciliationError = error
            }

            var retryStagingError: Error?
            if firstStagingError != nil,
               shouldRetryStaging(after: firstReconciliationError)
            {
                do {
                    try await store.stageTerminalPublication(intent)
                } catch {
                    retryStagingError = error
                }
            }

            do {
                return try await reconcileExact(intent, store: store)
            } catch {
                if isNotStaged(error) {
                    throw retryStagingError ?? firstStagingError ?? firstReconciliationError
                }
                throw error
            }
        }.value
    }

    private static func reconcileExact(
        _ intent: OracleTerminalPublicationIntent,
        store: any OracleGroupStore
    ) async throws -> OracleGroupDocument {
        let reconciled = try await store.reconcileTerminalPublication(intent)
        guard reconciled == intent.terminal else {
            throw OraclePersistenceError.terminalPublicationMismatch
        }
        return reconciled
    }

    private static func isNotStaged(_ error: Error) -> Bool {
        error as? OraclePersistenceError == .terminalPublicationNotStaged
    }

    private static func shouldRetryStaging(after error: Error) -> Bool {
        if isNotStaged(error) { return true }
        if error is OracleGroupContractError { return false }
        return error as? OraclePersistenceError == nil
    }
}
