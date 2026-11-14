import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptFoundation
import RepoPromptInstrumentation
import RepoPromptSettingsCore
import RepoPromptShared
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

struct AgentSlashSkillToken: Equatable {
    let name: String
    let tokenRange: NSRange
    let argumentsRange: NSRange
}

struct AgentResolvedSlashSkillInvocation: Equatable {
    let definition: AgentSkillDefinition
    let token: AgentSlashSkillToken
}

/// Actual provider-input construction. Workspace roots, lookup scope and content storage are
/// supplied explicitly by composition; this service never selects a window or an active tab.
@MainActor
final class AgentSessionProviderInputRuntime {
    let skillCatalog: AgentSkillCatalog
    private let perfRecorder: any AgentModePerfRecording
    #if DEBUG
        var test_afterProviderInputAugmentation: (@MainActor () async -> Void)?
    #endif

    init(skillCatalog: AgentSkillCatalog, perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()) {
        self.skillCatalog = skillCatalog
        self.perfRecorder = perfRecorder
    }

    /// Captured content authority and lookup scope for this input, not a selected-window query.
    struct Context {
        let store: WorkspaceFileContextStore
        let lookup: WorkspaceLookupContext
    }

    func finishUserMessage(
        _ text: String,
        attachments: [AgentFileAttachment],
        taggedFileAttachments: [AgentTaggedFileAttachment],
        agent: AgentProviderKind,
        context: Context?,
        session: AgentTabSession?,
        handoff: AgentSessionHandoffRuntime,
        ignoresPendingHandoff: Bool,
        isCurrent: @MainActor () -> Bool,
        onTaggedFileFailures: ([ExplicitFileFailure]) -> Void = { _ in }
    ) async -> String {
        let tagged = await Self.prepareTaggedFileContents(text, taggedFileAttachments: taggedFileAttachments, context: context)
        let withTaggedFiles = tagged.warningText
        guard isCurrent() else { return withTaggedFiles }
        onTaggedFileFailures(tagged.failures)
        let rendered = Self.renderProviderMessage(text: withTaggedFiles, attachments: attachments, agent: agent)
        if let session, !ignoresPendingHandoff {
            return handoff.prependPendingHandoffIfNeeded(rendered, session: session)
        }
        return rendered
    }

    private static let taggedFileTrailingTrimSet = CharacterSet(charactersIn: ").,;:!?]}")
    private static let taggedFileTerminatingScalars = CharacterSet.whitespacesAndNewlines
    nonisolated static let taggedFileContentsTokenBudget = 12000
    nonisolated static let taggedFileContentsMaxFiles = 5
    private static let slashSkillNameScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

    func resolvedSlashSkillInvocations(in text: String, agentKind: AgentProviderKind) -> [AgentResolvedSlashSkillInvocation] {
        Self.extractSlashSkillTokens(from: text).compactMap { token in
            // Keep Claude's native maintenance command distinct from a same-named local skill.
            // The skill remains reachable via the existing explicit /skill: namespace.
            if agentKind == .claudeCode,
               token.name.lowercased() == AgentProviderControlCommand.Kind.compact.rawValue
            {
                return nil
            }
            let resolvedName: String = {
                let normalizedName = token.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if normalizedName.lowercased().hasPrefix("skill:") {
                    return String(normalizedName.dropFirst("skill:".count))
                }
                return normalizedName
            }()
            guard !resolvedName.isEmpty,
                  let definition = skillCatalog.resolve(name: resolvedName)
            else {
                return nil
            }
            return AgentResolvedSlashSkillInvocation(definition: definition, token: token)
        }
    }

    /// Extract a slash-skill token only when `/` is the first non-whitespace character in the text.
    /// This allows literal slashes deeper in the input (e.g. file paths) without triggering skill expansion.
    static func extractSlashSkillTokens(from text: String) -> [AgentSlashSkillToken] {
        guard !text.isEmpty else { return [] }
        let fullText = text as NSString
        let length = fullText.length
        guard length > 0 else { return [] }

        // Find the first non-whitespace character; it must be `/` for a skill token.
        var slashIndex = 0
        while slashIndex < length {
            let ch = fullText.character(at: slashIndex)
            if let scalar = UnicodeScalar(ch), CharacterSet.whitespacesAndNewlines.contains(scalar) {
                slashIndex += 1
                continue
            }
            break
        }
        guard slashIndex < length, fullText.character(at: slashIndex) == 47 /* "/" */ else {
            return []
        }

        // Scan the skill name immediately after the `/`
        var cursor = slashIndex + 1
        var hasNameCharacter = false
        var isInvalidToken = false
        while cursor < length {
            let current = fullText.character(at: cursor)
            guard let scalar = UnicodeScalar(current) else {
                isInvalidToken = true
                break
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                break
            }
            if Self.slashSkillNameScalars.contains(scalar) {
                hasNameCharacter = true
                cursor += 1
                continue
            }
            if scalar == ":",
               fullText.substring(with: NSRange(location: slashIndex + 1, length: cursor - slashIndex - 1)).lowercased() == "skill"
            {
                hasNameCharacter = true
                cursor += 1
                continue
            }
            isInvalidToken = true
            break
        }

        guard hasNameCharacter, !isInvalidToken else { return [] }

        let nameRange = NSRange(location: slashIndex + 1, length: cursor - slashIndex - 1)
        let name = fullText.substring(with: nameRange)
        let tokenRange = NSRange(location: slashIndex, length: cursor - slashIndex)
        let argumentsRange = NSRange(location: cursor, length: length - cursor)
        return [AgentSlashSkillToken(name: name, tokenRange: tokenRange, argumentsRange: argumentsRange)]
    }

    static func renderProviderMessage(
        text: String,
        attachments: [AgentFileAttachment],
        agent: AgentProviderKind
    ) -> String {
        guard !attachments.isEmpty else { return text }
        switch agent {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .openCode, .cursor, .antigravity:
            return renderAtPathAttachmentMessage(text: text, attachments: attachments)
        case .codexExec, .grokBuild, .devin:
            // These transports deliver pixels natively but no file path, so the agent could not
            // otherwise name the file in ask_oracle `attachments`.
            return renderAttachmentPathNote(text: text, attachments: attachments)
        }
    }

    static let attachmentPathNoteHeader =
        "Attached files (to share one with the Oracle, pass its path in ask_oracle `attachments`):"

    private static func renderAttachmentPathNote(text: String, attachments: [AgentFileAttachment]) -> String {
        let paths = attachments.compactMap { attachment -> String? in
            guard case let .localFile(path) = attachment.source else { return nil }
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !paths.isEmpty else { return text }
        let note = ([Self.attachmentPathNoteHeader] + paths.map { "- \($0)" }).joined(separator: "\n")
        return text.isEmpty ? note : text + "\n\n" + note
    }

    private static func renderAtPathAttachmentMessage(text: String, attachments: [AgentFileAttachment]) -> String {
        var lines: [String] = []
        for attachment in attachments {
            switch attachment.source {
            case let .localFile(path):
                let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedPath.isEmpty else { continue }
                lines.append("@\(escapePathForAtCommand(trimmedPath))")
            case let .url(url):
                let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedURL.isEmpty else { continue }
                lines.append(trimmedURL)
            }
        }
        guard !lines.isEmpty else { return text }
        if !text.isEmpty {
            lines.append("")
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func escapePathForAtCommand(_ path: String) -> String {
        var escaped = ""
        for character in path {
            switch character {
            case "\\", " ", ",", ";", "!", "?", "(", ")", "[", "]", "{", "}":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    static func extractTaggedPaths(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let scalars = Array(text.unicodeScalars)
        var ordered: [String] = []
        ordered.reserveCapacity(8)
        var seen = Set<String>()
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "@" else {
                index += 1
                continue
            }
            if index > 0 {
                let previous = scalars[index - 1]
                if !taggedFileTerminatingScalars.contains(previous) {
                    index += 1
                    continue
                }
            }

            var cursor = index + 1
            var tokenScalars: [UnicodeScalar] = []
            var isEscaped = false

            while cursor < scalars.count {
                let current = scalars[cursor]
                if isEscaped {
                    tokenScalars.append(current)
                    isEscaped = false
                    cursor += 1
                    continue
                }
                if current == "\\" {
                    isEscaped = true
                    cursor += 1
                    continue
                }
                if taggedFileTerminatingScalars.contains(current) {
                    break
                }
                tokenScalars.append(current)
                cursor += 1
            }

            var token = String(String.UnicodeScalarView(tokenScalars))
            token = token.trimmingCharacters(in: taggedFileTrailingTrimSet)
            if !token.isEmpty {
                let lowered = token.lowercased()
                if !lowered.hasPrefix("/"),
                   !lowered.hasPrefix("~"),
                   !lowered.hasPrefix("file://"),
                   seen.insert(token).inserted
                {
                    ordered.append(token)
                }
            }

            index = cursor
        }

        return ordered
    }

    static func unescapeTaggedPath(_ value: String) -> String {
        guard value.contains("\\") else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let scalars = Array(value.unicodeScalars)
        var output: [UnicodeScalar] = []
        output.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let current = scalars[index]
            if current == "\\", index + 1 < scalars.count {
                let next = scalars[index + 1]
                switch next {
                case "\\", " ", ",", ";", "!", "?", "(", ")", "[", "]", "{", "}":
                    output.append(next)
                default:
                    output.append(current)
                    output.append(next)
                }
                index += 2
                continue
            }
            output.append(current)
            index += 1
        }
        return String(String.UnicodeScalarView(output)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func taggedFileContentsXMLForTaggedPaths(
        _ taggedPaths: [String],
        tokenBudget: Int,
        maxFiles: Int,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext = .visibleWorkspace
    ) async -> String? {
        let result = await prepareTaggedFileContents(
            "", taggedFileAttachments: [], context: .init(store: store, lookup: lookupContext),
            tokenBudget: tokenBudget, maxFiles: maxFiles, inferredPaths: taggedPaths
        )
        return result.text.isEmpty ? nil : result.text
    }

    nonisolated static func externalTaggedFileBlock(displayPath: String, content: String) -> String {
        let fence = PromptPackagingService.codeFenceStart(for: displayPath)
        return """
        File: \(displayPath)
        \(fence)
        \(content)
        ```
        """
    }

    @MainActor
    func expandSlashSkillInvocationIfNeeded(
        _ text: String,
        agentKind: AgentProviderKind,
        workspacePaths: [String],
        shouldPublishCatalog: @MainActor () -> Bool = { true }
    ) async -> String {
        guard !text.isEmpty else { return text }
        let effectiveAgent = agentKind
        await skillCatalog.refreshIfNeeded(workspacePaths: workspacePaths, agentKind: effectiveAgent, shouldPublish: shouldPublishCatalog)
        guard shouldPublishCatalog() else { return text }
        var invocations = resolvedSlashSkillInvocations(in: text, agentKind: effectiveAgent)

        // Defensive fallback: if slash-skill tokens were detected syntactically but none
        // resolved (e.g. a skill was just installed and we missed the dirty signal),
        // force-refresh once and retry resolution.
        if invocations.isEmpty {
            let syntacticTokens = Self.extractSlashSkillTokens(from: text)
            if !syntacticTokens.isEmpty {
                await skillCatalog.refresh(workspacePaths: workspacePaths, agentKind: effectiveAgent, shouldPublish: shouldPublishCatalog)
                guard shouldPublishCatalog() else { return text }
                invocations = resolvedSlashSkillInvocations(in: text, agentKind: effectiveAgent)
            }
        }

        guard invocations.count == 1, let invocation = invocations.first else {
            return text
        }
        guard let renderedBody = renderSlashSkillBody(for: invocation, sourceText: text) else {
            return text
        }
        return composeSlashSkillPromptBlock(
            definition: invocation.definition,
            renderedBody: renderedBody
        )
    }

    private func renderSlashSkillBody(
        for invocation: AgentResolvedSlashSkillInvocation,
        sourceText: String
    ) -> String? {
        let template = AgentWorkflowDefinition.stripYAMLFrontmatter(invocation.definition.template)
        let trimmedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTemplate.isEmpty else {
            return nil
        }

        let fullText = sourceText as NSString
        let argsText = fullText.substring(with: invocation.token.argumentsRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedUserInstructions = renderSlashSkillUserInstructions(argsText)
        if trimmedTemplate.contains("$ARGUMENTS") {
            return trimmedTemplate.replacingOccurrences(of: "$ARGUMENTS", with: renderedUserInstructions)
        }
        guard !renderedUserInstructions.isEmpty else {
            return trimmedTemplate
        }
        return "\(trimmedTemplate)\n\n\(renderedUserInstructions)"
    }

    private func renderSlashSkillUserInstructions(_ argsText: String) -> String {
        let trimmedArgs = argsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArgs.isEmpty else {
            return ""
        }
        return """
        <user_instructions>
        \(trimmedArgs)
        </user_instructions>
        """
    }

    private func composeSlashSkillPromptBlock(
        definition: AgentSkillDefinition,
        renderedBody: String
    ) -> String {
        let promptContext = skillCatalog.promptContext(for: definition)
        let escapedName = Self.escapePromptXMLAttribute(definition.name)
        let escapedScope = Self.escapePromptXMLAttribute(promptContext.scopeLabel)
        let escapedSource = Self.escapePromptXMLAttribute(promptContext.sourceLabel)

        var sections = [
            """
            <selected_skill_context name="\(escapedName)" scope="\(escapedScope)" source="\(escapedSource)">
            The selected /\(definition.name) skill content is already included below.
            Treat any <user_instructions> block as the user's live instructions for this skill invocation.
            Do not re-read the skill file unless the user explicitly asks you to inspect or modify the skill itself.
            </selected_skill_context>
            """
        ]

        if let directoryTree = promptContext.directoryTree?.trimmingCharacters(in: .whitespacesAndNewlines), !directoryTree.isEmpty {
            sections.append(
                """
                <skill_directory_tree>
                \(directoryTree)
                </skill_directory_tree>
                """
            )
        }

        sections.append(renderedBody)
        return sections.joined(separator: "\n\n")
    }

    private static func escapePromptXMLAttribute(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    @MainActor
    static func augmentUserMessageWithTaggedFileContents(
        _ text: String,
        taggedFileAttachments: [AgentTaggedFileAttachment] = [],
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext = .visibleWorkspace
    ) async -> String {
        await prepareTaggedFileContents(
            text, taggedFileAttachments: taggedFileAttachments, context: .init(store: store, lookup: lookupContext)
        ).warningText
    }

    func buildHeadlessAgentMessage(
        session: AgentTabSession,
        initialMessageForRun: String,
        attachments: [AgentFileAttachment],
        links: AgentSessionLinkExecutionRuntime
    ) -> AgentMessage {
        // Build initial message - for providers with resumable sessions, use --resume when available.
        let supportsSessionResume = session.selectedAgent.usesClaudeNativeRuntime || session.selectedAgent.acpProviderID != nil
        // Fresh handoff tabs already carry their continuity inside the staged
        // <forked_session> payload injected into the first user turn. Replaying
        // the migrated local transcript as <previous_conversation> would duplicate
        // that context for the model.
        // Keyed on `isStagedForSend`, not `hasPayload`: the bypass exists because the payload was
        // prepended into `initialMessageForRun`, and staging is the only signal that it actually was.
        // A direct start that deliberately left a payload untouched must still replay history, or the
        // turn would carry neither the handoff nor the conversation.
        let shouldBypassHistoryReplay = (session.pendingHandoff.providerSwitchDelivery != nil && session.pendingHandoff.isStagedForSend)
            || (session.oversight.pendingAutoWake?.isPeriodic != true && session.pendingHandoff.isStagedForSend)
            || (supportsSessionResume && (session.providerSessionID != nil || !attachments.isEmpty))
        let fullMessage: String
        let resumeSessionID: String?

        if shouldBypassHistoryReplay {
            // Resumable providers handle conversation continuity natively.
            // Also keep attachment references at top-level (not wrapped) for image turns.
            fullMessage = initialMessageForRun
            resumeSessionID = session.providerSessionID
        } else {
            // Non-resumable agents: include conversation history in prompt.
            //
            // Rebuilding from the transcript resets what the provider knows, and the transcript never
            // contains the oversight supplement — it is a provider-only envelope that deliberately
            // never becomes an `AgentChatItem`. Any acknowledgement a previous context earned is
            // therefore not true of this one, so the supplement is re-owed before the claim for this
            // turn is composed downstream.
            links.agentSessionLinkReoweSupplementForRebuiltProviderContext(for: session)
            let conversationHistory = buildConversationHistory(for: session)
            fullMessage = conversationHistory.isEmpty
                ? initialMessageForRun
                : """
                <previous_conversation>
                \(conversationHistory)
                </previous_conversation>
                \("")
                <current_instruction>
                \(initialMessageForRun)
                </current_instruction>
                """
            resumeSessionID = nil
        }

        // Create agent message with system prompt for interactive assistance
        let systemPrompt = SystemPromptService.agentModePrompt(
            agentKind: session.selectedAgent,
            taskLabelKind: session.mcpControlContext?.taskLabelKind,
            codeMapsDisabled: GlobalSettingsStore.shared.globalCodeMapsDisabled()
        )
        return AgentMessage(systemPrompt: systemPrompt, userMessage: fullMessage, resumeSessionID: resumeSessionID)
    }

    func buildConversationHistory(for session: AgentTabSession) -> String {
        AgentTranscriptIO.buildConversationHistory(from: session.transcript, perfRecorder: perfRecorder) { request in
            Self.renderProviderMessage(
                text: request.text,
                attachments: request.attachments,
                agent: session.selectedAgent
            )
        }
    }
}
