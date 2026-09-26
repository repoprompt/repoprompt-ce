import AppKit
import QuartzCore
@testable import RepoPromptApp
import SwiftUI
import XCTest

/// The running row's arc spins on the render server: a Core Animation rotation on its own shape
/// layer, not a SwiftUI `repeatForever` that re-renders the whole window every frame on main.
@MainActor
final class AgentRowActivityArcLayerViewTests: XCTestCase {
    func testRunningArcSpinsWithARenderServerRotation() throws {
        let hosted = hostRunningArc()
        defer { hosted.window.close() }

        let arcs = arcViews(in: hosted.host)
        XCTAssertEqual(arcs.count, 1, "the running row's arc is the layer-backed arc")
        let arc = try XCTUnwrap(arcs.first)
        XCTAssertEqual(arc.bounds.size, CGSize(width: 15, height: 15), "the arc keeps its 15 pt frame")
        let rotation = try XCTUnwrap(
            arc.arcLayer.animation(forKey: AgentRowActivityArcLayerView.animationKey) as? CABasicAnimation,
            "the rotation is a Core Animation layer animation"
        )
        XCTAssertEqual(rotation.keyPath, "transform.rotation.z")
        XCTAssertEqual(rotation.repeatCount, .infinity)
        XCTAssertEqual(rotation.duration, 1.0)
        XCTAssertEqual(try XCTUnwrap(rotation.fromValue as? CGFloat), 0)
        XCTAssertEqual(try XCTUnwrap(rotation.toValue as? CGFloat), 2 * .pi, accuracy: 1e-9)
        XCTAssertEqual(rotation.timingFunction, CAMediaTimingFunction(name: .linear))
        XCTAssertFalse(rotation.isRemovedOnCompletion)
    }

    /// SwiftUI draws in y-down space, so `rotationEffect(.degrees(+360))` spins clockwise and
    /// `Circle().trim(0, 0.7)` runs clockwise from 3 o'clock, leaving its gap at the top right. The
    /// layer arc must match: AppKit flips the flipped host view's backing layer, so the arc layer is
    /// effectively y-down on screen, its identical path runs clockwise, and a positive
    /// `transform.rotation.z` turns it clockwise.
    func testHostedArcRunsAndSpinsClockwiseLikeTheSwiftUIArc() throws {
        let hosted = hostRunningArc()
        defer { hosted.window.close() }
        let arc = try XCTUnwrap(arcViews(in: hosted.host).first)
        arc.layoutSubtreeIfNeeded()
        let viewLayer = try XCTUnwrap(arc.layer)
        XCTAssertTrue(arc.arcLayer.contentsAreFlipped(), "the arc layer renders y-down, like SwiftUI")

        let bounds = arc.arcLayer.bounds
        let swiftUIPath = Circle().path(in: bounds).cgPath
        XCTAssertEqual(try pathPoints(XCTUnwrap(arc.arcLayer.path)), pathPoints(swiftUIPath))

        func inWindow(_ point: CGPoint) -> CGPoint {
            arc.convert(arc.arcLayer.convert(point, to: viewLayer), to: nil)
        }
        let center = inWindow(CGPoint(x: bounds.midX, y: bounds.midY))
        let start = inWindow(CGPoint(x: bounds.maxX, y: bounds.midY))
        let quarter = inWindow(CGPoint(x: bounds.midX, y: bounds.maxY))
        // Window coordinates are y-up: 3 o'clock, then 6 o'clock below the center, is clockwise.
        XCTAssertGreaterThan(start.x, center.x)
        XCTAssertEqual(start.y, center.y, accuracy: 0.001)
        XCTAssertLessThan(quarter.y, center.y, "the path runs clockwise, so the trimmed gap is at the top right")

        arc.arcLayer.transform = CATransform3DMakeRotation(0.2, 0, 0, 1)
        let rotatedStart = inWindow(CGPoint(x: bounds.maxX, y: bounds.midY))
        arc.arcLayer.transform = CATransform3DIdentity
        XCTAssertLessThan(rotatedStart.y, start.y, "a positive rotation turns 3 o'clock downward: clockwise")
    }

    func testArcGeometryMatchesTheSwiftUIArc() {
        let arc = AgentRowActivityArcLayerView(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        arc.layout()

        XCTAssertEqual(arc.intrinsicContentSize, NSSize(width: 15, height: 15))
        XCTAssertEqual(arc.arcLayer.frame, arc.bounds)
        XCTAssertEqual(arc.arcLayer.path?.boundingBox, CGRect(x: 0, y: 0, width: 15, height: 15))
        XCTAssertEqual(arc.arcLayer.strokeStart, 0)
        XCTAssertEqual(arc.arcLayer.strokeEnd, 0.7)
        XCTAssertEqual(arc.arcLayer.lineWidth, 1.5)
        XCTAssertEqual(arc.arcLayer.lineCap, .round)
        XCTAssertNil(arc.arcLayer.fillColor)
    }

    func testRotationStartsOnlyInAWindowOnceAndStopsWhenDetached() {
        let arc = AgentRowActivityArcLayerView(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        arc.startAnimatingIfNeeded()
        XCTAssertNil(arc.arcLayer.animation(forKey: AgentRowActivityArcLayerView.animationKey))

        let window = makeWindow()
        defer { window.close() }
        window.contentView?.addSubview(arc)
        let installed = arc.arcLayer.animation(forKey: AgentRowActivityArcLayerView.animationKey)
        XCTAssertNotNil(installed)
        arc.startAnimatingIfNeeded()
        XCTAssertTrue(
            arc.arcLayer.animation(forKey: AgentRowActivityArcLayerView.animationKey) === installed,
            "repeated updates keep the running rotation instead of restarting it"
        )

        arc.removeFromSuperview()
        XCTAssertNil(arc.arcLayer.animation(forKey: AgentRowActivityArcLayerView.animationKey))
    }

    func testTintIsStrokedAtTheSwiftUIArcOpacity() throws {
        let arc = AgentRowActivityArcLayerView(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        arc.tint = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)

        XCTAssertEqual(try strokeComponents(of: arc), [1, 0.5, 0, 0.75])
    }

    /// AppKit reports accent-colour as well as light and dark changes through
    /// `viewDidChangeEffectiveAppearance`; the stroke re-resolves the dynamic tint there, the way
    /// SwiftUI re-resolves `Color.accentColor`.
    func testAppearanceChangeReResolvesTheDynamicTint() throws {
        let arc = AgentRowActivityArcLayerView(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        arc.appearance = NSAppearance(named: .aqua)
        arc.tint = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
                : NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        }
        XCTAssertEqual(try strokeComponents(of: arc), [1, 0, 0, 0.75])

        arc.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(try strokeComponents(of: arc), [0, 0, 1, 0.75])
    }

    /// Decorative, like the SwiftUI shape it replaces: clicks on the arc reach the plate and the row.
    func testArcIsTransparentToClicks() throws {
        let hosted = hostRunningArc()
        defer { hosted.window.close() }
        let arc = try XCTUnwrap(arcViews(in: hosted.host).first)
        let center = NSPoint(x: arc.bounds.midX, y: arc.bounds.midY)

        XCTAssertNil(arc.hitTest(arc.convert(center, to: arc.superview)))
        XCTAssertFalse(hosted.host.hitTest(arc.convert(center, to: hosted.host.superview)) is AgentRowActivityArcLayerView)
    }

    // MARK: - Helpers

    /// The sidebar row's own running arc, hosted in a window the way the row hosts it.
    private func hostRunningArc() -> (host: NSHostingView<AgentRowActivityArc>, window: NSWindow) {
        let host = NSHostingView(rootView: AgentRowActivityArc())
        let window = makeWindow()
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// The stroke's sRGB components, alpha last, rounded so equal colours compare equal.
    private func strokeComponents(of arc: AgentRowActivityArcLayerView) throws -> [CGFloat] {
        let stroke = try XCTUnwrap(arc.arcLayer.strokeColor)
        let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let components = try XCTUnwrap(stroke.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components)
        return components.map { ($0 * 100).rounded() / 100 }
    }

    private func pathPoints(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let count = switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: 1
            case .addQuadCurveToPoint: 2
            case .addCurveToPoint: 3
            case .closeSubpath: 0
            @unknown default: 0
            }
            for index in 0 ..< count {
                let point = element.pointee.points[index]
                // Rounded so equal geometry built by different APIs compares equal.
                points.append(CGPoint(x: (point.x * 1000).rounded() / 1000, y: (point.y * 1000).rounded() / 1000))
            }
        }
        return points
    }

    private func arcViews(in view: NSView) -> [AgentRowActivityArcLayerView] {
        let own: [AgentRowActivityArcLayerView] = (view as? AgentRowActivityArcLayerView).map { [$0] } ?? []
        return own + view.subviews.flatMap { arcViews(in: $0) }
    }
}
