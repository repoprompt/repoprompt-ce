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
    case failed(String)
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
    func addLink(observer: UUID, target: UUID) async -> SessionAdminLinkOutcome
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
    func fork(sessionID: UUID, upToItemID: UUID?) async throws -> UUID
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
    func createWorktree(
        forSession sessionID: UUID,
        repoRoot: String?,
        branch: String?,
        baseRef: String?
    ) async throws -> SessionAdminWorktreeInfo
    /// Binds `worktree` (selector: `@id:`, path, branch, or name) for the target now. Throws when the
    /// target is not idle; the handler decides whether to defer. `isStillAuthorized` is evaluated
    /// synchronously right before the binding transition and again at its `beforeCommit` fence; `false`
    /// throws `SessionAdminHostError.authorityEnded` and nothing changes. Work after that fence
    /// (recovery handoff, publication) is not re-checked, as with `manage_worktree`.
    func bindWorktree(
        sessionID: UUID,
        worktree: String,
        repoRoot: String?,
        isStillAuthorized: @escaping @MainActor () -> Bool
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
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            "The target session is not loaded in any open window."
        case .notIdle:
            "The target session is busy; worktree bindings change only at an idle boundary."
        case .authorityEnded:
            "Delegated authority over the target ended before the change; nothing was changed."
        case let .invalid(message):
            message
        }
    }
}
