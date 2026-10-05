import Foundation
import RepoPromptDomainRuntime
import RepoPromptFileSystem
import SwiftOpenAI

typealias ConversationEntry = RepoPromptDomainRuntime.ConversationEntry
typealias AIMessage = RepoPromptDomainRuntime.AIMessage

extension AIMessage {
    /// Generates the full array of `ChatCompletionParameters.Message` objects
    /// that an OpenAI‑style chat endpoint expects.
    ///
    /// Replaces the old `createMessages` helper (which has been removed from
    /// providers).
    func openAIChatMessages(embedSystemPrompt: Bool) -> [ChatCompletionParameters.Message] {
        let tail = buildTail(embedSystemPrompt: embedSystemPrompt)

        var msgs: [ChatCompletionParameters.Message] = []

        if !embedSystemPrompt, !systemPrompt.isEmpty {
            msgs.append(.init(role: .system, content: .text(systemPrompt)))
        }

        let lastUserIndex = conversationMessages.lastIndex { $0.role == .user }

        for (idx, entry) in conversationMessages.enumerated() {
            let baseText = entry.content
            let text = (entry.role == .user && idx == lastUserIndex && !tail.isEmpty)
                ? tail + "\n" + baseText
                : baseText

            let role: ChatCompletionParameters.Message.Role = (entry.role == .user)
                ? .user
                : .assistant
            if entry.role == .user, idx == lastUserIndex, !transientImages.isEmpty {
                msgs.append(.init(role: role, content: openAIChatContent(text: text)))
            } else {
                msgs.append(.init(role: role, content: .text(text)))
            }
        }

        if lastUserIndex == nil, !transientImages.isEmpty {
            msgs.append(.init(role: .user, content: openAIChatContent(text: tail)))
        }

        return msgs
    }

    /// Generates the full array of `InputItem`s for the Responses-API,
    /// applying the **same** "tail-on-last-user" logic that
    /// `openAIChatMessages(_:)` uses.
    ///
    /// All assistant turns are encoded as normal `message` objects
    /// (role = "assistant").  This avoids the need for the `msg_…` ids that
    /// `output_message` objects require.
    func openAIResponsesInput() -> SwiftOpenAI.InputType {
        // 1. Build the XML / meta tail that must be prepended to the *first*
        //    user message.
        let tail = buildTail(embedSystemPrompt: false)
        let additions = tail.isEmpty ? "" : tail + "\n\n"

        var items: [SwiftOpenAI.InputItem] = []
        var firstUser = true
        let lastUserIndex = conversationMessages.lastIndex { $0.role == .user }

        // 2. Walk through the stored conversation.
        for (index, entry) in conversationMessages.enumerated() {
            switch entry.role {
            case .user:
                var text = entry.content
                if firstUser {
                    text = additions + text // prepend only once
                    firstUser = false
                }

                let content = if index == lastUserIndex, !transientImages.isEmpty {
                    openAIResponsesContent(text: text)
                } else {
                    SwiftOpenAI.MessageContent.text(text)
                }
                let msg = SwiftOpenAI.InputMessage(
                    role: "user",
                    content: content
                )
                items.append(.message(msg))

            case .assistant:
                // Previous assistant reply – send as a plain message.
                let msg = SwiftOpenAI.InputMessage(
                    role: "assistant",
                    content: .text(entry.content)
                )
                items.append(.message(msg))
            }
        }

        // 3. Edge-case: no user message yet. Preserve the text-only behavior of
        // adding context only when there are no existing conversation items.
        if lastUserIndex == nil,
           !transientImages.isEmpty || items.isEmpty && !additions.isEmpty
        {
            let content = transientImages.isEmpty
                ? SwiftOpenAI.MessageContent.text(additions)
                : openAIResponsesContent(text: additions)
            let msg = SwiftOpenAI.InputMessage(role: "user", content: content)
            items.append(.message(msg))
        }

        return .array(items)
    }

    private func openAIChatContent(text: String) -> ChatCompletionParameters.Message.ContentType {
        var parts: [ChatCompletionParameters.Message.ContentType.MessageContent] = []
        if !text.isEmpty {
            parts.append(.text(text))
        }
        for image in transientImages {
            if let annotation = image.titleAnnotation {
                parts.append(.text(annotation))
            }
            guard let imageURL = URL(string: image.openAIDataURL) else { continue }
            parts.append(.imageUrl(.init(url: imageURL, detail: nil)))
        }
        return .contentArray(parts)
    }

    private func openAIResponsesContent(text: String) -> SwiftOpenAI.MessageContent {
        var parts: [SwiftOpenAI.ContentItem] = []
        if !text.isEmpty {
            parts.append(.text(SwiftOpenAI.TextContent(text: text)))
        }
        for image in transientImages {
            if let annotation = image.titleAnnotation {
                parts.append(.text(SwiftOpenAI.TextContent(text: annotation)))
            }
            parts.append(.image(SwiftOpenAI.ImageContent(detail: "auto", imageUrl: image.openAIDataURL)))
        }
        return .array(parts)
    }

    // MARK: - Temperature helpers

    /// Returns the final temperature to send for a specific model,
    /// respecting global on/off and per-model overrides.
    func effectiveTemperature(for model: AIModel) -> Double? {
        // 1) Explicit per-model override stored by the user.
        if let override = ModelOverridesSettings.shared
            .temperatureOverride(for: model.rawValue)
        {
            return override
        }

        // 2) Global temperature selected by the user.
        if let global = temperature, global != 0.0 {
            return global
        }

        // 3) Built-in per-model default (if any).  If `nil`, omit the field.
        return model.defaultTemperature
    }
}

struct OverallSummary: Codable {
    let overall_summary: String
}

struct AIResponse: Identifiable, Equatable {
    let id = UUID()
    let fileName: String
    let relativePath: String
    var fileContent: [String]
    var changes: [FileChange]
    var appliedChanges: Set<UUID> = []
    var rejectedChanges: Set<UUID> = []
}

struct FileChange: Identifiable, Equatable, Codable {
    let id: UUID
    let description: String
    var startLine: Int
    var diffChunk: DiffChunk
    static let dummy = FileChange(id: UUID(), startLine: 0, description: "No change", diffChunk: DiffChunk(lines: [], startLine: 0))

    enum CodingKeys: String, CodingKey {
        case startLine = "start_line"
        case description
        case chunk
    }

    init(id: UUID = UUID(), startLine: Int, description: String, diffChunk: DiffChunk) {
        self.id = id
        self.startLine = startLine
        self.description = description
        self.diffChunk = diffChunk
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        startLine = try container.decode(Int.self, forKey: .startLine)
        description = try container.decode(String.self, forKey: .description)
        let chunkLines = try container.decode([String].self, forKey: .chunk)
        diffChunk = DiffChunk(lines: chunkLines.map { DiffLine(content: $0) }, startLine: startLine)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startLine, forKey: .startLine)
        try container.encode(description, forKey: .description)
        try container.encode(diffChunk.lines.map(\.rawContent), forKey: .chunk)
    }

    /// New function to print all lines in the file change
    func printAllLines() {
        print("File Change ID: \(id)")
        print("Description: \(description)")
        print("Start Line: \(startLine)")
        print("Diff Chunk:")
        for (index, line) in diffChunk.lines.enumerated() {
            print("  Line \(index + 1): \(line.rawContent)")
        }
        print("") // Empty line for better readability
    }

    /// A stable, human-readable identity built from the change's content.
    ///
    /// *Important*: use the immutable `diffChunk.startLine` rather than the
    /// mutable `startLine`.
    /// When changes are applied (or reverted) `startLine` is adjusted,
    /// causing any key computed from it *afterwards* to drift.
    /// Persisting that drifting key made most changes fail to match during a
    /// restore – we’d only hit whichever change happened not to shift.
    var contentKey: String {
        [
            description.trimmingCharacters(in: .whitespacesAndNewlines),
            String(diffChunk.startLine), // ← fixed
            diffChunk.lines.map(\.rawContent).joined(separator: "\n")
        ]
        .joined(separator: "|")
    }
}
