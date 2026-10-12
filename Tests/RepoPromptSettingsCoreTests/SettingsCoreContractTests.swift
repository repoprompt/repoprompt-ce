import Foundation
@testable import RepoPromptSettingsCore
import XCTest

@MainActor
final class SettingsCoreContractTests: XCTestCase {
    func testChatModesAndDocumentBytesRemainPinned() throws {
        let workspaceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let document = GlobalSettingsDocument(
            updatedAt: Date(timeIntervalSince1970: 0),
            chatSettings: [workspaceID: ChatGlobalSettings(
                workspaceID: workspaceID,
                planActMode: .plan,
                manualPlanActMode: .edit
            )]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let expected = #"{"chatSettingsByWorkspaceID":{"00000000-0000-0000-0000-000000000001":{"codeMapUsage":"auto","fileTreeOption":"Auto","gitInclusion":"none","manualPlanActMode":"Edit","planActMode":"Plan","proFileEdits":false,"workspaceID":"00000000-0000-0000-0000-000000000001"}},"copySettingsByWorkspaceID":{},"globalDefaults":{},"schemaLineage":"repoprompt-ce.global-settings","schemaVersion":11,"updatedAt":"1970-01-01T00:00:00Z"}"#
        XCTAssertEqual(try encoder.encode(document), Data(expected.utf8))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(GlobalSettingsDocument.self, from: Data(expected.utf8))
        XCTAssertEqual(decoded.chatSettings[workspaceID], document.chatSettings[workspaceID])
        for (mode, literal) in [
            (SettingsPlanActMode.chat, #""Chat""#),
            (.plan, #""Plan""#),
            (.edit, #""Edit""#),
            (.review, #""Review""#)
        ] {
            XCTAssertEqual(try encoder.encode(mode), Data(literal.utf8))
            XCTAssertEqual(try decoder.decode(SettingsPlanActMode.self, from: Data(literal.utf8)), mode)
        }
    }

    func testComputerUseOptInIsAdditiveAndRoundTripsBothValues() throws {
        let decoder = JSONDecoder()
        let oldSettings = try decoder.decode(GlobalScalarPreferences.AgentModeSettings.self, from: Data("{}".utf8))
        XCTAssertNil(oldSettings.codexComputerUseEnabled)
        for enabled in [false, true] {
            var preferences = GlobalScalarPreferences()
            preferences.agentMode = .init(codexComputerUseEnabled: enabled)
            let document = GlobalSettingsDocument(scalarPreferences: preferences)
            let bytes = try JSONEncoder().encode(document)
            let decoded = try decoder.decode(GlobalSettingsDocument.self, from: bytes)
            XCTAssertEqual(decoded.scalarPreferences?.agentMode?.codexComputerUseEnabled, enabled)
        }
    }

    func testIgnoreFacetPreservesEmptyOverrideAndReflectsDeferredWrites() throws {
        try withStore { store, fileStore in
            let reader: any GlobalIgnoreSettingsProviding = store
            let original = reader.globalIgnoreSettingsSnapshot()
            XCTAssertEqual(original.globalIgnoreDefaults, "")
            XCTAssertTrue(original.respectRepoIgnore)
            XCTAssertTrue(original.respectCursorignore)
            XCTAssertTrue(original.enableHierarchicalIgnores)

            store.setRespectCursorignore(false, commit: false)
            store.setEnableHierarchicalIgnores(false, commit: false)
            store.setGlobalIgnoreDefaults("**/fixture/", commit: false)
            let changed = reader.globalIgnoreSettingsSnapshot()
            XCTAssertEqual(changed.globalIgnoreDefaults, "**/fixture/")
            XCTAssertFalse(changed.respectCursorignore)
            XCTAssertFalse(changed.enableHierarchicalIgnores)
            XCTAssertEqual(original.globalIgnoreDefaults, "")
            XCTAssertEqual(fileStore.saveAttempts, 0)

            store.setGlobalIgnoreDefaults("")
            XCTAssertEqual(reader.globalIgnoreSettingsSnapshot().globalIgnoreDefaults, "")
            XCTAssertEqual(fileStore.document.scalarPreferences?.fileSystem?.globalIgnoreDefaults, "")
            XCTAssertEqual(fileStore.saveAttempts, 1)
        }
    }

    func testNotificationEventsRemainSynchronousAcrossDeferredAndFailedSaves() throws {
        try withStore { store, fileStore in
            var observed: [(GlobalSettingsEvent, Bool?, Int, GlobalSettingsPersistenceBlockReason?)] = []
            store.eventHandler = { event, source in
                observed.append((
                    event,
                    source.scalarPreferences.notifications?.enabled,
                    fileStore.saveAttempts,
                    source.persistenceBlockReason
                ))
            }
            store.updateNotificationSettings(commit: false) { $0.enabled = false }
            XCTAssertEqual(observed.count, 1)
            XCTAssertEqual(observed[0].0, .notificationPreferencesChanged)
            XCTAssertEqual(observed[0].1, false)
            XCTAssertEqual(observed[0].2, 0)

            store.updateNotificationSettings(commit: false) { $0.enabled = false }
            XCTAssertEqual(observed.count, 1)

            fileStore.failWrites = true
            store.updateNotificationSettings { $0.enabled = true }
            XCTAssertEqual(observed.count, 2)
            XCTAssertEqual(observed[1].0, .notificationPreferencesChanged)
            XCTAssertEqual(observed[1].1, true)
            XCTAssertEqual(observed[1].2, 1)
            XCTAssertEqual(observed[1].3, .saveFailed)
            XCTAssertNil(fileStore.document.scalarPreferences?.notifications)
        }
    }

    func testProcessEventAdapterAppliesToNonSharedStoresAndInstanceOverrideWins() throws {
        let previous = GlobalSettingsStore.applicationEventHandler
        defer { GlobalSettingsStore.applicationEventHandler = previous }
        var processEvents: [GlobalSettingsEvent] = []
        GlobalSettingsStore.applicationEventHandler = { event, _ in processEvents.append(event) }
        try withStore { store, _ in
            processEvents.removeAll()
            store.updateNotificationSettings(commit: false) { $0.enabled = false }
            XCTAssertEqual(processEvents, [.notificationPreferencesChanged])
            var instanceEvents: [GlobalSettingsEvent] = []
            store.eventHandler = { event, _ in instanceEvents.append(event) }
            store.updateNotificationSettings(commit: false) { $0.enabled = true }
            XCTAssertEqual(processEvents, [.notificationPreferencesChanged])
            XCTAssertEqual(instanceEvents, [.notificationPreferencesChanged])
        }
    }

    func testDiskFontScaleReloadUsesHostNormalizationWithoutSaving() throws {
        try withStore { store, fileStore in
            var ui = GlobalScalarPreferences.UISettings()
            ui.fontScaleBodySize = 123
            fileStore.document.scalarPreferences?.ui = ui
            let reloaded = store.reloadFontScaleBodySizeFromDisk { rawValue in
                XCTAssertEqual(rawValue, 123)
                return 16
            }
            XCTAssertEqual(reloaded, 16)
            XCTAssertEqual(store.scalarPreferences.ui?.fontScaleBodySize, 16)
            XCTAssertEqual(fileStore.saveAttempts, 0)
            XCTAssertEqual(fileStore.document.scalarPreferences?.ui?.fontScaleBodySize, 123)
        }
    }

    private func withStore(_ body: (GlobalSettingsStore, ContractFileStore) throws -> Void) throws {
        let suite = "SettingsCoreContractTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fileStore = ContractFileStore()
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertEqual(fileStore.saveAttempts, 0)
        try body(store, fileStore)
    }
}

private final class ContractFileStore: GlobalSettingsFileStoring {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("unused-settings-contract.json")
    var blockReason: GlobalSettingsPersistenceBlockReason?
    let hasPendingStartupMigration = false
    var saveAttempts = 0
    var failWrites = false
    var document = GlobalSettingsDocument(scalarPreferences: GlobalScalarPreferences(
        contextBuilder: .init(),
        fileSystem: .init(globalIgnoreDefaults: "")
    ))

    func load() throws -> GlobalSettingsDocument {
        document
    }

    func loadOrCreateDefault() -> GlobalSettingsDocument {
        document
    }

    func save(_ document: GlobalSettingsDocument) throws {
        saveAttempts += 1
        if failWrites {
            blockReason = .saveFailed
            throw CocoaError(.fileWriteUnknown)
        }
        self.document = document
    }

    func saveStartupMigrationPreservingUnknownFields(
        _ document: GlobalSettingsDocument,
        includeModelSelectionRepair _: Bool
    ) throws {
        try save(document)
    }

    func retryStartupMigrationPreservingUnknownFields(_ document: GlobalSettingsDocument) throws {
        try save(document)
    }

    func performUserInitiatedRecovery(replacementDocument _: GlobalSettingsDocument) -> Bool {
        false
    }

    func performUserInitiatedCompatibleImport() -> Bool {
        false
    }
}
