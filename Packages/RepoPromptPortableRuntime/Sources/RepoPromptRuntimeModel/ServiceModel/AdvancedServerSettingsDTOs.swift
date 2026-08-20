import Foundation

/// Desktop `PromptSection`. Raw values are persisted; do not rename.
public enum PromptSection: String, CaseIterable, Codable, Sendable {
    case fileMap
    case fileContents
    case metaPrompts
    case userInstructions
    case gitDiff

    public static let defaultOrder: [PromptSection] = [.fileMap, .fileContents, .gitDiff, .metaPrompts, .userInstructions]

    public static let defaultOrderJSON = #"["fileMap","fileContents","gitDiff","metaPrompts","userInstructions"]"#

    public static func resolvedOrder(from raw: String) -> [PromptSection] {
        if let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([PromptSection].self, from: data),
           decoded.count == allCases.count,
           Set(decoded) == Set(allCases)
        {
            return decoded
        }
        return defaultOrder
    }

    public static func encode(_ order: [PromptSection]) -> String {
        guard let data = try? JSONEncoder().encode(order), let raw = String(data: data, encoding: .utf8) else {
            return defaultOrderJSON
        }
        return raw
    }
}

/// Desktop `GlobalScalarPreferences.ModelOverrideSettingsData`. Empty maps are valid.
public struct ModelOverrideMaps: Codable, Hashable, Sendable {
    public var diffOverrides: [String: Bool]
    public var streamOverrides: [String: Bool]
    public var temperatureOverrides: [String: Double]
    public var responsesOverrides: [String: Bool]

    public static let empty = ModelOverrideMaps()

    private enum CodingKeys: String, CodingKey {
        case diffOverrides, streamOverrides, temperatureOverrides, responsesOverrides
    }

    public init(
        diffOverrides: [String: Bool] = [:],
        streamOverrides: [String: Bool] = [:],
        temperatureOverrides: [String: Double] = [:],
        responsesOverrides: [String: Bool] = [:]
    ) {
        self.diffOverrides = diffOverrides
        self.streamOverrides = streamOverrides
        self.temperatureOverrides = temperatureOverrides
        self.responsesOverrides = responsesOverrides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        diffOverrides = try container.decodeIfPresent([String: Bool].self, forKey: .diffOverrides) ?? [:]
        streamOverrides = try container.decodeIfPresent([String: Bool].self, forKey: .streamOverrides) ?? [:]
        temperatureOverrides = try container.decodeIfPresent([String: Double].self, forKey: .temperatureOverrides) ?? [:]
        responsesOverrides = try container.decodeIfPresent([String: Bool].self, forKey: .responsesOverrides) ?? [:]
    }

    public func streamOverride(for modelRaw: String) -> Bool? {
        streamOverrides[modelRaw]
    }

    public func responsesOverride(for modelRaw: String) -> Bool? {
        responsesOverrides[modelRaw]
    }

    public func temperatureOverride(for modelRaw: String) -> Double? {
        temperatureOverrides[modelRaw]
    }

    /// Desktop built-in Pro variants default to non-streaming unless overridden.
    public static let desktopNonStreamingBuiltins: Set<String> = [
        "gpt-5.2-pro",
        "gpt-5.2-pro-xhigh",
        "gpt-5.4-pro",
        "gpt-5.4-pro-xhigh"
    ]

    /// Desktop `canStream`: override wins, otherwise stream except built-in Pro variants.
    public func resolvedStream(for modelRaw: String) -> Bool {
        if let override = streamOverride(for: modelRaw) { return override }
        return !Self.desktopNonStreamingBuiltins.contains(modelRaw)
    }

    /// Desktop `usesResponsesAPI` step 2: custom-provider models only.
    public func resolvedUsesResponses(for modelRaw: String, isCustomProvider: Bool) -> Bool {
        guard isCustomProvider, let override = responsesOverride(for: modelRaw) else { return false }
        return override
    }

    /// Desktop `effectiveTemperature`: per-model override wins, including 0.0.
    public func resolvedTemperature(for modelRaw: String, globalAttached: Double?) -> Double? {
        if let override = temperatureOverride(for: modelRaw) { return override }
        return globalAttached
    }
}

public struct AdvancedServerSettings: Codable, Hashable, Sendable {
    /// Desktop `IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults`. Empty disables app-wide patterns.
    public static let canonicalGlobalIgnoreDefaults: String = """
    # RepoPrompt global ignore defaults (v2)
    **/node_modules/
    **/.npm/
    **/.pnpm-store/
    **/.yarn/
    **/.cache/
    **/bower_components/

    **/__pycache__/
    **/.pytest_cache/
    **/.mypy_cache/

    **/.gradle/
    **/.m2/
    **/.nuget/
    **/.cargo/
    **/.stack-work/
    **/.ccache/

    **/.idea/
    **/.vscode/
    **/.bundle/
    **/.gem/

    # Virtual environments
    **/.venv/
    **/venv/

    # Common temp/junk files
    **/*.swp
    **/*~
    **/*.tmp
    **/*.temp
    **/*.bak
    """

    public let respectRepoIgnore: Bool
    public let respectCursorIgnore: Bool
    public let respectNestedIgnoreFiles: Bool
    public let followSymbolicLinks: Bool
    public let showEmptyFolders: Bool
    public let globalIgnoreDefaults: String
    public let codeMapsGloballyDisabled: Bool
    public var codeMapsEnabled: Bool {
        !codeMapsGloballyDisabled
    }

    public let historyIdleThresholdMinutes: Int
    public let fileEditFormat: String
    public let customPlanningPrompt: String
    public let modelTemperature: Double
    public let setModelTemperature: Bool
    public let promptSectionsOrder: String
    public let duplicateUserInstructionsAtTop: Bool
    public let workflowPresets: WorkflowPresetDocument
    public let selectedCopyPresetID: UUID?
    public let selectedChatPresetID: UUID?
    public let savedPrompts: [SavedPromptRecord]
    public let includeSavedPromptsInClipboard: Bool
    public let filePathDisplayOption: String
    public let includeDatetimeInUserInstructions: Bool
    public let modelOverrides: ModelOverrideMaps
    public let appearanceMode: String
    public let showTooltips: Bool
    public let enableKeyboardShortcuts: Bool
    public let fontScaleBodySize: Double

    public init(
        respectRepoIgnore: Bool = true,
        respectCursorIgnore: Bool = true,
        respectNestedIgnoreFiles: Bool = true,
        followSymbolicLinks: Bool = false,
        showEmptyFolders: Bool = false,
        globalIgnoreDefaults: String = AdvancedServerSettings.canonicalGlobalIgnoreDefaults,
        codeMapsEnabled: Bool = true,
        codeMapsGloballyDisabled: Bool? = nil,
        historyIdleThresholdMinutes: Int = HistoryIdleThreshold.defaultMinutes,
        fileEditFormat: String = FileEditFormat.defaultRaw,
        customPlanningPrompt: String = "",
        modelTemperature: Double = 0.0,
        setModelTemperature: Bool = true,
        promptSectionsOrder: String = "",
        duplicateUserInstructionsAtTop: Bool = false,
        workflowPresets: WorkflowPresetDocument = .empty,
        selectedCopyPresetID: UUID? = nil,
        selectedChatPresetID: UUID? = nil,
        savedPrompts: [SavedPromptRecord] = [],
        includeSavedPromptsInClipboard: Bool = true,
        filePathDisplayOption: String = FilePathDisplay.defaultRaw,
        includeDatetimeInUserInstructions: Bool = false,
        modelOverrides: ModelOverrideMaps = .empty,
        appearanceMode: String = AppearanceMode.defaultRaw,
        showTooltips: Bool = true,
        enableKeyboardShortcuts: Bool = true,
        fontScaleBodySize: Double = FontScale.defaultRaw
    ) {
        self.respectRepoIgnore = respectRepoIgnore
        self.respectCursorIgnore = respectCursorIgnore
        self.respectNestedIgnoreFiles = respectNestedIgnoreFiles
        self.followSymbolicLinks = followSymbolicLinks
        self.showEmptyFolders = showEmptyFolders
        self.globalIgnoreDefaults = globalIgnoreDefaults
        self.codeMapsGloballyDisabled = codeMapsGloballyDisabled ?? !codeMapsEnabled
        self.historyIdleThresholdMinutes = HistoryIdleThreshold.clamped(historyIdleThresholdMinutes)
        self.fileEditFormat = fileEditFormat
        self.customPlanningPrompt = customPlanningPrompt
        self.modelTemperature = modelTemperature
        self.setModelTemperature = setModelTemperature
        self.promptSectionsOrder = promptSectionsOrder
        self.duplicateUserInstructionsAtTop = duplicateUserInstructionsAtTop
        self.workflowPresets = workflowPresets
        self.selectedCopyPresetID = selectedCopyPresetID
        self.selectedChatPresetID = selectedChatPresetID
        self.savedPrompts = savedPrompts
        self.includeSavedPromptsInClipboard = includeSavedPromptsInClipboard
        self.filePathDisplayOption = filePathDisplayOption
        self.includeDatetimeInUserInstructions = includeDatetimeInUserInstructions
        self.modelOverrides = modelOverrides
        self.appearanceMode = AppearanceMode.resolved(from: appearanceMode).rawValue
        self.showTooltips = showTooltips
        self.enableKeyboardShortcuts = enableKeyboardShortcuts
        self.fontScaleBodySize = FontScale.resolved(from: fontScaleBodySize).rawValue
    }

    public static let `default` = AdvancedServerSettings()

    private enum CodingKeys: String, CodingKey {
        case respectRepoIgnore
        case respectCursorIgnore
        case respectNestedIgnoreFiles
        case followSymbolicLinks
        case showEmptyFolders
        case globalIgnoreDefaults
        case codeMapsEnabled
        case codeMapsGloballyDisabled
        case historyIdleThresholdMinutes
        case fileEditFormat
        case customPlanningPrompt
        case modelTemperature
        case setModelTemperature
        case promptSectionsOrder
        case duplicateUserInstructionsAtTop
        case workflowPresets
        case selectedCopyPresetID
        case selectedChatPresetID
        case savedPrompts
        case includeSavedPromptsInClipboard
        case filePathDisplayOption
        case includeDatetimeInUserInstructions
        case modelOverrides
        case appearanceMode
        case showTooltips
        case enableKeyboardShortcuts
        case fontScaleBodySize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        respectRepoIgnore = try container.decodeIfPresent(Bool.self, forKey: .respectRepoIgnore) ?? true
        respectCursorIgnore = try container.decodeIfPresent(Bool.self, forKey: .respectCursorIgnore) ?? true
        respectNestedIgnoreFiles = try container.decodeIfPresent(Bool.self, forKey: .respectNestedIgnoreFiles) ?? true
        followSymbolicLinks = try container.decodeIfPresent(Bool.self, forKey: .followSymbolicLinks) ?? false
        showEmptyFolders = try container.decodeIfPresent(Bool.self, forKey: .showEmptyFolders) ?? false
        globalIgnoreDefaults = try container.decodeIfPresent(String.self, forKey: .globalIgnoreDefaults)
            ?? Self.canonicalGlobalIgnoreDefaults
        if let disabled = try container.decodeIfPresent(Bool.self, forKey: .codeMapsGloballyDisabled) {
            codeMapsGloballyDisabled = disabled
        } else if let enabled = try container.decodeIfPresent(Bool.self, forKey: .codeMapsEnabled) {
            codeMapsGloballyDisabled = !enabled
        } else {
            codeMapsGloballyDisabled = false
        }
        historyIdleThresholdMinutes = try HistoryIdleThreshold.clamped(
            container.decodeIfPresent(Int.self, forKey: .historyIdleThresholdMinutes) ?? HistoryIdleThreshold.defaultMinutes
        )
        fileEditFormat = try container.decodeIfPresent(String.self, forKey: .fileEditFormat) ?? FileEditFormat.defaultRaw
        customPlanningPrompt = try container.decodeIfPresent(String.self, forKey: .customPlanningPrompt) ?? ""
        modelTemperature = try container.decodeIfPresent(Double.self, forKey: .modelTemperature) ?? 0.0
        setModelTemperature = try container.decodeIfPresent(Bool.self, forKey: .setModelTemperature) ?? true
        promptSectionsOrder = try container.decodeIfPresent(String.self, forKey: .promptSectionsOrder) ?? ""
        duplicateUserInstructionsAtTop = try container.decodeIfPresent(Bool.self, forKey: .duplicateUserInstructionsAtTop) ?? false
        workflowPresets = try container.decodeIfPresent(WorkflowPresetDocument.self, forKey: .workflowPresets) ?? .empty
        selectedCopyPresetID = try container.decodeIfPresent(UUID.self, forKey: .selectedCopyPresetID)
        selectedChatPresetID = try container.decodeIfPresent(UUID.self, forKey: .selectedChatPresetID)
        savedPrompts = try container.decodeIfPresent([SavedPromptRecord].self, forKey: .savedPrompts) ?? []
        includeSavedPromptsInClipboard = try container.decodeIfPresent(Bool.self, forKey: .includeSavedPromptsInClipboard) ?? true
        filePathDisplayOption = try container.decodeIfPresent(String.self, forKey: .filePathDisplayOption) ?? FilePathDisplay.defaultRaw
        includeDatetimeInUserInstructions = try container.decodeIfPresent(Bool.self, forKey: .includeDatetimeInUserInstructions) ?? false
        modelOverrides = try container.decodeIfPresent(ModelOverrideMaps.self, forKey: .modelOverrides) ?? .empty
        appearanceMode = try AppearanceMode.resolved(
            from: container.decodeIfPresent(String.self, forKey: .appearanceMode)
        ).rawValue
        showTooltips = try container.decodeIfPresent(Bool.self, forKey: .showTooltips) ?? true
        enableKeyboardShortcuts = try container.decodeIfPresent(Bool.self, forKey: .enableKeyboardShortcuts) ?? true
        fontScaleBodySize = try FontScale.resolved(
            from: container.decodeIfPresent(Double.self, forKey: .fontScaleBodySize)
        ).rawValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(respectRepoIgnore, forKey: .respectRepoIgnore)
        try container.encode(respectCursorIgnore, forKey: .respectCursorIgnore)
        try container.encode(respectNestedIgnoreFiles, forKey: .respectNestedIgnoreFiles)
        try container.encode(followSymbolicLinks, forKey: .followSymbolicLinks)
        try container.encode(showEmptyFolders, forKey: .showEmptyFolders)
        try container.encode(globalIgnoreDefaults, forKey: .globalIgnoreDefaults)
        try container.encode(codeMapsEnabled, forKey: .codeMapsEnabled)
        try container.encode(codeMapsGloballyDisabled, forKey: .codeMapsGloballyDisabled)
        try container.encode(historyIdleThresholdMinutes, forKey: .historyIdleThresholdMinutes)
        try container.encode(fileEditFormat, forKey: .fileEditFormat)
        try container.encode(customPlanningPrompt, forKey: .customPlanningPrompt)
        try container.encode(modelTemperature, forKey: .modelTemperature)
        try container.encode(setModelTemperature, forKey: .setModelTemperature)
        try container.encode(promptSectionsOrder, forKey: .promptSectionsOrder)
        try container.encode(duplicateUserInstructionsAtTop, forKey: .duplicateUserInstructionsAtTop)
        try container.encode(workflowPresets, forKey: .workflowPresets)
        try container.encodeIfPresent(selectedCopyPresetID, forKey: .selectedCopyPresetID)
        try container.encodeIfPresent(selectedChatPresetID, forKey: .selectedChatPresetID)
        try container.encode(savedPrompts, forKey: .savedPrompts)
        try container.encode(includeSavedPromptsInClipboard, forKey: .includeSavedPromptsInClipboard)
        try container.encode(filePathDisplayOption, forKey: .filePathDisplayOption)
        try container.encode(includeDatetimeInUserInstructions, forKey: .includeDatetimeInUserInstructions)
        try container.encode(modelOverrides, forKey: .modelOverrides)
        try container.encode(appearanceMode, forKey: .appearanceMode)
        try container.encode(showTooltips, forKey: .showTooltips)
        try container.encode(enableKeyboardShortcuts, forKey: .enableKeyboardShortcuts)
        try container.encode(fontScaleBodySize, forKey: .fontScaleBodySize)
    }

    /// Desktop `PromptViewModel.FileEditFormat`: Diff / Whole / None. Missing or invalid raw → Diff.
    public enum FileEditFormat: String, CaseIterable, Sendable {
        case diff = "Diff"
        case whole = "Whole"
        case none = "None"

        public static let defaultRaw = FileEditFormat.diff.rawValue

        public static func resolved(from raw: String?) -> FileEditFormat {
            FileEditFormat(rawValue: raw ?? defaultRaw) ?? .diff
        }

        /// Desktop `targetFileEditFormat`: None stays None; a model that cannot diff is forced to Whole.
        public func target(modelCapableOfDiff: Bool) -> FileEditFormat {
            if self == .none { return .none }
            return modelCapableOfDiff ? self : .whole
        }
    }

    public func resolvedFileEditFormat(modelCapableOfDiff: Bool = true) -> FileEditFormat {
        FileEditFormat.resolved(from: fileEditFormat).target(modelCapableOfDiff: modelCapableOfDiff)
    }

    /// Desktop `FilePathDisplay`: Full / Relative. Missing or invalid raw → Full.
    public enum FilePathDisplay: String, CaseIterable, Sendable {
        case full = "Full"
        case relative = "Relative"

        public static let defaultRaw = FilePathDisplay.full.rawValue

        public static func resolved(from raw: String?) -> FilePathDisplay {
            FilePathDisplay(rawValue: raw ?? defaultRaw) ?? .full
        }

        public static func joinedFullPath(rootPath: String, logicalPath: String) -> String {
            if logicalPath.hasPrefix("/") { return logicalPath }
            var root = rootPath
            while root.hasSuffix("/") {
                root.removeLast()
            }
            return root.isEmpty ? logicalPath : "\(root)/\(logicalPath)"
        }
    }

    public func resolvedFilePathDisplay() -> FilePathDisplay {
        FilePathDisplay.resolved(from: filePathDisplayOption)
    }

    public func displayedFilePath(logicalPath: String, fullPath: String?) -> String {
        switch resolvedFilePathDisplay() {
        case .relative:
            logicalPath
        case .full:
            fullPath ?? logicalPath
        }
    }

    /// Desktop `AppearanceMode`. Missing or invalid raw → System.
    public enum AppearanceMode: String, CaseIterable, Sendable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"

        public static let defaultRaw = AppearanceMode.system.rawValue

        public static func resolved(from raw: String?) -> AppearanceMode {
            AppearanceMode(rawValue: raw ?? defaultRaw) ?? .system
        }
    }

    public func resolvedAppearanceMode() -> AppearanceMode {
        AppearanceMode.resolved(from: appearanceMode)
    }

    /// Desktop `FontScalePreset` body sizes. Missing or invalid → 14.
    public enum FontScale: Double, CaseIterable, Sendable {
        case normal = 14
        case large = 16
        case extraLarge = 18

        public static let defaultRaw = FontScale.normal.rawValue

        public static func resolved(from raw: Double?) -> FontScale {
            guard let raw else { return .normal }
            return FontScale(rawValue: raw) ?? .normal
        }
    }

    public func resolvedFontScale() -> FontScale {
        FontScale.resolved(from: fontScaleBodySize)
    }

    /// Desktop MCP `file_system.skip_symlinks` is the inverse of `followSymbolicLinks`.
    public var skipSymlinks: Bool {
        !followSymbolicLinks
    }

    /// Desktop `AgentSessionMetadataRecord.defaultIdleThresholdMinutes` and MCP `idle_threshold_minutes`.
    public enum HistoryIdleThreshold {
        public static let defaultMinutes = 10
        public static let range = 0 ... 1440
        public static let integerRequiredMessage = "idle_threshold_minutes must be an integer"
        public static let rangeMessage = "idle_threshold_minutes must be between 0 and 1440"

        public static func clamped(_ raw: Int) -> Int {
            min(max(range.lowerBound, raw), range.upperBound)
        }

        /// Desktop: gaps ≤ threshold count; gaps > threshold add 0.
        public static func activeDurationSeconds(timestamps: [Date], thresholdMinutes: Int) -> Int {
            let sorted = timestamps.sorted()
            guard sorted.count >= 2 else { return 0 }
            let thresholdSeconds = thresholdMinutes * 60
            var total = 0
            for (previous, next) in zip(sorted, sorted.dropFirst()) {
                let gap = Int(max(0, next.timeIntervalSince(previous)))
                if gap <= thresholdSeconds {
                    total += gap
                }
            }
            return total
        }
    }

    public static let codeMapsGloballyDisabledMCPMessage =
        "Code Maps are globally disabled in Advanced Settings; codemap-only selection modes and get_code_structure are unavailable."

    /// Desktop `effectiveMCPCodeMapUsage`: disable remaps copy/chat usage to `.none` without mutating presets.
    public func resolvedCodeMapUsage(_ usage: CodeMapUsage) -> CodeMapUsage {
        codeMapsGloballyDisabled ? .none : usage
    }

    public func formattedUserInstructions(_ text: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return """
        <user_instructions date="\(formatter.string(from: now))">
        \(text)
        </user_instructions>
        """
    }

    public func packagedContextPreamble(selectionRevision: Int64) -> [String] {
        [
            "# RepoPrompt Context",
            "selection-revision: \(selectionRevision)",
            "file-edit-format: \(resolvedFileEditFormat().rawValue)"
        ]
    }

    public func resolvedPromptSectionOrder() -> [PromptSection] {
        PromptSection.resolvedOrder(from: promptSectionsOrder)
    }

    public func resolvedCopyPreset() -> CopyPresetRecord {
        workflowPresets.resolvedCopyPreset(selectedID: selectedCopyPresetID)
    }

    public func resolvedChatPreset() -> ChatPresetRecord {
        workflowPresets.resolvedChatPreset(selectedID: selectedChatPresetID)
    }

    public func resolvedSavedPrompts() -> [SavedPromptRecord] {
        SavedPromptRecord.resolvedCatalog(stored: savedPrompts)
    }

    /// Desktop copy vs chat selected IDs. Clipboard toggle omits metas from copy only.
    /// Chat `useStoredPromptsAsSystem` with one ID uses that body as system, not `<meta prompt>`.
    public func resolvedMetaPromptIDs(purpose: PromptPackagingPurpose) -> [UUID] {
        switch purpose {
        case .copy:
            guard includeSavedPromptsInClipboard else { return [] }
            let preset = resolvedCopyPreset()
            guard preset.includeMetaPrompts != false else { return [] }
            return preset.storedPromptIds ?? []
        case .chat:
            let preset = resolvedChatPreset()
            let ids = preset.storedPromptIds ?? []
            if preset.useStoredPromptsAsSystem == true, ids.count == 1 {
                return []
            }
            return ids
        }
    }

    public func resolvedMetaPromptsSnippet(purpose: PromptPackagingPurpose) -> String? {
        let ids = resolvedMetaPromptIDs(purpose: purpose)
        guard !ids.isEmpty else { return nil }
        let catalog = resolvedSavedPrompts()
        let selected = ids.compactMap { id in catalog.first(where: { $0.id == id }) }
        return SavedPromptRecord.metaPromptsSnippet(selected)
    }

    /// Desktop `PromptAssemblyBuilder`: optional top copy of user instructions, then live-read order.
    public func packagedContext(
        selectionRevision: Int64,
        snippets: [PromptSection: String],
        purpose: PromptPackagingPurpose = .copy,
        now: Date = Date()
    ) -> String {
        var parts = packagedContextPreamble(selectionRevision: selectionRevision)
        var effective = snippets
        if purpose == .copy, resolvedCopyPreset().includeFiles == false {
            effective[.fileContents] = nil
        }
        if effective[.metaPrompts] == nil, let meta = resolvedMetaPromptsSnippet(purpose: purpose) {
            effective[.metaPrompts] = meta
        }
        if includeDatetimeInUserInstructions,
           let user = effective[.userInstructions],
           !user.isEmpty
        {
            effective[.userInstructions] = formattedUserInstructions(user, now: now)
        }
        if duplicateUserInstructionsAtTop,
           let user = effective[.userInstructions],
           !user.isEmpty
        {
            parts.append(user)
        }
        for section in resolvedPromptSectionOrder() {
            guard let snippet = effective[section], !snippet.isEmpty else { continue }
            parts.append(snippet)
        }
        return parts.joined(separator: "\n\n")
    }

    public func replacing(
        respectRepoIgnore: Bool? = nil,
        respectCursorIgnore: Bool? = nil,
        respectNestedIgnoreFiles: Bool? = nil,
        followSymbolicLinks: Bool? = nil,
        showEmptyFolders: Bool? = nil,
        globalIgnoreDefaults: String? = nil,
        codeMapsGloballyDisabled: Bool? = nil,
        fileEditFormat: String? = nil,
        customPlanningPrompt: String? = nil,
        modelTemperature: Double? = nil,
        setModelTemperature: Bool? = nil,
        promptSectionsOrder: String? = nil,
        duplicateUserInstructionsAtTop: Bool? = nil,
        workflowPresets: WorkflowPresetDocument? = nil,
        selectedCopyPresetID: UUID? = nil,
        selectedChatPresetID: UUID? = nil,
        savedPrompts: [SavedPromptRecord]? = nil,
        includeSavedPromptsInClipboard: Bool? = nil,
        filePathDisplayOption: String? = nil,
        includeDatetimeInUserInstructions: Bool? = nil,
        modelOverrides: ModelOverrideMaps? = nil,
        appearanceMode: String? = nil,
        showTooltips: Bool? = nil,
        enableKeyboardShortcuts: Bool? = nil,
        fontScaleBodySize: Double? = nil
    ) -> AdvancedServerSettings {
        AdvancedServerSettings(
            respectRepoIgnore: respectRepoIgnore ?? self.respectRepoIgnore,
            respectCursorIgnore: respectCursorIgnore ?? self.respectCursorIgnore,
            respectNestedIgnoreFiles: respectNestedIgnoreFiles ?? self.respectNestedIgnoreFiles,
            followSymbolicLinks: followSymbolicLinks ?? self.followSymbolicLinks,
            showEmptyFolders: showEmptyFolders ?? self.showEmptyFolders,
            globalIgnoreDefaults: globalIgnoreDefaults ?? self.globalIgnoreDefaults,
            codeMapsGloballyDisabled: codeMapsGloballyDisabled ?? self.codeMapsGloballyDisabled,
            historyIdleThresholdMinutes: historyIdleThresholdMinutes,
            fileEditFormat: fileEditFormat ?? self.fileEditFormat,
            customPlanningPrompt: customPlanningPrompt ?? self.customPlanningPrompt,
            modelTemperature: modelTemperature ?? self.modelTemperature,
            setModelTemperature: setModelTemperature ?? self.setModelTemperature,
            promptSectionsOrder: promptSectionsOrder ?? self.promptSectionsOrder,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop ?? self.duplicateUserInstructionsAtTop,
            workflowPresets: workflowPresets ?? self.workflowPresets,
            selectedCopyPresetID: selectedCopyPresetID ?? self.selectedCopyPresetID,
            selectedChatPresetID: selectedChatPresetID ?? self.selectedChatPresetID,
            savedPrompts: savedPrompts ?? self.savedPrompts,
            includeSavedPromptsInClipboard: includeSavedPromptsInClipboard ?? self.includeSavedPromptsInClipboard,
            filePathDisplayOption: filePathDisplayOption ?? self.filePathDisplayOption,
            includeDatetimeInUserInstructions: includeDatetimeInUserInstructions ?? self.includeDatetimeInUserInstructions,
            modelOverrides: modelOverrides ?? self.modelOverrides,
            appearanceMode: appearanceMode ?? self.appearanceMode,
            showTooltips: showTooltips ?? self.showTooltips,
            enableKeyboardShortcuts: enableKeyboardShortcuts ?? self.enableKeyboardShortcuts,
            fontScaleBodySize: fontScaleBodySize ?? self.fontScaleBodySize
        )
    }

    /// Desktop `effectiveTemperature`: disabled or global 0.0 omits the field.
    public func resolvedAttachedTemperature() -> Double? {
        guard setModelTemperature, modelTemperature != 0.0 else { return nil }
        return modelTemperature
    }

    /// Stamps live-read stream / Responses / temperature keys for a direct-provider launch.
    /// Diff overrides persist only; Desktop `canApplyDiff` stays unconditional true.
    public func stampedProviderSettings(_ settings: [String: String], modelRaw: String?) -> [String: String] {
        var next = settings
        let providerID = settings["provider.settingsID"].flatMap(ProviderSettingsID.init(rawValue:))
        let temperature: Double? = if let modelRaw {
            modelOverrides.resolvedTemperature(for: modelRaw, globalAttached: resolvedAttachedTemperature())
        } else {
            resolvedAttachedTemperature()
        }
        if let temperature {
            next["models.temperature"] = String(temperature)
        } else {
            next.removeValue(forKey: "models.temperature")
        }
        if let modelRaw {
            next["models.stream"] = modelOverrides.resolvedStream(for: modelRaw) ? "true" : "false"
            next["models.responses"] = modelOverrides.resolvedUsesResponses(
                for: modelRaw,
                isCustomProvider: providerID == .customOpenAICompatible
            ) ? "true" : "false"
        }
        return next
    }

    public func resolvedPlanningPrompt() -> String {
        let custom = customPlanningPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? Self.architectFallback : custom
    }

    /// Desktop Chat Planning Prompt empty default: built-in [Architect] body.
    public static let architectFallback = """
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

    Please proceed with your analysis based on the following <user instructions>
    """
}

public struct AdvancedServerSettingsSnapshot: Codable, Hashable, Sendable {
    public let settings: AdvancedServerSettings
    public let revision: Int64
    public let scannerPolicyGeneration: Int64
    public let updatedAt: Date

    public init(settings: AdvancedServerSettings, revision: Int64, updatedAt: Date) {
        self.settings = settings
        self.revision = revision
        scannerPolicyGeneration = revision
        self.updatedAt = updatedAt
    }
}

public struct ReplaceAdvancedServerSettingsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let settings: AdvancedServerSettings

    public init(expectedRevision: Int64, settings: AdvancedServerSettings) {
        self.expectedRevision = expectedRevision
        self.settings = settings
    }
}
