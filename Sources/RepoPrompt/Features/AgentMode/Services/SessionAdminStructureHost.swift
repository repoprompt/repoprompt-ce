import Foundation
import MCP
import RepoPromptDomainRuntime

// App effects behind the structural `session_admin` handlers (link/unlink/reparent/adopt,
// set_model/set_effort/fork, worktree ops). Handlers own authorization re-checks and policy; hosts
// only perform the already-authorized effect through the existing owner of that state:
// - links go through `AgentSessionLinkRuntimeBridge.addMonitorLink` / `stopMonitorLink` (link
//   authority stays the sole owner);
// - placement through the owning window's `commitDelegationPlacement` (in memory synchronously,
//   durable write queued);
// - model/effort through the target's existing model-commit seam;
// - worktree bindings through `transitionWorktreeBindings(.externalManagement)`;
// - merge apply through the existing user merge-review prompt.

enum SessionAdminLinkOutcome: Equatable {
    case linked
    case alreadyLinked
    case stopped
    case notLinked
    /// The delegated authority behind the operation ended before it committed; nothing was left behind.
    case revoked
    case failed(String)
}

/// A fork crossed its creation boundary but a later required step failed. Its identity must be
/// returned and retained for idempotent retries; a delegated caller must never delete it as rollback.
struct SessionAdminPartialForkError: Error {
    let sessionID: UUID
    let code: String
    let detail: String
}

enum SessionAdminLifecycleOutcome: Equatable {
    case applied(changed: Bool, fields: [String: String])
    /// The target is not in a state that accepts the change (busy, closing, revoked).
    case blocked(String)
    /// The requested value is not valid for the target.
    case invalid(String)
}

@MainActor
protocol SessionAdminStructureHost: AnyObject {
    /// Applies organizational placement synchronously, with no suspension, so the handler's final
    /// re-validation and this write form one critical section; the returned commit carries the queued
    /// durable write. `delegationScopeID == nil` keeps the existing value. Spawn provenance is never
    /// written. Returns `nil` when no loaded window owns the session.
    func commitOrganizationalPlacement(sessionID: UUID, parentID: UUID, delegationScopeID: UUID?) throws -> DelegationPlacementCommit?
    /// Capabilities of the active link from `observer` to `target`, or `nil` when none.
    func activeLinkCapabilities(observer: UUID, target: UUID) async -> Set<DomainAgentSessionLinkCapability>?
    /// Capabilities every link minted through the bridge carries.
    var mintedLinkCapabilities: Set<DomainAgentSessionLinkCapability> { get }
    /// Adds the link through the bridge's shared durable Add with `isStillAuthorized` carried into the
    /// transaction: it is re-proved at the durable insert and around reservation and activation, so
    /// authority lost while the Add is suspended fails closed (`.revoked`).
    func addLink(
        observer: UUID,
        target: UUID,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> SessionAdminLinkOutcome
    /// Exact-target approvals retain their consent dependency across runtime and restoration.
    func addLink(
        observer: UUID, target: UUID, sourceScopeID: UUID?,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> SessionAdminLinkOutcome
    /// Stops the active link through the bridge's ordinary Stop. `isStillAuthorized` is evaluated
    /// synchronously after the link lookup and right before the Stop.
    func stopLink(
        observer: UUID,
        target: UUID,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> SessionAdminLinkOutcome
    func setModel(
        sessionID: UUID,
        modelID: String,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> SessionAdminLifecycleOutcome
    func setEffort(
        sessionID: UUID,
        effort: String,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> SessionAdminLifecycleOutcome
    /// Forks `sessionID` into a new background tab without focusing it and without inheriting
    /// oversight links. Returns the new session's ID.
    func fork(
        sessionID: UUID, upToItemID: UUID?, isStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws -> UUID
}

extension SessionAdminStructureHost {
    func addLink(
        observer: UUID, target: UUID, sourceScopeID: UUID?,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> SessionAdminLinkOutcome {
        guard sourceScopeID == nil else { return .failed("source_scope_unavailable: This host cannot retain exact-target consent; nothing was linked.") }
        return await addLink(observer: observer, target: target, isStillAuthorized: isStillAuthorized)
    }
}

struct SessionAdminWorktreeInfo: Equatable {
    let worktreeID: String
    let repositoryID: String
    let repoRootPath: String
    let path: String
    let branch: String?
    let isPrunable: Bool

    var value: Value {
        var object: [String: Value] = [
            "worktree_id": .string(worktreeID),
            "repository_id": .string(repositoryID),
            "repo_root": .string(repoRootPath),
            "path": .string(path),
            "is_prunable": .bool(isPrunable)
        ]
        if let branch { object["branch"] = .string(branch) }
        return .object(object)
    }
}

@MainActor
protocol SessionAdminWorktreeHost: AnyObject {
    /// Creates an app-managed worktree for the repository `repoRoot` in the **target** session's
    /// workspace. Admission is fenced to that workspace's roots plus the app-managed container.
    /// Re-proves `isStillAuthorized` after preparation, at the final Git creation fence.
    func createWorktree(
        forSession sessionID: UUID,
        repoRoot: String?,
        branch: String?,
        baseRef: String?,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws -> SessionAdminWorktreeInfo
    /// Binds `worktree` (selector: `@id:`, path, branch, or name) for the target now. Throws when the
    /// target is not idle; the handler decides whether to defer. `isStillAuthorized` is evaluated
    /// synchronously right before the binding transition and again at its `beforeCommit` fence; `false`
    /// throws `SessionAdminHostError.authorityEnded` and nothing changes. Work after that fence
    /// (recovery handoff, publication) is not re-checked, as with `manage_worktree`. `admitBindings`
    /// runs once at that fence with resolved desired identities; `bindingsCommitted` runs at actual
    /// publication, before any required persistence await (or immediately for an admitted exact no-op).
    func bindWorktree(
        sessionID: UUID,
        worktree: String,
        repoRoot: String?,
        isStillAuthorized: @escaping @MainActor () -> Bool,
        admitBindings: @escaping @MainActor (Set<String>) throws -> Void,
        bindingsCommitted: @escaping @MainActor (Set<String>) -> Void
    ) async throws -> SessionAdminWorktreeInfo
    /// Removes the binding for `worktreeID`, or every binding when `nil`. Returns removed IDs.
    func unbindWorktrees(
        sessionID: UUID,
        worktreeID: String?,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws -> [String]
    func boundWorktrees(sessionID: UUID) -> [AgentSessionWorktreeBindingSummary]
    /// Every worktree bound by any session in any loaded workspace, with its binding sessions.
    func allBoundWorktrees() -> [String: Set<UUID>]
    /// Bindings of the same session retained outside the window selected for replacement.
    func retainedWorktreeIDsAfterReplacingBinding(sessionID: UUID) -> Set<String>
    /// Whether a binding transition would be admitted right now (no active run or queued work).
    func isIdleForWorktreeTransition(sessionID: UUID) -> Bool
    /// Suspends until the target next reaches an idle boundary (or disappears). Never mutates.
    func waitForIdleBoundary(sessionID: UUID) async
    /// Git's own prunable status for the worktree at `path` in `repoRoot` (the `list` logic).
    func isWorktreePrunable(path: String, repoRoot: String?) async -> Bool
    func previewMerge(sessionID: UUID, repoRoot: String?, mergeTarget: String?) async throws -> Value
    /// Routes through the existing user merge-review prompt in the target's tab.
    func applyMerge(sessionID: UUID, operationID: String) async throws -> Value
}

enum SessionAdminHostError: LocalizedError, Equatable {
    case sessionUnavailable
    case notIdle
    /// Delegated authority (lease or membership) ended before the write; nothing changed.
    case authorityEnded
    case guardrailExceeded(limit: Int, current: Int)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            "The target session is not loaded in any open window."
        case .notIdle:
            "The target session is busy; worktree bindings change only at an idle boundary."
        case .authorityEnded:
            "Delegated authority over the target ended before the change; nothing was changed."
        case let .guardrailExceeded(limit, current):
            "The worktree binding would exceed max_worktrees (limit \(limit), current \(current))."
        case let .invalid(message):
            message
        }
    }
}
