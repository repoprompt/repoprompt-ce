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

/// The workspace's colour sticker. A click opens the swatch picker; the System workspace (no
/// colourable workspace) shows nothing.
struct AgentModeTitlebarWorkspaceStickerButton: View {
    @ObservedObject var model: WorkspaceStickerModel
    let host: WorkspaceStickerHost
    @State private var isHovering = false
    /// The last opening this host showed, kept so the popover keeps its swatches while it closes.
    @State private var lastPresentation: WorkspaceStickerModel.PickerPresentation?

    var body: some View {
        if model.state.workspaceID != nil {
            // Captured now: whether the popover shows, its swatches and its dismissal all describe
            // this one opening, so they cannot disagree before the next render.
            let actions = model.actions(in: host)
            Button {
                model.togglePicker(from: host)
            } label: {
                WorkspaceSticker(color: model.state.color)
            }
            .buttonStyle(TitlebarAccessoryButtonStyle(isHovering: isHovering))
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
            .hoverTooltip("Workspace Color", .bottom)
            .accessibilityLabel("Workspace Color")
            .accessibilityValue(model.state.color?.accessibilityLabel ?? "None")
            .accessibilityIdentifier("WorkspaceStickerButton")
            .popover(isPresented: pickerBinding(actions), arrowEdge: .bottom) {
                // While closing, the retired opening's swatches stay visible; they no longer apply.
                if let shown = actions ?? lastPresentation.map(model.actions(for:)) {
                    WorkspaceStickerPickerPopover(model: model, actions: shown)
                }
            }
            .onChange(of: actions?.presentation, initial: true) { _, presentation in
                if let presentation {
                    lastPresentation = presentation
                }
            }
        }
    }

    /// Presented from the model so toolbar re-evaluation cannot drop it. A dismissal only closes
    /// the opening this render showed, never one the other host, or a later opening, has since made.
    private func pickerBinding(_ actions: WorkspaceStickerModel.PickerActions?) -> Binding<Bool> {
        Binding(
            get: { actions != nil },
            set: { isPresented in
                if !isPresented {
                    actions?.dismiss()
                }
            }
        )
    }
}

/// Observes the model so the selection ring follows the stored colour while the popover is open.
/// Swatches apply only through the opening that rendered them.
private struct WorkspaceStickerPickerPopover: View {
    @ObservedObject var model: WorkspaceStickerModel
    let actions: WorkspaceStickerModel.PickerActions

    var body: some View {
        WorkspaceColorSwatchPicker(selection: model.state.color) { color in
            actions.select(color)
        }
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

/// What sits beside the traffic lights. The toggle comes first so it never moves when the sidebar
/// collapses. Compose and the workspace sticker normally sit at the sidebar's trailing edge; that
/// cluster goes away with the sidebar, so they appear here while it is hidden.
enum AgentModeTitlebarLeadingItem: Hashable {
    case sidebarToggle
    case newSession
    case workspaceSticker

    static func items(isSidebarCollapsed: Bool, showsWorkspaceSticker: Bool) -> [Self] {
        guard isSidebarCollapsed else { return [.sidebarToggle] }
        return showsWorkspaceSticker
            ? [.sidebarToggle, .newSession, .workspaceSticker]
            : [.sidebarToggle, .newSession]
    }
}

/// Everything beside the traffic lights, in `AgentModeTitlebarLeadingItem` order.
private struct AgentModeTitlebarLeadingView: View {
    let isSidebarCollapsed: Bool
    /// Passed by value so a change reaches the accessory's measured width through `update`.
    let showsWorkspaceSticker: Bool
    let workspaceSticker: WorkspaceStickerModel
    let onToggleSidebar: () -> Void
    let onNewSession: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(
                AgentModeTitlebarLeadingItem.items(
                    isSidebarCollapsed: isSidebarCollapsed,
                    showsWorkspaceSticker: showsWorkspaceSticker
                ),
                id: \.self
            ) { item in
                switch item {
                case .sidebarToggle:
                    AgentModeTitlebarSidebarToggleButton(
                        isSidebarCollapsed: isSidebarCollapsed,
                        action: onToggleSidebar
                    )
                case .newSession:
                    AgentModeTitlebarNewSessionButton(action: onNewSession)
                case .workspaceSticker:
                    AgentModeTitlebarWorkspaceStickerButton(model: workspaceSticker, host: .titlebarAccessory)
                }
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
        workspaceSticker: WorkspaceStickerModel,
        onToggleSidebar: @escaping () -> Void,
        onNewSession: @escaping () -> Void
    ) {
        rootView = Self.makeRootView(
            isSidebarCollapsed: isSidebarCollapsed,
            workspaceSticker: workspaceSticker,
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
        workspaceSticker: WorkspaceStickerModel,
        onToggleSidebar: @escaping () -> Void,
        onNewSession: @escaping () -> Void
    ) {
        rootView = Self.makeRootView(
            isSidebarCollapsed: isSidebarCollapsed,
            workspaceSticker: workspaceSticker,
            onToggleSidebar: onToggleSidebar,
            onNewSession: onNewSession
        )
        guard let hostingView else { return }
        hostingView.rootView = rootView
        // The accessory's width follows its content: compose and the sticker come and go with the
        // sidebar, and the sticker also with the workspace.
        hostingView.frame.size = hostingView.fittingSize
    }

    private static func makeRootView(
        isSidebarCollapsed: Bool,
        workspaceSticker: WorkspaceStickerModel,
        onToggleSidebar: @escaping () -> Void,
        onNewSession: @escaping () -> Void
    ) -> AgentModeTitlebarLeadingView {
        AgentModeTitlebarLeadingView(
            isSidebarCollapsed: isSidebarCollapsed,
            showsWorkspaceSticker: workspaceSticker.state.workspaceID != nil,
            workspaceSticker: workspaceSticker,
            onToggleSidebar: onToggleSidebar,
            onNewSession: onNewSession
        )
    }
}
