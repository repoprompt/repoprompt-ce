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
    func openAIChatMessages(embedSystemPrompt: Bool) throws -> [ChatCompletionParameters.Message] {
        let planned = try AttachmentEncoding.plan(attachments, route: .openAIChat)
        let tail = buildTail(embedSystemPrompt: embedSystemPrompt)

        var msgs: [ChatCompletionParameters.Message] = []

        if !embedSystemPrompt, !systemPrompt.isEmpty {
            msgs.append(.init(role: .system, content: .text(systemPrompt)))
        }

        let lastUserIndex = conversationMessages.lastIndex { $0.role == .user }

        for (idx, entry) in conversationMessages.enumerated() {
            let role: ChatCompletionParameters.Message.Role = (entry.role == .user)
                ? .user
                : .assistant
            guard entry.role == .user, idx == lastUserIndex else {
                msgs.append(.init(role: role, content: .text(entry.content)))
                continue
            }
            let body = AttachmentEncoding.prependingInlineText(of: planned, to: entry.content)
            let text = tail.isEmpty ? body : tail + "\n" + body
            try msgs.append(.init(role: role, content: openAIChatContent(text: text, planned: planned)))
        }

        if lastUserIndex == nil, !planned.isEmpty {
            let text = AttachmentEncoding.prependingInlineText(of: planned, to: tail)
            try msgs.append(.init(role: .user, content: openAIChatContent(text: text, planned: planned)))
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
    func openAIResponsesInput() throws -> SwiftOpenAI.InputType {
        let planned = try AttachmentEncoding.plan(attachments, route: .openAIResponses)
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
                var text = index == lastUserIndex
                    ? AttachmentEncoding.prependingInlineText(of: planned, to: entry.content)
                    : entry.content
                if firstUser {
                    text = additions + text // prepend only once
                    firstUser = false
                }

                let content = if index == lastUserIndex {
                    try openAIResponsesContent(text: text, planned: planned)
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
           !planned.isEmpty || items.isEmpty && !additions.isEmpty
        {
            let text = AttachmentEncoding.prependingInlineText(of: planned, to: additions)
            let msg = try SwiftOpenAI.InputMessage(
                role: "user",
                content: openAIResponsesContent(text: text, planned: planned)
            )
            items.append(.message(msg))
        }

        return .array(items)
    }

    private func openAIChatContent(
        text: String,
        planned: [PlannedAttachment]
    ) throws -> ChatCompletionParameters.Message.ContentType {
        var parts: [ChatCompletionParameters.Message.ContentType.MessageContent] = []
        if !text.isEmpty {
            parts.append(.text(text))
        }
        var nativeCount = 0
        for item in planned {
            switch item.delivery {
            case let .nativeImage(mediaType, data):
                guard let imageURL = URL(string: AttachmentEncoding.dataURL(mimeType: mediaType.rawValue, data: data)) else {
                    throw AttachmentEncodingInvariant.unencodable(fileName: item.attachment.fileName, route: .openAIChat)
                }
                if let annotation = item.titleAnnotation {
                    parts.append(.text(annotation))
                }
                parts.append(.imageUrl(.init(url: imageURL, detail: nil)))
                nativeCount += 1
            case .inlineText:
                break
            case .nativeDocument:
                throw item.undeclaredRung(on: .openAIChat)
            }
        }
        return nativeCount == 0 ? .text(text) : .contentArray(parts)
    }

    private func openAIResponsesContent(
        text: String,
        planned: [PlannedAttachment]
    ) throws -> SwiftOpenAI.MessageContent {
        var parts: [SwiftOpenAI.ContentItem] = []
        if !text.isEmpty {
            parts.append(.text(SwiftOpenAI.TextContent(text: text)))
        }
        var nativeCount = 0
        for item in planned {
            switch item.delivery {
            case let .nativeImage(mediaType, data):
                if let annotation = item.titleAnnotation {
                    parts.append(.text(SwiftOpenAI.TextContent(text: annotation)))
                }
                parts.append(.image(SwiftOpenAI.ImageContent(
                    detail: "auto",
                    imageUrl: AttachmentEncoding.dataURL(mimeType: mediaType.rawValue, data: data)
                )))
                nativeCount += 1
            case let .nativeDocument(data):
                if let annotation = item.titleAnnotation {
                    parts.append(.text(SwiftOpenAI.TextContent(text: annotation)))
                }
                parts.append(.file(SwiftOpenAI.FileContent(
                    fileData: AttachmentEncoding.dataURL(mimeType: "application/pdf", data: data),
                    filename: item.attachment.fileName
                )))
                nativeCount += 1
            case .inlineText:
                break
            }
        }
        return nativeCount == 0 ? .text(text) : .array(parts)
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
