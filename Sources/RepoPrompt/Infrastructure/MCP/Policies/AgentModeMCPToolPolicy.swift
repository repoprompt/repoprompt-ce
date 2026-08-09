import Foundation
import RepoPromptDomainRuntime

/// App provider-kind adapter over the canonical domain-runtime client policy.
enum AgentModeMCPToolPolicy {
    static let restrictedCapabilities = MCPClientToolPolicyCatalog.agentModeRestrictedCapabilities
    static let restrictedTools = MCPToolCapabilities.toolNames(for: restrictedCapabilities)

    static let grantedCapabilities = MCPClientToolPolicyCatalog
        .classification(for: .agentModeGenericEngineer)
        .grantedCapabilities
    static let grantedTools = MCPToolCapabilities.toolNames(for: grantedCapabilities)

    static let claudeNativeGrantedCapabilities = MCPClientToolPolicyCatalog
        .classification(for: .agentModeClaudeEngineer)
        .grantedCapabilities
    static let claudeNativeGrantedTools = MCPToolCapabilities.toolNames(for: claudeNativeGrantedCapabilities)

    static let codexNativeGrantedCapabilities = MCPClientToolPolicyCatalog
        .classification(for: .agentModeCodexEngineer)
        .grantedCapabilities
    static let codexNativeGrantedTools = MCPToolCapabilities.toolNames(for: codexNativeGrantedCapabilities)

    static let openCodeGrantedCapabilities = MCPClientToolPolicyCatalog
        .classification(for: .agentModeOpenCodeEngineer)
        .grantedCapabilities
    static let openCodeGrantedTools = MCPToolCapabilities.toolNames(for: openCodeGrantedCapabilities)

    static let cursorGrantedCapabilities = MCPClientToolPolicyCatalog
        .classification(for: .agentModeCursorEngineer)
        .grantedCapabilities
    static let cursorGrantedTools = MCPToolCapabilities.toolNames(for: cursorGrantedCapabilities)

    static func grantedTools(forAgent agent: AgentProviderKind) -> Set<String> {
        switch agent {
        case .codexExec:
            codexNativeGrantedTools
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            claudeNativeGrantedTools
        case .openCode:
            openCodeGrantedTools
        case .cursor:
            cursorGrantedTools
        }
    }
}
