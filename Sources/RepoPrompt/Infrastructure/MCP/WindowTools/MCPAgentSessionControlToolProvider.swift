import Foundation
import JSONSchema
import MCP
import Ontology
import RepoPromptShared

@MainActor
final class MCPAgentSessionControlToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .agentSessionControl

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
    }

    func buildTools() -> [Tool] {
        [
            shareThoughtsTool(),
            setStatusTool(),
            waitForNextInstructionTool()
        ]
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
        ) { [dependencies] _, args in
            try await Self.executeShareThoughts(args: args, dependencies: dependencies)
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
        ) { [dependencies] _, args in
            try await Self.executeSetStatus(args: args, dependencies: dependencies)
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
        ) { [dependencies] _, args in
            try await Self.executeWaitForNextInstruction(args: args, dependencies: dependencies)
        }
    }

    private static func executeShareThoughts(
        args: [String: Value],
        dependencies: MCPWindowToolDependencies
    ) async throws -> Value {
        guard let thoughts = args["thoughts"]?.stringValue else {
            throw MCPError.invalidParams("thoughts is required")
        }
        let title = args["title"]?.stringValue

        let connectionID = try await dependencies.requireAgentModeConnection(MCPWindowToolName.shareThoughts)
        let targetWindow = try dependencies.requireTargetWindow()
        let tabID = try await dependencies.resolveAgentModeTabID(args, connectionID)

        // Invariant: background tool updates are tab-scoped and must not steal tab focus.
        await MainActor.run {
            targetWindow.agentModeViewModel.shareThoughts(thoughts, title: title, tabID: tabID)
        }

        return .object([
            "ok": .bool(true),
            "context_id": .string(tabID.uuidString)
        ])
    }

    private static func executeSetStatus(
        args: [String: Value],
        dependencies: MCPWindowToolDependencies
    ) async throws -> Value {
        let connectionID = try await dependencies.requireAgentModeConnection(MCPWindowToolName.setStatus)
        let trimmedSessionName = args["session_name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionNameToApply = (trimmedSessionName?.isEmpty == false) ? trimmedSessionName : nil

        let targetWindow = try dependencies.requireTargetWindow()
        let tabID = try await dependencies.resolveAgentModeTabID(args, connectionID)

        // Invariant: background status updates are tab-scoped and must not steal tab focus.
        await MainActor.run {
            if let sessionNameToApply {
                targetWindow.agentModeViewModel.renameSession(tabID: tabID, to: sessionNameToApply)
            }
        }

        var result: [String: Value] = [
            "ok": .bool(true),
            "context_id": .string(tabID.uuidString),
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
        dependencies: MCPWindowToolDependencies
    ) async throws -> Value {
        let prompt = args["prompt"]?.stringValue
        let timeout = try resolvedInstructionWaitTimeoutSeconds(args["timeout_seconds"])

        let targetWindow = try dependencies.requireTargetWindow()
        let connectionID = ServerNetworkManager.currentConnectionID
        let tabID = try await dependencies.resolveAgentModeTabID(args, connectionID)

        // Invariant: waiting state is stored on the target session; do not switch tabs here.
        let response = try await targetWindow.agentModeViewModel.waitForNextUserInstruction(
            tabID: tabID,
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
