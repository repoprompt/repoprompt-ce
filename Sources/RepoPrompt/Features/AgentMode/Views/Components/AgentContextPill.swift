import SwiftUI

// MARK: - Context Pill

/// Always-visible pill showing context usage wheel + file/token info.
/// Expands upward into a popover with export controls.
struct AgentContextPill: View {
    @ObservedObject var promptManager: PromptViewModel
    let selectionCoordinator: WorkspaceSelectionCoordinator
    @ObservedObject var runtimeVM: AgentRuntimeSidebarViewModel
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let worktreeBindingsProvider: @MainActor (UUID, UUID?) -> [AgentSessionWorktreeBinding]

    @State private var showPopover = false
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
        AgentContextExportResolver.selectionSummary(for: currentExportSourceSelection)
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

        lines.append("Selected: \(detailedFileSummaryText)")
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
        let summary = selectionSummary
        let compactFileSummaryText = summary.compactText
        let detailedFileSummaryText = summary.headlineText

        Button {
            showPopover.toggle()
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
        .accessibilityHint("Opens context export controls and usage details")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            contextPopoverContent
        }
    }

    @ViewBuilder
    private var contextPopoverContent: some View {
        // Width grows with the font scale so the export card never feels
        // pinched at Large/Extra Large.
        let popoverWidth = fontPreset.scaledClamped(420, max: 520)
        let summary = selectionSummary
        let fileCount = summary.totalExplicitFileCount
        let visibleManagerRows = min(max(fileCount, 3), 7)
        let managerIdealHeight = min(360, Double(visibleManagerRows) * 40 + 54)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AgentContextIndicator(
                    contextWindowTokens: contextWindowTokens,
                    usedTokens: estimatedUsedTokens,
                    sourceLabel: runtimeVM.snapshot.usedTokens != nil
                        ? runtimeVM.snapshot.usageSource.label
                        : "Estimated",
                    style: .labeled
                )
                Spacer()
            }

            AgentSelectedFilesInlineManager(
                promptManager: promptManager,
                selectionCoordinator: selectionCoordinator,
                currentTabID: currentTabID,
                activeAgentSessionID: activeAgentSessionID,
                worktreeBindingsProvider: worktreeBindingsProvider,
                summary: summary
            )
            .frame(
                minHeight: 124,
                idealHeight: managerIdealHeight,
                maxHeight: 360
            )

            Divider()

            AgentExportCard(
                promptManager: promptManager,
                tokenCounter: promptManager.tokenCountingViewModel,
                selectionCoordinator: selectionCoordinator,
                fileCount: fileCount,
                selectionTokens: selectionTokens,
                showsFilesButton: false,
                currentTabID: currentTabID,
                activeAgentSessionID: activeAgentSessionID,
                worktreeBindingsProvider: worktreeBindingsProvider
            )
        }
        .padding(12)
        .frame(width: popoverWidth)
    }
}
