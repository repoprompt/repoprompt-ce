import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class ContextBuilderOracleGroupStateTests: XCTestCase {
    func testTwoThreeAndFiveLaneRunsFenceStaleAndOutOfOrderProgress() throws {
        for count in [2, 3, 5] {
            var state = ContextBuilderOracleGroupState()
            let generation = state.beginRun()
            let groupID = OracleGroupID()
            let turnID = OracleTurnID()
            let members = try (0 ..< count).map { index in
                try ContextBuilderOracleMemberHandle(
                    laneID: OracleLaneID(index: index),
                    sessionID: UUID(),
                    chatID: "chat-\(index)"
                )
            }

            XCTAssertTrue(state.bind(
                groupID: groupID,
                turnID: turnID,
                members: members,
                generation: generation
            ))
            let first = OracleProgressEvent(
                kind: .laneDelta,
                groupID: groupID,
                turnID: turnID,
                laneID: members[0].laneID,
                sequence: 0,
                text: "first"
            )
            XCTAssertTrue(state.accept(first, generation: generation))
            XCTAssertFalse(state.accept(first, generation: generation), "duplicate sequence must be rejected")

            let cancelled = state.invalidateAndTakeMembers()
            XCTAssertEqual(cancelled, members)
            XCTAssertFalse(state.accept(
                OracleProgressEvent(
                    kind: .laneDelta,
                    groupID: groupID,
                    turnID: turnID,
                    laneID: members[0].laneID,
                    sequence: 1,
                    text: "stale"
                ),
                generation: generation
            ))
        }
    }

    func testReplacementAcceptsOnlyNewGenerationAndMembers() throws {
        var state = ContextBuilderOracleGroupState()
        let oldGeneration = state.beginRun()
        let oldMembers = try members(count: 2, prefix: "old")
        XCTAssertTrue(state.bind(
            groupID: OracleGroupID(),
            turnID: OracleTurnID(),
            members: oldMembers,
            generation: oldGeneration
        ))
        _ = state.invalidateAndTakeMembers()

        let newGeneration = state.beginRun()
        let newGroupID = OracleGroupID()
        let newTurnID = OracleTurnID()
        let newMembers = try members(count: 3, prefix: "new")
        XCTAssertTrue(state.bind(
            groupID: newGroupID,
            turnID: newTurnID,
            members: newMembers,
            generation: newGeneration
        ))
        XCTAssertFalse(state.acceptsLaneCallback(oldMembers[0].laneID, generation: oldGeneration))
        XCTAssertTrue(state.acceptsLaneCallback(newMembers[2].laneID, generation: newGeneration))
        XCTAssertTrue(state.accept(
            OracleProgressEvent(
                kind: .laneStarted,
                groupID: newGroupID,
                turnID: newTurnID,
                laneID: newMembers[2].laneID,
                sequence: 0
            ),
            generation: newGeneration
        ))
    }

    private func members(count: Int, prefix: String) throws -> [ContextBuilderOracleMemberHandle] {
        try (0 ..< count).map { index in
            try ContextBuilderOracleMemberHandle(
                laneID: OracleLaneID(index: index),
                sessionID: UUID(),
                chatID: "\(prefix)-\(index)"
            )
        }
    }
}
