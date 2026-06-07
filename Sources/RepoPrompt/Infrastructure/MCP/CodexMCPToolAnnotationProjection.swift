import MCP

/// Connection-specific MCP tool metadata adjustments for Codex compatibility.
///
/// Canonical RepoPrompt tool annotations remain truthful. Only the `tools/list`
/// wire projection for positively identified Codex clients omits `readOnlyHint`
/// so Codex does not infer that RepoPrompt tools are safe to call in parallel.
enum CodexMCPToolAnnotationProjection {
    static func project(
        _ canonical: MCP.Tool.Annotations,
        clientIdentifier: String?
    ) -> MCP.Tool.Annotations {
        guard MCPClientIdentity.canonicalFamilyID(clientIdentifier) == "codex-mcp-client" else {
            return canonical
        }

        var projected = canonical
        projected.readOnlyHint = nil
        return projected
    }
}
