#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif
import Foundation
import RepoPromptC

public struct DomainMutationPathIdentity: Codable, Hashable, Sendable {
    public let originalPath: String
    public let resolvedPath: String
    public let device: UInt64
    public let inode: UInt64
    /// Optional for compatibility with journals admitted before birth-time
    /// fencing was available.
    public let birthTimeBits: UInt64?

    public init(
        originalPath: String,
        resolvedPath: String,
        device: UInt64,
        inode: UInt64,
        birthTimeBits: UInt64? = nil
    ) {
        self.originalPath = originalPath
        self.resolvedPath = resolvedPath
        self.device = device
        self.inode = inode
        self.birthTimeBits = birthTimeBits
    }
}

public struct DomainMutationPathFenceEntry: Codable, Hashable, Sendable {
    public let requestedPath: String
    public let resolvedPath: String
    /// Identity of the target when it exists, otherwise its nearest existing parent.
    public let existingAnchor: DomainMutationPathIdentity
    public let authorizedRoot: DomainMutationPathIdentity
}

public struct DomainMutationPathFenceSnapshot: Codable, Hashable, Sendable {
    public let authorizedRoots: [DomainMutationPathIdentity]
    public let entries: [DomainMutationPathFenceEntry]

    public var coveredRoots: Set<String> {
        Set(authorizedRoots.map(\.resolvedPath))
    }
}

public enum DomainMutationPathFenceError: Error, Equatable, LocalizedError, Sendable {
    case scopeUnavailable
    case relativePath(String)
    case pathOutsideAuthorizedRoots(String)
    case rootUnavailable(String)
    case rootIdentityChanged(String)
    case pathResolutionChanged(String)

    public var errorDescription: String? {
        switch self {
        case .scopeUnavailable:
            "Protected mutation denied because no authoritative workspace roots are bound."
        case let .relativePath(path):
            "Protected mutation paths must be absolute: \(path)"
        case let .pathOutsideAuthorizedRoots(path):
            "Protected mutation path is outside the authoritative workspace roots: \(path)"
        case let .rootUnavailable(path):
            "Protected mutation root is unavailable: \(path)"
        case let .rootIdentityChanged(path):
            "Protected mutation root identity changed before commit: \(path)"
        case let .pathResolutionChanged(path):
            "Protected mutation path or symlink resolution changed before commit: \(path)"
        }
    }
}

public struct DomainMutationPhysicalCommitGuard: Sendable {
    private let snapshot: DomainMutationPathFenceSnapshot

    public init(snapshot: DomainMutationPathFenceSnapshot) {
        self.snapshot = snapshot
    }

    /// Revalidates the admitted path identities synchronously at a path-based mutation boundary.
    /// This narrows the race window but does not make the later path operation descriptor-bound.
    public func revalidate() throws {
        try DomainMutationPathFence.revalidateBlocking(snapshot)
    }
}

public enum DomainMutationPathFence {
    public static func admit(
        requestedPaths: [String],
        authorizedRoots: Set<String>
    ) async throws -> DomainMutationPathFenceSnapshot {
        try await Task.detached(priority: .utility) {
            try admitBlocking(requestedPaths: requestedPaths, authorizedRoots: authorizedRoots)
        }.value
    }

    public static func canonicalPath(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        guard let resolution = try? resolvePotentialPath(expanded) else { return nil }
        return resolution.path
    }

    public static func revalidate(_ snapshot: DomainMutationPathFenceSnapshot) async throws {
        try await Task.detached(priority: .utility) {
            try revalidateBlocking(snapshot)
        }.value
    }

    public static func revalidateBlocking(_ snapshot: DomainMutationPathFenceSnapshot) throws {
        for root in snapshot.authorizedRoots {
            let currentRoot = try identity(root.originalPath)
            guard sameStableRootIdentity(currentRoot, root) else {
                throw DomainMutationPathFenceError.rootIdentityChanged(root.originalPath)
            }
        }
        for entry in snapshot.entries {
            let resolution = try resolvePotentialPath(entry.requestedPath)
            let currentAnchor = try identity(entry.existingAnchor.originalPath)
            guard resolution.path == entry.resolvedPath,
                  currentAnchor == entry.existingAnchor,
                  isContained(resolution.path, by: entry.authorizedRoot.resolvedPath)
            else {
                throw DomainMutationPathFenceError.pathResolutionChanged(entry.requestedPath)
            }
        }
    }

    private static func admitBlocking(
        requestedPaths: [String],
        authorizedRoots: Set<String>
    ) throws -> DomainMutationPathFenceSnapshot {
        guard !authorizedRoots.isEmpty else {
            throw DomainMutationPathFenceError.scopeUnavailable
        }
        let rootIdentities = try authorizedRoots.sorted().map(identity)
        let entries = try requestedPaths.map { path in
            let absolutePath: String
            if path.hasPrefix("/") {
                absolutePath = path
            } else if rootIdentities.count == 1, let root = rootIdentities.first {
                absolutePath = URL(fileURLWithPath: root.originalPath)
                    .appendingPathComponent(path)
                    .standardizedFileURL.path
            } else {
                throw DomainMutationPathFenceError.relativePath(path)
            }
            let resolution = try resolvePotentialPath(absolutePath)
            guard let root = rootIdentities.first(where: { isContained(resolution.path, by: $0.resolvedPath) }) else {
                throw DomainMutationPathFenceError.pathOutsideAuthorizedRoots(path)
            }
            return DomainMutationPathFenceEntry(
                requestedPath: absolutePath,
                resolvedPath: resolution.path,
                existingAnchor: resolution.anchor,
                authorizedRoot: root
            )
        }
        return DomainMutationPathFenceSnapshot(authorizedRoots: rootIdentities, entries: entries)
    }

    private static func identity(_ path: String) throws -> DomainMutationPathIdentity {
        guard path.hasPrefix("/") else {
            throw DomainMutationPathFenceError.relativePath(path)
        }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var info = stat()
        guard lstat(standardized, &info) == 0 else {
            throw DomainMutationPathFenceError.rootUnavailable(path)
        }
        var birthSeconds: UInt64 = 0
        var birthNanoseconds: UInt32 = 0
        let birthTimeBits: UInt64? = standardized.withCString {
            rp_filesystem_birth_identity($0, &birthSeconds, &birthNanoseconds) == 0
                ? birthSeconds &* 1_000_000_000 &+ UInt64(birthNanoseconds)
                : nil
        }
        return DomainMutationPathIdentity(
            originalPath: standardized,
            resolvedPath: URL(fileURLWithPath: standardized).resolvingSymlinksInPath().standardizedFileURL.path,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            birthTimeBits: birthTimeBits
        )
    }

    private static func resolvePotentialPath(
        _ path: String
    ) throws -> (path: String, anchor: DomainMutationPathIdentity) {
        guard path.hasPrefix("/") else {
            throw DomainMutationPathFenceError.relativePath(path)
        }
        var cursor = URL(fileURLWithPath: path).standardizedFileURL
        var missingComponents: [String] = []
        var info = stat()
        while lstat(cursor.path, &info) != 0 {
            let component = cursor.lastPathComponent
            guard !component.isEmpty, cursor.path != "/" else {
                throw DomainMutationPathFenceError.rootUnavailable(path)
            }
            missingComponents.insert(component, at: 0)
            cursor.deleteLastPathComponent()
        }
        let anchor = try identity(cursor.path)
        var resolved = cursor.resolvingSymlinksInPath()
        for component in missingComponents {
            resolved.appendPathComponent(component)
        }
        return (resolved.standardizedFileURL.path, anchor)
    }

    private static func isContained(_ path: String, by root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func sameStableRootIdentity(
        _ lhs: DomainMutationPathIdentity,
        _ rhs: DomainMutationPathIdentity
    ) -> Bool {
        lhs.originalPath == rhs.originalPath
            && lhs.resolvedPath == rhs.resolvedPath
            && lhs.device == rhs.device
            && lhs.inode == rhs.inode
    }
}
