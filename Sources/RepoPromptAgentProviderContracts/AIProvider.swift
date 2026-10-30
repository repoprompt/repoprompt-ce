import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime

package protocol AIProvider {
    func streamMessage(_ aiMessage: RepoPromptDomainRuntime.AIMessage, model: AIModel, maxTokens: Int?) async throws -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error>
    func completeMessage(_ aiMessage: RepoPromptDomainRuntime.AIMessage, model: AIModel, maxTokens: Int?) async throws -> RepoPromptDomainRuntime.AICompletionResult
    func cleanupConversation(_ handle: RepoPromptDomainRuntime.ProviderConversationCleanupHandle, action: RepoPromptDomainRuntime.ProviderConversationCleanupAction) async -> RepoPromptDomainRuntime.ProviderConversationCleanupOutcome
    func dispose() async
}

package protocol AIModelGetter {
    func getAvailableModels() async throws -> [String]
}

/// Default protocol extensions
package extension AIProvider {
    func streamMessage(_ aiMessage: RepoPromptDomainRuntime.AIMessage, model: AIModel) async throws -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error> {
        try await streamMessage(aiMessage, model: model, maxTokens: nil)
    }

    func completeMessage(_ aiMessage: RepoPromptDomainRuntime.AIMessage, model: AIModel) async throws -> RepoPromptDomainRuntime.AICompletionResult {
        try await completeMessage(aiMessage, model: model, maxTokens: nil)
    }

    func cleanupConversation(_ handle: RepoPromptDomainRuntime.ProviderConversationCleanupHandle, action: RepoPromptDomainRuntime.ProviderConversationCleanupAction) async -> RepoPromptDomainRuntime.ProviderConversationCleanupOutcome {
        .unsupported(message: "Provider has no local API for \(action.rawValue) cleanup of conversations.")
    }

    func dispose() async {}
}
