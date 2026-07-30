import Combine
@testable import RepoPromptApp
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
        let recommended = AIModel.gpt54Pro.rawValue
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
        fixture.engine.applyModelRecommendations(
            recommendations,
            identity: AgentModelsOperationIdentity(sourceWorkspaceID: workspaceID, scope: .workspace(workspaceID))
        )

        let workspaceProfile = try XCTUnwrap(fixture.store.workspaceAgentModelsProfile(for: workspaceID))
        XCTAssertEqual(workspaceProfile.planningModelRaw, AIModel.gpt54Pro.rawValue)
        XCTAssertEqual(workspaceProfile.preferredComposeModelRaw, AIModel.gpt54Pro.rawValue)
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
