import Foundation

// Overseers tab layout. Only this tab nests by oversight; All, Pinned and Active keep the ordinary
// sidebar. Each overseer is a top-level row with the sessions it oversees one level beneath it.
// Nesting never goes deeper: an overseer that is itself overseen gets its own group and also
// appears as a plain child under its overseer, and a session with several overseers appears under
// each of them. Sessions whose overseers are not in this sidebar trail in "Overseen elsewhere".
//
// SEARCH-HELPER: overseers tab, overseer groups, overseen sessions, oversight nesting.

/// One directed oversight relationship between two sessions.
struct AgentSidebarOverseerRelation: Hashable {
    let overseerSessionID: UUID
    let overseenSessionID: UUID
}

/// Identity of one rendered occurrence of a session. A session normally renders once
/// (`.canonical`); the Overseers tab can render it under several overseers, so each occurrence
/// needs its own identity while selection and mutations stay per session.
enum AgentSidebarActiveOccurrenceID: Hashable {
    case canonical(UUID)
    case overseerRoot(UUID)
    case overseen(overseerTabID: UUID, tabID: UUID)
    case elsewhere(UUID)
}

struct AgentSidebarOverseerPresentation {
    /// Every rendered occurrence, duplicates included, with section headers on first rows.
    let renderedRows: [AgentSidebarRenderedActiveRow]
    /// Visible sessions in first-occurrence order: selection, shortcuts and navigation.
    let orderedUniqueSessions: [AgentModeViewModel.SidebarSession]
}

@MainActor
enum AgentSidebarOverseerSectionBuilder {
    static let overseersTitle = "Overseers"
    static let elsewhereTitle = "Overseen elsewhere"

    /// - Parameters:
    ///   - rows: canonical rows (one per session) in sidebar order.
    ///   - matchesSearch: nil when search is inactive; otherwise whether a row directly matches.
    static func build(
        rows: [AgentModeViewModel.SidebarSession],
        relations: Set<AgentSidebarOverseerRelation>,
        matchesSearch: ((AgentModeViewModel.SidebarSession) -> Bool)?,
        collapsedKeys: Set<AgentSidebarThreadKey>,
        currentTabID: UUID?,
        attentionTabIDs: Set<UUID>
    ) -> AgentSidebarOverseerPresentation {
        var rowBySessionID: [UUID: AgentModeViewModel.SidebarSession] = [:]
        var position: [UUID: Int] = [:]
        for (index, row) in rows.enumerated() {
            guard let sessionID = row.sessionID, rowBySessionID[sessionID] == nil else { continue }
            rowBySessionID[sessionID] = row
            position[sessionID] = index
        }

        var overseen: [UUID: Set<UUID>] = [:]
        var overseers: [UUID: Set<UUID>] = [:]
        for relation in relations where relation.overseerSessionID != relation.overseenSessionID {
            overseen[relation.overseerSessionID, default: []].insert(relation.overseenSessionID)
            overseers[relation.overseenSessionID, default: []].insert(relation.overseerSessionID)
        }

        func rank(_ row: AgentModeViewModel.SidebarSession) -> Int {
            row.sessionID.flatMap { position[$0] } ?? .max
        }
        /// Pinned first, then newest activity, then sidebar order.
        func newestFirst(_ lhs: AgentModeViewModel.SidebarSession, _ rhs: AgentModeViewModel.SidebarSession) -> Bool {
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            let lhsDate = lhs.lastUserMessageAt ?? lhs.activityDate
            let rhsDate = rhs.lastUserMessageAt ?? rhs.activityDate
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return rank(lhs) < rank(rhs)
        }

        // Roots: visible sessions overseeing anyone (even sessions outside this sidebar), pinned
        // first, otherwise in their own sidebar order so a busy child never moves its overseer.
        let rootRows = rows.filter { row in
            guard let sessionID = row.sessionID, rowBySessionID[sessionID]?.id == row.id else { return false }
            return overseen[sessionID]?.isEmpty == false
        }
        let orderedRoots = rootRows.filter(\.isPinned) + rootRows.filter { !$0.isPinned }
        let rootSessionIDs = Set(orderedRoots.compactMap(\.sessionID))

        var rendered: [AgentSidebarRenderedActiveRow] = []
        var pendingHeader: String? = overseersTitle
        func append(_ session: AgentModeViewModel.SidebarSession, id: AgentSidebarActiveOccurrenceID) {
            let header = pendingHeader
            pendingHeader = nil
            rendered.append(AgentSidebarRenderedActiveRow(
                session: session,
                showsHeader: header != nil,
                isFirstHeader: header != nil && rendered.isEmpty,
                headerTitle: header ?? "",
                occurrenceID: id
            ))
        }

        for root in orderedRoots {
            guard let rootSessionID = root.sessionID else { continue }
            let allChildren = (overseen[rootSessionID] ?? [])
                .compactMap { rowBySessionID[$0] }
                .filter { $0.sessionID != rootSessionID }
                .sorted(by: newestFirst)
            let children: [AgentModeViewModel.SidebarSession]
            if let matchesSearch {
                if matchesSearch(root) {
                    children = allChildren
                } else {
                    children = allChildren.filter(matchesSearch)
                    guard !children.isEmpty else { continue }
                }
            } else {
                children = allChildren
            }
            let key = AgentSidebarThreadKey.overseerGroup(root.tabID)
            let containsCurrent = currentTabID.map { current in children.contains { $0.tabID == current } } ?? false
            let isCollapsed = !children.isEmpty && matchesSearch == nil
                && collapsedKeys.contains(key) && !containsCurrent
            append(presentationCopy(
                root,
                depth: 0,
                threadKey: key,
                hasThreadChildren: !children.isEmpty,
                isThreadCollapsed: isCollapsed,
                hiddenCount: isCollapsed ? children.count : 0,
                hiddenAttentionCount: isCollapsed ? children.count(where: { attentionTabIDs.contains($0.tabID) }) : 0
            ), id: .overseerRoot(root.tabID))
            guard !isCollapsed else { continue }
            for child in children {
                append(
                    presentationCopy(child, depth: 1, threadKey: nil, hasThreadChildren: false, isThreadCollapsed: false, hiddenCount: 0, hiddenAttentionCount: 0),
                    id: .overseen(overseerTabID: root.tabID, tabID: child.tabID)
                )
            }
        }

        // Overseen sessions with no overseer in this sidebar (other workspace, archived, closed).
        let elsewhere = rows.filter { row in
            guard let sessionID = row.sessionID, rowBySessionID[sessionID]?.id == row.id,
                  !rootSessionIDs.contains(sessionID),
                  let observerIDs = overseers[sessionID], !observerIDs.isEmpty,
                  !observerIDs.contains(where: { rowBySessionID[$0] != nil })
            else { return false }
            return matchesSearch?(row) ?? true
        }.sorted(by: newestFirst)
        pendingHeader = elsewhereTitle
        for row in elsewhere {
            append(
                presentationCopy(row, depth: 0, threadKey: nil, hasThreadChildren: false, isThreadCollapsed: false, hiddenCount: 0, hiddenAttentionCount: 0),
                id: .elsewhere(row.tabID)
            )
        }

        var seen = Set<UUID>()
        let unique = rendered.map(\.session).filter { seen.insert($0.tabID).inserted }
        return AgentSidebarOverseerPresentation(renderedRows: rendered, orderedUniqueSessions: unique)
    }

    /// The row as displayed in this tab. Session data, delegation metadata and search sources are
    /// unchanged; only depth and disclosure state are presentation-specific.
    private static func presentationCopy(
        _ row: AgentModeViewModel.SidebarSession,
        depth: Int,
        threadKey: AgentSidebarThreadKey?,
        hasThreadChildren: Bool,
        isThreadCollapsed: Bool,
        hiddenCount: Int,
        hiddenAttentionCount: Int
    ) -> AgentModeViewModel.SidebarSession {
        AgentModeViewModel.SidebarSession(
            id: row.id,
            tabID: row.tabID,
            title: row.title,
            lastUserMessageAt: row.lastUserMessageAt,
            activityDate: row.activityDate,
            isPinned: row.isPinned,
            sessionID: row.sessionID,
            canStash: row.canStash,
            parentSessionID: row.parentSessionID,
            createdByOverseerSessionID: row.createdByOverseerSessionID,
            depth: depth,
            isMCPControlled: row.isMCPControlled,
            worktree: row.worktree,
            worktreeMergeAttention: row.worktreeMergeAttention,
            threadKey: threadKey,
            hasThreadChildren: hasThreadChildren,
            isThreadCollapsed: isThreadCollapsed,
            hiddenThreadDescendantCount: hiddenCount,
            hiddenThreadDescendantAttentionCount: hiddenAttentionCount,
            threadActivityDate: row.lastUserMessageAt ?? row.activityDate,
            restorationDateBucket: row.restorationDateBucket,
            searchFieldSource: row.searchFieldSource
        )
    }
}
