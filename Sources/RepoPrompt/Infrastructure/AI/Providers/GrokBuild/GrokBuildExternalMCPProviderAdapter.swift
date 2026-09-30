import Foundation

/// Grok Build has no verified CE-owned external-MCP auth, home isolation, or cleanup contract.
/// Keep the provider explicitly present in static composition while denying every operation.
struct GrokBuildExternalMCPProviderAdapter: ExternalMCPFailClosedProviderAdapter {
    let runtimeProvider: ExternalMCPRuntimeProvider = .grokBuild
}
