import Foundation

package enum AIProviderType: Codable, Equatable {
    case anthropic
    case openAI
    case ollama
    case azure
    case openRouter
    case gemini
    case deepseek // <-- New deepseek provider case
    case customProvider
    case fireworks // <-- New fireworks provider case
    case grok // <-- New grok provider case
    case groq // <-- New groq provider case
    case zAI // <-- New Z.AI provider case
    case claudeCode // <-- New Claude Code provider case
    case codex // <-- New Codex CLI provider case
    case openCode // OpenCode CLI provider case
    case cursor // Cursor CLI provider case
    case grokBuild // Grok Build CLI provider case
    case devin
}
