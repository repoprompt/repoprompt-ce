import Foundation
import RepoPromptDomainRuntime

extension MCPServerViewModel {
    /// Builds the `session_admin` service for one call.
    ///
    /// The caller endpoint resolver is the same exact run-routing resolver `agent_session_link` and
    /// `self_compact` use: it can never be supplied, hinted, or explicitly bound by the caller.
    func sessionAdminToolService(
        requireTargetWindow: @escaping @MainActor () throws -> WindowState
    ) -> SessionAdminMCPToolService {
        let scopes = AgentSessionLinkRuntimeBridge.shared.delegationScopes
        return SessionAdminMCPToolService(
            captureRequestMetadata: { [self] in await captureRequestMetadata() },
            requireTargetWindow: requireTargetWindow,
            resolveObserverEndpoint: { [self] metadata, targetWindow in
                await resolveAgentSessionLinkObserverEndpoint(metadata: metadata, targetWindow: targetWindow)
            },
            scopes: { scopes },
            administration: { AgentSessionLinkRuntimeBridge.shared.sessionAdministrationFrontDoor }
        )
    }
}
