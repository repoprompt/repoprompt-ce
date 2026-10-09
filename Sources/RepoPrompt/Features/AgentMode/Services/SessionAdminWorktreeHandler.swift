import Foundation
import MCP
import RepoPromptDomainRuntime

/// Worktree operations on behalf of scope members (scope `worktree`).
///
/// - Root admission is computed from the **target** session's workspace plus the app-managed
///   worktree container (in the host), never from the caller's own routed workspace; existing
///   `manage_worktree` paths are unchanged.
/// - `worktree_bind` with `apply: next_boundary` queues the bind and applies it through the normal
///   binding transition when the target next reaches an idle boundary.
/// - `worktree_release` unbinds and marks the worktree stale for human cleanup, always behind a batch
///   card. Nothing here removes or prunes a worktree; that is human-only.
/// - `merge_apply` goes through the existing user merge-review prompt in the target's tab.
@MainActor
final class SessionAdminWorktreeHandler: AgentSessionAdministrationOperationHandler {
    let operations: Set<DomainAgentSessionTargetOperation> = [
        .adminWorktreeCreate, .adminWorktreeBind, .adminWorktreeUnbind, .adminWorktreeRelease,
        .adminWorktreeInventory, .adminMergePreview, .adminMergeApply
    ]

    /// Deferred binds give up after this many idle boundaries that still refuse the transition.
    static let maxDeferredAttempts = 8

    struct DeferredBind {
        let id: UUID
        let sessionID: UUID
        let worktree: String
        let repoRoot: String?
        let requestedBySessionID: UUID
        let queuedAt: Date
    }

    enum DeferredBindOutcome: Equatable {
        case applied(worktreeID: String)
        case revoked
        case failed(String)
    }

    private let context: SessionAdminHandlerContext
    private let host: any SessionAdminWorktreeHost
    private let ownership: WorktreeOwnershipStore
    private let now: () -> Date
    private(set) var pendingBinds: [UUID: DeferredBind] = [:]
    private(set) var deferredOutcomes: [UUID: DeferredBindOutcome] = [:]
    private var deferredTasks: [UUID: Task<Void, Never>] = [:]

    init(
        context: SessionAdminHandlerContext,
        host: any SessionAdminWorktreeHost,
        ownership: WorktreeOwnershipStore,
        now: @escaping () -> Date = Date.init
    ) {
        self.context = context
        self.host = host
        self.ownership = ownership
        self.now = now
    }

    // MARK: - Cards and preflight

    func confirmationItems(
        for request: AgentSessionAdministrationRequest,
        scope _: DomainDelegationScopeRecord
    ) -> [BatchConfirmationItem] {
        request.targetSessionIDs.map { sessionID in
            let bound = host.boundWorktrees(sessionID: sessionID)
            let names = bound.map { $0.worktreeName ?? $0.branch ?? $0.worktreeID }
            let effect = request.operation == .adminWorktreeRelease
                ? "Unbind \(names.isEmpty ? "no worktrees" : names.joined(separator: ", ")) and mark stale for your cleanup (nothing is deleted)"
                : request.operation.rawValue
            return BatchConfirmationItem(sessionID: sessionID, title: sessionID.uuidString, effect: effect)
        }
    }

    func preflight(_ batch: AgentSessionAdministrationAuthorizedBatch) throws -> Value? {
        let args = batch.request.arguments
        switch batch.request.operation {
        case .adminWorktreeCreate:
            try SessionAdminArguments.requireOnly(["repo_root", "branch", "base_ref", "bind", "apply"], in: args, op: "worktree_create")
            guard batch.request.targetSessionIDs.count == 1 else {
                throw MCPError.invalidParams("session_admin worktree_create takes exactly one session_id (the member it is for).")
            }
            _ = try Self.applyMode(args, op: "worktree_create")
        case .adminWorktreeBind:
            try SessionAdminArguments.requireOnly(["worktree", "repo_root", "apply"], in: args, op: "worktree_bind")
            _ = try SessionAdminArguments.requiredString(args, "worktree", op: "worktree_bind")
            _ = try Self.applyMode(args, op: "worktree_bind")
        case .adminWorktreeUnbind, .adminWorktreeRelease:
            try SessionAdminArguments.requireOnly(["worktree_id"], in: args, op: batch.request.operation.rawValue)
        case .adminWorktreeInventory:
            try SessionAdminArguments.requireOnly(["idle_days"], in: args, op: "worktree_inventory")
        case .adminMergePreview:
            try SessionAdminArguments.requireOnly(["repo_root", "merge_target"], in: args, op: "merge_preview")
            guard batch.request.targetSessionIDs.count == 1 else {
                throw MCPError.invalidParams("session_admin merge_preview takes exactly one session_id.")
            }
        case .adminMergeApply:
            try SessionAdminArguments.requireOnly(["operation_id"], in: args, op: "merge_apply")
            _ = try SessionAdminArguments.requiredString(args, "operation_id", op: "merge_apply")
            guard batch.request.targetSessionIDs.count == 1 else {
                throw MCPError.invalidParams("session_admin merge_apply takes exactly one session_id.")
            }
        default:
            break
        }
        return nil
    }

    enum ApplyMode: String {
        case now
        case nextBoundary = "next_boundary"
    }

    static func applyMode(_ args: [String: Value], op: String) throws -> ApplyMode {
        guard let raw = try SessionAdminArguments.string(args, "apply", op: op) else { return .now }
        guard let mode = ApplyMode(rawValue: raw) else {
            throw MCPError.invalidParams("session_admin \(op) apply must be now or next_boundary.")
        }
        return mode
    }

    // MARK: - Perform

    func perform(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        switch batch.request.operation {
        case .adminWorktreeCreate: try await create(batch)
        case .adminWorktreeBind: try await bind(batch)
        case .adminWorktreeUnbind: try await unbind(batch, release: false)
        case .adminWorktreeRelease: try await unbind(batch, release: true)
        case .adminWorktreeInventory: try await inventory(batch)
        case .adminMergePreview: try await mergePreview(batch)
        case .adminMergeApply: try await mergeApply(batch)
        default: throw SessionAdminMCPToolService.notImplemented(batch.request.operation.rawValue)
        }
    }

    // MARK: - Create

    private func create(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        guard let lease = batch.leases.first, let caller = batch.request.caller.agentSessionID else {
            throw SessionAdminMCPToolService.unavailableError
        }
        let args = batch.request.arguments
        let repoRoot = try SessionAdminArguments.string(args, "repo_root", op: "worktree_create")
        let branch = try SessionAdminArguments.string(args, "branch", op: "worktree_create")
        let baseRef = try SessionAdminArguments.string(args, "base_ref", op: "worktree_create")
        let bindAfter = try SessionAdminArguments.bool(args, "bind", op: "worktree_create") ?? false
        let mode = try Self.applyMode(args, op: "worktree_create")
        let target = lease.targetSessionID
        if batch.request.preview {
            return .object([
                "result": .string("preview"), "op": .string("worktree_create"),
                "session_id": .string(target.uuidString), "bind": .bool(bindAfter)
            ])
        }
        // Reserved before the first suspension, right after the core's `maxWorktrees` check, so two
        // concurrent creations cannot both pass; the ownership record takes over once it exists.
        let reservation = context.scopes.reserve(scopeIDs: context.scopeChain(of: batch.scope).map(\.id), worktrees: 1)
        defer { context.scopes.release(reservation) }
        let info = try await host.createWorktree(forSession: target, repoRoot: repoRoot, branch: branch, baseRef: baseRef)
        // Ownership is recorded even if authority lapsed during creation: the worktree exists, and
        // the record is what lets the user find and clean it up.
        ownership.recordCreation(info, createdBySessionID: caller, delegationScopeID: batch.scope.id, at: now())
        var reply: [String: Value] = [
            "result": .string("created"), "op": .string("worktree_create"),
            "session_id": .string(target.uuidString), "worktree": info.value
        ]
        if bindAfter {
            guard context.scopes.isCurrent(lease) else {
                reply["binding"] = SessionAdminItemResult.revoked(target).value
                return .object(reply)
            }
            reply["binding"] = await bindOne(
                lease: lease, scope: batch.scope, caller: caller, worktree: "@id:\(info.worktreeID)", repoRoot: repoRoot, mode: mode
            ).value
        }
        return .object(reply)
    }

    // MARK: - Bind

    private func bind(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        guard let caller = batch.request.caller.agentSessionID else { throw SessionAdminMCPToolService.unavailableError }
        let args = batch.request.arguments
        let worktree = try SessionAdminArguments.requiredString(args, "worktree", op: "worktree_bind")
        let repoRoot = try SessionAdminArguments.string(args, "repo_root", op: "worktree_bind")
        let mode = try Self.applyMode(args, op: "worktree_bind")
        var items: [SessionAdminItemResult] = []
        var authorityLost = false
        for lease in batch.leases {
            guard !authorityLost, context.scopes.isCurrent(lease) else {
                authorityLost = true
                items.append(.revoked(lease.targetSessionID))
                continue
            }
            if batch.request.preview {
                let idle = host.isIdleForWorktreeTransition(sessionID: lease.targetSessionID)
                items.append(SessionAdminItemResult(
                    sessionID: lease.targetSessionID,
                    result: idle || mode == .now ? "would_bind" : "would_queue"
                ))
                continue
            }
            await items.append(bindOne(
                lease: lease, scope: batch.scope, caller: caller, worktree: worktree, repoRoot: repoRoot, mode: mode
            ))
        }
        return SessionAdminReply.batch(op: "worktree_bind", items: items, preview: batch.request.preview)
    }

    private func bindOne(
        lease: DomainDelegationScopeLease,
        scope: DomainDelegationScopeRecord,
        caller: UUID,
        worktree: String,
        repoRoot: String?,
        mode: ApplyMode
    ) async -> SessionAdminItemResult {
        let target = lease.targetSessionID
        if mode == .nextBoundary, !host.isIdleForWorktreeTransition(sessionID: target) {
            return enqueueDeferredBind(lease: lease, scope: scope, caller: caller, worktree: worktree, repoRoot: repoRoot)
        }
        let context = context
        do {
            let info = try await host.bindWorktree(sessionID: target, worktree: worktree, repoRoot: repoRoot) {
                context.isStillAuthorized(lease, scope: scope)
            }
            ownership.clearReleased(worktreeID: info.worktreeID)
            return SessionAdminItemResult(sessionID: target, result: "bound", fields: ["worktree": info.value])
        } catch SessionAdminHostError.authorityEnded {
            return .revoked(target)
        } catch SessionAdminHostError.notIdle {
            if mode == .nextBoundary {
                return enqueueDeferredBind(lease: lease, scope: scope, caller: caller, worktree: worktree, repoRoot: repoRoot)
            }
            return SessionAdminItemResult(
                sessionID: target, result: "not_applied", code: "target_busy",
                fields: ["detail": .string("The target is busy. Retry with apply: next_boundary to bind at its next idle boundary.")]
            )
        } catch {
            return SessionAdminItemResult(
                sessionID: target, result: "not_applied", code: "bind_failed",
                fields: ["detail": .string(error.localizedDescription)]
            )
        }
    }

    /// One pending bind per target; a newer request replaces an older one.
    private func enqueueDeferredBind(
        lease: DomainDelegationScopeLease,
        scope: DomainDelegationScopeRecord,
        caller: UUID,
        worktree: String,
        repoRoot: String?
    ) -> SessionAdminItemResult {
        let target = lease.targetSessionID
        let pending = DeferredBind(
            id: UUID(), sessionID: target, worktree: worktree, repoRoot: repoRoot,
            requestedBySessionID: caller, queuedAt: now()
        )
        let replaced = pendingBinds[target] != nil
        deferredTasks[target]?.cancel()
        pendingBinds[target] = pending
        deferredOutcomes.removeValue(forKey: target)
        deferredTasks[target] = Task { [weak self] in
            await self?.runDeferredBind(pending, lease: lease, scope: scope)
        }
        var fields: [String: Value] = ["apply": .string(ApplyMode.nextBoundary.rawValue)]
        if replaced { fields["replaced_pending_bind"] = .bool(true) }
        return SessionAdminItemResult(sessionID: target, result: "queued", fields: fields)
    }

    private func runDeferredBind(
        _ pending: DeferredBind,
        lease: DomainDelegationScopeLease,
        scope: DomainDelegationScopeRecord
    ) async {
        let context = context
        let isStillAuthorized: @MainActor () -> Bool = { context.isStillAuthorized(lease, scope: scope) }
        for _ in 0 ..< Self.maxDeferredAttempts {
            await host.waitForIdleBoundary(sessionID: pending.sessionID)
            guard !Task.isCancelled, pendingBinds[pending.sessionID]?.id == pending.id else { return }
            // Lease and membership: the target may have left the scope while the bind was queued.
            guard isStillAuthorized() else {
                return finishDeferredBind(pending, .revoked)
            }
            do {
                let info = try await host.bindWorktree(
                    sessionID: pending.sessionID, worktree: pending.worktree, repoRoot: pending.repoRoot,
                    isStillAuthorized: isStillAuthorized
                )
                ownership.clearReleased(worktreeID: info.worktreeID)
                return finishDeferredBind(pending, .applied(worktreeID: info.worktreeID))
            } catch SessionAdminHostError.authorityEnded {
                return finishDeferredBind(pending, .revoked)
            } catch SessionAdminHostError.notIdle {
                continue
            } catch is CancellationError {
                return
            } catch {
                return finishDeferredBind(pending, .failed(error.localizedDescription))
            }
        }
        finishDeferredBind(pending, .failed("The target never reached an idle boundary that admitted the bind."))
    }

    private func finishDeferredBind(_ pending: DeferredBind, _ outcome: DeferredBindOutcome) {
        guard pendingBinds[pending.sessionID]?.id == pending.id else { return }
        pendingBinds.removeValue(forKey: pending.sessionID)
        deferredTasks.removeValue(forKey: pending.sessionID)
        deferredOutcomes[pending.sessionID] = outcome
    }

    /// Test and shutdown seam: waits for every queued deferred bind task.
    func settleDeferredBinds() async {
        for task in deferredTasks.values {
            await task.value
        }
    }

    // MARK: - Unbind / release

    private func unbind(_ batch: AgentSessionAdministrationAuthorizedBatch, release: Bool) async throws -> Value {
        guard let caller = batch.request.caller.agentSessionID else { throw SessionAdminMCPToolService.unavailableError }
        let op = release ? "worktree_release" : "worktree_unbind"
        let worktreeID = try SessionAdminArguments.string(batch.request.arguments, "worktree_id", op: op)
        var items: [SessionAdminItemResult] = []
        var authorityLost = false
        for lease in batch.leases {
            let target = lease.targetSessionID
            guard !authorityLost, context.scopes.isCurrent(lease) else {
                authorityLost = true
                items.append(.revoked(target))
                continue
            }
            let bound = host.boundWorktrees(sessionID: target).filter { worktreeID == nil || $0.worktreeID == worktreeID }
            if batch.request.preview {
                items.append(SessionAdminItemResult(
                    sessionID: target, result: bound.isEmpty ? "nothing_bound" : "would_unbind",
                    fields: ["worktree_ids": .array(bound.map { .string($0.worktreeID) })]
                ))
                continue
            }
            // A target's pending deferred bind is superseded by an explicit unbind/release.
            cancelDeferredBind(for: target)
            guard !bound.isEmpty else {
                items.append(SessionAdminItemResult(sessionID: target, result: "nothing_bound"))
                continue
            }
            do {
                let context = context
                let scope = batch.scope
                let removed = try await host.unbindWorktrees(sessionID: target, worktreeID: worktreeID) {
                    context.isStillAuthorized(lease, scope: scope)
                }
                if release {
                    // The stale mark is recorded for whatever was actually unbound, even if authority
                    // ended during the await: it only ever makes cleanup more visible.
                    ownership.markReleased(bound.filter { removed.contains($0.worktreeID) }, bySessionID: caller, at: now())
                }
                items.append(SessionAdminItemResult(
                    sessionID: target, result: release ? "released" : "unbound",
                    fields: ["worktree_ids": .array(removed.map(Value.string))]
                ))
            } catch SessionAdminHostError.authorityEnded {
                items.append(.revoked(target))
            } catch SessionAdminHostError.notIdle {
                items.append(SessionAdminItemResult(sessionID: target, result: "not_applied", code: "target_busy"))
            } catch {
                items.append(SessionAdminItemResult(
                    sessionID: target, result: "not_applied", code: "unbind_failed",
                    fields: ["detail": .string(error.localizedDescription)]
                ))
            }
        }
        return SessionAdminReply.batch(
            op: op, items: items, requiresControl: batch.itemsRequiringControl, preview: batch.request.preview
        )
    }

    private func cancelDeferredBind(for sessionID: UUID) {
        deferredTasks.removeValue(forKey: sessionID)?.cancel()
        pendingBinds.removeValue(forKey: sessionID)
    }

    // MARK: - Inventory

    private func inventory(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        let idleDays: Int? = try {
            guard let raw = batch.request.arguments["idle_days"] else { return nil }
            guard let days = raw.intValue, days >= 0 else {
                throw MCPError.invalidParams("session_admin worktree_inventory idle_days must be an integer >= 0.")
            }
            return days
        }()
        let members = context.projector.members(of: batch.scope.grant)
            .filter { context.isMember($0, ofChainFrom: batch.scope) }
        struct Row {
            var summary: AgentSessionWorktreeBindingSummary?
        }
        var rows: [String: Row] = [:]
        for member in members {
            for summary in host.boundWorktrees(sessionID: member) where rows[summary.worktreeID] == nil {
                rows[summary.worktreeID] = Row(summary: summary)
            }
        }
        // `unbound` and `released` are judged against bindings across every loaded session, not only
        // members: a worktree some other session still binds is in use.
        let boundEverywhere = host.allBoundWorktrees()
        let owned = ownership.records(createdBy: Set(members))
        for record in owned where rows[record.worktreeID] == nil {
            rows[record.worktreeID] = Row()
        }
        let currentDate = now()
        var entries: [Value] = []
        for worktreeID in rows.keys.sorted() {
            guard let row = rows[worktreeID] else { continue }
            let record = ownership.record(worktreeID: worktreeID)
            let path = row.summary?.worktreeRootPath ?? record?.path ?? ""
            let lastActivity = [record?.createdAt, record?.releasedAt, row.summary?.boundAt].compactMap(\.self).max()
            let repoRoot = record?.repoRootPath ?? row.summary?.logicalRootPath
            let isPrunable = if path.isEmpty { true } else { await host.isWorktreePrunable(path: path, repoRoot: repoRoot) }
            let boundSessionIDs = (boundEverywhere[worktreeID] ?? []).sorted { $0.uuidString < $1.uuidString }
            let visibleBoundSessionIDs = boundSessionIDs.filter(Set(members).contains)
            let flags = DomainDelegationWorktreeStaleness.flags(
                isReleased: record?.releasedAt != nil,
                boundSessionCount: boundSessionIDs.count,
                isPrunable: isPrunable,
                lastActivityAt: lastActivity,
                idleThresholdDays: idleDays,
                now: currentDate
            )
            var entry: [String: Value] = [
                "worktree_id": .string(worktreeID),
                "path": .string(path),
                // Only members are named; sessions outside the scope are a count.
                "bound_session_ids": .array(visibleBoundSessionIDs.map { .string($0.uuidString) }),
                "bound_outside_scope_count": .int(boundSessionIDs.count - visibleBoundSessionIDs.count),
                "stale_flags": .array(flags.map { .string($0.rawValue) })
            ]
            if let branch = row.summary?.branch ?? record?.branch { entry["branch"] = .string(branch) }
            if let record {
                if let creator = record.createdBySessionID { entry["created_by_session_id"] = .string(creator.uuidString) }
                if let scope = record.delegationScopeID { entry["delegation_scope_id"] = .string(scope.uuidString) }
                entry["created_at"] = .string(ISO8601DateFormatter().string(from: record.createdAt))
            }
            entries.append(.object(entry))
        }
        let pending = pendingBinds.values
            .filter { members.contains($0.sessionID) }
            .sorted { $0.queuedAt < $1.queuedAt }
            .map { bind -> Value in
                .object([
                    "session_id": .string(bind.sessionID.uuidString),
                    "worktree": .string(bind.worktree),
                    "apply": .string(ApplyMode.nextBoundary.rawValue)
                ])
            }
        return .object([
            "result": .string("ok"),
            "op": .string("worktree_inventory"),
            "worktrees": .array(entries),
            "pending_binds": .array(pending),
            "note": .string("Release marks worktrees stale; removing or pruning them is up to the user.")
        ])
    }

    // MARK: - Merge

    private func mergePreview(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        guard let lease = batch.leases.first else { throw SessionAdminMCPToolService.unavailableError }
        let repoRoot = try SessionAdminArguments.string(batch.request.arguments, "repo_root", op: "merge_preview")
        let mergeTarget = try SessionAdminArguments.string(batch.request.arguments, "merge_target", op: "merge_preview")
        let preview = try await host.previewMerge(sessionID: lease.targetSessionID, repoRoot: repoRoot, mergeTarget: mergeTarget)
        return .object([
            "result": .string("previewed"), "op": .string("merge_preview"),
            "session_id": .string(lease.targetSessionID.uuidString), "merge": preview
        ])
    }

    private func mergeApply(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        guard let lease = batch.leases.first else { throw SessionAdminMCPToolService.unavailableError }
        let operationID = try SessionAdminArguments.requiredString(batch.request.arguments, "operation_id", op: "merge_apply")
        guard context.scopes.isCurrent(lease) else {
            return SessionAdminReply.batch(op: "merge_apply", items: [.revoked(lease.targetSessionID)])
        }
        if batch.request.preview {
            return .object(["result": .string("preview"), "op": .string("merge_apply"), "operation_id": .string(operationID)])
        }
        // The user decides in the existing review prompt; scope authority only lets the overseer ask.
        let result = try await host.applyMerge(sessionID: lease.targetSessionID, operationID: operationID)
        return .object([
            "result": .string("reviewed"), "op": .string("merge_apply"),
            "session_id": .string(lease.targetSessionID.uuidString), "merge": result
        ])
    }
}
