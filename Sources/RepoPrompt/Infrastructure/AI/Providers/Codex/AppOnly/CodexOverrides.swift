import Foundation

enum CodexOverrides {
    private static let forcedDisabledConfig: [String: Bool] = [
        "features.apps": false,
        "features.memories": false,
        "features.goals": false,
        "features.computer_use": false,
        "features.plugins": false,
        // Disable MCP elicitation until RepoPrompt supports the mcpServer/elicitation/request
        // server request and its {action, content, _meta} response contract. Without this,
        // Codex routes MCP tool approvals through elicitation by default (ToolCallMcpElicitation
        // is stable + enabled), which RepoPrompt treats as unsupported and fails the run.
        "features.tool_call_mcp_elicitation": false,
        "features.tool_suggest": false,
        "memories.generate_memories": false,
        "memories.use_memories": false
    ]

    private static let computerUseEnabledConfig: [String: Bool] = [
        "features.computer_use": true,
        "features.plugins": true,
        "features.tool_call_mcp_elicitation": true,
        "features.tool_suggest": true
    ]

    enum ReasoningSummary: String {
        case auto
        case concise
        case detailed
        case none
    }

    struct FeaturePolicy: Equatable {
        var goalsEnabled: Bool
        var computerUseEnabled: Bool

        static let defaultDisabled = FeaturePolicy(goalsEnabled: false, computerUseEnabled: false)
        static let enabledForGoals = FeaturePolicy(goalsEnabled: true, computerUseEnabled: false)
        static let enabledForComputerUse = FeaturePolicy(goalsEnabled: false, computerUseEnabled: true)

        static func resolved(goalsEnabled: Bool, computerUseEnabled: Bool) -> FeaturePolicy {
            FeaturePolicy(goalsEnabled: goalsEnabled, computerUseEnabled: computerUseEnabled)
        }
    }

    struct ToolPolicy {
        var toolOutputTokenLimit: Int
        var shellToolEnabled: Bool?
        var webSearchRequestEnabled: Bool?
        var multiAgentEnabled: Bool?
        /// Keep reasoning summaries enabled for newer Codex models that now default them off.
        var modelReasoningSummary: ReasoningSummary? = .auto
    }

    enum MCPPolicy {
        case disableAll(exceptBroken: Set<String>)
        case enableOnlyRepoPrompt(repoPromptNormalizedName: String, exceptBroken: Set<String>)
        case enableSelected(
            enabledNormalizedNames: Set<String>,
            repoPromptNormalizedName: String,
            exceptBroken: Set<String>
        )
    }

    static func cliConfigArgs(
        toolPolicy: ToolPolicy,
        featurePolicy: FeaturePolicy = .defaultDisabled
    ) -> [String] {
        var args: [String] = [
            "-c", "tool_output_token_limit=\(toolPolicy.toolOutputTokenLimit)"
        ]
        if let shellToolEnabled = toolPolicy.shellToolEnabled {
            args.append(contentsOf: ["-c", "features.shell_tool=\(shellToolEnabled)"])
            if shellToolEnabled == false {
                args.append(contentsOf: ["-c", "features.unified_exec=false"])
            }
        }
        if let webSearchRequestEnabled = toolPolicy.webSearchRequestEnabled {
            args.append(contentsOf: ["-c", "web_search=\(webSearchMode(enabled: webSearchRequestEnabled))"])
        }
        if let multiAgentEnabled = toolPolicy.multiAgentEnabled {
            args.append(contentsOf: ["-c", "features.multi_agent=\(multiAgentEnabled)"])
        }
        if let modelReasoningSummary = toolPolicy.modelReasoningSummary {
            args.append(contentsOf: ["-c", "model_reasoning_summary=\(modelReasoningSummary.rawValue)"])
        }
        appendForcedConfigOverrideArgs(to: &args, featurePolicy: featurePolicy)
        return args
    }

    static func appServerConfigMap(
        toolPolicy: ToolPolicy,
        featurePolicy: FeaturePolicy = .defaultDisabled
    ) -> [String: Any] {
        var overrides: [String: Any] = [
            "tool_output_token_limit": toolPolicy.toolOutputTokenLimit
        ]
        if let shellToolEnabled = toolPolicy.shellToolEnabled {
            overrides["features.shell_tool"] = shellToolEnabled
            if shellToolEnabled == false {
                overrides["features.unified_exec"] = false
            }
        }
        if let webSearchRequestEnabled = toolPolicy.webSearchRequestEnabled {
            overrides["web_search"] = webSearchMode(enabled: webSearchRequestEnabled)
        }
        if let multiAgentEnabled = toolPolicy.multiAgentEnabled {
            overrides["features.multi_agent"] = multiAgentEnabled
        }
        if let modelReasoningSummary = toolPolicy.modelReasoningSummary {
            overrides["model_reasoning_summary"] = modelReasoningSummary.rawValue
        }
        applyForcedConfigOverrides(to: &overrides, featurePolicy: featurePolicy)
        return overrides
    }

    static func cliMCPServerArgs(
        entries: [MCPIntegrationHelper.CodexServerEntry],
        policy: MCPPolicy
    ) -> [String] {
        var args: [String] = []
        for (cliComponent, enabled) in mcpServerOverrideEntries(entries: entries, policy: policy) {
            args.append(contentsOf: ["-c", "mcp_servers.\(cliComponent).enabled=\(enabled)"])
        }
        return args
    }

    static func appServerMCPServerMap(
        entries: [MCPIntegrationHelper.CodexServerEntry],
        policy: MCPPolicy
    ) -> [String: Any] {
        var overrides: [String: Any] = [:]
        for (cliComponent, enabled) in mcpServerOverrideEntries(entries: entries, policy: policy) {
            overrides["mcp_servers.\(cliComponent).enabled"] = enabled
        }
        return overrides
    }

    private static func appendForcedConfigOverrideArgs(
        to args: inout [String],
        featurePolicy: FeaturePolicy
    ) {
        let resolvedConfig = forcedConfig(featurePolicy: featurePolicy)
        for key in resolvedConfig.keys.sorted() {
            guard let enabled = resolvedConfig[key] else { continue }
            args.append(contentsOf: ["-c", "\(key)=\(enabled)"])
        }
    }

    private static func applyForcedConfigOverrides(
        to overrides: inout [String: Any],
        featurePolicy: FeaturePolicy
    ) {
        let resolvedConfig = forcedConfig(featurePolicy: featurePolicy)
        for key in resolvedConfig.keys.sorted() {
            guard let enabled = resolvedConfig[key] else { continue }
            overrides[key] = enabled
        }
    }

    private static func forcedConfig(featurePolicy: FeaturePolicy) -> [String: Bool] {
        var config = forcedDisabledConfig
        if featurePolicy.goalsEnabled {
            config["features.goals"] = true
        }
        guard featurePolicy.computerUseEnabled else {
            return config
        }
        for (key, value) in computerUseEnabledConfig {
            config[key] = value
        }
        return config
    }

    private static func webSearchMode(enabled: Bool) -> String {
        enabled ? "live" : "disabled"
    }

    private static func mcpServerOverrideEntries(
        entries: [MCPIntegrationHelper.CodexServerEntry],
        policy: MCPPolicy
    ) -> [(String, Bool)] {
        var overrides: [(String, Bool)] = []

        switch policy {
        case let .disableAll(exceptBroken):
            for entry in entries {
                if entry.normalizedName.isEmpty {
                    continue
                }
                if exceptBroken.contains(entry.normalizedName) {
                    continue
                }
                overrides.append((entry.cliPathComponent, false))
            }
        case let .enableOnlyRepoPrompt(repoPromptName, exceptBroken):
            var didEnableRepoPrompt = false
            for entry in entries {
                if entry.normalizedName.isEmpty {
                    continue
                }
                if entry.normalizedName == repoPromptName {
                    overrides.append((entry.cliPathComponent, true))
                    didEnableRepoPrompt = true
                } else {
                    if exceptBroken.contains(entry.normalizedName) {
                        continue
                    }
                    overrides.append((entry.cliPathComponent, false))
                }
            }
            if !didEnableRepoPrompt {
                let cliComponent = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: repoPromptName)
                overrides.append((cliComponent, true))
            }
        case let .enableSelected(enabledNames, repoPromptName, exceptBroken):
            let normalizedEnabled = Set(enabledNames)
            let normalizedBroken = Set(exceptBroken)
            let normalizedRepoPrompt = repoPromptName
            var didEnableRepoPrompt = false

            for entry in entries {
                if entry.normalizedName.isEmpty {
                    continue
                }

                let normalizedName = entry.normalizedName
                let isRepoPrompt = normalizedName == normalizedRepoPrompt
                let shouldEnable = isRepoPrompt || normalizedEnabled.contains(normalizedName)
                if shouldEnable {
                    if isRepoPrompt {
                        didEnableRepoPrompt = true
                    }
                    overrides.append((entry.cliPathComponent, true))
                    continue
                }

                if normalizedBroken.contains(normalizedName) {
                    continue
                }
                overrides.append((entry.cliPathComponent, false))
            }

            if !didEnableRepoPrompt {
                let cliComponent = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: repoPromptName)
                overrides.append((cliComponent, true))
            }
        }

        return overrides
    }
}
