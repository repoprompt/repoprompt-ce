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
        let stateRoot = paths.rootDirectory.resolvingSymlinksInPath().standardizedFileURL
        let exportsRoot = paths.exportsDirectory.resolvingSymlinksInPath().standardizedFileURL
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

        let resolvedParent = target.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let resolvedTarget = resolvedParent
            .appendingPathComponent(target.lastPathComponent, isDirectory: false)
            .standardizedFileURL
        let inState = HeadlessRootAccessPolicy.path(resolvedTarget.path, isContainedInOrEqualTo: stateRoot.path)
        let parentInState = HeadlessRootAccessPolicy.path(resolvedParent.path, isContainedInOrEqualTo: stateRoot.path)
        let inExports = HeadlessRootAccessPolicy.path(resolvedTarget.path, isContainedInOrEqualTo: exportsRoot.path)
        let parentInExports = HeadlessRootAccessPolicy.path(resolvedParent.path, isContainedInOrEqualTo: exportsRoot.path)

        guard (inState && parentInState) || permissions.exportOutsideStateDirectory else {
            throw HeadlessCommandError(
                "Export path is outside the headless state directory and export_outside_state_directory is false: \(target.path)",
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
                to: resolvedTarget,
                stateRoot: stateRoot,
                fileManager: fileManager,
                parentDirectoryOpenedHook: inStateParentDirectoryOpenedHook
            )
        } else {
            try HeadlessExternalExportFileSecurity.writeFile(
                data,
                to: resolvedTarget,
                parentDirectoryOpenedHook: externalParentDirectoryOpenedHook
            )
        }
        return resolvedTarget
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
}
