import Foundation
import SwiftAnthropic
import SwiftOpenAI

enum ModelPickerStringOrdering {
    static func compare(
        _ lhs: String,
        _ rhs: String,
        caseInsensitiveASCII: Bool
    ) -> ComparisonResult {
        let foldedComparison = compareScalars(
            lhs.unicodeScalars.map { foldedScalarValue($0.value, caseInsensitiveASCII: caseInsensitiveASCII) },
            rhs.unicodeScalars.map { foldedScalarValue($0.value, caseInsensitiveASCII: caseInsensitiveASCII) }
        )
        if foldedComparison != .orderedSame || !caseInsensitiveASCII {
            return foldedComparison
        }

        return compareScalars(
            lhs.unicodeScalars.map(\.value),
            rhs.unicodeScalars.map(\.value)
        )
    }

    static func precedes(
        _ lhs: String,
        _ rhs: String,
        caseInsensitiveASCII: Bool = true
    ) -> Bool {
        compare(lhs, rhs, caseInsensitiveASCII: caseInsensitiveASCII) == .orderedAscending
    }

    private static func foldedScalarValue(
        _ value: UInt32,
        caseInsensitiveASCII: Bool
    ) -> UInt32 {
        guard caseInsensitiveASCII, value >= 65, value <= 90 else { return value }
        return value + 32
    }

    private static func compareScalars(
        _ lhs: [UInt32],
        _ rhs: [UInt32]
    ) -> ComparisonResult {
        let count = min(lhs.count, rhs.count)
        for index in 0 ..< count {
            if lhs[index] == rhs[index] { continue }
            return lhs[index] < rhs[index] ? .orderedAscending : .orderedDescending
        }
        if lhs.count == rhs.count { return .orderedSame }
        return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
    }
}

public enum AIModel: Equatable, Hashable {
    /// OpenAI Models
    case gpt41

    /// Service tier variant wrapper (for OpenAI Responses API models)
    indirect case openAIServiceTierVariant(base: AIModel, tier: String)

    case gpt5
    case gpt5Low
    case gpt5High
    case gpt5XHigh
    case gpt54
    case gpt54Low
    case gpt54High
    case gpt54XHigh
    case gpt54Mini
    case gpt54MiniLow
    case gpt54MiniHigh
    case gpt54MiniXHigh
    case gpt54Nano

    case gpt5CodexLow
    case gpt5CodexMed
    case gpt5CodexHigh
    case gpt5CodexXHigh

    // Codex CLI Provider Models
    case codexCliGpt56SolLow
    case codexCliGpt56SolMedium
    case codexCliGpt56SolHigh
    case codexCliGpt56SolXHigh
    case codexCliGpt56SolMax
    case codexCliGpt56SolUltra
    case codexCliGpt56TerraLow
    case codexCliGpt56TerraMedium
    case codexCliGpt56TerraHigh
    case codexCliGpt56TerraXHigh
    case codexCliGpt56TerraMax
    case codexCliGpt56TerraUltra
    case codexCliGpt56LunaLow
    case codexCliGpt56LunaMedium
    case codexCliGpt56LunaHigh
    case codexCliGpt56LunaXHigh
    case codexCliGpt56LunaMax
    case codexCliGpt5Low
    case codexCliGpt5Medium
    case codexCliGpt5High
    case codexCliGpt5XHigh
    case codexCliGpt54Low
    case codexCliGpt54Medium
    case codexCliGpt54High
    case codexCliGpt54XHigh
    case codexCliGpt5Mini

    case codexCliGpt5CodexLow
    case codexCliGpt5CodexMedium
    case codexCliGpt5CodexHigh
    case codexCliGpt5CodexXHigh
    case codexCliGpt5CodexMini

    case gpt4o
    case o3
    case o1Preview
    case o1Mini
    case gpt5Pro
    case gpt5ProXHigh
    case gpt54Pro
    case gpt54ProXHigh

    // --- NEW o3 variants ---
    case o3Low // o3-low   – low reasoning effort
    case o3High // o3-high  – high reasoning effort

    // Anthropic Models
    case claude45Haiku
    case claude4Sonnet
    case claude4SonnetThinking
    case claude4SonnetThinkingMax
    // Add Claude Opus 4.0 and its thinking mode
    case claude4Opus
    case claude4OpusThinking

    // Gemini Models
    case geminiFlashLatest
    case gemini2flashlite
    case geminiProLatest
    case geminiFlash2
    case geminiFlash25
    case geminiFlash25LitePreview
    case geminiFlashThinking
    case geminiPro25
    case gemini3p1ProPreview
    case gemini3FlashPreview

    // Deepseek Models
    case deepseekChat
    case deepseekReasoner

    /// Ollama
    case ollama

    // OpenRouter Models
    case openrouterDeepseekChat
    case openrouterGpt5
    case openrouterGeminiFlash
    case openrouterGeminiPro
    case openrouterClaude4Sonnet
    case openrouterClaude4Opus

    case openrouterGeminiPro25
    case openrouterCustom(name: String)

    // Per-provider user-defined models
    case openaiCustom(name: String)
    case openaiCustomResponses(name: String)
    case openaiCustomReasoning(name: String, effort: CodexReasoningEffort)
    case anthropicCustom(name: String)
    case geminiCustom(name: String)
    case deepseekCustom(name: String)
    case fireworksCustom(name: String)
    case azureCustom(name: String)
    case grokCustom(name: String) // <-- New custom model case for Grok
    case groqCustom(name: String) // <-- New custom model case for Groq
    case zaiCustom(name: String)
    case codexCustom(name: String)
    case openCodeCustom(name: String)
    case cursorCustom(name: String)

    // Custom Provider Models
    case customProvider(name: String, provider: String, model: String)
    case customProviderUser(name: String)

    // **New Fireworks Models**
    case fireworksDeepseekV3p1Terminus
    case fireworksGLM46
    case fireworksKimiK2Instruct0905
    case fireworksGptOss120b
    case fireworksQwen3235bA22bThinking2507
    case fireworksQwen3Coder480bA35bInstruct
    case fireworksQwen3235bA22bInstruct2507

    // **New Grok Models**
    case grok40709
    case grokCodeFast1
    case grok4FastReasoning
    case grok4FastNonReasoning

    /// **New Groq Models**
    case groqKimi

    // Z.AI Models
    case zaiGLM52
    case zaiGLM5
    case zaiGLM5_0
    case zaiGLM5Turbo
    case zaiGLM47
    case zaiGLM47Flash
    case zaiGLM46
    case zaiGLM45
    case zaiGLM45Air
    case zaiGLM45Flash

    // Claude Code Models
    case claudeCode
    case claudeCodeSonnet
    case claudeCodeHaiku
    case claudeCodeOpus
    case claudeCodeModel(specifier: String)

    private enum ProviderIndex {
        static let openAI = 0
        static let anthropic = 1
        static let gemini = 2
        static let openRouter = 3
        static let deepseek = 4
        static let fireworks = 5 // <-- New index for Fireworks
        static let grok = 6 // <-- New index for Grok
        static let groq = 7 // <-- New index for Groq
        static let claudeCode = 8 // <-- New index for Claude Code
        static let zAI = 9
        static let azure = 10
        static let codex = 11
        static let openCode = 12
        static let cursor = 13
        static let special = -1
    }

    private struct ModelInfo {
        let model: AIModel
        let rawValue: String
        let actualName: String? // Used for providers that may have clashing names
        let displayName: String
        let provider: Int
        var availableFrom: Date? // Optional release date for staged rollouts
    }

    private static let azureVariantPrefix = "__azure_default__"

    private static func codexModelsForPicker() -> [AIModel] {
        CodexAIModelCatalog.modelsForPicker(staticModels: Array(modelGroups[ProviderIndex.codex]))
    }

    private static func azureVariantKey(for name: String) -> String {
        name.hasPrefix(azureVariantPrefix) ? name : "\(azureVariantPrefix)\(name)"
    }

    private static func azureVariantBaseName(from name: String) -> String {
        name.hasPrefix(azureVariantPrefix)
            ? String(name.dropFirst(azureVariantPrefix.count))
            : name
    }

    private static let openAICustomReasoningEfforts: [CodexReasoningEffort] = [.low, .medium, .high, .xhigh]

    static func openAICustomResponsesVariants(for customModelName: String) -> [AIModel] {
        let baseName = customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseName.isEmpty else { return [] }
        return [.openaiCustomResponses(name: baseName)]
            + openAICustomReasoningEfforts.map { .openaiCustomReasoning(name: baseName, effort: $0) }
    }

    private static let baseModelDefinitions: [ModelInfo] = [
        // OpenAI Models
        // Legacy 4.x series - hidden from display
        // ModelInfo(model: .gpt41, rawValue: "gpt-4.1", actualName: nil, displayName: "gpt 4.1", provider: ProviderIndex.openAI),
        // ModelInfo(model: .gpt4o, rawValue: "gpt-4o", actualName: nil, displayName: "gpt 4o", provider: ProviderIndex.openAI),

        ModelInfo(model: .gpt5, rawValue: "gpt-5.2", actualName: nil, displayName: "GPT-5.2 Med", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt5Low, rawValue: "gpt-5.2-low", actualName: nil, displayName: "GPT-5.2 Low", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt5High, rawValue: "gpt-5.2-high", actualName: nil, displayName: "GPT-5.2 High", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt5XHigh, rawValue: "gpt-5.2-xhigh", actualName: nil, displayName: "GPT-5.2 XHigh", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt54, rawValue: "gpt-5.4", actualName: nil, displayName: "GPT-5.4 Med", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt54Low, rawValue: "gpt-5.4-low", actualName: "gpt-5.4", displayName: "GPT-5.4 Low", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt54High, rawValue: "gpt-5.4-high", actualName: "gpt-5.4", displayName: "GPT-5.4 High", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt54XHigh, rawValue: "gpt-5.4-xhigh", actualName: "gpt-5.4", displayName: "GPT-5.4 XHigh", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt54Mini, rawValue: "gpt-5.4-mini", actualName: nil, displayName: "GPT-5.4 Mini", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt54MiniLow, rawValue: "gpt-5.4-mini-low", actualName: "gpt-5.4-mini", displayName: "GPT-5.4 Mini Low", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt54MiniHigh, rawValue: "gpt-5.4-mini-high", actualName: "gpt-5.4-mini", displayName: "GPT-5.4 Mini High", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt54MiniXHigh, rawValue: "gpt-5.4-mini-xhigh", actualName: "gpt-5.4-mini", displayName: "GPT-5.4 Mini XHigh", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt54Nano, rawValue: "gpt-5.4-nano", actualName: nil, displayName: "GPT-5.4 Nano", provider: ProviderIndex.openAI),

        ModelInfo(model: .gpt5CodexLow, rawValue: "gpt-5.1-codex-max-low", actualName: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex Max Low", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt5CodexMed, rawValue: "gpt-5.1-codex-max", actualName: nil, displayName: "GPT-5.1 Codex Max Med", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt5CodexHigh, rawValue: "gpt-5.1-codex-max-high", actualName: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex Max High", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt5CodexXHigh, rawValue: "gpt-5.1-codex-max-xhigh", actualName: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex Max XHigh", provider: ProviderIndex.openAI),

        // O-series models - hidden from display
        // ModelInfo(model: .o3, rawValue: "o3", actualName: nil, displayName: "o3 Med", provider: ProviderIndex.openAI),
        // ModelInfo(model: .o3Low,  rawValue: "o3-low",   actualName: nil, displayName: "o3 low",  provider: ProviderIndex.openAI),
        // ModelInfo(model: .o3High, rawValue: "o3-high",  actualName: nil, displayName: "o3 high", provider: ProviderIndex.openAI),
        // ModelInfo(model: .o1Preview, rawValue: "o1-preview", actualName: nil, displayName: "o1 preview", provider: ProviderIndex.openAI),
        // ModelInfo(model: .o1Mini, rawValue: "o1-mini", actualName: nil, displayName: "o1-mini", provider: ProviderIndex.openAI),
        // ModelInfo(model: .o3pro, rawValue: "o1-pro", actualName: nil, displayName: "o1 pro", provider: ProviderIndex.openAI),

        ModelInfo(model: .gpt5Pro, rawValue: "gpt-5.2-pro", actualName: nil, displayName: "GPT-5.2 Pro", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt5ProXHigh, rawValue: "gpt-5.2-pro-xhigh", actualName: "gpt-5.2-pro", displayName: "GPT-5.2 Pro XHigh", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt54Pro, rawValue: "gpt-5.4-pro", actualName: nil, displayName: "GPT-5.4 Pro", provider: ProviderIndex.openAI),
        ModelInfo(model: .gpt54ProXHigh, rawValue: "gpt-5.4-pro-xhigh", actualName: "gpt-5.4-pro", displayName: "GPT-5.4 Pro XHigh", provider: ProviderIndex.openAI),

        // Codex CLI Provider Models
        ModelInfo(model: .codexCliGpt56SolLow, rawValue: "codex_cli_gpt-5.6-sol-low", actualName: "gpt-5.6-sol", displayName: "CLI·GPT-5.6 Sol Low", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt56SolMedium, rawValue: "codex_cli_gpt-5.6-sol-medium", actualName: "gpt-5.6-sol", displayName: "CLI·GPT-5.6 Sol Medium", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt56SolHigh, rawValue: "codex_cli_gpt-5.6-sol-high", actualName: "gpt-5.6-sol", displayName: "CLI·GPT-5.6 Sol High", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt56SolXHigh, rawValue: "codex_cli_gpt-5.6-sol-xhigh", actualName: "gpt-5.6-sol", displayName: "CLI·GPT-5.6 Sol XHigh", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt56SolMax, rawValue: "codex_cli_gpt-5.6-sol-max", actualName: "gpt-5.6-sol", displayName: "CLI·GPT-5.6 Sol Max", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt56SolUltra, rawValue: "codex_cli_gpt-5.6-sol-ultra", actualName: "gpt-5.6-sol", displayName: "CLI·GPT-5.6 Sol Ultra", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt56TerraLow, rawValue: "codex_cli_gpt-5.6-terra-low", actualName: "gpt-5.6-terra", displayName: "CLI·GPT-5.6 Terra Low", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt56TerraMedium, rawValue: "codex_cli_gpt-5.6-terra-medium", actualName: "gpt-5.6-terra", displayName: "CLI·GPT-5.6 Terra Medium", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt56TerraHigh, rawValue: "codex_cli_gpt-5.6-terra-high", actualName: "gpt-5.6-terra", displayName: "CLI·GPT-5.6 Terra High", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt56TerraXHigh, rawValue: "codex_cli_gpt-5.6-terra-xhigh", actualName: "gpt-5.6-terra", displayName: "CLI·GPT-5.6 Terra XHigh", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt56TerraMax, rawValue: "codex_cli_gpt-5.6-terra-max", actualName: "gpt-5.6-terra", displayName: "CLI·GPT-5.6 Terra Max", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt56TerraUltra, rawValue: "codex_cli_gpt-5.6-terra-ultra", actualName: "gpt-5.6-terra", displayName: "CLI·GPT-5.6 Terra Ultra", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt56LunaLow, rawValue: "codex_cli_gpt-5.6-luna-low", actualName: "gpt-5.6-luna", displayName: "CLI·GPT-5.6 Luna Low", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt56LunaMedium, rawValue: "codex_cli_gpt-5.6-luna-medium", actualName: "gpt-5.6-luna", displayName: "CLI·GPT-5.6 Luna Medium", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt56LunaHigh, rawValue: "codex_cli_gpt-5.6-luna-high", actualName: "gpt-5.6-luna", displayName: "CLI·GPT-5.6 Luna High", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt56LunaXHigh, rawValue: "codex_cli_gpt-5.6-luna-xhigh", actualName: "gpt-5.6-luna", displayName: "CLI·GPT-5.6 Luna XHigh", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt56LunaMax, rawValue: "codex_cli_gpt-5.6-luna-max", actualName: "gpt-5.6-luna", displayName: "CLI·GPT-5.6 Luna Max", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt5Low, rawValue: "codex_cli_gpt-5.2-low", actualName: "gpt-5.2", displayName: "CLI·GPT-5.2 Low", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt5Medium, rawValue: "codex_cli_gpt-5.2-medium", actualName: "gpt-5.2", displayName: "CLI·GPT-5.2 Medium", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt5High, rawValue: "codex_cli_gpt-5.2-high", actualName: "gpt-5.2", displayName: "CLI·GPT-5.2 High", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt5XHigh, rawValue: "codex_cli_gpt-5.2-xhigh", actualName: "gpt-5.2", displayName: "CLI·GPT-5.2 XHigh", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt54Low, rawValue: "codex_cli_gpt-5.4-low", actualName: "gpt-5.4", displayName: "CLI·GPT-5.4 Low", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt54Medium, rawValue: "codex_cli_gpt-5.4-medium", actualName: "gpt-5.4", displayName: "CLI·GPT-5.4 Medium", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt54High, rawValue: "codex_cli_gpt-5.4-high", actualName: "gpt-5.4", displayName: "CLI·GPT-5.4 High", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt54XHigh, rawValue: "codex_cli_gpt-5.4-xhigh", actualName: "gpt-5.4", displayName: "CLI·GPT-5.4 XHigh", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt5Mini, rawValue: "codex_cli_gpt-5.1-mini", actualName: "gpt-5.1-mini", displayName: "CLI·GPT-5.1 Mini", provider: ProviderIndex.codex),

        ModelInfo(model: .codexCliGpt5CodexLow, rawValue: "codex_cli_gpt-5.3-codex-low", actualName: "gpt-5.3-codex", displayName: "CLI·GPT-5.3 Codex Low", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt5CodexMedium, rawValue: "codex_cli_gpt-5.3-codex-medium", actualName: "gpt-5.3-codex", displayName: "CLI·GPT-5.3 Codex Medium", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt5CodexHigh, rawValue: "codex_cli_gpt-5.3-codex-high", actualName: "gpt-5.3-codex", displayName: "CLI·GPT-5.3 Codex High", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt5CodexXHigh, rawValue: "codex_cli_gpt-5.3-codex-xhigh", actualName: "gpt-5.3-codex", displayName: "CLI·GPT-5.3 Codex XHigh", provider: ProviderIndex.codex),
        ModelInfo(model: .codexCliGpt5CodexMini, rawValue: "codex_cli_gpt-5.1-codex-mini", actualName: "gpt-5.1-codex-mini", displayName: "CLI·GPT-5.1 Codex Mini", provider: ProviderIndex.codex),

        // Anthropic Models
        ModelInfo(model: .claude45Haiku, rawValue: "claude-haiku-4-5", actualName: nil, displayName: "Claude Haiku 4.5", provider: ProviderIndex.anthropic),
        ModelInfo(model: .claude4Sonnet, rawValue: "claude-sonnet-4-5-20250929", actualName: nil, displayName: "Claude Sonnet 4.5", provider: ProviderIndex.anthropic),
        ModelInfo(model: .claude4SonnetThinking, rawValue: "claude-sonnet-4-5-20250929-thinking", actualName: nil, displayName: "Claude Sonnet 4.5 Thinking", provider: ProviderIndex.anthropic),
        ModelInfo(model: .claude4SonnetThinkingMax, rawValue: "claude-sonnet-4-5-20250929-thinking-max", actualName: nil, displayName: "Claude Sonnet 4.5 Thinking Max", provider: ProviderIndex.anthropic),
        // Add Claude Opus 4.0 and its thinking mode
        ModelInfo(model: .claude4Opus, rawValue: "claude-opus-4-6", actualName: nil, displayName: "Claude Opus 4.6", provider: ProviderIndex.anthropic),
        ModelInfo(model: .claude4OpusThinking, rawValue: "claude-opus-4-6-thinking", actualName: nil, displayName: "Claude Opus 4.6 Thinking", provider: ProviderIndex.anthropic),

        // Gemini Models
        ModelInfo(model: .gemini2flashlite, rawValue: "gemini-2.0-flash-lite", actualName: nil, displayName: "Gemini 2.0 Flash Lite", provider: ProviderIndex.gemini),
        ModelInfo(model: .geminiFlash2, rawValue: "gemini-2.0-flash", actualName: nil, displayName: "Gemini 2.0 Flash", provider: ProviderIndex.gemini),
        ModelInfo(model: .geminiFlash25, rawValue: "gemini-2.5-flash", actualName: nil, displayName: "Gemini 2.5 Flash", provider: ProviderIndex.gemini),
        ModelInfo(model: .geminiFlash25LitePreview, rawValue: "gemini-2.5-flash-lite-preview-06-17", actualName: nil, displayName: "Gemini 2.5 Flash Lite Preview 06-17", provider: ProviderIndex.gemini),
        ModelInfo(model: .geminiPro25, rawValue: "gemini-2.5-pro", actualName: nil, displayName: "Gemini 2.5 Pro", provider: ProviderIndex.gemini),
        ModelInfo(model: .gemini3p1ProPreview, rawValue: "gemini-3.1-pro-preview", actualName: nil, displayName: "Gemini 3.1 Pro Preview", provider: ProviderIndex.gemini),
        // Gemini 3.0 Flash Preview
        ModelInfo(model: .gemini3FlashPreview, rawValue: "gemini-3-flash-preview", actualName: nil, displayName: "Gemini 3.0 Flash Preview", provider: ProviderIndex.gemini),

        // Special Models
        ModelInfo(model: .ollama, rawValue: "Ollama", actualName: nil, displayName: "local/", provider: ProviderIndex.special),
        // OpenRouter Models
        ModelInfo(model: .openrouterDeepseekChat, rawValue: "deepseek/deepseek-chat-v3-0324", actualName: nil, displayName: "oRouter/Deepseek V3 (03-24)", provider: ProviderIndex.openRouter),
        ModelInfo(model: .openrouterGpt5, rawValue: "openai/gpt-5.2", actualName: nil, displayName: "oRouter/GPT-5.2 Med", provider: ProviderIndex.openRouter),
        ModelInfo(model: .openrouterGeminiFlash, rawValue: "google/gemini-2.0-flash-001", actualName: nil, displayName: "oRouter/Gemini Flash 2.0", provider: ProviderIndex.openRouter),
        ModelInfo(model: .openrouterGeminiPro25, rawValue: "google/gemini-2.5-flash-preview", actualName: nil, displayName: "oRouter/Gemini 2.5 Flash Preview", provider: ProviderIndex.openRouter),
        ModelInfo(model: .openrouterClaude4Sonnet, rawValue: "anthropic/claude-sonnet-4.5", actualName: nil, displayName: "oRouter/Claude Sonnet 4.5", provider: ProviderIndex.openRouter),
        ModelInfo(model: .openrouterClaude4Opus, rawValue: "anthropic/claude-opus-4.6", actualName: nil, displayName: "oRouter/Claude Opus 4.6", provider: ProviderIndex.openRouter),

        // **New DeepSeek Models**
        ModelInfo(model: .deepseekChat, rawValue: "deepseek-chat", actualName: nil, displayName: "DeepSeek-V3.2-Exp", provider: ProviderIndex.deepseek),
        ModelInfo(model: .deepseekReasoner, rawValue: "deepseek-reasoner", actualName: nil, displayName: "DeepSeek-V3.2-Exp Thinking", provider: ProviderIndex.deepseek),

        // **New Fireworks Models**
        ModelInfo(model: .fireworksDeepseekV3p1Terminus, rawValue: "accounts/fireworks/models/deepseek-v3p1-terminus", actualName: nil, displayName: "DeepSeek V3.1 Terminus", provider: ProviderIndex.fireworks),
        ModelInfo(model: .fireworksGLM46, rawValue: "accounts/fireworks/models/glm-4p6", actualName: nil, displayName: "GLM-4.6", provider: ProviderIndex.fireworks),
        ModelInfo(model: .fireworksKimiK2Instruct0905, rawValue: "accounts/fireworks/models/kimi-k2-instruct-0905", actualName: nil, displayName: "Kimi K2 Instruct 0905", provider: ProviderIndex.fireworks),
        ModelInfo(model: .fireworksGptOss120b, rawValue: "accounts/fireworks/models/gpt-oss-120b", actualName: nil, displayName: "OpenAI gpt-oss-120b", provider: ProviderIndex.fireworks),
        ModelInfo(model: .fireworksQwen3235bA22bThinking2507, rawValue: "accounts/fireworks/models/qwen3-235b-a22b-thinking-2507", actualName: nil, displayName: "Qwen3 235B A22B Thinking 2507", provider: ProviderIndex.fireworks),
        ModelInfo(model: .fireworksQwen3Coder480bA35bInstruct, rawValue: "accounts/fireworks/models/qwen3-coder-480b-a35b-instruct", actualName: nil, displayName: "Qwen3 Coder 480B A35B Instruct", provider: ProviderIndex.fireworks),
        ModelInfo(model: .fireworksQwen3235bA22bInstruct2507, rawValue: "accounts/fireworks/models/qwen3-235b-a22b-instruct-2507", actualName: nil, displayName: "Qwen3 235B A22B Instruct 2507", provider: ProviderIndex.fireworks),

        // **New Grok Models**
        ModelInfo(model: .grok40709, rawValue: "grok-4-0709", actualName: nil, displayName: "Grok 4 (0709)", provider: ProviderIndex.grok),
        ModelInfo(model: .grokCodeFast1, rawValue: "grok-code-fast-1", actualName: nil, displayName: "Grok Code Fast 1", provider: ProviderIndex.grok),
        ModelInfo(model: .grok4FastReasoning, rawValue: "grok-4-fast-reasoning", actualName: nil, displayName: "Grok 4 Fast Reasoning", provider: ProviderIndex.grok),
        ModelInfo(model: .grok4FastNonReasoning, rawValue: "grok-4-fast-non-reasoning", actualName: nil, displayName: "Grok 4 Fast", provider: ProviderIndex.grok),

        // **New Groq Models**
        ModelInfo(model: .groqKimi, rawValue: "moonshotai/kimi-k2-instruct", actualName: nil, displayName: "groq/Kimi K2", provider: ProviderIndex.groq),

        // Z.AI Models
        ModelInfo(model: .zaiGLM52, rawValue: "glm-5.2", actualName: nil, displayName: "Z.AI GLM-5.2", provider: ProviderIndex.zAI),
        ModelInfo(model: .zaiGLM5, rawValue: "glm-5.1", actualName: nil, displayName: "Z.AI GLM-5.1", provider: ProviderIndex.zAI),
        ModelInfo(model: .zaiGLM5_0, rawValue: "glm-5", actualName: nil, displayName: "Z.AI GLM-5", provider: ProviderIndex.zAI),
        ModelInfo(model: .zaiGLM5Turbo, rawValue: "glm-5-turbo", actualName: nil, displayName: "Z.AI GLM-5-Turbo", provider: ProviderIndex.zAI),
        ModelInfo(model: .zaiGLM47, rawValue: "glm-4.7", actualName: nil, displayName: "Z.AI GLM-4.7", provider: ProviderIndex.zAI),
        ModelInfo(model: .zaiGLM47Flash, rawValue: "glm-4.7-flash", actualName: nil, displayName: "Z.AI GLM-4.7 Flash", provider: ProviderIndex.zAI),
        ModelInfo(model: .zaiGLM46, rawValue: "glm-4.6", actualName: nil, displayName: "Z.AI GLM-4.6", provider: ProviderIndex.zAI),
        ModelInfo(model: .zaiGLM45, rawValue: "glm-4.5", actualName: nil, displayName: "Z.AI GLM-4.5", provider: ProviderIndex.zAI),
        ModelInfo(model: .zaiGLM45Air, rawValue: "glm-4.5-air", actualName: nil, displayName: "Z.AI GLM-4.5 Air", provider: ProviderIndex.zAI),
        ModelInfo(model: .zaiGLM45Flash, rawValue: "glm-4.5-flash", actualName: nil, displayName: "Z.AI GLM-4.5 Flash", provider: ProviderIndex.zAI),

        // Claude Code Models
        ModelInfo(model: .claudeCode, rawValue: "claude-code", actualName: nil, displayName: "Claude Code", provider: ProviderIndex.claudeCode),
        ModelInfo(model: .claudeCodeSonnet, rawValue: "sonnet", actualName: nil, displayName: "Claude Code Sonnet Latest", provider: ProviderIndex.claudeCode),
        ModelInfo(model: .claudeCodeHaiku, rawValue: "haiku", actualName: nil, displayName: "Claude Code Haiku Latest", provider: ProviderIndex.claudeCode),
        ModelInfo(model: .claudeCodeOpus, rawValue: "opus", actualName: nil, displayName: "Claude Code Opus Latest", provider: ProviderIndex.claudeCode)
    ]

    private static let modelDefinitions: [ModelInfo] = {
        let azureVariants = baseModelDefinitions
            .filter { $0.provider == ProviderIndex.openAI }
            .map { info -> ModelInfo in
                let displaySource = info.displayName.isEmpty ? info.rawValue : info.displayName
                return ModelInfo(
                    model: .azureCustom(name: azureVariantKey(for: info.rawValue)),
                    rawValue: "azure_custom_\(info.rawValue)",
                    actualName: nil,
                    displayName: "azure/\(displaySource)",
                    provider: ProviderIndex.azure
                )
            }
        return baseModelDefinitions + azureVariants
    }()

    private static let modelData: [AIModel: (rawValue: String, displayName: String)] = {
        let pairs = modelDefinitions.map { info in
            (info.model, (rawValue: info.rawValue, displayName: info.displayName))
        }
        var seen: Set<AIModel> = []
        var duplicates: [AIModel] = []
        for (model, _) in pairs {
            if !seen.insert(model).inserted {
                duplicates.append(model)
            }
        }
        #if DEBUG
            if !duplicates.isEmpty {
                print("AIModel.modelData duplicate keys: \(duplicates)")
            }
        #endif
        return Dictionary(pairs, uniquingKeysWith: { existing, _ in existing })
    }()

    private static let modelGroups: [Set<AIModel>] = {
        var groups: [Set<AIModel>] = Array(repeating: [], count: 14) // Includes CLI provider groups through Cursor
        for info in modelDefinitions where info.provider >= 0 {
            groups[info.provider].insert(info.model)
        }
        return groups
    }()

    // MARK: - Service Tier Variant Helpers

    private static let openAITierPrefix = "openai_tier__"

    static func rawValueWithoutOpenAIServiceTier(_ rawValue: String) -> String {
        let normalizedRawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedRawValue.hasPrefix(openAITierPrefix) else { return rawValue }
        let rest = String(normalizedRawValue.dropFirst(openAITierPrefix.count))
        let parts = rest.components(separatedBy: "__")
        guard parts.count >= 2 else { return rawValue }
        return parts.dropFirst().joined(separator: "__")
    }

    /// Returns the service tier override if this is a tier variant, nil otherwise
    var openAIServiceTierOverride: String? {
        if case let .openAIServiceTierVariant(_, tier) = self { return tier }
        return nil
    }

    /// Returns the base model (unwraps tier variant if applicable)
    var openAIServiceTierBase: AIModel {
        if case let .openAIServiceTierVariant(base, _) = self { return base }
        return self
    }

    /// Returns true if this is a service tier variant
    var isOpenAIServiceTierVariant: Bool {
        if case .openAIServiceTierVariant = self { return true }
        return false
    }

    private var openAITierDisplayName: String {
        switch openAIServiceTierOverride {
        case "default": "Default"
        case "flex": "Flex"
        case "priority": "Priority"
        case "auto": "Auto"
        default: (openAIServiceTierOverride ?? "").capitalized
        }
    }

    var rawValue: String {
        switch self {
        case let .openAIServiceTierVariant(base, tier):
            return "\(Self.openAITierPrefix)\(tier)__\(base.rawValue)"
        case let .openrouterCustom(name):
            return "openrouter_custom_\(name)"
        case let .openaiCustom(n):
            return "openai_custom_\(n)"
        case let .openaiCustomResponses(n):
            return "openai_custom_responses_\(n)"
        case let .openaiCustomReasoning(n, effort):
            return "openai_custom_reasoning_\(effort.rawValue)__\(n)"
        case let .claudeCodeModel(specifier):
            return "\(ClaudeCodeAIModelCatalog.rawPrefix)\(ClaudeCodeAIModelCatalog.normalizedSpecifier(specifier))"
        case let .anthropicCustom(n):
            return "anthropic_custom_\(n)"
        case let .geminiCustom(n):
            return "gemini_custom_\(n)"
        case let .deepseekCustom(n):
            return "deepseek_custom_\(n)"
        case let .fireworksCustom(n):
            return "fireworks_custom_\(n)"
        case let .azureCustom(n):
            return "azure_custom_\(n)"
        case let .grokCustom(n): // <-- Handle Grok custom model rawValue
            return "grok_custom_\(n)"
        case let .groqCustom(n): // <-- Handle Groq custom model rawValue
            return "groq_custom_\(n)"
        case let .zaiCustom(n):
            return "zai_custom_\(n)"
        case let .codexCustom(n):
            return "codex_custom_\(n)"
        case let .openCodeCustom(n):
            return "opencode_custom_\(n)"
        case let .cursorCustom(n):
            return "cursor_custom_\(n)"
        case let .customProvider(_, _, model):
            return "custom_provider_\(model)"
        case let .customProviderUser(name):
            return "custom_provider_user_\(name)"
        case .ollama:
            return "ollama_\(modelName)"
        default:
            if let info = Self.modelDefinitions.first(where: { $0.model == self }) {
                return info.rawValue
            }
            return "unknown_model"
        }
    }

    var displayName: String {
        if case let .openAIServiceTierVariant(base, _) = self {
            return "\(base.displayName) (\(openAITierDisplayName))"
        }
        if case let .openrouterCustom(name) = self { return "oRouter/\(name)" }
        if case let .openaiCustom(n) = self { return "\(n)" }
        if case let .openaiCustomResponses(n) = self { return "\(n)" }
        if case let .openaiCustomReasoning(n, effort) = self { return "\(n) \(effort.displayName)" }
        if case let .claudeCodeModel(specifier) = self { return ClaudeCodeAIModelCatalog.displayName(for: specifier) }
        if case let .anthropicCustom(n) = self { return "\(n)" }
        if case let .geminiCustom(n) = self { return "\(n)" }
        if case let .deepseekCustom(n) = self { return "\(n)" }
        if case let .fireworksCustom(n) = self { return "\(n)" }
        if case let .azureCustom(n) = self {
            if let info = Self.modelData[self] {
                return info.displayName
            }
            let variantKey = Self.azureVariantKey(for: n)
            if let info = Self.modelData[.azureCustom(name: variantKey)] {
                return info.displayName
            }
            let baseName = Self.azureVariantBaseName(from: n)
            return "azure/\(baseName)"
        }
        if case let .grokCustom(n) = self { return "Grok/\(n)" } // <-- Handle Grok custom model displayName
        if case let .groqCustom(n) = self { return "Groq/\(n)" } // <-- Handle Groq custom model displayName
        if case let .zaiCustom(n) = self { return "Z.AI/\(n)" }
        if case let .codexCustom(n) = self {
            if let label = CodexDynamicModelStore.displayName(forModelID: n) {
                return "CLI·\(label)"
            }
            // Humanize the ID for synthesized models not in the store (e.g. fast-tier variants)
            return "CLI·\(Self.humanizedCodexBaseModel(n))"
        }
        if case let .openCodeCustom(n) = self {
            if let option = ACPAIModelCatalog.openCodeModelOption(for: n) {
                return option.displayName
            }
            return n
        }
        if case let .cursorCustom(n) = self {
            if let option = ACPAIModelCatalog.cursorModelOption(for: n) {
                return option.displayName
            }
            let normalized = ACPAIModelCatalog.normalizedCursorModelAlias(n)
            if normalized == AgentModel.cursorAuto.rawValue {
                return AgentModel.cursorAuto.displayName
            }
            if normalized == AgentModel.cursorComposer2.rawValue {
                return AgentModel.cursorComposer2.displayName
            }
            return n
        }
        if case let .customProviderUser(name) = self { return "Custom/\(name)" }
        if case .ollama = self {
            return "local/" + modelName
        }
        if case let .customProvider(name, provider, _) = self {
            return "\(provider)/\(name)" // Simplified display name
        }
        return Self.modelData[self]?.displayName ?? ""
    }

    var provider: AIProvider.Type {
        switch providerType {
        case .openAI: OpenAIProvider.self
        case .anthropic: AnthropicProvider.self
        case .gemini: GeminiProvider.self
        case .azure: AzureOpenAIProvider.self
        case .openRouter: OpenRouterProvider.self
        case .ollama: OpenAIProvider.self // Ollama uses OpenAI-compatible API
        case .deepseek: DeepSeekProvider.self
        case .fireworks: FireworksProvider.self
        case .customProvider: CustomOpenAIProvider.self
        case .grok: OpenAIProvider.self // GrokProvider will inherit from OpenAIProvider
        case .groq: GroqProvider.self
        case .zAI: ZAIProvider.self
        case .claudeCode: ClaudeCodeProvider.self
        case .codex: CodexCLIProvider.self
        case .openCode: OpenCodeCLIProvider.self
        case .cursor: CursorCLIProvider.self
        }
    }

    var providerType: AIProviderType {
        switch self {
        case let .openAIServiceTierVariant(base, _):
            return base.providerType
        // direct checks for each type
        case .openrouterCustom:
            return .openRouter
        case .customProvider:
            return .customProvider
        case .ollama:
            return .ollama
        case .openaiCustom, .openaiCustomResponses, .openaiCustomReasoning:
            return .openAI
        case .anthropicCustom: return .anthropic
        case .geminiCustom: return .gemini
        case .deepseekCustom: return .deepseek
        case .fireworksCustom: return .fireworks
        case .azureCustom: return .azure
        case .grokCustom: return .grok // <-- Handle Grok custom model providerType
        case .groqCustom: return .groq // <-- Handle Groq custom model providerType
        case .zaiCustom: return .zAI
        case .claudeCodeModel: return .claudeCode
        case .codexCustom: return .codex
        case .openCodeCustom: return .openCode
        case .cursorCustom: return .cursor
        case .customProviderUser: return .customProvider
        // or, if you prefer the old modelGroups approach:
        default:
            if Self.modelGroups[ProviderIndex.openAI].contains(self) { return .openAI }
            if Self.modelGroups[ProviderIndex.anthropic].contains(self) { return .anthropic }
            if Self.modelGroups[ProviderIndex.gemini].contains(self) { return .gemini }
            if Self.modelGroups[ProviderIndex.openRouter].contains(self) { return .openRouter }
            if Self.modelGroups[ProviderIndex.deepseek].contains(self) { return .deepseek }
            if Self.modelGroups[ProviderIndex.fireworks].contains(self) { return .fireworks }
            if Self.modelGroups[ProviderIndex.grok].contains(self) { return .grok } // <-- Add Grok to providerType check
            if Self.modelGroups[ProviderIndex.groq].contains(self) { return .groq } // <-- Add Groq to providerType check
            if Self.modelGroups[ProviderIndex.zAI].contains(self) { return .zAI }
            if Self.modelGroups[ProviderIndex.claudeCode].contains(self) { return .claudeCode } // <-- Add Claude Code to providerType check
            if Self.modelGroups[ProviderIndex.codex].contains(self) { return .codex }
            if Self.modelGroups[ProviderIndex.openCode].contains(self) { return .openCode }
            if Self.modelGroups[ProviderIndex.cursor].contains(self) { return .cursor }
            // fallback
            return .azure
        }
    }

    var claudeCodeRuntimeSpecifierRaw: String? {
        ClaudeCodeAIModelCatalog.runtimeSpecifierRaw(for: self)
    }

    var modelName: String {
        switch self {
        case let .openAIServiceTierVariant(base, _):
            return base.modelName
        case .ollama:
            return UserDefaults.standard.string(forKey: "ollamaModel") ?? "llama3.1"
        case let .openrouterCustom(name):
            return name
        case let .openaiCustom(n):
            return n
        case let .openaiCustomResponses(n):
            return n
        case let .openaiCustomReasoning(n, _):
            return n
        case let .claudeCodeModel(specifier):
            return ClaudeModelSpecifier(raw: specifier).runtimeModelParam ?? ""
        case let .anthropicCustom(n),
             let .geminiCustom(n),
             let .deepseekCustom(n),
             let .fireworksCustom(n):
            return n
        case let .azureCustom(n):
            return Self.azureVariantBaseName(from: n)
        case let .grokCustom(n),
             let .groqCustom(n),
             let .zaiCustom(n),
             let .codexCustom(n),
             let .openCodeCustom(n),
             let .cursorCustom(n):
            return n
        case let .customProviderUser(name):
            return name
        case let .customProvider(_, _, model):
            return model
        default:
            if let modelInfo = Self.modelDefinitions.first(where: { $0.model == self }) {
                return modelInfo.actualName ?? modelInfo.rawValue
            }
            return rawValue
        }
    }

    // ==========================================================
    // DIFF PRIORITY ARRAYS
    // ==========================================================

    /// "Simple" diff (cheaper first).
    static let simpleDiffPriority: [AIModel] = [
        // Prioritize practical current CLI variants first
        .claudeCodeSonnet,
        .codexCliGpt56SolMedium,
        .codexCliGpt56SolLow,
        .codexCliGpt56SolHigh,
        .gpt54Low,
        .gpt54,
        .gpt54High,
        .gpt5CodexLow,
        .gpt5Low,
        .gpt41,
        .fireworksDeepseekV3p1Terminus,
        .deepseekChat, .openrouterDeepseekChat,
        .claude4Sonnet, .openrouterClaude4Sonnet,
        .gemini3p1ProPreview,
        .geminiPro25, .openrouterGeminiPro25,
        .deepseekReasoner,
        .grok40709, // Add new Grok 4 model
        .zaiGLM52,
        .zaiGLM5,
        .zaiGLM5_0,
        .zaiGLM5Turbo,
        .zaiGLM47, .zaiGLM47Flash,
        .zaiGLM46,
        .zaiGLM45, .zaiGLM45Air, .zaiGLM45Flash
    ]

    /// "Medium" diff (user's final ranking).
    static let mediumDiffPriority: [AIModel] = [
        // Prioritize practical current CLI variants first
        .claudeCodeSonnet,
        .codexCliGpt56SolHigh,
        .codexCliGpt56SolMedium,
        .codexCliGpt56SolLow,
        .gpt54,
        .gpt54High,
        .gpt54Low,
        .gpt5CodexLow,
        .gpt5Low,
        .gpt41,
        .fireworksDeepseekV3p1Terminus,
        .deepseekChat, .openrouterDeepseekChat,
        .claude4Sonnet, .openrouterClaude4Sonnet,
        .gemini3p1ProPreview,
        .geminiPro25, .openrouterGeminiPro25,
        .deepseekReasoner,
        .grok40709, // Add new Grok 4 model
        .zaiGLM52,
        .zaiGLM5,
        .zaiGLM5_0,
        .zaiGLM5Turbo,
        .zaiGLM47, .zaiGLM47Flash,
        .zaiGLM46,
        .zaiGLM45, .zaiGLM45Air, .zaiGLM45Flash
    ]

    /// "High" diff (top-tier first).
    static let highDiffPriority: [AIModel] = [
        // Then other top models
        .claudeCodeSonnet,
        .codexCliGpt56SolHigh,
        .codexCliGpt56SolXHigh,
        .codexCliGpt56SolMedium,
        .gpt54High,
        .gpt54,
        .claude4Sonnet, .openrouterClaude4Sonnet,
        .gpt5CodexLow,
        .gpt5Low,
        .deepseekChat, .openrouterDeepseekChat,
        .fireworksDeepseekV3p1Terminus,
        .gemini3p1ProPreview,
        .geminiPro25, .openrouterGeminiPro25,
        .gpt41,
        .deepseekReasoner,
        .grok40709, // Add new Grok 4 model
        .zaiGLM52,
        .zaiGLM5,
        .zaiGLM5_0,
        .zaiGLM5Turbo,
        .zaiGLM47, .zaiGLM47Flash,
        .zaiGLM46,
        .zaiGLM45, .zaiGLM45Air, .zaiGLM45Flash
    ]

    // ==========================================================
    // WHOLE ARRAYS
    // ==========================================================

    /// "Simple" whole: prefer current Gemini 3.0 Flash, then fast GPT and fallback models.
    static let simpleWholePriority: [AIModel] = [
        .claudeCodeSonnet,
        .gemini3FlashPreview,
        .gpt54Low,
        // Prioritize fast and affordable models
        .gpt54Mini,
        // Then other cheap/fast models
        .deepseekChat, .openrouterDeepseekChat,
        .gpt41,
        .deepseekReasoner,
        .zaiGLM52,
        .zaiGLM5,
        .zaiGLM5_0,
        .zaiGLM5Turbo,
        .zaiGLM47, .zaiGLM47Flash,
        .zaiGLM46,
        .zaiGLM45, .zaiGLM45Air, .zaiGLM45Flash,
        .claude4Sonnet, .openrouterClaude4Sonnet,
        .geminiProLatest, .openrouterGeminiPro,
        .geminiPro25, .openrouterGeminiPro25,
        .geminiFlash25,
        .o3,
        .ollama
    ]

    /// "Medium" whole: prefer current Gemini 3.0 Flash, then balanced GPT and fallback models.
    static let mediumWholePriority: [AIModel] = [
        .claudeCodeSonnet,
        .gemini3FlashPreview,
        .gpt54,
        // Then the simple priorities
        .gpt54Mini,
        // fallback: everything else
        .deepseekChat, .openrouterDeepseekChat,
        .gpt41,
        .claude4Sonnet, .openrouterClaude4Sonnet,
        .geminiProLatest, .openrouterGeminiPro,
        .geminiPro25, .openrouterGeminiPro25,
        .geminiFlash25,
        .zaiGLM52,
        .zaiGLM5,
        .zaiGLM5_0,
        .zaiGLM5Turbo,
        .zaiGLM47, .zaiGLM47Flash,
        .zaiGLM46,
        .zaiGLM45, .zaiGLM45Air, .zaiGLM45Flash,
        .o3,
        .ollama
    ]

    /// "High" whole: optimized for more expensive models at top
    static let highWholePriority: [AIModel] = [
        // Prioritize higher-quality models for complex whole-file edits
        .claudeCodeSonnet,
        .gpt54High,
        .gemini3FlashPreview,
        .gpt54Mini,
        .geminiFlashLatest,
        // fallback: everything else
        .deepseekChat, .openrouterDeepseekChat,
        .gpt41,
        .zaiGLM52,
        .zaiGLM5,
        .zaiGLM5_0,
        .zaiGLM5Turbo,
        .zaiGLM47, .zaiGLM47Flash,
        .zaiGLM46,
        .zaiGLM45, .zaiGLM45Air, .zaiGLM45Flash,
        .claude4Sonnet, .openrouterClaude4Sonnet,
        .geminiProLatest, .openrouterGeminiPro,
        .geminiPro25, .openrouterGeminiPro25,
        .geminiFlash25,
        .o3,
        .ollama
    ]

    // Priority lists (kept for backward compatibility)
    static let diffPriorityModels: [AIModel] = mediumDiffPriority
    static let wholePriorityModels: [AIModel] = mediumWholePriority

    // ==========================================================
    // FIND BEST AVAILABLE MODEL (with fallback to "other" models)
    // ==========================================================

    // MARK: - Responses-API flag

    /// Returns **true** for built-in `o3-pro` variants.
    /// For *custom-provider* models it defers to `ModelOverridesSettings`.
    /// All other models return `false`.
    var usesResponsesAPI: Bool {
        // Delegate to base for tier variants
        if case let .openAIServiceTierVariant(base, _) = self {
            return base.usesResponsesAPI
        }
        // 1. Built-in support
        if [
            .gpt5Pro,
            .gpt5ProXHigh,
            .gpt54Pro,
            .gpt54ProXHigh,
            .o3,
            .o3Low,
            .o3High,
            .gpt5,
            .gpt5Low,
            .gpt5High,
            .gpt5XHigh,
            .gpt54,
            .gpt54Low,
            .gpt54High,
            .gpt54XHigh,
            .gpt54Mini,
            .gpt54MiniLow,
            .gpt54MiniHigh,
            .gpt54MiniXHigh,
            .gpt54Nano,
            .gpt5CodexLow,
            .gpt5CodexMed,
            .gpt5CodexHigh,
            .gpt5CodexXHigh
        ].contains(self) { return true }

        if case .openaiCustomResponses = self {
            return true
        }

        if case .openaiCustomReasoning = self {
            return true
        }

        // 2. Custom provider override
        if isCustomProviderModel,
           let override = ModelOverridesSettings.shared.responsesOverride(for: rawValue)
        {
            return override
        }

        // 3. Default
        return false
    }

    static func findBestAvailableModel(
        in availableModels: [AIModel],
        desiredFormat: PromptViewModel.FileEditFormat,
        priorities: [AIModel]
    ) -> AIModel? {
        // Filter out models that are not yet available
        let currentlyAvailableModels = availableModels.filter(\.isAvailable)

        // 1) Try the official priority list
        for candidate in priorities {
            guard let match = currentlyAvailableModels.first(where: { $0 == candidate }) else { continue }
            switch desiredFormat {
            case .diff:
                if match.isModelCapableOfDiff { return match }
            case .whole, .none:
                return match
            }
        }
        // 2) If none found in the list, fallback to ANY leftover model in user's environment
        //    e.g. custom provider or openrouterCustom not in the arrays
        //    Skip service tier variants to prevent accidental selection of explicit tiers
        for possible in currentlyAvailableModels {
            if possible.isOpenAIServiceTierVariant { continue }
            if !priorities.contains(possible) {
                // This means it's "unlisted."
                // Check if it meets the diff requirement if needed:
                switch desiredFormat {
                case .diff:
                    if possible.isModelCapableOfDiff { return possible }
                case .whole, .none:
                    return possible
                }
            }
        }
        // 3) Return nil if truly nothing is suitable
        return nil
    }

    /// Helper check for custom provider or openrouterCustom
    var isCustom: Bool {
        switch self {
        case .customProvider(_, _, _),
             .customProviderUser(_),
             .openrouterCustom(_),
             .openaiCustom(_),
             .openaiCustomResponses(_),
             .openaiCustomReasoning(_, _),
             .anthropicCustom(_),
             .geminiCustom(_),
             .deepseekCustom(_),
             .fireworksCustom(_),
             .azureCustom(_),
             .grokCustom(_),
             .groqCustom(_),
             .zaiCustom(_),
             .codexCustom(_),
             .ollama:
            true
        default:
            false
        }
    }

    /// NEW: returns true only for `.customProvider` / `.customProviderUser`
    private var isCustomProviderModel: Bool {
        switch self {
        case .customProvider(_, _, _), .customProviderUser:
            true
        default:
            false
        }
    }

    var isOpenAIModel: Bool {
        if case let .openAIServiceTierVariant(base, _) = self {
            return base.isOpenAIModel
        }
        return Self.modelGroups[ProviderIndex.openAI].contains(self)
    }

    var isAnthropicModel: Bool {
        Self.modelGroups[ProviderIndex.anthropic].contains(self)
    }

    var isGeminiModel: Bool {
        Self.modelGroups[ProviderIndex.gemini].contains(self)
    }

    var isOpenRouterModel: Bool {
        Self.modelGroups[ProviderIndex.openRouter].contains(self) || (rawValue.starts(with: "openrouter_custom_"))
    }

    var isOllamaModel: Bool {
        self == .ollama
    }

    /// Check if a model is currently available based on its release date
    var isAvailable: Bool {
        guard let modelInfo = Self.modelDefinitions.first(where: { $0.model == self }) else {
            return true // Unknown models default to available
        }

        if let releaseDate = modelInfo.availableFrom {
            return Date() >= releaseDate
        }

        return true // No release date means always available
    }

    var isModelCapableOfDiff: Bool {
        // All models use the diff-edit prompt path. Keep this unconditional so legacy
        // allowlists, custom-provider heuristics, and per-model overrides cannot force
        // models back to whole-file rewrite mode.
        true
    }

    /// New helper: whether this model can stream.
    var canStream: Bool {
        // Delegate to base for tier variants
        if case let .openAIServiceTierVariant(base, _) = self {
            return base.canStream
        }
        if let override = ModelOverridesSettings.shared.streamOverride(for: rawValue) {
            return override
        }
        // Explicitly disable streaming for all Pro variants
        if self == .gpt5Pro || self == .gpt5ProXHigh || self == .gpt54Pro || self == .gpt54ProXHigh {
            return false
        }
        return true
    }

    var defaultReasoningEffort: String? {
        // Delegate to base for tier variants
        if case let .openAIServiceTierVariant(base, _) = self {
            return base.defaultReasoningEffort
        }
        switch self {
        case .gpt5Pro, .gpt54Pro: return "high"
        case .gpt5ProXHigh, .gpt54ProXHigh: return "xhigh"
        case .gpt5XHigh, .gpt54XHigh, .gpt5CodexXHigh: return "xhigh"
        case .gpt5High, .gpt54High, .gpt5CodexHigh, .o3High: return "high"
        case .gpt5, .gpt54, .gpt5CodexMed, .o3: return "medium"
        case .gpt5Low, .gpt54Low, .gpt5CodexLow, .o3Low: return "low"
        // Codex CLI models
        case .codexCliGpt56SolUltra, .codexCliGpt56TerraUltra: return "ultra"
        case .codexCliGpt56SolMax, .codexCliGpt56TerraMax, .codexCliGpt56LunaMax: return "max"
        case .codexCliGpt56SolXHigh, .codexCliGpt56TerraXHigh, .codexCliGpt56LunaXHigh,
             .codexCliGpt5XHigh, .codexCliGpt54XHigh, .codexCliGpt5CodexXHigh: return "xhigh"
        case .codexCliGpt56SolHigh, .codexCliGpt56TerraHigh, .codexCliGpt56LunaHigh,
             .codexCliGpt5High, .codexCliGpt54High, .codexCliGpt5CodexHigh: return "high"
        case .codexCliGpt56SolMedium, .codexCliGpt56TerraMedium, .codexCliGpt56LunaMedium,
             .codexCliGpt5Medium, .codexCliGpt54Medium, .codexCliGpt5CodexMedium: return "medium"
        case .codexCliGpt56SolLow, .codexCliGpt56TerraLow, .codexCliGpt56LunaLow,
             .codexCliGpt5Low, .codexCliGpt54Low, .codexCliGpt5CodexLow: return "low"
        case let .codexCustom(name):
            return CodexModelSpecifier(raw: name).reasoningEffort?.rawValue
        case let .claudeCodeModel(specifier):
            return ClaudeModelSpecifier(raw: specifier).explicitEffortLevel?.rawValue
        case let .openaiCustomReasoning(_, effort):
            return effort.rawValue
        default: return nil
        }
    }

    /// Returns the Codex service tier override for this model, if any.
    /// Currently only GPT-5.4 Fast variants request the "fast" service tier.
    var codexServiceTier: String? {
        switch self {
        case let .codexCustom(name):
            let specifier = CodexModelSpecifier(raw: name)
            guard let baseModel = specifier.baseModel else { return nil }
            return CodexServiceTierVariantCatalog.supportedServiceTier(
                baseModelID: baseModel,
                serviceTier: specifier.serviceTier
            )
        default:
            return nil
        }
    }

    func toProviderModel() -> Any {
        // Delegate to base for tier variants
        if case let .openAIServiceTierVariant(base, _) = self {
            return base.toProviderModel()
        }
        switch providerType {
        case .openAI, .gemini, .ollama, .deepseek, .fireworks, .grok, .groq, .zAI: // <-- Add Groq here
            return SwiftOpenAI.Model.custom(modelName)
        case .anthropic:
            return SwiftAnthropic.Model.other(modelName)
        case .azure, .openRouter, .customProvider, .claudeCode, .codex, .openCode, .cursor:
            // For these providers, use the actual model name when available
            if let modelInfo = Self.modelDefinitions.first(where: { $0.model == self }),
               let actualName = modelInfo.actualName
            {
                return SwiftOpenAI.Model.custom(actualName)
            }
            return SwiftOpenAI.Model.custom(modelName)
        }
    }

    static func fromModelName(_ rawValue: String) -> AIModel? {
        let normalizedRawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedRawValue = normalizedRawValue.lowercased()
        guard !lowercasedRawValue.hasPrefix("gemini_cli_") else {
            return nil
        }
        switch lowercasedRawValue {
        case "gemini-3-pro-preview":
            return .gemini3p1ProPreview
        case "glm-5.2":
            return .zaiGLM52
        case "glm-5":
            return .zaiGLM5_0
        default:
            break
        }

        // Handle service tier variants
        if normalizedRawValue.hasPrefix(openAITierPrefix) {
            let rest = String(normalizedRawValue.dropFirst(openAITierPrefix.count))
            let parts = rest.components(separatedBy: "__")
            if parts.count >= 2 {
                let tier = parts[0]
                let baseRaw = parts.dropFirst().joined(separator: "__")
                if let base = AIModel.fromModelName(baseRaw) {
                    if !UserDefaults.standard.bool(forKey: "openAIShowServiceTierVariants") {
                        return base
                    }
                    return .openAIServiceTierVariant(base: base, tier: tier)
                }
            }
        }

        // Handle custom OpenRouter models
        if normalizedRawValue.starts(with: "openrouter_custom_") {
            return .openrouterCustom(name: String(normalizedRawValue.dropFirst("openrouter_custom_".count)))
        }

        // Handle Claude Code CLI provider models with a provider-specific prefix to avoid
        // conflicts with Anthropic API model IDs such as "claude-opus-4-6".
        if normalizedRawValue.hasPrefix(ClaudeCodeAIModelCatalog.rawPrefix) {
            let specifier = String(normalizedRawValue.dropFirst(ClaudeCodeAIModelCatalog.rawPrefix.count))
            return ClaudeCodeAIModelCatalog.validatedModel(specifier: specifier)
        }

        // Agent discovery/app-settings may persist unprefixed Claude Code model raws
        // with explicit effort suffixes, e.g. "claude-opus-4-5:high". Treat the
        // effort suffix as a provider signal so these do not fall through to an
        // unrelated chat-model fallback. Bare no-effort full IDs still use the
        // standard exact resolver below to preserve Anthropic conflict behavior.
        if let claudeCodeModel = ClaudeCodeAIModelCatalog.validatedAgentCatalogEffortModel(specifier: normalizedRawValue) {
            return claudeCodeModel
        }

        // Handle Codex CLI models with prefix
        if normalizedRawValue.starts(with: "codex_cli_") {
            if let model = modelDefinitions.first(where: { $0.rawValue == normalizedRawValue })?.model {
                return model
            }
            switch normalizedRawValue {
            case "codex_cli_gpt-5.5-low":
                return .codexCliGpt56SolLow
            case "codex_cli_gpt-5.5-medium":
                return .codexCliGpt56SolMedium
            case "codex_cli_gpt-5.5-high":
                return .codexCliGpt56SolHigh
            case "codex_cli_gpt-5.5-xhigh":
                return .codexCliGpt56SolXHigh
            default:
                return nil
            }
        }
        if normalizedRawValue.starts(with: "codex_custom_") {
            return .codexCustom(name: String(normalizedRawValue.dropFirst("codex_custom_".count)))
        }
        if normalizedRawValue.starts(with: "opencode_custom_") {
            return .openCodeCustom(name: String(normalizedRawValue.dropFirst("opencode_custom_".count)))
        }
        if normalizedRawValue.starts(with: "cursor_custom_") {
            return .cursorCustom(name: String(normalizedRawValue.dropFirst("cursor_custom_".count)))
        }

        if normalizedRawValue.starts(with: "openai_custom_reasoning_") {
            let rest = String(normalizedRawValue.dropFirst("openai_custom_reasoning_".count))
            let parts = rest.components(separatedBy: "__")
            if parts.count >= 2,
               let effort = CodexReasoningEffort.parse(parts[0])
            {
                let name = parts.dropFirst().joined(separator: "__")
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return .openaiCustomReasoning(name: name, effort: effort)
            }
        }

        if normalizedRawValue.starts(with: "openai_custom_responses_") {
            let name = String(normalizedRawValue.dropFirst("openai_custom_responses_".count))
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .openaiCustomResponses(name: name)
        }

        let customPrefixes: [(String, (String) -> AIModel)] = [
            ("openai_custom_", { .openaiCustom(name: $0) }),
            ("anthropic_custom_", { .anthropicCustom(name: $0) }),
            ("gemini_custom_", { .geminiCustom(name: $0) }),
            ("deepseek_custom_", { .deepseekCustom(name: $0) }),
            ("fireworks_custom_", { .fireworksCustom(name: $0) }),
            ("azure_custom_", { .azureCustom(name: $0) }),
            ("zai_custom_", { .zaiCustom(name: $0) })
        ]
        for (prefix, builder) in customPrefixes where normalizedRawValue.hasPrefix(prefix) {
            return builder(String(normalizedRawValue.dropFirst(prefix.count)))
        }

        // Handle Grok custom models
        if normalizedRawValue.starts(with: "grok_custom_") {
            return .grokCustom(name: String(normalizedRawValue.dropFirst("grok_custom_".count)))
        }

        // Handle Groq custom models
        if normalizedRawValue.starts(with: "groq_custom_") {
            return .groqCustom(name: String(normalizedRawValue.dropFirst("groq_custom_".count)))
        }

        if normalizedRawValue.starts(with: "ollama_") {
            return .ollama
        }

        // Handle custom provider models
        if normalizedRawValue.starts(with: "custom_provider_user_") {
            return .customProviderUser(name: String(normalizedRawValue.dropFirst("custom_provider_user_".count)))
        }
        if normalizedRawValue.starts(with: "custom_provider_") {
            let modelName = String(normalizedRawValue.dropFirst("custom_provider_".count))
            if let config = try? CustomProviderConfiguration.load() {
                // Preserve the user's selection and show the real provider name when available
                return .customProvider(name: modelName, provider: config.name, model: modelName)
            } else {
                // Best-effort placeholder; still treats it as a real custom provider model
                return .customProvider(name: modelName, provider: "custom", model: modelName)
            }
        }

        // Handle Fireworks models
        if normalizedRawValue.starts(with: "accounts/fireworks/models/") {
            return modelDefinitions.first { $0.rawValue == normalizedRawValue }?.model
        }

        // Handle standard models
        return modelData.first(where: { $0.value.rawValue == normalizedRawValue })?.key
    }

    static func modelsForProvider(_ provider: AIProviderType) -> [AIModel] {
        let models: [AIModel]
        switch provider {
        case .anthropic:
            models = Array(modelGroups[ProviderIndex.anthropic])
        case .openAI:
            models = Array(modelGroups[ProviderIndex.openAI])
        case .gemini:
            models = Array(modelGroups[ProviderIndex.gemini])
        case .openRouter:
            models = Array(modelGroups[ProviderIndex.openRouter])
        case .deepseek:
            models = Array(modelGroups[ProviderIndex.deepseek])
        case .ollama:
            models = [.ollama]
        case .azure:
            models = Array(modelGroups[ProviderIndex.azure])
        case .customProvider:
            var customModels: [AIModel] = []
            if let config = try? CustomProviderConfiguration.load() {
                customModels.append(.customProvider(name: config.name, provider: "custom", model: config.defaultModel))
                if let userModel = config.userPreferredModel, !userModel.isEmpty {
                    customModels.append(.customProviderUser(name: userModel))
                }
            }
            models = customModels
        case .fireworks: // <-- Add Fireworks case
            models = Array(modelGroups[ProviderIndex.fireworks])
        case .grok: // <-- Add Grok case
            models = Array(modelGroups[ProviderIndex.grok])
        case .groq: // <-- Add Groq case
            models = Array(modelGroups[ProviderIndex.groq])
        case .zAI:
            models = Array(modelGroups[ProviderIndex.zAI])
        case .claudeCode:
            models = ClaudeCodeAIModelCatalog.modelsForPicker()
        case .codex:
            models = codexModelsForPicker()
        case .openCode:
            models = ACPAIModelCatalog.openCodeModelsFromStore()
        case .cursor:
            models = ACPAIModelCatalog.cursorModelsFromStore()
        }

        // Filter out models that are not yet available based on their release date
        return models.filter(\.isAvailable)
    }

    struct CodexPickerMenuGroup: Identifiable, Hashable {
        let baseModelID: String
        let displayName: String
        let models: [AIModel]

        var id: String {
            baseModelID.lowercased()
        }
    }

    struct OpenCodePickerMenuOption: Identifiable, Hashable {
        let model: AIModel
        let displayName: String

        var id: String {
            model.rawValue
        }
    }

    struct OpenCodePickerMenuGroup: Identifiable, Hashable {
        let baseModelID: String
        let displayName: String
        let modelDisplayName: String
        let options: [OpenCodePickerMenuOption]
        let rendersAsSubmenu: Bool

        var id: String {
            baseModelID.lowercased()
        }
    }

    struct OpenCodePickerProviderMenuGroup: Identifiable, Hashable {
        let providerID: String?
        let displayName: String
        let groups: [OpenCodePickerMenuGroup]
        let rendersAsSubmenu: Bool

        var id: String {
            providerID?.lowercased() ?? "_root"
        }
    }

    struct OpenCodePickerMenu: Hashable {
        let providerGroups: [OpenCodePickerProviderMenuGroup]
        let groups: [OpenCodePickerMenuGroup]
    }

    struct ClaudeCodePickerMenuOption: Identifiable, Hashable {
        let model: AIModel
        let displayName: String

        var id: String {
            model.rawValue
        }
    }

    struct ClaudeCodePickerMenuGroup: Identifiable, Hashable {
        let baseModelRaw: String
        let displayName: String
        let options: [ClaudeCodePickerMenuOption]
        let rendersAsSubmenu: Bool

        var id: String {
            baseModelRaw.lowercased()
        }
    }

    struct ClaudeCodePickerMenu: Hashable {
        let defaultOption: ClaudeCodePickerMenuOption?
        let groups: [ClaudeCodePickerMenuGroup]
    }

    private struct SemanticSortMetadata {
        let family: String
        let versionComponents: [Int]
        let suffix: String
        let reasoningEffort: CodexReasoningEffort?
        let displayName: String
        let tieBreaker: String
    }

    static func sortedForPicker(_ models: [AIModel]) -> [AIModel] {
        var metadataCache: [AIModel: SemanticSortMetadata] = [:]
        func metadata(for model: AIModel) -> SemanticSortMetadata {
            if let cached = metadataCache[model] {
                return cached
            }
            let metadata = semanticSortMetadata(for: model)
            metadataCache[model] = metadata
            return metadata
        }

        return models.sorted { lhs, rhs in
            if lhs.providerType != rhs.providerType {
                return ModelPickerStringOrdering.precedes(
                    AIProviderType.displayName(for: lhs.providerType),
                    AIProviderType.displayName(for: rhs.providerType)
                )
            }
            if lhs.providerType == .claudeCode {
                return ClaudeCodeAIModelCatalog.modelPrecedes(lhs, rhs)
            }
            return semanticMetadataPrecedes(metadata(for: lhs), metadata(for: rhs))
        }
    }

    static func pickerSortComparator(_ lhs: AIModel, _ rhs: AIModel) -> Bool {
        if lhs.providerType != rhs.providerType {
            return ModelPickerStringOrdering.precedes(
                AIProviderType.displayName(for: lhs.providerType),
                AIProviderType.displayName(for: rhs.providerType)
            )
        }
        if lhs.providerType == .claudeCode {
            return ClaudeCodeAIModelCatalog.modelPrecedes(lhs, rhs)
        }
        return semanticModelPrecedes(lhs, rhs)
    }

    static func claudeCodeMenu(for models: [AIModel]) -> ClaudeCodePickerMenu {
        ClaudeCodeAIModelCatalog.menu(for: models)
    }

    static func openCodeMenu(for models: [AIModel]) -> OpenCodePickerMenu {
        var modelsByName: [String: AIModel] = [:]
        var sourceOptionsByRaw: [String: AgentModelOption] = [:]
        for option in ACPAIModelCatalog.openCodeModelOptionsFromStore() {
            let key = option.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, sourceOptionsByRaw[key] == nil else { continue }
            sourceOptionsByRaw[key] = option
        }
        let options = models.compactMap { model -> AgentModelOption? in
            guard model.providerType == .openCode else { return nil }
            let modelName = model.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelName.isEmpty else { return nil }
            modelsByName[modelName.lowercased()] = model
            let sourceOption = sourceOptionsByRaw[modelName.lowercased()]
            return AgentModelOption(
                rawValue: modelName,
                displayName: sourceOption?.displayName ?? modelName,
                description: sourceOption?.description,
                isPlaceholderDefault: sourceOption?.isPlaceholderDefault ?? false,
                isProviderDefault: sourceOption?.isProviderDefault ?? false,
                supportedReasoningEfforts: sourceOption?.supportedReasoningEfforts ?? [],
                defaultReasoningEffort: sourceOption?.defaultReasoningEffort
            )
        }

        let catalogMenu = AgentModelCatalog.openCodeMenu(for: options)
        var groupsByID: [String: OpenCodePickerMenuGroup] = [:]
        let groups = catalogMenu.groups.compactMap { group -> OpenCodePickerMenuGroup? in
            let menuOptions = group.options.compactMap { menuOption -> OpenCodePickerMenuOption? in
                guard let model = modelsByName[menuOption.option.rawValue.lowercased()] else { return nil }
                return OpenCodePickerMenuOption(model: model, displayName: menuOption.displayName)
            }
            guard !menuOptions.isEmpty else { return nil }
            let pickerGroup = OpenCodePickerMenuGroup(
                baseModelID: group.baseModelID,
                displayName: group.displayName,
                modelDisplayName: group.modelDisplayName,
                options: menuOptions,
                rendersAsSubmenu: group.rendersAsSubmenu
            )
            groupsByID[group.id] = pickerGroup
            return pickerGroup
        }
        let providerGroups = catalogMenu.providerGroups.compactMap { providerGroup -> OpenCodePickerProviderMenuGroup? in
            let pickerGroups = providerGroup.groups.compactMap { groupsByID[$0.id] }
            guard !pickerGroups.isEmpty else { return nil }
            return OpenCodePickerProviderMenuGroup(
                providerID: providerGroup.providerID,
                displayName: providerGroup.displayName,
                groups: pickerGroups,
                rendersAsSubmenu: providerGroup.rendersAsSubmenu
            )
        }
        return OpenCodePickerMenu(providerGroups: providerGroups, groups: groups)
    }

    static func openCodeMenuGroups(for models: [AIModel]) -> [OpenCodePickerMenuGroup] {
        openCodeMenu(for: models).groups
    }

    static func codexMenuGroups(for models: [AIModel]) -> [CodexPickerMenuGroup] {
        struct Entry {
            let model: AIModel
            let baseModelID: String
            let displayName: String
            let reasoningEffort: CodexReasoningEffort?
        }

        let entries = models.map { model in
            let baseModelID = codexBaseModelID(for: model)
            return Entry(
                model: model,
                baseModelID: baseModelID,
                displayName: codexBaseDisplayName(for: baseModelID, fallbackDisplayName: model.displayName),
                reasoningEffort: codexReasoningEffort(for: model)
            )
        }

        let grouped = Dictionary(grouping: entries, by: { $0.baseModelID.lowercased() })
        return grouped.values.compactMap { groupEntries in
            guard let representative = groupEntries.first else { return nil }
            let sortedModels = groupEntries.sorted { lhs, rhs in
                let leftRank = reasoningSortRank(lhs.reasoningEffort)
                let rightRank = reasoningSortRank(rhs.reasoningEffort)
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return semanticModelPrecedes(lhs.model, rhs.model)
            }.map(\.model)

            return CodexPickerMenuGroup(
                baseModelID: representative.baseModelID,
                displayName: representative.displayName,
                models: sortedModels
            )
        }.sorted { lhs, rhs in
            if codexBaseModelPrecedes(lhs.baseModelID, rhs.baseModelID) { return true }
            if codexBaseModelPrecedes(rhs.baseModelID, lhs.baseModelID) { return false }
            return ModelPickerStringOrdering.precedes(lhs.displayName, rhs.displayName)
        }
    }

    static func codexBaseModelPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        let leftMetadata = semanticSortMetadata(identifier: lhs, fallbackDisplayName: lhs, reasoningEffort: nil)
        let rightMetadata = semanticSortMetadata(identifier: rhs, fallbackDisplayName: rhs, reasoningEffort: nil)
        return semanticMetadataPrecedes(leftMetadata, rightMetadata)
    }

    static func codexBaseDisplayName(for baseModelID: String, fallbackDisplayName: String) -> String {
        if let storeLabel = CodexDynamicModelStore.displayName(forModelID: baseModelID) {
            let normalizedStoreLabel = normalizedCodexBaseLabel(storeLabel)
            if !normalizedStoreLabel.isEmpty {
                return codexPreviewDisplayAlias(for: normalizedStoreLabel) ?? normalizedStoreLabel
            }
        }

        let fallbackLabel = normalizedCodexBaseLabel(fallbackDisplayName)
        if !fallbackLabel.isEmpty {
            return humanizedCodexBaseModel(fallbackLabel)
        }

        return humanizedCodexBaseModel(baseModelID)
    }

    static func codexPreviewDisplayAlias(for raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let specifier = CodexModelSpecifier(raw: trimmed)
        let base = specifier.baseModel ?? trimmed
        let normalizedBase = normalizedSemanticText(base)
        let canonicalBase: String
        switch normalizedBase {
        case "gpt-5.6", "gpt-5.6-sol":
            canonicalBase = "GPT-5.6 Sol"
        case "gpt-5.6-terra":
            canonicalBase = "GPT-5.6 Terra"
        case "gpt-5.6-luna":
            canonicalBase = "GPT-5.6 Luna"
        case "gpt-5.5":
            canonicalBase = "GPT-5.5"
        default:
            return nil
        }

        var label = canonicalBase
        if let serviceTier = specifier.serviceTier {
            label += serviceTier == CodexServiceTierVariantCatalog.fastServiceTier ? " Fast" : " \(serviceTier.capitalized)"
        }
        if let reasoningEffort = specifier.reasoningEffort {
            label += " \(reasoningEffort.displayName)"
        }
        return label
    }

    static func stripCodexReasoningSuffix(from label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let specifier = codexSpecifierFromSemanticLabel(trimmed)
        guard specifier.reasoningEffort != nil, let baseModel = specifier.baseModel else {
            return trimmed
        }

        var stripped = humanizedCodexBaseModel(baseModel)
        if let serviceTier = specifier.serviceTier {
            stripped += serviceTier == CodexServiceTierVariantCatalog.fastServiceTier
                ? " Fast"
                : " \(serviceTier.capitalized)"
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func semanticModelPrecedes(_ lhs: AIModel, _ rhs: AIModel) -> Bool {
        let leftMetadata = semanticSortMetadata(for: lhs)
        let rightMetadata = semanticSortMetadata(for: rhs)
        return semanticMetadataPrecedes(leftMetadata, rightMetadata)
    }

    private static func semanticMetadataPrecedes(_ lhs: SemanticSortMetadata, _ rhs: SemanticSortMetadata) -> Bool {
        let familyComparison = ModelPickerStringOrdering.compare(lhs.family, rhs.family, caseInsensitiveASCII: true)
        if familyComparison != .orderedSame {
            return familyComparison == .orderedAscending
        }

        let versionComparison = compareVersionComponents(lhs.versionComponents, rhs.versionComponents)
        if versionComparison != .orderedSame {
            return versionComparison == .orderedDescending
        }

        let leftReasoningRank = reasoningSortRank(lhs.reasoningEffort)
        let rightReasoningRank = reasoningSortRank(rhs.reasoningEffort)
        if leftReasoningRank != rightReasoningRank {
            return leftReasoningRank < rightReasoningRank
        }

        let suffixComparison = ModelPickerStringOrdering.compare(lhs.suffix, rhs.suffix, caseInsensitiveASCII: true)
        if suffixComparison != .orderedSame {
            return suffixComparison == .orderedAscending
        }

        let displayComparison = ModelPickerStringOrdering.compare(lhs.displayName, rhs.displayName, caseInsensitiveASCII: true)
        if displayComparison != .orderedSame {
            return displayComparison == .orderedAscending
        }

        return ModelPickerStringOrdering.precedes(lhs.tieBreaker, rhs.tieBreaker)
    }

    private static func semanticSortMetadata(for model: AIModel) -> SemanticSortMetadata {
        let identifier = model.providerType == .codex ? codexBaseModelID(for: model) : model.modelName
        let reasoningEffort = codexReasoningEffort(for: model)
            ?? reasoningEffort(in: model.modelName)
            ?? reasoningEffort(in: model.displayName)
        let metadata = semanticSortMetadata(
            identifier: identifier,
            fallbackDisplayName: model.displayName,
            reasoningEffort: reasoningEffort
        )

        return SemanticSortMetadata(
            family: metadata.family,
            versionComponents: metadata.versionComponents,
            suffix: metadata.suffix,
            reasoningEffort: metadata.reasoningEffort,
            displayName: metadata.displayName,
            tieBreaker: model.rawValue
        )
    }

    private static func semanticSortMetadata(
        identifier: String,
        fallbackDisplayName: String,
        reasoningEffort: CodexReasoningEffort?
    ) -> SemanticSortMetadata {
        let semanticSource = codexPreviewDisplayAlias(for: identifier) ?? (identifier.isEmpty ? fallbackDisplayName : identifier)
        let normalizedIdentifier = normalizedSemanticText(semanticSource)
        let family = semanticFamily(in: normalizedIdentifier)
        let versionComponents = semanticVersionComponents(in: normalizedIdentifier)
        let suffix = semanticSuffix(in: normalizedIdentifier)

        return SemanticSortMetadata(
            family: family,
            versionComponents: versionComponents,
            suffix: suffix,
            reasoningEffort: reasoningEffort,
            displayName: fallbackDisplayName,
            tieBreaker: identifier
        )
    }

    private static func compareVersionComponents(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        guard !lhs.isEmpty || !rhs.isEmpty else { return .orderedSame }

        let maxCount = max(lhs.count, rhs.count)
        for index in 0 ..< maxCount {
            let leftValue = index < lhs.count ? lhs[index] : -1
            let rightValue = index < rhs.count ? rhs[index] : -1
            if leftValue == rightValue { continue }
            return leftValue < rightValue ? .orderedAscending : .orderedDescending
        }

        return .orderedSame
    }

    private static func reasoningSortRank(_ effort: CodexReasoningEffort?) -> Int {
        guard let effort else { return -1 }
        return CodexReasoningEffort.displayOrder.firstIndex(of: effort) ?? Int.max
    }

    private static func codexBaseModelID(for model: AIModel) -> String {
        let specifier = CodexModelSpecifier(raw: model.modelName)
        var candidate = specifier.baseModel ?? model.modelName
        // Preserve service tier in the grouping key so fast/flex variants get their own picker group
        if let tier = specifier.serviceTier {
            candidate += "-\(tier)"
        }
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func codexReasoningEffort(for model: AIModel) -> CodexReasoningEffort? {
        let specifier = CodexModelSpecifier(raw: model.modelName)
        return specifier.reasoningEffort
            ?? reasoningEffort(in: model.modelName)
            ?? reasoningEffort(in: model.displayName)
    }

    private static func reasoningEffort(in text: String) -> CodexReasoningEffort? {
        codexSpecifierFromSemanticLabel(text).reasoningEffort
    }

    private static func codexSpecifierFromSemanticLabel(_ text: String) -> CodexModelSpecifier {
        let parseableText = text
            .replacingOccurrences(of: "CLI·", with: "")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
        let normalized = normalizedSemanticText(parseableText)
        let candidates = codexSpecifierCandidates(fromNormalizedSemanticText: normalized)
        for candidate in candidates {
            let specifier = CodexModelSpecifier(raw: candidate)
            if specifier.reasoningEffort != nil {
                return specifier
            }
        }
        return CodexModelSpecifier(raw: normalized)
    }

    private static func codexSpecifierCandidates(fromNormalizedSemanticText normalized: String) -> [String] {
        guard !normalized.isEmpty else { return [normalized] }

        var candidates: [String] = []
        func appendAlias(suffix: String, replacement: String) {
            guard normalized.hasSuffix(suffix) else { return }
            let base = String(normalized.dropLast(suffix.count))
            guard !base.isEmpty else { return }
            candidates.append("\(base)\(replacement)")
        }

        appendAlias(suffix: "-x-high", replacement: "-xhigh")
        appendAlias(suffix: "-med", replacement: "-medium")
        candidates.append(normalized)
        return candidates
    }

    private static func normalizedCodexBaseLabel(_ label: String) -> String {
        let withoutPrefix = label
            .replacingOccurrences(of: "CLI·", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripCodexReasoningSuffix(from: withoutPrefix)
    }

    private static func humanizedCodexBaseModel(_ raw: String) -> String {
        if let alias = codexPreviewDisplayAlias(for: raw) {
            return alias
        }

        let tokens = raw.split { character in
            character == "_" || character == "-" || character == "/" || character.isWhitespace
        }
        guard !tokens.isEmpty else { return raw }

        var formatted: [String] = []
        formatted.reserveCapacity(tokens.count)
        for token in tokens {
            let value = String(token)
            let formattedToken = formatCodexLabelToken(value)
            if isVersionToken(value), formatted.last == "GPT" {
                formatted[formatted.count - 1] = "GPT-\(formattedToken)"
            } else {
                formatted.append(formattedToken)
            }
        }
        return formatted.joined(separator: " ")
    }

    private static func formatCodexLabelToken(_ value: String) -> String {
        let lower = value.lowercased()
        if lower == "gpt" { return "GPT" }
        if lower == "codex" { return "Codex" }
        if lower == "xhigh" { return "XHigh" }
        if isVersionToken(value) { return value }
        return lower.capitalized
    }

    private static func isVersionToken(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }

    private static func normalizedSemanticText(_ text: String) -> String {
        var output = ""
        var previousWasSeparator = false
        for character in text.lowercased() {
            if character == "·" || character == "_" || character.isWhitespace {
                if !previousWasSeparator {
                    output.append("-")
                    previousWasSeparator = true
                }
            } else {
                output.append(character)
                previousWasSeparator = false
            }
        }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: "- /"))
    }

    private static func semanticFamily(in text: String) -> String {
        guard let firstNumberIndex = text.firstIndex(where: { $0.isNumber }) else {
            return text
        }

        let prefix = text[..<firstNumberIndex]
            .trimmingCharacters(in: CharacterSet(charactersIn: "- /"))
        return prefix.isEmpty ? text : String(prefix)
    }

    private static func semanticVersionComponents(in text: String) -> [Int] {
        guard let firstNumberIndex = text.firstIndex(where: { $0.isNumber }) else {
            return []
        }

        var cursor = firstNumberIndex
        var versionString = ""
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isNumber || character == "." {
                versionString.append(character)
                cursor = text.index(after: cursor)
                continue
            }
            break
        }

        return versionString
            .split(separator: ".")
            .compactMap { Int($0) }
    }

    private static func semanticSuffix(in text: String) -> String {
        guard let firstNumberIndex = text.firstIndex(where: { $0.isNumber }) else {
            return text
        }

        var cursor = firstNumberIndex
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isNumber || character == "." {
                cursor = text.index(after: cursor)
                continue
            }
            break
        }

        return text[cursor...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "- /"))
    }

    static func allModels() -> [AIModel] {
        var models: [AIModel] = []
        for (providerIndex, group) in modelGroups.enumerated() {
            if providerIndex == ProviderIndex.claudeCode {
                models.append(contentsOf: ClaudeCodeAIModelCatalog.modelsForPicker())
            } else if providerIndex == ProviderIndex.codex {
                models.append(contentsOf: codexModelsForPicker())
            } else if providerIndex == ProviderIndex.openCode {
                models.append(contentsOf: ACPAIModelCatalog.openCodeModelsFromStore())
            } else if providerIndex == ProviderIndex.cursor {
                models.append(contentsOf: ACPAIModelCatalog.cursorModelsFromStore())
            } else {
                models.append(contentsOf: group)
            }
        }
        models.append(.ollama)
        // Filter out models that are not yet available based on their release date
        return models.filter(\.isAvailable)
    }

    private indirect enum AIModelIdentity: Hashable {
        case openAIServiceTierVariant(base: AIModelIdentity, tier: String)
        case openrouterCustom(name: String)
        case openaiCustom(name: String)
        case openaiCustomResponses(name: String)
        case openaiCustomReasoning(name: String, effort: CodexReasoningEffort)
        case anthropicCustom(name: String)
        case geminiCustom(name: String)
        case deepseekCustom(name: String)
        case fireworksCustom(name: String)
        case azureCustom(name: String)
        case grokCustom(name: String)
        case groqCustom(name: String)
        case zaiCustom(name: String)
        case codexCustom(name: String)
        case openCodeCustom(name: String)
        case cursorCustom(name: String)
        case customProvider(name: String, provider: String, model: String)
        case customProviderUser(name: String)
        case claudeCodeModel(normalizedSpecifier: String)
        case staticCase(StaticIdentity)
    }

    private enum StaticIdentity: Hashable {
        case gpt41
        case gpt5
        case gpt5Low
        case gpt5High
        case gpt5XHigh
        case gpt54
        case gpt54Low
        case gpt54High
        case gpt54XHigh
        case gpt54Mini
        case gpt54MiniLow
        case gpt54MiniHigh
        case gpt54MiniXHigh
        case gpt54Nano
        case gpt5CodexLow
        case gpt5CodexMed
        case gpt5CodexHigh
        case gpt5CodexXHigh
        case codexCliGpt56SolLow
        case codexCliGpt56SolMedium
        case codexCliGpt56SolHigh
        case codexCliGpt56SolXHigh
        case codexCliGpt56SolMax
        case codexCliGpt56SolUltra
        case codexCliGpt56TerraLow
        case codexCliGpt56TerraMedium
        case codexCliGpt56TerraHigh
        case codexCliGpt56TerraXHigh
        case codexCliGpt56TerraMax
        case codexCliGpt56TerraUltra
        case codexCliGpt56LunaLow
        case codexCliGpt56LunaMedium
        case codexCliGpt56LunaHigh
        case codexCliGpt56LunaXHigh
        case codexCliGpt56LunaMax
        case codexCliGpt5Low
        case codexCliGpt5Medium
        case codexCliGpt5High
        case codexCliGpt5XHigh
        case codexCliGpt54Low
        case codexCliGpt54Medium
        case codexCliGpt54High
        case codexCliGpt54XHigh
        case codexCliGpt5Mini
        case codexCliGpt5CodexLow
        case codexCliGpt5CodexMedium
        case codexCliGpt5CodexHigh
        case codexCliGpt5CodexXHigh
        case codexCliGpt5CodexMini
        case gpt4o
        case o3
        case o1Preview
        case o1Mini
        case gpt5Pro
        case gpt5ProXHigh
        case gpt54Pro
        case gpt54ProXHigh
        case o3Low
        case o3High
        case claude45Haiku
        case claude4Sonnet
        case claude4SonnetThinking
        case claude4SonnetThinkingMax
        case claude4Opus
        case claude4OpusThinking
        case geminiFlashLatest
        case gemini2flashlite
        case geminiProLatest
        case geminiFlash2
        case geminiFlash25
        case geminiFlash25LitePreview
        case geminiFlashThinking
        case geminiPro25
        case gemini3p1ProPreview
        case gemini3FlashPreview
        case deepseekChat
        case deepseekReasoner
        case ollama
        case openrouterDeepseekChat
        case openrouterGpt5
        case openrouterGeminiFlash
        case openrouterGeminiPro
        case openrouterClaude4Sonnet
        case openrouterClaude4Opus
        case openrouterGeminiPro25
        case fireworksDeepseekV3p1Terminus
        case fireworksGLM46
        case fireworksKimiK2Instruct0905
        case fireworksGptOss120b
        case fireworksQwen3235bA22bThinking2507
        case fireworksQwen3Coder480bA35bInstruct
        case fireworksQwen3235bA22bInstruct2507
        case grok40709
        case grokCodeFast1
        case grok4FastReasoning
        case grok4FastNonReasoning
        case groqKimi
        case zaiGLM52
        case zaiGLM5
        case zaiGLM5_0
        case zaiGLM5Turbo
        case zaiGLM47
        case zaiGLM47Flash
        case zaiGLM46
        case zaiGLM45
        case zaiGLM45Air
        case zaiGLM45Flash
        case claudeCode
        case claudeCodeSonnet
        case claudeCodeHaiku
        case claudeCodeOpus
    }

    private var identity: AIModelIdentity {
        switch self {
        case let .openAIServiceTierVariant(base, tier):
            .openAIServiceTierVariant(base: base.identity, tier: tier)
        case let .openrouterCustom(name):
            .openrouterCustom(name: name)
        case let .openaiCustom(name):
            .openaiCustom(name: name)
        case let .openaiCustomResponses(name):
            .openaiCustomResponses(name: name)
        case let .openaiCustomReasoning(name, effort):
            .openaiCustomReasoning(name: name, effort: effort)
        case let .anthropicCustom(name):
            .anthropicCustom(name: name)
        case let .geminiCustom(name):
            .geminiCustom(name: name)
        case let .deepseekCustom(name):
            .deepseekCustom(name: name)
        case let .fireworksCustom(name):
            .fireworksCustom(name: name)
        case let .azureCustom(name):
            .azureCustom(name: name)
        case let .grokCustom(name):
            .grokCustom(name: name)
        case let .groqCustom(name):
            .groqCustom(name: name)
        case let .zaiCustom(name):
            .zaiCustom(name: name)
        case let .codexCustom(name):
            .codexCustom(name: name)
        case let .openCodeCustom(name):
            .openCodeCustom(name: name)
        case let .cursorCustom(name):
            .cursorCustom(name: name)
        case let .customProvider(name, provider, model):
            .customProvider(name: name, provider: provider, model: model)
        case let .customProviderUser(name):
            .customProviderUser(name: name)
        case let .claudeCodeModel(specifier):
            .claudeCodeModel(normalizedSpecifier: ClaudeCodeAIModelCatalog.normalizedSpecifier(specifier))
        case .gpt41:
            .staticCase(.gpt41)
        case .gpt5:
            .staticCase(.gpt5)
        case .gpt5Low:
            .staticCase(.gpt5Low)
        case .gpt5High:
            .staticCase(.gpt5High)
        case .gpt5XHigh:
            .staticCase(.gpt5XHigh)
        case .gpt54:
            .staticCase(.gpt54)
        case .gpt54Low:
            .staticCase(.gpt54Low)
        case .gpt54High:
            .staticCase(.gpt54High)
        case .gpt54XHigh:
            .staticCase(.gpt54XHigh)
        case .gpt54Mini:
            .staticCase(.gpt54Mini)
        case .gpt54MiniLow:
            .staticCase(.gpt54MiniLow)
        case .gpt54MiniHigh:
            .staticCase(.gpt54MiniHigh)
        case .gpt54MiniXHigh:
            .staticCase(.gpt54MiniXHigh)
        case .gpt54Nano:
            .staticCase(.gpt54Nano)
        case .gpt5CodexLow:
            .staticCase(.gpt5CodexLow)
        case .gpt5CodexMed:
            .staticCase(.gpt5CodexMed)
        case .gpt5CodexHigh:
            .staticCase(.gpt5CodexHigh)
        case .gpt5CodexXHigh:
            .staticCase(.gpt5CodexXHigh)
        case .codexCliGpt56SolLow:
            .staticCase(.codexCliGpt56SolLow)
        case .codexCliGpt56SolMedium:
            .staticCase(.codexCliGpt56SolMedium)
        case .codexCliGpt56SolHigh:
            .staticCase(.codexCliGpt56SolHigh)
        case .codexCliGpt56SolXHigh:
            .staticCase(.codexCliGpt56SolXHigh)
        case .codexCliGpt56SolMax:
            .staticCase(.codexCliGpt56SolMax)
        case .codexCliGpt56SolUltra:
            .staticCase(.codexCliGpt56SolUltra)
        case .codexCliGpt56TerraLow:
            .staticCase(.codexCliGpt56TerraLow)
        case .codexCliGpt56TerraMedium:
            .staticCase(.codexCliGpt56TerraMedium)
        case .codexCliGpt56TerraHigh:
            .staticCase(.codexCliGpt56TerraHigh)
        case .codexCliGpt56TerraXHigh:
            .staticCase(.codexCliGpt56TerraXHigh)
        case .codexCliGpt56TerraMax:
            .staticCase(.codexCliGpt56TerraMax)
        case .codexCliGpt56TerraUltra:
            .staticCase(.codexCliGpt56TerraUltra)
        case .codexCliGpt56LunaLow:
            .staticCase(.codexCliGpt56LunaLow)
        case .codexCliGpt56LunaMedium:
            .staticCase(.codexCliGpt56LunaMedium)
        case .codexCliGpt56LunaHigh:
            .staticCase(.codexCliGpt56LunaHigh)
        case .codexCliGpt56LunaXHigh:
            .staticCase(.codexCliGpt56LunaXHigh)
        case .codexCliGpt56LunaMax:
            .staticCase(.codexCliGpt56LunaMax)
        case .codexCliGpt5Low:
            .staticCase(.codexCliGpt5Low)
        case .codexCliGpt5Medium:
            .staticCase(.codexCliGpt5Medium)
        case .codexCliGpt5High:
            .staticCase(.codexCliGpt5High)
        case .codexCliGpt5XHigh:
            .staticCase(.codexCliGpt5XHigh)
        case .codexCliGpt54Low:
            .staticCase(.codexCliGpt54Low)
        case .codexCliGpt54Medium:
            .staticCase(.codexCliGpt54Medium)
        case .codexCliGpt54High:
            .staticCase(.codexCliGpt54High)
        case .codexCliGpt54XHigh:
            .staticCase(.codexCliGpt54XHigh)
        case .codexCliGpt5Mini:
            .staticCase(.codexCliGpt5Mini)
        case .codexCliGpt5CodexLow:
            .staticCase(.codexCliGpt5CodexLow)
        case .codexCliGpt5CodexMedium:
            .staticCase(.codexCliGpt5CodexMedium)
        case .codexCliGpt5CodexHigh:
            .staticCase(.codexCliGpt5CodexHigh)
        case .codexCliGpt5CodexXHigh:
            .staticCase(.codexCliGpt5CodexXHigh)
        case .codexCliGpt5CodexMini:
            .staticCase(.codexCliGpt5CodexMini)
        case .gpt4o:
            .staticCase(.gpt4o)
        case .o3:
            .staticCase(.o3)
        case .o1Preview:
            .staticCase(.o1Preview)
        case .o1Mini:
            .staticCase(.o1Mini)
        case .gpt5Pro:
            .staticCase(.gpt5Pro)
        case .gpt5ProXHigh:
            .staticCase(.gpt5ProXHigh)
        case .gpt54Pro:
            .staticCase(.gpt54Pro)
        case .gpt54ProXHigh:
            .staticCase(.gpt54ProXHigh)
        case .o3Low:
            .staticCase(.o3Low)
        case .o3High:
            .staticCase(.o3High)
        case .claude45Haiku:
            .staticCase(.claude45Haiku)
        case .claude4Sonnet:
            .staticCase(.claude4Sonnet)
        case .claude4SonnetThinking:
            .staticCase(.claude4SonnetThinking)
        case .claude4SonnetThinkingMax:
            .staticCase(.claude4SonnetThinkingMax)
        case .claude4Opus:
            .staticCase(.claude4Opus)
        case .claude4OpusThinking:
            .staticCase(.claude4OpusThinking)
        case .geminiFlashLatest:
            .staticCase(.geminiFlashLatest)
        case .gemini2flashlite:
            .staticCase(.gemini2flashlite)
        case .geminiProLatest:
            .staticCase(.geminiProLatest)
        case .geminiFlash2:
            .staticCase(.geminiFlash2)
        case .geminiFlash25:
            .staticCase(.geminiFlash25)
        case .geminiFlash25LitePreview:
            .staticCase(.geminiFlash25LitePreview)
        case .geminiFlashThinking:
            .staticCase(.geminiFlashThinking)
        case .geminiPro25:
            .staticCase(.geminiPro25)
        case .gemini3p1ProPreview:
            .staticCase(.gemini3p1ProPreview)
        case .gemini3FlashPreview:
            .staticCase(.gemini3FlashPreview)
        case .deepseekChat:
            .staticCase(.deepseekChat)
        case .deepseekReasoner:
            .staticCase(.deepseekReasoner)
        case .ollama:
            .staticCase(.ollama)
        case .openrouterDeepseekChat:
            .staticCase(.openrouterDeepseekChat)
        case .openrouterGpt5:
            .staticCase(.openrouterGpt5)
        case .openrouterGeminiFlash:
            .staticCase(.openrouterGeminiFlash)
        case .openrouterGeminiPro:
            .staticCase(.openrouterGeminiPro)
        case .openrouterClaude4Sonnet:
            .staticCase(.openrouterClaude4Sonnet)
        case .openrouterClaude4Opus:
            .staticCase(.openrouterClaude4Opus)
        case .openrouterGeminiPro25:
            .staticCase(.openrouterGeminiPro25)
        case .fireworksDeepseekV3p1Terminus:
            .staticCase(.fireworksDeepseekV3p1Terminus)
        case .fireworksGLM46:
            .staticCase(.fireworksGLM46)
        case .fireworksKimiK2Instruct0905:
            .staticCase(.fireworksKimiK2Instruct0905)
        case .fireworksGptOss120b:
            .staticCase(.fireworksGptOss120b)
        case .fireworksQwen3235bA22bThinking2507:
            .staticCase(.fireworksQwen3235bA22bThinking2507)
        case .fireworksQwen3Coder480bA35bInstruct:
            .staticCase(.fireworksQwen3Coder480bA35bInstruct)
        case .fireworksQwen3235bA22bInstruct2507:
            .staticCase(.fireworksQwen3235bA22bInstruct2507)
        case .grok40709:
            .staticCase(.grok40709)
        case .grokCodeFast1:
            .staticCase(.grokCodeFast1)
        case .grok4FastReasoning:
            .staticCase(.grok4FastReasoning)
        case .grok4FastNonReasoning:
            .staticCase(.grok4FastNonReasoning)
        case .groqKimi:
            .staticCase(.groqKimi)
        case .zaiGLM52:
            .staticCase(.zaiGLM52)
        case .zaiGLM5:
            .staticCase(.zaiGLM5)
        case .zaiGLM5_0:
            .staticCase(.zaiGLM5_0)
        case .zaiGLM5Turbo:
            .staticCase(.zaiGLM5Turbo)
        case .zaiGLM47:
            .staticCase(.zaiGLM47)
        case .zaiGLM47Flash:
            .staticCase(.zaiGLM47Flash)
        case .zaiGLM46:
            .staticCase(.zaiGLM46)
        case .zaiGLM45:
            .staticCase(.zaiGLM45)
        case .zaiGLM45Air:
            .staticCase(.zaiGLM45Air)
        case .zaiGLM45Flash:
            .staticCase(.zaiGLM45Flash)
        case .claudeCode:
            .staticCase(.claudeCode)
        case .claudeCodeSonnet:
            .staticCase(.claudeCodeSonnet)
        case .claudeCodeHaiku:
            .staticCase(.claudeCodeHaiku)
        case .claudeCodeOpus:
            .staticCase(.claudeCodeOpus)
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
    }

    public static func == (lhs: AIModel, rhs: AIModel) -> Bool {
        lhs.identity == rhs.identity
    }

    // MARK: - Max Tokens ------------------------------------------------

    /// Optional per-model max tokens.
    /// Returns `nil` when the provider default should be used.
    var maxTokens: Int? {
        switch self {
        // Fireworks models with specific max tokens
        case .fireworksDeepseekV3p1Terminus:
            20480
        case .fireworksGLM46:
            25344
        case .fireworksKimiK2Instruct0905:
            32768
        case .fireworksGptOss120b:
            16384
        case .fireworksQwen3235bA22bThinking2507:
            32768
        case .fireworksQwen3Coder480bA35bInstruct:
            32768
        case .fireworksQwen3235bA22bInstruct2507:
            32768
        default:
            nil
        }
    }

    // MARK: - Default Temperature ------------------------------------------------

    /// Optional per-model default temperature.
    /// Returns `nil` when the global app temperature should be used.
    var defaultTemperature: Double? {
        switch self {
        // Gemini Pro 2.5
        case .geminiPro25, .openrouterGeminiPro25:
            0.7
        // DeepSeek R1
        case .deepseekReasoner:
            0.6
        // DeepSeek V3p1 Terminus
        case .fireworksDeepseekV3p1Terminus:
            0.6
        // GLM-4.6
        case .fireworksGLM46:
            0.6
        // Kimi K2 Instruct 0905
        case .fireworksKimiK2Instruct0905:
            0.6
        // OpenAI gpt-oss-120b
        case .fireworksGptOss120b:
            0.6
        // Qwen3 235B A22B Thinking 2507
        case .fireworksQwen3235bA22bThinking2507:
            0.6
        // Qwen3 Coder 480B A35B Instruct
        case .fireworksQwen3Coder480bA35bInstruct:
            0.6
        // Qwen3 235B A22B Instruct 2507
        case .fireworksQwen3235bA22bInstruct2507:
            0.6
        default:
            nil
        }
    }

    /// Resolves the actual temperature that will be used for this model,
    /// taking into account overrides, explicit values, and model defaults.
    /// Returns nil when the temperature is not determinable (e.g., API uses its own default).
    /// - Parameters:
    ///   - explicitTemperature: Optional explicit temperature (e.g., from benchmark settings)
    ///   - includeOverrides: Whether per-model overrides should be considered (default: true)
    /// - Returns: The resolved temperature value, or nil if unknown
    func resolveTemperature(explicitTemperature: Double? = nil, includeOverrides: Bool = true) -> Double? {
        // 1. Per-model override from settings
        if includeOverrides,
           let override = ModelOverridesSettings.shared.temperatureOverride(for: rawValue)
        {
            return override
        }

        // 2. Explicit temperature passed in (e.g., benchmark override)
        if let explicit = explicitTemperature, explicit > 0.0 {
            return explicit
        }

        // 3. Model-specific default
        if let modelDefault = defaultTemperature {
            return modelDefault
        }

        // 4. Provider-specific behavior when effectiveTemperature returns nil
        switch providerType {
        case .anthropic:
            // AnthropicProvider explicitly sets temperature = 0 if not overridden (line 102 in AnthropicProvider.swift)
            return 0.0
        case .customProvider:
            // CustomProviderConfiguration uses 0.3 as default (line 10 in CustomProviderConfiguration.swift)
            return 0.3
        case .openAI, .azure, .openRouter, .gemini, .deepseek, .fireworks, .grok, .groq, .zAI, .claudeCode, .codex, .ollama, .openCode, .cursor:
            // These providers don't set temperature when nil - API uses its own default (typically 1.0)
            // But we can't be certain what the API actually used
            return nil
        }
    }
}
