import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class GEPARunControllerTests: XCTestCase {
        // MARK: Fixtures

        static let executionTarget = PromptExperimentTestFixtures.execution
        static let reflectionTarget = PromptExperimentTestFixtures.reflection

        private final class Recorder<Value>: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [Value] = []
            func append(_ value: Value) {
                lock.lock()
                storage.append(value)
                lock.unlock()
            }

            var values: [Value] {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
        }

        /// Scripted model: `handler` decides each completion; calls are recorded.
        private final class FakeCompleter: PromptExperimentModelCompleting {
            var handler: (PromptExperimentResolvedTarget, String, String) async throws -> String = { _, _, _ in "good" }
            private(set) var calls: [(target: PromptExperimentResolvedTarget, user: String)] = []

            func complete(
                target: PromptExperimentResolvedTarget,
                systemPrompt: String,
                userPrompt: String,
                callbackRoot _: URL
            ) async throws -> PromptExperimentConnectedModelCompletion {
                calls.append((target, userPrompt))
                return try await PromptExperimentConnectedModelCompletion(
                    output: handler(target, systemPrompt, userPrompt), promptTokens: 3, completionTokens: 2
                )
            }

            var executionCalls: Int {
                calls.count(where: { $0.target == GEPARunControllerTests.executionTarget })
            }
        }

        /// Model calls that block until released or cancelled, keyed by the user prompt.
        private final class BlockingCompleter: PromptExperimentModelCompleting {
            private var waiting: [String: CheckedContinuation<PromptExperimentConnectedModelCompletion, Error>] = [:]
            private(set) var cancelledInputs: [String] = []

            var waitingCount: Int {
                waiting.count
            }

            func complete(
                target _: PromptExperimentResolvedTarget,
                systemPrompt _: String,
                userPrompt: String,
                callbackRoot _: URL
            ) async throws -> PromptExperimentConnectedModelCompletion {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        waiting[userPrompt] = continuation
                    }
                } onCancel: {
                    Task { @MainActor in self.cancel(userPrompt) }
                }
            }

            private func cancel(_ key: String) {
                guard let continuation = waiting.removeValue(forKey: key) else { return }
                cancelledInputs.append(key)
                continuation.resume(throwing: CancellationError())
            }

            func release(_ key: String, output: String) {
                waiting.removeValue(forKey: key)?.resume(returning: .init(output: output, promptTokens: nil, completionTokens: nil))
            }
        }

        typealias Script = (_ host: GEPAWorkerHostHandler, _ event: GEPAWorkerEventHandler) async throws -> GEPAWorkerProtocol.Terminal

        /// Stands in for the Python process: drives host callbacks and events like GEPA would.
        private final class FakeWorker: GEPAWorkerRunning {
            let script: Script
            private(set) var cancelled = false
            private(set) var request: GEPAWorkerProtocol.RunRequest?

            init(script: @escaping Script) {
                self.script = script
            }

            func run(
                request: GEPAWorkerProtocol.RunRequest,
                pythonSealValue _: String,
                layout _: GEPAWorkerLayout,
                host: @escaping GEPAWorkerHostHandler,
                event: @escaping GEPAWorkerEventHandler,
                observation _: @escaping @MainActor @Sendable (PromptExperimentRuntimeObservation) async -> Void
            ) async throws -> GEPAWorkerCompletion {
                self.request = request
                let terminal = try await script(host, event)
                return try GEPAWorkerCompletion(terminal: terminal, rawResultJSON: JSONEncoder().encode(terminal))
            }

            func cancel() {
                cancelled = true
            }
        }

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

        /// The target's user prompt for a context-free case: the production `<user_instructions>` wrap.
        static func packaged(_ input: String) -> String {
            "<user_instructions>\n\(input)\n</user_instructions>"
        }

        static func sha(_ text: String) -> String {
            PromptExperimentDigest.sha256(Data(text.utf8))
        }

        private func makeExperiment(
            cases: [PromptExperimentTestFixtures.SuiteCase] = PromptExperimentTestFixtures.defaultCases,
            maxEvaluations: Int = 4,
            maxProviderRetries: Int = 0
        ) throws -> (experiment: PromptExperiment, registry: BuiltInPromptRegistry) {
            let registry = try PromptExperimentTestFixtures.makeRegistry(root: makeRoot(), cases: cases)
            return try (
                PromptExperimentTestFixtures.makeExperiment(registry: registry, maxEvaluations: maxEvaluations, maxProviderRetries: maxProviderRetries),
                registry
            )
        }

        private func makeController(
            root: URL,
            registry: BuiltInPromptRegistry,
            completer: PromptExperimentModelCompleting,
            workers: [FakeWorker],
            sleeps: Recorder<Double> = Recorder()
        ) -> GEPARunController {
            var queue = workers
            return GEPARunController(environment: .init(
                storeRoot: root,
                registry: registry,
                makeWorker: { queue.removeFirst() },
                preflightWorker: { _ in },
                completer: completer,
                backoffSleep: { sleeps.append($0) },
                jitter: { 0.5 }
            ))
        }

        private func submit(
            _ controller: GEPARunController,
            experiment: PromptExperiment,
            checkpoints: Recorder<PromptExperimentCheckpoint> = Recorder()
        ) async throws -> PromptExperimentRuntimeHandle {
            try await controller.submit(
                PromptExperimentRunRequest(experiment: experiment, runID: UUID()),
                progress: { _ in },
                observation: { _ in },
                checkpoint: { checkpoints.append($0) }
            )
        }

        static func evaluate(_ candidate: String, _ exampleID: String, _ split: PromptExperimentDatasetSplit = .training) -> GEPAWorkerProtocol.HostRequest {
            .evaluate(.init(candidate: candidate, candidateSHA256: sha(candidate), exampleID: exampleID, split: split.rawValue))
        }

        static func register(_ event: GEPAWorkerEventHandler, _ index: Int, _ text: String, parents: [Int] = [], score: Double? = nil) async throws {
            try await event(.candidate(.init(
                eventID: "candidate:\(index)", candidateIndex: index, candidateSHA256: sha(text),
                candidate: text, parentIndices: parents, aggregateScore: score
            )))
        }

        static func terminal(
            _ candidates: [(text: String, parents: [Int], score: Double?)],
            best: Int?,
            stopReason: String = "completed",
            hasIncumbent: Bool = true,
            heldOut: GEPAWorkerProtocol.HeldOut? = nil
        ) -> GEPAWorkerProtocol.Terminal {
            GEPAWorkerProtocol.Terminal(
                engine: "gepa",
                upstreamRevision: PromptExperimentGEPAConfiguration.pinnedRevision,
                stopReason: stopReason,
                hasIncumbent: hasIncumbent,
                candidates: candidates.enumerated().map { index, candidate in
                    .init(index: index, sha256: sha(candidate.text), parentIndices: candidate.parents, aggregateScore: candidate.score)
                },
                bestCandidateIndex: best,
                bestScore: best.flatMap { candidates[$0].score },
                baselineScore: candidates.first?.score,
                totalMetricCalls: nil,
                wallTimeSeconds: 1,
                heldOut: heldOut,
                proposerUsage: "reflection_calls=0"
            )
        }

        private func ledger(root: URL, experiment: PromptExperiment) throws -> PromptExperimentBudgetLedger.Document {
            let url = root
                .appendingPathComponent(GEPARunController.runDirectoryRelativePath(experimentID: experiment.id, authorityDigest: experiment.authorityDigest))
                .appendingPathComponent(PromptExperimentBudgetLedger.fileName)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(PromptExperimentBudgetLedger.Document.self, from: Data(contentsOf: url))
        }

        // MARK: Budget

        func testLedgerCeilingIsATypedBudgetStopThatReturnsTheIncumbent() async throws {
            let root = try makeRoot()
            let (experiment, registry) = try makeExperiment(maxEvaluations: 4)
            let completer = FakeCompleter()
            let replies = Recorder<GEPAWorkerProtocol.HostReply>()
            let worker = FakeWorker { host, event in
                try await Self.register(event, 0, "seed prompt", score: 1)
                var index = 0
                while true {
                    let reply = await host(Self.evaluate("candidate \(index)", "t1"))
                    replies.append(reply)
                    if reply == .budgetExhausted { break }
                    guard case .evaluated = reply else { throw CancellationError() }
                    index += 1
                }
                return Self.terminal([("seed prompt", [], 1)], best: 0, stopReason: "budget_exhausted")
            }
            let controller = makeController(root: root, registry: registry, completer: completer, workers: [worker])
            let checkpoints = Recorder<PromptExperimentCheckpoint>()
            let handle = try await submit(controller, experiment: experiment, checkpoints: checkpoints)
            let result = await controller.wait(for: handle)

            XCTAssertEqual(result.disposition, .stoppedBudget)
            XCTAssertEqual(replies.values.count(where: { if case .evaluated = $0 { true } else { false } }), 4)
            XCTAssertEqual(replies.values.last, .budgetExhausted)
            XCTAssertEqual(completer.executionCalls, 4, "the ceiling refuses before any spend")
            let optimization = try XCTUnwrap(result.optimization)
            XCTAssertEqual(optimization.stopReason, "budget_exhausted")
            XCTAssertEqual(optimization.bestCandidateIndex, 0)
            XCTAssertEqual(optimization.candidates, ["seed prompt"])
            XCTAssertEqual(optimization.totalEvaluations, 4)
            XCTAssertEqual(optimization.evaluations.count, 4)
            XCTAssertEqual(checkpoints.values.count(where: { if case .evaluation = $0 { true } else { false } }), 4)
            XCTAssertEqual(try ledger(root: root, experiment: experiment).entries.count, 4)
        }

        func testHeldOutAveragesSurviveIntoTheRuntimeResultAndAssessment() async throws {
            let root = try makeRoot()
            let (experiment, registry) = try makeExperiment()
            let worker = FakeWorker { _, event in
                try await Self.register(event, 0, "seed prompt", score: 0.5)
                try await Self.register(event, 1, "better prompt", parents: [0], score: 0.8)
                return Self.terminal(
                    [("seed prompt", [], 0.5), ("better prompt", [0], 0.8)],
                    best: 1,
                    heldOut: .init(baseline: nil, best: .init(scores: ["h1": 0.75], average: 0.75))
                )
            }
            let controller = makeController(root: root, registry: registry, completer: FakeCompleter(), workers: [worker])
            let result = try await controller.wait(for: submit(controller, experiment: experiment))
            XCTAssertEqual(result.disposition, .completed)
            let heldOut = try XCTUnwrap(result.optimization?.heldOut)
            XCTAssertEqual(heldOut, PromptExperimentHeldOutSummary(baselineAverage: nil, bestAverage: 0.75))
            XCTAssertEqual(heldOut.summary, "Held-out average: baseline unavailable \u{2192} best 0.750.")
        }

        func testBudgetStopWithoutIncumbentIsInconclusiveNotAWinner() async throws {
            let root = try makeRoot()
            let (experiment, registry) = try makeExperiment()
            let worker = FakeWorker { _, _ in
                Self.terminal([], best: nil, stopReason: "budget_exhausted", hasIncumbent: false)
            }
            let controller = makeController(root: root, registry: registry, completer: FakeCompleter(), workers: [worker])
            let result = try await controller.wait(for: submit(controller, experiment: experiment))
            guard case let .failed(message) = result.disposition else { return XCTFail("Expected an inconclusive failure") }
            XCTAssertTrue(message.contains("no winner"))
            XCTAssertNil(result.optimization)
        }

        func testDuplicateLogicalEvaluationReplaysWithoutSpendAndResumeKeepsTheCumulativeCap() async throws {
            let root = try makeRoot()
            let (experiment, registry) = try makeExperiment(maxEvaluations: 4)
            let completer = FakeCompleter()
            let first = FakeWorker { host, event in
                try await Self.register(event, 0, "seed prompt")
                for request in [Self.evaluate("c0", "t1"), Self.evaluate("c0", "t1"), Self.evaluate("c0", "v1", .validation), Self.evaluate("c1", "t1"), Self.evaluate("c1", "v1", .validation)] {
                    _ = await host(request)
                }
                let exhausted = await host(Self.evaluate("c2", "t1"))
                XCTAssertEqual(exhausted, .budgetExhausted)
                return Self.terminal([("seed prompt", [], nil)], best: 0, stopReason: "budget_exhausted")
            }
            let replays = Recorder<Bool>()
            let second = FakeWorker { host, event in
                try await Self.register(event, 0, "seed prompt")
                if case let .evaluated(reply) = await host(Self.evaluate("c0", "t1")) { replays.append(reply.replayed) }
                let exhausted = await host(Self.evaluate("c3", "t1"))
                XCTAssertEqual(exhausted, .budgetExhausted)
                return Self.terminal([("seed prompt", [], nil)], best: 0, stopReason: "budget_exhausted")
            }
            let controller = makeController(root: root, registry: registry, completer: completer, workers: [first, second])
            let firstResult = try await controller.wait(for: submit(controller, experiment: experiment))
            XCTAssertEqual(firstResult.optimization?.totalEvaluations, 4)
            XCTAssertEqual(completer.executionCalls, 4, "the repeated c0/t1 request replayed its recorded outcome")

            let secondResult = try await controller.wait(for: submit(controller, experiment: experiment))
            XCTAssertEqual(secondResult.disposition, .stoppedBudget)
            XCTAssertEqual(secondResult.optimization?.totalEvaluations, 0)
            XCTAssertEqual(replays.values, [true])
            XCTAssertEqual(completer.executionCalls, 4, "a resume never spends past the approved cumulative cap")
            XCTAssertEqual(try ledger(root: root, experiment: experiment).entries.count, 4)
        }

        // MARK: Results

        func testDuplicateRetainedTextCompletesWithSharedEvidenceAndNoInventedIndex() async throws {
            let root = try makeRoot()
            let (experiment, registry) = try makeExperiment()
            let worker = FakeWorker { host, event in
                try await Self.register(event, 0, "seed prompt", score: 0)
                _ = await host(Self.evaluate("dup", "t1"))
                try await Self.register(event, 1, "dup", parents: [0], score: 1)
                try await Self.register(event, 2, "dup", parents: [1], score: 1)
                return Self.terminal([("seed prompt", [], 0), ("dup", [0], 1), ("dup", [1], 1)], best: 1)
            }
            let controller = makeController(root: root, registry: registry, completer: FakeCompleter(), workers: [worker])
            let result = try await controller.wait(for: submit(controller, experiment: experiment))
            let optimization = try XCTUnwrap(result.optimization)
            XCTAssertEqual(optimization.candidates, ["seed prompt", "dup", "dup"])
            XCTAssertEqual(optimization.evaluations.map(\.candidateIndex), [-1])
            XCTAssertEqual(optimization.parentIndices, [[], [0], [1]])
        }

        func testLargeTargetOutputStaysHostSideWhileTheWorkerGetsABoundedExcerpt() async throws {
            let root = try makeRoot()
            let (experiment, registry) = try makeExperiment()
            let completer = FakeCompleter()
            let large = String(repeating: "E", count: 2 * 1024 * 1024)
            completer.handler = { _, _, _ in large }
            let replies = Recorder<GEPAWorkerProtocol.HostReply>()
            let worker = FakeWorker { host, event in
                try await Self.register(event, 0, "seed prompt")
                await replies.append(host(Self.evaluate("seed prompt", "t1")))
                return Self.terminal([("seed prompt", [], 0)], best: 0)
            }
            let controller = makeController(root: root, registry: registry, completer: completer, workers: [worker])
            let result = try await controller.wait(for: submit(controller, experiment: experiment))
            guard case let .evaluated(reply) = replies.values.first else { return XCTFail("Expected a scored reply") }
            XCTAssertLessThan(reply.outputExcerpt?.count ?? 0, 9 * 1024)
            XCTAssertLessThan(reply.feedback.count, 17 * 1024)
            XCTAssertEqual(result.optimization?.evaluations.first?.output?.count, large.count)
            XCTAssertLessThan(result.optimization?.rawResultJSON.count ?? .max, 4 * 1024)
        }

        // MARK: Provider retries

        func testTransientProviderFailureRetriesWithBackoffWithoutASecondAdmission() async throws {
            let root = try makeRoot()
            let (experiment, registry) = try makeExperiment(maxProviderRetries: 1)
            let completer = FakeCompleter()
            var failures = 1
            completer.handler = { _, _, _ in
                if failures > 0 {
                    failures -= 1
                    throw PromptExperimentProviderFailure(code: .rateLimited)
                }
                return "good"
            }
            let replies = Recorder<GEPAWorkerProtocol.HostReply>()
            let worker = FakeWorker { host, event in
                try await Self.register(event, 0, "seed prompt")
                await replies.append(host(Self.evaluate("seed prompt", "t1")))
                return Self.terminal([("seed prompt", [], 1)], best: 0)
            }
            let sleeps = Recorder<Double>()
            let checkpoints = Recorder<PromptExperimentCheckpoint>()
            let controller = makeController(root: root, registry: registry, completer: completer, workers: [worker], sleeps: sleeps)
            _ = try await controller.wait(for: submit(controller, experiment: experiment, checkpoints: checkpoints))

            guard case let .evaluated(reply) = replies.values.first else { return XCTFail("Expected a scored reply") }
            XCTAssertEqual(reply.score, 1)
            XCTAssertEqual(sleeps.values, [2], "base 2s with the midpoint jitter factor 1.0")
            let states = checkpoints.values.compactMap { value -> PromptExperimentModelCallEvidence.State? in
                if case let .modelCall(call) = value, call.role == "execution" { return call.state }
                return nil
            }
            XCTAssertEqual(states, [.started, .failed, .started, .completed], "each invocation is its own ledger entry")
            XCTAssertEqual(try ledger(root: root, experiment: experiment).entries.count, 1)
        }

        func testNonRetryableProviderFailureDoesNotRetryAndSettlesTheAdmissionAsSpent() async throws {
            let root = try makeRoot()
            let (experiment, registry) = try makeExperiment(maxProviderRetries: 3)
            let completer = FakeCompleter()
            completer.handler = { _, _, _ in throw PromptExperimentProviderFailure(code: .rejected) }
            let replies = Recorder<GEPAWorkerProtocol.HostReply>()
            let worker = FakeWorker { host, _ in
                await replies.append(host(Self.evaluate("seed prompt", "t1")))
                throw PromptExperimentGEPAWorker.WorkerError.infrastructureFailure("worker failed")
            }
            let sleeps = Recorder<Double>()
            let controller = makeController(root: root, registry: registry, completer: completer, workers: [worker], sleeps: sleeps)
            let result = try await controller.wait(for: submit(controller, experiment: experiment))
            XCTAssertEqual(replies.values, [.failed(code: "provider_rejected", message: PromptExperimentProviderFailureCode.rejected.safeMessage)])
            XCTAssertEqual(completer.executionCalls, 1)
            XCTAssertTrue(sleeps.values.isEmpty)
            guard case .failed = result.disposition else { return XCTFail("Infrastructure failure is not a completed run") }
            XCTAssertEqual(try ledger(root: root, experiment: experiment).entries.map(\.state), [.failed])
        }

        func testRetryPolicyBacksOffExponentiallyWithBoundedJitter() {
            let policy = PromptExperimentProviderRetryPolicy(maxRetries: 3)
            XCTAssertEqual(policy.delaySeconds(beforeRetry: 1, jitter: 0.5), 2)
            XCTAssertEqual(policy.delaySeconds(beforeRetry: 2, jitter: 0.5), 4)
            XCTAssertEqual(policy.delaySeconds(beforeRetry: 5, jitter: 0.5), 30, "capped at the maximum delay")
            XCTAssertEqual(policy.delaySeconds(beforeRetry: 1, jitter: 0), 1)
            XCTAssertLessThan(policy.delaySeconds(beforeRetry: 1, jitter: 0.999), 3)
        }

        func testOverallDeadlineCancelsAHungCallAndIsNotRetried() async throws {
            let completer = BlockingCompleter()
            let checkpoints = Recorder<PromptExperimentCheckpoint>()
            let callbackRoot = try makeRoot()
            let invoker = PromptExperimentModelInvoker(
                completer: completer,
                policy: PromptExperimentProviderRetryPolicy(maxRetries: 3, overallTimeoutSeconds: 0.2),
                checkpoint: { checkpoints.append($0) },
                callbackRootBase: callbackRoot
            )
            do {
                _ = try await invoker.invoke(target: Self.executionTarget, role: "execution", systemPrompt: "s", userPrompt: "hang")
                XCTFail("A hung call must time out")
            } catch let failure as PromptExperimentProviderFailure {
                XCTAssertEqual(failure.code, .timedOut)
            }
            XCTAssertEqual(completer.cancelledInputs, ["hang"])
            XCTAssertEqual(checkpoints.values.count, 2)
        }

        // MARK: Cancellation

        func testCancellingOneRunLeavesAnotherRunsCallRunning() async throws {
            let root = try makeRoot()
            let (experimentA, registryA) = try makeExperiment(cases: [
                .init(id: "t1", split: "training", input: "input A"),
                .init(id: "v1", split: "validation", input: "validation A")
            ])
            let (experimentB, registryB) = try makeExperiment(cases: [
                .init(id: "t1", split: "training", input: "input B"),
                .init(id: "v1", split: "validation", input: "validation B")
            ])
            let completer = BlockingCompleter()
            func worker() -> FakeWorker {
                FakeWorker { host, event in
                    try await Self.register(event, 0, "seed prompt")
                    let reply = await host(Self.evaluate("seed prompt", "t1"))
                    guard case .evaluated = reply else { throw CancellationError() }
                    return Self.terminal([("seed prompt", [], 1)], best: 0)
                }
            }
            let controllerA = makeController(root: root, registry: registryA, completer: completer, workers: [worker()])
            let controllerB = makeController(root: root, registry: registryB, completer: completer, workers: [worker()])
            let handleA = try await submit(controllerA, experiment: experimentA)
            let handleB = try await submit(controllerB, experiment: experimentB)
            for _ in 0 ..< 400 where completer.waitingCount < 2 {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(completer.waitingCount, 2)

            let cancellation = await controllerA.cancel(handleA)
            XCTAssertEqual(cancellation, .requested)
            let resultA = await controllerA.wait(for: handleA)
            XCTAssertEqual(resultA.disposition, .cancelled)
            XCTAssertEqual(completer.cancelledInputs, [Self.packaged("input A")])
            XCTAssertEqual(completer.waitingCount, 1, "run B's call is untouched")

            completer.release(Self.packaged("input B"), output: "good")
            let resultB = await controllerB.wait(for: handleB)
            XCTAssertEqual(resultB.disposition, .completed)
            XCTAssertEqual(resultB.optimization?.evaluations.first?.score, 1)
        }

        // MARK: Resolution and rendering

        func testResolutionRejectsCapsBelowTheMinimumAndInterruptedRunsAreSettledAsSpent() async throws {
            let (experiment, registry) = try makeExperiment()
            var small = experiment
            small.authority = PromptExperimentAuthority(
                promptID: experiment.authority.promptID,
                promptResourceSHA256: experiment.authority.promptResourceSHA256,
                suiteID: experiment.authority.suiteID,
                suiteSHA256: experiment.authority.suiteSHA256,
                rubricSHA256: nil,
                targets: experiment.authority.targets,
                settings: experiment.authority.settings,
                maxEvaluations: 3,
                calibrationEvaluations: 0,
                pythonSealValue: experiment.authority.pythonSealValue,
                gepaRevision: experiment.authority.gepaRevision
            )
            XCTAssertThrowsError(try GEPARunController.resolveExecution(small, registry: registry)) { error in
                XCTAssertTrue(error.localizedDescription.contains("below the minimum"))
            }

            let root = try makeRoot()
            let runRoot = root.appendingPathComponent(GEPARunController.runDirectoryRelativePath(experimentID: experiment.id, authorityDigest: experiment.authorityDigest))
            let crashed = try PromptExperimentBudgetLedger.open(
                directory: runRoot, authorityDigest: experiment.authorityDigest, totalCap: 4, heldOutReserve: 0,
                calibrationReserve: 0, gepaStateURL: runRoot.appendingPathComponent("gepa-run/gepa_state.bin")
            )
            _ = try crashed.admit(candidateSHA256: "x", exampleID: "t1", split: .training)
            let worker = FakeWorker { _, event in
                try await Self.register(event, 0, "seed prompt")
                return Self.terminal([("seed prompt", [], nil)], best: 0)
            }
            let controller = makeController(root: root, registry: registry, completer: FakeCompleter(), workers: [worker])
            let result = try await controller.wait(for: submit(controller, experiment: experiment))
            XCTAssertEqual(result.interruptedAdmissionsSettled, 1)
            XCTAssertEqual(result.admissionsAfter, 1, "the interrupted admission stays spent")
            XCTAssertEqual(try ledger(root: root, experiment: experiment).entries.map(\.state), [.interrupted])
        }

        func testWorkerRequestCarriesOnlyIdentifiersSplitsAndInputs() throws {
            let (experiment, registry) = try makeExperiment(cases: PromptExperimentTestFixtures.defaultCases + [
                .init(id: "h1", split: "hidden_test", input: "hidden input", expected: "SECRET_EXPECTED")
            ], maxEvaluations: 6)
            let execution = try GEPARunController.resolveExecution(experiment, registry: registry)
            let request = GEPARunController.makeWorkerRequest(execution: execution, runRoot: URL(fileURLWithPath: "/tmp/run"), searchRemaining: 5)
            XCTAssertEqual(request.searchRemaining, 5)
            XCTAssertNil(request.seedOutputCharacters, "omitted when nothing is recorded")
            XCTAssertEqual(request.examples.map(\.id), ["t1", "v1"])
            XCTAssertEqual(request.heldOutExamples.map(\.id), ["h1"])
            XCTAssertEqual(request.searchMaxEvaluations, 5, "the held-out reserve (1 per hidden case, incumbent only) is excluded")
            XCTAssertEqual(request.seedCandidate, "seed prompt", "the seed is the built-in baseline")
            XCTAssertEqual(request.reflectionMinibatchSize, 2)
            XCTAssertEqual(request.candidateSelectionStrategy, "current_best")
            XCTAssertFalse(request.useMerge)
            XCTAssertNil(request.heldOutBaseline)
            XCTAssertEqual(request.promptCharacterCeilingRatio, 1.0, "proposals may not grow the prompt by default")
            XCTAssertNil(request.maxPromptCharacters)
            XCTAssertTrue(request.objective.contains("shorter wins"))
            let wire = try String(decoding: JSONEncoder().encode(request), as: UTF8.self)
            XCTAssertTrue(wire.contains("\"prompt_character_ceiling_ratio\":1"))
            XCTAssertFalse(wire.contains("SECRET"))
            XCTAssertFalse(wire.contains("\"good\""))
            XCTAssertFalse(wire.contains("hidden input"), "held-out inputs never cross to the worker")
            XCTAssertEqual(request.heldOutExamples, [.init(id: "h1", split: "hidden_test")])
        }

        // MARK: Baseline calibration

        private static let hiddenCases = PromptExperimentTestFixtures.defaultCases + [
            .init(id: "h1", split: "hidden_test", input: "hidden input")
        ]

        func testSeedHeldOutBaselineIsCalibratedOnceThenReusedAcrossExperiments() async throws {
            let root = try makeRoot()
            let registry = try PromptExperimentTestFixtures.makeRegistry(root: makeRoot(), cases: Self.hiddenCases)
            let first = try PromptExperimentTestFixtures.makeExperiment(registry: registry, maxEvaluations: 6)
            let second = try PromptExperimentTestFixtures.makeExperiment(registry: registry, maxEvaluations: 6)
            XCTAssertEqual(first.authority.calibrationEvaluations, 1)
            let completer = FakeCompleter()
            func worker() -> FakeWorker {
                FakeWorker { _, event in
                    try await Self.register(event, 0, "seed prompt", score: 1)
                    return Self.terminal(
                        [("seed prompt", [], 1)], best: 0,
                        heldOut: .init(baseline: .init(scores: ["h1": 1], average: 1), best: .init(scores: ["h1": 1], average: 1))
                    )
                }
            }
            let workers = [worker(), worker()]
            let controller = makeController(root: root, registry: registry, completer: completer, workers: workers)

            let calibrated = try await controller.wait(for: submit(controller, experiment: first))
            XCTAssertEqual(completer.executionCalls, 1, "the seed's held-out case is scored once before search")
            XCTAssertEqual(workers[0].request?.heldOutBaseline, .init(scores: ["h1": 1], average: 1))
            XCTAssertEqual(calibrated.calibrationAdmissionsAfter, 1)
            XCTAssertEqual(calibrated.admissionsAfter, 0, "calibration is outside the approved search cap")
            XCTAssertEqual(calibrated.optimization?.heldOut?.baselineSource, .calibrated)
            XCTAssertEqual(try ledger(root: root, experiment: first).entries.map(\.pool), [.calibration])

            let reused = try await controller.wait(for: submit(controller, experiment: second))
            XCTAssertEqual(completer.executionCalls, 1, "a matching cache entry spends nothing")
            XCTAssertEqual(workers[1].request?.heldOutBaseline, .init(scores: ["h1": 1], average: 1))
            XCTAssertEqual(reused.calibrationAdmissionsAfter, 0)
            XCTAssertEqual(reused.optimization?.heldOut?.baselineSource, .cache)
            XCTAssertTrue(reused.optimization?.heldOut?.summary.contains("reused from the calibration cache") == true)
        }

        func testCalibrationFailureLeavesTheBaselineUnavailableWithoutFailingTheSearch() async throws {
            let root = try makeRoot()
            let registry = try PromptExperimentTestFixtures.makeRegistry(root: makeRoot(), cases: Self.hiddenCases)
            let experiment = try PromptExperimentTestFixtures.makeExperiment(registry: registry, maxEvaluations: 6)
            let completer = FakeCompleter()
            completer.handler = { _, _, user in
                if user.contains("hidden input") { throw PromptExperimentProviderFailure(code: .rejected) }
                return "good"
            }
            let worker = FakeWorker { _, event in
                try await Self.register(event, 0, "seed prompt", score: 1)
                return Self.terminal([("seed prompt", [], 1)], best: 0)
            }
            let controller = makeController(root: root, registry: registry, completer: completer, workers: [worker])
            let result = try await controller.wait(for: submit(controller, experiment: experiment))
            XCTAssertEqual(result.disposition, .completed)
            XCTAssertNil(worker.request?.heldOutBaseline)
            let key = try GEPARunController.resolveExecution(experiment, registry: registry).calibrationKey(registry: registry)
            XCTAssertNil(PromptExperimentCalibrationCache.load(storeRoot: root, key: key), "a failed calibration is never cached")
        }

        // MARK: Noise floor

        private static let noiseCases: [PromptSuiteCase] = [
            PromptSuiteCase(id: "t1", split: .training, input: "t", expectedOutput: nil),
            PromptSuiteCase(id: "v1", split: .validation, input: "a", expectedOutput: nil),
            PromptSuiteCase(id: "v2", split: .validation, input: "b", expectedOutput: nil)
        ]

        func testNoiseFloorFlagsImprovementsNoLargerThanTheSeedSpread() throws {
            let noisy = try XCTUnwrap(PromptExperimentNoiseFloor.compute(
                validationCases: PromptExperimentBudgetLedger.validationPassCases(Self.noiseCases),
                seedSamples: ["v1": [0.5, 0.7, 0.6], "v2": [0.4, 0.5, 0.6]],
                bestValidation: ["v1": 0.75, "v2": 0.6],
                seedHeldOut: ["h1": 0.5],
                bestHeldOut: ["h1": 0.6],
                bestIsBaseline: false
            ))
            XCTAssertEqual(noisy.samplesPerCase, 3)
            XCTAssertEqual(noisy.meanSpread, 0.2, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(noisy.meanDelta), 0.125, accuracy: 1e-9)
            XCTAssertTrue(noisy.withinNoise, "+0.125 does not exceed the 0.2 seed spread")
            XCTAssertEqual(noisy.improvedBeyondNoise, 0)
            XCTAssertEqual(noisy.heldOut.map(\.exampleID), ["h1"])
            XCTAssertTrue(noisy.summary.contains("within noise: not a demonstrated improvement"), noisy.summary)
            XCTAssertTrue(noisy.summary.contains("Held-out \u{0394} +0.100 (0 of 1 case beyond the spread)"), noisy.summary)

            let clear = try XCTUnwrap(PromptExperimentNoiseFloor.compute(
                validationCases: PromptExperimentBudgetLedger.validationPassCases(Self.noiseCases),
                seedSamples: ["v1": [0.5, 0.5, 0.6], "v2": [0.4, 0.4, 0.4]],
                bestValidation: ["v1": 0.9, "v2": 0.8],
                seedHeldOut: nil,
                bestHeldOut: nil,
                bestIsBaseline: false
            ))
            XCTAssertFalse(clear.withinNoise)
            XCTAssertEqual(clear.improvedBeyondNoise, 2)
            XCTAssertTrue(clear.summary.hasSuffix("beyond noise."), clear.summary)

            let unmeasured = try XCTUnwrap(PromptExperimentNoiseFloor.compute(
                validationCases: PromptExperimentBudgetLedger.validationPassCases(Self.noiseCases),
                seedSamples: ["v1": [0.5], "v2": [0.4]],
                bestValidation: ["v1": 0.9, "v2": 0.8],
                seedHeldOut: nil, bestHeldOut: nil, bestIsBaseline: false
            ))
            XCTAssertFalse(unmeasured.measured)
            XCTAssertTrue(unmeasured.withinNoise, "an unmeasured gain is never reported as beyond noise")
            XCTAssertTrue(unmeasured.summary.hasPrefix("Noise floor not measured"))

            let seedBest = try XCTUnwrap(PromptExperimentNoiseFloor.compute(
                validationCases: PromptExperimentBudgetLedger.validationPassCases(Self.noiseCases),
                seedSamples: ["v1": [0.5, 0.6]], bestValidation: ["v1": 0.5],
                seedHeldOut: ["h1": 1], bestHeldOut: ["h1": 1], bestIsBaseline: true
            ))
            XCTAssertTrue(seedBest.heldOut.isEmpty)
            XCTAssertTrue(seedBest.summary.contains("the seed stayed best"))
            XCTAssertNil(PromptExperimentNoiseFloor.compute(
                validationCases: [], seedSamples: [:], bestValidation: nil, seedHeldOut: nil, bestHeldOut: nil, bestIsBaseline: false
            ))
        }

        func testNoiseFloorReplicatesAreCalibratedCachedAndJudgedPairwise() async throws {
            let root = try makeRoot()
            let registry = try PromptExperimentTestFixtures.makeRegistry(root: makeRoot())
            let first = try PromptExperimentTestFixtures.makeExperiment(registry: registry, maxEvaluations: 6, noiseFloorReplicates: 2)
            let second = try PromptExperimentTestFixtures.makeExperiment(registry: registry, maxEvaluations: 6, noiseFloorReplicates: 2)
            XCTAssertEqual(first.authority.calibrationEvaluations, 2, "two replicates of the one validation case")
            let completer = FakeCompleter()
            var seedValidationCalls = 0
            completer.handler = { _, _, user in
                guard user.contains("validation input") else { return "good" }
                seedValidationCalls += 1
                return seedValidationCalls == 2 ? "bad" : "good" // replicate 2 disagrees: spread 1.0
            }
            func worker() -> FakeWorker {
                FakeWorker { host, event in
                    try await Self.register(event, 0, "seed prompt", score: 1)
                    _ = await host(Self.evaluate("seed prompt", "v1", .validation))
                    try await Self.register(event, 1, "better prompt", parents: [0], score: 1)
                    var terminal = Self.terminal([("seed prompt", [], 1), ("better prompt", [0], 1)], best: 1)
                    terminal.validationScores = .init(baseline: ["v1": 1], best: ["v1": 1])
                    return terminal
                }
            }
            let workers = [worker(), worker()]
            let controller = makeController(root: root, registry: registry, completer: completer, workers: workers)

            let calibrated = try await controller.wait(for: submit(controller, experiment: first))
            XCTAssertEqual(calibrated.calibrationAdmissionsAfter, 2)
            XCTAssertEqual(try ledger(root: root, experiment: first).entries.map(\.replicate), [1, 2, 0], "replicates first, then GEPA's own pass")
            let noise = try XCTUnwrap(calibrated.optimization?.noiseFloor)
            XCTAssertEqual(noise.validation.first?.baselineSamples, [1, 1, 0], "GEPA's pass, then replicates 1 and 2")
            XCTAssertEqual(noise.meanSpread, 1)
            XCTAssertTrue(noise.withinNoise)

            let reused = try await controller.wait(for: submit(controller, experiment: second))
            XCTAssertEqual(reused.calibrationAdmissionsAfter, 0, "cached replicates are not paid for again")
            XCTAssertEqual(reused.optimization?.noiseFloor?.validation.first?.baselineSamples, [1, 1, 0])
            XCTAssertEqual(seedValidationCalls, 4, "2 replicates + 2 GEPA seed passes (one per experiment ledger)")
        }

        func testCalibrationKeyChangesWithEveryMeasuredInput() {
            let targets = PromptExperimentTargets(
                execution: PromptExperimentTestFixtures.execution,
                reflection: PromptExperimentTestFixtures.reflection,
                judge: PromptExperimentTestFixtures.judge
            )
            func key(
                seed: String = "s", suite: String = "u", rubric: String? = "r", targets: PromptExperimentTargets = targets,
                retries: Int = 2, judgeTemplate: String? = "j"
            ) -> String {
                PromptExperimentCalibrationCache.key(
                    promptID: .oraclePlan, renderedSeedSHA256: seed, suiteSHA256: suite, rubricSHA256: rubric, targets: targets,
                    maxProviderRetries: retries, judgeTemplateSHA256: judgeTemplate
                )
            }
            let base = key()
            XCTAssertEqual(base, key(), "deterministic")
            XCTAssertNotEqual(base, key(seed: "t"), "rendered seed bytes, including code-owned suffixes")
            XCTAssertNotEqual(base, key(retries: 0), "retries decide which measurements complete")
            XCTAssertNotEqual(base, key(judgeTemplate: "k"), "the code-owned judge prompt shapes scores")
            XCTAssertNotEqual(base, key(suite: "v"))
            XCTAssertNotEqual(base, key(rubric: nil))
            XCTAssertNotEqual(base, key(targets: .init(execution: targets.reflection, reflection: targets.reflection, judge: targets.judge)))
            XCTAssertNotEqual(base, key(targets: .init(execution: targets.execution, reflection: targets.reflection, judge: targets.reflection)))
            XCTAssertEqual(
                base,
                key(targets: .init(execution: targets.execution, reflection: PromptExperimentTestFixtures.judge, judge: targets.judge)),
                "the reflection model never influences seed measurements"
            )
        }

        func testExecutionCalibrationKeyDigestsTheRenderedSeedAndScoringSettings() throws {
            let registry = try PromptExperimentTestFixtures.makeRegistry(root: makeRoot())
            let zero = try GEPARunController.resolveExecution(
                PromptExperimentTestFixtures.makeExperiment(registry: registry, maxProviderRetries: 0), registry: registry
            )
            let one = try GEPARunController.resolveExecution(
                PromptExperimentTestFixtures.makeExperiment(registry: registry, maxProviderRetries: 1), registry: registry
            )
            let rendered = try ConnectedModelHarness.renderSystemPrompt(candidate: zero.baseline, promptID: .oraclePlan, registry: registry)
            XCTAssertNotEqual(rendered, zero.baseline, "the key covers the code-owned response-format suffix, not just the resource")
            XCTAssertEqual(try zero.calibrationKey(registry: registry), PromptExperimentCalibrationCache.key(
                promptID: .oraclePlan,
                renderedSeedSHA256: Self.sha(rendered),
                suiteSHA256: zero.suite.suiteSHA256,
                rubricSHA256: nil,
                targets: zero.targets,
                maxProviderRetries: 0,
                judgeTemplateSHA256: nil
            ))
            XCTAssertNotEqual(try zero.calibrationKey(registry: registry), try one.calibrationKey(registry: registry))
        }

        func testResumeSendsTheSeedsRecordedAnswerLengthsAndTheLedgerRemaining() async throws {
            let root = try makeRoot()
            let (experiment, registry) = try makeExperiment(maxEvaluations: 6)
            let completer = FakeCompleter()
            completer.handler = { _, _, user in user.contains("validation") ? "good" : "bad answer" }
            let first = FakeWorker { host, event in
                try await Self.register(event, 0, "seed prompt", score: 1)
                _ = await host(Self.evaluate("seed prompt", "v1", .validation))
                _ = await host(Self.evaluate("seed prompt", "t1"))
                return Self.terminal([("seed prompt", [], 1)], best: 0)
            }
            let second = FakeWorker { _, event in
                try await Self.register(event, 0, "seed prompt", score: 1)
                return Self.terminal([("seed prompt", [], 1)], best: 0)
            }
            let controller = makeController(root: root, registry: registry, completer: completer, workers: [first, second])
            _ = try await controller.wait(for: submit(controller, experiment: experiment))
            XCTAssertNil(first.request?.seedOutputCharacters, "nothing recorded before the first run")
            XCTAssertEqual(first.request?.searchRemaining, 6)
            _ = try await controller.wait(for: submit(controller, experiment: experiment))
            XCTAssertEqual(second.request?.seedOutputCharacters, ["v1": 4, "t1": 10])
            XCTAssertEqual(second.request?.searchRemaining, 4, "the resumed worker starts from the ledger's count")
        }

        func testSeedAnswerLengthsPreferGEPAsOwnPassOverReplicates() throws {
            let directory = try makeRoot()
            let ledger = try PromptExperimentBudgetLedger.open(
                directory: directory, authorityDigest: "d", totalCap: 4, heldOutReserve: 1, calibrationReserve: 2,
                gepaStateURL: directory.appendingPathComponent("gepa-run/gepa_state.bin")
            )
            func record(_ candidate: String, _ example: String, _ split: PromptExperimentDatasetSplit, replicate: Int, pool: PromptExperimentBudgetLedger.Pool?, characters: Int) throws {
                guard case let .admitted(entry) = try ledger.admit(
                    candidateSHA256: candidate, exampleID: example, split: split, replicate: replicate, pool: pool
                ) else { return XCTFail("expected an admission") }
                try ledger.settle(entry.evaluationID, outcome: .init(
                    score: 1, proposerFeedback: "", outputExcerpt: nil, failureKind: nil,
                    usage: .init(promptCharacters: 1, outputCharacters: characters, promptTokens: nil, completionTokens: nil)
                ))
            }
            try record("seed", "v1", .validation, replicate: 1, pool: .calibration, characters: 90)
            try record("seed", "v1", .validation, replicate: 0, pool: nil, characters: 40)
            try record("seed", "v2", .validation, replicate: 2, pool: .calibration, characters: 70)
            try record("seed", "h1", .hiddenTest, replicate: 0, pool: nil, characters: 5)
            try record("other", "v3", .validation, replicate: 0, pool: nil, characters: 1)
            XCTAssertEqual(
                GEPARunController.seedOutputCharacters(seedSHA256: "seed", ledger: ledger),
                ["v1": 40, "v2": 70],
                "replicate 0 wins, replicates fill gaps, held-out and other candidates never leak"
            )
        }

        func testEvaluationRepliesCarryLedgerRemainingAndUsageAggregatesPerCandidate() async throws {
            let root = try makeRoot()
            let (experiment, registry) = try makeExperiment(maxEvaluations: 5)
            let replies = Recorder<GEPAWorkerProtocol.HostReply>()
            let worker = FakeWorker { host, event in
                try await Self.register(event, 0, "seed prompt", score: 1)
                for request in [Self.evaluate("seed prompt", "v1", .validation), Self.evaluate("seed prompt", "t1"), Self.evaluate("seed prompt", "t1")] {
                    await replies.append(host(request))
                }
                return Self.terminal([("seed prompt", [], 1)], best: 0)
            }
            let controller = makeController(root: root, registry: registry, completer: FakeCompleter(), workers: [worker])
            let result = try await controller.wait(for: submit(controller, experiment: experiment))
            let remaining = replies.values.compactMap { reply -> Int? in
                if case let .evaluated(value) = reply { return value.searchRemaining }
                return nil
            }
            XCTAssertEqual(remaining, [4, 3, 3], "a replay spends nothing and reports the same remaining count")
            guard case let .evaluated(first) = replies.values.first else { return XCTFail("Expected a scored reply") }
            XCTAssertEqual(first.promptTokens, 3)
            XCTAssertEqual(first.completionTokens, 2)
            XCTAssertEqual(first.outputCharacters, 4)
            guard case let .evaluated(replayed) = replies.values.last else { return XCTFail("Expected a replayed reply") }
            XCTAssertTrue(replayed.replayed)
            XCTAssertEqual(replayed.outputCharacters, 4, "replays carry the recorded answer length for brevity")
            let usage = try XCTUnwrap(result.optimization?.candidateUsage.first ?? nil)
            XCTAssertEqual(usage.promptCharacters, "seed prompt".count)
            XCTAssertEqual(usage.evaluations, 2)
            XCTAssertEqual(usage.averageOutputCharacters, 4)
            XCTAssertEqual(usage.averageCompletionTokens, 2)
            XCTAssertEqual(result.optimization?.evaluations.first?.usage?.outputCharacters, 4)
        }

        func testOutputExcerptKeepsHeadAndTailWithAnOmissionMarker() {
            let head = String(repeating: "H", count: 4000)
            let tail = String(repeating: "T", count: 4000)
            let excerpt = ConnectedModelHarness.outputExcerpt(head + tail)
            XCTAssertTrue(excerpt.hasPrefix(String(repeating: "H", count: 3072)))
            XCTAssertTrue(excerpt.hasSuffix(String(repeating: "T", count: 3072)))
            XCTAssertTrue(excerpt.contains("1856 characters omitted"))
            XCTAssertEqual(ConnectedModelHarness.outputExcerpt("short"), "short")
        }

        func testCaseInputIsPackagedLikeAProductionOracleUserMessage() throws {
            let example = PromptSuiteCase(
                id: "t1", split: .training, input: "Plan the change.", expectedOutput: nil,
                context: PromptSuiteCaseContext(
                    fileTree: "root\n└── Sources/A.swift",
                    files: [PromptSuiteContextFile(path: "Sources/A.swift", content: "let a = 1")]
                )
            )
            let production = PromptPackagingService.buildAIMessage(
                systemPrompt: "system",
                metaInstructions: [],
                fileTree: "root\n└── Sources/A.swift",
                fileContents: [PromptPackagingService.fullFileBlock(path: "Sources/A.swift", content: "let a = 1")],
                conversation: [ConversationEntry(role: .user, content: "Plan the change.")],
                temperature: nil,
                promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
                disabledPromptSections: []
            )
            let expected = """
            <file_tree>
            root
            └── Sources/A.swift
            </file_tree>

            <file_contents>
            File: Sources/A.swift
            ```swift
            let a = 1
            ```

            </file_contents>
            <user_instructions>
            Plan the change.
            </user_instructions>
            """
            XCTAssertEqual(example.packagedUserMessage, expected)
            XCTAssertEqual(production.packagedFinalUserMessage, expected, "the harness uses the production packaging path")
            XCTAssertEqual(
                PromptSuiteCase(id: "t2", split: .training, input: "Bare.", expectedOutput: nil).packagedUserMessage,
                "<user_instructions>\nBare.\n</user_instructions>"
            )

            let suite = try PromptSuiteLoader.load(promptID: .oraclePlan)
            for example in suite.cases {
                let message = example.packagedUserMessage
                XCTAssertTrue(message.contains("<file_tree>") && message.contains("<file_contents>\nFile: "), example.id)
                XCTAssertTrue(message.hasSuffix("<user_instructions>\n\(example.input)\n</user_instructions>"), example.id)
            }
        }

        func testBuiltInCandidateRendersThroughTheProductionOracleComposition() throws {
            let registry = AppDomainRuntimeComposition.shared.builtInPromptRegistry
            let baseline = try registry.resource(.oraclePlan).text
            // Pinned production hash of the Oracle Plan system prompt (BuiltInPromptRegistryTests).
            let rendered = try ConnectedModelHarness.renderSystemPrompt(candidate: baseline, promptID: .oraclePlan, registry: registry)
            XCTAssertEqual(Self.sha(rendered), "b0fae79a60bb3597be4290a02cdabf306e68fd7f52ff2757fdfc91c7572e6347")

            let candidate = "Plan carefully.\n```swift\nlet x = 1\n```"
            let override = try ConnectedModelHarness.renderSystemPrompt(candidate: candidate, promptID: .oraclePlan, registry: registry)
            XCTAssertEqual(override, OracleSystemPromptRenderer.appendingResponseFormat(to: candidate))
            XCTAssertEqual(registry.text(.oraclePlan), baseline, "a per-evaluation override never leaks into production")
        }

        func testBaselineDriftAfterApprovalIsRejected() throws {
            let (experiment, _) = try makeExperiment()
            let drifted = try PromptExperimentTestFixtures.makeRegistry(root: makeRoot(), prompt: "edited baseline")
            XCTAssertThrowsError(try GEPARunController.resolveExecution(experiment, registry: drifted)) { error in
                XCTAssertTrue(error.localizedDescription.contains("changed after approval"))
            }
        }
    }
#endif
