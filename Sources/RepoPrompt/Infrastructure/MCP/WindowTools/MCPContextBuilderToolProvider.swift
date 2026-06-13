import Foundation
import JSONSchema
import MCP
import Ontology

private struct ContextBuilderToolResult: Codable {
    let tabID: String
    let status: String
    let prompt: String
    let fileCount: Int
    let totalTokens: Int
    let userTotalTokens: Int?
    let tokenNote: String?
    let tokenBudget: Int?
    let promptMode: String?
    let agent: String?
    let selection: String

    let responseType: String?
    let plan: ChatSendReply?
    let review: ChatSendReply?
    let followUpHint: String?
    let oracleExportPath: String?
    let oracleExportInstruction: String?

    enum CodingKeys: String, CodingKey {
        case tabID = "context_id"
        case status, prompt
        case fileCount = "file_count"
        case totalTokens = "total_tokens"
        case userTotalTokens = "user_total_tokens"
        case tokenNote = "token_note"
        case tokenBudget = "token_budget"
        case promptMode = "prompt_mode"
        case agent
        case selection
        case responseType = "response_type"
        case plan
        case review
        case followUpHint = "follow_up_hint"
        case oracleExportPath = "oracle_export_path"
        case oracleExportInstruction = "oracle_export_instruction"
    }

    func toMCPValue() -> Value {
        var obj: [String: Value] = [
            "context_id": .string(tabID),
            "status": .string(status),
            "prompt": .string(prompt),
            "file_count": .int(fileCount),
            "total_tokens": .int(totalTokens),
            "selection": .string(selection)
        ]

        if let userTotalTokens {
            obj["user_total_tokens"] = .int(userTotalTokens)
        }
        if let tokenNote {
            obj["token_note"] = .string(tokenNote)
        }
        if let tokenBudget {
            obj["token_budget"] = .int(tokenBudget)
        }
        if let promptMode {
            obj["prompt_mode"] = .string(promptMode)
        }
        if let agent {
            obj["agent"] = .string(agent)
        }
        if let responseType {
            obj["response_type"] = .string(responseType)
        }
        if let plan {
            obj["plan"] = plan.toMCPValue()
        }
        if let review {
            obj["review"] = review.toMCPValue()
        }
        if let hint = followUpHint {
            obj["follow_up_hint"] = .string(hint)
        }
        if let oracleExportPath {
            obj["oracle_export_path"] = .string(oracleExportPath)
        }
        if let oracleExportInstruction {
            obj["oracle_export_instruction"] = .string(oracleExportInstruction)
        }

        return .object(obj)
    }
}

@MainActor
final class MCPContextBuilderToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .contextBuilder

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
    }

    func buildTools() -> [Tool] {
        [contextBuilderTool()]
    }

    private func contextBuilderTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.contextBuilder,
            freshnessPolicy: .providerManaged,
            description: """
            Intelligently explore the codebase and build optimal file context for a task.

            A Context Builder agent analyzes your codebase, selects relevant files within a token budget, and rewrites your instructions into a clarified prompt. Describe **what** you need, not **where** to look — the agent discovers the right files autonomously. Mention what you know and what you're unsure about; being too prescriptive narrows discovery.

            **response_type** (what happens after context building):
            | Type | Behavior |
            |------|----------|
            | (omit) or `clarify` | Context only — returns selection and prompt for you to use |
            | `question` | Answers a question about the codebase using built context |
            | `plan` | Generates implementation plan for the task |
            | `review` | Generates code review with git diff context |

            **Structuring instructions** (XML tags):
            - `<task>`: Main goal
            - `<context>`: Background, constraints, known file references
            - `<discovery_agent-guidelines>`: Optional starting hints for the agent (not passed to follow-up model). The agent explores beyond these freely — omit if you don't have specific leads.

            **Example**:
            ```
            <task>Add user authentication using JWT</task>
            <context>The app has an existing session system. See docs/auth-spec.md for requirements.</context>
            <discovery_agent-guidelines>There may be auth-related code in src/auth/ already</discovery_agent-guidelines>
            ```

            **Exporting**: Pass `export_response: true` (requires a `response_type` that generates a response) to write the result to a file and get back `oracle_export_path` plus `oracle_export_instruction`. To hand the export to a child agent, include `oracle_export_path` inside the `message` (or `messages`) you send on your next delegation call; your system prompt names the specific delegation tool available to you.

            **Workflow**: Continue with `ask_oracle(chat_id: "<returned_id>", new_chat: false)`. Refine with `manage_selection`.

            **Agent mode behavior**: If this tool is invoked during an Agent Mode run, it reuses the current agent tab instead of creating a new tab.

            **Timing**: 30s-5min depending on codebase size and task complexity.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                properties: [
                    "instructions": .string(description: "Your request, ideally structured with XML tags: <task> for the main goal, <context> for background/constraints/file references, <discovery_agent-guidelines> for optional starting hints. Describe what you need — the agent finds the right files."),
                    "response_type": .string(description: "Optional: 'plan' to generate implementation plan, 'question' to ask a question, or 'review' to generate a code review. Omit or 'clarify' to just return context.", enum: ["plan", "question", "review", "clarify"]),
                    "export_response": .boolean(description: "When true, export the generated response to a file and return `oracle_export_path` plus `oracle_export_instruction`. Requires a response_type that generates a response. Include `oracle_export_path` inside the `message` you send on your next delegation call; the specific delegation tool is named by your system prompt.")
                ],
                required: []
            )
        ) { [dependencies] _, args in
            let connectionID = ServerNetworkManager.currentConnectionID
            let result = try await Self.executeContextBuilder(
                args: args,
                connectionID: connectionID,
                dependencies: dependencies
            )
            return result.toMCPValue()
        }
    }

    private static func executeContextBuilder(
        args: [String: Value],
        connectionID: UUID?,
        dependencies: MCPWindowToolDependencies
    ) async throws -> ContextBuilderToolResult {
        let instructions = args["instructions"]?.stringValue ?? ""
        let metadata = await dependencies.captureRequestMetadata()
        guard await dependencies.drainReadFileAutoSelection(metadata, .mirroredSelectionAndMetrics) == .completed else {
            throw CancellationError()
        }
        let responseType = try ContextBuilderResponseType.parse(from: args["response_type"])
        let exportResponse: Bool
        if let value = args["export_response"] {
            guard let boolValue = value.boolValue else {
                throw MCPError.invalidParams("export_response must be a boolean")
            }
            if boolValue, responseType?.wantsResponse != true {
                throw MCPError.invalidParams("export_response requires a response_type that generates a response (plan, question, or review).")
            }
            exportResponse = boolValue
        } else {
            exportResponse = false
        }

        let targetWindow = try dependencies.requireTargetWindow()
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace in this window. Use manage_workspaces action='list' to see available workspaces, then action='switch' to load one.")
        }
        let preferredAgent = targetWindow.promptManager.contextBuilderAgent
        let preferredModelRaw = targetWindow.promptManager.contextBuilderAgentModelRaw

        let tabResolution = try await dependencies.resolveContextBuilderTab(
            args,
            targetWindow,
            connectionID
        )
        let finalTabID = tabResolution.tabID

        if tabResolution.bindCaller, let connectionID {
            let clientName = await ServerNetworkManager.shared.clientIdentifier(forConnection: connectionID)
            try dependencies.bindTabForConnection(
                connectionID,
                clientName,
                finalTabID,
                tabResolution.workspaceID ?? workspace.id,
                targetWindow.windowID
            )
        }

        // swiftformat:disable conditionalAssignment
        let capturedOracleExportDestination: OracleExportDestination?
        if exportResponse {
            // Export into the exact root scope selected by Context Builder's final tab resolution.
            // Ambient request metadata may still describe a different active tab.
            capturedOracleExportDestination = try dependencies.makeOracleExportDestination(
                workspace,
                targetWindow.windowID,
                finalTabID,
                tabResolution.lookupContext
            )
        } else {
            capturedOracleExportDestination = nil
        }
        // swiftformat:enable conditionalAssignment

        let contextBuilderVM = targetWindow.contextBuilderAgentViewModel
        let tabIDForCleanup = finalTabID
        let mcpControlToken = try await MainActor.run {
            try contextBuilderVM.beginMCPControlledRun(
                forTabID: finalTabID,
                responseType: responseType?.rawValue,
                planModelName: nil
            )
        }

        return try await AsyncScope.withCleanup({}, cleanup: {
            await MainActor.run {
                contextBuilderVM.clearMCPControlledRun(
                    forTabID: tabIDForCleanup,
                    controlToken: mcpControlToken
                )
            }
        }) {
            let wantsResponse = responseType?.wantsResponse ?? false
            let contextBuilderTokenBudget = await MainActor.run {
                contextBuilderVM.resolvedMCPContextBuilderBudget(for: workspace.id, wantsResponse: wantsResponse)
            }
            let tokenBudgetOverride = contextBuilderTokenBudget
            let promptManager = targetWindow.promptManager

            let planModelName: String? = await wantsResponse ? MainActor.run {
                let settingsStore = GlobalSettingsStore.shared
                let useModelPresets = settingsStore.mcpShowModelPresets()
                let temporarilyDisabled = settingsStore.mcpTemporarilyDisablePresets()

                if !useModelPresets {
                    return promptManager.planningModel.displayName
                }

                let allPresets = ModelPresetsManager.shared.presets
                let effectivePresets = temporarilyDisabled ? [] : allPresets

                if effectivePresets.isEmpty {
                    return promptManager.planningModel.displayName
                }

                let modeFiltered = effectivePresets.filter { preset in
                    responseType?.supportsPresetMode(preset) ?? false
                }
                for preset in modeFiltered {
                    if promptManager.isModelAvailable(preset.model) {
                        return preset.model.displayName
                    }
                }
                return promptManager.planningModel.displayName
            } : nil

            let sendStageProgress = dependencies.sendStageProgress
            let progressTimeline = ContextBuilderMCPProgressTimeline { event in
                await sendStageProgress(
                    connectionID,
                    MCPWindowToolName.contextBuilder,
                    event.stage,
                    event.message
                )
            }
            let progressReporter: ContextBuilderMCPProgressReporter = { phase in
                await progressTimeline.transition(to: phase)
            }
            let activityReporter: ContextBuilderMCPActivityReporter = { phase, message in
                await progressTimeline.reportActivity(phase: phase, message: message)
            }

            func runContextBuilderAndPlan() async throws -> ContextBuilderToolResult {
                await dependencies.sendStageProgress(
                    connectionID,
                    MCPWindowToolName.contextBuilder,
                    "starting",
                    "Starting context builder..."
                )

                await dependencies.sendStageProgress(
                    connectionID,
                    MCPWindowToolName.contextBuilder,
                    "discovering",
                    "Running Context Builder agent..."
                )
                let snapshot = try await withTimelinePhaseCompletion(progressTimeline) {
                    try await withHeartbeat(
                        connectionID: connectionID,
                        tool: MCPWindowToolName.contextBuilder,
                        stage: "discovering",
                        message: "Still building context...",
                        timeline: progressTimeline
                    ) {
                        try await contextBuilderVM.runContextBuilderForMCP(
                            tabID: finalTabID,
                            instructionsOverride: instructions.isEmpty ? nil : instructions,
                            tokenBudgetOverride: tokenBudgetOverride,
                            persistTokenBudget: false,
                            enhancementModeOverride: .fullRewrite,
                            agentOverride: preferredAgent,
                            modelOverrideRaw: preferredModelRaw,
                            responseType: responseType?.rawValue,
                            planModelName: planModelName,
                            mcpControlToken: mcpControlToken,
                            progressReporter: progressReporter
                        )
                    }
                }

                await dependencies.sendStageProgress(
                    connectionID,
                    MCPWindowToolName.contextBuilder,
                    "discovered",
                    "Context Builder run complete, building selection..."
                )

                let resultTab = await MainActor.run {
                    snapshot.finalState ?? targetWindow.workspaceManager.composeTab(with: finalTabID)
                }
                guard let resultTab else {
                    throw MCPError.internalError("Tab state missing after Context Builder run")
                }

                let overrides = resultTab.contextOverrides
                let effectivePrompt = overrides.useOverridePrompt ? overrides.overridePromptText : resultTab.promptText

                let status = switch snapshot.runState {
                case .completed: "completed"
                case .cancelled: "cancelled"
                case let .failed(message): "failed: \(message)"
                default: "completed"
                }

                let sel = resultTab.selection
                let fileCount = sel.selectedPaths.count + sel.autoCodemapPaths.count

                let selectionReply = try await dependencies.buildTabSelectionReply(
                    sel,
                    false,
                    .relative,
                    .auto
                )
                let formattedSelection = ToolOutputFormatter.formatSelectionReplyToString(selectionReply)

                var planReply: ChatSendReply? = nil
                var reviewReply: ChatSendReply? = nil
                var followUpHint: String? = nil
                var oracleExportFile: OracleExportFile? = nil

                let mode = responseType?.headlessMode

                if let mode,
                   snapshot.runState == .completed,
                   !snapshot.usedAgentOutputAsPrompt,
                   !effectivePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    try Task.checkCancellation()

                    let modeLabel = responseType?.generationLabel ?? "question"
                    await dependencies.sendStageProgress(
                        connectionID,
                        MCPWindowToolName.contextBuilder,
                        "generating",
                        "Generating \(modeLabel)..."
                    )

                    let reply = try await withTimelinePhaseCompletion(progressTimeline) {
                        try await withHeartbeat(
                            connectionID: connectionID,
                            tool: MCPWindowToolName.contextBuilder,
                            stage: "generating",
                            message: "Still generating \(modeLabel)...",
                            timeline: progressTimeline
                        ) {
                            try await dependencies.runMCPPlanOrQuestion(
                                contextBuilderVM,
                                resultTab.id,
                                mode,
                                effectivePrompt,
                                sel,
                                progressReporter,
                                activityReporter
                            )
                        }
                    }

                    if mode == .review {
                        reviewReply = reply
                    } else {
                        planReply = reply
                    }
                    followUpHint = "Continue this \(modeLabel) conversation with ask_oracle(chat_id: \"\(reply.shortId)\", new_chat: false)"
                }

                await dependencies.sendStageProgress(
                    connectionID,
                    MCPWindowToolName.contextBuilder,
                    "complete",
                    "Context builder complete"
                )

                let normalizedTokens = selectionReply.totalTokens ?? 0
                let userTokens = selectionReply.userCopyTokens
                let userTotalTokens: Int?
                let tokenNote: String?
                if let ut = userTokens, ut != normalizedTokens {
                    userTotalTokens = ut
                    let codemapDelta = normalizedTokens - ut
                    tokenNote = "Difference: \(codemapDelta) codemap tokens (API signatures). Your preset excludes these, so exports use \(ut) file tokens, not \(normalizedTokens)."
                } else {
                    userTotalTokens = nil
                    tokenNote = nil
                }

                func makeResult(oracleExportPath: String?, oracleExportInstruction: String? = nil) -> ContextBuilderToolResult {
                    ContextBuilderToolResult(
                        tabID: resultTab.id.uuidString,
                        status: status,
                        prompt: effectivePrompt,
                        fileCount: fileCount,
                        totalTokens: normalizedTokens,
                        userTotalTokens: userTotalTokens,
                        tokenNote: tokenNote,
                        tokenBudget: contextBuilderTokenBudget,
                        promptMode: "rewrite",
                        agent: preferredAgent.rawValue,
                        selection: formattedSelection,
                        responseType: responseType?.rawValue,
                        plan: planReply,
                        review: reviewReply,
                        followUpHint: followUpHint,
                        oracleExportPath: oracleExportPath,
                        oracleExportInstruction: oracleExportInstruction
                    )
                }

                if exportResponse,
                   planReply != nil || reviewReply != nil
                {
                    let resultForExport = makeResult(oracleExportPath: nil)
                    let markdown = ToolOutputFormatter.formatDiscoverContext(value: resultForExport.toMCPValue())
                        .compactMap { block -> String? in
                            switch block {
                            case .text(text: let text, annotations: _, _meta: _):
                                return text
                            default:
                                return nil
                            }
                        }
                        .joined(separator: "\n")
                    let exportMode = responseType?.rawValue ?? planReply?.mode ?? reviewReply?.mode ?? "response"
                    let chatID = planReply?.shortId ?? reviewReply?.shortId
                    guard let capturedOracleExportDestination else {
                        throw MCPError.internalError("Missing captured Oracle export destination for context_builder export.")
                    }
                    let exportPath = try await dependencies.resolveDefaultOracleExportPath(
                        exportMode,
                        chatID,
                        capturedOracleExportDestination
                    )
                    let resolvedPath = try await dependencies.writeGeneratedOracleExportFile(
                        exportPath,
                        markdown,
                        capturedOracleExportDestination
                    )
                    oracleExportFile = OracleExportFile(
                        path: resolvedPath,
                        instruction: AgentOracleExport.instruction(path: resolvedPath)
                    )
                }

                return makeResult(
                    oracleExportPath: oracleExportFile?.path,
                    oracleExportInstruction: oracleExportFile?.instruction
                )
            }
            return try await runContextBuilderAndPlan()
        }
    }

    private static func withHeartbeat<T: Sendable>(
        connectionID: UUID?,
        tool: String,
        stage: String,
        message: String,
        timeline: ContextBuilderMCPProgressTimeline? = nil,
        interval: Duration = .seconds(30),
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let connectionID else {
            return try await operation()
        }
        let shouldSendProgress = await ServerNetworkManager.shared.supportsControlNotifications(connectionID: connectionID)
        guard shouldSendProgress else {
            return try await operation()
        }

        let heartbeatTask = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: interval)
                    try Task.checkCancellation()
                    let heartbeat: (stage: String, message: String) = if let timeline {
                        await timeline.heartbeat(
                            fallbackStage: stage,
                            fallbackMessage: message
                        )
                    } else {
                        (stage, message)
                    }
                    await ServerNetworkManager.shared.sendProgress(
                        for: connectionID,
                        tool: tool,
                        kind: .heartbeat,
                        stage: heartbeat.stage,
                        message: heartbeat.message
                    )
                }
            } catch {
                // Cancellation is the expected completion path.
            }
        }
        defer { heartbeatTask.cancel() }
        return try await operation()
    }

    private static func withTimelinePhaseCompletion<T: Sendable>(
        _ timeline: ContextBuilderMCPProgressTimeline,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            let result = try await operation()
            await timeline.finishCurrentPhase()
            await timeline.flush()
            return result
        } catch {
            await timeline.finishCurrentPhase()
            await timeline.flush()
            throw error
        }
    }
}
