//
//  AgentModeTitlebarAccessoryViewController.swift
//  RepoPrompt
//
//  Xcode-style titlebar accessory that places a "New Session" button
//  near the traffic lights using NSTitlebarAccessoryViewController.
//

import Cocoa
import SwiftUI

// MARK: - SwiftUI View for Titlebar Button

/// Compact "New Session" button designed for the titlebar area
private struct AgentModeTitlebarNewSessionView: View {
    let onNewSession: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onNewSession) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.primary.opacity(isHovering ? 1.0 : 0.7))
                // SEARCH-HELPER: Titlebar, Alignment, Compose icon offset
                // The `square.and.pencil` glyph's pencil shaft extends up-and-right
                // beyond the square, so the geometric center of its bounding box sits
                // higher than the visible mass (the square). Centering the bounding
                // box therefore renders the square visibly *low* relative to the
                // traffic lights — nudge the icon up slightly to correct the optical
                // center.
                .offset(y: -1.5)
        }
        .buttonStyle(TitlebarAccessoryButtonStyle(isHovering: isHovering))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .hoverTooltip("New Session", .bottom)
        .accessibilityLabel("New Session")
    }
}

/// Button style optimized for titlebar accessory placement
struct TitlebarAccessoryButtonStyle: ButtonStyle {
    let isHovering: Bool

    init(isHovering: Bool = false) {
        self.isHovering = isHovering
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 36, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            Color.primary.opacity(0.15)
        } else if isHovering {
            Color.primary.opacity(0.08)
        } else {
            Color.clear
        }
    }
}

// MARK: - AppKit Titlebar Accessory Controller

@MainActor
final class AgentModeTitlebarAccessoryViewController: NSTitlebarAccessoryViewController {
    private var hostingView: NSHostingView<AgentModeTitlebarNewSessionView>?
    private var onNewSession: () -> Void

    init(onNewSession: @escaping () -> Void) {
        self.onNewSession = onNewSession
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .leading
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let swiftUIView = AgentModeTitlebarNewSessionView(onNewSession: onNewSession)
        let hosting = NSHostingView(rootView: swiftUIView)
        hosting.frame.size = hosting.fittingSize
        hostingView = hosting
        view = hosting
    }

    /// Updates the action closure without recreating the controller
    func update(onNewSession: @escaping () -> Void) {
        self.onNewSession = onNewSession
        hostingView?.rootView = AgentModeTitlebarNewSessionView(onNewSession: onNewSession)
    }
}
