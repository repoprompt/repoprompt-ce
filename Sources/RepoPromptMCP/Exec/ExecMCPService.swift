//
//  ExecMCPService.swift
//  repoprompt-mcp
//
//  ServiceLifecycle service for exec mode.
//  Runs commands non-interactively and exits.
//

import Foundation
import Logging
import MCP
import ServiceLifecycle

/// ServiceLifecycle service that runs exec mode (non-interactive command execution).
actor ExecMCPService: Service {
    private let options: ExecOptions
    private let logger: Logger
    private let sessionToken: String
    private let clientName: String

    private var session: InteractiveMCPClientSession?
    private var exitCode: Int32 = 0

    init(options: ExecOptions, logger: Logger? = nil) {
        self.options = options
        sessionToken = UUID().uuidString
        clientName = "RepoPrompt CLI (Exec)"
        var configuredLogger = logger ?? Logger(label: "mcp.exec") { _ in
            SwiftLogNoOpLogHandler()
        }
        if options.verbose {
            configuredLogger.logLevel = .trace
        }
        self.logger = configuredLogger
    }

    func run() async throws {
        logger.debug("Starting exec MCP service...")

        // Create session
        let session = InteractiveMCPClientSession(
            sessionToken: sessionToken,
            clientName: clientName,
            logger: logger
        )
        self.session = session

        // Enable raw JSON mode if requested
        await session.setRawJSONEnabled(options.rawJSON)
        await session.setDefaultToolCallTimeout(Self.timeoutPolicy(from: options.toolCallTimeoutSeconds))

        // Enable progress notifications for exec mode
        await session.setProgressEnabled(true)

        // Connect with optional retry
        do {
            try await connectWithRetry(session: session)
        } catch {
            await session.disconnect()
            self.session = nil
            handleConnectionError(error)
            throw error
        }

        do {
            try await runConnectedSession(session)
        } catch {
            await session.disconnect()
            self.session = nil
            throw error
        }
        await session.disconnect()
        self.session = nil
    }

    private func runConnectedSession(_ session: InteractiveMCPClientSession) async throws {
        // Apply explicit local routing first so explicit CLI selectors still route
        // subsequent calls if bind_context validation is unavailable or times out.
        if let windowID = options.windowID {
            await session.setSelectedWindowID(windowID)
        }
        if let contextID = options.contextID {
            await session.setSelectedContextID(contextID)
        } else if let tabID = options.tabID, UUID(uuidString: tabID) != nil {
            await session.setSelectedContextID(tabID)
        }

        // Apply explicit bind_context-based startup routing.
        do {
            if let contextID = options.contextID {
                _ = try await session.bindContextID(contextID, windowID: options.windowID)
                if !options.quiet {
                    fputs("Bound context \(contextID)\n", stderr)
                }
            } else if let tabID = options.tabID {
                _ = try await session.bindTab(selector: tabID, windowID: options.windowID)
                if !options.quiet {
                    fputs("Bound tab \(tabID)\n", stderr)
                }
            } else if !options.workingDirs.isEmpty {
                _ = try await session.bindWorkingDirs(options.workingDirs, windowID: options.windowID)
                if !options.quiet {
                    fputs("Bound working_dirs \(options.workingDirs.joined(separator: ", "))\n", stderr)
                }
            } else if let windowID = options.windowID {
                _ = try await session.selectWindow(windowID: windowID)
                if !options.quiet {
                    fputs("Selected window \(windowID)\n", stderr)
                }
            }
        } catch {
            let target = options.contextID ?? options.tabID ?? options.workingDirs.first ?? options.windowID.map(String.init) ?? "startup binding"
            fputs("Warning: Failed to bind \(target): \(error)\n", stderr)
        }

        #if DEBUG || MCP_LATENCY_TRACE
            if let latencyConcurrentBatchPath = options.latencyConcurrentBatchPath {
                try await runLatencyConcurrentBatch(
                    at: latencyConcurrentBatchPath,
                    session: session
                )
                return
            }
        #endif

        // Collect commands to run
        let commands = try collectCommands()
        if commands.isEmpty {
            if !options.quiet {
                fputs("No commands to execute.\n", stderr)
            }
            return
        }

        // Create runner
        let runnerSettings = RunnerSettings(
            prettyJSON: options.prettyJSON,
            colors: false, // No colors in exec mode
            verbose: options.verbose,
            timing: options.verbose,
            failFast: options.failFast
        )

        let runner = MCPCommandRunner(
            session: session,
            initialDirectory: options.cwd ?? FileManager.default.currentDirectoryPath,
            settings: runnerSettings,
            outputHandler: { [weak self] text, isError in
                await self?.handleOutput(text, isError: isError)
            }
        )

        // Execute commands with redirect support
        var allSucceeded = true
        var summaries: [LineExecutionResult] = []

        for command in commands {
            // Parse redirect from command
            let parsed = REPLInputParser.parse(command)

            // Handle redirect if present (> truncates, >> appends)
            var redirectPath: String?
            if let rawPath = parsed.outputRedirectPath {
                redirectPath = resolvePath(rawPath)
                do {
                    outputSink = try OutputSink.openFile(at: redirectPath!, append: parsed.appendMode)
                } catch {
                    fputs("Error: Failed to open output file '\(redirectPath!)': \(error)\n", stderr)
                    allSucceeded = false
                    if options.failFast { break }
                    continue
                }
            }

            // Build command without redirect for execution, preserving separators
            var commandToRun = ""
            for (index, segment) in parsed.segments.enumerated() {
                commandToRun += segment.command
                if let sep = segment.separatorAfter, index < parsed.segments.count - 1 {
                    commandToRun += sep == .always ? " ; " : " && "
                }
            }
            let summary = await runner.runLine(commandToRun)
            summaries.append(summary)

            // Close redirect and print confirmation
            if let path = redirectPath {
                outputSink.close()
                outputSink = .stdout
                // Always show confirmation for file redirect (it's the only feedback)
                fputs("Output written to: \(path)\n", stderr)
            }

            if !summary.succeeded {
                allSucceeded = false
                if options.failFast { break }
            }
        }

        // Log summary in verbose mode
        if options.verbose {
            let total = summaries.count
            let failed = summaries.count(where: { !$0.succeeded })
            fputs("\nExecuted \(total) command(s): \(total - failed) succeeded, \(failed) failed\n", stderr)
        }

        // Set exit code
        exitCode = allSucceeded ? 0 : 1
        if exitCode != 0 {
            throw ExecError.commandFailed
        }
    }

    #if DEBUG || MCP_LATENCY_TRACE
        private struct LatencyConcurrentBatchRequest: Decodable {
            enum OutputFormat: String, Decodable {
                case formatted
                case raw
            }

            let invocationID: UUID
            let tool: String
            let outputFormat: OutputFormat
            let outputPath: String
            let arguments: [String: Value]?

            enum CodingKeys: String, CodingKey {
                case invocationID = "invocation_id"
                case tool
                case outputFormat = "output_format"
                case outputPath = "output_path"
                case arguments
            }
        }

        private func runLatencyConcurrentBatch(
            at path: String,
            session: InteractiveMCPClientSession
        ) async throws {
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            let requests = try JSONDecoder().decode([LatencyConcurrentBatchRequest].self, from: data)
            guard !requests.isEmpty else { throw ExecError.commandFailed }
            guard Set(requests.map(\.invocationID)).count == requests.count,
                  Set(requests.map(\.outputPath)).count == requests.count,
                  requests.allSatisfy({ $0.outputPath.hasPrefix("/") })
            else { throw ExecError.commandFailed }

            try await withThrowingTaskGroup(of: Void.self) { group in
                for request in requests {
                    group.addTask {
                        var arguments = request.arguments ?? [:]
                        arguments[MCPCommandLatencyDiagnostics.requestIdentityArgument] = .string(
                            request.invocationID.uuidString
                        )
                        switch request.outputFormat {
                        case .formatted:
                            arguments.removeValue(forKey: "_rawJSON")
                        case .raw:
                            arguments["_rawJSON"] = .bool(true)
                        }
                        let prepared = MCPCommandLatencyDiagnostics.prepareInvocation(
                            toolName: request.tool,
                            arguments: arguments
                        )
                        do {
                            let result = try await session.callTool(
                                name: request.tool,
                                arguments: prepared.arguments
                            )
                            let returned = DispatchTime.now().uptimeNanoseconds
                            let output = Self.latencyBatchResponseData(result)
                            try output.write(
                                to: URL(fileURLWithPath: request.outputPath),
                                options: .atomic
                            )
                            let printed = DispatchTime.now().uptimeNanoseconds
                            await MCPCommandLatencyDiagnostics.shared.record(
                                invocation: prepared.invocation,
                                c1Nanoseconds: returned,
                                c2Nanoseconds: printed,
                                result: result,
                                outcome: result.isError == true ? .toolError : .success
                            )
                        } catch {
                            let returned = DispatchTime.now().uptimeNanoseconds
                            await MCPCommandLatencyDiagnostics.shared.record(
                                invocation: prepared.invocation,
                                c1Nanoseconds: returned,
                                c2Nanoseconds: returned,
                                result: nil,
                                outcome: MCPCommandLatencyDiagnostics.outcome(for: error)
                            )
                            throw error
                        }
                    }
                }
                try await group.waitForAll()
            }
        }

        private nonisolated static func latencyBatchResponseData(_ result: CallTool.Result) -> Data {
            // Match redirected MCPCommandRunner output: successful content blocks are
            // emitted in order with one trailing newline per output callback. Tool
            // errors remain on stderr and therefore produce an empty response file.
            guard result.isError != true else { return Data() }
            var output = ""
            for content in result.content {
                let rendered: [String]
                switch content {
                case let .text(text, _, _):
                    rendered = [text]
                case let .image(data, mimeType, _, _):
                    rendered = ["[Image: \(mimeType), \(data.count) bytes]"]
                case let .audio(data, mimeType, _, _):
                    rendered = ["[Audio: \(mimeType), \(data.count) bytes]"]
                case let .resource(resource, _, _):
                    var lines = ["[Resource: \(resource.uri) (\(resource.mimeType ?? "unknown"))]"]
                    if let text = resource.text {
                        lines.append(text)
                    } else if let blob = resource.blob {
                        lines.append("[Binary resource: \(blob.count) base64 characters]")
                    }
                    rendered = lines
                case let .resourceLink(uri, name, _, _, mimeType, _):
                    rendered = ["[Resource Link: \(name) \(uri) (\(mimeType ?? "unknown"))]"]
                }
                for line in rendered {
                    output += line + "\n"
                }
            }
            return Data(output.utf8)
        }
    #endif

    func shutdown() async throws {
        logger.debug("Shutting down exec MCP service...")
        await session?.disconnect()
        session = nil
    }

    // MARK: - Connection

    private static func timeoutPolicy(from seconds: Double?) -> ToolCallTimeoutPolicy {
        guard let seconds else { return .default }
        return seconds == 0 ? .none : .seconds(seconds)
    }

    private func connectWithRetry(session: InteractiveMCPClientSession) async throws {
        let deadline = options.connectWaitSeconds > 0
            ? Date().addingTimeInterval(options.connectWaitSeconds)
            : Date()

        var lastError: (any Error)?
        var attempt = 0

        repeat {
            attempt += 1
            do {
                try await session.connect(fetchInitialTools: false)
                return // Success
            } catch {
                lastError = error

                if let sessionError = error as? InteractiveSessionError {
                    switch sessionError {
                    case .approvalDenied:
                        throw error
                    case .appNotRunning where Date() < deadline:
                        if options.verbose {
                            fputs("Waiting for RepoPrompt app (attempt \(attempt))...\n", stderr)
                        }
                        try await MCPCompatibilitySleep.sleep(.milliseconds(500))
                        continue
                    case .bootstrapResponseTimeout where Date() < deadline:
                        if options.verbose {
                            fputs("Retrying stalled RepoPrompt bootstrap handshake (attempt \(attempt))...\n", stderr)
                        }
                        try await MCPCompatibilitySleep.sleep(.milliseconds(500))
                        continue
                    default:
                        break
                    }
                }

                // For other errors, retry if we have time
                if Date() < deadline {
                    try await MCPCompatibilitySleep.sleep(.milliseconds(500))
                    continue
                }

                throw error
            }
        } while Date() < deadline

        if let error = lastError {
            throw error
        }
    }

    // MARK: - Command Collection

    private func collectCommands() throws -> [String] {
        var commands: [String] = []

        // From --exec flags (in order)
        commands.append(contentsOf: options.commands)

        // From script file
        if let scriptPath = options.scriptPath {
            let url = URL(fileURLWithPath: scriptPath)
            guard FileManager.default.fileExists(atPath: scriptPath) else {
                fputs("Error: Script file not found: \(scriptPath)\n", stderr)
                throw ExecError.scriptNotFound(scriptPath)
            }
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let lines = content.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                commands.append(contentsOf: lines)
            } catch {
                fputs("Error: Failed to read script file: \(error)\n", stderr)
                throw ExecError.scriptReadError(error)
            }
        }

        // From stdin
        if options.readStdin {
            while let line = readLine() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                    commands.append(trimmed)
                }
            }
        }

        // Append JSON args to the last command if provided via --json flag
        if let jsonArgs = options.jsonArgs, !commands.isEmpty {
            let lastIndex = commands.count - 1
            commands[lastIndex] = commands[lastIndex] + " " + jsonArgs
        }

        return commands
    }

    // MARK: - Output Handling

    /// Current output sink - either stdout or file redirect
    private var outputSink: OutputSink = .stdout

    private func handleOutput(_ text: String, isError: Bool) {
        if isError {
            fputs("\(text)\n", stderr)
        } else if case let .file(_, handle) = outputSink {
            // Write to file
            if let data = (text + "\n").data(using: .utf8) {
                handle.write(data)
            }
        } else {
            print(text)
        }
    }

    /// Resolves a path argument (handles ~, relative paths).
    private func resolvePath(_ path: String) -> String {
        var resolved = path
        if resolved.hasPrefix("~") {
            resolved = (resolved as NSString).expandingTildeInPath
        }
        if !resolved.hasPrefix("/") {
            let base = options.cwd ?? FileManager.default.currentDirectoryPath
            resolved = (base as NSString).appendingPathComponent(resolved)
        }
        return resolved
    }

    // MARK: - Error Handling

    private func handleConnectionError(_ error: any Error) {
        guard let error = error as? InteractiveSessionError else {
            fputs("Error: \(error)\n", stderr)
            return
        }

        switch error {
        case .appNotRunning:
            fputs("""
            Error: Cannot connect to RepoPrompt

            The RepoPrompt app is not running or MCP is disabled.

            To fix:
            1. Launch RepoPrompt.app
            2. Ensure MCP Server is enabled in Settings > MCP

            """, stderr)
        case .approvalDenied:
            fputs("""
            Error: Connection approval denied

            Your connection request was rejected by RepoPrompt.
            Check the MCP approval dialog in RepoPrompt.

            """, stderr)
        case .bootstrapResponseTimeout:
            fputs("""
            Error: RepoPrompt did not respond to the bootstrap handshake

            The app accepted the socket connection too slowly or is wedged.
            If RepoPrompt recently crashed under the debugger, restart it and try again.

            """, stderr)
        default:
            fputs("Error: \(error.description)\n", stderr)
        }
    }
}

// MARK: - Errors

enum ExecError: Swift.Error {
    case commandFailed
    case scriptNotFound(String)
    case scriptReadError(any Swift.Error)
}
