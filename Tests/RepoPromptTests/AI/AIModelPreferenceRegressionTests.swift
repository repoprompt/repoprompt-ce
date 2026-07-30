import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class AIModelPreferenceRegressionTests: XCTestCase {
    @MainActor
    func testPlanningDropdownInvalidStateMatrixDoesNotDisplayFirstAvailableModel() {
        let availableModels: [AIModel] = [.codexCustom(name: "gpt-5.5-low")]
        let rows = [
            (rawValue: "", expectedDisplayName: "Select an Oracle model"),
            (rawValue: "legacy-oracle-model", expectedDisplayName: "Invalid Oracle model")
        ]

        for row in rows {
            let displayName = AIModelDropdown.displayName(
                forRawValue: row.rawValue,
                destinationID: "planningModel",
                availableModels: availableModels,
                customOpenRouterModels: []
            )

            XCTAssertEqual(displayName, row.expectedDisplayName, row.rawValue)
            XCTAssertNotEqual(displayName, availableModels[0].displayName, row.rawValue)
        }
    }

    @MainActor
    func testNonPlanningDropdownRetainsFirstAvailableFallbackForInvalidRaw() {
        let availableModels: [AIModel] = [.codexCustom(name: "gpt-5.5-low")]

        let displayName = AIModelDropdown.displayName(
            forRawValue: "legacy-chat-model",
            destinationID: "chatModel",
            availableModels: availableModels,
            customOpenRouterModels: []
        )

        XCTAssertEqual(displayName, availableModels[0].displayName)
    }

    @MainActor
    func testSettingsSyncClearsStaleModelRawWhenPersistedValueIsEmptyOrMissing() {
        XCTAssertEqual(
            PromptViewModel.modelRawAfterSettingsSync(currentRaw: "stale-planning", persistedRaw: ""),
            ""
        )
        XCTAssertEqual(
            PromptViewModel.modelRawAfterSettingsSync(currentRaw: "stale-preferred", persistedRaw: nil),
            ""
        )
        XCTAssertEqual(
            PromptViewModel.modelRawAfterSettingsSync(currentRaw: "stale", persistedRaw: "gpt-5.5-low"),
            "gpt-5.5-low"
        )
    }

    func testStrictOraclePlanningResolutionRejectsEmptyInvalidAndUnavailableRaw() {
        let empty = PromptViewModel.mcpOraclePlanningModelResolution(rawValue: "", isModelAvailable: { _ in true })
        XCTAssertEqual(empty, .unconfigured)
        XCTAssertEqual(
            PromptViewModel.mcpOraclePlanningModelErrorMessage(for: empty),
            "MCP Oracle model is not configured. Select an Oracle model in the Models settings before using ask_oracle."
        )

        let invalid = PromptViewModel.mcpOraclePlanningModelResolution(
            rawValue: "legacy-oracle-model",
            isModelAvailable: { _ in true }
        )
        XCTAssertEqual(invalid, .invalid(rawValue: "legacy-oracle-model"))
        XCTAssertEqual(
            PromptViewModel.mcpOraclePlanningModelErrorMessage(for: invalid),
            "MCP Oracle model raw value 'legacy-oracle-model' is invalid. Select a valid Oracle model in the Models settings before using ask_oracle."
        )

        let unavailableModel = AIModel.codexCustom(name: "gpt-5.5-low")
        let unavailable = PromptViewModel.mcpOraclePlanningModelResolution(
            rawValue: unavailableModel.rawValue,
            isModelAvailable: { _ in false }
        )
        XCTAssertEqual(unavailable, .unavailable(unavailableModel))
        XCTAssertEqual(
            PromptViewModel.mcpOraclePlanningModelErrorMessage(for: unavailable),
            "MCP oracle model '\(unavailableModel.displayName)' is not available."
        )
    }

    func testStrictOraclePlanningResolutionReturnsConfiguredModelOnlyWhenRawParsesAndIsAvailable() {
        let configuredModel = AIModel.codexCustom(name: "gpt-5.5-low")
        let resolved = PromptViewModel.mcpOraclePlanningModelResolution(
            rawValue: "  \(configuredModel.rawValue)  ",
            isModelAvailable: { model in model == configuredModel }
        )
        XCTAssertEqual(resolved, .configured(configuredModel))
    }

    // MARK: - Oracle reset-on-restart regression

    //
    // Reproduces the durable "Oracle resets to nothing after restart" bug: when the
    // sync-chat-with-Oracle toggle is on, a blank built-in-chat (preferredCompose) write
    // — produced by the transient fallback in PromptViewModel.pickDiffCapableFallback when
    // the model list is unhydrated — is mirrored into the GLOBAL Oracle planningModel and
    // eagerly persisted. planningModel is deliberately never auto-healed, so the blank
    // survives relaunch.

    @MainActor
    private func makeIsolatedStore(_ fileURL: URL) throws -> GlobalSettingsStore {
        let suiteName = "AIModelPreferenceRegressionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
    }

    @MainActor
    func testEmptyChatModelDoesNotBlankOracleAcrossRelaunchWhenSyncOn() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleResetRepro.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")

        let store = try makeIsolatedStore(fileURL)
        let model = AIModel.codexCustom(name: "gpt-5.5-high").rawValue

        // User has the same model for Oracle and Chat with sync on.
        store.setPlanningModelRaw(model, commit: true)
        store.setPreferredComposeModelRaw(model, commit: true)
        store.setSyncChatModelWithOracle(true)
        XCTAssertEqual(store.planningModelRaw(), model)
        XCTAssertEqual(store.preferredComposeModelRaw(), model)
        XCTAssertTrue(store.syncChatModelWithOracle())

        // Transient blank of the chat model (pickDiffCapableFallback's empty branch) routes
        // through here with honorSync=true while sync is on.
        store.setPreferredComposeModelRaw("", commit: true, honorSync: true)

        XCTAssertEqual(
            store.planningModelRaw(), model,
            "A blank chat model must not blank the Oracle planning model (Oracle is never auto-healed)"
        )

        // Whitespace-only is blank too — raw values can arrive from the MCP/app_settings API.
        store.setPreferredComposeModelRaw("   ", commit: true, honorSync: true)
        XCTAssertEqual(
            store.planningModelRaw(), model,
            "A whitespace-only chat model must not blank the Oracle either"
        )

        // Relaunch: a fresh store reading the same on-disk document must still have the Oracle.
        let reloaded = try makeIsolatedStore(fileURL)
        XCTAssertEqual(
            reloaded.planningModelRaw(), model,
            "Oracle planning model must survive relaunch"
        )
    }

    @MainActor
    func testRealChatModelStillMirrorsIntoOracleWhenSyncOn() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleMirrorKept.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")

        let store = try makeIsolatedStore(fileURL)
        let model = AIModel.codexCustom(name: "gpt-5.5-high").rawValue
        let newModel = AIModel.codexCustom(name: "gpt-5.5-low").rawValue

        store.setPlanningModelRaw(model, commit: true)
        store.setPreferredComposeModelRaw(model, commit: true)
        store.setSyncChatModelWithOracle(true)
        XCTAssertTrue(store.syncChatModelWithOracle())

        // A real (non-empty) chat model selection must still mirror into the Oracle when sync is on.
        store.setPreferredComposeModelRaw(newModel, commit: true, honorSync: true)
        XCTAssertEqual(store.planningModelRaw(), newModel)
    }
}
