import Combine
import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class GlobalSettingsCrossWindowPropagationTests: XCTestCase {
    /// Changing the Oracle model in one window's PromptViewModel must update every other
    /// window's cached value, because all windows share one `GlobalSettingsStore`. Defect:
    /// window A showed "fable" while every other window kept "gpt-5.5" until the app restarted.
    func testOracleModelChangePropagatesAcrossWindows() async throws {
        let store = try makeIsolatedStore()
        let windowA = makePromptViewModel(windowID: 1, store: store)
        let windowB = makePromptViewModel(windowID: 2, store: store)

        let baseline = windowB.planningModelName
        XCTAssertNotEqual(baseline, "sonnet", "test is only meaningful if B does not already hold sonnet")

        // Window A changes the Oracle model (writes through to the shared store).
        windowA.planningModelName = "sonnet"
        await drainMainQueue()

        XCTAssertEqual(
            windowB.planningModelName, "sonnet",
            "Oracle model change in one window must propagate to other windows live"
        )
    }

    /// The cross-window subscription must not feedback-loop: a single Oracle change re-seeds
    /// other windows but must not re-mutate the store (re-entrancy is guarded by
    /// `isSyncingSettings` and direct storage writes). Defect: a naive subscription could
    /// make every change cascade into unbounded store writes / UI churn.
    func testOraclePropagationDoesNotFeedbackLoop() async throws {
        let store = try makeIsolatedStore()
        let windowA = makePromptViewModel(windowID: 1, store: store)
        let windowB = makePromptViewModel(windowID: 2, store: store) // retained additional observer

        var storeEmissions = 0
        let cancellable = store.objectWillChange.sink { _ in storeEmissions += 1 }
        defer { cancellable.cancel() }

        windowA.planningModelName = "sonnet"
        await drainMainQueue()
        await drainMainQueue()

        XCTAssertLessThan(storeEmissions, 5, "cross-window re-sync must not feedback-loop into store writes")
        XCTAssertEqual(windowA.planningModelName, "sonnet")
        XCTAssertEqual(windowB.planningModelName, "sonnet")
    }

    func testContextBuilderPickerExplicitCommitPersistsDisplayedRuntimeFallback() async throws {
        let previousCodexConnected = UserDefaults.standard.object(forKey: "CodexCLIConnected")
        defer {
            if let previousCodexConnected {
                UserDefaults.standard.set(previousCodexConnected, forKey: "CodexCLIConnected")
            } else {
                UserDefaults.standard.removeObject(forKey: "CodexCLIConnected")
            }
        }
        UserDefaults.standard.set(true, forKey: "CodexCLIConnected")

        let store = try makeIsolatedStore()
        let prompt = makePromptViewModel(windowID: 1, store: store)
        prompt.apiSettingsViewModel?.test_completeContextBuilderProviderValidation(
            verifiedProviders: [.codexExec]
        )
        await drainMainQueue()

        prompt.contextBuilderAgent = .codexExec
        prompt.selectContextBuilderAgentModel(rawModel: AgentModel.gpt55CodexLow.rawValue)
        prompt.commitContextBuilderSettings()

        let persisted = store.persistedGlobalContextBuilderAgentSelection()
        XCTAssertEqual(persisted.agentRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(persisted.modelRaw, AgentModel.gpt55CodexLow.rawValue)
    }

    // NOTE: Context Builder agent propagation is exercised compositionally — the store-side
    // publish is covered by SettingsJSONOnlyPersistenceTests.testGlobalDefaultsSettersPublishObjectWillChange
    // and the VM-side subscription + re-seed is covered by testOracleModelChangePropagatesAcrossWindows
    // above (same `objectWillChange` subscription, same `syncGlobalDerivedSettingsFromStore`). The
    // agent-kind resolution itself is availability-gated and covered by ContextBuilderModelStartupSelectionTests.

    // MARK: - Helpers

    private func makeIsolatedStore() throws -> GlobalSettingsStore {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossWindowPropagation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let suiteName = "CrossWindowPropagation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
    }

    private func makePromptViewModel(windowID: Int, store: GlobalSettingsStore) -> PromptViewModel {
        let secureService = SecureKeysService(secureStorage: TestSecureStorageBackend(values: [:]))
        let keyManager = KeyManager(secureService: secureService)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        return PromptViewModel(
            fileManager: WorkspaceFilesViewModel(),
            apiSettingsViewModel: apiSettings,
            windowID: windowID,
            settingsManager: WindowSettingsManager(windowID: windowID, store: store)
        )
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1.0)
    }
}
