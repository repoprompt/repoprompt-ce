import Foundation
@testable import RepoPrompt
import RepoPromptCore
import XCTest

final class AIMessagePromptAssemblyParityTests: XCTestCase {
    func testCoreStandardChatMatchesLegacyAcrossStandardPolicyMatrix() {
        let orders: [[PromptSection]] = [
            PromptAssemblyBuilder.defaultSectionOrder,
            [.metaPrompts, .userInstructions, .fileContents, .fileMap, .gitDiff],
            [.fileContents, .userInstructions, .fileContents, .metaPrompts, .userInstructions, .gitDiff, .fileMap, .metaPrompts]
        ]
        let disabledSets: [Set<PromptSection>] = [
            [],
            Set(PromptSection.allCases),
            [.fileMap],
            [.fileContents],
            [.gitDiff],
            [.metaPrompts],
            [.userInstructions],
            [.fileMap, .metaPrompts, .userInstructions]
        ]
        let finalUserContents = [
            "FINAL",
            " \t\r\n",
            "<user_instructions>\nPREWRAPPED-LF\n</user_instructions>\n",
            "<user_instructions>\r\nPREWRAPPED-CRLF\r\n</user_instructions>\r\n"
        ]

        for order in orders {
            for disabled in disabledSets {
                for duplicate in [false, true] {
                    for finalUserContent in finalUserContents {
                        let conversation = [
                            ConversationEntry(role: .user, content: "EARLY"),
                            ConversationEntry(role: .assistant, content: "ASSISTANT"),
                            ConversationEntry(role: .user, content: finalUserContent)
                        ]
                        assertCoreMatchesLegacy(
                            conversation: conversation,
                            order: order,
                            disabled: disabled,
                            duplicateUserInstructionsAtTop: duplicate
                        )
                    }
                }
            }
        }
    }

    func testCoreStandardChatPreservesEmbeddedSystemAndEmptyOrUserlessTransportBehavior() {
        let nonempty = makeMessage(
            conversation: [ConversationEntry(role: .user, content: "FINAL")],
            strategy: .coreStandardChat
        )
        let tail = nonempty.buildTail(embedSystemPrompt: false)
        XCTAssertFalse(tail.isEmpty)
        XCTAssertEqual(nonempty.buildTail(embedSystemPrompt: true), tail + "\n\n\n\nSYSTEM")

        let emptyTail = PromptPackagingService.buildAIMessage(
            systemPrompt: "SYSTEM",
            metaInstructions: [],
            fileTree: "",
            fileContents: [],
            conversation: [ConversationEntry(role: .user, content: "FINAL")],
            temperature: nil,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            tailAssemblyStrategy: .coreStandardChat
        )
        XCTAssertEqual(emptyTail.buildTail(embedSystemPrompt: false), "")
        XCTAssertEqual(emptyTail.buildTail(embedSystemPrompt: true), "SYSTEM")

        for conversation in [
            [ConversationEntry](),
            [ConversationEntry(role: .assistant, content: "ASSISTANT-ONLY")]
        ] {
            assertCoreMatchesLegacy(
                conversation: conversation,
                order: [.userInstructions, .fileMap, .metaPrompts, .fileContents, .gitDiff, .userInstructions],
                disabled: [.userInstructions],
                duplicateUserInstructionsAtTop: true
            )
        }

        let coreNoUser = makeMessage(
            conversation: [ConversationEntry(role: .assistant, content: "ASSISTANT-ONLY")],
            strategy: .coreStandardChat
        )
        XCTAssertEqual(
            PromptPackagingService.exactChatPayload(for: coreNoUser, source: .immutableSnapshot).text,
            "SYSTEMASSISTANT-ONLY"
        )
    }

    func testTopOnlyDuplicateAdapterPreservesWhitespaceEligibilityAndTrailingBytes() {
        for userContent in ["", " \t\r\n", "USER\n", "USER\r\n"] {
            let legacy = directMessage(
                userContent: userContent,
                strategy: .legacy
            )
            let core = directMessage(
                userContent: userContent,
                strategy: .coreStandardChat
            )
            XCTAssertEqual(core.buildTail(embedSystemPrompt: false), legacy.buildTail(embedSystemPrompt: false))
            XCTAssertEqual(core.buildTail(embedSystemPrompt: true), legacy.buildTail(embedSystemPrompt: true))
        }
    }

    func testCoreStandardChatMatchesHistoricalBytesForEmptyWhitespaceAndUserlessFixtures() {
        assertCoreMatchesLegacy(
            conversation: [],
            order: [],
            disabled: [],
            duplicateUserInstructionsAtTop: true,
            systemPrompt: "",
            metaInstructions: [],
            fileTree: "",
            fileContents: [],
            gitDiff: nil
        )
        assertCoreMatchesLegacy(
            conversation: [ConversationEntry(role: .user, content: " \t\r\n")],
            order: [.fileContents, .fileMap, .gitDiff, .metaPrompts, .fileContents],
            disabled: [.gitDiff],
            duplicateUserInstructionsAtTop: true,
            metaInstructions: [],
            fileTree: " \t",
            fileContents: ["", " \r\n"],
            gitDiff: " \t\r\n"
        )
        assertCoreMatchesLegacy(
            conversation: [ConversationEntry(role: .assistant, content: "ASSISTANT-ONLY")],
            order: [.metaPrompts, .fileMap, .metaPrompts, .fileContents, .gitDiff],
            disabled: [.fileMap, .fileContents, .gitDiff, .metaPrompts, .userInstructions],
            duplicateUserInstructionsAtTop: true,
            metaInstructions: [],
            fileTree: "TREE",
            fileContents: ["FILE"],
            gitDiff: "DIFF"
        )
    }

    func testCoreBackedLegacyFactualPropertiesPreserveHistoricalBytes() {
        let cases: [(fileTree: String, fileBlocks: [String], gitDiff: String?)] = [
            ("", [], nil),
            (" \t", [""], " \r\n"),
            ("TREE\n", ["FIRST", "SECOND"], "DIFF\n"),
            ("TREE\r\n", ["FIRST\n", "SECOND\r\n"], "DIFF\r\n")
        ]

        for values in cases {
            let message = AIMessage(
                systemPrompt: "SYSTEM",
                metaPrompts: ["META"],
                fileTree: values.fileTree,
                fileBlocks: values.fileBlocks,
                gitDiff: values.gitDiff,
                conversationMessages: [],
                temperature: nil,
                promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
                disabledPromptSections: []
            )

            XCTAssertEqual(message.fileTreeXML, historicalFileTreeXML(values.fileTree))
            XCTAssertEqual(message.fileBlocksXML, historicalFileBlocksXML(values.fileBlocks))
            XCTAssertEqual(message.gitDiffXML, historicalGitDiffXML(values.gitDiff))
            XCTAssertEqual(
                message.combinedXML,
                [
                    message.systemPromptXML,
                    message.metaPromptsXML,
                    historicalFileTreeXML(values.fileTree),
                    historicalFileBlocksXML(values.fileBlocks),
                    historicalGitDiffXML(values.gitDiff)
                ]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            )
        }
    }

    private func assertCoreMatchesLegacy(
        conversation: [ConversationEntry],
        order: [PromptSection],
        disabled: Set<PromptSection>,
        duplicateUserInstructionsAtTop: Bool,
        systemPrompt: String = "SYSTEM",
        metaInstructions: [MetaInstruction] = [
            MetaInstruction(title: "Rules LF", content: "META-LF\n"),
            MetaInstruction(title: "Rules CRLF", content: "META-CRLF\r\n")
        ],
        fileTree: String = "TREE-LF\n",
        fileContents: [String] = ["FIRST\n", "SECOND\r\n"],
        gitDiff: String? = "DIFF-CRLF\r\n",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let legacy = makeMessage(
            conversation: conversation,
            order: order,
            disabled: disabled,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
            systemPrompt: systemPrompt,
            metaInstructions: metaInstructions,
            fileTree: fileTree,
            fileContents: fileContents,
            gitDiff: gitDiff,
            strategy: .legacy
        )
        let core = makeMessage(
            conversation: conversation,
            order: order,
            disabled: disabled,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
            systemPrompt: systemPrompt,
            metaInstructions: metaInstructions,
            fileTree: fileTree,
            fileContents: fileContents,
            gitDiff: gitDiff,
            strategy: .coreStandardChat
        )

        for embedSystemPrompt in [false, true] {
            let historicalTail = historicalLegacyTail(for: legacy, embedSystemPrompt: embedSystemPrompt)
            XCTAssertEqual(legacy.buildTail(embedSystemPrompt: embedSystemPrompt), historicalTail, file: file, line: line)
            XCTAssertEqual(core.buildTail(embedSystemPrompt: embedSystemPrompt), historicalTail, file: file, line: line)
            let historicalChat = historicalChatTransport(for: legacy, embedSystemPrompt: embedSystemPrompt)
            XCTAssertEqual(chatTransport(legacy, embedSystemPrompt: embedSystemPrompt), historicalChat, file: file, line: line)
            XCTAssertEqual(chatTransport(core, embedSystemPrompt: embedSystemPrompt), historicalChat, file: file, line: line)
        }

        let historicalResponses = historicalResponsesTransport(for: legacy)
        XCTAssertEqual(responsesTransport(legacy), historicalResponses, file: file, line: line)
        XCTAssertEqual(responsesTransport(core), historicalResponses, file: file, line: line)

        let legacyPayload = PromptPackagingService.exactChatPayload(for: legacy, source: .activeLive)
        let corePayload = PromptPackagingService.exactChatPayload(for: core, source: .activeLive)
        XCTAssertEqual(corePayload.text, legacyPayload.text, file: file, line: line)
        XCTAssertEqual(corePayload.projection.total, legacyPayload.projection.total, file: file, line: line)
    }

    private func makeMessage(
        conversation: [ConversationEntry],
        order: [PromptSection] = PromptAssemblyBuilder.defaultSectionOrder,
        disabled: Set<PromptSection> = [],
        duplicateUserInstructionsAtTop: Bool = false,
        systemPrompt: String = "SYSTEM",
        metaInstructions: [MetaInstruction] = [
            MetaInstruction(title: "Rules LF", content: "META-LF\n"),
            MetaInstruction(title: "Rules CRLF", content: "META-CRLF\r\n")
        ],
        fileTree: String = "TREE-LF\n",
        fileContents: [String] = ["FIRST\n", "SECOND\r\n"],
        gitDiff: String? = "DIFF-CRLF\r\n",
        strategy: AIMessage.TailAssemblyStrategy
    ) -> AIMessage {
        PromptPackagingService.buildAIMessage(
            systemPrompt: systemPrompt,
            metaInstructions: metaInstructions,
            fileTree: fileTree,
            fileContents: fileContents,
            gitDiff: gitDiff,
            conversation: conversation,
            temperature: nil,
            promptSectionsOrder: order,
            disabledPromptSections: disabled,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
            tailAssemblyStrategy: strategy
        )
    }

    private func directMessage(
        userContent: String,
        strategy: AIMessage.TailAssemblyStrategy
    ) -> AIMessage {
        AIMessage(
            systemPrompt: "SYSTEM",
            metaPrompts: [],
            fileTree: "",
            fileBlocks: [],
            conversationMessages: [ConversationEntry(role: .user, content: userContent)],
            temperature: nil,
            promptSectionsOrder: [.userInstructions, .userInstructions],
            disabledPromptSections: [],
            duplicateUserInstructionsAtTop: true,
            tailAssemblyStrategy: strategy
        )
    }

    private func chatTransport(
        _ message: AIMessage,
        embedSystemPrompt: Bool
    ) -> [TransportMessage] {
        message.openAIChatMessages(embedSystemPrompt: embedSystemPrompt).map { item in
            let text: String = switch item.content {
            case let .text(text):
                text
            case let .contentArray(items):
                items.compactMap { content in
                    if case let .text(text) = content { return text }
                    return nil
                }.joined()
            }
            return TransportMessage(role: String(describing: item.role), text: text)
        }
    }

    private func responsesTransport(_ message: AIMessage) -> [TransportMessage] {
        switch message.openAIResponsesInput() {
        case let .array(items):
            items.compactMap { item in
                guard case let .message(message) = item else { return nil }
                guard case let .text(text) = message.content else { return nil }
                return TransportMessage(role: message.role, text: text)
            }
        default:
            []
        }
    }

    private func historicalLegacyTail(
        for message: AIMessage,
        embedSystemPrompt: Bool
    ) -> String {
        var parts: [String] = []
        if message.duplicateUserInstructionsAtTop,
           let userBlock = message.conversationMessages.last(where: { $0.role == .user })?.content,
           !userBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            parts.append(userBlock)
        }

        for section in message.promptSectionsOrder where !message.disabledPromptSections.contains(section) {
            switch section {
            case .fileMap:
                if !message.fileTree.isEmpty { parts.append(historicalFileTreeXML(message.fileTree)) }
            case .fileContents:
                if !message.fileBlocks.isEmpty { parts.append(historicalFileBlocksXML(message.fileBlocks)) }
            case .metaPrompts:
                if !message.metaPrompts.isEmpty { parts.append(message.metaPrompts.joined(separator: "\n")) }
            case .gitDiff:
                if let diff = message.gitDiff, !diff.isEmpty { parts.append(historicalGitDiffXML(diff)) }
            case .userInstructions:
                continue
            }
        }

        if embedSystemPrompt, !message.systemPrompt.isEmpty {
            if !parts.isEmpty { parts.append("") }
            parts.append(message.systemPrompt)
        }
        return parts.joined(separator: "\n\n")
    }

    private func historicalChatTransport(
        for message: AIMessage,
        embedSystemPrompt: Bool
    ) -> [TransportMessage] {
        let tail = historicalLegacyTail(for: message, embedSystemPrompt: embedSystemPrompt)
        var messages: [TransportMessage] = []
        if !embedSystemPrompt, !message.systemPrompt.isEmpty {
            messages.append(TransportMessage(role: "system", text: message.systemPrompt))
        }

        let lastUserIndex = message.conversationMessages.lastIndex { $0.role == .user }
        for (index, entry) in message.conversationMessages.enumerated() {
            let text = entry.role == .user && index == lastUserIndex && !tail.isEmpty
                ? tail + "\n" + entry.content
                : entry.content
            messages.append(
                TransportMessage(
                    role: entry.role == .user ? "user" : "assistant",
                    text: text
                )
            )
        }
        return messages
    }

    private func historicalResponsesTransport(for message: AIMessage) -> [TransportMessage] {
        let tail = historicalLegacyTail(for: message, embedSystemPrompt: false)
        let additions = tail.isEmpty ? "" : tail + "\n\n"
        var messages: [TransportMessage] = []
        var firstUser = true

        for entry in message.conversationMessages {
            switch entry.role {
            case .user:
                let text = firstUser ? additions + entry.content : entry.content
                firstUser = false
                messages.append(TransportMessage(role: "user", text: text))
            case .assistant:
                messages.append(TransportMessage(role: "assistant", text: entry.content))
            }
        }

        if messages.isEmpty, !additions.isEmpty {
            messages.append(TransportMessage(role: "user", text: additions))
        }
        return messages
    }

    private func historicalFileTreeXML(_ fileTree: String) -> String {
        guard !fileTree.isEmpty else { return "" }
        return "<file_tree>\n\(fileTree)\n</file_tree>"
    }

    private func historicalFileBlocksXML(_ fileBlocks: [String]) -> String {
        guard !fileBlocks.isEmpty else { return "" }
        var result = "<file_contents>\n"
        for block in fileBlocks {
            result += block + "\n\n"
        }
        result += "</file_contents>"
        return result
    }

    private func historicalGitDiffXML(_ gitDiff: String?) -> String {
        guard let gitDiff, !gitDiff.isEmpty else { return "" }
        return "<git_diff>\n\(gitDiff)\n</git_diff>"
    }
}

private struct TransportMessage: Equatable {
    let role: String
    let text: String
}
