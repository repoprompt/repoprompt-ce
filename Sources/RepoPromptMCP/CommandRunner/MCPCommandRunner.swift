//
//  MCPCommandRunner.swift
//  repoprompt-mcp
//
//  Reusable command execution engine.
//  Handles parsing and executing commands without REPL UI.
//

import Foundation
import MCP
import RepoPromptShared

/// Reusable command execution engine that works with both REPL and exec mode.
actor MCPCommandRunner {
    private let session: InteractiveMCPClientSession
    private var parseContext: CommandParseContext
    private let settings: RunnerSettings

    /// Output goes through this callback
    private let outputHandler: @Sendable (String, Bool) async -> Void // (text, isError)

    /// Creates a new command runner.
    /// - Parameters:
    ///   - session: The MCP client session to use for tool calls
    ///   - initialDirectory: Starting directory for path resolution
    ///   - settings: Runner configuration
    ///   - outputHandler: Callback for output. (text, isError) - isError true for stderr.
    init(
        session: InteractiveMCPClientSession,
        initialDirectory: String,
        settings: RunnerSettings,
        outputHandler: @escaping @Sendable (String, Bool) async -> Void
    ) {
        self.session = session
        parseContext = CommandParseContext(currentDirectory: initialDirectory)
        self.settings = settings
        self.outputHandler = outputHandler
    }

    /// Current working directory for path resolution.
    var currentDirectory: String {
        parseContext.currentDirectory
    }

    /// Updates the current directory.
    func setCurrentDirectory(_ path: String) {
        parseContext.currentDirectory = path
    }

    // MARK: - Execution

    /// Runs a single input line (may contain ; or && chaining).
    /// Returns execution summary.
    func runLine(_ line: String) async -> LineExecutionResult {
        let parsed = REPLInputParser.parse(line)
        var failedCount = 0
        var totalCount = 0
        var lastSegmentSucceeded = true
        let hasMultipleSegments = parsed.segments.count > 1

        for segment in parsed.segments {
            // Add separator between chained command outputs
            if hasMultipleSegments, totalCount > 0 {
                await output("\n---\n", isError: false) // Markdown horizontal rule separator
            }
            totalCount += 1
            do {
                let command = try MCPCommandParser.parseCommand(segment.command, ctx: parseContext)
                try await executeCommand(command)
                lastSegmentSucceeded = true
            } catch let error as CommandParseError {
                await output("Error: \(error.description)", isError: true)
                if case let .unknownCommand(cmd) = error,
                   let suggestion = MCPCommandParser.suggestCommand(for: cmd)
                {
                    await output("Did you mean: \(suggestion)?", isError: false)
                }
                failedCount += 1
                lastSegmentSucceeded = false
                if segment.separatorAfter == .onSuccess || settings.failFast {
                    break
                }
            } catch is ToolCallFailedError {
                // Tool output already printed by printCallResult; just mark as failed
                failedCount += 1
                lastSegmentSucceeded = false
                if segment.separatorAfter == .onSuccess || settings.failFast {
                    break
                }
            } catch {
                await output("Error: \(error)", isError: true)
                failedCount += 1
                lastSegmentSucceeded = false
                if segment.separatorAfter == .onSuccess || settings.failFast {
                    break
                }
            }
        }

        let succeeded: Bool = switch settings.exitCodeMode {
        case .anyFailure:
            failedCount == 0
        case .lastSegment:
            lastSegmentSucceeded
        }

        return LineExecutionResult(
            line: line,
            succeeded: succeeded,
            failedSegments: failedCount,
            totalSegments: totalCount
        )
    }

    /// Runs multiple lines sequentially.
    func runLines(_ lines: [String]) async -> (allSucceeded: Bool, summaries: [LineExecutionResult]) {
        var summaries: [LineExecutionResult] = []
        var anyFailed = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let summary = await runLine(trimmed)
            summaries.append(summary)

            if !summary.succeeded {
                anyFailed = true
                if settings.failFast {
                    break
                }
            }
        }

        return (!anyFailed, summaries)
    }

    // MARK: - Command Execution

    /// Executes a parsed command.
    func executeCommand(_ command: InteractiveCommand) async throws {
        switch command {
        case .help:
            await printHelp()

        case let .tools(mode):
            try await printToolList(mode: mode)

        case let .toolsSchema(mode):
            try await printToolsSchemaJSON(mode: mode)

        case let .describe(toolName):
            try await describeTool(toolName)

        case let .call(toolName, jsonPayload):
            try await callTool(name: toolName, jsonPayload: jsonPayload)

        case let .aliasCall(toolName, args):
            try await callToolWithArgs(name: toolName, args: args)

        case .windows:
            let result = try await session.listWindows()
            await printCallResult(result)
            if result.isError == true {
                throw ToolCallFailedError(toolName: "bind_context")
            }

        case let .useWindow(windowID):
            let result = try await session.selectWindow(windowID: windowID)
            await printCallResult(result)
            if result.isError == true {
                throw ToolCallFailedError(toolName: "bind_context")
            }

        case .clearWindow:
            let result = try await session.clearWindowSelection()
            await printCallResult(result)
            if result.isError == true {
                throw ToolCallFailedError(toolName: "bind_context")
            }

        case let .snapshot(path):
            try await snapshotTools(to: path)

        case .refresh:
            let tools = try await session.refreshTools()
            await output("Refreshed: \(tools.count) tools available", isError: false)

        case .exit:
            // Exit is handled by the caller (REPL or ExecService)
            throw ExitCommandException()

        case .history:
            // History is REPL-only, no-op in exec mode
            await output("History command only available in interactive mode.", isError: false)

        case .showSettings:
            await printSettings()

        case .setSetting:
            // Settings changes are REPL-only in this abstraction
            await output("Settings command only available in interactive mode.", isError: false)

        case .clearScreen:
            await output("\u{001B}[2J\u{001B}[H", isError: false)

        case .status:
            await printStatus()

        case .pwd:
            await output(parseContext.currentDirectory, isError: false)

        case let .cd(path):
            if parseContext.changeDirectory(to: path) {
                await output(parseContext.currentDirectory, isError: false)
            } else {
                await output("Not a directory: \(parseContext.resolvePathArg(path))", isError: true)
            }
        }
    }

    // MARK: - Tool Operations

    private func printToolList(mode: ToolListMode) async throws {
        switch mode {
        case .groupNames:
            await printToolGroupNames()
            return

        case .all:
            let tools = try await session.cachedToolsOrRefresh()
            await printFilteredToolList(tools, groupFilter: nil)

        case let .groups(groups):
            let allTools = try await session.cachedToolsOrRefresh()
            let filtered = ToolGroupCatalog.filter(tools: allTools, groups: groups)
            let groupNames = groups.map(\.rawValue)
            await printFilteredToolList(filtered, groupFilter: groupNames)
        }
    }

    private func printToolGroupNames() async {
        await output("\nAvailable Tool Groups:", isError: false)
        await output(String(repeating: "-", count: 60), isError: false)

        for group in ToolGroup.allCases {
            let description = ToolGroupCatalog.groupDescriptions[group] ?? ""
            await output("  \(group.rawValue)", isError: false)
            if !description.isEmpty {
                await output("    \(description)", isError: false)
            }
        }

        await output("\nUsage: tools <group>        e.g., tools explore", isError: false)
        await output("       tools <g1>,<g2>      e.g., tools explore,edit", isError: false)
    }

    private func printFilteredToolList(_ tools: [MCP.Tool], groupFilter: [String]?) async {
        if tools.isEmpty {
            if let filter = groupFilter {
                await output("No tools found for groups: \(filter.joined(separator: ", "))", isError: false)
            } else {
                await output("No tools available.", isError: false)
            }
            return
        }

        var header = "\nAvailable Tools (\(tools.count))"
        if let filter = groupFilter {
            header += " [\(filter.joined(separator: ", "))]"
        }
        await output("\(header):", isError: false)
        await output(String(repeating: "=", count: 70), isError: false)

        for tool in tools.sorted(by: { $0.name < $1.name }) {
            await output("\n\(tool.name)", isError: false)
            await output(String(repeating: "-", count: 70), isError: false)
            if let description = tool.description, !description.isEmpty {
                await output(description, isError: false)
            }
            // Show full schema
            await output("", isError: false)
            await output(tool.renderSchemaDoc(), isError: false)
        }
    }

    private func printToolsSchemaJSON(mode: ToolListMode) async throws {
        let allTools = try await session.cachedToolsOrRefresh()
        let tools: [MCP.Tool] = switch mode {
        case .groupNames:
            // Not meaningful for JSON schema output; emit all tools
            allTools
        case .all:
            allTools
        case let .groups(groups):
            ToolGroupCatalog.filter(tools: allTools, groups: groups)
        }

        let sorted = tools.sorted { $0.name < $1.name }
        let envelope = ToolsSchemaEnvelope(tools: sorted.map { ToolSnapshot.ToolEntry(from: $0) })

        let encoder = JSONEncoder()
        encoder.outputFormatting = settings.prettyJSON ? [.prettyPrinted, .sortedKeys] : .sortedKeys
        let data = try encoder.encode(envelope)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        await output(json, isError: false)
    }

    private func describeTool(_ name: String) async throws {
        // Resolve alias to actual tool name
        let resolvedName = MCPCommandParser.resolveToolAlias(name)
        let tools = try await session.cachedToolsOrRefresh()
        guard let tool = tools.first(where: { $0.name == resolvedName }) else {
            if resolvedName != name {
                await output("Tool '\(name)' (resolved to '\(resolvedName)') not found. Run 'tools' to see available tools.", isError: true)
            } else {
                await output("Tool '\(name)' not found. Run 'tools' to see available tools.", isError: true)
            }
            return
        }

        let header = resolvedName != name ? "\nTool: \(tool.name) (alias: \(name))" : "\nTool: \(tool.name)"
        await output(header, isError: false)
        await output(String(repeating: "-", count: 60), isError: false)

        if let description = tool.description, !description.isEmpty {
            await output("\nDescription:", isError: false)
            await output(description, isError: false)
        }

        // Render human-readable parameter documentation
        await output("\n" + tool.renderSchemaDoc(), isError: false)

        // Also show raw JSON schema if verbose mode is enabled
        if settings.verbose {
            await output("\nRaw JSON Schema:", isError: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = settings.prettyJSON ? [.prettyPrinted, .sortedKeys] : .sortedKeys
            if let data = try? encoder.encode(tool.inputSchema),
               let json = String(data: data, encoding: .utf8)
            {
                await output(json, isError: false)
            } else {
                await output("\(tool.inputSchema)", isError: false)
            }
        }

        let annotations = tool.annotations
        let hasAnnotations = annotations.title != nil || annotations.readOnlyHint != nil ||
            annotations.destructiveHint != nil || annotations.idempotentHint != nil ||
            annotations.openWorldHint != nil

        if hasAnnotations {
            await output("\nAnnotations:", isError: false)
            if let title = annotations.title {
                await output("  Title: \(title)", isError: false)
            }
            if let readOnly = annotations.readOnlyHint {
                await output("  Read-only: \(readOnly)", isError: false)
            }
            if let destructive = annotations.destructiveHint {
                await output("  Destructive: \(destructive)", isError: false)
            }
            if let idempotent = annotations.idempotentHint {
                await output("  Idempotent: \(idempotent)", isError: false)
            }
            if let openWorld = annotations.openWorldHint {
                await output("  Open-world: \(openWorld)", isError: false)
            }
        }
    }

    private func callTool(name: String, jsonPayload: String?) async throws {
        var args = try MCPCommandParser.parseJSONArgs(jsonPayload)

        // Normalize context_builder instruction aliases (task, prompt, etc. -> instructions)
        if name == "context_builder", var argsDict = args {
            try MCPCommandParser.normalizeContextBuilderArgs(&argsDict)

            // Validate required instructions parameter
            let hasInstructions: Bool = if case let .string(value) = argsDict["instructions"] {
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } else {
                false
            }

            guard hasInstructions else {
                throw CommandParseError.missingArgument(
                    """
                    instructions (required)

                    Usage:
                      call context_builder {"task": "your task"}
                      call context_builder {"instructions": "...", "response_type": "plan"}
                    """
                )
            }

            args = argsDict
        }

        if settings.verbose {
            await output("Calling \(name)...", isError: false)
        }
        let result = try await session.callTool(name: name, arguments: args)
        await printCallResult(result)
        if result.isError == true {
            throw ToolCallFailedError(toolName: name)
        }
    }

    private func callToolWithArgs(name: String, args: [String: UncheckedSendableValue]) async throws {
        // Note: window_id injection for tools like manage_workspaces is now handled
        // by the app's routing layer (MCPConnectionManager.injectWindowIDIfNeeded)
        let valueArgs = try MCPCommandParser.convertToMCPValues(args)
        let result = try await session.callTool(name: name, arguments: valueArgs)
        await printCallResult(result)
        if result.isError == true {
            throw ToolCallFailedError(toolName: name)
        }
    }

    private func snapshotTools(to path: String) async throws {
        let tools = try await session.refreshTools()

        let snapshot = await ToolSnapshot(
            generatedAt: Date(),
            serverName: session.serverName ?? "unknown",
            serverVersion: session.serverVersion ?? "unknown",
            tools: tools.map { ToolSnapshot.ToolEntry(from: $0) }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = settings.prettyJSON ? [.prettyPrinted, .sortedKeys] : .sortedKeys
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(snapshot)

        let url = URL(fileURLWithPath: parseContext.resolvePathArg(path))
        try data.write(to: url)

        await output("Snapshot written to: \(url.path)", isError: false)
        await output("Contains \(tools.count) tools", isError: false)
    }

    // MARK: - Output

    private func printCallResult(_ result: CallTool.Result) async {
        if result.isError == true, !Self.isRawJSONResult(result) {
            await output("Error:", isError: true)
        }

        for content in result.content {
            switch content {
            case let .text(text, _, _):
                await output(text, isError: result.isError == true)
            case let .image(data, mimeType, _, _):
                await output("[Image: \(mimeType), \(data.count) bytes]", isError: false)
            case let .audio(data, mimeType, _, _):
                await output("[Audio: \(mimeType), \(data.count) bytes]", isError: false)
            case let .resource(resource, _, _):
                await output("[Resource: \(resource.uri) (\(resource.mimeType ?? "unknown"))]", isError: false)
                if let text = resource.text {
                    await output(text, isError: false)
                } else if let blob = resource.blob {
                    await output("[Binary resource: \(blob.count) base64 characters]", isError: false)
                }
            case let .resourceLink(uri, name, _, _, mimeType, _):
                await output("[Resource Link: \(name) \(uri) (\(mimeType ?? "unknown"))]", isError: false)
            }
        }
    }

    // MARK: - Raw JSON detection (avoid breaking JSON with prefixes)

    private static func isRawJSONResult(_ result: CallTool.Result) -> Bool {
        guard result.content.count == 1 else { return false }
        guard case let .text(text, _, _) = result.content[0] else { return false }
        return isJSONText(text)
    }

    private static func isJSONText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    private func printStatus() async {
        await output("\n─── Status ───", isError: false)

        // Connection
        let serverInfo = await "\(session.serverName ?? "?") v\(session.serverVersion ?? "?")"
        await output("  Server:     \(serverInfo)", isError: false)

        // Window
        if let wid = await session.selectedWindowID {
            await output("  Window:     w\(wid)", isError: false)
        } else {
            await output("  Window:     none", isError: false)
        }

        // Directory
        await output("  Directory:  \(parseContext.currentDirectory)", isError: false)

        // Tools
        let toolCount = await session.tools().count
        let dirtyNote = await session.toolsDirty ? " (changed)" : ""
        await output("  Tools:      \(toolCount) available\(dirtyNote)", isError: false)

        // Settings summary
        var flags: [String] = []
        if settings.prettyJSON { flags.append("pretty") }
        if settings.colors { flags.append("colors") }
        if settings.verbose { flags.append("verbose") }
        await output("  Settings:   \(flags.joined(separator: ", "))", isError: false)

        await output("──────────────", isError: false)
    }

    private func printSettings() async {
        await output("\nCurrent Settings:", isError: false)
        await output("  pretty   = \(settings.prettyJSON ? "on" : "off")    (JSON formatting)", isError: false)
        await output("  colors   = \(settings.colors ? "on" : "off")    (ANSI colors)", isError: false)
        await output("  verbose  = \(settings.verbose ? "on" : "off")    (Extra output)", isError: false)
    }

    private func printHelp() async {
        let help = """

        ═══════════════════════════════════════════════════════════════
                            CORE WORKFLOW
        ═══════════════════════════════════════════════════════════════

        The tab's file selection is a core part of context for oracle sends.
        The oracle sees what you've selected. Use manage_selection to curate
        selection, or context_builder to auto-select relevant files.

        Manual workflow:
          1. manage_selection (select)    Build file selection manually
          2. oracle_send (chat)            Send message with selection as context

        Auto workflow with context_builder:
          context_builder instructions="task"                      Build selection only
          context_builder instructions="question" response_type=question   → chat
          context_builder instructions="task" response_type=plan           → plan
          builder "task" --response-type plan --export                    → plan file
          context_builder instructions="review" response_type=review       → review

        ═══════════════════════════════════════════════════════════════
                            MCP TOOLS (with shorthand aliases)
        ═══════════════════════════════════════════════════════════════

        Exploration:
          read_file       (read, cat)     Read file contents
          file_search     (search, grep)  Search files by pattern
          get_file_tree   (tree)          Show file/folder tree
          get_code_structure (structure)  Show code signatures

        Selection & Context:
          manage_selection (select)       Curate file selection
          prompt                          Get/set prompt, export, presets
          workspace_context (context)     Get workspace snapshot
          context_builder  (builder)      Auto-build selection + generate response
            instructions/task (required)  What you need help with
            response_type (optional)
              omit/clarify  Build context only (default)
              question      Build context → answer question → return chat_id
              plan          Build context → generate plan → return chat_id
              review        Build context → generate code review → return chat_id
            Use oracle_send with returned chat_id to continue the conversation.
            Examples:
              builder "Find auth code"
              context_builder task="Add logout" response_type=plan
              builder "Add logout" --response-type plan --export
              builder "Review these changes" --type review

        Editing:
          apply_edits                     Search/replace in files (JSON args required)
            Usage: call apply_edits {"path":"...","search":"...","replace":"..."}
            Single edit:  {"path":"...", "search":"...", "replace":"...", "all":true}
            Multi edit:   {"path":"...", "edits":[{"search":"...", "replace":"..."}]}
            Full rewrite: {"path":"...", "rewrite":"content", "on_missing":"create"}
            Options:      "verbose":true to show diff preview
            File input:   call apply_edits @edits.json  or  call apply_edits edits.json
            Auto-repair:  Multiline strings with raw newlines/tabs are auto-escaped
            Note: No shorthand - use 'call apply_edits ...'
          file_actions                    Create/delete/move files
            Usage: call file_actions {"action":"...","path":"..."}
            Create:  {"action":"create", "path":"...", "content":"...", "if_exists":"overwrite"}
            Delete:  {"action":"delete", "path":"/absolute/path/..."}
            Move:    {"action":"move", "path":"...", "new_path":"..."}
            File input:   call file_actions @args.json  or  call file_actions args.json
            Auto-repair:  Multiline strings with raw newlines/tabs are auto-escaped
            Note: No shorthand - use 'call file_actions ...'

        Conversation:
          oracle_send                    Send oracle conversation turn
            message      (required)      The message to send
            new_chat     (bool)          true=start new, false=continue (important!)
            mode         (string)        chat|plan|review
              review mode includes git diffs when published via git artifacts
            Example: oracle_send message="Review this" mode=review new_chat=true
          oracle_utils   (oracle, models, chats)
            op=models                    List available oracle models
            op=sessions                  List recent oracle sessions

        App Settings:
          app_settings                   Read/update allowlisted app-wide preferences
            op=list|get|set|options      Catalog, read, write one key, list candidate values
            group                        ui|prompt_packaging|editing|models|context_builder|mcp|code_maps
            Examples:
              app_settings op=list [group=<g>]
              app_settings op=get key=<k>|group=<g>
              app_settings op=set key=<k> value=<v>
              app_settings op=options key=<k> [agent=<a>]
            Use JSON (`call app_settings {...}`) for fractional numbers or null values.

        Git:
          git             (git)           Safe git abstraction for MCP agents
            Operations:
              git status                  Repository state (branch, staged, modified)
              git diff [--files|--patches|--full]   View changes
              git diff --compare staged   Compare staged changes vs HEAD
              git diff --compare main     Compare vs merge-base with trunk branch
              git log [--count N]         Commit history with stats
              git show <ref>              Single commit details
              git blame <path> --lines 10-40   Line attribution
            Common flags:
              --detail summary|files|patches|full   Detail level for diff/show
              --compare <spec>              Compare spec (staged, uncommitted, mergebase:X, back:N)
                                            main/trunk and *:main use merge-base semantics
              --scope all|selected          Diff scope
              --artifacts                   Write snapshot artifacts (MAP.txt, patches); primary review artifacts auto-select into context

        Routing & Workspaces:
          bind_context                    Discover and bind window/tab routing context
            bind_context op=list          List windows, tabs, and current binding
            bind_context op=list window_id=<id>
                                          Filter listing to a specific window
            bind_context op=status        Show current binding only
            bind_context op=bind context_id=<uuid>
                                          Bind to a specific compose tab (sticky)
            bind_context op=bind window_id=<id>
                                          Set window affinity (follows whichever tab is active)
            bind_context op=bind working_dirs="/path/to/project"
                                          Bind by matching working directory to a tab
            bind_context op=bind working_dirs="..." create_if_missing=true
                                          Same, but create a new workspace if no match
          windows                         Shorthand: bind_context op=list
          use <id>                        Shorthand: bind_context op=bind window_id=<id>
          manage_workspaces (workspace)   Manage workspaces and compose-tab lifecycle
            workspace list                List visible workspaces
            workspace list --include-hidden  Include recoverable hidden workspaces
            workspace hide <name>         Hide from default lists (non-destructive)
            workspace unhide <name>       Restore to default lists
            workspace switch <name>       Switch to workspace in current window
            workspace switch <name> --include-hidden  Switch hidden workspace by name
            workspace switch <name> --new-window  Open workspace in NEW window
            workspace create <name> --switch       Create workspace and switch to it
            workspace create <name> --folder-path <path>  Create workspace with a root folder
            workspace delete <name>       Delete workspace
            workspace delete <name> --include-hidden  Delete hidden workspace by name
            workspace delete <name> --close-window  Delete workspace and close its window
          tabs create|close               manage_workspaces create_tab / close_tab lifecycle

        Agent Control:
          agent_run                       Control Agent Mode runs
            op=start message="..." [model_id=<id>]
                                          Start a new run → returns session_id
                                          defaults to model_id=pair when omitted
                                          model_id: task label (explore, engineer, pair, design)
                                            or specific ID from agent_manage.list_agents
            op=start message="..." detach=true
                                          Start and return immediately without waiting
            op=poll session_id="..."      Poll current run snapshot
            op=poll session_ids=["<uuid1>","<uuid2>"]
                                          Poll multiple snapshots immediately
            op=wait session_id="..." [timeout=N]
                                          Block until input needed or terminal (default \(Int(MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds))s)
            op=wait session_ids=["<uuid1>","<uuid2>"] [timeout=N]
                                          Wait until first session needs input or terminates
            op=cancel session_id="..."    Request run cancellation
            op=steer session_id="..." message="..."
                                          Inject follow-up instruction mid-run
            op=steer session_id="..." message="..." wait=true [timeout_seconds=N]
                                          Steer and wait for result (default \(Int(MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds))s)
            op=respond session_id="..." interaction_id="..." response="..."
                                          Resolve a pending interaction (approval, question, etc)
            session_id lifecycle: start returns it; all other ops require it.
            session_ids is accepted only for wait/poll and is mutually exclusive with session_id.
            Multi-wait returns the winning snapshot at top level plus wait metadata
              (mode, result, winner_session_id, pending_session_ids).
            Multi-poll returns poll metadata plus a snapshots array.
            Responses include failure_reason on failed/cancelled runs
              (process_crash, timeout, agent_error, cancelled).
            MCP-started orchestrate runs can dispatch sub-agents;
              sub-agents cannot recursively start additional agent runs.

          agent_manage                    List agents, manage sessions, browse workflows
            op=list_agents                List agents with model_id values for agent_run
            op=list_sessions [limit=N] [state=<filter>]
                                          List agent sessions (live + persisted)
                                          Filter by state (running, completed, failed, etc)
            op=get_log session_id="..." [offset=N] [limit=N]
                                          Get session transcript (compact XML)
            op=extract_handoff session_id="..." [output_path="/tmp/handoff.xml"]
                                          Export full <forked_session> XML; op=handoff is an alias
            handoff <session_id> --output handoff.xml
                                          CLI shorthand for extract_handoff with file output
            op=create_session [model_id=<id>] [session_name="..."]
                                          Create a new agent session
            op=resume_session session_id="..." [model_id=<id>]
                                          Resume an existing session
            op=stop_session session_id="..."
                                          Stop a live running session
            op=cleanup_sessions session_ids=["<uuid>",...]
                                          Delete specific MCP-originated sessions
                                          Only sessions started via MCP are eligible
            op=list_workflows             List available agent workflows
                                          Includes orchestrate for sub-agent dispatch
            session_id: UUID only (short IDs not supported)

        ═══════════════════════════════════════════════════════════════
                            SHORTHAND SYNTAX
        ═══════════════════════════════════════════════════════════════

        read <path> [start] [limit]       read_file with positional args
        search <pattern> [path]           file_search with options
        tree [path] [--folders]           get_file_tree with options
        select <op> <paths...>            manage_selection operations
        context [--tree] [--files]        workspace_context options
        chat <message> [--mode <m>]       Alias for oracle_send (continues by default)
        plan <message>                    Alias: oracle_send mode=plan new_chat=true
        review <message>                  Alias: oracle_send mode=review new_chat=true
                                          (includes git diffs when published via git artifacts)
        Note: For explicit control, use oracle_send directly with mode= and new_chat=
        workspace <action> [args]         manage_workspaces actions (list/hide/unhide/switch/delete; --include-hidden where supported)
        agent_manage handoff <id> --output handoff.xml
                                          Export <forked_session> XML shorthand
        git <op> [options]                git tool shorthand
        manage_worktree op=<op> ...        Raw worktree management/merge MCP tool

        ═══════════════════════════════════════════════════════════════
                            SYSTEM COMMANDS
        ═══════════════════════════════════════════════════════════════

          tools                           List all MCP tools
          tools <groups>                  Filter by groups (binding,context,explore,git,edit,conversation,settings)
          tools --groups                  List available tool groups
          tools --schema                  Print all tools as JSON with full schemas
          tools <groups> --schema         Print group tools as JSON with schemas
          describe <tool>                 Show tool schema
          call <tool> [json]              Raw tool call with JSON args
            JSON args: inline, @/path/file.json, @-, or path.json

          snapshot <path>                 Save tool list to JSON
          refresh                         Refresh tool list from server

          status                          Quick status overview
          pwd / cd <path>                 Directory navigation
          help / exit                     Help and exit

        ═══════════════════════════════════════════════════════════════
                            EXAMPLES
        ═══════════════════════════════════════════════════════════════

          # Using tool names directly
          call read_file {"path":"main.swift"}
          call file_search {"pattern":"TODO","filter":{"extensions":[".swift"]}}

          # Using shorthand syntax
          read main.swift 100 50
          search "func.*async" --extensions .swift
          select add src/ && context --all
          chat "How does auth work?" --mode plan

          # App settings
          app_settings op=list
          app_settings op=set key=ui.show_tooltips value=false
          call app_settings {"op":"set","key":"models.planning_model","value":null}
          app_settings op=options key=models.planning_model agent=codexExec
          tools settings --schema

          # Git commands
          git status
          git diff --files
          git diff --full --compare staged
          git diff --compare mergebase:origin/main
          git log --count 20
          git show HEAD~1
          git blame src/main.swift --lines 10-40
          git diff --artifacts                 # Write snapshot (MAP.txt, patches)
          manage_worktree op=list include_graph=true graph_limit=8
          manage_worktree op=show worktree_id="<wt_id>"
          manage_worktree op=preview session_id="<uuid>" target="@main"
          tools git --schema

          # Agent control
          agent_manage op=list_agents
          agent_manage op=list_sessions limit=5
          agent_manage op=list_sessions state=failed
          agent_manage op=extract_handoff session_id="<uuid>" output_path="/tmp/handoff.xml"
          agent_manage handoff <uuid> --output handoff.xml
          agent_manage op=cleanup_sessions session_ids=["<uuid1>","<uuid2>"]
          agent_run op=start message="Investigate the auth flow" model_id=engineer
          builder "Implement the plan" --response-type plan --export
          agent_run op=start message="Read the plan at prompt-exports/oracle-plan.md with read_file first. Implement item 1." workflow_name=orchestrate detach=true
          agent_run op=wait session_id="<session-uuid>" timeout=30
          agent_run op=wait session_ids=["<uuid1>","<uuid2>"] timeout=60
          agent_run op=poll session_ids=["<uuid1>","<uuid2>","<uuid3>"]
          agent_run op=steer session_id="<uuid>" message="Now fix it" wait=true
          agent_run op=respond session_id="<session-uuid>" interaction_id="<id>" response="accept"

        ═════════════════════════════════════════════════════════════════
                            OUTPUT REDIRECT
        ═══════════════════════════════════════════════════════════════

          command > file.txt                  Write output to file
          command >> file.txt                 Append output to file
          cmd1 ; cmd2 > out.txt               Redirect captures all segments

        Tip: Use 'describe <tool>' to see full schema for any MCP tool.

        """

        // Conditionally add multi-window routing guidance when multiple windows detected
        var finalHelp = help
        if await session.isMultiWindowModeAvailable() {
            finalHelp += multiWindowRoutingSection()
        }

        await output(finalHelp, isError: false)
    }

    /// Returns the multi-window routing guidance section for help output.
    private func multiWindowRoutingSection() -> String {
        """

        ═══════════════════════════════════════════════════════════════
                        MULTI-WINDOW ROUTING (DETECTED)
        ═══════════════════════════════════════════════════════════════

        Multiple RepoPrompt windows are open. Bind or disambiguate explicitly.

        rpce-cli -e 'windows'                         Discover windows and context_id values
        rpce-cli -w <id> -e 'context'                 Bind a window for this invocation
        rpce-cli --context-id <uuid> -e 'context'     Bind a specific compose context
        rpce-cli -w <id> -t <tab-or-uuid> -e 'context' Resolve/bind a tab in one step

        AI agents SHOULD:
          1. Run 'windows' to discover available windows and context_id values
          2. Prefer --context-id when targeting a specific compose context
          3. Pass -w <id> when working at window scope only

        """
    }

    private func output(_ text: String, isError: Bool) async {
        await outputHandler(text, isError)
    }
}

// MARK: - Exit Command

/// Thrown when exit command is executed.
struct ExitCommandException: Swift.Error {}

/// Thrown when an MCP tool returns CallTool.Result(isError=true).
/// The error output has already been printed; this is used to mark the command as failed.
struct ToolCallFailedError: Swift.Error {
    let toolName: String
}

// MARK: - Tools Schema Envelope (MCP tools/list-style output)

/// Lightweight envelope matching MCP `tools/list` response shape.
/// Used by `--tools-schema` and `tools --schema` to emit machine-readable JSON.
struct ToolsSchemaEnvelope: Codable {
    let tools: [ToolSnapshot.ToolEntry]
}

// MARK: - Tool Snapshot (shared with REPL)

struct ToolSnapshot: Codable {
    let generatedAt: Date
    let serverName: String
    let serverVersion: String
    let tools: [ToolEntry]

    struct ToolEntry: Codable {
        let name: String
        let description: String
        let inputSchema: Value?
        let annotations: AnnotationsEntry?

        init(from tool: MCP.Tool) {
            name = tool.name
            description = tool.description ?? ""
            inputSchema = tool.inputSchema
            let ann = tool.annotations
            let hasAnnotations = ann.title != nil || ann.readOnlyHint != nil ||
                ann.destructiveHint != nil || ann.idempotentHint != nil ||
                ann.openWorldHint != nil
            if hasAnnotations {
                annotations = AnnotationsEntry(from: ann)
            } else {
                annotations = nil
            }
        }
    }

    struct AnnotationsEntry: Codable {
        let title: String?
        let readOnlyHint: Bool?
        let destructiveHint: Bool?
        let idempotentHint: Bool?
        let openWorldHint: Bool?

        init(from ann: MCP.Tool.Annotations) {
            title = ann.title
            readOnlyHint = ann.readOnlyHint
            destructiveHint = ann.destructiveHint
            idempotentHint = ann.idempotentHint
            openWorldHint = ann.openWorldHint
        }
    }
}
