import Foundation
import MCP
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptInstrumentation
import RepoPromptMCPServer

/// Window-local seam between the authoritative link inventory and the provider dispatch adapters.
///
/// The adapters (Codex start/steer/fallback, Claude native, Claude/generic headless, ACP prompt and
/// active steering, waiting-instruction continuation) preserve synchronous baseline composition and
/// acceptance. Optional user-input disclosure adds an exact Read proof after all other preparation
/// awaits, followed by synchronous MainActor revalidation/consumption at the final provider handoff.
/// A failed optional proof falls back to the unchanged baseline; it never creates a dispatch.
/// The authoritative outbound inventory published to one exact incarnation.
///
/// The endpoint is stored alongside the value rather than implied by the map key: an in-place rebind
/// keeps the session UUID while advancing the binding generations, so a UUID-keyed read alone would
/// hand a fresh incarnation the targets the previous one was granted.
struct AgentSessionLinkPublishedPromptInventory: Equatable {
    let endpoint: DomainAgentSessionLinkEndpointIdentity
    let inventory: AgentSessionLinkPromptInventory
}

/// One endpoint's publication fence, raised for the duration of *every* overlapping membership write.
///
/// The fence is shared, not owned: activations for the same observer can overlap (the Add sheet's
/// `isWorking` single-flight is per-view `@State`, so dismissing and reopening it mid-flight yields a
/// fresh control), and it must stay raised until the last participant has settled. A fence that only
/// the newest writer could lower let a *rejected* newest writer restore the pre-hop inventory over a
/// sibling that had already committed but not yet published — the same false terminal notice the
/// fence exists to prevent, reachable in the other release order.
struct AgentSessionLinkPromptInventoryHold: Equatable {
    /// Every writer that has raised this fence and not yet settled. While it is non-empty the
    /// endpoint stays withheld, so no release order can expose a partially-settled membership.
    let outstanding: Set<UInt64>
    /// What this endpoint had published when the *first* participant fenced it, restored only if no
    /// participant commits. `nil` when the endpoint had nothing published, which is itself the
    /// correct state to return to.
    let retracted: AgentSessionLinkPromptInventory?
    /// The highest-`linkSetRevision` inventory reported by a participant that committed, or `nil`
    /// while none has. This is what the last release publishes: it is a comparison of values each
    /// read inside the body that committed it, so it does not depend on which continuation resumes
    /// first.
    let committed: AgentSessionLinkPromptInventory?
}

/// One incarnation's claim inputs: what it may be told, and the epoch that scopes the telling.
struct AgentSessionLinkPromptContext: Equatable {
    let epoch: AgentSessionLinkPromptEpoch
    let inventory: AgentSessionLinkPromptInventory
    /// This session's latest published passive status queue, unfiltered.
    ///
    /// Deliberately handed over raw rather than pre-screened here: every condition that may join a
    /// batch to a dispatch — endpoint match, eligibility, enablement, deliverability, revision match,
    /// and grant membership — lives in one truth table inside the claim store, where it is testable
    /// without a view model.
    let passiveNotices: AgentSessionLinkPassiveStatusNotices.Snapshot?

    init(
        epoch: AgentSessionLinkPromptEpoch,
        inventory: AgentSessionLinkPromptInventory,
        passiveNotices: AgentSessionLinkPassiveStatusNotices.Snapshot? = nil
    ) {
        self.epoch = epoch
        self.inventory = inventory
        self.passiveNotices = passiveNotices
    }
}

extension AgentModeViewModel {
    typealias ProviderInputRouteReadiness = AgentSessionLinkExecutionRuntime.ProviderInputRouteReadiness
    typealias ProviderInputRouteWait = AgentSessionLinkExecutionRuntime.ProviderInputRouteWait
}
