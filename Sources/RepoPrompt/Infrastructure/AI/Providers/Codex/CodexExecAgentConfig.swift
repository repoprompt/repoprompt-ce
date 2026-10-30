import Foundation
import RepoPromptProcess

/// Configuration for Codex Exec agent provider.
package struct CodexExecAgentConfig {
    package let commandName: String
    package let additionalPathHints: [String]
    package let modelString: String?
    package let enableDebugLogging: Bool
    package let fullAccess: Bool

    package init(
        commandName: String,
        additionalPathHints: [String],
        modelString: String?,
        enableDebugLogging: Bool,
        fullAccess: Bool
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.modelString = modelString
        self.enableDebugLogging = enableDebugLogging
        self.fullAccess = fullAccess
    }
}
