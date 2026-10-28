import AppKit
import Foundation
import RepoPromptProcess

/// Feeds the Codex runtime menu in Settings with executables detected on this Mac.
///
/// Detection is filesystem-only and never launches a candidate binary. The login-shell
/// environment comes from `CLIEnvironmentCache`, the fixed install roots and the bounded
/// scan live in `CLIExecutableDiscovery`, and the bundled runtime is excluded by resolved
/// real path so the included entry is never duplicated by the menu.
package enum CodexExecutableDetection {
    package static let executableName = "codex"

    /// Detects installed `codex` executables off the caller's actor. Reads the cached
    /// login-shell environment, then scans PATH directories plus well-known install roots.
    package static func detectOnSystem() async -> [CLIExecutableDiscovery.DetectedExecutable] {
        let environment = await CLIEnvironmentCache.shared.environment(enableLogging: false)
        return await Task.detached(priority: .utility) {
            detect(
                environment: environment,
                bundledExecutablePath: bundledExecutablePath(environment: environment)
            )
        }.value
    }

    /// Pure scan core: merges the login-shell PATH with the fixed install roots, keeps
    /// executable `codex` files, dedupes by resolved real path, and excludes the bundled
    /// runtime. Fully injectable so tests run against a temporary filesystem only.
    package static func detect(
        environment: [String: String],
        bundledExecutablePath: String?,
        fileManager: FileManager = .default
    ) -> [CLIExecutableDiscovery.DetectedExecutable] {
        var excludedResolvedPaths = Set<String>()
        if let bundledExecutablePath {
            excludedResolvedPaths.insert(CLIExecutableDiscovery.resolvedRealPath(bundledExecutablePath))
        }
        return CLIExecutableDiscovery.detectExecutables(
            named: executableName,
            inDirectories: CLIExecutableDiscovery.codexSearchDirectories(environment: environment),
            excludingResolvedPaths: excludedResolvedPaths,
            fileManager: fileManager
        )
    }

    /// The bundled runtime's executable path, resolved without launching it. Nil when the
    /// bundled package is unavailable (for example in test bundles).
    package static func bundledExecutablePath(environment: [String: String]) -> String? {
        guard case let .success(runtime) = CodexRuntimeAuthority.resolve(environment: environment) else {
            return nil
        }
        return runtime.executableURL.path
    }

    /// The pending custom selection that still needs its own menu item: an external path
    /// that is not already covered by a detected executable (compared by resolved real path
    /// so a selected symlink and its target do not produce a duplicate row).
    package static func undetectedCustomPath(
        pendingExternalPath: String?,
        detected: [CLIExecutableDiscovery.DetectedExecutable]
    ) -> String? {
        guard let pendingExternalPath else { return nil }
        let resolved = CLIExecutableDiscovery.resolvedRealPath(pendingExternalPath)
        return detected.contains { $0.path == pendingExternalPath || $0.resolvedPath == resolved }
            ? nil
            : pendingExternalPath
    }

    /// Whether a detected entry corresponds to the pending external selection, matching
    /// either the found path or the resolved real path of the selected path.
    package static func isSelected(
        externalPath: String?,
        detected: CLIExecutableDiscovery.DetectedExecutable
    ) -> Bool {
        guard let externalPath else { return false }
        return externalPath == detected.path
            || CLIExecutableDiscovery.resolvedRealPath(externalPath) == detected.resolvedPath
    }

    /// Path abbreviated with `~` for the user's home directory, as shown in the menu.
    package static func abbreviatedPath(_ path: String, homePath: String = NSHomeDirectory()) -> String {
        if path == homePath { return "~" }
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~" + path.dropFirst(homePath.count)
    }

    /// Menu item title for an executable path (abbreviated with `~`).
    package static func menuItemTitle(for path: String) -> String {
        abbreviatedPath(path)
    }

    /// Start directory for the file panel: the folder containing the first detected
    /// executable, then `~/.local/bin` when it exists, then the pending custom path's
    /// folder (previous behavior) as a last resort.
    package static func filePanelStartDirectory(
        detected: [CLIExecutableDiscovery.DetectedExecutable],
        pendingExternalPath: String?,
        localBinPath: String = ("~/.local/bin" as NSString).expandingTildeInPath,
        fileManager: FileManager = .default
    ) -> URL? {
        if let first = detected.first {
            return URL(fileURLWithPath: first.directory, isDirectory: true)
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: localBinPath, isDirectory: &isDirectory), isDirectory.boolValue {
            return URL(fileURLWithPath: localBinPath, isDirectory: true)
        }
        if let pendingExternalPath {
            return URL(fileURLWithPath: pendingExternalPath).deletingLastPathComponent()
        }
        return nil
    }

    /// Configures the shared open panel for choosing a `codex` executable. Hidden files
    /// are shown so installs under dot-directories remain reachable.
    @MainActor
    package static func configureExecutablePanel(
        _ panel: NSOpenPanel,
        detected: [CLIExecutableDiscovery.DetectedExecutable],
        pendingExternalPath: String?
    ) {
        panel.title = "Choose Codex Executable"
        panel.message = "Select an installed Codex CLI executable. RepoPrompt validates its version before use."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.showsHiddenFiles = true
        panel.directoryURL = filePanelStartDirectory(
            detected: detected,
            pendingExternalPath: pendingExternalPath
        )
    }
}
