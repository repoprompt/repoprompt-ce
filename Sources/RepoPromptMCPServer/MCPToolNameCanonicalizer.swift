import Foundation

/// Legacy wire aliases. Canonical tool classification remains owned by the domain catalog.
package enum MCPToolNameCanonicalizer {
    private static let aliases: [String: String] = [
        "discover_manage_selection": "manage_selection",
        "discover_prompt": "prompt",
        "discover_workspace_context": "workspace_context"
    ]

    package static func canonicalToolName(for name: String) -> String {
        aliases[name] ?? name
    }
}
