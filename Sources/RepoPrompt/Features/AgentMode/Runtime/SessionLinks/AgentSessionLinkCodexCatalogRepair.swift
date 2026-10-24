import Foundation

/// Vocabulary for the bounded, one-shot recovery of a Codex run whose *returned* MCP catalog is
/// stuck on an old oversight surface (including activation without links and same-name upgrades).
///
/// Ordinary invalidation preserves returned evidence and recomputes expected client-shaped
/// definitions. Explicit activation and inbound-to-outbound upgrades therefore open the same
/// existing cycle even when there is no grant or the tool name is already present.
/// Membership and prompt authority remain separate from discovery.
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

    /// Exact client-shaped expected/returned definitions disagree. Legacy test observations without
    /// either fingerprint retain their presence-only interpretation.
    ///
    /// Both halves must be *exact current observations*. An unknown (`nil`) presence on either side
    /// is not a mismatch; it is a route torn down or not yet observed, which is not evidence of
    /// anything.
    static func isStuckProjection(_ projection: AgentSessionLinkRunCatalogProjection) -> Bool {
        if let expected = projection.expectedSurface, let returned = projection.returnedSurface {
            return expected != returned
        }
        guard projection.expectedSurface == nil, projection.returnedSurface == nil else { return false }
        return projection.hasAgentSessionLink == false && projection.hasAnyActiveLink == true
    }

    /// Exact surface equality ends the cycle, including withdrawal and activation-only full.
    /// A partly unknown fingerprint never opens or closes a cycle.
    ///
    /// Deliberately not the negation of `isStuckProjection`: an unknown observation closes nothing
    /// and leaves a cycle pending, because it is not evidence that the catalog healed.
    static func projectionResolvesCycle(_ projection: AgentSessionLinkRunCatalogProjection) -> Bool {
        if let expected = projection.expectedSurface, let returned = projection.returnedSurface {
            return expected == returned
        }
        guard projection.expectedSurface == nil, projection.returnedSurface == nil else { return false }
        return projection.hasAgentSessionLink == true || projection.hasAnyActiveLink == false
    }
}
