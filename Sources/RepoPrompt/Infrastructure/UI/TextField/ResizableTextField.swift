// ResizableTextField.swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ImagePasteboardTypes {
    static let legacyApplePNG = NSPasteboard.PasteboardType("Apple PNG pasteboard type")
    static let legacyNeXTTIFF = NSPasteboard.PasteboardType("NeXT TIFF v4.0 pasteboard type")

    static let explicitImageReadableTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType(UTType.image.identifier),
        NSPasteboard.PasteboardType(UTType.png.identifier),
        NSPasteboard.PasteboardType(UTType.tiff.identifier),
        legacyApplePNG,
        legacyNeXTTIFF
    ]

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

final class ImageAwareTextView: NSTextView {
    var imagePasteHandler: ((NSPasteboard) -> Bool)?
    var enablesImagePasteHandling = false

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        guard enablesImagePasteHandling else {
            return types
        }
        for type in ImagePasteboardTypes.explicitImageReadableTypes where !types.contains(type) {
            types.append(type)
        }
        return types
    }

    override func paste(_ sender: Any?) {
        let pasteboard = sender as? NSPasteboard ?? NSPasteboard.general
        if enablesImagePasteHandling, imagePasteHandler?(pasteboard) == true {
            return
        }
        super.paste(sender)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if enablesImagePasteHandling,
           isImageLikePasteboardType(type),
           imagePasteHandler?(pboard) == true
        {
            return true
        }
        return super.readSelection(from: pboard, type: type)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let superOperation = super.draggingEntered(sender)
        if superOperation != [] {
            return superOperation
        }
        guard enablesImagePasteHandling else {
            return []
        }
        return canHandleImageDrop(from: sender.draggingPasteboard) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard enablesImagePasteHandling else {
            return super.prepareForDragOperation(sender)
        }
        if canHandleImageDrop(from: sender.draggingPasteboard) {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard enablesImagePasteHandling else {
            return super.performDragOperation(sender)
        }
        let pasteboard = sender.draggingPasteboard
        guard canHandleImageDrop(from: pasteboard) else {
            return super.performDragOperation(sender)
        }
        _ = imagePasteHandler?(pasteboard)
        // Consume image-like drops so file paths are not inserted into the text body.
        return true
    }

    private func canHandleImageDrop(from pasteboard: NSPasteboard) -> Bool {
        if let types = pasteboard.types {
            for type in types where isImageLikePasteboardType(type) {
                return true
            }
        }

        if let urlObjects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urlObjects where url.isFileURL {
                if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
                   contentType.conforms(to: .image)
                {
                    return true
                }
                if let extType = UTType(filenameExtension: url.pathExtension), extType.conforms(to: .image) {
                    return true
                }
            }
        }

        return false
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

struct ResizableTextField: View {
    @Binding var text: String
    let placeholder: String
    var onReturn: () -> Void
    @Binding var resetTrigger: Bool
    var onImagePaste: ((NSPasteboard) -> Bool)?
    var features: ResizableTextFieldFeatures = .plain

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
            onImagePaste: onImagePaste,
            features: features,
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
    var onImagePaste: ((NSPasteboard) -> Bool)?
    var features: ResizableTextFieldFeatures = .plain
    @Binding var currentHeightPresetIndex: Int

    /// Callback for height changes
    var onHeightChange: (CGFloat) -> Void = { _ in }

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ImageAwareTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? ImageAwareTextView else {
            return scrollView
        }

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
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
        textView.imagePasteHandler = onImagePaste
        textView.enablesImagePasteHandling = onImagePaste != nil
        context.coordinator.configureFileTagSupport(
            textView: textView,
            enabled: features.enableFileTagOverlay,
            store: features.fileTagStore,
            searchService: features.fileTagSearchService,
            selectionCoordinator: features.fileTagSelectionCoordinator,
            lookupContextIdentity: features.fileTagLookupContextIdentity,
            lookupContextProvider: features.fileTagLookupContextProvider,
            configuration: features.fileTagPickerConfiguration
        )
        context.coordinator.configureSlashSkillSupport(
            textView: textView,
            enabled: features.enableSlashSkillOverlay,
            suggestionsProvider: features.slashSkillSuggestionsProvider
        )
        textView.string = text
        context.coordinator.clearUndoHistory()

        // Initial height calculation
        Task { @MainActor in
            context.coordinator.updateHeightIfNeeded(textView: textView)
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? ImageAwareTextView else { return }
        textView.imagePasteHandler = onImagePaste
        textView.enablesImagePasteHandling = onImagePaste != nil
        if textView.font != fontPreset.nsFont {
            textView.font = fontPreset.nsFont
            Task { @MainActor in
                context.coordinator.updateHeightIfNeeded(textView: textView)
            }
        }
        context.coordinator.configureFileTagSupport(
            textView: textView,
            enabled: features.enableFileTagOverlay,
            store: features.fileTagStore,
            searchService: features.fileTagSearchService,
            selectionCoordinator: features.fileTagSelectionCoordinator,
            lookupContextIdentity: features.fileTagLookupContextIdentity,
            lookupContextProvider: features.fileTagLookupContextProvider,
            configuration: features.fileTagPickerConfiguration
        )
        context.coordinator.configureSlashSkillSupport(
            textView: textView,
            enabled: features.enableSlashSkillOverlay,
            suggestionsProvider: features.slashSkillSuggestionsProvider
        )

        var appliedProgrammaticTextChange = false
        // IME FIX: Avoid stomping marked text (composition) with programmatic writes.
        if textView.string != text {
            // If an IME composition is active, DO NOT overwrite.
            if textView.hasMarkedText() { return }

            context.coordinator.internalUpdateInProgress = true

            // Preserve selection when applying programmatic changes.
            let prevSel = textView.selectedRange()
            context.coordinator.performExternalReplacement(in: textView) {
                textView.string = text
            }
            let nsLen = (text as NSString).length
            let clampedLoc = min(max(prevSel.location, 0), nsLen)
            let maxLenFromLoc = max(0, nsLen - clampedLoc)
            let clampedLen = min(max(prevSel.length, 0), maxLenFromLoc)
            textView.setSelectedRange(NSRange(location: clampedLoc, length: clampedLen))

            context.coordinator.internalUpdateInProgress = false
            appliedProgrammaticTextChange = true

            Task { @MainActor in
                context.coordinator.updateHeightIfNeeded(textView: textView)
            }
        }
        if appliedProgrammaticTextChange {
            context.coordinator.scheduleFileTagSuggestionsRefresh(for: textView, immediate: true)
            context.coordinator.scheduleSlashSkillSuggestionsRefresh(for: textView, immediate: true)
        }
    }

    // NEW: stop callbacks after view is torn down
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        guard let textView = nsView.documentView as? ImageAwareTextView else { return }
        textView.delegate = nil
        textView.imagePasteHandler = nil
        textView.isAutomaticSpellingCorrectionEnabled = false
        coordinator.clearUndoHistory()
        coordinator.dismissFileTagOverlay()
        coordinator.dismissSlashSkillOverlay()
        coordinator.isActive = false
    }

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextField
        var internalUpdateInProgress = false
        var lastReportedHeight: CGFloat?

        private let textViewUndoManager = UndoManager()
        private let fileTagHelper = FileTagMentionHelper()
        private let slashSkillHelper = SlashSkillMentionHelper()
        // NEW: mark inactive after dismantle
        var isActive: Bool = true

        init(_ parent: CustomTextField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            if internalUpdateInProgress { return }
            guard isActive, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string

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
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Use the *current* event to read modifier flags (more reliable)
                let flags = textView.window?.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) {
                    textView.insertNewline(nil) // Shift+Return → newline
                } else {
                    parent.onReturn() // Plain Return → send
                }
                return true
            }
            // Some keyboards/IMEs use insertLineBreak for Shift+Return; let it fall through to newline.
            if commandSelector == #selector(NSResponder.insertLineBreak(_:)) { return false }
            if commandSelector == #selector(NSText.paste(_:)) {
                if let imageAwareTextView = textView as? ImageAwareTextView {
                    return imageAwareTextView.imagePasteHandler?(NSPasteboard.general) == true
                }
                return parent.onImagePaste?(NSPasteboard.general) == true
            }
            return false
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

        func updateHeightIfNeeded(textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            layoutManager.ensureLayout(for: textContainer)
            let glyphRange = layoutManager.glyphRange(for: textContainer)
            var visibleLineFragmentCount = 0
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
                visibleLineFragmentCount += 1
            }
            if layoutManager.extraLineFragmentTextContainer === textContainer,
               !layoutManager.extraLineFragmentRect.isEmpty
            {
                visibleLineFragmentCount += 1
            }
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
            textView: ImageAwareTextView,
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
            textView: ImageAwareTextView,
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
