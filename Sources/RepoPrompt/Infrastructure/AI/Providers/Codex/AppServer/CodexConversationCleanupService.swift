import Foundation

struct CodexConversationCleanupService {
    typealias RequestExecutor = @Sendable (
        _ method: String,
        _ params: [String: Any]?,
        _ timeout: TimeInterval?
    ) async throws -> [String: Any]

    static let conversationSummaryMethod = "getConversationSummary"
    static let archiveThreadMethod = "thread/archive"
    static let deleteThreadMethod = "thread/delete"

    let requestExecutor: RequestExecutor
    let timeout: TimeInterval?

    init(
        requestExecutor: @escaping RequestExecutor,
        timeout: TimeInterval? = nil
    ) {
        self.requestExecutor = requestExecutor
        self.timeout = timeout
    }

    func cleanup(
        _ handle: ProviderConversationCleanupHandle,
        action: ProviderConversationCleanupAction
    ) async -> ProviderConversationCleanupOutcome {
        let method: String
        let successMessage: String
        switch action {
        case .archive:
            method = Self.archiveThreadMethod
            successMessage = "Archived Codex conversation."
        case .delete:
            method = Self.deleteThreadMethod
            successMessage = "Deleted Codex conversation."
        }

        do {
            let threadID = try await resolveThreadID(from: handle)
            _ = try await requestExecutor(
                method,
                ["threadId": threadID],
                timeout
            )
            return .succeeded(message: successMessage)
        } catch let error as CleanupError {
            return error.outcome
        } catch is CancellationError {
            return .cancelled(message: "Codex conversation cleanup was cancelled.")
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    private func resolveThreadID(from handle: ProviderConversationCleanupHandle) async throws -> String {
        if let conversationID = normalized(handle.conversationID) {
            return conversationID
        }
        guard let rolloutPath = normalized(handle.rolloutPath) else {
            throw CleanupError.unsupported("Codex cleanup requires a conversation ID or rollout path.")
        }
        let response = try await requestExecutor(
            Self.conversationSummaryMethod,
            ["rolloutPath": rolloutPath],
            timeout
        )
        guard let threadID = Self.threadID(fromConversationSummaryResponse: response) else {
            throw CleanupError.failed("Codex app-server did not return a conversation ID for rollout path cleanup.")
        }
        return threadID
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func threadID(fromConversationSummaryResponse response: [String: Any]) -> String? {
        if let direct = firstString(
            in: response,
            keys: ["conversationId", "conversationID", "threadId", "threadID", "id"]
        ) {
            return direct
        }
        for key in ["summary", "conversation", "thread"] {
            if let object = response[key] as? [String: Any],
               let nested = firstString(
                   in: object,
                   keys: ["conversationId", "conversationID", "threadId", "threadID", "id"]
               )
            {
                return nested
            }
        }
        return nil
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringScalarValue(from: object[key]) {
                return value
            }
        }
        return nil
    }

    private static func stringScalarValue(from value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as CustomStringConvertible:
            let string = value.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return string.isEmpty ? nil : string
        default:
            return nil
        }
    }

    private enum CleanupError: Error {
        case unsupported(String)
        case failed(String)

        var outcome: ProviderConversationCleanupOutcome {
            switch self {
            case let .unsupported(message):
                .unsupported(message: message)
            case let .failed(message):
                .failed(message: message)
            }
        }
    }
}
