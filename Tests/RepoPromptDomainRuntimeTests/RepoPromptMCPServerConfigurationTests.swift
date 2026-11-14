import Foundation
import RepoPromptDomainRuntime
import XCTest

final class RepoPromptMCPServerConfigurationTests: XCTestCase {
    func testWireAndSettingsRepresentationsPreserveRawValues() throws {
        let configuration = RepoPromptMCPServerConfiguration(
            name: "custom",
            command: "/tmp/my executable",
            args: ["--flag", "a/b"],
            env: [.init(name: "SECOND", value: "2"), .init(name: "FIRST", value: "1")]
        )
        XCTAssertEqual(configuration.acpJSONObject["env"] as? [[String: String]], [
            ["name": "SECOND", "value": "2"],
            ["name": "FIRST", "value": "1"]
        ])
        XCTAssertEqual(configuration.settingsJSONObject["env"] as? [String: String], ["SECOND": "2", "FIRST": "1"])
        let json = try configuration.prettyPrintedWrappedSettingsJSON()
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let servers = try XCTUnwrap(decoded["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["custom"]?["command"] as? String, "/tmp/my executable")
        XCTAssertEqual(servers["custom"]?["args"] as? [String], ["--flag", "a/b"])
        XCTAssertTrue(json.contains("a/b"))
        XCTAssertNil(RepoPromptMCPServerConfiguration(command: "cmd").settingsJSONObject["env"])
    }
}
