import Foundation
import RepoPromptACPProviders
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptDomainRuntime

/// Runs Oracle and built-in chat in disposable ACP sessions with no workspace or MCP access.
final class AntigravityChatProvider: AIProvider {
    private static let agentName = "repoprompt-chat"
    private let runsLock = NSLock()
    private var runs: [UUID: Task<Void, Never>] = [:]
    private var disposed = false

    func streamMessage(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens _: Int? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let message = Self.makeAgentMessage(from: aiMessage)
        let modelName = model.modelName
        let runID = UUID()
        return AsyncThrowingStream { continuation in
            let task = runsLock.withLock { () -> Task<Void, Never>? in
                guard !disposed else { return nil }
                let task = Task {
                    defer { self.removeRun(runID) }
                    do {
                        try await Self.run(message, modelName: modelName, continuation: continuation)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                runs[runID] = task
                return task
            }
            if let task {
                continuation.onTermination = { _ in task.cancel() }
            } else {
                continuation.finish(throwing: CancellationError())
            }
        }
    }

    func completeMessage(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens: Int? = nil
    ) async throws -> AICompletionResult {
        let stream = try await streamMessage(aiMessage, model: model, maxTokens: maxTokens)
        var text = ""
        var finalContent: String?
        var usage: AIStreamResult?
        for try await result in stream {
            switch result.type {
            case "content": text += result.text ?? ""
            case "final_content": finalContent = result.text ?? finalContent
            case "message_stop": usage = result
            case "error": throw AIProviderError.invalidResponse(detail: result.text ?? "Antigravity ACP reported an error.")
            default: continue
            }
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = finalContent ?? ""
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidResponse(detail: "Antigravity returned no completion.")
        }
        return AICompletionResult(text: text, promptTokens: usage?.promptTokens, completionTokens: usage?.completionTokens, cost: usage?.cost)
    }

    func dispose() async {
        let active = runsLock.withLock {
            disposed = true
            return Array(runs.values)
        }
        active.forEach { $0.cancel() }
        for task in active {
            await task.value
        }
    }

    private func removeRun(_ runID: UUID) {
        _ = runsLock.withLock { runs.removeValue(forKey: runID) }
    }

    private static func run(
        _ message: AgentMessage,
        modelName: String,
        continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptAntigravityChat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let profile = root.appendingPathComponent("profile", isDirectory: true)
        let agents = profile.appendingPathComponent("antigravity-cli/agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        // The isolated CLI can use Google's existing secure sign-in. The profile imports
        // no user settings, credentials, or tools from the active workspace.
        try """
        ---
        name: \(agentName)
        description: Answer questions using the provided conversation and context.
        tools: []
        subagent: false
        commandExecutionPolicy: off
        ---
        Answer using only the supplied conversation and context.
        """.write(to: agents.appendingPathComponent("\(agentName).md"), atomically: true, encoding: .utf8)

        let bridge = ACPHeadlessAgentProviderBridge(
            providerName: "Google Antigravity",
            makeProvider: {
                AntigravityACPAgentProvider(
                    includeRepoPromptMCPServer: false,
                    isolatedProfile: profile,
                    customAgentName: agentName
                )
            },
            makeRequest: { _, _ in
                ACPRunRequest(
                    agentKind: .antigravity,
                    modelString: modelName,
                    workspacePath: workspace.path,
                    resumeSessionID: nil,
                    attachments: [],
                    taskLabelKind: nil
                )
            },
            makeController: { provider, request, diagnosticSink in
                try ACPAgentSessionController(
                    provider: provider,
                    runRequest: request,
                    host: ACPAgentSessionAppHost(allowsModelCatalogPublication: false),
                    diagnosticSink: diagnosticSink
                )
            },
            beforePrompt: { controller, _ in try await controller.setSessionModel(modelName) },
            approvalPolicy: .declineUnsupported
        )
        do {
            let results = try await bridge.streamAgentMessage(message)
            for try await result in results {
                continuation.yield(result)
            }
            try Task.checkCancellation()
        } catch {
            await bridge.dispose()
            throw error
        }
        await bridge.dispose()
    }

    static func makeAgentMessage(from message: AIMessage) -> AgentMessage {
        let tail = message.buildTail(embedSystemPrompt: false)
        let lastUserIndex = message.conversationMessages.lastIndex { $0.role == .user }
        let turns = message.conversationMessages.enumerated().map { index, turn in
            let text = index == lastUserIndex && !tail.isEmpty ? tail + "\n\n" + turn.content : turn.content
            return "\(turn.role == .user ? "User" : "Assistant"): \(text)"
        }
        return AgentMessage(
            systemPrompt: message.systemPrompt,
            userMessage: turns.isEmpty ? tail : turns.joined(separator: "\n\n"),
            attachments: message.attachments
        )
    }
}
