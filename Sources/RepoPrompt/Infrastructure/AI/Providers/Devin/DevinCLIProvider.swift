import Foundation

final class DevinCLIProvider: AIProvider {
    private let config: DevinAgentConfig
    private let launchResolver: DevinACPLaunchResolver
    private let requestTimeout: TimeInterval
    private let activeRuns = ActiveDevinOneShotRunStore()

    init(
        config: DevinAgentConfig = DevinAgentConfig(
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            includeRepoPromptMCPServer: false
        ),
        launchResolver: DevinACPLaunchResolver = DevinACPLaunchResolver(),
        requestTimeout: TimeInterval = 6000
    ) {
        self.config = config
        self.launchResolver = launchResolver
        self.requestTimeout = requestTimeout
    }

    #if DEBUG
        static func test_arguments(modelName: String?, promptFilePath: String) -> [String] {
            DevinOneShotCLIOptions(modelName: modelName, promptFilePath: promptFilePath).toTokens()
        }

        static func test_promptText(from message: AIMessage) -> String {
            promptText(from: message)
        }
    #endif

    func streamMessage(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens _: Int? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let runID = UUID()
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                defer { activeRuns.remove(runID) }
                do {
                    let text = try await runOneShot(aiMessage, modelName: devinModelName(for: model))
                    continuation.yield(AIStreamResult(type: "content", text: text))
                    continuation.yield(AIStreamResult(type: "message_stop", text: nil))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            activeRuns.insert(task, for: runID)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func completeMessage(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens: Int? = nil
    ) async throws -> AICompletionResult {
        let stream = try await streamMessage(aiMessage, model: model, maxTokens: maxTokens)
        var text = ""
        for try await result in stream where result.type == "content" {
            text += result.text ?? ""
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidResponse(detail: "Devin returned no completion")
        }
        return AICompletionResult(text: text)
    }

    func dispose() async {
        let tasks = activeRuns.removeAll()
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
    }

    private func runOneShot(_ message: AIMessage, modelName: String?) async throws -> String {
        try Task.checkCancellation()
        let support = try await launchResolver.probeSupport(for: config)
        guard case .supported = support else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "Devin CLI is not available."
            )
        }
        let launch: DevinACPResolvedLaunch
        do {
            launch = try launchResolver.resolvedLaunch(for: config)
        } catch {
            throw mapProcessError(error)
        }

        let prompt = Self.promptText(from: message)
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidResponse(detail: "Devin prompt is empty")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-devin-oneshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let integration = try DevinIntegrationConfiguration.prepare(
            workingDirectory: directory.path,
            mcpServers: .disableAll,
            sourceEnvironment: launch.environment
        )
        defer { DevinIntegrationConfiguration.cleanupReportingFailures(artifact: integration.cleanupArtifact) }

        let promptURL = directory.appendingPathComponent("prompt.md")
        try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptURL.path)

        let processConfig = CLIProcessConfiguration(
            command: launch.command,
            workingDirectory: directory.path,
            environment: launch.environment.merging(integration.environment) { _, overlay in overlay },
            additionalPaths: [],
            enableDebugLogging: config.enableDebugLogging,
            resolveCandidates: [(launch.command as NSString).lastPathComponent],
            shellLookupMode: .disabled
        )
        let runner = CLIProcessRunner(config: processConfig)
        let result: CLIProcessRunner.Result
        do {
            try launch.executableIdentity.validateForTrustedPathLaunch(atPath: launch.command)
            result = try await runner.run(
                args: DevinOneShotCLIOptions(
                    modelName: modelName,
                    promptFilePath: promptURL.path
                ).toTokens(),
                stdin: nil,
                outputMode: .none,
                timeout: requestTimeout,
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
                message: "Devin timed out after \(Int(requestTimeout))s."
            )
        }
        guard result.status == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = !stderr.isEmpty ? stderr : !stdout.isEmpty ? stdout : "Devin failed (exit \(result.status))."
            throw runtimeError(code: Int(result.status), message: message)
        }

        let text = String(decoding: result.stdout, as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidResponse(detail: "Devin returned no completion")
        }
        return text
    }

    private static let noToolsInstruction = "Do not use any tools, function calls, MCP servers, external commands, or workspace files. Return one final text answer only; preserve Markdown when useful."

    private static func promptText(from message: AIMessage) -> String {
        let systemPrompt = message.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = message.buildTail(embedSystemPrompt: false)
        var conversation = ""
        let lastUserIndex = message.conversationMessages.lastIndex { $0.role == .user }
        for (index, turn) in message.conversationMessages.enumerated() {
            var text = turn.content
            if turn.role == .user, index == lastUserIndex, !tail.isEmpty {
                text = tail + "\n\n" + text
            }
            if !conversation.isEmpty { conversation += "\n\n" }
            conversation += "\(turn.role == .user ? "User" : "Assistant"): \(text)"
        }
        if message.conversationMessages.isEmpty, !tail.isEmpty {
            conversation = "User: \(tail)"
        }
        return [systemPrompt, noToolsInstruction, conversation]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func devinModelName(for model: AIModel) -> String? {
        guard model.providerType == .devin else { return nil }
        let value = model.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else { return nil }
        return value
    }

    private func mapProcessError(_ error: Error) -> Error {
        if error is AIProviderError { return error }
        if let runnerError = error as? CLIProcessRunnerError,
           case .commandNotFound = runnerError
        {
            return AIProviderError.invalidConfiguration(
                detail: "Devin CLI was not found. Install Devin and ensure `devin` is on PATH."
            )
        }
        if error is DevinACPLaunchResolutionError || error is ExecutableFileIdentityError {
            return AIProviderError.invalidConfiguration(detail: error.localizedDescription)
        }
        return AIProviderError.apiError(source: error)
    }

    private func runtimeError(code: Int, message: String) -> Error {
        AIProviderError.apiError(
            source: NSError(
                domain: "DevinCLI",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        )
    }
}

private struct DevinOneShotCLIOptions {
    let modelName: String?
    let promptFilePath: String

    func toTokens() -> [String] {
        var tokens: [String] = []
        if let modelName = modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !modelName.isEmpty,
           modelName.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        {
            tokens += ["--model", modelName]
        }
        tokens += [
            "--respect-workspace-trust", "false",
            "--permission-mode", "auto",
            "--prompt-file", promptFilePath,
            "-p"
        ]
        return tokens
    }
}

private final class ActiveDevinOneShotRunStore: @unchecked Sendable {
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
