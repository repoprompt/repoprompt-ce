import Foundation
import RepoPromptDomainRuntime

extension AgentModeViewModel {
    /// Exact memory-only target lookup. Never hydrates, materializes Read, or scans session history.
    func agentSessionLinkLocalInputSnapshot(
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        includeRecords: Bool
    ) -> AgentSessionLinkRetainedLocalInputIndex.Snapshot? {
        guard endpoint.windowID == windowID,
              let session = sessions[endpoint.tabID], session.hasLoadedPersistedState,
              session.activeAgentSessionID == endpoint.sessionID,
              agentSessionLifecycleIdentity(tabID: endpoint.tabID, expectedSessionID: endpoint.sessionID)?.monitorEndpoint(windowID: windowID) == endpoint,
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
