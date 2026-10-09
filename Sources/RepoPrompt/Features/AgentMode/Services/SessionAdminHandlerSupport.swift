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

    /// The caller's scope and every ancestor scope.
    func scopeChain(of scope: DomainDelegationScopeRecord) -> [DomainDelegationScopeRecord] {
        scopes.scopeChain(from: scope.id)
    }

    func isMember(_ sessionID: UUID, ofChainFrom scope: DomainDelegationScopeRecord) -> Bool {
        let chain = scopeChain(of: scope)
        guard !chain.isEmpty else { return false }
        return chain.allSatisfy { record in
            guard let proof = projector.membershipProof(for: sessionID, in: record.grant) else { return false }
            return DomainDelegationScopeAuthority.isValid(proof, for: record.grant, targetSessionID: sessionID)
        }
    }

    func memberships(of sessionID: UUID, inChainFrom scope: DomainDelegationScopeRecord) -> [DomainDelegationScopeMembershipProof] {
        scopeChain(of: scope).compactMap { projector.membershipProof(for: sessionID, in: $0.grant) }
    }

    /// Requires `sessionID` to be a member of the whole chain, else the uniform denial.
    func requireMember(_ sessionID: UUID, of batch: AgentSessionAdministrationAuthorizedBatch) throws {
        guard isMember(sessionID, ofChainFrom: batch.scope) else {
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

    var value: Value {
        var object = fields
        object["session_id"] = .string(sessionID.uuidString)
        object["result"] = .string(result)
        if let code { object["code"] = .string(code) }
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
        object["result"] = .string(preview ? "preview" : "applied")
        object["op"] = .string(op)
        object["items"] = .array(items.map(\.value))
        if !requiresControl.isEmpty {
            object["requires_control"] = .array(requiresControl.map { .string($0.uuidString) })
        }
        return .object(object)
    }

    static func refused(code: String, detail: String, fields: [String: Value] = [:]) -> Value {
        var object = fields
        object["result"] = .string("denied")
        object["code"] = .string(code)
        object["detail"] = .string(detail)
        return .object(object)
    }

    static func placementRefusal(_ denial: DomainDelegationScopePlacementDenial, sessionID: UUID) -> Value {
        let detail = switch denial {
        case .cycle:
            "The destination is the session itself or one of its descendants."
        case .affectsOtherScopes:
            "The move would change the membership of other delegation scopes; ask the user to restructure those sessions."
        case .adoptionRequiresUserGrantedScope:
            "Only a user-granted (not nested) scope may adopt sessions."
        }
        var fields: [String: Value] = ["session_id": .string(sessionID.uuidString)]
        if !denial.affectedScopeIDs.isEmpty {
            fields["affected_scope_ids"] = .array(denial.affectedScopeIDs.map { .string($0.uuidString) })
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
