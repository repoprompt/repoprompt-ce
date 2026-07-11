//
//  ChatSharedComponents.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-01-13.
//

import AppKit
import QuartzCore
import SwiftUI

struct LoadingIndicatorWithStop: View {
    let isHovered: Bool
    let source: CancelButtonSource

    var body: some View {
        ZStack {
            LayerBackedCancelSpinner()
                .allowsHitTesting(false)

            Rectangle()
                .fill(Color.accentColor)
                .frame(width: isHovered ? 10 : 8, height: isHovered ? 10 : 8)
                .opacity(isHovered ? 1.0 : 0.8)
        }
        .onAppear(perform: recordAppear)
        .onDisappear(perform: recordDisappear)
    }

    private func recordAppear() {
        #if DEBUG
            let sourceName = source.rawValue
            AgentModePerfDiagnostics.increment(AgentModePerfDiagnostics.counterKey("cancelSpinner.appear", source: sourceName))
            AgentModePerfDiagnostics.event("cancelSpinner.appear", fields: ["source": sourceName])
        #endif
    }

    private func recordDisappear() {
        #if DEBUG
            let sourceName = source.rawValue
            AgentModePerfDiagnostics.increment(AgentModePerfDiagnostics.counterKey("cancelSpinner.disappear", source: sourceName))
            AgentModePerfDiagnostics.event("cancelSpinner.disappear", fields: ["source": sourceName])
        #endif
    }
}

private struct LayerBackedCancelSpinner: NSViewRepresentable {
    func makeNSView(context _: Context) -> CancelSpinnerLayerView {
        let view = CancelSpinnerLayerView()
        view.strokeColor = NSColor.controlAccentColor.cgColor
        return view
    }

    func updateNSView(_ nsView: CancelSpinnerLayerView, context _: Context) {
        nsView.strokeColor = NSColor.controlAccentColor.cgColor
        nsView.startAnimatingIfNeeded()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView _: CancelSpinnerLayerView,
        context _: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 24, height: proposal.height ?? 24)
    }

    static func dismantleNSView(_ nsView: CancelSpinnerLayerView, coordinator _: ()) {
        nsView.stopAnimating()
    }
}

private final class CancelSpinnerLayerView: NSView {
    private let arcLayer = CAShapeLayer()
    private let animationKey = "cancelSpinner.rotation"
    private let arcFraction: CGFloat = 0.7
    private let spinnerLineWidth: CGFloat = 2

    var strokeColor: CGColor = NSColor.controlAccentColor.cgColor {
        didSet {
            arcLayer.strokeColor = strokeColor
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
        NSSize(width: 24, height: 24)
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
            startAnimatingIfNeeded()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    func startAnimatingIfNeeded() {
        guard window != nil else { return }
        ensureArcLayerInstalled()
        if arcLayer.animation(forKey: animationKey) != nil {
            return
        }

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = -CGFloat.pi / 2
        rotation.toValue = (3 * CGFloat.pi) / 2
        rotation.duration = 1.0
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotation.isRemovedOnCompletion = false
        arcLayer.add(rotation, forKey: animationKey)
    }

    func stopAnimating() {
        arcLayer.removeAnimation(forKey: animationKey)
    }

    private func configureLayerTree() {
        wantsLayer = true
        arcLayer.fillColor = nil
        arcLayer.strokeColor = strokeColor
        arcLayer.lineWidth = spinnerLineWidth
        arcLayer.lineCap = .butt
        arcLayer.strokeStart = 0
        arcLayer.strokeEnd = arcFraction
        arcLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "path": NSNull(),
            "strokeColor": NSNull()
        ]
        ensureArcLayerInstalled()
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
        let inset = spinnerLineWidth / 2
        arcLayer.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        arcLayer.lineWidth = spinnerLineWidth
        CATransaction.commit()
    }

    private func updateContentsScale() {
        arcLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}

struct EmptyChatOverlay: View {
    let textIsEmpty: Bool
    @Environment(\.font) private var envFont

    var body: some View {
        VStack(spacing: 20) {
            if textIsEmpty {
                Text("Type a message to send...")
                    .font(envFont != nil ? envFont!.weight(.semibold).scale(1.5) : .system(size: 19.5, weight: .semibold))
                    .foregroundColor(.secondary)
            } else {
                Text("Hit send or ↵ to start chatting")
                    .font(envFont != nil ? envFont!.weight(.semibold).scale(1.5) : .system(size: 19.5, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            Text("Select files from the sidebar, then ask Oracle for chat, planning, or review help.")
                .font(envFont ?? .body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}
