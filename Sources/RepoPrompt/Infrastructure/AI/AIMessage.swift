import Foundation
import SwiftOpenAI

/// A single conversation entry
struct ConversationEntry {
    enum Role {
        case user
        case assistant
    }

    let role: Role
    let content: String
}

/// Keep each piece separate. We also provide "XML getters" for certain fields.
struct AIMessage {
    /// The main system prompt
    let systemPrompt: String

    /// Any "meta" instructions, each stored separately
    let metaPrompts: [String]

    /// The entire file tree (if any)
    let fileTree: String

    /// File blocks (each block is one file's content)
    let fileBlocks: [String]

    /// Git diff content (optional)
    let gitDiff: String?

    /// NEW: Full conversation array, user + AI in order
    let conversationMessages: [ConversationEntry]

    let temperature: Double?
    let disableTemperatureOverrides: Bool

    /// User-defined ordering of prompt sections
    let promptSectionsOrder: [PromptSection]

    /// Sections that should be excluded from the prompt
    let disabledPromptSections: Set<PromptSection>

    /// Duplicate the user‑instruction block at the very top of the prompt
    let duplicateUserInstructionsAtTop: Bool

    // MARK: - XML Getter Properties

    /// System prompt in XML
    var systemPromptXML: String {
        guard !systemPrompt.isEmpty else { return "" }
        return """
        <system_prompt>
        \(systemPrompt)
        </system_prompt>
        """
    }

    /// Meta prompts in XML
    var metaPromptsXML: String {
        guard !metaPrompts.isEmpty else { return "" }
        var result = "<meta_prompts>\n"
        for meta in metaPrompts {
            result += meta + "\n\n"
        }
        result += "</meta_prompts>"
        return result
    }

    /// File tree in XML
    var fileTreeXML: String {
        guard !fileTree.isEmpty else { return "" }
        return """
        <file_tree>
        \(fileTree)
        </file_tree>
        """
    }

    /// File blocks in XML
    var fileBlocksXML: String {
        guard !fileBlocks.isEmpty else { return "" }
        var result = "<file_contents>\n"
        for block in fileBlocks {
            result += block + "\n\n"
        }
        result += "</file_contents>"
        return result
    }

    /// Git diff in XML
    var gitDiffXML: String {
        guard let diff = gitDiff, !diff.isEmpty else { return "" }
        return """
        <git_diff>
        \(diff)
        </git_diff>
        """
    }

    /// Combine the main sections, skipping anything empty
    var combinedXML: String {
        let sections = [
            systemPromptXML,
            metaPromptsXML,
            fileTreeXML,
            fileBlocksXML,
            gitDiffXML
        ]
        return sections
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    init(
        systemPrompt: String,
        metaPrompts: [String] = [],
        fileTree: String = "",
        fileBlocks: [String] = [],
        gitDiff: String? = nil,
        conversationMessages: [ConversationEntry] = [],
        temperature: Double?,
        disableTemperatureOverrides: Bool = false,
        promptSectionsOrder: [PromptSection],
        disabledPromptSections: Set<PromptSection>,
        duplicateUserInstructionsAtTop: Bool = false
    ) {
        self.systemPrompt = systemPrompt
        self.metaPrompts = metaPrompts
        self.fileTree = fileTree
        self.fileBlocks = fileBlocks
        self.gitDiff = gitDiff
        self.conversationMessages = conversationMessages
        self.temperature = temperature
        self.disableTemperatureOverrides = disableTemperatureOverrides
        self.promptSectionsOrder = promptSectionsOrder
        self.disabledPromptSections = disabledPromptSections
        self.duplicateUserInstructionsAtTop = duplicateUserInstructionsAtTop
    }

    /// Simpler initializer for "system prompt + user message" usage
    /// (e.g. older single-user instructions approach).
    init(systemPrompt: String, userMessage: String, temperature: Double? = nil, disableTemperatureOverrides: Bool = false) {
        self.systemPrompt = systemPrompt
        metaPrompts = []
        fileTree = ""
        fileBlocks = []
        gitDiff = nil
        self.temperature = temperature
        self.disableTemperatureOverrides = disableTemperatureOverrides
        // Store the single user message in conversationMessages
        conversationMessages = [
            ConversationEntry(role: .user, content: userMessage)
        ]
        // Use library defaults for prompt ordering
        promptSectionsOrder = PromptAssemblyBuilder.defaultSectionOrder
        disabledPromptSections = []
        duplicateUserInstructionsAtTop = false
    }

    /// Builds the text block that must be *prepended* to the **final** user
    /// message, respecting the prompt‑ordering UI.
    ///
    /// - Parameters:
    ///   - embedSystemPrompt:  If `true` the `systemPrompt` is appended to the
    ///     tail instead of being sent as an independent `.system` role.
    /// - Returns: A single string, without leading / trailing blank lines.
    func buildTail(embedSystemPrompt: Bool) -> String {
        var parts: [String] = []

        // ───── 1)  Optional *top* copy of the user instructions  ─────
        if duplicateUserInstructionsAtTop,
           let userBlock = conversationMessages.last(where: { $0.role == .user })?.content,
           !userBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            parts.append(userBlock)
        }

        // ───── 2)  Auto‑generated sections in caller‑defined order  ─────
        for section in promptSectionsOrder where !disabledPromptSections.contains(section) {
            switch section {
            case .fileMap:
                if !fileTree.isEmpty {
                    parts.append(fileTreeXML)
                }
            case .fileContents:
                if !fileBlocks.isEmpty {
                    parts.append(fileBlocksXML)
                }
            case .metaPrompts:
                if !metaPrompts.isEmpty {
                    parts.append(metaPrompts.joined(separator: "\n"))
                }
            case .gitDiff:
                if let diff = gitDiff, !diff.isEmpty {
                    parts.append(gitDiffXML)
                }
            case .userInstructions:
                // User-authored block, never auto-prepended.
                continue
            }
        }

        // ───── 3)  Inline system prompt (optional)  ─────
        if embedSystemPrompt, !systemPrompt.isEmpty {
            if !parts.isEmpty {
                parts.append("")
            } // blank line separator
            parts.append(systemPrompt)
        }

        return parts.joined(separator: "\n\n")
    }

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
            msgs.append(.init(role: role, content: .text(text)))
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

        // 2. Walk through the stored conversation.
        for entry in conversationMessages {
            switch entry.role {
            case .user:
                var text = entry.content
                if firstUser {
                    text = additions + text // prepend only once
                    firstUser = false
                }

                let msg = SwiftOpenAI.InputMessage(
                    role: "user",
                    content: .text(text)
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

        // 3. Edge-case: no user message yet but there *is* a tail.
        if items.isEmpty, !additions.isEmpty {
            let msg = SwiftOpenAI.InputMessage(
                role: "user",
                content: .text(additions)
            )
            items.append(.message(msg))
        }

        return .array(items)
    }

    // MARK: - Temperature helpers

    /// Returns the final temperature to send for a specific model,
    /// respecting global on/off and per-model overrides.
    func effectiveTemperature(for model: AIModel) -> Double? {
        if disableTemperatureOverrides {
            return nil
        }
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
