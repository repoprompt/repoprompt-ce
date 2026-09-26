//
//  ExecOptions.swift
//  repoprompt-mcp
//
//  Options for exec mode - non-interactive command execution.
//

import Foundation

/// Options for exec mode (non-interactive batch execution).
struct ExecOptions {
    /// Window ID to pre-select for tool calls.
    var windowID: Int?

    /// Tab name or UUID to resolve/bind via bind_context at startup.
    var tabID: String?

    /// Canonical compose-tab context ID to bind via bind_context at startup.
    var contextID: String?

    /// Explicit bind_context working_dirs selectors used at startup.
    var workingDirs: [String] = []

    /// If true, request raw JSON tool output (server skips markdown formatting).
    var rawJSON: Bool = false

    /// Commands to execute (from repeated --exec flags).
    var commands: [String] = []

    /// JSON arguments to append to the last command (--json flag).
    var jsonArgs: String?

    /// Path to script file (--exec-file).
    var scriptPath: String?

    /// Read commands from stdin (--exec-stdin).
    var readStdin: Bool = false

    /// Override working directory (--cwd).
    var cwd: String?

    /// Pretty-print JSON output.
    var prettyJSON: Bool = false

    /// Suppress non-essential output.
    var quiet: Bool = true

    /// Wait for server to become available (seconds). 0 = no wait.
    var connectWaitSeconds: Double = 0

    /// Tool call timeout in seconds. nil = default, 0 = no CLI-side timeout.
    var toolCallTimeoutSeconds: Double?

    /// Stop on first failure.
    var failFast: Bool = false

    /// Show verbose output including timing.
    var verbose: Bool = false
}

/// Exit codes for exec mode.
enum ExecExitCode: Int32 {
    case success = 0
    case commandFailed = 1
    case connectionFailed = 73
    case approvalDenied = 74
    case scriptNotFound = 75
    case parseError = 78
}
