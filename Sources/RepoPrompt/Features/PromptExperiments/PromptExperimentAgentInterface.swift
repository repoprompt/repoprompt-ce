#if DEBUG
    import Foundation

    enum PromptExperimentAgentOperation: String, CaseIterable {
        case capabilities
        case list
        case createDraft = "create_draft"
        case updateDraft = "update_draft"
        case proposeSeal = "propose_seal"
        case read
        case proposeNextRevision = "propose_next_revision"
    }

    struct PromptExperimentAgentOwner: Equatable {
        let controllerSessionID: UUID
        let sourceTabID: UUID
    }

    struct PromptExperimentAgentDraftPatch: Equatable {
        var title: String?
        var taskInput: String?
        var syntheticFixture: String?
        var originalInstructions: String?
        var candidateInstructions: String?
        var targetRole: String?
        var repetitions: Int?
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
        case proposeNextRevision(experimentID: UUID, expectedPlanDigest: String)
    }

    enum PromptExperimentAgentResponse {
        case capabilities(operations: [String], limitations: [String])
        case records([PromptExperimentRecord])
        case record(PromptExperimentRecord)
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
                    limitations: [
                        "DEBUG pilot; synthetic-fixture, fixed-comparison, serial trials only.",
                        "No agent operation can approve, start, cancel, score, or promote a plan.",
                        "The user must approve the exact digest and start execution in the native Prompt Experiment Studio.",
                        "This is not the full Investigate workflow, a multi-agent optimizer, or GEPA."
                    ]
                )
            case .list:
                return try await .records(service.ownedRecords(controllerSessionID: owner.controllerSessionID))
            case .createDraft:
                let id = try await service.createExperiment(
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
                    expectedControllerSessionID: owner.controllerSessionID
                )
                return .sealed(experimentID: experimentID, plan: plan)
            case let .read(experimentID):
                return try await .record(service.ownedRecord(
                    id: experimentID,
                    controllerSessionID: owner.controllerSessionID
                ))
            case let .proposeNextRevision(experimentID, digest):
                try await service.startNextRevision(
                    experimentID: experimentID,
                    expectedPlanDigest: digest,
                    expectedControllerSessionID: owner.controllerSessionID
                )
                return try await .record(service.ownedRecord(
                    id: experimentID,
                    controllerSessionID: owner.controllerSessionID
                ))
            }
        }

        private func requireDraft(_ record: PromptExperimentRecord) throws -> PromptExperimentDraft {
            guard let draft = record.draft else { throw PromptExperimentAuthorityError.noDraft }
            return draft
        }
    }
#endif
