import Foundation
@testable import RepoPromptSettingsCore
import XCTest

/// Persistence contract for the opt-in Codex usage quota flag.
///
/// The flag is `Optional` so "never set" survives a round-trip and an older build can still
/// read the document. Production default is off: while unset or false, no quota client,
/// process, subscription, or polling exists.
@MainActor
final class CodexUsageQuotaSettingsTests: XCTestCase {
    func testDefaultsToOffWhenUnset() {
        let document = GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: GlobalScalarPreferences.AgentModeSettings())
        )
        XCTAssertNil(
            document.scalarPreferences?.agentMode?.codexUsageQuotaEnabled,
            "unset must stay unset rather than being written as false"
        )

        // The accessor's default is what production reads, and it is off.
        let settings = GlobalScalarPreferences.AgentModeSettings()
        XCTAssertEqual(settings.codexUsageQuotaEnabled ?? false, false)
        XCTAssertNil(settings.claudeUsageQuotaEnabled)
        XCTAssertFalse(settings.claudeUsageQuotaEnabled ?? false)
    }

    func testRoundTripsThroughDocumentEncoding() throws {
        for value in [true, false] {
            let agentMode = GlobalScalarPreferences.AgentModeSettings(codexUsageQuotaEnabled: value, claudeUsageQuotaEnabled: !value)
            let document = GlobalSettingsDocument(
                scalarPreferences: GlobalScalarPreferences(agentMode: agentMode)
            )
            let decoded = try JSONDecoder().decode(
                GlobalSettingsDocument.self,
                from: JSONEncoder().encode(document)
            )
            XCTAssertEqual(decoded.scalarPreferences?.agentMode?.codexUsageQuotaEnabled, value)
            XCTAssertEqual(decoded.scalarPreferences?.agentMode?.claudeUsageQuotaEnabled, !value)
        }
    }

    func testUnsetFlagIsNotEmittedIntoTheDocument() throws {
        let document = GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(
                agentMode: GlobalScalarPreferences.AgentModeSettings(codexGoalSupportEnabled: true)
            )
        )
        let data = try JSONEncoder().encode(document)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let scalarPreferences = try XCTUnwrap(raw["scalarPreferences"] as? [String: Any])
        let agentMode = try XCTUnwrap(scalarPreferences["agentMode"] as? [String: Any])
        XCTAssertNil(agentMode["claudeUsageQuotaEnabled"])
        XCTAssertNil(
            agentMode["codexUsageQuotaEnabled"],
            "an untouched optional must not be materialized on write"
        )
    }

    func testSiblingAgentModeSettingsSurviveToggling() throws {
        let agentMode = GlobalScalarPreferences.AgentModeSettings(
            codexGoalSupportEnabled: true,
            codexUsageQuotaEnabled: true,
            agentSessionHandoffInstructions: "keep me"
        )
        let document = GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: agentMode)
        )
        let decoded = try JSONDecoder().decode(
            GlobalSettingsDocument.self,
            from: JSONEncoder().encode(document)
        )
        XCTAssertEqual(decoded.scalarPreferences?.agentMode?.codexUsageQuotaEnabled, true)
        XCTAssertEqual(decoded.scalarPreferences?.agentMode?.codexGoalSupportEnabled, true)
        XCTAssertEqual(decoded.scalarPreferences?.agentMode?.agentSessionHandoffInstructions, "keep me")
    }
}

/// Master presentation switch and Claude account-usage consent are independent of each other
/// and of the legacy per-provider flags, except for the one-way display migration.
@MainActor
final class UsageLimitsDisplaySettingsTests: XCTestCase {
    private typealias AgentMode = GlobalScalarPreferences.AgentModeSettings

    func testUnsetMasterFollowsEitherLegacyOptInAndOtherwiseStaysOff() {
        let cases: [(AgentMode?, Bool)] = [
            (nil, false),
            (AgentMode(), false),
            (AgentMode(codexUsageQuotaEnabled: false, claudeUsageQuotaEnabled: false), false),
            (AgentMode(codexUsageQuotaEnabled: true), true),
            (AgentMode(claudeUsageQuotaEnabled: true), true),
            // An explicit choice always wins over the legacy derivation.
            (AgentMode(codexUsageQuotaEnabled: true, usageLimitsDisplayEnabled: false), false),
            (AgentMode(usageLimitsDisplayEnabled: true), true)
        ]
        for (settings, expected) in cases {
            XCTAssertEqual(
                GlobalSettingsStore.resolvedUsageLimitsDisplayEnabled(settings),
                expected,
                String(describing: settings)
            )
        }
    }

    func testReadingDerivedMasterPersistsNothingAndAuthorizesNoSource() throws {
        try withStore { store, fileStore in
            store.setClaudeUsageQuotaEnabled(true)
            XCTAssertTrue(store.usageLimitsDisplayEnabled(), "legacy Claude opt-in keeps usage visible")

            let persisted = try fileStore.load().scalarPreferences?.agentMode
            XCTAssertNil(persisted?.usageLimitsDisplayEnabled, "the derived value is never written")
            XCTAssertNil(store.claudeAccountUsageGrant(), "legacy passive opt-in never becomes account consent")
            XCTAssertFalse(store.codexUsageQuotaEnabled(), "presentation never enables a source")
        }
    }

    func testExplicitMasterAndGrantRoundTripIndependently() throws {
        try withStore { store, fileStore in
            let grant = ClaudeAccountUsageGrant(
                credentialProfileID: "/Users/example/.claude",
                grantedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
            store.setUsageLimitsDisplayEnabled(false)
            store.setClaudeAccountUsageGrant(grant)

            let persisted = try fileStore.load().scalarPreferences?.agentMode
            XCTAssertEqual(persisted?.usageLimitsDisplayEnabled, false)
            XCTAssertEqual(persisted?.claudeAccountUsageGrant, grant)
            XCTAssertFalse(store.usageLimitsDisplayEnabled())
            XCTAssertEqual(store.claudeAccountUsageGrant(), grant, "hiding usage does not revoke consent")

            store.setClaudeAccountUsageGrant(nil)
            XCTAssertNil(try fileStore.load().scalarPreferences?.agentMode?.claudeAccountUsageGrant)
            XCTAssertFalse(store.usageLimitsDisplayEnabled(), "revoking consent does not change presentation")
        }
    }

    func testGrantAppliesOnlyToItsOwnNonEmptyProfile() {
        let grant = ClaudeAccountUsageGrant(credentialProfileID: "/a/.claude", grantedAt: Date())
        XCTAssertTrue(grant.applies(toProfileID: "/a/.claude"))
        XCTAssertFalse(grant.applies(toProfileID: "/b/.claude"))
        XCTAssertFalse(ClaudeAccountUsageGrant(credentialProfileID: "", grantedAt: Date()).applies(toProfileID: ""))
    }

    func testGrantEncodesOnlyNonSecretFields() throws {
        let grant = ClaudeAccountUsageGrant(credentialProfileID: "/a/.claude", grantedAt: Date(timeIntervalSince1970: 0))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)) as? [String: Any])
        XCTAssertEqual(Set(raw.keys), ["credentialProfileID", "grantedAt"])
    }

    func testUnsetMasterAndGrantAreNotMaterializedOnWrite() throws {
        let document = GlobalSettingsDocument(
            scalarPreferences: GlobalScalarPreferences(agentMode: AgentMode(codexUsageQuotaEnabled: true))
        )
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        let agentMode = try XCTUnwrap((raw["scalarPreferences"] as? [String: Any])?["agentMode"] as? [String: Any])
        XCTAssertNil(agentMode["usageLimitsDisplayEnabled"])
        XCTAssertNil(agentMode["claudeAccountUsageGrant"])
    }

    private func withStore(_ body: (GlobalSettingsStore, GlobalSettingsFileStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageLimitsDisplaySettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "UsageLimitsDisplaySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fileStore = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        try body(GlobalSettingsStore(defaults: defaults, fileStore: fileStore), fileStore)
    }
}
