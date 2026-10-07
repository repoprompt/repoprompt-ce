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
//    account-wide, fresh-only, and equality-gated. No timers, IO, or settings observation here.
//  - Absence is the unknown state: with no real figure the pill is not shown at all.

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
            if let state = indicator.state,
               let presentation = AgentUsageLimitsPillPresentation(
                   usedPercent: state.usedPercent,
                   isReached: state.isReached,
                   resetAt: state.resetAt,
                   providerName: providerName,
                   now: Date()
               )
            {
                pill(presentation)
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
