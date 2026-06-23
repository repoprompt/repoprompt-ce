import Darwin
import Foundation

struct HeadlessExportWriter {
    private let paths: HeadlessStatePaths
    private let fileManager: FileManager

    init(paths: HeadlessStatePaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func write(
        _ data: Data,
        to requestedPath: String?,
        defaultFileName: String,
        permissions: HeadlessPermissions,
        inStateParentDirectoryOpenedHook: HeadlessStateFileSecurity.ParentDirectoryOpenedHook? = nil,
        externalParentDirectoryOpenedHook: HeadlessExternalExportFileSecurity.ParentDirectoryOpenedHook? = nil
    ) throws -> URL {
        try paths.ensureBaseDirectories(fileManager: fileManager)
        let stateRoot = paths.rootDirectory
        let exportsRoot = paths.exportsDirectory
        let requestedAbsolutePath = requestedPath?.hasPrefix("/") ?? false

        let target: URL = if let requestedPath, !requestedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if requestedAbsolutePath {
                URL(fileURLWithPath: requestedPath).standardizedFileURL
            } else {
                paths.exportsDirectory.appendingPathComponent(requestedPath, isDirectory: false).standardizedFileURL
            }
        } else {
            paths.exportsDirectory.appendingPathComponent(defaultFileName, isDirectory: false).standardizedFileURL
        }

        if try isSymbolicLink(at: target) {
            throw HeadlessCommandError("Export target must not be an existing symbolic link: \(target.path)", exitCode: 2)
        }

        let targetParent = target.deletingLastPathComponent()
        let inState = Self.lexicallyContains(target.path, root: stateRoot.path)
        let parentInState = Self.lexicallyContains(targetParent.path, root: stateRoot.path)
        let inExports = Self.lexicallyContains(target.path, root: exportsRoot.path)
        let parentInExports = Self.lexicallyContains(targetParent.path, root: exportsRoot.path)

        guard (inState && parentInState) || permissions.exportOutsideStateDirectory else {
            throw HeadlessCommandError(
                "Export path is outside the headless state directory '\(stateRoot.path)' and export_outside_state_directory is false: \(target.path) (targetContained=\(inState), parentContained=\(parentInState), parent=\(targetParent.path))",
                exitCode: 2
            )
        }
        if !requestedAbsolutePath, !(inExports && parentInExports) {
            throw HeadlessCommandError(
                "Relative export path escapes the headless Exports directory: \(requestedPath ?? defaultFileName)",
                exitCode: 2
            )
        }

        if inState {
            try HeadlessStateFileSecurity.writePrivateFile(
                data,
                to: target,
                stateRoot: stateRoot,
                fileManager: fileManager,
                parentDirectoryOpenedHook: inStateParentDirectoryOpenedHook
            )
        } else {
            try HeadlessExternalExportFileSecurity.writeFile(
                data,
                to: target,
                parentDirectoryOpenedHook: externalParentDirectoryOpenedHook
            )
        }
        return target
    }

    private func isSymbolicLink(at url: URL) throws -> Bool {
        var status = stat()
        if Darwin.lstat(url.path, &status) == 0 {
            return status.st_mode & S_IFMT == S_IFLNK
        }
        if errno == ENOENT {
            return false
        }
        let detail = String(cString: Darwin.strerror(errno))
        throw HeadlessCommandError("Unable to inspect export target '\(url.path)': \(detail)", exitCode: 2)
    }

    private static func lexicallyContains(_ candidate: String, root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root + "/")
    }
}
