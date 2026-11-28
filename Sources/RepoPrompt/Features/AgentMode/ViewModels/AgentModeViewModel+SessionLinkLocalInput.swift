import Foundation
import RepoPromptDomainRuntime

extension AgentSessionLinkExecutionRuntime {
    /// Exact memory-only target lookup. Never hydrates, materializes Read, or scans session history.
    func agentSessionLinkLocalInputSnapshot(
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        includeRecords: Bool
    ) -> AgentSessionLinkRetainedLocalInputIndex.Snapshot? {
        guard agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              let session = sessions[endpoint.tabID], session.hasLoadedPersistedState,
              !session.localInputCanonicalCommitPending,
              let snapshot = session.localInputIndex.snapshot else { return nil }
        if includeRecords { return snapshot }
        return .init(
            epoch: snapshot.epoch,
            revision: snapshot.revision,
            producedThrough: snapshot.producedThrough,
            droppedThrough: snapshot.droppedThrough,
            records: []
        )
    }
}

extension AgentModeViewModel {
    func agentSessionLinkLocalInputSnapshot(
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        includeRecords: Bool
    ) -> AgentSessionLinkRetainedLocalInputIndex.Snapshot? {
        linkExecutionRuntime.agentSessionLinkLocalInputSnapshot(for: endpoint, includeRecords: includeRecords)
    }
}
