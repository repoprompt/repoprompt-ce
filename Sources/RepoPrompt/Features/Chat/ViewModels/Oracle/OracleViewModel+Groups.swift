import Foundation
import MCP
import RepoPromptDomainRuntime

struct AppOracleGroupExecutionCallbacks {
    let prepared: @MainActor @Sendable (
        _ groupID: OracleGroupID,
        _ turnID: OracleTurnID,
        _ members: [OracleGroupMember]
    ) async -> Void
    let progress: @MainActor @Sendable (OracleProgressEvent) async -> Void
    let laneProgress: @MainActor @Sendable (
        _ laneID: OracleLaneID,
        _ text: String,
        _ reasoning: String?
    ) -> Void
}

enum AppOracleGroupRouting {
    static func usesGroup(additionalModelRaws: [String]) -> Bool {
        !additionalModelRaws.isEmpty
    }
}

extension OracleViewModel {
    /// App-backed Oracle roster entry point. The empty-additional-roster branch is intentionally
    /// a literal call into the pre-existing single-Oracle implementation: it performs no group
    /// persistence, claim, preparation, projection, or coordinator work.
    @MainActor
    func tool_chatSendWithConfiguredRoster(
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext? = nil,
        frozenInput: OracleInput? = nil,
        callbacks: AppOracleGroupExecutionCallbacks? = nil
    ) async throws -> [String: Value] {
        let workspaceID = tabContext?.workspaceID ?? workspaceManager.activeWorkspace?.id
        let profile = GlobalSettingsStore.shared.effectiveAgentModelsProfile(workspaceID: workspaceID)
        let usesConfiguredGroup = AppOracleGroupRouting.usesGroup(
            additionalModelRaws: profile.additionalOracleModelRaws
        )
        let continuesExistingGroup = if usesConfiguredGroup {
            false
        } else {
            try await resolvesExistingOracleGroup(
                args: args,
                promptVM: promptVM,
                tabContext: tabContext,
                workspaceID: workspaceID
            )
        }
        guard usesConfiguredGroup || continuesExistingGroup else {
            return try await tool_chatSend(args: args, promptVM: promptVM, tabContext: tabContext)
        }
        return try await tool_chatSendGroup(
            args: args,
            promptVM: promptVM,
            tabContext: tabContext,
            workspaceID: workspaceID,
            profile: profile,
            frozenInput: frozenInput,
            callbacks: callbacks
        )
    }

    @MainActor
    private func resolvesExistingOracleGroup(
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext?,
        workspaceID: UUID?
    ) async throws -> Bool {
        guard args["new_chat"]?.boolValue != true else { return false }
        let tabID = tabContext?.tabID ?? promptVM.activeComposeTabID
        guard let tabID else { return false }
        let owner = try Self.oracleGroupOwner(workspaceID: workspaceID, tabID: tabID)
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        if let chatID = args["chat_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !chatID.isEmpty
        {
            return try await store.load(
                member: OracleMemberLookup(publicChatID: chatID),
                owner: owner
            ) != nil
        }
        guard let latest = try await store.loadMostRecentConversation(owner: owner) else { return false }
        if case .group = latest { return true }
        return false
    }

    @MainActor
    private func tool_chatSendGroup(
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext?,
        workspaceID: UUID?,
        profile: AgentModelsSettingsProfile,
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
        let newChat = args["new_chat"]?.boolValue ?? false
        let requestedChatID = args["chat_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tabID = tabContext?.tabID ?? promptVM.activeComposeTabID
        guard let tabID else {
            throw ChatToolError.invalidParams("A tab context is required for multiple Oracles.")
        }
        let owner = try Self.oracleGroupOwner(workspaceID: workspaceID, tabID: tabID)
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore

        let existingGroup: OracleGroupDocument?
        if newChat {
            existingGroup = nil
        } else if let requestedChatID, !requestedChatID.isEmpty {
            existingGroup = try await store.load(
                member: OracleMemberLookup(publicChatID: requestedChatID),
                owner: owner
            )
            // A named legacy chat remains a literal single-chat continuation even while an
            // N>1 roster is configured. Existing conversations are never silently promoted.
            if existingGroup == nil {
                return try await tool_chatSend(args: args, promptVM: promptVM, tabContext: tabContext)
            }
        } else if case let .group(group)? = try await store.loadMostRecentConversation(owner: owner) {
            existingGroup = group
        } else {
            existingGroup = nil
        }

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

        let prepared: OracleGroupDocument
        if var current = existingGroup {
            let claim = try await AppDomainRuntimeComposition.shared.oracleGroupClaimManager.acquire(
                group: current,
                owner: owner,
                invocationID: invocationID,
                runID: runID
            )
            defer { claim.release() }
            if current.turns.last?.state == .prepared {
                current = try await settleInterruptedOracleGroup(current, store: store)
            }
            guard args["model"] == nil else {
                throw ChatToolError.invalidParams(
                    "model can only be used when starting a new Oracle conversation; set new_chat=true."
                )
            }
            guard current.roster == roster, current.turns.last?.state == .terminal else {
                throw ChatToolError.invalidParams(
                    "The configured Oracle roster differs from this conversation. Restore its roster or set new_chat=true."
                )
            }
            let now = Date()
            prepared = try OracleGroupDocument(
                schemaVersion: current.schemaVersion,
                group: current.group,
                owner: current.owner,
                name: current.name,
                revision: current.revision &+ 1,
                createdAt: current.createdAt,
                updatedAt: now,
                roster: current.roster,
                members: current.members,
                turns: current.turns + [OracleTurnRecord(input: input, state: .prepared, startedAt: now)]
            )
            try await store.save(prepared, expectedRevision: current.revision)
            do {
                try await restoreOracleGroupProjectionsIfNeeded(
                    prepared,
                    workspaceID: workspaceID,
                    tabID: tabID,
                    tabContext: tabContext
                )
                return try await executeOracleGroup(
                    prepared,
                    args: args,
                    promptVM: promptVM,
                    tabContext: tabContext,
                    store: store,
                    callbacks: callbacks
                )
            } catch {
                try await settlePreparedOracleGroupIfNeeded(prepared, error: error, store: store)
                throw error
            }
        }

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
        let now = Date()
        prepared = try OracleGroupDocument(
            group: descriptor,
            owner: owner,
            name: baseName,
            revision: 1,
            createdAt: now,
            updatedAt: now,
            roster: roster,
            members: members,
            turns: [OracleTurnRecord(input: input, state: .prepared, startedAt: now)]
        )
        let claim = try await AppDomainRuntimeComposition.shared.oracleGroupClaimManager.acquire(
            group: prepared,
            owner: owner,
            invocationID: invocationID,
            runID: runID
        )
        defer { claim.release() }
        // The canonical prepared group exists before any app projection becomes visible.
        try await store.create(prepared)
        do {
            try await restoreOracleGroupProjectionsIfNeeded(
                prepared,
                workspaceID: workspaceID,
                tabID: tabID,
                tabContext: tabContext
            )
            return try await executeOracleGroup(
                prepared,
                args: args,
                promptVM: promptVM,
                tabContext: tabContext,
                store: store,
                callbacks: callbacks
            )
        } catch {
            try await settlePreparedOracleGroupIfNeeded(prepared, error: error, store: store)
            throw error
        }
    }

    @MainActor
    private func restoreOracleGroupProjectionsIfNeeded(
        _ group: OracleGroupDocument,
        workspaceID: UUID?,
        tabID: UUID,
        tabContext: OracleSendTabContext?
    ) async throws {
        for member in group.members where !sessions.contains(where: { $0.shortID == member.publicChatID }) {
            let created = await startNewChatSession(
                id: member.memberID.rawValue,
                name: Self.oracleProjectionName(base: group.name, laneIndex: member.laneID.index),
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
    private func executeOracleGroup(
        _ prepared: OracleGroupDocument,
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext?,
        store: DomainOracleConversationStore,
        callbacks: AppOracleGroupExecutionCallbacks?
    ) async throws -> [String: Value] {
        guard let turn = prepared.turns.last, turn.state == .prepared else {
            throw ChatToolError.internalError("Oracle group is not prepared")
        }
        await callbacks?.prepared(prepared.group.id, turn.id, prepared.members)
        let plans = try prepared.members.map { member in
            let lane = try OracleLaneDescriptor(
                group: prepared.group,
                laneID: member.laneID,
                model: member.model
            )
            return try OracleLanePlan(
                lane: lane,
                publicChatID: member.publicChatID
            ) { [weak self] context in
                guard let self else { throw CancellationError() }
                return try await executeOracleLane(
                    member: member,
                    args: args,
                    promptVM: promptVM,
                    tabContext: tabContext,
                    executionContext: context,
                    callbacks: callbacks
                )
            }
        }
        let result = try await OracleGroupCoordinator().execute(
            group: prepared.group,
            turnID: turn.id,
            input: turn.input,
            plans: plans,
            progress: { event in
                await callbacks?.progress(event)
            }
        )
        let terminal = try prepared.settling(result)
        try await Task.detached(priority: Task.currentPriority) {
            try await store.save(terminal, expectedRevision: prepared.revision)
        }.value
        try Task.checkCancellation()
        return Self.oracleGroupValue(result, mode: turn.input.mode.rawValue, tabContext: tabContext)
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
        let laneContext: OracleSendTabContext? = if member.laneID.index == 0 {
            tabContext
        } else if let tabContext {
            Self.backgroundOracleContext(tabContext)
        } else {
            nil
        }
        do {
            let reply = try await tool_chatSend(
                args: laneArgs,
                promptVM: promptVM,
                tabContext: laneContext,
                resolvedModel: resolvedModel,
                onProgress: { text, reasoning in
                    callbacks?.laneProgress(member.laneID, text, reasoning)
                }
            )
            guard let response = reply["response"]?.stringValue else {
                throw OracleLaneFailure(code: "empty_response", message: "Oracle lane returned no response.")
            }
            await executionContext.emitDelta(response)
            return OracleLaneExecutionResponse(response: response)
        } catch let failure as OracleLaneFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OracleLaneFailure(message: String(describing: error))
        }
    }

    private func settleInterruptedOracleGroup(
        _ prepared: OracleGroupDocument,
        store: DomainOracleConversationStore
    ) async throws -> OracleGroupDocument {
        let terminal = try prepared.settlingInterrupted(
            status: .failed,
            code: "interrupted",
            message: "The previous Oracle execution was interrupted before completion."
        )
        try await store.save(terminal, expectedRevision: prepared.revision)
        return terminal
    }

    private func settlePreparedOracleGroupIfNeeded(
        _ prepared: OracleGroupDocument,
        error: Error,
        store: DomainOracleConversationStore
    ) async throws {
        let status: OracleLaneResultStatus = error is CancellationError ? .cancelled : .failed
        let code = error is CancellationError ? "cancelled" : "execution_failed"
        let message = error is CancellationError
            ? "Oracle provider was cancelled."
            : String(String(describing: error).prefix(512))
        try await Task.detached(priority: Task.currentPriority) {
            guard let current = try await store.load(groupID: prepared.group.id, owner: prepared.owner),
                  current.revision == prepared.revision,
                  current.turns.last?.state == .prepared
            else { return }
            let terminal = try current.settlingInterrupted(status: status, code: code, message: message)
            try await store.save(terminal, expectedRevision: current.revision)
        }.value
    }

    private static func oracleRoster(
        primaryRaw: String?,
        additionalRaws: [String]
    ) throws -> OracleRoster {
        guard let primaryRaw,
              !primaryRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ChatToolError.invalidParams(
                "Choose a Primary Oracle model before using an additional Oracle roster."
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
        switch laneIndex {
        case 0: "Primary Oracle"
        case 1: "Secondary Oracle"
        default: "Oracle \(laneIndex + 1)"
        }
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
        try await store.rename(
            groupID: group.group.id,
            owner: owner,
            name: newName,
            expectedRevision: group.revision
        )
        for member in group.members {
            guard let index = sessions.firstIndex(where: { $0.id == member.memberID.rawValue }) else { continue }
            sessions[index].name = Self.oracleProjectionName(base: newName, laneIndex: member.laneID.index)
            let projection = sessions[index]
            if projection.id == currentSessionID {
                autosaveChatHistory(for: projection.id, force: true)
            } else {
                do {
                    let savedURL = try await autosaveSession(projection)
                    if let refreshed = sessions.firstIndex(where: { $0.id == projection.id }) {
                        sessions[refreshed].fileURL = savedURL
                        sessions[refreshed].savedAt = Date()
                    }
                } catch {
                    // Canonical rename already succeeded. Projection repair is retried on use.
                }
            }
        }
    }
}
