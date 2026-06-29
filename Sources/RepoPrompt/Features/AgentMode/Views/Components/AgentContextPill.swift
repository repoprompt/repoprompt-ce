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

    private var fileCount: Int {
        selectionSummary.totalExplicitFileCount
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

    private var compactFileSummaryText: String {
        selectionSummary.compactText
    }

    private var detailedFileSummaryText: String {
        selectionSummary.headlineText
    }

    private var contextUsageTooltip: String {
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
        .hoverTooltip(contextUsageTooltip, .top)
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
        let popoverWidth = fontPreset.scaledClamped(360, max: 480)
        VStack(alignment: .leading, spacing: 10) {
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
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Selected")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundStyle(.tertiary)
                    Text(detailedFileSummaryText)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .semibold))
                }
            }

            Divider()

            AgentExportCard(
                promptManager: promptManager,
                tokenCounter: promptManager.tokenCountingViewModel,
                selectionCoordinator: selectionCoordinator,
                fileCount: fileCount,
                selectionTokens: selectionTokens,
                currentTabID: currentTabID,
                activeAgentSessionID: activeAgentSessionID,
                worktreeBindingsProvider: worktreeBindingsProvider
            )
        }
        .padding(12)
        .frame(width: popoverWidth)
    }
}
