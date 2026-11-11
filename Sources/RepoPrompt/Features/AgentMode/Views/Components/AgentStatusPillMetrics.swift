import SwiftUI

@MainActor
func agentSelectionCheckmark(fontPreset: FontScalePreset) -> some View {
    Image(systemName: "checkmark")
        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
        .foregroundStyle(Color.accentColor)
}

extension View {
    func agentApprovalSurface(strokeOpacity: Double) -> some View {
        padding(12)
            .background(Color.orange.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.orange.opacity(strokeOpacity), lineWidth: 1)
            )
    }

    func agentOversightPreviewSurface() -> some View {
        padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    func agentPillSurface(cornerRadius: CGFloat, strokeColor: Color, lineWidth: CGFloat) -> some View {
        background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(strokeColor, lineWidth: lineWidth)
            )
    }
}

// MARK: - Shared Pill Metrics

/// All composer pills (Workflow, Interview, Auto Edit, Oracle, Context, the
/// auto-edit guidance bubble) need to scale together so the row reads as a
/// coherent unit at every font preset. Centralising the metrics here means
/// individual pills only declare colors / labels — the geometry stays in sync.
enum AgentPillMetrics {
    static let baseHeight: CGFloat = 28

    static func height() -> CGFloat {
        ButtonScale.metric(baseHeight)
    }

    static func horizontalPadding() -> CGFloat {
        ButtonScale.metric(10)
    }

    static func cornerRadius() -> CGFloat {
        ButtonScale.pillCornerRadius(16)
    }
}
