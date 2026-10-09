import Foundation

/// How a delegation operation relates to batch confirmation cards (design §2.5).
package enum DomainDelegationScopeConfirmationClass: String, Hashable, Sendable {
    /// Read-only or scope-lifecycle; never carded.
    case none
    /// Reversible; carded only when it affects more items than the scope threshold.
    case reversible
    /// Always carded, regardless of item count (`retire`, `worktree_release`). This is the meaning
    /// of the reserved `destructive` capability flag; it imposes no capability requirement.
    case alwaysCarded
    /// Always carded: brings sessions from outside the scope into it.
    case adoption
}

/// Which guardrail family an operation consumes.
package enum DomainDelegationScopeGuardrailUse: String, Hashable, Sendable {
    /// Creates one new live session below the target (its organizational parent).
    case session
    /// Creates one new worktree.
    case worktree
}

package extension DomainAgentSessionTargetOperation {
    /// The primary scope capability this operation requires — the one its lease carries — or `nil`
    /// when no scope may authorize it. Operations whose full requirement depends on the target's
    /// run state (`retire`) also declare `requiredScopeCapabilities(for:)`.
    ///
    /// `nil` covers two different things: scope-lifecycle operations that are decided by the scope
    /// authority itself (`request_scope`, `scope_status`, `release_scope`), and human-only operations
    /// such as `agent_manage.cleanup_sessions`, which deletes sessions. Oversight-link operations are
    /// authorized by `DomainAgentSessionLinkAuthority` and also return `nil` here.
    var requiredScopeCapability: DomainDelegationScopeCapability? {
        switch self {
        // Existing control surfaces that accept the scope basis as a fallback.
        case .runPoll, .runWait, .manageList, .manageGetLog, .manageExtractHandoff:
            .observe
        case .runCancel, .runSteer, .runRespond, .manageResume, .manageStop:
            .control
        case .manageCleanup:
            // Deletes sessions: human-only, never grantable.
            nil
        case .monitorList, .monitorCreateLane, .monitorRetireLane, .monitorPoll, .monitorWait, .monitorRead,
             .monitorSend, .monitorCompact, .monitorSnoozeAutoWake, .monitorRespond, .monitorSteer, .monitorStop,
             .monitorSetModel:
            nil
        case .adminRequestScope, .adminScopeStatus, .adminReleaseScope:
            nil
        case .adminInventory, .adminGet, .adminTree, .adminLinks, .adminWorktreeInventory:
            .observe
        case .adminRename, .adminSetPin, .adminReorderPins, .adminSetGroup, .adminReorderGroups,
             .adminArchive, .adminUnarchive:
            .organize
        case .adminLink, .adminUnlink, .adminReparent, .adminAdopt, .adminRelease:
            .restructure
        case .adminRetire:
            // Stop + release + archive. Its lease carries `restructure`; the full, state-dependent
            // set is `requiredScopeCapabilities(for:)`.
            .restructure
        case .adminSetModel, .adminSetEffort:
            .control
        case .adminSpawn, .adminFork, .adminAttenuate:
            .spawn
        case .adminWorktreeCreate, .adminWorktreeBind, .adminWorktreeUnbind, .adminWorktreeRelease,
             .adminMergePreview, .adminMergeApply:
            // `worktree_release` unbinds and marks stale; it never deletes. Removing or pruning a
            // worktree is human-only and has no operation identity at all.
            .worktree
        }
    }

    /// Every scope capability this operation requires against a target in `state`.
    ///
    /// No operation ever requires the reserved `destructive` flag. `retire` needs `organize` +
    /// `restructure` for an idle or finished target, so an `.allSessions` scope can retire idle
    /// members; stopping a running (or unknown-state) target additionally needs `control`, and the
    /// authority reports such items as `requires_control` instead of granting it implicitly.
    /// `archive` stashes the session's tab, which cancels a live run and its pending prompts, so a
    /// non-idle target likewise needs `organize` + `control`.
    func requiredScopeCapabilities(for state: DomainDelegationScopeTargetState) -> Set<DomainDelegationScopeCapability> {
        guard let primary = requiredScopeCapability else { return [] }
        switch self {
        case .adminRetire:
            return state == .idle ? [.organize, .restructure] : [.organize, .restructure, .control]
        case .adminArchive:
            return state == .idle ? [.organize] : [.organize, .control]
        default:
            return [primary]
        }
    }

    /// Scope-level delegation operations name no target session.
    ///
    /// Lifecycle operations act on the caller's own scope; enumeration operations are filtered by
    /// scope membership rather than authorized per target.
    var isScopeLevel: Bool {
        switch self {
        case .adminRequestScope, .adminScopeStatus, .adminReleaseScope,
             .adminInventory, .adminTree, .adminLinks, .adminWorktreeInventory:
            true
        default:
            false
        }
    }

    /// Scope-lifecycle operations are decided by the scope authority alone, never by a lease.
    var isScopeLifecycle: Bool {
        switch self {
        case .adminRequestScope, .adminScopeStatus, .adminReleaseScope:
            true
        default:
            false
        }
    }

    /// Whether each target must present a membership proof. `adopt` targets are by definition
    /// outside the scope; their consent comes from an always-required batch card instead.
    var requiresScopeMembership: Bool {
        family == .delegation && !isScopeLevel && self != .adminAdopt
    }

    var scopeConfirmationClass: DomainDelegationScopeConfirmationClass {
        switch self {
        case .adminRetire, .adminWorktreeRelease:
            .alwaysCarded
        case .adminAdopt:
            .adoption
        case .adminRename, .adminSetPin, .adminReorderPins, .adminSetGroup, .adminReorderGroups,
             .adminArchive, .adminUnarchive, .adminLink, .adminUnlink, .adminReparent, .adminRelease,
             .adminSetModel, .adminSetEffort, .adminWorktreeBind, .adminWorktreeUnbind:
            .reversible
        default:
            .none
        }
    }

    /// Acting on oneself under `control`, or retiring oneself, would let an agent answer its own
    /// prompt or stop/archive itself through delegated authority; the scope basis refuses it.
    var deniesScopeSelfTarget: Bool {
        self == .adminRetire || requiredScopeCapability == .control
    }

    var scopeGuardrailUse: DomainDelegationScopeGuardrailUse? {
        switch self {
        case .adminSpawn, .adminFork:
            .session
        case .adminWorktreeCreate:
            .worktree
        default:
            nil
        }
    }

    /// Mutation classification for delegation operations, used by `mutatesTarget`.
    internal var delegationMutatesTarget: Bool {
        switch self {
        case .adminRequestScope, .adminScopeStatus, .adminReleaseScope,
             .adminInventory, .adminGet, .adminTree, .adminLinks,
             .adminWorktreeInventory, .adminMergePreview:
            false
        default:
            family == .delegation
        }
    }
}
