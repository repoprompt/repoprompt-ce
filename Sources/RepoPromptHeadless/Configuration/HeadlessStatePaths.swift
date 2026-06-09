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
        if let cliOverride, !cliOverride.isEmpty {
            return HeadlessStatePaths(rootDirectory: absoluteDirectoryURL(for: cliOverride, fileManager: fileManager))
        }
        if let environmentOverride = environment[stateDirectoryEnvironmentVariable], !environmentOverride.isEmpty {
            return HeadlessStatePaths(rootDirectory: absoluteDirectoryURL(for: environmentOverride, fileManager: fileManager))
        }

        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
            .appendingPathComponent("Headless", isDirectory: true)
            .standardizedFileURL
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

    private static func absoluteDirectoryURL(for path: String, fileManager: FileManager) -> URL {
        let expanded = expandTilde(in: path, fileManager: fileManager)
        let absolutePath: String = if expanded.hasPrefix("/") {
            expanded
        } else {
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(expanded, isDirectory: true)
                .path
        }
        return URL(fileURLWithPath: absolutePath, isDirectory: true).standardizedFileURL
    }

    private static func expandTilde(in path: String, fileManager: FileManager) -> String {
        if path == "~" {
            return fileManager.homeDirectoryForCurrentUser.path
        }
        if path.hasPrefix("~/") {
            return fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
                .path
        }
        return path
    }
}
