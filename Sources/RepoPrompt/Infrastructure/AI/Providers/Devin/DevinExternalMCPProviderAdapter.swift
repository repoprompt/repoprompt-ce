/// Devin's remote Figma MCP contract has not passed the login, proof, or revocation gates.
struct DevinExternalMCPProviderAdapter: ExternalMCPFailClosedProviderAdapter {
    let runtimeProvider: ExternalMCPRuntimeProvider = .devin
}
