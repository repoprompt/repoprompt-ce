@testable import RepoPromptApp
import XCTest

@MainActor
final class BackgroundComposeTabAdmissionTests: XCTestCase {
    func testBackgroundCreationCrossesLegacyLimitWithoutMutatingExistingTabs() async throws {
        let fixture = makeFixture(initialTabCount: 499)
        let originalWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        let originalTabIDs = originalWorkspace.composeTabs.map(\.id)
        let originalSessionIDsByTabID = Dictionary(
            uniqueKeysWithValues: originalWorkspace.composeTabs.map { ($0.id, $0.activeAgentSessionID) }
        )
        let originalActiveTabID = try XCTUnwrap(originalWorkspace.activeComposeTabID)
        let originalStashedTabs = originalWorkspace.stashedTabs

        for expectedCount in 500 ... 502 {
            let created = await fixture.prompt.createBackgroundComposeTab(
                strategy: .blank,
                name: "Background \(expectedCount)"
            )

            XCTAssertNotNil(created, "Background creation should reach \(expectedCount) tabs")
            XCTAssertEqual(fixture.manager.activeWorkspace?.composeTabs.count, expectedCount)
        }

        let finalWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        let existingTabs = Array(finalWorkspace.composeTabs.prefix(originalTabIDs.count))
        XCTAssertEqual(existingTabs.map(\.id), originalTabIDs)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: existingTabs.map { ($0.id, $0.activeAgentSessionID) }),
            originalSessionIDsByTabID
        )
        XCTAssertEqual(finalWorkspace.activeComposeTabID, originalActiveTabID)
        XCTAssertEqual(finalWorkspace.stashedTabs, originalStashedTabs)
    }

    private func makeFixture(initialTabCount: Int) -> (manager: WorkspaceManagerViewModel, prompt: PromptViewModel) {
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
        let tabs = (0 ..< initialTabCount).map { index in
            ComposeTabState(
                name: "Existing \(index)",
                lastModified: Date(timeIntervalSince1970: TimeInterval(index)),
                activeAgentSessionID: UUID()
            )
        }
        let stashed = StashedTab(
            tab: ComposeTabState(name: "Already stashed", activeAgentSessionID: UUID()),
            stashedAt: Date(timeIntervalSince1970: 1)
        )
        let workspace = WorkspaceModel(
            name: "Background compose admission",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: tabs,
            activeComposeTabID: tabs.last?.id,
            stashedTabs: [stashed]
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        prompt.loadComposeTabsFromWorkspace(workspace)
        return (manager, prompt)
    }
}
