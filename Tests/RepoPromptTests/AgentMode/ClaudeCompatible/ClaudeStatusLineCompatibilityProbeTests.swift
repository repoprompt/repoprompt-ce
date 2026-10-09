#if DEBUG
    import Foundation
    @testable import RepoPromptApp
    import XCTest

    final class ClaudeStatusLineCompatibilityProbeTests: XCTestCase {
        func testRequiresExplicitOptInAndFirstPartyAndClaimsOnlyOnce() throws {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let arguments = ["app", "--claude-statusline-probe", root.appendingPathComponent("settings.json").path]
            XCTAssertEqual(ClaudeStatusLineCompatibilityProbe.claimSettingsArguments(launchArguments: [], isFirstParty: true), [])
            XCTAssertEqual(ClaudeStatusLineCompatibilityProbe.claimSettingsArguments(launchArguments: arguments, isFirstParty: false), [])
            XCTAssertEqual(ClaudeStatusLineCompatibilityProbe.claimSettingsArguments(launchArguments: arguments, isFirstParty: true, providerArguments: ["--settings", "existing"]), [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("claimed").path))
            XCTAssertEqual(ClaudeStatusLineCompatibilityProbe.claimSettingsArguments(launchArguments: arguments, isFirstParty: true), ["--settings", arguments[2]])
            XCTAssertEqual(ClaudeStatusLineCompatibilityProbe.claimSettingsArguments(launchArguments: arguments, isFirstParty: true), [])
        }

        func testRejectsSettingsWithOtherOverridesAndInsecureFiles() throws {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let settings = root.appendingPathComponent("settings.json")
            let arguments = ["app", "--claude-statusline-probe", settings.path]
            try Data(#"{"statusLine":{"type":"command","command":"echo probe"},"permissions":{}}"#.utf8).write(to: settings)
            XCTAssertEqual(ClaudeStatusLineCompatibilityProbe.claimSettingsArguments(launchArguments: arguments, isFirstParty: true), [])
            try Data(#"{"statusLine":{"type":"command","command":"echo probe"}}"#.utf8).write(to: settings)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path)
            XCTAssertEqual(ClaudeStatusLineCompatibilityProbe.claimSettingsArguments(launchArguments: arguments, isFirstParty: true), [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
            XCTAssertEqual(ClaudeStatusLineCompatibilityProbe.claimSettingsArguments(launchArguments: arguments + arguments, isFirstParty: true), [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("claimed").path))
        }

        private func fixture() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let settings = root.appendingPathComponent("settings.json")
            try Data(#"{"statusLine":{"type":"command","command":"echo probe"}}"#.utf8).write(to: settings)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
            return root
        }
    }
#endif
