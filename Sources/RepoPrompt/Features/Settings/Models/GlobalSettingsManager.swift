import Foundation

// MARK: - Canonical Settings Keys

//
// SEARCH-HELPER: SettingKeys, AppStorage keys, UserDefaults keys, settings dedupe
//
// Centralized UserDefaults key constants for keys that were previously
// written as string literals across multiple `@AppStorage` declarations in
// `Views/Settings/`. Views that touch these keys should reference the
// constants below so renames stay safe and duplicate keys are easy to audit.
//
// Not every key in the app lives here — just the ones that appear in
// multiple settings views. Single-site keys can stay as inline literals.
enum SettingKeys {
    /// Master toggle for all global keyboard shortcuts.
    /// Referenced by Advanced Settings and Keyboard Shortcuts settings.
    static let enableKeyboardShortcuts = "enableKeyboardShortcuts"

    /// Serialized `AppearanceMode` raw value (`system` / `light` / `dark`).
    /// Persisted once; re-read by AppearanceController and any appearance picker.
    static let appearanceMode = "appearanceMode"

    /// Whether to collapse the latest-file-changes panel by default.
    static let collapseLatestFileChanges = "collapseLatestFileChanges"

    /// Whether hover tooltips are shown globally.
    static let showTooltips = "showTooltips"

    /// Whether the MCP Oracle UI exposes the Model Presets affordance.
    /// Referenced by ChatSettingsView, MCPSettingsView, and the inline MCP toggle.
    static let mcpShowModelPresets = "mcpShowModelPresets"

    /// App-wide UI font scale preset body size.
    static let fontPresetBodySize = "fontPresetBodySize"
}

extension Notification.Name {
    /// Posted after app-wide file-system/ignore preferences are changed through
    /// the settings surface. `userInfo["key"]` contains the app_settings key.
    static let appSettingsFileSystemPreferencesDidChange = Notification.Name("RepoPromptAppSettingsFileSystemPreferencesDidChange")
}

// MARK: - Copy Global Settings (per workspace)

struct CopyGlobalSettings: Codable {
    var fileTreeOption: FileTreeOption
    var codeMapUsage: CodeMapUsage
    var gitInclusion: GitDiffInclusionMode
    var workspaceID: UUID

    // --- NEW: snapshot of Manual mode (persisted per workspace) ---
    /// Manual mode's last-known settings (when Manual is not active).
    var manualFileTreeOption: FileTreeOption? = nil
    var manualCodeMapUsage: CodeMapUsage? = nil
    var manualGitInclusion: GitDiffInclusionMode? = nil
    var manualSelectedPromptIDs: Set<UUID>? = nil
    var manualHasManualPromptSelection: Bool? = nil
    var manualWorkingCopyCustomizations: CopyCustomizations? = nil
    /// Optional: remembers the last non-manual preset for UX (copy context).
    var lastNonManualCopyPresetID: UUID? = nil

    init(
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

struct ChatGlobalSettings: Codable {
    var fileTreeOption: FileTreeOption
    var codeMapUsage: CodeMapUsage
    var gitInclusion: GitDiffInclusionMode
    var planActMode: PromptViewModel.PlanActMode
    var proFileEdits: Bool
    var workspaceID: UUID

    // --- NEW: snapshot of Manual mode (persisted per workspace) ---
    /// Manual mode's last-known chat settings (when Manual is not active).
    var manualFileTreeOption: FileTreeOption? = nil
    var manualCodeMapUsage: CodeMapUsage? = nil
    var manualGitInclusion: GitDiffInclusionMode? = nil
    var manualPlanActMode: PromptViewModel.PlanActMode? = nil
    var manualProFileEdits: Bool? = nil
    var manualSelectedPromptIDs: Set<UUID>? = nil
    var manualHasManualPromptSelection: Bool? = nil
    /// NEW: remember last non-manual preset so UI can restore it later
    var lastNonManualChatPresetID: UUID? = nil
    var lastNonManualChatPresetName: String? = nil

    // MARK: - Legacy Context Builder Agent & Model (workspace-scoped)

    var lastUsedDiscoverAgentRaw: String? = nil
    /// Maps agent rawValue to last-used model rawValue for that agent
    var lastUsedDiscoverModelsByAgent: [String: String]? = nil
    /// Discovery token budget (workspace-scoped)
    var discoveryTokenBudget: Int? = nil
    /// Discovery prompt enhancement mode (workspace-scoped) - stores raw value of PromptEnhancementMode enum
    var discoveryEnhancementMode: String? = nil
    /// Default auto-plan setting for new/unstored tabs (workspace-scoped fallback).
    /// Per-tab values live in ComposeTabState.contextBuilder.autoGeneratePlan.
    var discoveryAutoGeneratePlan: Bool? = nil
    /// Allow Context Builder to ask clarifying questions mid-run (workspace-scoped, UI-triggered)
    var discoveryAllowClarifyingQuestions: Bool? = nil
    /// Allow clarifying questions when discovery is triggered via MCP context_builder (workspace-scoped, defaults false)
    var discoveryAllowClarifyingQuestionsForMCP: Bool? = nil
    /// Timeout (in seconds) for clarifying question responses (workspace-scoped, defaults to 300)
    var discoveryQuestionTimeoutSeconds: TimeInterval? = nil
    /// Token budget for plan generation (workspace-scoped, defaults to 80k)
    var discoveryPlanTokenBudget: Int? = nil

    // MARK: - Context Builder Model (workspace-scoped)

    var contextBuilderModelRaw: String? = nil

    // MARK: - Context Builder Agent (workspace-scoped)

    /// Preferred agent for context-builder / discover workflows (claudeCode, codexExec, openCode)
    var contextBuilderAgentRaw: String? = nil
    /// Preferred model for context-builder agent (per agent's supported list)
    var contextBuilderAgentModelRaw: String? = nil

    // MARK: - Recommendation Wizard (workspace-scoped)

    /// IDs of recommendations that have been dismissed/muted in this workspace.
    var mutedRecommendationIDs: Set<String>? = nil
    /// Timestamp of the last time user completed/dismissed the recommendation wizard.
    var lastRecommendationWizardCompletedAt: Date? = nil

    // MARK: - MCP Agent Role Default Overrides (legacy workspace-scoped)

    /// Legacy workspace-scoped role-default overrides.
    /// New code stores role defaults globally in GlobalDefaults.mcpAgentRoleOverrides and ignores this field
    /// after one-time migration. Kept for backwards compatibility and rollback safety.
    var mcpAgentRoleOverrides: [String: String]? = nil

    // MARK: - Recommendation Bootstrap Tracking (workspace-scoped)

    /// True when the user explicitly changed Context Builder agent/model defaults.
    /// nil => legacy workspace (treat as user-defined to avoid auto changes)
    var didUserSetDiscoverAgentDefaults: Bool? = nil
    /// True when the user explicitly changed context-builder agent/model defaults.
    /// nil => legacy workspace (treat as user-defined to avoid auto changes)
    var didUserSetContextBuilderDefaults: Bool? = nil
    /// Set when we auto-apply recommendations on workspace creation (for idempotency).
    var didAutoApplyRecommendationsAt: Date? = nil

    init(
        workspaceID: UUID,
        fileTreeOption: FileTreeOption = .auto,
        codeMapUsage: CodeMapUsage = .auto,
        gitInclusion: GitDiffInclusionMode = .none,
        planActMode: PromptViewModel.PlanActMode = .chat,
        proFileEdits: Bool = false,
        manualFileTreeOption: FileTreeOption? = nil,
        manualCodeMapUsage: CodeMapUsage? = nil,
        manualGitInclusion: GitDiffInclusionMode? = nil,
        manualPlanActMode: PromptViewModel.PlanActMode? = nil,
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
struct GlobalDefaults: Codable {
    /// Global Context Builder agent selection (shared across all workspaces).
    var discoverAgentRaw: String?
    /// Maps agent rawValue to last-used model rawValue for that agent (global)
    var discoverModelsByAgent: [String: String]?
    var discoveryTokenBudget: Int?
    var discoveryEnhancementMode: String?
    /// Legacy preferred context-builder agent (seeds new workspaces).
    var contextBuilderAgentRaw: String?
    /// Schema version for recommendations (used to clear mutes on new best practices)
    var recommendationSchemaVersion: Int?
    /// Schema version for discovery token budget (used to reset to new defaults)
    var tokenBudgetSchemaVersion: Int?
    /// True when the user has explicitly set the global Context Builder agent/model.
    var didUserSetDiscoverAgentDefaults: Bool?
    /// Global MCP Agent Mode role-default overrides (shared across all workspaces).
    /// Keys are TaskLabelKind rawValues, values are AgentModelSelectionID rawValues.
    var mcpAgentRoleOverrides: [String: String]?
    /// One-time migration version for legacy workspace-scoped MCP role overrides.
    var mcpAgentRoleOverridesMigrationVersion: Int?
    /// Global provider filter used by recommendation generation. nil means all providers.
    var recommendationProviderFilterRaw: [String]?
    /// Cross-workspace override that disables Code Maps without mutating per-workspace modes.
    var codeMapsGloballyDisabled: Bool?
    /// Global per-repository visual identities for Git worktrees.
    /// Stored as an additive optional field for schema-compatible rollout.
    var worktreeVisualIdentitiesByRepositoryID: [String: WorktreeVisualIdentityRepositoryBucket]?
}

// MARK: - Scalar Settings Snapshots

struct FileSystemSettingsSnapshot: Equatable {
    var respectRepoIgnore: Bool
    var respectCursorignore: Bool
    var globalIgnoreDefaults: String
    var enableHierarchicalIgnores: Bool
    var skipSymlinks: Bool
    var showEmptyFolders: Bool
}

/// In-memory diagnostics for settings writes that affect recommendation satisfaction.
/// Kept deliberately small and non-persistent so callers can inspect recent writes
/// during triage without changing app state or bloating the settings document.
struct GlobalSettingsWriteDiagnostic: Equatable {
    let timestamp: Date
    let key: String
    let oldValue: String?
    let newValue: String?
    let commit: Bool
    let markUserDefined: Bool?
    let reason: String
    let caller: String
}

// MARK: - Global Settings Store (Persistent)

/// This is the single source of truth for workspace default settings.
/// Primary persistence is the Application Support JSON document at
/// `~/Library/Application Support/RepoPrompt CE/Settings/globalSettings.json`.
/// Windows use WindowSettingsManager to maintain local overlays.
@MainActor
class GlobalSettingsStore: ObservableObject {
    static let shared = GlobalSettingsStore()

    private let defaults: UserDefaults
    private let fileStore: GlobalSettingsFileStoring

    @Published private(set) var copySettings: [UUID: CopyGlobalSettings] = [:]
    @Published private(set) var chatSettings: [UUID: ChatGlobalSettings] = [:]
    @Published private(set) var codeMapsGloballyDisabled: Bool = false
    private var globalDefaults = GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil)
    private var scalarPreferences = GlobalScalarPreferences()

    private static let defaultBackgroundAgentComposeTabHardLimit = 500
    private static let defaultComposeTabSoftLimit = 50
    private static let defaultAppearanceModeRaw = "System"
    private static let defaultFilePathDisplayOptionRaw = "Full"
    private static let defaultSelectedFilesSortMethodRaw = "nameAscending"
    private static let defaultFileEditFormatRaw = "Diff"
    private static let defaultComplexEditStrategyRaw = "Sequential split"
    private static let settingsWriteDiagnosticsLimit = 80

    private var settingsWriteDiagnostics: [GlobalSettingsWriteDiagnostic] = []

    init(
        defaults: UserDefaults = .standard,
        fileStore: GlobalSettingsFileStoring = GlobalSettingsFileStore()
    ) {
        self.defaults = defaults
        self.fileStore = fileStore
        load()
        ensureFileSystemGlobalIgnoreDefaultsSeeded()
    }

    func recentSettingsWriteDiagnostics() -> [GlobalSettingsWriteDiagnostic] {
        settingsWriteDiagnostics
    }

    private func recordSettingsWriteDiagnostic(
        key: String,
        oldValue: String?,
        newValue: String?,
        commit: Bool,
        markUserDefined: Bool? = nil,
        reason: String?,
        fileID: StaticString,
        line: UInt,
        function: StaticString
    ) {
        let fallbackReason = "\(function)"
        let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnostic = GlobalSettingsWriteDiagnostic(
            timestamp: Date(),
            key: key,
            oldValue: oldValue,
            newValue: newValue,
            commit: commit,
            markUserDefined: markUserDefined,
            reason: trimmedReason?.isEmpty == false ? trimmedReason! : fallbackReason,
            caller: "\(fileID):\(line) \(function)"
        )
        settingsWriteDiagnostics.append(diagnostic)
        if settingsWriteDiagnostics.count > Self.settingsWriteDiagnosticsLimit {
            settingsWriteDiagnostics.removeFirst(settingsWriteDiagnostics.count - Self.settingsWriteDiagnosticsLimit)
        }
    }

    // MARK: - Access Methods

    func copySettings(for workspaceID: UUID) -> CopyGlobalSettings {
        if let existing = copySettings[workspaceID] {
            return existing
        }
        // Create default settings for new workspace
        let newSettings = CopyGlobalSettings(workspaceID: workspaceID)
        copySettings[workspaceID] = newSettings
        save()
        return newSettings
    }

    func chatSettings(for workspaceID: UUID) -> ChatGlobalSettings {
        chatSettingsResult(for: workspaceID).settings
    }

    /// Returns chat settings for a workspace, along with whether they were newly created.
    /// Use this when you need to know if this is a brand new workspace (for auto-apply).
    func chatSettingsResult(for workspaceID: UUID) -> (settings: ChatGlobalSettings, isNew: Bool) {
        if let existing = chatSettings[workspaceID] {
            return (existing, false)
        }
        // Create default settings for new workspace
        var newSettings = ChatGlobalSettings(workspaceID: workspaceID)
        seedChatSettingsDefaults(&newSettings)
        chatSettings[workspaceID] = newSettings
        save()
        return (newSettings, true)
    }

    func updateCopySettings(_ settings: CopyGlobalSettings) {
        copySettings[settings.workspaceID] = settings
        save()
    }

    func updateCopySettings(_ settings: CopyGlobalSettings, commit: Bool) {
        copySettings[settings.workspaceID] = settings
        if commit {
            save()
        }
    }

    func updateChatSettings(_ settings: ChatGlobalSettings) {
        chatSettings[settings.workspaceID] = settings
        // NOTE: We no longer sync workspace Context Builder agent/model to global defaults here.
        // Global Context Builder settings are now the single source of truth, updated only via
        // setGlobalContextBuilderAgentSelection() when the user explicitly changes them.
        save()
    }

    func updateChatSettings(_ settings: ChatGlobalSettings, commit: Bool) {
        chatSettings[settings.workspaceID] = settings
        // NOTE: We no longer sync workspace Context Builder agent/model to global defaults here.
        // Global Context Builder settings are now the single source of truth.
        if commit {
            save()
        }
    }

    // MARK: - Scalar Preferences

    func appearanceModeRaw() -> String {
        scalarPreferences.ui?.appearanceMode ?? Self.defaultAppearanceModeRaw
    }

    func setAppearanceModeRaw(_ raw: String, commit: Bool = true) {
        updateUIScalar(commit: commit) { settings in
            settings.appearanceMode = raw
        }
    }

    func useTransparency() -> Bool {
        scalarPreferences.ui?.useTransparency ?? true
    }

    func setUseTransparency(_ enabled: Bool, commit: Bool = true) {
        updateUIScalar(commit: commit) { settings in
            settings.useTransparency = enabled
        }
    }

    func collapseLatestFileChanges() -> Bool {
        scalarPreferences.ui?.collapseLatestFileChanges ?? false
    }

    func setCollapseLatestFileChanges(_ enabled: Bool, commit: Bool = true) {
        updateUIScalar(commit: commit) { settings in
            settings.collapseLatestFileChanges = enabled
        }
    }

    func showTooltips() -> Bool {
        scalarPreferences.ui?.showTooltips ?? true
    }

    func setShowTooltips(_ enabled: Bool, commit: Bool = true) {
        updateUIScalar(commit: commit) { settings in
            settings.showTooltips = enabled
        }
    }

    func showDatesInMessageTimestamps() -> Bool {
        scalarPreferences.ui?.showDatesInMessageTimestamps ?? false
    }

    func setShowDatesInMessageTimestamps(_ enabled: Bool, commit: Bool = true) {
        updateUIScalar(commit: commit) { settings in
            settings.showDatesInMessageTimestamps = enabled
        }
    }

    func experimentalAttributedTextEditor() -> Bool {
        scalarPreferences.ui?.experimentalAttributedTextEditor ?? false
    }

    func setExperimentalAttributedTextEditor(_ enabled: Bool, commit: Bool = true) {
        updateUIScalar(commit: commit) { settings in
            settings.experimentalAttributedTextEditor = enabled
        }
    }

    func fileMentionPickerStyle() -> FileMentionPickerStyle {
        FileMentionPickerStyle.normalized(rawValue: scalarPreferences.ui?.fileMentionPickerStyle)
    }

    func fileMentionPickerConfiguration() -> FileMentionPickerConfiguration {
        fileMentionPickerStyle().configuration
    }

    func setFileMentionPickerStyle(_ style: FileMentionPickerStyle, commit: Bool = true) {
        updateUIScalar(commit: commit) { settings in
            settings.fileMentionPickerStyle = style.rawValue
        }
    }

    func enableKeyboardShortcuts() -> Bool {
        scalarPreferences.ui?.enableKeyboardShortcuts ?? true
    }

    func setEnableKeyboardShortcuts(_ enabled: Bool, commit: Bool = true) {
        updateUIScalar(commit: commit) { settings in
            settings.enableKeyboardShortcuts = enabled
        }
    }

    func fontScaleBodySize() -> Double {
        guard let rawValue = scalarPreferences.ui?.fontScaleBodySize,
              let preset = FontScalePreset(rawValue: rawValue)
        else {
            return FontScalePreset.normal.rawValue
        }
        return preset.rawValue
    }

    func setFontScaleBodySize(_ rawValue: Double, commit: Bool = true) {
        let normalized = FontScalePreset(rawValue: rawValue)?.rawValue ?? FontScalePreset.normal.rawValue
        updateUIScalar(commit: commit) { settings in
            settings.fontScaleBodySize = normalized
        }
    }

    func reloadFontScaleBodySizeFromDisk() -> Double? {
        do {
            let document = try fileStore.load()
            guard let diskRawValue = document.scalarPreferences?.ui?.fontScaleBodySize else {
                return nil
            }
            let normalized = FontScalePreset(rawValue: diskRawValue)?.rawValue ?? FontScalePreset.normal.rawValue
            var preferences = scalarPreferences
            var uiSettings = preferences.ui ?? GlobalScalarPreferences.UISettings()
            uiSettings.fontScaleBodySize = normalized
            preferences.ui = uiSettings
            guard preferences != scalarPreferences else {
                return normalized
            }

            objectWillChange.send()
            scalarPreferences = preferences
            return normalized
        } catch {
            print("⚠️ Failed to reload font scale from global settings JSON at \(fileStore.fileURL.path): \(error)")
            return nil
        }
    }

    func promptSectionsOrderRaw() -> String {
        scalarPreferences.promptPackaging?.promptSectionsOrder ?? ""
    }

    func setPromptSectionsOrderRaw(_ raw: String, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.promptSectionsOrder = raw
        }
    }

    func duplicateUserInstructionsAtTop() -> Bool {
        scalarPreferences.promptPackaging?.duplicateUserInstructionsAtTop ?? false
    }

    func setDuplicateUserInstructionsAtTop(_ enabled: Bool, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.duplicateUserInstructionsAtTop = enabled
        }
    }

    func filePathDisplayOptionRaw() -> String {
        scalarPreferences.promptPackaging?.filePathDisplayOption ?? Self.defaultFilePathDisplayOptionRaw
    }

    func setFilePathDisplayOptionRaw(_ raw: String, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.filePathDisplayOption = raw
        }
    }

    func selectedFilesSortMethodRaw() -> String {
        scalarPreferences.promptPackaging?.selectedFilesSortMethod ?? Self.defaultSelectedFilesSortMethodRaw
    }

    func setSelectedFilesSortMethodRaw(_ raw: String, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.selectedFilesSortMethod = raw
        }
    }

    func fileEditFormatRaw() -> String {
        scalarPreferences.promptPackaging?.fileEditFormat ?? Self.defaultFileEditFormatRaw
    }

    func setFileEditFormatRaw(_ raw: String, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.fileEditFormat = raw
        }
    }

    func includeDatetimeInUserInstructions() -> Bool {
        scalarPreferences.promptPackaging?.includeDatetimeInUserInstructions ?? false
    }

    func setIncludeDatetimeInUserInstructions(_ enabled: Bool, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.includeDatetimeInUserInstructions = enabled
        }
    }

    func customPlanningPrompt() -> String {
        scalarPreferences.promptPackaging?.customPlanningPrompt ?? ""
    }

    func setCustomPlanningPrompt(_ prompt: String, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.customPlanningPrompt = prompt
        }
    }

    func modelTemperature() -> Double {
        scalarPreferences.promptPackaging?.modelTemperature ?? 0.0
    }

    func setModelTemperature(_ temperature: Double, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.modelTemperature = temperature
        }
    }

    func shouldSetModelTemperature() -> Bool {
        scalarPreferences.promptPackaging?.setModelTemperature ?? true
    }

    func setShouldSetModelTemperature(_ enabled: Bool, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.setModelTemperature = enabled
        }
    }

    func complexEditStrategyRaw() -> String {
        scalarPreferences.promptPackaging?.complexEditStrategy ?? Self.defaultComplexEditStrategyRaw
    }

    func setComplexEditStrategyRaw(_ raw: String, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.complexEditStrategy = raw
        }
    }

    func preferredComposeModelRaw() -> String? {
        scalarPreferences.modelSelection?.preferredComposeModel
    }

    func setPreferredComposeModelRaw(
        _ raw: String?,
        commit: Bool = true,
        reason: String? = nil,
        honorSync: Bool = false,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        let oldPreferred = scalarPreferences.modelSelection?.preferredComposeModel
        let oldPlanning = scalarPreferences.modelSelection?.planningModel
        let shouldMirror = honorSync && resolvedSyncChatModelWithOracleFromCurrentPreferences()
        // Never let a blank chat model blank the Oracle. An empty/nil preferred value is
        // produced by transient fallbacks (e.g. PromptViewModel.pickDiffCapableFallback when
        // the model list is unhydrated); mirroring it would wipe the global Oracle planningModel
        // — which is deliberately never auto-healed — and persist the blank across relaunch.
        // Only mirror real model selections; the chat model can re-heal itself, the Oracle cannot.
        // Treat whitespace-only as blank too — these raw values can arrive from the MCP/app_settings
        // API, not just picker-backed AIModel.rawValue.
        let shouldMirrorModel = shouldMirror && (raw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        updateModelSelectionScalar(commit: commit) { settings in
            settings.preferredComposeModel = raw
            if shouldMirrorModel {
                settings.planningModel = raw
            }
        }
        recordSettingsWriteDiagnostic(
            key: "preferredComposeModelRaw",
            oldValue: oldPreferred,
            newValue: raw,
            commit: commit,
            reason: reason,
            fileID: fileID,
            line: line,
            function: function
        )
        if shouldMirrorModel, oldPlanning != raw {
            recordSettingsWriteDiagnostic(
                key: "planningModelRaw",
                oldValue: oldPlanning,
                newValue: raw,
                commit: commit,
                reason: syncSiblingReason(from: reason),
                fileID: fileID,
                line: line,
                function: function
            )
        }
    }

    func planningModelRaw() -> String? {
        scalarPreferences.modelSelection?.planningModel
    }

    func setPlanningModelRaw(
        _ raw: String?,
        commit: Bool = true,
        reason: String? = nil,
        honorSync: Bool = false,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        let oldPlanning = scalarPreferences.modelSelection?.planningModel
        let oldPreferred = scalarPreferences.modelSelection?.preferredComposeModel
        let shouldMirror = honorSync && resolvedSyncChatModelWithOracleFromCurrentPreferences()
        updateModelSelectionScalar(commit: commit) { settings in
            settings.planningModel = raw
            if shouldMirror {
                settings.preferredComposeModel = raw
            }
        }
        recordSettingsWriteDiagnostic(
            key: "planningModelRaw",
            oldValue: oldPlanning,
            newValue: raw,
            commit: commit,
            reason: reason,
            fileID: fileID,
            line: line,
            function: function
        )
        if shouldMirror, oldPreferred != raw {
            recordSettingsWriteDiagnostic(
                key: "preferredComposeModelRaw",
                oldValue: oldPreferred,
                newValue: raw,
                commit: commit,
                reason: syncSiblingReason(from: reason),
                fileID: fileID,
                line: line,
                function: function
            )
        }
    }

    func syncChatModelWithOracle() -> Bool {
        resolvedSyncChatModelWithOracleFromCurrentPreferences()
    }

    func setSyncChatModelWithOracle(
        _ enabled: Bool,
        commit: Bool = true,
        reason: String? = nil,
        snapOnEnableToPlanning: Bool = false,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        let oldStoredValue = scalarPreferences.modelSelection?.syncChatModelWithOracle.map(String.init)
        let oldPreferred = scalarPreferences.modelSelection?.preferredComposeModel
        let planning = scalarPreferences.modelSelection?.planningModel ?? ""
        let shouldSnap = enabled && snapOnEnableToPlanning && !planning.isEmpty && planning != oldPreferred
        updateModelSelectionScalar(commit: commit) { settings in
            settings.syncChatModelWithOracle = enabled
            if shouldSnap {
                settings.preferredComposeModel = planning
            }
        }
        recordSettingsWriteDiagnostic(
            key: "syncChatModelWithOracle",
            oldValue: oldStoredValue,
            newValue: String(enabled),
            commit: commit,
            reason: reason,
            fileID: fileID,
            line: line,
            function: function
        )
        if shouldSnap {
            recordSettingsWriteDiagnostic(
                key: "preferredComposeModelRaw",
                oldValue: oldPreferred,
                newValue: planning,
                commit: commit,
                reason: syncSnapReason(from: reason),
                fileID: fileID,
                line: line,
                function: function
            )
        }
    }

    func mcpAutoStart() -> Bool {
        scalarPreferences.mcp?.autoStart ?? false
    }

    func setMCPAutoStart(_ enabled: Bool, commit: Bool = true) {
        updateMCPScalar(commit: commit) { settings in
            settings.autoStart = enabled
        }
    }

    func mcpShowModelPresets() -> Bool {
        scalarPreferences.mcp?.showModelPresets ?? false
    }

    func setMCPShowModelPresets(_ enabled: Bool, commit: Bool = true) {
        updateMCPScalar(commit: commit) { settings in
            settings.showModelPresets = enabled
        }
    }

    func mcpTemporarilyDisablePresets() -> Bool {
        scalarPreferences.mcp?.temporarilyDisablePresets ?? false
    }

    func setMCPTemporarilyDisablePresets(_ enabled: Bool, commit: Bool = true) {
        updateMCPScalar(commit: commit) { settings in
            settings.temporarilyDisablePresets = enabled
        }
    }

    func respectRepoIgnore() -> Bool {
        scalarPreferences.fileSystem?.respectRepoIgnore ?? true
    }

    func setRespectRepoIgnore(_ enabled: Bool, commit: Bool = true) {
        updateFileSystemScalar(commit: commit) { settings in
            settings.respectRepoIgnore = enabled
        }
    }

    func respectCursorignore() -> Bool {
        scalarPreferences.fileSystem?.respectCursorignore ?? true
    }

    func setRespectCursorignore(_ enabled: Bool, commit: Bool = true) {
        updateFileSystemScalar(commit: commit) { settings in
            settings.respectCursorignore = enabled
        }
    }

    func globalIgnoreDefaults() -> String {
        if let stored = scalarPreferences.fileSystem?.globalIgnoreDefaults {
            return stored
        }
        return IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults
    }

    func setGlobalIgnoreDefaults(_ content: String, commit: Bool = true) {
        updateFileSystemScalar(commit: commit) { settings in
            settings.globalIgnoreDefaults = content
        }
    }

    func enableHierarchicalIgnores() -> Bool {
        scalarPreferences.fileSystem?.enableHierarchicalIgnores ?? true
    }

    func setEnableHierarchicalIgnores(_ enabled: Bool, commit: Bool = true) {
        updateFileSystemScalar(commit: commit) { settings in
            settings.enableHierarchicalIgnores = enabled
        }
    }

    func skipSymlinks() -> Bool {
        scalarPreferences.fileSystem?.skipSymlinks ?? true
    }

    func setSkipSymlinks(_ enabled: Bool, commit: Bool = true) {
        updateFileSystemScalar(commit: commit) { settings in
            settings.skipSymlinks = enabled
        }
    }

    func showEmptyFolders() -> Bool {
        scalarPreferences.fileSystem?.showEmptyFolders ?? false
    }

    func fileSystemSettingsSnapshot() -> FileSystemSettingsSnapshot {
        let settings = scalarPreferences.fileSystem
        return FileSystemSettingsSnapshot(
            respectRepoIgnore: settings?.respectRepoIgnore ?? true,
            respectCursorignore: settings?.respectCursorignore ?? true,
            globalIgnoreDefaults: settings?.globalIgnoreDefaults ?? IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults,
            enableHierarchicalIgnores: settings?.enableHierarchicalIgnores ?? true,
            skipSymlinks: settings?.skipSymlinks ?? true,
            showEmptyFolders: settings?.showEmptyFolders ?? false
        )
    }

    func setShowEmptyFolders(_ enabled: Bool, commit: Bool = true) {
        updateFileSystemScalar(commit: commit) { settings in
            settings.showEmptyFolders = enabled
        }
    }

    func postFileSystemPreferencesDidChange(
        key: String,
        notificationCenter: NotificationCenter = .default
    ) {
        notificationCenter.post(
            name: .appSettingsFileSystemPreferencesDidChange,
            object: nil,
            userInfo: ["key": key]
        )
    }

    func maxBackgroundAgentComposeTabs() -> Int {
        let configuredLimit = scalarPreferences.agentMode?.maxBackgroundAgentComposeTabs ?? Self.defaultBackgroundAgentComposeTabHardLimit
        let rawLimit = configuredLimit > 0 ? configuredLimit : Self.defaultBackgroundAgentComposeTabHardLimit
        return max(Self.defaultComposeTabSoftLimit, rawLimit)
    }

    func setMaxBackgroundAgentComposeTabs(_ limit: Int?, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { settings in
            settings.maxBackgroundAgentComposeTabs = limit
        }
    }

    func showBuiltInWorkflowCleanupGuidance() -> Bool {
        scalarPreferences.agentMode?.showBuiltInWorkflowCleanupGuidance ?? true
    }

    func setShowBuiltInWorkflowCleanupGuidance(_ enabled: Bool, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { settings in
            settings.showBuiltInWorkflowCleanupGuidance = enabled
        }
    }

    func codexGoalSupportEnabled() -> Bool {
        CodexGoalSupport.isEnabled(persistedValue: scalarPreferences.agentMode?.codexGoalSupportEnabled)
    }

    func setCodexGoalSupportEnabled(_ enabled: Bool, commit: Bool = true) {
        let oldValue = codexGoalSupportEnabled()
        updateAgentModeScalar(commit: commit) { settings in
            settings.codexGoalSupportEnabled = enabled
        }
        CodexGoalSupport.postDidChangeIfNeeded(previousValue: oldValue, currentValue: codexGoalSupportEnabled())
    }

    #if DEBUG
        func claudeRawEventLoggingEnabled() -> Bool {
            defaults.bool(forKey: "claudeRawEventLoggingEnabled")
        }

        func setClaudeRawEventLoggingEnabled(_ enabled: Bool) {
            defaults.set(enabled, forKey: "claudeRawEventLoggingEnabled")
        }

        func claudeRawEventLogFilePath() -> String {
            defaults.string(forKey: "claudeRawEventLogFilePath") ?? ""
        }

        func setClaudeRawEventLogFilePath(_ path: String) {
            if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                defaults.removeObject(forKey: "claudeRawEventLogFilePath")
            } else {
                defaults.set(path, forKey: "claudeRawEventLogFilePath")
            }
        }

        func agentModePerfDiagnosticsEnabled() -> Bool {
            defaults.bool(forKey: "enableAgentModePerfDiagnostics")
        }

        func setAgentModePerfDiagnosticsEnabled(_ enabled: Bool) {
            defaults.set(enabled, forKey: "enableAgentModePerfDiagnostics")
        }

        func agentModePerfDiagnosticsOSLogEnabled() -> Bool {
            defaults.bool(forKey: "emitAgentModePerfDiagnosticsToOSLog")
        }

        func setAgentModePerfDiagnosticsOSLogEnabled(_ enabled: Bool) {
            defaults.set(enabled, forKey: "emitAgentModePerfDiagnosticsToOSLog")
        }

        func worktreeStartupBenchmarkDiagnosticsEnabled() -> Bool {
            defaults.bool(forKey: WorktreeStartupBenchmarkDiagnostics.enabledDefaultsKey)
        }

        func setWorktreeStartupBenchmarkDiagnosticsEnabled(_ enabled: Bool) {
            defaults.set(enabled, forKey: WorktreeStartupBenchmarkDiagnostics.enabledDefaultsKey)
        }
    #endif

    func restrictMCPAgentDiscoveryToRoleLabels() -> Bool {
        scalarPreferences.agentMode?.restrictMCPAgentDiscoveryToRoleLabels ?? false
    }

    func setRestrictMCPAgentDiscoveryToRoleLabels(_ enabled: Bool, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { settings in
            settings.restrictMCPAgentDiscoveryToRoleLabels = enabled
        }
    }

    func modelDiffOverrides() -> [String: Bool] {
        scalarPreferences.modelOverrides?.diffOverrides ?? [:]
    }

    func setModelDiffOverrides(_ overrides: [String: Bool], commit: Bool = true) {
        updateModelOverridesScalar(commit: commit) { settings in
            settings.diffOverrides = overrides
        }
    }

    func modelStreamOverrides() -> [String: Bool] {
        scalarPreferences.modelOverrides?.streamOverrides ?? [:]
    }

    func setModelStreamOverrides(_ overrides: [String: Bool], commit: Bool = true) {
        updateModelOverridesScalar(commit: commit) { settings in
            settings.streamOverrides = overrides
        }
    }

    func modelTemperatureOverrides() -> [String: Double] {
        scalarPreferences.modelOverrides?.temperatureOverrides ?? [:]
    }

    func setModelTemperatureOverrides(_ overrides: [String: Double], commit: Bool = true) {
        updateModelOverridesScalar(commit: commit) { settings in
            settings.temperatureOverrides = overrides
        }
    }

    func modelResponsesOverrides() -> [String: Bool] {
        scalarPreferences.modelOverrides?.responsesOverrides ?? [:]
    }

    func setModelResponsesOverrides(_ overrides: [String: Bool], commit: Bool = true) {
        updateModelOverridesScalar(commit: commit) { settings in
            settings.responsesOverrides = overrides
        }
    }

    func updateModelOverrides(
        _ mutation: (inout GlobalScalarPreferences.ModelOverrideSettingsData) -> Void,
        commit: Bool = true
    ) {
        updateModelOverridesScalar(commit: commit, mutation)
    }

    private func updateUIScalar(
        commit: Bool,
        _ mutation: (inout GlobalScalarPreferences.UISettings) -> Void
    ) {
        updateScalarPreferences(commit: commit) { preferences in
            var settings = preferences.ui ?? GlobalScalarPreferences.UISettings()
            mutation(&settings)
            preferences.ui = settings
        }
    }

    private func updatePromptPackagingScalar(
        commit: Bool,
        _ mutation: (inout GlobalScalarPreferences.PromptPackagingSettings) -> Void
    ) {
        updateScalarPreferences(commit: commit) { preferences in
            var settings = preferences.promptPackaging ?? GlobalScalarPreferences.PromptPackagingSettings()
            mutation(&settings)
            preferences.promptPackaging = settings
        }
    }

    private func updateModelSelectionScalar(
        commit: Bool,
        _ mutation: (inout GlobalScalarPreferences.ModelSelectionSettings) -> Void
    ) {
        updateScalarPreferences(commit: commit) { preferences in
            var settings = preferences.modelSelection ?? GlobalScalarPreferences.ModelSelectionSettings()
            mutation(&settings)
            preferences.modelSelection = settings
        }
    }

    private func updateMCPScalar(
        commit: Bool,
        _ mutation: (inout GlobalScalarPreferences.MCPSettings) -> Void
    ) {
        updateScalarPreferences(commit: commit) { preferences in
            var settings = preferences.mcp ?? GlobalScalarPreferences.MCPSettings()
            mutation(&settings)
            preferences.mcp = settings
        }
    }

    private func updateFileSystemScalar(
        commit: Bool,
        _ mutation: (inout GlobalScalarPreferences.FileSystemSettings) -> Void
    ) {
        updateScalarPreferences(commit: commit) { preferences in
            var settings = preferences.fileSystem ?? GlobalScalarPreferences.FileSystemSettings()
            mutation(&settings)
            preferences.fileSystem = settings
        }
    }

    private func updateAgentModeScalar(
        commit: Bool,
        _ mutation: (inout GlobalScalarPreferences.AgentModeSettings) -> Void
    ) {
        updateScalarPreferences(commit: commit) { preferences in
            var settings = preferences.agentMode ?? GlobalScalarPreferences.AgentModeSettings()
            mutation(&settings)
            preferences.agentMode = settings
        }
    }

    private func updateModelOverridesScalar(
        commit: Bool,
        _ mutation: (inout GlobalScalarPreferences.ModelOverrideSettingsData) -> Void
    ) {
        updateScalarPreferences(commit: commit) { preferences in
            var settings = preferences.modelOverrides ?? GlobalScalarPreferences.ModelOverrideSettingsData()
            mutation(&settings)
            preferences.modelOverrides = settings
        }
    }

    private func updateScalarPreferences(commit: Bool, _ mutation: (inout GlobalScalarPreferences) -> Void) {
        let before = scalarPreferences
        mutation(&scalarPreferences)
        // Notify SwiftUI observers (e.g. settings views that bind directly to the
        // typed scalar accessors) whenever a scalar preference changes. The
        // @Published `codeMapsGloballyDisabled` / copy/chat collections already
        // cover other edit paths; scalar preferences are private so we fire
        // objectWillChange manually to keep views in sync during the migration
        // window.
        if before != scalarPreferences {
            objectWillChange.send()
        }
        if commit {
            save()
        }
    }

    // MARK: - Worktree Visual Identity

    enum WorktreeVisualIdentityError: Error, Equatable {
        case invalidColorHex(String)
        case emptyRepositoryID
        case emptyWorktreeID
    }

    func worktreeVisualIdentitiesByRepositoryID() -> [String: WorktreeVisualIdentityRepositoryBucket] {
        globalDefaults.worktreeVisualIdentitiesByRepositoryID ?? [:]
    }

    func worktreeVisualIdentity(repositoryID: String, worktreeID: String) -> WorktreeVisualIdentity? {
        let repositoryID = normalizedWorktreeIdentityKey(repositoryID)
        let worktreeID = normalizedWorktreeIdentityKey(worktreeID)
        guard !repositoryID.isEmpty, !worktreeID.isEmpty else { return nil }
        return globalDefaults.worktreeVisualIdentitiesByRepositoryID?[repositoryID]?.identitiesByWorktreeID[worktreeID]
    }

    func fallbackWorktreeVisualIdentity(
        repositoryID: String,
        worktreeID: String,
        label: String? = nil,
        iconName: String? = nil,
        markerStyle: WorktreeVisualMarkerStyle? = nil
    ) -> WorktreeVisualIdentity {
        WorktreeVisualIdentity(
            label: normalizedWorktreeVisualLabel(label),
            colorHex: Self.deterministicWorktreeColorHex(repositoryID: repositoryID, worktreeID: worktreeID),
            iconName: normalizedWorktreeIconName(iconName) ?? WorktreeVisualIdentity.defaultIconName,
            markerStyle: markerStyle ?? WorktreeVisualIdentity.defaultMarkerStyle,
            updatedAt: nil
        )
    }

    func resolvedWorktreeVisualIdentity(
        repositoryID: String,
        worktreeID: String,
        fallbackLabel: String? = nil,
        fallbackIconName: String? = nil,
        fallbackMarkerStyle: WorktreeVisualMarkerStyle? = nil
    ) -> WorktreeVisualIdentity {
        worktreeVisualIdentity(repositoryID: repositoryID, worktreeID: worktreeID)
            ?? fallbackWorktreeVisualIdentity(
                repositoryID: repositoryID,
                worktreeID: worktreeID,
                label: fallbackLabel,
                iconName: fallbackIconName,
                markerStyle: fallbackMarkerStyle
            )
    }

    @discardableResult
    func ensureWorktreeVisualIdentity(
        repositoryID: String,
        worktreeID: String,
        label: String? = nil,
        colorHex: String? = nil,
        iconName: String? = nil,
        markerStyle: WorktreeVisualMarkerStyle? = nil,
        updatedAt: Date = Date(),
        commit: Bool = true
    ) throws -> WorktreeVisualIdentity {
        let repositoryID = normalizedWorktreeIdentityKey(repositoryID)
        let worktreeID = normalizedWorktreeIdentityKey(worktreeID)
        guard !repositoryID.isEmpty else { throw WorktreeVisualIdentityError.emptyRepositoryID }
        guard !worktreeID.isEmpty else { throw WorktreeVisualIdentityError.emptyWorktreeID }

        let existing = worktreeVisualIdentity(repositoryID: repositoryID, worktreeID: worktreeID)
        let requestedLabel = normalizedWorktreeVisualLabel(label)
        let requestedColor = try normalizedWorktreeColorHex(colorHex)
        let requestedIconName = normalizedWorktreeIconName(iconName)
        if let existing, requestedLabel == nil, requestedColor == nil, requestedIconName == nil, markerStyle == nil {
            return existing
        }
        let normalizedLabel = requestedLabel ?? existing?.label
        let normalizedColor = requestedColor
            ?? existing?.colorHex
            ?? Self.deterministicWorktreeColorHex(repositoryID: repositoryID, worktreeID: worktreeID)
        let identity = WorktreeVisualIdentity(
            label: normalizedLabel,
            colorHex: normalizedColor,
            iconName: requestedIconName ?? existing?.iconName ?? WorktreeVisualIdentity.defaultIconName,
            markerStyle: markerStyle ?? existing?.markerStyle ?? WorktreeVisualIdentity.defaultMarkerStyle,
            updatedAt: updatedAt
        )
        guard existing != identity else { return identity }
        setValidatedWorktreeVisualIdentity(identity, repositoryID: repositoryID, worktreeID: worktreeID, commit: commit)
        return identity
    }

    func setWorktreeVisualIdentity(
        _ identity: WorktreeVisualIdentity,
        repositoryID: String,
        worktreeID: String,
        commit: Bool = true
    ) throws {
        let repositoryID = normalizedWorktreeIdentityKey(repositoryID)
        let worktreeID = normalizedWorktreeIdentityKey(worktreeID)
        guard !repositoryID.isEmpty else { throw WorktreeVisualIdentityError.emptyRepositoryID }
        guard !worktreeID.isEmpty else { throw WorktreeVisualIdentityError.emptyWorktreeID }
        let normalizedColor = try normalizedWorktreeColorHex(identity.colorHex) ?? identity.colorHex
        let normalizedIdentity = WorktreeVisualIdentity(
            label: normalizedWorktreeVisualLabel(identity.label),
            colorHex: normalizedColor,
            iconName: normalizedWorktreeIconName(identity.iconName) ?? WorktreeVisualIdentity.defaultIconName,
            markerStyle: identity.markerStyle,
            updatedAt: identity.updatedAt
        )
        setValidatedWorktreeVisualIdentity(
            normalizedIdentity,
            repositoryID: repositoryID,
            worktreeID: worktreeID,
            commit: commit
        )
    }

    private func setValidatedWorktreeVisualIdentity(
        _ identity: WorktreeVisualIdentity,
        repositoryID: String,
        worktreeID: String,
        commit: Bool
    ) {
        var repositories = globalDefaults.worktreeVisualIdentitiesByRepositoryID ?? [:]
        var bucket = repositories[repositoryID] ?? WorktreeVisualIdentityRepositoryBucket()
        bucket.identitiesByWorktreeID[worktreeID] = identity
        repositories[repositoryID] = bucket
        globalDefaults.worktreeVisualIdentitiesByRepositoryID = repositories
        objectWillChange.send()
        if commit {
            save()
        }
    }

    private func normalizedWorktreeIdentityKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedWorktreeVisualLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedWorktreeIconName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedWorktreeColorHex(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Self.isValidWorktreeColorHex(trimmed) else {
            throw WorktreeVisualIdentityError.invalidColorHex(value)
        }
        return trimmed
    }

    static func isValidWorktreeColorHex(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 7, scalars.first == "#" else { return false }
        return scalars.dropFirst().allSatisfy { scalar in
            (48 ... 57).contains(scalar.value)
                || (65 ... 70).contains(scalar.value)
                || (97 ... 102).contains(scalar.value)
        }
    }

    private static func deterministicWorktreeColorHex(repositoryID: String, worktreeID: String) -> String {
        let palette = [
            "#2563EB", "#7C3AED", "#DB2777", "#DC2626", "#EA580C", "#CA8A04",
            "#16A34A", "#059669", "#0891B2", "#4F46E5", "#9333EA", "#C026D3"
        ]
        let seed = "\(repositoryID)\u{0}\(worktreeID)"
        let hash = seed.unicodeScalars.reduce(UInt64(14_695_981_039_346_656_037)) { result, scalar in
            (result ^ UInt64(scalar.value)).multipliedReportingOverflow(by: 1_099_511_628_211).partialValue
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    // MARK: - Global Code Maps Override

    func globalCodeMapsDisabled() -> Bool {
        codeMapsGloballyDisabled
    }

    func setCodeMapsGloballyDisabled(_ disabled: Bool, commit: Bool = true) {
        guard codeMapsGloballyDisabled != disabled || (globalDefaults.codeMapsGloballyDisabled ?? false) != disabled else {
            return
        }
        globalDefaults.codeMapsGloballyDisabled = disabled
        codeMapsGloballyDisabled = disabled
        if commit {
            save()
        }
    }

    // MARK: - Global Context Builder Agent Selection (Single Source of Truth)

    /// Returns the raw persisted global Context Builder selection without synthesizing a fallback.
    /// Startup restoration needs to distinguish a real saved value from the catalog's historical
    /// Claude Code / Opus default so it can validate availability and use recommendations instead.
    func persistedGlobalContextBuilderAgentSelection() -> (agentRaw: String?, modelRaw: String?) {
        guard let agentRaw = globalDefaults.discoverAgentRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !agentRaw.isEmpty
        else {
            return (nil, nil)
        }
        let modelRaw = globalDefaults.discoverModelsByAgent?[agentRaw]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (agentRaw, modelRaw?.isEmpty == false ? modelRaw : nil)
    }

    /// Returns a normalized global Context Builder agent and model selection.
    /// Callers performing startup restoration should use
    /// `persistedGlobalContextBuilderAgentSelection()` and validate against current availability.
    func globalContextBuilderAgentSelection() -> (agentRaw: String?, modelRaw: String?) {
        let persisted = persistedGlobalContextBuilderAgentSelection()
        let normalized = AgentModelCatalog.normalizeSelection(
            agentRaw: persisted.agentRaw,
            modelRaw: persisted.modelRaw
        )
        return (normalized.agent.rawValue, normalized.modelRaw)
    }

    /// Returns the remembered raw model for a specific global Context Builder agent slot.
    /// This intentionally exposes only the per-agent memory entry needed by
    /// allowlisted settings surfaces; callers that need an executable selection
    /// should continue using `globalContextBuilderAgentSelection()`.
    func globalContextBuilderRememberedModelRaw(for agentRaw: String) -> String? {
        let trimmedAgentRaw = agentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentProviderKind(rawValue: trimmedAgentRaw) != nil else { return nil }
        guard let raw = globalDefaults.discoverModelsByAgent?[trimmedAgentRaw]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        return raw
    }

    /// Sets the global Context Builder agent and model selection.
    /// This is the only way to update the global Context Builder agent/model - workspace settings
    /// should NOT be used for this purpose.
    /// - Parameters:
    ///   - agentRaw: The agent rawValue (e.g., "claudeCode", "codexExec", "openCode")
    ///   - modelRaw: The model rawValue for the selected agent
    ///   - markUserDefined: If true, marks this as a user-defined selection (prevents auto-apply override)
    func setGlobalContextBuilderAgentSelection(
        agentRaw: String,
        modelRaw: String,
        markUserDefined: Bool = true,
        reason: String? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        let oldSelection = globalContextBuilderAgentSelection()
        let normalized = AgentModelCatalog.normalizeSelection(agentRaw: agentRaw, modelRaw: modelRaw)
        globalDefaults.discoverAgentRaw = normalized.agent.rawValue
        if globalDefaults.discoverModelsByAgent == nil {
            globalDefaults.discoverModelsByAgent = [:]
        }
        globalDefaults.discoverModelsByAgent?[normalized.agent.rawValue] = normalized.modelRaw
        if markUserDefined {
            globalDefaults.didUserSetDiscoverAgentDefaults = true
        }
        recordSettingsWriteDiagnostic(
            key: "globalContextBuilderAgentSelection",
            oldValue: oldSelection.agentRaw.flatMap { oldAgentRaw in
                oldSelection.modelRaw.map { "\(oldAgentRaw):\($0)" } ?? oldAgentRaw
            },
            newValue: "\(normalized.agent.rawValue):\(normalized.modelRaw)",
            commit: true,
            markUserDefined: markUserDefined,
            reason: reason,
            fileID: fileID,
            line: line,
            function: function
        )
        save()
    }

    /// Sets the global Context Builder agent and optionally updates/clears that agent's
    /// remembered model slot. Passing `nil` or an empty string clears the current
    /// remembered model entry for the selected agent; `globalContextBuilderAgentSelection()`
    /// will still synthesize a runtime default when a concrete model is required.
    func setGlobalContextBuilderAgentSelection(
        agentRaw: String,
        modelRaw: String?,
        markUserDefined: Bool = true,
        reason: String? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        let oldSelection = globalContextBuilderAgentSelection()
        let trimmedAgentRaw = agentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let agent = AgentProviderKind(rawValue: trimmedAgentRaw)
            ?? AgentModelCatalog.normalizeSelection(agentRaw: trimmedAgentRaw, modelRaw: modelRaw).agent
        globalDefaults.discoverAgentRaw = agent.rawValue

        let trimmedModelRaw = modelRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newModelRaw: String?
        if let trimmedModelRaw, !trimmedModelRaw.isEmpty {
            let normalized = AgentModelCatalog.normalizeSelection(
                agentRaw: agent.rawValue,
                modelRaw: trimmedModelRaw
            )
            if globalDefaults.discoverModelsByAgent == nil {
                globalDefaults.discoverModelsByAgent = [:]
            }
            globalDefaults.discoverModelsByAgent?[normalized.agent.rawValue] = normalized.modelRaw
            newModelRaw = normalized.modelRaw
        } else {
            globalDefaults.discoverModelsByAgent?[agent.rawValue] = nil
            newModelRaw = nil
        }

        if markUserDefined {
            globalDefaults.didUserSetDiscoverAgentDefaults = true
        }
        recordSettingsWriteDiagnostic(
            key: "globalContextBuilderAgentSelection",
            oldValue: oldSelection.agentRaw.flatMap { oldAgentRaw in
                oldSelection.modelRaw.map { "\(oldAgentRaw):\($0)" } ?? oldAgentRaw
            },
            newValue: newModelRaw.map { "\(agent.rawValue):\($0)" } ?? agent.rawValue,
            commit: true,
            markUserDefined: markUserDefined,
            reason: reason,
            fileID: fileID,
            line: line,
            function: function
        )
        save()
    }

    /// Returns whether the user has explicitly set the global Context Builder agent defaults.
    /// Used by recommendation engine to determine if auto-apply should be allowed.
    /// NOTE: For existing installs, `didUserSetDiscoverAgentDefaults` will be nil but
    /// they may already have a configured selection. We treat nil + existing selection
    /// as "user-defined" to avoid overwriting their settings via auto-apply.
    var hasUserSetGlobalContextBuilderAgentDefaults: Bool {
        // Explicit true = definitely user-set
        if globalDefaults.didUserSetDiscoverAgentDefaults == true {
            return true
        }
        // nil (legacy) + existing selection = treat as user-set to be safe
        if globalDefaults.didUserSetDiscoverAgentDefaults == nil,
           globalDefaults.discoverAgentRaw != nil
        {
            return true
        }
        // false (seeded/new) or nil + no selection = not user-set
        return false
    }

    // MARK: - Helper Methods

    /// Update global Context Builder agent defaults to seed new workspaces.
    /// Kept for compatibility with legacy persisted fields; prefer `setGlobalContextBuilderAgentSelection`.
    func updateGlobalContextBuilderAgentDefaults(agentRaw: String?, modelRaw: String?) {
        // Redirect to the new API if we have valid values
        if let agent = agentRaw, let model = modelRaw {
            setGlobalContextBuilderAgentSelection(agentRaw: agent, modelRaw: model, markUserDefined: true)
        } else if let agent = agentRaw {
            globalDefaults.discoverAgentRaw = agent
            save()
        }
    }

    // MARK: - Global MCP Agent Role Defaults (Single Source of Truth)

    /// Returns global MCP Agent Mode role-default overrides.
    /// nil means all roles use the recommended defaults.
    func globalMCPAgentRoleOverrides() -> [String: String]? {
        normalizedRoleOverrides(globalDefaults.mcpAgentRoleOverrides)
    }

    /// Updates global MCP Agent Mode role-default overrides.
    /// Empty dictionaries are normalized to nil.
    func updateGlobalMCPAgentRoleOverrides(_ overrides: [String: String]?, commit: Bool = true) {
        globalDefaults.mcpAgentRoleOverrides = Self.normalizedMCPAgentRoleOverrides(overrides)
        if commit {
            save()
        }
    }

    // MARK: - Recommendation Provider Filter (Global)

    /// Returns the global provider filter for recommendation generation. Absence means all providers.
    func globalRecommendationProviderFilter() -> Set<RecommendationProviderKind> {
        Self.normalizedRecommendationProviderFilter(raw: globalDefaults.recommendationProviderFilterRaw)
    }

    /// Normalizes persisted provider filters across recommendation-provider list changes.
    ///
    /// Older builds could persist the previous "all providers" set, which included Anthropic API
    /// and did not include Cursor CLI. Treat that legacy all-providers shape as the current all
    /// providers so newly supported providers are not silently hidden from recommendations/UI.
    static func normalizedRecommendationProviderFilter(raw stored: [String]?) -> Set<RecommendationProviderKind> {
        guard let stored else {
            return Set(RecommendationProviderKind.allCases)
        }
        let storedSet = Set(stored)
        let legacyAllProviders: Set<String> = [
            RecommendationProviderKind.claudeCode.rawValue,
            RecommendationProviderKind.codex.rawValue,
            RecommendationProviderKind.openAI.rawValue,
            "anthropic",
            "geminiCLI"
        ]
        if storedSet.isSuperset(of: legacyAllProviders) {
            return Set(RecommendationProviderKind.allCases)
        }
        let normalized = Set(stored.compactMap(RecommendationProviderKind.init(rawValue:)))
        if normalized.isEmpty, !stored.isEmpty {
            return Set(RecommendationProviderKind.allCases)
        }
        return normalized
    }

    /// Updates the global provider filter. Passing all providers clears the override.
    func setGlobalRecommendationProviderFilter(_ providers: Set<RecommendationProviderKind>, commit: Bool = true) {
        if providers == Set(RecommendationProviderKind.allCases) {
            globalDefaults.recommendationProviderFilterRaw = nil
        } else {
            globalDefaults.recommendationProviderFilterRaw = RecommendationProviderKind.allCases
                .filter { providers.contains($0) }
                .map(\.rawValue)
        }
        if commit {
            save()
        }
    }

    private func normalizedRoleOverrides(_ overrides: [String: String]?) -> [String: String]? {
        Self.normalizedMCPAgentRoleOverrides(overrides)
    }

    private static func normalizedMCPAgentRoleOverrides(_ overrides: [String: String]?) -> [String: String]? {
        guard let overrides else { return nil }
        let normalized = overrides.reduce(into: [String: String]()) { result, entry in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { return }
            result[key] = value
        }
        return normalized.isEmpty ? nil : normalized
    }

    /// Check if recommendation schema version is current; if not, clear mutes across all workspaces.
    /// Returns true if schema was updated (mutes cleared).
    @discardableResult
    func ensureLatestRecommendationSchema(currentVersion: Int) -> Bool {
        if globalDefaults.recommendationSchemaVersion != currentVersion {
            // Clear all mutedRecommendationIDs and completion timestamps across workspaces
            for (id, var s) in chatSettings {
                s.mutedRecommendationIDs = nil
                s.lastRecommendationWizardCompletedAt = nil
                chatSettings[id] = s
            }
            globalDefaults.recommendationSchemaVersion = currentVersion
            save()
            return true
        }
        return false
    }

    /// Seed new workspace chat settings with defaults.
    /// Called when creating brand new ChatGlobalSettings for a workspace.
    /// NOTE: Context Builder agent/model are now GLOBAL (not per-workspace), so we don't seed those here.
    /// The workspace lastUsedDiscover* fields are legacy and kept only for backwards compatibility.
    private func seedChatSettingsDefaults(_ settings: inout ChatGlobalSettings) {
        // Legacy: seed workspace discover settings from global for backwards compatibility
        // These are no longer the source of truth - global settings are.
        if settings.lastUsedDiscoverAgentRaw == nil {
            settings.lastUsedDiscoverAgentRaw = globalDefaults.discoverAgentRaw ?? "claudeCode"
        }
        if settings.lastUsedDiscoverModelsByAgent == nil {
            settings.lastUsedDiscoverModelsByAgent = globalDefaults.discoverModelsByAgent ?? [:]
        }

        // Seed context-builder agent from global defaults (legacy feature)
        if settings.contextBuilderAgentRaw == nil {
            settings.contextBuilderAgentRaw = globalDefaults.contextBuilderAgentRaw ?? "claudeCode"
        }

        // Mark as seeded (not user-defined) for recommendation auto-apply
        // These are explicitly false (not nil) to indicate this is a new workspace
        settings.didUserSetDiscoverAgentDefaults = false
        settings.didUserSetContextBuilderDefaults = false
        settings.didAutoApplyRecommendationsAt = nil
    }

    // MARK: - Persistence

    private func load() {
        let document = fileStore.loadOrCreateDefault()
        copySettings = document.copySettings
        chatSettings = document.chatSettings
        globalDefaults = document.globalDefaults
        scalarPreferences = document.scalarPreferences ?? GlobalScalarPreferences()
        codeMapsGloballyDisabled = globalDefaults.codeMapsGloballyDisabled ?? false
    }

    @discardableResult
    func reloadFromDisk() -> Bool {
        do {
            let document = try fileStore.load()
            objectWillChange.send()
            copySettings = document.copySettings
            chatSettings = document.chatSettings
            globalDefaults = document.globalDefaults
            scalarPreferences = document.scalarPreferences ?? GlobalScalarPreferences()
            codeMapsGloballyDisabled = globalDefaults.codeMapsGloballyDisabled ?? false
            return true
        } catch {
            print("⚠️ Failed to reload global settings JSON at \(fileStore.fileURL.path): \(error)")
            return false
        }
    }

    private func ensureFileSystemGlobalIgnoreDefaultsSeeded() {
        var fileSystemSettings = scalarPreferences.fileSystem ?? GlobalScalarPreferences.FileSystemSettings()
        guard fileSystemSettings.globalIgnoreDefaults == nil else { return }
        fileSystemSettings.globalIgnoreDefaults = IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults
        scalarPreferences.fileSystem = fileSystemSettings
        save()
    }

    private func resolvedSyncChatModelWithOracleFromCurrentPreferences() -> Bool {
        if let stored = scalarPreferences.modelSelection?.syncChatModelWithOracle {
            return stored
        }
        let planning = scalarPreferences.modelSelection?.planningModel ?? ""
        let compose = scalarPreferences.modelSelection?.preferredComposeModel ?? ""
        return !planning.isEmpty && planning == compose
    }

    private func syncSiblingReason(from reason: String?) -> String? {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return "\(trimmed).sync_sibling"
    }

    private func syncSnapReason(from reason: String?) -> String? {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return "\(trimmed).snap_to_planning"
    }

    private func save() {
        let document = GlobalSettingsDocument(
            copySettings: copySettings,
            chatSettings: chatSettings,
            globalDefaults: globalDefaults,
            scalarPreferences: scalarPreferences
        )

        do {
            try fileStore.save(document)
        } catch {
            print("⚠️ Failed to save global settings JSON at \(fileStore.fileURL.path): \(error)")
        }
    }
}
