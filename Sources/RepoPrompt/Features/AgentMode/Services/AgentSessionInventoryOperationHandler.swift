import Foundation
import MCP
import RepoPromptDomainRuntime

/// `inventory`, `get`, `tree`, and `links` (scope `observe`).
///
/// Inventory spans every workspace through the history index; only sessions the scope covers are
/// ever listed. Membership comes from persisted provenance in the snapshot, never from arguments.
@MainActor
final class AgentSessionInventoryOperationHandler: AgentSessionAdministrationOperationHandler {
    static let maxTreeDepth = 32

    let operations: Set<DomainAgentSessionTargetOperation> = [.adminInventory, .adminGet, .adminTree, .adminLinks]

    private let source: any AgentSessionInventorySource
    private let scopeChain: @MainActor (UUID) -> [DomainDelegationScopeRecord]
    /// Whether the scope is still the live generation the batch was authorized under.
    private let isScopeCurrent: @MainActor (DomainDelegationScopeRecord) -> Bool
    private let isLeaseCurrent: @MainActor (DomainDelegationScopeLease) -> Bool
    private let now: () -> Date

    init(
        source: any AgentSessionInventorySource,
        scopeChain: @escaping @MainActor (UUID) -> [DomainDelegationScopeRecord],
        isScopeCurrent: @escaping @MainActor (DomainDelegationScopeRecord) -> Bool,
        isLeaseCurrent: @escaping @MainActor (DomainDelegationScopeLease) -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.source = source
        self.scopeChain = scopeChain
        self.isScopeCurrent = isScopeCurrent
        self.isLeaseCurrent = isLeaseCurrent
        self.now = now
    }

    func perform(_ batch: AgentSessionAdministrationAuthorizedBatch) async throws -> Value {
        let args = batch.request.arguments
        // Validate before the (possibly slow) snapshot.
        let filter = batch.request.operation == .adminInventory ? try AgentSessionAdminArguments.filter(args["filter"]) : nil
        let limit = try AgentSessionAdminArguments.limit(args)
        let snapshot = await source.snapshot()
        // Re-check authority after the suspension: a revoked or expired scope reveals nothing.
        guard isScopeCurrent(batch.scope), batch.leases.allSatisfy(isLeaseCurrent) else {
            throw SessionAdminMCPToolService.unavailableError
        }
        let visibility = AgentSessionScopeVisibility(chain: scopeChain(batch.scope.id))
        let date = now()
        func visible(_ id: UUID) -> DomainAgentSessionInventoryRecord? {
            snapshot.records[id].flatMap { visibility.isVisible($0, in: snapshot) ? $0 : nil }
        }

        switch batch.request.operation {
        case .adminInventory:
            let matches = snapshot.records.values
                .filter { visibility.isVisible($0, in: snapshot) }
                .filter { filter?.matchesStructured($0, in: snapshot, now: date) ?? true }
                .filter { AgentSessionInventoryRendering.matchesQuery(filter?.query, record: $0) }
                .sorted { lhs, rhs in
                    if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
                    return lhs.sessionID.uuidString < rhs.sessionID.uuidString
                }
            return .object([
                "result": .string("ok"),
                "total": .int(matches.count),
                "truncated": .bool(matches.count > limit),
                "history_complete": .bool(snapshot.isComplete),
                "sessions": .array(matches.prefix(limit).map {
                    AgentSessionInventoryRendering.row($0, snapshot: snapshot, now: date)
                })
            ])

        case .adminGet:
            guard let target = batch.admittedSessionIDs.first, let record = visible(target) else {
                throw SessionAdminMCPToolService.unavailableError
            }
            var row = AgentSessionInventoryRendering.row(record, snapshot: snapshot, now: date).objectValue ?? [:]
            row["links"] = .array(snapshot.edges(touching: target).map {
                AgentSessionInventoryRendering.edge($0, snapshot: snapshot)
            })
            row["children"] = .array(
                snapshot.records.values
                    .filter { $0.effectiveParentID == target && visibility.isVisible($0, in: snapshot) }
                    .sorted { $0.lastActivityAt > $1.lastActivityAt }
                    .map { .string($0.sessionID.uuidString) }
            )
            return .object(["result": .string("ok"), "session": .object(row)])

        case .adminTree:
            let rootID = batch.request.targetSessionIDs.first ?? defaultRoot(batch)
            guard let rootID, let root = visible(rootID) else { throw SessionAdminMCPToolService.unavailableError }
            var childrenByParent: [UUID: [DomainAgentSessionInventoryRecord]] = [:]
            for record in snapshot.records.values where visibility.isVisible(record, in: snapshot) {
                if let parent = record.effectiveParentID, parent != record.sessionID {
                    childrenByParent[parent, default: []].append(record)
                }
            }
            var budget = limit
            var seen: Set<UUID> = []
            func node(_ record: DomainAgentSessionInventoryRecord, depth: Int) -> Value {
                budget -= 1
                seen.insert(record.sessionID)
                var object: [String: Value] = [
                    "session_id": .string(record.sessionID.uuidString),
                    "name": .string(record.name),
                    "state": .string(record.runState.rawValue),
                    "archived": .bool(record.isArchived),
                    "pinned": .bool(record.isPinned),
                    "observes": .array(
                        snapshot.edges(touching: record.sessionID)
                            .filter { $0.observerSessionID == record.sessionID }
                            .map { .string($0.targetSessionID.uuidString) }
                    )
                ]
                if let group = record.sidebarGroup { object["group"] = .string(group) }
                let children = (childrenByParent[record.sessionID] ?? [])
                    .filter { !seen.contains($0.sessionID) }
                    .sorted { $0.lastActivityAt > $1.lastActivityAt }
                if depth < Self.maxTreeDepth {
                    var rendered: [Value] = []
                    for child in children where budget > 0 {
                        rendered.append(node(child, depth: depth + 1))
                    }
                    if !rendered.isEmpty { object["children"] = .array(rendered) }
                    if rendered.count < children.count { object["children_truncated"] = .bool(true) }
                } else if !children.isEmpty {
                    object["children_truncated"] = .bool(true)
                }
                return .object(object)
            }
            return .object(["result": .string("ok"), "tree": node(root, depth: 0)])

        case .adminLinks:
            let focus = batch.request.targetSessionIDs.first
            let edges = snapshot.edges.filter { edge in
                if let focus, !edge.touches(focus) { return false }
                return visible(edge.observerSessionID) != nil || visible(edge.targetSessionID) != nil
            }
            return .object([
                "result": .string("ok"),
                "total": .int(edges.count),
                "truncated": .bool(edges.count > limit),
                "history_complete": .bool(snapshot.isComplete),
                "links": .array(edges.prefix(limit).map { AgentSessionInventoryRendering.edge($0, snapshot: snapshot) })
            ])

        default:
            throw AgentSessionAdminArguments.invalid("\(batch.request.operation.adminOperationName) is not an inventory op.")
        }
    }

    private func defaultRoot(_ batch: AgentSessionAdministrationAuthorizedBatch) -> UUID? {
        if case let .tree(rootSessionID) = batch.scope.grant.kind { return rootSessionID }
        return batch.request.caller.agentSessionID
    }
}
