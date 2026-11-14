import Foundation

/// Metadata-only projection. Saved state never becomes live/active merely by appearing here.
enum CommandCenterSidebarProjection {
    struct Item: Identifiable {
        let row: CommandCenterRecentSessions.Row
        let projectLabel: String
        let depth: Int
        let bucket: AgentSidebarDateSectionBucket
        let showsHeader: Bool
        let isFirstHeader: Bool
        var id: CommandCenterSessionRow.ID {
            row.id
        }
    }

    static func rows(
        snapshot: CommandCenterSnapshot,
        tab: AgentSidebarTab,
        search: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Item] {
        let all = CommandCenterRecentSessions.rows(in: snapshot, matching: "")
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let names = Dictionary(grouping: snapshot.workspaces, by: \.name)
        let overseers = Set(all.filter(\.session.oversightRole.isOverseer).map(\.id))
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = all.filter { row in
            let session = row.session
            let matchesTab: Bool = switch tab {
            case .all: true
            case .pinned: session.isPinned
            case .active: session.attention == .working || session.attention == .needsYou || session.attention == .failed
            case .overseers: overseers.contains(row.id) || session.oversightRole.isOverseen
                || session.createdByOverseerSessionID.map { overseers.contains(.init(workspaceID: session.workspaceID, sessionID: $0)) } == true
            }
            return matchesTab && (query.isEmpty || [session.name, row.workspaceName, row.rootSummary].contains {
                $0.localizedCaseInsensitiveContains(query)
            })
        }
        let visibleIDs = Set(matching.map(\.id))
        var children: [CommandCenterSessionRow.ID: [CommandCenterRecentSessions.Row]] = [:]
        var roots: [CommandCenterRecentSessions.Row] = []
        for row in matching {
            if let parent = row.session.parentSessionID {
                let parentID = CommandCenterSessionRow.ID(workspaceID: row.session.workspaceID, sessionID: parent)
                if parentID != row.id, visibleIDs.contains(parentID), byID[parentID] != nil {
                    children[parentID, default: []].append(row)
                    continue
                }
            }
            roots.append(row)
        }
        var output: [Item] = []
        var visited: Set<CommandCenterSessionRow.ID> = []
        var lastBucket: AgentSidebarDateSectionBucket?
        func append(_ row: CommandCenterRecentSessions.Row, depth: Int, bucket: AgentSidebarDateSectionBucket) {
            guard visited.insert(row.id).inserted else { return }
            let label = row.workspaceName + ((names[row.workspaceName]?.count ?? 0) > 1 ? " · \(row.session.workspaceID.uuidString.prefix(8))" : "")
            output.append(Item(
                row: row,
                projectLabel: label,
                depth: depth,
                bucket: bucket,
                showsHeader: lastBucket != bucket,
                isFirstHeader: output.isEmpty
            ))
            lastBucket = bucket
            for child in children[row.id] ?? [] {
                append(child, depth: min(8, depth + 1), bucket: bucket)
            }
        }
        for row in roots + matching {
            append(row, depth: 0, bucket: .bucket(for: row.session.activityDate, relativeTo: now, calendar: calendar))
        }
        return output
    }
}
