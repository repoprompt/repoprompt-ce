import Foundation

/// Prompt-only Grok Build adapter for chat, Oracle, and other non-Agent-Mode requests.
/// Agent Mode continues to use `grok agent stdio`; this adapter uses the documented
/// one-shot JSON CLI and preserves the existing trusted Grok executable preflight.
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
        let selection = try Self.resolveModelSelection(
            modelString: config.modelString,
            snapshot: AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)
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

        let promptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-grok-oneshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: promptDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: promptDirectory) }

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
            environment: launch.environment,
            additionalPaths: [],
            enableDebugLogging: config.enableDebugLogging,
            resolveCandidates: [(launch.command as NSString).lastPathComponent],
            shellLookupMode: .disabled
        )
        let runner = CLIProcessRunner(config: processConfig)

        var additionalEnvironment: [String: String] = [:]
        var apiKey = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if apiKey?.isEmpty != false {
            apiKey = try await apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let apiKey, !apiKey.isEmpty {
            additionalEnvironment["XAI_API_KEY"] = apiKey
        }
        try Task.checkCancellation()

        let arguments = GrokBuildOneShotCLIOptions(
            promptFilePath: promptURL.path,
            model: selection.model,
            effort: selection.effort
        ).toTokens()

        let result: CLIProcessRunner.Result
        do {
            // Revalidate at the final launch boundary after all async/keychain work.
            try launch.executableIdentity.validateForTrustedPathLaunch(atPath: launch.command)
            result = try await runner.run(
                args: arguments,
                stdin: nil,
                outputMode: .none,
                timeout: requestTimeout,
                additionalEnvironment: additionalEnvironment,
                cancelChildOnTaskCancellation: true
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
