import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptDomainRuntime

package typealias ClaudeHeadlessAgentContext = HeadlessLaunchContext<ClaudeCompatiblePluginLaunchEnvironment>

package protocol ClaudeHeadlessConfigPreparing: Actor {
    func prepareClaudeHeadlessLaunchConfig() throws -> any LaunchConfigLease
}

/// One synchronous preference snapshot, taken at the original stream evaluation site.
package struct ClaudeHeadlessPromptDelivery {
    package let userMessage: (String, String) -> String
    package let nativeSystemPromptOverride: (String) -> String?

    package init(
        userMessage: @escaping (String, String) -> String,
        nativeSystemPromptOverride: @escaping (String) -> String?
    ) {
        self.userMessage = userMessage
        self.nativeSystemPromptOverride = nativeSystemPromptOverride
    }
}

/// App capabilities only. The process, stream task, and cleanup scopes stay in the provider.
package protocol ClaudeHeadlessHosting {
    func currentPromptDelivery() -> ClaudeHeadlessPromptDelivery
    func buildArguments(config: ClaudeCodeAgentConfig, context: ClaudeHeadlessAgentContext, resumeSessionID: String?, systemPromptOverride: String?) -> [String]
    func isReasoningExtractionEnabled() -> Bool
    func expectedClientName(for variant: ClaudeCodeRuntimeVariant) -> String?
    func registerExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID) async
    func clearExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID) async
    func startTracking(runID: UUID, clientNameHint: String, continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation)
    @MainActor func stopTracking() async
}
