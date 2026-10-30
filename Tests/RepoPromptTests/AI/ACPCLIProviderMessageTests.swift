import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class ACPCLIProviderMessageTests: XCTestCase {
    func testACPCLIAdaptersPreserveTransientImages() {
        let message = AIMessage(
            systemPrompt: "system",
            conversationMessages: [
                .init(role: .user, content: "first"),
                .init(role: .assistant, content: "answer"),
                .init(role: .user, content: "final")
            ],
            attachments: [
                .init(payload: .image(.png, Data([1, 2, 3])), fileName: "image.png", title: "Diagram")
            ],
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )
        let openCode = makeOpenCode().makeAgentMessage(from: message)
        let cursor = makeCursor().makeAgentMessage(from: message)

        XCTAssertEqual(openCode.attachments, message.attachments)
        XCTAssertEqual(cursor.attachments, message.attachments)
    }

    func testPromptConversionKeepsHistoryAndCursorNoToolsInstructionWithoutInventingAnEmptySystemPrompt() {
        let message = AIMessage(
            systemPrompt: "  policy  ",
            conversationMessages: [
                .init(role: .user, content: "first"),
                .init(role: .assistant, content: "answer"),
                .init(role: .user, content: "last")
            ],
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )
        let cursor = makeCursor().makeAgentMessage(from: message)
        let openCode = makeOpenCode().makeAgentMessage(from: message)
        XCTAssertEqual(cursor.systemPrompt, "policy\n\nIMPORTANT: Do not use any tools, function calls, or external commands. Respond with text only. Any tool invocation will cause task failure.")
        XCTAssertEqual(openCode.systemPrompt, "policy")
        XCTAssertEqual(cursor.userMessage, "User: first\n\nAssistant: answer\n\nUser: last")
        XCTAssertEqual(openCode.userMessage, cursor.userMessage)
        XCTAssertNil(cursor.resumeSessionID)
        XCTAssertNil(openCode.resumeSessionID)

        let empty = AIMessage(systemPrompt: " \n\t", userMessage: "only")
        XCTAssertEqual(makeCursor().makeAgentMessage(from: empty).systemPrompt, "")
        XCTAssertEqual(makeOpenCode().makeAgentMessage(from: empty).systemPrompt, "")
    }

    private func makeCursor() -> CursorCLIProvider {
        CursorCLIProvider(
            configurationFactory: { _ in
                XCTFail("Message conversion must not resolve a launch configuration")
                return CursorAgentConfig()
            },
            headlessProviderFactory: { _, _ in
                fatalError("Message conversion must not construct an execution provider")
            }
        )
    }

    private func makeOpenCode() -> OpenCodeCLIProvider {
        OpenCodeCLIProvider(
            configurationFactory: { _ in
                XCTFail("Message conversion must not resolve a launch configuration")
                return OpenCodeAgentConfig()
            },
            headlessProviderFactory: { _, _ in
                fatalError("Message conversion must not construct an execution provider")
            }
        )
    }
}
