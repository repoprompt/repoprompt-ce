import Foundation
import RepoPromptDomainRuntime

/// App compatibility policy for tools requiring an explicit per-connection grant.
enum MCPPolicyGatedTools {
    static let gatedCapabilities = MCPClientToolPolicyCatalog.policyGatedCapabilities
    static let names = MCPClientToolPolicyCatalog.policyGatedToolNames
}
