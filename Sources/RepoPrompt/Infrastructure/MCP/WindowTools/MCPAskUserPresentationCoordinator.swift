import Foundation

actor MCPAskUserPresentationCoordinator {
    typealias Cancellation = @Sendable () async -> Void

    static let shared = MCPAskUserPresentationCoordinator()

    private static let tombstoneLimit = 256
    private static let tombstoneLifetime: TimeInterval = 60

    private var cancellations: [UUID: Cancellation] = [:]
    private var cancelledBeforeRegistration: [UUID: Date] = [:]
    private var completed: [UUID: Date] = [:]

    func register(requestID: UUID, cancellation: @escaping Cancellation) async -> Bool {
        pruneTombstones()
        guard cancellations[requestID] == nil,
              completed[requestID] == nil
        else {
            return false
        }
        if cancelledBeforeRegistration.removeValue(forKey: requestID) != nil {
            rememberCompletion(requestID)
            await cancellation()
            return false
        }
        cancellations[requestID] = cancellation
        return true
    }

    func unregister(requestID: UUID) {
        cancellations.removeValue(forKey: requestID)
        cancelledBeforeRegistration.removeValue(forKey: requestID)
        rememberCompletion(requestID)
    }

    @discardableResult
    func cancel(requestID: UUID) async -> Bool {
        pruneTombstones()
        guard completed[requestID] == nil else { return false }
        guard let cancellation = cancellations.removeValue(forKey: requestID) else {
            cancelledBeforeRegistration[requestID] = Date()
            Self.bound(&cancelledBeforeRegistration)
            return false
        }
        rememberCompletion(requestID)
        await cancellation()
        return true
    }

    private func rememberCompletion(_ requestID: UUID) {
        completed[requestID] = Date()
        Self.bound(&completed)
    }

    private func pruneTombstones(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.tombstoneLifetime)
        cancelledBeforeRegistration = cancelledBeforeRegistration.filter { $0.value >= cutoff }
        completed = completed.filter { $0.value >= cutoff }
    }

    private static func bound(_ values: inout [UUID: Date]) {
        guard values.count > tombstoneLimit else { return }
        for key in values.sorted(by: { $0.value < $1.value })
            .prefix(values.count - tombstoneLimit)
            .map(\.key)
        {
            values.removeValue(forKey: key)
        }
    }

    #if DEBUG
        func test_hasPresentation(requestID: UUID) -> Bool {
            cancellations[requestID] != nil
        }

        func test_wasCancelledBeforeRegistration(requestID: UUID) -> Bool {
            cancelledBeforeRegistration[requestID] != nil
        }

        func test_tombstoneCounts() -> (early: Int, completed: Int) {
            (cancelledBeforeRegistration.count, completed.count)
        }
    #endif
}
