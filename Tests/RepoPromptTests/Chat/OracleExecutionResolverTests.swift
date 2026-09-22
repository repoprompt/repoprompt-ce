import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class OracleExecutionResolverTests: XCTestCase {
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
