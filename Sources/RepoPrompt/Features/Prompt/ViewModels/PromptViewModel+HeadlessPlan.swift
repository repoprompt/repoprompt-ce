import Foundation

// MARK: - Headless Mode

/// Which system prompt flavor to use for headless generation
enum HeadlessMode {
    case plan // Uses architect/planning system prompt
    case chat // Uses chat system prompt
    case review // Uses review system prompt with git diff
}

// MARK: - Headless Context Snapshot

/// A frozen snapshot of tab state for headless generation.
/// Used when running plan/chat via AIQueriesService without activating the tab.
struct HeadlessContextSnapshot {
    /// The compose tab this snapshot came from
    let tabID: UUID

    /// Effective prompt text for the request
    let promptText: String

    /// Frozen selection from ComposeTabState.selection
    let selection: StoredSelection

    /// Frozen logical-to-physical workspace projection for this request.
    let lookupContext: WorkspaceLookupContext?

    init(
        tabID: UUID,
        promptText: String,
        selection: StoredSelection,
        lookupContext: WorkspaceLookupContext? = nil
    ) {
        self.tabID = tabID
        self.promptText = promptText
        self.selection = selection
        self.lookupContext = lookupContext
    }
}

// MARK: - Headless AIMessage Builders

extension PromptViewModel {
    /// Builds an AIMessage for a headless request from a frozen snapshot.
    /// Does NOT read from live tab state - uses only the snapshot data.
    ///
    /// Headless specifics:
    /// - File tree: auto mode
    /// - Codemaps: auto mode
    /// - Git diff: included only for review
    /// - Warning: NOT included
    /// - System prompt depends on mode (plan uses architect, chat uses default chat, review uses stored review prompt)
    @MainActor
    func buildHeadlessAIMessage(
        from snapshot: HeadlessContextSnapshot,
        model: AIModel,
        mode: HeadlessMode = .plan,
        gitScopeOverride: GitInclusion? = nil,
        gitBaseOverride: String? = nil
    ) async -> AIMessage {
        let effectiveGitScope = mode == .review ? (gitScopeOverride ?? .selected) : .none
        let headlessConfig = PromptContextResolved(
            includeFiles: true,
            includeUserPrompt: true,
            includeMetaPrompts: false,
            includeFileTree: true,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: effectiveGitScope,
            storedPromptIds: []
        )
        let preAssembly = await preAssemblePromptContext(
            cfg: headlessConfig,
            selection: snapshot.selection,
            lookupContext: snapshot.lookupContext ?? allLoadedWorkspaceLookupContext(),
            gitBaseOverride: gitBaseOverride
        )
        let (_, codeEntries) = PromptPackagingService.partitionPromptEntriesForGitDiff(preAssembly.entries)

        // 2. Generate file contents. Preserve legacy formatting unless an authoritative
        // Agent Mode lookup context requires physical paths to be projected logically.
        let displayPathResolver: ((ResolvedPromptFileEntry) -> String?)? = if snapshot.lookupContext != nil {
            { entry in preAssembly.displayPath(for: entry) }
        } else {
            nil
        }
        let fileBlocks = PromptPackagingService.generateFileContents(
            codeEntries,
            filePathDisplay: filePathDisplayOption,
            codemapSnapshots: preAssembly.codemapSnapshots,
            displayPathResolver: displayPathResolver
        )

        // 3. Use the neutral pre-assembly file tree.
        let fileTree = preAssembly.fileTreeContent ?? ""

        // 4. System prompt based on mode
        let systemPrompt: String = {
            switch mode {
            case .plan:
                let custom = customPlanningPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                return custom.isEmpty ? architectPrompt.content : custom
            case .chat:
                return getChatPrompt()
            case .review:
                let reviewPromptID = ChatPreset.BuiltIn.review.storedPromptIds?.first
                if let reviewPromptID,
                   let stored = storedPrompts.first(where: { $0.id == reviewPromptID })
                {
                    var prompt = stored.content
                    prompt += "\n\nYou may include one chat-name tag on its own line near the top: <chatName=\\\"Unique name describing user request\\\"/>"
                    prompt += "\n\nProvide your response in clean, well-formatted Markdown. Use proper headings, lists, code blocks, and other Markdown elements to make your response easy to read and understand. Do not emit machine-readable edit blocks."
                    return prompt
                }
                return getChatPrompt()
            }
        }()

        // 5. Single-user conversation
        let conversation = [ConversationEntry(role: .user, content: snapshot.promptText)]

        let gitDiff = preAssembly.gitDiff

        // 6. Assemble AIMessage (no warning, no meta prompts)
        return PromptPackagingService.buildAIMessage(
            systemPrompt: systemPrompt,
            metaInstructions: [],
            fileTree: fileTree,
            fileContents: fileBlocks,
            gitDiff: gitDiff,
            conversation: conversation,
            temperature: setModelTemperature ? modelTemperature : nil,
            promptSectionsOrder: promptSectionsOrder,
            disabledPromptSections: disabledPromptSections,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop
        )
    }
}
