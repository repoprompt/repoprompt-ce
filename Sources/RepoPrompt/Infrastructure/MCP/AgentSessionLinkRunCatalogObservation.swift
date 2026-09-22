import Foundation
import RepoPromptDomainRuntime

// The server-side observation of whether one run's returned MCP catalog actually carries
// `agent_session_link`, projected onto the MainActor.
//
// Owns the exact route token (run, observer endpoint, connection, routing and lifecycle
// generations) a catalog was observed against, the projection with its monotonic revision, and the
// wait outcome. `MCPConnectionManager` publishes projections; `AgentModeViewModel+SessionLinkPrompt`
// accepts them under a run/route identity guard and fails the prompt context closed while a ready
// projection is absent; `AgentSessionLinkCodexCatalogRepair` names the one stuck shape
// (`hasAgentSessionLink == false` with a live outbound grant) that nothing else will heal.
// Invariant: `isReady` requires an exact route token *and* positive presence on both axes — an
// unknown (`nil`) presence is not evidence of anything.

/// Exact server-owned route identity that a returned MCP catalog was observed against.
struct AgentSessionLinkRunCatalogRouteToken: Equatable, Hashable {
    let runID: UUID
    let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    let connectionID: UUID
    let routingAuthorityGeneration: UInt64
    let connectionLifecycleGeneration: UInt64
}

/// MainActor projection of the server's latest exact catalog observation for one run.
struct AgentSessionLinkRunCatalogProjection: Equatable {
    let runID: UUID
    let routeToken: AgentSessionLinkRunCatalogRouteToken?
    let projectionRevision: UInt64
    let hasAgentSessionLink: Bool?
    let hasActiveOutboundLink: Bool?

    init(
        runID: UUID,
        routeToken: AgentSessionLinkRunCatalogRouteToken?,
        projectionRevision: UInt64,
        hasAgentSessionLink: Bool?,
        hasActiveOutboundLink: Bool? = true
    ) {
        self.runID = runID
        self.routeToken = routeToken
        self.projectionRevision = projectionRevision
        self.hasAgentSessionLink = hasAgentSessionLink
        self.hasActiveOutboundLink = hasActiveOutboundLink
    }

    var isReady: Bool {
        routeToken != nil && hasAgentSessionLink == true && hasActiveOutboundLink == true
    }
}

enum AgentSessionLinkRunCatalogWaitOutcome: Equatable {
    case ready(AgentSessionLinkRunCatalogProjection)
    case superseded
    case timedOut
    case cancelled
}
