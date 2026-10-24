import Combine
import enum MCP.Value
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import XCTest

@MainActor
final class AutoRecommendationEngineScopedSettingsTests: XCTestCase {
    func testOperationIdentityRejectsWorkspaceAndInheritanceChanges() {
        let workspaceID = UUID()
        let identity = AgentModelsOperationIdentity(
            sourceWorkspaceID: workspaceID,
            inheritanceMode: .useWorkspaceOverrides
        )

        XCTAssertTrue(identity.matches(sourceWorkspaceID: workspaceID, inheritanceMode: .useWorkspaceOverrides))
        XCTAssertFalse(identity.matches(sourceWorkspaceID: UUID(), inheritanceMode: .useWorkspaceOverrides))
        XCTAssertFalse(identity.matches(sourceWorkspaceID: workspaceID, inheritanceMode: .useGlobalSettings))
    }

    func testRecommendationActionRevisionGuardRejectsSameIdentityAfterDurableChange() {
        var guardState = RecommendationActionRevisionGuard()
        guardState.markComputed()
        XCTAssertTrue(guardState.isCurrent)

        guardState.invalidate()
        XCTAssertFalse(guardState.isCurrent)

        guardState.markComputed()
        XCTAssertTrue(guardState.isCurrent)
    }

    func testRecommendationSatisfactionUsesTargetEditingScope() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let recommended = try recommendedOpenAIModelRaw(from: fixture.engine)
        let nonRecommended = AIModel.claude4Sonnet.rawValue

        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: recommended,
                preferredComposeModelRaw: recommended
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fixture.store.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: AgentModelsSettingsProfile(
                planningModelRaw: nonRecommended,
                preferredComposeModelRaw: nonRecommended
            )
        )

        let globalRecommendations = fixture.engine.computeRecommendations(
            for: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .global),
            enabledProviders: [.openAI]
        )
        let workspaceRecommendations = fixture.engine.computeRecommendations(
            for: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID)),
            enabledProviders: [.openAI]
        )

        XCTAssertEqual(globalRecommendations.chatModel?.defaultBackend, .openAI)
        XCTAssertEqual(globalRecommendations.chatModel?.alreadySatisfied, true)
        XCTAssertEqual(workspaceRecommendations.chatModel?.defaultBackend, .openAI)
        XCTAssertEqual(workspaceRecommendations.chatModel?.alreadySatisfied, false)
    }

    func testBulkApplyWritesWorkspaceProfileWithoutMutatingGlobalProfile() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let globalProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.claude4Sonnet.rawValue,
            preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
            contextBuilderAgentRaw: AgentProviderKind.claudeCode.rawValue,
            contextBuilderModelsByAgent: [
                AgentProviderKind.claudeCode.rawValue: AgentModel.claudeSonnet.rawValue
            ]
        )
        fixture.store.setGlobalAgentModelsProfile(
            globalProfile,
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fixture.store.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: AgentModelsSettingsProfile(
                planningModelRaw: AIModel.claude4Sonnet.rawValue,
                preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue
            )
        )

        let recommendations = fixture.engine.computeRecommendations(
            for: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID)),
            enabledProviders: [.openAI]
        )
        let recommended = try XCTUnwrap(recommendations.chatModel?.openAIOption?.modelString)
        fixture.engine.applyModelRecommendations(
            recommendations,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID))
        )

        let workspaceProfile = try XCTUnwrap(fixture.store.workspaceAgentModelsProfile(for: workspaceID))
        XCTAssertEqual(workspaceProfile.planningModelRaw, recommended)
        XCTAssertEqual(workspaceProfile.preferredComposeModelRaw, recommended)
        XCTAssertEqual(fixture.store.globalAgentModelsProfile(), globalProfile)
    }

    func testBulkApplyWithPresetExposureNotifiesEachAffectedScopeAndCoalescesGlobal() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let nonRecommended = AIModel.claude4Sonnet.rawValue
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: nonRecommended,
                preferredComposeModelRaw: nonRecommended
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fixture.store.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: AgentModelsSettingsProfile(
                planningModelRaw: nonRecommended,
                preferredComposeModelRaw: nonRecommended
            )
        )
        let recommendations = fixture.engine.computeRecommendations(
            for: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID)),
            enabledProviders: [.openAI]
        )
        var receivedNotifications: [Notification] = []
        let notificationCancellable = NotificationCenter.default.publisher(for: .recommendationsDidApply)
            .filter {
                $0.userInfo?[AgentModelsSettingsNotification.sourceWorkspaceIDKey] as? UUID == workspaceID
            }
            .sink { receivedNotifications.append($0) }
        defer { notificationCancellable.cancel() }

        fixture.engine.applyModelRecommendations(
            recommendations,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID)),
            includePresetExposure: true
        )

        XCTAssertEqual(receivedNotifications.count, 2)
        XCTAssertEqual(
            Set(receivedNotifications.compactMap {
                $0.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String
            }),
            Set([
                AgentModelsSettingsNotification.Scope.workspace.rawValue,
                AgentModelsSettingsNotification.Scope.global.rawValue
            ])
        )
        let workspaceNotification = try XCTUnwrap(receivedNotifications.first { notification in
            notification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String
                == AgentModelsSettingsNotification.Scope.workspace.rawValue
        })
        XCTAssertEqual(
            workspaceNotification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey] as? UUID,
            workspaceID
        )

        receivedNotifications.removeAll()
        fixture.engine.applyModelRecommendations(
            recommendations,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .global),
            includePresetExposure: true
        )

        XCTAssertEqual(receivedNotifications.count, 1)
        let globalNotification = try XCTUnwrap(receivedNotifications.first)
        XCTAssertEqual(
            globalNotification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String,
            AgentModelsSettingsNotification.Scope.global.rawValue
        )
        XCTAssertNil(globalNotification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey])
    }

    func testContextBuilderRecommendationWritesTargetWorkspaceProfileOnly() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let globalProfile = AgentModelsSettingsProfile(
            contextBuilderAgentRaw: AgentProviderKind.codexExec.rawValue,
            contextBuilderModelsByAgent: [
                AgentProviderKind.codexExec.rawValue: AgentModel.gpt55CodexLow.rawValue
            ]
        )
        fixture.store.setGlobalAgentModelsProfile(
            globalProfile,
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fixture.store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: AgentModelsSettingsProfile())
        let beforeWorkspaceChatSettings = fixture.store.chatSettings(for: workspaceID)

        let recommendation = ContextBuilderRecommendation(
            recommendedAgent: .claudeCode,
            recommendedModel: .claudeSonnet,
            rationale: "test"
        )
        fixture.engine.applyContextBuilderRecommendation(
            recommendation,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID))
        )

        let workspaceProfile = try XCTUnwrap(fixture.store.workspaceAgentModelsProfile(for: workspaceID))
        XCTAssertEqual(workspaceProfile.contextBuilderAgentRaw, AgentProviderKind.claudeCode.rawValue)
        XCTAssertEqual(
            workspaceProfile.contextBuilderModelsByAgent?[AgentProviderKind.claudeCode.rawValue],
            AgentModel.claudeSonnet.rawValue
        )
        XCTAssertEqual(fixture.store.globalAgentModelsProfile(), globalProfile)
        let afterWorkspaceChatSettings = fixture.store.chatSettings(for: workspaceID)
        XCTAssertEqual(afterWorkspaceChatSettings.contextBuilderAgentRaw, beforeWorkspaceChatSettings.contextBuilderAgentRaw)
        XCTAssertEqual(afterWorkspaceChatSettings.contextBuilderAgentModelRaw, beforeWorkspaceChatSettings.contextBuilderAgentModelRaw)
        XCTAssertEqual(
            afterWorkspaceChatSettings.didUserSetContextBuilderDefaults,
            beforeWorkspaceChatSettings.didUserSetContextBuilderDefaults
        )
    }

    func testRoleDefaultsRecommendationClearsOnlyTargetWorkspaceOverrides() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let globalOverride = AgentModelSelectionID(
            agentRaw: AgentProviderKind.codexExec.rawValue,
            modelRaw: AgentModel.gpt55CodexHigh.rawValue
        ).rawValue
        let workspaceOverride = AgentModelSelectionID(
            agentRaw: AgentProviderKind.codexExec.rawValue,
            modelRaw: AgentModel.gpt55CodexMedium.rawValue
        ).rawValue
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                mcpAgentRoleOverrides: [AgentModelCatalog.TaskLabelKind.explore.rawValue: globalOverride]
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fixture.store.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: AgentModelsSettingsProfile(
                mcpAgentRoleOverrides: [AgentModelCatalog.TaskLabelKind.explore.rawValue: workspaceOverride]
            )
        )

        let recommendation = MCPAgentDefaultsRecommendation(
            currentRoleDefaults: [],
            recommendedRoleDefaults: [],
            upgradeHint: nil
        )
        fixture.engine.applyMCPAgentDefaultsRecommendation(
            recommendation,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID))
        )

        XCTAssertEqual(
            fixture.store.globalAgentModelsProfile().mcpAgentRoleOverrides,
            [AgentModelCatalog.TaskLabelKind.explore.rawValue: globalOverride]
        )
        XCTAssertNil(fixture.store.workspaceAgentModelsProfile(for: workspaceID)?.mcpAgentRoleOverrides)
    }

    func testRoleDefaultsRecommendationUsesActualAvailabilityAndFilteredRecommendations() throws {
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
        let registry = AgentACPModelRegistry.shared
        let providers: [ACPProviderID] = [.grokBuild, .openCode]
        for provider in providers {
            registry.test_reset(providerID: provider)
        }
        defer {
            for provider in providers {
                registry.test_reset(providerID: provider)
            }
        }
        let grokModel = AgentModelOption(
            rawValue: "test-grok-pinned", displayName: "Pinned Grok", description: nil, isDefault: false
        )
        let openCodeModel = AgentModelOption(
            rawValue: "test-opencode-pinned", displayName: "Pinned OpenCode", description: nil, isDefault: false
        )
        XCTAssertTrue(registry.updateDiscoveredModels(
            .init(options: [grokModel], currentModelRaw: grokModel.rawValue), for: .grokBuild
        ))
        XCTAssertTrue(registry.updateDiscoveredModels(
            .init(options: [openCodeModel], currentModelRaw: openCodeModel.rawValue), for: .openCode
        ))
        let scenarios: [(
            name: String, grokReady: Bool, codexReady: Bool, enabled: Set<RecommendationProviderKind>,
            agent: AgentProviderKind, model: String, preservesPin: Bool, satisfied: Bool
        )] = [
            ("available Grok pin", true, true, [.codex, .grokBuild], .grokBuild, grokModel.rawValue, true, false),
            ("Grok excluded from recommendations", true, true, [.codex], .grokBuild, grokModel.rawValue, true, false),
            ("disconnected Grok pin", false, true, [.codex, .grokBuild], .grokBuild, grokModel.rawValue, false, true),
            ("Grok-only ready CLI", true, false, [.grokBuild], .grokBuild, AgentModel.defaultModel.rawValue, true, true),
            ("OpenCode stays excluded", false, true, [.codex], .openCode, openCodeModel.rawValue, false, true)
        ]
        for scenario in scenarios {
            let fixture = try makeFixture()
            defer { fixture.apiSettings.prepareForWindowClose() }
            fixture.apiSettings.isClaudeCodeConnected = false
            fixture.apiSettings.isCodexConnected = scenario.codexReady
            fixture.apiSettings.isCursorConnected = false
            fixture.apiSettings.isGrokBuildConnected = scenario.grokReady
            fixture.apiSettings.isOpenCodeConnected = scenario.agent == .openCode
            var verified: Set<AgentProviderKind> = []
            if scenario.codexReady { verified.insert(.codexExec) }
            if scenario.grokReady { verified.insert(.grokBuild) }
            fixture.apiSettings.test_completeContextBuilderProviderValidation(verifiedProviders: verified)
            let workspaceID = UUID()
            let pin = AgentModelSelectionID(agentRaw: scenario.agent.rawValue, modelRaw: scenario.model).rawValue
            fixture.store.setWorkspaceAgentModelsProfile(
                workspaceID: workspaceID,
                profile: AgentModelsSettingsProfile(mcpAgentRoleOverrides: ["pair": pin])
            )

            let result = fixture.engine.computeRecommendations(
                for: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID)),
                enabledProviders: scenario.enabled
            )
            guard let recommendation = result.mcpAgentDefaults else {
                XCTFail("\(scenario.name): ready providers must keep all role rows")
                continue
            }
            XCTAssertEqual(
                Set(recommendation.currentRoleDefaults.map(\.role)), Set(AgentModelCatalog.TaskLabelKind.allCases), scenario.name
            )
            let current = try XCTUnwrap(recommendation.currentRoleDefaults.first { $0.role == .pair }, scenario.name)
            let recommended = try XCTUnwrap(recommendation.recommendedRoleDefaults.first { $0.role == .pair }, scenario.name)
            XCTAssertEqual(
                current.selectionIDRaw, scenario.preservesPin ? pin : recommended.selectionIDRaw,
                "\(scenario.name): current must reflect the available pin, not the recommendation filter"
            )
            XCTAssertEqual(recommendation.alreadySatisfied, scenario.satisfied, "\(scenario.name): satisfaction must compare the actual current selection")
            if scenario.codexReady {
                XCTAssertEqual(recommended.agent, .codexExec, "\(scenario.name): preserve recommendation eligibility and ordering")
            }
        }
    }

    func testRuntimeOwnedRolePinsUseRecommendationAvailability() throws {
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
        let registry = AgentACPModelRegistry.shared
        let providers: [(id: ACPProviderID, agent: AgentProviderKind)] = [
            (.antigravity, .antigravity), (.devin, .devin)
        ]
        for provider in providers {
            registry.test_reset(providerID: provider.id)
        }
        defer {
            for provider in providers {
                registry.test_reset(providerID: provider.id)
            }
        }
        let fixture = try makeFixture()
        defer { fixture.apiSettings.prepareForWindowClose() }
        let status = ProviderStatusSnapshot(
            claudeCodeCLI: .notConfigured, codexCLI: .ready, cursorCLI: .notConfigured,
            grokBuildCLI: .notConfigured, openAI: .notConfigured
        )
        for provider in providers {
            let model = AgentModelOption(
                rawValue: "test-\(provider.agent.rawValue)-pinned", displayName: "Pinned model", description: nil, isDefault: false
            )
            XCTAssertTrue(registry.updateDiscoveredModels(
                .init(options: [model], currentModelRaw: model.rawValue), for: provider.id
            ))
            let pin = AgentModelSelectionID(agentRaw: provider.agent.rawValue, modelRaw: model.rawValue).rawValue
            for available in [true, false] {
                let name = "\(provider.agent.rawValue) available=\(available)"
                let context = fixture.engine.mcpAgentAvailabilityContext(
                    from: status,
                    runtimeAvailability: AgentModelCatalog.AvailabilityContext(
                        antigravityAvailable: provider.agent == .antigravity && available,
                        devinAvailable: provider.agent == .devin && available
                    )
                )
                let resolution = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
                    for: .pair,
                    availability: context,
                    settingsStore: AgentModelsProfileRoleDefaultsStore(overrides: ["pair": pin])
                ), name)
                XCTAssertEqual(
                    resolution.selectionID.rawValue,
                    available ? pin : AgentModelSelectionID(
                        agentRaw: resolution.recommended.agent.rawValue, modelRaw: resolution.recommended.modelRaw
                    ).rawValue,
                    "\(name): recommendation inputs must preserve an executable current pin"
                )
                XCTAssertEqual(resolution.overrideUnavailable, !available, "\(name): unavailable pins must remain flagged")
            }
        }
    }

    func testContextBuilderRecommendationWriteIntentDistinguishesAutomaticSeedFromExplicitApply() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let recommendation = ContextBuilderRecommendation(
            recommendedAgent: .claudeCode,
            recommendedModel: .claudeSonnet,
            rationale: "test"
        )

        fixture.engine.applyContextBuilderRecommendation(
            recommendation,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .global),
            contextBuilderWriteIntent: .automaticSeed
        )

        XCTAssertFalse(fixture.store.hasUserSetGlobalContextBuilderAgentDefaults)

        fixture.engine.applyContextBuilderRecommendation(
            recommendation,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .global),
            contextBuilderWriteIntent: .userInitiated
        )

        XCTAssertTrue(fixture.store.hasUserSetGlobalContextBuilderAgentDefaults)

        fixture.engine.applyContextBuilderRecommendation(
            recommendation,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .global),
            contextBuilderWriteIntent: .automaticSeed
        )

        XCTAssertTrue(
            fixture.store.hasUserSetGlobalContextBuilderAgentDefaults,
            "Automatic seeding must not demote an established user-owned selection."
        )
    }

    /// Clearing a saved Claude model uses Claude's catalog default without persisting it,
    /// both immediately and after a fresh-store reload.
    func testContextBuilderModelClearKeepsSettingsAndRuntimeProviderInAgreement() async throws {
        let fixture = try makeFixture()
        defer { fixture.apiSettings.prepareForWindowClose() }
        fixture.apiSettings.isClaudeCodeConnected = true
        fixture.apiSettings.isCodexConnected = true
        fixture.apiSettings.isCursorConnected = false
        fixture.apiSettings.isGrokBuildConnected = false
        fixture.apiSettings.test_completeContextBuilderProviderValidation(verifiedProviders: [.claudeCode, .codexExec])
        let claudeRaw = AgentProviderKind.claudeCode.rawValue
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                contextBuilderAgentRaw: claudeRaw,
                contextBuilderModelsByAgent: [claudeRaw: AgentModel.claudeSonnet.rawValue]
            ),
            contextBuilderWriteIntent: .userInitiated
        )
        func runtimeSelection(from store: GlobalSettingsStore) -> AgentModelCatalog.NormalizedAgentSelection? {
            let profile = store.effectiveAgentModelsProfile(workspaceID: nil)
            let agentRaw = profile.contextBuilderAgentRaw
            return AutoRecommendationEngine.resolveContextBuilderSelection(
                persistedAgentRaw: agentRaw,
                persistedModelRaw: agentRaw.flatMap { profile.contextBuilderModelsByAgent?[$0] },
                availability: fixture.apiSettings.contextBuilderRestorationAvailabilityContext,
                enabledRecommendationProviders: store.globalRecommendationProviderFilter()
            )
        }
        XCTAssertEqual(
            runtimeSelection(from: fixture.store),
            AgentModelCatalog.NormalizedAgentSelection(agent: .claudeCode, modelRaw: AgentModel.claudeSonnet.rawValue),
            "Precondition: runtime accepts the saved, available Claude/Sonnet pair"
        )
        XCTAssertTrue(fixture.store.hasUserSetGlobalContextBuilderAgentDefaults)

        let clear = try await AppSettingsMCPService(store: fixture.store).handleForTesting([
            "op": .string("set"),
            "key": .string("context_builder.model"),
            "value": .null
        ])
        XCTAssertEqual(clear.objectValue?["changed"]?.boolValue, true)
        XCTAssertEqual(clear.objectValue?["applied"]?.boolValue, true)
        XCTAssertNil(clear.objectValue?["persistence_blocked"])

        func assertClearedSelection(in store: GlobalSettingsStore, phase: String) async throws {
            let settings = AgentModelsSettingsViewModel(
                apiSettingsVM: fixture.apiSettings,
                workspaceID: nil,
                settingsManager: store,
                settingsStore: store,
                notificationCenter: NotificationCenter()
            )
            let runtime = try XCTUnwrap(runtimeSelection(from: store), phase)
            XCTAssertEqual(settings.selectedContextBuilderAgent, .claudeCode, phase)
            XCTAssertEqual(runtime.agent, .claudeCode, "\(phase): a clear must keep the saved provider")
            XCTAssertEqual(runtime, settings.selectedContextBuilderSelection, "\(phase): Settings and runtime must use the same normalized default")
            let profile = store.globalAgentModelsProfile()
            XCTAssertEqual(profile.contextBuilderAgentRaw, claudeRaw, phase)
            XCTAssertNil(profile.contextBuilderModelsByAgent?[claudeRaw], "\(phase): the synthesized default must not be saved")
            XCTAssertTrue(store.hasUserSetGlobalContextBuilderAgentDefaults, phase)
            let get = try await AppSettingsMCPService(store: store).handleForTesting([
                "op": .string("get"),
                "keys": .array([.string("context_builder.model")])
            ])
            XCTAssertEqual(get.objectValue?["values"]?.objectValue?["context_builder.model"], .null, phase)
        }
        try await assertClearedSelection(in: fixture.store, phase: "after clear")
        let reloaded = GlobalSettingsStore(
            defaults: fixture.defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fixture.fileURL)
        )
        try await assertClearedSelection(in: reloaded, phase: "after reload")
    }

    func testContextBuilderResolverKeepsSavedProviderDefaultBeforeRecommendationFiltering() throws {
        let invalidModel = "not-a-claude-model"
        let available = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true, codexAvailable: true, openCodeAvailable: false
        )
        let codexOnly = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false, codexAvailable: true, openCodeAvailable: false
        )
        XCTAssertFalse(AgentModelCatalog.isValid(rawModel: invalidModel, for: .claudeCode, availability: available))
        let scenarios: [(
            name: String, model: String?, availability: AgentModelCatalog.AvailabilityContext, expectedAgent: AgentProviderKind
        )] = [
            ("saved Claude default ignores recommendation filter", nil, available, .claudeCode),
            ("invalid nonempty Claude model keeps fallback", invalidModel, available, .codexExec),
            ("unavailable Claude default keeps fallback", nil, codexOnly, .codexExec)
        ]
        for scenario in scenarios {
            let selection = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
                persistedAgentRaw: AgentProviderKind.claudeCode.rawValue,
                persistedModelRaw: scenario.model,
                availability: scenario.availability,
                enabledRecommendationProviders: [.codex]
            ), scenario.name)
            XCTAssertEqual(selection.agent, scenario.expectedAgent, scenario.name)
        }
    }

    private func recommendedOpenAIModelRaw(from engine: AutoRecommendationEngine) throws -> String {
        let recommendations = engine.computeRecommendations(
            for: AgentModelsOperationIdentity(sourceWorkspaceID: UUID(), scope: .global),
            enabledProviders: [.openAI]
        )
        return try XCTUnwrap(recommendations.chatModel?.openAIOption?.modelString)
    }

    private func makeFixture() throws -> (
        store: GlobalSettingsStore,
        engine: AutoRecommendationEngine,
        apiSettings: APISettingsViewModel,
        defaults: UserDefaults,
        fileURL: URL
    ) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRecommendationEngineScopedSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }

        let suiteName = "AutoRecommendationEngineScopedSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        apiSettings.openAIApiKey = "test-key"
        apiSettings.isOpenAIKeyValid = true
        let engine = AutoRecommendationEngine(
            settingsStore: store,
            profileSettingsManager: store,
            apiSettingsViewModel: apiSettings
        )
        return (store, engine, apiSettings, defaults, fileURL)
    }
}
