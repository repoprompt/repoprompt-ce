import Foundation

enum AgentProviderBindingID: String, CaseIterable, Hashable {
    case codex
    case claude
    case openCode
    case cursor
    case grokBuild
    case antigravity
    case omp

    var displayName: String {
        switch self {
        case .codex:
            "Codex CLI"
        case .claude:
            "Claude Code"
        case .openCode:
            "OpenCode"
        case .cursor:
            "Cursor CLI"
        case .grokBuild:
            "Grok Build"
        case .antigravity:
            "Google Antigravity"
        case .omp:
            "Oh My Pi"
        }
    }
}

extension AgentProviderKind {
    var providerBindingID: AgentProviderBindingID {
        switch self {
        case .codexExec:
            .codex
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            .claude
        case .openCode:
            .openCode
        case .cursor:
            .cursor
        case .grokBuild:
            .grokBuild
        case .antigravity:
            .antigravity
        case .omp:
            .omp
        }
    }
}
