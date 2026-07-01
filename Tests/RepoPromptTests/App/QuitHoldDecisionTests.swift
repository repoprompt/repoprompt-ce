@testable import RepoPrompt
import XCTest

/// Pins the hold-⌘Q-to-quit state machine. The threshold ARMS the quit; the
/// quit intent is produced only on release AFTER the threshold. Releasing
/// before the threshold cancels.
final class QuitHoldDecisionTests: XCTestCase {
    /// S-003: gate-off keyDown is ignored and never begins a hold.
    func testKeyDownToggleOffReturnsIgnoreAndStaysIdle() {
        var decision = QuitHoldDecision()
        let intent = decision.handle(.keyDown(toggleOn: false))
        XCTAssertEqual(intent, .ignore)
        XCTAssertEqual(decision.state, .idle)
    }

    /// S-001 setup: gate-on keyDown begins the hold with the threshold.
    func testKeyDownToggleOnBeginsHoldAndEntersHolding() {
        var decision = QuitHoldDecision()
        let intent = decision.handle(.keyDown(toggleOn: true))
        XCTAssertEqual(intent, .beginHold(threshold: QuitHoldDecision.threshold))
        XCTAssertEqual(decision.state, .holding)
    }

    /// Threshold reached while holding ARMS the quit (does not quit immediately).
    func testTimerElapsedWhileHoldingArmsAndEntersArmed() {
        var decision = QuitHoldDecision()
        _ = decision.handle(.keyDown(toggleOn: true))
        let intent = decision.handle(.timerElapsed)
        XCTAssertEqual(intent, .arm)
        XCTAssertEqual(decision.state, .armed)
    }

    /// S-002: Q keyUp before the threshold cancels and returns to idle.
    func testKeyUpWhileHoldingCancelsAndReturnsToIdle() {
        var decision = QuitHoldDecision()
        _ = decision.handle(.keyDown(toggleOn: true))
        let intent = decision.handle(.keyUp)
        XCTAssertEqual(intent, .cancel)
        XCTAssertEqual(decision.state, .idle)
    }

    /// S-002 alt: Command release before the threshold cancels and returns to idle.
    func testFlagsChangedCommandReleasedWhileHoldingCancelsAndReturnsToIdle() {
        var decision = QuitHoldDecision()
        _ = decision.handle(.keyDown(toggleOn: true))
        let intent = decision.handle(.flagsChanged(commandDown: false))
        XCTAssertEqual(intent, .cancel)
        XCTAssertEqual(decision.state, .idle)
    }

    /// S-010: a repeat ⌘Q keyDown while holding is ignored and stays holding.
    func testRepeatKeyDownWhileHoldingIsIgnoredAndStaysHolding() {
        var decision = QuitHoldDecision()
        _ = decision.handle(.keyDown(toggleOn: true))
        let intent = decision.handle(.keyDown(toggleOn: true))
        XCTAssertEqual(intent, .ignore)
        XCTAssertEqual(decision.state, .holding)
    }

    /// A stray Command-held flags event while holding does not cancel.
    func testFlagsChangedCommandHeldWhileHoldingIsIgnoredAndStaysHolding() {
        var decision = QuitHoldDecision()
        _ = decision.handle(.keyDown(toggleOn: true))
        let intent = decision.handle(.flagsChanged(commandDown: true))
        XCTAssertEqual(intent, .ignore)
        XCTAssertEqual(decision.state, .holding)
    }

    /// Idle noise (keyUp / flagsChanged / timerElapsed) is ignored.
    func testNonKeyDownEventsWhileIdleAreIgnoredAndStaysIdle() {
        var decision = QuitHoldDecision()
        for event in [QuitHoldEvent.keyUp, .flagsChanged(commandDown: false), .flagsChanged(commandDown: true), .timerElapsed] {
            var d = decision
            XCTAssertEqual(d.handle(event), .ignore)
            XCTAssertEqual(d.state, .idle)
        }
        XCTAssertEqual(decision.state, .idle)
    }

    // MARK: - Armed (threshold reached, awaiting release)

    /// S-001: Q keyUp after the threshold quits and enters the terminal state.
    func testKeyUpWhileArmedQuitsAndEntersQuitting() {
        var decision = Self.armedDecision()
        let intent = decision.handle(.keyUp)
        XCTAssertEqual(intent, .quit)
        XCTAssertEqual(decision.state, .quitting)
    }

    /// S-001 alt: Command release after the threshold quits.
    func testFlagsChangedCommandReleasedWhileArmedQuitsAndEntersQuitting() {
        var decision = Self.armedDecision()
        let intent = decision.handle(.flagsChanged(commandDown: false))
        XCTAssertEqual(intent, .quit)
        XCTAssertEqual(decision.state, .quitting)
    }

    /// S-010: a repeat ⌘Q keyDown after arming is ignored and stays armed.
    func testRepeatKeyDownWhileArmedIsIgnoredAndStaysArmed() {
        var decision = Self.armedDecision()
        let intent = decision.handle(.keyDown(toggleOn: true))
        XCTAssertEqual(intent, .ignore)
        XCTAssertEqual(decision.state, .armed)
    }

    /// A stray Command-held flags event after arming does not quit.
    func testFlagsChangedCommandHeldWhileArmedIsIgnoredAndStaysArmed() {
        var decision = Self.armedDecision()
        let intent = decision.handle(.flagsChanged(commandDown: true))
        XCTAssertEqual(intent, .ignore)
        XCTAssertEqual(decision.state, .armed)
    }

    /// Terminal quitting state is not escapable.
    func testEventsWhileQuittingAreIgnoredAndStaysQuitting() {
        var decision = Self.armedDecision()
        _ = decision.handle(.keyUp)
        XCTAssertEqual(decision.state, .quitting)
        for event in [QuitHoldEvent.keyDown(toggleOn: true), .keyUp, .flagsChanged(commandDown: false), .timerElapsed] {
            XCTAssertEqual(decision.handle(event), .ignore)
            XCTAssertEqual(decision.state, .quitting)
        }
    }

    // MARK: - External cancellation (owner window closed / app resigned active)

    /// External cancel while holding dismisses and returns to idle.
    func testExternalCancelWhileHoldingDismissesAndReturnsToIdle() {
        var decision = QuitHoldDecision()
        _ = decision.handle(.keyDown(toggleOn: true))
        let intent = decision.handle(.externalCancel)
        XCTAssertEqual(intent, .dismiss)
        XCTAssertEqual(decision.state, .idle)
    }

    /// External cancel while armed resets to idle — a later ⌘Q tap must NOT
    /// quit from stale `.armed` state (regression: owner window closes mid-hold).
    func testExternalCancelWhileArmedDismissesAndReturnsToIdle() {
        var decision = QuitHoldDecision()
        _ = decision.handle(.keyDown(toggleOn: true))
        _ = decision.handle(.timerElapsed)
        let intent = decision.handle(.externalCancel)
        XCTAssertEqual(intent, .dismiss)
        XCTAssertEqual(decision.state, .idle)
    }

    /// After an external cancel from `.armed`, a subsequent quick ⌘Q tap does
    /// not quit — it begins a fresh hold and cancels on release, never quits.
    func testTapAfterExternalCancelFromArmedDoesNotQuit() {
        var decision = QuitHoldDecision()
        _ = decision.handle(.keyDown(toggleOn: true))
        _ = decision.handle(.timerElapsed)
        _ = decision.handle(.externalCancel)
        let down = decision.handle(.keyDown(toggleOn: true))
        XCTAssertEqual(down, .beginHold(threshold: QuitHoldDecision.threshold))
        XCTAssertEqual(decision.state, .holding)
        let up = decision.handle(.keyUp)
        XCTAssertEqual(up, .cancel)
        XCTAssertEqual(decision.state, .idle)
    }

    /// External cancel is a no-op when idle.
    func testExternalCancelWhileIdleIsIgnored() {
        var decision = QuitHoldDecision()
        XCTAssertEqual(decision.handle(.externalCancel), .ignore)
        XCTAssertEqual(decision.state, .idle)
    }

    /// External cancel does not escape the terminal quitting state.
    func testExternalCancelWhileQuittingIsIgnored() {
        var decision = QuitHoldDecision()
        _ = decision.handle(.keyDown(toggleOn: true))
        _ = decision.handle(.timerElapsed)
        _ = decision.handle(.keyUp)
        XCTAssertEqual(decision.handle(.externalCancel), .ignore)
        XCTAssertEqual(decision.state, .quitting)
    }

    // MARK: - Helpers

    /// A decision driven to the armed state (toggle-on keyDown + timer elapsed).
    private static func armedDecision() -> QuitHoldDecision {
        var decision = QuitHoldDecision()
        _ = decision.handle(.keyDown(toggleOn: true))
        let armIntent = decision.handle(.timerElapsed)
        XCTAssertEqual(armIntent, .arm)
        XCTAssertEqual(decision.state, .armed)
        return decision
    }
}
