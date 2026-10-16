@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class ContextBuilderOracleGroupStreamingProgressTests: XCTestCase {
    func testStreamingLabelTracksAuxiliariesAfterPrimaryStops() throws {
        let members = try makeMembers()
        var streamingSessionIDs = Set(members.map(\.sessionID))
        XCTAssertEqual(
            ContextBuilderOracleGroupProgressProjection.streamingLabel(
                members: members, streamingSessionIDs: streamingSessionIDs
            ),
            "Oracle, Oracle 2, Oracle 3 streaming..."
        )

        streamingSessionIDs.remove(members[0].sessionID)
        XCTAssertEqual(
            ContextBuilderOracleGroupProgressProjection.streamingLabel(
                members: members, streamingSessionIDs: streamingSessionIDs
            ),
            "Oracle 2, Oracle 3 streaming..."
        )

        streamingSessionIDs.remove(members[1].sessionID)
        XCTAssertEqual(
            ContextBuilderOracleGroupProgressProjection.streamingLabel(
                members: members, streamingSessionIDs: streamingSessionIDs
            ),
            "Oracle 3 streaming..."
        )
    }

    func testStreamingLabelIgnoresUnrelatedSessionsAndPreservesLaneIdentity() throws {
        let members = try makeMembers()
        let unrelatedMembers = try makeMembers()
        let streamingSessionIDs = Set(unrelatedMembers.map(\.sessionID) + [members[2].sessionID])
        XCTAssertEqual(
            ContextBuilderOracleGroupProgressProjection.streamingLabel(
                members: members, streamingSessionIDs: streamingSessionIDs
            ),
            "Oracle 3 streaming..."
        )
    }

    func testStreamingLabelIsAbsentWhenBoundGroupHasNoLiveStreams() throws {
        let members = try makeMembers()
        let unrelatedMembers = try makeMembers()
        XCTAssertNil(ContextBuilderOracleGroupProgressProjection.streamingLabel(
            members: members, streamingSessionIDs: Set(unrelatedMembers.map(\.sessionID))
        ))
        XCTAssertNil(ContextBuilderOracleGroupProgressProjection.streamingLabel(
            members: members, streamingSessionIDs: []
        ))
    }

    func testStreamingLabelIsAbsentBeforeBindingAndAfterCleanup() throws {
        let members = try makeMembers()
        XCTAssertNil(ContextBuilderOracleGroupProgressProjection.streamingLabel(
            members: [], streamingSessionIDs: Set(members.map(\.sessionID))
        ))
    }

    private func makeMembers() throws -> [ContextBuilderOracleMemberHandle] {
        try (0 ..< 3).map { index in
            try ContextBuilderOracleMemberHandle(
                laneID: OracleLaneID(index: index), sessionID: UUID(), chatID: "chat-\(index)"
            )
        }
    }
}
