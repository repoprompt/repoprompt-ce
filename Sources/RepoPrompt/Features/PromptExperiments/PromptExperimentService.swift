#if DEBUG
    import Combine
    import Foundation

    @MainActor
    protocol PromptExperimentRuntime: AnyObject {
        func preflightOptimization(_ plan: PromptExperimentPlan) async throws
        func submit(
            _ request: PromptExperimentRunRequest,
            progress: @escaping @MainActor @Sendable (String) async -> Void
        ) async throws -> PromptExperimentRuntimeHandle
        func wait(for handle: PromptExperimentRuntimeHandle) async -> PromptExperimentRuntimeResult
        func cancel(_ handle: PromptExperimentRuntimeHandle) async -> PromptExperimentCancellationObservation
    }

    extension PromptExperimentRuntime {
        func preflightOptimization(_ plan: PromptExperimentPlan) async throws {
            guard plan.optimization == nil else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("The configured runtime does not support upstream GEPA optimization.")
            }
        }
    }

    @MainActor
    final class PromptExperimentService: ObservableObject {
        private static var liveInstance: PromptExperimentService?
        static var currentLiveInstance: PromptExperimentService? {
            liveInstance
        }

        static func live(windowState: WindowState) throws -> PromptExperimentService {
            let bindingIdentity = ObjectIdentifier(windowState)
            if let liveInstance {
                guard liveInstance.bindRuntimeIfIdle(
                    NativePromptExperimentContextBuilderRuntime(windowState: windowState),
                    bindingIdentity: bindingIdentity
                ) else {
                    throw PromptExperimentAuthorityError.runtimeUnavailable(
                        "Another window owns the pending or running Prompt Experiment runtime. Wait for it to settle before using this window."
                    )
                }
                return liveInstance
            }
            let service = PromptExperimentService(
                store: PromptExperimentStore(rootURL: PromptExperimentStore.liveRootURL()),
                runtime: NativePromptExperimentContextBuilderRuntime(windowState: windowState)
            )
            service.runtimeBindingIdentity = bindingIdentity
            liveInstance = service
            return service
        }

        @Published private(set) var records: [PromptExperimentRecord] = []
        @Published private(set) var loadError: String?
        @Published private(set) var projectionError: String?
        @Published private(set) var isLoaded = false

        private let store: PromptExperimentStore
        private var runtime: PromptExperimentRuntime
        private let resolveTarget: @MainActor (String) throws -> PromptExperimentResolvedTarget?
        private let listAvailableTargets: @MainActor () -> [PromptExperimentResolvedTarget]
        private let now: @MainActor () -> Date
        private static let pendingApprovalStatus = "Run requested by this Agent session. Review the exact sealed digest below; Approve & Run starts automatically."
        private static let restoredAwaitingApprovalStatus = "Sealed plan is awaiting a new owning-session run request; no native approval is pending."

        private struct PendingRunApproval {
            let planDigest: String
            let controllerSessionID: UUID
            let continuation: CheckedContinuation<PromptExperimentRecord, Error>
        }

        private struct ExecutionWaiter {
            let continuation: CheckedContinuation<Void, Never>
            let timeoutTask: Task<Void, Never>
        }

        private var executionTasks: [UUID: Task<Void, Never>] = [:]
        private var admittedExperimentIDs: Set<UUID> = []
        private var activeHandles: [UUID: PromptExperimentRuntimeHandle] = [:]
        private var pendingRunApprovals: [UUID: PendingRunApproval] = [:]
        private var pendingRunApprovalObservers: [UUID: [CheckedContinuation<Void, Never>]] = [:]
        private var executionWaiters: [UUID: [UUID: ExecutionWaiter]] = [:]
        private var loadTask: Task<Void, Never>?
        private var runtimeBindingIdentity: ObjectIdentifier?

        init(
            store: PromptExperimentStore,
            runtime: PromptExperimentRuntime,
            resolveTarget: @escaping @MainActor (String) throws -> PromptExperimentResolvedTarget? = PromptExperimentService.liveTarget,
            availableTargets: @escaping @MainActor () -> [PromptExperimentResolvedTarget] = PromptExperimentService.liveTargets,
            now: @escaping @MainActor () -> Date = Date.init
        ) {
            self.store = store
            self.runtime = runtime
            self.resolveTarget = resolveTarget
            listAvailableTargets = availableTargets
            self.now = now
        }

        /// A process-global service may serve multiple windows, but an approval request pins the
        /// originating runtime until it either starts or settles. Same-window lookups preserve the
        /// pinned instance; a different window fails closed instead of executing against it.
        @discardableResult
        func bindRuntimeIfIdle(
            _ replacement: PromptExperimentRuntime,
            bindingIdentity: ObjectIdentifier
        ) -> Bool {
            if runtimeBindingIdentity == bindingIdentity { return true }
            guard admittedExperimentIDs.isEmpty, pendingRunApprovals.isEmpty else { return false }
            runtime = replacement
            runtimeBindingIdentity = bindingIdentity
            return true
        }

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
                var loaded = try await store.loadRecords()
                let recoveryDate = now()
                var changed = false
                for index in loaded.indices {
                    if loaded[index].migrateLegacyAttemptLineage() {
                        changed = true
                    }
                    if loaded[index].phase == .awaitingApproval,
                       loaded[index].statusMessage == Self.pendingApprovalStatus
                    {
                        changed = true
                        loaded[index].updatedAt = recoveryDate
                        loaded[index].statusMessage = Self.restoredAwaitingApprovalStatus
                    }
                    guard loaded[index].phase == .running || loaded[index].phase == .cancelling else { continue }
                    changed = true
                    for attemptIndex in loaded[index].attempts.indices {
                        switch loaded[index].attempts[attemptIndex].status {
                        case .submitting, .running:
                            loaded[index].attempts[attemptIndex].status = .submissionUncertain
                            loaded[index].attempts[attemptIndex].statusText = "App restarted before provider settlement; acceptance is uncertain and this attempt will not be retried."
                        case .cancellationRequested:
                            loaded[index].attempts[attemptIndex].status = .cancelledRemoteUnknown
                            loaded[index].attempts[attemptIndex].statusText = "Cancellation was requested before restart; remote settlement is unknown."
                        default:
                            break
                        }
                    }
                    loaded[index].phase = loaded[index].cancellationRequestedAt == nil ? .inconclusive : .cancelled
                    loaded[index].updatedAt = recoveryDate
                    loaded[index].statusMessage = loaded[index].cancellationRequestedAt == nil
                        ? "Reopened with uncertain provider submission; automatic retry is disabled."
                        : "Reopened after cancellation with remote settlement unknown."
                }
                records = loaded.sorted { $0.updatedAt > $1.updatedAt }
                loadError = nil
                isLoaded = true
                if changed {
                    try await persist()
                } else {
                    projectionError = await store.rebuildReadableViews(records).message
                }
            } catch {
                records = []
                isLoaded = false
                loadError = error.localizedDescription
            }
        }

        private func requireLoaded() async throws {
            await load()
            guard isLoaded, loadError == nil else {
                throw PromptExperimentAuthorityError.runtimeUnavailable(
                    loadError ?? "Prompt Experiment storage has not finished loading."
                )
            }
        }

        @discardableResult
        func createExperiment(controllerSessionID: UUID, sourceTabID: UUID) async throws -> UUID {
            try await requireLoaded()
            let date = now()
            let experimentID = UUID()
            let draft = PromptExperimentDraft(
                revision: 1,
                title: "Prompt comparison",
                createdAt: date,
                updatedAt: date
            )
            records.insert(PromptExperimentRecord(
                id: experimentID,
                controllerSessionID: controllerSessionID,
                sourceTabID: sourceTabID,
                createdAt: date,
                updatedAt: date,
                phase: .drafting,
                draft: draft,
                plans: [],
                approvals: [],
                attempts: [],
                cancellationRequestedAt: nil,
                statusMessage: "Draft — edit and seal a fixed synthetic-fixture comparison."
            ), at: 0)
            try await persist()
            return experimentID
        }

        @discardableResult
        func createOptimizationExperiment(controllerSessionID: UUID, sourceTabID: UUID) async throws -> UUID {
            try await requireLoaded()
            let date = now()
            let experimentID = UUID()
            let python = PromptExperimentGEPAWorker.configuredPythonSealValue()
            let draft = PromptExperimentDraft(
                revision: 1,
                title: "GEPA optimization",
                targetRole: "",
                optimization: PromptExperimentOptimizationSpecification(
                    seedCandidate: nil,
                    objective: "",
                    background: "",
                    examples: [],
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
                        adapter: .connectedModel,
                        targetSelector: nil,
                        instructions: "Use the candidate as the governing instructions for this task."
                    ),
                    gepa: PromptExperimentGEPAConfiguration(
                        engine: "gepa",
                        pythonExecutablePath: python,
                        reflectionTargetSelector: "",
                        maxEvaluations: 40,
                        maxWallClockSeconds: 1800,
                        stopAtScore: 1,
                        randomSeed: 0
                    )
                ),
                createdAt: date,
                updatedAt: date
            )
            records.insert(PromptExperimentRecord(
                id: experimentID,
                controllerSessionID: controllerSessionID,
                sourceTabID: sourceTabID,
                createdAt: date,
                updatedAt: date,
                phase: .drafting,
                draft: draft,
                plans: [],
                approvals: [],
                attempts: [],
                cancellationRequestedAt: nil,
                statusMessage: "Draft — the linked Agent session can propose a reviewed dataset, evaluator, targets, and GEPA budget."
            ), at: 0)
            try await persist()
            return experimentID
        }

        @discardableResult
        func updateDraft(
            experimentID: UUID,
            expectedDraftID: UUID,
            expectedDraftVersion: Int,
            expectedDraftDigest: String,
            draft: PromptExperimentDraft,
            expectedControllerSessionID: UUID? = nil
        ) async throws -> PromptExperimentDraft {
            try await requireLoaded()
            let index = try index(of: experimentID)
            try requireOwner(records[index], expectedControllerSessionID: expectedControllerSessionID)
            guard records[index].phase == .drafting, let current = records[index].draft else {
                throw PromptExperimentAuthorityError.illegalPhase("Only the active drafting phase can be updated.")
            }
            guard current.id == expectedDraftID,
                  draft.id == current.id,
                  draft.revision == current.revision,
                  draft.parentPlanID == current.parentPlanID,
                  draft.createdAt == current.createdAt,
                  current.optimisticVersion == expectedDraftVersion
            else {
                throw PromptExperimentAuthorityError.staleDraft
            }
            guard try current.contentDigest() == expectedDraftDigest else {
                throw PromptExperimentAuthorityError.draftDigestMismatch
            }
            var updated = try draft.validatedBounds()
            updated.version = current.optimisticVersion + 1
            updated.updatedAt = now()
            let previousRecord = records[index]
            records[index].draft = updated
            records[index].updatedAt = updated.updatedAt
            records[index].statusMessage = "Draft version \(updated.optimisticVersion) saved; seal again before approval."
            do {
                try await persist()
            } catch {
                restoreRecord(previousRecord)
                throw error
            }
            return updated
        }

        @discardableResult
        func seal(
            experimentID: UUID,
            expectedDraftID: UUID,
            expectedDraftVersion: Int,
            expectedDraftDigest: String,
            expectedControllerSessionID: UUID? = nil,
            authorizedSourceRoots: [String] = []
        ) async throws -> PromptExperimentPlan {
            try await requireLoaded()
            let originalIndex = try index(of: experimentID)
            try requireOwner(records[originalIndex], expectedControllerSessionID: expectedControllerSessionID)
            guard records[originalIndex].phase == .drafting,
                  let draft = records[originalIndex].draft
            else { throw PromptExperimentAuthorityError.noDraft }
            guard draft.id == expectedDraftID,
                  draft.optimisticVersion == expectedDraftVersion
            else { throw PromptExperimentAuthorityError.staleDraft }
            guard try draft.contentDigest() == expectedDraftDigest else {
                throw PromptExperimentAuthorityError.draftDigestMismatch
            }
            let validated = try draft.validated()
            let optimizationTargets: PromptExperimentOptimizationTargets?
            let target: PromptExperimentResolvedTarget
            if let optimization = validated.optimization {
                guard let reflection = try resolveTarget(optimization.gepa.reflectionTargetSelector) else {
                    throw PromptExperimentAuthorityError.targetUnavailable(
                        "No available catalog target resolves the reflection selector ‘\(optimization.gepa.reflectionTargetSelector)’."
                    )
                }
                let execution: PromptExperimentResolvedTarget? = if let selector = optimization.execution.targetSelector {
                    try resolveTarget(selector)
                } else {
                    nil
                }
                if optimization.execution.adapter != .sandboxedCommand, execution == nil {
                    throw PromptExperimentAuthorityError.targetUnavailable(
                        "The \(optimization.execution.adapter.rawValue) execution target is unavailable."
                    )
                }
                let judge: PromptExperimentResolvedTarget? = if let selector = optimization.evaluator.judgeTargetSelector {
                    try resolveTarget(selector)
                } else {
                    nil
                }
                if optimization.evaluator.kind == .connectedModelJudge, judge == nil {
                    throw PromptExperimentAuthorityError.targetUnavailable("The connected-model judge target is unavailable.")
                }
                optimizationTargets = PromptExperimentOptimizationTargets(
                    reflection: reflection,
                    execution: execution,
                    judge: judge
                )
                target = execution ?? reflection
            } else {
                guard let legacyTarget = try resolveTarget(validated.targetRole) else {
                    throw PromptExperimentAuthorityError.targetUnavailable(
                        "No currently available catalog target resolves for selector ‘\(validated.targetRole)’."
                    )
                }
                optimizationTargets = nil
                target = legacyTarget
            }
            let date = now()
            let materialized: (rootURL: URL, files: [PromptExperimentFixtureFile], digest: String)
            if let optimization = validated.optimization {
                let value = try await store.materializeOptimizationEnvironment(
                    experimentID: experimentID,
                    planRevision: validated.revision,
                    project: optimization.projectSnapshot,
                    authorizedSourceRoots: authorizedSourceRoots
                )
                materialized = (value.rootURL, value.files, value.digest)
            } else {
                let value = try await store.materializeSyntheticEnvironment(
                    experimentID: experimentID,
                    planRevision: validated.revision,
                    fixtureText: validated.syntheticFixture
                )
                materialized = (value.rootURL, [value.fixture], value.digest)
            }
            let currentIndex = try index(of: experimentID)
            try requireOwner(records[currentIndex], expectedControllerSessionID: expectedControllerSessionID)
            guard records[currentIndex].phase == .drafting,
                  records[currentIndex].draft == draft
            else { throw PromptExperimentAuthorityError.staleDraft }
            let environment = PromptExperimentEnvironment(
                workspaceID: PromptExperimentDigest.deterministicUUID(
                    namespace: "environment-workspace",
                    value: "\(experimentID.uuidString):\(validated.revision):\(materialized.digest)"
                ),
                sourceTabID: records[currentIndex].sourceTabID,
                capturedAt: date,
                isolatedRootPath: materialized.rootURL.standardizedFileURL.path,
                selection: StoredSelection(selectedPaths: materialized.files.map(\.path)),
                fixtureFiles: materialized.files,
                fixtureDigest: materialized.digest,
                captureLimitations: validated.optimization == nil ? [
                    "Only the reviewed synthetic fixture is available to trial tools.",
                    "The user’s loaded workspace, worktrees, session bindings, and hidden grading data are not attached."
                ] : [
                    "Only explicitly reviewed regular project files were copied into this immutable app-owned snapshot.",
                    "Expected outputs, reviewer notes, and held-out grading data are host-private and are not present in the runtime root.",
                    "Commands receive the copied project read-only and a separate writable scratch directory; the source workspace is never an execution cwd."
                ]
            )
            let plan = try PromptExperimentPlan.seal(
                draft: validated,
                target: target,
                optimizationTargets: optimizationTargets,
                environment: environment,
                at: date
            )
            records[currentIndex].plans.append(plan)
            records[currentIndex].draft = nil
            records[currentIndex].cancellationRequestedAt = nil
            records[currentIndex].phase = .awaitingApproval
            records[currentIndex].updatedAt = date
            records[currentIndex].statusMessage = "Sealed revision \(plan.revision). Review digest \(plan.digest.prefix(12))… and approve in this native view."
            try await persist()
            return plan
        }

        func approve(
            experimentID: UUID,
            displayedDigest: String,
            source: PromptExperimentApprovalActor = .nativeUI,
            expectedControllerSessionID: UUID? = nil
        ) async throws {
            try await requireLoaded()
            let index = try index(of: experimentID)
            try requireOwner(records[index], expectedControllerSessionID: expectedControllerSessionID)
            guard records[index].phase == .awaitingApproval else {
                throw PromptExperimentAuthorityError.illegalPhase("Only a newly sealed plan awaiting approval can be approved.")
            }
            guard let plan = records[index].currentPlan else { throw PromptExperimentAuthorityError.noSealedPlan }
            guard records[index].approval(for: plan) == nil else {
                throw PromptExperimentAuthorityError.illegalPhase("This exact plan is already approved.")
            }
            guard source == .nativeUI else { throw PromptExperimentAuthorityError.approvalRequiresNativeUI }
            guard displayedDigest == plan.digest, plan.verifiesIntegrity() else {
                throw PromptExperimentAuthorityError.digestMismatch
            }
            let date = now()
            records[index].approvals.append(PromptExperimentApproval(
                id: UUID(),
                planID: plan.id,
                planDigest: plan.digest,
                source: source,
                approvedAt: date,
                statement: "I reviewed and approve exactly plan digest \(plan.digest)."
            ))
            records[index].phase = .approved
            records[index].updatedAt = date
            records[index].statusMessage = "Approved locally; starting the exact sealed run."
            try await persist()
        }

        func requestRun(
            experimentID: UUID,
            expectedPlanDigest: String,
            expectedControllerSessionID: UUID
        ) async throws -> PromptExperimentRecord {
            try await requireLoaded()
            let index = try index(of: experimentID)
            try requireOwner(records[index], expectedControllerSessionID: expectedControllerSessionID)
            guard let plan = records[index].currentPlan else { throw PromptExperimentAuthorityError.noSealedPlan }
            guard plan.digest == expectedPlanDigest, plan.verifiesIntegrity() else {
                throw PromptExperimentAuthorityError.digestMismatch
            }

            switch records[index].phase {
            case .approved:
                try await run(
                    experimentID: experimentID,
                    expectedPlanDigest: expectedPlanDigest,
                    expectedControllerSessionID: expectedControllerSessionID
                )
                return try records[self.index(of: experimentID)]
            case .running, .cancelling, .completed, .inconclusive, .cancelled:
                return records[index]
            case .awaitingApproval:
                guard pendingRunApprovals[experimentID] == nil else {
                    throw PromptExperimentAuthorityError.experimentAlreadyRunning
                }
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        if Task.isCancelled {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        guard let currentIndex = records.firstIndex(where: { $0.id == experimentID }),
                              records[currentIndex].phase == .awaitingApproval,
                              records[currentIndex].currentPlan?.digest == expectedPlanDigest
                        else {
                            continuation.resume(throwing: PromptExperimentAuthorityError.digestMismatch)
                            return
                        }
                        pendingRunApprovals[experimentID] = PendingRunApproval(
                            planDigest: expectedPlanDigest,
                            controllerSessionID: expectedControllerSessionID,
                            continuation: continuation
                        )
                        records[currentIndex].statusMessage = Self.pendingApprovalStatus
                        records[currentIndex].updatedAt = now()
                        resumePendingRunApprovalObservers(experimentID: experimentID)
                        Task { @MainActor [weak self] in
                            do {
                                try await self?.persist()
                            } catch {
                                guard let self,
                                      pendingRunApprovals[experimentID]?.planDigest == expectedPlanDigest
                                else { return }
                                resumePendingRunApproval(experimentID: experimentID, result: .failure(error))
                            }
                        }
                    }
                } onCancel: {
                    Task { @MainActor [weak self] in
                        await self?.cancelPendingRunRequest(
                            experimentID: experimentID,
                            expectedPlanDigest: expectedPlanDigest,
                            statusMessage: "Run approval request was cancelled; the sealed plan remains unapproved."
                        )
                    }
                }
            case .drafting:
                throw PromptExperimentAuthorityError.illegalPhase("Seal the reviewed draft before requesting a run.")
            }
        }

        func approveAndRun(
            experimentID: UUID,
            displayedDigest: String,
            source: PromptExperimentApprovalActor = .nativeUI
        ) async throws {
            guard let pending = pendingRunApprovals[experimentID] else {
                throw PromptExperimentAuthorityError.illegalPhase("The owning Agent session must request this exact run before native approval.")
            }
            guard pending.planDigest == displayedDigest else {
                let error = PromptExperimentAuthorityError.digestMismatch
                resumePendingRunApproval(experimentID: experimentID, result: .failure(error))
                throw error
            }
            let expectedOwner = pending.controllerSessionID
            do {
                try await approve(
                    experimentID: experimentID,
                    displayedDigest: displayedDigest,
                    source: source,
                    expectedControllerSessionID: expectedOwner
                )
                try await run(
                    experimentID: experimentID,
                    expectedPlanDigest: displayedDigest,
                    expectedControllerSessionID: expectedOwner
                )
                try resumePendingRunApproval(
                    experimentID: experimentID,
                    result: .success(records[index(of: experimentID)])
                )
            } catch {
                resumePendingRunApproval(experimentID: experimentID, result: .failure(error))
                throw error
            }
        }

        func declineRunAndRevise(
            experimentID: UUID,
            displayedDigest: String,
            source: PromptExperimentApprovalActor = .nativeUI
        ) async throws {
            try await requireLoaded()
            let originalIndex = try index(of: experimentID)
            guard source == .nativeUI else { throw PromptExperimentAuthorityError.approvalRequiresNativeUI }
            guard let pending = pendingRunApprovals[experimentID], pending.planDigest == displayedDigest else {
                throw PromptExperimentAuthorityError.illegalPhase("The owning Agent session must request this exact run before changes can be returned.")
            }
            try requireOwner(records[originalIndex], expectedControllerSessionID: pending.controllerSessionID)
            guard records[originalIndex].phase == .awaitingApproval,
                  let plan = records[originalIndex].currentPlan,
                  plan.digest == displayedDigest,
                  plan.verifiesIntegrity()
            else { throw PromptExperimentAuthorityError.digestMismatch }
            let fixture = if plan.optimization == nil {
                try await store.readSyntheticFixture(environment: plan.environment)
            } else {
                ""
            }
            let index = try index(of: experimentID)
            guard records[index].phase == .awaitingApproval,
                  records[index].currentPlan == plan
            else { throw PromptExperimentAuthorityError.staleDraft }
            let date = now()
            records[index].draft = PromptExperimentDraft(
                revision: plan.revision + 1,
                parentPlanID: plan.id,
                title: plan.title,
                taskInput: plan.taskInput,
                syntheticFixture: fixture,
                originalInstructions: plan.originalInstructions,
                candidateInstructions: plan.candidateInstructions,
                targetRole: plan.resolvedTarget.selector,
                repetitions: plan.repetitions,
                optimization: plan.optimization,
                createdAt: date,
                updatedAt: date
            )
            records[index].phase = .drafting
            records[index].updatedAt = date
            records[index].statusMessage = "The user declined revision \(plan.revision). Continue this conversation to revise the new versioned draft."
            try await persist()
            try resumePendingRunApproval(
                experimentID: experimentID,
                result: .success(records[self.index(of: experimentID)])
            )
        }

        func hasPendingRunApproval(experimentID: UUID, planDigest: String) -> Bool {
            pendingRunApprovals[experimentID]?.planDigest == planDigest
        }

        func waitForPendingRunApprovalForTesting(experimentID: UUID) async {
            if pendingRunApprovals[experimentID] != nil { return }
            await withCheckedContinuation { continuation in
                if pendingRunApprovals[experimentID] != nil {
                    continuation.resume()
                } else {
                    pendingRunApprovalObservers[experimentID, default: []].append(continuation)
                }
            }
        }

        private func resumePendingRunApprovalObservers(experimentID: UUID) {
            let observers = pendingRunApprovalObservers.removeValue(forKey: experimentID) ?? []
            observers.forEach { $0.resume() }
        }

        private func cancelPendingRunRequest(
            experimentID: UUID,
            expectedPlanDigest: String,
            statusMessage: String
        ) async {
            guard let pending = pendingRunApprovals[experimentID],
                  pending.planDigest == expectedPlanDigest
            else { return }
            pendingRunApprovals[experimentID] = nil
            if let index = records.firstIndex(where: { $0.id == experimentID }),
               records[index].phase == .awaitingApproval,
               records[index].currentPlan?.digest == expectedPlanDigest
            {
                records[index].statusMessage = statusMessage
                records[index].updatedAt = now()
                try? await persist()
            }
            pending.continuation.resume(throwing: CancellationError())
        }

        private func resumePendingRunApproval(
            experimentID: UUID,
            result: Result<PromptExperimentRecord, Error>
        ) {
            guard let pending = pendingRunApprovals.removeValue(forKey: experimentID) else { return }
            pending.continuation.resume(with: result)
        }

        func run(
            experimentID: UUID,
            expectedPlanDigest: String? = nil,
            expectedControllerSessionID: UUID? = nil
        ) async throws {
            try await requireLoaded()
            let index = try index(of: experimentID)
            try requireOwner(records[index], expectedControllerSessionID: expectedControllerSessionID)
            guard !admittedExperimentIDs.contains(experimentID) else {
                throw PromptExperimentAuthorityError.experimentAlreadyRunning
            }
            guard records[index].phase == .approved else {
                throw PromptExperimentAuthorityError.illegalPhase("Only an approved, not-yet-run plan can start trials.")
            }
            guard let plan = records[index].currentPlan else { throw PromptExperimentAuthorityError.noSealedPlan }
            if let expectedPlanDigest, expectedPlanDigest != plan.digest {
                throw PromptExperimentAuthorityError.digestMismatch
            }
            guard records[index].approval(for: plan) != nil, plan.verifiesIntegrity() else {
                throw PromptExperimentAuthorityError.planNotApproved
            }
            if plan.optimization != nil {
                guard plan.schemaVersion == PromptExperimentPlan.optimizationSchemaVersion else {
                    throw PromptExperimentAuthorityError.illegalPhase("Earlier optimization schemas are preserved read-only. Clone the result into a current reviewed draft before execution.")
                }
                try await runtime.preflightOptimization(plan)
            }
            guard records[index].attempts(for: plan).isEmpty else {
                throw PromptExperimentAuthorityError.illegalPhase("This immutable plan already has an execution history and cannot be run again.")
            }
            guard admittedExperimentIDs.insert(experimentID).inserted else {
                throw PromptExperimentAuthorityError.experimentAlreadyRunning
            }
            records[index].attempts.append(contentsOf: plan.trials.map { PromptExperimentAttempt(trial: $0, plan: plan) })
            records[index].phase = .running
            records[index].updatedAt = now()
            records[index].statusMessage = plan.optimization == nil
                ? "Running fixed serial comparison (0/\(plan.trials.count))."
                : "Starting pinned upstream GEPA search (0/\(plan.optimization?.gepa.maxEvaluations ?? 0) evaluations)."
            do {
                try await persist()
            } catch {
                admittedExperimentIDs.remove(experimentID)
                if let currentIndex = records.firstIndex(where: { $0.id == experimentID }) {
                    records[currentIndex].attempts.removeAll { $0.planID == plan.id }
                    records[currentIndex].phase = .approved
                }
                throw error
            }
            executionTasks[experimentID] = Task { @MainActor [weak self] in
                await self?.executeSerially(experimentID: experimentID, plan: plan)
            }
        }

        func cancel(
            experimentID: UUID,
            expectedPlanDigest: String? = nil,
            expectedControllerSessionID: UUID? = nil
        ) async throws {
            try await requireLoaded()
            let index = try index(of: experimentID)
            try requireOwner(records[index], expectedControllerSessionID: expectedControllerSessionID)
            if let expectedPlanDigest, records[index].currentPlan?.digest != expectedPlanDigest {
                throw PromptExperimentAuthorityError.digestMismatch
            }
            if records[index].phase == .awaitingApproval, let expectedPlanDigest {
                await cancelPendingRunRequest(
                    experimentID: experimentID,
                    expectedPlanDigest: expectedPlanDigest,
                    statusMessage: "Run approval request cancelled by its owning Agent session; the sealed plan remains unapproved."
                )
                return
            }
            guard records[index].phase == .running || records[index].phase == .cancelling else { return }
            let date = now()
            records[index].phase = .cancelling
            records[index].cancellationRequestedAt = date
            records[index].updatedAt = date
            records[index].statusMessage = "Cancellation requested; waiting for provider settlement."
            var handle: PromptExperimentRuntimeHandle?
            let currentPlanID = records[index].currentPlan?.id
            for attemptIndex in records[index].attempts.indices where records[index].attempts[attemptIndex].planID == currentPlanID {
                if records[index].attempts[attemptIndex].status == .running || records[index].attempts[attemptIndex].status == .submitting {
                    records[index].attempts[attemptIndex].status = .cancellationRequested
                    records[index].attempts[attemptIndex].statusText = "Cancellation requested; settlement pending."
                    records[index].attempts[attemptIndex].cancellationRequestedAt = date
                    handle = activeHandles[records[index].attempts[attemptIndex].id]
                }
            }
            try await persist()
            guard let handle else { return }
            let observation = await runtime.cancel(handle)
            if case let .remoteStateUnknown(message) = observation {
                try await mutate(experimentID: experimentID) { record in
                    if let attemptIndex = record.attempts.firstIndex(where: { $0.id == handle.id }) {
                        record.attempts[attemptIndex].statusText = "Cancellation requested; remote settlement unknown: \(message)"
                    }
                }
            }
        }

        func waitForExecution(
            experimentID: UUID,
            expectedPlanDigest: String,
            expectedControllerSessionID: UUID,
            timeoutSeconds: TimeInterval
        ) async throws -> PromptExperimentRecord {
            try await requireLoaded()
            guard timeoutSeconds.isFinite, timeoutSeconds >= 0, timeoutSeconds <= 3600 else {
                throw PromptExperimentAuthorityError.invalidDraft("timeout_seconds must be between 0 and 3600.")
            }
            var index = try index(of: experimentID)
            try requireOwner(records[index], expectedControllerSessionID: expectedControllerSessionID)
            guard records[index].currentPlan?.digest == expectedPlanDigest else {
                throw PromptExperimentAuthorityError.digestMismatch
            }
            guard records[index].phase == .running || records[index].phase == .cancelling,
                  executionTasks[experimentID] != nil,
                  timeoutSeconds > 0
            else { return records[index] }

            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume()
                        return
                    }
                    guard let currentIndex = records.firstIndex(where: { $0.id == experimentID }),
                          records[currentIndex].phase == .running || records[currentIndex].phase == .cancelling,
                          executionTasks[experimentID] != nil
                    else {
                        continuation.resume()
                        return
                    }
                    let timeoutTask = Task { @MainActor [weak self] in
                        do {
                            try await Task.sleep(for: .seconds(timeoutSeconds))
                        } catch {
                            return
                        }
                        self?.resumeExecutionWaiter(experimentID: experimentID, waiterID: waiterID)
                    }
                    executionWaiters[experimentID, default: [:]][waiterID] = ExecutionWaiter(
                        continuation: continuation,
                        timeoutTask: timeoutTask
                    )
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.resumeExecutionWaiter(experimentID: experimentID, waiterID: waiterID)
                }
            }
            index = try self.index(of: experimentID)
            try requireOwner(records[index], expectedControllerSessionID: expectedControllerSessionID)
            guard records[index].currentPlan?.digest == expectedPlanDigest else {
                throw PromptExperimentAuthorityError.digestMismatch
            }
            return records[index]
        }

        private func resumeExecutionWaiter(experimentID: UUID, waiterID: UUID) {
            guard let waiter = executionWaiters[experimentID]?.removeValue(forKey: waiterID) else { return }
            waiter.timeoutTask.cancel()
            waiter.continuation.resume()
            if executionWaiters[experimentID]?.isEmpty == true {
                executionWaiters[experimentID] = nil
            }
        }

        private func resumeExecutionWaiters(experimentID: UUID) {
            guard let waiters = executionWaiters[experimentID] else { return }
            for waiterID in Array(waiters.keys) {
                resumeExecutionWaiter(experimentID: experimentID, waiterID: waiterID)
            }
        }

        func startNextRevision(
            experimentID: UUID,
            expectedPlanDigest: String? = nil,
            expectedControllerSessionID: UUID? = nil,
            revisionMode: PromptExperimentRevisionMode = .continueBest
        ) async throws {
            try await requireLoaded()
            let originalIndex = try index(of: experimentID)
            try requireOwner(records[originalIndex], expectedControllerSessionID: expectedControllerSessionID)
            guard [.completed, .inconclusive, .cancelled].contains(records[originalIndex].phase) else {
                throw PromptExperimentAuthorityError.illegalPhase("A next revision can only follow a settled experiment run.")
            }
            guard records[originalIndex].draft == nil,
                  let plan = records[originalIndex].currentPlan
            else { throw PromptExperimentAuthorityError.noSealedPlan }
            if let expectedPlanDigest, expectedPlanDigest != plan.digest {
                throw PromptExperimentAuthorityError.digestMismatch
            }
            let recordSnapshot = records[originalIndex]
            let originalPhase = recordSnapshot.phase
            let chosenCandidateReference: PromptExperimentArtifactReference? = try {
                guard plan.optimization != nil else { return nil }
                switch revisionMode {
                case .repeatCurrentSeed:
                    return nil
                case .continueBest, .continueCandidate:
                    guard let result = recordSnapshot.attempts(for: plan).last?.optimizationResult else {
                        throw PromptExperimentAuthorityError.invalidDraft("No settled GEPA candidate evidence is available to continue.")
                    }
                    let desired: Int? = switch revisionMode {
                    case .continueBest: result.bestCandidateIndex
                    case let .continueCandidate(index): index
                    case .repeatCurrentSeed: nil
                    }
                    guard let desired,
                          let reference = result.candidates.first(where: { $0.index == desired })?.candidateEvidence
                    else {
                        throw PromptExperimentAuthorityError.invalidDraft("The selected GEPA candidate is unavailable; no silent seed fallback was applied.")
                    }
                    return reference
                }
            }()
            let fixture = if plan.optimization == nil {
                try await store.readSyntheticFixture(environment: plan.environment)
            } else {
                ""
            }
            let chosenCandidate: String? = if let chosenCandidateReference {
                try await String(data: store.readArtifact(chosenCandidateReference), encoding: .utf8)
            } else {
                nil
            }
            let index = try index(of: experimentID)
            try requireOwner(records[index], expectedControllerSessionID: expectedControllerSessionID)
            guard records[index].phase == originalPhase,
                  records[index].draft == nil,
                  records[index].currentPlan == plan
            else { throw PromptExperimentAuthorityError.staleDraft }
            let date = now()
            var nextOptimization = plan.optimization
            if let chosenCandidate { nextOptimization?.seedCandidate = chosenCandidate }
            records[index].draft = PromptExperimentDraft(
                revision: plan.revision + 1,
                parentPlanID: plan.id,
                title: plan.title,
                taskInput: plan.taskInput,
                syntheticFixture: fixture,
                originalInstructions: plan.originalInstructions,
                candidateInstructions: plan.candidateInstructions,
                targetRole: plan.resolvedTarget.role,
                repetitions: plan.repetitions,
                optimization: nextOptimization,
                createdAt: date,
                updatedAt: date
            )
            records[index].phase = .drafting
            records[index].updatedAt = date
            records[index].statusMessage = "Revision \(plan.revision + 1) draft created; prior plans and evidence remain immutable."
            try await persist()
        }

        @discardableResult
        func cloneExperiment(
            experimentID: UUID,
            expectedControllerSessionID: UUID? = nil
        ) async throws -> UUID {
            try await requireLoaded()
            let sourceIndex = try index(of: experimentID)
            let source = records[sourceIndex]
            try requireOwner(source, expectedControllerSessionID: expectedControllerSessionID)
            guard [.approved, .completed, .inconclusive, .cancelled].contains(source.phase),
                  let plan = source.currentPlan
            else {
                throw PromptExperimentAuthorityError.illegalPhase("Only a sealed or settled experiment can be cloned into a new draft.")
            }
            let date = now()
            let cloneID = UUID()
            let draft = try await PromptExperimentDraft(
                revision: 1,
                title: "\(plan.title) copy",
                taskInput: plan.taskInput,
                syntheticFixture: plan.optimization == nil ? store.readSyntheticFixture(environment: plan.environment) : "",
                originalInstructions: plan.originalInstructions,
                candidateInstructions: plan.candidateInstructions,
                targetRole: plan.resolvedTarget.selector,
                repetitions: plan.repetitions,
                optimization: plan.optimization,
                createdAt: date,
                updatedAt: date
            )
            records.insert(PromptExperimentRecord(
                id: cloneID,
                controllerSessionID: source.controllerSessionID,
                sourceTabID: source.sourceTabID,
                createdAt: date,
                updatedAt: date,
                phase: .drafting,
                draft: draft,
                plans: [],
                approvals: [],
                attempts: [],
                cancellationRequestedAt: nil,
                statusMessage: "Cloned as an unsealed draft. Review and seal a new digest before approval or execution."
            ), at: 0)
            do {
                try await persist()
            } catch {
                records.removeAll { $0.id == cloneID }
                throw error
            }
            return cloneID
        }

        func record(id: UUID) -> PromptExperimentRecord? {
            records.first { $0.id == id }
        }

        func availableTargets() -> [PromptExperimentResolvedTarget] {
            listAvailableTargets()
        }

        func ownedRecords(controllerSessionID: UUID) async throws -> [PromptExperimentRecord] {
            try await requireLoaded()
            return records.filter { $0.controllerSessionID == controllerSessionID }
        }

        func ownedRecord(id: UUID, controllerSessionID: UUID) async throws -> PromptExperimentRecord {
            try await requireLoaded()
            let record = try records[index(of: id)]
            try requireOwner(record, expectedControllerSessionID: controllerSessionID)
            return record
        }

        func readableArtifactText(for record: PromptExperimentRecord) async throws -> [String: String] {
            var references: [PromptExperimentArtifactReference] = []
            for attempt in record.attempts {
                if let prompt = attempt.committedHandoff?.promptEvidence { references.append(prompt) }
                if let assistant = attempt.assistantOutputEvidence { references.append(assistant) }
                if let result = attempt.optimizationResult {
                    references.append(contentsOf: result.candidates.map(\.candidateEvidence))
                    references.append(contentsOf: result.evaluations.compactMap(\.outputEvidence))
                    if let raw = result.rawResultEvidence { references.append(raw) }
                }
            }
            var textByDigest: [String: String] = [:]
            for reference in references where textByDigest[reference.sha256] == nil {
                let data = try await store.readArtifact(reference)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw PromptExperimentAuthorityError.runtimeUnavailable(
                        "Experiment artifact \(reference.sha256) is not valid UTF-8."
                    )
                }
                textByDigest[reference.sha256] = text
            }
            return textByDigest
        }

        func rebuildReadableViews() async throws {
            try await requireLoaded()
            let report = await store.rebuildReadableViews(records)
            projectionError = report.message
        }

        func recordDirectoryURL(experimentID: UUID) async throws -> URL {
            try await store.recordDirectoryURL(experimentID: experimentID)
        }

        func waitForExecutionForTesting(experimentID: UUID) async {
            let task = executionTasks[experimentID]
            await task?.value
        }

        private func executeSerially(experimentID: UUID, plan: PromptExperimentPlan) async {
            defer {
                executionTasks[experimentID] = nil
                admittedExperimentIDs.remove(experimentID)
            }
            for trial in plan.trials {
                guard let recordIndex = records.firstIndex(where: { $0.id == experimentID }),
                      records[recordIndex].cancellationRequestedAt == nil,
                      let attemptIndex = records[recordIndex].attempts.firstIndex(where: { $0.trialID == trial.id })
                else { break }

                let attemptID = records[recordIndex].attempts[attemptIndex].id
                records[recordIndex].attempts[attemptIndex].status = .submitting
                records[recordIndex].attempts[attemptIndex].statusText = "Persisted as submitting; awaiting runtime acceptance."
                records[recordIndex].attempts[attemptIndex].submittedAt = now()
                records[recordIndex].updatedAt = now()
                let request = PromptExperimentRunRequest(
                    experimentID: experimentID,
                    controllerSessionID: records[recordIndex].controllerSessionID,
                    plan: plan,
                    attempt: records[recordIndex].attempts[attemptIndex]
                )
                do {
                    try await persist()
                } catch {
                    markLocalPersistenceFailure(experimentID: experimentID, attemptID: attemptID, message: "Trial was not submitted because its submitting state could not be persisted: \(error.localizedDescription)")
                    break
                }

                let handle: PromptExperimentRuntimeHandle
                do {
                    handle = try await runtime.submit(request) { [weak self] message in
                        guard let self else { return }
                        await updateProgress(experimentID: experimentID, attemptID: trial.id, message: message)
                    }
                } catch let error as PromptExperimentSubmissionError {
                    await settleSubmissionFailure(experimentID: experimentID, attemptID: attemptID, error: error)
                    if case .acceptanceUnknown = error { break }
                    continue
                } catch {
                    await settleSubmissionFailure(
                        experimentID: experimentID,
                        attemptID: attemptID,
                        error: .rejected(error.localizedDescription)
                    )
                    continue
                }

                activeHandles[attemptID] = handle
                guard let currentRecordIndex = records.firstIndex(where: { $0.id == experimentID }),
                      let currentAttemptIndex = records[currentRecordIndex].attempts.firstIndex(where: { $0.id == attemptID })
                else {
                    _ = await runtime.cancel(handle)
                    _ = await runtime.wait(for: handle)
                    activeHandles.removeValue(forKey: attemptID)
                    break
                }
                let cancellationAlreadyRequested = records[currentRecordIndex].cancellationRequestedAt != nil
                records[currentRecordIndex].attempts[currentAttemptIndex].status = cancellationAlreadyRequested
                    ? .cancellationRequested
                    : .running
                records[currentRecordIndex].attempts[currentAttemptIndex].statusText = cancellationAlreadyRequested
                    ? "Accepted after cancellation was requested; forwarding cancellation and awaiting settlement."
                    : "Accepted by existing Context Builder runtime."
                if cancellationAlreadyRequested,
                   records[currentRecordIndex].attempts[currentAttemptIndex].cancellationRequestedAt == nil
                {
                    records[currentRecordIndex].attempts[currentAttemptIndex].cancellationRequestedAt = records[currentRecordIndex].cancellationRequestedAt
                }
                records[currentRecordIndex].attempts[currentAttemptIndex].runtimeLink = PromptExperimentRuntimeLink(
                    adapter: PromptExperimentPlan.executionAdapter,
                    tabID: handle.tabID,
                    runID: handle.runID,
                    provider: plan.resolvedTarget.agentRaw,
                    model: plan.resolvedTarget.modelRaw
                )
                do {
                    try await persist()
                } catch {
                    _ = await runtime.cancel(handle)
                    _ = await runtime.wait(for: handle)
                    activeHandles.removeValue(forKey: attemptID)
                    markLocalPersistenceFailure(
                        experimentID: experimentID,
                        attemptID: attemptID,
                        message: "Runtime accepted the trial, but local acceptance persistence failed. Cancellation was requested and terminal settlement was drained: \(error.localizedDescription)"
                    )
                    break
                }
                if cancellationAlreadyRequested {
                    _ = await runtime.cancel(handle)
                }

                let result = await runtime.wait(for: handle)
                activeHandles.removeValue(forKey: attemptID)
                do {
                    try await settle(experimentID: experimentID, attemptID: attemptID, result: result)
                } catch {
                    markLocalPersistenceFailure(
                        experimentID: experimentID,
                        attemptID: attemptID,
                        message: "Runtime settled, but evidence or settlement persistence failed: \(error.localizedDescription)"
                    )
                    break
                }
            }
            await finishExperiment(experimentID: experimentID)
        }

        private func markLocalPersistenceFailure(experimentID: UUID, attemptID: UUID, message: String) {
            loadError = message
            guard let recordIndex = records.firstIndex(where: { $0.id == experimentID }),
                  let attemptIndex = records[recordIndex].attempts.firstIndex(where: { $0.id == attemptID })
            else { return }
            records[recordIndex].attempts[attemptIndex].status = .localPersistenceFailed
            records[recordIndex].attempts[attemptIndex].statusText = message
            records[recordIndex].attempts[attemptIndex].error = message
            records[recordIndex].phase = .inconclusive
            records[recordIndex].statusMessage = message
            records[recordIndex].updatedAt = now()
        }

        private func settle(experimentID: UUID, attemptID: UUID, result: PromptExperimentRuntimeResult) async throws {
            let committedHandoff: PromptExperimentCommittedHandoff? = if let handoff = result.committedHandoff {
                try await PromptExperimentCommittedHandoff(
                    promptEvidence: store.installArtifact(Data(handoff.prompt.utf8)),
                    promptPreview: String(handoff.prompt.prefix(400)),
                    selection: handoff.selection,
                    selectionRevision: handoff.selectionRevision,
                    usedAgentOutputAsPrompt: handoff.usedAgentOutputAsPrompt
                )
            } else {
                nil
            }
            let assistantOutputEvidence: PromptExperimentArtifactReference? = if let assistantOutput = result.assistantOutput {
                try await store.installArtifact(Data(assistantOutput.utf8))
            } else {
                nil
            }
            let optimizationResult = try await installOptimizationResult(result.optimizationResult)
            try await mutate(experimentID: experimentID) { record in
                guard let index = record.attempts.firstIndex(where: { $0.id == attemptID }) else { return }
                let cancelled = record.attempts[index].cancellationRequestedAt != nil || record.cancellationRequestedAt != nil
                record.attempts[index].runtimeLink = result.runtimeLink
                record.attempts[index].fixtureDigestBefore = result.fixtureDigestBefore
                record.attempts[index].fixtureDigestAfter = result.fixtureDigestAfter
                record.attempts[index].committedHandoff = committedHandoff
                record.attempts[index].assistantOutputEvidence = assistantOutputEvidence
                record.attempts[index].assistantOutputPreview = result.assistantOutput.map { String($0.prefix(400)) }
                record.attempts[index].handoffUnavailableReason = result.handoffUnavailableReason
                record.attempts[index].optimizationResult = optimizationResult
                record.attempts[index].settledAt = now()
                record.attempts[index].lateResultAfterCancellation = cancelled
                if cancelled {
                    record.attempts[index].status = .cancelledSettled
                    record.attempts[index].statusText = "Provider settled after cancellation was requested; committed handoff and assistant output are retained when available, but not scored."
                } else if result.fixtureDigestBefore != record.plan(for: record.attempts[index])?.environment.fixtureDigest
                    || result.fixtureDigestAfter != result.fixtureDigestBefore
                {
                    record.attempts[index].status = .failed
                    record.attempts[index].statusText = "Synthetic fixture digest was not sealed or changed during the run; attempt disqualified."
                    record.attempts[index].error = "Fixture digest mismatch"
                } else {
                    switch result.disposition {
                    case .completed where committedHandoff == nil && optimizationResult == nil:
                        let message = result.handoffUnavailableReason ?? "Context Builder completion did not include an immutable committed handoff."
                        record.attempts[index].status = .failed
                        record.attempts[index].statusText = "Committed handoff unavailable; attempt is inconclusive: \(message)"
                        record.attempts[index].error = message
                    case .completed:
                        record.attempts[index].status = .completed
                        record.attempts[index].statusText = "Completed with immutable committed prompt and final selection evidence."
                    case let .failed(message):
                        record.attempts[index].status = .failed
                        record.attempts[index].statusText = "Runtime failed: \(message)"
                        record.attempts[index].error = message
                    case .cancelled:
                        record.attempts[index].status = .cancelledSettled
                        record.attempts[index].statusText = "Provider confirmed cancellation."
                    }
                }
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
                    isBest: index == runtime.bestCandidateIndex
                ))
            }
            var evaluations: [PromptExperimentEvaluationEvidence] = []
            for (index, evaluation) in runtime.evaluations.enumerated() {
                let scoreIdentity = evaluation.score.map { String($0) } ?? "unavailable"
                let outputEvidence: PromptExperimentArtifactReference? = if let output = evaluation.output {
                    try await store.installArtifact(Data(output.utf8), fileExtension: "txt")
                } else {
                    nil
                }
                evaluations.append(PromptExperimentEvaluationEvidence(
                    id: PromptExperimentDigest.deterministicUUID(
                        namespace: "gepa-evaluation",
                        value: "\(evaluation.candidateIndex):\(evaluation.exampleID):\(index):\(scoreIdentity)"
                    ),
                    candidateIndex: evaluation.candidateIndex,
                    exampleID: evaluation.exampleID,
                    split: evaluation.split,
                    score: evaluation.score,
                    feedback: evaluation.feedback,
                    failureKind: evaluation.failureKind,
                    outputEvidence: outputEvidence,
                    elapsedSeconds: evaluation.elapsedSeconds
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
                runDirectoryRelativePath: runtime.runDirectoryRelativePath,
                rawResultEvidence: rawResultEvidence
            )
        }

        private func settleSubmissionFailure(
            experimentID: UUID,
            attemptID: UUID,
            error: PromptExperimentSubmissionError
        ) async {
            try? await mutate(experimentID: experimentID) { record in
                guard let index = record.attempts.firstIndex(where: { $0.id == attemptID }) else { return }
                record.attempts[index].settledAt = now()
                record.attempts[index].error = error.localizedDescription
                switch error {
                case let .rejected(message):
                    record.attempts[index].status = .failed
                    record.attempts[index].statusText = "Submission rejected before acceptance: \(message)"
                case let .acceptanceUnknown(message):
                    record.attempts[index].status = .submissionUncertain
                    record.attempts[index].statusText = "Submission acceptance uncertain; automatic retry disabled: \(message)"
                }
            }
        }

        private func finishExperiment(experimentID: UUID) async {
            defer { resumeExecutionWaiters(experimentID: experimentID) }
            guard loadError == nil else { return }
            try? await mutate(experimentID: experimentID) { record in
                guard let plan = record.currentPlan else { return }
                let currentAttempts = record.attempts(for: plan)
                if record.cancellationRequestedAt != nil {
                    record.phase = .cancelled
                    record.statusMessage = "Cancelled. Requested and settled/unknown states remain visible per attempt."
                } else if !currentAttempts.isEmpty, currentAttempts.allSatisfy({ $0.status == .completed }) {
                    record.phase = .completed
                    if let result = currentAttempts.last?.optimizationResult {
                        let best = result.bestScore.map { String($0) } ?? "unavailable"
                        let baseline = result.baselineScore.map { String($0) } ?? "unavailable"
                        record.statusMessage = "GEPA complete: \(result.totalEvaluations) evaluations; best \(best) vs baseline \(baseline). Applying a winner requires separate approval."
                    } else {
                        record.statusMessage = "Fixed serial comparison complete. Review outputs; no automatic winner or promotion is computed."
                    }
                } else {
                    record.phase = .inconclusive
                    record.statusMessage = "Comparison inconclusive. Failures and uncertain submissions were not retried."
                }
            }
        }

        private func updateProgress(experimentID: UUID, attemptID: UUID, message: String) async {
            try? await mutate(experimentID: experimentID) { record in
                guard let index = record.attempts.firstIndex(where: { $0.trialID == attemptID }) else { return }
                record.attempts[index].statusText = message
            }
        }

        private func mutate(
            experimentID: UUID,
            body: (inout PromptExperimentRecord) -> Void
        ) async throws {
            let index = try index(of: experimentID)
            body(&records[index])
            records[index].updatedAt = now()
            try await persist()
        }

        private func restoreRecord(_ record: PromptExperimentRecord) {
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index] = record
            } else {
                records.append(record)
            }
            records.sort { $0.updatedAt > $1.updatedAt }
        }

        private func index(of experimentID: UUID) throws -> Int {
            guard let index = records.firstIndex(where: { $0.id == experimentID }) else {
                throw PromptExperimentAuthorityError.experimentNotFound
            }
            return index
        }

        private func requireOwner(
            _ record: PromptExperimentRecord,
            expectedControllerSessionID: UUID?
        ) throws {
            guard let expectedControllerSessionID else { return }
            guard record.controllerSessionID == expectedControllerSessionID else {
                throw PromptExperimentAuthorityError.ownerMismatch
            }
        }

        private func persist() async throws {
            records.sort { $0.updatedAt > $1.updatedAt }
            let report = try await store.saveRecords(records)
            projectionError = report.message
        }

        private static func liveTarget(selector: String) throws -> PromptExperimentResolvedTarget? {
            try PromptExperimentTargetCatalog.resolve(selector)
        }

        private static func liveTargets() -> [PromptExperimentResolvedTarget] {
            PromptExperimentTargetCatalog.availableTargets()
        }
    }
#endif
