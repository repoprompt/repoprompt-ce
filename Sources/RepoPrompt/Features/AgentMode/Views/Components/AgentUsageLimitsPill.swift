import Foundation
import RepoPromptProviderQuota
import RepoPromptSettingsCore
import SwiftUI

// SEARCH-HELPER: Agent Mode usage limits pill, plan usage indicator, quota pill, observe-only
//
// One compact, passive plan-usage affordance in the Agent Mode status pill row.
//
// Performance contract:
//  - The pill row passes only a value (`ProviderQuotaSettingsTarget`); quota changes re-render
//    this pill alone, never `AgentStatusPillsRow`.
//  - It observes exactly one per-provider indicator store whose state is already rounded,
//    account-wide, and equality-gated. No timers, IO, or settings observation here.
//  - Sticky: once shown it stays. Hide reasons (see `ProviderQuotaIndicatorStore`): display
//    or source turned off, the agent has no usage target (decided by the row), or no value
//    was ever observed. Stale / reset-passed / updating / failed dim the last value in place;
//    a cleared snapshot shows a neutral "—".
//  - Right-click "Refresh usage" uses the same user-initiated path as Settings → Refresh.

struct AgentUsageLimitsPill: View {
    let target: ProviderQuotaSettingsTarget
    let windowID: Int

    var body: some View {
        let runtime = WindowStatesManager.shared.providerQuotaRuntime
        AgentUsageLimitsPillContent(
            target: target,
            windowID: windowID,
            indicator: target == .codex ? runtime.codexIndicator : runtime.claudeIndicator
        )
        // A provider switch is a different store and surface lease.
        .id(target)
    }
}

private struct AgentUsageLimitsPillContent: View {
    let target: ProviderQuotaSettingsTarget
    let windowID: Int
    @ObservedObject var indicator: ProviderQuotaIndicatorStore
    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var surfaceID = UUID()
    @State private var isPopoverPresented = false

    private var providerName: String {
        target == .codex ? "Codex" : "Claude"
    }

    var body: some View {
        // An HStack (rather than a bare conditional) keeps appear/disappear firing while hidden,
        // so the lease is released when the row goes away.
        HStack(spacing: 0) {
            if let state = indicator.state {
                pill(AgentUsageLimitsPillPresentation(state: state, providerName: providerName, now: Date()))
            }
        }
        .onAppear { indicator.activate(surfaceID: surfaceID) }
        .onDisappear { indicator.deactivate(surfaceID: surfaceID) }
    }

    private func pill(_ presentation: AgentUsageLimitsPillPresentation) -> some View {
        let cornerRadius = AgentPillMetrics.cornerRadius()
        let height = AgentPillMetrics.height()
        let tint: Color = presentation.isReached ? .orange : .secondary
        return Button { isPopoverPresented.toggle() } label: {
            HStack(spacing: 4) {
                if presentation.isReached {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(fontScale.preset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                        .foregroundStyle(Color.orange)
                } else if let fraction = presentation.ringFraction {
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 11, height: 11)
                }
                Text(presentation.label)
                    .font(fontScale.preset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .opacity(presentation.isDimmed ? 0.55 : 1)
            .padding(.horizontal, 7)
            .frame(height: height)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Refresh usage") { indicator.refresh() }
        }
        .hoverTooltip(presentation.tooltip, .top)
        .accessibilityLabel("\(providerName) plan usage")
        .accessibilityValue(presentation.tooltip)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            ProviderUsageQuotaSection(
                provider: target,
                style: .popover,
                openSettings: openUsageSettings
            )
            .padding(12)
            .frame(width: 280)
        }
    }

    private func openUsageSettings() {
        isPopoverPresented = false
        guard let windowState = WindowStatesManager.shared.allWindows.first(where: { $0.windowID == windowID })
            ?? WindowStatesManager.shared.latestWindowState
        else { return }
        SettingsWindowCoordinator.shared.open(windowState: windowState, selectedTab: .cliProviders)
    }
}
