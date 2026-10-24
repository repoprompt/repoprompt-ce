import RepoPromptDomainRuntime

/// Route admission for Oracle image attachments. This gates *transport capability*: whether
/// the provider implementation provably serializes `transientImages` onto the wire, not
/// whether the selected model accepts image input (models without vision return a normal
/// provider error).
///
/// Verified transports:
/// - `anthropic` → `AnthropicProvider.makeMessages` emits image blocks.
/// - `openAI` and every `OpenAIProvider` subclass (`ollama`, `azure`, `openRouter`, `gemini`,
///   `deepseek`, `customProvider`, `fireworks`, `grok`, `groq`, `zAI`) →
///   `AIMessage.openAIChatMessages` / `openAIResponsesInput` emit image parts.
/// - `claudeCode` → stream-json stdin via `ClaudeCodeProvider.makeStreamJSONInput`.
/// - `codex` → staged image attachments via `OracleTransientImageStaging`.
/// - `openCode` / `cursor` / `devin` → ACP image blocks via `ACPPromptContentBuilder`.
///
/// Not admitted: `grokBuild` (advertises `promptCapabilities.image = false` over ACP, and its
/// one-shot prompt-file CLI exposes no attachment channel).
enum OracleImageRouteAdmission {
    static func supports(_ model: AIModel) -> Bool {
        switch model.providerType {
        case .anthropic,
             .openAI,
             .ollama,
             .azure,
             .openRouter,
             .gemini,
             .deepseek,
             .customProvider,
             .fireworks,
             .grok,
             .groq,
             .zAI,
             .claudeCode,
             .codex,
             .openCode,
             .cursor,
             .devin:
            true
        case .grokBuild:
            false
        }
    }
}
