import Darwin
import Foundation
import RepoPromptProcess

/// Text-only Grok Build adapter for chat, Oracle, and other non-Agent-Mode requests.
/// Agent Mode continues to use `grok agent stdio`; this adapter uses the documented
/// one-shot prompt-file CLI and rejects images before launch.
final class GrokBuildOneShotHeadlessAgentProvider: HeadlessAgentProvider {
    typealias APIKeyProvider = @Sendable () async throws -> String?

    private let config: GrokBuildAgentConfig
    private let launchResolver: GrokBuildACPLaunchResolver
    private let requestTimeout: TimeInterval
    private let apiKeyProvider: APIKeyProvider
    private let activeRuns = ActiveGrokBuildOneShotRunStore()

    init(
        config: GrokBuildAgentConfig,
        launchResolver: GrokBuildACPLaunchResolver = GrokBuildACPLaunchResolver(),
        requestTimeout: TimeInterval = 6000,
        apiKeyProvider: @escaping APIKeyProvider = {
            try await KeyManager().getAPIKey(for: .grok)
        }
    ) {
        self.config = config
        self.launchResolver = launchResolver
        self.requestTimeout = requestTimeout
        self.apiKeyProvider = apiKeyProvider
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        guard message.resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            throw AIProviderError.invalidConfiguration(
                detail: "Grok Build one-shot requests cannot resume a previous session."
            )
        }
        guard message.transientImages.isEmpty else {
            throw AIProviderError.invalidConfiguration(
                detail: "Grok Build one-shot requests do not accept image attachments. Choose an image-capable Oracle model or remove the images and retry."
            )
        }

        let trackedRunID = runID ?? UUID()
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                defer { activeRuns.remove(trackedRunID) }
                do {
                    let completion = try await runOneShot(message)
                    for result in Self.streamResults(from: completion) {
                        continuation.yield(result)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            activeRuns.insert(task, for: trackedRunID)
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func dispose() async {
        let tasks = activeRuns.removeAll()
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
    }

    private func runOneShot(_ message: AgentMessage) async throws -> GrokBuildOneShotCompletion {
        let selection = try await Self.resolveModelSelection(
            modelString: config.modelString,
            snapshot: AgentACPModelRegistry.shared.resolvedSnapshotAfterWarmingStandardStore(for: .grokBuild)
        )
        try Task.checkCancellation()

        let support = try await launchResolver.probeSupport(for: config)
        guard case .supported = support else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "Grok Build CLI is not available."
            )
        }

        let launch: GrokBuildACPResolvedLaunch
        do {
            launch = try launchResolver.resolvedLaunch(for: config)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw mapProcessError(error)
        }
        try Task.checkCancellation()

        // Freeze the same effective environment the runner uses, including inherited Grok home.
        let environment = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(purpose: .cliRunner, overrides: launch.environment)
        ).environment
        try Task.checkCancellation()

        let promptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-grok-oneshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: promptDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return try await Self.withRequestCleanup(
            promptDirectory: promptDirectory,
            environment: environment
        ) {
            let promptURL = promptDirectory.appendingPathComponent("prompt.txt")
            let prompt = Self.promptText(from: message)
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIProviderError.invalidResponse(detail: "Grok Build prompt is empty")
            }
            try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptURL.path)

            let processConfig = CLIProcessConfiguration(
                command: launch.command,
                workingDirectory: promptDirectory.path,
                environment: environment,
                additionalPaths: [],
                enableDebugLogging: config.enableDebugLogging,
                resolveCandidates: [(launch.command as NSString).lastPathComponent],
                shellLookupMode: .disabled
            )
            let runner = CLIProcessRunner(config: processConfig)

            var apiKey = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            if apiKey?.isEmpty != false {
                apiKey = try await apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let additionalEnvironment = Self.launchEnvironment(apiKey: apiKey)
            try Task.checkCancellation()

            let arguments = GrokBuildOneShotCLIOptions(
                promptFilePath: promptURL.path,
                model: selection.model,
                effort: selection.effort
            ).toTokens()

            let result: (stdout: Data, stderr: Data, status: Int32, timedOut: Bool)
            do {
                // Revalidate at the final launch boundary after all async/keychain work.
                try launch.executableIdentity.validateForTrustedPathLaunch(atPath: launch.command)
                result = try await Self.runRequestProcess(
                    runner: runner,
                    arguments: arguments,
                    timeout: requestTimeout,
                    additionalEnvironment: additionalEnvironment,
                    additionalRemovedKeys: environment["GROK_HOME"] == nil ? ["GROK_HOME"] : []
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw mapProcessError(error)
            }

            if result.timedOut {
                throw runtimeError(
                    code: Int(result.status),
                    message: "Grok Build timed out after \(Int(requestTimeout))s."
                )
            }

            if result.status != 0 {
                throw mapProcessFailure(
                    exitCode: result.status,
                    stdout: result.stdout,
                    stderr: result.stderr
                )
            }

            if let errorMessage = Self.structuredErrorMessage(from: result.stdout) {
                throw normalizeCLIError(message: errorMessage, exitCode: result.status)
            }
            guard !result.stdout.isEmpty else {
                throw AIProviderError.invalidResponse(detail: "Grok Build CLI returned no output")
            }
            do {
                return try Self.parseCompletion(result.stdout)
            } catch let error as AIProviderError {
                throw error
            } catch {
                throw AIProviderError.invalidResponse(
                    detail: "Failed to decode Grok Build CLI JSON: \(error.localizedDescription)"
                )
            }
        }
    }

    /// The streaming runner's physical finalizer, not its bounded result or cancellation,
    /// is the authority for when the request's child has stopped writing.
    private static func runRequestProcess(
        runner: CLIProcessRunner,
        arguments: [String],
        timeout: TimeInterval,
        additionalEnvironment: [String: String],
        additionalRemovedKeys: Set<String>
    ) async throws -> (stdout: Data, stderr: Data, status: Int32, timedOut: Bool) {
        let termination = GrokBuildOneShotProcessTermination()
        let stream = try await runner.runStreaming(
            args: arguments,
            stdin: nil,
            outputMode: .none,
            timeout: timeout,
            additionalEnvironment: additionalEnvironment,
            additionalRemovedKeys: additionalRemovedKeys,
            onProcessTerminated: { _ in await termination.finish() }
        )
        var stdout = Data()
        var stderr = Data()
        var exitStatus: (status: Int32, timedOut: Bool)?
        do {
            for try await event in stream {
                switch event {
                case let .stdout(data): stdout.append(data)
                case let .stderr(data): stderr.append(data)
                case let .terminated(status, timedOut): exitStatus = (status, timedOut)
                }
            }
        } catch {
            await termination.wait()
            try Task.checkCancellation()
            throw error
        }
        // AsyncThrowingStream can end normally on consumer cancellation. Always join
        // physical finalization before the outer request scope removes any artifacts.
        await termination.wait()
        try Task.checkCancellation()
        guard let exitStatus else {
            throw AIProviderError.invalidResponse(detail: "Grok Build process ended without an exit status")
        }
        return (stdout: stdout, stderr: stderr, status: exitStatus.status, timedOut: exitStatus.timedOut)
    }

    /// Failed deletion is diagnostic and must not replace a successful completion,
    /// original request failure, or cancellation.
    static func withRequestCleanup<Value>(
        promptDirectory: URL,
        environment: [String: String],
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        reportFailure: (String) -> Void = { NSLog("%@", $0) },
        operation: () async throws -> Value
    ) async throws -> Value {
        var sessionDirectory: URL?
        defer {
            do {
                try cleanupRequestArtifacts(
                    promptDirectory: promptDirectory,
                    sessionDirectory: sessionDirectory,
                    removeItem: removeItem
                )
            } catch {
                reportFailure(cleanupFailureDiagnostic(error))
            }
        }
        let physicalDirectory = try resolvedRequestDirectory(promptDirectory)
        let encoded = encodedCWD(physicalDirectory.path)
        // Grok hashes longer paths. Refuse before launch rather than infer ownership
        // from directory names or potentially unfinished .cwd metadata.
        guard encoded.utf8.count <= 255 else {
            throw AIProviderError.invalidConfiguration(
                detail: "Grok Build one-shot request directory is too long for safe session cleanup (URL-encoded physical path exceeds 255 bytes). Use a shorter temporary directory and retry."
            )
        }
        sessionDirectory = sessionsRoot(promptDirectory: physicalDirectory, environment: environment)
            .appendingPathComponent(encoded, isDirectory: true)
        return try await operation()
    }

    private static func cleanupRequestArtifacts(
        promptDirectory: URL,
        sessionDirectory: URL?,
        removeItem: (URL) throws -> Void
    ) throws {
        var failure: Error?
        if let sessionDirectory {
            do {
                try removeItemIfPresent(sessionDirectory, removeItem: removeItem)
            } catch {
                failure = error
            }
        }
        // Even a failed session delete must not retain the temporary prompt file too.
        do {
            try removeItemIfPresent(promptDirectory, removeItem: removeItem)
        } catch {
            if failure == nil { failure = error }
        }
        if let failure { throw failure }
    }

    private static func resolvedRequestDirectory(_ directory: URL) throws -> URL {
        // Foundation can shorten /private/var back to /var while resolving symlinks.
        // Grok uses the physical getcwd path, so preserve POSIX realpath's spelling.
        guard let path = realpath(directory.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private static func sessionsRoot(promptDirectory: URL, environment: [String: String]) -> URL {
        let override = environment["GROK_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let home = override ?? environment["HOME"] ?? NSHomeDirectory()
        // Preserve symlink/.. spelling: Grok lets the filesystem resolve the path,
        // and the home may not exist until the child creates it during the request.
        let absoluteHome = home.hasPrefix("/") ? home : promptDirectory.path + "/" + home
        return URL(
            fileURLWithPath: absoluteHome + (override == nil ? "/.grok/sessions" : "/sessions"),
            isDirectory: true
        )
    }

    private static func encodedCWD(_ cwd: String) -> String {
        cwd.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
    }

    private static func removeItemIfPresent(_ url: URL, removeItem: (URL) throws -> Void) throws {
        do {
            try removeItem(url)
        } catch {
            if !isMissingFile(error) { throw error }
        }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    private static func cleanupFailureDiagnostic(_ error: Error) -> String {
        // Do not include error descriptions, domains, paths, or userInfo: any of
        // those can contain prompt content. The numeric filesystem code is bounded.
        "[GrokBuildOneShot] Request artifact cleanup failed (filesystem code \((error as NSError).code)); artifacts may remain."
    }

    /// Process-local overrides, kept separate from Grok's inherited credential/config environment.
    static func launchEnvironment(apiKey: String?) -> [String: String] {
        var environment = GrokBuildAgentConfig.importIsolationEnvironment
        environment["GROK_CLAUDE_HOOKS_ENABLED"] = "0"
        environment["GROK_CURSOR_HOOKS_ENABLED"] = "0"
        environment["GROK_SESSION_SEARCH"] = "0"
        environment["GROK_STORAGE_MODE"] = "local"
        if let apiKey, !apiKey.isEmpty {
            environment["XAI_API_KEY"] = apiKey
        }
        return environment
    }

    private func mapProcessError(_ error: Error) -> Error {
        if error is AIProviderError {
            return error
        }
        if let runnerError = error as? CLIProcessRunnerError {
            switch runnerError {
            case let .commandNotFound(command):
                return AIProviderError.invalidConfiguration(
                    detail: "Grok Build CLI was not found (`\(command)`). Install Grok Build or configure its path."
                )
            default:
                return AIProviderError.apiError(source: error)
            }
        }
        if error is GrokBuildACPLaunchResolutionError || error is ExecutableFileIdentityError {
            return AIProviderError.invalidConfiguration(detail: error.localizedDescription)
        }
        return AIProviderError.apiError(source: error)
    }

    private func mapProcessFailure(exitCode: Int32, stdout: Data, stderr: Data) -> Error {
        if let message = Self.structuredErrorMessage(from: stdout) {
            return normalizeCLIError(message: message, exitCode: exitCode)
        }
        let stderrMessage = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stderrMessage.isEmpty {
            return normalizeCLIError(message: stderrMessage, exitCode: exitCode)
        }
        return runtimeError(
            code: Int(exitCode),
            message: "Grok Build failed (exit \(exitCode))."
        )
    }

    private func normalizeCLIError(message: String, exitCode: Int32) -> Error {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("not signed in")
            || lower.contains("not authenticated")
            || lower.contains("unauthorized")
            || lower.contains("authorizationrequired")
            || lower.contains("authentication required")
            || lower.contains("run `grok login`")
        {
            return AIProviderError.invalidConfiguration(detail: trimmed)
        }
        if lower.contains("couldn't set model")
            || lower.contains("unknown model")
        {
            return AIProviderError.invalidConfiguration(detail: trimmed)
        }
        return runtimeError(code: Int(exitCode), message: trimmed)
    }

    private func runtimeError(code: Int, message: String) -> Error {
        AIProviderError.apiError(
            source: NSError(
                domain: "GrokBuildCLI",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        )
    }

    private static func promptText(from message: AgentMessage) -> String {
        let systemPrompt = message.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let userMessage = message.userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if systemPrompt.isEmpty {
            return userMessage
        }
        if userMessage.isEmpty {
            return systemPrompt
        }
        return systemPrompt + "\n\n" + userMessage
    }

    private static func resolveModelSelection(
        modelString: String?,
        snapshot: ACPDiscoveredSessionModels?
    ) throws -> (model: String?, effort: String?) {
        guard let modelString = modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelString.isEmpty,
              modelString.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else {
            return (nil, nil)
        }
        guard let snapshot, snapshot.contains(rawModel: modelString) else {
            throw AIProviderError.invalidConfiguration(
                detail: "Grok Build model `\(modelString)` is not in the discovered model set. Refresh Grok Build models and retry."
            )
        }
        guard let decomposed = GrokBuildModelSpecifier.decompose(
            raw: modelString,
            options: snapshot.options
        ) else {
            throw AIProviderError.invalidConfiguration(
                detail: "Grok Build model `\(modelString)` could not be resolved from the discovered model set. Refresh Grok Build models and retry."
            )
        }
        return (decomposed.base.rawValue, decomposed.explicitEffort?.rawValue)
    }

    private static let successfulTerminalStopReasons: Set<String> = [
        "end_turn",
        "stop",
        "stop_sequence",
        "completed",
        "complete"
    ]

    private static func parseCompletion(_ data: Data) throws -> GrokBuildOneShotCompletion {
        let payload = try JSONDecoder().decode(GrokBuildOneShotJSON.self, from: data)
        guard let stopReason = payload.stopReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stopReason.isEmpty
        else {
            throw AIProviderError.invalidResponse(detail: "Grok Build CLI JSON omitted stopReason")
        }
        let text = payload.text ?? ""
        if successfulTerminalStopReasons.contains(stopReason.lowercased()),
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw AIProviderError.invalidResponse(detail: "Grok Build returned no completion")
        }
        return GrokBuildOneShotCompletion(
            text: text,
            thought: payload.thought,
            stopReason: stopReason,
            promptTokens: payload.usage?.inputTokens,
            completionTokens: payload.usage?.outputTokens,
            cost: payload.totalCostUsd,
            sessionID: payload.sessionID
        )
    }

    private static func structuredErrorMessage(from data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(GrokBuildOneShotErrorJSON.self, from: data),
              payload.type.caseInsensitiveCompare("error") == .orderedSame
        else {
            return nil
        }
        let message = payload.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    private static func streamResults(from completion: GrokBuildOneShotCompletion) -> [AIStreamResult] {
        var results: [AIStreamResult] = []
        if let thought = completion.thought,
           !thought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            results.append(AIStreamResult(type: "reasoning", text: nil, reasoning: thought))
        }
        if !completion.text.isEmpty {
            results.append(AIStreamResult(type: "content", text: completion.text))
        }
        results.append(
            AIStreamResult(
                type: "message_stop",
                text: nil,
                promptTokens: completion.promptTokens,
                completionTokens: completion.completionTokens,
                cost: completion.cost,
                providerSessionID: completion.sessionID,
                stopReason: completion.stopReason
            )
        )
        return results
    }
}

/// One request has one finalization waiter. Cancellation must not cancel this join.
private actor GrokBuildOneShotProcessTermination {
    private var terminated = false
    private var continuation: CheckedContinuation<Void, Never>?

    func finish() {
        terminated = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        guard !terminated else { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private struct GrokBuildOneShotCLIOptions {
    static let disallowedTools = ["read_file", "search_tool", "use_tool"]

    static let systemPromptOverride = """
    You are a text-only assistant.
    No tools are available.
    Do not claim to call, inspect, read, search, or modify external resources.
    Answer from the supplied prompt and context.
    Provide the final answer directly without progress narration.
    """

    static let deniedPermissionRules = [
        "Read",
        "Grep",
        "Edit",
        "Write",
        "Bash",
        "WebFetch",
        "MCPTool"
    ]

    var promptFilePath: String
    var model: String?
    var effort: String?

    func toTokens() -> [String] {
        var tokens = [
            "--prompt-file", promptFilePath,
            "--output-format", "json",
            "--verbatim",
            "--max-turns", "1",
            "--no-subagents",
            "--no-plan",
            "--no-memory",
            "--disable-web-search",
            "--tools", "read_file",
            "--disallowed-tools", Self.disallowedTools.joined(separator: ","),
            "--system-prompt-override", Self.systemPromptOverride
        ]
        for rule in Self.deniedPermissionRules {
            tokens += ["--deny", rule]
        }
        if let model {
            tokens += ["-m", model]
        }
        if let effort {
            tokens += ["--reasoning-effort", effort]
        }
        return tokens
    }
}

private struct GrokBuildOneShotJSON: Decodable {
    let text: String?
    let thought: String?
    let stopReason: String?
    let sessionID: String?
    let usage: Usage?
    let totalCostUsd: Double?

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case text
        case thought
        case stopReason
        case sessionID = "sessionId"
        case usage
        case totalCostUsd = "total_cost_usd"
    }
}

private struct GrokBuildOneShotErrorJSON: Decodable {
    let type: String
    let message: String
}

private struct GrokBuildOneShotCompletion {
    let text: String
    let thought: String?
    let stopReason: String
    let promptTokens: Int?
    let completionTokens: Int?
    let cost: Double?
    let sessionID: String?
}

private final class ActiveGrokBuildOneShotRunStore: @unchecked Sendable {
    private let lock = NSLock()
    private var acceptingRuns = true
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func insert(_ task: Task<Void, Never>, for runID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard acceptingRuns else {
            task.cancel()
            return
        }
        tasks[runID] = task
    }

    func remove(_ runID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard acceptingRuns else { return }
        tasks.removeValue(forKey: runID)
    }

    func removeAll() -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        acceptingRuns = false
        let current = Array(tasks.values)
        tasks.removeAll()
        return current
    }
}
