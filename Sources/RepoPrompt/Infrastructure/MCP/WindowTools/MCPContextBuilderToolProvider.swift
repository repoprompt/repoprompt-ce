import Foundation
import JSONSchema
import MCP
import Ontology

/// Carries existing non-Sendable UI snapshot/DTO values through the provider's @Sendable timeline
/// wrappers without broadening their conformances. Each operation stores once and is fully awaited
/// before the owning task loads once; the lock makes that narrow handoff explicit and race-safe.
private final class ContextBuilderTimelinePhaseValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func store(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

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
    let model: String?
    let planningModel: String?
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
        case agent, model
        case planningModel = "planning_model"
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
        if let model {
            obj["model"] = .string(model)
        }
        if let planningModel {
            obj["planning_model"] = .string(planningModel)
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

enum ContextBuilderResponseDisposition {
    case contextOnly
    case generate(HeadlessMode, prompt: String)
    case failed(String)
}

/// Typed-prompt resolution outcome for a completed Context Builder run. `resolved` carries the prompt
/// handed to the follow-up model; each failure case names a distinct reason the provider can report
/// safely, without echoing withheld caller instructions or discovery-guideline content.
enum ContextBuilderTypedPromptResolution: Equatable {
    case resolved(String)
    /// The request carried no caller task or context and no reusable committed prompt existed.
    case missingCallerTask
    /// Caller instructions consisted only of discovery guidelines, which are withheld from the follow-up model.
    case discoveryGuidelinesOnly
    /// Caller instructions used unsupported or malformed discovery-guideline markup, so resolution failed closed.
    case malformedDiscoveryMarkup
    /// Only copied discovery output was committed and no independent caller task exists to answer.
    case onlyCopiedDiscoveryOutput
}

enum ContextBuilderTypedPromptResolver {
    private static let openingTag = "<discovery_agent-guidelines>"
    private static let closingTag = "</discovery_agent-guidelines>"
    private static let reservedName = "discovery_agent-guidelines"

    /// Outcome of stripping reserved discovery-guideline markup from caller instructions. The empty and
    /// guidelines-only cases are kept distinct so resolution can tell "caller supplied nothing" apart from
    /// "caller supplied only withheld guidelines" without re-parsing.
    private enum SanitizedCallerInstructions {
        case prompt(String)
        case empty
        case onlyGuidelines
        case malformed
    }

    static func resolve(
        effectivePrompt: String,
        usedAgentOutputAsPrompt: Bool,
        callerInstructions: String
    ) -> ContextBuilderTypedPromptResolution {
        if !usedAgentOutputAsPrompt,
           !effectivePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .resolved(effectivePrompt)
        }
        switch sanitizeCallerInstructions(callerInstructions) {
        case let .prompt(prompt):
            return .resolved(prompt)
        case .malformed:
            return .malformedDiscoveryMarkup
        case .onlyGuidelines:
            return .discoveryGuidelinesOnly
        case .empty:
            // A committed prompt flagged as copied discovery output is deliberately not reused, so an empty
            // caller fallback means only that copied output exists; otherwise no caller task was provided at all.
            return usedAgentOutputAsPrompt ? .onlyCopiedDiscoveryOutput : .missingCallerTask
        }
    }

    private static func sanitizeCallerInstructions(_ instructions: String) -> SanitizedCallerInstructions {
        var sanitized = ""
        var cursor = instructions.startIndex
        var insideGuidelines = false
        var removedGuidelines = false

        while cursor < instructions.endIndex {
            guard instructions[cursor] == "<" else {
                if !insideGuidelines {
                    sanitized.append(instructions[cursor])
                }
                cursor = instructions.index(after: cursor)
                continue
            }

            guard let closingAngle = closingAngleIndex(in: instructions, after: cursor) else {
                let remainder = instructions[cursor...]
                guard remainder.range(of: reservedName, options: .caseInsensitive) == nil else {
                    return .malformed
                }
                if !insideGuidelines {
                    sanitized.append(contentsOf: remainder)
                }
                break
            }

            let afterTag = instructions.index(after: closingAngle)
            let tag = instructions[cursor ..< afterTag]
            if tag == openingTag {
                guard !insideGuidelines else { return .malformed }
                insideGuidelines = true
                removedGuidelines = true
            } else if tag == closingTag {
                guard insideGuidelines else { return .malformed }
                insideGuidelines = false
            } else {
                // Quote-aware tokenization keeps reserved markup inside attributes from becoming removable blocks.
                guard tag.range(of: reservedName, options: .caseInsensitive) == nil else {
                    return .malformed
                }
                if !insideGuidelines {
                    sanitized.append(contentsOf: tag)
                }
            }
            cursor = afterTag
        }

        guard !insideGuidelines else { return .malformed }
        let result = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.isEmpty {
            return .prompt(result)
        }
        return removedGuidelines ? .onlyGuidelines : .empty
    }

    private static func closingAngleIndex(
        in instructions: String,
        after openingAngle: String.Index
    ) -> String.Index? {
        var cursor = instructions.index(after: openingAngle)
        var activeQuote: Character?

        while cursor < instructions.endIndex {
            let character = instructions[cursor]
            if let quote = activeQuote {
                if character == quote {
                    activeQuote = nil
                }
            } else if character == "\"" || character == "'" {
                activeQuote = character
            } else if character == ">" {
                return cursor
            }
            cursor = instructions.index(after: cursor)
        }
        return nil
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
        let tabResolution = try await dependencies.resolveContextBuilderTab(
            args,
            targetWindow,
            connectionID
        )
        let resolvedIdentity = tabResolution.identity
        let finalTabID = resolvedIdentity.tabID
        guard let workspace = targetWindow.workspaceManager.workspaces.first(where: { $0.id == resolvedIdentity.workspaceID }) else {
            throw MCPError.invalidParams("The resolved Context Builder workspace is no longer available.")
        }
        let workspaceContext = tabResolution.workspaceContext
        let lookupContext = workspaceContext?.lookupContext ?? tabResolution.lookupContext
        if workspaceContext == nil {
            let scopedRoots = await dependencies.promptVM.workspaceFileContextStore.rootRefs(
                scope: lookupContext.rootScope
            )
            let scopedPaths = Set(scopedRoots.map(\.standardizedFullPath))
            let targetPaths = Set(workspace.repoPaths.map {
                StandardizedPath.absolute(lookupContext.translateInputPath($0))
            })
            guard !targetPaths.isEmpty, targetPaths.isSubset(of: scopedPaths) else {
                throw MCPError.invalidParams(
                    "The resolved Context Builder workspace projection is unavailable. Reload the target workspace before retrying."
                )
            }
        }
        guard let initialResultTab = targetWindow.workspaceManager.composeTab(for: resolvedIdentity) else {
            throw MCPError.internalError("Resolved Context Builder tab is unavailable in its workspace")
        }
        try await workspaceContext?.validateReviewTargetAvailability(
            store: dependencies.promptVM.workspaceFileContextStore
        )
        let contextBuilderVM = targetWindow.contextBuilderAgentViewModel

        if tabResolution.bindCaller, let connectionID {
            let clientName = await ServerNetworkManager.shared.clientIdentifier(forConnection: connectionID)
            try dependencies.bindTabForConnection(
                connectionID,
                clientName,
                finalTabID,
                resolvedIdentity.workspaceID,
                targetWindow.windowID
            )
        }

        let targetMetadata = MCPServerViewModel.RequestMetadata(
            connectionID: connectionID ?? metadata.connectionID,
            clientName: metadata.clientName,
            windowID: targetWindow.windowID,
            runPurpose: metadata.runPurpose,
            tabContextHint: MCPServerViewModel.TabContextHint(
                tabID: resolvedIdentity.tabID,
                workspaceID: resolvedIdentity.workspaceID,
                windowID: targetWindow.windowID
            ),
            explicitWindowRoutingHint: metadata.explicitWindowRoutingHint
        )
        guard await dependencies.drainReadFileAutoSelection(
            targetMetadata,
            .mirroredSelectionAndMetrics
        ) == .completed else {
            throw CancellationError()
        }
        let runAuthority = try await contextBuilderVM.resolveMCPRunAuthority(
            identity: resolvedIdentity,
            nestedTabContext: tabResolution.nestedTabContext,
            workspaceContext: workspaceContext,
            responseType: responseType?.rawValue
        )

        // swiftformat:disable conditionalAssignment
        let capturedOracleExportDestination: OracleExportDestination?
        if exportResponse {
            // Export into the exact root scope selected by Context Builder's final tab resolution.
            // Ambient request metadata may still describe a different active tab.
            capturedOracleExportDestination = try dependencies.makeOracleExportDestination(
                workspace,
                targetWindow.windowID,
                finalTabID,
                lookupContext
            )
        } else {
            capturedOracleExportDestination = nil
        }
        // swiftformat:enable conditionalAssignment

        let tabIDForCleanup = finalTabID
        let mcpControlToken = try await MainActor.run {
            try contextBuilderVM.beginMCPControlledRun(
                forTabID: finalTabID,
                workspaceID: resolvedIdentity.workspaceID,
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
            let contextBuilderTokenBudget = runAuthority.configuration.effectiveTokenBudget
            let promptManager = targetWindow.promptManager

            let planModelName: String? = await wantsResponse ? MainActor.run {
                let settingsStore = GlobalSettingsStore.shared
                let useModelPresets = settingsStore.mcpShowModelPresets()
                let temporarilyDisabled = settingsStore.mcpTemporarilyDisablePresets()

                if !useModelPresets {
                    return runAuthority.configuration.planningModelRaw
                        .flatMap(AIModel.fromModelName)?.displayName
                }

                let allPresets = ModelPresetsManager.shared.presets
                let effectivePresets = temporarilyDisabled ? [] : allPresets

                if effectivePresets.isEmpty {
                    return runAuthority.configuration.planningModelRaw
                        .flatMap(AIModel.fromModelName)?.displayName
                }

                let modeFiltered = effectivePresets.filter { preset in
                    responseType?.supportsPresetMode(preset) ?? false
                }
                for preset in modeFiltered {
                    if promptManager.isModelAvailable(preset.model) {
                        return preset.model.displayName
                    }
                }
                return runAuthority.configuration.planningModelRaw
                    .flatMap(AIModel.fromModelName)?.displayName
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
                            authority: runAuthority,
                            instructionsOverride: instructions.isEmpty ? nil : instructions,
                            planModelName: planModelName,
                            workspaceContext: workspaceContext,
                            mcpControlToken: mcpControlToken,
                            progressReporter: progressReporter,
                            activityReporter: activityReporter
                        )
                    }
                }

                await dependencies.sendStageProgress(
                    connectionID,
                    MCPWindowToolName.contextBuilder,
                    "discovered",
                    "Context Builder run complete, building selection..."
                )

                await progressTimeline.transition(to: .selectionReplyRendering)
                let renderedSelection = ContextBuilderTimelinePhaseValue<(
                    resultTab: ComposeTabState,
                    effectivePrompt: String,
                    status: String,
                    selection: StoredSelection,
                    fileCount: Int,
                    reply: ToolResultDTOs.SelectionReply,
                    formatted: String
                )>()
                try await withTimelinePhaseCompletion(progressTimeline) {
                    try await withHeartbeat(
                        connectionID: connectionID,
                        tool: MCPWindowToolName.contextBuilder,
                        stage: "processing",
                        message: "Still rendering Context Builder selection...",
                        timeline: progressTimeline
                    ) {
                        let committedResultTab: ComposeTabState?
                        if let committedTab = snapshot.committedTab {
                            guard committedTab.nestedRunID == snapshot.runID,
                                  committedTab.identity == resolvedIdentity,
                                  committedTab.tab.id == finalTabID
                            else {
                                throw MCPError.internalError(
                                    "Context Builder committed tab identity does not match the completed run"
                                )
                            }
                            if snapshot.terminalDisposition == .completed {
                                let canonicalState = await MainActor.run { () -> (ComposeTabState?, UInt64) in
                                    let manager = targetWindow.workspaceManager
                                    return (
                                        manager.composeTab(for: committedTab.identity),
                                        manager.selectionRevisionForMCP(
                                            workspaceID: committedTab.identity.workspaceID,
                                            tabID: committedTab.identity.tabID
                                        )
                                    )
                                }
                                let committedSnapshotIsCurrent: Bool = if responseType == .review {
                                    canonicalState.1 == committedTab.selectionRevision
                                        && canonicalState.0?.selection == committedTab.tab.selection
                                } else {
                                    canonicalState.1 >= committedTab.selectionRevision
                                        && (
                                            canonicalState.1 != committedTab.selectionRevision
                                                || canonicalState.0?.selection == committedTab.tab.selection
                                        )
                                }
                                guard committedSnapshotIsCurrent else {
                                    throw MCPError.internalError(
                                        "Context Builder committed tab snapshot is no longer valid"
                                    )
                                }
                            }
                            committedResultTab = committedTab.tab
                        } else {
                            committedResultTab = nil
                        }

                        let resultTab: ComposeTabState
                        switch snapshot.terminalDisposition {
                        case .completed:
                            guard let committedResultTab else {
                                throw MCPError.internalError(
                                    "Context Builder completed without an exact committed tab snapshot"
                                )
                            }
                            resultTab = committedResultTab
                        case .cancelled, .failed:
                            // Cancellation or failure after a successful commit must report the exact
                            // committed prompt and selection. Pre-commit outcomes retain the immutable
                            // initial tab instead of consulting mutable active-tab state.
                            resultTab = committedResultTab ?? initialResultTab
                        }

                        let overrides = resultTab.contextOverrides
                        let effectivePrompt = overrides.useOverridePrompt
                            ? overrides.overridePromptText
                            : resultTab.promptText
                        let status = switch snapshot.terminalDisposition {
                        case .completed: "completed"
                        case .cancelled: "cancelled"
                        case let .failed(message): "failed: \(message)"
                        }

                        try workspaceContext?.validateAvailability()
                        let selection = resultTab.selection
                        let reply = try await dependencies.buildTabSelectionReply(
                            selection,
                            false,
                            .relative,
                            .auto,
                            lookupContext,
                            tabResolution.reviewGitContext
                        )
                        renderedSelection.store((
                            resultTab: resultTab,
                            effectivePrompt: effectivePrompt,
                            status: status,
                            selection: selection,
                            fileCount: selection.selectedPaths.count,
                            reply: reply,
                            formatted: ToolOutputFormatter.formatSelectionReplyToString(reply)
                        ))
                    }
                }
                guard let renderedSelection = renderedSelection.load() else {
                    throw MCPError.internalError(
                        "Context Builder selection reply rendering completed without a result"
                    )
                }
                let resultTab = renderedSelection.resultTab
                let effectivePrompt = renderedSelection.effectivePrompt
                let status = renderedSelection.status
                let sel = renderedSelection.selection
                let fileCount = renderedSelection.fileCount
                let selectionReply = renderedSelection.reply
                let formattedSelection = renderedSelection.formatted

                var planReply: ChatSendReply? = nil
                var reviewReply: ChatSendReply? = nil
                var followUpHint: String? = nil
                var oracleExportFile: OracleExportFile? = nil

                let responseDisposition = Self.responseDisposition(
                    responseType: responseType,
                    terminalDisposition: snapshot.terminalDisposition,
                    usedAgentOutputAsPrompt: snapshot.usedAgentOutputAsPrompt,
                    effectivePrompt: effectivePrompt,
                    callerInstructions: instructions
                )
                var resultPrompt = effectivePrompt

                switch responseDisposition {
                case .contextOnly:
                    break
                case let .failed(message):
                    throw MCPError.internalError(message)
                case let .generate(mode, prompt):
                    resultPrompt = prompt
                    try Task.checkCancellation()
                    let finalReviewAuthorization: ContextBuilderFinalReviewAuthorization?
                    if mode == .review, let workspaceContext {
                        guard case .completed = snapshot.terminalDisposition,
                              let committedTab = snapshot.committedTab
                        else {
                            throw MCPError.internalError(
                                "Context Builder review requires an exact completed selection snapshot"
                            )
                        }

                        await progressTimeline.transition(to: .reviewSelectionAuthorization)
                        let retainedAuthorization =
                            ContextBuilderTimelinePhaseValue<ContextBuilderFinalReviewAuthorization>()
                        try await withTimelinePhaseCompletion(progressTimeline) {
                            try await withHeartbeat(
                                connectionID: connectionID,
                                tool: MCPWindowToolName.contextBuilder,
                                stage: "generating",
                                message: "Still authorizing Context Builder review selection...",
                                timeline: progressTimeline
                            ) {
                                await dependencies.beforeContextBuilderFinalReviewAuthorization()
                                let preAuthorizationCanonical = await MainActor.run {
                                    () -> (ComposeTabState?, UInt64) in
                                    let manager = targetWindow.workspaceManager
                                    return (
                                        manager.composeTab(for: committedTab.identity),
                                        manager.selectionRevisionForMCP(
                                            workspaceID: committedTab.identity.workspaceID,
                                            tabID: committedTab.identity.tabID
                                        )
                                    )
                                }
                                guard preAuthorizationCanonical.1 == committedTab.selectionRevision,
                                      preAuthorizationCanonical.0?.selection == sel
                                else {
                                    throw MCPError.invalidParams(
                                        "Context Builder review selection changed before final repository authorization."
                                    )
                                }

                                let authorization = try await workspaceContext.authorizeFinalReviewSelection(
                                    sel,
                                    workspaceID: committedTab.identity.workspaceID,
                                    tabID: committedTab.identity.tabID,
                                    selectionRevision: committedTab.selectionRevision,
                                    store: dependencies.promptVM.workspaceFileContextStore
                                )
                                await dependencies.didFinalizeContextBuilderReview(authorization)

                                let finalCanonical = await MainActor.run {
                                    () -> (ComposeTabState?, UInt64) in
                                    let manager = targetWindow.workspaceManager
                                    return (
                                        manager.composeTab(for: committedTab.identity),
                                        manager.selectionRevisionForMCP(
                                            workspaceID: committedTab.identity.workspaceID,
                                            tabID: committedTab.identity.tabID
                                        )
                                    )
                                }
                                guard finalCanonical.1 == committedTab.selectionRevision,
                                      finalCanonical.0?.selection == sel
                                else {
                                    throw MCPError.invalidParams(
                                        "Context Builder review selection changed after final repository authorization."
                                    )
                                }
                                retainedAuthorization.store(authorization)
                            }
                        }
                        guard let authorization = retainedAuthorization.load() else {
                            throw MCPError.internalError(
                                "Context Builder review authorization completed without retained authority"
                            )
                        }
                        finalReviewAuthorization = authorization
                    } else {
                        finalReviewAuthorization = nil
                    }

                    if mode == .review, workspaceContext != nil, finalReviewAuthorization == nil {
                        throw MCPError.internalError(
                            "Context Builder review final authorization was not retained"
                        )
                    }

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
                                resolvedIdentity,
                                tabResolution.agentModeSessionID,
                                tabResolution.agentModeRunID,
                                mode,
                                prompt,
                                sel,
                                lookupContext,
                                tabResolution.reviewGitContext,
                                finalReviewAuthorization,
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
                        prompt: resultPrompt,
                        fileCount: fileCount,
                        totalTokens: normalizedTokens,
                        userTotalTokens: userTotalTokens,
                        tokenNote: tokenNote,
                        tokenBudget: contextBuilderTokenBudget,
                        promptMode: "rewrite",
                        agent: snapshot.agentKind?.rawValue ?? runAuthority.agentKind.rawValue,
                        model: snapshot.modelRaw ?? runAuthority.modelRaw,
                        planningModel: planModelName,
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

    nonisolated static func responseDisposition(
        responseType: ContextBuilderResponseType?,
        terminalDisposition: ContextBuilderRunTerminalOutcome,
        usedAgentOutputAsPrompt: Bool,
        effectivePrompt: String,
        callerInstructions: String
    ) -> ContextBuilderResponseDisposition {
        guard responseType?.wantsResponse == true else { return .contextOnly }

        switch terminalDisposition {
        case .cancelled, .failed:
            return .contextOnly
        case .completed:
            let prompt: String
            switch ContextBuilderTypedPromptResolver.resolve(
                effectivePrompt: effectivePrompt,
                usedAgentOutputAsPrompt: usedAgentOutputAsPrompt,
                callerInstructions: callerInstructions
            ) {
            case let .resolved(resolvedPrompt):
                prompt = resolvedPrompt
            case .missingCallerTask:
                return .failed(typedPromptFailure(
                    responseType,
                    reason: "the request included no caller task or context to answer"
                ))
            case .onlyCopiedDiscoveryOutput:
                return .failed(typedPromptFailure(
                    responseType,
                    reason: "only copied discovery output is available and no independent caller task was provided"
                ))
            case .discoveryGuidelinesOnly:
                return .failed(typedPromptFailure(
                    responseType,
                    reason: "the caller instructions contained only discovery guidelines, which are withheld from the follow-up model"
                ))
            case .malformedDiscoveryMarkup:
                return .failed(typedPromptFailure(
                    responseType,
                    reason: "the caller instructions used unsupported or malformed discovery-guideline markup"
                ))
            }
            guard let mode = responseType?.headlessMode else {
                return .failed("Context Builder requested response mode is unavailable")
            }
            return .generate(mode, prompt: prompt)
        }
    }

    /// Composes a safe typed-prompt failure message. `reason` names why resolution failed without echoing
    /// withheld caller instructions or discovery-guideline content; "without a prompt" stays the stable stem.
    private nonisolated static func typedPromptFailure(
        _ responseType: ContextBuilderResponseType?,
        reason: String
    ) -> String {
        "Context Builder completed without a prompt for the requested \(responseType?.rawValue ?? "response"): \(reason)"
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
        let shouldSendProgress = await ServerNetworkManager.shared.supportsProgressNotifications(connectionID: connectionID)
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
