import Foundation

/// A single conversation entry
package struct ConversationEntry {
    package enum Role {
        case user
        case assistant
    }

    package let role: Role
    package let content: String

    package init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Keep each piece separate. We also provide "XML getters" for certain fields.
package struct AIMessage {
    /// The main system prompt
    package let systemPrompt: String

    /// Any "meta" instructions, each stored separately
    package let metaPrompts: [String]

    /// The entire file tree (if any)
    package let fileTree: String

    /// File blocks (each block is one file's content)
    package let fileBlocks: [String]

    /// Git diff content (optional)
    package let gitDiff: String?

    /// NEW: Full conversation array, user + AI in order
    package let conversationMessages: [ConversationEntry]

    /// Request-scoped provider payload. Never copied into persisted chat messages.
    package var transientImages: [AITransientImage]

    package let temperature: Double?

    /// User-defined ordering of prompt sections
    package let promptSectionsOrder: [PromptSection]

    /// Sections that should be excluded from the prompt
    package let disabledPromptSections: Set<PromptSection>

    /// Duplicate the user‑instruction block at the very top of the prompt
    package let duplicateUserInstructionsAtTop: Bool

    // MARK: - XML Getter Properties

    /// System prompt in XML
    package var systemPromptXML: String {
        guard !systemPrompt.isEmpty else { return "" }
        return """
        <system_prompt>
        \(systemPrompt)
        </system_prompt>
        """
    }

    /// Meta prompts in XML
    package var metaPromptsXML: String {
        guard !metaPrompts.isEmpty else { return "" }
        var result = "<meta_prompts>\n"
        for meta in metaPrompts {
            result += meta + "\n\n"
        }
        result += "</meta_prompts>"
        return result
    }

    /// File tree in XML
    package var fileTreeXML: String {
        guard !fileTree.isEmpty else { return "" }
        return """
        <file_tree>
        \(fileTree)
        </file_tree>
        """
    }

    /// File blocks in XML
    package var fileBlocksXML: String {
        guard !fileBlocks.isEmpty else { return "" }
        var result = "<file_contents>\n"
        for block in fileBlocks {
            result += block + "\n\n"
        }
        result += "</file_contents>"
        return result
    }

    /// Git diff in XML
    package var gitDiffXML: String {
        guard let diff = gitDiff, !diff.isEmpty else { return "" }
        return """
        <git_diff>
        \(diff)
        </git_diff>
        """
    }

    /// Combine the main sections, skipping anything empty
    package var combinedXML: String {
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

    package init(
        systemPrompt: String,
        metaPrompts: [String] = [],
        fileTree: String = "",
        fileBlocks: [String] = [],
        gitDiff: String? = nil,
        conversationMessages: [ConversationEntry] = [],
        transientImages: [AITransientImage] = [],
        temperature: Double?,
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
        self.transientImages = transientImages
        self.temperature = temperature
        self.promptSectionsOrder = promptSectionsOrder
        self.disabledPromptSections = disabledPromptSections
        self.duplicateUserInstructionsAtTop = duplicateUserInstructionsAtTop
    }

    /// Simpler initializer for "system prompt + user message" usage
    /// (e.g. older single-user instructions approach).
    package init(systemPrompt: String, userMessage: String, temperature: Double? = nil) {
        self.systemPrompt = systemPrompt
        metaPrompts = []
        fileTree = ""
        fileBlocks = []
        gitDiff = nil
        self.temperature = temperature
        // Store the single user message in conversationMessages
        conversationMessages = [
            ConversationEntry(role: .user, content: userMessage)
        ]
        transientImages = []
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
    package func buildTail(embedSystemPrompt: Bool) -> String {
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
                // User-authored block, never auto-prepended.
                continue
            }
        }

        // ───── 3)  Inline system prompt (optional)  ─────
        if embedSystemPrompt, !systemPrompt.isEmpty {
            if !parts.isEmpty { parts.append("") } // blank line separator
            parts.append(systemPrompt)
        }

        return parts.joined(separator: "\n\n")
    }
}
