import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptShared

// Shared parsing, rendering, and inventory projection for the organizing `session_admin` ops
// (inventory, organize, release). Handlers derive every effect from `request.arguments`, which a
// batch card binds, so an approved card applies exactly what the user saw.

// MARK: - Arguments

enum AgentSessionAdminArguments {
    static let maxTargets = 256
    static let defaultInventoryLimit = 100
    static let maxInventoryLimit = 500

    static func invalid(_ message: String) -> MCPError {
        MCPError.invalidParams("session_admin \(message)")
    }

    static func string(_ args: [String: Value], _ key: String) throws -> String? {
        guard let raw = args[key], !raw.isAdminNull else { return nil }
        guard let text = raw.stringValue else { throw invalid("\(key) must be a string.") }
        return text
    }

    static func bool(_ args: [String: Value], _ key: String) throws -> Bool? {
        guard let raw = args[key], !raw.isAdminNull else { return nil }
        guard let flag = raw.boolValue else { throw invalid("\(key) must be a boolean.") }
        return flag
    }

    static func uuid(_ args: [String: Value], _ key: String) throws -> UUID? {
        guard let text = try string(args, key) else { return nil }
        guard let id = UUID(uuidString: text) else { throw invalid("\(key) must be a UUID string.") }
        return id
    }

    static func strings(_ args: [String: Value], _ key: String) throws -> [String]? {
        guard let raw = args[key], !raw.isAdminNull else { return nil }
        guard let array = raw.arrayValue, array.count <= maxTargets else {
            throw invalid("\(key) must be an array of at most \(maxTargets) strings.")
        }
        return try array.map { element in
            guard let text = element.stringValue else { throw invalid("\(key) must contain only strings.") }
            return text
        }
    }

    static func uuids(_ args: [String: Value], _ key: String) throws -> [UUID]? {
        guard let texts = try strings(args, key) else { return nil }
        var seen: Set<UUID> = []
        return try texts.map { text in
            guard let id = UUID(uuidString: text), seen.insert(id).inserted else {
                throw invalid("\(key) must contain unique session UUIDs.")
            }
            return id
        }
    }

    static func limit(_ args: [String: Value]) throws -> Int {
        guard let raw = args["limit"], !raw.isAdminNull else { return defaultInventoryLimit }
        guard let value = raw.intValue, value >= 1, value <= maxInventoryLimit else {
            throw invalid("limit must be an integer 1...\(maxInventoryLimit).")
        }
        return value
    }

    // MARK: Filter

    static let filterKeys: Set<String> = [
        "workspace", "root_overseer", "state", "pinned", "group", "query", "idle_days_gt",
        "created_before", "created_after", "has_links", "role", "orphaned", "archived", "loaded"
    ]

    /// Parses the structured inventory filter. Unknown keys are rejected rather than ignored, so a
    /// typo can never silently widen a bulk mutation.
    static func filter(_ raw: Value?) throws -> DomainAgentSessionInventoryFilter? {
        guard let raw, !raw.isAdminNull else { return nil }
        guard let object = raw.objectValue else { throw invalid("filter must be an object.") }
        for key in object.keys.sorted() where !filterKeys.contains(key) {
            throw invalid("filter does not support '\(key)'.")
        }
        var filter = DomainAgentSessionInventoryFilter()
        filter.workspaceID = try uuid(object, "workspace")
        filter.rootOverseerSessionID = try uuid(object, "root_overseer")
        if let state = object["state"], !state.isAdminNull {
            let texts: [String] = if let text = state.stringValue { [text] } else { try strings(object, "state") ?? [] }
            var states: Set<DomainAgentSessionInventoryRunState> = []
            for text in texts {
                guard let parsed = DomainAgentSessionInventoryRunState.parseFilter(text) else {
                    throw invalid("filter.state must be idle, running, waiting, active, completed, cancelled, failed, or unknown.")
                }
                states.formUnion(parsed)
            }
            filter.states = states
        }
        filter.pinned = try bool(object, "pinned")
        if object.keys.contains("group") {
            if let text = try string(object, "group"), !text.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let name = DomainAgentSessionSidebarGroup.normalizedName(text) else {
                    throw invalid("filter.group must be a group name of at most \(DomainAgentSessionSidebarGroup.maxNameCharacters) characters.")
                }
                filter.group = .named(name)
            } else {
                filter.group = DomainAgentSessionInventoryFilter.GroupMatch.none
            }
        }
        filter.query = try string(object, "query").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        if let raw = object["idle_days_gt"], !raw.isAdminNull {
            guard let days = raw.intValue, days >= 0 else { throw invalid("filter.idle_days_gt must be an integer >= 0.") }
            filter.idleDaysGreaterThan = days
        }
        filter.createdBefore = try date(object, "created_before")
        filter.createdAfter = try date(object, "created_after")
        filter.hasLinks = try bool(object, "has_links")
        if let role = try string(object, "role") {
            guard let parsed = DomainAgentSessionInventoryRole(rawValue: role.lowercased()) else {
                throw invalid("filter.role must be overseer or overseen.")
            }
            filter.role = parsed
        }
        filter.orphaned = try bool(object, "orphaned")
        filter.archived = try bool(object, "archived")
        filter.loaded = try bool(object, "loaded")
        return filter
    }

    private static func date(_ object: [String: Value], _ key: String) throws -> Date? {
        guard let text = try string(object, key) else { return nil }
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        let dayOnly = ISO8601DateFormatter()
        dayOnly.formatOptions = [.withFullDate]
        if let date = dayOnly.date(from: text) { return date }
        throw invalid("filter.\(key) must be an ISO 8601 date or date-time.")
    }
}

private extension Value {
    var isAdminNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - Results

/// One per-item outcome in a mutating op's reply.
struct AgentSessionAdminItemResult {
    enum Status: String {
        case changed
        case unchanged
        case skipped
        case failed
    }

    let sessionID: UUID
    let status: Status
    var reason: String?
    var detail: [String: Value] = [:]

    var value: Value {
        var object = detail
        object["session_id"] = .string(sessionID.uuidString)
        object["status"] = .string(status.rawValue)
        if let reason { object["reason"] = .string(reason) }
        return .object(object)
    }
}

enum AgentSessionAdminRendering {
    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Set (to `true`) when a call committed durable side effects that per-item `changed` statuses
    /// do not show, for example a release whose first unlink succeeded before a later one failed.
    static let committedChangesKey = "committed_changes"

    /// Standard reply for a mutating op.
    static func mutationValue(
        operation: DomainAgentSessionTargetOperation,
        items: [AgentSessionAdminItemResult],
        itemsRequiringControl: [UUID],
        extra: [String: Value] = [:]
    ) -> Value {
        var object = extra
        object["result"] = .string(mutationResult(
            statuses: items.map(\.status),
            requiresControl: !itemsRequiringControl.isEmpty,
            committedChanges: extra[committedChangesKey] == .bool(true)
        ))
        object["op"] = .string(operation.adminOperationName)
        object["items"] = .array(items.map(\.value))
        object["changed_count"] = .int(items.count(where: { $0.status == .changed }))
        if !itemsRequiringControl.isEmpty {
            object["requires_control"] = .array(itemsRequiringControl.map { .string($0.uuidString) })
        }
        return .object(object)
    }

    /// Recompute only the organizing/release receipt family after the front door appends targets.
    /// Structural replies have their own item/effect semantics and are not interpreted here.
    static func refreshingOrganizingResult(_ object: [String: Value]) -> [String: Value] {
        let operations: Set = [
            "rename", "set_pin", "reorder_pins", "set_group", "reorder_groups",
            "archive", "unarchive", "release", "retire"
        ]
        guard let operation = object["op"]?.stringValue, operations.contains(operation),
              let items = object["items"]?.arrayValue else { return object }
        let statuses = items.compactMap { item -> AgentSessionAdminItemResult.Status? in
            guard let status = item.objectValue?["status"]?.stringValue else { return nil }
            return AgentSessionAdminItemResult.Status(rawValue: status)
        }
        guard statuses.count == items.count else { return object }
        var result = object
        result["result"] = .string(mutationResult(
            statuses: statuses,
            requiresControl: !(object["requires_control"]?.arrayValue ?? []).isEmpty,
            committedChanges: object[committedChangesKey] == .bool(true)
        ))
        result["changed_count"] = .int(statuses.count(where: { $0 == .changed }))
        return result
    }

    private static func mutationResult(
        statuses: [AgentSessionAdminItemResult.Status], requiresControl: Bool, committedChanges: Bool
    ) -> String {
        let effects = committedChanges || statuses.contains(.changed)
        let failed = statuses.contains(.failed)
        let incomplete = failed || statuses.contains(.skipped) || requiresControl
        if effects { return incomplete ? "partial" : "applied" }
        if failed { return "failed" }
        if incomplete || statuses.isEmpty { return "not_applied" }
        return "unchanged"
    }
}

extension DomainAgentSessionTargetOperation {
    /// `session_admin.set_pin` → `set_pin`.
    var adminOperationName: String {
        rawValue.hasPrefix("session_admin.") ? String(rawValue.dropFirst("session_admin.".count)) : rawValue
    }
}

// MARK: - Scope visibility

/// Which inventory records a scope (and every ancestor of an attenuated scope) can see. Membership
/// is computed from app-owned provenance in the snapshot, never from arguments.
struct AgentSessionScopeVisibility {
    let chain: [DomainDelegationScopeRecord]

    func isVisible(_ record: DomainAgentSessionInventoryRecord, in snapshot: DomainAgentSessionInventorySnapshot) -> Bool {
        chain.allSatisfy { scope in
            switch scope.grant.kind {
            case let .session(target):
                record.sessionID == target || record.sessionID == scope.grant.granteeSessionID
            case .allSessions:
                true
            case let .workspace(workspaceID):
                record.workspaceID == workspaceID
            case let .tree(rootSessionID):
                snapshot.isInTree(record.sessionID, rootSessionID: rootSessionID)
            }
        }
    }
}

// MARK: - Inventory source

enum AgentSessionInventoryReadFailure: Error, Equatable {
    case budgetExceeded
    case incomplete

    var value: Value {
        .object([
            "result": .string("incomplete"),
            "code": .string(self == .budgetExceeded ? "inventory_budget_exceeded" : "inventory_incomplete"),
            "retryable": .bool(true)
        ])
    }
}

enum AgentSessionInventoryInvocation {
    static let budgetTaskLocal = BoxedTaskLocal<HistoryRequestBudget?>(nil)
    static var budget: HistoryRequestBudget? {
        budgetTaskLocal.get()
    }
}

/// A backend read plan, distinct from the output filter. Never use an output predicate to discard
/// in-scope link endpoints needed by role/link filters or bulk target selection.
struct AgentSessionInventoryRead {
    var workspaceID: UUID?
    var loadedOnly = false
    var sessionIDs: Set<UUID>?
    /// Exact history provenance probes, never a global history inventory. Ancestors are followed
    /// only from persisted metadata, with a finite total lookup cap and the invocation budget.
    var historyTargetIDs: Set<UUID>?
    var budget: HistoryRequestBudget = AgentSessionInventoryInvocation.budget ?? .standalone()

    /// Ordinary trees are an explicitly partial census of loaded carriers across all windows.
    /// Absence/link/role predicates still require history; output workspace filters never discard
    /// the loaded ancestry or endpoints needed to decide tree membership and redact links.
    static func scoped(
        chain: [DomainDelegationScopeRecord],
        filter: DomainAgentSessionInventoryFilter? = nil
    ) -> AgentSessionInventoryRead {
        let isTree = chain.contains { if case .tree = $0.grant.kind { return true }
            return false
        }
        let needsGlobal = filter?.orphaned != nil || filter?.hasLinks != nil || filter?.role != nil
            || (!isTree && filter?.rootOverseerSessionID != nil)
        let workspace = chain.compactMap { scope -> UUID? in
            if case let .workspace(id) = scope.grant.kind { return id }
            return nil
        }.first ?? (isTree || needsGlobal ? nil : filter?.workspaceID)
        return AgentSessionInventoryRead(
            workspaceID: isTree || needsGlobal ? nil : workspace,
            loadedOnly: isTree && !needsGlobal
        )
    }
}

/// Produces snapshots over loaded sessions, the history index, and live/durable links.
@MainActor
protocol AgentSessionInventorySource: AnyObject {
    func snapshot() async -> DomainAgentSessionInventorySnapshot
    func snapshot(read: AgentSessionInventoryRead) async throws -> DomainAgentSessionInventorySnapshot
}

extension AgentSessionInventorySource {
    func snapshot(read _: AgentSessionInventoryRead) async throws -> DomainAgentSessionInventorySnapshot {
        try Task.checkCancellation()
        let result = await snapshot()
        try Task.checkCancellation()
        return result
    }
}

/// Production inventory over open windows, the cross-workspace history index, and the bridge.
@MainActor
final class LiveAgentSessionInventorySource: AgentSessionInventorySource {
    private let scanner: any HistorySessionScanning
    private let windows: @MainActor () -> [WindowState]
    private let links: @MainActor () async -> (live: [DomainAgentSessionLinkInventoryItem], persisted: [AgentSessionOversightIntent])

    init(
        scanner: any HistorySessionScanning = HistorySessionScanner(),
        windows: @escaping @MainActor () -> [WindowState] = { WindowStatesManager.shared.allWindows },
        links: @escaping @MainActor () async -> (
            live: [DomainAgentSessionLinkInventoryItem],
            persisted: [AgentSessionOversightIntent]
        ) = { await AgentSessionLinkRuntimeBridge.shared.oversightInventory(includeLocation: false) }
    ) {
        self.scanner = scanner
        self.windows = windows
        self.links = links
    }

    func snapshot() async -> DomainAgentSessionInventorySnapshot {
        // Compatibility for nonthrowing injected consumers. Administrative reads use the throwing
        // entry point below, so cancellation is never converted into a successful empty response.
        await (try? snapshot(read: AgentSessionInventoryRead()))
            ?? DomainAgentSessionInventorySnapshot(records: [], edges: [], isComplete: false)
    }

    func snapshot(read: AgentSessionInventoryRead) async throws -> DomainAgentSessionInventorySnapshot {
        try Task.checkCancellation()
        var records: [DomainAgentSessionInventoryRecord] = []
        var isComplete = false
        var recordsComplete = false
        var historyByID: [UUID: (AgentSessionMetadataRecord, String)] = [:]
        if let targets = read.historyTargetIDs {
            var pending = Array(targets)
            var visited: Set<UUID> = []
            while let id = pending.popLast() {
                guard visited.insert(id).inserted else { continue }
                guard visited.count <= 256 else { throw AgentSessionInventoryReadFailure.incomplete }
                try await Self.projectionCheckpoint(projected: visited.count, budget: read.budget)
                let lookup: HistoryDirectSessionLookup
                do {
                    lookup = try await scanner.locateSession(sessionID: id, requestBudget: read.budget)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as HistorySessionScannerError {
                    try Task.checkCancellation()
                    if case .workBudgetExceeded = error { throw AgentSessionInventoryReadFailure.budgetExceeded }
                    throw AgentSessionInventoryReadFailure.incomplete
                } catch {
                    try Task.checkCancellation()
                    throw AgentSessionInventoryReadFailure.incomplete
                }
                try await Self.projectionCheckpoint(projected: visited.count, budget: read.budget)
                guard lookup.isComplete else { throw AgentSessionInventoryReadFailure.incomplete }
                guard let location = lookup.location else { continue }
                let metadata = try await exactMetadata(location: location, sessionID: id, budget: read.budget)
                let record = metadata.record
                guard record.id == id else { throw AgentSessionInventoryReadFailure.incomplete }
                historyByID[id] = (record, location.workspaceName)
                records.append(DomainAgentSessionInventoryRecord(
                    sessionID: id, name: record.name, workspaceID: metadata.workspaceID,
                    workspaceName: location.workspaceName, isLoaded: false,
                    organizationStateIsKnown: false,
                    runState: .classify(rawValue: record.lastRunStateRaw),
                    parentSessionID: record.parentSessionID,
                    createdByOverseerSessionID: record.createdByOverseerSessionID,
                    organizationalParentID: record.organizationalParentID,
                    createdAt: record.firstActivityAt, lastActivityAt: record.activityDate,
                    worktreeCount: record.worktreeBindingSummaries.count
                ))
                if let parent = record.organizationalParentID ?? record.parentSessionID ?? record.createdByOverseerSessionID {
                    pending.append(parent)
                }
            }
        } else if !read.loadedOnly {
            do {
                let scan = try await scanner.scanWorkspaces(
                    matching: read.workspaceID?.uuidString, requestBudget: read.budget
                )
                try Task.checkCancellation()
                // A workspace-local scan cannot prove that an endpoint in another workspace is gone.
                recordsComplete = Self.isComplete(scan)
                isComplete = read.workspaceID == nil && recordsComplete
                var projected = 0
                for workspace in scan.workspaces {
                    for record in workspace.records {
                        try await Self.projectionCheckpoint(projected: projected, budget: read.budget)
                        projected += 1
                        guard read.workspaceID == nil || (record.workspaceID ?? workspace.workspaceID) == read.workspaceID else { continue }
                        historyByID[record.id] = (record, workspace.workspaceName)
                        records.append(Self.historyRecord(record, workspace: workspace))
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AgentSessionInventoryReadFailure {
                throw error
            } catch let error as HistorySessionScannerError {
                try Task.checkCancellation()
                if case .workBudgetExceeded = error { throw AgentSessionInventoryReadFailure.budgetExceeded }
                isComplete = false
            } catch {
                // History I/O/budget failures never prove deletion, and must not expose filesystem
                // details through the administration surface. Keep the app-owned loaded projection.
                try Task.checkCancellation()
                isComplete = false
            }
        }
        try Task.checkCancellation()
        let loaded = try await loadedRecords(historyByID: historyByID, read: read)
        records.append(contentsOf: loaded.records)
        isComplete = isComplete && loaded.isComplete
        try await Self.projectionCheckpoint(projected: records.count, budget: read.budget)
        let (live, persisted) = await links()
        try Task.checkCancellation()
        guard read.budget.elapsedDiagnostic(phase: "session_admin_projection") == nil else {
            throw AgentSessionInventoryReadFailure.budgetExceeded
        }
        let edges = DomainAgentSessionInventoryEdge.merge(
            live: live.map { ($0.observerSessionID, $0.targetSessionID, $0.linkID, $0.generation) },
            persisted: persisted.map { ($0.observerSessionID, $0.targetSessionID) }
        )
        try Task.checkCancellation()
        let snapshot = DomainAgentSessionInventorySnapshot(
            records: records, edges: edges,
            isComplete: isComplete && read.budget.elapsedDiagnostic(phase: "session_admin_projection") == nil,
            recordsComplete: recordsComplete && loaded.isComplete
        )
        try Task.checkCancellation()
        // The immutable snapshot's dictionary/edge indexing is synchronous. Never hand back a
        // globally complete census if that final construction itself consumed the remaining budget.
        guard read.budget.elapsedDiagnostic(phase: "session_admin_projection") == nil else {
            throw AgentSessionInventoryReadFailure.budgetExceeded
        }
        return snapshot
    }

    /// A cold direct lookup proves the file's location, not its metadata. Read only that
    /// signature-checked storage directory's index under the same invocation budget. Never
    /// substitute a global census, transcript hydration, or caller-supplied ancestry.
    private func exactMetadata(
        location: HistoryDirectSessionLocation, sessionID: UUID, budget: HistoryRequestBudget
    ) async throws -> (record: AgentSessionMetadataRecord, workspaceID: UUID?) {
        if let record = location.record, let workspaceID = record.workspaceID {
            return (record, workspaceID)
        }
        // Legacy records may omit workspaceID even in a warm cache. Resolve their placement
        // only from the exact scanner-owned workspace identity, never from the grant or target.
        let scan: HistoryInventoryScan
        do {
            scan = try await scanner.scanWorkspaces(
                matching: location.workspaceDir.lastPathComponent, requestBudget: budget
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HistorySessionScannerError {
            try Task.checkCancellation()
            if case .workBudgetExceeded = error { throw AgentSessionInventoryReadFailure.budgetExceeded }
            throw AgentSessionInventoryReadFailure.incomplete
        } catch {
            try Task.checkCancellation()
            throw AgentSessionInventoryReadFailure.incomplete
        }
        try await Self.projectionCheckpoint(projected: 0, budget: budget)
        guard Self.isComplete(scan),
              let workspace = scan.workspaces.first(where: { $0.workspaceDir.standardizedFileURL == location.workspaceDir.standardizedFileURL }),
              let record = workspace.records.first(where: { $0.id == sessionID })
        else {
            throw AgentSessionInventoryReadFailure.incomplete
        }
        return (record, record.workspaceID ?? workspace.workspaceID)
    }

    /// A scan is complete only when it covered every workspace and read every index in full. An
    /// unreadable index or one written under a different schema (its records are skipped) leaves
    /// sessions unaccounted for, so absence-based orphan detection must stay off.
    static func isComplete(_ scan: HistoryInventoryScan) -> Bool {
        !scan.isTruncated && !scan.workspaces.contains { $0.indexReadFailed || $0.indexSchemaVersion != nil }
    }

    private static func historyRecord(
        _ record: AgentSessionMetadataRecord,
        workspace: HistoryWorkspaceScanResult
    ) -> DomainAgentSessionInventoryRecord {
        DomainAgentSessionInventoryRecord(
            sessionID: record.id,
            name: record.name,
            workspaceID: record.workspaceID ?? workspace.workspaceID,
            workspaceName: workspace.workspaceName,
            isLoaded: false,
            organizationStateIsKnown: false,
            runState: .classify(rawValue: record.lastRunStateRaw),
            parentSessionID: record.parentSessionID,
            createdByOverseerSessionID: record.createdByOverseerSessionID,
            organizationalParentID: record.organizationalParentID,
            createdAt: record.firstActivityAt,
            lastActivityAt: record.activityDate,
            worktreeCount: record.worktreeBindingSummaries.count
        )
    }

    /// Yield without a detached cache or a second authority. The caller rechecks leases after the
    /// entire snapshot. Deadline exhaustion fails closed: omitted edges must never become factual
    /// no-links predicates that widen a filtered mutation.
    private static func projectionCheckpoint(projected: Int, budget: HistoryRequestBudget) async throws {
        try Task.checkCancellation()
        if projected > 0, projected.isMultiple(of: 64) {
            await Task.yield()
            try Task.checkCancellation()
        }
        let hasTime = budget.elapsedDiagnostic(phase: "session_admin_projection") == nil
        try Task.checkCancellation()
        guard hasTime else { throw AgentSessionInventoryReadFailure.budgetExceeded }
    }

    static func exactTabMatches(_ tab: ComposeTabState, sessionID: UUID, indexTabID: UUID?) -> Bool {
        tab.activeAgentSessionID == sessionID || (tab.activeAgentSessionID == nil && tab.id == indexTabID)
    }

    private enum LoadedRuntimeObservation {
        case live(DomainAgentSessionInventoryRunState)
        case fallback(DomainAgentSessionInventoryRunState)
        case bindingConflict
    }

    /// Keep evidence rather than just the chosen value: a fallback between two disagreeing live
    /// observations must not hide the conflict. Fallback disagreement matters only without live
    /// evidence, so resolution happens after every window has contributed, independent of order.
    private struct LoadedRuntimeEvidence {
        var liveStates: Set<DomainAgentSessionInventoryRunState> = []
        var fallbackStates: Set<DomainAgentSessionInventoryRunState> = []
        var hasBindingConflict = false

        mutating func observe(_ observation: LoadedRuntimeObservation) {
            switch observation {
            case let .live(state): liveStates.insert(state)
            case let .fallback(state): fallbackStates.insert(state)
            case .bindingConflict: hasBindingConflict = true
            }
        }

        func resolved() throws -> DomainAgentSessionInventoryRunState {
            guard !hasBindingConflict, liveStates.count <= 1 else {
                throw AgentSessionInventoryReadFailure.incomplete
            }
            if let live = liveStates.first { return live }
            guard fallbackStates.count == 1, let fallback = fallbackStates.first else {
                throw AgentSessionInventoryReadFailure.incomplete
            }
            return fallback
        }
    }

    private struct LoadedCarrierProjection {
        /// Physical uniqueness is established by the shared carrier capture. Runtime is compared
        /// separately here; every other rendered fact must still agree across window replicas.
        let record: DomainAgentSessionInventoryRecord
        var runtime = LoadedRuntimeEvidence()

        mutating func merge(
            record: DomainAgentSessionInventoryRecord, observation: LoadedRuntimeObservation
        ) throws {
            guard self.record == record else { throw AgentSessionInventoryReadFailure.incomplete }
            runtime.observe(observation)
        }

        func resolvedRecord() throws -> DomainAgentSessionInventoryRecord {
            try DomainAgentSessionInventoryRecord(
                sessionID: record.sessionID, name: record.name,
                workspaceID: record.workspaceID, workspaceName: record.workspaceName,
                isLoaded: record.isLoaded, organizationStateIsKnown: record.organizationStateIsKnown,
                isArchived: record.isArchived, isPinned: record.isPinned,
                pinnedOrder: record.pinnedOrder, sidebarGroup: record.sidebarGroup,
                sidebarGroupOrder: record.sidebarGroupOrder,
                runState: runtime.resolved(),
                parentSessionID: record.parentSessionID,
                createdByOverseerSessionID: record.createdByOverseerSessionID,
                organizationalParentID: record.organizationalParentID,
                createdAt: record.createdAt, lastActivityAt: record.lastActivityAt,
                worktreeCount: record.worktreeCount
            )
        }
    }

    private func loadedRecords(
        historyByID: [UUID: (AgentSessionMetadataRecord, String)],
        read: AgentSessionInventoryRead
    ) async throws -> (records: [DomainAgentSessionInventoryRecord], isComplete: Bool) {
        try Task.checkCancellation()
        let capture = AgentSessionCarrierResolver.capture(windows: windows(), sessionIDs: read.sessionIDs)
        let rows = capture.rows.filter { read.workspaceID == nil || $0.workspaceID == read.workspaceID }
        var affectedIDs = read.sessionIDs ?? Set(rows.map(\.sessionID))
        if read.sessionIDs == nil {
            for id in capture.ambiguousSessionIDs {
                if let workspaceID = read.workspaceID, !capture.affectedWorkspaceIDs(for: id).contains(workspaceID) { continue }
                affectedIDs.insert(id)
            }
        }
        guard capture.ambiguousSessionIDs.isDisjoint(with: affectedIDs) else {
            throw AgentSessionInventoryReadFailure.incomplete
        }
        let rowsByWindow = Dictionary(grouping: rows) { ObjectIdentifier($0.window) }
        var bindingStates: [ObjectIdentifier: [UUID: AgentModeViewModel.AuthoritativeLiveSessionState]] = [:]
        for (windowID, windowRows) in rowsByWindow {
            guard let window = windowRows.first?.window else { continue }
            bindingStates[windowID] = window.agentModeViewModel.authoritativeLiveSessionStates(
                for: Set(windowRows.filter { $0.stashedTabID == nil }.map(\.sessionID))
            )
        }
        // Capture runtime beside the synchronous physical/binding capture. A replacement live
        // object after a yield must never inherit the earlier object's binding proof.
        let observations: [LoadedRuntimeObservation] = rows.map { row in
            let candidateHistory = historyByID[row.sessionID]?.0
            let history = row.hasCurrentMetadataOwner && candidateHistory?.workspaceID == row.workspaceID ? candidateHistory : nil
            let fallback = DomainAgentSessionInventoryRunState.classify(rawValue: row.entry?.lastRunStateRaw ?? history?.lastRunStateRaw)
            if row.stashedTabID != nil { return .fallback(fallback) }
            let state = bindingStates[ObjectIdentifier(row.window)]?[row.sessionID]
            if state == .ambiguous { return .bindingConflict }
            if state == .idle || state == .running {
                guard let session = row.window.agentModeViewModel.sessions[row.tab.id], session.activeAgentSessionID == row.sessionID else {
                    return .fallback(.unknown)
                }
                return .live(.classify(rawValue: session.runState.rawValue))
            }
            return .fallback(fallback)
        }
        var projections: [UUID: LoadedCarrierProjection] = [:]
        var projected = 0
        for (row, observation) in zip(rows, observations) {
            try await Self.projectionCheckpoint(projected: projected, budget: read.budget)
            guard capture.isCurrent() else { throw AgentSessionInventoryReadFailure.incomplete }
            projected += 1
            let sessionID = row.sessionID
            let tab = row.tab
            let entry = row.entry
            let candidateHistory = historyByID[sessionID]?.0
            let history = row.hasCurrentMetadataOwner && candidateHistory?.workspaceID == row.workspaceID ? candidateHistory : nil
            let lastActivity = entry.map {
                AgentSessionRestoreSupport.sidebarActivityDate(lastUserMessageAt: $0.lastUserMessageAt, savedAt: $0.savedAt)
            } ?? history?.activityDate ?? tab.lastModified
            let record = DomainAgentSessionInventoryRecord(
                sessionID: sessionID,
                name: tab.name,
                workspaceID: row.workspaceID,
                workspaceName: row.workspaceName,
                isLoaded: true,
                isArchived: row.stashedTabID != nil,
                isPinned: tab.isPinned,
                pinnedOrder: tab.pinnedOrder,
                sidebarGroup: tab.sidebarGroup,
                sidebarGroupOrder: tab.sidebarGroupOrder,
                runState: .unknown,
                parentSessionID: entry?.parentSessionID,
                createdByOverseerSessionID: entry?.createdByOverseerSessionID,
                organizationalParentID: entry?.organizationalParentID,
                createdAt: history?.firstActivityAt,
                lastActivityAt: lastActivity,
                worktreeCount: entry?.worktreeBindingSummaries.count ?? history?.worktreeBindingSummaries.count ?? 0
            )
            if var existing = projections[sessionID] {
                try existing.merge(record: record, observation: observation)
                projections[sessionID] = existing
            } else {
                var projection = LoadedCarrierProjection(record: record)
                projection.runtime.observe(observation)
                projections[sessionID] = projection
            }
        }
        return try (projections.values.map { try $0.resolvedRecord() }, true)
    }
}

// MARK: - Inventory rendering

/// Renders inventory from a scope-restricted snapshot (`DomainAgentSessionInventorySnapshot.restricted`):
/// any session ID that is not a record of that view is either outside the scope (never rendered) or
/// known to be deleted (rendered as `missing`, without its ID).
enum AgentSessionInventoryRendering {
    static func row(
        _ record: DomainAgentSessionInventoryRecord,
        snapshot: DomainAgentSessionInventorySnapshot,
        now: Date
    ) -> Value {
        var object: [String: Value] = [
            "session_id": .string(record.sessionID.uuidString),
            "name": .string(record.name),
            "loaded": .bool(record.isLoaded),
            "organization_complete": .bool(record.organizationStateIsKnown),
            "state": .string(record.runState.rawValue),
            "last_activity_at": .string(AgentSessionAdminRendering.iso(record.lastActivityAt)),
            "idle_days": .int(snapshot.idleDays(record.sessionID, now: now) ?? 0),
            "worktree_count": .int(record.worktreeCount),
            "roles": .array(
                DomainAgentSessionInventoryRole.allCases
                    .filter(snapshot.roles(of: record.sessionID).contains)
                    .map { .string($0.rawValue) }
            ),
            "link_count": .int(snapshot.edges(touching: record.sessionID).count)
        ]
        if record.organizationStateIsKnown {
            object["archived"] = .bool(record.isArchived)
            object["pinned"] = .bool(record.isPinned)
            if let order = record.pinnedOrder { object["pinned_order"] = .int(order) }
            if let group = record.sidebarGroup { object["group"] = .string(group) }
            if let order = record.sidebarGroupOrder { object["group_order"] = .int(order) }
        }
        if let workspaceID = record.workspaceID { object["workspace_id"] = .string(workspaceID.uuidString) }
        if let workspaceName = record.workspaceName { object["workspace_name"] = .string(workspaceName) }
        // Provenance pointing outside the scope is redacted; orphan reasons cover deleted ones.
        if let parent = record.parentSessionID, snapshot.records[parent] != nil {
            object["parent_session_id"] = .string(parent.uuidString)
        }
        if let creator = record.createdByOverseerSessionID, snapshot.records[creator] != nil {
            object["created_by_overseer_session_id"] = .string(creator.uuidString)
        }
        if let createdAt = record.createdAt { object["created_at"] = .string(AgentSessionAdminRendering.iso(createdAt)) }
        let orphanReasons = snapshot.orphanReasons(for: record.sessionID)
        object["orphaned"] = .bool(!orphanReasons.isEmpty)
        if !orphanReasons.isEmpty {
            object["orphan_reasons"] = .array(orphanReasons.map { .string($0.rawValue) })
        }
        object["links_complete"] = .bool(snapshot.isComplete)
        let orphanComplete = snapshot.orphanStatusIsComplete(for: record.sessionID)
        object["orphan_status_complete"] = .bool(orphanComplete)
        if !orphanComplete {
            if !orphanReasons.isEmpty { object["known_orphan_reasons"] = .array(orphanReasons.map { .string($0.rawValue) }) }
            object.removeValue(forKey: "orphaned")
            object.removeValue(forKey: "orphan_reasons")
        }
        if !snapshot.isComplete {
            // Partial endpoints can prove positive observations, never zero links/no role/not
            // orphaned. Name lower bounds explicitly so callers cannot treat missing census as fact.
            let knownCount = snapshot.edges(touching: record.sessionID).count
            if knownCount > 0 {
                object["known_link_count"] = .int(knownCount)
                object["known_roles"] = object["roles"]
            }
            if !orphanReasons.isEmpty { object["known_orphan_reasons"] = object["orphan_reasons"] }
            for key in ["link_count", "roles", "orphaned", "orphan_reasons"] {
                object.removeValue(forKey: key)
            }
        }
        return .object(object)
    }

    static func edge(_ edge: DomainAgentSessionInventoryEdge, snapshot: DomainAgentSessionInventorySnapshot) -> Value {
        var object: [String: Value] = [
            "live": .bool(edge.isLive),
            "persisted": .bool(edge.isPersisted)
        ]
        for (role, id) in [("observer", edge.observerSessionID), ("target", edge.targetSessionID)] {
            if let record = snapshot.records[id] {
                object["\(role)_session_id"] = .string(id.uuidString)
                object["\(role)_name"] = .string(record.name)
            } else {
                // The restricted view keeps only edges whose other endpoints are deleted sessions.
                object[role] = .string("missing")
            }
        }
        if let observer = snapshot.records[edge.observerSessionID], observer.organizationStateIsKnown, observer.isArchived {
            object["observer_archived"] = .bool(true)
        }
        return .object(object)
    }

    /// Free-text query over name, workspace, group, and session ID, with the shared matcher.
    static func matchesQuery(_ query: String?, record: DomainAgentSessionInventoryRecord) -> Bool {
        guard let query else { return true }
        let parsed = AgentSessionSearchQuery.parse(query)
        guard !parsed.isEmpty else { return true }
        guard record.organizationStateIsKnown || !parsed.hasFacets else { return false }
        let fields = AgentSessionSearchFields(
            title: record.name,
            status: [record.runState.rawValue, record.organizationStateIsKnown && record.isArchived ? "archived" : nil],
            secondary: [record.workspaceName, record.organizationStateIsKnown ? record.sidebarGroup : nil],
            identifier: [record.sessionID.uuidString]
        ).withFacets(isPinned: record.isPinned, group: record.sidebarGroup)
        return AgentSessionSearchMatcher.matches(query: parsed, fields: fields)
    }
}
