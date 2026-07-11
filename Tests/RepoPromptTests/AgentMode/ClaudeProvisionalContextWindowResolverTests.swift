import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeProvisionalContextWindowResolverTests: XCTestCase {
    func testSettingsResolveRawConfiguredWindow() throws {
        let fixture = try makeFixture(userSettingsValue: "400_000")
        let key = ClaudeProvisionalContextWindowResolver.Key(
            agentKind: .claudeCode,
            modelRaw: "claude-fable-5",
            workspacePath: fixture.workspace.path
        )

        let value = ClaudeProvisionalContextWindowResolver.resolveUncachedConfiguredContextWindow(
            for: key,
            environmentSnapshot: fixture.environment
        )

        XCTAssertEqual(value, 400_000)
    }

    func testEnvironmentSnapshotOverridesSettings() throws {
        let fixture = try makeFixture(userSettingsValue: "400_000")
        let key = ClaudeProvisionalContextWindowResolver.Key(
            agentKind: .claudeCode,
            modelRaw: "claude-fable-5",
            workspacePath: fixture.workspace.path
        )
        var environment = fixture.environment
        environment[ClaudeEffectiveContextWindowResolver.environmentKey] = "300_000"

        let value = ClaudeProvisionalContextWindowResolver.resolveUncachedConfiguredContextWindow(
            for: key,
            environmentSnapshot: environment
        )

        XCTAssertEqual(value, 300_000)
    }

    func testInvalidAndNonClaudeResolveNil() throws {
        let fixture = try makeFixture(userSettingsValue: "not-a-number")
        let invalidClaudeKey = ClaudeProvisionalContextWindowResolver.Key(
            agentKind: .claudeCode,
            modelRaw: "claude-fable-5",
            workspacePath: fixture.workspace.path
        )
        XCTAssertNil(ClaudeProvisionalContextWindowResolver.resolveUncachedConfiguredContextWindow(
            for: invalidClaudeKey,
            environmentSnapshot: fixture.environment
        ))

        let nonClaudeKey = ClaudeProvisionalContextWindowResolver.Key(
            agentKind: .codexExec,
            modelRaw: "gpt-5.1-codex",
            workspacePath: fixture.workspace.path
        )
        XCTAssertNil(ClaudeProvisionalContextWindowResolver.resolveUncachedConfiguredContextWindow(
            for: nonClaudeKey,
            environmentSnapshot: fixture.environment
        ))
    }

    func testGLMOneMillionPredictionOverridesUserSettings() throws {
        let fixture = try makeFixture(userSettingsValue: "400_000")
        let key = ClaudeProvisionalContextWindowResolver.Key(
            agentKind: .claudeCodeGLM,
            modelRaw: "sonnet",
            workspacePath: fixture.workspace.path
        )

        let value = ClaudeProvisionalContextWindowResolver.resolveUncachedConfiguredContextWindow(
            for: key,
            environmentSnapshot: fixture.environment
        )

        XCTAssertEqual(value, 1_000_000)
    }

    func testCacheAvoidsRepeatedSettingsReadsForSameKey() throws {
        let fixture = try makeFixture(userSettingsValue: "400_000")
        let key = ClaudeProvisionalContextWindowResolver.Key(
            agentKind: .claudeCode,
            modelRaw: "claude-fable-5",
            workspacePath: fixture.workspace.path
        )
        let fileManager = CountingFileManager()
        let resolver = ClaudeProvisionalContextWindowResolver()

        XCTAssertEqual(resolver.resolveConfiguredContextWindow(
            for: key,
            environmentSnapshot: fixture.environment,
            fileManager: fileManager
        ), 400_000)
        let firstLookupCount = fileManager.fileExistsCallCount
        XCTAssertGreaterThan(firstLookupCount, 0)

        XCTAssertEqual(resolver.resolveConfiguredContextWindow(
            for: key,
            environmentSnapshot: fixture.environment,
            fileManager: fileManager
        ), 400_000)
        XCTAssertEqual(fileManager.fileExistsCallCount, firstLookupCount)
    }

    private struct Fixture {
        let root: URL
        let workspace: URL
        let home: URL
        let environment: [String: String]
    }

    private func makeFixture(userSettingsValue: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeProvisionalContextWindowResolverTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let settingsDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let settings = "{\"env\":{\"CLAUDE_CODE_AUTO_COMPACT_WINDOW\":\"\(userSettingsValue)\"}}"
        try settings.write(
            to: settingsDirectory.appendingPathComponent("settings.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(
            root: root,
            workspace: workspace,
            home: home,
            environment: ["HOME": home.path]
        )
    }

    private final class CountingFileManager: FileManager {
        private(set) var fileExistsCallCount = 0

        override func fileExists(atPath path: String) -> Bool {
            fileExistsCallCount += 1
            return super.fileExists(atPath: path)
        }
    }
}
