import SwiftUI

struct AgentStagedSlashCommandPill: View {
    let staged: AgentStagedSlashCommandProps

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var accentColor: Color {
        staged.action == .setObjective ? .green : .secondary
    }

    private var labelText: String {
        staged.appliesSelectedWorkflowContext ? "\(staged.displayText) + Workflow" : staged.displayText
    }

    private var tooltipText: String {
        switch staged.action {
        case .setObjective where staged.appliesSelectedWorkflowContext:
            let workflowName = staged.selectedWorkflowName ?? "selected"
            return "Next send will set a Codex goal and include \(workflowName) workflow context."
        case .setObjective:
            return "Next send will set a Codex goal."
        case .show:
            return "Next send will run /goal as a Codex control command. Selected workflows are not applied to goal control actions."
        case .pause:
            return "Next send will run /goal pause as a Codex control command. Selected workflows are not applied to goal control actions."
        case .resume:
            return "Next send will run /goal resume as a Codex control command. Selected workflows are not applied to goal control actions."
        case .clear:
            return "Next send will run /goal clear as a Codex control command. Selected workflows are not applied to goal control actions."
        }
    }

    var body: some View {
        let cornerRadius = AgentPillMetrics.cornerRadius()
        HStack(spacing: 5) {
            Image(systemName: "target")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
            Text(labelText)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
        }
        .foregroundStyle(accentColor)
        .padding(.horizontal, AgentPillMetrics.horizontalPadding())
        .frame(height: AgentPillMetrics.height())
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(accentColor.opacity(staged.action == .setObjective ? 0.35 : 0.18), lineWidth: staged.action == .setObjective ? 0.8 : 0.5)
        )
        .hoverTooltip(tooltipText, .top)
    }
}

struct AgentAutoEditGuidanceBubble: View {
    let agentModeVM: AgentModeViewModel
    let runState: AgentSessionRunState
    let guidance: AgentModeViewModel.AutoEditPermissionGuidance

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var accentColor: Color {
        switch guidance.provider {
        case .codex:
            .green
        case .claude:
            .orange
        }
    }

    private var messageText: String {
        if runState.isActive {
            return guidance.message + " Applies next turn."
        }
        return guidance.message
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(messageText)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Button(guidance.actionTitle) {
                agentModeVM.applyAutoEditPermissionGuidanceAction()
            }
            .buttonStyle(.plain)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
            .foregroundStyle(accentColor)
        }
        .padding(.horizontal, AgentPillMetrics.horizontalPadding())
        .frame(height: AgentPillMetrics.height())
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AgentPillMetrics.cornerRadius(), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AgentPillMetrics.cornerRadius(), style: .continuous)
                .stroke(accentColor.opacity(0.18), lineWidth: 0.8)
        )
    }
}
