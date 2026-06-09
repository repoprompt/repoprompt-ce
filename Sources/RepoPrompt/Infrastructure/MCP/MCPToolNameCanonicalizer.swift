enum MCPToolNameCanonicalizer {
    private static let aliases: [String: String] = [
        "discover_manage_selection": "manage_selection",
        "discover_prompt": "prompt",
        "discover_workspace_context": "workspace_context"
    ]

    static func canonicalName(for name: String) -> String {
        aliases[name] ?? name
    }
}
