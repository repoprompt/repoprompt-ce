import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptClaudeProvider

#if DEBUG
    private var claudeCodeAgentConfigDebugLoggingEnabled = false
    private func claudeCodeAgentConfigDebugLog(_ message: @autoclosure () -> String) {
        guard claudeCodeAgentConfigDebugLoggingEnabled else { return }
        print("[ClaudeCode] \(message())")
    }
#else
    private func claudeCodeAgentConfigDebugLog(_ message: @autoclosure () -> String) {}
#endif

/// App-owned construction and policy for Claude Code agent configuration.
extension ClaudeCodeAgentConfig {
    var processEnvironmentOverrides: [String: String] {
        Self.processEnvironmentOverrides(for: toolContext)
    }

    static func processEnvironmentOverrides(for toolContext: AgentCLIToolContext) -> [String: String] {
        switch toolContext {
        case .agentRun, .terminal:
            MCPIntegrationHelper.claudeProcessEnvironmentOverrides
        case .discoverRun, .promptOnly:
            [:]
        }
    }

    // MARK: - Agent Mode (interactive, user-controlled permissions)

    /// Config for interactive Agent Mode runs.
    /// Reads permission mode and bash tool preference from user settings.
    static func agentMode(
        commandName: String? = nil,
        modelString: String? = nil,
        runtimeVariant: ClaudeCodeRuntimeVariant = .standard,
        enableDebugLogging: Bool = false,
        sdkConnectTimeoutSeconds: TimeInterval = 10,
        sdkRelaunchMaxAttempts: Int = 1,
        permissionMode: String? = nil,
        allowNativeBashTool: Bool? = nil,
        disallowedBuiltInTools: [String]? = nil,
        mcpStrictMode: Bool? = nil,
        toolSearchEnabled: Bool? = nil,
        effortLevel: ClaudeCodeEffortLevel? = nil
    ) -> ClaudeCodeAgentConfig {
        let defaults = UserDefaults.standard
        let resolvedPermission = sanitizePermissionMode(
            permissionMode ?? ClaudeAgentToolPreferences.permissionMode(defaults: defaults)
        )
        let resolvedBash = allowNativeBashTool
            ?? ClaudeAgentToolPreferences.bashToolEnabled(defaults: defaults)
        let resolvedStrictMode = mcpStrictMode
            ?? ClaudeAgentToolPreferences.mcpStrictModeEnabled(defaults: defaults)
        let resolvedToolSearch = toolSearchEnabled
            ?? ClaudeAgentToolPreferences.toolSearchEnabled(defaults: defaults)
        let resolvedEffortLevel = effortLevel
            ?? agentModeEffortLevel(
                modelString: modelString,
                runtimeVariant: runtimeVariant,
                defaults: defaults
            )
        return ClaudeCodeAgentConfig(
            commandName: commandName,
            modelString: modelString,
            runtimeVariant: runtimeVariant,
            enableDebugLogging: enableDebugLogging,
            sdkConnectTimeoutSeconds: sdkConnectTimeoutSeconds,
            sdkRelaunchMaxAttempts: sdkRelaunchMaxAttempts,
            permissionMode: resolvedPermission,
            allowNativeBashTool: resolvedBash,
            toolContext: .agentRun,
            disallowedBuiltInTools: disallowedBuiltInTools,
            mcpStrictMode: resolvedStrictMode,
            toolSearchEnabled: resolvedToolSearch,
            effortLevel: resolvedEffortLevel
        )
    }

    private static func agentModeEffortLevel(
        modelString: String?,
        runtimeVariant: ClaudeCodeRuntimeVariant,
        defaults: UserDefaults
    ) -> ClaudeCodeEffortLevel? {
        guard !isNoModelCompatibleBackend(runtimeVariant) else { return nil }
        return ClaudeAgentToolPreferences.effortLevel(
            forModelRaw: modelString,
            agentKind: runtimeVariant.agentKind,
            defaults: defaults
        )
    }

    // MARK: - Discovery (headless, restricted MCP-only toolset)

    /// Config for headless discovery runs.
    /// Permissions are skipped via --dangerously-skip-permissions at the CLI level.
    /// Never reads from agent mode user preferences.
    static func discovery(
        commandName: String? = nil,
        modelString: String? = nil,
        runtimeVariant: ClaudeCodeRuntimeVariant = .standard,
        enableDebugLogging: Bool = false
    ) -> ClaudeCodeAgentConfig {
        ClaudeCodeAgentConfig(
            commandName: commandName,
            modelString: modelString,
            runtimeVariant: runtimeVariant,
            enableDebugLogging: enableDebugLogging,
            sdkConnectTimeoutSeconds: 10,
            sdkRelaunchMaxAttempts: 1,
            permissionMode: "bypassPermissions",
            allowNativeBashTool: false,
            toolContext: .discoverRun,
            disallowedBuiltInTools: nil,
            mcpStrictMode: true,
            toolSearchEnabled: false,
            effortLevel: nil
        )
    }

    // MARK: - Private memberwise init

    /// Low-level initializer. Prefer the named factory methods above.
    private init(
        commandName: String?,
        modelString: String?,
        runtimeVariant: ClaudeCodeRuntimeVariant,
        enableDebugLogging: Bool,
        sdkConnectTimeoutSeconds: TimeInterval,
        sdkRelaunchMaxAttempts: Int,
        permissionMode: String,
        allowNativeBashTool: Bool,
        toolContext: MCPIntegrationHelper.CLIToolContext,
        disallowedBuiltInTools: [String]?,
        mcpStrictMode: Bool,
        toolSearchEnabled: Bool,
        effortLevel: ClaudeCodeEffortLevel?
    ) {
        let resolvedCommand = commandName ?? "claude"
        let modelSpecifier = ClaudeModelSpecifier(raw: modelString)
        claudeCodeAgentConfigDebugLog("Using command '\(resolvedCommand)' (DEBUG build)")
        let additionalPathHints = CLIPathHints.claudeCode
        let resolvedModel = modelSpecifier.runtimeModelParam
        let connectTimeout = max(1, sdkConnectTimeoutSeconds)
        let relaunchAttempts = max(0, sdkRelaunchMaxAttempts)
        let resolvedEffort = Self.isNoModelCompatibleBackend(runtimeVariant)
            ? nil
            : (modelSpecifier.explicitEffortLevel ?? effortLevel)
        let resolvedDisallowedTools = Self.normalizedToolList(
            disallowedBuiltInTools
                ?? MCPIntegrationHelper.claudeDisallowedTools(
                    for: toolContext,
                    allowNativeBashTool: allowNativeBashTool
                )
        )
        self.init(
            commandName: resolvedCommand,
            additionalPathHints: additionalPathHints,
            modelString: resolvedModel,
            runtimeVariant: runtimeVariant,
            enableDebugLogging: enableDebugLogging,
            sdkConnectTimeoutSeconds: connectTimeout,
            sdkRelaunchMaxAttempts: relaunchAttempts,
            permissionMode: permissionMode,
            allowNativeBashTool: allowNativeBashTool,
            toolContext: toolContext,
            disallowedBuiltInTools: resolvedDisallowedTools,
            mcpStrictMode: mcpStrictMode,
            toolSearchEnabled: toolSearchEnabled,
            effortLevel: resolvedEffort
        )
    }

    // MARK: - Helpers

    private static func isNoModelCompatibleBackend(_ runtimeVariant: ClaudeCodeRuntimeVariant) -> Bool {
        guard let backendID = runtimeVariant.compatibleBackendID else { return false }
        let config = ClaudeCodeCompatibleBackendStore.shared.config(for: backendID)
        if case .noModel = config.modelBehavior {
            return true
        }
        return false
    }

    private static func sanitizePermissionMode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode : trimmed
    }

    private static func normalizedToolList(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lowered = trimmed.lowercased()
            guard !seen.contains(lowered) else { continue }
            seen.insert(lowered)
            result.append(trimmed)
        }
        return result
    }
}
