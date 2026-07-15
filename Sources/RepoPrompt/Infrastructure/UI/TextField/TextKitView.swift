import AppKit
import SwiftUI

/**
 A SwiftUI wrapper around an NSTextView for plain text usage.
 Spell‑checking can optionally be enabled.
 */
struct TextKitView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    var isSpellCheckEnabled: Bool = false
    var fontSize: Double?
    var useMonospacedFont: Bool = false // Use monospaced font
    var wrapLines: Bool = true // New: toggle line-wrapping / horizontal scroll
    var externalUpdateTick: Int = 0
    /// When true, allows non-contiguous layout (incremental layout). Default is false
    /// to fix Intel Mac scroll issues, but can be enabled to avoid expensive full-layout on click.
    var allowNonContiguousLayout: Bool = false
    /// When true, scroll indicators auto-hide when not scrolling. Default is false (always visible).
    var autohidesScrollers: Bool = false
    /// Optional AppKit scroller style override.
    var scrollerStyle: NSScroller.Style?
    /// Notifies parent when the user starts/stops editing so it can gate external writes.
    var onEditingChanged: ((Bool) -> Void)?

    @ObservedObject private var fontScale = FontScaleManager.shared

    private var resolvedFontSize: CGFloat {
        if let fontSize {
            return CGFloat(fontSize)
        }
        return useMonospacedFont
            ? CGFloat(max(fontScale.preset.rawValue - 2, 9))
            : CGFloat(fontScale.preset.rawValue)
    }

    private var resolvedFont: NSFont {
        useMonospacedFont
            ? NSFont.monospacedSystemFont(ofSize: resolvedFontSize, weight: .regular)
            : NSFont.systemFont(ofSize: resolvedFontSize)
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextKitView
        private let textViewUndoManager = UndoManager()
        var internalText: String
        var lastAppliedTick: Int = 0
        // NEW: mark inactive after dismantle
        var isActive: Bool = true
        /// Track previous empty state to detect empty<->non-empty transitions
        var wasEmpty: Bool = true
        var pendingLayoutTask: Task<Void, Never>?
        var layoutGeneration: UInt64 = 0

        fileprivate enum LayoutStabilizationReason {
            case emptyTransition
            case externalWrite
        }

        init(_ parent: TextKitView) {
            self.parent = parent
            internalText = parent.text
            wasEmpty = parent.text.isEmpty
            textViewUndoManager.levelsOfUndo = 100
            textViewUndoManager.groupsByEvent = true
        }

        func textDidChange(_ notification: Notification) {
            guard isActive, let textView = notification.object as? NSTextView else { return }
            let newText = textView.string
            let isEmpty = newText.isEmpty

            // Force full layout on empty<->non-empty transitions (fixes placeholder/scroll issues)
            if isEmpty != wasEmpty {
                wasEmpty = isEmpty
                scheduleLayoutStabilization(
                    for: textView,
                    expectedIsEmpty: isEmpty,
                    reason: .emptyTransition
                )
            }

            internalText = newText
            parent.text = newText
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onEditingChanged?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onEditingChanged?(false)
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            textViewUndoManager
        }

        func performExternalReplacement(
            in textView: NSTextView,
            mutation: () -> Void
        ) {
            TextViewUndoSafeReplacement.perform(
                in: textView,
                undoManager: textViewUndoManager,
                mutation: mutation
            )
        }

        func clearUndoHistory() {
            textViewUndoManager.removeAllActions()
        }

        fileprivate func scheduleLayoutStabilization(
            for textView: NSTextView,
            expectedIsEmpty: Bool,
            reason: LayoutStabilizationReason
        ) {
            layoutGeneration &+= 1
            let generation = layoutGeneration

            pendingLayoutTask?.cancel()
            pendingLayoutTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { return }
                guard isActive else { return }
                guard generation == layoutGeneration else { return }
                guard textView.window != nil else { return }
                guard expectedIsEmpty == textView.string.isEmpty else { return }
                guard !textView.hasMarkedText() else { return }

                textView.clampSelectionToCurrentString()
                let nsLen = textView.currentStringLength()
                if nsLen == 0 {
                    let emptyRange = NSRange(location: 0, length: 0)
                    if let lm = textView.layoutManager {
                        lm.invalidateLayout(forCharacterRange: emptyRange, actualCharacterRange: nil)
                        lm.invalidateDisplay(forCharacterRange: emptyRange)
                    }
                    if reason == .emptyTransition {
                        textView.scrollRangeToVisible(emptyRange)
                    }
                    return
                }

                let fullRange = NSRange(location: 0, length: nsLen)
                if let lm = textView.layoutManager {
                    lm.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
                    lm.invalidateDisplay(forCharacterRange: fullRange)
                }

                let isActiveEditor = (textView.window?.firstResponder as? NSTextView) == textView
                guard !isActiveEditor,
                      let lm = textView.layoutManager,
                      let container = textView.textContainer,
                      container.layoutManager === lm,
                      lm.textContainers.contains(where: { $0 === container })
                else { return }
                lm.ensureLayout(for: container)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        setupTextView(textView, coordinator: context.coordinator)

        // Scroll-view configuration
        scrollView.scrollsDynamically = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.contentView.postsBoundsChangedNotifications = true
        // Enable horizontal scroller when wrapping is disabled
        scrollView.hasHorizontalScroller = !wrapLines
        if let scrollerStyle {
            scrollView.scrollerStyle = scrollerStyle
        }
        return scrollView
    }

    private func setupTextView(_ textView: NSTextView, coordinator: Coordinator) {
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        // Conditionally set font
        textView.font = resolvedFont

        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = coordinator
        textView.string = coordinator.internalText

        textView.isVerticallyResizable = true
        // Wrapping / horizontal behaviour
        if wrapLines {
            textView.isHorizontallyResizable = false
            if let container = textView.textContainer {
                container.containerSize = NSSize(
                    width: 0,
                    height: CGFloat.greatestFiniteMagnitude
                )
                container.widthTracksTextView = true
            }
        } else {
            textView.isHorizontallyResizable = true
            if let container = textView.textContainer {
                container.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
                container.widthTracksTextView = false
            }
        }

        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        if let layoutManager = textView.layoutManager {
            // Non-contiguous layout can cause scroll bar and display issues on Intel Macs
            layoutManager.allowsNonContiguousLayout = false
            layoutManager.usesFontLeading = true
        }

        if let scrollView = textView.enclosingScrollView {
            scrollView.hasVerticalScroller = true
            // Keep this aligned with wrap mode (was hardcoded to false)
            scrollView.hasHorizontalScroller = !wrapLines
            scrollView.autohidesScrollers = autohidesScrollers
            if let scrollerStyle {
                scrollView.scrollerStyle = scrollerStyle
            }
        }

        textView.isRichText = false
        textView.smartInsertDeleteEnabled = false
        textView.displaysLinkToolTips = false

        // Disable costly automatic transforms by default (opt back in if needed)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        if #available(macOS 13.0, *) {
            textView.isAutomaticDataDetectionEnabled = false
        }

        // Configure spell-check and autocorrection (kept user-configurable)
        textView.isContinuousSpellCheckingEnabled = isSpellCheckEnabled
        textView.isAutomaticSpellingCorrectionEnabled = isSpellCheckEnabled
    }

    @MainActor
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? NSTextView else { return }

        // Non-contiguous layout: disabled by default (fixes Intel Mac scroll issues),
        // but can be enabled to avoid expensive full-layout on click.
        if let layoutManager = textView.layoutManager {
            if layoutManager.allowsNonContiguousLayout != allowNonContiguousLayout {
                layoutManager.allowsNonContiguousLayout = allowNonContiguousLayout
            }
        }

        // Mirror wrapping → horizontal scroller only when wrapping is disabled
        if let scrollView = textView.enclosingScrollView {
            let shouldHaveHScroller = !wrapLines
            if scrollView.hasHorizontalScroller != shouldHaveHScroller {
                scrollView.hasHorizontalScroller = shouldHaveHScroller
            }
            if scrollView.autohidesScrollers != autohidesScrollers {
                scrollView.autohidesScrollers = autohidesScrollers
            }
            if let scrollerStyle, scrollView.scrollerStyle != scrollerStyle {
                scrollView.scrollerStyle = scrollerStyle
            }
        }

        // Compute whether we should force a programmatic update even if focused
        let shouldForce = context.coordinator.lastAppliedTick != externalUpdateTick

        // Only touch the font when size/mono actually changed to avoid reflow on every update
        let requiredFont = resolvedFont
        if let currentFont = textView.font {
            let currentSize = currentFont.pointSize
            let isMono = currentFont.fontName.lowercased().contains("mono")
            if currentSize != requiredFont.pointSize || isMono != useMonospacedFont {
                textView.font = requiredFont
            }
        } else {
            textView.font = requiredFont
        }

        // Determine if user is actively editing in this text view
        let wasFirstResponder = (textView.window?.firstResponder as? NSTextView) == textView

        if textView.string != text {
            if textView.hasMarkedText() { return }
            if wasFirstResponder, !shouldForce {
                // Do not overwrite in-flight user edits; let delegate drive the binding.
            } else {
                // Preserve selection but clamp it to the new text length
                let previousSelection = textView.clampedSelectedRange()
                context.coordinator.performExternalReplacement(in: textView) {
                    textView.string = text
                }
                textView.setSelectedRange(previousSelection.clamped(to: textView.currentStringLength()))

                // Only auto-scroll when not forcing or not focused
                let nsLen = textView.currentStringLength()
                if !wasFirstResponder || !shouldForce {
                    textView.scrollRangeToVisible(NSRange(location: nsLen, length: 0))
                }

                // Record that we applied this external tick
                if shouldForce {
                    context.coordinator.lastAppliedTick = externalUpdateTick
                    // Sync empty state tracker
                    context.coordinator.wasEmpty = text.isEmpty
                    context.coordinator.scheduleLayoutStabilization(
                        for: textView,
                        expectedIsEmpty: text.isEmpty,
                        reason: .externalWrite
                    )
                }
            }
        }

        // Ensure wrapping mode is still respected with minimal churn
        if let container = textView.textContainer {
            if wrapLines {
                if container.widthTracksTextView == false {
                    container.widthTracksTextView = true
                    container.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
                }
            } else {
                if container.widthTracksTextView == true {
                    container.widthTracksTextView = false
                }
                container.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }
        }
    }

    /// Ensure AppKit resources are released when SwiftUI detaches the view
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.delegate = nil
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        coordinator.clearUndoHistory()
        textView.string = ""
        coordinator.internalText = ""
        coordinator.wasEmpty = true
        coordinator.pendingLayoutTask?.cancel()
        coordinator.pendingLayoutTask = nil
        // NEW: mark inactive
        coordinator.isActive = false
    }
}
