import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptShared

actor DirectHeadlessProviderCoordinator {
    typealias BeginEpoch = @Sendable (
        _ registration: DomainAgentSessionRegistration,
        _ activationID: UUID
    ) async -> DomainAgentRunSessionStore.EpochBeginResult

    enum ExecutionPurpose {
        case directOracle
        case oracleGroup
        case agent

        var sandbox: String {
            switch self {
            case .oracleGroup: "read-only"
            case .directOracle, .agent: "workspace-write"
            }
        }
    }

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

    /// Transient startup/drain state only. The domain store remains the registration and
    /// terminal authority; this joins the work that must finish before its handler returns.
    private struct PendingStart {
        let sessionID: UUID
        var cancellationRequested = false
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private struct AgentRecord {
        let registration: DomainAgentSessionRegistration
        let activationID: UUID
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

    struct ConversationReference: Equatable {
        let id: UUID
        let updatedAt: Date
    }

    private struct Conversation {
        let id: UUID
        let providerID: String
        let model: String?
        var messages: [(role: String, text: String)]
        var updatedAt: Date
    }

    private let runtime: MCPDomainRuntime
    private let context: DirectHeadlessDomainContext
    private let settingsStore: DomainDirectSettingsStore
    private let environment: [String: String]
    private let allowsProviderProcessLaunchForTesting: Bool
    private let beginEpoch: BeginEpoch
    private var agents: [UUID: AgentRecord] = [:]
    private var pendingStarts: [UUID: PendingStart] = [:]
    private var providerTasks: [UUID: Task<String, Error>] = [:]
    private var conversations: [UUID: Conversation] = [:]
    private var isShuttingDown = false

    #if DEBUG
        private var pendingStartCancellationObserver: (@Sendable () -> Void)?
        private var runningPublicationObserver: (@Sendable (DomainAgentSessionRegistration) async -> Void)?

        func test_observePendingStartCancellation(_ observer: @escaping @Sendable () -> Void) {
            pendingStartCancellationObserver = observer
        }

        func test_observeRunningPublication(_ observer: @escaping @Sendable (DomainAgentSessionRegistration) async -> Void) {
            runningPublicationObserver = observer
        }
    #endif

    init(
        runtime: MCPDomainRuntime,
        context: DirectHeadlessDomainContext,
        settingsStore: DomainDirectSettingsStore,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        beginEpoch: BeginEpoch? = nil,
        allowsProviderProcessLaunchForTesting: Bool = false
    ) {
        self.runtime = runtime
        self.context = context
        self.settingsStore = settingsStore
        self.environment = environment
        self.allowsProviderProcessLaunchForTesting = allowsProviderProcessLaunchForTesting
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

    static func codexExecArguments(model: String?, purpose: ExecutionPurpose) -> [String] {
        var arguments: [String] = []
        if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model != "default" {
            arguments += ["--model", model]
        }
        arguments += ["exec", "--skip-git-repo-check", "--sandbox", purpose.sandbox, "--json", "-"]
        return arguments
    }

    func validateOracleRoster(_ roster: OracleRoster) throws {
        for model in roster.orderedModels {
            let descriptor = try resolveProvider(model.providerID)
            guard descriptor.executable != nil else {
                throw MCPError.invalidRequest(
                    "Provider '\(descriptor.id)' is unavailable: \(descriptor.unavailableReason ?? "not configured")"
                )
            }
        }
    }

    func runProviderOnce(
        message: String,
        providerID: String?,
        model: String?,
        request: DomainPhysicalToolRequest,
        sessionID: UUID? = nil,
        purpose: ExecutionPurpose,
        carrierEnvironment: [String: String]? = nil
    ) async throws -> String {
        guard !isShuttingDown else { throw CancellationError() }
        try ProviderProcessLaunchPolicy.check(allowsLaunchInTests: allowsProviderProcessLaunchForTesting)
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
        guard !isShuttingDown else { throw CancellationError() }
        try Task.checkCancellation()
        let arguments = Self.codexExecArguments(model: model, purpose: purpose)
        let carrier = carrierEnvironment ?? DomainChildLaunchContext.current?.environment ?? [:]
        var childEnvironment = DirectProcess.withoutPrivateCarrier(from: environment)
        childEnvironment.merge(carrier) { _, supplied in supplied }
        let taskID = UUID()
        let task = Task {
            let output = try await DirectProcess.run(
                executable,
                arguments: arguments,
                input: Data(message.utf8),
                environment: childEnvironment,
                currentDirectory: snapshot.activeRoot,
                isProvider: true,
                allowsProviderProcessLaunchForTesting: allowsProviderProcessLaunchForTesting
            )
            return Self.finalAssistantText(from: output)
        }
        providerTasks[taskID] = task
        defer { providerTasks.removeValue(forKey: taskID) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func startAgent(args: [String: Value], request: DomainPhysicalToolRequest) async throws -> Value {
        guard !isShuttingDown else { throw CancellationError() }
        let sessionID = DomainChildLaunchContext.current?.runID ?? UUID()
        let activationID = UUID()
        pendingStarts[activationID] = PendingStart(sessionID: sessionID)
        defer { finishPendingStart(activationID) }
        try checkPendingStart(activationID)
        await settingsStore.bootstrap()
        let cleanupGuidance = try await settingsStore.effectiveValue(
            for: "agent_mode.show_built_in_workflow_cleanup_guidance"
        )
        try checkPendingStart(activationID)
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
        var registrationToCleanup: DomainAgentSessionRegistration?
        do {
            // Coordinator shutdown joins the entire setup operation, including root preparation.
            // Do not publish a registration if cancellation arrived during that preparation.
            try checkPendingStart(activationID)
            // Cancellation is installed by the store in the same actor turn as registration,
            // before either an epoch await or a running snapshot can expose this start.
            let registration = await runtime.agentSessionStore.register(sessionID: sessionID) { [weak self] registration in
                await self?.cancelRegisteredAgent(registration: registration, activationID: activationID)
            }
            registrationToCleanup = registration
            guard registration.generation > 0 else { throw CancellationError() }
            try checkPendingStart(activationID)
            let epoch: DomainAgentRunTurnEpoch
            let epochResult = await beginEpoch(registration, activationID)
            try checkPendingStart(activationID)
            switch epochResult {
            case let .accepted(value): epoch = value
            case let .rejected(reason): throw MCPError.internalError(reason)
            case .stale: throw MCPError.internalError("agent epoch changed during start")
            }
            let name = args["session_name"]?.stringValue
            let record = AgentRecord(
                registration: registration,
                activationID: activationID,
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
            #if DEBUG
                await runningPublicationObserver?(registration)
            #endif
            try checkPendingStart(activationID)
            guard agents[sessionID]?.registration == registration,
                  agents[sessionID]?.activationID == activationID
            else { throw MCPError.internalError("agent registration changed during start") }
            let capturedRequest = request
            let capturedCarrierEnvironment = DomainChildLaunchContext.current?.environment ?? [:]
            let task = Task { [weak self] in
                guard let coordinator = self else { return }
                let report = await DomainAgentRunExecutionCore.execute {
                    do {
                        let text = try await coordinator.runProviderOnce(
                            message: message,
                            providerID: descriptor.id,
                            model: args["model"]?.stringValue,
                            request: capturedRequest,
                            sessionID: sessionID,
                            purpose: .agent,
                            carrierEnvironment: capturedCarrierEnvironment
                        )
                        return .completed(assistantText: text)
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        throw error
                    }
                }
                guard case let .terminal(outcome) = report.result else { return }
                await coordinator.finishAgent(registration: registration, outcome: outcome)
            }
            agents[sessionID]?.task = task
            // No suspension between the last cancellation fence and attaching this task.
            // Once attached, the exact-registration handler cancels and joins the task.
            finishPendingStart(activationID)

            if args["detach"]?.boolValue == true {
                return running.toValue()
            }
            let timeout = args["timeout"]?.doubleValue ?? 120
            return await waitAgent(sessionID: sessionID, timeout: timeout).toValue()
        } catch {
            if let registrationToCleanup, agents[sessionID]?.registration == registrationToCleanup {
                agents.removeValue(forKey: sessionID)
            }
            await context.rollbackSessionRootOverlay(rootOverlayPreparation)
            if let registrationToCleanup {
                await runtime.agentSessionStore.cleanup(registration: registrationToCleanup)
            }
            throw error
        }
    }

    private func checkPendingStart(_ activationID: UUID) throws {
        guard !isShuttingDown,
              let pending = pendingStarts[activationID], !pending.cancellationRequested
        else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func finishPendingStart(_ activationID: UUID) {
        let pending = pendingStarts.removeValue(forKey: activationID)
        for waiter in pending?.drainWaiters ?? [] {
            waiter.resume()
        }
    }

    private func waitForPendingStart(_ activationID: UUID) async {
        guard pendingStarts[activationID] != nil else { return }
        await withCheckedContinuation { continuation in
            guard pendingStarts[activationID] != nil else {
                continuation.resume()
                return
            }
            pendingStarts[activationID]?.drainWaiters.append(continuation)
        }
    }

    private func requestPendingStartCancellation(_ activationID: UUID) {
        guard pendingStarts[activationID] != nil else { return }
        pendingStarts[activationID]?.cancellationRequested = true
        #if DEBUG
            pendingStartCancellationObserver?()
        #endif
    }

    private func cancelRegisteredAgent(
        registration: DomainAgentSessionRegistration,
        activationID: UUID
    ) async {
        if pendingStarts[activationID]?.sessionID == registration.sessionID {
            requestPendingStartCancellation(activationID)
            await waitForPendingStart(activationID)
        }
        guard let record = agents[registration.sessionID],
              record.registration == registration, record.activationID == activationID else { return }
        record.task?.cancel()
        await record.task?.value
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
        for activationID in pendingStarts.keys where pendingStarts[activationID]?.sessionID == sessionID {
            requestPendingStartCancellation(activationID)
        }
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

    func createConversation(
        providerID: String?,
        message: String,
        model: String?,
        request: DomainPhysicalToolRequest
    ) async throws -> (UUID, String) {
        let descriptor = try resolveProvider(providerID)
        let text = try await runProviderOnce(
            message: message,
            providerID: descriptor.id,
            model: model,
            request: request,
            purpose: .directOracle
        )
        let id = UUID()
        conversations[id] = Conversation(
            id: id,
            providerID: descriptor.id,
            model: model,
            messages: [("user", message), ("assistant", text)],
            updatedAt: Date()
        )
        return (id, text)
    }

    func continueConversation(
        id: UUID,
        message: String,
        request: DomainPhysicalToolRequest
    ) async throws -> String {
        guard var conversation = conversations[id] else {
            throw MCPError.invalidParams("unknown chat_id")
        }
        let history = conversation.messages.map { "\($0.role): \($0.text)" }.joined(separator: "\n\n")
        let prompt = history + "\n\nuser: " + message
        let text = try await runProviderOnce(
            message: prompt,
            providerID: conversation.providerID,
            model: conversation.model,
            request: request,
            purpose: .directOracle
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
            guard let found = conversations[id] else {
                throw MCPError.invalidParams("unknown chat_id")
            }
            conversation = found
        } else {
            guard let latest = latestConversation() else {
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

    func conversationReference(id: UUID) -> ConversationReference? {
        conversations[id].map { ConversationReference(id: $0.id, updatedAt: $0.updatedAt) }
    }

    func latestConversationReference() -> ConversationReference? {
        latestConversation().map { ConversationReference(id: $0.id, updatedAt: $0.updatedAt) }
    }

    private func latestConversation() -> Conversation? {
        conversations.values.max { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    func shutdown() async {
        isShuttingDown = true
        let pendingActivationIDs = Array(pendingStarts.keys)
        for activationID in pendingActivationIDs {
            requestPendingStartCancellation(activationID)
        }
        let agentTasks = agents.values.compactMap(\.task)
        let physicalTasks = Array(providerTasks.values)
        for task in agentTasks {
            task.cancel()
        }
        for task in physicalTasks {
            task.cancel()
        }
        for task in agentTasks {
            await task.value
        }
        for task in physicalTasks {
            _ = try? await task.value
        }
        for activationID in pendingActivationIDs {
            await waitForPendingStart(activationID)
        }
        providerTasks.removeAll()
    }

    /// Settles one agent run through the neutral terminal-outcome contract.
    /// The canonical exactly-once settlement stays owned by
    /// `DomainAgentRunSessionStore.publishTerminal`.
    private func finishAgent(
        registration: DomainAgentSessionRegistration,
        outcome: DomainAgentRunTerminalOutcome
    ) async {
        let sessionID = registration.sessionID
        guard var record = agents[sessionID], record.registration == registration else { return }
        let terminal = snapshot(
            record: record,
            status: outcome.snapshotStatus,
            statusText: Self.terminalStatusText(for: outcome),
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
        // Keep the task joinable until terminal publication has actually settled.
        if agents[sessionID]?.registration == registration {
            agents[sessionID]?.task = nil
        }
    }

    /// Concise terminal `status_text`. The final reply travels only in the bounded
    /// `assistant_text`; a failure keeps its first diagnostic line here, and the failure
    /// reason is carried explicitly by the outcome rather than re-derived from this label.
    ///
    /// Contract for every snapshot producer, including any new headless or start-expiry
    /// snapshot: publish a short `status_text`, carry the reply only in `assistant_text`, and
    /// when rebuilding a snapshot from another one copy `latestAssistantPreviewTotalCharacters`
    /// (plus `worktreeBindingState` / `parentIsWorktreeBound`) along with the preview.
    /// Omitting the total makes every already-bounded preview, ASCII included, republish without
    /// both `assistant_text_truncated` and `assistant_text_characters`; only the marker remains.
    nonisolated static func terminalStatusText(for outcome: DomainAgentRunTerminalOutcome) -> String {
        switch outcome.kind {
        case .completed:
            return "Completed"
        case .cancelled:
            return "Cancelled"
        case .failed:
            let firstLine = outcome.assistantText?
                .split(whereSeparator: \.isNewline)
                .lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            guard let firstLine else { return "Failed" }
            return DomainAgentRunSnapshot.boundedStatusText("Failed: \(firstLine)")
        }
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
        if let parameters = args["model_parameters"], parameters != .null, parameters != .array([]) {
            throw MCPError.invalidParams("model_parameters are supported only for app-backed Cursor sessions.")
        }
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
