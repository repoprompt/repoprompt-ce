import Foundation

final class DomainTestLockedState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(initialState: Value) {
        value = initialState
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&value) }
    }
}
