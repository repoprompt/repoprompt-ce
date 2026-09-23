import AppKit
@testable import RepoPromptApp
import SwiftUI
import XCTest

@MainActor
final class ResizableTextFieldTests: XCTestCase {
    func testFocusedEditorRejectsStaleBindingUpdate() {
        XCTAssertFalse(
            CustomTextField.shouldApplyTextSynchronization(
                isFirstResponder: true,
                hasMarkedText: false,
                hasPendingExternalUpdate: false
            )
        )
    }

    func testFocusedEditorAcceptsExplicitExternalUpdate() {
        XCTAssertTrue(
            CustomTextField.shouldApplyTextSynchronization(
                isFirstResponder: true,
                hasMarkedText: false,
                hasPendingExternalUpdate: true
            )
        )
    }

    func testMarkedTextAlwaysRejectsProgrammaticReplacement() {
        XCTAssertFalse(
            CustomTextField.shouldApplyTextSynchronization(
                isFirstResponder: false,
                hasMarkedText: true,
                hasPendingExternalUpdate: true
            )
        )
    }

    func testUnfocusedEditorAcceptsBindingUpdate() {
        XCTAssertTrue(
            CustomTextField.shouldApplyTextSynchronization(
                isFirstResponder: false,
                hasMarkedText: false,
                hasPendingExternalUpdate: false
            )
        )
    }

    func testStaleBindingEchoPreservesNativeTextCaretAndUndo() throws {
        let fixture = try ResizableTextFieldHostingFixture(initialText: "hel")
        defer { fixture.tearDown() }

        fixture.insertNativeText("l")
        XCTAssertEqual(fixture.textView.string, "hell")
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertEqual(fixture.publishedTexts.value.last, "hell")
        XCTAssertTrue(fixture.undoManager.canUndo)

        try fixture.render(bindingText: "hel", externalUpdateTick: 0)
        XCTAssertEqual(fixture.textView.string, "hell")
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertTrue(fixture.undoManager.canUndo)

        fixture.insertNativeText("o")
        XCTAssertEqual(fixture.textView.string, "hello")
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 5, length: 0))

        fixture.undoManager.undo()
        XCTAssertEqual(fixture.textView.string, "hell")
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 4, length: 0))
    }

    func testExplicitExternalRevisionAppliesOnceAndClearsObsoleteUndoHistory() throws {
        let fixture = try ResizableTextFieldHostingFixture(initialText: "newer draft")
        defer { fixture.tearDown() }

        fixture.insertNativeText("!")
        XCTAssertTrue(fixture.undoManager.canUndo)

        let externalText = "restored\nnewer draft!"
        try fixture.render(bindingText: externalText, externalUpdateTick: 1)

        XCTAssertEqual(fixture.textView.string, externalText)
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 12, length: 0))
        XCTAssertEqual(fixture.coordinator.lastAppliedExternalUpdateTick, 1)
        XCTAssertNil(fixture.coordinator.pendingExternalTextUpdate)
        XCTAssertFalse(fixture.undoManager.canUndo)
        XCTAssertFalse(fixture.undoManager.canRedo)

        fixture.textView.setSelectedRange(
            NSRange(location: (externalText as NSString).length, length: 0)
        )
        fixture.insertNativeText("?")
        let nativeText = externalText + "?"
        let nativeCaret = NSRange(location: (nativeText as NSString).length, length: 0)
        XCTAssertEqual(fixture.textView.string, nativeText)
        XCTAssertEqual(fixture.textView.selectedRange(), nativeCaret)
        XCTAssertTrue(fixture.undoManager.canUndo)

        try fixture.render(bindingText: externalText, externalUpdateTick: 1)
        XCTAssertEqual(fixture.textView.string, nativeText)
        XCTAssertEqual(fixture.textView.selectedRange(), nativeCaret)
        XCTAssertEqual(fixture.coordinator.lastAppliedExternalUpdateTick, 1)
        XCTAssertTrue(fixture.undoManager.canUndo)

        fixture.undoManager.undo()
        XCTAssertEqual(fixture.textView.string, externalText)
        XCTAssertEqual(
            fixture.textView.selectedRange(),
            NSRange(location: (externalText as NSString).length, length: 0)
        )
    }

    func testMarkedTextDefersExternalRevisionUntilCompositionEnds() throws {
        let fixture = try ResizableTextFieldHostingFixture(initialText: "draft")
        defer { fixture.tearDown() }

        fixture.beginMarkedText("かな")
        XCTAssertTrue(fixture.textView.hasMarkedText())
        let composedText = fixture.textView.string
        let composedSelection = fixture.textView.selectedRange()
        XCTAssertTrue(fixture.publishedTexts.value.isEmpty)

        try fixture.render(bindingText: "restored draft", externalUpdateTick: 1)
        XCTAssertTrue(fixture.textView.hasMarkedText())
        XCTAssertEqual(fixture.textView.string, composedText)
        XCTAssertEqual(fixture.textView.selectedRange(), composedSelection)
        XCTAssertEqual(fixture.coordinator.lastAppliedExternalUpdateTick, 0)
        XCTAssertEqual(fixture.coordinator.pendingExternalTextUpdate?.text, "restored draft")
        XCTAssertEqual(fixture.coordinator.pendingExternalTextUpdate?.tick, 1)
        XCTAssertTrue(fixture.publishedTexts.value.isEmpty)

        fixture.completeMarkedText()
        XCTAssertFalse(fixture.textView.hasMarkedText())
        XCTAssertEqual(fixture.textView.string, "restored draft")
        XCTAssertEqual(fixture.coordinator.lastAppliedExternalUpdateTick, 1)
        XCTAssertNil(fixture.coordinator.pendingExternalTextUpdate)
        XCTAssertTrue(fixture.publishedTexts.value.isEmpty)
        XCTAssertFalse(fixture.undoManager.canUndo)
        XCTAssertFalse(fixture.undoManager.canRedo)
    }
}

@MainActor
private final class ResizableTextFieldHostingFixture {
    let publishedTexts = ValueBox<[String]>([])
    let textView: ImageAwareTextView
    let coordinator: CustomTextField.Coordinator
    let scrollView: NSScrollView
    let window: NSWindow

    private let boundText: ValueBox<String>
    private let externalUpdateTick: ValueBox<Int>
    private let heightPresetIndex = ValueBox(0)
    private let hostingView: NSHostingView<CustomTextField>
    private var isTornDown = false

    var undoManager: UndoManager {
        coordinator.undoManager(for: textView)!
    }

    init(initialText: String, initialExternalUpdateTick: Int = 0) throws {
        let boundText = ValueBox(initialText)
        let externalUpdateTick = ValueBox(initialExternalUpdateTick)
        self.boundText = boundText
        self.externalUpdateTick = externalUpdateTick

        let hostingView = NSHostingView(
            rootView: Self.makeParent(
                boundText: boundText,
                publishedTexts: publishedTexts,
                heightPresetIndex: heightPresetIndex,
                externalUpdateTick: externalUpdateTick
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        self.hostingView = hostingView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        self.window = window

        Self.flushHostedUpdates(hostingView)
        let scrollView = try XCTUnwrap(Self.hostedScrollViews(in: hostingView).only)
        let textView = try XCTUnwrap(scrollView.documentView as? ImageAwareTextView)
        let coordinator = try XCTUnwrap(textView.delegate as? CustomTextField.Coordinator)
        self.scrollView = scrollView
        self.textView = textView
        self.coordinator = coordinator

        XCTAssertTrue(window.makeFirstResponder(textView))
        XCTAssertTrue(window.firstResponder === textView)
        textView.setSelectedRange(
            NSRange(location: (initialText as NSString).length, length: 0)
        )
        undoManager.groupsByEvent = false
        undoManager.removeAllActions()
    }

    func render(bindingText: String, externalUpdateTick: Int) throws {
        boundText.value = bindingText
        self.externalUpdateTick.value = externalUpdateTick
        hostingView.rootView = Self.makeParent(
            boundText: boundText,
            publishedTexts: publishedTexts,
            heightPresetIndex: heightPresetIndex,
            externalUpdateTick: self.externalUpdateTick
        )
        Self.flushHostedUpdates(hostingView)

        let updatedScrollView = try XCTUnwrap(Self.hostedScrollViews(in: hostingView).only)
        let updatedTextView = try XCTUnwrap(updatedScrollView.documentView as? ImageAwareTextView)
        XCTAssertTrue(updatedScrollView === scrollView)
        XCTAssertTrue(updatedTextView === textView)
        XCTAssertTrue(updatedTextView.delegate === coordinator)
        XCTAssertTrue(window.firstResponder === textView)
    }

    func insertNativeText(_ text: String) {
        suppressAutomaticDelegateDelivery {
            undoManager.beginUndoGrouping()
            textView.insertText(text, replacementRange: textView.selectedRange())
            textView.breakUndoCoalescing()
            undoManager.endUndoGrouping()
        }
        deliverTextDidChange()
    }

    func beginMarkedText(_ text: String) {
        suppressAutomaticDelegateDelivery {
            undoManager.beginUndoGrouping()
            textView.setMarkedText(
                text,
                selectedRange: NSRange(location: (text as NSString).length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            undoManager.endUndoGrouping()
        }
        deliverTextDidChange()
    }

    func completeMarkedText() {
        suppressAutomaticDelegateDelivery {
            textView.unmarkText()
        }
        deliverTextDidChange()
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        CustomTextField.dismantleNSView(scrollView, coordinator: coordinator)
        window.contentView = nil
        window.orderOut(nil)
    }

    private func suppressAutomaticDelegateDelivery(_ operation: () -> Void) {
        coordinator.internalUpdateInProgress = true
        operation()
        coordinator.internalUpdateInProgress = false
    }

    private func deliverTextDidChange() {
        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )
    }

    private static func makeParent(
        boundText: ValueBox<String>,
        publishedTexts: ValueBox<[String]>,
        heightPresetIndex: ValueBox<Int>,
        externalUpdateTick: ValueBox<Int>
    ) -> CustomTextField {
        CustomTextField(
            text: Binding(
                get: { boundText.value },
                set: { publishedTexts.value.append($0) }
            ),
            placeholder: "",
            onReturn: {},
            onImagePaste: nil,
            features: .plain,
            externalUpdateTick: externalUpdateTick.value,
            currentHeightPresetIndex: Binding(
                get: { heightPresetIndex.value },
                set: { heightPresetIndex.value = $0 }
            )
        )
    }

    private static func flushHostedUpdates(_ hostingView: NSHostingView<CustomTextField>) {
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        hostingView.needsDisplay = true
        hostingView.displayIfNeeded()
    }

    private static func hostedScrollViews(in rootView: NSView) -> [NSScrollView] {
        var matches: [NSScrollView] = []
        if let scrollView = rootView as? NSScrollView,
           scrollView.documentView is ImageAwareTextView
        {
            matches.append(scrollView)
        }
        for subview in rootView.subviews {
            matches.append(contentsOf: hostedScrollViews(in: subview))
        }
        return matches
    }
}

private final class ValueBox<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
