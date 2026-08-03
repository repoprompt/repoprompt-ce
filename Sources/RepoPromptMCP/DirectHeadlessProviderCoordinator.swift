import Foundation
import MCP
import RepoPromptDomainRuntime

actor DirectHeadlessProviderCoordinator {
    struct ProviderDescriptor {
        let id: String
        let displayName: String
        let executable: String?
        let unavailableReason: String?

        var value: Value {
            .object([
                "id": .string(id),
                "name": .string(displayName),
                "available": .bool(executable != nil),
                "reason": unavailableReason.map(Value.string) ?? .null
            ])
        }
    }

    private struct AgentRecord {
        let registration: DomainAgentSessionRegistration
        let epoch: DomainAgentRunTurnEpoch
        let runID: UUID
        let agentID: String
        let model: String?
        var name: String?
        var latestText: String?
        var task: Task<Void, Never>?
    }

    private struct Conversation {
        let id: UUID
        let providerID: String
        var messages: [(role: String, text: String)]
        var updatedAt: Date
    }

    private let runtime: MCPDomainRuntime
    private let context: DirectHeadlessDomainContext
    private let environment: [String: String]
    private var agents: [UUID: AgentRecord] = [:]
    private var conversations: [UUID: Conversation] = [:]
    private var isShuttingDown = false

    init(
        runtime: MCPDomainRuntime,
        context: DirectHeadlessDomainContext,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runtime = runtime
        self.context = context
        self.environment = environment
    }

    func providerCatalog() -> [ProviderDescriptor] {
        let codex = Self.findExecutable(
            named: environment["REPOPROMPT_CODEX_COMMAND"] ?? "codex",
            path: environment["PATH"]
        )
        return [
            ProviderDescriptor(
                id: "codexExec",
                displayName: "Codex CLI",
                executable: codex,
                unavailableReason: codex == nil ? "Codex CLI was not found on PATH." : nil
            )
        ]
    }

    func runProviderOnce(
        message: String,
        providerID: String?,
        model: String?,
        request: DomainPhysicalToolRequest,
        carrierEnvironment: [String: String]? = nil
    ) async throws -> String {
        guard !isShuttingDown else { throw CancellationError() }
        let descriptor = try resolveProvider(providerID)
        guard let executable = descriptor.executable else {
            throw MCPError.invalidRequest("Provider '\(descriptor.id)' is unavailable: \(descriptor.unavailableReason ?? "not configured")")
        }
        let snapshot = try await context.snapshot(for: request)
        var arguments: [String] = []
        if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model != "default" {
            arguments += ["--model", model]
        }
        arguments += ["exec", "--json", "--skip-git-repo-check", "--full-auto", "-"]
        let carrier = carrierEnvironment ?? DomainChildLaunchContext.current?.environment ?? [:]
        var childEnvironment = DirectProcess.withoutPrivateCarrier(from: environment)
        childEnvironment.merge(carrier) { _, supplied in supplied }
        let output = try await DirectProcess.run(
            executable,
            arguments: arguments,
            input: Data(message.utf8),
            environment: childEnvironment,
            currentDirectory: snapshot.roots.first
        )
        return Self.finalAssistantText(from: output)
    }

    func startAgent(args: [String: Value], request: DomainPhysicalToolRequest) async throws -> Value {
        guard !isShuttingDown else { throw CancellationError() }
        guard let message = args["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            throw MCPError.invalidParams("agent_run start requires message")
        }
        let providerID = args["model_id"]?.stringValue ?? args["agent"]?.stringValue ?? "codexExec"
        let descriptor = try resolveProvider(providerID)
        guard descriptor.executable != nil else {
            throw MCPError.invalidRequest("Provider '\(descriptor.id)' is unavailable: \(descriptor.unavailableReason ?? "not configured")")
        }
        let sessionID = DomainChildLaunchContext.current?.runID ?? UUID()
        let runID = sessionID
        let registration = await runtime.agentSessionStore.register(sessionID: sessionID)
        let activationID = UUID()
        let epoch: DomainAgentRunTurnEpoch
        switch await runtime.agentSessionStore.beginEpoch(
            registration: registration,
            activationID: activationID,
            expectedCurrentEpoch: nil,
            transitionKind: .initial
        ) {
        case let .accepted(value): epoch = value
        case let .rejected(reason): throw MCPError.internalError(reason)
        case .stale: throw MCPError.internalError("agent epoch changed during start")
        }
        let name = args["session_name"]?.stringValue
        let record = AgentRecord(
            registration: registration,
            epoch: epoch,
            runID: runID,
            agentID: descriptor.id,
            model: args["model"]?.stringValue,
            name: name,
            latestText: nil,
            task: nil
        )
        agents[sessionID] = record
        let running = snapshot(
            record: record,
            status: .running,
            statusText: "Running",
            assistantText: nil,
            failure: nil
        )
        await runtime.agentSessionStore.noteSnapshot(
            running,
            cursor: DomainAgentSessionWaitCursor(registration: registration, epoch: epoch)
        )
        let capturedRequest = request
        let capturedCarrierEnvironment = DomainChildLaunchContext.current?.environment ?? [:]
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await runProviderOnce(
                    message: message,
                    providerID: descriptor.id,
                    model: args["model"]?.stringValue,
                    request: capturedRequest,
                    carrierEnvironment: capturedCarrierEnvironment
                )
                await finishAgent(sessionID: sessionID, status: .completed, text: text, reason: nil)
            } catch is CancellationError {
                await finishAgent(sessionID: sessionID, status: .cancelled, text: nil, reason: .cancelled)
            } catch {
                await finishAgent(
                    sessionID: sessionID,
                    status: .failed,
                    text: error.localizedDescription,
                    reason: .agentError
                )
            }
        }
        agents[sessionID]?.task = task
        await runtime.agentSessionStore.installCancellationHandler(registration: registration) { [weak self] in
            await self?.cancelAgent(sessionID: sessionID)
        }

        if args["detach"]?.boolValue == true {
            return running.toValue()
        }
        let timeout = args["timeout"]?.doubleValue ?? 120
        return await waitAgent(sessionID: sessionID, timeout: timeout).toValue()
    }

    func pollAgent(sessionID: UUID, timeout: TimeInterval) async -> DomainAgentRunSnapshot {
        guard let record = agents[sessionID] else {
            return await restoredOrExpired(sessionID)
        }
        if timeout <= 0 {
            return await runtime.agentSessionStore.snapshot(for: record.registration)
                ?? DomainAgentRunSnapshot.expired(sessionID: sessionID)
        }
        return await waitAgent(sessionID: sessionID, timeout: timeout)
    }

    func waitAgent(sessionID: UUID, timeout: TimeInterval) async -> DomainAgentRunSnapshot {
        guard let record = agents[sessionID] else { return await restoredOrExpired(sessionID) }
        let disposition = await runtime.agentSessionStore.waitUntilInteresting(
            registration: record.registration,
            timeoutSeconds: max(0, timeout)
        )
        switch disposition {
        case let .snapshotReady(snapshot):
            return snapshot
        case let .noteworthySnapshot(wake):
            return wake.snapshot
        case .timedOut:
            return await runtime.agentSessionStore.snapshot(for: record.registration)
                ?? DomainAgentRunSnapshot.expired(sessionID: sessionID, statusText: "wait timed out")
        case .cancelled:
            return DomainAgentRunSnapshot.expired(sessionID: sessionID, statusText: "wait cancelled")
        case .expired:
            return DomainAgentRunSnapshot.expired(sessionID: sessionID)
        case let .epochAdvanced(epoch, _):
            return await runtime.agentSessionStore.snapshot(
                for: DomainAgentSessionWaitCursor(registration: record.registration, epoch: epoch)
            ) ?? DomainAgentRunSnapshot.expired(sessionID: sessionID)
        case let .terminalPublicationRejected(_, reason):
            return DomainAgentRunSnapshot.expired(sessionID: sessionID, statusText: reason)
        }
    }

    func cancelAgent(sessionID: UUID) async {
        agents[sessionID]?.task?.cancel()
    }

    func listAgents() async -> [Value] {
        var values = agents.values.map { record -> Value in
            let current = awaitSnapshot(record)
            return current.toValue()
        }
        let activeIDs = Set(agents.keys)
        for metadata in await runtime.agentSessionStore.restoredMetadata() where !activeIDs.contains(metadata.sessionID) {
            values.append(.object([
                "session_id": .string(metadata.sessionID.uuidString),
                "status": .string(metadata.state.rawValue),
                "updated_at": .string(ISO8601DateFormatter().string(from: metadata.updatedAt)),
                "resumable": .bool(metadata.resumable)
            ]))
        }
        return values
    }

    func updateStatus(sessionID: UUID, name: String?) async throws -> Value {
        guard var record = agents[sessionID] else { throw MCPError.invalidParams("unknown session_id") }
        record.name = name
        agents[sessionID] = record
        let current = awaitSnapshot(record)
        await runtime.agentSessionStore.noteSnapshot(
            current,
            cursor: DomainAgentSessionWaitCursor(registration: record.registration, epoch: record.epoch)
        )
        return current.toValue()
    }

    func shareThoughts(sessionID: UUID, text: String) async throws -> Value {
        guard var record = agents[sessionID] else { throw MCPError.invalidParams("unknown session_id") }
        record.latestText = text
        agents[sessionID] = record
        let current = snapshot(record: record, status: .waitingForInput, statusText: "Thoughts shared", assistantText: text, failure: nil)
        await runtime.agentSessionStore.noteSnapshotAndWakeWaiters(
            current,
            cursor: DomainAgentSessionWaitCursor(registration: record.registration, epoch: record.epoch),
            reason: .instructionDelivered
        )
        return current.toValue()
    }

    func createConversation(providerID: String?, message: String, model: String?, request: DomainPhysicalToolRequest) async throws -> (UUID, String) {
        let descriptor = try resolveProvider(providerID)
        let text = try await runProviderOnce(message: message, providerID: descriptor.id, model: model, request: request)
        let id = UUID()
        conversations[id] = Conversation(
            id: id,
            providerID: descriptor.id,
            messages: [("user", message), ("assistant", text)],
            updatedAt: Date()
        )
        return (id, text)
    }

    func continueConversation(id: UUID, message: String, model: String?, request: DomainPhysicalToolRequest) async throws -> String {
        guard var conversation = conversations[id] else { throw MCPError.invalidParams("unknown chat_id") }
        let history = conversation.messages.map { "\($0.role): \($0.text)" }.joined(separator: "\n\n")
        let prompt = history + "\n\nuser: " + message
        let text = try await runProviderOnce(
            message: prompt,
            providerID: conversation.providerID,
            model: model,
            request: request
        )
        conversation.messages.append(("user", message))
        conversation.messages.append(("assistant", text))
        conversation.updatedAt = Date()
        conversations[id] = conversation
        return text
    }

    func conversationLog(id: UUID?, limit: Int) throws -> Value {
        let conversation: Conversation
        if let id {
            guard let found = conversations[id] else { throw MCPError.invalidParams("unknown chat_id") }
            conversation = found
        } else {
            guard let latest = conversations.values.max(by: { $0.updatedAt < $1.updatedAt }) else {
                return .object(["messages": .array([])])
            }
            conversation = latest
        }
        let messages = conversation.messages.suffix(max(1, min(limit, 50))).map {
            Value.object(["role": .string($0.role), "text": .string($0.text)])
        }
        return .object([
            "chat_id": .string(conversation.id.uuidString),
            "messages": .array(Array(messages))
        ])
    }

    func shutdown() async {
        isShuttingDown = true
        let tasks = agents.values.compactMap(\.task)
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
    }

    private func finishAgent(
        sessionID: UUID,
        status: DomainAgentRunSnapshot.Status,
        text: String?,
        reason: DomainAgentRunSnapshot.FailureReason?
    ) async {
        guard var record = agents[sessionID] else { return }
        record.latestText = text
        record.task = nil
        agents[sessionID] = record
        let terminal = snapshot(record: record, status: status, statusText: text, assistantText: text, failure: reason)
        _ = await runtime.agentSessionStore.publishTerminal(
            DomainAgentRunTerminalPublicationEnvelope(epoch: record.epoch, snapshot: terminal),
            registration: record.registration,
            commitID: UUID(),
            successorKind: nil
        )
    }

    private func awaitSnapshot(_ record: AgentRecord) -> DomainAgentRunSnapshot {
        snapshot(
            record: record,
            status: record.task == nil ? .completed : .running,
            statusText: record.task == nil ? "Completed" : "Running",
            assistantText: record.latestText,
            failure: nil
        )
    }

    private func snapshot(
        record: AgentRecord,
        status: DomainAgentRunSnapshot.Status,
        statusText: String?,
        assistantText: String?,
        failure: DomainAgentRunSnapshot.FailureReason?
    ) -> DomainAgentRunSnapshot {
        DomainAgentRunSnapshot(
            sessionID: record.registration.sessionID,
            runID: record.runID,
            tabID: nil,
            sessionName: record.name,
            agentRaw: record.agentID,
            agentDisplayName: record.agentID == "codexExec" ? "Codex CLI" : record.agentID,
            modelRaw: record.model,
            reasoningEffortRaw: nil,
            status: status,
            statusText: statusText,
            latestAssistantPreview: assistantText,
            interaction: nil,
            transcriptItemCount: assistantText == nil ? 0 : 1,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: failure,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
    }

    private func restoredOrExpired(_ sessionID: UUID) async -> DomainAgentRunSnapshot {
        if let metadata = await runtime.agentSessionStore.restoredMetadata().first(where: { $0.sessionID == sessionID }) {
            return DomainAgentRunSnapshot.expired(
                sessionID: sessionID,
                statusText: "Session is \(metadata.state.rawValue) and has no live provider process in this runtime."
            )
        }
        return DomainAgentRunSnapshot.expired(sessionID: sessionID)
    }

    private func resolveProvider(_ requested: String?) throws -> ProviderDescriptor {
        let normalized = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = normalized.flatMap { $0.isEmpty ? nil : $0 } ?? "codexExec"
        let roleAliases: Set = ["pair", "explore", "engineer", "design", "default"]
        guard let descriptor = providerCatalog().first(where: {
            $0.id.caseInsensitiveCompare(id) == .orderedSame || (roleAliases.contains(id.lowercased()) && $0.id == "codexExec")
        }) else {
            throw MCPError.invalidParams("unknown standalone provider '\(id)'")
        }
        return descriptor
    }

    private nonisolated static func findExecutable(named command: String, path: String?) -> String? {
        if command.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: command) { return command }
        let paths = path?.split(separator: ":").map(String.init) ?? []
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent(command).path }
            .first(where: FileManager.default.isExecutableFile)
    }

    private nonisolated static func finalAssistantText(from output: String) -> String {
        var latest: String?
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let item = object["item"] as? [String: Any],
               item["type"] as? String == "agent_message",
               let text = item["text"] as? String
            {
                latest = text
            }
            if object["type"] as? String == "message", let text = object["text"] as? String {
                latest = text
            }
        }
        return latest ?? output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
