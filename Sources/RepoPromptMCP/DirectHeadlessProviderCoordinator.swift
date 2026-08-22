import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptShared

actor DirectHeadlessProviderCoordinator {
    typealias BeginEpoch = @Sendable (
        _ registration: DomainAgentSessionRegistration,
        _ activationID: UUID
    ) async -> DomainAgentRunSessionStore.EpochBeginResult

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
        let parentSessionID: UUID?
        let worktreeBindings: [DomainAgentRunSnapshot.WorktreeBinding]
        var latestSnapshot: DomainAgentRunSnapshot?
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
    private let settingsStore: DomainDirectSettingsStore
    private let environment: [String: String]
    private let beginEpoch: BeginEpoch
    private var agents: [UUID: AgentRecord] = [:]
    private var conversations: [UUID: Conversation] = [:]
    private var isShuttingDown = false

    init(
        runtime: MCPDomainRuntime,
        context: DirectHeadlessDomainContext,
        settingsStore: DomainDirectSettingsStore,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        beginEpoch: BeginEpoch? = nil
    ) {
        self.runtime = runtime
        self.context = context
        self.settingsStore = settingsStore
        self.environment = environment
        let sessionStore = runtime.agentSessionStore
        self.beginEpoch = beginEpoch ?? { registration, activationID in
            await sessionStore.beginEpoch(
                registration: registration,
                activationID: activationID,
                expectedCurrentEpoch: nil,
                transitionKind: .initial
            )
        }
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

    static func codexExecArguments(model: String?) -> [String] {
        var arguments: [String] = []
        if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model != "default" {
            arguments += ["--model", model]
        }
        arguments += ["exec", "--skip-git-repo-check", "--sandbox", "workspace-write", "--json", "-"]
        return arguments
    }

    func runProviderOnce(
        message: String,
        providerID: String?,
        model: String?,
        request: DomainPhysicalToolRequest,
        sessionID: UUID? = nil,
        carrierEnvironment: [String: String]? = nil
    ) async throws -> String {
        guard !isShuttingDown else { throw CancellationError() }
        let descriptor = try resolveProvider(providerID)
        guard let executable = descriptor.executable else {
            throw MCPError.invalidRequest("Provider '\(descriptor.id)' is unavailable: \(descriptor.unavailableReason ?? "not configured")")
        }
        guard let connectionID = request.securityContext?.connectionID else {
            throw DirectHeadlessDomainContext.Error.routingUnavailable
        }
        let effectiveSessionID = sessionID ?? request.securityContext?.principal.runID
        let snapshot = try await context.snapshot(
            connectionID: connectionID,
            sessionID: effectiveSessionID
        )
        let arguments = Self.codexExecArguments(model: model)
        let carrier = carrierEnvironment ?? DomainChildLaunchContext.current?.environment ?? [:]
        var childEnvironment = DirectProcess.withoutPrivateCarrier(from: environment)
        childEnvironment.merge(carrier) { _, supplied in supplied }
        let output = try await DirectProcess.run(
            executable,
            arguments: arguments,
            input: Data(message.utf8),
            environment: childEnvironment,
            currentDirectory: snapshot.activeRoot
        )
        return Self.finalAssistantText(from: output)
    }

    func startAgent(args: [String: Value], request: DomainPhysicalToolRequest) async throws -> Value {
        guard !isShuttingDown else { throw CancellationError() }
        await settingsStore.bootstrap()
        let cleanupGuidance = try await settingsStore.effectiveValue(
            for: "agent_mode.show_built_in_workflow_cleanup_guidance"
        )
        guard case let .bool(includeSessionCleanupGuidance) = cleanupGuidance else {
            throw MCPError.internalError("Built-in workflow cleanup guidance setting is not boolean.")
        }
        let message = try Self.resolvedLaunchMessage(
            args: args,
            includeSessionCleanupGuidance: includeSessionCleanupGuidance
        )
        let providerID = args["model_id"]?.stringValue ?? args["agent"]?.stringValue ?? "codexExec"
        let descriptor = try resolveProvider(providerID)
        guard descriptor.executable != nil else {
            throw MCPError.invalidRequest("Provider '\(descriptor.id)' is unavailable: \(descriptor.unavailableReason ?? "not configured")")
        }
        let sessionID = DomainChildLaunchContext.current?.runID ?? UUID()
        let runID = sessionID
        guard let connectionID = request.securityContext?.connectionID else {
            throw DirectHeadlessDomainContext.Error.routingUnavailable
        }
        let requestedParentSessionID = request.securityContext?.principal.runID
        let parentSessionID = requestedParentSessionID.flatMap { agents[$0] == nil ? nil : $0 }
        let rootOverlayPreparation = try await context.prepareSessionRootOverlay(
            sessionID: sessionID,
            sourceSessionID: parentSessionID,
            arguments: args,
            connectionID: connectionID
        )
        let registration = await runtime.agentSessionStore.register(sessionID: sessionID)
        let activationID = UUID()
        let epoch: DomainAgentRunTurnEpoch
        switch await beginEpoch(registration, activationID) {
        case let .accepted(value): epoch = value
        case let .rejected(reason):
            await context.rollbackSessionRootOverlay(rootOverlayPreparation)
            await runtime.agentSessionStore.cleanup(registration: registration)
            throw MCPError.internalError(reason)
        case .stale:
            await context.rollbackSessionRootOverlay(rootOverlayPreparation)
            await runtime.agentSessionStore.cleanup(registration: registration)
            throw MCPError.internalError("agent epoch changed during start")
        }
        let name = args["session_name"]?.stringValue
        let record = AgentRecord(
            registration: registration,
            epoch: epoch,
            runID: runID,
            agentID: descriptor.id,
            model: args["model"]?.stringValue,
            name: name,
            parentSessionID: parentSessionID,
            worktreeBindings: rootOverlayPreparation.bindings,
            latestSnapshot: nil,
            task: nil
        )
        var runningRecord = record
        let running = snapshot(
            record: runningRecord,
            status: .running,
            statusText: "Running",
            assistantText: nil,
            failure: nil
        )
        runningRecord.latestSnapshot = running
        agents[sessionID] = runningRecord
        await runtime.agentSessionStore.noteSnapshot(
            running,
            cursor: DomainAgentSessionWaitCursor(registration: registration, epoch: epoch)
        )
        let capturedRequest = request
        let capturedCarrierEnvironment = DomainChildLaunchContext.current?.environment ?? [:]
        let task = Task { [weak self] in
            guard let self else { return }
            let report = await DomainAgentRunExecutionCore.execute {
                do {
                    let text = try await runProviderOnce(
                        message: message,
                        providerID: descriptor.id,
                        model: args["model"]?.stringValue,
                        request: capturedRequest,
                        sessionID: sessionID,
                        carrierEnvironment: capturedCarrierEnvironment
                    )
                    return .completed(assistantText: text)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    throw error
                }
            }
            guard case let .terminal(outcome) = report.result else { return }
            await finishAgent(sessionID: sessionID, outcome: outcome)
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
                ?? retainedSnapshot(record)
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
                ?? retainedSnapshot(record)
        case .cancelled:
            return DomainAgentRunSnapshot.expired(sessionID: sessionID, statusText: "wait cancelled")
        case .expired:
            return retainedSnapshot(record)
        case let .epochAdvanced(epoch, _):
            return await runtime.agentSessionStore.snapshot(
                for: DomainAgentSessionWaitCursor(registration: record.registration, epoch: epoch)
            ) ?? retainedSnapshot(record)
        case let .terminalPublicationRejected(_, reason):
            return DomainAgentRunSnapshot.expired(sessionID: sessionID, statusText: reason)
        }
    }

    func cancelAgent(sessionID: UUID) async {
        agents[sessionID]?.task?.cancel()
    }

    func listAgents() async -> [Value] {
        var values: [Value] = []
        for record in agents.values {
            let current = await runtime.agentSessionStore.snapshot(for: record.registration)
                ?? retainedSnapshot(record)
            values.append(current.toValue())
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
        let previous = await runtime.agentSessionStore.snapshot(for: record.registration)
            ?? retainedSnapshot(record)
        record.name = name
        let current = snapshot(
            record: record,
            status: previous.status,
            statusText: previous.statusText,
            assistantText: previous.latestAssistantPreview,
            failure: previous.failureReason
        )
        record.latestSnapshot = current
        agents[sessionID] = record
        await runtime.agentSessionStore.noteSnapshot(
            current,
            cursor: DomainAgentSessionWaitCursor(registration: record.registration, epoch: record.epoch)
        )
        return current.toValue()
    }

    func shareThoughts(sessionID: UUID, text: String) async throws -> Value {
        guard var record = agents[sessionID] else { throw MCPError.invalidParams("unknown session_id") }
        let current = snapshot(record: record, status: .waitingForInput, statusText: "Thoughts shared", assistantText: text, failure: nil)
        record.latestSnapshot = current
        agents[sessionID] = record
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

    /// Settles one agent run through the neutral terminal-outcome contract.
    /// The canonical exactly-once settlement stays owned by
    /// `DomainAgentRunSessionStore.publishTerminal`.
    private func finishAgent(
        sessionID: UUID,
        outcome: DomainAgentRunTerminalOutcome
    ) async {
        guard var record = agents[sessionID] else { return }
        record.task = nil
        let terminal = snapshot(
            record: record,
            status: outcome.snapshotStatus,
            statusText: outcome.assistantText,
            assistantText: outcome.assistantText,
            failure: outcome.failureReason
        )
        record.latestSnapshot = terminal
        agents[sessionID] = record
        _ = await runtime.agentSessionStore.publishTerminal(
            DomainAgentRunTerminalPublicationEnvelope(epoch: record.epoch, snapshot: terminal),
            registration: record.registration,
            commitID: UUID(),
            successorKind: nil
        )
    }

    private func retainedSnapshot(_ record: AgentRecord) -> DomainAgentRunSnapshot {
        record.latestSnapshot ?? snapshot(
            record: record,
            status: .running,
            statusText: "Running",
            assistantText: nil,
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
            parentSessionID: record.parentSessionID,
            failureReason: failure,
            worktreeBindings: record.worktreeBindings,
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

    nonisolated static func resolvedLaunchMessage(
        args: [String: Value],
        includeSessionCleanupGuidance: Bool = true
    ) throws -> String {
        guard let message = args["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            throw MCPError.invalidParams("agent_run start requires message")
        }
        do {
            let workflow = try RepoPromptBuiltInAgentWorkflow.resolve(
                workflowID: args["workflow_id"]?.stringValue,
                workflowName: args["workflow_name"]?.stringValue
            )
            return workflow?.wrapUserText(
                message,
                includeSessionCleanupGuidance: includeSessionCleanupGuidance
            ) ?? message
        } catch RepoPromptBuiltInAgentWorkflow.ResolutionError.conflictingReferences {
            throw MCPError.invalidParams("Specify either workflow_id or workflow_name, not both.")
        } catch let RepoPromptBuiltInAgentWorkflow.ResolutionError.unknownReference(reference) {
            throw MCPError.invalidParams("Workflow '\(reference)' was not found.")
        } catch {
            throw MCPError.invalidParams("Invalid workflow selection.")
        }
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
