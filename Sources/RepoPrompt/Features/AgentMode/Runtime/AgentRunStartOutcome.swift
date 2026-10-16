import Foundation

// MARK: - Provider control commands

/// Immutable identity carried to the final provider input seam. A pipeline start is not an
/// acknowledgment that the bytes reached the provider.
struct AgentSelfCompactionDispatchID: Equatable {
    enum Stage: Equatable {
        case compact
        case note
    }

    let requestID: UUID
    let stage: Stage
}

/// A provider-native maintenance command that RepoPrompt itself constructs, bound to the exact
/// provider conversation it was admitted for.
///
/// The provider-bound text is fixed here and never derived from caller input, so an overseer can ask
/// for a compaction without any sender-controlled string ever reaching a provider as a command. The
/// conversation binding travels with the command because run preparation can suspend after the
/// admitting transaction's last fence; the runtime re-proves it at its own send boundary.
struct AgentProviderControlCommand: Equatable {
    enum Kind: String, Equatable {
        case compact
    }

    let kind: Kind
    /// The exact app-session binding the command was admitted for. Every rebind — including one to
    /// the same session UUID — installs a new identity, so any rebind refuses the command.
    let expectedBinding: AgentPersistentSessionBindingIdentity
    /// The provider conversation the command was admitted for. It runs only against exactly this
    /// conversation; a fresh-start fallback or any other conversation refuses it.
    let expectedProviderConversation: String
    let selfCompactDispatchID: AgentSelfCompactionDispatchID?

    static func compact(
        expectedBinding: AgentPersistentSessionBindingIdentity,
        expectedProviderConversation: String,
        selfCompactDispatchID: AgentSelfCompactionDispatchID? = nil
    ) -> AgentProviderControlCommand {
        AgentProviderControlCommand(
            kind: .compact,
            expectedBinding: expectedBinding,
            expectedProviderConversation: expectedProviderConversation,
            selfCompactDispatchID: selfCompactDispatchID
        )
    }

    /// The exact provider-bound text: the native slash command and nothing else.
    var providerText: String {
        "/\(kind.rawValue)"
    }

    /// ACP runtimes whose advertised slash commands are the agent's own commands.
    ///
    /// OpenCode advertises the user's own commands and skills, so an advertised `compact` there may
    /// be a user command rather than native compaction; Cursor has no verified native command. Both
    /// stay unsupported whatever they advertise.
    static func acpRuntimeAdvertisesNativeCommands(_ agent: AgentProviderKind) -> Bool {
        switch agent {
        case .devin, .grokBuild, .antigravity:
            true
        case .openCode, .cursor, .codexExec, .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            false
        }
    }

    /// Whether `session`'s live ACP controller currently advertises `kind` in the provider session
    /// `providerConversation`. Live-unverified: no provider-recorded advertisement has been observed.
    @MainActor
    static func acpSession(
        _ session: AgentTabSession,
        advertises kind: Kind,
        inProviderConversation providerConversation: String
    ) -> Bool {
        guard acpRuntimeAdvertisesNativeCommands(session.selectedAgent),
              let controller = session.acpController
        else { return false }
        return controller.advertisesCommand(kind.rawValue, inProviderSession: providerConversation)
    }
}

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
    var periodicWakeID: UUID?

    /// Marks this run as a RepoPrompt-constructed provider maintenance command (an overseer
    /// compaction). Its provider input is exactly `command.providerText`: no user augmentation, no
    /// initial-thread context, no staged handoff, no oversight supplement, and no instruction or
    /// effort packaging, because any of those would turn a native command into inert prose.
    var providerControlCommand: AgentProviderControlCommand?

    /// One dedicated continuation-note turn; never an ordinary user send or a fallback queue item.
    var selfCompactDispatchID: AgentSelfCompactionDispatchID?

    /// Captured at producer scheduling time so a prior Stop cannot bless deferred work.
    var stopFence: AgentRunStartStopFence?
    var skipsUserAugmentation: Bool {
        isLaneUpdate || periodicWakeID != nil || providerControlCommand != nil || selfCompactDispatchID != nil
    }

    var isLaneUpdate: Bool {
        laneUpdateWakeID != nil
    }

    static func periodicWake(
        wakeID: UUID,
        stopFence: AgentRunStartStopFence? = nil
    ) -> AgentDirectRunStartOptions {
        AgentDirectRunStartOptions(
            ignoresPendingHandoff: true,
            periodicWakeID: wakeID,
            stopFence: stopFence
        )
    }

    static let `default` = AgentDirectRunStartOptions()

    /// Options for `agent_session_link.send`.
    static let crossSessionDelivery = AgentDirectRunStartOptions(ignoresPendingHandoff: true)

    /// Options for one overseer-requested provider control command.
    static func providerControl(_ command: AgentProviderControlCommand) -> AgentDirectRunStartOptions {
        AgentDirectRunStartOptions(
            ignoresPendingHandoff: true,
            providerControlCommand: command,
            selfCompactDispatchID: command.selfCompactDispatchID
        )
    }

    static func selfCompactNote(requestID: UUID) -> AgentDirectRunStartOptions {
        AgentDirectRunStartOptions(
            ignoresPendingHandoff: true,
            selfCompactDispatchID: .init(requestID: requestID, stage: .note)
        )
    }

    /// Options for one automatic lane-update follow-up.
    static func laneUpdate(
        wakeID: UUID,
        stopFence: AgentRunStartStopFence? = nil
    ) -> AgentDirectRunStartOptions {
        AgentDirectRunStartOptions(
            ignoresPendingHandoff: true,
            laneUpdateWakeID: wakeID,
            stopFence: stopFence
        )
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
