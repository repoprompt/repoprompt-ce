#if DEBUG
    import Foundation

    enum PromptExperimentAgentOperation: String, CaseIterable {
        case capabilities
        case list
        case createDraft = "create_draft"
        case updateDraft = "update_draft"
        case proposeSeal = "propose_seal"
        case read
        case cloneDraft = "clone_draft"
        case proposeRunAgain = "propose_run_again"
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
        case read(experimentID: UUID)
        case cloneDraft(experimentID: UUID)
        case proposeRunAgain(experimentID: UUID, expectedPlanDigest: String)
        case proposeNextRevision(experimentID: UUID, expectedPlanDigest: String, candidateIndex: Int?)
    }

    struct PromptExperimentGEPARuntimeCapability {
        let workerProtocolVersion: Int
        let packageVersion: String
        let pinnedRevision: String
        let workerResourceAvailable: Bool
        let configuredPythonExecutable: String?
        let setupInstructions: String
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

    /// Agent-facing draft/query authority. The native UI remains the sole approval and run authority.
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
                        workerResourceAvailable: (try? PromptExperimentGEPAWorker.resolveWorkerURL()) != nil,
                        configuredPythonExecutable: PromptExperimentGEPAWorker.configuredPythonExecutable(),
                        setupInstructions: PromptExperimentGEPAWorker.setupInstructions
                    ),
                    limitations: [
                        "DEBUG integration using upstream GEPA optimize_anything from a separately configured pinned Python environment.",
                        "The linked Agent session may create/update/seal/query only; it cannot approve, start, cancel, or apply a winner.",
                        "The user approves the exact native digest card and starts or stops execution from that card.",
                        "Prompt-only connected-model, Context Builder, and sandboxed-command adapters are supported for catalog targets shown here. ACP, Investigate, and multi-agent adapters remain explicit unsupported capabilities.",
                        "Reviewed project files may be copied from the Agent session's currently loaded root into an app-owned snapshot. Expected outputs, notes, and held-out grading data remain host-private."
                    ]
                )
            case .list:
                return try await .records(service.ownedRecords(controllerSessionID: owner.controllerSessionID))
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
                if let optimization = patch.optimization { draft.optimization = optimization }
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
            case let .read(experimentID):
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
