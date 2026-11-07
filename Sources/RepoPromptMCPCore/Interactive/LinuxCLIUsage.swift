#if os(Linux)
    import Foundation

    func printLinuxUsage() {
        let command = cliDisplayCommand()
        print("""
        RepoPrompt CE for Linux — local context tools and MCP server

        USAGE
          \(command) --backend headless         MCP server on stdin/stdout
          \(command) -l                        List available tools
          \(command) -c read_file -j '{"path":"src/main.swift"}'
          \(command) -e 'tree'                 Execute a command
          \(command) -e 'select set src/ && context'
          \(command) -i                        Interactive REPL
          \(command) policy list               Inspect local mutation policy (TTY)

        WORKSPACE SETUP
          Set REPOPROMPT_MCP_HEADLESS_PROFILE_DIR to a dedicated state directory.
          Set REPOPROMPT_MCP_WORKING_DIRS to one or more absolute project paths,
          separated by colons. Keep the same profile directory across invocations
          to retain workspace state and selections. See docs/linux.md.

        OPTIONS
          -e, --exec <command>       Execute one or more commands
          -i, --interactive          Start the REPL
          -l, --list-tools           List tools supported by this backend
          -c, --call <tool>          Call an MCP tool directly
          -j, --json <object>        Tool arguments as JSON
          --context-id <uuid>        Bind a saved compose context
          --raw-json                 Print machine-readable tool results
          --tool-timeout <seconds>   Tool timeout (300 by default, 0 disables)
          --backend headless|auto    Use the local headless backend (the default)
          --version                  Print the version

        Linux commands and the REPL run the local headless runtime.
        Native macOS windows and app-only tools are unavailable. Inspect -l or
        a tool's schema for supported operations; capabilities are not identical
        to the macOS interface. Provider tools require a separately installed,
        configured provider CLI and the applicable mutation permissions.

        Agents run only while their owning MCP connection or REPL remains open.
        --exec and --call reject detached starts and report unfinished agent waits
        as errors. Closing any Linux CLI session stops its remaining providers;
        another invocation cannot attach to those in-memory sessions.
        """)
    }
#endif
