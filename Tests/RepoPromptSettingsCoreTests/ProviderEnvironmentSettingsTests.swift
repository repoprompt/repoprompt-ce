import Foundation
@testable import RepoPromptSettingsCore
import XCTest

@MainActor
final class ProviderEnvironmentSettingsTests: XCTestCase {
    func testNamesAreExactValidatedAndNeverInterpretValuesOrWildcards() {
        XCTAssertEqual(ProviderEnvironmentNames.parsed("TOKEN, token TOKEN\nSSH_AUTH_SOCK"), ["SSH_AUTH_SOCK", "TOKEN", "token"])
        for invalid in ["TOKEN=value", "AWS_*", "1TOKEN", "A-B", "秘密"] {
            XCTAssertNil(ProviderEnvironmentNames.parsed(invalid), invalid)
        }
        XCTAssertEqual(ProviderEnvironmentNames.parsed(" \n,"), [])
    }

    func testOldDefaultsEmitNoFilteringFields() throws {
        let old = Data("{\"codexGoalSupportEnabled\":true}".utf8)
        let settings = try JSONDecoder().decode(GlobalScalarPreferences.AgentModeSettings.self, from: old)
        XCTAssertNil(settings.providerEnvironmentWithheldNames)
        XCTAssertNil(settings.providerEnvironmentPassthroughNames)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), ["codexGoalSupportEnabled"])
    }

    func testOptInRoundTripRemovalAndUnknownSettingsPreservation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "ProviderEnvironmentSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fileURL = directory.appendingPathComponent("settings.json")
        let document = GlobalSettingsDocument(scalarPreferences: GlobalScalarPreferences(agentMode: .init(codexGoalSupportEnabled: true)))
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        var scalars = try XCTUnwrap(raw["scalarPreferences"] as? [String: Any])
        var agentMode = try XCTUnwrap(scalars["agentMode"] as? [String: Any])
        agentMode["futureSetting"] = ["keep": true]
        agentMode["providerEnvironmentPassthroughNames"] = ["futureProvider": ["FUTURE_TOKEN"]]
        scalars["agentMode"] = agentMode
        raw["scalarPreferences"] = scalars
        try JSONSerialization.data(withJSONObject: raw).write(to: fileURL)
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        XCTAssertTrue(store.providerEnvironmentRemovedNames(for: "openCode").isEmpty)
        XCTAssertTrue(store.setProviderEnvironmentFiltering(
            withheldNames: ["TOKEN", "SSH_AUTH_SOCK", "TOKEN"], passthroughNames: ["TOKEN"], for: "openCode"
        ))
        XCTAssertEqual(store.providerEnvironmentRemovedNames(for: "openCode"), ["SSH_AUTH_SOCK"])
        XCTAssertEqual(store.providerEnvironmentRemovedNames(for: "cursor"), ["TOKEN", "SSH_AUTH_SOCK"])
        XCTAssertFalse(store.setProviderEnvironmentWithheldNames(["TOKEN=value"]))
        XCTAssertEqual(try fileStore.load().scalarPreferences?.agentMode?.providerEnvironmentWithheldNames, ["SSH_AUTH_SOCK", "TOKEN"])
        XCTAssertTrue(store.setProviderEnvironmentWithheldNames([]))
        XCTAssertTrue(store.setProviderEnvironmentPassthroughNames([], for: "openCode"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        let savedScalars = try XCTUnwrap(saved["scalarPreferences"] as? [String: Any])
        let savedAgentMode = try XCTUnwrap(savedScalars["agentMode"] as? [String: Any])
        XCTAssertEqual(savedAgentMode["futureSetting"] as? [String: Bool], ["keep": true])
        XCTAssertEqual(savedAgentMode["providerEnvironmentPassthroughNames"] as? [String: [String]], ["futureProvider": ["FUTURE_TOKEN"]])
        XCTAssertNil(savedAgentMode["providerEnvironmentWithheldNames"])
        XCTAssertEqual(savedAgentMode["codexGoalSupportEnabled"] as? Bool, true)
    }
}
