import Foundation

/// Release-gated Cursor model metadata used by Agent Mode UI and MCP surfaces.
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

    static let options: [AgentModelOption] = entries.map { entry in
        AgentModelOption(
            rawValue: entry.rawValue,
            displayName: entry.displayName,
            description: entry.rawValue == AgentModel.cursorAuto.rawValue
                ? AgentModel.cursorAuto.description
                : "Available through Cursor Agent.",
            isDefault: entry.rawValue == AgentModel.cursorAuto.rawValue
        )
    }

    static func contains(modelRaw: String) -> Bool {
        entry(matching: modelRaw) != nil
    }

    static func option(matching modelRaw: String) -> AgentModelOption? {
        guard let match = entry(matching: modelRaw) else { return nil }
        return options.first { $0.rawValue == match.rawValue }
    }

    static func parameterSet(for modelRaw: String) -> ACPModelParameterSet? {
        guard let match = entry(matching: modelRaw), !match.parameters.isEmpty else { return nil }
        return ACPModelParameterSet(baseModelRaw: match.rawValue, parameters: match.parameters)
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
