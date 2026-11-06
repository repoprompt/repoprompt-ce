//
//  AgentModeTitlebarAccessoryViewController.swift
//  RepoPrompt
//
//  Xcode-style titlebar accessory that places a "New Session" button
//  near the traffic lights using NSTitlebarAccessoryViewController.
//

import Cocoa
import SwiftUI

// MARK: - SwiftUI Views for Titlebar Buttons

/// Compact "New Session" button designed for the titlebar area
struct AgentModeTitlebarNewSessionButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
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

private struct AgentModeTitlebarSidebarToggleButton: View {
    let isSidebarCollapsed: Bool
    let action: () -> Void
    @State private var isHovering = false

    private var label: String {
        isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.primary.opacity(isHovering ? 1.0 : 0.7))
        }
        .buttonStyle(TitlebarAccessoryButtonStyle(isHovering: isHovering))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .hoverTooltip(label, .bottom)
        .accessibilityLabel(label)
    }
}

/// Everything beside the traffic lights. The toggle comes first so it never moves when the sidebar
/// collapses. Compose normally sits at the sidebar's trailing edge; that cluster goes away with the
/// sidebar, so compose appears here while it is hidden.
private struct AgentModeTitlebarLeadingView: View {
    let isSidebarCollapsed: Bool
    let onToggleSidebar: () -> Void
    let onNewSession: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            AgentModeTitlebarSidebarToggleButton(
                isSidebarCollapsed: isSidebarCollapsed,
                action: onToggleSidebar
            )
            if isSidebarCollapsed {
                AgentModeTitlebarNewSessionButton(action: onNewSession)
            }
        }
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
    private var hostingView: NSHostingView<AgentModeTitlebarLeadingView>?
    private var rootView: AgentModeTitlebarLeadingView

    init(
        isSidebarCollapsed: Bool,
        onToggleSidebar: @escaping () -> Void,
        onNewSession: @escaping () -> Void
    ) {
        rootView = AgentModeTitlebarLeadingView(
            isSidebarCollapsed: isSidebarCollapsed,
            onToggleSidebar: onToggleSidebar,
            onNewSession: onNewSession
        )
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .leading
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame.size = hosting.fittingSize
        hostingView = hosting
        view = hosting
    }

    /// Updates the content without recreating the controller
    func update(
        isSidebarCollapsed: Bool,
        onToggleSidebar: @escaping () -> Void,
        onNewSession: @escaping () -> Void
    ) {
        rootView = AgentModeTitlebarLeadingView(
            isSidebarCollapsed: isSidebarCollapsed,
            onToggleSidebar: onToggleSidebar,
            onNewSession: onNewSession
        )
        guard let hostingView else { return }
        hostingView.rootView = rootView
        // The accessory's width follows its content: compose comes and goes with the sidebar.
        hostingView.frame.size = hostingView.fittingSize
    }
}
