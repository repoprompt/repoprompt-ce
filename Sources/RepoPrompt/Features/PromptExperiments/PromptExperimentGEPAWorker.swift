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
        var failureCode: String?

        var jsonObject: [String: Any] {
            var value: [String: Any] = ["ok": ok]
            if let output { value["output"] = output }
            if let score { value["score"] = score }
            if let feedback { value["feedback"] = feedback }
            if let failureKind { value["failure_kind"] = failureKind.rawValue }
            if let error { value["error"] = error }
            if let failureCode { value["failure_code"] = failureCode }
            if let elapsedSeconds { value["elapsed_seconds"] = elapsedSeconds }
            if let promptTokens { value["prompt_tokens"] = promptTokens }
            if let completionTokens { value["completion_tokens"] = completionTokens }
            return value
        }
    }

    /// Runs the app-bundled, pinned Python GEPA environment. The child receives no provider
    /// credentials; all model and workflow work round-trips to app-owned callbacks.
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
        private let processLifecycleLock = NSLock()
        private let cancellationQueue = DispatchQueue(label: "com.repoprompt.prompt-experiment.worker-cancellation")
        private var process: Process?
        private var cancellationWriteHandle: FileHandle?
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

        static let pythonVersion = "3.11.16"
        private static let bundledSchemePrefix = "bundle://PromptExperimentPython/"

        static var bundledRuntimeAvailable: Bool {
            (try? resolvePythonExecutable(sealedValue: bundledPythonSealValue())) != nil
        }

        static var runtimeStatus: String {
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
            let expectedRevision = PromptExperimentGEPAConfiguration.pinnedRevision
            let expectedVersion = PromptExperimentGEPAConfiguration.packageVersion
            let executable = try resolvePythonExecutable(sealedValue: pythonExecutable)
            let script = """
            import importlib.metadata, json, sys
            assert sys.version_info[:3] == (3, 11, 16), f'Python version mismatch: {sys.version}'
            d=importlib.metadata.distribution('gepa')
            direct=d.read_text('direct_url.json')
            revision=(json.loads(direct).get('vcs_info',{}).get('commit_id') if direct else None)
            requires=d.requires or []
            assert importlib.metadata.version('gepa') == '\(expectedVersion)', 'GEPA version mismatch'
            assert revision == '\(expectedRevision)', 'GEPA git revision mismatch or unavailable'
            assert requires == [], f'Unexpected GEPA runtime dependencies: {requires}'
            import gepa
            import gepa.adapters.mcp_adapter
            assert importlib.metadata.version("mcp") == "1.30.0", "MCP SDK version mismatch"
            """
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
                process.arguments = ["-I", "-B", "-u", "-c", script]
                process.environment = workerEnvironment(home: home, temporaryDirectory: temporary)
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let message = String(data: data, encoding: .utf8) ?? "unknown preflight failure"
                    throw WorkerError.unavailable("Bundled GEPA preflight failed without making a model call: \(message)")
                }
            }.value
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
            plan: PromptExperimentPlan,
            attemptID: UUID,
            host: @escaping @MainActor @Sendable (_ callbackID: String, _ operation: String, _ payload: [String: Any]) async -> PromptExperimentGEPAHostReply,
            progress: @escaping @MainActor @Sendable (String) async -> Void,
            observation: @escaping @MainActor @Sendable (PromptExperimentRuntimeObservation) async -> Void
        ) async throws -> PromptExperimentOptimizationRuntimeResult {
            guard let specification = plan.optimization else {
                throw WorkerError.protocolFailure("The GEPA worker received a legacy comparison plan.")
            }
            let runRoot = PromptExperimentStore.liveRootURL()
                .appendingPathComponent("worker-runs", isDirectory: true)
                .appendingPathComponent(attemptID.uuidString.lowercased(), isDirectory: true)
            let runDirectory = runRoot.appendingPathComponent("gepa-run", isDirectory: true)
            let outputDirectory = runRoot.appendingPathComponent("gepa-output", isDirectory: true)
            let stderrURL = runRoot.appendingPathComponent("worker-stderr.log")
            let protocolURL = runRoot.appendingPathComponent("stdout-protocol.ndjson")
            let relativeRunRoot = "worker-runs/\(attemptID.uuidString.lowercased())"
            let workerHome = runRoot.appendingPathComponent("home", isDirectory: true)
            let workerTemporary = runRoot.appendingPathComponent("tmp", isDirectory: true)
            let workerURL: URL
            let pythonExecutable: URL
            let stderrLog: SafeDiagnosticLog
            let protocolLog: SafeDiagnosticLog
            do {
                try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: workerHome, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: workerTemporary, withIntermediateDirectories: true)
                workerURL = try Self.resolveWorkerURL()
                pythonExecutable = try Self.resolvePythonExecutable(
                    sealedValue: specification.gepa.pythonExecutablePath
                )
                stderrLog = try SafeDiagnosticLog(url: stderrURL)
                protocolLog = try SafeDiagnosticLog(url: protocolURL)
            } catch {
                await observation(.workerLaunchFailed(error.localizedDescription))
                throw error
            }
            defer {
                stderrLog.close()
                protocolLog.close()
            }
            await observation(.workerPrepared(
                stderrLogRelativePath: "\(relativeRunRoot)/worker-stderr.log",
                stdoutProtocolLogRelativePath: "\(relativeRunRoot)/stdout-protocol.ndjson"
            ))

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
            if let mcp = specification.execution.mcp {
                try mcp.verifyResolved()
                request["mcp_adapter"] = try [
                    "tool_names": mcp.toolNames, "component": mcp.component,
                    "tool_definitions_json": mcp.toolDefinitionsJson ?? "", "server_sha256": mcp.serverSha256 ?? "",
                    "server_path": PromptExperimentMCPConfiguration.serverURL().path,
                    "project_root": URL(fileURLWithPath: plan.environment.isolatedRootPath).appendingPathComponent("project").path,
                    "instructions": specification.execution.instructions
                ]
            }
            request["stage"] = specification.isPreparation ? "preparation" : "search"
            if specification.isPreparation { request["preparation_candidates"] = specification.preparationCandidates }
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
                                pythonExecutable: pythonExecutable,
                                workerURL: workerURL,
                                initial: initial,
                                stderrLog: stderrLog,
                                protocolLog: protocolLog,
                                workerHome: workerHome,
                                workerTemporary: workerTemporary,
                                host: host,
                                progress: progress,
                                observation: observation,
                                hostCallbackTimeoutSeconds: (specification.gepa.maxJudgeRetries ?? 0) > 0 ? 600 : 300
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
            initial: [String: Any],
            stderrLog: SafeDiagnosticLog,
            protocolLog: SafeDiagnosticLog,
            workerHome: URL,
            workerTemporary: URL,
            host: @escaping @MainActor @Sendable (_ callbackID: String, _ operation: String, _ payload: [String: Any]) async -> PromptExperimentGEPAHostReply,
            progress: @escaping @MainActor @Sendable (String) async -> Void,
            observation: @escaping @MainActor @Sendable (PromptExperimentRuntimeObservation) async -> Void,
            hostCallbackTimeoutSeconds: Int
        ) throws -> PromptExperimentOptimizationRuntimeResult {
            let child = Process()
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let cancellationPipe = Pipe()
            child.executableURL = pythonExecutable
            child.arguments = ["-I", "-B", "-u", workerURL.path]
            // Deliberately do not inherit the app environment: provider credentials and
            // authentication remain inside RepoPrompt. The worker receives only process
            // mechanics and communicates every model request over the host protocol.
            child.environment = Self.workerEnvironment(home: workerHome, temporaryDirectory: workerTemporary)
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
            try writeJSONLine(initial, to: stdinPipe.fileHandleForWriting)
            try protocolLog.append(channel: "stdin", event: "run_request_written", detail: "payload=excluded")
            emitObservation(
                .protocolEvent(channel: "stdin", event: "run_request_written", detail: "payload=excluded"),
                using: observation
            )
            var reader = PromptExperimentNDJSONLineReader(
                handle: stdoutPipe.fileHandleForReading,
                cancellationHandle: cancellationPipe.fileHandleForReading
            )
            var terminal: PromptExperimentOptimizationRuntimeResult?
            var terminalError: Error?
            while let data = try reader.nextLine() {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["protocol_version"] as? Int == 1,
                      let type = object["type"] as? String
                else {
                    try? protocolLog.append(channel: "stdout", event: "invalid_protocol", detail: nil)
                    throw WorkerError.protocolFailure("GEPA worker emitted invalid protocol JSON.")
                }
                let protocolDetail = Self.safeProtocolDetail(type: type, object: object)
                try protocolLog.append(
                    channel: "stdout",
                    event: type,
                    detail: protocolDetail
                )
                emitObservation(
                    .protocolEvent(
                        channel: "stdout",
                        event: type,
                        detail: protocolDetail
                    ),
                    using: observation
                )
                switch type {
                case "host_request":
                    guard let id = object["id"] as? String,
                          let operation = object["operation"] as? String,
                          let payload = object["payload"] as? [String: Any]
                    else { throw WorkerError.protocolFailure("GEPA host request is incomplete.") }
                    emitObservation(.callbackStarted(id: id, operation: operation), using: observation)
                    let semaphore = DispatchSemaphore(value: 0)
                    let replyBox = PromptExperimentGEPAHostReplyBox()
                    let callback = Task { @MainActor in
                        let reply = await host(id, operation, payload)
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
                    emitObservation(.callbackFinished(id: id, operation: operation), using: observation)
                    var response = reply.jsonObject
                    response["protocol_version"] = 1
                    response["type"] = "host_response"
                    response["id"] = id
                    try writeJSONLine(response, to: stdinPipe.fileHandleForWriting)
                case "mcp_process":
                    break // Payload-free PID/phase detail is already persisted above.
                case "progress":
                    let completed = object["completed_evaluations"] as? Int ?? 0
                    let maximum = object["max_evaluations"] as? Int ?? 0
                    let candidate = object["candidate_index"] as? Int ?? 0
                    Task { @MainActor in
                        await progress("Evaluated candidate \(candidate + 1) (\(completed)/\(maximum) budget calls).")
                    }
                case "completed":
                    guard let result = object["result"] as? [String: Any] else {
                        throw WorkerError.protocolFailure("GEPA completion omitted its result.")
                    }
                    terminal = try decodeResult(result)
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
                if terminal != nil || terminalError != nil { break }
            }
            stdinPipe.fileHandleForWriting.closeFile()
            child.waitUntilExit()
            stderrDrain.wait()
            lock.lock()
            let cancelled = didRequestCancellation
            lock.unlock()
            if cancelled { throw CancellationError() }
            if let terminalError { throw terminalError }
            guard child.terminationStatus == 0, let terminal else {
                throw WorkerError.infrastructureFailure(
                    "GEPA worker terminated without a result (status \(child.terminationStatus)); inspect the persisted attempt diagnostics and redacted worker logs."
                )
            }
            return terminal
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
            case "mcp_process":
                let pid = object["pid"] as? Int ?? -1
                let state = ["started", "closed"].contains(object["state"] as? String ?? "") ? (object["state"] as? String ?? "unknown") : "unknown"
                return "mcp_server_pid=\(pid) state=\(state) payload=excluded"
            case "host_request":
                let id = object["id"] as? String ?? "unknown"
                let operation = object["operation"] as? String ?? "unknown"
                return "callback_id=\(id) operation=\(operation) payload=excluded"
            case "progress":
                let completed = object["completed_evaluations"] as? Int ?? 0
                let maximum = object["max_evaluations"] as? Int ?? 0
                let candidate = object["candidate_index"] as? Int ?? 0
                return "candidate=\(candidate) completed_evaluations=\(completed) max_evaluations=\(maximum)"
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
                let safeCode = ["judge_invalid_response", "judge_provider_failed"].contains(code ?? "") ? code! : "unavailable"
                return "exception_type=\(exceptionType) source_frame=\(module).\(function):\(line) failure_code=\(safeCode) error_payload=excluded"
            default:
                return nil
            }
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

        private func decodeResult(_ result: [String: Any]) throws -> PromptExperimentOptimizationRuntimeResult {
            let raw = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            guard let engine = result["engine"] as? String, ["gepa", "preparation"].contains(engine),
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
                engine: engine,
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
