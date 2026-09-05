import Foundation

/// Vocabulary for the bounded, one-shot recovery of a Codex run whose *returned* MCP catalog is
/// stuck saying `agent_session_link` is absent while the link authority holds a live outbound grant.
///
/// The state is produced by ordinary code: `notifyToolListChangedForAgentSession` republishes the
/// observation with returned presence preserved and outbound presence recomputed, so a grant restored
/// against a live run whose client has not re-read `tools/list` lands on exactly
/// `hasAgentSessionLink == false` plus `hasActiveOutboundLink == true`. For any established run the
/// prompt context then fails closed, and nothing else will ever republish a healed catalog.
///
/// This file owns only the two predicates and the cycle value. The projection reconciler in
/// `AgentModeViewModel+SessionLinkPrompt` opens and closes a cycle; `CodexAgentModeCoordinator`
/// spends it (one controller replacement, or one stranded-run retirement) once the session is
/// quiescent; `agentSessionLinkRedriveCurrentPassiveSnapshot` re-admits the queue afterwards. The
/// cycle is keyed on the Codex controller generation rather than a Boolean so that surviving a
/// generation rotation *is* the record that some replacement already happened — which is what
/// bounds the repair to one replacement per cycle without instrumenting every teardown route.
enum AgentSessionLinkCodexCatalogRepair {
    /// One repair cycle, recorded as the controller generation the stuck projection was observed
    /// against.
    ///
    /// Compared with the session's current `codexControllerGeneration`, the value has two states,
    /// and `nil` on the session is the third (no cycle):
    ///
    /// | Comparison | State | Meaning |
    /// | --- | --- | --- |
    /// | equal | `.pending` | the one replacement this cycle allows is still owed |
    /// | different | `.spent` | some reconnect already rotated the controller; only re-drive |
    ///
    /// The spent state is written by nobody: `codexController.didSet` rotates the generation on
    /// every identity change. That is also why a cycle must never be cleared from controller
    /// teardown — clearing it there would erase the evidence and let a later projection revision or
    /// terminal commit replace a second time. Never persisted: it names a live process-local
    /// generation.
    struct Cycle: Equatable {
        let observedControllerGeneration: UUID

        enum State: Equatable {
            case pending
            case spent
        }

        func state(currentControllerGeneration: UUID) -> State {
            observedControllerGeneration == currentControllerGeneration ? .pending : .spent
        }
    }

    /// The exact mismatch this repair exists for: the returned catalog says the tool is absent while
    /// the authority says this endpoint still holds a live outbound grant.
    ///
    /// Both halves must be *exact current observations*. An unknown (`nil`) presence on either side
    /// is not a mismatch; it is a route torn down or not yet observed, which is not evidence of
    /// anything.
    static func isStuckProjection(_ projection: AgentSessionLinkRunCatalogProjection) -> Bool {
        projection.hasAgentSessionLink == false && projection.hasActiveOutboundLink == true
    }

    /// An exact current observation that ends any open cycle as *over* rather than spent: the tool
    /// is back in the returned catalog, or the endpoint no longer holds an outbound grant to repair
    /// for.
    ///
    /// Deliberately not the negation of `isStuckProjection`: an unknown observation closes nothing
    /// and leaves a cycle pending, because it is not evidence that the catalog healed.
    static func projectionResolvesCycle(_ projection: AgentSessionLinkRunCatalogProjection) -> Bool {
        projection.hasAgentSessionLink == true || projection.hasActiveOutboundLink == false
    }
}
