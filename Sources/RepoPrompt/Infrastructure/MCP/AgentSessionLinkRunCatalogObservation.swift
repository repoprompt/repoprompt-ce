import Foundation
import RepoPromptDomainRuntime

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
