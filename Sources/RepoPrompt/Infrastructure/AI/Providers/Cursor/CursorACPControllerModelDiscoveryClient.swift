import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts

struct CursorACPControllerModelDiscoveryClient: CursorACPModelDiscoveryClient {
    typealias ProviderFactory = @Sendable (_ agent: AgentProviderKind, _ modelString: String?) async throws -> (any ACPAgentProvider)?
    typealias ControllerFactory = @Sendable (_ provider: any ACPAgentProvider, _ runRequest: ACPRunRequest) throws -> ACPAgentSessionController

    private let providerFactory: ProviderFactory
    private let controllerFactory: ControllerFactory

    init(
        providerFactory: @escaping ProviderFactory = { agent, modelString in
            if agent == .cursor {
                return Self.makeCursorProvider(modelString: modelString)
            }
            return try await ACPAgentProviderFactory.makeProvider(for: agent, modelString: modelString)
        },
        controllerFactory: @escaping ControllerFactory = { provider, runRequest in
            try ACPAgentSessionController(provider: provider, runRequest: runRequest)
        }
    ) {
        self.providerFactory = providerFactory
        self.controllerFactory = controllerFactory
    }

    #if DEBUG
        static func test_makeCursorProvider(modelString: String?) -> CursorACPAgentProvider {
            makeCursorProvider(modelString: modelString)
        }
    #endif

    private static func makeCursorProvider(modelString: String?) -> CursorACPAgentProvider {
        CursorACPAgentProvider(
            config: CursorAgentConfig(
                enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                modelString: modelString,
                includeRepoPromptMCPServer: false,
                cleanupProjectMCPApproval: false
            )
        )
    }

    func discoverModels(workspacePath: String?) async throws -> ACPDiscoveredSessionModels? {
        let preferredModel = AgentModel.cursorAuto.rawValue
        let request = ACPRunRequest(
            agentKind: .cursor,
            modelString: preferredModel,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        guard let provider = try await providerFactory(.cursor, preferredModel) else { return nil }
        let support = try await provider.support(for: request)
        guard support == .supported else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "Cursor ACP is not available."
            )
        }

        let controller = try controllerFactory(provider, request)
        do {
            _ = try await controller.bootstrap()
            let snapshot = try await controller.cursorAvailableModelCatalog()
            await controller.shutdown()
            return snapshot
        } catch {
            await controller.shutdown()
            throw error
        }
    }
}
