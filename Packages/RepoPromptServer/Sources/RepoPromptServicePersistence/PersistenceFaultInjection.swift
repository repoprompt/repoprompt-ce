import Foundation

enum PersistenceFaultPoint: String, Sendable {
    case afterIdempotencyPreflightMiss
    case afterTransactionBegin
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
