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
final class SessionAdminWorktreeHandler: AgentSessionAdministrationOperationHandler, AgentSessionAdministrationTargetDeriving {
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
        case failed(subreason: String, detail: String, retryable: Bool, worktree: String, repoRoot: String?)
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

    // MARK: - Target derivation

    /// `worktree_unbind`/`worktree_release` naming only `worktree_id` act on the sessions bound to
    /// it. The front door keeps only scope members; each one is still authorized individually.
    func derivedTargets(for request: AgentSessionAdministrationRequest) throws -> [UUID]? {
        guard request.operation == .adminWorktreeUnbind || request.operation == .adminWorktreeRelease else { return nil }
        let op = request.operation.adminOperationName
        guard let worktreeID = request.arguments["worktree_id"]?.stringValue, !worktreeID.isEmpty else {
            throw AgentSessionAdminEarlyResult(value: .object(SessionAdminReply.diagnostic(code: "target_required", fields: [
                "result": .string("invalid_request"), "op": .string(op), "retryable": .bool(false),
                "next_call": .object(["tool": .string("session_admin"), "arguments": .object(["op": .string("worktree_inventory")])]),

                "detail": .string("\(op) needs session_id (the session the worktree is bound to) or worktree_id. Call worktree_inventory to see bound worktrees and their sessions.")
            ])))
        }
        let bound = (host.allBoundWorktrees()[worktreeID] ?? []).sorted { $0.uuidString < $1.uuidString }
        guard !bound.isEmpty else {
            throw AgentSessionAdminEarlyResult(value: .object(SessionAdminReply.diagnostic(code: "worktree_not_bound", fields: [
                "result": .string("not_applied"), "op": .string(op), "retryable": .bool(false),
                "next_call": .object(["tool": .string("session_admin"), "arguments": .object(["op": .string("worktree_inventory")])]),
                "worktree_id": .string(worktreeID),
                "detail": .string("No loaded session is bound to this worktree, so there is nothing to \(op == "worktree_release" ? "release" : "unbind"). Removing the worktree from disk stays with the user.")
            ])))
        }
        return bound
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
        let value: Value = switch batch.request.operation {
        case .adminWorktreeCreate: try await create(batch)
        case .adminWorktreeBind: try await bind(batch)
        case .adminWorktreeUnbind: try await unbind(batch, release: false)
        case .adminWorktreeRelease: try await unbind(batch, release: true)
        case .adminWorktreeInventory: try await inventory(batch)
        case .adminMergePreview: try await mergePreview(batch)
        case .adminMergeApply: try await mergeApply(batch)
        default: throw SessionAdminMCPToolService.notImplemented(batch.request.operation.rawValue)
        }
        guard case var .object(reply) = value else { return value }
        reply["ownership_continuity_save_state"] = .string(ownership.saveState)
        if let detail = ownership.persistenceDiagnostic { reply["ownership_continuity_detail"] = .string(detail) }
        return .object(reply)
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
        let bindAfter = try SessionAdminArguments.bool(args, "bind", op: "worktree_create") ?? true
        let mode = try Self.applyMode(args, op: "worktree_create")
        let target = lease.targetSessionID
        if batch.request.preview {
            return .object([
                "result": .string("preview"), "op": .string("worktree_create"),
                "session_id": .string(target.uuidString), "bind": .bool(bindAfter)
            ])
        }
        // The worktree is owned by the caller, so it counts toward every scope the caller's creations
        // count toward (and, once bound, the target's), not only the caller's own chain (which the core
        // already checked).
        var records = try DelegationSpawnAdmission.guardrailScopes(forCreator: caller, scopes: context.scopes, projector: context.projector)
        if bindAfter {
            records += try DelegationSpawnAdmission.guardrailScopes(forCreator: target, scopes: context.scopes, projector: context.projector)
        }
        let evaluation = DelegationSpawnAdmission.evaluate(
            records, creator: caller, operation: .adminWorktreeCreate, scopes: context.scopes, projector: context.projector
        )
        if let denial = evaluation.denial {
            let refusal = try SessionAdminMCPToolService.deniedValue(denial, sessionID: nil)
            guard var fields = refusal.objectValue else { return refusal }
            fields["subreason"] = fields["guardrail"] ?? .string("usage_evidence_unavailable")
            return .object(SessionAdminReply.diagnostic(
                code: fields["code"]?.stringValue ?? "scope_denied", sessionIDs: [target], fields: fields
            ))
        }
        // Reserved before the first suspension, right after the guardrail checks, so two concurrent
        // creations cannot both pass; the ownership record takes over once it exists.
        let reservation = context.scopes.reserve(
            scopeIDs: Array(evaluation.scopeIDs.union(context.scopeChain(of: batch.scope).map(\.id))), worktrees: 1
        )
        defer { context.scopes.release(reservation) }
        let handlerContext = context
        let info: SessionAdminWorktreeInfo
        do {
            info = try await host.createWorktree(
                forSession: target, repoRoot: repoRoot, branch: branch, baseRef: baseRef,
                isStillAuthorized: { handlerContext.isStillAuthorized(lease, scope: batch.scope) }
            )
        } catch SessionAdminHostError.authorityEnded {
            return SessionAdminReply.batch(op: "worktree_create", items: [.revoked(target)])
        }
        // Ownership is recorded even if authority lapsed during creation: the worktree exists, and
        // the record is what lets the user find and clean it up.
        ownership.recordCreation(info, createdBySessionID: caller, delegationScopeID: batch.scope.id, at: now())
        // The ownership row now counts the same identity; the anonymous creation reservation must
        // transfer before an optional bind checks usage, otherwise create+bind charges twice.
        context.scopes.release(reservation)
        var reply: [String: Value] = [
            "result": .string("created"), "op": .string("worktree_create"),
            "session_id": .string(target.uuidString), "worktree": info.value,
            // Replayable by the front door's ledger: a retry with the same key never creates twice.
            "changed_count": .int(1), "bound": .bool(false),
            "next_call": .object(["tool": .string("session_admin"), "arguments": .object([
                "op": .string("worktree_bind"), "session_id": .string(target.uuidString),
                "scope_id": .string(batch.scope.id.uuidString), "worktree": .string("@id:\(info.worktreeID)"),
                "repo_root": .string(info.repoRootPath), "apply": .string("next_boundary")
            ])])
        ]
        if bindAfter {
            let binding: SessionAdminItemResult = if context.scopes.isCurrent(lease) {
                await bindOne(
                    lease: lease, scope: batch.scope, caller: caller, worktree: "@id:\(info.worktreeID)", repoRoot: repoRoot, mode: mode
                )
            } else {
                .revoked(target)
            }
            reply["binding"] = binding.value
            let bindingCommitted = binding.fields[AgentSessionAdminRendering.committedChangesKey] == .bool(true)
            reply["bound"] = .bool(binding.result == "bound" || bindingCommitted)
            if bindingCommitted { reply["next_call"] = binding.value.objectValue?["next_call"] }
            if binding.result == "bound" { reply.removeValue(forKey: "next_call") }
            if binding.status == "failed" || binding.status == "skipped" {
                reply["result"] = .string("partial")
                reply["detail"] = .string("The worktree was created and its ownership recorded, but binding completion failed. Use next_call to inspect or bind the existing worktree; retrying this creation key replays this receipt. " + (binding.value.objectValue?["detail"]?.stringValue ?? ""))
                reply["affected"] = .object([
                    "session_ids": .array([.string(target.uuidString)]), "worktree_ids": .array([.string(info.worktreeID)])
                ])
                reply = SessionAdminReply.diagnostic(code: binding.code ?? "bind_failed", sessionIDs: [target], fields: reply)
                reply["subreason"] = binding.value.objectValue?["subreason"] ?? .string(binding.code ?? "bind_failed")
            }
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
        var committed = false
        do {
            let info = try await bindWithAdmission(lease: lease, scope: scope, worktree: worktree, repoRoot: repoRoot, onCommitted: { committed = true })
            return SessionAdminItemResult(sessionID: target, result: "bound", fields: ["worktree": info.value])
        } catch SessionAdminHostError.authorityEnded {
            return .revoked(target)
        } catch SessionAdminHostError.usageEvidenceUnavailable {
            return SessionAdminItemResult(
                sessionID: target, result: "not_applied", code: "scope_denied",
                fields: ["subreason": .string("usage_evidence_unavailable")]
            )
        } catch let SessionAdminHostError.guardrailExceeded(limit, current) {
            return SessionAdminItemResult(
                sessionID: target, result: "not_applied", code: "scope_guardrail_exceeded",
                fields: ["subreason": .string("max_worktrees"), "guardrail": .string("max_worktrees"), "limit": .int(limit), "current": .int(current)]
            )
        } catch SessionAdminHostError.notIdle {
            if mode == .nextBoundary {
                return enqueueDeferredBind(lease: lease, scope: scope, caller: caller, worktree: worktree, repoRoot: repoRoot)
            }
            return SessionAdminItemResult(
                sessionID: target, result: "not_applied", code: "target_busy",
                fields: [
                    "detail": .string("The target is busy. Use next_call to bind at its next idle boundary."),
                    "next_call": .object(["tool": .string("session_admin"), "arguments": .object([
                        "op": .string("worktree_bind"), "scope_id": .string(scope.id.uuidString),
                        "session_id": .string(target.uuidString), "worktree": .string(worktree), "apply": .string("next_boundary")
                    ])])
                ]
            )
        } catch {
            return SessionAdminItemResult(
                sessionID: target, result: "not_applied", code: "bind_failed",
                fields: [
                    "detail": .string(error.localizedDescription + (
                        committed
                            ? " The binding committed, but completion failed. Inspect the current session before any further mutation."
                            : " No binding commit was acknowledged. Inspect current session and scope state before choosing a recovery call."
                    )),
                    AgentSessionAdminRendering.committedChangesKey: .bool(committed),
                    "next_call": .object(["tool": .string("session_admin"), "arguments": .object([
                        "op": .string("get"), "scope_id": .string(scope.id.uuidString), "session_id": .string(target.uuidString)
                    ])])
                ]
            )
        }
    }

    /// Resolving a selector and preparing roots may suspend. Admission runs only at the host's final
    /// fence, using resolved worktree identities; the reservations cover its remaining publication
    /// awaits and deduplicate both concurrent same-tree binds and already-counted ownership.
    private func bindWithAdmission(
        lease: DomainDelegationScopeLease,
        scope: DomainDelegationScopeRecord,
        worktree: String,
        repoRoot: String?,
        onCommitted: @escaping @MainActor () -> Void = {}
    ) async throws -> SessionAdminWorktreeInfo {
        let context = context
        var reservations: [DelegationScopeReservation] = []
        defer { for reservation in reservations {
            context.scopes.release(reservation)
        } }
        return try await host.bindWorktree(
            sessionID: lease.targetSessionID, worktree: worktree, repoRoot: repoRoot,
            isStillAuthorized: { context.isStillAuthorized(lease, scope: scope) },
            admitBindings: { desiredIDs in
                precondition(reservations.isEmpty, "A binding transition admits only once")
                reservations = try self.reserveBinding(desiredIDs, target: lease.targetSessionID, scope: scope)
            },
            bindingsCommitted: { desiredIDs in
                onCommitted()
                for worktreeID in desiredIDs {
                    self.ownership.clearReleased(worktreeID: worktreeID)
                }
            }
        )
    }

    private func reserveBinding(
        _ desiredIDs: Set<String>, target: UUID, scope: DomainDelegationScopeRecord
    ) throws -> [DelegationScopeReservation] {
        let reactivated = desiredIDs.compactMap { ownership.record(worktreeID: $0) }
            .filter { $0.releasedAt != nil && $0.createdBySessionID != nil }
        var records = try context.scopeChain(of: scope)
            + DelegationSpawnAdmission.guardrailScopes(forCreator: target, scopes: context.scopes, projector: context.projector)
        for creator in Set(reactivated.compactMap(\.createdBySessionID)) {
            records += try DelegationSpawnAdmission.guardrailScopes(forCreator: creator, scopes: context.scopes, projector: context.projector)
        }
        // A target can count toward overlapping creator scopes and their restricted ancestors,
        // even when the authorizing scope itself is unrestricted.
        records = records.flatMap { context.scopeChain(of: $0) }
        let byID = Dictionary(
            records.filter { !$0.grant.unrestricted && $0.grant.guardrails.maxWorktrees != nil }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let bound = host.allBoundWorktrees()
        let retainedTargetIDs = host.retainedWorktreeIDsAfterReplacingBinding(sessionID: target)
        var admitted: [(UUID, Set<String>)] = []
        for record in byID.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let projected = context.projector.usageEvidence(of: record.grant, spawnParentSessionID: nil) else {
                throw SessionAdminHostError.usageEvidenceUnavailable
            }
            let members = Set(context.projector.members(of: record.grant))
            let owned = ownership.ownedUnreleasedWorktreeIDs(createdBy: members)
            let currentIDs = Set(bound.filter { !$0.value.isDisjoint(with: members) }.keys).union(owned)
            let addedIDs = (members.contains(target) ? desiredIDs : [])
                .union(reactivated.filter { $0.createdBySessionID.map(members.contains) ?? false }.map(\.worktreeID))
            // Replace this target's selected-window contribution while retaining bindings in
            // other windows, another member's bindings, and unreleased ownership rows.
            let postIDs = Set(bound.filter { !$0.value.subtracting([target]).isDisjoint(with: members) }.keys)
                .union(members.contains(target) ? retainedTargetIDs : [])
                .union(owned).union(addedIDs)
            let anonymous = max(0, projected.worktreeCount - projected.countedWorktreeIDs.count)
            let postUsage = context.scopes.usageIncludingReservations(DomainDelegationScopeUsage(
                scopeID: record.id, liveSessionCount: projected.liveSessionCount,
                worktreeCount: postIDs.count + anonymous, countedWorktreeIDs: postIDs
            ))
            if let limit = record.grant.guardrails.maxWorktrees, postUsage.worktreeCount > limit {
                let current = context.scopes.usageIncludingReservations(DomainDelegationScopeUsage(
                    scopeID: record.id, liveSessionCount: projected.liveSessionCount,
                    worktreeCount: currentIDs.count + anonymous, countedWorktreeIDs: currentIDs
                )).worktreeCount
                throw SessionAdminHostError.guardrailExceeded(limit: limit, current: current)
            }
            admitted.append((record.id, addedIDs))
        }
        // Every check and all reservations are synchronous, so no competing bind can pass between
        // the census and the reservation. Identity reservations remain held independently by each
        // admitted bind, even if another bind of the same identity later fails.
        return admitted.map { context.scopes.reserve(scopeIDs: [$0.0], worktreeIDs: $0.1) }
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
                let info = try await bindWithAdmission(
                    lease: lease, scope: scope, worktree: pending.worktree, repoRoot: pending.repoRoot
                )
                return finishDeferredBind(pending, .applied(worktreeID: info.worktreeID))
            } catch SessionAdminHostError.authorityEnded {
                return finishDeferredBind(pending, .revoked)
            } catch SessionAdminHostError.notIdle {
                continue
            } catch is CancellationError {
                return
            } catch SessionAdminHostError.usageEvidenceUnavailable {
                // Permanent until placement is repaired: an unchanged retry cannot succeed.
                return finishDeferredBind(pending, .failed(
                    subreason: "usage_evidence_unavailable",
                    detail: SessionAdminHostError.usageEvidenceUnavailable.localizedDescription,
                    retryable: false, worktree: pending.worktree, repoRoot: pending.repoRoot
                ))
            } catch let SessionAdminHostError.guardrailExceeded(limit, current) {
                return finishDeferredBind(pending, .failed(
                    subreason: "worktree_limit_reached",
                    detail: "The scope allows \(limit) worktrees and \(current) are bound; release one before binding.",
                    retryable: false, worktree: pending.worktree, repoRoot: pending.repoRoot
                ))
            } catch let SessionAdminHostError.invalid(message) {
                return finishDeferredBind(pending, .failed(
                    subreason: "invalid_bind", detail: message, retryable: false, worktree: pending.worktree, repoRoot: pending.repoRoot
                ))
            } catch {
                // Unclassified failures (for example a missing worktree path) are not repaired by an
                // unchanged retry. Only the idle-boundary timeout below is known to be transient.
                return finishDeferredBind(pending, .failed(
                    subreason: "bind_error", detail: error.localizedDescription, retryable: false, worktree: pending.worktree, repoRoot: pending.repoRoot
                ))
            }
        }
        finishDeferredBind(pending, .failed(
            subreason: "no_idle_boundary",
            detail: "The target never reached an idle boundary that admitted the bind.",
            retryable: true, worktree: pending.worktree, repoRoot: pending.repoRoot
        ))
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
        let initialChain = context.scopeChain(of: batch.scope)
        guard let currentScope = context.scopes.record(id: batch.scope.id),
              currentScope.generation == batch.scope.generation,
              !initialChain.isEmpty,
              initialChain.allSatisfy({ record in
                  record.isActive && batch.request.operation.requiredScopeCapability.map(record.grant.capabilities.contains) == true
              })
        else { throw SessionAdminMCPToolService.unavailableError }
        // Listing has no capacity admission: per-row membership and final chain fences remain
        // authoritative. Unrelated incomplete usage evidence must not veto a read.
        let focus = Set(batch.request.targetSessionIDs)
        let members = context.projector.members(of: batch.scope.grant)
            .filter { context.isMember($0, ofChainFrom: batch.scope) }
            .filter { focus.isEmpty || focus.contains($0) }
        let memberSet = Set(members)
        let chainScopeIDs = Set(context.scopeChain(of: batch.scope).map(\.id))
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
        let owned = ownership.records(createdBy: memberSet)
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
            let boundSessionIDs = boundEverywhere[worktreeID] ?? []
            let memberBindings = boundSessionIDs.filter(memberSet.contains).sorted { $0.uuidString < $1.uuidString }
            // `unbound`/`released` consider every loaded session's bindings, so a worktree in use
            // elsewhere is never offered as free; nothing below names or counts those sessions.
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
                // Scope-restricted like `inventory`: only members are named, and no session outside
                // the scope is identified or counted.
                "bound_session_ids": .array(memberBindings.map { .string($0.uuidString) }),
                "stale_flags": .array(flags.map { .string($0.rawValue) })
            ]
            if let branch = row.summary?.branch ?? record?.branch { entry["branch"] = .string(branch) }
            if let record {
                if let creator = record.createdBySessionID, memberSet.contains(creator) {
                    entry["created_by_session_id"] = .string(creator.uuidString)
                }
                if let scope = record.delegationScopeID, chainScopeIDs.contains(scope) {
                    entry["delegation_scope_id"] = .string(scope.uuidString)
                }
                entry["created_at"] = .string(ISO8601DateFormatter().string(from: record.createdAt))
            }
            entries.append(.object(entry))
        }
        // Prunability checks suspend. Re-prove the whole chain and every named member before
        // returning worktree paths or deferred outcomes; a stale pre-await census is not authority.
        try Task.checkCancellation()
        let currentChain = context.scopeChain(of: batch.scope)
        guard !initialChain.isEmpty, currentChain.count == initialChain.count,
              zip(initialChain, currentChain).allSatisfy({ before, after in
                  before.id == after.id && before.generation == after.generation && after.isActive
              }),
              members.allSatisfy({ context.isMember($0, ofChainFrom: batch.scope) })
        else { throw SessionAdminMCPToolService.unavailableError }
        let outcomes = deferredOutcomes.keys.filter(memberSet.contains)
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { sessionID -> Value? in
                guard let outcome = deferredOutcomes[sessionID] else { return nil }
                var row: [String: Value] = [
                    "session_id": .string(sessionID.uuidString),
                    "affected": .array([.string(sessionID.uuidString)])
                ]
                switch outcome {
                case let .applied(worktreeID):
                    row["result"] = .string("applied")
                    row["worktree_id"] = .string(worktreeID)
                case .revoked:
                    row["result"] = .string("not_applied")
                    row["code"] = .string("scope_revoked")
                    row["subreason"] = .string("revoked_before_idle_boundary")
                    row["detail"] = .string("The scope authorizing this deferred bind was revoked before the target reached an idle boundary; nothing was bound.")
                    row["next_call"] = .object(["tool": .string("session_admin"), "arguments": .object(["op": .string("scope_status")])])
                    row["retryable"] = .bool(false)
                case let .failed(subreason, detail, retryable, worktree, repoRoot):
                    row["result"] = .string("not_applied")
                    row["code"] = .string("bind_failed")
                    row["subreason"] = .string(subreason)
                    row["detail"] = .string(detail)
                    // Retryable failures get the complete original bind call; permanent ones point
                    // at the scope and limits to inspect instead of an unchanged retry.
                    row["next_call"] = retryable
                        ? .object(["tool": .string("session_admin"), "arguments": .object([
                            "op": .string("worktree_bind"), "session_id": .string(sessionID.uuidString),
                            "worktree": .string(worktree)
                        ].merging(repoRoot.map { ["repo_root": Value.string($0)] } ?? [:]) { current, _ in current })])
                        : .object(["tool": .string("session_admin"), "arguments": .object(["op": .string("scope_status")])])
                    row["retryable"] = .bool(retryable)
                }
                return .object(row)
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
            "deferred_outcomes": .array(outcomes),
            "note": .string("Release marks worktrees stale; removing or pruning them is up to the user.")
        ])
    }

    // MARK: - Merge

    private func mergePreview(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        guard let lease = batch.leases.first else { throw SessionAdminMCPToolService.unavailableError }
        let repoRoot = try SessionAdminArguments.string(batch.request.arguments, "repo_root", op: "merge_preview")
        let mergeTarget = try SessionAdminArguments.string(batch.request.arguments, "merge_target", op: "merge_preview")
        let preview = try await host.previewMerge(sessionID: lease.targetSessionID, repoRoot: repoRoot, mergeTarget: mergeTarget)
        try Task.checkCancellation()
        guard context.isStillAuthorized(lease, scope: batch.scope, requiresMutationOwner: batch.request.operation.mutatesTarget) else {
            throw SessionAdminMCPToolService.unavailableError
        }
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
            "session_id": .string(lease.targetSessionID.uuidString), "merge": result,
            // A retry replays this outcome instead of prompting the user again.
            "changed_count": .int(1)
        ])
    }
}
