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

    /// Canonical digest of `arguments` that a batch card binds (targets, key, confirmation ID, scope,
    /// op, and preview excluded). Changed arguments under the same key can never ride an approval.
    var argumentsDigest: String {
        DomainDelegationScopeArgumentsDigest.digest(arguments)
    }

    /// The same request narrowed to `targets` (the admitted subset).
    func narrowed(to targets: [UUID]) -> AgentSessionAdministrationRequest {
        AgentSessionAdministrationRequest(
            operation: operation, caller: caller, callerTabID: callerTabID, scopeID: scopeID,
            targetSessionIDs: targets, idempotencyKey: idempotencyKey, confirmationID: confirmationID,
            preview: preview, arguments: arguments
        )
    }
}

/// Everything a handler needs after the single authority check passed.
struct AgentSessionAdministrationAuthorizedBatch {
    let request: AgentSessionAdministrationRequest
    let scope: DomainDelegationScopeRecord
    /// One lease per admitted target, in request order. Empty for scope-level operations. A handler
    /// acts on these targets only.
    let leases: [DomainDelegationScopeLease]
    let bases: [DomainAgentSessionAuthorityBasis]
    /// Targets the operation would have to stop without `control` (running or unknown state). The
    /// handler reports them per item as `requires_control` and must not act on them.
    let itemsRequiringControl: [UUID]
    /// The approved card when one was required.
    let confirmation: DomainDelegationScopeConfirmation?

    var admittedSessionIDs: [UUID] {
        leases.map(\.targetSessionID)
    }
}

enum AgentSessionAdministrationAuthorization {
    case authorized(AgentSessionAdministrationAuthorizedBatch)
    /// Steps 1–4 passed for the batch's admitted items; a card must be approved first.
    case confirmationRequired(DomainDelegationScopeConfirmationReason, AgentSessionAdministrationAuthorizedBatch)
    case denied(DomainDelegationScopeDenial, sessionID: UUID?)
    /// The caller holds more than one live scope and named none.
    case scopeSelectionRequired(scopeIDs: [UUID])
}

enum AgentSessionAdministrationOutcome {
    case completed(Value)
    /// One card for the admitted items; `itemsRequiringControl` were set aside, not carded.
    case pendingConfirmation(PendingBatchConfirmation, itemsRequiringControl: [UUID])
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
    /// Synchronous, operation-specific validation after the authority admitted the batch and
    /// **before** any batch card is raised or the handler runs. A non-nil value is returned to the
    /// caller as-is, so a structurally refused request never reaches the user's card.
    func preflight(_ batch: AgentSessionAdministrationAuthorizedBatch) throws -> Value?
}

extension AgentSessionAdministrationOperationHandler {
    func preflight(_: AgentSessionAdministrationAuthorizedBatch) -> Value? {
        nil
    }

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
        var targetStates: [UUID: DomainDelegationScopeTargetState] = [:]
        for target in request.targetSessionIDs {
            targetStates[target] = projector.targetState(for: target)
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
            targetStates: targetStates,
            argumentsDigest: request.argumentsDigest,
            idempotencyKey: request.idempotencyKey,
            confirmation: confirmation
        ))
        func batch(_ items: DomainDelegationScopeAuthorizedItems) -> AgentSessionAdministrationAuthorizedBatch {
            AgentSessionAdministrationAuthorizedBatch(
                request: request,
                scope: scope,
                leases: items.leases,
                bases: items.bases,
                itemsRequiringControl: items.itemsRequiringControl,
                confirmation: confirmation
            )
        }
        switch outcome {
        case let .authorized(items):
            return .authorized(batch(items))
        case let .confirmationRequired(reason, items):
            return .confirmationRequired(reason, batch(items))
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
        case let .confirmationRequired(reason, pending):
            if let refusal = try handler.preflight(pending) { return .completed(refusal) }
            // Lane B owns preview rendering; until then a preview reports the requirement only.
            guard !request.preview, let idempotencyKey = request.idempotencyKey else {
                return .denied(.confirmationRequired(reason: reason), sessionID: nil)
            }
            // The card lists exactly the admitted items; `requires_control` items are reported, not carded.
            switch scopes.confirmations.request(
                scope: pending.scope,
                operation: request.operation,
                idempotencyKey: idempotencyKey,
                granteeTabID: request.callerTabID,
                reason: reason,
                items: handler.confirmationItems(for: request.narrowed(to: pending.admittedSessionIDs), scope: pending.scope),
                argumentsDigest: request.argumentsDigest
            ) {
            case let .created(card), let .existing(card):
                return .pendingConfirmation(card, itemsRequiringControl: pending.itemsRequiringControl)
            case .idempotencyConflict:
                return .idempotencyConflict
            case .tooManyPending:
                return .tooManyPendingConfirmations
            }
        case let .denied(denial, sessionID):
            return .denied(denial, sessionID: sessionID)
        case let .authorized(batch):
            // Structural refusals are decided before any card is claimed, exactly as before a card
            // is raised in the branch above.
            if let refusal = try handler.preflight(batch) { return .completed(refusal) }
            // Only a card the authority actually required is claimed: an approved card authorizes
            // exactly one application, claimed before the handler suspends (so a concurrent replay
            // cannot double-apply) and marked applied only after the handler succeeds. The handler
            // re-checks `DelegationScopeRuntime.isCurrent(_:)` after its own suspensions.
            let cardRequired = DomainDelegationScopeAuthority.confirmationRequirement(
                operation: request.operation,
                itemCount: batch.admittedSessionIDs.count,
                guardrails: batch.scope.grant.guardrails
            ) != nil && !batch.admittedSessionIDs.isEmpty
            let claimedCard = cardRequired ? batch.confirmation?.confirmationID : nil
            if let claimedCard, !scopes.confirmations.beginApplying(confirmationID: claimedCard) {
                return .denied(.confirmationMismatch, sessionID: nil)
            }
            do {
                let value = try await handler.perform(batch)
                if let claimedCard { scopes.confirmations.finishApplying(confirmationID: claimedCard, succeeded: true) }
                return .completed(value)
            } catch {
                if let claimedCard { scopes.confirmations.finishApplying(confirmationID: claimedCard, succeeded: false) }
                throw error
            }
        }
    }
}
