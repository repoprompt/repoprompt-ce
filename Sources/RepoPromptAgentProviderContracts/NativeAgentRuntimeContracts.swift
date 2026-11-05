import Foundation
import RepoPromptDomainRuntime

/// Core Agent Mode contract for native CLI runtimes that keep an interactive
/// process/session alive across turns.
///
/// This is an app-internal contract, not the future external plugin API. It can
/// use core app models (`AIStreamResult`, `AgentApprovalRequest`, and
/// `AgentApprovalDecision`) because adapters/bridges are expected to translate
/// plugin-owned DTOs before events reach Agent Mode.
package struct NativeAgentRuntimeEventStreamHandle {
    package let generation: UInt64
    package let stream: AsyncStream<NativeAgentRuntimeEvent>

    package init(generation: UInt64, stream: AsyncStream<NativeAgentRuntimeEvent>) {
        self.generation = generation
        self.stream = stream
    }
}

package protocol NativeAgentRuntimeControlling: Actor {
    var hasActiveSession: Bool { get async }
    var hasTurnInFlight: Bool { get async }
    var events: AsyncStream<NativeAgentRuntimeEvent> { get async }
    var eventStreamSnapshot: (generation: UInt64, stream: AsyncStream<NativeAgentRuntimeEvent>) { get async }

    func ensureEventsStreamReady() async
    func resetEventsStreamForNewRun() async
    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef
    func currentSessionRef() async -> NativeAgentRuntimeSessionRef
    /// Cached command metadata from this runtime's initialize response; never starts a process.
    func availableSlashCommands() async -> [NativeAgentRuntimeSlashCommand]
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
    func cleanupConversation(_ handle: ProviderConversationCleanupHandle, action: ProviderConversationCleanupAction) async -> RepoPromptDomainRuntime.ProviderConversationCleanupOutcome
    func shutdown() async
    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async
}

package extension NativeAgentRuntimeControlling {
    var eventStreamSnapshot: (generation: UInt64, stream: AsyncStream<NativeAgentRuntimeEvent>) {
        get async {
            let stream = await events
            return (0, stream)
        }
    }

    var eventStreamHandle: NativeAgentRuntimeEventStreamHandle {
        get async {
            let snapshot = await eventStreamSnapshot
            return NativeAgentRuntimeEventStreamHandle(generation: snapshot.generation, stream: snapshot.stream)
        }
    }

    func availableSlashCommands() async -> [NativeAgentRuntimeSlashCommand] {
        []
    }

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

    func cleanupConversation(_ handle: ProviderConversationCleanupHandle, action: ProviderConversationCleanupAction) async -> RepoPromptDomainRuntime.ProviderConversationCleanupOutcome {
        .unsupported(message: "Native runtime has no local API for \(action.rawValue) cleanup of conversations.")
    }
}
