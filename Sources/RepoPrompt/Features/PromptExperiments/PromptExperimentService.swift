#if DEBUG
    import Combine
    import Foundation

    /// The execution seam the service drives. `GEPARunController` is the live implementation.
    @MainActor
    protocol PromptExperimentRuntime: AnyObject {
        func preflight(_ experiment: PromptExperiment) async throws
        func submit(
            _ request: PromptExperimentRunRequest,
            progress: @escaping @MainActor @Sendable (String) async -> Void,
            observation: @escaping @MainActor @Sendable (PromptExperimentRuntimeObservation) async -> Void,
            checkpoint: @escaping PromptExperimentCheckpointSink
        ) async throws -> PromptExperimentRuntimeHandle
        func wait(for handle: PromptExperimentRuntimeHandle) async -> PromptExperimentRuntimeResult
        func cancel(_ handle: PromptExperimentRuntimeHandle) async -> PromptExperimentCancellationObservation
        func runDirectoryURL(for experiment: PromptExperiment) -> URL
    }

    /// Typed create/update input. Nil fields keep the updated experiment's value, or use the
    /// server default for a new experiment.
    struct PromptExperimentCreateRequest: Equatable {
        var experimentID: UUID?
        var title: String?
        var promptID: String?
        var suiteID: String?
        var executionTarget: String?
        var reflectionTarget: String?
        var judgeTarget: String?
        var maxEvaluations: Int?
        var reflectionMinibatchSize: Int?
        var maxProviderRetries: Int?
        var randomSeed: Int?
        var promptCharacterCeilingRatio: Double?
        var maxPromptCharacters: Int?
        var noiseFloorReplicates: Int?
    }

    struct PromptExperimentTargetDefaults: Equatable {
        let execution: PromptExperimentResolvedTarget?
        let reflection: PromptExperimentResolvedTarget?
        let judge: PromptExperimentResolvedTarget?
    }

    /// Owns experiments, approval, runs, and persistence for the whole app (not a window).
    ///
    /// It is the store's single writer. Approvals, run admissions, and scored evidence are
    /// durable commits before they take effect; worker diagnostics and progress are batched
    /// into throttled saves. Only native UI calls `approve`; there is no MCP approval path.
    @MainActor
    final class PromptExperimentService: ObservableObject {
        static let defaultExecutionRole = "engineer"
        static let defaultReflectionRole = "design"
        static let defaultJudgeRole = "pair"

        @Published private(set) var experiments: [PromptExperiment] = []
        @Published private(set) var loadError: String?
        @Published private(set) var persistenceError: String?
        @Published private(set) var projectionError: String?
        @Published private(set) var isLoaded = false
        @Published private(set) var discardedLegacyLabData = false

        private let store: PromptExperimentStore
        private let runtime: PromptExperimentRuntime
        private let patchProposer: PromptPatchProposer
        private let registry: BuiltInPromptRegistry
        private let resolveTarget: @MainActor (String) throws -> PromptExperimentResolvedTarget
        private let listTargets: @MainActor () -> [PromptExperimentResolvedTarget]
        private let pythonSealValue: @MainActor () -> String
        private let now: @MainActor () -> Date
        private let diagnosticsSaveInterval: Duration

        private struct ActiveRun {
            let experimentID: UUID
            let runID: UUID
            let suite: PromptSuite
            var handle: PromptExperimentRuntimeHandle?
        }

        private var loadTask: Task<Void, Never>?
        private var activeRun: ActiveRun?
        private var executionTasks: [UUID: Task<Void, Never>] = [:]
        private var isSaving = false
        private var saveWaiters: [CheckedContinuation<Void, Never>] = []
        private var pendingDiagnosticsSave: Task<Void, Never>?
        private var changeWaiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]

        init(
            store: PromptExperimentStore,
            runtime: PromptExperimentRuntime,
            registry: BuiltInPromptRegistry = AppDomainRuntimeComposition.shared.builtInPromptRegistry,
            patchProposer: PromptPatchProposer = PromptPatchProposer(),
            resolveTarget: @escaping @MainActor (String) throws -> PromptExperimentResolvedTarget = { try PromptExperimentTargetCatalog.resolve($0) },
            availableTargets: @escaping @MainActor () -> [PromptExperimentResolvedTarget] = { PromptExperimentTargetCatalog.availableTargets() },
            pythonSealValue: @escaping @MainActor () -> String = { PromptExperimentGEPAWorker.configuredPythonSealValue() },
            now: @escaping @MainActor () -> Date = Date.init,
            diagnosticsSaveInterval: Duration = .seconds(2)
        ) {
            self.store = store
            self.runtime = runtime
            self.registry = registry
            self.patchProposer = patchProposer
            self.resolveTarget = resolveTarget
            listTargets = availableTargets
            self.pythonSealValue = pythonSealValue
            self.now = now
            self.diagnosticsSaveInterval = diagnosticsSaveInterval
        }

        // MARK: - Loading

        func load() async {
            if let loadTask {
                await loadTask.value
                return
            }
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await performInitialLoad()
            }
            loadTask = task
            await task.value
        }

        private func performInitialLoad() async {
            do {
                let loaded = try await store.load()
                discardedLegacyLabData = loaded.discardedLegacyLabData
                var experiments = loaded.experiments
                var changed = false
                let recoveredAt = now()
                for experimentIndex in experiments.indices {
                    for runIndex in experiments[experimentIndex].runs.indices
                        where experiments[experimentIndex].runs[runIndex].state.isActive
                    {
                        // The worker and provider calls died with the previous process. Their
                        // admissions stay spent; an explicit run settles them and resumes.
                        changed = true
                        experiments[experimentIndex].runs[runIndex].state = .failed
                        experiments[experimentIndex].runs[runIndex].uncertainRemoteSettlement = true
                        experiments[experimentIndex].runs[runIndex].settledAt = recoveredAt
                        experiments[experimentIndex].runs[runIndex].statusText = "Interrupted by an app restart; provider settlement is unknown. Its checkpoint is retained; run again to resume within the remaining budget."
                        experiments[experimentIndex].runs[runIndex].gradings = experiments[experimentIndex].runs[runIndex].gradings.map { $0.settlingCancellation() }
                        if var diagnostics = experiments[experimentIndex].runs[runIndex].diagnostics {
                            diagnostics.processObservation = .unknownAfterRestart
                            diagnostics.activeCallbackID = nil
                            diagnostics.activeCallbackOperation = nil
                            diagnostics.append(.init(observedAt: recoveredAt, channel: "service", event: "service_restarted", detail: nil))
                            experiments[experimentIndex].runs[runIndex].diagnostics = diagnostics
                        }
                        experiments[experimentIndex].updatedAt = recoveredAt
                    }
                }
                self.experiments = experiments
                isLoaded = true
                if changed {
                    try await persist(projecting: Set(experiments.map(\.id)))
                }
            } catch {
                loadError = error.localizedDescription
                isLoaded = true
            }
        }

        private func requireLoaded() async throws {
            await load()
            if let loadError { throw PromptExperimentAuthorityError.runtimeUnavailable(loadError) }
        }

        func experiment(id: UUID) -> PromptExperiment? {
            experiments.first { $0.id == id }
        }

        private func index(of id: UUID) throws -> Int {
            guard let index = experiments.firstIndex(where: { $0.id == id }) else {
                throw PromptExperimentAuthorityError.experimentNotFound
            }
            return index
        }

        // MARK: - Targets

        func availableTargets() -> [PromptExperimentResolvedTarget] {
            listTargets()
        }

        /// The default judge never shares the reflection model: a judge that grades the
        /// reflector's own proposals rewards its style (self-preference) instead of the rubric.
        func targetDefaults() -> PromptExperimentTargetDefaults {
            let reflection = defaultTarget(role: Self.defaultReflectionRole)
            return PromptExperimentTargetDefaults(
                execution: defaultTarget(role: Self.defaultExecutionRole),
                reflection: reflection,
                judge: defaultJudge(distinctFrom: reflection)
            )
        }

        private func defaultJudge(distinctFrom reflection: PromptExperimentResolvedTarget?) -> PromptExperimentResolvedTarget? {
            guard let reflection else { return defaultTarget(role: Self.defaultJudgeRole) }
            let preferred = [Self.defaultJudgeRole, Self.defaultExecutionRole, "explore"].compactMap { try? resolveTarget($0) }
            return (preferred + listTargets()).first {
                PromptExperimentConnectedModelRunner.supportsPromptOnlyCallbacks($0)
                    && $0.canonicalSelectionID != reflection.canonicalSelectionID
            }
        }

        private func defaultTarget(role: String) -> PromptExperimentResolvedTarget? {
            if let resolved = try? resolveTarget(role), PromptExperimentConnectedModelRunner.supportsPromptOnlyCallbacks(resolved) {
                return resolved
            }
            return listTargets().first(where: PromptExperimentConnectedModelRunner.supportsPromptOnlyCallbacks)
        }

        // MARK: - Create / update

        /// Validates every field and reports all problems together. An unapproved experiment is
        /// updated in place; changing an approved experiment's authority creates a new
        /// experiment (superseding it) that needs its own approval.
        func createOrUpdate(_ request: PromptExperimentCreateRequest) async throws -> PromptExperiment {
            try await requireLoaded()
            let base = try request.experimentID.map { try experiments[index(of: $0)] }
            var errors: [PromptExperimentFieldError] = []

            var promptID = base?.authority.promptID
            if let raw = request.promptID?.trimmingCharacters(in: .whitespacesAndNewlines) {
                promptID = BuiltInPromptID(rawValue: raw)
                if promptID == nil {
                    errors.append(.init(field: "prompt_id", message: "Unknown built-in prompt '\(raw)'. Choose one of: \(BuiltInPromptID.allCases.map(\.rawValue).joined(separator: ", "))."))
                }
            } else if promptID == nil {
                errors.append(.init(field: "prompt_id", message: "Required: the built-in prompt to optimize."))
            }

            var resource: BuiltInPromptResource?
            var suite: PromptSuite?
            if let promptID {
                do { resource = try registry.resource(promptID) } catch {
                    errors.append(.init(field: "prompt_id", message: error.localizedDescription))
                }
                do {
                    let loaded = try PromptSuiteLoader.load(promptID: promptID, registry: registry)
                    let requestedSuite = request.suiteID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let requestedSuite, requestedSuite != loaded.suiteID {
                        errors.append(.init(field: "suite_id", message: "Unknown suite '\(requestedSuite)' for '\(promptID.rawValue)'; the checked-in suite is '\(loaded.suiteID)'."))
                    } else {
                        suite = loaded
                    }
                } catch {
                    errors.append(.init(field: "suite_id", message: "The checked-in suite for '\(promptID.rawValue)' is unavailable: \(error.localizedDescription)"))
                }
            }

            let defaults = targetDefaults()
            func target(_ field: String, _ selector: String?, current: PromptExperimentResolvedTarget?, fallback: PromptExperimentResolvedTarget?) -> PromptExperimentResolvedTarget? {
                if let selector = selector?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    do { return try resolveTarget(selector) } catch {
                        errors.append(.init(field: field, message: error.localizedDescription))
                        return nil
                    }
                }
                if let current { return current }
                if fallback == nil {
                    errors.append(.init(field: field, message: "No available prompt-only target; choose one from targets."))
                }
                return fallback
            }
            let execution = target("execution_target", request.executionTarget, current: base?.authority.targets.execution, fallback: defaults.execution)
            let reflection = target("reflection_target", request.reflectionTarget, current: base?.authority.targets.reflection, fallback: defaults.reflection)
            var judge: PromptExperimentResolvedTarget?
            if let suite {
                if suite.grader.kind == .modelJudge {
                    // A changed reflection model re-derives a distinct default judge.
                    let fallback = defaults.judge?.canonicalSelectionID == reflection?.canonicalSelectionID
                        ? defaultJudge(distinctFrom: reflection)
                        : defaults.judge
                    let current = base?.authority.targets.judge.flatMap {
                        $0.canonicalSelectionID == reflection?.canonicalSelectionID ? nil : $0
                    }
                    judge = target("judge_target", request.judgeTarget, current: current, fallback: fallback)
                    if let judge, let reflection, judge.canonicalSelectionID == reflection.canonicalSelectionID {
                        errors.append(.init(field: "judge_target", message: "The judge model must differ from the reflection model (\(reflection.displayName)); a model grading its own proposals favors its own style."))
                    }
                } else if request.judgeTarget != nil {
                    errors.append(.init(field: "judge_target", message: "Suite '\(suite.suiteID)' is graded by exact match; omit judge_target."))
                }
            }

            var settings = base?.authority.settings ?? PromptExperimentGEPASettings()
            func bounded(_ field: String, _ value: Int?, _ range: ClosedRange<Int>, _ apply: (Int) -> Void) {
                guard let value else { return }
                guard range.contains(value) else {
                    errors.append(.init(field: field, message: "Must be between \(range.lowerBound) and \(range.upperBound)."))
                    return
                }
                apply(value)
            }
            bounded("reflection_minibatch_size", request.reflectionMinibatchSize, 1 ... 100) { settings.reflectionMinibatchSize = $0 }
            bounded("max_provider_retries", request.maxProviderRetries, 0 ... 3) { settings.maxProviderRetries = $0 }
            bounded("random_seed", request.randomSeed, 0 ... Int(Int32.max)) { settings.randomSeed = $0 }
            bounded("max_prompt_characters", request.maxPromptCharacters, 200 ... 200_000) { settings.maxPromptCharacters = $0 }
            bounded("noise_floor_replicates", request.noiseFloorReplicates, 0 ... 5) { settings.noiseFloorReplicates = $0 }
            if let ratio = request.promptCharacterCeilingRatio {
                if ratio.isFinite, (0.25 ... 4.0).contains(ratio) {
                    settings.promptCharacterCeilingRatio = ratio
                } else {
                    errors.append(.init(field: "prompt_character_ceiling_ratio", message: "Must be between 0.25 and 4.0."))
                }
            }

            let maxEvaluations = request.maxEvaluations ?? base?.authority.maxEvaluations
            if let maxEvaluations {
                if !(1 ... 10000).contains(maxEvaluations) {
                    errors.append(.init(field: "max_evaluations", message: "Must be between 1 and 10000."))
                } else if let suite {
                    let minimum = PromptExperimentBudgetLedger.minimumApprovableEvaluations(
                        cases: suite.cases, reflectionMinibatchSize: settings.reflectionMinibatchSize
                    )
                    if maxEvaluations < minimum {
                        errors.append(.init(field: "max_evaluations", message: "Must be at least \(minimum) for suite '\(suite.suiteID)': the seed's validation pass, one mutation-and-validation cycle, and the held-out reserve."))
                    }
                }
            } else {
                errors.append(.init(field: "max_evaluations", message: "Required: the total evaluation cap the user will approve."))
            }

            if let execution, let reflection {
                errors += PromptExperimentConnectedModelRunner.targetErrors(
                    PromptExperimentTargets(execution: execution, reflection: reflection, judge: judge)
                ).map { PromptExperimentFieldError(field: "\($0.field)_target", message: $0.message) }
            }
            let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? base?.title
            if let title, title.isEmpty || title.count > 200 {
                errors.append(.init(field: "title", message: "Must be 1-200 characters."))
            }

            guard errors.isEmpty, let promptID, let resource, let suite, let execution, let reflection, let maxEvaluations else {
                throw PromptExperimentAuthorityError.validation(errors)
            }
            let authority = PromptExperimentAuthority(
                promptID: promptID,
                promptResourceSHA256: resource.sha256,
                suiteID: suite.suiteID,
                suiteSHA256: suite.suiteSHA256,
                rubricSHA256: suite.grader.rubric?.sha256,
                targets: PromptExperimentTargets(execution: execution, reflection: reflection, judge: judge),
                settings: settings,
                maxEvaluations: maxEvaluations,
                calibrationEvaluations: PromptExperimentBudgetLedger.calibrationEvaluations(
                    cases: suite.cases, replicates: settings.noiseFloorReplicates
                ),
                pythonSealValue: pythonSealValue(),
                gepaRevision: PromptExperimentGEPAConfiguration.pinnedRevision
            )
            let digest = try authority.digest()
            let date = now()
            let resolvedTitle = title ?? "Optimize \(promptID.rawValue)"

            if let base, base.isApproved || !base.runs.isEmpty {
                if digest == base.authorityDigest {
                    guard resolvedTitle != base.title else { return base }
                    let position = try index(of: base.id)
                    experiments[position].title = resolvedTitle
                    experiments[position].updatedAt = date
                    try await persist(projecting: [base.id])
                    return experiments[position]
                }
                let successor = PromptExperiment(
                    id: UUID(), title: resolvedTitle, createdAt: date, updatedAt: date,
                    authority: authority, authorityDigest: digest, supersedes: base.id,
                    approvalRequest: nil, approval: nil, runs: [], proposals: []
                )
                experiments.append(successor)
                try await persist(projecting: [successor.id])
                return successor
            }
            if let base {
                let position = try index(of: base.id)
                experiments[position].title = resolvedTitle
                if experiments[position].authorityDigest != digest {
                    experiments[position].authority = authority
                    experiments[position].authorityDigest = digest
                    experiments[position].approvalRequest = nil
                }
                experiments[position].updatedAt = date
                try await persist(projecting: [base.id])
                notifyChange(base.id)
                return experiments[position]
            }
            let created = PromptExperiment(
                id: UUID(), title: resolvedTitle, createdAt: date, updatedAt: date,
                authority: authority, authorityDigest: digest, supersedes: nil,
                approvalRequest: nil, approval: nil, runs: [], proposals: []
            )
            experiments.append(created)
            try await persist(projecting: [created.id])
            return created
        }

        // MARK: - Approval

        /// Surfaces the native approval card. It never approves; only `approve` (native UI) can.
        func requestApproval(experimentID: UUID, expectedAuthorityDigest: String?) async throws -> PromptExperiment {
            try await requireLoaded()
            let position = try index(of: experimentID)
            let experiment = experiments[position]
            guard !experiment.isApproved else { throw PromptExperimentAuthorityError.alreadyApproved }
            if let expectedAuthorityDigest, expectedAuthorityDigest != experiment.authorityDigest {
                throw PromptExperimentAuthorityError.authorityChanged
            }
            _ = try GEPARunController.resolveExecution(experiment, registry: registry)
            experiments[position].approvalRequest = PromptExperimentApprovalRequest(
                authorityDigest: experiment.authorityDigest,
                requestedAt: now()
            )
            experiments[position].updatedAt = now()
            try await persist(projecting: [experimentID])
            notifyChange(experimentID)
            return experiments[position]
        }

        /// Native-only approval of the exact authority shown, then the first run starts.
        func approve(experimentID: UUID, authorityDigest: String) async throws {
            try await requireLoaded()
            let position = try index(of: experimentID)
            let experiment = experiments[position]
            guard !experiment.isApproved else { throw PromptExperimentAuthorityError.alreadyApproved }
            guard let request = experiment.approvalRequest else { throw PromptExperimentAuthorityError.approvalNotRequested }
            guard request.authorityDigest == authorityDigest, experiment.authorityDigest == authorityDigest else {
                throw PromptExperimentAuthorityError.authorityChanged
            }
            experiments[position].approval = PromptExperimentApproval(authorityDigest: authorityDigest, approvedAt: now())
            experiments[position].approvalRequest = nil
            experiments[position].updatedAt = now()
            try await persist(projecting: [experimentID])
            notifyChange(experimentID)
            _ = try await run(experimentID: experimentID)
        }

        func decline(experimentID: UUID) async throws {
            try await requireLoaded()
            let position = try index(of: experimentID)
            guard experiments[position].approvalRequest != nil else { throw PromptExperimentAuthorityError.approvalNotRequested }
            experiments[position].approvalRequest = nil
            experiments[position].updatedAt = now()
            try await persist(projecting: [experimentID])
            notifyChange(experimentID)
        }

        // MARK: - Runs

        /// Starts (or resumes) an approved experiment within its remaining approved budget.
        func run(experimentID: UUID) async throws -> PromptExperiment {
            try await requireLoaded()
            var position = try index(of: experimentID)
            let experiment = experiments[position]
            guard experiment.isApproved else { throw PromptExperimentAuthorityError.notApproved }
            guard activeRun == nil else { throw PromptExperimentAuthorityError.runActive }
            let used = max(
                experiment.admissionsUsed,
                PromptExperimentBudgetLedger.peekCappedAdmitted(directory: runtime.runDirectoryURL(for: experiment))
            )
            guard used < experiment.authority.maxEvaluations else { throw PromptExperimentAuthorityError.budgetExhausted }
            let execution = try GEPARunController.resolveExecution(experiment, registry: registry)
            do {
                try await runtime.preflight(experiment)
            } catch {
                throw PromptExperimentAuthorityError.runtimeUnavailable(error.localizedDescription)
            }
            guard activeRun == nil else { throw PromptExperimentAuthorityError.runActive }
            position = try index(of: experimentID)
            let runID = UUID()
            let date = now()
            let runRecord = PromptExperimentRun(
                id: runID,
                ordinal: experiments[position].runs.count + 1,
                runDirectoryRelativePath: GEPARunController.runDirectoryRelativePath(
                    experimentID: experimentID, authorityDigest: experiment.authorityDigest
                ),
                createdAt: date,
                state: .queued,
                statusText: "Queued; starting the pinned GEPA worker.",
                admissionsBefore: used,
                interruptedAdmissionsSettled: 0,
                uncertainRemoteSettlement: false,
                diagnostics: .initial(at: date),
                modelCalls: [],
                evaluations: [],
                gradings: [],
                result: nil
            )
            experiments[position].runs.append(runRecord)
            experiments[position].updatedAt = date
            activeRun = ActiveRun(experimentID: experimentID, runID: runID, suite: execution.suite)
            do {
                try await persist(projecting: [experimentID])
            } catch {
                activeRun = nil
                throw error
            }

            let handle: PromptExperimentRuntimeHandle
            do {
                handle = try await runtime.submit(
                    PromptExperimentRunRequest(experiment: experiments[index(of: experimentID)], runID: runID),
                    progress: { [weak self] message in self?.recordProgress(experimentID: experimentID, runID: runID, message: message) },
                    observation: { [weak self] value in self?.recordObservation(experimentID: experimentID, runID: runID, value) },
                    checkpoint: { [weak self] value in
                        guard let self else { throw PromptExperimentAuthorityError.runtimeUnavailable("The experiment service is unavailable.") }
                        try await persistCheckpoint(experimentID: experimentID, runID: runID, value: value)
                    }
                )
            } catch {
                activeRun = nil
                try? mutateRun(experimentID: experimentID, runID: runID) { run in
                    run.state = .failed
                    run.settledAt = now()
                    run.error = error.localizedDescription
                    run.statusText = "The run was rejected before any evaluation: \(error.localizedDescription)"
                }
                try? await persist(projecting: [experimentID])
                notifyChange(experimentID)
                throw PromptExperimentAuthorityError.runtimeUnavailable(error.localizedDescription)
            }
            activeRun?.handle = handle
            try? mutateRun(experimentID: experimentID, runID: runID) { run in
                run.state = .running
                run.startedAt = now()
                if run.statusText.hasPrefix("Queued") { run.statusText = "Running pinned upstream GEPA." }
            }
            if activeRun?.runID == runID, self.experiment(id: experimentID)?.runs.last?.cancellationRequestedAt != nil {
                _ = await runtime.cancel(handle)
            }
            try await persist(projecting: [experimentID])
            notifyChange(experimentID)
            executionTasks[runID] = Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await runtime.wait(for: handle)
                await settle(experimentID: experimentID, runID: runID, result: result)
            }
            return try experiments[index(of: experimentID)]
        }

        func cancel(experimentID: UUID) async throws -> PromptExperiment {
            try await requireLoaded()
            let position = try index(of: experimentID)
            guard let active = activeRun, active.experimentID == experimentID else {
                return experiments[position]
            }
            try mutateRun(experimentID: experimentID, runID: active.runID) { run in
                if run.cancellationRequestedAt == nil { run.cancellationRequestedAt = now() }
                run.statusText = "Cancellation requested; waiting for this run's provider calls to settle."
            }
            try await persist(projecting: [experimentID])
            if let handle = active.handle { _ = await runtime.cancel(handle) }
            notifyChange(experimentID)
            return try experiments[index(of: experimentID)]
        }

        /// Returns immediately for a zero timeout; otherwise waits until the experiment's
        /// approval or run state changes, or the timeout elapses.
        func statusOrWait(experimentID: UUID, timeoutSeconds: TimeInterval) async throws -> PromptExperiment {
            try await requireLoaded()
            _ = try index(of: experimentID)
            if timeoutSeconds > 0 {
                let waiterID = UUID()
                let timeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    self?.resumeWaiter(experimentID: experimentID, waiterID: waiterID)
                }
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        changeWaiters[experimentID, default: [:]][waiterID] = continuation
                    }
                } onCancel: {
                    Task { @MainActor [weak self] in self?.resumeWaiter(experimentID: experimentID, waiterID: waiterID) }
                }
                timeout.cancel()
            }
            return try experiments[index(of: experimentID)]
        }

        func waitForSettlementForTesting(experimentID: UUID) async {
            for (runID, task) in executionTasks where experiment(id: experimentID)?.runs.contains(where: { $0.id == runID }) == true {
                await task.value
            }
        }

        private func resumeWaiter(experimentID: UUID, waiterID: UUID) {
            changeWaiters[experimentID]?.removeValue(forKey: waiterID)?.resume()
        }

        private func notifyChange(_ experimentID: UUID) {
            let waiters = changeWaiters.removeValue(forKey: experimentID) ?? [:]
            for continuation in waiters.values {
                continuation.resume()
            }
        }

        private func settle(experimentID: UUID, runID: UUID, result: PromptExperimentRuntimeResult) async {
            defer {
                executionTasks.removeValue(forKey: runID)
                if activeRun?.runID == runID { activeRun = nil }
                notifyChange(experimentID)
            }
            let installed: PromptExperimentOptimizationResult?
            do {
                installed = try await installOptimizationResult(result.optimization)
            } catch {
                installed = nil
                persistenceError = "Run evidence could not be installed: \(error.localizedDescription)"
            }
            try? mutateRun(experimentID: experimentID, runID: runID) { run in
                run.settledAt = now()
                run.admissionsAfter = result.admissionsAfter
                run.calibrationAdmissions = result.calibrationAdmissionsAfter
                run.interruptedAdmissionsSettled = result.interruptedAdmissionsSettled
                run.result = installed
                switch result.disposition {
                case .completed:
                    run.state = .completed
                    run.statusText = installed?.assessment ?? "Completed."
                case .stoppedBudget:
                    run.state = .stoppedBudget
                    run.statusText = installed?.assessment ?? "Stopped at the approved evaluation budget."
                case let .failed(message):
                    run.state = .failed
                    run.error = message
                    run.statusText = "Failed: \(message)"
                case .cancelled:
                    run.state = .cancelled
                    run.statusText = "Cancelled; this run's provider calls were cancelled."
                    run.gradings = run.gradings.map { $0.settlingCancellation() }
                }
            }
            do {
                try await persist(projecting: [experimentID])
            } catch {
                persistenceError = error.localizedDescription
            }
        }

        private func installOptimizationResult(
            _ runtime: PromptExperimentOptimizationRuntimeResult?
        ) async throws -> PromptExperimentOptimizationResult? {
            guard let runtime else { return nil }
            let rawResultEvidence = try await store.installArtifact(runtime.rawResultJSON, fileExtension: "json")
            var candidates: [PromptExperimentCandidateEvidence] = []
            for (index, candidate) in runtime.candidates.enumerated() {
                let evidence = try await store.installArtifact(Data(candidate.utf8), fileExtension: "txt")
                candidates.append(PromptExperimentCandidateEvidence(
                    id: PromptExperimentDigest.deterministicUUID(namespace: "gepa-candidate", value: "\(evidence.sha256):\(index)"),
                    index: index,
                    parentIndices: index < runtime.parentIndices.count ? runtime.parentIndices[index] : [],
                    candidateEvidence: evidence,
                    candidatePreview: String(candidate.prefix(600)),
                    aggregateScore: index < runtime.aggregateScores.count ? runtime.aggregateScores[index] : nil,
                    isBaseline: index == 0,
                    isBest: index == runtime.bestCandidateIndex,
                    usage: index < runtime.candidateUsage.count ? runtime.candidateUsage[index] : nil
                ))
            }
            var evaluations: [PromptExperimentEvaluationEvidence] = []
            for (index, evaluation) in runtime.evaluations.enumerated() {
                let outputEvidence: PromptExperimentArtifactReference? = if let output = evaluation.output {
                    try await store.installArtifact(Data(output.utf8), fileExtension: "txt")
                } else {
                    nil
                }
                evaluations.append(PromptExperimentEvaluationEvidence(
                    id: PromptExperimentDigest.deterministicUUID(
                        namespace: "gepa-result-evaluation",
                        value: "\(evaluation.candidateIndex):\(evaluation.exampleID):\(index)"
                    ),
                    candidateIndex: evaluation.candidateIndex,
                    exampleID: evaluation.exampleID,
                    split: evaluation.split,
                    score: evaluation.score,
                    feedback: evaluation.feedback,
                    failureKind: evaluation.failureKind,
                    outputEvidence: outputEvidence,
                    elapsedSeconds: evaluation.elapsedSeconds,
                    usage: evaluation.usage
                ))
            }
            return PromptExperimentOptimizationResult(
                engine: runtime.engine,
                upstreamRevision: runtime.upstreamRevision,
                baselineScore: runtime.baselineScore,
                bestScore: runtime.bestScore,
                bestCandidateIndex: runtime.bestCandidateIndex,
                candidates: candidates,
                evaluations: evaluations,
                totalEvaluations: runtime.totalEvaluations,
                wallTimeSeconds: runtime.wallTimeSeconds,
                proposerUsage: runtime.proposerUsage,
                rawResultEvidence: rawResultEvidence,
                stopReason: runtime.stopReason,
                heldOut: runtime.heldOut,
                stoppedBeforeUnfinishableIteration: runtime.stoppedBeforeUnfinishableIteration,
                noiseFloor: runtime.noiseFloor
            )
        }

        // MARK: - Evidence (durable)

        private func persistCheckpoint(experimentID: UUID, runID: UUID, value: PromptExperimentCheckpoint) async throws {
            guard let active = activeRun, active.experimentID == experimentID, active.runID == runID,
                  let experiment = experiment(id: experimentID),
                  let run = experiment.runs.first(where: { $0.id == runID }), run.state.isActive
            else { throw PromptExperimentAuthorityError.runtimeUnavailable("Checkpoint no longer belongs to an active run.") }
            switch value {
            case let .modelCall(call):
                let targets = experiment.authority.targets
                let expected: PromptExperimentResolvedTarget? = switch call.role {
                case "execution": targets.execution
                case "reflection": targets.reflection
                case "judge": targets.judge
                default: nil
                }
                guard call.target == expected,
                      call.state == .completed || (call.promptTokens == nil && call.completionTokens == nil),
                      call.state != .started || run.cancellationRequestedAt == nil
                else { throw PromptExperimentAuthorityError.runtimeUnavailable("Invalid model-call checkpoint.") }
                if let old = run.modelCalls.first(where: { $0.id == call.id }) {
                    guard old.state == .started, call.state != .started else {
                        throw PromptExperimentAuthorityError.runtimeUnavailable("Conflicting model-call checkpoint.")
                    }
                } else if call.state != .started {
                    throw PromptExperimentAuthorityError.runtimeUnavailable("Model completion has no recorded invocation.")
                }
                try mutateRun(experimentID: experimentID, runID: runID) { run in
                    if let i = run.modelCalls.firstIndex(where: { $0.id == call.id }) { run.modelCalls[i] = call } else { run.modelCalls.append(call) }
                }
            case let .evaluation(id, candidate, evaluation):
                guard active.suite.cases.contains(where: { $0.id == evaluation.exampleID && $0.split == evaluation.split }),
                      !candidate.isEmpty,
                      evaluation.score.map({ $0.isFinite && $0 >= active.suite.grader.scoreRange.min && $0 <= active.suite.grader.scoreRange.max }) == true,
                      evaluation.failureKind != .infrastructure
                else { throw PromptExperimentAuthorityError.runtimeUnavailable("Evaluation checkpoint is outside the suite.") }
                guard !run.evaluations.contains(where: { $0.id == id }) else { return }
                let candidateRef = try await store.installArtifact(Data(candidate.utf8))
                let outputRef: PromptExperimentArtifactReference? = if let output = evaluation.output {
                    try await store.installArtifact(Data(output.utf8))
                } else { nil }
                try mutateRun(experimentID: experimentID, runID: runID) { run in
                    run.evaluations.append(PromptExperimentScoredEvaluation(id: id, candidateEvidence: candidateRef, evaluation: .init(
                        id: id, candidateIndex: evaluation.candidateIndex, exampleID: evaluation.exampleID,
                        split: evaluation.split, score: evaluation.score, feedback: evaluation.feedback,
                        failureKind: evaluation.failureKind, outputEvidence: outputRef, elapsedSeconds: evaluation.elapsedSeconds,
                        usage: evaluation.usage
                    )))
                }
            case let .grading(value):
                guard active.suite.cases.contains(where: { $0.id == value.exampleID && $0.split == value.split }),
                      active.suite.grader.kind == .modelJudge,
                      (1 ... 2).contains(value.ordinal)
                else { throw PromptExperimentAuthorityError.runtimeUnavailable("Invalid grading checkpoint.") }
                let candidateRef = try await store.installArtifact(Data(value.candidate.utf8))
                let outputRef = try await store.installArtifact(Data(value.output.utf8))
                // Judge responses can contain reference answers: kept host-private.
                let responseRef: PromptExperimentArtifactReference? = if let response = value.response {
                    try await store.installArtifact(Data(response.utf8))
                } else { nil }
                try mutateRun(experimentID: experimentID, runID: runID) { run in
                    let old = run.gradings.first { $0.id == value.id }
                    var history = old?.history ?? []
                    if value.state != .pending {
                        history.append(.init(ordinal: value.ordinal, state: value.state, responseEvidence: responseRef))
                    }
                    let evidence = PromptExperimentGradingEvidence(
                        id: value.id, exampleID: value.exampleID, split: value.split,
                        candidateEvidence: candidateRef, outputEvidence: outputRef,
                        ordinal: value.ordinal, state: value.state, history: history
                    )
                    if let i = run.gradings.firstIndex(where: { $0.id == value.id }) { run.gradings[i] = evidence } else { run.gradings.append(evidence) }
                }
            }
            try await persist()
        }

        // MARK: - Diagnostics (throttled)

        private func recordProgress(experimentID: UUID, runID: UUID, message: String) {
            try? mutateRun(experimentID: experimentID, runID: runID) { run in
                guard run.state.isActive else { return }
                run.statusText = message
                run.diagnostics?.latestProgress = message
            }
            scheduleDiagnosticsSave()
        }

        private func recordObservation(experimentID: UUID, runID: UUID, _ observation: PromptExperimentRuntimeObservation) {
            let date = now()
            try? mutateRun(experimentID: experimentID, runID: runID) { run in
                var diagnostics = run.diagnostics ?? .initial(at: date)
                switch observation {
                case let .workerPrepared(stderr, stdout):
                    diagnostics.stderrLogRelativePath = stderr
                    diagnostics.stdoutProtocolLogRelativePath = stdout
                    diagnostics.append(.init(observedAt: date, channel: "worker", event: "prepared", detail: nil))
                case let .workerStarted(pid, identity):
                    diagnostics.processObservation = .runningObserved
                    diagnostics.workerPID = pid
                    diagnostics.workerProcessIdentity = identity
                    diagnostics.processStartedAt = date
                    diagnostics.append(.init(observedAt: date, channel: "worker", event: "started", detail: "pid=\(pid)"))
                case let .workerLaunchFailed(message):
                    diagnostics.processObservation = .launchFailed
                    diagnostics.append(.init(observedAt: date, channel: "worker", event: "launch_failed", detail: message))
                case let .workerExited(status, stderrBytes, stderrTruncated, protocolBytes, protocolTruncated):
                    diagnostics.processObservation = .exitedObserved
                    diagnostics.processExitedAt = date
                    diagnostics.processExitStatus = status
                    diagnostics.stderrLogByteCount = stderrBytes
                    diagnostics.stderrLogTruncated = stderrTruncated
                    diagnostics.protocolLogByteCount = protocolBytes
                    diagnostics.protocolLogTruncated = protocolTruncated
                    diagnostics.append(.init(observedAt: date, channel: "worker", event: "exited", detail: "status=\(status)"))
                case let .protocolEvent(channel, event, detail):
                    diagnostics.append(.init(observedAt: date, channel: channel, event: event, detail: detail))
                case let .callbackStarted(id, operation):
                    diagnostics.activeCallbackID = id
                    diagnostics.activeCallbackOperation = operation
                case let .callbackFinished(id, _):
                    if diagnostics.activeCallbackID == id {
                        diagnostics.activeCallbackID = nil
                        diagnostics.activeCallbackOperation = nil
                    }
                }
                run.diagnostics = diagnostics
            }
            scheduleDiagnosticsSave()
        }

        private func scheduleDiagnosticsSave() {
            guard pendingDiagnosticsSave == nil else { return }
            let interval = diagnosticsSaveInterval
            pendingDiagnosticsSave = Task { @MainActor [weak self] in
                try? await Task.sleep(for: interval)
                guard let self else { return }
                pendingDiagnosticsSave = nil
                try? await persist()
            }
        }

        // MARK: - Persistence (single writer)

        private func mutateRun(experimentID: UUID, runID: UUID, _ update: (inout PromptExperimentRun) throws -> Void) throws {
            let position = try index(of: experimentID)
            guard let runIndex = experiments[position].runs.firstIndex(where: { $0.id == runID }) else {
                throw PromptExperimentAuthorityError.experimentNotFound
            }
            try update(&experiments[position].runs[runIndex])
            experiments[position].updatedAt = now()
        }

        /// Saves the current in-memory state. Saves are serialized; each snapshots state after
        /// acquiring the gate, so it includes every mutation made before it was requested.
        private func persist(projecting projected: Set<UUID> = []) async throws {
            await acquireSaveGate()
            defer { releaseSaveGate() }
            do {
                let report = try await store.save(experiments, projecting: projected)
                persistenceError = nil
                if report.message != nil || !projected.isEmpty { projectionError = report.message }
            } catch {
                persistenceError = error.localizedDescription
                throw error
            }
        }

        private func acquireSaveGate() async {
            guard isSaving else {
                isSaving = true
                return
            }
            await withCheckedContinuation { saveWaiters.append($0) }
        }

        private func releaseSaveGate() {
            if saveWaiters.isEmpty {
                isSaving = false
            } else {
                saveWaiters.removeFirst().resume()
            }
        }

        /// Agents may select a retained GEPA index; only native UI may apply or reject it.
        func proposePatch(experimentID: UUID, runID: UUID, candidateIndex: Int) async throws -> PromptExperimentProposal {
            try await requireLoaded()
            let position = try index(of: experimentID)
            let experiment = experiments[position]
            guard let run = experiment.runs.first(where: { $0.id == runID }),
                  run.state == .completed || run.state == .stoppedBudget,
                  let candidate = run.result?.candidates.first(where: { $0.index == candidateIndex })
            else {
                throw PromptExperimentAuthorityError.validation([.init(field: "candidate_index", message: "Choose a retained candidate from a completed or stopped-budget run.")])
            }
            let data = try await store.readArtifact(candidate.candidateEvidence)
            let diff = try patchProposer.proposedDiff(
                promptID: experiment.authority.promptID,
                baselineSHA256: experiment.authority.promptResourceSHA256,
                candidate: data
            )
            let diffReference = try await store.installArtifact(Data(diff.utf8), fileExtension: "diff")
            let proposal = PromptExperimentProposal(
                id: UUID(), runID: runID, candidateIndex: candidateIndex,
                baselineResourceSHA256: experiment.authority.promptResourceSHA256,
                candidateEvidence: candidate.candidateEvidence, diffEvidence: diffReference,
                state: .proposed, createdAt: now(), decidedAt: nil
            )
            experiments[position].proposals.append(proposal)
            experiments[position].updatedAt = now()
            try await persist(projecting: [experimentID])
            return proposal
        }

        func applyProposal(experimentID: UUID, proposalID: UUID) async throws {
            try await decideProposal(experimentID: experimentID, proposalID: proposalID, apply: true)
        }

        func rejectProposal(experimentID: UUID, proposalID: UUID) async throws {
            try await decideProposal(experimentID: experimentID, proposalID: proposalID, apply: false)
        }

        private func decideProposal(experimentID: UUID, proposalID: UUID, apply: Bool) async throws {
            try await requireLoaded()
            let position = try index(of: experimentID)
            guard let proposalIndex = experiments[position].proposals.firstIndex(where: { $0.id == proposalID }),
                  experiments[position].proposals[proposalIndex].state == .proposed
            else {
                throw PromptExperimentAuthorityError.validation([.init(field: "proposal_id", message: "Choose a pending proposal.")])
            }
            if apply {
                let proposal = experiments[position].proposals[proposalIndex]
                let candidate = try await store.readArtifact(proposal.candidateEvidence)
                try patchProposer.apply(
                    promptID: experiments[position].authority.promptID,
                    baselineSHA256: proposal.baselineResourceSHA256,
                    candidate: candidate
                )
            }
            experiments[position].proposals[proposalIndex].state = apply ? .applied : .rejected
            experiments[position].proposals[proposalIndex].decidedAt = now()
            experiments[position].updatedAt = now()
            try await persist(projecting: [experimentID])
        }

        func readArtifactText(_ reference: PromptExperimentArtifactReference) async -> String? {
            guard let data = try? await store.readArtifact(reference) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        func recordDirectoryURL(experimentID: UUID) async -> URL {
            await store.recordDirectoryURL(experimentID: experimentID)
        }
    }
#endif
