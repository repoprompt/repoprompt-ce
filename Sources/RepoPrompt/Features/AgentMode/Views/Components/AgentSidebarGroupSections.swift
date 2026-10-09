import RepoPromptDomainRuntime
import RepoPromptInstrumentation
import SwiftUI

// Collapsible sidebar group sections (design §4.1). Sessions whose tab carries a `sidebarGroup` render
// first, one section per group in group order; everything else keeps its date sections. Rows keep
// their own ids, so grouping never changes row identity under the pointer.
//
// SEARCH-HELPER: sidebar groups, group sections, collapsible group header.

extension AgentSidebarDateSectionBuilder {
    /// Rendered active rows with group sections. With no grouped rows this is exactly
    /// `renderedActiveRows(for: activeSections(for:))`, so ungrouped workspaces are unchanged.
    ///
    /// A collapsed group keeps only its first row as a carrier for the header (`hidesRow`).
    static func renderedActiveRowsWithGroups(
        for rows: [AgentModeViewModel.SidebarSession],
        collapsedGroups: Set<String>,
        now: Date = Date(),
        calendar: Calendar = .current,
        perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()
    ) -> [AgentSidebarRenderedActiveRow] {
        let threads = activeGroups(for: rows, now: now, calendar: calendar)
        func groupName(_ thread: AgentSidebarActiveDateGroup) -> String? {
            thread.rows.first?.searchFieldSource.sidebarGroup
        }
        guard threads.contains(where: { groupName($0) != nil }) else {
            return renderedActiveRows(for: activeSections(for: rows, now: now, calendar: calendar, perfRecorder: perfRecorder))
        }

        var rowsByGroup: [String: [AgentModeViewModel.SidebarSession]] = [:]
        var orderEntries: [(group: String, order: Int?)] = []
        var ungrouped: [AgentModeViewModel.SidebarSession] = []
        for thread in threads {
            guard let name = groupName(thread) else {
                ungrouped.append(contentsOf: thread.rows)
                continue
            }
            rowsByGroup[name, default: []].append(contentsOf: thread.rows)
            orderEntries.append((name, thread.rows.first?.searchFieldSource.sidebarGroupOrder))
        }

        var rendered: [AgentSidebarRenderedActiveRow] = []
        for (index, name) in DomainAgentSessionSidebarGroup.orderedGroups(orderEntries).enumerated() {
            let groupRows = rowsByGroup[name] ?? []
            let collapsed = collapsedGroups.contains(name)
            for (rowIndex, session) in groupRows.enumerated() {
                if collapsed, rowIndex > 0 { break }
                rendered.append(AgentSidebarRenderedActiveRow(
                    session: session,
                    showsHeader: rowIndex == 0,
                    isFirstHeader: rowIndex == 0 && index == 0,
                    headerTitle: name,
                    groupName: rowIndex == 0 ? name : nil,
                    isGroupCollapsed: collapsed,
                    groupRowCount: groupRows.count,
                    hidesRow: collapsed
                ))
            }
        }
        let dated = renderedActiveRows(for: activeSections(for: ungrouped, now: now, calendar: calendar, perfRecorder: perfRecorder))
        rendered.append(contentsOf: dated.map { row in
            AgentSidebarRenderedActiveRow(
                session: row.session,
                showsHeader: row.showsHeader,
                isFirstHeader: false,
                headerTitle: row.headerTitle
            )
        })
        return rendered
    }
}

/// Header for one sidebar group: title, row count, and a collapse chevron.
struct AgentSidebarGroupSectionHeader: View {
    let title: String
    let rowCount: Int
    let isCollapsed: Bool
    var isFirst: Bool = false
    let onToggle: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(rowCount)")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .regular))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, fontPreset.scaledClamped(10, max: 14))
        .padding(.top, isFirst ? fontPreset.scaledClamped(2, max: 3) : fontPreset.scaledClamped(14, max: 20))
        .padding(.bottom, fontPreset.scaledClamped(4, max: 6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(title), \(rowCount) sessions, \(isCollapsed ? "collapsed" : "expanded")")
    }
}
