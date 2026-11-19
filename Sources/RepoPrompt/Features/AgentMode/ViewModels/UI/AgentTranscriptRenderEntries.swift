import Foundation

/// The scroll container receives individually realizable leaves, never a history-sized child view.
struct AgentTranscriptRenderEntries {
    struct Entry: Identifiable {
        enum ID: Hashable {
            case block(String)
            case row(block: String, item: UUID)
        }

        let id: ID
        let block: AgentTranscriptRenderBlock
        let item: AgentChatItem?
        let isFirstInBlock: Bool
        let groupedChildren: [GroupEntry]
        let groupedRowCount: Int
    }

    struct GroupEntry: Identifiable {
        enum ID: Hashable {
            case header(String)
            case row(section: String, block: String, item: UUID)
        }

        enum Content {
            case header(AgentTranscriptGroupedSection)
            case row(AgentTranscriptRenderBlock, AgentChatItem)
        }

        let id: ID
        let content: Content
        let spacingBefore: CGFloat
    }

    let entries: [Entry]

    init(blocks: [AgentTranscriptRenderBlock]) {
        var entries: [Entry] = []
        for block in blocks {
            switch block.kind {
            case .activityCluster, .groupedHistory, .collapsedHistoryRange:
                let (children, rowCount) = Self.groupEntries(for: block)
                entries.append(.init(
                    id: .block(block.id),
                    block: block,
                    item: nil,
                    isFirstInBlock: true,
                    groupedChildren: children,
                    groupedRowCount: rowCount
                ))
            default:
                for (offset, item) in block.rows.enumerated() {
                    entries.append(.init(
                        id: .row(block: block.id, item: item.id),
                        block: block,
                        item: item,
                        isFirstInBlock: offset == 0,
                        groupedChildren: [],
                        groupedRowCount: 0
                    ))
                }
            }
        }
        self.entries = entries
    }

    private static func groupEntries(for block: AgentTranscriptRenderBlock) -> ([GroupEntry], Int) {
        var entries: [GroupEntry] = []
        var rowCount = 0
        for section in block.groupedHistory?.sections ?? [] {
            let start = entries.count
            if section.title != nil || section.clusterSummary != nil {
                entries.append(.init(id: .header(section.id), content: .header(section), spacingBefore: start == 0 ? 2 : 12))
            }
            for child in section.childBlocks {
                for (offset, item) in child.rows.enumerated() {
                    let spacing: CGFloat = if entries.count == start {
                        start == 0 ? 2 : 12
                    } else {
                        offset == 0 ? 6 : 4
                    }
                    entries.append(.init(
                        id: .row(section: section.id, block: child.id, item: item.id),
                        content: .row(child, item),
                        spacingBefore: spacing
                    ))
                    rowCount += 1
                }
            }
        }
        return (entries, rowCount)
    }
}
