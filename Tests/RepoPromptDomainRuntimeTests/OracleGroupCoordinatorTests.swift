import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class OracleGroupCoordinatorTests: XCTestCase {
    func testRejectsNoncontiguousLanePlans() async throws {
        let fixture = try makeFixture(count: 2)

        await XCTAssertOracleThrowsErrorAsync {
            _ = try await OracleGroupCoordinator().execute(
                group: fixture.group,
                turnID: OracleTurnID(),
                input: fixture.input,
                plans: [fixture.plans[1], fixture.plans[0]]
            )
        } verify: {
            XCTAssertEqual($0 as? OracleGroupCoordinatorError, .invalidLanePlan)
        }
    }

    func testFiveLanesReturnStableOrderAfterReverseCompletion() async throws {
        let fixture = try makeFixture(count: 5) { lane in
            try await Task.sleep(for: .milliseconds((5 - lane) * 10))
            return OracleLaneExecutionResponse(response: "lane-\(lane)")
        }
        let result = try await OracleGroupCoordinator().execute(
            group: fixture.group,
            turnID: OracleTurnID(),
            input: fixture.input,
            plans: fixture.plans
        )

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.oracleResults.map(\.laneIndex), [0, 1, 2, 3, 4])
        XCTAssertEqual(result.oracleResults.compactMap(\.response), [
            "lane-0", "lane-1", "lane-2", "lane-3", "lane-4"
        ])
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testSuccessfulExecutionProfileIsPersistedWithoutChangingRosterIdentity() async throws {
        let profile = try OracleExecutionProfile(
            providerID: "codex",
            modelID: "gpt-5.6-sol",
            effectiveReasoningEffort: "high"
        )
        let fixture = try makeFixture(count: 2) { lane in
            OracleLaneExecutionResponse(response: "lane-\(lane)", executionProfile: profile)
        }
        let result = try await OracleGroupCoordinator().execute(
            group: fixture.group,
            turnID: OracleTurnID(),
            input: fixture.input,
            plans: fixture.plans
        )

        XCTAssertEqual(result.oracleResults.map(\.modelID), Array(repeating: "duplicate-model", count: 2))
        XCTAssertEqual(result.oracleResults.map(\.executionProfile), Array(repeating: profile, count: 2))
    }

    func testAuxiliaryFailureAndEmptyResponseAreStructured() async throws {
        let profile = try OracleExecutionProfile(providerID: "runtime", modelID: "resolved")
        let fixture = try makeFixture(count: 5) { lane in
            if lane == 2 {
                throw OracleLaneFailure(
                    code: "fixture_failure",
                    message: "lane failed",
                    partialResponse: "partial",
                    executionProfile: profile
                )
            }
            if lane == 4 {
                return OracleLaneExecutionResponse(response: "  \n", executionProfile: profile)
            }
            return OracleLaneExecutionResponse(response: "lane-\(lane)", executionProfile: profile)
        }
        let result = try await OracleGroupCoordinator().execute(
            group: fixture.group,
            turnID: OracleTurnID(),
            input: fixture.input,
            plans: fixture.plans
        )

        XCTAssertEqual(result.status, .partialFailure)
        XCTAssertEqual(result.oracleResults[2].error?.code, "fixture_failure")
        XCTAssertEqual(result.oracleResults[2].error?.partialResponse, "partial")
        XCTAssertEqual(result.oracleResults[2].executionProfile, profile)
        XCTAssertEqual(result.oracleResults[4].error?.code, "empty_response")
        XCTAssertEqual(result.oracleResults[4].executionProfile, profile)
        XCTAssertEqual(
            result.warnings,
            [OracleGroupWarning(code: "lane_failures", message: "Two lanes did not complete")]
        )
    }

    func testTypedCancellationPreservesResolvedExecutionProfile() async throws {
        let profile = try OracleExecutionProfile(providerID: "runtime", modelID: "resolved")
        let fixture = try makeFixture(count: 2) { lane in
            if lane == 1 { throw OracleLaneCancellation(executionProfile: profile) }
            return OracleLaneExecutionResponse(response: "primary", executionProfile: profile)
        }
        let result = try await OracleGroupCoordinator().execute(
            group: fixture.group,
            turnID: OracleTurnID(),
            input: fixture.input,
            plans: fixture.plans
        )

        XCTAssertEqual(result.status, .partialFailure)
        XCTAssertEqual(result.oracleResults[1].status, .cancelled)
        XCTAssertEqual(result.oracleResults[1].executionProfile, profile)
        XCTAssertEqual(
            result.warnings,
            [OracleGroupWarning(code: "lane_failures", message: "One lane did not complete")]
        )
    }

    func testPrimaryFailureMakesGroupFailed() async throws {
        let fixture = try makeFixture(count: 2) { lane in
            if lane == 0 { throw OracleLaneFailure(message: "primary failed") }
            return OracleLaneExecutionResponse(response: "auxiliary")
        }
        let result = try await OracleGroupCoordinator().execute(
            group: fixture.group,
            turnID: OracleTurnID(),
            input: fixture.input,
            plans: fixture.plans
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.primary.status, .failed)
        XCTAssertEqual(result.oracleResults[1].status, .completed)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testLateDetachedProgressIsSuppressedAfterTerminalReturn() async throws {
        let fixture = try makeFixture(count: 2)
        let progress = OracleProgressRecorder()
        var plans = fixture.plans
        plans[0] = try OracleLanePlan(
            lane: fixture.plans[0].lane,
            publicChatID: fixture.plans[0].publicChatID,
            operation: { context in
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    await context.emitDelta("late")
                }
                return OracleLaneExecutionResponse(response: "primary")
            }
        )
        _ = try await OracleGroupCoordinator().execute(
            group: fixture.group,
            turnID: OracleTurnID(),
            input: fixture.input,
            plans: plans,
            progress: { await progress.record($0) }
        )
        let eventsAtReturn = await progress.events()
        try await Task.sleep(for: .milliseconds(100))
        let eventsAfterLateEmitter = await progress.events()
        XCTAssertEqual(eventsAfterLateEmitter, eventsAtReturn)
    }

    func testParentCancellationDrainsFiveLanesAndFencesProgress() async throws {
        let started = expectation(description: "all lanes started")
        started.expectedFulfillmentCount = 5
        let drained = expectation(description: "all lanes drained")
        drained.expectedFulfillmentCount = 5
        let progress = OracleProgressRecorder()
        let fixture = try makeFixture(count: 5) { lane in
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(60))
                return OracleLaneExecutionResponse(response: "unexpected-\(lane)")
            } catch {
                drained.fulfill()
                throw error
            }
        }
        let task = Task {
            try await OracleGroupCoordinator().execute(
                group: fixture.group,
                turnID: OracleTurnID(),
                input: fixture.input,
                plans: fixture.plans,
                progress: { await progress.record($0) }
            )
        }

        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.oracleResults.map(\.status), Array(repeating: .cancelled, count: 5))
        await fulfillment(of: [drained], timeout: 2)
        let eventsAtReturn = await progress.events()
        try await Task.sleep(for: .milliseconds(20))
        let eventsAfterDelay = await progress.events()
        XCTAssertEqual(eventsAfterDelay, eventsAtReturn)

        for lane in 0 ..< 5 {
            let laneEvents = eventsAtReturn.filter { $0.laneID?.index == lane }
            XCTAssertEqual(laneEvents.count(where: { $0.kind == .laneSettled }), 1)
            XCTAssertEqual(laneEvents.compactMap(\.sequence), Array(0 ..< UInt64(laneEvents.count)))
        }
    }

    private func makeFixture(
        count: Int,
        operation: @escaping @Sendable (Int) async throws -> OracleLaneExecutionResponse = {
            OracleLaneExecutionResponse(response: "lane-\($0)")
        }
    ) throws -> (group: OracleGroupDescriptor, input: OracleInput, plans: [OracleLanePlan]) {
        let group = try OracleGroupDescriptor(size: count)
        let input = try OracleInput(mode: .chat, userMessage: "Frozen input")
        let plans = try (0 ..< count).map { index in
            let laneID = try OracleLaneID(index: index)
            let model = try OracleModelReference(providerID: "fixture", modelID: "duplicate-model")
            return try OracleLanePlan(
                lane: OracleLaneDescriptor(group: group, laneID: laneID, model: model),
                publicChatID: "chat-\(index)",
                operation: { _ in try await operation(index) }
            )
        }
        return (group, input, plans)
    }
}

private actor OracleProgressRecorder {
    private var recorded: [OracleProgressEvent] = []

    func record(_ event: OracleProgressEvent) {
        recorded.append(event)
    }

    func events() -> [OracleProgressEvent] {
        recorded
    }
}

private func XCTAssertOracleThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    verify: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        verify(error)
    }
}
