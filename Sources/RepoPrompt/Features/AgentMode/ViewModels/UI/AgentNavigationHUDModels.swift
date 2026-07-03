import Foundation

/// Internal mode for the Agent Session Switcher HUD.
enum AgentNavigationHUDMode: String, Equatable, CaseIterable, Identifiable {
    case currentWindow
    case allAgents

    var id: String {
        rawValue
    }

    var title: String {
        "Agent Session Switcher"
    }

    var scopeTitle: String {
        switch self {
        case .currentWindow:
            "This Window"
        case .allAgents:
            "All Agents"
        }
    }

    var emptyTitle: String {
        switch self {
        case .currentWindow:
            "No Agent sessions in this window"
        case .allAgents:
            "No active or recent Agent sessions"
        }
    }
}

enum AgentNavigationHUDNotificationUserInfoKey {
    static let windowID = "windowID"
    static let mode = "mode"
}

struct AgentNavigationHUDItem: Identifiable, Equatable {
    var id: String {
        "\(windowID):\(tabID.uuidString)"
    }

    let windowID: Int
    let workspaceID: UUID
    let tabID: UUID
    let sessionID: UUID?
    let title: String
    let workspaceTitle: String
    let windowTitle: String
    let parentSessionID: UUID?
    let depth: Int
    let subagentCount: Int
    let subagentAttentionCount: Int
    let isActiveTab: Bool
    let runState: AgentSessionRunState?
    let attentionState: AgentSessionRunState?
    let attentionMarkedAt: Date?
    let activityDate: Date
    let worktree: AgentWorktreeIndicator?
    let worktreeLabel: String?
    let mergeAttention: AgentWorktreeMergeAttention?
    let mergeLabel: String?
    let isMCPControlled: Bool

    var isSubagent: Bool {
        depth > 0
    }

    var displayDepth: Int {
        min(depth, AgentNavigationHUDSnapshotBuilder.maxVisibleDepth)
    }

    var hasHiddenSubagentAttention: Bool {
        subagentAttentionCount > 0
    }

    var subagentChipLabel: String? {
        guard subagentCount > 0 else { return nil }
        return subagentCount == 1 ? "1 sub-agent" : "\(subagentCount) sub-agents"
    }

    var latestActivityAt: Date {
        [attentionMarkedAt, activityDate].compactMap(\.self).max() ?? activityDate
    }

    var effectiveStatusState: AgentSessionRunState? {
        if runState == .running { return .running }
        return attentionState ?? runState
    }

    var isUnseenAttention: Bool {
        guard let attentionState else { return false }
        if runState == .running { return false }
        return Self.isAttentionEligible(attentionState)
    }

    var statusLabel: String? {
        if let attentionState {
            return Self.label(for: attentionState)
        }
        guard let runState, runState != .idle else { return nil }
        return Self.label(for: runState)
    }

    var metadataSearchText: [String] {
        [
            title,
            workspaceTitle,
            windowTitle,
            statusLabel,
            isSubagent ? "sub-agent" : nil,
            subagentCount > 0 ? "subagents" : nil,
            worktreeLabel,
            mergeLabel,
            isMCPControlled ? "MCP" : nil
        ].compactMap(\.self)
    }

    var accessibilityStatusText: String {
        var parts: [String] = []
        if let statusLabel { parts.append(statusLabel) }
        if isMCPControlled { parts.append("MCP controlled") }
        if let worktreeLabel { parts.append("worktree \(worktreeLabel)") }
        if let mergeLabel { parts.append("merge ready to \(mergeLabel)") }
        return parts.joined(separator: ", ")
    }

    private static func isAttentionEligible(_ state: AgentSessionRunState) -> Bool {
        switch state {
        case .completed, .failed,
             .waitingForUser, .waitingForQuestion, .waitingForApproval:
            true
        case .idle, .running, .cancelled:
            false
        }
    }

    private static func label(for state: AgentSessionRunState) -> String {
        switch state {
        case .idle: "Idle"
        case .running: "Running"
        case .waitingForUser: "Needs input"
        case .waitingForQuestion: "Question"
        case .waitingForApproval: "Approval"
        case .completed: "Done"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }
}

struct AgentNavigationHUDSnapshot: Equatable {
    let mode: AgentNavigationHUDMode
    let title: String
    let items: [AgentNavigationHUDItem]
}

enum AgentNavigationHUDSnapshotBuilder {
    static let allAgentsCap = 50
    static let maxVisibleDepth = 2

    @MainActor
    static func currentWindowSnapshot(
        windowState: WindowState,
        mode: AgentNavigationHUDMode = .currentWindow
    ) -> AgentNavigationHUDSnapshot {
        AgentNavigationHUDSnapshot(
            mode: mode,
            title: mode.title,
            items: currentWindowItems(windowState: windowState)
        )
    }

    @MainActor
    static func allAgentsSnapshot(now: Date = Date()) -> AgentNavigationHUDSnapshot {
        allAgentsSnapshot(windows: WindowStatesManager.shared.allWindows, now: now)
    }

    @MainActor
    static func allAgentsSnapshot(
        windows: [WindowState],
        now: Date = Date()
    ) -> AgentNavigationHUDSnapshot {
        let rows = windows
            .filter { !$0.isClosing }
            .flatMap { currentWindowItems(windowState: $0) }
        return AgentNavigationHUDSnapshot(
            mode: .allAgents,
            title: AgentNavigationHUDMode.allAgents.title,
            items: allAgentsSorted(rows, now: now)
        )
    }

    static func currentWindowItems(
        rows: [AgentModeViewModel.SidebarSession],
        currentTabID: UUID?,
        windowID: Int,
        workspaceID: UUID,
        workspaceTitle: String,
        windowTitle: String,
        runStateByTabID: [UUID: AgentSessionRunState] = [:],
        attentionRunStateByTabID: [UUID: AgentSessionRunState] = [:],
        attentionMarkedAtByTabID: [UUID: Date] = [:]
    ) -> [AgentNavigationHUDItem] {
        let rootDescendantCounts = descendantCountsByRootTabID(
            rows: rows,
            attentionRunStateByTabID: attentionRunStateByTabID
        )
        return rows.map { row in
            let descendantCounts = rootDescendantCounts[row.tabID] ?? (count: 0, attentionCount: 0)
            return AgentNavigationHUDItem(
                windowID: windowID,
                workspaceID: workspaceID,
                tabID: row.tabID,
                sessionID: row.sessionID,
                title: row.title,
                workspaceTitle: workspaceTitle,
                windowTitle: windowTitle,
                parentSessionID: row.parentSessionID,
                depth: row.depth,
                subagentCount: row.depth == 0 ? descendantCounts.count : 0,
                subagentAttentionCount: row.depth == 0 ? descendantCounts.attentionCount : 0,
                isActiveTab: row.tabID == currentTabID,
                runState: runStateByTabID[row.tabID],
                attentionState: attentionRunStateByTabID[row.tabID],
                attentionMarkedAt: attentionMarkedAtByTabID[row.tabID],
                activityDate: row.threadActivityDate ?? row.lastUserMessageAt ?? row.activityDate,
                worktree: row.worktree,
                worktreeLabel: row.worktree?.label,
                mergeAttention: row.worktreeMergeAttention,
                mergeLabel: row.worktreeMergeAttention?.targetLabel,
                isMCPControlled: row.isMCPControlled
            )
        }
    }

    private static func descendantCountsByRootTabID(
        rows: [AgentModeViewModel.SidebarSession],
        attentionRunStateByTabID: [UUID: AgentSessionRunState]
    ) -> [UUID: (count: Int, attentionCount: Int)] {
        var counts: [UUID: (count: Int, attentionCount: Int)] = [:]
        var currentRootTabID: UUID?
        for row in rows {
            if row.depth == 0 {
                currentRootTabID = row.tabID
                continue
            }
            guard let currentRootTabID else { continue }
            var current = counts[currentRootTabID] ?? (count: 0, attentionCount: 0)
            current.count += 1
            if attentionRunStateByTabID[row.tabID] != nil {
                current.attentionCount += 1
            }
            counts[currentRootTabID] = current
        }
        return counts
    }

    static func allAgentsSorted(_ items: [AgentNavigationHUDItem], now: Date = Date()) -> [AgentNavigationHUDItem] {
        items
            .filter { isIncludedInAllAgentsHUD($0, now: now) }
            .sorted(by: allAgentsSort)
    }

    static func allAgentsSortedAndCapped(_ items: [AgentNavigationHUDItem], now: Date = Date()) -> [AgentNavigationHUDItem] {
        Array(allAgentsSorted(items, now: now).prefix(allAgentsCap))
    }

    private static func isIncludedInAllAgentsHUD(_ item: AgentNavigationHUDItem, now: Date) -> Bool {
        if item.runState?.isActive == true { return true }
        if item.attentionState != nil { return true }
        return item.latestActivityAt >= now.addingTimeInterval(-24 * 60 * 60)
    }

    private static func allAgentsSort(_ lhs: AgentNavigationHUDItem, _ rhs: AgentNavigationHUDItem) -> Bool {
        if (lhs.attentionState != nil) != (rhs.attentionState != nil) {
            return lhs.attentionState != nil
        }
        if (lhs.runState?.isActive == true) != (rhs.runState?.isActive == true) {
            return lhs.runState?.isActive == true
        }
        if lhs.latestActivityAt != rhs.latestActivityAt {
            return lhs.latestActivityAt > rhs.latestActivityAt
        }
        if lhs.workspaceTitle != rhs.workspaceTitle {
            return lhs.workspaceTitle.localizedCaseInsensitiveCompare(rhs.workspaceTitle) == .orderedAscending
        }
        if lhs.windowTitle != rhs.windowTitle {
            return lhs.windowTitle.localizedCaseInsensitiveCompare(rhs.windowTitle) == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    @MainActor
    private static func currentWindowItems(windowState: WindowState) -> [AgentNavigationHUDItem] {
        guard let workspace = windowState.workspaceManager.activeWorkspace,
              !workspace.isSystemWorkspace
        else {
            return []
        }
        let agentModeVM = windowState.agentModeViewModel
        let tabs = windowState.promptManager.currentComposeTabs
        let currentTabID = windowState.promptManager.activeComposeTabID
        let rows = agentModeVM.sidebarSessions(for: tabs)
        let attentionSnapshot = agentModeVM.ui.sessionSidebar.snapshot
        return currentWindowItems(
            rows: rows,
            currentTabID: currentTabID,
            windowID: windowState.windowID,
            workspaceID: workspace.id,
            workspaceTitle: workspace.name,
            windowTitle: windowState.displayedWindowTitle,
            runStateByTabID: agentModeVM.agentNavigationHUDRunStateByTabID(for: rows.map(\.tabID)),
            attentionRunStateByTabID: attentionSnapshot.attentionRunStateByTabID,
            attentionMarkedAtByTabID: attentionSnapshot.attentionMarkedAtByTabID
        )
    }
}

@MainActor
extension AgentModeViewModel {
    func agentNavigationHUDRunStateByTabID(for tabIDs: [UUID]) -> [UUID: AgentSessionRunState] {
        Dictionary(uniqueKeysWithValues: tabIDs.compactMap { tabID in
            sessions[tabID].map { (tabID, $0.runState) }
        })
    }
}
