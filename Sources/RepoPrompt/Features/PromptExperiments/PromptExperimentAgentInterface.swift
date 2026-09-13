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
        case retryGrading = "retry_grading"
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

        /// The legacy controllerSessionID storage field is an owner key. Workspace controllers
        /// have a separate deterministic namespace and never impersonate an Agent session.
        static func workspace(_ workspaceID: UUID, tabID: UUID, roots: [String]) -> Self {
            Self(
                controllerSessionID: PromptExperimentDigest.deterministicUUID(
                    namespace: "mcp-workspace-experiment-controller-v1", value: workspaceID.uuidString
                ),
                sourceTabID: tabID, authorizedSourceRoots: roots
            )
        }

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
        case retryGrading(experimentID: UUID, expectedPlanDigest: String, gradingID: UUID)
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
    /// user response through MCP elicitation or a native digest card can grant approval.
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
                        PromptExperimentConnectedModelRunner.codexIsolationLimitation,
                        "Provider callback recovery: max_provider_retries is a sealed per-callback allowance (0...3; absent means zero). Only closed retryable provider failure codes qualify, and every retry is visible in protocol diagnostics and model_calls. Reflection retries repeat only reflection. MCP model retries keep the same phase; a second-pass retry reuses the already captured tool result and never repeats the tool call. Authentication, configuration, policy violations, candidate failures, grading failures, cancellation, storage failures, and whole evaluations are not automatically retried.",
                        "Opt-in gepa.pause_on_grading_failure=true keeps the live GEPA callback paused on a judge failure while a sealed retry remains. Inspect awaiting_retry grading_evidence, then call retry_grading with exact grading_id and plan digest, or cancel. This consumes one already approved judge retry (at most one per evaluation), without rerunning the target. No model call occurs while paused and no pause deadline is imposed. App/worker exit is not resumable. Old plans retain their existing behavior.",
                        "Without pause_on_grading_failure, grading recovery: max_judge_retries is a sealed run-wide allowance (0...10; absent means zero), with at most one extra judge call per evaluation and only for invalid JSON from a completed judge. Target output is durably saved before grading and never rerun for format repair. Inspect grading_evidence states/history; raw judge responses remain host-private. Transport/auth/storage failures and cancellation are never blindly retried. Post-exit exact GEPA checkpoint resume remains unsupported.",
                        "Partial evaluations and model_calls persist before optimizer advancement, including failed attempts. They are not final candidate rankings; Use candidate_evidence.sha256 as partial candidate identity, not a final optimizer index. Missing token counts remain unavailable.",
                        "DEBUG integration using the packaged CPython and upstream GEPA optimize_anything runtime; no user Python setup or provider credentials are delegated to Python.",
                        "The bound Agent session or external MCP workspace controller may draft, seal, request, wait for, and cancel owned runs. Ownership is not approval: only a native human action or server-originated MCP elicitation may approve; no automatic winner application.",
                        "Run approval can use MCP form elicitation (approval_mode=mcp) without native UI. Agent sessions also support native digest cards. Approval starts exactly one sealed revision; no tool argument grants approval.",
                        "Specification schema 3 supports stage=preparation with preparation_candidates: a fixed reviewed batch on training examples only, without GEPA proposals or hidden/validation evaluation. Choose starting_point=supplied or gepa with the user. GEPA seedless search omits seed_candidate; supplied text can use focused preparation probes. Continue preserves preparation until the agent explicitly changes stage after reviewing guidance. Status/read guidance identifies the next decision without authorizing execution. Preparation is not held-out optimization evidence.",
                        "New runs are bounded by evaluation count, not an experiment-wide wall-clock deadline. Cancellation and bounded individual host operations remain available, and durable diagnostics identify the latest observed worker/callback state.",
                        "Supported execution adapters: connected_model, context_builder, sandboxed_command, and mcp_adapter. MCP adapter uses the pinned upstream two-pass adapter against a fresh per-evaluation copy of reviewed project files. Read tools and apply_edits may be selected; mutations affect only that disposable copy and are captured in the trace. It optimizes system_prompt or tool_description_<selected tool>. Remote/arbitrary MCP servers, ACP, Investigate, and multi-agent execution remain unsupported. Do not describe this one-tool workflow as native multi-turn agent execution.",
                        "Reviewed project files may be copied from the authorized currently loaded workspace roots into an app-owned snapshot. Expected outputs, notes, and held-out grading data remain host-private."
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
            case let .retryGrading(experimentID, expectedPlanDigest, gradingID):
                try await service.retryGrading(
                    experimentID: experimentID, expectedPlanDigest: expectedPlanDigest,
                    gradingID: gradingID, expectedControllerSessionID: owner.controllerSessionID
                )
                let record = try await service.ownedRecord(id: experimentID, controllerSessionID: owner.controllerSessionID)
                return try await .record(record, artifactTextBySHA256: service.readableArtifactText(for: record))
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
