import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexContextWindowResolverTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testUserRootTableModelContextWindowResolvesRawConfiguredWindow() throws {
        let root = try makeTemporaryDirectory()
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        try writeCodexConfig(codexHome.appendingPathComponent("config.toml"), content: "model_context_window = 400_000\n")

        let resolved = CodexContextWindowResolver.resolve(
            launchEnvironment: ["CODEX_HOME": codexHome.path],
            workingDirectory: nil,
            homeDirectory: root.appendingPathComponent("home", isDirectory: true)
        )

        XCTAssertEqual(resolved.configuredContextWindow, 400_000)
        XCTAssertNil(resolved.autoCompactTokenLimit)
    }

    func testProjectRootTableConfigOverridesUserConfig() throws {
        let root = try makeTemporaryDirectory()
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try writeCodexConfig(codexHome.appendingPathComponent("config.toml"), content: "model_context_window = 300000\n")
        try writeCodexConfig(project.appendingPathComponent(".codex/config.toml"), content: "model_context_window = 400000\n")

        let resolved = CodexContextWindowResolver.resolve(
            launchEnvironment: ["CODEX_HOME": codexHome.path],
            workingDirectory: project.path,
            homeDirectory: root.appendingPathComponent("home", isDirectory: true)
        )

        XCTAssertEqual(resolved.configuredContextWindow, 400_000)
    }

    func testProfileTableModelContextWindowDoesNotLeakIntoDefaultResolution() {
        let resolved = CodexContextWindowResolver.configuration(
            fromRootTableTOML: "[profiles.foo]\nmodel_context_window = 400000\n"
        )

        XCTAssertNil(resolved.configuredContextWindow)
    }

    func testAutoCompactTokenLimitIsCapturedButDoesNotBecomeDenominator() {
        let resolved = CodexContextWindowResolver.configuration(
            fromRootTableTOML: "model_auto_compact_token_limit = 350000\n"
        )

        XCTAssertNil(resolved.configuredContextWindow)
        XCTAssertEqual(resolved.autoCompactTokenLimit, 350_000)
    }

    func testInvalidMalformedAndNonPositiveValuesFailSoftToNil() {
        let malformed = CodexContextWindowResolver.configuration(fromRootTableTOML: "model_context_window = \"400000\"\n")
        let zero = CodexContextWindowResolver.configuration(fromRootTableTOML: "model_context_window = 0\n")
        let negative = CodexContextWindowResolver.configuration(fromRootTableTOML: "model_context_window = -1\n")

        XCTAssertNil(malformed.configuredContextWindow)
        XCTAssertNil(zero.configuredContextWindow)
        XCTAssertNil(negative.configuredContextWindow)
    }

    func testMissingCodexHomeDefaultsToHomeDotCodexConfig() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeCodexConfig(home.appendingPathComponent(".codex/config.toml"), content: "model_context_window = 400000\n")

        let resolved = CodexContextWindowResolver.resolve(
            launchEnvironment: [:],
            workingDirectory: nil,
            homeDirectory: home
        )

        XCTAssertEqual(resolved.configuredContextWindow, 400_000)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexContextWindowResolverTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func writeCodexConfig(_ url: URL, content: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
