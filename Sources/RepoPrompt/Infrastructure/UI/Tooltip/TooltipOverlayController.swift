//  TooltipOverlayController.swift
//  RepoPrompt
//
//  Created by RepoPrompt-AI.
//  Updated to reduce display-cycle churn: orderFront only on show, skip redundant repositions.
//

import AppKit
import SwiftUI

@MainActor
final class TooltipOverlayController {
    // MARK: – Public API

    func show(
        content: TooltipContent,
        anchorRect: NSRect,
        owner: NSWindow,
        placement: TooltipPlacement,
        preset: FontScalePreset
    ) {
        prepareWindowIfNeeded(owner: owner, preset: preset)
        let bubbleSize = bubbleSize(for: content.text, preset: preset)
        guard let win else { return }

        cachedText = content.text
        cachedPlacement = placement
        cachedPreset = preset

        // Update SwiftUI rootView
        if let hosting = win.contentView as? NSHostingView<AnyView> {
            hosting.rootView = AnyView(TooltipBubble(content: content, preset: preset))
        }

        // Resize & position
        var f = win.frame
        f.size = bubbleSize
        win.setFrame(f, display: false) // avoid immediate display-cycle churn
        reposition(to: anchorRect)

        // Order front once (show), not on every reposition
        win.orderFront(nil)
    }

    func reposition(to anchorRect: NSRect) {
        guard
            let win,
            let owner,
            let text = cachedText,
            let preset = cachedPreset
        else { return }

        // Validate that owner window is still valid
        guard owner.isVisible else {
            hide()
            return
        }

        // 1. Work in screen coordinates
        let anchor = owner.convertToScreen(anchorRect)

        // 2. Sizes
        let bubble = bubbleSize(for: text, preset: preset)
        let arrow = Self.arrowGap * preset.scaleFactor

        // 3. Compute *top-left* window position for every placement
        let topLeft: NSPoint = {
            switch cachedPlacement {
            case .top:
                // Bubble ABOVE anchor – its bottom is arrow pts above anchor.top
                let x = anchor.midX - bubble.width / 2
                let y = anchor.maxY + arrow + bubble.height
                return NSPoint(x: x, y: y)

            case .bottom:
                // Bubble BELOW anchor – its top is arrow pts below anchor.bottom
                let x = anchor.midX - bubble.width / 2
                let y = anchor.minY - arrow
                return NSPoint(x: x, y: y)

            case .left:
                // Bubble LEFT of anchor – its right edge is arrow pts left of anchor.left
                let x = anchor.minX - arrow - bubble.width
                let y = anchor.midY + bubble.height / 2
                return NSPoint(x: x, y: y)

            case .right:
                // Bubble RIGHT of anchor – its left edge is arrow pts right of anchor.right
                let x = anchor.maxX + arrow
                let y = anchor.midY + bubble.height / 2
                return NSPoint(x: x, y: y)

            case .topLeft:
                let x = anchor.minX
                let y = anchor.maxY + arrow + bubble.height
                return NSPoint(x: x, y: y)

            case .topRight:
                let x = anchor.maxX - bubble.width
                let y = anchor.maxY + arrow + bubble.height
                return NSPoint(x: x, y: y)

            case .bottomLeft:
                let x = anchor.minX
                let y = anchor.minY - arrow
                return NSPoint(x: x, y: y)

            case .bottomRight:
                let x = anchor.maxX - bubble.width
                let y = anchor.minY - arrow
                return NSPoint(x: x, y: y)
            }
        }()

        // Skip redundant frame sets (reduces display-cycle flush churn)
        let currentTopLeft = NSPoint(x: win.frame.origin.x, y: win.frame.origin.y + win.frame.height)
        let eps: CGFloat = 0.5
        if abs(currentTopLeft.x - topLeft.x) < eps, abs(currentTopLeft.y - topLeft.y) < eps {
            return
        }

        win.setFrameTopLeftPoint(topLeft)
        // NOTE: No orderFront here - only call orderFront in show()
    }

    func hide() {
        guard let w = win else { return }

        // Safely remove from window hierarchy
        w.orderOut(nil)

        // Only remove child window if it was added and owner is still valid
        if let owner,
           owner.isVisible,
           owner.childWindows?.contains(w) == true
        {
            owner.removeChildWindow(w)
        }

        // Remove notification observer
        if let token = ownerWillCloseObserver {
            NotificationCenter.default.removeObserver(token)
            ownerWillCloseObserver = nil
        }

        win = nil
        owner = nil
        cachedText = nil
        cachedPlacement = .top
        cachedPreset = nil
    }

    // MARK: – Private

    private weak var owner: NSWindow?
    private var win: TooltipWindow?
    private var cachedText: String?
    private var cachedPlacement: TooltipPlacement = .top
    private var cachedPreset: FontScalePreset?

    private var ownerWillCloseObserver: NSObjectProtocol?

    /// Distance (in points) between the tooltip bubble and its anchor view.
    /// Kept small to avoid a large visual gap; still multiplied by
    /// `preset.scaleFactor` to honour accessibility font scaling.
    private static let arrowGap: CGFloat = 6

    private func prepareWindowIfNeeded(
        owner: NSWindow,
        preset: FontScalePreset
    ) {
        guard win == nil else { return }
        self.owner = owner
        let initial = bubbleSize(for: "", preset: preset)
        let tooltipWindow = TooltipWindow(contentSize: initial)

        // Set up the window but don't add as child window yet
        // This avoids hierarchy issues with menus
        win = tooltipWindow

        ownerWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: owner,
            queue: .main
        ) // ensure main thread
            { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.hide()
                }
        }
    }

    private func bubbleSize(for text: String, preset: FontScalePreset) -> CGSize {
        let maxWidth = 320 * preset.scaleFactor
        let padding = 8 * preset.scaleFactor * 2

        // Use the actual caption font size that matches what TooltipBubble uses
        let captionSize = max(preset.rawValue - 2, 9)
        let attrFont = NSFont.systemFont(ofSize: CGFloat(captionSize))

        // Calculate text size with proper options for accurate sizing
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: attrFont,
            .paragraphStyle: paragraphStyle
        ]

        let box = (text as NSString).boundingRect(
            with: CGSize(
                width: maxWidth - padding,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading, .usesDeviceMetrics],
            attributes: attributes
        )

        // Add buffer for font rendering variations and line height differences
        let widthBuffer: CGFloat = 4 * preset.scaleFactor
        let heightBuffer: CGFloat = 4 * preset.scaleFactor

        return CGSize(
            width: ceil(min(box.width + padding + widthBuffer, maxWidth)),
            height: ceil(box.height + padding + heightBuffer)
        )
    }

    // ---------------------------------------------------------------------
    // MARK: TooltipWindow

    /// ---------------------------------------------------------------------
    private final class TooltipWindow: NSWindow {
        init(contentSize: CGSize) {
            let rect = NSRect(origin: .zero, size: contentSize)
            super.init(
                contentRect: rect,
                styleMask: .borderless,
                backing: .buffered,
                defer: true
            )
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            level = .floating
            ignoresMouseEvents = true
            contentView = NSHostingView(rootView: AnyView(EmptyView()))
        }
    }
}
