import Foundation
import MCP // <- required for `Value`
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import RepoPromptWorkspaceContext

// MARK: - MCP Tool helpers (moved from MCPServerViewModel)

extension OracleViewModel {
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    enum OracleSendActivationPolicy: Equatable {
        case foregroundWhenActive
        case background
    }

    enum OracleSendPackagingProvenance: Equatable {
        case direct
        case delegated(delegationID: UUID)
    }

    /// Immutable prompt-packaging inputs. These may be source-owned by a launching tab while
    /// `OracleSendTabContext` remains owned by the exact child conversation/session/run.
    struct OracleSendPackagingContext {
        let sourceTabID: UUID
        let sourceWorkspaceID: UUID?
        let sourceSelectionRevision: UInt64
        let sourceAgentSessionID: UUID?
        let sourceAgentRunID: UUID?
        let promptText: String
        let selection: StoredSelection
        let lookupContext: WorkspaceLookupContext?
        let reviewGitContext: FrozenPromptGitReviewContext
        let prebuiltAIMessage: AIMessage?
        let provenance: OracleSendPackagingProvenance

        init(
            sourceTabID: UUID,
            sourceWorkspaceID: UUID?,
            sourceSelectionRevision: UInt64,
            sourceAgentSessionID: UUID?,
            sourceAgentRunID: UUID?,
            promptText: String,
            selection: StoredSelection,
            lookupContext: WorkspaceLookupContext?,
            reviewGitContext: FrozenPromptGitReviewContext,
            prebuiltAIMessage: AIMessage? = nil,
            provenance: OracleSendPackagingProvenance
        ) {
            self.sourceTabID = sourceTabID
            self.sourceWorkspaceID = sourceWorkspaceID
            self.sourceSelectionRevision = sourceSelectionRevision
            self.sourceAgentSessionID = sourceAgentSessionID
            self.sourceAgentRunID = sourceAgentRunID
            self.promptText = promptText
            self.selection = selection
            self.lookupContext = lookupContext
            self.reviewGitContext = reviewGitContext
            self.prebuiltAIMessage = prebuiltAIMessage
            self.provenance = provenance
        }

        init(delegated context: DelegatedAgentRunOracleReviewContext) throws {
            if let reason = context.unavailableReason {
                throw reason
            }
            guard let source = context.capturedSource else {
                throw AgentRunOracleReviewUnavailableReason.sourceCaptureFailed(
                    "The immutable launch snapshot is unavailable."
                )
            }
            let artifactDelegation = SelectedGitArtifactDelegation(
                delegationID: source.delegationID,
                sourceWorkspaceID: source.workspaceID,
                sourceTabID: source.sourceTabID,
                sourceAgentSessionID: source.sourceAgentSessionID,
                sourceAgentRunID: source.sourceAgentRunID,
                targetWorkspaceID: context.target.workspaceID,
                targetTabID: context.target.tabID,
                targetAgentSessionID: context.target.agentSessionID,
                targetAgentRunID: context.targetRunID,
                exactSelectedArtifactPaths: Set(source.exactSelectedIdentities),
                targetBoundCheckouts: context.target.boundCheckouts
            )
            let delegatedReviewContext = FrozenPromptGitReviewContext(
                artifactCapability: source.reviewGitContext.artifactCapability?.delegated(artifactDelegation),
                artifactDelegationConsumer: SelectedGitArtifactDelegationConsumer(
                    workspaceID: context.target.workspaceID,
                    tabID: context.target.tabID,
                    agentSessionID: context.target.agentSessionID,
                    agentRunID: context.targetRunID,
                    boundCheckouts: context.target.boundCheckouts
                ),
                compareIntent: source.reviewGitContext.compareIntent,
                displayContext: source.reviewGitContext.displayContext
            )
            self.init(
                sourceTabID: source.sourceTabID,
                sourceWorkspaceID: source.workspaceID,
                sourceSelectionRevision: source.sourceSelectionRevision,
                sourceAgentSessionID: source.sourceAgentSessionID,
                sourceAgentRunID: source.sourceAgentRunID,
                promptText: source.promptText,
                selection: source.selection,
                lookupContext: source.lookupContext,
                reviewGitContext: delegatedReviewContext,
                provenance: .delegated(delegationID: source.delegationID)
            )
        }
    }

    struct OracleSendTabContext {
        /// Conversation ownership. Never substitute packaging source identity here.
        let tabID: UUID
        let workspaceID: UUID?
        let origin: OracleSendOrigin
        let agentModeSessionID: UUID?
        let agentModeRunID: UUID?
        let activationPolicy: OracleSendActivationPolicy
        let packaging: OracleSendPackagingContext
        let attachments: [OracleAttachment]
        var toolSettlement: OracleToolSettlementCallbacks?

        init(
            tabID: UUID,
            workspaceID: UUID? = nil,
            origin: OracleSendOrigin = .compatibility,
            agentModeSessionID: UUID? = nil,
            agentModeRunID: UUID? = nil,
            activationPolicy: OracleSendActivationPolicy = .foregroundWhenActive,
            packaging: OracleSendPackagingContext,
            attachments: [OracleAttachment] = []
        ) {
            self.tabID = tabID
            self.workspaceID = workspaceID
            self.origin = origin
            self.agentModeSessionID = agentModeSessionID
            self.agentModeRunID = agentModeRunID
            self.activationPolicy = activationPolicy
            self.packaging = packaging
            self.attachments = attachments
        }
    }

    @MainActor
    func resolveOracleStartExecution(
        mode: String,
        modelParam: String?,
        profile: AgentModelsSettingsProfile,
        promptVM: PromptViewModel,
        snapshotOverride: OracleSelectionSnapshot? = nil,
        additionalOracles: [String]? = nil
    ) throws -> ResolvedOracleExecution {
        let snapshot = snapshotOverride ?? .mcp(profile: profile)
        do {
            return try OracleExecutionResolver(promptViewModel: promptVM).resolve(
                choice: modelParam.map(OracleStartChoice.oracleSend) ?? .automatic,
                mode: mode,
                snapshot: snapshot,
                additionalOracles: additionalOracles
            )
        } catch {
            throw ChatToolError.invalidParams(error.localizedDescription)
        }
    }

    @MainActor
    func resolveOracleConversationExecution(
        session: ChatSession,
        mode: String,
        profile: AgentModelsSettingsProfile,
        promptVM: PromptViewModel,
        snapshotOverride: OracleSelectionSnapshot? = nil
    ) throws -> ResolvedOracleExecution {
        guard let modelString = session.preferredAIModel else {
            throw ChatToolError.invalidParams("Oracle conversation has no persisted model.")
        }
        let snapshot = snapshotOverride ?? .mcp(profile: profile)
        do {
            return try OracleExecutionResolver(promptViewModel: promptVM).resolveConversation(
                modelString: modelString,
                persistedChatPresetID: session.selectedChatPresetID,
                mode: mode,
                snapshot: snapshot
            )
        } catch {
            throw ChatToolError.invalidParams(error.localizedDescription)
        }
    }

    @MainActor
    func resolveMCPFollowUpExecution(
        mode: String,
        modelParam: String? = nil,
        workspaceID: UUID? = nil
    ) throws -> ResolvedOracleExecution {
        let profile = GlobalSettingsStore.shared.effectiveAgentModelsProfile(workspaceID: workspaceID)
        return try resolveOracleStartExecution(
            mode: mode,
            modelParam: modelParam,
            profile: profile,
            promptVM: promptViewModel
        )
    }

    /// Builds an array of `Value` objects representing chat history, ready for MCP JSON-RPC responses.
    private func buildMCPMessageLog(from parsedMessages: [AIChatMessage]) -> [Value] {
        var log: [Value] = []
        log.reserveCapacity(parsedMessages.count)

        for msg in parsedMessages {
            let role: String = msg.isUser ? "user" : "assistant"

            let baseText = msg.content

            var dict: [String: Value] = [
                "id": .string(msg.id.uuidString),
                "role": .string(role),
                "is_user": .bool(msg.isUser),
                "text": .string(baseText)
            ]

            /*
             // Include reasoning when available (streaming, not persisted).
             if !msg.isUser {
             	let reasoning = ephemeralState.reasoningContent(for: msg.id)
             	if !reasoning.isEmpty {
             		dict["reasoning"] = .string(reasoning)
             	}
             }
             */
            log.append(.object(dict))
        }

        return log
    }

    /// Builds MCP log output from the currently displayed chat state.
    private func buildMCPMessageLog(includeDiffs: Bool = false, limit: Int? = nil) -> [Value] {
        let messagesToProcess = if let limit, limit > 0 {
            Array(messages.suffix(limit))
        } else {
            messages
        }
        _ = includeDiffs
        return buildMCPMessageLog(from: messagesToProcess)
    }

    /// Builds MCP log output from persisted `StoredMessage` values without switching UI state.
    private func buildMCPMessageLog(
        from storedMessages: [StoredMessage],
        includeDiffs: Bool = false,
        limit: Int? = nil
    ) async -> [Value] {
        let storedToProcess = if let limit, limit > 0 {
            Array(storedMessages.suffix(limit))
        } else {
            storedMessages
        }

        var parsedMessages: [AIChatMessage] = []
        parsedMessages.reserveCapacity(storedToProcess.count)
        for stored in storedToProcess {
            await parsedMessages.append(Self.parseSingleRawMessage(stored))
        }
        _ = includeDiffs
        return buildMCPMessageLog(from: parsedMessages)
    }

    // MARK: - Session resolution helpers

    @MainActor
    func resolveSession(id raw: String?) -> ChatSession? {
        guard let raw, !raw.isEmpty else { return nil }

        // 1️⃣ Exact UUID
        if let uuid = UUID(uuidString: raw) {
            return sessions.first { $0.id == uuid }
        }
        // 2️⃣ shortID
        return sessions.first { $0.shortID == raw }
    }

    @MainActor
    func resolveSessionForExplicitContinuation(
        id rawID: String,
        tabID: UUID?,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?,
        contextBuilderScope: ContextBuilderOracleLaneScope? = nil
    ) async throws -> ChatSession {
        try contextBuilderScope?.checkpoint()
        let session: ChatSession
        if let loaded = resolveSession(id: rawID) {
            session = loaded
        } else {
            guard let tabID,
                  let candidate = workspaceManager.storedBindingCandidate(forContextID: tabID),
                  let workspace = workspaceManager.workspaces.first(where: { $0.id == candidate.workspaceID }),
                  let persisted = try await chatData.findSession(for: workspace, id: rawID, composeTabID: tabID)
            else {
                throw ChatToolError.invalidParams("Chat with ID '\(rawID)' not found")
            }

            try contextBuilderScope?.checkpoint()
            // Inactive headless generation deliberately avoids publishing into the active
            // workspace's chat catalog. Load only an explicitly requested continuation;
            // activation remains disabled for an inactive tab, so currentSession is untouched.
            if !sessions.contains(where: { $0.id == persisted.id }) {
                sessions.append(persisted)
            }
            session = persisted
        }

        guard Self.sessionBelongsToResolvedTab(session, tabID: tabID) else {
            throw ChatToolError.invalidParams("Chat with ID '\(rawID)' belongs to a different tab")
        }
        guard Self.sessionMatchesOracleOwnerForExplicitContinuation(
            session,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID
        ) else {
            throw ChatToolError.invalidParams(
                Self.oracleOwnerRefusalMessage(chatID: rawID, session: session, agentModeSessionID: agentModeSessionID)
            )
        }
        return session
    }

    @MainActor
    private func resolveBackgroundTabID(
        for session: ChatSession,
        fallbackTabID: UUID?,
        contextBuilderScope: ContextBuilderOracleLaneScope? = nil
    ) async -> UUID? {
        guard contextBuilderScope?.isLive != false else { return nil }
        if let tabID = session.composeTabID,
           workspaceManager.composeTab(with: tabID) != nil
        {
            return tabID
        }

        if let fallbackTabID,
           workspaceManager.composeTab(with: fallbackTabID) != nil
        {
            await assignSession(session.id, toTabID: fallbackTabID, setActiveForTab: false)
            return fallbackTabID
        }

        return await ensureTabForSession(session, contextBuilderScope: contextBuilderScope)
    }

    private enum ChatInspectionScope: String {
        case workspace
        case tab
    }

    @MainActor
    private func requestedChatInspectionScope(from args: [String: Value]) -> ChatInspectionScope {
        let rawScope = args["scope"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rawScope == ChatInspectionScope.tab.rawValue {
            return .tab
        }
        let explicitContextID = (args["context_id"] ?? args["tab_id"])?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (explicitContextID?.isEmpty == false) ? .tab : .workspace
    }

    @MainActor
    private func resolvedInspectionTabID(from args: [String: Value]) throws -> UUID? {
        guard requestedChatInspectionScope(from: args) == .tab else { return nil }

        if let rawID = (args["context_id"] ?? args["tab_id"])?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawID.isEmpty
        {
            guard let tabID = UUID(uuidString: rawID) else {
                throw ChatToolError.invalidParams("context_id must be a valid UUID")
            }
            return tabID
        }

        return promptViewModel.activeComposeTabID
    }

    private func sessionNeedsInspectionLoad(_ session: ChatSession) -> Bool {
        session.isListStub || (session.messages.isEmpty && session.effectiveMessageCount > 0)
    }

    private func loadSessionForInspection(_ session: ChatSession) async throws -> ChatSession {
        guard sessionNeedsInspectionLoad(session) else { return session }
        guard let fileURL = session.fileURL else {
            throw ChatToolError.internalError("Chat session '\(session.shortID)' is missing its backing file")
        }
        do {
            return try await chatData.loadChatSession(from: fileURL)
        } catch {
            throw ChatToolError.internalError("Failed to load chat session '\(session.shortID)'")
        }
    }

    @MainActor
    private func resolveSessionForInspection(
        id rawID: String,
        workspace: WorkspaceModel,
        tabID: UUID?
    ) async throws -> ChatSession {
        if let loaded = resolveSession(id: rawID) {
            if let sessionWorkspaceID = loaded.workspaceID, sessionWorkspaceID != workspace.id {
                // Ignore stale in-memory sessions from other workspaces; fall through to disk lookup.
            } else {
                if let tabID, loaded.composeTabID != tabID {
                    throw ChatToolError.invalidParams("Chat with ID '\(rawID)' belongs to a different tab")
                }
                return try await loadSessionForInspection(loaded)
            }
        }

        if let persisted = try await chatData.findSession(for: workspace, id: rawID, composeTabID: tabID) {
            return persisted
        }

        throw ChatToolError.invalidParams("Chat with ID '\(rawID)' not found")
    }

    @MainActor
    private func mostRecentSessionForInspection(
        workspace: WorkspaceModel,
        tabID: UUID?
    ) async throws -> ChatSession {
        if let tabID {
            if let loaded = sessions(forTabID: tabID).sorted(by: { $0.savedAt > $1.savedAt }).first {
                return try await loadSessionForInspection(loaded)
            }
            if let persisted = try await chatData.mostRecentSession(for: workspace, composeTabID: tabID) {
                return persisted
            }
            throw ChatToolError.invalidParams("No chats found in the requested tab")
        }

        if let loaded = sessions.sorted(by: { $0.savedAt > $1.savedAt }).first {
            return try await loadSessionForInspection(loaded)
        }
        if let persisted = try await chatData.mostRecentSession(for: workspace, composeTabID: nil) {
            return persisted
        }
        throw ChatToolError.invalidParams("No chats found in the current workspace")
    }

    @MainActor
    func createSession(
        named name: String?,
        tabID: UUID? = nil,
        activateInUI: Bool = true,
        setActiveForTab: Bool = true,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil
    ) async throws -> ChatSession {
        let safeName = ChatSession.validatedName(name ?? "")
        let createdID = await startNewChatSession(
            name: safeName,
            tabID: tabID,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID,
            activateInUI: activateInUI,
            setActiveForTab: setActiveForTab
        )

        guard let id = createdID ?? currentSessionID,
              let session = sessions.first(where: { $0.id == id })
        else {
            throw ChatToolError.internalError("Failed to create chat session")
        }
        return session
    }

    private static func sessionBelongsToResolvedTab(_ session: ChatSession, tabID: UUID?) -> Bool {
        guard let tabID else { return true }
        return session.composeTabID == tabID
    }

    private static func sessionMatchesOracleOwner(
        _ session: ChatSession,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?,
        allowUnownedLegacy: Bool
    ) -> Bool {
        if !allowUnownedLegacy {
            return session.agentModeSessionID == agentModeSessionID
                && session.agentModeRunID == agentModeRunID
        }
        guard agentModeSessionID != nil || agentModeRunID != nil else {
            return session.agentModeSessionID == nil && session.agentModeRunID == nil
        }

        let sessionIsUnowned = session.agentModeSessionID == nil && session.agentModeRunID == nil
        if sessionIsUnowned {
            return allowUnownedLegacy
        }

        if let agentModeSessionID {
            guard session.agentModeSessionID == agentModeSessionID else { return false }
            if let agentModeRunID {
                if let sessionRunID = session.agentModeRunID {
                    return sessionRunID == agentModeRunID
                }
                return allowUnownedLegacy
            }
            return true
        }

        if let agentModeRunID {
            if let sessionRunID = session.agentModeRunID {
                return sessionRunID == agentModeRunID
            }
            return allowUnownedLegacy && session.agentModeSessionID == nil
        }

        return true
    }

    static func validateRawAttachmentDispatchInvariant(_ args: [String: Value]) throws {
        guard OracleAttachmentContract.redactedArgumentKeys.allSatisfy({ args[$0] == nil }) else {
            throw ChatToolError.internalError(
                "Raw ask_oracle attachment arguments must be consumed before Oracle dispatch."
            )
        }
    }

    static func sessionMatchesOracleOwnerForExplicitContinuation(
        _ session: ChatSession,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?
    ) -> Bool {
        sessionMatchesOracleOwner(
            session,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID,
            allowUnownedLegacy: false
        )
    }

    /// Text for a chat refused by ``sessionMatchesOracleOwnerForExplicitContinuation``. It changes
    /// only the message: a chat stamped with the caller's own Agent session can differ only in its
    /// run, so that case names the run limit and the next step. Every other mismatch keeps the
    /// generic text and reveals nothing about another owner.
    static func oracleOwnerRefusalMessage(
        chatID: String,
        session: ChatSession,
        agentModeSessionID: UUID?
    ) -> String {
        guard let agentModeSessionID, session.agentModeSessionID == agentModeSessionID else {
            return "Chat with ID '\(chatID)' belongs to a different Agent Mode owner"
        }
        return "Chat with ID '\(chatID)' belongs to this Agent session but not to its current run. "
            + "Oracle chats can be continued or read only from the run that created them, and the run can change, "
            + "for example after Stop, Clear chat, or an app relaunch. "
            + "Start a new Oracle chat (new_chat: true) and restate the context you need."
    }

    /// `oracle_chat_log` text when the tab has no chat the caller may read without a `chat_id`.
    static func oracleChatLogNoEligibleChatMessage(agentModeSessionID: UUID?, agentModeRunID: UUID?) -> String {
        guard agentModeSessionID != nil || agentModeRunID != nil else {
            return "No chats found in the current tab"
        }
        return "No Oracle chats from this Agent session's current run were found in the current tab. "
            + "oracle_chat_log cannot read chats from an earlier run (for example before Stop, Clear chat, or an app relaunch) "
            + "or from another Agent session; start a new Oracle chat instead."
    }

    private static func oracleOwnerRank(
        _ session: ChatSession,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?,
        allowUnownedLegacy: Bool
    ) -> Int? {
        guard agentModeSessionID != nil || agentModeRunID != nil else { return 0 }

        let sessionIsUnowned = session.agentModeSessionID == nil && session.agentModeRunID == nil
        if let agentModeSessionID {
            guard session.agentModeSessionID == agentModeSessionID else {
                return (allowUnownedLegacy && sessionIsUnowned) ? 2 : nil
            }
            guard let agentModeRunID else { return 0 }
            if session.agentModeRunID == agentModeRunID { return 0 }
            if session.agentModeRunID == nil, allowUnownedLegacy { return 1 }
            return nil
        }

        if let agentModeRunID {
            if session.agentModeRunID == agentModeRunID { return 0 }
            return (allowUnownedLegacy && sessionIsUnowned) ? 2 : nil
        }

        return 0
    }

    private static func strongestOracleOwnerBucket(
        _ sessions: [ChatSession],
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?,
        allowUnownedLegacy: Bool
    ) -> [ChatSession] {
        let ranked = sessions.compactMap { session -> (session: ChatSession, rank: Int)? in
            guard let rank = oracleOwnerRank(
                session,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID,
                allowUnownedLegacy: allowUnownedLegacy
            ) else { return nil }
            return (session, rank)
        }
        guard let strongestRank = ranked.map(\.rank).min() else { return [] }
        return ranked
            .filter { $0.rank == strongestRank }
            .map(\.session)
            .sorted { $0.savedAt > $1.savedAt }
    }

    @MainActor
    private func applyOracleOwnerIfNeeded(
        sessionID: UUID,
        tabID: UUID?,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?
    ) async {
        guard agentModeSessionID != nil || agentModeRunID != nil else { return }
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        var changed = false
        if let tabID, sessions[index].composeTabID == nil {
            sessions[index].composeTabID = tabID
            changed = true
        }
        if sessions[index].agentModeSessionID == nil, let agentModeSessionID {
            sessions[index].agentModeSessionID = agentModeSessionID
            changed = true
        }
        if sessions[index].agentModeRunID == nil, let agentModeRunID {
            sessions[index].agentModeRunID = agentModeRunID
            changed = true
        }
        guard changed else { return }

        let sessionToSave = sessions[index]
        scheduleTrackedAutosave(for: sessionToSave) { [weak self] in
            guard let self else { return }
            _ = try? await autosaveSession(sessionToSave)
        }
    }

    @MainActor
    private func activateResolvedChatSession(
        _ session: ChatSession,
        resolvedTabID: UUID?,
        activateInUI: Bool,
        contextBuilderScope: ContextBuilderOracleLaneScope? = nil
    ) async {
        guard contextBuilderScope?.isLive != false else { return }
        if activateInUI {
            await switchToSession(session.id)
            return
        }

        _ = await ensureSessionLoadedForBackground(session, contextBuilderScope: contextBuilderScope)
        guard contextBuilderScope?.isLive != false else { return }
        let targetTabID = await resolveBackgroundTabID(
            for: session,
            fallbackTabID: resolvedTabID,
            contextBuilderScope: contextBuilderScope
        )
        guard contextBuilderScope?.isLive != false else { return }
        if let targetTabID {
            workspaceManager.setActiveChatSessionID(session.id, forTabID: targetTabID)
        }
    }

    @MainActor
    func shouldActivateOracleSendSession(
        tabContext: OracleSendTabContext?,
        promptVM: PromptViewModel
    ) -> Bool {
        guard let tabContext else { return true }
        let isFocusedTab = (promptVM.activeComposeTabID == tabContext.tabID) &&
            tabContext.activationPolicy == .foregroundWhenActive
        let activeSessionID = workspaceManager.activeChatSessionID(forTabID: tabContext.tabID)
            ?? currentSessionID.flatMap { currentID in
                sessions.first(where: { $0.id == currentID && $0.composeTabID == tabContext.tabID })?.id
            }
        return isFocusedTab && !isSessionStreaming(activeSessionID)
    }

    @MainActor
    func resolveImplicitOracleContinuationCandidate(
        tabID: UUID? = nil,
        activateInUI: Bool,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil
    ) -> ChatSession? {
        let resolvedTabID = tabID ?? promptViewModel.activeComposeTabID

        func eligible(_ session: ChatSession, allowUnownedLegacy: Bool = true) -> Bool {
            Self.sessionBelongsToResolvedTab(session, tabID: resolvedTabID) &&
                Self.sessionMatchesOracleOwner(
                    session,
                    agentModeSessionID: agentModeSessionID,
                    agentModeRunID: agentModeRunID,
                    allowUnownedLegacy: allowUnownedLegacy
                )
        }

        let hasOwner = agentModeSessionID != nil || agentModeRunID != nil
        let scopedSessions: [ChatSession]
        let activeForTab: UUID?
        if let resolvedTabID {
            scopedSessions = sessions(forTabID: resolvedTabID)
            activeForTab = workspaceManager.activeChatSessionID(forTabID: resolvedTabID)
        } else {
            scopedSessions = sessions
            activeForTab = nil
        }

        let candidates: [ChatSession] = if hasOwner {
            Self.strongestOracleOwnerBucket(
                scopedSessions.filter { Self.sessionBelongsToResolvedTab($0, tabID: resolvedTabID) },
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID,
                allowUnownedLegacy: false
            )
        } else {
            scopedSessions.filter { eligible($0) }
        }

        if let activeForTab,
           let activeCandidate = candidates.first(where: { $0.id == activeForTab })
        {
            return activeCandidate
        }
        if activateInUI,
           let currentSessionID,
           let currentCandidate = candidates.first(where: { $0.id == currentSessionID })
        {
            return currentCandidate
        }
        return candidates.max(by: { $0.savedAt < $1.savedAt })
    }

    /// Ensure the requested chat exists (or create one) and make it active.
    /// Defaults to resuming the most recent chat scoped to the resolved tab/owner.
    @discardableResult
    @MainActor
    func locateOrCreateChat(
        _ idString: String?,
        desiredName: String? = nil,
        forceNew: Bool = false,
        tabID: UUID? = nil,
        activateInUI: Bool = true,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil,
        implicitSessionID: UUID? = nil,
        contextBuilderScope: ContextBuilderOracleLaneScope? = nil
    ) async throws -> UUID {
        try contextBuilderScope?.checkpoint()
        if let activeWorkspace = workspaceManager.activeWorkspace {
            prepareChatSessionCatalog(for: activeWorkspace)
        }
        let resolvedTabID = tabID ?? promptViewModel.activeComposeTabID

        if forceNew {
            let new = try await createSession(
                named: desiredName,
                tabID: resolvedTabID,
                activateInUI: activateInUI,
                setActiveForTab: true,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            )
            return new.id
        }

        if let idString = idString?.trimmingCharacters(in: .whitespacesAndNewlines), !idString.isEmpty {
            let existing = try await resolveSessionForExplicitContinuation(
                id: idString,
                tabID: resolvedTabID,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID,
                contextBuilderScope: contextBuilderScope
            )

            try contextBuilderScope?.checkpoint()
            await applyOracleOwnerIfNeeded(
                sessionID: existing.id,
                tabID: resolvedTabID,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            )
            try contextBuilderScope?.checkpoint()
            await activateResolvedChatSession(existing, resolvedTabID: resolvedTabID, activateInUI: activateInUI, contextBuilderScope: contextBuilderScope)
            try contextBuilderScope?.checkpoint()

            if let newName = desiredName,
               !newName.isEmpty,
               newName != existing.name
            {
                renameSession(id: existing.id, newName: ChatSession.validatedName(newName))
            }
            return existing.id
        }

        let implicitCandidate: ChatSession?
        if let implicitSessionID {
            guard let selected = sessions.first(where: { $0.id == implicitSessionID }) else {
                throw ChatToolError.invalidParams("The selected Oracle chat is no longer available")
            }
            implicitCandidate = selected
        } else {
            implicitCandidate = resolveImplicitOracleContinuationCandidate(
                tabID: resolvedTabID,
                activateInUI: activateInUI,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            )
        }

        if let candidate = implicitCandidate {
            await applyOracleOwnerIfNeeded(
                sessionID: candidate.id,
                tabID: resolvedTabID,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            )
            await activateResolvedChatSession(candidate, resolvedTabID: resolvedTabID, activateInUI: activateInUI)
            if let newName = desiredName,
               !newName.isEmpty,
               newName != candidate.name
            {
                renameSession(id: candidate.id, newName: ChatSession.validatedName(newName))
            }
            return candidate.id
        }

        let new = try await createSession(
            named: desiredName ?? "New Chat",
            tabID: resolvedTabID,
            activateInUI: activateInUI,
            setActiveForTab: true,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID
        )
        return new.id
    }

    /// Full implementation of the shared oracle send backend.
    @MainActor
    func tool_chatSend(
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext? = nil,
        resolvedExecution: ResolvedOracleExecution? = nil,
        resolvedLaneIndex: Int = 0,
        implicitSessionID: UUID? = nil,
        contextBuilderScope: ContextBuilderOracleLaneScope? = nil,
        onQueryCreated: ((UUID) -> Void)? = nil,
        onProgress: ((_ text: String, _ reasoning: String?) -> Void)? = nil,
        backgroundJob: OracleBackgroundInvocationRegistry.Job? = nil,
        backgroundLaneIndex: Int = 0
    ) async throws
        -> [String: Value]
    {
        try contextBuilderScope?.checkpoint()
        // ────────── 1. Validate & extract parameters ──────────
        try Self.validateRawAttachmentDispatchInvariant(args)
        let removedArgs = ["selected_paths", "git_scope", "git_base"].filter { args[$0] != nil }
        if !removedArgs.isEmpty {
            throw ChatToolError.invalidParams(
                "ask_oracle no longer accepts \(removedArgs.joined(separator: ", ")). Use manage_selection for selection and git tools for git context."
            )
        }

        let useTabPrompt = args["use_tab_prompt"]?.boolValue ?? false
        let rawMessage = args["message"]?.stringValue ?? ""

        // Resolve message: either from tab prompt or explicit message parameter
        let message: String
        if useTabPrompt {
            let base = tabContext?.packaging.promptText ?? promptVM.promptText
            message = base.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                throw ChatToolError.invalidParams("Active tab prompt is empty (use_tab_prompt=true)")
            }
        } else {
            message = rawMessage
            guard !message.isEmpty else {
                throw ChatToolError.invalidParams("message cannot be empty")
            }
        }

        let mode = args["mode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "chat"
        guard ["chat", "plan", "review"].contains(mode) else {
            throw ChatToolError.invalidParams("Invalid mode: \(mode). Valid modes: chat, plan, review")
        }
        let chatName = args["chat_name"]?.stringValue
        let chatIdIn = args["chat_id"]?.stringValue
        let newChat = args["new_chat"]?.boolValue ?? false
        _ = args["include_diffs"]?.boolValue
        let selectionOverride = tabContext?.packaging.selection
        let lookupContextOverride = tabContext?.packaging.lookupContext
        let reviewGitContextOverride = tabContext?.packaging.reviewGitContext

        guard let resolvedExecution else {
            throw ChatToolError.internalError("Oracle execution was not resolved before dispatch.")
        }
        guard resolvedExecution.models.indices.contains(resolvedLaneIndex) else {
            throw ChatToolError.internalError("Resolved Oracle lane index is invalid.")
        }
        let selectedModel = resolvedExecution.models[resolvedLaneIndex]
        #if DEBUG
            if let contextBuilderScope { await contextBuilderBeforeChatResolutionForTesting?(contextBuilderScope, selectedModel) }
        #endif
        try contextBuilderScope?.checkpoint()
        let selectionLabel = switch resolvedExecution.selection {
        case let .explicitPreset(_, name): "Model Preset \(name)"
        case let .automaticPreset(_, name): "Automatic Model Preset \(name)"
        case .agentModels: "Agent Models"
        case .rawPrimaryOverride: "Raw model override"
        case .conversation: "Oracle conversation"
        case .contextBuilderUI: "Context Builder"
        }
        let mcpControlledModel = "\(mode.capitalized) mode • \(selectionLabel) (\(selectedModel.displayName))"
        let attachments = tabContext?.attachments ?? []
        if case let .failure(error) = AttachmentPlanner.plan(
            OracleAttachmentSet(attachments),
            route: selectedModel.attachmentRoute,
            limits: .production
        ) {
            throw ChatToolError.invalidParams(error.localizedDescription)
        }
        let overrideModelName = selectedModel.displayName
        let overrideChatPresetName = resolvedExecution.promptConfiguration.chatPreset.name

        // ────────── 3. Resolve chat session ──────────
        let tabID = tabContext?.tabID ?? promptVM.activeComposeTabID
        let shouldActivate = shouldActivateOracleSendSession(tabContext: tabContext, promptVM: promptVM)
        let chatID = try await locateOrCreateChat(
            chatIdIn,
            desiredName: chatName,
            forceNew: newChat,
            tabID: tabID,
            activateInUI: shouldActivate,
            agentModeSessionID: tabContext?.agentModeSessionID,
            agentModeRunID: tabContext?.agentModeRunID,
            implicitSessionID: implicitSessionID,
            contextBuilderScope: contextBuilderScope
        )
        try contextBuilderScope?.checkpoint()
        pinSession(chatID)
        defer { unpinSession(chatID) }

        guard let sessionIndex = sessions.firstIndex(where: { $0.id == chatID }) else {
            throw ChatToolError.internalError("Oracle conversation was not created.")
        }
        let requiresAuthorityPersistence = sessions[sessionIndex].oracleExecutionAuthority == nil
        sessions[sessionIndex].preferredAIModel = selectedModel.rawValue
        sessions[sessionIndex].selectedChatPresetID = resolvedExecution.promptConfiguration.chatPresetID
        sessions[sessionIndex].oracleExecutionAuthority = .frozen
        if requiresAuthorityPersistence {
            let sessionToPersist = sessions[sessionIndex]
            let savedURL = try await autosaveSession(sessionToPersist)
            // Record the write that already happened, even if the lane expired during I/O.
            if let refreshedIndex = sessions.firstIndex(where: { $0.id == chatID }) {
                sessions[refreshedIndex].fileURL = savedURL
                sessions[refreshedIndex].savedAt = Date()
            }
            try contextBuilderScope?.checkpoint()
        }
        setMCPSessionUIState(
            MCPSessionUIState(
                modelInfo: mcpControlledModel,
                overrideModelName: overrideModelName,
                overrideChatPresetName: overrideChatPresetName
            ),
            for: chatID
        )

        // ────────── 4. Determine mode ──────────
        let effectiveMode = PromptViewModel.PlanActMode(rawValue: mode.capitalized) ?? .chat

        // ────────── 5. Send user message & wait for completion ──────────
        // Pass the selected model, chat preset, and mode to sendMessage without affecting global state.
        let send = {
            await self.sendMessage(
                message,
                sessionID: chatID,
                overrideModel: selectedModel,
                overrideChatPresetID: resolvedExecution.promptConfiguration.chatPresetID,
                oraclePromptConfiguration: resolvedExecution.promptConfiguration,
                overrideMode: effectiveMode,
                gitInclusionOverride: nil,
                gitBaseOverride: nil,
                selectionOverride: selectionOverride,
                lookupContextOverride: lookupContextOverride,
                reviewGitContextOverride: reviewGitContextOverride,
                overrideAIMessage: tabContext?.packaging.prebuiltAIMessage,
                oracleAttachments: attachments,
                completionPolicy: contextBuilderScope == nil ? .interactive : .contextBuilderStrict,
                contextBuilderScope: contextBuilderScope,
                onQueryCreated: onQueryCreated,
                onProgress: onProgress,
                backgroundJob: backgroundJob,
                backgroundLaneIndex: backgroundLaneIndex
            )
        }
        let queryId: UUID?
        #if DEBUG
            let trace = OracleReviewPackagingDiagnostics.makeTraceContext(
                tabContext: tabContext,
                observer: oracleReviewPackagingTraceObserverForTesting
            )
            queryId = await OracleReviewPackagingDiagnostics.withTrace(trace, operation: send)
        #else
            queryId = await send()
        #endif
        guard let queryId else {
            // No query exists to clear the label this call set above.
            clearMCPSessionUIState(for: chatID)
            throw OracleContextBuilderCompletionError.missingExactQuery
        }
        let response = try await waitForContextBuilderCompletion(queryId)
        try contextBuilderScope?.admitSuccess()

        // ────────── 6. Build typed reply ──────────
        let replyObj = ChatSendReply(
            chatId: chatID,
            shortId: sessions.first(where: { $0.id == chatID })?.shortID ?? "",
            mode: mode,
            response: response,
            errors: nil
        )

        // Serialise to MCP Value → dictionary
        guard case var .object(dict) = replyObj.toMCPValue() else {
            throw ChatToolError.internalError("failed to encode reply")
        }
        if let tabID {
            dict["context_id"] = .string(tabID.uuidString)
        }
        if let agentModeSessionID = tabContext?.agentModeSessionID {
            dict["agent_session_id"] = .string(agentModeSessionID.uuidString)
        }
        if let agentModeRunID = tabContext?.agentModeRunID {
            dict["agent_run_id"] = .string(agentModeRunID.uuidString)
        }
        return dict
    }

    /// Legacy entry point kept for compatibility with `MCPServerViewModel`.
    /// Delegates to the newer implementation that returns the enriched log.
    @MainActor
    func handleChatGetLogTool(chatIdRaw: String?) async throws -> [String: Value] {
        var args: [String: Value] = ["include_diffs": .bool(false)]
        if let chatIdRaw, !chatIdRaw.isEmpty {
            args["chat_id"] = .string(chatIdRaw)
        }
        return try await tool_chatGetLog(args: args)
    }

    /// Full implementation of **chat_get_log** MCP tool.
    /// Returns a richer, size-optimised message log.
    @MainActor
    func tool_chatGetLog(args: [String: Value]) async throws -> [String: Value] {
        let chatIdIn = args["chat_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let includeDiffs = args["include_diffs"]?.boolValue ?? false
        let limit = args["limit"]?.intValue ?? 3 // Default to 3 messages

        guard let workspace = workspaceManager.activeWorkspace else {
            throw ChatToolError.invalidParams("No active workspace loaded")
        }

        let scope = requestedChatInspectionScope(from: args)
        let tabID = try resolvedInspectionTabID(from: args)
        if scope == .tab, tabID == nil {
            throw ChatToolError.invalidParams("scope=tab requires an active compose tab or an explicit context_id")
        }
        let normalizedChatID = (chatIdIn?.isEmpty == false) ? chatIdIn : nil
        let resolvedSession = if let normalizedChatID {
            try await resolveSessionForInspection(id: normalizedChatID, workspace: workspace, tabID: tabID)
        } else {
            try await mostRecentSessionForInspection(workspace: workspace, tabID: tabID)
        }

        let msgs = await buildMCPMessageLog(from: resolvedSession.messages, includeDiffs: includeDiffs, limit: limit)
        var result: [String: Value] = [
            "chat_id": .string(resolvedSession.shortID),
            "messages": .array(msgs),
            "scope": .string(scope.rawValue)
        ]
        if let resolvedTabID = tabID ?? resolvedSession.composeTabID {
            result["context_id"] = .string(resolvedTabID.uuidString)
        }

        return result
    }

    private static func preferredOracleLogSession(
        forTabID tabID: UUID,
        sessions: [ChatSession],
        activeSessionID: UUID?,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil
    ) -> ChatSession? {
        let tabSessions = sessions.filter { $0.composeTabID == tabID }
        let hasOwner = agentModeSessionID != nil || agentModeRunID != nil
        let sortedCandidates: [ChatSession] = if hasOwner {
            Self.strongestOracleOwnerBucket(
                tabSessions,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID,
                allowUnownedLegacy: false
            )
        } else {
            tabSessions.sorted(by: { $0.savedAt > $1.savedAt })
        }

        if let activeSessionID,
           let activeSession = sortedCandidates.first(where: { $0.id == activeSessionID }),
           activeSession.hasMessages
        {
            return activeSession
        }
        if let mostRecentNonEmpty = sortedCandidates
            .filter(\.hasMessages)
            .first
        {
            return mostRecentNonEmpty
        }
        return sortedCandidates.first
    }

    static func test_preferredOracleLogSession(
        forTabID tabID: UUID,
        sessions: [ChatSession],
        activeSessionID: UUID?,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil
    ) -> ChatSession? {
        preferredOracleLogSession(
            forTabID: tabID,
            sessions: sessions,
            activeSessionID: activeSessionID,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID
        )
    }

    /// Agent-mode helper for a stripped-down, tab-scoped Oracle chat log.
    /// Returns only role/text messages and never creates sessions.
    @MainActor
    func tool_oracleChatLog(
        args: [String: Value],
        tabID: UUID,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil
    ) async throws -> [String: Value] {
        let chatIDIn = args["chat_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedChatID = (chatIDIn?.isEmpty == false) ? chatIDIn : nil

        let limit: Int = {
            guard let rawLimit = args["limit"]?.intValue else { return 8 }
            return min(max(rawLimit, 1), 50)
        }()
        let includeUser = args["include_user"]?.boolValue ?? false

        let resolvedSession: ChatSession
        if let normalizedChatID {
            guard let found = resolveSession(id: normalizedChatID) else {
                throw ChatToolError.invalidParams("Chat with ID '\(normalizedChatID)' not found")
            }
            guard found.composeTabID == tabID else {
                throw ChatToolError.invalidParams(
                    "Chat with ID '\(normalizedChatID)' belongs to a different tab. oracle_utils op='log' can only read chats from the current tab during agent mode."
                )
            }
            guard Self.sessionMatchesOracleOwnerForExplicitContinuation(
                found,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            ) else {
                throw ChatToolError.invalidParams(
                    Self.oracleOwnerRefusalMessage(
                        chatID: normalizedChatID,
                        session: found,
                        agentModeSessionID: agentModeSessionID
                    )
                )
            }
            guard let loaded = await ensureSessionLoadedForBackground(found) else {
                throw ChatToolError.internalError("Failed to load chat session '\(normalizedChatID)'")
            }
            resolvedSession = loaded
        } else {
            guard let preferredSession = Self.preferredOracleLogSession(
                forTabID: tabID,
                sessions: sessions,
                activeSessionID: workspaceManager.activeChatSessionID(forTabID: tabID),
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            ) else {
                throw ChatToolError.invalidParams(
                    Self.oracleChatLogNoEligibleChatMessage(
                        agentModeSessionID: agentModeSessionID,
                        agentModeRunID: agentModeRunID
                    )
                )
            }
            guard let loaded = await ensureSessionLoadedForBackground(preferredSession) else {
                throw ChatToolError.internalError("Failed to load the preferred chat for the current tab")
            }
            resolvedSession = loaded
        }

        let maxCharsPerMessage = 8000
        func compactOracleLogText(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > maxCharsPerMessage else { return trimmed }
            let endIndex = trimmed.index(trimmed.startIndex, offsetBy: maxCharsPerMessage)
            return String(trimmed[..<endIndex]) + "\n… [truncated]"
        }

        let filteredMessages = resolvedSession.messages.filter { includeUser || !$0.isUser }
        let trimmedMessages = Array(filteredMessages.suffix(limit))
        let msgArray: [Value] = trimmedMessages.map { msg in
            .object([
                "role": .string(msg.isUser ? "user" : "assistant"),
                "text": .string(compactOracleLogText(msg.rawText))
            ])
        }

        var result: [String: Value] = [
            "action": .string("log"),
            "chat_id": .string(resolvedSession.shortID),
            "messages": .array(msgArray),
            "context_id": .string(tabID.uuidString)
        ]
        if let agentModeSessionID = resolvedSession.agentModeSessionID ?? agentModeSessionID {
            result["agent_session_id"] = .string(agentModeSessionID.uuidString)
        }
        if let agentModeRunID = resolvedSession.agentModeRunID ?? agentModeRunID {
            result["agent_run_id"] = .string(agentModeRunID.uuidString)
        }
        return result
    }

    /// Full implementation of **chat_list** MCP tool.
    @MainActor
    func tool_chatList(args: [String: Value]) async throws -> [String: Value] {
        let limit = args["limit"]?.intValue ?? 10

        // Get active workspace
        guard let workspace = workspaceManager.activeWorkspace else {
            return ["chats": .array([])]
        }

        let scope = requestedChatInspectionScope(from: args)
        let resolvedTabID = try resolvedInspectionTabID(from: args)
        if scope == .tab, resolvedTabID == nil {
            throw ChatToolError.invalidParams("scope=tab requires an active compose tab or an explicit context_id")
        }

        // Get recent sessions from ChatDataService
        let metadataList = try await chatData.recentSessions(
            for: workspace,
            limit: limit,
            composeTabID: resolvedTabID
        )

        let formatter = Self.iso8601Formatter

        // Convert to Value array - only expose short IDs
        let chatsArray = metadataList.map { meta -> Value in
            let activeForTab = meta.composeTabID.flatMap { workspaceManager.activeChatSessionID(forTabID: $0) } == meta.id
            var chatDict: [String: Value] = [
                "id": .string(meta.shortID), // Only expose short ID
                "name": .string(meta.name),
                "last_modified": .string(formatter.string(from: meta.lastModified)),
                "message_count": .int(meta.messageCount),
                "selected_files": .array(meta.selectedFilePaths.map { path in Value.string(path) }),
                "is_current": .bool(meta.id == currentSessionID),
                "is_active_for_tab": .bool(activeForTab)
            ]
            if let tabID = meta.composeTabID {
                chatDict["context_id"] = .string(tabID.uuidString)
            }
            return .object(chatDict)
        }

        var result: [String: Value] = [
            "chats": .array(chatsArray),
            "scope": .string(scope.rawValue)
        ]
        if let resolvedTabID {
            result["context_id"] = .string(resolvedTabID.uuidString)
        }
        return result
    }

    // MARK: - Headless Generation (Plan & Question)

    /// Run a plan request without going through the normal sendMessage pipeline.
    /// - Parameters:
    ///   - useChatModelDirectly: If true, bypasses MCP preset resolution and uses the current chat model.
    ///                           Use this for UI-triggered requests (e.g., from discover view).
    ///   - onProgress: Optional callback invoked with accumulated text and reasoning during streaming.
    @MainActor
    func runHeadlessPlan(
        prompt: String,
        modelParam: String?,
        chatName: String?,
        tabID: UUID,
        selection: StoredSelection,
        useChatModelDirectly: Bool = false,
        onProgress: ((_ text: String, _ reasoning: String?) -> Void)? = nil
    ) async throws -> ChatSendReply {
        try await runHeadless(
            prompt: prompt,
            modelParam: modelParam,
            chatName: chatName ?? "Plan",
            tabID: tabID,
            selection: selection,
            mode: .plan,
            useChatModelDirectly: useChatModelDirectly,
            onProgress: onProgress
        )
    }

    /// Run a question/chat request without going through the normal sendMessage pipeline.
    @MainActor
    func runHeadlessQuestion(
        prompt: String,
        modelParam: String?,
        chatName: String?,
        tabID: UUID,
        selection: StoredSelection,
        onProgress: ((_ text: String, _ reasoning: String?) -> Void)? = nil
    ) async throws -> ChatSendReply {
        try await runHeadless(
            prompt: prompt,
            modelParam: modelParam,
            chatName: chatName ?? "Q&A",
            tabID: tabID,
            selection: selection,
            mode: .chat,
            onProgress: onProgress
        )
    }

    /// Run a review request without going through the normal sendMessage pipeline.
    @MainActor
    func runHeadlessReview(
        prompt: String,
        modelParam: String?,
        chatName: String?,
        tabID: UUID,
        selection: StoredSelection,
        gitScopeOverride: GitInclusion? = nil,
        reviewGitContext: FrozenPromptGitReviewContext? = nil,
        onProgress: ((_ text: String, _ reasoning: String?) -> Void)? = nil
    ) async throws -> ChatSendReply {
        let frozenReviewGitContext = if let reviewGitContext {
            reviewGitContext
        } else {
            await promptViewModel.freezePromptGitReviewContext(tabID: tabID, base: "HEAD")
        }
        return try await runHeadless(
            prompt: prompt,
            modelParam: modelParam,
            chatName: chatName ?? "Review",
            tabID: tabID,
            selection: selection,
            mode: .review,
            gitScopeOverride: gitScopeOverride,
            reviewGitContext: frozenReviewGitContext,
            onProgress: onProgress
        )
    }

    /// Internal: run a headless request (plan or chat) via AIQueriesService.
    /// - Builds an AIMessage from a frozen tab snapshot
    /// - Streams via AIQueriesService without touching `messages` or `isAIResponseInProgress`
    /// - Creates a `ChatSession` with the resulting user+assistant messages
    /// - Returns a `ChatSendReply` suitable for MCP or UI callers
    @MainActor
    func runHeadless(
        prompt: String,
        modelParam: String?,
        chatName: String,
        tabID: UUID,
        selection: StoredSelection,
        mode: HeadlessMode,
        useChatModelDirectly: Bool = false,
        gitScopeOverride: GitInclusion? = nil,
        reviewGitContext: FrozenPromptGitReviewContext = .automaticOnly(),
        workspaceID: UUID? = nil,
        lookupContext: WorkspaceLookupContext? = nil,
        resolvedExecution: ResolvedOracleExecution? = nil,
        finalReviewAuthorization: ContextBuilderFinalReviewAuthorization? = nil,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil,
        completionPolicy: OracleResponseCompletionPolicy = .interactive,
        onProgress: ((_ text: String, _ reasoning: String?) -> Void)? = nil
    ) async throws -> ChatSendReply {
        // Check cancellation at entry
        try Task.checkCancellation()

        let activationLease: WorkspaceActivityCoordinator.ActivationLease?
        if let workspaceID {
            guard let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceID }) else {
                throw ChatToolError.notFound("The target workspace is unavailable.")
            }
            guard workspace.consolidatedIntoWorkspaceID == nil,
                  !workspaceManager.pendingConsolidatedRestoreIDs.contains(workspaceID)
            else {
                throw ChatToolError(
                    code: .conflict,
                    message: "The target workspace is being consolidated or restored.",
                    details: ["workspace_id": workspaceID.uuidString]
                )
            }
            guard let lease = workspaceManager.workspaceActivityCoordinator.beginActivation(
                workspaceID: workspaceID
            ) else {
                throw ChatToolError(
                    code: .conflict,
                    message: "The target workspace is being consolidated.",
                    details: ["workspace_id": workspaceID.uuidString]
                )
            }
            activationLease = lease
        } else {
            activationLease = nil
        }
        defer {
            if let activationLease {
                workspaceManager.workspaceActivityCoordinator.endActivation(activationLease)
            }
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw ChatToolError.invalidParams("Prompt cannot be empty")
        }

        // 1) Resolve model
        let model: AIModel
        let chatPresetID: UUID?

        if let resolvedExecution {
            model = resolvedExecution.primaryModel
            chatPresetID = resolvedExecution.promptConfiguration.chatPresetID
        } else if useChatModelDirectly {
            // UI-triggered: use the current chat model directly, bypassing MCP preset logic
            model = promptViewModel.preferredAIModel
            chatPresetID = nil
        } else {
            try Task.checkCancellation()
            let execution = try resolveMCPFollowUpExecution(
                mode: mode.mcpModeName,
                modelParam: modelParam,
                workspaceID: workspaceID
            )
            model = execution.primaryModel
            chatPresetID = execution.promptConfiguration.chatPresetID
        }

        // 2) Build snapshot
        let snapshot = HeadlessContextSnapshot(
            workspaceID: workspaceID,
            tabID: tabID,
            promptText: trimmedPrompt,
            selection: selection,
            lookupContext: lookupContext,
            reviewGitContext: reviewGitContext,
            finalReviewAuthorization: finalReviewAuthorization
        )

        try Task.checkCancellation()

        // 3) Build AIMessage from snapshot
        let aiMessage = try await promptViewModel.buildHeadlessAIMessage(
            from: snapshot,
            model: model,
            mode: mode,
            gitScopeOverride: gitScopeOverride,
            oraclePromptConfiguration: resolvedExecution?.promptConfiguration
        )

        try Task.checkCancellation()

        // 4) Execute provider streaming without touching OracleViewModel.messages.
        let runtimeOutput = try await headlessRuntime.execute(
            message: aiMessage,
            model: model,
            tabID: tabID,
            completionPolicy: completionPolicy,
            onProgress: onProgress
        )
        var didScheduleProviderCleanup = false
        defer {
            if !didScheduleProviderCleanup {
                Task {
                    await self.headlessRuntime.cleanup(
                        runtimeOutput.providerCleanupHandle,
                        model: model
                    )
                }
            }
        }

        let trimmedResponse = runtimeOutput.text
        let finalTokenInfo = runtimeOutput.tokenInfo
        let providerCleanupHandle = runtimeOutput.providerCleanupHandle

        // 5) Create persisted ChatSession
        let (session, shortID) = try await createSessionFromHeadlessRun(
            prompt: trimmedPrompt,
            response: trimmedResponse,
            model: model,
            tokenInfo: finalTokenInfo,
            selection: selection,
            chatName: chatName,
            chatPresetID: chatPresetID,
            tabID: tabID,
            workspaceID: workspaceID,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID
        )

        didScheduleProviderCleanup = true
        Task { await headlessRuntime.cleanup(providerCleanupHandle, model: model) }

        // 6) Return ChatSendReply
        return ChatSendReply(
            chatId: session.id,
            shortId: shortID,
            mode: mode.mcpModeName,
            response: trimmedResponse,
            errors: nil
        )
    }

    /// Helper: persist a new ChatSession from a headless run without
    /// mutating the current chat stream (no changes to `messages` or `currentSessionID`).
    @MainActor
    func createSessionFromHeadlessRun(
        prompt: String,
        response: String,
        model: AIModel,
        tokenInfo: ChatTokenInfo,
        selection: StoredSelection,
        chatName: String?,
        chatPresetID: UUID?,
        tabID: UUID,
        workspaceID: UUID? = nil,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil,
        setActiveForTab: Bool = false
    ) async throws -> (session: ChatSession, shortID: String) {
        let workspace: WorkspaceModel? = if let workspaceID {
            workspaceManager.workspaces.first(where: { $0.id == workspaceID })
        } else {
            workspaceManager.activeWorkspace
        }
        guard let workspace else {
            throw ChatSessionError.invalidFilename("The target workspace for this plan chat is unavailable.")
        }
        guard workspace.consolidatedIntoWorkspaceID == nil,
              !workspaceManager.pendingConsolidatedRestoreIDs.contains(workspace.id)
        else {
            throw ChatToolError(
                code: .conflict,
                message: "The target workspace is being consolidated or restored.",
                details: ["workspace_id": workspace.id.uuidString]
            )
        }

        // 1) Build StoredMessage entries
        let now = Date()
        let allowedPaths = selection.selectedPaths

        let userMsg = StoredMessage(
            id: UUID(),
            isUser: true,
            rawText: prompt,
            timestamp: now,
            sequenceIndex: 0,
            allowedFilePaths: allowedPaths,
            promptTokens: nil,
            completionTokens: nil,
            cost: nil,
            modelName: nil
        )

        let aiMsg = StoredMessage(
            id: UUID(),
            isUser: false,
            rawText: response,
            timestamp: now,
            sequenceIndex: 1,
            allowedFilePaths: allowedPaths,
            promptTokens: tokenInfo.promptTokens,
            completionTokens: tokenInfo.completionTokens,
            cost: tokenInfo.cost,
            modelName: model.rawValue
        )

        // 2) Create a ChatSession object (in-memory)
        let resolvedName = ChatSession.validatedName(
            chatName ?? "Plan – \(workspace.name)"
        )

        var session = ChatSession(
            workspaceID: workspace.id,
            composeTabID: tabID,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID,
            name: resolvedName,
            messages: [userMsg, aiMsg],
            selectedFilePaths: allowedPaths,
            selectedPromptIDs: workspace.id == workspaceManager.activeWorkspaceID
                ? Array(promptViewModel.selectedPromptIDsForChat)
                : [],
            preferredAIModel: model.rawValue,
            selectedChatPresetID: chatPresetID,
            oracleExecutionAuthority: .frozen
        )

        if setActiveForTab {
            if workspaceID != nil {
                workspaceManager.setActiveChatSessionID(
                    session.id,
                    for: WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: tabID)
                )
            } else {
                workspaceManager.setActiveChatSessionID(session.id, forTabID: tabID)
            }
        }

        // 3) Persist to disk via ChatDataService
        let fileURL = try await autosaveSession(session)
        session.fileURL = fileURL

        // 4) Register in-memory but DO NOT disturb the live session/stream
        if workspace.id == workspaceManager.activeWorkspaceID {
            sessions.append(session)
        }

        return (session, session.shortID)
    }
}

extension MCPOracleToolService {
    var backgroundRegistry: OracleBackgroundInvocationRegistry {
        OracleBackgroundInvocationRegistry.shared
    }

    func startBackgroundOracle(args: [String: Value], tabContext: OracleViewModel.OracleSendTabContext, caller: OracleBackgroundCaller, invocationID: UUID) async throws -> Value {
        guard caller.admitsStart else { return Self.backgroundEnvelope(.unsupported, reason: "session") }
        let registry = backgroundRegistry
        let context = OracleViewModel.backgroundOracleContext(tabContext)
        let profile = GlobalSettingsStore.shared.effectiveAgentModelsProfile(workspaceID: caller.owner.workspaceID)
        do {
            let prepared = try await oracleVM.prepareConfiguredOracleRoster(args: args, promptVM: promptVM, tabContext: context, capturedProfile: profile, freezeGroupLanes: true)
            guard prepared.isGrouped else { return Self.backgroundEnvelope(.unsupported, reason: "group") }
            guard caller.admitsStart else { return Self.backgroundEnvelope(.unsupported, reason: "session") }
            if let group = prepared.existingGroup, let busy = authorizedLiveBackground(groupID: group.group.id, caller: caller) {
                return Self.backgroundEnvelope(.busy, reference: busy.reference, caller: caller)
            }
            let admits = { caller.admitsStart && oracleVM.oracleBackgroundHistoryAdmissionIsOpen(workspaceID: caller.owner.workspaceID, groupID: prepared.existingGroup?.group.id) }
            guard admits() else { return Self.backgroundEnvelope(.busy, caller: caller) }
            if let previous = caller.session.oracleBackgroundOwner, previous != caller.owner, !registry.isDrained(previous) {
                return Self.backgroundEnvelope(.busy, caller: caller)
            }
            if registry.admissionIsClosed(for: caller.owner) {
                try registry.reopen(caller.owner, admissionIsCurrent: admits)
            }
            // Install only after preparation/validation, without a suspension before registry reservation.
            // A different binding's outstanding drain must never lose its session Stop pointer.
            caller.session.oracleBackgroundOwner = caller.owner
            let reference = try await registry.start(owner: caller.owner, runID: caller.runID, invocationID: invocationID, admissionIsCurrent: admits) { [oracleVM, promptVM, window = caller.window] job in
                // The worker owns captured composition independently of parent-run disposal.
                defer { withExtendedLifetime(window) {} }
                _ = try await oracleVM.executePreparedOracleGroup(prepared, args: args, promptVM: promptVM, tabContext: context, backgroundJob: job)
            }
            var receipt = Self.backgroundIdentity(reference, caller: caller)
            receipt.merge([
                "status": .string("running"), "chat_id": .string(reference.members[0].publicChatID),
                "oracle_count": .int(reference.members.count), "mode": args["mode"] ?? .string("chat"),
                "lanes": .array(reference.members.map { member in .object(Self.backgroundLane(member, status: "running")) })
            ]) { _, new in new }
            return .object(receipt)
        } catch let error as ChatToolError where error.code == .invalidParams { throw error }
        catch let error as OracleBackgroundInvocationRegistry.RegistryError {
            return Self.backgroundEnvelope(error == .limit ? .limit : error == .staleOwner ? .unsupported : error == .busy ? .busy : .unavailable, caller: caller, reason: error == .staleOwner ? "session" : nil)
        } catch is CancellationError { throw CancellationError() }
        catch OracleGroupClaimError.conflict { return await backgroundBusyAfterClaim(args: args, caller: caller) ?? Self.backgroundEnvelope(.busy, caller: caller) }
        catch { return Self.backgroundEnvelope(.unavailable, caller: caller) }
    }

    func backgroundBusyAfterClaim(args: [String: Value], caller: OracleBackgroundCaller?) async -> Value? {
        if let caller, let chatID = args["chat_id"]?.stringValue,
           let owner = try? OracleViewModel.oracleGroupOwner(workspaceID: caller.owner.workspaceID, tabID: caller.owner.binding.tabID),
           let lookup = try? OracleMemberLookup(publicChatID: chatID),
           let group = try? await oracleVM.oracleConversationStore.load(member: lookup, owner: owner),
           caller.isCurrent, let turn = group.turns.last, turn.state == .prepared, let provenance = turn.backgroundExecution,
           provenance.agentSessionID == caller.owner.binding.sessionID,
           backgroundProjectionMatches(group, provenance: provenance, caller: caller)
        {
            let reference = OracleBackgroundInvocationRegistry.Reference(groupID: group.group.id, turnID: turn.id, members: group.members, provenance: provenance)
            return Self.backgroundEnvelope(.busy, reference: reference, caller: caller)
        }
        return nil
    }

    func authorizedLiveBackground(groupID: OracleGroupID, caller: OracleBackgroundCaller) -> OracleBackgroundInvocationRegistry.Snapshot? {
        backgroundRegistry.snapshot(for: caller.owner, includeFinished: false).invocations.first { $0.reference.groupID == groupID }
    }

    func backgroundBusyContinuation(chatID: String, caller: OracleBackgroundCaller) async -> Value? {
        guard let owner = try? OracleViewModel.oracleGroupOwner(workspaceID: caller.owner.workspaceID, tabID: caller.owner.binding.tabID),
              let lookup = try? OracleMemberLookup(publicChatID: chatID),
              let group = try? await oracleVM.oracleConversationStore.load(member: lookup, owner: owner),
              caller.isCurrent, let live = authorizedLiveBackground(groupID: group.group.id, caller: caller),
              backgroundProjectionMatches(group, provenance: live.reference.provenance, caller: caller)
        else { return nil }
        return Self.backgroundEnvelope(.busy, reference: live.reference, caller: caller)
    }

    func executeBackgroundOracleControl(args: [String: Value], invocation: ToolInvocationContext, cancel: Bool) async throws -> Value {
        let allowed = cancel ? ["op", "oracle_group_id", "oracle_turn_id"] : ["op", "oracle_group_id", "oracle_turn_id", "chat_id", "include_finished"]
        let unsupported = args.keys.filter { !$0.hasPrefix("_") && !allowed.contains($0) }.sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams("\(cancel ? askOracleToolName : oracleChatLogToolName) only accepts: \(allowed.joined(separator: ", ")). Unsupported args: \(unsupported.joined(separator: ", "))")
        }
        let groupID = try OracleBackgroundContract.uuid(args, "oracle_group_id").map(OracleGroupID.init(rawValue:))
        let turnID = try OracleBackgroundContract.uuid(args, "oracle_turn_id").map(OracleTurnID.init(rawValue:))
        let includeFinished = try OracleBackgroundContract.boolean(args, "include_finished", default: true)
        let chatID: String?
        if let value = args["chat_id"] {
            guard let text = value.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OracleBackgroundContract.invalid("chat_id", expected: "non-empty string") }
            chatID = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else { chatID = nil }
        if cancel, groupID == nil || turnID == nil { throw OracleBackgroundContract.invalidConstraint("cancel needs both Oracle IDs") }
        if turnID != nil, groupID == nil, chatID == nil { throw OracleBackgroundContract.invalidConstraint("turn ID needs group ID or chat_id") }
        if args["include_finished"] != nil, groupID != nil || chatID != nil || turnID != nil { throw OracleBackgroundContract.invalidConstraint("include_finished needs no selector") }
        guard let caller = try await backgroundCaller(args: args, invocation: invocation, tool: cancel ? askOracleToolName : oracleChatLogToolName), caller.isCurrent else {
            return Self.backgroundEnvelope(.unsupported, reason: "session")
        }
        if groupID == nil, chatID == nil {
            return backgroundList(caller: caller, includeFinished: includeFinished)
        }
        let canonicalOwner = try OracleViewModel.oracleGroupOwner(workspaceID: caller.owner.workspaceID, tabID: caller.owner.binding.tabID)
        var document: OracleGroupDocument?
        let beforeLoad = backgroundRegistry.awarenessVersion(for: caller.owner).generation
        do {
            let store = oracleVM.oracleConversationStore
            if let groupID { document = try await store.load(groupID: groupID, owner: canonicalOwner) }
            else if let chatID { document = try await store.load(member: OracleMemberLookup(publicChatID: chatID), owner: canonicalOwner) }
            else { document = nil }
            // A completed worker can publish, release its claim and be evicted during the load.
            // Reload only this target once; uncertainty must not masquerade as interruption.
            if document?.turns.last?.state == .prepared,
               backgroundRegistry.awarenessVersion(for: caller.owner).generation != beforeLoad,
               let id = document?.group.id
            {
                let beforeReload = backgroundRegistry.awarenessVersion(for: caller.owner).generation
                document = try await store.load(groupID: id, owner: canonicalOwner)
                if document?.turns.last?.state == .prepared,
                   backgroundRegistry.awarenessVersion(for: caller.owner).generation != beforeReload
                {
                    return Self.backgroundEnvelope(.unavailable, caller: caller)
                }
            }
        } catch OraclePersistenceError.ownerMismatch { return Self.backgroundEnvelope(.notFound, caller: caller) }
        catch OraclePersistenceError.ambiguousMemberAlias { return Self.backgroundEnvelope(.notFound, caller: caller) }
        catch { return Self.backgroundEnvelope(.unavailable, caller: caller) }
        guard caller.isCurrent, let document,
              let turn = turnID.flatMap({ id in document.turns.first { $0.id == id } }) ?? (turnID == nil ? document.turns.last : nil),
              let provenance = turn.backgroundExecution,
              provenance.agentSessionID == caller.owner.binding.sessionID,
              backgroundProjectionMatches(document, provenance: provenance, caller: caller)
        else { return Self.backgroundEnvelope(.notFound, caller: caller) }
        if let chatID, !document.members.contains(where: { $0.publicChatID == chatID }) {
            throw OracleBackgroundContract.invalidConstraint("group ID and chat_id must match")
        }
        let reference = OracleBackgroundInvocationRegistry.Reference(groupID: document.group.id, turnID: turn.id, members: document.members, provenance: provenance)
        let current = backgroundRegistry.snapshot(for: caller.owner).invocations.first { $0.reference == reference }
        if cancel {
            if turn.state != .terminal, current?.phase.isLive == true {
                do { _ = try backgroundRegistry.cancel(owner: caller.owner, reference: reference) }
                catch { return Self.backgroundEnvelope(.notFound, caller: caller) }
                return Self.backgroundEnvelope(.cancelling, reference: reference, caller: caller)
            }
            return Self.backgroundEnvelope(.notRunning, reference: reference, caller: caller)
        }
        if turn.state == .terminal {
            return try backgroundTerminalValue(document: document, turn: turn, reference: reference, caller: caller)
        }
        if current?.groupStatus != nil {
            return await backgroundReloadPublished(reference: reference, caller: caller)
        }
        guard let current, current.phase.isLive else {
            if current?.phase == .orphaned { return Self.backgroundEnvelope(.unavailable, reference: reference, caller: caller) }
            guard case var .object(interrupted) = Self.backgroundEnvelope(.interrupted, reference: reference, caller: caller) else { preconditionFailure() }
            interrupted["chat_id"] = .string(reference.members[0].publicChatID)
            interrupted["mode"] = .string(turn.input.mode.rawValue)
            interrupted["lanes"] = .array(reference.members.map { member in
                var lane = Self.backgroundLane(member, status: "interrupted")
                lane["answer_ready"] = .bool(false)
                lane["partial"] = .bool(false)
                lane["truncated"] = .bool(false)
                return .object(lane)
            })
            return .object(interrupted)
        }
        var lanes: [Value] = [], unavailable = false
        for member in reference.members {
            let index = member.laneID.index
            var status = current.laneOutcomes[index]?.rawValue ?? "running"
            var response: String?, partial = false
            if let query = current.queries[index] {
                let (outcome, message) = await oracleVM.backgroundOracleQuerySnapshot(query)
                if case .providerCompleted? = outcome, message?.isFinalized == true {
                    status = "completed"
                    response = message?.content
                    if response?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { unavailable = true
                        response = nil
                    }
                } else if let outcome {
                    if case .cancelled = outcome { status = "cancelled" } else { status = "failed" }
                    response = message?.content
                    partial = response?.isEmpty == false
                } else if status == "completed" { unavailable = true }
            } else if status == "completed" { unavailable = true }
            var lane = Self.backgroundLane(member, status: status)
            lane["answer_ready"] = .bool(status == "completed" && response != nil)
            lane["partial"] = .bool(partial)
            lane["truncated"] = .bool((response?.count ?? 0) > 8000)
            if let response {
                let text = String(response.prefix(8000))
                if partial { lane["error"] = .object(["partial_response": .string(text)]) }
                else { lane["response"] = .string(text) }
            }
            lanes.append(.object(lane))
        }
        guard caller.isCurrent else { return Self.backgroundEnvelope(.notFound, caller: caller) }
        let latest = backgroundRegistry.snapshot(for: caller.owner).invocations.first { $0.reference == reference }
        if latest?.groupStatus != nil || latest?.phase.isLive != true {
            return await backgroundReloadPublished(reference: reference, caller: caller)
        }
        var object = Self.backgroundIdentity(reference, caller: caller)
        object["status"] = .string(latest?.phase == .cancelling ? "cancelling" : "running")
        object["mode"] = .string(turn.input.mode.rawValue)
        object["chat_id"] = .string(reference.members[0].publicChatID)
        object["lanes"] = .array(lanes)
        if unavailable, case let .object(envelope) = Self.backgroundEnvelope(.unavailable, reference: reference, caller: caller) { object.merge(envelope) { _, new in new } }
        return .object(object)
    }

    private func backgroundReloadPublished(reference: OracleBackgroundInvocationRegistry.Reference, caller: OracleBackgroundCaller) async -> Value {
        do {
            let owner = try OracleViewModel.oracleGroupOwner(workspaceID: caller.owner.workspaceID, tabID: caller.owner.binding.tabID)
            let loaded = try await oracleVM.oracleConversationStore.load(groupID: reference.groupID, owner: owner)
            guard caller.isCurrent else { return Self.backgroundEnvelope(.notFound, caller: caller) }
            guard let document = loaded, let turn = document.turns.first(where: { $0.id == reference.turnID }),
                  turn.backgroundExecution == reference.provenance,
                  backgroundProjectionMatches(document, provenance: reference.provenance, caller: caller), turn.state == .terminal
            else { return Self.backgroundEnvelope(.unavailable, reference: reference, caller: caller) }
            return try backgroundTerminalValue(document: document, turn: turn, reference: reference, caller: caller)
        } catch { return Self.backgroundEnvelope(.unavailable, reference: reference, caller: caller) }
    }

    private func backgroundTerminalValue(document: OracleGroupDocument, turn: OracleTurnRecord, reference: OracleBackgroundInvocationRegistry.Reference, caller: OracleBackgroundCaller) throws -> Value {
        guard let status = turn.status, turn.results.count == document.members.count else { return Self.backgroundEnvelope(.unavailable, reference: reference, caller: caller) }
        let result = try OracleGroupResult(groupID: document.group.id, status: status, oracleResults: turn.results, warnings: turn.warnings)
        var object = OracleViewModel.oracleGroupValue(result, mode: turn.input.mode.rawValue, tabContext: nil, reconciliationGuidance: GlobalSettingsStore.shared.effectiveAgentModelsProfile(workspaceID: caller.owner.workspaceID).oracleReconciliationGuidance)
        object.merge(Self.backgroundIdentity(reference, caller: caller)) { _, new in new }
        return .object(object)
    }

    private func backgroundProjectionMatches(_ group: OracleGroupDocument, provenance: OracleBackgroundExecution, caller: OracleBackgroundCaller) -> Bool {
        for member in group.members {
            do {
                if let index = try oracleVM.validatedOracleProjectionIndex(member: member, group: group, workspaceID: caller.owner.workspaceID, tabID: caller.owner.binding.tabID) {
                    let projection = oracleVM.sessions[index]
                    guard projection.agentModeSessionID == provenance.agentSessionID,
                          projection.agentModeRunID == provenance.agentRunID else { return false }
                }
            } catch { return false }
        }
        return true
    }

    private func backgroundList(caller: OracleBackgroundCaller, includeFinished: Bool) -> Value {
        let snapshot = backgroundRegistry.snapshot(for: caller.owner, includeFinished: includeFinished)
        let open = snapshot.invocations.filter(\.phase.isLive)
        let ready = open.reduce(0) { $0 + $1.laneOutcomes.values.count(where: { $0 == .completed }) }
        var object: [String: Value] = [
            "status": .string(snapshot.invocations.isEmpty ? "empty" : "listed"), "scope": .string("current_process"),
            "count": .int(snapshot.invocations.count), "open_count": .int(open.count), "answer_ready_count": .int(ready),
            "retention_limit": .int(OracleBackgroundInvocationRegistry.inactiveSessionLimit), "history_truncated": .bool(snapshot.historyTruncated),
            "backend": .string("app"), "context_id": .string(caller.owner.binding.tabID.uuidString), "agent_session_id": .string(caller.owner.binding.sessionID.uuidString),
            "turns": .array(snapshot.invocations.map { item in
                var turn = Self.backgroundIdentity(item.reference, caller: caller)
                turn["status"] = .string(item.phase == .orphaned ? "unavailable" : item.phase == .cancelling ? "cancelling" : item.phase.isLive ? "running" : item.groupStatus?.rawValue ?? "unavailable")
                turn["lanes"] = .array(item.reference.members.map { member in
                    var lane = Self.backgroundLane(member, status: item.laneOutcomes[member.laneID.index]?.rawValue ?? (item.phase.isLive ? "running" : "interrupted"))
                    lane["answer_ready"] = .bool(item.phase.isLive && item.laneOutcomes[member.laneID.index] == .completed)
                    return .object(lane)
                })
                return .object(turn)
            })
        ]
        if snapshot.invocations.isEmpty {
            object["code"] = .string("oracle_background_empty")
            object["message"] = .string(OracleBackgroundContract.ResultCode.empty.message)
            object["next_action"] = .null
        }
        return .object(object)
    }

    private static func backgroundLane(_ member: OracleGroupMember, status: String) -> [String: Value] {
        ["lane_index": .int(member.laneID.index), "chat_id": .string(member.publicChatID), "model_id": .string(member.model.modelID), "status": .string(status)]
    }

    static func backgroundIdentity(_ reference: OracleBackgroundInvocationRegistry.Reference, caller: OracleBackgroundCaller) -> [String: Value] {
        [
            "oracle_group_id": .string(reference.groupID.rawValue.uuidString),
            "oracle_turn_id": .string(reference.turnID.rawValue.uuidString),
            "agent_session_id": .string(reference.provenance.agentSessionID.uuidString),
            "agent_run_id": .string(reference.provenance.agentRunID.uuidString),
            "backend": .string("app"),
            "context_id": .string(caller.owner.binding.tabID.uuidString)
        ]
    }

    static func backgroundEnvelope(_ code: OracleBackgroundContract.ResultCode, reference: OracleBackgroundInvocationRegistry.Reference? = nil, caller: OracleBackgroundCaller? = nil, reason: String? = nil) -> Value {
        var object: [String: Value] = ["status": .string(code.status), "code": .string("oracle_background_" + code.rawValue), "message": .string(code.message), "next_action": .null]
        if let caller {
            object.merge(["backend": .string("app"), "context_id": .string(caller.owner.binding.tabID.uuidString), "agent_session_id": .string(caller.owner.binding.sessionID.uuidString)]) { _, new in new }
            if let reference { object.merge(backgroundIdentity(reference, caller: caller)) { _, new in new } }
        }
        if let reason { object["reason"] = .string(reason) }
        if [.busy, .notFound, .notRunning, .cancelling, .unavailable].contains(code) {
            var args: [String: Value] = ["op": .string("collect")]
            if let reference {
                args["oracle_group_id"] = .string(reference.groupID.rawValue.uuidString)
                args["oracle_turn_id"] = .string(reference.turnID.rawValue.uuidString)
            }
            object["next_action"] = .object(["tool": .string("oracle_chat_log"), "arguments": .object(args)])
        }
        return .object(object)
    }
}
