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

/// Shared round control for the composer status row.
struct AgentIconTogglePill: View {
    let systemImage: String
    let isOn: Bool
    /// Drives only the outline; fill and icon color always follow `isOn`.
    let isOutlineHighlighted: Bool
    let isBusy: Bool
    let onToggle: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    init(
        systemImage: String,
        isOn: Bool,
        isOutlineHighlighted: Bool? = nil,
        isBusy: Bool,
        onToggle: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.isOn = isOn
        self.isOutlineHighlighted = isOutlineHighlighted ?? isOn
        self.isBusy = isBusy
        self.onToggle = onToggle
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
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(fontScale.preset.swiftUIFont(sizeAtNormal: 14, weight: .semibold))
                        .foregroundStyle(isOn ? Color.accentColor : .secondary)
                }
            }
            .frame(width: size, height: size)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isOutlineHighlighted ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: isOutlineHighlighted ? 0.8 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Proposes at most `maxWidth` to its single child and adopts the child's size,
/// so short labels hug their text while long labels truncate at the cap.
/// A flexible `.frame(maxWidth:)` would instead expand to the cap and center the text.
struct AgentPillLabelWidthCap: Layout {
    let maxWidth: CGFloat

    private func cappedProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(cappedProposal(proposal))
        return CGSize(width: min(size.width, maxWidth), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

/// Shared geometry keeps the routing controls balanced with and without feedback.
/// Reserving the same slot for symbols and spinners prevents busy-state label jumps.
private struct AgentRoutingPillLabel: View {
    let systemImage: String
    let isBusy: Bool
    let title: String?
    var directionImage: String?
    let fontPreset: FontScalePreset

    var body: some View {
        let height = AgentPillMetrics.height()
        let iconSlot = ButtonScale.metric(16)
        let inset = (height - iconSlot) / 2
        HStack(alignment: .center, spacing: ButtonScale.metric(4)) {
            ZStack {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: systemImage)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                        .imageScale(.large)
                }
            }
            .frame(width: iconSlot, height: iconSlot)

            if let title {
                HStack(spacing: ButtonScale.metric(2)) {
                    AgentPillLabelWidthCap(maxWidth: ButtonScale.metric(140)) {
                        Text(title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let directionImage {
                        Image(systemName: directionImage)
                            .imageScale(.small)
                    }
                }
            }
        }
        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
        .padding(.leading, inset)
        .padding(.trailing, title == nil ? inset : inset + ButtonScale.metric(3))
        .frame(width: title == nil ? height : nil, height: height)
    }
}

// MARK: - Model Router Pill

struct AgentModelRouterPill: View {
    let props: AgentModelRouterPillProps
    let onToggle: () -> Void
    let onOpenSettings: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private var routedModelDisplayName: String? {
        props.isOn ? props.routedModelDisplayName : nil
    }

    private var tooltip: String {
        guard props.isOn || props.isAvailable else { return routingTooltip }
        return routingTooltip + (props.usageBalancing ? " Usage balancing is on." : "")
    }

    private var routingTooltip: String {
        if !props.isOn, !props.isAvailable {
            return "Model Router is unavailable. Click to configure."
        }
        if let reason = props.disabledReason { return reason }
        if props.isRouting { return "Router is choosing a target for this new session" }
        if let routedModelDisplayName {
            return "Router on. Last routed model: \(routedModelDisplayName). New primary sessions and subagents are routed automatically."
        }
        return props.isOn
            ? "Router on: New primary sessions and subagents are routed automatically"
            : "Router off: New sessions use their current or requested target"
    }

    var body: some View {
        let cornerRadius = AgentPillMetrics.cornerRadius()
        Button {
            if !props.isAvailable, !props.isOn {
                onOpenSettings()
            } else {
                onToggle()
            }
        } label: {
            AgentRoutingPillLabel(
                systemImage: "arrow.triangle.branch",
                isBusy: props.isRouting,
                title: routedModelDisplayName,
                fontPreset: fontScale.preset
            )
            .foregroundStyle(props.isOn ? Color.accentColor : .secondary)
            .background(props.isOn ? Color.accentColor.opacity(0.12) : Color.clear)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke((props.isOn || props.usageBalancing) ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: (props.isOn || props.usageBalancing) ? 0.8 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(props.isRouting)
        .hoverTooltip(tooltip, .top)
        .accessibilityLabel("Model Router")
        .accessibilityValue((routedModelDisplayName.map { "On, last routed model \($0)" } ?? (props.isOn ? "On" : "Off")) + (props.usageBalancing ? ", usage balancing on" : ""))
    }
}

// MARK: - Auto Effort Pill

struct AgentAutoEffortPill: View {
    let props: AgentAutoEffortPillProps
    let onToggle: () -> Void
    let onOpenSettings: () -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var showingEnableConfirmation = false

    private var feedback: AutoEffortTurnFeedback? {
        props.isOn ? props.feedback : nil
    }

    private var tooltip: String {
        if !props.isOn, !props.isAvailable {
            return "Auto effort is unavailable. Click to configure."
        }
        if !props.isOn { return "Auto effort off. Click to let the selected decision service choose effort before eligible user turns." }
        if props.isJudging { return "The selected decision service is choosing effort for this user turn." }
        let availability = props.isAvailable ? "" : " The selected service is unavailable; turns use manual effort."
        guard let feedback else { return "Auto effort on. No service choice has been submitted for this model yet. Effort does not change between tool calls inside an active turn.\(availability)" }
        let change = switch feedback.direction {
        case .up: "up from the previous service choice or initial selected effort"
        case .down: "down from the previous service choice or initial selected effort"
        case .unchanged: "unchanged from the previous service choice"
        case .unknown: "no comparable previous effort"
        }
        return "Auto effort on. Last service choice: \(feedback.effortRaw), \(change). The arrow compares service choices, not intervening manual turns.\(availability)"
    }

    var body: some View {
        let cornerRadius = AgentPillMetrics.cornerRadius()
        Button {
            if !props.isAvailable, !props.isOn {
                onOpenSettings()
            } else if props.isOn {
                onToggle()
            } else {
                showingEnableConfirmation = true
            }
        } label: {
            AgentRoutingPillLabel(
                systemImage: "gauge.open.with.lines.needle.33percent",
                isBusy: props.isJudging && props.isOn,
                title: feedback?.effortRaw.uppercased(),
                directionImage: feedback.flatMap {
                    switch $0.direction {
                    case .up: "arrow.up"
                    case .down: "arrow.down"
                    default: nil
                    }
                },
                fontPreset: fontScale.preset
            )
            .foregroundStyle(props.isOn ? Color.accentColor : .secondary)
            .background(props.isOn ? Color.accentColor.opacity(0.12) : Color.clear)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(props.isOn ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: props.isOn ? 0.8 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .hoverTooltip(tooltip, .top)
        .accessibilityLabel("Auto effort")
        .accessibilityValue(tooltip)
        .confirmationDialog("Enable Auto Effort?", isPresented: $showingEnableConfirmation) {
            Button("Enable Auto Effort", action: onToggle)
            Button("Privacy details…", action: onOpenSettings)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("For eligible turns, your selected decision service receives a short, best-effort masked excerpt of your message, the model ID, available effort levels, and any built-in workflow category. Masking can miss sensitive information. Files, tool results, and earlier conversation aren’t sent.")
        }
    }
}
