import Foundation

package enum DomainSettingValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case null
}

package enum DomainSettingValueKind: String, Codable, Sendable {
    case boolean
    case integer
    case number
    case string
}

package struct DomainSettingDescriptor: Codable, Equatable, Sendable {
    package let key: String
    package let group: String
    package let valueKind: DomainSettingValueKind
    package let defaultValue: DomainSettingValue
    package let description: String
    package let allowedValues: [DomainSettingValue]?
    package let optionsAvailable: Bool

    package init(
        key: String,
        group: String,
        valueKind: DomainSettingValueKind,
        defaultValue: DomainSettingValue,
        description: String,
        allowedValues: [DomainSettingValue]? = nil,
        optionsAvailable: Bool = false
    ) {
        self.key = key
        self.group = group
        self.valueKind = valueKind
        self.defaultValue = defaultValue
        self.description = description
        self.allowedValues = allowedValues
        self.optionsAvailable = optionsAvailable || allowedValues != nil
    }
}

/// Portable Codex metadata for a Secondary Oracle model selection.
///
/// App builds derive the same values from `AIModel`; the direct runtime keeps this
/// deliberately small so the standalone backend does not depend on app-only AI code.
package struct DomainCodexModelSelection: Equatable, Sendable {
    package let canonicalRawID: String
    package let cliBaseModel: String
    package let reasoningEffort: String?
    package let serviceTier: String?
    package let displayName: String

    fileprivate init(
        canonicalRawID: String,
        cliBaseModel: String,
        reasoningEffort: String?,
        serviceTier: String?,
        displayName: String
    ) {
        self.canonicalRawID = canonicalRawID
        self.cliBaseModel = cliBaseModel
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.displayName = displayName
    }
}

private enum DomainCodexModelCatalog {
    private static let customPrefix = "codex_custom_"

    private static let currentSelections: [String: DomainCodexModelSelection] = {
        let selections = [
            selection("gpt-5.6-sol", "GPT-5.6 Sol", "low"),
            selection("gpt-5.6-sol", "GPT-5.6 Sol", "medium"),
            selection("gpt-5.6-sol", "GPT-5.6 Sol", "high"),
            selection("gpt-5.6-sol", "GPT-5.6 Sol", "xhigh"),
            selection("gpt-5.6-sol", "GPT-5.6 Sol", "max"),
            selection("gpt-5.6-sol", "GPT-5.6 Sol", "ultra"),
            selection("gpt-5.6-terra", "GPT-5.6 Terra", "low"),
            selection("gpt-5.6-terra", "GPT-5.6 Terra", "medium"),
            selection("gpt-5.6-terra", "GPT-5.6 Terra", "high"),
            selection("gpt-5.6-terra", "GPT-5.6 Terra", "xhigh"),
            selection("gpt-5.6-terra", "GPT-5.6 Terra", "max"),
            selection("gpt-5.6-terra", "GPT-5.6 Terra", "ultra"),
            selection("gpt-5.6-luna", "GPT-5.6 Luna", "low"),
            selection("gpt-5.6-luna", "GPT-5.6 Luna", "medium"),
            selection("gpt-5.6-luna", "GPT-5.6 Luna", "high"),
            selection("gpt-5.6-luna", "GPT-5.6 Luna", "xhigh"),
            selection("gpt-5.6-luna", "GPT-5.6 Luna", "max"),
            selection("gpt-5.2", "GPT-5.2", "low"),
            selection("gpt-5.2", "GPT-5.2", "medium"),
            selection("gpt-5.2", "GPT-5.2", "high"),
            selection("gpt-5.2", "GPT-5.2", "xhigh"),
            selection("gpt-5.4", "GPT-5.4", "low"),
            selection("gpt-5.4", "GPT-5.4", "medium"),
            selection("gpt-5.4", "GPT-5.4", "high"),
            selection("gpt-5.4", "GPT-5.4", "xhigh"),
            selectionWithoutEffort("gpt-5.1-mini", "GPT-5.1 Mini"),
            selection("gpt-5.3-codex", "GPT-5.3 Codex", "low"),
            selection("gpt-5.3-codex", "GPT-5.3 Codex", "medium"),
            selection("gpt-5.3-codex", "GPT-5.3 Codex", "high"),
            selection("gpt-5.3-codex", "GPT-5.3 Codex", "xhigh"),
            selectionWithoutEffort("gpt-5.1-codex-mini", "GPT-5.1 Codex Mini"),
        ]
        return Dictionary(uniqueKeysWithValues: selections.map { ($0.canonicalRawID, $0) })
    }()

    private static let legacyCanonicalRawIDs = [
        "codex_cli_gpt-5.5-low": "codex_cli_gpt-5.6-sol-low",
        "codex_cli_gpt-5.5-medium": "codex_cli_gpt-5.6-sol-medium",
        "codex_cli_gpt-5.5-high": "codex_cli_gpt-5.6-sol-high",
        "codex_cli_gpt-5.5-xhigh": "codex_cli_gpt-5.6-sol-xhigh",
    ]

    static func secondaryOracleSelection(raw: String?) throws -> DomainCodexModelSelection? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }

        let canonicalRawID = legacyCanonicalRawIDs[trimmed] ?? trimmed
        if let selection = currentSelections[canonicalRawID] {
            return selection
        }
        if canonicalRawID.hasPrefix(customPrefix) {
            let customID = String(canonicalRawID.dropFirst(customPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !customID.isEmpty else {
                throw DomainDirectSettingsError.unrecognizedSecondaryOracleModel(trimmed)
            }
            let specifier = customSpecifier(customID)
            return DomainCodexModelSelection(
                canonicalRawID: "\(customPrefix)\(customID)",
                cliBaseModel: specifier.baseModel,
                reasoningEffort: specifier.reasoningEffort,
                serviceTier: specifier.serviceTier,
                displayName: "CLI·\(humanizedCustomID(customID))"
            )
        }
        throw DomainDirectSettingsError.unrecognizedSecondaryOracleModel(trimmed)
    }

    private static func selection(
        _ baseModel: String,
        _ baseDisplayName: String,
        _ reasoningEffort: String
    ) -> DomainCodexModelSelection {
        DomainCodexModelSelection(
            canonicalRawID: "codex_cli_\(baseModel)-\(reasoningEffort)",
            cliBaseModel: baseModel,
            reasoningEffort: reasoningEffort,
            serviceTier: nil,
            displayName: "CLI·\(baseDisplayName) \(reasoningDisplayName(reasoningEffort))"
        )
    }

    private static func selectionWithoutEffort(
        _ baseModel: String,
        _ displayName: String
    ) -> DomainCodexModelSelection {
        DomainCodexModelSelection(
            canonicalRawID: "codex_cli_\(baseModel)",
            cliBaseModel: baseModel,
            reasoningEffort: nil,
            serviceTier: nil,
            displayName: "CLI·\(displayName)"
        )
    }

    private static func reasoningDisplayName(_ raw: String) -> String {
        raw == "xhigh" ? "XHigh" : raw.capitalized
    }

    private static func customSpecifier(
        _ raw: String
    ) -> (baseModel: String, reasoningEffort: String?, serviceTier: String?) {
        let suffixes: [(suffix: String, normalized: String, requiresKnownFamily: Bool)] = [
            ("xhigh", "xhigh", false),
            ("maximum", "max", true),
            ("ultra", "ultra", true),
            ("max", "max", true),
            ("medium", "medium", false),
            ("minimal", "minimal", false),
            ("high", "high", false),
            ("none", "none", false),
            ("low", "low", false),
        ]
        var baseModel = raw
        var reasoningEffort: String?
        let lowered = raw.lowercased()
        for suffix in suffixes where lowered.hasSuffix("-\(suffix.suffix)") {
            let candidate = String(raw.dropLast(suffix.suffix.count + 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { break }
            if !suffix.requiresKnownFamily
                || supportsExtendedEffort(suffix.normalized, baseModel: candidate)
            {
                baseModel = candidate
                reasoningEffort = suffix.normalized
            }
            break
        }

        let fastSuffix = "-fast"
        var serviceTier: String?
        if baseModel.lowercased().hasSuffix(fastSuffix) {
            let candidate = String(baseModel.dropLast(fastSuffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                baseModel = candidate
                serviceTier = supportsFastServiceTier(baseModel: candidate) ? "fast" : nil
            }
        }
        return (baseModel, reasoningEffort, serviceTier)
    }

    private static func supportsFastServiceTier(baseModel: String) -> Bool {
        let normalized = baseModel.lowercased()
        guard normalized.hasPrefix("gpt-") else { return false }
        let version = normalized.dropFirst("gpt-".count)
            .prefix { $0.isNumber || $0 == "." }
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard let majorRaw = components.first,
              let major = Int(majorRaw)
        else { return false }
        let minor = components.count > 1 ? Int(components[1]) : 0
        guard let minor else { return false }
        return major > 5 || (major == 5 && minor >= 3)
    }

    private static func supportsExtendedEffort(_ effort: String, baseModel: String) -> Bool {
        let fastSuffix = "-fast"
        let normalizedBase = baseModel.lowercased().hasSuffix(fastSuffix)
            ? String(baseModel.dropLast(fastSuffix.count)).lowercased()
            : baseModel.lowercased()
        switch normalizedBase {
        case "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra":
            return effort == "max" || effort == "ultra"
        case "gpt-5.6-luna":
            return effort == "max"
        default:
            return false
        }
    }

    private static func humanizedCustomID(_ raw: String) -> String {
        let tokens = raw.split { character in
            character == "_" || character == "-" || character == "/" || character.isWhitespace
        }
        guard !tokens.isEmpty else { return raw }

        var formatted: [String] = []
        for token in tokens {
            let value = String(token)
            let lower = value.lowercased()
            let rendered: String
            switch lower {
            case "gpt": rendered = "GPT"
            case "codex": rendered = "Codex"
            case "xhigh": rendered = "XHigh"
            default: rendered = isVersionToken(value) ? value : lower.capitalized
            }
            if isVersionToken(value), formatted.last == "GPT" {
                formatted[formatted.count - 1] = "GPT-\(rendered)"
            } else {
                formatted.append(rendered)
            }
        }
        return formatted.joined(separator: " ")
    }

    private static func isVersionToken(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }
}

/// Protocol-neutral catalog shared by app and standalone settings adapters.
package enum DomainAppSettingsCatalog {
    package static let groups = [
        "ui", "prompt_packaging", "models", "context_builder", "mcp", "code_maps", "file_system", "agent_mode",
    ]

    package static let descriptors: [DomainSettingDescriptor] = [
        enumString("ui.appearance_mode", "ui", "System", ["System", "Light", "Dark"], "App appearance mode."),
        bool("ui.show_tooltips", "ui", true, "Whether RepoPrompt shows app tooltips."),
        bool("ui.enable_keyboard_shortcuts", "ui", true, "Whether global keyboard shortcuts are enabled."),
        DomainSettingDescriptor(key: "ui.font_scale", group: "ui", valueKind: .number, defaultValue: .number(13), description: "App-wide UI font scale preset body size.", allowedValues: [11, 12, 13, 14, 15, 16].map { .number(Double($0)) }),
        DomainSettingDescriptor(key: "prompt_packaging.prompt_sections_order", group: "prompt_packaging", valueKind: .string, defaultValue: .string("[]"), description: "Serialized prompt section ordering used when packaging prompts."),
        bool("prompt_packaging.duplicate_user_instructions_at_top", "prompt_packaging", false, "Whether user instructions are duplicated at the top of packaged prompts."),
        enumString("prompt_packaging.file_path_display_option", "prompt_packaging", "Relative", ["Full", "Relative"], "How file paths are displayed in packaged context."),
        enumString("prompt_packaging.selected_files_sort_method", "prompt_packaging", "nameAscending", ["nameAscending", "nameDescending", "tokenAscending", "tokenDescending"], "Sort method for selected files."),
        bool("prompt_packaging.include_datetime_in_user_instructions", "prompt_packaging", false, "Whether packaged user instructions include the current date/time."),
        model("models.preferred_compose_model", "Preferred Built-in Chat model raw identifier, if set."),
        model("models.planning_model", "Preferred Oracle model raw identifier, if set."),
        model("models.secondary_oracle_model", "Optional independent Secondary Oracle model. Null disables the second lane."),
        bool("models.sync_chat_model_with_oracle", "models", false, "Whether the Built-in Chat model is kept in sync with the Oracle model."),
        DomainSettingDescriptor(key: "models.temperature", group: "models", valueKind: .number, defaultValue: .number(1), description: "Global default model temperature."),
        bool("models.temperature_enabled", "models", false, "Whether the global temperature is sent with model requests."),
        DomainSettingDescriptor(key: "models.custom_planning_prompt", group: "models", valueKind: .string, defaultValue: .string(""), description: "Custom Oracle system prompt."),
        enumString("context_builder.agent", "context_builder", "claudeCode", ["claudeCode", "codexExec", "cursor", "openCode", "zaiClaudeCode", "kimiClaudeCode", "customClaudeCompatible"], "CLI agent used by Context Builder."),
        model("context_builder.model", "Model raw identifier used by Context Builder."),
        bool("mcp.show_model_presets", "mcp", true, "Whether MCP model preset recommendations are shown."),
        bool("code_maps.globally_disabled", "code_maps", false, "Whether Code Maps are globally disabled."),
        bool("agent_mode.show_built_in_workflow_cleanup_guidance", "agent_mode", true, "Whether built-in workflows include cleanup guidance."),
        bool("agent_mode.codex_goal_support_enabled", "agent_mode", true, "Whether Codex goal support is enabled."),
        bool("agent_mode.codex_reasoning_summaries_enabled", "agent_mode", false, "Whether Codex reasoning summaries are requested."),
        enumString("agent_mode.provider_conversation_cleanup_action", "agent_mode", "archive", ["archive", "delete"], "Provider-side conversation cleanup action."),
        bool("file_system.respect_repo_ignore", "file_system", true, "Whether .repo_ignore files are honored."),
        bool("file_system.respect_cursorignore", "file_system", true, "Whether .cursorignore files are honored."),
        DomainSettingDescriptor(key: "file_system.global_ignore_defaults", group: "file_system", valueKind: .string, defaultValue: .string(""), description: "App-wide gitignore-style patterns."),
        bool("file_system.enable_hierarchical_ignores", "file_system", true, "Whether nested ignore files are honored."),
        bool("file_system.skip_symlinks", "file_system", false, "Whether symbolic links are skipped."),
        bool("file_system.show_empty_folders", "file_system", true, "Whether empty folders are shown."),
    ]

    private static let byKey = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, $0) })

    package static func descriptor(for key: String) -> DomainSettingDescriptor? { byKey[key] }

    package static func descriptors(in group: String?) throws -> [DomainSettingDescriptor] {
        guard let group else { return descriptors }
        guard groups.contains(group) else { throw DomainDirectSettingsError.unknownGroup(group) }
        return descriptors.filter { $0.group == group }
    }

    package static func secondaryOracleModelSelection(
        raw: String?
    ) throws -> DomainCodexModelSelection? {
        try DomainCodexModelCatalog.secondaryOracleSelection(raw: raw)
    }

    package static func canonicalized(
        _ value: DomainSettingValue,
        for descriptor: DomainSettingDescriptor
    ) throws -> DomainSettingValue {
        guard descriptor.key == "models.secondary_oracle_model" else { return value }
        switch value {
        case .null:
            return .null
        case let .string(raw):
            guard let selection = try secondaryOracleModelSelection(raw: raw) else { return .null }
            return .string(selection.canonicalRawID)
        default:
            return value
        }
    }

    package static func validate(_ value: DomainSettingValue, for descriptor: DomainSettingDescriptor) throws {
        _ = try canonicalized(value, for: descriptor)
        if case .null = value {
            guard descriptor.optionsAvailable else { throw DomainDirectSettingsError.invalidValue(descriptor.key) }
            return
        }
        let kindMatches = switch (descriptor.valueKind, value) {
        case (.boolean, .bool), (.integer, .integer), (.number, .number), (.number, .integer), (.string, .string): true
        default: false
        }
        guard kindMatches else { throw DomainDirectSettingsError.invalidValue(descriptor.key) }
        if let allowed = descriptor.allowedValues, !allowed.contains(value) {
            throw DomainDirectSettingsError.invalidValue(descriptor.key)
        }
        if descriptor.key == "models.temperature" {
            let number: Double = switch value {
            case let .number(value): value
            case let .integer(value): Double(value)
            default: -1
            }
            guard (0 ... 2).contains(number) else { throw DomainDirectSettingsError.invalidValue(descriptor.key) }
        }
    }

    private static func bool(_ key: String, _ group: String, _ value: Bool, _ description: String) -> DomainSettingDescriptor {
        DomainSettingDescriptor(key: key, group: group, valueKind: .boolean, defaultValue: .bool(value), description: description)
    }

    private static func enumString(_ key: String, _ group: String, _ value: String, _ allowed: [String], _ description: String) -> DomainSettingDescriptor {
        DomainSettingDescriptor(key: key, group: group, valueKind: .string, defaultValue: .string(value), description: description, allowedValues: allowed.map(DomainSettingValue.string))
    }

    private static func model(_ key: String, _ description: String) -> DomainSettingDescriptor {
        DomainSettingDescriptor(key: key, group: key.hasPrefix("context_builder") ? "context_builder" : "models", valueKind: .string, defaultValue: .null, description: description, optionsAvailable: true)
    }
}

package enum DomainDirectSettingsError: Error, LocalizedError, Equatable, Sendable {
    case unknownKey(String)
    case unknownGroup(String)
    case invalidValue(String)
    case futureDocument
    case wrongProfile
    case corruptDocument
    case readOnlyDegraded(String)
    case stateConflict
    case unrecognizedSecondaryOracleModel(String)

    package var errorDescription: String? {
        switch self {
        case let .unknownKey(key): "Unknown or unavailable app setting key '\(key)'."
        case let .unknownGroup(group): "Unknown app settings group '\(group)'."
        case let .invalidValue(key): "Invalid value for app setting '\(key)'."
        case .futureDocument: "Direct settings document uses a future schema version."
        case .wrongProfile: "Direct settings document belongs to another profile."
        case .corruptDocument: "Direct settings document is corrupt."
        case let .readOnlyDegraded(reason): "Direct settings are read-only degraded: \(reason)."
        case .stateConflict: "Direct settings changed in another process; retry after reading current state."
        case let .unrecognizedSecondaryOracleModel(raw):
            "Secondary Oracle Model '\(raw)' is not a recognized Oracle model ID."
        }
    }
}

private struct DomainDirectSettingsDocument: Codable, Sendable {
    static let version = 1
    let version: Int
    let profileIdentifier: String
    let revision: UInt64
    let values: [String: DomainSettingValue]
    let updatedAt: Date
}

package actor DomainDirectSettingsStore {
    private let persistence: DomainPersistenceCoordinator
    private let profileIdentifier: String
    private var values: [String: DomainSettingValue] = [:]
    private var revision: UInt64 = 0
    private var persistedDigest: String?
    private var healthReason: String?
    private var didBootstrap = false

    package init(persistence: DomainPersistenceCoordinator, profileIdentifier: String) {
        self.persistence = persistence
        self.profileIdentifier = profileIdentifier
    }

    package func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        do {
            let snapshot = try await persistence.loadDirectSettingsData()
            persistedDigest = snapshot.data.map(DomainContentDigest.sha256)
            guard let data = snapshot.data else { return }
            let document = try JSONDecoder().decode(DomainDirectSettingsDocument.self, from: data)
            guard document.version <= DomainDirectSettingsDocument.version else { throw DomainDirectSettingsError.futureDocument }
            guard document.profileIdentifier == profileIdentifier else { throw DomainDirectSettingsError.wrongProfile }
            for (key, value) in document.values {
                guard let descriptor = DomainAppSettingsCatalog.descriptor(for: key) else { continue }
                let canonicalValue = try DomainAppSettingsCatalog.canonicalized(value, for: descriptor)
                try DomainAppSettingsCatalog.validate(canonicalValue, for: descriptor)
                if case .null = canonicalValue {
                    values.removeValue(forKey: key)
                } else {
                    values[key] = canonicalValue
                }
            }
            revision = document.revision
        } catch let error as DomainDirectSettingsError {
            healthReason = error.localizedDescription
        } catch {
            healthReason = DomainDirectSettingsError.corruptDocument.localizedDescription
        }
    }

    package func effectiveValue(for key: String) throws -> DomainSettingValue {
        guard let descriptor = DomainAppSettingsCatalog.descriptor(for: key) else {
            throw DomainDirectSettingsError.unknownKey(key)
        }
        return values[key] ?? descriptor.defaultValue
    }

    package func effectiveValues(for descriptors: [DomainSettingDescriptor]) -> [String: DomainSettingValue] {
        Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, values[$0.key] ?? $0.defaultValue) })
    }

    package func set(key: String, value: DomainSettingValue) async throws -> UInt64 {
        if let healthReason { throw DomainDirectSettingsError.readOnlyDegraded(healthReason) }
        guard let descriptor = DomainAppSettingsCatalog.descriptor(for: key) else {
            throw DomainDirectSettingsError.unknownKey(key)
        }
        let canonicalValue = try DomainAppSettingsCatalog.canonicalized(value, for: descriptor)
        try DomainAppSettingsCatalog.validate(canonicalValue, for: descriptor)
        var next = values
        if case .null = canonicalValue { next.removeValue(forKey: key) } else { next[key] = canonicalValue }
        let nextRevision = revision &+ 1
        let document = DomainDirectSettingsDocument(
            version: DomainDirectSettingsDocument.version,
            profileIdentifier: profileIdentifier,
            revision: nextRevision,
            values: next,
            updatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        do {
            try await persistence.compareAndSwapDirectSettingsData(expectedDigest: persistedDigest, data: data)
        } catch DomainPersistenceError.externalDocumentConflict {
            throw DomainDirectSettingsError.stateConflict
        }
        values = next
        revision = nextRevision
        persistedDigest = DomainContentDigest.sha256(data)
        return revision
    }
}
