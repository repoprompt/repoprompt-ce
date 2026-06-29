import Foundation
@testable import RepoPrompt
import XCTest

final class DroidAgentToolPreferencesTests: XCTestCase {
    // MARK: - PermissionLevel Properties

    func testPermissionLevelRawValues() {
        XCTAssertEqual(DroidAgentToolPreferences.PermissionLevel.managedDefault.rawValue, "managedDefault")
        XCTAssertEqual(DroidAgentToolPreferences.PermissionLevel.fullAccess.rawValue, "fullAccess")
    }

    func testPermissionLevelDisplayNames() {
        XCTAssertEqual(DroidAgentToolPreferences.PermissionLevel.managedDefault.displayName, "Default")
        XCTAssertEqual(DroidAgentToolPreferences.PermissionLevel.fullAccess.displayName, "Full Access")
    }

    func testPermissionLevelSessionModeIDs() {
        XCTAssertEqual(
            DroidAgentToolPreferences.PermissionLevel.managedDefault.sessionModeID,
            DroidAgentConfig.managedSessionModeID
        )
        XCTAssertEqual(
            DroidAgentToolPreferences.PermissionLevel.fullAccess.sessionModeID,
            DroidAgentConfig.managedFullAccessSessionModeID
        )
    }

    func testPermissionLevelWarningFlag() {
        XCTAssertFalse(DroidAgentToolPreferences.PermissionLevel.managedDefault.isWarning)
        XCTAssertTrue(DroidAgentToolPreferences.PermissionLevel.fullAccess.isWarning)
    }

    func testPermissionLevelAutoApproveFlag() {
        XCTAssertFalse(DroidAgentToolPreferences.PermissionLevel.managedDefault.acceptsPendingApprovalWhenActivated)
        XCTAssertTrue(DroidAgentToolPreferences.PermissionLevel.fullAccess.acceptsPendingApprovalWhenActivated)
    }

    func testPermissionLevelIconNames() {
        XCTAssertEqual(DroidAgentToolPreferences.PermissionLevel.managedDefault.iconName, "shield")
        XCTAssertEqual(DroidAgentToolPreferences.PermissionLevel.fullAccess.iconName, "exclamationmark.shield.fill")
    }

    // MARK: - PermissionLevel from sessionModeID

    func testFromSessionModeIDReturnsCorrectLevel() {
        XCTAssertEqual(
            DroidAgentToolPreferences.PermissionLevel.from(sessionModeID: DroidAgentConfig.managedSessionModeID),
            .managedDefault
        )
        XCTAssertEqual(
            DroidAgentToolPreferences.PermissionLevel.from(sessionModeID: DroidAgentConfig.managedFullAccessSessionModeID),
            .fullAccess
        )
    }

    func testFromSessionModeIDDefaultsToManagedDefaultForUnknownValues() {
        XCTAssertEqual(
            DroidAgentToolPreferences.PermissionLevel.from(sessionModeID: "unknown_mode"),
            .managedDefault
        )
        XCTAssertEqual(
            DroidAgentToolPreferences.PermissionLevel.from(sessionModeID: ""),
            .managedDefault
        )
    }

    // MARK: - UserDefaults Persistence

    func testSessionModeIDDefaultsToManagedDefault() {
        let defaults = makeIsolatedDefaults()
        let modeID = DroidAgentToolPreferences.sessionModeID(defaults: defaults, secureStore: nil)
        XCTAssertEqual(modeID, DroidAgentConfig.managedSessionModeID)
    }

    func testSetSessionModeIDPersistsAndReturnsCorrectValue() {
        let defaults = makeIsolatedDefaults()

        DroidAgentToolPreferences.setSessionModeID(
            DroidAgentConfig.managedFullAccessSessionModeID,
            defaults: defaults,
            secureStore: nil
        )
        let modeID = DroidAgentToolPreferences.sessionModeID(defaults: defaults, secureStore: nil)

        XCTAssertEqual(modeID, DroidAgentConfig.managedFullAccessSessionModeID)
    }

    func testSetSessionModeIDWithEmptyStringDefaultsToManagedDefault() {
        let defaults = makeIsolatedDefaults()

        DroidAgentToolPreferences.setSessionModeID("", defaults: defaults, secureStore: nil)
        let modeID = DroidAgentToolPreferences.sessionModeID(defaults: defaults, secureStore: nil)

        XCTAssertEqual(modeID, DroidAgentConfig.managedSessionModeID)
    }

    func testPermissionLevelDefaultsToManagedDefault() {
        let defaults = makeIsolatedDefaults()
        let level = DroidAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: nil)
        XCTAssertEqual(level, .managedDefault)
    }

    func testSetPermissionLevelPersistsAndReturnsCorrectValue() {
        let defaults = makeIsolatedDefaults()

        DroidAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults, secureStore: nil)
        let level = DroidAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: nil)

        XCTAssertEqual(level, .fullAccess)
    }

    func testSetPermissionLevelRoundTripsBackToManagedDefault() {
        let defaults = makeIsolatedDefaults()

        DroidAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults, secureStore: nil)
        DroidAgentToolPreferences.setPermissionLevel(.managedDefault, defaults: defaults, secureStore: nil)
        let level = DroidAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: nil)

        XCTAssertEqual(level, .managedDefault)
    }

    // MARK: - CaseIterable

    func testPermissionLevelCaseIterableIncludesAllCases() {
        let allCases = DroidAgentToolPreferences.PermissionLevel.allCases
        XCTAssertEqual(allCases.count, 2)
        XCTAssertTrue(allCases.contains(.managedDefault))
        XCTAssertTrue(allCases.contains(.fullAccess))
    }

    // MARK: - SecureDroidPermissionDocument

    func testSecureDroidPermissionDocumentDefaultsToManagedDefault() {
        let document = SecureDroidPermissionDocument()
        XCTAssertEqual(document.permissionLevel(), .managedDefault)
        XCTAssertEqual(document.sessionModeID(), DroidAgentConfig.managedSessionModeID)
    }

    func testSecureDroidPermissionDocumentFullAccessRoundTrip() {
        var document = SecureDroidPermissionDocument()
        document.permissionLevelRaw = DroidAgentToolPreferences.PermissionLevel.fullAccess.rawValue
        XCTAssertEqual(document.permissionLevel(), .fullAccess)
        XCTAssertEqual(document.sessionModeID(), DroidAgentConfig.managedFullAccessSessionModeID)
    }

    func testSecureDroidPermissionDocumentFailClosedDefaultsToManagedDefault() {
        let document = SecureDroidPermissionDocument.failClosedDocument()
        XCTAssertEqual(document.permissionLevel(), .managedDefault)
        XCTAssertEqual(document.schemaVersion, SecureDroidPermissionDocument.currentSchemaVersion)
    }

    func testSecureDroidPermissionDocumentNilRawDefaultsToManagedDefault() {
        var document = SecureDroidPermissionDocument()
        document.permissionLevelRaw = nil
        XCTAssertEqual(document.permissionLevel(), .managedDefault)
    }

    func testSecureDroidPermissionDocumentUnknownRawDefaultsToManagedDefault() {
        var document = SecureDroidPermissionDocument()
        document.permissionLevelRaw = "unknown_level"
        XCTAssertEqual(document.permissionLevel(), .managedDefault)
    }

    // MARK: - DroidAgentConfig Constants

    func testDroidAgentConfigSessionModeConstants() {
        XCTAssertEqual(DroidAgentConfig.managedSessionModeID, "repoprompt_acp")
        XCTAssertEqual(DroidAgentConfig.managedFullAccessSessionModeID, "repoprompt_acp_full_access")
        XCTAssertEqual(DroidAgentConfig.managedHeadlessSessionModeID, "repoprompt_headless")
        XCTAssertEqual(DroidAgentConfig.managedNoToolsSessionModeID, "repoprompt_no_tools")
    }

    func testDroidAgentConfigToolProfileSessionModeIDs() {
        XCTAssertEqual(DroidAgentConfig.ToolProfile.agentMode.sessionModeID, DroidAgentConfig.managedSessionModeID)
        XCTAssertEqual(DroidAgentConfig.ToolProfile.headless.sessionModeID, DroidAgentConfig.managedHeadlessSessionModeID)
        XCTAssertEqual(DroidAgentConfig.ToolProfile.noTools.sessionModeID, DroidAgentConfig.managedNoToolsSessionModeID)
    }

    func testDroidAgentConfigDefaultValues() {
        let config = DroidAgentConfig()
        XCTAssertEqual(config.commandName, "droid")
        XCTAssertEqual(config.additionalPathHints, CLIPathHints.droid)
        XCTAssertNil(config.modelString)
        XCTAssertFalse(config.enableDebugLogging)
        XCTAssertTrue(config.includeRepoPromptMCPServer)
        XCTAssertEqual(config.toolProfile, .headless)
        XCTAssertEqual(config.sessionModeID, DroidAgentConfig.managedHeadlessSessionModeID)
    }

    // MARK: - Helpers

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "DroidAgentToolPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
