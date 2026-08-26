import Foundation
import MCP
import RepoPromptDomainRuntime

struct AppOracleGroupExecutionCallbacks {
    let prepared: @MainActor @Sendable (
        _ groupID: OracleGroupID,
        _ turnID: OracleTurnID,
        _ members: [OracleGroupMember]
    ) async throws -> Void
    let progress: @MainActor @Sendable (OracleProgressEvent) async -> Void
    let laneProgress: @MainActor @Sendable (
        _ laneID: OracleLaneID,
        _ text: String,
        _ reasoning: String?
    ) -> Void
}

private struct AppOracleConfiguredRosterSelection {
    let group: OracleGroupDocument?
    let singleSessionID: UUID?

    static let none = AppOracleConfiguredRosterSelection(group: nil, singleSessionID: nil)
}

enum AppOracleGroupRouting {
    static func usesGroup(additionalModelRaws: [String]) -> Bool {
        !additionalModelRaws.isEmpty
    }

    static func startsConfiguredGroup(
        route: OracleConversationRoute,
        additionalModelRaws: [String]
    ) -> Bool {
        guard case .start = route else { return false }
        return usesGroup(additionalModelRaws: additionalModelRaws)
    }

    static func executionProfile(for model: AIModel) -> OracleExecutionProfile? {
        try? OracleExecutionProfile(
            providerID: providerID(for: model),
            modelID: model.modelName,
            effectiveReasoningEffort: model.defaultReasoningEffort
        )
    }

    private static func providerID(for model: AIModel) -> String {
        if case let .customProvider(_, provider, _) = model {
            return provider
        }
        return providerID(for: model.providerType)
    }

    private static func providerID(for provider: AIProviderType) -> String {
        switch provider {
        case .anthropic: "anthropic"
        case .openAI: "openAI"
        case .ollama: "ollama"
        case .azure: "azure"
        case .openRouter: "openRouter"
        case .gemini: "gemini"
        case .deepseek: "deepseek"
        case .customProvider: "customProvider"
        case .fireworks: "fireworks"
        case .grok: "grok"
        case .groq: "groq"
        case .zAI: "zAI"
        case .claudeCode: "claudeCode"
        case .codex: "codex"
        case .openCode: "openCode"
        case .cursor: "cursor"
        case .grokBuild: "grokBuild"
        }
    }
}

extension OracleViewModel {
    /// N=1 calls the existing single-Oracle path and bypasses all group state.
    @MainActor
    func tool_chatSendWithConfiguredRoster(
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext? = nil,
        frozenInput: OracleInput? = nil,
        callbacks: AppOracleGroupExecutionCallbacks? = nil,
        capturedProfile: AgentModelsSettingsProfile? = nil
    ) async throws -> [String: Value] {
        let workspaceID = tabContext?.workspaceID ?? workspaceManager.activeWorkspace?.id
        let profile = capturedProfile
            ?? GlobalSettingsStore.shared.effectiveAgentModelsProfile(workspaceID: workspaceID)
        let route = try OracleConversationRoute.resolve(
            chatID: args["chat_id"]?.stringValue,
            newChat: args["new_chat"]?.boolValue == true,
            modelOverride: args["model"]?.stringValue,
            whenMissingChatID: .continueCurrent
        )
        let selection = try await resolveConfiguredRosterSelection(
            route: route,
            promptVM: promptVM,
            tabContext: tabContext,
            workspaceID: workspaceID
        )
        let startsConfiguredGroup = AppOracleGroupRouting.startsConfiguredGroup(
            route: route,
            additionalModelRaws: profile.additionalOracleModelRaws
        )
        guard startsConfiguredGroup || selection.group != nil else {
            return try await tool_chatSend(
                args: args,
                promptVM: promptVM,
                tabContext: tabContext,
                implicitSessionID: selection.singleSessionID
            )
        }
        return try await tool_chatSendGroup(
            args: args,
            promptVM: promptVM,
            tabContext: tabContext,
            workspaceID: workspaceID,
            profile: profile,
            existingGroup: selection.group,
            frozenInput: frozenInput,
            callbacks: callbacks
        )
    }

    @MainActor
    private func resolveConfiguredRosterSelection(
        route: OracleConversationRoute,
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext?,
        workspaceID: UUID?
    ) async throws -> AppOracleConfiguredRosterSelection {
        let tabID = tabContext?.tabID ?? promptVM.activeComposeTabID
        guard let tabID else { return .none }
        let owner = try Self.oracleGroupOwner(workspaceID: workspaceID, tabID: tabID)
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        switch route {
        case .start:
            return .none
        case let .continuation(chatID):
            let group = try await store.load(
                member: OracleMemberLookup(publicChatID: chatID),
                owner: owner
            )
            return AppOracleConfiguredRosterSelection(group: group, singleSessionID: nil)
        case .implicitContinuation:
            let candidate = resolveImplicitOracleContinuationCandidate(
                tabID: tabID,
                activateInUI: shouldActivateOracleSendSession(tabContext: tabContext, promptVM: promptVM),
                agentModeSessionID: tabContext?.agentModeSessionID,
                agentModeRunID: tabContext?.agentModeRunID
            )
            guard let candidate else { return .none }
            if let rawGroupID = candidate.oracleGroupID {
                guard let group = try await store.load(
                    groupID: OracleGroupID(rawValue: rawGroupID),
                    owner: owner
                ),
                    group.members.contains(where: { $0.memberID.rawValue == candidate.id })
                else {
                    throw ChatToolError.internalError("Canonical Oracle group was not found.")
                }
                return AppOracleConfiguredRosterSelection(group: group, singleSessionID: nil)
            }
            return AppOracleConfiguredRosterSelection(group: nil, singleSessionID: candidate.id)
        }
    }

    @MainActor
    private func tool_chatSendGroup(
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext?,
        workspaceID: UUID?,
        profile: AgentModelsSettingsProfile,
        existingGroup: OracleGroupDocument?,
        frozenInput: OracleInput?,
        callbacks: AppOracleGroupExecutionCallbacks?
    ) async throws -> [String: Value] {
        let useTabPrompt = args["use_tab_prompt"]?.boolValue ?? false
        let rawMessage = args["message"]?.stringValue ?? ""
        let message: String
        if useTabPrompt {
            message = (tabContext?.packaging.promptText ?? promptVM.promptText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                throw ChatToolError.invalidParams("Active tab prompt is empty (use_tab_prompt=true)")
            }
        } else {
            message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { throw ChatToolError.invalidParams("message cannot be empty") }
        }
        let modeRaw = args["mode"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "chat"
        guard let mode = OracleMode(rawValue: modeRaw) else {
            throw ChatToolError.invalidParams("Invalid mode: \(modeRaw). Valid modes: chat, plan, review")
        }
        let tabID = tabContext?.tabID ?? promptVM.activeComposeTabID
        guard let tabID else {
            throw ChatToolError.invalidParams("A tab context is required for multiple Oracles.")
        }
        let owner = try Self.oracleGroupOwner(workspaceID: workspaceID, tabID: tabID)
        let runtime = AppDomainRuntimeComposition.shared.oracleGroupRuntime

        let roster = try Self.oracleRoster(
            primaryRaw: args["model"]?.stringValue ?? profile.planningModelRaw,
            additionalRaws: profile.additionalOracleModelRaws
        )
        let input = try frozenInput ?? OracleInput(mode: mode, userMessage: message)
        guard input.mode == mode, input.userMessage == message else {
            throw ChatToolError.invalidParams("Frozen Oracle input does not match the requested mode and message.")
        }
        let invocationID = UUID()
        let runID = tabContext?.agentModeRunID ?? invocationID
        let runtimeCallbacks = OracleGroupRuntime.Callbacks(
            prepared: { [weak self] document in
                guard let self else { throw CancellationError() }
                try await restoreOracleGroupProjectionsIfNeeded(
                    document,
                    workspaceID: workspaceID,
                    tabID: tabID,
                    tabContext: tabContext
                )
                if let turn = document.turns.last {
                    try await callbacks?.prepared(document.group.id, turn.id, document.members)
                }
            },
            executeLane: { [weak self] invocation in
                guard let self else { throw CancellationError() }
                return try await executeOracleLane(
                    member: invocation.member,
                    args: args,
                    promptVM: promptVM,
                    tabContext: tabContext,
                    executionContext: invocation.context,
                    callbacks: callbacks
                )
            },
            progress: { event in
                await callbacks?.progress(event)
            }
        )

        do {
            let completion: OracleGroupRuntime.Completion
            if let observed = existingGroup {
                completion = try await runtime.execute(
                    OracleGroupRuntime.Request(
                        invocationID: invocationID,
                        runID: runID,
                        claimID: UUID(),
                        input: input,
                        intent: .continuation(
                            .init(
                                group: observed.group,
                                owner: owner,
                                observedRevision: observed.revision,
                                expectedRoster: roster
                            )
                        )
                    ),
                    callbacks: runtimeCallbacks
                )
            } else {
                let descriptor = try OracleGroupDescriptor(size: roster.count)
                let baseName = ChatSession.validatedName(args["chat_name"]?.stringValue ?? "New Chat")
                let sessionIDs = roster.orderedModels.map { _ in UUID() }
                let members = try roster.orderedModels.enumerated().map { index, model in
                    let sessionName = Self.oracleProjectionName(base: baseName, laneIndex: index)
                    return try OracleGroupMember(
                        laneID: OracleLaneID(index: index),
                        memberID: OracleMemberID(rawValue: sessionIDs[index]),
                        publicChatID: ChatSession.makeShortID(name: sessionName, uuid: sessionIDs[index]),
                        model: model
                    )
                }
                completion = try await runtime.execute(
                    OracleGroupRuntime.Request(
                        invocationID: invocationID,
                        runID: runID,
                        claimID: UUID(),
                        input: input,
                        intent: .start(
                            .init(
                                group: descriptor,
                                owner: owner,
                                name: baseName,
                                roster: roster,
                                members: members
                            )
                        )
                    ),
                    callbacks: runtimeCallbacks
                )
            }
            return Self.oracleGroupValue(
                completion.result,
                mode: input.mode.rawValue,
                tabContext: tabContext
            )
        } catch let error as OracleGroupRuntime.RuntimeError {
            throw mapOracleGroupRuntimeError(error)
        }
    }

    @MainActor
    private func restoreOracleGroupProjectionsIfNeeded(
        _ group: OracleGroupDocument,
        workspaceID: UUID?,
        tabID: UUID,
        tabContext: OracleSendTabContext?
    ) async throws {
        for member in group.members {
            let expectedName = Self.oracleProjectionName(base: group.name, laneIndex: member.laneID.index)
            if let index = sessions.firstIndex(where: { $0.id == member.memberID.rawValue }) {
                if let existingGroupID = sessions[index].oracleGroupID,
                   existingGroupID != group.group.id.rawValue
                {
                    throw ChatToolError.internalError("Oracle group projection identity conflict.")
                }
                let needsSave = sessions[index].name != expectedName
                    || sessions[index].oracleGroupID != group.group.id.rawValue
                    || sessions[index].oracleLaneIndex != member.laneID.index
                    || sessions[index].oracleGroupSize != group.group.size
                guard needsSave else { continue }
                sessions[index].name = expectedName
                sessions[index].oracleGroupID = group.group.id.rawValue
                sessions[index].oracleLaneIndex = member.laneID.index
                sessions[index].oracleGroupSize = group.group.size
                let savedURL = try await autosaveSession(sessions[index])
                if let refreshed = sessions.firstIndex(where: { $0.id == member.memberID.rawValue }) {
                    sessions[refreshed].fileURL = savedURL
                    sessions[refreshed].savedAt = Date()
                }
                continue
            }
            let created = await startNewChatSession(
                id: member.memberID.rawValue,
                name: expectedName,
                workspaceID: workspaceID,
                tabID: tabID,
                agentModeSessionID: tabContext?.agentModeSessionID,
                agentModeRunID: tabContext?.agentModeRunID,
                oracleGroupID: group.group.id.rawValue,
                oracleLaneIndex: member.laneID.index,
                oracleGroupSize: group.group.size,
                oracleModelRaw: member.model.modelID,
                activateInUI: false,
                setActiveForTab: false,
                reuseBlankSession: false
            )
            guard created == member.memberID.rawValue else {
                throw ChatToolError.internalError("failed to restore Oracle group projection")
            }
        }
    }

    @MainActor
    private func executeOracleLane(
        member: OracleGroupMember,
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext?,
        executionContext: OracleLaneExecutionContext,
        callbacks: AppOracleGroupExecutionCallbacks?
    ) async throws -> OracleLaneExecutionResponse {
        var laneArgs = args
        laneArgs["chat_id"] = .string(member.publicChatID)
        laneArgs["new_chat"] = .bool(false)
        laneArgs.removeValue(forKey: "model")
        laneArgs.removeValue(forKey: "chat_name")
        let modelResolution = PromptViewModel.mcpOraclePlanningModelResolution(
            rawValue: member.model.modelID,
            isModelAvailable: { promptVM.mcpOracleIsProviderConfigured(for: $0) }
        )
        guard case let .configured(resolvedModel) = modelResolution else {
            let message = PromptViewModel.mcpOraclePlanningModelErrorMessage(
                for: modelResolution,
                availabilityGuidance: { model in
                    "Please check that the \(model.providerType.displayName) provider is configured in Settings."
                }
            ) ?? "Oracle lane model is not configured."
            throw OracleLaneFailure(code: "model_unavailable", message: message)
        }
        let executionProfile = AppOracleGroupRouting.executionProfile(for: resolvedModel)
        let laneContext: OracleSendTabContext? = if member.laneID.index == 0 {
            tabContext
        } else if let tabContext {
            Self.backgroundOracleContext(tabContext)
        } else {
            nil
        }
        let sessionID = member.memberID.rawValue
        var partialResponse: String?
        do {
            let reply = try await withTaskCancellationHandler {
                try await tool_chatSend(
                    args: laneArgs,
                    promptVM: promptVM,
                    tabContext: laneContext,
                    resolvedModel: resolvedModel,
                    onProgress: { text, reasoning in
                        partialResponse = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
                        callbacks?.laneProgress(member.laneID, text, reasoning)
                    }
                )
            } onCancel: { [weak self] in
                Task { @MainActor in
                    await self?.cancelAIResponse(in: sessionID, skipPartialParseAndSave: true)
                }
            }
            guard let response = reply["response"]?.stringValue else {
                throw OracleLaneFailure(code: "empty_response", message: "Oracle lane returned no response.")
            }
            await executionContext.emitDelta(response)
            return OracleLaneExecutionResponse(
                response: response,
                executionProfile: executionProfile
            )
        } catch let failure as OracleLaneFailure {
            throw OracleLaneFailure(
                code: failure.code,
                message: failure.message,
                partialResponse: failure.partialResponse ?? partialResponse,
                executionProfile: failure.executionProfile ?? executionProfile
            )
        } catch is CancellationError {
            await cancelAIResponse(in: sessionID, skipPartialParseAndSave: true)
            throw OracleLaneCancellation(executionProfile: executionProfile)
        } catch {
            throw OracleLaneFailure(
                message: error.localizedDescription,
                partialResponse: partialResponse,
                executionProfile: executionProfile
            )
        }
    }

    private func mapOracleGroupRuntimeError(_ error: OracleGroupRuntime.RuntimeError) -> ChatToolError {
        switch error {
        case .rosterConflict, .singleLaneBypassRequired:
            .invalidParams(
                "The configured Oracle roster differs from this conversation. Restore its roster or set new_chat=true."
            )
        case .continuationMissing, .continuationChanged:
            .internalError("Oracle group changed before continuation ownership was acquired.")
        case .invalidPreparedTurn:
            .internalError("Oracle group is not prepared")
        case let .settlementFailed(execution, settlement):
            .internalError("Oracle group settlement failed after \(execution): \(settlement)")
        }
    }

    private static func oracleRoster(
        primaryRaw: String?,
        additionalRaws: [String]
    ) throws -> OracleRoster {
        guard let primaryRaw,
              !primaryRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ChatToolError.invalidParams(
                "Choose an Oracle model before using an additional Oracle roster."
            )
        }
        do {
            return try OracleRoster(primaryModelID: primaryRaw, additionalModelIDs: additionalRaws)
        } catch {
            throw ChatToolError.invalidParams(error.localizedDescription)
        }
    }

    static func oracleGroupOwner(workspaceID: UUID?, tabID: UUID) throws -> OracleConversationOwner {
        try OracleConversationOwner(
            kind: "app-tab",
            identifier: "workspace:\(workspaceID?.uuidString ?? "none"):tab:\(tabID.uuidString)"
        )
    }

    static func oracleProjectionName(base: String, laneIndex: Int) -> String {
        laneIndex == 0 ? base : "\(base) · \(oracleLabel(laneIndex: laneIndex))"
    }

    static func oracleLabel(laneIndex: Int) -> String {
        OracleRosterContract.displayLabel(laneIndex: laneIndex)
    }

    @MainActor
    func oracleGroupCopyPayload(containing session: ChatSession) async throws -> OracleLaneMarkdownPayload {
        guard let rawGroupID = session.oracleGroupID,
              let tabID = session.composeTabID
        else {
            throw OracleGroupLanePayloadLoader.LoadError.mismatchedProjection
        }
        return try await OracleGroupLanePayloadLoader.load(
            groupID: OracleGroupID(rawValue: rawGroupID),
            owner: Self.oracleGroupOwner(workspaceID: session.workspaceID, tabID: tabID),
            selectedSessionID: session.id,
            sessions: sessions,
            liveMessages: messagesSnapshot(for:),
            store: AppDomainRuntimeComposition.shared.oracleConversationStore
        )
    }

    private static func backgroundOracleContext(_ context: OracleSendTabContext) -> OracleSendTabContext {
        OracleSendTabContext(
            tabID: context.tabID,
            workspaceID: context.workspaceID,
            origin: context.origin,
            agentModeSessionID: context.agentModeSessionID,
            agentModeRunID: context.agentModeRunID,
            activationPolicy: .background,
            packaging: context.packaging
        )
    }

    static func oracleGroupValue(
        _ result: OracleGroupResult,
        mode: String,
        tabContext: OracleSendTabContext?
    ) -> [String: Value] {
        var object = OracleGroupMCPCodec.groupFields(result)
        object.merge([
            "chat_id": .string(result.primary.chatID),
            "mode": .string(mode),
            "response": result.primary.response.map(Value.string) ?? .null,
            "backend": .string("app")
        ]) { _, new in new }
        if let tabID = tabContext?.tabID { object["context_id"] = .string(tabID.uuidString) }
        if let sessionID = tabContext?.agentModeSessionID {
            object["agent_session_id"] = .string(sessionID.uuidString)
        }
        if let runID = tabContext?.agentModeRunID {
            object["agent_run_id"] = .string(runID.uuidString)
        }
        return object
    }

    @MainActor
    func deleteOracleGroupIfNeeded(containing session: ChatSession) async throws -> Bool {
        guard let rawGroupID = session.oracleGroupID else { return false }
        guard let tabID = session.composeTabID,
              let owner = try? Self.oracleGroupOwner(workspaceID: session.workspaceID, tabID: tabID)
        else {
            throw ChatToolError.internalError("Oracle group projection is missing its tab owner.")
        }
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        guard let group = try await store.load(
            groupID: OracleGroupID(rawValue: rawGroupID),
            owner: owner
        ) else { return false }
        let memberIDs = Set(group.members.map(\.memberID.rawValue))
        guard memberIDs.contains(session.id) else { return false }
        for memberSession in sessions where memberIDs.contains(memberSession.id) && isSessionStreaming(memberSession.id) {
            await cancelAIResponse(in: memberSession.id, skipPartialParseAndSave: true)
        }
        try await store.delete(
            groupID: group.group.id,
            owner: owner,
            expectedRevision: group.revision
        )
        let removed = sessions.filter { memberIDs.contains($0.id) }
        var projectionCleanupFailed = false
        for projection in removed {
            clearMCPSessionUIState(for: projection.id)
            if let fileURL = projection.fileURL {
                do {
                    try await chatData.deleteChatSessionFile(fileURL)
                } catch {
                    projectionCleanupFailed = true
                }
            }
            purgeSessionStorage(projection.id)
        }
        sessions.removeAll { memberIDs.contains($0.id) }
        for projection in removed {
            if let tabID = projection.composeTabID,
               workspaceManager.activeChatSessionID(forTabID: tabID).map(memberIDs.contains) == true
            {
                let replacement = sessions
                    .filter { $0.composeTabID == tabID }
                    .max(by: { $0.savedAt < $1.savedAt })
                workspaceManager.setActiveChatSessionID(replacement?.id, forTabID: tabID)
            }
        }
        if currentSessionID.map(memberIDs.contains) == true {
            currentSessionID = nil
            _ = await ensureActiveSessionForCurrentTab(createIfMissing: true)
        }
        if projectionCleanupFailed {
            throw ChatToolError.internalError(
                "The Oracle group was deleted, but one or more projection files could not be removed."
            )
        }
        return true
    }

    @MainActor
    func renameOracleGroup(containing session: ChatSession, newName: String) async throws {
        guard let rawGroupID = session.oracleGroupID,
              let tabID = session.composeTabID,
              let owner = try? Self.oracleGroupOwner(workspaceID: session.workspaceID, tabID: tabID)
        else { throw ChatToolError.internalError("Oracle group projection is missing its durable owner.") }
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        guard let group = try await store.load(
            groupID: OracleGroupID(rawValue: rawGroupID),
            owner: owner
        ) else {
            throw ChatToolError.internalError("Canonical Oracle group was not found.")
        }
        let normalizedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if group.name != normalizedName {
            try await store.rename(
                groupID: group.group.id,
                owner: owner,
                name: normalizedName,
                expectedRevision: group.revision
            )
        }
        var projectionSaveFailed = false
        for member in group.members {
            guard let index = sessions.firstIndex(where: { $0.id == member.memberID.rawValue }) else { continue }
            sessions[index].name = Self.oracleProjectionName(base: normalizedName, laneIndex: member.laneID.index)
            let projection = sessions[index]
            if projection.id == currentSessionID {
                let saved = await withCheckedContinuation { continuation in
                    autosaveChatHistory(for: projection.id, force: true) {
                        continuation.resume(returning: $0)
                    }
                }
                projectionSaveFailed = projectionSaveFailed || !saved
            } else {
                do {
                    let savedURL = try await autosaveSession(projection)
                    if let refreshed = sessions.firstIndex(where: { $0.id == projection.id }) {
                        sessions[refreshed].fileURL = savedURL
                        sessions[refreshed].savedAt = Date()
                    }
                } catch {
                    projectionSaveFailed = true
                }
            }
        }
        if projectionSaveFailed {
            throw ChatToolError.internalError(
                "The Oracle group was renamed, but one or more projection files could not be updated."
            )
        }
    }
}
