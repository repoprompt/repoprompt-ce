import Combine
import Foundation
import RepoPromptDomainRuntime
import RepoPromptFoundation
import RepoPromptShared

// MARK: - Codex Hook Approval Settings

@MainActor
package protocol CodexHookApprovalSettingsProviding {
    func codexHookApprovalStrictModeEnabled(workspaceID: UUID?) -> Bool
}

// MARK: - Global Settings Store (Persistent)

/// This is the single source of truth for workspace default settings.
/// Primary persistence is the Application Support JSON document at
/// `~/Library/Application Support/RepoPrompt CE/Settings/globalSettings.json`.
/// Windows use WindowSettingsManager to maintain local overlays.
@MainActor
package class GlobalSettingsStore: ObservableObject, CodexHookApprovalSettingsProviding {
    package static let shared = GlobalSettingsStore()

    /// App composition installs a synchronous adapter before settings-driven feature work.
    /// Events are emitted at the original memory/write boundary, including commit=false.
    package static var applicationEventHandler: (@MainActor (GlobalSettingsEvent, GlobalSettingsStore) -> Void)?
    package var eventHandler: (@MainActor (GlobalSettingsEvent, GlobalSettingsStore) -> Void)?

    private func emit(_ event: GlobalSettingsEvent) {
        (eventHandler ?? Self.applicationEventHandler)?(event, self)
    }

    private static let defaultUserDefaults: UserDefaults = {
        if SettingsProcessEnvironment.isUnitTestProcess {
            return UserDefaults(suiteName: "RepoPromptCE.unit-settings.\(UUID().uuidString)")!
        }
        return .standard
    }()

    package let defaults: UserDefaults
    private let fileStore: GlobalSettingsFileStoring
    private let invalidAgentModelsProfileAssertion: (String) -> Void

    @Published package private(set) var copySettings: [UUID: CopyGlobalSettings] = [:]
    @Published package private(set) var chatSettings: [UUID: ChatGlobalSettings] = [:]
    @Published package private(set) var agentModelsSettingsByWorkspaceID: [UUID: WorkspaceAgentModelsSettings] = [:]
    @Published package private(set) var codeMapsGloballyDisabled: Bool = false
    @Published package private(set) var nonGitCodeMapsEnabled: Bool = false
    @Published package private(set) var modelRouterSettingsRevision: UInt64 = 0
    /// Non-nil when the on-disk settings file is blocked (unreadable or a newer schema).
    /// UI surfaces this when the store cannot safely repair the document automatically.
    @Published package private(set) var persistenceBlockReason: GlobalSettingsPersistenceBlockReason? {
        didSet { reconcilePersistenceBlockDismissal() }
    }

    /// True when a failed startup migration must be retried through the raw-preserving
    /// transaction instead of the ordinary typed save path.
    package var isPendingPreservingMigrationRetry: Bool {
        fileStore.hasPendingStartupMigration
    }

    @Published package private(set) var sessionDismissedPersistenceBlockReason: GlobalSettingsPersistenceBlockReason?

    package var globalDefaults = GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil)
    package var scalarPreferences = GlobalScalarPreferences()

    private static let defaultAppearanceModeRaw = "System"
    private static let defaultFilePathDisplayOptionRaw = "Full"
    private static let defaultSelectedFilesSortMethodRaw = "nameAscending"
    private static let defaultFileEditFormatRaw = "Diff"
    private static let defaultComplexEditStrategyRaw = "Sequential split"
    package static let telemetryEnabledDefaultsKey = "telemetry.enabled"
    private static let settingsWriteDiagnosticsLimit = 80

    private var settingsWriteDiagnostics: [GlobalSettingsWriteDiagnostic] = []

    package init(
        defaults: UserDefaults? = nil,
        fileStore: GlobalSettingsFileStoring = GlobalSettingsFileStore(),
        invalidAgentModelsProfileAssertion: @escaping (String) -> Void = { assertionFailure($0) }
    ) {
        self.defaults = defaults ?? Self.defaultUserDefaults
        self.fileStore = fileStore
        self.invalidAgentModelsProfileAssertion = invalidAgentModelsProfileAssertion
        load()
        reconcilePersistenceBlockDismissal()
    }

    package func reloadFontScaleBodySizeFromDisk(normalize: (Double) -> Double) -> Double? {
        do {
            let document = try fileStore.load()
            guard let diskRawValue = document.scalarPreferences?.ui?.fontScaleBodySize else {
                return nil
            }
            let normalized = normalize(diskRawValue)
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

    package func recentSettingsWriteDiagnostics() -> [GlobalSettingsWriteDiagnostic] {
        settingsWriteDiagnostics
    }

    package func dismissCurrentPersistenceBlockForSession() {
        sessionDismissedPersistenceBlockReason = persistenceBlockReason
    }

    package var isCurrentPersistenceBlockDismissedForSession: Bool {
        guard let persistenceBlockReason else { return false }
        return sessionDismissedPersistenceBlockReason == persistenceBlockReason
    }

    private func reconcilePersistenceBlockDismissal() {
        guard let persistenceBlockReason else {
            sessionDismissedPersistenceBlockReason = nil
            return
        }
        if sessionDismissedPersistenceBlockReason != persistenceBlockReason {
            sessionDismissedPersistenceBlockReason = nil
        }
    }

    package func recordSettingsWriteDiagnostic(
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

    package func copySettings(for workspaceID: UUID) -> CopyGlobalSettings {
        if let existing = copySettings[workspaceID] {
            return existing
        }
        // Create default settings for new workspace
        let newSettings = CopyGlobalSettings(workspaceID: workspaceID)
        copySettings[workspaceID] = newSettings
        save()
        return newSettings
    }

    package func chatSettings(for workspaceID: UUID) -> ChatGlobalSettings {
        chatSettingsResult(for: workspaceID).settings
    }

    /// Returns chat settings for a workspace, along with whether they were newly created.
    /// Use this when you need to know if this is a brand new workspace (for auto-apply).
    package func chatSettingsResult(for workspaceID: UUID) -> (settings: ChatGlobalSettings, isNew: Bool) {
        if let existing = chatSettings[workspaceID] {
            return (existing, false)
        }
        // Create default settings for new workspace
        let newSettings = ChatGlobalSettings(workspaceID: workspaceID)
        chatSettings[workspaceID] = newSettings
        save()
        return (newSettings, true)
    }

    package func updateCopySettings(_ settings: CopyGlobalSettings) {
        copySettings[settings.workspaceID] = settings
        save()
    }

    package func updateCopySettings(_ settings: CopyGlobalSettings, commit: Bool) {
        copySettings[settings.workspaceID] = settings
        if commit {
            save()
        }
    }

    package func updateChatSettings(_ settings: ChatGlobalSettings) {
        chatSettings[settings.workspaceID] = settings
        // NOTE: We no longer sync workspace Context Builder agent/model to global defaults here.
        // Global Context Builder settings are now the single source of truth, updated only via
        // setGlobalContextBuilderAgentSelection() when the user explicitly changes them.
        save()
    }

    package func updateChatSettings(_ settings: ChatGlobalSettings, commit: Bool) {
        chatSettings[settings.workspaceID] = settings
        // NOTE: We no longer sync workspace Context Builder agent/model to global defaults here.
        // Global Context Builder settings are now the single source of truth.
        if commit {
            save()
        }
    }

    // MARK: - Scoped Agent Models Settings

    package func globalAgentModelsProfile() -> AgentModelsSettingsProfile {
        AgentModelsSettingsProfile(
            planningModelRaw: scalarPreferences.modelSelection?.planningModel,
            additionalOracleModelRaws: scalarPreferences.modelSelection?.additionalOracleModels ?? [],
            oracleReconciliationGuidance: scalarPreferences.modelSelection?.oracleReconciliationGuidance,
            preferredComposeModelRaw: scalarPreferences.modelSelection?.preferredComposeModel,
            syncChatModelWithOracle: resolvedSyncChatModelWithOracleFromCurrentPreferences(),
            contextBuilderAgentRaw: globalDefaults.discoverAgentRaw,
            contextBuilderModelsByAgent: globalDefaults.discoverModelsByAgent,
            mcpAgentRoleOverrides: globalDefaults.mcpAgentRoleOverrides,
            restrictMCPAgentDiscoveryToRoleLabels: restrictMCPAgentDiscoveryToRoleLabels(),
            mcpAgentRoleModelParameters: globalDefaults.mcpAgentRoleModelParameters,
            contextBuilderModelParametersByAgent: globalDefaults.contextBuilderModelParametersByAgent
        )
    }

    package func setGlobalAgentModelsProfile(
        _ profile: AgentModelsSettingsProfile,
        contextBuilderWriteIntent: ContextBuilderSettingsWriteIntent
    ) {
        let oldProfile = globalAgentModelsProfile()
        let normalized = normalizedAgentModelsProfile(profile)
        var modelSelection = scalarPreferences.modelSelection ?? GlobalScalarPreferences.ModelSelectionSettings()
        modelSelection.planningModel = normalized.planningModelRaw
        modelSelection.additionalOracleModels = normalized.additionalOracleModelRaws.isEmpty
            ? nil
            : normalized.additionalOracleModelRaws
        modelSelection.oracleReconciliationGuidance = normalized.oracleReconciliationGuidance
        modelSelection.preferredComposeModel = normalized.preferredComposeModelRaw
        modelSelection.syncChatModelWithOracle = normalized.syncChatModelWithOracle
        scalarPreferences.modelSelection = modelSelection

        var agentMode = scalarPreferences.agentMode ?? GlobalScalarPreferences.AgentModeSettings()
        agentMode.restrictMCPAgentDiscoveryToRoleLabels = normalized.restrictMCPAgentDiscoveryToRoleLabels
        scalarPreferences.agentMode = agentMode

        globalDefaults.discoverAgentRaw = normalized.contextBuilderAgentRaw
        globalDefaults.discoverModelsByAgent = normalized.contextBuilderModelsByAgent
        globalDefaults.mcpAgentRoleOverrides = normalized.mcpAgentRoleOverrides
        globalDefaults.mcpAgentRoleModelParameters = normalized.mcpAgentRoleModelParameters
        globalDefaults.contextBuilderModelParametersByAgent = normalized.contextBuilderModelParametersByAgent
        switch contextBuilderWriteIntent {
        case .preserveExistingOwnership:
            break
        case .userInitiated:
            globalDefaults.didUserSetDiscoverAgentDefaults = true
        case .automaticSeed:
            if globalDefaults.didUserSetDiscoverAgentDefaults != true {
                globalDefaults.didUserSetDiscoverAgentDefaults = false
            }
        }

        recordAgentModelsProfileWriteDiagnostic(
            scope: .global,
            workspaceID: nil,
            oldProfile: oldProfile,
            newProfile: normalized,
            attemptedProfile: profile
        )

        objectWillChange.send()
        save()
        postAgentModelsSettingsDidChange(scope: .global)
    }

    package func workspaceAgentModelsSettings(for workspaceID: UUID) -> WorkspaceAgentModelsSettings {
        agentModelsSettingsByWorkspaceID[workspaceID] ?? WorkspaceAgentModelsSettings()
    }

    package func setWorkspaceAgentModelsInheritanceMode(
        workspaceID: UUID,
        mode: AgentModelsInheritanceMode
    ) {
        var settings = agentModelsSettingsByWorkspaceID[workspaceID] ?? WorkspaceAgentModelsSettings()
        let oldProfile = settings.profile
        settings.inheritanceMode = mode
        if mode == .useWorkspaceOverrides, settings.profile == nil {
            settings.profile = globalAgentModelsProfile()
        }
        agentModelsSettingsByWorkspaceID[workspaceID] = settings
        if oldProfile != settings.profile, let newProfile = settings.profile {
            recordAgentModelsProfileWriteDiagnostic(
                scope: .workspace,
                workspaceID: workspaceID,
                oldProfile: oldProfile,
                newProfile: newProfile
            )
        }
        save()
        postAgentModelsSettingsDidChange(scope: .workspace(workspaceID))
    }

    package func workspaceAgentModelsProfile(for workspaceID: UUID) -> AgentModelsSettingsProfile? {
        agentModelsSettingsByWorkspaceID[workspaceID]?.profile
    }

    package func setWorkspaceAgentModelsProfile(
        workspaceID: UUID,
        profile: AgentModelsSettingsProfile
    ) {
        let existing = agentModelsSettingsByWorkspaceID[workspaceID]
        let oldProfile = existing?.profile
        let normalized = normalizedAgentModelsProfile(profile)
        let settings = WorkspaceAgentModelsSettings(
            inheritanceMode: existing?.inheritanceMode ?? .useWorkspaceOverrides,
            profile: normalized
        )
        agentModelsSettingsByWorkspaceID[workspaceID] = settings
        recordAgentModelsProfileWriteDiagnostic(
            scope: .workspace,
            workspaceID: workspaceID,
            oldProfile: oldProfile,
            newProfile: normalized,
            attemptedProfile: profile
        )
        save()
        postAgentModelsSettingsDidChange(scope: .workspace(workspaceID))
    }

    package func effectiveAgentModelsProfile(workspaceID: UUID?) -> AgentModelsSettingsProfile {
        guard let workspaceID else { return globalAgentModelsProfile() }
        let settings = workspaceAgentModelsSettings(for: workspaceID)
        guard settings.inheritanceMode == .useWorkspaceOverrides,
              let profile = settings.profile
        else {
            return globalAgentModelsProfile()
        }
        return normalizedAgentModelsProfile(profile)
    }

    /// Removes hidden OpenAI service-tier wrappers from every Agent Models profile
    /// in one durable transaction. Notifications are synchronous and emitted only
    /// after the complete state has been installed and saved.
    package func normalizeDisabledOpenAIServiceTierVariants(normalizeModelRaw: (String) -> String) {
        func normalized(_ raw: String?) -> String? {
            guard let raw else { return nil }
            return normalizeModelRaw(raw)
        }

        func normalizedTieredRoleOverrides(_ overrides: [String: String]?) -> [String: String]? {
            overrides?.mapValues { raw in
                guard let selection = AgentModelSelectionID.parse(raw) else { return raw }
                let modelRaw = normalizeModelRaw(selection.modelRaw)
                guard modelRaw != selection.modelRaw,
                      !modelRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    return raw
                }
                return AgentModelSelectionID(agentRaw: selection.agentRaw, modelRaw: modelRaw).rawValue
            }
        }

        var globalChanged = false
        var modelSelection = scalarPreferences.modelSelection ?? GlobalScalarPreferences.ModelSelectionSettings()
        let planning = normalized(modelSelection.planningModel)
        let additional = modelSelection.additionalOracleModels?.compactMap(normalized)
        let compose = normalized(modelSelection.preferredComposeModel)
        if planning != modelSelection.planningModel
            || additional != modelSelection.additionalOracleModels
            || compose != modelSelection.preferredComposeModel
        {
            modelSelection.planningModel = planning
            modelSelection.additionalOracleModels = additional?.isEmpty == false ? additional : nil
            modelSelection.preferredComposeModel = compose
            scalarPreferences.modelSelection = modelSelection
            globalChanged = true
        }
        if let models = globalDefaults.discoverModelsByAgent {
            let next = models.mapValues { normalizeModelRaw($0) }
            if next != models {
                globalDefaults.discoverModelsByAgent = next
                globalChanged = true
            }
        }
        let roleOverrides = normalizedTieredRoleOverrides(globalDefaults.mcpAgentRoleOverrides)
        if roleOverrides != globalDefaults.mcpAgentRoleOverrides {
            globalDefaults.mcpAgentRoleOverrides = roleOverrides
            globalChanged = true
        }

        var changedWorkspaceIDs: [UUID] = []
        for workspaceID in agentModelsSettingsByWorkspaceID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var settings = agentModelsSettingsByWorkspaceID[workspaceID], var profile = settings.profile else { continue }
            let old = profile
            profile.planningModelRaw = normalized(profile.planningModelRaw)
            profile.additionalOracleModelRaws = profile.additionalOracleModelRaws.compactMap(normalized)
            profile.preferredComposeModelRaw = normalized(profile.preferredComposeModelRaw)
            if let models = profile.contextBuilderModelsByAgent {
                profile.contextBuilderModelsByAgent = models.mapValues { normalizeModelRaw($0) }
            }
            profile.mcpAgentRoleOverrides = normalizedTieredRoleOverrides(profile.mcpAgentRoleOverrides)
            guard profile != old else { continue }
            settings.profile = profile
            agentModelsSettingsByWorkspaceID[workspaceID] = settings
            changedWorkspaceIDs.append(workspaceID)
        }

        let legacyKey = "contextBuilderModel"
        if let raw = defaults.string(forKey: legacyKey) {
            let next = normalizeModelRaw(raw)
            if next != raw {
                defaults.set(next, forKey: legacyKey)
            }
        }

        guard globalChanged || !changedWorkspaceIDs.isEmpty else { return }
        objectWillChange.send()
        save()
        if globalChanged {
            postAgentModelsSettingsDidChange(scope: .global)
        }
        for workspaceID in changedWorkspaceIDs {
            postAgentModelsSettingsDidChange(scope: .workspace(workspaceID))
        }
    }

    package func setAgentModelsMCPAgentRoleOverrides(
        _ overrides: [String: String]?,
        scope: AgentModelsEditingScope
    ) {
        updateAgentModelsProfile(scope: scope) { profile in
            profile.mcpAgentRoleOverrides = overrides
        }
    }

    /// Atomic Context Builder pin write: persist the displayed agent+model choice and
    /// set/clear that agent's parameter bucket in one profile mutation.
    package func setAgentModelsContextBuilderModelParameter(
        _ selections: [ACPModelParameterSelection]?,
        agentRaw: String?,
        modelRaw: String,
        scope: AgentModelsEditingScope
    ) {
        // The write durably commits the displayed Context Builder agent+model alongside the pin,
        // so it must claim user ownership exactly as the existing Context Builder model setters
        // do. With `.preserveExistingOwnership` the global ownership flag stays false, automatic
        // recommendation application stays eligible, it moves the Context Builder model, and
        // profile coherence then drops the bucket — silently erasing the pin the user just set.
        // Skip a no-op. `.userInitiated` claims user ownership of the Context Builder defaults,
        // so writing it for a click that changes nothing would silently revoke automatic
        // recommendation eligibility.
        let current = agentModelsProfile(for: scope)
        let next = current.replacingContextBuilderModelParameter(
            selections,
            for: agentRaw,
            modelRaw: modelRaw
        )
        guard next != current else { return }
        updateAgentModelsProfile(scope: scope, contextBuilderWriteIntent: .userInitiated) { profile in
            profile = next
        }
    }

    /// Atomic role-pin write: persist the displayed model choice as the role override and
    /// set/clear the role's parameter bucket in one profile mutation, so the two never diverge.
    package func setAgentModelsRoleModelParameter(
        _ selections: [ACPModelParameterSelection]?,
        roleRawValue: String,
        displayedSelectionID: AgentModelSelectionID,
        scope: AgentModelsEditingScope
    ) {
        // Skip a no-op, matching the Context Builder setter. Now that clearing is scoped to the
        // displayed model, re-picking an already-checked "Default" on a recommendation-tracking
        // role produces an identical profile — writing and broadcasting it would be pure churn.
        let current = agentModelsProfile(for: scope)
        let next = current.replacingRoleModelParameter(
            selections,
            for: roleRawValue,
            displayedSelectionID: displayedSelectionID
        )
        guard next != current else { return }
        updateAgentModelsProfile(scope: scope) { profile in
            profile = next
        }
    }

    package func copyAgentModelsProfile(
        from source: AgentModelsEditingScope,
        to destination: AgentModelsEditingScope
    ) {
        let profile = agentModelsProfile(for: source)
        switch destination {
        case .global:
            setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: .userInitiated)
        case let .workspace(workspaceID):
            let oldProfile = agentModelsSettingsByWorkspaceID[workspaceID]?.profile
            let normalized = normalizedAgentModelsProfile(profile)
            agentModelsSettingsByWorkspaceID[workspaceID] = WorkspaceAgentModelsSettings(
                inheritanceMode: .useWorkspaceOverrides,
                profile: normalized
            )
            recordAgentModelsProfileWriteDiagnostic(
                scope: .workspace,
                workspaceID: workspaceID,
                oldProfile: oldProfile,
                newProfile: normalized,
                attemptedProfile: profile
            )
            save()
            postAgentModelsSettingsDidChange(scope: .workspace(workspaceID))
        }
    }

    // MARK: - Scalar Preferences

    package func appearanceModeRaw() -> String {
        scalarPreferences.ui?.appearanceMode ?? Self.defaultAppearanceModeRaw
    }

    package func setAppearanceModeRaw(_ raw: String, commit: Bool = true) {
        updateUIScalar(commit: commit) { settings in
            settings.appearanceMode = raw
        }
    }

    package func useTransparency() -> Bool {
        scalarPreferences.ui?.useTransparency ?? true
    }

    package func setUseTransparency(_ enabled: Bool, commit: Bool = true) {
        updateUIScalar(commit: commit) { settings in
            settings.useTransparency = enabled
        }
    }

    package func collapseLatestFileChanges() -> Bool {
        scalarPreferences.ui?.collapseLatestFileChanges ?? false
    }

    package func setCollapseLatestFileChanges(_ enabled: Bool, commit: Bool = true) {
        updateUIScalar(commit: commit) { settings in
            settings.collapseLatestFileChanges = enabled
        }
    }

    package func showTooltips() -> Bool {
        scalarPreferences.ui?.showTooltips ?? true
    }

    package func setShowTooltips(_ enabled: Bool, commit: Bool = true) {
        updateUIScalar(commit: commit) { settings in
            settings.showTooltips = enabled
        }
    }

    package func showDatesInMessageTimestamps() -> Bool {
        scalarPreferences.ui?.showDatesInMessageTimestamps ?? false
    }

    package func setShowDatesInMessageTimestamps(_ enabled: Bool, commit: Bool = true) {
        updateUIScalar(commit: commit) { settings in
            settings.showDatesInMessageTimestamps = enabled
        }
    }

    package func experimentalAttributedTextEditor() -> Bool {
        scalarPreferences.ui?.experimentalAttributedTextEditor ?? false
    }

    package func setExperimentalAttributedTextEditor(_ enabled: Bool, commit: Bool = true) {
        updateUIScalar(commit: commit) { settings in
            settings.experimentalAttributedTextEditor = enabled
        }
    }

    package func enableKeyboardShortcuts() -> Bool {
        scalarPreferences.ui?.enableKeyboardShortcuts ?? true
    }

    package func setEnableKeyboardShortcuts(_ enabled: Bool, commit: Bool = true) {
        updateUIScalar(commit: commit) { settings in
            settings.enableKeyboardShortcuts = enabled
        }
    }

    // MARK: - History

    package func contextBuilderBehaviorSettings() -> ContextBuilderBehaviorSettings {
        let settings = scalarPreferences.contextBuilder
        return ContextBuilderBehaviorSettings(
            contextTokenBudget: settings?.contextTokenBudget ?? ContextBuilderDefaults.contextTokenBudget,
            analysisTokenBudget: ContextBuilderDefaults.normalizedAnalysisTokenBudget(
                settings?.analysisTokenBudget ?? ContextBuilderDefaults.analysisTokenBudget
            ),
            enhancementMode: settings?.enhancementMode.flatMap(PromptEnhancementMode.init(rawValue:))
                ?? ContextBuilderDefaults.enhancementMode,
            questionTimeoutSeconds: settings?.questionTimeoutSeconds ?? ContextBuilderDefaults.questionTimeoutSeconds,
            allowUIClarifyingQuestions: settings?.allowUIClarifyingQuestions
                ?? ContextBuilderDefaults.allowUIClarifyingQuestions,
            allowMCPClarifyingQuestions: settings?.allowMCPClarifyingQuestions
                ?? ContextBuilderDefaults.allowMCPClarifyingQuestions,
            followUpAnalysisEnabled: settings?.followUpAnalysisEnabled
                ?? ContextBuilderDefaults.followUpAnalysisEnabled
        )
    }

    package func setContextBuilderBehaviorSettings(
        _ settings: ContextBuilderBehaviorSettings,
        commit: Bool = true
    ) {
        let persisted = GlobalScalarPreferences.ContextBuilderSettings(
            contextTokenBudget: settings.contextTokenBudget,
            analysisTokenBudget: ContextBuilderDefaults.normalizedAnalysisTokenBudget(settings.analysisTokenBudget),
            enhancementMode: settings.enhancementMode.rawValue,
            questionTimeoutSeconds: settings.questionTimeoutSeconds,
            allowUIClarifyingQuestions: settings.allowUIClarifyingQuestions,
            allowMCPClarifyingQuestions: settings.allowMCPClarifyingQuestions,
            followUpAnalysisEnabled: settings.followUpAnalysisEnabled
        )
        guard scalarPreferences.contextBuilder != persisted else { return }
        updateScalarPreferences(commit: commit) { preferences in
            preferences.contextBuilder = persisted
        }
    }

    package func promptSectionsOrderRaw() -> String {
        scalarPreferences.promptPackaging?.promptSectionsOrder ?? ""
    }

    package func setPromptSectionsOrderRaw(_ raw: String, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.promptSectionsOrder = raw
        }
    }

    package func duplicateUserInstructionsAtTop() -> Bool {
        scalarPreferences.promptPackaging?.duplicateUserInstructionsAtTop ?? false
    }

    package func setDuplicateUserInstructionsAtTop(_ enabled: Bool, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.duplicateUserInstructionsAtTop = enabled
        }
    }

    package func filePathDisplayOptionRaw() -> String {
        scalarPreferences.promptPackaging?.filePathDisplayOption ?? Self.defaultFilePathDisplayOptionRaw
    }

    package func setFilePathDisplayOptionRaw(_ raw: String, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.filePathDisplayOption = raw
        }
    }

    package func selectedFilesSortMethodRaw() -> String {
        scalarPreferences.promptPackaging?.selectedFilesSortMethod ?? Self.defaultSelectedFilesSortMethodRaw
    }

    package func setSelectedFilesSortMethodRaw(_ raw: String, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.selectedFilesSortMethod = raw
        }
    }

    package func fileEditFormatRaw() -> String {
        scalarPreferences.promptPackaging?.fileEditFormat ?? Self.defaultFileEditFormatRaw
    }

    package func setFileEditFormatRaw(_ raw: String, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.fileEditFormat = raw
        }
    }

    package func includeDatetimeInUserInstructions() -> Bool {
        scalarPreferences.promptPackaging?.includeDatetimeInUserInstructions ?? false
    }

    package func setIncludeDatetimeInUserInstructions(_ enabled: Bool, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.includeDatetimeInUserInstructions = enabled
        }
    }

    package func customPlanningPrompt() -> String {
        scalarPreferences.promptPackaging?.customPlanningPrompt ?? ""
    }

    package func setCustomPlanningPrompt(_ prompt: String, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.customPlanningPrompt = prompt
        }
    }

    package func modelTemperature() -> Double {
        scalarPreferences.promptPackaging?.modelTemperature ?? 0.0
    }

    package func setModelTemperature(_ temperature: Double, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.modelTemperature = temperature
        }
    }

    package func shouldSetModelTemperature() -> Bool {
        scalarPreferences.promptPackaging?.setModelTemperature ?? true
    }

    package func setShouldSetModelTemperature(_ enabled: Bool, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.setModelTemperature = enabled
        }
    }

    package func complexEditStrategyRaw() -> String {
        scalarPreferences.promptPackaging?.complexEditStrategy ?? Self.defaultComplexEditStrategyRaw
    }

    package func setComplexEditStrategyRaw(_ raw: String, commit: Bool = true) {
        updatePromptPackagingScalar(commit: commit) { settings in
            settings.complexEditStrategy = raw
        }
    }

    package func preferredComposeModelRaw() -> String? {
        scalarPreferences.modelSelection?.preferredComposeModel
    }

    package func setPreferredComposeModelRaw(
        _ raw: String?,
        commit: Bool = true,
        reason: String? = nil,
        honorSync: Bool = false,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        let oldAgentModelsProfile = globalAgentModelsProfile()
        let oldPreferred = scalarPreferences.modelSelection?.preferredComposeModel
        let oldPlanning = scalarPreferences.modelSelection?.planningModel
        let wasSynchronized = resolvedSyncChatModelWithOracleFromCurrentPreferences()
        let hasModel = Self.trimmedNonEmptyModelRaw(raw) != nil
        let shouldMirror = honorSync && wasSynchronized && hasModel
        updateModelSelectionScalar(commit: commit) { settings in
            settings.preferredComposeModel = raw
            if shouldMirror {
                settings.planningModel = raw
            }
            if settings.syncChatModelWithOracle == true,
               !Self.isValidSynchronizedModelTuple(
                   planning: settings.planningModel,
                   compose: settings.preferredComposeModel
               )
            {
                settings.syncChatModelWithOracle = false
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
        if shouldMirror, oldPlanning != raw {
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
        if globalAgentModelsProfile() != oldAgentModelsProfile {
            postAgentModelsSettingsDidChange(scope: .global)
        }
    }

    package func planningModelRaw() -> String? {
        scalarPreferences.modelSelection?.planningModel
    }

    package func setPlanningModelRaw(
        _ raw: String?,
        commit: Bool = true,
        reason: String? = nil,
        honorSync: Bool = false,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        let oldAgentModelsProfile = globalAgentModelsProfile()
        let oldPlanning = scalarPreferences.modelSelection?.planningModel
        let oldPreferred = scalarPreferences.modelSelection?.preferredComposeModel
        let wasSynchronized = resolvedSyncChatModelWithOracleFromCurrentPreferences()
        let hasModel = Self.trimmedNonEmptyModelRaw(raw) != nil
        let shouldMirror = honorSync && wasSynchronized && hasModel
        updateModelSelectionScalar(commit: commit) { settings in
            settings.planningModel = raw
            if shouldMirror {
                settings.preferredComposeModel = raw
            }
            if settings.syncChatModelWithOracle == true,
               !Self.isValidSynchronizedModelTuple(
                   planning: settings.planningModel,
                   compose: settings.preferredComposeModel
               )
            {
                settings.syncChatModelWithOracle = false
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
        if globalAgentModelsProfile() != oldAgentModelsProfile {
            postAgentModelsSettingsDidChange(scope: .global)
        }
    }

    package func additionalOracleModelRaws() -> [String] {
        scalarPreferences.modelSelection?.additionalOracleModels ?? []
    }

    package func setAdditionalOracleModelRaws(_ raws: [String], commit: Bool = true) throws {
        let normalized = try OracleRosterContract.normalizedAdditionalModelIDs(raws)
        guard normalized != additionalOracleModelRaws() else { return }
        updateModelSelectionScalar(commit: commit) { settings in
            settings.additionalOracleModels = normalized.isEmpty ? nil : normalized
        }
        postAgentModelsSettingsDidChange(scope: .global)
    }

    package func syncChatModelWithOracle() -> Bool {
        resolvedSyncChatModelWithOracleFromCurrentPreferences()
    }

    package func setSyncChatModelWithOracle(
        _ enabled: Bool,
        commit: Bool = true,
        reason: String? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        let oldAgentModelsProfile = globalAgentModelsProfile()
        let oldStoredValue = scalarPreferences.modelSelection?.syncChatModelWithOracle.map(String.init)
        let oldPreferred = scalarPreferences.modelSelection?.preferredComposeModel
        let planning = scalarPreferences.modelSelection?.planningModel
        let canEnable = enabled && Self.trimmedNonEmptyModelRaw(planning) != nil
        let shouldSnap = canEnable && planning != oldPreferred
        updateModelSelectionScalar(commit: commit) { settings in
            settings.syncChatModelWithOracle = canEnable
            if shouldSnap {
                settings.preferredComposeModel = planning
            }
        }
        recordSettingsWriteDiagnostic(
            key: "syncChatModelWithOracle",
            oldValue: oldStoredValue,
            newValue: String(canEnable),
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
        if globalAgentModelsProfile() != oldAgentModelsProfile {
            postAgentModelsSettingsDidChange(scope: .global)
        }
    }

    package func mcpAutoStart() -> Bool {
        scalarPreferences.mcp?.autoStart ?? false
    }

    package func setMCPAutoStart(_ enabled: Bool, commit: Bool = true) {
        updateMCPScalar(commit: commit) { settings in
            settings.autoStart = enabled
        }
    }

    package func mcpShowModelPresets() -> Bool {
        scalarPreferences.mcp?.showModelPresets ?? false
    }

    package func setMCPShowModelPresets(_ enabled: Bool, commit: Bool = true) {
        updateMCPScalar(commit: commit) { settings in
            settings.showModelPresets = enabled
        }
    }

    package func mcpTemporarilyDisablePresets() -> Bool {
        scalarPreferences.mcp?.temporarilyDisablePresets ?? false
    }

    package func setMCPTemporarilyDisablePresets(_ enabled: Bool, commit: Bool = true) {
        updateMCPScalar(commit: commit) { settings in
            settings.temporarilyDisablePresets = enabled
        }
    }

    package func respectRepoIgnore() -> Bool {
        scalarPreferences.fileSystem?.respectRepoIgnore ?? true
    }

    package func setRespectRepoIgnore(_ enabled: Bool, commit: Bool = true) {
        updateFileSystemScalar(commit: commit) { settings in
            settings.respectRepoIgnore = enabled
        }
    }

    package func respectCursorignore() -> Bool {
        scalarPreferences.fileSystem?.respectCursorignore ?? true
    }

    package func setRespectCursorignore(_ enabled: Bool, commit: Bool = true) {
        updateFileSystemScalar(commit: commit) { settings in
            settings.respectCursorignore = enabled
        }
    }

    package func globalIgnoreDefaults() -> String {
        if let stored = scalarPreferences.fileSystem?.globalIgnoreDefaults {
            return stored
        }
        return IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults
    }

    package func setGlobalIgnoreDefaults(_ content: String, commit: Bool = true) {
        updateFileSystemScalar(commit: commit) { settings in
            settings.globalIgnoreDefaults = content
        }
    }

    package func enableHierarchicalIgnores() -> Bool {
        scalarPreferences.fileSystem?.enableHierarchicalIgnores ?? true
    }

    package func setEnableHierarchicalIgnores(_ enabled: Bool, commit: Bool = true) {
        updateFileSystemScalar(commit: commit) { settings in
            settings.enableHierarchicalIgnores = enabled
        }
    }

    package func skipSymlinks() -> Bool {
        scalarPreferences.fileSystem?.skipSymlinks ?? true
    }

    package func setSkipSymlinks(_ enabled: Bool, commit: Bool = true) {
        updateFileSystemScalar(commit: commit) { settings in
            settings.skipSymlinks = enabled
        }
    }

    package func showEmptyFolders() -> Bool {
        scalarPreferences.fileSystem?.showEmptyFolders ?? false
    }

    package func fileSystemSettingsSnapshot() -> FileSystemSettingsSnapshot {
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

    package func setShowEmptyFolders(_ enabled: Bool, commit: Bool = true) {
        updateFileSystemScalar(commit: commit) { settings in
            settings.showEmptyFolders = enabled
        }
    }

    package func showBuiltInWorkflowCleanupGuidance() -> Bool {
        scalarPreferences.agentMode?.showBuiltInWorkflowCleanupGuidance ?? true
    }

    package func setShowBuiltInWorkflowCleanupGuidance(_ enabled: Bool, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { settings in
            settings.showBuiltInWorkflowCleanupGuidance = enabled
        }
    }

    /// Independent of Model Router. Missing settings retain the manual-effort path.
    package func autoEffortEnabled() -> Bool {
        scalarPreferences.agentMode?.autoEffortEnabled == true
    }

    package func setAutoEffortEnabled(_ enabled: Bool, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { settings in
            // Clearing returns to the baseline scalar shape for older CE builds.
            settings.autoEffortEnabled = enabled ? true : nil
        }
    }

    package func setCodexMemoriesEnabled(_ enabled: Bool, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { settings in
            settings.codexMemoriesEnabled = enabled
        }
    }

    package func setCodexAppsEnabled(_ enabled: Bool, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { settings in
            settings.codexAppsEnabled = enabled
        }
    }

    package func setCodexPluginsEnabled(_ enabled: Bool, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { settings in
            settings.codexPluginsEnabled = enabled
        }
    }

    package func setCodexMCPElicitationEnabled(_ enabled: Bool, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { settings in
            settings.codexMCPElicitationEnabled = enabled
        }
    }

    package func setCodexToolSuggestionsEnabled(_ enabled: Bool, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { settings in
            settings.codexToolSuggestionsEnabled = enabled
        }
    }

    package func codexUsageQuotaEnabled() -> Bool {
        scalarPreferences.agentMode?.codexUsageQuotaEnabled ?? false
    }

    package func setCodexUsageQuotaEnabled(_ enabled: Bool, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { $0.codexUsageQuotaEnabled = enabled }
    }

    package func claudeUsageQuotaEnabled() -> Bool {
        scalarPreferences.agentMode?.claudeUsageQuotaEnabled ?? false
    }

    package func setClaudeUsageQuotaEnabled(_ enabled: Bool, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { $0.claudeUsageQuotaEnabled = enabled }
    }

    /// Master presentation switch. An explicit choice wins; otherwise users who opted into
    /// either legacy per-provider surface keep seeing usage. This is a pure read: it neither
    /// persists the derived value nor authorizes any acquisition source.
    package func usageLimitsDisplayEnabled() -> Bool {
        Self.resolvedUsageLimitsDisplayEnabled(scalarPreferences.agentMode)
    }

    package nonisolated static func resolvedUsageLimitsDisplayEnabled(
        _ settings: GlobalScalarPreferences.AgentModeSettings?
    ) -> Bool {
        if let explicit = settings?.usageLimitsDisplayEnabled { return explicit }
        return settings?.codexUsageQuotaEnabled == true || settings?.claudeUsageQuotaEnabled == true
    }

    package func setUsageLimitsDisplayEnabled(_ enabled: Bool, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { $0.usageLimitsDisplayEnabled = enabled }
    }

    /// UI-only consent record. Deliberately has no MCP writer.
    package func claudeCLIUsageGrant() -> ClaudeCLIUsageGrant? {
        scalarPreferences.agentMode?.claudeCLIUsageGrant
    }

    package func setClaudeCLIUsageGrant(_ grant: ClaudeCLIUsageGrant?, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { $0.claudeCLIUsageGrant = grant }
    }

    /// The Claude usage display the user already set up: usage display on, and a ready CLI
    /// usage grant for this credential profile. This is the consent that lets passive run
    /// telemetry refresh the *displayed* Claude usage.
    package func claudeUsageDisplayConsented(profileID: String) -> Bool {
        guard usageLimitsDisplayEnabled(), let grant = claudeCLIUsageGrant() else { return false }
        return grant.isReady && grant.applies(toProfileID: profileID)
    }

    /// Whether first-party Claude runs record their own SDK `rate_limit_event` stream output.
    ///
    /// Either the diagnostics toggle (`claudeUsageQuotaEnabled`, unchanged meaning) or the
    /// connected Claude usage display is sufficient. The events are part of the run's own
    /// output: recording them starts no read, process, or request and touches no credential,
    /// so the display connection the user already granted covers showing them. They remain
    /// display-only; routing and balancing never consume SDK telemetry.
    package func claudeRunTelemetryRecordingEnabled(profileID: String) -> Bool {
        claudeUsageQuotaEnabled() || claudeUsageDisplayConsented(profileID: profileID)
    }

    /// UI-only, separately disclosed background acquisition consent. Not routing policy.
    package func setClaudeBalancingRefreshGrant(_ grant: ClaudeCLIUsageGrant?, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { $0.claudeBalancingRefreshGrant = grant }
    }

    package func claudeAccountUsageGrant() -> ClaudeAccountUsageGrant? {
        scalarPreferences.agentMode?.claudeAccountUsageGrant
    }

    package func setClaudeAccountUsageGrant(_ grant: ClaudeAccountUsageGrant?, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { $0.claudeAccountUsageGrant = grant }
    }

    package func globalCodexHookApprovalStrictModeEnabled() -> Bool {
        scalarPreferences.agentMode?.codexHookApprovalStrictModeEnabled ?? false
    }

    package func codexHookApprovalStrictModeWorkspaceOverride(workspaceID: UUID) -> Bool? {
        scalarPreferences.agentMode?.codexHookApprovalStrictModeWorkspaceOverrides?[workspaceID.uuidString]
    }

    package func codexHookApprovalStrictModeEnabled(workspaceID: UUID?) -> Bool {
        if let workspaceID,
           let workspaceOverride = codexHookApprovalStrictModeWorkspaceOverride(workspaceID: workspaceID)
        {
            return workspaceOverride
        }
        return globalCodexHookApprovalStrictModeEnabled()
    }

    package func setGlobalCodexHookApprovalStrictModeEnabled(_ enabled: Bool, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { settings in
            settings.codexHookApprovalStrictModeEnabled = enabled
        }
    }

    package func setCodexHookApprovalStrictModeEnabled(
        _ enabled: Bool,
        workspaceID: UUID?,
        commit: Bool = true
    ) {
        if let workspaceID,
           codexHookApprovalStrictModeWorkspaceOverride(workspaceID: workspaceID) != nil
        {
            setCodexHookApprovalStrictModeOverride(enabled, for: workspaceID, commit: commit)
        } else {
            setGlobalCodexHookApprovalStrictModeEnabled(enabled, commit: commit)
        }
    }

    package func setCodexHookApprovalStrictModeOverride(
        _ override: Bool?,
        for workspaceID: UUID,
        commit: Bool = true
    ) {
        updateAgentModeScalar(commit: commit) { settings in
            var overrides = settings.codexHookApprovalStrictModeWorkspaceOverrides ?? [:]
            overrides[workspaceID.uuidString] = override
            settings.codexHookApprovalStrictModeWorkspaceOverrides = overrides.isEmpty ? nil : overrides
        }
    }

    package func subagentDefaultWaitSeconds() -> Int {
        MCPTimeoutPolicy.resolvedSubagentDefaultWaitSeconds(
            scalarPreferences.agentMode?.subagentDefaultWaitSeconds
        )
    }

    @discardableResult
    package func setSubagentDefaultWaitSeconds(_ seconds: Int, commit: Bool = true) -> Bool {
        guard MCPTimeoutPolicy.isSupportedSubagentDefaultWaitSeconds(seconds) else {
            return false
        }

        let proposedValue = seconds == Int(MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds) ? nil : seconds
        guard scalarPreferences.agentMode?.subagentDefaultWaitSeconds != proposedValue else {
            return true
        }

        updateAgentModeScalar(commit: commit) { settings in
            settings.subagentDefaultWaitSeconds = proposedValue
        }
        return true
    }

    package func agentSessionHandoffInstructions() -> String {
        scalarPreferences.agentMode?.agentSessionHandoffInstructions ?? ""
    }

    // MARK: - Model Router

    package func setModelRouterEnabled(_ enabled: Bool, commit: Bool = true) {
        updateModelRouterScalar(commit: commit) { $0.enabled = enabled }
    }

    @discardableResult
    package func setModelRouterCustomInstructions(_ instructions: String, commit: Bool = true) -> Bool {
        let normalized = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= 1000, normalized.utf8.count <= 4096 else { return false }
        updateModelRouterScalar(commit: commit) { settings in
            settings.customInstructions = normalized.isEmpty ? nil : normalized
        }
        return true
    }

    #if DEBUG
        package func claudeRawEventLoggingEnabled() -> Bool {
            defaults.bool(forKey: "claudeRawEventLoggingEnabled")
        }

        package func setClaudeRawEventLoggingEnabled(_ enabled: Bool) {
            defaults.set(enabled, forKey: "claudeRawEventLoggingEnabled")
        }

        package func claudeRawEventLogFilePath() -> String {
            defaults.string(forKey: "claudeRawEventLogFilePath") ?? ""
        }

        package func setClaudeRawEventLogFilePath(_ path: String) {
            if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                defaults.removeObject(forKey: "claudeRawEventLogFilePath")
            } else {
                defaults.set(path, forKey: "claudeRawEventLogFilePath")
            }
        }

        package func agentModePerfDiagnosticsEnabled() -> Bool {
            defaults.bool(forKey: "enableAgentModePerfDiagnostics")
        }

        package func setAgentModePerfDiagnosticsEnabled(_ enabled: Bool) {
            defaults.set(enabled, forKey: "enableAgentModePerfDiagnostics")
        }

        package func agentModePerfDiagnosticsOSLogEnabled() -> Bool {
            defaults.bool(forKey: "emitAgentModePerfDiagnosticsToOSLog")
        }

        package func setAgentModePerfDiagnosticsOSLogEnabled(_ enabled: Bool) {
            defaults.set(enabled, forKey: "emitAgentModePerfDiagnosticsToOSLog")
        }

    #endif

    package func restrictMCPAgentDiscoveryToRoleLabels() -> Bool {
        scalarPreferences.agentMode?.restrictMCPAgentDiscoveryToRoleLabels ?? false
    }

    package func setRestrictMCPAgentDiscoveryToRoleLabels(_ enabled: Bool, commit: Bool = true) {
        let oldValue = restrictMCPAgentDiscoveryToRoleLabels()
        updateAgentModeScalar(commit: commit) { settings in
            settings.restrictMCPAgentDiscoveryToRoleLabels = enabled
        }
        if oldValue != enabled {
            postAgentModelsSettingsDidChange(scope: .global)
        }
    }

    package func modelDiffOverrides() -> [String: Bool] {
        scalarPreferences.modelOverrides?.diffOverrides ?? [:]
    }

    package func setModelDiffOverrides(_ overrides: [String: Bool], commit: Bool = true) {
        updateModelOverridesScalar(commit: commit) { settings in
            settings.diffOverrides = overrides
        }
    }

    package func modelStreamOverrides() -> [String: Bool] {
        scalarPreferences.modelOverrides?.streamOverrides ?? [:]
    }

    package func setModelStreamOverrides(_ overrides: [String: Bool], commit: Bool = true) {
        updateModelOverridesScalar(commit: commit) { settings in
            settings.streamOverrides = overrides
        }
    }

    package func modelTemperatureOverrides() -> [String: Double] {
        scalarPreferences.modelOverrides?.temperatureOverrides ?? [:]
    }

    package func setModelTemperatureOverrides(_ overrides: [String: Double], commit: Bool = true) {
        updateModelOverridesScalar(commit: commit) { settings in
            settings.temperatureOverrides = overrides
        }
    }

    package func telemetryEnabled() -> Bool {
        if let mirrored = defaults.object(forKey: Self.telemetryEnabledDefaultsKey) as? Bool {
            return mirrored
        }
        return scalarPreferences.telemetry?.enabled ?? Self.defaultTelemetryEnabled
    }

    package func telemetryAppHangReportsEnabled() -> Bool {
        scalarPreferences.telemetry?.appHangReportsEnabled ?? false
    }

    package func telemetryPerformanceTracingEnabled() -> Bool {
        scalarPreferences.telemetry?.performanceTracingEnabled ?? false
    }

    package func modelResponsesOverrides() -> [String: Bool] {
        scalarPreferences.modelOverrides?.responsesOverrides ?? [:]
    }

    package func setModelResponsesOverrides(_ overrides: [String: Bool], commit: Bool = true) {
        updateModelOverridesScalar(commit: commit) { settings in
            settings.responsesOverrides = overrides
        }
    }

    package func updateModelOverrides(
        _ mutation: (inout GlobalScalarPreferences.ModelOverrideSettingsData) -> Void,
        commit: Bool = true
    ) {
        updateModelOverridesScalar(commit: commit, mutation)
    }

    // MARK: - Notifications

    package func updateNotificationSettings(
        commit: Bool = true,
        _ mutation: (inout GlobalScalarPreferences.NotificationSettings) -> Void
    ) {
        let before = scalarPreferences.notifications
        updateScalarPreferences(commit: commit) { preferences in
            var settings = preferences.notifications ?? GlobalScalarPreferences.NotificationSettings()
            mutation(&settings)
            preferences.notifications = settings
        }
        if before != scalarPreferences.notifications {
            emit(.notificationPreferencesChanged)
        }
    }

    package func updateUIScalar(
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

    package func updateAgentModeScalar(
        commit: Bool,
        _ mutation: (inout GlobalScalarPreferences.AgentModeSettings) -> Void
    ) {
        updateScalarPreferences(commit: commit) { preferences in
            var settings = preferences.agentMode ?? GlobalScalarPreferences.AgentModeSettings()
            mutation(&settings)
            preferences.agentMode = settings
        }
    }

    package func updateModelRouterScalar(
        commit: Bool,
        _ mutation: (inout GlobalScalarPreferences.ModelRouterSettings) -> Void
    ) {
        let before = scalarPreferences.modelRouter
        updateScalarPreferences(commit: false) { preferences in
            var settings = preferences.modelRouter ?? GlobalScalarPreferences.ModelRouterSettings()
            mutation(&settings)
            preferences.modelRouter = settings
        }
        if before != scalarPreferences.modelRouter {
            modelRouterSettingsRevision &+= 1
        }
        if commit {
            save()
        }
    }

    package func updateTelemetryScalar(
        commit: Bool,
        _ mutation: (inout GlobalScalarPreferences.TelemetrySettings) -> Void
    ) {
        updateScalarPreferences(commit: commit) { preferences in
            var settings = preferences.telemetry ?? GlobalScalarPreferences.TelemetrySettings()
            mutation(&settings)
            preferences.telemetry = settings
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

    package func updateScalarPreferences(commit: Bool, _ mutation: (inout GlobalScalarPreferences) -> Void) {
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

    package enum WorktreeVisualIdentityError: Error, Equatable {
        case invalidColorHex(String)
        case emptyRepositoryID
        case emptyWorktreeID
    }

    package func worktreeVisualIdentitiesByRepositoryID() -> [String: WorktreeVisualIdentityRepositoryBucket] {
        globalDefaults.worktreeVisualIdentitiesByRepositoryID ?? [:]
    }

    package func worktreeVisualIdentity(repositoryID: String, worktreeID: String) -> WorktreeVisualIdentity? {
        let repositoryID = normalizedWorktreeIdentityKey(repositoryID)
        let worktreeID = normalizedWorktreeIdentityKey(worktreeID)
        guard !repositoryID.isEmpty, !worktreeID.isEmpty else { return nil }
        return globalDefaults.worktreeVisualIdentitiesByRepositoryID?[repositoryID]?.identitiesByWorktreeID[worktreeID]
    }

    package func fallbackWorktreeVisualIdentity(
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

    package func resolvedWorktreeVisualIdentity(
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
    package func ensureWorktreeVisualIdentity(
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

    package func setWorktreeVisualIdentity(
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
        let previousLabel = normalizedWorktreeVisualLabel(bucket.identitiesByWorktreeID[worktreeID]?.label)
        bucket.identitiesByWorktreeID[worktreeID] = identity
        repositories[repositoryID] = bucket
        globalDefaults.worktreeVisualIdentitiesByRepositoryID = repositories
        objectWillChange.send()
        if commit {
            save()
        }
        // Label only. Color, icon, marker style, and `updatedAt` cannot change any oversight row's
        // location text, so they must not schedule a repaint. Fired from the live assignment rather
        // than from `save()`: presentation follows memory, and a revert emits its own refresh.
        if previousLabel != normalizedWorktreeVisualLabel(identity.label) {
            emit(.worktreeLocationLabelsChanged)
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

    package static func isValidWorktreeColorHex(_ value: String) -> Bool {
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

    package func globalCodeMapsDisabled() -> Bool {
        codeMapsGloballyDisabled
    }

    package func setCodeMapsGloballyDisabled(_ disabled: Bool, commit: Bool = true) {
        guard codeMapsGloballyDisabled != disabled || (globalDefaults.codeMapsGloballyDisabled ?? false) != disabled else {
            return
        }
        globalDefaults.codeMapsGloballyDisabled = disabled
        codeMapsGloballyDisabled = disabled
        if commit {
            save()
        }
    }

    package func setNonGitCodeMapsEnabled(_ enabled: Bool, commit: Bool = true) {
        guard nonGitCodeMapsEnabled != enabled || (globalDefaults.nonGitCodeMapsEnabled ?? false) != enabled else {
            return
        }
        globalDefaults.nonGitCodeMapsEnabled = enabled
        nonGitCodeMapsEnabled = enabled
        if commit {
            save()
        }
    }

    /// Publishes `objectWillChange` when `globalDefaults` changed and persists if `commit`.
    /// Centralizes the publish-on-mutate contract for the global-defaults surface (Context
    /// Builder agent, MCP role overrides, recommendation provider filter) so any change
    /// propagates to every observing window; route all `globalDefaults` mutations through here.
    package func persistGlobalDefaultsChange(before: GlobalDefaults, commit: Bool) {
        // Direct `globalDefaults` writers (the legacy Context Builder selection setters, reached
        // from `app_settings` and window settings) bypass profile normalization. Normalization
        // only *masks* a pin whose model no longer matches, so the stale bucket would survive in
        // backing state and resurrect if the user later switched back to that model. Re-derive
        // the buckets through the profile, which is the single owner of the coherence rule —
        // rather than restating that rule here.
        let coherent = globalAgentModelsProfile()
        globalDefaults.mcpAgentRoleModelParameters = coherent.mcpAgentRoleModelParameters
        globalDefaults.contextBuilderModelParametersByAgent = coherent.contextBuilderModelParametersByAgent
        if before != globalDefaults {
            objectWillChange.send()
        }
        if commit {
            save()
        }
    }

    // MARK: - Global Context Builder Agent Selection (Single Source of Truth)

    /// Returns the raw persisted global Context Builder selection without synthesizing a fallback.
    /// Startup restoration needs to distinguish a real saved value from the catalog's historical
    /// Claude Code / Opus default so it can validate availability and use recommendations instead.
    package func persistedGlobalContextBuilderAgentSelection() -> (agentRaw: String?, modelRaw: String?) {
        guard let agentRaw = globalDefaults.discoverAgentRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !agentRaw.isEmpty
        else {
            return (nil, nil)
        }
        let modelRaw = globalDefaults.discoverModelsByAgent?[agentRaw]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (agentRaw, modelRaw?.isEmpty == false ? modelRaw : nil)
    }

    /// Returns whether the user has explicitly set the global Context Builder agent defaults.
    /// Used by recommendation engine to determine if auto-apply should be allowed.
    /// NOTE: For existing installs, `didUserSetDiscoverAgentDefaults` will be nil but
    /// they may already have a configured selection. We treat nil + existing selection
    /// as "user-defined" to avoid overwriting their settings via auto-apply.
    package var hasUserSetGlobalContextBuilderAgentDefaults: Bool {
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

    // MARK: - Global MCP Agent Role Defaults (Single Source of Truth)

    /// Returns global MCP Agent Mode role-default overrides.
    /// nil means all roles use the recommended defaults.
    package func globalMCPAgentRoleOverrides() -> [String: String]? {
        normalizedRoleOverrides(globalDefaults.mcpAgentRoleOverrides)
    }

    /// Updates global MCP Agent Mode role-default overrides.
    /// Empty dictionaries are normalized to nil.
    // MARK: - Recommendation Provider Filter (Global)

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
    package func ensureLatestRecommendationSchema(currentVersion: Int) -> Bool {
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

    private func agentModelsProfile(for scope: AgentModelsEditingScope) -> AgentModelsSettingsProfile {
        switch scope {
        case .global:
            globalAgentModelsProfile()
        case let .workspace(workspaceID):
            workspaceAgentModelsProfile(for: workspaceID)
                ?? effectiveAgentModelsProfile(workspaceID: workspaceID)
        }
    }

    private func updateAgentModelsProfile(
        scope: AgentModelsEditingScope,
        contextBuilderWriteIntent: ContextBuilderSettingsWriteIntent = .preserveExistingOwnership,
        _ mutation: (inout AgentModelsSettingsProfile) -> Void
    ) {
        switch scope {
        case .global:
            var profile = globalAgentModelsProfile()
            mutation(&profile)
            setGlobalAgentModelsProfile(profile, contextBuilderWriteIntent: contextBuilderWriteIntent)
        case let .workspace(workspaceID):
            var settings = agentModelsSettingsByWorkspaceID[workspaceID] ?? WorkspaceAgentModelsSettings(
                inheritanceMode: .useWorkspaceOverrides,
                profile: globalAgentModelsProfile()
            )
            settings.inheritanceMode = .useWorkspaceOverrides
            let oldProfile = settings.profile
            var profile = settings.profile ?? globalAgentModelsProfile()
            mutation(&profile)
            let normalized = normalizedAgentModelsProfile(profile)
            settings.profile = normalized
            agentModelsSettingsByWorkspaceID[workspaceID] = settings
            recordAgentModelsProfileWriteDiagnostic(
                scope: .workspace,
                workspaceID: workspaceID,
                oldProfile: oldProfile,
                newProfile: normalized,
                attemptedProfile: profile
            )
            save()
            postAgentModelsSettingsDidChange(scope: .workspace(workspaceID))
        }
    }

    private func normalizedAgentModelsProfile(_ profile: AgentModelsSettingsProfile) -> AgentModelsSettingsProfile {
        var normalized = AgentModelsSettingsProfile(
            planningModelRaw: profile.planningModelRaw,
            additionalOracleModelRaws: profile.additionalOracleModelRaws,
            oracleReconciliationGuidance: profile.oracleReconciliationGuidance,
            preferredComposeModelRaw: profile.preferredComposeModelRaw,
            syncChatModelWithOracle: profile.syncChatModelWithOracle,
            contextBuilderAgentRaw: profile.contextBuilderAgentRaw,
            contextBuilderModelsByAgent: profile.contextBuilderModelsByAgent,
            mcpAgentRoleOverrides: profile.mcpAgentRoleOverrides,
            restrictMCPAgentDiscoveryToRoleLabels: profile.restrictMCPAgentDiscoveryToRoleLabels,
            mcpAgentRoleModelParameters: profile.mcpAgentRoleModelParameters,
            contextBuilderModelParametersByAgent: profile.contextBuilderModelParametersByAgent
        )
        if let invalidReason = invalidSynchronizedProfileReason(normalized) {
            invalidAgentModelsProfileAssertion(
                "Invalid sync-enabled Agent Models profile (\(invalidReason)): planning and compose must be equal and nonblank"
            )
            normalized.syncChatModelWithOracle = false
        }
        return normalized
    }

    private enum ProfileDiagnosticScope: String {
        case global
        case workspace
    }

    private func recordAgentModelsProfileWriteDiagnostic(
        scope: ProfileDiagnosticScope,
        workspaceID: UUID?,
        oldProfile: AgentModelsSettingsProfile?,
        newProfile: AgentModelsSettingsProfile,
        attemptedProfile: AgentModelsSettingsProfile? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) {
        let invalidSyncTuple = attemptedProfile.flatMap { invalidSynchronizedProfileReason($0) }
            ?? invalidSynchronizedProfileReason(newProfile)
        let workspaceSuffix = workspaceID.map { ".\($0.uuidString)" } ?? ""
        recordSettingsWriteDiagnostic(
            key: "agentModelsProfile.\(scope.rawValue)\(workspaceSuffix)",
            oldValue: agentModelsProfileDiagnosticValue(oldProfile),
            newValue: agentModelsProfileDiagnosticValue(newProfile),
            commit: true,
            reason: invalidSyncTuple.map { "agent_models.profile.invalid_sync.\($0)" }
                ?? "agent_models.profile.\(scope.rawValue)",
            fileID: fileID,
            line: line,
            function: function
        )
    }

    private func invalidSynchronizedProfileReason(_ profile: AgentModelsSettingsProfile) -> String? {
        guard profile.syncChatModelWithOracle else { return nil }
        switch (profile.planningModelRaw, profile.preferredComposeModelRaw) {
        case (nil, nil):
            return "both_blank"
        case (nil, _), (_, nil):
            return "one_blank"
        case let (planning?, compose?) where planning != compose:
            return "divergent"
        default:
            return nil
        }
    }

    private func agentModelsProfileDiagnosticValue(_ profile: AgentModelsSettingsProfile?) -> String? {
        guard let profile else { return nil }
        let contextBuilderModelRaw = profile.contextBuilderAgentRaw.flatMap { profile.contextBuilderModelsByAgent?[$0] }
        return [
            "planning=\(profile.planningModelRaw ?? "nil")",
            "additionalOracles=\(profile.additionalOracleModelRaws.joined(separator: ","))",
            "compose=\(profile.preferredComposeModelRaw ?? "nil")",
            "sync=\(profile.syncChatModelWithOracle)",
            "contextBuilder=\(profile.contextBuilderAgentRaw ?? "nil"):\(contextBuilderModelRaw ?? "nil")",
            "roleOverrides=\(profile.mcpAgentRoleOverrides?.count ?? 0)",
            "restrictRoleDiscovery=\(profile.restrictMCPAgentDiscoveryToRoleLabels)"
        ].joined(separator: ";")
    }

    package func postAgentModelsSettingsDidChange(scope: AgentModelsEditingScope) {
        emit(.agentModelsSettingsChanged(scope: scope))
    }

    // MARK: - Persistence

    private func load(notifyAgentModelsChanges: Bool = false) {
        let oldGlobalProfile = globalAgentModelsProfile()
        let oldWorkspaceSettings = agentModelsSettingsByWorkspaceID
        let fileExists = FileManager.default.fileExists(atPath: fileStore.fileURL.path)
        var loadedExistingDocument: GlobalSettingsDocument?
        var shouldSyncTelemetryMirror = false
        if !fileExists {
            defaults.removeObject(forKey: Self.telemetryEnabledDefaultsKey)
        } else {
            do {
                loadedExistingDocument = try fileStore.load()
                shouldSyncTelemetryMirror = true
            } catch GlobalSettingsFileStore.GlobalSettingsFileStoreError.unsupportedFutureSchema,
                GlobalSettingsFileStore.GlobalSettingsFileStoreError.incompatibleSchema
            {
                if defaults.object(forKey: Self.telemetryEnabledDefaultsKey) == nil {
                    defaults.set(false, forKey: Self.telemetryEnabledDefaultsKey)
                }
            } catch {
                defaults.set(false, forKey: Self.telemetryEnabledDefaultsKey)
            }
        }
        let document = loadedExistingDocument ?? fileStore.loadOrCreateDefault()
        let needsSchemaVersionUpgrade = document.requiredSchemaVersion > document.schemaVersion
        copySettings = document.copySettings
        let migratedContextBuilderState = Self.migratingLegacyContextBuilderState(
            chatSettings: document.chatSettings,
            globalDefaults: document.globalDefaults,
            scalarPreferences: document.scalarPreferences ?? GlobalScalarPreferences()
        )
        chatSettings = migratedContextBuilderState.chatSettings
        agentModelsSettingsByWorkspaceID = document.agentModelsSettings
        globalDefaults = migratedContextBuilderState.globalDefaults
        scalarPreferences = migratedContextBuilderState.scalarPreferences
        let seededFileSystemDefaults = Self.seedFileSystemGlobalIgnoreDefaults(in: &scalarPreferences)
        let disabledInvalidSync = disableInvalidLoadedAgentModelsSyncState()
        if shouldSyncTelemetryMirror {
            syncTelemetryMirrorFromLoadedSettings(scalarPreferences)
        }
        codeMapsGloballyDisabled = globalDefaults.codeMapsGloballyDisabled ?? false
        nonGitCodeMapsEnabled = globalDefaults.nonGitCodeMapsEnabled ?? false
        persistenceBlockReason = fileStore.blockReason
        if persistenceBlockReason == nil,
           migratedContextBuilderState.didChange
           || seededFileSystemDefaults
           || disabledInvalidSync
           || needsSchemaVersionUpgrade
        {
            saveStartupMigration(includeModelSelectionRepair: disabledInvalidSync)
        }
        if notifyAgentModelsChanges {
            postInstalledAgentModelsChanges(
                oldGlobalProfile: oldGlobalProfile,
                oldWorkspaceSettings: oldWorkspaceSettings
            )
            emit(.settingsInstalled)
        }
    }

    /// User-initiated recovery when `persistenceBlockReason` is non-nil. The file store backs
    /// up the offending on-disk file, writes the current in-memory settings as a fresh
    /// current-schema document, and clears the block on success. A failed replacement keeps
    /// the current in-memory document and the file store's blocked state intact.
    /// Returns true only when recovery completed successfully.
    @discardableResult
    package func recoverBlockedPersistenceAfterBackup() -> Bool {
        let recovered = fileStore.performUserInitiatedRecovery(replacementDocument: makeDocument())
        objectWillChange.send()
        if recovered {
            load(notifyAgentModelsChanges: true)
        } else {
            // Recovery may have moved the original file before its replacement write failed.
            // Do not reload a missing primary file: that would install and persist defaults.
            // Keep the live document intact and surface the store's actionable blocked state so
            // the user can retry the intended settings after fixing the underlying failure.
            persistenceBlockReason = fileStore.blockReason
        }
        return recovered
    }

    /// User-initiated compatible import from a blocked newer/different-schema settings file.
    /// The file store backs up the original, writes a current-schema document containing only
    /// CE-known fields, then this store reloads those imported settings.
    @discardableResult
    package func importBlockedPersistenceAfterBackup() -> Bool {
        let imported = fileStore.performUserInitiatedCompatibleImport()
        objectWillChange.send()
        if imported {
            load(notifyAgentModelsChanges: true)
        } else {
            persistenceBlockReason = fileStore.blockReason
        }
        return imported
    }

    /// Retries writing the current in-memory settings after a transient save failure, without
    /// backing up or resetting the user's settings. Returns true when persistence is unblocked.
    @discardableResult
    package func retryBlockedPersistenceSave() -> Bool {
        // Reload is an explicit, separate action: never overwrite another writer or
        // persist provisional defaults through the generic save retry.
        guard persistenceBlockReason != .changedOnDisk,
              persistenceBlockReason != .missingOnDisk,
              persistenceBlockReason != .loadFailed
        else {
            return false
        }
        if fileStore.hasPendingStartupMigration {
            return persist {
                try fileStore.retryStartupMigrationPreservingUnknownFields(makeDocument())
            }
        }
        return save()
    }

    @discardableResult
    package func reloadFromDisk() -> Bool {
        do {
            let oldGlobalProfile = globalAgentModelsProfile()
            let oldWorkspaceSettings = agentModelsSettingsByWorkspaceID
            let document = try fileStore.load()
            let needsSchemaVersionUpgrade = document.requiredSchemaVersion > document.schemaVersion
            objectWillChange.send()
            copySettings = document.copySettings
            let migratedContextBuilderState = Self.migratingLegacyContextBuilderState(
                chatSettings: document.chatSettings,
                globalDefaults: document.globalDefaults,
                scalarPreferences: document.scalarPreferences ?? GlobalScalarPreferences()
            )
            chatSettings = migratedContextBuilderState.chatSettings
            agentModelsSettingsByWorkspaceID = document.agentModelsSettings
            globalDefaults = migratedContextBuilderState.globalDefaults
            scalarPreferences = migratedContextBuilderState.scalarPreferences
            let seededFileSystemDefaults = Self.seedFileSystemGlobalIgnoreDefaults(in: &scalarPreferences)
            let disabledInvalidSync = disableInvalidLoadedAgentModelsSyncState()
            syncTelemetryMirrorFromLoadedSettings(scalarPreferences)
            codeMapsGloballyDisabled = globalDefaults.codeMapsGloballyDisabled ?? false
            nonGitCodeMapsEnabled = globalDefaults.nonGitCodeMapsEnabled ?? false
            persistenceBlockReason = fileStore.blockReason
            if persistenceBlockReason == nil,
               migratedContextBuilderState.didChange
               || seededFileSystemDefaults
               || disabledInvalidSync
               || needsSchemaVersionUpgrade
            {
                saveStartupMigration(includeModelSelectionRepair: disabledInvalidSync)
            }
            postInstalledAgentModelsChanges(
                oldGlobalProfile: oldGlobalProfile,
                oldWorkspaceSettings: oldWorkspaceSettings
            )
            emit(.settingsInstalled)
            return true
        } catch {
            persistenceBlockReason = fileStore.blockReason
            print("⚠️ Failed to reload global settings JSON at \(fileStore.fileURL.path): \(error)")
            return false
        }
    }

    /// Disables invalid persisted sync flags without changing either stored model raw.
    /// This runs only after a document has passed the file store's schema/lineage checks;
    /// callers decide whether that compatible load may be repaired on disk.
    @discardableResult
    private func disableInvalidLoadedAgentModelsSyncState() -> Bool {
        var changed = false

        if var modelSelection = scalarPreferences.modelSelection,
           modelSelection.syncChatModelWithOracle == true,
           !Self.isValidSynchronizedModelTuple(
               planning: modelSelection.planningModel,
               compose: modelSelection.preferredComposeModel
           )
        {
            modelSelection.syncChatModelWithOracle = false
            scalarPreferences.modelSelection = modelSelection
            changed = true
        }

        for workspaceID in agentModelsSettingsByWorkspaceID.keys {
            guard var settings = agentModelsSettingsByWorkspaceID[workspaceID],
                  var profile = settings.profile,
                  invalidSynchronizedProfileReason(profile) != nil
            else {
                continue
            }
            profile.syncChatModelWithOracle = false
            settings.profile = profile
            agentModelsSettingsByWorkspaceID[workspaceID] = settings
            changed = true
        }

        return changed
    }

    private func postInstalledAgentModelsChanges(
        oldGlobalProfile: AgentModelsSettingsProfile,
        oldWorkspaceSettings: [UUID: WorkspaceAgentModelsSettings]
    ) {
        if oldGlobalProfile != globalAgentModelsProfile() {
            postAgentModelsSettingsDidChange(scope: .global)
        }
        let workspaceIDs = Set(oldWorkspaceSettings.keys).union(agentModelsSettingsByWorkspaceID.keys)
        for workspaceID in workspaceIDs.sorted(by: { $0.uuidString < $1.uuidString })
            where oldWorkspaceSettings[workspaceID] != agentModelsSettingsByWorkspaceID[workspaceID]
        {
            postAgentModelsSettingsDidChange(scope: .workspace(workspaceID))
        }
    }

    private static func seedFileSystemGlobalIgnoreDefaults(
        in scalarPreferences: inout GlobalScalarPreferences
    ) -> Bool {
        var fileSystemSettings = scalarPreferences.fileSystem ?? GlobalScalarPreferences.FileSystemSettings()
        guard fileSystemSettings.globalIgnoreDefaults == nil else { return false }
        fileSystemSettings.globalIgnoreDefaults = IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults
        scalarPreferences.fileSystem = fileSystemSettings
        return true
    }

    private static func migratingLegacyContextBuilderState(
        chatSettings: [UUID: ChatGlobalSettings],
        globalDefaults: GlobalDefaults,
        scalarPreferences: GlobalScalarPreferences
    ) -> (
        chatSettings: [UUID: ChatGlobalSettings],
        globalDefaults: GlobalDefaults,
        scalarPreferences: GlobalScalarPreferences,
        didChange: Bool
    ) {
        var migratedGlobalDefaults = globalDefaults
        if migratedGlobalDefaults.discoverAgentRaw == nil,
           let legacySelection = legacyContextBuilderSelection(
               chatSettings: chatSettings,
               globalDefaults: globalDefaults
           )
        {
            migratedGlobalDefaults.discoverAgentRaw = legacySelection.agentRaw
            if migratedGlobalDefaults.discoverModelsByAgent?[legacySelection.agentRaw] == nil,
               let modelRaw = legacySelection.modelRaw
            {
                if migratedGlobalDefaults.discoverModelsByAgent == nil {
                    migratedGlobalDefaults.discoverModelsByAgent = [:]
                }
                migratedGlobalDefaults.discoverModelsByAgent?[legacySelection.agentRaw] = modelRaw
            }
            migratedGlobalDefaults.didUserSetDiscoverAgentDefaults = true
        }
        migratedGlobalDefaults.contextBuilderAgentRaw = nil

        var migratedScalarPreferences = scalarPreferences
        if migratedScalarPreferences.contextBuilder == nil {
            let behavior = legacyContextBuilderBehaviorSettings(chatSettings: chatSettings)
            migratedScalarPreferences.contextBuilder = GlobalScalarPreferences.ContextBuilderSettings(
                contextTokenBudget: behavior.contextTokenBudget,
                analysisTokenBudget: ContextBuilderDefaults.normalizedAnalysisTokenBudget(behavior.analysisTokenBudget),
                enhancementMode: behavior.enhancementMode.rawValue,
                questionTimeoutSeconds: behavior.questionTimeoutSeconds,
                allowUIClarifyingQuestions: behavior.allowUIClarifyingQuestions,
                allowMCPClarifyingQuestions: behavior.allowMCPClarifyingQuestions,
                followUpAnalysisEnabled: behavior.followUpAnalysisEnabled
            )
        }
        if let analysisTokenBudget = migratedScalarPreferences.contextBuilder?.analysisTokenBudget {
            migratedScalarPreferences.contextBuilder?.analysisTokenBudget =
                ContextBuilderDefaults.normalizedAnalysisTokenBudget(analysisTokenBudget)
        }

        let migratedChatSettings = removingLegacyWorkspaceContextBuilderState(from: chatSettings)
        return (
            migratedChatSettings,
            migratedGlobalDefaults,
            migratedScalarPreferences,
            migratedChatSettings != chatSettings
                || migratedGlobalDefaults != globalDefaults
                || migratedScalarPreferences != scalarPreferences
        )
    }

    private static func legacyContextBuilderBehaviorSettings(
        chatSettings: [UUID: ChatGlobalSettings]
    ) -> ContextBuilderBehaviorSettings {
        let orderedSettings = chatSettings.sorted { $0.key.uuidString < $1.key.uuidString }
        let enhancementMode = orderedSettings.lazy.compactMap { entry -> PromptEnhancementMode? in
            guard let rawValue = entry.value.discoveryEnhancementMode else { return nil }
            guard let mode = PromptEnhancementMode(rawValue: rawValue) else {
                print(
                    "⚠️ Ignoring invalid legacy Context Builder enhancement mode for workspace "
                        + "\(entry.key.uuidString)"
                )
                return nil
            }
            return mode
        }.first

        return ContextBuilderBehaviorSettings(
            contextTokenBudget: orderedSettings.lazy.compactMap(\.value.discoveryTokenBudget).first
                ?? ContextBuilderDefaults.contextTokenBudget,
            analysisTokenBudget: orderedSettings.lazy.compactMap(\.value.discoveryPlanTokenBudget).first
                ?? ContextBuilderDefaults.analysisTokenBudget,
            enhancementMode: enhancementMode ?? ContextBuilderDefaults.enhancementMode,
            questionTimeoutSeconds: orderedSettings.lazy.compactMap(\.value.discoveryQuestionTimeoutSeconds).first
                ?? ContextBuilderDefaults.questionTimeoutSeconds,
            allowUIClarifyingQuestions: orderedSettings.lazy.compactMap(\.value.discoveryAllowClarifyingQuestions).first
                ?? ContextBuilderDefaults.allowUIClarifyingQuestions,
            allowMCPClarifyingQuestions: orderedSettings.lazy
                .compactMap(\.value.discoveryAllowClarifyingQuestionsForMCP).first
                ?? ContextBuilderDefaults.allowMCPClarifyingQuestions,
            followUpAnalysisEnabled: orderedSettings.lazy.compactMap(\.value.discoveryAutoGeneratePlan).first
                ?? ContextBuilderDefaults.followUpAnalysisEnabled
        )
    }

    private static func legacyContextBuilderSelection(
        chatSettings: [UUID: ChatGlobalSettings],
        globalDefaults: GlobalDefaults
    ) -> (agentRaw: String, modelRaw: String?)? {
        let orderedSettings = chatSettings
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map(\.value)

        if let agentRaw = validLegacyAgentRaw(globalDefaults.contextBuilderAgentRaw) {
            let modelRaw = orderedSettings.lazy
                .compactMap { legacyModelRaw(for: agentRaw, in: $0) }
                .first
            return (agentRaw, modelRaw)
        }

        for settings in orderedSettings {
            if settings.didUserSetContextBuilderDefaults != false,
               let agentRaw = validLegacyAgentRaw(settings.contextBuilderAgentRaw)
            {
                return (agentRaw, legacyModelRaw(for: agentRaw, in: settings))
            }
            if settings.didUserSetDiscoverAgentDefaults != false,
               let agentRaw = validLegacyAgentRaw(settings.lastUsedDiscoverAgentRaw)
            {
                return (agentRaw, legacyModelRaw(for: agentRaw, in: settings))
            }
        }
        return nil
    }

    private static func validLegacyAgentRaw(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return SettingsAgentKind(rawValue: trimmed)?.rawValue
    }

    private static func legacyModelRaw(
        for agentRaw: String,
        in settings: ChatGlobalSettings
    ) -> String? {
        if validLegacyAgentRaw(settings.contextBuilderAgentRaw) == agentRaw,
           let modelRaw = nonEmptyTrimmed(settings.contextBuilderAgentModelRaw)
        {
            return modelRaw
        }
        return nonEmptyTrimmed(settings.lastUsedDiscoverModelsByAgent?[agentRaw])
    }

    private static func nonEmptyTrimmed(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func removingLegacyWorkspaceContextBuilderState(
        from settingsByWorkspaceID: [UUID: ChatGlobalSettings]
    ) -> [UUID: ChatGlobalSettings] {
        settingsByWorkspaceID.mapValues { settings in
            var settings = settings
            settings.lastUsedDiscoverAgentRaw = nil
            settings.lastUsedDiscoverModelsByAgent = nil
            settings.discoveryTokenBudget = nil
            settings.discoveryEnhancementMode = nil
            settings.discoveryAutoGeneratePlan = nil
            settings.discoveryAllowClarifyingQuestions = nil
            settings.discoveryAllowClarifyingQuestionsForMCP = nil
            settings.discoveryQuestionTimeoutSeconds = nil
            settings.discoveryPlanTokenBudget = nil
            settings.contextBuilderAgentRaw = nil
            settings.contextBuilderAgentModelRaw = nil
            settings.didUserSetDiscoverAgentDefaults = nil
            settings.didUserSetContextBuilderDefaults = nil
            settings.didAutoApplyRecommendationsAt = nil
            return settings
        }
    }

    private func resolvedSyncChatModelWithOracleFromCurrentPreferences() -> Bool {
        let planning = scalarPreferences.modelSelection?.planningModel
        let compose = scalarPreferences.modelSelection?.preferredComposeModel
        if let stored = scalarPreferences.modelSelection?.syncChatModelWithOracle {
            return stored && Self.isValidSynchronizedModelTuple(planning: planning, compose: compose)
        }
        return Self.isValidSynchronizedModelTuple(planning: planning, compose: compose)
    }

    private static func isValidSynchronizedModelTuple(planning: String?, compose: String?) -> Bool {
        guard let planning = trimmedNonEmptyModelRaw(planning),
              let compose = trimmedNonEmptyModelRaw(compose)
        else {
            return false
        }
        return planning == compose
    }

    private static func trimmedNonEmptyModelRaw(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
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

    private func syncTelemetryMirrorFromLoadedSettings(_ preferences: GlobalScalarPreferences) {
        if let enabled = preferences.telemetry?.enabled {
            defaults.set(enabled, forKey: Self.telemetryEnabledDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.telemetryEnabledDefaultsKey)
        }
    }

    private static var defaultTelemetryEnabled: Bool {
        #if REPOPROMPT_SENTRY_ENABLED
            true
        #else
            false
        #endif
    }

    private func makeDocument() -> GlobalSettingsDocument {
        GlobalSettingsDocument(
            copySettings: copySettings,
            chatSettings: chatSettings,
            agentModelsSettings: agentModelsSettingsByWorkspaceID,
            globalDefaults: globalDefaults,
            scalarPreferences: scalarPreferences
        )
    }

    @discardableResult
    private func saveStartupMigration(includeModelSelectionRepair: Bool) -> Bool {
        persist {
            try fileStore.saveStartupMigrationPreservingUnknownFields(
                makeDocument(),
                includeModelSelectionRepair: includeModelSelectionRepair
            )
        }
    }

    @discardableResult
    private func save() -> Bool {
        persist { try fileStore.save(makeDocument()) }
    }

    private func persist(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            if persistenceBlockReason != fileStore.blockReason {
                persistenceBlockReason = fileStore.blockReason
            }
            return true
        } catch {
            if persistenceBlockReason != fileStore.blockReason {
                persistenceBlockReason = fileStore.blockReason
            }
            print("⚠️ Failed to save global settings JSON at \(fileStore.fileURL.path): \(error)")
            return false
        }
    }
}
