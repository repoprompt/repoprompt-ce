import Foundation
import RepoPromptMCPServer

/// Progress is observational: cancelling a heartbeat must not replace an operation's
/// settled partial result. The operation still owns its ordinary cancellation behavior.
enum MCPToolHeartbeat {
    static func runProgress<T: Sendable>(
        connectionID: UUID?, tool: String, stage: String, message: String,
        invocation: ToolInvocationContext, interval: Duration = .seconds(30),
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let connectionID,
              await ServerNetworkManager.shared.supportsProgressNotifications(connectionID: connectionID)
        else { return try await operation() }
        return try await run(interval: interval) {
            await MCPInvocationContextBridge.withInvocation(invocation) {
                await ServerNetworkManager.shared.sendProgress(
                    for: connectionID, tool: tool, kind: .heartbeat, stage: stage, message: message
                )
            }
        } operation: {
            try await MCPInvocationContextBridge.withInvocation(invocation) { try await operation() }
        }
    }

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
