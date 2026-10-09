import Foundation
import RepoPromptProviderQuota

/// App-owned process adapter for the app-free quota transport port. This client is
/// exclusively owned by the quota runtime, never borrowed from an Agent Mode run.
actor CodexQuotaAppServerAdapter: CodexQuotaAppServerClient {
    private let client: CodexAppServerClient

    init(client: CodexAppServerClient) {
        self.client = client
    }

    func startIfNeeded() async throws {
        try await client.startIfNeeded()
    }

    func subscribeNotifications() async -> AsyncStream<CodexQuotaNotification> {
        let source = await client.subscribeNotifications()
        // Do not coalesce sparse bucket updates: two different buckets must both survive.
        let (stream, continuation) = AsyncStream<CodexQuotaNotification>.makeStream()
        let relay = Task {
            for await notification in source {
                guard !Task.isCancelled else { break }
                guard notification.method == CodexProviderQuotaMapper.updatedNotificationMethod else { continue }
                continuation.yield(CodexQuotaNotification(method: notification.method, params: notification.params))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in relay.cancel() }
        return stream
    }

    func request(method: String, params: [String: CodexJSONValue]?, timeout: TimeInterval?) async throws -> [String: CodexJSONValue] {
        let response = try await client.request(method: method, params: params?.mapValues { $0.toAny() }, timeout: timeout)
        return response.compactMapValues { CodexJSONValue.from($0) }
    }

    func stop() async {
        await client.stop()
    }
}
