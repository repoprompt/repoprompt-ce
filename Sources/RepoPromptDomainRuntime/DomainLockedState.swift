import Foundation

final class DomainLockedState<State: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(initialState: State) {
        state = initialState
    }

    func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&state) }
    }
}
