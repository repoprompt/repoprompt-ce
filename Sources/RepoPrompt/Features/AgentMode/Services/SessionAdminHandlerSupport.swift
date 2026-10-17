import Foundation
import MCP
import RepoPromptDomainRuntime

/// Shared, app-presented facts the structural handlers need beyond the core's authorized batch.
///
/// Membership of *additional* sessions an operation names (a link observer, a re-parent
/// destination) is proven exactly like a target's: one projector proof per scope on the caller's
/// chain, validated by `DomainDelegationScopeAuthority.isValid`. It is never taken from arguments.
@MainActor
struct SessionAdminHandlerContext {
    let scopes: DelegationScopeRuntime
    let projector: any DelegationMembershipProjector
    /// Presentation-only session titles for card items.
    var displayName: @MainActor (UUID) -> String? = { _ in nil }

    /// The write-time checkpoint for one target (`OverseerAuthorizationEngine.checkpointTarget`).
    func isStillAuthorized(
        _ lease: DomainDelegationScopeLease, scope: DomainDelegationScopeRecord,
        requiresMutationOwner: Bool = true,
        operation: DomainAgentSessionTargetOperation? = nil
    ) -> Bool {
        scopes.authorization.checkpointTarget(
            lease, scope: scope, projector: projector, requiresMutationOwner: requiresMutationOwner, operation: operation
        )
    }

    /// The caller's scope and every ancestor scope.
    func scopeChain(of scope: DomainDelegationScopeRecord) -> [DomainDelegationScopeRecord] {
        scopes.scopeChain(from: scope.id)
    }

    /// Placement fact (never an authorization gate by itself): `sessionID` is placed in the chain.
    func isPlacedMember(_ sessionID: UUID, ofChainFrom scope: DomainDelegationScopeRecord) -> Bool {
        scopes.authorization.isPlacedMember(sessionID, ofChainFrom: scope, projector: projector)
    }

    /// Permission: the operation may reach `sessionID` through `scope` (`scopeMembership`).
    func permitsMember(_ sessionID: UUID, ofChainFrom scope: DomainDelegationScopeRecord) -> Bool {
        scopes.authorization.permitsMember(sessionID, ofChainFrom: scope, projector: projector)
    }

    func memberships(of sessionID: UUID, inChainFrom scope: DomainDelegationScopeRecord) -> [DomainDelegationScopeMembershipProof] {
        scopeChain(of: scope).compactMap { projector.membershipProof(for: sessionID, in: $0.grant) }
    }

    /// Requires the operation to be permitted to reach `sessionID`, else the uniform denial.
    func requireMember(_ sessionID: UUID, of batch: AgentSessionAdministrationAuthorizedBatch) throws {
        guard permitsMember(sessionID, ofChainFrom: batch.scope) else {
            throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID)
        }
    }

    /// The batch is still authorized: every lease's scope generation is current.
    func isCurrent(_ batch: AgentSessionAdministrationAuthorizedBatch) -> Bool {
        batch.leases.allSatisfy(scopes.isCurrent)
    }
}

/// Arguments common to every `session_admin` administration op (validated by the MCP service).
enum SessionAdminArguments {
    static let common: Set<String> = [
        "op", "scope_id", "session_id", "targets", "filter", "preview", "idempotency_key", "confirmation_id"
    ]

    static func requireOnly(_ allowed: Set<String>, in args: [String: Value], op: String) throws {
        let permitted = common.union(allowed)
        for key in args.keys.sorted() where !permitted.contains(key) {
            throw MCPError.invalidParams("session_admin \(op) does not support '\(key)'.")
        }
    }

    static func uuid(_ args: [String: Value], _ key: String, op: String) throws -> UUID? {
        guard let raw = args[key] else { return nil }
        guard let text = raw.stringValue, let uuid = UUID(uuidString: text) else {
            throw MCPError.invalidParams("session_admin \(op) \(key) must be a UUID string.")
        }
        return uuid
    }

    static func string(_ args: [String: Value], _ key: String, op: String, maxUTF8Bytes: Int = 1024) throws -> String? {
        guard let raw = args[key] else { return nil }
        guard let text = raw.stringValue else {
            throw MCPError.invalidParams("session_admin \(op) \(key) must be a string.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxUTF8Bytes else {
            throw MCPError.invalidParams("session_admin \(op) \(key) must be 1...\(maxUTF8Bytes) UTF-8 bytes.")
        }
        return trimmed
    }

    static func requiredString(_ args: [String: Value], _ key: String, op: String) throws -> String {
        guard let value = try string(args, key, op: op) else {
            throw MCPError.invalidParams("session_admin \(op) requires \(key).")
        }
        return value
    }

    static func bool(_ args: [String: Value], _ key: String, op: String) throws -> Bool? {
        guard let raw = args[key] else { return nil }
        guard let flag = raw.boolValue else {
            throw MCPError.invalidParams("session_admin \(op) \(key) must be a boolean.")
        }
        return flag
    }
}

/// One per-target row in a structural op's reply.
struct SessionAdminItemResult {
    let sessionID: UUID
    let result: String
    var code: String?
    var fields: [String: Value] = [:]

    /// The organizing ops' per-item vocabulary (`changed` / `unchanged` / `skipped` / `failed`), so one
    /// `items` array reads the same whichever lane produced a row (the front door appends its own
    /// `workspace_not_loaded` rows to these replies).
    var status: String {
        switch result {
        case "linked", "unlinked", "moved", "applied", "bound", "unbound", "released", "queued":
            "changed"
        case "already_linked", "not_linked", "nothing_bound", "unchanged":
            "unchanged"
        case "not_applied":
            (code?.hasSuffix("_failed") ?? false) ? "failed" : "skipped"
        default:
            result
        }
    }

    var isChange: Bool {
        status == "changed"
    }

    var value: Value {
        var object = fields
        object["session_id"] = .string(sessionID.uuidString)
        object["result"] = .string(result)
        object["status"] = .string(status)
        if let code {
            object["reason"] = .string(code)
            object = SessionAdminReply.diagnostic(code: code, sessionIDs: [sessionID], fields: object)
        }
        return .object(object)
    }

    static func revoked(_ sessionID: UUID) -> SessionAdminItemResult {
        SessionAdminItemResult(sessionID: sessionID, result: "not_applied", code: "scope_revoked")
    }
}

enum SessionAdminReply {
    static func batch(
        op: String,
        items: [SessionAdminItemResult],
        requiresControl: [UUID] = [],
        preview: Bool = false,
        extra: [String: Value] = [:]
    ) -> Value {
        var object = extra
        let statuses = items.compactMap { AgentSessionAdminItemResult.Status(rawValue: $0.status) }
        let committed = extra[AgentSessionAdminRendering.committedChangesKey] == .bool(true)
            || items.contains { $0.fields[AgentSessionAdminRendering.committedChangesKey] == .bool(true) }
        object["result"] = .string(preview ? "preview" : AgentSessionAdminRendering.mutationResult(
            statuses: statuses, requiresControl: !requiresControl.isEmpty, committedChanges: committed,
            alreadySatisfied: statuses.count == items.count && extra[AgentSessionAdminRendering.stateSatisfiedKey] == .bool(true)
        ))
        if object["result"] != .string("applied") { object.removeValue(forKey: AgentSessionAdminRendering.stateSatisfiedKey) }
        if committed { object[AgentSessionAdminRendering.committedChangesKey] = .bool(true) }
        object["op"] = .string(op)
        object["items"] = .array(items.map(\.value))
        // The front door's idempotency ledger records (and replays) only calls that changed something.
        object["changed_count"] = .int(preview ? 0 : items.count(where: \.isChange))
        if !requiresControl.isEmpty {
            object["requires_control"] = .array(requiresControl.map { .string($0.uuidString) })
        }
        return .object(preview ? object : AgentSessionAdminRendering.addingBatchDiagnostic(object))
    }

    /// Fill missing diagnostics without overwriting more precise host/transport evidence.
    static func diagnostic(code: String, sessionIDs: [UUID] = [], fields: [String: Value] = [:]) -> [String: Value] {
        let guidance = switch code {
        case "scope_revoked", "scope_no_longer_current":
            "Delegated authority ended before completion. Inspect scope_status and obtain current authority before another mutation."
        case "target_busy":
            "The target is busy. Wait until it is idle, or use worktree_bind with apply: next_boundary."
        case "scope_guardrail_exceeded":
            "The operation exceeds a configured scope limit. Inspect scope_status; release resources or ask the user to adjust that limit."
        case "usage_evidence_unavailable", "scope_denied":
            "A configured limit requires complete placement evidence. Resolve ambiguous session bindings or load the affected workspace, then retry. A new capability grant alone cannot repair this evidence."
        case "replicated_binding", "ambiguous_binding", "archived_carrier_unavailable", "not_restorable":
            "No unique writable archived carrier was proved. Inspect this session, open its workspace, and resolve duplicate or changed bindings before retrying undo; no ownership fence was bypassed."
        case "not_archived":
            "The current writable carrier is not archived. Inspect the session's current state; nothing was restored."
        case "compose_flush_rejected":
            "The active compose draft could not be flushed safely. Ask the user to save or resolve that draft before retrying undo."
        case "workspace_changed", "target_changed", "tab_id_conflict":
            "The workspace or tab carrier changed before restoration. Inspect the session and resolve conflicting tab identities before retrying undo."
        case "persistence_rejected", "persistence_unconfirmed":
            "The local restore changed state but its workspace save was not acknowledged. Inspect the current session and resolve the save failure; do not blindly repeat the mutation."
        case "workspace_writer_unavailable":
            "The groups are readable, but no current workspace writer could accept their order. Ask the user to resolve the workspace's save or duplicate-binding conflict, then inspect the groups again."
        case "group_state_changed", "group_projection_changed":
            "The workspace's group carriers or presentation changed while this request ran. Inspect the current group order before submitting another change; any committed_changes reported here remain committed."
        case "group_persistence_rejected", "group_persistence_unconfirmed", "group_save_incomplete":
            "The workspace owner could not confirm the complete group-order save. Inspect local_changes and committed_changes, resolve the workspace save failure, and read the current order before another mutation."
        case "no_change":
            "No item changed. Inspect current state before choosing another operation."
        default:
            "The requested operation did not fully complete. Inspect the item reason and current scope before choosing a recovery call."
        }
        let visibleIDs = sessionIDs + [fields["session_id"]?.stringValue.flatMap(UUID.init(uuidString:))].compactMap(\.self)
        var result: [String: Value] = [
            "code": .string(code), "subreason": .string(code), "detail": .string(guidance),
            "retryable": .bool(false),
            "affected": .object(["session_ids": .array(Array(Set(visibleIDs)).sorted { $0.uuidString < $1.uuidString }.map { .string($0.uuidString) })]),
            "next_call": .object(["tool": .string("session_admin"), "arguments": .object(["op": .string("scope_status")])])
        ]
        if code == "target_busy" { result["retryable"] = .bool(true) }
        // Nothing failed, so there is no recovery call to suggest.
        if code == "no_change" { result.removeValue(forKey: "next_call") }
        if ["workspace_writer_unavailable", "group_state_changed", "group_projection_changed", "group_persistence_rejected", "group_persistence_unconfirmed", "group_save_incomplete"].contains(code) {
            result.removeValue(forKey: "next_call")
            result["recovery"] = .string("manual")
        }
        if let sessionID = sessionIDs.first,
           ["replicated_binding", "ambiguous_binding", "archived_carrier_unavailable", "not_restorable", "not_archived", "compose_flush_rejected", "workspace_changed", "target_changed", "tab_id_conflict", "persistence_rejected", "persistence_unconfirmed"].contains(code)
        {
            result["next_call"] = .object(["tool": .string("session_admin"), "arguments": .object([
                "op": .string("get"), "session_id": .string(sessionID.uuidString)
            ])])
        }
        result.merge(fields, uniquingKeysWith: { _, supplied in supplied })
        return result
    }

    static func refused(code: String, detail: String, fields: [String: Value] = [:]) -> Value {
        var object = diagnostic(code: code, fields: fields)
        object["result"] = .string("denied")
        object["code"] = .string(code)
        object["detail"] = .string(detail)
        return .object(object)
    }

    static func placementRefusal(_ denial: DomainDelegationScopePlacementDenial, sessionID: UUID) -> Value {
        let detail = switch denial {
        case .cycle:
            "The destination is the session itself or one of its descendants."
        case .unresolved:
            "Part of an organizational chain is in a workspace no open window has loaded, so the move cannot be checked. Open that workspace first."
        case .affectsOtherScopes:
            "The move would change the membership of other delegation scopes; ask the user to restructure those sessions."
        case .adoptionRequiresUserGrantedScope:
            "Only a user-granted (not nested) scope may adopt sessions."
        case .adopteeAnchorsScope:
            "The session or one of its descendants holds or roots another delegation scope and cannot be adopted."
        }
        var fields: [String: Value] = ["session_id": .string(sessionID.uuidString)]
        if let count = denial.affectedScopeCount {
            // A count only: other scopes' identities are never disclosed to this caller.
            fields["affected_scope_count"] = .int(count)
        }
        return refused(code: denial.publicCode, detail: detail, fields: fields)
    }

    /// Encodes a `Codable` app result as a JSON `Value`.
    static func encoded(_ value: some Encodable) throws -> Value {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try JSONDecoder().decode(Value.self, from: encoder.encode(value))
    }
}
