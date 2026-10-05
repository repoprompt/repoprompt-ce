import CryptoKit
import Foundation

/// Describes a git repository root for multi-root workspace operations.
/// Used to identify, namespace, and display repo roots consistently.
public struct GitRepoDescriptor: Codable, Sendable, Equatable, Hashable {
    /// Canonical URL of the git repository root directory
    public let rootURL: URL

    /// Standardized absolute path (rootURL.path)
    public let rootPath: String

    /// Stable, filesystem-safe key for storage namespacing (e.g., "repoprompt-a1b2c3d4")
    /// Format: sanitized-slug + "-" + 8-char hash
    public let repoKey: String

    /// Human-readable display name (typically last path component)
    public let displayName: String

    /// Fresh repository/worktree identity when the root has a resolvable Git layout.
    /// A nil value is intentionally not treated as an authorization match for external worktrees.
    public let worktreeIdentity: GitWorktreeIdentitySnapshot?

    /// Initialize from a git root URL
    /// - Parameter rootURL: The canonical git repository root URL
    public init(rootURL: URL) {
        self.rootURL = rootURL
        rootPath = (rootURL.path as NSString).standardizingPath
        displayName = rootURL.lastPathComponent
        repoKey = Self.makeRepoKey(for: rootPath, displayName: displayName)
        worktreeIdentity = GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: rootURL)
    }

    /// Initialize with all fields (used for decoding or testing)
    public init(
        rootURL: URL,
        rootPath: String,
        repoKey: String,
        displayName: String,
        worktreeIdentity: GitWorktreeIdentitySnapshot? = nil
    ) {
        self.rootURL = rootURL
        self.rootPath = rootPath
        self.repoKey = repoKey
        self.displayName = displayName
        self.worktreeIdentity = worktreeIdentity
    }

    /// Generate a stable, filesystem-safe repo key from the root path.
    /// Format: "sanitized-slug-hash8" where:
    /// - sanitized-slug: lowercase, alphanumeric + hyphen version of displayName
    /// - hash8: first 8 characters of SHA256 hash of canonicalized path
    /// - Parameter rootPath: The standardized absolute path of the git root
    /// - Parameter displayName: The human-readable name (typically last path component)
    /// - Returns: A stable filesystem-safe key
    public static func makeRepoKey(for rootPath: String, displayName: String) -> String {
        let slug = sanitizeSlug(displayName)
        let hash = hashPath(rootPath)
        return "\(slug)-\(hash)"
    }

    /// Sanitize a string into a filesystem-safe slug
    /// - Parameter input: The string to sanitize
    /// - Returns: Lowercase alphanumeric string with hyphens, max 24 chars
    private static func sanitizeSlug(_ input: String) -> String {
        let lowercased = input.lowercased()
        var slug = ""
        var lastWasHyphen = true // Start true to avoid leading hyphen

        for char in lowercased {
            if char.isLetter || char.isNumber {
                slug.append(char)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                slug.append("-")
                lastWasHyphen = true
            }
        }

        // Remove trailing hyphen
        while slug.hasSuffix("-") {
            slug.removeLast()
        }

        // Limit length
        if slug.count > 24 {
            slug = String(slug.prefix(24))
            // Clean up any trailing hyphen from truncation
            while slug.hasSuffix("-") {
                slug.removeLast()
            }
        }

        // Fallback if empty
        if slug.isEmpty {
            slug = "repo"
        }

        return slug
    }

    /// Hash the canonical path for stable identification
    /// - Parameter path: The standardized absolute path
    /// - Returns: First 8 characters of SHA256 hash (hex)
    private static func hashPath(_ path: String) -> String {
        let canonicalized = path.lowercased()
        let data = Data(canonicalized.utf8)
        let hash = SHA256.hash(data: data)
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }

    /// Check if an absolute path is within this repository
    /// - Parameter absolutePath: The absolute path to check
    /// - Returns: true if the path is under this repo's root
    public func contains(absolutePath: String) -> Bool {
        let standardized = (absolutePath as NSString).standardizingPath
        let rootWithSlash = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return standardized == rootPath || standardized.hasPrefix(rootWithSlash)
    }

    /// Convert an absolute path to a repo-relative path
    /// - Parameter absolutePath: The absolute path to convert
    /// - Returns: The relative path within this repo, or nil if not contained
    public func relativePath(for absolutePath: String) -> String? {
        let standardized = (absolutePath as NSString).standardizingPath
        guard contains(absolutePath: standardized) else { return nil }

        if standardized == rootPath {
            return ""
        }

        let rootWithSlash = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return String(standardized.dropFirst(rootWithSlash.count))
    }
}

// MARK: - Comparable for stable ordering

extension GitRepoDescriptor: Comparable {
    public static func < (lhs: GitRepoDescriptor, rhs: GitRepoDescriptor) -> Bool {
        // Sort by display name first, then by path for stability
        if lhs.displayName != rhs.displayName {
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        return lhs.rootPath < rhs.rootPath
    }
}
