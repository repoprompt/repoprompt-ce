import Foundation
import MCP
import RepoPromptDomainRuntime

/// Spawn under scope for the existing session-creating surfaces (`agent_run start`, including an
/// empty or parentless `tab_id`; `agent_manage create_session`; `agent_session_link create_lane`).
///
/// These surfaces keep their own authority: any routed Agent caller may already create sessions.
/// A scope only *adds* two things:
/// 1. before creation, guardrails (`maxLiveSessions`, `maxDepth`) of **every** live `.tree` or
///    `.workspace` scope the creator is a member of, together with each one's ancestor scopes, because
///    the new session joins those scopes and their limits count the whole subtree (design §2.2,
///    §2.4). A worker inside an overseer's tree is bounded exactly like the overseer. In-flight
///    creations are reserved so concurrent spawns cannot overshoot;
/// 2. after creation, auto-join stamping (`organizationalParentID` = creator, `delegationScopeID`)
///    when the creator holds a live scope with `spawn`.
///
/// A creator that is a member of no such scope gets `.unscoped` and every surface behaves exactly as
/// before. Administrative principals never have a creator session, so they are never affected.
/// `.allSessions` scopes are excluded: they cannot hold `spawn`, and every session is their member.
@MainActor
enum DelegationSpawnAdmission {
    struct Admission: Equatable {
        let creatorSessionID: UUID
        /// The creator's own `spawn` scope that stamps auto-join, if any.
        let stampScopeID: UUID?
        let stampLease: DomainDelegationScopeLease?
        /// Counts the pending session against every evaluated scope until `finish`.
        let reservation: DelegationScopeReservation
    }

    enum Outcome: Equatable {
        case unscoped
        case admitted(Admission)
        case denied(DomainDelegationScopeDenial)
    }

    static func admit(
        creatorSessionID: UUID?,
        scopes: DelegationScopeRuntime,
        administration: any AgentSessionAdministrationService,
        projector: any DelegationMembershipProjector
    ) -> Outcome {
        guard let creator = creatorSessionID else { return .unscoped }
        let memberScopes = scopes.allLiveScopes().filter { record in
            if case .allSessions = record.grant.kind { return false }
            return isMember(creator, ofChainFrom: record, scopes: scopes, projector: projector)
        }
        guard !memberScopes.isEmpty else { return .unscoped }

        var reservedScopeIDs: Set<UUID> = []
        for record in memberScopes {
            let chain = scopes.scopeChain(from: record.id)
            var usage: [UUID: DomainDelegationScopeUsage] = [:]
            for scope in chain {
                usage[scope.id] = scopes.usageIncludingReservations(
                    projector.usage(of: scope.grant, spawnParentSessionID: creator)
                )
                reservedScopeIDs.insert(scope.id)
            }
            if let denial = scopes.evaluateSpawnGuardrails(scopeID: record.id, usageByScopeID: usage) {
                return .denied(denial)
            }
        }

        var stampScopeID: UUID?
        var stampLease: DomainDelegationScopeLease?
        for scope in scopes.liveScopes(grantedTo: creator) where scope.grant.capabilities.contains(.spawn) {
            let request = AgentSessionAdministrationRequest(
                operation: .adminSpawn, caller: .agentSession(creator), scopeID: scope.id, targetSessionIDs: [creator]
            )
            if case let .authorized(batch) = administration.authorize(request), let lease = batch.leases.first {
                stampScopeID = scope.id
                stampLease = lease
                break
            }
        }
        // Reserved synchronously after the checks above: nothing can interleave on the main actor.
        let reservation = scopes.reserve(scopeIDs: Array(reservedScopeIDs), sessions: 1)
        return .admitted(Admission(
            creatorSessionID: creator, stampScopeID: stampScopeID, stampLease: stampLease, reservation: reservation
        ))
    }

    private static func isMember(
        _ sessionID: UUID,
        ofChainFrom record: DomainDelegationScopeRecord,
        scopes: DelegationScopeRuntime,
        projector: any DelegationMembershipProjector
    ) -> Bool {
        let chain = scopes.scopeChain(from: record.id)
        return !chain.isEmpty && chain.allSatisfy { scope in
            guard let proof = projector.membershipProof(for: sessionID, in: scope.grant) else { return false }
            return DomainDelegationScopeAuthority.isValid(proof, for: scope.grant, targetSessionID: sessionID)
        }
    }

    /// Production entry used by the MCP surfaces: admits or throws the recoverable scope error.
    /// Pair every non-nil result with `finish(_:)`.
    static func admitOrThrow(creatorSessionID: UUID?) throws -> Admission? {
        let bridge = AgentSessionLinkRuntimeBridge.shared
        switch admit(
            creatorSessionID: creatorSessionID,
            scopes: bridge.delegationScopes,
            administration: bridge.sessionAdministration,
            projector: SpawnProvenanceDelegationMembershipProjector.production(worktreeOwnership: bridge.worktreeOwnership)
        ) {
        case .unscoped:
            return nil
        case let .admitted(admission):
            return admission
        case let .denied(denial):
            throw error(for: denial)
        }
    }

    /// Releases the in-flight reservation once creation finished or failed.
    static func finish(
        _ admission: Admission?,
        scopes: DelegationScopeRuntime = AgentSessionLinkRuntimeBridge.shared.delegationScopes
    ) {
        scopes.release(admission?.reservation)
    }

    /// Structured, recoverable refusal: a stable code followed by a JSON object.
    static func error(for denial: DomainDelegationScopeDenial) -> MCPError {
        var fields: [String: Value] = ["code": .string(denial.publicCode ?? "scope_denied")]
        switch denial {
        case let .guardrailExceeded(guardrail, limit, current):
            fields["guardrail"] = .string(guardrail.rawValue)
            fields["limit"] = .int(limit)
            fields["current"] = .int(current)
            fields["detail"] = .string(
                "The new session would join a delegation scope at its limit. Retire or release sessions in that scope, or ask the user for a larger limit."
            )
        case let .capabilityMissing(capability):
            fields["capability"] = .string(capability.rawValue)
        default:
            break
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(Value.object(fields))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return MCPError.invalidParams("\(denial.publicCode ?? "scope_denied"): \(json)")
    }

    /// Auto-join after creation. Skipped silently if the scope lapsed meanwhile: the session was
    /// created under the surface's own authority and simply does not join by stamp.
    @discardableResult
    static func stamp(
        _ admission: Admission?,
        newSessionID: UUID,
        viewModel: AgentModeViewModel,
        scopes: DelegationScopeRuntime = AgentSessionLinkRuntimeBridge.shared.delegationScopes
    ) async -> Bool {
        guard let admission, let scopeID = admission.stampScopeID, let lease = admission.stampLease,
              scopes.isCurrent(lease)
        else { return false }
        return await (try? viewModel.setDelegationPlacement(
            sessionID: newSessionID,
            organizationalParentID: admission.creatorSessionID,
            delegationScopeID: scopeID
        )) ?? false
    }
}
