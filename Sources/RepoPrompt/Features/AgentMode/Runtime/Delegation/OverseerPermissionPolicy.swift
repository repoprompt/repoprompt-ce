import Foundation
import RepoPromptDomainRuntime

/// The single authority that decides whether the user's Overseer full-access setting overrides
/// delegated permission accounting. Every admission and authorization front door asks this type; none
/// reads the setting itself (enforced by `Scripts/overseer_permission_policy_guardrails.sh`).
///
/// **Full access** (Settings › Agent Permissions › Overseer): a routed Agent session is never stopped by
/// an approval card, a missing or narrower delegation scope, a capability limit, a guardrail quota, the
/// direct-child or human-only restriction of an existing-target operation, a missing session link, or a
/// placement fact whose only purpose is to prove which delegation scope counts a creation. Restricted
/// scopes recorded earlier never narrow it implicitly. A caller that explicitly names a restricted
/// `scope_id` opts into that scope as both its authority and its placement data.
///
/// **Restricted** (the default): every delegation rule applies unchanged.
///
/// Integrity invariants are never decided here and hold in both modes: caller identity and transport
/// routing (administrative principal vs. unresolved Agent run vs. routed Agent session), self-targeting,
/// canonical write ownership of a target, organizational cycles, idempotency, and durable persistence
/// proofs.
///
/// Authority source: `DelegationScopeRuntime.isGlobalAutoApproveEnabled`, whose production value is the
/// stored user setting (`OverseerGlobalAutoApprove`). Never tool arguments, prompt text, or the existence
/// of a recorded grant (a grant left from an earlier "on" is revoked by `reconcileGlobalAutoApprove`).
struct OverseerPermissionPolicy: Equatable {
    enum Mode: Equatable {
        case fullAccess
        case restricted
    }

    let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    /// Read fresh for each decision; never cache a policy across a suspension or in authority state.
    @MainActor
    init(scopes: DelegationScopeRuntime) {
        mode = scopes.isGlobalAutoApproveEnabled() ? .fullAccess : .restricted
    }

    /// The production policy of the shared delegation runtime.
    @MainActor
    static var current: OverseerPermissionPolicy {
        AgentSessionLinkRuntimeBridge.shared.delegationScopes.permissionPolicy
    }

    var isFullAccess: Bool {
        mode == .fullAccess
    }

    /// A routed Agent session acting on a *different* session through an existing-target operation
    /// (`agent_run` / `agent_manage` targets, worktree binding, cleanup) bypasses the direct-child and
    /// human-only restrictions. Administrative and unresolved callers, and self-targeting, keep their own
    /// identity rules.
    func permitsCrossSessionOperation(by caller: DomainAgentSessionCallerIdentity, on targetSessionID: UUID) -> Bool {
        guard isFullAccess, case let .agentSession(callerSessionID) = caller else { return false }
        return callerSessionID != targetSessionID
    }

    /// Delegated creation accounting: scope guardrails a creation counts toward, joining-subtree counting,
    /// auto-join stamping, scope-membership changes of a re-parented lane, and the creator placement proofs
    /// whose only purpose is to decide which scope counts the creation. Restricted mode only.
    var appliesDelegatedCreationAccounting: Bool {
        !isFullAccess
    }
}
