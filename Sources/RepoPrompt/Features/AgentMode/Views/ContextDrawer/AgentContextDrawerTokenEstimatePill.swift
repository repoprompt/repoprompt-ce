import SwiftUI

struct AgentContextDrawerTokenEstimatePill: View {
    @ObservedObject var tokenCounter: TokenCountingViewModel
    @ObservedObject var runtimeVM: AgentRuntimeSidebarViewModel
    let fontPreset: FontScalePreset
    let tokenBlankingSelection: StoredSelection?

    private func isWaitingForExpectedSelection(_ snapshot: TokenCountingViewModel.PublishedTokenSnapshot) -> Bool {
        guard tokenBlankingSelection != nil else { return false }
        return !snapshot.isComplete || snapshot.isStale || snapshot.refreshPending
    }

    private var contextWindowTokens: Int {
        runtimeVM.snapshot.effectiveContextWindowTokens
    }

    var body: some View {
        let snapshot = tokenCounter.latestPublishedTokenSnapshot(for: tokenBlankingSelection)
        let contextWindowTokenBudget = contextWindowTokens
        let isWaiting = isWaitingForExpectedSelection(snapshot)

        Group {
            if isWaiting {
                loadingCapsule
            } else {
                let usedTokens = snapshot.breakdown.total
                let usedPercent = contextUsedPercent(usedTokens: usedTokens, contextWindowTokens: contextWindowTokenBudget)

                HStack(spacing: 8) {
                    AgentContextIndicator(
                        contextWindowTokens: contextWindowTokenBudget,
                        usedTokens: usedTokens,
                        style: .compact
                    )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(
                            "\(AgentContextIndicator.formatTokens(usedTokens)) / "
                                + "\(AgentContextIndicator.formatTokens(contextWindowTokenBudget))"
                        )
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                        HStack(spacing: 4) {
                            Text("\(formattedPercent(usedPercent))% of budget")
                            if snapshot.refreshPending {
                                Text("· Updating token estimate…")
                            }
                        }
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.10))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
        .hoverTooltip(
            isWaiting
                ? "Updating token estimate for the current selection."
                : tokenWarningHelp(
                    snapshot,
                    contextWindowTokens: contextWindowTokenBudget,
                    usedPercent: contextUsedPercent(
                        usedTokens: snapshot.breakdown.total,
                        contextWindowTokens: contextWindowTokenBudget
                    )
                )
        )
    }

    private var loadingCapsule: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Token estimate")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text("Updating for current selection…")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func contextUsedPercent(usedTokens: Int, contextWindowTokens: Int) -> Double {
        guard contextWindowTokens > 0 else { return 0 }
        return min(max((Double(usedTokens) / Double(contextWindowTokens)) * 100, 0), 100)
    }

    private func formattedPercent(_ usedPercent: Double) -> String {
        "\(Int(usedPercent.rounded()))"
    }

    private func tokenWarningHelp(
        _ snapshot: TokenCountingViewModel.PublishedTokenSnapshot,
        contextWindowTokens: Int,
        usedPercent: Double
    ) -> String {
        var lines: [String] = []
        lines.append("Prompt context used: \(formattedPercent(usedPercent))%")
        lines.append(
            "\(AgentContextIndicator.formatTokens(snapshot.breakdown.total)) / "
                + "\(AgentContextIndicator.formatTokens(contextWindowTokens)) tokens"
        )

        if !snapshot.isComplete {
            lines.append("Token estimate is not complete yet.")
        } else if snapshot.refreshPending {
            lines.append("Token estimate is refreshing; the displayed count may be stale.")
        }

        let breakdown = tokenCounter.tokenBreakdownDescription
        if !breakdown.isEmpty {
            lines.append(breakdown)
        }
        return lines.joined(separator: "\n")
    }
}
