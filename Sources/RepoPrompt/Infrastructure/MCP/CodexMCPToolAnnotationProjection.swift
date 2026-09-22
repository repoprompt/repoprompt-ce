import MCP
import RepoPromptDomainRuntime

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
        let profile: MCPClientToolAnnotationProfile =
            MCPClientIdentity.canonicalFamilyID(clientIdentifier) == "codex-mcp-client"
                ? .suppressReadOnlyHint
                : .canonical
        let domain = MCPDomainToolAnnotations(
            title: canonical.title,
            readOnlyHint: canonical.readOnlyHint,
            destructiveHint: canonical.destructiveHint,
            idempotentHint: canonical.idempotentHint,
            openWorldHint: canonical.openWorldHint
        ).projected(for: profile)
        return domain.mcpAnnotations
    }
}
