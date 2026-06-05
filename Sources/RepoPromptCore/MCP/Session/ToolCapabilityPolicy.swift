import Foundation

package struct ToolCapability: RawRepresentable, Hashable {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package static let workspaceRead = Self(rawValue: "workspace_read")
    package static let workspaceLifecycle = Self(rawValue: "workspace_lifecycle")
    package static let selection = Self(rawValue: "selection")
    package static let promptContext = Self(rawValue: "prompt_context")
    package static let fileRead = Self(rawValue: "file_read")
    package static let fileWrite = Self(rawValue: "file_write")
    package static let codeStructure = Self(rawValue: "code_structure")
    package static let vcs = Self(rawValue: "vcs")
    package static let oracle = Self(rawValue: "oracle")
    package static let contextBuilder = Self(rawValue: "context_builder")
    package static let userInteraction = Self(rawValue: "user_interaction")
    package static let agentControl = Self(rawValue: "agent_control")
    package static let settings = Self(rawValue: "settings")
    package static let appLifecycle = Self(rawValue: "app_lifecycle")
}

/// Immutable capability projection used both for tool advertisement and pre-invocation checks.
package struct ToolCapabilityPolicy {
    package let grantedCapabilities: Set<ToolCapability>

    package init(grantedCapabilities: Set<ToolCapability>) {
        self.grantedCapabilities = grantedCapabilities
    }

    package func allows(_ capability: ToolCapability) -> Bool {
        grantedCapabilities.contains(capability)
    }

    package func allowsAll(_ capabilities: Set<ToolCapability>) -> Bool {
        capabilities.isSubset(of: grantedCapabilities)
    }
}
