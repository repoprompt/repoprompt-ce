import Foundation

// A pure state machine that decides what to do during a hold-⌘Q-to-quit
// gesture.
//
// `QuitHoldDecision` has no AppKit, timer, or singleton coupling. It only maps
// discrete input events (`QuitHoldEvent`) to observable intents
// (`QuitHoldIntent`), so its full behavior is unit-testable with no mocks. The
// `QuitHoldController` (App layer) owns the real `NSEvent` local monitor, the
// hold timer, and the overlay, and feeds events into this value type.
//
// Quit timing: the threshold ARMS the quit; the actual quit intent is produced
// only when the user releases ⌘Q (keyUp or Command flag release) AFTER the
// threshold. Releasing before the threshold cancels. An `.externalCancel`
// (owner window closed, app resigned active, etc.) resets from `.holding` or
// `.armed` to `.idle` with a `.dismiss` intent so the controller can tear down
// the overlay immediately and a later ⌘Q can't quit from stale state.
//
// Semantics are pinned by `docs/spec/hold-to-quit.md` (scenarios S-001, S-002,
// S-003, S-010) and mirrored by `QuitHoldDecisionTests`.

/// Discrete input events the hold-decision state machine reacts to.
public enum QuitHoldEvent {
    /// A keyboard keyDown. `toggleOn` carries the current value of the
    /// "Warn before quitting with ⌘Q" setting at the moment of the event.
    case keyDown(toggleOn: Bool)
    /// A keyboard keyUp of Q.
    case keyUp
    /// A modifier-flag change. `commandDown` carries whether Command is held.
    case flagsChanged(commandDown: Bool)
    /// The hold timer elapsed (threshold reached).
    case timerElapsed
    /// An external condition aborted the gesture (owner window closed, app
    /// resigned active, …). Resets an in-flight hold; no-op if idle/already
    /// quitting.
    case externalCancel
}

/// Observable side effects the controller should perform in response to an event.
public enum QuitHoldIntent: Equatable {
    /// Do nothing.
    case ignore
    /// Show the hold overlay and start the hold timer at `threshold`.
    case beginHold(threshold: TimeInterval)
    /// Threshold reached while still holding: keep the overlay and update it to
    /// a "release to quit" message. Do NOT terminate yet.
    case arm
    /// Release before the threshold: dismiss the overlay (linger/fade), cancel
    /// the timer, and keep running.
    case cancel
    /// Release after the threshold: dismiss the overlay and quit through the
    /// normal shutdown path.
    case quit
    /// External cancellation: dismiss the overlay immediately (no linger) and
    /// reset to idle.
    case dismiss
}

public struct QuitHoldDecision {
    /// The hold threshold in seconds, shared by the decision and its controller.
    public static let threshold: TimeInterval = 1.0

    /// The current phase of the gesture.
    public enum State: Equatable {
        case idle
        case holding
        /// Threshold reached; waiting for ⌘Q / Command release to terminate.
        case armed
        case quitting
    }

    public private(set) var state: State = .idle

    public init() {}

    /// Feeds an event to the state machine, mutating state and returning the
    /// intent the controller should act on.
    @discardableResult
    public mutating func handle(_ event: QuitHoldEvent) -> QuitHoldIntent {
        switch state {
        case .idle:
            switch event {
            case .keyDown(toggleOn: true):
                state = .holding
                return .beginHold(threshold: Self.threshold)
            case .keyDown(toggleOn: false):
                return .ignore
            case .keyUp, .flagsChanged(commandDown: _), .timerElapsed, .externalCancel:
                return .ignore
            }

        case .holding:
            switch event {
            case .timerElapsed:
                // Threshold reached while still holding: arm, don't terminate.
                state = .armed
                return .arm
            case .keyUp, .flagsChanged(commandDown: false):
                // Released before the threshold: cancel.
                state = .idle
                return .cancel
            case .externalCancel:
                // Aborted externally: reset to idle, dismiss immediately.
                state = .idle
                return .dismiss
            case .keyDown(toggleOn: _), .flagsChanged(commandDown: true):
                return .ignore
            }

        case .armed:
            switch event {
            case .keyUp, .flagsChanged(commandDown: false):
                // Released after the threshold: quit. Quit MUST wait for
                // release rather than firing at the threshold while the key is
                // held — quitting mid-hold propagates the held ⌘Q to the next
                // focused app. See QuitHoldController's load-bearing notes.
                state = .quitting
                return .quit
            case .externalCancel:
                // Aborted externally: reset to idle, dismiss immediately. Without
                // this, a later ⌘Q tap could quit from stale `.armed` state.
                state = .idle
                return .dismiss
            case .keyDown(toggleOn: _), .flagsChanged(commandDown: true), .timerElapsed:
                return .ignore
            }

        case .quitting:
            return .ignore
        }
    }
}
