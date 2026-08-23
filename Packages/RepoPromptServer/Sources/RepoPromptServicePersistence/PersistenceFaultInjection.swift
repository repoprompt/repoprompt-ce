import Foundation

public enum PersistenceFaultPoint: String, Sendable {
    case afterIdempotencyPreflightMiss
    case afterTransactionBegin
    case afterEventInsertBeforeSequenceAdvance
    case beforeTransactionCommit
}

public struct PersistenceFaultInjector: Sendable {
    private let operation: @Sendable (PersistenceFaultPoint) async throws -> Void

    public init(_ operation: @escaping @Sendable (PersistenceFaultPoint) async throws -> Void) {
        self.operation = operation
    }

    public func hit(_ point: PersistenceFaultPoint) async throws {
        try await operation(point)
    }

    public static let none = PersistenceFaultInjector { _ in }
}
