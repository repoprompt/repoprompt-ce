#if DEBUG
    import Darwin
    import Foundation

    struct PromptExperimentGEPAHostReply {
        let ok: Bool
        let output: String?
        let score: Double?
        let feedback: String?
        let failureKind: PromptExperimentOptimizationFailureKind?
        let error: String?
        let elapsedSeconds: Double?
        var promptTokens: Int?
        var completionTokens: Int?

        var jsonObject: [String: Any] {
            var value: [String: Any] = ["ok": ok]
            if let output { value["output"] = output }
            if let score { value["score"] = score }
            if let feedback { value["feedback"] = feedback }
            if let failureKind { value["failure_kind"] = failureKind.rawValue }
            if let error { value["error"] = error }
            if let elapsedSeconds { value["elapsed_seconds"] = elapsedSeconds }
            if let promptTokens { value["prompt_tokens"] = promptTokens }
            if let completionTokens { value["completion_tokens"] = completionTokens }
            return value
        }
    }

    /// Runs the separately configured, pinned Python GEPA environment. The child receives no
    /// provider credentials; all model and workflow work round-trips to app-owned callbacks.
    final class PromptExperimentGEPAWorker: @unchecked Sendable {
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
        private var process: Process?
        private var didRequestCancellation = false

        static func resolveWorkerURL() throws -> URL {
            if let override = ProcessInfo.processInfo.environment["REPOPROMPT_GEPA_WORKER"], !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            if let resource = Bundle.main.resourceURL?
                .appendingPathComponent("PromptExperiments/gepa_worker.py"),
                FileManager.default.fileExists(atPath: resource.path)
            {
                return resource
            }
            let sourceTree = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("AppResources/PromptExperiments/gepa_worker.py")
            guard FileManager.default.fileExists(atPath: sourceTree.path) else {
                throw WorkerError.unavailable("The packaged GEPA worker resource is unavailable.")
            }
            return sourceTree
        }

        static var setupInstructions: String {
            let python = defaultPythonExecutableURL().path
            let environment = URL(fileURLWithPath: python).deletingLastPathComponent().deletingLastPathComponent().path
            let pip = URL(fileURLWithPath: python).deletingLastPathComponent().appendingPathComponent("pip").path
            let requirements = resolvedRequirementsURL()?.path ?? "<RepoPrompt checkout>/AppResources/PromptExperiments/gepa-requirements.txt"
            return "GEPA \(PromptExperimentGEPAConfiguration.packageVersion) requires Python >=3.10,<3.15. Choose a compatible interpreter (for example python3.11) and verify it before installing: python3.11 -c 'import sys; assert (3, 10) <= sys.version_info < (3, 15), sys.version' && python3.11 -m venv '\(environment)' && '\(pip)' install -r '\(requirements)'. This requirements input pins GEPA itself; transitive dependencies are not hash-locked. No installation is automatic. Then restart the DEBUG app with REPOPROMPT_GEPA_PYTHON set only if using a different reviewed environment."
        }

        private static func resolvedRequirementsURL() -> URL? {
            if let resource = Bundle.main.resourceURL?
                .appendingPathComponent("PromptExperiments/gepa-requirements.txt"),
                FileManager.default.isReadableFile(atPath: resource.path)
            {
                return resource
            }
            let sourceTree = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("AppResources/PromptExperiments/gepa-requirements.txt")
            return FileManager.default.isReadableFile(atPath: sourceTree.path) ? sourceTree : nil
        }

        static func configuredPythonExecutable() -> String? {
            if let override = ProcessInfo.processInfo.environment["REPOPROMPT_GEPA_PYTHON"]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty
            {
                return override
            }
            let candidate = defaultPythonExecutableURL().path
            return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
        }

        private static func defaultPythonExecutableURL() -> URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/RepoPrompt CE/GEPA/venv/bin/python3")
        }

        static func preflight(pythonExecutable: String) async throws {
            let workerURL = try resolveWorkerURL()
            let expectedRevision = PromptExperimentGEPAConfiguration.pinnedRevision
            let expectedVersion = PromptExperimentGEPAConfiguration.packageVersion
            guard let configured = configuredPythonExecutable() else {
                throw WorkerError.unavailable("No native-owned external GEPA environment is configured. \(setupInstructions)")
            }
            let requested = URL(fileURLWithPath: pythonExecutable).standardizedFileURL.resolvingSymlinksInPath().path
            let approved = URL(fileURLWithPath: configured).standardizedFileURL.resolvingSymlinksInPath().path
            guard requested == approved else {
                throw WorkerError.unavailable("The sealed interpreter does not match the native configured GEPA environment. Refresh capabilities and reseal the draft.")
            }
            let script = """
            import importlib.metadata, json
            d=importlib.metadata.distribution('gepa')
            direct=d.read_text('direct_url.json')
            revision=(json.loads(direct).get('vcs_info',{}).get('commit_id') if direct else None)
            assert importlib.metadata.version('gepa') == '\(expectedVersion)', 'GEPA version mismatch'
            assert revision == '\(expectedRevision)', 'GEPA git revision mismatch or unavailable'
            """
            try await Task.detached(priority: .utility) {
                guard FileManager.default.isExecutableFile(atPath: pythonExecutable) else {
                    throw WorkerError.unavailable("The configured external Python executable is unavailable or not executable: \(pythonExecutable)")
                }
                guard FileManager.default.isReadableFile(atPath: workerURL.path) else {
                    throw WorkerError.unavailable("The packaged GEPA worker is unreadable.")
                }
                guard resolvedRequirementsURL() != nil else {
                    throw WorkerError.unavailable("The pinned GEPA requirements input is unavailable.")
                }
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: pythonExecutable)
                process.arguments = ["-c", script]
                process.environment = workerEnvironment(home: FileManager.default.temporaryDirectory)
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let message = String(data: data, encoding: .utf8) ?? "unknown preflight failure"
                    throw WorkerError.unavailable("Pinned GEPA preflight failed without making a model call: \(message)")
                }
            }.value
        }

        func cancel() {
            lock.lock()
            didRequestCancellation = true
            let process = process
            lock.unlock()
            process?.interrupt()
        }

        func run(
            plan: PromptExperimentPlan,
            attemptID: UUID,
            host: @escaping @MainActor @Sendable (_ operation: String, _ payload: [String: Any]) async -> PromptExperimentGEPAHostReply,
            progress: @escaping @MainActor @Sendable (String) async -> Void
        ) async throws -> PromptExperimentOptimizationRuntimeResult {
            guard let specification = plan.optimization else {
                throw WorkerError.protocolFailure("The GEPA worker received a legacy comparison plan.")
            }
            let workerURL = try Self.resolveWorkerURL()
            let runRoot = PromptExperimentStore.liveRootURL()
                .appendingPathComponent("worker-runs", isDirectory: true)
                .appendingPathComponent(attemptID.uuidString.lowercased(), isDirectory: true)
            let runDirectory = runRoot.appendingPathComponent("gepa-run", isDirectory: true)
            let outputDirectory = runRoot.appendingPathComponent("gepa-output", isDirectory: true)
            let stderrURL = runRoot.appendingPathComponent("worker-stderr.log")
            try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)

            // The worker receives only opaque IDs, splits, and current inputs. Expected outputs
            // and reviewer notes remain in the app-owned sealed plan and are looked up by ID.
            let examples: [[String: Any]] = specification.examples.map { example in
                [
                    "id": example.id,
                    "split": example.split.rawValue,
                    "input": example.input
                ]
            }
            var request: [String: Any] = [
                "run_name": "rpce-\(plan.id.uuidString.lowercased())",
                "objective": specification.objective,
                "background": specification.background,
                "task_preservation": "Evaluator, dataset, permissions, targets, and output requirements are immutable under approved plan digest \(plan.digest).",
                "examples": examples,
                "max_evaluations": specification.gepa.maxEvaluations,
                "random_seed": specification.gepa.randomSeed,
                "reflection_minibatch_size": specification.gepa.reflectionMinibatchSize ?? 3,
                "use_merge": specification.gepa.useMerge ?? false,
                "max_merge_invocations": specification.gepa.maxMergeInvocations ?? 5,
                "skip_perfect_score": specification.gepa.skipPerfectScore ?? true,
                "perfect_score": specification.evaluator.maximumScore,
                "run_dir": runDirectory.path,
                "run_directory_relative_path": "worker-runs/\(attemptID.uuidString.lowercased())",
                "output_dir": outputDirectory.path
            ]
            if let seed = specification.seedCandidate { request["seed_candidate"] = seed }
            if let stop = specification.gepa.stopAtScore { request["stop_at_score"] = stop }
            let initial: [String: Any] = [
                "protocol_version": 1,
                "type": "run",
                "request": request
            ]

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async { [self] in
                        do {
                            try continuation.resume(returning: blockingRun(
                                pythonExecutable: specification.gepa.pythonExecutablePath,
                                workerURL: workerURL,
                                initial: initial,
                                stderrURL: stderrURL,
                                host: host,
                                progress: progress,
                                hostCallbackTimeoutSeconds: min(300, specification.gepa.maxWallClockSeconds)
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
            pythonExecutable: String,
            workerURL: URL,
            initial: [String: Any],
            stderrURL: URL,
            host: @escaping @MainActor @Sendable (_ operation: String, _ payload: [String: Any]) async -> PromptExperimentGEPAHostReply,
            progress: @escaping @MainActor @Sendable (String) async -> Void,
            hostCallbackTimeoutSeconds: Int
        ) throws -> PromptExperimentOptimizationRuntimeResult {
            let child = Process()
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            guard FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
                throw WorkerError.infrastructureFailure("Could not create the GEPA worker log.")
            }
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer { try? stderrHandle.close() }
            child.executableURL = URL(fileURLWithPath: pythonExecutable)
            child.arguments = [workerURL.path]
            // Deliberately do not inherit the app environment: provider credentials and
            // authentication remain inside RepoPrompt. The worker receives only process
            // mechanics and communicates every model request over the host protocol.
            child.environment = Self.workerEnvironment(home: URL(fileURLWithPath: NSTemporaryDirectory()))
            child.standardInput = stdinPipe
            child.standardOutput = stdoutPipe
            child.standardError = stderrHandle
            lock.lock()
            if didRequestCancellation {
                lock.unlock()
                throw CancellationError()
            }
            process = child
            lock.unlock()
            defer {
                Self.terminateAndReap(child)
                lock.lock()
                process = nil
                lock.unlock()
            }
            try child.run()
            lock.lock()
            let cancelledAfterLaunch = didRequestCancellation
            lock.unlock()
            if cancelledAfterLaunch {
                child.interrupt()
                throw CancellationError()
            }
            try writeJSONLine(initial, to: stdinPipe.fileHandleForWriting)
            var reader = LineReader(handle: stdoutPipe.fileHandleForReading)
            var terminal: PromptExperimentOptimizationRuntimeResult?
            var terminalError: Error?
            while let data = try reader.nextLine() {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["protocol_version"] as? Int == 1,
                      let type = object["type"] as? String
                else {
                    throw WorkerError.protocolFailure("GEPA worker emitted invalid protocol JSON.")
                }
                switch type {
                case "host_request":
                    guard let id = object["id"] as? String,
                          let operation = object["operation"] as? String,
                          let payload = object["payload"] as? [String: Any]
                    else { throw WorkerError.protocolFailure("GEPA host request is incomplete.") }
                    let semaphore = DispatchSemaphore(value: 0)
                    let replyBox = PromptExperimentGEPAHostReplyBox()
                    let callback = Task { @MainActor in
                        let reply = await host(operation, payload)
                        replyBox.store(reply)
                        semaphore.signal()
                    }
                    let deadline = DispatchTime.now() + .seconds(hostCallbackTimeoutSeconds)
                    while semaphore.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
                        lock.lock()
                        let cancelled = didRequestCancellation
                        lock.unlock()
                        if cancelled {
                            callback.cancel()
                            throw CancellationError()
                        }
                        if DispatchTime.now() >= deadline {
                            callback.cancel()
                            throw WorkerError.infrastructureFailure("A RepoPrompt model/evaluator callback exceeded the sealed host timeout.")
                        }
                    }
                    guard let reply = replyBox.load() else { throw WorkerError.protocolFailure("The app did not produce a host reply.") }
                    var response = reply.jsonObject
                    response["protocol_version"] = 1
                    response["type"] = "host_response"
                    response["id"] = id
                    try writeJSONLine(response, to: stdinPipe.fileHandleForWriting)
                case "progress":
                    let completed = object["completed_evaluations"] as? Int ?? 0
                    let maximum = object["max_evaluations"] as? Int ?? 0
                    let candidate = object["candidate_index"] as? Int ?? 0
                    Task { @MainActor in
                        await progress("GEPA evaluated candidate \(candidate) (\(completed)/\(maximum) budget calls).")
                    }
                case "completed":
                    guard let result = object["result"] as? [String: Any] else {
                        throw WorkerError.protocolFailure("GEPA completion omitted its result.")
                    }
                    terminal = try decodeResult(result)
                case "failed":
                    terminalError = WorkerError.infrastructureFailure(object["error"] as? String ?? "GEPA worker failed.")
                default:
                    throw WorkerError.protocolFailure("Unsupported GEPA worker message type: \(type)")
                }
                if terminal != nil || terminalError != nil { break }
            }
            stdinPipe.fileHandleForWriting.closeFile()
            child.waitUntilExit()
            try stderrHandle.synchronize()
            let stderrData = (try? Data(contentsOf: stderrURL, options: [.mappedIfSafe])) ?? Data()
            let stderr = String(data: stderrData.suffix(4000), encoding: .utf8) ?? ""
            lock.lock()
            let cancelled = didRequestCancellation
            lock.unlock()
            if cancelled { throw CancellationError() }
            if let terminalError { throw terminalError }
            guard child.terminationStatus == 0, let terminal else {
                throw WorkerError.infrastructureFailure("GEPA worker terminated without a result (status \(child.terminationStatus)): \(stderr)")
            }
            return terminal
        }

        private func decodeResult(_ result: [String: Any]) throws -> PromptExperimentOptimizationRuntimeResult {
            let raw = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            guard result["engine"] as? String == "gepa",
                  result["upstream_revision"] as? String == PromptExperimentGEPAConfiguration.pinnedRevision,
                  let candidates = result["candidates"] as? [String], !candidates.isEmpty,
                  let rawParents = result["parent_indices"] as? [[Any]], rawParents.count == candidates.count,
                  let rawScores = result["aggregate_scores"] as? [Any], rawScores.count == candidates.count,
                  let rawEvaluations = result["evaluations"] as? [[String: Any]],
                  let totalEvaluations = (result["total_evaluations"] as? NSNumber)?.intValue,
                  totalEvaluations >= 0
            else {
                throw WorkerError.protocolFailure("GEPA result identity, candidate arrays, or evaluation counts are invalid.")
            }
            let parents = try rawParents.enumerated().map { index, values in
                let decoded = values.compactMap { ($0 as? NSNumber)?.intValue }
                guard decoded.count == values.count,
                      decoded.allSatisfy({ $0 >= 0 && $0 < index })
                else { throw WorkerError.protocolFailure("GEPA parent indices are invalid.") }
                return decoded
            }
            let scores = try rawScores.map { value -> Double? in
                guard !(value is NSNull) else { return nil }
                guard let score = (value as? NSNumber)?.doubleValue, score.isFinite else {
                    throw WorkerError.protocolFailure("GEPA emitted a non-finite aggregate score.")
                }
                return score
            }
            let bestIndex = (result["best_candidate_index"] as? NSNumber)?.intValue
            if let bestIndex, !(0 ..< candidates.count).contains(bestIndex) {
                throw WorkerError.protocolFailure("GEPA best candidate index is invalid.")
            }
            let evaluations = try rawEvaluations.map { value -> PromptExperimentOptimizationRuntimeEvaluation in
                guard let candidate = (value["candidate_index"] as? NSNumber)?.intValue,
                      candidate == -1 || (candidate >= 0 && candidate < candidates.count),
                      let exampleID = value["example_id"] as? String, !exampleID.isEmpty,
                      let splitRaw = value["split"] as? String,
                      let split = PromptExperimentDatasetSplit(rawValue: splitRaw)
                else { throw WorkerError.protocolFailure("GEPA evaluation identity is invalid.") }
                let score = (value["score"] as? NSNumber)?.doubleValue
                guard score?.isFinite != false else {
                    throw WorkerError.protocolFailure("GEPA emitted a non-finite evaluation score.")
                }
                let failureRaw = value["failure_kind"] as? String
                let failure = failureRaw.flatMap(PromptExperimentOptimizationFailureKind.init(rawValue:))
                guard failureRaw == nil || failure != nil else {
                    throw WorkerError.protocolFailure("GEPA emitted an unknown evaluation failure classification.")
                }
                return PromptExperimentOptimizationRuntimeEvaluation(
                    candidateIndex: candidate,
                    exampleID: exampleID,
                    split: split,
                    score: score,
                    feedback: value["feedback"] as? String ?? "",
                    failureKind: failure,
                    output: value["output"] as? String,
                    elapsedSeconds: (value["elapsed_seconds"] as? NSNumber)?.doubleValue
                )
            }
            let baselineScore = (result["baseline_score"] as? NSNumber)?.doubleValue
            let bestScore = (result["best_score"] as? NSNumber)?.doubleValue
            let wallTime = (result["wall_time_seconds"] as? NSNumber)?.doubleValue
            guard baselineScore?.isFinite != false,
                  bestScore?.isFinite != false,
                  wallTime?.isFinite != false,
                  wallTime.map({ $0 >= 0 }) != false
            else { throw WorkerError.protocolFailure("GEPA result metrics are invalid.") }
            let relativeRunDirectory = result["run_directory_relative_path"] as? String
            guard relativeRunDirectory.map({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) != false else {
                throw WorkerError.protocolFailure("GEPA result artifact path is unsafe.")
            }
            return PromptExperimentOptimizationRuntimeResult(
                engine: "gepa",
                upstreamRevision: PromptExperimentGEPAConfiguration.pinnedRevision,
                baselineScore: baselineScore,
                bestScore: bestScore,
                bestCandidateIndex: bestIndex,
                candidates: candidates,
                parentIndices: parents,
                aggregateScores: scores,
                evaluations: evaluations,
                totalEvaluations: totalEvaluations,
                wallTimeSeconds: wallTime,
                proposerUsage: result["proposer_usage"] as? String ?? "unavailable",
                runDirectoryRelativePath: relativeRunDirectory,
                rawResultJSON: raw
            )
        }

        private func writeJSONLine(_ object: [String: Any], to handle: FileHandle) throws {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(0x0A)
            try handle.write(contentsOf: data)
        }

        private static func terminateAndReap(_ child: Process) {
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
            child.waitUntilExit()
        }

        static func workerEnvironment(home: URL) -> [String: String] {
            let current = ProcessInfo.processInfo.environment
            var environment: [String: String] = [
                "HOME": home.path,
                "PATH": current["PATH"] ?? "/usr/bin:/bin",
                "PYTHONUNBUFFERED": "1",
                "TMPDIR": NSTemporaryDirectory()
            ]
            for key in ["LANG", "LC_ALL", "LC_CTYPE"] {
                if let value = current[key], !value.isEmpty {
                    environment[key] = value
                }
            }
            return environment
        }
    }

    private final class PromptExperimentGEPAHostReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: PromptExperimentGEPAHostReply?

        func store(_ reply: PromptExperimentGEPAHostReply) {
            lock.lock()
            value = reply
            lock.unlock()
        }

        func load() -> PromptExperimentGEPAHostReply? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private struct LineReader {
        let handle: FileHandle
        var buffer = Data()

        mutating func nextLine() throws -> Data? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    return Data(line)
                }
                let chunk = try handle.read(upToCount: 8192) ?? Data()
                if chunk.isEmpty {
                    guard !buffer.isEmpty else { return nil }
                    defer { buffer.removeAll() }
                    return buffer
                }
                buffer.append(chunk)
            }
        }
    }
#endif
