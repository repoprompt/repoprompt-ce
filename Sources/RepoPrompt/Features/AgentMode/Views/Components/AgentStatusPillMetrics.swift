import SwiftUI

extension View {
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
