import Foundation
@testable import RepoPromptApp
import XCTest

final class DevinPromptQualificationTests: XCTestCase {
    func testStandardAndRolePromptsQualifyHostReferences() {
        for role in [nil, .explore, .engineer, .pair, .design] as [AgentModelCatalog.TaskLabelKind?] {
            let prompt = SystemPromptService.agentModePrompt(agentKind: .devin, taskLabelKind: role)
            XCTAssertTrue(prompt.contains("`mcp__RepoPromptCE__set_status`"))
            XCTAssertFalse(prompt.contains("`set_status`"))
            XCTAssertFalse(prompt.contains("`RepoPrompt__read_file`"))
            XCTAssertFalse(prompt.contains("`get_file_tree`"))
            XCTAssertFalse(prompt.contains("mcp__RepoPromptCE__mcp__"))
        }
    }
}
