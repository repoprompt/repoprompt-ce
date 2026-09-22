import Darwin
import Foundation

package struct DomainMutationPathIdentity: Codable, Hashable {
    package let originalPath: String
    package let resolvedPath: String
    package let device: UInt64
    package let inode: UInt64
}

package struct DomainMutationPathFenceEntry: Codable, Hashable {
    package let requestedPath: String
    package let resolvedPath: String
    /// Identity of the target when it exists, otherwise its nearest existing parent.
    package let existingAnchor: DomainMutationPathIdentity
    package let authorizedRoot: DomainMutationPathIdentity
}

package struct DomainMutationPathFenceSnapshot: Codable, Hashable {
    package let authorizedRoots: [DomainMutationPathIdentity]
    package let entries: [DomainMutationPathFenceEntry]

    package var coveredRoots: Set<String> {
        Set(authorizedRoots.map(\.resolvedPath))
    }
}

package enum DomainMutationPathFenceError: Error, Equatable, LocalizedError {
    case scopeUnavailable
    case relativePath(String)
    case pathOutsideAuthorizedRoots(String)
    case rootUnavailable(String)
    case rootIdentityChanged(String)
    case pathResolutionChanged(String)

    package var errorDescription: String? {
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

package struct DomainMutationPhysicalCommitGuard {
    private let snapshot: DomainMutationPathFenceSnapshot
    private let capability: DomainMutationPhysicalCapability?

    package init(
        snapshot: DomainMutationPathFenceSnapshot,
        capability: DomainMutationPhysicalCapability? = nil
    ) {
        self.snapshot = snapshot
        self.capability = capability
    }

    package func physicalMutationCapability() -> DomainMutationPhysicalCapability? {
        capability
    }

    /// Revalidates the admitted path identities synchronously at a path-based mutation boundary.
    /// Protected file I/O uses the retained capability; Git subprocesses retain this path-fence-only guard.
    package func revalidate() throws {
        try DomainMutationPathFence.revalidateBlocking(snapshot)
    }
}

package enum DomainMutationPathFence {
    package static func admit(
        requestedPaths: [String],
        authorizedRoots: Set<String>
    ) async throws -> DomainMutationPathFenceSnapshot {
        try await Task.detached(priority: .utility) {
            try admitBlocking(requestedPaths: requestedPaths, authorizedRoots: authorizedRoots)
        }.value
    }

    package static func canonicalPath(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        guard let resolution = try? resolvePotentialPath(expanded) else { return nil }
        return resolution.path
    }

    package static func revalidate(_ snapshot: DomainMutationPathFenceSnapshot) async throws {
        try await Task.detached(priority: .utility) {
            try revalidateBlocking(snapshot)
        }.value
    }

    package static func revalidateBlocking(_ snapshot: DomainMutationPathFenceSnapshot) throws {
        for root in snapshot.authorizedRoots {
            let currentRoot = try identity(root.originalPath)
            guard currentRoot == root else {
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
        return DomainMutationPathIdentity(
            originalPath: standardized,
            resolvedPath: URL(fileURLWithPath: standardized).resolvingSymlinksInPath().standardizedFileURL.path,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
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
}
