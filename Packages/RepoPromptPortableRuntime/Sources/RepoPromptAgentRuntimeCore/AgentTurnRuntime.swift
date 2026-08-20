import Foundation
import RepoPromptRuntimeModel

public struct ProviderTurnSettingsSnapshot: Sendable {
    public let effortID: String?
    public let permissionID: ProviderPermissionID
    public let settings: ProviderTurnSettings

    public init(
        effortID: String? = nil,
        permissionID: ProviderPermissionID,
        settings: ProviderTurnSettings
    ) {
        self.effortID = effortID
        self.permissionID = permissionID
        self.settings = settings
    }
}

public protocol ProviderTurnSettingsProviding: Sendable {
    func settings(for providerID: ProviderSettingsID) async throws -> ProviderTurnSettingsSnapshot
}

public struct AgentTurnRequest: Sendable {
    public let ownerID: RuntimeOwnerID
    public let model: ProviderModelDescriptor
    public let workflow: WorkflowDefinition

    public init(
        ownerID: RuntimeOwnerID,
        model: ProviderModelDescriptor,
        workflow: WorkflowDefinition
    ) {
        self.ownerID = ownerID
        self.model = model
        self.workflow = workflow
    }
}

public struct PreparedProviderTurn: Sendable {
    public let turnID: UUID
    public let preparedAt: Date
    public let ownerID: RuntimeOwnerID
    public let workflow: WorkflowDefinition
    public let configuration: CompiledProviderTurnConfiguration

    public init(
        turnID: UUID,
        preparedAt: Date,
        ownerID: RuntimeOwnerID,
        workflow: WorkflowDefinition,
        configuration: CompiledProviderTurnConfiguration
    ) {
        self.turnID = turnID
        self.preparedAt = preparedAt
        self.ownerID = ownerID
        self.workflow = workflow
        self.configuration = configuration
    }
}

public protocol ProviderTurnExecuting: Sendable {
    func execute(_ turn: PreparedProviderTurn) async throws
}

public actor AgentTurnRuntime {
    private let settingsProvider: any ProviderTurnSettingsProviding
    private let provider: any ProviderTurnExecuting
    private let clock: any RuntimeClock
    private let idGenerator: any RuntimeIDGenerator

    public init(
        settingsProvider: any ProviderTurnSettingsProviding,
        provider: any ProviderTurnExecuting,
        clock: any RuntimeClock = SystemRuntimeClock(),
        idGenerator: any RuntimeIDGenerator = SystemRuntimeIDGenerator()
    ) {
        self.settingsProvider = settingsProvider
        self.provider = provider
        self.clock = clock
        self.idGenerator = idGenerator
    }

    @discardableResult
    public func prepareAndExecute(_ request: AgentTurnRequest) async throws -> PreparedProviderTurn {
        try Task.checkCancellation()
        let snapshot = try await settingsProvider.settings(for: request.model.providerID)
        let configuration = try ProviderTurnConfigurationAdapters.compile(.init(
            providerID: request.model.providerID,
            model: request.model,
            effortID: snapshot.effortID,
            permissionID: snapshot.permissionID.rawValue,
            settings: snapshot.settings,
            toolValues: Self.toolValues(from: snapshot.settings),
            scopedResources: Set(request.workflow.resources),
            workflowID: nil
        ))
        let turn = PreparedProviderTurn(
            turnID: idGenerator.next(),
            preparedAt: clock.now(),
            ownerID: request.ownerID,
            workflow: request.workflow,
            configuration: configuration
        )
        try Task.checkCancellation()
        try await provider.execute(turn)
        return turn
    }

    private nonisolated static func toolValues(
        from settings: ProviderTurnSettings
    ) -> [String: AgentControlValue] {
        switch settings {
        case let .codex(value):
            [
                "codex.bash": .boolean(value.bashEnabled),
                "codex.search": .boolean(value.searchEnabled),
                "codex.goals": .boolean(value.goalsEnabled),
                "codex.reasoningSummaries": .boolean(value.reasoningSummariesEnabled),
                "codex.memories": .boolean(value.memoriesEnabled),
                "codex.mcpServers": .choices(value.mcpServerIDs.sorted())
            ]
        case let .claudeCompatible(value):
            [
                "claude.bash": .boolean(value.bashEnabled),
                "claude.mcpStrictMode": .boolean(value.strictMCPEnabled),
                "claude.toolSearch": .boolean(value.toolSearchEnabled),
                "claude.promptDelivery": .choice(value.promptDelivery.rawValue)
            ]
        case .acp, .directAPI:
            [:]
        }
    }
}
