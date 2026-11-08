import SwiftUI

/// Visual compaction never changes the full name used by accessibility, history, or search.
struct AgentSessionTitleLabel: View {
    let title: String
    var metadata: AgentSessionTitleMetadata?

    var body: some View {
        HStack(spacing: 3) {
            if let state = metadata?.state, let prefix = AgentSessionTitleFormatter.prefix(state),
               let range = title.range(of: state.displayName)
            {
                if range.lowerBound != title.startIndex {
                    Text(String(title[..<range.lowerBound])).lineLimit(1).truncationMode(.tail)
                }
                ViewThatFits(in: .horizontal) {
                    Text(prefix).fixedSize()
                    let first = prefix.components(separatedBy: ", ").first ?? prefix
                    Text(first + (state.pullRequests.count > 1 ? " +\(state.pullRequests.count - 1)" : ""))
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Text("— " + state.baseTitle + String(title[range.upperBound...])).lineLimit(1).truncationMode(.tail)
            } else { Text(title).lineLimit(1).truncationMode(.tail) }
        }
        .hoverTooltip(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
