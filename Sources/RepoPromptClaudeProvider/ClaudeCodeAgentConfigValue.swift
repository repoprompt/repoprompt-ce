import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts

/// Explicit configuration values supplied by the application composition layer.
package struct ClaudeCodeAgentConfig {
    package let commandName: String
    package let additionalPathHints: [String]
    package let modelString: String?
    package let runtimeVariant: ClaudeCodeRuntimeVariant
    package let enableDebugLogging: Bool
    package let sdkConnectTimeoutSeconds: TimeInterval
    package let sdkRelaunchMaxAttempts: Int
    package let permissionMode: String
    package let allowNativeBashTool: Bool
    package let toolContext: AgentCLIToolContext
    package let disallowedBuiltInTools: [String]
    package let mcpStrictMode: Bool
    package let toolSearchEnabled: Bool
    package let effortLevel: ClaudeCodeEffortLevel?

    package init(
        commandName: String,
        additionalPathHints: [String],
        modelString: String?,
        runtimeVariant: ClaudeCodeRuntimeVariant,
        enableDebugLogging: Bool,
        sdkConnectTimeoutSeconds: TimeInterval,
        sdkRelaunchMaxAttempts: Int,
        permissionMode: String,
        allowNativeBashTool: Bool,
        toolContext: AgentCLIToolContext,
        disallowedBuiltInTools: [String],
        mcpStrictMode: Bool,
        toolSearchEnabled: Bool,
        effortLevel: ClaudeCodeEffortLevel?
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.modelString = modelString
        self.runtimeVariant = runtimeVariant
        self.enableDebugLogging = enableDebugLogging
        self.sdkConnectTimeoutSeconds = sdkConnectTimeoutSeconds
        self.sdkRelaunchMaxAttempts = sdkRelaunchMaxAttempts
        self.permissionMode = permissionMode
        self.allowNativeBashTool = allowNativeBashTool
        self.toolContext = toolContext
        self.disallowedBuiltInTools = disallowedBuiltInTools
        self.mcpStrictMode = mcpStrictMode
        self.toolSearchEnabled = toolSearchEnabled
        self.effortLevel = effortLevel
    }

    package var effortEnvironmentOverrides: [String: String] {
        guard let effortLevel else { return [:] }
        return ["CLAUDE_CODE_EFFORT_LEVEL": effortLevel.envValue]
    }
}
