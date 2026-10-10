import CoreGraphics
import Foundation

// MARK: - Layout Input

/// One transcript row (render block) in content coordinates: `minY` grows downward from
/// the top of the document, matching a flipped `NSClipView` document.
struct TranscriptScrollAnchorRowFrame: Codable, Equatable {
    let blockID: String
    /// Turn that owns the block; used to pick a fallback anchor when the block disappears.
    let turnID: UUID?
    let minY: CGFloat
    let height: CGFloat

    var maxY: CGFloat {
        minY + height
    }
}

/// Snapshot of the transcript layout the anchor model reasons about.
struct TranscriptScrollAnchorLayout: Equatable {
    /// Rows ordered top to bottom.
    var rows: [TranscriptScrollAnchorRowFrame]
    var contentHeight: CGFloat
    var viewportHeight: CGFloat

    /// Largest valid clip origin (viewport top in content coordinates).
    var maxClipOriginY: CGFloat {
        max(0, contentHeight - viewportHeight)
    }

    func row(for blockID: String) -> TranscriptScrollAnchorRowFrame? {
        rows.first { $0.blockID == blockID }
    }

    func clampedClipOriginY(_ y: CGFloat) -> CGFloat {
        min(max(0, y), maxClipOriginY)
    }

    func distanceToBottom(clipOriginY: CGFloat) -> CGFloat {
        max(0, maxClipOriginY - clipOriginY)
    }

    /// Row containing the viewport top, or the first row starting below it.
    func topVisibleRow(clipOriginY: CGFloat) -> TranscriptScrollAnchorRowFrame? {
        rows.first { $0.maxY > clipOriginY } ?? rows.last
    }
}

// MARK: - Output

/// What the container must do to honour the anchor after an event.
enum TranscriptScrollAnchorAdjustment: Equatable {
    /// Leave the clip origin where it is.
    case none
    /// Move the clip origin (viewport top, content coordinates) to this value.
    case setClipOrigin(CGFloat)

    /// Signed clip-origin change relative to `currentClipOriginY`.
    func delta(from currentClipOriginY: CGFloat) -> CGFloat {
        switch self {
        case .none:
            0
        case let .setClipOrigin(target):
            target - currentClipOriginY
        }
    }
}

/// Explicit navigation requests.
enum TranscriptScrollAnchorJump: Equatable {
    case top
    case block(String)
    case bottom
}

// MARK: - Anchor Model

/// Pure scroll-anchor state machine for the transcript.
///
/// - `.following`: the viewport is pinned to the live bottom; every layout change pins again.
/// - `.reading`: the user is reading history; the viewport keeps `anchorBlockID`'s top at
///   `offsetFromViewportTop` (row top minus viewport top, negative when the row starts above the
///   viewport) through height changes, appends, streaming growth, width changes and fold/unfold.
///
/// The model never scrolls on its own: callers feed it events with old/new layouts and apply the
/// returned `TranscriptScrollAnchorAdjustment`.
///
/// Not wired into the UI yet: the SwiftUI transcript container cannot report per-row frames
/// cheaply. The NSTableView-backed transcript container (follow-up PR) drives it through
/// `TranscriptScrollDriver`. `Codable` so the reading position can later be persisted per session.
struct TranscriptScrollAnchorModel: Codable, Equatable {
    enum Mode: Codable, Equatable {
        case following
        case reading(anchorBlockID: String, offsetFromViewportTop: CGFloat)
    }

    /// Distance from the bottom within which the viewport counts as following.
    static let defaultFollowThreshold: CGFloat = 24

    private(set) var mode: Mode
    let followThreshold: CGFloat

    init(mode: Mode = .following, followThreshold: CGFloat = TranscriptScrollAnchorModel.defaultFollowThreshold) {
        self.mode = mode
        self.followThreshold = followThreshold
    }

    var isFollowing: Bool {
        mode == .following
    }

    // MARK: User scroll

    /// The user moved the viewport. Within `followThreshold` of the bottom the model follows;
    /// otherwise it reads from the top-visible row. User scrolls never produce an adjustment.
    mutating func userDidScroll(clipOriginY: CGFloat, layout: TranscriptScrollAnchorLayout) {
        if layout.distanceToBottom(clipOriginY: clipOriginY) <= followThreshold {
            mode = .following
            return
        }
        guard let anchorRow = layout.topVisibleRow(clipOriginY: clipOriginY) else {
            mode = .following
            return
        }
        mode = .reading(anchorBlockID: anchorRow.blockID, offsetFromViewportTop: anchorRow.minY - clipOriginY)
    }

    // MARK: Layout changes

    /// Row heights changed, rows were inserted/removed above or below, content was appended,
    /// a streaming row grew, or rows were folded/unfolded. Following pins to the new bottom;
    /// reading keeps the anchor row's top at the same viewport offset.
    mutating func layoutDidChange(
        from oldLayout: TranscriptScrollAnchorLayout,
        to newLayout: TranscriptScrollAnchorLayout,
        clipOriginY: CGFloat
    ) -> TranscriptScrollAnchorAdjustment {
        switch mode {
        case .following:
            return adjustment(to: newLayout.maxClipOriginY, from: clipOriginY)
        case let .reading(anchorBlockID, offset):
            if let anchorRow = newLayout.row(for: anchorBlockID) {
                return adjustment(to: newLayout.clampedClipOriginY(anchorRow.minY - offset), from: clipOriginY)
            }
            return fallbackAdjustment(
                lostAnchorBlockID: anchorBlockID,
                oldLayout: oldLayout,
                newLayout: newLayout,
                clipOriginY: clipOriginY
            )
        }
    }

    /// Content appended at the end (new turn or row). Equivalent to `layoutDidChange`.
    mutating func didAppend(
        from oldLayout: TranscriptScrollAnchorLayout,
        to newLayout: TranscriptScrollAnchorLayout,
        clipOriginY: CGFloat
    ) -> TranscriptScrollAnchorAdjustment {
        layoutDidChange(from: oldLayout, to: newLayout, clipOriginY: clipOriginY)
    }

    /// A streaming row grew. Reading leaves the viewport alone unless growth happened above the
    /// anchor; following pins to the new bottom.
    mutating func streamingDidGrow(
        from oldLayout: TranscriptScrollAnchorLayout,
        to newLayout: TranscriptScrollAnchorLayout,
        clipOriginY: CGFloat
    ) -> TranscriptScrollAnchorAdjustment {
        layoutDidChange(from: oldLayout, to: newLayout, clipOriginY: clipOriginY)
    }

    /// The viewport width changed and every row reflowed. When the viewport top sits inside the
    /// anchor row, the same fraction of that row stays at the viewport top.
    mutating func widthDidChange(
        from oldLayout: TranscriptScrollAnchorLayout,
        to newLayout: TranscriptScrollAnchorLayout,
        clipOriginY: CGFloat
    ) -> TranscriptScrollAnchorAdjustment {
        if case let .reading(anchorBlockID, offset) = mode,
           offset < 0,
           let oldRow = oldLayout.row(for: anchorBlockID),
           let newRow = newLayout.row(for: anchorBlockID),
           oldRow.height > 0
        {
            let scaledOffset = offset * (newRow.height / oldRow.height)
            mode = .reading(anchorBlockID: anchorBlockID, offsetFromViewportTop: scaledOffset)
        }
        return layoutDidChange(from: oldLayout, to: newLayout, clipOriginY: clipOriginY)
    }

    // MARK: Explicit jumps

    /// Explicit navigation (top, a specific turn/block, bottom).
    mutating func jump(
        to target: TranscriptScrollAnchorJump,
        layout: TranscriptScrollAnchorLayout,
        clipOriginY: CGFloat
    ) -> TranscriptScrollAnchorAdjustment {
        switch target {
        case .bottom:
            mode = .following
            return adjustment(to: layout.maxClipOriginY, from: clipOriginY)
        case .top:
            guard let firstRow = layout.rows.first else {
                mode = .following
                return adjustment(to: layout.maxClipOriginY, from: clipOriginY)
            }
            return read(from: firstRow, layout: layout, clipOriginY: clipOriginY)
        case let .block(blockID):
            guard let row = layout.row(for: blockID) else { return .none }
            return read(from: row, layout: layout, clipOriginY: clipOriginY)
        }
    }

    // MARK: Helpers

    private mutating func read(
        from row: TranscriptScrollAnchorRowFrame,
        layout: TranscriptScrollAnchorLayout,
        clipOriginY: CGFloat
    ) -> TranscriptScrollAnchorAdjustment {
        let target = layout.clampedClipOriginY(row.minY)
        if layout.distanceToBottom(clipOriginY: target) <= followThreshold {
            mode = .following
            return adjustment(to: layout.maxClipOriginY, from: clipOriginY)
        }
        mode = .reading(anchorBlockID: row.blockID, offsetFromViewportTop: row.minY - target)
        return adjustment(to: target, from: clipOriginY)
    }

    /// The anchor row vanished. Re-anchor to the nearest surviving row of the same turn, keeping
    /// that row where it was on screen; if the turn has no surviving rows, go to the bottom.
    private mutating func fallbackAdjustment(
        lostAnchorBlockID: String,
        oldLayout: TranscriptScrollAnchorLayout,
        newLayout: TranscriptScrollAnchorLayout,
        clipOriginY: CGFloat
    ) -> TranscriptScrollAnchorAdjustment {
        guard let lostRow = oldLayout.row(for: lostAnchorBlockID),
              let turnID = lostRow.turnID
        else {
            mode = .following
            return adjustment(to: newLayout.maxClipOriginY, from: clipOriginY)
        }
        let survivingTurnRows = oldLayout.rows.filter { row in
            row.turnID == turnID && row.blockID != lostAnchorBlockID && newLayout.row(for: row.blockID) != nil
        }
        guard let nearestOldRow = survivingTurnRows.min(by: { lhs, rhs in
            abs(lhs.minY - lostRow.minY) < abs(rhs.minY - lostRow.minY)
        }),
            let nearestNewRow = newLayout.row(for: nearestOldRow.blockID)
        else {
            mode = .following
            return adjustment(to: newLayout.maxClipOriginY, from: clipOriginY)
        }
        let offset = nearestOldRow.minY - clipOriginY
        mode = .reading(anchorBlockID: nearestNewRow.blockID, offsetFromViewportTop: offset)
        return adjustment(to: newLayout.clampedClipOriginY(nearestNewRow.minY - offset), from: clipOriginY)
    }

    private func adjustment(to target: CGFloat, from clipOriginY: CGFloat) -> TranscriptScrollAnchorAdjustment {
        abs(target - clipOriginY) < 0.5 ? .none : .setClipOrigin(target)
    }
}
