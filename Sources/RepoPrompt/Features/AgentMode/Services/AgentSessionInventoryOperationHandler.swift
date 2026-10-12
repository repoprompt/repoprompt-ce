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
        try Task.checkCancellation()
        let chain = scopeChain(batch.scope.id)
        var read = AgentSessionInventoryRead.scoped(chain: chain, filter: filter)
        let exactGet = batch.request.operation == .adminGet && !batch.admittedSessionIDs.isEmpty
        if exactGet {
            read.loadedOnly = true
            read.sessionIDs = Set(batch.admittedSessionIDs)
        }
        let full: DomainAgentSessionInventorySnapshot
        do {
            full = try await source.snapshot(read: read)
        } catch let failure as AgentSessionInventoryReadFailure {
            // Operational outcomes are disclosed only to the still-authorized grantee. Revocation
            // while a read expires remains the same uniform denial, never a recoverable budget code.
            try checkAuthority(batch, chain: chain)
            return failure.value
        }
        let boundedGet = exactGet && !full.isComplete
        try checkAuthority(batch, chain: chain)
        if !full.isComplete, filter?.hasLinks != nil || filter?.role != nil || filter?.orphaned != nil {
            // Read predicates can feed a later explicit mutation just as target-shaping filters can.
            // Never report candidate IDs obtained by treating an unknown endpoint census as false.
            return AgentSessionInventoryReadFailure.incomplete.value
        }
        // Membership is decided on the full snapshot; everything rendered, counted, filtered, or
        // classified below comes from the scope-restricted view, so no output can name, count, or
        // reflect a session outside the scope.
        let visibility = AgentSessionScopeVisibility(chain: scopeChain(batch.scope.id))
        let snapshot = full.restricted(to: Set(
            full.records.values
                .filter {
                    // An exact get already carries current app-owned target leases. Its partial
                    // read need not rediscover a potentially cross-workspace tree ancestry.
                    boundedGet ? batch.admittedSessionIDs.contains($0.sessionID) : visibility.isVisible($0, in: full)
                }
                .map(\.sessionID)
        ))
        let date = now()
        func visible(_ id: UUID) -> DomainAgentSessionInventoryRecord? {
            snapshot.records[id]
        }

        switch batch.request.operation {
        case .adminInventory:
            let matches = snapshot.records.values
                .filter { filter?.matchesStructured($0, in: snapshot, now: date) ?? true }
                .filter { AgentSessionInventoryRendering.matchesQuery(filter?.query, record: $0) }
                .sorted { lhs, rhs in
                    if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
                    return lhs.sessionID.uuidString < rhs.sessionID.uuidString
                }
            return .object([
                "result": .string("ok"),
                "total": .int(matches.count),
                "total_complete": .bool(snapshot.isComplete),
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
            if boundedGet {
                // This bounded get deliberately does not census siblings or other endpoints. Do
                // not turn unknown link/orphan facts into authoritative zero/false fields.
                for key in ["link_count", "roles", "orphaned", "orphan_reasons"] {
                    row.removeValue(forKey: key)
                }
            }
            row["links_complete"] = .bool(!boundedGet && snapshot.isComplete)
            row["children_complete"] = .bool(!boundedGet && snapshot.isComplete)
            if !boundedGet {
                row["links"] = .array(snapshot.edges(touching: target).map {
                    AgentSessionInventoryRendering.edge($0, snapshot: snapshot)
                })
                row["children"] = .array(
                    snapshot.records.values
                        .filter { $0.effectiveParentID == target }
                        .sorted { $0.lastActivityAt > $1.lastActivityAt }
                        .map { .string($0.sessionID.uuidString) }
                )
            }
            return .object([
                "result": .string("ok"), "history_complete": .bool(snapshot.isComplete), "session": .object(row)
            ])

        case .adminTree:
            let rootID = batch.request.targetSessionIDs.first ?? defaultRoot(batch)
            guard let rootID, let root = visible(rootID) else { throw SessionAdminMCPToolService.unavailableError }
            var childrenByParent: [UUID: [DomainAgentSessionInventoryRecord]] = [:]
            for record in snapshot.records.values {
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
                    "children_complete": .bool(snapshot.isComplete),
                    "observes_complete": .bool(snapshot.isComplete),
                    "observes": .array(
                        snapshot.edges(touching: record.sessionID)
                            .filter { $0.observerSessionID == record.sessionID && visible($0.targetSessionID) != nil }
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
            return .object([
                "result": .string("ok"), "history_complete": .bool(snapshot.isComplete), "tree": node(root, depth: 0)
            ])

        case .adminLinks:
            let focus = batch.request.targetSessionIDs.first
            if let focus, visible(focus) == nil { throw SessionAdminMCPToolService.unavailableError }
            let edges = snapshot.edges.filter { edge in
                focus.map(edge.touches) ?? true
            }
            return .object([
                "result": .string("ok"),
                "total": .int(edges.count),
                "total_complete": .bool(snapshot.isComplete),
                "truncated": .bool(edges.count > limit),
                "history_complete": .bool(snapshot.isComplete),
                "links": .array(edges.prefix(limit).map { AgentSessionInventoryRendering.edge($0, snapshot: snapshot) })
            ])

        default:
            throw AgentSessionAdminArguments.invalid("\(batch.request.operation.adminOperationName) is not an inventory op.")
        }
    }

    private func checkAuthority(
        _ batch: AgentSessionAdministrationAuthorizedBatch,
        chain: [DomainDelegationScopeRecord]
    ) throws {
        try Task.checkCancellation()
        let currentChain = scopeChain(batch.scope.id)
        guard isScopeCurrent(batch.scope), !chain.isEmpty, chain.count == currentChain.count,
              zip(chain, currentChain).allSatisfy({ before, after in
                  before.id == after.id && before.generation == after.generation && isScopeCurrent(after)
              }), batch.leases.allSatisfy(isLeaseCurrent)
        else {
            throw SessionAdminMCPToolService.unavailableError
        }
    }

    private func defaultRoot(_ batch: AgentSessionAdministrationAuthorizedBatch) -> UUID? {
        if case let .tree(rootSessionID) = batch.scope.grant.kind { return rootSessionID }
        return batch.request.caller.agentSessionID
    }
}
