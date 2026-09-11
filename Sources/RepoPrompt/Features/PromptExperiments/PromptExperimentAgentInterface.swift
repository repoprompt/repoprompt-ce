#if DEBUG
    import Foundation

    enum PromptExperimentAgentOperation: String, CaseIterable {
        case capabilities
        case list
        case setup
        case createDraft = "create_draft"
        case updateDraft = "update_draft"
        case proposeSeal = "propose_seal"
        case status
        case run
        case wait
        case cancel
        case read
        case clone
        case cloneDraft = "clone_draft"
        case rerun
        case proposeRunAgain = "propose_run_again"
        case continueRevision = "continue"
        case proposeNextRevision = "propose_next_revision"
    }

    struct PromptExperimentAgentOwner: Equatable {
        let controllerSessionID: UUID
        let sourceTabID: UUID
        let authorizedSourceRoots: [String]

        init(controllerSessionID: UUID, sourceTabID: UUID, authorizedSourceRoots: [String] = []) {
            self.controllerSessionID = controllerSessionID
            self.sourceTabID = sourceTabID
            self.authorizedSourceRoots = authorizedSourceRoots
        }
    }

    struct PromptExperimentAgentDraftPatch: Equatable {
        var title: String?
        var taskInput: String?
        var syntheticFixture: String?
        var originalInstructions: String?
        var candidateInstructions: String?
        var targetRole: String?
        var repetitions: Int?
        var optimization: PromptExperimentOptimizationSpecification?
    }

    enum PromptExperimentAgentCommand {
        case capabilities
        case list
        case setup(patch: PromptExperimentAgentDraftPatch)
        case createDraft
        case updateDraft(
            experimentID: UUID,
            expectedDraftID: UUID,
            expectedDraftVersion: Int,
            expectedDraftDigest: String,
            patch: PromptExperimentAgentDraftPatch
        )
        case proposeSeal(
            experimentID: UUID,
            expectedDraftID: UUID,
            expectedDraftVersion: Int,
            expectedDraftDigest: String
        )
        case status(experimentID: UUID)
        case run(experimentID: UUID, expectedPlanDigest: String)
        case wait(experimentID: UUID, expectedPlanDigest: String, timeoutSeconds: TimeInterval)
        case cancel(experimentID: UUID, expectedPlanDigest: String)
        case read(experimentID: UUID)
        case cloneDraft(experimentID: UUID)
        case proposeRunAgain(experimentID: UUID, expectedPlanDigest: String)
        case proposeNextRevision(experimentID: UUID, expectedPlanDigest: String, candidateIndex: Int?)
    }

    struct PromptExperimentGEPARuntimeCapability {
        let workerProtocolVersion: Int
        let packageVersion: String
        let pinnedRevision: String
        let pythonVersion: String
        let workerResourceAvailable: Bool
        let bundledRuntimeAvailable: Bool
        let configuredPythonExecutable: String?
        let runtimeStatus: String
    }

    enum PromptExperimentAgentResponse {
        case capabilities(
            operations: [String],
            targets: [PromptExperimentResolvedTarget],
            gepaRuntime: PromptExperimentGEPARuntimeCapability,
            limitations: [String]
        )
        case records([PromptExperimentRecord])
        case record(PromptExperimentRecord, artifactTextBySHA256: [String: String])
        case draft(experimentID: UUID, draft: PromptExperimentDraft)
        case sealed(experimentID: UUID, plan: PromptExperimentPlan)
    }

    /// Session-facing experiment authority. Agents can request and observe runs, but only the
    /// native digest card can grant approval; approved work executes through the existing runtime.
    @MainActor
    struct PromptExperimentAgentInterface {
        let service: PromptExperimentService

        func execute(
            _ command: PromptExperimentAgentCommand,
            owner: PromptExperimentAgentOwner
        ) async throws -> PromptExperimentAgentResponse {
            switch command {
            case .capabilities:
                return .capabilities(
                    operations: PromptExperimentAgentOperation.allCases.map(\.rawValue),
                    targets: service.availableTargets(),
                    gepaRuntime: PromptExperimentGEPARuntimeCapability(
                        workerProtocolVersion: 1,
                        packageVersion: PromptExperimentGEPAConfiguration.packageVersion,
                        pinnedRevision: PromptExperimentGEPAConfiguration.pinnedRevision,
                        pythonVersion: PromptExperimentGEPAWorker.pythonVersion,
                        workerResourceAvailable: (try? PromptExperimentGEPAWorker.resolveWorkerURL()) != nil,
                        bundledRuntimeAvailable: PromptExperimentGEPAWorker.bundledRuntimeAvailable,
                        configuredPythonExecutable: PromptExperimentGEPAWorker.configuredPythonExecutable(),
                        runtimeStatus: PromptExperimentGEPAWorker.runtimeStatus
                    ),
                    limitations: [
                        "DEBUG integration using the packaged CPython and upstream GEPA optimize_anything runtime; no user Python setup or provider credentials are delegated to Python.",
                        "The linked Agent session may draft, seal, request, wait for, and cancel owned runs, but it cannot approve or apply a winner.",
                        "The user approves one exact native digest card; that action automatically starts the sealed run.",
                        "New runs are bounded by evaluation count, not an experiment-wide wall-clock deadline. Cancellation and bounded individual host operations remain available, and durable diagnostics identify the latest observed worker/callback state.",
                        "Prompt-only connected-model, Context Builder, and sandboxed-command adapters are supported for catalog targets shown here. ACP, Investigate, and multi-agent adapters remain explicit unsupported capabilities.",
                        "Reviewed project files may be copied from the Agent session's currently loaded root into an app-owned snapshot. Expected outputs, notes, and held-out grading data remain host-private."
                    ]
                )
            case .list:
                return try await .records(service.ownedRecords(controllerSessionID: owner.controllerSessionID))
            case let .setup(patch):
                guard patch.optimization != nil else {
                    throw PromptExperimentAuthorityError.invalidDraft("setup requires a complete specification_json optimization envelope.")
                }
                let id = try await service.createOptimizationExperiment(
                    controllerSessionID: owner.controllerSessionID,
                    sourceTabID: owner.sourceTabID
                )
                let createdRecord = try await service.ownedRecord(id: id, controllerSessionID: owner.controllerSessionID)
                let created = try requireDraft(createdRecord)
                var draft = created
                if let title = patch.title { draft.title = title }
                if let taskInput = patch.taskInput { draft.taskInput = taskInput }
                if let syntheticFixture = patch.syntheticFixture { draft.syntheticFixture = syntheticFixture }
                if let originalInstructions = patch.originalInstructions { draft.originalInstructions = originalInstructions }
                if let candidateInstructions = patch.candidateInstructions { draft.candidateInstructions = candidateInstructions }
                if let targetRole = patch.targetRole { draft.targetRole = targetRole }
                if let repetitions = patch.repetitions { draft.repetitions = repetitions }
                if var optimization = patch.optimization {
                    optimization.gepa.pythonExecutablePath = PromptExperimentGEPAWorker.configuredPythonSealValue()
                    draft.optimization = optimization
                }
                let updated = try await service.updateDraft(
                    experimentID: id,
                    expectedDraftID: created.id,
                    expectedDraftVersion: created.optimisticVersion,
                    expectedDraftDigest: created.contentDigest(),
                    draft: draft,
                    expectedControllerSessionID: owner.controllerSessionID
                )
                let plan = try await service.seal(
                    experimentID: id,
                    expectedDraftID: updated.id,
                    expectedDraftVersion: updated.optimisticVersion,
                    expectedDraftDigest: updated.contentDigest(),
                    expectedControllerSessionID: owner.controllerSessionID,
                    authorizedSourceRoots: owner.authorizedSourceRoots
                )
                return .sealed(experimentID: id, plan: plan)
            case .createDraft:
                let id = try await service.createOptimizationExperiment(
                    controllerSessionID: owner.controllerSessionID,
                    sourceTabID: owner.sourceTabID
                )
                return try await .draft(
                    experimentID: id,
                    draft: requireDraft(
                        service.ownedRecord(id: id, controllerSessionID: owner.controllerSessionID)
                    )
                )
            case let .updateDraft(experimentID, draftID, version, digest, patch):
                let record = try await service.ownedRecord(
                    id: experimentID,
                    controllerSessionID: owner.controllerSessionID
                )
                var draft = try requireDraft(record)
                if let title = patch.title { draft.title = title }
                if let taskInput = patch.taskInput { draft.taskInput = taskInput }
                if let syntheticFixture = patch.syntheticFixture { draft.syntheticFixture = syntheticFixture }
                if let originalInstructions = patch.originalInstructions { draft.originalInstructions = originalInstructions }
                if let candidateInstructions = patch.candidateInstructions { draft.candidateInstructions = candidateInstructions }
                if let targetRole = patch.targetRole { draft.targetRole = targetRole }
                if let repetitions = patch.repetitions { draft.repetitions = repetitions }
                if var optimization = patch.optimization {
                    optimization.gepa.pythonExecutablePath = PromptExperimentGEPAWorker.configuredPythonSealValue()
                    draft.optimization = optimization
                }
                let updated = try await service.updateDraft(
                    experimentID: experimentID,
                    expectedDraftID: draftID,
                    expectedDraftVersion: version,
                    expectedDraftDigest: digest,
                    draft: draft,
                    expectedControllerSessionID: owner.controllerSessionID
                )
                return .draft(experimentID: experimentID, draft: updated)
            case let .proposeSeal(experimentID, draftID, version, digest):
                let plan = try await service.seal(
                    experimentID: experimentID,
                    expectedDraftID: draftID,
                    expectedDraftVersion: version,
                    expectedDraftDigest: digest,
                    expectedControllerSessionID: owner.controllerSessionID,
                    authorizedSourceRoots: owner.authorizedSourceRoots
                )
                return .sealed(experimentID: experimentID, plan: plan)
            case let .status(experimentID), let .read(experimentID):
                let record = try await service.ownedRecord(
                    id: experimentID,
                    controllerSessionID: owner.controllerSessionID
                )
                return try await .record(
                    record,
                    artifactTextBySHA256: service.readableArtifactText(for: record)
                )
            case let .run(experimentID, expectedPlanDigest):
                let record = try await service.requestRun(
                    experimentID: experimentID,
                    expectedPlanDigest: expectedPlanDigest,
                    expectedControllerSessionID: owner.controllerSessionID
                )
                return try await .record(
                    record,
                    artifactTextBySHA256: service.readableArtifactText(for: record)
                )
            case let .wait(experimentID, expectedPlanDigest, timeoutSeconds):
                let record = try await service.waitForExecution(
                    experimentID: experimentID,
                    expectedPlanDigest: expectedPlanDigest,
                    expectedControllerSessionID: owner.controllerSessionID,
                    timeoutSeconds: timeoutSeconds
                )
                return try await .record(
                    record,
                    artifactTextBySHA256: service.readableArtifactText(for: record)
                )
            case let .cancel(experimentID, expectedPlanDigest):
                try await service.cancel(
                    experimentID: experimentID,
                    expectedPlanDigest: expectedPlanDigest,
                    expectedControllerSessionID: owner.controllerSessionID
                )
                let record = try await service.ownedRecord(
                    id: experimentID,
                    controllerSessionID: owner.controllerSessionID
                )
                return try await .record(
                    record,
                    artifactTextBySHA256: service.readableArtifactText(for: record)
                )
            case let .cloneDraft(experimentID):
                let cloneID = try await service.cloneExperiment(
                    experimentID: experimentID,
                    expectedControllerSessionID: owner.controllerSessionID
                )
                return try await .draft(
                    experimentID: cloneID,
                    draft: requireDraft(service.ownedRecord(id: cloneID, controllerSessionID: owner.controllerSessionID))
                )
            case let .proposeRunAgain(experimentID, digest):
                try await service.startNextRevision(
                    experimentID: experimentID,
                    expectedPlanDigest: digest,
                    expectedControllerSessionID: owner.controllerSessionID,
                    revisionMode: .repeatCurrentSeed
                )
                let record = try await service.ownedRecord(id: experimentID, controllerSessionID: owner.controllerSessionID)
                return try await .record(record, artifactTextBySHA256: service.readableArtifactText(for: record))
            case let .proposeNextRevision(experimentID, digest, candidateIndex):
                try await service.startNextRevision(
                    experimentID: experimentID,
                    expectedPlanDigest: digest,
                    expectedControllerSessionID: owner.controllerSessionID,
                    revisionMode: candidateIndex.map(PromptExperimentRevisionMode.continueCandidate) ?? .continueBest
                )
                let record = try await service.ownedRecord(
                    id: experimentID,
                    controllerSessionID: owner.controllerSessionID
                )
                return try await .record(
                    record,
                    artifactTextBySHA256: service.readableArtifactText(for: record)
                )
            }
        }

        private func requireDraft(_ record: PromptExperimentRecord) throws -> PromptExperimentDraft {
            guard let draft = record.draft else { throw PromptExperimentAuthorityError.noDraft }
            return draft
        }
    }
#endif
