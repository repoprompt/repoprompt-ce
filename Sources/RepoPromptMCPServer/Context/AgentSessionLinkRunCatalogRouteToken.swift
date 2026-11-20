// Exported Swift 5 package values need explicit cross-module Sendable contracts.
// swiftformat:disable redundantSendable
import Foundation
import RepoPromptDomainRuntime

package struct AgentSessionLinkRunCatalogRouteToken: Equatable, Hashable, Sendable {
    package let runID: UUID
    package let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    package let connectionID: UUID
    package let routingAuthorityGeneration: UInt64
    package let connectionLifecycleGeneration: UInt64

    /// An offer may survive a benign policy renewal, never another client or observer incarnation.
    package func hasSameClientIncarnation(as other: Self) -> Bool {
        runID == other.runID && observerEndpoint == other.observerEndpoint
            && connectionID == other.connectionID
            && connectionLifecycleGeneration == other.connectionLifecycleGeneration
    }

    package init(
        runID: UUID,
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        connectionID: UUID,
        routingAuthorityGeneration: UInt64,
        connectionLifecycleGeneration: UInt64
    ) {
        self.runID = runID
        self.observerEndpoint = observerEndpoint
        self.connectionID = connectionID
        self.routingAuthorityGeneration = routingAuthorityGeneration
        self.connectionLifecycleGeneration = connectionLifecycleGeneration
    }
}
