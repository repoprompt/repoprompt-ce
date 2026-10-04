import Foundation
import RepoPromptSettingsCore

/// Cursor runtime membership and parameter authority, with legacy offline metadata.
///
/// Cursor's CLI also publishes synthetic model variants, but expanding every
/// effort and speed combination in the model picker does not scale. Keep the
/// base models here and expose independently selectable parameters instead.
enum CursorAIModelCatalog {
    private struct Entry {
        let rawValue: String
        let displayName: String
        let aliases: [String]
        let parameters: [ACPModelParameterDefinition]

        init(
            _ rawValue: String,
            _ displayName: String,
            aliases: [String] = [],
            parameters: [ACPModelParameterDefinition] = []
        ) {
            self.rawValue = rawValue
            self.displayName = displayName
            self.aliases = aliases
            self.parameters = parameters
        }
    }

    static var options: [AgentModelOption] {
        AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor)?.options
            ?? referenceOptions.filter { $0.rawValue == AgentModel.cursorAuto.rawValue }
    }

    /// Historical aliases and diagnostic comparison only, never production effort authority.
    private static let referenceOptions: [AgentModelOption] = entries.map { entry in
        AgentModelOption(
            rawValue: entry.rawValue,
            displayName: entry.displayName,
            description: entry.rawValue == AgentModel.cursorAuto.rawValue
                ? AgentModel.cursorAuto.description
                : "Available through Cursor Agent.",
            isDefault: entry.rawValue == AgentModel.cursorAuto.rawValue
        )
    }

    struct ModelSpecifier {
        struct Override {
            let configID: String
            let valueRaw: String
        }

        let baseModelRaw: String
        let overrides: [Override]

        init(raw: String) throws {
            // A real advertisement owns its exact ID, even if it contains bracket characters.
            if CursorAIModelCatalog.options.contains(where: { $0.rawValue == raw }) || !raw.contains("[") {
                baseModelRaw = raw
                overrides = []
                return
            }
            guard let start = raw.firstIndex(of: "["), raw.hasSuffix("]") else { throw Self.invalid(raw) }
            baseModelRaw = String(raw[..<start])
            let body = raw[raw.index(after: start) ..< raw.index(before: raw.endIndex)]
            var parsed: [Override] = []
            var ids = Set<String>()
            for pair in body.split(separator: ",", omittingEmptySubsequences: false) {
                let parts = pair.split(separator: "=", omittingEmptySubsequences: false)
                guard parts.count == 2, Self.canEncode(String(parts[0])), Self.canEncode(String(parts[1])),
                      ids.insert(String(parts[0])).inserted else { throw Self.invalid(raw) }
                parsed.append(.init(configID: String(parts[0]), valueRaw: String(parts[1])))
            }
            guard !baseModelRaw.isEmpty, !baseModelRaw.contains("]"), !parsed.isEmpty else { throw Self.invalid(raw) }
            overrides = parsed
        }

        static func canEncode(_ raw: String) -> Bool {
            !raw.isEmpty && !raw.contains(where: { "[]=,".contains($0) || $0.isWhitespace })
        }

        static func invalid(_ raw: String) -> NSError {
            NSError(domain: "CursorModelSelection", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported Cursor model selection: \(raw)"])
        }

        struct ValidatedOverride {
            let baseModelRaw: String
            let kind: ACPModelParameterKind
            let configID: String
            let valueRaw: String
        }

        func selections(in snapshot: ACPDiscoveredSessionModels?, excludingConfigIDs: Set<String> = [], supersededKinds: Set<ACPModelParameterKind> = [], ignoringUnavailable: Bool = false) throws -> [ValidatedOverride] {
            let inherited = overrides.filter { !excludingConfigIDs.contains($0.configID) }
            guard !inherited.isEmpty else { return [] }
            guard let set = snapshot?.modelParameterSets.first(where: { $0.baseModelRaw == baseModelRaw }) else { throw Self.invalid(baseModelRaw) }
            return try inherited.compactMap { override in
                guard let definition = set.definition(configID: override.configID) else {
                    if ignoringUnavailable { return nil }
                    throw Self.invalid("\(override.configID)=\(override.valueRaw)")
                }
                if supersededKinds.contains(definition.kind) { return nil }
                guard definition.choices.contains(where: { $0.rawValue == override.valueRaw }) else {
                    if ignoringUnavailable { return nil }
                    throw Self.invalid("\(override.configID)=\(override.valueRaw)")
                }
                return .init(
                    baseModelRaw: set.baseModelRaw,
                    kind: definition.kind,
                    configID: definition.configID,
                    valueRaw: override.valueRaw
                )
            }
        }

        func replacing(configID: String, valueRaw: String?) -> String? {
            guard Self.canEncode(configID), valueRaw.map(Self.canEncode) ?? true else { return nil }
            var values = overrides.filter { $0.configID != configID }
            if let valueRaw { values.append(.init(configID: configID, valueRaw: valueRaw)) }
            return values.isEmpty ? baseModelRaw : baseModelRaw + "[" + values.map { "\($0.configID)=\($0.valueRaw)" }.joined(separator: ",") + "]"
        }
    }

    static func contains(modelRaw: String) -> Bool {
        option(matching: modelRaw) != nil
    }

    static func option(matching modelRaw: String) -> AgentModelOption? {
        if let exact = options.first(where: { $0.rawValue == modelRaw }) { return exact }
        if let specifier = try? ModelSpecifier(raw: modelRaw), !specifier.overrides.isEmpty,
           let base = option(matching: specifier.baseModelRaw),
           let selections = try? specifier.selections(in: AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor))
        {
            let labels = selections.map { selection in
                parameterSet(for: base.rawValue)?.definition(configID: selection.configID)?.choices.first(where: { $0.rawValue == selection.valueRaw })?.displayName ?? selection.valueRaw
            }
            return AgentModelOption(rawValue: modelRaw, displayName: base.displayName + " · " + labels.joined(separator: " · "), description: base.description, isDefault: false)
        }
        let requested = canonicalAlias(modelRaw)
        let matches = options.filter {
            canonicalAlias($0.rawValue) == requested
                || canonicalAlias($0.displayName) == requested
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func parameterSet(for modelRaw: String) -> ACPModelParameterSet? {
        if let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor),
           snapshot.hasModelParameterMetadata
        {
            guard let option = option(matching: modelRaw) else { return nil }
            return snapshot.modelParameterSets.first { $0.baseModelRaw == option.rawValue }
        }
        // A model-only legacy record contains no evidence for any parameter choices.
        return nil
    }

    static func canonicalAlias(_ raw: String) -> String {
        entry(matching: raw)?.rawValue ?? ACPAIModelCatalog.normalizedCursorModelAlias(raw)
    }

    static func reconciliationIssues(comparedTo liveCatalog: ACPDiscoveredSessionModels) -> [String] {
        var issues: [String] = []

        for localEntry in entries {
            guard liveCatalog.options.contains(where: { liveOption in
                let matched = entry(matching: liveOption.rawValue) ?? entry(matching: liveOption.displayName)
                return matched?.rawValue == localEntry.rawValue
            }) else {
                issues.append("\(localEntry.rawValue) is missing from Cursor's live catalog")
                continue
            }

            let liveSet = liveCatalog.modelParameterSets.first { set in
                entry(matching: set.baseModelRaw)?.rawValue == localEntry.rawValue
            }
            for localDefinition in localEntry.parameters {
                guard let liveDefinition = liveSet?.definition(kind: localDefinition.kind) else {
                    issues.append("\(localEntry.rawValue) \(localDefinition.displayName) is missing from Cursor's live catalog")
                    continue
                }
                if localDefinition.configID != liveDefinition.configID {
                    issues.append(
                        "\(localEntry.rawValue) \(localDefinition.displayName) selector changed "
                            + "(local: \(localDefinition.configID); live: \(liveDefinition.configID))"
                    )
                }
                let localChoices = localDefinition.choices.map(\.rawValue)
                let liveChoices = liveDefinition.choices.map(\.rawValue)
                if localChoices != liveChoices {
                    issues.append(
                        "\(localEntry.rawValue) \(localDefinition.displayName) choices changed "
                            + "(local: \(localChoices.joined(separator: ", ")); "
                            + "live: \(liveChoices.joined(separator: ", ")))"
                    )
                }
                if localDefinition.currentValueRaw != liveDefinition.currentValueRaw {
                    issues.append(
                        "\(localEntry.rawValue) \(localDefinition.displayName) default changed "
                            + "(local: \(localDefinition.currentValueRaw); live: \(liveDefinition.currentValueRaw))"
                    )
                }
            }

            let localKinds = Set(localEntry.parameters.map(\.kind))
            for liveDefinition in liveSet?.parameters ?? [] where !localKinds.contains(liveDefinition.kind) {
                issues.append("\(localEntry.rawValue) now exposes \(liveDefinition.displayName)")
            }
        }

        for liveOption in liveCatalog.options {
            guard entry(matching: liveOption.rawValue) == nil,
                  entry(matching: liveOption.displayName) == nil
            else { continue }
            issues.append("\(liveOption.rawValue) is new in Cursor's live catalog")
        }
        return issues
    }

    private static let entries: [Entry] = [
        Entry(AgentModel.cursorAuto.rawValue, AgentModel.cursorAuto.displayName),
        Entry(
            "grok-4.6",
            "Cursor Grok 4.6",
            aliases: ["cursor-grok-4.6"],
            parameters: [
                effortDefinition(values: ["low", "medium", "high", "xhigh"], defaultValue: "high"),
                speedDefinition(defaultValue: "true")
            ]
        ),
        Entry(
            "grok-4.5",
            "Cursor Grok 4.5",
            aliases: ["cursor-grok-4.5"],
            parameters: [
                effortDefinition(values: ["low", "medium", "high"], defaultValue: "high"),
                speedDefinition(defaultValue: "true")
            ]
        ),
        Entry(
            "composer-2.5",
            "Composer 2.5",
            aliases: ["composer-2"],
            parameters: [speedDefinition(defaultValue: "true")]
        ),
        Entry(
            "claude-fable-5",
            "Claude Fable 5",
            parameters: effortParameters(
                values: ["low", "medium", "high", "xhigh", "max"],
                defaultValue: "high"
            )
        ),
        Entry("claude-haiku-4-5", "Claude Haiku 4.5"),
        Entry("claude-opus-4-5", "Claude Opus 4.5"),
        Entry(
            "claude-opus-4-6",
            "Claude Opus 4.6",
            parameters: effortParameters(values: ["low", "medium", "high", "max"], defaultValue: "medium")
        ),
        Entry(
            "claude-opus-4-7",
            "Claude Opus 4.7",
            parameters: effortAndSpeedParameters(
                values: ["low", "medium", "high", "xhigh", "max"],
                defaultEffort: "xhigh"
            )
        ),
        Entry(
            "claude-opus-4-8",
            "Claude Opus 4.8",
            parameters: effortAndSpeedParameters(
                values: ["low", "medium", "high", "xhigh", "max"],
                defaultEffort: "high"
            )
        ),
        Entry(
            "claude-opus-5",
            "Claude Opus 5",
            parameters: effortAndSpeedParameters(
                values: ["low", "medium", "high", "xhigh", "max"],
                defaultEffort: "high"
            )
        ),
        Entry("claude-sonnet-4", "Claude Sonnet 4"),
        Entry("claude-sonnet-4-5", "Claude Sonnet 4.5"),
        Entry(
            "claude-sonnet-4-6",
            "Claude Sonnet 4.6",
            parameters: effortParameters(values: ["low", "medium", "high", "max"], defaultValue: "medium")
        ),
        Entry(
            "claude-sonnet-5",
            "Claude Sonnet 5",
            parameters: effortParameters(
                values: ["low", "medium", "high", "xhigh", "max"],
                defaultValue: "high"
            )
        ),
        Entry("gemini-2.5-flash", "Gemini 2.5 Flash"),
        Entry("gemini-3-flash", "Gemini 3 Flash"),
        Entry("gemini-3.1-pro", "Gemini 3.1 Pro"),
        Entry("gemini-3.5-flash", "Gemini 3.5 Flash"),
        Entry(
            "gemini-3.6-flash",
            "Gemini 3.6 Flash",
            parameters: effortParameters(
                values: ["minimal", "low", "medium", "high"],
                defaultValue: "high"
            )
        ),
        Entry(
            "gemini-3.7-flash",
            "Gemini 3.7 Flash",
            parameters: effortParameters(values: ["low", "medium", "high"], defaultValue: "high")
        ),
        Entry(
            "glm-5.2",
            "GLM 5.2",
            parameters: effortParameters(values: ["high", "max"], defaultValue: "high", configID: "reasoning")
        ),
        Entry("gpt-5-mini", "GPT-5 Mini"),
        Entry(
            "gpt-5.1",
            "GPT-5.1",
            parameters: effortParameters(values: ["low", "medium", "high"], defaultValue: "medium", configID: "reasoning")
        ),
        Entry(
            "gpt-5.2",
            "GPT-5.2",
            parameters: effortAndSpeedParameters(
                values: ["low", "medium", "high", "extra-high"],
                defaultEffort: "medium",
                configID: "reasoning"
            )
        ),
        Entry(
            "gpt-5.3-codex",
            "Codex 5.3",
            parameters: effortAndSpeedParameters(
                values: ["low", "medium", "high", "extra-high"],
                defaultEffort: "medium",
                configID: "reasoning"
            )
        ),
        Entry(
            "gpt-5.4",
            "GPT-5.4",
            parameters: effortAndSpeedParameters(
                values: ["none", "low", "medium", "high", "extra-high"],
                defaultEffort: "medium",
                configID: "reasoning"
            )
        ),
        Entry(
            "gpt-5.4-mini",
            "GPT-5.4 Mini",
            parameters: effortParameters(
                values: ["none", "low", "medium", "high", "xhigh"],
                defaultValue: "medium",
                configID: "reasoning"
            )
        ),
        Entry(
            "gpt-5.4-nano",
            "GPT-5.4 Nano",
            parameters: effortParameters(
                values: ["none", "low", "medium", "high", "xhigh"],
                defaultValue: "medium",
                configID: "reasoning"
            )
        ),
        Entry(
            "gpt-5.5",
            "GPT-5.5",
            parameters: effortAndSpeedParameters(
                values: ["none", "low", "medium", "high", "extra-high"],
                defaultEffort: "medium",
                configID: "reasoning"
            )
        ),
        Entry(
            "gpt-5.6-luna",
            "GPT-5.6 Luna",
            parameters: effortAndSpeedParameters(
                values: ["none", "low", "medium", "high", "xhigh", "max"],
                defaultEffort: "medium",
                configID: "reasoning"
            )
        ),
        Entry(
            "gpt-5.6-sol",
            "GPT-5.6 Sol",
            parameters: effortAndSpeedParameters(
                values: ["none", "low", "medium", "high", "xhigh", "max"],
                defaultEffort: "medium",
                configID: "reasoning"
            )
        ),
        Entry(
            "gpt-5.6-terra",
            "GPT-5.6 Terra",
            parameters: effortAndSpeedParameters(
                values: ["none", "low", "medium", "high", "xhigh", "max"],
                defaultEffort: "medium",
                configID: "reasoning"
            )
        ),
        Entry("kimi-k2.7-code", "Kimi K2.7 Code"),
        Entry(
            "kimi-k3",
            "Kimi K3",
            parameters: effortParameters(values: ["low", "high", "max"], defaultValue: "max", configID: "reasoning")
        )
    ]

    private static func entry(matching modelRaw: String) -> Entry? {
        let requested = ACPAIModelCatalog.normalizedCursorModelAlias(modelRaw)
        guard !requested.isEmpty else { return nil }
        return entries.first { entry in
            ([entry.rawValue, entry.displayName] + entry.aliases).contains { candidate in
                ACPAIModelCatalog.normalizedCursorModelAlias(candidate) == requested
            }
        }
    }

    private static func effortDefinition(
        values: [String],
        defaultValue: String,
        configID: String = "effort"
    ) -> ACPModelParameterDefinition {
        ACPModelParameterDefinition(
            kind: .thinking,
            configID: configID,
            displayName: "Effort",
            choices: values.map { value in
                ACPModelParameterChoice(
                    rawValue: value,
                    displayName: ["xhigh", "extra-high"].contains(value) ? "Extra High" : value.capitalized
                )
            },
            currentValueRaw: defaultValue
        )
    }

    private static func effortParameters(
        values: [String],
        defaultValue: String,
        configID: String = "effort"
    ) -> [ACPModelParameterDefinition] {
        [effortDefinition(values: values, defaultValue: defaultValue, configID: configID)]
    }

    private static func effortAndSpeedParameters(
        values: [String],
        defaultEffort: String,
        configID: String = "effort",
        defaultFast: String = "false"
    ) -> [ACPModelParameterDefinition] {
        [
            effortDefinition(values: values, defaultValue: defaultEffort, configID: configID),
            speedDefinition(defaultValue: defaultFast)
        ]
    }

    private static func speedDefinition(defaultValue: String) -> ACPModelParameterDefinition {
        ACPModelParameterDefinition(
            kind: .speed,
            configID: "fast",
            displayName: "Speed",
            choices: [
                ACPModelParameterChoice(rawValue: "false", displayName: "Standard"),
                ACPModelParameterChoice(rawValue: "true", displayName: "Fast")
            ],
            currentValueRaw: defaultValue
        )
    }
}
