import Foundation
import RepoPromptClaudeProvider

/// Core facade for Claude-compatible prompt packaging. The pure packaging rules
/// live in the provider package; settings/defaults stay in core.
enum ClaudeCodePromptDelivery {
    static let instructionsTag = "claude_code_instructions"

    static func decoratedUserMessage(_ userMessage: String, instructions: String) -> String {
        ClaudeCompatibleProviderRuntimeBridge.decoratedUserMessage(userMessage, instructions: instructions)
    }
}
