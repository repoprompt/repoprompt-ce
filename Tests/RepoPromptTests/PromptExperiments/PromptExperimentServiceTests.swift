import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class PromptExperimentServiceTests: XCTestCase {
        func testUngradedOutputsAndPrivateJudgeHistorySurviveFailureAndReload() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdResults = true
            let (id, initial) = try await updatedOptimizationDraft(harness)
            var draft = initial
            draft.optimization?.evaluator.kind = .connectedModelJudge
            draft.optimization?.evaluator.judgeTargetSelector = "fake"
            draft.optimization?.evaluator.rubric = "Evaluate grounding in the example."
            draft.optimization?.gepa.maxJudgeRetries = 1
            let updated = try await harness.service.updateDraft(
                experimentID: id, expectedDraftID: initial.id, expectedDraftVersion: initial.optimisticVersion,
                expectedDraftDigest: initial.contentDigest(), draft: draft
            )
            let plan = try await harness.service.seal(
                experimentID: id,
                expectedDraftID: updated.id,
                expectedDraftVersion: updated.optimisticVersion,
                expectedDraftDigest: updated.contentDigest()
            )
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            try await harness.service.run(experimentID: id)
            await harness.runtime.waitUntilWaitingForResult()
            let sink = try XCTUnwrap(harness.runtime.reportCheckpoint)
            let gradeID = UUID()
            func value(_ ordinal: Int, _ state: PromptExperimentGradingState, id: UUID = gradeID) -> PromptExperimentCheckpoint {
                .grading(.init(
                    id: id,
                    exampleID: "reviewed-1",
                    split: .validation,
                    candidate: "Candidate",
                    output: "Saved target output",
                    ordinal: ordinal,
                    state: state,
                    response: state == .invalidResponse ? "HOST_PRIVATE_JUDGE_RESPONSE" : nil
                ))
            }
            try await sink(value(1, .pending))
            try await sink(value(1, .invalidResponse))
            try await sink(value(2, .pending))
            try await sink(value(2, .invalidResponse))
            let second = UUID()
            try await sink(value(1, .pending, id: second))
            try await sink(value(1, .invalidResponse, id: second))
            do { try await sink(value(2, .pending, id: second))
                XCTFail("Run-wide repair budget must not reset for another evaluation")
            } catch {}
            harness.runtime.settleFirst(disposition: .failed("judge_invalid_response"))
            await harness.service.waitForExecutionForTesting(experimentID: id)
            let saved = try await harness.store.loadRecords()
            let record = try XCTUnwrap(saved.first)
            let grade = try XCTUnwrap(record.attempts.last?.gradingEvidence?.first)
            XCTAssertEqual(grade.history.count, 2)
            XCTAssertEqual(grade.ordinal, 2)
            let texts = try await harness.service.readableArtifactText(for: record)
            XCTAssertTrue(texts.values.contains("Saved target output"))
            XCTAssertFalse(texts.values.contains("HOST_PRIVATE_JUDGE_RESPONSE"))
            XCTAssertNotNil(grade.history.first?.responseEvidence)
            let projection = try MCPAgentSessionControlToolProvider.responseValue(.record(record, artifactTextBySHA256: texts))
            let serialized = try String(decoding: JSONEncoder().encode(projection), as: UTF8.self)
            XCTAssertFalse(serialized.contains("HOST_PRIVATE_JUDGE_RESPONSE"))
            XCTAssertTrue(serialized.contains("invalid_response"))
            XCTAssertEqual(PromptExperimentGuidance.evaluate(record)?.action, "review_grading_interruption")
        }

        func testJudgeFormatRepairUsesDurableOutputAndPublishesOneEvaluation() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdResults = true
            let (id, initial) = try await updatedOptimizationDraft(harness)
            var draft = initial
            draft.optimization?.evaluator.kind = .connectedModelJudge
            draft.optimization?.evaluator.judgeTargetSelector = "fake"
            draft.optimization?.evaluator.rubric = "Evaluate grounding in the example."
            draft.optimization?.gepa.maxJudgeRetries = 1
            let updated = try await harness.service.updateDraft(
                experimentID: id, expectedDraftID: initial.id, expectedDraftVersion: initial.optimisticVersion,
                expectedDraftDigest: initial.contentDigest(), draft: draft
            )
            let plan = try await harness.service.seal(
                experimentID: id, expectedDraftID: updated.id, expectedDraftVersion: updated.optimisticVersion,
                expectedDraftDigest: updated.contentDigest()
            )
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            try await harness.service.run(experimentID: id)
            await harness.runtime.waitUntilWaitingForResult()
            let sink = try XCTUnwrap(harness.runtime.reportCheckpoint)
            let gradeID = UUID()
            let candidate = "Read the fixture and report the named value."
            let output = "cobalt"
            var judgeCalls = 0
            let judgment = try await PromptExperimentGrading.run(minimum: 0, maximum: 1, canRepair: true) { ordinal, state, response in
                try await sink(.grading(.init(
                    id: gradeID, exampleID: "reviewed-1", split: .validation,
                    candidate: candidate, output: output, ordinal: ordinal, state: state, response: response
                )))
            } invoke: { repair in
                judgeCalls += 1
                // Read the canonical store, not the in-memory service projection. Both
                // invocations must observe the same committed target output before spending.
                let records = try await harness.store.loadRecords()
                let record = try XCTUnwrap(records.first)
                let grade = try XCTUnwrap(record.attempts.last?.gradingEvidence?.first)
                XCTAssertEqual(grade.id, gradeID)
                XCTAssertEqual(grade.state, .pending)
                XCTAssertEqual(grade.ordinal, judgeCalls)
                XCTAssertEqual(grade.outputEvidence.sha256, PromptExperimentDigest.sha256(Data(output.utf8)))
                XCTAssertEqual(record.attempts.last?.partialEvaluations?.count ?? 0, 0)
                XCTAssertEqual(repair, judgeCalls == 2)
                if repair {
                    XCTAssertEqual(grade.history.map(\.state), [.invalidResponse])
                    XCTAssertNotNil(grade.history.first?.responseEvidence)
                    return #"{"score":0.75,"feedback":"Grounded but missing source citation"}"#
                }
                return "HOST_PRIVATE_INVALID_GRADE"
            }
            try await sink(.evaluation(id: gradeID, candidate: candidate, value: .init(
                candidateIndex: -1, exampleID: "reviewed-1", split: .validation, score: judgment.score,
                feedback: judgment.feedback, failureKind: nil, output: output, elapsedSeconds: 1
            )))
            // A later unrelated interruption must not erase the repaired, scored output.
            harness.runtime.settleFirst(disposition: .failed("later reflection interrupted"))
            await harness.service.waitForExecutionForTesting(experimentID: id)
            let records = try await harness.store.loadRecords()
            let record = try XCTUnwrap(records.first)
            let attempt = try XCTUnwrap(record.attempts.last)
            XCTAssertEqual(judgeCalls, 2)
            XCTAssertEqual(attempt.gradingEvidence?.count, 1)
            XCTAssertEqual(attempt.gradingEvidence?.first?.state, .completed)
            XCTAssertEqual(attempt.gradingEvidence?.first?.history.map(\.state), [.invalidResponse, .completed])
            XCTAssertEqual(attempt.partialEvaluations?.count, 1)
            XCTAssertEqual(attempt.partialEvaluations?.first?.evaluation.score, 0.75)
            XCTAssertNil(attempt.optimizationResult, "Partial recovery must not fabricate a final GEPA winner")
            let texts = try await harness.service.readableArtifactText(for: record)
            let projection = try MCPAgentSessionControlToolProvider.responseValue(.record(record, artifactTextBySHA256: texts))
            let serialized = try String(decoding: JSONEncoder().encode(projection), as: UTF8.self)
            XCTAssertTrue(serialized.contains("cobalt"))
            XCTAssertFalse(serialized.contains("HOST_PRIVATE_INVALID_GRADE"))
        }

        func testLiveRetryRequiresOwnedPlanAndPendingGradeAndSurvivesOnlyInLiveRuntime() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdResults = true
            let (id, initial) = try await updatedOptimizationDraft(harness)
            var draft = initial
            draft.optimization?.evaluator.kind = .connectedModelJudge
            draft.optimization?.evaluator.judgeTargetSelector = "fake"
            draft.optimization?.evaluator.rubric = "Evaluate grounding."
            draft.optimization?.gepa.maxJudgeRetries = 1
            draft.optimization?.gepa.pauseOnGradingFailure = true
            let updated = try await harness.service.updateDraft(
                experimentID: id, expectedDraftID: initial.id, expectedDraftVersion: initial.optimisticVersion,
                expectedDraftDigest: initial.contentDigest(), draft: draft
            )
            let plan = try await harness.service.seal(
                experimentID: id,
                expectedDraftID: updated.id,
                expectedDraftVersion: updated.optimisticVersion,
                expectedDraftDigest: updated.contentDigest()
            )
            let owner = try XCTUnwrap(harness.service.record(id: id)?.controllerSessionID)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            try await harness.service.run(experimentID: id)
            await harness.runtime.waitUntilWaitingForResult()
            let sink = try XCTUnwrap(harness.runtime.reportCheckpoint)
            let gradeID = UUID()
            func value(_ ordinal: Int, _ state: PromptExperimentGradingState, awaitingRetry: Bool? = nil) -> PromptExperimentCheckpoint {
                .grading(.init(
                    id: gradeID,
                    exampleID: "reviewed-1",
                    split: .validation,
                    candidate: "Read the file",
                    output: "saved output",
                    ordinal: ordinal,
                    state: state,
                    response: nil,
                    awaitingRetry: awaitingRetry
                ))
            }
            try await sink(value(1, .pending))
            try await sink(value(1, .providerFailed))
            try await sink(value(1, .pending, awaitingRetry: true))
            let record = try await harness.service.waitForExecution(
                experimentID: id,
                expectedPlanDigest: plan.digest,
                expectedControllerSessionID: owner,
                timeoutSeconds: 1
            )
            XCTAssertEqual(PromptExperimentGuidance.evaluate(record)?.action, "retry_grading_or_cancel")
            struct LegacyGrade: Decodable {
                struct History: Decodable { let state: PromptExperimentGradingState }
                let state: PromptExperimentGradingState
                let history: [History]
            }
            let paused = try XCTUnwrap(record.attempts.last?.gradingEvidence?.first)
            let legacy = try JSONDecoder().decode(LegacyGrade.self, from: JSONEncoder().encode(paused))
            XCTAssertEqual(legacy.state, .providerFailed)
            XCTAssertEqual(legacy.history.map(\.state), [.providerFailed, .providerFailed])

            for (digest, ownerID, grade) in [("wrong", owner, gradeID), (plan.digest, UUID(), gradeID), (plan.digest, owner, UUID())] {
                do {
                    try await harness.service.retryGrading(
                        experimentID: id,
                        expectedPlanDigest: digest,
                        gradingID: grade,
                        expectedControllerSessionID: ownerID
                    )
                    XCTFail("Mismatched authority must fail")
                } catch {}
            }
            XCTAssertEqual(harness.runtime.retryRequests.count, 0)
            let reopened = PromptExperimentService(store: PromptExperimentStore(rootURL: harness.root), runtime: FakeRuntime(), resolveTarget: Self.fakeTarget)
            await reopened.load()
            let restored = try XCTUnwrap(reopened.record(id: id))
            XCTAssertNotEqual(restored.phase, .running)
            XCTAssertEqual(restored.attempts.last?.gradingEvidence?.first?.awaitingRetry, false)
            XCTAssertNotEqual(PromptExperimentGuidance.evaluate(restored)?.action, "retry_grading_or_cancel")
            // Separate service is a restart projection probe only; the original test
            // runtime remains in memory and drives subsequent controlled checkpoints.
            try await harness.service.retryGrading(
                experimentID: id,
                expectedPlanDigest: plan.digest,
                gradingID: gradeID,
                expectedControllerSessionID: owner
            )
            XCTAssertEqual(harness.runtime.retryRequests, [gradeID])
            try await sink(value(2, .pending))
            try await sink(value(2, .providerFailed))
            harness.runtime.settleFirst(disposition: .failed("judge_provider_failed"))
            await harness.service.waitForExecutionForTesting(experimentID: id)
            do {
                try await harness.service.retryGrading(experimentID: id, expectedPlanDigest: plan.digest, gradingID: gradeID)
                XCTFail("Exited attempt must not restart")
            } catch {}
            let saved = try await harness.store.loadRecords()
            XCTAssertEqual(saved.first?.attempts.last?.gradingEvidence?.first?.history.map(\.state), [.providerFailed, .providerFailed, .providerFailed])
            XCTAssertEqual(saved.first?.attempts.last?.gradingEvidence?.first?.ordinal, 2)
            XCTAssertNil(saved.first?.attempts.last?.optimizationResult)
        }

        func testJudgeRepairBudgetChangesDigestAndHistoricalAbsenceRemainsZero() throws {
            var draft = PromptExperimentDraft(revision: 1, title: "Budget", targetRole: "", optimization: Self.validOptimization(), createdAt: Date(), updatedAt: Date())
            let original = try draft.contentDigest()
            XCTAssertNil(draft.optimization?.gepa.pauseOnGradingFailure)
            draft.optimization?.gepa.pauseOnGradingFailure = true
            XCTAssertNotEqual(try draft.contentDigest(), original)
            draft.optimization?.gepa.pauseOnGradingFailure = nil
            XCTAssertEqual(try draft.contentDigest(), original, "Historical omission must preserve the digest")
            XCTAssertNil(draft.optimization?.gepa.maxProviderRetries)
            draft.optimization?.gepa.maxProviderRetries = 1
            XCTAssertNotEqual(try draft.contentDigest(), original)
            draft.optimization?.gepa.maxProviderRetries = nil
            XCTAssertEqual(try draft.contentDigest(), original, "Historical provider retry omission must preserve the digest")
            XCTAssertNil(draft.optimization?.gepa.maxJudgeRetries)
            draft.optimization?.gepa.maxJudgeRetries = 1
            XCTAssertNotEqual(try draft.contentDigest(), original)
        }

        func testCheckpointEvidenceAndUsageSurviveLaterFailureAndReload() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdResults = true
            let id = try await preparedOptimizationExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            try await harness.service.run(experimentID: id)
            await harness.runtime.waitUntilWaitingForResult()
            let checkpoint = try XCTUnwrap(harness.runtime.reportCheckpoint)
            let target = try XCTUnwrap(plan.optimizationTargets?.reflection)
            let callID = UUID()
            try await checkpoint(.modelCall(.init(id: callID, target: target, role: "reflection", state: .started, promptTokens: nil, completionTokens: nil)))
            let completed = PromptExperimentCheckpoint.modelCall(.init(id: callID, target: target, role: "reflection", state: .completed, promptTokens: 31, completionTokens: 9))
            try await checkpoint(completed)
            try await checkpoint(completed)
            let evaluation = PromptExperimentCheckpoint.evaluation(id: UUID(), candidate: "Find the named value.", value: .init(
                candidateIndex: 0, exampleID: "reviewed-1", split: .validation, score: 1,
                feedback: "Exact answer", failureKind: nil, output: "cobalt", elapsedSeconds: 2
            ))
            try await checkpoint(evaluation)
            try await checkpoint(evaluation)
            let activeRecords = try await harness.store.loadRecords()
            XCTAssertEqual(activeRecords.first?.attempts.last?.partialEvaluations?.count, 1)
            XCTAssertEqual(activeRecords.first?.attempts.last?.modelCalls?.count, 1)
            let texts = try await harness.service.readableArtifactText(for: XCTUnwrap(harness.service.record(id: id)))
            XCTAssertTrue(texts.values.contains("cobalt"))
            harness.runtime.settleFirst(disposition: .failed("later callback failed"))
            await harness.service.waitForExecutionForTesting(experimentID: id)
            let saved = try await harness.store.loadRecords()
            let record = try XCTUnwrap(saved.first)
            XCTAssertEqual(record.phase, .inconclusive)
            XCTAssertNil(record.attempts.last?.optimizationResult)
            XCTAssertEqual(record.attempts.last?.partialEvaluations?.count, 1)
            XCTAssertEqual(record.attempts.last?.modelCalls?.first?.promptTokens, 31)
            let projected = try MCPAgentSessionControlToolProvider.responseValue(.record(record, artifactTextBySHA256: texts)).objectValue
            let attempt = projected?["attempts"]?.arrayValue?.first?.objectValue
            XCTAssertEqual(attempt?["partial_evaluations"]?.arrayValue?.first?.objectValue?["output"]?.stringValue, "cobalt")
            XCTAssertEqual(attempt?["model_calls"]?.arrayValue?.first?.objectValue?["completion_tokens"], .int(9))
            do { try await checkpoint(evaluation)
                XCTFail("Late checkpoint must not mutate settled evidence")
            } catch {}
            XCTAssertEqual(harness.service.record(id: id)?.attempts.last?.partialEvaluations?.count, 1)
        }

        func testCancellationRetainsAdmittedCompletionButRejectsNewModelInvocation() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdResults = true
            let id = try await preparedOptimizationExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            try await harness.service.run(experimentID: id)
            await harness.runtime.waitUntilWaitingForResult()
            let checkpoint = try XCTUnwrap(harness.runtime.reportCheckpoint)
            let target = try XCTUnwrap(plan.optimizationTargets?.reflection)
            let invocationID = UUID()
            try await checkpoint(.modelCall(.init(id: invocationID, target: target, role: "reflection", state: .started, promptTokens: nil, completionTokens: nil)))
            try await harness.service.cancel(experimentID: id)
            try await checkpoint(.modelCall(.init(id: invocationID, target: target, role: "reflection", state: .completed, promptTokens: 10, completionTokens: 2)))
            do {
                try await checkpoint(.modelCall(.init(id: UUID(), target: target, role: "reflection", state: .started, promptTokens: nil, completionTokens: nil)))
                XCTFail("Cancellation must prevent new invocations")
            } catch {}
            harness.runtime.settleFirst(disposition: .cancelled)
            await harness.service.waitForExecutionForTesting(experimentID: id)
            let records = try await harness.store.loadRecords()
            XCTAssertEqual(records.first?.phase, .cancelled)
            XCTAssertEqual(records.first?.attempts.last?.modelCalls?.count, 1)
            XCTAssertEqual(records.first?.attempts.last?.modelCalls?.first?.completionTokens, 2)
        }

        func testCheckpointCanonicalWriteFailureDoesNotAcknowledgeOrDeduplicateUnsavedUsage() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdResults = true
            let id = try await preparedOptimizationExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            try await harness.service.run(experimentID: id)
            await harness.runtime.waitUntilWaitingForResult()
            let checkpoint = try XCTUnwrap(harness.runtime.reportCheckpoint)
            let target = try XCTUnwrap(plan.optimizationTargets?.reflection)
            let callID = UUID()
            try await checkpoint(.modelCall(.init(id: callID, target: target, role: "reflection", state: .started, promptTokens: nil, completionTokens: nil)))
            let canonical = harness.root.appendingPathComponent("experiments.json")
            let backup = try Data(contentsOf: canonical)
            try FileManager.default.removeItem(at: canonical)
            try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: false)
            let completed = PromptExperimentCheckpoint.modelCall(.init(id: callID, target: target, role: "reflection", state: .completed, promptTokens: 31, completionTokens: 9))
            do { try await checkpoint(completed)
                XCTFail("Save failure must propagate to the runtime")
            } catch {}
            XCTAssertEqual(harness.service.record(id: id)?.attempts.last?.modelCalls?.first?.state, .started)
            try FileManager.default.removeItem(at: canonical)
            try backup.write(to: canonical)
            do { try await checkpoint(completed)
                XCTFail("An unsaved checkpoint must not be acknowledged on retry")
            } catch {}
            harness.runtime.settleFirst(disposition: .failed("checkpoint persistence failed"))
            await harness.service.waitForExecutionForTesting(experimentID: id)
            let saved = try await harness.store.loadRecords()
            XCTAssertEqual(saved.first?.attempts.last?.modelCalls?.first?.state, .started)
            XCTAssertNil(saved.first?.attempts.last?.modelCalls?.first?.promptTokens)
        }

        func testPromptOnlyPreflightRejectsCodexRolesWithoutChangingExactSelections() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            let environment = try XCTUnwrap(harness.service.record(id: id)?.currentPlan?.environment)
            let claude = PromptExperimentResolvedTarget(role: "reflection", agentRaw: AgentProviderKind.claudeCode.rawValue, modelRaw: "test-model", displayName: "test")
            let codex = PromptExperimentResolvedTarget(role: "execution", agentRaw: AgentProviderKind.codexExec.rawValue, modelRaw: "exact-test-model", displayName: "test")
            XCTAssertNoThrow(try PromptExperimentConnectedModelRunner.requirePromptOnlyTarget(claude))
            XCTAssertThrowsError(try PromptExperimentConnectedModelRunner.requirePromptOnlyTarget(codex))
            XCTAssertThrowsError(try PromptExperimentConnectedModelRunner.requirePromptOnlyTarget(XCTUnwrap(Self.fakeTarget("unknown"))))
            for role in ["reflection", "execution", "judge"] {
                var draft = Self.validDraft(date: Date(), repetitions: 1)
                var spec = Self.validOptimization()
                spec.execution.adapter = .connectedModel
                spec.evaluator.kind = .connectedModelJudge
                spec.evaluator.rubric = "Judge correctness."
                spec.evaluator.judgeTargetSelector = "judge"
                draft.optimization = spec
                let targets = PromptExperimentOptimizationTargets(
                    reflection: role == "reflection" ? codex : claude,
                    execution: role == "execution" ? codex : claude,
                    judge: role == "judge" ? codex : claude
                )
                let plan = try PromptExperimentPlan.seal(draft: draft, target: claude, optimizationTargets: targets, environment: environment, at: Date())
                XCTAssertThrowsError(try PromptExperimentConnectedModelRunner.preflight(plan)) { error in
                    XCTAssertTrue(error.localizedDescription.contains(role))
                    XCTAssertTrue(error.localizedDescription.contains("exact-test-model"))
                }
                XCTAssertEqual(plan.optimizationTargets, targets)
            }
            var draft = Self.validDraft(date: Date(), repetitions: 1)
            var spec = Self.validOptimization()
            spec.stage = .preparation
            spec.preparationCandidates = ["Find the value."]
            spec.examples[0].split = .training
            draft.optimization = spec
            let plan = try PromptExperimentPlan.seal(
                draft: draft,
                target: codex,
                optimizationTargets: .init(reflection: codex, execution: codex, judge: nil),
                environment: environment,
                at: Date()
            )
            XCTAssertNoThrow(try PromptExperimentConnectedModelRunner.preflight(plan), "Unused reflection and real Context Builder workflows are not prompt-only callbacks")
            XCTAssertTrue(harness.runtime.submitted.isEmpty)
        }

        func testProviderFailureClassificationIsClosedAndRetryabilityIsExplicit() {
            XCTAssertEqual(
                PromptExperimentConnectedModelRunner.classifyProviderDescription("HTTP 429 rate limit").code,
                .rateLimited
            )
            XCTAssertTrue(PromptExperimentProviderFailureCode.rateLimited.isRetryable)
            XCTAssertEqual(
                PromptExperimentConnectedModelRunner.classifyProviderDescription("OAuth authentication expired").code,
                .rejected
            )
            XCTAssertFalse(PromptExperimentProviderFailureCode.rejected.isRetryable)
            XCTAssertEqual(
                PromptExperimentConnectedModelRunner.classifyProviderDescription("surprising opaque failure").code,
                .unknown
            )
            XCTAssertFalse(PromptExperimentProviderFailureCode.unknown.isRetryable)
            XCTAssertEqual(
                PromptExperimentGEPAWorker.safeProtocolDetail(type: "provider_retry", object: [
                    "operation": "mcp_model",
                    "failure_code": "provider_transport_interrupted",
                    "next_attempt": 2,
                    "max_attempts": 2
                ]),
                "operation=mcp_model failure_code=provider_transport_interrupted next_attempt=2 max_attempts=2 payload=excluded"
            )
        }

        func testSealRejectsKnownIncompatibleCodexCallbackBeforeApprovalOrEnvironmentCapture() async throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = PromptExperimentStore(rootURL: root)
            let runtime = FakeRuntime()
            let claude = PromptExperimentResolvedTarget(
                role: "reflector",
                agentRaw: AgentProviderKind.claudeCode.rawValue,
                modelRaw: "claude-test",
                displayName: "Claude Test"
            )
            let codex = PromptExperimentResolvedTarget(
                role: "executor",
                agentRaw: AgentProviderKind.codexExec.rawValue,
                modelRaw: "gpt-test",
                displayName: "Codex Test"
            )
            let service = PromptExperimentService(
                store: store,
                runtime: runtime,
                resolveTarget: { $0 == "executor" ? codex : claude },
                now: { Date(timeIntervalSince1970: 1000) }
            )
            await service.load()
            let id = try await service.createOptimizationExperiment(
                controllerSessionID: UUID(),
                sourceTabID: UUID()
            )
            var draft = try XCTUnwrap(service.record(id: id)?.draft)
            let digest = try draft.contentDigest()
            var optimization = Self.validOptimization()
            optimization.execution.adapter = .connectedModel
            draft.optimization = optimization
            let updated = try await service.updateDraft(
                experimentID: id,
                expectedDraftID: draft.id,
                expectedDraftVersion: draft.optimisticVersion,
                expectedDraftDigest: digest,
                draft: draft
            )
            do {
                _ = try await service.seal(
                    experimentID: id,
                    expectedDraftID: updated.id,
                    expectedDraftVersion: updated.optimisticVersion,
                    expectedDraftDigest: updated.contentDigest()
                )
                XCTFail("Known-incompatible callback target must fail before sealing")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("cannot be sealed"))
                XCTAssertTrue(error.localizedDescription.contains("execution"))
                XCTAssertTrue(error.localizedDescription.contains("gpt-test"))
            }
            let record = try XCTUnwrap(service.record(id: id))
            XCTAssertEqual(record.phase, .drafting)
            XCTAssertTrue(record.plans.isEmpty)
            XCTAssertTrue(record.approvals.isEmpty)
        }

        func testRunPersistsPreflightBlockBeforeAnyAttempt() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            harness.runtime.preflightError = .runtimeUnavailable("controlled callback unavailable")

            do {
                try await harness.service.run(experimentID: id)
                XCTFail("Preflight failure must propagate")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("controlled callback unavailable"))
            }
            let record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record.phase, .approved)
            XCTAssertTrue(record.attempts.isEmpty)
            XCTAssertTrue(record.statusMessage.contains("preflight blocked"))
            XCTAssertTrue(record.statusMessage.contains("controlled callback unavailable"))
            let persisted = try await harness.store.loadRecords()
            XCTAssertEqual(persisted.first?.statusMessage, record.statusMessage)
        }

        func testCompletionPreservesMessageBoundariesAndTerminalUsage() throws {
            let provider = CodexExecAgentProvider(config: .init(commandName: "codex", additionalPathHints: []))
            var accumulator = PromptExperimentCompletionAccumulator()
            let answer = "{\"action\":\"answer\",\"text\":\"same answer\"}"
            for id in ["commentary-id", "final-id"] {
                let data = try JSONSerialization.data(withJSONObject: [
                    "type": "item.completed", "item": ["type": "agent_message", "id": id, "text": answer]
                ])
                let event = try XCTUnwrap(provider.parseJSONLEvent(data))
                XCTAssertEqual(event.contentMessageID, id)
                accumulator.consume(event)
            }
            let terminal = try XCTUnwrap(provider.parseJSONLEvent(Data(
                #"{"type":"turn.completed","usage":{"input_tokens":31,"output_tokens":9}}"#.utf8
            )))
            accumulator.consume(terminal)
            XCTAssertEqual(accumulator.output, answer)
            XCTAssertEqual(accumulator.promptTokens, 31)
            XCTAssertEqual(accumulator.completionTokens, 9)
            var deltas = PromptExperimentCompletionAccumulator()
            deltas.consume(AIStreamResult(type: "content", text: "same"))
            deltas.consume(AIStreamResult(type: "content", text: "same"))
            XCTAssertEqual(deltas.output, "samesame", "Do not heuristically deduplicate valid token deltas")
            deltas.consume(AIStreamResult(type: "final_content", text: "authoritative final"))
            XCTAssertEqual(deltas.output, "authoritative final")
        }

        func testLiveProgressProjectsThroughMCPAndCannotOverwriteCancellationOrSettlement() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdResults = true
            let id = try await preparedOptimizationExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            try await harness.service.run(experimentID: id)
            await harness.runtime.waitUntilWaitingForResult()
            let progress = try XCTUnwrap(harness.runtime.reportProgress)
            await progress("Evaluated candidate 2 (3/6 budget calls).")
            let record = try XCTUnwrap(harness.service.record(id: id))
            let projected = try MCPAgentSessionControlToolProvider.responseValue(.record(record, artifactTextBySHA256: [:])).objectValue
            XCTAssertEqual(projected?["status"]?.stringValue, "Evaluated candidate 2 (3/6 budget calls).")
            XCTAssertEqual(projected?["attempts"]?.arrayValue?.first?.objectValue?["status_text"]?.stringValue, record.statusMessage)
            let persisted = try await harness.store.loadRecords()
            XCTAssertEqual(persisted.first?.statusMessage, record.statusMessage)
            try await harness.service.cancel(experimentID: id)
            let cancelling = harness.service.record(id: id)?.statusMessage
            await progress("late progress after cancellation")
            XCTAssertEqual(harness.service.record(id: id)?.statusMessage, cancelling)
            harness.runtime.settleFirst()
            await harness.service.waitForExecutionForTesting(experimentID: id)
            let terminal = harness.service.record(id: id)?.statusMessage
            await progress("late progress after settlement")
            XCTAssertEqual(harness.service.record(id: id)?.statusMessage, terminal)
        }

        func testMCPConfigurationAllowsIsolatedApplyEditsAndRejectsControlTools() throws {
            let valid = PromptExperimentMCPConfiguration(toolNames: ["read_file"], component: "tool_description_read_file", toolDefinitionsJson: "[]", serverSha256: "digest")
            XCTAssertNoThrow(try valid.validate())
            XCTAssertNoThrow(
                try PromptExperimentMCPConfiguration(
                    toolNames: ["apply_edits"],
                    component: "tool_description_apply_edits"
                ).validate()
            )
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            XCTAssertEqual(try decoder.decode(PromptExperimentMCPConfiguration.self, from: encoder.encode(valid)), valid)
            for invalid in [
                PromptExperimentMCPConfiguration(toolNames: ["prompt_experiment"], component: "system_prompt"),
                PromptExperimentMCPConfiguration(toolNames: ["read_file", "read_file"], component: "system_prompt"),
                PromptExperimentMCPConfiguration(toolNames: ["read_file"], component: "tool_description_file_actions")
            ] {
                XCTAssertThrowsError(try invalid.validate())
            }
        }

        func testWorkspaceControllerIsStableAcrossClientsButCannotImpersonateAgentOrOtherWorkspace() {
            let workspaceID = UUID()
            let first = PromptExperimentAgentOwner.workspace(workspaceID, tabID: UUID(), roots: ["/one"])
            let resumed = PromptExperimentAgentOwner.workspace(workspaceID, tabID: UUID(), roots: ["/one"])
            let other = PromptExperimentAgentOwner.workspace(UUID(), tabID: UUID(), roots: ["/one"])
            XCTAssertEqual(first.controllerSessionID, resumed.controllerSessionID)
            XCTAssertNotEqual(first.controllerSessionID, workspaceID)
            XCTAssertNotEqual(first.controllerSessionID, other.controllerSessionID)
        }

        func testMCPApprovalStartsExactRunAndSurvivesReloadWithoutNativeCard() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdResults = true
            let id = try await preparedOptimizationExperiment(harness)
            let sealed = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(sealed.currentPlan)
            let owner = PromptExperimentAgentOwner(controllerSessionID: sealed.controllerSessionID, sourceTabID: sealed.sourceTabID)
            let started = try await harness.service.requestRunUsingMCPApproval(
                experimentID: id, expectedPlanDigest: plan.digest, owner: owner
            ) { disclosed in
                XCTAssertEqual(disclosed, plan)
                XCTAssertTrue(harness.runtime.submitted.isEmpty)
                XCTAssertFalse(harness.service.bindRuntimeIfIdle(FakeRuntime(), bindingIdentity: ObjectIdentifier(NSObject())))
                return true
            }
            XCTAssertEqual(started.phase, .running)
            XCTAssertEqual(started.approval(for: plan)?.source, .mcpElicitation)
            await harness.runtime.waitUntilWaitingForResult()
            harness.runtime.settleFirst()
            let completed = try await harness.service.waitForExecution(
                experimentID: id, expectedPlanDigest: plan.digest,
                expectedControllerSessionID: owner.controllerSessionID, timeoutSeconds: 30
            )
            XCTAssertEqual(completed.phase, .completed)
            let repeated = try await harness.service.requestRunUsingMCPApproval(
                experimentID: id, expectedPlanDigest: plan.digest, owner: owner
            ) { _ in XCTFail("A retry must not request approval or buy another run")
                return true
            }
            XCTAssertEqual(repeated.attempts.count, 1)
            let reloaded = try await harness.store.loadRecords()
            XCTAssertEqual(reloaded.first?.approval(for: plan)?.source, .mcpElicitation)
        }

        func testMCPDeclineAndLateAcceptAfterCancelDoNotExecute() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            let sealed = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(sealed.currentPlan)
            let owner = PromptExperimentAgentOwner(controllerSessionID: sealed.controllerSessionID, sourceTabID: sealed.sourceTabID)
            let declined = try await harness.service.requestRunUsingMCPApproval(
                experimentID: id, expectedPlanDigest: plan.digest, owner: owner
            ) { _ in false }
            XCTAssertEqual(declined.phase, .awaitingApproval)
            XCTAssertTrue(declined.approvals.isEmpty)
            do {
                _ = try await harness.service.requestRunUsingMCPApproval(
                    experimentID: id, expectedPlanDigest: plan.digest, owner: owner
                ) { _ in
                    try await harness.service.cancel(
                        experimentID: id, expectedPlanDigest: plan.digest,
                        expectedControllerSessionID: owner.controllerSessionID
                    )
                    return true
                }
                XCTFail("Late acceptance must not resurrect a cancelled request")
            } catch is CancellationError {}
            XCTAssertTrue(harness.runtime.submitted.isEmpty)
            XCTAssertTrue(try XCTUnwrap(harness.service.record(id: id)).approvals.isEmpty)
        }

        func testMCPApprovalCannotStartAfterCancellationDuringPreflight() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            let sealed = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(sealed.currentPlan)
            let owner = PromptExperimentAgentOwner(controllerSessionID: sealed.controllerSessionID, sourceTabID: sealed.sourceTabID)
            harness.runtime.preflightAction = {
                try await harness.service.cancel(
                    experimentID: id, expectedPlanDigest: plan.digest,
                    expectedControllerSessionID: owner.controllerSessionID
                )
            }
            defer { harness.runtime.preflightAction = nil }
            do {
                _ = try await harness.service.requestRunUsingMCPApproval(
                    experimentID: id, expectedPlanDigest: plan.digest, owner: owner
                ) { _ in true }
                XCTFail("Preflight must not overwrite cancellation")
            } catch let error as PromptExperimentAuthorityError {
                guard case .illegalPhase = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertTrue(harness.runtime.submitted.isEmpty)
            XCTAssertEqual(harness.service.record(id: id)?.phase, .cancelled)
            let saved = try await harness.store.loadRecords()
            XCTAssertEqual(saved.first?.phase, .cancelled)
        }

        func testMCPWrongOwnerAndDigestNeverPresentApproval() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            let sealed = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(sealed.currentPlan)
            for (ownerID, digest, expected) in [
                (UUID(), plan.digest, PromptExperimentAuthorityError.ownerMismatch),
                (sealed.controllerSessionID, "stale", .digestMismatch)
            ] {
                do {
                    _ = try await harness.service.requestRunUsingMCPApproval(
                        experimentID: id, expectedPlanDigest: digest,
                        owner: .init(controllerSessionID: ownerID, sourceTabID: sealed.sourceTabID)
                    ) { _ in XCTFail("Invalid authority must not reach elicitation")
                        return true
                    }
                    XCTFail("Invalid authority must fail")
                } catch let error as PromptExperimentAuthorityError { XCTAssertEqual(error, expected) }
            }
            XCTAssertTrue(harness.runtime.submitted.isEmpty)
        }

        func testMCPCancelReleasesRunCallerBeforeFormResponds() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            let sealed = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(sealed.currentPlan)
            let owner = PromptExperimentAgentOwner(controllerSessionID: sealed.controllerSessionID, sourceTabID: sealed.sourceTabID)
            var reply: CheckedContinuation<Bool, Never>?
            var presentation: CheckedContinuation<Void, Never>?
            let pending = Task {
                try await harness.service.requestRunUsingMCPApproval(
                    experimentID: id, expectedPlanDigest: plan.digest, owner: owner
                ) { _ in
                    await withCheckedContinuation { continuation in
                        reply = continuation
                        presentation?.resume()
                    }
                }
            }
            await withCheckedContinuation { presentation = $0 }
            try await harness.service.cancel(
                experimentID: id, expectedPlanDigest: plan.digest,
                expectedControllerSessionID: owner.controllerSessionID
            )
            do {
                _ = try await pending.value
                XCTFail("The cancelled run call must settle before the form replies")
            } catch is CancellationError {}
            reply?.resume(returning: true)
            XCTAssertTrue(harness.runtime.submitted.isEmpty)
            XCTAssertTrue(try XCTUnwrap(harness.service.record(id: id)).approvals.isEmpty)
        }

        func testLiveServiceAvailabilityPublishesLateInstallationAndReplacement() {
            let first = makeHarness()
            let replacement = makeHarness()
            defer {
                try? FileManager.default.removeItem(at: first.root)
                try? FileManager.default.removeItem(at: replacement.root)
            }
            let availability = PromptExperimentServiceAvailability()
            var observed: [ObjectIdentifier?] = []
            let subscription = availability.$service.sink { service in
                observed.append(service.map(ObjectIdentifier.init))
            }
            XCTAssertNil(availability.service)
            availability.install(first.service)
            availability.install(replacement.service)
            XCTAssertEqual(observed, [nil, ObjectIdentifier(first.service), ObjectIdentifier(replacement.service)])
            XCTAssertTrue(availability.service === replacement.service)
            withExtendedLifetime(subscription) {}
        }

        func testGuidanceUsesCurrentNonHiddenEvidenceAndDoesNotAuthorizeSearch() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            var record = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(record.currentPlan)
            record.phase = .completed
            var attempt = try PromptExperimentAttempt(trial: XCTUnwrap(plan.trials.first), plan: plan)
            attempt.status = .completed
            let artifact = PromptExperimentArtifactReference(sha256: "candidate", relativePath: "candidate.txt", byteCount: 1)
            func partial(split: PromptExperimentDatasetSplit, score: Double, failure: PromptExperimentOptimizationFailureKind? = nil) -> PromptExperimentPartialEvaluation {
                let id = UUID()
                return .init(id: id, candidateEvidence: artifact, evaluation: .init(id: id, candidateIndex: 0, exampleID: "example", split: split, score: score, feedback: "Evidence", failureKind: failure, outputEvidence: nil, elapsedSeconds: nil))
            }
            attempt.partialEvaluations = [partial(split: .hiddenTest, score: 0, failure: .candidate)]
            record.attempts = [attempt]
            XCTAssertEqual(PromptExperimentGuidance.evaluate(record)?.action, "establish_evaluable_execution")
            XCTAssertEqual(PromptExperimentGuidance.evaluate(record)?.evidenceIDs, [])
            let development = partial(split: .training, score: 0, failure: .candidate)
            record.attempts[0].partialEvaluations?.append(development)
            XCTAssertEqual(PromptExperimentGuidance.evaluate(record)?.action, "diagnose_and_probe")
            XCTAssertEqual(PromptExperimentGuidance.evaluate(record)?.evidenceIDs, [development.id.uuidString])
            record.attempts[0].partialEvaluations = [partial(split: .training, score: 1)]
            XCTAssertEqual(PromptExperimentGuidance.evaluate(record)?.action, "review_measurement")
            record.attempts[0].partialEvaluations = [partial(split: .training, score: 0.5)]
            XCTAssertEqual(PromptExperimentGuidance.evaluate(record)?.action, "review_evidence")
            record.attempts[0].status = .failed
            XCTAssertEqual(PromptExperimentGuidance.evaluate(record)?.action, "repair_runtime")
            record.phase = .running
            XCTAssertEqual(PromptExperimentGuidance.evaluate(record)?.action, "repair_runtime")
            record.attempts[0].status = .running
            XCTAssertEqual(PromptExperimentGuidance.evaluate(record)?.action, "monitor")
            record.phase = .cancelled
            XCTAssertEqual(PromptExperimentGuidance.evaluate(record)?.action, "review_interruption")
            // Old-revision failures must never determine the current revision's diagnosis.
            record.phase = .completed
            record.attempts[0].planDigest = "old-revision"
            XCTAssertEqual(PromptExperimentGuidance.evaluate(record)?.action, "establish_evaluable_execution")
            XCTAssertTrue(harness.runtime.submitted.isEmpty)
        }

        func testHiddenTestOutputsAreRedactedFromPartialAndFinalMCPProjections() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            var record = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(record.currentPlan)
            record.phase = .completed
            var attempt = try PromptExperimentAttempt(trial: XCTUnwrap(plan.trials.first), plan: plan)
            attempt.status = .completed
            let candidate = try await harness.store.installArtifact(Data("Candidate prompt".utf8), fileExtension: "txt")
            let hiddenOutput = try await harness.store.installArtifact(Data("hidden answer".utf8), fileExtension: "txt")
            let visibleOutput = try await harness.store.installArtifact(Data("visible answer".utf8), fileExtension: "txt")
            func evaluation(_ split: PromptExperimentDatasetSplit, output: PromptExperimentArtifactReference) -> PromptExperimentEvaluationEvidence {
                .init(id: UUID(), candidateIndex: 0, exampleID: split.rawValue, split: split, score: 0.5, feedback: "Feedback \(split.rawValue)", failureKind: nil, outputEvidence: output, elapsedSeconds: 1)
            }
            let evaluations = [evaluation(.hiddenTest, output: hiddenOutput), evaluation(.validation, output: visibleOutput)]
            attempt.partialEvaluations = evaluations.map { .init(id: $0.id, candidateEvidence: candidate, evaluation: $0) }
            attempt.optimizationResult = PromptExperimentOptimizationResult(
                engine: "gepa", upstreamRevision: "test", baselineScore: 0.5, bestScore: 0.5, bestCandidateIndex: 0,
                candidates: [.init(id: UUID(), index: 0, parentIndices: [], candidateEvidence: candidate, candidatePreview: "Candidate prompt", aggregateScore: 0.5, isBaseline: true, isBest: true)],
                evaluations: evaluations, totalEvaluations: 2, wallTimeSeconds: 1, proposerUsage: "unavailable",
                runDirectoryRelativePath: nil, rawResultEvidence: nil
            )
            record.attempts = [attempt]

            let texts = try await harness.service.readableArtifactText(for: record)
            XCTAssertNil(texts[hiddenOutput.sha256], "Hidden-test output must not be loaded for proposer projections")
            XCTAssertEqual(texts[visibleOutput.sha256], "visible answer")

            // Even if a caller supplies hidden text, the projection itself must withhold it.
            var leakedTexts = texts
            leakedTexts[hiddenOutput.sha256] = "hidden answer"
            let projected = try MCPAgentSessionControlToolProvider.responseValue(.record(record, artifactTextBySHA256: leakedTexts)).objectValue
            let projectedAttempt = try XCTUnwrap(projected?["attempts"]?.arrayValue?.first?.objectValue)

            let partials = try XCTUnwrap(projectedAttempt["partial_evaluations"]?.arrayValue).compactMap(\.objectValue)
            let hiddenPartial = try XCTUnwrap(partials.first { $0["split"]?.stringValue == "hidden_test" })
            XCTAssertEqual(hiddenPartial["output"], .null)
            XCTAssertEqual(hiddenPartial["output_evidence"], .null)
            XCTAssertEqual(hiddenPartial["score"], .double(0.5))
            XCTAssertEqual(hiddenPartial["feedback"]?.stringValue, PromptExperimentDatasetSplit.heldOutFeedback)
            let visiblePartial = try XCTUnwrap(partials.first { $0["split"]?.stringValue == "validation" })
            XCTAssertEqual(visiblePartial["feedback"]?.stringValue, "Feedback validation")
            XCTAssertEqual(visiblePartial["output"]?.stringValue, "visible answer")
            XCTAssertEqual(visiblePartial["output_evidence"]?.objectValue?["sha256"]?.stringValue, visibleOutput.sha256)

            let result = try XCTUnwrap(projectedAttempt["optimization_result"]?.objectValue)
            let finals = try XCTUnwrap(result["evaluations"]?.arrayValue).compactMap(\.objectValue)
            let hiddenFinal = try XCTUnwrap(finals.first { $0["split"]?.stringValue == "hidden_test" })
            XCTAssertEqual(hiddenFinal["output"], .null)
            XCTAssertEqual(hiddenFinal["score"], .double(0.5))
            XCTAssertEqual(hiddenFinal["feedback"]?.stringValue, PromptExperimentDatasetSplit.heldOutFeedback)
            let visibleFinal = try XCTUnwrap(finals.first { $0["split"]?.stringValue == "validation" })
            XCTAssertEqual(visibleFinal["output"]?.stringValue, "visible answer")
            XCTAssertEqual(visibleFinal["feedback"]?.stringValue, "Feedback validation")
            XCTAssertEqual(result["best_score"], .double(0.5))
        }

        /// Records persisted before hidden command feedback was withheld upstream may store grader
        /// feedback (answer keys) verbatim; proposer-facing projections must still replace it.
        func testHistoricalHiddenTestFeedbackIsReplacedInMCPAndOverview() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            var record = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(record.currentPlan)
            record.phase = .completed
            var attempt = try PromptExperimentAttempt(trial: XCTUnwrap(plan.trials.first), plan: plan)
            attempt.status = .completed
            let candidate = try await harness.store.installArtifact(Data("Candidate prompt".utf8), fileExtension: "txt")
            let hiddenPartialMarker = "HIDDEN_PARTIAL_ANSWER_KEY"
            let hiddenFinalMarker = "HIDDEN_FINAL_ANSWER_KEY"
            func evaluation(_ split: PromptExperimentDatasetSplit, feedback: String) -> PromptExperimentEvaluationEvidence {
                .init(id: UUID(), candidateIndex: 0, exampleID: split.rawValue, split: split, score: 0.5, feedback: feedback, failureKind: .candidate, outputEvidence: nil, elapsedSeconds: 1)
            }
            attempt.partialEvaluations = [
                evaluation(.hiddenTest, feedback: "expected \(hiddenPartialMarker)"),
                evaluation(.validation, feedback: "VALIDATION_PARTIAL_FEEDBACK")
            ].map { .init(id: $0.id, candidateEvidence: candidate, evaluation: $0) }
            attempt.optimizationResult = PromptExperimentOptimizationResult(
                engine: "gepa", upstreamRevision: "test", baselineScore: 0.5, bestScore: 0.5, bestCandidateIndex: 0,
                candidates: [.init(id: UUID(), index: 0, parentIndices: [], candidateEvidence: candidate, candidatePreview: "Candidate prompt", aggregateScore: 0.5, isBaseline: true, isBest: true)],
                evaluations: [
                    evaluation(.hiddenTest, feedback: "expected \(hiddenFinalMarker)"),
                    evaluation(.validation, feedback: "VALIDATION_FINAL_FEEDBACK")
                ],
                totalEvaluations: 2, wallTimeSeconds: 1, proposerUsage: "unavailable",
                runDirectoryRelativePath: nil, rawResultEvidence: nil
            )
            record.attempts = [attempt]

            let texts = try await harness.service.readableArtifactText(for: record)
            let projection = try MCPAgentSessionControlToolProvider.responseValue(.record(record, artifactTextBySHA256: texts))
            let serialized = try String(decoding: JSONEncoder().encode(projection), as: UTF8.self)
            XCTAssertFalse(serialized.contains(hiddenPartialMarker))
            XCTAssertFalse(serialized.contains(hiddenFinalMarker))
            XCTAssertTrue(serialized.contains(PromptExperimentDatasetSplit.heldOutFeedback))
            XCTAssertTrue(serialized.contains("VALIDATION_PARTIAL_FEEDBACK"))
            XCTAssertTrue(serialized.contains("VALIDATION_FINAL_FEEDBACK"))

            _ = try await harness.store.saveRecords([record])
            let directory = try await harness.store.recordDirectoryURL(experimentID: id)
            let overview = try String(contentsOf: directory.appendingPathComponent("overview.md"), encoding: .utf8)
            XCTAssertFalse(overview.contains(hiddenPartialMarker))
            XCTAssertFalse(overview.contains(hiddenFinalMarker))
            XCTAssertTrue(overview.contains(PromptExperimentDatasetSplit.heldOutFeedback))
            XCTAssertTrue(overview.contains("VALIDATION_FINAL_FEEDBACK"))
        }

        func testRawGEPAResultAndHiddenOutputPathsAreNotAdvertisedInMCPOrOverview() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            var record = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(record.currentPlan)
            record.phase = .completed
            var attempt = try PromptExperimentAttempt(trial: XCTUnwrap(plan.trials.first), plan: plan)
            attempt.status = .completed
            let candidate = try await harness.store.installArtifact(Data("Candidate prompt".utf8), fileExtension: "txt")
            let hiddenOutput = try await harness.store.installArtifact(Data("HIDDEN_TEST_ANSWER".utf8), fileExtension: "txt")
            let visibleOutput = try await harness.store.installArtifact(Data("VALIDATION_ANSWER".utf8), fileExtension: "txt")
            let rawJSON = Data(#"{"evaluations":[{"split":"hidden_test","output":"HIDDEN_TEST_ANSWER"}]}"#.utf8)
            let rawResult = try await harness.store.installArtifact(rawJSON, fileExtension: "json")
            func evaluation(_ split: PromptExperimentDatasetSplit, output: PromptExperimentArtifactReference) -> PromptExperimentEvaluationEvidence {
                .init(id: UUID(), candidateIndex: 0, exampleID: split.rawValue, split: split, score: 0.5, feedback: "Feedback \(split.rawValue)", failureKind: nil, outputEvidence: output, elapsedSeconds: 1)
            }
            let evaluations = [evaluation(.hiddenTest, output: hiddenOutput), evaluation(.validation, output: visibleOutput)]
            attempt.partialEvaluations = evaluations.map { .init(id: $0.id, candidateEvidence: candidate, evaluation: $0) }
            attempt.optimizationResult = PromptExperimentOptimizationResult(
                engine: "gepa", upstreamRevision: "test", baselineScore: 0.5, bestScore: 0.5, bestCandidateIndex: 0,
                candidates: [.init(id: UUID(), index: 0, parentIndices: [], candidateEvidence: candidate, candidatePreview: "Candidate prompt", aggregateScore: 0.5, isBaseline: true, isBest: true)],
                evaluations: evaluations, totalEvaluations: 2, wallTimeSeconds: 1, proposerUsage: "unavailable",
                runDirectoryRelativePath: "worker-runs/attempt", rawResultEvidence: rawResult
            )
            record.attempts = [attempt]
            let hiddenMarkers = [hiddenOutput.sha256, hiddenOutput.relativePath, rawResult.sha256, rawResult.relativePath, "HIDDEN_TEST_ANSWER"]

            let texts = try await harness.service.readableArtifactText(for: record)
            XCTAssertNil(texts[rawResult.sha256], "The raw GEPA result embeds hidden outputs and must not be read for proposer projections")
            XCTAssertFalse(texts.values.contains { $0.contains("HIDDEN_TEST_ANSWER") })
            XCTAssertEqual(texts[visibleOutput.sha256], "VALIDATION_ANSWER")

            let projection = try MCPAgentSessionControlToolProvider.responseValue(.record(record, artifactTextBySHA256: texts))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let serialized = try String(decoding: encoder.encode(projection), as: UTF8.self)
            for marker in hiddenMarkers {
                XCTAssertFalse(serialized.contains(marker), "MCP projection advertises hidden payload: \(marker)")
            }
            XCTAssertTrue(serialized.contains("VALIDATION_ANSWER"))
            XCTAssertTrue(serialized.contains(visibleOutput.sha256))
            let result = try XCTUnwrap(projection.objectValue?["attempts"]?.arrayValue?.first?.objectValue?["optimization_result"]?.objectValue)
            XCTAssertNil(result["raw_result_evidence"])
            XCTAssertEqual(result["raw_result_persisted"], .bool(true))
            XCTAssertEqual(result["run_directory_relative_path"]?.stringValue, "worker-runs/attempt")
            XCTAssertNotNil(result["run_directory_policy"]?.stringValue)

            _ = try await harness.store.saveRecords([record])
            let directory = try await harness.store.recordDirectoryURL(experimentID: id)
            let overview = try String(contentsOf: directory.appendingPathComponent("overview.md"), encoding: .utf8)
            for marker in hiddenMarkers {
                XCTAssertFalse(overview.contains(marker), "overview.md advertises hidden payload: \(marker)")
            }
            XCTAssertTrue(overview.contains("Output: host-private (hidden test)"))
            XCTAssertTrue(overview.contains("../../\(visibleOutput.relativePath)"))
            XCTAssertTrue(overview.contains("Raw versioned result: persisted host-private"))
            XCTAssertTrue(overview.contains("worker-runs/attempt"))

            // Durable evidence stays stored and inspectable through explicit file access.
            let reloaded = try await harness.store.loadRecords()
            let persisted = try XCTUnwrap(reloaded.first { $0.id == id }?.attempts.first?.optimizationResult)
            XCTAssertEqual(persisted.rawResultEvidence, rawResult)
            let storedRaw = try await harness.store.readArtifact(rawResult)
            let storedHidden = try await harness.store.readArtifact(hiddenOutput)
            XCTAssertEqual(storedRaw, rawJSON)
            XCTAssertEqual(storedHidden, Data("HIDDEN_TEST_ANSWER".utf8))
        }

        func testStartingPointChoiceIsValidatedAndDigestBoundWithoutChangingLegacyEncoding() throws {
            let date = Date(timeIntervalSince1970: 100)
            var draft = PromptExperimentDraft(revision: 1, title: "Seed choice", optimization: Self.validOptimization(), createdAt: date, updatedAt: date)
            let legacyDigest = try draft.contentDigest()
            let legacyJSON = try MCPAgentSessionControlToolProvider.encodeOptimizationSpecification(XCTUnwrap(draft.optimization))
            XCTAssertFalse(legacyJSON.contains("starting_point"))
            draft.optimization?.startingPoint = .choose
            XCTAssertThrowsError(try draft.validated())
            XCTAssertNotEqual(try draft.contentDigest(), legacyDigest)
            draft.optimization?.startingPoint = .gepa
            XCTAssertNoThrow(try draft.validated())
            let seedlessDigest = try draft.contentDigest()
            draft.optimization?.seedCandidate = "Do the task"
            XCTAssertThrowsError(try draft.validated(), "Seedless choice must not mask an agent-written seed")
            draft.optimization?.startingPoint = .supplied
            XCTAssertNoThrow(try draft.validated())
            XCTAssertNotEqual(try draft.contentDigest(), seedlessDigest)
            draft.optimization?.seedCandidate = "   "
            XCTAssertThrowsError(try draft.validated())
            draft.optimization?.startingPoint = nil
            draft.optimization?.seedCandidate = nil
            XCTAssertEqual(try draft.contentDigest(), legacyDigest)
        }

        func testNewDraftAsksForStartingPointWithoutExecutingModels() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await harness.service.createOptimizationExperiment(controllerSessionID: UUID(), sourceTabID: UUID())
            let record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record.draft?.optimization?.startingPoint, .choose)
            XCTAssertEqual(PromptExperimentGuidance.evaluate(record)?.action, "choose_starting_point")
            XCTAssertTrue(harness.runtime.submitted.isEmpty)
            var legacy = record
            legacy.draft?.optimization?.startingPoint = nil
            XCTAssertEqual(PromptExperimentGuidance.evaluate(legacy)?.action, "review_proposal")
        }

        func testPreparationBoundsAndHostAdmissionExcludeHeldOutExamples() throws {
            var spec = Self.validOptimization()
            spec.stage = .preparation
            spec.preparationCandidates = ["Reference instructions", "Revised instructions"]
            spec.examples = [
                PromptExperimentExample(id: "dev-1", split: .training, input: "one", expectedOutput: "1", reviewerNotes: nil),
                PromptExperimentExample(id: "dev-2", split: .training, input: "two", expectedOutput: "2", reviewerNotes: nil),
                PromptExperimentExample(id: "validation", split: .validation, input: "three", expectedOutput: "3", reviewerNotes: nil),
                PromptExperimentExample(id: "hidden", split: .hiddenTest, input: "four", expectedOutput: "4", reviewerNotes: nil)
            ]
            spec.gepa.maxEvaluations = 4
            let date = Date(timeIntervalSince1970: 100)
            var draft = PromptExperimentDraft(revision: 1, title: "Preparation", optimization: spec, createdAt: date, updatedAt: date)
            XCTAssertNoThrow(try draft.validated())
            XCTAssertTrue(spec.admitsPreparationEvaluation(candidate: "Reference instructions", exampleID: "dev-1"))
            XCTAssertFalse(spec.admitsPreparationEvaluation(candidate: "Unreviewed instructions", exampleID: "dev-1"))
            XCTAssertFalse(spec.admitsPreparationEvaluation(candidate: "Reference instructions", exampleID: "validation"))
            XCTAssertFalse(spec.admitsPreparationEvaluation(candidate: "Reference instructions", exampleID: "hidden"))
            let digest = try draft.contentDigest()
            draft.optimization?.preparationCandidates?[1] = "Another revision"
            XCTAssertNotEqual(try draft.contentDigest(), digest)
            draft.optimization?.gepa.maxEvaluations = 3
            XCTAssertThrowsError(try draft.validated())
            draft.optimization?.gepa.maxEvaluations = 4
            draft.optimization?.stage = .search
            XCTAssertThrowsError(try draft.validated(), "Search cannot silently retain a preparation candidate batch")
            draft.optimization?.preparationCandidates = nil
            draft.optimization?.seedCandidate = "Revised instructions"
            XCTAssertNoThrow(try draft.validated())
        }

        func testSearchBudgetMustReserveReportingOnlyHiddenEvaluations() throws {
            var spec = Self.validOptimization()
            spec.examples.append(PromptExperimentExample(
                id: "hidden",
                split: .hiddenTest,
                input: "reporting input",
                expectedOutput: "reporting output",
                reviewerNotes: nil
            ))
            spec.startingPoint = .supplied
            spec.seedCandidate = "Reviewed seed"
            spec.gepa.maxEvaluations = 2
            let date = Date(timeIntervalSince1970: 100)
            var draft = PromptExperimentDraft(
                revision: 1,
                title: "Held-out reserve",
                optimization: spec,
                createdAt: date,
                updatedAt: date
            )
            XCTAssertThrowsError(try draft.validated())
            draft.optimization?.gepa.maxEvaluations = 3
            XCTAssertNoThrow(try draft.validated())

            draft.optimization?.startingPoint = .gepa
            draft.optimization?.seedCandidate = nil
            draft.optimization?.gepa.maxEvaluations = 1
            XCTAssertThrowsError(try draft.validated())
            draft.optimization?.gepa.maxEvaluations = 2
            XCTAssertNoThrow(try draft.validated())
        }

        func testImplementedOperationsMatchCanonicalAdvertisement() {
            XCTAssertEqual(
                PromptExperimentAgentOperation.allCases.map(\.rawValue),
                MCPDomainToolCatalog.promptExperimentOperations
            )
        }

        func testNamespacedPromptExperimentTracksAndRoutesNativePendingCard() {
            let liveToolName = "mcp__repopromptce__prompt_experiment"
            XCTAssertEqual(
                MCPIntegrationHelper.canonicalRepoPromptToolName(liveToolName),
                "prompt_experiment"
            )
            XCTAssertTrue(AgentToolTrackingSupport.isRepoPromptTool(liveToolName))
            XCTAssertEqual(normalizedToolCardName(liveToolName), "prompt_experiment")
            XCTAssertTrue(ToolCardRouter.routesToPromptExperimentCard(toolName: liveToolName))
            XCTAssertTrue(ToolCardRouter.knownResultTools.contains("prompt_experiment"))
        }

        private final class FakeRuntime: PromptExperimentRuntime {
            var submitted: [PromptExperimentRunRequest] = []
            var cancelled: [PromptExperimentRuntimeHandle] = []
            var immediateResults: [Int: PromptExperimentRuntimeResult] = [:]
            var submissionErrors: [Int: PromptExperimentSubmissionError] = [:]
            var holdResults = false
            var holdSubmission = false
            var preflightedPlans: [PromptExperimentPlan] = []
            var preflightError: PromptExperimentAuthorityError?
            var preflightAction: (@MainActor () async throws -> Void)?
            var observationsOnSubmit: [PromptExperimentRuntimeObservation] = []
            var retryRequests: [UUID] = []
            func retryGrading(_: PromptExperimentRuntimeHandle, gradingID: UUID) throws {
                retryRequests.append(gradingID)
            }

            var reportCheckpoint: PromptExperimentCheckpointSink?
            var reportProgress: (@MainActor @Sendable (String) async -> Void)?
            private var submissionGate: CheckedContinuation<Void, Never>?
            private var blockedSubmissionWaiters: [CheckedContinuation<Void, Never>] = []
            private var resultContinuations: [UUID: CheckedContinuation<PromptExperimentRuntimeResult, Never>] = [:]
            private var submissionWaiters: [CheckedContinuation<Void, Never>] = []
            private var resultWaiters: [CheckedContinuation<Void, Never>] = []

            func preflightOptimization(_ plan: PromptExperimentPlan) async throws {
                preflightedPlans.append(plan)
                try await preflightAction?()
                if let preflightError { throw preflightError }
            }

            func submit(
                _ request: PromptExperimentRunRequest,
                progress: @escaping @MainActor @Sendable (String) async -> Void,
                observation: @escaping @MainActor @Sendable (PromptExperimentRuntimeObservation) async -> Void,
                checkpoint: @escaping PromptExperimentCheckpointSink
            ) async throws -> PromptExperimentRuntimeHandle {
                if let error = submissionErrors[request.attempt.ordinal] { throw error }
                if holdSubmission {
                    await withCheckedContinuation {
                        submissionGate = $0
                        let waiters = blockedSubmissionWaiters
                        blockedSubmissionWaiters.removeAll()
                        waiters.forEach { $0.resume() }
                    }
                }
                reportCheckpoint = checkpoint
                reportProgress = progress
                submitted.append(request)
                let waiters = submissionWaiters
                submissionWaiters.removeAll()
                waiters.forEach { $0.resume() }
                await progress("controlled fake accepted")
                for value in observationsOnSubmit {
                    await observation(value)
                }
                return PromptExperimentRuntimeHandle(
                    id: request.attempt.id,
                    tabID: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", request.attempt.ordinal))"),
                    runID: nil
                )
            }

            func wait(for handle: PromptExperimentRuntimeHandle) async -> PromptExperimentRuntimeResult {
                let request = submitted.first(where: { $0.attempt.id == handle.id })
                guard holdResults else {
                    let ordinal = request?.attempt.ordinal ?? 0
                    return immediateResults[ordinal] ?? Self.completed(
                        handle: handle,
                        output: "output-\(ordinal)",
                        fixtureDigest: request?.plan.environment.fixtureDigest ?? "unavailable"
                    )
                }
                return await withCheckedContinuation {
                    resultContinuations[handle.id] = $0
                    let waiters = resultWaiters
                    resultWaiters.removeAll()
                    waiters.forEach { $0.resume() }
                }
            }

            func cancel(_ handle: PromptExperimentRuntimeHandle) async -> PromptExperimentCancellationObservation {
                cancelled.append(handle)
                return .requested
            }

            func waitUntilSubmitBlocked() async {
                if submissionGate != nil { return }
                await withCheckedContinuation { blockedSubmissionWaiters.append($0) }
            }

            func releaseSubmission() {
                submissionGate?.resume()
                submissionGate = nil
            }

            func waitUntilSubmitted() async {
                if !submitted.isEmpty { return }
                await withCheckedContinuation { submissionWaiters.append($0) }
            }

            func waitUntilWaitingForResult() async {
                if !resultContinuations.isEmpty { return }
                await withCheckedContinuation { resultWaiters.append($0) }
            }

            func settleFirst(disposition: PromptExperimentRuntimeDisposition = .completed) {
                guard let request = submitted.first,
                      let continuation = resultContinuations.removeValue(forKey: request.attempt.id)
                else { return }
                continuation.resume(returning: Self.result(
                    handle: PromptExperimentRuntimeHandle(id: request.attempt.id, tabID: nil, runID: nil),
                    disposition: disposition,
                    output: "late-output",
                    fixtureDigest: request.plan.environment.fixtureDigest
                ))
            }

            static func completed(
                handle: PromptExperimentRuntimeHandle,
                output: String,
                fixtureDigest: String
            ) -> PromptExperimentRuntimeResult {
                result(handle: handle, disposition: .completed, output: output, fixtureDigest: fixtureDigest)
            }

            static func result(
                handle: PromptExperimentRuntimeHandle,
                disposition: PromptExperimentRuntimeDisposition,
                output: String?,
                fixtureDigest: String = "fixture",
                selection: StoredSelection = StoredSelection(selectedPaths: ["fixture.md"]),
                assistantOutput: String? = "Done"
            ) -> PromptExperimentRuntimeResult {
                PromptExperimentRuntimeResult(
                    disposition: disposition,
                    runtimeLink: PromptExperimentRuntimeLink(
                        adapter: PromptExperimentPlan.executionAdapter,
                        tabID: handle.tabID,
                        runID: UUID(),
                        provider: "fake",
                        model: "fake-model"
                    ),
                    committedHandoff: output.map {
                        PromptExperimentRuntimeHandoff(
                            prompt: $0,
                            selection: selection,
                            selectionRevision: 7,
                            usedAgentOutputAsPrompt: false
                        )
                    },
                    assistantOutput: assistantOutput,
                    handoffUnavailableReason: output == nil ? "controlled missing handoff" : nil,
                    fixtureDigestBefore: fixtureDigest,
                    fixtureDigestAfter: fixtureDigest
                )
            }
        }

        private actor AsyncGate {
            private var isOpen = false
            private var entered = false
            private var entryWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func wait() async {
                entered = true
                let waiters = entryWaiters
                entryWaiters.removeAll()
                waiters.forEach { $0.resume() }
                guard !isOpen else { return }
                await withCheckedContinuation { releaseWaiters.append($0) }
            }

            func waitUntilEntered() async {
                guard !entered else { return }
                await withCheckedContinuation { entryWaiters.append($0) }
            }

            func open() {
                isOpen = true
                let waiters = releaseWaiters
                releaseWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        private struct Harness {
            let root: URL
            let store: PromptExperimentStore
            let runtime: FakeRuntime
            let service: PromptExperimentService
        }

        func testApprovalRequiresNativeActionAndExactDigest() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)

            do {
                try await harness.service.approve(experimentID: id, displayedDigest: plan.digest, source: .agent)
                XCTFail("Agent approval must be rejected")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .approvalRequiresNativeUI)
            }
            do {
                try await harness.service.approve(experimentID: id, displayedDigest: "wrong")
                XCTFail("Digest mismatch must be rejected")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .digestMismatch)
            }

            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            XCTAssertEqual(harness.service.record(id: id)?.phase, .approved)
            XCTAssertEqual(harness.service.record(id: id)?.approvals.last?.planDigest, plan.digest)
        }

        func testApprovalPersistenceFailureRestoresUnapprovedAuthority() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            try blockCanonicalPersistence(at: harness.root)

            do {
                try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
                XCTFail("Approval must fail when canonical persistence fails")
            } catch {}

            let record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record.phase, .awaitingApproval)
            XCTAssertTrue(record.approvals.isEmpty)
        }

        func testSealPersistenceFailureRestoresDraftAuthority() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let (id, draft) = try await updatedOptimizationDraft(harness)
            try blockCanonicalPersistence(at: harness.root)

            do {
                _ = try await harness.service.seal(
                    experimentID: id,
                    expectedDraftID: draft.id,
                    expectedDraftVersion: draft.optimisticVersion,
                    expectedDraftDigest: draft.contentDigest()
                )
                XCTFail("Seal must fail when canonical persistence fails")
            } catch {}

            let record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record.phase, .drafting)
            XCTAssertEqual(record.draft, draft)
            XCTAssertTrue(record.plans.isEmpty)
        }

        func testRunPersistenceFailureRestoresExactApprovedAuthority() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            let approved = try XCTUnwrap(harness.service.record(id: id))
            try blockCanonicalPersistence(at: harness.root)

            do {
                try await harness.service.run(experimentID: id)
                XCTFail("Run admission must fail when its canonical state cannot be persisted")
            } catch {}

            let record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record, approved)
            XCTAssertTrue(harness.runtime.submitted.isEmpty)
        }

        func testPersistenceReopenAndReadableViews() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await reopened.load()
            XCTAssertNil(reopened.loadError)
            XCTAssertEqual(reopened.record(id: id)?.currentPlan?.digest, plan.digest)
            XCTAssertEqual(reopened.record(id: id)?.phase, .approved)

            let directory = try await reopened.recordDirectoryURL(experimentID: id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("overview.md").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("plan.json").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("results.csv").path))
        }

        func testCorruptCanonicalStoreIsVisibleAndNotReplaced() async throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let canonical = root.appendingPathComponent("experiments.json")
            let bytes = Data("not-json".utf8)
            try bytes.write(to: canonical)
            let service = PromptExperimentService(
                store: PromptExperimentStore(rootURL: root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )

            await service.load()

            XCTAssertNotNil(service.loadError)
            XCTAssertEqual(try Data(contentsOf: canonical), bytes)
        }

        func testScheduleIdentityIsDeterministicAndInterleaved() throws {
            let date = Date(timeIntervalSince1970: 100)
            let draft = Self.validDraft(date: date, repetitions: 3)
            let environment = try PromptExperimentEnvironment(
                workspaceID: XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                sourceTabID: XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
                capturedAt: date,
                isolatedRootPath: "/tmp/synthetic",
                selection: StoredSelection(selectedPaths: ["/tmp/synthetic/fixture.md"]),
                fixtureFiles: [PromptExperimentFixtureFile(path: "/tmp/synthetic/fixture.md", byteCount: 1, sha256: "fixture")],
                fixtureDigest: "fixture",
                captureLimitations: ["synthetic"]
            )
            let first = try PromptExperimentPlan.seal(draft: draft, target: XCTUnwrap(Self.fakeTarget("explore")), environment: environment, at: date)
            let second = try PromptExperimentPlan.seal(draft: draft, target: XCTUnwrap(Self.fakeTarget("explore")), environment: environment, at: date.addingTimeInterval(50))

            XCTAssertEqual(first.digest, second.digest)
            XCTAssertEqual(first.trials.map(\.id), second.trials.map(\.id))
            let expected: [PromptExperimentCondition] = [.original, .candidate, .candidate, .original, .original, .candidate]
            XCTAssertEqual(first.trials.map(\.condition), expected)
            XCTAssertEqual(Set(first.trials.map(\.id)).count, first.trials.count)
        }

        func testTamperedScheduleInvalidatesApprovedPlanDigest() throws {
            let date = Date(timeIntervalSince1970: 100)
            let draft = Self.validDraft(date: date, repetitions: 1)
            let environment = PromptExperimentEnvironment(
                workspaceID: UUID(),
                sourceTabID: UUID(),
                capturedAt: date,
                isolatedRootPath: "/tmp/synthetic",
                selection: StoredSelection(selectedPaths: ["/tmp/synthetic/fixture.md"]),
                fixtureFiles: [PromptExperimentFixtureFile(path: "/tmp/synthetic/fixture.md", byteCount: 1, sha256: "fixture")],
                fixtureDigest: "fixture",
                captureLimitations: []
            )
            let plan = try PromptExperimentPlan.seal(
                draft: draft,
                target: XCTUnwrap(Self.fakeTarget("explore")),
                environment: environment,
                at: date
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(plan)) as? [String: Any])
            var trials = try XCTUnwrap(object["trials"] as? [[String: Any]])
            trials[0]["condition"] = PromptExperimentCondition.candidate.rawValue
            object["trials"] = trials
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let tampered = try decoder.decode(
                PromptExperimentPlan.self,
                from: JSONSerialization.data(withJSONObject: object)
            )

            XCTAssertFalse(tampered.verifiesIntegrity())
        }

        func testSubmissionUncertainStopsWithoutRetry() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.submissionErrors[1] = .acceptanceUnknown("transport lost after send")
            let id = try await approvedExperiment(harness)

            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record.phase, .inconclusive)
            XCTAssertEqual(record.attempts.first?.status, .submissionUncertain)
            XCTAssertTrue(harness.runtime.submitted.isEmpty)
            XCTAssertEqual(record.attempts.dropFirst().first?.status, .planned)
        }

        func testRuntimeFailureRetainsSerialScheduleAndEvidence() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.immediateResults[1] = FakeRuntime.result(
                handle: PromptExperimentRuntimeHandle(id: UUID(), tabID: nil, runID: nil),
                disposition: .failed("controlled failure"),
                output: "failure evidence"
            )
            let id = try await approvedExperiment(harness)

            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(harness.runtime.submitted.map(\.attempt.ordinal), [1, 2])
            XCTAssertEqual(record.phase, .inconclusive)
            XCTAssertEqual(record.attempts.map(\.status), [.failed, .completed])
            XCTAssertNotNil(record.attempts.first?.committedHandoff)
        }

        func testCancellationPreservesRequestedThenLateSettlement() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdResults = true
            let id = try await approvedExperiment(harness)
            try await harness.service.run(experimentID: id)
            await harness.runtime.waitUntilSubmitted()
            await harness.runtime.waitUntilWaitingForResult()

            try await harness.service.cancel(experimentID: id)
            var record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record.phase, .cancelling)
            XCTAssertEqual(record.attempts.first?.status, .cancellationRequested)
            XCTAssertEqual(harness.runtime.cancelled.count, 1)

            harness.runtime.settleFirst()
            await harness.service.waitForExecutionForTesting(experimentID: id)
            record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record.phase, .cancelled)
            XCTAssertEqual(record.attempts.first?.status, .cancelledSettled)
            XCTAssertEqual(record.attempts.first?.lateResultAfterCancellation, true)
            XCTAssertNotNil(record.attempts.first?.committedHandoff)
            XCTAssertEqual(record.attempts.dropFirst().first?.status, .planned)
        }

        func testCancellationDuringSubmissionIsForwardedAfterAcceptance() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdSubmission = true
            harness.runtime.holdResults = true
            let id = try await approvedExperiment(harness)
            try await harness.service.run(experimentID: id)
            await harness.runtime.waitUntilSubmitBlocked()
            do {
                try await harness.service.run(experimentID: id)
                XCTFail("Duplicate run admission must be rejected")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .experimentAlreadyRunning)
            }

            try await harness.service.cancel(experimentID: id)
            XCTAssertEqual(harness.service.record(id: id)?.attempts.first?.status, .cancellationRequested)
            XCTAssertTrue(harness.runtime.cancelled.isEmpty)

            harness.runtime.releaseSubmission()
            await harness.runtime.waitUntilWaitingForResult()
            XCTAssertEqual(harness.runtime.cancelled.count, 1)
            harness.runtime.settleFirst(disposition: .cancelled)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record.phase, .cancelled)
            XCTAssertEqual(record.attempts.first?.status, .cancelledSettled)
            XCTAssertEqual(record.attempts.first?.lateResultAfterCancellation, true)
        }

        func testReopenMarksInFlightSubmissionUncertain() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdResults = true
            let id = try await approvedExperiment(harness)
            try await harness.service.run(experimentID: id)
            await harness.runtime.waitUntilSubmitted()
            await harness.runtime.waitUntilWaitingForResult()

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await reopened.load()
            let reopenedRecord = try XCTUnwrap(reopened.record(id: id))
            XCTAssertEqual(reopenedRecord.phase, .inconclusive)
            XCTAssertEqual(reopenedRecord.attempts.first?.status, .submissionUncertain)

            try await harness.service.cancel(experimentID: id)
            harness.runtime.settleFirst(disposition: .cancelled)
            await harness.service.waitForExecutionForTesting(experimentID: id)
        }

        func testDraftOptimisticVersionRejectsStaleRepeatedUpdate() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            await harness.service.load()
            let id = try await harness.service.createExperiment(controllerSessionID: UUID(), sourceTabID: UUID())
            var original = try XCTUnwrap(harness.service.record(id: id)?.draft)
            let originalDigest = try original.contentDigest()
            original.title = "First writer"
            let updated = try await harness.service.updateDraft(
                experimentID: id,
                expectedDraftID: original.id,
                expectedDraftVersion: original.optimisticVersion,
                expectedDraftDigest: originalDigest,
                draft: original
            )
            XCTAssertEqual(updated.optimisticVersion, 2)

            do {
                original.title = "Stale writer"
                try await harness.service.updateDraft(
                    experimentID: id,
                    expectedDraftID: original.id,
                    expectedDraftVersion: 1,
                    expectedDraftDigest: originalDigest,
                    draft: original
                )
                XCTFail("A repeated update from version 1 must be rejected")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .staleDraft)
            }
        }

        func testAgentDraftToNativeSealedProposalIsSessionOwnedAndUnprivileged() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let owner = PromptExperimentAgentOwner(controllerSessionID: UUID(), sourceTabID: UUID())
            let otherOwner = PromptExperimentAgentOwner(controllerSessionID: UUID(), sourceTabID: UUID())
            let interface = PromptExperimentAgentInterface(service: harness.service)

            let capabilities = try await interface.execute(.capabilities, owner: owner)
            guard case let .capabilities(operations, targets, gepaRuntime, _) = capabilities else {
                return XCTFail("Expected capabilities")
            }
            let external = try MCPAgentSessionControlToolProvider.responseValue(capabilities, usesMCPApproval: true).objectValue
            XCTAssertEqual(external?["native_approval_required"], .bool(false))
            XCTAssertEqual(external?["user_approval_required"], .bool(true))
            let native = try MCPAgentSessionControlToolProvider.responseValue(capabilities).objectValue
            XCTAssertEqual(native?["native_approval_required"], .bool(true))
            XCTAssertFalse(operations.contains("approve"))
            XCTAssertTrue(operations.contains("run"))
            XCTAssertTrue(operations.contains("wait"))
            XCTAssertTrue(operations.contains("cancel"))
            XCTAssertEqual(targets.map(\.selector), harness.service.availableTargets().map(\.selector))
            XCTAssertEqual(gepaRuntime.pinnedRevision, PromptExperimentGEPAConfiguration.pinnedRevision)

            let createdResponse = try await interface.execute(.createDraft, owner: owner)
            guard case let .draft(id, created) = createdResponse else { return XCTFail("Expected draft") }
            let createdValue = try MCPAgentSessionControlToolProvider.responseValue(createdResponse).objectValue
            let preconditions = createdValue?["update_preconditions"]?.objectValue
            XCTAssertEqual(preconditions?["experiment_id"], .string(id.uuidString))
            XCTAssertEqual(preconditions?["expected_draft_id"], .string(created.id.uuidString))
            XCTAssertEqual(preconditions?["expected_draft_version"], .string("1"))
            XCTAssertEqual(preconditions?["expected_draft_digest"], try .string(created.contentDigest()))
            let contract = createdValue?["authoring_contract"]?.objectValue
            XCTAssertEqual(contract?["schema_version"], .int(3))
            let exampleTemplate = contract?["examples"]?.objectValue?["template"]?.objectValue
            XCTAssertEqual(exampleTemplate?["id"], .string("case-id"))
            XCTAssertEqual(exampleTemplate?["split"], .string("training"))
            let updatedResponse = try await interface.execute(.updateDraft(
                experimentID: id,
                expectedDraftID: created.id,
                expectedDraftVersion: created.optimisticVersion,
                expectedDraftDigest: created.contentDigest(),
                patch: PromptExperimentAgentDraftPatch(
                    title: "Agent proposal",
                    taskInput: "Report the value.",
                    syntheticFixture: "The value is cobalt.",
                    originalInstructions: "Read and answer.",
                    candidateInstructions: "Read, cite, and answer.",
                    targetRole: "explore",
                    repetitions: 1,
                    optimization: Self.validOptimization()
                )
            ), owner: owner)
            guard case let .draft(_, updated) = updatedResponse else { return XCTFail("Expected updated draft") }

            do {
                _ = try await interface.execute(.read(experimentID: id), owner: otherOwner)
                XCTFail("A different Agent session must not read the experiment")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .ownerMismatch)
            }

            _ = try await interface.execute(.proposeSeal(
                experimentID: id,
                expectedDraftID: updated.id,
                expectedDraftVersion: updated.optimisticVersion,
                expectedDraftDigest: updated.contentDigest()
            ), owner: owner)
            let sealed = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(sealed.phase, .awaitingApproval)
            XCTAssertEqual(sealed.currentPlan?.schemaVersion, PromptExperimentPlan.optimizationSchemaVersion)
            XCTAssertTrue(harness.runtime.preflightedPlans.isEmpty, "Preflight must not probe the external runtime before native approval")
            XCTAssertNil(PromptExperimentAgentOperation(rawValue: "approve"))
            XCTAssertEqual(PromptExperimentAgentOperation(rawValue: "run"), .run)

            let plan = try XCTUnwrap(sealed.currentPlan)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            XCTAssertEqual(harness.service.record(id: id)?.phase, .approved)

            let cloneResponse = try await interface.execute(.cloneDraft(experimentID: id), owner: owner)
            guard case let .draft(cloneID, cloneDraft) = cloneResponse else { return XCTFail("Expected owned clone draft") }
            XCTAssertNotEqual(cloneID, id)
            XCTAssertEqual(cloneDraft.optimization, plan.optimization)
            do {
                _ = try await interface.execute(.cloneDraft(experimentID: id), owner: otherOwner)
                XCTFail("A different Agent session must not clone the experiment")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .ownerMismatch)
            }
        }

        func testSetupSealsCompleteSessionProposalWithBundledRuntime() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            await harness.service.load()
            let owner = PromptExperimentAgentOwner(controllerSessionID: UUID(), sourceTabID: UUID())
            let interface = PromptExperimentAgentInterface(service: harness.service)

            let response = try await interface.execute(.setup(patch: PromptExperimentAgentDraftPatch(
                title: "Session lab",
                taskInput: nil,
                syntheticFixture: nil,
                originalInstructions: nil,
                candidateInstructions: nil,
                targetRole: nil,
                repetitions: nil,
                optimization: Self.validOptimization()
            )), owner: owner)

            guard case let .sealed(id, plan) = response else { return XCTFail("Expected sealed proposal") }
            XCTAssertEqual(harness.service.record(id: id)?.phase, .awaitingApproval)
            XCTAssertEqual(plan.optimization?.gepa.pythonExecutablePath, PromptExperimentGEPAWorker.configuredPythonSealValue())
            XCTAssertEqual(harness.service.record(id: id)?.controllerSessionID, owner.controllerSessionID)
            XCTAssertTrue(plan.limitations.contains { $0.contains("bundled CPython runtime") })
            XCTAssertFalse(plan.limitations.contains { $0.contains("separately configured Python") })
        }

        func testInvalidSetupDoesNotPersistProbeDraft() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            await harness.service.load()
            let owner = PromptExperimentAgentOwner(controllerSessionID: UUID(), sourceTabID: UUID())
            let interface = PromptExperimentAgentInterface(service: harness.service)
            var invalid = Self.validOptimization()
            invalid.examples = []

            do {
                _ = try await interface.execute(.setup(patch: PromptExperimentAgentDraftPatch(
                    title: "Invalid schema probe",
                    taskInput: nil,
                    syntheticFixture: nil,
                    originalInstructions: nil,
                    candidateInstructions: nil,
                    targetRole: nil,
                    repetitions: nil,
                    optimization: invalid
                )), owner: owner)
                XCTFail("Invalid setup must fail before persistence")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .invalidDraft("Add at least one reviewed evaluation example."))
            }
            let ownedRecords = try await harness.service.ownedRecords(
                controllerSessionID: owner.controllerSessionID
            )
            XCTAssertTrue(ownedRecords.isEmpty)
        }

        func testHandlerParsesRunWaitAndRevisionAliases() throws {
            let experimentID = UUID()
            let digest = "digest"
            let wait = try MCPAgentSessionControlToolProvider.promptExperimentCommand(args: [
                "op": .string("wait"),
                "experiment_id": .string(experimentID.uuidString),
                "expected_plan_digest": .string(digest),
                "timeout_seconds": .int(7)
            ])
            guard case let .wait(parsedID, parsedDigest, timeout) = wait else {
                return XCTFail("Expected wait command")
            }
            XCTAssertEqual(parsedID, experimentID)
            XCTAssertEqual(parsedDigest, digest)
            XCTAssertEqual(timeout, 7)

            let next = try MCPAgentSessionControlToolProvider.promptExperimentCommand(args: [
                "op": .string("continue"),
                "experiment_id": .string(experimentID.uuidString),
                "expected_plan_digest": .string(digest),
                "candidate_index": .int(2)
            ])
            guard case let .proposeNextRevision(parsedID, parsedDigest, candidateIndex) = next else {
                return XCTFail("Expected continue alias")
            }
            XCTAssertEqual(parsedID, experimentID)
            XCTAssertEqual(parsedDigest, digest)
            XCTAssertEqual(candidateIndex, 2)
        }

        func testHandlerParsesNormalizedSetupAndUpdateSpecificationEnvelope() throws {
            let specification = Self.validOptimization()
            let specificationJSON = try MCPAgentSessionControlToolProvider.encodeOptimizationSpecification(specification)
            let envelope = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(specificationJSON.utf8)) as? [String: Any]
            )
            XCTAssertEqual(envelope["schema_version"] as? Int, 3)
            XCTAssertNil(envelope["schemaVersion"])

            let setupArgs = MCPToolArgsNormalizer.normalize(
                params: [
                    "op": .string("setup"),
                    "specification_json": .string(specificationJSON)
                ],
                originalToolName: "prompt_experiment",
                canonicalToolName: "prompt_experiment"
            ).payload
            XCTAssertNotNil(setupArgs["specification_json"]?.objectValue)
            let setup = try MCPAgentSessionControlToolProvider.promptExperimentCommand(args: setupArgs)
            guard case let .setup(patch) = setup else { return XCTFail("Expected setup command") }
            XCTAssertEqual(patch.optimization, specification)

            let experimentID = UUID()
            let draftID = UUID()
            let updateArgs = MCPToolArgsNormalizer.normalize(
                params: [
                    "op": .string("update_draft"),
                    "experiment_id": .string(experimentID.uuidString),
                    "expected_draft_id": .string(draftID.uuidString),
                    "expected_draft_version": .int(3),
                    "expected_draft_digest": .string("draft-digest"),
                    "specification_json": .string(specificationJSON)
                ],
                originalToolName: "prompt_experiment",
                canonicalToolName: "prompt_experiment"
            ).payload
            XCTAssertNotNil(updateArgs["specification_json"]?.objectValue)
            let update = try MCPAgentSessionControlToolProvider.promptExperimentCommand(args: updateArgs)
            guard case let .updateDraft(
                parsedExperimentID,
                parsedDraftID,
                parsedVersion,
                parsedDigest,
                patch
            ) = update else {
                return XCTFail("Expected update_draft command")
            }
            XCTAssertEqual(parsedExperimentID, experimentID)
            XCTAssertEqual(parsedDraftID, draftID)
            XCTAssertEqual(parsedVersion, 3)
            XCTAssertEqual(parsedDigest, "draft-digest")
            XCTAssertEqual(patch.optimization, specification)

            let stringVersionArgs = updateArgs.merging([
                "expected_draft_version": .string("3")
            ]) { _, replacement in replacement }
            let stringVersionUpdate = try MCPAgentSessionControlToolProvider.promptExperimentCommand(args: stringVersionArgs)
            guard case let .updateDraft(_, _, stringVersion, _, _) = stringVersionUpdate else {
                return XCTFail("Expected string-version update_draft command")
            }
            XCTAssertEqual(stringVersion, 3)

            let doubleVersionArgs = updateArgs.merging([
                "expected_draft_version": .double(3)
            ]) { _, replacement in replacement }
            let doubleVersionUpdate = try MCPAgentSessionControlToolProvider.promptExperimentCommand(args: doubleVersionArgs)
            guard case let .updateDraft(_, _, doubleVersion, _, _) = doubleVersionUpdate else {
                return XCTFail("Expected exact-double-version update_draft command")
            }
            XCTAssertEqual(doubleVersion, 3)

            let fractionalVersionArgs = updateArgs.merging([
                "expected_draft_version": .double(3.5)
            ]) { _, replacement in replacement }
            XCTAssertThrowsError(
                try MCPAgentSessionControlToolProvider.promptExperimentCommand(args: fractionalVersionArgs)
            )

            let booleanVersionArgs = updateArgs.merging([
                "expected_draft_version": .bool(true)
            ]) { _, replacement in replacement }
            let booleanVersionUpdate = try MCPAgentSessionControlToolProvider.promptExperimentCommand(args: booleanVersionArgs)
            guard case let .updateDraft(_, _, booleanVersion, _, _) = booleanVersionUpdate else {
                return XCTFail("Expected provider-coerced version update_draft command")
            }
            XCTAssertEqual(booleanVersion, 1)

            let falseVersionArgs = updateArgs.merging([
                "expected_draft_version": .bool(false)
            ]) { _, replacement in replacement }
            XCTAssertThrowsError(
                try MCPAgentSessionControlToolProvider.promptExperimentCommand(args: falseVersionArgs)
            )
        }

        func testHandlerRejectsMalformedAndUnsupportedNormalizedSpecificationEnvelopes() throws {
            let malformedArgs = MCPToolArgsNormalizer.normalize(
                params: [
                    "op": .string("setup"),
                    "specification_json": .string(#"{"schema_version":2}"#)
                ],
                originalToolName: "prompt_experiment",
                canonicalToolName: "prompt_experiment"
            ).payload
            XCTAssertNotNil(malformedArgs["specification_json"]?.objectValue)
            XCTAssertThrowsError(
                try MCPAgentSessionControlToolProvider.promptExperimentCommand(args: malformedArgs)
            ) { error in
                guard case let MCPError.invalidParams(message) = error else {
                    return XCTFail("Expected invalidParams, got \(error)")
                }
                XCTAssertTrue(message?.contains("Invalid specification_json") == true)
            }

            let specificationJSON = try MCPAgentSessionControlToolProvider.encodeOptimizationSpecification(
                Self.validOptimization()
            )
            var unsupportedEnvelope = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(specificationJSON.utf8)) as? [String: Any]
            )
            unsupportedEnvelope["schema_version"] = 99
            let unsupportedJSON = try String(decoding: JSONSerialization.data(withJSONObject: unsupportedEnvelope), as: UTF8.self)
            let unsupportedArgs = MCPToolArgsNormalizer.normalize(
                params: [
                    "op": .string("setup"),
                    "specification_json": .string(unsupportedJSON)
                ],
                originalToolName: "prompt_experiment",
                canonicalToolName: "prompt_experiment"
            ).payload
            XCTAssertNotNil(unsupportedArgs["specification_json"]?.objectValue)
            XCTAssertThrowsError(
                try MCPAgentSessionControlToolProvider.promptExperimentCommand(args: unsupportedArgs)
            ) { error in
                guard case let MCPError.invalidParams(message) = error else {
                    return XCTFail("Expected invalidParams, got \(error)")
                }
                XCTAssertEqual(message, "Unsupported optimization specification schema 99")
            }

            var missingIDEnvelope = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(specificationJSON.utf8)) as? [String: Any]
            )
            var missingIDSpecification = try XCTUnwrap(missingIDEnvelope["specification"] as? [String: Any])
            var missingIDExamples = try XCTUnwrap(missingIDSpecification["examples"] as? [[String: Any]])
            missingIDExamples[0].removeValue(forKey: "id")
            missingIDSpecification["examples"] = missingIDExamples
            missingIDEnvelope["specification"] = missingIDSpecification
            let missingIDJSON = try String(
                decoding: JSONSerialization.data(withJSONObject: missingIDEnvelope),
                as: UTF8.self
            )
            XCTAssertThrowsError(
                try MCPAgentSessionControlToolProvider.promptExperimentCommand(args: [
                    "op": .string("setup"),
                    "specification_json": .string(missingIDJSON)
                ])
            ) { error in
                guard case let MCPError.invalidParams(message) = error else {
                    return XCTFail("Expected invalidParams, got \(error)")
                }
                XCTAssertEqual(
                    message,
                    "Invalid specification_json: missing required field specification.examples[0].id"
                )
            }
        }

        func testSessionRunApprovalAutomaticallyStartsWaitsCompletesAndClones() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdResults = true
            let id = try await preparedOptimizationExperiment(harness)
            let sealed = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(sealed.currentPlan)
            let owner = PromptExperimentAgentOwner(
                controllerSessionID: sealed.controllerSessionID,
                sourceTabID: sealed.sourceTabID
            )
            let interface = PromptExperimentAgentInterface(service: harness.service)

            let runRequest = Task {
                try await interface.execute(.run(experimentID: id, expectedPlanDigest: plan.digest), owner: owner)
            }
            await harness.service.waitForPendingRunApprovalForTesting(experimentID: id)
            XCTAssertTrue(harness.service.hasPendingRunApproval(experimentID: id, planDigest: plan.digest))
            XCTAssertTrue(harness.runtime.submitted.isEmpty)

            try await harness.service.approveAndRun(experimentID: id, displayedDigest: plan.digest)
            guard case let .record(started, _) = try await runRequest.value else {
                return XCTFail("Expected started record")
            }
            XCTAssertEqual(started.phase, .running)
            await harness.runtime.waitUntilWaitingForResult()

            let waitRequest = Task {
                try await interface.execute(
                    .wait(experimentID: id, expectedPlanDigest: plan.digest, timeoutSeconds: 30),
                    owner: owner
                )
            }
            harness.runtime.settleFirst()
            guard case let .record(completed, _) = try await waitRequest.value else {
                return XCTFail("Expected completed record")
            }
            XCTAssertEqual(completed.phase, .completed)
            XCTAssertEqual(completed.attempts(for: plan).count, 1)

            let clone = try await interface.execute(.cloneDraft(experimentID: id), owner: owner)
            guard case let .draft(cloneID, cloneDraft) = clone else { return XCTFail("Expected clone draft") }
            XCTAssertNotEqual(cloneID, id)
            XCTAssertEqual(cloneDraft.optimization, plan.optimization)
        }

        func testPendingRunPinsOriginatingRuntimeAcrossWindowRebindAttempt() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdResults = true
            let id = try await preparedOptimizationExperiment(harness)
            let sealed = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(sealed.currentPlan)
            let owner = PromptExperimentAgentOwner(
                controllerSessionID: sealed.controllerSessionID,
                sourceTabID: sealed.sourceTabID
            )
            let interface = PromptExperimentAgentInterface(service: harness.service)
            let originatingWindow = NSObject()
            let otherWindow = NSObject()
            let otherWindowRuntime = FakeRuntime()
            XCTAssertTrue(harness.service.bindRuntimeIfIdle(
                harness.runtime,
                bindingIdentity: ObjectIdentifier(originatingWindow)
            ))

            let runRequest = Task {
                try await interface.execute(.run(experimentID: id, expectedPlanDigest: plan.digest), owner: owner)
            }
            await harness.service.waitForPendingRunApprovalForTesting(experimentID: id)

            XCTAssertTrue(harness.service.bindRuntimeIfIdle(
                otherWindowRuntime,
                bindingIdentity: ObjectIdentifier(originatingWindow)
            ))
            XCTAssertFalse(harness.service.bindRuntimeIfIdle(
                otherWindowRuntime,
                bindingIdentity: ObjectIdentifier(otherWindow)
            ))
            try await harness.service.approveAndRun(experimentID: id, displayedDigest: plan.digest)
            _ = try await runRequest.value
            await harness.runtime.waitUntilWaitingForResult()

            XCTAssertEqual(harness.runtime.submitted.count, 1)
            XCTAssertTrue(otherWindowRuntime.submitted.isEmpty)
            harness.runtime.settleFirst()
            await harness.service.waitForExecutionForTesting(experimentID: id)
        }

        func testNativeDenialReturnsNewDraftToWaitingSession() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            let sealed = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(sealed.currentPlan)
            let owner = PromptExperimentAgentOwner(
                controllerSessionID: sealed.controllerSessionID,
                sourceTabID: sealed.sourceTabID
            )
            let interface = PromptExperimentAgentInterface(service: harness.service)
            let runRequest = Task {
                try await interface.execute(.run(experimentID: id, expectedPlanDigest: plan.digest), owner: owner)
            }
            await harness.service.waitForPendingRunApprovalForTesting(experimentID: id)

            try await harness.service.declineRunAndRevise(experimentID: id, displayedDigest: plan.digest, feedback: "Add ambiguous cases; preserve the model.")
            guard case let .record(revision, _) = try await runRequest.value else {
                return XCTFail("Expected revised record")
            }
            XCTAssertEqual(revision.phase, .drafting)
            XCTAssertTrue(revision.statusMessage.contains("Add ambiguous cases; preserve the model."))
            let saved = try await harness.store.loadRecords()
            XCTAssertEqual(saved.first(where: { $0.id == id })?.statusMessage, revision.statusMessage)
            XCTAssertEqual(revision.currentPlan, plan)
            XCTAssertEqual(revision.draft?.revision, plan.revision + 1)
            XCTAssertEqual(revision.draft?.parentPlanID, plan.id)
            XCTAssertTrue(harness.runtime.submitted.isEmpty)
            XCTAssertTrue(harness.runtime.preflightedPlans.isEmpty)
        }

        func testCancellingSessionRunWhileApprovalPendingLeavesPlanUnapproved() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            let sealed = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(sealed.currentPlan)
            let owner = PromptExperimentAgentOwner(
                controllerSessionID: sealed.controllerSessionID,
                sourceTabID: sealed.sourceTabID
            )
            let interface = PromptExperimentAgentInterface(service: harness.service)
            let runRequest = Task {
                try await interface.execute(.run(experimentID: id, expectedPlanDigest: plan.digest), owner: owner)
            }
            await harness.service.waitForPendingRunApprovalForTesting(experimentID: id)

            runRequest.cancel()
            do {
                _ = try await runRequest.value
                XCTFail("Cancelled pending run must not return a started record")
            } catch is CancellationError {
                // Expected: cancellation resolves the pending interaction without approving the plan.
            }
            XCTAssertEqual(harness.service.record(id: id)?.phase, .awaitingApproval)
            XCTAssertFalse(harness.service.hasPendingRunApproval(experimentID: id, planDigest: plan.digest))
            XCTAssertTrue(harness.runtime.submitted.isEmpty)
            XCTAssertTrue(harness.service.record(id: id)?.statusMessage.contains("cancelled") == true)

            let persisted = try await harness.store.loadRecords()
            XCTAssertTrue(persisted.first(where: { $0.id == id })?.statusMessage.contains("cancelled") == true)
            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget,
                now: { Date(timeIntervalSince1970: 1001) }
            )
            await reopened.load()
            XCTAssertTrue(reopened.record(id: id)?.statusMessage.contains("cancelled") == true)
        }

        func testReloadClearsStalePendingApprovalStatusWithoutApprovingOrRunning() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            var stale = try XCTUnwrap(harness.service.record(id: id))
            stale.statusMessage = "Run requested by this Agent session. Review the exact sealed digest below; Approve & Run starts automatically."
            _ = try await harness.store.saveRecords([stale])

            let reopenedRuntime = FakeRuntime()
            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: reopenedRuntime,
                resolveTarget: Self.fakeTarget,
                now: { Date(timeIntervalSince1970: 1001) }
            )
            await reopened.load()

            let recovered = try XCTUnwrap(reopened.record(id: id))
            XCTAssertEqual(recovered.phase, .awaitingApproval)
            XCTAssertTrue(recovered.approvals.isEmpty)
            XCTAssertTrue(recovered.attempts.isEmpty)
            XCTAssertTrue(recovered.statusMessage.contains("no native approval is pending"))
            XCTAssertTrue(reopenedRuntime.submitted.isEmpty)
            let persisted = try await harness.store.loadRecords()
            XCTAssertTrue(
                persisted.first(where: { $0.id == id })?.statusMessage.contains("no native approval is pending") == true
            )
        }

        func testRunRequestRejectsStaleDigestAndWrongOwner() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            let sealed = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(sealed.currentPlan)
            let owner = PromptExperimentAgentOwner(
                controllerSessionID: sealed.controllerSessionID,
                sourceTabID: sealed.sourceTabID
            )
            let other = PromptExperimentAgentOwner(controllerSessionID: UUID(), sourceTabID: UUID())
            let interface = PromptExperimentAgentInterface(service: harness.service)

            do {
                _ = try await interface.execute(.run(experimentID: id, expectedPlanDigest: plan.digest), owner: other)
                XCTFail("Wrong owner must not request a run")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .ownerMismatch)
            }
            do {
                _ = try await interface.execute(.run(experimentID: id, expectedPlanDigest: "stale"), owner: owner)
                XCTFail("Stale digest must not request a run")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .digestMismatch)
            }
            do {
                try await harness.service.approveAndRun(experimentID: id, displayedDigest: plan.digest)
                XCTFail("Native approval without an owner-bound run request must not start")
            } catch let error as PromptExperimentAuthorityError {
                guard case .illegalPhase = error else { return XCTFail("Expected illegal phase, got \(error)") }
            }
            let runRequest = Task {
                try await interface.execute(.run(experimentID: id, expectedPlanDigest: plan.digest), owner: owner)
            }
            await harness.service.waitForPendingRunApprovalForTesting(experimentID: id)
            do {
                try await harness.service.approveAndRun(experimentID: id, displayedDigest: "stale")
                XCTFail("Stale native approval must not start")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .digestMismatch)
            }
            do {
                _ = try await runRequest.value
                XCTFail("The waiting run request must receive the stale approval failure")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .digestMismatch)
            }
            XCTAssertEqual(harness.service.record(id: id)?.phase, .awaitingApproval)
            XCTAssertFalse(harness.service.hasPendingRunApproval(experimentID: id, planDigest: plan.digest))
            XCTAssertTrue(harness.runtime.submitted.isEmpty)
        }

        func testApprovedRecordResumesAfterServiceRestart() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            let sealed = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(sealed.currentPlan)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)

            let reopenedRuntime = FakeRuntime()
            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: reopenedRuntime,
                resolveTarget: Self.fakeTarget,
                now: { Date(timeIntervalSince1970: 1001) }
            )
            await reopened.load()
            let owner = PromptExperimentAgentOwner(
                controllerSessionID: sealed.controllerSessionID,
                sourceTabID: sealed.sourceTabID
            )
            let response = try await PromptExperimentAgentInterface(service: reopened).execute(
                .run(experimentID: id, expectedPlanDigest: plan.digest),
                owner: owner
            )
            guard case let .record(started, _) = response else { return XCTFail("Expected resumed record") }
            XCTAssertEqual(started.phase, .running)
            await reopened.waitForExecutionForTesting(experimentID: id)
            XCTAssertEqual(reopened.record(id: id)?.phase, .completed)
            XCTAssertEqual(reopenedRuntime.submitted.count, 1)
        }

        func testOwningSessionCancelsRunningRequestAndWaitReturnsSettlement() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdResults = true
            let id = try await preparedOptimizationExperiment(harness)
            let sealed = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(sealed.currentPlan)
            let owner = PromptExperimentAgentOwner(
                controllerSessionID: sealed.controllerSessionID,
                sourceTabID: sealed.sourceTabID
            )
            let interface = PromptExperimentAgentInterface(service: harness.service)
            let runRequest = Task {
                try await interface.execute(.run(experimentID: id, expectedPlanDigest: plan.digest), owner: owner)
            }
            await harness.service.waitForPendingRunApprovalForTesting(experimentID: id)
            try await harness.service.approveAndRun(experimentID: id, displayedDigest: plan.digest)
            _ = try await runRequest.value
            await harness.runtime.waitUntilWaitingForResult()

            guard case let .record(cancelling, _) = try await interface.execute(
                .cancel(experimentID: id, expectedPlanDigest: plan.digest),
                owner: owner
            ) else { return XCTFail("Expected cancelling record") }
            XCTAssertEqual(cancelling.phase, .cancelling)
            XCTAssertEqual(harness.runtime.cancelled.count, 1)

            let waitRequest = Task {
                try await interface.execute(
                    .wait(experimentID: id, expectedPlanDigest: plan.digest, timeoutSeconds: 30),
                    owner: owner
                )
            }
            harness.runtime.settleFirst(disposition: .cancelled)
            guard case let .record(cancelled, _) = try await waitRequest.value else {
                return XCTFail("Expected cancelled record")
            }
            XCTAssertEqual(cancelled.phase, .cancelled)
        }

        func testAgentCanProposeRunAgainAsReviewedDraft() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedOptimizationExperiment(harness)
            let record = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(record.currentPlan)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let owner = PromptExperimentAgentOwner(
                controllerSessionID: record.controllerSessionID,
                sourceTabID: record.sourceTabID
            )
            let response = try await PromptExperimentAgentInterface(service: harness.service).execute(
                .proposeRunAgain(experimentID: id, expectedPlanDigest: plan.digest),
                owner: owner
            )
            guard case let .record(next, _) = response else { return XCTFail("Expected next-revision record") }
            XCTAssertEqual(next.phase, .drafting)
            XCTAssertEqual(next.draft?.parentPlanID, plan.id)
            XCTAssertEqual(next.draft?.optimization?.seedCandidate, plan.optimization?.seedCandidate)
            XCTAssertTrue(next.attempts(for: plan).count == 1)
            XCTAssertNil(PromptExperimentAgentOperation(rawValue: "start"))
        }

        func testCanonicalCommitSurvivesReadableProjectionFailure() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await preparedExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            let directory = try await harness.store.recordDirectoryURL(experimentID: id)
            try FileManager.default.removeItem(at: directory)
            XCTAssertTrue(FileManager.default.createFile(atPath: directory.path, contents: Data("blocked".utf8)))

            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            XCTAssertEqual(harness.service.record(id: id)?.phase, .approved)
            XCTAssertNotNil(harness.service.projectionError)

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await reopened.load()
            XCTAssertNil(reopened.loadError)
            XCTAssertEqual(reopened.record(id: id)?.phase, .approved)
            XCTAssertNotNil(reopened.projectionError)
        }

        func testCreateWaitsForInitialLoadAndPreservesOldAndNewRecords() async throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let seed = PromptExperimentService(
                store: PromptExperimentStore(rootURL: root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await seed.load()
            let oldID = try await seed.createExperiment(controllerSessionID: UUID(), sourceTabID: UUID())

            let gate = AsyncGate()
            let service = PromptExperimentService(
                store: PromptExperimentStore(rootURL: root, beforeLoad: { await gate.wait() }),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            let newSessionID = UUID()
            let create = Task {
                try await service.createExperiment(controllerSessionID: newSessionID, sourceTabID: UUID())
            }
            await gate.waitUntilEntered()
            XCTAssertTrue(service.records.isEmpty)
            await gate.open()
            let newID = try await create.value

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await reopened.load()
            XCTAssertNotNil(reopened.record(id: oldID))
            XCTAssertNotNil(reopened.record(id: newID))
            XCTAssertEqual(reopened.records.count, 2)
        }

        func testNextRevisionReResolvesExperimentAfterFixtureReadSuspension() async throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = AsyncGate()
            let runtime = FakeRuntime()
            let store = PromptExperimentStore(
                rootURL: root,
                beforeReadSyntheticFixture: { await gate.wait() }
            )
            let service = PromptExperimentService(
                store: store,
                runtime: runtime,
                resolveTarget: Self.fakeTarget,
                now: { Date(timeIntervalSince1970: 1000) }
            )
            let harness = Harness(root: root, store: store, runtime: runtime, service: service)
            let originalID = try await approvedExperiment(harness)
            try await service.run(experimentID: originalID)
            await service.waitForExecutionForTesting(experimentID: originalID)
            let digest = try XCTUnwrap(service.record(id: originalID)?.currentPlan?.digest)

            let nextRevision = Task {
                try await service.startNextRevision(experimentID: originalID, expectedPlanDigest: digest)
            }
            await gate.waitUntilEntered()
            let insertedID = try await service.createExperiment(controllerSessionID: UUID(), sourceTabID: UUID())
            await gate.open()
            try await nextRevision.value

            XCTAssertEqual(service.record(id: originalID)?.draft?.revision, 2)
            XCTAssertEqual(service.record(id: insertedID)?.draft?.revision, 1)
            XCTAssertEqual(service.record(id: insertedID)?.phase, .drafting)
        }

        func testPriorRevisionEvidenceSurvivesNextRevisionRunAndReopen() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await approvedExperiment(harness)
            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)
            let firstPlan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            let firstAttempts = try XCTUnwrap(harness.service.record(id: id)?.attempts(for: firstPlan))
            XCTAssertEqual(firstAttempts.count, 2)
            XCTAssertTrue(firstAttempts.allSatisfy { $0.committedHandoff != nil })

            try await harness.service.startNextRevision(experimentID: id, expectedPlanDigest: firstPlan.digest)
            var secondDraft = try XCTUnwrap(harness.service.record(id: id)?.draft)
            let secondBaseDigest = try secondDraft.contentDigest()
            secondDraft.candidateInstructions += " Include the fixture filename."
            let updated = try await harness.service.updateDraft(
                experimentID: id,
                expectedDraftID: secondDraft.id,
                expectedDraftVersion: secondDraft.optimisticVersion,
                expectedDraftDigest: secondBaseDigest,
                draft: secondDraft
            )
            let secondPlan = try await harness.service.seal(
                experimentID: id,
                expectedDraftID: updated.id,
                expectedDraftVersion: updated.optimisticVersion,
                expectedDraftDigest: updated.contentDigest()
            )
            try await harness.service.approve(experimentID: id, displayedDigest: secondPlan.digest)
            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await reopened.load()
            let record = try XCTUnwrap(reopened.record(id: id))
            XCTAssertEqual(record.plans.map(\.revision), [1, 2])
            XCTAssertEqual(record.attempts(for: firstPlan).count, 2)
            XCTAssertEqual(record.attempts(for: secondPlan).count, 2)
            XCTAssertTrue(record.attempts(for: firstPlan).allSatisfy { $0.committedHandoff != nil })
            XCTAssertTrue(record.attempts(for: secondPlan).allSatisfy { $0.committedHandoff != nil })
        }

        func testLoadMigratesUnambiguousLegacyAttemptLineage() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await approvedExperiment(harness)
            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            var legacyRecords = harness.service.records
            let recordIndex = try XCTUnwrap(legacyRecords.firstIndex { $0.id == id })
            for attemptIndex in legacyRecords[recordIndex].attempts.indices {
                legacyRecords[recordIndex].attempts[attemptIndex].planID = nil
                legacyRecords[recordIndex].attempts[attemptIndex].planRevision = nil
                legacyRecords[recordIndex].attempts[attemptIndex].planDigest = nil
            }
            _ = try await harness.store.saveRecords(legacyRecords)

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await reopened.load()
            let record = try XCTUnwrap(reopened.record(id: id))
            let plan = try XCTUnwrap(record.currentPlan)
            XCTAssertEqual(record.attempts(for: plan).count, plan.trials.count)
            XCTAssertTrue(record.attempts.allSatisfy {
                $0.planID == plan.id && $0.planRevision == plan.revision && $0.planDigest == plan.digest
            })

            let persisted = try await harness.store.loadRecords()
            XCTAssertEqual(persisted.first(where: { $0.id == id })?.attempts(for: plan).count, plan.trials.count)
        }

        func testCommittedHandoffUsesOverridePromptAndFinalSelectionAcrossReopen() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await approvedExperiment(harness)
            let record = try XCTUnwrap(harness.service.record(id: id))
            let plan = try XCTUnwrap(record.currentPlan)
            let trial = try XCTUnwrap(plan.trials.first)
            let finalSelection = StoredSelection(
                selectedPaths: ["fixture.md", "notes.md"],
                manualCodemapPaths: ["fixture.md"],
                slices: ["fixture.md": [LineRange(start: 2, end: 4, description: "answer evidence")]],
                codemapAutoEnabled: false
            )
            let tabID = UUID()
            let committedTab = MCPServerViewModel.ContextBuilderCommittedTabSnapshot(
                identity: WorkspaceSelectionIdentity(workspaceID: UUID(), tabID: tabID),
                nestedRunID: UUID(),
                tab: ComposeTabState(
                    id: tabID,
                    name: "Committed",
                    selection: finalSelection,
                    promptText: "stale prompt area",
                    contextOverrides: ContextBuilderOverrides(
                        useOverridePrompt: true,
                        overridePromptText: "Actual immutable handoff"
                    )
                ),
                selectionRevision: 42,
                usedAgentOutputAsPrompt: false
            )
            let completion = ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion(
                runID: UUID(),
                tabID: tabID,
                identity: committedTab.identity,
                agentKind: .codexExec,
                modelRaw: "catalog-model-high",
                terminalDisposition: .completed,
                agentOutput: "Done",
                usedAgentOutputAsPrompt: false,
                committedTab: committedTab
            )
            let runtimeResult = NativePromptExperimentContextBuilderRuntime.runtimeResult(
                completion: completion,
                fallbackProvider: "fallback",
                fallbackModel: "fallback-model",
                fixtureDigestBefore: plan.environment.fixtureDigest,
                fixtureDigestAfter: plan.environment.fixtureDigest
            )
            XCTAssertEqual(runtimeResult.committedHandoff?.prompt, "Actual immutable handoff")
            XCTAssertEqual(runtimeResult.committedHandoff?.selection, finalSelection)
            XCTAssertEqual(runtimeResult.assistantOutput, "Done")
            harness.runtime.immediateResults[trial.ordinal] = runtimeResult

            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await reopened.load()
            let reopenedRecord = try XCTUnwrap(reopened.record(id: id))
            let attempt = try XCTUnwrap(reopenedRecord.attempts.first)
            let handoff = try XCTUnwrap(attempt.committedHandoff)
            XCTAssertEqual(handoff.selection, finalSelection)
            XCTAssertEqual(handoff.selectionRevision, 42)
            XCTAssertEqual(attempt.assistantOutputPreview, "Done")
            XCTAssertNotEqual(handoff.promptPreview, attempt.assistantOutputPreview)
            let promptArtifactData = try await harness.store.readArtifact(handoff.promptEvidence)
            let assistantArtifact = try XCTUnwrap(attempt.assistantOutputEvidence)
            let assistantArtifactData = try await harness.store.readArtifact(assistantArtifact)
            XCTAssertEqual(String(data: promptArtifactData, encoding: .utf8), "Actual immutable handoff")
            XCTAssertEqual(String(data: assistantArtifactData, encoding: .utf8), "Done")

            let owner = PromptExperimentAgentOwner(
                controllerSessionID: reopenedRecord.controllerSessionID,
                sourceTabID: reopenedRecord.sourceTabID
            )
            let response = try await PromptExperimentAgentInterface(service: reopened).execute(.read(experimentID: id), owner: owner)
            guard case let .record(_, artifactTextBySHA256) = response else { return XCTFail("Expected record response") }
            XCTAssertEqual(artifactTextBySHA256[handoff.promptEvidence.sha256], "Actual immutable handoff")
            XCTAssertEqual(artifactTextBySHA256[attempt.assistantOutputEvidence?.sha256 ?? ""], "Done")

            let directory = try await reopened.recordDirectoryURL(experimentID: id)
            let overview = try String(contentsOf: directory.appendingPathComponent("overview.md"), encoding: .utf8)
            XCTAssertTrue(overview.contains("Actual immutable handoff"))
            XCTAssertTrue(overview.contains("fixture.md: 2-4 (answer evidence)"))
            XCTAssertTrue(overview.contains("Assistant output preview: Done"))
        }

        func testCompletedRuntimeWithoutCommittedHandoffIsInconclusive() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let id = try await approvedExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            harness.runtime.immediateResults[1] = FakeRuntime.result(
                handle: PromptExperimentRuntimeHandle(id: UUID(), tabID: nil, runID: nil),
                disposition: .completed,
                output: nil,
                fixtureDigest: plan.environment.fixtureDigest,
                assistantOutput: "Done"
            )

            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record.phase, .inconclusive)
            XCTAssertEqual(record.attempts.first?.status, .failed)
            XCTAssertEqual(record.attempts.first?.handoffUnavailableReason, "controlled missing handoff")
            XCTAssertEqual(record.attempts.first?.assistantOutputPreview, "Done")
        }

        func testExplicitCatalogTargetsSealExactModelsWithoutChangingRoleDefaults() async throws {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let targets = [
                PromptExperimentResolvedTarget(
                    role: "codexExec:gpt-6-astra-high",
                    agentRaw: AgentProviderKind.codexExec.rawValue,
                    modelRaw: "gpt-6-astra-high",
                    displayName: "Codex GPT-6 Astra High"
                ),
                PromptExperimentResolvedTarget(
                    role: "codexExec:gpt-6-astra-xhigh",
                    agentRaw: AgentProviderKind.codexExec.rawValue,
                    modelRaw: "gpt-6-astra-xhigh",
                    displayName: "Codex GPT-6 Astra XHigh"
                )
            ]
            let availability = AgentModelCatalog.AvailabilityContext(codexAvailable: true)
            let beforeOverrides = GlobalSettingsStore.shared.globalAgentModelsProfile().mcpAgentRoleOverrides
            let runtime = FakeRuntime()
            let store = PromptExperimentStore(rootURL: root)
            let service = PromptExperimentService(
                store: store,
                runtime: runtime,
                resolveTarget: { selector in
                    try PromptExperimentTargetCatalog.resolve(
                        selector,
                        availability: availability,
                        exactTargets: targets
                    )
                },
                availableTargets: { targets },
                now: { Date(timeIntervalSince1970: 1000) }
            )
            let harness = Harness(root: root, store: store, runtime: runtime, service: service)

            for target in targets {
                let id = try await preparedExperiment(harness, targetSelector: target.selector)
                let plan = try XCTUnwrap(service.record(id: id)?.currentPlan)
                XCTAssertEqual(plan.resolvedTarget, target)
                XCTAssertEqual(plan.resolvedTarget.canonicalSelectionID, target.selector)
            }
            XCTAssertEqual(GlobalSettingsStore.shared.globalAgentModelsProfile().mcpAgentRoleOverrides, beforeOverrides)
            XCTAssertTrue(runtime.submitted.isEmpty)

            await service.load()
            let invalidID = try await service.createExperiment(controllerSessionID: UUID(), sourceTabID: UUID())
            var invalidDraft = try XCTUnwrap(service.record(id: invalidID)?.draft)
            let invalidBaseDigest = try invalidDraft.contentDigest()
            invalidDraft.title = "Invalid target"
            invalidDraft.taskInput = "Task"
            invalidDraft.syntheticFixture = "Fixture"
            invalidDraft.originalInstructions = "Original"
            invalidDraft.candidateInstructions = "Candidate"
            invalidDraft.targetRole = "codexExec:not-in-capabilities"
            let updated = try await service.updateDraft(
                experimentID: invalidID,
                expectedDraftID: invalidDraft.id,
                expectedDraftVersion: invalidDraft.optimisticVersion,
                expectedDraftDigest: invalidBaseDigest,
                draft: invalidDraft
            )
            do {
                _ = try await service.seal(
                    experimentID: invalidID,
                    expectedDraftID: updated.id,
                    expectedDraftVersion: updated.optimisticVersion,
                    expectedDraftDigest: updated.contentDigest()
                )
                XCTFail("Unknown catalog selector must fail before approval or run")
            } catch let error as PromptExperimentAuthorityError {
                guard case .targetUnavailable = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertTrue(runtime.submitted.isEmpty)
            XCTAssertEqual(GlobalSettingsStore.shared.globalAgentModelsProfile().mcpAgentRoleOverrides, beforeOverrides)
        }

        func testOptimizationPreflightRunsOnlyAfterNativeApprovalAndFailureDoesNotSubmit() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let (id, draft) = try await updatedOptimizationDraft(harness)
            harness.runtime.preflightError = .runtimeUnavailable("controlled pinned GEPA mismatch")

            let plan = try await harness.service.seal(
                experimentID: id,
                expectedDraftID: draft.id,
                expectedDraftVersion: draft.optimisticVersion,
                expectedDraftDigest: draft.contentDigest()
            )
            XCTAssertTrue(harness.runtime.preflightedPlans.isEmpty)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)

            do {
                try await harness.service.run(experimentID: id)
                XCTFail("Failed GEPA preflight must reject runtime admission")
            } catch let error as PromptExperimentAuthorityError {
                XCTAssertEqual(error, .runtimeUnavailable("controlled pinned GEPA mismatch"))
            }

            let record = try XCTUnwrap(harness.service.record(id: id))
            XCTAssertEqual(record.phase, .approved)
            XCTAssertEqual(record.currentPlan?.id, plan.id)
            XCTAssertEqual(harness.runtime.preflightedPlans.map(\.id), [plan.id])
            XCTAssertTrue(harness.runtime.submitted.isEmpty)
            XCTAssertTrue(record.attempts(for: plan).isEmpty)
        }

        func testOptimizationResultPersistsCandidatesEvaluationsAndExactTargets() async throws {
            try await assertOptimizationResultContinuation(preparation: false)
            try await assertOptimizationResultContinuation(preparation: true)
        }

        private func assertOptimizationResultContinuation(preparation: Bool) async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let (id, draft) = try await updatedOptimizationDraft(harness)
            var reviewedDraft = draft
            if preparation {
                reviewedDraft.optimization?.stage = .preparation
                reviewedDraft.optimization?.preparationCandidates = ["baseline instructions", "improved instructions"]
                reviewedDraft.optimization?.examples[0].split = .training
                reviewedDraft = try await harness.service.updateDraft(
                    experimentID: id,
                    expectedDraftID: draft.id,
                    expectedDraftVersion: draft.optimisticVersion,
                    expectedDraftDigest: draft.contentDigest(),
                    draft: reviewedDraft
                )
            }
            _ = try await harness.service.seal(
                experimentID: id,
                expectedDraftID: reviewedDraft.id,
                expectedDraftVersion: reviewedDraft.optimisticVersion,
                expectedDraftDigest: reviewedDraft.contentDigest()
            )
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            XCTAssertEqual(plan.schemaVersion, PromptExperimentPlan.optimizationSchemaVersion)
            XCTAssertEqual(plan.optimizationTargets?.reflection.role, "reflector")
            XCTAssertEqual(plan.optimizationTargets?.execution?.role, "executor")
            XCTAssertEqual(plan.trials.map(\.condition), [.optimization])

            var runtimeResult = FakeRuntime.result(
                handle: PromptExperimentRuntimeHandle(id: plan.trials[0].id, tabID: nil, runID: nil),
                disposition: .completed,
                output: nil,
                fixtureDigest: plan.environment.fixtureDigest,
                assistantOutput: nil
            )
            runtimeResult.optimizationResult = PromptExperimentOptimizationRuntimeResult(
                engine: preparation ? "preparation" : "gepa",
                upstreamRevision: PromptExperimentGEPAConfiguration.pinnedRevision,
                baselineScore: 0,
                bestScore: 1,
                bestCandidateIndex: 1,
                candidates: ["baseline instructions", "improved instructions"],
                parentIndices: [[], [0]],
                aggregateScores: [0, 1],
                candidatePromptSurfaces: [
                    PromptExperimentPromptSurfaceMetrics(
                        schemaVersion: 1,
                        adapter: "upstream_gepa_mcp_adapter_two_pass",
                        component: "system_prompt",
                        candidateUTF8Bytes: 21,
                        candidateCharacters: 21,
                        candidateWords: 2,
                        candidateLines: 1,
                        fixedScaffoldUTF8Bytes: 5000,
                        renderedSystemUTF8Bytes: 5021,
                        mutableInsertionCount: 1,
                        fixedScaffoldSHA256: String(repeating: "a", count: 64),
                        renderedSystemSHA256: String(repeating: "b", count: 64),
                        candidateFixedScaffoldFourgramOverlap: 0
                    ),
                    PromptExperimentPromptSurfaceMetrics(
                        schemaVersion: 1,
                        adapter: "upstream_gepa_mcp_adapter_two_pass",
                        component: "system_prompt",
                        candidateUTF8Bytes: 21,
                        candidateCharacters: 21,
                        candidateWords: 2,
                        candidateLines: 1,
                        fixedScaffoldUTF8Bytes: 5000,
                        renderedSystemUTF8Bytes: 5021,
                        mutableInsertionCount: 1,
                        fixedScaffoldSHA256: String(repeating: "a", count: 64),
                        renderedSystemSHA256: String(repeating: "c", count: 64),
                        candidateFixedScaffoldFourgramOverlap: 0
                    )
                ],
                paretoFrontierIndices: [0, 1],
                evaluations: [
                    PromptExperimentOptimizationRuntimeEvaluation(
                        candidateIndex: 1,
                        exampleID: "reviewed-1",
                        split: preparation ? .training : .validation,
                        score: 1,
                        feedback: "matched reviewed answer",
                        failureKind: nil,
                        output: "cobalt",
                        elapsedSeconds: 0.25
                    )
                ],
                totalEvaluations: 2,
                wallTimeSeconds: 1.5,
                proposerUsage: "unavailable_from_connected_model_completion_contract",
                runDirectoryRelativePath: "worker-runs/attempt/gepa-run",
                rawResultJSON: Data("{\"engine\":\"gepa\"}".utf8)
            )
            harness.runtime.immediateResults[1] = runtimeResult
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await reopened.load()
            let record = try XCTUnwrap(reopened.record(id: id))
            let result = try XCTUnwrap(record.attempts(for: plan).first?.optimizationResult)
            XCTAssertEqual(result.engine, preparation ? "preparation" : "gepa")
            XCTAssertTrue(result.assessment.contains(preparation ? "not held-out results" : "retained candidates"))
            XCTAssertEqual(result.bestCandidateIndex, 1)
            XCTAssertEqual(result.paretoFrontierIndices, [0, 1])
            XCTAssertEqual(result.candidates.map(\.candidatePreview), ["baseline instructions", "improved instructions"])
            XCTAssertEqual(result.candidates.map(\.isParetoEfficient), [true, true])
            XCTAssertEqual(result.candidates.first?.promptSurface?.renderedSystemUTF8Bytes, 5021)
            XCTAssertEqual(result.evaluations.first?.feedback, "matched reviewed answer")
            XCTAssertEqual(result.runDirectoryRelativePath, "worker-runs/attempt/gepa-run")
            XCTAssertEqual(result.proposerUsage, "unavailable_from_connected_model_completion_contract")
            XCTAssertNotNil(result.rawResultEvidence)
            let artifactText = try await reopened.readableArtifactText(for: record)
            for candidate in result.candidates {
                XCTAssertNotNil(artifactText[candidate.candidateEvidence.sha256])
            }
            let directory = try await reopened.recordDirectoryURL(experimentID: id)
            let overview = try String(contentsOf: directory.appendingPathComponent("overview.md"), encoding: .utf8)
            XCTAssertTrue(overview.contains("GEPA wall time: 1.500 seconds"))
            XCTAssertTrue(overview.contains("Quality/rendered-size Pareto frontier: 0, 1"))
            XCTAssertTrue(overview.contains("candidate 21 bytes + fixed scaffold 5000 bytes"))
            XCTAssertTrue(overview.contains("worker-runs/attempt/gepa-run"))
            XCTAssertTrue(overview.contains("matched reviewed answer"))
            XCTAssertTrue(overview.contains("Sealed optimization authority"))

            let cloneID = try await reopened.cloneExperiment(experimentID: id)
            let clone = try XCTUnwrap(reopened.record(id: cloneID))
            XCTAssertEqual(clone.phase, .drafting)
            XCTAssertEqual(clone.draft?.optimization, plan.optimization)
            XCTAssertTrue(clone.plans.isEmpty)
            XCTAssertTrue(clone.attempts.isEmpty)

            try await reopened.startNextRevision(experimentID: id, expectedPlanDigest: plan.digest)
            let next = try XCTUnwrap(reopened.record(id: id))
            XCTAssertEqual(PromptExperimentGuidance.evaluate(record)?.action, "review_measurement")
            var recoveredRecord = record
            recoveredRecord.attempts[0].modelCalls = [.init(
                id: UUID(), target: plan.resolvedTarget, role: "judge", state: .failed,
                promptTokens: nil, completionTokens: nil
            )]
            XCTAssertEqual(
                PromptExperimentGuidance.evaluate(recoveredRecord)?.action,
                "review_measurement",
                "A recovered judge failure must not override the final result"
            )
            recoveredRecord.phase = .running
            recoveredRecord.attempts[0].optimizationResult = nil
            XCTAssertEqual(PromptExperimentGuidance.evaluate(recoveredRecord)?.action, "monitor")
            var partialRecord = record
            let partialID = UUID()
            partialRecord.attempts[0].partialEvaluations = [.init(
                id: partialID, candidateEvidence: result.candidates[0].candidateEvidence,
                evaluation: .init(id: partialID, candidateIndex: 0, exampleID: "stale", split: .training, score: 0, feedback: "stale", failureKind: .candidate, outputEvidence: nil, elapsedSeconds: nil)
            )]
            XCTAssertEqual(PromptExperimentGuidance.evaluate(partialRecord)?.action, "review_measurement", "Final evidence takes precedence over checkpoints")
            XCTAssertFalse(PromptExperimentGuidance.evaluate(partialRecord)?.evidenceIDs.contains(partialID.uuidString) ?? true)
            XCTAssertEqual(next.draft?.optimization?.seedCandidate, "improved instructions")
            XCTAssertEqual(next.draft?.optimization?.stage, preparation ? .preparation : .search)
            XCTAssertEqual(next.draft?.optimization?.startingPoint, .supplied)
            XCTAssertEqual(next.draft?.optimization?.preparationCandidates, preparation ? ["improved instructions"] : nil)
            XCTAssertEqual(next.plans.first?.optimization?.isPreparation, preparation)
            XCTAssertEqual(next.attempts(for: plan).first?.optimizationResult?.bestScore, 1)
            XCTAssertTrue(harness.runtime.submitted.count == 1)
        }

        func testOversizedOptimizationUpdatePreservesMemoryAndCanonicalStore() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let (id, current) = try await updatedOptimizationDraft(harness)
            let canonicalURL = harness.root.appendingPathComponent("experiments.json")
            let canonicalBefore = try Data(contentsOf: canonicalURL)
            var oversized = current
            let largeInput = String(repeating: "x", count: PromptExperimentDraft.maximumExampleCharacters)
            for index in 0 ..< 50 {
                oversized.optimization?.examples.append(PromptExperimentExample(
                    id: "large-\(index)",
                    split: .training,
                    input: largeInput,
                    expectedOutput: "ok",
                    reviewerNotes: nil
                ))
            }

            do {
                _ = try await harness.service.updateDraft(
                    experimentID: id,
                    expectedDraftID: current.id,
                    expectedDraftVersion: current.optimisticVersion,
                    expectedDraftDigest: current.contentDigest(),
                    draft: oversized
                )
                XCTFail("An aggregate specification over the encoded limit must be rejected")
            } catch let error as PromptExperimentAuthorityError {
                guard case .invalidDraft = error else { return XCTFail("Unexpected error: \(error)") }
            }

            XCTAssertEqual(harness.service.record(id: id)?.draft, current)
            XCTAssertEqual(try Data(contentsOf: canonicalURL), canonicalBefore)
        }

        func testReviewedProjectSnapshotIsImmutableAndExcludesPrivateGradingData() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            let sourceRoot = harness.root.appendingPathComponent("authorized-source", isDirectory: true)
            let sourceFile = sourceRoot.appendingPathComponent("Package.swift")
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            try Data("reviewed source v1".utf8).write(to: sourceFile)

            let environment = try await harness.store.materializeOptimizationEnvironment(
                experimentID: UUID(),
                planRevision: 1,
                project: PromptExperimentProjectSnapshotSpecification(
                    sourceRootPath: sourceRoot.path,
                    includedPaths: ["Package.swift"]
                ),
                authorizedSourceRoots: [sourceRoot.path]
            )
            XCTAssertEqual(environment.files.count, 2)
            let snapshot = environment.rootURL.appendingPathComponent("project/Package.swift")
            XCTAssertEqual(try String(contentsOf: snapshot, encoding: .utf8), "reviewed source v1")
            try Data("source changed after sealing".utf8).write(to: sourceFile)
            XCTAssertEqual(try String(contentsOf: snapshot, encoding: .utf8), "reviewed source v1")

            let visibleData = try environment.files
                .map { try Data(contentsOf: URL(fileURLWithPath: $0.path)) }
                .reduce(into: Data()) { $0.append($1) }
            let visibleText = String(decoding: visibleData, as: UTF8.self)
            XCTAssertFalse(visibleText.contains("HOST_PRIVATE_EXPECTED_CANARY"))
            XCTAssertFalse(visibleText.contains("HOST_PRIVATE_REVIEWER_NOTES_CANARY"))
            XCTAssertEqual(
                environment.digest,
                PromptExperimentDigest.environmentInventorySHA256(
                    rootPath: environment.rootURL.path,
                    files: environment.files
                )
            )
        }

        func testOptimizationDigestBindsEvaluatorDataBudgetAndResolvedTargets() throws {
            let date = Date(timeIntervalSince1970: 123)
            let environment = try PromptExperimentEnvironment(
                workspaceID: XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                sourceTabID: XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
                capturedAt: date,
                isolatedRootPath: "/tmp/gepa-digest",
                selection: StoredSelection(selectedPaths: ["reviewed-examples.json"]),
                fixtureFiles: [PromptExperimentFixtureFile(path: "reviewed-examples.json", byteCount: 10, sha256: "fixture")],
                fixtureDigest: "fixture",
                captureLimitations: ["isolated"]
            )
            let reflection = try XCTUnwrap(Self.fakeTarget("reflector"))
            let execution = try XCTUnwrap(Self.fakeTarget("executor"))
            let targets = PromptExperimentOptimizationTargets(reflection: reflection, execution: execution, judge: nil)

            func digest(_ specification: PromptExperimentOptimizationSpecification, targets selectedTargets: PromptExperimentOptimizationTargets = targets) throws -> String {
                let draft = PromptExperimentDraft(
                    revision: 1,
                    title: "Digest coverage",
                    optimization: specification,
                    createdAt: date,
                    updatedAt: date
                )
                return try PromptExperimentPlan.seal(
                    draft: draft,
                    target: execution,
                    optimizationTargets: selectedTargets,
                    environment: environment,
                    at: date
                ).digest
            }

            let original = Self.validOptimization()
            let originalDigest = try digest(original)
            var changedExample = original
            changedExample.examples[0].expectedOutput = "azure"
            var changedEvaluator = original
            changedEvaluator.evaluator.minimumScore = -1
            var changedBudget = original
            changedBudget.gepa.maxEvaluations += 1
            var changedGEPAOptions = original
            changedGEPAOptions.gepa.reflectionMinibatchSize = 7
            changedGEPAOptions.gepa.useMerge = true
            changedGEPAOptions.gepa.maxMergeInvocations = 4
            changedGEPAOptions.gepa.skipPerfectScore = false
            var changedProject = original
            changedProject.projectSnapshot = PromptExperimentProjectSnapshotSpecification(
                sourceRootPath: "/tmp/reviewed",
                includedPaths: ["Package.swift"]
            )
            let changedTargets = try PromptExperimentOptimizationTargets(
                reflection: XCTUnwrap(Self.fakeTarget("different-reflector")),
                execution: execution,
                judge: nil
            )

            XCTAssertNotEqual(try digest(changedExample), originalDigest)
            XCTAssertNotEqual(try digest(changedEvaluator), originalDigest)
            XCTAssertNotEqual(try digest(changedBudget), originalDigest)
            XCTAssertNotEqual(try digest(changedGEPAOptions), originalDigest)
            XCTAssertNotEqual(try digest(changedProject), originalDigest)
            XCTAssertNotEqual(try digest(original, targets: changedTargets), originalDigest)
        }

        func testSealedPlanDisclosureIncludesCompleteApprovalAuthority() throws {
            let date = Date(timeIntervalSince1970: 456)
            let environment = try PromptExperimentEnvironment(
                workspaceID: XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                sourceTabID: XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
                capturedAt: date,
                isolatedRootPath: "/tmp/gepa-disclosure",
                selection: StoredSelection(selectedPaths: ["project/Package.swift"]),
                fixtureFiles: [PromptExperimentFixtureFile(
                    path: "project/Package.swift",
                    byteCount: 42,
                    sha256: "manifest-sha-256-canary"
                )],
                fixtureDigest: "aggregate-manifest-digest-canary",
                captureLimitations: ["reviewed snapshot"]
            )
            var specification = Self.validOptimization()
            specification.examples[0].expectedOutput = "expected-output-canary"
            specification.examples[0].reviewerNotes = "reviewer-notes-canary"
            specification.evaluator.candidateFileName = "candidate-instructions.md"
            specification.gepa.stopAtScore = 0.875
            specification.projectSnapshot = PromptExperimentProjectSnapshotSpecification(
                sourceRootPath: "/tmp/authorized-project",
                includedPaths: ["Package.swift"]
            )
            let reflection = try XCTUnwrap(Self.fakeTarget("reflector"))
            let execution = try XCTUnwrap(Self.fakeTarget("executor"))
            let plan = try PromptExperimentPlan.seal(
                draft: PromptExperimentDraft(
                    revision: 1,
                    title: "Disclosure coverage",
                    optimization: specification,
                    createdAt: date,
                    updatedAt: date
                ),
                target: execution,
                optimizationTargets: PromptExperimentOptimizationTargets(
                    reflection: reflection,
                    execution: execution,
                    judge: nil
                ),
                environment: environment,
                at: date
            )

            let rendered = try PromptExperimentSealedPlanPresentation.prettyPrintedJSON(plan)

            for expected in [
                "expectedOutput", "expected-output-canary",
                "reviewerNotes", "reviewer-notes-canary",
                "candidateFileName", "candidate-instructions.md",
                "stopAtScore", "0.875",
                "manifest-sha-256-canary", "aggregate-manifest-digest-canary"
            ] {
                XCTAssertTrue(rendered.contains(expected), "Missing sealed authority field/value: \(expected)")
            }
        }

        func testNewOptimizationPlanHasNoExperimentWallClockDeadline() throws {
            let date = Date(timeIntervalSince1970: 777)
            let environment = try PromptExperimentEnvironment(
                workspaceID: XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                sourceTabID: XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
                capturedAt: date,
                isolatedRootPath: "/tmp/gepa-schema-4",
                selection: StoredSelection(selectedPaths: ["reviewed-examples.json"]),
                fixtureFiles: [],
                fixtureDigest: "fixture",
                captureLimitations: []
            )
            let reflection = try XCTUnwrap(Self.fakeTarget("reflector"))
            let execution = try XCTUnwrap(Self.fakeTarget("executor"))
            let plan = try PromptExperimentPlan.seal(
                draft: PromptExperimentDraft(
                    revision: 1,
                    title: "No wall deadline",
                    optimization: Self.validOptimization(),
                    createdAt: date,
                    updatedAt: date
                ),
                target: execution,
                optimizationTargets: PromptExperimentOptimizationTargets(
                    reflection: reflection,
                    execution: execution,
                    judge: nil
                ),
                environment: environment,
                at: date
            )

            XCTAssertEqual(plan.schemaVersion, PromptExperimentPlan.optimizationSchemaVersion)
            XCTAssertNil(plan.optimization?.gepa.maxWallClockSeconds)
            XCTAssertTrue(plan.verifiesIntegrity())
            let encoded = try JSONEncoder().encode(plan)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("maxWallClockSeconds"))
            XCTAssertTrue(plan.limitations.contains { $0.contains("no experiment-wide wall-clock deadline") })
        }

        func testHistoricPlansPreserveDigestAndDeadlineOnRoundTrip() async throws {
            try await assertHistoricPlanRoundTrip(schema: 3, deadline: 180)
            try await assertHistoricPlanRoundTrip(schema: 4, deadline: nil)
        }

        private func assertHistoricPlanRoundTrip(schema: Int, deadline: Int?) async throws {
            let date = Date(timeIntervalSince1970: 778)
            let environment = try PromptExperimentEnvironment(
                workspaceID: XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                sourceTabID: XCTUnwrap(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
                capturedAt: date,
                isolatedRootPath: "/tmp/gepa-schema-3",
                selection: StoredSelection(selectedPaths: []),
                fixtureFiles: [],
                fixtureDigest: "fixture",
                captureLimitations: []
            )
            var optimization = Self.validOptimization()
            optimization.gepa.maxWallClockSeconds = deadline
            let reflection = try XCTUnwrap(Self.fakeTarget("reflector"))
            let execution = try XCTUnwrap(Self.fakeTarget("executor"))
            let targets = PromptExperimentOptimizationTargets(
                reflection: reflection,
                execution: execution,
                judge: nil
            )
            let payload = PromptExperimentPlan.OptimizationDigestPayload(
                schemaVersion: schema,
                revision: 1,
                parentPlanID: nil,
                title: "Historic sealed plan",
                optimization: optimization,
                resolvedTargets: targets,
                environment: environment,
                executionAdapter: PromptExperimentPlan.gepaExecutionAdapter,
                comparisonMode: PromptExperimentPlan.gepaComparisonMode
            )
            let digest = try PromptExperimentDigest.canonicalSHA256(payload)
            let plan = PromptExperimentPlan(
                schemaVersion: schema,
                id: PromptExperimentDigest.deterministicUUID(namespace: "plan", value: digest),
                revision: 1,
                parentPlanID: nil,
                title: "Historic sealed plan",
                taskInput: "",
                originalInstructions: "",
                candidateInstructions: "",
                resolvedTarget: execution,
                environment: environment,
                repetitions: 1,
                executionAdapter: PromptExperimentPlan.gepaExecutionAdapter,
                comparisonMode: PromptExperimentPlan.gepaComparisonMode,
                digest: digest,
                sealedAt: date,
                trials: [PromptExperimentTrial(
                    id: PromptExperimentDigest.deterministicUUID(namespace: "gepa-run", value: digest),
                    ordinal: 1,
                    condition: .optimization,
                    repetition: 1
                )],
                limitations: ["historic"],
                optimization: optimization,
                optimizationTargets: targets
            )

            let data = try JSONEncoder().encode(plan)
            let decoded = try JSONDecoder().decode(PromptExperimentPlan.self, from: data)
            XCTAssertEqual(decoded, plan)
            XCTAssertEqual(decoded.digest, digest)
            XCTAssertEqual(decoded.optimization?.gepa.maxWallClockSeconds, deadline)
            XCTAssertTrue(decoded.verifiesIntegrity())

            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let owner = UUID()
            let sourceID = UUID()
            let store = PromptExperimentStore(rootURL: root)
            _ = try await store.saveRecords([PromptExperimentRecord(
                id: sourceID,
                controllerSessionID: owner,
                sourceTabID: UUID(),
                createdAt: date,
                updatedAt: date,
                phase: .inconclusive,
                draft: nil,
                plans: [decoded],
                approvals: [],
                attempts: [],
                cancellationRequestedAt: nil,
                statusMessage: "Historic record"
            )])
            let service = PromptExperimentService(
                store: store,
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget
            )
            await service.load()
            let cloneID = try await service.cloneExperiment(
                experimentID: sourceID,
                expectedControllerSessionID: owner
            )
            XCTAssertEqual(service.record(id: sourceID)?.currentPlan?.digest, digest)
            XCTAssertEqual(service.record(id: sourceID)?.currentPlan?.optimization?.gepa.maxWallClockSeconds, deadline)
            XCTAssertNil(service.record(id: cloneID)?.draft?.optimization?.gepa.maxWallClockSeconds)

            try await service.startNextRevision(
                experimentID: sourceID,
                expectedPlanDigest: digest,
                expectedControllerSessionID: owner,
                revisionMode: .repeatCurrentSeed
            )
            XCTAssertNil(service.record(id: sourceID)?.draft?.optimization?.gepa.maxWallClockSeconds)
            XCTAssertEqual(service.record(id: sourceID)?.plans.first?.digest, digest)
        }

        func testWorkerDiagnosticsPersistBeforeEvaluationAndExposeSafeEvidence() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.observationsOnSubmit = [
                .workerPrepared(
                    stderrLogRelativePath: "worker-runs/attempt/worker-stderr.log",
                    stdoutProtocolLogRelativePath: "worker-runs/attempt/stdout-protocol.ndjson"
                ),
                .workerStarted(pid: 4242, processIdentity: "python3.11 pid 4242"),
                .protocolEvent(channel: "stdin", event: "run_request_written", detail: "payload=excluded"),
                .callbackStarted(id: "callback-1", operation: "reflect"),
                .callbackLinked(
                    id: "callback-1",
                    runtime: PromptExperimentRuntimeLink(
                        adapter: "connected_model_callback_v1",
                        tabID: nil,
                        runID: nil,
                        provider: "fake",
                        model: "fake-model"
                    )
                ),
                .callbackFinished(id: "callback-1", operation: "reflect"),
                .protocolEvent(
                    channel: "stdout",
                    event: "failed",
                    detail: "exception_type=NameError source_frame=gepa.worker.run:312 error_payload=excluded"
                ),
                .workerExited(
                    status: 1,
                    stderrLogByteCount: 91,
                    stderrLogTruncated: false,
                    protocolLogByteCount: 210,
                    protocolLogTruncated: false
                )
            ]
            let id = try await preparedOptimizationExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            try await harness.service.run(experimentID: id)
            await harness.service.waitForExecutionForTesting(experimentID: id)

            let attempt = try XCTUnwrap(harness.service.record(id: id)?.attempts.first)
            let diagnostics = try XCTUnwrap(attempt.diagnostics)
            XCTAssertEqual(diagnostics.processObservation, .exitedObserved)
            XCTAssertEqual(diagnostics.workerPID, 4242)
            XCTAssertEqual(diagnostics.processExitStatus, 1)
            XCTAssertEqual(diagnostics.lastObservedEvent, "runtime_accepted")
            XCTAssertTrue(diagnostics.eventTail.contains { $0.event == "worker_exited" })
            XCTAssertNil(diagnostics.activeCallbackID)
            XCTAssertEqual(diagnostics.linkedCallbackRuntime?.provider, "fake")
            XCTAssertEqual(diagnostics.stderrLogRelativePath, "worker-runs/attempt/worker-stderr.log")
            XCTAssertEqual(diagnostics.stdoutProtocolLogRelativePath, "worker-runs/attempt/stdout-protocol.ndjson")
            XCTAssertTrue(diagnostics.eventTail.contains { $0.event == "runtime_submission_persisted" })
            XCTAssertTrue(diagnostics.eventTail.contains { $0.detail?.contains("payload=excluded") == true })
            XCTAssertTrue(diagnostics.eventTail.contains {
                $0.event == "failed"
                    && $0.detail == "exception_type=NameError source_frame=gepa.worker.run:312 error_payload=excluded"
            })
            XCTAssertFalse(diagnostics.eventTail.contains { $0.detail?.contains("expectedOutput") == true })
            let exposed = try XCTUnwrap(
                MCPAgentSessionControlToolProvider.diagnosticValue(diagnostics).objectValue
            )
            XCTAssertEqual(exposed["worker_pid"]?.intValue, 4242)
            XCTAssertEqual(exposed["process_observation"]?.stringValue, "exited_observed")
            XCTAssertEqual(exposed["stderr_log_relative_path"]?.stringValue, "worker-runs/attempt/worker-stderr.log")
            XCTAssertEqual(exposed["stdout_protocol_log_relative_path"]?.stringValue, "worker-runs/attempt/stdout-protocol.ndjson")
            XCTAssertTrue(exposed["pid_liveness_caveat"]?.stringValue?.contains("historical observation") == true)
            XCTAssertEqual(exposed["payload_policy"]?.stringValue, "Protocol request/response bodies are excluded; arbitrary stderr is redacted.")
            let exposedEvents = try XCTUnwrap(exposed["event_tail"]?.arrayValue)
            XCTAssertTrue(exposedEvents.contains {
                $0.objectValue?["detail"]?.stringValue
                    == "exception_type=NameError source_frame=gepa.worker.run:312 error_payload=excluded"
            })

            let directory = try await harness.service.recordDirectoryURL(experimentID: id)
            let overview = try String(contentsOf: directory.appendingPathComponent("overview.md"), encoding: .utf8)
            XCTAssertTrue(overview.contains("Worker process observation: `exited_observed`"))
            XCTAssertTrue(overview.contains("persisted PID is historical evidence"))
            XCTAssertTrue(overview.contains("stdout-protocol.ndjson"))
            XCTAssertTrue(overview.contains("exception_type=NameError source_frame=gepa.worker.run:312 error_payload=excluded"))
        }

        func testRestartMarksPersistedWorkerPIDAsUnknownRatherThanAlive() async throws {
            let harness = makeHarness()
            defer { try? FileManager.default.removeItem(at: harness.root) }
            harness.runtime.holdResults = true
            harness.runtime.observationsOnSubmit = [
                .workerPrepared(
                    stderrLogRelativePath: "worker-runs/attempt/worker-stderr.log",
                    stdoutProtocolLogRelativePath: "worker-runs/attempt/stdout-protocol.ndjson"
                ),
                .workerStarted(pid: 4343, processIdentity: "python3.11 pid 4343")
            ]
            let id = try await preparedOptimizationExperiment(harness)
            let plan = try XCTUnwrap(harness.service.record(id: id)?.currentPlan)
            try await harness.service.approve(experimentID: id, displayedDigest: plan.digest)
            try await harness.service.run(experimentID: id)
            await harness.runtime.waitUntilWaitingForResult()

            let reopened = PromptExperimentService(
                store: PromptExperimentStore(rootURL: harness.root),
                runtime: FakeRuntime(),
                resolveTarget: Self.fakeTarget,
                now: { Date(timeIntervalSince1970: 2000) }
            )
            await reopened.load()
            let recovered = try XCTUnwrap(reopened.record(id: id)?.attempts.first?.diagnostics)
            XCTAssertEqual(recovered.workerPID, 4343)
            XCTAssertEqual(recovered.processObservation, .unknownAfterRestart)
            XCTAssertEqual(recovered.lastObservedEvent, "service_restarted")
            XCTAssertNil(recovered.activeCallbackID)
            XCTAssertTrue(recovered.eventTail.last?.detail?.contains("liveness is unknown") == true)

            harness.runtime.settleFirst()
            await harness.service.waitForExecutionForTesting(experimentID: id)
        }

        func testGEPARuntimeUsesStableBundledSealAndNoManualSetupContract() {
            let sealed = PromptExperimentGEPAWorker.configuredPythonSealValue()

            XCTAssertEqual(PromptExperimentGEPAWorker.pythonVersion, "3.11.16")
            XCTAssertTrue(sealed.hasPrefix("bundle://PromptExperimentPython/"))
            XCTAssertTrue(sealed.hasSuffix("/python/bin/python3.11"))
            let status = PromptExperimentGEPAWorker.runtimeStatus.lowercased()
            XCTAssertTrue(status.contains("bundled") || status.contains("packaged prompt experiment runtime"))
            XCTAssertTrue(status.contains("no user"))
            XCTAssertFalse(status.contains("pip install"))
            XCTAssertFalse(status.contains("homebrew"))
        }

        func testCommandEvaluatorDistinguishesCandidateAndInfrastructureFailures() throws {
            let candidate = try NativePromptExperimentContextBuilderRuntime.commandEvaluationReply(
                stdout: #"{"score":0.25,"feedback":"candidate output was invalid","failure_kind":"candidate"}"#,
                split: .training,
                minimumScore: 0,
                maximumScore: 1,
                elapsedSeconds: 0.1
            )
            XCTAssertFalse(candidate.ok)
            XCTAssertEqual(candidate.failureKind, .candidate)
            XCTAssertEqual(candidate.score, 0.25)
            XCTAssertEqual(candidate.feedback, "candidate output was invalid")
            XCTAssertEqual(candidate.error, "candidate output was invalid")

            XCTAssertThrowsError(try NativePromptExperimentContextBuilderRuntime.commandEvaluationReply(
                stdout: #"{"score":0,"feedback":"sandbox bootstrap failed","failure_kind":"infrastructure"}"#,
                split: .training,
                minimumScore: 0,
                maximumScore: 1,
                elapsedSeconds: 0.1
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains("infrastructure failure"))
                XCTAssertTrue(error.localizedDescription.contains("sandbox bootstrap failed"))
            }
        }

        func testHiddenTestCommandReplyWithholdsGraderStdoutFeedbackAndError() throws {
            let marker = "HIDDEN_ANSWER_KEY_42"
            let stdoutWith = { (kind: String?) in
                let failure = kind.map { #","failure_kind":"\#($0)""# } ?? ""
                return #"{"score":0.25,"feedback":"expected \#(marker)"\#(failure)}"#
            }
            let heldOut = PromptExperimentDatasetSplit.heldOutFeedback

            let passing = try NativePromptExperimentContextBuilderRuntime.commandEvaluationReply(
                stdout: stdoutWith(nil), split: .hiddenTest, minimumScore: 0, maximumScore: 1, elapsedSeconds: 0.1
            )
            XCTAssertTrue(passing.ok)
            XCTAssertNil(passing.failureKind)
            XCTAssertEqual(passing.score, 0.25)
            XCTAssertNil(passing.output)
            XCTAssertEqual(passing.feedback, heldOut)
            XCTAssertNil(passing.error)

            // The worker's ok:false candidate path turns `error` into GEPA feedback.
            let candidate = try NativePromptExperimentContextBuilderRuntime.commandEvaluationReply(
                stdout: stdoutWith("candidate"), split: .hiddenTest, minimumScore: 0, maximumScore: 1, elapsedSeconds: 0.1
            )
            XCTAssertFalse(candidate.ok)
            XCTAssertEqual(candidate.failureKind, .candidate)
            XCTAssertEqual(candidate.score, 0.25)
            XCTAssertEqual(NativePromptExperimentContextBuilderRuntime.checkpointScore(operation: "evaluate", reply: candidate), 0.25)
            XCTAssertNil(candidate.output)
            XCTAssertEqual(candidate.feedback, heldOut)
            XCTAssertEqual(candidate.error, heldOut)

            for reply in [passing, candidate] {
                let wire = try String(decoding: JSONSerialization.data(withJSONObject: reply.jsonObject), as: UTF8.self)
                XCTAssertFalse(wire.contains(marker), "Hidden grader payload reached the GEPA wire: \(wire)")
            }

            XCTAssertThrowsError(try NativePromptExperimentContextBuilderRuntime.commandEvaluationReply(
                stdout: stdoutWith("infrastructure"), split: .hiddenTest, minimumScore: 0, maximumScore: 1, elapsedSeconds: 0.1
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains("infrastructure failure"))
                XCTAssertFalse(error.localizedDescription.contains(marker))
            }

            // Non-hidden command feedback and output still reach GEPA.
            let validation = try NativePromptExperimentContextBuilderRuntime.commandEvaluationReply(
                stdout: stdoutWith(nil), split: .validation, minimumScore: 0, maximumScore: 1, elapsedSeconds: 0.1
            )
            XCTAssertEqual(validation.feedback, "expected \(marker)")
            XCTAssertEqual(validation.output, stdoutWith(nil))
        }

        func testScoredCommandCandidateFailureCheckpointsButInfrastructureDoesNot() throws {
            let candidate = try NativePromptExperimentContextBuilderRuntime.commandEvaluationReply(
                stdout: #"{"score":0.25,"feedback":"candidate output was invalid","failure_kind":"candidate"}"#,
                split: .training,
                minimumScore: 0,
                maximumScore: 1,
                elapsedSeconds: 0.1
            )
            XCTAssertEqual(NativePromptExperimentContextBuilderRuntime.checkpointScore(operation: "evaluate", reply: candidate), 0.25)

            let passing = PromptExperimentGEPAHostReply(ok: true, output: "out", score: 1, feedback: "ok", failureKind: nil, error: nil, elapsedSeconds: 0.1)
            XCTAssertEqual(NativePromptExperimentContextBuilderRuntime.checkpointScore(operation: "evaluate", reply: passing), 1)
            XCTAssertEqual(NativePromptExperimentContextBuilderRuntime.checkpointScore(operation: "mcp_grade", reply: passing), 1)
            XCTAssertNil(NativePromptExperimentContextBuilderRuntime.checkpointScore(operation: "reflect", reply: passing))
            XCTAssertNil(NativePromptExperimentContextBuilderRuntime.checkpointScore(operation: "mcp_begin", reply: passing))

            let scoredInfrastructure = PromptExperimentGEPAHostReply(ok: false, output: nil, score: 0, feedback: nil, failureKind: .infrastructure, error: "boom", elapsedSeconds: nil)
            XCTAssertNil(NativePromptExperimentContextBuilderRuntime.checkpointScore(operation: "evaluate", reply: scoredInfrastructure))
            let okInfrastructure = PromptExperimentGEPAHostReply(ok: true, output: nil, score: 0, feedback: nil, failureKind: .infrastructure, error: nil, elapsedSeconds: nil)
            XCTAssertNil(NativePromptExperimentContextBuilderRuntime.checkpointScore(operation: "evaluate", reply: okInfrastructure))
            let unclassifiedFailure = PromptExperimentGEPAHostReply(ok: false, output: nil, score: 0.5, feedback: nil, failureKind: nil, error: "boom", elapsedSeconds: nil)
            XCTAssertNil(NativePromptExperimentContextBuilderRuntime.checkpointScore(operation: "evaluate", reply: unclassifiedFailure))
            let unscoredCandidate = PromptExperimentGEPAHostReply(ok: false, output: nil, score: nil, feedback: nil, failureKind: .candidate, error: "bad", elapsedSeconds: nil)
            XCTAssertNil(NativePromptExperimentContextBuilderRuntime.checkpointScore(operation: "evaluate", reply: unscoredCandidate))
        }

        func testEvaluationAdmissionEnforcesSealedBudgetAndLogicalIdentity() {
            var admission = PromptExperimentEvaluationAdmission(maxEvaluations: 2)
            let first = UUID()
            let second = UUID()

            XCTAssertEqual(admission.admit(logicalCallbackID: nil), .failure(.missingLogicalCallbackID))
            XCTAssertEqual(admission.admittedCount, 0, "Rejections must not consume budget.")

            XCTAssertEqual(admission.admit(logicalCallbackID: first), .success(1))
            XCTAssertEqual(admission.admit(logicalCallbackID: first), .failure(.reusedLogicalCallbackID))
            XCTAssertEqual(admission.admittedCount, 1)

            XCTAssertEqual(admission.admit(logicalCallbackID: second), .success(2))
            XCTAssertEqual(admission.admit(logicalCallbackID: UUID()), .failure(.budgetExhausted(maxEvaluations: 2)))
            XCTAssertEqual(admission.admit(logicalCallbackID: second), .failure(.reusedLogicalCallbackID))
            XCTAssertEqual(admission.admittedCount, 2, "Admissions are retained; failed or cancelled evaluations are never refunded.")
        }

        func testPromptOnlyClaudeProfileDisablesNativeAndWebTools() {
            let configuration = ClaudeCodeAgentConfig.promptExperiment(modelString: "claude-sonnet-4-6")
            XCTAssertFalse(configuration.allowNativeBashTool)
            XCTAssertTrue(configuration.mcpStrictMode)
            XCTAssertFalse(configuration.toolSearchEnabled)
            for tool in ["Bash", "Read", "Write", "Edit", "WebSearch", "WebFetch", "Task"] {
                XCTAssertTrue(configuration.disallowedBuiltInTools.contains(tool))
            }
            XCTAssertTrue(configuration.processEnvironmentOverrides.isEmpty)
        }

        func testGEPAWorkerEnvironmentDoesNotInheritProviderCredentials() {
            let environment = PromptExperimentGEPAWorker.workerEnvironment(
                home: URL(fileURLWithPath: "/tmp/gepa-home"),
                temporaryDirectory: URL(fileURLWithPath: "/tmp/gepa-tmp")
            )
            XCTAssertEqual(Set(environment.keys), ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"])
            XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
            XCTAssertEqual(environment["TMPDIR"], "/tmp/gepa-tmp")
            XCTAssertNil(environment["PYTHONHOME"])
            XCTAssertNil(environment["PYTHONPATH"])
            XCTAssertNil(environment["PYTHONDONTWRITEBYTECODE"])
            XCTAssertNil(environment["OPENAI_API_KEY"])
            XCTAssertNil(environment["ANTHROPIC_API_KEY"])
            XCTAssertNil(environment["CODEX_HOME"])
        }

        private func makeHarness() -> Harness {
            let root = temporaryRoot()
            let store = PromptExperimentStore(rootURL: root)
            let runtime = FakeRuntime()
            let service = PromptExperimentService(
                store: store,
                runtime: runtime,
                resolveTarget: Self.fakeTarget,
                now: { Date(timeIntervalSince1970: 1000) }
            )
            return Harness(root: root, store: store, runtime: runtime, service: service)
        }

        private func preparedExperiment(
            _ harness: Harness,
            targetSelector: String = "explore"
        ) async throws -> UUID {
            await harness.service.load()
            let id = try await harness.service.createExperiment(controllerSessionID: UUID(), sourceTabID: UUID())
            let record = try XCTUnwrap(harness.service.record(id: id))
            var draft = try XCTUnwrap(record.draft)
            let currentDigest = try draft.contentDigest()
            draft.title = "Native pilot"
            draft.taskInput = "Identify the named value in the fixture."
            draft.syntheticFixture = "# Synthetic fixture\n\nThe named value is cobalt."
            draft.originalInstructions = "Read the fixture and report the named value."
            draft.candidateInstructions = "Inspect only the fixture, then report the named value with one sentence of evidence."
            draft.targetRole = targetSelector
            let updated = try await harness.service.updateDraft(
                experimentID: id,
                expectedDraftID: draft.id,
                expectedDraftVersion: draft.optimisticVersion,
                expectedDraftDigest: currentDigest,
                draft: draft
            )
            _ = try await harness.service.seal(
                experimentID: id,
                expectedDraftID: updated.id,
                expectedDraftVersion: updated.optimisticVersion,
                expectedDraftDigest: updated.contentDigest()
            )
            return id
        }

        private func updatedOptimizationDraft(
            _ harness: Harness
        ) async throws -> (id: UUID, draft: PromptExperimentDraft) {
            await harness.service.load()
            let id = try await harness.service.createOptimizationExperiment(
                controllerSessionID: UUID(),
                sourceTabID: UUID()
            )
            var draft = try XCTUnwrap(harness.service.record(id: id)?.draft)
            let currentDigest = try draft.contentDigest()
            draft.title = "Real GEPA test"
            draft.optimization = Self.validOptimization()
            let updated = try await harness.service.updateDraft(
                experimentID: id,
                expectedDraftID: draft.id,
                expectedDraftVersion: draft.optimisticVersion,
                expectedDraftDigest: currentDigest,
                draft: draft
            )
            return (id, updated)
        }

        private func preparedOptimizationExperiment(_ harness: Harness) async throws -> UUID {
            let (id, draft) = try await updatedOptimizationDraft(harness)
            _ = try await harness.service.seal(
                experimentID: id,
                expectedDraftID: draft.id,
                expectedDraftVersion: draft.optimisticVersion,
                expectedDraftDigest: draft.contentDigest()
            )
            return id
        }

        private func approvedExperiment(_ harness: Harness) async throws -> UUID {
            let id = try await preparedExperiment(harness)
            let digest = try XCTUnwrap(harness.service.record(id: id)?.currentPlan?.digest)
            try await harness.service.approve(experimentID: id, displayedDigest: digest)
            return id
        }

        private func temporaryRoot() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("PromptExperimentServiceTests-\(UUID().uuidString)", isDirectory: true)
        }

        private func blockCanonicalPersistence(at root: URL) throws {
            let canonicalURL = root.appendingPathComponent("experiments.json", isDirectory: false)
            try FileManager.default.removeItem(at: canonicalURL)
            try FileManager.default.createDirectory(at: canonicalURL, withIntermediateDirectories: false)
        }

        private static func fakeTarget(_ role: String) -> PromptExperimentResolvedTarget? {
            PromptExperimentResolvedTarget(
                role: role,
                agentRaw: "fake",
                modelRaw: "fake-model",
                displayName: "Fake Model"
            )
        }

        private static func validOptimization() -> PromptExperimentOptimizationSpecification {
            PromptExperimentOptimizationSpecification(
                seedCandidate: nil,
                objective: "Improve the instructions so the reviewed answer is extracted exactly.",
                background: "Operate only on the reviewed example data.",
                examples: [
                    PromptExperimentExample(
                        id: "reviewed-1",
                        split: .validation,
                        input: "The named value is cobalt.",
                        expectedOutput: "cobalt",
                        reviewerNotes: "Reviewed synthetic example"
                    )
                ],
                evaluator: PromptExperimentEvaluatorSpecification(
                    kind: .exactMatch,
                    rubric: "",
                    judgeTargetSelector: nil,
                    command: nil,
                    candidateFileName: nil,
                    minimumScore: 0,
                    maximumScore: 1
                ),
                execution: PromptExperimentExecutionSpecification(
                    adapter: .contextBuilder,
                    targetSelector: "executor",
                    instructions: "Use the candidate as governing instructions and answer the example input."
                ),
                gepa: PromptExperimentGEPAConfiguration(
                    engine: "gepa",
                    pythonExecutablePath: "/usr/bin/python3",
                    reflectionTargetSelector: "reflector",
                    maxEvaluations: 20,
                    stopAtScore: 1,
                    randomSeed: 0
                )
            )
        }

        private static func validDraft(date: Date, repetitions: Int) -> PromptExperimentDraft {
            PromptExperimentDraft(
                revision: 1,
                title: "Deterministic",
                taskInput: "Task",
                syntheticFixture: "Fixture",
                originalInstructions: "Original",
                candidateInstructions: "Candidate",
                targetRole: "explore",
                repetitions: repetitions,
                createdAt: date,
                updatedAt: date
            )
        }
    }
#endif
