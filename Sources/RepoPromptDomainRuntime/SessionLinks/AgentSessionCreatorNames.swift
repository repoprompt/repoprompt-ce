import Foundation

/// UI-only names. Exact endpoints determine membership, UUIDs determine descriptive first-match
/// names only. Never used for actions, grants, prompt inventory, passive delivery, or Auto-wake.
package struct AgentSessionCreatorNames {
    package struct Source: Equatable {
        package let workspaceID: UUID
        package let sessionID: UUID
        package let name: String

        package init(workspaceID: UUID, sessionID: UUID, name: String) {
            self.workspaceID = workspaceID
            self.sessionID = sessionID
            self.name = name
        }
    }

    package init() {}

    private var live: [(endpoint: DomainAgentSessionLinkEndpointIdentity, name: String)] = []
    private var retained: [UUID: String] = [:]
    private var retentionOrder: [UUID] = []
    package private(set) var snapshot: [UUID: String] = [:]
    package static let retentionLimit = 4096
    package var liveEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> {
        Set(live.map(\.endpoint))
    }

    package mutating func replaceLive(_ candidates: [AgentSessionLinkEndpointCandidate]) {
        live = candidates.filter { !$0.isClosing && !$0.isDeletionInProgress }.map {
            ($0.domainEndpoint, $0.resolvedDisplayName)
        }
        rebuild()
    }

    /// Synchronous capture matters: rename followed immediately by close must retain the new name.
    /// No candidate/provider/location reconstruction on a name-only mutation.
    package mutating func update(windowID: Int, sources: [UUID: Source]) {
        live = live.compactMap { entry in
            guard entry.endpoint.windowID == windowID else { return entry }
            guard let source = sources[entry.endpoint.tabID],
                  source.workspaceID == entry.endpoint.workspaceID,
                  source.sessionID == entry.endpoint.sessionID else { return nil }
            let trimmed = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return (entry.endpoint, trimmed.isEmpty ? AgentMonitorSessionIDFormatter.short(source.sessionID) : trimmed)
        }
        let liveIDs = Set(live.map(\.endpoint.sessionID))
        // An already-known remote creator can be renamed by a settled non-live local copy after
        // its window closes. Do not create membership, resurrect deletion, or override any live copy.
        for source in sources.values where retained[source.sessionID] != nil && !liveIDs.contains(source.sessionID) {
            let trimmed = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
            retained[source.sessionID] = trimmed.isEmpty ? AgentMonitorSessionIDFormatter.short(source.sessionID) : trimmed
        }
        rebuild()
    }

    package mutating func remove(_ sessionID: UUID) {
        live.removeAll { $0.endpoint.sessionID == sessionID }
        retained.removeValue(forKey: sessionID)
        retentionOrder.removeAll { $0 == sessionID }
        rebuild()
    }

    private mutating func rebuild() {
        var names: [UUID: String] = [:]
        for entry in live where names[entry.endpoint.sessionID] == nil {
            names[entry.endpoint.sessionID] = entry.name
        }
        // Bound retired names, not live names. A live name always wins even at capacity.
        for entry in live where names[entry.endpoint.sessionID] == entry.name {
            let id = entry.endpoint.sessionID
            if retained[id] == nil {
                retentionOrder.append(id)
            }
            retained[id] = entry.name
        }
        while retentionOrder.count > Self.retentionLimit {
            retained.removeValue(forKey: retentionOrder.removeFirst())
        }
        snapshot = retained.merging(names, uniquingKeysWith: { _, live in live })
    }
}
