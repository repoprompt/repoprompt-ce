import Foundation
import RepoPromptDomainRuntime
import RepoPromptMCPServer

/// The synchronous run/connection projection used by provider-input admission. This is
/// shared storage, not a second routing authority: DomainRoutingCoordinator still owns
/// domain bindings, and the transport's live-connection fence is checked separately.
/// Runtime hosts can retain this owner without retaining an MCP presentation model.
@MainActor
final class MCPRunRouteBindings {
    /// Availability of the composition that can retract/publish these mappings. This
    /// is not domain admission: losing it only refuses dispatch. A runtime host owns
    /// it independently of presentation; the legacy server owns it until host cutover.
    final class OwnerLifetime {}

    private weak var ownerLifetime: OwnerLifetime?

    init(ownerLifetime: OwnerLifetime) {
        self.ownerLifetime = ownerLifetime
    }

    struct PendingPolicyToken {
        let id: UUID
        let connectionID: UUID
        let runID: UUID
        let displacedConnectionID: UUID?
        let displacedConnectionRunID: UUID?
        let displacedPendingPolicyTokenID: UUID?
        let previousRunID: UUID?
        let previousRunPrimaryConnectionID: UUID?
        let previousPendingPolicyTokenID: UUID?
        let previousWindowID: Int?
        var promotedContext: MCPTabContextSnapshot?
        var promotedContextClientName: String?
        var promotedContextWindowID: Int?
    }

    enum RegistrationResult: Equatable {
        case registered(displacedConnectionID: UUID?)
        case refusedBoundRun(UUID)
        case refusedWindow(Int)
        case refusedOwnerUnavailable
    }

    struct DetachedContextBuilderTabContext {
        let connectionID: UUID
        let context: MCPTabContextSnapshot
    }

    /// Immutable predecessor lanes retain the exact connection and selection generation.
    struct ReadFileAutoSelectionHandoverLineage {
        let successorKey: MCPReadFileAutoSelectionCoordinator.ContextKey
        let predecessorKeys: [MCPReadFileAutoSelectionCoordinator.ContextKey]
    }

    var pendingRunScopedTabContexts = PendingRunScopedContextStore()
    var lastContextByClientAndWindow: [String: [Int: MCPTabContextSnapshot]] = [:]
    var readFileAutoSelectionHandoverLineageByConnectionID: [UUID: ReadFileAutoSelectionHandoverLineage] = [:]
    var nextReadFileAutoSelectionBindingGeneration: UInt64 = 0
    var detachedContextBuilderTabContextByRunID: [UUID: DetachedContextBuilderTabContext] = [:]
    var tabContextByConnectionID: [UUID: MCPTabContextSnapshot] = [:]
    var connectionIDByRunID: [UUID: UUID] = [:]
    var connectionIDToRunID: [UUID: UUID] = [:]
    var pendingPolicyTokenIDByRunID: [UUID: UUID] = [:]
    var presentationWindowByConnection: [UUID: Int] = [:]

    func connectionID(forRunID runID: UUID) -> UUID? {
        guard let connectionID = connectionIDByRunID[runID],
              connectionIDToRunID[connectionID] == runID else { return nil }
        return connectionID
    }

    /// Includes displaced reverse mappings so teardown finds only this run's connections.
    func connectionIDs(forRunID runID: UUID) -> [UUID] {
        var ids: [UUID] = []
        if let primary = connectionIDByRunID[runID] { ids.append(primary) }
        for (connectionID, mappedRun) in connectionIDToRunID where mappedRun == runID {
            if !ids.contains(connectionID) { ids.append(connectionID) }
        }
        return ids
    }

    func liveRunIDsBound(toTabID tabID: UUID) -> [UUID] {
        let runIDs = tabContextByConnectionID.values.compactMap { context -> UUID? in
            guard context.tabID == tabID, let runID = context.runID else { return nil }
            return connectionID(forRunID: runID) != nil ? runID : nil
        }
        return Array(Set(runIDs)).sorted { $0.uuidString < $1.uuidString }
    }

    func hasCurrentMapping(runID: UUID, connectionID: UUID, expectedTabID: UUID? = nil) -> Bool {
        guard ownerLifetime != nil,
              connectionIDByRunID[runID] == connectionID,
              connectionIDToRunID[connectionID] == runID
        else { return false }
        guard let expectedTabID else { return true }
        guard let context = tabContextByConnectionID[connectionID] else { return false }
        return context.runID == runID && context.tabID == expectedTabID
    }

    /// This is the final synchronous fence after actor-qualified dispatch, not a
    /// replacement for domain admission or stable-input proof.
    func hasCurrentCatalogRouteToken(_ token: AgentSessionLinkRunCatalogRouteToken, expectedTabID: UUID) -> Bool {
        ownerLifetime != nil
            && token.observerEndpoint.tabID == expectedTabID
            && hasCurrentMapping(runID: token.runID, connectionID: token.connectionID, expectedTabID: expectedTabID)
            && ServerNetworkManager.shared.hasLiveProviderInputConnection(token)
    }

    func register(connectionID: UUID, runID: UUID, windowID: Int) -> RegistrationResult {
        guard ownerLifetime != nil else { return .refusedOwnerUnavailable }
        if connectionIDByRunID[runID] == connectionID,
           connectionIDToRunID[connectionID] == runID
        {
            pendingPolicyTokenIDByRunID.removeValue(forKey: runID)
            presentationWindowByConnection[connectionID] = windowID
            return .registered(displacedConnectionID: nil)
        }
        if let boundRun = tabContextByConnectionID[connectionID]?.runID, boundRun != runID {
            return .refusedBoundRun(boundRun)
        }
        let displaced = connectionIDByRunID[runID].flatMap { $0 == connectionID ? nil : $0 }
        if let displaced {
            if let existingWindow = presentationWindowByConnection[displaced], existingWindow != windowID {
                return .refusedWindow(existingWindow)
            }
            connectionIDToRunID.removeValue(forKey: displaced)
        }
        if let previous = connectionIDToRunID[connectionID], previous != runID {
            connectionIDByRunID.removeValue(forKey: previous)
        }
        presentationWindowByConnection[connectionID] = windowID
        connectionIDByRunID[runID] = connectionID
        connectionIDToRunID[connectionID] = runID
        pendingPolicyTokenIDByRunID.removeValue(forKey: runID)
        return .registered(displacedConnectionID: displaced)
    }

    func beginPendingPolicy(connectionID: UUID, runID: UUID, windowID: Int) -> PendingPolicyToken? {
        guard ownerLifetime != nil else { return nil }
        if let boundRun = tabContextByConnectionID[connectionID]?.runID, boundRun != runID { return nil }
        let displacedConnectionID = connectionIDByRunID[runID]
        if let displacedConnectionID, displacedConnectionID != connectionID,
           let existingWindow = presentationWindowByConnection[displacedConnectionID], existingWindow != windowID
        { return nil }
        let previousRunID = connectionIDToRunID[connectionID]
        let token = PendingPolicyToken(
            id: UUID(), connectionID: connectionID, runID: runID,
            displacedConnectionID: displacedConnectionID == connectionID ? nil : displacedConnectionID,
            displacedConnectionRunID: displacedConnectionID.flatMap { connectionIDToRunID[$0] },
            displacedPendingPolicyTokenID: pendingPolicyTokenIDByRunID[runID],
            previousRunID: previousRunID,
            previousRunPrimaryConnectionID: previousRunID.flatMap { connectionIDByRunID[$0] },
            previousPendingPolicyTokenID: previousRunID.flatMap { pendingPolicyTokenIDByRunID[$0] },
            previousWindowID: presentationWindowByConnection[connectionID]
        )
        if let displacedConnectionID = token.displacedConnectionID,
           connectionIDToRunID[displacedConnectionID] == runID
        { connectionIDToRunID.removeValue(forKey: displacedConnectionID) }
        if let previousRunID, previousRunID != runID, connectionIDByRunID[previousRunID] == connectionID {
            connectionIDByRunID.removeValue(forKey: previousRunID)
            pendingPolicyTokenIDByRunID.removeValue(forKey: previousRunID)
        }
        presentationWindowByConnection[connectionID] = windowID
        connectionIDByRunID[runID] = connectionID
        connectionIDToRunID[connectionID] = runID
        pendingPolicyTokenIDByRunID[runID] = token.id
        return token
    }

    func isCurrent(_ token: PendingPolicyToken) -> Bool {
        pendingPolicyTokenIDByRunID[token.runID] == token.id
            && connectionIDByRunID[token.runID] == token.connectionID
            && connectionIDToRunID[token.connectionID] == token.runID
    }

    /// Generation-fenced synchronous rollback. Context publication and selection
    /// invalidation remain with their existing owners, and cannot suspend between
    /// consuming this token and restoring its displaced mappings.
    @discardableResult
    func rollback(_ token: PendingPolicyToken, removingContext: () -> Void) -> Bool {
        guard isCurrent(token) else { return false }
        pendingPolicyTokenIDByRunID.removeValue(forKey: token.runID)
        removingContext()
        if connectionIDByRunID[token.runID] == token.connectionID {
            connectionIDByRunID.removeValue(forKey: token.runID)
        }
        if connectionIDToRunID[token.connectionID] == token.runID {
            connectionIDToRunID.removeValue(forKey: token.connectionID)
        }
        if let displacedConnectionID = token.displacedConnectionID,
           token.displacedPendingPolicyTokenID == nil,
           token.displacedConnectionRunID == token.runID,
           connectionIDByRunID[token.runID] == nil,
           connectionIDToRunID[displacedConnectionID] == nil
        {
            connectionIDByRunID[token.runID] = displacedConnectionID
            connectionIDToRunID[displacedConnectionID] = token.runID
        } else if token.displacedConnectionID == nil {
            connectionIDByRunID.removeValue(forKey: token.runID)
        }
        if let previousRunID = token.previousRunID, token.previousPendingPolicyTokenID == nil {
            let currentPrimary = connectionIDByRunID[previousRunID]
            let unchanged = currentPrimary == token.previousRunPrimaryConnectionID
            let canRestore = token.previousRunPrimaryConnectionID == token.connectionID && currentPrimary == nil
            if unchanged || canRestore {
                connectionIDToRunID[token.connectionID] = previousRunID
                if canRestore { connectionIDByRunID[previousRunID] = token.connectionID }
            }
        } else {
            connectionIDToRunID.removeValue(forKey: token.connectionID)
        }
        let restoredPreviousRun = token.previousRunID.map { connectionIDToRunID[token.connectionID] == $0 } ?? true
        if restoredPreviousRun, let previousWindowID = token.previousWindowID {
            presentationWindowByConnection[token.connectionID] = previousWindowID
        } else {
            presentationWindowByConnection.removeValue(forKey: token.connectionID)
        }
        return true
    }
}
