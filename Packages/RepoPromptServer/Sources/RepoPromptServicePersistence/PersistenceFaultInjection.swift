import Foundation

enum PersistenceFaultPoint: String, Sendable {
    case afterIdempotencyPreflightMiss
    case afterAuthorityStateCAS
    case afterAuthorityRunWrite
    case afterAuthorityTransitionWrite
    case afterAuthorityPresentationWrite
    case afterAuthoritySessionWrite
    case afterAuthorityAgentWrite
    case afterProviderEventReceiptInsert
    case afterProviderRunWrite
    case afterProviderPresentationWrite
    case afterProviderSemanticWrite
    case afterProviderAgentWrite
    case afterProviderSessionWrite
    case afterProviderToolWrite
    case afterProviderInteractionWrite
    case afterProviderContextUsageWrite
    case afterTransactionBegin
    case afterEventInsertBeforeOutboxInsert
    case afterOutboxInsertBeforeSequenceAdvance
    case afterEventInsertBeforeSequenceAdvance
    case afterMigrationStatement
    case beforeMigrationLedgerInsert
    case afterMigrationLedgerInsert
    case beforeTransactionCommit
}

struct PersistenceFaultInjector: Sendable {
    private let operation: @Sendable (PersistenceFaultPoint) async throws -> Void

    init(_ operation: @escaping @Sendable (PersistenceFaultPoint) async throws -> Void) {
        self.operation = operation
    }

    func hit(_ point: PersistenceFaultPoint) async throws {
        try await operation(point)
    }

    static let none = PersistenceFaultInjector { _ in }
}
