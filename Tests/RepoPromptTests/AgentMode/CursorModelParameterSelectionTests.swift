import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class CursorModelParameterSelectionTests: XCTestCase {
    func testChoiceResolutionPreservesExactWireValuesAndRejectsCaseCollisions() {
        let definition = ACPModelParameterDefinition(
            kind: .speed,
            configID: "Cursor.Fast-Mode",
            displayName: "Speed",
            choices: [
                .init(rawValue: "false", displayName: "Standard"),
                .init(rawValue: "TRUE", displayName: "Fast")
            ],
            currentValueRaw: "false"
        )

        XCTAssertEqual(definition.choice(matching: "TRUE")?.rawValue, "TRUE")
        XCTAssertEqual(definition.choice(matching: "true")?.rawValue, "TRUE")

        let colliding = ACPModelParameterDefinition(
            kind: .thinking,
            configID: "thought_level",
            displayName: "Effort",
            choices: [
                .init(rawValue: "High", displayName: "High"),
                .init(rawValue: "high", displayName: "High exact")
            ],
            currentValueRaw: "High"
        )
        XCTAssertNil(colliding.choice(matching: "HIGH"))
        XCTAssertEqual(colliding.choice(matching: "high")?.rawValue, "high")
    }

    func testPersistedSelectionNormalizationIsNamespacedAndLastWins() {
        let first = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .thinking,
            configID: "thought_level",
            valueRaw: "medium"
        )
        let replacement = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .thinking,
            configID: "thought_level",
            valueRaw: "high"
        )
        let otherModel = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "composer-2.5",
            kind: .thinking,
            configID: "thought_level",
            valueRaw: "low"
        )

        let normalized = ACPModelParameterSelection.normalized([first, otherModel, replacement])
        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized.first(where: { $0.baseModelRaw == "grok-4.6" })?.valueRaw, "high")
        XCTAssertEqual(normalized.first(where: { $0.baseModelRaw == "composer-2.5" })?.valueRaw, "low")
    }

    func testPersistedSelectionNormalizationUsesCursorAliasIdentityAndRetainsNewestWireSelection() {
        let first = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "Grok 4.6",
            kind: .thinking,
            configID: "Cursor.Thought-Level",
            valueRaw: "medium"
        )
        let replacement = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .thinking,
            configID: "effort",
            valueRaw: "high"
        )
        let distinctKind = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .speed,
            configID: "Cursor.Thought-Level",
            valueRaw: "true"
        )

        XCTAssertEqual(
            ACPModelParameterSelection.normalized([first, replacement, distinctKind]),
            [replacement, distinctKind]
        )
    }

    func testCursorClassifierRecognizesNarrowGenericAndMissingCategoryParameters() {
        let provider = CursorACPAgentProvider(config: CursorAgentConfig())
        let choices = [
            ACPModelParameterChoice(rawValue: "false", displayName: "Standard"),
            ACPModelParameterChoice(rawValue: "true", displayName: "Fast")
        ]

        XCTAssertEqual(provider.modelParameterKind(for: .init(
            configID: "Cursor.Thought-Level",
            category: "model_parameter",
            displayName: "Effort",
            choices: []
        )), .thinking)
        XCTAssertEqual(provider.modelParameterKind(for: .init(
            configID: "thought_level",
            category: nil,
            displayName: "Anything",
            choices: []
        )), .thinking)
        XCTAssertEqual(provider.modelParameterKind(for: .init(
            configID: "unrecognized",
            category: "model_config",
            displayName: "Anything",
            choices: choices
        )), .speed)
        XCTAssertEqual(provider.modelParameterKind(for: .init(
            configID: "Cursor.Fast-Mode",
            category: nil,
            displayName: "Anything",
            choices: choices
        )), .speed)
    }

    func testCursorClassifierRecognizesObservedFastSelectorShape() {
        let provider = CursorACPAgentProvider(config: CursorAgentConfig())

        XCTAssertEqual(provider.modelParameterKind(for: .init(
            configID: "fast",
            category: "model_config",
            displayName: "Fast Mode",
            choices: [
                .init(rawValue: "false", displayName: "Off"),
                .init(rawValue: "true", displayName: "Fast")
            ]
        )), .speed)
    }

    func testCursorClassifierUsesMultiLevelEffortAndReasoningButIgnoresBooleanThinking() {
        let provider = CursorACPAgentProvider(config: CursorAgentConfig())
        let effortChoices = [
            ACPModelParameterChoice(rawValue: "low", displayName: "Low"),
            ACPModelParameterChoice(rawValue: "high", displayName: "High")
        ]

        for configID in ["effort", "reasoning"] {
            XCTAssertEqual(provider.modelParameterKind(for: .init(
                configID: configID,
                category: "thought_level",
                displayName: configID.capitalized,
                choices: effortChoices
            )), .thinking, configID)
        }

        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "thinking",
            category: "thought_level",
            displayName: "Thinking",
            choices: [
                .init(rawValue: "false", displayName: "Off"),
                .init(rawValue: "true", displayName: "On")
            ]
        )))
    }

    func testCursorClassifierRejectsModelModeAndAmbiguousParameters() {
        let provider = CursorACPAgentProvider(config: CursorAgentConfig())
        let speedChoices = [
            ACPModelParameterChoice(rawValue: "false", displayName: "Standard"),
            ACPModelParameterChoice(rawValue: "true", displayName: "Fast")
        ]

        for category in ["model", "mode"] {
            XCTAssertNil(provider.modelParameterKind(for: .init(
                configID: "Cursor.Fast-Mode",
                category: category,
                displayName: "Speed",
                choices: speedChoices
            )))
        }
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "unrecognized",
            category: nil,
            displayName: "Anything",
            choices: speedChoices
        )))
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "unrecognized",
            category: "model_parameter",
            displayName: "Anything",
            choices: [.init(rawValue: "true", displayName: "Fast")]
        )))
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "unrecognized",
            category: "permission",
            displayName: "Speed",
            choices: speedChoices
        )))
    }

    func testCursorClassifierRejectsSemanticModelAndModeIDsBeforeParameterHeuristics() {
        let provider = CursorACPAgentProvider(config: CursorAgentConfig())
        let speedChoices = [
            ACPModelParameterChoice(rawValue: "false", displayName: "Standard"),
            ACPModelParameterChoice(rawValue: "true", displayName: "Fast")
        ]

        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "model",
            category: nil,
            displayName: "Effort",
            choices: []
        )))
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "mode",
            category: "model_parameter",
            displayName: "Speed",
            choices: speedChoices
        )))
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "model",
            category: "model_config",
            displayName: "Anything",
            choices: speedChoices
        )))
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "mode",
            category: nil,
            displayName: "Cursor.Fast-Mode",
            choices: speedChoices
        )))
    }

    func testAgentSessionDecodesMissingParametersAndRoundTripsExactSelections() throws {
        let legacyPayload = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","savedAt":0,"autoEditEnabled":true}"#
        let legacy = try JSONDecoder().decode(AgentSession.self, from: Data(legacyPayload.utf8))
        XCTAssertTrue(legacy.acpModelParameterSelections.isEmpty)

        let selection = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "Grok 4.6",
            kind: .speed,
            configID: "Cursor.Fast-Mode",
            valueRaw: "FALSE"
        )
        let session = AgentSession(acpModelParameterSelections: [selection])
        let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.acpModelParameterSelections, [selection])
    }

    func testLightweightSessionMetadataPreservesCursorModelParameters() {
        let selection = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .thinking,
            configID: "effort",
            valueRaw: "high"
        )
        let session = AgentSession(
            agentKind: AgentProviderKind.cursor.rawValue,
            agentModel: "grok-4.6",
            acpModelParameterSelections: [selection]
        )
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: URL(fileURLWithPath: "/tmp/cursor-parameters.json"),
            observedFileSize: nil,
            observedFileModificationDate: nil
        )

        XCTAssertEqual(record.agentSessionMeta().acpModelParameterSelections, [selection])
    }

    func testResolverUsesPersistedCursorValueAndHidesControlsForOtherProviders() {
        let persisted = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .thinking,
            configID: "Cursor.Thought-Level",
            valueRaw: "medium"
        )

        let resolved = ACPModelParameterResolver.resolve(
            providerID: .cursor,
            selectedModelRaw: "Grok 4.6",
            persistedSelections: [persisted]
        )
        XCTAssertEqual(resolved.map(\.definition.kind), [.thinking, .speed])
        XCTAssertEqual(resolved.map(\.selectedChoice.rawValue), ["medium", "true"])
        XCTAssertTrue(ACPModelParameterResolver.resolve(
            providerID: .openCode,
            selectedModelRaw: "grok-4.6",
            persistedSelections: [persisted]
        ).isEmpty)
    }

    func testEffectiveSelectionsForwardStoredIntentWithoutMetadataLookup() {
        let stale = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "Grok 4.6",
            kind: .thinking,
            configID: "Cursor.Thought-Level",
            valueRaw: "retired-effort"
        )

        let effective = ACPModelParameterResolver.effectiveSelections(
            providerID: .cursor,
            selectedModelRaw: "Grok 4.6",
            persistedSelections: [stale]
        )

        XCTAssertEqual(effective, [stale])
    }

    func testEffectiveSelectionsOmitOtherProviderAndBaseModelSelections() {
        let active = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .thinking,
            configID: "effort",
            valueRaw: "high"
        )
        let otherModel = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "composer-2.5",
            kind: .speed,
            configID: "fast",
            valueRaw: "true"
        )
        let otherProvider = ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: "ollama-cloud/kimi-k3",
            kind: .thinking,
            configID: "effort",
            valueRaw: "max"
        )

        let effective = ACPModelParameterResolver.effectiveSelections(
            providerID: .cursor,
            selectedModelRaw: "Grok 4.6",
            persistedSelections: [active, otherModel, otherProvider]
        )

        XCTAssertEqual(effective, [active])
    }

    func testSemanticIdentityCanonicalizesLegacyComposerAlias() {
        let legacy = ACPModelParameterIdentity(
            providerID: .cursor,
            baseModelRaw: "composer-2",
            kind: .speed
        )
        let current = ACPModelParameterIdentity(
            providerID: .cursor,
            baseModelRaw: "composer-2.5",
            kind: .speed
        )

        XCTAssertEqual(legacy, current)
    }

    func testCursorDiscoveryCannotReplaceReleaseCatalogSelectionsInUIFlows() {
        XCTAssertFalse(AgentModeViewModel.test_shouldAdoptDiscoveredPreferredModel(for: .cursor))
        XCTAssertFalse(ContextBuilderAgentViewModel.test_shouldAdoptDiscoveredPreferredModel(for: .cursor))
        XCTAssertTrue(AgentModeViewModel.test_shouldAdoptDiscoveredPreferredModel(for: .openCode))
        XCTAssertTrue(ContextBuilderAgentViewModel.test_shouldAdoptDiscoveredPreferredModel(for: .openCode))
    }

    func testContextBuilderPinTargetRejectsStaleCrossSurfaceModelSelection() {
        XCTAssertNil(ContextBuilderAgentViewModel.test_contextBuilderPinWriteSelection(
            liveAgent: .cursor,
            liveModelRaw: "composer-2.5",
            expectedProviderID: .cursor,
            expectedModelRaw: "grok-4.6"
        ))

        let current = ContextBuilderAgentViewModel.test_contextBuilderPinWriteSelection(
            liveAgent: .cursor,
            liveModelRaw: "grok-4.6",
            expectedProviderID: .cursor,
            expectedModelRaw: "Grok 4.6"
        )
        XCTAssertEqual(current?.agent, .cursor)
        XCTAssertEqual(current?.modelRaw, "grok-4.6")
    }

    func testPromptViewModelContextBuilderPinRejectsStaleCrossSurfaceModelSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptViewModelContextBuilderPinTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "PromptViewModelContextBuilderPinTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let cursorAgentRaw = AgentProviderKind.cursor.rawValue
        store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                contextBuilderAgentRaw: cursorAgentRaw,
                contextBuilderModelsByAgent: [cursorAgentRaw: "grok-4.6"]
            ),
            contextBuilderWriteIntent: .userInitiated
        )

        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let aiQueriesService = AIQueriesService(keyManager: keyManager)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        apiSettings.isCursorConnected = true
        apiSettings.test_completeContextBuilderProviderValidation(verifiedProviders: [.cursor])

        let prompt = PromptViewModel(
            fileManager: WorkspaceFilesViewModel(),
            aiQueriesService: aiQueriesService,
            apiSettingsViewModel: apiSettings,
            windowID: -1009,
            settingsManager: store
        )
        XCTAssertEqual(prompt.contextBuilderAgent, .cursor)
        XCTAssertEqual(prompt.contextBuilderAgentModelRaw, "grok-4.6")

        var newerProfile = store.globalAgentModelsProfile()
        newerProfile = newerProfile.replacingContextBuilderModel("composer-2.5", for: cursorAgentRaw)
        store.setGlobalAgentModelsProfile(
            newerProfile,
            contextBuilderWriteIntent: .userInitiated
        )
        XCTAssertEqual(prompt.contextBuilderAgentModelRaw, "grok-4.6", "precondition: published cache remains stale")

        prompt.setContextBuilderModelParameter(
            [cursorEffortSelection(valueRaw: "high")],
            expectedProviderID: .cursor,
            expectedModelRaw: "grok-4.6",
            expectedScope: .global
        )

        let finalProfile = store.globalAgentModelsProfile()
        XCTAssertEqual(finalProfile.contextBuilderModelsByAgent?[cursorAgentRaw], "composer-2.5")
        XCTAssertNil(finalProfile.contextBuilderModelParametersByAgent?[cursorAgentRaw])
    }

    func testActiveCursorRunLocksParameterControlsAndRejectsDefensiveSelection() {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .cursor
        session.selectedModelRaw = "grok-4.6"
        session.runState = .running
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)

        XCTAssertTrue(viewModel.makeComposerProps(tabID: tabID).areModelControlsDisabled)
        viewModel.selectACPModelParameter(cursorEffortSelection(valueRaw: "high"))
        XCTAssertTrue(session.acpModelParameterSelections.isEmpty)

        session.runState = .idle
        viewModel.updateBindingsFromSession(session)
        XCTAssertFalse(viewModel.makeComposerProps(tabID: tabID).areModelControlsDisabled)
        session.isDirty = false
        let previousGeneration = session.persistenceMutationGeneration
        viewModel.selectACPModelParameter(cursorEffortSelection(valueRaw: "high"))
        XCTAssertEqual(session.acpModelParameterSelections.map(\.valueRaw), ["high"])

        XCTAssertTrue(session.isDirty)
        XCTAssertGreaterThan(session.persistenceMutationGeneration, previousGeneration)

        viewModel.test_setMCPControlledTabIDs([tabID])
        XCTAssertTrue(viewModel.makeComposerProps(tabID: tabID).areModelControlsDisabled)
        viewModel.selectACPModelParameter(cursorSpeedSelection(valueRaw: "true"))
        XCTAssertEqual(session.acpModelParameterSelections.map(\.valueRaw), ["high"])
    }

    func testCompactParameterControlExposesAccessibleNameAndSelection() {
        let control = AgentComposerModelParameterControlProps(
            providerID: .cursor,
            kind: .thinking,
            baseModelRaw: "grok-4.6",
            configID: "thought_level",
            displayName: "Effort",
            selectedValueRaw: "high",
            selectedDisplayName: "High",
            choices: [
                .init(rawValue: "medium", displayName: "Medium"),
                .init(rawValue: "high", displayName: "High")
            ],
            openCodeDiscoveryKey: nil
        )

        XCTAssertEqual(control.accessibilityLabel, "Effort")
        XCTAssertEqual(control.accessibilityValue, "High")
    }

    func testSelectingKnownCursorModelPublishesLocalControlsSynchronously() {
        let viewModel = makeViewModel(workspacePath: "/workspace-a")
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .cursor
        session.selectedModelRaw = "grok-4.6"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)

        let controls = viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls
        XCTAssertEqual(controls.map(\.displayName), ["Effort", "Speed"])
        XCTAssertEqual(controls.map(\.selectedDisplayName), ["High", "Fast"])
    }

    func testSwitchingKnownCursorModelsImmediatelyReplacesControls() {
        let viewModel = makeViewModel(workspacePath: "/workspace-a")
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .cursor
        session.selectedModelRaw = "grok-4.6"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)
        XCTAssertEqual(
            viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.map(\.displayName),
            ["Effort", "Speed"]
        )

        session.selectedModelRaw = "composer-2.5"
        viewModel.applySessionToBindings(session)
        XCTAssertEqual(
            viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.map(\.displayName),
            ["Speed"]
        )
    }

    func testNonACPComposerHasNoParameterControls() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .codexExec
        session.selectedModelRaw = "gpt-5"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)

        XCTAssertTrue(viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.isEmpty)
    }

    func testOpenCodeComposerPublishesEffortControlWhenMetadataExists() {
        let workspacePath = "/workspace-a"
        let viewModel = makeViewModel(workspacePath: workspacePath)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .openCode
        session.selectedModelRaw = "ollama-cloud/kimi-k3"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)
        installOpenCodeObservation(viewModel, workspacePath: workspacePath)

        let controls = viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls
        XCTAssertEqual(controls.map(\.displayName), ["Effort"])
        XCTAssertEqual(controls.map(\.selectedDisplayName), ["Low"])
    }

    func testComposerShowsUnsupportedOpenCodeIntentWithoutChangingCursorFallback() throws {
        for agent: AgentProviderKind in [.openCode, .cursor] {
            let workspacePath = "/workspace-a"
            let viewModel = makeViewModel(workspacePath: workspacePath)
            let tabID = UUID()
            viewModel.test_setCurrentTabIDOverride(tabID)
            defer { viewModel.test_setCurrentTabIDOverride(nil) }
            let session = AgentModeViewModel.TabSession(tabID: tabID)
            session.hasLoadedPersistedState = true
            session.selectedAgent = agent
            session.selectedModelRaw = agent == .openCode ? "ollama-cloud/kimi-k3" : "grok-4.6"
            viewModel.test_installLiveSession(session)
            viewModel.applySessionToBindings(session)
            if agent == .openCode {
                installOpenCodeObservation(viewModel, workspacePath: workspacePath)
            }
            let providerID = try XCTUnwrap(agent.acpProviderID)
            let defaultControl = try XCTUnwrap(viewModel.makeComposerProps().acpModelParameterControls.first)
            XCTAssertFalse(defaultControl.isSavedValueUnavailable)
            XCTAssertTrue(session.acpModelParameterSelections.isEmpty)

            let saved = ACPModelParameterSelection(
                providerID: providerID,
                baseModelRaw: session.selectedModelRaw,
                kind: .thinking,
                configID: "effort",
                valueRaw: "retired-effort"
            )
            session.acpModelParameterSelections = [saved]
            let control = try XCTUnwrap(viewModel.makeComposerProps().acpModelParameterControls.first)
            XCTAssertEqual(control.selectedValueRaw, agent == .openCode ? saved.valueRaw : defaultControl.selectedValueRaw)
            XCTAssertEqual(control.selectedDisplayName, agent == .openCode ? saved.valueRaw : defaultControl.selectedDisplayName)
            XCTAssertEqual(control.isSavedValueUnavailable, agent == .openCode)
            XCTAssertEqual(control.choices, defaultControl.choices)
            if agent == .openCode {
                XCTAssertTrue(control.tooltip.contains(saved.valueRaw))
                XCTAssertEqual(control.accessibilityValue, "retired-effort, unavailable")
            } else {
                XCTAssertEqual(control.tooltip, defaultControl.tooltip)
                XCTAssertEqual(control.accessibilityValue, defaultControl.accessibilityValue)
            }
            XCTAssertEqual(ACPModelParameterResolver.effectiveSelections(
                providerID: providerID,
                selectedModelRaw: session.selectedModelRaw,
                persistedSelections: session.acpModelParameterSelections
            ), [saved])
        }
    }

    func testOpenCodeComposerHasNoControlsWhenMetadataMissing() {
        let viewModel = makeViewModel(workspacePath: "/workspace-a")
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .openCode
        session.selectedModelRaw = "anthropic/claude-sonnet"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)

        XCTAssertTrue(viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.isEmpty)
    }

    func testSelectingDisplayedFallbackCreatesExplicitOpenCodeIntent() {
        let workspacePath = "/workspace-a"
        let viewModel = makeViewModel(workspacePath: workspacePath)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .openCode
        session.selectedModelRaw = "ollama-cloud/kimi-k3"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)
        XCTAssertTrue(session.acpModelParameterSelections.isEmpty)

        installOpenCodeObservation(viewModel, workspacePath: workspacePath)
        let discoveryKey = viewModel.makeComposerProps(tabID: tabID)
            .acpModelParameterControls.first?.openCodeDiscoveryKey
        XCTAssertNotNil(discoveryKey)

        viewModel.selectACPModelParameter(
            ACPModelParameterSelection(
                providerID: .openCode,
                baseModelRaw: "ollama-cloud/kimi-k3",
                kind: .thinking,
                configID: "effort",
                valueRaw: "low"
            ),
            openCodeDiscoveryKey: discoveryKey
        )

        XCTAssertEqual(session.acpModelParameterSelections.map(\.valueRaw), ["low"])
        XCTAssertEqual(
            ACPModelParameterResolver.effectiveSelections(
                providerID: .openCode,
                selectedModelRaw: session.selectedModelRaw,
                persistedSelections: session.acpModelParameterSelections
            ).map(\.valueRaw),
            ["low"]
        )
    }

    func testStaleModelParameterSelectionIsRejected() {
        let workspacePath = "/workspace-a"
        let viewModel = makeViewModel(workspacePath: workspacePath)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .openCode
        session.selectedModelRaw = "ollama-cloud/kimi-k3"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)

        installOpenCodeObservation(viewModel, workspacePath: workspacePath)
        let discoveryKey = viewModel.makeComposerProps(tabID: tabID)
            .acpModelParameterControls.first?.openCodeDiscoveryKey

        // The selection targets a different model than the observation authority, so it must be
        // rejected rather than retargeted to the observed model.
        viewModel.selectACPModelParameter(
            ACPModelParameterSelection(
                providerID: .openCode,
                baseModelRaw: "anthropic/claude-sonnet",
                kind: .thinking,
                configID: "effort",
                valueRaw: "high"
            ),
            openCodeDiscoveryKey: discoveryKey
        )

        XCTAssertTrue(session.acpModelParameterSelections.isEmpty)
    }

    func testOpenCodeParameterActionWithoutDiscoveryKeyIsRejected() {
        let workspacePath = "/workspace-a"
        let viewModel = makeViewModel(workspacePath: workspacePath)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .openCode
        session.selectedModelRaw = "ollama-cloud/kimi-k3"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)
        installOpenCodeObservation(viewModel, workspacePath: workspacePath)

        // A click with no key (or a key that does not match the held observation) never creates
        // intent: metadata arrival alone is not a selection, and a stale menu cannot retarget.
        viewModel.selectACPModelParameter(
            ACPModelParameterSelection(
                providerID: .openCode,
                baseModelRaw: "ollama-cloud/kimi-k3",
                kind: .thinking,
                configID: "effort",
                valueRaw: "high"
            ),
            openCodeDiscoveryKey: nil
        )
        XCTAssertTrue(session.acpModelParameterSelections.isEmpty)

        let mismatchedKey = OpenCodeACPModelParameterKey(
            workspacePath: "/other-workspace",
            modelRaw: "ollama-cloud/kimi-k3"
        )
        viewModel.selectACPModelParameter(
            ACPModelParameterSelection(
                providerID: .openCode,
                baseModelRaw: "ollama-cloud/kimi-k3",
                kind: .thinking,
                configID: "effort",
                valueRaw: "high"
            ),
            openCodeDiscoveryKey: mismatchedKey
        )
        XCTAssertTrue(session.acpModelParameterSelections.isEmpty)
    }

    /// A held `.available` observation with a legitimately NIL-workspace key renders, matching
    /// the setter's whole-key comparison (a successfully resolved nil-workspace key is valid).
    func testOpenCodeNilWorkspaceKeyObservationStillRenders() {
        let viewModel = makeViewModel(workspacePath: nil)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .openCode
        session.selectedModelRaw = "ollama-cloud/kimi-k3"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)
        installOpenCodeObservation(viewModel, workspacePath: nil)

        XCTAssertFalse(viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.isEmpty)
    }

    /// Regression: the projection must not collapse "authority resolution failed" (no key)
    /// into "resolved nil-workspace key" via optional chaining. A broken worktree binding makes
    /// `effectiveWorkspacePath` throw, so the held available NIL-workspace observation must NOT
    /// render — the setter would reject the click by whole-key comparison, so rendering would
    /// show a control that is displayed but not clickable.
    func testOpenCodeNilWorkspaceObservationIsWithheldWhenWorkspaceResolutionFails() {
        let viewModel = makeViewModel(workspacePath: nil)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .openCode
        session.selectedModelRaw = "ollama-cloud/kimi-k3"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)
        installOpenCodeObservation(viewModel, workspacePath: nil)
        XCTAssertFalse(viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.isEmpty)

        // With no workspace fallback the session binds to its single worktree; a garbage root
        // makes the binding's validated execution root unresolvable, which throws.
        let garbage = "/definitely/not/a/real/root-\(UUID().uuidString)"
        session.worktreeBindings = [
            AgentSessionWorktreeBinding(
                id: "binding",
                repositoryID: "repo",
                repoKey: "repo-key",
                logicalRootPath: garbage,
                logicalRootName: "fixture",
                worktreeID: "worktree",
                worktreeRootPath: garbage,
                source: "test"
            )
        ]

        XCTAssertNil(viewModel.openCodeParameterDiscoveryKey(session: session, modelRaw: "ollama-cloud/kimi-k3"))
        XCTAssertTrue(viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.isEmpty)
    }

    func testOneChoiceOpenCodeObservationRendersSingleMenuOption() {
        let workspacePath = "/workspace-a"
        let viewModel = makeViewModel(workspacePath: workspacePath)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .openCode
        session.selectedModelRaw = "ollama-cloud/kimi-k3"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)
        installOpenCodeObservation(
            viewModel,
            workspacePath: workspacePath,
            choices: [.init(rawValue: "max", displayName: "Max")],
            currentValueRaw: "max"
        )

        let controls = viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls
        XCTAssertEqual(controls.count, 1)
        XCTAssertEqual(controls.first?.choices.map(\.displayName), ["Max"])
        XCTAssertEqual(controls.first?.selectedDisplayName, "Max")
    }

    func testOpenCodeLoadingObservationOmitsControlsButKeepsSubmissionUsable() {
        let workspacePath = "/workspace-a"
        let viewModel = makeViewModel(workspacePath: workspacePath)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .openCode
        session.selectedModelRaw = "ollama-cloud/kimi-k3"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)
        viewModel.test_setOpenCodeModelParameterObservation(
            OpenCodeACPModelParameterSnapshot(
                key: OpenCodeACPModelParameterKey(workspacePath: workspacePath, modelRaw: "ollama-cloud/kimi-k3"),
                state: .loading,
                updatedAt: Date()
            )
        )

        let props = viewModel.makeComposerProps(tabID: tabID)
        XCTAssertTrue(props.acpModelParameterControls.isEmpty)
        XCTAssertNotNil(props.submitTarget)
    }

    func testStaleProviderParameterSelectionIsRejected() {
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .cursor
        session.selectedModelRaw = "grok-4.6"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)

        viewModel.selectACPModelParameter(
            ACPModelParameterSelection(
                providerID: .openCode,
                baseModelRaw: "grok-4.6",
                kind: .thinking,
                configID: "effort",
                valueRaw: "high"
            )
        )

        XCTAssertTrue(session.acpModelParameterSelections.isEmpty)
    }

    func testOpenCodeSavedIntentSurvivesAbsentCachedMetadataForLiveValidation() {
        let saved = ACPModelParameterSelection(
            providerID: .openCode,
            baseModelRaw: "ollama-cloud/kimi-k3",
            kind: .thinking,
            configID: "effort",
            valueRaw: "max"
        )

        // No observation -> no parameter set authority (demand-scoped, not the registry), but
        // the stored selection still round-trips through effectiveSelections unchanged.
        XCTAssertNil(
            ACPModelParameterResolver.parameterSet(
                providerID: .openCode,
                selectedModelRaw: "ollama-cloud/kimi-k3"
            )
        )
        XCTAssertEqual(
            ACPModelParameterResolver.effectiveSelections(
                providerID: .openCode,
                selectedModelRaw: "ollama-cloud/kimi-k3",
                persistedSelections: [saved]
            ),
            [saved]
        )
    }

    func testActiveOpenCodeRunLocksParameterControls() {
        let workspacePath = "/workspace-a"
        let viewModel = makeViewModel(workspacePath: workspacePath)
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .openCode
        session.selectedModelRaw = "ollama-cloud/kimi-k3"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)
        installOpenCodeObservation(viewModel, workspacePath: workspacePath)
        session.runState = .running

        XCTAssertTrue(viewModel.makeComposerProps(tabID: tabID).areModelControlsDisabled)
        let discoveryKey = viewModel.makeComposerProps(tabID: tabID)
            .acpModelParameterControls.first?.openCodeDiscoveryKey
        viewModel.selectACPModelParameter(
            ACPModelParameterSelection(
                providerID: .openCode,
                baseModelRaw: "ollama-cloud/kimi-k3",
                kind: .thinking,
                configID: "effort",
                valueRaw: "high"
            ),
            openCodeDiscoveryKey: discoveryKey
        )
        XCTAssertTrue(session.acpModelParameterSelections.isEmpty)
    }

    func testActiveOpenCodeRunWithoutParameterMetadataDoesNotLockModelControls() {
        let viewModel = makeViewModel(workspacePath: "/workspace-a")
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .openCode
        session.selectedModelRaw = "anthropic/claude-sonnet"
        session.runState = .running
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)

        XCTAssertFalse(viewModel.makeComposerProps(tabID: tabID).areModelControlsDisabled)
    }

    func testUnknownCursorModelHasNoControls() {
        XCTAssertTrue(ACPModelParameterResolver.resolve(
            providerID: .cursor,
            selectedModelRaw: "future-cursor-model",
            persistedSelections: []
        ).isEmpty)
    }

    // MARK: - Demand-scoped observation lifecycle (injected stream)

    /// Explicit per-subscription handles for the injected stream provider. Each resync gets
    /// its OWN `AsyncStream` and continuation; the test records each registration (its
    /// bounded barrier) at PROVIDER-CALL time (before the VM awaits the stream), then yields
    /// onto that specific subscription, so a foreign/late delivery reaches the view model —
    /// there is no replay/ordering/routing hub to filter it out first.
    private actor SubscriptionRecorder {
        struct Registration {
            let id: UUID
            let key: OpenCodeACPModelParameterKey
        }

        private var registrations: [Registration] = []
        private var continuations: [UUID: AsyncStream<OpenCodeACPModelParameterSnapshot>.Continuation] = [:]

        /// Called by the injected stream provider. Registration happens synchronously on this
        /// actor (before the returned stream is handed back), so a subsequent
        /// `waitForSubscription` reliably observes it even if the VM has not started consuming.
        func register(workspace: String?, model: String) -> (AsyncStream<OpenCodeACPModelParameterSnapshot>, UUID) {
            let key = OpenCodeACPModelParameterKey(workspacePath: workspace, modelRaw: model)
            let (stream, continuation) = AsyncStream<OpenCodeACPModelParameterSnapshot>.makeStream(
                bufferingPolicy: .bufferingNewest(4)
            )
            let id = UUID()
            registrations.append(Registration(id: id, key: key))
            continuations[id] = continuation
            return (stream, id)
        }

        /// Bounded registration barrier: returns the ID of the NEWEST subscription for `model`
        /// that appeared after `baseline` (a value captured before the resync), so concurrent
        /// stale and current subscriptions are disambiguated.
        func waitForSubscription(model: String, seconds: UInt64, after baseline: Int = 0) async throws -> UUID {
            struct RegistrationTimeout: Error {}
            let deadline = Date().addingTimeInterval(TimeInterval(seconds))
            let canonical = ACPModelParameterIdentity.canonicalBaseModelRaw(model, providerID: .openCode)
            while true {
                if let match = registrations[baseline...].last(where: { $0.key.canonicalBaseModelRaw == canonical }) {
                    return match.id
                }
                if Date() >= deadline { throw RegistrationTimeout() }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        func registrationCount() -> Int {
            registrations.count
        }

        func continuation(for id: UUID) -> AsyncStream<OpenCodeACPModelParameterSnapshot>.Continuation? {
            continuations[id]
        }

        /// Adapts the injected provider signature: registers and returns the stream.
        func stream(workspace: String?, model: String) -> AsyncStream<OpenCodeACPModelParameterSnapshot> {
            let (stream, _) = register(workspace: workspace, model: model)
            return stream
        }
    }

    /// Drives the composer's demand-scoped observation through the INJECTED stream (not the
    /// direct setter), so target capture, key matching, and acceptance gating are all exercised
    /// the way production wiring does. This is the [P2-e] regression: the captured workspace
    /// string is un-normalized (`/a/child/..`) while the observation's key is normalized, and the
    /// control must still render.
    @MainActor
    func testComposerObservationThroughInjectedStreamAcceptsNormalizedKeyEquivalence() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }
        // `/workspace-root/child/..` and `/workspace-root` are the same logical directory.
        let rawWorkspacePath = "/workspace-root/child/.."
        let recorder = SubscriptionRecorder()
        let viewModel = AgentModeViewModel(
            testWorkspacePath: rawWorkspacePath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Picker-only tests must not start a Codex session")
            },
            testUsesProductionAgentDefaultsAndModelPolling: true,
            testOpenCodeModelParameterStreamProvider: { [recorder] workspace, model in
                await recorder.stream(workspace: workspace, model: model)
            }
        )
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .cursor
        session.selectedModelRaw = "grok-4.6"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)
        // Drive the production resync path: switching the agent through the VM's public mutable
        // state fires the didSet hook that subscribes to the injected stream. (The direct-setter
        // picker tests bypass this subscription entirely; the lifecycle tests must not.)
        viewModel.selectedAgent = .openCode
        // The test availability context lacks the demand-scoped catalog model, so the VM's didSet
        // normalizes to the resolved OpenCode default; model the observation on that resolved
        // model so the acceptance gate's key match is exercised (not bypassed).
        let effectiveModelRaw = viewModel.selectedModelRaw

        // No controls render before any observation arrives.
        XCTAssertTrue(viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.isEmpty)
        XCTAssertNil(viewModel.openCodeModelParameterObservation)

        // Deliver a normalized-key observation onto the registered subscription only after the
        // resync has registered it; bounded so a broken acceptance gate fails fast.
        let subscriptionID = try await recorder.waitForSubscription(model: effectiveModelRaw, seconds: 5)
        let observation = openCodeEffortObservation(
            workspacePath: "/workspace-root",
            modelRaw: effectiveModelRaw
        )
        await recorder.continuation(for: subscriptionID)?.yield(observation)
        try await eventually(seconds: 5) {
            !viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.isEmpty
        }

        // The HELD observation (not just the rendered controls) carries the normalized key.
        XCTAssertEqual(
            viewModel.openCodeModelParameterObservation?.key.workspacePath,
            "/workspace-root"
        )
        let controls = viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls
        XCTAssertEqual(controls.count, 1)
        XCTAssertEqual(controls.first?.configID, "effort")
        XCTAssertEqual(controls.first?.openCodeDiscoveryKey?.workspacePath, "/workspace-root")
    }

    func testComposerReconcilesRestoredModelWithoutResubscribingUnchangedTarget() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }
        let workspacePath = "/workspace-a"
        let recorder = SubscriptionRecorder()
        let viewModel = AgentModeViewModel(
            testWorkspacePath: workspacePath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Picker-only tests must not start a Codex session")
            },
            testUsesProductionAgentDefaultsAndModelPolling: true,
            testOpenCodeModelParameterStreamProvider: { workspace, model in
                await recorder.stream(workspace: workspace, model: model)
            }
        )
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .openCode
        session.selectedModelRaw = "ollama-cloud/kimi-k3"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)
        let firstSubscription = try await recorder.waitForSubscription(model: session.selectedModelRaw, seconds: 5)
        let firstObservation = openCodeEffortObservation(workspacePath: workspacePath)
        await recorder.continuation(for: firstSubscription)?.yield(firstObservation)
        try await eventually(seconds: 5) { viewModel.openCodeModelParameterObservation == firstObservation }

        // Hydration applies under isRestoringState, bypassing the model property's didSet.
        session.selectedModelRaw = "anthropic/claude-sonnet"
        viewModel.applySessionToBindings(session)
        XCTAssertNil(viewModel.openCodeModelParameterObservation)
        XCTAssertTrue(viewModel.ui.composer.props.acpModelParameterControls.isEmpty)
        let secondSubscription = try await recorder.waitForSubscription(model: session.selectedModelRaw, seconds: 5)
        let secondObservation = openCodeEffortObservation(workspacePath: workspacePath, modelRaw: session.selectedModelRaw)
        await recorder.continuation(for: secondSubscription)?.yield(secondObservation)
        try await eventually(seconds: 5) { viewModel.openCodeModelParameterObservation == secondObservation }

        // Reapplying bindings, canonical-equivalent spelling, and ordinary UI publications
        // must retain both the held result and its subscription (no extra ACP acquisition).
        session.selectedModelRaw = " ANTHROPIC/CLAUDE-SONNET "
        viewModel.applySessionToBindings(session)
        viewModel.applySessionToBindings(session)
        viewModel.syncComposerUIState()
        XCTAssertEqual(viewModel.openCodeModelParameterObservation, secondObservation)
        XCTAssertEqual(viewModel.makeComposerProps().acpModelParameterControls.first?.selectedDisplayName, "Low")
        let registrations = await recorder.registrationCount()
        XCTAssertEqual(registrations, 2)

        // A late previous-target delivery cannot replace the restored target's controls.
        await recorder.continuation(for: firstSubscription)?.yield(firstObservation)
        await recorder.continuation(for: secondSubscription)?.yield(
            openCodeEffortObservation(workspacePath: workspacePath, modelRaw: session.selectedModelRaw, currentValueRaw: "high")
        )
        try await eventually(seconds: 5) {
            viewModel.makeComposerProps().acpModelParameterControls.first?.selectedDisplayName == "High"
        }
        XCTAssertEqual(viewModel.openCodeModelParameterObservation?.key, secondObservation.key)
    }

    /// A wrong-key snapshot arriving on the CURRENT subscription is rejected by the view
    /// model's acceptance gate — the held observation stays nil and no controls render — and
    /// the same live subscription still renders its own valid result afterward. There is no
    /// fixture filtering: the foreign snapshot is yielded directly onto the recorded
    /// continuation, so the rejection proven here is the view model's own, not the fixture's.
    @MainActor
    func testComposerObservationRejectsForeignKeyOnCurrentSubscription() async throws {
        // Two valid OpenCode models so the target switch is a real (accepted) change.
        let modelA = "ollama-cloud/kimi-k3"
        let modelB = "anthropic/claude-sonnet"
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    .init(rawValue: modelA, displayName: "Kimi K3", description: nil, isPlaceholderDefault: false, isProviderDefault: true),
                    .init(rawValue: modelB, displayName: "Claude Sonnet", description: nil, isPlaceholderDefault: false, isProviderDefault: false)
                ],
                currentModelRaw: modelA,
                modelParameterSets: []
            ),
            for: .openCode
        )

        let workspacePath = "/workspace-a"
        let recorder = SubscriptionRecorder()
        let viewModel = AgentModeViewModel(
            testWorkspacePath: workspacePath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Picker-only tests must not start a Codex session")
            },
            testUsesProductionAgentDefaultsAndModelPolling: true,
            testOpenCodeModelParameterStreamProvider: { [recorder] workspace, model in
                await recorder.stream(workspace: workspace, model: model)
            }
        )
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .cursor
        session.selectedModelRaw = "grok-4.6"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)
        viewModel.selectedAgent = .openCode
        viewModel.selectedModelRaw = modelA

        // Establish model A's controls via its registered subscription.
        let subscriptionA = try await recorder.waitForSubscription(model: modelA, seconds: 5)
        await recorder.continuation(for: subscriptionA)?.yield(
            openCodeEffortObservation(workspacePath: workspacePath, modelRaw: modelA)
        )
        try await eventually(seconds: 5) {
            viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.isEmpty == false
        }
        XCTAssertNotNil(viewModel.openCodeModelParameterObservation)

        // Switch the composer target to model B; the resync synchronously clears the
        // observation and B has no metadata yet, so controls are empty.
        let baseline = await recorder.registrationCount()
        viewModel.selectModel(rawModel: modelB)
        XCTAssertTrue(viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.isEmpty)
        XCTAssertNil(viewModel.openCodeModelParameterObservation)

        // Push a FOREIGN snapshot (model A's key) directly onto the CURRENT (B) subscription.
        // It reaches the view model unfiltered, whose captured target is B, so the gate must
        // reject it: no controls and no held observation change.
        let subscriptionB = try await recorder.waitForSubscription(model: modelB, seconds: 5, after: baseline)
        await recorder.continuation(for: subscriptionB)?.yield(
            openCodeEffortObservation(workspacePath: workspacePath, modelRaw: modelA)
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.isEmpty)
        XCTAssertNil(viewModel.openCodeModelParameterObservation)

        // The same current subscription still receives and renders B's own valid result —
        // one foreign delivery never killed it.
        await recorder.continuation(for: subscriptionB)?.yield(
            openCodeEffortObservation(workspacePath: workspacePath, modelRaw: modelB)
        )
        try await eventually(seconds: 5) {
            !viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.isEmpty
        }
        XCTAssertEqual(
            viewModel.openCodeModelParameterObservation?.key.canonicalBaseModelRaw,
            modelB
        )
    }

    /// Switching the provider away from OpenCode cancels the observation: the controls drop,
    /// the held observation clears, and the composer stays submittable. Asserts only that
    /// clearing and termination.
    @MainActor
    func testComposerObservationCancellationClearsOnProviderSwitch() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }
        let workspacePath = "/workspace-a"
        let recorder = SubscriptionRecorder()
        let viewModel = AgentModeViewModel(
            testWorkspacePath: workspacePath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Picker-only tests must not start a Codex session")
            },
            testUsesProductionAgentDefaultsAndModelPolling: true,
            testOpenCodeModelParameterStreamProvider: { [recorder] workspace, model in
                await recorder.stream(workspace: workspace, model: model)
            }
        )
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .cursor
        session.selectedModelRaw = "grok-4.6"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)
        viewModel.selectedAgent = .openCode
        let effectiveModelRaw = viewModel.selectedModelRaw

        let subscriptionID = try await recorder.waitForSubscription(model: effectiveModelRaw, seconds: 5)
        await recorder.continuation(for: subscriptionID)?.yield(
            openCodeEffortObservation(workspacePath: workspacePath, modelRaw: effectiveModelRaw)
        )
        try await eventually(seconds: 5) {
            viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.isEmpty == false
        }

        // Switch provider away from OpenCode: the observation is cancelled and controls drop,
        // while submission stays usable.
        viewModel.selectedAgent = .cursor
        try await eventually(seconds: 5) {
            viewModel.makeComposerProps(tabID: tabID).acpModelParameterControls.isEmpty
        }
        XCTAssertNotNil(viewModel.makeComposerProps(tabID: tabID).submitTarget)
        XCTAssertNil(viewModel.openCodeModelParameterObservation)
    }

    /// Bounded polling barrier: fails the test with a useful message if `condition` never
    /// becomes true, instead of parking the runner forever.
    @MainActor
    private func eventually(
        seconds: UInt64,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        struct ConditionTimeout: Error {}
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if condition() { return }
        XCTFail("Timed out after \(seconds)s waiting for composer observation condition.")
        throw ConditionTimeout()
    }

    private func makeViewModel(workspacePath: String? = nil) -> AgentModeViewModel {
        AgentModeViewModel(
            testWorkspacePath: workspacePath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Picker-only tests must not start a Codex session")
            }
        )
    }

    /// OpenCode effort metadata is demand-scoped, so picker tests install a scripted observation
    /// directly into the view model (never the provider-global registry, which is no longer the
    /// OpenCode parameter authority).
    private func openCodeEffortObservation(
        workspacePath: String?,
        modelRaw: String = "ollama-cloud/kimi-k3",
        choices: [ACPModelParameterChoice] = [
            .init(rawValue: "low", displayName: "Low"),
            .init(rawValue: "high", displayName: "High")
        ],
        currentValueRaw: String = "low"
    ) -> OpenCodeACPModelParameterSnapshot {
        OpenCodeACPModelParameterSnapshot(
            key: OpenCodeACPModelParameterKey(workspacePath: workspacePath, modelRaw: modelRaw),
            state: .available(
                ACPModelParameterSet(
                    baseModelRaw: modelRaw,
                    parameters: [
                        .init(
                            kind: .thinking,
                            configID: "effort",
                            displayName: "Effort",
                            choices: choices,
                            currentValueRaw: currentValueRaw
                        )
                    ]
                )
            ),
            updatedAt: Date()
        )
    }

    private func installOpenCodeObservation(
        _ viewModel: AgentModeViewModel,
        workspacePath: String?,
        modelRaw: String = "ollama-cloud/kimi-k3",
        choices: [ACPModelParameterChoice]? = nil,
        currentValueRaw: String = "low"
    ) {
        viewModel.test_setOpenCodeModelParameterObservation(
            openCodeEffortObservation(
                workspacePath: workspacePath,
                modelRaw: modelRaw,
                choices: choices ?? [
                    .init(rawValue: "low", displayName: "Low"),
                    .init(rawValue: "high", displayName: "High")
                ],
                currentValueRaw: currentValueRaw
            )
        )
    }

    private func cursorEffortSelection(valueRaw: String) -> ACPModelParameterSelection {
        ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .thinking,
            configID: "effort",
            valueRaw: valueRaw
        )
    }

    private func cursorSpeedSelection(valueRaw: String) -> ACPModelParameterSelection {
        ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .speed,
            configID: "fast",
            valueRaw: valueRaw
        )
    }
}
