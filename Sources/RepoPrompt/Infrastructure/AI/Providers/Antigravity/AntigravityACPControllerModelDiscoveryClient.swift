import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts

/// Reuse one ACP session per workspace when refreshing the signed-in model catalog.
actor AntigravityACPControllerModelDiscoveryClient: AntigravityACPModelDiscoveryClient {
    private var retainedSessionIDByWorkspaceKey: [String: String] = [:]

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
        let provider = AntigravityACPAgentProvider(includeRepoPromptMCPServer: false)
        let support = try await provider.support(for: request)
        guard support == .supported else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "Antigravity ACP is not available."
            )
        }

        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        do {
            _ = try await controller.bootstrap()
            guard let snapshot = await controller.currentDiscoveredSessionModels(), !snapshot.options.isEmpty else {
                // Some versions omit models on load. Refresh in a new session next time.
                retainedSessionIDByWorkspaceKey.removeValue(forKey: workspaceKey)
                throw AntigravityACPModelPollingService.DiscoveryError.noModels
            }
            await retainVerifiedIdentity(controller.currentProviderSessionIdentity(), workspaceKey: workspaceKey)
            await controller.shutdown()
            return snapshot
        } catch {
            await controller.shutdown()
            if ACPAgentSessionController.isAuthenticationRequired(error) {
                throw AntigravityACPModelPollingService.DiscoveryError.signInRequired
            }
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
    /// polls reuse the same retained Antigravity session.
    private static func stableDiscoveryWorkspacePath() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptAntigravityACPDiscovery", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url.standardizedFileURL.path
    }
}
