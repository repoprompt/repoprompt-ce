#if DEBUG
    import Foundation

    /// Everything a run needs, resolved from an approved experiment and re-verified against
    /// the bundled resources: the baseline prompt text and the checked-in suite.
    struct PromptExperimentExecution {
        let experimentID: UUID
        let authorityDigest: String
        let promptID: BuiltInPromptID
        let baseline: String
        let suite: PromptSuite
        let targets: PromptExperimentTargets
        let settings: PromptExperimentGEPASettings
        let maxEvaluations: Int
        let calibrationEvaluations: Int
        let pythonSealValue: String

        var baselineSHA256: String {
            PromptExperimentDigest.sha256(Data(baseline.utf8))
        }

        var calibrationKey: String {
            PromptExperimentCalibrationCache.key(
                promptID: promptID,
                seedSHA256: baselineSHA256,
                suiteSHA256: suite.suiteSHA256,
                rubricSHA256: suite.grader.rubric?.sha256,
                targets: targets
            )
        }
    }

    /// GEPA-native prompt-only runtime.
    ///
    /// One worker per run; the run's host callbacks are tasks the worker cancels on
    /// cancellation, so cancelling one run never touches another run's calls. The durable
    /// `PromptExperimentBudgetLedger` in the app-owned run directory (keyed by experiment ID
    /// and approved authority digest) is the only hard evaluation authority; GEPA's own
    /// `max_evals` is a soft, cumulative stopper that the ledger backs. Every run of an
    /// experiment reuses that directory, so a later run resumes GEPA and the ledger.
    @MainActor
    final class GEPARunController: PromptExperimentRuntime {
        struct Environment {
            var storeRoot: URL
            var registry: BuiltInPromptRegistry
            var makeWorker: @MainActor () -> GEPAWorkerRunning
            var preflightWorker: @MainActor (_ pythonSealValue: String) async throws -> Void
            var completer: PromptExperimentModelCompleting
            var backoffSleep: @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
            var jitter: @Sendable () -> Double = { Double.random(in: 0 ..< 1) }
            var overallProviderTimeoutSeconds: Double = 900
            var now: () -> Date = Date.init
        }

        static let reflectionSystemPrompt = "Act as GEPA's reflection language model. Follow the output contract at the end of the request exactly. All tools are disabled."

        private struct RegisteredCandidate {
            let text: String
            let sha256: String
        }

        private struct RecordedEvaluation {
            let candidateSHA256: String
            let value: PromptExperimentOptimizationRuntimeEvaluation
        }

        /// One admitted-or-replayed logical evaluation through the ledger.
        private enum LedgerEvaluation {
            case exhausted(PromptExperimentBudgetLedger.Pool)
            case recorded(PromptExperimentBudgetLedger.Entry, PromptExperimentBudgetLedger.Outcome)
            case spent(PromptExperimentBudgetLedger.Entry, PromptExperimentBudgetLedger.Outcome)
        }

        private struct CalibrationResult {
            let heldOutScores: [String: Double]?
            let source: PromptExperimentCalibrationSource?
        }

        @MainActor
        private final class ActiveRun {
            let runID: UUID
            let execution: PromptExperimentExecution
            let ledger: PromptExperimentBudgetLedger
            let invoker: PromptExperimentModelInvoker
            let harness: ConnectedModelHarness
            let worker: GEPAWorkerRunning
            let progress: @MainActor @Sendable (String) async -> Void
            let checkpoint: PromptExperimentCheckpointSink
            var task: Task<PromptExperimentRuntimeResult, Never>?
            var cancelled = false
            var candidates: [Int: RegisteredCandidate] = [:]
            var evaluations: [RecordedEvaluation] = []
            var spentEvaluations = 0
            var replayedEvaluations = 0
            var calibration = CalibrationResult(heldOutScores: nil, source: nil)

            init(
                runID: UUID,
                execution: PromptExperimentExecution,
                ledger: PromptExperimentBudgetLedger,
                invoker: PromptExperimentModelInvoker,
                harness: ConnectedModelHarness,
                worker: GEPAWorkerRunning,
                progress: @escaping @MainActor @Sendable (String) async -> Void,
                checkpoint: @escaping PromptExperimentCheckpointSink
            ) {
                self.runID = runID
                self.execution = execution
                self.ledger = ledger
                self.invoker = invoker
                self.harness = harness
                self.worker = worker
                self.progress = progress
                self.checkpoint = checkpoint
            }
        }

        private let environment: Environment
        private var runs: [UUID: ActiveRun] = [:]
        private var activeRunDirectories: Set<String> = []

        init(environment: Environment) {
            self.environment = environment
        }

        static func live() -> GEPARunController {
            GEPARunController(environment: Environment(
                storeRoot: PromptExperimentStore.liveRootURL(),
                registry: .shared,
                makeWorker: { PromptExperimentGEPAWorker() },
                preflightWorker: { try await PromptExperimentGEPAWorker.preflight(pythonExecutable: $0) },
                completer: PromptExperimentConnectedModelRunner()
            ))
        }

        // MARK: - Resolution

        /// Re-verifies an experiment's authority against the bundled baseline and suite, without spending.
        static func resolveExecution(
            _ experiment: PromptExperiment,
            registry: BuiltInPromptRegistry
        ) throws -> PromptExperimentExecution {
            let authority = experiment.authority
            guard authority.gepaRevision == PromptExperimentGEPAConfiguration.pinnedRevision else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("The experiment was approved for a different GEPA revision.")
            }
            let resource = try registry.resource(authority.promptID)
            guard resource.sha256 == authority.promptResourceSHA256 else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("The built-in '\(authority.promptID.rawValue)' resource changed after approval (now \(resource.sha256.prefix(12))). Create a new experiment against the current baseline.")
            }
            let suite = try PromptSuiteLoader.load(promptID: authority.promptID, registry: registry)
            guard suite.suiteID == authority.suiteID,
                  suite.suiteSHA256 == authority.suiteSHA256,
                  suite.grader.rubric?.sha256 == authority.rubricSHA256
            else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("Suite '\(authority.suiteID)' or its rubric changed after approval. Create a new experiment against the current suite.")
            }
            guard (suite.grader.kind == .modelJudge) == (authority.targets.judge != nil) else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("The judge target does not match the suite grader.")
            }
            let minimum = PromptExperimentBudgetLedger.minimumApprovableEvaluations(
                cases: suite.cases,
                reflectionMinibatchSize: authority.settings.reflectionMinibatchSize
            )
            guard authority.maxEvaluations >= minimum else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("The approved cap of \(authority.maxEvaluations) evaluations is below the minimum of \(minimum) for one mutation-and-validation cycle.")
            }
            guard authority.calibrationEvaluations == PromptExperimentBudgetLedger.calibrationEvaluations(cases: suite.cases) else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("The approved baseline-calibration line no longer matches the suite. Create a new experiment.")
            }
            if let targetError = PromptExperimentConnectedModelRunner.targetErrors(authority.targets).first {
                throw PromptExperimentAuthorityError.targetUnavailable("\(targetError.field): \(targetError.message)")
            }
            return PromptExperimentExecution(
                experimentID: experiment.id,
                authorityDigest: experiment.authorityDigest,
                promptID: authority.promptID,
                baseline: resource.text,
                suite: suite,
                targets: authority.targets,
                settings: authority.settings,
                maxEvaluations: authority.maxEvaluations,
                calibrationEvaluations: authority.calibrationEvaluations,
                pythonSealValue: authority.pythonSealValue
            )
        }

        static func runDirectoryRelativePath(experimentID: UUID, authorityDigest: String) -> String {
            "gepa-runs/\(experimentID.uuidString.lowercased())/\(authorityDigest.prefix(32))"
        }

        static func makeWorkerRequest(
            execution: PromptExperimentExecution,
            runRoot: URL,
            searchRemaining: Int? = nil,
            heldOutBaseline: [String: Double]? = nil
        ) -> GEPAWorkerProtocol.RunRequest {
            /// Only identifiers, splits, and development inputs cross to the worker; held-out
            /// inputs, expected outputs, and rubrics stay host-side.
            func wire(_ example: PromptSuiteCase) -> GEPAWorkerProtocol.Example {
                .init(id: example.id, split: example.split.rawValue, input: example.input)
            }
            let settings = execution.settings
            return GEPAWorkerProtocol.RunRequest(
                runName: "rpce-\(execution.experimentID.uuidString.lowercased())",
                objective: "Improve RepoPrompt's built-in '\(execution.promptID.rawValue)' system prompt so the target model's answers score higher on suite '\(execution.suite.suiteID)'.",
                background: "The candidate is the complete prompt body. RepoPrompt appends fixed response-format instructions to it and sends each case as a production Oracle user message (frozen file map and file contents, then the case input in <user_instructions>) to a model with no tools. Preserve the prompt's role and output contract; do not memorize individual cases.",
                seedCandidate: execution.baseline,
                examples: execution.suite.cases.filter { $0.split != .hiddenTest }.map(wire),
                heldOutExamples: execution.suite.cases.filter { $0.split == .hiddenTest }
                    .map { GEPAWorkerProtocol.HeldOutExample(id: $0.id, split: $0.split.rawValue) },
                searchMaxEvaluations: execution.maxEvaluations
                    - PromptExperimentBudgetLedger.heldOutReserve(for: execution.suite.cases),
                searchRemaining: searchRemaining,
                heldOutBaseline: heldOutBaseline.flatMap { scores in
                    scores.isEmpty ? nil : GEPAWorkerProtocol.HeldOutScores(
                        scores: scores,
                        average: scores.values.reduce(0, +) / Double(scores.count)
                    )
                },
                reflectionMinibatchSize: settings.reflectionMinibatchSize,
                useMerge: settings.useMerge,
                maxMergeInvocations: settings.maxMergeInvocations,
                skipPerfectScore: settings.skipPerfectScore,
                candidateSelectionStrategy: settings.candidateSelectionStrategy,
                perfectScore: execution.suite.grader.scoreRange.max,
                stopAtScore: settings.stopAtScore,
                randomSeed: settings.randomSeed,
                runDir: runRoot.appendingPathComponent("gepa-run", isDirectory: true).path,
                outputDir: runRoot.appendingPathComponent("gepa-output", isDirectory: true).path
            )
        }

        func runDirectoryURL(for experiment: PromptExperiment) -> URL {
            environment.storeRoot.appendingPathComponent(
                Self.runDirectoryRelativePath(experimentID: experiment.id, authorityDigest: experiment.authorityDigest),
                isDirectory: true
            )
        }

        func preflight(_ experiment: PromptExperiment) async throws {
            let execution = try Self.resolveExecution(experiment, registry: environment.registry)
            try await environment.preflightWorker(execution.pythonSealValue)
        }

        // MARK: - Runtime boundary

        func submit(
            _ request: PromptExperimentRunRequest,
            progress: @escaping @MainActor @Sendable (String) async -> Void,
            observation: @escaping @MainActor @Sendable (PromptExperimentRuntimeObservation) async -> Void,
            checkpoint: @escaping PromptExperimentCheckpointSink
        ) async throws -> PromptExperimentRuntimeHandle {
            let runID = request.runID
            guard runs[runID] == nil else {
                throw PromptExperimentSubmissionError.rejected("This run already has a runtime submission.")
            }
            let execution: PromptExperimentExecution
            do {
                // The worker preflight ran once in `preflight(_:)`, before the service persisted
                // this run record; it is not repeated here.
                execution = try Self.resolveExecution(request.experiment, registry: environment.registry)
            } catch {
                throw PromptExperimentSubmissionError.rejected(error.localizedDescription)
            }
            let relativeRunDirectory = Self.runDirectoryRelativePath(
                experimentID: execution.experimentID,
                authorityDigest: execution.authorityDigest
            )
            guard runs[runID] == nil, activeRunDirectories.insert(relativeRunDirectory).inserted else {
                throw PromptExperimentSubmissionError.rejected("Another run is already using this experiment's GEPA run directory.")
            }
            let runRoot = environment.storeRoot.appendingPathComponent(relativeRunDirectory, isDirectory: true)
            let ledger: PromptExperimentBudgetLedger
            do {
                ledger = try PromptExperimentBudgetLedger.open(
                    directory: runRoot,
                    authorityDigest: execution.authorityDigest,
                    totalCap: execution.maxEvaluations,
                    heldOutReserve: PromptExperimentBudgetLedger.heldOutReserve(for: execution.suite.cases),
                    calibrationReserve: execution.calibrationEvaluations,
                    gepaStateURL: runRoot.appendingPathComponent("gepa-run/gepa_state.bin"),
                    now: environment.now
                )
            } catch {
                activeRunDirectories.remove(relativeRunDirectory)
                throw PromptExperimentSubmissionError.rejected(error.localizedDescription)
            }
            let invoker = PromptExperimentModelInvoker(
                completer: environment.completer,
                policy: PromptExperimentProviderRetryPolicy(
                    maxRetries: execution.settings.maxProviderRetries,
                    overallTimeoutSeconds: environment.overallProviderTimeoutSeconds
                ),
                checkpoint: checkpoint,
                callbackRootBase: environment.storeRoot
                    .appendingPathComponent("callback-roots", isDirectory: true)
                    .appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true),
                backoffSleep: environment.backoffSleep,
                jitter: environment.jitter
            )
            let harness = ConnectedModelHarness(
                promptID: execution.promptID,
                executionTarget: execution.targets.execution,
                registry: environment.registry,
                invoker: invoker,
                grader: PromptExperimentGrader(
                    grader: execution.suite.grader,
                    judgeTarget: execution.targets.judge
                ),
                checkpoint: checkpoint,
                progress: progress
            )
            let worker = environment.makeWorker()
            let run = ActiveRun(
                runID: runID,
                execution: execution,
                ledger: ledger,
                invoker: invoker,
                harness: harness,
                worker: worker,
                progress: progress,
                checkpoint: checkpoint
            )
            runs[runID] = run
            let layout = GEPAWorkerLayout(
                attemptDirectory: runRoot
                    .appendingPathComponent("runs", isDirectory: true)
                    .appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true),
                relativeAttemptDirectory: "\(relativeRunDirectory)/runs/\(runID.uuidString.lowercased())"
            )
            run.task = Task { @MainActor [self] in
                defer { activeRunDirectories.remove(relativeRunDirectory) }
                do {
                    run.calibration = try await calibrate(run)
                    let workerRequest = Self.makeWorkerRequest(
                        execution: execution,
                        runRoot: runRoot,
                        searchRemaining: ledger.remaining(in: .search),
                        heldOutBaseline: run.calibration.heldOutScores
                    )
                    let completion = try await worker.run(
                        request: workerRequest,
                        pythonSealValue: execution.pythonSealValue,
                        layout: layout,
                        host: { [self] hostRequest in await handleHost(run, hostRequest) },
                        event: { [self] event in try await handleEvent(run, event) },
                        observation: observation
                    )
                    return makeResult(run: run, completion: completion)
                } catch is CancellationError {
                    return runtimeResult(run, .cancelled)
                } catch {
                    return runtimeResult(run, run.cancelled ? .cancelled : .failed(error.localizedDescription))
                }
            }
            let interrupted = ledger.interruptedSettledOnOpen > 0
                ? " \(ledger.interruptedSettledOnOpen) unsettled evaluation(s) from an interrupted run were settled as spent."
                : ""
            await progress("Pinned GEPA \(PromptExperimentGEPAConfiguration.packageVersion) worker admitted; \(ledger.cappedAdmitted)/\(execution.maxEvaluations) approved search evaluations already used.\(interrupted)")
            return PromptExperimentRuntimeHandle(id: runID)
        }

        func wait(for handle: PromptExperimentRuntimeHandle) async -> PromptExperimentRuntimeResult {
            guard let run = runs[handle.id], let task = run.task else {
                return PromptExperimentRuntimeResult(
                    disposition: .failed("The accepted run is no longer registered."),
                    optimization: nil,
                    admissionsAfter: nil,
                    interruptedAdmissionsSettled: 0
                )
            }
            let result = await task.value
            runs.removeValue(forKey: handle.id)
            return result
        }

        func cancel(_ handle: PromptExperimentRuntimeHandle) async -> PromptExperimentCancellationObservation {
            guard let run = runs[handle.id] else { return .alreadySettled }
            run.cancelled = true
            run.worker.cancel()
            run.task?.cancel()
            return .requested
        }

        // MARK: - Host callbacks

        private func handleHost(_ run: ActiveRun, _ request: GEPAWorkerProtocol.HostRequest) async -> GEPAWorkerProtocol.HostReply {
            guard !run.cancelled else { return Self.failureReply(CancellationError()) }
            switch request {
            case let .reflect(prompt):
                do {
                    let completion = try await run.invoker.invoke(
                        target: run.execution.targets.reflection,
                        role: "reflection",
                        systemPrompt: Self.reflectionSystemPrompt,
                        userPrompt: prompt,
                        onRetry: { retry, code, delay in
                            await run.progress("Retrying the reflection call after \(code.rawValue) (retry \(retry)) in \(String(format: "%.1f", delay))s.")
                        }
                    )
                    return .reflected(
                        output: completion.output,
                        promptTokens: completion.promptTokens,
                        completionTokens: completion.completionTokens
                    )
                } catch {
                    return Self.failureReply(error)
                }
            case let .evaluate(evaluation):
                return await evaluate(run, evaluation)
            }
        }

        private func evaluate(_ run: ActiveRun, _ request: GEPAWorkerProtocol.EvaluateRequest) async -> GEPAWorkerProtocol.HostReply {
            guard PromptExperimentDigest.sha256(Data(request.candidate.utf8)) == request.candidateSHA256,
                  let split = PromptExperimentDatasetSplit(rawValue: request.split),
                  let example = run.execution.suite.cases.first(where: { $0.id == request.exampleID && $0.split == split })
            else {
                return .failed(code: nil, message: "GEPA requested an evaluation outside the suite.")
            }
            let result: LedgerEvaluation
            do {
                result = try await admitAndEvaluate(
                    run,
                    candidate: request.candidate,
                    candidateSHA256: request.candidateSHA256,
                    example: example
                )
            } catch {
                return Self.failureReply(error)
            }
            switch result {
            case let .exhausted(pool):
                await run.progress(
                    pool == .heldOut
                        ? "The held-out reporting reserve is used up; remaining held-out scores are reported as unavailable."
                        : "The approved evaluation cap is reached; GEPA stops with its saved incumbent."
                )
                return .budgetExhausted
            case let .recorded(entry, outcome), let .spent(entry, outcome):
                let replayed = if case .recorded = result { true } else { false }
                return .evaluated(.init(
                    evaluationID: entry.evaluationID.uuidString,
                    score: outcome.score,
                    feedback: outcome.proposerFeedback,
                    outputExcerpt: split == .hiddenTest ? nil : outcome.outputExcerpt,
                    replayed: replayed,
                    promptTokens: outcome.usage?.promptTokens,
                    completionTokens: outcome.usage?.completionTokens,
                    searchRemaining: run.ledger.remaining(in: .search)
                ))
            }
        }

        /// The single ledger-admitted evaluation path shared by GEPA callbacks and baseline
        /// calibration: replay a completed logical evaluation, refuse an exhausted pool, or
        /// admit durably, spend, settle, and checkpoint. Throws provider, grading, ledger,
        /// and cancellation failures after settling a spent admission as failed.
        private func admitAndEvaluate(
            _ run: ActiveRun,
            candidate: String,
            candidateSHA256: String,
            example: PromptSuiteCase,
            replicate: Int = 0,
            pool: PromptExperimentBudgetLedger.Pool? = nil
        ) async throws -> LedgerEvaluation {
            let admission = try run.ledger.admit(
                candidateSHA256: candidateSHA256,
                exampleID: example.id,
                split: example.split,
                replicate: replicate,
                pool: pool
            )
            switch admission {
            case let .exhausted(pool):
                return .exhausted(pool)
            case let .recorded(entry):
                guard let outcome = entry.outcome else {
                    throw PromptExperimentBudgetLedger.LedgerError.unreadable("A completed ledger entry has no outcome.")
                }
                run.replayedEvaluations += 1
                return .recorded(entry, outcome)
            case let .admitted(entry):
                run.spentEvaluations += 1
                do {
                    let outcome = try await run.harness.evaluate(
                        candidate: candidate,
                        example: example,
                        evaluationID: entry.evaluationID
                    )
                    let settled = PromptExperimentBudgetLedger.Outcome(
                        score: outcome.score,
                        proposerFeedback: outcome.proposerFeedback,
                        outputExcerpt: example.split == .hiddenTest ? nil : ConnectedModelHarness.outputExcerpt(outcome.output),
                        failureKind: outcome.failureKind,
                        usage: outcome.usage
                    )
                    try run.ledger.settle(entry.evaluationID, outcome: settled)
                    let value = PromptExperimentOptimizationRuntimeEvaluation(
                        candidateIndex: -1,
                        exampleID: example.id,
                        split: example.split,
                        score: outcome.score,
                        feedback: outcome.proposerFeedback,
                        failureKind: outcome.failureKind,
                        output: outcome.output,
                        elapsedSeconds: outcome.elapsedSeconds,
                        usage: outcome.usage
                    )
                    try await run.checkpoint(.evaluation(id: entry.evaluationID, candidate: candidate, value: value))
                    run.evaluations.append(RecordedEvaluation(candidateSHA256: candidateSHA256, value: value))
                    return .spent(entry, settled)
                } catch {
                    if run.ledger.document.entries.contains(where: { $0.evaluationID == entry.evaluationID && $0.state == .admitted }) {
                        try? run.ledger.settle(entry.evaluationID, outcome: nil)
                    }
                    throw error
                }
            }
        }

        // MARK: - Baseline calibration

        /// Seed-only measurements before GEPA starts, charged to the separately approved
        /// calibration line and cached across experiments with the same seed, suite, rubric,
        /// and targets. A cache hit spends nothing. Held-out results are report-only, so a
        /// provider or judge failure (or a spent line) leaves the baseline unavailable instead
        /// of failing the search; ledger failures and cancellation still end the run.
        private func calibrate(_ run: ActiveRun) async throws -> CalibrationResult {
            let execution = run.execution
            let hidden = execution.suite.cases.filter { $0.split == .hiddenTest }
            guard !hidden.isEmpty else { return CalibrationResult(heldOutScores: nil, source: nil) }
            let key = execution.calibrationKey
            if let cached = PromptExperimentCalibrationCache.load(storeRoot: environment.storeRoot, key: key),
               cached.isComplete(for: execution.suite.cases),
               let scores = cached.heldOutScores
            {
                await run.progress("Reusing the cached seed held-out baseline for this seed, suite, rubric, and target set; no calibration evaluations spent.")
                return CalibrationResult(heldOutScores: scores, source: .cache)
            }
            await run.progress("Calibrating the seed baseline: scoring \(hidden.count) held-out case(s) once on the separately approved calibration line.")
            let seedSHA256 = execution.baselineSHA256
            var scores: [String: Double] = [:]
            for example in hidden {
                let result: LedgerEvaluation
                do {
                    result = try await admitAndEvaluate(
                        run,
                        candidate: execution.baseline,
                        candidateSHA256: seedSHA256,
                        example: example,
                        pool: .calibration
                    )
                } catch let failure as PromptExperimentProviderFailure {
                    await run.progress("Seed held-out calibration failed (\(failure.code.rawValue)); the held-out baseline is reported as unavailable.")
                    return CalibrationResult(heldOutScores: nil, source: nil)
                } catch is PromptExperimentGrading.Failure {
                    await run.progress("Seed held-out calibration could not be graded; the held-out baseline is reported as unavailable.")
                    return CalibrationResult(heldOutScores: nil, source: nil)
                }
                switch result {
                case .exhausted:
                    await run.progress("The calibration line is used up; the held-out baseline is reported as unavailable.")
                    return CalibrationResult(heldOutScores: nil, source: nil)
                case let .recorded(_, outcome), let .spent(_, outcome):
                    scores[example.id] = outcome.score
                }
            }
            do {
                try PromptExperimentCalibrationCache.save(
                    PromptExperimentBaselineCalibration(
                        schemaVersion: PromptExperimentBaselineCalibration.schemaVersion,
                        key: key,
                        seedSHA256: seedSHA256,
                        heldOutScores: scores,
                        createdAt: environment.now()
                    ),
                    storeRoot: environment.storeRoot
                )
            } catch {
                await run.progress("The calibration cache could not be saved (\(error.localizedDescription)); later experiments will calibrate again.")
            }
            return CalibrationResult(heldOutScores: scores, source: .calibrated)
        }

        private func handleEvent(_ run: ActiveRun, _ event: GEPAWorkerProtocol.Event) async throws {
            switch event {
            case let .candidate(candidate):
                guard candidate.candidateIndex >= 0,
                      PromptExperimentDigest.sha256(Data(candidate.candidate.utf8)) == candidate.candidateSHA256,
                      candidate.parentIndices.allSatisfy({ $0 >= 0 && $0 < candidate.candidateIndex })
                else {
                    throw PromptExperimentGEPAWorker.WorkerError.protocolFailure("GEPA registered a candidate with invalid identity or lineage.")
                }
                if let existing = run.candidates[candidate.candidateIndex] {
                    guard existing.sha256 == candidate.candidateSHA256 else {
                        throw PromptExperimentGEPAWorker.WorkerError.protocolFailure("GEPA changed the text of a registered candidate index.")
                    }
                    return
                }
                run.candidates[candidate.candidateIndex] = RegisteredCandidate(
                    text: candidate.candidate,
                    sha256: candidate.candidateSHA256
                )
                let score = candidate.aggregateScore.map { String(format: " (validation %.3f)", $0) } ?? ""
                await run.progress("GEPA registered candidate \(candidate.candidateIndex + 1)\(score).")
            case let .evaluation(evaluation):
                await run.progress("Evaluated \(evaluation.split) case \(evaluation.exampleID)\(evaluation.replayed ? " (replayed from the ledger)" : ""); \(run.ledger.cappedAdmitted)/\(run.execution.maxEvaluations) approved search evaluations used.")
            case let .reflection(reflection):
                switch reflection.contract {
                case "envelope":
                    break
                case "missing_envelope", "empty_candidate":
                    await run.progress("A reflection reply had no usable candidate (\(reflection.contract)); GEPA skipped that proposal.")
                default:
                    await run.progress("The reflection reply ignored the candidate envelope; its \(reflection.contract) text was used whole.")
                }
            }
        }

        // MARK: - Settlement

        private func makeResult(run: ActiveRun, completion: GEPAWorkerCompletion) -> PromptExperimentRuntimeResult {
            let terminal = completion.terminal
            guard terminal.engine == "gepa", terminal.upstreamRevision == PromptExperimentGEPAConfiguration.pinnedRevision else {
                return runtimeResult(run, .failed("GEPA completion identity is invalid."))
            }
            guard terminal.hasIncumbent, !terminal.candidates.isEmpty,
                  let best = terminal.bestCandidateIndex
            else {
                return runtimeResult(run, .failed("GEPA reached the approved evaluation budget before saving any incumbent. The run is inconclusive and no winner is reported; scored evidence is retained."))
            }
            let ordered = terminal.candidates.sorted { $0.index < $1.index }
            guard ordered.map(\.index) == Array(0 ..< ordered.count), ordered.indices.contains(best) else {
                return runtimeResult(run, .failed("GEPA candidate indices are not contiguous."))
            }
            var texts: [String] = []
            for candidate in ordered {
                guard let registered = run.candidates[candidate.index], registered.sha256 == candidate.sha256 else {
                    return runtimeResult(run, .failed("GEPA reported candidate \(candidate.index) without registering its text."))
                }
                texts.append(registered.text)
            }
            // Duplicate retained texts share content evidence. An evaluation maps to a GEPA
            // index only when its text belongs to exactly one retained candidate.
            let indicesBySHA = Dictionary(grouping: ordered, by: \.sha256).mapValues { $0.map(\.index) }
            let evaluations = run.evaluations.map { recorded -> PromptExperimentOptimizationRuntimeEvaluation in
                let indices = indicesBySHA[recorded.candidateSHA256] ?? []
                let value = recorded.value
                return PromptExperimentOptimizationRuntimeEvaluation(
                    candidateIndex: indices.count == 1 ? indices[0] : -1,
                    exampleID: value.exampleID,
                    split: value.split,
                    score: value.score,
                    feedback: value.feedback,
                    failureKind: value.failureKind,
                    output: value.output,
                    elapsedSeconds: value.elapsedSeconds,
                    usage: value.usage
                )
            }
            var optimization = PromptExperimentOptimizationRuntimeResult(
                engine: "gepa",
                upstreamRevision: terminal.upstreamRevision,
                baselineScore: terminal.baselineScore,
                bestScore: terminal.bestScore,
                bestCandidateIndex: best,
                candidates: texts,
                parentIndices: ordered.map(\.parentIndices),
                aggregateScores: ordered.map(\.aggregateScore),
                evaluations: evaluations,
                totalEvaluations: run.spentEvaluations,
                wallTimeSeconds: terminal.wallTimeSeconds,
                proposerUsage: terminal.proposerUsage + ",replayed_evaluations=\(run.replayedEvaluations)",
                rawResultJSON: completion.rawResultJSON,
                stopReason: terminal.stopReason,
                heldOut: terminal.heldOut.map {
                    PromptExperimentHeldOutSummary(
                        baselineAverage: $0.baseline?.average,
                        bestAverage: $0.best?.average,
                        baselineSource: $0.baseline == nil ? nil : run.calibration.source
                    )
                },
                stoppedBeforeUnfinishableIteration: terminal.stoppedBeforeUnfinishableIteration
            )
            optimization.candidateUsage = texts.map { Self.candidateUsage(text: $0, ledger: run.ledger) }
            return runtimeResult(run, terminal.stopReason == "budget_exhausted" ? .stoppedBudget : .completed, optimization: optimization)
        }

        /// Averages over every completed evaluation of this exact text on visible splits
        /// (replays included, since the ledger holds the whole experiment).
        static func candidateUsage(text: String, ledger: PromptExperimentBudgetLedger) -> PromptExperimentCandidateUsage? {
            let sha256 = PromptExperimentDigest.sha256(Data(text.utf8))
            let usages = ledger.document.entries.compactMap { entry -> PromptExperimentEvaluationUsage? in
                guard entry.candidateSHA256 == sha256, entry.state == .completed, entry.split != .hiddenTest else { return nil }
                return entry.outcome?.usage
            }
            guard !usages.isEmpty else { return nil }
            return .aggregate(promptCharacters: text.count, usages: usages)
        }

        private func runtimeResult(
            _ run: ActiveRun,
            _ disposition: PromptExperimentRuntimeDisposition,
            optimization: PromptExperimentOptimizationRuntimeResult? = nil
        ) -> PromptExperimentRuntimeResult {
            PromptExperimentRuntimeResult(
                disposition: disposition,
                optimization: optimization,
                admissionsAfter: run.ledger.cappedAdmitted,
                interruptedAdmissionsSettled: run.ledger.interruptedSettledOnOpen,
                calibrationAdmissionsAfter: run.ledger.calibrationAdmitted
            )
        }

        static func failureReply(_ error: Error) -> GEPAWorkerProtocol.HostReply {
            if error is CancellationError {
                return .failed(code: "cancelled", message: "The run was cancelled.")
            }
            if let failure = error as? PromptExperimentProviderFailure {
                return .failed(code: failure.code.rawValue, message: failure.code.safeMessage)
            }
            if let failure = error as? PromptExperimentGrading.Failure {
                return .failed(code: failure.rawValue, message: failure.rawValue)
            }
            if error is PromptExperimentBudgetLedger.LedgerError {
                return .failed(code: "ledger_failure", message: error.localizedDescription)
            }
            return .failed(code: nil, message: error.localizedDescription)
        }
    }
#endif
