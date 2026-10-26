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

    func testNativeEditTakesOverStreamingTransactionBeforeMutationAndRejectsQueuedChunks() throws {
        let transaction = TextFieldExternalEditTransaction(id: UUID(), isComplete: false)
        var takeoverTexts: [String] = []
        let fixture = try ResizableTextFieldHostingFixture(
            initialText: "Rewritten draft",
            initialExternalEditTransaction: transaction,
            onBeginUserEditing: { text, yieldedID in
                guard yieldedID != transaction.id else { return nil }
                takeoverTexts.append(text)
                return .init(id: transaction.id, revision: 2)
            }
        )
        defer { fixture.tearDown() }

        fixture.insertNativeText("!")
        XCTAssertEqual(takeoverTexts, ["Rewritten draft"])
        XCTAssertEqual(fixture.textView.string, "Rewritten draft!")
        let selection = fixture.textView.selectedRange()

        try fixture.render(bindingText: "Queued model chunk", externalUpdateTick: 1, externalEditTransaction: transaction)
        XCTAssertEqual(fixture.textView.string, "Rewritten draft!")
        XCTAssertEqual(fixture.textView.selectedRange(), selection)
        try fixture.render(
            bindingText: "Queued final rewrite",
            externalUpdateTick: 2,
            externalEditTransaction: .init(id: transaction.id, isComplete: true)
        )
        XCTAssertEqual(fixture.textView.string, "Rewritten draft!")

        fixture.insertNativeText("?")
        XCTAssertEqual(takeoverTexts, ["Rewritten draft"], "Ownership is surrendered once per rewrite, before the first native edit")
        XCTAssertEqual(fixture.textView.string, "Rewritten draft!?")
        try fixture.render(bindingText: "Restored previous send", externalUpdateTick: 3, externalEditTransaction: .init(id: transaction.id, isComplete: true))
        XCTAssertEqual(fixture.textView.string, "Restored previous send", "A later explicit restoration must not be mistaken for an already queued model chunk")
        try fixture.render(bindingText: "Original restored", externalUpdateTick: 4, externalEditTransaction: .init(id: UUID(), isComplete: true))
        XCTAssertEqual(fixture.textView.string, "Original restored", "An explicit new transaction must still restore or replace the draft")
    }

    func testMarkedTextTakesOverCompletedRewriteBeforeCompositionAndRejectsLatePublication() throws {
        let transaction = TextFieldExternalEditTransaction(id: UUID(), isComplete: true)
        var takeoverTexts: [String] = []
        let fixture = try ResizableTextFieldHostingFixture(
            initialText: "draft",
            initialExternalEditTransaction: transaction,
            onBeginUserEditing: { text, yieldedID in
                guard yieldedID != transaction.id else { return nil }
                takeoverTexts.append(text)
                return .init(id: transaction.id, revision: 2)
            }
        )
        defer { fixture.tearDown() }

        fixture.coordinator.pendingExternalTextUpdate = (text: "Earlier pending rewrite", tick: 1, identity: nil)
        fixture.beginMarkedText("かな")
        XCTAssertEqual(takeoverTexts, ["draft"], "Auto-send and publishing must be fenced before IME composition mutates the native draft")
        XCTAssertNil(fixture.coordinator.pendingExternalTextUpdate)
        XCTAssertTrue(fixture.textView.hasMarkedText())
        let composedText = fixture.textView.string
        let selection = fixture.textView.selectedRange()

        try fixture.render(bindingText: "Late generated rewrite", externalUpdateTick: 2, externalEditTransaction: transaction)
        XCTAssertEqual(fixture.textView.string, composedText)
        XCTAssertEqual(fixture.textView.selectedRange(), selection)
        XCTAssertTrue(fixture.textView.hasMarkedText())
        XCTAssertNil(fixture.coordinator.pendingExternalTextUpdate)

        fixture.completeMarkedText()
        XCTAssertFalse(fixture.textView.hasMarkedText())
        XCTAssertEqual(fixture.textView.string, composedText)
        XCTAssertEqual(fixture.publishedTexts.value.last, composedText)
        XCTAssertEqual(takeoverTexts, ["draft"])
        XCTAssertTrue(fixture.window.firstResponder === fixture.textView)
    }

    func testMarkedTextCanTakeOverBeforeTheNewRewritePresentationRenders() throws {
        let operationID = UUID()
        var takeoverTexts: [String] = []
        let fixture = try ResizableTextFieldHostingFixture(
            initialText: "Original",
            onBeginUserEditing: { text, yieldedID in
                guard yieldedID != operationID else { return nil }
                takeoverTexts.append(text)
                return .init(id: operationID, revision: 1)
            }
        )
        defer { fixture.tearDown() }

        fixture.beginMarkedText("かな")
        let composedText = fixture.textView.string
        XCTAssertEqual(takeoverTexts, ["Original"])
        try fixture.render(
            bindingText: "First model chunk",
            externalUpdateTick: 1,
            externalEditTransaction: .init(id: operationID, isComplete: true)
        )
        XCTAssertTrue(fixture.textView.hasMarkedText())
        XCTAssertEqual(fixture.textView.string, composedText)
        XCTAssertNil(fixture.coordinator.pendingExternalTextUpdate)
        fixture.completeMarkedText()
        XCTAssertEqual(fixture.publishedTexts.value.last, composedText)
        XCTAssertEqual(fixture.textView.string, composedText)
        XCTAssertTrue(fixture.undoManager.canUndo, "Rendering the already-yielded operation must preserve native composition undo")
    }

    func testMarkedTextCanTakeOverNewRewriteBeforePreviousPresentationUpdates() throws {
        let oldTransaction = TextFieldExternalEditTransaction(id: UUID(), isComplete: true)
        var liveOperationID = oldTransaction.id
        var takeoverTexts: [String] = []
        let fixture = try ResizableTextFieldHostingFixture(
            initialText: "Rewrite",
            initialExternalEditTransaction: oldTransaction,
            onBeginUserEditing: { text, yieldedID in
                guard yieldedID != liveOperationID else { return nil }
                takeoverTexts.append(text)
                return .init(id: liveOperationID, revision: 2)
            }
        )
        defer { fixture.tearDown() }

        fixture.insertNativeText("!")
        liveOperationID = UUID()
        fixture.beginMarkedText("かな")
        let composedText = fixture.textView.string
        XCTAssertEqual(takeoverTexts, ["Rewrite", "Rewrite!"])

        try fixture.render(bindingText: "Stale old rewrite", externalUpdateTick: 1, externalEditTransaction: oldTransaction)
        XCTAssertTrue(fixture.textView.hasMarkedText())
        XCTAssertEqual(fixture.textView.string, composedText)
        XCTAssertNil(fixture.coordinator.pendingExternalTextUpdate)
        try fixture.render(
            bindingText: "Queued new rewrite", externalUpdateTick: 2,
            externalEditTransaction: .init(id: liveOperationID, isComplete: true)
        )
        XCTAssertTrue(fixture.textView.hasMarkedText())
        XCTAssertEqual(fixture.textView.string, composedText)
        XCTAssertNil(fixture.coordinator.pendingExternalTextUpdate)
        fixture.completeMarkedText()
        XCTAssertEqual(fixture.publishedTexts.value.last, composedText)
        XCTAssertEqual(takeoverTexts, ["Rewrite", "Rewrite!"])
    }

    func testTakingOverStreamingKeepsTypedEditUndoSeparateFromRewriteUndo() throws {
        for hasOpenEventGroup in [false, true] {
            let transaction = TextFieldExternalEditTransaction(id: UUID(), isComplete: false)
            var rewriteUndos = 0
            let fixture = try ResizableTextFieldHostingFixture(
                initialText: "Rewrite",
                initialExternalEditTransaction: transaction,
                onBeginUserEditing: { _, yieldedID in
                    yieldedID == transaction.id ? nil : .init(id: transaction.id, revision: 0)
                }
            )
            defer { fixture.tearDown() }
            fixture.coordinator.parent.onUndoExternalEdit = { rewriteUndos += 1 }
            fixture.undoManager.groupsByEvent = true
            if hasOpenEventGroup {
                fixture.undoManager.registerUndo(withTarget: fixture) { _ in }
                XCTAssertEqual(fixture.undoManager.groupingLevel, 1)
            }

            fixture.textView.insertText("!", replacementRange: fixture.textView.selectedRange())
            fixture.textView.breakUndoCoalescing()
            while fixture.undoManager.groupingLevel > 0 {
                fixture.undoManager.endUndoGrouping()
            }
            XCTAssertTrue(fixture.undoManager.groupsByEvent, "Native event grouping must be restored")
            XCTAssertEqual(fixture.textView.string, "Rewrite!")
            fixture.undoManager.undo()
            XCTAssertEqual(fixture.textView.string, "Rewrite")
            XCTAssertEqual(rewriteUndos, 0, "The first undo reverses the user's edit")
            fixture.undoManager.undo()
            XCTAssertEqual(rewriteUndos, 1, "The second undo reverses the prior external rewrite")
        }
    }

    func testReturnUsesDeliveredKeyEventInsteadOfNonKeyboardWindowEvent() throws {
        var returns = 0
        let fixture = try ResizableTextFieldHostingFixture(initialText: "draft", onReturn: { returns += 1 })
        defer { fixture.tearDown() }
        let windowEvent = try XCTUnwrap(NSEvent.otherEvent(
            with: .appKitDefined, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: fixture.window.windowNumber, context: nil, subtype: 4, data1: 0, data2: 0
        ))
        try fixture.sendReturn(currentWindowEvent: windowEvent)
        XCTAssertEqual(returns, 1)
        try fixture.sendReturn(repeatKey: true, currentWindowEvent: windowEvent)
        XCTAssertEqual(returns, 1, "The delivered key event still owns repeat suppression")
        try fixture.sendReturn(modifiers: .shift, currentWindowEvent: windowEvent)
        XCTAssertEqual(returns, 1, "A stale window event must not turn Shift+Return into Send")
        XCTAssertEqual(fixture.textView.string, "draft\n")
        XCTAssertNil(fixture.textView.currentKeyDownEvent, "Key-event ownership ends with native delivery")

        // Programmatic commands have no keyDown owner. The window fallback must not query
        // key-only properties on a KitDefined event, whether the editor is editable or read-only.
        fixture.window.injectedEvent = windowEvent
        defer { fixture.window.injectedEvent = nil }
        XCTAssertTrue(fixture.coordinator.textView(fixture.textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(returns, 2)
        fixture.coordinator.parent.isReadOnly = true
        fixture.coordinator.parent.onReadOnlyReturn = { returns += 1 }
        XCTAssertTrue(fixture.coordinator.textView(fixture.textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(returns, 3)
    }

    func testNativeDeletionSurrendersRewriteBeforeChangingText() throws {
        let transaction = TextFieldExternalEditTransaction(id: UUID(), isComplete: false)
        var takeoverTexts: [String] = []
        let fixture = try ResizableTextFieldHostingFixture(
            initialText: "draft!",
            initialExternalEditTransaction: transaction,
            onBeginUserEditing: { text, yieldedID in
                guard yieldedID != transaction.id else { return nil }
                takeoverTexts.append(text)
                return .init(id: transaction.id, revision: 0)
            }
        )
        defer { fixture.tearDown() }

        fixture.undoManager.beginUndoGrouping()
        fixture.textView.deleteBackward(nil)
        fixture.undoManager.endUndoGrouping()
        XCTAssertEqual(takeoverTexts, ["draft!"])
        XCTAssertEqual(fixture.textView.string, "draft")
        XCTAssertTrue(fixture.window.firstResponder === fixture.textView)
    }

    func testEditableReturnUsesExactModifiersAndNeverRepeatsSubmissionOrRewrite() throws {
        var submits = 0
        var rewrites = 0
        let fixture = try ResizableTextFieldHostingFixture(
            initialText: "draft",
            onReturn: { submits += 1 },
            onCommandReturn: { rewrites += 1
                return true
            }
        )
        defer { fixture.tearDown() }

        try fixture.sendReturn()
        XCTAssertEqual(submits, 1)
        try fixture.sendReturn(repeatKey: true)
        XCTAssertEqual(submits, 1)
        try fixture.sendReturn(modifiers: .shift)
        XCTAssertEqual(fixture.textView.string, "draft\n")
        XCTAssertEqual(submits, 1)
        try fixture.sendReturn(modifiers: .command)
        try fixture.sendReturn(modifiers: .command, repeatKey: true)
        XCTAssertEqual(rewrites, 1)

        let otherModifiers: [NSEvent.ModifierFlags] = [.option, .control, [.command, .shift], [.command, .option], [.command, .control], [.shift, .option]]
        for modifiers in otherModifiers {
            try fixture.sendReturn(modifiers: modifiers)
        }
        XCTAssertEqual(submits, 1, "Other modifier combinations retain native ownership and must not submit")
        XCTAssertEqual(rewrites, 1)
        XCTAssertTrue(fixture.window.firstResponder === fixture.textView)
    }

    func testNativeSnapshotTracksVisibleTextAndCompositionForTheRenderedIdentity() throws {
        let editor = TextFieldNativeEditor()
        let firstIdentity = AnyHashable(UUID())
        let nextIdentity = AnyHashable(UUID())
        let fixture = try ResizableTextFieldHostingFixture(
            initialText: "draft", nativeEditor: editor, nativeEditorIdentity: firstIdentity
        )
        defer { fixture.tearDown() }

        XCTAssertEqual(editor.snapshot(matching: firstIdentity)?.text, "draft")
        XCTAssertNil(editor.snapshot(matching: nextIdentity))
        fixture.insertNativeText("!")
        XCTAssertEqual(editor.snapshot(matching: firstIdentity)?.text, "draft!", "Submission must see native text even before its binding echo renders")
        fixture.beginMarkedText("かな")
        XCTAssertEqual(editor.snapshot(matching: firstIdentity)?.text, fixture.textView.string)
        XCTAssertEqual(editor.snapshot(matching: firstIdentity)?.hasMarkedText, true)
        fixture.completeMarkedText()
        XCTAssertEqual(editor.snapshot(matching: firstIdentity)?.hasMarkedText, false)

        try fixture.render(bindingText: "Other tab", externalUpdateTick: 1, nativeEditorIdentity: nextIdentity)
        XCTAssertNil(editor.snapshot(matching: firstIdentity))
        XCTAssertEqual(editor.snapshot(matching: nextIdentity)?.text, "Other tab")
    }

    func testDismantlingAnOldEditorCannotDetachANewerNativeSnapshot() throws {
        let editor = TextFieldNativeEditor()
        let firstIdentity = AnyHashable(UUID())
        let nextIdentity = AnyHashable(UUID())
        let first = try ResizableTextFieldHostingFixture(
            initialText: "First", nativeEditor: editor, nativeEditorIdentity: firstIdentity
        )
        defer { first.tearDown() }
        let next = try ResizableTextFieldHostingFixture(
            initialText: "Next", nativeEditor: editor, nativeEditorIdentity: nextIdentity
        )
        defer { next.tearDown() }

        first.tearDown()
        XCTAssertNil(editor.snapshot(matching: firstIdentity))
        XCTAssertEqual(editor.snapshot(matching: nextIdentity)?.text, "Next")
        next.tearDown()
        XCTAssertNil(editor.snapshot(matching: nextIdentity))
    }

    func testTabChangeDuringCompositionCannotAdoptThePriorTabsMarkedText() throws {
        let editor = TextFieldNativeEditor()
        let firstIdentity = AnyHashable(UUID())
        let nextIdentity = AnyHashable(UUID())
        var liveOperationID: UUID?
        var takeoverTexts: [String] = []
        let fixture = try ResizableTextFieldHostingFixture(
            initialText: "First tab",
            onBeginUserEditing: { text, yieldedID in
                guard let liveOperationID, liveOperationID != yieldedID else { return nil }
                takeoverTexts.append(text)
                return .init(id: liveOperationID, revision: 1)
            },
            nativeEditor: editor,
            nativeEditorIdentity: firstIdentity
        )
        defer { fixture.tearDown() }

        fixture.beginMarkedText("かな")
        let previousTabComposition = fixture.textView.string
        liveOperationID = UUID()
        try fixture.render(
            bindingText: "Next tab rewrite", externalUpdateTick: 1,
            externalEditTransaction: .init(id: XCTUnwrap(liveOperationID), isComplete: false),
            nativeEditorIdentity: nextIdentity
        )
        XCTAssertEqual(editor.snapshot(matching: firstIdentity)?.text, previousTabComposition)
        XCTAssertNil(editor.snapshot(matching: nextIdentity), "The new tab must not expose the previous tab's native draft")

        fixture.beginMarkedText("続き")
        XCTAssertTrue(takeoverTexts.isEmpty, "Continuing the old IME composition must not take over the new tab's rewrite")
        XCTAssertEqual(fixture.coordinator.pendingExternalTextUpdate?.text, "Next tab rewrite")
        fixture.completeMarkedText()
        XCTAssertTrue(fixture.publishedTexts.value.allSatisfy { $0 == "Next tab rewrite" }, "The previous composition must never be echoed into the new tab")
        XCTAssertEqual(fixture.textView.string, "Next tab rewrite")
        XCTAssertNil(editor.snapshot(matching: firstIdentity))
        XCTAssertEqual(editor.snapshot(matching: nextIdentity)?.text, "Next tab rewrite")

        fixture.textView.setSelectedRange(NSRange(location: (fixture.textView.string as NSString).length, length: 0))
        fixture.insertNativeText("!")
        XCTAssertEqual(takeoverTexts, ["Next tab rewrite"])
        XCTAssertEqual(fixture.publishedTexts.value.last, "Next tab rewrite!")
    }
}

@MainActor
private final class TextFieldEventWindow: NSWindow {
    var injectedEvent: NSEvent?
    override var currentEvent: NSEvent? {
        injectedEvent ?? super.currentEvent
    }
}

@MainActor
private final class ResizableTextFieldHostingFixture {
    let publishedTexts = ValueBox<[String]>([])
    let textView: AttachmentAwareTextView
    let coordinator: CustomTextField.Coordinator
    let scrollView: NSScrollView
    let window: TextFieldEventWindow

    private let boundText: ValueBox<String>
    private let externalUpdateTick: ValueBox<Int>
    private let heightPresetIndex = ValueBox(0)
    private let hostingView: NSHostingView<CustomTextField>
    private let onBeginUserEditing: ((String, UUID?) -> TextFieldExternalEditTakeover?)?
    private let onReturn: () -> Void
    private let onCommandReturn: (() -> Bool)?
    private let nativeEditor: TextFieldNativeEditor?
    private var nativeEditorIdentity: AnyHashable?
    private var isTornDown = false

    var undoManager: UndoManager {
        coordinator.undoManager(for: textView)!
    }

    init(
        initialText: String,
        initialExternalUpdateTick: Int = 0,
        initialExternalEditTransaction: TextFieldExternalEditTransaction? = nil,
        onBeginUserEditing: ((String, UUID?) -> TextFieldExternalEditTakeover?)? = nil,
        onReturn: @escaping () -> Void = {},
        onCommandReturn: (() -> Bool)? = nil,
        nativeEditor: TextFieldNativeEditor? = nil,
        nativeEditorIdentity: AnyHashable? = nil
    ) throws {
        let boundText = ValueBox(initialText)
        let externalUpdateTick = ValueBox(initialExternalUpdateTick)
        self.boundText = boundText
        self.externalUpdateTick = externalUpdateTick
        self.onBeginUserEditing = onBeginUserEditing
        self.onReturn = onReturn
        self.onCommandReturn = onCommandReturn
        self.nativeEditor = nativeEditor
        self.nativeEditorIdentity = nativeEditorIdentity

        let hostingView = NSHostingView(
            rootView: Self.makeParent(
                boundText: boundText,
                publishedTexts: publishedTexts,
                heightPresetIndex: heightPresetIndex,
                externalUpdateTick: externalUpdateTick,
                externalEditTransaction: initialExternalEditTransaction,
                onBeginUserEditing: onBeginUserEditing,
                onReturn: onReturn,
                onCommandReturn: onCommandReturn,
                nativeEditor: nativeEditor,
                nativeEditorIdentity: nativeEditorIdentity
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        self.hostingView = hostingView

        let window = TextFieldEventWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        self.window = window

        Self.flushHostedUpdates(hostingView)
        let scrollView = try XCTUnwrap(Self.hostedScrollViews(in: hostingView).only)
        let textView = try XCTUnwrap(scrollView.documentView as? AttachmentAwareTextView)
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

    func render(
        bindingText: String,
        externalUpdateTick: Int,
        externalEditTransaction: TextFieldExternalEditTransaction? = nil,
        nativeEditorIdentity: AnyHashable? = nil
    ) throws {
        boundText.value = bindingText
        self.externalUpdateTick.value = externalUpdateTick
        if let nativeEditorIdentity { self.nativeEditorIdentity = nativeEditorIdentity }
        hostingView.rootView = Self.makeParent(
            boundText: boundText,
            publishedTexts: publishedTexts,
            heightPresetIndex: heightPresetIndex,
            externalUpdateTick: self.externalUpdateTick,
            externalEditTransaction: externalEditTransaction,
            onBeginUserEditing: onBeginUserEditing,
            onReturn: onReturn,
            onCommandReturn: onCommandReturn,
            nativeEditor: nativeEditor,
            nativeEditorIdentity: self.nativeEditorIdentity
        )
        Self.flushHostedUpdates(hostingView)

        let updatedScrollView = try XCTUnwrap(Self.hostedScrollViews(in: hostingView).only)
        let updatedTextView = try XCTUnwrap(updatedScrollView.documentView as? AttachmentAwareTextView)
        XCTAssertTrue(updatedScrollView === scrollView)
        XCTAssertTrue(updatedTextView === textView)
        XCTAssertTrue(updatedTextView.delegate === coordinator)
        XCTAssertTrue(window.firstResponder === textView)
    }

    func insertNativeText(_ text: String) {
        performNativeMutation {
            undoManager.beginUndoGrouping()
            textView.insertText(text, replacementRange: textView.selectedRange())
            textView.breakUndoCoalescing()
            undoManager.endUndoGrouping()
        }
        deliverTextDidChange()
    }

    func sendReturn(modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false, currentWindowEvent: NSEvent? = nil) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: repeatKey, keyCode: 36
        ))
        window.injectedEvent = currentWindowEvent ?? event
        defer { window.injectedEvent = nil }
        if modifiers.contains(.command), textView.performKeyEquivalent(with: event) { return }
        undoManager.beginUndoGrouping()
        window.sendEvent(event)
        undoManager.endUndoGrouping()
    }

    func beginMarkedText(_ text: String) {
        performNativeMutation {
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
        performNativeMutation {
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

    private func performNativeMutation(_ operation: () -> Void) {
        if onBeginUserEditing != nil {
            operation()
            return
        }
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
        externalUpdateTick: ValueBox<Int>,
        externalEditTransaction: TextFieldExternalEditTransaction?,
        onBeginUserEditing: ((String, UUID?) -> TextFieldExternalEditTakeover?)?,
        onReturn: @escaping () -> Void,
        onCommandReturn: (() -> Bool)?,
        nativeEditor: TextFieldNativeEditor?,
        nativeEditorIdentity: AnyHashable?
    ) -> CustomTextField {
        CustomTextField(
            text: Binding(
                get: { boundText.value },
                set: { publishedTexts.value.append($0) }
            ),
            placeholder: "",
            onReturn: onReturn,
            onAttachmentPaste: nil,
            features: .plain,
            externalUpdateTick: externalUpdateTick.value,
            externalEditTransaction: externalEditTransaction,
            onBeginUserEditing: onBeginUserEditing,
            onCommandReturn: onCommandReturn,
            nativeEditor: nativeEditor,
            nativeEditorIdentity: nativeEditorIdentity,
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
           scrollView.documentView is AttachmentAwareTextView
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
