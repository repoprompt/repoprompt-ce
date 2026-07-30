import AppKit
@testable import RepoPromptApp
import XCTest

@MainActor
final class TextViewUndoSafeReplacementTests: XCTestCase {
    func testTypingRegistersUndoBeforeExternalReplacement() {
        let fixture = UndoTextViewFixture(initialText: "seed")

        fixture.type(" typed")

        XCTAssertEqual(fixture.textView.string, "seed typed")
        XCTAssertTrue(fixture.undoManager.canUndo)

        fixture.undoManager.undo()

        XCTAssertEqual(fixture.textView.string, "seed")
    }

    func testExternalReplacementClearsExistingUndoAndRedoStacks() {
        let undoFixture = UndoTextViewFixture(initialText: "seed")
        undoFixture.type(" typed")
        XCTAssertTrue(undoFixture.undoManager.canUndo)

        undoFixture.replaceDocument(with: "external from undo")

        XCTAssertEqual(undoFixture.textView.string, "external from undo")
        XCTAssertFalse(undoFixture.undoManager.canUndo)
        XCTAssertFalse(undoFixture.undoManager.canRedo)

        let redoFixture = UndoTextViewFixture(initialText: "seed")
        redoFixture.type(" typed")
        redoFixture.undoManager.undo()
        XCTAssertTrue(redoFixture.undoManager.canRedo)

        redoFixture.replaceDocument(with: "external from redo")

        XCTAssertEqual(redoFixture.textView.string, "external from redo")
        XCTAssertFalse(redoFixture.undoManager.canUndo)
        XCTAssertFalse(redoFixture.undoManager.canRedo)
    }

    func testTypingUndoResumesFromExternallyReplacedDocument() {
        let fixture = UndoTextViewFixture(initialText: "old")
        fixture.type(" draft")
        fixture.replaceDocument(with: "new document")

        fixture.type("!")

        XCTAssertEqual(fixture.textView.string, "new document!")
        XCTAssertTrue(fixture.undoManager.canUndo)

        fixture.undoManager.undo()

        XCTAssertEqual(fixture.textView.string, "new document")
    }

    func testReplacementDuringUndoAndRedoDefersHistoryClearUntilTransactionCompletes() {
        let undoFixture = UndoTextViewFixture(initialText: "before undo")
        let undoTarget = UndoActionTarget()
        var observedUndoing = false

        undoFixture.undoManager.beginUndoGrouping()
        undoFixture.undoManager.registerUndo(withTarget: undoTarget) { target in
            TextViewUndoSafeReplacement.perform(
                in: undoFixture.textView,
                undoManager: undoFixture.undoManager
            ) {
                observedUndoing = undoFixture.undoManager.isUndoing
                undoFixture.textView.string = "replacement during undo"
                undoFixture.undoManager.registerUndo(withTarget: target) { _ in }
            }
        }
        undoFixture.undoManager.endUndoGrouping()

        undoFixture.undoManager.undo()

        XCTAssertTrue(observedUndoing)
        XCTAssertEqual(undoFixture.textView.string, "replacement during undo")
        XCTAssertTrue(undoFixture.undoManager.canRedo)

        waitForMainQueueTurn()

        XCTAssertFalse(undoFixture.undoManager.canUndo)
        XCTAssertFalse(undoFixture.undoManager.canRedo)

        let redoFixture = UndoTextViewFixture(initialText: "before redo")
        let redoTarget = UndoActionTarget()
        var observedRedoing = false

        redoFixture.undoManager.beginUndoGrouping()
        redoFixture.undoManager.registerUndo(withTarget: redoTarget) { target in
            redoFixture.undoManager.registerUndo(withTarget: target) { target in
                TextViewUndoSafeReplacement.perform(
                    in: redoFixture.textView,
                    undoManager: redoFixture.undoManager
                ) {
                    observedRedoing = redoFixture.undoManager.isRedoing
                    redoFixture.textView.string = "replacement during redo"
                    redoFixture.undoManager.registerUndo(withTarget: target) { _ in }
                }
            }
        }
        redoFixture.undoManager.endUndoGrouping()

        redoFixture.undoManager.undo()
        XCTAssertTrue(redoFixture.undoManager.canRedo)

        redoFixture.undoManager.redo()

        XCTAssertTrue(observedRedoing)
        XCTAssertEqual(redoFixture.textView.string, "replacement during redo")
        XCTAssertTrue(redoFixture.undoManager.canUndo)

        waitForMainQueueTurn()

        XCTAssertFalse(redoFixture.undoManager.canUndo)
        XCTAssertFalse(redoFixture.undoManager.canRedo)
    }

    func testCallerPolicyClampsSelectionAfterReplacement() {
        let selectionFixture = UndoTextViewFixture(initialText: "abc👩‍💻xyz")
        let oldUTF16Length = (selectionFixture.textView.string as NSString).length
        selectionFixture.textView.setSelectedRange(
            NSRange(location: oldUTF16Length - 1, length: 1)
        )
        let previousSelection = selectionFixture.textView.clampedSelectedRange()

        TextViewUndoSafeReplacement.perform(
            in: selectionFixture.textView,
            undoManager: selectionFixture.undoManager
        ) {
            selectionFixture.textView.string = "é"
        }
        selectionFixture.textView.setSelectedRange(
            previousSelection.clamped(to: selectionFixture.textView.currentStringLength())
        )

        XCTAssertEqual(selectionFixture.textView.currentStringLength(), 1)
        XCTAssertEqual(selectionFixture.textView.selectedRange(), NSRange(location: 1, length: 0))
    }

    private func waitForMainQueueTurn() {
        let mainQueueTurn = expectation(description: "main queue turn")
        DispatchQueue.main.async {
            mainQueueTurn.fulfill()
        }
        wait(for: [mainQueueTurn], timeout: 1)
    }
}

@MainActor
private final class UndoTextViewFixture {
    let textView: UndoTestTextView

    var undoManager: UndoManager {
        textView.ownedUndoManager
    }

    init(initialText: String) {
        textView = UndoTestTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.string = initialText
        textView.setSelectedRange(
            NSRange(location: (initialText as NSString).length, length: 0)
        )
        undoManager.groupsByEvent = false
        undoManager.removeAllActions()
    }

    func type(_ text: String) {
        undoManager.beginUndoGrouping()
        textView.insertText(text, replacementRange: textView.selectedRange())
        textView.breakUndoCoalescing()
        undoManager.endUndoGrouping()
    }

    func replaceDocument(with text: String) {
        TextViewUndoSafeReplacement.perform(
            in: textView,
            undoManager: undoManager
        ) {
            textView.string = text
        }
    }
}

@MainActor
private final class UndoTestTextView: NSTextView {
    let ownedUndoManager = UndoManager()

    override var undoManager: UndoManager? {
        ownedUndoManager
    }
}

private final class UndoActionTarget: NSObject {}
