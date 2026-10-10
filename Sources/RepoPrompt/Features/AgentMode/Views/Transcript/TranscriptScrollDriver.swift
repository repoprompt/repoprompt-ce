import SwiftUI

// MARK: - Scroll Driver Seam

/// Placement used when scrolling a transcript block into view.
enum TranscriptScrollBlockPlacement: Equatable {
    case top
    case center

    var unitPoint: UnitPoint {
        switch self {
        case .top:
            .top
        case .center:
            .center
        }
    }
}

/// Everything the transcript scroll container must be able to do on behalf of the
/// scroll engine. All programmatic transcript scrolling funnels through a driver, so
/// alternative containers (for example a virtualized `NSTableView`) can replace the
/// SwiftUI `ScrollViewProxy` implementation without touching engine policy.
@MainActor
protocol TranscriptScrollDriver {
    /// Scrolls so the live bottom of the transcript is visible.
    func scrollToBottom(animated: Bool)

    /// Scrolls so the block with `blockID` is placed at `placement` in the viewport.
    /// No-ops when the container does not currently host that block.
    func scrollToBlock(id blockID: String, placement: TranscriptScrollBlockPlacement, animated: Bool)
}

/// Reports a scroll container sends back to the scroll engine. The SwiftUI container
/// derives these from `onScrollGeometryChange` / `onScrollPhaseChange`; other
/// containers produce the same events from their native scroll notifications.
enum TranscriptScrollDriverEvent: Equatable {
    /// Scroll geometry changed (offset, content size or viewport size).
    case metricsChanged(AgentTranscriptScrollMetrics)
    /// The user/system scroll phase changed. `metrics` is the geometry at the
    /// moment of the transition.
    case phaseChanged(AgentTranscriptUserScrollPhase, metrics: AgentTranscriptScrollMetrics)
}

// MARK: - SwiftUI ScrollViewProxy Driver

/// `TranscriptScrollDriver` backed by a SwiftUI `ScrollViewProxy`. Scroll targets are
/// the `.id(_:)` values applied to transcript block rows plus the bottom sentinel.
struct SwiftUITranscriptScrollDriver: TranscriptScrollDriver {
    /// `.id(_:)` of the zero-height view placed after the last transcript row.
    static let bottomTargetID = "bottomTarget"

    let proxy: ScrollViewProxy

    func scrollToBottom(animated: Bool) {
        perform(animated: animated) {
            proxy.scrollTo(Self.bottomTargetID, anchor: .bottom)
        }
    }

    func scrollToBlock(id blockID: String, placement: TranscriptScrollBlockPlacement, animated: Bool) {
        perform(animated: animated) {
            proxy.scrollTo(blockID, anchor: placement.unitPoint)
        }
    }

    private func perform(animated: Bool, _ scroll: () -> Void) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                scroll()
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scroll()
            }
        }
    }
}
