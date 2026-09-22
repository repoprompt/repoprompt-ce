@testable import RepoPromptApp
import XCTest

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
}
