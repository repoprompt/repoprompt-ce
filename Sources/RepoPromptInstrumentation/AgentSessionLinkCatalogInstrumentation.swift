import Foundation

/// Closed diagnostic outcomes; callers cannot attach prompt, path, or provider payloads.
package enum AgentSessionLinkCatalogOutcome: String, Equatable, Sendable {
    case accepted
    case rejectedEndpointMismatch = "rejected-endpoint-mismatch"
    case rejectedMissingSession = "rejected-missing-session"
    case rejectedEndpointRebind = "rejected-endpoint-rebind"
    case rejectedRunMismatch = "rejected-run-mismatch"
    case rejectedStaleRevision = "rejected-stale-revision"
    case coalescedDuplicate = "coalesced-duplicate"
    case opened
    case closedCatalogPresent = "closed-catalog-present"
    case closedLinksLost = "closed-links-lost"
    case closedProviderChanged = "closed-provider-changed"
    case closedToolDisabled = "closed-tool-disabled"
    case spentReplaced = "spent-replaced"
    case spentStrandedRunRetired = "spent-stranded-run-retired"
}

/// The sink receives only identifiers, bounded generations, and closed presence/outcome values.
/// Hashing and local logging remain the app adapter's responsibility.
package enum AgentSessionLinkCatalogEvent: Sendable {
    case catalogPublished(
        runID: UUID,
        tabID: UUID?,
        connectionID: UUID?,
        revision: UInt64,
        routingGeneration: UInt64?,
        lifecycleGeneration: UInt64?,
        routePresent: Bool,
        catalog: Bool?,
        outbound: Bool?
    )
    case projectionEvaluated(
        runID: UUID,
        tabID: UUID,
        revision: UInt64,
        catalog: Bool?,
        outbound: Bool?,
        outcome: AgentSessionLinkCatalogOutcome
    )
    case repairTransition(runID: UUID?, tabID: UUID, outcome: AgentSessionLinkCatalogOutcome)
    case toolCallReceived(runID: UUID?, tabID: UUID?, connectionID: UUID)
}

package protocol AgentSessionLinkCatalogEventSink: Sendable {
    func record(_ event: AgentSessionLinkCatalogEvent)
}

package struct NoopAgentSessionLinkCatalogEventSink: AgentSessionLinkCatalogEventSink {
    package init() {}

    package func record(_: AgentSessionLinkCatalogEvent) {}
}
