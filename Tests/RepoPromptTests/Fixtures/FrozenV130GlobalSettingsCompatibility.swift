import Foundation

/// Test-only compatibility codec frozen from the released RepoPrompt CE v1.3.0
/// source at `b8042678fac558842ef4bc37027d0cd26246fdd6`, before commit
/// `0b4d738a276c6489dc998f04d83082b01b49c8af` introduced the global
/// `scalarPreferences.contextBuilder` group.
///
/// The scalar preference shape below is the released typed Codable shape. It intentionally
/// has no `contextBuilder` member: decoding a document with that key and saving it again is
/// the exact old-writer compatibility boundary under test. Opaque JSON values are used only
/// for unrelated root maps so this fixture stays focused on the old scalar codec.
struct FrozenV130GlobalSettingsDocument: Codable {
    static let supportedSchemaVersion = 4
    static let schemaLineage = "repoprompt-ce.global-settings"

    var schemaVersion: Int
    var schemaLineage: String?
    var updatedAt: Date
    var copySettingsByWorkspaceID: [String: FrozenV130JSONValue]
    var chatSettingsByWorkspaceID: [String: FrozenV130JSONValue]
    var agentModelsSettingsByWorkspaceID: [String: FrozenV130JSONValue]?
    var globalDefaults: FrozenV130JSONValue
    var scalarPreferences: FrozenV130GlobalScalarPreferences?

    static func load(from url: URL) throws -> Self {
        let document = try decoder.decode(Self.self, from: Data(contentsOf: url))
        if document.schemaLineage == Self.schemaLineage,
           document.schemaVersion > Self.supportedSchemaVersion
        {
            throw CompatibilityError.unsupportedFutureSchema(document.schemaVersion)
        }
        return document
    }

    var requiredSchemaVersion: Int {
        guard let agentModelsSettingsByWorkspaceID,
              !agentModelsSettingsByWorkspaceID.isEmpty
        else {
            return 2
        }
        return 4
    }

    mutating func save(to url: URL, now: Date) throws {
        schemaVersion = requiredSchemaVersion
        schemaLineage = Self.schemaLineage
        updatedAt = now
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    enum CompatibilityError: Error, Equatable {
        case unsupportedFutureSchema(Int)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

struct FrozenV130GlobalScalarPreferences: Codable {
    var ui: UISettings?
    var promptPackaging: PromptPackagingSettings?
    var modelSelection: ModelSelectionSettings?
    var mcp: MCPSettings?
    var fileSystem: FileSystemSettings?
    var agentMode: AgentModeSettings?
    var telemetry: TelemetrySettings?
    var modelOverrides: ModelOverrideSettingsData?

    struct UISettings: Codable {
        var appearanceMode: String?
        var useTransparency: Bool?
        var collapseLatestFileChanges: Bool?
        var showTooltips: Bool?
        var experimentalAttributedTextEditor: Bool?
        var fileMentionPickerStyle: String?
        var enableKeyboardShortcuts: Bool?
        var fontScaleBodySize: Double?
        var showDatesInMessageTimestamps: Bool?
    }

    struct PromptPackagingSettings: Codable {
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
    }

    struct ModelSelectionSettings: Codable {
        var preferredComposeModel: String?
        var planningModel: String?
        var syncChatModelWithOracle: Bool?
    }

    struct MCPSettings: Codable {
        var autoStart: Bool?
        var showModelPresets: Bool?
        var temporarilyDisablePresets: Bool?
    }

    struct FileSystemSettings: Codable {
        var respectRepoIgnore: Bool?
        var respectCursorignore: Bool?
        var globalIgnoreDefaults: String?
        var enableHierarchicalIgnores: Bool?
        var skipSymlinks: Bool?
        var showEmptyFolders: Bool?
    }

    struct TelemetrySettings: Codable {
        var enabled: Bool?
        var appHangReportsEnabled: Bool?
        var performanceTracingEnabled: Bool?
    }

    struct ModelOverrideSettingsData: Codable {
        var diffOverrides: [String: Bool]?
        var streamOverrides: [String: Bool]?
        var temperatureOverrides: [String: Double]?
        var responsesOverrides: [String: Bool]?
    }

    struct AgentModeSettings: Codable {
        var proEditAgentMode: Bool?
        var proEditAgentKind: String?
        var proEditAgentModel: String?
        var proEditAgentModeMigrated: Bool?
        var agentAutoExpandToolCards: Bool?
        var maxBackgroundAgentComposeTabs: Int?
        var showBuiltInWorkflowCleanupGuidance: Bool?
        var codexGoalSupportEnabled: Bool?
        var codexReasoningSummariesEnabled: Bool?
        var codexMemoriesEnabled: Bool?
        var providerConversationCleanupAction: String?
        var restrictMCPAgentDiscoveryToRoleLabels: Bool?
        var agentSessionHandoffInstructions: String?
    }
}

indirect enum FrozenV130JSONValue: Codable {
    case object([String: Self])
    case array([Self])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    var objectValue: [String: Self]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = try .string(container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
