import Combine
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
        apiSettings: APISettingsViewModel
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

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(
                fileURL: temp.appendingPathComponent("Settings/globalSettings.json")
            )
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
        return (store, engine, apiSettings)
    }
}
