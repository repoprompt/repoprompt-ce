import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class PromptExperimentGradingTests: XCTestCase {
        func testHeldOutFeedbackIsRedactedAtProposerBoundary() {
            let privateFeedback = "Expected secret answer: SECRET_EXPECTED"
            XCTAssertEqual(PromptSuiteSplit.training.proposerFacingFeedback(privateFeedback), privateFeedback)
            XCTAssertEqual(PromptSuiteSplit.validation.proposerFacingFeedback(privateFeedback), privateFeedback)
            XCTAssertEqual(PromptSuiteSplit.hiddenTest.proposerFacingFeedback(privateFeedback), PromptSuiteSplit.heldOutFeedback)
            XCTAssertFalse(PromptSuiteSplit.hiddenTest.proposerFacingFeedback(privateFeedback).contains("SECRET_EXPECTED"))
        }

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

        func testStrictGradeDecodingRejectsBooleanOutOfRangeAndMissingFields() {
            for output in [
                #"{"score":true,"feedback":"bad"}"#, #"{"score":2,"feedback":"bad"}"#, #"{"score":0.2}"#,
                #"{"score":"0.5","feedback":"bad"}"#, #"{"score":1e400,"feedback":"bad"}"#,
                #"Here is my verdict: {"score":2,"feedback":"out of range"}"#, "No JSON at all.", "{unbalanced"
            ] {
                XCTAssertNil(PromptExperimentGrading.decode(output, minimum: 0, maximum: 1), output)
            }
            XCTAssertEqual(PromptExperimentGrading.decode("```json\n{\"score\":0.5,\"feedback\":\"ok\"}\n```", minimum: 0, maximum: 1)?.score, 0.5)
        }

        func testGradeDecodingToleratesPreambleAndExtractsTheEvaluatorObject() {
            let preamble = PromptExperimentGrading.decode(
                #"Here is my evaluation: {"score":0.75,"feedback":"Grounded {with braces} and \"quotes\""} Thanks."#,
                minimum: 0, maximum: 1
            )
            XCTAssertEqual(preamble?.score, 0.75)
            XCTAssertEqual(preamble?.feedback, #"Grounded {with braces} and "quotes""#)

            let prosePlaceholder = PromptExperimentGrading.decode(
                #"I will answer in the {score, feedback} shape. {"score":0.25,"feedback":"thin"}"#,
                minimum: 0, maximum: 1
            )
            XCTAssertEqual(prosePlaceholder?.score, 0.25, "non-JSON brace spans are skipped")

            let fenced = PromptExperimentGrading.decode(
                "Draft:\n```json\n{\"score\":0.1,\"feedback\":\"draft\"}\n```\nFinal:\n```json\n{\"score\":0.9,\"feedback\":\"final\"}\n```\n",
                minimum: 0, maximum: 1
            )
            XCTAssertEqual(fenced?.score, 0.9, "the last fenced JSON block wins")
        }

        func testJudgeRepairIsAvailableForEveryEvaluationNotRunWide() async throws {
            let completer = ScriptedJudge()
            let invoker = PromptExperimentModelInvoker(
                completer: completer,
                policy: PromptExperimentProviderRetryPolicy(maxRetries: 0),
                checkpoint: { _ in },
                callbackRootBase: FileManager.default.temporaryDirectory
                    .appendingPathComponent("grading-\(UUID().uuidString)", isDirectory: true)
            )
            let grader = PromptExperimentGrader(
                grader: PromptSuiteGrader(
                    kind: .modelJudge,
                    scoreRange: .init(min: 0, max: 1),
                    rubric: PromptSuiteRubric(fileName: "rubric.md", text: "Score it.", sha256: "x")
                ),
                judgeTarget: PromptExperimentTestFixtures.execution
            )
            // Every evaluation's first judge reply is malformed; each must still get its own repair.
            for index in 0 ..< 4 {
                let grade = try await grader.grade(
                    example: PromptSuiteCase(id: "t\(index)", split: .training, input: "input", expectedOutput: nil),
                    candidate: "candidate",
                    output: "output",
                    gradingID: UUID(),
                    invoker: invoker,
                    checkpoint: { _ in },
                    progress: { _ in }
                )
                XCTAssertEqual(grade.score, 0.5)
            }
            XCTAssertEqual(completer.calls, 8)
        }
    }

    @MainActor
    private final class ScriptedJudge: PromptExperimentModelCompleting {
        private(set) var calls = 0

        func complete(
            target _: PromptExperimentResolvedTarget,
            systemPrompt _: String,
            userPrompt: String,
            callbackRoot _: URL
        ) async throws -> PromptExperimentConnectedModelCompletion {
            calls += 1
            let repair = userPrompt.contains("did not satisfy the evaluator JSON contract")
            return PromptExperimentConnectedModelCompletion(
                output: repair ? #"{"score":0.5,"feedback":"ok"}"# : "I cannot decide yet.",
                promptTokens: nil,
                completionTokens: nil
            )
        }
    }
#endif
