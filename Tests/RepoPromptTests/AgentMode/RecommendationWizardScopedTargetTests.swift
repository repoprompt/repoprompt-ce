import Combine
@testable import RepoPromptApp
import XCTest

@MainActor
final class RecommendationWizardScopedTargetTests: XCTestCase {
    func testEditingScopeResolverMapsInheritanceToGlobalOrWorkspace() {
        let workspaceID = UUID()

        XCTAssertEqual(
            AgentModelsEditingScope.resolve(
                workspaceID: nil,
                inheritanceMode: .useWorkspaceOverrides
            ),
            .global
        )
        XCTAssertEqual(
            AgentModelsEditingScope.resolve(
                workspaceID: workspaceID,
                inheritanceMode: .useGlobalSettings
            ),
            .global
        )
        XCTAssertEqual(
            AgentModelsEditingScope.resolve(
                workspaceID: workspaceID,
                inheritanceMode: .useWorkspaceOverrides
            ),
            .workspace(workspaceID)
        )
    }

    func testQuickApplyGlobalTargetPreservesWorkspaceProfileAndUsesWorkspaceBookkeeping() throws {
        let fixture = try makeFixture()
        let workspace = WorkspaceModel(name: "Global Project", repoPaths: [])
        let sentinel = AIModel.claude4Sonnet.rawValue
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: sentinel,
                preferredComposeModelRaw: sentinel
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fixture.store.setWorkspaceAgentModelsProfile(
            workspaceID: workspace.id,
            profile: AgentModelsSettingsProfile(
                planningModelRaw: sentinel,
                preferredComposeModelRaw: sentinel
            )
        )
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: workspace.id,
            mode: .useGlobalSettings
        )
        let manager = makeWorkspaceManager(workspaces: [workspace])
        let viewModel = RecommendationWizardViewModel(
            engine: fixture.engine,
            settingsStore: fixture.store,
            workspaceManager: manager
        )
        var receivedNotifications: [Notification] = []
        let notificationCancellable = NotificationCenter.default.publisher(for: .recommendationsDidApply)
            .filter { ($0.object as? RecommendationWizardViewModel) === viewModel }
            .sink { receivedNotifications.append($0) }
        defer { notificationCancellable.cancel() }

        XCTAssertEqual(viewModel.agentModelsScopeLabel, "Agent Models: Global settings")
        XCTAssertTrue(viewModel.canApplyRecommendations)
        XCTAssertTrue(viewModel.applyActionScopeLabels.contains("Agent Models: Global settings"))
        XCTAssertTrue(viewModel.applyActionScopeLabels.contains("MCP Presets: Global settings"))

        viewModel.applyAllRecommendations()

        XCTAssertEqual(fixture.store.globalAgentModelsProfile().planningModelRaw, AIModel.gpt54Pro.rawValue)
        XCTAssertEqual(
            fixture.store.workspaceAgentModelsProfile(for: workspace.id)?.planningModelRaw,
            sentinel
        )
        XCTAssertTrue(fixture.engine.hasCompletedRecently(workspaceID: workspace.id))
        XCTAssertEqual(receivedNotifications.count, 1)
        let notification = try XCTUnwrap(receivedNotifications.first)
        XCTAssertEqual(
            notification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String,
            AgentModelsSettingsNotification.Scope.global.rawValue
        )
        XCTAssertEqual(notification.userInfo?[AgentModelsSettingsNotification.sourceWorkspaceIDKey] as? UUID, workspace.id)
        XCTAssertNil(notification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey])
    }

    func testInheritanceChangeRecomputesWorkspaceTargetBeforeQuickApply() throws {
        let fixture = try makeFixture()
        let workspace = WorkspaceModel(name: "Scoped Project", repoPaths: [])
        let sentinel = AIModel.claude4Sonnet.rawValue
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: sentinel,
                preferredComposeModelRaw: sentinel
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fixture.store.setWorkspaceAgentModelsProfile(
            workspaceID: workspace.id,
            profile: AgentModelsSettingsProfile(
                planningModelRaw: sentinel,
                preferredComposeModelRaw: sentinel
            )
        )
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: workspace.id,
            mode: .useGlobalSettings
        )
        let manager = makeWorkspaceManager(workspaces: [workspace])
        let viewModel = RecommendationWizardViewModel(
            engine: fixture.engine,
            settingsStore: fixture.store,
            workspaceManager: manager
        )
        var receivedNotifications: [Notification] = []
        let notificationCancellable = NotificationCenter.default.publisher(for: .recommendationsDidApply)
            .filter { ($0.object as? RecommendationWizardViewModel) === viewModel }
            .sink { receivedNotifications.append($0) }
        defer { notificationCancellable.cancel() }

        XCTAssertEqual(viewModel.agentModelsScopeLabel, "Agent Models: Global settings")
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: workspace.id,
            mode: .useWorkspaceOverrides
        )

        XCTAssertEqual(viewModel.currentStep, .intro)
        XCTAssertEqual(viewModel.agentModelsScopeLabel, "Agent Models: Workspace — Scoped Project")
        XCTAssertTrue(viewModel.canApplyRecommendations)

        viewModel.applyAllRecommendations()

        XCTAssertEqual(fixture.store.globalAgentModelsProfile().planningModelRaw, sentinel)
        XCTAssertEqual(
            fixture.store.workspaceAgentModelsProfile(for: workspace.id)?.planningModelRaw,
            AIModel.gpt54Pro.rawValue
        )
        XCTAssertEqual(receivedNotifications.count, 2)
        let workspaceNotification = try XCTUnwrap(receivedNotifications.first { notification in
            notification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String
                == AgentModelsSettingsNotification.Scope.workspace.rawValue
        })
        let globalNotification = try XCTUnwrap(receivedNotifications.first { notification in
            notification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String
                == AgentModelsSettingsNotification.Scope.global.rawValue
        })
        XCTAssertEqual(
            workspaceNotification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey] as? UUID,
            workspace.id
        )
        XCTAssertNil(globalNotification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey])
        for notification in receivedNotifications {
            XCTAssertEqual(
                notification.userInfo?[AgentModelsSettingsNotification.sourceWorkspaceIDKey] as? UUID,
                workspace.id
            )
        }
    }

    func testPresetOnlyWorkspaceTargetNotifiesGlobalScope() throws {
        let fixture = try makeFixture()
        let workspace = WorkspaceModel(name: "Preset Project", repoPaths: [])
        let recommended = AIModel.gpt54Pro.rawValue
        fixture.store.setWorkspaceAgentModelsProfile(
            workspaceID: workspace.id,
            profile: AgentModelsSettingsProfile(
                planningModelRaw: recommended,
                preferredComposeModelRaw: recommended
            )
        )
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: workspace.id,
            mode: .useWorkspaceOverrides
        )
        let manager = makeWorkspaceManager(workspaces: [workspace])
        let viewModel = RecommendationWizardViewModel(
            engine: fixture.engine,
            settingsStore: fixture.store,
            workspaceManager: manager
        )
        var receivedNotifications: [Notification] = []
        let notificationCancellable = NotificationCenter.default.publisher(for: .recommendationsDidApply)
            .filter { ($0.object as? RecommendationWizardViewModel) === viewModel }
            .sink { receivedNotifications.append($0) }
        defer { notificationCancellable.cancel() }

        XCTAssertEqual(viewModel.applyActionScopeLabels, [viewModel.mcpPresetsScopeLabel])
        viewModel.nextStep()
        XCTAssertEqual(viewModel.currentStep, .presets)

        viewModel.applyCurrentStep()

        XCTAssertTrue(fixture.store.mcpShowModelPresets())
        XCTAssertTrue(fixture.store.mcpTemporarilyDisablePresets())
        XCTAssertEqual(receivedNotifications.count, 1)
        let notification = try XCTUnwrap(receivedNotifications.first)
        XCTAssertEqual(
            notification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String,
            AgentModelsSettingsNotification.Scope.global.rawValue
        )
        XCTAssertNil(notification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey])
        XCTAssertEqual(
            notification.userInfo?[AgentModelsSettingsNotification.sourceWorkspaceIDKey] as? UUID,
            workspace.id
        )
    }

    func testWorkspaceSwitchCannotApplyPreviousWorkspaceRecommendations() throws {
        let fixture = try makeFixture()
        let first = WorkspaceModel(name: "First", repoPaths: [])
        let second = WorkspaceModel(name: "Second", repoPaths: [])
        let sentinel = AIModel.claude4Sonnet.rawValue
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: sentinel,
                preferredComposeModelRaw: sentinel
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        for workspaceID in [first.id, second.id] {
            fixture.store.setWorkspaceAgentModelsProfile(
                workspaceID: workspaceID,
                profile: AgentModelsSettingsProfile(
                    planningModelRaw: sentinel,
                    preferredComposeModelRaw: sentinel
                )
            )
        }
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: first.id,
            mode: .useGlobalSettings
        )
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: second.id,
            mode: .useWorkspaceOverrides
        )
        let manager = makeWorkspaceManager(workspaces: [first, second])
        let viewModel = RecommendationWizardViewModel(
            engine: fixture.engine,
            settingsStore: fixture.store,
            workspaceManager: manager
        )

        XCTAssertEqual(viewModel.agentModelsScopeLabel, "Agent Models: Global settings")
        manager.activeWorkspace = second
        XCTAssertEqual(manager.activeWorkspaceID, second.id)

        XCTAssertEqual(viewModel.currentStep, .intro)
        XCTAssertEqual(viewModel.agentModelsScopeLabel, "Agent Models: Workspace — Second")
        XCTAssertTrue(viewModel.canApplyRecommendations)

        viewModel.applyAllRecommendations()

        XCTAssertEqual(fixture.store.globalAgentModelsProfile().planningModelRaw, sentinel)
        XCTAssertEqual(
            fixture.store.workspaceAgentModelsProfile(for: first.id)?.planningModelRaw,
            sentinel
        )
        XCTAssertEqual(
            fixture.store.workspaceAgentModelsProfile(for: second.id)?.planningModelRaw,
            AIModel.gpt54Pro.rawValue
        )
    }

    private func makeFixture() throws -> (
        store: GlobalSettingsStore,
        engine: AutoRecommendationEngine,
        apiSettings: APISettingsViewModel
    ) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecommendationWizardScopedTargetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }

        let suiteName = "RecommendationWizardScopedTargetTests.\(UUID().uuidString)"
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
        store.setGlobalRecommendationProviderFilter([.openAI])
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
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

    private func makeWorkspaceManager(workspaces: [WorkspaceModel]) -> WorkspaceManagerViewModel {
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        manager.workspaces = workspaces
        manager.activeWorkspace = workspaces.first
        return manager
    }
}
