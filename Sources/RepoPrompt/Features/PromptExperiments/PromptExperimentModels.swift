#if DEBUG
    import CryptoKit
    import Foundation

    // MARK: - Prompt Experiment authority records

    /// The first native Prompt Experiment slice is deliberately narrow: a fixed, serial
    /// comparison of Context Builder instructions. These records are the app-owned authority;
    /// the provider runtime remains authoritative for each underlying execution.
    enum PromptExperimentCondition: String, Codable, CaseIterable, Hashable {
        case original
        case candidate
        case optimization

        var displayName: String {
            switch self {
            case .original: "Original"
            case .candidate: "Candidate"
            case .optimization: "GEPA optimization"
            }
        }
    }

    enum PromptExperimentPhase: String, Codable {
        case drafting
        case awaitingApproval
        case approved
        case running
        case cancelling
        case completed
        case inconclusive
        case cancelled
    }

    enum PromptExperimentAttemptStatus: String, Codable {
        case planned
        case submitting
        case submissionUncertain
        case localPersistenceFailed
        case running
        case completed
        case failed
        case cancellationRequested
        case cancelledSettled
        case cancelledRemoteUnknown
    }

    enum PromptExperimentApprovalActor: String, Codable {
        case nativeUI
        case agent
    }

    enum PromptExperimentAuthorityError: LocalizedError, Equatable {
        case experimentNotFound
        case staleDraft
        case draftDigestMismatch
        case illegalPhase(String)
        case ownerMismatch
        case noDraft
        case noSealedPlan
        case digestMismatch
        case approvalRequiresNativeUI
        case planNotApproved
        case experimentAlreadyRunning
        case invalidDraft(String)
        case targetUnavailable(String)
        case environmentUnavailable(String)
        case runtimeUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .experimentNotFound:
                "The Prompt Experiment no longer exists."
            case .staleDraft:
                "The draft changed before this operation completed. Reload it and try again."
            case .draftDigestMismatch:
                "The draft content digest changed before this operation completed. Reload it and try again."
            case let .illegalPhase(message):
                message
            case .ownerMismatch:
                "The experiment does not belong to the calling Agent session."
            case .noDraft:
                "There is no editable draft to seal."
            case .noSealedPlan:
                "There is no sealed plan to approve or run."
            case .digestMismatch:
                "The displayed plan digest does not match the sealed plan. Approval was refused."
            case .approvalRequiresNativeUI:
                "Only an explicit native UI action can approve a Prompt Experiment plan."
            case .planNotApproved:
                "The exact sealed plan has not been approved."
            case .experimentAlreadyRunning:
                "This experiment already has active work."
            case let .invalidDraft(message), let .targetUnavailable(message),
                 let .environmentUnavailable(message), let .runtimeUnavailable(message):
                message
            }
        }
    }

    enum PromptExperimentDatasetSplit: String, Codable, CaseIterable, Hashable {
        case training
        case validation
        case hiddenTest = "hidden_test"
    }

    struct PromptExperimentExample: Codable, Equatable, Identifiable {
        let id: String
        var split: PromptExperimentDatasetSplit
        var input: String
        var expectedOutput: String?
        var reviewerNotes: String?
    }

    enum PromptExperimentEvaluatorKind: String, Codable, CaseIterable {
        case exactMatch = "exact_match"
        case connectedModelJudge = "connected_model_judge"
        case sandboxedCommand = "sandboxed_command"
    }

    struct PromptExperimentEvaluatorSpecification: Codable, Equatable {
        var kind: PromptExperimentEvaluatorKind
        var rubric: String
        var judgeTargetSelector: String?
        var command: String?
        var candidateFileName: String?
        var minimumScore: Double
        var maximumScore: Double
    }

    enum PromptExperimentWorkflowAdapter: String, Codable, CaseIterable {
        case contextBuilder = "context_builder"
        case sandboxedCommand = "sandboxed_command"
    }

    struct PromptExperimentExecutionSpecification: Codable, Equatable {
        var adapter: PromptExperimentWorkflowAdapter
        var targetSelector: String?
        var instructions: String
    }

    struct PromptExperimentGEPAConfiguration: Codable, Equatable {
        static let upstreamRepository = "https://github.com/gepa-ai/gepa.git"
        static let pinnedRevision = "0632cdb5dcc052e690eab439e1b4a7e3e9cfe407"
        static let packageVersion = "0.1.4"

        var engine: String
        var pythonExecutablePath: String
        var reflectionTargetSelector: String
        var maxEvaluations: Int
        var maxWallClockSeconds: Int
        var stopAtScore: Double?
        var randomSeed: Int
    }

    /// Sealed input to the external upstream GEPA worker. Every field that can
    /// influence proposals, scoring, permissions, or budget is digest-bound.
    struct PromptExperimentOptimizationTargets: Codable, Equatable {
        let reflection: PromptExperimentResolvedTarget
        let execution: PromptExperimentResolvedTarget?
        let judge: PromptExperimentResolvedTarget?
    }

    struct PromptExperimentOptimizationSpecification: Codable, Equatable {
        var seedCandidate: String?
        var objective: String
        var background: String
        var examples: [PromptExperimentExample]
        var evaluator: PromptExperimentEvaluatorSpecification
        var execution: PromptExperimentExecutionSpecification
        var gepa: PromptExperimentGEPAConfiguration
    }

    enum PromptExperimentOptimizationFailureKind: String, Codable, Equatable {
        case candidate
        case infrastructure
    }

    struct PromptExperimentEvaluationEvidence: Codable, Equatable, Identifiable {
        let id: UUID
        let candidateIndex: Int
        let exampleID: String
        let split: PromptExperimentDatasetSplit
        let score: Double?
        let feedback: String
        let failureKind: PromptExperimentOptimizationFailureKind?
        let outputEvidence: PromptExperimentArtifactReference?
        let elapsedSeconds: Double?
    }

    struct PromptExperimentCandidateEvidence: Codable, Equatable, Identifiable {
        let id: UUID
        let index: Int
        let parentIndices: [Int]
        let candidateEvidence: PromptExperimentArtifactReference
        let candidatePreview: String
        let aggregateScore: Double?
        let isBaseline: Bool
        let isBest: Bool
    }

    struct PromptExperimentOptimizationRuntimeEvaluation: Codable, Equatable {
        let candidateIndex: Int
        let exampleID: String
        let split: PromptExperimentDatasetSplit
        let score: Double?
        let feedback: String
        let failureKind: PromptExperimentOptimizationFailureKind?
        let output: String?
        let elapsedSeconds: Double?
    }

    struct PromptExperimentOptimizationRuntimeResult: Codable, Equatable {
        let engine: String
        let upstreamRevision: String
        let baselineScore: Double?
        let bestScore: Double?
        let bestCandidateIndex: Int?
        let candidates: [String]
        let parentIndices: [[Int]]
        let aggregateScores: [Double?]
        let evaluations: [PromptExperimentOptimizationRuntimeEvaluation]
        let totalEvaluations: Int
        let wallTimeSeconds: Double?
        let proposerUsage: String
        let runDirectoryRelativePath: String?
        let rawResultJSON: Data
    }

    struct PromptExperimentOptimizationResult: Codable, Equatable {
        let engine: String
        let upstreamRevision: String
        let baselineScore: Double?
        let bestScore: Double?
        let bestCandidateIndex: Int?
        let candidates: [PromptExperimentCandidateEvidence]
        let evaluations: [PromptExperimentEvaluationEvidence]
        let totalEvaluations: Int
        let wallTimeSeconds: Double?
        let proposerUsage: String
        let runDirectoryRelativePath: String?
        let rawResultEvidence: PromptExperimentArtifactReference?
    }

    struct PromptExperimentDraft: Codable, Equatable, Identifiable {
        private struct DigestPayload: Codable {
            let id: UUID
            let revision: Int
            let parentPlanID: UUID?
            let title: String
            let taskInput: String
            let syntheticFixture: String
            let originalInstructions: String
            let candidateInstructions: String
            let targetRole: String
            let repetitions: Int
            let optimization: PromptExperimentOptimizationSpecification?
            let createdAt: Date
        }

        static let maximumTitleCharacters = 200
        static let maximumTaskCharacters = 20000
        static let maximumFixtureBytes = 256 * 1024
        static let maximumInstructionCharacters = 50000

        let id: UUID
        let revision: Int
        let parentPlanID: UUID?
        /// Optional for backward-compatible decoding of the original DEBUG pilot document.
        var version: Int?
        var title: String
        var taskInput: String
        var syntheticFixture: String
        var originalInstructions: String
        var candidateInstructions: String
        var targetRole: String
        var repetitions: Int
        var optimization: PromptExperimentOptimizationSpecification?
        let createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            revision: Int,
            parentPlanID: UUID? = nil,
            version: Int = 1,
            title: String,
            taskInput: String = "",
            syntheticFixture: String = "",
            originalInstructions: String = "",
            candidateInstructions: String = "",
            targetRole: String = "explore",
            repetitions: Int = 1,
            optimization: PromptExperimentOptimizationSpecification? = nil,
            createdAt: Date,
            updatedAt: Date
        ) {
            self.id = id
            self.revision = revision
            self.parentPlanID = parentPlanID
            self.version = version
            self.title = title
            self.taskInput = taskInput
            self.syntheticFixture = syntheticFixture
            self.originalInstructions = originalInstructions
            self.candidateInstructions = candidateInstructions
            self.targetRole = targetRole
            self.repetitions = repetitions
            self.optimization = optimization
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        var optimisticVersion: Int {
            version ?? 1
        }

        func contentDigest() throws -> String {
            try PromptExperimentDigest.canonicalSHA256(DigestPayload(
                id: id,
                revision: revision,
                parentPlanID: parentPlanID,
                title: title,
                taskInput: taskInput,
                syntheticFixture: syntheticFixture,
                originalInstructions: originalInstructions,
                candidateInstructions: candidateInstructions,
                targetRole: targetRole,
                repetitions: repetitions,
                optimization: optimization,
                createdAt: createdAt
            ))
        }

        func validatedBounds() throws -> Self {
            guard title.count <= Self.maximumTitleCharacters else {
                throw PromptExperimentAuthorityError.invalidDraft("Experiment titles are limited to \(Self.maximumTitleCharacters) characters.")
            }
            guard taskInput.count <= Self.maximumTaskCharacters else {
                throw PromptExperimentAuthorityError.invalidDraft("Evaluation tasks are limited to \(Self.maximumTaskCharacters) characters.")
            }
            guard Data(syntheticFixture.utf8).count <= Self.maximumFixtureBytes else {
                throw PromptExperimentAuthorityError.invalidDraft("Synthetic fixtures are limited to \(Self.maximumFixtureBytes) UTF-8 bytes.")
            }
            guard originalInstructions.count <= Self.maximumInstructionCharacters,
                  candidateInstructions.count <= Self.maximumInstructionCharacters,
                  (optimization?.seedCandidate?.count ?? 0) <= Self.maximumInstructionCharacters,
                  (optimization?.objective.count ?? 0) <= Self.maximumTaskCharacters,
                  (optimization?.background.count ?? 0) <= Self.maximumInstructionCharacters
            else {
                throw PromptExperimentAuthorityError.invalidDraft("Each instruction variant is limited to \(Self.maximumInstructionCharacters) characters.")
            }
            return self
        }

        func validated() throws -> Self {
            _ = try validatedBounds()
            if var optimization {
                optimization.objective = optimization.objective.trimmingCharacters(in: .whitespacesAndNewlines)
                optimization.background = optimization.background.trimmingCharacters(in: .whitespacesAndNewlines)
                optimization.seedCandidate = optimization.seedCandidate?.trimmingCharacters(in: .whitespacesAndNewlines)
                if optimization.seedCandidate?.isEmpty == true { optimization.seedCandidate = nil }
                guard !optimization.objective.isEmpty else {
                    throw PromptExperimentAuthorityError.invalidDraft("Enter an optimization objective.")
                }
                guard optimization.gepa.engine == "gepa" else {
                    throw PromptExperimentAuthorityError.invalidDraft("This integration currently admits only the upstream GEPA engine.")
                }
                guard (2 ... 10000).contains(optimization.gepa.maxEvaluations) else {
                    throw PromptExperimentAuthorityError.invalidDraft("GEPA max evaluations must be between 2 and 10,000.")
                }
                guard (30 ... 86400).contains(optimization.gepa.maxWallClockSeconds) else {
                    throw PromptExperimentAuthorityError.invalidDraft("GEPA wall-clock limit must be between 30 seconds and 24 hours.")
                }
                guard !optimization.gepa.pythonExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PromptExperimentAuthorityError.invalidDraft("Configure the external Python executable containing pinned GEPA before sealing.")
                }
                let ids = optimization.examples.map(\.id)
                guard Set(ids).count == ids.count, ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw PromptExperimentAuthorityError.invalidDraft("Dataset example IDs must be non-empty and unique.")
                }
                guard !optimization.examples.isEmpty else {
                    throw PromptExperimentAuthorityError.invalidDraft("Add at least one reviewed evaluation example.")
                }
                guard optimization.examples.contains(where: { $0.split != .hiddenTest }) else {
                    throw PromptExperimentAuthorityError.invalidDraft("At least one training or validation example must be visible to GEPA.")
                }
                switch optimization.execution.adapter {
                case .contextBuilder:
                    guard optimization.execution.targetSelector?.isEmpty == false else {
                        throw PromptExperimentAuthorityError.invalidDraft("Select a Context Builder execution target.")
                    }
                case .sandboxedCommand:
                    guard optimization.evaluator.kind == .sandboxedCommand else {
                        throw PromptExperimentAuthorityError.invalidDraft("Sandboxed command execution requires a sandboxed command evaluator.")
                    }
                }
                switch optimization.evaluator.kind {
                case .exactMatch:
                    guard optimization.examples.allSatisfy({ $0.expectedOutput?.isEmpty == false }) else {
                        throw PromptExperimentAuthorityError.invalidDraft("Exact-match examples require reviewed expected outputs.")
                    }
                case .connectedModelJudge:
                    guard !optimization.evaluator.rubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          optimization.evaluator.judgeTargetSelector?.isEmpty == false
                    else {
                        throw PromptExperimentAuthorityError.invalidDraft("A connected-model judge requires a rubric and exact judge target.")
                    }
                case .sandboxedCommand:
                    guard optimization.evaluator.command?.isEmpty == false,
                          optimization.evaluator.candidateFileName?.isEmpty == false
                    else {
                        throw PromptExperimentAuthorityError.invalidDraft("A sandboxed command evaluator requires a command and candidate file name.")
                    }
                }
                var copy = self
                copy.optimization = optimization
                copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !copy.title.isEmpty else {
                    throw PromptExperimentAuthorityError.invalidDraft("Enter an experiment title.")
                }
                return copy
            }
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedTask = taskInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedFixture = syntheticFixture.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedOriginal = originalInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedCandidate = candidateInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else {
                throw PromptExperimentAuthorityError.invalidDraft("Enter an experiment title.")
            }
            guard !trimmedTask.isEmpty else {
                throw PromptExperimentAuthorityError.invalidDraft("Enter a fixed evaluation task.")
            }
            guard !trimmedFixture.isEmpty else {
                throw PromptExperimentAuthorityError.invalidDraft("Enter a reviewed synthetic fixture. Loaded-workspace source is intentionally unsupported in this pilot.")
            }
            guard !trimmedOriginal.isEmpty else {
                throw PromptExperimentAuthorityError.invalidDraft("Enter the original Context Builder instructions.")
            }
            guard !trimmedCandidate.isEmpty else {
                throw PromptExperimentAuthorityError.invalidDraft("Enter candidate Context Builder instructions.")
            }
            guard trimmedOriginal != trimmedCandidate else {
                throw PromptExperimentAuthorityError.invalidDraft("Original and candidate instructions must differ.")
            }
            guard (1 ... 3).contains(repetitions) else {
                throw PromptExperimentAuthorityError.invalidDraft("The pilot supports one to three repetitions per condition.")
            }
            var copy = self
            copy.title = trimmedTitle
            copy.taskInput = trimmedTask
            copy.syntheticFixture = trimmedFixture
            copy.originalInstructions = trimmedOriginal
            copy.candidateInstructions = trimmedCandidate
            copy.targetRole = targetRole.trimmingCharacters(in: .whitespacesAndNewlines)
            return copy
        }
    }

    struct PromptExperimentResolvedTarget: Codable, Equatable {
        /// The user-selected task role or canonical `agent:model` catalog identifier.
        let role: String
        let agentRaw: String
        let modelRaw: String
        let displayName: String

        var selector: String {
            role
        }

        var canonicalSelectionID: String {
            AgentModelSelectionID(agentRaw: agentRaw, modelRaw: modelRaw).rawValue
        }
    }

    struct PromptExperimentFixtureFile: Codable, Equatable, Hashable {
        let path: String
        let byteCount: Int
        let sha256: String
    }

    struct PromptExperimentEnvironment: Codable, Equatable {
        let workspaceID: UUID
        let sourceTabID: UUID
        let capturedAt: Date
        let isolatedRootPath: String
        let selection: StoredSelection
        let fixtureFiles: [PromptExperimentFixtureFile]
        let fixtureDigest: String
        let captureLimitations: [String]
    }

    struct PromptExperimentTrial: Codable, Equatable, Identifiable {
        let id: UUID
        let ordinal: Int
        let condition: PromptExperimentCondition
        let repetition: Int
    }

    struct PromptExperimentPlan: Codable, Equatable, Identifiable {
        struct DigestPayload: Codable {
            let schemaVersion: Int
            let revision: Int
            let parentPlanID: UUID?
            let title: String
            let taskInput: String
            let originalInstructions: String
            let candidateInstructions: String
            let resolvedTarget: PromptExperimentResolvedTarget
            let environment: PromptExperimentEnvironment
            let repetitions: Int
            let executionAdapter: String
            let comparisonMode: String
        }

        struct OptimizationDigestPayload: Codable {
            let schemaVersion: Int
            let revision: Int
            let parentPlanID: UUID?
            let title: String
            let optimization: PromptExperimentOptimizationSpecification
            let resolvedTargets: PromptExperimentOptimizationTargets
            let environment: PromptExperimentEnvironment
            let executionAdapter: String
            let comparisonMode: String
        }

        static let legacySchemaVersion = 1
        static let optimizationSchemaVersion = 2
        static let schemaVersion = legacySchemaVersion
        static let executionAdapter = "context_builder_native_v1"
        static let comparisonMode = "fixed_serial_interleaved_v1"
        static let gepaExecutionAdapter = "upstream_gepa_optimize_anything_v1"
        static let gepaComparisonMode = "budgeted_pareto_search_v1"

        let schemaVersion: Int?
        let id: UUID
        let revision: Int
        let parentPlanID: UUID?
        let title: String
        let taskInput: String
        let originalInstructions: String
        let candidateInstructions: String
        let resolvedTarget: PromptExperimentResolvedTarget
        let environment: PromptExperimentEnvironment
        let repetitions: Int
        let executionAdapter: String
        let comparisonMode: String
        let digest: String
        let sealedAt: Date
        let trials: [PromptExperimentTrial]
        let limitations: [String]
        let optimization: PromptExperimentOptimizationSpecification?
        let optimizationTargets: PromptExperimentOptimizationTargets?

        static func seal(
            draft: PromptExperimentDraft,
            target: PromptExperimentResolvedTarget,
            optimizationTargets: PromptExperimentOptimizationTargets? = nil,
            environment: PromptExperimentEnvironment,
            at date: Date
        ) throws -> Self {
            let draft = try draft.validated()
            if let optimization = draft.optimization {
                guard let optimizationTargets else {
                    throw PromptExperimentAuthorityError.targetUnavailable("The sealed GEPA envelope is missing resolved targets.")
                }
                let payload = OptimizationDigestPayload(
                    schemaVersion: optimizationSchemaVersion,
                    revision: draft.revision,
                    parentPlanID: draft.parentPlanID,
                    title: draft.title,
                    optimization: optimization,
                    resolvedTargets: optimizationTargets,
                    environment: environment,
                    executionAdapter: gepaExecutionAdapter,
                    comparisonMode: gepaComparisonMode
                )
                let digest = try PromptExperimentDigest.canonicalSHA256(payload)
                let planID = PromptExperimentDigest.deterministicUUID(namespace: "plan", value: digest)
                let trial = PromptExperimentTrial(
                    id: PromptExperimentDigest.deterministicUUID(namespace: "gepa-run", value: digest),
                    ordinal: 1,
                    condition: .optimization,
                    repetition: 1
                )
                return Self(
                    schemaVersion: optimizationSchemaVersion,
                    id: planID,
                    revision: draft.revision,
                    parentPlanID: draft.parentPlanID,
                    title: draft.title,
                    taskInput: draft.taskInput,
                    originalInstructions: draft.originalInstructions,
                    candidateInstructions: draft.candidateInstructions,
                    resolvedTarget: optimizationTargets.execution ?? optimizationTargets.reflection,
                    environment: environment,
                    repetitions: 1,
                    executionAdapter: gepaExecutionAdapter,
                    comparisonMode: gepaComparisonMode,
                    digest: digest,
                    sealedAt: date,
                    trials: [trial],
                    limitations: [
                        "Runs the pinned upstream GEPA optimize_anything engine in a separately configured Python environment; RPCE does not install Python packages.",
                        "Context Builder is the first workflow adapter. Investigate and multi-agent adapters use the same host bridge but are not yet implemented.",
                        "Reviewed examples are copied into an app-owned isolated environment. Direct loaded-workspace execution and hidden source access are not admitted.",
                        "Generated-code commands run only under the sealed macOS Seatbelt profile; unsupported sandbox hosts fail closed.",
                        "Infrastructure failures remain inconclusive and are never converted to candidate score zero.",
                        "Applying a winning candidate remains a separate user-authorized action and is not implemented by the agent tool."
                    ],
                    optimization: optimization,
                    optimizationTargets: optimizationTargets
                )
            }
            let payload = DigestPayload(
                schemaVersion: schemaVersion,
                revision: draft.revision,
                parentPlanID: draft.parentPlanID,
                title: draft.title,
                taskInput: draft.taskInput,
                originalInstructions: draft.originalInstructions,
                candidateInstructions: draft.candidateInstructions,
                resolvedTarget: target,
                environment: environment,
                repetitions: draft.repetitions,
                executionAdapter: executionAdapter,
                comparisonMode: comparisonMode
            )
            let digest = try PromptExperimentDigest.canonicalSHA256(payload)
            let planID = PromptExperimentDigest.deterministicUUID(namespace: "plan", value: digest)
            return Self(
                schemaVersion: legacySchemaVersion,
                id: planID,
                revision: draft.revision,
                parentPlanID: draft.parentPlanID,
                title: draft.title,
                taskInput: draft.taskInput,
                originalInstructions: draft.originalInstructions,
                candidateInstructions: draft.candidateInstructions,
                resolvedTarget: target,
                environment: environment,
                repetitions: draft.repetitions,
                executionAdapter: executionAdapter,
                comparisonMode: comparisonMode,
                digest: digest,
                sealedAt: date,
                trials: makeSchedule(planDigest: digest, repetitions: draft.repetitions),
                limitations: [
                    "Single-stage Context Builder pilot; it does not execute the Investigate workflow or multi-agent handoffs.",
                    "Fixed original/candidate comparison only; there is no optimizer, GEPA attachment, semantic judge, or automatic promotion.",
                    "Runs use an app-owned synthetic fixture as the provider working directory and run-scoped lookup authority. Loaded-workspace experiments are unsupported.",
                    "The pilot supports catalog-resolved Claude-compatible and Codex login-backed discovery targets. ACP and other target families remain unsupported.",
                    "The synthetic fixture digest is verified before and after each trial; a mismatch disqualifies the attempt.",
                    "Subscription-backed provider cost is not represented as a hard currency budget."
                ],
                optimization: nil,
                optimizationTargets: nil
            )
        }

        func instructions(for condition: PromptExperimentCondition) -> String {
            switch condition {
            case .original: originalInstructions
            case .candidate: candidateInstructions
            case .optimization: optimization?.execution.instructions ?? candidateInstructions
            }
        }

        func verifiesIntegrity() -> Bool {
            if let optimization {
                guard schemaVersion == Self.optimizationSchemaVersion,
                      let optimizationTargets,
                      trials.count == 1,
                      trials.first?.condition == .optimization
                else { return false }
                let payload = OptimizationDigestPayload(
                    schemaVersion: Self.optimizationSchemaVersion,
                    revision: revision,
                    parentPlanID: parentPlanID,
                    title: title,
                    optimization: optimization,
                    resolvedTargets: optimizationTargets,
                    environment: environment,
                    executionAdapter: executionAdapter,
                    comparisonMode: comparisonMode
                )
                return (try? PromptExperimentDigest.canonicalSHA256(payload)) == digest
                    && id == PromptExperimentDigest.deterministicUUID(namespace: "plan", value: digest)
                    && trials.first?.id == PromptExperimentDigest.deterministicUUID(namespace: "gepa-run", value: digest)
            }
            let payload = DigestPayload(
                schemaVersion: Self.legacySchemaVersion,
                revision: revision,
                parentPlanID: parentPlanID,
                title: title,
                taskInput: taskInput,
                originalInstructions: originalInstructions,
                candidateInstructions: candidateInstructions,
                resolvedTarget: resolvedTarget,
                environment: environment,
                repetitions: repetitions,
                executionAdapter: executionAdapter,
                comparisonMode: comparisonMode
            )
            guard (try? PromptExperimentDigest.canonicalSHA256(payload)) == digest,
                  id == PromptExperimentDigest.deterministicUUID(namespace: "plan", value: digest)
            else { return false }
            return trials == Self.makeSchedule(planDigest: digest, repetitions: repetitions)
        }

        private static func makeSchedule(planDigest: String, repetitions: Int) -> [PromptExperimentTrial] {
            var trials: [PromptExperimentTrial] = []
            var ordinal = 0
            for repetition in 0 ..< repetitions {
                let conditions: [PromptExperimentCondition] = repetition.isMultiple(of: 2)
                    ? [.original, .candidate]
                    : [.candidate, .original]
                for condition in conditions {
                    ordinal += 1
                    let identity = "\(planDigest):\(repetition):\(condition.rawValue):\(ordinal)"
                    trials.append(PromptExperimentTrial(
                        id: PromptExperimentDigest.deterministicUUID(namespace: "trial", value: identity),
                        ordinal: ordinal,
                        condition: condition,
                        repetition: repetition + 1
                    ))
                }
            }
            return trials
        }
    }

    struct PromptExperimentApproval: Codable, Equatable, Identifiable {
        let id: UUID
        let planID: UUID
        let planDigest: String
        let source: PromptExperimentApprovalActor
        let approvedAt: Date
        let statement: String
    }

    struct PromptExperimentArtifactReference: Codable, Equatable {
        let sha256: String
        let relativePath: String
        let byteCount: Int
    }

    struct PromptExperimentRuntimeLink: Codable, Equatable {
        let adapter: String
        let tabID: UUID?
        let runID: UUID?
        let provider: String?
        let model: String?
    }

    /// Raw immutable handoff captured at the Context Builder terminal commit seam.
    struct PromptExperimentRuntimeHandoff: Equatable {
        let prompt: String
        let selection: StoredSelection
        let selectionRevision: UInt64
        let usedAgentOutputAsPrompt: Bool
    }

    /// Durable evidence for the actual committed prompt and final selected context.
    struct PromptExperimentCommittedHandoff: Codable, Equatable {
        let promptEvidence: PromptExperimentArtifactReference
        let promptPreview: String
        let selection: StoredSelection
        let selectionRevision: UInt64
        let usedAgentOutputAsPrompt: Bool
    }

    struct PromptExperimentAttempt: Codable, Equatable, Identifiable {
        let id: UUID
        let trialID: UUID
        var planID: UUID?
        var planRevision: Int?
        var planDigest: String?
        let ordinal: Int
        let condition: PromptExperimentCondition
        let repetition: Int
        var status: PromptExperimentAttemptStatus
        var statusText: String
        var submittedAt: Date?
        var cancellationRequestedAt: Date?
        var settledAt: Date?
        var runtimeLink: PromptExperimentRuntimeLink?
        /// Legacy pilot evidence. New runs store the committed prompt and assistant output separately.
        var evidence: PromptExperimentArtifactReference?
        /// Legacy pilot preview. New runs use `committedHandoff.promptPreview`.
        var outputPreview: String?
        var committedHandoff: PromptExperimentCommittedHandoff?
        var assistantOutputEvidence: PromptExperimentArtifactReference?
        var assistantOutputPreview: String?
        var handoffUnavailableReason: String?
        var error: String?
        var lateResultAfterCancellation: Bool
        var fixtureDigestBefore: String?
        var fixtureDigestAfter: String?
        var optimizationResult: PromptExperimentOptimizationResult?

        init(trial: PromptExperimentTrial, plan: PromptExperimentPlan) {
            id = PromptExperimentDigest.deterministicUUID(namespace: "attempt", value: trial.id.uuidString)
            trialID = trial.id
            planID = plan.id
            planRevision = plan.revision
            planDigest = plan.digest
            ordinal = trial.ordinal
            condition = trial.condition
            repetition = trial.repetition
            status = .planned
            statusText = "Planned"
            submittedAt = nil
            cancellationRequestedAt = nil
            settledAt = nil
            runtimeLink = nil
            evidence = nil
            outputPreview = nil
            committedHandoff = nil
            assistantOutputEvidence = nil
            assistantOutputPreview = nil
            handoffUnavailableReason = nil
            error = nil
            lateResultAfterCancellation = false
            fixtureDigestBefore = nil
            fixtureDigestAfter = nil
            optimizationResult = nil
        }
    }

    struct PromptExperimentRecord: Codable, Equatable, Identifiable {
        let id: UUID
        let controllerSessionID: UUID
        let sourceTabID: UUID
        let createdAt: Date
        var updatedAt: Date
        var phase: PromptExperimentPhase
        var draft: PromptExperimentDraft?
        var plans: [PromptExperimentPlan]
        var approvals: [PromptExperimentApproval]
        var attempts: [PromptExperimentAttempt]
        var cancellationRequestedAt: Date?
        var statusMessage: String

        var title: String {
            draft?.title ?? plans.last?.title ?? "Prompt Experiment"
        }

        var currentPlan: PromptExperimentPlan? {
            plans.last
        }

        func approval(for plan: PromptExperimentPlan) -> PromptExperimentApproval? {
            approvals.last { $0.planID == plan.id && $0.planDigest == plan.digest && $0.source == .nativeUI }
        }

        func attempts(for plan: PromptExperimentPlan) -> [PromptExperimentAttempt] {
            attempts.filter { $0.planID == plan.id && $0.planDigest == plan.digest }
        }

        func plan(for attempt: PromptExperimentAttempt) -> PromptExperimentPlan? {
            guard let planID = attempt.planID else { return nil }
            return plans.first { $0.id == planID }
        }

        /// Migrates evidence written by the earliest DEBUG pilot, before attempts carried
        /// explicit plan lineage. A match must be unique; ambiguous evidence remains visible
        /// but unassigned rather than being attached to the wrong immutable plan.
        mutating func migrateLegacyAttemptLineage() -> Bool {
            var changed = false
            for index in attempts.indices where attempts[index].planID == nil
                || attempts[index].planRevision == nil
                || attempts[index].planDigest == nil
            {
                let attempt = attempts[index]
                let candidates = plans.filter { plan in
                    (attempt.planID == nil || attempt.planID == plan.id)
                        && (attempt.planRevision == nil || attempt.planRevision == plan.revision)
                        && (attempt.planDigest == nil || attempt.planDigest == plan.digest)
                        && plan.trials.contains { $0.id == attempt.trialID }
                }
                guard candidates.count == 1, let plan = candidates.first else { continue }
                attempts[index].planID = plan.id
                attempts[index].planRevision = plan.revision
                attempts[index].planDigest = plan.digest
                changed = true
            }
            return changed
        }
    }

    struct PromptExperimentDocument: Codable {
        static let schemaVersion = 1
        let schemaVersion: Int
        var records: [PromptExperimentRecord]

        init(records: [PromptExperimentRecord]) {
            schemaVersion = Self.schemaVersion
            self.records = records
        }
    }

    enum PromptExperimentRuntimeDisposition: Equatable {
        case completed
        case failed(String)
        case cancelled
    }

    struct PromptExperimentRuntimeHandle: Equatable {
        let id: UUID
        let tabID: UUID?
        let runID: UUID?
    }

    struct PromptExperimentRuntimeResult: Equatable {
        let disposition: PromptExperimentRuntimeDisposition
        let runtimeLink: PromptExperimentRuntimeLink
        let committedHandoff: PromptExperimentRuntimeHandoff?
        let assistantOutput: String?
        let handoffUnavailableReason: String?
        let fixtureDigestBefore: String
        let fixtureDigestAfter: String?
        var optimizationResult: PromptExperimentOptimizationRuntimeResult?
    }

    enum PromptExperimentSubmissionError: LocalizedError, Equatable {
        case rejected(String)
        case acceptanceUnknown(String)

        var errorDescription: String? {
            switch self {
            case let .rejected(message), let .acceptanceUnknown(message): message
            }
        }
    }

    struct PromptExperimentRunRequest {
        let experimentID: UUID
        let controllerSessionID: UUID
        let plan: PromptExperimentPlan
        let attempt: PromptExperimentAttempt
    }

    enum PromptExperimentCancellationObservation: Equatable {
        case requested
        case alreadySettled
        case remoteStateUnknown(String)
    }

    enum PromptExperimentDigest {
        static func canonicalSHA256(_ value: some Encodable) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(value)
            return sha256(data)
        }

        static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        static func deterministicUUID(namespace: String, value: String) -> UUID {
            let data = Data("com.repoprompt.prompt-experiment:\(namespace):\(value)".utf8)
            var bytes = Array(SHA256.hash(data: data).prefix(16))
            bytes[6] = (bytes[6] & 0x0F) | 0x50
            bytes[8] = (bytes[8] & 0x3F) | 0x80
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }
    }
#endif
