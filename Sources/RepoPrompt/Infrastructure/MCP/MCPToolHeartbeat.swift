import Foundation

/// Progress is observational: cancelling a heartbeat must not replace an operation's
/// settled partial result. The operation still owns its ordinary cancellation behavior.
enum MCPToolHeartbeat {
    static func run<T: Sendable>(
        interval: Duration = .seconds(30),
        heartbeat: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let heartbeatTask = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: interval)
                    try Task.checkCancellation()
                    await heartbeat()
                }
            } catch {
                // Cancellation is the expected completion path for progress delivery.
            }
        }
        let outcome: Result<T, Error>
        do {
            outcome = try await .success(operation())
        } catch {
            outcome = .failure(error)
        }
        heartbeatTask.cancel()
        // Cancellation is cooperative: an in-flight progress callback must drain before
        // terminal progress or a response can be delivered for this request.
        await heartbeatTask.value
        return try outcome.get()
    }
}
