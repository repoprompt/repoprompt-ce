import Foundation
import RepoPromptSettingsCore

/// Pre-allocation policy for ordinary, top-level sessions created by an overseer.
enum AgentSessionLanePolicy {
    static let agentSessionLaneMaximumCount = 8

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
        guard let role = AgentModelCatalog.TaskLabelKind(rawValue: normalized),
              let resolution = MCPAgentRoleDefaultsService.effectiveSelection(
                  for: role,
                  availability: availability,
                  workspaceID: workspaceID,
                  settingsStore: settingsStore
              ),
              !resolution.overrideUnavailable,
              AgentModelCatalog.AgentSelectionSurface.headless.allows(resolution.effective.agent),
              AgentModelCatalog.isValid(
                  rawModel: resolution.effective.modelRaw,
                  for: resolution.effective.agent,
                  availability: availability
              )
        else {
            throw RoleResolutionError.roleUnavailable
        }
        let effort = AgentExternalMCPRunStarter.extractReasoningEffort(from: resolution.effective.modelRaw)
        return RoleSelection(
            role: role,
            agentRaw: resolution.effective.agent.rawValue,
            modelRaw: effort.model ?? resolution.effective.modelRaw,
            reasoningEffortRaw: effort.effort,
            modelParameterSelections: resolution.modelParameters
        )
    }
}
