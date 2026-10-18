import Foundation
import RepoPromptProviderQuota
import RepoPromptSettingsCore
import SwiftUI

/// Dual gauge: the outer ring is the account-wide (weekly) window and matches the printed
/// figure; the inner pie, separated by a dark gap, is the short rolling window (e.g.
/// Claude's 5-hour limit). The pie is a calm tint with headroom and warms amber -> red
/// as it nears its limit. Single-window providers render the ring alone.
struct UsageDualGauge: View {
    let accountFraction: Double
    let sessionFraction: Double?

    private static let calm = Color(red: 0.55, green: 0.62, blue: 0.95)
    private static let warm = Color(red: 1.0, green: 0.72, blue: 0.30)
    private static let hot = Color(red: 0.96, green: 0.42, blue: 0.40)

    private func pieColor(_ fraction: Double) -> Color {
        if fraction >= 0.9 { return Self.hot }
        if fraction >= 0.7 { return Self.warm }
        return Self.calm.opacity(0.85)
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let lineWidth: CGFloat = sessionFraction == nil ? 2 : 1.75
            let gap: CGFloat = 1.5
            let pieInset = lineWidth + gap
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
                    .padding(lineWidth / 2)
                Circle()
                    .trim(from: 0, to: accountFraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(lineWidth / 2)
                if let sessionFraction {
                    Circle()
                        .fill(Color.secondary.opacity(0.22))
                        .padding(pieInset)
                    PieSlice(fraction: sessionFraction)
                        .fill(pieColor(sessionFraction))
                        .padding(pieInset)
                }
            }
            .frame(width: side, height: side)
        }
        .animation(.easeOut(duration: 0.35), value: accountFraction)
        .animation(.easeOut(duration: 0.35), value: sessionFraction)
        .accessibilityHidden(true)
    }
}

private struct PieSlice: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return Path() }
        if clamped >= 1 { return Path(ellipseIn: rect) }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addArc(
            center: center,
            radius: min(rect.width, rect.height) / 2,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * clamped),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

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
                    UsageDualGauge(
                        accountFraction: fraction,
                        sessionFraction: presentation.sessionFraction
                    )
                    .frame(width: presentation.sessionFraction == nil ? 11 : 14, height: presentation.sessionFraction == nil ? 11 : 14)
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
