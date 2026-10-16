import Foundation

/// Core Agent Mode contract for native CLI runtimes that keep an interactive
/// process/session alive across turns.
///
/// This is an app-internal contract, not the future external plugin API. It can
/// use core app models (`AIStreamResult`, `AgentApprovalRequest`, and
/// `AgentApprovalDecision`) because adapters/bridges are expected to translate
/// plugin-owned DTOs before events reach Agent Mode.
protocol NativeAgentRuntimeControlling: Actor {
    var hasActiveSession: Bool { get async }
    var hasTurnInFlight: Bool { get async }
    var events: AsyncStream<NativeAgentRuntimeEvent> { get async }

    func ensureEventsStreamReady() async
    func resetEventsStreamForNewRun() async
    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef
    func currentSessionRef() async -> NativeAgentRuntimeSessionRef
    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws
    /// Unlike the legacy live-update helper, this proves the complete requested configuration.
    func applyModelAndEffortWithProof(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws -> NativeAgentRuntimeConfigurationApplication
    /// Begins fallback only if the failed application is still current, consuming its intent.
    func applyModelAndEffortWithProof(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?, replacingFailure: NativeAgentRuntimeConfigurationFailure) async throws -> NativeAgentRuntimeConfigurationApplication
    /// Turn-scoped Auto application; fallback consumes only a still-current failure token.
    func applyModelAndEffortForTurn(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?, replacingFailure: NativeAgentRuntimeConfigurationFailure?) async throws -> NativeAgentRuntimeTurnConfigurationOutcome
    func sendUserMessage(_ text: String, configuration: NativeAgentRuntimeConfigurationProof) async throws -> UUID
    /// Maintenance commands intentionally do not require an ordinary-turn configuration proof.
    func sendUserMessage(_ text: String) async throws -> UUID
    /// Sends a reasoned interrupt request to the provider runtime.
    /// - Parameter reason: "interrupt" for steering (graceful), "cancel" for forceful stop.
    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome
    func cleanupConversation(_ handle: ProviderConversationCleanupHandle, action: ProviderConversationCleanupAction) async -> ProviderConversationCleanupOutcome
    func shutdown() async
    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async
}

extension NativeAgentRuntimeControlling {
    /// Fail closed for runtimes that have not implemented application proof. In particular,
    /// an old no-op fake must not accidentally certify provider application.
    func applyModelAndEffortWithProof(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws -> NativeAgentRuntimeConfigurationApplication {
        .notReady
    }

    /// A runtime without atomic failure-token validation must not recertify an older turn.
    func applyModelAndEffortWithProof(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?, replacingFailure _: NativeAgentRuntimeConfigurationFailure) async throws -> NativeAgentRuntimeConfigurationApplication {
        .superseded
    }

    /// Runtimes must implement failure-token ownership to support conditional fallback.
    /// A legacy Void update alone cannot authorize restoring a failed turn's configuration.
    func applyModelAndEffortForTurn(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?, replacingFailure: NativeAgentRuntimeConfigurationFailure?) async throws -> NativeAgentRuntimeTurnConfigurationOutcome {
        guard replacingFailure == nil else { return .superseded }
        try await applyModelAndEffort(model: model, effortLevel: effortLevel)
        return .applied
    }

    func sendUserMessage(_: String, configuration _: NativeAgentRuntimeConfigurationProof) async throws -> UUID {
        throw NativeAgentRuntimeControllerError.configurationNotCurrent
    }

    func cleanupConversation(_ handle: ProviderConversationCleanupHandle, action: ProviderConversationCleanupAction) async -> ProviderConversationCleanupOutcome {
        .unsupported(message: "Native runtime has no local API for \(action.rawValue) cleanup of conversations.")
    }
}

// MARK: - Current Claude-compatible native runtime aliases

// Native process control is still core-owned in this wave. These compatibility
// aliases let coordinators/runners depend on the provider-neutral contract
// while preserving the current Claude runtime DTO shapes. When a second native
// provider lands, the aliases become proper neutral DTOs and the Claude
// controller conforms via its own mapping.
// See docs/architecture/provider-plugins.md for the full bridge/adapter layout.
typealias NativeAgentRuntimeEvent = ClaudeNativeProcessSessionController.Event
typealias NativeAgentRuntimeSessionRef = ClaudeNativeProcessSessionController.SessionRef
typealias NativeAgentRuntimeTurnStatus = ClaudeNativeProcessSessionController.TurnStatus
typealias NativeAgentRuntimeRuntimeInitStatus = ClaudeNativeProcessSessionController.RuntimeInitStatus
typealias NativeAgentRuntimeInterruptOutcome = ClaudeNativeProcessSessionController.InterruptOutcome
typealias NativeAgentRuntimeControllerError = ClaudeNativeProcessSessionController.ControllerError
typealias NativeAgentRuntimeEffortLevel = ClaudeCodeEffortLevel

extension ClaudeNativeProcessSessionController: NativeAgentRuntimeControlling {}
