import Foundation

extension RepoPromptMCPServerConfiguration {
    init(name: String = Self.defaultServerName, args: [String] = [], env: [EnvironmentEntry] = []) {
        self.init(name: name, command: CLISymlinkManagerUserSpace.stableCLIPath, args: args, env: env)
    }

    static var repoPrompt: Self {
        Self(args: ["--backend", "app"])
    }

    func validateACPLaunchCommand(
        workingDirectory: String? = nil,
        resolvedBareCommandPath: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw ACPCommandValidationError.emptyCommand(serverName: name)
        }

        guard let path = Self.resolvedFilesystemPath(for: trimmedCommand, workingDirectory: workingDirectory) else {
            guard let resolvedBareCommandPath,
                  let resolvedPath = Self.resolvedFilesystemPath(for: resolvedBareCommandPath, workingDirectory: workingDirectory)
            else {
                return
            }
            try Self.validateACPLaunchPath(resolvedPath, serverName: name, fileManager: fileManager)
            return
        }

        try Self.validateACPLaunchPath(path, serverName: name, fileManager: fileManager)
    }

    private static func validateACPLaunchPath(_ path: String, serverName: String, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ACPCommandValidationError.missingExecutable(serverName: serverName, path: path)
        }
        guard !isDirectory.boolValue, fileManager.isExecutableFile(atPath: path) else {
            throw ACPCommandValidationError.notExecutable(serverName: serverName, path: path)
        }
    }

    private static func resolvedFilesystemPath(for command: String, workingDirectory: String?) -> String? {
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        guard expanded.contains("/") else { return nil }
        let basePath = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = URL(fileURLWithPath: (basePath?.isEmpty == false ? basePath : nil) ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: expanded, relativeTo: baseURL).standardizedFileURL.path
    }

    enum ACPCommandValidationError: LocalizedError, Equatable {
        case emptyCommand(serverName: String)
        case missingExecutable(serverName: String, path: String)
        case unresolvedCommand(serverName: String, command: String)
        case notExecutable(serverName: String, path: String)

        var errorDescription: String? {
            switch self {
            case let .emptyCommand(serverName):
                "\(serverName) MCP command is empty. Configure a valid RepoPrompt CLI command before starting the agent."
            case let .missingExecutable(serverName, path):
                "\(serverName) MCP command does not exist at \(path). Launch RepoPrompt to refresh its CLI helper, or update the MCP command before starting the agent."
            case let .unresolvedCommand(serverName, command):
                "\(serverName) MCP command \(command) was not found in the agent launch environment. Use an absolute RepoPrompt CLI path or update PATH before starting the agent."
            case let .notExecutable(serverName, path):
                "\(serverName) MCP command is not executable at \(path). Fix the CLI helper permissions or update the MCP command before starting the agent."
            }
        }
    }
}
