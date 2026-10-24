import Foundation
import RepoPromptSettingsCore

/// Pre-allocation policy for ordinary, top-level sessions created by an overseer.
enum AgentSessionLanePolicy {
    static let agentSessionLaneMaximumCount = 12

    enum RoleResolutionError: Error, Equatable {
        case roleUnavailable
    }

    struct RoleSelection: Equatable {
        let role: AgentModelCatalog.TaskLabelKind
        let agentRaw: String
        let modelRaw: String
        let reasoningEffortRaw: String?
        let modelParameterSelections: [ACPModelParameterSelection]
    }

    static func resolveModel(
        _ modelID: String,
        availability: AgentModelCatalog.AvailabilityContext
    ) throws -> RoleSelection {
        let selection = try AgentAdvertisedModelCatalog.shared.selection(modelID, availability: availability)
        guard AgentModelCatalog.AgentSelectionSurface.headless.allows(selection.agent) else {
            throw AgentAdvertisedModelCatalog.AdmissionError.unavailable
        }
        // Default selection label only: lane creation consumes the model fields and creates
        // an ordinary top-level session, without installing an MCP task role or permissions.
        return RoleSelection(
            role: .pair, agentRaw: selection.agent.rawValue,
            modelRaw: selection.storedModelRaw, reasoningEffortRaw: selection.reasoningEffortRaw,
            modelParameterSelections: []
        )
    }

    @MainActor
    static func resolveRole(
        _ rawRole: String?,
        availability: AgentModelCatalog.AvailabilityContext,
        workspaceID: UUID,
        settingsStore: (any MCPAgentRoleDefaultsStoring)? = nil
    ) throws -> RoleSelection {
        let normalized = rawRole?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "pair"
        guard let role = AgentModelCatalog.TaskLabelKind(rawValue: normalized) else {
            throw RoleResolutionError.roleUnavailable
        }
        let effective: AgentModelCatalog.NormalizedAgentSelection
        let modelParameters: [ACPModelParameterSelection]
        if let resolution = MCPAgentRoleDefaultsService.effectiveSelection(
            for: role,
            availability: availability,
            workspaceID: workspaceID,
            settingsStore: settingsStore
        ) {
            guard !resolution.overrideUnavailable else { throw RoleResolutionError.roleUnavailable }
            effective = resolution.effective
            modelParameters = resolution.modelParameters
        } else {
            // A lane may use an executable explicit pin even when the role chain has no
            // recommendation. Do not synthesize a recommendation row or substitute a pin.
            let store = settingsStore ?? GlobalSettingsStore.shared
            guard let storedSelection = MCPAgentRoleDefaultsService.executableStoredSelection(
                for: role,
                overrides: store.mcpAgentRoleOverrides(workspaceID: workspaceID),
                roleModelParameters: store.mcpAgentRoleModelParameters(workspaceID: workspaceID),
                availability: availability
            ) else { throw RoleResolutionError.roleUnavailable }
            effective = storedSelection.selection
            modelParameters = storedSelection.modelParameters
        }
        guard AgentModelCatalog.AgentSelectionSurface.headless.allows(effective.agent),
              AgentModelCatalog.isValid(
                  rawModel: effective.modelRaw,
                  for: effective.agent,
                  availability: availability
              )
        else {
            throw RoleResolutionError.roleUnavailable
        }
        // Devin encodes thinking in its model ID, not in the native reasoning-effort field.
        let effort = effective.agent == .devin
            ? (model: effective.modelRaw, effort: nil)
            : AgentExternalMCPRunStarter.extractReasoningEffort(from: effective.modelRaw)
        return RoleSelection(
            role: role,
            agentRaw: effective.agent.rawValue,
            modelRaw: effort.model ?? effective.modelRaw,
            reasoningEffortRaw: effort.effort,
            modelParameterSelections: modelParameters
        )
    }
}
