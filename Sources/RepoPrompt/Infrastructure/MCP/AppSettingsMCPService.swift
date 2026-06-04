import Foundation
import JSONSchema
import MCP

/// Global, non-window-scoped MCP service for allowlisted RepoPrompt app settings.
///
/// This service intentionally does not expose the raw global settings document. Only
/// keys present in `AppSettingsMCPRegistry.definitions` are visible to MCP clients.
final class AppSettingsMCPService: Service {
    static let toolName = "app_settings"

    private let store: GlobalSettingsStore
    private let notificationCenter: NotificationCenter

    @MainActor
    init(
        store: GlobalSettingsStore? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store ?? GlobalSettingsStore.shared
        self.notificationCenter = notificationCenter
    }

    var tools: [Tool] {
        get async {
            #if DEBUG || EDIT_FLOW_PERF
                let appSettingsToolsBuildState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupAppSettingsToolsBuild)
                defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupAppSettingsToolsBuild, appSettingsToolsBuildState) }
            #endif
            return makeTools()
        }
    }

    private func makeTools() -> [Tool] {
        [
            Tool(
                name: Self.toolName,
                description: """
                Read/update allowlisted RepoPrompt app-wide preferences. Settings outside the allowlist are not exposed.

                **Operations**: `list` (catalog), `get` (read), `set` (write one key), `options` (candidate values for keys with `options_available: true`).

                **Selectors**: `get` accepts exactly one of `key`, `keys`, or `group`. `set` and `options` take one `key`.

                **Groups**: `ui` · `prompt_packaging` · `models` · `context_builder` · `mcp` · `code_maps` · `file_system` · `agent_mode`

                **Examples**:
                - `{"op":"list","group":"ui"}`
                - `{"op":"get","keys":["ui.appearance_mode","ui.show_tooltips"]}`
                - `{"op":"get","group":"file_system"}`
                - `{"op":"set","key":"models.planning_model","value":null}`
                - `{"op":"set","key":"file_system.respect_gitignore","value":false}`
                - `{"op":"set","key":"file_system.global_ignore_defaults","value":"**/node_modules/\\n"}`
                - `{"op":"options","key":"models.planning_model","agent":"codexExec"}`

                Invalid or out-of-range values are rejected with no partial apply. Model-raw settings accept custom identifiers beyond what `options` returns.
                """,
                inputSchema: .object(
                    properties: [
                        "op": .string(description: "Operation.", enum: ["list", "get", "set", "options"]),
                        "group": .string(description: "Settings group.", enum: ["ui", "prompt_packaging", "models", "context_builder", "mcp", "code_maps", "file_system", "agent_mode"]),
                        "key": .string(description: "Allowlisted setting key (required for set/options)."),
                        "keys": .array(description: "Multiple keys (get only).", items: .string()),
                        "value": .anyOf([.boolean(), .integer(), .number(), .string(), .null]),
                        "agent": .string(description: "Filter options by CLI backend."),
                        "limit": .integer(description: "Maximum options returned (1–200)."),
                        "detailed": .boolean(description: "Include descriptions and model metadata.")
                    ],
                    required: ["op"]
                ),
                annotations: .repoPromptLocalPersistentSettings,
                returnsValue: { [weak self] args in
                    guard let self else {
                        throw MCPError.internalError("App settings service unavailable")
                    }
                    return try await handle(args)
                }
            )
        ]
    }

    private func handle(_ args: [String: Value]) async throws -> Value {
        guard let rawOp = args["op"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let op = AppSettingsOperation(rawValue: rawOp)
        else {
            throw MCPError.invalidParams("app_settings requires op='list', 'get', 'set', or 'options'.")
        }

        switch op {
        case .list:
            return try await list(args)
        case .get:
            return try await get(args)
        case .set:
            return try await set(args)
        case .options:
            return try await options(args)
        }
    }

    private func list(_ args: [String: Value]) async throws -> Value {
        let group = try parseOptionalString(args["group"], parameter: "group")
        let detailed = try parseOptionalBool(args["detailed"], parameter: "detailed") ?? true
        let definitions = try AppSettingsMCPRegistry.definitions(inGroup: group)

        let settings: [Value] = await MainActor.run {
            definitions.map { definition in
                definition.catalogValue(readingFrom: store, detailed: detailed)
            }
        }

        return .object([
            "op": .string("list"),
            "status": .string("ok"),
            "read_only": .bool(false),
            "supports_set": .bool(true),
            "detailed": .bool(detailed),
            "groups": .array(AppSettingsMCPRegistry.groups.map(Value.string)),
            "settings": .array(settings),
            "count": .int(settings.count)
        ])
    }

    private func get(_ args: [String: Value]) async throws -> Value {
        let key = try parseOptionalString(args["key"], parameter: "key")
        let keys = try parseOptionalStringArray(args["keys"], parameter: "keys")
        let group = try parseOptionalString(args["group"], parameter: "group")

        let selectorCount = (key == nil ? 0 : 1) + (keys == nil ? 0 : 1) + (group == nil ? 0 : 1)
        guard selectorCount == 1 else {
            throw MCPError.invalidParams("app_settings op='get' requires exactly one selector: key, keys, or group.")
        }

        let definitions: [AppSettingDefinition]
        if let key {
            definitions = try [AppSettingsMCPRegistry.definition(forKey: key)]
        } else if let keys {
            guard !keys.isEmpty else {
                throw MCPError.invalidParams("app_settings op='get' requires keys to be a non-empty array.")
            }
            definitions = try keys.map { try AppSettingsMCPRegistry.definition(forKey: $0) }
        } else {
            definitions = try AppSettingsMCPRegistry.definitions(inGroup: group)
        }

        let values = await MainActor.run {
            definitions.reduce(into: [String: Value]()) { result, definition in
                result[definition.key] = definition.read(store)
            }
        }

        return .object([
            "op": .string("get"),
            "status": .string("ok"),
            "values": .object(values),
            "count": .int(values.count)
        ])
    }

    private func set(_ args: [String: Value]) async throws -> Value {
        guard args["keys"] == nil, args["group"] == nil else {
            throw MCPError.invalidParams("app_settings op='set' accepts exactly one 'key'; do not pass keys or group.")
        }
        guard let key = try parseOptionalString(args["key"], parameter: "key") else {
            throw MCPError.invalidParams("app_settings op='set' requires a non-empty 'key'.")
        }
        guard let rawValue = args["value"] else {
            throw MCPError.invalidParams("app_settings op='set' requires 'value'.")
        }

        let definition = try AppSettingsMCPRegistry.definition(forKey: key)
        let normalizedValue = try definition.validate(rawValue)

        let result = try await MainActor.run { () throws -> (oldValue: Value, newValue: Value, changed: Bool, applied: Bool) in
            let oldValue = definition.read(store)
            let changed = !Self.valuesEqual(oldValue, normalizedValue)
            if changed {
                try definition.write(store, normalizedValue)
                definition.afterWrite?(store, normalizedValue, notificationCenter)
            }
            let newValue = definition.read(store)
            definition.afterSet?(store, newValue, changed, notificationCenter)
            return (oldValue, newValue, changed, changed)
        }

        return .object([
            "op": .string("set"),
            "status": .string("ok"),
            "key": .string(definition.key),
            "old_value": result.oldValue,
            "new_value": result.newValue,
            "changed": .bool(result.changed),
            "applied": .bool(result.applied)
        ])
    }

    private func options(_ args: [String: Value]) async throws -> Value {
        // op=options accepts exactly one `key`. Reject list/get-style selectors and write fields.
        guard args["keys"] == nil else {
            throw MCPError.invalidParams("app_settings op='options' does not accept 'keys'; pass exactly one 'key'.")
        }
        guard args["group"] == nil else {
            throw MCPError.invalidParams("app_settings op='options' does not accept 'group'; pass exactly one 'key'.")
        }
        guard args["value"] == nil else {
            throw MCPError.invalidParams("app_settings op='options' does not accept 'value'.")
        }

        guard let key = try parseOptionalString(args["key"], parameter: "key") else {
            throw MCPError.invalidParams("app_settings op='options' requires a non-empty 'key'.")
        }

        let definition = try AppSettingsMCPRegistry.definition(forKey: key)
        guard let candidateProvider = definition.candidateProvider else {
            throw MCPError.invalidParams("Setting '\(definition.key)' does not advertise candidate options. Use app_settings op='list' to find keys with options_available=true.")
        }

        let requestedAgent = try parseOptionalAgent(args["agent"], parameter: "agent")
        let agent: AgentProviderKind? = if let requestedAgent {
            requestedAgent
        } else if let resolver = definition.defaultOptionsAgent {
            await MainActor.run { resolver(store) }
        } else {
            nil
        }
        let detailed = try parseOptionalBool(args["detailed"], parameter: "detailed") ?? true
        let requestedLimit = try parseOptionalInt(args["limit"], parameter: "limit")
        let limit: Int
        if let requestedLimit {
            guard requestedLimit >= 1 else {
                throw MCPError.invalidParams("app_settings op='options' requires limit >= 1.")
            }
            guard requestedLimit <= 200 else {
                throw MCPError.invalidParams("app_settings op='options' requires limit <= 200.")
            }
            limit = requestedLimit
        } else {
            limit = 60
        }

        let request = AppSettingCandidateRequest(
            key: definition.key,
            agentFilter: agent,
            detailed: detailed,
            limit: limit,
            availability: .current
        )

        let result = try await MainActor.run { () throws -> AppSettingCandidatesResult in
            try candidateProvider(request)
        }

        var envelope: [String: Value] = [
            "op": .string("options"),
            "status": .string("ok"),
            "key": .string(definition.key),
            "type": .string(definition.valueType.rawValue),
            "source": .string(result.source),
            "generated_at": .string(Self.iso8601Timestamp()),
            "detailed": .bool(detailed),
            "nullable": .bool(definition.valueType == .optionalString),
            "exhaustive": .bool(result.exhaustive),
            "limit": .int(limit),
            "count": .int(result.options.count),
            "total_count": .int(result.totalCount),
            "truncated": .bool(result.truncated),
            "options": .array(result.options.map { $0.toValue(detailed: detailed) })
        ]
        if definition.valueType == .optionalString {
            envelope["clear_value"] = .null
        }
        var filters: [String: Value] = [:]
        if let agent {
            filters["agent"] = .string(agent.rawValue)
        }
        if !filters.isEmpty {
            envelope["filters"] = .object(filters)
        }
        if !result.notes.isEmpty {
            envelope["notes"] = .array(result.notes.map(Value.string))
        }
        return .object(envelope)
    }

    private static func iso8601Timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private static func valuesEqual(_ lhs: Value, _ rhs: Value) -> Bool {
        ToolOutputFormatter.rawJSONString(lhs) == ToolOutputFormatter.rawJSONString(rhs)
    }

    private func parseOptionalString(_ value: Value?, parameter: String) throws -> String? {
        guard let value else { return nil }
        guard let raw = value.stringValue else {
            throw MCPError.invalidParams("app_settings parameter '\(parameter)' must be a string.")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseOptionalBool(_ value: Value?, parameter: String) throws -> Bool? {
        guard let value else { return nil }
        guard case let .bool(bool) = value else {
            throw MCPError.invalidParams("app_settings parameter '\(parameter)' must be a boolean.")
        }
        return bool
    }

    private func parseOptionalInt(_ value: Value?, parameter: String) throws -> Int? {
        guard let value else { return nil }
        switch value {
        case let .int(int):
            return int
        case let .double(double):
            guard let int = Int(exactly: double) else {
                throw MCPError.invalidParams("app_settings parameter '\(parameter)' must be a whole integer value.")
            }
            return int
        case let .string(raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let int = Int(trimmed) else {
                throw MCPError.invalidParams("app_settings parameter '\(parameter)' must be an integer value.")
            }
            return int
        default:
            throw MCPError.invalidParams("app_settings parameter '\(parameter)' must be an integer value.")
        }
    }

    private func parseOptionalAgent(_ value: Value?, parameter: String) throws -> AgentProviderKind? {
        guard let trimmed = try parseOptionalString(value, parameter: parameter) else { return nil }
        if let match = AgentProviderKind(rawValue: trimmed) {
            return match
        }
        let loweredTarget = trimmed.lowercased()
        if let match = AgentProviderKind.allCases.first(where: { $0.rawValue.lowercased() == loweredTarget }) {
            return match
        }
        let allowed = AgentProviderKind.allCases.map(\.rawValue).joined(separator: ", ")
        throw MCPError.invalidParams("app_settings parameter '\(parameter)' must be one of: \(allowed).")
    }

    private func parseOptionalStringArray(_ value: Value?, parameter: String) throws -> [String]? {
        guard let value else { return nil }
        guard let array = value.arrayValue else {
            throw MCPError.invalidParams("app_settings parameter '\(parameter)' must be an array of strings.")
        }
        var result: [String] = []
        result.reserveCapacity(array.count)
        for item in array {
            guard let raw = item.stringValue else {
                throw MCPError.invalidParams("app_settings parameter '\(parameter)' must contain only strings.")
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MCPError.invalidParams("app_settings parameter '\(parameter)' must not contain empty keys.")
            }
            result.append(trimmed)
        }
        return result
    }
}

private enum AppSettingsOperation: String {
    case list
    case get
    case set
    case options
}

private enum AppSettingValueType: String {
    case boolean
    case string
    case optionalString = "string|null"
    case number
}

private struct AppSettingCandidateRequest {
    let key: String
    let agentFilter: AgentProviderKind?
    let detailed: Bool
    let limit: Int
    let availability: AgentModelCatalog.AvailabilityContext
}

private struct AppSettingCandidate {
    let value: Value
    let label: String?
    let description: String?
    let group: String?
    let groupLabel: String?
    let attributes: [String: Value]

    /// Reserved top-level fields in a candidate envelope. Provider-supplied attributes
    /// must not clobber these — they are owned by this renderer.
    private static let reservedTopLevelKeys: Set<String> = [
        "value", "label", "group", "group_label", "description"
    ]

    func toValue(detailed: Bool) -> Value {
        var object: [String: Value] = [:]
        object["value"] = value
        if let label, !label.isEmpty {
            object["label"] = .string(label)
        }
        if let group, !group.isEmpty {
            object["group"] = .string(group)
        }
        if let groupLabel, !groupLabel.isEmpty {
            object["group_label"] = .string(groupLabel)
        }
        for (key, value) in attributes where !Self.reservedTopLevelKeys.contains(key) {
            object[key] = value
        }
        if detailed, let description, !description.isEmpty {
            object["description"] = .string(description)
        }
        return .object(object)
    }
}

private struct AppSettingCandidatesResult {
    let source: String
    let exhaustive: Bool
    let totalCount: Int
    let options: [AppSettingCandidate]
    let truncated: Bool
    let notes: [String]
}

private struct AppSettingDefinition: @unchecked Sendable {
    let key: String
    let group: String
    let valueType: AppSettingValueType
    let label: String?
    let description: String
    let allowedValues: [String]?
    let valueFormat: String?
    let allowedItems: [String]?
    let read: @MainActor (GlobalSettingsStore) -> Value
    let validate: (Value) throws -> Value
    let write: @MainActor (GlobalSettingsStore, Value) throws -> Void
    let afterWrite: (@MainActor (GlobalSettingsStore, Value, NotificationCenter) -> Void)?
    let afterSet: (@MainActor (GlobalSettingsStore, Value, Bool, NotificationCenter) -> Void)?
    let candidateProvider: (@MainActor (AppSettingCandidateRequest) throws -> AppSettingCandidatesResult)?
    /// Optional resolver used by `op=options` to pick a default agent filter when the
    /// caller omits `agent=`. Only settings that opt in (currently `context_builder.model`)
    /// scope their default candidates to a specific backend; other model settings
    /// continue to return candidates across all available backends.
    let defaultOptionsAgent: (@MainActor (GlobalSettingsStore) -> AgentProviderKind?)?

    init(
        key: String,
        group: String,
        valueType: AppSettingValueType,
        label: String? = nil,
        description: String,
        allowedValues: [String]?,
        valueFormat: String? = nil,
        allowedItems: [String]? = nil,
        read: @escaping @MainActor (GlobalSettingsStore) -> Value,
        validate: @escaping (Value) throws -> Value,
        write: @escaping @MainActor (GlobalSettingsStore, Value) throws -> Void,
        afterWrite: (@MainActor (GlobalSettingsStore, Value, NotificationCenter) -> Void)?,
        afterSet: (@MainActor (GlobalSettingsStore, Value, Bool, NotificationCenter) -> Void)? = nil,
        candidateProvider: (@MainActor (AppSettingCandidateRequest) throws -> AppSettingCandidatesResult)? = nil,
        defaultOptionsAgent: (@MainActor (GlobalSettingsStore) -> AgentProviderKind?)? = nil
    ) {
        self.key = key
        self.group = group
        self.valueType = valueType
        self.label = label
        self.description = description
        self.allowedValues = allowedValues
        self.valueFormat = valueFormat
        self.allowedItems = allowedItems
        self.read = read
        self.validate = validate
        self.write = write
        self.afterWrite = afterWrite
        self.afterSet = afterSet
        self.candidateProvider = candidateProvider
        self.defaultOptionsAgent = defaultOptionsAgent
    }

    func catalogValue(value: Value? = nil, detailed: Bool = true) -> Value {
        var object: [String: Value] = [
            "key": .string(key),
            "group": .string(group),
            "type": .string(valueType.rawValue)
        ]
        if detailed {
            object["description"] = .string(description)
            object["writable"] = .bool(true)
            if let label, !label.isEmpty {
                object["label"] = .string(label)
            }
            if let allowedValues {
                object["allowed_values"] = .array(allowedValues.map(Value.string))
            }
            if let valueFormat {
                object["value_format"] = .string(valueFormat)
            }
            if let allowedItems {
                object["allowed_items"] = .array(allowedItems.map(Value.string))
            }
        }
        if candidateProvider != nil {
            object["options_available"] = .bool(true)
        }
        if let value {
            object["value"] = value
        }
        return .object(object)
    }

    @MainActor
    func catalogValue(readingFrom store: GlobalSettingsStore, detailed: Bool = true) -> Value {
        catalogValue(value: read(store), detailed: detailed)
    }
}

private enum AppSettingsMCPRegistry {
    static let groups = ["ui", "prompt_packaging", "models", "context_builder", "mcp", "code_maps", "file_system", "agent_mode"]

    private static let appearanceModes = ["System", "Light", "Dark"]
    private static let filePathDisplayOptions = ["Full", "Relative"]
    private static let selectedFilesSortMethods = ["nameAscending", "nameDescending", "tokenAscending", "tokenDescending"]
    private static let modelRawMaxLength = 512
    private static let freeformStringMaxLength = 20000
    private static let globalIgnoreDefaultsMaxLength = 20000
    private static let promptSectionsOrderMaxLength = 10000
    private static let debugDefaultsStringMaxLength = 4096

    static let definitions: [AppSettingDefinition] = [
        // UI settings — user-facing app chrome only. Experimental/internal
        // flags and no-op legacy toggles (ui.use_transparency,
        // ui.collapse_latest_file_changes, ui.experimental_attributed_text_editor)
        // are intentionally omitted from the MCP surface.
        stringEnumSetting(
            key: "ui.appearance_mode",
            group: "ui",
            description: "App appearance mode.",
            allowedValues: appearanceModes,
            read: { .string($0.appearanceModeRaw()) },
            write: { store, value in try store.setAppearanceModeRaw(requiredString(from: value)) },
            afterWrite: { _, value, _ in
                if let raw = value.stringValue {
                    AppearanceController.shared.apply(modeRawValue: raw)
                }
            }
        ),
        boolSetting(
            key: "ui.show_tooltips",
            group: "ui",
            description: "Whether RepoPrompt shows app tooltips.",
            read: { .bool($0.showTooltips()) },
            write: { try $0.setShowTooltips(requiredBool(from: $1)) }
        ),
        boolSetting(
            key: "ui.enable_keyboard_shortcuts",
            group: "ui",
            description: "Whether global keyboard shortcuts are enabled. New/changed shortcuts may only take effect after reopening a window.",
            read: { .bool($0.enableKeyboardShortcuts()) },
            write: { try $0.setEnableKeyboardShortcuts(requiredBool(from: $1)) }
        ),
        AppSettingDefinition(
            key: "ui.font_scale",
            group: "ui",
            valueType: .number,
            label: "Font Scale",
            description: "App-wide UI font scale preset body size.",
            allowedValues: FontScalePreset.allCases.map { String(format: "%.0f", $0.rawValue) },
            read: { .double($0.fontScaleBodySize()) },
            validate: validateFontScaleRawValue,
            write: { store, value in try store.setFontScaleBodySize(requiredDouble(from: value)) },
            afterWrite: nil,
            afterSet: reconcileFontScaleAfterSet,
            candidateProvider: fontScaleCandidates
        ),

        // Prompt-packaging settings — how RepoPrompt assembles and formats
        // the packaged prompt. Model/inference settings live in the
        // `models` group.
        AppSettingDefinition(
            key: "prompt_packaging.prompt_sections_order",
            group: "prompt_packaging",
            valueType: .string,
            description: "Serialized prompt section ordering used when packaging prompts.",
            allowedValues: nil,
            valueFormat: "JSON string array containing each prompt section exactly once.",
            allowedItems: PromptSection.allCases.map(\.rawValue),
            read: { .string($0.promptSectionsOrderRaw()) },
            validate: validatePromptSectionsOrder,
            write: { store, value in try store.setPromptSectionsOrderRaw(requiredString(from: value)) },
            afterWrite: nil
        ),
        boolSetting(
            key: "prompt_packaging.duplicate_user_instructions_at_top",
            group: "prompt_packaging",
            description: "Whether user instructions are duplicated at the top of packaged prompts.",
            read: { .bool($0.duplicateUserInstructionsAtTop()) },
            write: { try $0.setDuplicateUserInstructionsAtTop(requiredBool(from: $1)) }
        ),
        stringEnumSetting(
            key: "prompt_packaging.file_path_display_option",
            group: "prompt_packaging",
            description: "How file paths are displayed in packaged context.",
            allowedValues: filePathDisplayOptions,
            read: { .string($0.filePathDisplayOptionRaw()) },
            write: { try $0.setFilePathDisplayOptionRaw(requiredString(from: $1)) }
        ),
        stringEnumSetting(
            key: "prompt_packaging.selected_files_sort_method",
            group: "prompt_packaging",
            description: "Sort method for selected files.",
            allowedValues: selectedFilesSortMethods,
            read: { .string($0.selectedFilesSortMethodRaw()) },
            write: { try $0.setSelectedFilesSortMethodRaw(requiredString(from: $1)) }
        ),
        boolSetting(
            key: "prompt_packaging.include_datetime_in_user_instructions",
            group: "prompt_packaging",
            description: "Whether packaged user instructions include the current date/time.",
            read: { .bool($0.includeDatetimeInUserInstructions()) },
            write: { try $0.setIncludeDatetimeInUserInstructions(requiredBool(from: $1)) }
        ),

        // Model / AI behavior — model selection plus default inference
        // parameters and the planning-agent system prompt.
        optionalModelRawSetting(
            key: "models.preferred_compose_model",
            group: "models",
            label: "Built-in Chat Model",
            description: "Preferred Built-in Chat model raw identifier, if set.",
            read: { stringOrNull($0.preferredComposeModelRaw()) },
            write: { try $0.setPreferredComposeModelRaw(
                optionalString(from: $1),
                reason: "app_settings.models.preferred_compose_model"
            ) },
            afterWrite: { store, value, notificationCenter in
                postModelRawDidWrite(
                    store: store,
                    siblingKey: "models.planning_model",
                    valueJustWritten: value,
                    notificationCenter: notificationCenter
                )
            },
            candidateProvider: aiModelRawCandidates
        ),
        optionalModelRawSetting(
            key: "models.planning_model",
            group: "models",
            label: "Oracle Model",
            description: "Preferred Oracle model raw identifier, if set.",
            read: { stringOrNull($0.planningModelRaw()) },
            write: { try $0.setPlanningModelRaw(
                optionalString(from: $1),
                reason: "app_settings.models.planning_model"
            ) },
            afterWrite: { store, value, notificationCenter in
                postModelRawDidWrite(
                    store: store,
                    siblingKey: "models.preferred_compose_model",
                    valueJustWritten: value,
                    notificationCenter: notificationCenter
                )
            },
            candidateProvider: aiModelRawCandidates
        ),
        boolSetting(
            key: "models.sync_chat_model_with_oracle",
            group: "models",
            label: "Sync Built-in Chat with Oracle",
            description: "Whether the Built-in Chat model is kept in sync with the Oracle model.",
            read: { .bool($0.syncChatModelWithOracle()) },
            write: {
                try $0.setSyncChatModelWithOracle(
                    requiredBool(from: $1),
                    reason: "app_settings.models.sync_chat_model_with_oracle",
                    snapOnEnableToPlanning: true
                )
            },
            afterWrite: postRecommendationsDidApply
        ),
        numberSetting(
            key: "models.temperature",
            group: "models",
            description: "Global default model temperature (only applied when models.temperature_enabled is true).",
            range: 0.0 ... 2.0,
            read: { .double($0.modelTemperature()) },
            write: { try $0.setModelTemperature(requiredDouble(from: $1)) }
        ),
        boolSetting(
            key: "models.temperature_enabled",
            group: "models",
            description: "Whether the global models.temperature value is sent with model requests.",
            read: { .bool($0.shouldSetModelTemperature()) },
            write: { try $0.setShouldSetModelTemperature(requiredBool(from: $1)) }
        ),
        freeformStringSetting(
            key: "models.custom_planning_prompt",
            group: "models",
            label: "Custom Oracle System Prompt",
            description: "Custom system prompt used by the Oracle. Empty string restores the built-in default.",
            maxLength: freeformStringMaxLength,
            read: { .string($0.customPlanningPrompt()) },
            write: { try $0.setCustomPlanningPrompt(requiredString(from: $1)) }
        ),

        // Context Builder agent/model selection. Uses the legacy persisted
        // discover-agent slot only; workspace-scoped context builder fields are
        // intentionally not exposed here.
        stringEnumSetting(
            key: "context_builder.agent",
            group: "context_builder",
            description: "CLI agent used by the Context Builder MCP tool.",
            allowedValues: AgentProviderKind.allCases.map(\.rawValue),
            read: { .string($0.globalContextBuilderAgentSelection().agentRaw ?? AgentProviderKind.claudeCode.rawValue) },
            write: { store, value in
                let agentRaw = try requiredString(from: value)
                let kind = AgentProviderKind(rawValue: agentRaw) ?? .claudeCode
                let rememberedModelRaw = store.globalContextBuilderRememberedModelRaw(for: kind.rawValue)
                let modelRaw = rememberedModelRaw ?? AgentModelCatalog.defaultModelRaw(for: kind)
                store.setGlobalContextBuilderAgentSelection(
                    agentRaw: kind.rawValue,
                    modelRaw: modelRaw,
                    markUserDefined: true,
                    reason: "app_settings.context_builder.agent"
                )
            },
            afterWrite: postRecommendationsDidApply
        ),
        optionalModelRawSetting(
            key: "context_builder.model",
            group: "context_builder",
            description: "Model raw identifier used by the Context Builder MCP tool.",
            read: { store in
                let agentRaw = store.globalContextBuilderAgentSelection().agentRaw
                return stringOrNull(agentRaw.flatMap { store.globalContextBuilderRememberedModelRaw(for: $0) })
            },
            write: { store, value in
                let currentAgentRaw = store.globalContextBuilderAgentSelection().agentRaw ?? AgentProviderKind.claudeCode.rawValue
                try store.setGlobalContextBuilderAgentSelection(
                    agentRaw: currentAgentRaw,
                    modelRaw: optionalString(from: value),
                    markUserDefined: true,
                    reason: "app_settings.context_builder.model"
                )
            },
            afterWrite: postRecommendationsDidApply,
            candidateProvider: agentModelRawCandidates,
            defaultOptionsAgent: { store in
                store.globalContextBuilderAgentSelection().agentRaw.flatMap(AgentProviderKind.init(rawValue:))
            }
        ),

        // General MCP preferences (not MCP tool ACLs or server lifecycle
        // controls). The internal recommendation-dismissal flag
        // `mcpTemporarilyDisablePresets` is intentionally omitted because it
        // is not a durable user preference.
        boolSetting(
            key: "mcp.show_model_presets",
            group: "mcp",
            description: "Whether MCP model preset recommendations are shown.",
            read: { .bool($0.mcpShowModelPresets()) },
            write: { try $0.setMCPShowModelPresets(requiredBool(from: $1)) },
            afterWrite: postRecommendationsDidApply
        ),

        // Global Code Maps toggle.
        boolSetting(
            key: "code_maps.globally_disabled",
            group: "code_maps",
            description: "Whether Code Maps are globally disabled. Disabling also suppresses the MCP get_code_structure tool.",
            read: { .bool($0.globalCodeMapsDisabled()) },
            write: { try $0.setCodeMapsGloballyDisabled(requiredBool(from: $1)) }
        ),

        // Agent Mode behavior. This exposes durable prompt-shaping preferences only;
        // internal provider/runtime toggles remain omitted.
        boolSetting(
            key: "agent_mode.show_built_in_workflow_cleanup_guidance",
            group: "agent_mode",
            description: "Whether built-in Agent Mode workflow prompts include optional housekeeping guidance about dismissing completed agent sessions. Applies only to built-in workflows selected in Agent Mode or via agent_run workflow_id/workflow_name; it does not affect custom workflows or external slash skills.",
            read: { .bool($0.showBuiltInWorkflowCleanupGuidance()) },
            write: { try $0.setShowBuiltInWorkflowCleanupGuidance(requiredBool(from: $1)) }
        ),
        boolSetting(
            key: "agent_mode.codex_goal_support_enabled",
            group: "agent_mode",
            label: "Codex Goal Support",
            description: "Default-on toggle for Codex /goal support. Turn off to prevent RepoPrompt from passing features.goals=true to Codex app-server launch and thread start/resume config.",
            read: { .bool($0.codexGoalSupportEnabled()) },
            write: { try $0.setCodexGoalSupportEnabled(requiredBool(from: $1)) }
        ),

        // File-system / ignore preferences. Local .repo_ignore file content remains
        // repository content; this group exposes app-wide scalar behavior only.
        boolSetting(
            key: "file_system.respect_gitignore",
            group: "file_system",
            description: "Whether RepoPrompt honors .gitignore files while scanning workspace folders.",
            read: { .bool($0.respectGitignore()) },
            write: { try $0.setRespectGitignore(requiredBool(from: $1)) },
            afterWrite: fileSystemPreferencesDidChangeHook(key: "file_system.respect_gitignore")
        ),
        boolSetting(
            key: "file_system.respect_repo_ignore",
            group: "file_system",
            description: "Whether RepoPrompt honors RepoPrompt-specific .repo_ignore files. This controls use of those files; edit local .repo_ignore content through file editing tools.",
            read: { .bool($0.respectRepoIgnore()) },
            write: { try $0.setRespectRepoIgnore(requiredBool(from: $1)) },
            afterWrite: fileSystemPreferencesDidChangeHook(key: "file_system.respect_repo_ignore")
        ),
        boolSetting(
            key: "file_system.respect_cursorignore",
            group: "file_system",
            description: "Whether RepoPrompt honors .cursorignore files while scanning workspace folders.",
            read: { .bool($0.respectCursorignore()) },
            write: { try $0.setRespectCursorignore(requiredBool(from: $1)) },
            afterWrite: fileSystemPreferencesDidChangeHook(key: "file_system.respect_cursorignore")
        ),
        rawTextSetting(
            key: "file_system.global_ignore_defaults",
            group: "file_system",
            description: "App-wide gitignore-style patterns applied to every workspace before local .repo_ignore rules. Empty string disables app-wide default ignore patterns.",
            maxLength: globalIgnoreDefaultsMaxLength,
            allowEmpty: true,
            read: { .string($0.globalIgnoreDefaults()) },
            write: { try $0.setGlobalIgnoreDefaults(requiredString(from: $1)) },
            afterWrite: fileSystemPreferencesDidChangeHook(key: "file_system.global_ignore_defaults")
        ),
        boolSetting(
            key: "file_system.enable_hierarchical_ignores",
            group: "file_system",
            description: "Whether ignore files in nested directories are honored.",
            read: { .bool($0.enableHierarchicalIgnores()) },
            write: { try $0.setEnableHierarchicalIgnores(requiredBool(from: $1)) },
            afterWrite: fileSystemPreferencesDidChangeHook(key: "file_system.enable_hierarchical_ignores")
        ),
        boolSetting(
            key: "file_system.skip_symlinks",
            group: "file_system",
            description: "Whether symbolic links are skipped while scanning folders.",
            read: { .bool($0.skipSymlinks()) },
            write: { try $0.setSkipSymlinks(requiredBool(from: $1)) },
            afterWrite: fileSystemPreferencesDidChangeHook(key: "file_system.skip_symlinks")
        ),
        boolSetting(
            key: "file_system.show_empty_folders",
            group: "file_system",
            description: "Whether empty folders are shown in the file tree.",
            read: { .bool($0.showEmptyFolders()) },
            write: { try $0.setShowEmptyFolders(requiredBool(from: $1)) },
            afterWrite: fileSystemPreferencesDidChangeHook(key: "file_system.show_empty_folders")
        )
    ] + debugDefinitions

    #if DEBUG
        private static let debugDefinitions: [AppSettingDefinition] = [
            boolSetting(
                key: "agent_mode.claude_raw_event_logging_enabled",
                group: "agent_mode",
                label: "Claude Raw Event Logging",
                description: "DEBUG-only opt-in toggle for raw Claude Code event JSONL capture. Disabled by default; when enabled without a directory override, logs use a non-workspace temp debug directory. Writes UserDefaults key 'claudeRawEventLoggingEnabled'.",
                read: { .bool($0.claudeRawEventLoggingEnabled()) },
                write: { try $0.setClaudeRawEventLoggingEnabled(requiredBool(from: $1)) }
            ),
            rawTextSetting(
                key: "agent_mode.claude_raw_event_log_file_path",
                group: "agent_mode",
                label: "Claude Raw Event Log Directory",
                description: "DEBUG-only directory override for raw Claude Code event JSONL files. Empty string clears the override; enabled logging then writes to a non-workspace temp debug directory. Writes UserDefaults key 'claudeRawEventLogFilePath'.",
                maxLength: debugDefaultsStringMaxLength,
                allowEmpty: true,
                read: { .string($0.claudeRawEventLogFilePath()) },
                write: { try $0.setClaudeRawEventLogFilePath(requiredString(from: $1)) }
            ),
            boolSetting(
                key: "agent_mode.perf_diagnostics_enabled",
                group: "agent_mode",
                label: "Agent Mode Perf Diagnostics",
                description: "DEBUG-only toggle for Agent Mode performance diagnostics. Writes UserDefaults key 'enableAgentModePerfDiagnostics'.",
                read: { .bool($0.agentModePerfDiagnosticsEnabled()) },
                write: { try $0.setAgentModePerfDiagnosticsEnabled(requiredBool(from: $1)) }
            ),
            boolSetting(
                key: "agent_mode.perf_diagnostics_os_log_enabled",
                group: "agent_mode",
                label: "Agent Mode Perf Diagnostics OSLog",
                description: "DEBUG-only toggle for mirroring Agent Mode performance diagnostics to OSLog. Writes UserDefaults key 'emitAgentModePerfDiagnosticsToOSLog'.",
                read: { .bool($0.agentModePerfDiagnosticsOSLogEnabled()) },
                write: { try $0.setAgentModePerfDiagnosticsOSLogEnabled(requiredBool(from: $1)) }
            )
        ]
    #else
        private static let debugDefinitions: [AppSettingDefinition] = []
    #endif

    private static let definitionsByKey: [String: AppSettingDefinition] = Dictionary(
        uniqueKeysWithValues: definitions.map { ($0.key, $0) }
    )

    static func definition(forKey key: String) throws -> AppSettingDefinition {
        guard let definition = definitionsByKey[key] else {
            throw MCPError.invalidParams("Unknown or unavailable app setting key '\(key)'. Use app_settings op='list' to inspect the allowlist.")
        }
        return definition
    }

    static func definitions(inGroup group: String?) throws -> [AppSettingDefinition] {
        guard let group else { return definitions }
        guard groups.contains(group) else {
            throw MCPError.invalidParams("Unknown app settings group '\(group)'. Allowed groups: \(groups.joined(separator: ", ")).")
        }
        return definitions.filter { $0.group == group }
    }

    private static func boolSetting(
        key: String,
        group: String,
        label: String? = nil,
        description: String,
        read: @escaping @MainActor (GlobalSettingsStore) -> Value,
        write: @escaping @MainActor (GlobalSettingsStore, Value) throws -> Void,
        afterWrite: (@MainActor (GlobalSettingsStore, Value, NotificationCenter) -> Void)? = nil
    ) -> AppSettingDefinition {
        AppSettingDefinition(
            key: key,
            group: group,
            valueType: .boolean,
            label: label,
            description: description,
            allowedValues: nil,
            read: read,
            validate: { value in try validateBool(value, key: key) },
            write: write,
            afterWrite: afterWrite
        )
    }

    private static func stringEnumSetting(
        key: String,
        group: String,
        label: String? = nil,
        description: String,
        allowedValues: [String],
        read: @escaping @MainActor (GlobalSettingsStore) -> Value,
        write: @escaping @MainActor (GlobalSettingsStore, Value) throws -> Void,
        afterWrite: (@MainActor (GlobalSettingsStore, Value, NotificationCenter) -> Void)? = nil
    ) -> AppSettingDefinition {
        AppSettingDefinition(
            key: key,
            group: group,
            valueType: .string,
            label: label,
            description: description,
            allowedValues: allowedValues,
            read: read,
            validate: { value in try validateEnumString(value, key: key, allowedValues: allowedValues) },
            write: write,
            afterWrite: afterWrite
        )
    }

    private static func freeformStringSetting(
        key: String,
        group: String,
        label: String? = nil,
        description: String,
        maxLength: Int,
        read: @escaping @MainActor (GlobalSettingsStore) -> Value,
        write: @escaping @MainActor (GlobalSettingsStore, Value) throws -> Void,
        afterWrite: (@MainActor (GlobalSettingsStore, Value, NotificationCenter) -> Void)? = nil
    ) -> AppSettingDefinition {
        AppSettingDefinition(
            key: key,
            group: group,
            valueType: .string,
            label: label,
            description: description,
            allowedValues: nil,
            read: read,
            validate: { value in try validateTrimmedString(value, key: key, maxLength: maxLength, allowEmpty: true) },
            write: write,
            afterWrite: afterWrite
        )
    }

    private static func rawTextSetting(
        key: String,
        group: String,
        label: String? = nil,
        description: String,
        maxLength: Int,
        allowEmpty: Bool,
        read: @escaping @MainActor (GlobalSettingsStore) -> Value,
        write: @escaping @MainActor (GlobalSettingsStore, Value) throws -> Void,
        afterWrite: (@MainActor (GlobalSettingsStore, Value, NotificationCenter) -> Void)? = nil
    ) -> AppSettingDefinition {
        AppSettingDefinition(
            key: key,
            group: group,
            valueType: .string,
            label: label,
            description: description,
            allowedValues: nil,
            read: read,
            validate: { value in try validateRawString(value, key: key, maxLength: maxLength, allowEmpty: allowEmpty) },
            write: write,
            afterWrite: afterWrite
        )
    }

    private static func optionalModelRawSetting(
        key: String,
        group: String,
        label: String? = nil,
        description: String,
        read: @escaping @MainActor (GlobalSettingsStore) -> Value,
        write: @escaping @MainActor (GlobalSettingsStore, Value) throws -> Void,
        afterWrite: (@MainActor (GlobalSettingsStore, Value, NotificationCenter) -> Void)? = nil,
        candidateProvider: (@MainActor (AppSettingCandidateRequest) throws -> AppSettingCandidatesResult)? = nil,
        defaultOptionsAgent: (@MainActor (GlobalSettingsStore) -> AgentProviderKind?)? = nil
    ) -> AppSettingDefinition {
        AppSettingDefinition(
            key: key,
            group: group,
            valueType: .optionalString,
            label: label,
            description: description,
            allowedValues: nil,
            read: read,
            validate: { value in try validateOptionalTrimmedString(value, key: key, maxLength: modelRawMaxLength) },
            write: write,
            afterWrite: afterWrite,
            candidateProvider: candidateProvider,
            defaultOptionsAgent: defaultOptionsAgent
        )
    }

    private static func numberSetting(
        key: String,
        group: String,
        label: String? = nil,
        description: String,
        range: ClosedRange<Double>,
        read: @escaping @MainActor (GlobalSettingsStore) -> Value,
        write: @escaping @MainActor (GlobalSettingsStore, Value) throws -> Void
    ) -> AppSettingDefinition {
        AppSettingDefinition(
            key: key,
            group: group,
            valueType: .number,
            label: label,
            description: description,
            allowedValues: nil,
            read: read,
            validate: { value in try validateDouble(value, key: key, range: range) },
            write: write,
            afterWrite: nil
        )
    }

    private static func validateBool(_ value: Value, key: String) throws -> Value {
        switch value {
        case let .bool(bool):
            return .bool(bool)
        case let .string(raw):
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "true" {
                return .bool(true)
            }
            if normalized == "false" {
                return .bool(false)
            }
            throw MCPError.invalidParams("Setting '\(key)' requires a boolean value or 'true'/'false' string.")
        default:
            throw MCPError.invalidParams("Setting '\(key)' requires a boolean value or 'true'/'false' string.")
        }
    }

    private static func validateEnumString(_ value: Value, key: String, allowedValues: [String]) throws -> Value {
        let normalized = try validateTrimmedString(value, key: key, maxLength: 256, allowEmpty: false)
        let raw = try requiredString(from: normalized)
        guard allowedValues.contains(raw) else {
            throw MCPError.invalidParams("Invalid value for '\(key)'. Allowed values: \(allowedValues.joined(separator: ", ")).")
        }
        return .string(raw)
    }

    private static func validateTrimmedString(_ value: Value, key: String, maxLength: Int, allowEmpty: Bool) throws -> Value {
        guard case let .string(raw) = value else {
            throw MCPError.invalidParams("Setting '\(key)' requires a string value.")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !allowEmpty, trimmed.isEmpty {
            throw MCPError.invalidParams("Setting '\(key)' requires a non-empty string value.")
        }
        guard trimmed.count <= maxLength else {
            throw MCPError.invalidParams("Setting '\(key)' exceeds maximum length \(maxLength).")
        }
        return .string(trimmed)
    }

    private static func validateRawString(_ value: Value, key: String, maxLength: Int, allowEmpty: Bool) throws -> Value {
        guard case let .string(raw) = value else {
            throw MCPError.invalidParams("Setting '\(key)' requires a string value.")
        }
        if !allowEmpty, raw.isEmpty {
            throw MCPError.invalidParams("Setting '\(key)' requires a non-empty string value.")
        }
        guard raw.count <= maxLength else {
            throw MCPError.invalidParams("Setting '\(key)' exceeds maximum length \(maxLength).")
        }
        return .string(raw)
    }

    private static func validateOptionalTrimmedString(_ value: Value, key: String, maxLength: Int) throws -> Value {
        if case .null = value {
            return .null
        }
        let normalized = try validateTrimmedString(value, key: key, maxLength: maxLength, allowEmpty: true)
        let raw = try requiredString(from: normalized)
        return raw.isEmpty ? .null : .string(raw)
    }

    private static func validateFontScaleRawValue(_ value: Value) throws -> Value {
        let key = "ui.font_scale"
        let number = try numericValue(value, key: key)
        let allowedValues = FontScalePreset.allCases.map(\.rawValue)
        guard allowedValues.contains(number) else {
            let allowed = allowedValues.map { String(format: "%.0f", $0) }.joined(separator: ", ")
            throw MCPError.invalidParams("Invalid value for '\(key)'. Allowed values: \(allowed).")
        }
        return .double(number)
    }

    @MainActor
    private static func reconcileFontScaleAfterSet(
        _ store: GlobalSettingsStore,
        _ value: Value,
        _ changed: Bool,
        _ notificationCenter: NotificationCenter
    ) {
        _ = changed
        _ = notificationCenter
        guard let rawValue = value.doubleValue ?? value.intValue.map(Double.init) else { return }
        FontScaleManager.shared.applyAppSettingsRawValue(
            rawValue,
            broadcastExternalChange: store === GlobalSettingsStore.shared
        )
    }

    private static func validateDouble(_ value: Value, key: String, range: ClosedRange<Double>) throws -> Value {
        let number = try numericValue(value, key: key)
        guard range.contains(number) else {
            throw MCPError.invalidParams("Setting '\(key)' must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return .double(number)
    }

    private static func numericValue(_ value: Value, key: String) throws -> Double {
        let number: Double
        switch value {
        case let .double(double):
            number = double
        case let .int(int):
            number = Double(int)
        case let .string(raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let parsed = Double(trimmed) else {
                throw MCPError.invalidParams("Setting '\(key)' requires a finite numeric value or numeric string.")
            }
            number = parsed
        default:
            throw MCPError.invalidParams("Setting '\(key)' requires a finite numeric value or numeric string.")
        }
        guard number.isFinite else {
            throw MCPError.invalidParams("Setting '\(key)' requires a finite numeric value or numeric string.")
        }
        return number
    }

    private static func validatePromptSectionsOrder(_ value: Value) throws -> Value {
        let key = "prompt_packaging.prompt_sections_order"
        let normalized = try validateTrimmedString(
            value,
            key: key,
            maxLength: promptSectionsOrderMaxLength,
            allowEmpty: false
        )
        let raw = try requiredString(from: normalized)
        guard let data = raw.data(using: .utf8) else {
            throw MCPError.invalidParams("\(key) must be valid UTF-8 JSON.")
        }
        let decoded: [PromptSection]
        do {
            decoded = try JSONDecoder().decode([PromptSection].self, from: data)
        } catch {
            throw MCPError.invalidParams("\(key) must be a JSON array of PromptSection raw values.")
        }
        let allSections = Set(PromptSection.allCases)
        guard decoded.count == PromptSection.allCases.count, Set(decoded) == allSections else {
            let allowed = PromptSection.allCases.map(\.rawValue).joined(separator: ", ")
            throw MCPError.invalidParams("\(key) must contain each prompt section exactly once. Allowed sections: \(allowed).")
        }
        let encoded = try JSONEncoder().encode(decoded)
        guard let canonical = String(data: encoded, encoding: .utf8) else {
            throw MCPError.invalidParams("\(key) could not be encoded.")
        }
        return .string(canonical)
    }

    private static func requiredBool(from value: Value) throws -> Bool {
        guard case let .bool(bool) = value else {
            throw MCPError.invalidParams("Expected normalized boolean value.")
        }
        return bool
    }

    private static func requiredString(from value: Value) throws -> String {
        guard case let .string(string) = value else {
            throw MCPError.invalidParams("Expected normalized string value.")
        }
        return string
    }

    private static func optionalString(from value: Value) throws -> String? {
        if case .null = value { return nil }
        return try requiredString(from: value)
    }

    private static func requiredDouble(from value: Value) throws -> Double {
        guard case let .double(double) = value else {
            throw MCPError.invalidParams("Expected normalized numeric value.")
        }
        return double
    }

    private static func stringOrNull(_ value: String?) -> Value {
        guard let value, !value.isEmpty else { return .null }
        return .string(value)
    }

    @MainActor
    private static func postRecommendationsDidApply(
        _ store: GlobalSettingsStore,
        _ value: Value,
        _ notificationCenter: NotificationCenter
    ) {
        notificationCenter.post(name: .recommendationsDidApply, object: nil)
    }

    private static func fileSystemPreferencesDidChangeHook(
        key: String
    ) -> @MainActor (GlobalSettingsStore, Value, NotificationCenter) -> Void {
        { store, _, notificationCenter in
            store.postFileSystemPreferencesDidChange(key: key, notificationCenter: notificationCenter)
        }
    }

    /// Post-write hook for `models.planning_model` / `models.preferred_compose_model`.
    ///
    /// When `GlobalSettingsStore.syncChatModelWithOracle()` is true, mirrors the
    /// freshly-written value to the sibling model-raw key via the direct store setter
    /// (which does NOT re-enter `afterWrite`), then posts `.recommendationsDidApply`
    /// exactly once so UI layers (`AgentModelsSettingsViewModel`,
    /// `ContextBuilderAgentViewModel`, `PromptViewModel`, `RecommendationWizardViewModel`,
    /// `MCPServerToggleView`, `MCPSettingsView`) rebuild their derived state.
    ///
    /// Mirror-skip cases:
    /// - sync disabled
    /// - sibling already holds the same value (avoids spurious disk writes and
    ///   ensures a single notification fires per MCP write)
    /// A null write (clear) is mirrored as a null on the sibling to keep behavior
    /// symmetric with the toggle-driven UI path.
    @MainActor
    private static func postModelRawDidWrite(
        store: GlobalSettingsStore,
        siblingKey: String,
        valueJustWritten: Value,
        notificationCenter: NotificationCenter
    ) {
        if store.syncChatModelWithOracle() {
            let newValue: String? = switch valueJustWritten {
            case let .string(raw):
                raw
            case .null:
                nil
            default:
                nil
            }

            let siblingCurrent: String? = switch siblingKey {
            case "models.planning_model":
                store.planningModelRaw()
            case "models.preferred_compose_model":
                store.preferredComposeModelRaw()
            default:
                nil
            }

            if siblingCurrent != newValue {
                switch siblingKey {
                case "models.planning_model":
                    store.setPlanningModelRaw(newValue, reason: "app_settings.models.sync_sibling")
                case "models.preferred_compose_model":
                    store.setPreferredComposeModelRaw(newValue, reason: "app_settings.models.sync_sibling")
                default:
                    break
                }
            }
        }
        notificationCenter.post(name: .recommendationsDidApply, object: nil)
    }

    // MARK: - Candidate Providers

    private static func aiProviderType(for agent: AgentProviderKind) -> AIProviderType? {
        switch agent {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            .claudeCode
        case .codexExec:
            .codex
        case .openCode:
            .openCode
        case .cursor:
            .cursor
        }
    }

    private static func providerRawValue(_ provider: AIProviderType) -> String {
        switch provider {
        case .anthropic: "anthropic"
        case .openAI: "openAI"
        case .ollama: "ollama"
        case .azure: "azure"
        case .openRouter: "openRouter"
        case .gemini: "gemini"
        case .deepseek: "deepseek"
        case .customProvider: "customProvider"
        case .fireworks: "fireworks"
        case .grok: "grok"
        case .groq: "groq"
        case .zAI: "zAI"
        case .claudeCode: "claudeCode"
        case .codex: "codex"
        case .openCode: "openCode"
        case .cursor: "cursor"
        }
    }

    @MainActor
    static func fontScaleCandidates(
        request: AppSettingCandidateRequest
    ) throws -> AppSettingCandidatesResult {
        let allCandidates = FontScalePreset.allCases.map { preset in
            AppSettingCandidate(
                value: .double(preset.rawValue),
                label: preset.displayName,
                description: nil,
                group: nil,
                groupLabel: nil,
                attributes: [:]
            )
        }
        let totalCount = allCandidates.count
        let clampedLimit = max(1, request.limit)
        let truncated = totalCount > clampedLimit
        let options = truncated ? Array(allCandidates.prefix(clampedLimit)) : allCandidates
        return AppSettingCandidatesResult(
            source: "font_scale_presets",
            exhaustive: true,
            totalCount: totalCount,
            options: options,
            truncated: truncated,
            notes: []
        )
    }

    /// Returns raw-value candidates for app-level compose/planning model settings.
    /// These settings store `AIModel.rawValue` strings, not agent-run model IDs.
    @MainActor
    static func aiModelRawCandidates(
        request: AppSettingCandidateRequest
    ) throws -> AppSettingCandidatesResult {
        let filteredProvider = request.agentFilter.flatMap(aiProviderType(for:))
        let models = AIModel.allModels()
            .filter(\.isAvailable)
            .filter { model in
                guard let filteredProvider else { return true }
                return model.providerType == filteredProvider
            }
            .sorted { lhs, rhs in
                let lhsProvider = providerRawValue(lhs.providerType)
                let rhsProvider = providerRawValue(rhs.providerType)
                if lhsProvider != rhsProvider { return lhsProvider < rhsProvider }
                if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
                return lhs.rawValue < rhs.rawValue
            }

        var seenRawValues = Set<String>()
        var allCandidates: [AppSettingCandidate] = []
        for model in models {
            let trimmedRaw = model.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRaw.isEmpty,
                  trimmedRaw.count <= modelRawMaxLength,
                  seenRawValues.insert(trimmedRaw).inserted
            else { continue }

            let providerRaw = providerRawValue(model.providerType)
            var attributes: [String: Value] = [
                "provider": .string(providerRaw),
                "provider_name": .string(model.providerType.displayName),
                "available": .bool(model.isAvailable)
            ]
            if request.detailed,
               let effort = model.defaultReasoningEffort,
               !effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                attributes["reasoning_effort"] = .string(effort)
            }

            allCandidates.append(AppSettingCandidate(
                value: .string(trimmedRaw),
                label: model.displayName,
                description: nil,
                group: providerRaw,
                groupLabel: model.providerType.displayName,
                attributes: attributes
            ))
        }

        let totalCount = allCandidates.count
        let clampedLimit = max(1, request.limit)
        let truncated = totalCount > clampedLimit
        let options = truncated ? Array(allCandidates.prefix(clampedLimit)) : allCandidates

        let notes = [
            "These are current AIModel raw-value candidates; custom raw identifiers may still be accepted by app_settings op='set'.",
            "Task labels such as explore/engineer/pair/design and agent compound IDs are not valid values for this setting."
        ]

        return AppSettingCandidatesResult(
            source: "ai_model_catalog",
            exhaustive: false,
            totalCount: totalCount,
            options: options,
            truncated: truncated,
            notes: notes
        )
    }

    /// Returns model-raw candidates for string-typed Context Builder settings using the shared
    /// `AgentModelCatalog` discovery data. Task labels such as explore/engineer/pair/design
    /// are intentionally excluded — they are higher-level `agent_run model_id` aliases and
    /// are not valid values for these settings.
    @MainActor
    static func agentModelRawCandidates(
        request: AppSettingCandidateRequest
    ) throws -> AppSettingCandidatesResult {
        let discoveryAgents = AgentModelCatalog.discoveryAgents(availability: request.availability)
        let filteredAgents: [AgentModelCatalog.DiscoveryAgent] = if let agentFilter = request.agentFilter {
            discoveryAgents.filter { $0.agent == agentFilter && $0.available }
        } else {
            discoveryAgents.filter(\.available)
        }

        // Reserved task labels such as explore/engineer/pair/design are `agent_run model_id`
        // aliases, not valid values for model-raw settings. Pull the canonical set from
        // AgentModelCatalog so the filter stays in sync if new labels are added.
        let reservedTaskLabels: Set<String> = Set(
            AgentModelCatalog.taskLabels.map { $0.label.lowercased() }
        )

        var allCandidates: [AppSettingCandidate] = []
        for discoveryAgent in filteredAgents {
            for model in discoveryAgent.models {
                for target in model.startTargets {
                    // Only surface available runtime candidates, skip anything that would fail
                    // the shared `set` validator, and belt-and-braces exclude reserved task
                    // labels even if a future catalog entry happens to match one.
                    guard target.available else { continue }
                    let trimmedRaw = target.modelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedRaw.isEmpty,
                          trimmedRaw.count <= modelRawMaxLength,
                          !reservedTaskLabels.contains(trimmedRaw.lowercased())
                    else { continue }

                    var attributes: [String: Value] = [
                        "agent": .string(discoveryAgent.agent.rawValue),
                        "agent_name": .string(discoveryAgent.agent.displayName),
                        "available": .bool(discoveryAgent.available && target.available),
                        "is_default": .bool(target.isDefault)
                    ]
                    if request.detailed {
                        if let effort = target.reasoningEffort {
                            attributes["reasoning_effort"] = .string(effort.rawValue)
                        }
                        if let contextWindow = target.contextWindowTokens {
                            attributes["context_window_tokens"] = .int(contextWindow)
                        }
                        if !model.tags.isEmpty {
                            attributes["tags"] = .array(model.tags.map { Value.string($0.rawValue) })
                        }
                    }

                    let candidate = AppSettingCandidate(
                        value: .string(trimmedRaw),
                        label: target.name,
                        description: request.detailed ? target.description : nil,
                        group: discoveryAgent.agent.rawValue,
                        groupLabel: discoveryAgent.agent.displayName,
                        attributes: attributes
                    )
                    allCandidates.append(candidate)
                }
            }
        }

        let totalCount = allCandidates.count
        let clampedLimit = max(1, request.limit)
        let truncated = totalCount > clampedLimit
        let options = truncated ? Array(allCandidates.prefix(clampedLimit)) : allCandidates

        let notes = [
            "These are current runtime model candidates; custom raw identifiers may still be accepted by app_settings op='set'.",
            "Task labels such as explore/engineer/pair/design are not valid values for this setting."
        ]

        return AppSettingCandidatesResult(
            source: "agent_model_catalog",
            exhaustive: false,
            totalCount: totalCount,
            options: options,
            truncated: truncated,
            notes: notes
        )
    }
}
