import Foundation

enum DevinACPModelDiscoveryService {
    static func discoverModels(workspacePath: String? = nil) async throws -> ACPDiscoveredSessionModels? {
        let request = ACPRunRequest(
            agentKind: .devin,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let provider = DevinACPAgentProvider(
            config: DevinAgentConfig(
                enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                includeRepoPromptMCPServer: false
            )
        )
        let support = try await provider.support(for: request)
        guard support == .supported else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "Installed Devin CLI does not support ACP mode."
            )
        }

        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        do {
            _ = try await controller.bootstrap()
            let snapshot = AgentACPModelRegistry.shared.currentSnapshot(for: .devin)
            await controller.shutdown()
            return snapshot
        } catch {
            await controller.shutdown()
            throw error
        }
    }
}
