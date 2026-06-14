import Foundation

enum ContextBuilderRunOrigin: Equatable {
    case ui
    case mcp(controlToken: UUID)

    var isMCP: Bool {
        if case .mcp = self { return true }
        return false
    }
}

enum ContextBuilderRunTerminalOutcome: Equatable {
    case completed
    case cancelled
    case failed(String)

    var runState: AgentRunState {
        switch self {
        case .completed:
            .completed
        case .cancelled:
            .cancelled
        case let .failed(message):
            .failed(message)
        }
    }
}

enum ContextBuilderRunWaiterResolution {
    case snapshot
    case cancellationError
}

/// Coordinates successful child-connection finalization. Each tab-context snapshot must be
/// positively committed before transport termination can trigger connection-backed cleanup.
/// Termination completion is joined before connection/run mappings are removed.
@MainActor
enum ContextBuilderChildConnectionFinalizer {
    typealias RequestTermination = @MainActor (_ connectionID: UUID) -> Task<Void, Never>
    typealias CommitContext = @MainActor (_ connectionID: UUID) async -> Bool
    typealias BeforeTerminationRequest = @MainActor () async -> Void
    typealias BeforeTerminationJoin = @MainActor () async -> Void
    typealias CleanupMapping = @MainActor (_ connectionID: UUID) -> Void

    static func finalize(
        connectionIDs: [UUID],
        commitContext: CommitContext,
        beforeTerminationRequest: BeforeTerminationRequest,
        requestTermination: RequestTermination,
        beforeTerminationJoin: BeforeTerminationJoin,
        cleanupMapping: CleanupMapping
    ) async -> Bool {
        for connectionID in connectionIDs {
            guard await commitContext(connectionID) else { return false }
        }

        await beforeTerminationRequest()
        let terminationTasks = connectionIDs.map(requestTermination)
        await beforeTerminationJoin()
        for task in terminationTasks {
            await task.value
        }

        for connectionID in connectionIDs {
            cleanupMapping(connectionID)
        }
        return true
    }
}

@MainActor
final class ContextBuilderRunRecord {
    struct TeardownPayload {
        let provider: HeadlessAgentProvider?
        let executionTask: Task<Void, Never>?
    }

    let runID: UUID
    let tabID: UUID
    let session: ContextBuilderAgentViewModel.TabSession
    let ownership: AgentRunOwnership
    let origin: ContextBuilderRunOrigin
    let agentKind: AgentProviderKind
    let modelRaw: String
    let progressReporter: ContextBuilderMCPProgressReporter?
    let workspaceContext: ContextBuilderWorkspaceContext?

    var output = ContextBuilderAssistantOutputAccumulator()
    var executionTask: Task<Void, Never>?
    var previewPublicationTask: Task<Void, Never>?
    var lastPublishedPreview: String?
    var restoreConfiguration: (() -> Void)?

    private var continuation: CheckedContinuation<ContextBuilderAgentViewModel.ContextBuilderRunSnapshot, Error>?
    private var provider: HeadlessAgentProvider?
    private(set) var terminalOutcome: ContextBuilderRunTerminalOutcome?
    private(set) var teardownStartedAt: Date?
    private(set) var teardownFinishedAt: Date?
    private(set) var providerDisposalFinished = false
    private(set) var executionTaskFinished = false

    init(
        runID: UUID,
        tabID: UUID,
        session: ContextBuilderAgentViewModel.TabSession,
        ownership: AgentRunOwnership,
        origin: ContextBuilderRunOrigin,
        agentKind: AgentProviderKind,
        modelRaw: String,
        workspaceContext: ContextBuilderWorkspaceContext? = nil,
        continuation: CheckedContinuation<ContextBuilderAgentViewModel.ContextBuilderRunSnapshot, Error>? = nil,
        restoreConfiguration: (() -> Void)? = nil,
        progressReporter: ContextBuilderMCPProgressReporter? = nil
    ) {
        self.runID = runID
        self.tabID = tabID
        self.session = session
        self.ownership = ownership
        self.origin = origin
        self.agentKind = agentKind
        self.modelRaw = modelRaw
        self.workspaceContext = workspaceContext
        self.continuation = continuation
        self.restoreConfiguration = restoreConfiguration
        self.progressReporter = progressReporter
    }

    func reportProgress(_ phase: ContextBuilderMCPProgressPhase) async {
        await progressReporter?(phase)
    }

    var isTerminal: Bool {
        terminalOutcome != nil
    }

    var isTeardownPending: Bool {
        teardownStartedAt != nil && teardownFinishedAt == nil
    }

    @discardableResult
    func claimTerminal(_ outcome: ContextBuilderRunTerminalOutcome) -> Bool {
        guard terminalOutcome == nil else { return false }
        terminalOutcome = outcome
        return true
    }

    func installProvider(_ provider: HeadlessAgentProvider) -> Bool {
        guard terminalOutcome == nil, teardownStartedAt == nil, self.provider == nil else {
            return false
        }
        self.provider = provider
        return true
    }

    func takeContinuation() -> CheckedContinuation<ContextBuilderAgentViewModel.ContextBuilderRunSnapshot, Error>? {
        defer { continuation = nil }
        return continuation
    }

    func takeConfigurationRestoration() -> (() -> Void)? {
        defer { restoreConfiguration = nil }
        return restoreConfiguration
    }

    func beginTeardown(at date: Date = Date()) -> TeardownPayload? {
        guard teardownStartedAt == nil else { return nil }
        teardownStartedAt = date
        let payload = TeardownPayload(provider: provider, executionTask: executionTask)
        provider = nil
        return payload
    }

    func markProviderDisposalFinished() {
        providerDisposalFinished = true
        finishTeardownIfReady()
    }

    func markExecutionTaskFinished() {
        executionTaskFinished = true
        executionTask = nil
        finishTeardownIfReady()
    }

    private func finishTeardownIfReady() {
        guard providerDisposalFinished, executionTaskFinished, teardownFinishedAt == nil else { return }
        teardownFinishedAt = Date()
    }
}

@MainActor
final class ContextBuilderRunRegistry {
    private var recordsByRunID: [UUID: ContextBuilderRunRecord] = [:]
    private var activeRunIDByTabID: [UUID: UUID] = [:]

    @discardableResult
    func register(_ record: ContextBuilderRunRecord) -> Bool {
        guard recordsByRunID[record.runID] == nil,
              activeRunIDByTabID[record.tabID] == nil
        else {
            return false
        }
        recordsByRunID[record.runID] = record
        activeRunIDByTabID[record.tabID] = record.runID
        return true
    }

    func record(runID: UUID) -> ContextBuilderRunRecord? {
        recordsByRunID[runID]
    }

    func activeRecord(tabID: UUID) -> ContextBuilderRunRecord? {
        guard let runID = activeRunIDByTabID[tabID] else { return nil }
        return recordsByRunID[runID]
    }

    func acceptsEvents(from record: ContextBuilderRunRecord, currentSession: ContextBuilderAgentViewModel.TabSession?) -> Bool {
        recordsByRunID[record.runID] === record &&
            activeRunIDByTabID[record.tabID] == record.runID &&
            currentSession === record.session &&
            !record.isTerminal &&
            record.session.activeRunOwnership == record.ownership
    }

    @discardableResult
    func releaseActiveSlot(for record: ContextBuilderRunRecord) -> Bool {
        guard activeRunIDByTabID[record.tabID] == record.runID else { return false }
        activeRunIDByTabID.removeValue(forKey: record.tabID)
        return true
    }

    @discardableResult
    func removeAfterTeardown(_ record: ContextBuilderRunRecord) -> Bool {
        guard recordsByRunID[record.runID] === record,
              record.teardownFinishedAt != nil
        else {
            return false
        }
        recordsByRunID.removeValue(forKey: record.runID)
        return true
    }
}
