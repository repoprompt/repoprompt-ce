import Foundation

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

    // GPT-6 family (OpenAI Responses API)
    case gpt61Sol
    case gpt61SolLow
    case gpt61SolHigh
    case gpt61SolXHigh
    case gpt61SolMax
    case gpt61Terra
    case gpt61TerraNone
    case gpt61TerraLow
    case gpt61TerraHigh
    case gpt61TerraXHigh
    case gpt61TerraMax
    case gpt6Astra
    case gpt6AstraLow
    case gpt6AstraHigh
    case gpt6AstraXHigh
    case gpt6AstraMax
    case gpt6AstraPro
    case gpt6AstraProLow
    case gpt6AstraProHigh
    case gpt6AstraProXHigh
    case gpt6AstraProMax
    case gpt6Luna
    case gpt6LunaLow
    case gpt6LunaHigh
    case gpt6LunaXHigh
    case gpt6Sol

    case gpt5CodexLow
    case gpt5CodexMed
    case gpt5CodexHigh
    case gpt5CodexXHigh

    // Codex CLI Provider Models
    case codexCliGpt61SolLow
    case codexCliGpt61SolMedium
    case codexCliGpt61SolHigh
    case codexCliGpt61SolXHigh
    case codexCliGpt61SolMax
    case codexCliGpt61SolUltra
    case codexCliGpt6AstraLow
    case codexCliGpt6AstraMedium
    case codexCliGpt6AstraHigh
    case codexCliGpt6AstraXHigh
    case codexCliGpt6AstraMax
    case codexCliGpt6LunaLow
    case codexCliGpt6LunaMedium
    case codexCliGpt6LunaHigh
    case codexCliGpt6LunaXHigh
    case codexCliGpt6LunaMax
    case codexCliGpt6SolLow
    case codexCliGpt6SolMedium
    case codexCliGpt6SolHigh
    case codexCliGpt6SolXHigh
    case codexCliGpt6SolMax
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
    case claudeSonnet55
    case claudeSonnet5
    case claudeOpus55
    case claudeOpus5
    case claudeFable51
    case claudeMythos51
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
    case openrouterGpt61Sol
    case openrouterGpt6Astra
    case openrouterGpt6Luna
    case openrouterClaudeSonnet55
    case openrouterClaudeOpus55
    case openrouterClaudeFable51

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
    case grokBuildCustom(name: String)
    case devinCustom(name: String)

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
        case grokBuildCustom(name: String)
        case devinCustom(name: String)
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
        case gpt61Sol
        case gpt61SolLow
        case gpt61SolHigh
        case gpt61SolXHigh
        case gpt61SolMax
        case gpt61Terra
        case gpt61TerraNone
        case gpt61TerraLow
        case gpt61TerraHigh
        case gpt61TerraXHigh
        case gpt61TerraMax
        case gpt6Astra
        case gpt6AstraLow
        case gpt6AstraHigh
        case gpt6AstraXHigh
        case gpt6AstraMax
        case gpt6AstraPro
        case gpt6AstraProLow
        case gpt6AstraProHigh
        case gpt6AstraProXHigh
        case gpt6AstraProMax
        case gpt6Luna
        case gpt6LunaLow
        case gpt6LunaHigh
        case gpt6LunaXHigh
        case gpt6Sol
        case gpt5CodexLow
        case gpt5CodexMed
        case gpt5CodexHigh
        case gpt5CodexXHigh
        case codexCliGpt61SolLow
        case codexCliGpt61SolMedium
        case codexCliGpt61SolHigh
        case codexCliGpt61SolXHigh
        case codexCliGpt61SolMax
        case codexCliGpt61SolUltra
        case codexCliGpt6AstraLow
        case codexCliGpt6AstraMedium
        case codexCliGpt6AstraHigh
        case codexCliGpt6AstraXHigh
        case codexCliGpt6AstraMax
        case codexCliGpt6LunaLow
        case codexCliGpt6LunaMedium
        case codexCliGpt6LunaHigh
        case codexCliGpt6LunaXHigh
        case codexCliGpt6LunaMax
        case codexCliGpt6SolLow
        case codexCliGpt6SolMedium
        case codexCliGpt6SolHigh
        case codexCliGpt6SolXHigh
        case codexCliGpt6SolMax
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
        case claudeSonnet55
        case claudeSonnet5
        case claudeOpus55
        case claudeOpus5
        case claudeFable51
        case claudeMythos51
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
        case openrouterGpt61Sol
        case openrouterGpt6Astra
        case openrouterGpt6Luna
        case openrouterClaudeSonnet55
        case openrouterClaudeOpus55
        case openrouterClaudeFable51
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
        case let .grokBuildCustom(name):
            .grokBuildCustom(name: name)
        case let .devinCustom(name):
            .devinCustom(name: name)
        case let .customProvider(name, provider, model):
            .customProvider(name: name, provider: provider, model: model)
        case let .customProviderUser(name):
            .customProviderUser(name: name)
        case let .claudeCodeModel(specifier):
            .claudeCodeModel(normalizedSpecifier: normalizedClaudeCodeModelIdentitySpecifier(specifier))
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
        case .gpt61Sol:
            .staticCase(.gpt61Sol)
        case .gpt61SolLow:
            .staticCase(.gpt61SolLow)
        case .gpt61SolHigh:
            .staticCase(.gpt61SolHigh)
        case .gpt61SolXHigh:
            .staticCase(.gpt61SolXHigh)
        case .gpt61SolMax:
            .staticCase(.gpt61SolMax)
        case .gpt61Terra:
            .staticCase(.gpt61Terra)
        case .gpt61TerraNone:
            .staticCase(.gpt61TerraNone)
        case .gpt61TerraLow:
            .staticCase(.gpt61TerraLow)
        case .gpt61TerraHigh:
            .staticCase(.gpt61TerraHigh)
        case .gpt61TerraXHigh:
            .staticCase(.gpt61TerraXHigh)
        case .gpt61TerraMax:
            .staticCase(.gpt61TerraMax)
        case .gpt6Astra:
            .staticCase(.gpt6Astra)
        case .gpt6AstraLow:
            .staticCase(.gpt6AstraLow)
        case .gpt6AstraHigh:
            .staticCase(.gpt6AstraHigh)
        case .gpt6AstraXHigh:
            .staticCase(.gpt6AstraXHigh)
        case .gpt6AstraMax:
            .staticCase(.gpt6AstraMax)
        case .gpt6AstraPro:
            .staticCase(.gpt6AstraPro)
        case .gpt6AstraProLow:
            .staticCase(.gpt6AstraProLow)
        case .gpt6AstraProHigh:
            .staticCase(.gpt6AstraProHigh)
        case .gpt6AstraProXHigh:
            .staticCase(.gpt6AstraProXHigh)
        case .gpt6AstraProMax:
            .staticCase(.gpt6AstraProMax)
        case .gpt6Luna:
            .staticCase(.gpt6Luna)
        case .gpt6LunaLow:
            .staticCase(.gpt6LunaLow)
        case .gpt6LunaHigh:
            .staticCase(.gpt6LunaHigh)
        case .gpt6LunaXHigh:
            .staticCase(.gpt6LunaXHigh)
        case .gpt6Sol:
            .staticCase(.gpt6Sol)
        case .gpt5CodexLow:
            .staticCase(.gpt5CodexLow)
        case .gpt5CodexMed:
            .staticCase(.gpt5CodexMed)
        case .gpt5CodexHigh:
            .staticCase(.gpt5CodexHigh)
        case .gpt5CodexXHigh:
            .staticCase(.gpt5CodexXHigh)
        case .codexCliGpt61SolLow:
            .staticCase(.codexCliGpt61SolLow)
        case .codexCliGpt61SolMedium:
            .staticCase(.codexCliGpt61SolMedium)
        case .codexCliGpt61SolHigh:
            .staticCase(.codexCliGpt61SolHigh)
        case .codexCliGpt61SolXHigh:
            .staticCase(.codexCliGpt61SolXHigh)
        case .codexCliGpt61SolMax:
            .staticCase(.codexCliGpt61SolMax)
        case .codexCliGpt61SolUltra:
            .staticCase(.codexCliGpt61SolUltra)
        case .codexCliGpt6AstraLow:
            .staticCase(.codexCliGpt6AstraLow)
        case .codexCliGpt6AstraMedium:
            .staticCase(.codexCliGpt6AstraMedium)
        case .codexCliGpt6AstraHigh:
            .staticCase(.codexCliGpt6AstraHigh)
        case .codexCliGpt6AstraXHigh:
            .staticCase(.codexCliGpt6AstraXHigh)
        case .codexCliGpt6AstraMax:
            .staticCase(.codexCliGpt6AstraMax)
        case .codexCliGpt6LunaLow:
            .staticCase(.codexCliGpt6LunaLow)
        case .codexCliGpt6LunaMedium:
            .staticCase(.codexCliGpt6LunaMedium)
        case .codexCliGpt6LunaHigh:
            .staticCase(.codexCliGpt6LunaHigh)
        case .codexCliGpt6LunaXHigh:
            .staticCase(.codexCliGpt6LunaXHigh)
        case .codexCliGpt6LunaMax:
            .staticCase(.codexCliGpt6LunaMax)
        case .codexCliGpt6SolLow:
            .staticCase(.codexCliGpt6SolLow)
        case .codexCliGpt6SolMedium:
            .staticCase(.codexCliGpt6SolMedium)
        case .codexCliGpt6SolHigh:
            .staticCase(.codexCliGpt6SolHigh)
        case .codexCliGpt6SolXHigh:
            .staticCase(.codexCliGpt6SolXHigh)
        case .codexCliGpt6SolMax:
            .staticCase(.codexCliGpt6SolMax)
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
        case .claudeSonnet55:
            .staticCase(.claudeSonnet55)
        case .claudeSonnet5:
            .staticCase(.claudeSonnet5)
        case .claudeOpus55:
            .staticCase(.claudeOpus55)
        case .claudeOpus5:
            .staticCase(.claudeOpus5)
        case .claudeFable51:
            .staticCase(.claudeFable51)
        case .claudeMythos51:
            .staticCase(.claudeMythos51)
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
        case .openrouterGpt61Sol:
            .staticCase(.openrouterGpt61Sol)
        case .openrouterGpt6Astra:
            .staticCase(.openrouterGpt6Astra)
        case .openrouterGpt6Luna:
            .staticCase(.openrouterGpt6Luna)
        case .openrouterClaudeSonnet55:
            .staticCase(.openrouterClaudeSonnet55)
        case .openrouterClaudeOpus55:
            .staticCase(.openrouterClaudeOpus55)
        case .openrouterClaudeFable51:
            .staticCase(.openrouterClaudeFable51)
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
}
