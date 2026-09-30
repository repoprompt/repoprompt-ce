/// Classifies selectable agents by their external-MCP runtime family only. This does not
/// transfer credentials, proof, or runtime-binding authority between agent variants.
extension AgentProviderKind {
    var externalMCPRuntimeProvider: ExternalMCPRuntimeProvider {
        switch self {
        case .codexExec: .codex
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible: .claudeCode
        case .openCode: .openCode
        case .cursor: .cursor
        case .grokBuild: .grokBuild
        case .devin: .devin
        case .antigravity: .antigravity
        }
    }
}
