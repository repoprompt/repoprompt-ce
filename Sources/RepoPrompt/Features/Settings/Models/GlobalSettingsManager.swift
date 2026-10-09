import Foundation
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import RepoPromptShared

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

    /// Whether Agent Chats includes open Compose tabs without Agent sessions.
    /// Referenced by Agent Mode Overview and the Agent Chats list.
    static let agentModeShowComposeTabsWithoutAgentSessions = "agentModeShowComposeTabsWithoutAgentSessions"
}

extension Notification.Name {
    /// Posted after app-wide file-system/ignore preferences are changed through
    /// the settings surface. `userInfo["key"]` contains the app_settings key.
    static let appSettingsFileSystemPreferencesDidChange = Notification.Name("RepoPromptAppSettingsFileSystemPreferencesDidChange")

    /// Posted after durable Agent Models settings change through the scoped resolver.
    /// `userInfo[AgentModelsSettingsNotification.scopeKey]` contains `global` or
    /// `workspace`; workspace changes also include
    /// `userInfo[AgentModelsSettingsNotification.workspaceIDKey]`.
    static let agentModelsSettingsDidChange = Notification.Name("RepoPromptAgentModelsSettingsDidChange")
}

enum AgentModelsSettingsNotification {
    static let scopeKey = "scope"
    static let workspaceIDKey = "workspaceID"
    static let sourceWorkspaceIDKey = "sourceWorkspaceID"

    enum Scope: String {
        case global
        case workspace
    }

    static func userInfo(
        scope: AgentModelsEditingScope,
        sourceWorkspaceID: UUID? = nil
    ) -> [String: Any] {
        var userInfo: [String: Any] = switch scope {
        case .global:
            [scopeKey: Scope.global.rawValue]
        case let .workspace(workspaceID):
            [
                scopeKey: Scope.workspace.rawValue,
                workspaceIDKey: workspaceID
            ]
        }
        if let sourceWorkspaceID {
            userInfo[sourceWorkspaceIDKey] = sourceWorkspaceID
        }
        return userInfo
    }
}

// MARK: - App policy adapters

/// Runtime catalogs, UI projections, and application side effects remain app-owned.
extension GlobalSettingsStore {
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

    func historyIdleThresholdMinutes() -> Int {
        let raw = (defaults.object(forKey: HistoryMCPToolService.idleThresholdSettingsKey) as? Int)
            ?? AgentSessionMetadataRecord.defaultIdleThresholdMinutes
        // Defense for out-of-band writes; the UI slider caps 0...60 but `defaults write`
        // can store anything. Clamp to the spec's 0...1440 range.
        return min(max(0, raw), 1440)
    }

    func setHistoryIdleThresholdMinutes(_ minutes: Int) {
        let clamped = min(max(0, minutes), 1440)
        defaults.set(clamped, forKey: HistoryMCPToolService.idleThresholdSettingsKey)
        objectWillChange.send()
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
        reloadFontScaleBodySizeFromDisk { rawValue in
            FontScalePreset(rawValue: rawValue)?.rawValue ?? FontScalePreset.normal.rawValue
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

    func codexComputerUseEnabled() -> Bool {
        CodexComputerUseWorkflow.isEnabled(persistedValue: scalarPreferences.agentMode?.codexComputerUseEnabled)
    }

    func setCodexComputerUseEnabled(_ enabled: Bool, commit: Bool = true) {
        let oldValue = codexComputerUseEnabled()
        updateAgentModeScalar(commit: commit) { settings in
            settings.codexComputerUseEnabled = enabled
        }
        CodexComputerUseWorkflow.postDidChangeIfNeeded(previousValue: oldValue, currentValue: codexComputerUseEnabled())
    }

    func codexReasoningSummariesEnabled() -> Bool {
        CodexReasoningSummaries.isEnabled(persistedValue: scalarPreferences.agentMode?.codexReasoningSummariesEnabled)
    }

    func setCodexReasoningSummariesEnabled(_ enabled: Bool, commit: Bool = true) {
        let oldValue = codexReasoningSummariesEnabled()
        updateAgentModeScalar(commit: commit) { settings in
            settings.codexReasoningSummariesEnabled = enabled
        }
        CodexReasoningSummaries.postDidChangeIfNeeded(previousValue: oldValue, currentValue: codexReasoningSummariesEnabled())
    }

    /// App-global UI preference for the oversight-link confirmation. Nil reads as false; the flag
    /// only skips the dialog and never relaxes runtime authorization or approval restrictions.
    func suppressOversightLinkConfirmation() -> Bool {
        scalarPreferences.agentMode?.suppressOversightLinkConfirmation == true
    }

    func setSuppressOversightLinkConfirmation(_ suppressed: Bool, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { settings in
            // Clearing returns to the baseline scalar shape for older CE builds.
            settings.suppressOversightLinkConfirmation = suppressed ? true : nil
        }
    }

    func codexMemoriesEnabled() -> Bool {
        CodexMemories.isEnabled(persistedValue: scalarPreferences.agentMode?.codexMemoriesEnabled)
    }

    func codexAppsEnabled() -> Bool {
        CodexCapabilityPreference.isEnabled(persistedValue: scalarPreferences.agentMode?.codexAppsEnabled)
    }

    func codexPluginsEnabled() -> Bool {
        CodexCapabilityPreference.isEnabled(persistedValue: scalarPreferences.agentMode?.codexPluginsEnabled)
    }

    func codexMCPElicitationEnabled() -> Bool {
        CodexCapabilityPreference.isEnabled(persistedValue: scalarPreferences.agentMode?.codexMCPElicitationEnabled)
    }

    func codexToolSuggestionsEnabled() -> Bool {
        CodexCapabilityPreference.isEnabled(persistedValue: scalarPreferences.agentMode?.codexToolSuggestionsEnabled)
    }

    func providerConversationCleanupAction() -> ProviderConversationCleanupAction {
        guard let raw = scalarPreferences.agentMode?.providerConversationCleanupAction,
              let action = ProviderConversationCleanupAction(rawValue: raw)
        else {
            return .archive
        }
        return action
    }

    func setProviderConversationCleanupAction(_ action: ProviderConversationCleanupAction, commit: Bool = true) {
        updateAgentModeScalar(commit: commit) { settings in
            settings.providerConversationCleanupAction = action.rawValue
        }
    }

    func modelRouterConfiguration() -> AgentTaskRouterConfiguration {
        let stored = scalarPreferences.modelRouter
        let backendRaw = stored?.selectedBackendRawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let backendID = backendRaw.flatMap { $0.isEmpty ? nil : AgentTaskRouterBackendID(rawValue: $0) }

        let rolesMaterialized = stored?.candidateRoleRawValues != nil
        let rawRoles = stored?.candidateRoleRawValues ?? []
        let knownRoles = AgentModelCatalog.TaskLabelKind.allCases.filter { rawRoles.contains($0.rawValue) }
        let unknownRoles = rawRoles.filter { raw in
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && AgentModelCatalog.TaskLabelKind(rawValue: raw) == nil
        }

        let providersMaterialized = stored?.allowedProviderRawValues != nil
        let rawProviders = stored?.allowedProviderRawValues ?? []
        let knownProviders = Set(rawProviders.compactMap(AgentProviderKind.init(rawValue:)))
        let unknownProviders = rawProviders.filter { raw in
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && AgentProviderKind(rawValue: raw) == nil
        }

        let enabled = stored?.enabled ?? false
        let primaryProvider = stored?.primaryProviderRawValue.flatMap(AgentProviderKind.init(rawValue:))
        let subagentProvider = stored?.subagentProviderRawValue.flatMap(AgentProviderKind.init(rawValue:))
        let storedCustomInstructions = stored?.customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let customInstructions = storedCustomInstructions.count <= 1000
            && storedCustomInstructions.utf8.count <= 4096
            ? storedCustomInstructions
            : ""
        let validity: AgentTaskRouterConfiguration.Validity = if !enabled {
            .disabled
        } else if backendID == nil {
            .backendMissing
        } else {
            .valid
        }
        return AgentTaskRouterConfiguration(
            enabled: enabled,
            selectedBackendID: backendID,
            selectedBackendRawValue: backendRaw,
            candidateRoles: knownRoles,
            allowedProviders: knownProviders,
            candidateRolesMaterialized: rolesMaterialized,
            allowedProvidersMaterialized: providersMaterialized,
            unknownRoleRawValues: unknownRoles,
            unknownProviderRawValues: unknownProviders,
            primaryProvider: primaryProvider,
            subagentProvider: subagentProvider,
            customInstructions: customInstructions,
            validity: validity,
            revision: modelRouterSettingsRevision,
            usageBalancing: AgentUsageBalancingConfiguration(
                enabled: stored?.usageBalancingEnabled == true && AgentUsageBalancingPreset.stored(stored?.usageBalancingPreset) != nil,
                preset: AgentUsageBalancingPreset.stored(stored?.usageBalancingPreset) ?? .evenPace
            ),
            allowPaidFastRouting: stored?.allowPaidFastRouting == true
        )
    }

    func setUsageBalancingEnabled(_ enabled: Bool) {
        updateModelRouterScalar(commit: true) { $0.usageBalancingEnabled = enabled }
    }

    func setUsageBalancingPreset(_ preset: AgentUsageBalancingPreset) {
        updateModelRouterScalar(commit: true) { $0.usageBalancingPreset = preset.rawValue }
    }

    func setAllowPaidFastRouting(_ enabled: Bool) {
        updateModelRouterScalar(commit: true) { $0.allowPaidFastRouting = enabled }
    }

    func setModelRouterBackend(_ backendID: AgentTaskRouterBackendID, commit: Bool = true) {
        updateModelRouterScalar(commit: commit) { $0.selectedBackendRawValue = backendID.rawValue }
    }

    func setModelRouterCandidateRoles(_ roles: Set<AgentModelCatalog.TaskLabelKind>, commit: Bool = true) {
        updateModelRouterScalar(commit: commit) { settings in
            let unknown = (settings.candidateRoleRawValues ?? []).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && AgentModelCatalog.TaskLabelKind(rawValue: $0) == nil
            }
            settings.candidateRoleRawValues = AgentModelCatalog.TaskLabelKind.allCases
                .filter(roles.contains)
                .map(\.rawValue) + unknown
        }
    }

    func setModelRouterAllowedProviders(_ providers: Set<AgentProviderKind>, commit: Bool = true) {
        updateModelRouterScalar(commit: commit) { settings in
            let unknown = (settings.allowedProviderRawValues ?? []).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && AgentProviderKind(rawValue: $0) == nil
            }
            settings.allowedProviderRawValues = AgentProviderKind.allCases
                .filter(providers.contains)
                .map(\.rawValue) + unknown
        }
    }

    func setModelRouterProvider(_ provider: AgentProviderKind?, scope: AgentTaskRoutingScope, commit: Bool = true) {
        updateModelRouterScalar(commit: commit) { settings in
            switch scope {
            case .primarySession: settings.primaryProviderRawValue = provider?.rawValue
            case .subagent: settings.subagentProviderRawValue = provider?.rawValue
            }
        }
    }

    /// Materializes the currently visible policy on first enable; subsequent provider additions
    /// remain opt-in because these arrays are thereafter explicit.
    func enableModelRouterWithCurrentPolicy(
        backendID: AgentTaskRouterBackendID,
        roles: Set<AgentModelCatalog.TaskLabelKind>,
        providers: Set<AgentProviderKind>,
        commit: Bool = true
    ) {
        updateModelRouterScalar(commit: commit) { settings in
            let unknownRoles = (settings.candidateRoleRawValues ?? []).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && AgentModelCatalog.TaskLabelKind(rawValue: $0) == nil
            }
            let unknownProviders = (settings.allowedProviderRawValues ?? []).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && AgentProviderKind(rawValue: $0) == nil
            }
            settings.selectedBackendRawValue = backendID.rawValue
            settings.candidateRoleRawValues = AgentModelCatalog.TaskLabelKind.allCases
                .filter(roles.contains)
                .map(\.rawValue) + unknownRoles
            settings.allowedProviderRawValues = AgentProviderKind.allCases
                .filter(providers.contains)
                .map(\.rawValue) + unknownProviders
            settings.enabled = true
        }
    }

    @discardableResult
    func setAgentSessionHandoffInstructions(_ instructions: String, commit: Bool = true) -> Bool {
        guard case .valid = AgentSessionHandoffInstructionsPolicy.validation(of: instructions) else {
            return false
        }

        let proposedValue = instructions.isEmpty ? nil : instructions
        guard scalarPreferences.agentMode?.agentSessionHandoffInstructions != proposedValue else {
            return true
        }

        updateAgentModeScalar(commit: commit) { settings in
            settings.agentSessionHandoffInstructions = proposedValue
        }
        return true
    }

    #if DEBUG
        func worktreeStartupBenchmarkDiagnosticsEnabled() -> Bool {
            defaults.bool(forKey: WorktreeStartupBenchmarkDiagnostics.enabledDefaultsKey)
        }
    #endif

    #if DEBUG
        func setWorktreeStartupBenchmarkDiagnosticsEnabled(_ enabled: Bool) {
            defaults.set(enabled, forKey: WorktreeStartupBenchmarkDiagnostics.enabledDefaultsKey)
        }
    #endif

    func setTelemetryEnabled(_ enabled: Bool, commit: Bool = true) {
        defaults.set(enabled, forKey: Self.telemetryEnabledDefaultsKey)
        updateTelemetryScalar(commit: commit) { settings in
            settings.enabled = enabled
        }
        if enabled {
            SentryTelemetryBootstrap.start()
        } else {
            SentryTelemetryBootstrap.disableAndClose()
        }
    }

    func setTelemetryAppHangReportsEnabled(_ enabled: Bool, commit: Bool = true) {
        updateTelemetryScalar(commit: commit) { settings in
            settings.appHangReportsEnabled = enabled
        }
        SentryTelemetryBootstrap.restartIfStarted()
    }

    func setTelemetryPerformanceTracingEnabled(_ enabled: Bool, commit: Bool = true) {
        updateTelemetryScalar(commit: commit) { settings in
            settings.performanceTracingEnabled = enabled
        }
        SentryTelemetryBootstrap.restartIfStarted()
    }

    func notificationPreferences() -> NotificationPreferences {
        (scalarPreferences.notifications ?? GlobalScalarPreferences.NotificationSettings()).resolved()
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
        let globalDefaultsBeforeMutation = globalDefaults
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
        let globalDefaultsChanged = globalDefaultsBeforeMutation != globalDefaults
        persistGlobalDefaultsChange(before: globalDefaultsBeforeMutation, commit: true)
        if globalDefaultsChanged {
            postAgentModelsSettingsDidChange(scope: .global)
        }
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
        let globalDefaultsBeforeMutation = globalDefaults
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
        let globalDefaultsChanged = globalDefaultsBeforeMutation != globalDefaults
        persistGlobalDefaultsChange(before: globalDefaultsBeforeMutation, commit: true)
        if globalDefaultsChanged {
            postAgentModelsSettingsDidChange(scope: .global)
        }
    }

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
        let globalDefaultsBeforeMutation = globalDefaults
        if providers == Set(RecommendationProviderKind.allCases) {
            globalDefaults.recommendationProviderFilterRaw = nil
        } else {
            globalDefaults.recommendationProviderFilterRaw = RecommendationProviderKind.allCases
                .filter { providers.contains($0) }
                .map(\.rawValue)
        }
        persistGlobalDefaultsChange(before: globalDefaultsBeforeMutation, commit: commit)
    }

    func normalizeDisabledOpenAIServiceTierVariants() {
        normalizeDisabledOpenAIServiceTierVariants(normalizeModelRaw: AIModel.rawValueWithoutOpenAIServiceTier)
    }

    /// Invoke before constructing any settings store or decoding Agent Models profiles.
    nonisolated static func installApplicationModelIdentityPolicy() {
        SettingsModelIdentityPolicy.installCursorCanonicalizer { raw in
            // Exact advertised identities win over historical rename aliases.
            if AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor)?.options.contains(where: { $0.rawValue == raw }) == true {
                return raw
            }
            if let specifier = try? CursorAIModelCatalog.ModelSpecifier(raw: raw), !specifier.overrides.isEmpty {
                return ACPModelParameterIdentity.canonicalBaseModelRaw(specifier.baseModelRaw, providerID: .cursor)
            }
            return CursorAIModelCatalog.canonicalAlias(raw)
        }
    }

    static func installProcessApplicationEventBridge(notificationCenter: NotificationCenter = .default) {
        applicationEventHandler = applicationEventAdapter(notificationCenter: notificationCenter)
    }

    private static func applicationEventAdapter(
        notificationCenter: NotificationCenter
    ) -> @MainActor (GlobalSettingsEvent, GlobalSettingsStore) -> Void {
        { event, store in
            switch event {
            case .notificationPreferencesChanged:
                notificationCenter.post(name: .notificationPreferencesDidChange, object: store)
            case let .agentModelsSettingsChanged(scope):
                notificationCenter.post(
                    name: .agentModelsSettingsDidChange,
                    object: store,
                    userInfo: AgentModelsSettingsNotification.userInfo(scope: scope)
                )
            case .settingsInstalled:
                notificationCenter.post(
                    name: .recommendationsShouldRefresh,
                    object: store,
                    userInfo: ["reason": "globalSettingsInstalled"]
                )
            case .worktreeLocationLabelsChanged:
                AgentSessionLinkLocationInvalidationSink.locationLabelsChanged(inWorkspace: nil)
            }
        }
    }

    /// Install before feature startup; no buffering or asynchronous delivery is introduced.
    func installApplicationEventBridge(notificationCenter: NotificationCenter = .default) {
        eventHandler = Self.applicationEventAdapter(notificationCenter: notificationCenter)
    }
}

extension GlobalScalarPreferences.NotificationSettings {
    func resolved(over defaults: NotificationPreferences = .defaults) -> NotificationPreferences {
        var preferences = defaults
        preferences.enabled = enabled ?? defaults.enabled
        preferences.agentInteractions = agentInteractions ?? defaults.agentInteractions
        preferences.agentInstructionWaits = agentInstructionWaits ?? defaults.agentInstructionWaits
        preferences.agentTurnComplete = agentTurnComplete ?? defaults.agentTurnComplete
        preferences.agentTurnFailed = agentTurnFailed ?? defaults.agentTurnFailed
        preferences.chatComplete = chatComplete ?? defaults.chatComplete
        preferences.contextBuilderComplete = contextBuilderComplete ?? defaults.contextBuilderComplete
        preferences.approveFromNotifications = approveFromNotifications ?? defaults.approveFromNotifications
        preferences.answerFromNotifications = answerFromNotifications ?? defaults.answerFromNotifications
        preferences.replyFromCompletion = replyFromCompletion ?? defaults.replyFromCompletion
        preferences.showDetails = showDetails ?? defaults.showDetails
        preferences.notifyWhileActive = notifyWhileActive ?? defaults.notifyWhileActive
        preferences.completionsWhileActive = completionsWhileActive ?? defaults.completionsWhileActive
        preferences.includeAgentDrivenSessions = includeAgentDrivenSessions ?? defaults.includeAgentDrivenSessions
        preferences.dockBadge = dockBadge ?? defaults.dockBadge
        preferences.mcpAskUserNotifyInsteadOfActivate = mcpAskUserNotifyInsteadOfActivate
            ?? defaults.mcpAskUserNotifyInsteadOfActivate
        return preferences
    }
}

extension AgentModelsSettingsProfile {
    func contextBuilderModelParameterSelections(
        for agent: AgentProviderKind,
        modelRaw: String
    ) -> [ACPModelParameterSelection] {
        guard let identity = SettingsAgentKind(rawValue: agent.rawValue) else { return [] }
        return contextBuilderModelParameterSelections(forAgentIdentity: identity, modelRaw: modelRaw)
    }
}
