import Foundation
import MCP
import RepoPromptDomainRuntime

/// One administration call, already parsed from its surface (MCP `session_admin`, `agent_run`, the
/// sidebar bulk dispatcher). Caller identity comes from server-owned routing; targets are only
/// *names* — membership is projected by the app, never trusted from here.
struct AgentSessionAdministrationRequest {
    let operation: DomainAgentSessionTargetOperation
    let caller: DomainAgentSessionCallerIdentity
    /// Where batch cards for this caller are shown.
    let callerTabID: UUID?
    /// Explicit scope selection; optional when the caller holds exactly one live scope.
    let scopeID: UUID?
    let targetSessionIDs: [UUID]
    let idempotencyKey: String?
    let confirmationID: UUID?
    let preview: Bool
    /// Operation-specific arguments for the registered handler.
    let arguments: [String: Value]

    init(
        operation: DomainAgentSessionTargetOperation,
        caller: DomainAgentSessionCallerIdentity,
        callerTabID: UUID? = nil,
        scopeID: UUID? = nil,
        targetSessionIDs: [UUID] = [],
        idempotencyKey: String? = nil,
        confirmationID: UUID? = nil,
        preview: Bool = false,
        arguments: [String: Value] = [:]
    ) {
        self.operation = operation
        self.caller = caller
        self.callerTabID = callerTabID
        self.scopeID = scopeID
        self.targetSessionIDs = targetSessionIDs
        self.idempotencyKey = idempotencyKey
        self.confirmationID = confirmationID
        self.preview = preview
        self.arguments = arguments
    }
}

/// Everything a handler needs after the single authority check passed.
struct AgentSessionAdministrationAuthorizedBatch {
    let request: AgentSessionAdministrationRequest
    let scope: DomainDelegationScopeRecord
    /// One lease per target, in request order. Empty for scope-level operations.
    let leases: [DomainDelegationScopeLease]
    let bases: [DomainAgentSessionAuthorityBasis]
    /// The approved card when one was required.
    let confirmation: DomainDelegationScopeConfirmation?
}

enum AgentSessionAdministrationAuthorization {
    case authorized(AgentSessionAdministrationAuthorizedBatch)
    case denied(DomainDelegationScopeDenial, sessionID: UUID?)
    /// The caller holds more than one live scope and named none.
    case scopeSelectionRequired(scopeIDs: [UUID])
}

enum AgentSessionAdministrationOutcome {
    case completed(Value)
    case pendingConfirmation(PendingBatchConfirmation)
    case denied(DomainDelegationScopeDenial, sessionID: UUID?)
    case scopeSelectionRequired(scopeIDs: [UUID])
    case idempotencyConflict
    case tooManyPendingConfirmations
    /// No handler is registered yet for this operation.
    case notImplemented(DomainAgentSessionTargetOperation)
}

/// Implements one or more administration operations. Lanes B and C register these; the core owns
/// authorization, so a handler only ever sees an already-authorized batch.
@MainActor
protocol AgentSessionAdministrationOperationHandler: AnyObject {
    var operations: Set<DomainAgentSessionTargetOperation> { get }
    /// Rows for a batch confirmation card. The default lists each target by ID.
    func confirmationItems(
        for request: AgentSessionAdministrationRequest,
        scope: DomainDelegationScopeRecord
    ) -> [BatchConfirmationItem]
    func perform(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value
}

extension AgentSessionAdministrationOperationHandler {
    func confirmationItems(
        for request: AgentSessionAdministrationRequest,
        scope _: DomainDelegationScopeRecord
    ) -> [BatchConfirmationItem] {
        request.targetSessionIDs.map {
            BatchConfirmationItem(sessionID: $0, title: $0.uuidString, effect: request.operation.rawValue)
        }
    }
}

/// The one shared service behind every administration surface (design §3.4).
@MainActor
protocol AgentSessionAdministrationService: AnyObject {
    /// The single authority check: scope liveness, membership, capability, guardrails, card.
    func authorize(_ request: AgentSessionAdministrationRequest) -> AgentSessionAdministrationAuthorization
    /// Authorizes, raises a batch card when required, and otherwise dispatches to the handler.
    func perform(_ request: AgentSessionAdministrationRequest) async throws -> AgentSessionAdministrationOutcome
    func register(_ handler: any AgentSessionAdministrationOperationHandler)
}

@MainActor
final class AgentSessionAdministrationCore: AgentSessionAdministrationService {
    private let scopes: DelegationScopeRuntime
    private let projector: any DelegationMembershipProjector
    private var handlersByOperation: [DomainAgentSessionTargetOperation: any AgentSessionAdministrationOperationHandler] = [:]

    init(
        scopes: DelegationScopeRuntime,
        projector: any DelegationMembershipProjector,
        handlers: [any AgentSessionAdministrationOperationHandler] = []
    ) {
        self.scopes = scopes
        self.projector = projector
        for handler in handlers {
            register(handler)
        }
    }

    func register(_ handler: any AgentSessionAdministrationOperationHandler) {
        for operation in handler.operations {
            // Scope-lifecycle ops are decided by the scope runtime itself, and human-only ops have no
            // capability; neither may be given a handler.
            precondition(!operation.isScopeLifecycle && operation.requiredScopeCapability != nil)
            handlersByOperation[operation] = handler
        }
    }

    func hasHandler(for operation: DomainAgentSessionTargetOperation) -> Bool {
        handlersByOperation[operation] != nil
    }

    func authorize(_ request: AgentSessionAdministrationRequest) -> AgentSessionAdministrationAuthorization {
        guard let callerSessionID = request.caller.agentSessionID else {
            return .denied(.callerNotAgentSession, sessionID: nil)
        }
        let scope: DomainDelegationScopeRecord
        if let scopeID = request.scopeID {
            // The authority checks grantee identity before disclosing anything about this scope.
            guard let record = scopes.record(id: scopeID) else { return .denied(.unknownScope, sessionID: nil) }
            scope = record
        } else {
            let live = scopes.liveScopes(grantedTo: callerSessionID)
            switch live.count {
            case 0: return .denied(.unknownScope, sessionID: nil)
            case 1: scope = live[0]
            default: return .scopeSelectionRequired(scopeIDs: live.map(\.id))
            }
        }

        // One proof per target for the scope and each ancestor: an attenuated scope never reaches a
        // session its parents could not.
        let chain = scopes.scopeChain(from: scope.id)
        var memberships: [UUID: [DomainDelegationScopeMembershipProof]] = [:]
        for target in request.targetSessionIDs {
            memberships[target] = chain.compactMap { projector.membershipProof(for: target, in: $0.grant) }
        }
        var usage: [UUID: DomainDelegationScopeUsage] = [:]
        if request.operation.scopeGuardrailUse != nil {
            for record in chain {
                usage[record.id] = projector.usage(
                    of: record.grant,
                    spawnParentSessionID: request.targetSessionIDs.first
                )
            }
        }
        let confirmation = request.confirmationID.flatMap {
            scopes.confirmations.confirmation(id: $0, granteeSessionID: callerSessionID)?.domainConfirmation
        }
        let outcome = scopes.authorize(DomainDelegationScopeAuthorizationRequest(
            operation: request.operation,
            caller: request.caller,
            scopeID: scope.id,
            presentedGeneration: scope.generation,
            targetSessionIDs: request.targetSessionIDs,
            memberships: memberships,
            usageByScopeID: usage,
            idempotencyKey: request.idempotencyKey,
            confirmation: confirmation
        ))
        switch outcome {
        case let .authorized(leases, bases):
            return .authorized(AgentSessionAdministrationAuthorizedBatch(
                request: request,
                scope: scope,
                leases: leases,
                bases: bases,
                confirmation: confirmation
            ))
        case let .denied(denial, sessionID):
            return .denied(denial, sessionID: sessionID)
        }
    }

    func perform(_ request: AgentSessionAdministrationRequest) async throws -> AgentSessionAdministrationOutcome {
        guard let handler = handlersByOperation[request.operation] else {
            return .notImplemented(request.operation)
        }
        switch authorize(request) {
        case let .scopeSelectionRequired(scopeIDs):
            return .scopeSelectionRequired(scopeIDs: scopeIDs)
        case let .denied(.confirmationRequired(reason), _) where !request.preview:
            guard let idempotencyKey = request.idempotencyKey,
                  let callerSessionID = request.caller.agentSessionID,
                  let scope = resolvedScope(for: request, callerSessionID: callerSessionID)
            else {
                return .denied(.confirmationRequired(reason: reason), sessionID: nil)
            }
            switch scopes.confirmations.request(
                scope: scope,
                operation: request.operation,
                idempotencyKey: idempotencyKey,
                granteeTabID: request.callerTabID,
                reason: reason,
                items: handler.confirmationItems(for: request, scope: scope)
            ) {
            case let .created(card), let .existing(card):
                return .pendingConfirmation(card)
            case .idempotencyConflict:
                return .idempotencyConflict
            case .tooManyPending:
                return .tooManyPendingConfirmations
            }
        case let .denied(denial, sessionID):
            return .denied(denial, sessionID: sessionID)
        case let .authorized(batch):
            // An approved card authorizes exactly one application; replays need a new card. The
            // handler re-checks `DelegationScopeRuntime.isCurrent(_:)` after its own suspensions.
            if let confirmationID = batch.confirmation?.confirmationID {
                scopes.confirmations.consume(confirmationID: confirmationID)
            }
            return try await .completed(handler.perform(batch))
        }
    }

    private func resolvedScope(
        for request: AgentSessionAdministrationRequest,
        callerSessionID: UUID
    ) -> DomainDelegationScopeRecord? {
        if let scopeID = request.scopeID { return scopes.record(id: scopeID) }
        let live = scopes.liveScopes(grantedTo: callerSessionID)
        return live.count == 1 ? live[0] : nil
    }
}
