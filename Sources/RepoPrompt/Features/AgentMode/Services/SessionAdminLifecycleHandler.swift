import Foundation
import MCP
import RepoPromptDomainRuntime

/// `set_model`, `set_effort` (scope `control`) and `fork` (scope `spawn`).
///
/// Model and effort changes reuse the target's existing per-session commit seam (the same one
/// `agent_session_link set_model` routes to), with the scope lease standing in for the link lease at
/// the final reauthorization. `fork` is the ordinary Handoff/Fork migration into a background tab;
/// the fork joins the caller's scope by organizational placement, and the scope's spawn guardrails
/// were already evaluated by the core. Session deletion is human-only and has no operation here.
@MainActor
final class SessionAdminLifecycleHandler: AgentSessionAdministrationOperationHandler {
    let operations: Set<DomainAgentSessionTargetOperation> = [.adminSetModel, .adminSetEffort, .adminFork]

    /// Bounded replay ledger for `fork`, keyed by caller and idempotency key.
    static let maxForkReceipts = 256

    private struct ForkReceipt {
        let sourceSessionID: UUID
        let upToItemID: UUID?
        let forkedSessionID: UUID
        var joinedScope: Bool
        var failureCode: String?
        var failureDetail: String?
    }

    private let context: SessionAdminHandlerContext
    private let host: any SessionAdminStructureHost
    private var forkReceipts: [String: ForkReceipt] = [:]
    private var forkReceiptOrder: [String] = []
    private var forksInFlight: Set<String> = []

    init(context: SessionAdminHandlerContext, host: any SessionAdminStructureHost) {
        self.context = context
        self.host = host
    }

    func preflight(_ batch: AgentSessionAdministrationAuthorizedBatch) throws -> Value? {
        let args = batch.request.arguments
        switch batch.request.operation {
        case .adminSetModel:
            try SessionAdminArguments.requireOnly(["model_id"], in: args, op: "set_model")
            _ = try SessionAdminArguments.requiredString(args, "model_id", op: "set_model")
        case .adminSetEffort:
            try SessionAdminArguments.requireOnly(["effort"], in: args, op: "set_effort")
            _ = try SessionAdminArguments.requiredString(args, "effort", op: "set_effort")
        case .adminFork:
            try SessionAdminArguments.requireOnly(["up_to_item_id"], in: args, op: "fork")
            _ = try SessionAdminArguments.uuid(args, "up_to_item_id", op: "fork")
            guard batch.request.targetSessionIDs.count == 1 else {
                throw MCPError.invalidParams("session_admin fork takes exactly one session_id.")
            }
            guard batch.request.idempotencyKey != nil else {
                throw MCPError.invalidParams("session_admin fork requires idempotency_key.")
            }
        default:
            break
        }
        return nil
    }

    func perform(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        switch batch.request.operation {
        case .adminSetModel:
            let modelID = try SessionAdminArguments.requiredString(batch.request.arguments, "model_id", op: "set_model")
            return await apply(batch, op: "set_model") { [host] target, authorized in
                await host.setModel(sessionID: target, modelID: modelID, isStillAuthorized: authorized)
            }
        case .adminSetEffort:
            let effort = try SessionAdminArguments.requiredString(batch.request.arguments, "effort", op: "set_effort")
            return await apply(batch, op: "set_effort") { [host] target, authorized in
                await host.setEffort(sessionID: target, effort: effort, isStillAuthorized: authorized)
            }
        case .adminFork:
            return try await fork(batch)
        default:
            throw SessionAdminMCPToolService.notImplemented(batch.request.operation.rawValue)
        }
    }

    private func apply(
        _ batch: AgentSessionAdministrationAuthorizedBatch,
        op: String,
        effect: (UUID, @escaping @MainActor () -> Bool) async -> SessionAdminLifecycleOutcome
    ) async -> Value {
        var items: [SessionAdminItemResult] = []
        var authorityLost = false
        for lease in batch.leases {
            let target = lease.targetSessionID
            guard !authorityLost, context.isStillAuthorized(lease, scope: batch.scope, operation: batch.request.operation) else {
                authorityLost = true
                items.append(.revoked(target))
                continue
            }
            if batch.request.preview {
                items.append(SessionAdminItemResult(sessionID: target, result: "would_apply"))
                continue
            }
            let context = context
            let outcome = await effect(target) {
                context.isStillAuthorized(lease, scope: batch.scope, operation: batch.request.operation)
            }
            switch outcome {
            case let .applied(changed, fields):
                items.append(SessionAdminItemResult(
                    sessionID: target, result: changed ? "applied" : "unchanged",
                    fields: fields.mapValues(Value.string)
                ))
            case let .blocked(detail):
                items.append(SessionAdminItemResult(
                    sessionID: target, result: "not_applied", code: "target_unavailable", fields: ["detail": .string(detail)]
                ))
            case let .invalid(detail):
                items.append(SessionAdminItemResult(
                    sessionID: target, result: "not_applied", code: "invalid_value", fields: ["detail": .string(detail)]
                ))
            }
        }
        return SessionAdminReply.batch(
            op: op, items: items, requiresControl: batch.itemsRequiringControl, preview: batch.request.preview,
            extra: [AgentSessionAdminRendering.stateSatisfiedKey: .bool(true)]
        )
    }

    // MARK: - Fork

    private func fork(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        guard let lease = batch.leases.first, let caller = batch.request.caller.agentSessionID,
              let key = batch.request.idempotencyKey
        else { throw MCPError.invalidParams("session_admin fork requires session_id and idempotency_key.") }
        let source = lease.targetSessionID
        let upToItemID = try SessionAdminArguments.uuid(batch.request.arguments, "up_to_item_id", op: "fork")
        let ledgerKey = "\(caller.uuidString)|\(key)"
        if let receipt = forkReceipts[ledgerKey] {
            guard receipt.sourceSessionID == source, receipt.upToItemID == upToItemID else {
                return .object([
                    "result": .string("idempotency_conflict"),
                    "detail": .string("This idempotency_key is bound to a different fork; use a new key.")
                ])
            }
            return Self.forkValue(receipt, replayed: true)
        }
        if batch.request.preview {
            return .object(["result": .string("preview"), "op": .string("fork"), "session_id": .string(source.uuidString)])
        }
        guard forksInFlight.insert(ledgerKey).inserted else {
            return .object(["result": .string("in_progress"), "detail": .string("This fork is already being created.")])
        }
        defer { forksInFlight.remove(ledgerKey) }
        // The fork is placed under the caller, so it counts toward every scope a session the caller
        // spawns would join, not only the caller's own chain (which the core already checked).
        let evaluation = try DelegationSpawnAdmission.evaluate(
            DelegationSpawnAdmission.guardrailScopes(forCreator: caller, scopes: context.scopes, projector: context.projector),
            creator: caller, operation: .adminFork, scopes: context.scopes, projector: context.projector
        )
        if let denial = evaluation.denial {
            return try SessionAdminMCPToolService.deniedValue(denial, sessionID: nil)
        }
        // Reserved before the first suspension, right after the guardrail checks, so concurrent forks
        // and spawns cannot overshoot `maxLiveSessions`.
        let reservation = context.scopes.reserve(
            scopeIDs: Array(evaluation.scopeIDs.union(context.scopeChain(of: batch.scope).map(\.id))), sessions: 1
        )
        defer { context.scopes.release(reservation) }
        let context = context
        let forked: UUID
        var creationFailure: SessionAdminPartialForkError?
        do {
            forked = try await host.fork(sessionID: source, upToItemID: upToItemID) {
                context.isStillAuthorized(lease, scope: batch.scope)
            }
        } catch SessionAdminHostError.authorityEnded {
            return SessionAdminReply.batch(op: "fork", items: [.revoked(source)])
        } catch let partial as SessionAdminPartialForkError {
            forked = partial.sessionID
            creationFailure = partial
        }
        // Recorded as soon as the fork exists, so a retry after a later failure replays it instead
        // of forking twice; `joined_scope` is updated once placement settles.
        var receipt = ForkReceipt(
            sourceSessionID: source, upToItemID: upToItemID, forkedSessionID: forked, joinedScope: false,
            failureCode: creationFailure?.code, failureDetail: creationFailure?.detail
        )
        recordForkReceipt(receipt, key: ledgerKey)
        // The fork exists either way; only joining the scope needs live authority. An incomplete
        // first save cannot become a normal joined-scope success merely because placement can run.
        if creationFailure == nil, context.isStillAuthorized(lease, scope: batch.scope),
           context.isPlacedMember(caller, ofChainFrom: batch.scope)
        {
            do {
                let commit = try host.commitOrganizationalPlacement(
                    sessionID: forked, parentID: caller, delegationScopeID: batch.scope.id
                )
                receipt.joinedScope = commit != nil
                // Placement has committed in memory; preserve it even if its required save fails.
                if forkReceipts[ledgerKey] != nil { forkReceipts[ledgerKey] = receipt }
                context.scopes.release(reservation)
                try await commit?.persisted()
            } catch {
                receipt.failureCode = receipt.joinedScope ? "persist_failed" : "placement_failed"
                receipt.failureDetail = "The fork exists, but its scope placement did not complete: \(error.localizedDescription)"
            }
            if forkReceipts[ledgerKey] != nil { forkReceipts[ledgerKey] = receipt }
        }
        return Self.forkValue(receipt, replayed: false)
    }

    private func recordForkReceipt(_ receipt: ForkReceipt, key: String) {
        forkReceipts[key] = receipt
        forkReceiptOrder.append(key)
        while forkReceiptOrder.count > Self.maxForkReceipts {
            forkReceipts.removeValue(forKey: forkReceiptOrder.removeFirst())
        }
    }

    private static func forkValue(_ receipt: ForkReceipt, replayed: Bool) -> Value {
        var value: [String: Value] = [
            "result": .string(replayed ? "replayed" : (receipt.failureCode == nil ? "forked" : "partial")),
            "op": .string("fork"),
            "session_id": .string(receipt.sourceSessionID.uuidString),
            "forked_session_id": .string(receipt.forkedSessionID.uuidString),
            "joined_scope": .bool(receipt.joinedScope),
            "changed_count": .int(replayed ? 0 : 1)
        ]
        if let code = receipt.failureCode { value["code"] = .string(code) }
        if let detail = receipt.failureDetail { value["detail"] = .string(detail) }
        return .object(value)
    }
}
