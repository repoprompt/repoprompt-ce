import Foundation
import RepoPromptAIContracts
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

extension AgentSessionProviderInputRuntime {
    /// Concrete inputs to the existing permissive presentation lookup policy. This is not
    /// canonical admission: a saved runtime must supply an independently validated context.
    struct WorkspaceSource {
        let store: WorkspaceFileContextStore
        let lookupSource: AgentWorkspaceLookupContextSource?

        func lookupContext() async -> WorkspaceLookupContext {
            guard let lookupSource else { return .visibleWorkspace }
            return await AgentWorkspaceLookupContextResolver.lookupContext(source: lookupSource, store: store)
        }
    }

    struct InitialThreadInput {
        let workspace: WorkspaceSource
        let selection: StoredSelection
        let promptText: String?
    }

    func augmentUserMessage(
        _ text: String,
        attachments: [AgentFileAttachment],
        taggedFileAttachments: [AgentTaggedFileAttachment],
        agent: AgentProviderKind,
        workspacePaths: [String],
        workspace: @MainActor () -> WorkspaceSource?,
        session: AgentTabSession?,
        handoff: AgentSessionHandoffRuntime,
        ignoresPendingHandoff: Bool,
        skipsSlashExpansion: Bool,
        isCurrent: @MainActor () -> Bool,
        onTaggedFileFailures: ([ExplicitFileFailure]) -> Void = { _ in }
    ) async -> String {
        guard isCurrent() else { return text }
        let expanded = skipsSlashExpansion ? text : await expandSlashSkillInvocationIfNeeded(
            text, agentKind: agent, workspacePaths: workspacePaths, shouldPublishCatalog: isCurrent
        )
        guard isCurrent() else { return expanded }
        // Resolve mutable worktree bindings after skill discovery, at the same boundary as
        // the original input path. Composition captures values here; it does not perform IO.
        let context: Context? = if let workspace = workspace() {
            await Context(store: workspace.store, lookup: workspace.lookupContext())
        } else {
            nil
        }
        guard isCurrent() else { return expanded }
        return await finishUserMessage(
            expanded, attachments: attachments, taggedFileAttachments: taggedFileAttachments,
            agent: agent, context: context, session: session, handoff: handoff,
            ignoresPendingHandoff: ignoresPendingHandoff, isCurrent: isCurrent,
            onTaggedFileFailures: onTaggedFileFailures
        )
    }

    /// Read-only composer admission: skill and file bytes are captured before any user state changes.
    func prepareUserInput(
        _ text: String,
        taggedFileAttachments: [AgentTaggedFileAttachment],
        agent: AgentProviderKind,
        workspacePaths: [String],
        workspace: @MainActor () -> WorkspaceSource?,
        skipsSlashExpansion: Bool,
        isCurrent: @MainActor () -> Bool
    ) async -> TaggedFileAugmentation {
        guard isCurrent() else { return .init(text: text, includedPaths: [], failures: []) }
        let expanded = skipsSlashExpansion ? text : await expandSlashSkillInvocationIfNeeded(
            text, agentKind: agent, workspacePaths: workspacePaths, shouldPublishCatalog: isCurrent
        )
        guard isCurrent() else { return .init(text: text, includedPaths: [], failures: []) }
        let context: Context? = if let source = workspace() {
            await Context(store: source.store, lookup: source.lookupContext())
        } else { nil }
        guard isCurrent() else { return .init(text: text, includedPaths: [], failures: []) }
        return await Self.prepareTaggedFileContents(expanded, taggedFileAttachments: taggedFileAttachments, context: context)
    }

    /// Resource capture remains host-composed; context construction and admission are runtime work.
    /// Refused work must not capture successor resources or publish its result into a new start.
    func buildInitialThreadMessageIfNeeded(
        session: AgentTabSession,
        initialMessage: String,
        input: @MainActor () -> InitialThreadInput?,
        isCurrent: @MainActor () -> Bool
    ) async -> String {
        guard isCurrent(), Self.shouldIncludeInitialThreadContext(for: session),
              let input = input(), isCurrent() else { return initialMessage }
        let context = await initialThreadContext(input)
        guard isCurrent() else { return initialMessage }
        return Self.composeInitialThreadMessage(
            initialMessage: initialMessage, fileTree: context.fileTree, promptText: context.promptText
        )
    }

    func initialThreadContext(_ input: InitialThreadInput) async -> (fileTree: String, promptText: String?) {
        let lookup = await input.workspace.lookupContext()
        let tree = await AgentProviderContextBuilder.initialFileTree(
            selection: input.selection, store: input.workspace.store, lookupContext: lookup
        )
        return (tree, input.promptText)
    }

    static func shouldIncludeInitialThreadContext(for session: AgentTabSession) -> Bool {
        guard session.providerSessionID == nil else { return false }
        guard !session.items.contains(where: itemBlocksInitialThreadContext) else { return false }
        let userMessageCount = session.items.enumerated().reduce(into: 0) { partialResult, entry in
            let (index, item) = entry
            if item.kind == .user,
               !item.isLocalControlPlaneEcho,
               !Self.isGoalObjectiveControlEcho(item, at: index, in: session.items)
            {
                partialResult += 1
            }
        }
        return userMessageCount <= 1
    }

    private static func isGoalObjectiveControlEcho(_ item: AgentChatItem, at index: Int, in items: [AgentChatItem]) -> Bool {
        guard item.kind == .user else { return false }
        let objective = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else { return false }
        let expectedResultPrefix = "Set Codex goal: \(objective)"
        return items.dropFirst(index + 1).contains { candidate in
            candidate.kind == .system && candidate.text.contains(expectedResultPrefix)
        }
    }

    private static func itemBlocksInitialThreadContext(_ item: AgentChatItem) -> Bool {
        switch item.kind {
        case .assistant, .assistantInline, .toolCall, .toolResult, .thinking:
            true
        case .user, .system, .error:
            false
        }
    }

    nonisolated static func composeInitialThreadMessage(
        initialMessage: String,
        fileTree: String,
        promptText: String?
    ) -> String {
        let trimmedTree = fileTree.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = promptText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedInstruction = initialMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        var contextSections: [String] = []
        if !trimmedTree.isEmpty {
            contextSections.append("""
            <file_map>
            \(trimmedTree)
            </file_map>
            """)
        }
        if !trimmedPrompt.isEmpty {
            contextSections.append("""
            <current_prompt_content>
            \(trimmedPrompt)
            </current_prompt_content>
            """)
        }
        guard !contextSections.isEmpty else { return initialMessage }
        guard !trimmedInstruction.isEmpty else {
            return contextSections.joined(separator: "\n\n")
        }
        return [initialMessage, contextSections.joined(separator: "\n\n")].joined(separator: "\n\n")
    }
}
