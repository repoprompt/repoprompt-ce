import Dispatch
import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptSettingsCore

/// Admission over the already-advertised catalogue, never a discovery or persistence entrypoint.
/// Producers refresh this index while building ordinary picker/list_agents options. A cold or
/// invalidated index fails closed; an oversight request must not warm it on the caller's behalf.
final class AgentModelCatalogRuntime: @unchecked Sendable {
    static let shared = AgentModelCatalogRuntime(registerBackendChanges: { handler in
        ClaudeCodeCompatibleBackendStore.setConfigurationChangeHandler(handler)
    })

    private let registerBackendChanges: (@escaping @Sendable () -> Void) -> Void
    private let activation = NSCondition()
    private var activationState = 0 // 0: cold, 1: installing, 2: installed
    #if DEBUG
        private let activationWaiterArrived = DispatchSemaphore(value: 0)
    #endif
    private let acpSlotLock = NSLock()
    private var acpSlot: AgentACPModelRegistry?
    private let codexSlotLock = NSLock()
    private var codexSlot: AgentCodexModelRegistry?

    init(registerBackendChanges: @escaping (@escaping @Sendable () -> Void) -> Void) {
        self.registerBackendChanges = registerBackendChanges
    }

    /// Only pure construction occurs under these slot locks. Neither registry constructor nor
    /// dependency assembly invokes storage, invalidation, or other runtime operations.
    var acpRegistry: AgentACPModelRegistry {
        acpSlotLock.withLock {
            if let acpSlot { return acpSlot }
            let registry = AgentACPModelRegistry(dependencies: .app(invalidate: { [weak self] agent in
                self?.invalidate(agent)
            }))
            acpSlot = registry
            return registry
        }
    }

    var codexRegistry: AgentCodexModelRegistry {
        codexSlotLock.withLock {
            if let codexSlot { return codexSlot }
            let registry = AgentCodexModelRegistry(invalidate: { [weak self] in
                self?.invalidate(.codexExec)
            })
            codexSlot = registry
            return registry
        }
    }

    /// The production registrar only installs a handler; it never invokes it synchronously.
    /// Release the activation lock before invoking it; concurrent users wait until installation
    /// completes so that no advertised producer can publish before subscription is active.
    private func ensureAdvertisedActive() {
        activation.lock()
        #if DEBUG
            var reportedWaiter = false
        #endif
        while activationState == 1 {
            #if DEBUG
                if !reportedWaiter {
                    reportedWaiter = true
                    activationWaiterArrived.signal()
                }
            #endif
            activation.wait()
        }
        if activationState == 2 {
            activation.unlock()
            return
        }
        activationState = 1
        activation.unlock()

        registerBackendChanges { [weak self] in
            for agent in [AgentProviderKind.claudeCodeGLM, .kimiCode, .customClaudeCompatible] {
                self?.invalidate(agent)
            }
        }

        activation.lock()
        activationState = 2
        activation.broadcast()
        activation.unlock()
    }

    #if DEBUG
        func test_waitForActivationWaiter() -> Bool {
            activationWaiterArrived.wait(timeout: .now() + 5) == .success
        }

        var test_initializedSlots: (acp: Bool, codex: Bool) {
            let acp = acpSlotLock.withLock { acpSlot != nil }
            let codex = codexSlotLock.withLock { codexSlot != nil }
            return (acp, codex)
        }
    #endif

    private let lock = NSLock()
    private struct Entry {
        let option: AgentModelOption
        let reasoningEffortRaw: String?
    }

    private var optionsByAgent: [AgentProviderKind: [String: Entry]] = [:]
    private var generationsByAgent: [AgentProviderKind: UInt64] = [:]

    /// Capture before reading any source snapshot, not after options have been built.
    func productionGeneration(for agent: AgentProviderKind) -> UInt64 {
        ensureAdvertisedActive()
        return lock.withLock { generationsByAgent[agent, default: 0] }
    }

    @discardableResult
    func record(_ options: [AgentModelOption], for agent: AgentProviderKind, generation: UInt64) -> Bool {
        ensureAdvertisedActive()
        // Decomposition belongs to the producer too: Codex's legacy parser can consult persisted
        // discovery for extended effort suffixes. Never invoke that default parser during admission.
        let index = options.reduce(into: [String: Entry]()) { index, option in
            let effort: String? = if agent == .codexExec {
                CodexModelSpecifier(raw: option.rawValue).reasoningEffort?.rawValue
            } else if agent.usesClaudeTooling {
                ClaudeModelSpecifier(raw: option.rawValue).explicitEffortLevel?.rawValue
            } else { nil }
            index[option.rawValue] = Entry(option: option, reasoningEffortRaw: effort)
        }
        return lock.withLock {
            guard generationsByAgent[agent, default: 0] == generation else { return false }
            optionsByAgent[agent] = index
            return true
        }
    }

    func invalidate(_ agent: AgentProviderKind) {
        ensureAdvertisedActive()
        lock.withLock {
            generationsByAgent[agent, default: 0] &+= 1
            optionsByAgent.removeValue(forKey: agent)
        }
    }

    func selection(
        _ modelID: String,
        availability: AgentModelCatalog.AvailabilityContext
    ) throws -> Selection {
        ensureAdvertisedActive()
        guard let id = AgentModelSelectionID.parse(modelID),
              let agent = AgentProviderKind(rawValue: id.agentRaw),
              id.rawValue == modelID
        else { throw AdmissionError.invalidID }
        guard AgentModelCatalog.isAgentAvailable(agent, availability: availability) else {
            throw AdmissionError.unavailable
        }
        let entry: Entry = try lock.withLock {
            guard let index = optionsByAgent[agent] else { throw AdmissionError.catalogueUnavailable }
            guard let option = index[id.modelRaw] else { throw AdmissionError.unadvertised }
            return option
        }
        return Selection(id: id, agent: agent, option: entry.option, reasoningEffortRaw: entry.reasoningEffortRaw)
    }

    /// Bounded memory-only recovery hints; never discover or warm a provider catalogue on refusal.
    func modelIDs(for agent: AgentProviderKind, availability: AgentModelCatalog.AvailabilityContext) -> [String] {
        ensureAdvertisedActive()
        guard AgentModelCatalog.isAgentAvailable(agent, availability: availability) else { return [] }
        return lock.withLock {
            (optionsByAgent[agent]?.keys.sorted() ?? []).prefix(8).map {
                AgentModelSelectionID(agentRaw: agent.rawValue, modelRaw: $0).rawValue
            }
        }
    }

    struct Selection {
        let id: AgentModelSelectionID
        let agent: AgentProviderKind
        let option: AgentModelOption

        /// Validate the complete encoded ID before decomposing it. Keep native effort encoded so
        /// manually created sessions use the same next-turn baseline as MCP-created sessions.
        var storedModelRaw: String {
            id.modelRaw
        }

        let reasoningEffortRaw: String?
    }

    enum AdmissionError: Error, Equatable {
        case invalidID, unavailable, catalogueUnavailable, unadvertised

        var diagnosticCode: String {
            switch self {
            case .invalidID: "model_id_invalid"
            case .unavailable: "model_agent_unavailable"
            case .catalogueUnavailable: "model_catalog_unavailable"
            case .unadvertised: "model_not_advertised"
            }
        }

        var message: String {
            switch self {
            case .invalidID:
                "model_id must be an exact compound ID from agent_manage.list_agents, not a role."
            case .unavailable:
                "The selected agent is unavailable in the destination window. Refresh agent_manage.list_agents there."
            case .catalogueUnavailable:
                "The in-memory model catalogue is unavailable. Refresh agent_manage.list_agents in the destination window, then retry; this operation does not discover models."
            case .unadvertised:
                "model_id is not in the current advertised catalogue. Refresh agent_manage.list_agents in the destination window and use an exact returned model_id."
            }
        }
    }
}
