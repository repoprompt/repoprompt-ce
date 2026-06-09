import Foundation
import RepoPromptCore
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
    enum TailAssemblyStrategy {
        case legacy
        case coreStandardChat
    }

    struct PreparedMessage: Equatable {
        let role: AIProviderInputRole
        let content: String
    }

    struct PreparedOpenAIChatInput: Equatable {
        let messages: [PreparedMessage]
    }

    struct PreparedOpenAIResponsesInput: Equatable {
        let instructions: String?
        let messages: [PreparedMessage]
    }

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

    /// Selects the prompt-tail renderer without changing provider role placement.
    let tailAssemblyStrategy: TailAssemblyStrategy

    /// Immutable Core rendering reused by legacy getters, assembly, and provider adapters.
    private let renderedFactualSnippets: PromptRenderedFactualSnippets

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
        renderedFactualSnippets.fileMap ?? ""
    }

    /// File blocks in XML
    var fileBlocksXML: String {
        renderedFactualSnippets.fileContents ?? ""
    }

    /// Git diff in XML
    var gitDiffXML: String {
        renderedFactualSnippets.gitDiff ?? ""
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
        duplicateUserInstructionsAtTop: Bool = false,
        tailAssemblyStrategy: TailAssemblyStrategy = .legacy
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
        self.tailAssemblyStrategy = tailAssemblyStrategy
        renderedFactualSnippets = Self.renderFactualSnippets(
            fileTree: fileTree,
            fileBlocks: fileBlocks,
            gitDiff: gitDiff
        )
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
        tailAssemblyStrategy = .legacy
        renderedFactualSnippets = Self.renderFactualSnippets(
            fileTree: "",
            fileBlocks: [],
            gitDiff: nil
        )
    }

    /// Builds the text block that must be *prepended* to the **final** user
    /// message, respecting the prompt‑ordering UI.
    ///
    /// - Parameters:
    ///   - embedSystemPrompt:  If `true` the `systemPrompt` is appended to the
    ///     tail instead of being sent as an independent `.system` role.
    /// - Returns: A single string, without leading / trailing blank lines.
    func buildTail(embedSystemPrompt: Bool) -> String {
        let tail = switch tailAssemblyStrategy {
        case .legacy:
            buildLegacyTail()
        case .coreStandardChat:
            buildCoreStandardChatTail()
        }

        guard embedSystemPrompt, !systemPrompt.isEmpty else { return tail }
        guard !tail.isEmpty else { return systemPrompt }
        return [tail, "", systemPrompt].joined(separator: "\n\n")
    }

    private static func renderFactualSnippets(
        fileTree: String,
        fileBlocks: [String],
        gitDiff: String?
    ) -> PromptRenderedFactualSnippets {
        PromptRenderingService.renderFactualSnippets(
            fileTreeContent: fileTree,
            codemapBlocks: [],
            contentBlocks: fileBlocks,
            gitDiff: gitDiff,
            envelopePolicy: .chatStyleTree
        )
    }

    private func buildLegacyTail() -> String {
        var parts: [String] = []

        if duplicateUserInstructionsAtTop,
           let userBlock = conversationMessages.last(where: { $0.role == .user })?.content,
           !userBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            parts.append(userBlock)
        }

        for section in promptSectionsOrder where !disabledPromptSections.contains(section) {
            switch section {
            case .fileMap:
                if !fileTree.isEmpty { parts.append(fileTreeXML) }
            case .fileContents:
                if !fileBlocks.isEmpty { parts.append(fileBlocksXML) }
            case .metaPrompts:
                if !metaPrompts.isEmpty {
                    parts.append(metaPrompts.joined(separator: "\n"))
                }
            case .gitDiff:
                if let diff = gitDiff, !diff.isEmpty {
                    parts.append(gitDiffXML)
                }
            case .userInstructions:
                continue
            }
        }

        return parts.joined(separator: "\n\n")
    }

    private func buildCoreStandardChatTail() -> String {
        let factual = renderedFactualSnippets
        var snippets: [PromptSection: String] = [:]
        snippets[.fileMap] = factual.fileMap
        snippets[.fileContents] = factual.fileContents
        snippets[.gitDiff] = factual.gitDiff

        if !metaPrompts.isEmpty {
            snippets[.metaPrompts] = metaPrompts.joined(separator: "\n")
        }

        // Chat treats user instructions as a top-only duplicate. Keep that app policy
        // outside Core's ordered traversal so repeated/custom orders cannot emit it again,
        // and preserve prewrapped trailing LF/CRLF bytes without layout normalization.
        let assembled = PromptAssemblyBuilder.build(
            order: promptSectionsOrder,
            disabled: disabledPromptSections.union([.userInstructions]),
            duplicateUserInstructionsAtTop: false,
            snippets: snippets,
            layout: .blankLineSeparatedFragments
        )
        guard duplicateUserInstructionsAtTop,
              let userBlock = conversationMessages.last(where: { $0.role == .user })?.content,
              !userBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return assembled
        }
        return assembled.isEmpty ? userBlock : userBlock + "\n\n" + assembled
    }

    func preparedOpenAIChatInput(embedSystemPrompt: Bool) -> PreparedOpenAIChatInput {
        let tail = buildTail(embedSystemPrompt: embedSystemPrompt)
        var messages: [PreparedMessage] = []

        if !embedSystemPrompt, !systemPrompt.isEmpty {
            messages.append(.init(role: .system, content: systemPrompt))
        }

        let lastUserIndex = conversationMessages.lastIndex { $0.role == .user }
        for (index, entry) in conversationMessages.enumerated() {
            let text = entry.role == .user && index == lastUserIndex && !tail.isEmpty
                ? tail + "\n" + entry.content
                : entry.content
            messages.append(.init(
                role: entry.role == .user ? .user : .assistant,
                content: text
            ))
        }

        return PreparedOpenAIChatInput(messages: messages)
    }

    /// Generates the full array of `ChatCompletionParameters.Message` objects
    /// that an OpenAI‑style chat endpoint expects.
    ///
    /// Replaces the old `createMessages` helper (which has been removed from
    /// providers).
    func openAIChatMessages(embedSystemPrompt: Bool) -> [ChatCompletionParameters.Message] {
        preparedOpenAIChatInput(embedSystemPrompt: embedSystemPrompt).messages.map { message in
            let role: ChatCompletionParameters.Message.Role = switch message.role {
            case .system: .system
            case .user: .user
            case .assistant: .assistant
            }
            return .init(role: role, content: .text(message.content))
        }
    }

    func preparedOpenAIResponsesInput() -> PreparedOpenAIResponsesInput {
        let tail = buildTail(embedSystemPrompt: false)
        let additions = tail.isEmpty ? "" : tail + "\n\n"

        var messages: [PreparedMessage] = []
        var firstUser = true
        for entry in conversationMessages {
            switch entry.role {
            case .user:
                let text = firstUser ? additions + entry.content : entry.content
                firstUser = false
                messages.append(.init(role: .user, content: text))
            case .assistant:
                messages.append(.init(role: .assistant, content: entry.content))
            }
        }

        if messages.isEmpty, !additions.isEmpty {
            messages.append(.init(role: .user, content: additions))
        }

        return PreparedOpenAIResponsesInput(
            instructions: systemPrompt.isEmpty ? nil : systemPrompt,
            messages: messages
        )
    }

    /// Generates the full array of `InputItem`s for the Responses API.
    /// All assistant turns remain ordinary `message` objects so no provider
    /// response IDs are required.
    func openAIResponsesInput() -> SwiftOpenAI.InputType {
        let prepared = preparedOpenAIResponsesInput()
        let items = prepared.messages.map { message in
            let role = switch message.role {
            case .system: "system"
            case .user: "user"
            case .assistant: "assistant"
            }
            return SwiftOpenAI.InputItem.message(.init(
                role: role,
                content: .text(message.content)
            ))
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
