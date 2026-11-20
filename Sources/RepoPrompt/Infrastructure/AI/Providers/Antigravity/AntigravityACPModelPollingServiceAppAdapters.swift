import RepoPromptACPProviders

extension AntigravityACPModelPollingService {
    static let shared = AntigravityACPModelPollingService(
        client: AntigravityACPControllerModelDiscoveryClient(),
        registry: AgentModelCatalogRuntime.shared.acpRegistry,
        logFailure: { message in
            if AgentRuntimeProviderService.enableDebugLogging {
                print("[AntigravityACPModelPolling] refresh failed: \(message)")
            }
        }
    )
}
