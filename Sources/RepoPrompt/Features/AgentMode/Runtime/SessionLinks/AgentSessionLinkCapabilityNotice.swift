import Foundation
import RepoPromptDomainRuntime

// Value model for proactively telling a *running* overseer that its user changed what it may do.
//
// Authority never waits for any of this: `DomainAgentSessionLinkAuthority.setManagement` changes the
// grant, and every management fence reads the grant. What this models is awareness — the notice the
// authority records for the exact observer endpoint, and how it reached (or will reach) the model:
//
// 1. a parked `agent_session_link wait` returns `capabilities_changed` carrying it (any provider);
// 2. the next `agent_session_link` result carries it as `capability_notice` (any provider);
// 3. a running Codex turn is steered with a RepoPrompt-authored notice (never a new turn, never the
//    follow-up queue, never the composer);
// 4. the next accepted dispatch's refreshed inventory block settles whatever is left.
//
// A notice is delivered at most once per channel claim; a failed push hands it back to the authority,
// which keeps only the newest change per link and drops notices for revoked or relinked grants.

/// Why a running-turn push was not made, stated for the user in the Oversee dashboard.
enum AgentSessionLinkCapabilityNoticeDeferral: Equatable {
    /// The overseer has no run in progress; its next turn starts with the refreshed capabilities.
    case observerIdle
    /// The overseer is running on a provider whose only mid-turn input path interrupts the turn
    /// (Claude) or has none (ACP), so RepoPrompt does not inject a notice mid-turn.
    case providerCannotTakeMidTurnNotice
    /// The overseer is running but not at a point where a notice can be steered in: it is waiting on
    /// a prompt, between states, or waiting for its next instruction.
    case observerBusy
    /// The running turn refused or did not confirm the steered notice.
    case steerNotAccepted
    /// The steer is still in flight after the dashboard's reporting bound. It settles on its own:
    /// if the turn does not take it, the notice stays owed to the next oversight call or turn.
    case pushInProgress
    /// No exact live overseer session, or it is not currently eligible to be told about its links.
    case observerUnavailable

    var dashboardMessage: String {
        switch self {
        case .observerIdle:
            "The overseer isn't running; it starts its next turn with the new capabilities."
        case .providerCannotTakeMidTurnNotice:
            "This overseer's provider can't take a notice mid-turn; it is told at its next oversight call or turn."
        case .pushInProgress:
            "Telling the overseer in its running turn; if that fails, it is told at its next oversight call or turn."
        case .observerBusy, .steerNotAccepted, .observerUnavailable:
            "The overseer is told at its next oversight call or turn."
        }
    }
}

/// How one management change's notice reached, or will reach, the overseer's model.
enum AgentSessionLinkCapabilityNoticeDelivery: Equatable {
    /// Steered into the overseer's exact running turn and accepted by the provider.
    case toldRunningTurn
    /// Already claimed by another channel — a woken `wait`, another oversight result, or an accepted
    /// dispatch — before a push was needed.
    case alreadyDelivered
    /// Still owed; it rides the next oversight result or accepted turn.
    case deferred(AgentSessionLinkCapabilityNoticeDeferral)

    var dashboardMessage: String {
        switch self {
        case .toldRunningTurn:
            "The overseer was told in its running turn."
        case .alreadyDelivered:
            "The overseer was told."
        case let .deferred(reason):
            reason.dashboardMessage
        }
    }
}

/// Result of one user management change as the dashboard reports it.
enum AgentSessionLinkManagementChangeReport: Equatable {
    /// The exact link generation is gone or ineligible; nothing changed.
    case failed
    /// The grant already had this state; nothing new is owed.
    case unchanged
    /// Authority changed now; `notice` says how the running overseer learns about it.
    case changed(notice: AgentSessionLinkCapabilityNoticeDelivery)
}

/// Whether the exact overseer can take a mid-turn notice right now.
enum AgentSessionLinkCapabilityNoticeRoute: Equatable {
    /// A Codex user turn is running and steerable.
    case codexRunningTurn
    case unavailable(AgentSessionLinkCapabilityNoticeDeferral)
}
