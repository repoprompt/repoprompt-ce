import AppKit
import SwiftUI

struct DualActionButton<Content: View>: View {
    @Binding var showPopover: Bool
    let icon: String
    let label: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    let useNativeHitTesting: Bool

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    /// Optional shortcut for the main button, e.g. ("c", [.command, .shift])
    let mainShortcut: (key: KeyEquivalent, modifiers: EventModifiers)?
    // Optional shortcut for the popover button, e.g. ("n", [.command, .shift])
    // let popoverShortcut: (key: KeyEquivalent, modifiers: EventModifiers)?

    @State private var isHovering = false
    @State private var isHoveringMainButton = false
    @GestureState private var isPressed = false
    @State private var actionComplete = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var resetWorkItem: DispatchWorkItem?
    @State private var resetWorkGate = WorkItemGate()
    @State private var clickMonitor: Any?

    let backgroundColor = Color(nsColor: .controlBackgroundColor).opacity(0.75)
    let disabledColor = Color(nsColor: .controlBackgroundColor).opacity(0.25)
    let lineColor = Color(NSColor.systemGray)

    var body: some View {
        HStack(spacing: 0) {
            // Main button
            Button(action: performAction) {
                HStack(spacing: 5) {
                    Image(systemName: actionComplete ? "checkmark" : icon)
                        .font(fontPreset.font)
                    Text(label)
                        .font(fontPreset.font)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            // If mainShortcut is provided, apply it
            .applyKeyboardShortcut(mainShortcut)
            .frame(width: 105)
            .onHover { hovering in
                guard isHoveringMainButton != hovering else { return }
                isHoveringMainButton = hovering
            }
            .hoverTooltip(tooltipTextForMainButton)

            // Divider
            Divider()
                .frame(height: 18)

            // Popover button
            Button(action: { showPopover.toggle() }) {
                Image(systemName: "gear")
                    .font(fontPreset.captionFont.weight(.medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            // If popoverShortcut is provided, apply it
            // .applyKeyboardShortcut(popoverShortcut)
            .frame(width: 24)
            .hoverTooltip("\(label) Settings")
        }
        .frame(width: 136, height: 32)
        .background(backgroundForState)
        .foregroundColor(isEnabled ? foregroundColor : .gray)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColorForState, lineWidth: 0.5)
        )
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
            if hovering {
                startClickMonitor()
            } else {
                stopClickMonitor()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in
                    state = true
                }
        )
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            content()
        }
        .onDisappear {
            stopClickMonitor()
            resetWorkItem?.cancel()
            resetWorkItem = nil
            resetWorkGate.cancel()
        }
    }

    // MARK: - Backgrounds

    @ViewBuilder
    private var backgroundForState: some View {
        if !isEnabled {
            disabledBackground
        } else if isPressed {
            pressedBackground
        } else if isHovering {
            hoverBackground
        } else {
            normalBackground
        }
    }

    private var borderColorForState: Color {
        if !isEnabled {
            lineColor.opacity(0.25)
        } else if isPressed {
            lineColor.opacity(0.5)
        } else if isHovering {
            lineColor
        } else {
            lineColor.opacity(0.75)
        }
    }

    private var normalBackground: some View {
        Color.clear
    }

    private var hoverBackground: some View {
        backgroundColor
            .overlay(Color.primary.opacity(0.05))
    }

    private var pressedBackground: some View {
        backgroundColor
            .overlay(Color.primary.opacity(0.15))
    }

    private var disabledBackground: some View {
        disabledColor
    }

    private var foregroundColor: Color {
        colorScheme == .dark ? .white : .black
    }

    // MARK: - Tooltip Text

    private var tooltipTextForMainButton: String {
        guard let mainShortcut else {
            return label
        }
        let shortcutText = formatKeyboardShortcut(mainShortcut)
        return "\(label) (\(shortcutText))"
    }

    private func formatKeyboardShortcut(_ shortcut: (key: KeyEquivalent, modifiers: EventModifiers)) -> String {
        var parts: [String] = []

        if shortcut.modifiers.contains(.command) {
            parts.append("⌘")
        }
        if shortcut.modifiers.contains(.shift) {
            parts.append("⇧")
        }
        if shortcut.modifiers.contains(.option) {
            parts.append("⌥")
        }
        if shortcut.modifiers.contains(.control) {
            parts.append("⌃")
        }

        // Convert KeyEquivalent to display string
        let keyString = String(shortcut.key.character).uppercased()
        parts.append(keyString)

        return parts.joined()
    }

    // MARK: - Actions

    private func performAction() {
        resetWorkItem?.cancel()
        resetWorkItem = nil
        resetWorkGate.cancel()

        action()

        withAnimation(.easeInOut(duration: 0.2)) {
            actionComplete = true
        }

        resetWorkItem = resetWorkGate.schedule(after: 1.5) {
            withAnimation {
                actionComplete = false
            }
        }
    }

    // MARK: - Native Hit Testing

    private func startClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard isHoveringMainButton, !showPopover else { return event }

            if useNativeHitTesting {
                Task { @MainActor in
                    performAction()
                }
                return event
            }

            guard let window = event.window,
                  let contentView = window.contentView
            else {
                return event
            }

            let pointInWindow = event.locationInWindow
            let pointInView = contentView.convert(pointInWindow, from: nil)

            if let hitView = contentView.hitTest(pointInView),
               hitView.isDescendant(of: contentView)
            {
                Task { @MainActor in
                    performAction()
                }
                return nil
            }

            return event
        }
    }

    private func stopClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        resetWorkItem?.cancel()
        resetWorkItem = nil
        resetWorkGate.cancel()
    }
}

// MARK: - Helper ViewModifier

private struct KeyboardShortcutModifier: ViewModifier {
    let shortcut: (key: KeyEquivalent, modifiers: EventModifiers)

    func body(content: Content) -> some View {
        content.keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
    }
}

private extension View {
    /// Applies a keyboard shortcut if the passed tuple is not nil
    func applyKeyboardShortcut(_ shortcut: (key: KeyEquivalent, modifiers: EventModifiers)?) -> some View {
        guard let shortcut else {
            return AnyView(self)
        }
        return AnyView(modifier(KeyboardShortcutModifier(shortcut: shortcut)))
    }
}
