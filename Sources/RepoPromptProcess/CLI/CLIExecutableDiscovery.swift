import Darwin
import Foundation

/// Filesystem-only discovery of installed CLI executables.
///
/// Used by Settings to present executables the user already installed. Detection only stats
/// candidate paths; it never launches a process, never recurses, and scans a bounded set of
/// directories derived from the login-shell PATH plus shared native path defaults.
package enum CLIExecutableDiscovery {
    package struct DetectedExecutable: Equatable, Sendable {
        /// Candidate path as found (`<search directory>/<name>`).
        package let path: String
        /// Fully resolved real path with all symlink components resolved. Used for dedupe.
        package let resolvedPath: String
        /// The search directory the candidate was found in.
        package let directory: String

        package init(path: String, resolvedPath: String, directory: String) {
            self.path = path
            self.resolvedPath = resolvedPath
            self.directory = directory
        }
    }

    /// Well-known install roots for a manually installed `codex` CLI beyond the login-shell
    /// PATH. Derived from the shared native path defaults so detection agrees with process
    /// environment building about where CLI tools live.
    package static let codexFixedSearchDirectories: [String] = [
        "~/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin"
    ] + CLINativePathDefaults.nodePackageManagerBins

    /// Search directories for a `codex` executable: the environment's PATH components first,
    /// then the fixed install roots, expanded and deduplicated in order.
    package static func codexSearchDirectories(environment: [String: String]) -> [String] {
        CommandPathResolver.mergedPathComponents(
            environment: environment,
            additionalPaths: codexFixedSearchDirectories
        )
    }

    /// Bounded, non-recursive scan: stats `<directory>/<executableName>` once per search
    /// directory and keeps regular executable files. Entries are deduplicated by resolved
    /// real path, so a `codex` symlink and its target collapse to the first hit in search
    /// order. `excludingResolvedPaths` removes entries such as the bundled runtime, which
    /// callers resolve with `resolvedRealPath` for a symmetric comparison.
    ///
    /// Relative search directories (for example a `bin` PATH entry) are resolved against
    /// `baseDirectoryPath`, defaulting to the process working directory, so reported paths
    /// are always absolute; the candidate's symlink spelling is preserved in `path`.
    package static func detectExecutables(
        named executableName: String,
        inDirectories directories: [String],
        excludingResolvedPaths: Set<String> = [],
        fileManager: FileManager = .default,
        baseDirectoryPath: String? = nil
    ) -> [DetectedExecutable] {
        let baseDirectoryPath = baseDirectoryPath ?? fileManager.currentDirectoryPath
        var detected: [DetectedExecutable] = []
        var seenResolvedPaths = Set<String>()
        for directory in directories where !directory.isEmpty {
            let absoluteDirectory = absoluteSearchDirectory(directory, baseDirectoryPath: baseDirectoryPath)
            let candidate = (absoluteDirectory as NSString).appendingPathComponent(executableName)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: candidate)
            else { continue }
            let resolvedPath = resolvedRealPath(candidate)
            guard !excludingResolvedPaths.contains(resolvedPath),
                  isRegularFile(atPath: resolvedPath),
                  seenResolvedPaths.insert(resolvedPath).inserted
            else { continue }
            detected.append(
                DetectedExecutable(path: candidate, resolvedPath: resolvedPath, directory: absoluteDirectory)
            )
        }
        return detected
    }

    /// The resolved real path for dedupe and exclusion comparisons. Falls back to a
    /// standardized absolute path when `realpath` cannot resolve the candidate.
    package static func resolvedRealPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func absoluteSearchDirectory(_ directory: String, baseDirectoryPath: String) -> String {
        let path = (directory as NSString).isAbsolutePath
            ? directory
            : (baseDirectoryPath as NSString).appendingPathComponent(directory)
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isRegularFile(atPath path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }
}
