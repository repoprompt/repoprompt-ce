import Foundation

/// Common chat completion parameters
package enum CompletionParams {
    package struct Message: Encodable {
        package enum Role: String, Encodable {
            case system
            case user
            case assistant
        }

        package enum Content: Encodable {
            case text(String)
            case parts([Part])

            package struct ImageURL: Encodable {
                package let url: String
                package let detail: String
            }

            package enum Part: Encodable {
                case text(String)
                case imageURL(url: String, detail: String)

                private enum CodingKeys: String, CodingKey {
                    case type
                    case text
                    case imageURL = "image_url"
                }

                package func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    switch self {
                    case let .text(text):
                        try container.encode("text", forKey: .type)
                        try container.encode(text, forKey: .text)
                    case let .imageURL(url, detail):
                        try container.encode("image_url", forKey: .type)
                        try container.encode(ImageURL(url: url, detail: detail), forKey: .imageURL)
                    }
                }
            }

            package func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case let .text(text):
                    try container.encode(text)
                case let .parts(parts):
                    try container.encode(parts)
                }
            }
        }

        package let role: Role
        package let content: Content

        package init(role: Role, content: Content) {
            self.role = role
            self.content = content
        }
    }
}

package enum CustomOpenAIMessageBuilder {
    package static func messages(for aiMessage: AIMessage) -> [CompletionParams.Message] {
        var results: [CompletionParams.Message] = []

        // 1) System prompt
        if !aiMessage.systemPrompt.isEmpty {
            results.append(
                CompletionParams.Message(
                    role: .system,
                    content: .text(aiMessage.systemPrompt)
                )
            )
        }

        // Collect file tree, file blocks, and meta instructions into one block
        var additionsForFinalUserMessage = ""
        if !aiMessage.fileTree.isEmpty {
            additionsForFinalUserMessage += aiMessage.fileTreeXML + "\n"
        }
        if !aiMessage.fileBlocks.isEmpty {
            additionsForFinalUserMessage += aiMessage.fileBlocksXML + "\n"
        }
        for meta in aiMessage.metaPrompts {
            additionsForFinalUserMessage += meta + "\n"
        }
        if !aiMessage.disabledPromptSections.contains(.gitDiff),
           !aiMessage.gitDiffXML.isEmpty
        {
            additionsForFinalUserMessage += aiMessage.gitDiffXML + "\n"
        }

        // Find the index of the last user message
        let conversation = aiMessage.conversationMessages
        let lastUserIndex = conversation.lastIndex { $0.role == .user }

        // Build the conversation in chronological order
        for (index, entry) in conversation.enumerated() {
            let role: CompletionParams.Message.Role = entry.role == .user ? .user : .assistant

            if role == .user {
                var userContent = ""

                // If this is the last user message, add context before the message
                if index == lastUserIndex, !additionsForFinalUserMessage.isEmpty {
                    userContent = additionsForFinalUserMessage + "\n" + entry.content
                } else {
                    userContent = entry.content
                }

                let content: CompletionParams.Message.Content
                if index == lastUserIndex, !aiMessage.transientImages.isEmpty {
                    var parts: [CompletionParams.Message.Content.Part] = []
                    if !userContent.isEmpty {
                        parts.append(.text(userContent))
                    }
                    for image in aiMessage.transientImages {
                        if let annotation = image.titleAnnotation {
                            parts.append(.text(annotation))
                        }
                        parts.append(.imageURL(url: image.openAIDataURL, detail: "auto"))
                    }
                    content = .parts(parts)
                } else {
                    content = .text(userContent)
                }
                results.append(CompletionParams.Message(role: .user, content: content))
            } else {
                results.append(
                    CompletionParams.Message(
                        role: .assistant,
                        content: .text(entry.content)
                    )
                )
            }
        }

        if lastUserIndex == nil, !aiMessage.transientImages.isEmpty {
            var parts: [CompletionParams.Message.Content.Part] = []
            if !additionsForFinalUserMessage.isEmpty {
                parts.append(.text(additionsForFinalUserMessage))
            }
            for image in aiMessage.transientImages {
                if let annotation = image.titleAnnotation {
                    parts.append(.text(annotation))
                }
                parts.append(.imageURL(url: image.openAIDataURL, detail: "auto"))
            }
            results.append(CompletionParams.Message(role: .user, content: .parts(parts)))
        }

        return results
    }
}
