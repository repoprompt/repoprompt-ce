import Combine
import Foundation
import RepoPromptDomainRuntime
import RepoPromptFoundation
import RepoPromptShared

// MARK: - Copy Global Settings (per workspace)

package struct CopyGlobalSettings: Codable {
    package var fileTreeOption: FileTreeOption
    package var codeMapUsage: CodeMapUsage
    package var gitInclusion: GitDiffInclusionMode
    package var workspaceID: UUID

    // --- NEW: snapshot of Manual mode (persisted per workspace) ---
    /// Manual mode's last-known settings (when Manual is not active).
    package var manualFileTreeOption: FileTreeOption? = nil
    package var manualCodeMapUsage: CodeMapUsage? = nil
    package var manualGitInclusion: GitDiffInclusionMode? = nil
    package var manualSelectedPromptIDs: Set<UUID>? = nil
    package var manualHasManualPromptSelection: Bool? = nil
    package var manualWorkingCopyCustomizations: CopyCustomizations? = nil
    /// Optional: remembers the last non-manual preset for UX (copy context).
    package var lastNonManualCopyPresetID: UUID? = nil

    package init(
        workspaceID: UUID,
        fileTreeOption: FileTreeOption = .auto,
        codeMapUsage: CodeMapUsage = .auto,
        gitInclusion: GitDiffInclusionMode = .none,
        manualFileTreeOption: FileTreeOption? = nil,
        manualCodeMapUsage: CodeMapUsage? = nil,
        manualGitInclusion: GitDiffInclusionMode? = nil,
        manualSelectedPromptIDs: Set<UUID>? = nil,
        manualHasManualPromptSelection: Bool? = nil,
        manualWorkingCopyCustomizations: CopyCustomizations? = nil,
        lastNonManualCopyPresetID: UUID? = nil
    ) {
        self.workspaceID = workspaceID
        self.fileTreeOption = fileTreeOption
        self.codeMapUsage = codeMapUsage
        self.gitInclusion = gitInclusion
        self.manualFileTreeOption = manualFileTreeOption
        self.manualCodeMapUsage = manualCodeMapUsage
        self.manualGitInclusion = manualGitInclusion
        self.manualSelectedPromptIDs = manualSelectedPromptIDs
        self.manualHasManualPromptSelection = manualHasManualPromptSelection
        self.manualWorkingCopyCustomizations = manualWorkingCopyCustomizations
        self.lastNonManualCopyPresetID = lastNonManualCopyPresetID
    }
}

// MARK: - Chat Global Settings (per workspace)

package struct ChatGlobalSettings: Codable, Equatable {
    package var fileTreeOption: FileTreeOption
    package var codeMapUsage: CodeMapUsage
    package var gitInclusion: GitDiffInclusionMode
    package var planActMode: SettingsPlanActMode
    package var proFileEdits: Bool
    package var workspaceID: UUID

    // --- NEW: snapshot of Manual mode (persisted per workspace) ---
    /// Manual mode's last-known chat settings (when Manual is not active).
    package var manualFileTreeOption: FileTreeOption? = nil
    package var manualCodeMapUsage: CodeMapUsage? = nil
    package var manualGitInclusion: GitDiffInclusionMode? = nil
    package var manualPlanActMode: SettingsPlanActMode? = nil
    package var manualProFileEdits: Bool? = nil
    package var manualSelectedPromptIDs: Set<UUID>? = nil
    package var manualHasManualPromptSelection: Bool? = nil
    /// NEW: remember last non-manual preset so UI can restore it later
    package var lastNonManualChatPresetID: UUID? = nil
    package var lastNonManualChatPresetName: String? = nil

    // MARK: - Legacy Context Builder State (decode compatibility only)

    package var lastUsedDiscoverAgentRaw: String? = nil
    /// Maps agent rawValue to last-used model rawValue for that agent
    package var lastUsedDiscoverModelsByAgent: [String: String]? = nil
    /// Legacy migration input only
    package var discoveryTokenBudget: Int? = nil
    /// Legacy migration input only
    package var discoveryEnhancementMode: String? = nil
    /// Legacy migration input only
    package var discoveryAutoGeneratePlan: Bool? = nil
    /// Legacy migration input only
    package var discoveryAllowClarifyingQuestions: Bool? = nil
    /// Legacy migration input only
    package var discoveryAllowClarifyingQuestionsForMCP: Bool? = nil
    /// Legacy migration input only
    package var discoveryQuestionTimeoutSeconds: TimeInterval? = nil
    /// Legacy migration input only
    package var discoveryPlanTokenBudget: Int? = nil

    // MARK: - Context Builder Model (workspace-scoped)

    package var contextBuilderModelRaw: String? = nil

    // MARK: - Legacy Context Builder Agent (decode compatibility only)

    /// Former workspace-scoped agent selection. Runtime selection is global.
    package var contextBuilderAgentRaw: String? = nil
    /// Former workspace-scoped model selection. Runtime selection is global.
    package var contextBuilderAgentModelRaw: String? = nil

    // MARK: - Recommendation Wizard (workspace-scoped)

    /// IDs of recommendations that have been dismissed/muted in this workspace.
    package var mutedRecommendationIDs: Set<String>? = nil
    /// Timestamp of the last time user completed/dismissed the recommendation wizard.
    package var lastRecommendationWizardCompletedAt: Date? = nil

    // MARK: - MCP Agent Role Default Overrides (legacy workspace-scoped)

    /// Legacy workspace-scoped role-default overrides.
    /// New code stores role defaults globally in GlobalDefaults.mcpAgentRoleOverrides and ignores this field
    /// after one-time migration. Kept for backwards compatibility and rollback safety.
    package var mcpAgentRoleOverrides: [String: String]? = nil

    // MARK: - Recommendation Bootstrap Tracking (workspace-scoped)

    /// Legacy workspace bootstrap marker retained for decoding compatibility.
    package var didUserSetDiscoverAgentDefaults: Bool? = nil
    /// Legacy workspace bootstrap marker retained for decoding compatibility.
    package var didUserSetContextBuilderDefaults: Bool? = nil
    /// Set when we auto-apply recommendations on workspace creation (for idempotency).
    package var didAutoApplyRecommendationsAt: Date? = nil

    package init(
        workspaceID: UUID,
        fileTreeOption: FileTreeOption = .auto,
        codeMapUsage: CodeMapUsage = .auto,
        gitInclusion: GitDiffInclusionMode = .none,
        planActMode: SettingsPlanActMode = .chat,
        proFileEdits: Bool = false,
        manualFileTreeOption: FileTreeOption? = nil,
        manualCodeMapUsage: CodeMapUsage? = nil,
        manualGitInclusion: GitDiffInclusionMode? = nil,
        manualPlanActMode: SettingsPlanActMode? = nil,
        manualProFileEdits: Bool? = nil,
        manualSelectedPromptIDs: Set<UUID>? = nil,
        manualHasManualPromptSelection: Bool? = nil,
        lastNonManualChatPresetID: UUID? = nil,
        lastNonManualChatPresetName: String? = nil,
        lastUsedDiscoverAgentRaw: String? = nil,
        lastUsedDiscoverModelsByAgent: [String: String]? = nil,
        discoveryTokenBudget: Int? = nil,
        discoveryEnhancementMode: String? = nil,
        discoveryAutoGeneratePlan: Bool? = nil,
        contextBuilderModelRaw: String? = nil,
        contextBuilderAgentRaw: String? = nil,
        contextBuilderAgentModelRaw: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.fileTreeOption = fileTreeOption
        self.codeMapUsage = codeMapUsage
        self.gitInclusion = gitInclusion
        self.planActMode = planActMode
        self.proFileEdits = proFileEdits
        self.manualFileTreeOption = manualFileTreeOption
        self.manualCodeMapUsage = manualCodeMapUsage
        self.manualGitInclusion = manualGitInclusion
        self.manualPlanActMode = manualPlanActMode
        self.manualProFileEdits = manualProFileEdits
        self.manualSelectedPromptIDs = manualSelectedPromptIDs
        self.manualHasManualPromptSelection = manualHasManualPromptSelection
        self.lastNonManualChatPresetID = lastNonManualChatPresetID
        self.lastNonManualChatPresetName = lastNonManualChatPresetName
        self.lastUsedDiscoverAgentRaw = lastUsedDiscoverAgentRaw
        self.lastUsedDiscoverModelsByAgent = lastUsedDiscoverModelsByAgent
        self.discoveryTokenBudget = discoveryTokenBudget
        self.discoveryEnhancementMode = discoveryEnhancementMode
        self.discoveryAutoGeneratePlan = discoveryAutoGeneratePlan
        self.contextBuilderModelRaw = contextBuilderModelRaw
        self.contextBuilderAgentRaw = contextBuilderAgentRaw
        self.contextBuilderAgentModelRaw = contextBuilderAgentModelRaw
    }
}

// MARK: - Global Defaults (cross-workspace seeding)

/// Stores the global Context Builder agent/model selection (single source of truth).
/// This is NOT per-workspace - it's the same across all workspaces.
/// Persisted field names still use the legacy discover-agent keys for compatibility.
package struct GlobalDefaults: Codable, Equatable {
    /// Global Context Builder agent selection (shared across all workspaces).
    package var discoverAgentRaw: String?
    /// Maps agent rawValue to last-used model rawValue for that agent (global)
    package var discoverModelsByAgent: [String: String]?
    package var discoveryTokenBudget: Int?
    package var discoveryEnhancementMode: String?
    /// Former preferred context-builder agent retained for decoding compatibility.
    package var contextBuilderAgentRaw: String?
    /// Schema version for recommendations (used to clear mutes on new best practices)
    package var recommendationSchemaVersion: Int?
    /// Schema version for discovery token budget (used to reset to new defaults)
    package var tokenBudgetSchemaVersion: Int?
    /// True when the user has explicitly set the global Context Builder agent/model.
    package var didUserSetDiscoverAgentDefaults: Bool?
    /// Global MCP Agent Mode role-default overrides (shared across all workspaces).
    /// Keys are TaskLabelKind rawValues, values are AgentModelSelectionID rawValues.
    package var mcpAgentRoleOverrides: [String: String]?
    /// OpenCode-style ACP parameter pins for the global role defaults. Keys are
    /// TaskLabelKind rawValues; values are model-scoped selections.
    package var mcpAgentRoleModelParameters: [String: [ACPModelParameterSelection]]?
    /// OpenCode-style ACP parameter pins for the global Context Builder agents.
    /// Keys are AgentProviderKind rawValues, mirroring `discoverModelsByAgent`.
    package var contextBuilderModelParametersByAgent: [String: [ACPModelParameterSelection]]?
    /// One-time migration version for legacy workspace-scoped MCP role overrides.
    package var mcpAgentRoleOverridesMigrationVersion: Int?
    /// Global provider filter used by recommendation generation. nil means all providers.
    package var recommendationProviderFilterRaw: [String]?
    /// Cross-workspace override that disables Code Maps without mutating per-workspace modes.
    package var codeMapsGloballyDisabled: Bool?
    /// Non-Git Code Maps require an explicit opt-in; missing legacy values remain disabled.
    package var nonGitCodeMapsEnabled: Bool?
    /// Global per-repository visual identities for Git worktrees.
    /// Stored as an additive optional field for schema-compatible rollout.
    package var worktreeVisualIdentitiesByRepositoryID: [String: WorktreeVisualIdentityRepositoryBucket]?

    package init(
        discoverAgentRaw: String? = nil,
        discoverModelsByAgent: [String: String]? = nil,
        discoveryTokenBudget: Int? = nil,
        discoveryEnhancementMode: String? = nil,
        contextBuilderAgentRaw: String? = nil,
        recommendationSchemaVersion: Int? = nil,
        tokenBudgetSchemaVersion: Int? = nil,
        didUserSetDiscoverAgentDefaults: Bool? = nil,
        mcpAgentRoleOverrides: [String: String]? = nil,
        mcpAgentRoleModelParameters: [String: [ACPModelParameterSelection]]? = nil,
        contextBuilderModelParametersByAgent: [String: [ACPModelParameterSelection]]? = nil,
        mcpAgentRoleOverridesMigrationVersion: Int? = nil,
        recommendationProviderFilterRaw: [String]? = nil,
        codeMapsGloballyDisabled: Bool? = nil,
        nonGitCodeMapsEnabled: Bool? = nil,
        worktreeVisualIdentitiesByRepositoryID: [String: WorktreeVisualIdentityRepositoryBucket]? = nil
    ) {
        self.discoverAgentRaw = discoverAgentRaw
        self.discoverModelsByAgent = discoverModelsByAgent
        self.discoveryTokenBudget = discoveryTokenBudget
        self.discoveryEnhancementMode = discoveryEnhancementMode
        self.contextBuilderAgentRaw = contextBuilderAgentRaw
        self.recommendationSchemaVersion = recommendationSchemaVersion
        self.tokenBudgetSchemaVersion = tokenBudgetSchemaVersion
        self.didUserSetDiscoverAgentDefaults = didUserSetDiscoverAgentDefaults
        self.mcpAgentRoleOverrides = mcpAgentRoleOverrides
        self.mcpAgentRoleModelParameters = mcpAgentRoleModelParameters
        self.contextBuilderModelParametersByAgent = contextBuilderModelParametersByAgent
        self.mcpAgentRoleOverridesMigrationVersion = mcpAgentRoleOverridesMigrationVersion
        self.recommendationProviderFilterRaw = recommendationProviderFilterRaw
        self.codeMapsGloballyDisabled = codeMapsGloballyDisabled
        self.nonGitCodeMapsEnabled = nonGitCodeMapsEnabled
        self.worktreeVisualIdentitiesByRepositoryID = worktreeVisualIdentitiesByRepositoryID
    }
}

// MARK: - Scalar Settings Snapshots

package struct FileSystemSettingsSnapshot: Equatable {
    package var respectRepoIgnore: Bool
    package var respectCursorignore: Bool
    package var globalIgnoreDefaults: String
    package var enableHierarchicalIgnores: Bool
    package var skipSymlinks: Bool
    package var showEmptyFolders: Bool

    package init(
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        globalIgnoreDefaults: String,
        enableHierarchicalIgnores: Bool,
        skipSymlinks: Bool,
        showEmptyFolders: Bool
    ) {
        self.respectRepoIgnore = respectRepoIgnore
        self.respectCursorignore = respectCursorignore
        self.globalIgnoreDefaults = globalIgnoreDefaults
        self.enableHierarchicalIgnores = enableHierarchicalIgnores
        self.skipSymlinks = skipSymlinks
        self.showEmptyFolders = showEmptyFolders
    }
}

/// In-memory diagnostics for settings writes that affect recommendation satisfaction.
/// Kept deliberately small and non-persistent so callers can inspect recent writes
/// during triage without changing app state or bloating the settings document.
package struct GlobalSettingsWriteDiagnostic: Equatable {
    package let timestamp: Date
    package let key: String
    package let oldValue: String?
    package let newValue: String?
    package let commit: Bool
    package let markUserDefined: Bool?
    package let reason: String
    package let caller: String

    package init(
        timestamp: Date,
        key: String,
        oldValue: String? = nil,
        newValue: String? = nil,
        commit: Bool,
        markUserDefined: Bool? = nil,
        reason: String,
        caller: String
    ) {
        self.timestamp = timestamp
        self.key = key
        self.oldValue = oldValue
        self.newValue = newValue
        self.commit = commit
        self.markUserDefined = markUserDefined
        self.reason = reason
        self.caller = caller
    }
}
