@testable import RepoPromptApp
import XCTest

/// Regression coverage for the two Major defects in the Agent Models read-modify-write boundary.
///
/// Both need the view model's cache to disagree with the store, so these fixtures inject an
/// isolated `NotificationCenter`: the store posts on `.default`, so the view model never hears
/// the external write and stays stale by construction — exactly the window the bugs lived in.
@MainActor
final class AgentModelsSettingsViewModelStaleEditTests: XCTestCase {
    /// A stale editing scope must not redirect the write. Both setters replace every profile
    /// field, so writing global content into the workspace slot (or the reverse) silently
    /// replaced unrelated configuration.
    func testStaleEditingScopeWritesNeitherProfile() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let globalRaw = AIModel.gpt54Pro.rawValue
        let workspaceRaw = AIModel.claude4Sonnet.rawValue

        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(planningModelRaw: globalRaw),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: workspaceID,
            mode: .useWorkspaceOverrides
        )
        fixture.store.setWorkspaceAgentModelsProfile(
            workspaceID: workspaceID,
            profile: AgentModelsSettingsProfile(planningModelRaw: workspaceRaw)
        )

        // Caches `.workspace` as the editing scope.
        let viewModel = makeViewModel(fixture: fixture, workspaceID: workspaceID)
        XCTAssertEqual(viewModel.editingScope, .workspace(workspaceID))

        // Another surface routes this workspace back to global; the view model does not hear it.
        fixture.store.setWorkspaceAgentModelsInheritanceMode(
            workspaceID: workspaceID,
            mode: .useGlobalSettings
        )

        viewModel.setOracleModel(raw: AIModel.gpt54.rawValue)

        XCTAssertEqual(
            fixture.store.globalAgentModelsProfile().planningModelRaw,
            globalRaw,
            "A stale-scope edit must not overwrite the global profile."
        )
        XCTAssertEqual(
            fixture.store.workspaceAgentModelsProfile(for: workspaceID)?.planningModelRaw,
            workspaceRaw,
            "A stale-scope edit must not overwrite the workspace profile either."
        )
        XCTAssertEqual(
            viewModel.editingScope,
            .global,
            "Rejection must resync the view model to the store."
        )
    }

    /// An index bounds-checked against the cached roster must never reach a shorter live roster.
    /// This trapped at runtime before the fix.
    func testStaleOracleIndexDoesNotTrapOrWrite() throws {
        let fixture = try makeFixture()
        let first = AIModel.gpt54Pro.rawValue
        let second = AIModel.claude4Sonnet.rawValue

        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(
                planningModelRaw: first,
                additionalOracleModelRaws: [first, second]
            ),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )

        // Caches a two-entry roster.
        let viewModel = makeViewModel(fixture: fixture, workspaceID: nil)
        XCTAssertEqual(viewModel.additionalOracleModelRaws.count, 2)

        // MCP or a second window shrinks the live roster; the view model does not hear it.
        fixture.store.setGlobalAgentModelsProfile(
            AgentModelsSettingsProfile(planningModelRaw: first, additionalOracleModelRaws: []),
            contextBuilderWriteIntent: .preserveExistingOwnership
        )

        viewModel.removeOracle(at: 1)

        XCTAssertEqual(
            fixture.store.globalAgentModelsProfile().additionalOracleModelRaws,
            [],
            "A stale index must be rejected rather than applied to the live roster."
        )
        XCTAssertEqual(viewModel.additionalOracleModelRaws, [])
    }

    // MARK: - Fixture

    private func makeViewModel(
        fixture: (store: GlobalSettingsStore, apiSettings: APISettingsViewModel),
        workspaceID: UUID?
    ) -> AgentModelsSettingsViewModel {
        AgentModelsSettingsViewModel(
            apiSettingsVM: fixture.apiSettings,
            workspaceID: workspaceID,
            settingsManager: fixture.store,
            settingsStore: fixture.store,
            notificationCenter: NotificationCenter()
        )
    }

    private func makeFixture() throws -> (store: GlobalSettingsStore, apiSettings: APISettingsViewModel) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentModelsSettingsViewModelStaleEditTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temp) }

        let suiteName = "AgentModelsSettingsViewModelStaleEditTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

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
        return (store, apiSettings)
    }
}
