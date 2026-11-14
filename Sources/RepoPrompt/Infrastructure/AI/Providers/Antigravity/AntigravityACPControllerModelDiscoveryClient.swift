import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts

/// Discovery client that reuses one verified Grok session per standardized workspace so
/// 5-minute polling does not accumulate persistent sessions under `~/.grok/sessions`.
/// `session/load` returns fresh `models` metadata on grok 1.0.3, so load-based discovery
/// observes remote catalog changes.
actor AntigravityACPControllerModelDiscoveryClient: AntigravityACPModelDiscoveryClient {
    typealias ProviderFactory = @Sendable (_ agent: AgentProviderKind, _ modelString: String?) async throws -> (any ACPAgentProvider)?
    typealias ControllerFactory = @Sendable (_ provider: any ACPAgentProvider, _ runRequest: ACPRunRequest) throws -> ACPAgentSessionController

    private let providerFactory: ProviderFactory
    private let controllerFactory: ControllerFactory
    private var retainedSessionIDByWorkspaceKey: [String: String] = [:]

    init(
        providerFactory: @escaping ProviderFactory = { agent, modelString in
            if agent == .antigravity {
                return AntigravityACPAgentProvider()
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

    func discoverModels(workspacePath: String?) async throws -> ACPDiscoveredSessionModels? {
        let workspaceKey = Self.discoveryWorkspaceKey(for: workspacePath)
        let retainedSessionID = retainedSessionIDByWorkspaceKey[workspaceKey]
        let request = ACPRunRequest(
            agentKind: .antigravity,
            modelString: nil,
            workspacePath: workspacePath ?? Self.stableDiscoveryWorkspacePath(),
            resumeSessionID: retainedSessionID,
            attachments: [],
            taskLabelKind: nil
        )
        guard let provider = try await providerFactory(.antigravity, nil) else { return nil }
        let support = try await provider.support(for: request)
        guard support == .supported else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "Antigravity ACP is not available."
            )
        }

        let controller = try controllerFactory(provider, request)
        do {
            _ = try await controller.bootstrap()
            await retainVerifiedIdentity(controller.currentProviderSessionIdentity(), workspaceKey: workspaceKey)
            let snapshot = AgentModelCatalogRuntime.shared.acpRegistry.currentSnapshot(for: .antigravity)
            await controller.shutdown()
            return snapshot
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    private func retainVerifiedIdentity(_ identity: ACPProviderSessionIdentity, workspaceKey: String) {
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
        retainedSessionIDByWorkspaceKey[workspaceKey] = loadID
    }

    private static func discoveryWorkspaceKey(for workspacePath: String?) -> String {
        guard let trimmed = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return stableDiscoveryWorkspacePath()
        }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }

    /// One stable provider-specific directory key for nil-workspace discovery so repeated
    /// polls reuse the same retained session instead of leaking `~/.grok/sessions` entries.
    private static func stableDiscoveryWorkspacePath() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptAntigravityACPDiscovery", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url.standardizedFileURL.path
    }
}
