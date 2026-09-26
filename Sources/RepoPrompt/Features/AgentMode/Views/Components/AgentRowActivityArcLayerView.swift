import AppKit
import SwiftUI

/// The running row's spinning arc, animated by the render server instead of SwiftUI.
///
/// A SwiftUI `repeatForever` rotation is interpolated on the main thread: every frame re-renders the
/// row's whole window hosting view, lays the window out, and commits its layer tree, so every window
/// with a running row paid a per-frame main-thread cost that scaled with its sidebar and transcript
/// rather than with the 15 pt arc. A `CABasicAnimation` on the arc's own shape layer is run by the
/// render server, so the main thread does no per-frame work while it spins.
///
/// It keeps the SwiftUI arc's geometry, colour and motion: `Circle().trim(from: 0, to: 0.7)` stroked
/// 1.5 pt wide with round caps, at 0.75 of the tint's opacity, in a 15 pt frame, turning clockwise
/// once a second.
struct AgentRowAnimatedActivityArc: NSViewRepresentable {
    var tint: Color

    func makeNSView(context _: Context) -> AgentRowActivityArcLayerView {
        let view = AgentRowActivityArcLayerView()
        view.tint = NSColor(tint)
        return view
    }

    func updateNSView(_ nsView: AgentRowActivityArcLayerView, context _: Context) {
        nsView.tint = NSColor(tint)
        nsView.startAnimatingIfNeeded()
    }

    func sizeThatFits(
        _: ProposedViewSize,
        nsView _: AgentRowActivityArcLayerView,
        context _: Context
    ) -> CGSize? {
        CGSize(width: AgentRowActivityArcLayerView.diameter, height: AgentRowActivityArcLayerView.diameter)
    }

    static func dismantleNSView(_ nsView: AgentRowActivityArcLayerView, coordinator _: ()) {
        nsView.stopAnimating()
    }
}

final class AgentRowActivityArcLayerView: NSView {
    static let diameter: CGFloat = 15
    static let lineWidth: CGFloat = 1.5
    static let arcFraction: CGFloat = 0.7
    static let strokeOpacity: CGFloat = 0.75
    static let rotationDuration: CFTimeInterval = 1.0
    static let animationKey = "agentRowActivityArc.rotation"

    let arcLayer = CAShapeLayer()

    var tint: NSColor = .controlAccentColor {
        didSet {
            guard tint != oldValue else { return }
            updateStrokeColor()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayerTree()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayerTree()
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.diameter, height: Self.diameter)
    }

    /// Decorative, like the SwiftUI shape it replaces: clicks go through to the plate's chevron and the
    /// row, independently of the call site's `.allowsHitTesting(false)`.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        ensureArcLayerInstalled()
        updateArcGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimating()
        } else {
            updateContentsScale()
            startAnimatingIfNeeded()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateStrokeColor()
    }

    /// Idempotent; a no-op outside a window, where nothing can see the arc.
    func startAnimatingIfNeeded() {
        guard window != nil else { return }
        ensureArcLayerInstalled()
        guard arcLayer.animation(forKey: Self.animationKey) == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = 2 * CGFloat.pi
        rotation.duration = Self.rotationDuration
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotation.isRemovedOnCompletion = false
        arcLayer.add(rotation, forKey: Self.animationKey)
    }

    func stopAnimating() {
        arcLayer.removeAnimation(forKey: Self.animationKey)
    }

    private func configureLayerTree() {
        wantsLayer = true
        arcLayer.fillColor = nil
        arcLayer.lineWidth = Self.lineWidth
        arcLayer.lineCap = .round
        arcLayer.strokeStart = 0
        arcLayer.strokeEnd = Self.arcFraction
        arcLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "path": NSNull(),
            "strokeColor": NSNull(),
            "contentsScale": NSNull()
        ]
        ensureArcLayerInstalled()
        updateStrokeColor()
        updateContentsScale()
        updateArcGeometry()
    }

    private func ensureArcLayerInstalled() {
        wantsLayer = true
        guard let hostLayer = layer else { return }
        if arcLayer.superlayer !== hostLayer {
            arcLayer.removeFromSuperlayer()
            hostLayer.addSublayer(arcLayer)
        }
    }

    private func updateArcGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arcLayer.frame = bounds
        // Stroked on the inscribed circle, like SwiftUI's `Circle().stroke` in its frame.
        arcLayer.path = CGPath(ellipseIn: arcLayer.bounds, transform: nil)
        CATransaction.commit()
    }

    /// Resolves the (possibly dynamic) tint against this view's appearance, at the SwiftUI arc's
    /// opacity. AppKit reports accent-colour changes, as well as light and dark ones, through
    /// `viewDidChangeEffectiveAppearance`, which calls this again, so the arc follows them the way
    /// SwiftUI's `Color.accentColor` does.
    private func updateStrokeColor() {
        var resolved: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = self.tint.withAlphaComponent(self.tint.alphaComponent * Self.strokeOpacity).cgColor
        }
        arcLayer.strokeColor = resolved
    }

    private func updateContentsScale() {
        arcLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}
