import Foundation
import JSONSchema
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import XCTest

@MainActor
final class OracleExecutionResolverTests: XCTestCase {
    func testDirectAstraProSelectionRemainsProForOracleExecution() throws {
        let model = AIModel.gpt6AstraProMax
        let snapshot = makeSnapshot(presets: [], profile: AgentModelsSettingsProfile(planningModelRaw: model.rawValue))
        let resolver = makeResolver(available: [model])

        let execution = try resolver.resolve(choice: .oracleSend("current_chat_model"), mode: "review", snapshot: snapshot)

        XCTAssertEqual(execution.models, [model])
        XCTAssertEqual(execution.roster.orderedModels.map(\.modelID), [model.rawValue])
        XCTAssertEqual(execution.models.first?.openAIReasoningMode, "pro")
        XCTAssertEqual(execution.models.first?.modelName, "gpt-6-astra")
    }

    func testMixedProviderResolverCapturesOrderedProviderIdentityWithoutDeduplicating() throws {
        let models: [AIModel] = [
            .claudeCodeOpus,
            .codexCustom(name: "gpt-6.1-sol-high"),
            .grokBuildCustom(name: "grok-build-test"),
            .gpt54,
            .claudeCodeOpus
        ]
        let modelStrings = models.map(\.rawValue)
        let preset = try ModelPreset(name: "Mixed providers", modelStrings: modelStrings)
        let snapshot = makeSnapshot(
            presets: [preset],
            profile: AgentModelsSettingsProfile(
                planningModelRaw: modelStrings[0],
                additionalOracleModelRaws: Array(modelStrings.dropFirst())
            )
        )
        let resolver = makeResolver(available: Set(models))
        let choices: [OracleStartChoice] = [.oracleSend("current_chat_model"), .oracleSend(preset.id.uuidString)]

        for choice in choices {
            let execution = try resolver.resolve(choice: choice, mode: "review", snapshot: snapshot)
            XCTAssertEqual(execution.models, models, "\(choice)")
            XCTAssertEqual(execution.roster.orderedModels.map(\.modelID), modelStrings, "\(choice)")
            XCTAssertEqual(
                execution.roster.orderedModels.map(\.providerID),
                ["claudeCode", "codex", "grokBuild", "openAI", "claudeCode"],
                "Provider identity must be captured by the resolver, not supplied by a group fixture: \(choice)"
            )
        }
    }

    func testExplicitPresetOwnsOrderedRosterAndMappingIncludingDuplicates() throws {
        let customReview = ChatPreset(name: "Custom Review", mode: .review)
        let preset = try ModelPreset(
            name: "Deep",
            modelStrings: [
                AIModel.gpt54.rawValue,
                AIModel.gpt54Mini.rawValue,
                AIModel.gpt54.rawValue,
                AIModel.gpt54Mini.rawValue,
                AIModel.gpt54.rawValue
            ],
            chatPresetMappings: ChatPresetMappings(reviewPresetID: customReview.id)
        )
        let snapshot = makeSnapshot(
            presets: [preset],
            profile: AgentModelsSettingsProfile(
                planningModelRaw: AIModel.claude4Sonnet.rawValue,
                additionalOracleModelRaws: [AIModel.claude4Sonnet.rawValue]
            ),
            chatPresets: ChatPreset.BuiltIn.all() + [customReview]
        )

        let execution = try makeResolver().resolve(
            choice: .oracleSend(preset.id.uuidString),
            mode: "review",
            snapshot: snapshot
        )

        XCTAssertEqual(execution.models, [.gpt54, .gpt54Mini, .gpt54, .gpt54Mini, .gpt54])
        XCTAssertEqual(execution.roster.orderedModels.map(\.modelID), preset.modelStrings)
        XCTAssertEqual(execution.promptConfiguration.chatPresetID, customReview.id)
        XCTAssertEqual(execution.selection, .explicitPreset(id: preset.id, name: preset.name))
    }

    func testExactPresetIdentityWinsRawCollisionAndRawOverrideRetainsAdditionsWithExposureOff() throws {
        let rawModel = AIModel.claude4Sonnet.rawValue
        let collision = try ModelPreset(name: rawModel, model: .gpt54Mini)
        XCTAssertEqual(collision.name, rawModel)
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54Mini.rawValue,
            additionalOracleModelRaws: [AIModel.gpt54Mini.rawValue]
        )
        let exposed = makeSnapshot(presets: [collision], profile: profile)
        let hidden = makeSnapshot(presets: [collision], profile: profile, exposed: false)

        let presetExecution = try makeResolver().resolve(
            choice: .oracleSend(rawModel),
            mode: "chat",
            snapshot: exposed
        )
        let rawExecution = try makeResolver().resolve(
            choice: .oracleSend(rawModel),
            mode: "chat",
            snapshot: hidden
        )

        XCTAssertEqual(presetExecution.models, [.gpt54Mini])
        XCTAssertEqual(rawExecution.models, [.claude4Sonnet, .gpt54Mini])
        XCTAssertEqual(rawExecution.selection, .rawPrimaryOverride(rawModel))
    }

    func testAutomaticSelectionUsesPersistedOrderAndRequiresWholeRosterAvailability() throws {
        let unavailable = try ModelPreset(
            name: "First",
            modelStrings: [AIModel.gpt54.rawValue, AIModel.claude4Sonnet.rawValue]
        )
        let usable = try ModelPreset(name: "Second", model: .gpt54Mini)
        let snapshot = makeSnapshot(presets: [unavailable, usable])
        let resolver = makeResolver(available: [.gpt54, .gpt54Mini])

        let execution = try resolver.resolve(choice: .automatic, mode: "plan", snapshot: snapshot)

        XCTAssertEqual(execution.models, [.gpt54Mini])
        XCTAssertEqual(execution.selection, .automaticPreset(id: usable.id, name: usable.name))

        XCTAssertThrowsError(
            try resolver.resolve(
                choice: .automatic,
                mode: "plan",
                snapshot: makeSnapshot(presets: [unavailable])
            )
        ) { error in
            guard case let OracleExecutionResolutionError.noUsablePreset(_, details) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(details.contains("First"))
            XCTAssertTrue(details.contains("lane 2"))
        }
    }

    func testMissingMappedChatPresetAndHiddenExplicitPresetFail() throws {
        let missingID = UUID()
        let preset = try ModelPreset(
            name: "Mapped",
            model: .gpt54,
            chatPresetMappings: ChatPresetMappings(reviewPresetID: missingID)
        )
        let resolver = makeResolver()

        XCTAssertThrowsError(
            try resolver.resolve(
                choice: .oracleSend("Mapped"),
                mode: "review",
                snapshot: makeSnapshot(presets: [preset])
            )
        ) { error in
            XCTAssertEqual(
                error as? OracleExecutionResolutionError,
                .missingMappedChatPreset(presetName: preset.name, mappingID: missingID)
            )
        }
        XCTAssertThrowsError(
            try resolver.resolve(
                choice: .contextBuilderPreset("Mapped"),
                mode: "review",
                snapshot: makeSnapshot(presets: [preset], exposed: false)
            )
        ) { error in
            XCTAssertEqual(
                error as? OracleExecutionResolutionError,
                .presetsUnavailable("Mapped")
            )
        }
    }

    func testContextBuilderUISelectionIgnoresMCPExposure() throws {
        let snapshot = OracleSelectionSnapshot(
            origin: .contextBuilderUI,
            agentModelsProfile: AgentModelsSettingsProfile(),
            modelPresets: [],
            modelPresetsExposed: false,
            modelPresetsTemporarilyDisabled: true,
            chatPresets: ChatPreset.BuiltIn.all(),
            defaultChatPresets: defaults,
            contextBuilderUIModelStrings: [AIModel.gpt54Mini.rawValue],
            contextBuilderUIChatPreset: ChatPreset.BuiltIn.plan
        )

        let execution = try makeResolver().resolve(choice: .automatic, mode: "plan", snapshot: snapshot)

        XCTAssertEqual(execution.models, [.gpt54Mini])
        XCTAssertEqual(execution.selection, .contextBuilderUI)
    }

    func testPresetMatchingAndAutomaticPriorityAreDeterministic() throws {
        let first = try ModelPreset(name: "Alpha Review", model: .gpt54)
        let second = try ModelPreset(name: "Beta Review", model: .gpt54Mini)
        let resolver = makeResolver()

        let byName = try resolver.resolve(
            choice: .oracleSend("alpha review"),
            mode: "review",
            snapshot: makeSnapshot(presets: [first, second])
        )
        let byID = try resolver.resolve(
            choice: .oracleSend(first.id.uuidString),
            mode: "review",
            snapshot: makeSnapshot(presets: [first, second])
        )
        let byFuzzyName = try resolver.resolve(
            choice: .oracleSend("Alpha Reviw"),
            mode: "review",
            snapshot: makeSnapshot(presets: [first, second])
        )
        XCTAssertEqual(byName.roster, byID.roster)
        XCTAssertEqual(byFuzzyName.roster, byID.roster)

        let originalOrder = try resolver.resolve(
            choice: .automatic,
            mode: "review",
            snapshot: makeSnapshot(presets: [first, second])
        )
        let reversedOrder = try resolver.resolve(
            choice: .automatic,
            mode: "review",
            snapshot: makeSnapshot(presets: [second, first])
        )
        XCTAssertEqual(originalOrder.primaryModel, .gpt54)
        XCTAssertEqual(reversedOrder.primaryModel, .gpt54Mini)
    }

    func testOracleSendSelectionPrecedenceIsExactPresetThenSentinelThenRawBeforeFuzzyPreset() throws {
        let exactSentinelPreset = try ModelPreset(name: "current_chat_model", model: .gpt54Mini)
        let fuzzySentinelPreset = try ModelPreset(name: "current-chat-model", model: .gpt54Mini)
        let fuzzyRawPreset = try ModelPreset(name: AIModel.gpt54.rawValue, model: .gpt54Mini)
        let profile = AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54.rawValue)
        let resolver = makeResolver()

        let exactPreset = try resolver.resolve(
            choice: .oracleSend("current_chat_model"),
            mode: "review",
            snapshot: makeSnapshot(presets: [exactSentinelPreset], profile: profile)
        )
        let sentinel = try resolver.resolve(
            choice: .oracleSend("current_chat_model"),
            mode: "review",
            snapshot: makeSnapshot(presets: [fuzzySentinelPreset], profile: profile)
        )
        let raw = try resolver.resolve(
            choice: .oracleSend(AIModel.gpt54.rawValue),
            mode: "review",
            snapshot: makeSnapshot(presets: [fuzzyRawPreset], profile: profile)
        )

        XCTAssertEqual(exactPreset.models, [.gpt54Mini])
        XCTAssertEqual(
            exactPreset.selection,
            .explicitPreset(id: exactSentinelPreset.id, name: exactSentinelPreset.name)
        )
        XCTAssertEqual(sentinel.models, [.gpt54])
        XCTAssertEqual(sentinel.selection, .agentModels)
        XCTAssertEqual(raw.models, [.gpt54])
        XCTAssertEqual(raw.selection, .rawPrimaryOverride(AIModel.gpt54.rawValue))
    }

    func testConversationUsesPersistedPromptForSameModeAndDefaultForModeChange() throws {
        let persisted = ChatPreset(name: "Persisted Review", mode: .review)
        let snapshot = makeSnapshot(presets: [], chatPresets: ChatPreset.BuiltIn.all() + [persisted])
        let resolver = makeResolver()

        let sameMode = try resolver.resolveConversation(
            modelString: AIModel.gpt54.rawValue,
            persistedChatPresetID: persisted.id,
            mode: "review",
            snapshot: snapshot
        )
        let changedMode = try resolver.resolveConversation(
            modelString: AIModel.gpt54.rawValue,
            persistedChatPresetID: persisted.id,
            mode: "plan",
            snapshot: snapshot
        )

        XCTAssertEqual(sameMode.promptConfiguration.chatPresetID, persisted.id)
        XCTAssertEqual(changedMode.promptConfiguration.chatPresetID, ChatPreset.BuiltIn.plan.id)
        XCTAssertEqual(sameMode.selection, .conversation)
        XCTAssertEqual(changedMode.selection, .conversation)
    }

    func testAdditionalOraclesFiltersResolvedRostersPreservingOrderAndDuplicateLanes() throws {
        let mirroredSchema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MCPOracleToolProvider.additionalOraclesSchema)) as? NSDictionary
        let canonicalSchema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OracleAdditionalOraclesContract.schemaProperty())) as? NSDictionary
        XCTAssertEqual(mirroredSchema, canonicalSchema)
        let typedSchema = try JSONDecoder().decode(JSONSchema.self, from: JSONEncoder().encode(MCPOracleToolProvider.additionalOraclesSchema))
        let tool = Tool(name: "ask_oracle", description: "", inputSchema: .object(properties: [OracleAdditionalOraclesContract.argumentName: typedSchema]), returnsValue: { _ in .null })
        guard case let .object(publishedSchema) = try tool.domainBinding().definition.inputSchema,
              case let .object(properties)? = publishedSchema["properties"]
        else { return XCTFail("Expected published Oracle schema") }
        XCTAssertEqual(properties[OracleAdditionalOraclesContract.argumentName], OracleAdditionalOraclesContract.schemaProperty())
        let primary = AIModel.gpt54.rawValue
        let mini = AIModel.gpt54Mini.rawValue
        let sonnet = AIModel.claude4Sonnet.rawValue
        let identifiers = [primary, mini, sonnet, mini]
        let preset = try ModelPreset(name: "Subset", modelStrings: identifiers)
        let profile = AgentModelsSettingsProfile(planningModelRaw: primary, additionalOracleModelRaws: Array(identifiers.dropFirst()))
        let resolver = makeResolver()
        let cases: [(OracleStartChoice, OracleSelectionSnapshot)] = [
            (.automatic, makeSnapshot(presets: [], profile: profile)),
            (.oracleSend(primary), makeSnapshot(presets: [], profile: profile)),
            (.oracleSend("current_chat_model"), makeSnapshot(presets: [], profile: profile)),
            (.oracleSend(preset.id.uuidString), makeSnapshot(presets: [preset])),
            (.automatic, makeSnapshot(presets: [preset]))
        ]
        for (choice, snapshot) in cases {
            let all = try resolver.resolve(choice: choice, mode: "chat", snapshot: snapshot)
            XCTAssertEqual(all.roster.orderedModels.map(\.modelID), identifiers)
            let subset = try resolver.resolve(choice: choice, mode: "chat", snapshot: snapshot, additionalOracles: [" \(sonnet) ", mini])
            XCTAssertEqual(subset.roster.orderedModels.map(\.modelID), identifiers)
            let duplicates = try resolver.resolve(choice: choice, mode: "chat", snapshot: snapshot, additionalOracles: [mini])
            XCTAssertEqual(duplicates.models, [.gpt54, .gpt54Mini, .gpt54Mini])
            let single = try resolver.resolve(choice: choice, mode: "chat", snapshot: snapshot, additionalOracles: [])
            XCTAssertEqual(single.roster.count, 1)
            XCTAssertEqual(single.models, [.gpt54])
        }
        let limited = makeResolver(available: [.gpt54, .gpt54Mini])
        for excluded in [sonnet, "unknown-model"] {
            let unavailablePreset = try ModelPreset(name: "Explicit subset", modelStrings: [primary, mini, excluded])
            let unavailableProfile = AgentModelsSettingsProfile(planningModelRaw: primary, additionalOracleModelRaws: [mini, excluded])
            let unavailableCases: [(OracleStartChoice, OracleSelectionSnapshot)] = [
                (.automatic, makeSnapshot(presets: [], profile: unavailableProfile)),
                (.oracleSend(primary), makeSnapshot(presets: [], profile: unavailableProfile)),
                (.oracleSend("current_chat_model"), makeSnapshot(presets: [], profile: unavailableProfile)),
                (.oracleSend(unavailablePreset.id.uuidString), makeSnapshot(presets: [unavailablePreset]))
            ]
            for (choice, snapshot) in unavailableCases {
                XCTAssertThrowsError(try limited.resolve(choice: choice, mode: "chat", snapshot: snapshot))
                let single = try limited.resolve(choice: choice, mode: "chat", snapshot: snapshot, additionalOracles: [])
                XCTAssertEqual(single.models, [.gpt54])
                let subset = try limited.resolve(choice: choice, mode: "chat", snapshot: snapshot, additionalOracles: [mini])
                XCTAssertEqual(subset.models, [.gpt54, .gpt54Mini])
                XCTAssertThrowsError(try limited.resolve(choice: choice, mode: "chat", snapshot: snapshot, additionalOracles: [excluded]))
            }
        }
        let ineligible = try ModelPreset(name: "Unavailable", modelStrings: [primary, sonnet])
        let eligible = try ModelPreset(name: "Available", model: .gpt54Mini)
        let automaticSnapshot = makeSnapshot(presets: [ineligible, eligible])
        let baseline = try limited.resolve(choice: .automatic, mode: "chat", snapshot: automaticSnapshot)
        let filtered = try limited.resolve(choice: .automatic, mode: "chat", snapshot: automaticSnapshot, additionalOracles: [])
        XCTAssertEqual(filtered.selection, baseline.selection)
        XCTAssertEqual(filtered.models, [.gpt54Mini])
    }

    func testAdditionalOraclesRejectsUnmatchedAndPrimaryOnlyIdentifiers() throws {
        let primary = AIModel.gpt54.rawValue
        let mini = AIModel.gpt54Mini.rawValue
        let snapshot = makeSnapshot(presets: [], profile: AgentModelsSettingsProfile(planningModelRaw: primary, additionalOracleModelRaws: [mini]))
        let first = try ModelPreset(name: "First", modelStrings: [primary, mini])
        let second = try ModelPreset(name: "Second", modelStrings: [mini, AIModel.claude4Sonnet.rawValue])
        XCTAssertThrowsError(try makeResolver().resolve(
            choice: .automatic, mode: "chat", snapshot: makeSnapshot(presets: [first, second]),
            additionalOracles: [AIModel.claude4Sonnet.rawValue]
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("Selectable identifiers: [\(mini)]"))
        }
        for identifier in ["unknown", mini.uppercased(), primary] {
            XCTAssertThrowsError(try makeResolver().resolve(choice: .automatic, mode: "chat", snapshot: snapshot, additionalOracles: [identifier])) { error in
                let message = error.localizedDescription
                XCTAssertTrue(message.contains("Unmatched additional_oracles: \(identifier)"), message)
                XCTAssertTrue(message.contains("Selectable identifiers: [\(mini)]"), message)
                XCTAssertEqual(message.contains("The primary is always included; set it with model."), identifier == primary)
            }
        }
    }

    private var defaults: [ChatPresetMode: ChatPreset] {
        [
            .chat: ChatPreset.BuiltIn.chat,
            .plan: ChatPreset.BuiltIn.plan,
            .review: ChatPreset.BuiltIn.review
        ]
    }

    private func makeSnapshot(
        presets: [ModelPreset],
        profile: AgentModelsSettingsProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54.rawValue
        ),
        chatPresets: [ChatPreset] = ChatPreset.BuiltIn.all(),
        exposed: Bool = true
    ) -> OracleSelectionSnapshot {
        OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: presets,
            modelPresetsExposed: exposed,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: chatPresets,
            defaultChatPresets: defaults
        )
    }

    private func makeResolver(
        available: Set<AIModel> = [.gpt54, .gpt54Mini, .claude4Sonnet]
    ) -> OracleExecutionResolver {
        OracleExecutionResolver(
            resolveModel: AIModel.fromModelName,
            isModelAvailable: available.contains,
            capturePromptConfiguration: { preset, mode in
                OraclePromptConfiguration(
                    chatPreset: preset,
                    mode: mode,
                    promptContext: PromptContextResolved(
                        includeFiles: true,
                        includeUserPrompt: true,
                        includeMetaPrompts: true,
                        includeFileTree: true,
                        fileTreeMode: .auto,
                        codeMapUsage: .auto,
                        gitInclusion: GitInclusion.none,
                        storedPromptIds: preset.storedPromptIds
                    ),
                    systemPrompt: preset.name,
                    metaInstructions: []
                )
            }
        )
    }
}
