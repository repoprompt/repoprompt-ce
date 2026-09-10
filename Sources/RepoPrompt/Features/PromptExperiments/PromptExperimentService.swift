#if DEBUG
    import Combine
    import Foundation

    @MainActor
    protocol PromptExperimentRuntime: AnyObject {
        func submit(
            _ request: PromptExperimentRunRequest,
            progress: @escaping @MainActor @Sendable (String) async -> Void
        ) async throws -> PromptExperimentRuntimeHandle
        func wait(for handle: PromptExperimentRuntimeHandle) async -> PromptExperimentRuntimeResult
        func cancel(_ handle: PromptExperimentRuntimeHandle) async -> PromptExperimentCancellationObservation
    }

    @MainActor
    final class PromptExperimentService: ObservableObject {
        private static var liveInstance: PromptExperimentService?

        static func live(windowState: WindowState) -> PromptExperimentService {
            if let liveInstance {
                liveInstance.bindRuntime(windowState: windowState)
                return liveInstance
            }
            let service = PromptExperimentService(
                store: PromptExperimentStore(rootURL: PromptExperimentStore.liveRootURL()),
                runtime: NativePromptExperimentContextBuilderRuntime(windowState: windowState)
            )
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
        private var executionTasks: [UUID: Task<Void, Never>] = [:]
        private var admittedExperimentIDs: Set<UUID> = []
        private var activeHandles: [UUID: PromptExperimentRuntimeHandle] = [:]
        private var loadTask: Task<Void, Never>?

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

        func bindRuntime(windowState: WindowState) {
            guard admittedExperimentIDs.isEmpty else { return }
            runtime = NativePromptExperimentContextBuilderRuntime(windowState: windowState)
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
            records[index].draft = updated
            records[index].updatedAt = updated.updatedAt
            records[index].statusMessage = "Draft version \(updated.optimisticVersion) saved; seal again before approval."
            try await persist()
            return updated
        }

        @discardableResult
        func seal(
            experimentID: UUID,
            expectedDraftID: UUID,
            expectedDraftVersion: Int,
            expectedDraftDigest: String,
            expectedControllerSessionID: UUID? = nil
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
            guard let target = try resolveTarget(validated.targetRole) else {
                throw PromptExperimentAuthorityError.targetUnavailable(
                    "No currently available catalog target resolves for selector ‘\(validated.targetRole)’."
                )
            }
            let date = now()
            let materialized = try await store.materializeSyntheticEnvironment(
                experimentID: experimentID,
                planRevision: validated.revision,
                fixtureText: validated.syntheticFixture
            )
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
                selection: StoredSelection(selectedPaths: [materialized.fixture.path]),
                fixtureFiles: [materialized.fixture],
                fixtureDigest: materialized.digest,
                captureLimitations: [
                    "Only the reviewed synthetic fixture is available to trial tools.",
                    "The user’s loaded workspace, worktrees, session bindings, and hidden grading data are not attached.",
                    "Loaded-workspace experiments are unsupported and fail closed in this pilot."
                ]
            )
            let plan = try PromptExperimentPlan.seal(draft: validated, target: target, environment: environment, at: date)
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
            source: PromptExperimentApprovalActor = .nativeUI
        ) async throws {
            try await requireLoaded()
            let index = try index(of: experimentID)
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
            records[index].statusMessage = "Approved locally. No trial runs until Run is pressed."
            try await persist()
        }

        func run(experimentID: UUID) async throws {
            try await requireLoaded()
            let index = try index(of: experimentID)
            guard !admittedExperimentIDs.contains(experimentID) else {
                throw PromptExperimentAuthorityError.experimentAlreadyRunning
            }
            guard records[index].phase == .approved else {
                throw PromptExperimentAuthorityError.illegalPhase("Only an approved, not-yet-run plan can start trials.")
            }
            guard let plan = records[index].currentPlan else { throw PromptExperimentAuthorityError.noSealedPlan }
            guard records[index].approval(for: plan) != nil, plan.verifiesIntegrity() else {
                throw PromptExperimentAuthorityError.planNotApproved
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
            records[index].statusMessage = "Running fixed serial comparison (0/\(plan.trials.count))."
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

        func cancel(experimentID: UUID) async throws {
            try await requireLoaded()
            let index = try index(of: experimentID)
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

        func startNextRevision(
            experimentID: UUID,
            expectedPlanDigest: String? = nil,
            expectedControllerSessionID: UUID? = nil
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
            let originalPhase = records[originalIndex].phase
            let fixture = try await store.readSyntheticFixture(environment: plan.environment)
            let index = try index(of: experimentID)
            try requireOwner(records[index], expectedControllerSessionID: expectedControllerSessionID)
            guard records[index].phase == originalPhase,
                  records[index].draft == nil,
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
                targetRole: plan.resolvedTarget.role,
                repetitions: plan.repetitions,
                createdAt: date,
                updatedAt: date
            )
            records[index].phase = .drafting
            records[index].updatedAt = date
            records[index].statusMessage = "Revision \(plan.revision + 1) draft created; prior plans and evidence remain immutable."
            try await persist()
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
                    case .completed where committedHandoff == nil:
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
            guard loadError == nil else { return }
            try? await mutate(experimentID: experimentID) { record in
                guard let plan = record.currentPlan else { return }
                let currentAttempts = record.attempts(for: plan)
                if record.cancellationRequestedAt != nil {
                    record.phase = .cancelled
                    record.statusMessage = "Cancelled. Requested and settled/unknown states remain visible per attempt."
                } else if !currentAttempts.isEmpty, currentAttempts.allSatisfy({ $0.status == .completed }) {
                    record.phase = .completed
                    record.statusMessage = "Fixed serial comparison complete. Review outputs; no automatic winner or promotion is computed."
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
