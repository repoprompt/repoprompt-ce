import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptSettingsCore

struct OpenCodeACPControllerModelDiscoveryClient: OpenCodeACPModelDiscoveryClient {
    typealias ProviderFactory = @Sendable (_ agent: AgentProviderKind, _ modelString: String?) async throws -> (any ACPAgentProvider)?
    typealias ControllerFactory = @Sendable (_ provider: any ACPAgentProvider, _ runRequest: ACPRunRequest) throws -> ACPAgentSessionController

    private let providerFactory: ProviderFactory
    private let controllerFactory: ControllerFactory

    init(
        providerFactory: @escaping ProviderFactory = { agent, modelString in
            if agent == .openCode {
                return OpenCodeACPAgentProvider(
                    config: OpenCodeAgentConfig(
                        modelString: modelString,
                        enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                        includeRepoPromptMCPServer: false,
                        includeManagedConfigOverlay: true,
                        cleanupLegacyPersistentConfig: true,
                        toolProfile: .noTools
                    )
                )
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

    /// Bootstraps a disposable OpenCode ACP session and returns the bootstrap catalog plus,
    /// when `modelRaw` is non-nil, the parameter outcome for that model.
    ///
    /// The bootstrap catalog is the one published. OpenCode only advertises the
    /// model-scoped `effort` selector *after* a model set, so the parameter probe mutates the
    /// session's current model; substituting that probe session's model list would confuse
    /// "the model we interrogated" with "the provider default" and could lose the model list.
    /// The probe therefore runs in a disposable controller and only its *parameter outcome*
    /// is extracted; the published catalog retains the bootstrap options and bootstrap current.
    func discoverModels(workspacePath: String?, modelRaw: String?) async throws -> OpenCodeACPModelDiscoveryResult? {
        let request = ACPRunRequest(
            agentKind: .openCode,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        guard let provider = try await providerFactory(.openCode, nil) else { return nil }
        let support = try await provider.support(for: request)
        guard support == .supported else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "OpenCode ACP is not available."
            )
        }

        let controller = try controllerFactory(provider, request)
        // The disposable controller is shut down on success, failure, and cancellation.
        do {
            _ = try await controller.bootstrap()
            guard let catalog = await controller.currentDiscoveredSessionModels() else {
                await controller.shutdown()
                return nil
            }

            var parameterState: OpenCodeACPModelParameterState?
            if let modelRaw {
                parameterState = await Self.probeParameters(for: modelRaw, controller: controller)
            }
            await controller.shutdown()
            return OpenCodeACPModelDiscoveryResult(catalog: catalog, parameterState: parameterState)
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    /// Drives the model-selector probe and reduces the verified snapshot to a terminal
    /// parameter state for the requested model. A probe failure never throws here: the
    /// catalog must survive a failed probe, so the outcome is `.failed(detail:)` instead.
    private static func probeParameters(
        for modelRaw: String,
        controller: ACPAgentSessionController
    ) async -> OpenCodeACPModelParameterState {
        await classifyParameterOutcome(modelRaw: modelRaw) {
            try await controller.discoverSessionModelParameters(for: $0)
        }
    }

    /// The terminal classification, extracted from the transport so it is directly testable
    /// via a scripted closure (no protocol conformance / Python subprocess needed).
    static func classifyParameterOutcome(
        modelRaw: String,
        discover: (String) async throws -> ACPDiscoveredSessionModels
    ) async -> OpenCodeACPModelParameterState {
        let trimmed = modelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failed(detail: "Model parameter discovery requires a non-empty model.")
        }
        let requestedIdentity = ACPModelParameterIdentity.canonicalBaseModelRaw(
            trimmed,
            providerID: .openCode
        )
        do {
            let verified = try await discover(trimmed)
            // Never fall back to another model's metadata when the requested identity is
            // missing or ambiguous in the verified post-mutation snapshot.
            let matchingSets = verified.modelParameterSets.filter {
                ACPModelParameterIdentity.canonicalBaseModelRaw($0.baseModelRaw, providerID: .openCode)
                    == requestedIdentity
            }
            switch matchingSets.count {
            case 0:
                // A verified, matching model that legitimately advertises no selector is
                // `.noUsableParameters` (a successful outcome: no parameter set exists).
                return .noUsableParameters
            case 1:
                let parameterSet = matchingSets[0]
                guard parameterSet.parameters.contains(where: { !$0.choices.isEmpty }) else {
                    return .noUsableParameters
                }
                return .available(parameterSet)
            default:
                return .failed(
                    detail: "Model parameter discovery for '\(trimmed)' was ambiguous: matched \(matchingSets.count) parameter sets; expected exactly one."
                )
            }
        } catch is CancellationError {
            return .failed(detail: "Model parameter discovery for '\(trimmed)' was cancelled.")
        } catch {
            return .failed(detail: "Model parameter discovery for '\(trimmed)' failed: \(error.localizedDescription)")
        }
    }
}
