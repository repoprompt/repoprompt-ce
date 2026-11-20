import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptDomainRuntime

package final class DevinACPHeadlessAgentProvider: HeadlessAgentProvider {
    package typealias ProviderFactory = @Sendable (_ config: DevinAgentConfig) -> any ACPAgentProvider
    package typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory

    private let config: DevinAgentConfig
    private let bridge: ACPHeadlessAgentProviderBridge

    package init(
        isDefaultModel: @escaping @Sendable (String) -> Bool,
        config: DevinAgentConfig,
        workspacePath: String? = nil,
        providerFactory: @escaping ProviderFactory,
        controllerFactory: @escaping ControllerFactory
    ) {
        self.config = config
        bridge = ACPHeadlessAgentProviderBridge(
            providerName: "Devin",
            makeProvider: { providerFactory(config) },
            makeRequest: { message, _ in
                Self.makeRunRequest(config: config, workspacePath: workspacePath, message: message)
            },
            makeController: controllerFactory,
            beforePrompt: { controller, request in
                guard let model = request.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !model.isEmpty,
                      !isDefaultModel(model)
                else { return }
                try await controller.setSessionModel(model)
            },
            approvalPolicy: .declineUnsupported
        )
    }

    package static func makeRunRequest(
        config: DevinAgentConfig,
        workspacePath: String?,
        message: AgentMessage
    ) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .devin,
            modelString: config.modelString,
            workspacePath: workspacePath,
            resumeSessionID: message.resumeSessionID,
            attachments: [],
            taskLabelKind: nil,
            launchPermissionMode: config.includeRepoPromptMCPServer ? "auto" : nil
        )
    }

    package func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID? = nil
    ) async throws -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error> {
        try await bridge.streamAgentMessage(message, runID: runID)
    }

    package func dispose() async {
        await bridge.dispose()
    }
}
