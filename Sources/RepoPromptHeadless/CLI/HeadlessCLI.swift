import Foundation

final class HeadlessCLI {
    func run(arguments: [String], environment: [String: String]) async -> Int {
        do {
            return try await runThrowing(arguments: arguments, environment: environment)
        } catch let error as HeadlessCommandError {
            HeadlessOutput.stderr("ERROR: \(error.message)")
            return error.exitCode
        } catch {
            HeadlessOutput.stderr("ERROR: \(error.localizedDescription)")
            return 1
        }
    }

    private func runThrowing(arguments: [String], environment: [String: String]) async throws -> Int {
        let parsed = try parseGlobalOptions(arguments)
        if parsed.printVersion {
            HeadlessOutput.stdout("\(HeadlessVersion.executableName) \(HeadlessVersion.versionString)")
            return 0
        }
        if parsed.printHelp {
            HeadlessOutput.stdout(Self.usage)
            return 0
        }

        let command = parsed.remaining.first ?? "serve"
        let commandArguments = parsed.remaining.isEmpty ? [] : Array(parsed.remaining.dropFirst())
        let paths = try HeadlessStatePaths.resolve(cliOverride: parsed.stateDirectoryOverride, environment: environment)
        let store = HeadlessConfigurationStore(paths: paths)

        switch command {
        case "serve":
            guard commandArguments.isEmpty else {
                throw HeadlessCommandError("Unexpected arguments for serve: \(commandArguments.joined(separator: " "))", exitCode: 2)
            }
            try await serve(store: store)
            return 0
        case "doctor":
            guard commandArguments.isEmpty else {
                throw HeadlessCommandError("Unexpected arguments for doctor: \(commandArguments.joined(separator: " "))", exitCode: 2)
            }
            return try doctor(store: store)
        case "config":
            return try config(commandArguments, store: store)
        default:
            throw HeadlessCommandError("Unknown command '\(command)'.\n\n\(Self.usage)", exitCode: 2)
        }
    }

    private func serve(store: HeadlessConfigurationStore) async throws {
        _ = try store.loadOrCreate()
        HeadlessOutput.stderr("\(HeadlessVersion.displayName) \(HeadlessVersion.versionString) serving direct stdio MCP with the read-oriented safe tool profile.")
        let server = HeadlessMCPServer(configurationStore: store)
        let transport = HeadlessStdioTransport(server: server, writer: HeadlessStdoutWriter())
        try await transport.run()
    }

    private func doctor(store: HeadlessConfigurationStore) throws -> Int {
        let config = try store.loadOrCreate()
        let validationFailures = HeadlessRootAccessPolicy.validationFailures(for: config.allowedRoots)

        HeadlessOutput.stdout("RepoPrompt Headless doctor")
        HeadlessOutput.stdout("version: \(HeadlessVersion.versionString)")
        HeadlessOutput.stdout("state_dir: \(store.paths.rootDirectory.path)")
        HeadlessOutput.stdout("config: \(store.paths.configFile.path)")
        HeadlessOutput.stdout("workspaces_dir: \(store.paths.workspacesDirectory.path)")
        HeadlessOutput.stdout("exports_dir: \(store.paths.exportsDirectory.path)")
        HeadlessOutput.stdout("secure_storage_namespace: \(HeadlessSecureStorage.namespace)")
        HeadlessOutput.stdout("transport: direct stdio JSON-RPC")
        HeadlessOutput.stdout("app_proxy_socket: unused")
        if config.allowedRoots.isEmpty {
            HeadlessOutput.stdout("allowed_roots: 0 (fail-closed; add one with `\(HeadlessVersion.executableName) config roots add /absolute/path --name NAME`)")
        } else {
            HeadlessOutput.stdout("allowed_roots: \(config.allowedRoots.count)")
        }
        HeadlessOutput.stdout("permissions: write_files=\(config.permissions.writeFiles), vcs_write=\(config.permissions.vcsWrite), launch_agents=\(config.permissions.launchAgents), export_outside_state_directory=\(config.permissions.exportOutsideStateDirectory)")

        guard validationFailures.isEmpty else {
            HeadlessOutput.stdout("root_policy: invalid")
            validationFailures.forEach { HeadlessOutput.stdout("- \($0)") }
            return 2
        }
        HeadlessOutput.stdout("root_policy: fail-closed ok")
        return 0
    }

    private func config(_ arguments: [String], store: HeadlessConfigurationStore) throws -> Int {
        guard let section = arguments.first else {
            throw HeadlessCommandError(Self.configUsage, exitCode: 2)
        }
        let sectionArguments = Array(arguments.dropFirst())
        switch section {
        case "roots":
            return try configRoots(sectionArguments, store: store)
        case "permissions":
            return try configPermissions(sectionArguments, store: store)
        default:
            throw HeadlessCommandError("Unknown config section '\(section)'.\n\n\(Self.configUsage)", exitCode: 2)
        }
    }

    private func configRoots(_ arguments: [String], store: HeadlessConfigurationStore) throws -> Int {
        guard let operation = arguments.first else {
            throw HeadlessCommandError(Self.configRootsUsage, exitCode: 2)
        }
        let operationArguments = Array(arguments.dropFirst())
        switch operation {
        case "list":
            guard operationArguments.isEmpty else {
                throw HeadlessCommandError("Unexpected arguments for config roots list: \(operationArguments.joined(separator: " "))", exitCode: 2)
            }
            let config = try store.loadOrCreate()
            try HeadlessOutput.stdout(HeadlessJSONFormatting.string(HeadlessRootsListOutput(allowedRoots: config.allowedRoots)))
            return 0
        case "add":
            return try addRoot(operationArguments, store: store)
        case "remove":
            return try removeRoot(operationArguments, store: store)
        default:
            throw HeadlessCommandError("Unknown config roots operation '\(operation)'.\n\n\(Self.configRootsUsage)", exitCode: 2)
        }
    }

    private func addRoot(_ arguments: [String], store: HeadlessConfigurationStore) throws -> Int {
        guard let rootPath = arguments.first else {
            throw HeadlessCommandError(Self.configRootsUsage, exitCode: 2)
        }
        let rootOptions = try parseRootOptions(Array(arguments.dropFirst()))
        let root = try HeadlessRootAccessPolicy.makeAllowedRoot(path: rootPath, name: rootOptions.name)

        let config = try store.update { document in
            if document.allowedRoots.contains(where: { $0.resolvedPath == root.resolvedPath }) {
                throw HeadlessCommandError("Allowed root already configured: \(root.resolvedPath)", exitCode: 2)
            }
            if document.allowedRoots.contains(where: { $0.name == root.name }) {
                throw HeadlessCommandError("Allowed root name already configured: \(root.name)", exitCode: 2)
            }
            document.allowedRoots.append(root)
            document.allowedRoots.sort { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        guard let added = config.allowedRoots.first(where: { $0.id == root.id }) else {
            throw HeadlessCommandError("Root was added but could not be read back from config.")
        }
        try HeadlessOutput.stdout(HeadlessJSONFormatting.string(HeadlessRootMutationOutput(action: "added", root: added)))
        return 0
    }

    private func removeRoot(_ arguments: [String], store: HeadlessConfigurationStore) throws -> Int {
        guard arguments.count == 1, let token = arguments.first else {
            throw HeadlessCommandError(Self.configRootsUsage, exitCode: 2)
        }
        var removedRoot: HeadlessAllowedRoot?
        _ = try store.update { document in
            guard let index = document.allowedRoots.firstIndex(where: { HeadlessRootAccessPolicy.rootMatches($0, token: token) }) else {
                throw HeadlessCommandError("No allowed root matches '\(token)'.", exitCode: 2)
            }
            removedRoot = document.allowedRoots.remove(at: index)
        }
        guard let removedRoot else {
            throw HeadlessCommandError("Root was removed but could not be reported.")
        }
        try HeadlessOutput.stdout(HeadlessJSONFormatting.string(HeadlessRootMutationOutput(action: "removed", root: removedRoot)))
        return 0
    }

    private func configPermissions(_ arguments: [String], store: HeadlessConfigurationStore) throws -> Int {
        guard let operation = arguments.first else {
            throw HeadlessCommandError(Self.configPermissionsUsage, exitCode: 2)
        }
        let operationArguments = Array(arguments.dropFirst())
        switch operation {
        case "list":
            guard operationArguments.isEmpty else {
                throw HeadlessCommandError("Unexpected arguments for config permissions list: \(operationArguments.joined(separator: " "))", exitCode: 2)
            }
            let config = try store.loadOrCreate()
            try HeadlessOutput.stdout(HeadlessJSONFormatting.string(HeadlessPermissionsOutput(permissions: config.permissions)))
            return 0
        case "set":
            guard operationArguments.count == 2 else {
                throw HeadlessCommandError(Self.configPermissionsUsage, exitCode: 2)
            }
            let permission = operationArguments[0]
            let value = try parseBoolean(operationArguments[1])
            let config = try store.update { document in
                try document.permissions.set(permission, to: value)
            }
            try HeadlessOutput.stdout(HeadlessJSONFormatting.string(HeadlessPermissionsOutput(permissions: config.permissions)))
            return 0
        default:
            throw HeadlessCommandError("Unknown config permissions operation '\(operation)'.\n\n\(Self.configPermissionsUsage)", exitCode: 2)
        }
    }

    private func parseGlobalOptions(_ arguments: [String]) throws -> ParsedGlobalOptions {
        var remaining: [String] = []
        var stateDirectoryOverride: String?
        var printVersion = false
        var printHelp = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--state-dir":
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    throw HeadlessCommandError("--state-dir requires a path argument.", exitCode: 2)
                }
                stateDirectoryOverride = arguments[valueIndex]
                index += 2
            case "--version", "-V":
                printVersion = true
                index += 1
            case "--help", "-h":
                printHelp = true
                index += 1
            default:
                remaining.append(argument)
                index += 1
            }
        }
        return ParsedGlobalOptions(
            stateDirectoryOverride: stateDirectoryOverride,
            printVersion: printVersion,
            printHelp: printHelp,
            remaining: remaining
        )
    }

    private func parseRootOptions(_ arguments: [String]) throws -> RootOptions {
        var name: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--name":
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    throw HeadlessCommandError("--name requires a value.", exitCode: 2)
                }
                name = arguments[valueIndex]
                index += 2
            default:
                throw HeadlessCommandError("Unexpected config roots add argument: \(argument)", exitCode: 2)
            }
        }
        return RootOptions(name: name)
    }

    private func parseBoolean(_ value: String) throws -> Bool {
        switch value.lowercased() {
        case "true", "yes", "1", "on": true
        case "false", "no", "0", "off": false
        default:
            throw HeadlessCommandError("Expected boolean true/false, received '\(value)'.", exitCode: 2)
        }
    }

    private struct ParsedGlobalOptions {
        let stateDirectoryOverride: String?
        let printVersion: Bool
        let printHelp: Bool
        let remaining: [String]
    }

    private struct RootOptions {
        let name: String?
    }

    private static let usage = """
    Usage: repoprompt-headless [--state-dir PATH] [command]

    Commands:
      serve                         Serve direct stdio JSON-RPC MCP (default; safe read-oriented tools)
      doctor                        Validate state paths, config, fail-closed roots, and defaults
      config roots list             List configured allowed roots
      config roots add PATH [--name NAME]
      config roots remove ID|NAME|PATH
      config permissions list       List capability permissions (all default false)
      config permissions set NAME true|false
      --version                     Print version
    """

    private static let configUsage = """
    Usage: repoprompt-headless [--state-dir PATH] config <roots|permissions> ...
    """

    private static let configRootsUsage = """
    Usage:
      repoprompt-headless [--state-dir PATH] config roots list
      repoprompt-headless [--state-dir PATH] config roots add /absolute/path [--name NAME]
      repoprompt-headless [--state-dir PATH] config roots remove ID|NAME|PATH
    """

    private static let configPermissionsUsage = """
    Usage:
      repoprompt-headless [--state-dir PATH] config permissions list
      repoprompt-headless [--state-dir PATH] config permissions set <write_files|vcs_write|launch_agents|export_outside_state_directory> true|false
    """
}
