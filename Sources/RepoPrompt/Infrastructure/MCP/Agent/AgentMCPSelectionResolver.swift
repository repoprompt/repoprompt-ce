import Foundation
import MCP

// SEARCH-HELPER: model_id, compound identifier, task label, agent+model resolution, MCP parsing, global role defaults
// Related:
// - AgentModelSelectionID.swift (compound ID format)
// - AgentModelCatalog.swift (discovery/validation/task label recommendations)
// - MCPAgentRoleDefaultsService.swift (scoped role-default overrides)
// - AgentRunMCPToolService.swift / AgentManageMCPToolService.swift (consumers)

/// Resolves `model_id` into agent + model for session configuration.
///
/// Accepts two forms:
/// 1. **Task label**: `explore`, `engineer`, `pair`, `design` — auto-picks the effective role default
/// 2. **Compound ID**: `claudeCode:sonnet`, `codexExec:gpt-5.4-high` — explicit selection
enum AgentMCPSelectionResolver {
    typealias RoleSelectionProvider = @MainActor (
        _ role: AgentModelCatalog.TaskLabelKind,
        _ availability: AgentModelCatalog.AvailabilityContext
    ) -> AgentModelCatalog.NormalizedAgentSelection?

    struct ResolvedSelection {
        let agentRaw: String?
        let modelRaw: String?
        /// The resolved task label kind, if the selection was role-driven.
        /// `nil` when the model_id was a compound ID or no role was involved.
        let taskLabelKind: AgentModelCatalog.TaskLabelKind?
        /// The role's stored OpenCode effort pin captured *with* the role resolution, so a
        /// caller inherits a baseline without re-reading the profile after awaited setup. Empty
        /// for compound IDs and non-role selections.
        ///
        /// ⚠️ Every launch path that consumes a `ResolvedSelection` must also deliver this to the
        /// session before the run starts — via `mcpStageModelParameterSelections` (`agent_run`
        /// start, `agent_explore` start) or `mcpConfigureSession`/`mcpApplyModelParameterSelections`
        /// (`agent_manage` create/resume). Resolving it and forwarding only agent/model silently
        /// drops the user's choice and runs at the provider default; `agent_explore` shipped that
        /// bug. Capture it with the resolution — never re-read role settings after awaited setup.
        let modelParameterSelections: [ACPModelParameterSelection]
    }

    /// Resolves a `model_id` string into agent + model components.
    ///
    /// - If `modelID` is nil/empty and `defaultTaskLabel` is provided, resolves that role's effective default.
    /// - If `modelID` is nil/empty and no default is provided, returns nils (use agent defaults).
    /// - Task labels (`explore`, `engineer`, `pair`, `design`) resolve through effective role defaults.
    /// - Compound IDs are validated against the catalog and are never rewritten by role defaults.
    ///
    /// - Throws: `MCPError.invalidParams` for unrecognized or invalid IDs.
    @MainActor
    static func resolve(
        modelID: String?,
        defaultTaskLabel: AgentModelCatalog.TaskLabelKind? = nil,
        availability: AgentModelCatalog.AvailabilityContext = .current,
        workspaceID: UUID? = nil,
        roleSelectionProvider: RoleSelectionProvider? = nil,
        surface: AgentModelCatalog.AgentSelectionSurface = .general
    ) throws -> ResolvedSelection {
        let trimmed = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            // No explicit model_id — use default global role if provided
            if let defaultKind = defaultTaskLabel,
               let resolved = try resolveRoleSelection(defaultKind, availability: availability, workspaceID: workspaceID, roleSelectionProvider: roleSelectionProvider, surface: surface)
            {
                return ResolvedSelection(
                    agentRaw: resolved.selection.agent.rawValue,
                    modelRaw: resolved.selection.modelRaw,
                    taskLabelKind: defaultKind,
                    modelParameterSelections: resolved.modelParameters
                )
            }
            return ResolvedSelection(
                agentRaw: nil,
                modelRaw: nil,
                taskLabelKind: nil,
                modelParameterSelections: []
            )
        }

        // Try task label first (no colon = not a compound ID)
        if !trimmed.contains(":") {
            let lowered = trimmed.lowercased()
            if let entry = AgentModelCatalog.taskLabels.first(where: { $0.label == lowered }) {
                guard let resolved = try resolveRoleSelection(entry.kind, availability: availability, workspaceID: workspaceID, roleSelectionProvider: roleSelectionProvider, surface: surface) else {
                    throw MCPError.invalidParams("No available agent/model for task label '\(trimmed)'.")
                }
                return ResolvedSelection(
                    agentRaw: resolved.selection.agent.rawValue,
                    modelRaw: resolved.selection.modelRaw,
                    taskLabelKind: entry.kind,
                    modelParameterSelections: resolved.modelParameters
                )
            }
            let knownLabels = AgentModelCatalog.taskLabels.map(\.label).joined(separator: ", ")
            throw MCPError.invalidParams(
                "Unknown model_id '\(trimmed)'. Use a task label (\(knownLabels)) or a compound ID from agent_manage op=list_agents."
            )
        }

        // Parse compound ID
        guard let parsed = AgentModelSelectionID.parse(trimmed) else {
            throw MCPError.invalidParams(
                "Invalid model_id '\(trimmed)'. Use agent_manage op=list_agents to get valid model_id values."
            )
        }

        guard let agent = AgentProviderKind(rawValue: parsed.agentRaw) else {
            throw MCPError.invalidParams(
                "Unknown agent '\(parsed.agentRaw)' in model_id. Use agent_manage op=list_agents."
            )
        }

        guard surface.allows(agent) else {
            throw MCPError.invalidParams(
                "Agent '\(parsed.agentRaw)' is available only in interactive Agent Mode and cannot run headlessly."
            )
        }

        guard AgentModelCatalog.isAgentAvailable(agent, availability: availability) else {
            throw MCPError.invalidParams(
                "Agent '\(parsed.agentRaw)' is currently unavailable."
            )
        }

        // Codex is intentionally permissive for dynamic/stale model IDs
        if agent != .codexExec {
            guard AgentModelCatalog.isValid(rawModel: parsed.modelRaw, for: agent, availability: availability) else {
                throw MCPError.invalidParams(
                    "Model '\(parsed.modelRaw)' is not valid for agent '\(parsed.agentRaw)'. Use agent_manage op=list_agents."
                )
            }
        }

        return ResolvedSelection(
            agentRaw: parsed.agentRaw,
            modelRaw: parsed.modelRaw,
            taskLabelKind: nil,
            modelParameterSelections: []
        )
    }

    @MainActor
    private static func resolveRoleSelection(
        _ role: AgentModelCatalog.TaskLabelKind,
        availability: AgentModelCatalog.AvailabilityContext,
        workspaceID: UUID?,
        roleSelectionProvider: RoleSelectionProvider?,
        surface: AgentModelCatalog.AgentSelectionSurface
    ) throws -> (selection: AgentModelCatalog.NormalizedAgentSelection, modelParameters: [ACPModelParameterSelection])? {
        if let providerSelection = roleSelectionProvider?(role, availability) {
            guard surface.allows(providerSelection.agent) else {
                throw MCPError.invalidParams(
                    "Agent '\(providerSelection.agent.rawValue)' selected for role '\(role.rawValue)' is available only in interactive Agent Mode and cannot run headlessly. Choose a headless-capable model for this role in Agent Models settings or use interactive Agent Mode."
                )
            }
            return (providerSelection, [])
        }
        if let resolution = MCPAgentRoleDefaultsService.effectiveSelection(
            for: role,
            availability: availability,
            workspaceID: workspaceID
        ) {
            guard surface.allows(resolution.effective.agent) else {
                throw MCPError.invalidParams(
                    "Agent '\(resolution.effective.agent.rawValue)' selected for role '\(role.rawValue)' is available only in interactive Agent Mode and cannot run headlessly. Choose a headless-capable model for this role in Agent Models settings or use interactive Agent Mode."
                )
            }
            return (resolution.effective, resolution.modelParameters)
        }
        guard let fallback = AgentModelCatalog.resolveTaskLabelKind(role, availability: availability) else {
            return nil
        }
        guard surface.allows(fallback.agent) else {
            throw MCPError.invalidParams(
                "Agent '\(fallback.agent.rawValue)' selected for role '\(role.rawValue)' is available only in interactive Agent Mode and cannot run headlessly. Choose a headless-capable model for this role in Agent Models settings or use interactive Agent Mode."
            )
        }
        return (fallback, [])
    }
}
