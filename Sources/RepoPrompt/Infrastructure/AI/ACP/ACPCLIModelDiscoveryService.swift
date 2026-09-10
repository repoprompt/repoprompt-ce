import Foundation

/// Connect-time model discovery for ACP CLI providers whose catalog is only advertised by a
/// live session. One throwaway session is bootstrapped so `AgentACPModelRegistry` (and the
/// pickers reading it) are populated before the first real run instead of after it.
///
/// Discovery never injects the RepoPrompt MCP server and never sets a model: a session that
/// exists only to read `session/new` metadata must not spawn tool servers or mutate state.
/// Grok Build is intentionally absent — it owns a polling service with session reuse.
enum ACPCLIModelDiscoveryService {
    static func discoverModels(
        for agentKind: AgentProviderKind,
        workspacePath: String? = nil
    ) async throws -> ACPDiscoveredSessionModels? {
        guard let providerID = agentKind.acpProviderID,
              let provider = discoveryProvider(for: agentKind)
        else {
            return nil
        }

        let request = ACPRunRequest(
            agentKind: agentKind,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let support = try await provider.support(for: request)
        guard support == .supported else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "Installed CLI does not support ACP mode."
            )
        }

        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        do {
            _ = try await controller.bootstrap()
            // The controller publishes advertised models into the registry during bootstrap.
            let snapshot = AgentACPModelRegistry.shared.currentSnapshot(for: providerID)
            await controller.shutdown()
            return snapshot
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    private static func discoveryProvider(for agentKind: AgentProviderKind) -> (any ACPAgentProvider)? {
        switch agentKind {
        case .omp:
            OMPACPAgentProvider(
                config: OMPAgentConfig(
                    enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                    includeRepoPromptMCPServer: false
                )
            )
        case .devin:
            DevinACPAgentProvider(
                config: DevinAgentConfig(
                    enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                    includeRepoPromptMCPServer: false
                )
            )
        default:
            nil
        }
    }
}
