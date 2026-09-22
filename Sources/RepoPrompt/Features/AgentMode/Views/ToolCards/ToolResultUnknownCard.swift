import Foundation
import SwiftUI

struct UnknownToolResultCard: View {
    let item: AgentChatItem
    let title: String
    @State private var isExpanded = false

    private var status: ToolCardStatus {
        ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    private var subtitle: String? {
        if let subtitle = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON)?.inlineSubtitle {
            return subtitle
        }
        guard let obj = ToolJSON.rawObject(from: item.toolResultJSON) else { return nil }
        if let status = ToolRawJSON.string(obj, key: "status"), !status.isEmpty {
            return status
        }
        if let error = ToolRawJSON.string(obj, key: "error"), !error.isEmpty {
            return "error"
        }
        return nil
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: title,
            subtitle: subtitle,
            status: status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}
