import AppKit

struct ScreenGeometrySnapshot: Equatable {
    let frame: NSRect
    let visibleFrame: NSRect
}

enum ScreenVisibleFrameResolver {
    static func selectedVisibleFrame(
        for anchor: NSRect,
        screens: [ScreenGeometrySnapshot]
    ) -> NSRect? {
        guard !screens.isEmpty else { return nil }

        let intersecting = screens.enumerated().map { index, screen in
            (index, screen, intersectionArea(anchor, screen.frame))
        }
        if let best = intersecting.max(by: { lhs, rhs in
            lhs.2 == rhs.2 ? lhs.0 > rhs.0 : lhs.2 < rhs.2
        }), best.2 > 0 {
            return best.1.visibleFrame
        }

        let anchorCenter = NSPoint(x: anchor.midX, y: anchor.midY)
        return screens.enumerated().min { lhs, rhs in
            let leftDistance = squaredDistance(from: anchorCenter, to: lhs.element.frame)
            let rightDistance = squaredDistance(from: anchorCenter, to: rhs.element.frame)
            return leftDistance == rightDistance ? lhs.offset < rhs.offset : leftDistance < rightDistance
        }?.element.visibleFrame
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(intersection.width, 0) * max(intersection.height, 0)
    }

    private static func squaredDistance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
