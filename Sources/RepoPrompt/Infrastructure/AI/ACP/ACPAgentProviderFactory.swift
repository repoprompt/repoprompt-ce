import Foundation

enum ACPAgentProviderFactory {
    static func makeProvider(
        for agentKind: AgentProviderKind,
        modelString: String?
    ) -> (any ACPAgentProvider)? {
        switch agentKind {
        case .openCode:
            OpenCodeACPAgentProvider(
                config: OpenCodeAgentConfig(
                    modelString: modelString,
                    enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                    toolProfile: .agentMode
                )
            )
        case .cursor:
            CursorACPAgentProvider(
                config: CursorAgentConfig(
                    enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                    modelString: modelString
                )
            )
        case .grok:
            GrokACPAgentProvider(
                config: GrokAgentConfig(
                    modelString: modelString,
                    enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging
                )
            )
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .codexExec:
            nil
        }
    }
}
