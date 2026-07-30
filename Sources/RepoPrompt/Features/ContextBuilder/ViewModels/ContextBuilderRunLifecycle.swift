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

enum ContextBuilderRunWaiterResolution: Equatable {
    case snapshot
    case cancellationError
}

struct ContextBuilderRunCancellationSettlementPolicy: Equatable {
    let waiterResolution: ContextBuilderRunWaiterResolution
    let saveHistory: Bool
}

enum ContextBuilderRunCancellationState: Equatable {
    case none
    case requested
    case deferredUntilFinalContextCommitCompletes
    case applied
}

enum ContextBuilderRunCancellationDisposition: Equatable {
    case settleImmediately
    case deferredUntilFinalContextCommitCompletes
    case alreadyRequested
    case terminal
}

enum ContextBuilderResponseDeliveryDrainOutcome: Equatable {
    case drained
    case peerEOFDetached
    case detachedAfterResponseDeliveryDrained
    case failed

    var succeeded: Bool {
        self != .failed
    }

    var transportAlreadyClosed: Bool {
        self == .peerEOFDetached || self == .detachedAfterResponseDeliveryDrained
    }
}

@MainActor
enum ContextBuilderResponseDeliveryDrainResolver {
    static func resolve(
        initiallyDetached: Bool,
        awaitDrain: @MainActor () async -> Bool,
        isAuthoritativeDetached: @MainActor () -> Bool,
        awaitTeardownPublication: @MainActor () async -> MCPServerViewModel.ContextBuilderTeardownPublicationOutcome
    ) async -> ContextBuilderResponseDeliveryDrainOutcome {
        if !initiallyDetached, await awaitDrain() { return .drained }

        let publication = await awaitTeardownPublication()
        guard publication.completedDiscoveryCanCommit,
              isAuthoritativeDetached()
        else { return .failed }
        return publication == .peerEOFDetached
            ? .peerEOFDetached
            : .detachedAfterResponseDeliveryDrained
    }
}

/// Coordinates successful child-connection finalization. Each tab-context snapshot must be
/// positively committed before transport termination can trigger connection-backed cleanup.
/// Termination completion is joined before connection/run mappings are removed.
@MainActor
enum ContextBuilderChildConnectionFinalizer {
    typealias AwaitResponseDeliveryDrain = @MainActor (_ connectionID: UUID) async -> Bool
    typealias RequestTermination = @MainActor (_ connectionID: UUID) -> Task<Void, Never>
    typealias CommitContext = @MainActor (_ connectionID: UUID) async -> Bool
    typealias BeforeTerminationRequest = @MainActor () async -> Void
    typealias BeforeTerminationJoin = @MainActor () async -> Void
    typealias CleanupMapping = @MainActor (_ connectionID: UUID) -> Void

    static func finalize(
        connectionIDs: [UUID],
        awaitResponseDeliveryDrain: AwaitResponseDeliveryDrain,
        commitContext: CommitContext,
        beforeTerminationRequest: BeforeTerminationRequest,
        requestTermination: RequestTermination,
        beforeTerminationJoin: BeforeTerminationJoin,
        cleanupMapping: CleanupMapping
    ) async -> Bool {
        for connectionID in connectionIDs {
            guard await awaitResponseDeliveryDrain(connectionID) else { return false }
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

struct ContextBuilderResolvedRunAuthority {
    let configuration: ContextBuilderMCPRunConfiguration
    let agentKind: AgentProviderKind
    let modelRaw: String
}

struct ContextBuilderMCPRunConfiguration {
    let identity: WorkspaceSelectionIdentity
    let nestedTabContext: MCPServerViewModel.TabContextSnapshot
    let providerWorkspacePath: String
    let discoveryTokenBudget: Int
    let planTokenBudget: Int
    let enhancementMode: PromptEnhancementMode
    let allowClarifyingQuestions: Bool
    let questionTimeoutSeconds: TimeInterval
    let responseType: String?
    let planningModelRaw: String?
    let isSystemWorkspace: Bool

    var effectiveTokenBudget: Int {
        let wantsResponse = responseType.flatMap {
            ContextBuilderResponseType(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }?.wantsResponse ?? false
        return ContextBuilderBudgetResolver.resolveBudget(
            wantsResponse: wantsResponse,
            discoveryTokenBudget: discoveryTokenBudget,
            planTokenBudget: planTokenBudget
        )
    }
}

@MainActor
final class ContextBuilderRunRecord {
    enum ProviderActivity {
        case firstEvent(type: String)
        case firstRepoPromptTool(name: String)
    }

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
    let activityReporter: ContextBuilderMCPActivityReporter?
    let workspaceContext: ContextBuilderWorkspaceContext?
    let mcpConfiguration: ContextBuilderMCPRunConfiguration?

    var output = ContextBuilderAssistantOutputAccumulator()
    var executionTask: Task<Void, Never>?
    var previewPublicationTask: Task<Void, Never>?
    var lastPublishedPreview: String?
    var finalContextConnectionIDForDiagnostics: UUID?
    var restoreConfiguration: (() -> Void)?

    private(set) var committedTabSnapshot: MCPServerViewModel.ContextBuilderCommittedTabSnapshot?
    private var continuation: CheckedContinuation<ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion, Error>?
    private var provider: HeadlessAgentProvider?
    private(set) var finalContextCommitClaimed = false
    private(set) var cancellationState = ContextBuilderRunCancellationState.none
    private(set) var deferredCancellationSettlementPolicy: ContextBuilderRunCancellationSettlementPolicy?
    private(set) var terminalOutcome: ContextBuilderRunTerminalOutcome?
    private(set) var teardownStartedAt: Date?
    private(set) var teardownFinishedAt: Date?
    private(set) var providerDisposalFinished = false
    private(set) var executionTaskFinished = false
    private var didBeginProviderStreamProgress = false
    private var didReportRoutingConfirmed = false
    private var didObserveProviderEventAfterRouting = false
    private var didObserveRepoPromptToolAfterRouting = false

    init(
        runID: UUID,
        tabID: UUID,
        session: ContextBuilderAgentViewModel.TabSession,
        ownership: AgentRunOwnership,
        origin: ContextBuilderRunOrigin,
        agentKind: AgentProviderKind,
        modelRaw: String,
        workspaceContext: ContextBuilderWorkspaceContext? = nil,
        mcpConfiguration: ContextBuilderMCPRunConfiguration? = nil,
        continuation: CheckedContinuation<ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion, Error>? = nil,
        restoreConfiguration: (() -> Void)? = nil,
        progressReporter: ContextBuilderMCPProgressReporter? = nil,
        activityReporter: ContextBuilderMCPActivityReporter? = nil
    ) {
        self.runID = runID
        self.tabID = tabID
        self.session = session
        self.ownership = ownership
        self.origin = origin
        self.agentKind = agentKind
        self.modelRaw = modelRaw
        self.workspaceContext = workspaceContext
        self.mcpConfiguration = mcpConfiguration
        self.continuation = continuation
        self.restoreConfiguration = restoreConfiguration
        self.progressReporter = progressReporter
        self.activityReporter = activityReporter
    }

    func reportProgress(_ phase: ContextBuilderMCPProgressPhase) async {
        await progressReporter?(phase)
    }

    func reportRoutingProgress(_ phase: ContextBuilderMCPProgressPhase) async {
        guard !didBeginProviderStreamProgress else { return }
        if phase == .routingConfirmed {
            didReportRoutingConfirmed = true
        }
        await reportProgress(phase)
    }

    func beginProviderStreamProgress() async {
        guard !didBeginProviderStreamProgress else { return }
        didBeginProviderStreamProgress = true
        if !didReportRoutingConfirmed {
            didReportRoutingConfirmed = true
            await reportProgress(.routingConfirmed)
        }
        await reportProgress(.waitingForProviderStreamEvent)
    }

    func captureProviderActivity(_ result: AIStreamResult) -> [ProviderActivity] {
        var activity: [ProviderActivity] = []
        if !didObserveProviderEventAfterRouting {
            didObserveProviderEventAfterRouting = true
            activity.append(.firstEvent(type: result.type))
        }
        if !didObserveRepoPromptToolAfterRouting,
           result.type == "tool_call",
           let toolName = result.toolName,
           MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix(toolName)
        {
            didObserveRepoPromptToolAfterRouting = true
            activity.append(
                .firstRepoPromptTool(
                    name: MCPIntegrationHelper.canonicalRepoPromptToolName(toolName) ?? toolName
                )
            )
        }
        return activity
    }

    func reportProviderActivity(_ activity: [ProviderActivity]) async {
        for item in activity {
            switch item {
            case let .firstEvent(type):
                await reportProgress(.providerStreamActive)
                await activityReporter?(
                    .providerStreamActive,
                    "First discovery provider event received: \(type)"
                )
            case let .firstRepoPromptTool(name):
                await activityReporter?(
                    .providerStreamActive,
                    "First nested RepoPrompt MCP tool request observed: \(name)"
                )
            }
        }
    }

    var isTerminal: Bool {
        terminalOutcome != nil
    }

    var hasDeferredCancellationPending: Bool {
        cancellationState == .deferredUntilFinalContextCommitCompletes
    }

    var isTeardownPending: Bool {
        teardownStartedAt != nil && teardownFinishedAt == nil
    }

    @discardableResult
    func claimFinalContextCommit() -> Bool {
        guard terminalOutcome == nil,
              cancellationState == .none,
              !finalContextCommitClaimed
        else { return false }
        finalContextCommitClaimed = true
        return true
    }

    func requestCancellation(
        deferredSettlementPolicy: ContextBuilderRunCancellationSettlementPolicy
    ) -> ContextBuilderRunCancellationDisposition {
        guard terminalOutcome == nil else { return .terminal }
        guard cancellationState == .none else { return .alreadyRequested }

        if finalContextCommitClaimed {
            cancellationState = .deferredUntilFinalContextCommitCompletes
            deferredCancellationSettlementPolicy = deferredSettlementPolicy
            return .deferredUntilFinalContextCommitCompletes
        }
        cancellationState = .requested
        return .settleImmediately
    }

    func consumeDeferredCancellationAtSafeBoundary() -> ContextBuilderRunCancellationSettlementPolicy? {
        guard terminalOutcome == nil,
              cancellationState == .deferredUntilFinalContextCommitCompletes,
              let deferredCancellationSettlementPolicy
        else { return nil }
        cancellationState = .applied
        return deferredCancellationSettlementPolicy
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

    func installCommittedTabSnapshot(
        _ snapshot: MCPServerViewModel.ContextBuilderCommittedTabSnapshot
    ) -> Bool {
        guard snapshot.nestedRunID == runID,
              snapshot.identity.tabID == tabID,
              committedTabSnapshot == nil
        else { return false }
        committedTabSnapshot = snapshot
        return true
    }

    func takeContinuation() -> CheckedContinuation<ContextBuilderAgentViewModel.MCPContextBuilderRunCompletion, Error>? {
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

    func records(tabID: UUID) -> [ContextBuilderRunRecord] {
        recordsByRunID.values.filter { $0.tabID == tabID }
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
