@testable import RepoPromptApp
import XCTest

final class ContextBuilderExperimentPromptInsertionTests: XCTestCase {
    func testAcceptsExactlyOneInsertionInFinalUserMessage() throws {
        let message = AgentMessage(
            systemPrompt: "Fixed production system instructions",
            userMessage: "<discover_instructions>\nSealed candidate\n</discover_instructions>"
        )
        XCTAssertNoThrow(try ContextBuilderExperimentPromptInsertion.validate(message, instructions: "Sealed candidate"))
    }

    func testRejectsMissingInsertionEvenWhenSystemContainsCandidate() {
        let message = AgentMessage(systemPrompt: "Sealed candidate", userMessage: "Unrelated task")
        XCTAssertThrowsError(try ContextBuilderExperimentPromptInsertion.validate(message, instructions: "Sealed candidate")) { error in
            XCTAssertEqual(error as? ContextBuilderExperimentPromptInsertionError, .missingInstructions)
        }
    }

    func testRejectsDuplicateInsertion() {
        let block = "<discover_instructions>\nSealed candidate\n</discover_instructions>"
        let message = AgentMessage(systemPrompt: "Fixed", userMessage: "\(block)\n\(block)")
        XCTAssertThrowsError(try ContextBuilderExperimentPromptInsertion.validate(message, instructions: "Sealed candidate")) { error in
            XCTAssertEqual(error as? ContextBuilderExperimentPromptInsertionError, .duplicateInstructions)
        }
    }

    func testSameWordsOutsideInsertionBlockAreNotASecondInsertion() {
        let message = AgentMessage(
            userMessage: "<current_prompt_content>Sealed candidate</current_prompt_content>\n<discover_instructions>\nSealed candidate\n</discover_instructions>"
        )
        XCTAssertNoThrow(try ContextBuilderExperimentPromptInsertion.validate(message, instructions: "Sealed candidate"))
    }

    func testPreservesLineEndingsInsideInsertedInstructions() {
        let instructions = "First line\r\nSecond line\n"
        let message = AgentMessage(userMessage: "<discover_instructions>\n\(instructions)\n</discover_instructions>")
        XCTAssertNoThrow(try ContextBuilderExperimentPromptInsertion.validate(message, instructions: instructions))
    }

    func testRejectsEmptyInstructions() {
        let message = AgentMessage(userMessage: "Task")
        XCTAssertThrowsError(try ContextBuilderExperimentPromptInsertion.validate(message, instructions: "")) { error in
            XCTAssertEqual(error as? ContextBuilderExperimentPromptInsertionError, .emptyInstructions)
        }
        XCTAssertThrowsError(try ContextBuilderExperimentPromptInsertion.validate(message, instructions: " \n ")) { error in
            XCTAssertEqual(error as? ContextBuilderExperimentPromptInsertionError, .emptyInstructions)
        }
    }
}
