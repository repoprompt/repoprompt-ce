import Foundation
import MCP

extension AgentModeViewModel {
    struct MCPModelParameterSelectionStagingRollback {
        fileprivate struct Change {
            let previousSelection: ACPModelParameterSelection?
            let stagedSelection: ACPModelParameterSelection
            let selectionRevision: UInt64
        }

        fileprivate let session: TabSession
        fileprivate let sessionID: UUID?
        fileprivate let persistentBinding: AgentPersistentSessionBindingIdentity?
        fileprivate let changes: [Change]
    }

    func mcpStageModelParameterSelections(
        tabID: UUID,
        agentRaw: String?,
        modelRaw: String?,
        selections: [ACPModelParameterSelection]
    ) throws -> MCPModelParameterSelectionStagingRollback? {
        guard !selections.isEmpty else { return nil }
        guard agentRaw == AgentProviderKind.cursor.rawValue,
              let modelRaw
        else {
            throw MCPError.invalidParams("Cursor model parameters require an explicit Cursor model selection.")
        }
        guard let session = session(for: tabID, createIfNeeded: false) else {
            throw MCPError.internalError("Failed to resolve the Agent session for model parameter configuration.")
        }
        let previousSelections = session.acpModelParameterSelections
        try mcpStoreModelParameterSelections(
            tabID: tabID,
            selectedAgent: .cursor,
            selectedModelRaw: modelRaw,
            selections: selections,
            schedulePersistence: false
        )
        let stagedSelections = session.acpModelParameterSelections
        let previousByIdentity = previousSelections.reduce(
            into: [ACPModelParameterIdentity: ACPModelParameterSelection]()
        ) { result, selection in
            result[selection.identity] = selection
        }
        let stagedByIdentity = stagedSelections.reduce(
            into: [ACPModelParameterIdentity: ACPModelParameterSelection]()
        ) { result, selection in
            result[selection.identity] = selection
        }
        let changes: [MCPModelParameterSelectionStagingRollback.Change] = ACPModelParameterSelection
            .normalized(selections).compactMap { selection in
                guard let stagedSelection = stagedByIdentity[selection.identity],
                      previousByIdentity[selection.identity] != stagedSelection
                else {
                    return nil
                }
                return MCPModelParameterSelectionStagingRollback.Change(
                    previousSelection: previousByIdentity[selection.identity],
                    stagedSelection: stagedSelection,
                    selectionRevision: session.acpModelParameterSelectionRevision(for: selection.identity)
                )
            }
        return MCPModelParameterSelectionStagingRollback(
            session: session,
            sessionID: session.activeAgentSessionID,
            persistentBinding: session.persistentSessionBindingIdentity,
            changes: changes
        )
    }

    func mcpRollbackStagedModelParameterSelections(
        _ rollback: MCPModelParameterSelectionStagingRollback
    ) {
        guard let currentSession = session(for: rollback.session.tabID, createIfNeeded: false),
              currentSession === rollback.session,
              currentSession.activeAgentSessionID == rollback.sessionID,
              currentSession.persistentSessionBindingIdentity == rollback.persistentBinding
        else {
            return
        }

        var restoredSelections = ACPModelParameterSelection.normalized(
            currentSession.acpModelParameterSelections
        )
        var didRestore = false
        for change in rollback.changes {
            guard currentSession.acpModelParameterSelectionRevision(
                for: change.stagedSelection.identity
            ) == change.selectionRevision,
                let index = restoredSelections.firstIndex(where: {
                    $0.identity == change.stagedSelection.identity
                }),
                restoredSelections[index] == change.stagedSelection
            else {
                continue
            }
            if let previousSelection = change.previousSelection {
                restoredSelections[index] = previousSelection
            } else {
                restoredSelections.remove(at: index)
            }
            didRestore = true
        }
        guard didRestore else { return }
        currentSession.acpModelParameterSelections = ACPModelParameterSelection.normalized(restoredSelections)
        currentSession.isDirty = true
        scheduleSave(for: currentSession)
        if currentSession.tabID == currentTabID {
            syncComposerUIState()
            syncRunInteractionUIState()
        }
    }

    func mcpApplyModelParameterSelections(
        tabID: UUID,
        selections: [ACPModelParameterSelection]
    ) throws {
        guard !selections.isEmpty else { return }
        guard let session = session(for: tabID, createIfNeeded: false) else {
            throw MCPError.internalError("Failed to resolve the Agent session for model parameter configuration.")
        }
        try mcpStoreModelParameterSelections(
            tabID: tabID,
            selectedAgent: session.selectedAgent,
            selectedModelRaw: session.selectedModelRaw,
            selections: selections,
            schedulePersistence: true
        )
    }

    func mcpValidateModelParameterSelections(
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        selections: [ACPModelParameterSelection]
    ) throws {
        guard !selections.isEmpty else { return }
        guard selectedAgent == .cursor else {
            throw MCPError.invalidParams("Cursor model parameters cannot be applied to \(selectedAgent.displayName).")
        }
        let selectedModelIdentity = ACPModelParameterIdentity.canonicalBaseModelRaw(
            selectedModelRaw,
            providerID: .cursor
        )
        guard selections.allSatisfy({
            $0.providerID == .cursor
                && ACPModelParameterIdentity.canonicalBaseModelRaw(
                    $0.baseModelRaw,
                    providerID: .cursor
                ) == selectedModelIdentity
        }) else {
            throw MCPError.invalidParams("Cursor model parameters do not match the configured base model.")
        }
    }

    private func mcpStoreModelParameterSelections(
        tabID: UUID,
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        selections: [ACPModelParameterSelection],
        schedulePersistence: Bool
    ) throws {
        guard let session = session(for: tabID, createIfNeeded: false) else {
            throw MCPError.internalError("Failed to resolve the Agent session for model parameter configuration.")
        }
        guard !session.runState.isActive else {
            throw MCPError.invalidParams("Cannot change model settings while this session is actively running.")
        }
        try mcpValidateModelParameterSelections(
            selectedAgent: selectedAgent, selectedModelRaw: selectedModelRaw, selections: selections
        )

        session.recordAcceptedACPModelParameterWrite(selections)
        let updatedSelections = ACPModelParameterSelection.normalized(
            session.acpModelParameterSelections + selections
        )
        guard updatedSelections != session.acpModelParameterSelections else { return }
        session.acpModelParameterSelections = updatedSelections
        session.isDirty = true
        if schedulePersistence {
            scheduleSave(for: tabID)
        }
        if tabID == currentTabID {
            syncComposerUIState()
            syncRunInteractionUIState()
        }
    }
}
