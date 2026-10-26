// ResizableTextField.swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum AttachmentPasteboard {
    static let readableTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }

    static func isRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        else { return false }
        return values.isRegularFile == true
    }

    static func isDirectory(_ url: URL) -> Bool {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        else { return false }
        return values.isDirectory == true
    }

    static func regularFileURLs(in pasteboard: NSPasteboard) -> [URL] {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        for item in pasteboard.pasteboardItems ?? [] {
            if let fileURLString = item.string(forType: .fileURL),
               let fileURL = URL(string: fileURLString)
            {
                urls.append(fileURL)
            } else if let fileURLData = item.data(forType: .fileURL),
                      let fileURL = URL(dataRepresentation: fileURLData, relativeTo: nil)
            {
                urls.append(fileURL)
            }
        }
        var seenPaths: Set<String> = []
        return urls
            .map(\.standardizedFileURL)
            .filter { isRegularFile($0) && seenPaths.insert($0.path).inserted }
    }
}

enum ImagePasteboardTypes {
    static let legacyApplePNG = NSPasteboard.PasteboardType("Apple PNG pasteboard type")
    static let legacyNeXTTIFF = NSPasteboard.PasteboardType("NeXT TIFF v4.0 pasteboard type")

    static func canonicalImageType(forIdentifier identifier: String) -> UTType? {
        if let type = UTType(identifier), type.conforms(to: .image) {
            return type
        }
        switch identifier {
        case NSPasteboard.PasteboardType.png.rawValue,
             legacyApplePNG.rawValue:
            return .png
        case NSPasteboard.PasteboardType.tiff.rawValue,
             legacyNeXTTIFF.rawValue:
            return .tiff
        default:
            return nil
        }
    }

    static func isImageLike(_ type: NSPasteboard.PasteboardType) -> Bool {
        if let utType = UTType(type.rawValue), utType.conforms(to: .image) {
            return true
        }
        return type == legacyApplePNG || type == legacyNeXTTIFF
    }
}

final class AttachmentAwareTextView: NSTextView {
    var attachmentPasteHandler: ((NSPasteboard) -> Bool)?
    var enablesAttachmentPasteHandling = false
    var commandReturnHandler: (() -> Bool)?
    var readOnlyReturnHandler: (() -> Void)?
    var beginUserEditingHandler: (() -> Void)?
    private(set) var currentKeyDownEvent: NSEvent?

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if isEditable { beginUserEditingHandler?() }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if isEditable { beginUserEditingHandler?() }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func keyDown(with event: NSEvent) {
        let previousEvent = currentKeyDownEvent
        currentKeyDownEvent = event
        defer { currentKeyDownEvent = previousEvent }
        if handleReadOnlyReturn(event) { return }
        super.keyDown(with: event)
    }

    /// Non-editable NSTextView does not reliably forward insertion commands to its delegate.
    /// Handle only plain Return here; IME, newline and command shortcuts keep native ownership.
    func handleReadOnlyReturn(_ event: NSEvent) -> Bool {
        guard !isEditable, !hasMarkedText(), let readOnlyReturnHandler,
              event.keyCode == 36 || event.keyCode == 76,
              event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty else { return false }
        if !event.isARepeat { readOnlyReturnHandler() }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, isEditable, !hasMarkedText(),
           event.modifierFlags.intersection([.command, .option, .control]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "z"
        {
            beginUserEditingHandler?()
        }
        if Self.isCommandReturn(event), window?.firstResponder === self, isEditable, !hasMarkedText(),
           let commandReturnHandler
        {
            if event.isARepeat || commandReturnHandler() { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    static func isCommandReturn(_ event: NSEvent) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.control)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        guard enablesAttachmentPasteHandling else {
            return types
        }
        for type in AttachmentPasteboard.readableTypes where !types.contains(type) {
            types.append(type)
        }
        return types
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let pasteboard = sender as? NSPasteboard ?? NSPasteboard.general
        if enablesAttachmentPasteHandling, attachmentPasteHandler?(pasteboard) == true {
            return
        }
        super.paste(sender)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard isEditable else { return false }
        if enablesAttachmentPasteHandling,
           isImageLikePasteboardType(type) || type == .fileURL,
           attachmentPasteHandler?(pboard) == true
        {
            return true
        }
        return super.readSelection(from: pboard, type: type)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        let superOperation = super.draggingEntered(sender)
        if superOperation != [] {
            return superOperation
        }
        guard enablesAttachmentPasteHandling else {
            return []
        }
        return canHandleAttachmentDrop(from: sender.draggingPasteboard) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        guard enablesAttachmentPasteHandling else {
            return super.prepareForDragOperation(sender)
        }
        if canHandleAttachmentDrop(from: sender.draggingPasteboard) {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        guard enablesAttachmentPasteHandling else {
            return super.performDragOperation(sender)
        }
        let pasteboard = sender.draggingPasteboard
        guard canHandleAttachmentDrop(from: pasteboard) else {
            return super.performDragOperation(sender)
        }
        _ = attachmentPasteHandler?(pasteboard)
        // Consume attachable drops so file paths are not inserted into the text body.
        return true
    }

    private func canHandleAttachmentDrop(from pasteboard: NSPasteboard) -> Bool {
        if let types = pasteboard.types, types.contains(where: isImageLikePasteboardType) {
            return true
        }
        return !AttachmentPasteboard.regularFileURLs(in: pasteboard).isEmpty
    }

    private func isImageLikePasteboardType(_ type: NSPasteboard.PasteboardType) -> Bool {
        ImagePasteboardTypes.isImageLike(type)
    }
}

struct ResizableTextFieldFeatures {
    var enableFileTagOverlay: Bool = false
    var fileTagStore: WorkspaceFileContextStore?
    var fileTagSearchService: WorkspaceSearchService?
    var fileTagSelectionCoordinator: WorkspaceSelectionCoordinator?
    var fileTagLookupContextIdentity: AnyHashable?
    var fileTagLookupContextProvider: (() async -> WorkspaceLookupContext)?
    var fileTagPickerConfiguration: FileMentionPickerConfiguration = .compact
    var onFileTagCommitted: ((MentionSuggestion) -> Void)?
    var enableSlashSkillOverlay: Bool = false
    var slashSkillSuggestionsProvider: ((String) async -> [MentionSuggestion])?

    static let plain = ResizableTextFieldFeatures()

    static func agentInputBar(
        fileTagStore: WorkspaceFileContextStore?,
        fileTagSearchService: WorkspaceSearchService?,
        fileTagSelectionCoordinator: WorkspaceSelectionCoordinator?,
        fileTagLookupContextIdentity: AnyHashable? = nil,
        fileTagLookupContextProvider: (() async -> WorkspaceLookupContext)? = nil,
        fileMentionPickerConfiguration: FileMentionPickerConfiguration = .compact,
        onFileTagCommitted: ((MentionSuggestion) -> Void)?,
        slashSkillSuggestionsProvider: ((String) async -> [MentionSuggestion])?
    ) -> ResizableTextFieldFeatures {
        ResizableTextFieldFeatures(
            enableFileTagOverlay: true,
            fileTagStore: fileTagStore,
            fileTagSearchService: fileTagSearchService,
            fileTagSelectionCoordinator: fileTagSelectionCoordinator,
            fileTagLookupContextIdentity: fileTagLookupContextIdentity,
            fileTagLookupContextProvider: fileTagLookupContextProvider,
            fileTagPickerConfiguration: fileMentionPickerConfiguration,
            onFileTagCommitted: onFileTagCommitted,
            enableSlashSkillOverlay: true,
            slashSkillSuggestionsProvider: slashSkillSuggestionsProvider
        )
    }
}

struct TextFieldExternalEditTransaction: Equatable {
    let id: UUID
    let isComplete: Bool
}

struct TextFieldExternalEditTakeover {
    let id: UUID
    let revision: Int
}

@MainActor
final class TextFieldNativeEditor {
    struct Snapshot {
        let text: String
        let hasMarkedText: Bool
    }

    private weak var textView: NSTextView?
    private var identity: AnyHashable?

    func snapshot(matching identity: AnyHashable) -> Snapshot? {
        guard self.identity == identity, let textView, textView.window != nil else { return nil }
        return .init(text: textView.string, hasMarkedText: textView.hasMarkedText())
    }

    func attach(_ textView: NSTextView, identity: AnyHashable?) {
        self.textView = textView
        self.identity = identity
    }

    func detach(_ textView: NSTextView) {
        guard self.textView === textView else { return }
        self.textView = nil
        identity = nil
    }
}

struct ResizableTextField: View {
    @Binding var text: String
    let placeholder: String
    var onReturn: () -> Void
    @Binding var resetTrigger: Bool
    var onAttachmentPaste: ((NSPasteboard) -> Bool)?
    var features: ResizableTextFieldFeatures = .plain
    /// Revision for intentional programmatic text changes while the editor is focused.
    var externalUpdateTick: Int? = .none
    var isReadOnly = false
    var externalEditTransaction: TextFieldExternalEditTransaction?
    var onUndoExternalEdit: (() -> Void)?
    /// Checks the live operation against the last yielded ID before native text or IME changes.
    var onBeginUserEditing: ((String, UUID?) -> TextFieldExternalEditTakeover?)?
    var onEscape: (() -> Void)?
    var onCommandReturn: (() -> Bool)?
    var onReadOnlyReturn: (() -> Void)?
    /// Explicit, scoped handoff after a transient composer interaction finishes.
    var focusRestoreRequest: UUID?
    var nativeEditor: TextFieldNativeEditor?
    var nativeEditorIdentity: AnyHashable?

    /// Callback for height changes to coordinate with parent
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// Define height presets at the Normal text-size preset.
    static let heightPresets: [CGFloat] = [36, 52, 68, 84, 100, 116, 132, 148, 164]
    /// Maximum height allowed is the last preset at Normal text size.
    static let maxHeight = heightPresets.last ?? 164

    static func heightPresets(for preset: FontScalePreset) -> [CGFloat] {
        heightPresets.map { preset.scaledMetric($0) }
    }

    static func maxHeight(for preset: FontScalePreset) -> CGFloat {
        heightPresets(for: preset).last ?? preset.scaledMetric(maxHeight)
    }

    static func height(forPresetIndex index: Int, preset: FontScalePreset) -> CGFloat {
        let scaledPresets = heightPresets(for: preset)
        guard !scaledPresets.isEmpty else { return preset.scaledMetric(maxHeight) }
        let clampedIndex = min(max(index, 0), scaledPresets.count - 1)
        return scaledPresets[clampedIndex]
    }

    /// Largest line-fragment count that can still change the chosen height preset.
    /// Drafts taller than this saturate at the last preset, so measuring further is wasted work.
    static var maximumVisibleLineFragmentCount: Int {
        heightPresets.count
    }

    static func presetIndex(
        forVisibleLineFragmentCount lineFragmentCount: Int,
        preset: FontScalePreset
    ) -> Int {
        let normalizedCount = max(1, lineFragmentCount)
        return min(normalizedCount - 1, heightPresets(for: preset).count - 1)
    }

    static func presetIndex(forVisibleLineFragmentCount lineFragmentCount: Int) -> Int {
        presetIndex(forVisibleLineFragmentCount: lineFragmentCount, preset: .normal)
    }

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    @FocusState private var isFocused: Bool
    @State private var currentHeightPresetIndex: Int = 0

    var body: some View {
        CustomTextField(
            text: $text,
            placeholder: placeholder,
            onReturn: onReturn,
            onAttachmentPaste: onAttachmentPaste,
            features: features,
            externalUpdateTick: externalUpdateTick,
            isReadOnly: isReadOnly,
            externalEditTransaction: externalEditTransaction,
            onUndoExternalEdit: onUndoExternalEdit,
            onBeginUserEditing: onBeginUserEditing,
            onEscape: onEscape,
            onCommandReturn: onCommandReturn,
            onReadOnlyReturn: onReadOnlyReturn,
            focusRestoreRequest: focusRestoreRequest,
            nativeEditor: nativeEditor,
            nativeEditorIdentity: nativeEditorIdentity,
            currentHeightPresetIndex: $currentHeightPresetIndex,
            onHeightChange: onHeightChange
        )
        .focused($isFocused)
        .onChange(of: resetTrigger) { _, newValue in
            if newValue {
                reset()
                resetTrigger = false
            }
        }
        .onChange(of: fontPreset) { _, newPreset in
            onHeightChange(Self.height(forPresetIndex: currentHeightPresetIndex, preset: newPreset))
        }
        .onAppear {
            onHeightChange(Self.height(forPresetIndex: currentHeightPresetIndex, preset: fontPreset))
        }
    }

    private func reset() {
        text = ""
        // Reset to the smallest height preset
        currentHeightPresetIndex = 0
        // Notify parent of height change
        onHeightChange(ResizableTextField.height(forPresetIndex: currentHeightPresetIndex, preset: fontPreset))
    }
}

struct CustomTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onReturn: () -> Void
    var onAttachmentPaste: ((NSPasteboard) -> Bool)?
    var features: ResizableTextFieldFeatures = .plain
    var externalUpdateTick: Int? = .none
    var isReadOnly = false
    var externalEditTransaction: TextFieldExternalEditTransaction?
    var onUndoExternalEdit: (() -> Void)?
    /// Checks the live operation against the last yielded ID before native text or IME changes.
    var onBeginUserEditing: ((String, UUID?) -> TextFieldExternalEditTakeover?)?
    var onEscape: (() -> Void)?
    var onCommandReturn: (() -> Bool)?
    var onReadOnlyReturn: (() -> Void)?
    /// Explicit, scoped handoff after a transient composer interaction finishes.
    var focusRestoreRequest: UUID?
    var nativeEditor: TextFieldNativeEditor?
    var nativeEditorIdentity: AnyHashable?
    @Binding var currentHeightPresetIndex: Int

    /// Callback for height changes
    var onHeightChange: (CGFloat) -> Void = { _ in }

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    static func shouldApplyTextSynchronization(
        isFirstResponder: Bool,
        hasMarkedText: Bool,
        hasPendingExternalUpdate: Bool
    ) -> Bool {
        guard !hasMarkedText else { return false }
        return !isFirstResponder || hasPendingExternalUpdate
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = AttachmentAwareTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? AttachmentAwareTextView else {
            return scrollView
        }

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isEditable = !isReadOnly
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.font = fontPreset.nsFont
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 0, height: 6)

        // Plain text config
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        if #available(macOS 13.0, *) {
            textView.isAutomaticDataDetectionEnabled = false
        }
        textView.usesFontPanel = false
        textView.usesRuler = false

        // IME/UI perf tweaks
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.layoutManager?.usesFontLeading = true

        textView.delegate = context.coordinator
        textView.beginUserEditingHandler = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.beginUserEditingIfNeeded(textView: textView)
        }
        textView.commandReturnHandler = isReadOnly ? nil : onCommandReturn
        textView.readOnlyReturnHandler = onReadOnlyReturn
        textView.attachmentPasteHandler = isReadOnly ? nil : onAttachmentPaste
        textView.enablesAttachmentPasteHandling = !isReadOnly && onAttachmentPaste != nil
        context.coordinator.configureFileTagSupport(
            textView: textView,
            enabled: features.enableFileTagOverlay && !isReadOnly,
            store: features.fileTagStore,
            searchService: features.fileTagSearchService,
            selectionCoordinator: features.fileTagSelectionCoordinator,
            lookupContextIdentity: features.fileTagLookupContextIdentity,
            lookupContextProvider: features.fileTagLookupContextProvider,
            configuration: features.fileTagPickerConfiguration
        )
        context.coordinator.configureSlashSkillSupport(
            textView: textView,
            enabled: features.enableSlashSkillOverlay && !isReadOnly,
            suggestionsProvider: features.slashSkillSuggestionsProvider
        )
        textView.string = text
        context.coordinator.lastAppliedExternalUpdateTick = externalUpdateTick
        context.coordinator.clearUndoHistory()
        context.coordinator.nativeEditorIdentity = nativeEditorIdentity
        context.coordinator.connectNativeEditor(textView: textView)

        // Initial height calculation
        Task { @MainActor in
            context.coordinator.updateHeightIfNeeded(textView: textView)
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? AttachmentAwareTextView else { return }
        defer { context.coordinator.connectNativeEditor(textView: textView) }
        textView.isEditable = !isReadOnly
        context.coordinator.restoreFocusIfRequested(textView: textView)
        context.coordinator.beginExternalEditIfNeeded()
        textView.commandReturnHandler = isReadOnly ? nil : onCommandReturn
        textView.readOnlyReturnHandler = onReadOnlyReturn
        textView.attachmentPasteHandler = isReadOnly ? nil : onAttachmentPaste
        textView.enablesAttachmentPasteHandling = !isReadOnly && onAttachmentPaste != nil
        if textView.font != fontPreset.nsFont {
            textView.font = fontPreset.nsFont
            Task { @MainActor in
                context.coordinator.updateHeightIfNeeded(textView: textView)
            }
        }
        context.coordinator.configureFileTagSupport(
            textView: textView,
            enabled: features.enableFileTagOverlay && !isReadOnly,
            store: features.fileTagStore,
            searchService: features.fileTagSearchService,
            selectionCoordinator: features.fileTagSelectionCoordinator,
            lookupContextIdentity: features.fileTagLookupContextIdentity,
            lookupContextProvider: features.fileTagLookupContextProvider,
            configuration: features.fileTagPickerConfiguration
        )
        context.coordinator.configureSlashSkillSupport(
            textView: textView,
            enabled: features.enableSlashSkillOverlay && !isReadOnly,
            suggestionsProvider: features.slashSkillSuggestionsProvider
        )

        if context.coordinator.shouldIgnoreYieldedExternalUpdate(externalUpdateTick) {
            context.coordinator.pendingExternalTextUpdate = nil
            if let externalUpdateTick {
                context.coordinator.lastAppliedExternalUpdateTick = max(context.coordinator.lastAppliedExternalUpdateTick ?? externalUpdateTick, externalUpdateTick)
            }
            return
        }

        var appliedProgrammaticTextChange = false
        let isFirstResponder = (textView.window?.firstResponder as? NSTextView) == textView
        let hasPendingExternalUpdate = externalUpdateTick.map {
            context.coordinator.lastAppliedExternalUpdateTick != $0
        } ?? false
        let isNativeIdentityChanging = context.coordinator.nativeEditorIdentity != nativeEditorIdentity
        if textView.hasMarkedText(), textView.string != text || isNativeIdentityChanging {
            if hasPendingExternalUpdate || isNativeIdentityChanging {
                context.coordinator.pendingExternalTextUpdate = (
                    text: text,
                    tick: externalUpdateTick,
                    identity: nativeEditorIdentity
                )
            }
            return
        }
        // Avoid replacing active user edits with a stale SwiftUI binding snapshot. Explicit
        // external updates are allowed through via externalUpdateTick. Callers that do not
        // opt into revision tracking retain the previous synchronization behavior.
        if textView.string != text {
            let shouldApplyFocusedBindingUpdate = externalUpdateTick == nil || hasPendingExternalUpdate || isNativeIdentityChanging
            guard Self.shouldApplyTextSynchronization(
                isFirstResponder: isFirstResponder,
                hasMarkedText: false,
                hasPendingExternalUpdate: shouldApplyFocusedBindingUpdate
            ) else { return }

            context.coordinator.applyExternalTextReplacement(
                text,
                to: textView,
                externalUpdateTick: externalUpdateTick
            )
            appliedProgrammaticTextChange = true
        } else {
            // Consume an external revision even when the requested text is already installed.
            if let externalUpdateTick {
                context.coordinator.lastAppliedExternalUpdateTick = externalUpdateTick
            }
        }
        context.coordinator.pendingExternalTextUpdate = nil
        context.coordinator.nativeEditorIdentity = nativeEditorIdentity
        context.coordinator.completeExternalEditIfNeeded()
        if appliedProgrammaticTextChange, !isReadOnly {
            context.coordinator.scheduleFileTagSuggestionsRefresh(for: textView, immediate: true)
            context.coordinator.scheduleSlashSkillSuggestionsRefresh(for: textView, immediate: true)
        }
    }

    // NEW: stop callbacks after view is torn down
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        guard let textView = nsView.documentView as? AttachmentAwareTextView else { return }
        textView.delegate = nil
        textView.attachmentPasteHandler = nil
        textView.commandReturnHandler = nil
        textView.readOnlyReturnHandler = nil
        textView.beginUserEditingHandler = nil
        coordinator.connectedNativeEditor?.detach(textView)
        coordinator.focusRestorationTask?.cancel()
        textView.isAutomaticSpellingCorrectionEnabled = false
        coordinator.clearUndoHistory()
        coordinator.dismissFileTagOverlay()
        coordinator.dismissSlashSkillOverlay()
        coordinator.isActive = false
    }

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextField
        var lastFocusRestoreRequest: UUID?
        var focusRestorationTask: Task<Void, Never>?
        weak var connectedNativeEditor: TextFieldNativeEditor?
        var nativeEditorIdentity: AnyHashable?

        func connectNativeEditor(textView: NSTextView) {
            if connectedNativeEditor !== parent.nativeEditor { connectedNativeEditor?.detach(textView) }
            parent.nativeEditor?.attach(textView, identity: nativeEditorIdentity)
            connectedNativeEditor = parent.nativeEditor
        }

        /// Only reclaim abandoned/container focus. Never steal a live sibling field's editor.
        static func mayRestoreFocus(to textView: NSTextView, in window: NSWindow) -> Bool {
            guard window.isKeyWindow else { return false }
            guard let responder = window.firstResponder else { return true }
            if responder === window || responder === textView { return true }
            guard let view = responder as? NSView else { return false }
            if view.window !== window || textView.isDescendant(of: view) { return true }
            if let fieldEditor = view as? NSTextView, fieldEditor.isFieldEditor,
               let owner = fieldEditor.delegate as? NSView
            {
                return owner.window !== window
            }
            return false
        }

        func restoreFocusIfRequested(textView: NSTextView) {
            let request = parent.focusRestoreRequest
            guard request != lastFocusRestoreRequest else { return }
            lastFocusRestoreRequest = request
            focusRestorationTask?.cancel()
            focusRestorationTask = nil
            guard let request else { return }
            focusRestorationTask = Task { @MainActor [weak self, weak textView] in
                await Task.yield()
                guard let self, let textView, !Task.isCancelled, isActive,
                      parent.focusRestoreRequest == request, let window = textView.window,
                      Self.mayRestoreFocus(to: textView, in: window) else { return }
                window.makeFirstResponder(textView)
            }
        }

        var internalUpdateInProgress = false
        var lastReportedHeight: CGFloat?
        var lastAppliedExternalUpdateTick: Int?
        var pendingExternalTextUpdate: (text: String, tick: Int?, identity: AnyHashable?)?

        private let textViewUndoManager = UndoManager()
        private var externalEditID: UUID?
        private var externalEditUndoRegistered = false
        private var yieldedExternalEditID: UUID?
        private var yieldedExternalUpdateThroughTick: Int?
        private let fileTagHelper = FileTagMentionHelper()
        private let slashSkillHelper = SlashSkillMentionHelper()
        // NEW: mark inactive after dismantle
        var isActive: Bool = true

        init(_ parent: CustomTextField) {
            self.parent = parent
        }

        func shouldIgnoreYieldedExternalUpdate(_ tick: Int?) -> Bool {
            guard let tick, let yieldedExternalUpdateThroughTick else { return false }
            return tick <= yieldedExternalUpdateThroughTick
        }

        func beginUserEditingIfNeeded(textView: NSTextView) {
            guard isActive, !internalUpdateInProgress, !parent.isReadOnly,
                  nativeEditorIdentity == parent.nativeEditorIdentity,
                  let onBeginUserEditing = parent.onBeginUserEditing,
                  let takeover = onBeginUserEditing(textView.string, yieldedExternalEditID) else { return }
            beginExternalEditIfNeeded()
            yieldedExternalEditID = takeover.id
            yieldedExternalUpdateThroughTick = takeover.revision
            pendingExternalTextUpdate = nil
            if parent.externalEditTransaction?.id == takeover.id {
                registerExternalEditUndoIfNeeded()
            } else {
                externalEditUndoRegistered = true
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if !internalUpdateInProgress { beginUserEditingIfNeeded(textView: textView) }
            return true
        }

        func textDidChange(_ notification: Notification) {
            if internalUpdateInProgress { return }
            guard isActive, let textView = notification.object as? NSTextView else { return }

            if textView.hasMarkedText() {
                // Let the input method finish composing before reflecting text into SwiftUI.
                // This prevents a stale binding snapshot from being fed back into the editor.
                updateHeightIfNeeded(textView: textView)
                return
            }

            if let pendingExternalTextUpdate {
                self.pendingExternalTextUpdate = nil
                if textView.string != pendingExternalTextUpdate.text {
                    applyExternalTextReplacement(
                        pendingExternalTextUpdate.text,
                        to: textView,
                        externalUpdateTick: pendingExternalTextUpdate.tick
                    )
                } else {
                    lastAppliedExternalUpdateTick = pendingExternalTextUpdate.tick
                }
                nativeEditorIdentity = pendingExternalTextUpdate.identity
                connectNativeEditor(textView: textView)
            } else {
                parent.text = textView.string
            }

            updateHeightIfNeeded(textView: textView)
            scheduleFileTagSuggestionsRefresh(for: textView, immediate: false)
            scheduleSlashSkillSuggestionsRefresh(for: textView, immediate: false)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard isActive else { return }
            dismissFileTagOverlay()
            dismissSlashSkillOverlay()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard isActive, let textView = notification.object as? NSTextView else { return }
            // Selection changes fire frequently while typing; debounce to avoid duplicate
            // refreshes alongside textDidChange.
            scheduleFileTagSuggestionsRefresh(for: textView, immediate: false)
            scheduleSlashSkillSuggestionsRefresh(for: textView, immediate: false)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // AppKit can deliver a command while the window still reports a KitDefined event.
            // Key-only accessors such as isARepeat raise an Objective-C exception for that event.
            let currentEvent = (textView as? AttachmentAwareTextView)?.currentKeyDownEvent ?? textView.window?.currentEvent
            let event = currentEvent?.type == .keyDown ? currentEvent : nil
            if parent.isReadOnly, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape?()
                return true
            }
            if parent.isReadOnly {
                // Preparation locks editing, not the composer's explicit Return override.
                let flags = event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
                if commandSelector == #selector(NSResponder.insertNewline(_:)),
                   !textView.hasMarkedText(), isActive,
                   flags.intersection([.shift, .command, .option, .control]).isEmpty,
                   let onReturn = parent.onReadOnlyReturn
                {
                    if event?.isARepeat != true { onReturn() }
                    return true
                }
                return false
            }
            // IME FIX: if composing, let IME handle keys (Return/space/numbers etc.)
            if textView.hasMarkedText() { return false }
            guard isActive else { return false }
            if slashSkillHelper.handleCommandIfNeeded(
                textView: textView,
                commandSelector: commandSelector,
                enabled: parent.features.enableSlashSkillOverlay
            ) {
                return true
            }
            if fileTagHelper.handleCommandIfNeeded(
                textView: textView,
                commandSelector: commandSelector,
                enabled: parent.features.enableFileTagOverlay,
                onCommit: parent.features.onFileTagCommitted
            ) {
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)), let onEscape = parent.onEscape {
                onEscape()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let flags = event?.modifierFlags.intersection([.shift, .command, .option, .control]) ?? []
                if flags == .shift {
                    textView.insertNewline(nil) // Shift+Return → newline
                } else if flags == .command, let action = parent.onCommandReturn {
                    if event?.isARepeat == true { return true }
                    return action()
                } else if flags.isEmpty {
                    // A held Return is not an explicit second press/submit.
                    if event?.isARepeat != true {
                        parent.text = textView.string
                        parent.onReturn()
                    }
                } else { return false }
                return true
            }
            // Some keyboards/IMEs use insertLineBreak for Shift+Return; let it fall through to newline.
            if commandSelector == #selector(NSResponder.insertLineBreak(_:)) { return false }
            if commandSelector == #selector(NSText.paste(_:)) {
                if let imageAwareTextView = textView as? AttachmentAwareTextView {
                    return imageAwareTextView.attachmentPasteHandler?(NSPasteboard.general) == true
                }
                return parent.onAttachmentPaste?(NSPasteboard.general) == true
            }
            return false
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            textViewUndoManager
        }

        func applyExternalTextReplacement(
            _ text: String,
            to textView: NSTextView,
            externalUpdateTick: Int?
        ) {
            internalUpdateInProgress = true

            let previousSelection = textView.selectedRange()
            performExternalReplacement(in: textView) {
                textView.string = text
            }
            let nsLength = (text as NSString).length
            let clampedLocation = min(max(previousSelection.location, 0), nsLength)
            let maxLengthFromLocation = max(0, nsLength - clampedLocation)
            let clampedLength = min(max(previousSelection.length, 0), maxLengthFromLocation)
            textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))

            internalUpdateInProgress = false
            if let externalUpdateTick {
                lastAppliedExternalUpdateTick = externalUpdateTick
            }
            updateHeightIfNeeded(textView: textView)
        }

        private func performExternalReplacement(
            in textView: NSTextView,
            mutation: () -> Void
        ) {
            if parent.externalEditTransaction != nil {
                textViewUndoManager.disableUndoRegistration()
                mutation()
                textViewUndoManager.enableUndoRegistration()
            } else {
                TextViewUndoSafeReplacement.perform(in: textView, undoManager: textViewUndoManager, mutation: mutation)
            }
        }

        func beginExternalEditIfNeeded() {
            let id = parent.externalEditTransaction?.id
            guard id != externalEditID else { return }
            if let id, id == yieldedExternalEditID {
                externalEditID = id
                return
            }
            if id != nil, !textViewUndoManager.isUndoing, !textViewUndoManager.isRedoing {
                textViewUndoManager.removeAllActions()
            }
            externalEditID = id
            externalEditUndoRegistered = false
            yieldedExternalEditID = nil
            yieldedExternalUpdateThroughTick = nil
        }

        func completeExternalEditIfNeeded() {
            guard parent.externalEditTransaction?.isComplete == true else { return }
            registerExternalEditUndoIfNeeded()
        }

        private func registerExternalEditUndoIfNeeded() {
            guard parent.externalEditTransaction != nil, !externalEditUndoRegistered else { return }
            externalEditUndoRegistered = true
            let undo = parent.onUndoExternalEdit
            let ownsUndoGroup = textViewUndoManager.groupingLevel == 0
            if ownsUndoGroup { textViewUndoManager.beginUndoGrouping() }
            textViewUndoManager.registerUndo(withTarget: self) { _ in undo?() }
            textViewUndoManager.setActionName("Re-prompt")
            if ownsUndoGroup { textViewUndoManager.endUndoGrouping() }
            // An explicit group can leave the implicit event group open. Split that outer group
            // after the rewrite, then leave a fresh event group for native typing registration.
            // Do not toggle groupsByEvent or close explicitly nested/undo/redo-owned groups.
            if textViewUndoManager.groupsByEvent, textViewUndoManager.groupingLevel == 1,
               !textViewUndoManager.isUndoing, !textViewUndoManager.isRedoing
            {
                textViewUndoManager.endUndoGrouping()
                textViewUndoManager.beginUndoGrouping()
            }
        }

        func clearUndoHistory() {
            textViewUndoManager.removeAllActions()
        }

        func updateHeightIfNeeded(textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            let visibleLineFragmentCount = ComposerLineFragmentCounter.visibleLineFragmentCount(
                layoutManager: layoutManager,
                textContainer: textContainer,
                maximumCountOfInterest: ResizableTextField.maximumVisibleLineFragmentCount
            )
            let index = ResizableTextField.presetIndex(
                forVisibleLineFragmentCount: visibleLineFragmentCount,
                preset: parent.fontPreset
            )
            let newHeight = ResizableTextField.height(forPresetIndex: index, preset: parent.fontPreset)

            if index != parent.currentHeightPresetIndex || lastReportedHeight.map({ abs($0 - newHeight) >= 0.5 }) != false {
                parent.currentHeightPresetIndex = index
                lastReportedHeight = newHeight
                parent.onHeightChange(newHeight)
            }
        }

        func configureFileTagSupport(
            textView: AttachmentAwareTextView,
            enabled: Bool,
            store: WorkspaceFileContextStore?,
            searchService: WorkspaceSearchService?,
            selectionCoordinator: WorkspaceSelectionCoordinator?,
            lookupContextIdentity: AnyHashable?,
            lookupContextProvider: (() async -> WorkspaceLookupContext)?,
            configuration: FileMentionPickerConfiguration
        ) {
            fileTagHelper.configure(
                textView: textView,
                enabled: enabled,
                store: store,
                searchService: searchService,
                selectionCoordinator: selectionCoordinator,
                lookupContextIdentity: lookupContextIdentity,
                lookupContextProvider: lookupContextProvider,
                configuration: configuration
            )
        }

        func scheduleFileTagSuggestionsRefresh(for textView: NSTextView, immediate: Bool) {
            fileTagHelper.scheduleRefresh(
                for: textView,
                immediate: immediate,
                enabled: parent.features.enableFileTagOverlay,
                isActive: isActive
            )
        }

        func dismissFileTagOverlay() {
            fileTagHelper.dismiss()
        }

        func configureSlashSkillSupport(
            textView: AttachmentAwareTextView,
            enabled: Bool,
            suggestionsProvider: ((String) async -> [MentionSuggestion])?
        ) {
            slashSkillHelper.configure(
                textView: textView,
                enabled: enabled,
                suggestionsProvider: suggestionsProvider
            )
        }

        func scheduleSlashSkillSuggestionsRefresh(for textView: NSTextView, immediate: Bool) {
            slashSkillHelper.scheduleRefresh(
                for: textView,
                immediate: immediate,
                enabled: parent.features.enableSlashSkillOverlay,
                isActive: isActive
            )
        }

        func dismissSlashSkillOverlay() {
            slashSkillHelper.dismiss()
        }
    }
}

/// Counts composer line fragments for height-preset selection.
///
/// The composer stops growing at `ResizableTextField.maximumVisibleLineFragmentCount` fragments, so
/// once that many fragments are proven to exist the exact total cannot change the chosen preset.
/// Measuring a saturated draft therefore lays out and enumerates only the leading fragments instead
/// of the whole document on every keystroke. Shorter drafts keep the exact full-container
/// measurement, so their height behavior is unchanged.
enum ComposerLineFragmentCounter {
    static func visibleLineFragmentCount(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        maximumCountOfInterest: Int
    ) -> Int {
        if maximumCountOfInterest > 0,
           isSaturated(
               layoutManager: layoutManager,
               textContainer: textContainer,
               maximumCountOfInterest: maximumCountOfInterest
           )
        {
            return maximumCountOfInterest
        }
        return exactVisibleLineFragmentCount(
            layoutManager: layoutManager,
            textContainer: textContainer
        )
    }

    /// Exact measurement over the fully laid out container, including the trailing empty line
    /// fragment. Only reached for drafts that are shorter than the largest height preset, or when
    /// the bounded probe could not prove saturation.
    static func exactVisibleLineFragmentCount(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> Int {
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var count = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
            count += 1
        }
        if layoutManager.extraLineFragmentTextContainer === textContainer,
           !layoutManager.extraLineFragmentRect.isEmpty
        {
            count += 1
        }
        return count
    }

    /// Reports whether at least `maximumCountOfInterest` line fragments exist, laying out only the
    /// glyphs inside a bounded probe rect rather than the entire document.
    private static func isSaturated(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        maximumCountOfInterest: Int
    ) -> Bool {
        let probeRect = probeBoundingRect(
            layoutManager: layoutManager,
            textContainer: textContainer,
            maximumCountOfInterest: maximumCountOfInterest
        )
        guard probeRect.width > 0, probeRect.height > 0 else { return false }
        let probedGlyphRange = layoutManager.glyphRange(forBoundingRect: probeRect, in: textContainer)
        guard probedGlyphRange.length > 0 else { return false }

        var count = 0
        layoutManager.enumerateLineFragments(forGlyphRange: probedGlyphRange) { _, _, _, _, stop in
            count += 1
            if count >= maximumCountOfInterest {
                stop.pointee = true
            }
        }
        return count >= maximumCountOfInterest
    }

    /// Probe rect tall enough to hold the saturating fragment count at twice the default line
    /// height. When content uses taller fragments the probe simply fails to prove saturation and
    /// the caller falls back to the exact measurement, so height behavior stays correct.
    private static func probeBoundingRect(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        maximumCountOfInterest: Int
    ) -> CGRect {
        let font = textContainer.textView?.font
            ?? layoutManager.firstTextView?.font
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = max(layoutManager.defaultLineHeight(for: font), 1)
        let probeHeight = lineHeight * CGFloat(maximumCountOfInterest) * 2
        return CGRect(x: 0, y: 0, width: textContainer.size.width, height: probeHeight)
    }
}
