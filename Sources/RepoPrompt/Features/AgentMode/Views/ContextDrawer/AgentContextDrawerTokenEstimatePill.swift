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

    private var contextWindowTokens: Int? {
        runtimeVM.snapshot.effectiveContextWindowTokens
    }

    var body: some View {
        let snapshot = tokenCounter.latestPublishedTokenSnapshot(
            for: tokenBlankingSelection,
            scheduleRefreshIfNeeded: false
        )
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
                        Text(Self.tokenSummaryText(usedTokens: usedTokens, contextWindowTokens: contextWindowTokenBudget))
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        HStack(spacing: 4) {
                            Text(Self.budgetText(usedPercent: usedPercent))
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

    private func contextUsedPercent(usedTokens: Int, contextWindowTokens: Int?) -> Double? {
        guard let contextWindowTokens, contextWindowTokens > 0 else { return nil }
        return min(max((Double(usedTokens) / Double(contextWindowTokens)) * 100, 0), 100)
    }

    private static func formattedPercent(_ usedPercent: Double) -> String {
        "\(Int(usedPercent.rounded()))"
    }

    /// An unknown window shows the token count alone rather than a guessed denominator.
    static func tokenSummaryText(usedTokens: Int, contextWindowTokens: Int?) -> String {
        guard let contextWindowTokens, contextWindowTokens > 0 else {
            return "\(AgentContextIndicator.formatTokens(usedTokens)) tokens"
        }
        return "\(AgentContextIndicator.formatTokens(usedTokens)) / \(AgentContextIndicator.formatTokens(contextWindowTokens))"
    }

    static func budgetText(usedPercent: Double?) -> String {
        guard let usedPercent else { return "Context window unknown" }
        return "\(formattedPercent(usedPercent))% of budget"
    }

    private func tokenWarningHelp(
        _ snapshot: TokenCountingViewModel.PublishedTokenSnapshot,
        contextWindowTokens: Int?,
        usedPercent: Double?
    ) -> String {
        var lines: [String] = []
        if let usedPercent {
            lines.append("Prompt context used: \(Self.formattedPercent(usedPercent))%")
            lines.append(Self.tokenSummaryText(usedTokens: snapshot.breakdown.total, contextWindowTokens: contextWindowTokens) + " tokens")
        } else {
            lines.append("Prompt context: " + Self.tokenSummaryText(usedTokens: snapshot.breakdown.total, contextWindowTokens: nil))
            lines.append(AgentContextIndicator.unknownWindowText)
        }

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
