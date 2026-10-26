@testable import RepoPromptApp
import XCTest

final class ChatNameExtractorTests: XCTestCase {
    func testExtractAndRemoveScenarios() {
        let scenarios: [(name: String, input: String, expectedName: String?, expectedContent: String)] = [
            ("quoted self-closing marker", "<chatName=\"Implementation Plan\"/>\nBody", "Implementation Plan", "\nBody"),
            ("unquoted non-self-closing marker", "Intro\n<chatName=Plan>\nBody", "Plan", "Intro\n\nBody"),
            ("valid marker embedded in surrounding text", "Before <chatName = \"Review Notes\" /> after", "Review Notes", "Before  after"),
            ("absent marker", "Intro\nNo chat name here.\nBody", nil, "Intro\nNo chat name here.\nBody"),
            ("empty quoted value", "Intro\n<chatName=\"\"/>\nBody", nil, "Intro\n<chatName=\"\"/>\nBody"),
            ("missing assignment and value", "Intro\n<chatName/>\nBody", nil, "Intro\n<chatName/>\nBody")
        ]

        for scenario in scenarios {
            XCTContext.runActivity(named: scenario.name) { _ in
                var content = scenario.input

                let name = ChatNameExtractor.extractAndRemove(from: &content)

                XCTAssertEqual(name, scenario.expectedName)
                XCTAssertEqual(content, scenario.expectedContent)
            }
        }
    }
}
