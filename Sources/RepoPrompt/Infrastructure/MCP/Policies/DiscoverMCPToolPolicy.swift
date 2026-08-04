import Foundation
import RepoPromptDomainRuntime

/// App compatibility policy for Context Builder discovery runs.
enum DiscoverMCPToolPolicy {
    static let restrictedCapabilities = MCPClientToolPolicyCatalog
        .classification(for: .discovery)
        .restrictedCapabilities
    static let restrictedTools = MCPToolCapabilities.toolNames(for: restrictedCapabilities)
    static let grantedCapabilities = MCPClientToolPolicyCatalog
        .classification(for: .discovery)
        .grantedCapabilities
    static let grantedTools = MCPToolCapabilities.toolNames(for: grantedCapabilities)
}
