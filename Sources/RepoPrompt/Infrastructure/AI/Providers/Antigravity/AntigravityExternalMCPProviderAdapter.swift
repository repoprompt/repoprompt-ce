/// Antigravity's local desktop Figma route does not support this remote MCP endpoint.
struct AntigravityExternalMCPProviderAdapter: ExternalMCPFailClosedProviderAdapter {
    let runtimeProvider: ExternalMCPRuntimeProvider = .antigravity
}
