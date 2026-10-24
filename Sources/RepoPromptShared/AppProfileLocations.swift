import Darwin
import Foundation

/// Application-state locations, not repository editing authority. Build flavor is
/// compiled into the product; an environment variable/profile path cannot elevate it.
public struct AppProfileLocations: Sendable {
    public let identity: MCPFilesystemIdentity
    public let profileName: String
    public let homeDirectory: URL
    private let protectedCustomRoots: [URL]

    public init(
        identity: MCPFilesystemIdentity,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        profileName: String = "default",
        releaseCustomStorageRoots: [URL]? = nil
    ) {
        self.identity = identity
        self.profileName = profileName
        self.homeDirectory = homeDirectory
        // Capture read-only release preferences at profile composition, not on
        // every workspace/session write. A changed selection is picked up by
        // the next runtime composition; canonical/symlink checks still run per IO.
        protectedCustomRoots = identity.buildFlavor == .debug
            ? (releaseCustomStorageRoots ?? Self.releaseCustomRoots()) : []
    }

    public static let current = AppProfileLocations(identity: .current)

    public var profileIdentifier: String {
        profileName
    }

    public var applicationSupportRoot: URL {
        homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(identity.applicationStateDirectoryName, isDirectory: true)
    }

    public var workspaceRoot: URL {
        applicationSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)
    }

    public var savedPromptsRoot: URL {
        identity.buildFlavor == .release
            ? homeDirectory.appendingPathComponent("Library/Application Support/com.pvncher.repoprompt", isDirectory: true)
            : applicationSupportRoot.appendingPathComponent("SavedPrompts", isDirectory: true)
    }

    public var preferencesDomain: String {
        identity.buildFlavor == .debug ? "com.repoprompt.ce.debug" : "com.pvncher.repoprompt.ce"
    }

    /// Read-only legacy sources are never a fallback write destination.
    public var releaseStateRoots: [URL] {
        let release = Self(identity: .repoPromptCE(.release), homeDirectory: homeDirectory)
        return [
            release.applicationSupportRoot,
            release.savedPromptsRoot
        ]
    }

    public func validateWritableRoot(_ url: URL, additionalReleaseRoots: [URL] = []) throws {
        guard identity.buildFlavor == .debug else { return }
        guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/" else { throw ProfileLocationError.invalidRoot(url.path) }
        try validateDirectory(url)
        try validateProtectedPath(url, additionalReleaseRoots: additionalReleaseRoots, rejectAncestors: true)
    }

    private func validateDirectory(_ url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFDIR else { throw ProfileLocationError.notDirectory(url.path) }
        } else if errno != ENOENT { throw ProfileLocationError.unavailable(url.path) }
    }

    private func validateProtectedPath(_ url: URL, additionalReleaseRoots: [URL], rejectAncestors: Bool) throws {
        let canonical = try Self.canonicalURL(url)
        for source in releaseStateRoots + additionalReleaseRoots {
            let protected = try Self.canonicalURL(source)
            if Self.contains(protected, canonical) || (rejectAncestors && Self.contains(canonical, protected)) {
                throw ProfileLocationError.releaseAlias(url.path)
            }
        }
    }

    /// Rejects symlinks in application-owned descendants before a store follows
    /// imported or persisted absolute references. This is accidental-write protection,
    /// not an OS security boundary against a malicious same-user process.
    public func validateMetadataURL(_ url: URL, within root: URL) throws {
        guard identity.buildFlavor == .debug else { return }
        guard root.isFileURL, root.path.hasPrefix("/") else { throw ProfileLocationError.invalidRoot(root.path) }
        try validateDirectory(root)
        // The containment parent is not itself the mutation target. A safe sibling
        // file/directory can share an ancestor with production (for example temp HOME).
        try validateProtectedPath(root, additionalReleaseRoots: protectedCustomRoots, rejectAncestors: false)
        try validateProtectedPath(url, additionalReleaseRoots: protectedCustomRoots, rejectAncestors: true)
        let target = url.standardizedFileURL
        let canonicalRoot = try Self.canonicalURL(root)
        guard Self.contains(root.standardizedFileURL, target), try Self.contains(canonicalRoot, Self.canonicalURL(target)) else {
            throw ProfileLocationError.outsideOwnedRoot(url.path)
        }
        var component = target
        while component.path != root.standardizedFileURL.path {
            var status = stat()
            if lstat(component.path, &status) == 0 {
                if status.st_mode & S_IFMT == S_IFLNK { throw ProfileLocationError.symlink(url.path) }
            } else if errno != ENOENT { throw ProfileLocationError.unavailable(url.path) }
            component.deleteLastPathComponent()
        }
    }

    /// Use only at application-metadata IO boundaries, never for explicit
    /// repository edits or user-selected export destinations.
    public func validateMetadataFile(_ url: URL) throws {
        guard identity.buildFlavor == .debug else { return }
        let root = [applicationSupportRoot].first {
            url.standardizedFileURL.pathComponents.starts(with: $0.standardizedFileURL.pathComponents)
        } ?? url.deletingLastPathComponent()
        try validateMetadataURL(url, within: root)
    }

    /// Preserve the selected parent, but never put debug metadata directly in a
    /// release/custom profile's shared workspace/index directory.
    public func customWorkspaceDirectory(selectedDirectory: URL) -> URL {
        guard identity.buildFlavor == .debug else { return selectedDirectory }
        let name = identity.applicationStateDirectoryName
        return selectedDirectory.lastPathComponent == name
            ? selectedDirectory : selectedDirectory.appendingPathComponent(name, isDirectory: true)
    }

    public func customWorkspaceRoot(selectedDirectory: URL) throws -> URL {
        let root = customWorkspaceDirectory(selectedDirectory: selectedDirectory)
        try validateWritableRoot(root, additionalReleaseRoots: protectedCustomRoots)
        return root
    }

    /// Persisted/imported absolute custom references cannot opt out of the
    /// debug metadata namespace, even when the release custom path is unknown.
    public func validateCustomWorkspaceDirectory(_ url: URL) throws {
        guard identity.buildFlavor == .debug else { return }
        guard url.standardizedFileURL.pathComponents.contains(identity.applicationStateDirectoryName) else {
            throw ProfileLocationError.outsideOwnedRoot(url.path)
        }
        try validateMetadataFile(url)
    }

    private static func releaseCustomRoots() -> [URL] {
        ["com.pvncher.repoprompt.ce", "com.repoprompt.ce"].compactMap { domain in
            guard let path = UserDefaults.standard.persistentDomain(forName: domain)?["GlobalCustomStorageURL"] as? String,
                  !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    /// Foundation does not reliably resolve an existing symlink parent when
    /// the final child is absent. Resolve the nearest existing ancestor first.
    private static func canonicalURL(_ url: URL) throws -> URL {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        var status = stat()
        while lstat(existing.path, &status) != 0 {
            guard errno == ENOENT else { throw ProfileLocationError.unavailable(existing.path) }
            missing.append(existing.lastPathComponent)
            guard existing.path != "/" else { throw ProfileLocationError.invalidRoot(url.path) }
            existing.deleteLastPathComponent()
        }
        var canonical = existing.resolvingSymlinksInPath()
        for component in missing.reversed() {
            canonical.appendPathComponent(component)
        }
        return canonical.standardizedFileURL
    }

    private static func contains(_ root: URL, _ child: URL) -> Bool {
        let components = root.pathComponents
        return child.pathComponents.starts(with: components)
    }
}

public enum ProfileLocationError: Error, Equatable, LocalizedError {
    case invalidRoot(String), notDirectory(String), unavailable(String)
    case releaseAlias(String), outsideOwnedRoot(String), symlink(String)
    public var errorDescription: String? {
        "Application profile location rejected: \(self). No alternate profile will be used."
    }
}

/// An injected profile boundary for metadata engines. Repository/tool output
/// paths are deliberately not governed by this value.
public final class AppMetadataPathPolicy: @unchecked Sendable {
    public let locations: AppProfileLocations
    private let lock = NSLock()
    private var admittedRoots: [URL]
    private var profileLease: DebugProfileAccessLease?
    public var roots: [URL] {
        lock.withLock { admittedRoots }
    }

    public init(locations: AppProfileLocations, roots: [URL]) {
        self.locations = locations
        admittedRoots = roots
    }

    /// The app's explicit storage-selection boundary calls this before moving bytes.
    /// Retain old safe roots while in-flight owners settle; admission is not a catalog move.
    public func admitWorkspaceRoot(_ root: URL) throws {
        try locations.validateCustomWorkspaceDirectory(root)
        try locations.validateWritableRoot(root)
        lock.withLock {
            if !admittedRoots.contains(root) { admittedRoots.append(root) }
        }
    }

    /// Called before a headless runtime opens the default shared debug profile.
    /// The policy is retained by runtime configuration for the lifetime of its stores.
    public func acquireProfileAccess() throws {
        guard locations.identity.buildFlavor == .debug,
              roots.contains(where: { $0.standardizedFileURL.pathComponents.starts(with: locations.applicationSupportRoot.standardizedFileURL.pathComponents) }) else { return }
        try lock.withLock {
            if profileLease == nil { profileLease = try DebugProfileAccessLease.acquire(locations: locations, exclusive: false) }
        }
    }

    public func validate(_ url: URL) throws {
        for root in roots {
            if url.standardizedFileURL.pathComponents.starts(with: root.standardizedFileURL.pathComponents) {
                try locations.validateMetadataURL(url, within: root)
                return
            }
        }
        throw ProfileLocationError.outsideOwnedRoot(url.path)
    }
}
