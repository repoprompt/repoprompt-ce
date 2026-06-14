import Combine
import Foundation
import SwiftUI

enum FileTreeOption: String, CaseIterable, Identifiable, Codable {
    case auto = "Auto"
    case files = "Full"
    case selected = "Selected"
    case none = "None"

    var id: String {
        rawValue
    }
}

/// Errors that can occur when publishing git diff artifacts
enum GitArtifactPublishError: LocalizedError {
    case noActiveWorkspace
    case noGitRepository
    case noDiffModeSelected
    case noFilesSelected

    var errorDescription: String? {
        switch self {
        case .noActiveWorkspace: "No active workspace"
        case .noGitRepository: "No git repository found"
        case .noDiffModeSelected: "No diff mode selected"
        case .noFilesSelected: "No changed files selected"
        }
    }
}

@MainActor
enum FilesTabSelection: Equatable {
    case followDefault
    case explicit(FilesTab)
}

@MainActor
enum FilesTabChangeSource {
    case user
    case workspaceApply
    case restore
}

@MainActor
class PromptViewModel: ObservableObject {
    /// Set to true to enable debug logging for settings sync
    static var debugLoggingEnabled = false

    // MARK: - Type Definitions and Enums

    enum PlanActMode: String, CaseIterable, Codable {
        case chat = "Chat"
        case plan = "Plan"
        case edit = "Edit"
        case review = "Review"
    }

    enum FileEditFormat: String, CaseIterable {
        case diff = "Diff"
        case whole = "Whole"
        case none = "None"
    }

    enum FileTreeType {
        case full
        case foldersOnly
        case excluded
    }

    enum PromptSelectionContext {
        case copy
        case chat
    }

    struct StoredPrompt: Identifiable, Codable, Equatable {
        let id: UUID
        var title: String
        var content: String
        /// Tracks whether the user has manually edited a built-in prompt.
        /// When true, auto-upgrades of built-in content are skipped.
        var isUserEdited: Bool

        init(id: UUID, title: String, content: String, isUserEdited: Bool = false) {
            self.id = id
            self.title = title
            self.content = content
            self.isUserEdited = isUserEdited
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            content = try container.decode(String.self, forKey: .content)
            isUserEdited = try container.decodeIfPresent(Bool.self, forKey: .isUserEdited) ?? false
        }

        static func == (lhs: StoredPrompt, rhs: StoredPrompt) -> Bool {
            lhs.id == rhs.id &&
                lhs.title == rhs.title &&
                lhs.content == rhs.content
        }
    }

    // MARK: - Core Properties

    @Published private(set) var fileManager: WorkspaceFilesViewModel
    var workspaceFileContextStore: WorkspaceFileContextStore {
        fileManager.workspaceFileContextStore
    }

    @Published private(set) var gitViewModel: GitViewModel
    @Published private(set) var aiQueriesService: AIQueriesService?
    let windowID: Int
    private var cancellables = Set<AnyCancellable>()
    private var isDirty: Bool = false
    @Published private(set) var queryIdentifier = UUID()
    private weak var workspaceManager: WorkspaceManagerViewModel?
    private weak var selectionCoordinator: WorkspaceSelectionCoordinator?

    // MARK: - Compose Tabs

    @Published private(set) var currentComposeTabs: [ComposeTabState] = []
    @Published private(set) var activeComposeTabID: UUID? {
        didSet {
            guard oldValue != activeComposeTabID else { return }
            NotificationCenter.default.post(
                name: .activeComposeTabChanged,
                object: nil,
                userInfo: [
                    "tabID": activeComposeTabID as Any,
                    "windowID": windowID
                ]
            )
        }
    }

    @Published private(set) var dirtyTabIDs: Set<UUID> = []
    @Published private(set) var isSwitchingComposeTab: Bool = false
    private var activeTabApplyTask: Task<Void, Never>?
    private static let defaultComposeTabSoftLimit = 50
    private let maxComposeTabs = PromptViewModel.defaultComposeTabSoftLimit
    private var isDirtyStateUpdateScheduled = false

    enum ComposeTabCapacityPolicy: Equatable {
        case uiInteractive
        case mcpBackgroundAgent
    }

    typealias ComposeTabAutoStashEligibilityProvider = @MainActor (_ tabID: UUID) -> Bool
    var composeTabAutoStashEligibilityProvider: ComposeTabAutoStashEligibilityProvider?

    private var backgroundAgentComposeTabHardLimit: Int {
        max(maxComposeTabs, settingsManager.maxBackgroundAgentComposeTabs())
    }

    // MARK: - Tab Close Listeners

    /// Async listeners that are called before tabs are closed, allowing cleanup of running tasks.
    enum ComposeTabRemovalReason: Equatable {
        case close
        case stash
        case deleteStashed
    }

    struct AgentSessionCascadePlan: Equatable {
        var composeTabIDs: Set<UUID> = []
        var stashedTabIDs: Set<UUID> = []
    }

    typealias ComposeTabsWillCloseListener = @Sendable (_ tabIDs: Set<UUID>, _ reason: ComposeTabRemovalReason) async -> Void
    typealias ComposeTabCascadeResolver = @Sendable (_ tabIDs: Set<UUID>, _ reason: ComposeTabRemovalReason) async -> AgentSessionCascadePlan
    typealias StashedTabCascadeResolver = @Sendable (_ stashedTabIDs: Set<UUID>) async -> AgentSessionCascadePlan
    private var composeTabsWillCloseListeners: [UUID: ComposeTabsWillCloseListener] = [:]
    var composeTabCascadeResolver: ComposeTabCascadeResolver?
    var stashedTabCascadeResolver: StashedTabCascadeResolver?

    var composeTabLimit: Int {
        maxComposeTabs
    }

    // MARK: - UI State Properties

    @Published var promptText: String = ""
    @Published var aiResponse: String = ""
    @Published private(set) var isQueryInProgress = false
    @Published private(set) var isCancellable = false
    @Published var instructionsHeight: CGFloat = 300
    @Published private(set) var activeFilesTab: FilesTab = .selected
    private var filesTabSelection: FilesTabSelection = .followDefault
    @Published var selectedFileForPreview: FileViewModel?

    // MARK: - Files Tab Selection

    var storedActiveSubView: FilesTab? {
        if case let .explicit(tab) = filesTabSelection {
            return tab
        }
        return nil
    }

    func setFilesTabSelection(_ selection: FilesTabSelection, source: FilesTabChangeSource) {
        let previousSelection = filesTabSelection
        let previousResolved = activeFilesTab
        let resolved = resolveFilesTab(for: selection)

        filesTabSelection = selection
        if previousResolved != resolved {
            activeFilesTab = resolved
        }

        let didChange = previousSelection != selection || previousResolved != resolved
        if didChange {
            let shouldMarkDirty = (source == .user || source == .restore)
            if shouldMarkDirty {
                workspaceManager?.markWorkspaceDirty()
            }
            updateActiveTabDirtyState()
        }
    }

    func setActiveFilesTab(_ tab: FilesTab, source: FilesTabChangeSource) {
        setFilesTabSelection(.explicit(tab), source: source)
    }

    private func resolveFilesTab(for selection: FilesTabSelection) -> FilesTab {
        switch selection {
        case let .explicit(tab):
            tab
        case .followDefault:
            .context
        }
    }

    /// Prompt Section Ordering State
    private var promptSectionsOrderRaw: String {
        get { settingsManager.promptSectionsOrderRaw() }
        set {
            guard newValue != promptSectionsOrderRaw else { return }
            settingsManager.setPromptSectionsOrderRaw(newValue, commit: true)
            handlePromptPackagingSettingChanged()
        }
    }

    @Published var promptSectionsOrder: [PromptSection] = PromptAssemblyBuilder.defaultSectionOrder
    var duplicateUserInstructionsAtTop: Bool {
        get { settingsManager.duplicateUserInstructionsAtTop() }
        set {
            guard newValue != duplicateUserInstructionsAtTop else { return }
            settingsManager.setDuplicateUserInstructionsAtTop(newValue, commit: true)
            handlePromptPackagingSettingChanged()
        }
    }

    var disabledPromptSections: Set<PromptSection> {
        Set<PromptSection>()
    }

    // MARK: - File Display Properties

    var filePathDisplayOption: FilePathDisplay {
        get { FilePathDisplay(rawValue: settingsManager.filePathDisplayOptionRaw()) ?? .full }
        set {
            guard newValue != filePathDisplayOption else { return }
            settingsManager.setFilePathDisplayOptionRaw(newValue.rawValue, commit: true)
            handlePromptPackagingSettingChanged()
        }
    }

    var selectedFilesSortMethod: SortMethod {
        get { SortMethod(rawValue: settingsManager.selectedFilesSortMethodRaw()) ?? .nameAscending }
        set {
            guard newValue != selectedFilesSortMethod else { return }
            settingsManager.setSelectedFilesSortMethodRaw(newValue.rawValue, commit: true)
            handlePromptPackagingSettingChanged()
        }
    }

    @AppStorage("onlyIncludeRootsWithSelectedFiles") var onlyIncludeRootsWithSelectedFiles: Bool = true

    // MARK: - Model and Format Properties

    var fileEditFormat: FileEditFormat {
        get { FileEditFormat(rawValue: settingsManager.fileEditFormatRaw()) ?? .diff }
        set {
            guard newValue != fileEditFormat else { return }
            settingsManager.setFileEditFormatRaw(newValue.rawValue, commit: true)
            handlePromptPackagingSettingChanged()
        }
    }

    @Published private var _preferredModel: String = ""
    private var sessionPreferredModelOverrideRaw: String?
    @Published private var _contextBuilderModel: String = "" // workspace-scoped (synced from ChatGlobalSettings)
    @Published private var _planningModel: String = ""

    /// Returns the chosen planning model as an `AIModel` (falls back to preferredAIModel).
    var planningModel: AIModel {
        AIModel.fromModelName(planningModelName) ?? preferredAIModel
    }

    enum MCPOraclePlanningModelResolution: Equatable {
        case configured(AIModel)
        case unconfigured
        case invalid(rawValue: String)
        case unavailable(AIModel)
    }

    nonisolated static func mcpOraclePlanningModelResolution(
        rawValue: String,
        isModelAvailable: (AIModel) -> Bool
    ) -> MCPOraclePlanningModelResolution {
        let trimmedRawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRawValue.isEmpty else {
            return .unconfigured
        }
        guard let model = AIModel.fromModelName(trimmedRawValue) else {
            return .invalid(rawValue: trimmedRawValue)
        }
        guard isModelAvailable(model) else {
            return .unavailable(model)
        }
        return .configured(model)
    }

    func mcpOraclePlanningModelResolution() -> MCPOraclePlanningModelResolution {
        Self.mcpOraclePlanningModelResolution(
            rawValue: planningModelName,
            isModelAvailable: { [weak self] model in
                self?.isProviderConfigured(for: model) ?? false
            }
        )
    }

    nonisolated static func mcpOraclePlanningModelErrorMessage(
        for resolution: MCPOraclePlanningModelResolution,
        availabilityGuidance: ((AIModel) -> String)? = nil
    ) -> String? {
        switch resolution {
        case .configured:
            return nil
        case .unconfigured:
            return "MCP Oracle model is not configured. Select an Oracle model in the Models settings before using ask_oracle."
        case let .invalid(rawValue):
            return "MCP Oracle model raw value '\(rawValue)' is invalid. Select a valid Oracle model in the Models settings before using ask_oracle."
        case let .unavailable(model):
            let guidance = availabilityGuidance?(model)
            let suffix = guidance.map { " \($0)" } ?? ""
            return "MCP oracle model '\(model.displayName)' is not available.\(suffix)"
        }
    }

    /// String wrapper exposed to the UI for persistence.
    var planningModelName: String {
        get { _planningModel }
        set {
            setPlanningModelRaw(newValue, markDirty: true, reason: "prompt.model_selection.planning")
        }
    }

    private func setPreferredModelRaw(_ rawValue: String, markDirty: Bool, reason: String? = nil) {
        sessionPreferredModelOverrideRaw = nil
        let shouldSync = settingsManager.syncChatModelWithOracle()
        if _preferredModel != rawValue {
            _preferredModel = rawValue
        }
        if shouldSync, _planningModel != rawValue {
            _planningModel = rawValue
        }
        settingsManager.setPreferredComposeModelRaw(rawValue, commit: true, reason: reason, honorSync: shouldSync)
        if markDirty {
            isDirty = true
        }
    }

    private func setPlanningModelRaw(_ rawValue: String, markDirty: Bool, reason: String? = nil) {
        let shouldSync = settingsManager.syncChatModelWithOracle()
        if _planningModel != rawValue {
            _planningModel = rawValue
        }
        if shouldSync, _preferredModel != rawValue {
            sessionPreferredModelOverrideRaw = nil
            _preferredModel = rawValue
        }
        settingsManager.setPlanningModelRaw(rawValue, commit: true, reason: reason, honorSync: shouldSync)
        if markDirty {
            isDirty = true
        }
    }

    @Published private(set) var availableModels: [AIModel] = []
    @Published private(set) var apiSettingsViewModel: APISettingsViewModel?
    private var apiSettingsObserver: AnyCancellable?
    private var apiSettingsCancellables = Set<AnyCancellable>()

    @Published private(set) var availableAgentKinds: [AgentProviderKind] = AgentModelCatalog.selectableAgents(availability: .none)

    /// Preferred context-builder agent (global, persisted via GlobalSettingsStore)
    @Published var contextBuilderAgent: AgentProviderKind = .claudeCode {
        didSet {
            guard oldValue != contextBuilderAgent else { return }
            if isSyncingSettings { return }
            if !isContextBuilderModelRawValidForAgent(contextBuilderAgentModelRaw, agent: contextBuilderAgent) {
                contextBuilderAgentModelRaw = defaultModelRaw(for: contextBuilderAgent)
            }
            settingsManager.setGlobalContextBuilderAgentSelection(
                agentRaw: contextBuilderAgent.rawValue,
                modelRaw: contextBuilderAgentModelRaw,
                markUserDefined: true
            )
            postRecommendationsShouldRefresh(reason: "contextBuilderAgentChanged")
        }
    }

    /// Raw selected model for context builder agent.
    @Published var contextBuilderAgentModelRaw: String = AgentModel.defaultModel.rawValue {
        didSet {
            let normalized = contextBuilderAgentModelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveRaw = normalized.isEmpty ? defaultModelRaw(for: contextBuilderAgent) : normalized
            guard oldValue.caseInsensitiveCompare(effectiveRaw) != .orderedSame else { return }
            if contextBuilderAgentModelRaw != effectiveRaw {
                contextBuilderAgentModelRaw = effectiveRaw
                return
            }
            if isSyncingSettings { return }
            if !isContextBuilderModelRawValidForAgent(effectiveRaw, agent: contextBuilderAgent) {
                contextBuilderAgentModelRaw = defaultModelRaw(for: contextBuilderAgent)
                return
            }
            settingsManager.setGlobalContextBuilderAgentSelection(
                agentRaw: contextBuilderAgent.rawValue,
                modelRaw: effectiveRaw,
                markUserDefined: true
            )
            postRecommendationsShouldRefresh(reason: "contextBuilderAgentModelChanged")
        }
    }

    /// Legacy enum wrapper over contextBuilderAgentModelRaw.
    var contextBuilderAgentModel: AgentModel {
        get { AgentModel.resolvedModel(forRaw: contextBuilderAgentModelRaw, agentKind: contextBuilderAgent) ?? .defaultModel }
        set { selectContextBuilderAgentModel(rawModel: newValue.rawValue) }
    }

    var contextBuilderAgentModelDisplayName: String {
        AgentModelCatalog.displayName(
            for: contextBuilderAgentModelRaw,
            agentKind: contextBuilderAgent,
            availability: agentAvailabilityContext
        )
    }

    func contextBuilderModelOptions(for agentKind: AgentProviderKind) -> [AgentModelOption] {
        AgentModelCatalog.options(for: agentKind, availability: agentAvailabilityContext)
    }

    private var agentAvailabilityContext: AgentModelCatalog.AvailabilityContext {
        apiSettingsViewModel?.agentModeAvailabilityContext ?? .none
    }

    private func defaultModelRaw(for agentKind: AgentProviderKind) -> String {
        AgentModelCatalog.defaultModelRaw(for: agentKind, availability: agentAvailabilityContext)
    }

    private func refreshAvailableAgentKinds() {
        availableAgentKinds = AgentModelCatalog.selectableAgents(availability: agentAvailabilityContext)
    }

    private func resolvedPersistedContextBuilderSelection() -> AgentModelCatalog.NormalizedAgentSelection? {
        guard let apiSettingsViewModel,
              apiSettingsViewModel.isContextBuilderProviderValidationComplete
        else {
            return nil
        }
        let persisted = settingsManager.persistedGlobalContextBuilderAgentSelection()
        return AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: persisted.agentRaw,
            persistedModelRaw: persisted.modelRaw,
            availability: apiSettingsViewModel.contextBuilderRestorationAvailabilityContext,
            enabledRecommendationProviders: settingsManager.globalRecommendationProviderFilter()
        )
    }

    func selectContextBuilderAgentModel(rawModel: String) {
        contextBuilderAgentModelRaw = rawModel
    }

    private func isContextBuilderModelRawValidForAgent(_ rawModel: String, agent: AgentProviderKind) -> Bool {
        AgentModelCatalog.isValid(rawModel: rawModel, for: agent, availability: agentAvailabilityContext)
    }

    private func handleAgentProviderAvailabilityChanged(reason: String) {
        refreshAvailableAgentKinds()
        guard let normalizedContextBuilder = resolvedPersistedContextBuilderSelection() else { return }
        if normalizedContextBuilder.agent != contextBuilderAgent ||
            normalizedContextBuilder.modelRaw.caseInsensitiveCompare(contextBuilderAgentModelRaw) != .orderedSame
        {
            isSyncingSettings = true
            contextBuilderAgent = normalizedContextBuilder.agent
            contextBuilderAgentModelRaw = normalizedContextBuilder.modelRaw
            isSyncingSettings = false
            postRecommendationsShouldRefresh(reason: reason)
        }
    }

    /// Force-commit context builder settings to the global store so other components (like recommendation engine) see them.
    func commitContextBuilderSettings() {
        settingsManager.setGlobalContextBuilderAgentSelection(
            agentRaw: contextBuilderAgent.rawValue,
            modelRaw: contextBuilderAgentModelRaw,
            markUserDefined: true
        )
        postRecommendationsShouldRefresh(reason: "contextBuilderSettingsCommitted")
    }

    private func postRecommendationsShouldRefresh(reason: String) {
        NotificationCenter.default.post(
            name: .recommendationsShouldRefresh,
            object: nil,
            userInfo: ["reason": reason]
        )
    }

    /// Temporary storage for customizations during preset transitions
    private var preservedCustomizations: CopyCustomizations?

    /// Plan/Act mode persisted per workspace and mirrored into global chat settings.
    @Published var planActMode: PlanActMode = .chat {
        didSet {
            guard oldValue != planActMode else { return }
            if isSyncingSettings { return }
            guard let workspaceID = currentWorkspaceID else { return }

            var settings = settingsManager.chatSettings(for: workspaceID)
            if settings.planActMode != planActMode {
                settings.planActMode = planActMode
                settingsManager.updateChatSettings(settings, commit: nil)
            }
            isDirty = true
        }
    }

    var preferredAIModel: AIModel {
        // print("Preffered model: \(preferredModel)")
        AIModel.fromModelName(preferredModel) ?? .claude4Sonnet
        // print("model=\(model)")
    }

    var preferredModel: String {
        get { _preferredModel }
        set {
            setPreferredModelRaw(newValue, markDirty: true, reason: "prompt.model_selection.preferred_compose")
        }
    }

    /// Restores the model remembered by a chat session without changing the global compose default.
    func restorePreferredModelForSession(_ rawValue: String?) {
        guard let rawValue else {
            sessionPreferredModelOverrideRaw = nil
            syncModelSelectionFromSettingsManager()
            return
        }
        sessionPreferredModelOverrideRaw = rawValue
        if _preferredModel != rawValue {
            _preferredModel = rawValue
        }
    }

    var contextBuilderModel: AIModel {
        AIModel.fromModelName(_contextBuilderModel) ?? preferredAIModel // Fallback if stored value is invalid
    }

    var contextBuilderModelName: String {
        get { _contextBuilderModel }
        set {
            _contextBuilderModel = newValue
            isDirty = true
            // Persist to workspace settings
            guard let workspaceID = currentWorkspaceID else { return }
            var settings = settingsManager.chatSettings(for: workspaceID)
            settings.contextBuilderModelRaw = newValue
            settingsManager.updateChatSettings(settings, commit: true)
        }
    }

    var targetFileEditFormat: FileEditFormat {
        if fileEditFormat == .none {
            return .none
        }
        if preferredAIModel.isModelCapableOfDiff {
            return fileEditFormat
        }
        return .whole
    }

    private func targetFileEditFormat(for model: AIModel) -> FileEditFormat {
        if fileEditFormat == .none { return .none }
        return model.isModelCapableOfDiff ? fileEditFormat : .whole
    }

    // MARK: - Model Settings

    var modelTemperature: Double {
        get { settingsManager.modelTemperature() }
        set {
            guard newValue != modelTemperature else { return }
            settingsManager.setModelTemperature(newValue, commit: true)
            handlePromptPackagingSettingChanged()
        }
    }

    var setModelTemperature: Bool {
        get { settingsManager.shouldSetModelTemperature() }
        set {
            guard newValue != setModelTemperature else { return }
            settingsManager.setShouldSetModelTemperature(newValue, commit: true)
            handlePromptPackagingSettingChanged()
        }
    }

    var customPlanningPrompt: String {
        get { settingsManager.customPlanningPrompt() }
        set {
            guard newValue != customPlanningPrompt else { return }
            settingsManager.setCustomPlanningPrompt(newValue, commit: true)
            handlePromptPackagingSettingChanged()
        }
    }

    // MARK: - File Tree Properties

    /// Workspace ID accessor
    var currentWorkspaceID: UUID? {
        fileManager.currentWorkspaceID
    }

    private var isSyncingSettings = false
    private var suppressPromptPackagingSettingInvalidation = false
    @Published private(set) var codeMapsGloballyDisabled: Bool = false

    // MARK: - Copy Context Settings (used by Agent copy/export operations)

    @Published var fileTreeOption: FileTreeOption = .auto {
        didSet {
            guard oldValue != fileTreeOption else { return }
            // Recompute file-tree tokens regardless of sync state
            tokenCountingViewModel.markDirty(.fileTree)
            if isSyncingSettings { return }
            guard let workspaceID = currentWorkspaceID else { return }

            var settings = settingsManager.copySettings(for: workspaceID)
            if settings.fileTreeOption != fileTreeOption {
                settings.fileTreeOption = fileTreeOption
                settingsManager.updateCopySettings(settings, commit: nil)
            }

            // NEW: If we're in Manual preset, persist manual snapshot immediately
            if currentCopyPreset().builtInKind == .manual {
                snapshotManualCopySettings(commit: true)
            }

            isDirty = true
        }
    }

    @Published var codeMapUsage: CodeMapUsage = .auto {
        didSet {
            guard oldValue != codeMapUsage else { return }

            // Recompute code-map blobs/tokens regardless of sync state
            tokenCountingViewModel.markDirty(.codeMap)

            if currentCopyPreset().builtInKind == .manual,
               workingCopyCustomizations.codeMapUsage != nil
            {
                workingCopyCustomizations = workingCopyCustomizations.removingCodeMapUsageOverride()
            }

            if !isSyncingSettings {
                guard let workspaceID = currentWorkspaceID else { return }
                var settings = settingsManager.copySettings(for: workspaceID)
                if settings.codeMapUsage != codeMapUsage {
                    settings.codeMapUsage = codeMapUsage
                    settingsManager.updateCopySettings(settings, commit: nil)
                }

                if currentCopyPreset().builtInKind == .manual {
                    snapshotManualCopySettings(commit: true)
                }

                isDirty = true
            }

            Task {
                await refreshCodeScanEnabledForEffectiveState()
            }
        }
    }

    @Published var gitDiffInclusionModeForCopy: GitDiffInclusionMode = .none {
        didSet {
            guard oldValue != gitDiffInclusionModeForCopy else { return }
            // Git-only light path: update diff tokens immediately
            tokenCountingViewModel.markGitDiffDirty()
            if !isSyncingSettings {
                guard let workspaceID = currentWorkspaceID else { return }
                var settings = settingsManager.copySettings(for: workspaceID)
                if settings.gitInclusion != gitDiffInclusionModeForCopy {
                    settings.gitInclusion = gitDiffInclusionModeForCopy
                    settingsManager.updateCopySettings(settings, commit: nil)
                }

                // NEW: Persist Manual snapshot immediately
                if currentCopyPreset().builtInKind == .manual {
                    snapshotManualCopySettings(commit: true)
                }

                isDirty = true
            }
            gitViewModel.gitDiffInclusionMode = gitDiffInclusionModeForCopy
        }
    }

    // MARK: - Chat Context Settings (used in Chat views)

    @Published var fileTreeOptionForChat: FileTreeOption = .auto {
        didSet {
            guard oldValue != fileTreeOptionForChat else { return }
            if isSyncingSettings { return }
            guard let workspaceID = currentWorkspaceID else { return }

            var settings = settingsManager.chatSettings(for: workspaceID)
            if settings.fileTreeOption != fileTreeOptionForChat {
                settings.fileTreeOption = fileTreeOptionForChat
                settingsManager.updateChatSettings(settings, commit: nil)
            }

            // NEW: If chat preset is Manual, persist snapshot immediately
            if currentChatPreset().id == ChatPreset.BuiltIn.manual.id {
                snapshotManualChatSettings(commit: true)
            }

            isDirty = true
        }
    }

    @Published var codeMapUsageForChat: CodeMapUsage = .auto {
        didSet {
            guard oldValue != codeMapUsageForChat else { return }

            // Always refresh codemap tokens when chat usage changes
            tokenCountingViewModel.markDirty(.codeMap)

            if isSyncingSettings { return }
            guard let workspaceID = currentWorkspaceID else { return }

            var settings = settingsManager.chatSettings(for: workspaceID)
            if settings.codeMapUsage != codeMapUsageForChat {
                settings.codeMapUsage = codeMapUsageForChat
                settingsManager.updateChatSettings(settings, commit: nil)
            }

            // NEW: Persist Manual snapshot immediately for chat Manual preset
            if currentChatPreset().id == ChatPreset.BuiltIn.manual.id {
                snapshotManualChatSettings(commit: true)
            }

            isDirty = true

            Task {
                await refreshCodeScanEnabledForEffectiveState()
            }
        }
    }

    @Published var gitDiffInclusionModeForChat: GitDiffInclusionMode = .none {
        didSet {
            guard oldValue != gitDiffInclusionModeForChat else { return }
            if isSyncingSettings { return }
            guard let workspaceID = currentWorkspaceID else { return }

            var settings = settingsManager.chatSettings(for: workspaceID)
            if settings.gitInclusion != gitDiffInclusionModeForChat {
                settings.gitInclusion = gitDiffInclusionModeForChat
                settingsManager.updateChatSettings(settings, commit: nil)
            }

            // NEW: Persist Manual snapshot immediately for chat Manual preset
            if currentChatPreset().id == ChatPreset.BuiltIn.manual.id {
                snapshotManualChatSettings(commit: true)
            }

            isDirty = true
        }
    }

    // MARK: - Auto-Switch to Manual Mode Wrapper Methods

    private func syncModelSelectionFromSettingsManager() {
        _planningModel = Self.modelRawAfterSettingsSync(
            currentRaw: _planningModel,
            persistedRaw: settingsManager.planningModelRaw()
        )
        if sessionPreferredModelOverrideRaw == nil {
            _preferredModel = Self.modelRawAfterSettingsSync(
                currentRaw: _preferredModel,
                persistedRaw: settingsManager.preferredComposeModelRaw()
            )
        }
    }

    static func modelRawAfterSettingsSync(currentRaw _: String, persistedRaw: String?) -> String {
        guard let persistedRaw else { return "" }
        return persistedRaw
    }

    func syncSettingsFromSettingsManager() {
        guard let workspaceID = currentWorkspaceID else { return }

        let copySettings = settingsManager.copySettings(for: workspaceID)
        let chatSettings = settingsManager.chatSettings(for: workspaceID)

        isSyncingSettings = true

        // NEW: Detect whether current presets are Manual
        let isCopyManual = (selectedCopyPresetID == BuiltInCopyPresets.manual.id)
        let isChatManual = (selectedChatPresetID == ChatPreset.BuiltIn.manual.id)

        // NEW: Prefer manual snapshots when in Manual; fallback to workspace defaults otherwise
        fileTreeOption = isCopyManual
            ? (copySettings.manualFileTreeOption ?? copySettings.fileTreeOption)
            : copySettings.fileTreeOption
        codeMapUsage = isCopyManual
            ? (copySettings.manualCodeMapUsage ?? copySettings.codeMapUsage)
            : copySettings.codeMapUsage

        // For non-Manual presets, apply the preset's git inclusion instead of persisted value
        if isCopyManual {
            gitDiffInclusionModeForCopy = copySettings.manualGitInclusion ?? copySettings.gitInclusion
        } else {
            // Apply the preset's git inclusion value
            let currentPreset = currentCopyPreset()
            let resolvedContext = resolvePromptContext(currentPreset, custom: nil)
            switch resolvedContext.gitInclusion {
            case .none: gitDiffInclusionModeForCopy = .none
            case .selected: gitDiffInclusionModeForCopy = .selectedFiles
            case .complete: gitDiffInclusionModeForCopy = .all
            }
        }

        fileTreeOptionForChat = isChatManual
            ? (chatSettings.manualFileTreeOption ?? chatSettings.fileTreeOption)
            : chatSettings.fileTreeOption
        codeMapUsageForChat = isChatManual
            ? (chatSettings.manualCodeMapUsage ?? chatSettings.codeMapUsage)
            : chatSettings.codeMapUsage
        planActMode = isChatManual
            ? (chatSettings.manualPlanActMode ?? chatSettings.planActMode)
            : chatSettings.planActMode

        // For non-Manual chat presets, apply the preset's git inclusion instead of persisted value
        if isChatManual {
            gitDiffInclusionModeForChat = chatSettings.manualGitInclusion ?? chatSettings.gitInclusion
        } else {
            // Apply the preset's git inclusion value
            let currentChatPreset = resolvedChatPreset(for: selectedChatPresetID ?? ChatPreset.BuiltIn.chat.id)
            let presetGitInclusion = currentChatPreset.gitInclusion ?? .none
            switch presetGitInclusion {
            case .none: gitDiffInclusionModeForChat = .none
            case .selected: gitDiffInclusionModeForChat = .selectedFiles
            case .complete: gitDiffInclusionModeForChat = .all
            }
        }
        _contextBuilderModel = chatSettings.contextBuilderModelRaw ?? ""

        // Sync Context Builder agent/model from global Context Builder settings (single source of truth)
        refreshAvailableAgentKinds()
        if let normalizedContextBuilder = resolvedPersistedContextBuilderSelection() {
            if Self.debugLoggingEnabled { print("[PromptVM] syncSettings - normalized context builder agent: \(normalizedContextBuilder.agent.rawValue)") }
            contextBuilderAgent = normalizedContextBuilder.agent
            contextBuilderAgentModelRaw = normalizedContextBuilder.modelRaw
            if Self.debugLoggingEnabled { print("[PromptVM] syncSettings - contextBuilderAgentModelRaw set to: \(contextBuilderAgentModelRaw)") }
        }

        // Sync model selection from the global settings store (may have been set by recommendation engine).
        syncModelSelectionFromSettingsManager()

        isSyncingSettings = false

        // NEW: pull persisted "restore previous preset" banner info
        lastNonManualCopyPresetID = copySettings.lastNonManualCopyPresetID
        lastNonManualChatPresetID = chatSettings.lastNonManualChatPresetID
        lastNonManualChatPresetName = chatSettings.lastNonManualChatPresetName ?? ""

        Task {
            await refreshCodeScanEnabledForEffectiveState()
        }
        gitViewModel.gitDiffInclusionMode = gitDiffInclusionModeForCopy
    }

    /// Updates fileTreeOption and auto-switches to Manual mode if needed
    func updateFileTreeOption(_ newValue: FileTreeOption) {
        // Check if we're in a non-manual preset
        if let currentID = selectedCopyPresetID,
           currentID != BuiltInCopyPresets.manual.id
        {
            // Switch to Manual without restoring prior manual overrides
            selectCopyPreset(BuiltInCopyPresets.manual.id, applySettings: false, restoreManualSnapshot: false)
        }

        // Now update the setting
        fileTreeOption = newValue
    }

    /// Updates codeMapUsage and auto-switches to Manual mode if needed
    func updateCodeMapUsage(_ newValue: CodeMapUsage) {
        // Check if we're in a non-manual preset
        if let currentID = selectedCopyPresetID,
           currentID != BuiltInCopyPresets.manual.id
        {
            // Switch to Manual without restoring prior manual overrides
            selectCopyPreset(BuiltInCopyPresets.manual.id, applySettings: false, restoreManualSnapshot: false)
        }

        // Now update the setting
        codeMapUsage = newValue
    }

    /// Updates gitDiffInclusionModeForCopy and auto-switches to Manual mode if needed
    func updateGitInclusion(_ newValue: GitDiffInclusionMode) {
        // Check if we're in a non-manual preset
        if let currentID = selectedCopyPresetID,
           currentID != BuiltInCopyPresets.manual.id
        {
            // Switch to Manual without restoring prior manual overrides
            selectCopyPreset(BuiltInCopyPresets.manual.id, applySettings: false, restoreManualSnapshot: false)
        }

        // Now update the setting
        gitDiffInclusionModeForCopy = newValue
    }

    /// Updates chat fileTreeOption and auto-switches to Manual mode if needed
    func updateFileTreeOptionForChat(_ newValue: FileTreeOption) {
        ensureManualPresetFor(context: .chat)

        fileTreeOptionForChat = newValue
    }

    /// Updates chat codeMapUsage and auto-switches to Manual mode if needed
    func updateCodeMapUsageForChat(_ newValue: CodeMapUsage) {
        ensureManualPresetFor(context: .chat)

        codeMapUsageForChat = newValue
    }

    /// Updates chat gitDiffInclusionMode and auto-switches to Manual mode if needed
    func updateGitInclusionForChat(_ newValue: GitDiffInclusionMode) {
        ensureManualPresetFor(context: .chat)

        gitDiffInclusionModeForChat = newValue
        gitViewModel.gitDiffInclusionMode = newValue
    }

    // MARK: - Git Diff Artifact Publishing

    /// Publishes git diff artifacts to _git_data/ based on current UI settings.
    /// Always creates a fresh snapshot tagged with the current tab ID.
    /// - Parameters:
    ///   - inclusionMode: Which files to include (selected or all)
    ///   - vsBranch: Optional branch to compare against (defaults to gitViewModel.selectedDiffBranch)
    ///   - publishMode: How detailed the artifacts should be (.quick, .standard, .deep)
    /// - Returns: The snapshot manifest
    @MainActor
    func publishGitDiffArtifacts(
        inclusionMode: GitDiffInclusionMode,
        vsBranch: String? = nil,
        publishMode: GitDiffPublishMode = .standard,
        contextLines: Int = 3,
        detectRenames: Bool = true
    ) async throws -> GitDiffSnapshotManifest {
        // Validate prerequisites
        guard let workspace = workspaceManager?.activeWorkspace else {
            throw GitArtifactPublishError.noActiveWorkspace
        }
        guard let gitRootPath = gitViewModel.gitRootPath else {
            throw GitArtifactPublishError.noGitRepository
        }
        guard inclusionMode != .none else {
            throw GitArtifactPublishError.noDiffModeSelected
        }

        let repoURL = URL(fileURLWithPath: gitRootPath)
        let effectiveBranch = vsBranch ?? gitViewModel.selectedDiffBranch
        let compareSpec: GitDiffCompareSpec = effectiveBranch.caseInsensitiveCompare("HEAD") == .orderedSame
            ? .uncommitted(base: effectiveBranch)
            : .uncommittedMergeBase(base: effectiveBranch)

        // Determine scope and selected paths
        let scope: GitDiffScope
        let selectedAbsolutePaths: [String]

        switch inclusionMode {
        case .none:
            throw GitArtifactPublishError.noDiffModeSelected
        case .all:
            scope = .all
            selectedAbsolutePaths = []
        case .selectedFiles:
            scope = .selected
            selectedAbsolutePaths = gitViewModel.selectedChangedAbsolutePathsForGitArtifacts()
            guard !selectedAbsolutePaths.isEmpty else {
                throw GitArtifactPublishError.noFilesSelected
            }
        }

        // Get workspace directory for storing artifacts
        guard let workspaceManager else {
            throw GitArtifactPublishError.noActiveWorkspace
        }
        let workspaceDirectory = workspaceManager.workspaceDirectory(for: workspace)
        let compareDisplay = compareSpec.displayString

        // Publish the artifacts
        let result = try await GitDiffSnapshotPublisher.shared.publish(
            workspaceDirectory: workspaceDirectory,
            repoURL: repoURL,
            mode: publishMode,
            compareSpec: compareSpec,
            compareDisplay: compareDisplay,
            compareInput: effectiveBranch,
            scope: scope,
            selectedAbsolutePaths: selectedAbsolutePaths,
            contextLines: contextLines,
            detectRenames: detectRenames,
            snapshotIDOverride: nil,
            tabID: activeComposeTabID
        )

        // Ensure _git_data is visible and refreshed
        await fileManager.ensureGitDataRootLoaded(workspace: workspace, workspaceManager: workspaceManager)
        await fileManager.flushPendingDeltas(aggressive: true)

        return result
    }

    // MARK: - Clipboard Properties

    @AppStorage("includeFolderDirectory") var _includeFolderDirectory: Bool = false
    @AppStorage("includeFileTreeInAIQuery") private var _includeFileTreeInAIQuery: Bool = true
    @AppStorage("includeSavedPromptsInClipboard") var includeSavedPromptsInClipboard: Bool = true
    @AppStorage("includeFilesInClipboard") var includeFilesInClipboard: Bool = true
    @AppStorage("includeUserPromptInClipboard") var includeUserPromptInClipboard: Bool = true
    var includeDatetimeInUserInstructions: Bool {
        get { settingsManager.includeDatetimeInUserInstructions() }
        set {
            guard newValue != includeDatetimeInUserInstructions else { return }
            settingsManager.setIncludeDatetimeInUserInstructions(newValue, commit: true)
            handlePromptPackagingSettingChanged()
        }
    }

    @AppStorage("spellCheckInstructions") var spellCheckInstructions: Bool = false

    var includeFolderDirectory: Bool {
        get { _includeFolderDirectory }
        set {
            if _includeFolderDirectory != newValue {
                _includeFolderDirectory = newValue
                isDirty = true
            }
        }
    }

    // MARK: - Token Counting

    /// Keep token updates isolated from PromptViewModel's objectWillChange.
    let tokenCountingViewModel = TokenCountingViewModel()

    /// Copy/Chat Preset Selection
    static var defaultCopyPresetID: UUID {
        BuiltInCopyPresets.standard.id
    }

    @Published var selectedCopyPresetID: UUID? = BuiltInCopyPresets.standard.id
    @Published var selectedChatPresetID: UUID? = ChatPreset.BuiltIn.chat.id
    @Published var workingCopyCustomizations: CopyCustomizations = .init()

    /// Track last non-manual copy preset for undo functionality
    @Published var lastNonManualCopyPresetID: UUID? = BuiltInCopyPresets.standard.id

    // --- NEW: persisted, per-workspace last non-manual chat preset ---
    @Published var lastNonManualChatPresetID: UUID? = nil
    @Published var lastNonManualChatPresetName: String = ""

    // Manual-by-intent support
    @Published private var isApplyingPresetOverrides = false
    private var isApplyingChatPreset = false

    struct ChatPromptEntriesCacheKey: Hashable {
        let codeMapUsage: CodeMapUsage
        let selectionVersion: UInt64
        let slicesVersion: UInt64
        let autoCodemapVersion: UInt64
        let fileAPIsVersion: UInt64
    }

    private struct ChatPresetTokenBaselineKey: Equatable {
        let id: UUID
        let mode: ChatPresetMode
        let modelPresetName: String?
        let fileTreeMode: FileTreeOption?
        let codeMapUsage: CodeMapUsage?
        let gitInclusion: GitInclusion?
        let storedPromptIds: [UUID]
        let useStoredPromptsAsSystem: Bool
    }

    private struct PromptContextTokenBaselineKey: Equatable {
        let includeFiles: Bool
        let includeUserPrompt: Bool
        let includeMetaPrompts: Bool
        let includeFileTree: Bool
        let fileTreeMode: FileTreeOption
        let codeMapUsage: CodeMapUsage
        let gitInclusion: GitInclusion
        let storedPromptIds: [UUID]
    }

    private struct StoredPromptTokenBaselineKey: Equatable {
        let id: UUID
        let title: String
        let content: String
        let isUserEdited: Bool
    }

    private struct RootTokenBaselineKey: Equatable {
        let id: UUID
        let fullPath: String
        let name: String
        let isSystemRoot: Bool
    }

    private struct ChatContextTokenBaselineCacheKey: Equatable {
        let workspaceID: UUID?
        let selectedChatPresetID: UUID?
        let chatPreset: ChatPresetTokenBaselineKey
        let resolvedContext: PromptContextTokenBaselineKey
        let fileTreeOptionForChat: FileTreeOption
        let codeMapUsageForChat: CodeMapUsage
        let gitDiffInclusionModeForChat: GitDiffInclusionMode
        let codeMapsGloballyDisabled: Bool
        let filePathDisplayOption: FilePathDisplay
        let selectedFilesSortMethod: SortMethod
        let fileTreeSortMethod: SortMethod
        let onlyIncludeRootsWithSelectedFiles: Bool
        let includeDatetimeInUserInstructions: Bool
        let promptSectionsOrder: [PromptSection]
        let disabledPromptSections: [PromptSection]
        let duplicateUserInstructionsAtTop: Bool
        let selectedPromptIDsForChat: [UUID]
        let hasManualChatPromptSelection: Bool
        let storedPrompts: [StoredPromptTokenBaselineKey]
        let hierarchyGenerationSignature: UInt64
        let rootOrder: [RootTokenBaselineKey]
        let selectionVersion: UInt64
        let slicesVersion: UInt64
        let autoCodemapVersion: UInt64
        let fileAPIsVersion: UInt64
        let fileSystemDeltaVersion: UInt64
    }

    private struct ChatContextTokenBaselineCache {
        let key: ChatContextTokenBaselineCacheKey
        let baseTokensWithoutPromptText: Int
        /// The base token value only safely supports prompt deltas if it was derived
        /// from a payload that actually contained a user-instructions prompt block.
        let supportsPromptTextDeltas: Bool
        /// Exact value for the empty-prompt shape when the cold miss observed it.
        let emptyPromptTokenCount: Int?
    }

    var chatPromptEntriesCache: (key: ChatPromptEntriesCacheKey, entries: [PromptFileEntry])?
    var chatCodemapFileAPIs: [FileAPI] = []
    var chatSelectionVersion: UInt64 = 0
    var chatSlicesVersion: UInt64 = 0
    var chatAutoCodemapVersion: UInt64 = 0
    var chatFileAPIsVersion: UInt64 = 0
    private var chatFileSystemDeltaVersion: UInt64 = 0
    private var chatContextTokenBaselineCache: ChatContextTokenBaselineCache?

    // MARK: - Computed Properties for Token Counting (Legacy Support)

    var tokenCount: String {
        tokenCountingViewModel.tokenCount
    }

    var tokenCountFilesOnly: String {
        tokenCountingViewModel.tokenCountFilesOnly
    }

    var charCount: Int {
        tokenCountingViewModel.charCount
    }

    var totalTokenCount: Int {
        tokenCountingViewModel.totalTokenCount
    }

    var totalTokenCountFilesOnly: Int {
        tokenCountingViewModel.totalTokenCountFilesOnly
    }

    var folderTokenInfo: [String: TokenInfo] {
        tokenCountingViewModel.folderTokenInfo
    }

    var fileTokenInfo: [UUID: TokenInfo] {
        tokenCountingViewModel.fileTokenInfo
    }

    var codeMapFileCount: Int {
        tokenCountingViewModel.codeMapFileCount
    }

    var codeMapTokenCount: Int {
        tokenCountingViewModel.codeMapTokenCount
    }

    var cachedFileAPIs: [FileAPI] {
        tokenCountingViewModel.cachedFileAPIs
    }

    var fileTreeContent: String {
        tokenCountingViewModel.fileTreeContent
    }

    var codeMapContent: String {
        tokenCountingViewModel.codeMapContent
    }

    var scannedLanguages: Set<LanguageType> {
        tokenCountingViewModel.scannedLanguages
    }

    var combinedTreeAndCodeMapContent: String {
        tokenCountingViewModel.combinedTreeAndCodeMapContent
    }

    var tokenCalculationCompletedPublisher: PassthroughSubject<Void, Never> {
        tokenCountingViewModel.tokenCalculationCompletedPublisher
    }

    var fileTreeTokenCount: Double {
        tokenCountingViewModel.fileTreeTokenCount
    }

    var tooManyFileTreeTokens: Bool {
        tokenCountingViewModel.tooManyFileTreeTokens
    }

    var gitDiffTokenCount: Int {
        tokenCountingViewModel.gitDiffTokenCount
    }

    var gitDiffTokenCountString: String {
        tokenCountingViewModel.gitDiffTokenCountString
    }

    var tokenBreakdownDescription: String {
        tokenCountingViewModel.tokenBreakdownDescription
    }

    // Codemap coverage meta-injection removed; handled by the Discover system prompt.

    // MARK: - Prompt Management Properties

    @Published var storedPrompts: [StoredPrompt] = []
    @Published var metaInstructions: [MetaInstruction] = []
    @Published var metaInstructionsForChat: [MetaInstruction] = []
    @Published var selectedInstructionsText: String = "" {
        didSet {
            // Any change to resolved instruction text should update totals
            if oldValue != selectedInstructionsText {
                tokenCountingViewModel.markInstructionsDirty()
            }
        }
    }

    @Published var selectedPromptIDs: Set<UUID> = [] {
        didSet {
            // Maintain a stable ordering for persistence, reduce unnecessary diffs
            selectedPromptIDsArraySnapshot = selectedPromptIDs.sorted { $0.uuidString < $1.uuidString }
            workspaceManager?.markWorkspaceDirty()
            updateActiveTabDirtyState()
            // Changing stored prompt selection changes instruction tokens
            tokenCountingViewModel.markInstructionsDirty()
        }
    }

    @Published var selectedPromptIDsForChat: Set<UUID> = []
    @Published private(set) var hasManualCopyPromptSelection = false
    @Published private(set) var hasManualChatPromptSelection = false

    /// Cached, stable-ordered snapshot to avoid Set→Array conversions on hot paths
    private var selectedPromptIDsArraySnapshot: [UUID] = []

    var architectPromptID: UUID {
        architectPrompt.id
    }

    var engineerPromptID: UUID {
        engineerPrompt.id
    }

    var mcpAgentPromptID: UUID {
        mcpAgentPrompt.id
    }

    var mcpPairProgramPromptID: UUID {
        mcpPairProgramPrompt.id
    }

    var reviewPromptID: UUID {
        reviewPrompt.id
    }

    private var builtInPromptIDs: Set<UUID> {
        Set([
            architectPrompt.id,
            engineerPrompt.id,
            mcpPairProgramPrompt.id,
            mcpAgentPrompt.id,
            reviewPrompt.id
        ])
    }

    /// Canonical built-in prompts keyed by ID, for auto-upgrade logic.
    private var builtInCanonical: [UUID: StoredPrompt] {
        [
            architectPrompt.id: architectPrompt,
            engineerPrompt.id: engineerPrompt,
            mcpPairProgramPrompt.id: mcpPairProgramPrompt,
            mcpAgentPrompt.id: mcpAgentPrompt,
            reviewPrompt.id: reviewPrompt
        ]
    }

    /// Exact previous canonical built-in prompt variants.
    /// If a persisted built-in matches one of these exactly, it was never user-edited
    /// and is safe to auto-upgrade to the current canonical version.
    private var previousCanonicalBuiltIns: [UUID: [StoredPrompt]] {
        [
            architectPrompt.id: [previousArchitectPromptV1, previousArchitectPromptV2, previousArchitectPromptV3, previousArchitectPromptV4]
        ]
    }

    /// Fingerprint phrase sets for known previous canonical versions of built-in prompts.
    /// Each entry is a list of phrase groups — a prompt matches if ALL phrases in ANY single group are present.
    /// Use fingerprints only when exact previous canonical content is not available.
    private let previousCanonicalFingerprints: [UUID: [[String]]] = [
        UUID(uuidString: "8E81AAC2-79CE-4897-A59E-EFD81EEBB7E9")!: [
            // Architect prompt v1 — these phrases only appear in the original unedited version
            [
                "Analyze the requested changes and break them down into clear, actionable steps",
                "Create a detailed implementation plan that includes:",
                "Highlight critical architectural decisions that need to be made"
            ],
            // Architect prompt v2 — these phrases identify the v2 canonical version
            [
                "Recommend a design with disciplined ambition",
                "Handle ambiguity for one-shot planning",
                "Prefer crisp architectural reasoning over long general advice"
            ],
            // Architect prompt v3 — the canonical version immediately before the Mar 11, 2026 wording refresh
            [
                "Use illustrative snippets, type signatures, enum cases, data shapes, or pseudocode",
                "The type name, kind (struct/class/enum/protocol/actor), and why that kind.",
                "Specify actor isolation, @MainActor requirements, Sendable conformances, or queue discipline"
            ],
            // Architect prompt v4 — language-agnostic version before verbosity reduction
            [
                "Use illustrative snippets, interface shapes, sample signatures, state/data shapes, or pseudocode",
                "The name, kind (for example: class, interface, enum, record, service, module, controller)",
                "Trade-offs and alternatives"
            ]
        ],
        // Review prompt v1 — these phrases only appear in the original unedited version
        UUID(uuidString: "D7F1B2E4-3C5A-6B8D-CF8E-1F5D0E2A4C6B")!: [
            [
                "Acknowledge what's done particularly well",
                "Are the commit boundaries logical?"
            ]
        ]
    ]

    var builtInStoredPrompts: [StoredPrompt] {
        storedPrompts.filter { builtInPromptIDs.contains($0.id) }
    }

    var customStoredPrompts: [StoredPrompt] {
        storedPrompts.filter { !builtInPromptIDs.contains($0.id) }
    }

    var sendPromptAction: (() -> Void)?

    /// Our two default prompts, each with a fixed UUID so we don't accidentally re-add them if the user modifies or deletes them.
    private let previousArchitectPromptV1 = StoredPrompt(
        id: UUID(uuidString: "8E81AAC2-79CE-4897-A59E-EFD81EEBB7E9")!,
        title: "[Architect]",
        content: """
        You are a senior software architect specializing in code design and implementation planning. Your role is to:

        1. Analyze the requested changes and break them down into clear, actionable steps
        2. Create a detailed implementation plan that includes:
           - Files that need to be modified
           - Specific code sections requiring changes
           - New functions, methods, or classes to be added
           - Dependencies or imports to be updated
           - Data structure modifications
           - Interface changes
           - Configuration updates

        For each change:
        - Describe the exact location in the code where changes are needed
        - Explain the logic and reasoning behind each modification
        - Provide example signatures, parameters, and return types
        - Note any potential side effects or impacts on other parts of the codebase
        - Highlight critical architectural decisions that need to be made

        You may include short code snippets to illustrate specific patterns, signatures, or structures, but do not implement the full solution.

        Focus solely on the technical implementation plan - exclude testing, validation, and deployment considerations unless they directly impact the architecture.

        Please proceed with your analysis based on the following <user instructions>
        """
    )

    private let previousArchitectPromptV2 = StoredPrompt(
        id: UUID(uuidString: "8E81AAC2-79CE-4897-A59E-EFD81EEBB7E9")!,
        title: "[Architect]",
        content: """
        Your job is to:
        1. Analyze the requested change against the provided code and identify the relevant existing architecture, constraints, and extension points.
        2. Recommend the best implementation approach, including when to prefer a targeted change versus a broader refactor.
        3. Explain what should change, where it should change, and why, with enough precision for implementation to follow cleanly.

        Constraints:
        - Do not write production code, patches, diffs, or copy-paste-ready implementations.
        - Do not respond as though you are executing the change.
        - Stay in analysis and architecture mode only.
        - Use small snippets, signatures, data shapes, or pseudocode when they communicate the design more clearly than prose. Keep them illustrative and partial, not implementation-complete.
        - If the user asks for code, keep the response at the design level unless they explicitly switch to an implementation step.

        Planning standards:
        1. Start with current-state analysis:
           - Identify the existing responsibilities, abstractions, data flow, and dependencies relevant to the request.
           - Call out existing code that should be extended or reused instead of duplicated.
           - Note meaningful constraints from current APIs, state ownership, persistence, concurrency, or UI boundaries.

        2. Recommend a design with disciplined ambition:
           - Be thorough enough to solve the actual problem, not just the most visible symptom.
           - Prefer the smallest change that cleanly solves the problem.
           - Recommend a broader refactor when the smaller option would create duplication, awkward layering, or architectural debt.
           - Explicitly weigh implementation cost, migration risk, and added complexity against the expected payoff.

        3. For each significant change, be concrete about:
           - The files, types, or subsystems likely to change.
           - The exact areas of responsibility that need to move, expand, or be simplified.
           - Interface, model, state-flow, lifecycle, and dependency changes, described precisely without writing full declarations.
           - Side effects, compatibility concerns, and any places where sequencing matters.

        4. For algorithmic or logic-heavy work, go deep:
           - Describe the algorithm, control flow, key invariants, and data structures.
           - Cover edge cases, failure modes, concurrency concerns, and performance implications when relevant.
           - Explain why this design is preferable to the most plausible alternatives.

        5. Keep the design testable without turning the answer into a test plan:
           - Prefer seams, dependency boundaries, and responsibilities that can be verified in isolation.
        	- Mention testability where it materially affects the architecture, but do not provide a test matrix unless the user explicitly asks for one.

        6. Avoid unnecessary complexity:
           - Do not add layers, abstractions, or indirection without a clear benefit.
           - Avoid duplicating functionality or creating parallel code paths.
           - Reuse existing patterns unless those patterns are themselves part of the problem.

        7. Handle ambiguity for one-shot planning:
        	- If the request is ambiguous, make the most reasonable assumptions, state them explicitly, and note the most important alternative interpretations that would materially change the architecture.

        Output structure:
        1. Brief summary
        2. Current-state analysis
        3. Proposed architecture
        4. File/component impact
        5. Algorithm / logic deep dive (include when the change involves non-trivial control flow, state transitions, data transformations, concurrency, or performance tradeoffs)
        6. Trade-offs and alternatives
        7. Risks / migration notes
        8. Recommended implementation order

        Response style:
        - Be specific to the provided code, not generic.
        - Make assumptions explicit.
        - Call out unknowns that should be validated during implementation.
        - Prefer crisp architectural reasoning over long general advice.

        Please proceed with your analysis based on the following <user instructions>
        """
    )

    private let previousArchitectPromptV3 = StoredPrompt(
        id: UUID(uuidString: "8E81AAC2-79CE-4897-A59E-EFD81EEBB7E9")!,
        title: "[Architect]",
        content: """
        You are producing an implementation-ready technical plan. The implementer will work from your plan without asking clarifying questions, so every design decision must be resolved, every touched component must be identified, and every behavioral change must be specified precisely.

        Your job:
        1. Analyze the requested change against the provided code — identify the relevant architecture, constraints, data flow, and extension points.
        2. Decide whether this is best solved by a targeted change or a broader refactor, and justify that decision.
        3. Produce a plan detailed enough that an engineer can implement it file-by-file without making design decisions of their own.

        Hard constraints:
        - Do not write production code, patches, diffs, or copy-paste-ready implementations.
        - Stay in analysis and architecture mode only.
        - Use illustrative snippets, type signatures, enum cases, data shapes, or pseudocode when they communicate the design more precisely than prose. Keep them partial — enough to remove ambiguity, not enough to copy-paste.

        ─── ANALYSIS ───

        Current-state analysis (always include):
        - Map the existing responsibilities, type relationships, ownership, data flow, and mutation points relevant to the request.
        - Identify existing code that should be reused or extended — never duplicate what already exists without justification.
        - Note hard constraints: API contracts, protocol conformances, state ownership rules, thread/actor isolation, persistence schemas, UI update mechanisms.
        - When multiple subsystems interact, trace the call chain end-to-end and identify each transformation boundary.

        ─── DESIGN ───

        Design standards — apply uniformly to every aspect of the plan:

        1. New and modified types: For each, specify:
           - The type name, kind (struct/class/enum/protocol/actor), and why that kind.
           - Properties with their types, mutability, and ownership semantics.
           - Key method signatures with parameter types, return types, and whether they are throwing/async.
           - Protocol conformances or inheritance.
           - For enums: all cases with associated values.
           - Where the type lives (file path) and who owns/creates instances.

        2. State and data flow: For each state change the plan introduces or modifies:
           - What triggers the change (user action, callback, notification, timer, stream event).
           - The exact path the data travels: source → transformations → destination.
           - Thread/actor/queue context at each step.
           - How downstream consumers observe the change (published property, delegate, notification, binding, callback).
           - What happens if the change arrives out of order, is duplicated, or is dropped.

        3. API and interface changes: For each modified public/internal interface:
           - The before and after signatures (or new signature if additive).
           - Every call site that must be updated, grouped by file.
           - Backward-compatibility strategy if the interface is used by external consumers or persisted data.

        4. Persistence and serialization: When the plan touches stored data:
           - Schema changes with exact field names, types, and defaults.
           - Migration strategy: how existing data is read, transformed, and re-persisted.
           - What happens when new code reads old data and when old code reads new data (if rollback is possible).

        5. Concurrency and lifecycle:
           - Specify actor isolation, @MainActor requirements, Sendable conformances, or queue discipline for each new/modified component.
           - Identify potential races, retain cycles, or lifecycle mismatches introduced by the change.
           - When operations are async, specify cancellation behavior and what state is left on cancellation.

        6. Error handling and edge cases:
           - For each operation that can fail, specify what errors are possible and how they propagate.
           - Describe degraded-mode behavior: what the user sees, what state is preserved, what recovery is available.
           - Identify boundary conditions: empty collections, nil optionals, first-run states, interrupted operations.

        7. Algorithmic and logic-heavy work (include whenever the change involves non-trivial control flow, state machines, data transformations, or performance-sensitive paths):
           - Describe the algorithm step-by-step: inputs, outputs, invariants, and data structures.
           - Cover edge cases, failure modes, and performance characteristics (time/space complexity if relevant).
           - Explain why this approach over the most plausible alternatives.

        8. Avoid unnecessary complexity:
           - Do not add layers, abstractions, or indirection without a concrete benefit identified in the plan.
           - Do not create parallel code paths — unify where possible.
           - Reuse existing patterns unless those patterns are themselves the problem.

        ─── OUTPUT ───

        Structure your response as:

        1. **Summary** — One paragraph: what changes, why, and the high-level approach.

        2. **Current-state analysis** — How the relevant code works today. Trace the data/control flow end-to-end. Identify what is reusable and what is blocking.

        3. **Design** — The core of the plan. Apply every applicable standard from above. Organize by logical component or subsystem, not by standard number. Each component section should cover types, state flow, interfaces, persistence, concurrency, and error handling as relevant to that component.

        4. **File-by-file impact** — For every file that changes, list:
           - What changes (added/modified/removed types, methods, properties).
           - Why (which design decision drives this change).
           - Dependencies on other changes in this plan (ordering constraints).

        5. **Trade-offs and alternatives** — What was considered and rejected, and why. Include the cost/benefit of the chosen approach vs. the runner-up.

        6. **Risks and migration** — Breaking changes, rollback concerns, data migration, feature flags, and incremental delivery strategy if the change is large.

        7. **Implementation order** — A numbered sequence of steps. Each step should be independently compilable and testable where possible. Call out steps that must be atomic (landed together).

        Response discipline:
        - Be specific to the provided code — reference actual type names, file paths, method names, and property names.
        - Make every assumption explicit.
        - Flag unknowns that must be validated during implementation, with a suggested validation approach.
        - When a design decision has a non-obvious rationale, explain it in one sentence.
        - Do not pad with generic advice. Every sentence should convey information the implementer needs.

        Please proceed with your analysis based on the following <user instructions>
        """
    )

    private let previousArchitectPromptV4 = StoredPrompt(
        id: UUID(uuidString: "8E81AAC2-79CE-4897-A59E-EFD81EEBB7E9")!,
        title: "[Architect]",
        content: """
        You are producing an implementation-ready technical plan. The implementer will work from your plan without asking clarifying questions, so every design decision must be resolved, every touched component must be identified, and every behavioral change must be specified precisely.

        Your job:
        1. Analyze the requested change against the provided code — identify the relevant architecture, constraints, data flow, and extension points.
        2. Decide whether this is best solved by a targeted change or a broader refactor, and justify that decision.
        3. Produce a plan detailed enough that an engineer can implement it file-by-file without making design decisions of their own.

        Hard constraints:
        - Do not write production code, patches, diffs, or copy-paste-ready implementations.
        - Stay in analysis and architecture mode only.
        - Use illustrative snippets, interface shapes, sample signatures, state/data shapes, or pseudocode when they communicate the design more precisely than prose. Keep them partial — enough to remove ambiguity, not enough to copy-paste.

        ─── ANALYSIS ───

        Current-state analysis (always include):
        - Map the existing responsibilities, type relationships, ownership, data flow, and mutation points relevant to the request.
        - Identify existing code that should be reused or extended — never duplicate what already exists without justification.
        - Note hard constraints: API contracts, protocol conformances, state ownership rules, thread/actor isolation, persistence schemas, UI update mechanisms.
        - When multiple subsystems interact, trace the call chain end-to-end and identify each transformation boundary.

        ─── DESIGN ───

        Design standards — apply uniformly to every aspect of the plan:

        1. New and modified components/types: For each, specify:
           - The name, kind (for example: class, interface, enum, record, service, module, controller), and why that kind fits the codebase and language.
           - The fields/properties/state it owns, including data shape, mutability, and ownership/lifecycle semantics.
           - Key callable interfaces or signatures, including inputs, outputs, and whether execution is synchronous/asynchronous or can fail.
           - Contracts it implements, extends, composes with, or depends on.
           - For closed sets of variants (for example enums, tagged unions, discriminated unions): all cases/variants and any attached data.
           - Where the component lives (file path) and who creates/owns its instances.

        2. State and data flow: For each state change the plan introduces or modifies:
           - What triggers the change (user action, callback, notification, timer, stream event).
           - The exact path the data travels: source → transformations → destination.
           - Thread/actor/queue context at each step.
           - How downstream consumers observe the change (published property, delegate, notification, binding, callback).
           - What happens if the change arrives out of order, is duplicated, or is dropped.

        3. API and interface changes: For each modified public/internal interface:
           - The before and after signatures (or new signature if additive).
           - Every call site that must be updated, grouped by file.
           - Backward-compatibility strategy if the interface is used by external consumers or persisted data.

        4. Persistence and serialization: When the plan touches stored data:
           - Schema changes with exact field names, types, and defaults.
           - Migration strategy: how existing data is read, transformed, and re-persisted.
           - What happens when new code reads old data and when old code reads new data (if rollback is possible).

        5. Concurrency and lifecycle:
           - Specify the execution model and safety boundaries for each new/modified component: thread affinity, event-loop/runtime constraints, isolation boundaries, queue/worker discipline, or thread-safety expectations as applicable.
           - Identify potential races, leaked references/resources, or lifecycle mismatches introduced by the change.
           - When operations are asynchronous, specify cancellation/abort behavior and what state remains after interruption.

        6. Error handling and edge cases:
           - For each operation that can fail, specify what failures are possible and how they propagate.
           - Describe degraded-mode behavior: what the user sees, what state is preserved, what recovery is available.
           - Identify boundary conditions: empty collections, missing/null/optional values, first-run states, interrupted operations.

        7. Algorithmic and logic-heavy work (include whenever the change involves non-trivial control flow, state machines, data transformations, or performance-sensitive paths):
           - Describe the algorithm step-by-step: inputs, outputs, invariants, and data structures.
           - Cover edge cases, failure modes, and performance characteristics (time/space complexity if relevant).
           - Explain why this approach over the most plausible alternatives.

        8. Avoid unnecessary complexity:
           - Do not add layers, abstractions, or indirection without a concrete benefit identified in the plan.
           - Do not create parallel code paths — unify where possible.
           - Reuse existing patterns unless those patterns are themselves the problem.

        ─── OUTPUT ───

        Structure your response as:

        1. **Summary** — One paragraph: what changes, why, and the high-level approach.

        2. **Current-state analysis** — How the relevant code works today. Trace the data/control flow end-to-end. Identify what is reusable and what is blocking.

        3. **Design** — The core of the plan. Apply every applicable standard from above. Organize by logical component or subsystem, not by standard number. Each component section should cover types, state flow, interfaces, persistence, concurrency, and error handling as relevant to that component.

        4. **File-by-file impact** — For every file that changes, list:
           - What changes (added/modified/removed types, methods, properties).
           - Why (which design decision drives this change).
           - Dependencies on other changes in this plan (ordering constraints).

        5. **Trade-offs and alternatives** — What was considered and rejected, and why. Include the cost/benefit of the chosen approach vs. the runner-up.

        6. **Risks and migration** — Breaking changes, rollback concerns, data migration, feature flags, and incremental delivery strategy if the change is large.

        7. **Implementation order** — A numbered sequence of steps. Each step should be independently compilable and testable where possible. Call out steps that must be atomic (landed together).

        Response discipline:
        - Be specific to the provided code — reference actual type names, file paths, method names, and property names.
        - Make every assumption explicit.
        - Flag unknowns that must be validated during implementation, with a suggested validation approach.
        - When a design decision has a non-obvious rationale, explain it in one sentence.
        - Do not pad with generic advice. Every sentence should convey information the implementer needs.

        Please proceed with your analysis based on the following <user instructions>
        """
    )

    let architectPrompt = StoredPrompt(
        id: UUID(uuidString: "8E81AAC2-79CE-4897-A59E-EFD81EEBB7E9")!,
        title: "[Architect]",
        content: """
        You are producing an implementation-ready technical plan. The implementer will work from your plan without asking clarifying questions, so every design decision must be resolved, every touched component must be identified, and every behavioral change must be specified precisely.

        Your job:
        1. Analyze the requested change against the provided code — identify the relevant architecture, constraints, data flow, and extension points.
        2. Decide whether this is best solved by a targeted change or a broader refactor, and justify that decision.
        3. Produce a plan detailed enough that an engineer can implement it file-by-file without making design decisions of their own.

        Hard constraints:
        - Do not write production code, patches, diffs, or copy-paste-ready implementations.
        - Stay in analysis and architecture mode only.
        - Use illustrative snippets, interface shapes, sample signatures, state/data shapes, or pseudocode when they communicate the design more precisely than prose. Keep them partial — enough to remove ambiguity, not enough to copy-paste.
        - Scale your response to the complexity of the request. Small, localized changes need short plans; only expand sections for changes that genuinely require the detail.

        ─── ANALYSIS ───

        Current-state analysis (always include):
        - Map the existing responsibilities, type relationships, ownership, data flow, and mutation points relevant to the request.
        - Identify existing code that should be reused or extended — never duplicate what already exists without justification.
        - Note hard constraints: API contracts, protocol conformances, state ownership rules, thread/actor isolation, persistence schemas, UI update mechanisms.
        - When multiple subsystems interact, trace the call chain end-to-end and identify each transformation boundary.

        ─── DESIGN ───

        Design standards — address only the standards relevant to the change; skip sections that don't apply:

        1. New and modified components/types: For each, specify:
           - The name, kind (for example: class, interface, enum, record, service, module, controller), and why that kind fits the codebase and language.
           - The fields/properties/state it owns, including data shape, mutability, and ownership/lifecycle semantics.
           - Key callable interfaces or signatures, including inputs, outputs, and whether execution is synchronous/asynchronous or can fail.
           - Contracts it implements, extends, composes with, or depends on.
           - For closed sets of variants (for example enums, tagged unions, discriminated unions): all cases/variants and any attached data.
           - Where the component lives (file path) and who creates/owns its instances.

        2. State and data flow: For each state change the plan introduces or modifies:
           - What triggers the change (user action, callback, notification, timer, stream event).
           - The exact path the data travels: source → transformations → destination.
           - Thread/actor/queue context at each step.
           - How downstream consumers observe the change (published property, delegate, notification, binding, callback).
           - What happens if the change arrives out of order, is duplicated, or is dropped.

        3. API and interface changes: For each modified public/internal interface:
           - The before and after signatures (or new signature if additive).
           - Every call site that must be updated, grouped by file.
           - Backward-compatibility strategy if the interface is used by external consumers or persisted data.

        4. Persistence and serialization: When the plan touches stored data:
           - Schema changes with exact field names, types, and defaults.
           - Migration strategy: how existing data is read, transformed, and re-persisted.
           - What happens when new code reads old data and when old code reads new data (if rollback is possible).

        5. Concurrency and lifecycle:
           - Specify the execution model and safety boundaries for each new/modified component: thread affinity, event-loop/runtime constraints, isolation boundaries, queue/worker discipline, or thread-safety expectations as applicable.
           - Identify potential races, leaked references/resources, or lifecycle mismatches introduced by the change.
           - When operations are asynchronous, specify cancellation/abort behavior and what state remains after interruption.

        6. Error handling and edge cases:
           - For each operation that can fail, specify what failures are possible and how they propagate.
           - Describe degraded-mode behavior: what the user sees, what state is preserved, what recovery is available.
           - Identify boundary conditions: empty collections, missing/null/optional values, first-run states, interrupted operations.

        7. Algorithmic and logic-heavy work (include whenever the change involves non-trivial control flow, state machines, data transformations, or performance-sensitive paths):
           - Describe the algorithm step-by-step: inputs, outputs, invariants, and data structures.
           - Cover edge cases, failure modes, and performance characteristics (time/space complexity if relevant).
           - Explain why this approach over the most plausible alternatives.

        8. Avoid unnecessary complexity:
           - Do not add layers, abstractions, or indirection without a concrete benefit identified in the plan.
           - Do not create parallel code paths — unify where possible.
           - Reuse existing patterns unless those patterns are themselves the problem.

        ─── OUTPUT ───

        Structure your response as:

        1. **Summary** — One paragraph: what changes, why, and the high-level approach.

        2. **Current-state analysis** — How the relevant code works today. Trace the data/control flow end-to-end. Identify what is reusable and what is blocking.

        3. **Design** — The core of the plan. Apply every applicable standard from above. Organize by logical component or subsystem, not by standard number. Each component section should cover types, state flow, interfaces, persistence, concurrency, and error handling as relevant to that component.

        4. **File-by-file impact** — For every file that changes, list:
           - What changes (added/modified/removed types, methods, properties).
           - Why (which design decision drives this change).
           - Dependencies on other changes in this plan (ordering constraints).

        5. **Risks and migration** — Include only when the change introduces breaking changes, data migration, or rollback concerns. Omit for additive or non-breaking work.

        6. **Implementation order** — A numbered sequence of steps. Each step should be independently compilable and testable where possible. Call out steps that must be atomic (landed together).

        Response discipline:
        - Be specific to the provided code — reference actual type names, file paths, method names, and property names.
        - Make every assumption explicit.
        - Flag unknowns that must be validated during implementation, with a suggested validation approach.
        - When a design decision has a non-obvious rationale, explain it in one sentence.
        - Do not pad with generic advice. Every sentence should convey information the implementer needs.

        Please proceed with your analysis based on the following <user instructions>
        """
    )

    private let engineerPrompt = StoredPrompt(
        id: UUID(uuidString: "4798D902-CC16-4B5B-8859-27CCF93151BC")!,
        title: "[Engineer]",
        content: """
        You are a senior software engineer whose role is to provide clear, actionable code changes. For each edit required:

        1. Specify locations and changes:
           - File path/name
           - Function/class being modified
           - The type of change (add/modify/remove)

        2. Show complete code for:
           - Any modified functions (entire function)
           - New functions or methods
           - Changed class definitions
           - Modified configuration blocks
           Only show code units that actually change.

        3. Format all responses as:

           File: path/filename.ext
           Change: Brief description of what's changing
           ```language
           [Complete code block for this change]
           ```

        You only need to specify the file and path for the first change in a file, and split the rest into separate codeblocks.
        """
    )

    private let mcpPairProgramPrompt = StoredPrompt(
        id: UUID(uuidString: "A7E8F2C1-3D5B-4E9A-BC6D-8F2A7C9E1D3B")!,
        title: "[MCP: Pair Program]",
        content: """
        You are a pair programming assistant that guides implementation through strategic use of MCP chat tools. Your role is to:

        1. **Understanding the Codebase**:
        	- Use `get_file_tree` to understand the directory structure
        	- Use `file_search` as your primary all-in-one flexible tool to find anything across all open folders in the workspace
        	- Prefer these MCP tools over generic file exploration

        2. **Context Preparation**:
        	- Read and understand the user's instructions and supplied context
        	- Use `manage_selection` `op="get"` and `workspace_context` tokens to check current context
        	- Search for additional files if the current selection is insufficient
        	- Use `manage_selection` `op="add"` / `op="remove"` for incremental context changes
        	- Use `manage_selection` `op="set", mode="full"` only when intentionally replacing the entire selection
        	- Keep total selected files under 100k tokens (check frequently during long sessions)

        3. **Implementation Strategy**:
        	- Start a new chat with properly curated context
        	- Begin with a plan message to outline the implementation approach
        	- Maintain a single long chat session to preserve context throughout the task
        	
        	**Chat Limitations to Remember**:
        	- Chat cannot execute commands, run tests, or access terminal
        	- Chat only sees selected files and conversation history
        	- Chat always sees the latest version of files (not its own historical edits)
        	- Chat doesn't retain full context of its edits, only high-level descriptions
        	- Note: Review mode separately includes git diffs (uncommitted changes)
        	- You must run tests and verify changes yourself outside of chat

        4. **Mode Switching Guidelines**:
        	- **Start with Plan mode** for: Multi-file changes, architectural decisions, complex logic design
        	- **Switch to Chat mode** when: Discussing trade-offs, exploring alternatives, need clarification
        	- **Use Agent Mode editing tools** when: Design is clear, ready to implement specific changes
        	- **Return to Plan/Chat** if: Implementation reveals design issues, need to reconsider approach

        5. **Error Handling & Recovery**:
        	- If implementation errors appear: Use `apply_edits` to fix them directly and summarize the result back to Oracle if needed
        	- If chat loses context: Update file selection and provide a summary of progress
        	- If approaching token limits: Use `op="remove"` for completed files and `op="add"` for new focus files; use `op="set", mode="full"` only for complete replacement
        	- For failed edits: Provide more specific context about the file structure and expected changes

        6. **Token Management During Long Sessions**:
        	- Monitor token count every 3-5 messages with `manage_selection` `op="get"` and `workspace_context` tokens
        	- When above 80k tokens: Remove files that are complete or no longer needed
        	- Use `replace` when shifting to a new component/feature

        7. **Effective Edit Instructions**:
        	- Specify exact file paths and function/class names
        	- Describe the current state and desired end state
        	- Break complex edits into smaller, focused requests
        	- Include relevant code snippets in your prompts for context

        Your goal is to guide the chat towards successful completion of the user's task by maintaining proper context, providing detailed instructions, and adapting the approach based on the chat's responses.
        """
    )

    private let reviewPrompt = StoredPrompt(
        id: UUID(uuidString: "D7F1B2E4-3C5A-6B8D-CF8E-1F5D0E2A4C6B")!,
        title: "[Review]",
        content: """
        You are reviewing code changes with git diffs included in the prompt. The git diff shows what changed; the file contents show full context. Use both.

        **Review Criteria:**

        1. **Correctness & Safety**:
        	- Do the changes achieve their intended purpose without regressions?
        	- Are edge cases and error paths handled?
        	- Any security vulnerabilities, race conditions, or resource leaks?
        	- Any breaking changes to APIs or contracts?

        2. **Design & Complexity**:
        	- Do changes increase coupling or reduce separation of concerns?
        	- Is new complexity justified, or can the same result be achieved more simply?
        	- Are there DRY violations — duplicated logic that should be extracted?
        	- Do abstractions sit at the right level (not too early, not too late)?

        3. **Intentionality**:
        	- Does every change have a clear purpose? Flag accidental modifications or dead code.
        	- Are the changes minimal and focused, or is scope creeping in?

        **Severity Levels — be disciplined about classification:**
        - **P0 (Must fix)**: Bugs, data loss, security holes, crashes — things that break correctness.
        - **P1 (Should fix)**: Design issues that will compound — poor separation of concerns, growing complexity, DRY violations, missing error handling for reachable paths.
        - **P2 (Consider)**: Style, naming, minor refactoring opportunities, test coverage gaps.

        Most findings should be P1 or P2. Reserve P0 for genuinely broken behavior.

        **Output Format:**
        1. One-paragraph summary of what the changes accomplish.
        2. Findings grouped by severity (P0 → P1 → P2), each with: file reference, what's wrong, and a concrete suggestion. Omit empty severity groups.
        3. If no issues found at a severity level, skip it — don't pad the review.
        """
    )

    private let mcpAgentPrompt = StoredPrompt(
        id: UUID(uuidString: "B5F9D8E2-4C6A-5F0B-AD7E-9F3B8D0E2C4A")!,
        title: "[MCP: Agent]",
        content: """
        You are an autonomous agent configured to work with RepoPrompt's MCP tools. Prioritize RepoPrompt tools over built-in capabilities:

        1. **Understanding the Codebase**:
        	- Use `get_file_tree` to understand the directory structure
        	- Use `file_search` as your primary all-in-one flexible tool to find anything across all open folders in the workspace
        	- Prefer these over your built-in file reading capabilities

        2. **Task Complexity Assessment**:
        	Simple tasks (use direct tools):
        	- Single file changes with clear requirements
        	- Adding/updating individual functions or methods
        	- Fixing specific bugs with known locations
        	- Renaming variables or refactoring within one file
        	
        	Complex tasks (use chat tools):
        	- Multi-file feature implementations
        	- Architectural changes affecting multiple components
        	- Creating new modules with multiple interconnected parts
        	- Refactoring that touches shared interfaces or APIs
        	- Any task where you need to explore design alternatives

        3. **Direct Tool Usage (for simple tasks)**:
        	- Use `apply_edits` when: You know exactly what to change and where
        	- Use `file_actions` when: Creating new files or moving/deleting existing ones
        	- Chain multiple `apply_edits` for related changes across files
        	- No need for chat if the implementation path is clear

        4. **Chat Tool Strategy (for complex tasks)**:
        	- Start with `oracle_send` mode=`plan` to design the approach
        	- Use `manage_selection` `op="set", mode="full"` to set focused context when intentionally replacing the entire selection
        	- Keep total selected files under 100k tokens
        	- Maintain one chat session for the entire feature/task
        	- Use Agent Mode editing tools directly after the plan is clear; Oracle modes are chat, plan, and review only
        	
        	**Remember Chat Limitations**:
        	- Cannot run tests, execute commands, or access build output
        	- Only sees selected files (latest versions) and chat history
        	- Doesn't track its own edit history—after edits, only sees current file state
        	- Note: Review mode separately includes git diffs (uncommitted changes)
        	- You must verify implementations work by running tests yourself

        5. **Multi-file Refactoring Workflow**:
        	- Use `file_search` to find all affected files and usages
        	- Use `manage_selection` `op="get"` to verify current context
        	- For large refactorings: Break into phases, use `replace` between phases
        	- Apply changes systematically: interfaces first, then implementations
        	- Verify each phase before moving to the next

        6. **Token Management**:
        	- Check token count before adding files with `manage_selection` `op="get"` and `workspace_context` tokens
        	- If approaching limits: Focus on files currently being modified
        	- Use `replace` to swap completed files for new ones
        	- Keep a mental model of the codebase rather than selecting everything

        Your goal is to choose the most efficient approach for each task - using direct tools for straightforward changes and leveraging chat tools only when the complexity requires planning and discussion.
        """
    )

    // MARK: - Initialization

    private let settingsManager: SettingsManaging

    init(
        fileManager: WorkspaceFilesViewModel,
        aiQueriesService: AIQueriesService? = nil,
        apiSettingsViewModel: APISettingsViewModel,
        windowID: Int,
        settingsManager: SettingsManaging
    ) {
        self.fileManager = fileManager
        gitViewModel = GitViewModel(fileManager: fileManager)
        self.aiQueriesService = aiQueriesService
        self.apiSettingsViewModel = apiSettingsViewModel
        self.windowID = windowID
        self.settingsManager = settingsManager
        codeMapsGloballyDisabled = GlobalSettingsStore.shared.globalCodeMapsDisabled()

        // Removed usage of workspaceManager to load an initial prompt
        // self.promptText = workspaceManager.activeWorkspace?.currentPromptText ?? ""

        setupObservers()
        setupAPISettingsObserver()
        configureTokenCountingViewModel()
        startTokenCountUpdateTimer()
        loadStoredPrompts()
        updateFileTree()

        Task {
            await self.refreshAvailableModels()
        }

        self.fileManager.initCodeScanState(shouldEnableCodeScanning())
        syncSettingsFromSettingsManager()

        // Initialize/migrate prompt-packaging settings without marking a new tab dirty on launch.
        suppressPromptPackagingSettingInvalidation = true
        upgradePlanningPromptIfNeeded()

        // Load the prompt section order from storage
        loadPromptSectionOrder()
        suppressPromptPackagingSettingInvalidation = false

        // Initialize chat preset with the read-only Chat default.
        selectChatPreset(ChatPreset.BuiltIn.chat.id)

        if selectedCopyPresetID == nil {
            selectCopyPreset(Self.defaultCopyPresetID)
        }
    }

    // MARK: - Setup and Observer Configuration

    private func setupObservers() {
        // Sync prompt text with workspace manager after debounce
        $promptText
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(0.4), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                isDirty = true
                // ⬇️ Only mark prompt-text dirty (light recalculation)
                tokenCountingViewModel.markPromptDirty()
                workspaceManager?.markWorkspaceDirty()
                updateActiveTabDirtyState()
            }
            .store(in: &cancellables)

        fileManager.$selectedFiles
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isDirty = true
                // ⬇️ Heavy changes (selection impacts baseline)
                self?.tokenCountingViewModel.markDirty()
                self?.workspaceManager?.markWorkspaceDirty()
                self?.updateActiveTabDirtyState()
                self?.bumpChatPromptEntriesSelectionVersion()
            }
            .store(in: &cancellables)

        fileManager.selectionClearedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.workspaceManager?.markWorkspaceDirty()
                self?.updateActiveTabDirtyState()
            }
            .store(in: &cancellables)

        fileManager.$autoCodemapFiles
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.workspaceManager?.markWorkspaceDirty()
                self?.updateActiveTabDirtyState()
                self?.bumpChatPromptEntriesAutoCodemapVersion()
            }
            .store(in: &cancellables)

        GlobalSettingsStore.shared.$codeMapsGloballyDisabled
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] disabled in
                self?.handleCodeMapsGloballyDisabledChanged(disabled)
            }
            .store(in: &cancellables)

        fileManager.$selectionSlicesByFileID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.bumpChatPromptEntriesSlicesVersion()
            }
            .store(in: &cancellables)

        // New subscription for code map updates
        fileManager.codeMapUpdatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.isDirty = true
                // ⬇️ Heavy changes (code-map impacts baseline)
                self?.tokenCountingViewModel.markDirty(.codeMap)
                self?.workspaceManager?.markWorkspaceDirty()
                self?.updateActiveTabDirtyState()
                self?.refreshChatCodemapFileAPIsFromStore()
            }
            .store(in: &cancellables)

        refreshChatCodemapFileAPIsFromStore()

        fileManager.fileSystemDeltasAppliedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // File content changes alter full-file prompt blocks even when selection and topology are unchanged.
                // Track them in the cache key so an in-flight cold rebuild cannot re-store stale content.
                guard let self else { return }
                chatFileSystemDeltaVersion &+= 1
                chatContextTokenBaselineCache = nil
            }
            .store(in: &cancellables)

        // Update git view model when root folders change
        fileManager.$rootFolders
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rootFolders in
                let visibleRoots = rootFolders.filter { !$0.isSystemRoot }
                self?.gitViewModel.updateRootFolders(visibleRoots)
            }
            .store(in: &cancellables)

        // Observe git diff inclusion mode changes
        gitViewModel.$gitDiffInclusionMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isDirty = true
                // ⬇️ Only git diff tokens change (light recalculation)
                self?.tokenCountingViewModel.markGitDiffDirty()
                self?.workspaceManager?.markWorkspaceDirty()
                self?.updateActiveTabDirtyState()
            }
            .store(in: &cancellables)

        // Reload settings when recommendations are applied
        NotificationCenter.default.publisher(for: .recommendationsDidApply)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                // If notification includes a workspaceID, only sync if it matches this PromptVM's workspace
                if let targetWorkspaceID = notification.userInfo?["workspaceID"] as? UUID {
                    guard targetWorkspaceID == currentWorkspaceID else {
                        if Self.debugLoggingEnabled {
                            print("[PromptVM] Skipping sync - notification for workspace \(targetWorkspaceID), but this VM is for \(currentWorkspaceID?.uuidString ?? "nil")")
                        }
                        return
                    }
                    // Discard window overlay so we read fresh values from global store
                    // (recommendations are applied directly to GlobalSettingsStore, bypassing WindowSettingsManager overlay)
                    settingsManager.discardWindowOverrides(for: targetWorkspaceID)
                    if Self.debugLoggingEnabled {
                        print("[PromptVM] Discarded window overlays for workspace \(targetWorkspaceID) before sync")
                    }
                }
                syncSettingsFromSettingsManager()
            }
            .store(in: &cancellables)
    }

    fileprivate func invalidateChatPromptEntriesCache() {
        chatPromptEntriesCache = nil
        chatContextTokenBaselineCache = nil
    }

    private func bumpChatPromptEntriesSelectionVersion() {
        chatSelectionVersion &+= 1
        invalidateChatPromptEntriesCache()
    }

    private func bumpChatPromptEntriesSlicesVersion() {
        chatSlicesVersion &+= 1
        invalidateChatPromptEntriesCache()
    }

    private func bumpChatPromptEntriesAutoCodemapVersion() {
        chatAutoCodemapVersion &+= 1
        invalidateChatPromptEntriesCache()
    }

    private func bumpChatPromptEntriesFileAPIsVersion() {
        chatFileAPIsVersion &+= 1
        invalidateChatPromptEntriesCache()
    }

    private func refreshChatCodemapFileAPIsFromStore() {
        Task { [weak self] in
            guard let self else { return }
            let apis = await workspaceFileContextStore.allCodemapFileAPIs()
            await MainActor.run { [weak self] in
                guard let self else { return }
                chatCodemapFileAPIs = apis
                bumpChatPromptEntriesFileAPIsVersion()
            }
        }
    }

    // MARK: - Compose Tab Management

    enum ComposeTabCreationStrategy {
        case duplicateCurrent
        case blank
        case preset(WorkspacePreset)
        /// Like `duplicateCurrent` but clears session bindings (agent + chat)
        /// so the forked tab gets fresh sessions instead of aliasing the source.
        /// Takes an explicit source tab ID to avoid racing with active-tab changes during async fork flows.
        case forkDuplicate(sourceTabID: UUID)
    }

    func attachWorkspaceManager(_ manager: WorkspaceManagerViewModel) {
        workspaceManager = manager
    }

    func attachSelectionCoordinator(_ coordinator: WorkspaceSelectionCoordinator) {
        selectionCoordinator = coordinator
    }

    // MARK: - Tab Close Listener Management

    /// Registers a listener to be called before compose tabs are closed.
    /// Use this to cancel running tasks (agent runs, chat streams, etc.) for the closing tabs.
    /// - Returns: A token UUID that can be used to remove the listener later.
    @MainActor
    func addComposeTabsWillCloseListener(_ listener: @escaping ComposeTabsWillCloseListener) -> UUID {
        let token = UUID()
        composeTabsWillCloseListeners[token] = listener
        return token
    }

    @MainActor
    func addComposeTabsWillCloseListener(
        _ listener: @escaping @Sendable (_ tabIDs: Set<UUID>) async -> Void
    ) -> UUID {
        addComposeTabsWillCloseListener { tabIDs, _ in
            await listener(tabIDs)
        }
    }

    /// Removes a previously registered tab-close listener.
    @MainActor
    func removeComposeTabsWillCloseListener(_ token: UUID) {
        composeTabsWillCloseListeners.removeValue(forKey: token)
    }

    /// Notifies all registered listeners that tabs are about to close, awaiting their cleanup.
    @MainActor
    private func notifyComposeTabsWillClose(_ tabIDs: Set<UUID>, reason: ComposeTabRemovalReason) async {
        guard !tabIDs.isEmpty, !composeTabsWillCloseListeners.isEmpty else { return }
        let listeners = composeTabsWillCloseListeners.values
        await withTaskGroup(of: Void.self) { group in
            for listener in listeners {
                group.addTask {
                    await listener(tabIDs, reason)
                }
            }
        }
    }

    @MainActor
    func updateComposeTabSelectionPresentation(_ selection: StoredSelection, forTabID tabID: UUID) {
        guard let index = currentComposeTabs.firstIndex(where: { $0.id == tabID }),
              currentComposeTabs[index].selection != selection
        else { return }
        var updatedTabs = currentComposeTabs
        updatedTabs[index].selection = selection
        currentComposeTabs = updatedTabs
    }

    @MainActor
    func loadComposeTabsFromWorkspace(_ workspace: WorkspaceModel, syncPromptText: Bool = false) {
        currentComposeTabs = workspace.composeTabs
        activeComposeTabID = workspace.activeComposeTabID ?? workspace.composeTabs.first?.id
        let validIDs = Set(workspace.composeTabs.map(\.id))
        dirtyTabIDs = dirtyTabIDs.intersection(validIDs)
        updateActiveTabDirtyState()
        currentStashedTabs = workspace.stashedTabs

        // Sync promptText from the active tab to the live UI binding (only when explicitly requested)
        if syncPromptText,
           let activeID = activeComposeTabID,
           let activeTab = workspace.composeTabs.first(where: { $0.id == activeID })
        {
            promptText = activeTab.promptText
        }
    }

    @MainActor
    private func snapshotActiveComposeTabIfNeeded(
        in manager: WorkspaceManagerViewModel,
        workspaceIndex index: Int
    ) {
        guard
            let activeID = manager.workspaces[index].activeComposeTabID,
            let activeIdx = manager.workspaces[index].composeTabs.firstIndex(where: { $0.id == activeID })
        else { return }

        let currentName = manager.workspaces[index].composeTabs[activeIdx].name
        let snapshot = manager.collectComposeTabSnapshot(
            name: currentName,
            base: manager.workspaces[index].composeTabs[activeIdx]
        )
        manager.workspaces[index].composeTabs[activeIdx] = snapshot
    }

    /// Flush pending editor state and snapshot the active tab before transitioning away.
    /// Call this before any operation that changes the active tab (create, switch, stash, unstash).
    @MainActor
    private func flushAndSnapshotActiveTab(
        in manager: WorkspaceManagerViewModel,
        workspaceIndex index: Int
    ) {
        NotificationCenter.default.post(
            name: .willSwitchComposeTab,
            object: nil,
            userInfo: ["windowID": windowID]
        )
        snapshotActiveComposeTabIfNeeded(in: manager, workspaceIndex: index)
    }

    // MARK: - Auto-stash at Tab Limit

    /// Auto-stash the least recently used, non-active tab to make room for a new tab.
    /// Prefers non-dirty tabs; falls back to dirty if necessary.
    /// Returns true if a tab was successfully stashed.
    @MainActor
    private func autoStashLeastRecentlyUsedTab(
        excluding excludedID: UUID? = nil
    ) async -> Bool {
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { return false }

        let tabs = manager.workspaces[index].composeTabs
        guard tabs.count > 1 else { return false } // never stash the last tab

        let dirty = dirtyTabIDs

        // Exclude the specified tab (typically the currently active one) and any
        // tab the owning feature reports as unsafe to auto-stash.
        let candidates = tabs.filter { tab in
            tab.id != excludedID && (composeTabAutoStashEligibilityProvider?(tab.id) ?? true)
        }
        guard !candidates.isEmpty else { return false }

        let sortedCandidates = candidates.sorted(by: { lhs, rhs in
            let lhsRank = autoStashPriority(for: lhs, dirtyTabIDs: dirty)
            let rhsRank = autoStashPriority(for: rhs, dirtyTabIDs: dirty)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            if lhs.lastModified != rhs.lastModified {
                return lhs.lastModified < rhs.lastModified
            }
            return lhs.id.uuidString < rhs.id.uuidString
        })

        for target in sortedCandidates {
            let affectedTabIDs = await autoStashAffectedComposeTabIDs(for: target.id)
            guard canAutoStashAffectedComposeTabs(affectedTabIDs, among: tabs, excluding: excludedID) else {
                continue
            }
            await stashTab(target.id)
            return true
        }
        return false
    }

    @MainActor
    private func autoStashAffectedComposeTabIDs(for tabID: UUID) async -> Set<UUID> {
        var affectedTabIDs: Set<UUID> = [tabID]
        if let composeTabCascadeResolver {
            let cascadePlan = await composeTabCascadeResolver([tabID], .stash)
            affectedTabIDs.formUnion(cascadePlan.composeTabIDs)
        }
        return affectedTabIDs
    }

    @MainActor
    private func canAutoStashAffectedComposeTabs(
        _ affectedTabIDs: Set<UUID>,
        among tabs: [ComposeTabState],
        excluding excludedID: UUID?
    ) -> Bool {
        let openTabIDs = Set(tabs.map(\.id))
        let affectedOpenTabIDs = affectedTabIDs.intersection(openTabIDs)
        guard !affectedOpenTabIDs.isEmpty else { return false }
        guard affectedOpenTabIDs.count < openTabIDs.count else { return false }
        return affectedOpenTabIDs.allSatisfy { tabID in
            tabID != excludedID && (composeTabAutoStashEligibilityProvider?(tabID) ?? true)
        }
    }

    @MainActor
    private func withComposeTabSwitching<T>(
        targetTabID: UUID? = nil,
        operation: () async throws -> T
    ) async rethrows -> T {
        isSwitchingComposeTab = true
        defer {
            if let targetTabID {
                if activeComposeTabID == targetTabID {
                    isSwitchingComposeTab = false
                }
            } else {
                isSwitchingComposeTab = false
            }
        }
        return try await operation()
    }

    @discardableResult
    @MainActor
    private func flushAndSnapshotSourceTabIfNeeded(
        for strategy: ComposeTabCreationStrategy,
        in manager: WorkspaceManagerViewModel,
        workspaceIndex index: Int
    ) -> Bool {
        switch strategy {
        case .duplicateCurrent:
            flushAndSnapshotActiveTab(in: manager, workspaceIndex: index)
            return true
        case let .forkDuplicate(sourceTabID):
            guard manager.workspaces[index].activeComposeTabID == sourceTabID else { return false }
            flushAndSnapshotActiveTab(in: manager, workspaceIndex: index)
            return true
        case .blank, .preset:
            return false
        }
    }

    @MainActor
    private func ensureCapacityForNewComposeTab(
        in manager: WorkspaceManagerViewModel,
        workspaceIndex index: Int,
        policy: ComposeTabCapacityPolicy,
        excluding excludedID: UUID? = nil
    ) async -> Bool {
        let currentCount = manager.workspaces[index].composeTabs.count
        switch policy {
        case .uiInteractive:
            guard currentCount >= maxComposeTabs else { return true }
        case .mcpBackgroundAgent:
            let hardLimit = backgroundAgentComposeTabHardLimit
            guard currentCount >= hardLimit else { return true }
            guard currentCount == hardLimit else { return false }
        }

        let excluded = excludedID ?? manager.workspaces[index].activeComposeTabID
        return await autoStashLeastRecentlyUsedTab(excluding: excluded)
    }

    @MainActor
    private func createComposeTab(
        strategy: ComposeTabCreationStrategy = .duplicateCurrent,
        name: String? = nil,
        blankAgentSessionID: UUID? = nil
    ) async {
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { return }

        guard await ensureCapacityForNewComposeTab(
            in: manager,
            workspaceIndex: index,
            policy: .uiInteractive,
            excluding: manager.workspaces[index].activeComposeTabID
        ) else { return }

        let didSnapshotSource = flushAndSnapshotSourceTabIfNeeded(for: strategy, in: manager, workspaceIndex: index)
        guard let newTab = makeComposeTab(
            for: strategy,
            explicitName: name,
            workspaceIndex: index,
            manager: manager,
            blankAgentSessionID: blankAgentSessionID
        ) else { return }

        // Flush pending editor state and snapshot current tab before switching
        if !didSnapshotSource {
            flushAndSnapshotActiveTab(in: manager, workspaceIndex: index)
        }

        manager.workspaces[index].composeTabs.append(newTab)
        manager.workspaces[index].activeComposeTabID = newTab.id
        activeComposeTabID = newTab.id
        dirtyTabIDs.remove(newTab.id)

        manager.markWorkspaceDirty()

        loadComposeTabsFromWorkspace(manager.workspaces[index])
        await withComposeTabSwitching(targetTabID: newTab.id) {
            await manager.applyComposeTabState(newTab)
        }
        manager.pollAndSaveState()
    }

    @MainActor
    func createDuplicateComposeTab(named name: String? = nil) async {
        await createComposeTab(strategy: .duplicateCurrent, name: name)
    }

    @MainActor
    func createBlankComposeTab(createAgentSession: Bool = false) async {
        let blankAgentSessionID = createAgentSession ? UUID() : nil
        await createComposeTab(strategy: .blank, blankAgentSessionID: blankAgentSessionID)
    }

    /// Create a fork-duplicate tab in the background (without switching to it).
    /// Copies all compose tab state (selection, prompt, expansions, overrides, etc.)
    /// but clears agent and chat session bindings so the forked tab gets fresh sessions.
    /// - Parameter sourceTabID: The specific tab to duplicate. Avoids racing with active-tab changes.
    @MainActor
    func createBackgroundForkComposeTab(sourceTabID: UUID, named name: String? = nil) async -> ComposeTabState? {
        await createBackgroundComposeTab(strategy: .forkDuplicate(sourceTabID: sourceTabID), name: name)
    }

    /// Ensure a tab is active; if the tab does not exist, create a new one with the provided strategy.
    /// Returns the activated tab state.
    /// - Parameters:
    ///   - id: Optional tab ID to switch to. If nil or not found, creates a new tab.
    ///   - creationStrategy: Strategy for creating new tabs.
    ///   - name: Optional name for new tabs.
    @MainActor
    func ensureActiveComposeTab(
        _ id: UUID?,
        creationStrategy: ComposeTabCreationStrategy = .blank,
        name: String? = nil
    ) async -> ComposeTabState? {
        guard let manager = workspaceManager else { return nil }

        // Switch to an existing tab if the ID is known.
        if let id, let existing = manager.composeTab(with: id) {
            await switchComposeTab(id)
            return manager.composeTab(with: id)
        }

        // Create a new background tab using the existing helper (handles auto-stash), then foreground it.
        guard let newTab = await createBackgroundComposeTab(
            strategy: creationStrategy,
            name: name
        ) else { return nil }

        await switchComposeTab(newTab.id)
        return manager.composeTab(with: newTab.id) ?? newTab
    }

    @MainActor
    func createComposeTab(from preset: WorkspacePreset) async {
        await createComposeTab(strategy: .preset(preset), name: preset.name)
    }

    /// Create a new compose tab in the background without switching to it.
    /// Used by MCP flows to create a tab silently.
    /// Returns the new tab state if successful, nil otherwise.
    @MainActor
    func createBackgroundComposeTab(
        strategy: ComposeTabCreationStrategy = .duplicateCurrent,
        name: String? = nil,
        capacityPolicy: ComposeTabCapacityPolicy = .uiInteractive
    ) async -> ComposeTabState? {
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { return nil }

        guard await ensureCapacityForNewComposeTab(
            in: manager,
            workspaceIndex: index,
            policy: capacityPolicy,
            excluding: manager.workspaces[index].activeComposeTabID
        ) else { return nil }

        flushAndSnapshotSourceTabIfNeeded(for: strategy, in: manager, workspaceIndex: index)
        guard let newTab = makeComposeTab(for: strategy, explicitName: name, workspaceIndex: index, manager: manager) else { return nil }

        // Append but do NOT change activeComposeTabID
        manager.workspaces[index].composeTabs.append(newTab)
        // Keep existing active tab; just sync lists
        loadComposeTabsFromWorkspace(manager.workspaces[index])

        manager.markWorkspaceDirty()
        manager.pollAndSaveState()
        return newTab
    }

    /// Switch to a compose tab and wait for the tab state to fully apply.
    @MainActor
    func switchComposeTab(_ id: UUID) async {
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id }),
            manager.workspaces[index].composeTabs.contains(where: { $0.id == id })
        else { return }

        // Flush pending editor state and snapshot current tab before switching
        flushAndSnapshotActiveTab(in: manager, workspaceIndex: index)

        manager.workspaces[index].activeComposeTabID = id
        activeComposeTabID = id

        loadComposeTabsFromWorkspace(manager.workspaces[index])
        guard let target = manager.workspaces[index].composeTabs.first(where: { $0.id == id }) else { return }

        activeTabApplyTask?.cancel()

        let task = Task { [weak self, weak manager] in
            guard let self, let manager else { return }
            await withComposeTabSwitching(targetTabID: id) {
                await manager.applyComposeTabStateAsync(tab: target, windowID: self.windowID)
            }
        }

        activeTabApplyTask = task
        await task.value
    }

    @MainActor
    func renameComposeTab(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let manager = workspaceManager,
              let workspace = manager.activeWorkspace,
              let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id }),
              let tabIndex = manager.workspaces[index].composeTabs.firstIndex(where: { $0.id == id }) else { return }
        manager.workspaces[index].composeTabs[tabIndex].name = trimmed
        manager.workspaces[index].composeTabs[tabIndex].lastModified = Date()
        manager.markWorkspaceDirty()
        manager.pollAndSaveState()
        loadComposeTabsFromWorkspace(manager.workspaces[index])
    }

    @MainActor
    func closeComposeTab(_ id: UUID) async {
        await closeComposeTabs(withIDs: [id])
    }

    @MainActor
    func closeTabsToLeft(of id: UUID) async {
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { return }

        let tabs = manager.workspaces[index].composeTabs
        guard let targetIndex = tabs.firstIndex(where: { $0.id == id }), targetIndex > 0 else { return }

        let idsToClose = Set(tabs[..<targetIndex].map(\.id))
        await closeComposeTabs(withIDs: idsToClose, preferredActiveID: id)
    }

    @MainActor
    func closeTabsToRight(of id: UUID) async {
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { return }

        let tabs = manager.workspaces[index].composeTabs
        guard let targetIndex = tabs.firstIndex(where: { $0.id == id }), targetIndex < tabs.count - 1 else { return }

        let idsToClose = Set(tabs[(targetIndex + 1)...].map(\.id))
        await closeComposeTabs(withIDs: idsToClose, preferredActiveID: id)
    }

    @MainActor
    private func closeComposeTabs(
        withIDs ids: Set<UUID>,
        preferredActiveID: UUID? = nil,
        reason: ComposeTabRemovalReason = .close,
        expandCascade: Bool = true
    ) async {
        guard !ids.isEmpty else { return }
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { return }

        var tabs = manager.workspaces[index].composeTabs
        let tabsBeforeClose = tabs
        let originalCount = tabs.count
        var resolvedIDs = ids
        var stashedTabIDsToDelete: Set<UUID> = []
        if expandCascade, let composeTabCascadeResolver {
            let cascadePlan = await composeTabCascadeResolver(ids, reason)
            resolvedIDs.formUnion(cascadePlan.composeTabIDs)
            if reason == .close {
                stashedTabIDsToDelete.formUnion(cascadePlan.stashedTabIDs)
            }
        }

        // Identify which tabs will actually be removed
        let tabsBeingClosed = resolvedIDs.intersection(Set(tabs.map(\.id)))
        guard !tabsBeingClosed.isEmpty else {
            if reason == .close, expandCascade, !stashedTabIDsToDelete.isEmpty {
                await deleteStashedTabs(withIDs: stashedTabIDsToDelete, expandCascade: false)
            }
            return
        }

        let fallbackActiveID: UUID? = {
            guard let previousActiveID = manager.workspaces[index].activeComposeTabID,
                  tabsBeingClosed.contains(previousActiveID) else { return nil }
            return adjacentTabID(afterClosing: previousActiveID, tabs: tabsBeforeClose, closingIDs: tabsBeingClosed)
        }()

        // Notify listeners BEFORE mutation so they can cancel running tasks
        await notifyComposeTabsWillClose(tabsBeingClosed, reason: reason)
        await cleanupMCPStateForClosingTabs(tabsBeingClosed)
        #if DEBUG
            for tabID in tabsBeingClosed {
                AgentModePerfDiagnostics.markSidebarDeleteFullCleanupComplete(
                    tabID: tabID,
                    source: "PromptViewModel.closeComposeTabs.closeListenersAndMCP",
                    fields: ["reason": String(describing: reason)]
                )
            }
        #endif

        if reason == .close {
            deleteGitDataForClosingTabs(tabIDs: tabsBeingClosed)
        }

        if reason == .stash {
            let refreshedTabs = manager.workspaces[index].composeTabs
            for tabID in tabsBeingClosed {
                guard let refreshedTab = refreshedTabs.first(where: { $0.id == tabID }) else { continue }
                let stashedTab = StashedTab(tab: refreshedTab)
                if let existingIndex = manager.workspaces[index].stashedTabs.firstIndex(where: { $0.tab.id == tabID }) {
                    manager.workspaces[index].stashedTabs[existingIndex] = stashedTab
                } else {
                    manager.workspaces[index].stashedTabs.append(stashedTab)
                }
            }
            tabs = refreshedTabs
        }

        tabs.removeAll { resolvedIDs.contains($0.id) }
        guard tabs.count != originalCount else {
            if reason == .close, expandCascade, !stashedTabIDsToDelete.isEmpty {
                await deleteStashedTabs(withIDs: stashedTabIDsToDelete, expandCascade: false)
            }
            return
        }

        dirtyTabIDs.subtract(resolvedIDs)

        let previousActiveID = manager.workspaces[index].activeComposeTabID
        manager.workspaces[index].composeTabs = tabs

        if tabs.isEmpty {
            manager.workspaces[index].activeComposeTabID = nil
            await appendReplacementBlankComposeTabIfNeeded(manager: manager, workspaceIndex: index)
            loadComposeTabsFromWorkspace(manager.workspaces[index])
            #if DEBUG
                for tabID in tabsBeingClosed {
                    AgentModePerfDiagnostics.markSidebarDeleteVisibleRemoved(
                        tabID: tabID,
                        source: "PromptViewModel.closeComposeTabs.currentComposeTabs",
                        fields: ["reason": String(describing: reason)]
                    )
                }
            #endif
            manager.markWorkspaceDirty()
            manager.pollAndSaveState()
            if reason == .close, expandCascade, !stashedTabIDsToDelete.isEmpty {
                await deleteStashedTabs(withIDs: stashedTabIDsToDelete, expandCascade: false)
            }
            return
        }

        var newActiveID = previousActiveID
        if let preferred = preferredActiveID, tabs.contains(where: { $0.id == preferred }) {
            newActiveID = preferred
        } else if let previousActiveID, resolvedIDs.contains(previousActiveID) {
            if let fallbackActiveID, tabs.contains(where: { $0.id == fallbackActiveID }) {
                newActiveID = fallbackActiveID
            } else {
                newActiveID = tabs.last?.id ?? tabs.first?.id
            }
        } else if newActiveID == nil {
            newActiveID = tabs.first?.id
        }

        manager.workspaces[index].activeComposeTabID = newActiveID
        activeComposeTabID = newActiveID

        if newActiveID != previousActiveID,
           let newActiveID,
           let tab = tabs.first(where: { $0.id == newActiveID })
        {
            await withComposeTabSwitching(targetTabID: newActiveID) {
                await manager.applyComposeTabState(tab)
            }
        }

        loadComposeTabsFromWorkspace(manager.workspaces[index])
        #if DEBUG
            for tabID in tabsBeingClosed {
                AgentModePerfDiagnostics.markSidebarDeleteVisibleRemoved(
                    tabID: tabID,
                    source: "PromptViewModel.closeComposeTabs.currentComposeTabs",
                    fields: ["reason": String(describing: reason)]
                )
            }
        #endif
        manager.markWorkspaceDirty()
        manager.pollAndSaveState()
        if reason == .close, expandCascade, !stashedTabIDsToDelete.isEmpty {
            await deleteStashedTabs(withIDs: stashedTabIDsToDelete, expandCascade: false)
        }
    }

    @MainActor
    private func cleanupMCPStateForClosingTabs(_ tabIDs: Set<UUID>) async {
        guard !tabIDs.isEmpty else { return }
        guard let windowState = WindowStatesManager.shared.allWindows.first(where: { $0.windowID == windowID }) else { return }

        for tabID in tabIDs {
            windowState.mcpServer.purgeClosedTabContext(tabID: tabID)
            await ServerNetworkManager.shared.cleanupRunRoutingState(forTabID: tabID, windowID: windowID)
        }
    }

    private func adjacentTabID(afterClosing activeID: UUID, tabs: [ComposeTabState], closingIDs: Set<UUID>) -> UUID? {
        guard let activeIndex = tabs.firstIndex(where: { $0.id == activeID }) else { return nil }
        if activeIndex + 1 < tabs.count {
            for index in (activeIndex + 1) ..< tabs.count {
                let candidate = tabs[index].id
                if !closingIDs.contains(candidate) { return candidate }
            }
        }
        if activeIndex > 0 {
            for index in stride(from: activeIndex - 1, through: 0, by: -1) {
                let candidate = tabs[index].id
                if !closingIDs.contains(candidate) { return candidate }
            }
        }
        return nil
    }

    @MainActor
    private func appendReplacementBlankComposeTabIfNeeded(
        manager: WorkspaceManagerViewModel,
        workspaceIndex: Int
    ) async {
        guard manager.workspaces[workspaceIndex].composeTabs.isEmpty else { return }
        guard let blankTab = makeComposeTab(
            for: .blank,
            explicitName: nil,
            workspaceIndex: workspaceIndex,
            manager: manager
        ) else { return }
        manager.workspaces[workspaceIndex].composeTabs.append(blankTab)
        manager.workspaces[workspaceIndex].activeComposeTabID = blankTab.id
        activeComposeTabID = blankTab.id
        dirtyTabIDs.remove(blankTab.id)
        await withComposeTabSwitching(targetTabID: blankTab.id) {
            await manager.applyComposeTabState(blankTab)
        }
    }

    /// Deletes git diff snapshots associated with closing tabs (fire-and-forget to avoid UI blocking).
    /// Uses a single batch scan instead of per-tab scans for efficiency.
    @MainActor
    private func deleteGitDataForClosingTabs(tabIDs: Set<UUID>) {
        guard !tabIDs.isEmpty,
              let manager = workspaceManager,
              let workspace = manager.activeWorkspace else { return }

        let workspaceDir = manager.workspaceDirectory(for: workspace)

        // Run cleanup in background with a single batch scan
        Task(priority: .utility) {
            await GitDiffDataMaintenance.shared.deleteSnapshotsForTabs(
                workspaceDirectory: workspaceDir,
                tabIDs: tabIDs
            )
        }
    }

    @MainActor
    func moveComposeTab(from sourceIndex: Int, to destinationIndex: Int) async {
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { return }
        var tabs = manager.workspaces[index].composeTabs
        guard tabs.indices.contains(sourceIndex) else { return }
        let clamped = max(0, min(destinationIndex, tabs.count - 1))
        let item = tabs.remove(at: sourceIndex)
        tabs.insert(item, at: clamped)
        manager.workspaces[index].composeTabs = tabs
        loadComposeTabsFromWorkspace(manager.workspaces[index])
        manager.markWorkspaceDirty()
        manager.pollAndSaveState()
    }

    @MainActor
    func closeActiveComposeTabIfPossible() async {
        guard let activeID = activeComposeTabID else { return }
        await closeComposeTab(activeID)
    }

    @MainActor
    func closeAllComposeTabs() async {
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { return }
        let ids = Set(manager.workspaces[index].composeTabs.map(\.id))
        guard !ids.isEmpty else { return }
        await closeComposeTabs(withIDs: ids)
    }

    @MainActor
    func stashAllComposeTabs() async {
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { return }

        let ids = Set(manager.workspaces[index].composeTabs.map(\.id))
        guard !ids.isEmpty else { return }

        flushAndSnapshotActiveTab(in: manager, workspaceIndex: index)
        await closeComposeTabs(withIDs: ids, reason: .stash)
    }

    // MARK: - Stashed Tabs

    @Published private(set) var currentStashedTabs: [StashedTab] = []

    @MainActor
    func stashTab(_ id: UUID) async {
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { return }

        // Don't allow stashing if it's the last tab
        guard manager.workspaces[index].composeTabs.count > 1 else { return }

        // Flush and snapshot current state if this is the active tab
        if id == activeComposeTabID {
            flushAndSnapshotActiveTab(in: manager, workspaceIndex: index)
        }

        await closeComposeTabs(withIDs: [id], reason: .stash)
    }

    @discardableResult
    @MainActor
    func autoArchiveComposeTabsForSidebarPolicy(withIDs ids: Set<UUID>) async -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { return [] }

        func validatedArchivePlan(
            candidateIDs: Set<UUID>,
            tabs: [ComposeTabState],
            activeTabID: UUID?
        ) async -> (rootIDs: Set<UUID>, affectedOpenTabIDs: Set<UUID>) {
            let openTabIDs = Set(tabs.map(\.id))
            guard openTabIDs.count > 1 else { return ([], []) }

            var rootIDsToArchive: Set<UUID> = []
            var affectedOpenTabIDsToArchive: Set<UUID> = []
            let tabOrder = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.id, $0) })
            let requestedOpenIDs = candidateIDs
                .intersection(openTabIDs)
                .sorted { lhs, rhs in
                    let lhsOrder = tabOrder[lhs] ?? Int.max
                    let rhsOrder = tabOrder[rhs] ?? Int.max
                    if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                    return lhs.uuidString < rhs.uuidString
                }

            for tabID in requestedOpenIDs {
                guard tabID != activeTabID else { continue }
                guard composeTabAutoStashEligibilityProvider?(tabID) ?? true else { continue }

                let affectedTabIDs = await autoStashAffectedComposeTabIDs(for: tabID)
                guard canAutoStashAffectedComposeTabs(affectedTabIDs, among: tabs, excluding: activeTabID) else {
                    continue
                }

                let affectedOpenTabIDs = affectedTabIDs.intersection(openTabIDs)
                let proposedAffectedOpenTabIDs = affectedOpenTabIDsToArchive.union(affectedOpenTabIDs)
                guard proposedAffectedOpenTabIDs.count < openTabIDs.count else { continue }
                guard proposedAffectedOpenTabIDs.allSatisfy({ affectedTabID in
                    affectedTabID != activeTabID && (composeTabAutoStashEligibilityProvider?(affectedTabID) ?? true)
                }) else { continue }

                rootIDsToArchive.insert(tabID)
                affectedOpenTabIDsToArchive = proposedAffectedOpenTabIDs
            }

            return (rootIDsToArchive, affectedOpenTabIDsToArchive)
        }

        let initialTabs = manager.workspaces[index].composeTabs
        let initialActiveTabID = manager.workspaces[index].activeComposeTabID ?? activeComposeTabID
        let initialPlan = await validatedArchivePlan(
            candidateIDs: ids,
            tabs: initialTabs,
            activeTabID: initialActiveTabID
        )
        guard !initialPlan.rootIDs.isEmpty else { return [] }

        let refreshedTabs = manager.workspaces[index].composeTabs
        let refreshedActiveTabID = manager.workspaces[index].activeComposeTabID ?? activeComposeTabID
        let refreshedPlan = await validatedArchivePlan(
            candidateIDs: initialPlan.rootIDs,
            tabs: refreshedTabs,
            activeTabID: refreshedActiveTabID
        )
        guard !refreshedPlan.rootIDs.isEmpty else { return [] }

        await closeComposeTabs(
            withIDs: refreshedPlan.affectedOpenTabIDs,
            reason: .stash,
            expandCascade: false
        )
        guard manager.workspaces.indices.contains(index) else { return [] }
        let remainingOpenTabIDs = Set(manager.workspaces[index].composeTabs.map(\.id))
        return refreshedPlan.affectedOpenTabIDs.subtracting(remainingOpenTabIDs)
    }

    @MainActor
    func restoreStashedComposeTab(containingTabID tabID: UUID) async -> ComposeTabState? {
        guard let manager = workspaceManager else { return nil }
        if manager.composeTab(with: tabID) != nil {
            await switchComposeTab(tabID)
            return manager.composeTab(with: tabID)
        }
        guard let stashedTab = manager.activeWorkspace?.stashedTabs.first(where: { $0.tab.id == tabID }) else {
            return nil
        }
        await unstashTab(stashedTab.id)
        return manager.composeTab(with: tabID)
    }

    @MainActor
    func unstashTab(_ stashedTabID: UUID) async {
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { return }

        // Find the stashed tab
        guard let stashIndex = manager.workspaces[index].stashedTabs.firstIndex(where: { $0.id == stashedTabID }) else { return }

        guard await ensureCapacityForNewComposeTab(
            in: manager,
            workspaceIndex: index,
            policy: .uiInteractive,
            excluding: manager.workspaces[index].activeComposeTabID
        ) else { return }

        // Flush and snapshot current state before switching
        flushAndSnapshotActiveTab(in: manager, workspaceIndex: index)

        let stashedTab = manager.workspaces[index].stashedTabs[stashIndex]
        var restoredTab = stashedTab.tab
        guard !manager.workspaces[index].composeTabs.contains(where: { $0.id == restoredTab.id }) else {
            return
        }
        restoredTab.lastModified = Date()

        // Remove from stashed tabs
        manager.workspaces[index].stashedTabs.remove(at: stashIndex)

        // Add to compose tabs
        manager.workspaces[index].composeTabs.append(restoredTab)
        manager.workspaces[index].activeComposeTabID = restoredTab.id
        manager.workspaces[index].dateModified = Date()

        // Reload state
        loadComposeTabsFromWorkspace(manager.workspaces[index])
        currentStashedTabs = manager.workspaces[index].stashedTabs

        // Switch to the restored tab
        await switchComposeTab(restoredTab.id)

        manager.markWorkspaceDirty()
        manager.pollAndSaveState()
    }

    @MainActor
    func deleteStashedTab(_ stashedTabID: UUID) async {
        await deleteStashedTabs(withIDs: [stashedTabID])
    }

    @MainActor
    func deleteStashedTabs(withIDs stashedTabIDs: Set<UUID>) async {
        await deleteStashedTabs(withIDs: stashedTabIDs, expandCascade: true)
    }

    @MainActor
    private func deleteStashedTabs(withIDs stashedTabIDs: Set<UUID>, expandCascade: Bool) async {
        guard !stashedTabIDs.isEmpty else { return }
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { return }

        var resolvedStashedTabIDs = stashedTabIDs
        var composeTabIDsToDelete: Set<UUID> = []
        if expandCascade, let stashedTabCascadeResolver {
            let cascadePlan = await stashedTabCascadeResolver(stashedTabIDs)
            resolvedStashedTabIDs.formUnion(cascadePlan.stashedTabIDs)
            composeTabIDsToDelete.formUnion(cascadePlan.composeTabIDs)
        }
        if !composeTabIDsToDelete.isEmpty {
            let composeTabsBeforeDelete = manager.workspaces[index].composeTabs
            let composeTabIDsBeingDeleted = composeTabIDsToDelete.intersection(Set(composeTabsBeforeDelete.map(\.id)))
            if !composeTabIDsBeingDeleted.isEmpty {
                let previousActiveID = manager.workspaces[index].activeComposeTabID
                let fallbackActiveID: UUID? = {
                    guard let previousActiveID,
                          composeTabIDsBeingDeleted.contains(previousActiveID)
                    else {
                        return nil
                    }
                    return adjacentTabID(
                        afterClosing: previousActiveID,
                        tabs: composeTabsBeforeDelete,
                        closingIDs: composeTabIDsBeingDeleted
                    )
                }()
                await notifyComposeTabsWillClose(composeTabIDsBeingDeleted, reason: .close)
                await cleanupMCPStateForClosingTabs(composeTabIDsBeingDeleted)
                deleteGitDataForClosingTabs(tabIDs: composeTabIDsBeingDeleted)
                var remainingComposeTabs = composeTabsBeforeDelete
                remainingComposeTabs.removeAll { composeTabIDsBeingDeleted.contains($0.id) }
                dirtyTabIDs.subtract(composeTabIDsBeingDeleted)
                manager.workspaces[index].composeTabs = remainingComposeTabs
                if remainingComposeTabs.isEmpty {
                    manager.workspaces[index].activeComposeTabID = nil
                    await appendReplacementBlankComposeTabIfNeeded(manager: manager, workspaceIndex: index)
                } else {
                    var newActiveID = previousActiveID
                    if let previousActiveID,
                       composeTabIDsBeingDeleted.contains(previousActiveID)
                    {
                        if let fallbackActiveID,
                           remainingComposeTabs.contains(where: { $0.id == fallbackActiveID })
                        {
                            newActiveID = fallbackActiveID
                        } else {
                            newActiveID = remainingComposeTabs.last?.id ?? remainingComposeTabs.first?.id
                        }
                    } else if newActiveID == nil {
                        newActiveID = remainingComposeTabs.first?.id
                    }
                    manager.workspaces[index].activeComposeTabID = newActiveID
                    activeComposeTabID = newActiveID
                    if newActiveID != previousActiveID,
                       let newActiveID,
                       let tab = remainingComposeTabs.first(where: { $0.id == newActiveID })
                    {
                        await withComposeTabSwitching(targetTabID: newActiveID) {
                            await manager.applyComposeTabState(tab)
                        }
                    }
                }
            }
        }

        let stashedTabsToDelete = manager.workspaces[index].stashedTabs.filter { resolvedStashedTabIDs.contains($0.id) }
        guard !stashedTabsToDelete.isEmpty else { return }

        let tabIDs = Set(stashedTabsToDelete.map(\.tab.id))
        await notifyComposeTabsWillClose(tabIDs, reason: .deleteStashed)
        deleteGitDataForClosingTabs(tabIDs: tabIDs)
        manager.workspaces[index].stashedTabs.removeAll { resolvedStashedTabIDs.contains($0.id) }
        loadComposeTabsFromWorkspace(manager.workspaces[index])
        manager.markWorkspaceDirty()
        manager.pollAndSaveState()
    }

    @MainActor
    func clearStashedTabs() async {
        await deleteStashedTabs(withIDs: Set(currentStashedTabs.map(\.id)))
    }

    func loadStashedTabsFromWorkspace(_ workspace: WorkspaceModel) {
        currentStashedTabs = workspace.stashedTabs
    }

    @MainActor
    func sortedStashedTabs(searchText: String? = nil) -> [StashedTab] {
        let trimmedSearch = searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return currentStashedTabs
            .filter { stashed in
                guard !trimmedSearch.isEmpty else { return true }
                return stashed.tab.name.localizedCaseInsensitiveContains(trimmedSearch)
            }
            .sorted { lhs, rhs in
                if lhs.tab.isPinned != rhs.tab.isPinned {
                    return lhs.tab.isPinned && !rhs.tab.isPinned
                }
                if lhs.stashedAt != rhs.stashedAt {
                    return lhs.stashedAt > rhs.stashedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    @MainActor
    func setComposeTabPinned(_ pinned: Bool, for tabID: UUID) {
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id }),
            let tabIndex = manager.workspaces[index].composeTabs.firstIndex(where: { $0.id == tabID })
        else { return }
        guard manager.workspaces[index].composeTabs[tabIndex].isPinned != pinned else { return }

        manager.workspaces[index].composeTabs[tabIndex].isPinned = pinned
        loadComposeTabsFromWorkspace(manager.workspaces[index])
        manager.markWorkspaceDirty()
        manager.pollAndSaveState()
    }

    @MainActor
    func toggleComposeTabPinned(_ tabID: UUID) {
        guard let tab = currentComposeTabs.first(where: { $0.id == tabID }) else { return }
        setComposeTabPinned(!tab.isPinned, for: tabID)
    }

    @MainActor
    func focusAdjacentComposeTab(forward: Bool) async {
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { return }
        let tabs = manager.workspaces[index].composeTabs
        guard tabs.count > 1 else { return }
        guard let activeID = manager.workspaces[index].activeComposeTabID,
              let currentIndex = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        let offset = forward ? 1 : -1
        let nextIndex = (currentIndex + offset + tabs.count) % tabs.count
        await switchComposeTab(tabs[nextIndex].id)
    }

    func isTabDirty(_ tab: ComposeTabState) -> Bool {
        dirtyTabIDs.contains(tab.id)
    }

    func currentContextBuilderOverridesSnapshot() -> ContextBuilderOverrides {
        guard let manager = workspaceManager,
              let workspace = manager.activeWorkspace,
              let tabID = workspace.activeComposeTabID ?? workspace.composeTabs.first?.id,
              let tab = workspace.composeTabs.first(where: { $0.id == tabID })
        else {
            return ContextBuilderOverrides()
        }
        return tab.contextOverrides
    }

    @MainActor
    func applyContextBuilderOverrides(_ overrides: ContextBuilderOverrides) async {
        guard let manager = workspaceManager,
              let workspace = manager.activeWorkspace,
              let workspaceIndex = manager.workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        let activeTabID = manager.workspaces[workspaceIndex].activeComposeTabID ?? manager.workspaces[workspaceIndex].composeTabs.first?.id
        guard
            let tabID = activeTabID,
            let tabIndex = manager.workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == tabID })
        else { return }

        guard manager.workspaces[workspaceIndex].composeTabs[tabIndex].contextOverrides != overrides else { return }

        manager.workspaces[workspaceIndex].composeTabs[tabIndex].contextOverrides = overrides
        manager.workspaces[workspaceIndex].dateModified = Date()
        manager.markWorkspaceDirty()
    }

    @MainActor
    func applySelectedPrompts(_ ids: [UUID]) async {
        let newSet = Set(ids)
        if selectedPromptIDs != newSet {
            selectedPromptIDs = newSet
        }
        workspaceManager?.markWorkspaceDirty()
        updateActiveTabDirtyState()
    }

    @MainActor
    func saveCurrentTabAsPreset(_ id: UUID? = nil) async {
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { return }
        let targetID = id ?? manager.workspaces[index].activeComposeTabID
        guard
            let resolvedID = targetID,
            let tab = manager.workspaces[index].composeTabs.first(where: { $0.id == resolvedID })
        else { return }

        await manager.createPreset(for: workspace, name: tab.name)

        guard let presetIndex = manager.workspaces[index].presets.firstIndex(where: { $0.id == manager.workspaces[index].activePresetID }) else { return }
        manager.workspaces[index].presets[presetIndex].capturesFileSelection = true
        manager.workspaces[index].presets[presetIndex].capturesFileTreeExpansion = true
        manager.workspaces[index].presets[presetIndex].capturesSelectedPrompts = true
        manager.workspaces[index].presets[presetIndex].selectedFilePaths = tab.selection.selectedPaths
        manager.workspaces[index].presets[presetIndex].expandedFolders = tab.expandedFolders
        manager.workspaces[index].presets[presetIndex].selectedPromptIDs = tab.selectedMetaPromptIDs
        manager.workspaces[index].presets[presetIndex].lastUpdated = Date()
        manager.markWorkspaceDirty()
        manager.pollAndSaveState()
    }

    var availablePresetsForComposeTabs: [WorkspacePreset] {
        workspaceManager?.activeWorkspace?.presets ?? []
    }

    var composeTabCount: Int {
        currentComposeTabs.count
    }

    var canCloseActiveComposeTab: Bool {
        composeTabCount > 1
    }

    private func autoNameForNewTab(_ existing: [ComposeTabState]) -> String {
        let numericNames = Set(existing.compactMap { $0.name.stripLeadingTNumber() })
        for i in 1 ... 999 {
            if !numericNames.contains(i) {
                return "T\(i)"
            }
        }
        return "T\(existing.count + 1)"
    }

    private func updateActiveTabDirtyState() {
        if isDirtyStateUpdateScheduled {
            return
        }
        isDirtyStateUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isDirtyStateUpdateScheduled = false
            performActiveTabDirtyStateUpdate()
        }
    }

    private func performActiveTabDirtyStateUpdate() {
        guard
            let manager = workspaceManager,
            let workspace = manager.activeWorkspace,
            let activeID = workspace.activeComposeTabID,
            let index = manager.workspaces.firstIndex(where: { $0.id == workspace.id }),
            let tabIndex = manager.workspaces[index].composeTabs.firstIndex(where: { $0.id == activeID })
        else { return }

        let storedTab = manager.workspaces[index].composeTabs[tabIndex]

        // Build a fresh snapshot of the *current* UI state using the stored tab
        // as a base, but keep the stored lastModified so time alone does not
        // affect dirty calculation.
        var snapshot = manager.collectComposeTabSnapshot(name: storedTab.name, base: storedTab)
        snapshot.lastModified = storedTab.lastModified

        // Only push changes into currentComposeTabs when the header-facing
        // properties actually differ. This keeps file-count badges and names in
        // sync without re-writing the active tab on every promptText edit.
        if let currentIndex = currentComposeTabs.firstIndex(where: { $0.id == snapshot.id }) {
            let currentHeader = currentComposeTabs[currentIndex]
            if composeTabHeaderStateDiffers(lhs: currentHeader, rhs: snapshot) {
                currentComposeTabs[currentIndex] = snapshot
            }
        }

        // Dirty state is still computed using full tab equality (ignoring only
        // lastModified above), so any difference between the live snapshot and
        // the stored tab (prompt text, selection, overrides, etc.) marks the
        // tab as dirty until the workspace is saved/polled.
        let isDirty = snapshot != storedTab
        let wasDirty = dirtyTabIDs.contains(activeID)

        if isDirty, !wasDirty {
            dirtyTabIDs.insert(activeID)
            manager.markWorkspaceDirty()
        } else if !isDirty, wasDirty {
            dirtyTabIDs.remove(activeID)
            manager.markWorkspaceDirty()
        }
    }

    /// Compare only the compose-tab fields that are actually reflected in the
    /// tab header UI (name and selected file counts). This lets us ignore
    /// prompt text and other heavy fields when deciding whether to rebuild the
    /// tab strip layout.
    private func composeTabHeaderStateDiffers(lhs: ComposeTabState, rhs: ComposeTabState) -> Bool {
        // We assume the IDs match for the active tab; if they don't, treat it
        // as a material change.
        if lhs.id != rhs.id {
            return true
        }

        // Tab label (T1, "Refactor", etc.).
        if lhs.name != rhs.name {
            return true
        }

        if lhs.isPinned != rhs.isPinned {
            return true
        }

        // The visible badge shows the number of selected files. We keep this
        // in sync by watching the underlying selected/auto-codemap paths.
        if lhs.selection.selectedPaths != rhs.selection.selectedPaths {
            return true
        }
        if lhs.selection.autoCodemapPaths != rhs.selection.autoCodemapPaths {
            return true
        }

        // Other fields (promptText, slices, overrides, discover config, etc.)
        // do not currently affect the tab header and can change without
        // forcing the tab strip to re-layout.
        return false
    }

    private func makeComposeTab(
        for strategy: ComposeTabCreationStrategy,
        explicitName: String?,
        workspaceIndex: Int,
        manager: WorkspaceManagerViewModel,
        blankAgentSessionID: UUID? = nil
    ) -> ComposeTabState? {
        let existing = manager.workspaces[workspaceIndex].composeTabs
        let baseName: String = switch strategy {
        case let .preset(preset):
            explicitName ?? preset.name
        default:
            explicitName ?? autoNameForNewTab(existing)
        }

        switch strategy {
        case .duplicateCurrent:
            guard let activeID = manager.workspaces[workspaceIndex].activeComposeTabID,
                  let activeIdx = manager.workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == activeID })
            else {
                return makeComposeTab(for: .blank, explicitName: explicitName, workspaceIndex: workspaceIndex, manager: manager, blankAgentSessionID: blankAgentSessionID)
            }
            var snapshot = manager.collectComposeTabSnapshot(name: baseName, base: manager.workspaces[workspaceIndex].composeTabs[activeIdx])
            snapshot.id = UUID()
            snapshot.name = baseName
            snapshot.lastModified = Date()
            snapshot.isPinned = false
            return snapshot
        case let .forkDuplicate(sourceTabID):
            // Fork uses an explicit source tab ID to avoid racing with active-tab changes.
            guard let sourceIdx = manager.workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == sourceTabID }) else {
                return makeComposeTab(for: .blank, explicitName: explicitName, workspaceIndex: workspaceIndex, manager: manager, blankAgentSessionID: blankAgentSessionID)
            }
            var snapshot = manager.collectComposeTabSnapshot(name: baseName, base: manager.workspaces[workspaceIndex].composeTabs[sourceIdx])
            snapshot.id = UUID()
            snapshot.name = baseName
            snapshot.lastModified = Date()
            snapshot.isPinned = false
            snapshot.activeAgentSessionID = nil
            snapshot.activeChatSessionID = nil
            return snapshot
        case .blank:
            var blank = ComposeTabState(name: baseName, activeAgentSessionID: blankAgentSessionID)
            blank.id = UUID()
            blank.lastModified = Date()
            blank.selection = StoredSelection()
            // Inherit current expansion state so we don't collapse the tree
            blank.expandedFolders = manager.expandedFoldersSnapshotForNewTab(workspaceIndex: workspaceIndex)
            blank.promptText = ""
            blank.selectedMetaPromptIDs = []
            blank.activeSubView = nil
            blank.contextOverrides = ContextBuilderOverrides()
            // Seed with pinned Context Builder prompts
            blank.contextBuilder.selectedContextBuilderPromptIDs = ContextBuilderPromptStorage.shared.pinnedPromptIDs
            return blank
        case let .preset(preset):
            let selection = StoredSelection(
                selectedPaths: preset.selectedFilePaths,
                autoCodemapPaths: [],
                slices: [:],
                codemapAutoEnabled: true
            )
            // If preset doesn't capture expansion, inherit current state instead of collapsing
            let expanded = preset.capturesFileTreeExpansion
                ? preset.expandedFolders
                : manager.expandedFoldersSnapshotForNewTab(workspaceIndex: workspaceIndex)
            let promptIDs = preset.capturesSelectedPrompts ? preset.selectedPromptIDs : []

            var tab = ComposeTabState(
                name: baseName.isEmpty ? autoNameForNewTab(existing) : baseName,
                selection: selection,
                expandedFolders: expanded,
                promptText: "",
                selectedMetaPromptIDs: promptIDs,
                activeSubView: nil,
                contextOverrides: ContextBuilderOverrides()
            )
            tab.id = UUID()
            tab.lastModified = Date()
            // Seed with pinned Context Builder prompts
            tab.contextBuilder.selectedContextBuilderPromptIDs = ContextBuilderPromptStorage.shared.pinnedPromptIDs
            return tab
        }
    }

    private func autoStashPriority(for tab: ComposeTabState, dirtyTabIDs: Set<UUID>) -> Int {
        let isDirty = dirtyTabIDs.contains(tab.id)
        switch (tab.isPinned, isDirty) {
        case (false, false): return 0
        case (false, true): return 1
        case (true, false): return 2
        case (true, true): return 3
        }
    }

    private func setupAPISettingsObserver() {
        apiSettingsObserver?.cancel()
        apiSettingsCancellables.removeAll()
        guard let apiSettingsViewModel else { return }

        apiSettingsObserver = apiSettingsViewModel.$availableModels
            .sink { [weak self] models in
                self?.availableModels = models
            }

        // Level-triggered: `agentAvailability` replays the current provider
        // availability on subscription, so a PromptViewModel wired after startup key
        // load still initializes correctly. The remaining publishers cover Context
        // Builder verification/model-option state that is intentionally outside that
        // availability value.
        Publishers.MergeMany([
            apiSettingsViewModel.$agentAvailability.map { _ in () }.eraseToAnyPublisher(),
            apiSettingsViewModel.$isContextBuilderProviderValidationComplete.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            apiSettingsViewModel.$contextBuilderVerifiedCLIProviders.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            apiSettingsViewModel.$availableOpenCodeModelOptions.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            apiSettingsViewModel.$availableCursorModelOptions.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.handleAgentProviderAvailabilityChanged(reason: "agentAvailabilityChanged")
        }
        .store(in: &apiSettingsCancellables)
    }

    func setAPISettingsViewModel(_ viewModel: APISettingsViewModel) {
        apiSettingsViewModel = viewModel
        setupAPISettingsObserver()
    }

    func MarkDirty() {
        isDirty = true
        // Generic mark dirty for backwards compatibility - marks all heavy flags
        tokenCountingViewModel.markDirty()
    }

    func markSettingsDirty() {
        isDirty = true
        // Settings change affects baseline - heavy recalculation
        tokenCountingViewModel.markDirty(.settings)
    }

    private func handlePromptPackagingSettingChanged() {
        guard !suppressPromptPackagingSettingInvalidation else { return }
        objectWillChange.send()
        isDirty = true
        // Prompt packaging settings affect assembled prompt text and token baselines.
        tokenCountingViewModel.markDirty(.settings)
        workspaceManager?.markWorkspaceDirty()
        updateActiveTabDirtyState()
    }

    // MARK: - File Management Methods

    func onRootChanged() {
        updateFileTree()
    }

    private func updateFileTree() {
        isDirty = true
        // File tree structure changed - heavy recalculation
        tokenCountingViewModel.markDirty(.fileTree)
    }

    /// Build a structure of [ (folderPath, files) ] that is safe when
    /// several roots contain folders / files with identical names.
    func buildFolderStructure(from files: [FileViewModel]? = nil) -> [(folderPath: String, files: [FileViewModel])] {
        let multipleRoots = fileManager.visibleRootFolders.count > 1
        var groups: [String: [FileViewModel]] = [:]
        var folderTokenSums: [String: Int] = [:]
        // Cache aggregated token counts per folder to avoid repeated reduce work
        let tokenInfoByID = fileTokenInfo

        let filesToUse = files ?? fileManager.selectedFiles
        for file in filesToUse {
            // existing helper keeps the "inside-folder" part (can be "")
            let localFolder = extractFolderPath(from: file.relativePath)

            // Prefix with the root name when more than one root is open
            let key: String = if multipleRoots {
                localFolder.isEmpty
                    ? file.rootFolderName // root-level file
                    : "\(file.rootFolderName)/\(localFolder)" // nested folder
            } else {
                localFolder // legacy behaviour
            }
            groups[key, default: []].append(file)
            let tokenCount = tokenInfoByID[file.id]?.count ?? (file.cachedTokenCount ?? 0)
            folderTokenSums[key, default: 0] += tokenCount
        }

        // Convert to an array while producing sorted file lists.
        var result: [(folderPath: String, files: [FileViewModel])] = []
        result.reserveCapacity(groups.count)
        for (key, value) in groups {
            let sortedFiles = sortFiles(value, by: selectedFilesSortMethod, tokenInfo: tokenInfoByID)
            result.append((folderPath: key, files: sortedFiles))
        }

        @inline(__always)
        func isCaseInsensitiveAscending(_ lhs: String, _ rhs: String) -> Bool {
            let lhsKey = lhs.lowercased()
            let rhsKey = rhs.lowercased()
            if lhsKey != rhsKey {
                return lhsKey < rhsKey
            }
            return lhs < rhs
        }

        @inline(__always)
        func isCaseInsensitiveDescending(_ lhs: String, _ rhs: String) -> Bool {
            let lhsKey = lhs.lowercased()
            let rhsKey = rhs.lowercased()
            if lhsKey != rhsKey {
                return lhsKey > rhsKey
            }
            return lhs > rhs
        }

        switch selectedFilesSortMethod {
        case .tokenAscending, .tokenDescending:
            result.sort { lhs, rhs in
                let lhsSum = folderTokenSums[lhs.folderPath] ?? 0
                let rhsSum = folderTokenSums[rhs.folderPath] ?? 0
                if lhsSum != rhsSum {
                    return (selectedFilesSortMethod == .tokenAscending) ? lhsSum < rhsSum : lhsSum > rhsSum
                }
                return isCaseInsensitiveAscending(lhs.folderPath, rhs.folderPath)
            }
        case .nameAscending:
            result.sort { isCaseInsensitiveAscending($0.folderPath, $1.folderPath) }
        case .nameDescending:
            result.sort { isCaseInsensitiveDescending($0.folderPath, $1.folderPath) }
        default:
            result.sort { isCaseInsensitiveAscending($0.folderPath, $1.folderPath) }
        }

        return result
    }

    /// Sort a list of files by selectedFilesSortMethod (including token-based).
    private func sortFiles(_ files: [FileViewModel], by method: SortMethod, tokenInfo: [UUID: TokenInfo]) -> [FileViewModel] {
        @inline(__always)
        func isNameAscending(_ lhs: FileViewModel, _ rhs: FileViewModel) -> Bool {
            let lhsKey = lhs.nameSortKey
            let rhsKey = rhs.nameSortKey
            if lhsKey != rhsKey {
                return lhsKey < rhsKey
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            let lhsPathKey = lhs.uniqueRelativePathSortKey
            let rhsPathKey = rhs.uniqueRelativePathSortKey
            if lhsPathKey != rhsPathKey {
                return lhsPathKey < rhsPathKey
            }
            return lhs.uniqueRelativePath < rhs.uniqueRelativePath
        }

        @inline(__always)
        func isNameDescending(_ lhs: FileViewModel, _ rhs: FileViewModel) -> Bool {
            let lhsKey = lhs.nameSortKey
            let rhsKey = rhs.nameSortKey
            if lhsKey != rhsKey {
                return lhsKey > rhsKey
            }
            if lhs.name != rhs.name {
                return lhs.name > rhs.name
            }
            let lhsPathKey = lhs.uniqueRelativePathSortKey
            let rhsPathKey = rhs.uniqueRelativePathSortKey
            if lhsPathKey != rhsPathKey {
                return lhsPathKey > rhsPathKey
            }
            return lhs.uniqueRelativePath > rhs.uniqueRelativePath
        }

        return files.sorted { lhs, rhs in
            switch method {
            case .nameAscending:
                return isNameAscending(lhs, rhs)
            case .nameDescending:
                return isNameDescending(lhs, rhs)
            case .tokenAscending:
                let lhsTokens = tokenInfo[lhs.id]?.count ?? (lhs.cachedTokenCount ?? 0)
                let rhsTokens = tokenInfo[rhs.id]?.count ?? (rhs.cachedTokenCount ?? 0)
                if lhsTokens != rhsTokens {
                    return lhsTokens < rhsTokens
                }
                return isNameAscending(lhs, rhs)
            case .tokenDescending:
                let lhsTokens = tokenInfo[lhs.id]?.count ?? (lhs.cachedTokenCount ?? 0)
                let rhsTokens = tokenInfo[rhs.id]?.count ?? (rhs.cachedTokenCount ?? 0)
                if lhsTokens != rhsTokens {
                    return lhsTokens > rhsTokens
                }
                return isNameAscending(lhs, rhs)
            default:
                // Fall back to name ascending for any other sort methods.
                return isNameAscending(lhs, rhs)
            }
        }
    }

    private func extractFolderPath(from relativePath: String) -> String {
        let comps = relativePath.split(separator: "/")
        guard comps.count > 1 else { return "" }
        return comps.dropLast().joined(separator: "/")
    }

    private func getFolderPath(from relativePath: String) -> String {
        let components = relativePath.split(separator: "/")
        if components.count > 1 {
            return components.dropLast().joined(separator: "/")
        }
        return ""
    }

    func selectFileForPreview(_ file: FileViewModel?) {
        selectedFileForPreview = file
    }

    // MARK: - Token Calculation Methods (Delegates to TokenCountingViewModel)

    func startTokenCountUpdateTimer() {
        tokenCountingViewModel.startTokenCountUpdateTimer()
    }

    func stopTokenCountUpdateTimer() async {
        await tokenCountingViewModel.stopTokenCountUpdateTimer()
    }

    private func configureTokenCountingViewModel() {
        tokenCountingViewModel.configure(
            fileManager: fileManager,
            gitViewModel: gitViewModel,
            getPromptText: { [weak self] in self?.promptText ?? "" },
            getSelectedInstructionsText: { [weak self] in self?.selectedInstructionsText ?? "" },
            getSettings: { [weak self] in
                guard let self else {
                    return TokenCountingViewModel.TokenCalculationSettings(
                        fileTreeOption: .auto,
                        codeMapUsage: .none,
                        filePathDisplayOption: .full,
                        includeFilesInClipboard: true,
                        duplicateUserInstructionsAtTop: false,
                        onlyIncludeRootsWithSelectedFiles: true,
                        codeMapsGloballyDisabled: false
                    )
                }
                return TokenCountingViewModel.TokenCalculationSettings(
                    fileTreeOption: fileTreeOption,
                    codeMapUsage: effectiveCopyCodeMapUsage(),
                    filePathDisplayOption: filePathDisplayOption,
                    includeFilesInClipboard: includeFilesInClipboard,
                    duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
                    onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
                    codeMapsGloballyDisabled: codeMapsGloballyDisabled
                )
            },
            getCopyContext: { [weak self] in
                guard let self else { return .default }
                return currentCopyContextSnapshot()
            },
            getStoredSelection: { [weak self] in
                self?.currentActiveComposeTabStoredSelectionForTokenCounting()
            }
        )
    }

    private func currentActiveComposeTabStoredSelectionForTokenCounting() -> StoredSelection? {
        if !isSwitchingComposeTab, let selectionCoordinator {
            return selectionCoordinator.activeSelectionSnapshot(flushPendingUI: true).selection
        }
        guard let workspaceManager else { return nil }
        let activeTabID = activeComposeTabID
            ?? workspaceManager.activeWorkspace?.activeComposeTabID
            ?? workspaceManager.activeWorkspace?.composeTabs.first?.id
        guard let activeTabID else { return nil }

        if !isSwitchingComposeTab {
            workspaceManager.publishActiveComposeTabSnapshot(commitToMemory: true)
        }
        return workspaceManager.composeTab(with: activeTabID)?.selection
    }

    private func activeComposeTabStoredSelectionForPromptPackaging() -> StoredSelection {
        if let selection = activeComposeTabStoredSelectionSnapshot() {
            return selection
        }
        return legacyRFMSnapshotSelectionForPromptPackaging()
    }

    private func activeComposeTabStoredSelectionSnapshot() -> StoredSelection? {
        if let selectionCoordinator {
            return selectionCoordinator.activeSelectionSnapshot(flushPendingUI: true).selection
        }
        guard let workspaceManager else { return nil }
        let activeTabID = activeComposeTabID
            ?? workspaceManager.activeWorkspace?.activeComposeTabID
            ?? workspaceManager.activeWorkspace?.composeTabs.first?.id
        guard let activeTabID else { return nil }
        return workspaceManager.composeTab(with: activeTabID)?.selection
    }

    private func legacyRFMSnapshotSelectionForPromptPackaging() -> StoredSelection {
        // Legacy/test-only fallback for PromptViewModel instances that are not bound
        // to a WorkspaceManager/compose tab. Normal active copy/chat packaging reads
        // ComposeTabState.selection via activeComposeTabStoredSelectionSnapshot().
        fileManager.snapshotSelection()
    }

    private func currentCopyContextSnapshot() -> TokenCountingViewModel.CopyContextSnapshot {
        let resolved = resolvePromptContext()
        let effectiveTreeMode = resolved.effectiveFileTreeMode
        return TokenCountingViewModel.CopyContextSnapshot(
            includeFiles: resolved.includeFiles,
            includeUserPrompt: resolved.includeUserPrompt,
            includeMetaPrompts: resolved.includeMetaPrompts,
            includeFileTree: resolved.rendersFileTree,
            fileTreeMode: effectiveTreeMode,
            codeMapUsage: resolved.codeMapUsage,
            gitInclusion: resolved.gitInclusion,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop
        )
    }

    private func gatherFileContents() async -> [(FileViewModel, String)] {
        await withTaskGroup(of: (FileViewModel, String)?.self) { group in
            // Capture selected files on main thread
            let selectedFiles = await MainActor.run { self.fileManager.selectedFiles }

            // Load file contents concurrently
            for file in selectedFiles where file.isChecked {
                group.addTask {
                    if let content = await file.latestContent {
                        return (file, "File: \(file.name)\n\(content)")
                    }
                    return nil
                }
            }

            // Gather results
            var contents: [(FileViewModel, String)] = []
            for await result in group {
                if let result {
                    contents.append(result)
                }
            }
            return contents
        }
    }

    private func estimateTokens(for text: String) -> Int {
        // This is a simple estimation. For more accurate results, you might want to use a proper tokenizer.
        Int(Double(text.count) / 4.0)
    }

    // MARK: - Prompt Section Order Methods

    static func resolvedPromptSectionOrder(raw: String) -> [PromptSection] {
        if let d = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([PromptSection].self, from: d),
           Set(decoded) == Set(PromptSection.allCases)
        {
            return decoded
        }
        return PromptAssemblyBuilder.defaultSectionOrder
    }

    func loadPromptSectionOrder() {
        promptSectionsOrder = Self.resolvedPromptSectionOrder(raw: promptSectionsOrderRaw)
    }

    func savePromptSectionOrder() {
        if let d = try? JSONEncoder().encode(promptSectionsOrder) {
            promptSectionsOrderRaw = String(data: d, encoding: .utf8) ?? ""
        }
    }

    @MainActor
    func movePromptSection(from src: IndexSet, to dst: Int) {
        promptSectionsOrder.move(fromOffsets: src, toOffset: dst)
        savePromptSectionOrder()
    }

    // MARK: - Clipboard Operations

    func copyToClipboard() {
        _ = true
        // Capture all necessary properties before Task to minimize actor hopping
        let promptContext = resolvePromptContext()
        let selectionSnapshot = activeComposeTabStoredSelectionForPromptPackaging()
        let metaInstructions = metaInstructions
        let promptText = promptText
        let filePathDisplayOption = filePathDisplayOption
        let includeSavedPrompts = includeSavedPromptsInClipboard
        let includeUserPrompt = includeUserPromptInClipboard
        let includeDatetime = includeDatetimeInUserInstructions
        let promptSectionsOrder = promptSectionsOrder
        let disabledPromptSections = disabledPromptSections
        let duplicateUserInstructions = duplicateUserInstructionsAtTop
        let includeFilesInClipboard = includeFilesInClipboard

        // NEW: Determine active compose tab title (fallback to empty if unavailable)
        let tabTitleForClipboard: String = {
            if let tabID = self.activeComposeTabID,
               let snapshot = self.workspaceManager?.composeTabSnapshot(for: tabID)
            {
                return snapshot.name
            }
            return ""
        }()

        Task {
            let preAssembly = await self.preAssemblePromptContext(
                cfg: promptContext,
                selection: selectionSnapshot,
                lookupContext: self.allLoadedWorkspaceLookupContext()
            )
            let includeFiles = includeFilesInClipboard && !preAssembly.entries.isEmpty

            // Use captured values inside the Task
            let clipboardContent = await PromptPackagingService.generateClipboardContent(
                metaInstructions: metaInstructions,
                userInstructions: promptText,
                files: preAssembly.entries,
                fileTreeContent: preAssembly.fileTreeContent,
                gitDiff: preAssembly.gitDiff,
                includeSavedPrompts: includeSavedPrompts,
                includeFiles: includeFiles,
                includeUserPrompt: includeUserPrompt,
                filePathDisplay: filePathDisplayOption,
                codemapSnapshots: preAssembly.codemapSnapshots,
                includeDatetimeInUserInstructions: includeDatetime,
                promptSectionsOrder: promptSectionsOrder,
                disabledPromptSections: disabledPromptSections,
                duplicateUserInstructionsAtTop: duplicateUserInstructions,
                tabTitle: tabTitleForClipboard
            )

            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(clipboardContent, forType: .string)
            }
        }
    }

    // MARK: - Prompt Management Methods

    func promptSelection(for context: PromptSelectionContext) -> Set<UUID> {
        switch context {
        case .copy:
            selectedPromptIDs
        case .chat:
            selectedPromptIDsForChat
        }
    }

    func defaultPromptIDs(for context: PromptSelectionContext) -> Set<UUID> {
        switch context {
        case .copy:
            let preset = currentCopyPreset()
            let resolved = resolvePromptContext(preset, custom: workingCopyCustomizations)
            let ids = resolved.storedPromptIds ?? preset.storedPromptIds ?? []
            return Set(ids)
        case .chat:
            let preset = currentChatPreset()
            // When useStoredPromptsAsSystem is true with exactly one stored prompt,
            // that prompt is used as the system prompt, not as a meta prompt selection.
            // Return empty set so it doesn't appear in the Prompts button/overlay.
            if preset.useStoredPromptsAsSystem ?? false,
               let ids = preset.storedPromptIds,
               ids.count == 1
            {
                return Set()
            }
            let ids = preset.storedPromptIds ?? []
            return Set(ids)
        }
    }

    func syncPromptSelectionToPreset(for context: PromptSelectionContext, force: Bool = false) {
        let defaults = defaultPromptIDs(for: context)
        switch context {
        case .copy:
            guard force || !hasManualCopyPromptSelection else { return }
            if force || selectedPromptIDs != defaults {
                updatePromptSelection(defaults, for: .copy, markManual: false)
            }
        case .chat:
            guard force || !hasManualChatPromptSelection else { return }
            if force || selectedPromptIDsForChat != defaults {
                updatePromptSelection(defaults, for: .chat, markManual: false)
            }
        }
    }

    func updatePromptSelection(_ newValue: Set<UUID>, for context: PromptSelectionContext, markManual: Bool = true) {
        switch context {
        case .copy:
            let didChange = selectedPromptIDs != newValue
            if didChange {
                selectedPromptIDs = newValue
            }
            hasManualCopyPromptSelection = markManual ? true : false
            // Persist to GlobalSettings when in Manual mode so prompts survive workspace switching
            if didChange, currentCopyPreset().builtInKind == .manual {
                snapshotManualCopySettings(commit: true)
            }
        case .chat:
            let didChange = selectedPromptIDsForChat != newValue
            if didChange {
                selectedPromptIDsForChat = newValue
            }
            hasManualChatPromptSelection = markManual ? true : false
            // Persist to GlobalSettings when in Manual mode
            if didChange, currentChatPreset().id == ChatPreset.BuiltIn.manual.id {
                snapshotManualChatSettings(commit: true)
            }
        }
        updateSelectedInstructions()
    }

    /// Restores chat prompt selection from a chat session without triggering manual-mode persistence.
    /// Called when switching between chat sessions/tabs to ensure the UI reflects the correct session state.
    @MainActor
    func restoreChatPromptSelectionFromSession(_ ids: [UUID]) {
        let restored = Set(ids)
        selectedPromptIDsForChat = restored

        // Infer "manual" vs "defaults" based on whether restored matches current preset defaults
        let defaults = defaultPromptIDs(for: .chat)
        hasManualChatPromptSelection = (restored != defaults)

        updateSelectedInstructions()
    }

    func addStoredPrompt(title: String, content: String) -> StoredPrompt {
        let newPrompt = StoredPrompt(id: UUID(), title: title, content: content)
        storedPrompts.append(newPrompt)
        saveStoredPrompts()
        updateMetaInstructions()
        return newPrompt
    }

    func removeStoredPrompt(_ prompt: StoredPrompt) {
        storedPrompts.removeAll { $0.id == prompt.id }
        if selectedPromptIDs.contains(prompt.id) {
            var currentCopySelection = selectedPromptIDs
            currentCopySelection.remove(prompt.id)
            updatePromptSelection(currentCopySelection, for: .copy)
        }
        if selectedPromptIDsForChat.contains(prompt.id) {
            var currentChatSelection = selectedPromptIDsForChat
            currentChatSelection.remove(prompt.id)
            updatePromptSelection(currentChatSelection, for: .chat)
        }
        saveStoredPrompts()
    }

    func updateStoredPrompt(_ prompt: StoredPrompt) {
        if let index = storedPrompts.firstIndex(where: { $0.id == prompt.id }) {
            var updated = prompt
            // Mark built-in prompts as user-edited so auto-upgrades are skipped
            if builtInPromptIDs.contains(prompt.id) {
                updated.isUserEdited = true
            }
            storedPrompts[index] = updated
            saveStoredPrompts()
            updateSelectedInstructions()
        }
    }

    /// Clears out all saved prompts and re-adds the default ones.
    /// This helps users fix corrupted data quickly.
    func resetUserPrompts() {
        // Clear in-memory prompts
        storedPrompts.removeAll()

        // Write the empty array to the file
        saveStoredPrompts()

        // Re-add the built-in defaults
        insertDefaultPromptsIfNeeded()

        // Save again with the defaults
        saveStoredPrompts()

        // Update selected instructions
        selectedPromptIDs.removeAll()
        updateSelectedInstructions()
    }

    func resetBuiltInPrompts() {
        let builtInDefaults = [architectPrompt, engineerPrompt, mcpPairProgramPrompt, mcpAgentPrompt, reviewPrompt]
        var didMutate = false

        for defaultPrompt in builtInDefaults {
            if let index = storedPrompts.firstIndex(where: { $0.id == defaultPrompt.id }) {
                if storedPrompts[index] != defaultPrompt {
                    storedPrompts[index] = defaultPrompt
                    didMutate = true
                }
            } else {
                storedPrompts.append(defaultPrompt)
                didMutate = true
            }
        }

        if didMutate {
            reorderBuiltInPrompts()
            saveStoredPrompts()
            updateSelectedInstructions()
        }
    }

    private func reorderBuiltInPrompts() {
        let builtInOrder = [
            architectPrompt.id,
            engineerPrompt.id,
            mcpPairProgramPrompt.id,
            mcpAgentPrompt.id,
            reviewPrompt.id
        ]

        let orderedBuiltIns = builtInOrder.compactMap { id in
            storedPrompts.first(where: { $0.id == id })
        }

        let remainingPrompts = storedPrompts.filter { prompt in
            !builtInOrder.contains(prompt.id)
        }

        storedPrompts = orderedBuiltIns + remainingPrompts
    }

    func selectNewPrompt(_ prompt: StoredPrompt, context: PromptSelectionContext = .copy) {
        var next = promptSelection(for: context)
        next.insert(prompt.id)
        updatePromptSelection(next, for: context)
    }

    func togglePromptSelection(_ prompt: StoredPrompt, in context: PromptSelectionContext = .copy) {
        var next = promptSelection(for: context)
        if next.contains(prompt.id) {
            next.remove(prompt.id)
        } else {
            next.insert(prompt.id)
        }
        updatePromptSelection(next, for: context)
    }

    func updateMetaInstructions() {
        // Update regular meta instructions (stored prompts only, NOT system prompts)
        metaInstructions = storedPrompts
            .filter { selectedPromptIDs.contains($0.id) }
            .map { MetaInstruction(title: $0.title, content: $0.content) }

        // Update chat meta instructions
        metaInstructionsForChat = storedPrompts
            .filter { selectedPromptIDsForChat.contains($0.id) }
            .map { MetaInstruction(title: $0.title, content: $0.content) }

        // For token counting, include both stored prompts and live MCP system prompts.
        var allInstructionsForCounting = metaInstructions.map(\.content)

        selectedInstructionsText = allInstructionsForCounting.joined(separator: "\n\n")
        isDirty = true
    }

    func updateSelectedInstructions() {
        updateMetaInstructions()
    }

    func saveStoredPrompts() {
        PromptStorage.shared.savePrompts(storedPrompts)
    }

    func exportPrompts(to url: URL) throws {
        try PromptStorage.shared.exportPrompts(to: url, prompts: storedPrompts)
    }

    func importPrompts(from url: URL) throws -> Int {
        let external = try PromptStorage.shared.loadExternalPrompts(from: url)
        let (merged, addedCount) = PromptStorage.shared.mergeExternalPrompts(
            current: storedPrompts,
            external: external
        )
        if addedCount > 0 {
            storedPrompts = merged
            saveStoredPrompts()
            updateSelectedInstructions() // refresh anything that depends on storedPrompts
        }
        return addedCount
    }

    /// Checks if a persisted built-in prompt matches a known previous canonical version.
    /// Exact matches are preferred so we do not overwrite user-customized prompts.
    private func isKnownPreviousCanonical(_ prompt: StoredPrompt) -> Bool {
        if let previousVariants = previousCanonicalBuiltIns[prompt.id],
           previousVariants.contains(where: { $0.title == prompt.title && $0.content == prompt.content })
        {
            return true
        }

        guard let fingerprintGroups = previousCanonicalFingerprints[prompt.id] else {
            return false
        }
        // Match if ALL phrases in ANY single fingerprint group are present
        return fingerprintGroups.contains { group in
            group.allSatisfy { prompt.content.contains($0) }
        }
    }

    /// Upgrades the planning prompt only when it still matches a known old built-in default.
    /// Prompts that do not match a known canonical snapshot or fingerprint are preserved as user-customized.
    private func upgradePlanningPromptIfNeeded() {
        if customPlanningPrompt.isEmpty {
            customPlanningPrompt = architectPrompt.content
            return
        }

        if customPlanningPrompt == architectPrompt.content {
            return
        }

        let planningPromptCandidate = StoredPrompt(
            id: architectPrompt.id,
            title: architectPrompt.title,
            content: customPlanningPrompt
        )

        if isKnownPreviousCanonical(planningPromptCandidate) {
            customPlanningPrompt = architectPrompt.content
        }
    }

    /// Ensure the default prompts (Architect, Engineer, MCP Pair Program, MCP Agent, MCP Plan, and Review) are available
    private func insertDefaultPromptsIfNeeded() {
        // If architectPrompt not found, add it
        if !storedPrompts.contains(where: { $0.id == architectPrompt.id }) {
            storedPrompts.append(architectPrompt)
        }

        // If engineerPrompt not found, add it
        if !storedPrompts.contains(where: { $0.id == engineerPrompt.id }) {
            storedPrompts.append(engineerPrompt)
        }

        // If mcpPairProgramPrompt not found, add it
        if !storedPrompts.contains(where: { $0.id == mcpPairProgramPrompt.id }) {
            storedPrompts.append(mcpPairProgramPrompt)
        }

        // If mcpAgentPrompt not found, add it
        if !storedPrompts.contains(where: { $0.id == mcpAgentPrompt.id }) {
            storedPrompts.append(mcpAgentPrompt)
        }

        // mcpDiscover is now a built-in system prompt; do not add as stored prompt

        // If reviewPrompt not found, add it
        if !storedPrompts.contains(where: { $0.id == reviewPrompt.id }) {
            storedPrompts.append(reviewPrompt)
        }
    }

    func loadStoredPrompts() {
        let loadResult = PromptStorage.shared.loadPrompts()

        // Handle the load result
        let loadedPrompts: [StoredPrompt]

        switch loadResult {
        case let .success(prompts):
            loadedPrompts = prompts
        case let .failure(error):
            // File exists but couldn't be loaded - DO NOT overwrite!
            print("⚠️ CRITICAL: Cannot load prompts file, aborting to prevent data loss")
            print("⚠️ Error details: \(error)")
            print("⚠️ Keeping current in-memory prompts. User should check file at:")
            print("⚠️ ~/Library/Application Support/com.pvncher.repoprompt/SavedPrompts.json")

            // Keep whatever prompts we have in memory, don't save
            updateMetaInstructions()
            return
        }

        // Separate built-in prompts from user prompts, upgrading unedited built-ins
        let builtInIds = Set(builtInCanonical.keys)
        var resolvedBuiltIns: [UUID: StoredPrompt] = [:]
        var userPrompts: [StoredPrompt] = []
        var needsSave = false

        for prompt in loadedPrompts {
            guard builtInIds.contains(prompt.id) else {
                userPrompts.append(prompt)
                continue
            }

            guard let canonical = builtInCanonical[prompt.id] else { continue }

            if prompt.content == canonical.content, prompt.title == canonical.title {
                // Already up to date
                resolvedBuiltIns[prompt.id] = prompt
            } else if isKnownPreviousCanonical(prompt) {
                // Content matches a known previous canonical version — safe to upgrade,
                // even if an earlier release incorrectly marked it as user-edited.
                resolvedBuiltIns[prompt.id] = canonical
                needsSave = true
            } else if prompt.isUserEdited {
                // User explicitly edited this prompt — keep their version
                resolvedBuiltIns[prompt.id] = prompt
            } else {
                // Content differs from canonical and all known previous versions.
                // This means the user edited it before we started tracking isUserEdited.
                var edited = prompt
                edited.isUserEdited = true
                resolvedBuiltIns[prompt.id] = edited
                needsSave = true
            }
        }

        // Add any built-ins that weren't in the persisted data at all
        let orderedBuiltIns: [StoredPrompt] = [architectPrompt, engineerPrompt, mcpPairProgramPrompt, mcpAgentPrompt, reviewPrompt].map { canonical in
            if let resolved = resolvedBuiltIns[canonical.id] {
                return resolved
            }
            needsSave = true
            return canonical
        }

        // Reorder: built-in prompts first, then user prompts
        storedPrompts = orderedBuiltIns + userPrompts

        if needsSave {
            print("✓ Built-in prompts updated, saving...")
            saveStoredPrompts()
        }

        updateMetaInstructions()
        syncPromptSelectionToPreset(for: .copy, force: false)
        syncPromptSelectionToPreset(for: .chat, force: false)
    }

    // MARK: - AI Query & Chat Methods

    func updateAIQueriesService(_ newService: AIQueriesService?) {
        aiQueriesService = newService
    }

    func cancelQuery() {
        guard isCancellable else { return }
        Task { @MainActor in
            aiQueriesService?.cancelQuery()
            isQueryInProgress = false
            isCancellable = false
        }
    }

    @MainActor
    func clearPrompt() {
        promptText = ""
        Task {
            await fileManager.clearSelection(persistWorkspace: true)
            // Selection cleared - heavy recalculation
            tokenCountingViewModel.markDirty(.selection)
        }
    }

    func sendPromptToChatView() {
        sendPromptAction?()
    }

    /// Current preset resolvers with fallbacks when managers are empty or IDs are nil
    func currentCopyPreset() -> CopyPreset {
        if let id = selectedCopyPresetID,
           let p = CopyPresetManager.shared.preset(with: id)
        {
            return p
        }
        return BuiltInCopyPresets.standard
    }

    func currentChatPreset() -> ChatPreset {
        if let id = selectedChatPresetID {
            return resolvedChatPreset(for: id)
        }
        return ChatPreset.BuiltIn.chat
    }

    private func resolvedChatPreset(for id: UUID) -> ChatPreset {
        if let preset = ChatPresetManager.shared.preset(with: id) {
            return preset
        }
        // Fall back to built-in presets by stable IDs even if the manager
        // hasn't finished loading yet, to avoid mode/UI mismatches.
        if id == ChatPreset.BuiltIn.manual.id { return ChatPreset.BuiltIn.manual }
        if id == ChatPreset.BuiltIn.chat.id { return ChatPreset.BuiltIn.chat }
        if id == ChatPreset.BuiltIn.plan.id { return ChatPreset.BuiltIn.plan }
        if id == ChatPreset.BuiltIn.review.id { return ChatPreset.BuiltIn.review }
        let legacyEditID = UUID(uuidString: "A3333333-3333-3333-3333-333333333333")!
        let legacyDelegatedEditID = UUID(uuidString: "A3333334-3334-3334-3334-333333333334")!
        if id == legacyEditID || id == legacyDelegatedEditID { return ChatPreset.BuiltIn.chat }
        return ChatPreset.BuiltIn.chat
    }

    /// Selection mutators
    func selectCopyPreset(_ id: UUID, applySettings: Bool = true, restoreManualSnapshot: Bool = true) {
        let wasManual = (selectedCopyPresetID == BuiltInCopyPresets.manual.id)
        let willBeManual = (id == BuiltInCopyPresets.manual.id)

        // Preserve RESOLVED settings when leaving a non-Manual preset
        // Capture on ANY transition away from a non-Manual preset (to handle indirect paths via Standard)
        if restoreManualSnapshot, !wasManual, preservedCustomizations == nil {}

        if wasManual, !willBeManual {
            snapshotManualCopySettings(commit: true)
            preservedCustomizations = nil
        }

        guard selectedCopyPresetID != id else {
            // If toggling to Manual while already Manual, still restore snapshot (idempotent)
            if willBeManual, restoreManualSnapshot {
                restoreManualCopySettingsIfAvailable()
            }
            return
        }

        // Track the last non-manual preset before switching
        if let currentID = selectedCopyPresetID,
           currentID != BuiltInCopyPresets.manual.id,
           id == BuiltInCopyPresets.manual.id
        {
            // Switching TO manual from a non-manual preset - persist it
            persistLastNonManualCopyPreset(presetID: currentID)
        }
        selectedCopyPresetID = id

        // Apply preset settings if requested (but not when entering Manual)
        if applySettings, !willBeManual {
            let preset = CopyPresetManager.shared.preset(with: id) ?? BuiltInCopyPresets.standard
            // Clear ALL non-manual overrides to avoid leaking manual tweaks into built-in presets
            if workingCopyCustomizations.hasCustomizations {
                var overrides = workingCopyCustomizations
                overrides.gitInclusion = nil
                overrides.fileTreeMode = nil
                overrides.codeMapUsage = nil
                overrides.includeFiles = nil
                overrides.includeUserPrompt = nil
                overrides.includeMetaPrompts = nil
                overrides.includeFileTree = nil
                workingCopyCustomizations = overrides
            }

            let cfg = resolvePromptContext(preset, custom: workingCopyCustomizations)

            // Apply file tree setting
            fileTreeOption = cfg.fileTreeMode

            // Apply raw preset codemap setting. A global override affects effective output only.
            codeMapUsage = Self.resolveCopyCodeMapUsage(
                isManualPreset: false,
                customCodeMapUsage: nil,
                presetCodeMapUsage: preset.codeMapUsage,
                uiCodeMapUsage: codeMapUsage,
                globallyDisabled: false
            )

            // Apply git inclusion setting (3-way mapping)
            let gitMode: GitDiffInclusionMode = switch cfg.gitInclusion {
            case .none: .none
            case .selected: .selectedFiles
            case .complete: .all
            }
            gitDiffInclusionModeForCopy = gitMode
        }

        if willBeManual {
            if applySettings, restoreManualSnapshot {
                restoreManualCopySettingsIfAvailable()
            }
            if restoreManualSnapshot, let preserved = preservedCustomizations {
                workingCopyCustomizations = preserved
                preservedCustomizations = nil
                markSettingsDirty()
            }
        }

        // Ensure codemap scanning runs when the newly selected preset requires it.
        let preset = CopyPresetManager.shared.preset(with: id) ?? BuiltInCopyPresets.standard
        let cfg = resolvePromptContext(preset, custom: workingCopyCustomizations)
        if cfg.codeMapUsage != .none {
            Task { await fileManager.setCodeScanEnabled(true) }
        }

        // Only force-sync when switching to a non-manual preset
        if !willBeManual {
            syncPromptSelectionToPreset(for: .copy, force: true)
        }

        // Presets can toggle includes (files/user/meta/tree), xml/system flavor, etc.
        // Treat as settings change to rebuild baseline immediately.
        tokenCountingViewModel.markDirty(.settings)
    }

    @MainActor
    func selectChatPreset(_ id: UUID) {
        let preset = resolvedChatPreset(for: id)
        applyChatPreset(preset, using: id)
    }

    // MARK: - Manual-by-Intent Methods

    /// Ensures manual mode is active when user attempts to customize settings
    /// Returns true if switched to manual, false if already manual or blocked
    @MainActor
    func ensureManualModeOnUserCustomization() -> Bool {
        guard !isApplyingPresetOverrides else { return false }
        if currentCopyPreset().builtInKind != .manual {
            // When user customizes in a non-manual preset, switch to Manual
            // but DON'T snapshot yet - the snapshot will happen when leaving Manual
            selectCopyPreset(BuiltInCopyPresets.manual.id, applySettings: false, restoreManualSnapshot: false)
            return true
        }
        return false
    }

    @MainActor
    private func ensureManualChatPresetOnUserCustomization() {
        guard !isApplyingChatPreset else { return }
        if currentChatPreset().id != ChatPreset.BuiltIn.manual.id {
            // Same policy as copy: preserve current edited chat settings as Manual baseline
            snapshotManualChatSettings(commit: true)
            // also persist the "last non-manual" preset for banner/restore
            persistLastNonManualChatPreset(current: currentChatPreset())
            applyChatPreset(ChatPreset.BuiltIn.manual, using: ChatPreset.BuiltIn.manual.id)
        }
    }

    @MainActor
    func ensureManualPresetFor(context: PromptSelectionContext) {
        switch context {
        case .copy:
            _ = ensureManualModeOnUserCustomization()
        case .chat:
            ensureManualChatPresetOnUserCustomization()
        }
    }

    // MARK: - Manual snapshots (persisted)

    private func snapshotManualCopySettings(commit: Bool) {
        guard let workspaceID = currentWorkspaceID else { return }
        var s = settingsManager.copySettings(for: workspaceID)
        let sanitizedManualCustomizations = workingCopyCustomizations.removingCodeMapUsageOverride()
        s.manualFileTreeOption = fileTreeOption
        s.manualCodeMapUsage = codeMapUsage
        s.manualGitInclusion = gitDiffInclusionModeForCopy
        s.manualSelectedPromptIDs = selectedPromptIDs
        s.manualHasManualPromptSelection = hasManualCopyPromptSelection
        s.manualWorkingCopyCustomizations = sanitizedManualCustomizations.hasCustomizations
            ? sanitizedManualCustomizations
            : nil
        settingsManager.updateCopySettings(s, commit: commit)
    }

    private func restoreManualCopySettingsIfAvailable() {
        guard let workspaceID = currentWorkspaceID else { return }
        let s = settingsManager.copySettings(for: workspaceID)
        let sanitizedManualCustomizations = s.manualWorkingCopyCustomizations?
            .removingCodeMapUsageOverride()
        let persistedManualCustomizations = sanitizedManualCustomizations?.hasCustomizations == true
            ? sanitizedManualCustomizations
            : nil
        if let v = s.manualFileTreeOption { fileTreeOption = v }
        if let v = s.manualCodeMapUsage { codeMapUsage = v }
        if let v = s.manualGitInclusion { gitDiffInclusionModeForCopy = v }
        if let v = s.manualSelectedPromptIDs {
            selectedPromptIDs = v
        }
        if let v = s.manualHasManualPromptSelection { hasManualCopyPromptSelection = v }
        workingCopyCustomizations = persistedManualCustomizations ?? .init()
        if persistedManualCustomizations != s.manualWorkingCopyCustomizations {
            var updatedSettings = s
            updatedSettings.manualWorkingCopyCustomizations = persistedManualCustomizations
            settingsManager.updateCopySettings(updatedSettings, commit: true)
        }
        updateSelectedInstructions()
    }

    private func snapshotManualChatSettings(commit: Bool) {
        guard let workspaceID = currentWorkspaceID else { return }
        var s = settingsManager.chatSettings(for: workspaceID)
        s.manualFileTreeOption = fileTreeOptionForChat
        s.manualCodeMapUsage = codeMapUsageForChat
        s.manualGitInclusion = gitDiffInclusionModeForChat
        s.manualPlanActMode = planActMode
        s.manualSelectedPromptIDs = selectedPromptIDsForChat
        s.manualHasManualPromptSelection = hasManualChatPromptSelection
        settingsManager.updateChatSettings(s, commit: commit)
    }

    private func restoreManualChatSettingsIfAvailable() {
        guard let workspaceID = currentWorkspaceID else { return }
        let s = settingsManager.chatSettings(for: workspaceID)
        if let v = s.manualFileTreeOption { fileTreeOptionForChat = v }
        if let v = s.manualCodeMapUsage { codeMapUsageForChat = v }
        if let v = s.manualGitInclusion { gitDiffInclusionModeForChat = v }
        if let v = s.manualPlanActMode { planActMode = v == .edit ? .chat : v }
        if let v = s.manualSelectedPromptIDs { selectedPromptIDsForChat = v }
        if let v = s.manualHasManualPromptSelection { hasManualChatPromptSelection = v }
        updateSelectedInstructions()
    }

    private func persistLastNonManualChatPreset(current: ChatPreset) {
        guard let workspaceID = currentWorkspaceID else { return }
        var s = settingsManager.chatSettings(for: workspaceID)
        s.lastNonManualChatPresetID = current.id
        s.lastNonManualChatPresetName = current.name
        settingsManager.updateChatSettings(s, commit: true)
        lastNonManualChatPresetID = current.id
        lastNonManualChatPresetName = current.name
    }

    private func persistLastNonManualCopyPreset(presetID: UUID) {
        guard let workspaceID = currentWorkspaceID else { return }
        var s = settingsManager.copySettings(for: workspaceID)
        s.lastNonManualCopyPresetID = presetID
        settingsManager.updateCopySettings(s, commit: true)
        lastNonManualCopyPresetID = presetID
    }

    /// Switches to manual mode for editing (used by lock overlay)
    @MainActor
    func switchToManualForEditing() {
        selectCopyPreset(BuiltInCopyPresets.manual.id)
    }

    /// Applies preset overrides to the current settings
    @MainActor
    func applyCopyPresetOverridesFromSelection(_ preset: CopyPreset) {
        isApplyingPresetOverrides = true
        defer { isApplyingPresetOverrides = false }

        if let ft = preset.fileTreeMode {
            fileTreeOption = ft
            markSettingsDirty()
        }
        if let cm = preset.codeMapUsage {
            codeMapUsage = cm
            markSettingsDirty()
        }
        if let gi = preset.gitInclusion {
            switch gi {
            case .none:
                gitViewModel.gitDiffInclusionMode = .none
            case .selected:
                gitViewModel.gitDiffInclusionMode = .selectedFiles
            case .complete:
                gitViewModel.gitDiffInclusionMode = .all
            }
        } else {
            // New behavior: when a preset does not specify git inclusion,
            // reset to the safe default (.none) so git doesn't stay "sticky"
            gitViewModel.gitDiffInclusionMode = .none
        }
    }

    func packagePrompt(
        conversation: [ConversationEntry],
        overrideModel: AIModel? = nil,
        overridePromptConfig: PromptContextResolved? = nil,
        overrideChatPreset: ChatPreset? = nil,
        overrideMode: PlanActMode? = nil,
        gitInclusionOverride: GitInclusion? = nil,
        gitBaseOverride: String? = nil,
        selectionOverride: StoredSelection? = nil,
        lookupContextOverride: WorkspaceLookupContext? = nil
    ) async -> AIMessage {
        // Use pro file edit based on the specified or current chat preset
        let preset = overrideChatPreset ?? currentChatPreset()
        var resolvedConfig: PromptContextResolved = {
            if let overridePromptConfig {
                return overridePromptConfig
            }
            if let chatResolved = resolvedPromptContext(from: preset) {
                return chatResolved
            }
            return resolvePromptContext()
        }()
        if let gitInclusionOverride {
            resolvedConfig.gitInclusion = gitInclusionOverride
        }
        let activeConfig = applyingGlobalCodeMapOverride(resolvedConfig)
        let logicalSelection = selectionOverride ?? activeComposeTabStoredSelectionForPromptPackaging()
        let lookupContext = lookupContextOverride ?? allLoadedWorkspaceLookupContext()

        // Determine effective read-only mode. Legacy/manual edit settings are treated as Chat.
        let effectiveMode: PlanActMode = {
            if let override = overrideMode { return override == .edit ? .chat : override }
            if preset.id == ChatPreset.BuiltIn.manual.id {
                return self.planActMode == .edit ? .chat : self.planActMode
            }
            switch preset.mode {
            case .chat: return .chat
            case .plan: return .plan
            case .review: return .review
            }
        }()

        // Resolve value-backed file entries before system/local-definition assembly so
        // active chat packaging no longer needs FileViewModel selection snapshots.
        let filePathDisplay = filePathDisplayOption
        let temperature = setModelTemperature ? modelTemperature : nil
        let preAssembly = await preAssemblePromptContext(
            cfg: activeConfig,
            selection: logicalSelection,
            lookupContext: lookupContext,
            includeLocalDefinitionsInFileTree: true,
            gitBaseOverride: gitBaseOverride
        )
        let (_, codeEntries) = PromptPackagingService.partitionPromptEntriesForGitDiff(preAssembly.entries)

        // Identify a stored prompt to be used as SYSTEM prompt when configured
        let idsCandidate = activeConfig.storedPromptIds ?? preset.storedPromptIds
        var systemStoredPrompt: StoredPrompt? = nil
        if preset.useStoredPromptsAsSystem ?? false,
           let ids = idsCandidate,
           ids.count == 1,
           let only = ids.first,
           let found = storedPrompts.first(where: { $0.id == only })
        {
            systemStoredPrompt = found
        }
        let useStoredAsSystem = (systemStoredPrompt != nil)

        // Build system prompt (generic rules; no "isReviewPreset")
        var systemPrompt: String
        switch effectiveMode {
        case .plan:
            systemPrompt = customPlanningPrompt.isEmpty ? architectPrompt.content : customPlanningPrompt
            systemPrompt += "\n\nYou may include one chat-name tag on its own line near the top: <chatName=\\\"Unique name describing user request\\\"/>"
            systemPrompt += "\n\nProvide your response in clean, well-formatted Markdown. Use proper headings, lists, code blocks, and other Markdown elements to make your response easy to read and understand. Do not emit machine-readable edit blocks."
        case .chat, .review, .edit:
            if let sp = systemStoredPrompt {
                // Use the configured stored prompt as SYSTEM prompt
                systemPrompt = sp.content
                systemPrompt += "\n\nYou may include one chat-name tag on its own line near the top: <chatName=\"Unique name describing user request\"/>"
                systemPrompt += "\n\nProvide your response in clean, well-formatted Markdown. Use proper headings, lists, code blocks, and other Markdown elements to make your response easy to read and understand. Do not emit machine-readable edit blocks."
            } else {
                // Default chat prompt
                systemPrompt = getChatPrompt()
            }
        }

        // Build file contents with effective code map usage
        let fileBlocks = PromptPackagingService.generateFileContents(
            codeEntries,
            filePathDisplay: filePathDisplay,
            codemapSnapshots: preAssembly.codemapSnapshots,
            displayPathResolver: { entry in
                preAssembly.displayPath(for: entry)
            }
        )
        let fileTreeString = preAssembly.fileTreeContent ?? ""
        let gitDiff = preAssembly.gitDiff

        // Meta prompts:
        // - If override supplies stored prompts AND they are NOT used as system, use them.
        // - Otherwise, use global chat meta; when a stored prompt is used as system, exclude it from meta.
        let metaForThisChat: [MetaInstruction] = {
            if let ids = activeConfig.storedPromptIds, !ids.isEmpty, !useStoredAsSystem {
                let selected = storedPrompts.filter { ids.contains($0.id) }
                return selected.map { MetaInstruction(title: $0.title, content: $0.content) }
            }
            if let sys = systemStoredPrompt {
                return metaInstructionsForChat.filter { $0.title != sys.title }
            }
            return metaInstructionsForChat
        }()

        return PromptPackagingService.buildAIMessage(
            systemPrompt: systemPrompt,
            metaInstructions: metaForThisChat,
            fileTree: fileTreeString,
            fileContents: fileBlocks,
            gitDiff: gitDiff,
            conversation: conversation, // Pass conversation unchanged (no MCP metadata injection in chat history)
            temperature: temperature,
            promptSectionsOrder: promptSectionsOrder,
            disabledPromptSections: disabledPromptSections,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop
        )
    }

    func getSystemPrompt() -> String {
        if fileManager.visibleRootFolders.isEmpty {
            return "You are a helpful assistant operating in an app called Repo Prompt designed by the talented programmer Eric Provencher. His twitter handle is (@pvncher). The app works best if the user selects a folder. Chat with the user and answer any questions they may have to the best of your knowledge. Format responses in Markdown. You may include one chat-name tag on its own line near the top: <chatName=\"Unique name describing user request\"/>"
        }

        return "You are a helpful assistant operating in an app called Repo Prompt designed by the talented programmer Eric Provencher. His twitter handle is (@pvncher). Chat with the user and answer any questions they may have to the best of your knowledge. Format responses in Markdown. If file changes are needed, describe them in prose or Markdown code blocks rather than machine-readable edit blocks. You may include one chat-name tag on its own line near the top: <chatName=\"Unique name describing user request\"/>"
    }

    func getChatPrompt() -> String {
        if fileManager.visibleRootFolders.isEmpty {
            return """
            Answer clearly and directly. Format every response in markdown.

            If a question would benefit from repository context, suggest selecting a folder.

            You may include one descriptive chat-name tag on its own line near the top:

            <chatName=\"Brief description of chat topic\"/>
            """
        }

        return """
        Answer clearly and directly. Format every response in markdown.

        Ground repository-specific answers in the provided context.

        You may include one descriptive chat-name tag on its own line near the top:

        <chatName=\"Brief description of chat topic\"/>
        """
    }

    func getSystemPrompt(for model: AIModel) -> String {
        if fileManager.visibleRootFolders.isEmpty {
            return "You are a helpful assistant operating in an app called Repo Prompt designed by the talented programmer Eric Provencher. His twitter handle is (@pvncher). The app works best if the user selects a folder. Chat with the user and answer any questions they may have to the best of your knowledge. Format responses in Markdown. You may include one chat-name tag on its own line near the top: <chatName=\\\"Unique name describing user request\\\"/>"
        }

        return "You are a helpful assistant operating in an app called Repo Prompt designed by the talented programmer Eric Provencher. His twitter handle is (@pvncher). Chat with the user and answer any questions they may have to the best of your knowledge. Format responses in Markdown. If file changes are needed, describe them in prose or Markdown code blocks rather than machine-readable edit blocks. You may include one chat-name tag on its own line near the top: <chatName=\\\"Unique name describing user request\\\"/>"
    }

    // MARK: - Model and Settings Management

    @MainActor
    func refreshAvailableModels() async {
        await apiSettingsViewModel?.loadStoredData {
            self.refreshModelSelectionState()
        }
    }

    @MainActor
    func refreshModelSelectionState() {
        // Only validate models AFTER they are fully updated and we have received the callback
        availableModels = apiSettingsViewModel?.availableModels ?? []
        syncModelSelectionFromSettingsManager()
        validatePreferredModel()
    }

    /// Checks if a model's provider has an API key configured.
    /// This is more stable than checking array membership, which can fail when enum definitions change.
    @MainActor
    private func isProviderConfigured(for model: AIModel) -> Bool {
        guard let api = apiSettingsViewModel else { return false }

        switch model.providerType {
        case .anthropic:
            return api.isAnthropicKeyValid
        case .openAI:
            return api.isOpenAIKeyValid
        case .gemini:
            return api.isGeminiKeyValid
        case .azure:
            return api.isAzureKeyValid
        case .openRouter:
            return api.isOpenRouterKeyValid
        case .ollama:
            return api.isOllamaURLValid && api.isOllamaModelValid
        case .deepseek:
            return api.isDeepSeekKeyValid
        case .fireworks:
            return api.isFireworksKeyValid
        case .customProvider:
            return api.isCustomProviderValid
        case .grok:
            return api.isGrokKeyValid
        case .groq:
            return api.isGroqKeyValid
        case .zAI:
            return api.isZaiKeyValid
        case .claudeCode:
            if let backendID = ClaudeCodeAIModelCatalog.compatibleBackendID(for: model) {
                return api.compatibleBackendIsActive(backendID)
            }
            return api.isClaudeCodeConnected
        case .codex:
            return api.isCodexConnected
        case .openCode:
            return api.isOpenCodeConnected
        case .cursor:
            return api.isCursorConnected
        }
    }

    /// Checks if a stored model rawValue is safe to preserve as a preference.
    /// Runtime CLI availability is intentionally not treated as a persistence invariant because
    /// launch-time provider probes can be transiently cold while the stored preference is valid.
    /// Returns true if:
    /// - The model can be parsed AND its provider has an API key configured, OR
    /// - The model is a CLI-backed preference whose provider may become available later, OR
    /// - The model is a custom model type (always considered available if parseable), OR
    /// - The rawValue is non-empty but can't be parsed (preserve for forward compatibility)
    @MainActor
    private func isModelPreferencePreservable(_ rawValue: String) -> Bool {
        // Empty rawValue is invalid - needs fallback
        guard !rawValue.isEmpty else { return false }

        // Try to parse the rawValue
        if let model = AIModel.fromModelName(rawValue) {
            // Custom models are always valid (user explicitly configured them)
            if model.isCustom { return true }
            switch model.providerType {
            case .claudeCode, .codex, .openCode, .cursor:
                return true
            default:
                // Check if the model's provider has an API key configured
                return isProviderConfigured(for: model)
            }
        }

        // If we can't parse the rawValue, it might be from a newer version or a renamed model.
        // Preserve it rather than resetting - only reset if there are no available models at all.
        // This prevents preferences from being reset when enum definitions change during development.
        return true
    }

    @MainActor
    private func validatePreferredModel() {
        // Validate the persisted compose default using preservability, not transient runtime availability.
        if sessionPreferredModelOverrideRaw == nil, !isModelPreferencePreservable(preferredModel) {
            pickDiffCapableFallback()
        }

        // Validate context builder model
        if !isModelPreferencePreservable(_contextBuilderModel) {
            pickContextBuilderFallbackModel()
        }

        // Do not auto-heal the dedicated Oracle planning model here. MCP Oracle paths
        // resolve it strictly so empty, invalid, or unavailable explicit values surface
        // the same failure in ask_oracle and oracle_utils op=models instead of being
        // silently replaced by a preferred/default fallback during model refresh.
    }

    @MainActor
    private func pickDiffCapableFallback() {
        // 1) High
        if let model = AIModel.findBestAvailableModel(
            in: availableModels,
            desiredFormat: .diff,
            priorities: AIModel.highDiffPriority
        ) {
            setPreferredModelRaw(model.rawValue, markDirty: false, reason: "prompt.validate_preferred_model.fallback.diff.high")
            return
        }
        // 2) Medium
        if let model = AIModel.findBestAvailableModel(
            in: availableModels,
            desiredFormat: .diff,
            priorities: AIModel.mediumDiffPriority
        ) {
            setPreferredModelRaw(model.rawValue, markDirty: false, reason: "prompt.validate_preferred_model.fallback.diff.medium")
            return
        }
        // 3) Simple
        if let model = AIModel.findBestAvailableModel(
            in: availableModels,
            desiredFormat: .diff,
            priorities: AIModel.simpleDiffPriority
        ) {
            setPreferredModelRaw(model.rawValue, markDirty: false, reason: "prompt.validate_preferred_model.fallback.diff.simple")
            return
        }

        // 4) Otherwise fallback to first available or empty
        if !availableModels.isEmpty {
            setPreferredModelRaw(availableModels[0].rawValue, markDirty: false, reason: "prompt.validate_preferred_model.fallback.first_available")
        } else {
            setPreferredModelRaw("", markDirty: false, reason: "prompt.validate_preferred_model.fallback.empty")
        }
    }

    @MainActor
    private func pickContextBuilderFallbackModel() {
        // Priority: Simple Whole -> Medium Whole -> High Whole -> First Available
        if let model = AIModel.findBestAvailableModel(
            in: availableModels,
            desiredFormat: .whole, // Context builder prefers whole file models
            priorities: AIModel.simpleWholePriority
        ) {
            _contextBuilderModel = model.rawValue
            return
        }
        if let model = AIModel.findBestAvailableModel(
            in: availableModels,
            desiredFormat: .whole,
            priorities: AIModel.mediumWholePriority
        ) {
            _contextBuilderModel = model.rawValue
            return
        }
        if let model = AIModel.findBestAvailableModel(
            in: availableModels,
            desiredFormat: .whole,
            priorities: AIModel.highWholePriority
        ) {
            _contextBuilderModel = model.rawValue
            return
        }

        // Fallback to the first available model if no suitable 'whole' model found
        if !availableModels.isEmpty {
            _contextBuilderModel = preferredModel
        } else {
            _contextBuilderModel = "" // No models available
        }
    }

    func hasValidModelSelected() async -> Bool {
        await refreshAvailableModels()
        guard !preferredModel.isEmpty, !availableModels.isEmpty else { return false }
        return isModelCurrentlyUsable(preferredModel)
    }

    /// Checks if a model is available for use.
    /// Uses provider-based validation for stability when model definitions change.
    @MainActor
    private func isModelCurrentlyUsable(_ rawValue: String) -> Bool {
        guard !rawValue.isEmpty else { return false }
        guard let model = AIModel.fromModelName(rawValue) else {
            return !availableModels.isEmpty
        }
        return isModelAvailable(model)
    }

    @MainActor
    func isModelAvailable(_ model: AIModel) -> Bool {
        // Custom models are always considered available if parseable
        if model.isCustom { return true }
        // Check if the model's provider has an API key configured
        // This is more stable than array membership which can fail when enum definitions change
        return isProviderConfigured(for: model)
    }

    // MARK: - Code Map Methods

    private var hasEffectiveCodeMapAccess: Bool {
        true && !codeMapsGloballyDisabled
    }

    private func shouldEnableCodeScanning() -> Bool {
        hasEffectiveCodeMapAccess && (codeMapUsage != .none || codeMapUsageForChat != .none)
    }

    @MainActor
    private func refreshCodeScanEnabledForEffectiveState() async {
        await fileManager.setCodeScanEnabled(shouldEnableCodeScanning())
    }

    @MainActor
    func cancelCodeMapScans() async {
        await fileManager.cancelCodeMapScans()
    }

    private func handleCodeMapsGloballyDisabledChanged(_ disabled: Bool) {
        guard codeMapsGloballyDisabled != disabled else { return }
        codeMapsGloballyDisabled = disabled
        tokenCountingViewModel.markDirty(.codeMap.union(.fileTree))
        isDirty = true
        Task {
            await refreshCodeScanEnabledForEffectiveState()
        }
    }

    func updateCodeMapEffectiveState() {
        Task {
            await refreshCodeScanEnabledForEffectiveState()
        }
    }

    /// Resets the code map cache and triggers a rescan of all files
    @MainActor
    func resetCodeMapCache() async {
        // Clear all code map caches and trigger rescan
        await fileManager.clearCodeMapCaches()
    }

    func resetPlanningPromptToDefault() {
        customPlanningPrompt = architectPrompt.content
    }

    // MARK: - Utility

    @MainActor
    func getSelectedPromptIDsSnapshot() -> [UUID] {
        // Keep snapshot in sync even if didSet didn't run during init-time
        if selectedPromptIDsArraySnapshot.count != selectedPromptIDs.count {
            selectedPromptIDsArraySnapshot = selectedPromptIDs.sorted { $0.uuidString < $1.uuidString }
        }
        return selectedPromptIDsArraySnapshot
    }

    deinit {
        activeTabApplyTask?.cancel()
        cancellables.removeAll()
        /*
         // Stop any background timer/work owned by the token counter.
         let counter = tokenCountingViewModel
         Task { await counter.stopTokenCountUpdateTimer() }
         */
    }

    private func canonicalTabIndex(from name: String) -> Int? {
        name.stripLeadingTNumber()
    }
}

private extension String {
    func stripLeadingTNumber() -> Int? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return nil }
        let prefix = trimmed.prefix(1)
        guard prefix == "T" || prefix == "t" else { return nil }
        let numberPart = trimmed.dropFirst()
        return Int(numberPart)
    }
}

extension Notification.Name {
    static let activeComposeTabChanged = Notification.Name("activeComposeTabChanged")
}

extension PromptViewModel {
    nonisolated static func resolveCopyCodeMapUsage(
        isManualPreset: Bool,
        customCodeMapUsage: CodeMapUsage?,
        presetCodeMapUsage: CodeMapUsage?,
        uiCodeMapUsage: CodeMapUsage,
        globallyDisabled: Bool = false
    ) -> CodeMapUsage {
        guard !globallyDisabled else { return .none }
        if isManualPreset {
            return uiCodeMapUsage
        }
        return presetCodeMapUsage ?? uiCodeMapUsage
    }

    func resolvePromptContext() -> PromptContextResolved {
        let preset = currentCopyPreset()
        return resolvePromptContext(preset, custom: workingCopyCustomizations)
    }

    /// Returns the effective codeMapUsage after resolving presets, customizations, and CE availability.
    /// Use this instead of reading `codeMapUsage` directly to ensure UI and token pipeline stay in sync.
    func effectiveCopyCodeMapUsage() -> CodeMapUsage {
        resolvePromptContext().codeMapUsage
    }

    /// Returns the effective codeMapUsage for chat context.
    func effectiveChatCodeMapUsage() -> CodeMapUsage {
        // Mirror the copy resolver pattern for chat.
        if codeMapsGloballyDisabled {
            return .none
        }
        return codeMapUsageForChat
    }

    /// Internal resolver that merges a preset with working customizations and current UI defaults.
    func resolvePromptContext(_ preset: CopyPreset, custom: CopyCustomizations?) -> PromptContextResolved {
        // Manual preset is the only place where per-workspace overrides apply
        let isManualPreset = (preset.builtInKind == .manual) || (preset.id == BuiltInCopyPresets.manual.id)
        let effectiveCustom = isManualPreset ? custom : nil

        // Merge include flags (force to true since UI elements were removed)
        let includeFiles = (effectiveCustom?.includeFiles ?? preset.includeFiles) ?? true
        let includeUserPrompt = (effectiveCustom?.includeUserPrompt ?? preset.includeUserPrompt) ?? true
        let includeMetaPrompts = (effectiveCustom?.includeMetaPrompts ?? preset.includeMetaPrompts) ?? true
        let includeFileTree = (effectiveCustom?.includeFileTree ?? preset.includeFileTree) ?? true

        // File-tree and code-map behaviour (fallback to current UI)
        let desiredFileTreeMode = effectiveCustom?.fileTreeMode ?? preset.fileTreeMode ?? fileTreeOption

        let desiredCodeMapUsage = Self.resolveCopyCodeMapUsage(
            isManualPreset: isManualPreset,
            customCodeMapUsage: effectiveCustom?.codeMapUsage,
            presetCodeMapUsage: preset.codeMapUsage,
            uiCodeMapUsage: codeMapUsage,
            globallyDisabled: codeMapsGloballyDisabled
        )

        let desiredGitInclusion = Self.mapGitInclusion(
            custom: effectiveCustom?.gitInclusion,
            preset: preset.gitInclusion,
            uiMode: gitViewModel.gitDiffInclusionMode,
            isManualPreset: isManualPreset
        )

        return PromptContextResolved(
            includeFiles: includeFiles,
            includeUserPrompt: includeUserPrompt,
            includeMetaPrompts: includeMetaPrompts,
            includeFileTree: includeFileTree,
            fileTreeMode: desiredFileTreeMode,
            codeMapUsage: desiredCodeMapUsage,
            gitInclusion: desiredGitInclusion,
            storedPromptIds: preset.storedPromptIds
        )
    }

    private func applyingGlobalCodeMapOverride(_ cfg: PromptContextResolved) -> PromptContextResolved {
        guard codeMapsGloballyDisabled else { return cfg }
        var copy = cfg
        copy.codeMapUsage = .none
        return copy
    }

    /// Returns a copy of `cfg` with `codeMapUsage` overridden when provided.
    /// Does not mutate any @Published/AppStorage state.
    /// Used by context builder to normalize selection to `.auto` mode without affecting user's preset.
    func contextWithCodeMapUsageOverride(
        _ cfg: PromptContextResolved,
        override: CodeMapUsage?
    ) -> PromptContextResolved {
        var copy = cfg
        if codeMapsGloballyDisabled {
            copy.codeMapUsage = .none
            return copy
        }
        guard let override else { return copy }
        copy.codeMapUsage = override
        return copy
    }
}

extension PromptViewModel {
    static func mapGitInclusion(
        custom: GitInclusion?,
        preset: GitInclusion?,
        uiMode: GitDiffInclusionMode,
        isManualPreset: Bool
    ) -> GitInclusion {
        if let c = custom { return c }
        if let p = preset { return p }
        if isManualPreset {
            switch uiMode {
            case .none:
                return .none
            case .selectedFiles:
                return .selected
            case .all:
                return .complete
            }
        }
        return .none
    }

    func metaInstructions(
        for cfg: PromptContextResolved,
        selectedPromptIDsOverride: [UUID]? = nil
    ) -> [MetaInstruction] {
        // Compose user-selected meta prompts when requested.
        var combinedMeta: [MetaInstruction] = []
        // Add stored prompts: preset's specific prompts OR manually selected for Manual mode
        if let promptIds = cfg.storedPromptIds, !promptIds.isEmpty {
            // Preset has specific stored prompts - use those
            let selectedPrompts = storedPrompts.filter { promptIds.contains($0.id) }
            let metaFromIds = selectedPrompts.map { MetaInstruction(title: $0.title, content: $0.content) }
            combinedMeta.append(contentsOf: metaFromIds)
        } else if cfg.includeMetaPrompts {
            if let overrideIds = selectedPromptIDsOverride {
                let selectedPrompts = storedPrompts.filter { overrideIds.contains($0.id) }
                let metaFromIds = selectedPrompts.map { MetaInstruction(title: $0.title, content: $0.content) }
                combinedMeta.append(contentsOf: metaFromIds)
            } else {
                // Manual mode or preset without specific prompts - use manually selected meta instructions
                combinedMeta.append(contentsOf: metaInstructions)
            }
        }
        // Discover is now a hardcoded system prompt; no need to append dynamic coverage meta here.
        return combinedMeta
    }

    func allLoadedWorkspaceLookupContext() -> WorkspaceLookupContext {
        WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
    }

    func preAssemblePromptContext(
        cfg: PromptContextResolved,
        selection: StoredSelection,
        lookupContext: WorkspaceLookupContext,
        includeLocalDefinitionsInFileTree: Bool = false,
        gitBaseOverride: String? = nil
    ) async -> PromptContextPreAssemblyResult {
        let diffBase = gitBaseOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBase = (diffBase?.isEmpty == false) ? diffBase : nil
        let gitVM = gitViewModel
        return await PromptContextPreAssemblyService.resolve(
            PromptContextPreAssemblyRequest(
                cfg: cfg,
                selection: selection,
                store: workspaceFileContextStore,
                lookupContext: lookupContext,
                filePathDisplay: filePathDisplayOption,
                onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
                showCodeMapMarkers: !codeMapsGloballyDisabled,
                selectedGitDiffFolderPolicy: .expandFolders,
                selectedGitDiffLookupProfile: .uiAssisted,
                includeLocalDefinitionsInFileTree: includeLocalDefinitionsInFileTree,
                selectedGitDiffProvider: { [gitVM] selectedPaths in
                    await gitVM.getDiffForAbsolutePaths(selectedPaths, vs: effectiveBase, forceRefreshStatus: true)
                },
                completeGitDiffProvider: { [gitVM] in
                    await gitVM.getDiffUsing(inclusionMode: .all, vs: effectiveBase, forceRefreshStatus: true)
                }
            )
        )
    }

    /// Builds clipboard content using a resolved configuration without mutating any AppStorage/UI state.
    func buildClipboard(
        for inputConfig: PromptContextResolved,
        promptTextOverride: String? = nil,
        selectionOverride: StoredSelection? = nil,
        includeLocalDefinitionsInFileTree: Bool = false
    ) async -> String {
        let cfg = applyingGlobalCodeMapOverride(inputConfig)
        let promptText = promptTextOverride ?? promptText
        let effectiveSelection = selectionOverride ?? activeComposeTabStoredSelectionForPromptPackaging()
        let preAssembly = await preAssemblePromptContext(
            cfg: cfg,
            selection: effectiveSelection,
            lookupContext: allLoadedWorkspaceLookupContext(),
            includeLocalDefinitionsInFileTree: includeLocalDefinitionsInFileTree
        )

        // 2.5) Meta prompts assembly.
        let combinedMeta = metaInstructions(for: cfg)
        let includeMetaBlock = !combinedMeta.isEmpty

        // 3) Generate clipboard string via existing packaging service
        return await PromptPackagingService.generateClipboardContent(
            metaInstructions: combinedMeta,
            userInstructions: cfg.includeUserPrompt ? promptText : "",
            files: preAssembly.entries,
            fileTreeContent: preAssembly.fileTreeContent,
            gitDiff: preAssembly.gitDiff,
            includeSavedPrompts: includeMetaBlock,
            includeFiles: cfg.includeFiles,
            includeUserPrompt: cfg.includeUserPrompt,
            filePathDisplay: filePathDisplayOption,
            codemapSnapshots: preAssembly.codemapSnapshots,
            includeDatetimeInUserInstructions: includeDatetimeInUserInstructions,
            promptSectionsOrder: promptSectionsOrder,
            disabledPromptSections: disabledPromptSections,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop
        )
    }

    /// Estimates the token count for the current Copy context (what would be copied now)
    /// Uses the resolved copy preset (including manual overrides) and builds the exact clipboard payload.
    func calculateTokensForCopyContext() async -> Int {
        await calculateTokensForCopyContext(using: currentCopyPreset())
    }

    /// Estimates the token count for a specific Copy preset without mutating UI state.
    func calculateTokensForCopyContext(using preset: CopyPreset, promptTextOverride: String? = nil) async -> Int {
        let cfg = resolvePromptContext(preset, custom: workingCopyCustomizations)
        let text = await buildClipboard(for: cfg, promptTextOverride: promptTextOverride)
        return estimateTokens(for: text)
    }

    private func chatPresetTokenBaselineKey(_ preset: ChatPreset) -> ChatPresetTokenBaselineKey {
        ChatPresetTokenBaselineKey(
            id: preset.id,
            mode: preset.mode,
            modelPresetName: preset.modelPresetName,
            fileTreeMode: preset.fileTreeMode,
            codeMapUsage: preset.codeMapUsage,
            gitInclusion: preset.gitInclusion,
            storedPromptIds: preset.storedPromptIds ?? [],
            useStoredPromptsAsSystem: preset.useStoredPromptsAsSystem ?? false
        )
    }

    private func promptContextTokenBaselineKey(_ cfg: PromptContextResolved) -> PromptContextTokenBaselineKey {
        PromptContextTokenBaselineKey(
            includeFiles: cfg.includeFiles,
            includeUserPrompt: cfg.includeUserPrompt,
            includeMetaPrompts: cfg.includeMetaPrompts,
            includeFileTree: cfg.includeFileTree,
            fileTreeMode: cfg.fileTreeMode,
            codeMapUsage: cfg.codeMapUsage,
            gitInclusion: cfg.gitInclusion,
            storedPromptIds: cfg.storedPromptIds ?? []
        )
    }

    private func chatContextTokenBaselineCacheKey(
        chatPreset: ChatPreset,
        config cfg: PromptContextResolved
    ) -> ChatContextTokenBaselineCacheKey {
        let disabledSections = disabledPromptSections.sorted { $0.rawValue < $1.rawValue }
        let selectedPromptIDs = selectedPromptIDsForChat.sorted { $0.uuidString < $1.uuidString }
        let storedPromptKeys = storedPrompts.map {
            StoredPromptTokenBaselineKey(
                id: $0.id,
                title: $0.title,
                content: $0.content,
                isUserEdited: $0.isUserEdited
            )
        }
        let rootOrder = fileManager.visibleRootFolders.map {
            RootTokenBaselineKey(
                id: $0.id,
                fullPath: $0.fullPath,
                name: $0.name,
                isSystemRoot: $0.isSystemRoot
            )
        }

        return ChatContextTokenBaselineCacheKey(
            workspaceID: currentWorkspaceID,
            selectedChatPresetID: selectedChatPresetID,
            chatPreset: chatPresetTokenBaselineKey(chatPreset),
            resolvedContext: promptContextTokenBaselineKey(cfg),
            fileTreeOptionForChat: fileTreeOptionForChat,
            codeMapUsageForChat: codeMapUsageForChat,
            gitDiffInclusionModeForChat: gitDiffInclusionModeForChat,
            codeMapsGloballyDisabled: codeMapsGloballyDisabled,
            filePathDisplayOption: filePathDisplayOption,
            selectedFilesSortMethod: selectedFilesSortMethod,
            fileTreeSortMethod: fileManager.currentSortMethod,
            onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
            includeDatetimeInUserInstructions: includeDatetimeInUserInstructions,
            promptSectionsOrder: promptSectionsOrder,
            disabledPromptSections: disabledSections,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
            selectedPromptIDsForChat: selectedPromptIDs,
            hasManualChatPromptSelection: hasManualChatPromptSelection,
            storedPrompts: storedPromptKeys,
            hierarchyGenerationSignature: fileManager.currentHierarchyGenerationSignature(),
            rootOrder: rootOrder,
            selectionVersion: chatSelectionVersion,
            slicesVersion: chatSlicesVersion,
            autoCodemapVersion: chatAutoCodemapVersion,
            fileAPIsVersion: chatFileAPIsVersion,
            fileSystemDeltaVersion: chatFileSystemDeltaVersion
        )
    }

    private func promptTextDuplicateFactor(for cfg: PromptContextResolved) -> Int {
        guard cfg.includeUserPrompt else { return 0 }
        var factor = disabledPromptSections.contains(.userInstructions) ? 0 : 1
        if duplicateUserInstructionsAtTop {
            factor += 1
        }
        return factor
    }

    /// Estimates the token count for the current Chat context.
    /// If the chat preset references a specific copy preset, that configuration is used; otherwise falls back to current state.
    func calculateTokensForChatContext() async -> Int {
        let chatPreset = currentChatPreset()
        // Prefer the chat preset's resolved configuration (includes git/meta/system flavor overrides),
        // falling back to the current copy configuration only if unavailable.
        let cfg: PromptContextResolved = resolvedPromptContext(from: chatPreset) ?? resolvePromptContext()
        guard cfg.gitInclusion == .none else {
            let text = await buildClipboard(for: cfg, includeLocalDefinitionsInFileTree: true)
            return estimateTokens(for: text)
        }
        let cacheKey = chatContextTokenBaselineCacheKey(chatPreset: chatPreset, config: cfg)
        let promptTextSnapshot = promptText
        let promptTextTokens = estimateTokens(for: promptTextSnapshot)
        let duplicateFactor = promptTextDuplicateFactor(for: cfg)
        let hasPromptText = !promptTextSnapshot.isEmpty

        if let cache = chatContextTokenBaselineCache, cache.key == cacheKey {
            if hasPromptText, cache.supportsPromptTextDeltas {
                return cache.baseTokensWithoutPromptText + (promptTextTokens * duplicateFactor)
            }
            if !hasPromptText, let emptyPromptTokenCount = cache.emptyPromptTokenCount {
                return emptyPromptTokenCount
            }
        }

        let text = await buildClipboard(
            for: cfg,
            promptTextOverride: promptTextSnapshot,
            includeLocalDefinitionsInFileTree: true
        )
        let tokenCount = estimateTokens(for: text)

        let currentChatPreset = currentChatPreset()
        let currentCfg: PromptContextResolved = resolvedPromptContext(from: currentChatPreset) ?? resolvePromptContext()
        let currentCacheKey = chatContextTokenBaselineCacheKey(chatPreset: currentChatPreset, config: currentCfg)
        if currentCacheKey == cacheKey {
            chatContextTokenBaselineCache = ChatContextTokenBaselineCache(
                key: cacheKey,
                baseTokensWithoutPromptText: max(0, tokenCount - (promptTextTokens * duplicateFactor)),
                supportsPromptTextDeltas: hasPromptText && duplicateFactor > 0,
                emptyPromptTokenCount: hasPromptText ? nil : tokenCount
            )
        }

        return tokenCount
    }

    /// Resolve, build and place the clipboard content for a specific copy preset without mutating UI state.
    /// The `openApplyXMLTab` parameter is retained for existing Agent call sites but is ignored now that the Apply XML UI is removed.
    func performCopy(using preset: CopyPreset, promptTextOverride: String? = nil, openApplyXMLTab: Bool = true) {
        let cfg = resolvePromptContext(preset, custom: workingCopyCustomizations)
        Task {
            let clipboard = await buildClipboard(for: cfg, promptTextOverride: promptTextOverride)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(clipboard, forType: .string)
        }
    }

    /// Resolve, build and place the clipboard content.
    /// The `openApplyXMLTab` parameter is retained for existing Agent call sites but is ignored now that the Apply XML UI is removed.
    func performCopyUsingCurrentPreset(openApplyXMLTab: Bool = true) {
        performCopy(using: currentCopyPreset(), openApplyXMLTab: openApplyXMLTab)
    }

    /// Applies the selected chat preset's mode to the current plan/chat/edit state.
    func applyChatPresetMode(using presetOverride: ChatPreset? = nil) {
        let chatPreset = presetOverride ?? currentChatPreset()
        let desiredMode: PlanActMode = switch chatPreset.mode {
        case .chat:
            .chat
        case .plan:
            .plan
        case .review:
            .review
        }
        if planActMode != desiredMode {
            planActMode = desiredMode
        }
    }

    @MainActor
    func applyChatPreset(_ preset: ChatPreset, using identifier: UUID? = nil) {
        guard !isApplyingChatPreset else { return }
        isApplyingChatPreset = true
        defer { isApplyingChatPreset = false }

        let previousPreset = currentChatPreset() // capture BEFORE mutation
        let wasManual = (selectedChatPresetID == ChatPreset.BuiltIn.manual.id)
        let willBeManual = (preset.id == ChatPreset.BuiltIn.manual.id)
        if wasManual, !willBeManual {
            // Leaving Manual → persist snapshot of manual chat state
            snapshotManualChatSettings(commit: true)
        }

        let targetID = identifier ?? preset.id
        let didChangePreset = selectedChatPresetID != targetID
        selectedChatPresetID = targetID

        applyChatPresetMode(using: preset)

        // If we are entering Manual, restore the saved manual snapshot AFTER mode update
        if !wasManual, willBeManual {
            restoreManualChatSettingsIfAvailable()
            // Persist the previous (non-manual) preset *before* we lose it
            persistLastNonManualChatPreset(current: previousPreset)
            if didChangePreset {
                markSettingsDirty()
            }
            return
        }

        let cfg: PromptContextResolved = resolvedPromptContext(from: preset) ?? resolvePromptContext()
        if cfg.codeMapUsage != .none {
            Task { await fileManager.setCodeScanEnabled(true) }
        }

        // Preset-specific configs are resolved on demand; avoid mutating manual defaults.
        if willBeManual {
            if didChangePreset {
                markSettingsDirty()
            }
            return
        }

        var appliedExplicitSettings = false

        if let fileTree = preset.fileTreeMode {
            if fileTreeOptionForChat != fileTree {
                fileTreeOptionForChat = fileTree
                appliedExplicitSettings = true
            }
        }

        if let codeMap = preset.codeMapUsage {
            if codeMapUsageForChat != codeMap {
                codeMapUsageForChat = codeMap
                appliedExplicitSettings = true
            }
        }

        if let gitSetting = preset.gitInclusion {
            let newMode: GitDiffInclusionMode = switch gitSetting {
            case .none:
                .none
            case .selected:
                .selectedFiles
            case .complete:
                .all
            }
            if gitDiffInclusionModeForChat != newMode {
                gitDiffInclusionModeForChat = newMode
            }
            gitViewModel.gitDiffInclusionMode = newMode
            appliedExplicitSettings = true
        } else if gitDiffInclusionModeForChat != .none {
            gitDiffInclusionModeForChat = .none
            gitViewModel.gitDiffInclusionMode = .none
            appliedExplicitSettings = true
        }

        if didChangePreset {
            markSettingsDirty()
        } else if appliedExplicitSettings {
            // Ensure dependent systems refresh even if preset ID was unchanged
            markSettingsDirty()
        }

        // Only force-sync when switching to a non-manual preset
        if !willBeManual {
            syncPromptSelectionToPreset(for: .chat, force: true)
        }
    }

    /// Build a resolved config from a ChatPreset when it does not reference a CopyPreset.
    func resolvedPromptContext(from chatPreset: ChatPreset) -> PromptContextResolved? {
        // Synthesize from ChatPreset fields, using current UI defaults as fallback
        let isManualChatPreset = (chatPreset.id == ChatPreset.BuiltIn.manual.id)
        let resolvedGit: GitInclusion = if let gi = chatPreset.gitInclusion {
            gi
        } else if isManualChatPreset {
            switch gitDiffInclusionModeForChat {
            case .none:
                .none
            case .selectedFiles:
                .selected
            case .all:
                .complete
            }
        } else {
            switch gitDiffInclusionModeForChat {
            case .none:
                .none
            case .selectedFiles:
                .selected
            case .all:
                .complete
            }
        }

        return PromptContextResolved(
            includeFiles: true,
            includeUserPrompt: true,
            includeMetaPrompts: true,
            includeFileTree: true,
            fileTreeMode: chatPreset.fileTreeMode ?? fileTreeOptionForChat,
            codeMapUsage: codeMapsGloballyDisabled ? .none : (chatPreset.codeMapUsage ?? codeMapUsageForChat),
            gitInclusion: resolvedGit,
            storedPromptIds: chatPreset.storedPromptIds
        )
    }

    func modelFromChatPreset(_ preset: ChatPreset) -> AIModel? {
        guard let raw = preset.modelPresetName, !raw.isEmpty else { return nil }

        // First try direct AIModel rawValue lookup
        if let model = AIModel.fromModelName(raw) {
            return model
        }

        // If that fails, try looking up by ModelPreset name
        // (modelPresetName can be either a raw model string OR a ModelPreset name)
        if let modelPreset = ModelPresetsManager.shared.preset(named: raw) {
            return modelPreset.optionalModel
        }

        return nil
    }

    func modelFromCurrentChatPreset() -> AIModel? {
        let preset = currentChatPreset()
        return modelFromChatPreset(preset)
    }
}

extension Array {
    func asyncCompactMap<T>(_ transform: (Element) async -> T?) async -> [T] {
        var values = [T]()
        for element in self {
            if let transformed = await transform(element) {
                values.append(transformed)
            }
        }
        return values
    }
}

enum PromptError: Error {
    case aiServiceNotAvailable
}

enum AIResponseError: Error {
    case invalidData
}

enum FilePathDisplay: String, CaseIterable {
    case full = "Full"
    case relative = "Relative"
}
