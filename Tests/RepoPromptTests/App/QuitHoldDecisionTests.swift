@testable import RepoPrompt
import XCTest

/// Pins every branch of the pure hold-⌘Q-to-quit decision state machine.
///
/// These tests cover the decision layer of scenarios S-001, S-002, S-003, and
/// S-010 (see `docs/spec/hold-to-quit.md`). The `QuitHoldDecision` type has no
/// AppKit, timer, or singleton coupling, so its full behavior is exercised here
/// at the lowest faithful layer with no mocks.
final class QuitHoldDecisionTests: XCTestCase {
    /// S-003: a ⌘Q keyDown with the toggle off is ignored at the decision layer;
    /// the controller does not begin a hold and the state stays idle.
    func testKeyDownToggleOffReturnsIgnoreAndStaysIdle() {
        var decision = QuitHoldDecision()
        XCTAssertEqual(decision.state, .idle)

        let intent = decision.handle(.keyDown(toggleOn: false))

        XCTAssertEqual(intent, .ignore)
        XCTAssertEqual(decision.state, .idle)
    }

    /// S-001 setup: the first ⌘Q keyDown with the toggle on begins a hold using
    /// the shared threshold and transitions into the holding state.
    func testKeyDownToggleOnBeginsHoldAndEntersHolding() {
        var decision = QuitHoldDecision()

        let intent = decision.handle(.keyDown(toggleOn: true))

        XCTAssertEqual(intent, .beginHold(threshold: QuitHoldDecision.threshold))
        XCTAssertEqual(intent, .beginHold(threshold: 1.0))
        XCTAssertEqual(decision.state, .holding)
    }

    /// S-001: a held ⌘Q whose timer elapses past the threshold quits and
    /// transitions into the (terminal) quitting state.
    func testTimerElapsedWhileHoldingQuitsAndEntersQuitting() {
        var decision = QuitHoldDecision()
        _ = decision.handle(.keyDown(toggleOn: true))

        let intent = decision.handle(.timerElapsed)

        XCTAssertEqual(intent, .quit)
        XCTAssertEqual(decision.state, .quitting)
    }

    /// S-002: releasing Q (keyUp) before the threshold cancels the hold and
    /// returns the state machine to idle.
    func testKeyUpWhileHoldingCancelsAndReturnsToIdle() {
        var decision = QuitHoldDecision()
        _ = decision.handle(.keyDown(toggleOn: true))

        let intent = decision.handle(.keyUp)

        XCTAssertEqual(intent, .cancel)
        XCTAssertEqual(decision.state, .idle)
    }

    /// S-002 alt: releasing the Command modifier before the threshold cancels
    /// the hold and returns the state machine to idle.
    func testFlagsChangedCommandReleasedWhileHoldingCancelsAndReturnsToIdle() {
        var decision = QuitHoldDecision()
        _ = decision.handle(.keyDown(toggleOn: true))

        let intent = decision.handle(.flagsChanged(commandDown: false))

        XCTAssertEqual(intent, .cancel)
        XCTAssertEqual(decision.state, .idle)
    }

    /// S-010: a re-entrant ⌘Q keyDown while a hold is already in progress is
    /// ignored — it never starts a second hold and never quits early.
    func testRepeatKeyDownWhileHoldingIsIgnoredAndStaysHolding() {
        var decision = QuitHoldDecision()
        _ = decision.handle(.keyDown(toggleOn: true))

        let intent = decision.handle(.keyDown(toggleOn: true))

        XCTAssertEqual(intent, .ignore)
        XCTAssertEqual(decision.state, .holding)
    }

    /// A flagsChanged that keeps Command held while holding does not break the
    /// hold; it is ignored and the state stays holding.
    func testFlagsChangedCommandHeldWhileHoldingIsIgnoredAndStaysHolding() {
        var decision = QuitHoldDecision()
        _ = decision.handle(.keyDown(toggleOn: true))

        let intent = decision.handle(.flagsChanged(commandDown: true))

        XCTAssertEqual(intent, .ignore)
        XCTAssertEqual(decision.state, .holding)
    }

    /// From idle, every non-keyDown event (keyUp, flagsChanged, timerElapsed) is
    /// a no-op: the state stays idle and the decision never begins a hold,
    /// cancels, or quits spuriously.
    func testNonKeyDownEventsWhileIdleAreIgnoredAndStaysIdle() {
        let events: [QuitHoldEvent] = [
            .keyUp,
            .flagsChanged(commandDown: true),
            .flagsChanged(commandDown: false),
            .timerElapsed
        ]

        for event in events {
            var decision = QuitHoldDecision()
            let intent = decision.handle(event)
            XCTAssertEqual(intent, .ignore, "expected .ignore for \(event) from idle")
            XCTAssertEqual(decision.state, .idle, "expected .idle after \(event) from idle")
        }
    }

    /// From the terminal quitting state, every event is ignored and the state
    /// stays quitting — quit is committed and cannot be cancelled.
    func testEventsWhileQuittingAreIgnoredAndStaysQuitting() {
        let events: [QuitHoldEvent] = [
            .keyDown(toggleOn: true),
            .keyDown(toggleOn: false),
            .keyUp,
            .flagsChanged(commandDown: true),
            .flagsChanged(commandDown: false),
            .timerElapsed
        ]

        for event in events {
            var decision = QuitHoldDecision()
            _ = decision.handle(.keyDown(toggleOn: true))
            _ = decision.handle(.timerElapsed)
            XCTAssertEqual(decision.state, .quitting)

            let intent = decision.handle(event)

            XCTAssertEqual(intent, .ignore, "expected .ignore for \(event) from quitting")
            XCTAssertEqual(decision.state, .quitting, "expected .quitting after \(event) from quitting")
        }
    }
}
