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
    /// Group order value only (group reorders).
    case groupOrder(before: Int?, after: Int?)
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
    /// Whether the scope is still live and its whole chain holds `control`, for targets that turned
    /// out not to be idle when re-read.
    private let holdsControl: @MainActor (DomainDelegationScopeRecord) -> Bool
    private let now: () -> Date
    private let makeToken: () -> String
    private var undoLedger: DomainAgentSessionAdministrationUndoLedger<AgentSessionOrganizeUndoPayload>

    init(
        backend: any AgentSessionOrganizingBackend,
        isLeaseCurrent: @escaping @MainActor (DomainDelegationScopeLease) -> Bool,
        holdsControl: @escaping @MainActor (DomainDelegationScopeRecord) -> Bool,
        now: @escaping () -> Date = Date.init,
        makeToken: @escaping () -> String = { UUID().uuidString },
        undoLifetime: TimeInterval = 15 * 60
    ) {
        self.backend = backend
        self.isLeaseCurrent = isLeaseCurrent
        self.holdsControl = holdsControl
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
        return .fields(states.filter { changed.contains($0.sessionID) }.compactMap { state in
            // Store what was actually written (rename validates the name).
            backend.state(of: state.sessionID).map {
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
        // CAS on the named pins' current relative order.
        if case let .failure(error) = DomainAgentSessionOrdering.permute(
            current: current, expected: expected, desired: order, describe: \.uuidString
        ) {
            return Self.orderingFailure(error)
        }
        // Only the named pins are ever written (see `DomainAgentSessionPinRanks`): they swap their own
        // explicit ranks, or, lacking distinct ones, move to the end of the ranked block in order.
        let rankBefore = Dictionary(uniqueKeysWithValues: current.map { ($0, backend.state(of: $0)?.pinnedOrder) })
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
        if case let .failure(error) = DomainAgentSessionOrdering.permute(
            current: current, expected: expected, desired: order, describe: { $0 }
        ) {
            return Self.orderingFailure(error)
        }
        // The named groups' values are redistributed among them; only their carriers are written.
        let values = DomainAgentSessionSidebarGroup.redistributedOrders(
            desired: order,
            entries: entries.map { ($0.group, $0.order) }
        )
        var before: [UUID: Int?] = [:]
        var writes: [UUID: Int?] = [:]
        for entry in entries {
            guard let value = values[entry.group] else { continue }
            before[entry.sessionID] = entry.order
            if entry.order != value { writes[entry.sessionID] = value }
        }
        guard affected.allSatisfy(context.isCurrent) else {
            return Self.scopeNoLongerCurrent(context.batch.request.operation)
        }
        let changed = writes.isEmpty ? [] : backend.setGroupOrderValues(writes)
        for id in affected {
            context.add(id, changed.contains(id) ? .changed : .unchanged)
        }
        context.extra["workspace_id"] = .string(workspaceID.uuidString)
        let after = backend.groupEntries(workspaceID: workspaceID) ?? []
        context.extra["group_order"] = .array(
            DomainAgentSessionSidebarGroup.orderedGroups(after.map { ($0.group, $0.order) })
                .filter(Set(order).contains).map(Value.string)
        )
        return finish(context, payload: .fields(changed.sorted { $0.uuidString < $1.uuidString }.map { id in
            AgentSessionOrganizeFieldRestore(
                sessionID: id,
                change: .groupOrder(before: before[id] ?? nil, after: writes[id] ?? nil)
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
        states.filter { state in
            guard backend.runState(of: state.sessionID) != .idle else { return true }
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
        let context = Context(batch: batch, leases: leases, isLeaseCurrent: isLeaseCurrent)
        switch entry.payload {
        case let .fields(restores):
            for restore in restores {
                // Every restore needs the session's own lease; a materialized rank on a pin outside
                // the call is left in place (it never changed that pin's position).
                guard context.isCurrent(restore.sessionID) else {
                    if leases[restore.sessionID] != nil {
                        context.add(restore.sessionID, .failed, "scope_no_longer_current")
                    }
                    continue
                }
                let outcome = undoField(restore)
                context.add(restore.sessionID, outcome.status, outcome.reason)
            }
        case let .unarchive(ids):
            let current = ids.filter(context.isCurrent)
            let changed = backend.unarchive(current)
            for id in ids {
                context.add(id, changed.contains(id) ? .changed : .skipped, changed.contains(id) ? nil : "not_restorable")
            }
        case let .archive(ids):
            // Re-authorized as `archive`, so not-idle targets without `control` were never admitted;
            // the run state is re-read here as well.
            let states = controlCheckedForStash(
                context,
                ids.filter(context.isCurrent).compactMap { backend.state(of: $0) }
                    .filter { !$0.isArchived }
            )
            let outcome = await archiveAuthorized(context, states.map(\.sessionID))
            recordArchive(context, attempted: states.map(\.sessionID), outcome: outcome)
            // Items the authority set aside are reported once, under `requires_control`.
            let reported = Set(context.items.map(\.sessionID)).union(batch.itemsRequiringControl)
            for id in ids where !reported.contains(id) {
                context.add(id, .skipped, "not_archivable")
            }
        }
        var value = AgentSessionAdminRendering.mutationValue(
            operation: entry.operation,
            items: context.items,
            itemsRequiringControl: batch.itemsRequiringControl,
            extra: ["undone_op": .string(entry.operation.adminOperationName)]
        )
        if case var .object(object) = value {
            object["result"] = .string("undone")
            value = .object(object)
        }
        return value
    }

    /// Restores one field, only while it still holds the value the call wrote.
    private func undoField(
        _ restore: AgentSessionOrganizeFieldRestore
    ) -> (status: AgentSessionAdminItemResult.Status, reason: String?) {
        guard let state = backend.state(of: restore.sessionID), !state.isArchived else {
            return (.skipped, "workspace_not_loaded")
        }
        let id = restore.sessionID
        let applied: Bool
        switch restore.change {
        case let .name(before, after):
            guard state.name == after else { return (.skipped, "changed_since") }
            applied = backend.rename(id, to: before)
        case let .pinned(before, beforeRank, after):
            guard state.isPinned == after else { return (.skipped, "changed_since") }
            applied = !backend.setPinned(before, sessionIDs: [id]).isEmpty
            if applied, before, let beforeRank { _ = backend.setPinnedRanks([id: beforeRank]) }
        case let .pinRank(before, after):
            guard state.isPinned, state.pinnedOrder == after else { return (.skipped, "changed_since") }
            applied = !backend.setPinnedRanks([id: before]).isEmpty
        case let .group(before, beforeOrder, after, afterOrder):
            guard state.sidebarGroup == after, state.sidebarGroupOrder == afterOrder else {
                return (.skipped, "changed_since")
            }
            applied = !backend.setGroup(before, order: beforeOrder, sessionIDs: [id]).isEmpty
        case let .groupOrder(before, after):
            guard state.sidebarGroup != nil, state.sidebarGroupOrder == after else { return (.skipped, "changed_since") }
            applied = !backend.setGroupOrderValues([id: before]).isEmpty
        }
        return applied ? (.changed, nil) : (.failed, "mutation_rejected")
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
        case let .fields(restores): !restores.isEmpty
        case let .unarchive(ids), let .archive(ids): !ids.isEmpty
        }
    }
}
