import Foundation

/// Structured tags for model discovery. Helps callers programmatically
/// choose the right model for their task without parsing descriptions.
enum AgentModelDiscoveryTag: String, CaseIterable {
    case fast
    case exploration
    case balanced
    case engineering
    case complex
    case pair
    case extendedContext = "extended_context"

    /// Fixed display order for deterministic output.
    static let displayOrder: [AgentModelDiscoveryTag] = allCases

    /// Dynamic models are intentionally untagged. Tags are reserved for the
    /// small set of explicit recommendation targets below.
    static func infer(from _: String) -> [AgentModelDiscoveryTag] {
        []
    }
}

enum AgentModel: String, CaseIterable, Codable {
    /// GPT-5.1 Codex Mini (separate fast model)
    case codexMini = "gpt-5.1-codex-mini"

    // GPT-5.6 models exposed through Codex CLI
    case gpt56SolLow = "gpt-5.6-sol-low"
    case gpt56SolMedium = "gpt-5.6-sol-medium"
    case gpt56SolHigh = "gpt-5.6-sol-high"
    case gpt56SolXHigh = "gpt-5.6-sol-xhigh"
    case gpt56SolMax = "gpt-5.6-sol-max"
    case gpt56SolUltra = "gpt-5.6-sol-ultra"
    case gpt56TerraLow = "gpt-5.6-terra-low"
    case gpt56TerraMedium = "gpt-5.6-terra-medium"
    case gpt56TerraHigh = "gpt-5.6-terra-high"
    case gpt56TerraXHigh = "gpt-5.6-terra-xhigh"
    case gpt56TerraMax = "gpt-5.6-terra-max"
    case gpt56TerraUltra = "gpt-5.6-terra-ultra"
    case gpt56LunaLow = "gpt-5.6-luna-low"
    case gpt56LunaMedium = "gpt-5.6-luna-medium"
    case gpt56LunaHigh = "gpt-5.6-luna-high"
    case gpt56LunaXHigh = "gpt-5.6-luna-xhigh"
    case gpt56LunaMax = "gpt-5.6-luna-max"

    // Legacy GPT-5.5 models retained for decoding/resolution compatibility.
    case gpt55CodexLow = "gpt-5.5-low"
    case gpt55CodexMedium = "gpt-5.5-medium"
    case gpt55CodexHigh = "gpt-5.5-high"
    case gpt55CodexXHigh = "gpt-5.5-xhigh"

    // GPT-5.3 Codex models - uses gpt-5.3-codex (agentic coding optimized)
    case codexLow = "gpt-5.3-codex-low"
    case codexMedium = "gpt-5.3-codex-medium"
    case codexHigh = "gpt-5.3-codex-high"
    case codexXHigh = "gpt-5.3-codex-xhigh"

    // GPT-5.2 models (base model with reasoning levels)
    case gpt5Low = "gpt-5.2-low"
    case gpt5Medium = "gpt-5.2-medium"
    case gpt5High = "gpt-5.2-high"
    case gpt5XHigh = "gpt-5.2-xhigh"

    // GPT-5.4 models
    case gpt54Low = "gpt-5.4-low"
    case gpt54Medium = "gpt-5.4-medium"
    case gpt54High = "gpt-5.4-high"
    case gpt54XHigh = "gpt-5.4-xhigh"

    // GPT-5.4 Mini models (separate fast model family)
    case gpt54MiniLow = "gpt-5.4-mini-low"
    case gpt54MiniMedium = "gpt-5.4-mini-medium"
    case gpt54MiniHigh = "gpt-5.4-mini-high"

    // Claude Code models
    case claudeSonnet = "sonnet"
    case claudeOpus = "opus"
    case claudeHaiku = "haiku"
    case claudeOpus1m = "opus[1m]"

    // Claude Code full model IDs (static known versions; no dynamic probing)
    case claudeFable5 = "claude-fable-5"
    case claudeSonnet5 = "claude-sonnet-5"
    case claudeSonnet46 = "claude-sonnet-4-6"
    case claudeSonnet45 = "claude-sonnet-4-5"
    case claudeOpus47 = "claude-opus-4-7"
    case claudeOpus46 = "claude-opus-4-6"
    case claudeOpus45 = "claude-opus-4-5"
    case claudeHaiku45 = "claude-haiku-4-5"

    // Claude Code GLM aliases
    case glm45Air = "glm-4.5-air"
    case glm47 = "glm-4.7"
    case glm52 = "glm-5.2"
    case glm52_1m = "glm-5.2[1m]"
    case glm5Turbo = "glm-5-turbo"
    case glm5 = "glm-5.1"

    // Claude-compatible backend no-model display entries
    case kimiCode = "kimi-code"
    case customClaudeCompatible = "custom-claude-compatible"

    // Cursor models
    case cursorAuto = "auto"
    case cursorComposer2 = "composer-2"

    /// Default (no model specified)
    case defaultModel = "default"

    var displayName: String {
        switch self {
        case .codexMini: "GPT-5.1 Codex Mini"
        case .gpt56SolLow: "GPT-5.6 Sol Low"
        case .gpt56SolMedium: "GPT-5.6 Sol Medium"
        case .gpt56SolHigh: "GPT-5.6 Sol High"
        case .gpt56SolXHigh: "GPT-5.6 Sol XHigh"
        case .gpt56SolMax: "GPT-5.6 Sol Max"
        case .gpt56SolUltra: "GPT-5.6 Sol Ultra"
        case .gpt56TerraLow: "GPT-5.6 Terra Low"
        case .gpt56TerraMedium: "GPT-5.6 Terra Medium"
        case .gpt56TerraHigh: "GPT-5.6 Terra High"
        case .gpt56TerraXHigh: "GPT-5.6 Terra XHigh"
        case .gpt56TerraMax: "GPT-5.6 Terra Max"
        case .gpt56TerraUltra: "GPT-5.6 Terra Ultra"
        case .gpt56LunaLow: "GPT-5.6 Luna Low"
        case .gpt56LunaMedium: "GPT-5.6 Luna Medium"
        case .gpt56LunaHigh: "GPT-5.6 Luna High"
        case .gpt56LunaXHigh: "GPT-5.6 Luna XHigh"
        case .gpt56LunaMax: "GPT-5.6 Luna Max"
        case .gpt55CodexLow: "GPT-5.5 Low"
        case .gpt55CodexMedium: "GPT-5.5 Medium"
        case .gpt55CodexHigh: "GPT-5.5 High"
        case .gpt55CodexXHigh: "GPT-5.5 XHigh"
        case .codexLow: "GPT-5.3 Codex Low"
        case .codexMedium: "GPT-5.3 Codex Medium"
        case .codexHigh: "GPT-5.3 Codex High"
        case .codexXHigh: "GPT-5.3 Codex XHigh"
        case .gpt5Low: "GPT-5.2 Low"
        case .gpt5Medium: "GPT-5.2 Medium"
        case .gpt5High: "GPT-5.2 High"
        case .gpt5XHigh: "GPT-5.2 XHigh"
        case .gpt54Low: "GPT-5.4 Low"
        case .gpt54Medium: "GPT-5.4 Medium"
        case .gpt54High: "GPT-5.4 High"
        case .gpt54XHigh: "GPT-5.4 XHigh"
        case .gpt54MiniLow: "GPT-5.4 Mini Low"
        case .gpt54MiniMedium: "GPT-5.4 Mini Medium"
        case .gpt54MiniHigh: "GPT-5.4 Mini High"
        case .claudeSonnet: "Sonnet Latest"
        case .claudeOpus: "Opus Latest"
        case .claudeHaiku: "Haiku Latest"
        case .claudeOpus1m: "Opus Latest (1M)"
        case .claudeFable5: "Fable 5"
        case .claudeSonnet5: "Sonnet 5"
        case .claudeSonnet46: "Sonnet 4.6"
        case .claudeSonnet45: "Sonnet 4.5"
        case .claudeOpus47: "Opus 4.7"
        case .claudeOpus46: "Opus 4.6"
        case .claudeOpus45: "Opus 4.5"
        case .claudeHaiku45: "Haiku 4.5"
        case .glm45Air: "GLM 4.5 Air"
        case .glm47: "GLM 4.7"
        case .glm52: "GLM 5.2"
        case .glm52_1m: "GLM 5.2 (1M)"
        case .glm5Turbo: "GLM 5 Turbo"
        case .glm5: "GLM 5.1"
        case .kimiCode: "Kimi Code"
        case .customClaudeCompatible: "CC Custom"
        case .cursorAuto: "Auto"
        case .cursorComposer2: "Composer 2"
        case .defaultModel: "Default"
        }
    }

    var description: String {
        switch self {
        case .codexMini: "Ultra-fast. Good for quick lookups, simple edits, and surface-level exploration."
        case .gpt56SolLow: "Fast GPT-5.6 Sol reasoning through Codex. Recommended for explore, discovery, and lightweight implementation."
        case .gpt56SolMedium: "Balanced GPT-5.6 Sol reasoning through Codex. Good for Engineer defaults when you want more reasoning than Low without jumping to High."
        case .gpt56SolHigh: "Deep GPT-5.6 Sol reasoning through Codex. Recommended for planning, review, and pair-agent work."
        case .gpt56SolXHigh: "Extra-high GPT-5.6 Sol reasoning through Codex. Use selectively for hard agentic tasks."
        case .gpt56SolMax: "Maximum GPT-5.6 Sol reasoning through Codex. Can use substantially more tokens; choose intentionally for exceptional tasks."
        case .gpt56SolUltra: "Ultra GPT-5.6 Sol reasoning through Codex. Can use substantially more tokens; choose intentionally for exceptional tasks."
        case .gpt56TerraLow: "Fast GPT-5.6 Terra reasoning through Codex. Balances intelligence and cost for lighter agentic work."
        case .gpt56TerraMedium: "Balanced GPT-5.6 Terra reasoning through Codex. Strong default when cost matters."
        case .gpt56TerraHigh: "Deep GPT-5.6 Terra reasoning through Codex. Good for complex work with cost-conscious tradeoffs."
        case .gpt56TerraXHigh: "Extra-high GPT-5.6 Terra reasoning through Codex. Use selectively for hard cost-conscious tasks."
        case .gpt56TerraMax: "Maximum GPT-5.6 Terra reasoning through Codex. Can use substantially more tokens; choose intentionally."
        case .gpt56TerraUltra: "Ultra GPT-5.6 Terra reasoning through Codex. Can use substantially more tokens; choose intentionally."
        case .gpt56LunaLow: "Fast GPT-5.6 Luna reasoning through Codex. Cost-sensitive option for simple exploration."
        case .gpt56LunaMedium: "Balanced GPT-5.6 Luna reasoning through Codex. Cost-sensitive option for routine work."
        case .gpt56LunaHigh: "Deep GPT-5.6 Luna reasoning through Codex. Cost-sensitive option when more reasoning is needed."
        case .gpt56LunaXHigh: "Extra-high GPT-5.6 Luna reasoning through Codex. Cost-sensitive option for harder tasks."
        case .gpt56LunaMax: "Maximum GPT-5.6 Luna reasoning through Codex. Can use substantially more tokens; choose intentionally."
        case .gpt55CodexLow: "Fast GPT-5.5 reasoning through Codex. Recommended for explore, discovery, and lightweight implementation."
        case .gpt55CodexMedium: "Balanced GPT-5.5 reasoning through Codex. Good for Engineer defaults when you want more reasoning than Low without jumping to High."
        case .gpt55CodexHigh: "Deep GPT-5.5 reasoning through Codex. Recommended for planning, review, and pair-agent work."
        case .gpt55CodexXHigh: "Maximum GPT-5.5 reasoning through Codex. Use selectively for the hardest agentic tasks."
        case .codexLow: "Fast agentic coding. Good for well-scoped, straightforward tasks."
        case .codexMedium: "Balanced agentic coding. Good for general engineering work with clear requirements."
        case .codexHigh: "Deep reasoning for complex coding. Best for multi-file refactors and nuanced engineering."
        case .codexXHigh: "Maximum reasoning. Best for the hardest agentic tasks requiring deep analysis."
        case .gpt5Low: "Quick responses. Good for exploration and mapping the territory."
        case .gpt5Medium: "Balanced reasoning. Good for general-purpose tasks."
        case .gpt5High: "Deep reasoning. Good for complex multi-step problems."
        case .gpt5XHigh: "Maximum reasoning. Best for the most complex tasks."
        case .gpt54Low: "Quick GPT-5.4 responses. Good for exploration and light tasks."
        case .gpt54Medium: "Balanced GPT-5.4. Good for general work with solid reasoning."
        case .gpt54High: "Deep GPT-5.4 reasoning. Good for complex engineering and analysis."
        case .gpt54XHigh: "Maximum GPT-5.4 reasoning. Best for the hardest multi-step tasks."
        case .gpt54MiniLow: "Fast GPT-5.4 Mini. Good for quick exploration and lookups."
        case .gpt54MiniMedium: "GPT-5.4 Mini with balanced reasoning. Best exploration sub-agent for context gathering."
        case .gpt54MiniHigh: "GPT-5.4 Mini with deep reasoning. Good for complex exploration and analysis."
        case .claudeSonnet: "Balanced speed and capability. Good for general coding, analysis, and everyday work."
        case .claudeOpus: "Most capable Opus-tier model. Best for open-ended tasks, architecture, and complex reasoning."
        case .claudeHaiku: "Fast and lightweight. Good for exploration, quick edits, and mapping codebases."
        case .claudeOpus1m: "Claude Opus with 1M token context. Best for large codebases and tasks requiring extensive context."
        case .claudeFable5: "Claude Fable 5. Anthropic's most capable widely released model for demanding reasoning and long-horizon agentic work."
        case .claudeSonnet5: "Pinned Claude Sonnet 5. Balanced speed and capability with 1M context for everyday engineering."
        case .claudeSonnet46: "Pinned Claude Sonnet 4.6. Balanced speed and capability for everyday engineering."
        case .claudeSonnet45: "Pinned Claude Sonnet 4.5. Balanced speed and capability for everyday engineering."
        case .claudeOpus47: "Pinned Claude Opus 4.7. Opus-tier capability for complex reasoning and architecture."
        case .claudeOpus46: "Pinned Claude Opus 4.6. Opus-tier capability for complex reasoning and architecture."
        case .claudeOpus45: "Pinned Claude Opus 4.5. Opus-tier capability for complex reasoning and architecture."
        case .claudeHaiku45: "Pinned Claude Haiku 4.5. Fast and lightweight for quick edits and exploration."
        case .glm45Air: "GLM 4.5 Air via Z.ai. Fast and lightweight, good for exploration."
        case .glm47: "GLM tier via Z.ai. Fast and lightweight, good for exploration."
        case .glm52: "GLM 5.2 tier via Z.ai. Latest GLM tier, good for complex tasks."
        case .glm52_1m: "GLM 5.2 via Z.ai with 1M context. Best for large codebases and tasks requiring extensive context."
        case .glm5Turbo: "GLM tier via Z.ai. Balanced, good for general work."
        case .glm5: "GLM 5.1 tier via Z.ai. Strongest legacy GLM tier, good for complex tasks."
        case .kimiCode: "Kimi Code backend. RepoPrompt does not pass a model flag."
        case .customClaudeCompatible: "Custom Claude-compatible backend. RepoPrompt does not pass a model flag when configured for no-model behavior."
        case .cursorAuto: "Let Cursor choose the best model automatically. Built-in fallback for Cursor ACP runs when dynamic model metadata is unavailable."
        case .cursorComposer2: "Cursor's Composer 2 model. Available when Cursor exposes it through ACP model metadata."
        case .defaultModel: "Use the agent's default model. Good starting point when unsure."
        }
    }

    /// Get available models for a specific agent type
    static func modelsForAgent(_ agentKind: AgentProviderKind) -> [AgentModel] {
        let models: [AgentModel] = switch agentKind {
        case .codexExec:
            [
                .defaultModel,
                .gpt56SolLow,
                .gpt56SolMedium,
                .gpt56SolHigh,
                .gpt56SolXHigh,
                .gpt56SolMax,
                .gpt56SolUltra,
                .gpt56TerraLow,
                .gpt56TerraMedium,
                .gpt56TerraHigh,
                .gpt56TerraXHigh,
                .gpt56TerraMax,
                .gpt56TerraUltra,
                .gpt56LunaLow,
                .gpt56LunaMedium,
                .gpt56LunaHigh,
                .gpt56LunaXHigh,
                .gpt56LunaMax,
                .codexMini,
                .codexLow,
                .codexMedium,
                .codexHigh,
                .codexXHigh,
                .gpt54MiniLow,
                .gpt54MiniMedium,
                .gpt54MiniHigh,
                .gpt54Low,
                .gpt54Medium,
                .gpt54High,
                .gpt54XHigh,
                .gpt5Low,
                .gpt5Medium,
                .gpt5High,
                .gpt5XHigh
            ]
        case .claudeCode:
            // Family priority matches the Claude Code picker catalog:
            // Fable → Opus[1M] → Opus → Sonnet → Haiku. Within each family,
            // latest aliases come first, then pinned full IDs by descending version.
            [
                .defaultModel,
                .claudeFable5,
                .claudeOpus1m,
                .claudeOpus, .claudeOpus47, .claudeOpus46, .claudeOpus45,
                .claudeSonnet, .claudeSonnet5, .claudeSonnet46, .claudeSonnet45,
                .claudeHaiku, .claudeHaiku45
            ]
        case .openCode:
            [.defaultModel]
        case .cursor:
            [.cursorAuto, .cursorComposer2]
        case .claudeCodeGLM:
            [.claudeHaiku, .claudeSonnet, .claudeOpus]
        case .kimiCode:
            [.kimiCode]
        case .customClaudeCompatible:
            [.customClaudeCompatible]
        }
        return models.filter(\.isAvailable)
    }

    /// Check if this model is valid for the given agent
    func isValidFor(_ agentKind: AgentProviderKind) -> Bool {
        AgentModel.modelsForAgent(agentKind).contains(self)
    }

    /// Resolve a stored model raw string to the closest known model enum for UI bindings.
    /// Codex dynamic model IDs can arrive as base-only IDs (for example `gpt-5.3-codex`)
    /// which are valid to run but don't map directly to enum cases.
    static func resolvedModel(forRaw rawModel: String?, agentKind: AgentProviderKind) -> AgentModel? {
        guard let rawModel else { return nil }
        let normalized = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if agentKind.usesClaudeTooling {
            let specifier = ClaudeModelSpecifier(raw: normalized)
            guard let baseModel = specifier.baseModel else {
                return agentKind == .claudeCode ? .defaultModel : nil
            }
            if agentKind == .kimiCode,
               baseModel.caseInsensitiveCompare(AgentModel.kimiCode.rawValue) == .orderedSame
            {
                return .kimiCode
            }
            if agentKind == .customClaudeCompatible {
                if baseModel.caseInsensitiveCompare(AgentModel.customClaudeCompatible.rawValue) == .orderedSame {
                    return .customClaudeCompatible
                }
                if let slotModel = AgentModel(rawValue: baseModel), [.claudeHaiku, .claudeSonnet, .claudeOpus].contains(slotModel) {
                    return slotModel
                }
            }
            if agentKind == .claudeCodeGLM,
               let mappedRaw = ClaudeCodeGLMIntegration.normalizedGLMModel(baseModel),
               let mapped = AgentModel(rawValue: mappedRaw),
               mapped.isValidFor(agentKind)
            {
                return mapped
            }
            if let exact = AgentModel(rawValue: baseModel), exact.isValidFor(agentKind) {
                return exact
            }
            return nil
        }

        if let exact = AgentModel(rawValue: normalized), exact.isValidFor(agentKind) {
            return exact
        }

        guard agentKind == .codexExec else { return nil }
        let specifier = CodexModelSpecifier(raw: normalized)
        let base = (specifier.baseModel ?? normalized).lowercased()
        let effort = specifier.reasoningEffort
        // Unsupported Max/Ultra-looking raw values intentionally remain unresolved instead of
        // falling through to generic GPT-5/Codex Medium fallbacks. This preserves legitimate
        // base IDs such as `gpt-5.1-codex-max` and prevents unknown `*-ultra` selections from
        // silently changing to a runnable lower-effort model.
        if effort == nil,
           let trailingToken = normalized.split(separator: "-").last,
           let trailingEffort = CodexReasoningEffort.parse(String(trailingToken)),
           [.max, .ultra].contains(trailingEffort)
        {
            return nil
        }

        func codex53(for effort: CodexReasoningEffort?) -> AgentModel {
            switch effort {
            case .some(.low):
                .codexLow
            case .some(.high):
                .codexHigh
            case .some(.xhigh):
                .codexXHigh
            case .some(.none), .some(.minimal), .some(.medium):
                .codexMedium
            case nil, .some:
                .codexMedium
            }
        }

        func gpt52(for effort: CodexReasoningEffort?) -> AgentModel {
            switch effort {
            case .some(.low):
                .gpt5Low
            case .some(.high):
                .gpt5High
            case .some(.xhigh):
                .gpt5XHigh
            case .some(.none), .some(.minimal), .some(.medium):
                .gpt5Medium
            case nil, .some:
                .gpt5Medium
            }
        }

        func gpt56Sol(for effort: CodexReasoningEffort?) -> AgentModel {
            switch effort {
            case .some(.low):
                .gpt56SolLow
            case .some(.high):
                .gpt56SolHigh
            case .some(.xhigh):
                .gpt56SolXHigh
            case .some(.max):
                .gpt56SolMax
            case .some(.ultra):
                .gpt56SolUltra
            case .some(.none), .some(.minimal), .some(.medium):
                .gpt56SolMedium
            case nil, .some:
                .gpt56SolMedium
            }
        }

        func gpt56Terra(for effort: CodexReasoningEffort?) -> AgentModel {
            switch effort {
            case .some(.low):
                .gpt56TerraLow
            case .some(.high):
                .gpt56TerraHigh
            case .some(.xhigh):
                .gpt56TerraXHigh
            case .some(.max):
                .gpt56TerraMax
            case .some(.ultra):
                .gpt56TerraUltra
            case .some(.none), .some(.minimal), .some(.medium):
                .gpt56TerraMedium
            case nil, .some:
                .gpt56TerraMedium
            }
        }

        func gpt56Luna(for effort: CodexReasoningEffort?) -> AgentModel {
            switch effort {
            case .some(.low):
                .gpt56LunaLow
            case .some(.high):
                .gpt56LunaHigh
            case .some(.xhigh):
                .gpt56LunaXHigh
            case .some(.max):
                .gpt56LunaMax
            case .some(.none), .some(.minimal), .some(.medium):
                .gpt56LunaMedium
            case nil, .some:
                .gpt56LunaMedium
            }
        }

        func gpt54(for effort: CodexReasoningEffort?) -> AgentModel {
            switch effort {
            case .some(.low):
                .gpt54Low
            case .some(.high):
                .gpt54High
            case .some(.xhigh):
                .gpt54XHigh
            case .some(.none), .some(.minimal), .some(.medium):
                .gpt54Medium
            case nil, .some:
                .gpt54Medium
            }
        }

        func gpt54Mini(for effort: CodexReasoningEffort?) -> AgentModel {
            switch effort {
            case .some(.low):
                .gpt54MiniLow
            case .some(.high):
                .gpt54MiniHigh
            case .some(.none), .some(.minimal), .some(.medium):
                .gpt54MiniMedium
            case nil, .some:
                .gpt54MiniMedium
            }
        }

        if base.contains("gpt-5.1-codex-mini") || base.contains("codex-mini") {
            return .codexMini
        }
        if base.contains("gpt-5.3-codex") {
            return codex53(for: effort)
        }
        if base == "gpt-5.6-terra" {
            return gpt56Terra(for: effort)
        }
        if base == "gpt-5.6-luna" {
            return gpt56Luna(for: effort)
        }
        if base == "gpt-5.6" || base == "gpt-5.6-sol" || base == "gpt-5.5" {
            return gpt56Sol(for: effort)
        }
        // Check mini before regular gpt-5.4 to avoid false matches
        if base.contains("gpt-5.4-mini") {
            return gpt54Mini(for: effort)
        }
        if base.contains("gpt-5.4") {
            return gpt54(for: effort)
        }
        if base.contains("gpt-5.2") {
            return gpt52(for: effort)
        }
        if base.contains("codex") {
            return codex53(for: effort)
        }
        if base.contains("gpt-5") {
            return gpt56Sol(for: effort)
        }

        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decodedRawValue = try container.decode(String.self)
        if let model = AgentModel(rawValue: decodedRawValue) {
            self = model
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid AgentModel raw value: \(decodedRawValue)"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Whether this model uses the 1M extended context window.
    /// Derived from `contextWindowTokens` so the two facts cannot drift.
    var isExtendedContext: Bool {
        (contextWindowTokens ?? 0) >= 1_000_000
    }

    /// Returns the release date for models with staged rollouts
    var availableFrom: Date? {
        nil
    }

    /// Check if a model is currently available based on its release date
    var isAvailable: Bool {
        if let releaseDate = availableFrom {
            return Date() >= releaseDate
        }
        return true
    }

    /// Structured tags indicating when this model is one of the explicit
    /// recommendation targets. Other models are intentionally untagged.
    var discoveryTags: [AgentModelDiscoveryTag] {
        switch self {
        case .gpt56SolLow:
            [.fast, .exploration, .engineering]
        case .gpt56SolHigh:
            [.complex, .engineering, .pair]
        case .claudeFable5:
            [.complex, .engineering, .pair, .extendedContext]
        case .claudeSonnet5:
            [.balanced, .engineering, .extendedContext]
        case .claudeOpus:
            [.complex, .engineering, .pair]
        default:
            []
        }
    }

    /// Known context window size in tokens, when verified.
    /// Returns `nil` for models where the context window is unknown or unverified.
    var contextWindowTokens: Int? {
        switch self {
        case .claudeFable5, .claudeSonnet5, .claudeOpus1m, .glm52_1m:
            1_000_000
        case .claudeSonnet, .claudeOpus, .claudeHaiku,
             .claudeSonnet46, .claudeSonnet45,
             .claudeOpus47, .claudeOpus46, .claudeOpus45,
             .claudeHaiku45:
            200_000
        default:
            nil
        }
    }
}
