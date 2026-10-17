import Foundation
import JSONSchema
import MCP
import Ontology
import RepoPromptDomainRuntime
import RepoPromptFoundation
import RepoPromptWorkspaceCore

/// An unsatisfied prerequisite rejects discovery without rolling back earlier selection or binding effects.
enum MCPContextBuilderSelectionPrerequisiteError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case deferred
    case invalidated

    var description: String {
        switch self {
        case .deferred:
            "context_builder_selection_prerequisite_deferred: Context Builder discovery was not started because its selection prerequisite was deferred."
        case .invalidated:
            "context_builder_selection_prerequisite_invalidated: Context Builder discovery was not started because its selection prerequisite was invalidated."
        }
    }

    var errorDescription: String? {
        description
    }
}

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
    let oracleExportError: String?

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
        case oracleExportError = "oracle_export_error"
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
        if let oracleExportError {
            obj["oracle_export_error"] = .string(oracleExportError)
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
final class MCPContextBuilderToolProvider: MCPAppToolProviding {
    let group: MCPAppToolGroup = .contextBuilder

    private let runtime: MCPAppToolBinder
    private typealias Dependencies = (
        execution: MCPAppPhysicalCapabilityAdapters.Execution,
        context: MCPAppPhysicalCapabilityAdapters.Context,
        files: MCPAppPhysicalCapabilityAdapters.Files,
        jobs: MCPLongRunningJobCenter,
        registerJob: (UUID, UUID?, @escaping () -> Void) -> Void,
        unregisterJob: (UUID) -> Void
    )

    private let dependencies: Dependencies

    init(runtime: MCPAppToolBinder, execution: MCPAppPhysicalCapabilityAdapters.Execution, context: MCPAppPhysicalCapabilityAdapters.Context, files: MCPAppPhysicalCapabilityAdapters.Files, jobs: MCPLongRunningJobCenter, registerJob: @escaping (UUID, UUID?, @escaping () -> Void) -> Void, unregisterJob: @escaping (UUID) -> Void) {
        self.runtime = runtime
        dependencies = (execution: execution, context: context, files: files, jobs: jobs, registerJob: registerJob, unregisterJob: unregisterJob)
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

            **Oracle preset**: For app-backed `plan`, `question`, or `review` runs, pass `oracle_preset` to select an exposed Model Preset by name or UUID. The preset determines the complete ordered Oracle roster and request prompt; it is separate from the Context Builder discovery `agent` and `model`. Omit it to use automatic Model Preset selection. Direct-headless execution rejects this app-only argument.

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
                    "op": .string(description: MCPLongRunningJobToolContract.operationDescription, enum: ["start", "poll", "wait", "cancel"]),
                    "job_id": .string(description: MCPLongRunningJobToolContract.jobIDDescription),
                    "detach": .boolean(description: MCPLongRunningJobToolContract.detachDescription),
                    "timeout": .number(description: MCPLongRunningJobToolContract.timeoutDescription),
                    "instructions": .string(description: "Your request, ideally structured with XML tags: <task> for the main goal, <context> for background/constraints/file references, <discovery_agent-guidelines> for optional starting hints. Describe what you need — the agent finds the right files."),
                    "response_type": .string(description: "Optional: 'plan' to generate implementation plan, 'question' to ask a question, or 'review' to generate a code review. Omit or 'clarify' to just return context.", enum: ["plan", "question", "review", "clarify"]),
                    "oracle_preset": .string(
                        description: "App-backed only: exposed Model Preset name or UUID for a plan, question, or review response. This selects the Oracle roster and prompt independently of the discovery model.",
                        minLength: 1,
                        maxLength: OracleRosterContract.maximumModelIdentifierLength
                    ),
                    "context_pack_ref": .string(description: "Direct-headless only: canonical oracle-pack:sha256 reference to an already persisted frozen Context Builder package. Mutually exclusive with instructions."),
                    "export_response": .boolean(description: "When true, export the generated response to a file and return `oracle_export_path` plus `oracle_export_instruction`. Requires a response_type that generates a response. Include `oracle_export_path` inside the `message` you send on your next delegation call; the specific delegation tool is named by your system prompt.")
                ],
                required: []
            )
        ) { [dependencies] invocation, args in
            let invocationContext = invocation.context
            do {
                return try await Self.executeContextBuilder(
                    args: args,
                    invocationContext: invocationContext,
                    dependencies: dependencies
                )
            } catch let error as ContextBuilderWorkspaceContextError {
                throw MCPError.invalidParams(error.localizedDescription)
            }
        }
    }

    nonisolated static func parseOraclePreset(
        _ value: Value?,
        responseType: ContextBuilderResponseType?
    ) throws -> String? {
        guard let value else { return nil }
        guard let stringValue = value.stringValue else {
            throw MCPError.invalidParams("oracle_preset must be a string")
        }
        let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidParams("oracle_preset cannot be blank")
        }
        guard trimmed.count <= OracleRosterContract.maximumModelIdentifierLength else {
            throw MCPError.invalidParams(
                "oracle_preset cannot exceed \(OracleRosterContract.maximumModelIdentifierLength) characters"
            )
        }
        guard responseType?.wantsResponse == true else {
            throw MCPError.invalidParams(
                "oracle_preset requires response_type plan, question, or review."
            )
        }
        return trimmed
    }

    private struct PreparedContextBuilderRun {
        let instructions: String
        let invocationContext: ToolInvocationContext
        let targetWindow: WindowState
        let tabResolution: MCPAppPhysicalCapabilityAdapters.ContextBuilderTabResolution
        let initialResultTab: ComposeTabState
        let responseType: ContextBuilderResponseType?
        let exportResponse: Bool
        let runAuthority: ContextBuilderResolvedRunAuthority
        let exportDestination: OracleExportDestination?
        let controlToken: UUID

        var owner: MCPLongRunningJobCenter.Owner {
            .init(windowID: targetWindow.windowID, workspaceID: tabResolution.identity.workspaceID, tabID: tabResolution.identity.tabID, sessionID: tabResolution.agentModeSessionID, runID: tabResolution.agentModeRunID)
        }

        @MainActor func abandon() {
            targetWindow.contextBuilderAgentViewModel.clearMCPControlledRun(forTabID: tabResolution.identity.tabID, controlToken: controlToken)
        }
    }

    private static func executeContextBuilder(args: [String: Value], invocationContext: ToolInvocationContext, dependencies: Dependencies) async throws -> Value {
        guard args["debug_primary_only"] == nil, args["debug_lane_timeout_seconds"] == nil else {
            throw MCPError.invalidParams("Context Builder does not support Oracle request diagnostics")
        }
        // Routing selectors are validated against the resolved context below, not job controls.
        let operation = try MCPLongRunningJobOperation.parse(args.filter { $0.key != "context_id" })
        if operation.id != nil {
            return try await dependencies.jobs.control(operation: operation, tool: MCPWindowToolName.contextBuilder) { owner in
                let context = try await dependencies.execution.requireCurrentTabContext(MCPWindowToolName.contextBuilder)
                let window = try dependencies.execution.requireTargetWindow()
                guard window.windowID == owner.windowID, context.workspaceID == owner.workspaceID, context.tabID == owner.tabID else {
                    throw MCPError.invalidParams("job_id belongs to a different workspace/context; bind the context_id from its start snapshot")
                }
                let purpose = if let connection = invocationContext.connectionID { await dependencies.execution.liveRunPurpose(connection) } else { MCPRunPurpose.unknown }
                for key in ["context_id", "_tabID"] {
                    guard let selector = args[key] else { continue }
                    guard purpose != .agentModeRun else {
                        throw MCPError.invalidParams("Agent Mode context_builder cannot replace the invoking run-scoped tab context with an explicit context_id")
                    }
                    guard let raw = selector.stringValue, let id = UUID(uuidString: raw), id == context.tabID else {
                        throw MCPError.invalidParams("\(key) must identify the job's bound tab context")
                    }
                }
                if purpose == .agentModeRun, context.activeAgentSessionID == nil || context.runID == nil {
                    throw MCPError.invalidParams("Ticket controls require the active Agent session/run context")
                }
                guard owner.sessionID == (purpose == .agentModeRun ? context.activeAgentSessionID : nil), owner.runID == (purpose == .agentModeRun ? context.runID : nil) else {
                    throw MCPError.invalidParams("job_id belongs to a different Agent session/run")
                }
            }
        }
        let ticketed = if case .start = operation { true } else { false }
        let executionArgs = MCPLongRunningJobOperation.executionArgs(args)
        if ticketed, !executionArgs.keys.allSatisfy({ $0.hasPrefix("_") || ["instructions", "response_type", "oracle_preset", "context_pack_ref", "export_response", "context_id"].contains($0) }) {
            throw MCPError.invalidParams("context_builder start accepts only instructions, response_type, oracle_preset, context_pack_ref, export_response, context_id")
        }
        #if DEBUG
            let window = try dependencies.execution.requireTargetWindow()
            let binding = invocationContext.connectionID.map { window.mcpServer.connectionBindingSnapshot(forConnection: $0) }
            let observation = window.contextBuilderAgentViewModel.startupObservationForTesting(workspaceID: binding?.workspaceID, tabID: binding?.tabID, invokingRunID: binding?.runID)
            defer { observation?.recordRequestTerminal() }
        #endif
        let prepared = try await prepareContextBuilderRun(args: executionArgs, invocationContext: invocationContext, dependencies: dependencies, ticketed: ticketed)
        guard case let .start(detach, timeout) = operation else {
            return try await performContextBuilderRun(prepared, dependencies: dependencies).toMCPValue()
        }
        let snapshot = try await dependencies.jobs.start(tool: MCPWindowToolName.contextBuilder, owner: prepared.owner, admissible: {
            // Tab close sweeps only admitting/registered jobs; reject a tab removed during preparation.
            guard prepared.targetWindow.workspaceManager.composeTab(for: prepared.tabResolution.identity) != nil else {
                throw MCPError.invalidRequest("Tab context '\(prepared.tabResolution.identity.tabID.uuidString)' was closed before the job was admitted")
            }
        }, register: { id, cancel in
            dependencies.registerJob(id, prepared.owner.runID, cancel)
        }, unregister: dependencies.unregisterJob, onNotStarted: { prepared.abandon() }) { progress in
            try await performContextBuilderRun(prepared, dependencies: dependencies, jobProgress: progress).toMCPValue()
        }
        if detach { return snapshot.value() }
        return await dependencies.jobs.store.wait(id: snapshot.id, timeout: timeout)?.value() ?? MCPLongRunningJobCenter.expired(id: snapshot.id)
    }

    private static func prepareContextBuilderRun(
        args: [String: Value],
        invocationContext: ToolInvocationContext,
        dependencies: Dependencies,
        ticketed: Bool
    ) async throws -> PreparedContextBuilderRun {
        guard args["context_pack_ref"] == nil else {
            throw MCPError.invalidParams(
                "context_pack_ref is accepted only by the direct-headless Context Builder adapter."
            )
        }
        let instructions = args["instructions"]?.stringValue ?? ""
        let metadata = invocationContext.metadata
        let connectionID = invocationContext.connectionID
        let responseType = try ContextBuilderResponseType.parse(from: args["response_type"])
        let oraclePreset = try parseOraclePreset(args["oracle_preset"], responseType: responseType)
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

        let targetWindow = try dependencies.execution.requireTargetWindow()
        let tabResolution = try await dependencies.execution.resolveContextBuilderTab(
            args,
            targetWindow,
            connectionID
        )
        let resolvedIdentity = tabResolution.identity
        if ticketed {
            let purpose = if let connectionID { await dependencies.execution.liveRunPurpose(connectionID) } else { MCPRunPurpose.unknown }
            if purpose == .agentModeRun, tabResolution.agentModeSessionID == nil || tabResolution.agentModeRunID == nil {
                throw MCPError.invalidParams("Ticket admission requires the active Agent session/run context")
            }
            let owner = MCPLongRunningJobCenter.Owner(windowID: targetWindow.windowID, workspaceID: resolvedIdentity.workspaceID, tabID: resolvedIdentity.tabID, sessionID: tabResolution.agentModeSessionID, runID: tabResolution.agentModeRunID)
            try await dependencies.jobs.store.checkAdmission(owner: owner)
        }
        let finalTabID = resolvedIdentity.tabID
        guard let workspace = targetWindow.workspaceManager.workspaces.first(where: { $0.id == resolvedIdentity.workspaceID }) else {
            throw MCPError.invalidParams("The resolved Context Builder workspace is no longer available.")
        }
        let workspaceContext = tabResolution.workspaceContext
        let lookupContext = workspaceContext?.lookupContext ?? tabResolution.lookupContext
        if workspaceContext == nil {
            let scopedRoots = await dependencies.context.promptVM.workspaceFileContextStore.rootRefs(
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
            store: dependencies.context.promptVM.workspaceFileContextStore
        )
        let contextBuilderVM = targetWindow.contextBuilderAgentViewModel

        if tabResolution.bindCaller, let connectionID {
            let clientName = metadata.clientName
            try dependencies.execution.bindTabForConnection(
                connectionID,
                clientName,
                finalTabID,
                resolvedIdentity.workspaceID,
                targetWindow.windowID
            )
        }

        let targetMetadata = MCPRequestMetadata(
            connectionID: connectionID ?? metadata.connectionID,
            clientName: metadata.clientName,
            windowID: targetWindow.windowID,
            runPurpose: metadata.runPurpose,
            tabContextHint: MCPTabContextHint(
                tabID: resolvedIdentity.tabID,
                workspaceID: resolvedIdentity.workspaceID,
                windowID: targetWindow.windowID
            ),
            explicitWindowRoutingHint: metadata.explicitWindowRoutingHint,
            invocationID: metadata.invocationID,
            requestID: metadata.requestID
        )
        let selectionPrerequisite = try await dependencies.files.drainReadFileAutoSelection(
            targetMetadata,
            .mirroredSelectionAndMetrics
        )
        try Task.checkCancellation()
        switch selectionPrerequisite {
        case .completed:
            break
        case .cancelled:
            throw CancellationError()
        case .deferred:
            throw MCPContextBuilderSelectionPrerequisiteError.deferred
        case .invalidated:
            throw MCPContextBuilderSelectionPrerequisiteError.invalidated
        }
        let runAuthority: ContextBuilderResolvedRunAuthority
        do {
            runAuthority = try await contextBuilderVM.resolveMCPRunAuthority(
                identity: resolvedIdentity,
                nestedTabContext: tabResolution.nestedTabContext,
                workspaceContext: workspaceContext,
                responseType: responseType?.rawValue,
                oraclePreset: oraclePreset
            )
        } catch let error as OracleExecutionResolutionError {
            throw MCPError.invalidParams(error.localizedDescription)
        }

        try await workspaceContext?.validateStartupAvailability(workspaceManager: targetWindow.workspaceManager)
        try Task.checkCancellation()

        // swiftformat:disable conditionalAssignment
        let capturedOracleExportDestination: OracleExportDestination?
        if exportResponse {
            // Export into the exact root scope selected by Context Builder's final tab resolution.
            // Ambient request metadata may still describe a different active tab.
            capturedOracleExportDestination = try dependencies.execution.makeOracleExportDestination(
                workspace,
                targetWindow.windowID,
                finalTabID,
                lookupContext
            )
        } else {
            capturedOracleExportDestination = nil
        }
        // swiftformat:enable conditionalAssignment

        let mcpControlToken = try await MainActor.run {
            try contextBuilderVM.beginMCPControlledRun(
                forTabID: finalTabID,
                workspaceID: resolvedIdentity.workspaceID,
                responseType: responseType?.rawValue,
                planModelName: nil
            )
        }

        return PreparedContextBuilderRun(instructions: instructions, invocationContext: invocationContext, targetWindow: targetWindow, tabResolution: tabResolution, initialResultTab: initialResultTab, responseType: responseType, exportResponse: exportResponse, runAuthority: runAuthority, exportDestination: capturedOracleExportDestination, controlToken: mcpControlToken)
    }

    private static func performContextBuilderRun(_ prepared: PreparedContextBuilderRun, dependencies: Dependencies, jobProgress: MCPLongRunningJobProgress? = nil) async throws -> ContextBuilderToolResult {
        let instructions = prepared.instructions
        let invocationContext = prepared.invocationContext
        let connectionID = jobProgress == nil ? invocationContext.connectionID : nil
        let targetWindow = prepared.targetWindow
        let tabResolution = prepared.tabResolution
        let resolvedIdentity = tabResolution.identity
        let finalTabID = resolvedIdentity.tabID
        let workspaceContext = tabResolution.workspaceContext
        let lookupContext = workspaceContext?.lookupContext ?? tabResolution.lookupContext
        let initialResultTab = prepared.initialResultTab
        let responseType = prepared.responseType
        let exportResponse = prepared.exportResponse
        let runAuthority = prepared.runAuthority
        let capturedOracleExportDestination = prepared.exportDestination
        let contextBuilderVM = targetWindow.contextBuilderAgentViewModel
        let mcpControlToken = prepared.controlToken
        let tabIDForCleanup = finalTabID
        return try await AsyncScope.withCleanup({}, cleanup: {
            await MainActor.run {
                contextBuilderVM.clearMCPControlledRun(
                    forTabID: tabIDForCleanup,
                    controlToken: mcpControlToken
                )
            }
        }) {
            let contextBuilderTokenBudget = runAuthority.configuration.effectiveTokenBudget
            let planModelName = runAuthority.configuration.generatedResponseAuthority.planningModelName

            let sendStageProgress: MCPAppPhysicalCapabilityAdapters.SendStageProgress = { connection, tool, stage, message in
                guard jobProgress == nil else { return }
                await dependencies.execution.sendStageProgress(connection, tool, stage, message)
            }
            let progressTimeline = ContextBuilderMCPProgressTimeline { event in
                if let jobProgress {
                    if event.kind == .started { await jobProgress.phase(event.phase.rawValue, stage: event.stage) }
                    return
                }
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
                await sendStageProgress(
                    connectionID,
                    MCPWindowToolName.contextBuilder,
                    "starting",
                    "Starting context builder..."
                )

                await sendStageProgress(
                    connectionID,
                    MCPWindowToolName.contextBuilder,
                    "discovering",
                    "Running Context Builder agent..."
                )
                let snapshot = try await withTimelinePhaseCompletion(progressTimeline) {
                    try await withHeartbeat(
                        invocationContext: invocationContext,
                        execution: dependencies.execution,
                        tool: MCPWindowToolName.contextBuilder,
                        stage: "discovering",
                        message: "Still building context...",
                        timeline: progressTimeline,
                        jobProgress: jobProgress
                    ) {
                        try await contextBuilderVM.runContextBuilderForMCP(
                            authority: runAuthority,
                            instructionsOverride: instructions.isEmpty ? nil : instructions,
                            workspaceContext: workspaceContext,
                            mcpControlToken: mcpControlToken,
                            progressReporter: progressReporter,
                            activityReporter: activityReporter
                        )
                    }
                }

                await sendStageProgress(
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
                        invocationContext: invocationContext,
                        execution: dependencies.execution,
                        tool: MCPWindowToolName.contextBuilder,
                        stage: "processing",
                        message: "Still rendering Context Builder selection...",
                        timeline: progressTimeline,
                        jobProgress: jobProgress
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

                        try await workspaceContext?.validateStartupAvailability(workspaceManager: targetWindow.workspaceManager)
                        try Task.checkCancellation()
                        let selection = resultTab.selection
                        let reply = try await dependencies.execution.buildTabSelectionReply(
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
                if let jobProgress {
                    await jobProgress.store.update(id: jobProgress.id, fields: ["discovery": .object(["file_count": .int(fileCount), "total_tokens": .int(selectionReply.totalTokens ?? 0)])])
                }

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
                                invocationContext: invocationContext,
                                execution: dependencies.execution,
                                tool: MCPWindowToolName.contextBuilder,
                                stage: "generating",
                                message: "Still authorizing Context Builder review selection...",
                                timeline: progressTimeline,
                                jobProgress: jobProgress
                            ) {
                                await dependencies.execution.beforeContextBuilderFinalReviewAuthorization()
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
                                    store: dependencies.context.promptVM.workspaceFileContextStore
                                )
                                await dependencies.execution.didFinalizeContextBuilderReview(authorization)

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

                    guard case let .generate(capturedMode, execution) =
                        runAuthority.configuration.generatedResponseAuthority,
                        capturedMode == mode
                    else {
                        throw MCPError.internalError(
                            "Context Builder generated-response authority does not match the requested mode"
                        )
                    }

                    let modeLabel = responseType?.generationLabel ?? "question"
                    await sendStageProgress(
                        connectionID,
                        MCPWindowToolName.contextBuilder,
                        "generating",
                        "Generating \(modeLabel)..."
                    )

                    let reply = try await withTimelinePhaseCompletion(progressTimeline) {
                        try await withHeartbeat(
                            invocationContext: invocationContext,
                            execution: dependencies.execution,
                            tool: MCPWindowToolName.contextBuilder,
                            stage: "generating",
                            message: "Still generating \(modeLabel)...",
                            timeline: progressTimeline,
                            jobProgress: jobProgress
                        ) {
                            try await dependencies.execution.runMCPPlanOrQuestion(
                                contextBuilderVM,
                                resolvedIdentity,
                                tabResolution.agentModeSessionID,
                                tabResolution.agentModeRunID,
                                mode,
                                execution,
                                prompt,
                                sel,
                                lookupContext,
                                tabResolution.reviewGitContext,
                                finalReviewAuthorization,
                                progressReporter,
                                activityReporter,
                                jobProgress
                            )
                        }
                    }

                    if mode == .review {
                        reviewReply = reply
                    } else {
                        planReply = reply
                    }
                    followUpHint = Self.generatedResponseFollowUpHint(
                        modeLabel: modeLabel,
                        chatID: reply.shortId,
                        oracleCount: reply.oracleGroup?.result.oracleCount
                    )
                }

                await sendStageProgress(
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

                func makeResult(oracleExportPath: String?, oracleExportInstruction: String? = nil, oracleExportError: String? = nil) -> ContextBuilderToolResult {
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
                        oracleExportInstruction: oracleExportInstruction,
                        oracleExportError: oracleExportError
                    )
                }

                if exportResponse,
                   planReply != nil || reviewReply != nil
                {
                    do {
                        // Ticket observers retain the settled result even if optional export is
                        // cancelled or fails. Legacy requests keep their existing throwing contract.
                        if jobProgress != nil { try Task.checkCancellation() }
                        await jobProgress?.phase("response_export", stage: "exporting")
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
                        let exportPath = try await dependencies.execution.resolveDefaultOracleExportPath(
                            exportMode,
                            chatID,
                            capturedOracleExportDestination
                        )
                        let resolvedPath = try await dependencies.execution.writeGeneratedOracleExportFile(
                            exportPath,
                            markdown,
                            capturedOracleExportDestination
                        )
                        let exportedLaneCount = [planReply, reviewReply]
                            .compactMap { $0?.oracleGroup?.result.oracleResults.count }
                            .max()
                        oracleExportFile = OracleExportFile(
                            path: resolvedPath,
                            instruction: AgentOracleExport.instruction(path: resolvedPath, oracleLaneCount: exportedLaneCount)
                        )
                    } catch {
                        guard jobProgress != nil else { throw error }
                        let notice = error is CancellationError || Task.isCancelled
                            ? "Oracle export cancelled; output may remain. Recover the settled result using the returned chat IDs."
                            : "Oracle export failed; output may remain. Recover the settled result using the returned chat IDs."
                        return makeResult(oracleExportPath: nil, oracleExportError: notice)
                    }
                }

                return makeResult(
                    oracleExportPath: oracleExportFile?.path,
                    oracleExportInstruction: oracleExportFile?.instruction
                )
            }
            return try await runContextBuilderAndPlan()
        }
    }

    nonisolated static func generatedResponseFollowUpHint(
        modeLabel: String,
        chatID: String,
        oracleCount: Int?
    ) -> String {
        let continuation = "Continue this \(modeLabel) conversation with ask_oracle(chat_id: \"\(chatID)\", new_chat: false)"
        guard let reminder = OracleGroupDeliveryContract.followUpReminder(laneCount: oracleCount ?? 0) else {
            return continuation
        }
        return reminder + "\nThis explicit chat_id continues only the addressed Oracle lane; other lanes are not re-run.\n\nOptional later follow-up: " + continuation
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
        invocationContext: ToolInvocationContext,
        execution: MCPAppPhysicalCapabilityAdapters.Execution,
        tool: String,
        stage: String,
        message: String,
        timeline: ContextBuilderMCPProgressTimeline? = nil,
        jobProgress: MCPLongRunningJobProgress? = nil,
        interval: Duration = .seconds(30),
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard jobProgress == nil, let connectionID = invocationContext.connectionID else {
            return try await operation()
        }
        let shouldSendProgress = await execution.supportsProgressNotifications(connectionID)
        guard shouldSendProgress else {
            return try await operation()
        }

        return try await MCPToolHeartbeat.run(interval: interval) {
            let heartbeat: (stage: String, message: String) = if let timeline {
                await timeline.heartbeat(
                    fallbackStage: stage,
                    fallbackMessage: message
                )
            } else {
                (stage, message)
            }
            await execution.sendHeartbeatProgress(
                connectionID,
                tool,
                heartbeat.stage,
                heartbeat.message
            )
        } operation: {
            try await operation()
        }
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
