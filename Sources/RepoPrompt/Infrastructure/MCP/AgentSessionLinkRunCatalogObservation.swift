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

    /// An offer may survive a benign policy renewal, never another client or observer incarnation.
    func hasSameClientIncarnation(as other: Self) -> Bool {
        runID == other.runID && observerEndpoint == other.observerEndpoint
            && connectionID == other.connectionID
            && connectionLifecycleGeneration == other.connectionLifecycleGeneration
    }
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
    /// Actual client-shaped returned definitions, grouped by exact name once at observation ingress.
    /// Preserve all values and duplicates in this same immutable slot; no support cache or registry.
    /// Evidence only, separate from repair fingerprints; cleared on invalidation/overlap/teardown.
    let returnedCatalog: [String: [MCP.Tool]]?
    let offerInputs: MCPRunCatalogOfferInputs?
    let offerExpiresAt: Date?

    init(
        runID: UUID,
        routeToken: AgentSessionLinkRunCatalogRouteToken?,
        projectionRevision: UInt64,
        hasAgentSessionLink: Bool?,
        hasAnyActiveLink: Bool?,
        hasActiveOutboundLink: Bool? = true,
        expectedSurface: Data? = nil,
        returnedSurface: Data? = nil,
        returnedCatalog: [String: [MCP.Tool]]? = nil,
        offerInputs: MCPRunCatalogOfferInputs? = nil,
        offerExpiresAt: Date? = nil
    ) {
        self.runID = runID
        self.routeToken = routeToken
        self.projectionRevision = projectionRevision
        self.hasAgentSessionLink = hasAgentSessionLink
        self.hasAnyActiveLink = hasAnyActiveLink
        self.hasActiveOutboundLink = hasActiveOutboundLink
        self.expectedSurface = expectedSurface
        self.returnedSurface = returnedSurface
        self.returnedCatalog = returnedCatalog
        self.offerInputs = offerInputs
        self.offerExpiresAt = offerExpiresAt
    }

    /// Positive definition evidence, not a role, dispatch grant or attempt authorization.
    /// The server query qualifies the latest revision and exact live route before using it.
    func containsReturnedTool(_ definition: MCP.Tool) -> Bool {
        guard let matches = returnedCatalog?[definition.name], matches.count == 1 else { return false }
        return matches[0] == definition
    }

    /// Mirror-side necessary condition only; the server also revalidates all input revisions and
    /// current route authorization. The actual offer's original generation is never rewritten.
    var hasUnchangedOffer: Bool {
        hasUnchangedOffer(at: Date())
    }

    func hasUnchangedOffer(at date: Date) -> Bool {
        offerInputs?.advertisementRevision == ServerNetworkManager.catalogAdvertisementRevision
            && (offerExpiresAt.map { date < $0 } ?? true)
    }

    var isReady: Bool {
        routeToken != nil && hasAgentSessionLink == true && hasActiveOutboundLink == true
    }
}

/// Fingerprints the actual client-shaped definitions, not tool-name presence or grant membership.
/// Kept internal: no MCP wire fields and no authority are introduced.
enum AgentSessionLinkCatalogSurface {
    static let toolNames: Set<String> = [
        MCPWindowToolName.agentSessionLink,
        MCPWindowToolName.becomeOverseer,
        MCPWindowToolName.sessionAdmin
    ]

    static func fingerprint(_ tools: [MCP.Tool]) throws -> Data {
        let family = tools.filter {
            toolNames.contains($0.name)
        }.sorted { $0.name < $1.name }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(family)
    }

    /// A disabled oversight family must not prevent repair of an independently granted
    /// administration tool. Compare its actual client-shaped definition, including withdrawal;
    /// unknown evidence cannot justify replacing a provider.
    static func differs(toolName: String, expected: Data?, returned: Data?) -> Bool {
        guard let expectedTools = definitions(in: expected),
              let returnedTools = definitions(in: returned) else { return false }
        let expectedTool = expectedTools.first { $0["name"] as? String == toolName }
            .map { NSDictionary(dictionary: $0) }
        let returnedTool = returnedTools.first { $0["name"] as? String == toolName }
            .map { NSDictionary(dictionary: $0) }
        return expectedTool != returnedTool
    }

    private static func definitions(in data: Data?) -> [[String: Any]]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }
}

enum AgentSessionLinkRunCatalogWaitOutcome: Equatable {
    case ready(AgentSessionLinkRunCatalogProjection)
    case superseded
    case timedOut
    case cancelled
}
