import Foundation
import MCP
import RepoPromptDomainRuntime

/// Spawn under scope for the existing session-creating surfaces (`agent_run start`,
/// `agent_manage create_session`, `agent_session_link create_lane`).
///
/// These surfaces keep their own authority: any routed Agent caller may already create sessions.
/// A scope only *adds* two things, and only for a creator that holds a live scope with `spawn`:
/// 1. before creation, the scope's spawn guardrails (`maxLiveSessions`, `maxDepth`, counted over the
///    whole subtree and every ancestor scope) through the single authority check (`adminSpawn`);
/// 2. after creation, auto-join: the new session's `organizationalParentID` is the creator and its
///    `delegationScopeID` is the admitting scope.
/// A creator without such a scope gets `.unscoped` and every surface behaves exactly as before.
@MainActor
enum DelegationSpawnAdmission {
    struct Admission: Equatable {
        let scopeID: UUID
        let creatorSessionID: UUID
        let lease: DomainDelegationScopeLease
    }

    enum Outcome: Equatable {
        case unscoped
        case admitted(Admission)
        case denied(DomainDelegationScopeDenial)
    }

    static func admit(
        creatorSessionID: UUID?,
        scopes: DelegationScopeRuntime,
        administration: any AgentSessionAdministrationService
    ) -> Outcome {
        guard let creator = creatorSessionID else { return .unscoped }
        let spawnScopes = scopes.liveScopes(grantedTo: creator).filter { $0.grant.capabilities.contains(.spawn) }
        guard !spawnScopes.isEmpty else { return .unscoped }
        var admitted: Admission?
        for scope in spawnScopes {
            let request = AgentSessionAdministrationRequest(
                operation: .adminSpawn,
                caller: .agentSession(creator),
                scopeID: scope.id,
                targetSessionIDs: [creator]
            )
            switch administration.authorize(request) {
            case let .authorized(batch):
                if admitted == nil, let lease = batch.leases.first {
                    admitted = Admission(scopeID: scope.id, creatorSessionID: creator, lease: lease)
                }
            case let .denied(denial, _) where denial.publicCode != nil:
                // Every live spawn scope the creator holds counts: one exceeded guardrail refuses.
                return .denied(denial)
            case .denied, .confirmationRequired, .scopeSelectionRequired:
                // Not applicable to this scope (for example a workspace scope for another workspace).
                continue
            }
        }
        return admitted.map(Outcome.admitted) ?? .unscoped
    }

    /// Production entry used by the MCP surfaces: admits or throws the recoverable scope error.
    static func admitOrThrow(creatorSessionID: UUID?) throws -> Admission? {
        let bridge = AgentSessionLinkRuntimeBridge.shared
        switch admit(
            creatorSessionID: creatorSessionID,
            scopes: bridge.delegationScopes,
            administration: bridge.sessionAdministration
        ) {
        case .unscoped:
            return nil
        case let .admitted(admission):
            return admission
        case let .denied(denial):
            throw error(for: denial)
        }
    }

    static func error(for denial: DomainDelegationScopeDenial) -> MCPError {
        switch denial {
        case let .guardrailExceeded(guardrail, limit, current):
            MCPError.invalidParams(
                "scope_guardrail_exceeded: \(guardrail.rawValue) limit \(limit), current \(current). Retire or release sessions in your delegation scope, or ask the user for a larger limit."
            )
        case let .capabilityMissing(capability):
            MCPError.invalidParams("scope_capability_missing: \(capability.rawValue).")
        case .expired:
            MCPError.invalidParams("scope_expired: your delegation scope has expired.")
        default:
            MCPError.invalidParams("The session could not be created under your delegation scope.")
        }
    }

    /// Auto-join after creation. Skipped silently if the scope lapsed meanwhile: the session was
    /// created under the surface's own authority and simply does not join.
    @discardableResult
    static func stamp(
        _ admission: Admission?,
        newSessionID: UUID,
        viewModel: AgentModeViewModel,
        scopes: DelegationScopeRuntime = AgentSessionLinkRuntimeBridge.shared.delegationScopes
    ) async -> Bool {
        guard let admission, scopes.isCurrent(admission.lease) else { return false }
        return await (try? viewModel.setDelegationPlacement(
            sessionID: newSessionID,
            organizationalParentID: admission.creatorSessionID,
            delegationScopeID: admission.scopeID
        )) ?? false
    }
}
