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

        private let store: PromptExperimentStore
        private var runtime: PromptExperimentRuntime
        private let resolveTarget: @MainActor (String) -> PromptExperimentResolvedTarget?
        private let now: @MainActor () -> Date
        private var executionTasks: [UUID: Task<Void, Never>] = [:]
        private var admittedExperimentIDs: Set<UUID> = []
        private var activeHandles: [UUID: PromptExperimentRuntimeHandle] = [:]
        private var hasLoaded = false

        init(
            store: PromptExperimentStore,
            runtime: PromptExperimentRuntime,
            resolveTarget: @escaping @MainActor (String) -> PromptExperimentResolvedTarget? = PromptExperimentService.liveTarget,
            now: @escaping @MainActor () -> Date = Date.init
        ) {
            self.store = store
            self.runtime = runtime
            self.resolveTarget = resolveTarget
            self.now = now
        }

        func bindRuntime(windowState: WindowState) {
            guard admittedExperimentIDs.isEmpty else { return }
            runtime = NativePromptExperimentContextBuilderRuntime(windowState: windowState)
        }

        func load() async {
            guard !hasLoaded else { return }
            hasLoaded = true
            do {
                var loaded = try await store.loadRecords()
                let recoveryDate = now()
                var changed = false
                for index in loaded.indices {
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
                if changed { try await persist() }
            } catch {
                records = []
                loadError = error.localizedDescription
            }
        }

        @discardableResult
        func createExperiment(controllerSessionID: UUID, sourceTabID: UUID) async throws -> UUID {
            guard loadError == nil else {
                throw PromptExperimentAuthorityError.runtimeUnavailable(loadError ?? "Prompt Experiment storage is unavailable.")
            }
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

        func updateDraft(experimentID: UUID, expectedRevision: Int, draft: PromptExperimentDraft) async throws {
            let index = try index(of: experimentID)
            guard records[index].draft?.revision == expectedRevision else {
                throw PromptExperimentAuthorityError.staleDraft
            }
            var draft = draft
            draft.updatedAt = now()
            records[index].draft = draft
            records[index].phase = .drafting
            records[index].updatedAt = draft.updatedAt
            records[index].statusMessage = "Draft changed; seal again before approval."
            try await persist()
        }

        @discardableResult
        func seal(experimentID: UUID, expectedDraftRevision: Int) async throws -> PromptExperimentPlan {
            let originalIndex = try index(of: experimentID)
            guard let draft = records[originalIndex].draft else { throw PromptExperimentAuthorityError.noDraft }
            guard draft.revision == expectedDraftRevision else { throw PromptExperimentAuthorityError.staleDraft }
            let validated = try draft.validated()
            guard let target = resolveTarget(validated.targetRole) else {
                throw PromptExperimentAuthorityError.targetUnavailable(
                    "No currently available catalog target resolves for role ‘\(validated.targetRole)’."
                )
            }
            let date = now()
            let materialized = try await store.materializeSyntheticEnvironment(
                experimentID: experimentID,
                planRevision: validated.revision,
                fixtureText: validated.syntheticFixture
            )
            let currentIndex = try index(of: experimentID)
            guard records[currentIndex].draft == draft else { throw PromptExperimentAuthorityError.staleDraft }
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
            records[currentIndex].attempts = []
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
            let index = try index(of: experimentID)
            guard let plan = records[index].currentPlan else { throw PromptExperimentAuthorityError.noSealedPlan }
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
            let index = try index(of: experimentID)
            guard let plan = records[index].currentPlan else { throw PromptExperimentAuthorityError.noSealedPlan }
            guard records[index].approval(for: plan) != nil, plan.verifiesIntegrity() else {
                throw PromptExperimentAuthorityError.planNotApproved
            }
            guard admittedExperimentIDs.insert(experimentID).inserted else {
                throw PromptExperimentAuthorityError.experimentAlreadyRunning
            }
            records[index].attempts = plan.trials.map(PromptExperimentAttempt.init)
            records[index].phase = .running
            records[index].updatedAt = now()
            records[index].statusMessage = "Running fixed serial comparison (0/\(plan.trials.count))."
            do {
                try await persist()
            } catch {
                admittedExperimentIDs.remove(experimentID)
                if let currentIndex = records.firstIndex(where: { $0.id == experimentID }) {
                    records[currentIndex].attempts = []
                    records[currentIndex].phase = .approved
                }
                throw error
            }
            executionTasks[experimentID] = Task { @MainActor [weak self] in
                await self?.executeSerially(experimentID: experimentID, plan: plan)
            }
        }

        func cancel(experimentID: UUID) async throws {
            let index = try index(of: experimentID)
            guard records[index].phase == .running || records[index].phase == .cancelling else { return }
            let date = now()
            records[index].phase = .cancelling
            records[index].cancellationRequestedAt = date
            records[index].updatedAt = date
            records[index].statusMessage = "Cancellation requested; waiting for provider settlement."
            var handle: PromptExperimentRuntimeHandle?
            for attemptIndex in records[index].attempts.indices {
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

        func startNextRevision(experimentID: UUID) async throws {
            let index = try index(of: experimentID)
            guard let plan = records[index].currentPlan else { throw PromptExperimentAuthorityError.noSealedPlan }
            guard records[index].phase != .running, records[index].phase != .cancelling else {
                throw PromptExperimentAuthorityError.experimentAlreadyRunning
            }
            let fixture = try await store.readSyntheticFixture(environment: plan.environment)
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
            let evidence: PromptExperimentArtifactReference? = if let output = result.output {
                try await store.installArtifact(Data(output.utf8))
            } else {
                nil
            }
            try await mutate(experimentID: experimentID) { record in
                guard let index = record.attempts.firstIndex(where: { $0.id == attemptID }) else { return }
                let cancelled = record.attempts[index].cancellationRequestedAt != nil || record.cancellationRequestedAt != nil
                record.attempts[index].runtimeLink = result.runtimeLink
                record.attempts[index].fixtureDigestBefore = result.fixtureDigestBefore
                record.attempts[index].fixtureDigestAfter = result.fixtureDigestAfter
                record.attempts[index].evidence = evidence
                record.attempts[index].outputPreview = result.output.map { String($0.prefix(400)) }
                record.attempts[index].settledAt = now()
                record.attempts[index].lateResultAfterCancellation = cancelled
                if cancelled {
                    record.attempts[index].status = .cancelledSettled
                    record.attempts[index].statusText = "Provider settled after cancellation was requested; evidence retained but not scored."
                } else if result.fixtureDigestBefore != record.currentPlan?.environment.fixtureDigest
                    || result.fixtureDigestAfter != result.fixtureDigestBefore
                {
                    record.attempts[index].status = .failed
                    record.attempts[index].statusText = "Synthetic fixture digest was not sealed or changed during the run; attempt disqualified."
                    record.attempts[index].error = "Fixture digest mismatch"
                } else {
                    switch result.disposition {
                    case .completed:
                        record.attempts[index].status = .completed
                        record.attempts[index].statusText = "Completed with immutable evidence."
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
                if record.cancellationRequestedAt != nil {
                    record.phase = .cancelled
                    record.statusMessage = "Cancelled. Requested and settled/unknown states remain visible per attempt."
                } else if record.attempts.allSatisfy({ $0.status == .completed }) {
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

        private func persist() async throws {
            records.sort { $0.updatedAt > $1.updatedAt }
            try await store.saveRecords(records)
        }

        private static func liveTarget(role: String) -> PromptExperimentResolvedTarget? {
            guard let selection = AgentModelCatalog.resolveTaskLabel(role) else { return nil }
            switch selection.agent {
            case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
                break
            case .codexExec, .openCode, .cursor, .grokBuild, .antigravity:
                return nil
            }
            return PromptExperimentResolvedTarget(
                role: role,
                agentRaw: selection.agent.rawValue,
                modelRaw: selection.modelRaw,
                displayName: "\(selection.agent.displayName) \(AgentModelCatalog.displayName(for: selection.modelRaw, agentKind: selection.agent))"
            )
        }
    }
#endif
