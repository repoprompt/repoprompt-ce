import Foundation

/// Structured helper for async setup/teardown pairs.
/// Mirrors the semantics of `TaskSemaphore.withPermit`, but allows callers
/// to await both the entry and cleanup phases without resorting to launching
/// detached `Task`s from a `defer`.
package enum AsyncScope {
    @discardableResult
    package static func withCleanup<T>(
        _ enter: () async throws -> Void,
        cleanup: () async -> Void,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await enter()
        do {
            let value = try await operation()
            await cleanup()
            return value
        } catch {
            await cleanup()
            throw error
        }
    }
}
