import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptClaudeProvider
import RepoPromptDomainRuntime

/// Interactive native-runtime seam for the Claude-compatible plugin path.
///
/// Full native process control remains core-owned for this slice. The adapter is
/// nevertheless the object Agent Mode consumes: it carries the package-shaped
/// runtime DTO and delegates the `NativeAgentRuntimeControlling` contract to the
/// current core controller. This keeps run behavior unchanged while routing the
/// interactive path through the future plugin boundary.
actor ClaudeCompatibleNativeSessionAdapter: NativeAgentRuntimeControlling, MCPRunRoutingCleanupRetaining {
    typealias ControllerFactory = () -> any NativeAgentRuntimeControlling

    let runtimeConfig: ClaudeCompatiblePluginRuntimeConfig
    private let controller: any NativeAgentRuntimeControlling
    private let routingIdentity: (runID: UUID, routeID: Int)?
    private var routingCleanupReceipt: MCPRunRoutingCleanupReceipt?
    private var routingCleanupTail: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?

    init(
        runtimeConfig: ClaudeCompatiblePluginRuntimeConfig,
        routingIdentity: (runID: UUID, routeID: Int)? = nil,
        controllerFactory: @escaping ControllerFactory
    ) {
        self.runtimeConfig = runtimeConfig
        self.routingIdentity = routingIdentity
        controller = controllerFactory()
    }

    #if DEBUG
        func test_processController() -> ClaudeNativeProcessSessionController? {
            controller as? ClaudeNativeProcessSessionController
        }
    #endif

    var hasActiveSession: Bool {
        get async { await controller.hasActiveSession }
    }

    var hasTurnInFlight: Bool {
        get async { await controller.hasTurnInFlight }
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        get async { await controller.events }
    }

    var eventStreamSnapshot: (generation: UInt64, stream: AsyncStream<NativeAgentRuntimeEvent>) {
        get async { await controller.eventStreamSnapshot }
    }

    func ensureEventsStreamReady() async {
        await controller.ensureEventsStreamReady()
    }

    func resetEventsStreamForNewRun() async {
        await controller.resetEventsStreamForNewRun()
    }

    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        guard shutdownTask == nil else { throw CancellationError() }
        // This immutable registrar belongs to the launch, not to the adapter's later handoff.
        if let origin = routingCleanupReceipt {
            guard !origin.isConsumed,
                  let processController = controller as? ClaudeNativeProcessSessionController
            else {
                throw AIProviderError.invalidConfiguration(detail: "Claude process cannot retain its originating routing registration")
            }
            let result = try await processController.startOrResume(
                existingSessionID: existingSessionID, model: model, effortLevel: effortLevel,
                systemPromptOverride: systemPromptOverride,
                expectedAgentPIDRegistrar: .serverNetworkManager(registration: origin)
            )
            guard shutdownTask == nil, !origin.isConsumed, routingCleanupReceipt == origin else {
                throw CancellationError()
            }
            return result
        }
        return try await controller.startOrResume(
            existingSessionID: existingSessionID,
            model: model,
            effortLevel: effortLevel,
            systemPromptOverride: systemPromptOverride
        )
    }

    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        await controller.currentSessionRef()
    }

    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws {
        try await controller.applyModelAndEffort(model: model, effortLevel: effortLevel)
    }

    func applyModelAndEffortWithProof(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws -> NativeAgentRuntimeConfigurationApplication {
        try await controller.applyModelAndEffortWithProof(model: model, effortLevel: effortLevel)
    }

    func applyModelAndEffortWithProof(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?, replacingFailure: NativeAgentRuntimeConfigurationFailure) async throws -> NativeAgentRuntimeConfigurationApplication {
        try await controller.applyModelAndEffortWithProof(model: model, effortLevel: effortLevel, replacingFailure: replacingFailure)
    }

    func applyModelAndEffortForTurn(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?, replacingFailure: NativeAgentRuntimeConfigurationFailure?) async throws -> NativeAgentRuntimeTurnConfigurationOutcome {
        try await controller.applyModelAndEffortForTurn(model: model, effortLevel: effortLevel, replacingFailure: replacingFailure)
    }

    func sendUserMessage(_ text: String, configuration: NativeAgentRuntimeConfigurationProof) async throws -> UUID {
        try await controller.sendUserMessage(text, configuration: configuration)
    }

    func sendUserMessage(_ text: String) async throws -> UUID {
        try await controller.sendUserMessage(text)
    }

    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome {
        await controller.interruptTurn(reason: reason)
    }

    func retainRoutingCleanup(_ receipt: MCPRunRoutingCleanupReceipt) -> Bool {
        guard shutdownTask == nil, let routingIdentity,
              receipt.runID == routingIdentity.runID, receipt.routeID == routingIdentity.routeID,
              receipt.routeOwner != nil, !receipt.isConsumed,
              receipt.managerIdentity == ObjectIdentifier(ServerNetworkManager.shared) else { return false }
        if let origin = routingCleanupReceipt {
            guard origin.routeOwner === receipt.routeOwner else { return false }
            if origin == receipt { return true }
        }
        let previous = routingCleanupReceipt
        let predecessor = routingCleanupTail
        routingCleanupReceipt = receipt
        if let previous {
            routingCleanupTail = Task {
                await predecessor?.value
                await ServerNetworkManager.shared.cleanupRunRoutingState(ownedBy: previous)
            }
        }
        return true
    }

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let predecessor = routingCleanupTail
        let receipt = routingCleanupReceipt
        let controller = controller
        let task = Task {
            await controller.shutdown()
            await predecessor?.value
            if let receipt {
                await ServerNetworkManager.shared.cleanupRunRoutingState(ownedBy: receipt)
            }
        }
        shutdownTask = task
        routingCleanupTail = nil
        routingCleanupReceipt = nil
        await task.value
    }

    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async {
        await controller.respondToPermissionRequest(id: id, decision: decision)
    }

    static func streamResult(from providerResult: ClaudeCompatiblePluginStreamResult) -> AIStreamResult {
        ClaudeCompatiblePluginBridge.streamResult(from: providerResult)
    }
}
