#if DEBUG
    import Darwin
    import Foundation

    /// NDJSON protocol v2 between the app and `AppResources/PromptExperiments/gepa_worker.py`.
    ///
    /// The worker streams small identity events (`candidate`, `evaluation`, `reflection`)
    /// and ends with a `completed` summary carrying only GEPA indices, lineage, aggregate
    /// scores, and content hashes. Candidate text crosses once per candidate in its own
    /// event; evaluation outputs never cross back to the app because the app produced them.
    /// Explicit coding keys (not snake-case strategies) keep example-ID dictionary keys intact.
    enum GEPAWorkerProtocol {
        static let version = 2

        struct Example: Codable, Equatable {
            let id: String
            let split: String
            let input: String
        }

        /// Held-out cases are scored host-side by identity; their inputs never cross to GEPA.
        struct HeldOutExample: Codable, Equatable {
            let id: String
            let split: String
        }

        struct ObjectivePolicy: Codable, Equatable {
            let mode: String
            let qualityTolerance: Double
            let inputWeight: Double
            let outputWeight: Double

            init(_ objective: PromptLabObjective) {
                mode = objective.mode.rawValue
                qualityTolerance = objective.qualityTolerance
                inputWeight = objective.inputWeight
                outputWeight = objective.outputWeight
            }

            enum CodingKeys: String, CodingKey {
                case mode
                case qualityTolerance = "quality_tolerance"
                case inputWeight = "input_weight"
                case outputWeight = "output_weight"
            }
        }

        struct SeedMeasurement: Codable, Equatable {
            let quality: Double
            let promptTokens: Int?
            let completionTokens: Int?

            enum CodingKeys: String, CodingKey {
                case quality
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
            }
        }

        struct RunRequest: Encodable, Equatable {
            let runName: String
            let objective: String
            let background: String
            let seedCandidate: String?
            let examples: [Example]
            let heldOutExamples: [HeldOutExample]
            /// Cumulative GEPA search cap (approved total minus the held-out reserve).
            let searchMaxEvaluations: Int
            /// Search admissions the host ledger still allows when this run starts; every
            /// evaluation reply refreshes it for the worker's iteration-boundary stopper. Required:
            /// the worker refuses to start without it.
            let searchRemaining: Int
            /// The seed's recorded answer length per visible case (ledger replicate 0), so
            /// brevity keeps its real reference on a resume that never re-evaluates the seed.
            var seedOutputCharacters: [String: Int]?
            /// The seed's held-out baseline from calibration; the reserve then scores only the incumbent.
            var heldOutBaseline: HeldOutScores?
            let reflectionMinibatchSize: Int
            let useMerge: Bool
            let maxMergeInvocations: Int
            let skipPerfectScore: Bool
            let candidateSelectionStrategy: String
            /// Proposal ceiling as a multiple of the prompt being edited, plus an optional absolute cap.
            let promptCharacterCeilingRatio: Double?
            var maxPromptCharacters: Int?
            let perfectScore: Double
            let stopAtScore: Double?
            let randomSeed: Int
            let runDir: String
            let outputDir: String
            var objectivePolicy: ObjectivePolicy?
            var seedMeasurements: [String: SeedMeasurement]?

            enum CodingKeys: String, CodingKey {
                case runName = "run_name"
                case objective
                case background
                case seedCandidate = "seed_candidate"
                case examples
                case heldOutExamples = "held_out_examples"
                case searchMaxEvaluations = "search_max_evaluations"
                case searchRemaining = "search_remaining"
                case seedOutputCharacters = "seed_output_characters"
                case heldOutBaseline = "held_out_baseline"
                case reflectionMinibatchSize = "reflection_minibatch_size"
                case useMerge = "use_merge"
                case maxMergeInvocations = "max_merge_invocations"
                case skipPerfectScore = "skip_perfect_score"
                case candidateSelectionStrategy = "candidate_selection_strategy"
                case promptCharacterCeilingRatio = "prompt_character_ceiling_ratio"
                case maxPromptCharacters = "max_prompt_characters"
                case perfectScore = "perfect_score"
                case stopAtScore = "stop_at_score"
                case randomSeed = "random_seed"
                case runDir = "run_dir"
                case outputDir = "output_dir"
                case objectivePolicy = "objective_policy"
                case seedMeasurements = "seed_measurements"
            }
        }

        struct EvaluateRequest: Codable, Equatable {
            let candidate: String
            let candidateSHA256: String
            let exampleID: String
            let split: String

            enum CodingKeys: String, CodingKey {
                case candidate
                case candidateSHA256 = "candidate_sha256"
                case exampleID = "example_id"
                case split
            }
        }

        enum HostRequest: Equatable {
            case reflect(prompt: String)
            case evaluate(EvaluateRequest)
        }

        struct EvaluatedReply: Equatable {
            let evaluationID: String
            let score: Double
            let feedback: String
            let outputExcerpt: String?
            let replayed: Bool
            var promptTokens: Int?
            var completionTokens: Int?
            /// Search-pool admissions left after this evaluation (host ledger authority).
            var searchRemaining: Int?
            /// Answer length, for the worker's brevity objective (replays included).
            var outputCharacters: Int?
            /// A malformed candidate is never an eligible winner, even at tied zero quality.
            var candidateValid: Bool?
        }

        enum HostReply: Equatable {
            case reflected(output: String, promptTokens: Int?, completionTokens: Int?)
            case evaluated(EvaluatedReply)
            /// Typed ledger refusal; the worker turns it into GEPA's clean budget stop.
            case budgetExhausted
            case failed(code: String?, message: String)

            func jsonObject(id: String) -> [String: Any] {
                var value: [String: Any] = ["protocol_version": version, "type": "host_response", "id": id]
                switch self {
                case let .reflected(output, promptTokens, completionTokens):
                    value["status"] = "ok"
                    value["output"] = output
                    if let promptTokens { value["prompt_tokens"] = promptTokens }
                    if let completionTokens { value["completion_tokens"] = completionTokens }
                case let .evaluated(reply):
                    value["status"] = "ok"
                    value["evaluation_id"] = reply.evaluationID
                    value["score"] = reply.score
                    value["feedback"] = reply.feedback
                    value["replayed"] = reply.replayed
                    if let excerpt = reply.outputExcerpt { value["output_excerpt"] = excerpt }
                    if let promptTokens = reply.promptTokens { value["prompt_tokens"] = promptTokens }
                    if let completionTokens = reply.completionTokens { value["completion_tokens"] = completionTokens }
                    if let searchRemaining = reply.searchRemaining { value["search_remaining"] = searchRemaining }
                    if let outputCharacters = reply.outputCharacters { value["output_characters"] = outputCharacters }
                    if let candidateValid = reply.candidateValid { value["candidate_valid"] = candidateValid }
                case .budgetExhausted:
                    value["status"] = "budget_exhausted"
                case let .failed(code, message):
                    value["status"] = "failed"
                    value["error"] = message
                    if let code { value["failure_code"] = code }
                }
                return value
            }
        }

        struct CandidateEvent: Decodable, Equatable {
            let eventID: String
            let candidateIndex: Int
            let candidateSHA256: String
            let candidate: String
            let parentIndices: [Int]
            let aggregateScore: Double?

            enum CodingKeys: String, CodingKey {
                case eventID = "event_id"
                case candidateIndex = "candidate_index"
                case candidateSHA256 = "candidate_sha256"
                case candidate
                case parentIndices = "parent_indices"
                case aggregateScore = "aggregate_score"
            }
        }

        struct EvaluationEvent: Decodable, Equatable {
            let eventID: String
            let candidateSHA256: String
            let exampleID: String
            let split: String
            let score: Double
            let replayed: Bool

            enum CodingKeys: String, CodingKey {
                case eventID = "event_id"
                case candidateSHA256 = "candidate_sha256"
                case exampleID = "example_id"
                case split
                case score
                case replayed
            }
        }

        struct ReflectionEvent: Decodable, Equatable {
            let eventID: String
            /// `envelope` or `fenced_block` for an accepted candidate; `missing_envelope` or
            /// `empty_candidate` when the reply was rejected and GEPA skipped the proposal.
            let contract: String
            let candidateSHA256: String

            enum CodingKeys: String, CodingKey {
                case eventID = "event_id"
                case contract
                case candidateSHA256 = "candidate_sha256"
            }
        }

        enum Event: Equatable {
            case candidate(CandidateEvent)
            case evaluation(EvaluationEvent)
            case reflection(ReflectionEvent)
        }

        struct TerminalCandidate: Codable, Equatable {
            let index: Int
            let sha256: String
            let parentIndices: [Int]
            let aggregateScore: Double?

            enum CodingKeys: String, CodingKey {
                case index
                case sha256
                case parentIndices = "parent_indices"
                case aggregateScore = "aggregate_score"
            }
        }

        struct HeldOutScores: Codable, Equatable {
            let scores: [String: Double]
            let average: Double
        }

        struct HeldOut: Codable, Equatable {
            /// Nil when the held-out pass could not be admitted; never a fabricated zero.
            let baseline: HeldOutScores?
            let best: HeldOutScores?
        }

        /// GEPA's per-case validation scores for the seed (replicate 0) and the reported best.
        struct ValidationScores: Codable, Equatable {
            let baseline: [String: Double]
            let best: [String: Double]
        }

        struct Terminal: Codable, Equatable {
            let engine: String
            let upstreamRevision: String
            /// `completed`, `budget_exhausted`, or `iteration_limit` (replays made no progress).
            let stopReason: String
            /// False when the budget ran out before GEPA saved any state; no winner exists.
            let hasIncumbent: Bool
            let candidates: [TerminalCandidate]
            let bestCandidateIndex: Int?
            let bestScore: Double?
            let baselineScore: Double?
            let totalMetricCalls: Int?
            let wallTimeSeconds: Double?
            let heldOut: HeldOut?
            let proposerUsage: String
            var searchRemaining: Int?
            var iterationCost: Int?
            var stoppedBeforeUnfinishableIteration: Bool?
            var validationScores: ValidationScores?

            enum CodingKeys: String, CodingKey {
                case engine
                case upstreamRevision = "upstream_revision"
                case stopReason = "stop_reason"
                case hasIncumbent = "has_incumbent"
                case candidates
                case bestCandidateIndex = "best_candidate_index"
                case bestScore = "best_score"
                case baselineScore = "baseline_score"
                case totalMetricCalls = "total_metric_calls"
                case wallTimeSeconds = "wall_time_seconds"
                case heldOut = "held_out"
                case proposerUsage = "proposer_usage"
                case searchRemaining = "search_remaining"
                case iterationCost = "iteration_cost"
                case stoppedBeforeUnfinishableIteration = "stopped_before_unfinishable_iteration"
                case validationScores = "validation_scores"
            }
        }

        fileprivate struct Header: Decodable {
            let protocolVersion: Int
            let type: String

            enum CodingKeys: String, CodingKey {
                case protocolVersion = "protocol_version"
                case type
            }
        }

        fileprivate struct HostRequestHeader: Decodable {
            let id: String
            let operation: String
        }

        fileprivate struct Payload<Value: Decodable>: Decodable {
            let payload: Value
        }

        fileprivate struct ReflectPayload: Decodable {
            let prompt: String
        }

        fileprivate struct CompletedMessage: Decodable {
            let result: Terminal
        }

        static func decodeHostRequest(_ data: Data) throws -> (id: String, request: HostRequest) {
            let decoder = JSONDecoder()
            let header = try decoder.decode(HostRequestHeader.self, from: data)
            switch header.operation {
            case "reflect":
                return try (header.id, .reflect(prompt: decoder.decode(Payload<ReflectPayload>.self, from: data).payload.prompt))
            case "evaluate":
                return try (header.id, .evaluate(decoder.decode(Payload<EvaluateRequest>.self, from: data).payload))
            default:
                throw PromptExperimentGEPAWorker.WorkerError.protocolFailure("Unsupported GEPA host operation: \(header.operation)")
            }
        }

        static func decodeEvent(type: String, data: Data) throws -> Event? {
            let decoder = JSONDecoder()
            switch type {
            case "candidate": return try .candidate(decoder.decode(CandidateEvent.self, from: data))
            case "evaluation": return try .evaluation(decoder.decode(EvaluationEvent.self, from: data))
            case "reflection": return try .reflection(decoder.decode(ReflectionEvent.self, from: data))
            default: return nil
            }
        }

        static func decodeTerminal(_ data: Data) throws -> Terminal {
            try JSONDecoder().decode(CompletedMessage.self, from: data).result
        }
    }

    typealias GEPAWorkerHostHandler = @MainActor @Sendable (GEPAWorkerProtocol.HostRequest) async -> GEPAWorkerProtocol.HostReply
    typealias GEPAWorkerEventHandler = @MainActor @Sendable (GEPAWorkerProtocol.Event) async throws -> Void

    /// App-owned per-attempt worker files (process home, scratch, and redacted logs).
    struct GEPAWorkerLayout: Equatable {
        let attemptDirectory: URL
        /// Relative to the Prompt Experiment store root, for persisted diagnostics.
        let relativeAttemptDirectory: String

        var home: URL {
            attemptDirectory.appendingPathComponent("home", isDirectory: true)
        }

        var temporary: URL {
            attemptDirectory.appendingPathComponent("tmp", isDirectory: true)
        }

        var stderrURL: URL {
            attemptDirectory.appendingPathComponent("worker-stderr.log")
        }

        var protocolURL: URL {
            attemptDirectory.appendingPathComponent("stdout-protocol.ndjson")
        }

        var stderrRelativePath: String {
            "\(relativeAttemptDirectory)/worker-stderr.log"
        }

        var protocolRelativePath: String {
            "\(relativeAttemptDirectory)/stdout-protocol.ndjson"
        }
    }

    struct GEPAWorkerCompletion: Equatable {
        let terminal: GEPAWorkerProtocol.Terminal
        /// The exact final protocol line (small by construction), kept as raw evidence.
        let rawResultJSON: Data
    }

    /// The process seam the run controller drives; tests substitute a scripted worker.
    protocol GEPAWorkerRunning: AnyObject {
        func run(
            request: GEPAWorkerProtocol.RunRequest,
            pythonSealValue: String,
            layout: GEPAWorkerLayout,
            host: @escaping GEPAWorkerHostHandler,
            event: @escaping GEPAWorkerEventHandler,
            observation: @escaping @MainActor @Sendable (PromptExperimentRuntimeObservation) async -> Void
        ) async throws -> GEPAWorkerCompletion
        func cancel()
    }

    /// Runs the app-bundled, pinned Python GEPA environment. The child receives no provider
    /// credentials; all model and grading work round-trips to app-owned callbacks.
    final class PromptExperimentGEPAWorker: GEPAWorkerRunning, @unchecked Sendable {
        enum WorkerError: LocalizedError {
            case unavailable(String)
            case protocolFailure(String)
            case infrastructureFailure(String)

            var errorDescription: String? {
                switch self {
                case let .unavailable(message), let .protocolFailure(message), let .infrastructureFailure(message):
                    message
                }
            }
        }

        private let lock = NSLock()
        private let processLifecycleLock = NSLock()
        private let cancellationQueue = DispatchQueue(label: "com.repoprompt.prompt-experiment.worker-cancellation")
        private var process: Process?
        private var cancellationWriteHandle: FileHandle?
        private var didRequestCancellation = false

        static func resolveWorkerURL() throws -> URL {
            try resolveWorkerURL(
                resourcesDirectory: Bundle.main.resourceURL,
                sourceFileURL: URL(fileURLWithPath: #filePath),
                isPackagedApp: Bundle.main.bundleURL.pathExtension == "app",
                override: ProcessInfo.processInfo.environment["REPOPROMPT_GEPA_WORKER"]
            )
        }

        static func resolveWorkerURL(
            resourcesDirectory: URL?,
            sourceFileURL: URL,
            isPackagedApp: Bool,
            override: String? = nil
        ) throws -> URL {
            if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
                let worker = URL(fileURLWithPath: override).standardizedFileURL
                guard isReadableWorker(at: worker) else {
                    throw WorkerError.unavailable("The explicit developer GEPA worker override is not a readable file.")
                }
                return worker
            }

            if let resource = resourcesDirectory?
                .appendingPathComponent("PromptExperiments/gepa_worker.py"),
                isReadableWorker(at: resource)
            {
                return resource
            }

            // A packaged app must use its own worker. Falling back to an arbitrary checkout
            // hides an incomplete package and can pair stale code with the pinned runtime.
            guard !isPackagedApp else {
                throw WorkerError.unavailable("The packaged GEPA worker is missing or unreadable. Rebuild the debug app before starting an experiment.")
            }
            // Unbundled SwiftPM/test launches must not depend on Finder's or the caller's cwd.
            // <repo>/Sources/RepoPrompt/Features/PromptExperiments/PromptExperimentGEPAWorker.swift
            var repositoryRoot = sourceFileURL
            for _ in 0 ..< 5 {
                repositoryRoot.deleteLastPathComponent()
            }
            let source = repositoryRoot.appendingPathComponent("AppResources/PromptExperiments/gepa_worker.py")
            guard isReadableWorker(at: source) else {
                throw WorkerError.unavailable("The development GEPA worker is unavailable. Build the packaged debug app or configure an explicit developer worker override.")
            }
            return source
        }

        private static func isReadableWorker(at url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && FileManager.default.isReadableFile(atPath: url.path)
        }

        static let pythonVersion = "3.11.16"
        private static let bundledSchemePrefix = "bundle://PromptExperimentPython/"

        static var bundledRuntimeAvailable: Bool {
            (try? resolveWorkerURL()) != nil
                && (try? resolvePythonExecutable(sealedValue: bundledPythonSealValue())) != nil
        }

        static var runtimeStatus: String {
            do {
                _ = try resolveWorkerURL()
            } catch {
                return error.localizedDescription
            }
            if ProcessInfo.processInfo.environment["REPOPROMPT_GEPA_PYTHON"]?.isEmpty == false {
                return configuredPythonExecutable() == nil
                    ? "The explicit developer interpreter override is unavailable."
                    : "Using an explicit developer interpreter override; normal packaged builds use the bundled runtime."
            }
            return bundledRuntimeAvailable
                ? "Bundled CPython \(pythonVersion) and GEPA \(PromptExperimentGEPAConfiguration.packageVersion) are ready; no user setup is required."
                : "The packaged Prompt Experiment runtime is missing from this build. Repackage the app from the repository; no user-side Python installation is supported."
        }

        static func configuredPythonSealValue() -> String {
            if let override = ProcessInfo.processInfo.environment["REPOPROMPT_GEPA_PYTHON"]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty
            {
                return URL(fileURLWithPath: override).standardizedFileURL.path
            }
            return bundledPythonSealValue()
        }

        static func configuredPythonExecutable() -> String? {
            try? resolvePythonExecutable(sealedValue: configuredPythonSealValue()).path
        }

        static func resolvePythonExecutable(sealedValue: String) throws -> URL {
            if sealedValue.hasPrefix(bundledSchemePrefix) {
                guard sealedValue == bundledPythonSealValue() else {
                    throw WorkerError.unavailable("The sealed bundled interpreter architecture is stale. Refresh capabilities and reseal the draft.")
                }
                let root = bundledRuntimeRootURL()
                try validateBundledProvenance(at: root.appendingPathComponent(runtimeArchitecture, isDirectory: true))
                let candidate = root
                    .appendingPathComponent(runtimeArchitecture, isDirectory: true)
                    .appendingPathComponent("python/bin/python3.11")
                guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
                    throw WorkerError.unavailable("The signed app does not contain its bundled Prompt Experiment interpreter for \(runtimeArchitecture).")
                }
                return candidate
            }

            guard let override = ProcessInfo.processInfo.environment["REPOPROMPT_GEPA_PYTHON"]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty
            else {
                throw WorkerError.unavailable("External interpreter paths are not accepted by packaged Prompt Experiments. Reseal against the bundled runtime.")
            }
            let requested = URL(fileURLWithPath: sealedValue).standardizedFileURL.resolvingSymlinksInPath()
            let configured = URL(fileURLWithPath: override).standardizedFileURL.resolvingSymlinksInPath()
            guard requested.path == configured.path,
                  FileManager.default.isExecutableFile(atPath: configured.path)
            else {
                throw WorkerError.unavailable("The sealed interpreter does not match the explicit developer override. Refresh capabilities and reseal the draft.")
            }
            return configured
        }

        private static var runtimeArchitecture: String {
            #if arch(arm64)
                "arm64"
            #elseif arch(x86_64)
                "x86_64"
            #else
                "unsupported"
            #endif
        }

        private static func bundledPythonSealValue() -> String {
            "\(bundledSchemePrefix)\(runtimeArchitecture)/python/bin/python3.11"
        }

        private static func bundledRuntimeRootURL() -> URL {
            if let override = ProcessInfo.processInfo.environment["REPOPROMPT_GEPA_BUNDLED_RUNTIME_ROOT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty
            {
                return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
            }
            return Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/BundledRuntimes/PromptExperimentPython", isDirectory: true)
        }

        private static func validateBundledProvenance(at targetRoot: URL) throws {
            let provenanceURL = targetRoot.appendingPathComponent("provenance.json")
            guard let data = try? Data(contentsOf: provenanceURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["schema_version"] as? Int == 1,
                  object["architecture"] as? String == runtimeArchitecture,
                  object["python_version"] as? String == pythonVersion,
                  object["gepa_version"] as? String == PromptExperimentGEPAConfiguration.packageVersion,
                  object["gepa_revision"] as? String == PromptExperimentGEPAConfiguration.pinnedRevision,
                  (object["gepa_requires_dist"] as? [String])?.isEmpty == true
            else {
                throw WorkerError.unavailable("The bundled Prompt Experiment runtime provenance is missing or does not match the app's pinned Python/GEPA contract.")
            }
        }

        static func preflight(pythonExecutable: String) async throws {
            let workerURL = try resolveWorkerURL()
            let executable = try resolvePythonExecutable(sealedValue: pythonExecutable)
            try await Task.detached(priority: .utility) {
                guard FileManager.default.isReadableFile(atPath: workerURL.path) else {
                    throw WorkerError.unavailable("The packaged GEPA worker is unreadable.")
                }
                let preflightRoot = PromptExperimentStore.liveRootURL()
                    .appendingPathComponent("worker-preflight", isDirectory: true)
                let home = preflightRoot.appendingPathComponent("home", isDirectory: true)
                let temporary = preflightRoot.appendingPathComponent("tmp", isDirectory: true)
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                let process = Process()
                let output = Pipe()
                process.executableURL = executable
                process.arguments = ["-I", "-B", "-u", workerURL.path, "--preflight"]
                process.environment = workerEnvironment(home: home, temporaryDirectory: temporary)
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                try validatePreflightResponse(data, terminationStatus: process.terminationStatus)
            }.value
        }

        static func validatePreflightResponse(_ data: Data, terminationStatus: Int32) throws {
            guard terminationStatus == 0,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "ready",
                  object["protocol_version"] as? Int == GEPAWorkerProtocol.version,
                  object["python_version"] as? [Int] == pythonVersion.split(separator: ".").compactMap({ Int($0) }),
                  object["gepa_version"] as? String == PromptExperimentGEPAConfiguration.packageVersion,
                  object["upstream_revision"] as? String == PromptExperimentGEPAConfiguration.pinnedRevision
            else {
                throw WorkerError.unavailable("The GEPA worker did not pass its readiness check. Rebuild the debug app to restore its matching worker and Python runtime; no model calls were made.")
            }
        }

        func cancel() {
            lock.lock()
            let shouldSignal = !didRequestCancellation
            didRequestCancellation = true
            let process = process
            let cancellationWriteHandle = shouldSignal ? cancellationWriteHandle : nil
            lock.unlock()
            try? cancellationWriteHandle?.write(contentsOf: Data([1]))
            if shouldSignal, let process {
                cancellationQueue.async { [self] in
                    requestCancellationEscalation(process)
                }
            }
        }

        func run(
            request: GEPAWorkerProtocol.RunRequest,
            pythonSealValue: String,
            layout: GEPAWorkerLayout,
            host: @escaping GEPAWorkerHostHandler,
            event: @escaping GEPAWorkerEventHandler,
            observation: @escaping @MainActor @Sendable (PromptExperimentRuntimeObservation) async -> Void
        ) async throws -> GEPAWorkerCompletion {
            let workerURL: URL
            let pythonExecutable: URL
            let stderrLog: SafeDiagnosticLog
            let protocolLog: SafeDiagnosticLog
            let initial: Data
            do {
                try FileManager.default.createDirectory(at: layout.home, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: layout.temporary, withIntermediateDirectories: true)
                workerURL = try Self.resolveWorkerURL()
                pythonExecutable = try Self.resolvePythonExecutable(sealedValue: pythonSealValue)
                stderrLog = try SafeDiagnosticLog(url: layout.stderrURL)
                protocolLog = try SafeDiagnosticLog(url: layout.protocolURL)
                let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                initial = try JSONSerialization.data(
                    withJSONObject: ["protocol_version": GEPAWorkerProtocol.version, "type": "run", "request": body],
                    options: [.sortedKeys]
                )
            } catch {
                await observation(.workerLaunchFailed(error.localizedDescription))
                throw error
            }
            defer {
                stderrLog.close()
                protocolLog.close()
            }
            await observation(.workerPrepared(
                stderrLogRelativePath: layout.stderrRelativePath,
                stdoutProtocolLogRelativePath: layout.protocolRelativePath
            ))

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async { [self] in
                        do {
                            try continuation.resume(returning: blockingRun(
                                pythonExecutable: pythonExecutable,
                                workerURL: workerURL,
                                initial: initial,
                                stderrLog: stderrLog,
                                protocolLog: protocolLog,
                                layout: layout,
                                host: host,
                                event: event,
                                observation: observation
                            ))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: { [self] in
                cancel()
            }
        }

        private func blockingRun(
            pythonExecutable: URL,
            workerURL: URL,
            initial: Data,
            stderrLog: SafeDiagnosticLog,
            protocolLog: SafeDiagnosticLog,
            layout: GEPAWorkerLayout,
            host: @escaping GEPAWorkerHostHandler,
            event: @escaping GEPAWorkerEventHandler,
            observation: @escaping @MainActor @Sendable (PromptExperimentRuntimeObservation) async -> Void
        ) throws -> GEPAWorkerCompletion {
            let child = Process()
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let cancellationPipe = Pipe()
            child.executableURL = pythonExecutable
            child.arguments = ["-I", "-B", "-u", workerURL.path]
            // Deliberately do not inherit the app environment: provider credentials and
            // authentication remain inside RepoPrompt.
            child.environment = Self.workerEnvironment(home: layout.home, temporaryDirectory: layout.temporary)
            child.standardInput = stdinPipe
            child.standardOutput = stdoutPipe
            child.standardError = stderrPipe
            lock.lock()
            if didRequestCancellation {
                lock.unlock()
                throw CancellationError()
            }
            cancellationWriteHandle = cancellationPipe.fileHandleForWriting
            lock.unlock()
            do {
                try child.run()
            } catch {
                emitObservation(.workerLaunchFailed(error.localizedDescription), using: observation)
                lock.lock()
                process = nil
                cancellationWriteHandle = nil
                lock.unlock()
                throw error
            }
            lock.lock()
            process = child
            lock.unlock()
            let stderrDrain = DispatchGroup()
            stderrDrain.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { stderrDrain.leave() }
                var reader = PromptExperimentPipeChunkReader(handle: stderrPipe.fileHandleForReading)
                var didReportRedactedOutput = false
                do {
                    while let chunk = try reader.nextChunk() {
                        let detail = Self.safeStderrDetail(chunk)
                        try stderrLog.append(channel: "stderr", event: "worker_output", detail: detail)
                        let isRedacted = detail.hasPrefix("[redacted ")
                        if !isRedacted || !didReportRedactedOutput {
                            self.emitObservation(
                                .protocolEvent(channel: "stderr", event: "worker_output", detail: detail),
                                using: observation
                            )
                        }
                        didReportRedactedOutput = didReportRedactedOutput || isRedacted
                    }
                } catch {
                    try? stderrLog.append(channel: "stderr", event: "read_failed", detail: error.localizedDescription)
                }
            }
            try? stderrPipe.fileHandleForWriting.close()
            emitObservation(
                .workerStarted(
                    pid: child.processIdentifier,
                    processIdentity: "CPython \(Self.pythonVersion) / GEPA \(PromptExperimentGEPAConfiguration.packageVersion) / pid \(child.processIdentifier)"
                ),
                using: observation
            )
            defer {
                terminateAndReap(child)
                stderrDrain.wait()
                emitObservation(
                    .workerExited(
                        status: child.terminationStatus,
                        stderrLogByteCount: stderrLog.byteCount,
                        stderrLogTruncated: stderrLog.isTruncated,
                        protocolLogByteCount: protocolLog.byteCount,
                        protocolLogTruncated: protocolLog.isTruncated
                    ),
                    using: observation
                )
                lock.lock()
                process = nil
                cancellationWriteHandle = nil
                lock.unlock()
            }
            lock.lock()
            let cancelledAfterLaunch = didRequestCancellation
            lock.unlock()
            if cancelledAfterLaunch {
                child.interrupt()
                throw CancellationError()
            }
            try writeLine(initial, to: stdinPipe.fileHandleForWriting)
            try protocolLog.append(channel: "stdin", event: "run_request_written", detail: "payload=excluded")
            emitObservation(
                .protocolEvent(channel: "stdin", event: "run_request_written", detail: "payload=excluded"),
                using: observation
            )
            var reader = PromptExperimentNDJSONLineReader(
                handle: stdoutPipe.fileHandleForReading,
                cancellationHandle: cancellationPipe.fileHandleForReading
            )
            var completion: GEPAWorkerCompletion?
            var terminalError: Error?
            while let data = try reader.nextLine() {
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard let object,
                      let header = try? JSONDecoder().decode(GEPAWorkerProtocol.Header.self, from: data),
                      header.protocolVersion == GEPAWorkerProtocol.version
                else {
                    try? protocolLog.append(channel: "stdout", event: "invalid_protocol", detail: nil)
                    throw WorkerError.protocolFailure("GEPA worker emitted invalid protocol JSON.")
                }
                let type = header.type
                let protocolDetail = Self.safeProtocolDetail(type: type, object: object)
                try protocolLog.append(channel: "stdout", event: type, detail: protocolDetail)
                emitObservation(.protocolEvent(channel: "stdout", event: type, detail: protocolDetail), using: observation)
                switch type {
                case "host_request":
                    let decoded: (id: String, request: GEPAWorkerProtocol.HostRequest)
                    do {
                        decoded = try GEPAWorkerProtocol.decodeHostRequest(data)
                    } catch {
                        throw WorkerError.protocolFailure("GEPA host request is incomplete.")
                    }
                    let operation = switch decoded.request {
                    case .reflect: "reflect"
                    case .evaluate: "evaluate"
                    }
                    emitObservation(.callbackStarted(id: decoded.id, operation: operation), using: observation)
                    let request = decoded.request
                    let reply = try awaitMainActor(child: child) { await host(request) }
                    emitObservation(.callbackFinished(id: decoded.id, operation: operation), using: observation)
                    let response = try JSONSerialization.data(withJSONObject: reply.jsonObject(id: decoded.id), options: [.sortedKeys])
                    try writeLine(response, to: stdinPipe.fileHandleForWriting)
                case "candidate", "evaluation", "reflection":
                    let decodedEvent: GEPAWorkerProtocol.Event?
                    do {
                        decodedEvent = try GEPAWorkerProtocol.decodeEvent(type: type, data: data)
                    } catch {
                        throw WorkerError.protocolFailure("GEPA \(type) event is invalid.")
                    }
                    guard let decodedEvent else { throw WorkerError.protocolFailure("GEPA event type is unsupported.") }
                    let outcome: Result<Void, Error> = try awaitMainActor(child: child) {
                        do {
                            try await event(decodedEvent)
                            return .success(())
                        } catch {
                            return .failure(error)
                        }
                    }
                    try outcome.get()
                case "completed":
                    do {
                        completion = try GEPAWorkerCompletion(terminal: GEPAWorkerProtocol.decodeTerminal(data), rawResultJSON: data)
                    } catch {
                        throw WorkerError.protocolFailure("GEPA completion summary is invalid.")
                    }
                case "cancelled":
                    terminalError = CancellationError()
                case "failed":
                    let safeFailure = protocolDetail
                        ?? "exception_type=unavailable source_frame=unavailable envelope=invalid error_payload=excluded"
                    terminalError = WorkerError.infrastructureFailure(
                        "GEPA worker reported a failure (\(safeFailure)); inspect the persisted redacted diagnostics."
                    )
                default:
                    throw WorkerError.protocolFailure("Unsupported GEPA worker message type: \(type)")
                }
                if completion != nil || terminalError != nil { break }
            }
            stdinPipe.fileHandleForWriting.closeFile()
            child.waitUntilExit()
            stderrDrain.wait()
            lock.lock()
            let cancelled = didRequestCancellation
            lock.unlock()
            if cancelled { throw CancellationError() }
            if let terminalError { throw terminalError }
            guard child.terminationStatus == 0, let completion else {
                throw WorkerError.infrastructureFailure(
                    "GEPA worker terminated without a result (status \(child.terminationStatus)); inspect the persisted attempt diagnostics and redacted worker logs."
                )
            }
            return completion
        }

        /// Runs `operation` on the main actor while the protocol thread waits. Cancellation or
        /// worker exit abandons the wait and cancels only this attempt's callback task.
        private func awaitMainActor<Value>(
            child: Process,
            _ operation: @escaping @MainActor @Sendable () async -> Value
        ) throws -> Value {
            let semaphore = DispatchSemaphore(value: 0)
            let box = PromptExperimentLockedBox<Value>()
            let task = Task { @MainActor in
                await box.store(operation())
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
                lock.lock()
                let cancelled = didRequestCancellation
                lock.unlock()
                if cancelled {
                    task.cancel()
                    throw CancellationError()
                }
                if !child.isRunning {
                    task.cancel()
                    throw WorkerError.infrastructureFailure("GEPA worker exited while its host callback was pending.")
                }
            }
            guard let value = box.load() else { throw WorkerError.protocolFailure("The app did not produce a host reply.") }
            return value
        }

        private func emitObservation(
            _ value: PromptExperimentRuntimeObservation,
            using observation: @escaping @MainActor @Sendable (PromptExperimentRuntimeObservation) async -> Void
        ) {
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await observation(value)
                semaphore.signal()
            }
            semaphore.wait()
        }

        static func safeProtocolDetail(type: String, object: [String: Any]) -> String? {
            switch type {
            case "host_request":
                let id = object["id"] as? String ?? "unknown"
                let operation = ["reflect", "evaluate"].contains(object["operation"] as? String ?? "")
                    ? (object["operation"] as? String ?? "unknown") : "unknown"
                return "callback_id=\(id) operation=\(operation) payload=excluded"
            case "candidate":
                let index = object["candidate_index"] as? Int ?? -1
                let digest = safeSHA256(object["candidate_sha256"]) ?? "unavailable"
                return "candidate_index=\(index) candidate_sha256=\(digest) text=excluded"
            case "evaluation":
                let split = PromptExperimentDatasetSplit(rawValue: object["split"] as? String ?? "")?.rawValue ?? "unknown"
                let replayed = object["replayed"] as? Bool ?? false
                return "split=\(split) replayed=\(replayed) payload=excluded"
            case "reflection":
                let contract = ["envelope", "fenced_block", "raw"].contains(object["contract"] as? String ?? "")
                    ? (object["contract"] as? String ?? "unknown") : "unknown"
                return "contract=\(contract) payload=excluded"
            case "completed":
                return "result_payload=excluded"
            case "cancelled":
                return "signal=\(object["signal"] as? Int ?? -1) payload=excluded"
            case "failed":
                guard let diagnostic = object["diagnostic"] as? [String: Any] else {
                    return "exception_type=unavailable source_frame=unavailable envelope=legacy error_payload=excluded"
                }
                guard diagnostic["schema_version"] as? Int == 1,
                      let exceptionType = safePythonIdentifier(diagnostic["exception_type"]),
                      let sourceFrame = diagnostic["source_frame"] as? [String: Any],
                      let module = safePythonIdentifier(sourceFrame["module"], dotted: true),
                      let function = safePythonIdentifier(sourceFrame["function"]),
                      let line = sourceFrame["line"] as? Int,
                      line > 0
                else {
                    return "exception_type=unavailable source_frame=unavailable envelope=invalid error_payload=excluded"
                }
                let code = diagnostic["failure_code"] as? String
                let safeCode = ["judge_invalid_response", "judge_provider_failed", "ledger_failure", "cancelled"].contains(code ?? "")
                    ? code! : (Self.safeProviderFailureCode(code) ?? "unavailable")
                return "exception_type=\(exceptionType) source_frame=\(module).\(function):\(line) failure_code=\(safeCode) error_payload=excluded"
            default:
                return nil
            }
        }

        private static func safeSHA256(_ rawValue: Any?) -> String? {
            guard let value = rawValue as? String, value.count == 64,
                  value.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) })
            else { return nil }
            return value
        }

        private static func safeProviderFailureCode(_ rawValue: Any?) -> String? {
            guard let value = rawValue as? String,
                  PromptExperimentProviderFailureCode.allCases.map(\.rawValue).contains(value)
            else { return nil }
            return value
        }

        private static func safePythonIdentifier(_ rawValue: Any?, dotted: Bool = false) -> String? {
            guard let value = rawValue as? String,
                  !value.isEmpty,
                  value.utf8.count <= 256
            else { return nil }
            let components = dotted
                ? value.split(separator: ".", omittingEmptySubsequences: false)
                : [Substring(value)]
            guard components.allSatisfy({ component in
                guard !component.isEmpty,
                      component.utf8.count <= 128,
                      let first = component.utf8.first,
                      first == 95 || (65 ... 90).contains(first) || (97 ... 122).contains(first)
                else { return false }
                return component.utf8.dropFirst().allSatisfy { byte in
                    byte == 95 || (48 ... 57).contains(byte) || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
                }
            }) else { return nil }
            return value
        }

        static func safeStderrDetail(_ data: Data) -> String {
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let allowlistedMessages = [
                "Generating initial seed candidate via LLM...",
                "Traceback (most recent call last):"
            ]
            if allowlistedMessages.contains(text) {
                return text
            }
            return "[redacted \(data.count) bytes]"
        }

        private func writeLine(_ data: Data, to handle: FileHandle) throws {
            var line = data
            line.append(0x0A)
            try handle.write(contentsOf: line)
        }

        private func requestCancellationEscalation(_ child: Process) {
            processLifecycleLock.lock()
            defer { processLifecycleLock.unlock() }
            Self.sendCancellationSignals(child)
        }

        private static func sendCancellationSignals(_ child: Process) {
            guard child.isRunning else { return }
            child.interrupt()
            let interruptDeadline = Date().addingTimeInterval(1)
            while child.isRunning, Date() < interruptDeadline {
                usleep(20000)
            }
            if child.isRunning {
                child.terminate()
                let terminateDeadline = Date().addingTimeInterval(1)
                while child.isRunning, Date() < terminateDeadline {
                    usleep(20000)
                }
            }
            if child.isRunning {
                kill(child.processIdentifier, SIGKILL)
            }
        }

        private func terminateAndReap(_ child: Process) {
            processLifecycleLock.lock()
            defer { processLifecycleLock.unlock() }
            if child.isRunning {
                Self.sendCancellationSignals(child)
            }
            child.waitUntilExit()
        }

        static func workerEnvironment(
            home: URL,
            temporaryDirectory: URL? = nil
        ) -> [String: String] {
            let current = ProcessInfo.processInfo.environment
            var environment: [String: String] = [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin",
                "TMPDIR": (temporaryDirectory ?? home.appendingPathComponent("tmp", isDirectory: true)).path
            ]
            for key in ["LANG", "LC_ALL", "LC_CTYPE"] {
                if let value = current[key], !value.isEmpty {
                    environment[key] = value
                }
            }
            return environment
        }
    }

    private final class SafeDiagnosticLog: @unchecked Sendable {
        private static let maximumBytes = 4 * 1024 * 1024

        private let lock = NSLock()
        private let handle: FileHandle
        private var storedByteCount = 0
        private var storedTruncated = false
        private var isClosed = false

        init(url: URL) throws {
            try Data().write(to: url, options: [.atomic])
            handle = try FileHandle(forWritingTo: url)
        }

        deinit {
            close()
        }

        var byteCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedByteCount
        }

        var isTruncated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storedTruncated
        }

        func append(channel: String, event: String, detail: String?) throws {
            var object: [String: Any] = [
                "observed_at": ISO8601DateFormatter().string(from: Date()),
                "channel": channel,
                "event": event
            ]
            if let detail { object["detail"] = detail }
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(0x0A)

            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return }
            if storedByteCount + data.count > Self.maximumBytes {
                guard !storedTruncated else { return }
                storedTruncated = true
                let marker = Data("{\"event\":\"log_truncated\"}\n".utf8)
                try handle.write(contentsOf: marker)
                storedByteCount += marker.count
                return
            }
            try handle.write(contentsOf: data)
            storedByteCount += data.count
        }

        func close() {
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return }
            try? handle.synchronize()
            try? handle.close()
            isClosed = true
        }
    }

    final class PromptExperimentLockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        func store(_ newValue: Value) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func load() -> Value? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    enum PromptExperimentPipeReadError: LocalizedError {
        case lineTooLong(maximumBytes: Int)

        var errorDescription: String? {
            switch self {
            case let .lineTooLong(maximumBytes):
                "Worker protocol line exceeded the \(maximumBytes)-byte safety limit."
            }
        }
    }

    struct PromptExperimentPipeChunkReader {
        let handle: FileHandle

        mutating func nextChunk() throws -> Data? {
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = try Self.readAvailable(handle: handle, bytes: &bytes)
            return count == 0 ? nil : Data(bytes.prefix(count))
        }

        fileprivate static func readAvailable(handle: FileHandle, bytes: inout [UInt8]) throws -> Int {
            try bytes.withUnsafeMutableBytes { storage -> Int in
                while true {
                    let result = Darwin.read(handle.fileDescriptor, storage.baseAddress, storage.count)
                    if result >= 0 { return result }
                    if errno != EINTR {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            }
        }
    }

    struct PromptExperimentNDJSONLineReader {
        static let defaultMaximumLineBytes = 16 * 1024 * 1024

        let handle: FileHandle
        let cancellationHandle: FileHandle?
        let maximumLineBytes: Int
        var buffer = Data()

        init(
            handle: FileHandle,
            cancellationHandle: FileHandle? = nil,
            maximumLineBytes: Int = Self.defaultMaximumLineBytes
        ) {
            self.handle = handle
            self.cancellationHandle = cancellationHandle
            self.maximumLineBytes = maximumLineBytes
        }

        mutating func nextLine() throws -> Data? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    return Data(line)
                }
                try waitUntilReadableOrCancelled()
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = try PromptExperimentPipeChunkReader.readAvailable(handle: handle, bytes: &bytes)
                if count == 0 {
                    guard !buffer.isEmpty else { return nil }
                    defer { buffer.removeAll() }
                    return buffer
                }
                guard buffer.count + count <= maximumLineBytes else {
                    throw PromptExperimentPipeReadError.lineTooLong(maximumBytes: maximumLineBytes)
                }
                buffer.append(contentsOf: bytes.prefix(count))
            }
        }

        private func waitUntilReadableOrCancelled() throws {
            guard let cancellationHandle else { return }
            var descriptors = [
                pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: cancellationHandle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            ]
            while true {
                let result = Darwin.poll(&descriptors, nfds_t(descriptors.count), -1)
                if result > 0 {
                    if descriptors[1].revents != 0 { throw CancellationError() }
                    if descriptors[0].revents != 0 { return }
                } else if result < 0, errno != EINTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }
#endif
