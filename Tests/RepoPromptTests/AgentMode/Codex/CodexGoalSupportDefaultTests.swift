import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class CodexGoalSupportDefaultTests: XCTestCase {
    override func setUp() {
        super.setUp()
        resetTestingOverrides()
    }

    override func tearDown() {
        resetTestingOverrides()
        super.tearDown()
    }

    func testMissingUserDefaultsGoalKeyDefaultsEnabled() throws {
        let defaults = try makeIsolatedDefaults()

        XCTAssertNil(defaults.object(forKey: "enableCodexGoalSupport"))
        XCTAssertTrue(CodexGoalSupport.isEnabled(defaults: defaults))
    }

    func testExplicitUserDefaultsGoalFalseDisablesSupport() throws {
        try skipIfEnvironmentFlagEnabled("RP_CODEX_GOALS")
        let defaults = try makeIsolatedDefaults()
        defaults.set(false, forKey: "enableCodexGoalSupport")

        XCTAssertFalse(CodexGoalSupport.isEnabled(defaults: defaults))
    }

    func testExplicitUserDefaultsGoalTrueEnablesSupport() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(true, forKey: "enableCodexGoalSupport")

        XCTAssertTrue(CodexGoalSupport.isEnabled(defaults: defaults))
    }

    func testMissingUserDefaultsReasoningSummariesKeyDefaultsDisabled() throws {
        let defaults = try makeIsolatedDefaults()

        XCTAssertNil(defaults.object(forKey: CodexReasoningSummaries.defaultsKey))
        XCTAssertFalse(CodexReasoningSummaries.isEnabled(defaults: defaults))
    }

    func testExplicitUserDefaultsReasoningSummariesTrueEnablesSummaries() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(true, forKey: CodexReasoningSummaries.defaultsKey)

        XCTAssertTrue(CodexReasoningSummaries.isEnabled(defaults: defaults))
    }

    func testExplicitUserDefaultsReasoningSummariesFalseDisablesSummaries() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(false, forKey: CodexReasoningSummaries.defaultsKey)

        XCTAssertFalse(CodexReasoningSummaries.isEnabled(defaults: defaults))
    }

    func testMissingUserDefaultsMemoriesKeyDefaultsDisabled() throws {
        let defaults = try makeIsolatedDefaults()

        XCTAssertNil(defaults.object(forKey: CodexMemories.defaultsKey))
        XCTAssertFalse(CodexAgentModeBooleanPreference.memories.isEnabled(defaults: defaults))
    }

    func testInjectedUserDefaultsMemoriesPreferencePersistsOptIn() throws {
        let defaults = try makeIsolatedDefaults()

        CodexAgentModeBooleanPreference.memories.setEnabled(true, defaults: defaults)

        XCTAssertEqual(defaults.object(forKey: CodexMemories.defaultsKey) as? Bool, true)
        XCTAssertTrue(CodexAgentModeBooleanPreference.memories.isEnabled(defaults: defaults))
    }

    func testMissingUserDefaultsCapabilityKeysDefaultDisabled() throws {
        let defaults = try makeIsolatedDefaults()
        let preferences: [CodexAgentModeBooleanPreference] = [
            .apps,
            .plugins,
            .mcpElicitation,
            .toolSuggestions
        ]

        for (capability, preference) in zip(CodexCapabilityPreference.allCases, preferences) {
            XCTAssertNil(defaults.object(forKey: capability.defaultsKey))
            XCTAssertFalse(preference.isEnabled(defaults: defaults))
        }
    }

    func testMissingGlobalSettingsGoalScalarDefaultsEnabled() throws {
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init())
        ))

        XCTAssertTrue(store.codexGoalSupportEnabled())
    }

    func testExplicitGlobalSettingsGoalFalseDisablesSupport() throws {
        try skipIfEnvironmentFlagEnabled("RP_CODEX_GOALS")
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init(codexGoalSupportEnabled: false))
        ))

        XCTAssertFalse(store.codexGoalSupportEnabled())
    }

    func testExplicitGlobalSettingsGoalTrueEnablesSupport() throws {
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init(codexGoalSupportEnabled: true))
        ))

        XCTAssertTrue(store.codexGoalSupportEnabled())
    }

    func testMissingGlobalSettingsReasoningSummariesScalarDefaultsDisabled() throws {
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init())
        ))

        XCTAssertFalse(store.codexReasoningSummariesEnabled())
    }

    func testExplicitGlobalSettingsReasoningSummariesTrueEnablesSummaries() throws {
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init(codexReasoningSummariesEnabled: true))
        ))

        XCTAssertTrue(store.codexReasoningSummariesEnabled())
    }

    func testExplicitGlobalSettingsReasoningSummariesFalseDisablesSummaries() throws {
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init(codexReasoningSummariesEnabled: false))
        ))

        XCTAssertFalse(store.codexReasoningSummariesEnabled())
    }

    func testMissingGlobalSettingsMemoriesScalarDefaultsDisabled() throws {
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init())
        ))

        XCTAssertFalse(store.codexMemoriesEnabled())
    }

    func testGlobalSettingsMemoriesOptInPersistsAcrossReload() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMemoriesPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }
        let fileStore = GlobalSettingsFileStore(fileURL: temp.appendingPathComponent("Settings/globalSettings.json"))
        try fileStore.save(GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init())
        ))
        let defaults = try makeIsolatedDefaults()
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        store.setCodexMemoriesEnabled(true)

        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertTrue(reloaded.codexMemoriesEnabled())
        XCTAssertEqual(try fileStore.load().scalarPreferences?.agentMode?.codexMemoriesEnabled, true)
    }

    func testMissingGlobalSettingsCapabilityScalarsDefaultDisabled() throws {
        let store = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init())
        ))

        XCTAssertFalse(store.codexAppsEnabled())
        XCTAssertFalse(store.codexPluginsEnabled())
        XCTAssertFalse(store.codexMCPElicitationEnabled())
        XCTAssertFalse(store.codexToolSuggestionsEnabled())
    }

    func testGlobalSettingsCapabilityChoicesPersistIndependentlyAcrossReload() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexCapabilityPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }
        let fileStore = GlobalSettingsFileStore(fileURL: temp.appendingPathComponent("Settings/globalSettings.json"))
        try fileStore.save(GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init())
        ))
        let defaults = try makeIsolatedDefaults()
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)

        store.setCodexAppsEnabled(true)
        store.setCodexPluginsEnabled(false)
        store.setCodexMCPElicitationEnabled(true)
        store.setCodexToolSuggestionsEnabled(false)

        let reloaded = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertTrue(reloaded.codexAppsEnabled())
        XCTAssertFalse(reloaded.codexPluginsEnabled())
        XCTAssertTrue(reloaded.codexMCPElicitationEnabled())
        XCTAssertFalse(reloaded.codexToolSuggestionsEnabled())
        let persisted = try XCTUnwrap(fileStore.load().scalarPreferences?.agentMode)
        XCTAssertEqual(persisted.codexAppsEnabled, true)
        XCTAssertEqual(persisted.codexPluginsEnabled, false)
        XCTAssertEqual(persisted.codexMCPElicitationEnabled, true)
        XCTAssertEqual(persisted.codexToolSuggestionsEnabled, false)
    }

    func testProviderConversationCleanupActionDefaultsArchiveAndPersistsDelete() throws {
        let defaultStore = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init())
        ))
        XCTAssertEqual(defaultStore.providerConversationCleanupAction(), .archive)

        let deleteStore = try makeStore(document: GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: .init(providerConversationCleanupAction: "delete"))
        ))
        XCTAssertEqual(deleteStore.providerConversationCleanupAction(), .delete)
    }

    func testProviderConversationCleanupHandleFallsBackToProviderSessionID() throws {
        let result = AIStreamResult(
            type: "message_stop",
            text: nil,
            providerSessionID: " claude-session-1 "
        )

        let handle = try XCTUnwrap(AIQueriesService.cleanupHandle(for: result, model: .claudeCodeSonnet))
        XCTAssertEqual(handle.provider, "claudeCode")
        XCTAssertEqual(handle.sessionID, "claude-session-1")
        XCTAssertNil(handle.conversationID)
    }

    func testProviderConversationCleanupHandlePrefersExplicitHandle() throws {
        let explicit = ProviderConversationCleanupHandle(
            provider: "custom-provider",
            conversationID: "conversation-1"
        )
        let result = AIStreamResult(
            type: "message_stop",
            text: nil,
            providerSessionID: "session-ignored",
            cleanupHandle: explicit
        )

        let handle = try XCTUnwrap(AIQueriesService.cleanupHandle(for: result, model: .claudeCodeSonnet))
        XCTAssertEqual(handle, explicit)
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "CodexGoalSupportDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(document: GlobalSettingsDocument) throws -> GlobalSettingsStore {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexGoalSupportDefaultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }

        let fileURL = temp.appendingPathComponent("Settings/globalSettings.json")
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        try fileStore.save(document)
        return try GlobalSettingsStore(
            defaults: makeIsolatedDefaults(),
            fileStore: fileStore
        )
    }

    private func skipIfEnvironmentFlagEnabled(_ key: String) throws {
        let rawValue = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let rawValue, ["1", "true", "yes", "on"].contains(rawValue) {
            throw XCTSkip("\(key) force-enables this feature in the current environment.")
        }
    }

    private func resetTestingOverrides() {
        #if DEBUG
            CodexGoalSupport.setEnabledForTesting(nil)
        #endif
    }
}
