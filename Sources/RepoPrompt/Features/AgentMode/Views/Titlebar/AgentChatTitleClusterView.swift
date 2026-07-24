import AppKit
import SwiftUI

@MainActor
final class AgentChatTitleClusterModel: ObservableObject {
    struct State: Equatable {
        var title: String
        var showsChatOptions: Bool
    }

    @Published private(set) var state: State

    init(title: String) {
        state = State(title: title, showsChatOptions: false)
    }

    func update(title: String, showsChatOptions: Bool) {
        let nextState = State(title: title, showsChatOptions: showsChatOptions)
        guard state != nextState else { return }
        state = nextState
    }
}

struct AgentChatTitleClusterView<Title: View>: View {
    @ObservedObject var model: AgentChatTitleClusterModel
    let menuSnapshot: () -> AgentChatOptionsMenuSnapshot?
    let menuActions: AgentChatOptionsMenuActions
    @ViewBuilder let title: (String) -> Title

    var body: some View {
        HStack(spacing: 4) {
            title(model.state.title)

            if model.state.showsChatOptions {
                AgentChatOptionsMenuButton(
                    menuSnapshot: menuSnapshot,
                    menuActions: menuActions
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }
}

final class AgentChatOptionsButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateAppearance() }
    }

    init() {
        super.init(frame: .zero)

        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Chat Options")
        imagePosition = .imageOnly
        isBordered = false
        focusRingType = .exterior
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Chat Options"
        setAccessibilityLabel("Chat Options")
        setAccessibilityRole(.menuButton)
        setAccessibilityIdentifier("AgentChatOptionsButton")

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 24)
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with _: NSEvent) {
        guard isEnabled, let action else { return }
        NSApplication.shared.sendAction(action, to: target, from: self)
    }

    override var focusRingMaskBounds: NSRect {
        bounds
    }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: focusRingMaskBounds,
            xRadius: layer?.cornerRadius ?? 6,
            yRadius: layer?.cornerRadius ?? 6
        ).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseEnteredAndExited]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
    }

    private func updateAppearance() {
        layer?.backgroundColor = isHovering
            ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
        contentTintColor = NSColor.labelColor.withAlphaComponent(isHovering ? 1 : 0.8)
    }
}

private struct AgentChatOptionsMenuButton: NSViewRepresentable {
    let menuSnapshot: () -> AgentChatOptionsMenuSnapshot?
    let menuActions: AgentChatOptionsMenuActions

    func makeCoordinator() -> Coordinator {
        Coordinator(menuSnapshot: menuSnapshot, menuActions: menuActions)
    }

    func makeNSView(context: Context) -> AgentChatOptionsButton {
        let button = AgentChatOptionsButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        return button
    }

    func updateNSView(_ nsView: AgentChatOptionsButton, context: Context) {
        _ = nsView
        context.coordinator.menuSnapshot = menuSnapshot
        context.coordinator.menuActions = menuActions
    }

    @MainActor
    final class Coordinator: NSObject {
        var menuSnapshot: () -> AgentChatOptionsMenuSnapshot?
        var menuActions: AgentChatOptionsMenuActions

        init(
            menuSnapshot: @escaping () -> AgentChatOptionsMenuSnapshot?,
            menuActions: AgentChatOptionsMenuActions
        ) {
            self.menuSnapshot = menuSnapshot
            self.menuActions = menuActions
        }

        @objc func showMenu(_ sender: NSButton) {
            guard let snapshot = menuSnapshot() else { return }
            AgentChatOptionsMenuPresenter.popUp(
                below: sender,
                snapshot: snapshot,
                actions: menuActions
            )
        }
    }
}
