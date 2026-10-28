#if DEBUG
    import CryptoKit
    import Foundation
    import RepoPromptSettingsCore

    // MARK: - Splits

    /// Suite splits are the single split vocabulary for evidence, grading, and the ledger.
    typealias PromptExperimentDatasetSplit = PromptSuiteSplit

    extension PromptSuiteSplit {
        /// Fixed feedback sent upstream for held-out evaluations; grader feedback can embed
        /// reference answers and never leaves the native host for this split.
        static let heldOutFeedback = "Held-out score recorded; reference-derived feedback is withheld."

        func proposerFacingFeedback(_ feedback: String) -> String {
            self == .hiddenTest ? Self.heldOutFeedback : feedback
        }
    }

    // MARK: - Errors

    /// One field-level validation problem; several are reported together.
    struct PromptExperimentFieldError: Codable, Equatable {
        let field: String
        let message: String
    }

    enum PromptExperimentAuthorityError: LocalizedError, Equatable {
        case experimentNotFound
        case authorityChanged
        case approvalNotRequested
        case alreadyApproved
        case notApproved
        case runActive
        case budgetExhausted
        case invalidRequest(String)
        case validation([PromptExperimentFieldError])
        case targetUnavailable(String)
        case runtimeUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .experimentNotFound:
                "The Prompt Experiment no longer exists."
            case .authorityChanged:
                "The experiment's authority digest changed; reread it before acting."
            case .approvalNotRequested:
                "No approval request is pending for this experiment."
            case .alreadyApproved:
                "This experiment is already approved. Use run to resume within its remaining budget; changing authority creates a new experiment."
            case .notApproved:
                "The experiment has not been approved in the native app."
            case .runActive:
                "A Prompt Experiment run is already active. Only one run may execute at a time."
            case .budgetExhausted:
                "The approved evaluation cap is fully used. Create a new experiment for more budget."
            case let .invalidRequest(message), let .targetUnavailable(message), let .runtimeUnavailable(message):
                message
            case let .validation(errors):
                "Invalid experiment: " + errors.map { "\($0.field): \($0.message)" }.joined(separator: "; ")
            }
        }
    }

    // MARK: - Authority

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

    struct PromptExperimentTargets: Codable, Equatable {
        let execution: PromptExperimentResolvedTarget
        let reflection: PromptExperimentResolvedTarget
        /// Present exactly when the suite uses a model judge.
        let judge: PromptExperimentResolvedTarget?
    }

    struct PromptExperimentGEPASettings: Codable, Equatable {
        static let candidateSelectionStrategies = ["current_best", "pareto", "epsilon_greedy", "top_k_pareto"]

        /// Small minibatches buy more proposals per budget (a rejected proposal costs 2m).
        var reflectionMinibatchSize = 2
        var useMerge = false
        var maxMergeInvocations = 5
        var skipPerfectScore = true
        /// GEPA parent selection; `current_best` always refines the incumbent.
        var candidateSelectionStrategy = "current_best"
        /// Hard ceiling for a proposed prompt, as a multiple of the prompt being edited
        /// (1.0: a proposal may never grow the prompt).
        var promptCharacterCeilingRatio = 1.0
        /// Optional absolute ceiling, applied together with the ratio.
        var maxPromptCharacters: Int?
        /// Extra seed passes over the validation cases before search (the noise floor);
        /// with GEPA's own pass that is `k + 1` samples per case.
        var noiseFloorReplicates = 2
        var randomSeed = 0
        var stopAtScore: Double?
        /// Additional invocations per logical provider call for classified transient failures.
        var maxProviderRetries = 2
    }

    enum PromptExperimentGEPAConfiguration {
        static let upstreamRepository = "https://github.com/gepa-ai/gepa.git"
        static let pinnedRevision = "0632cdb5dcc052e690eab439e1b4a7e3e9cfe407"
        static let packageVersion = "0.1.4"
    }

    /// Everything that can influence spend, scoring, or proposals. Its digest is what the
    /// native approval covers; any change is a different experiment.
    struct PromptExperimentAuthority: Codable, Equatable {
        let promptID: BuiltInPromptID
        let promptResourceSHA256: String
        let suiteID: String
        let suiteSHA256: String
        let rubricSHA256: String?
        let targets: PromptExperimentTargets
        let settings: PromptExperimentGEPASettings
        /// The approved search cap: GEPA's seed validation pass, proposals, and the held-out
        /// reserve for the incumbent.
        let maxEvaluations: Int
        /// The separately approved baseline-calibration line (spent only on a cache miss).
        let calibrationEvaluations: Int
        let pythonSealValue: String
        let gepaRevision: String

        func digest() throws -> String {
            try PromptExperimentDigest.canonicalSHA256(self)
        }
    }

    struct PromptExperimentApprovalRequest: Codable, Equatable {
        let authorityDigest: String
        let requestedAt: Date
    }

    /// The single native approval of an experiment's authority and cumulative cap.
    struct PromptExperimentApproval: Codable, Equatable {
        let authorityDigest: String
        let approvedAt: Date
    }

    // MARK: - Runs

    enum PromptExperimentRunState: String, Codable, CaseIterable {
        case queued
        case running
        case completed
        case stoppedBudget = "stopped_budget"
        case failed
        case cancelled

        var isActive: Bool {
            self == .queued || self == .running
        }
    }

    struct PromptExperimentArtifactReference: Codable, Equatable {
        let sha256: String
        let relativePath: String
        let byteCount: Int
    }

    enum PromptExperimentOptimizationFailureKind: String, Codable, Equatable {
        case candidate
        case infrastructure
    }

    /// Size and cost of one evaluation, always recorded (tokens only when the provider reports them).
    struct PromptExperimentEvaluationUsage: Codable, Equatable {
        /// Characters in the evaluated candidate prompt body.
        let promptCharacters: Int
        /// Characters in the target's output.
        let outputCharacters: Int
        let promptTokens: Int?
        let completionTokens: Int?
    }

    /// Per-candidate averages over every completed evaluation of that exact text.
    struct PromptExperimentCandidateUsage: Codable, Equatable {
        let promptCharacters: Int
        let evaluations: Int
        let averageOutputCharacters: Double?
        let tokenReportedEvaluations: Int
        let averagePromptTokens: Double?
        let averageCompletionTokens: Double?

        static func aggregate(promptCharacters: Int, usages: [PromptExperimentEvaluationUsage]) -> Self {
            func average(_ values: [Int]) -> Double? {
                values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count)
            }
            let prompts = usages.compactMap(\.promptTokens)
            let completions = usages.compactMap(\.completionTokens)
            return Self(
                promptCharacters: promptCharacters,
                evaluations: usages.count,
                averageOutputCharacters: average(usages.map(\.outputCharacters)),
                tokenReportedEvaluations: max(prompts.count, completions.count),
                averagePromptTokens: average(prompts),
                averageCompletionTokens: average(completions)
            )
        }

        var summary: String {
            var parts = ["prompt \(promptCharacters) chars"]
            if let averageOutputCharacters {
                parts.append("output avg \(Int(averageOutputCharacters.rounded())) chars")
            }
            if let averageCompletionTokens {
                parts.append("completion avg \(Int(averageCompletionTokens.rounded())) tok")
            }
            parts.append("\(evaluations) eval\(evaluations == 1 ? "" : "s")")
            return parts.joined(separator: " · ")
        }
    }

    struct PromptExperimentEvaluationEvidence: Codable, Equatable, Identifiable {
        let id: UUID
        /// GEPA pool index when the evaluated text belongs to exactly one retained candidate; else -1.
        let candidateIndex: Int
        let exampleID: String
        let split: PromptExperimentDatasetSplit
        let score: Double?
        let feedback: String
        let failureKind: PromptExperimentOptimizationFailureKind?
        let outputEvidence: PromptExperimentArtifactReference?
        let elapsedSeconds: Double?
        var usage: PromptExperimentEvaluationUsage?
    }

    /// Scored evidence committed as it is produced; not a final ranking.
    struct PromptExperimentScoredEvaluation: Codable, Equatable, Identifiable {
        let id: UUID
        let candidateEvidence: PromptExperimentArtifactReference
        let evaluation: PromptExperimentEvaluationEvidence
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
        var usage: PromptExperimentCandidateUsage?
    }

    /// Report-only held-out averages for the seed and GEPA's best candidate. A nil side means
    /// that pass was unavailable (reserve spent or provider/judge failure), never a zero.
    struct PromptExperimentHeldOutSummary: Codable, Equatable {
        let baselineAverage: Double?
        let bestAverage: Double?
        /// Where the seed's held-out baseline came from.
        var baselineSource: PromptExperimentCalibrationSource?

        var summary: String {
            func format(_ value: Double?) -> String {
                value.map { String(format: "%.3f", $0) } ?? "unavailable"
            }
            let source = baselineSource.map { " (baseline \($0.label))" } ?? ""
            return "Held-out average: baseline \(format(baselineAverage)) → best \(format(bestAverage))\(source)."
        }
    }

    enum PromptExperimentCalibrationSource: String, Codable, Equatable {
        /// Reused from an earlier experiment with the same seed, suite, rubric, and targets.
        case cache
        /// Scored by this experiment's pre-search calibration pass.
        case calibrated

        var label: String {
            switch self {
            case .cache: "reused from the calibration cache"
            case .calibrated: "calibrated before search"
            }
        }
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
        let rawResultEvidence: PromptExperimentArtifactReference?
        let stopReason: String?
        /// Nil when the suite has no held-out cases or no incumbent was saved.
        var heldOut: PromptExperimentHeldOutSummary?
        /// True when the ledger-aware stopper declined to start an iteration it could not finish.
        var stoppedBeforeUnfinishableIteration: Bool?
        /// Paired per-case deltas of the best against the seed's replicate spread.
        var noiseFloor: PromptExperimentNoiseFloor?

        var assessment: String {
            let budgetNote: String = if stopReason == "budget_exhausted" {
                stoppedBeforeUnfinishableIteration == true
                    ? " Stopped before an iteration the remaining budget could not finish; the reported best is GEPA's saved incumbent."
                    : " Stopped at the approved evaluation budget; the reported best is GEPA's saved incumbent."
            } else {
                ""
            }
            let heldOutNote = heldOut.map { " " + $0.summary } ?? ""
            let noiseNote = noiseFloor.map { " " + $0.summary } ?? ""
            if candidates.count == 1 {
                return "Only the starting candidate was retained after \(totalEvaluations) evaluations; improvement was not demonstrated." + budgetNote + heldOutNote + noiseNote
            }
            return "GEPA retained \(candidates.count) candidates over \(totalEvaluations) evaluations." + noiseNote + budgetNote + heldOutNote
        }
    }

    enum PromptExperimentWorkerProcessObservation: String, Codable, Equatable {
        case notApplicable = "not_applicable"
        case preparing
        case runningObserved = "running_observed"
        case exitedObserved = "exited_observed"
        case launchFailed = "launch_failed"
        case unknownAfterRestart = "unknown_after_restart"
    }

    struct PromptExperimentDiagnosticEvent: Codable, Equatable {
        let observedAt: Date
        let channel: String
        let event: String
        let detail: String?
    }

    struct PromptExperimentRunDiagnostics: Codable, Equatable {
        static let maximumEventTailCount = 40

        var processObservation: PromptExperimentWorkerProcessObservation
        var workerPID: Int32?
        var workerProcessIdentity: String?
        var processStartedAt: Date?
        var processExitedAt: Date?
        var processExitStatus: Int32?
        var lastObservedAt: Date
        var lastObservedEvent: String
        var activeCallbackID: String?
        var activeCallbackOperation: String?
        var stderrLogRelativePath: String?
        var stdoutProtocolLogRelativePath: String?
        var stderrLogByteCount: Int?
        var stderrLogTruncated: Bool
        var protocolLogByteCount: Int?
        var protocolLogTruncated: Bool
        var latestProgress: String?
        var eventTail: [PromptExperimentDiagnosticEvent]

        static func initial(at date: Date) -> Self {
            Self(
                processObservation: .preparing,
                lastObservedAt: date,
                lastObservedEvent: "run_submitted",
                stderrLogTruncated: false,
                protocolLogTruncated: false,
                eventTail: [PromptExperimentDiagnosticEvent(observedAt: date, channel: "service", event: "run_submitted", detail: nil)]
            )
        }

        mutating func append(_ event: PromptExperimentDiagnosticEvent) {
            lastObservedAt = event.observedAt
            lastObservedEvent = event.event
            eventTail.append(event)
            if eventTail.count > Self.maximumEventTailCount {
                eventTail.removeFirst(eventTail.count - Self.maximumEventTailCount)
            }
        }
    }

    struct PromptExperimentModelCallEvidence: Codable, Equatable, Identifiable {
        enum State: String, Codable { case started, completed, failed }
        let id: UUID
        let target: PromptExperimentResolvedTarget
        let role: String
        let state: State
        let promptTokens: Int?
        let completionTokens: Int?
    }

    struct PromptExperimentRun: Codable, Equatable, Identifiable {
        let id: UUID
        let ordinal: Int
        let runDirectoryRelativePath: String
        let createdAt: Date
        var state: PromptExperimentRunState
        var statusText: String
        var startedAt: Date?
        var settledAt: Date?
        var cancellationRequestedAt: Date?
        /// Ledger admissions before this run started (cumulative across the experiment).
        var admissionsBefore: Int
        var admissionsAfter: Int?
        /// Unsettled admissions from an interrupted earlier run, settled as spent when this run opened the ledger.
        var interruptedAdmissionsSettled: Int
        /// The app restarted while this run was active; provider-side settlement is unknown.
        var uncertainRemoteSettlement: Bool
        var diagnostics: PromptExperimentRunDiagnostics?
        var modelCalls: [PromptExperimentModelCallEvidence]
        var evaluations: [PromptExperimentScoredEvaluation]
        var gradings: [PromptExperimentGradingEvidence]
        var result: PromptExperimentOptimizationResult?
        var error: String?
        /// Cumulative baseline-calibration admissions after this run (separate approved line).
        var calibrationAdmissions: Int?
    }

    // MARK: - Proposals

    enum PromptExperimentProposalState: String, Codable {
        case proposed
        case applied
        case rejected
    }

    /// A reviewed source patch for a retained candidate. Created and applied by the patch
    /// proposer (not yet implemented); the record shape is fixed here.
    struct PromptExperimentProposal: Codable, Equatable, Identifiable {
        let id: UUID
        let runID: UUID
        let candidateIndex: Int
        let baselineResourceSHA256: String
        let candidateEvidence: PromptExperimentArtifactReference
        let diffEvidence: PromptExperimentArtifactReference?
        var state: PromptExperimentProposalState
        let createdAt: Date
        var decidedAt: Date?
    }

    // MARK: - Experiment

    enum PromptExperimentStatus: String, Codable {
        case unapproved
        case awaitingApproval = "awaiting_approval"
        case approved
        case running
        case completed
        case stoppedBudget = "stopped_budget"
        case failed
        case cancelled
        case budgetExhausted = "budget_exhausted"
    }

    struct PromptExperiment: Codable, Equatable, Identifiable {
        let id: UUID
        var title: String
        let createdAt: Date
        var updatedAt: Date
        /// Mutable only while unapproved; an approved authority is never changed in place.
        var authority: PromptExperimentAuthority
        var authorityDigest: String
        /// The approved experiment this one replaced when its authority changed.
        let supersedes: UUID?
        var approvalRequest: PromptExperimentApprovalRequest?
        var approval: PromptExperimentApproval?
        var runs: [PromptExperimentRun]
        var proposals: [PromptExperimentProposal]

        var isApproved: Bool {
            approval?.authorityDigest == authorityDigest
        }

        var activeRun: PromptExperimentRun? {
            runs.last { $0.state.isActive }
        }

        /// Cumulative ledger admissions as last recorded by a run.
        var admissionsUsed: Int {
            runs.map { $0.admissionsAfter ?? $0.admissionsBefore }.max() ?? 0
        }

        var remainingEvaluations: Int {
            max(0, authority.maxEvaluations - admissionsUsed)
        }

        var calibrationAdmissionsUsed: Int {
            runs.compactMap(\.calibrationAdmissions).max() ?? 0
        }

        var status: PromptExperimentStatus {
            if activeRun != nil { return .running }
            if approvalRequest != nil, !isApproved { return .awaitingApproval }
            guard isApproved else { return .unapproved }
            if remainingEvaluations == 0 { return .budgetExhausted }
            switch runs.last?.state {
            case .completed: return .completed
            case .stoppedBudget: return .stoppedBudget
            case .failed: return .failed
            case .cancelled: return .cancelled
            case .queued, .running, nil: return .approved
            }
        }
    }

    /// Canonical store document. Schema 10 adds the baseline-calibration line, usage
    /// evidence, prompt-length ceilings, and the noise floor; earlier lab documents are
    /// discarded, never migrated.
    struct PromptExperimentDocument: Codable {
        static let schemaVersion = 10
        let schemaVersion: Int
        var experiments: [PromptExperiment]

        init(experiments: [PromptExperiment]) {
            schemaVersion = Self.schemaVersion
            self.experiments = experiments
        }
    }

    // MARK: - Runtime boundary

    struct PromptExperimentOptimizationRuntimeEvaluation: Codable, Equatable {
        let candidateIndex: Int
        let exampleID: String
        let split: PromptExperimentDatasetSplit
        let score: Double?
        let feedback: String
        let failureKind: PromptExperimentOptimizationFailureKind?
        let output: String?
        let elapsedSeconds: Double?
        var usage: PromptExperimentEvaluationUsage?
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
        let rawResultJSON: Data
        /// `completed` or `budget_exhausted` (GEPA's saved incumbent at the approved cap).
        let stopReason: String?
        var heldOut: PromptExperimentHeldOutSummary?
        var stoppedBeforeUnfinishableIteration: Bool?
        /// Index-aligned with `candidates`, from every completed ledger evaluation of that text.
        var candidateUsage: [PromptExperimentCandidateUsage?] = []
        var noiseFloor: PromptExperimentNoiseFloor?
    }

    enum PromptExperimentCheckpoint: Equatable {
        case modelCall(PromptExperimentModelCallEvidence)
        case evaluation(id: UUID, candidate: String, value: PromptExperimentOptimizationRuntimeEvaluation)
        case grading(PromptExperimentGradingCheckpoint)
    }

    typealias PromptExperimentCheckpointSink = @MainActor @Sendable (PromptExperimentCheckpoint) async throws -> Void

    enum PromptExperimentRuntimeObservation: Equatable {
        case workerPrepared(stderrLogRelativePath: String, stdoutProtocolLogRelativePath: String)
        case workerStarted(pid: Int32, processIdentity: String)
        case workerLaunchFailed(String)
        case workerExited(
            status: Int32,
            stderrLogByteCount: Int,
            stderrLogTruncated: Bool,
            protocolLogByteCount: Int,
            protocolLogTruncated: Bool
        )
        case protocolEvent(channel: String, event: String, detail: String?)
        case callbackStarted(id: String, operation: String)
        case callbackFinished(id: String, operation: String)
    }

    struct PromptExperimentRunRequest {
        let experiment: PromptExperiment
        let runID: UUID
    }

    struct PromptExperimentRuntimeHandle: Equatable {
        let id: UUID
    }

    enum PromptExperimentRuntimeDisposition: Equatable {
        case completed
        case stoppedBudget
        case failed(String)
        case cancelled
    }

    struct PromptExperimentRuntimeResult: Equatable {
        let disposition: PromptExperimentRuntimeDisposition
        let optimization: PromptExperimentOptimizationRuntimeResult?
        /// Cumulative capped ledger admissions after the run (nil when the ledger never opened).
        let admissionsAfter: Int?
        let interruptedAdmissionsSettled: Int
        var calibrationAdmissionsAfter: Int?
    }

    enum PromptExperimentSubmissionError: LocalizedError, Equatable {
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case let .rejected(message): message
            }
        }
    }

    enum PromptExperimentCancellationObservation: Equatable {
        case requested
        case alreadySettled
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
