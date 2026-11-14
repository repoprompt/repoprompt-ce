import Foundation
import RepoPromptAIContracts
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

extension AgentSessionProviderInputRuntime {
    /// Concrete lookup inputs. Canonical composition retains the originating lease checks with
    /// these bytes; the legacy presentation adapter has only its existing enclosing admission.
    /// Neither successful validation nor possession of a snapshot elects a writer.
    struct WorkspaceSource {
        let store: WorkspaceFileContextStore
        let lookupSource: AgentWorkspaceLookupContextSource?
        /// Present only for an exact canonical capture; legacy callers retain their projection.
        let workspacePaths: [String]?
        let isCurrent: @MainActor () -> Bool
        let validate: @MainActor () async -> Bool

        init(
            store: WorkspaceFileContextStore, lookupSource: AgentWorkspaceLookupContextSource?,
            workspacePaths: [String]? = nil,
            isCurrent: @escaping @MainActor () -> Bool = { true },
            validate: @escaping @MainActor () async -> Bool = { true }
        ) {
            self.store = store
            self.lookupSource = lookupSource
            self.workspacePaths = workspacePaths
            self.isCurrent = isCurrent
            self.validate = validate
        }

        func lookupContext() async -> WorkspaceLookupContext {
            guard let lookupSource else { return .visibleWorkspace }
            return await AgentWorkspaceLookupContextResolver.lookupContext(source: lookupSource, store: store)
        }
    }

    /// Legacy presentation bindings are resolved after skill discovery; canonical requests
    /// must first capture the exact resource whose roots authorize that discovery.
    enum WorkspaceCaptureOrder {
        case afterSkillExpansion
        case beforeSkillExpansion
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
        workspace: @MainActor () async throws -> WorkspaceSource?,
        workspaceCaptureOrder: WorkspaceCaptureOrder = .afterSkillExpansion,
        session: AgentTabSession?,
        handoff: AgentSessionHandoffRuntime,
        ignoresPendingHandoff: Bool,
        skipsSlashExpansion: Bool,
        isCurrent: @MainActor () -> Bool,
        onTaggedFileFailures: ([ExplicitFileFailure]) -> Void = { _ in }
    ) async rethrows -> String {
        guard isCurrent() else { return text }
        // Canonical capture supplies both skill roots and rendered context. Legacy callers
        // retain their post-discovery binding lookup; neither path reads the source twice.
        var source: WorkspaceSource?
        if workspaceCaptureOrder == .beforeSkillExpansion {
            source = try await workspace()
        }
        func current() -> Bool {
            isCurrent() && (source?.isCurrent() ?? true)
        }
        guard current() else { return text }
        let expanded = skipsSlashExpansion ? text : await expandSlashSkillInvocationIfNeeded(
            text, agentKind: agent, workspacePaths: source?.workspacePaths ?? workspacePaths, shouldPublishCatalog: current
        )
        guard current() else { return expanded }
        if workspaceCaptureOrder == .afterSkillExpansion {
            source = try await workspace()
        }
        guard current() else { return expanded }
        let context: Context? = if let workspace = source {
            await Context(store: workspace.store, lookup: workspace.lookupContext())
        } else {
            nil
        }
        guard current() else { return expanded }
        let prepared = await finishUserMessage(
            expanded, attachments: attachments, taggedFileAttachments: taggedFileAttachments,
            agent: agent, context: context, session: session, handoff: handoff,
            ignoresPendingHandoff: ignoresPendingHandoff, isCurrent: current,
            onTaggedFileFailures: onTaggedFileFailures
        )
        #if DEBUG
            if current(), agent.acpProviderID != nil {
                await test_afterProviderInputAugmentation?()
            }
        #endif
        return prepared
    }

    /// Read-only composer admission: skill and file bytes are captured before any user state changes.
    func prepareUserInput(
        _ text: String,
        taggedFileAttachments: [AgentTaggedFileAttachment],
        agent: AgentProviderKind,
        workspacePaths: [String],
        workspace: @MainActor () async throws -> WorkspaceSource?,
        workspaceCaptureOrder: WorkspaceCaptureOrder = .afterSkillExpansion,
        skipsSlashExpansion: Bool,
        isCurrent: @MainActor () -> Bool
    ) async rethrows -> TaggedFileAugmentation {
        guard isCurrent() else { return .init(text: text, includedPaths: [], failures: []) }
        var source: WorkspaceSource?
        if workspaceCaptureOrder == .beforeSkillExpansion {
            source = try await workspace()
        }
        func current() -> Bool {
            isCurrent() && (source?.isCurrent() ?? true)
        }
        guard current() else { return .init(text: text, includedPaths: [], failures: []) }
        let expanded = skipsSlashExpansion ? text : await expandSlashSkillInvocationIfNeeded(
            text, agentKind: agent, workspacePaths: source?.workspacePaths ?? workspacePaths, shouldPublishCatalog: current
        )
        guard current() else { return .init(text: text, includedPaths: [], failures: []) }
        if workspaceCaptureOrder == .afterSkillExpansion {
            source = try await workspace()
        }
        guard current() else { return .init(text: text, includedPaths: [], failures: []) }
        let context: Context? = if let source {
            await Context(store: source.store, lookup: source.lookupContext())
        } else { nil }
        guard current() else { return .init(text: text, includedPaths: [], failures: []) }
        let prepared = await Self.prepareTaggedFileContents(expanded, taggedFileAttachments: taggedFileAttachments, context: context)
        guard current() else { return .init(text: text, includedPaths: [], failures: []) }
        return prepared
    }

    /// Resource capture remains host-composed; context construction and admission are runtime work.
    /// Refused work must not capture successor resources or publish its result into a new start.
    func buildInitialThreadMessageIfNeeded(
        session: AgentTabSession,
        initialMessage: String,
        input: @MainActor () async throws -> InitialThreadInput?,
        isCurrent: @MainActor () -> Bool
    ) async rethrows -> String {
        guard isCurrent(), Self.shouldIncludeInitialThreadContext(for: session) else { return initialMessage }
        let captured = try await input()
        guard isCurrent(), let input = captured, input.workspace.isCurrent() else { return initialMessage }
        let context = await initialThreadContext(input)
        guard isCurrent(), input.workspace.isCurrent() else { return initialMessage }
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
