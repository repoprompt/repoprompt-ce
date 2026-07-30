import Foundation

/// Interactive native-runtime seam for the Claude-compatible plugin path.
///
/// Full native process control remains core-owned for this slice. The adapter is
/// nevertheless the object Agent Mode consumes: it carries the package-shaped
/// runtime DTO and delegates the `NativeAgentRuntimeControlling` contract to the
/// current core controller. This keeps run behavior unchanged while routing the
/// interactive path through the future plugin boundary.
actor ClaudeCompatibleNativeSessionAdapter: NativeAgentRuntimeControlling {
    typealias ControllerFactory = () -> any NativeAgentRuntimeControlling

    let runtimeConfig: ClaudeCompatiblePluginRuntimeConfig
    private let controller: any NativeAgentRuntimeControlling

    init(
        runtimeConfig: ClaudeCompatiblePluginRuntimeConfig,
        controllerFactory: @escaping ControllerFactory
    ) {
        self.runtimeConfig = runtimeConfig
        controller = controllerFactory()
    }

    var hasActiveSession: Bool {
        get async { await controller.hasActiveSession }
    }

    var hasTurnInFlight: Bool {
        get async { await controller.hasTurnInFlight }
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        get async { await controller.events }
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
        try await controller.startOrResume(
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

    func sendUserMessage(_ text: String) async throws -> UUID {
        try await controller.sendUserMessage(text)
    }

    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome {
        await controller.interruptTurn(reason: reason)
    }

    func shutdown() async {
        await controller.shutdown()
    }

    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async {
        await controller.respondToPermissionRequest(id: id, decision: decision)
    }

    #if DEBUG
        func debugProcessSnapshot() async -> AgentRuntimeProcessSnapshot? {
            await controller.debugProcessSnapshot()
        }
    #endif

    static func streamResult(from providerResult: ClaudeCompatiblePluginStreamResult) -> AIStreamResult {
        ClaudeCompatiblePluginBridge.streamResult(from: providerResult)
    }
}
