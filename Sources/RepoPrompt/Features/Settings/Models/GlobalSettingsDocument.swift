import Foundation

/// Versioned JSON document stored at
/// `~/Library/Application Support/RepoPrompt CE/Settings/globalSettings.json`.
///
/// Schema v1 contains copy settings, chat settings, and cross-workspace global
/// defaults. Schema v2 adds optional scalar preference groups. Scalar fields stay
/// optional so missing JSON fields fall back through the typed GlobalSettingsStore
/// accessors without losing current default behavior.
struct GlobalSettingsDocument: Codable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var updatedAt: Date
    var copySettingsByWorkspaceID: [String: CopyGlobalSettings]
    var chatSettingsByWorkspaceID: [String: ChatGlobalSettings]
    var globalDefaults: GlobalDefaults
    var scalarPreferences: GlobalScalarPreferences?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        updatedAt: Date = Date(),
        copySettings: [UUID: CopyGlobalSettings] = [:],
        chatSettings: [UUID: ChatGlobalSettings] = [:],
        globalDefaults: GlobalDefaults = GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
        scalarPreferences: GlobalScalarPreferences? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        copySettingsByWorkspaceID = Self.encodeUUIDKeyedDictionary(copySettings)
        chatSettingsByWorkspaceID = Self.encodeUUIDKeyedDictionary(chatSettings)
        self.globalDefaults = globalDefaults
        self.scalarPreferences = scalarPreferences
    }

    var copySettings: [UUID: CopyGlobalSettings] {
        Self.decodeUUIDKeyedDictionary(copySettingsByWorkspaceID)
    }

    var chatSettings: [UUID: ChatGlobalSettings] {
        Self.decodeUUIDKeyedDictionary(chatSettingsByWorkspaceID)
    }

    func replacing(
        copySettings: [UUID: CopyGlobalSettings],
        chatSettings: [UUID: ChatGlobalSettings],
        globalDefaults: GlobalDefaults,
        scalarPreferences: GlobalScalarPreferences? = nil,
        updatedAt: Date = Date()
    ) -> GlobalSettingsDocument {
        GlobalSettingsDocument(
            schemaVersion: max(schemaVersion, Self.currentSchemaVersion),
            updatedAt: updatedAt,
            copySettings: copySettings,
            chatSettings: chatSettings,
            globalDefaults: globalDefaults,
            scalarPreferences: scalarPreferences ?? self.scalarPreferences
        )
    }

    private static func encodeUUIDKeyedDictionary<Value>(_ values: [UUID: Value]) -> [String: Value] {
        values.reduce(into: [String: Value]()) { result, entry in
            result[entry.key.uuidString] = entry.value
        }
    }

    private static func decodeUUIDKeyedDictionary<Value>(_ values: [String: Value]) -> [UUID: Value] {
        values.reduce(into: [UUID: Value]()) { result, entry in
            guard let uuid = UUID(uuidString: entry.key) else { return }
            result[uuid] = entry.value
        }
    }
}

// MARK: - Worktree Visual Identity

enum WorktreeVisualMarkerStyle: String, Codable, Equatable {
    case dot
    case ring
    case capsule
}

struct WorktreeVisualIdentity: Codable, Equatable {
    static let defaultIconName = "circle.fill"
    static let defaultMarkerStyle = WorktreeVisualMarkerStyle.dot

    var label: String?
    var colorHex: String
    var iconName: String
    var markerStyle: WorktreeVisualMarkerStyle
    var updatedAt: Date?

    init(
        label: String? = nil,
        colorHex: String,
        iconName: String = Self.defaultIconName,
        markerStyle: WorktreeVisualMarkerStyle = Self.defaultMarkerStyle,
        updatedAt: Date? = nil
    ) {
        self.label = label
        self.colorHex = colorHex
        self.iconName = iconName
        self.markerStyle = markerStyle
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case label, colorHex, iconName, markerStyle, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName) ?? Self.defaultIconName
        markerStyle = try container.decodeIfPresent(WorktreeVisualMarkerStyle.self, forKey: .markerStyle) ?? Self.defaultMarkerStyle
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct WorktreeVisualIdentityRepositoryBucket: Codable, Equatable {
    var identitiesByWorktreeID: [String: WorktreeVisualIdentity]

    init(identitiesByWorktreeID: [String: WorktreeVisualIdentity] = [:]) {
        self.identitiesByWorktreeID = identitiesByWorktreeID
    }
}

// MARK: - Scalar Preferences

/// Optional scalar preferences stored in schema v2.
///
/// Keep groups and fields optional so missing values continue to use the same
/// defaults as the typed settings accessors.
struct GlobalScalarPreferences: Codable, Equatable {
    var ui: UISettings?
    var promptPackaging: PromptPackagingSettings?
    var modelSelection: ModelSelectionSettings?
    var mcp: MCPSettings?
    var fileSystem: FileSystemSettings?
    var agentMode: AgentModeSettings?
    var modelOverrides: ModelOverrideSettingsData?

    init(
        ui: UISettings? = nil,
        promptPackaging: PromptPackagingSettings? = nil,
        modelSelection: ModelSelectionSettings? = nil,
        mcp: MCPSettings? = nil,
        fileSystem: FileSystemSettings? = nil,
        agentMode: AgentModeSettings? = nil,
        modelOverrides: ModelOverrideSettingsData? = nil
    ) {
        self.ui = ui
        self.promptPackaging = promptPackaging
        self.modelSelection = modelSelection
        self.mcp = mcp
        self.fileSystem = fileSystem
        self.agentMode = agentMode
        self.modelOverrides = modelOverrides
    }

    struct UISettings: Codable, Equatable {
        var appearanceMode: String?
        var useTransparency: Bool?
        var collapseLatestFileChanges: Bool?
        var showTooltips: Bool?
        var experimentalAttributedTextEditor: Bool?
        var fileMentionPickerStyle: String?
        var enableKeyboardShortcuts: Bool?
        var fontScaleBodySize: Double?
        var showDatesInMessageTimestamps: Bool?

        init(
            appearanceMode: String? = nil,
            useTransparency: Bool? = nil,
            collapseLatestFileChanges: Bool? = nil,
            showTooltips: Bool? = nil,
            experimentalAttributedTextEditor: Bool? = nil,
            fileMentionPickerStyle: String? = nil,
            enableKeyboardShortcuts: Bool? = nil,
            fontScaleBodySize: Double? = nil,
            showDatesInMessageTimestamps: Bool? = nil
        ) {
            self.appearanceMode = appearanceMode
            self.useTransparency = useTransparency
            self.collapseLatestFileChanges = collapseLatestFileChanges
            self.showTooltips = showTooltips
            self.experimentalAttributedTextEditor = experimentalAttributedTextEditor
            self.fileMentionPickerStyle = fileMentionPickerStyle
            self.enableKeyboardShortcuts = enableKeyboardShortcuts
            self.fontScaleBodySize = fontScaleBodySize
            self.showDatesInMessageTimestamps = showDatesInMessageTimestamps
        }
    }

    struct PromptPackagingSettings: Codable, Equatable {
        var promptSectionsOrder: String?
        var duplicateUserInstructionsAtTop: Bool?
        var filePathDisplayOption: String?
        var selectedFilesSortMethod: String?
        var fileEditFormat: String?
        var includeDatetimeInUserInstructions: Bool?
        var customPlanningPrompt: String?
        var modelTemperature: Double?
        var setModelTemperature: Bool?
        var complexEditStrategy: String?

        init(
            promptSectionsOrder: String? = nil,
            duplicateUserInstructionsAtTop: Bool? = nil,
            filePathDisplayOption: String? = nil,
            selectedFilesSortMethod: String? = nil,
            fileEditFormat: String? = nil,
            includeDatetimeInUserInstructions: Bool? = nil,
            customPlanningPrompt: String? = nil,
            modelTemperature: Double? = nil,
            setModelTemperature: Bool? = nil,
            complexEditStrategy: String? = nil
        ) {
            self.promptSectionsOrder = promptSectionsOrder
            self.duplicateUserInstructionsAtTop = duplicateUserInstructionsAtTop
            self.filePathDisplayOption = filePathDisplayOption
            self.selectedFilesSortMethod = selectedFilesSortMethod
            self.fileEditFormat = fileEditFormat
            self.includeDatetimeInUserInstructions = includeDatetimeInUserInstructions
            self.customPlanningPrompt = customPlanningPrompt
            self.modelTemperature = modelTemperature
            self.setModelTemperature = setModelTemperature
            self.complexEditStrategy = complexEditStrategy
        }
    }

    struct ModelSelectionSettings: Codable, Equatable {
        var preferredComposeModel: String?
        var planningModel: String?
        var syncChatModelWithOracle: Bool?

        init(
            preferredComposeModel: String? = nil,
            planningModel: String? = nil,
            syncChatModelWithOracle: Bool? = nil
        ) {
            self.preferredComposeModel = preferredComposeModel
            self.planningModel = planningModel
            self.syncChatModelWithOracle = syncChatModelWithOracle
        }
    }

    struct MCPSettings: Codable, Equatable {
        var autoStart: Bool?
        var showModelPresets: Bool?
        var temporarilyDisablePresets: Bool?

        init(
            autoStart: Bool? = nil,
            showModelPresets: Bool? = nil,
            temporarilyDisablePresets: Bool? = nil
        ) {
            self.autoStart = autoStart
            self.showModelPresets = showModelPresets
            self.temporarilyDisablePresets = temporarilyDisablePresets
        }
    }

    struct FileSystemSettings: Codable, Equatable {
        var respectRepoIgnore: Bool?
        var respectCursorignore: Bool?
        var globalIgnoreDefaults: String?
        var enableHierarchicalIgnores: Bool?
        var skipSymlinks: Bool?
        var showEmptyFolders: Bool?

        init(
            respectRepoIgnore: Bool? = nil,
            respectCursorignore: Bool? = nil,
            globalIgnoreDefaults: String? = nil,
            enableHierarchicalIgnores: Bool? = nil,
            skipSymlinks: Bool? = nil,
            showEmptyFolders: Bool? = nil
        ) {
            self.respectRepoIgnore = respectRepoIgnore
            self.respectCursorignore = respectCursorignore
            self.globalIgnoreDefaults = globalIgnoreDefaults
            self.enableHierarchicalIgnores = enableHierarchicalIgnores
            self.skipSymlinks = skipSymlinks
            self.showEmptyFolders = showEmptyFolders
        }
    }

    struct ModelOverrideSettingsData: Codable, Equatable {
        var diffOverrides: [String: Bool]?
        var streamOverrides: [String: Bool]?
        var temperatureOverrides: [String: Double]?
        var responsesOverrides: [String: Bool]?

        init(
            diffOverrides: [String: Bool]? = nil,
            streamOverrides: [String: Bool]? = nil,
            temperatureOverrides: [String: Double]? = nil,
            responsesOverrides: [String: Bool]? = nil
        ) {
            self.diffOverrides = diffOverrides
            self.streamOverrides = streamOverrides
            self.temperatureOverrides = temperatureOverrides
            self.responsesOverrides = responsesOverrides
        }
    }

    struct AgentModeSettings: Codable, Equatable {
        var proEditAgentMode: Bool?
        var proEditAgentKind: String?
        var proEditAgentModel: String?
        var proEditAgentModeMigrated: Bool?
        // DEPRECATED: Auto-Expand Tool Cards was removed in 2026-04.
        // Kept temporarily for decode/rollback compatibility only; do not read from UI/runtime.
        var agentAutoExpandToolCards: Bool?
        var maxBackgroundAgentComposeTabs: Int?
        var showBuiltInWorkflowCleanupGuidance: Bool?
        var codexGoalSupportEnabled: Bool?
        var restrictMCPAgentDiscoveryToRoleLabels: Bool?

        init(
            proEditAgentMode: Bool? = nil,
            proEditAgentKind: String? = nil,
            proEditAgentModel: String? = nil,
            proEditAgentModeMigrated: Bool? = nil,
            agentAutoExpandToolCards: Bool? = nil,
            maxBackgroundAgentComposeTabs: Int? = nil,
            showBuiltInWorkflowCleanupGuidance: Bool? = nil,
            codexGoalSupportEnabled: Bool? = nil,
            restrictMCPAgentDiscoveryToRoleLabels: Bool? = nil
        ) {
            self.proEditAgentMode = proEditAgentMode
            self.proEditAgentKind = proEditAgentKind
            self.proEditAgentModel = proEditAgentModel
            self.proEditAgentModeMigrated = proEditAgentModeMigrated
            self.agentAutoExpandToolCards = agentAutoExpandToolCards
            self.maxBackgroundAgentComposeTabs = maxBackgroundAgentComposeTabs
            self.showBuiltInWorkflowCleanupGuidance = showBuiltInWorkflowCleanupGuidance
            self.codexGoalSupportEnabled = codexGoalSupportEnabled
            self.restrictMCPAgentDiscoveryToRoleLabels = restrictMCPAgentDiscoveryToRoleLabels
        }
    }
}
