//
//  InteractiveMCPService.swift
//  repoprompt-mcp
//
//  ServiceLifecycle service for interactive MCP mode.
//  Manages the MCP client session and REPL.
//

import Foundation
import Logging
import ServiceLifecycle

/// ServiceLifecycle service that runs interactive MCP mode.
actor InteractiveMCPService: Service {
    private let options: InteractiveOptions
    private let sessionToken: String
    private let clientName: String
    private let logger: Logger

    private var session: InteractiveMCPClientSession?
    private var repl: InteractiveREPL?

    init(options: InteractiveOptions, logger: Logger? = nil) {
        self.options = options
        sessionToken = UUID().uuidString
        clientName = "RepoPrompt CLI (Interactive)"
        self.logger = logger ?? Logger(label: "mcp.interactive") { _ in
            SwiftLogNoOpLogHandler()
        }
    }

    func run() async throws {
        logger.debug("Starting interactive MCP service...")

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

        // Enable progress for direct tool calls (--call) only
        if options.callTool != nil {
            await session.setProgressEnabled(true)
        }

        // Connect to the app
        do {
            try await session.connect()
        } catch {
            handleConnectionError(error)
            throw error
        }

        defer {
            Task {
                await session.disconnect()
            }
        }

        // Create and run REPL
        let repl = InteractiveREPL(session: session, options: options)
        self.repl = repl

        try await repl.run()
    }

    func shutdown() async throws {
        logger.debug("Shutting down interactive MCP service...")
        await session?.disconnect()
    }

    // MARK: - Error Handling

    private static func timeoutPolicy(from seconds: Double?) -> ToolCallTimeoutPolicy {
        guard let seconds else { return .default }
        return seconds == 0 ? .none : .seconds(seconds)
    }

    private func handleConnectionError(_ error: Error) {
        guard let error = error as? InteractiveSessionError else {
            fputs("\u{001B}[31mError: \(String(describing: error))\u{001B}[0m\n", stderr)
            return
        }

        switch error {
        case .appNotRunning:
            fputs("""
            \u{001B}[31mError: Cannot connect to RepoPrompt\u{001B}[0m

            The RepoPrompt app is not running or MCP is disabled.

            To fix:
            1. Launch RepoPrompt.app
            2. Ensure MCP Server is enabled in Settings > MCP

            """, stderr)

        case .approvalDenied:
            fputs("""
            \u{001B}[31mError: Connection approval denied\u{001B}[0m

            Your connection request was rejected by RepoPrompt.
            Check the MCP approval dialog in RepoPrompt.

            """, stderr)

        case .bootstrapResponseTimeout:
            fputs("""
            \u{001B}[31mError: RepoPrompt did not respond to the bootstrap handshake\u{001B}[0m

            The app accepted the socket connection too slowly or is wedged.
            If RepoPrompt recently crashed under the debugger, restart it and try again.

            """, stderr)

        default:
            fputs("\u{001B}[31mError: \(error.description)\u{001B}[0m\n", stderr)
        }
    }
}
