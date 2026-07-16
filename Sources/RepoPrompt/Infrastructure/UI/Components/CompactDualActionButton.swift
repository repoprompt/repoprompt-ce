//
//  CompactDualActionButton.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-09.
//

import AppKit
import SwiftUI

struct CompactDualActionButton: View {
    // Main button properties
    let icon: String
    let label: String
    let mainAction: () -> Void

    // Secondary button properties
    let secondaryIcon: String
    let secondaryAction: () -> Void

    /// Optional help text
    let helpText: String?

    // Appearance states
    @State private var isHovering = false
    @State private var isHoveringMainPart = false
    @State private var isHoveringSecondaryPart = false
    @State private var isPressedMain = false
    @State private var isPressedSecondary = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    // Colors (match CustomButtonStyle)
    let backgroundColor = Color(nsColor: .controlBackgroundColor).opacity(0.75)
    let disabledColor = Color(nsColor: .controlBackgroundColor).opacity(0.25)
    let lineColor = Color(NSColor.systemGray)

    // Padding values
    let verticalPadding: CGFloat = 5
    let horizontalPadding: CGFloat = 8

    init(
        icon: String,
        label: String,
        mainAction: @escaping () -> Void,
        secondaryIcon: String,
        secondaryAction: @escaping () -> Void,
        helpText: String? = nil
    ) {
        self.icon = icon
        self.label = label
        self.mainAction = mainAction
        self.secondaryIcon = secondaryIcon
        self.secondaryAction = secondaryAction
        self.helpText = helpText
    }

    var body: some View {
        HStack(spacing: 0) {
            // Main button
            Button(action: mainAction) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .imageScale(.medium)
                    Text(label)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.horizontal, horizontalPadding)
            .background(backgroundForPart(isHovering: isHoveringMainPart, isPressed: isPressedMain))
            .onHover { hovering in
                guard isHoveringMainPart != hovering else { return }
                isHoveringMainPart = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressedMain = true }
                    .onEnded { _ in
                        isPressedMain = false
                    }
            )

            // Divider
            Divider()
                .frame(height: 16)

            // Secondary button
            Button(action: secondaryAction) {
                Image(systemName: secondaryIcon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(isEnabled ? .secondary : .gray)
                    .frame(width: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .background(backgroundForPart(isHovering: isHoveringSecondaryPart, isPressed: isPressedSecondary))
            .onHover { hovering in
                guard isHoveringSecondaryPart != hovering else { return }
                isHoveringSecondaryPart = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressedSecondary = true }
                    .onEnded { _ in
                        isPressedSecondary = false
                    }
            )
        }
        .padding(.vertical, verticalPadding)
        .background(backgroundForState)
        .foregroundColor(isEnabled ? foregroundColor : .gray)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(borderColorForState, lineWidth: 0.5)
        )
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .scaleEffect((isPressedMain || isPressedSecondary) ? 0.98 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressedMain || isPressedSecondary)
        .hoverTooltip(helpText)
    }

    // MARK: - Backgrounds

    private func backgroundForPart(isHovering: Bool, isPressed: Bool) -> some View {
        if !isEnabled {
            return disabledBackground.eraseToAnyView()
        } else if isPressed {
            return pressedBackground.eraseToAnyView()
        } else if isHovering {
            return hoverBackground.eraseToAnyView()
        } else {
            return normalBackground.eraseToAnyView()
        }
    }

    @ViewBuilder
    private var backgroundForState: some View {
        if !isEnabled {
            disabledBackground
        } else if isPressedMain || isPressedSecondary {
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
        } else if isPressedMain || isPressedSecondary {
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
}

extension View {
    func eraseToAnyView() -> AnyView {
        AnyView(self)
    }
}
