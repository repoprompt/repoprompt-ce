import SwiftUI

struct AgentRuntimeContextSection: View {
    let snapshot: AgentRuntimeSidebarViewModel.ContextSnapshot

    private var usageSubtitle: String {
        snapshot.usageSource.label
    }

    private var selectionTokensText: String {
        guard let tokens = snapshot.selectionTokens else { return "n/a" }
        return AgentContextIndicator.formatTokens(tokens)
    }

    private var selectionDeltaText: String? {
        guard let delta = snapshot.selectionDeltaTokens else { return nil }
        let prefix = delta > 0 ? "+" : ""
        return "\(prefix)\(AgentContextIndicator.formatTokens(delta))"
    }

    var body: some View {
        AgentRuntimeSectionCard(
            title: "Context",
            subtitle: usageSubtitle
        ) {
            AgentContextIndicator(
                contextWindowTokens: snapshot.effectiveContextWindowTokens,
                usedTokens: snapshot.usedTokens,
                sourceLabel: usageSubtitle,
                // Gate the standalone window fact so pre-usage sessions with an
                // unknown denominator show an em-dash placeholder, not the fabricated fallback.
                isContextWindowKnown: snapshot.displayContextWindowTokens != nil,
                style: .labeled
            )

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Selected files")
                    Spacer()
                    Text("\(snapshot.selectionFileCount ?? 0)")
                        .fontWeight(.semibold)
                }
                .font(.system(size: 11))

                HStack {
                    Text("Selection tokens")
                    Spacer()
                    Text(selectionTokensText)
                        .fontWeight(.semibold)
                }
                .font(.system(size: 11))

                if let selectionDeltaText {
                    HStack {
                        Text("Delta")
                        Spacer()
                        Text(selectionDeltaText)
                            .fontWeight(.semibold)
                            .foregroundStyle(selectionDeltaText.hasPrefix("+") ? .orange : .green)
                    }
                    .font(.system(size: 11))
                }

                if snapshot.observedReadFileCount > 0 {
                    Text("Observed read_file paths: \(snapshot.observedReadFileCount)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
