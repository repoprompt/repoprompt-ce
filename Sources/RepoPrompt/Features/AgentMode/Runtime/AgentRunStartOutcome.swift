import Foundation

// MARK: - Direct-start options

/// Narrow opt-outs for a run started by something other than the local composer.
///
/// Every field defaults to the ordinary local-send behaviour, so adding one cannot change an
/// existing caller. Only a caller that must not act as "the target's next local send" sets any of
/// them.
struct AgentDirectRunStartOptions: Equatable {
    /// Leaves `pendingHandoff` completely untouched: not prepended, not marked staged, not cleared,
    /// and not consulted for the history/payload decision.
    ///
    /// A staged handoff belongs to whoever types the target's next message. A cross-session delivery
    /// must not spend it: doing so would splice the target's own forked transcript into a turn a
    /// different session initiated, and would leave the local user's next message without the
    /// continuity it was staged for.
    var ignoresPendingHandoff: Bool = false

    /// Marks this run as RepoPrompt's own lane-update follow-up rather than any kind of user send.
    ///
    /// A typed identity, deliberately **not** an empty-string check: "the caller passed no text" is a
    /// property a future refactor can produce by accident, whereas a wake ID can only come from the
    /// auto-wake coordinator. It carries no user-authored base instruction, appends no `.user` row,
    /// does not move `lastUserMessageAt`, and never consumes a staged handoff — the rendered lane
    /// claim the ordinary supplement path attaches is its whole new provider input.
    var laneUpdateWakeID: UUID?

    var isLaneUpdate: Bool {
        laneUpdateWakeID != nil
    }

    static let `default` = AgentDirectRunStartOptions()

    /// Options for `agent_session_link.send`.
    static let crossSessionDelivery = AgentDirectRunStartOptions(ignoresPendingHandoff: true)

    /// Options for one automatic lane-update follow-up.
    static func laneUpdate(wakeID: UUID) -> AgentDirectRunStartOptions {
        AgentDirectRunStartOptions(ignoresPendingHandoff: true, laneUpdateWakeID: wakeID)
    }
}

// MARK: - Start outcome

/// Provider-neutral record of whether a run reached its provider pipeline.
///
/// `AgentModeRunService.startRun` returns `CodexAgentModeCoordinator.NativeSendOutcome?`, where
/// `nil` means "not a Codex native send" — it says nothing about success, so Claude, ACP, and
/// headless report success and pre-start failure identically. Callers that must distinguish the two
/// (currently only the cross-session send receipt) pass a recorder instead of changing that return
/// type, which would touch every existing caller.
///
/// Defaults to `.startFailed` on purpose: a path that returns without recording is a path nobody
/// proved started, and a receipt that says `run_start_failed` makes the observer poll, whereas a
/// wrong `run_started` makes it wait for output that will never arrive.
@MainActor
final class AgentRunStartOutcomeRecorder {
    enum Outcome: Equatable {
        /// The run reached its provider pipeline. Later provider failures are ordinary run failures.
        case accepted
        /// The run was rejected before provider startup. No provider turn exists.
        case startFailed(message: String?)

        var didStart: Bool {
            self == .accepted
        }
    }

    private(set) var outcome: Outcome = .startFailed(message: nil)

    init() {}

    func recordAccepted() {
        outcome = .accepted
    }

    func recordStartFailure(message: String?) {
        outcome = .startFailed(message: message)
    }

    /// Maps the Codex native send outcome onto the provider-neutral vocabulary. A durably queued
    /// fallback counts as started: the message is committed to the provider pipeline.
    func record(codexOutcome: CodexAgentModeCoordinator.NativeSendOutcome) {
        switch codexOutcome {
        case .sent, .queuedFallback:
            recordAccepted()
        case let .preDispatchRejected(message), let .failed(message):
            recordStartFailure(message: message)
        case let .stale(reason):
            recordStartFailure(message: reason)
        case .cancelled:
            recordStartFailure(message: nil)
        }
    }
}
