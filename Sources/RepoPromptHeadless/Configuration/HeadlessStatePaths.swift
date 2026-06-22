import Foundation

struct HeadlessStatePaths: Equatable {
    static let stateDirectoryEnvironmentVariable = "REPOPROMPT_HEADLESS_STATE_DIR"

    let rootDirectory: URL

    var configFile: URL {
        rootDirectory.appendingPathComponent("config.json", isDirectory: false)
    }

    var workspacesDirectory: URL {
        rootDirectory.appendingPathComponent("Workspaces", isDirectory: true)
    }

    var exportsDirectory: URL {
        rootDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    var configLockFile: URL {
        rootDirectory.appendingPathComponent("config.lock", isDirectory: false)
    }

    func workspaceLockFile(for id: UUID) -> URL {
        workspacesDirectory.appendingPathComponent("\(id.uuidString).lock", isDirectory: false)
    }

    static func resolve(
        cliOverride: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> HeadlessStatePaths {
        let homeDirectory: URL = if let home = environment["HOME"], home.hasPrefix("/") {
            URL(fileURLWithPath: home, isDirectory: true)
        } else {
            fileManager.homeDirectoryForCurrentUser
        }
        if let cliOverride, !cliOverride.isEmpty {
            return try HeadlessStatePaths(rootDirectory: absoluteDirectoryURL(for: cliOverride, homeDirectory: homeDirectory))
        }
        if let environmentOverride = environment[stateDirectoryEnvironmentVariable], !environmentOverride.isEmpty {
            return try HeadlessStatePaths(rootDirectory: absoluteDirectoryURL(for: environmentOverride, homeDirectory: homeDirectory))
        }

        let root = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
            .appendingPathComponent("Headless", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        return HeadlessStatePaths(rootDirectory: root)
    }

    func ensureBaseDirectories(fileManager: FileManager = .default) throws {
        try HeadlessStateFileSecurity.ensurePrivateDirectory(at: rootDirectory, fileManager: fileManager)
        try HeadlessStateFileSecurity.ensurePrivateDirectory(
            at: workspacesDirectory,
            stateRoot: rootDirectory,
            fileManager: fileManager
        )
        try HeadlessStateFileSecurity.ensurePrivateDirectory(
            at: exportsDirectory,
            stateRoot: rootDirectory,
            fileManager: fileManager
        )
    }

    private static func absoluteDirectoryURL(for path: String, homeDirectory: URL) throws -> URL {
        let expanded = expandTilde(in: path, homeDirectory: homeDirectory)
        guard expanded.hasPrefix("/") else {
            throw HeadlessCommandError("Headless state directory overrides must be absolute paths.", exitCode: 2)
        }
        let components = expanded.split(separator: "/", omittingEmptySubsequences: false)
        guard components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw HeadlessCommandError("Headless state directory overrides must not contain empty, '.', or '..' components.", exitCode: 2)
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private static func expandTilde(in path: String, homeDirectory: URL) -> String {
        if path == "~" {
            return homeDirectory.path
        }
        if path.hasPrefix("~/") {
            return homeDirectory
                .appendingPathComponent(String(path.dropFirst(2)))
                .path
        }
        return path
    }
}
