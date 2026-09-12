import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class PromptExperimentServiceTests: XCTestCase {
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

        func testMCPConfigurationAllowsOnlyReadOnlyToolsAndRoundTripsResolvedFields() throws {
            let valid = PromptExperimentMCPConfiguration(toolNames: ["read_file"], component: "tool_description_read_file", toolDefinitionsJson: "[]", serverSha256: "digest")
            XCTAssertNoThrow(try valid.validate())
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
            XCTAssertEqual(result.candidates.map(\.candidatePreview), ["baseline instructions", "improved instructions"])
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
            XCTAssertEqual(next.draft?.optimization?.seedCandidate, "improved instructions")
            XCTAssertEqual(next.draft?.optimization?.stage, .search)
            XCTAssertNil(next.draft?.optimization?.preparationCandidates)
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
                minimumScore: 0,
                maximumScore: 1,
                elapsedSeconds: 0.1
            )
            XCTAssertFalse(candidate.ok)
            XCTAssertEqual(candidate.failureKind, .candidate)
            XCTAssertEqual(candidate.score, 0.25)

            XCTAssertThrowsError(try NativePromptExperimentContextBuilderRuntime.commandEvaluationReply(
                stdout: #"{"score":0,"feedback":"sandbox bootstrap failed","failure_kind":"infrastructure"}"#,
                minimumScore: 0,
                maximumScore: 1,
                elapsedSeconds: 0.1
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains("infrastructure failure"))
            }
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
