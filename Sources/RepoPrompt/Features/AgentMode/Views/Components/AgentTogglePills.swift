import SwiftUI

// MARK: - Auto Edit Pill

struct AgentAutoEditPill: View {
    let isOn: Bool
    let onToggle: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var tooltipText: String {
        if isOn {
            return "Auto Edit is on: apply_edits writes files immediately after the agent proposes them."
        }
        return "Auto Edit is off: apply_edits requires approval. If sandbox permissions still allow file edits, those changes bypass RepoPrompt review."
    }

    var body: some View {
        let cornerRadius = AgentPillMetrics.cornerRadius()
        let dotSize = fontPreset.scaledMetric(CGFloat(7))
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isOn ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: dotSize, height: dotSize)
                Text("Auto Edit")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    .foregroundStyle(isOn ? Color.green : .secondary)
            }
            .padding(.horizontal, AgentPillMetrics.horizontalPadding())
            .frame(height: AgentPillMetrics.height())
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isOn ? Color.green.opacity(0.35) : Color.secondary.opacity(0.15), lineWidth: isOn ? 0.8 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .hoverTooltip(tooltipText, .top)
    }
}

// MARK: - Interview Pill

struct AgentInterviewPill: View {
    let isOn: Bool
    let onToggle: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var tooltipPlainText: String {
        if isOn {
            return "Interview on: Asks questions before starting"
        }
        return "Interview off: Work begins immediately"
    }

    private var tooltipText: AttributedString {
        var text = AttributedString(tooltipPlainText)
        if let range = text.range(of: isOn ? "on" : "off") {
            text[range].foregroundColor = isOn ? .green : .red
        }
        return text
    }

    private var accessibilityTraits: AccessibilityTraits {
        isOn ? [.isSelected] : []
    }

    var body: some View {
        let cornerRadius = AgentPillMetrics.cornerRadius()
        let size = AgentPillMetrics.height()
        Button(action: onToggle) {
            ZStack {
                if isOn {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                }

                Image(systemName: isOn ? "questionmark.bubble.fill" : "questionmark.bubble")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
            }
            .frame(width: size, height: size)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isOn ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: isOn ? 0.8 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .hoverTooltip(tooltipText, plainText: tooltipPlainText, .top)
        .accessibilityLabel("Interview")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(accessibilityTraits)
    }
}

// MARK: - Model Router Pill

struct AgentModelRouterPill: View {
    let props: AgentModelRouterPillProps
    let onToggle: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private var tooltip: String {
        if let reason = props.disabledReason, !props.isAvailable { return reason }
        if props.isRouting { return "Router is choosing a target for this new session" }
        return props.isOn
            ? "Router on: New primary sessions and subagents are routed automatically"
            : "Router off: New sessions use their current or requested target"
    }

    var body: some View {
        let cornerRadius = AgentPillMetrics.cornerRadius()
        let size = AgentPillMetrics.height()
        Button(action: onToggle) {
            ZStack {
                if props.isOn {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                }
                if props.isRouting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.branch")
                        .font(fontScale.preset.swiftUIFont(sizeAtNormal: 14, weight: .semibold))
                        .foregroundStyle(props.isOn ? Color.accentColor : .secondary)
                }
            }
            .frame(width: size, height: size)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(props.isOn ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: props.isOn ? 0.8 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(!props.isAvailable || props.isRouting)
        .hoverTooltip(tooltip, .top)
        .accessibilityLabel("Model Router")
        .accessibilityValue(props.isOn ? "On" : "Off")
    }
}
