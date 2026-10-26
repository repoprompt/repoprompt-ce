import Foundation
import MCP
import RepoPromptWorkspaceCore

/// Native output interpretation and the actual ephemeral handoff payload writer.
/// This value does not issue workspace/root authority.
package enum AgentHandoffOutputFile {
    package static func pathArgument(_ value: Value?) throws -> String? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        case let .string(path):
            return path
        default:
            throw MCPError.invalidParams("output_path must be a string.")
        }
    }

    package static func write(
        _ payload: String,
        to rawPath: String,
        overwrite: Bool,
        homeDirectory: URL
    ) async throws -> (path: String, bytes: Int) {
        let url = try resolveOutputURL(rawPath, homeDirectory: homeDirectory)
        let data = Data(payload.utf8)
        let bytes = data.count
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    throw MCPError.invalidParams("output_path points to a directory: \(url.path)")
                }
                if !overwrite {
                    throw MCPError.invalidParams("output_path already exists and overwrite=false: \(url.path)")
                }
            }
            let parent = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let options: Data.WritingOptions = overwrite ? [.atomic] : [.withoutOverwriting]
            do {
                try data.write(to: url, options: options)
            } catch {
                if !overwrite, fileManager.fileExists(atPath: url.path) {
                    throw MCPError.invalidParams("output_path already exists and overwrite=false: \(url.path)")
                }
                throw error
            }
        }.value
        return (url.path, bytes)
    }

    private static func resolveOutputURL(_ rawPath: String, homeDirectory: URL) throws -> URL {
        guard !rawPath.isEmpty else {
            throw MCPError.invalidParams("output_path must not be empty.")
        }
        // This operation deliberately accepts one path without NUL, LF or CR.
        // Inspect the supplied value before any expansion or native bridge.
        guard !rawPath.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) else {
            throw MCPError.invalidParams("output_path must be a single filesystem path.")
        }
        if rawPath.hasPrefix("~"), rawPath != "~", !rawPath.hasPrefix("~/") {
            throw MCPError.invalidParams("output_path supports '~' or '~/' only; use an absolute path otherwise.")
        }
        guard rawPath.hasPrefix("/") || rawPath == "~" || rawPath.hasPrefix("~/") else {
            throw MCPError.invalidParams("output_path must be absolute. CLI shorthand resolves relative paths before calling MCP.")
        }

        let absolutePath: WorkspaceAbsolutePath
        if rawPath.hasPrefix("/") {
            absolutePath = try WorkspaceAbsolutePath.nativeText(rawPath)
        } else {
            let home = try WorkspaceAbsolutePath.nativeText(homeDirectory.path)
            guard case let .absolute(expanded) = try WorkspaceNativePathInput.userText(rawPath, homeDirectory: home) else {
                throw MCPError.invalidParams("output_path must be absolute. CLI shorthand resolves relative paths before calling MCP.")
            }
            absolutePath = expanded
        }
        // Native dot/symlink traversal remains the filesystem's responsibility.
        // A terminal directory retains the existing writer's directory refusal.
        return try URL(fileURLWithPath: absolutePath.utf8ForPlatform())
    }
}
