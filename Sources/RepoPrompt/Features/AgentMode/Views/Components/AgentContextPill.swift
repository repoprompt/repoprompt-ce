import SwiftUI

// MARK: - Context Pill

/// Always-visible pill showing context usage wheel + file/token info.
struct AgentContextPill: View {
    @ObservedObject var promptManager: PromptViewModel
    let openContextDrawerFiles: () -> Void
    let selectionCoordinator: WorkspaceSelectionCoordinator
    @ObservedObject var runtimeVM: AgentRuntimeSidebarViewModel
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let worktreeBindingsProvider: @MainActor (UUID, UUID?) -> [AgentSessionWorktreeBinding]

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var estimatedUsedTokens: Int? {
        runtimeVM.snapshot.usedTokens ?? runtimeVM.snapshot.estimatedTranscriptTokens
    }

    private var contextWindowTokens: Int {
        runtimeVM.snapshot.effectiveContextWindowTokens
    }

    private var selectionSummary: AgentContextSelectionSummary {
        if let summary = runtimeVM.snapshot.selectionSummary {
            return summary
        }
        if let count = runtimeVM.snapshot.selectionFileCount {
            return .filesOnly(count)
        }
        return AgentContextExportResolver.selectionSummary(for: currentExportSourceSelection)
    }

    private var selectionDisplayText: AgentContextSelectionDisplayText {
        AgentContextFileCodemapCountSummary.selectionDisplayText(from: selectionSummary)
    }

    private var currentExportSourceSelection: StoredSelection {
        let requestedTabID = currentTabID ?? promptManager.activeComposeTabID
        let selectionSnapshot = requestedTabID.flatMap {
            selectionCoordinator.selectionSnapshot(for: $0, flushPendingUIIfActive: false)
        }
        return AgentContextExportSourceBuilder.makeSource(
            AgentContextExportSourceBuildRequest(
                requestedTabID: requestedTabID,
                activeComposeTabID: promptManager.activeComposeTabID,
                activePromptText: promptManager.promptText,
                selectionSnapshot: selectionSnapshot,
                composeTabs: promptManager.currentComposeTabs,
                explicitActiveAgentSessionID: activeAgentSessionID,
                worktreeBindingsProvider: worktreeBindingsProvider
            )
        ).selection
    }

    private var selectionTokens: Int? {
        runtimeVM.snapshot.selectionTokens
    }

    private func contextUsageTooltip(detailedFileSummaryText: String) -> String {
        var lines: [String] = []

        if let usedTokens = estimatedUsedTokens,
           contextWindowTokens > 0
        {
            let usedPercent = min(max((Double(usedTokens) / Double(contextWindowTokens)) * 100, 0), 100)
            lines.append("Context used: \(Int(usedPercent.rounded()))%")
            lines.append("\(AgentContextIndicator.formatTokens(usedTokens)) / \(AgentContextIndicator.formatTokens(contextWindowTokens)) tokens")
        } else if let usedTokens = estimatedUsedTokens {
            lines.append("Used tokens: \(AgentContextIndicator.formatTokens(usedTokens))")
        } else {
            lines.append("Context usage unavailable")
        }

        lines.append("Selected context: \(detailedFileSummaryText)")
        if let selectionTokens {
            lines.append("Selection: \(AgentContextIndicator.formatTokens(selectionTokens)) tokens")
        }

        return lines.joined(separator: "\n")
    }

    var body: some View {
        #if DEBUG
            let _ = AgentModePerfDiagnostics.increment("ui.body.statusPills.context")
        #endif
        let cornerRadius = AgentPillMetrics.cornerRadius()
        let displayText = selectionDisplayText
        let compactFileSummaryText = displayText.compact
        let detailedFileSummaryText = displayText.detailed

        Button {
            openContextDrawerFiles()
        } label: {
            HStack(spacing: 6) {
                Text(compactFileSummaryText)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                AgentContextIndicator(
                    contextWindowTokens: contextWindowTokens,
                    usedTokens: estimatedUsedTokens,
                    style: .compact
                )
            }
            .padding(.horizontal, AgentPillMetrics.horizontalPadding())
            .frame(height: AgentPillMetrics.height())
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .hoverTooltip(contextUsageTooltip(detailedFileSummaryText: detailedFileSummaryText), .top)
        .accessibilityLabel("Agent context: \(detailedFileSummaryText)")
        .accessibilityHint("Opens Compose selections")
    }
}
