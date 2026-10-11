import Foundation
import MCP
import RepoPromptDomainRuntime

// The exact client-shaped oversight catalog for one run, projected onto the MainActor.
// Owns its route token, monotonic revision, expected/returned surface evidence and wait outcome.
// `MCPConnectionManager` publishes; the view model accepts under its run/endpoint fence for
// discovery and bounded idle repair, never send admission. Surface equality includes withdrawal,
// bootstrap and same-name schema changes. Unknown evidence proves neither mismatch nor healing.
// `isReady` remains exact-route + tool presence + outbound membership, never activation authority.

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
    /// Exact live membership in either direction; catalog reachability, never outbound authority.
    let hasAnyActiveLink: Bool?
    let hasActiveOutboundLink: Bool?
    /// Exact serialized oversight-family definitions; nil is unknown, an empty array is withdrawal.
    let expectedSurface: Data?
    let returnedSurface: Data?

    init(
        runID: UUID,
        routeToken: AgentSessionLinkRunCatalogRouteToken?,
        projectionRevision: UInt64,
        hasAgentSessionLink: Bool?,
        hasAnyActiveLink: Bool?,
        hasActiveOutboundLink: Bool? = true,
        expectedSurface: Data? = nil,
        returnedSurface: Data? = nil
    ) {
        self.runID = runID
        self.routeToken = routeToken
        self.projectionRevision = projectionRevision
        self.hasAgentSessionLink = hasAgentSessionLink
        self.hasAnyActiveLink = hasAnyActiveLink
        self.hasActiveOutboundLink = hasActiveOutboundLink
        self.expectedSurface = expectedSurface
        self.returnedSurface = returnedSurface
    }

    var isReady: Bool {
        routeToken != nil && hasAgentSessionLink == true && hasActiveOutboundLink == true
    }
}

/// Fingerprints the actual client-shaped definitions, not tool-name presence or grant membership.
/// Kept internal: no MCP wire fields and no authority are introduced.
enum AgentSessionLinkCatalogSurface {
    static func fingerprint(_ tools: [MCP.Tool]) throws -> Data {
        let family = tools.filter {
            $0.name == MCPWindowToolName.agentSessionLink || $0.name == MCPWindowToolName.becomeOverseer
        }.sorted { $0.name < $1.name }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(family)
    }
}

enum AgentSessionLinkRunCatalogWaitOutcome: Equatable {
    case ready(AgentSessionLinkRunCatalogProjection)
    case superseded
    case timedOut
    case cancelled
}
