import Foundation
import MCP // <- required for `Value`

private actor OracleProviderCleanupHandleBox {
    private var handle: ProviderConversationCleanupHandle?

    func update(_ handle: ProviderConversationCleanupHandle) {
        self.handle = handle
    }

    func current() -> ProviderConversationCleanupHandle? {
        handle
    }
}

// MARK: - MCP Tool helpers (moved from MCPServerViewModel)

extension OracleViewModel {
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Model Selection

    /// Encapsulates the result of model selection
    struct ModelSelectionResult {
        let model: AIModel
        let mcpControlInfo: String?
        let isAutoSelected: Bool
        let chatPresetID: UUID? // The chat preset to use for this mode (always resolved now)
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
        let packaging: OracleSendPackagingContext

        init(
            tabID: UUID,
            workspaceID: UUID? = nil,
            origin: OracleSendOrigin = .compatibility,
            agentModeSessionID: UUID? = nil,
            agentModeRunID: UUID? = nil,
            packaging: OracleSendPackagingContext
        ) {
            self.tabID = tabID
            self.workspaceID = workspaceID
            self.origin = origin
            self.agentModeSessionID = agentModeSessionID
            self.agentModeRunID = agentModeRunID
            self.packaging = packaging
        }
    }

    private func oracleModelAvailabilityGuidance(for model: AIModel) -> String {
        switch model.providerType {
        case .claudeCode:
            if let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) {
                return "Configure and enable \(descriptor.groupDisplayName) in Settings."
            }
            return "Connect Claude Code in Settings."
        default:
            return "Please check that the \(model.providerType.displayName) API key is configured in Settings."
        }
    }

    private func oracleModelAvailabilityGuidance(for presets: [ModelPreset]) -> String {
        if let claudeFamilyModel = presets.map(\.model).first(where: { $0.providerType == .claudeCode }) {
            return oracleModelAvailabilityGuidance(for: claudeFamilyModel)
        }
        return "Please check that the required API keys are configured in Settings."
    }

    /// 1) Presets OFF: use the configured MCP Oracle planning model.
    /// 2) Presets ON & no presets exist: use the configured MCP Oracle planning model.
    /// 3) Presets ON & presets exist: use a compatible available preset; if none available, fail loudly.
    @MainActor
    private func selectModel(
        modelParam: String?,
        mode rawMode: String,
        allPresets: [ModelPreset],
        promptVM: PromptViewModel,
        planningModelRawOverride: String? = nil
    ) async throws -> ModelSelectionResult {
        /// Resolve a chat preset for the MCP mode even when the selected model preset
        /// does not map one explicitly. Ensures UI display and prompt building stay in sync.
        func resolveChatPreset(for mode: String, from mappings: ChatPresetMappings?) -> (id: UUID?, name: String?) {
            if let id = mappings?.presetID(for: mode),
               let preset = ChatPresetManager.shared.preset(with: id)
            {
                return (id, preset.name)
            }
            if let builtIn = findBuiltInPreset(for: mode) {
                return (builtIn.id, builtIn.name)
            }
            return (nil, nil)
        }

        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let mode = norm(rawMode)
        guard ["chat", "plan", "review"].contains(mode) else {
            throw ChatToolError.invalidParams("Invalid mode: \(mode). Valid modes: chat, plan, review")
        }
        let modeLabel = mode.capitalized

        func strictPlanningModel() throws -> AIModel {
            let resolution = if let planningModelRawOverride {
                PromptViewModel.mcpOraclePlanningModelResolution(
                    rawValue: planningModelRawOverride,
                    isModelAvailable: { promptVM.mcpOracleIsProviderConfigured(for: $0) }
                )
            } else {
                promptVM.mcpOraclePlanningModelResolution()
            }
            if case let .configured(model) = resolution {
                return model
            }
            let message = PromptViewModel.mcpOraclePlanningModelErrorMessage(
                for: resolution,
                availabilityGuidance: { model in self.oracleModelAvailabilityGuidance(for: model) }
            ) ?? "MCP Oracle model is not configured."
            throw ChatToolError.invalidParams(message)
        }

        // Settings toggle: "Use Model Preset for MCP chat"
        let settingsStore = GlobalSettingsStore.shared
        let useModelPresets = settingsStore.mcpShowModelPresets()
        let temporarilyDisabled = settingsStore.mcpTemporarilyDisablePresets()

        // When presets are temporarily hidden by wizard, treat as empty
        // This ensures hiding presets behaves identically to having no presets
        let effectivePresets: [ModelPreset] = (useModelPresets && temporarilyDisabled) ? [] : allPresets
        let hasAnyModelPresets = !effectivePresets.isEmpty

        /// Helpers for consistent info labels
        func infoLine(reason: String, model: AIModel) -> String {
            "\(modeLabel) mode • \(reason) (\(model.displayName))"
        }

        // ─────────────────────────────────────────────────────────────────
        // CASE A: Model Presets are DISABLED
        // Uses planningModel (MCP default model) - same as presets ON but empty.
        // This ensures consistent MCP behavior regardless of preset toggle state.
        // ─────────────────────────────────────────────────────────────────
        if !useModelPresets {
            // MCP always uses the explicitly configured Oracle planning model when presets are off.
            let planningModel = try strictPlanningModel()
            let resolvedPreset = resolveChatPreset(for: mode, from: nil)
            let info = resolvedPreset.name ?? infoLine(reason: "MCP Oracle Model", model: planningModel)

            // If a model was explicitly requested, only accept planningModel or "current_chat_model"
            if let mp = modelParam {
                let mpn = norm(mp)
                if mpn == "current_chat_model" || mpn == norm(planningModel.displayName) {
                    return .init(
                        model: planningModel,
                        mcpControlInfo: info,
                        isAutoSelected: false,
                        chatPresetID: resolvedPreset.id
                    )
                }

                throw ChatToolError.invalidParams(
                    "Model '\(mp)' not allowed when presets are disabled. " +
                        "Pass 'current_chat_model' or '\(planningModel.displayName)', or enable model presets."
                )
            }

            // No explicit model param → return planningModel
            return .init(
                model: planningModel,
                mcpControlInfo: info,
                isAutoSelected: true,
                chatPresetID: resolvedPreset.id
            )
        }

        // ─────────────────────────────────────────────────────────────────
        // CASE B: Model Presets are ENABLED
        // 1) No presets defined at all → use the configured Oracle planning model.
        // 2) Presets exist → pick an available preset for the mode; if none available, fail loudly.
        // ─────────────────────────────────────────────────────────────────

        // B.1: No model presets exist at all → use default MCP model (error if unavailable)
        if !hasAnyModelPresets {
            // Default MCP model must be explicitly configured and available when presets are enabled but none are defined.
            let planningModel = try strictPlanningModel()
            let resolvedPreset = resolveChatPreset(for: mode, from: nil)
            let info = resolvedPreset.name ?? infoLine(reason: "MCP Oracle Model", model: planningModel)
            // Respect explicit model only for the sentinel or configured Oracle model display name
            if let mp = modelParam {
                let mpn = norm(mp)
                if mpn == "current_chat_model" ||
                    mpn == norm(planningModel.displayName)
                {
                    return .init(
                        model: planningModel,
                        mcpControlInfo: info,
                        isAutoSelected: false,
                        chatPresetID: resolvedPreset.id
                    )
                }
                throw ChatToolError.invalidParams(
                    "Model '\(mp)' not found. No model presets are defined. Pass 'current_chat_model' or the display name shown by oracle_utils op=models, or create presets and enable them in Settings."
                )
            }
            return .init(
                model: planningModel,
                mcpControlInfo: info,
                isAutoSelected: true,
                chatPresetID: resolvedPreset.id
            )
        }

        // B.2: Model presets exist → use compatible preset, then fallback if needed
        let supporting: [ModelPreset] = effectivePresets.filteredForMode(mode)
        var available: [ModelPreset] = []
        for p in supporting {
            if promptVM.isModelAvailable(p.model) {
                available.append(p)
            }
        }

        // Explicit model request via param
        if let mp = modelParam {
            // Try to resolve a user-defined preset by id/name/fuzzy
            if let preset = try await findPreset(named: mp, in: effectivePresets) {
                try validateModeCompatibility(preset: preset, mode: mode, allPresets: effectivePresets)

                // Check if the preset's model is available (model presets are sacred)
                if !promptVM.isModelAvailable(preset.model) {
                    throw ChatToolError.invalidParams(
                        "Model preset '\(preset.name)' uses model '\(preset.model.displayName)' which is not available. " +
                            oracleModelAvailabilityGuidance(for: preset.model)
                    )
                }

                let modelName = preset.model.displayName
                let resolvedPreset = resolveChatPreset(for: mode, from: preset.chatPresetMappings)

                let info = resolvedPreset.name ?? "\(modeLabel) mode • \(preset.name) (\(modelName))"

                return .init(model: preset.model, mcpControlInfo: info, isAutoSelected: false, chatPresetID: resolvedPreset.id)
            }

            // No preset match: do not allow sentinel fallback here since presets exist.
            throw buildModelNotFoundError(
                modelParam: mp,
                mode: mode,
                allPresets: effectivePresets,
                hasPresets: hasAnyModelPresets
            )
        }

        // No explicit model → pick first available compatible preset
        if let first = available.first {
            let modelName = first.model.displayName
            let resolvedPreset = resolveChatPreset(for: mode, from: first.chatPresetMappings)
            let info = resolvedPreset.name ?? "\(modeLabel) mode • Auto: \(first.name) (\(modelName))"

            return .init(model: first.model, mcpControlInfo: info, isAutoSelected: true, chatPresetID: resolvedPreset.id)
        }

        // Hard line: user disabled this mode across presets
        if supporting.isEmpty {
            throw ChatToolError.invalidParams(
                "Mode '\(mode)' is disabled by your configured model presets. Choose a different mode, edit your presets to enable this mode, or disable 'Use Model Preset for MCP chat' in Settings."
            )
        }

        // Presets exist for this mode but none have available models - error instead of silent fallback
        // (model presets are sacred)
        let presetNames = supporting.map(\.name).joined(separator: ", ")
        throw ChatToolError.invalidParams(
            "None of your model presets for '\(mode)' mode are available. " +
                "Configured presets: \(presetNames). " +
                oracleModelAvailabilityGuidance(for: supporting)
        )
    }

    @MainActor
    func resolveMCPFollowUpModel(
        mode: String,
        modelParam: String? = nil,
        workspaceID: UUID? = nil,
        planningModelRawOverride: String? = nil
    ) async throws -> (model: AIModel, chatPresetID: UUID?, mcpControlInfo: String?) {
        let presetsManager = ModelPresetsManager.shared
        let allPresets = presetsManager.allPresets()
        let selection = try await selectModel(
            modelParam: modelParam,
            mode: mode,
            allPresets: allPresets,
            promptVM: promptViewModel,
            planningModelRawOverride: planningModelRawOverride ?? workspaceID.flatMap {
                GlobalSettingsStore.shared.effectiveAgentModelsProfile(workspaceID: $0).planningModelRaw
            }
        )
        return (selection.model, selection.chatPresetID, selection.mcpControlInfo)
    }

    /// Finds a built-in chat preset for the given mode
    @MainActor
    private func findBuiltInPreset(for mode: String) -> ChatPreset? {
        let manager = ChatPresetManager.shared
        switch mode.lowercased() {
        case "chat":
            return manager.defaultPreset(for: .chat)
                ?? manager.builtInPresets.first { $0.mode == .chat && $0.id != ChatPreset.BuiltIn.manual.id }
                ?? manager.builtInPresets.first { $0.mode == .chat }
        case "plan":
            return manager.defaultPreset(for: .plan)
                ?? manager.builtInPresets.first { $0.mode == .plan }
        case "review":
            return manager.defaultPreset(for: .review)
                ?? manager.builtInPresets.first { $0.mode == .review }
        default:
            return manager.defaultPreset(for: .chat)
                ?? manager.builtInPresets.first { $0.mode == .chat && $0.id != ChatPreset.BuiltIn.manual.id }
                ?? manager.builtInPresets.first { $0.mode == .chat }
        }
    }

    /// Finds a preset by name using various matching strategies
    @MainActor
    private func findPreset(named name: String, in presets: [ModelPreset]) async throws -> ModelPreset? {
        // Try by ID first
        if let presetId = UUID(uuidString: name),
           let preset = presets.first(where: { $0.id == presetId })
        {
            return preset
        }

        // Try exact name match (case-insensitive)
        if let preset = presets.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return preset
        }

        // Try fuzzy matching
        let availableNames = presets.map(\.name)
        let closestName = await Task.detached(priority: .userInitiated) {
            ModelPreset.findBestMatch(name, among: availableNames)
        }.value

        if let closestName {
            print("[MCP] Fuzzy matched model '\(name)' to preset '\(closestName)'")
            return presets.first { $0.name == closestName }
        }

        return nil
    }

    /// Validates that a preset supports the requested mode
    private func validateModeCompatibility(
        preset: ModelPreset,
        mode: String,
        allPresets: [ModelPreset]
    ) throws {
        guard let supportedModes = preset.supportedModes else { return }

        let isSupported = switch mode {
        case "chat": supportedModes.chat
        case "plan": supportedModes.plan
        case "review": supportedModes.review
        default: true
        }

        guard isSupported else {
            // Build list of supported modes
            var supportedModesList: [String] = []
            if supportedModes.chat { supportedModesList.append("chat") }
            if supportedModes.plan { supportedModesList.append("plan") }
            if supportedModes.review { supportedModesList.append("review") }

            let supportedModesStr = supportedModesList.isEmpty ?
                "no modes" :
                supportedModesList.joined(separator: ", ")

            // Find alternatives
            let alternatives = allPresets.filteredForMode(mode).map(\.name)
            let alternativesNote = if alternatives.isEmpty {
                " No defined presets support '\(mode)' mode. Use `oracle_utils op=models` to view each preset's supported modes."
            } else {
                " Alternative presets for \(mode) mode: \(alternatives.joined(separator: ", "))"
            }

            throw ChatToolError.invalidParams(
                "Model preset '\(preset.name)' does not support '\(mode)' mode. " +
                    "This preset only supports: \(supportedModesStr)." +
                    alternativesNote +
                    " To fix: either use a supported mode (\(supportedModesStr)) or choose a different model."
            )
        }
    }

    /// Builds appropriate error message when model is not found
    private func buildModelNotFoundError(
        modelParam: String,
        mode: String,
        allPresets: [ModelPreset],
        hasPresets: Bool
    ) -> ChatToolError {
        if !hasPresets {
            return ChatToolError.invalidParams(
                "Model '\(modelParam)' not found. No model presets are defined. " +
                    "Pass 'current_chat_model' or the display name of the current/planning model (as shown by oracle_utils op=models), " +
                    "or create presets and enable them in Settings."
            )
        }
        let available = allPresets.map(\.name).joined(separator: ", ")
        return ChatToolError.invalidParams(
            "Model '\(modelParam)' not found. Available presets: \(available). " +
                "Choose a compatible preset (see oracle_utils op=models), or disable 'Use Model Preset for MCP Oracle' to use the current oracle model."
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
    private func resolveSessionForExplicitContinuation(
        id rawID: String,
        tabID: UUID?
    ) async throws -> ChatSession? {
        if let loaded = resolveSession(id: rawID) {
            return loaded
        }
        guard let tabID,
              let candidate = workspaceManager.bindingCandidate(forContextID: tabID),
              let workspace = workspaceManager.workspaces.first(where: { $0.id == candidate.workspaceID }),
              let persisted = try await chatData.findSession(for: workspace, id: rawID, composeTabID: tabID)
        else {
            return nil
        }

        // Inactive headless generation deliberately avoids publishing into the active
        // workspace's chat catalog. Load only an explicitly requested continuation;
        // activation remains disabled for an inactive tab, so currentSession is untouched.
        if !sessions.contains(where: { $0.id == persisted.id }) {
            sessions.append(persisted)
        }
        return persisted
    }

    @MainActor
    private func resolveBackgroundTabID(
        for session: ChatSession,
        fallbackTabID: UUID?
    ) async -> UUID? {
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

        return await ensureTabForSession(session)
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
        workspaceID: UUID? = nil,
        tabID: UUID? = nil,
        activateInUI: Bool = true,
        setActiveForTab: Bool = true,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil,
        reuseBlankSession: Bool = true
    ) async throws -> ChatSession {
        let safeName = ChatSession.validatedName(name ?? "")
        let createdID = await startNewChatSession(
            name: safeName,
            workspaceID: workspaceID,
            tabID: tabID,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID,
            activateInUI: activateInUI,
            setActiveForTab: setActiveForTab,
            reuseBlankSession: reuseBlankSession
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
        Task { [weak self] in
            guard let self else { return }
            _ = try? await autosaveSession(sessionToSave)
        }
    }

    @MainActor
    private func activateResolvedChatSession(
        _ session: ChatSession,
        resolvedTabID: UUID?,
        activateInUI: Bool
    ) async {
        if activateInUI {
            await switchToSession(session.id)
            return
        }

        _ = await ensureSessionLoadedForBackground(session)
        let targetTabID = await resolveBackgroundTabID(
            for: session,
            fallbackTabID: resolvedTabID
        )
        if let targetTabID {
            workspaceManager.setActiveChatSessionID(session.id, forTabID: targetTabID)
        }
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
        agentModeRunID: UUID? = nil
    ) async throws -> UUID {
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
            guard let existing = try await resolveSessionForExplicitContinuation(
                id: idString,
                tabID: resolvedTabID
            ) else {
                throw ChatToolError.invalidParams("Chat with ID '\(idString)' not found")
            }
            guard Self.sessionBelongsToResolvedTab(existing, tabID: resolvedTabID) else {
                throw ChatToolError.invalidParams("Chat with ID '\(idString)' belongs to a different tab")
            }
            guard Self.sessionMatchesOracleOwnerForExplicitContinuation(
                existing,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            ) else {
                throw ChatToolError.invalidParams("Chat with ID '\(idString)' belongs to a different Agent Mode owner")
            }

            await applyOracleOwnerIfNeeded(
                sessionID: existing.id,
                tabID: resolvedTabID,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            )
            await activateResolvedChatSession(existing, resolvedTabID: resolvedTabID, activateInUI: activateInUI)

            if let newName = desiredName,
               !newName.isEmpty,
               newName != existing.name
            {
                renameSession(id: existing.id, newName: ChatSession.validatedName(newName))
            }
            return existing.id
        }

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
        func findCandidate(allowUnownedLegacy: Bool) -> ChatSession? {
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
                    allowUnownedLegacy: allowUnownedLegacy
                )
            } else {
                scopedSessions.filter { eligible($0, allowUnownedLegacy: allowUnownedLegacy) }
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
            return candidates.sorted(by: { $0.savedAt > $1.savedAt }).first
        }

        let candidate = hasOwner
            ? findCandidate(allowUnownedLegacy: false)
            : findCandidate(allowUnownedLegacy: true)

        if let candidate {
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

    private struct OraclePairSessionResolution {
        let pairID: UUID
        let primary: ChatSession
        let secondary: ChatSession
    }

    private func validatedOracleSendMode(_ args: [String: Value]) throws -> String {
        let removedArgs = ["selected_paths", "git_scope", "git_base"].filter { args[$0] != nil }
        if !removedArgs.isEmpty {
            throw ChatToolError.invalidParams(
                "ask_oracle no longer accepts \(removedArgs.joined(separator: ", ")). Use manage_selection for selection and git tools for git context."
            )
        }

        let mode = args["mode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "chat"
        guard ["chat", "plan", "review"].contains(mode) else {
            throw ChatToolError.invalidParams("Invalid mode: \(mode). Valid modes: chat, plan, review")
        }
        return mode
    }

    @MainActor
    private func configuredSecondaryOracleModel(
        promptVM: PromptViewModel,
        workspaceID: UUID?
    ) throws -> AIModel? {
        let profile = GlobalSettingsStore.shared.effectiveAgentModelsProfile(workspaceID: workspaceID)
        guard let raw = profile.secondaryOracleModelRaw?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        guard let model = AIModel.fromModelName(raw) else {
            throw ChatToolError.invalidParams(
                "Secondary Oracle Model '\(raw)' is not a recognized Oracle model ID."
            )
        }
        guard promptVM.mcpOracleIsProviderConfigured(for: model) else {
            throw ChatToolError.invalidParams(
                "Secondary Oracle Model '\(model.displayName)' is not available."
            )
        }
        return model
    }

    @MainActor
    private func resolvedOracleMessage(
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext?
    ) throws -> String {
        if args["use_tab_prompt"]?.boolValue ?? false {
            let message = (tabContext?.packaging.promptText ?? promptVM.promptText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                throw ChatToolError.invalidParams("Active tab prompt is empty (use_tab_prompt=true)")
            }
            return message
        }
        guard let message = args["message"]?.stringValue, !message.isEmpty else {
            throw ChatToolError.invalidParams("message cannot be empty")
        }
        return message
    }

    private nonisolated static func sessionMatchesExactOracleRoute(
        _ session: ChatSession,
        workspaceID: UUID,
        tabID: UUID,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?
    ) -> Bool {
        session.workspaceID == workspaceID &&
            session.composeTabID == tabID &&
            session.agentModeSessionID == agentModeSessionID &&
            session.agentModeRunID == agentModeRunID
    }

    @MainActor
    private func resolveOraclePairSource(
        requestedChatID: String?,
        forceNew: Bool,
        workspaceID: UUID,
        tabID: UUID,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?
    ) async throws -> ChatSession? {
        guard !forceNew else { return nil }
        if let requestedChatID = requestedChatID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedChatID.isEmpty
        {
            guard let source = try await resolveSessionForExplicitContinuation(id: requestedChatID, tabID: tabID) else {
                throw ChatToolError.notFound("Chat with ID '\(requestedChatID)' not found")
            }
            guard Self.sessionMatchesExactOracleRoute(
                source,
                workspaceID: workspaceID,
                tabID: tabID,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            ) else {
                throw ChatToolError.invalidParams("The requested Oracle chat belongs to a different workspace, tab, Agent session, or run.")
            }
            return source
        }

        let candidates = sessions.filter {
            Self.sessionMatchesExactOracleRoute(
                $0,
                workspaceID: workspaceID,
                tabID: tabID,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            ) && $0.oraclePairID != nil && $0.oracleLane == .primary
        }.sorted { $0.savedAt > $1.savedAt }
        if let activeID = workspaceManager.activeChatSessionID(forTabID: tabID),
           let active = candidates.first(where: { $0.id == activeID })
        {
            return active
        }
        if let currentSessionID,
           let current = candidates.first(where: { $0.id == currentSessionID })
        {
            return current
        }
        return candidates.first
    }

    nonisolated static func validatedPersistedOraclePairMembers(
        _ members: [ChatSession],
        pairID: UUID,
        workspaceID: UUID,
        tabID: UUID,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?
    ) throws -> [ChatSession] {
        guard members.count == 2 else {
            throw ChatToolError(
                code: .conflict,
                message: "Oracle pair \(pairID.uuidString) is incomplete; start a new Oracle chat instead of continuing it.",
                details: nil
            )
        }
        guard members.allSatisfy({
            sessionMatchesExactOracleRoute(
                $0,
                workspaceID: workspaceID,
                tabID: tabID,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            )
        }) else {
            throw ChatToolError.internalError("Oracle pair metadata crosses workspace, tab, Agent session, or run boundaries.")
        }
        let primaries = members.filter { $0.oraclePairID == pairID && $0.oracleLane == .primary }
        let secondaries = members.filter { $0.oraclePairID == pairID && $0.oracleLane == .secondary }
        guard primaries.count == 1, secondaries.count == 1 else {
            throw ChatToolError.internalError("Oracle pair metadata is corrupt: missing or duplicate lane metadata.")
        }
        return members
    }

    @MainActor
    private func hydratePersistedOraclePairMembersIfNeeded(
        pairID: UUID,
        workspaceID: UUID,
        tabID: UUID,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?
    ) async throws {
        let inMemoryMembers = sessions.filter { $0.oraclePairID == pairID }
        if inMemoryMembers.count >= 2 {
            let primaries = inMemoryMembers.filter { $0.oracleLane == .primary }
            let secondaries = inMemoryMembers.filter { $0.oracleLane == .secondary }
            guard inMemoryMembers.count == 2, primaries.count == 1, secondaries.count == 1,
                  inMemoryMembers.allSatisfy({
                      Self.sessionMatchesExactOracleRoute(
                          $0,
                          workspaceID: workspaceID,
                          tabID: tabID,
                          agentModeSessionID: agentModeSessionID,
                          agentModeRunID: agentModeRunID
                      )
                  })
            else {
                throw ChatToolError.internalError("Oracle pair metadata is corrupt in memory.")
            }
        }
        guard let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceID }) else {
            throw ChatToolError.invalidParams("The Oracle pair workspace is unavailable.")
        }
        let rawPersistedMembers = try await chatData.oraclePairSessionStubs(for: workspace, pairID: pairID)
        let persistedMembers = try Self.validatedPersistedOraclePairMembers(
            rawPersistedMembers,
            pairID: pairID,
            workspaceID: workspaceID,
            tabID: tabID,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID
        )
        for member in persistedMembers where !sessions.contains(where: { $0.id == member.id }) {
            guard let fileURL = member.fileURL,
                  let loaded = try? await chatData.loadChatSession(from: fileURL),
                  loaded.oraclePairID == pairID,
                  loaded.oracleLane == member.oracleLane,
                  Self.sessionMatchesExactOracleRoute(
                      loaded,
                      workspaceID: workspaceID,
                      tabID: tabID,
                      agentModeSessionID: agentModeSessionID,
                      agentModeRunID: agentModeRunID
                  )
            else {
                throw ChatToolError.internalError("Failed to hydrate a valid Oracle pair member.")
            }
            sessions.append(loaded)
        }
    }

    @MainActor
    private func persistOraclePairMetadata(
        primarySessionID: UUID,
        secondarySessionID: UUID,
        pairID: UUID,
        historyDiverged: Bool,
        workspaceID: UUID,
        tabID: UUID,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?
    ) async throws -> (primary: ChatSession, secondary: ChatSession) {
        guard let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceID }) else {
            throw ChatToolError.invalidParams("The Oracle pair workspace is unavailable.")
        }
        func updatedSession(id: UUID, lane: OracleLane) throws -> ChatSession {
            guard var updated = sessions.first(where: { $0.id == id }) else {
                throw ChatToolError.internalError("Failed to resolve the Oracle \(lane.rawValue) session.")
            }
            updated.workspaceID = workspaceID
            updated.composeTabID = tabID
            updated.agentModeSessionID = agentModeSessionID
            updated.agentModeRunID = agentModeRunID
            updated.oraclePairID = pairID
            updated.oracleLane = lane
            updated.oracleHistoryDiverged = historyDiverged
            return updated
        }
        let primary = try updatedSession(id: primarySessionID, lane: .primary)
        let secondary = try updatedSession(id: secondarySessionID, lane: .secondary)
        for updated in [primary, secondary] {
            guard let index = sessions.firstIndex(where: { $0.id == updated.id }) else {
                throw ChatToolError.internalError("An Oracle pair member disappeared before metadata persistence.")
            }
            sessions[index] = updated
        }

        let fileURLs = try await chatData.saveChatSessions([primary, secondary], for: workspace)
        guard let primaryIndex = sessions.firstIndex(where: { $0.id == primarySessionID }),
              let secondaryIndex = sessions.firstIndex(where: { $0.id == secondarySessionID }),
              sessions[primaryIndex].oraclePairID == pairID,
              sessions[primaryIndex].oracleLane == .primary,
              sessions[secondaryIndex].oraclePairID == pairID,
              sessions[secondaryIndex].oracleLane == .secondary
        else {
            throw ChatToolError(code: .conflict, message: "The Oracle pair changed while metadata was being saved.", details: nil)
        }
        sessions[primaryIndex].fileURL = fileURLs[primarySessionID]
        sessions[secondaryIndex].fileURL = fileURLs[secondarySessionID]
        return (sessions[primaryIndex], sessions[secondaryIndex])
    }

    @MainActor
    private func resolveOrCreateOraclePairSessions(
        requestedChatID: String?,
        forceNew: Bool,
        desiredName: String?,
        workspaceID: UUID,
        tabID: UUID,
        activatePrimaryInUI: Bool,
        agentModeSessionID: UUID?,
        agentModeRunID: UUID?
    ) async throws -> OraclePairSessionResolution {
        let source = try await resolveOraclePairSource(
            requestedChatID: requestedChatID,
            forceNew: forceNew,
            workspaceID: workspaceID,
            tabID: tabID,
            agentModeSessionID: agentModeSessionID,
            agentModeRunID: agentModeRunID
        )
        let pairID = source?.oraclePairID ?? UUID()

        let priorCurrentSessionID = currentSessionID
        let priorTabActiveSessionID = workspaceManager.activeChatSessionID(forTabID: tabID)
        var snapshots: [UUID: ChatSession] = [:]
        var createdSessionIDs: Set<UUID> = []
        var persistedExistingSessionIDs: [UUID] = []
        do {
            if source?.oraclePairID != nil {
                try await hydratePersistedOraclePairMembersIfNeeded(
                    pairID: pairID,
                    workspaceID: workspaceID,
                    tabID: tabID,
                    agentModeSessionID: agentModeSessionID,
                    agentModeRunID: agentModeRunID
                )
            }

            var primary: ChatSession?
            var secondary: ChatSession?
            if source?.oraclePairID != nil {
                let members = sessions.filter { $0.oraclePairID == pairID }
                let primaries = members.filter { $0.oracleLane == .primary }
                let secondaries = members.filter { $0.oracleLane == .secondary }
                guard primaries.count == 1, secondaries.count == 1, members.count == 2 else {
                    throw ChatToolError.internalError("Oracle pair metadata is incomplete or corrupt.")
                }
                for member in members {
                    guard Self.sessionMatchesExactOracleRoute(
                        member,
                        workspaceID: workspaceID,
                        tabID: tabID,
                        agentModeSessionID: agentModeSessionID,
                        agentModeRunID: agentModeRunID
                    ) else {
                        throw ChatToolError.internalError("Oracle pair metadata crosses workspace, tab, Agent session, or run boundaries.")
                    }
                }
                primary = primaries[0]
                secondary = secondaries[0]
            } else if let source {
                guard source.oracleLane != .secondary else {
                    throw ChatToolError.internalError("Secondary Oracle session is missing its pair ID.")
                }
                primary = source
            }

            for existing in [primary, secondary].compactMap(\.self) {
                guard !isSessionStreaming(existing.id),
                      let loaded = await ensureSessionLoadedForBackground(existing)
                else {
                    throw ChatToolError(code: .conflict, message: "An Oracle pair session is unavailable or already streaming.", details: nil)
                }
                snapshots[loaded.id] = loaded
                if primary?.id == loaded.id { primary = loaded } else { secondary = loaded }
            }

            let primaryName = desiredName ?? primary?.name ?? "Oracle"
            if primary == nil {
                let created = try await createSession(
                    named: primaryName,
                    workspaceID: workspaceID,
                    tabID: tabID,
                    activateInUI: false,
                    setActiveForTab: false,
                    agentModeSessionID: agentModeSessionID,
                    agentModeRunID: agentModeRunID,
                    reuseBlankSession: false
                )
                createdSessionIDs.insert(created.id)
                primary = created
            }
            if secondary == nil {
                let created = try await createSession(
                    named: "\(primaryName) — Secondary",
                    workspaceID: workspaceID,
                    tabID: tabID,
                    activateInUI: false,
                    setActiveForTab: false,
                    agentModeSessionID: agentModeSessionID,
                    agentModeRunID: agentModeRunID,
                    reuseBlankSession: false
                )
                createdSessionIDs.insert(created.id)
                secondary = created
            }
            guard let primary, let secondary else {
                throw ChatToolError.internalError("Failed to create both Oracle pair sessions.")
            }
            let historyDiverged = primary.oracleHistoryDiverged || secondary.oracleHistoryDiverged ||
                primary.effectiveMessageCount != secondary.effectiveMessageCount
            if snapshots[primary.id] != nil { persistedExistingSessionIDs.append(primary.id) }
            if snapshots[secondary.id] != nil { persistedExistingSessionIDs.append(secondary.id) }
            let persisted = try await persistOraclePairMetadata(
                primarySessionID: primary.id,
                secondarySessionID: secondary.id,
                pairID: pairID,
                historyDiverged: historyDiverged,
                workspaceID: workspaceID,
                tabID: tabID,
                agentModeSessionID: agentModeSessionID,
                agentModeRunID: agentModeRunID
            )
            let persistedPrimary = persisted.primary
            let persistedSecondary = persisted.secondary

            workspaceManager.setActiveChatSessionID(persistedPrimary.id, forTabID: tabID)
            if activatePrimaryInUI {
                await activateResolvedChatSession(persistedPrimary, resolvedTabID: tabID, activateInUI: true)
            }
            return OraclePairSessionResolution(
                pairID: pairID,
                primary: persistedPrimary,
                secondary: persistedSecondary
            )
        } catch {
            let preparationError = error
            var createdFileURLs = Set(sessions.compactMap { createdSessionIDs.contains($0.id) ? $0.fileURL : nil })
            if let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceID }) {
                for sessionID in createdSessionIDs {
                    if let persisted = try? await chatData.findSession(
                        for: workspace,
                        id: sessionID.uuidString,
                        composeTabID: tabID
                    ), let fileURL = persisted.fileURL {
                        createdFileURLs.insert(fileURL)
                    }
                }
            }
            let operationSessionIDs = createdSessionIDs.union(snapshots.keys)
            for (sessionID, snapshot) in snapshots {
                guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { continue }
                sessions[index].workspaceID = snapshot.workspaceID
                sessions[index].composeTabID = snapshot.composeTabID
                sessions[index].agentModeSessionID = snapshot.agentModeSessionID
                sessions[index].agentModeRunID = snapshot.agentModeRunID
                sessions[index].oraclePairID = snapshot.oraclePairID
                sessions[index].oracleLane = snapshot.oracleLane
                sessions[index].oracleHistoryDiverged = snapshot.oracleHistoryDiverged
                sessions[index].fileURL = snapshot.fileURL
            }
            let activeSessionIDAfterFailure = workspaceManager.activeChatSessionID(forTabID: tabID)
            let currentSessionIDAfterFailure = currentSessionID
            removeOraclePairSessionState(createdSessionIDs)
            var rollbackFailures: [String] = []
            if let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceID }) {
                let sessionsToRestore = persistedExistingSessionIDs.compactMap { snapshots[$0] }
                if !sessionsToRestore.isEmpty {
                    do { _ = try await chatData.saveChatSessions(sessionsToRestore, for: workspace) }
                    catch { rollbackFailures.append("restore pair: \(error.localizedDescription)") }
                }
            }
            if !createdFileURLs.isEmpty {
                do {
                    try await chatData.deleteChatSessionFiles(
                        Array(createdFileURLs),
                        sessionIDs: createdSessionIDs
                    )
                } catch {
                    rollbackFailures.append("delete created pair: \(error.localizedDescription)")
                }
            }
            if let activeSessionIDAfterFailure,
               operationSessionIDs.contains(activeSessionIDAfterFailure)
            {
                workspaceManager.setActiveChatSessionID(priorTabActiveSessionID, forTabID: tabID)
            }
            if let currentSessionIDAfterFailure,
               operationSessionIDs.contains(currentSessionIDAfterFailure)
            {
                currentSessionID = priorCurrentSessionID
            }
            guard rollbackFailures.isEmpty else {
                throw ChatToolError.internalError(
                    "Oracle pair preparation failed (\(preparationError.localizedDescription)); rollback also failed: \(rollbackFailures.joined(separator: "; "))"
                )
            }
            throw preparationError
        }
    }

    nonisolated static func oracleHistoriesDiverged(
        primary: [String],
        secondary: [String]
    ) -> Bool {
        primary != secondary
    }

    /// Full implementation of the shared oracle send backend.
    @MainActor
    func tool_chatSend(
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext? = nil
    ) async throws -> [String: Value] {
        let mode = try validatedOracleSendMode(args)
        let workspaceID = tabContext?.workspaceID ?? workspaceManager.activeWorkspace?.id
        guard let secondaryModel = try configuredSecondaryOracleModel(promptVM: promptVM, workspaceID: workspaceID) else {
            return try await tool_singleChatSend(args: args, promptVM: promptVM, tabContext: tabContext)
        }
        guard let workspaceID,
              let tabID = tabContext?.tabID ?? promptVM.activeComposeTabID,
              workspaceManager.bindingCandidate(forContextID: tabID)?.workspaceID == workspaceID
        else {
            throw ChatToolError.invalidParams("Paired Oracle requires an exact active workspace and tab route.")
        }

        let route = OraclePairRoute(
            workspaceID: workspaceID,
            tabID: tabID,
            agentModeSessionID: tabContext?.agentModeSessionID,
            agentModeRunID: tabContext?.agentModeRunID
        )
        do {
            return try await oraclePairClaims.withClaim([.route(route)]) {
                try await self.tool_pairedChatSend(
                    args: args,
                    promptVM: promptVM,
                    tabContext: tabContext,
                    mode: mode,
                    secondaryModel: secondaryModel,
                    workspaceID: workspaceID,
                    tabID: tabID
                )
            }
        } catch OraclePairClaimError.conflict {
            throw ChatToolError(
                code: .conflict,
                message: "This Oracle route already has an in-flight paired request.",
                details: nil
            )
        }
    }

    @MainActor
    private func tool_pairedChatSend(
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext?,
        mode: String,
        secondaryModel: AIModel,
        workspaceID: UUID,
        tabID: UUID
    ) async throws -> [String: Value] {
        _ = try resolvedOracleMessage(args: args, promptVM: promptVM, tabContext: tabContext)
        let primarySelection = try await selectModel(
            modelParam: args["model"]?.stringValue,
            mode: mode,
            allPresets: ModelPresetsManager.shared.allPresets(),
            promptVM: promptVM
        )
        let shouldActivatePrimary: Bool = if let tabContext {
            promptVM.activeComposeTabID == tabContext.tabID &&
                !isSessionStreaming(workspaceManager.activeChatSessionID(forTabID: tabContext.tabID))
        } else {
            true
        }
        let pair = try await resolveOrCreateOraclePairSessions(
            requestedChatID: args["chat_id"]?.stringValue,
            forceNew: args["new_chat"]?.boolValue ?? false,
            desiredName: args["chat_name"]?.stringValue,
            workspaceID: workspaceID,
            tabID: tabID,
            activatePrimaryInUI: shouldActivatePrimary,
            agentModeSessionID: tabContext?.agentModeSessionID,
            agentModeRunID: tabContext?.agentModeRunID
        )
        pinSession(pair.primary.id)
        pinSession(pair.secondary.id)
        defer {
            unpinSession(pair.secondary.id)
            unpinSession(pair.primary.id)
        }
        guard await ensureSessionLoadedForBackground(pair.primary) != nil,
              await ensureSessionLoadedForBackground(pair.secondary) != nil
        else {
            throw ChatToolError.internalError("Failed to load both Oracle pair transcripts.")
        }
        var primaryArgs = args
        primaryArgs["chat_id"] = .string(pair.primary.shortID)
        primaryArgs["new_chat"] = .bool(false)
        var secondaryArgs = args
        secondaryArgs["chat_id"] = .string(pair.secondary.shortID)
        secondaryArgs["new_chat"] = .bool(false)
        secondaryArgs["model"] = .string(secondaryModel.rawValue)
        let secondarySelection = ModelSelectionResult(
            model: secondaryModel,
            mcpControlInfo: "Secondary Oracle (\(secondaryModel.displayName))",
            isAutoSelected: false,
            chatPresetID: primarySelection.chatPresetID
        )
        let execution: OraclePairCoordinator.Result<[String: Value]>
        do {
            execution = try await OraclePairCoordinator.run(
                primary: {
                    let result = try await self.tool_singleChatSend(
                        args: primaryArgs,
                        promptVM: promptVM,
                        tabContext: tabContext,
                        modelSelectionOverride: primarySelection,
                        activateInUI: shouldActivatePrimary,
                        completionPolicy: .pairedLane(.primary)
                    )
                    _ = try OraclePairCoordinator.validatedResponse(result["response"]?.stringValue, lane: .primary)
                    return result
                },
                secondary: {
                    let result = try await self.tool_singleChatSend(
                        args: secondaryArgs,
                        promptVM: promptVM,
                        tabContext: tabContext,
                        modelSelectionOverride: secondarySelection,
                        activateInUI: false,
                        completionPolicy: .pairedLane(.secondary)
                    )
                    _ = try OraclePairCoordinator.validatedResponse(result["response"]?.stringValue, lane: .secondary)
                    return result
                }
            )
        } catch is CancellationError {
            _ = try? await persistOraclePairHistories(
                pairID: pair.pairID,
                primarySessionID: pair.primary.id,
                secondarySessionID: pair.secondary.id
            )
            throw CancellationError()
        }

        let historyDiverged: Bool
        var historyPersistenceError: String?
        do {
            historyDiverged = try await persistOraclePairHistories(
                pairID: pair.pairID,
                primarySessionID: pair.primary.id,
                secondarySessionID: pair.secondary.id
            )
        } catch {
            historyPersistenceError = error.localizedDescription
            historyDiverged = Self.oracleHistoriesDiverged(
                primary: oracleUserHistory(in: pair.primary.id) ?? [],
                secondary: oracleUserHistory(in: pair.secondary.id) ?? []
            )
            for index in sessions.indices where sessions[index].oraclePairID == pair.pairID {
                sessions[index].oracleHistoryDiverged = historyDiverged
            }
        }
        return OraclePairSendReply(
            pairID: pair.pairID,
            primaryChatID: pair.primary.shortID,
            secondaryChatID: pair.secondary.shortID,
            primaryModel: primarySelection.model,
            secondaryModel: secondaryModel,
            result: execution,
            historyDiverged: historyDiverged,
            historyPersistenceError: historyPersistenceError
        ).toMCPObject(mode: mode)
    }

    enum OracleSingleSendCompletionPolicy {
        case legacy
        case pairedLane(OracleLane)
    }

    @MainActor
    func tool_singleChatSend(
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext? = nil,
        modelSelectionOverride: ModelSelectionResult? = nil,
        activateInUI: Bool? = nil,
        completionPolicy: OracleSingleSendCompletionPolicy = .legacy
    ) async throws -> [String: Value] {
        // ────────── 1. Validate & extract parameters ──────────
        let mode = try validatedOracleSendMode(args)
        let message = try resolvedOracleMessage(args: args, promptVM: promptVM, tabContext: tabContext)
        let chatName = args["chat_name"]?.stringValue
        let chatIdIn = args["chat_id"]?.stringValue
        let newChat = args["new_chat"]?.boolValue ?? false
        _ = args["include_diffs"]?.boolValue
        let selectionOverride = tabContext?.packaging.selection
        let lookupContextOverride = tabContext?.packaging.lookupContext
        let reviewGitContextOverride = tabContext?.packaging.reviewGitContext

        let modelSelection = if let modelSelectionOverride {
            modelSelectionOverride
        } else {
            try await selectModel(
                modelParam: args["model"]?.stringValue,
                mode: mode,
                allPresets: ModelPresetsManager.shared.allPresets(),
                promptVM: promptVM
            )
        }
        let selectedModel = modelSelection.model
        let mcpControlledModel = modelSelection.mcpControlInfo
        let overrideModelName = selectedModel.displayName
        let overrideChatPresetName: String? = {
            if let presetID = modelSelection.chatPresetID,
               let chatPreset = ChatPresetManager.shared.preset(with: presetID) { return chatPreset.name }
            return findBuiltInPreset(for: mode)?.name
        }()

        let tabID = tabContext?.tabID ?? promptVM.activeComposeTabID
        let shouldActivate: Bool
        if let activateInUI {
            shouldActivate = activateInUI
        } else if let tabContext {
            let activeSessionID = workspaceManager.activeChatSessionID(forTabID: tabContext.tabID)
            shouldActivate = promptVM.activeComposeTabID == tabContext.tabID &&
                !isSessionStreaming(activeSessionID)
        } else {
            shouldActivate = true
        }
        let chatID = try await locateOrCreateChat(
            chatIdIn,
            desiredName: chatName,
            forceNew: newChat,
            tabID: tabID,
            activateInUI: shouldActivate,
            agentModeSessionID: tabContext?.agentModeSessionID,
            agentModeRunID: tabContext?.agentModeRunID
        )
        pinSession(chatID)
        defer { unpinSession(chatID) }

        if let mcpControlledModel {
            setMCPSessionUIState(
                MCPSessionUIState(
                    modelInfo: mcpControlledModel,
                    overrideModelName: overrideModelName,
                    overrideChatPresetName: overrideChatPresetName
                ),
                for: chatID
            )
        } else {
            clearMCPSessionUIState(for: chatID)
        }

        let effectiveMode = PromptViewModel.PlanActMode(rawValue: mode.capitalized) ?? .chat
        let persistencePolicy: ChatSendPersistencePolicy = switch completionPolicy {
        case .legacy: .automatic
        case .pairedLane: .coordinatedPair
        }
        let send = {
            await self.sendMessage(
                message,
                sessionID: chatID,
                overrideModel: selectedModel,
                overrideChatPresetID: modelSelection.chatPresetID,
                overrideMode: effectiveMode,
                gitInclusionOverride: nil,
                gitBaseOverride: nil,
                selectionOverride: selectionOverride,
                lookupContextOverride: lookupContextOverride,
                reviewGitContextOverride: reviewGitContextOverride,
                persistencePolicy: persistencePolicy
            )
        }
        let dispatch: ChatSendDispatch?
        #if DEBUG
            let trace = OracleReviewPackagingDiagnostics.makeTraceContext(
                tabContext: tabContext,
                observer: oracleReviewPackagingTraceObserverForTesting
            )
            dispatch = await OracleReviewPackagingDiagnostics.withTrace(trace, operation: send)
        #else
            dispatch = await send()
        #endif

        let queryID: UUID? = switch (completionPolicy, dispatch) {
        case (.legacy, .some(.rejected)): nil
        case let (_, dispatch?): dispatch.assistantMessageID
        case (_, nil): nil
        }
        defer {
            if persistencePolicy == .coordinatedPair, let queryID {
                completeCoordinatedPairPersistence(for: queryID)
            }
        }
        let terminalOutcome: ChatSendTerminalOutcome?
        if let queryID {
            do {
                terminalOutcome = try await waitForMessageFinalisationOutcome(queryID)
            } catch is CancellationError {
                await cancelAIResponse(in: chatID, skipPartialParseAndSave: false)
                throw CancellationError()
            }
        } else {
            terminalOutcome = nil
        }

        if case let .pairedLane(lane) = completionPolicy {
            switch terminalOutcome {
            case .completed:
                break
            case let .failed(message, partialResponse):
                throw OracleLaneExecutionError(message: message, partialResponse: partialResponse)
            case let .cancelled(message, partialResponse):
                if Task.isCancelled { throw CancellationError() }
                throw OracleLaneExecutionError(
                    message: message,
                    partialResponse: partialResponse,
                    code: .cancelled
                )
            case nil:
                throw OracleLaneExecutionError(message: "Oracle \(lane.rawValue) lane did not start.")
            }
        }

        let aiMessage = queryID.flatMap(getChatMessage(withId:)).flatMap { $0.isUser ? nil : $0 }
        let reply = ChatSendReply(
            chatId: chatID,
            shortId: sessions.first(where: { $0.id == chatID })?.shortID ?? "",
            mode: mode,
            response: aiMessage?.content,
            errors: nil
        )
        guard case var .object(dict) = reply.toMCPValue() else {
            throw ChatToolError.internalError("failed to encode reply")
        }
        if let tabID { dict["context_id"] = .string(tabID.uuidString) }
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
        if let pairID = resolvedSession.oraclePairID {
            result["oracle_pair_id"] = .string(pairID.uuidString)
            result["oracle_lane"] = .string(resolvedSession.oracleLane?.rawValue ?? "unknown")
            result["oracle_history_diverged"] = .bool(resolvedSession.oracleHistoryDiverged)
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
                throw ChatToolError.invalidParams("Chat with ID '\(normalizedChatID)' belongs to a different Agent Mode owner")
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
                throw ChatToolError.invalidParams("No chats found in the current tab")
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
        resolvedModel: AIModel? = nil,
        finalReviewAuthorization: ContextBuilderFinalReviewAuthorization? = nil,
        agentModeSessionID: UUID? = nil,
        agentModeRunID: UUID? = nil,
        onProgress: ((_ text: String, _ reasoning: String?) -> Void)? = nil
    ) async throws -> ChatSendReply {
        // Check cancellation at entry
        try Task.checkCancellation()

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw ChatToolError.invalidParams("Prompt cannot be empty")
        }

        // 1) Resolve model
        let model: AIModel
        let chatPresetID: UUID?

        if let resolvedModel {
            model = resolvedModel
            chatPresetID = nil
        } else if useChatModelDirectly {
            // UI-triggered: use the current chat model directly, bypassing MCP preset logic
            model = promptViewModel.preferredAIModel
            chatPresetID = nil
        } else {
            // MCP-triggered: use preset resolution logic
            let presetsManager = ModelPresetsManager.shared
            let allPresets = presetsManager.allPresets()

            try Task.checkCancellation()

            let modelSelection = try await selectModel(
                modelParam: modelParam,
                mode: mode.mcpModeName,
                allPresets: allPresets,
                promptVM: promptViewModel
            )
            model = modelSelection.model
            chatPresetID = modelSelection.chatPresetID
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
            gitScopeOverride: gitScopeOverride
        )

        try Task.checkCancellation()

        // 4) Stream via AIQueriesService WITHOUT touching OracleViewModel.messages
        let (streamID, stream) = try await aiQueriesService.sendPrompt(aiMessage, model: model)
        let cleanupHandleBox = OracleProviderCleanupHandleBox()
        var didScheduleProviderCleanup = false
        defer {
            if !didScheduleProviderCleanup {
                Task {
                    await self.cleanupOracleProviderConversation(cleanupHandleBox.current(), model: model)
                }
            }
        }

        // Register this headless stream by tab ID so Discover can cancel it.
        headlessStreamsByTabID[tabID] = streamID
        defer {
            // Always clean up mapping when this headless run finishes or errors.
            headlessStreamsByTabID.removeValue(forKey: tabID)
        }

        // Stream with 4-hour timeout using single task group
        // (One Task.sleep for entire stream, not per-chunk - avoids CPU churn)
        let timeout: Duration = .seconds(4 * 60 * 60)

        let (finalText, _, finalTokenInfo, providerCleanupHandle) = try await withThrowingTaskGroup(
            of: (String, String, ChatTokenInfo, ProviderConversationCleanupHandle?).self
        ) { group in
            // Timeout task - throws after 4 hours
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ChatToolError.internalError("Stream timed out after 4 hours of inactivity.")
            }

            // Streaming task - accumulates locally, returns result
            group.addTask { [stream, onProgress, cleanupHandleBox] in
                var accText = ""
                var accReasoning = ""
                var tokens = ChatTokenInfo()
                var cleanupHandle: ProviderConversationCleanupHandle?
                var iterator = stream.makeAsyncIterator()

                while let chunk = try await iterator.next() {
                    accText += chunk.text
                    if let reasoning = chunk.reasoning, !reasoning.isEmpty {
                        accReasoning += reasoning
                        accReasoning = ReasoningTextFormatter.normalize(accReasoning)
                    }
                    if chunk.tokens.promptTokens != nil ||
                        chunk.tokens.completionTokens != nil ||
                        chunk.tokens.cost != nil
                    {
                        tokens = chunk.tokens
                    }
                    if let handle = chunk.cleanupHandle {
                        cleanupHandle = handle
                        await cleanupHandleBox.update(handle)
                    }
                    // Only hop to MainActor for progress callback
                    if let onProgress {
                        let text = accText
                        let reasoning = accReasoning.isEmpty ? nil : accReasoning
                        await MainActor.run { onProgress(text, reasoning) }
                    }
                }
                return (accText, accReasoning, tokens, cleanupHandle)
            }

            // Wait for stream to complete or timeout to fire
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        let trimmedResponse = finalText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else {
            throw ChatToolError.internalError("Request produced no content.")
        }

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
        Task { await cleanupOracleProviderConversation(providerCleanupHandle, model: model) }

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
            selectedChatPresetID: chatPresetID
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
