import Foundation
@testable import RepoPromptCore
import XCTest

final class AgentSupportDirectoryCatalogTests: XCTestCase {
    func testBuiltInAlwaysReadableDirectoriesPreserveEstablishedFourRootPolicy() {
        let home = URL(fileURLWithPath: "/tmp/repoprompt-agent-support-home", isDirectory: true)

        let directories = AgentSupportDirectoryCatalog.builtInAlwaysReadableDirectories(
            homeDirectoryURL: home
        )

        XCTAssertEqual(
            directories.map(\.source),
            [.globalAgentsSkills, .globalAgentsSlash, .globalClaudeSkills, .globalClaudeCommands]
        )
        XCTAssertEqual(
            directories.map(\.standardizedPath),
            [
                "/tmp/repoprompt-agent-support-home/.agents/skills",
                "/tmp/repoprompt-agent-support-home/.agents/slash",
                "/tmp/repoprompt-agent-support-home/.claude/skills",
                "/tmp/repoprompt-agent-support-home/.claude/commands",
            ]
        )
    }

    func testCodexPromptInstallLocationIsNotImplicitReadAuthorization() {
        let home = URL(fileURLWithPath: "/tmp/repoprompt-agent-support-home", isDirectory: true)
        let roots = AgentSupportDirectoryCatalog.globalRootURLs(homeDirectoryURL: home)
        let readablePaths = Set(
            AgentSupportDirectoryCatalog.builtInAlwaysReadableDirectories(homeDirectoryURL: home)
                .map(\.standardizedPath)
        )

        XCTAssertEqual(
            AgentSupportDirectoryCatalog.normalizedPath(for: roots.codexPrompts.path),
            "/tmp/repoprompt-agent-support-home/.codex/prompts"
        )
        XCTAssertFalse(readablePaths.contains("/tmp/repoprompt-agent-support-home/.codex/prompts"))
    }
}
