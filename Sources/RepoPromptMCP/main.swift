import Dispatch
import Foundation
import Logging
import MCP
import RepoPromptDomainRuntime
import RepoPromptMCPCore
import RepoPromptShared
import ServiceLifecycle
import SystemPackage

// MARK: - Entry Point

bootstrapMCPCLIProcess()

// Ignore SIGPIPE to prevent crashes when stdout pipe breaks.
// We detect broken pipes via write() errors instead.
signal(SIGPIPE, SIG_IGN)

/// Parse CLI mode
let mode = parseCLIMode()

if case let .policyAdministration(arguments) = mode {
    await exit(RuntimePolicyAdministration.run(arguments: arguments))
}

if DirectHeadlessChildBridge.isRequested() {
    do {
        try await DirectHeadlessChildBridge.run()
        exit(MCPCLIExitCode.ok.rawValue)
    } catch {
        fputs("RepoPrompt MCP private child bridge: \(error)\n", stderr)
        exit(MCPCLIExitCode.connectionFailed.rawValue)
    }
}

if case .proxy = mode {
    // Proxy/direct MCP mode is for a host-owned pipe or socket. Keep the ordinary terminal
    // help behavior independent of the selected backend, including an explicit `auto` path.
    // Do not use a positive-timeout stdin probe here: hosts may send initialize later.
    let stdinIsTTY = isatty(STDIN_FILENO) != 0
    let stdoutIsTTY = isatty(STDOUT_FILENO) != 0
    let hasNoUserArgs = CommandLine.arguments.count <= 1
    if stdinIsTTY || stdoutIsTTY || (hasNoUserArgs && (!stdinLooksLikeMCPTransport() || stdinHasImmediateDisconnect())) {
        let usage = """
        RepoPrompt MCP CLI

        This command is designed to be used as an MCP server by host applications
        (Claude Desktop, Cursor, etc.) or with explicit mode flags.

        Quick start:
          __RPCE_CLI__ -l                    # List available tools
          __RPCE_CLI__ -e 'tree'             # Execute a command
          __RPCE_CLI__ -i                    # Interactive REPL
          __RPCE_CLI__ --help                # Full help

        """.replacingOccurrences(of: "__RPCE_CLI__", with: cliDisplayCommand())
        fputs(usage, stderr)
        exit(0)
    }
}

let resolvedBackend: MCPResolvedBackend? = if case let .proxy(requestedBackend) = mode {
    MCPBackendSelection.resolve(requested: requestedBackend)
} else {
    nil
}

if let resolvedBackend {
    log.debug(
        "Selected MCP backend before initialize",
        metadata: [
            "requested": "\(String(describing: mode))",
            "selected": "\(resolvedBackend.rawValue)"
        ]
    )
}

// Exec mode is a bounded one-shot command runner. Run it directly instead of
// through ServiceGroup so completion exits deterministically.
if case let .exec(options) = mode {
    let service = ExecMCPService(options: options, logger: log)
    do {
        try await service.run()
        exit(MCPCLIExitCode.ok.rawValue)
    } catch let err as CLIRuntimeError {
        handleRuntimeError(err)
    } catch let err as InteractiveSessionError {
        fputs("RepoPrompt MCP: \(err.description)\n", stderr)
        exit(MCPCLIExitCode.connectionFailed.rawValue)
    } catch let err as ExecError {
        switch err {
        case .commandFailed:
            exit(ExecExitCode.commandFailed.rawValue)
        case let .scriptNotFound(path):
            fputs("RepoPrompt MCP: Script not found: \(path)\n", stderr)
            exit(ExecExitCode.scriptNotFound.rawValue)
        case let .scriptReadError(underlying):
            fputs("RepoPrompt MCP: Failed to read script: \(underlying)\n", stderr)
            exit(ExecExitCode.scriptNotFound.rawValue)
        }
    } catch {
        fputs("Error: \(error)\n", stderr)
        exit(MCPCLIExitCode.unknownError.rawValue)
    }
}

if resolvedBackend == .headless {
    do {
        try await DirectHeadlessMCPService(logger: log).run()
        exit(MCPCLIExitCode.ok.rawValue)
    } catch {
        fputs("RepoPrompt MCP headless: \(error)\n", stderr)
        exit(MCPCLIExitCode.unknownError.rawValue)
    }
}

/// Create appropriate service based on mode
let service: any Service
switch mode {
case .proxy:
    guard resolvedBackend == .app else {
        fatalError("Headless direct service exits before app service composition")
    }
    service = MCPService()
case let .interactive(options):
    service = InteractiveMCPService(options: options, logger: log)
case let .exec(options):
    service = ExecMCPService(options: options, logger: log)
case .policyAdministration:
    fatalError("Policy administration exits before service composition")
}

/// Use a quiet logger for ServiceLifecycle to suppress internal debug output
let lifecycleLogger: Logger = .init(label: "ServiceLifecycle") { _ in
    SwiftLogNoOpLogHandler() // Suppress all ServiceLifecycle internal logging
}

let lifecycle = ServiceGroup(
    configuration: .init(
        services: [service],
        logger: lifecycleLogger
    )
)

do {
    try await lifecycle.run()
    exit(MCPCLIExitCode.ok.rawValue)
} catch let err as CLIRuntimeError {
    handleRuntimeError(err)
} catch let err as InteractiveSessionError {
    // Handle interactive mode errors
    fputs("RepoPrompt MCP: \(err.description)\n", stderr)
    exit(MCPCLIExitCode.connectionFailed.rawValue)
} catch let err as ExecError {
    // Handle exec mode errors
    switch err {
    case .commandFailed:
        exit(ExecExitCode.commandFailed.rawValue)
    case let .scriptNotFound(path):
        fputs("RepoPrompt MCP: Script not found: \(path)\n", stderr)
        exit(ExecExitCode.scriptNotFound.rawValue)
    case let .scriptReadError(underlying):
        fputs("RepoPrompt MCP: Failed to read script: \(underlying)\n", stderr)
        exit(ExecExitCode.scriptNotFound.rawValue)
    }
} catch {
    // ServiceLifecycle throws "A service has finished unexpectedly" when a service
    // completes normally (e.g., --list-tools). Treat this as success for interactive mode.
    let errorDesc = String(describing: error)
    if errorDesc.contains("service has finished unexpectedly") ||
        errorDesc.contains("ServiceGroupError")
    {
        // Service completed normally - this is expected for single-shot commands
        exit(MCPCLIExitCode.ok.rawValue)
    }

    fputs("Error: \(error)\n", stderr)
    exit(MCPCLIExitCode.unknownError.rawValue)
}
