import Foundation
import MCP
import RepoPromptDomainRuntime

/// One field a reversible organize call changed: the value before, and the value the call wrote.
enum AgentSessionOrganizeFieldChange: Equatable {
    case name(before: String, after: String)
    case pinned(before: Bool, beforeRank: Int?, after: Bool)
    /// Pin rank only (reorders and rank materialization).
    case pinRank(before: Int?, after: Int?)
    case group(before: String?, beforeOrder: Int?, after: String?, afterOrder: Int?)
    /// Group order value only, qualified by the group whose order changed.
    case groupOrder(group: String, before: Int?, after: Int?)
}

struct AgentSessionOrganizeFieldRestore: Equatable {
    let sessionID: UUID
    let change: AgentSessionOrganizeFieldChange
}

/// What `undo` restores for one reversible organize call.
enum AgentSessionOrganizeUndoPayload {
    /// Exactly the fields the call changed. Each is restored only while it still holds the value the
    /// call wrote, and only on a session the undo holds its own lease for.
    case fields([AgentSessionOrganizeFieldRestore])
    /// Undo of `archive`.
    case unarchive([UUID])
    /// Undo of `unarchive`; authorized as `archive` (state-dependent).
    case archive([UUID])

    /// The operation an undo is re-authorized as.
    func authorizationOperation(original: DomainAgentSessionTargetOperation) -> DomainAgentSessionTargetOperation {
        if case .archive = self { return .adminArchive }
        return original
    }
}

/// Thrown by target derivation when the call ends with a result rather than a batch.
struct AgentSessionAdminEarlyResult: Error {
    let value: Value
}

/// Handlers that can turn a request with no explicit targets into the targets it acts on.
@MainActor
protocol AgentSessionAdministrationTargetDeriving: AnyObject {
    /// `nil` when the operation does not derive targets.
    func derivedTargets(for request: AgentSessionAdministrationRequest) throws -> [UUID]?
}

/// Handlers whose calls can be undone with an `undo_token`.
@MainActor
protocol AgentSessionAdministrationUndoing: AnyObject {
    typealias UndoEntry = DomainAgentSessionAdministrationUndoLedger<AgentSessionOrganizeUndoPayload>.Entry
    func redeemUndo(token: String, granteeSessionID: UUID) -> DomainAgentSessionAdministrationUndoLedger<AgentSessionOrganizeUndoPayload>.Redeem
    func performUndo(_ entry: UndoEntry, batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value
    /// Puts back a token whose undo was refused, so a denial never burns it.
    func restoreUndo(_ entry: UndoEntry)
}

/// `rename`, `set_pin`, `reorder_pins`, `set_group`, `reorder_groups`, `archive`, `unarchive`.
///
/// Every effect is derived from `request.arguments`. Each mutation re-checks its target's scope lease
/// immediately before it runs. Archive and unarchive also recheck at their asynchronous boundaries.
@MainActor
final class AgentSessionOrganizeOperationHandler: AgentSessionAdministrationOperationHandler,
    AgentSessionAdministrationTargetDeriving, AgentSessionAdministrationUndoing
{
    let operations: Set<DomainAgentSessionTargetOperation> = [
        .adminRename, .adminSetPin, .adminReorderPins, .adminSetGroup, .adminReorderGroups,
        .adminArchive, .adminUnarchive
    ]

    private let backend: any AgentSessionOrganizingBackend
    private let isLeaseCurrent: @MainActor (DomainDelegationScopeLease) -> Bool
    private let isGroupOrderLeaseCurrent: @MainActor (DomainDelegationScopeLease) -> Bool
    /// Whether the scope is still live and its whole chain holds `control`, for targets that turned
    /// out not to be idle when re-read.
    private let holdsControl: @MainActor (DomainDelegationScopeRecord) -> Bool
    private let holdsObserve: @MainActor (DomainDelegationScopeRecord) -> Bool
    private let now: () -> Date
    private let makeToken: () -> String
    private var undoLedger: DomainAgentSessionAdministrationUndoLedger<AgentSessionOrganizeUndoPayload>

    init(
        backend: any AgentSessionOrganizingBackend,
        isLeaseCurrent: @escaping @MainActor (DomainDelegationScopeLease) -> Bool,
        holdsControl: @escaping @MainActor (DomainDelegationScopeRecord) -> Bool,
        holdsObserve: @escaping @MainActor (DomainDelegationScopeRecord) -> Bool = { _ in false },
        isGroupOrderLeaseCurrent: (@MainActor (DomainDelegationScopeLease) -> Bool)? = nil,
        now: @escaping () -> Date = Date.init,
        makeToken: @escaping () -> String = { UUID().uuidString },
        undoLifetime: TimeInterval = 15 * 60
    ) {
        self.backend = backend
        self.isLeaseCurrent = isLeaseCurrent
        self.isGroupOrderLeaseCurrent = isGroupOrderLeaseCurrent ?? isLeaseCurrent
        self.holdsControl = holdsControl
        self.holdsObserve = holdsObserve
        self.now = now
        self.makeToken = makeToken
        undoLedger = DomainAgentSessionAdministrationUndoLedger(lifetime: undoLifetime)
    }

    // MARK: - Target derivation

    func derivedTargets(for request: AgentSessionAdministrationRequest) throws -> [UUID]? {
        switch request.operation {
        case .adminReorderPins:
            guard let order = try AgentSessionAdminArguments.uuids(request.arguments, "order") else {
                throw AgentSessionAdminArguments.invalid("reorder_pins requires order (pinned session UUIDs).")
            }
            return order
        case .adminReorderGroups:
            let (workspaceID, order) = try groupReorderArguments(request.arguments)
            guard let entries = backend.groupEntries(workspaceID: workspaceID) else {
                throw AgentSessionAdminEarlyResult(value: Self.workspaceNotLoaded(workspaceID))
            }
            let named = Set(order)
            let members = entries.filter { named.contains($0.group) }.map(\.sessionID)
            if entries.isEmpty, order.isEmpty, request.arguments["order"] != nil,
               request.arguments["expected_order"] == nil
            {
                throw AgentSessionAdminArguments.invalid("reorder_groups requires expected_order.")
            }
            if entries.isEmpty, order.isEmpty,
               let expected = try AgentSessionAdminArguments.strings(request.arguments, "expected_order"),
               !expected.isEmpty
            {
                throw AgentSessionAdminEarlyResult(value: Self.orderingFailure(
                    .orderSetMismatch, operation: request.operation.adminOperationName,
                    arguments: request.arguments, scopeID: request.scopeID
                ))
            }
            if entries.isEmpty, request.arguments["order"] == nil || !order.isEmpty {
                // An empty workspace has no names to disclose or carriers to authorize. The
                // follow-up with two empty arrays completes as no_matching_sessions, never applied.
                throw AgentSessionAdminEarlyResult(value: recovery(
                    request, workspaceID: workspaceID, order: [], expected: [],
                    code: request.arguments["order"] == nil ? "order_required" : "groups_not_found"
                ))
            }
            // Unknown names need the same authorized discovery as a missing order. Do not leak
            // the workspace's current names from target derivation before the core admits them.
            return members.isEmpty && !order.isEmpty ? entries.map(\.sessionID) : members
        default:
            return nil
        }
    }

    // MARK: - Cards and preview

    /// Recovery discloses current group names only after authorization covers their carriers.
    /// Incomplete arguments must not create a confirmation card or reach the mutating handler.
    func preflight(_ batch: AgentSessionAdministrationAuthorizedBatch) throws -> Value? {
        let request = batch.request
        guard request.operation == .adminReorderGroups,
              request.confirmationID == nil
        else { return nil }
        let (workspaceID, order): (UUID, [String])
        do {
            (workspaceID, order) = try groupReorderArguments(request.arguments)
        } catch let early as AgentSessionAdminEarlyResult {
            return early.value
        }
        guard let entries = backend.groupEntries(workspaceID: workspaceID) else {
            return Self.workspaceNotLoaded(workspaceID)
        }
        let named = Set(order)
        let unknownGroups = !order.isEmpty && !entries.contains { named.contains($0.group) }
        let affected = entries.filter { unknownGroups || named.contains($0.group) }.map(\.sessionID)
        guard Set(affected).isSubset(of: Set(batch.admittedSessionIDs)) else {
            return .object(SessionAdminReply.diagnostic(code: "groups_outside_scope", fields: [
                "result": .string("groups_outside_scope"),
                "affected": .object(["workspace_id": .string(workspaceID.uuidString)]),
                "detail": .string("Every session in the reordered groups must be in your scope; reorder only groups you fully cover, or ask the user for authority covering the workspace.")
            ]))
        }
        let current = DomainAgentSessionSidebarGroup.orderedGroups(entries.map { ($0.group, $0.order) })
        if unknownGroups {
            // A complete request for unknown names is discovery too: organize authority over
            // carriers does not grant observe over their current names or the wider scope chain.
            guard holdsObserve(batch.scope) else {
                return try SessionAdminMCPToolService.deniedValue(.capabilityMissing(.observe), sessionID: nil)
            }
            return recovery(request, workspaceID: workspaceID, order: current, expected: current, code: "groups_not_found")
        }
        // Complete valid requests retain their ordinary preview/confirmation/mutation path.
        guard request.arguments["order"] == nil || request.arguments["expected_order"] == nil else { return nil }
        let expected = current.filter(named.contains)
        if case let .failure(error) = DomainAgentSessionOrdering.permute(
            current: current, expected: expected, desired: order, describe: { $0 }
        ) {
            return Self.orderingFailure(error, operation: request.operation.adminOperationName, arguments: request.arguments, scopeID: batch.scope.id)
        }
        return recovery(request, workspaceID: workspaceID, order: order, expected: expected, code: "order_required")
    }

    private func recovery(
        _ request: AgentSessionAdministrationRequest, workspaceID: UUID,
        order: [String], expected: [String], code: String
    ) -> Value {
        var arguments: [String: Value] = [
            "op": .string("reorder_groups"),
            "workspace": .string(workspaceID.uuidString),
            "order": .array(order.map(Value.string)),
            "expected_order": .array(expected.map(Value.string)),
            "idempotency_key": .string("reorder_groups:\(UUID().uuidString)")
        ]
        if let scopeID = request.scopeID {
            arguments["scope_id"] = .string(scopeID.uuidString)
        }
        // Preserve explicit selection and preview, but rederive implicit carriers on submission.
        for key in ["session_id", "targets", "filter"] {
            arguments[key] = request.arguments[key]
        }
        if request.preview {
            arguments["preview"] = .bool(true)
        }
        return .object(SessionAdminReply.diagnostic(code: code, fields: [
            "result": .string(code),
            "affected": .object(["workspace_id": .string(workspaceID.uuidString)]),
            "current_groups": .array(expected.map(Value.string)),
            "current_order": .array(expected.map(Value.string)),
            "detail": .string(
                order == expected
                    ? "Submit next_call to apply this order; an already satisfied order succeeds with changed_count: 0. Edit order to request a rearrangement. expected_order still rejects intervening changes."
                    : "Submit next_call to apply the supplied order. expected_order is the current relative order; intervening changes still conflict."
            ),
            "next_call": .object(["tool": .string("session_admin"), "arguments": .object(arguments)])
        ]))
    }

    func confirmationItems(
        for request: AgentSessionAdministrationRequest,
        scope _: DomainDelegationScopeRecord
    ) -> [BatchConfirmationItem] {
        let effect = (try? effectDescription(request)) ?? request.operation.adminOperationName
        let states = backend.states(of: request.targetSessionIDs)
        return request.targetSessionIDs.map { id in
            BatchConfirmationItem(sessionID: id, title: states[id]?.name ?? id.uuidString, effect: effect)
        }
    }

    private func effectDescription(_ request: AgentSessionAdministrationRequest) throws -> String {
        let args = request.arguments
        switch request.operation {
        case .adminRename:
            return try "Rename to \u{201C}\(AgentSessionAdminArguments.string(args, "name") ?? "")\u{201D}"
        case .adminSetPin:
            return try AgentSessionAdminArguments.bool(args, "pinned") == false ? "Unpin" : "Pin"
        case .adminReorderPins:
            return "Move within pinned order"
        case .adminSetGroup:
            if let group = try normalizedGroupArgument(args) { return "Move to group \u{201C}\(group)\u{201D}" }
            return "Remove from its group"
        case .adminReorderGroups:
            return "Reorder sidebar groups"
        case .adminArchive:
            return "Archive"
        case .adminUnarchive:
            return "Restore from archive"
        default:
            return request.operation.adminOperationName
        }
    }

    // MARK: - Perform

    func perform(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        let leases = Dictionary(batch.leases.map { ($0.targetSessionID, $0) }, uniquingKeysWith: { first, _ in first })
        let context = Context(
            batch: batch, leases: leases,
            isLeaseCurrent: batch.request.operation == .adminReorderGroups ? isGroupOrderLeaseCurrent : isLeaseCurrent
        )
        let args = batch.request.arguments
        switch batch.request.operation {
        case .adminRename:
            guard let raw = try AgentSessionAdminArguments.string(args, "name"),
                  !AgentSession.validatedName(raw).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw AgentSessionAdminArguments.invalid("rename requires a non-empty name.") }
            return finish(context, payload: rename(context, name: AgentSession.validatedName(raw)))
        case .adminSetPin:
            guard let pinned = try AgentSessionAdminArguments.bool(args, "pinned") else {
                throw AgentSessionAdminArguments.invalid("set_pin requires pinned (boolean).")
            }
            return finish(context, payload: setPin(context, pinned: pinned))
        case .adminReorderPins:
            return try reorderPins(context, args: args)
        case .adminSetGroup:
            guard args.keys.contains("group") else {
                throw AgentSessionAdminArguments.invalid("set_group requires group (a name, or an empty string to ungroup).")
            }
            return try finish(context, payload: setGroup(context, group: normalizedGroupArgument(args)))
        case .adminReorderGroups:
            return try await reorderGroups(context, args: args)
        case .adminArchive:
            return await finish(context, payload: archive(context))
        case .adminUnarchive:
            return await finish(context, payload: unarchive(context))
        default:
            throw AgentSessionAdminArguments.invalid("\(batch.request.operation.adminOperationName) is not an organize op.")
        }
    }

    // MARK: - Ops

    @MainActor
    private final class Context {
        let batch: AgentSessionAdministrationAuthorizedBatch
        let leases: [UUID: DomainDelegationScopeLease]
        let isLeaseCurrent: @MainActor (DomainDelegationScopeLease) -> Bool
        var items: [AgentSessionAdminItemResult] = []
        var extra: [String: Value] = [:]

        init(
            batch: AgentSessionAdministrationAuthorizedBatch,
            leases: [UUID: DomainDelegationScopeLease],
            isLeaseCurrent: @escaping @MainActor (DomainDelegationScopeLease) -> Bool
        ) {
            self.batch = batch
            self.leases = leases
            self.isLeaseCurrent = isLeaseCurrent
        }

        var targets: [UUID] {
            batch.admittedSessionIDs
        }

        /// Re-checked immediately before every mutation (after any suspension point).
        func isCurrent(_ sessionID: UUID) -> Bool {
            leases[sessionID].map(isLeaseCurrent) ?? false
        }

        func add(_ sessionID: UUID, _ status: AgentSessionAdminItemResult.Status, _ reason: String? = nil) {
            items.append(AgentSessionAdminItemResult(sessionID: sessionID, status: status, reason: reason))
        }
    }

    /// Splits targets into loaded, eligible states and per-item skips.
    private func eligibleStates(
        _ context: Context,
        archived: Bool,
        unchanged: (AgentSessionOrganizeState) -> Bool
    ) -> [AgentSessionOrganizeState] {
        var eligible: [AgentSessionOrganizeState] = []
        let states = backend.states(of: context.targets)
        for id in context.targets {
            guard let state = states[id] else {
                context.add(id, .skipped, "workspace_not_loaded")
                continue
            }
            guard state.isArchived == archived else {
                context.add(id, .skipped, archived ? "not_archived" : "archived")
                continue
            }
            if unchanged(state) {
                context.add(id, .unchanged)
                continue
            }
            eligible.append(state)
        }
        return eligible
    }

    /// Lease-checks `states` now; returns the still-authorized ones and marks the rest failed.
    private func currentOnly(_ context: Context, _ states: [AgentSessionOrganizeState]) -> [AgentSessionOrganizeState] {
        states.filter { state in
            if context.isCurrent(state.sessionID) { return true }
            context.add(state.sessionID, .failed, "scope_no_longer_current")
            return false
        }
    }

    private func record(_ context: Context, attempted: [AgentSessionOrganizeState], changed: Set<UUID>) {
        for state in attempted {
            context.add(
                state.sessionID,
                changed.contains(state.sessionID) ? .changed : .failed,
                changed.contains(state.sessionID) ? nil : "mutation_rejected"
            )
        }
    }

    private func rename(_ context: Context, name: String) -> AgentSessionOrganizeUndoPayload? {
        let states = currentOnly(context, eligibleStates(context, archived: false) { $0.name == name })
        let changed = backend.rename(states.map(\.sessionID), to: name)
        let after = backend.states(of: Array(changed))
        record(context, attempted: states, changed: changed)
        return .fields(states.filter { changed.contains($0.sessionID) }.compactMap { state in
            // Store what was actually written (rename validates the name).
            after[state.sessionID].map {
                AgentSessionOrganizeFieldRestore(sessionID: state.sessionID, change: .name(before: state.name, after: $0.name))
            }
        })
    }

    private func setPin(_ context: Context, pinned: Bool) -> AgentSessionOrganizeUndoPayload? {
        let states = currentOnly(context, eligibleStates(context, archived: false) { $0.isPinned == pinned })
        let changed = states.isEmpty ? [] : backend.setPinned(pinned, sessionIDs: states.map(\.sessionID))
        record(context, attempted: states, changed: changed)
        return .fields(states.filter { changed.contains($0.sessionID) }.map {
            AgentSessionOrganizeFieldRestore(
                sessionID: $0.sessionID,
                change: .pinned(before: $0.isPinned, beforeRank: $0.pinnedOrder, after: pinned)
            )
        })
    }

    private func reorderPins(_ context: Context, args: [String: Value]) throws -> Value {
        guard let order = try AgentSessionAdminArguments.uuids(args, "order"),
              let expected = try AgentSessionAdminArguments.uuids(args, "expected_order")
        else { throw AgentSessionAdminArguments.invalid("reorder_pins requires order and expected_order.") }
        guard Set(context.targets) == Set(order) else {
            throw AgentSessionAdminArguments.invalid("reorder_pins order must name exactly the sessions being reordered.")
        }
        var workspaceID: UUID?
        let states = backend.states(of: order)
        for id in order {
            guard let state = states[id] else { return Self.workspaceNotLoaded(nil) }
            guard state.isPinned, !state.isArchived else {
                throw AgentSessionAdminArguments.invalid("reorder_pins sessions must all be pinned.")
            }
            guard workspaceID == nil || workspaceID == state.workspaceID else {
                throw AgentSessionAdminArguments.invalid("reorder_pins sessions must share one workspace.")
            }
            workspaceID = state.workspaceID
        }
        guard let workspaceID, let current = backend.pinnedSessionOrder(workspaceID: workspaceID) else {
            return Self.workspaceNotLoaded(workspaceID)
        }
        // CAS on the named pins' current relative order.
        if case let .failure(error) = DomainAgentSessionOrdering.permute(
            current: current, expected: expected, desired: order, describe: \.uuidString
        ) {
            return Self.orderingFailure(error, operation: context.batch.request.operation.adminOperationName, arguments: args, scopeID: context.batch.scope.id)
        }
        // Only the named pins are ever written (see `DomainAgentSessionPinRanks`): they swap their own
        // explicit ranks, or, lacking distinct ones, move to the end of the ranked block in order.
        let currentStates = backend.states(of: current)
        let rankBefore = Dictionary(uniqueKeysWithValues: current.map { ($0, currentStates[$0]?.pinnedOrder) })
        let planned = DomainAgentSessionPinRanks.reordered(
            current: current.map { ($0, rankBefore[$0] ?? nil) },
            desired: order
        )
        let writes = planned.ranks.filter { rankBefore[$0.key] ?? nil != $0.value }
        guard order.allSatisfy(context.isCurrent) else {
            return Self.scopeNoLongerCurrent(context.batch.request.operation)
        }
        let changed = writes.isEmpty ? [] : backend.setPinnedRanks(writes.mapValues { Optional($0) })
        let named = Set(order)
        for id in order {
            context.add(id, changed.contains(id) ? .changed : .unchanged)
        }
        if !planned.keptSlots { context.extra["moved_to_ordered_block"] = .bool(true) }
        context.extra["workspace_id"] = .string(workspaceID.uuidString)
        context.extra["pinned_order"] = .array(
            (backend.pinnedSessionOrder(workspaceID: workspaceID) ?? [])
                .filter(named.contains).map { .string($0.uuidString) }
        )
        return finish(context, payload: .fields(changed.sorted { $0.uuidString < $1.uuidString }.map { id in
            AgentSessionOrganizeFieldRestore(sessionID: id, change: .pinRank(before: rankBefore[id] ?? nil, after: writes[id]))
        }))
    }

    private func setGroup(_ context: Context, group: String?) throws -> AgentSessionOrganizeUndoPayload? {
        let states = currentOnly(context, eligibleStates(context, archived: false) { $0.sidebarGroup == group })
        var changed: Set<UUID> = []
        var writtenOrder: [UUID: Int?] = [:]
        let byWorkspace = Dictionary(grouping: states, by: \.workspaceID)
        for workspaceID in byWorkspace.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let ids = byWorkspace[workspaceID]?.map(\.sessionID) ?? []
            let order = group.map { name in
                DomainAgentSessionSidebarGroup.order(
                    for: name,
                    existing: (backend.groupEntries(workspaceID: workspaceID) ?? []).map { ($0.group, $0.order) }
                )
            }
            for id in ids {
                writtenOrder[id] = order
            }
            changed.formUnion(backend.setGroup(group, order: order, sessionIDs: ids))
        }
        record(context, attempted: states, changed: changed)
        return .fields(states.filter { changed.contains($0.sessionID) }.map {
            AgentSessionOrganizeFieldRestore(
                sessionID: $0.sessionID,
                change: .group(
                    before: $0.sidebarGroup, beforeOrder: $0.sidebarGroupOrder,
                    after: group, afterOrder: writtenOrder[$0.sessionID] ?? nil
                )
            )
        })
    }

    private func reorderGroups(_ context: Context, args: [String: Value]) async throws -> Value {
        let (workspaceID, order) = try groupReorderArguments(args)
        guard let expectedRaw = try AgentSessionAdminArguments.strings(args, "expected_order") else {
            throw AgentSessionAdminArguments.invalid("reorder_groups requires expected_order.")
        }
        let expected = try expectedRaw.map(Self.groupName)
        guard let entries = backend.groupEntries(workspaceID: workspaceID) else {
            return Self.workspaceNotLoaded(workspaceID)
        }
        // Every session carrying a reordered group must be an admitted member: the order value is
        // mirrored on each of them.
        let affected = entries.filter { Set(order).contains($0.group) }.map(\.sessionID)
        guard Set(affected).isSubset(of: Set(context.targets)) else {
            return .object(SessionAdminReply.diagnostic(code: "groups_outside_scope", fields: [
                "result": .string("groups_outside_scope"),
                "affected": .object(["workspace_id": .string(workspaceID.uuidString)]),
                "detail": .string("Every session in the reordered groups must be in your scope; reorder only groups you fully cover, or ask the user for authority covering the workspace.")
            ]))
        }
        let current = DomainAgentSessionSidebarGroup.orderedGroups(entries.map { ($0.group, $0.order) })
        if case let .failure(error) = DomainAgentSessionOrdering.permute(
            current: current, expected: expected, desired: order, describe: { $0 }
        ) {
            return Self.orderingFailure(error, operation: context.batch.request.operation.adminOperationName, arguments: args, scopeID: context.batch.scope.id)
        }
        guard affected.allSatisfy(context.isCurrent) else {
            return Self.scopeNoLongerCurrent(context.batch.request.operation)
        }
        // A validated identity permutation succeeds without normalizing nil or inconsistent
        // mirrored ranks. CAS and live authority still apply before acknowledging satisfaction.
        if current.filter(Set(order).contains) == order {
            for id in affected {
                context.add(id, .unchanged)
            }
            context.extra["workspace_id"] = .string(workspaceID.uuidString)
            context.extra["group_order"] = .array(order.map(Value.string))
            context.extra[AgentSessionAdminRendering.stateSatisfiedKey] = .bool(true)
            return finish(context, payload: nil)
        }
        // The named groups' values are redistributed among them; only their carriers are written.
        let values = DomainAgentSessionSidebarGroup.redistributedOrders(
            desired: order,
            entries: entries.map { ($0.group, $0.order) }
        )
        var before: [UUID: (group: String, order: Int?)] = [:]
        var writes: [UUID: Int?] = [:]
        for entry in entries {
            guard let value = values[entry.group] else { continue }
            before[entry.sessionID] = (entry.group, entry.order)
            if entry.order != value { writes[entry.sessionID] = value }
        }
        guard affected.allSatisfy(context.isCurrent) else {
            return Self.scopeNoLongerCurrent(context.batch.request.operation)
        }
        let outcome = await backend.commitGroupOrderValues(
            writes, workspaceID: workspaceID,
            expected: Set(entries.map { AgentSessionGroupOrderEntry(sessionID: $0.sessionID, group: $0.group, order: $0.order) }),
            affectedSessionIDs: Set(affected), isAuthorized: context.isCurrent
        )
        let changed = outcome.changed
        for id in affected {
            context.add(id, outcome.failure != nil ? .failed : changed.contains(id) ? .changed : .unchanged, outcome.failure)
        }
        recordGroupOrderWrite(outcome, context: context)
        context.extra["workspace_id"] = .string(workspaceID.uuidString)
        let after = backend.groupEntries(workspaceID: workspaceID) ?? []
        context.extra["group_order"] = .array(
            DomainAgentSessionSidebarGroup.orderedGroups(after.map { ($0.group, $0.order) })
                .filter(Set(order).contains).map(Value.string)
        )
        return finish(context, payload: .fields(changed.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            guard let original = before[id] else { return nil }
            return AgentSessionOrganizeFieldRestore(
                sessionID: id,
                change: .groupOrder(group: original.group, before: original.order, after: writes[id] ?? nil)
            )
        }))
    }

    private func archive(_ context: Context) async -> AgentSessionOrganizeUndoPayload? {
        let states = currentOnly(context, controlCheckedForStash(context, eligibleStates(context, archived: false) { _ in false }))
        let outcome = await archiveAuthorized(context, states.map(\.sessionID))
        recordArchive(context, attempted: states.map(\.sessionID), outcome: outcome)
        return .unarchive(states.map(\.sessionID).filter(outcome.archived.contains))
    }

    /// Archiving stashes the tab, which cancels a live run and its pending prompts. The authority
    /// admitted these targets against the run state it saw; the state is re-read now, and a target
    /// that is not idle is archived only while the scope chain still holds `control`. Otherwise it is
    /// reported as `requires_control` and left alone.
    private func controlCheckedForStash(
        _ context: Context,
        _ states: [AgentSessionOrganizeState]
    ) -> [AgentSessionOrganizeState] {
        let runStates = backend.runStates(of: states.map(\.sessionID))
        return states.filter { state in
            guard runStates[state.sessionID] != .idle else { return true }
            if holdsControl(context.batch.scope) { return true }
            context.add(state.sessionID, .skipped, "requires_control")
            return false
        }
    }

    /// Stashes each target with its own commit-time check folded into the stash's mutation-context
    /// check: its lease is current, and it is idle (aggregated across every window) or the scope chain
    /// still holds `control`. The stash evaluates this after its own suspensions, immediately before
    /// it commits, so a target that started running in between is refused there.
    private func archiveAuthorized(_ context: Context, _ ids: [UUID]) async -> AgentSessionArchiveOutcome {
        guard !ids.isEmpty else { return AgentSessionArchiveOutcome() }
        let refusals = AgentSessionRunStateRefusals()
        let backend = backend
        let holdsControl = holdsControl
        let scope = context.batch.scope
        let archived = await backend.archive(ids, isAuthorized: { id in
            guard context.isCurrent(id) else {
                refusals.clear(id)
                return false
            }
            return refusals.admit(id, backend.runState(of: id) == .idle || holdsControl(scope))
        })
        return AgentSessionArchiveOutcome(archived: archived, requiresControl: refusals.refused.subtracting(archived))
    }

    private func recordArchive(_ context: Context, attempted: [UUID], outcome: AgentSessionArchiveOutcome) {
        for id in attempted {
            if outcome.archived.contains(id) {
                context.add(id, .changed)
            } else if outcome.requiresControl.contains(id) {
                context.add(id, .skipped, "requires_control")
            } else {
                context.add(id, .failed, "mutation_rejected")
            }
        }
    }

    private func unarchive(_ context: Context) async -> AgentSessionOrganizeUndoPayload? {
        let states = currentOnly(context, eligibleStates(context, archived: true) { _ in false })
        let ids = states.map(\.sessionID)
        let outcome = await backend.unarchive(ids, isAuthorized: context.isCurrent)
        recordUnarchive(context, attempted: ids, outcome: outcome)
        return .archive(ids.filter(outcome.restored.contains))
    }

    private func recordUnarchive(_ context: Context, attempted: [UUID], outcome: AgentSessionUnarchiveOutcome) {
        for id in attempted {
            if outcome.restored.contains(id) {
                context.add(id, .changed)
            } else if let failure = outcome.failures[id] {
                context.items.append(AgentSessionAdminItemResult(
                    sessionID: id, status: .failed, reason: failure.reason,
                    detail: [
                        "local_changes": .bool(failure.localChanges),
                        "persistence_confirmed": .bool(failure.persistenceConfirmed)
                    ]
                ))
                if failure.localChanges { context.extra["local_changes"] = .bool(true) }
                if failure.persistenceConfirmed {
                    context.extra[AgentSessionAdminRendering.committedChangesKey] = .bool(true)
                }
            } else {
                context.add(id, .skipped, "not_restorable")
            }
        }
    }

    // MARK: - Finish and undo

    /// Renders the reply and issues an undo token when something changed.
    private func finish(_ context: Context, payload: AgentSessionOrganizeUndoPayload?) -> Value {
        var extra = context.extra
        if let payload, payload.isEffective, let grantee = context.batch.request.caller.agentSessionID {
            let entry = undoLedger.issue(
                token: makeToken(),
                granteeSessionID: grantee,
                scopeID: context.batch.scope.id,
                scopeGeneration: context.batch.scope.generation,
                operation: context.batch.request.operation,
                targetSessionIDs: context.targets,
                payload: payload,
                now: now()
            )
            extra["undo_token"] = .string(entry.token)
            extra["undo_expires_at"] = .string(AgentSessionAdminRendering.iso(entry.expiresAt))
        }
        if context.items.contains(where: { $0.reason == "workspace_not_loaded" }) {
            extra["workspace_not_loaded_detail"] = .string(
                "Sessions in workspaces that no open window shows are listed but not changed; open the workspace to organize them."
            )
        }
        return AgentSessionAdminRendering.mutationValue(
            operation: context.batch.request.operation,
            items: context.items,
            itemsRequiringControl: context.batch.itemsRequiringControl,
            extra: extra
        )
    }

    func redeemUndo(
        token: String,
        granteeSessionID: UUID
    ) -> DomainAgentSessionAdministrationUndoLedger<AgentSessionOrganizeUndoPayload>.Redeem {
        undoLedger.redeem(token: token, granteeSessionID: granteeSessionID, now: now())
    }

    /// Puts a redeemed token back (its undo was refused, so it must not be burned).
    func restoreUndo(_ entry: UndoEntry) {
        undoLedger.restore(entry)
    }

    func performUndo(_ entry: UndoEntry, batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        let leases = Dictionary(batch.leases.map { ($0.targetSessionID, $0) }, uniquingKeysWith: { first, _ in first })
        let context = Context(
            batch: batch, leases: leases,
            isLeaseCurrent: entry.operation == .adminReorderGroups ? isGroupOrderLeaseCurrent : isLeaseCurrent
        )
        switch entry.payload {
        case let .fields(restores):
            await undoFields(restores, context: context)
        case let .unarchive(ids):
            let current = ids.filter(context.isCurrent)
            let outcome = await backend.unarchive(current, isAuthorized: context.isCurrent)
            recordUnarchive(context, attempted: ids, outcome: outcome)
            if outcome.restored.isEmpty, !outcome.failures.values.contains(where: \.localChanges) {
                // A refusal before any effect must not consume the original undo token.
                restoreUndo(entry)
            }
        case let .archive(ids):
            // Re-authorized as `archive`, so not-idle targets without `control` were never admitted;
            // the run state is re-read here as well.
            let currentIDs = ids.filter(context.isCurrent)
            let fresh = backend.states(of: currentIDs)
            let states = controlCheckedForStash(
                context,
                currentIDs.compactMap { fresh[$0] }.filter { !$0.isArchived }
            )
            let outcome = await archiveAuthorized(context, states.map(\.sessionID))
            recordArchive(context, attempted: states.map(\.sessionID), outcome: outcome)
            // Items the authority set aside are reported once, under `requires_control`.
            let reported = Set(context.items.map(\.sessionID)).union(batch.itemsRequiringControl)
            for id in ids where !reported.contains(id) {
                context.add(id, .skipped, "not_archivable")
            }
        }
        var extra = context.extra
        extra["undone_op"] = .string(entry.operation.adminOperationName)
        var value = AgentSessionAdminRendering.mutationValue(
            operation: entry.operation,
            items: context.items,
            itemsRequiringControl: batch.itemsRequiringControl,
            extra: extra
        )
        if case var .object(object) = value {
            // Token redemption is separate from the effects: some targets may have changed while
            // others were refused (for example because the user edited them since the original).
            let outcome = object["result"]?.stringValue
            object["result"] = .string(outcome == "partial" ? "partially_undone" : (outcome == "applied" ? "undone" : "not_undone"))
            value = .object(object)
        }
        return value
    }

    /// One fresh read region, then bounded batches. CAS and each target's lease remain mandatory;
    /// pin mutations still use the shared PromptViewModel path, never direct field writes.
    private func undoFields(_ restores: [AgentSessionOrganizeFieldRestore], context: Context) async {
        let states = backend.states(of: restores.map(\.sessionID))
        var pending: [AgentSessionOrganizeFieldRestore] = []
        var outcomes: [UUID: (AgentSessionAdminItemResult.Status, String?)] = [:]
        for restore in restores {
            let id = restore.sessionID
            guard context.leases[id] != nil else { continue }
            guard context.isCurrent(id) else { outcomes[id] = (.failed, "scope_no_longer_current")
                continue
            }
            guard let state = states[id], !state.isArchived else {
                outcomes[id] = (.skipped, "workspace_not_loaded")
                continue
            }
            let matches: Bool = switch restore.change {
            case let .name(_, after): state.name == after
            case let .pinned(_, _, after): state.isPinned == after
            case let .pinRank(_, after): state.isPinned && state.pinnedOrder == after
            case let .group(_, _, after, afterOrder): state.sidebarGroup == after && state.sidebarGroupOrder == afterOrder
            case let .groupOrder(group, _, after): state.sidebarGroup == group && state.sidebarGroupOrder == after
            }
            if matches { pending.append(restore) } else { outcomes[id] = (.skipped, "changed_since") }
        }
        var changed: Set<UUID> = []
        var names: [UUID: String] = [:]
        var pins: [Bool: [UUID]] = [:]
        var pinRanks: [UUID: Int?] = [:]
        var ranksAfterPin: [UUID: Int?] = [:]
        var groups: [UUID: (name: String?, order: Int?)] = [:]
        var groupOrders: [UUID: Int?] = [:]
        // No await or production mutation occurs between these checks and the writes below.
        for restore in pending {
            let id = restore.sessionID
            guard context.isCurrent(id) else { outcomes[id] = (.failed, "scope_no_longer_current")
                continue
            }
            switch restore.change {
            case let .name(before, _): names[id] = before
            case let .pinned(before, beforeRank, _):
                pins[before, default: []].append(id)
                if before, let beforeRank { ranksAfterPin[id] = beforeRank }
            case let .pinRank(before, _): pinRanks.updateValue(before, forKey: id)
            case let .group(before, beforeOrder, _, _): groups[id] = (before, beforeOrder)
            case let .groupOrder(_, before, _): groupOrders.updateValue(before, forKey: id)
            }
        }
        func isCurrent(_ id: UUID) -> Bool {
            guard context.isCurrent(id) else { outcomes[id] = (.failed, "scope_no_longer_current")
                return false
            }
            return true
        }
        let currentNames = names.filter { isCurrent($0.key) }
        if !currentNames.isEmpty { changed.formUnion(backend.rename(currentNames)) }
        for pinned in [false, true] {
            let ids = (pins[pinned] ?? []).filter(isCurrent)
            if !ids.isEmpty { changed.formUnion(backend.setPinned(pinned, sessionIDs: ids)) }
        }
        let restoredRanks = ranksAfterPin.filter { changed.contains($0.key) && isCurrent($0.key) }
        if !restoredRanks.isEmpty { _ = backend.setPinnedRanks(restoredRanks) }
        let currentRanks = pinRanks.filter { isCurrent($0.key) }
        if !currentRanks.isEmpty { changed.formUnion(backend.setPinnedRanks(currentRanks)) }
        let currentGroups = groups.filter { isCurrent($0.key) }
        if !currentGroups.isEmpty { changed.formUnion(backend.setGroups(currentGroups)) }
        let currentOrders = groupOrders.filter { isCurrent($0.key) }
        if !currentOrders.isEmpty {
            let byWorkspace = Dictionary(grouping: Array(currentOrders.keys), by: { states[$0]?.workspaceID })
            for workspaceID in byWorkspace.keys.compactMap(\.self).sorted(by: { $0.uuidString < $1.uuidString }) {
                var ids = Set(byWorkspace[workspaceID] ?? [])
                guard let entries = backend.groupEntries(workspaceID: workspaceID) else {
                    for id in ids {
                        outcomes[id] = (.failed, "workspace_not_loaded")
                    }
                    continue
                }
                // A preceding workspace commit can suspend. Re-prove each field's original CAS
                // against this fresh snapshot before using its captured restore value.
                let byID = Dictionary(entries.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
                for restore in pending where ids.contains(restore.sessionID) {
                    guard case let .groupOrder(group, _, after) = restore.change,
                          let current = byID[restore.sessionID], current.group == group, current.order == after
                    else {
                        outcomes[restore.sessionID] = (.skipped, "changed_since")
                        ids.remove(restore.sessionID)
                        continue
                    }
                }
                guard !ids.isEmpty else { continue }
                let result = await backend.commitGroupOrderValues(
                    currentOrders.filter { ids.contains($0.key) }, workspaceID: workspaceID,
                    expected: Set(entries.map { AgentSessionGroupOrderEntry(sessionID: $0.sessionID, group: $0.group, order: $0.order) }),
                    affectedSessionIDs: ids, isAuthorized: context.isCurrent
                )
                changed.formUnion(result.changed)
                recordGroupOrderWrite(result, context: context)
                if let reason = result.failure {
                    for id in ids {
                        outcomes[id] = (.failed, reason)
                    }
                }
            }
        }
        for restore in restores where context.leases[restore.sessionID] != nil {
            let id = restore.sessionID
            let outcome = outcomes[id] ?? (changed.contains(id) ? (.changed, nil) : (.failed, "mutation_rejected"))
            context.add(id, outcome.0, outcome.1)
        }
    }

    // MARK: - Helpers

    private func recordGroupOrderWrite(_ outcome: AgentSessionGroupOrderWriteOutcome, context: Context) {
        if outcome.localChanges { context.extra["local_changes"] = .bool(true) }
        if outcome.persistenceConfirmed { context.extra[AgentSessionAdminRendering.committedChangesKey] = .bool(true) }
    }

    /// The schema advertises `group` as a plain string; an empty (or whitespace-only) string clears
    /// the group. A literal `null` is still tolerated for callers written against the earlier schema.
    private func normalizedGroupArgument(_ args: [String: Value]) throws -> String? {
        guard let raw = try AgentSessionAdminArguments.string(args, "group"),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return try Self.groupName(raw)
    }

    private static func groupName(_ raw: String) throws -> String {
        guard let name = DomainAgentSessionSidebarGroup.normalizedName(raw) else {
            throw AgentSessionAdminArguments.invalid(
                "group names must be 1...\(DomainAgentSessionSidebarGroup.maxNameCharacters) characters on one line."
            )
        }
        return name
    }

    private func groupReorderArguments(_ args: [String: Value]) throws -> (UUID, [String]) {
        guard let workspaceID = try AgentSessionAdminArguments.uuid(args, "workspace") else {
            throw AgentSessionAdminArguments.invalid("reorder_groups requires workspace (workspace UUID).")
        }
        if args["expected_order"] != nil {
            guard let expected = try AgentSessionAdminArguments.strings(args, "expected_order") else {
                throw AgentSessionAdminArguments.invalid("expected_order must be an array of group names.")
            }
            _ = try expected.map(Self.groupName)
        }
        if args["order"] == nil {
            guard let entries = backend.groupEntries(workspaceID: workspaceID) else {
                throw AgentSessionAdminEarlyResult(value: Self.workspaceNotLoaded(workspaceID))
            }
            // Derive carriers only for authorization; preflight supplies the recovery receipt.
            return (workspaceID, DomainAgentSessionSidebarGroup.orderedGroups(entries.map { ($0.group, $0.order) }))
        }
        guard let order = try AgentSessionAdminArguments.strings(args, "order") else {
            throw AgentSessionAdminArguments.invalid("reorder_groups requires order (group names).")
        }
        return try (workspaceID, order.map(Self.groupName))
    }

    static func workspaceNotLoaded(_ workspaceID: UUID?) -> Value {
        var object: [String: Value] = [
            "result": .string("workspace_not_loaded"),
            "load_workspace": .bool(true),
            "detail": .string("Only sessions in a workspace an open window shows can be organized. Ask the user to open it.")
        ]
        if let workspaceID {
            object["workspace_id"] = .string(workspaceID.uuidString)
        }
        return .object(SessionAdminReply.diagnostic(code: "workspace_not_loaded", fields: object))
    }

    static func orderingFailure(
        _ error: DomainAgentSessionOrderingError, operation: String, arguments: [String: Value], scopeID: UUID?
    ) -> Value {
        var fields: [String: Value] = [:]
        var next = arguments
        next["op"] = .string(operation)
        if let scopeID {
            next["scope_id"] = .string(scopeID.uuidString)
        }
        let code: String
        switch error {
        case let .expectedOrderMismatch(current):
            code = "order_conflict"
            fields["subreason"] = .string("expected_order_mismatch")
            fields["current_order"] = .array(current.map(Value.string))
            fields["detail"] = .string("expected_order is stale. Inspect current_order, then use next_call if the desired ordering is still appropriate.")
            next["expected_order"] = .array(current.map(Value.string))
            fields["next_call"] = .object(["tool": .string("session_admin"), "arguments": .object(next)])
        case .orderSetMismatch:
            code = "invalid_order"
            fields["subreason"] = .string("order_set_mismatch")
            fields["detail"] = .string("order and expected_order must name the same items, each once. Inspect current session/group state and correct both arrays.")
        case .unknownItem:
            code = "invalid_order"
            fields["subreason"] = .string("unknown_order_item")
            fields["detail"] = .string("order names an item not currently in the ordered set. Inspect current session/group state and remove or correct that item.")
        }
        fields["result"] = .string(code)
        if let workspace = arguments["workspace"] { fields["affected"] = .object(["workspace_id": workspace]) }
        return .object(SessionAdminReply.diagnostic(code: code, fields: fields))
    }

    static func scopeNoLongerCurrent(_ operation: DomainAgentSessionTargetOperation) -> Value {
        .object(SessionAdminReply.diagnostic(code: "scope_no_longer_current", fields: [
            "result": .string("scope_no_longer_current"),
            "op": .string(operation.adminOperationName),
            "detail": .string("The scope changed before the mutation; nothing was applied. Inspect scope_status before another mutation.")
        ]))
    }
}

private extension AgentSessionOrganizeUndoPayload {
    var isEffective: Bool {
        switch self {
        case let .fields(restores): !restores.isEmpty
        case let .unarchive(ids), let .archive(ids): !ids.isEmpty
        }
    }
}
