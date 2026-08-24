import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class ContextBuilderOracleGroupStateTests: XCTestCase {
    func testTwoThreeAndFiveLaneRunsAcceptCompleteLifecycle() throws {
        for count in [2, 3, 5] {
            var fixture = try boundState(count: count)
            XCTAssertTrue(fixture.state.accept(
                event(.groupPrepared, fixture: fixture),
                generation: fixture.generation
            ))

            for member in fixture.members {
                XCTAssertTrue(fixture.state.accept(
                    event(.laneStarted, laneID: member.laneID, sequence: 0, fixture: fixture),
                    generation: fixture.generation
                ))
                XCTAssertTrue(fixture.state.accept(
                    event(.laneDelta, laneID: member.laneID, sequence: 1, fixture: fixture),
                    generation: fixture.generation
                ))
                XCTAssertTrue(fixture.state.acceptsLaneCallback(
                    member.laneID,
                    generation: fixture.generation
                ))
                XCTAssertTrue(fixture.state.accept(
                    event(.laneSettled, laneID: member.laneID, sequence: 2, fixture: fixture),
                    generation: fixture.generation
                ))
                XCTAssertFalse(fixture.state.acceptsLaneCallback(
                    member.laneID,
                    generation: fixture.generation
                ))
            }

            XCTAssertTrue(fixture.state.accept(
                event(.groupSettled, fixture: fixture),
                generation: fixture.generation
            ))
            XCTAssertFalse(fixture.state.accept(
                event(.groupSettled, fixture: fixture),
                generation: fixture.generation
            ))
        }
    }

    func testRejectsMalformedAndOutOfOrderLifecycleEvents() throws {
        var fixture = try boundState(count: 2)
        let primary = fixture.members[0].laneID
        let additional = fixture.members[1].laneID

        XCTAssertFalse(fixture.state.accept(
            event(.groupPrepared, laneID: primary, sequence: 0, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.groupPrepared, sequence: 0, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertTrue(fixture.state.accept(
            event(.groupPrepared, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.groupPrepared, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.laneStarted, laneID: primary, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.laneStarted, sequence: 0, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.laneDelta, laneID: primary, sequence: 0, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.laneSettled, laneID: primary, sequence: 0, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertTrue(fixture.state.accept(
            event(.laneStarted, laneID: primary, sequence: 0, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.laneStarted, laneID: primary, sequence: 1, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertTrue(fixture.state.accept(
            event(.laneDelta, laneID: primary, sequence: 1, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertTrue(fixture.state.accept(
            event(.laneSettled, laneID: primary, sequence: 2, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.acceptsLaneCallback(primary, generation: fixture.generation))
        XCTAssertFalse(fixture.state.accept(
            event(.laneSettled, laneID: primary, sequence: 3, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.laneDelta, laneID: primary, sequence: 3, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.groupSettled, fixture: fixture),
            generation: fixture.generation
        ))

        XCTAssertTrue(fixture.state.accept(
            event(.laneStarted, laneID: additional, sequence: 0, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertTrue(fixture.state.accept(
            event(.laneSettled, laneID: additional, sequence: 1, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.groupSettled, laneID: additional, sequence: 2, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertTrue(fixture.state.accept(
            event(.groupSettled, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.accept(
            event(.laneDelta, laneID: additional, sequence: 2, fixture: fixture),
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.acceptsLaneCallback(additional, generation: fixture.generation))
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
                kind: .groupPrepared,
                groupID: newGroupID,
                turnID: newTurnID
            ),
            generation: newGeneration
        ))
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

    func testFinalResultMustMatchPreparedGroupAndOrderedChatIDs() throws {
        let fixture = try boundState(count: 3)
        let matching = try groupResult(
            groupID: fixture.groupID,
            chatIDs: fixture.members.map(\.chatID)
        )
        XCTAssertTrue(fixture.state.matchesFinalResult(
            matching,
            generation: fixture.generation
        ))

        let wrongGroup = try groupResult(
            groupID: OracleGroupID(),
            chatIDs: fixture.members.map(\.chatID)
        )
        XCTAssertFalse(fixture.state.matchesFinalResult(
            wrongGroup,
            generation: fixture.generation
        ))

        let wrongCount = try groupResult(
            groupID: fixture.groupID,
            chatIDs: Array(fixture.members.prefix(2).map(\.chatID))
        )
        XCTAssertFalse(fixture.state.matchesFinalResult(
            wrongCount,
            generation: fixture.generation
        ))

        let wrongOrder = try groupResult(
            groupID: fixture.groupID,
            chatIDs: [
                fixture.members[1].chatID,
                fixture.members[0].chatID,
                fixture.members[2].chatID
            ]
        )
        XCTAssertFalse(fixture.state.matchesFinalResult(
            wrongOrder,
            generation: fixture.generation
        ))
        XCTAssertFalse(fixture.state.matchesFinalResult(
            matching,
            generation: fixture.generation &+ 1
        ))
    }

    private typealias Fixture = (
        state: ContextBuilderOracleGroupState,
        generation: UInt64,
        groupID: OracleGroupID,
        turnID: OracleTurnID,
        members: [ContextBuilderOracleMemberHandle]
    )

    private func boundState(count: Int) throws -> Fixture {
        var state = ContextBuilderOracleGroupState()
        let generation = state.beginRun()
        let groupID = OracleGroupID()
        let turnID = OracleTurnID()
        let members = try members(count: count, prefix: "chat")
        XCTAssertTrue(state.bind(
            groupID: groupID,
            turnID: turnID,
            members: members,
            generation: generation
        ))
        return (state, generation, groupID, turnID, members)
    }

    private func event(
        _ kind: OracleProgressKind,
        laneID: OracleLaneID? = nil,
        sequence: UInt64? = nil,
        fixture: Fixture
    ) -> OracleProgressEvent {
        OracleProgressEvent(
            kind: kind,
            groupID: fixture.groupID,
            turnID: fixture.turnID,
            laneID: laneID,
            sequence: sequence
        )
    }

    private func groupResult(
        groupID: OracleGroupID,
        chatIDs: [String]
    ) throws -> OracleGroupResult {
        let results = try chatIDs.enumerated().map { index, chatID in
            try OracleLaneResult(
                laneIndex: index,
                chatID: chatID,
                providerID: nil,
                modelID: "model-\(index)",
                status: .completed,
                response: "response-\(index)"
            )
        }
        return try OracleGroupResult(
            groupID: groupID,
            status: .completed,
            oracleResults: results
        )
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
