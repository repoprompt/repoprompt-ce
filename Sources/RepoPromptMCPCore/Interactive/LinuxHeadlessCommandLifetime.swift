#if os(Linux)
    import Foundation
    import MCP

    /// A single-command CLI invocation owns its local runtime and shuts it down on exit.
    /// Do not advertise a successful background launch that this same exit will cancel.
    enum LinuxHeadlessCommandLifetime {
        static func validate(toolName: String, arguments: [String: Value]) throws {
            guard isAgentTool(toolName), (arguments["op"]?.stringValue ?? "start") == "start",
                  arguments["detach"]?.boolValue == true else { return }
            throw MCPError.invalidParams(
                "Detached agents require a long-lived MCP connection or interactive REPL on Linux. " +
                    "--exec and --call shut down their local runtime on exit; use detach:false or keep --interactive open."
            )
        }

        static func reportPendingAgent(toolName: String, result: CallTool.Result) -> CallTool.Result {
            guard isAgentTool(toolName), result.isError != true else { return result }
            var values = result.structuredContent.map { [$0] } ?? []
            for case let .text(text, _, _) in result.content {
                if let value = try? JSONDecoder().decode(Value.self, from: Data(text.utf8)) {
                    values.append(value)
                }
            }
            guard values.contains(where: { value in
                let status = value.objectValue?["status"]?.stringValue
                return status == "running" || status == "waiting_for_input"
            }) else { return result }
            let diagnostic = "Agent work is unfinished. This Linux command owns the local runtime and " +
                "will cancel remaining providers when it exits. Use a long-lived MCP connection or " +
                "keep --interactive open to launch, poll, and wait for agents."
            return CallTool.Result(
                content: result.content + [.text(text: diagnostic, annotations: nil, _meta: nil)],
                structuredContent: result.structuredContent,
                isError: true,
                _meta: result._meta
            )
        }

        private static func isAgentTool(_ name: String) -> Bool {
            name == "agent_run" || name == "agent_explore"
        }
    }
#endif
