import Foundation
import MCP
import RepoPromptDomainRuntime

/// `session_admin`'s entry point over `AgentSessionAdministrationCore` (design §2.5, §3.1).
///
/// The core keeps the single authority check and dispatch; this front door adds the call-shaping that
/// sits around it, without touching that check:
/// - `filter` → targets (loaded scope members only, capped at `maxTargets`),
/// - target derivation for ordered ops (`reorder_pins`, `reorder_groups`),
/// - `preview` (a dry run listing exact items and effects; never reaches a handler),
/// - idempotency for direct (uncarded) mutating calls,
/// - `undo` tokens, re-authorized as the original operation at redemption,
/// - apply-on-approval: when the user approves a batch card, the stored request is applied with the
///   exact same arguments, narrowed to the ticked items, and the result is kept for
///   `confirmation_status`.
///
/// All batch-card and projector usage for the organizing ops is localized here.
@MainActor
final class AgentSessionAdministrationFrontDoor: AgentSessionAdministrationService {
    static let maxRetainedResults = 256

    private let core: AgentSessionAdministrationCore
    private let scopes: DelegationScopeRuntime
    private let projector: any DelegationMembershipProjector
    private let inventory: any AgentSessionInventorySource
    private var handlers: [DomainAgentSessionTargetOperation: any AgentSessionAdministrationOperationHandler] = [:]
    private weak var undoer: (any AgentSessionAdministrationUndoing)?
    private var retainedHandlers: [any AgentSessionAdministrationOperationHandler] = []
    private var idempotency = DomainAgentSessionAdministrationIdempotencyLedger<Value>()
    /// Requests behind undecided cards, keyed by confirmation ID, for apply-on-approval.
    private var pendingApplies: [UUID: AgentSessionAdministrationRequest] = [:]
    private var appliedResults: [UUID: Value] = [:]
    private var appliedOrder: [UUID] = []

    init(
        core: AgentSessionAdministrationCore,
        scopes: DelegationScopeRuntime,
        projector: any DelegationMembershipProjector,
        inventory: any AgentSessionInventorySource
    ) {
        self.core = core
        self.scopes = scopes
        self.projector = projector
        self.inventory = inventory
    }

    static func production(core: AgentSessionAdministrationCore, scopes: DelegationScopeRuntime) -> AgentSessionAdministrationFrontDoor {
        let frontDoor = AgentSessionAdministrationFrontDoor(
            core: core,
            scopes: scopes,
            projector: SpawnProvenanceDelegationMembershipProjector(source: OpenWindowsDelegationProvenanceSource()),
            inventory: LiveAgentSessionInventorySource()
        )
        frontDoor.registerOrganizingHandlers(
            backend: OpenWindowsAgentSessionOrganizer(),
            links: BridgeAgentSessionLinkReleaser()
        )
        return frontDoor
    }

    /// Registers Lane B's inventory, organize, and release handlers on the core.
    func registerOrganizingHandlers(backend: any AgentSessionOrganizingBackend, links: any AgentSessionLinkReleasing) {
        let scopes = scopes
        let isLeaseCurrent: @MainActor (DomainDelegationScopeLease) -> Bool = { scopes.isCurrent($0) }
        register(AgentSessionInventoryOperationHandler(
            source: inventory,
            scopeChain: { scopes.scopeChain(from: $0) },
            isScopeCurrent: { record in
                scopes.record(id: record.id).map { $0.isActive && $0.generation == record.generation } ?? false
            },
            isLeaseCurrent: isLeaseCurrent
        ))
        let holdsControl: @MainActor (DomainDelegationScopeRecord) -> Bool = { [weak self] scope in
            self?.holdsControl(scope) ?? false
        }
        register(AgentSessionOrganizeOperationHandler(
            backend: backend,
            isLeaseCurrent: isLeaseCurrent,
            holdsControl: holdsControl
        ))
        register(AgentSessionReleaseOperationHandler(
            backend: backend,
            links: links,
            isLeaseCurrent: isLeaseCurrent,
            isMember: { [weak self] sessionID, scope in self?.isMember(sessionID, of: scope) ?? false },
            holdsControl: holdsControl
        ))
    }

    /// The scope is still the live generation it was and its whole chain holds `control`. Used when a
    /// target admitted as idle is found running before a stop or stash.
    func holdsControl(_ scope: DomainDelegationScopeRecord) -> Bool {
        guard let live = scopes.record(id: scope.id), live.isActive, live.generation == scope.generation else {
            return false
        }
        return chainHolds(.control, scope: live)
    }

    private func chainHolds(_ capability: DomainDelegationScopeCapability, scope: DomainDelegationScopeRecord) -> Bool {
        let chain = scopes.scopeChain(from: scope.id)
        return !chain.isEmpty && chain.allSatisfy { record in
            guard record.isActive, record.grant.capabilities.contains(capability) else { return false }
            if case .allSessions = record.grant.kind {
                return DomainDelegationScopeCapability.allSessionsPermitted.contains(capability)
            }
            return true
        }
    }

    // MARK: - AgentSessionAdministrationService

    func register(_ handler: any AgentSessionAdministrationOperationHandler) {
        core.register(handler)
        retainedHandlers.append(handler)
        for operation in handler.operations {
            handlers[operation] = handler
        }
        if let undoing = handler as? any AgentSessionAdministrationUndoing {
            undoer = undoing
        }
    }

    func authorize(_ request: AgentSessionAdministrationRequest) -> AgentSessionAdministrationAuthorization {
        core.authorize(request)
    }

    func perform(_ request: AgentSessionAdministrationRequest) async throws -> AgentSessionAdministrationOutcome {
        // Anything the front door cannot shape (no handler, no unique live scope, a non-Agent caller)
        // goes straight to the core, which owns every denial.
        guard handlers[request.operation] != nil,
              let callerSessionID = request.caller.agentSessionID,
              let scope = selectScope(request, callerSessionID: callerSessionID)
        else { return try await core.perform(request) }
        prunePendingApplies()

        let mutating = request.operation.mutatesTarget
        let fingerprint = Self.fingerprint(request, scopeID: scope.id)
        let directKey = mutating && !request.preview && request.confirmationID == nil ? request.idempotencyKey : nil
        if let directKey {
            switch idempotency.lookup(granteeSessionID: callerSessionID, idempotencyKey: directKey, fingerprint: fingerprint) {
            case let .replay(value): return .completed(Self.markReplay(value))
            case .conflict: return .idempotencyConflict
            case .miss: break
            }
        }

        var shaped = request.rebuilt(scopeID: scope.id)
        var unloadedItems: [AgentSessionAdminItemResult] = []
        if !request.operation.isScopeLevel {
            // A filter enumerates sessions, so it needs a live scope holding `observe` and the
            // operation's own capability before anything is resolved.
            if request.arguments["filter"] != nil, let denial = filterDenial(request.operation, scope: scope) {
                return .denied(denial, sessionID: nil)
            }
            do {
                if let targets = try await resolveTargets(shaped, scope: scope, callerSessionID: callerSessionID) {
                    guard !targets.isEmpty else {
                        return .completed(.object([
                            "result": .string("no_matching_sessions"),
                            "op": .string(request.operation.adminOperationName),
                            "items": .array([])
                        ]))
                    }
                    shaped = shaped.rebuilt(targets: targets)
                } else {
                    let split = await splitUnloadedTargets(shaped.targetSessionIDs, scope: scope)
                    unloadedItems = split.unloaded.map {
                        AgentSessionAdminItemResult(sessionID: $0, status: .skipped, reason: "workspace_not_loaded")
                    }
                    if !unloadedItems.isEmpty {
                        guard !split.remaining.isEmpty else {
                            return .completed(AgentSessionAdminRendering.mutationValue(
                                operation: request.operation,
                                items: unloadedItems,
                                itemsRequiringControl: [],
                                extra: ["workspace_not_loaded_detail": .string(Self.unloadedDetail)]
                            ))
                        }
                        shaped = shaped.rebuilt(targets: split.remaining)
                    }
                }
            } catch let early as AgentSessionAdminEarlyResult {
                return .completed(early.value)
            }
        }

        if shaped.preview, mutating {
            return preview(shaped)
        }

        var outcome = try await core.perform(shaped)
        if !unloadedItems.isEmpty, case let .completed(value) = outcome {
            outcome = .completed(Self.appending(unloadedItems, to: value))
        }
        switch outcome {
        case let .completed(value):
            // Only a call that changed something is replayable; a no-op or a refused ordering is
            // re-evaluated on retry, so the retry sees current state.
            if let directKey, Self.changedSomething(value) {
                idempotency.record(
                    granteeSessionID: callerSessionID, idempotencyKey: directKey, fingerprint: fingerprint, result: value
                )
            }
        case let .pendingConfirmation(card, _):
            if card.state == .pending, pendingApplies[card.id] == nil {
                pendingApplies[card.id] = shaped
            }
        default:
            break
        }
        return outcome
    }

    // MARK: - Undo

    /// Redeems an `undo_token`. The undo is re-authorized as the original operation over the
    /// original targets, so a revoked scope or a target that left the scope undoes nothing. Restoring
    /// the exact prior state of items the user already approved needs no second bulk card.
    func undo(token: String, caller: DomainAgentSessionCallerIdentity) async throws -> AgentSessionAdministrationOutcome {
        guard let callerSessionID = caller.agentSessionID else {
            return .denied(.callerNotAgentSession, sessionID: nil)
        }
        guard let undoer else { return .completed(Self.undoUnavailable) }
        switch undoer.redeemUndo(token: token, granteeSessionID: callerSessionID) {
        case .unavailable:
            return .completed(Self.undoUnavailable)
        case .expired:
            return .completed(.object([
                "result": .string("undo_expired"),
                "detail": .string("The undo window for this token has passed.")
            ]))
        case let .redeemed(entry):
            // Bound to the scope generation the call ran under: a re-generated scope undoes nothing.
            guard let live = scopes.record(id: entry.scopeID), live.isActive, live.generation == entry.scopeGeneration else {
                let state = scopes.record(id: entry.scopeID)?.state
                let denial: DomainDelegationScopeDenial = switch state {
                case .expired?: .expired
                case .revoked?: .revoked
                default: .generationStale
                }
                return .denied(denial, sessionID: nil)
            }
            let request = AgentSessionAdministrationRequest(
                operation: entry.payload.authorizationOperation(original: entry.operation),
                caller: caller,
                scopeID: entry.scopeID,
                targetSessionIDs: entry.targetSessionIDs
            )
            let outcome: AgentSessionAdministrationOutcome
            switch core.authorize(request) {
            case let .authorized(batch), let .confirmationRequired(.bulkThreshold, batch):
                return try await .completed(undoer.performUndo(entry, batch: batch))
            case let .confirmationRequired(reason, _):
                outcome = .denied(.confirmationRequired(reason: reason), sessionID: nil)
            case let .denied(denial, sessionID):
                outcome = .denied(denial, sessionID: sessionID)
            case let .scopeSelectionRequired(scopeIDs):
                outcome = .scopeSelectionRequired(scopeIDs: scopeIDs)
            }
            // A refused undo never burns its token.
            undoer.restoreUndo(entry)
            return outcome
        }
    }

    private static let undoUnavailable: Value = .object([
        "result": .string("undo_unavailable"),
        "detail": .string("This undo_token is unknown, already used, or not yours.")
    ])

    // MARK: - Apply on approval

    /// The user approved a card: apply its stored request with identical arguments, narrowed to the
    /// ticked items. Cards created outside this front door are only approved; their caller re-calls.
    func approveAndApply(confirmationID: UUID) async {
        prunePendingApplies()
        // An ordered change (pins, groups) is one permutation: it applies to every item or none.
        if let pending = pendingApplies[confirmationID],
           Self.orderedOperations.contains(pending.operation),
           let grantee = pending.caller.agentSessionID,
           let card = scopes.confirmations.confirmation(id: confirmationID, granteeSessionID: grantee),
           !card.untickedSessionIDs.isEmpty
        {
            scopes.confirmations.deny(confirmationID: confirmationID, reason: Self.orderedAllOrNothing)
            pendingApplies.removeValue(forKey: confirmationID)
            recordApplied(
                .object(["result": .string("denied"), "detail": .string(Self.orderedAllOrNothing)]),
                confirmationID: confirmationID
            )
            return
        }
        _ = scopes.confirmations.approve(confirmationID: confirmationID)
        guard let pending = pendingApplies.removeValue(forKey: confirmationID),
              let grantee = pending.caller.agentSessionID,
              let card = scopes.confirmations.confirmation(id: confirmationID, granteeSessionID: grantee),
              card.state == .approved
        else { return }
        let approved = card.approvedSessionIDs
        // Same arguments (and so the same arguments digest) as the carded call; only the targets
        // narrow to the ticked items.
        let request = pending.rebuilt(
            targets: pending.targetSessionIDs.filter(approved.contains),
            confirmationID: confirmationID
        )
        // The core claims the card (beginApplying/finishApplying) only when the authority still
        // requires one for the ticked items. When unticking brought the batch to or below the
        // threshold, the card is claimed here instead, so an approved card always ends `applied`
        // after a successful application (or returns to `approved` after a failed one).
        let coreClaims = scopes.record(id: card.scopeID).map { scope in
            DomainDelegationScopeAuthority.confirmationRequirement(
                operation: request.operation,
                itemCount: request.targetSessionIDs.count,
                guardrails: scope.grant.guardrails
            ) != nil
        } ?? true
        let claimedHere = !coreClaims && scopes.confirmations.beginApplying(confirmationID: confirmationID)
        let result: Value
        var succeeded = false
        do {
            switch try await core.perform(request) {
            case let .completed(value):
                result = value
                succeeded = true
            case let .denied(denial, sessionID):
                result = (try? SessionAdminMCPToolService.deniedValue(denial, sessionID: sessionID))
                    ?? .object(["result": .string("denied")])
            default:
                result = .object(["result": .string("not_applied")])
            }
        } catch {
            result = .object(["result": .string("failed"), "detail": .string(error.localizedDescription)])
        }
        if claimedHere {
            scopes.confirmations.finishApplying(confirmationID: confirmationID, succeeded: succeeded)
        } else if succeeded,
                  scopes.confirmations.confirmation(id: confirmationID, granteeSessionID: grantee)?.state == .approved,
                  scopes.confirmations.beginApplying(confirmationID: confirmationID)
        {
            // The run state changed between card and approval so neither side claimed it; settle it.
            scopes.confirmations.finishApplying(confirmationID: confirmationID, succeeded: true)
        }
        recordApplied(result, confirmationID: confirmationID)
    }

    func denyConfirmation(confirmationID: UUID) {
        scopes.confirmations.deny(confirmationID: confirmationID, reason: "Denied by user")
        pendingApplies.removeValue(forKey: confirmationID)
    }

    /// The applied result of an approved card, for `confirmation_status`.
    func appliedResult(forConfirmation confirmationID: UUID) -> Value? {
        appliedResults[confirmationID]
    }

    private func recordApplied(_ value: Value, confirmationID: UUID) {
        if appliedResults[confirmationID] == nil { appliedOrder.append(confirmationID) }
        appliedResults[confirmationID] = value
        while appliedOrder.count > Self.maxRetainedResults {
            appliedResults.removeValue(forKey: appliedOrder.removeFirst())
        }
    }

    static let orderedOperations: Set<DomainAgentSessionTargetOperation> = [.adminReorderPins, .adminReorderGroups]
    static let orderedAllOrNothing = "Ordered changes apply to every item or none; untick nothing, or deny the card."

    /// Drops stored requests whose card is no longer pending (decided, invalidated, or evicted).
    private func prunePendingApplies() {
        pendingApplies = pendingApplies.filter { scopes.confirmations.confirmations[$0.key]?.state == .pending }
    }

    // MARK: - Shaping

    private static let unloadedDetail =
        "Sessions in workspaces that no open window shows are listed but not changed; open the workspace to organize them."

    /// Filter targeting enumerates sessions: the scope must be live and hold `observe` plus the
    /// operation's idle-state capabilities before anything is resolved.
    private func filterDenial(
        _ operation: DomainAgentSessionTargetOperation,
        scope: DomainDelegationScopeRecord
    ) -> DomainDelegationScopeDenial? {
        let probe = AgentSessionAdministrationRequest(
            operation: .adminInventory,
            caller: .agentSession(scope.grant.granteeSessionID),
            scopeID: scope.id
        )
        if case let .denied(denial, _) = core.authorize(probe) { return denial }
        let required = operation.requiredScopeCapabilities(for: .idle).union([.observe])
        if let missing = DomainDelegationScopeCapability.allCases.first(where: {
            required.contains($0) && !chainHolds($0, scope: scope)
        }) {
            return .capabilityMissing(missing)
        }
        return nil
    }

    /// Explicit targets the projector cannot prove (it only sees loaded workspaces) that inventory
    /// shows as scope-visible sessions in an unloaded workspace are reported per item as
    /// `workspace_not_loaded`. Unknown or invisible targets stay in the batch, so the core's uniform
    /// denial still covers them. Needs `observe`, since it consults inventory.
    private func splitUnloadedTargets(
        _ targets: [UUID],
        scope: DomainDelegationScopeRecord
    ) async -> (remaining: [UUID], unloaded: [UUID]) {
        let unproven = targets.filter { !isMember($0, of: scope) }
        guard !unproven.isEmpty, chainHolds(.observe, scope: scope) else { return (targets, []) }
        let snapshot = await inventory.snapshot()
        let visibility = AgentSessionScopeVisibility(chain: scopes.scopeChain(from: scope.id))
        let unloaded = Set(unproven.filter { id in
            snapshot.records[id].map { !$0.isLoaded && visibility.isVisible($0, in: snapshot) } ?? false
        })
        return (targets.filter { !unloaded.contains($0) }, targets.filter(unloaded.contains))
    }

    private static func appending(_ items: [AgentSessionAdminItemResult], to value: Value) -> Value {
        guard case var .object(object) = value else { return value }
        object["items"] = .array((object["items"]?.arrayValue ?? []) + items.map(\.value))
        object["workspace_not_loaded_detail"] = .string(unloadedDetail)
        return .object(object)
    }

    static func changedSomething(_ value: Value) -> Bool {
        (value.objectValue?["changed_count"]?.intValue ?? 0) > 0
    }

    private func selectScope(_ request: AgentSessionAdministrationRequest, callerSessionID: UUID) -> DomainDelegationScopeRecord? {
        if let scopeID = request.scopeID {
            guard let record = scopes.record(id: scopeID), record.grant.granteeSessionID == callerSessionID else {
                return nil
            }
            return record
        }
        let live = scopes.liveScopes(grantedTo: callerSessionID)
        return live.count == 1 ? live[0] : nil
    }

    func isMember(_ sessionID: UUID, of scope: DomainDelegationScopeRecord) -> Bool {
        let chain = scopes.scopeChain(from: scope.id)
        return !chain.isEmpty && chain.allSatisfy { projector.membershipProof(for: sessionID, in: $0.grant) != nil }
    }

    /// `nil` keeps the request's explicit targets.
    private func resolveTargets(
        _ request: AgentSessionAdministrationRequest,
        scope: DomainDelegationScopeRecord,
        callerSessionID: UUID
    ) async throws -> [UUID]? {
        if let rawFilter = request.arguments["filter"] {
            guard request.targetSessionIDs.isEmpty else {
                throw AgentSessionAdminArguments.invalid("filter is exclusive with targets and session_id.")
            }
            guard let filter = try AgentSessionAdminArguments.filter(rawFilter) else { return nil }
            let full = await inventory.snapshot()
            // Filters see only the scope-restricted view, so link/role/orphan predicates can never
            // react to sessions outside the scope.
            let visibility = AgentSessionScopeVisibility(chain: scopes.scopeChain(from: scope.id))
            let snapshot = full.restricted(to: Set(
                full.records.values
                    .filter { visibility.isVisible($0, in: full) }
                    .map(\.sessionID)
            ))
            let now = Date()
            let excludeCaller = request.operation.deniesScopeSelfTarget
            let matches = snapshot.records.values
                .filter(\.isLoaded)
                .filter { filter.matchesStructured($0, in: snapshot, now: now) }
                .filter { AgentSessionInventoryRendering.matchesQuery(filter.query, record: $0) }
                .filter { !(excludeCaller && $0.sessionID == callerSessionID) }
                .filter { isMember($0.sessionID, of: scope) }
                .sorted { lhs, rhs in
                    if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
                    return lhs.sessionID.uuidString < rhs.sessionID.uuidString
                }
                .map(\.sessionID)
            guard matches.count <= AgentSessionAdminArguments.maxTargets else {
                throw AgentSessionAdminArguments.invalid(
                    "filter matched \(matches.count) sessions; at most \(AgentSessionAdminArguments.maxTargets) per call. Narrow the filter."
                )
            }
            return matches
        }
        guard request.targetSessionIDs.isEmpty,
              let deriving = handlers[request.operation] as? any AgentSessionAdministrationTargetDeriving,
              let derived = try deriving.derivedTargets(for: request)
        else { return nil }
        // Derived targets can include sessions the caller never named (every carrier of a group). Only
        // members are kept, so a denial can never name a session outside the scope; the handler refuses
        // an ordering that would also touch the rest.
        return derived.filter { isMember($0, of: scope) }
    }

    /// Dry run: exact items and effects, the confirmation requirement, and `requires_control`.
    private func preview(_ request: AgentSessionAdministrationRequest) -> AgentSessionAdministrationOutcome {
        let batch: AgentSessionAdministrationAuthorizedBatch
        var reason: DomainDelegationScopeConfirmationReason?
        switch core.authorize(request) {
        case let .authorized(authorized):
            batch = authorized
        case let .confirmationRequired(required, authorized):
            batch = authorized
            reason = required
        case let .denied(denial, sessionID):
            return .denied(denial, sessionID: sessionID)
        case let .scopeSelectionRequired(scopeIDs):
            return .scopeSelectionRequired(scopeIDs: scopeIDs)
        }
        let narrowed = request.rebuilt(targets: batch.admittedSessionIDs)
        let items = handlers[request.operation].map { $0.confirmationItems(for: narrowed, scope: batch.scope) }
            ?? narrowed.targetSessionIDs.map {
                BatchConfirmationItem(sessionID: $0, title: $0.uuidString, effect: request.operation.adminOperationName)
            }
        var object: [String: Value] = [
            "result": .string("preview"),
            "op": .string(request.operation.adminOperationName),
            "item_count": .int(items.count),
            "items": .array(items.map { item in
                .object([
                    "session_id": .string(item.sessionID.uuidString),
                    "title": .string(item.title),
                    "effect": .string(item.effect)
                ])
            }),
            "requires_confirmation": .bool(reason != nil)
        ]
        if let reason { object["confirmation_reason"] = .string(reason.rawValue) }
        if !batch.itemsRequiringControl.isEmpty {
            object["requires_control"] = .array(batch.itemsRequiringControl.map { .string($0.uuidString) })
        }
        return .completed(.object(object))
    }

    /// Canonical request identity for idempotency: operation, scope, explicit targets, and every
    /// argument except the transport-only ones.
    static func fingerprint(_ request: AgentSessionAdministrationRequest, scopeID: UUID) -> String {
        var args = request.arguments
        for key in ["idempotency_key", "preview", "confirmation_id", "scope_id"] {
            args.removeValue(forKey: key)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let argsText = (try? encoder.encode(Value.object(args))).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let targets = request.targetSessionIDs.map(\.uuidString).joined(separator: ",")
        return "\(request.operation.rawValue)|\(scopeID.uuidString)|\(targets)|\(argsText)"
    }

    private static func markReplay(_ value: Value) -> Value {
        guard case var .object(object) = value else { return value }
        object["idempotent_replay"] = .bool(true)
        return .object(object)
    }
}

extension AgentSessionAdministrationRequest {
    /// The same request with a different target list, scope, or confirmation. Arguments are never
    /// changed, so a card's bound arguments always reach the handler verbatim.
    func rebuilt(targets: [UUID]? = nil, scopeID: UUID? = nil, confirmationID: UUID? = nil) -> AgentSessionAdministrationRequest {
        AgentSessionAdministrationRequest(
            operation: operation,
            caller: caller,
            callerTabID: callerTabID,
            scopeID: scopeID ?? self.scopeID,
            targetSessionIDs: targets ?? targetSessionIDs,
            idempotencyKey: idempotencyKey,
            confirmationID: confirmationID ?? self.confirmationID,
            preview: preview,
            arguments: arguments
        )
    }
}
