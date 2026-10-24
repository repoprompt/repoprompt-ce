import Foundation
import RepoPromptDomainRuntime

extension ContextBuilderOracleGroupProgressProjection {
    /// Project only live members of this run, never the configured roster or another group's streams.
    static func streamingLabel(
        members: [ContextBuilderOracleMemberHandle],
        streamingSessionIDs: Set<UUID>
    ) -> String? {
        let labels = members.filter { streamingSessionIDs.contains($0.sessionID) }.map {
            OracleRosterContract.displayLabel(laneIndex: $0.laneID.index)
        }
        guard !labels.isEmpty else { return nil }
        return "\(labels.joined(separator: ", ")) streaming..."
    }
}
