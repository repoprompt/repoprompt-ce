//
//  InteractiveREPL.swift
//  repoprompt-mcp
//
//  Interactive command loop for exploring and calling MCP tools.
//  Uses MCPCommandRunner for execution, adds REPL-specific UI.
//

import Foundation
import MCP

/// Options for interactive mode
struct InteractiveOptions {
    var snapshotPath: String?
    var initialWindowID: Int?
    var prettyJSON: Bool = true
    var rawJSON: Bool = false
    var verbose: Bool = false
    var toolCallTimeoutSeconds: Double?

    // Single-shot command options
    var listToolsOnly: Bool = false
    var listToolsMode: ToolListMode = .all
    var toolsSchemaOnly: Bool = false
    var toolsSchemaMode: ToolListMode = .all
    var describeTool: String?
    var callTool: String?
    var callArgs: String?
}

/// Runtime settings that can be changed during the session
struct REPLSettings {
    var prettyJSON: Bool = true
    var colors: Bool = true
    var verbose: Bool = false
    var timing: Bool = false // Show command execution time
    var outputFile: String? // Temporary redirect for single command
}

/// Interactive REPL for MCP tool exploration
actor InteractiveREPL {
    private let session: InteractiveMCPClientSession
    private let options: InteractiveOptions
    private var isRunning = false

    // Runtime state
    private var settings: REPLSettings
    private var commandHistory: [String] = []
    private var lastCommand: String?
    private var cachedSelectionCount: Int = 0
    private var cachedWorkspaceName: String?
    private var currentDirectory: String // For relative path resolution
    private var lastCommandDuration: TimeInterval = 0
    private var outputSink: OutputSinkState = .stdout
    private var workspaceCacheDirty: Bool = true

    /// Command runner (created on demand)
    private var runner: MCPCommandRunner?

    init(session: InteractiveMCPClientSession, options: InteractiveOptions) {
        self.session = session
        self.options = options
        settings = REPLSettings(prettyJSON: options.prettyJSON, verbose: options.verbose)
        currentDirectory = FileManager.default.currentDirectoryPath
    }

    /// Runs the interactive loop or single-shot command
    func run() async throws {
        // Handle single-shot commands first
        if options.listToolsOnly {
            try await printToolListSingleShot(mode: options.listToolsMode)
            return
        }

        if options.toolsSchemaOnly {
            try await toolsSchemaSingleShot(mode: options.toolsSchemaMode)
            return
        }

        if let toolName = options.describeTool {
            try await describeToolSingleShot(toolName)
            return
        }

        if let toolName = options.callTool {
            try await callToolSingleShot(name: toolName, argsJSON: options.callArgs)
            return
        }

        if let snapshotPath = options.snapshotPath {
            try await snapshotToolsSingleShot(to: snapshotPath)
            return
        }

        // Otherwise run the REPL
        try await runREPL()
    }

    // MARK: - REPL Loop

    private func runREPL() async throws {
        isRunning = true

        await printWelcome()

        // Apply initial window selection if provided
        if let windowID = options.initialWindowID {
            print("Selecting window \(windowID)...")
            let result = try await session.selectWindow(windowID: windowID)
            printCallResult(result)
            workspaceCacheDirty = true
        }

        // Initial status fetch
        await refreshStatusCache()

        while isRunning {
            // Check for tool list changes
            if await session.toolsChangeNoticePending {
                printColored("\n(Tools changed on server - run 'tools' to refresh)", .yellow)
                await session.acknowledgeToolsChanged()
            }

            // Print enhanced prompt
            await printPrompt()

            // Read input
            guard let line = readLine() else {
                // EOF
                break
            }

            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Handle !! (repeat last command)
            if trimmed == "!!" {
                guard let last = lastCommand else {
                    printError("No previous command")
                    continue
                }
                printColored("→ \(last)", .dim)
                trimmed = last
            } else if trimmed.hasPrefix("!"), trimmed.count > 1 {
                // !n to repeat nth command from history
                let indexStr = String(trimmed.dropFirst())
                if let index = Int(indexStr), index > 0, index <= commandHistory.count {
                    trimmed = commandHistory[index - 1]
                    printColored("→ \(trimmed)", .dim)
                } else {
                    printError("Invalid history index. Use 'history' to see commands.")
                    continue
                }
            }

            // Store in history (before potential transformation)
            if trimmed != lastCommand {
                commandHistory.append(trimmed)
                if commandHistory.count > 100 {
                    commandHistory.removeFirst()
                }
            }
            lastCommand = trimmed

            let parsedLine = REPLInputParser.parse(trimmed)
            let redirectPath = parsedLine.outputRedirectPath.map { resolvePathArg($0) }
            settings.outputFile = redirectPath

            var didRedirectOutput = false
            if let redirectPath {
                do {
                    try beginOutputRedirect(to: redirectPath)
                    didRedirectOutput = true
                } catch {
                    printError("Failed to redirect output to '\(redirectPath)': \(error)")
                    settings.outputFile = nil
                }
            }

            let startTime = Date()

            // Parse and execute (supports chaining via ; and &&)
            await executeParsedLine(parsedLine)

            lastCommandDuration = Date().timeIntervalSince(startTime)
            if settings.timing, lastCommandDuration > 0.1 {
                printColored(String(format: "⏱ %.2fs", lastCommandDuration), .dim)
            }

            // Clear temporary redirect and confirm
            endOutputRedirect()
            if didRedirectOutput, let redirectPath {
                printColored("Output written to: \(redirectPath)", .dim)
            }
            settings.outputFile = nil

            await refreshStatusCache()
        }

        print("\nGoodbye!")
    }

    /// Prints the enhanced prompt with status info
    private func printPrompt() async {
        var parts: [String] = []

        // Window indicator
        if let windowID = await session.selectedWindowID {
            parts.append(colorize("w\(windowID)", .cyan))
        }

        // Selection count
        if cachedSelectionCount > 0 {
            parts.append(colorize("s\(cachedSelectionCount)", .green))
        }

        // Workspace name
        if let ws = cachedWorkspaceName {
            parts.append(colorize(ws, .magenta))
        }

        let status = parts.isEmpty ? "" : "[\(parts.joined(separator: " "))] "
        print("\n\(status)\(colorize("mcp", .cyan))\(colorize(">", .white)) ", terminator: "")
        fflush(stdout)
    }

    /// Refreshes cached status info (called periodically)
    private func refreshStatusCache() async {
        await session.syncBindingFromServer()

        // Try to get selection count
        do {
            let result = try await session.callTool(name: "manage_selection", arguments: [
                "op": .string("get"),
                "view": .string("summary")
            ])
            // Parse selection count from result
            if let first = result.content.first, case let .text(text, _, _) = first {
                if let count = parseFileCount(fromManageSelectionSummary: text) {
                    cachedSelectionCount = count
                } else {
                    cachedSelectionCount = 0
                }
            }
        } catch {
            // Silently fail - status is just a nice-to-have
        }

        // Best-effort workspace name cache from bind_context status.
        do {
            let binding = try await session.bindingStatus()
            cachedWorkspaceName = binding.workspaceName
            workspaceCacheDirty = false
        } catch {
            // Ignore
        }
    }

    // MARK: - Command Execution

    private func executeParsedLine(_ parsed: REPLParsedLine) async {
        var ctx = CommandParseContext(currentDirectory: currentDirectory)

        for segment in parsed.segments {
            do {
                let command = try MCPCommandParser.parseCommand(segment.command, ctx: ctx)

                // Handle REPL-specific commands locally
                if try await handleREPLCommand(command, ctx: &ctx) {
                    continue
                }

                // Execute via runner for tool commands
                try await executeCommand(command, ctx: &ctx)

            } catch let error as CommandParseError {
                printError(error.description)
                if case let .unknownCommand(cmd) = error,
                   let suggestion = MCPCommandParser.suggestCommand(for: cmd)
                {
                    printColored("Did you mean: \(suggestion)?", .dim)
                }
                if segment.separatorAfter == .onSuccess {
                    break
                }
            } catch is ExitCommandException {
                isRunning = false
                return
            } catch {
                printError("\(error)")
                if segment.separatorAfter == .onSuccess {
                    break
                }
            }
        }

        // Sync directory changes back
        currentDirectory = ctx.currentDirectory
    }

    /// Handles REPL-specific commands that don't go through the runner.
    /// Returns true if the command was handled.
    private func handleREPLCommand(_ command: InteractiveCommand, ctx: inout CommandParseContext) async throws -> Bool {
        switch command {
        case .history:
            printHistory()
            return true

        case .showSettings:
            printSettings()
            return true

        case let .setSetting(name, value):
            applySetting(name: name, value: value)
            return true

        case .clearScreen:
            print("\u{001B}[2J\u{001B}[H", terminator: "")
            fflush(stdout)
            return true

        case .exit:
            throw ExitCommandException()

        default:
            return false
        }
    }

    private func executeCommand(_ command: InteractiveCommand, ctx: inout CommandParseContext) async throws {
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
            printCallResult(result)

        case let .useWindow(windowID):
            let result = try await session.selectWindow(windowID: windowID)
            printCallResult(result)
            workspaceCacheDirty = true

        case .clearWindow:
            let result = try await session.clearWindowSelection()
            printCallResult(result)
            cachedWorkspaceName = nil

        case let .snapshot(path):
            try await snapshotTools(to: path)

        case .refresh:
            let tools = try await session.refreshTools()
            print("Refreshed: \(tools.count) tools available")

        case .status:
            await printStatus()

        case .pwd:
            print(ctx.currentDirectory)

        case let .cd(path):
            if ctx.changeDirectory(to: path) {
                print(ctx.currentDirectory)
            } else {
                printError("Not a directory: \(ctx.resolvePathArg(path))")
            }

        case .history, .showSettings, .setSetting, .clearScreen, .exit:
            // These are handled in handleREPLCommand
            break
        }
    }

    // MARK: - Path Resolution (delegates to context)

    private func resolvePathArg(_ arg: String) -> String {
        let ctx = CommandParseContext(currentDirectory: currentDirectory)
        return ctx.resolvePathArg(arg)
    }

    // MARK: - History & Settings

    private func printHistory() {
        if commandHistory.isEmpty {
            print("No command history.")
            return
        }
        print(colorize("\nCommand History:", .bold))
        for (i, cmd) in commandHistory.enumerated() {
            let num = String(format: "%3d", i + 1)
            print("  \(colorize(num, .dim))  \(cmd)")
        }
        print(colorize("\nTip: Use !n to repeat command n, !! for last command", .dim))
    }

    private func printSettings() {
        print(colorize("\nCurrent Settings:", .bold))
        print("  \(colorize("pretty", .cyan))   = \(settings.prettyJSON ? "on" : "off")    (JSON formatting)")
        print("  \(colorize("colors", .cyan))   = \(settings.colors ? "on" : "off")    (ANSI colors)")
        print("  \(colorize("verbose", .cyan))  = \(settings.verbose ? "on" : "off")    (Extra output)")
        print("  \(colorize("timing", .cyan))   = \(settings.timing ? "on" : "off")    (Show command duration)")
        print(colorize("\nUse 'set <name> on|off' to change", .dim))
    }

    private func applySetting(name: String, value: String?) {
        let isOn = value == "on" || value == "true" || value == "1" || value == "yes"
        let isOff = value == "off" || value == "false" || value == "0" || value == "no"

        switch name {
        case "pretty", "json":
            if isOn { settings.prettyJSON = true }
            else if isOff { settings.prettyJSON = false }
            else { settings.prettyJSON.toggle() }
            print("pretty = \(settings.prettyJSON ? "on" : "off")")

        case "colors", "color":
            if isOn { settings.colors = true }
            else if isOff { settings.colors = false }
            else { settings.colors.toggle() }
            print("colors = \(settings.colors ? "on" : "off")")

        case "verbose", "v":
            if isOn { settings.verbose = true }
            else if isOff { settings.verbose = false }
            else { settings.verbose.toggle() }
            print("verbose = \(settings.verbose ? "on" : "off")")

        case "timing", "time", "t":
            if isOn { settings.timing = true }
            else if isOff { settings.timing = false }
            else { settings.timing.toggle() }
            print("timing = \(settings.timing ? "on" : "off")")

        default:
            printError("Unknown setting: \(name). Use 'set' to see available settings.")
        }
    }

    // MARK: - Tool Operations

    private func printToolList(mode: ToolListMode) async throws {
        switch mode {
        case .groupNames:
            printToolGroupNames()
            return

        case .all:
            let tools = try await session.cachedToolsOrRefresh()
            printFilteredToolList(tools, groupFilter: nil)

        case let .groups(groups):
            let allTools = try await session.cachedToolsOrRefresh()
            let filtered = ToolGroupCatalog.filter(tools: allTools, groups: groups)
            let groupNames = groups.map(\.rawValue)
            printFilteredToolList(filtered, groupFilter: groupNames)
        }
    }

    private func printToolGroupNames() {
        print(colorize("\nAvailable Tool Groups:", .bold))
        print(String(repeating: "-", count: 60))

        for group in ToolGroup.allCases {
            let description = ToolGroupCatalog.groupDescriptions[group] ?? ""
            print("  \(colorize(group.rawValue, .green))")
            if !description.isEmpty {
                print("    \(description)")
            }
        }

        print(colorize("\nUsage: tools <group>        e.g., tools explore", .dim))
        print(colorize("       tools <g1>,<g2>      e.g., tools explore,edit", .dim))
        print(colorize("       tools settings --schema", .dim))
    }

    private func printFilteredToolList(_ tools: [MCP.Tool], groupFilter: [String]?) {
        if tools.isEmpty {
            if let filter = groupFilter {
                print("No tools found for groups: \(filter.joined(separator: ", "))")
            } else {
                print("No tools available.")
            }
            return
        }

        var header = "\nAvailable Tools (\(tools.count))"
        if let filter = groupFilter {
            header += " [\(filter.joined(separator: ", "))]"
        }
        print(colorize("\(header):", .bold))
        print(String(repeating: "=", count: 70))

        for tool in tools.sorted(by: { $0.name < $1.name }) {
            print("\n\(colorize(tool.name, .green))")
            print(String(repeating: "-", count: 70))
            if let description = tool.description, !description.isEmpty {
                print(description)
            }
            // Show full schema
            print("")
            print(tool.renderSchemaDoc())
        }
    }

    private func printToolsSchemaJSON(mode: ToolListMode) async throws {
        let tools: [MCP.Tool]
        switch mode {
        case .groupNames:
            tools = try await session.cachedToolsOrRefresh()
        case .all:
            tools = try await session.cachedToolsOrRefresh()
        case let .groups(groups):
            let allTools = try await session.cachedToolsOrRefresh()
            tools = ToolGroupCatalog.filter(tools: allTools, groups: groups)
        }

        let sorted = tools.sorted { $0.name < $1.name }
        let envelope = ToolsSchemaEnvelope(tools: sorted.map { ToolSnapshot.ToolEntry(from: $0) })

        let encoder = JSONEncoder()
        encoder.outputFormatting = settings.prettyJSON ? [.prettyPrinted, .sortedKeys] : .sortedKeys
        let data = try encoder.encode(envelope)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        output(json)
    }

    private func describeTool(_ name: String) async throws {
        // Resolve alias to actual tool name
        let resolvedName = MCPCommandParser.resolveToolAlias(name)
        let tools = try await session.cachedToolsOrRefresh()
        guard let tool = tools.first(where: { $0.name == resolvedName }) else {
            if resolvedName != name {
                printError("Tool '\(name)' (resolved to '\(resolvedName)') not found. Run 'tools' to see available tools.")
            } else {
                printError("Tool '\(name)' not found. Run 'tools' to see available tools.")
            }
            return
        }

        let header = resolvedName != name ? "\nTool: \(tool.name) (alias: \(name))" : "\nTool: \(tool.name)"
        print(colorize(header, .bold))
        print(String(repeating: "-", count: 60))

        if let description = tool.description, !description.isEmpty {
            print(colorize("\nDescription:", .underline))
            print(description)
        }

        // Render human-readable parameter documentation
        print("")
        print(tool.renderSchemaDoc())

        // Also show raw JSON schema if verbose mode is enabled
        if settings.verbose {
            print(colorize("\nRaw JSON Schema:", .underline))
            let encoder = JSONEncoder()
            encoder.outputFormatting = settings.prettyJSON ? [.prettyPrinted, .sortedKeys] : .sortedKeys
            if let data = try? encoder.encode(tool.inputSchema),
               let json = String(data: data, encoding: .utf8)
            {
                print(json)
            } else {
                print("\(tool.inputSchema)")
            }
        }

        let annotations = tool.annotations
        let hasAnnotations = annotations.title != nil || annotations.readOnlyHint != nil ||
            annotations.destructiveHint != nil || annotations.idempotentHint != nil ||
            annotations.openWorldHint != nil

        if hasAnnotations {
            print(colorize("\nAnnotations:", .underline))
            if let title = annotations.title {
                print("  Title: \(title)")
            }
            if let readOnly = annotations.readOnlyHint {
                print("  Read-only: \(readOnly)")
            }
            if let destructive = annotations.destructiveHint {
                print("  Destructive: \(destructive)")
            }
            if let idempotent = annotations.idempotentHint {
                print("  Idempotent: \(idempotent)")
            }
            if let openWorld = annotations.openWorldHint {
                print("  Open-world: \(openWorld)")
            }
        }
    }

    private func callTool(name: String, jsonPayload: String?) async throws {
        let args = try MCPCommandParser.parseJSONArgs(jsonPayload)

        print("Calling \(name)...")
        let result = try await session.callTool(name: name, arguments: args)
        printCallResult(result)
    }

    private func callToolWithArgs(name: String, args: [String: UncheckedSendableValue]) async throws {
        let valueArgs = try MCPCommandParser.convertToMCPValues(args)
        let result = try await session.callTool(name: name, arguments: valueArgs)
        printCallResult(result)
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

        let url = URL(fileURLWithPath: resolvePathArg(path))
        try data.write(to: url)

        print("Snapshot written to: \(url.path)")
        print("Contains \(tools.count) tools")
    }

    // MARK: - Single-Shot Operations

    private func printToolListSingleShot(mode: ToolListMode) async throws {
        switch mode {
        case .groupNames:
            printToolGroupNamesSingleShot()
            return

        case .all:
            let tools = try await session.cachedToolsOrRefresh()
            printFilteredToolListSingleShot(tools, groupFilter: nil)

        case let .groups(groups):
            let allTools = try await session.cachedToolsOrRefresh()
            let filtered = ToolGroupCatalog.filter(tools: allTools, groups: groups)
            let groupNames = groups.map(\.rawValue)
            printFilteredToolListSingleShot(filtered, groupFilter: groupNames)
        }
    }

    private func printToolGroupNamesSingleShot() {
        print("Available Tool Groups:")
        for group in ToolGroup.allCases {
            let description = ToolGroupCatalog.groupDescriptions[group] ?? ""
            print("  \(group.rawValue)")
            if !description.isEmpty {
                print("    \(description)")
            }
        }
        print("\nUsage: --list-tools=<group>   e.g., --list-tools=explore")
        print("       --list-tools=<g1>,<g2> e.g., --list-tools=explore,edit")
        print("       --tools-schema=settings")
    }

    private func printFilteredToolListSingleShot(_ tools: [MCP.Tool], groupFilter: [String]?) {
        if tools.isEmpty {
            if let filter = groupFilter {
                print("No tools found for groups: \(filter.joined(separator: ", "))")
            } else {
                print("No tools available.")
            }
            return
        }

        var header = "Available Tools (\(tools.count))"
        if let filter = groupFilter {
            header += " [\(filter.joined(separator: ", "))]"
        }
        print("\(header):")
        print(String(repeating: "=", count: 70))

        for tool in tools.sorted(by: { $0.name < $1.name }) {
            print("\n\(tool.name)")
            print(String(repeating: "-", count: 70))
            if let description = tool.description, !description.isEmpty {
                print(description)
            }
            // Show full schema
            print("")
            print(tool.renderSchemaDoc())
        }
    }

    private func describeToolSingleShot(_ name: String) async throws {
        // Resolve alias to actual tool name
        let resolvedName = MCPCommandParser.resolveToolAlias(name)
        let tools = try await session.cachedToolsOrRefresh()
        guard let tool = tools.first(where: { $0.name == resolvedName }) else {
            if resolvedName != name {
                printError("Tool '\(name)' (resolved to '\(resolvedName)') not found.")
            } else {
                printError("Tool '\(name)' not found.")
            }
            return
        }

        print("Tool: \(tool.name)")
        if let description = tool.description, !description.isEmpty {
            print("\nDescription:")
            print(description)
        }

        // Render human-readable parameter documentation
        print("")
        print(tool.renderSchemaDoc())

        // Also show raw JSON schema if verbose mode is enabled
        if settings.verbose {
            print("\nRaw JSON Schema:")
            let encoder = JSONEncoder()
            encoder.outputFormatting = settings.prettyJSON ? [.prettyPrinted, .sortedKeys] : .sortedKeys
            if let data = try? encoder.encode(tool.inputSchema),
               let json = String(data: data, encoding: .utf8)
            {
                print(json)
            }
        }

        // Show annotations
        let annotations = tool.annotations
        let hasAnnotations = annotations.title != nil || annotations.readOnlyHint != nil ||
            annotations.destructiveHint != nil || annotations.idempotentHint != nil ||
            annotations.openWorldHint != nil

        if hasAnnotations {
            print("\nAnnotations:")
            if let title = annotations.title {
                print("  Title: \(title)")
            }
            if let readOnly = annotations.readOnlyHint {
                print("  Read-only: \(readOnly)")
            }
            if let destructive = annotations.destructiveHint {
                print("  Destructive: \(destructive)")
            }
            if let idempotent = annotations.idempotentHint {
                print("  Idempotent: \(idempotent)")
            }
            if let openWorld = annotations.openWorldHint {
                print("  Open-world: \(openWorld)")
            }
        }
    }

    private func callToolSingleShot(name: String, argsJSON: String?) async throws {
        let args = try MCPCommandParser.parseJSONArgs(argsJSON)
        let result = try await session.callTool(name: name, arguments: args)
        printCallResultPlain(result)

        // Ensure --call exits non-zero on tool failure
        if result.isError == true {
            throw ExecError.commandFailed
        }
    }

    private func toolsSchemaSingleShot(mode: ToolListMode) async throws {
        let tools: [MCP.Tool]
        switch mode {
        case .groupNames, .all:
            tools = try await session.cachedToolsOrRefresh()
        case let .groups(groups):
            let allTools = try await session.cachedToolsOrRefresh()
            tools = ToolGroupCatalog.filter(tools: allTools, groups: groups)
        }

        let sorted = tools.sorted { $0.name < $1.name }
        let envelope = ToolsSchemaEnvelope(tools: sorted.map { ToolSnapshot.ToolEntry(from: $0) })

        let encoder = JSONEncoder()
        encoder.outputFormatting = options.prettyJSON ? [.prettyPrinted, .sortedKeys] : .sortedKeys
        let data = try encoder.encode(envelope)
        if let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }

    private func snapshotToolsSingleShot(to path: String) async throws {
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

        let url = URL(fileURLWithPath: path)
        try data.write(to: url)

        print("Snapshot written to: \(url.path)")
        print("Contains \(tools.count) tools")
    }

    // MARK: - Status

    private func printStatus() async {
        print(colorize("\n─── Status ───", .bold))

        // Connection
        let serverInfo = await "\(session.serverName ?? "?") v\(session.serverVersion ?? "?")"
        print("  Server:     \(colorize(serverInfo, .cyan))")

        // Window
        if let wid = await session.selectedWindowID {
            print("  Window:     \(colorize("w\(wid)", .green))")
        } else {
            print("  Window:     \(colorize("none", .dim))")
        }

        // Selection
        print("  Selection:  \(colorize("\(cachedSelectionCount) files", cachedSelectionCount > 0 ? .green : .dim))")

        // Directory
        print("  Directory:  \(colorize(currentDirectory, .blue))")

        // Tools
        let toolCount = await session.tools().count
        let dirtyNote = await session.toolsDirty ? colorize(" (changed)", .yellow) : ""
        print("  Tools:      \(toolCount) available\(dirtyNote)")

        // History
        print("  History:    \(commandHistory.count) commands")

        // Settings summary
        var flags: [String] = []
        if settings.prettyJSON { flags.append("pretty") }
        if settings.colors { flags.append("colors") }
        if settings.timing { flags.append("timing") }
        if settings.verbose { flags.append("verbose") }
        print("  Settings:   \(flags.joined(separator: ", "))")

        print(colorize("──────────────", .bold))
    }

    // MARK: - Output Formatting

    private func printCallResult(_ result: CallTool.Result) {
        if result.isError == true, !Self.isRawJSONResult(result) {
            printColored("Error:", .red)
        }

        for content in result.content {
            switch content {
            case let .text(text, _, _):
                output(text)
            case let .image(data, mimeType, _, _):
                output("[Image: \(mimeType), \(data.count) bytes]")
            case let .audio(data, mimeType, _, _):
                output("[Audio: \(mimeType), \(data.count) bytes]")
            case let .resource(resource, _, _):
                output("[Resource: \(resource.uri) (\(resource.mimeType ?? "unknown"))]")
                if let text = resource.text {
                    output(text)
                } else if let blob = resource.blob {
                    output("[Binary resource: \(blob.count) base64 characters]")
                }
            case let .resourceLink(uri, name, _, _, mimeType, _):
                output("[Resource Link: \(name) \(uri) (\(mimeType ?? "unknown"))]")
            }
        }
    }

    private func printCallResultPlain(_ result: CallTool.Result) {
        if result.isError == true, !Self.isRawJSONResult(result) {
            fputs("Error:\n", stderr)
        }

        for content in result.content {
            switch content {
            case let .text(text, _, _):
                print(text)
            case let .image(data, mimeType, _, _):
                print("[Image: \(mimeType), \(data.count) bytes]")
            case let .audio(data, mimeType, _, _):
                print("[Audio: \(mimeType), \(data.count) bytes]")
            case let .resource(resource, _, _):
                print("[Resource: \(resource.uri) (\(resource.mimeType ?? "unknown"))]")
                if let text = resource.text {
                    print(text)
                } else if let blob = resource.blob {
                    print("[Binary resource: \(blob.count) base64 characters]")
                }
            case let .resourceLink(uri, name, _, _, mimeType, _):
                print("[Resource Link: \(name) \(uri) (\(mimeType ?? "unknown"))]")
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

    private func printWelcome() async {
        let serverName = await session.serverName ?? "unknown"
        let serverVersion = await session.serverVersion ?? "?"
        let banner = """
        \u{001B}[1m
        ╔══════════════════════════════════════════════════════════╗
        ║          RepoPrompt MCP Interactive Mode                 ║
        ╚══════════════════════════════════════════════════════════╝
        \u{001B}[0m
        Connected to: \(serverName) v\(serverVersion)

        Type 'help' for available commands, 'exit' to quit.
        """
        print(maybeStripANSI(banner))
    }

    private func printHelp() async {
        let help = """

        \u{001B}[1m═══════════════════════════════════════════════════════════════\u{001B}[0m
        \u{001B}[1m                    SHELL-LIKE COMMANDS                         \u{001B}[0m
        \u{001B}[1m═══════════════════════════════════════════════════════════════\u{001B}[0m

        \u{001B}[4mFiles & Search:\u{001B}[0m
          \u{001B}[32mread\u{001B}[0m <path> [start] [limit]    Read a file (alias: cat)
          \u{001B}[32msearch\u{001B}[0m <pattern> [path]        Search for pattern (alias: grep, find)
          \u{001B}[32mtree\u{001B}[0m [path] [--folders]        Show file tree
          \u{001B}[32mstructure\u{001B}[0m <path> ...           Show code structure (alias: struct, map)

        \u{001B}[4mSelection:\u{001B}[0m
          \u{001B}[32mselect\u{001B}[0m add <paths...> [--codemap]
                                          Add files to selection
          \u{001B}[32mselect\u{001B}[0m remove <paths...>       Remove files from selection
          \u{001B}[32mselect\u{001B}[0m set <paths...> [--codemap]
                                          Replace selection
          \u{001B}[32mselect\u{001B}[0m clear                   Clear selection
          \u{001B}[32mselect\u{001B}[0m get [--files|--content] View current selection
          \u{001B}[32mselect\u{001B}[0m promote/demote <paths>  Toggle full↔codemap mode
          \u{001B}[32mselect\u{001B}[0m <paths...> [--codemap]  Quick add (shortcut)

        \u{001B}[4mContext & Prompt:\u{001B}[0m
          \u{001B}[32mcontext\u{001B}[0m [--tree] [--files]     Get workspace context (alias: ctx)
          \u{001B}[32mbuilder\u{001B}[0m [instructions]         Run context builder
                                          Example: builder "add logout" --response-type plan --export
          \u{001B}[32mprompt\u{001B}[0m                         Show current prompt
          \u{001B}[32mprompt\u{001B}[0m set <text>              Set prompt text
          \u{001B}[32mprompt\u{001B}[0m append <text>           Append to prompt
          \u{001B}[32mprompt\u{001B}[0m clear                   Clear prompt

        \u{001B}[4mEditing:\u{001B}[0m
          \u{001B}[32mcall apply_edits\u{001B}[0m {...}         Find/replace (JSON args required)
                                          Example: call apply_edits {"path":"f.ts","search":"old","replace":"new"}
                                          File:    call apply_edits @edits.json  or  call apply_edits edits.json
                                          Stdin:   echo '...' | rpce-cli -c apply_edits -j @-
                                          Auto-repair: raw newlines/tabs in strings are auto-escaped

        \u{001B}[4mConversation:\u{001B}[0m
          \u{001B}[32mchat\u{001B}[0m <message>                 Send message to current oracle session
          \u{001B}[32mnewchat\u{001B}[0m <message>              Start new oracle session with message
          \u{001B}[32mplan\u{001B}[0m <message>                 Send as plan request
          \u{001B}[32mchats\u{001B}[0m                          Compatibility alias for recent sessions
          \u{001B}[32moracle\u{001B}[0m sessions                List recent oracle sessions
          \u{001B}[32mmodels\u{001B}[0m                         List available oracle models

        \u{001B}[4mAgent Control (advanced, policy-gated):\u{001B}[0m
          \u{001B}[32magent_run\u{001B}[0m op=start message="..."   Start agent run → session_id
                                          Plan path goes inside message: "Read the plan at prompt-exports/... with read_file first."
          \u{001B}[32magent_run\u{001B}[0m op=wait session_id="..." [timeout=N]
                                          Block until input/terminal (optional timeout in seconds)
          \u{001B}[32magent_run\u{001B}[0m op=wait session_ids=["<id1>","<id2>"] [timeout=N]
                                          Wait for first of multiple sessions to need attention
          \u{001B}[32magent_run\u{001B}[0m op=poll session_id="..."  Poll run snapshot
          \u{001B}[32magent_run\u{001B}[0m op=poll session_ids=["<id1>","<id2>"]
                                          Poll multiple snapshots immediately
          \u{001B}[32magent_run\u{001B}[0m op=steer session_id="..." message="..."
                                          Send follow-up instruction
          \u{001B}[32magent_run\u{001B}[0m op=respond session_id="..." interaction_id="..." response="..."
                                          Respond to pending interaction
          \u{001B}[32magent_run\u{001B}[0m op=cancel session_id="..." Cancel run
          session_id and session_ids are mutually exclusive; session_ids is wait/poll only.
          Multi-wait returns wait metadata; multi-poll returns poll metadata + snapshots.
          \u{001B}[32magent_manage\u{001B}[0m op=list_agents        List agent providers
          \u{001B}[32magent_manage\u{001B}[0m op=list_sessions      List sessions
          \u{001B}[32magent_manage\u{001B}[0m op=get_log session_id="..."
                                          Get session transcript
          \u{001B}[32magent_manage\u{001B}[0m op=extract_handoff session_id="..." output_path="/tmp/handoff.xml"
                                          Export full <forked_session> XML; op=handoff is an alias
          \u{001B}[32magent_manage\u{001B}[0m handoff <id> --output handoff.xml
                                          CLI shorthand for extract_handoff with file output
          \u{001B}[32magent_manage\u{001B}[0m op=create_session     Create new session
          \u{001B}[32magent_manage\u{001B}[0m op=resume_session session_id="..."
                                          Resume existing session
          \u{001B}[32magent_manage\u{001B}[0m op=stop_session session_id="..."
                                          Stop/cancel a live session
          \u{001B}[32magent_manage\u{001B}[0m op=list_workflows     List workflows
          Use \u{001B}[32mdescribe agent_run\u{001B}[0m / \u{001B}[32mdescribe agent_manage\u{001B}[0m for full schemas.

        \u{001B}[4mApp Settings:\u{001B}[0m
          \u{001B}[32mapp_settings\u{001B}[0m op=list                List allowlisted app-wide preferences (includes current values)
          \u{001B}[32mapp_settings\u{001B}[0m op=list group=ui       List UI settings
          \u{001B}[32mapp_settings\u{001B}[0m op=get key=ui.appearance_mode
                                          Get one setting
          \u{001B}[32mapp_settings\u{001B}[0m op=set key=ui.show_tooltips value=false
                                          Set a boolean value
          \u{001B}[32mcall app_settings\u{001B}[0m {"op":"set","key":"models.temperature","value":1.25}
                                          Use JSON for fractional numbers/null values
          Groups: ui, prompt_packaging, editing, models, mcp, code_maps
          Excludes credentials, ACLs, approvals, agent permissions, and sensitive/internal settings.

        \u{001B}[4mWorkspaces:\u{001B}[0m
          \u{001B}[32mworkspace\u{001B}[0m                       List visible workspaces (alias: ws)
          \u{001B}[32mworkspace\u{001B}[0m list --include-hidden Include recoverable hidden workspaces
          \u{001B}[32mworkspace\u{001B}[0m hide <name>           Hide from default lists (non-destructive)
          \u{001B}[32mworkspace\u{001B}[0m unhide <name>         Restore to default lists
          \u{001B}[32mworkspace\u{001B}[0m <name>                Switch to workspace
          \u{001B}[32mworkspace\u{001B}[0m <name> --include-hidden  Switch hidden workspace by name
          \u{001B}[32mworkspace\u{001B}[0m <name> --new-window   Open workspace in NEW window
          \u{001B}[32mworkspace\u{001B}[0m create <name> --new-window   Create workspace in NEW window
          \u{001B}[32mworkspace\u{001B}[0m create <name> --switch       Create workspace and switch to it
          \u{001B}[32mworkspace\u{001B}[0m create <name> --folder-path <path>  Create workspace with a root folder
          \u{001B}[32mwindows\u{001B}[0m                         List windows and context_id values
          \u{001B}[32muse\u{001B}[0m <id>                        Bind a window for this REPL session
          \u{001B}[32mtabs\u{001B}[0m list                       List tabs via bind_context
          \u{001B}[32mworkspace\u{001B}[0m create <name>         Create new workspace
          \u{001B}[32mworkspace\u{001B}[0m add-folder <path>     Add folder to workspace
          \u{001B}[32mworkspace\u{001B}[0m remove-folder <path>  Remove folder from workspace
          \u{001B}[32mworkspace\u{001B}[0m delete <name>         Delete workspace
          \u{001B}[32mworkspace\u{001B}[0m delete <name> --include-hidden  Delete hidden workspace by name
          \u{001B}[32mworkspace\u{001B}[0m delete <name> --close-window  Delete workspace and close its window
          \u{001B}[32mmodels\u{001B}[0m                          List available models

        \u{001B}[1m═══════════════════════════════════════════════════════════════\u{001B}[0m
        \u{001B}[1m                    SYSTEM COMMANDS                             \u{001B}[0m
        \u{001B}[1m═══════════════════════════════════════════════════════════════\u{001B}[0m

          \u{001B}[32mtools\u{001B}[0m                           List all MCP tools (alias: ls)
          \u{001B}[32mtools\u{001B}[0m <groups>                  Filter by groups (e.g., explore,edit,settings)
          \u{001B}[32mtools\u{001B}[0m --groups                  List available tool groups
          \u{001B}[32mtools\u{001B}[0m --schema                  Print all tools as JSON with full schemas
          \u{001B}[32mtools\u{001B}[0m <groups> --schema         Print group tools as JSON with schemas
          \u{001B}[32mdescribe\u{001B}[0m <tool>                 Show tool schema (alias: desc, d)
          \u{001B}[32mcall\u{001B}[0m <tool> [json]              Raw tool call with JSON args
            JSON args: inline, @/path/file.json, @-, or path.json

          \u{001B}[32mwindows\u{001B}[0m                         List windows (multi-window only)
          \u{001B}[32muse\u{001B}[0m <id>                        Select window (multi-window only)

          \u{001B}[32msnapshot\u{001B}[0m <path>                 Save tool list to JSON
          \u{001B}[32mrefresh\u{001B}[0m                         Refresh tool list from server

          \u{001B}[32mstatus\u{001B}[0m                          Quick status overview (alias: st)
          \u{001B}[32mpwd\u{001B}[0m                             Show current directory
          \u{001B}[32mcd\u{001B}[0m <path>                       Change directory for relative paths

          \u{001B}[32mhistory\u{001B}[0m                         Show command history (alias: hist)
          \u{001B}[32mset\u{001B}[0m [name] [on|off]             View/change settings
          \u{001B}[32mclear\u{001B}[0m                           Clear screen (alias: cls)

          \u{001B}[32mhelp\u{001B}[0m                            Show this help (alias: ?, h)
          \u{001B}[32mexit\u{001B}[0m                            Exit (alias: quit, q)

        \u{001B}[1m═══════════════════════════════════════════════════════════════\u{001B}[0m
        \u{001B}[1m                    EXAMPLES                                    \u{001B}[0m
        \u{001B}[1m═══════════════════════════════════════════════════════════════\u{001B}[0m

          read ~/code/main.swift              # Read a file
          read ~/code/main.swift 100 50       # Read lines 100-150
          search "func.*async" ~/code         # Regex search in directory
          tree --folders                      # Show folder structure only
          select add src/main.swift tests/    # Add files to selection
          context --all                       # Full workspace snapshot
          workspace list --include-hidden     # Include recoverable hidden workspaces
          agent_manage handoff <uuid> --output handoff.xml  # Export <forked_session> XML
          chat How does the auth flow work?   # Quick chat question
          edit main.swift TODO DONE --all     # Replace all occurrences
          app_settings op=get key=ui.appearance_mode  # Read app preference
          tools settings --schema             # app_settings schema as JSON

          !!                                  # Repeat last command
          !5                                  # Repeat command #5 from history
          read file.txt > output.txt          # Redirect output to file
          set colors off                      # Disable colored output
          set timing on                       # Show command duration
          cd ~/code && read main.swift        # Change dir, then read file
          status                              # Show session status

        \u{001B}[2mTip: Relative paths resolve from 'pwd'. Use 'call' for tools without aliases.\u{001B}[0m

        """

        // Conditionally add multi-window routing guidance when multiple windows detected
        var finalHelp = help
        if await session.isMultiWindowModeAvailable() {
            finalHelp += multiWindowRoutingHelpSection()
        }

        print(maybeStripANSI(finalHelp))
    }

    /// Returns ANSI-styled multi-window routing guidance section.
    private func multiWindowRoutingHelpSection() -> String {
        """

        \u{001B}[1;33m═══════════════════════════════════════════════════════════════\u{001B}[0m
        \u{001B}[1;33m                MULTI-WINDOW ROUTING (DETECTED)                 \u{001B}[0m
        \u{001B}[1;33m═══════════════════════════════════════════════════════════════\u{001B}[0m

        \u{001B}[1;31mMultiple RepoPrompt windows are open. Bind or disambiguate explicitly.\u{001B}[0m

        rpce-cli -e 'windows'                            \u{001B}[2mDiscover windows and context_id values\u{001B}[0m
        rpce-cli \u{001B}[33m-w <id>\u{001B}[0m -e 'context'                    \u{001B}[2mBind a window for this invocation\u{001B}[0m
        rpce-cli \u{001B}[33m--context-id <uuid>\u{001B}[0m -e 'context'        \u{001B}[2mBind a compose context directly\u{001B}[0m
        rpce-cli \u{001B}[33m-w <id> -t <tab-or-uuid>\u{001B}[0m -e 'context'   \u{001B}[2mResolve/bind a tab in one step\u{001B}[0m

        \u{001B}[2mAI agents SHOULD:
          1. Run 'windows' to discover available windows and context_id values
          2. Prefer --context-id when targeting a specific compose context
          3. Pass -w <id> when working at window scope only\u{001B}[0m

        """
    }

    private func printError(_ message: String) {
        fputs(colorize("Error: \(message)", .red) + "\n", stderr)
    }

    // MARK: - Color Helpers

    enum ANSIColor {
        case red, green, yellow, blue, magenta, cyan, white
        case bold, dim, underline
        case reset

        var code: String {
            switch self {
            case .red: "\u{001B}[31m"
            case .green: "\u{001B}[32m"
            case .yellow: "\u{001B}[33m"
            case .blue: "\u{001B}[34m"
            case .magenta: "\u{001B}[35m"
            case .cyan: "\u{001B}[36m"
            case .white: "\u{001B}[37m"
            case .bold: "\u{001B}[1m"
            case .dim: "\u{001B}[2m"
            case .underline: "\u{001B}[4m"
            case .reset: "\u{001B}[0m"
            }
        }
    }

    private func colorize(_ text: String, _ color: ANSIColor) -> String {
        guard settings.colors else { return text }
        return "\(color.code)\(text)\(ANSIColor.reset.code)"
    }

    private func maybeStripANSI(_ s: String) -> String {
        guard !settings.colors else { return s }
        // Strip common SGR sequences (e.g. ESC[32m)
        let pattern = #"\u{001B}\[[0-9;]*m"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex ..< s.endIndex, in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    private func printColored(_ text: String, _ color: ANSIColor) {
        print(colorize(text, color))
    }

    // MARK: - Output Redirection

    private enum OutputSinkState {
        case stdout
        case file(path: String, handle: FileHandle)
    }

    private func beginOutputRedirect(to path: String) throws {
        endOutputRedirect()

        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        outputSink = .file(path: path, handle: handle)
    }

    private func endOutputRedirect() {
        if case let .file(_, handle) = outputSink {
            try? handle.close()
        }
        outputSink = .stdout
    }

    /// Outputs text, respecting file redirect if set
    private func output(_ text: String) {
        switch outputSink {
        case .stdout:
            print(text)
        case let .file(path, handle):
            let data = (text + "\n").data(using: .utf8) ?? Data()
            do {
                try handle.write(contentsOf: data)
            } catch {
                printError("Failed to write to \(path): \(error)")
                print(text)
            }
        }
    }

    // MARK: - Parsing Helpers

    private func parseFileCount(fromManageSelectionSummary text: String) -> Int? {
        // Prefer the markdown summary: "- **Files**: N"
        if let re = try? NSRegularExpression(pattern: #"\*\*Files\*\*:\s*(\d+)"#) {
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            if let match = re.firstMatch(in: text, range: range),
               let r = Range(match.range(at: 1), in: text)
            {
                return Int(text[r])
            }
        }
        // Fallback: "... N file(s) ..."
        if let re = try? NSRegularExpression(pattern: #"(\d+)\s*files?"#, options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            if let match = re.firstMatch(in: text, range: range),
               let r = Range(match.range(at: 1), in: text)
            {
                return Int(text[r])
            }
        }
        return nil
    }

    private func parseWorkspaceName(fromListWindowsText text: String, windowID: Int) -> String? {
        // Matches: "- Window `3` • WS: Foo • Roots: 2"
        let pattern = #"^- Window `\#(windowID)` • WS: (.+?) • Roots:"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = re.firstMatch(in: text, range: range),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
