import Foundation
import JSONSchema
import MCP
import Ontology
import RepoPromptDomainRuntime
import RepoPromptShared

@MainActor
final class MCPAgentSessionControlToolProvider: MCPAppToolProviding {
    let group: MCPAppToolGroup = .agentSessionControl

    private let runtime: MCPAppToolBinder
    private let dependencies: MCPAppPhysicalCapabilityAdapters.Execution

    init(runtime: MCPAppToolBinder, execution: MCPAppPhysicalCapabilityAdapters.Execution) {
        self.runtime = runtime
        dependencies = execution
    }

    func buildTools() -> [Tool] {
        var tools = [
            agentSelfTool(),
            shareThoughtsTool(),
            setStatusTool(),
            waitForNextInstructionTool()
        ]
        #if DEBUG
            tools.append(promptExperimentTool())
        #endif
        return tools
    }

    private func agentSelfTool() -> Tool {
        guard let definition = MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.agentSelf) else {
            preconditionFailure("Missing canonical self_compact definition")
        }
        return runtime.tool(
            name: MCPWindowToolName.agentSelf,
            freshnessPolicy: .none,
            description: definition.description,
            annotations: .init(
                readOnlyHint: false, destructiveHint: true,
                idempotentHint: false, openWorldHint: true
            ),
            inputSchema: .object(
                properties: [
                    "op": .string(description: "Required operation: context or compact.", enum: ["context", "compact"]),
                    "note": .string(description: "[compact] Required verbatim note: 10% of window tokens × 4 UTF-8 bytes; 65,536 if unknown."),
                    "idempotency_key": .string(description: "[compact] Required identical-retry key, at most 200 UTF-8 bytes.")
                ],
                required: ["op"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeAgentSelf(args)
        }
    }

    private func shareThoughtsTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.shareThoughts,
            freshnessPolicy: .none,
            description: """
            Share real-time progress updates with the user.

            **Critical**: This is the PRIMARY way to provide live feedback during operations.
            Without this tool, users see nothing until you call `wait_for_next_user_instruction` -
            they're left staring at a loading state wondering what's happening.

            Use this tool PROACTIVELY to narrate your progress as you work:
            - "Looking for authentication-related files..."
            - "Found UserService.swift, reading to understand the pattern..."
            - "Making changes to the login flow..."

            **When to use (frequently!):**
            - Exploring a codebase (searching, reading multiple files)
            - Working through multi-step implementations
            - Any task taking more than a few seconds
            - Before and after significant operations

            **Notes:**
            - Messages appear with a "thinking" indicator
            - Use the optional `title` parameter for categorization (e.g., "Searching", "Analyzing", "Planning")
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                properties: [
                    "thoughts": .string(description: "Your thoughts or reasoning to share with the user."),
                    "title": .string(description: "Optional short title for the thought (e.g., 'Analyzing', 'Planning').")
                ],
                required: ["thoughts"]
            )
        ) { [dependencies] invocation, args in
            try await Self.executeShareThoughts(args: args, invocationContext: invocation.context, dependencies: dependencies)
        }
    }

    private func setStatusTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.setStatus,
            freshnessPolicy: .none,
            description: """
            Rename the current agent session/tab.

            Use this tool near session start to set a helpful session title.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                properties: [
                    "session_name": .string(description: "Optional session/tab title to set for the active session tab.")
                ],
                required: []
            )
        ) { [dependencies] invocation, args in
            try await Self.executeSetStatus(args: args, invocationContext: invocation.context, dependencies: dependencies)
        }
    }

    private func waitForNextInstructionTool() -> Tool {
        let defaultWaitSeconds = Int(MCPTimeoutPolicy.nextUserInstructionDefaultWaitSeconds)
        return runtime.tool(
            name: MCPWindowToolName.waitForNextInstruction,
            freshnessPolicy: .none,
            description: """
            Complete your turn and receive the user's next message.

            **CRITICAL - YOU MUST ALWAYS CALL THIS TOOL**
            This is how you deliver your response to the user. Without calling this tool, the user sees NOTHING and the session hangs. You must call this after EVERY turn - whether you completed a task, answered a question, or just want to share information.

            **How it works:**
            - The `prompt` you provide IS your message to the user - make it your complete response
            - After you call this, you receive the user's reply as your next turn (like a normal conversation)
            - The wait defaults to \(defaultWaitSeconds) seconds and honors a caller-supplied `timeout_seconds`; a timeout returns `timed_out: true`
            - Do NOT send a separate text response before calling this tool - the prompt IS your response

            **Writing your response (the `prompt` parameter):**
            - Be verbose and thorough - explain what you did, what you found, or what you're thinking
            - Write naturally as if speaking to a colleague - no need to end with a question
            - Include relevant details: files changed, code snippets, reasoning, observations
            - Example: "I've refactored the authentication module to use JWT tokens. The changes include:\n\n1. **TokenManager.swift** - New class handling token generation and validation\n2. **AuthMiddleware.swift** - Updated to use TokenManager instead of session-based auth\n3. **UserController.swift** - Login endpoint now returns JWT in response body\n\nAll existing tests pass, and I added new tests for token expiration handling."
            - DO NOT write terse responses like "Done." - be informative and helpful

            **The user's response comes as your next turn:**
            - After calling this tool, you'll receive the user's message as input to your next turn
            - This is just like a normal conversation - no special handling needed
            - You don't need to ask "what's next?" - just present your response naturally
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                properties: [
                    "prompt": .string(description: "Your response to the user - what you want to say before waiting for their next instruction."),
                    "timeout_seconds": .integer(description: "Optional wait timeout in seconds. Default \(defaultWaitSeconds).")
                ],
                required: []
            )
        ) { [dependencies] invocation, args in
            try await Self.executeWaitForNextInstruction(args: args, invocationContext: invocation.context, dependencies: dependencies)
        }
    }

    #if DEBUG
        private func promptExperimentTool() -> Tool {
            runtime.tool(
                name: MCPWindowToolName.promptExperiment,
                freshnessPolicy: .none,
                description: """
                Optimize one of RepoPrompt's built-in prompts with upstream GEPA against its checked-in evaluation suite.

                Lifecycle: `targets` (prompts, suites, prompt-only models, defaults) → `create_or_update` (typed fields; all
                invalid fields are reported together) → `request_approval` (shows a native card; only the user can approve,
                and approval starts the first run) → `status_or_wait` → `run` to resume within the remaining approved cap →
                `cancel`. After a completed run, `propose_patch` creates a reviewed source diff for a retained candidate.
                Changing any authority field of an approved experiment creates a new experiment that needs its own
                approval. This tool cannot approve or apply a candidate.
                """,
                annotations: .repoPromptLocalEphemeralState,
                inputSchema: .object(
                    properties: [
                        "op": .string(description: "targets | create_or_update | request_approval | run | status_or_wait | cancel | propose_patch"),
                        "experiment_id": .string(description: "Experiment UUID. Optional for create_or_update (update) and status_or_wait (omit to list)."),
                        "expected_authority_digest": .string(description: "request_approval: the authority_digest you reviewed; refused if it changed."),
                        "title": .string(description: "create_or_update: display title."),
                        "prompt_id": .string(description: "create_or_update: built-in prompt ID from targets, e.g. oracle-plan."),
                        "suite_id": .string(description: "create_or_update: suite ID from targets; defaults to the prompt's checked-in suite."),
                        "execution_target": .string(description: "create_or_update: prompt-only target selector for the evaluated model; defaults from targets."),
                        "reflection_target": .string(description: "create_or_update: prompt-only target selector for GEPA reflection; defaults from targets."),
                        "judge_target": .string(description: "create_or_update: judge target selector, only for model-judged suites; defaults from targets."),
                        "max_evaluations": .integer(description: "create_or_update: total evaluation cap the user approves (at least the suite minimum from targets)."),
                        "reflection_minibatch_size": .integer(description: "create_or_update: GEPA reflection minibatch size, 1-100. Default 2."),
                        "max_provider_retries": .integer(description: "create_or_update: retries per provider call for transient failures, 0-3. Default 2."),
                        "random_seed": .integer(description: "create_or_update: GEPA random seed. Default 0."),
                        "prompt_character_ceiling_ratio": .number(description: "create_or_update: hard ceiling for a proposed prompt as a multiple of the prompt being edited, 0.25-4.0. Default 1.0 (proposals never grow the prompt)."),
                        "max_prompt_characters": .integer(description: "create_or_update: optional absolute prompt-length ceiling in characters, 200-200000."),
                        "noise_floor_replicates": .integer(description: "create_or_update: extra seed passes over the validation cases before search to measure judge/target noise, 0-5. Default 2. Part of the separate calibration line; cached across experiments."),
                        "timeout_seconds": .number(description: "status_or_wait: seconds to wait for an approval or run change, 0-3600. Default 60."),
                        "run_id": .string(description: "propose_patch: completed run UUID."),
                        "candidate_index": .integer(description: "propose_patch: retained GEPA candidate index.")
                    ],
                    required: ["op"]
                )
            ) { _, args in
                try await PromptExperimentMCPControl.execute(args: args)
            }
        }
    #endif

    private static func executeShareThoughts(
        args: [String: Value],
        invocationContext: ToolInvocationContext,
        dependencies: MCPAppPhysicalCapabilityAdapters.Execution
    ) async throws -> Value {
        guard let thoughts = args["thoughts"]?.stringValue else {
            throw MCPError.invalidParams("thoughts is required")
        }
        let title = args["title"]?.stringValue

        let connectionID = try await dependencies.requireAgentModeConnection(invocationContext, MCPWindowToolName.shareThoughts)
        let targetWindow = try dependencies.requireTargetWindow()
        let target = try await dependencies.resolveAgentModeTabID(args, connectionID, .shareThoughts)

        // Invariant: background tool updates are tab-scoped and must not steal tab focus.
        try await MainActor.run {
            try targetWindow.agentModeViewModel.shareThoughts(
                thoughts,
                title: title,
                target: target
            )
        }

        return .object([
            "ok": .bool(true),
            "context_id": .string(target.tabID.uuidString)
        ])
    }

    private static func executeSetStatus(
        args: [String: Value],
        invocationContext: ToolInvocationContext,
        dependencies: MCPAppPhysicalCapabilityAdapters.Execution
    ) async throws -> Value {
        let connectionID = try await dependencies.requireAgentModeConnection(invocationContext, MCPWindowToolName.setStatus)
        let trimmedSessionName = args["session_name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionNameToApply = (trimmedSessionName?.isEmpty == false) ? trimmedSessionName : nil

        let targetWindow = try dependencies.requireTargetWindow()
        let target = try await dependencies.resolveAgentModeTabID(args, connectionID, .setStatus)

        // Invariant: background status updates are tab-scoped and must not steal tab focus.
        try await MainActor.run {
            if let sessionNameToApply {
                try targetWindow.agentModeViewModel.renameSession(
                    target: target,
                    to: sessionNameToApply
                )
            }
        }

        var result: [String: Value] = [
            "ok": .bool(true),
            "context_id": .string(target.tabID.uuidString),
            "session_name_applied": .bool(sessionNameToApply != nil)
        ]
        if let sessionNameToApply {
            result["session_name"] = .string(sessionNameToApply)
        }
        return .object(result)
    }

    static func resolvedInstructionWaitTimeoutSeconds(_ value: Value?) throws -> TimeInterval {
        let timeout = value?.intValue.map(TimeInterval.init) ?? MCPTimeoutPolicy.nextUserInstructionDefaultWaitSeconds
        guard timeout > 0 else {
            throw MCPError.invalidParams("timeout_seconds must be a positive integer.")
        }
        return timeout
    }

    private static func executeWaitForNextInstruction(
        args: [String: Value],
        invocationContext: ToolInvocationContext,
        dependencies: MCPAppPhysicalCapabilityAdapters.Execution
    ) async throws -> Value {
        let prompt = args["prompt"]?.stringValue
        let timeout = try resolvedInstructionWaitTimeoutSeconds(args["timeout_seconds"])

        let targetWindow = try dependencies.requireTargetWindow()
        let connectionID = invocationContext.connectionID
        let target = try await dependencies.resolveAgentModeTabID(args, connectionID, .waitForInstruction)

        // Invariant: waiting state is stored on the target session; do not switch tabs here.
        let response = try await targetWindow.agentModeViewModel.waitForNextUserInstruction(
            target: target,
            prompt: prompt,
            timeoutSeconds: timeout
        )

        var result: [String: Value] = [
            "timed_out": .bool(response.timedOut),
            "elapsed_seconds": .int(response.elapsedSeconds)
        ]
        if let text = response.text {
            result["instruction"] = .string(text)
        } else {
            result["instruction"] = .null
        }

        return .object(result)
    }
}
