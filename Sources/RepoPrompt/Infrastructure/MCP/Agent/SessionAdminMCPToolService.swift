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
/// A handler refusal that renders as a structured result (code, detail, next_call) instead of a
/// bare thrown error name.
protocol SessionAdminStructuredRefusal: Error {
    func refusalValue(op: String, targets: [UUID]) -> Value
}

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
    static let unavailableError = MCPError.invalidParams(
        "session_admin is not available for this session on this exact route. For one target, call become_overseer with session_id and optional message now: one exact-target approval automatically continues preparation, link and dispatch. session_admin scope_status discovers operations and grants when available. If already enabled, retry from the original requesting session; use request_scope for missing authority. A grant never substitutes for a current routed session."
    )

    static let inventoryGuidance = "Use covering grants directly. If authority is missing for cleanup or organizing, request observe together with needed mutation capabilities, then use inventory to select targets. A workspace scope covers only that workspace; history is not a scope inventory."

    private static let lifecycleKeys: [String: Set<String>] = [
        "request_scope": ["op", "kind", "workspace", "session_id", "capabilities", "guardrails", "reason", "idempotency_key"],
        "scope_status": ["op", "scope_id", "request_id"],
        "release_scope": ["op", "scope_id", "request_id"],
        "confirmation_status": ["op", "confirmation_id"],
        "undo": ["op", "undo_token"]
    ]

    /// Target selectors a scope-level operation reads (never authorized per target).
    private static let scopeLevelSelectorKeys: [String: Set<String>] = [
        "inventory": ["filter"],
        "tree": ["session_id"],
        "worktree_inventory": ["session_id"],
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
        let value: Value = switch op {
        case "request_scope":
            try requestScope(args: args, endpoint: endpoint)
        case "scope_status":
            try scopeStatus(args: args, callerSessionID: endpoint.sessionID)
        case "release_scope":
            try releaseScope(args: args, caller: caller)
        case "confirmation_status":
            try confirmationStatus(args: args, callerSessionID: endpoint.sessionID)
        case "undo":
            try await undo(args: args, caller: caller)
        default:
            try await administer(op: op, args: args, caller: caller, endpoint: endpoint)
        }
        guard case let .object(fields) = value else { return value }
        return Self.withScopeAvailability(fields, runtime: scopes(), includeContinuity: op == "scope_status")
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
        case "session":
            guard args["workspace"] == nil, let raw = args["session_id"]?.stringValue,
                  let target = UUID(uuidString: raw), target != endpoint.sessionID
            else {
                throw MCPError.invalidParams("session_admin request_scope kind=session needs one other session_id and no workspace selector.")
            }
            kind = .session(targetSessionID: target)
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
            throw MCPError.invalidParams("session_admin request_scope kind must be session, tree, workspace, or all_sessions.")
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
        case let .success(recorded):
            let runtime = scopes()
            // Standing user consent approves through the card's own path; no card is shown.
            let autoApproved = recorded.state == .pending && runtime.approveWithStandingConsent(requestID: recorded.id)
            let request = runtime.request(id: recorded.id, requesterSessionID: endpoint.sessionID) ?? recorded
            var value = Self.requestValue(request)
            value["result"] = .string(request.state.label)
            if case let .granted(scopeID) = request.state, let record = runtime.record(id: scopeID) {
                // The requested scope may be narrower than the authority that actually settled it.
                // Keep the proposal separate so it cannot be mistaken for the covering grant.
                let scope = Self.scopeValue(record, now: now())
                var requestedScope: [String: Value] = [:]
                for key in ["kind", "capabilities", "guardrails"] {
                    requestedScope[key] = value[key]
                    value[key] = scope.objectValue?[key]
                }
                value["requested_scope"] = .object(requestedScope)
                value["scope_id"] = .string(scopeID.uuidString)
                value["scope"] = scope
                if record.grant.unrestricted {
                    value["guidance"] = .string(
                        "Granted by Overseer full access; no card was shown. scope is the actual unrestricted covering grant, not the narrower requested_scope. Just call the operation."
                    )
                } else if autoApproved {
                    value["guidance"] = .string(
                        "Granted immediately by the user's standing consent for this session; no card was shown. scope describes the actual grant."
                    )
                }
            }
            if request.state == .pending {
                value["guidance"] = .string(
                    "Nothing is granted yet. The user sees an approval card in this session. Continue other work; RepoPrompt notifies this requesting session when the user decides (after its active turn settles). You can also check scope_status with this request_id; do not re-request. \(Self.inventoryGuidance)"
                )
            }
            return Self.withScopeAvailability(value, runtime: scopes())
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
            return Self.withScopeAvailability(value, runtime: runtime)
        }
        guard runtime.canUseAuthority else {
            return Self.withScopeAvailability(["result": .string("scope_authority_unavailable")], runtime: runtime)
        }
        if let scopeID = try Self.parseUUID(args["scope_id"], field: "scope_id") {
            guard let record = runtime.record(id: scopeID), record.grant.granteeSessionID == callerSessionID else {
                throw Self.unavailableError
            }
            return Self.withScopeAvailability(["result": .string("ok"), "scope": Self.scopeValue(record, now: now())], runtime: runtime)
        }
        let scopes = runtime.scopes(grantedTo: callerSessionID)
        return Self.withScopeAvailability([
            "result": .string("ok"),
            "has_live_scope": .bool(runtime.hasLiveScope(grantedTo: callerSessionID)),
            "scopes": .array(scopes.map { Self.scopeValue($0, now: now()) }),
            "operation_catalog": Self.operationCatalog(),
            "guidance": .string("Capabilities describe authority, not tool discovery. For a one-target task, become_overseer with session_id and optional message requests exactly the needed capabilities and continues automatically after approval, without waiting for catalog refresh. Other catalog changes may arrive next turn. A new link authorizes operations immediately on a current route. Use agent_session_link list for exact live link capabilities. Scope membership and guardrails are checked on every call.")
        ], runtime: runtime)
    }

    // MARK: - release_scope

    private func releaseScope(args: [String: Value], caller: DomainAgentSessionCallerIdentity) throws -> Value {
        guard let callerSessionID = caller.agentSessionID else { throw Self.unavailableError }
        let runtime = scopes()
        if args["request_id"] != nil, args["scope_id"] != nil {
            throw MCPError.invalidParams("session_admin release_scope takes request_id or scope_id, not both.")
        }
        if let requestID = try Self.parseUUID(args["request_id"], field: "request_id") {
            guard let before = runtime.request(id: requestID, requesterSessionID: callerSessionID),
                  let request = runtime.withdrawRequest(id: requestID, requesterSessionID: callerSessionID)
            else { throw Self.unavailableError }
            var value = Self.requestValue(request)
            if case .cancelled = request.state {
                value["result"] = .string(before.state == .pending ? "cancelled" : "already_cancelled")
                value["detail"] = .string("The pending request was withdrawn; no authority was granted.")
            } else {
                value["result"] = .string("request_not_pending")
                value["detail"] = .string("This request was already decided. Use scope_id to release a granted scope.")
            }
            return .object(value)
        }
        guard runtime.canUseAuthority else {
            return Self.withScopeAvailability(["result": .string("scope_authority_unavailable")], runtime: runtime)
        }
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
            return Self.withScopeAvailability([
                "result": .string(changed.isEmpty ? "already_inactive" : "released"),
                "scope_id": .string(scopeID.uuidString),
                "revoked_scope_ids": .array(changed.map { .string($0.id.uuidString) }),
                "detail": .string("Authority stops immediately. Sessions keep running and links stay until released.")
            ], runtime: runtime)
        case .failure:
            throw Self.unavailableError
        }
    }

    private static func withScopeAvailability(
        _ value: [String: Value], runtime: DelegationScopeRuntime, includeContinuity: Bool = false
    ) -> Value {
        var value = value
        value["authority_available"] = .bool(runtime.canUseAuthority)
        // Storage history is diagnostic context, not a warning on every successful operation.
        // Preserve it when authority is unavailable because it then affects this call.
        guard includeContinuity || !runtime.canUseAuthority else { return .object(value) }
        value["continuity_save_state"] = .string(runtime.continuityState)
        value["continuity_durable"] = .bool(runtime.continuityState == "saved")
        if !runtime.unsettledScopeIDs.isEmpty {
            value["unsettled_scope_ids"] = .array(runtime.unsettledScopeIDs.map { .string($0.uuidString) })
        }
        if let operationID = runtime.lastContinuityOperationID { value["continuity_operation_id"] = .string(operationID.uuidString) }
        if let message = runtime.persistenceStatusMessage {
            value["continuity_detail"] = .string(message)
        }
        return .object(value)
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
              let frontDoor = administration() as? AgentSessionAdministrationFrontDoor
        else { return value }
        if let result = frontDoor.appliedResult(forConfirmation: confirmationID) {
            object["applied_result"] = result
            // The stored receipt already combines exact item outcomes with captured selection coverage.
            if object["confirmation_state"] == .string("consumed"),
               let outcome = result.objectValue?["result"]?.stringValue
            {
                object["result"] = .string(outcome)
            }
        }
        if let selection = frontDoor.selectionCoverage(forConfirmation: confirmationID) {
            object["selection"] = selection
            if selection.objectValue?["records_complete"] == .bool(false) {
                object["selection_complete"] = .bool(false)
            }
        }
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
        let outcome: AgentSessionAdministrationOutcome
        do {
            outcome = try await administration().perform(request)
        } catch let error as any SessionAdminStructuredRefusal {
            return error.refusalValue(op: op, targets: request.targetSessionIDs)
        }
        return try render(
            outcome,
            confirmationID: request.confirmationID,
            callerSessionID: endpoint.sessionID,
            requestedScopeID: request.scopeID
        )
    }

    private func render(
        _ outcome: AgentSessionAdministrationOutcome,
        confirmationID: UUID?,
        callerSessionID: UUID,
        requestedScopeID: UUID? = nil
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
        case .denied(.usageProofMissing, _):
            if let requestedScopeID, scopes().record(id: requestedScopeID)?.grant.granteeSessionID != callerSessionID {
                throw Self.unavailableError
            }
            return .object([
                "result": .string("denied"), "code": .string("placement_unresolved"),
                "detail": .string("Your scope's configured limits require complete session placement evidence. Load or resolve ambiguous session bindings, then retry the same operation. Use session_admin scope_status to inspect limits. A new capability grant alone will not repair missing provenance.")
            ])
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
            // `adopt` cards list descendants outside the scope; the agent sees approved adoptees only.
            value["approved_session_ids"] = .array(
                SessionAdminAdoptCardProjection.agentApprovedSessionIDs(card).map { .string($0.uuidString) }
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
            // The caller is already resolved, so "not available on this route" would be false.
            // Name only the cases that disclose nothing about other sessions.
            let (code, detail, retryable) = switch denial {
            case .selfTarget:
                ("self_target", "This operation cannot target your own session.", false)
            case .generationStale:
                ("scope_changed", "Your scope changed while this call ran. Call scope_status, then retry.", true)
            case .operationNotScopeAuthorizable:
                ("operation_not_scope_authorizable", "No delegation scope can authorize this operation; it stays with the user.", false)
            default:
                ("not_authorized", "No current grant of yours covers this operation on its targets. If you hold no scope, call session_admin request_scope with the capabilities the operation needs; otherwise call scope_status for your grants and the operation catalog, and inventory to check the targets are in scope.", false)
            }
            return .object([
                "result": .string("denied"), "code": .string(code), "subreason": .string(code),
                "detail": .string(detail), "retryable": .bool(retryable),
                "next_call": .object(["tool": .string("session_admin"), "arguments": .object(["op": .string("scope_status")])])
            ])
        }
        var value: [String: Value] = ["result": .string("denied"), "code": .string(code)]
        switch denial {
        case let .capabilityMissing(capability):
            value["capability"] = .string(capability.rawValue)
            value["detail"] = .string("This scope lacks \(capability.rawValue). Request a new scope including \(capability.rawValue) by calling session_admin request_scope with all capabilities needed by the operation; wait for the user's approval. Call session_admin scope_status for the operation catalog and your current grants. \(inventoryGuidance)")
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

    /// Discovery is derived from the same operation identities used by authorization. It grants
    /// nothing; scope_status returns the caller's own grants beside this target-independent catalog.
    static func operationCatalog() -> Value {
        var rows: [Value] = MCPDomainSessionAdminToolDefinition.advertisedOperations.map { op in
            let operation = DomainAgentSessionTargetOperation(rawValue: "session_admin.\(op)")
            var required = operation?.requiredScopeCapabilities(for: .idle) ?? []
            if op == "link" { required.formUnion([.observe, .control]) }
            var row: [String: Value] = [
                "tool": .string("session_admin"), "op": .string(op),
                "scope_capabilities": capabilitiesValue(required)
            ]
            if op == "archive" || op == "retire" {
                row["when_running_also_requires"] = capabilitiesValue([.control])
            }
            return .object(row)
        }
        for operation in DomainAgentSessionTargetOperation.allCases where operation.rawValue.hasPrefix("agent_session_link.") {
            var row: [String: Value] = [
                "tool": .string("agent_session_link"),
                "op": .string(String(operation.rawValue.dropFirst("agent_session_link.".count)))
            ]
            if let capability = operation.requiredMonitorCapability {
                row["link_capability"] = .string(capability.rawValue)
            }
            if operation == .monitorCreateLane {
                // Authorized by overseer activation or a link, not by a scope capability. A live
                // scope only adds its guardrails (session/depth/worktree limits) to the creation.
                row["authority"] = .string("overseer_activation_or_link")
                row["guidance"] = .string("Needs overseer activation (become_overseer) or a link; no scope or spawn capability is required. Any live scope only adds its limits. This creates and links a lane without starting a turn unless message is supplied. Just call it.")
            }
            rows.append(.object(row))
        }
        for op in ["set_waiting_on", "request_attention"] {
            rows.append(.object([
                "tool": .string("agent_session_link"), "op": .string(op),
                "guidance": .string(op == "set_waiting_on" ? "Self-scoped waiting context; grants no authority." : "Needs an exact inbound link to the observer. Attention is not approval, authority or a reverse send grant.")
            ]))
        }
        rows.append(.object([
            "tool": .string("agent_run"), "op": .string("start"),
            "authority": .string("routed_agent_caller"),
            "guidance": .string("Creates a child session. Any routed Agent session may start one; no scope or spawn capability is required. Any live scope only adds its limits. Use session_admin fork to copy a member, or agent_session_link create_lane for a top-level managed lane.")
        ]))
        for operation in DomainAgentSessionTargetOperation.allCases where operation.rawValue.hasPrefix("agent_run.") {
            let op = String(operation.rawValue.dropFirst("agent_run.".count))
            rows.append(.object([
                "tool": .string("agent_run"), "op": .string(op),
                "authority": .string(operation == .runSteer ? "direct_child_or_exact_manage_link" : "direct_child"),
                "managed_target_tool": .string("agent_session_link"),
                "managed_target_op": .string(operation == .runCancel ? "stop" : op),
                "guidance": .string(
                    operation == .runSteer
                        ? "A managed target is forwarded to the exact-link steer transaction and requires Manage. A scope alone does not replace a link."
                        : "Child-session surface, not a scope inventory or raw transcript grant. For unrelated managed lanes use the named agent_session_link operation under an exact link; poll/wait need Watch, respond/stop need Manage."
                )
            ]))
        }
        return .array(rows)
    }

    static func scopeSelectionRequiredValue(_ scopeIDs: [UUID]) -> Value {
        var value: [String: Value] = [
            "result": .string(scopeIDs.isEmpty ? "no_live_scope" : "scope_id_required"),
            "scope_ids": .array(scopeIDs.map { .string($0.uuidString) })
        ]
        if scopeIDs.isEmpty {
            value["guidance"] = .string("Use request_scope to ask for user-approved authority. \(inventoryGuidance)")
        } else {
            value["guidance"] = .string("More than one scope could authorize this operation. Call session_admin scope_status, then repeat with the intended scope_id from scope_ids.")
        }
        return .object(value)
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
            "unrestricted": .bool(record.grant.unrestricted),
            "capabilities": capabilitiesValue(record.grant.capabilities),
            "guardrails": record.grant.unrestricted ? .object([:]) : guardrailsValue(record.grant.guardrails)
        ]
        switch record.grant.kind {
        case let .session(target):
            value["target_session_id"] = .string(target.uuidString)
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
        case .consumed: "consumed"
        case .denied: "denied"
        case .invalidated: "invalidated"
        }
        var value: [String: Value] = [
            "result": .string(state),
            "confirmation_id": .string(card.id.uuidString),
            "confirmation_state": .string(state),
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
        // Agent-facing only: an `adopt` card is projected to adoptee IDs and counts (the user's card
        // keeps the full subtree).
        return SessionAdminAdoptCardProjection.agentCardValue(card, rendered: .object(value))
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
            if case .session = kind { return [.observe, .control, .restructure] }
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
