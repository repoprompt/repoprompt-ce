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
    /// The hold timer elapsed.
    case timerElapsed
}

/// Observable side effects the controller should perform in response to an event.
public enum QuitHoldIntent: Equatable {
    /// Do nothing.
    case ignore
    /// Show the hold overlay and start the hold timer at `threshold`.
    case beginHold(threshold: TimeInterval)
    /// Dismiss the overlay, cancel the timer, and keep the app running.
    case cancel
    /// Dismiss the overlay and quit through the normal shutdown path.
    case quit
}

public struct QuitHoldDecision {
    /// The hold threshold in seconds, shared by the decision and its controller.
    public static let threshold: TimeInterval = 1.0

    /// The current phase of the gesture.
    public enum State: Equatable {
        case idle
        case holding
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
            case .keyUp, .flagsChanged(commandDown: _), .timerElapsed:
                return .ignore
            }
        case .holding:
            switch event {
            case .timerElapsed:
                state = .quitting
                return .quit
            case .keyUp, .flagsChanged(commandDown: false):
                state = .idle
                return .cancel
            case .keyDown(toggleOn: _), .flagsChanged(commandDown: true):
                return .ignore
            }
        case .quitting:
            return .ignore
        }
    }
}
