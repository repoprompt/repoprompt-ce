import Foundation
import MCP
import RepoPromptDomainRuntime

/// The agent-only `session_admin` MCP surface.
///
/// The caller is the exact Agent-session endpoint resolved from server-owned run routing; no
/// argument can name or substitute it. Administrative principals and unresolved Agent runs never get
/// past caller resolution, independently of the catalog gate in `ServerNetworkManager`.
///
/// The scope lifecycle (`request_scope`, `scope_status`, `release_scope`) and `confirmation_status`
/// are handled here. `undo` and every other operation go through the administration service (in
/// production `AgentSessionAdministrationFrontDoor`), which returns `not_implemented` for operations
/// no handler has registered.
@MainActor
struct SessionAdminMCPToolService {
    typealias Endpoint = DomainAgentSessionLinkEndpointIdentity
    typealias ObserverEndpointResolver = AgentSessionTargetOperationGuard.ObserverEndpointResolver

    static let maxTargets = 256
    static let maxIdempotencyKeyUTF8Bytes = 200

    let captureRequestMetadata: () async -> MCPRequestMetadata
    let requireTargetWindow: @MainActor () throws -> WindowState
    let resolveObserverEndpoint: ObserverEndpointResolver
    let scopes: () -> DelegationScopeRuntime
    let administration: () -> any AgentSessionAdministrationService
    var now: () -> Date = Date.init
    var isToolEnabled: () -> Bool = { ToolAvailabilityStore.shared.isEnabled(MCPWindowToolName.sessionAdmin) }

    /// Identical for every unavailable caller, so the hidden tool reveals nothing when named.
    static let unavailableError = MCPError.invalidParams("session_admin is not available for this session.")

    private static let lifecycleKeys: [String: Set<String>] = [
        "request_scope": ["op", "kind", "workspace", "capabilities", "guardrails", "reason", "idempotency_key"],
        "scope_status": ["op", "scope_id", "request_id"],
        "release_scope": ["op", "scope_id"],
        "confirmation_status": ["op", "confirmation_id"],
        "undo": ["op", "undo_token"]
    ]

    /// Target selectors a scope-level operation reads (never authorized per target).
    private static let scopeLevelSelectorKeys: [String: Set<String>] = [
        "inventory": ["filter"],
        "tree": ["session_id"],
        "links": ["session_id"]
    ]

    func execute(args: [String: Value]) async throws -> Value {
        guard isToolEnabled() else { throw MCPError.invalidParams("session_admin is disabled.") }
        guard let op = AgentMCPToolHelpers.normalizedString(args["op"])?.lowercased(),
              MCPDomainSessionAdminToolDefinition.operations.contains(op)
        else {
            throw MCPError.invalidParams("session_admin op is required and must be one of the advertised operations.")
        }
        if let allowed = Self.lifecycleKeys[op] {
            for key in args.keys.sorted() where !allowed.contains(key) {
                throw MCPError.invalidParams("session_admin \(op) does not support '\(key)'.")
            }
        }

        let endpoint = try await resolveCaller()
        let caller = DomainAgentSessionCallerIdentity.agentSession(endpoint.sessionID)
        switch op {
        case "request_scope":
            return try requestScope(args: args, endpoint: endpoint)
        case "scope_status":
            return try scopeStatus(args: args, callerSessionID: endpoint.sessionID)
        case "release_scope":
            return try releaseScope(args: args, caller: caller)
        case "confirmation_status":
            return try confirmationStatus(args: args, callerSessionID: endpoint.sessionID)
        case "undo":
            return try await undo(args: args, caller: caller)
        default:
            return try await administer(op: op, args: args, caller: caller, endpoint: endpoint)
        }
    }

    // MARK: - Caller

    private func resolveCaller() async throws -> Endpoint {
        let metadata = await captureRequestMetadata()
        let window = try requireTargetWindow()
        guard !window.isClosing,
              let endpoint = await AgentSessionTargetOperationGuard.resolveObserverEndpoint(
                  metadata: metadata,
                  targetWindow: window,
                  resolveObserverEndpoint: resolveObserverEndpoint
              ),
              endpoint.hasResolvedPersistentBinding
        else { throw Self.unavailableError }
        return endpoint
    }

    // MARK: - request_scope

    private func requestScope(args: [String: Value], endpoint: Endpoint) throws -> Value {
        let kind: DomainDelegationScopeKind
        switch AgentMCPToolHelpers.normalizedString(args["kind"])?.lowercased() ?? "tree" {
        case "tree":
            guard args["workspace"] == nil else {
                throw MCPError.invalidParams("session_admin request_scope workspace applies only to kind=workspace.")
            }
            kind = .tree(rootSessionID: endpoint.sessionID)
        case "workspace":
            if let raw = args["workspace"] {
                guard let text = raw.stringValue, let workspaceID = UUID(uuidString: text) else {
                    throw MCPError.invalidParams("session_admin request_scope workspace must be a workspace UUID.")
                }
                // Conservative default: a session may only ask for its own workspace.
                guard workspaceID == endpoint.workspaceID else {
                    return .object([
                        "result": .string("invalid_request"),
                        "code": .string("workspace_not_own"),
                        "detail": .string("A workspace scope can only cover this session's own workspace.")
                    ])
                }
            }
            kind = .workspace(workspaceID: endpoint.workspaceID)
        case "all_sessions":
            guard args["workspace"] == nil else {
                throw MCPError.invalidParams("session_admin request_scope workspace applies only to kind=workspace.")
            }
            kind = .allSessions
        default:
            throw MCPError.invalidParams("session_admin request_scope kind must be tree, workspace, or all_sessions.")
        }

        let capabilities = try Self.parseCapabilities(args["capabilities"], kind: kind)
        let (guardrails, expiresInSeconds) = try Self.parseGuardrails(args["guardrails"])
        let reason = try Self.parseReason(args["reason"])
        let idempotencyKey = try Self.parseIdempotencyKey(args["idempotency_key"], required: false)

        let workspaceName: String? = if case let .workspace(workspaceID) = kind {
            DelegationDisplayNames.workspaceName(workspaceID)
        } else {
            nil
        }
        switch scopes().requestScope(
            requesterSessionID: endpoint.sessionID,
            requesterTabID: endpoint.tabID,
            kind: kind,
            capabilities: capabilities,
            guardrails: guardrails,
            expiresInSeconds: expiresInSeconds,
            reason: reason,
            idempotencyKey: idempotencyKey,
            requesterTitle: DelegationDisplayNames.sessionTitle(endpoint.sessionID),
            workspaceName: workspaceName
        ) {
        case let .success(request):
            var value = Self.requestValue(request)
            value["result"] = .string(request.state.label)
            if request.state == .pending {
                value["guidance"] = .string(
                    "Nothing is granted yet. The user sees an approval card in this session. Continue other work and check scope_status with this request_id; do not re-request."
                )
            }
            return .object(value)
        case let .failure(.invalid(denial)):
            return .object([
                "result": .string("invalid_request"),
                "code": .string(denial.diagnosticLabel)
            ])
        case .failure(.idempotencyConflict):
            return .object([
                "result": .string("idempotency_conflict"),
                "detail": .string("This idempotency_key was used for a different request; use a new key.")
            ])
        case .failure(.tooManyPending):
            return .object([
                "result": .string("too_many_pending"),
                "detail": .string("Wait for the user to decide an existing request before asking again.")
            ])
        }
    }

    // MARK: - scope_status

    private func scopeStatus(args: [String: Value], callerSessionID: UUID) throws -> Value {
        let runtime = scopes()
        if args["request_id"] != nil, args["scope_id"] != nil {
            throw MCPError.invalidParams("session_admin scope_status takes request_id or scope_id, not both.")
        }
        if let requestID = try Self.parseUUID(args["request_id"], field: "request_id") {
            guard let request = runtime.request(id: requestID, requesterSessionID: callerSessionID) else {
                throw Self.unavailableError
            }
            var value = Self.requestValue(request)
            value["result"] = .string(request.state.label)
            if case let .granted(scopeID) = request.state, let record = runtime.record(id: scopeID) {
                value["scope"] = Self.scopeValue(record, now: now())
            }
            return .object(value)
        }
        if let scopeID = try Self.parseUUID(args["scope_id"], field: "scope_id") {
            guard let record = runtime.record(id: scopeID), record.grant.granteeSessionID == callerSessionID else {
                throw Self.unavailableError
            }
            return .object(["result": .string("ok"), "scope": Self.scopeValue(record, now: now())])
        }
        let scopes = runtime.scopes(grantedTo: callerSessionID)
        return .object([
            "result": .string("ok"),
            "has_live_scope": .bool(runtime.hasLiveScope(grantedTo: callerSessionID)),
            "scopes": .array(scopes.map { Self.scopeValue($0, now: now()) })
        ])
    }

    // MARK: - release_scope

    private func releaseScope(args: [String: Value], caller: DomainAgentSessionCallerIdentity) throws -> Value {
        guard let callerSessionID = caller.agentSessionID else { throw Self.unavailableError }
        let runtime = scopes()
        let scopeID: UUID
        if let explicit = try Self.parseUUID(args["scope_id"], field: "scope_id") {
            scopeID = explicit
        } else {
            let live = runtime.liveScopes(grantedTo: callerSessionID)
            guard live.count == 1 else {
                return Self.scopeSelectionRequiredValue(live.map(\.id))
            }
            scopeID = live[0].id
        }
        switch runtime.release(scopeID: scopeID, caller: caller) {
        case let .success(changed):
            return .object([
                "result": .string(changed.isEmpty ? "already_inactive" : "released"),
                "scope_id": .string(scopeID.uuidString),
                "revoked_scope_ids": .array(changed.map { .string($0.id.uuidString) }),
                "detail": .string("Authority stops immediately. Sessions keep running and links stay until released.")
            ])
        case .failure:
            throw Self.unavailableError
        }
    }

    // MARK: - confirmation_status

    private func confirmationStatus(args: [String: Value], callerSessionID: UUID) throws -> Value {
        guard let confirmationID = try Self.parseUUID(args["confirmation_id"], field: "confirmation_id") else {
            throw MCPError.invalidParams("session_admin confirmation_status requires confirmation_id.")
        }
        guard let card = scopes().confirmations.confirmation(id: confirmationID, granteeSessionID: callerSessionID) else {
            throw Self.unavailableError
        }
        return withAppliedResult(Self.confirmationValue(card), confirmationID: card.id)
    }

    /// Adds the result of an apply-on-approval card, when the front door applied it.
    private func withAppliedResult(_ value: Value, confirmationID: UUID) -> Value {
        guard case var .object(object) = value,
              let frontDoor = administration() as? AgentSessionAdministrationFrontDoor,
              let result = frontDoor.appliedResult(forConfirmation: confirmationID)
        else { return value }
        object["applied_result"] = result
        return .object(object)
    }

    // MARK: - undo

    private func undo(args: [String: Value], caller: DomainAgentSessionCallerIdentity) async throws -> Value {
        guard let token = AgentMCPToolHelpers.normalizedString(args["undo_token"]) else {
            throw MCPError.invalidParams("session_admin undo requires undo_token.")
        }
        guard let frontDoor = administration() as? AgentSessionAdministrationFrontDoor else {
            throw Self.notImplemented("undo")
        }
        return try await render(
            frontDoor.undo(token: token, caller: caller),
            confirmationID: nil,
            callerSessionID: caller.agentSessionID ?? UUID()
        )
    }

    // MARK: - Administration ops

    private func administer(
        op: String,
        args: [String: Value],
        caller: DomainAgentSessionCallerIdentity,
        endpoint: Endpoint
    ) async throws -> Value {
        guard let operation = DomainAgentSessionTargetOperation(rawValue: "session_admin.\(op)") else {
            throw Self.notImplemented(op)
        }
        if operation.isScopeLevel {
            // Scope-level ops name no target. The only selectors they read are an inventory `filter`
            // and an optional `session_id` focus for `tree`/`links`, which their handlers check
            // against scope visibility; nothing is authorized per target.
            let allowed = Self.scopeLevelSelectorKeys[op] ?? []
            for key in ["targets", "session_id", "filter"] where args[key] != nil && !allowed.contains(key) {
                throw MCPError.invalidParams("session_admin \(op) names no target; '\(key)' is not supported.")
            }
        }
        let request = try AgentSessionAdministrationRequest(
            operation: operation,
            caller: caller,
            callerTabID: endpoint.tabID,
            scopeID: Self.parseUUID(args["scope_id"], field: "scope_id"),
            targetSessionIDs: Self.parseTargets(args),
            idempotencyKey: Self.parseIdempotencyKey(args["idempotency_key"], required: false),
            confirmationID: Self.parseUUID(args["confirmation_id"], field: "confirmation_id"),
            preview: Self.parsePreview(args["preview"]),
            arguments: args
        )
        return try await render(
            administration().perform(request),
            confirmationID: request.confirmationID,
            callerSessionID: endpoint.sessionID
        )
    }

    private func render(
        _ outcome: AgentSessionAdministrationOutcome,
        confirmationID: UUID?,
        callerSessionID: UUID
    ) throws -> Value {
        switch outcome {
        case let .completed(value):
            return value
        case let .pendingConfirmation(card, itemsRequiringControl):
            return withAppliedResult(
                Self.confirmationValue(card, itemsRequiringControl: itemsRequiringControl),
                confirmationID: card.id
            )
        case let .scopeSelectionRequired(scopeIDs):
            return Self.scopeSelectionRequiredValue(scopeIDs)
        case .idempotencyConflict:
            return .object([
                "result": .string("idempotency_conflict"),
                "detail": .string("This idempotency_key is bound to a different request; use a new key.")
            ])
        case .tooManyPendingConfirmations:
            return .object([
                "result": .string("too_many_pending"),
                "detail": .string("Wait for the user to decide your existing confirmation cards first.")
            ])
        case let .notImplemented(operation):
            throw Self.notImplemented(operation.rawValue)
        case .denied(.confirmationMismatch, _):
            // Recoverable for the card's own grantee: report what the user actually approved.
            let card = confirmationID.flatMap {
                scopes().confirmations.confirmation(id: $0, granteeSessionID: callerSessionID)
            }
            return Self.confirmationMismatchValue(card)
        case let .denied(denial, sessionID):
            return try Self.deniedValue(denial, sessionID: sessionID)
        }
    }

    static func confirmationMismatchValue(_ card: PendingBatchConfirmation?) -> Value {
        var value: [String: Value] = [
            "result": .string("denied"),
            "code": .string("confirmation_mismatch"),
            "detail": .string(
                "The approved card does not cover this call. Repeat the original call unchanged (same op, arguments, and idempotency_key) with confirmation_id, limited to approved_session_ids; changed arguments need a new card."
            )
        ]
        if let card {
            value["confirmation_id"] = .string(card.id.uuidString)
            value["approved_session_ids"] = .array(
                card.items.map(\.sessionID).filter(card.approvedSessionIDs.contains).map { .string($0.uuidString) }
            )
            value["state"] = confirmationValue(card).objectValue?["result"] ?? .null
        }
        return .object(value)
    }

    // MARK: - Rendering

    static func notImplemented(_ op: String) -> MCPError {
        MCPError.invalidParams("not_implemented: session_admin '\(op)' is not implemented yet in this build.")
    }

    /// Recoverable denials carry their stable code; every other denial is the uniform error.
    static func deniedValue(_ denial: DomainDelegationScopeDenial, sessionID: UUID?) throws -> Value {
        guard let code = denial.publicCode else {
            if let sessionID { throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID) }
            throw unavailableError
        }
        var value: [String: Value] = ["result": .string("denied"), "code": .string(code)]
        switch denial {
        case let .capabilityMissing(capability):
            value["capability"] = .string(capability.rawValue)
        case let .guardrailExceeded(guardrail, limit, current):
            value["guardrail"] = .string(guardrail.rawValue)
            value["limit"] = .int(limit)
            value["current"] = .int(current)
        case let .confirmationRequired(reason):
            value["reason"] = .string(reason.rawValue)
            value["detail"] = .string("Retry with an idempotency_key to raise one confirmation card for the user.")
        default:
            break
        }
        if let sessionID { value["session_id"] = .string(sessionID.uuidString) }
        return .object(value)
    }

    static func scopeSelectionRequiredValue(_ scopeIDs: [UUID]) -> Value {
        .object([
            "result": .string(scopeIDs.isEmpty ? "no_live_scope" : "scope_id_required"),
            "scope_ids": .array(scopeIDs.map { .string($0.uuidString) })
        ])
    }

    static func requestValue(_ request: DelegationScopeRequest) -> [String: Value] {
        var guardrails = guardrailsValue(request.guardrails)
        if let seconds = request.expiresInSeconds, case var .object(object) = guardrails {
            object["expires_in_seconds"] = .int(seconds)
            guardrails = .object(object)
        }
        var value: [String: Value] = [
            "request_id": .string(request.id.uuidString),
            "kind": .string(request.kind.label),
            "capabilities": capabilitiesValue(request.capabilities),
            "guardrails": guardrails
        ]
        if case let .denied(reason) = request.state, let reason {
            value["denial_reason"] = .string(reason)
        }
        return value
    }

    static func scopeValue(_ record: DomainDelegationScopeRecord, now: Date) -> Value {
        let expired = record.isActive && record.grant.guardrails.isExpired(at: now)
        var value: [String: Value] = [
            "scope_id": .string(record.id.uuidString),
            "state": .string(expired ? DomainDelegationScopeState.expired.rawValue : record.state.rawValue),
            "kind": .string(record.grant.kind.label),
            "capabilities": capabilitiesValue(record.grant.capabilities),
            "guardrails": guardrailsValue(record.grant.guardrails)
        ]
        switch record.grant.kind {
        case let .tree(rootSessionID):
            value["root_session_id"] = .string(rootSessionID.uuidString)
        case let .workspace(workspaceID):
            value["workspace_id"] = .string(workspaceID.uuidString)
        case .allSessions:
            break
        }
        if let parent = record.grant.parentScopeID {
            value["parent_scope_id"] = .string(parent.uuidString)
        }
        return .object(value)
    }

    /// Renders a card. `itemsRequiringControl` are running (or unknown-state) targets the operation
    /// would have to stop without `control`; they are reported per item and never carded or applied.
    static func confirmationValue(_ card: PendingBatchConfirmation, itemsRequiringControl: [UUID] = []) -> Value {
        let state = switch card.state {
        case .pending: "pending_confirmation"
        case .approved: "approved"
        case .applying: "applying"
        case .consumed: "applied"
        case .denied: "denied"
        case .invalidated: "invalidated"
        }
        var value: [String: Value] = [
            "result": .string(state),
            "confirmation_id": .string(card.id.uuidString),
            "op": .string(card.operation.rawValue),
            "reason": .string(card.reason.rawValue),
            "items": .array(card.items.map { item in
                .object([
                    "session_id": .string(item.sessionID.uuidString),
                    "title": .string(item.title),
                    "effect": .string(item.effect),
                    "approved": .bool(card.approvedSessionIDs.contains(item.sessionID))
                ])
            })
        ]
        if !itemsRequiringControl.isEmpty {
            value["requires_control"] = .array(itemsRequiringControl.map { .string($0.uuidString) })
        }
        return .object(value)
    }

    private static func capabilitiesValue(_ capabilities: Set<DomainDelegationScopeCapability>) -> Value {
        .array(DomainDelegationScopeCapability.allCases.filter(capabilities.contains).map { .string($0.rawValue) })
    }

    private static func guardrailsValue(_ guardrails: DomainDelegationScopeGuardrails) -> Value {
        var value: [String: Value] = [
            "bulk_confirmation_threshold": .int(guardrails.bulkConfirmationThreshold)
        ]
        if let limit = guardrails.maxLiveSessions { value["max_live_sessions"] = .int(limit) }
        if let limit = guardrails.maxDepth { value["max_depth"] = .int(limit) }
        if let limit = guardrails.maxWorktrees { value["max_worktrees"] = .int(limit) }
        if let expiresAt = guardrails.expiresAt {
            value["expires_at"] = .string(ISO8601DateFormatter().string(from: expiresAt))
        }
        return .object(value)
    }

    // MARK: - Parsing

    static func parseCapabilities(
        _ value: Value?,
        kind: DomainDelegationScopeKind
    ) throws -> Set<DomainDelegationScopeCapability> {
        guard let value else {
            if case .allSessions = kind { return DomainDelegationScopeCapability.organizeEverythingPreset }
            return DomainDelegationScopeCapability.manageTreePreset
        }
        guard let array = value.arrayValue, !array.isEmpty else {
            throw MCPError.invalidParams("session_admin capabilities must be a non-empty array.")
        }
        var result: Set<DomainDelegationScopeCapability> = []
        for element in array {
            guard let text = element.stringValue, let capability = DomainDelegationScopeCapability(rawValue: text) else {
                throw MCPError.invalidParams("session_admin capabilities contains an unknown capability.")
            }
            result.insert(capability)
        }
        return result
    }

    /// Parses proposed guardrails. The lifetime stays relative (`expires_in_seconds`) until the user
    /// approves, so an identical retry matches and a slow approval does not shorten the scope.
    static func parseGuardrails(_ value: Value?) throws -> (DomainDelegationScopeGuardrails, Int?) {
        guard let value else { return (DomainDelegationScopeGuardrails(), nil) }
        guard let object = value.objectValue else {
            throw MCPError.invalidParams("session_admin guardrails must be an object.")
        }
        let known: Set = [
            "max_live_sessions", "max_depth", "max_worktrees", "expires_in_seconds", "bulk_confirmation_threshold"
        ]
        for key in object.keys.sorted() where !known.contains(key) {
            throw MCPError.invalidParams("session_admin guardrails does not support '\(key)'.")
        }
        func integer(_ key: String, minimum: Int) throws -> Int? {
            guard let raw = object[key] else { return nil }
            guard let number = raw.intValue, number >= minimum else {
                throw MCPError.invalidParams("session_admin guardrails.\(key) must be an integer >= \(minimum).")
            }
            return number
        }
        let guardrails = try DomainDelegationScopeGuardrails(
            maxLiveSessions: integer("max_live_sessions", minimum: 0),
            maxDepth: integer("max_depth", minimum: 0),
            maxWorktrees: integer("max_worktrees", minimum: 0),
            bulkConfirmationThreshold: integer("bulk_confirmation_threshold", minimum: 1)
                ?? DomainDelegationScopeGuardrails.defaultBulkConfirmationThreshold
        )
        let expiresInSeconds = try integer("expires_in_seconds", minimum: DelegationScopeRuntime.minimumExpirySeconds)
        if let expiresInSeconds, expiresInSeconds > DelegationScopeRuntime.maximumExpirySeconds {
            throw MCPError.invalidParams(
                "session_admin guardrails.expires_in_seconds must be at most \(DelegationScopeRuntime.maximumExpirySeconds)."
            )
        }
        return (guardrails, expiresInSeconds)
    }

    /// `preview` must be a real boolean: a malformed value must never silently become a live call.
    static func parsePreview(_ value: Value?) throws -> Bool {
        guard let value else { return false }
        guard let flag = value.boolValue else {
            throw MCPError.invalidParams("session_admin preview must be a boolean.")
        }
        return flag
    }

    static func parseReason(_ value: Value?) throws -> String? {
        guard let value else { return nil }
        guard let text = value.stringValue else {
            throw MCPError.invalidParams("session_admin reason must be a string.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= DelegationScopeRuntime.maxReasonUTF8Bytes else {
            throw MCPError.invalidParams("session_admin reason exceeds \(DelegationScopeRuntime.maxReasonUTF8Bytes) UTF-8 bytes.")
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parseIdempotencyKey(_ value: Value?, required: Bool) throws -> String? {
        guard let value else {
            if required { throw MCPError.invalidParams("session_admin idempotency_key is required.") }
            return nil
        }
        guard let key = value.stringValue,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              key.utf8.count <= maxIdempotencyKeyUTF8Bytes
        else {
            throw MCPError.invalidParams("session_admin idempotency_key must be 1...\(maxIdempotencyKeyUTF8Bytes) UTF-8 bytes.")
        }
        return key
    }

    static func parseUUID(_ value: Value?, field: String) throws -> UUID? {
        guard let value else { return nil }
        guard let text = value.stringValue, let uuid = UUID(uuidString: text) else {
            throw MCPError.invalidParams("session_admin \(field) must be a UUID string.")
        }
        return uuid
    }

    static func parseTargets(_ args: [String: Value]) throws -> [UUID] {
        if args["session_id"] != nil, args["targets"] != nil {
            throw MCPError.invalidParams("session_admin takes session_id or targets, not both.")
        }
        if let single = try parseUUID(args["session_id"], field: "session_id") {
            return [single]
        }
        guard let raw = args["targets"] else { return [] }
        guard let array = raw.arrayValue, array.count <= maxTargets else {
            throw MCPError.invalidParams("session_admin targets must be an array of at most \(maxTargets) UUIDs.")
        }
        var seen: Set<UUID> = []
        var result: [UUID] = []
        for element in array {
            guard let text = element.stringValue, let uuid = UUID(uuidString: text), seen.insert(uuid).inserted else {
                throw MCPError.invalidParams("session_admin targets must contain unique UUID strings.")
            }
            result.append(uuid)
        }
        return result
    }
}
