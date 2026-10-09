import Foundation

/// How a delegation operation relates to batch confirmation cards (design §2.5).
package enum DomainDelegationScopeConfirmationClass: String, Hashable, Sendable {
    /// Read-only or scope-lifecycle; never carded.
    case none
    /// Reversible; carded only when it affects more items than the scope threshold.
    case reversible
    /// Always carded, regardless of item count.
    case destructive
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
    /// The single scope capability this operation requires, or `nil` when no scope may authorize it.
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
        case .adminSetModel, .adminSetEffort:
            .control
        case .adminSpawn, .adminFork, .adminAttenuate:
            .spawn
        case .adminWorktreeCreate, .adminWorktreeBind, .adminWorktreeUnbind, .adminMergePreview, .adminMergeApply:
            .worktree
        case .adminRetire, .adminWorktreeRelease:
            // Retire = stop + release + archive; worktree release = unbind + mark stale. Both are the
            // design's `destructive` capability and are always carded. Deleting a session or removing
            // a worktree is human-only and has no operation identity at all.
            .destructive
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
            .destructive
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

    /// Acting on oneself under `control` or `destructive` would let an agent answer its own prompt or
    /// stop/retire itself through delegated authority; the scope basis refuses it.
    var deniesScopeSelfTarget: Bool {
        switch requiredScopeCapability {
        case .control, .destructive:
            true
        default:
            false
        }
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
