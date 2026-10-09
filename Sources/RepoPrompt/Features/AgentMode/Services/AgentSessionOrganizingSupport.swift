import Foundation
import MCP
import RepoPromptDomainRuntime

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

    /// Standard reply for a mutating op.
    static func mutationValue(
        operation: DomainAgentSessionTargetOperation,
        items: [AgentSessionAdminItemResult],
        itemsRequiringControl: [UUID],
        extra: [String: Value] = [:]
    ) -> Value {
        var object = extra
        object["result"] = .string("applied")
        object["op"] = .string(operation.adminOperationName)
        object["items"] = .array(items.map(\.value))
        object["changed_count"] = .int(items.count(where: { $0.status == .changed }))
        if !itemsRequiringControl.isEmpty {
            object["requires_control"] = .array(itemsRequiringControl.map { .string($0.uuidString) })
        }
        return .object(object)
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

/// Produces inventory snapshots: every loaded session, every history-indexed session, and every
/// live link and durable intent.
@MainActor
protocol AgentSessionInventorySource: AnyObject {
    func snapshot() async -> DomainAgentSessionInventorySnapshot
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
        ) = { await AgentSessionLinkRuntimeBridge.shared.oversightInventory() }
    ) {
        self.scanner = scanner
        self.windows = windows
        self.links = links
    }

    func snapshot() async -> DomainAgentSessionInventorySnapshot {
        var records: [DomainAgentSessionInventoryRecord] = []
        var isComplete = false
        var historyByID: [UUID: (AgentSessionMetadataRecord, String)] = [:]
        if let scan = try? await scanner.scanWorkspaces(matching: nil) {
            isComplete = !scan.isTruncated && !scan.workspaces.contains(where: \.indexReadFailed)
            for workspace in scan.workspaces {
                for record in workspace.records {
                    historyByID[record.id] = (record, workspace.workspaceName)
                    records.append(Self.historyRecord(record, workspace: workspace))
                }
            }
        }
        records.append(contentsOf: loadedRecords(historyByID: historyByID))
        let (live, persisted) = await links()
        let edges = DomainAgentSessionInventoryEdge.merge(
            live: live.map { ($0.observerSessionID, $0.targetSessionID, $0.linkID, $0.generation) },
            persisted: persisted.map { ($0.observerSessionID, $0.targetSessionID) }
        )
        return DomainAgentSessionInventorySnapshot(records: records, edges: edges, isComplete: isComplete)
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
            runState: .classify(rawValue: record.lastRunStateRaw),
            parentSessionID: record.parentSessionID,
            createdByOverseerSessionID: record.createdByOverseerSessionID,
            createdAt: record.firstActivityAt,
            lastActivityAt: record.activityDate,
            worktreeCount: record.worktreeBindingSummaries.count
        )
    }

    private func loadedRecords(
        historyByID: [UUID: (AgentSessionMetadataRecord, String)]
    ) -> [DomainAgentSessionInventoryRecord] {
        var result: [DomainAgentSessionInventoryRecord] = []
        for window in windows() where !window.isClosing {
            guard let workspace = window.workspaceManager.activeWorkspace else { continue }
            let viewModel = window.agentModeViewModel
            var rows: [(UUID, ComposeTabState, Bool)] = []
            let tabsByID = Dictionary(uniqueKeysWithValues: workspace.composeTabs.map { ($0.id, $0) })
            for row in viewModel.sidebarSessions(for: workspace.composeTabs) {
                if let sessionID = row.sessionID, let tab = tabsByID[row.tabID] { rows.append((sessionID, tab, false)) }
            }
            for stashed in workspace.stashedTabs {
                let sessionID = stashed.tab.activeAgentSessionID
                    ?? viewModel.sessionIndex.values.first { $0.tabID == stashed.tab.id }?.id
                if let sessionID { rows.append((sessionID, stashed.tab, true)) }
            }
            for (sessionID, tab, isArchived) in rows {
                let entry = viewModel.sessionIndex[sessionID]
                let history = historyByID[sessionID]?.0
                let liveState: DomainAgentSessionInventoryRunState? = isArchived ? nil : {
                    guard let session = try? viewModel.authoritativeLiveSession(for: sessionID) else { return nil }
                    return .classify(rawValue: session.runState.rawValue)
                }()
                let lastActivity = entry.map {
                    AgentSessionRestoreSupport.sidebarActivityDate(lastUserMessageAt: $0.lastUserMessageAt, savedAt: $0.savedAt)
                } ?? history?.activityDate ?? tab.lastModified
                result.append(DomainAgentSessionInventoryRecord(
                    sessionID: sessionID,
                    name: tab.name,
                    workspaceID: workspace.id,
                    workspaceName: workspace.name,
                    isLoaded: true,
                    isArchived: isArchived,
                    isPinned: tab.isPinned,
                    pinnedOrder: tab.pinnedOrder,
                    sidebarGroup: tab.sidebarGroup,
                    sidebarGroupOrder: tab.sidebarGroupOrder,
                    runState: liveState ?? .classify(rawValue: entry?.lastRunStateRaw ?? history?.lastRunStateRaw),
                    parentSessionID: entry?.parentSessionID ?? history?.parentSessionID,
                    createdByOverseerSessionID: entry?.createdByOverseerSessionID ?? history?.createdByOverseerSessionID,
                    createdAt: history?.firstActivityAt,
                    lastActivityAt: lastActivity,
                    worktreeCount: entry?.worktreeBindingSummaries.count ?? history?.worktreeBindingSummaries.count ?? 0
                ))
            }
        }
        return result
    }
}

// MARK: - Inventory rendering

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
            "archived": .bool(record.isArchived),
            "pinned": .bool(record.isPinned),
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
        if let workspaceID = record.workspaceID { object["workspace_id"] = .string(workspaceID.uuidString) }
        if let workspaceName = record.workspaceName { object["workspace_name"] = .string(workspaceName) }
        if let order = record.pinnedOrder { object["pinned_order"] = .int(order) }
        if let group = record.sidebarGroup { object["group"] = .string(group) }
        if let order = record.sidebarGroupOrder { object["group_order"] = .int(order) }
        if let parent = record.parentSessionID { object["parent_session_id"] = .string(parent.uuidString) }
        if let creator = record.createdByOverseerSessionID {
            object["created_by_overseer_session_id"] = .string(creator.uuidString)
        }
        if let createdAt = record.createdAt { object["created_at"] = .string(AgentSessionAdminRendering.iso(createdAt)) }
        let orphanReasons = snapshot.orphanReasons(for: record.sessionID)
        object["orphaned"] = .bool(!orphanReasons.isEmpty)
        if !orphanReasons.isEmpty {
            object["orphan_reasons"] = .array(orphanReasons.map { .string($0.rawValue) })
        }
        return .object(object)
    }

    static func edge(_ edge: DomainAgentSessionInventoryEdge, snapshot: DomainAgentSessionInventorySnapshot) -> Value {
        var object: [String: Value] = [
            "observer_session_id": .string(edge.observerSessionID.uuidString),
            "target_session_id": .string(edge.targetSessionID.uuidString),
            "live": .bool(edge.isLive),
            "persisted": .bool(edge.isPersisted)
        ]
        if let name = snapshot.records[edge.observerSessionID]?.name { object["observer_name"] = .string(name) }
        if let name = snapshot.records[edge.targetSessionID]?.name { object["target_name"] = .string(name) }
        if snapshot.isComplete {
            let missing = [edge.observerSessionID, edge.targetSessionID].filter { snapshot.records[$0] == nil }
            if !missing.isEmpty {
                object["missing_session_ids"] = .array(missing.map { .string($0.uuidString) })
            }
        }
        if snapshot.records[edge.observerSessionID]?.isArchived == true { object["observer_archived"] = .bool(true) }
        return .object(object)
    }

    /// Free-text query over name, workspace, group, and session ID, with the shared matcher.
    static func matchesQuery(_ query: String?, record: DomainAgentSessionInventoryRecord) -> Bool {
        guard let query else { return true }
        let parsed = AgentSessionSearchQuery.parse(query)
        guard !parsed.isEmpty else { return true }
        let fields = AgentSessionSearchFields(
            title: record.name,
            secondary: [record.workspaceName, record.sidebarGroup],
            identifier: [record.sessionID.uuidString]
        )
        return AgentSessionSearchMatcher.matches(query: parsed, fields: fields)
    }
}
