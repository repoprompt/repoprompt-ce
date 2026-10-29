import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// Shared fixtures: a temp built-in prompt registry with an exact-match suite, fake
    /// prompt-only targets, and a scriptable runtime.
    @MainActor
    enum PromptExperimentTestFixtures {
        static let execution = PromptExperimentResolvedTarget(
            role: "engineer", agentRaw: AgentProviderKind.claudeCode.rawValue, modelRaw: "exec-model", displayName: "Exec"
        )
        static let reflection = PromptExperimentResolvedTarget(
            role: "design", agentRaw: AgentProviderKind.claudeCode.rawValue, modelRaw: "reflect-model", displayName: "Reflect"
        )
        static let judge = PromptExperimentResolvedTarget(
            role: "pair", agentRaw: AgentProviderKind.claudeCode.rawValue, modelRaw: "judge-model", displayName: "Judge"
        )

        static func resolveTarget(_ selector: String) throws -> PromptExperimentResolvedTarget {
            switch selector {
            case "engineer": execution
            case "design": reflection
            case "pair": judge
            case "codex": PromptExperimentResolvedTarget(role: "codex", agentRaw: AgentProviderKind.codexExec.rawValue, modelRaw: "gpt", displayName: "Codex")
            default: throw PromptExperimentAuthorityError.targetUnavailable("Unknown target '\(selector)'.")
            }
        }

        struct SuiteCase {
            let id: String
            let split: String
            let input: String
            var expected: String = "good"
        }

        static let defaultCases = [
            SuiteCase(id: "t1", split: "training", input: "train input"),
            SuiteCase(id: "v1", split: "validation", input: "validation input")
        ]

        static let checklistRubric = """
        # Unit checklist

        Judge the answer.

        - `answers` (weight 1): Does it answer the request?
        - `grounded` (weight 1): Is it grounded in the context?
        """

        /// Writes `oracle-plan/prompt.md` and an exact-match `suite.json` under `root`, or a
        /// model-judge suite with `judgeRubric` as its checklist.
        static func makeRegistry(
            root: URL,
            prompt: String = "seed prompt",
            cases: [SuiteCase] = defaultCases,
            suiteID: String = "unit-suite",
            judgeRubric: String? = nil
        ) throws -> BuiltInPromptRegistry {
            let directory = root.appendingPathComponent("prompts/oracle-plan", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("\(prompt)\n".utf8).write(to: directory.appendingPathComponent("prompt.md"))
            if let judgeRubric {
                try Data(judgeRubric.utf8).write(to: directory.appendingPathComponent("rubric.md"))
            }
            let grader: [String: Any] = judgeRubric == nil
                ? ["kind": "exact_match", "score_range": ["min": 0, "max": 1]]
                : ["kind": "model_judge", "score_range": ["min": 0, "max": 1], "rubric": "rubric.md"]
            let suite: [String: Any] = [
                "schema_version": 1,
                "suite_id": suiteID,
                "prompt_id": "oracle-plan",
                "prompt_variant": "built_in",
                "grader": grader,
                "cases": cases.map { ["id": $0.id, "split": $0.split, "input": $0.input, "expected_output": $0.expected] }
            ]
            try JSONSerialization.data(withJSONObject: suite, options: [.sortedKeys]).write(to: directory.appendingPathComponent("suite.json"))
            return BuiltInPromptRegistry(promptsDirectory: root.appendingPathComponent("prompts", isDirectory: true))
        }

        /// An experiment built directly from a registry (optionally already approved).
        static func makeExperiment(
            registry: BuiltInPromptRegistry,
            maxEvaluations: Int = 4,
            maxProviderRetries: Int = 0,
            noiseFloorReplicates: Int = 0,
            title: String = "Experiment",
            approved: Bool = true
        ) throws -> PromptExperiment {
            let resource = try registry.resource(.oraclePlan)
            let suite = try PromptSuiteLoader.load(promptID: .oraclePlan, registry: registry)
            var settings = PromptExperimentGEPASettings()
            settings.maxProviderRetries = maxProviderRetries
            // Most runtime tests script exact spend; noise-floor tests opt in.
            settings.noiseFloorReplicates = noiseFloorReplicates
            let authority = PromptExperimentAuthority(
                promptID: .oraclePlan,
                promptResourceSHA256: resource.sha256,
                suiteID: suite.suiteID,
                suiteSHA256: suite.suiteSHA256,
                rubricSHA256: suite.grader.rubric?.sha256,
                targets: PromptExperimentTargets(execution: execution, reflection: reflection, judge: nil),
                settings: settings,
                maxEvaluations: maxEvaluations,
                calibrationEvaluations: PromptExperimentBudgetLedger.calibrationEvaluations(
                    cases: suite.cases, replicates: noiseFloorReplicates
                ),
                pythonSealValue: "bundle://PromptExperimentPython/test/python/bin/python3.11",
                gepaRevision: PromptExperimentGEPAConfiguration.pinnedRevision
            )
            let digest = try authority.digest()
            let date = Date(timeIntervalSince1970: 1000)
            return PromptExperiment(
                id: UUID(), title: title, createdAt: date, updatedAt: date,
                authority: authority, authorityDigest: digest, supersedes: nil,
                approvalRequest: nil,
                approval: approved ? PromptExperimentApproval(authorityDigest: digest, approvedAt: date) : nil,
                runs: [], proposals: []
            )
        }

        static func makeService(
            root: URL,
            registry: BuiltInPromptRegistry,
            runtime: FakeRuntime,
            patchSourceRoot: URL? = nil
        ) -> PromptExperimentService {
            PromptExperimentService(
                store: PromptExperimentStore(rootURL: root.appendingPathComponent("store", isDirectory: true)),
                runtime: runtime,
                registry: registry,
                patchProposer: PromptPatchProposer(sourceRoot: patchSourceRoot),
                resolveTarget: { try resolveTarget($0) },
                availableTargets: { [execution, reflection, judge] },
                pythonSealValue: { "bundle://PromptExperimentPython/test/python/bin/python3.11" },
                diagnosticsSaveInterval: .milliseconds(10)
            )
        }
    }

    /// Scriptable runtime: records submissions, emits checkpoints, and settles runs on demand.
    @MainActor
    final class FakeRuntime: PromptExperimentRuntime {
        let root: URL
        private(set) var submitted: [UUID] = []
        private(set) var cancelled: [UUID] = []
        var checkpointsOnSubmit: [PromptExperimentCheckpoint] = []
        var nextResults: [PromptExperimentRuntimeResult] = []
        var holdRuns = false
        var preflightError: Error?
        private var held: [UUID: CheckedContinuation<PromptExperimentRuntimeResult, Never>] = [:]

        init(root: URL) {
            self.root = root
        }

        func preflight(_: PromptExperiment) async throws {
            if let preflightError { throw preflightError }
        }

        func submit(
            _ request: PromptExperimentRunRequest,
            progress: @escaping @MainActor @Sendable (String) async -> Void,
            observation: @escaping @MainActor @Sendable (PromptExperimentRuntimeObservation) async -> Void,
            checkpoint: @escaping PromptExperimentCheckpointSink
        ) async throws -> PromptExperimentRuntimeHandle {
            submitted.append(request.runID)
            await progress("fake progress")
            await observation(.workerStarted(pid: 42, processIdentity: "fake"))
            for value in checkpointsOnSubmit {
                try await checkpoint(value)
            }
            return PromptExperimentRuntimeHandle(id: request.runID)
        }

        func wait(for handle: PromptExperimentRuntimeHandle) async -> PromptExperimentRuntimeResult {
            if holdRuns {
                return await withCheckedContinuation { held[handle.id] = $0 }
            }
            return nextResults.isEmpty ? Self.result(.completed, admissionsAfter: 1) : nextResults.removeFirst()
        }

        func release(_ runID: UUID, _ result: PromptExperimentRuntimeResult) {
            held.removeValue(forKey: runID)?.resume(returning: result)
        }

        var heldRunIDs: [UUID] {
            Array(held.keys)
        }

        func cancel(_ handle: PromptExperimentRuntimeHandle) async -> PromptExperimentCancellationObservation {
            cancelled.append(handle.id)
            release(handle.id, Self.result(.cancelled, admissionsAfter: 1))
            return .requested
        }

        func runDirectoryURL(for experiment: PromptExperiment) -> URL {
            root.appendingPathComponent(
                GEPARunController.runDirectoryRelativePath(experimentID: experiment.id, authorityDigest: experiment.authorityDigest),
                isDirectory: true
            )
        }

        static func result(_ disposition: PromptExperimentRuntimeDisposition, admissionsAfter: Int?) -> PromptExperimentRuntimeResult {
            PromptExperimentRuntimeResult(
                disposition: disposition, optimization: nil, admissionsAfter: admissionsAfter, interruptedAdmissionsSettled: 0
            )
        }
    }

    @MainActor
    final class PromptExperimentServiceTests: XCTestCase {
        private var roots: [URL] = []

        override func tearDown() async throws {
            for root in roots {
                try? FileManager.default.removeItem(at: root)
            }
            roots = []
            try await super.tearDown()
        }

        private func makeRoot() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            roots.append(root)
            return root
        }

        private func makeHarness() throws -> (service: PromptExperimentService, runtime: FakeRuntime, registry: BuiltInPromptRegistry, root: URL) {
            let root = try makeRoot()
            let registry = try PromptExperimentTestFixtures.makeRegistry(root: root)
            let runtime = FakeRuntime(root: root)
            return (PromptExperimentTestFixtures.makeService(root: root, registry: registry, runtime: runtime), runtime, registry, root)
        }

        private func create(_ service: PromptExperimentService, cap: Int = 4) async throws -> PromptExperiment {
            try await service.createOrUpdate(PromptExperimentCreateRequest(promptID: "oracle-plan", maxEvaluations: cap))
        }

        private func approveAndRun(_ service: PromptExperimentService, _ experiment: PromptExperiment) async throws {
            _ = try await service.requestApproval(experimentID: experiment.id, expectedAuthorityDigest: experiment.authorityDigest)
            try await service.approve(experimentID: experiment.id, authorityDigest: experiment.authorityDigest)
        }

        // MARK: Create / validate

        func testCreateAggregatesEveryFieldError() async throws {
            let harness = try makeHarness()
            do {
                _ = try await harness.service.createOrUpdate(PromptExperimentCreateRequest(
                    promptID: "not-a-prompt", executionTarget: "codex", maxEvaluations: nil, maxProviderRetries: 9
                ))
                XCTFail("Expected validation failure")
            } catch let PromptExperimentAuthorityError.validation(fields) {
                XCTAssertEqual(Set(fields.map(\.field)), ["prompt_id", "execution_target", "max_evaluations", "max_provider_retries"])
            }
            do {
                _ = try await create(harness.service, cap: 3)
                XCTFail("A cap below one mutation cycle must be rejected before approval")
            } catch let PromptExperimentAuthorityError.validation(fields) {
                XCTAssertEqual(fields.map(\.field), ["max_evaluations"])
            }
            XCTAssertTrue(harness.service.experiments.isEmpty)
        }

        func testCreateCapturesHashesDefaultsAndIsUnapproved() async throws {
            let harness = try makeHarness()
            let experiment = try await create(harness.service)
            let suite = try PromptSuiteLoader.load(promptID: .oraclePlan, registry: harness.registry)
            XCTAssertEqual(experiment.authority.promptResourceSHA256, try harness.registry.resource(.oraclePlan).sha256)
            XCTAssertEqual(experiment.authority.suiteSHA256, suite.suiteSHA256)
            XCTAssertEqual(experiment.authority.targets.execution, PromptExperimentTestFixtures.execution)
            XCTAssertEqual(experiment.authority.targets.reflection, PromptExperimentTestFixtures.reflection)
            XCTAssertNil(experiment.authority.targets.judge, "exact-match suites have no judge")
            XCTAssertEqual(experiment.status, .unapproved)
            XCTAssertEqual(experiment.authorityDigest, try experiment.authority.digest())
        }

        func testNativeSetupUsesTheServiceRegistryAndNeverSpends() async throws {
            let harness = try makeHarness()
            let options = harness.service.promptOptions()
            let plan = try XCTUnwrap(options.first { $0.promptID == .oraclePlan })
            XCTAssertEqual(plan.suite?.suiteID, "unit-suite")
            XCTAssertEqual(plan.resourceSHA256, try harness.registry.resource(.oraclePlan).sha256)
            XCTAssertNil(plan.unavailableReason)
            for option in options where option.promptID != .oraclePlan {
                XCTAssertNil(option.suite, "An unavailable resource must not be offered as runnable")
                XCTAssertNotNil(option.unavailableReason)
            }
            let draft = try await harness.service.createOrUpdate(PromptExperimentCreateRequest(
                title: "Native small experiment", promptID: plan.id, maxEvaluations: 25
            ))
            XCTAssertEqual(draft.status, .unapproved)
            XCTAssertNil(draft.approvalRequest)
            XCTAssertNil(draft.approval)
            XCTAssertTrue(harness.runtime.submitted.isEmpty)
            XCTAssertEqual(draft.authority.maximumTotalEvaluations, 27)
            XCTAssertEqual(draft.authority.approvalBudgetSummary, "up to 27 evaluations (25 search + 2 calibration)")
        }

        func testJudgeCannotDifferFromReflectionOnlyByEffort() async throws {
            let root = try makeRoot()
            let registry = try PromptExperimentTestFixtures.makeRegistry(root: root, judgeRubric: PromptExperimentTestFixtures.checklistRubric)
            let reflection = PromptExperimentResolvedTarget(
                role: "design", agentRaw: AgentProviderKind.claudeCode.rawValue,
                modelRaw: "shared-model:high", displayName: "Shared High"
            )
            let sameModelJudge = PromptExperimentResolvedTarget(
                role: "pair", agentRaw: AgentProviderKind.claudeCode.rawValue,
                modelRaw: "shared-model:medium", displayName: "Shared Medium"
            )
            let execution = PromptExperimentTestFixtures.execution
            let runtime = FakeRuntime(root: root)
            let service = PromptExperimentService(
                store: PromptExperimentStore(rootURL: root.appendingPathComponent("store", isDirectory: true)),
                runtime: runtime, registry: registry,
                resolveTarget: { selector in
                    switch selector {
                    case "design": reflection
                    case "pair": sameModelJudge
                    default: execution
                    }
                },
                availableTargets: { [execution, reflection, sameModelJudge] },
                pythonSealValue: { "test-python" }
            )
            XCTAssertNotEqual(reflection.canonicalSelectionID, sameModelJudge.canonicalSelectionID)
            XCTAssertEqual(reflection.judgmentModelIdentity, sameModelJudge.judgmentModelIdentity)
            XCTAssertEqual(service.targetDefaults().judge, execution, "Default selection must skip effort variants of the reflector")
            do {
                _ = try await service.createOrUpdate(PromptExperimentCreateRequest(
                    promptID: "oracle-plan", judgeTarget: "pair", maxEvaluations: 4
                ))
                XCTFail("Effort variants must not be treated as independent judges")
            } catch let PromptExperimentAuthorityError.validation(fields) {
                XCTAssertEqual(fields.map(\.field), ["judge_target"])
            }
            XCTAssertTrue(service.experiments.isEmpty)
            XCTAssertTrue(runtime.submitted.isEmpty)
        }

        // MARK: Approval

        func testRequestNeverApprovesAndOnlyNativeApproveRecordsOneApproval() async throws {
            let harness = try makeHarness()
            let experiment = try await create(harness.service)
            do {
                try await harness.service.approve(experimentID: experiment.id, authorityDigest: experiment.authorityDigest)
                XCTFail("Approval requires a pending request")
            } catch PromptExperimentAuthorityError.approvalNotRequested {}

            let requested = try await harness.service.requestApproval(experimentID: experiment.id, expectedAuthorityDigest: experiment.authorityDigest)
            XCTAssertEqual(requested.status, .awaitingApproval)
            XCTAssertFalse(requested.isApproved)
            XCTAssertTrue(harness.runtime.submitted.isEmpty, "requesting approval never spends")

            do {
                try await harness.service.approve(experimentID: experiment.id, authorityDigest: "stale")
                XCTFail("A different digest must not approve")
            } catch PromptExperimentAuthorityError.authorityChanged {}

            try await harness.service.approve(experimentID: experiment.id, authorityDigest: experiment.authorityDigest)
            await harness.service.waitForSettlementForTesting(experimentID: experiment.id)
            let approved = try XCTUnwrap(harness.service.experiment(id: experiment.id))
            XCTAssertEqual(approved.approval?.authorityDigest, experiment.authorityDigest)
            XCTAssertNil(approved.approvalRequest)
            XCTAssertEqual(harness.runtime.submitted.count, 1, "approval starts the first run")
            do {
                _ = try await harness.service.requestApproval(experimentID: experiment.id, expectedAuthorityDigest: nil)
                XCTFail("An approved experiment is never re-approved")
            } catch PromptExperimentAuthorityError.alreadyApproved {}
        }

        func testJudgeDefaultsToADifferentModelThanReflectionAndAnIdenticalChoiceIsRejected() async throws {
            let root = try makeRoot()
            let registry = try PromptExperimentTestFixtures.makeRegistry(root: root, judgeRubric: PromptExperimentTestFixtures.checklistRubric)
            let service = PromptExperimentTestFixtures.makeService(root: root, registry: registry, runtime: FakeRuntime(root: root))

            let defaults = try await service.createOrUpdate(PromptExperimentCreateRequest(promptID: "oracle-plan", maxEvaluations: 4))
            XCTAssertEqual(defaults.authority.targets.judge, PromptExperimentTestFixtures.judge)

            // Reflection moved onto the default judge's model: the default judge moves off it.
            let moved = try await service.createOrUpdate(PromptExperimentCreateRequest(
                promptID: "oracle-plan", reflectionTarget: "pair", maxEvaluations: 4
            ))
            let judge = try XCTUnwrap(moved.authority.targets.judge)
            XCTAssertNotEqual(judge.canonicalSelectionID, moved.authority.targets.reflection.canonicalSelectionID)

            do {
                _ = try await service.createOrUpdate(PromptExperimentCreateRequest(
                    promptID: "oracle-plan", judgeTarget: "design", maxEvaluations: 4
                ))
                XCTFail("A judge sharing the reflection model must be rejected")
            } catch let PromptExperimentAuthorityError.validation(fields) {
                XCTAssertEqual(fields.map(\.field), ["judge_target"])
            }
        }

        func testPromptLengthCeilingIsValidatedAndPartOfTheAuthority() async throws {
            let harness = try makeHarness()
            let defaults = try await create(harness.service)
            XCTAssertEqual(defaults.authority.settings.promptCharacterCeilingRatio, 1.0)
            XCTAssertNil(defaults.authority.settings.maxPromptCharacters)
            XCTAssertEqual(defaults.authority.settings.noiseFloorReplicates, 2)
            XCTAssertEqual(defaults.authority.calibrationEvaluations, 2, "two noise-floor passes over the one validation case")
            let custom = try await harness.service.createOrUpdate(PromptExperimentCreateRequest(
                promptID: "oracle-plan", maxEvaluations: 4, promptCharacterCeilingRatio: 0.8, maxPromptCharacters: 5000
            ))
            XCTAssertEqual(custom.authority.settings.promptCharacterCeilingRatio, 0.8)
            XCTAssertEqual(custom.authority.settings.maxPromptCharacters, 5000)
            XCTAssertNotEqual(custom.authorityDigest, defaults.authorityDigest, "the ceiling is approved authority")
            do {
                _ = try await harness.service.createOrUpdate(PromptExperimentCreateRequest(
                    promptID: "oracle-plan", maxEvaluations: 4, promptCharacterCeilingRatio: 9, maxPromptCharacters: 10,
                    noiseFloorReplicates: 9
                ))
                XCTFail("Out-of-range ceilings and replicate counts must be rejected")
            } catch let PromptExperimentAuthorityError.validation(fields) {
                XCTAssertEqual(Set(fields.map(\.field)), ["prompt_character_ceiling_ratio", "max_prompt_characters", "noise_floor_replicates"])
            }
            let noNoise = try await harness.service.createOrUpdate(PromptExperimentCreateRequest(
                promptID: "oracle-plan", maxEvaluations: 4, noiseFloorReplicates: 0
            ))
            XCTAssertEqual(noNoise.authority.calibrationEvaluations, 0)
        }

        func testChangingApprovedAuthorityCreatesANewExperiment() async throws {
            let harness = try makeHarness()
            let original = try await create(harness.service)
            try await approveAndRun(harness.service, original)
            await harness.service.waitForSettlementForTesting(experimentID: original.id)

            let changed = try await harness.service.createOrUpdate(PromptExperimentCreateRequest(experimentID: original.id, maxEvaluations: 6))
            XCTAssertNotEqual(changed.id, original.id)
            XCTAssertEqual(changed.supersedes, original.id)
            XCTAssertEqual(changed.status, .unapproved)
            let untouched = try XCTUnwrap(harness.service.experiment(id: original.id))
            XCTAssertEqual(untouched.authority.maxEvaluations, 4)
            XCTAssertTrue(untouched.isApproved)

            let same = try await harness.service.createOrUpdate(PromptExperimentCreateRequest(experimentID: original.id, title: "Renamed"))
            XCTAssertEqual(same.id, original.id, "a title is not authority")
            XCTAssertEqual(same.title, "Renamed")
        }

        func testUnapprovedUpdateReplacesAuthorityInPlaceAndWithdrawsTheRequest() async throws {
            let harness = try makeHarness()
            let experiment = try await create(harness.service)
            _ = try await harness.service.requestApproval(experimentID: experiment.id, expectedAuthorityDigest: nil)
            let updated = try await harness.service.createOrUpdate(PromptExperimentCreateRequest(experimentID: experiment.id, maxEvaluations: 8))
            XCTAssertEqual(updated.id, experiment.id)
            XCTAssertNotEqual(updated.authorityDigest, experiment.authorityDigest)
            XCTAssertNil(updated.approvalRequest, "a changed authority needs a fresh request")
            do {
                try await harness.service.approve(experimentID: experiment.id, authorityDigest: experiment.authorityDigest)
                XCTFail("The withdrawn request cannot be approved")
            } catch PromptExperimentAuthorityError.approvalNotRequested {}
        }

        // MARK: Runs and budget

        func testRunsCannotExceedTheCumulativeCap() async throws {
            let harness = try makeHarness()
            harness.runtime.nextResults = [FakeRuntime.result(.stoppedBudget, admissionsAfter: 3)]
            let experiment = try await create(harness.service)
            try await approveAndRun(harness.service, experiment)
            await harness.service.waitForSettlementForTesting(experimentID: experiment.id)
            XCTAssertEqual(harness.service.experiment(id: experiment.id)?.remainingEvaluations, 1)

            harness.runtime.nextResults = [FakeRuntime.result(.stoppedBudget, admissionsAfter: 4)]
            _ = try await harness.service.run(experimentID: experiment.id)
            await harness.service.waitForSettlementForTesting(experimentID: experiment.id)
            let resumed = try XCTUnwrap(harness.service.experiment(id: experiment.id))
            XCTAssertEqual(resumed.runs.map(\.admissionsBefore), [0, 3])
            XCTAssertEqual(resumed.runs.map(\.state), [.stoppedBudget, .stoppedBudget])
            XCTAssertEqual(resumed.runs.map(\.runDirectoryRelativePath).count, 2)
            XCTAssertEqual(Set(resumed.runs.map(\.runDirectoryRelativePath)).count, 1, "every run resumes the same GEPA directory")
            XCTAssertEqual(resumed.status, .budgetExhausted)
            do {
                _ = try await harness.service.run(experimentID: experiment.id)
                XCTFail("The approved cap is cumulative across runs")
            } catch PromptExperimentAuthorityError.budgetExhausted {}
            XCTAssertEqual(harness.runtime.submitted.count, 2)
        }

        func testOnlyOneRunIsActiveAcrossExperiments() async throws {
            let harness = try makeHarness()
            harness.runtime.holdRuns = true
            let first = try await create(harness.service)
            let second = try await create(harness.service)
            try await approveAndRun(harness.service, first)
            _ = try await harness.service.requestApproval(experimentID: second.id, expectedAuthorityDigest: nil)
            do {
                try await harness.service.approve(experimentID: second.id, authorityDigest: second.authorityDigest)
                XCTFail("A second concurrent run must be refused")
            } catch PromptExperimentAuthorityError.runActive {}
            XCTAssertTrue(try XCTUnwrap(harness.service.experiment(id: second.id)).isApproved, "approval stands; the run can start later")

            let cancelled = try await harness.service.cancel(experimentID: first.id)
            XCTAssertNotNil(cancelled.runs.last?.cancellationRequestedAt)
            await harness.service.waitForSettlementForTesting(experimentID: first.id)
            XCTAssertEqual(harness.service.experiment(id: first.id)?.runs.last?.state, .cancelled)
            XCTAssertEqual(harness.runtime.cancelled.count, 1)
        }

        func testCheckpointsAreDurableBeforeTheRuntimeContinues() async throws {
            let harness = try makeHarness()
            harness.runtime.holdRuns = true
            let evaluationID = UUID()
            harness.runtime.checkpointsOnSubmit = [
                .modelCall(.init(id: UUID(), target: PromptExperimentTestFixtures.execution, role: "execution", state: .started, promptTokens: nil, completionTokens: nil)),
                .evaluation(id: evaluationID, candidate: "candidate text", value: .init(
                    candidateIndex: -1, exampleID: "t1", split: .training, score: 1, feedback: "ok",
                    failureKind: nil, output: "good", elapsedSeconds: 0.1
                ))
            ]
            let experiment = try await create(harness.service)
            try await approveAndRun(harness.service, experiment)

            let reopened = try await PromptExperimentStore(rootURL: harness.root.appendingPathComponent("store")).load()
            let run = try XCTUnwrap(reopened.experiments.first?.runs.last)
            XCTAssertEqual(run.evaluations.map(\.id), [evaluationID])
            XCTAssertEqual(run.modelCalls.count, 1)
            XCTAssertEqual(run.state, .running)
            let runID = try XCTUnwrap(harness.runtime.heldRunIDs.first)
            harness.runtime.release(runID, FakeRuntime.result(.completed, admissionsAfter: 2))
            await harness.service.waitForSettlementForTesting(experimentID: experiment.id)
        }

        func testStatusOrWaitWakesOnAnApprovalChange() async throws {
            let harness = try makeHarness()
            let experiment = try await create(harness.service)
            let service = harness.service
            let waiter = Task { @MainActor in try await service.statusOrWait(experimentID: experiment.id, timeoutSeconds: 30) }
            try await Task.sleep(for: .milliseconds(50))
            _ = try await service.requestApproval(experimentID: experiment.id, expectedAuthorityDigest: nil)
            let observed = try await waiter.value
            XCTAssertEqual(observed.status, .awaitingApproval)
            let immediate = try await service.statusOrWait(experimentID: experiment.id, timeoutSeconds: 0)
            XCTAssertEqual(immediate.status, .awaitingApproval)
        }

        // MARK: Restart and store schema

        func testRestartSettlesARunningRunAsUncertainWithoutReplayingSpend() async throws {
            let harness = try makeHarness()
            harness.runtime.holdRuns = true
            harness.runtime.checkpointsOnSubmit = [
                .evaluation(id: UUID(), candidate: "c", value: .init(
                    candidateIndex: -1, exampleID: "t1", split: .training, score: 0, feedback: "no",
                    failureKind: nil, output: "bad", elapsedSeconds: nil
                ))
            ]
            let experiment = try await create(harness.service)
            try await approveAndRun(harness.service, experiment)

            let runtime = FakeRuntime(root: harness.root)
            let restarted = PromptExperimentTestFixtures.makeService(root: harness.root, registry: harness.registry, runtime: runtime)
            await restarted.load()
            let run = try XCTUnwrap(restarted.experiment(id: experiment.id)?.runs.last)
            XCTAssertEqual(run.state, .failed)
            XCTAssertTrue(run.uncertainRemoteSettlement)
            XCTAssertEqual(run.evaluations.count, 1, "scored evidence survives the restart")
            XCTAssertEqual(run.diagnostics?.processObservation, .unknownAfterRestart)
            XCTAssertTrue(runtime.submitted.isEmpty, "a restart never resumes spending on its own")
            XCTAssertEqual(restarted.experiment(id: experiment.id)?.status, .failed)

            _ = try await restarted.run(experimentID: experiment.id)
            XCTAssertEqual(runtime.submitted.count, 1, "an explicit run resumes")
            let holder = try XCTUnwrap(harness.runtime.heldRunIDs.first)
            harness.runtime.release(holder, FakeRuntime.result(.cancelled, admissionsAfter: nil))
            await restarted.waitForSettlementForTesting(experimentID: experiment.id)
        }

        func testEarlierLabSchemaIsDiscardedAndNewerSchemaIsLeftUntouched() async throws {
            let root = try makeRoot()
            let storeRoot = root.appendingPathComponent("store", isDirectory: true)
            try FileManager.default.createDirectory(at: storeRoot.appendingPathComponent("records/old"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: storeRoot.appendingPathComponent("worker-runs/old"), withIntermediateDirectories: true)
            try Data(#"{"schemaVersion":1,"records":[{"id":"legacy"}]}"#.utf8).write(to: storeRoot.appendingPathComponent("experiments.json"))

            let loaded = try await PromptExperimentStore(rootURL: storeRoot).load()
            XCTAssertTrue(loaded.discardedLegacyLabData)
            XCTAssertTrue(loaded.experiments.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.appendingPathComponent("records").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.appendingPathComponent("worker-runs").path))
            let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: storeRoot.appendingPathComponent("experiments.json"))) as? [String: Any]
            XCTAssertEqual(rewritten?["schemaVersion"] as? Int, PromptExperimentDocument.schemaVersion)
            let again = try await PromptExperimentStore(rootURL: storeRoot).load()
            XCTAssertFalse(again.discardedLegacyLabData, "discarding is one-time and deterministic")

            let future = Data(#"{"schemaVersion":99,"experiments":[]}"#.utf8)
            try future.write(to: storeRoot.appendingPathComponent("experiments.json"))
            do {
                _ = try await PromptExperimentStore(rootURL: storeRoot).load()
                XCTFail("A newer schema must not be discarded")
            } catch PromptExperimentStore.StoreError.unsupportedSchema(99) {}
            XCTAssertEqual(try Data(contentsOf: storeRoot.appendingPathComponent("experiments.json")), future)
        }

        func testProposalRejectAndApplyPreserveEvidenceAndWriteOnlyAfterReview() async throws {
            let root = try makeRoot()
            let registry = try PromptExperimentTestFixtures.makeRegistry(root: root)
            let sourceDirectory = root.appendingPathComponent("AppResources/Prompts/oracle-plan", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            let source = sourceDirectory.appendingPathComponent("prompt.md")
            try Data("seed prompt\n".utf8).write(to: source)
            let runtime = FakeRuntime(root: root)
            runtime.nextResults = [PromptExperimentRuntimeResult(
                disposition: .completed,
                optimization: PromptExperimentOptimizationRuntimeResult(
                    engine: "gepa", upstreamRevision: PromptExperimentGEPAConfiguration.pinnedRevision,
                    baselineScore: 0.2, bestScore: 0.8, bestCandidateIndex: 1,
                    candidates: ["seed prompt", "winner prompt"], parentIndices: [[], [0]],
                    aggregateScores: [0.2, 0.8], evaluations: [], totalEvaluations: 4,
                    wallTimeSeconds: 1, proposerUsage: "test", rawResultJSON: Data("{}".utf8), stopReason: "completed"
                ), admissionsAfter: 4, interruptedAdmissionsSettled: 0
            )]
            let service = PromptExperimentTestFixtures.makeService(root: root, registry: registry, runtime: runtime, patchSourceRoot: root)
            let experiment = try await service.createOrUpdate(PromptExperimentCreateRequest(promptID: "oracle-plan", maxEvaluations: 4))
            _ = try await service.requestApproval(experimentID: experiment.id, expectedAuthorityDigest: experiment.authorityDigest)
            try await service.approve(experimentID: experiment.id, authorityDigest: experiment.authorityDigest)
            await service.waitForSettlementForTesting(experimentID: experiment.id)
            let run = try XCTUnwrap(service.experiment(id: experiment.id)?.runs.last)
            XCTAssertEqual(run.state, .completed)

            let rejected = try await service.proposePatch(experimentID: experiment.id, runID: run.id, candidateIndex: 1)
            XCTAssertNotNil(rejected.diffEvidence)
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "seed prompt\n")
            try await service.rejectProposal(experimentID: experiment.id, proposalID: rejected.id)
            XCTAssertEqual(service.experiment(id: experiment.id)?.proposals.first?.state, .rejected)
            XCTAssertNotNil(service.experiment(id: experiment.id)?.runs.last?.result)

            let accepted = try await service.proposePatch(experimentID: experiment.id, runID: run.id, candidateIndex: 1)
            try await service.applyProposal(experimentID: experiment.id, proposalID: accepted.id)
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "winner prompt\n")
            XCTAssertEqual(service.experiment(id: experiment.id)?.proposals.last?.state, .applied)
            XCTAssertNotNil(service.experiment(id: experiment.id)?.runs.last?.result)
        }

        func testRunIsRefusedWhenTheBaselineChangedAfterApproval() async throws {
            let harness = try makeHarness()
            let experiment = try await create(harness.service)
            _ = try await harness.service.requestApproval(experimentID: experiment.id, expectedAuthorityDigest: nil)
            let promptURL = harness.root.appendingPathComponent("prompts/oracle-plan/prompt.md")
            try Data("edited baseline\n".utf8).write(to: promptURL)
            let fresh = FakeRuntime(root: harness.root)
            let reloaded = PromptExperimentTestFixtures.makeService(
                root: harness.root,
                registry: BuiltInPromptRegistry(promptsDirectory: harness.root.appendingPathComponent("prompts")),
                runtime: fresh
            )
            do {
                try await reloaded.approve(experimentID: experiment.id, authorityDigest: experiment.authorityDigest)
                XCTFail("A drifted baseline cannot run")
            } catch PromptExperimentAuthorityError.runtimeUnavailable {}
            XCTAssertTrue(fresh.submitted.isEmpty)
        }
    }
#endif

#if DEBUG
    @MainActor
    final class PromptLabPreparationApprovalTests: XCTestCase {
        private var roots: [URL] = []

        private final class CountingCompleter: PromptExperimentModelCompleting {
            var calls = 0

            func complete(
                target _: PromptExperimentResolvedTarget,
                systemPrompt _: String,
                userPrompt _: String,
                callbackRoot _: URL
            ) async throws -> PromptExperimentConnectedModelCompletion {
                calls += 1
                throw PromptExperimentAuthorityError.invalidRequest("Unexpected preparation call")
            }
        }

        override func tearDown() async throws {
            for root in roots {
                try? FileManager.default.removeItem(at: root)
            }
            roots = []
            try await super.tearDown()
        }

        private func service() throws -> PromptExperimentService {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            roots.append(root)
            let registry = try PromptExperimentTestFixtures.makeRegistry(root: root)
            return PromptExperimentTestFixtures.makeService(root: root, registry: registry, runtime: FakeRuntime(root: root))
        }

        private func filePayload(path: String = "/missing/rpce-preparation-prompt.md") -> PromptLabPreparationPayload {
            .file(.init(
                path: path, selection: nil, sourceTitle: "Blog prompt", goal: "Make useful, concise posts.",
                exampleInputs: "Explain gardening", criteria: "Uses the supplied facts", target: PromptExperimentTestFixtures.reflection
            ))
        }

        private func definition() -> PromptLabDefinition {
            PromptLabDefinition(
                source: .init(kind: .pasted, title: "Blog prompt", prompt: "Use the supplied facts."),
                goal: "Make useful posts.", examples: [], criteria: "Uses the supplied facts"
            )
        }

        func testSubmittingFileAndProgramRequestsDoesNotReadOrExecute() throws {
            var calls = 0
            let approvals = PromptLabPreparationApprovals { _, _ in
                calls += 1
                return self.definition()
            }
            let file = try approvals.submit(filePayload())
            let program = try approvals.submit(.program(.init(
                pythonExecutable: "/missing/python", projectRoot: "/missing/project", modulePath: "evaluate.py"
            ), .dspy))
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(file.status, .awaitingApproval)
            XCTAssertEqual(program.status, .awaitingApproval)
            XCTAssertNil(file.definition)
            XCTAssertNil(program.definition)
            XCTAssertNil(file.error)
        }

        func testNativeApprovalExecutesExactlyOnceAndPreservesSubmittedArguments() async throws {
            let service = try service()
            var calls: [PromptLabPreparationPayload] = []
            let approvals = PromptLabPreparationApprovals { payload, _ in
                calls.append(payload)
                return self.definition()
            }
            var program = PromptLabProgram(pythonExecutable: "/missing/python", projectRoot: "/missing/project", modulePath: "original.py")
            let requested = PromptLabPreparationPayload.program(program, .program)
            let request = try approvals.submit(requested)
            program.modulePath = "changed.py"
            try await approvals.approve(requestID: request.id, service: service)
            XCTAssertEqual(calls, [requested])
            XCTAssertEqual(approvals.request(id: request.id)?.status, .completed)
            XCTAssertNotNil(approvals.request(id: request.id)?.definition)
            do {
                try await approvals.approve(requestID: request.id, service: service)
                XCTFail("Settled approval cannot be replayed")
            } catch PromptExperimentAuthorityError.invalidRequest {}
            XCTAssertEqual(calls.count, 1)
            let changed = try approvals.submit(.program(program, .program))
            XCTAssertNotEqual(request.id, changed.id)
            XCTAssertEqual(changed.status, .awaitingApproval)
        }

        func testRejectedAndCancelledRequestsNeverExecute() async throws {
            let service = try service()
            var calls = 0
            let approvals = PromptLabPreparationApprovals { _, _ in
                calls += 1
                return self.definition()
            }
            let rejected = try approvals.submit(filePayload())
            try approvals.reject(requestID: rejected.id)
            let cancelled = try approvals.submit(filePayload())
            try approvals.cancel(requestID: cancelled.id)
            for request in [rejected, cancelled] {
                do {
                    try await approvals.approve(requestID: request.id, service: service)
                    XCTFail("Rejected or cancelled requests cannot execute")
                } catch PromptExperimentAuthorityError.invalidRequest {}
                XCTAssertNil(approvals.request(id: request.id)?.definition)
            }
            XCTAssertEqual(calls, 0)
        }

        func testCancellationDiscardsAResultEvenWhenExecutorReturnsLate() async throws {
            let service = try service()
            let started = expectation(description: "executor started")
            var finish: CheckedContinuation<Void, Never>?
            let approvals = PromptLabPreparationApprovals { _, _ in
                await withCheckedContinuation { continuation in
                    finish = continuation
                    started.fulfill()
                }
                return self.definition()
            }
            let request = try approvals.submit(filePayload())
            let approval = Task { try await approvals.approve(requestID: request.id, service: service) }
            await fulfillment(of: [started], timeout: 2)
            try approvals.cancel(requestID: request.id)
            finish?.resume()
            try await approval.value
            XCTAssertEqual(approvals.request(id: request.id)?.status, .cancelled)
            XCTAssertNil(approvals.request(id: request.id)?.definition)
        }

        func testProductionFileAccessOccursOnlyAfterApprovalAndFailureCannotBeReplayed() async throws {
            let service = try service()
            let approvals = PromptLabPreparationApprovals()
            let request = try approvals.submit(filePayload(path: "/missing/\(UUID().uuidString)/prompt.md"))
            XCTAssertEqual(request.status, .awaitingApproval)
            try await approvals.approve(requestID: request.id, service: service)
            XCTAssertEqual(approvals.request(id: request.id)?.status, .failed)
            XCTAssertNotNil(approvals.request(id: request.id)?.error)
            XCTAssertNil(approvals.request(id: request.id)?.definition)
            do {
                try await approvals.approve(requestID: request.id, service: service)
                XCTFail("Failed preparations require fresh consent")
            } catch PromptExperimentAuthorityError.invalidRequest {}
        }

        func testChangedPreparationModelFailsBeforeSendingSourceToProvider() async throws {
            let service = try service()
            let completer = CountingCompleter()
            let reviewed = PromptExperimentResolvedTarget(role: "design", agentRaw: "reviewed-provider", modelRaw: "reviewed-model", displayName: "Reviewed model")
            do {
                _ = try await service.prepareDefinition(
                    source: .init(kind: .pasted, title: "Private prompt", prompt: "Use the supplied facts."),
                    goal: "Improve quality", exampleInputs: "", criteria: "", targetSelector: "design",
                    expectedTarget: reviewed, completer: completer
                )
                XCTFail("A changed target requires new native review")
            } catch PromptExperimentAuthorityError.invalidRequest {}
            XCTAssertEqual(completer.calls, 0)
        }

        func testCancelledExecutionsRemainWithinPendingLimitUntilTheySettle() async throws {
            let service = try service()
            var finishes: [CheckedContinuation<Void, Never>] = []
            let started = expectation(description: "all executions started")
            started.expectedFulfillmentCount = 20
            let approvals = PromptLabPreparationApprovals { _, _ in
                await withCheckedContinuation { continuation in
                    finishes.append(continuation)
                    started.fulfill()
                }
                return self.definition()
            }
            var tasks: [Task<Void, Error>] = []
            for _ in 0 ..< 20 {
                let request = try approvals.submit(filePayload())
                tasks.append(Task { try await approvals.approve(requestID: request.id, service: service) })
            }
            await fulfillment(of: [started], timeout: 2)
            for request in approvals.requests {
                try approvals.cancel(requestID: request.id)
            }
            XCTAssertThrowsError(try approvals.submit(filePayload()), "Cancelling a slow process cannot free its active admission before settlement")
            for finish in finishes {
                finish.resume()
            }
            for task in tasks {
                try await task.value
            }
            XCTAssertTrue(approvals.requests.allSatisfy { $0.status == .cancelled && $0.definition == nil })
            XCTAssertNoThrow(try approvals.submit(filePayload()))
        }

        func testWaitReturnsTerminalStateAndCancellationDoesNotApprove() async throws {
            let approvals = PromptLabPreparationApprovals()
            let request = try approvals.submit(filePayload())
            let waiter = Task { try await approvals.statusOrWait(id: request.id, timeoutSeconds: 60) }
            await Task.yield()
            try approvals.reject(requestID: request.id)
            let rejected = try await waiter.value
            XCTAssertEqual(rejected.status, .rejected)
            let settled = try await approvals.statusOrWait(id: request.id, timeoutSeconds: 3600)
            XCTAssertEqual(settled.status, .rejected)
            let pending = try approvals.submit(filePayload())
            let cancelledWaiter = Task { try await approvals.statusOrWait(id: pending.id, timeoutSeconds: 60) }
            cancelledWaiter.cancel()
            do {
                _ = try await cancelledWaiter.value
                XCTFail("Waiting must respect cancellation")
            } catch is CancellationError {}
            XCTAssertEqual(approvals.request(id: pending.id)?.status, .awaitingApproval)
            let timedOut = try await approvals.statusOrWait(id: pending.id, timeoutSeconds: 0.01)
            XCTAssertEqual(timedOut.status, .awaitingApproval)
        }

        func testPendingAndHistoryQueuesAreBounded() throws {
            let approvals = PromptLabPreparationApprovals()
            for _ in 0 ..< 20 {
                try approvals.submit(filePayload())
            }
            XCTAssertThrowsError(try approvals.submit(filePayload()))
            for request in approvals.requests {
                try approvals.reject(requestID: request.id)
            }
            for _ in 0 ..< 60 {
                let request = try approvals.submit(filePayload())
                try approvals.reject(requestID: request.id)
            }
            XCTAssertEqual(approvals.requests.count, 50)
            XCTAssertThrowsError(try approvals.submit(filePayload(path: "relative.md")))
        }
    }
#endif

#if DEBUG
    @MainActor
    final class PromptLabDefinitionTests: XCTestCase {
        private var roots: [URL] = []

        override func tearDown() async throws {
            for root in roots {
                try? FileManager.default.removeItem(at: root)
            }
            roots = []
            try await super.tearDown()
        }

        private func makeRoot() throws -> URL {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            roots.append(root)
            return root
        }

        private func definition() -> PromptLabDefinition {
            PromptLabDefinition(
                source: .init(kind: .pasted, title: "Blog writer", prompt: "Write for {{audience}}. Use the supplied facts."),
                goal: "Reduce input and output tokens while retaining useful, factual posts.",
                objective: .init(mode: .efficiency),
                examples: PromptSuiteSplit.allCases.enumerated().map { index, split in
                    PromptSuiteCase(
                        id: "blog_\(index)",
                        split: split,
                        input: "Explain topic \(index)",
                        expectedOutput: nil,
                        variables: ["audience": "new readers"]
                    )
                },
                criteria: "Uses only supplied facts.\nAnswers the requested topic.\nKeeps a clear structure."
            )
        }

        func testProjectExperimentResolvesWithoutBuiltInPromptAndPreservesGoal() async throws {
            let root = try makeRoot()
            let registry = try PromptExperimentTestFixtures.makeRegistry(root: root)
            let service = PromptExperimentTestFixtures.makeService(root: root, registry: registry, runtime: FakeRuntime(root: root))
            let draft = definition()
            let experiment = try await service.createOrUpdate(.init(maxEvaluations: 20, definition: draft))
            XCTAssertNil(experiment.authority.promptID)
            XCTAssertEqual(experiment.authority.definition, draft)
            XCTAssertNotNil(experiment.authority.maxProviderInvocations)
            let execution = try GEPARunController.resolveExecution(experiment, registry: registry)
            XCTAssertEqual(execution.baseline, draft.source.prompt)
            let request = GEPARunController.makeWorkerRequest(execution: execution, runRoot: root, searchRemaining: 19)
            XCTAssertEqual(request.objective, draft.goal)
            XCTAssertNil(request.promptCharacterCeilingRatio, "Generic optimization must not silently require a shorter prompt.")
            XCTAssertEqual(request.examples.count, 2)
            XCTAssertEqual(request.heldOutExamples.count, 1)
            let restored = PromptExperimentTestFixtures.makeService(root: root, registry: registry, runtime: FakeRuntime(root: root))
            await restored.load()
            XCTAssertEqual(restored.experiment(id: experiment.id)?.authority, experiment.authority)
        }

        func testExplicitOneTimesPromptLimitIsSealedAndSurvivesResolution() async throws {
            let root = try makeRoot()
            let registry = try PromptExperimentTestFixtures.makeRegistry(root: root)
            let service = PromptExperimentTestFixtures.makeService(root: root, registry: registry, runtime: FakeRuntime(root: root))
            let experiment = try await service.createOrUpdate(.init(
                maxEvaluations: 20, promptCharacterCeilingRatio: 1, definition: definition()
            ))
            let execution = try GEPARunController.resolveExecution(experiment, registry: registry)
            let request = GEPARunController.makeWorkerRequest(execution: execution, runRoot: root, searchRemaining: 19)
            XCTAssertEqual(request.promptCharacterCeilingRatio, 1)
            XCTAssertEqual(experiment.authority.definition?.relativePromptLimit, 1)
            XCTAssertEqual(experiment.authority.suiteSHA256, try experiment.authority.definition?.makeSuite().suiteSHA256)
        }

        func testChangingGoalChangesExperimentAuthority() async throws {
            let root = try makeRoot()
            let registry = try PromptExperimentTestFixtures.makeRegistry(root: root)
            let service = PromptExperimentTestFixtures.makeService(root: root, registry: registry, runtime: FakeRuntime(root: root))
            var draft = definition()
            let before = try await service.createOrUpdate(.init(maxEvaluations: 20, definition: draft))
            draft.goal = "Improve coverage of difficult topics."
            let after = try await service.createOrUpdate(.init(experimentID: before.id, maxEvaluations: 20, definition: draft))
            XCTAssertNotEqual(before.authorityDigest, after.authorityDigest)
            XCTAssertNotEqual(before.authority.suiteSHA256, after.authority.suiteSHA256)
        }

        func testFileSnapshotCanResumeAfterSourceChangesButCannotOverwriteIt() async throws {
            let root = try makeRoot()
            let file = root.appendingPathComponent("blog-prompt.md")
            try Data("Write a useful post.".utf8).write(to: file)
            var draft = definition()
            draft.source = try .importFile(url: file)
            let registry = try PromptExperimentTestFixtures.makeRegistry(root: root)
            let service = PromptExperimentTestFixtures.makeService(root: root, registry: registry, runtime: FakeRuntime(root: root))
            let experiment = try await service.createOrUpdate(.init(maxEvaluations: 20, definition: draft))
            try Data("User edited this after the run began.".utf8).write(to: file)
            let execution = try GEPARunController.resolveExecution(experiment, registry: registry)
            XCTAssertEqual(execution.baseline, "Write a useful post.")
            XCTAssertThrowsError(try PromptPatchProposer().apply(source: draft.source, candidate: Data("Improved prompt".utf8)))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "User edited this after the run began.")
        }

        func testMissingTemplateValueFailsBeforeAnyRun() {
            var draft = definition()
            draft.source.prompt = "Write for {{audience}} in ${language}."
            XCTAssertThrowsError(try draft.validated()) { error in
                XCTAssertTrue(error.localizedDescription.contains("language"))
            }
            XCTAssertEqual(PromptLabTemplate.variables(in: "{{audience}} ${language} {audience}"), ["audience", "language"])
        }

        func testTemplateValuesAreLiteralAndNotRecursivelyExpanded() throws {
            let rendered = try PromptLabTemplate.render(
                "Hello {{name}} / ${topic} / {name}",
                variables: ["name": "$1\\quoted{{topic}}", "topic": "Swift"]
            )
            XCTAssertEqual(rendered, "Hello $1\\quoted{{topic}} / Swift / $1\\quoted{{topic}}")
        }

        func testDatasetPreservesNestedProgramFieldsAndLegacyReference() throws {
            let data = Data(#"{"id":"a","split":"training","input":"write","expected_output":"reference","payload":{"inputs":{"facts":["a","b"],"verified":true},"threshold":0.8,"missing":null}}"#.utf8)
            let example = try JSONDecoder().decode(PromptSuiteCase.self, from: data)
            XCTAssertEqual(example.expectedOutput, "reference")
            XCTAssertEqual(example.variables, [:])
            XCTAssertEqual(example.payload?["inputs"], .object(["facts": .array([.string("a"), .string("b")]), "verified": .boolean(true)]))
            XCTAssertEqual(example, try JSONDecoder().decode(PromptSuiteCase.self, from: JSONEncoder().encode(example)))
        }

        func testProgramSealDetectsChangedImportedHelperAndDependencyDeclaration() throws {
            let root = try makeRoot()
            let module = root.appendingPathComponent("evaluate.py")
            let helper = root.appendingPathComponent("quality.py")
            let requirements = root.appendingPathComponent("requirements.txt")
            try Data("from quality import score\n".utf8).write(to: module)
            try Data("def score(value): return 1\n".utf8).write(to: helper)
            try Data("dspy==3.4.1\n".utf8).write(to: requirements)
            let configuration = PromptLabProgram(pythonExecutable: "/usr/bin/true", projectRoot: root.path, modulePath: module.path)
            let sealed = try configuration.sealed()
            XCTAssertEqual(Set(sealed.dependencySHA256?.keys.map(\.self) ?? []), ["evaluate.py", "quality.py", "requirements.txt"])
            XCTAssertNoThrow(try sealed.sealed())
            try Data("def score(value): return 0\n".utf8).write(to: helper)
            XCTAssertThrowsError(try sealed.sealed())
            let resealed = try configuration.sealed()
            try Data("dspy==3.4.2\n".utf8).write(to: requirements)
            XCTAssertThrowsError(try resealed.sealed())
        }

        func testAllSplitsAndFiniteObjectiveAreRequired() {
            var draft = definition()
            draft.examples.removeAll { $0.split == .hiddenTest }
            XCTAssertThrowsError(try draft.validated())
            draft = definition()
            draft.objective.inputWeight = .infinity
            XCTAssertThrowsError(try draft.validated())
            draft.objective.inputWeight = 0
            draft.objective.outputWeight = 0
            XCTAssertThrowsError(try draft.validated())
        }
    }
#endif
