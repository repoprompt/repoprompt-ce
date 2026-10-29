import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts

/// Discovery client that reuses one verified Grok session in a neutral directory so
/// 5-minute polling does not accumulate persistent sessions under `~/.grok/sessions`.
/// `session/load` returns fresh `models` metadata on grok 1.0.3, so load-based discovery
/// observes remote catalog changes.
actor GrokBuildACPControllerModelDiscoveryClient: GrokBuildACPModelDiscoveryClient {
    typealias ProviderFactory = @Sendable (_ config: GrokBuildAgentConfig) async throws -> (any ACPAgentProvider)?
    typealias ControllerFactory = @Sendable (_ provider: any ACPAgentProvider, _ runRequest: ACPRunRequest) throws -> ACPAgentSessionController

    private let providerFactory: ProviderFactory
    private let controllerFactory: ControllerFactory
    private var retainedSessionID: String?

    init(
        providerFactory: @escaping ProviderFactory = { config in
            // Keep credential lookup inside the default factory so injected factories
            // can observe discovery routing without touching secure storage.
            try await GrokBuildACPAgentProvider(
                config: GrokBuildAgentConfig(
                    commandName: config.commandName,
                    additionalPathHints: config.additionalPathHints,
                    enableDebugLogging: config.enableDebugLogging,
                    modelString: config.modelString,
                    includeRepoPromptMCPServer: config.includeRepoPromptMCPServer,
                    alwaysApproveTools: config.alwaysApproveTools,
                    apiKey: KeyManager().getAPIKey(for: .grok),
                    backgroundFeatureEnvironment: config.backgroundFeatureEnvironment
                )
            )
        },
        controllerFactory: @escaping ControllerFactory = { provider, runRequest in
            try ACPAgentSessionController(provider: provider, runRequest: runRequest)
        }
    ) {
        self.providerFactory = providerFactory
        self.controllerFactory = controllerFactory
    }

    func discoverModels(workspacePath _: String?) async throws -> ACPDiscoveredSessionModels? {
        // Catalog discovery does not need the user's project. Keep project .mcp.json and
        // project-local Cursor imports out of polling, without changing HOME/GROK_HOME.
        let request = ACPRunRequest(
            agentKind: .grokBuild,
            modelString: nil,
            workspacePath: Self.stableDiscoveryWorkspacePath(),
            resumeSessionID: retainedSessionID,
            attachments: [],
            taskLabelKind: nil
        )
        // Polling every 300s must not spawn tool servers for nothing.
        let config = GrokBuildAgentConfig(
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            includeRepoPromptMCPServer: false,
            backgroundFeatureEnvironment: GrokBuildAgentConfig.managedBackgroundFeatureEnvironment
        )
        guard let provider = try await providerFactory(config) else { return nil }
        let support = try await provider.support(for: request)
        guard support == .supported else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "Grok Build ACP is not available."
            )
        }

        let controller = try controllerFactory(provider, request)
        do {
            _ = try await controller.bootstrap()
            await retainVerifiedIdentity(controller.currentProviderSessionIdentity())
            let snapshot = AgentACPModelRegistry.shared.currentSnapshot(for: .grokBuild)
            await controller.shutdown()
            return snapshot
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    private func retainVerifiedIdentity(_ identity: ACPProviderSessionIdentity) {
        // Only verified load IDs may be retained; a candidate ID would defeat the
        // controller's load→new recovery contract.
        guard identity.loadSessionIDConfidence == .verified,
              let loadID = identity.loadSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !loadID.isEmpty
        else {
            return
        }
        // On a load→new recovery the verified identity is the fresh session, so this
        // assignment also replaces an invalidated retained ID.
        retainedSessionID = loadID
    }

    /// One stable provider-specific directory for discovery so repeated
    /// polls reuse the same retained session instead of leaking `~/.grok/sessions` entries.
    private static func stableDiscoveryWorkspacePath() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptGrokBuildACPDiscovery", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url.standardizedFileURL.path
    }
}
