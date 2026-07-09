import Darwin
import Foundation
import RepoPromptShared

/// Shared ownership classifier for CE-managed CLI links and wrapper scripts.
/// Missing and dangling symlinks are inspected with lstat/readlink rather than
/// FileManager.fileExists, which follows the target.
enum ManagedCLIPathPolicy {
    enum SymlinkClassification: Equatable {
        case missing
        case managedCurrent(destination: String)
        case managedStale(destination: String)
        case unmanaged
    }

    enum WrapperClassification: Equatable {
        case missing
        case managedCurrent
        case managedOutdated
        case unmanaged
    }

    static let currentClaudeWrapperMarker = "# claude-rpce: Claude Code wrapper configured for RepoPrompt CE"
    static let legacyClaudeWrapperMarkers = [
        "# claude-rp-ce: Claude Code wrapper configured for RepoPrompt CE",
        "# claude-rp: Claude Code wrapper configured for RepoPrompt"
    ]

    static func classifySymlink(
        at path: String,
        desiredDestination: String,
        managedDestinations: Set<String>,
        fileManager: FileManager = .default
    ) -> SymlinkClassification {
        guard let type = fileType(atPath: path) else { return .missing }
        guard type == mode_t(S_IFLNK),
              let rawDestination = try? fileManager.destinationOfSymbolicLink(atPath: path)
        else { return .unmanaged }

        let destination = resolvedDestination(rawDestination, linkPath: path)
        let desired = standardized(desiredDestination)
        let allowlist = Set(managedDestinations.map(standardized))
        guard destination == desired
            || allowlist.contains(destination)
            || isTranslocatedManagedDestination(destination, allowlist: allowlist)
        else {
            return .unmanaged
        }
        if destination == desired, fileManager.isExecutableFile(atPath: destination) {
            return .managedCurrent(destination: rawDestination)
        }
        return .managedStale(destination: rawDestination)
    }

    static func classifyWrapper(
        at path: String,
        expectedContent: String,
        fileManager: FileManager = .default
    ) -> WrapperClassification {
        guard let type = fileType(atPath: path) else { return .missing }
        guard type == mode_t(S_IFREG),
              let content = try? String(contentsOfFile: path, encoding: .utf8),
              isManagedWrapper(content)
        else { return .unmanaged }
        return content.trimmingCharacters(in: .whitespacesAndNewlines) ==
            expectedContent.trimmingCharacters(in: .whitespacesAndNewlines)
            ? .managedCurrent
            : .managedOutdated
    }

    static func isManagedWrapper(_ content: String) -> Bool {
        let lines = content.split(whereSeparator: \.isNewline).prefix(8).map(String.init)
        let markers = [currentClaudeWrapperMarker] + legacyClaudeWrapperMarkers
        return markers.contains { marker in lines.contains(marker) }
    }

    static func managedDestinations(
        currentBundledCLIPath: String?,
        fileManager: FileManager = .default
    ) -> Set<String> {
        let home = fileManager.homeDirectoryForCurrentUser
        let legacyAppSupport = home
            .appendingPathComponent("Library/Application Support/RepoPrompt CE", isDirectory: true)
        var paths: Set<String> = [
            MCPFilesystemIdentity.repoPromptCE(.debug).userSpaceCLIURL(fileManager: fileManager).path,
            MCPFilesystemIdentity.repoPromptCE(.release).userSpaceCLIURL(fileManager: fileManager).path,
            legacyAppSupport.appendingPathComponent("repoprompt_ce_cli_debug").path,
            legacyAppSupport.appendingPathComponent("repoprompt_ce_cli").path,
            legacyAppSupport.appendingPathComponent("repoprompt_cli_debug").path,
            legacyAppSupport.appendingPathComponent("repoprompt_cli").path,
            legacyAppSupport.appendingPathComponent("DebugApps/RepoPrompt.app/Contents/MacOS/repoprompt-mcp").path,
            "/Applications/RepoPrompt.app/Contents/MacOS/repoprompt-mcp",
            home.appendingPathComponent("Applications/RepoPrompt.app/Contents/MacOS/repoprompt-mcp").path
        ]
        if let currentBundledCLIPath {
            paths.insert(currentBundledCLIPath)
        }
        return Set(paths.map(standardized))
    }

    static func isRecognizedCECommand(
        _ command: String,
        currentBundledCLIPath: String?,
        fileManager: FileManager = .default
    ) -> Bool {
        managedDestinations(currentBundledCLIPath: currentBundledCLIPath, fileManager: fileManager)
            .contains(standardized(command))
    }

    static var exactLegacyPathCommandNames: [String] {
        ["rp-cli-ce-debug", "rp-ce-cli", "rp-ce-cli-debug"]
    }

    static var exactLegacyWrapperCommandNames: [String] {
        ["claude-rp-ce", "claude-rp-ce-debug"]
    }

    private static func fileType(atPath path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & mode_t(S_IFMT)
    }

    private static func resolvedDestination(_ destination: String, linkPath: String) -> String {
        if destination.hasPrefix("/") { return standardized(destination) }
        let parent = URL(fileURLWithPath: linkPath).deletingLastPathComponent()
        return standardized(parent.appendingPathComponent(destination).path)
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// App Translocation relocates a quarantined app bundle to a randomized,
    /// read-only mount such as
    /// `/private/var/folders/.../AppTranslocation/<uuid>/d/<App>.app/...`.
    /// A user-space CLI link created during a translocated launch therefore
    /// points at a path that is neither the desired destination nor on the
    /// static allowlist, and that path usually vanishes once the app is moved
    /// to a stable location. Treat such a link as a managed (stale) entry when
    /// its app-bundle-relative suffix matches a known managed destination, so it
    /// can be repaired instead of being rejected as unmanaged.
    private static func isTranslocatedManagedDestination(
        _ destination: String,
        allowlist: Set<String>
    ) -> Bool {
        let components = (destination as NSString).pathComponents
        guard components.contains("AppTranslocation"),
              let suffix = appBundleRelativeSuffix(destination)
        else { return false }
        return allowlist.contains { appBundleRelativeSuffix($0) == suffix }
    }

    /// Returns the portion of a path from its last `*.app` component to the end
    /// (e.g. `RepoPrompt CE.app/Contents/MacOS/repoprompt-mcp`), or nil when the
    /// path has no app-bundle component.
    private static func appBundleRelativeSuffix(_ path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard let appIndex = components.lastIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        return components[appIndex...].joined(separator: "/")
    }
}
