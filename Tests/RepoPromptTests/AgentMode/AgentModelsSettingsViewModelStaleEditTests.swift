import Combine
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSecureStorage
import RepoPromptSettingsCore
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

    /// A refreshed cache must not turn an older text draft into a valid write.
    func testGuidanceDraftCannotOverwriteProfileAfterCacheRefresh() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let viewModel = makeViewModel(fixture: fixture, workspaceID: workspaceID)
        viewModel.oracleReconciliationGuidanceDraft = "unsaved older draft"
        var external = fixture.store.globalAgentModelsProfile()
        external.oracleReconciliationGuidance = "new external guidance"
        external.preferredComposeModelRaw = AIModel.claude4Sonnet.rawValue
        fixture.store.setGlobalAgentModelsProfile(external, contextBuilderWriteIntent: .preserveExistingOwnership)
        // Rename forces synchronous refresh of the cache, without changing its editing scope.
        viewModel.updateWorkspaceContext(workspaceID: workspaceID, workspaceName: "Renamed")
        XCTAssertEqual(viewModel.profileSnapshot, external)

        XCTAssertFalse(viewModel.saveOracleReconciliationGuidanceDraft())
        XCTAssertEqual(fixture.store.globalAgentModelsProfile(), external)
        XCTAssertEqual(viewModel.oracleReconciliationGuidanceDraft, "unsaved older draft")
    }

    func testGuidanceSaveBlankAndRestoreDefaultPreserveScopedProfileAndOwnership() throws {
        for workspaceID in [nil, UUID()] {
            let fixture = try makeFixture()
            let global = AgentModelsSettingsProfile(
                planningModelRaw: AIModel.gpt54.rawValue,
                oracleReconciliationGuidance: "global rule",
                preferredComposeModelRaw: AIModel.claude4Sonnet.rawValue,
                mcpAgentRoleOverrides: ["engineer": "codex:fixture-model"]
            )
            fixture.store.setGlobalAgentModelsProfile(global, contextBuilderWriteIntent: .preserveExistingOwnership)
            var original = global
            if let workspaceID {
                original.oracleReconciliationGuidance = nil
                fixture.store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: original)
            }
            let ownership = fixture.store.globalDefaults.didUserSetDiscoverAgentDefaults
            let viewModel = makeViewModel(fixture: fixture, workspaceID: workspaceID)
            XCTAssertEqual(viewModel.oracleReconciliationGuidanceDraft, workspaceID == nil ? "global rule" : OracleGroupDeliveryContract.defaultReconciliationGuidance)
            let custom = "  Check evidence.\nKeep disagreements visible.  \n"
            viewModel.oracleReconciliationGuidanceDraft = custom
            XCTAssertEqual(fixture.store.effectiveAgentModelsProfile(workspaceID: workspaceID), original, "Typing must not persist.")
            if workspaceID == nil {
                // Switching ambient workspaces does not change a global draft's write destination.
                viewModel.updateWorkspaceContext(workspaceID: UUID(), workspaceName: "First")
                viewModel.updateWorkspaceContext(workspaceID: UUID(), workspaceName: "Second")
                XCTAssertEqual(viewModel.editingScope, .global)
            }
            XCTAssertTrue(viewModel.saveOracleReconciliationGuidanceDraft())
            var expected = original
            expected.oracleReconciliationGuidance = custom
            XCTAssertEqual(fixture.store.effectiveAgentModelsProfile(workspaceID: workspaceID), expected)
            XCTAssertEqual(viewModel.oracleReconciliationGuidanceDraft, custom)
            XCTAssertFalse(viewModel.isOracleGuidanceDraftDirty)

            viewModel.oracleReconciliationGuidanceDraft = " \t\n"
            XCTAssertTrue(viewModel.saveOracleReconciliationGuidanceDraft())
            expected.oracleReconciliationGuidance = nil
            XCTAssertEqual(fixture.store.effectiveAgentModelsProfile(workspaceID: workspaceID), expected)
            XCTAssertEqual(viewModel.oracleReconciliationGuidanceDraft, OracleGroupDeliveryContract.defaultReconciliationGuidance)
            viewModel.oracleReconciliationGuidanceDraft = custom
            XCTAssertTrue(viewModel.saveOracleReconciliationGuidanceDraft())
            XCTAssertTrue(viewModel.restoreDefaultOracleReconciliationGuidance())
            XCTAssertEqual(fixture.store.effectiveAgentModelsProfile(workspaceID: workspaceID), expected)
            XCTAssertEqual(fixture.store.globalDefaults.didUserSetDiscoverAgentDefaults, ownership)
            if workspaceID != nil { XCTAssertEqual(fixture.store.globalAgentModelsProfile(), global) }
        }
    }

    func testGuidanceLiveChangeRejectsSaveAndResetWithoutRetryUntilReload() throws {
        for restore in [false, true] {
            let fixture = try makeFixture()
            let viewModel = makeViewModel(fixture: fixture, workspaceID: nil)
            viewModel.oracleReconciliationGuidanceDraft = "older draft"
            var external = fixture.store.globalAgentModelsProfile()
            external.oracleReconciliationGuidance = "external rule"
            fixture.store.setGlobalAgentModelsProfile(external, contextBuilderWriteIntent: .preserveExistingOwnership)
            // Isolated notifications leave the cache stale: the existing live/cache guard must refuse.
            XCTAssertFalse(restore ? viewModel.restoreDefaultOracleReconciliationGuidance() : viewModel.saveOracleReconciliationGuidanceDraft())
            XCTAssertEqual(viewModel.profileSnapshot, external)
            XCTAssertTrue(viewModel.oracleGuidanceHasConflict)
            XCTAssertEqual(viewModel.oracleReconciliationGuidanceDraft, "older draft")
            XCTAssertFalse(viewModel.saveOracleReconciliationGuidanceDraft())
            XCTAssertFalse(viewModel.restoreDefaultOracleReconciliationGuidance())
            XCTAssertEqual(fixture.store.globalAgentModelsProfile(), external)
            viewModel.reloadOracleReconciliationGuidanceDraft()
            XCTAssertEqual(viewModel.oracleReconciliationGuidanceDraft, "external rule")
            XCTAssertFalse(viewModel.oracleGuidanceHasConflict)
            viewModel.oracleReconciliationGuidanceDraft = "new deliberate edit"
            XCTAssertTrue(viewModel.saveOracleReconciliationGuidanceDraft())
            XCTAssertEqual(fixture.store.globalAgentModelsProfile().oracleReconciliationGuidance, "new deliberate edit")
        }
    }

    func testGuidanceScopeChangeRejectsBothActionsWithoutOverwritingEitherProfile() throws {
        for destination in [nil, UUID()] {
            let fixture = try makeFixture()
            let workspaceID = UUID()
            // Equal guidance isolates actual write-destination identity from the text baseline.
            let original = AgentModelsSettingsProfile(oracleReconciliationGuidance: "same guidance")
            fixture.store.setGlobalAgentModelsProfile(original, contextBuilderWriteIntent: .preserveExistingOwnership)
            fixture.store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: original)
            if let destination {
                fixture.store.setWorkspaceAgentModelsProfile(workspaceID: destination, profile: original)
            }
            let viewModel = makeViewModel(fixture: fixture, workspaceID: workspaceID)
            viewModel.oracleReconciliationGuidanceDraft = "unsaved workspace draft"
            viewModel.updateWorkspaceContext(workspaceID: destination, workspaceName: "Other")
            XCTAssertEqual(viewModel.editingScope, destination.map(AgentModelsEditingScope.workspace) ?? .global)
            XCTAssertTrue(viewModel.oracleGuidanceHasConflict)
            XCTAssertFalse(viewModel.saveOracleReconciliationGuidanceDraft())
            XCTAssertFalse(viewModel.restoreDefaultOracleReconciliationGuidance())
            XCTAssertEqual(fixture.store.globalAgentModelsProfile(), original)
            XCTAssertEqual(fixture.store.workspaceAgentModelsProfile(for: workspaceID), original)
            if let destination { XCTAssertEqual(fixture.store.workspaceAgentModelsProfile(for: destination), original) }
            XCTAssertEqual(viewModel.oracleReconciliationGuidanceDraft, "unsaved workspace draft")
        }
    }

    func testGuidanceDraftPreservesRefreshedUnrelatedProfileEdits() throws {
        let fixture = try makeFixture()
        let workspaceID = UUID()
        let viewModel = makeViewModel(fixture: fixture, workspaceID: workspaceID)
        viewModel.oracleReconciliationGuidanceDraft = "pending guidance"
        var external = fixture.store.globalAgentModelsProfile()
        external.planningModelRaw = AIModel.gpt54.rawValue
        fixture.store.setGlobalAgentModelsProfile(external, contextBuilderWriteIntent: .preserveExistingOwnership)
        viewModel.updateWorkspaceContext(workspaceID: workspaceID, workspaceName: "Renamed")
        XCTAssertFalse(viewModel.oracleGuidanceHasConflict)
        XCTAssertEqual(viewModel.oracleReconciliationGuidanceDraft, "pending guidance")
        XCTAssertTrue(viewModel.saveOracleReconciliationGuidanceDraft())
        external.oracleReconciliationGuidance = "pending guidance"
        XCTAssertEqual(fixture.store.globalAgentModelsProfile(), external)
    }

    func testDirtyGuidanceDraftSurvivesSamePageAddOracleAndSave() throws {
        for workspaceID in [nil, UUID()] {
            let fixture = try makeFixture()
            let original = AgentModelsSettingsProfile(
                planningModelRaw: AIModel.gpt54.rawValue,
                oracleReconciliationGuidance: "original guidance"
            )
            fixture.store.setGlobalAgentModelsProfile(original, contextBuilderWriteIntent: .preserveExistingOwnership)
            if let workspaceID {
                fixture.store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: original)
            }
            let viewModel = makeViewModel(fixture: fixture, workspaceID: workspaceID)
            let draft = "  Pending guidance.\nKeep every disagreement.  "
            viewModel.oracleReconciliationGuidanceDraft = draft
            viewModel.addOracle()
            var expected = original
            expected.additionalOracleModelRaws = [AIModel.gpt54.rawValue]
            XCTAssertEqual(fixture.store.effectiveAgentModelsProfile(workspaceID: workspaceID), expected)
            XCTAssertEqual(viewModel.oracleReconciliationGuidanceDraft, draft)
            XCTAssertTrue(viewModel.isOracleGuidanceDraftDirty)
            XCTAssertFalse(viewModel.oracleGuidanceHasConflict)
            XCTAssertTrue(viewModel.saveOracleReconciliationGuidanceDraft())
            expected.oracleReconciliationGuidance = draft
            XCTAssertEqual(fixture.store.effectiveAgentModelsProfile(workspaceID: workspaceID), expected)
            XCTAssertFalse(viewModel.isOracleGuidanceDraftDirty)
            if workspaceID != nil { XCTAssertEqual(fixture.store.globalAgentModelsProfile(), original) }
        }
    }

    func testUncachedUnrelatedProfileEditStillRefusesGuidanceClickWithoutRetry() throws {
        let fixture = try makeFixture()
        let viewModel = makeViewModel(fixture: fixture, workspaceID: nil)
        viewModel.oracleReconciliationGuidanceDraft = "pending guidance"
        var external = fixture.store.globalAgentModelsProfile()
        external.planningModelRaw = AIModel.gpt54.rawValue
        fixture.store.setGlobalAgentModelsProfile(external, contextBuilderWriteIntent: .preserveExistingOwnership)
        // No cache refresh: the existing whole-profile live/cache guard must still refuse.
        XCTAssertFalse(viewModel.saveOracleReconciliationGuidanceDraft())
        XCTAssertEqual(viewModel.profileSnapshot, external)
        XCTAssertFalse(viewModel.oracleGuidanceHasConflict)
        XCTAssertEqual(viewModel.oracleReconciliationGuidanceDraft, "pending guidance")
        XCTAssertEqual(fixture.store.globalAgentModelsProfile(), external, "Refusing a stale click must not retry automatically.")
        XCTAssertTrue(viewModel.saveOracleReconciliationGuidanceDraft(), "A new explicit click uses the refreshed, unchanged guidance baseline.")
        external.oracleReconciliationGuidance = "pending guidance"
        XCTAssertEqual(fixture.store.globalAgentModelsProfile(), external)
    }

    func testNotificationsFollowCleanTextButRetainDirtyDraftOnConflict() async throws {
        let fixture = try makeFixture()
        let center = NotificationCenter()
        let viewModel = makeViewModel(fixture: fixture, workspaceID: nil, notificationCenter: center)
        for dirty in [false, true] {
            if dirty { viewModel.oracleReconciliationGuidanceDraft = "unsaved text" }
            var external = fixture.store.globalAgentModelsProfile()
            external.oracleReconciliationGuidance = dirty ? "second external rule" : "first external rule"
            fixture.store.setGlobalAgentModelsProfile(external, contextBuilderWriteIntent: .preserveExistingOwnership)
            let refreshed = expectation(description: "Profile notification delivered")
            let observation = viewModel.$profileSnapshot.dropFirst().sink { _ in refreshed.fulfill() }
            center.post(name: .agentModelsSettingsDidChange, object: nil)
            await fulfillment(of: [refreshed], timeout: 2)
            observation.cancel()
            XCTAssertEqual(viewModel.oracleReconciliationGuidanceDraft, dirty ? "unsaved text" : "first external rule")
            XCTAssertEqual(viewModel.oracleGuidanceHasConflict, dirty)
            XCTAssertEqual(viewModel.isOracleGuidanceDraftDirty, dirty)
        }
    }

    func testAcceptedGuidanceSaveCanRemainPendingInExistingPersistenceWarning() throws {
        var failWrites = false
        let fixture = try makeFixture(shouldFailSave: { failWrites })
        let viewModel = makeViewModel(fixture: fixture, workspaceID: nil)
        viewModel.oracleReconciliationGuidanceDraft = "pending save"
        failWrites = true
        XCTAssertTrue(viewModel.saveOracleReconciliationGuidanceDraft(), "Accepted in memory, not a durability receipt.")
        XCTAssertEqual(fixture.store.persistenceBlockReason, .saveFailed)
        XCTAssertEqual(fixture.store.globalAgentModelsProfile().oracleReconciliationGuidance, "pending save")
        XCTAssertEqual(viewModel.oracleReconciliationGuidanceDraft, "pending save")
        XCTAssertFalse(viewModel.oracleGuidanceHasConflict)
    }

    // MARK: - Fixture

    private func makeViewModel(
        fixture: (store: GlobalSettingsStore, apiSettings: APISettingsViewModel),
        workspaceID: UUID?,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> AgentModelsSettingsViewModel {
        AgentModelsSettingsViewModel(
            apiSettingsVM: fixture.apiSettings,
            workspaceID: workspaceID,
            settingsManager: fixture.store,
            settingsStore: fixture.store,
            notificationCenter: notificationCenter
        )
    }

    private func makeFixture(shouldFailSave: @escaping () -> Bool = { false }) throws -> (store: GlobalSettingsStore, apiSettings: APISettingsViewModel) {
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
                fileURL: temp.appendingPathComponent("Settings/globalSettings.json"),
                atomicWriter: { data, url in
                    if shouldFailSave() { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: url, options: .atomic)
                }
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
