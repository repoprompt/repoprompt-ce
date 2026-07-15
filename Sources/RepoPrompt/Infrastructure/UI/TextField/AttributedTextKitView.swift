import AppKit
import Combine
import SwiftUI

/// A drop-in replacement for `TextKitView` that supports "@" mentions.
struct AttributedTextKitView: NSViewRepresentable {
    // ------------------------------------------------------------
    // MARK: – Cached resources (shared across all instances)

    /// ------------------------------------------------------------
    /// Shared mention-token regex, compiled lazily on first real use.
    private static var tokenRegex: NSRegularExpression = MentionAssets.shared.tokenRegex

    // MARK: – Public API identical to TextKitView

    @Binding var text: String
    var isEditable: Bool = true
    var isSpellCheckEnabled: Bool = false
    var fontSize: Double?
    var useMonospacedFont: Bool = false
    var wrapLines: Bool = true
    var externalUpdateTick: Int = 0
    /// Notify parent about begin/end editing (parity with TextKitView)
    var onEditingChanged: ((Bool) -> Void)?

    /// Needed for mention suggestions & toggling on commit.
    weak var fileManager: WorkspaceFilesViewModel?

    @ObservedObject private var fontScale = FontScaleManager.shared
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared

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

    // MARK: – Coordinator

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: AttributedTextKitView
        private let undoMgr = UndoManager()
        private weak var fileManager: WorkspaceFilesViewModel?
        var mentionCoord: MentionCoordinator?
        fileprivate weak var mentionTV: MentionTextView?

        // Tracks how many live occurences of each relativePath exist
        private var tokenCounts: [String: Int] = [:]
        var lastAppliedTick: Int = 0

        // NEW: local text cache + programmatic write guard + cancellable attr task
        var internalText: String
        var isApplyingExternalWrite: Bool = false
        var pendingAttrTask: Task<Void, Never>?
        var pendingLayoutTask: Task<Void, Never>?
        var layoutGeneration: UInt64 = 0

        // NEW: mark coordinator inactive after dismantle to prevent stale callbacks
        var isActive: Bool = true
        /// Track previous empty state to detect empty<->non-empty transitions
        var wasEmpty: Bool = true

        fileprivate enum LayoutStabilizationReason {
            case emptyTransition
            case externalWrite
        }

        init(_ parent: AttributedTextKitView) {
            self.parent = parent
            fileManager = parent.fileManager
            internalText = parent.text
            wasEmpty = parent.text.isEmpty
            undoMgr.levelsOfUndo = 100
            undoMgr.groupsByEvent = true
        }

        /// NSTextViewDelegate
        func textDidChange(_ notification: Notification) {
            guard isActive,
                  let textView = notification.object as? NSTextView
            else { return }
            // NEW: ignore delegate echo during programmatic updates
            if isApplyingExternalWrite { return }

            let newText = textView.string
            let isEmpty = newText.isEmpty

            // Export **plain** string to binding and keep cache in sync
            internalText = newText
            parent.text = newText

            // Stabilize layout after empty<->non-empty transitions
            if isEmpty != wasEmpty {
                wasEmpty = isEmpty
                scheduleLayoutStabilization(
                    for: textView,
                    expectedIsEmpty: isEmpty,
                    reason: .emptyTransition
                )
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onEditingChanged?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onEditingChanged?(false)
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoMgr
        }

        func performExternalReplacement(
            in textView: NSTextView,
            mutation: () -> Void
        ) {
            TextViewUndoSafeReplacement.perform(
                in: textView,
                undoManager: undoMgr,
                mutation: mutation
            )
        }

        func clearUndoHistory() {
            undoMgr.removeAllActions()
        }

        /// Called by MentionCoordinator via closure
        func commit(_ suggestion: MentionSuggestion) {
            guard isActive else { return }
            let path = suggestion.relativePath
            tokenCounts[path] = (tokenCounts[path] ?? 0) + 1
            fileManager?.selectPath(path, kind: suggestion.kind)
        }

        /// Called by MentionCoordinator via closure
        func tokenRemoved(_ payload: MentionTokenPayload) {
            guard isActive else { return }
            let path = payload.relativePath
            let newCount = max((tokenCounts[path] ?? 1) - 1, 0)
            tokenCounts[path] = newCount
            if newCount == 0 {
                fileManager?.deselectPath(path, kind: payload.kind)
            }
        }

        func updateFileManager(_ manager: WorkspaceFilesViewModel?) {
            fileManager = manager
            mentionCoord?.updateFileManager(manager)
        }

        /// Syncs the internal token-count table with a freshly computed set of counts.
        func setInitialTokenCounts(_ newCounts: [String: Int]) {
            tokenCounts = newCounts
        }

        // MARK: – Internal helper -----------------------------------------

        /// Toggles (checks / un-checks) the file-manager selection for the
        /// given path, correctly handling both files and folders.
        private func toggleModel(for path: String, kind: MentionKind?) {
            guard let fm = parent.fileManager else { return }

            // Prefer explicit kind if supplied, otherwise infer from models.
            let isFolder: Bool = {
                if let k = kind { return k == .folder }
                return fm.findFolderByRelativePath(path) != nil
            }()

            if isFolder {
                if let folderVM = fm.findFolderByRelativePath(path) {
                    fm.toggleFolder(folderVM)
                } else {
                    fm.togglePath(path) // fallback
                }
            } else {
                if let fileVM = fm.findFileByRelativePath(path) {
                    fm.toggleFile(fileVM)
                } else {
                    fm.togglePath(path) // fallback
                }
            }
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
                if !isActiveEditor {
                    (textView as? MentionTextView)?.repairTextKitIfNeeded()
                }
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
        // Custom text system: NSTextStorage + custom LM for rounded-rect draw
        let storage = NSTextStorage()
        let layout = MentionDrawingLayoutManager()
        // Non-contiguous layout can cause scroll bar and display issues on Intel Macs
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        let container = NSTextContainer()
        layout.addTextContainer(container)

        // Give a non-zero initial frame (10x10) so the view is interactive
        let textView = MentionTextView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), textContainer: container)

        // ------------------------------------------------------------------
        // Mention system wiring
        // ------------------------------------------------------------------
        let fileMentionPickerConfiguration = globalSettings.fileMentionPickerConfiguration()
        let svc = MentionSuggestionService(
            fileManager: fileManager,
            configuration: fileMentionPickerConfiguration
        )
        let mc = MentionCoordinator(
            textView: textView,
            suggestionService: svc,
            configuration: fileMentionPickerConfiguration,
            commitHandler: { [weak c = context.coordinator] sugg in
                c?.commit(sugg)
            },
            tokenRemovedHandler: { [weak c = context.coordinator] payload in
                c?.tokenRemoved(payload)
            }
        )
        context.coordinator.mentionCoord = mc
        textView.mentionDelegate = mc

        context.coordinator.mentionTV = textView

        // Sizing flags for interactivity
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 24)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator

        configureTextView(textView)

        // NEW: perform the initial string assignment with a programmatic write guard
        context.coordinator.isApplyingExternalWrite = true
        textView.string = context.coordinator.internalText
        context.coordinator.isApplyingExternalWrite = false

        // Re-hydrate mention attributes only when the initial text contains "@"
        if text.contains("@") {
            applyMentionAttributes(on: textView, coordinator: context.coordinator)
        }

        // Put inside scrollView (same style as TextKitView)
        let scrollView = NSScrollView()

        // Give the documentView an initial frame that matches the scrollView's
        // visible width so the first click focuses correctly but allows the
        // text view to grow in height independently (scrolling kicks in).
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        // Ensure the document view always covers at least the visible height,
        // so clicks on blank padding still hit the text view and focus it.
        ensureDocumentViewFillsVisibleHeight(scrollView, textView: textView)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wrapLines
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false // Transparent background
        scrollView.backgroundColor = .clear

        // Allow the text view to resize horizontally with the scrollView
        // but keep vertical resizing free so scrolling works.
        textView.autoresizingMask = [.width]

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        let fileMentionPickerConfiguration = globalSettings.fileMentionPickerConfiguration()
        context.coordinator.updateFileManager(fileManager)
        context.coordinator.mentionCoord?.updateConfiguration(fileMentionPickerConfiguration)

        // Ensure non-contiguous layout stays disabled (fixes Intel Mac issues)
        if let layoutManager = textView.layoutManager,
           layoutManager.allowsNonContiguousLayout
        {
            layoutManager.allowsNonContiguousLayout = false
        }

        // Sizing flags for interactivity (repeat in case view is recreated)
        textView.isVerticallyResizable = true
        // Keep the doc view at least as tall as the visible area so blank
        // padding is still clickable and focuses the editor.
        let minHeight = max(nsView.contentSize.height, 24)
        if textView.minSize.height != minHeight {
            textView.minSize = NSSize(width: 0, height: minHeight)
        }
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        ensureDocumentViewFillsVisibleHeight(nsView, textView: textView)

        // ------------------------------------------------------------------
        // Font synchronisation
        // ------------------------------------------------------------------
        let desiredFont = resolvedFont
        if textView.font != desiredFont {
            textView.font = desiredFont
            let fullRange = NSRange(location: 0, length: textView.currentStringLength())
            if let layoutManager = textView.layoutManager {
                layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
                layoutManager.invalidateDisplay(forCharacterRange: fullRange)
            }
        }

        // ------------------------------------------------------------------
        // Wrapping / horizontal scrolling – react to run-time changes
        // ------------------------------------------------------------------
        let currentlyWrapped = !textView.isHorizontallyResizable
        if wrapLines != currentlyWrapped {
            if wrapLines {
                textView.isHorizontallyResizable = false
                textView.textContainer?.widthTracksTextView = true
                textView.textContainer?.containerSize = NSSize(
                    width: 0,
                    height: CGFloat.greatestFiniteMagnitude
                )
                nsView.hasHorizontalScroller = false
            } else {
                textView.isHorizontallyResizable = true
                textView.textContainer?.widthTracksTextView = false
                textView.textContainer?.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
                nsView.hasHorizontalScroller = true
            }
        }

        // ------------------------------------------------------------------
        // Keep binding text in sync, without stomping active user edits
        // ------------------------------------------------------------------
        let wasFirstResponder = (textView.window?.firstResponder as? NSTextView) == textView
        let shouldForce = context.coordinator.lastAppliedTick != externalUpdateTick

        if textView.string != text {
            if textView.hasMarkedText() { return }
            if wasFirstResponder, !shouldForce {
                // Do not overwrite while the user is typing; delegate writes to binding.
            } else {
                // Preserve selection, clamp to valid range, then update string
                let previousSelection = textView.clampedSelectedRange()

                // NEW: guard delegate echo while we apply programmatic updates
                (textView as? MentionTextView)?.resetTransientEditingState()
                context.coordinator.performExternalReplacement(in: textView) {
                    context.coordinator.isApplyingExternalWrite = true
                    textView.string = text
                    context.coordinator.internalText = text
                    context.coordinator.isApplyingExternalWrite = false
                }

                textView.setSelectedRange(previousSelection.clamped(to: textView.currentStringLength()))

                // Only auto-scroll if not forcing or not focused
                if !wasFirstResponder || !shouldForce {
                    let endOfText = NSRange(location: textView.currentStringLength(), length: 0)
                    textView.scrollRangeToVisible(endOfText)
                }

                // Re-apply mention attributes if content contains '@'
                if text.contains("@"), !textView.hasMarkedText() {
                    applyMentionAttributes(on: textView, coordinator: context.coordinator)
                }

                if shouldForce {
                    context.coordinator.lastAppliedTick = externalUpdateTick
                    // Sync empty state tracker
                    context.coordinator.wasEmpty = text.isEmpty
                    // Stabilize layout after programmatic text change
                    context.coordinator.scheduleLayoutStabilization(
                        for: textView,
                        expectedIsEmpty: text.isEmpty,
                        reason: .externalWrite
                    )
                }
            }
        }
    }

    // NEW: ensure we unhook delegates and cancel pending tasks
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if let tv = nsView.documentView as? MentionTextView {
            tv.beginTeardown()
            tv.mentionDelegate = nil
            tv.delegate = nil
            tv.isContinuousSpellCheckingEnabled = false
            tv.isAutomaticSpellingCorrectionEnabled = false
        }
        // NEW: cancel any in-flight attribute rehydration
        coordinator.pendingAttrTask?.cancel()
        coordinator.pendingAttrTask = nil
        // NEW: cancel any in-flight layout stabilization
        coordinator.pendingLayoutTask?.cancel()
        coordinator.pendingLayoutTask = nil

        coordinator.clearUndoHistory()
        coordinator.mentionTV = nil
        coordinator.mentionCoord = nil
        coordinator.isActive = false
    }

    // MARK: – helpers

    private func configureTextView(_ tv: NSTextView) {
        tv.isEditable = isEditable
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.backgroundColor = .clear
        tv.drawsBackground = false // Transparent background
        // REMOVED: initial string write (now handled in makeNSView under guard)
        // tv.string               = text
        tv.font = resolvedFont
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.isRichText = false
        tv.smartInsertDeleteEnabled = false
        tv.isContinuousSpellCheckingEnabled = isSpellCheckEnabled
        tv.isAutomaticSpellingCorrectionEnabled = isSpellCheckEnabled

        // Sizing flags for interactivity
        tv.isVerticallyResizable = true
        tv.minSize = NSSize(width: 0, height: 24)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]

        if wrapLines {
            tv.isHorizontallyResizable = false
            tv.textContainer?.widthTracksTextView = true
            tv.textContainer?.containerSize = NSSize(
                width: 0,
                height: CGFloat.greatestFiniteMagnitude
            )
        } else {
            tv.isHorizontallyResizable = true
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }

    /// Ensures the NSTextView (document view) always covers at least the
    /// visible height of the scroll view, so clicking blank padding focuses.
    private func ensureDocumentViewFillsVisibleHeight(
        _ scrollView: NSScrollView,
        textView: NSTextView
    ) {
        let target = max(scrollView.contentSize.height, 24)
        if textView.minSize.height != target {
            textView.minSize = NSSize(width: 0, height: target)
        }
        if textView.frame.height < target {
            var f = textView.frame
            f.size.height = target
            textView.frame = f
        }
    }

    // MARK: – Attribute re-hydration (async)

    private func applyMentionAttributes(
        on tv: NSTextView,
        coordinator: Coordinator
    ) {
        // Capture weak references to avoid retaining views after they disappear
        guard let fm = fileManager else { return }
        guard !tv.hasMarkedText() else { return }
        let plainString = tv.string // immutable snapshot
        guard plainString.contains("@") else { return }
        let fullRange = NSRange(
            location: 0,
            length: (plainString as NSString).length
        )

        // 1. Clear any stale attributes immediately so the UI is up-to-date
        tv.textStorage?.removeAttribute(.mentionToken, range: fullRange)

        // NEW: Cancel any in-flight tagging job before starting a new one
        coordinator.pendingAttrTask?.cancel()
        coordinator.pendingAttrTask = Task.detached(priority: .userInitiated) { [weak tv] in
            // -----------------------------------------------
            // Background work – regex only (no AppKit calls!)
            // -----------------------------------------------
            let matches = await Self.tokenRegex.matches(in: plainString, range: fullRange)
            if Task.isCancelled { return }

            // Extract ranges & raw paths; keeps memory minimal
            var spans: [(NSRange, String)] = []
            spans.reserveCapacity(matches.count)
            let nsText = plainString as NSString
            for m in matches {
                spans.append((m.range, nsText.substring(with: m.range(at: 1))))
            }
            let capturedSpans = spans

            // 3. Hop back to the main actor to touch AppKit & view-models
            await MainActor.run { [weak tv, weak fm] in
                guard
                    let tv,
                    let fm,
                    coordinator.isActive
                else { return }

                // If the text has changed since we computed spans, bail to avoid stale ranges.
                guard tv.string == plainString else { return }
                guard tv.window != nil else { return }
                guard !tv.hasMarkedText() else { return }
                guard
                    let layoutManager = tv.layoutManager,
                    let container = tv.textContainer,
                    layoutManager.textContainers.contains(where: { $0 === container })
                else { return }

                // Batch mutations so AppKit performs a single layout pass
                tv.textStorage?.beginEditing()

                var newCounts: [String: Int] = [:]
                var kindCache: [String: MentionKind?] = [:] // nil == unknown path
                let storageLength = tv.textStorage?.length ?? tv.currentStringLength()

                for (range, rawPath) in capturedSpans {
                    let safeRange = range.clamped(to: storageLength)
                    guard safeRange == range, safeRange.length > 0 else { continue }

                    // Resolve kind only once per distinct path
                    let resolvedKind: MentionKind? = {
                        if let cached = kindCache[rawPath] { return cached }
                        var kind: MentionKind? = nil
                        if fm.findFolderByRelativePath(rawPath) != nil {
                            kind = .folder
                        } else if fm.findFileByRelativePath(rawPath) != nil {
                            kind = .file
                        }
                        kindCache[rawPath] = kind
                        return kind
                    }()

                    // Unknown path ➜ skip tagging
                    guard let kind = resolvedKind else { continue }

                    let payload = MentionTokenPayload(
                        relativePath: rawPath,
                        kind: kind
                    )
                    tv.textStorage?.addAttribute(
                        .mentionToken,
                        value: payload,
                        range: safeRange
                    )
                    newCounts[rawPath, default: 0] += 1
                }

                // Finish batched edits and invalidate layout/display
                // Prefer "invalidate" over "ensureLayout" here to avoid forcing layout
                // during fragile transitions (SwiftUI updates / container churn).
                tv.textStorage?.endEditing()
                if let lm = tv.layoutManager {
                    lm.invalidateLayout(
                        forCharacterRange: fullRange,
                        actualCharacterRange: nil
                    )
                    lm.invalidateDisplay(forCharacterRange: fullRange)
                }

                // 4. Sync counts with coordinator
                coordinator.setInitialTokenCounts(newCounts)
            }
        }
    }
}
