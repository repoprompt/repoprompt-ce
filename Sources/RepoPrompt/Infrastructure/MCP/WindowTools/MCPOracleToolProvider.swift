import Foundation
import JSONSchema
import MCP
import Ontology
import RepoPromptDomainRuntime

@MainActor
final class MCPOracleToolProvider: MCPAppToolProviding {
    let group: MCPAppToolGroup = .oracle

    private let runtime: MCPAppToolBinder
    private let dependencies: MCPAppPhysicalCapabilityAdapters.Execution

    init(runtime: MCPAppToolBinder, execution: MCPAppPhysicalCapabilityAdapters.Execution) {
        self.runtime = runtime
        dependencies = execution
    }

    func buildTools() -> [Tool] {
        [
            oracleUtilsTool(),
            askOracleTool(),
            oracleSendTool()
        ]
    }

    private func oracleUtilsTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.oracleUtils,
            freshnessPolicy: .none,
            description: """
            Oracle helper utilities.

            Use this for read-only oracle-specific helpers:
            - `op="models"`   → list model choices relevant to oracle sends
            - `op="sessions"` → list oracle/chat sessions for the current workspace. Pass context_id to filter to a specific context's sessions.

            Use `ask_oracle` for all send/continue turns.
            """,
            inputSchema: .object(
                properties: [
                    "op": .string(description: "Helper operation", enum: ["models", "sessions"]),
                    "limit": .integer(description: "Maximum sessions to return for the sessions operation"),
                    "scope": .string(description: "Filter scope: 'workspace' (default) or 'tab'. Auto-inferred when context_id is provided."),
                    "context_id": .string(description: "Context UUID to filter to a specific context's sessions. Use bind_context op=list to discover values.")
                ],
                required: ["op"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeOracleUtils(args)
        }
    }

    private func askOracleTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.askOracle,
            freshnessPolicy: .providerManaged,
            description: """
            Agent-mode oracle send/continue tool.

            Use this to start or continue an oracle conversation in `chat`, `plan`, or `review` mode for the current agent tab.

            Pass `export_response: true` to write the response to a shareable file and get back shareable `oracle_export_path` / `oracle_export_instruction` values. To hand the export to a child agent, include `oracle_export_path` inside the `message` (or `messages`) you send on your next delegation call; your system prompt names the specific delegation tool available to you.

            Use `oracle_chat_log` after compaction to recover recent oracle messages.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                properties: [
                    "message": .string(
                        description: "Your message to send",
                        minLength: 1
                    ),
                    "mode": .string(
                        description: "Operation mode",
                        default: "chat",
                        enum: ["chat", "plan", "review"]
                    ),
                    "chat_id": .string(
                        description: "Continue a specific chat in the current agent tab"
                    ),
                    "new_chat": .boolean(
                        description: "Start a new chat session (default: false; discouraged)"
                    ),
                    "export_response": .boolean(
                        description: "When true, export the response to a file and return `oracle_export_path` plus `oracle_export_instruction`. Include `oracle_export_path` inside the `message` you send on your next delegation call; the specific delegation tool is named by your system prompt."
                    )
                ],
                required: ["message"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeAskOracle(args)
        }
    }

    private func oracleSendTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.oracleSend,
            freshnessPolicy: .providerManaged,
            description: """
            Consult a second AI for planning, review, or questions.

            Use this to start or continue an oracle conversation in `chat`, `plan`, or `review` mode.
            Use `oracle_utils` for passive helpers like models and sessions.

            Pass `export_response: true` to write the response to a shareable file and get back shareable `oracle_export_path` / `oracle_export_instruction` values. To hand the export to a child agent, include `oracle_export_path` inside the `message` (or `messages`) you send on your next delegation call; your system prompt names the specific delegation tool available to you.

            Build context first with file reads, `manage_selection`, or `workspace_context`.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                properties: [
                    "message": .string(
                        description: "Your message to send",
                        minLength: 1
                    ),
                    "mode": .string(
                        description: "Operation mode",
                        default: "chat",
                        enum: ["chat", "plan", "review"]
                    ),
                    "chat_id": .string(
                        description: "Continue a specific chat in the current tab or current context"
                    ),
                    "new_chat": .boolean(
                        description: "Start a new chat session (default: false; discouraged)"
                    ),
                    "model": .string(
                        description: "Model preset ID or name override"
                    ),
                    "export_response": .boolean(
                        description: "When true, export the response to a file and return `oracle_export_path` plus `oracle_export_instruction`. Include `oracle_export_path` inside the `message` you send on your next delegation call; the specific delegation tool is named by your system prompt."
                    )
                ],
                required: ["message"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeOracleSend(args)
        }
    }

    func executeDomainOracleChatLog(
        context _: DomainReadInvocationContext,
        args: [String: Value]
    ) async throws -> Value {
        try await dependencies.executeOracleChatLog(args)
    }
}
