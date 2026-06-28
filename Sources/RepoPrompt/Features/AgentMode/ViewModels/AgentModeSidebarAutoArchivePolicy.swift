import Foundation

struct AgentModeSidebarAutoArchivePolicy {
    struct Configuration: Equatable {
        var baseVisibleSessionLimit: Int
        var overflowVisibleSessionLimit: Int
        var inactivityInterval: TimeInterval
        var protectsPinnedSessions: Bool

        init(
            baseVisibleSessionLimit: Int = 25,
            overflowVisibleSessionLimit: Int = 50,
            inactivityInterval: TimeInterval = 3 * 24 * 60 * 60,
            protectsPinnedSessions: Bool = true
        ) {
            let baseLimit = max(1, baseVisibleSessionLimit)
            self.baseVisibleSessionLimit = baseLimit
            self.overflowVisibleSessionLimit = max(baseLimit, overflowVisibleSessionLimit)
            self.inactivityInterval = max(0, inactivityInterval)
            self.protectsPinnedSessions = protectsPinnedSessions
        }
    }

    struct Decision: Equatable {
        let tabIDsToArchive: Set<UUID>
        let normalInactiveTabIDs: Set<UUID>
        let overflowTabIDs: Set<UUID>
        let evaluatedSessionCount: Int

        static func empty(evaluatedSessionCount: Int) -> Decision {
            Decision(
                tabIDsToArchive: [],
                normalInactiveTabIDs: [],
                overflowTabIDs: [],
                evaluatedSessionCount: evaluatedSessionCount
            )
        }
    }

    private struct ThreadGroup {
        let root: GroupRoot
        var rows: [AgentModeViewModel.SidebarSession] = []

        var rowCount: Int {
            rows.count
        }

        var tabIDs: Set<UUID> {
            Set(rows.map(\.tabID))
        }

        var effectiveEngagementDate: Date {
            rows.map { $0.lastUserMessageAt ?? $0.activityDate }.max() ?? .distantPast
        }

        func isProtected(
            currentTabID: UUID?,
            protectedTabIDs: Set<UUID>,
            protectsPinnedSessions: Bool
        ) -> Bool {
            rows.contains { row in
                row.tabID == currentTabID
                    || protectedTabIDs.contains(row.tabID)
                    || row.isMCPControlled
                    || (protectsPinnedSessions && row.isPinned)
            }
        }
    }

    private enum GroupRoot: Hashable {
        case session(UUID)
        case tab(UUID)
    }

    var configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func decision(
        for sessions: [AgentModeViewModel.SidebarSession],
        currentTabID: UUID?,
        protectedTabIDs: Set<UUID>,
        now: Date
    ) -> Decision {
        guard sessions.count > configuration.baseVisibleSessionLimit else {
            return .empty(evaluatedSessionCount: sessions.count)
        }

        let groups = threadGroups(for: sessions)
        let cutoff = now.addingTimeInterval(-configuration.inactivityInterval)
        let protectedRoots = Set(groups.filter {
            $0.isProtected(
                currentTabID: currentTabID,
                protectedTabIDs: protectedTabIDs,
                protectsPinnedSessions: configuration.protectsPinnedSessions
            )
        }.map(\.root))

        let inactiveCandidates = groups
            .filter { group in
                !protectedRoots.contains(group.root) && group.effectiveEngagementDate < cutoff
            }
            .sorted { lhs, rhs in
                if lhs.effectiveEngagementDate != rhs.effectiveEngagementDate {
                    return lhs.effectiveEngagementDate < rhs.effectiveEngagementDate
                }
                return String(describing: lhs.root) < String(describing: rhs.root)
            }

        var remainingCount = sessions.count
        var normalInactiveTabIDs: Set<UUID> = []
        for group in inactiveCandidates where remainingCount > configuration.baseVisibleSessionLimit {
            let countAfterArchivingGroup = remainingCount - group.rowCount
            guard countAfterArchivingGroup >= configuration.baseVisibleSessionLimit else {
                continue
            }
            normalInactiveTabIDs.formUnion(group.tabIDs)
            remainingCount = countAfterArchivingGroup
        }

        let overflowTabIDs: Set<UUID> = []
        let tabIDsToArchive = normalInactiveTabIDs
        return Decision(
            tabIDsToArchive: tabIDsToArchive,
            normalInactiveTabIDs: normalInactiveTabIDs,
            overflowTabIDs: overflowTabIDs,
            evaluatedSessionCount: sessions.count
        )
    }

    private func threadGroups(for sessions: [AgentModeViewModel.SidebarSession]) -> [ThreadGroup] {
        let lineage = AgentSessionLineageIndex(
            nodes: sessions.compactMap { row in
                guard let sessionID = row.sessionID else { return nil }
                return .init(sessionID: sessionID, parentSessionID: row.parentSessionID)
            }
        )

        func root(for row: AgentModeViewModel.SidebarSession) -> GroupRoot {
            guard let sessionID = row.sessionID else { return .tab(row.tabID) }
            return .session(lineage.rootSessionID(for: sessionID) ?? sessionID)
        }

        var groupsByRoot: [GroupRoot: ThreadGroup] = [:]
        for row in sessions {
            let groupRoot = root(for: row)
            groupsByRoot[groupRoot, default: ThreadGroup(root: groupRoot)].rows.append(row)
        }
        return Array(groupsByRoot.values)
    }
}
