import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeEffectiveContextWindowResolverTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testUserSettingsResolveRawConfiguredWindow() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeClaudeSettings(home.appendingPathComponent(".claude/settings.json"), value: "400_000")

        let resolved = ClaudeEffectiveContextWindowResolver.resolveConfiguredContextWindow(
            launchEnvironment: ["HOME": home.path],
            workingDirectory: nil
        )

        XCTAssertEqual(resolved, 400_000)
    }

    func testProjectSettingsOverrideUserSettingsAndLocalOverridesProject() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try writeClaudeSettings(home.appendingPathComponent(".claude/settings.json"), value: "300000")
        try writeClaudeSettings(project.appendingPathComponent(".claude/settings.json"), value: "350000")
        try writeClaudeSettings(project.appendingPathComponent(".claude/settings.local.json"), value: "400000")

        let resolved = ClaudeEffectiveContextWindowResolver.resolveConfiguredContextWindow(
            launchEnvironment: ["HOME": home.path],
            workingDirectory: project.path
        )

        XCTAssertEqual(resolved, 400_000)
    }

    func testLaunchEnvironmentOverridesSettingsFilesAndKeepsRawValue() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try writeClaudeSettings(home.appendingPathComponent(".claude/settings.json"), value: "300000")
        try writeClaudeSettings(project.appendingPathComponent(".claude/settings.local.json"), value: "400000")

        let resolved = ClaudeEffectiveContextWindowResolver.resolveConfiguredContextWindow(
            launchEnvironment: [
                "HOME": home.path,
                ClaudeEffectiveContextWindowResolver.environmentKey: "1_000_000"
            ],
            workingDirectory: project.path
        )

        XCTAssertEqual(resolved, 1_000_000)
    }

    func testClaudeConfigDirSuppliesUserSettingsRole() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let configDir = root.appendingPathComponent("custom-claude", isDirectory: true)
        try writeClaudeSettings(home.appendingPathComponent(".claude/settings.json"), value: "300000")
        try writeClaudeSettings(configDir.appendingPathComponent("settings.json"), value: "400000")

        let resolved = ClaudeEffectiveContextWindowResolver.resolveConfiguredContextWindow(
            launchEnvironment: [
                "HOME": home.path,
                "CLAUDE_CONFIG_DIR": configDir.path
            ],
            workingDirectory: nil
        )

        XCTAssertEqual(resolved, 400_000)
    }

    func testInvalidOrNonPositiveValuesAreIgnoredAndMissingSettingsResolveNil() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try writeClaudeSettings(home.appendingPathComponent(".claude/settings.json"), value: "-1")
        try writeClaudeSettings(project.appendingPathComponent(".claude/settings.json"), value: "not-a-number")
        try writeClaudeSettings(project.appendingPathComponent(".claude/settings.local.json"), value: "0")

        let invalidResolved = ClaudeEffectiveContextWindowResolver.resolveConfiguredContextWindow(
            launchEnvironment: ["HOME": home.path],
            workingDirectory: project.path
        )
        XCTAssertNil(invalidResolved)

        let missingResolved = ClaudeEffectiveContextWindowResolver.resolveConfiguredContextWindow(
            launchEnvironment: ["HOME": root.appendingPathComponent("missing-home").path],
            workingDirectory: root.appendingPathComponent("missing-project").path
        )
        XCTAssertNil(missingResolved)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeEffectiveContextWindowResolverTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func writeClaudeSettings(_ url: URL, value: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = "{\"env\":{\"CLAUDE_CODE_AUTO_COMPACT_WINDOW\":\"\(value)\"}}"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
