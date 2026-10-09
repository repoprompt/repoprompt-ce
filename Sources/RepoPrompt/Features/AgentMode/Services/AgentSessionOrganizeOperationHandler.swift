import Foundation
import MCP
import RepoPromptDomainRuntime

/// What `undo` restores for one reversible organize call.
enum AgentSessionOrganizeUndoPayload {
    /// Exact prior name/pin/order/group state.
    case restore([AgentSessionOrganizeState])
    /// Undo of `archive`.
    case unarchive([UUID])
    /// Undo of `unarchive`.
    case archive([UUID])
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
}

/// `rename`, `set_pin`, `reorder_pins`, `set_group`, `reorder_groups`, `archive`, `unarchive`.
///
/// Every effect is derived from `request.arguments`. Each mutation re-checks its target's scope lease
/// immediately before it runs; nothing suspends between that check and the synchronous mutation.
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
    private let now: () -> Date
    private let makeToken: () -> String
    private var undoLedger: DomainAgentSessionAdministrationUndoLedger<AgentSessionOrganizeUndoPayload>

    init(
        backend: any AgentSessionOrganizingBackend,
        isLeaseCurrent: @escaping @MainActor (DomainDelegationScopeLease) -> Bool,
        now: @escaping () -> Date = Date.init,
        makeToken: @escaping () -> String = { UUID().uuidString },
        undoLifetime: TimeInterval = 15 * 60
    ) {
        self.backend = backend
        self.isLeaseCurrent = isLeaseCurrent
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
            return entries.filter { named.contains($0.group) }.map(\.sessionID)
        default:
            return nil
        }
    }

    // MARK: - Cards and preview

    func confirmationItems(
        for request: AgentSessionAdministrationRequest,
        scope _: DomainDelegationScopeRecord
    ) -> [BatchConfirmationItem] {
        let effect = (try? effectDescription(request)) ?? request.operation.adminOperationName
        return request.targetSessionIDs.map { id in
            BatchConfirmationItem(sessionID: id, title: backend.state(of: id)?.name ?? id.uuidString, effect: effect)
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
        let context = Context(batch: batch, leases: leases, isLeaseCurrent: isLeaseCurrent)
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
                throw AgentSessionAdminArguments.invalid("set_group requires group (a name, or null to ungroup).")
            }
            return try finish(context, payload: setGroup(context, group: normalizedGroupArgument(args)))
        case .adminReorderGroups:
            return try reorderGroups(context, args: args)
        case .adminArchive:
            return await finish(context, payload: archive(context))
        case .adminUnarchive:
            return finish(context, payload: unarchive(context))
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
        for id in context.targets {
            guard let state = backend.state(of: id) else {
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
        var changed: Set<UUID> = []
        for state in states where backend.rename(state.sessionID, to: name) {
            changed.insert(state.sessionID)
        }
        record(context, attempted: states, changed: changed)
        return .restore(states.filter { changed.contains($0.sessionID) })
    }

    private func setPin(_ context: Context, pinned: Bool) -> AgentSessionOrganizeUndoPayload? {
        let states = currentOnly(context, eligibleStates(context, archived: false) { $0.isPinned == pinned })
        let changed = states.isEmpty ? [] : backend.setPinned(pinned, sessionIDs: states.map(\.sessionID))
        record(context, attempted: states, changed: changed)
        return .restore(states.filter { changed.contains($0.sessionID) })
    }

    private func reorderPins(_ context: Context, args: [String: Value]) throws -> Value {
        guard let order = try AgentSessionAdminArguments.uuids(args, "order"),
              let expected = try AgentSessionAdminArguments.uuids(args, "expected_order")
        else { throw AgentSessionAdminArguments.invalid("reorder_pins requires order and expected_order.") }
        guard Set(context.targets) == Set(order) else {
            throw AgentSessionAdminArguments.invalid("reorder_pins order must name exactly the sessions being reordered.")
        }
        var workspaceID: UUID?
        for id in order {
            guard let state = backend.state(of: id) else { return Self.workspaceNotLoaded(nil) }
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
        let next: [UUID]
        switch DomainAgentSessionOrdering.permute(current: current, expected: expected, desired: order, describe: \.uuidString) {
        case let .success(value): next = value
        case let .failure(error): return Self.orderingFailure(error)
        }
        // Undo restores every pin rank this write assigns; positions of pins outside the call are
        // unchanged (they keep their slots).
        let before = current.compactMap { backend.state(of: $0) }
        guard order.allSatisfy(context.isCurrent) else {
            return Self.scopeNoLongerCurrent(context.batch.request.operation)
        }
        guard next == current || backend.setPinnedOrder(next, workspaceID: workspaceID) else {
            throw AgentSessionAdminArguments.invalid("the pinned sessions changed before reordering; list them and retry.")
        }
        let moved = Set(zip(current, next).filter { $0 != $1 }.map(\.1))
        for id in order {
            context.add(id, moved.contains(id) ? .changed : .unchanged)
        }
        context.extra["workspace_id"] = .string(workspaceID.uuidString)
        context.extra["pinned_order"] = .array(next.map { .string($0.uuidString) })
        return finish(context, payload: moved.isEmpty ? nil : .restore(before))
    }

    private func setGroup(_ context: Context, group: String?) throws -> AgentSessionOrganizeUndoPayload? {
        let states = currentOnly(context, eligibleStates(context, archived: false) { $0.sidebarGroup == group })
        var changed: Set<UUID> = []
        let byWorkspace = Dictionary(grouping: states, by: \.workspaceID)
        for workspaceID in byWorkspace.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let ids = byWorkspace[workspaceID]?.map(\.sessionID) ?? []
            let order = group.map { name in
                DomainAgentSessionSidebarGroup.order(
                    for: name,
                    existing: (backend.groupEntries(workspaceID: workspaceID) ?? []).map { ($0.group, $0.order) }
                )
            }
            changed.formUnion(backend.setGroup(group, order: order, sessionIDs: ids))
        }
        record(context, attempted: states, changed: changed)
        return .restore(states.filter { changed.contains($0.sessionID) })
    }

    private func reorderGroups(_ context: Context, args: [String: Value]) throws -> Value {
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
            return .object([
                "result": .string("groups_outside_scope"),
                "detail": .string("Every session in the reordered groups must be in your scope; reorder only groups you fully cover.")
            ])
        }
        let current = DomainAgentSessionSidebarGroup.orderedGroups(entries.map { ($0.group, $0.order) })
        let next: [String]
        switch DomainAgentSessionOrdering.permute(current: current, expected: expected, desired: order, describe: { $0 }) {
        case let .success(value): next = value
        case let .failure(error): return Self.orderingFailure(error)
        }
        let before = affected.compactMap { backend.state(of: $0) }
        guard affected.allSatisfy(context.isCurrent) else {
            return Self.scopeNoLongerCurrent(context.batch.request.operation)
        }
        let orders = Dictionary(uniqueKeysWithValues: next.enumerated().map { ($0.element, $0.offset) })
        guard backend.setGroupOrders(orders, workspaceID: workspaceID) else { return Self.workspaceNotLoaded(workspaceID) }
        let after = Dictionary(uniqueKeysWithValues: affected.compactMap { id in backend.state(of: id).map { (id, $0) } })
        for state in before {
            context.add(state.sessionID, after[state.sessionID]?.sidebarGroupOrder == state.sidebarGroupOrder ? .unchanged : .changed)
        }
        context.extra["workspace_id"] = .string(workspaceID.uuidString)
        context.extra["group_order"] = .array(next.map(Value.string))
        let changed = before.contains { after[$0.sessionID]?.sidebarGroupOrder != $0.sidebarGroupOrder }
        return finish(context, payload: changed ? .restore(before) : nil)
    }

    private func archive(_ context: Context) async -> AgentSessionOrganizeUndoPayload? {
        let states = currentOnly(context, eligibleStates(context, archived: false) { _ in false })
        let changed = states.isEmpty ? [] : await backend.archive(states.map(\.sessionID))
        record(context, attempted: states, changed: changed)
        return .unarchive(states.map(\.sessionID).filter(changed.contains))
    }

    private func unarchive(_ context: Context) -> AgentSessionOrganizeUndoPayload? {
        let states = currentOnly(context, eligibleStates(context, archived: true) { _ in false })
        let changed = states.isEmpty ? [] : backend.unarchive(states.map(\.sessionID))
        record(context, attempted: states, changed: changed)
        return .archive(states.map(\.sessionID).filter(changed.contains))
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

    func performUndo(_ entry: UndoEntry, batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        let leases = Dictionary(batch.leases.map { ($0.targetSessionID, $0) }, uniquingKeysWith: { first, _ in first })
        let context = Context(batch: batch, leases: leases, isLeaseCurrent: isLeaseCurrent)
        switch entry.payload {
        case let .restore(states):
            for state in states {
                // Rank-only restores of pins outside the call ride on the call's own authorization.
                let gate = leases[state.sessionID] ?? batch.leases.first
                guard let gate, isLeaseCurrent(gate) else {
                    context.add(state.sessionID, .failed, "scope_no_longer_current")
                    continue
                }
                let restored = backend.restore(state)
                if leases[state.sessionID] != nil {
                    context.add(state.sessionID, restored ? .changed : .skipped, restored ? nil : "workspace_not_loaded")
                }
            }
        case let .unarchive(ids):
            let current = ids.filter(context.isCurrent)
            let changed = backend.unarchive(current)
            for id in ids {
                context.add(id, changed.contains(id) ? .changed : .skipped, changed.contains(id) ? nil : "not_restorable")
            }
        case let .archive(ids):
            let current = ids.filter(context.isCurrent)
            let changed = await backend.archive(current)
            for id in ids {
                context.add(id, changed.contains(id) ? .changed : .skipped, changed.contains(id) ? nil : "not_archivable")
            }
        }
        var value = AgentSessionAdminRendering.mutationValue(
            operation: entry.operation,
            items: context.items,
            itemsRequiringControl: [],
            extra: ["undone_op": .string(entry.operation.adminOperationName)]
        )
        if case var .object(object) = value {
            object["result"] = .string("undone")
            value = .object(object)
        }
        return value
    }

    // MARK: - Helpers

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
        if let workspaceID { object["workspace_id"] = .string(workspaceID.uuidString) }
        return .object(object)
    }

    static func orderingFailure(_ error: DomainAgentSessionOrderingError) -> Value {
        switch error {
        case let .expectedOrderMismatch(current):
            .object([
                "result": .string("order_conflict"),
                "current_order": .array(current.map(Value.string)),
                "detail": .string("expected_order is stale. Retry with current_order as expected_order.")
            ])
        case .orderSetMismatch:
            .object([
                "result": .string("invalid_order"),
                "detail": .string("order and expected_order must name the same items, each once.")
            ])
        case .unknownItem:
            .object([
                "result": .string("invalid_order"),
                "detail": .string("order names an item that is not currently in the ordered set.")
            ])
        }
    }

    static func scopeNoLongerCurrent(_ operation: DomainAgentSessionTargetOperation) -> Value {
        .object([
            "result": .string("scope_no_longer_current"),
            "op": .string(operation.adminOperationName),
            "detail": .string("The scope changed before the mutation; nothing was applied.")
        ])
    }
}

private extension AgentSessionOrganizeUndoPayload {
    var isEffective: Bool {
        switch self {
        case let .restore(states): !states.isEmpty
        case let .unarchive(ids), let .archive(ids): !ids.isEmpty
        }
    }
}
