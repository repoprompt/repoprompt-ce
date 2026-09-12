import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class PromptExperimentGradingTests: XCTestCase {
        func testInvalidJSONRepairsOnlyJudgeOnceAndCheckpointsBeforeEachInvocation() async throws {
            var events: [String] = []
            var calls = 0
            let result = try await PromptExperimentGrading.run(minimum: 0, maximum: 1, canRepair: true) { ordinal, state, _ in
                events.append("\(ordinal):\(state.rawValue)")
            } invoke: { repair in
                calls += 1
                XCTAssertEqual(events.last, "\(calls):pending")
                XCTAssertEqual(repair, calls == 2)
                return repair ? #"{"score":0.75,"feedback":"Grounded answer"}"# : "not JSON"
            }
            XCTAssertEqual(result.score, 0.75)
            XCTAssertEqual(events, ["1:pending", "1:invalid_response", "2:pending", "2:completed"])
            XCTAssertEqual(calls, 2)
        }

        func testRepairAllowanceIsNotAnUnboundedLoop() async {
            for allowance in [false, true] {
                var calls = 0
                do {
                    _ = try await PromptExperimentGrading.run(minimum: 0, maximum: 1, canRepair: allowance) { _, _, _ in } invoke: { _ in
                        calls += 1
                        return "invalid"
                    }
                    XCTFail("No score may be fabricated")
                } catch {
                    XCTAssertEqual(error as? PromptExperimentGrading.Failure, .invalidResponse)
                }
                XCTAssertEqual(calls, allowance ? 2 : 1)
            }
        }

        func testProviderErrorsAndCancellationNeverAutomaticallyRetry() async {
            for cancelled in [false, true] {
                var calls = 0
                var states: [PromptExperimentGradingState] = []
                do {
                    _ = try await PromptExperimentGrading.run(minimum: 0, maximum: 1, canRepair: true) { _, state, _ in
                        states.append(state)
                    } invoke: { _ in
                        calls += 1
                        if cancelled { throw CancellationError() }
                        throw NSError(domain: "PRIVATE_PROVIDER_ERROR", code: 1)
                    }
                    XCTFail("A failed invocation is not a grade")
                } catch {
                    if cancelled { XCTAssertTrue(error is CancellationError) }
                    else { XCTAssertEqual(error as? PromptExperimentGrading.Failure, .providerFailed) }
                }
                XCTAssertEqual(calls, 1)
                XCTAssertEqual(states, [.pending, cancelled ? .cancelled : .providerFailed])
            }
        }

        func testPersistenceFailurePreventsFurtherModelSpend() async {
            for failState in [PromptExperimentGradingState.pending, .invalidResponse] {
                var calls = 0
                do {
                    _ = try await PromptExperimentGrading.run(minimum: 0, maximum: 1, canRepair: true) { _, state, _ in
                        if state == failState { throw NSError(domain: "storage", code: 1) }
                    } invoke: { _ in calls += 1
                        return "invalid"
                    }
                    XCTFail("Missing evidence must stop spending")
                } catch {}
                XCTAssertEqual(calls, failState == .pending ? 0 : 1)
            }
        }

        func testCancellationAtBothStageBoundariesRecordsCancelledWithoutAnotherCall() async {
            for cancelBeforeInvocation in [true, false] {
                let task = Task { @MainActor in
                    var calls = 0
                    var states: [PromptExperimentGradingState] = []
                    do {
                        _ = try await PromptExperimentGrading.run(minimum: 0, maximum: 1, canRepair: true) { _, state, _ in
                            states.append(state)
                            if cancelBeforeInvocation, state == .pending { withUnsafeCurrentTask { $0?.cancel() } }
                        } invoke: { _ in
                            calls += 1
                            withUnsafeCurrentTask { $0?.cancel() }
                            return #"{"score":1,"feedback":"ok"}"#
                        }
                        XCTFail("Cancellation must not publish a score")
                    } catch { XCTAssertTrue(error is CancellationError) }
                    XCTAssertEqual(states, [.pending, .cancelled])
                    XCTAssertEqual(calls, cancelBeforeInvocation ? 0 : 1)
                }
                await task.value
            }
        }

        func testExplicitRetryPausesWithoutAnotherJudgeCallAndReusesOriginalCallback() async throws {
            for providerFailed in [false, true] {
                let gate = PromptExperimentGradingRetryGate()
                let attemptID = UUID(), gradingID = UUID()
                let paused = expectation(description: "failed judge is awaiting decision")
                var calls = 0
                var states: [PromptExperimentGradingState] = []
                let task = Task { @MainActor in
                    try await PromptExperimentGrading.run(minimum: 0, maximum: 1, canRepair: true) { _, state, _ in
                        states.append(state)
                    } requestRetry: { failure in
                        XCTAssertEqual(failure, providerFailed ? .providerFailed : .invalidResponse)
                        try await gate.wait(attemptID: attemptID, gradingID: gradingID) { paused.fulfill() }
                    } invoke: { _ in
                        calls += 1
                        if calls == 1 {
                            if providerFailed { throw NSError(domain: "provider", code: 1) }
                            return "invalid"
                        }
                        return #"{"score":0.75,"feedback":"Grounded"}"#
                    }
                }
                await fulfillment(of: [paused], timeout: 2)
                XCTAssertEqual(calls, 1, "No spending until the explicit decision")
                XCTAssertThrowsError(try gate.retry(attemptID: UUID(), gradingID: gradingID))
                try gate.retry(attemptID: attemptID, gradingID: gradingID)
                XCTAssertThrowsError(try gate.retry(attemptID: attemptID, gradingID: gradingID), "Double click must not authorize another call")
                let result = try await task.value
                XCTAssertEqual(result.score, 0.75)
                XCTAssertEqual(calls, 2)
                XCTAssertEqual(states, [.pending, providerFailed ? .providerFailed : .invalidResponse, .pending, .completed])
                XCTAssertThrowsError(try gate.retry(attemptID: attemptID, gradingID: gradingID), "A settled callback cannot resume")
            }
        }

        func testCancellationWhilePausedReleasesCallbackWithoutSpending() async {
            let gate = PromptExperimentGradingRetryGate()
            let attemptID = UUID(), gradingID = UUID()
            let paused = expectation(description: "paused")
            var calls = 0
            var states: [PromptExperimentGradingState] = []
            let task = Task { @MainActor in
                try await PromptExperimentGrading.run(minimum: 0, maximum: 1, canRepair: true) { _, state, _ in
                    states.append(state)
                } requestRetry: { _ in
                    try await gate.wait(attemptID: attemptID, gradingID: gradingID) { paused.fulfill() }
                } invoke: { _ in calls += 1
                    return "invalid"
                }
            }
            await fulfillment(of: [paused], timeout: 2)
            task.cancel()
            do { _ = try await task.value
                XCTFail("Cancelled callback must not produce a grade")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(states.last, .cancelled)
            XCTAssertThrowsError(try gate.retry(attemptID: attemptID, gradingID: gradingID))
        }

        func testRetryDecisionDuringPublicationIsNotLostAndFailureDoesNotPauseWithoutBudget() async throws {
            let gate = PromptExperimentGradingRetryGate()
            let attemptID = UUID(), gradingID = UUID()
            try await gate.wait(attemptID: attemptID, gradingID: gradingID) {
                try gate.retry(attemptID: attemptID, gradingID: gradingID)
            }
            var offers = 0, calls = 0
            do {
                _ = try await PromptExperimentGrading.run(minimum: 0, maximum: 1, canRepair: false) { _, _, _ in }
                    requestRetry: { _ in offers += 1 } invoke: { _ in calls += 1
                        return "invalid"
                    }
                XCTFail("Budget exhaustion must settle")
            } catch { XCTAssertEqual(error as? PromptExperimentGrading.Failure, .invalidResponse) }
            XCTAssertEqual(offers, 0)
            XCTAssertEqual(calls, 1)
        }

        func testCancellationAtRetryCheckpointPreventsSecondInvocation() async {
            let task = Task { @MainActor in
                var calls = 0
                var states: [PromptExperimentGradingState] = []
                do {
                    _ = try await PromptExperimentGrading.run(minimum: 0, maximum: 1, canRepair: true) { ordinal, state, _ in
                        states.append(state)
                        if ordinal == 2, state == .pending { withUnsafeCurrentTask { $0?.cancel() } }
                    } requestRetry: { _ in } invoke: { _ in calls += 1
                        return "invalid"
                    }
                    XCTFail("Cancellation must prevent the second call")
                } catch { XCTAssertTrue(error is CancellationError) }
                XCTAssertEqual(calls, 1)
                XCTAssertEqual(states.last, .cancelled)
            }
            await task.value
        }

        func testCancelledGateRejectsDecisionBeforeWaiterUnwinds() async {
            let gate = PromptExperimentGradingRetryGate()
            let id = UUID(), attemptID = UUID()
            let ready = expectation(description: "gate registered")
            let task = Task { @MainActor in
                try await gate.wait(attemptID: attemptID, gradingID: id) { ready.fulfill() }
            }
            await fulfillment(of: [ready], timeout: 2)
            gate.cancel(gradingID: id)
            XCTAssertThrowsError(try gate.retry(attemptID: attemptID, gradingID: id))
            do { try await task.value
                XCTFail("Cancelled gate must throw")
            } catch { XCTAssertTrue(error is CancellationError) }
        }

        func testCancellationDuringPublicationDoesNotLoseWaiter() async {
            let gate = PromptExperimentGradingRetryGate()
            let id = UUID()
            do {
                try await gate.wait(attemptID: UUID(), gradingID: id) { gate.cancel(gradingID: id) }
                XCTFail("Cancelled publication must not install a lost continuation")
            } catch { XCTAssertTrue(error is CancellationError) }
        }

        func testCallbackClockExcludesOnlyExplicitPauseTime() {
            var clock = PromptExperimentCallbackClock(startedAt: 10)
            XCTAssertEqual(clock.activeSeconds(at: 20), 10)
            clock.setPaused(true, now: 20)
            clock.setPaused(true, now: 30) // duplicate observation cannot reset pause
            XCTAssertEqual(clock.activeSeconds(at: 10000), 10)
            clock.setPaused(false, now: 10000)
            XCTAssertEqual(clock.activeSeconds(at: 10005), 15)
            clock.setPaused(false, now: 10006)
            clock.setPaused(true, now: 10010)
            clock.setPaused(false, now: 20000)
            XCTAssertEqual(clock.activeSeconds(at: 20005), 25)
        }

        func testStrictGradeDecodingRejectsBooleanOutOfRangeAndProse() {
            for output in [#"{"score":true,"feedback":"bad"}"#, #"{"score":2,"feedback":"bad"}"#, #"{"score":0.2}"#, #"Here is {"score":1,"feedback":"bad"}"#, #"{"score":1e400,"feedback":"bad"}"#] {
                XCTAssertNil(PromptExperimentGrading.decode(output, minimum: 0, maximum: 1))
            }
            XCTAssertEqual(PromptExperimentGrading.decode("```json\n{\"score\":0.5,\"feedback\":\"ok\"}\n```", minimum: 0, maximum: 1)?.score, 0.5)
        }
    }
#endif
