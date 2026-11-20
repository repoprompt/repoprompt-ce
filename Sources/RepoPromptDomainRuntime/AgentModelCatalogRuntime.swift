import Dispatch
import Foundation
import RepoPromptAIContracts

/// Admission over the already-advertised catalogue, never a discovery or persistence entrypoint.
/// Producers refresh this index while building ordinary picker/list_agents options. A cold or
/// invalidated index fails closed; an oversight request must not warm it on the caller's behalf.
package final class ModelCatalogRuntime<ACPRegistry: AnyObject, CodexRegistry: AnyObject, Availability>: @unchecked Sendable {
    /// Construction must be pure: factories run under their respective slot locks and must not
    /// invoke storage, invalidation, the backend registrar, or other runtime operations.
    package struct Dependencies {
        package let makeACPRegistry: (@escaping (AgentProviderKind) -> Void) -> ACPRegistry
        package let makeCodexRegistry: (@escaping () -> Void) -> CodexRegistry
        package let isAgentAvailable: (AgentProviderKind, Availability) -> Bool
        /// Producer-time decomposition only; admission never invokes this policy or reads storage.
        package let reasoningEffortRaw: (AgentProviderKind, AgentModelOption) -> String?

        package init(
            makeACPRegistry: @escaping (@escaping (AgentProviderKind) -> Void) -> ACPRegistry,
            makeCodexRegistry: @escaping (@escaping () -> Void) -> CodexRegistry,
            isAgentAvailable: @escaping (AgentProviderKind, Availability) -> Bool,
            reasoningEffortRaw: @escaping (AgentProviderKind, AgentModelOption) -> String?
        ) {
            self.makeACPRegistry = makeACPRegistry
            self.makeCodexRegistry = makeCodexRegistry
            self.isAgentAvailable = isAgentAvailable
            self.reasoningEffortRaw = reasoningEffortRaw
        }
    }

    private let dependencies: Dependencies

    private let registerBackendChanges: (@escaping @Sendable () -> Void) -> Void
    private let activation = NSCondition()
    private var activationState = 0 // 0: cold, 1: installing, 2: installed
    #if DEBUG
        private let activationWaiterArrived = DispatchSemaphore(value: 0)
    #endif
    private let acpSlotLock = NSLock()
    private var acpSlot: ACPRegistry?
    private let codexSlotLock = NSLock()
    private var codexSlot: CodexRegistry?

    package init(
        dependencies: Dependencies,
        registerBackendChanges: @escaping (@escaping @Sendable () -> Void) -> Void
    ) {
        self.dependencies = dependencies
        self.registerBackendChanges = registerBackendChanges
    }

    /// Only pure construction occurs under these slot locks. Neither registry constructor nor
    /// dependency assembly invokes storage, invalidation, or other runtime operations.
    package var acpRegistry: ACPRegistry {
        acpSlotLock.withLock {
            if let acpSlot { return acpSlot }
            let registry = dependencies.makeACPRegistry { [weak self] agent in
                self?.invalidate(agent)
            }
            acpSlot = registry
            return registry
        }
    }

    package var codexRegistry: CodexRegistry {
        codexSlotLock.withLock {
            if let codexSlot { return codexSlot }
            let registry = dependencies.makeCodexRegistry { [weak self] in
                self?.invalidate(.codexExec)
            }
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
        package func test_waitForActivationWaiter() -> Bool {
            activationWaiterArrived.wait(timeout: .now() + 5) == .success
        }

        package var test_initializedSlots: (acp: Bool, codex: Bool) {
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
    package func productionGeneration(for agent: AgentProviderKind) -> UInt64 {
        ensureAdvertisedActive()
        return lock.withLock { generationsByAgent[agent, default: 0] }
    }

    @discardableResult
    package func record(_ options: [AgentModelOption], for agent: AgentProviderKind, generation: UInt64) -> Bool {
        ensureAdvertisedActive()
        // Decomposition belongs to the producer too: Codex's legacy parser can consult persisted
        // discovery for extended effort suffixes. Never invoke that default parser during admission.
        let index = options.reduce(into: [String: Entry]()) { index, option in
            let effort = dependencies.reasoningEffortRaw(agent, option)
            index[option.rawValue] = Entry(option: option, reasoningEffortRaw: effort)
        }
        return lock.withLock {
            guard generationsByAgent[agent, default: 0] == generation else { return false }
            optionsByAgent[agent] = index
            return true
        }
    }

    package func invalidate(_ agent: AgentProviderKind) {
        ensureAdvertisedActive()
        lock.withLock {
            generationsByAgent[agent, default: 0] &+= 1
            optionsByAgent.removeValue(forKey: agent)
        }
    }

    package func selection(
        _ modelID: String,
        availability: Availability
    ) throws -> Selection {
        ensureAdvertisedActive()
        guard let id = AgentModelSelectionID.parse(modelID),
              let agent = AgentProviderKind(rawValue: id.agentRaw),
              id.rawValue == modelID
        else { throw AdmissionError.invalidID }
        guard dependencies.isAgentAvailable(agent, availability) else {
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
    package func modelIDs(for agent: AgentProviderKind, availability: Availability) -> [String] {
        ensureAdvertisedActive()
        guard dependencies.isAgentAvailable(agent, availability) else { return [] }
        return lock.withLock {
            (optionsByAgent[agent]?.keys.sorted() ?? []).prefix(8).map {
                AgentModelSelectionID(agentRaw: agent.rawValue, modelRaw: $0).rawValue
            }
        }
    }

    package struct Selection {
        package let id: AgentModelSelectionID
        package let agent: AgentProviderKind
        package let option: AgentModelOption

        /// Validate the complete encoded ID before decomposing it. Keep native effort encoded so
        /// manually created sessions use the same next-turn baseline as MCP-created sessions.
        package var storedModelRaw: String {
            id.modelRaw
        }

        package let reasoningEffortRaw: String?
    }

    package enum AdmissionError: Error, Equatable {
        case invalidID, unavailable, catalogueUnavailable, unadvertised

        package var diagnosticCode: String {
            switch self {
            case .invalidID: "model_id_invalid"
            case .unavailable: "model_agent_unavailable"
            case .catalogueUnavailable: "model_catalog_unavailable"
            case .unadvertised: "model_not_advertised"
            }
        }

        package var message: String {
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
