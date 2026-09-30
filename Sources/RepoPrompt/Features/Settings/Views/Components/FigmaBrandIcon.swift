import SwiftUI

/// The Figma mark geometry rendered as a monochrome, scalable vector.
struct FigmaBrandIcon: View {
    /// The height of the rendered vector paths, excluding transparent design-space margins.
    var visibleHeight: CGFloat = FigmaBrandIconGeometry.settingsVisibleHeight

    var body: some View {
        Canvas { context, size in
            let mark = FigmaBrandMark()
            let bounds = CGRect(origin: .zero, size: size)
            let color = Color.primary
            context.fill(mark.leftLobePath(in: bounds, yOffset: 340), with: .color(color))
            context.fill(mark.rightLobePath(in: bounds, yOffset: 340), with: .color(color))
            context.fill(mark.leftLobePath(in: bounds, yOffset: 540), with: .color(color))
            context.fill(mark.circlePath(in: bounds), with: .color(color))
            context.fill(mark.leftLobePath(in: bounds, yOffset: 740), with: .color(color))
        }
        .frame(
            width: visibleHeight * FigmaBrandIconGeometry.visibleAspectRatio,
            height: visibleHeight
        )
        .accessibilityHidden(true)
    }
}

enum FigmaBrandIconGeometry {
    /// Bounds of the actual Figma paths in the source design coordinates.
    static let visiblePathBounds = CGRect(x: 312, y: 0, width: 400, height: 940)
    static let visibleAspectRatio = visiblePathBounds.width / visiblePathBounds.height
    /// Shared visible height for the Figma mark in settings icon slots.
    static let settingsVisibleHeight: CGFloat = 18
    static let settingsIconSlotWidth: CGFloat = 16
    /// Optical adjustment for aligning the visible mark with settings title glyphs.
    static let settingsVerticalAlignmentOffset: CGFloat = -3
}

private struct FigmaBrandMark {
    private func point(in rect: CGRect, x: CGFloat, y: CGFloat) -> CGPoint {
        let visibleBounds = FigmaBrandIconGeometry.visiblePathBounds
        let scale = min(rect.width / visibleBounds.width, rect.height / visibleBounds.height)
        let xOffset = rect.midX - visibleBounds.width * scale / 2
        let yOffset = rect.midY - visibleBounds.height * scale / 2
        return CGPoint(
            x: xOffset + (x - visibleBounds.minX) * scale,
            y: yOffset + (y - visibleBounds.minY) * scale
        )
    }

    func leftLobePath(in rect: CGRect, yOffset: CGFloat) -> Path {
        var path = Path()
        path.move(to: point(in: rect, x: 312, y: yOffset + 100))
        path.addCurve(
            to: point(in: rect, x: 412, y: yOffset + 200),
            control1: point(in: rect, x: 312, y: yOffset + 155.228),
            control2: point(in: rect, x: 356.772, y: yOffset + 200)
        )
        path.addLine(to: point(in: rect, x: 512, y: yOffset + 200))
        path.addLine(to: point(in: rect, x: 512, y: yOffset))
        path.addLine(to: point(in: rect, x: 412, y: yOffset))
        path.addCurve(
            to: point(in: rect, x: 312, y: yOffset + 100),
            control1: point(in: rect, x: 356.772, y: yOffset),
            control2: point(in: rect, x: 312, y: yOffset + 44.772)
        )
        path.closeSubpath()
        return path
    }

    func rightLobePath(in rect: CGRect, yOffset: CGFloat) -> Path {
        var path = Path()
        path.move(to: point(in: rect, x: 512, y: yOffset))
        path.addLine(to: point(in: rect, x: 512, y: yOffset + 200))
        path.addLine(to: point(in: rect, x: 612, y: yOffset + 200))
        path.addCurve(
            to: point(in: rect, x: 712, y: yOffset + 100),
            control1: point(in: rect, x: 667.228, y: yOffset + 200),
            control2: point(in: rect, x: 712, y: yOffset + 155.228)
        )
        path.addCurve(
            to: point(in: rect, x: 612, y: yOffset),
            control1: point(in: rect, x: 712, y: yOffset + 44.772),
            control2: point(in: rect, x: 667.228, y: yOffset)
        )
        path.addLine(to: point(in: rect, x: 512, y: yOffset))
        path.closeSubpath()
        return path
    }

    func circlePath(in rect: CGRect) -> Path {
        let visibleBounds = FigmaBrandIconGeometry.visiblePathBounds
        let scale = min(rect.width / visibleBounds.width, rect.height / visibleBounds.height)
        let center = point(in: rect, x: 611.167, y: 640)
        let radius = 100 * scale
        var path = Path()
        path.addEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        return path
    }
}
