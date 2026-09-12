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

        func testStrictGradeDecodingRejectsBooleanOutOfRangeAndProse() {
            for output in [#"{"score":true,"feedback":"bad"}"#, #"{"score":2,"feedback":"bad"}"#, #"{"score":0.2}"#, #"Here is {"score":1,"feedback":"bad"}"#, #"{"score":1e400,"feedback":"bad"}"#] {
                XCTAssertNil(PromptExperimentGrading.decode(output, minimum: 0, maximum: 1))
            }
            XCTAssertEqual(PromptExperimentGrading.decode("```json\n{\"score\":0.5,\"feedback\":\"ok\"}\n```", minimum: 0, maximum: 1)?.score, 0.5)
        }
    }
#endif
