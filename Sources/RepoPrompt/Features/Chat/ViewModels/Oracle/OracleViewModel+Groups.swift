import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

struct OracleToolSettlementCallbacks {
    let prepared: @MainActor @Sendable (_ groupID: OracleGroupID, _ turnID: OracleTurnID) async -> Void
    let settled: @MainActor @Sendable (_ result: OracleGroupResult, _ turnID: OracleTurnID, _ reconciliationGuidance: String?) -> Void
}

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
    /// Validated parent of an explicit member continuation. Request-local exclusion identity only:
    /// `group` stays nil so this never enables fan-out.
    let singleSessionGroup: OracleGroupDocument?
    var singleSessionModelRaw: String?

    static let none = AppOracleConfiguredRosterSelection(group: nil, singleSessionID: nil, singleSessionGroup: nil)
}

private enum AppOracleConfiguredRosterDispatch {
    case singleMCPValue([String: Value])
    case groupedCompletion(OracleGroupRuntime.Completion, reconciliationGuidance: String?)
}

private enum AppOracleConfiguredRosterSingleFallback {
    case executeSingleMCPValue
    case rejectTypedCompletion
}

enum AppOracleGroupRouting {
    static func usesGroup(additionalModelRaws: [String]) -> Bool {
        !additionalModelRaws.isEmpty
    }

    static func executionProfile(for model: AIModel) -> OracleExecutionProfile? {
        let effort: String?
        if model.providerType == .grokBuild {
            let snapshot = AgentACPModelRegistry.shared.resolvedSnapshotIncludingStandardStore(for: .grokBuild)
            effort = GrokBuildModelSpecifier.decompose(
                raw: model.modelName,
                options: snapshot?.options ?? []
            )?.explicitEffort?.rawValue
        } else {
            effort = model.defaultReasoningEffort
        }
        return try? OracleExecutionProfile(
            providerID: providerID(for: model),
            modelID: model.modelName,
            effectiveReasoningEffort: effort
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
        case .devin: "devin"
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
        capturedProfile: AgentModelsSettingsProfile? = nil,
        selectionSnapshotOverride: OracleSelectionSnapshot? = nil,
        resolvedStartExecution: ResolvedOracleExecution? = nil
    ) async throws -> [String: Value] {
        switch try await executeConfiguredRosterDispatch(
            args: args,
            promptVM: promptVM,
            tabContext: tabContext,
            frozenInput: frozenInput,
            callbacks: callbacks,
            capturedProfile: capturedProfile,
            selectionSnapshotOverride: selectionSnapshotOverride,
            resolvedStartExecution: resolvedStartExecution,
            contextBuilderSupervision: nil,
            singleFallback: .executeSingleMCPValue
        ) {
        case let .singleMCPValue(value):
            value
        case let .groupedCompletion(completion, reconciliationGuidance):
            Self.oracleGroupValue(
                completion.result,
                mode: completion.terminalDocument.turns.last?.input.mode.rawValue ?? "chat",
                tabContext: tabContext,
                reconciliationGuidance: reconciliationGuidance
            )
        }
    }

    @MainActor
    func tool_chatSendWithConfiguredRosterCompletion(
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext? = nil,
        frozenInput: OracleInput? = nil,
        callbacks: AppOracleGroupExecutionCallbacks? = nil,
        capturedProfile: AgentModelsSettingsProfile? = nil,
        selectionSnapshotOverride: OracleSelectionSnapshot? = nil,
        resolvedStartExecution: ResolvedOracleExecution? = nil,
        contextBuilderSupervision: ContextBuilderOracleGroupSupervision? = nil
    ) async throws -> OracleGroupRuntime.Completion {
        switch try await executeConfiguredRosterDispatch(
            args: args,
            promptVM: promptVM,
            tabContext: tabContext,
            frozenInput: frozenInput,
            callbacks: callbacks,
            capturedProfile: capturedProfile,
            selectionSnapshotOverride: selectionSnapshotOverride,
            resolvedStartExecution: resolvedStartExecution,
            contextBuilderSupervision: contextBuilderSupervision,
            singleFallback: .rejectTypedCompletion
        ) {
        case .singleMCPValue:
            throw ChatToolError.internalError("Configured Oracle group dispatcher returned a single response.")
        case let .groupedCompletion(completion, _):
            return completion
        }
    }

    @MainActor
    private func executeConfiguredRosterDispatch(
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext?,
        frozenInput: OracleInput?,
        callbacks: AppOracleGroupExecutionCallbacks?,
        capturedProfile: AgentModelsSettingsProfile?,
        selectionSnapshotOverride: OracleSelectionSnapshot?,
        resolvedStartExecution: ResolvedOracleExecution?,
        contextBuilderSupervision: ContextBuilderOracleGroupSupervision?,
        singleFallback: AppOracleConfiguredRosterSingleFallback
    ) async throws -> AppOracleConfiguredRosterDispatch {
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
        let beginsNewConversation: Bool = switch route {
        case .start:
            true
        case .implicitContinuation:
            selection.group == nil && selection.singleSessionID == nil
        case .continuation:
            false
        }
        var startExecution = beginsNewConversation
            ? try resolvedStartExecution ?? tabContext?.resolvedStartExecution ?? resolveOracleStartExecution(
                mode: args["mode"]?.stringValue ?? "chat",
                modelParam: args["model"]?.stringValue,
                profile: profile,
                promptVM: promptVM,
                snapshotOverride: selectionSnapshotOverride
            )
            : nil
        // An execution with no override owns the built-in policy; it must not fall
        // through to a different profile's custom guidance. Continuations use this request's profile.
        let reconciliationGuidance = if let startExecution {
            startExecution.reconciliationGuidance
        } else {
            profile.oracleReconciliationGuidance
        }
        var supervision = contextBuilderSupervision
        #if DEBUG
            if let diagnostics = tabContext?.requestDiagnostics {
                if diagnostics.primaryOnly || diagnostics.laneTimeout != nil {
                    guard beginsNewConversation, let execution = startExecution else {
                        throw ChatToolError.invalidParams("Oracle diagnostics require a fresh conversation.")
                    }
                    if diagnostics.primaryOnly {
                        startExecution = try execution.primaryOnlyForDiagnostics()
                    }
                    if let timeout = diagnostics.laneTimeout {
                        guard execution.roster.count > 1 else {
                            throw ChatToolError.invalidParams("debug_lane_timeout_seconds requires a configured multi-lane roster.")
                        }
                        supervision = ContextBuilderOracleGroupSupervision(
                            configuration: .init(overallTimeout: timeout, inactivityTimeout: timeout, checkInterval: min(1, timeout)),
                            timeoutOwner: "Oracle diagnostic", timeoutCodePrefix: "oracle_diagnostic"
                        )
                    }
                }
            }
        #endif
        let singleExecution: ResolvedOracleExecution?
        if let startExecution {
            singleExecution = startExecution
        } else if let sessionID = selection.singleSessionID,
                  var session = sessions.first(where: { $0.id == sessionID })
        {
            if let modelRaw = selection.singleSessionModelRaw {
                // Canonical member identity owns the model, including legacy projections.
                session.preferredAIModel = modelRaw
                if session.oracleExecutionAuthority == nil { session.selectedChatPresetID = nil }
            }
            if session.oracleExecutionAuthority == .frozen || selection.singleSessionModelRaw != nil {
                singleExecution = try resolveOracleConversationExecution(
                    session: session,
                    mode: args["mode"]?.stringValue ?? "chat",
                    profile: profile,
                    promptVM: promptVM,
                    snapshotOverride: selectionSnapshotOverride
                )
            } else {
                singleExecution = try resolveOracleStartExecution(
                    mode: args["mode"]?.stringValue ?? "chat",
                    modelParam: nil,
                    profile: profile,
                    promptVM: promptVM,
                    snapshotOverride: selectionSnapshotOverride
                )
            }
        } else {
            singleExecution = nil
        }
        guard (startExecution?.roster.count ?? selection.group?.roster.count ?? 1) > 1 else {
            switch singleFallback {
            case .executeSingleMCPValue:
                var singleArgs = args
                if selection.singleSessionModelRaw != nil {
                    // Group member continuation is append-only; rename owns a separate group mutation.
                    singleArgs.removeValue(forKey: "chat_name")
                }
                let chatArgs = singleArgs
                let send: () async throws -> [String: Value] = { [self] in
                    try await tool_chatSend(
                        args: chatArgs,
                        promptVM: promptVM,
                        tabContext: tabContext,
                        resolvedExecution: singleExecution,
                        implicitSessionID: selection.singleSessionID,
                        requiresProducerDrain: selection.singleSessionGroup != nil
                    )
                }
                guard let group = selection.singleSessionGroup, let sessionID = selection.singleSessionID else {
                    return try await .singleMCPValue(send())
                }
                return try await .singleMCPValue(withExplicitOracleMemberClaim(
                    group: group, sessionID: sessionID, tabContext: tabContext, operation: send
                ))
            case .rejectTypedCompletion:
                throw ChatToolError.invalidParams(
                    "Configured Oracle group execution requires an additional Oracle roster or an existing Oracle group."
                )
            }
        }
        // One ticket lifetime owns every lane and its wrapper, including background lanes
        // whose context intentionally carries no UI/progress authority. Ordinary policy stays interactive.
        if supervision == nil, tabContext?.jobProgress != nil {
            supervision = ContextBuilderOracleGroupSupervision(configuration: nil)
        }
        let completion = try await tool_chatSendGroupCompletion(
            args: args,
            promptVM: promptVM,
            tabContext: tabContext,
            workspaceID: workspaceID,
            startExecution: startExecution,
            reconciliationGuidance: reconciliationGuidance,
            selectionSnapshotOverride: selectionSnapshotOverride,
            existingGroup: selection.group,
            frozenInput: frozenInput,
            callbacks: callbacks,
            contextBuilderSupervision: supervision
        )
        return .groupedCompletion(completion, reconciliationGuidance: reconciliationGuidance)
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
            let aliasGroup = try await store.load(member: OracleMemberLookup(publicChatID: chatID), owner: owner)
            if let group = aliasGroup,
               let member = group.members.first(where: { $0.publicChatID == chatID })
            {
                _ = try validatedOracleProjectionIndex(
                    member: member, group: group, workspaceID: workspaceID, tabID: tabID
                )
            }
            let session = try await resolveSessionForExplicitContinuation(
                id: chatID,
                tabID: tabID,
                agentModeSessionID: tabContext?.agentModeSessionID,
                agentModeRunID: tabContext?.agentModeRunID
            )
            if aliasGroup != nil, session.oracleGroupID == nil {
                throw ChatToolError.internalError("Oracle group projection identity conflict.")
            }
            guard let groupID = session.oracleGroupID else {
                return AppOracleConfiguredRosterSelection(group: nil, singleSessionID: session.id, singleSessionGroup: nil)
            }
            let resolvedGroup = if let aliasGroup {
                aliasGroup
            } else {
                try await store.load(groupID: OracleGroupID(rawValue: groupID), owner: owner)
            }
            guard let group = resolvedGroup else {
                throw ChatToolError.internalError("Canonical Oracle group was not found.")
            }
            guard let member = group.members.first(where: { $0.memberID.rawValue == session.id }) else {
                throw ChatToolError.internalError("Canonical Oracle group member was not found.")
            }
            _ = try validatedOracleProjectionIndex(
                member: member,
                group: group,
                workspaceID: workspaceID,
                tabID: tabID
            )
            // Explicit chat IDs address one conversation. Keep its historical group and
            // siblings unchanged; only implicit selection resumes the whole group.
            return AppOracleConfiguredRosterSelection(
                group: nil, singleSessionID: session.id, singleSessionGroup: group,
                singleSessionModelRaw: member.model.modelID
            )
        case .implicitContinuation:
            let candidate: ChatSession?
            if let capturedID = tabContext?.implicitContinuationSessionID {
                // Resolve the captured identity with the existing owner checks, but retain
                // implicit selection's whole-group semantics. Never fall back to current UI.
                do {
                    candidate = try await resolveSessionForExplicitContinuation(
                        id: capturedID.uuidString,
                        tabID: tabID,
                        agentModeSessionID: tabContext?.agentModeSessionID,
                        agentModeRunID: tabContext?.agentModeRunID
                    )
                } catch let error as ChatToolError where error.code == .invalidParams {
                    // The caller never supplied this ID; report the captured selection instead.
                    throw ChatToolError.invalidParams(
                        "The Oracle chat selected when this ticket was admitted is no longer available. Pass chat_id or new_chat=true."
                    )
                }
            } else {
                candidate = resolveImplicitOracleContinuationCandidate(
                    tabID: tabID,
                    activateInUI: shouldActivateOracleSendSession(tabContext: tabContext, promptVM: promptVM),
                    agentModeSessionID: tabContext?.agentModeSessionID,
                    agentModeRunID: tabContext?.agentModeRunID
                )
            }
            guard let candidate else { return .none }
            if let rawGroupID = candidate.oracleGroupID {
                guard let group = try await store.load(
                    groupID: OracleGroupID(rawValue: rawGroupID),
                    owner: owner
                ),
                    let member = group.members.first(where: { $0.memberID.rawValue == candidate.id })
                else {
                    throw ChatToolError.internalError("Canonical Oracle group was not found.")
                }
                _ = try validatedOracleProjectionIndex(
                    member: member,
                    group: group,
                    workspaceID: workspaceID,
                    tabID: tabID
                )
                return AppOracleConfiguredRosterSelection(group: group, singleSessionID: nil, singleSessionGroup: nil)
            }
            return AppOracleConfiguredRosterSelection(group: nil, singleSessionID: candidate.id, singleSessionGroup: nil)
        }
    }

    /// A lane-only send must exclude its parent group's turns in both directions, across runtimes.
    /// It joins the group runtime's claim namespace, revalidates under it, and holds it until the
    /// single send's producer has drained (`requiresProducerDrain`), releasing on every exit.
    @MainActor
    private func withExplicitOracleMemberClaim(
        group observed: OracleGroupDocument,
        sessionID: UUID,
        tabContext: OracleSendTabContext?,
        operation: () async throws -> [String: Value]
    ) async throws -> [String: Value] {
        // sendMessage replaces a streaming target, so refuse before touching the claim.
        try rejectBusyOracleMember(sessionID: sessionID, group: observed, requiresTerminalTurn: false)
        let composition = AppDomainRuntimeComposition.shared
        let invocationID = UUID()
        let claim: OracleGroupClaim
        do {
            claim = try await composition.oracleGroupClaimManager.acquire(
                group: observed,
                owner: observed.owner,
                invocationID: invocationID,
                runID: tabContext?.agentModeRunID ?? invocationID
            )
        } catch OracleGroupClaimError.conflict {
            throw Self.oracleLaneBusyError(groupID: observed.group.id)
        }
        defer { claim.release() }
        guard let current = try await composition.oracleConversationStore.load(
            groupID: observed.group.id,
            owner: observed.owner
        ),
            current.members.contains(where: { $0.memberID.rawValue == sessionID })
        else {
            throw ChatToolError.internalError("Canonical Oracle group member was not found.")
        }
        try rejectBusyOracleMember(sessionID: sessionID, group: current, requiresTerminalTurn: false)
        let recovered = try await composition.oracleGroupRuntime.recoverInterruptedTurn(current, claim: claim)
        try rejectBusyOracleMember(sessionID: sessionID, group: recovered)
        return try await operation()
    }

    /// A missing latest turn is not busy; `.terminal` is the domain's only settled turn state.
    @MainActor
    private func rejectBusyOracleMember(
        sessionID: UUID,
        group: OracleGroupDocument,
        requiresTerminalTurn: Bool = true
    ) throws {
        if isSessionStreaming(sessionID) || (requiresTerminalTurn && group.turns.last.map { $0.state != .terminal } == true) {
            throw Self.oracleLaneBusyError(groupID: group.group.id)
        }
    }

    private static func oracleLaneBusyError(groupID: OracleGroupID) -> ChatToolError {
        ChatToolError(
            code: .conflict,
            message: "Oracle lane is busy with an active conversation or group turn. Wait for it to finish before continuing this chat.",
            details: ["oracle_group_id": groupID.rawValue.uuidString]
        )
    }

    @MainActor
    private func tool_chatSendGroupCompletion(
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext?,
        workspaceID: UUID?,
        startExecution: ResolvedOracleExecution?,
        reconciliationGuidance: String?,
        selectionSnapshotOverride: OracleSelectionSnapshot?,
        existingGroup: OracleGroupDocument?,
        frozenInput: OracleInput?,
        callbacks: AppOracleGroupExecutionCallbacks?,
        contextBuilderSupervision: ContextBuilderOracleGroupSupervision?
    ) async throws -> OracleGroupRuntime.Completion {
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

        let roster: OracleRoster
        if let existingGroup {
            roster = existingGroup.roster
        } else if let startExecution {
            roster = startExecution.roster
        } else {
            throw ChatToolError.internalError("Resolved Oracle execution is required for a new group.")
        }
        if let images = tabContext?.transientImages, !images.isEmpty {
            for (laneIndex, laneModel) in roster.orderedModels.enumerated() {
                let resolution = PromptViewModel.mcpOraclePlanningModelResolution(
                    rawValue: laneModel.modelID,
                    isModelAvailable: { promptVM.mcpOracleIsProviderConfigured(for: $0) }
                )
                guard case let .configured(resolvedModel) = resolution else {
                    throw ChatToolError.invalidParams(
                        "Image attachments require every Oracle lane model to be configured; Oracle \(laneIndex + 1) is unavailable."
                    )
                }
                guard OracleImageRouteAdmission.supports(resolvedModel) else {
                    throw ChatToolError.invalidParams(
                        "Image attachments are not supported by Oracle \(laneIndex + 1)'s model '\(resolvedModel.displayName)' on provider '\(resolvedModel.providerType.displayName)'."
                    )
                }
            }
        }
        let input = try frozenInput ?? OracleInput(mode: mode, userMessage: message)
        guard input.mode == mode, input.userMessage == message else {
            throw ChatToolError.invalidParams("Frozen Oracle input does not match the requested mode and message.")
        }
        let invocationID = UUID()
        let runID = tabContext?.agentModeRunID ?? invocationID
        let runtimeCallbacks = OracleGroupRuntime.Callbacks(
            prepared: { [weak self] document in
                guard let self else { throw CancellationError() }
                await recordOracleGroupPresentation(document, invocationID: invocationID)
                try await restoreOracleGroupProjectionsIfNeeded(
                    document,
                    workspaceID: workspaceID,
                    tabID: tabID,
                    tabContext: tabContext,
                    startExecution: startExecution
                )
                if let turn = document.turns.last {
                    await tabContext?.jobProgress?.prepared(group: document.group.id, turn: turn.id, members: document.members)
                    try await callbacks?.prepared(document.group.id, turn.id, document.members)
                    await tabContext?.toolSettlement?.prepared(document.group.id, turn.id)
                }
            },
            executeLane: { [weak self] invocation in
                guard let self else { throw CancellationError() }
                return try await executeOracleLane(
                    member: invocation.member,
                    args: args,
                    promptVM: promptVM,
                    tabContext: tabContext,
                    startExecution: startExecution,
                    selectionSnapshotOverride: selectionSnapshotOverride,
                    executionContext: invocation.context,
                    callbacks: callbacks,
                    supervision: contextBuilderSupervision
                )
            },
            progress: { [weak self] event in
                await self?.receiveOracleGroupProgress(event, owner: owner)
                await callbacks?.progress(event)
                await tabContext?.jobProgress?.progress(event)
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
            recordOracleGroupPresentation(completion.terminalDocument)
            if let turn = completion.terminalDocument.turns.last {
                tabContext?.toolSettlement?.settled(completion.result, turn.id, reconciliationGuidance)
            }
            await tabContext?.jobProgress?.settled(.object(OracleGroupMCPCodec.groupFields(completion.result)))
            return completion
        } catch {
            await finishOracleGroupPresentation(invocationID: invocationID)
            if let claimError = error as? OracleGroupClaimError, claimError == .conflict, let existingGroup {
                throw Self.oracleLaneBusyError(groupID: existingGroup.group.id)
            }
            if let runtimeError = error as? OracleGroupRuntime.RuntimeError {
                throw mapOracleGroupRuntimeError(runtimeError)
            }
            throw error
        }
    }

    @MainActor
    private func validatedOracleProjectionIndex(
        member: OracleGroupMember,
        group: OracleGroupDocument,
        workspaceID: UUID?,
        tabID: UUID
    ) throws -> Int? {
        let claims = sessions.indices.filter { index in
            let projection = sessions[index]
            if projection.id == member.memberID.rawValue {
                return true
            }
            guard projection.workspaceID == workspaceID,
                  projection.composeTabID == tabID,
                  projection.oracleGroupID == group.group.id.rawValue
            else {
                return false
            }
            return projection.shortID == member.publicChatID
                || projection.oracleLaneIndex == member.laneID.index
        }
        guard claims.count <= 1 else {
            throw ChatToolError.internalError("Oracle group projection identity conflict.")
        }
        guard let index = claims.first else { return nil }
        try Self.validateOracleProjectionIdentity(
            sessions[index],
            member: member,
            group: group,
            workspaceID: workspaceID,
            tabID: tabID
        )
        return index
    }

    private static func validateOracleProjectionIdentity(
        _ session: ChatSession,
        member: OracleGroupMember,
        group: OracleGroupDocument,
        workspaceID: UUID?,
        tabID: UUID
    ) throws {
        guard session.id == member.memberID.rawValue,
              session.shortID == member.publicChatID,
              session.workspaceID == workspaceID,
              session.composeTabID == tabID,
              session.oracleGroupID == group.group.id.rawValue,
              session.oracleLaneIndex == member.laneID.index,
              session.oracleGroupSize == group.group.size,
              session.oracleModelRaw == member.model.modelID
        else {
            throw ChatToolError.internalError("Oracle group projection identity conflict.")
        }
    }

    @MainActor
    private func restoreOracleGroupProjectionsIfNeeded(
        _ group: OracleGroupDocument,
        workspaceID: UUID?,
        tabID: UUID,
        tabContext: OracleSendTabContext?,
        startExecution: ResolvedOracleExecution?
    ) async throws {
        for member in group.members {
            let expectedName = Self.oracleProjectionName(base: group.name, laneIndex: member.laneID.index)
            if try validatedOracleProjectionIndex(
                member: member,
                group: group,
                workspaceID: workspaceID,
                tabID: tabID
            ) != nil {
                // Existing names can be user- or response-derived. Restoration is not rename.
                continue
            }
            // The app sends from ChatSession history, not the canonical result log.
            if group.turns.contains(where: { turn in
                turn.results.contains {
                    $0.laneIndex == member.laneID.index
                        && ($0.response != nil || $0.error?.partialResponse != nil)
                }
            }) {
                throw ChatToolError.invalidParams(
                    "Oracle conversation history is unavailable. Restore the chat history or set new_chat=true."
                )
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
            if let startExecution,
               let index = sessions.firstIndex(where: { $0.id == member.memberID.rawValue })
            {
                sessions[index].preferredAIModel = startExecution.models[member.laneID.index].rawValue
                sessions[index].selectedChatPresetID = startExecution.promptConfiguration.chatPresetID
            }
        }
    }

    @MainActor
    private func executeOracleLane(
        member: OracleGroupMember,
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext?,
        startExecution: ResolvedOracleExecution?,
        selectionSnapshotOverride: OracleSelectionSnapshot?,
        executionContext: OracleLaneExecutionContext,
        callbacks: AppOracleGroupExecutionCallbacks?,
        supervision: ContextBuilderOracleGroupSupervision?
    ) async throws -> OracleLaneExecutionResponse {
        let scope = supervision?.makeLane(sessionID: member.memberID.rawValue)
        let operation = {
            try await self.executeOracleLaneBody(
                member: member, args: args, promptVM: promptVM, tabContext: tabContext,
                startExecution: startExecution, selectionSnapshotOverride: selectionSnapshotOverride,
                executionContext: executionContext, callbacks: callbacks, scope: scope
            )
        }
        if let scope { return try await scope.run(oracle: self, operation: operation) }
        return try await operation()
    }

    @MainActor
    private func executeOracleLaneBody(
        member: OracleGroupMember,
        args: [String: Value],
        promptVM: PromptViewModel,
        tabContext: OracleSendTabContext?,
        startExecution: ResolvedOracleExecution?,
        selectionSnapshotOverride: OracleSelectionSnapshot?,
        executionContext: OracleLaneExecutionContext,
        callbacks: AppOracleGroupExecutionCallbacks?,
        scope: ContextBuilderOracleLaneScope?
    ) async throws -> OracleLaneExecutionResponse {
        var laneArgs = args
        laneArgs["chat_id"] = .string(member.publicChatID)
        laneArgs["new_chat"] = .bool(false)
        laneArgs.removeValue(forKey: "model")
        laneArgs.removeValue(forKey: "chat_name")
        let laneExecution: ResolvedOracleExecution
        let resolvedLaneIndex: Int
        if let startExecution {
            laneExecution = startExecution
            resolvedLaneIndex = member.laneID.index
        } else {
            guard var session = sessions.first(where: { $0.id == member.memberID.rawValue }) else {
                throw ChatToolError.internalError("Oracle group projection is unavailable.")
            }
            session.preferredAIModel = member.model.modelID
            if session.oracleExecutionAuthority == nil {
                session.selectedChatPresetID = nil
            }
            let profile = GlobalSettingsStore.shared.effectiveAgentModelsProfile(workspaceID: tabContext?.workspaceID)
            laneExecution = try resolveOracleConversationExecution(
                session: session,
                mode: args["mode"]?.stringValue ?? "chat",
                profile: profile,
                promptVM: promptVM,
                snapshotOverride: selectionSnapshotOverride
            )
            resolvedLaneIndex = 0
        }
        let resolvedModel = laneExecution.models[resolvedLaneIndex]
        let executionProfile = AppOracleGroupRouting.executionProfile(for: resolvedModel)
        scope?.executionProfile = executionProfile
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
                    resolvedExecution: laneExecution,
                    resolvedLaneIndex: resolvedLaneIndex,
                    contextBuilderScope: scope,
                    onProgress: { text, reasoning in
                        partialResponse = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
                        scope?.partialResponse = partialResponse
                        callbacks?.laneProgress(member.laneID, text, reasoning)
                    }
                )
            } onCancel: { [weak self] in
                // Scoped cancellation is owned by the lane's arbiter, not an ambient session lookup.
                if scope == nil {
                    Task { @MainActor in
                        await self?.cancelAIResponse(in: sessionID, skipPartialParseAndSave: true)
                    }
                }
            }
            if scope == nil, Task.isCancelled {
                await cancelAIResponse(in: sessionID, skipPartialParseAndSave: true)
                throw OracleLaneCancellation(
                    partialResponse: partialResponse,
                    executionProfile: executionProfile
                )
            }
            guard let response = reply["response"]?.stringValue else {
                throw OracleLaneFailure(code: "empty_response", message: "Oracle lane returned no response.")
            }
            await executionContext.emitDelta(response)
            if scope == nil, Task.isCancelled {
                await cancelAIResponse(in: sessionID, skipPartialParseAndSave: true)
                throw OracleLaneCancellation(
                    partialResponse: partialResponse,
                    executionProfile: executionProfile
                )
            }
            return OracleLaneExecutionResponse(
                response: response,
                executionProfile: executionProfile
            )
        } catch {
            if (scope == nil && Task.isCancelled) || error is CancellationError {
                if scope == nil { await cancelAIResponse(in: sessionID, skipPartialParseAndSave: true) }
                throw OracleLaneCancellation(
                    partialResponse: partialResponse,
                    executionProfile: executionProfile
                )
            }
            if let failure = error as? OracleLaneFailure {
                throw OracleLaneFailure(
                    code: failure.code,
                    message: failure.message,
                    partialResponse: failure.partialResponse ?? partialResponse,
                    executionProfile: failure.executionProfile ?? executionProfile
                )
            }
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
            packaging: context.packaging,
            transientImages: context.transientImages
        )
    }

    static func oracleGroupValue(
        _ result: OracleGroupResult,
        mode: String,
        tabContext: OracleSendTabContext?,
        reconciliationGuidance: String? = nil
    ) -> [String: Value] {
        var object = ContextBuilderOracleGroupReply(
            result: result, reconciliationGuidance: reconciliationGuidance
        ).toMCPFields()
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
        let invalidateDeletedSnapshot = captureChatSessionCatalogDeletionFence(for: session.workspaceID, sessionID: session.id)
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
        guard invalidateDeletedSnapshot.isCurrent() else {
            throw ChatToolError.internalError("Workspace storage changed before the Oracle group could be deleted.")
        }
        for memberSession in sessions where memberIDs.contains(memberSession.id) && isSessionStreaming(memberSession.id) {
            guard invalidateDeletedSnapshot.isCurrent() else {
                throw ChatToolError.internalError("Workspace storage changed before the Oracle group could be deleted.")
            }
            await cancelAIResponse(
                in: memberSession.id,
                skipPartialParseAndSave: true,
                cleanupOwnerIsCurrent: invalidateDeletedSnapshot.isCurrent
            )
        }
        guard invalidateDeletedSnapshot.isCurrent() else {
            throw ChatToolError.internalError("Workspace storage changed before the Oracle group could be deleted.")
        }
        try await store.delete(
            groupID: group.group.id,
            owner: owner,
            expectedRevision: group.revision
        )
        invalidateDeletedSnapshot.invalidate()
        // A released lane's save is an un-awaited tracked task; let it land (and record its file) before deleting files.
        if let workspaceID = session.workspaceID { await drainTrackedAutosaves(for: workspaceID) }
        #if DEBUG
            await workspaceChatSessionDeletionBeforeCommitForTesting?(session.id)
        #endif
        guard invalidateDeletedSnapshot.isCurrent() else {
            throw ChatToolError.internalError("The Oracle group was deleted, but projection cleanup stopped because workspace storage changed.")
        }
        let removed = sessions.filter { memberIDs.contains($0.id) }
        var projectionCleanupFailed = false
        for projection in removed {
            if invalidateDeletedSnapshot.isCurrent() { clearMCPSessionUIState(for: projection.id) }
            if let fileURL = projection.fileURL {
                do {
                    try await chatData.deleteChatSessionFile(fileURL)
                } catch {
                    projectionCleanupFailed = true
                }
            }
            if invalidateDeletedSnapshot.isCurrent() { purgeSessionStorage(projection.id) }
        }
        guard invalidateDeletedSnapshot.isCurrent() else {
            throw ChatToolError.internalError("The Oracle group was deleted, but projection cleanup stopped because workspace storage changed.")
        }
        // Also fence snapshots started while projection cleanup was awaiting disk writes.
        invalidateDeletedSnapshot.invalidate()
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

// MARK: - Canonical group presentation

extension OracleViewModel {
    func oracleMemberPresentation(for session: ChatSession) -> OracleMemberPresentation {
        guard let key = OracleGroupPresentation.Key(session: session),
              isCurrentOracleProjection(session)
        else { return .unknown }
        return oracleGroupPresentations[key]?.member(session) ?? .unknown
    }

    func recordOracleGroupPresentation(_ document: OracleGroupDocument, invocationID: UUID? = nil) {
        let next = OracleGroupPresentation(document: document, invocationID: invocationID)
        if let current = oracleGroupPresentations[next.key] {
            // A store read can win the race with the prepared callback for the same revision.
            let beginsKnownExecution = next.revision == current.revision && next.turnID == current.turnID
                && !current.isTerminal && current.invocationID == nil && invocationID != nil
            guard next.revision > current.revision || beginsKnownExecution else { return }
        }
        oracleGroupPresentations[next.key] = next
        pruneOracleGroupPresentations()
    }

    func receiveOracleGroupProgress(_ event: OracleProgressEvent, owner: OracleConversationOwner) {
        let key = OracleGroupPresentation.Key(groupID: event.groupID, owner: owner)
        guard var current = oracleGroupPresentations[key] else { return }
        let previous = current
        current.receive(event)
        if current != previous { oracleGroupPresentations[key] = current }
    }

    /// One group read on opening/switching groups; never per member or text delta.
    func loadOracleGroupPresentation(containing session: ChatSession) async {
        guard let key = OracleGroupPresentation.Key(session: session),
              isCurrentOracleProjection(session)
        else { return }
        let previous = oracleGroupPresentations[key]
        let document = try? await AppDomainRuntimeComposition.shared.oracleConversationStore.load(
            groupID: key.groupID,
            owner: key.owner
        )
        guard !Task.isCancelled, isCurrentOracleProjection(session) else { return }
        if let document {
            recordOracleGroupPresentation(document)
        } else if oracleGroupPresentations[key] == previous, previous?.invocationID == nil {
            // A failed fresh read cannot prove the cached turn is still current. Do not, however,
            // erase a newer runtime publication that arrived while this read was suspended.
            oracleGroupPresentations.removeValue(forKey: key)
        }
    }

    func finishOracleGroupPresentation(invocationID: UUID) async {
        guard let entry = oracleGroupPresentations.first(where: { $0.value.invocationID == invocationID }) else { return }
        var ended = entry.value
        ended.endExecution()
        oracleGroupPresentations[entry.key] = ended
        // Runtime catch settlement may already have published failure/cancellation before throwing.
        // Read independently of caller cancellation, matching the runtime's terminal publication.
        // If publication also failed, the prepared projection stays unknown, never successful/live.
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        let groupID = entry.key.groupID
        let owner = entry.key.owner
        let document = try? await Task.detached(priority: Task.currentPriority) {
            try await store.load(groupID: groupID, owner: owner)
        }.value
        if let document {
            recordOracleGroupPresentation(document)
        }
        pruneOracleGroupPresentations()
    }

    func pruneOracleGroupPresentations() {
        let retained = Set(sessions.compactMap(OracleGroupPresentation.Key.init(session:)))
        let next = oracleGroupPresentations.filter { retained.contains($0.key) || $0.value.invocationID != nil }
        if next.count != oracleGroupPresentations.count { oracleGroupPresentations = next }
    }

    private func isCurrentOracleProjection(_ session: ChatSession) -> Bool {
        sessions.contains {
            $0.id == session.id && $0.shortID == session.shortID
                && $0.workspaceID == session.workspaceID && $0.composeTabID == session.composeTabID
                && $0.oracleGroupID == session.oracleGroupID && $0.oracleLaneIndex == session.oracleLaneIndex
                && $0.oracleGroupSize == session.oracleGroupSize && $0.oracleModelRaw == session.oracleModelRaw
        }
    }
}
