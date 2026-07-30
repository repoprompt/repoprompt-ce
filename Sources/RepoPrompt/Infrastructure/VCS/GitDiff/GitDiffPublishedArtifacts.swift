import Foundation

enum GitDiffArtifactPathPolicy {
    static func isSafeRelativeArtifactPath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !StandardizedPath.containsNUL(path)
        else { return false }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty &&
                component != "." &&
                component != ".." &&
                !component.contains(":")
        }
    }

    static func safeManifestPatchPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("diff/"),
              isSafeRelativeArtifactPath(trimmed)
        else { return nil }

        let lowercased = trimmed.lowercased()
        guard lowercased.hasSuffix(".patch") || lowercased.hasSuffix(".diff") else {
            return nil
        }
        return trimmed
    }
}

enum GitDiffPublishedArtifactKind: Hashable {
    case manifest
    case map
    case allPatch
    case perFilePatch
}

enum GitDiffPublishedArtifactSelectionDisposition: Hashable {
    case authorizationDependency
    case primaryAutoSelect
    case advertisedSelectable
}

struct GitDiffPublishedArtifact: Hashable {
    let kind: GitDiffPublishedArtifactKind
    let absolutePath: String
    let gitDataRelativePath: String
    let clientAlias: String?
    let selectionDisposition: GitDiffPublishedArtifactSelectionDisposition

    init(
        kind: GitDiffPublishedArtifactKind,
        absolutePath: String,
        gitDataRelativePath: String,
        clientAlias: String?,
        selectionDisposition: GitDiffPublishedArtifactSelectionDisposition
    ) {
        self.kind = kind
        self.absolutePath = StandardizedPath.absolute(absolutePath)
        self.gitDataRelativePath = gitDataRelativePath
        self.clientAlias = clientAlias
        self.selectionDisposition = selectionDisposition
    }
}

enum GitDiffPublishedArtifactError: LocalizedError, Equatable {
    case invalidSnapshotReference
    case manifestIdentityMismatch
    case invalidSnapshotDirectory(String)
    case unsafeRelativePath(String)

    var errorDescription: String? {
        switch self {
        case .invalidSnapshotReference:
            "Published Git artifacts require a normalized repo-scoped snapshot reference."
        case .manifestIdentityMismatch:
            "The Git artifact manifest does not match the published snapshot identity."
        case let .invalidSnapshotDirectory(path):
            "The Git artifact snapshot directory does not match its snapshot identity: \(path)"
        case let .unsafeRelativePath(path):
            "The Git artifact relative path is unsafe: \(path)"
        }
    }
}

struct GitDiffPublishedArtifactSet: Equatable {
    let snapshotRef: GitDiffSnapshotStore.GitDiffSnapshotRef
    let snapshotDirectoryPath: String
    let manifest: GitDiffPublishedArtifact
    let map: GitDiffPublishedArtifact
    let allPatch: GitDiffPublishedArtifact?
    let perFilePatches: [GitDiffPublishedArtifact]

    init(
        snapshotDirectoryURL: URL,
        snapshotRef: GitDiffSnapshotStore.GitDiffSnapshotRef,
        manifest: GitDiffSnapshotManifest,
        allPatchRelativePath: String?
    ) throws {
        guard snapshotRef.repoKey != nil,
              GitDiffArtifactPathPolicy.isSafeRelativeArtifactPath(snapshotRef.snapshotDirRel)
        else {
            throw GitDiffPublishedArtifactError.invalidSnapshotReference
        }
        guard let manifestRepoKey = manifest.repoKey,
              manifestRepoKey == snapshotRef.repoKey,
              let normalizedSnapshotID = GitDiffSnapshotStore.normalizeSnapshotID(manifest.snapshotID),
              normalizedSnapshotID == manifest.snapshotID,
              normalizedSnapshotID == snapshotRef.snapshotID
        else {
            throw GitDiffPublishedArtifactError.manifestIdentityMismatch
        }

        let snapshotDirectoryPath = StandardizedPath.absolute(snapshotDirectoryURL.path)
        let expectedSuffix = "/\(snapshotRef.snapshotDirRel)"
        guard snapshotDirectoryPath.hasPrefix("/"),
              !StandardizedPath.containsNUL(snapshotDirectoryPath),
              snapshotDirectoryPath.hasSuffix(expectedSuffix)
        else {
            throw GitDiffPublishedArtifactError.invalidSnapshotDirectory(snapshotDirectoryURL.path)
        }

        func makeArtifact(
            kind: GitDiffPublishedArtifactKind,
            relativePath: String,
            disposition: GitDiffPublishedArtifactSelectionDisposition
        ) throws -> GitDiffPublishedArtifact {
            guard GitDiffArtifactPathPolicy.isSafeRelativeArtifactPath(relativePath) else {
                throw GitDiffPublishedArtifactError.unsafeRelativePath(relativePath)
            }
            let gitDataRelativePath = "\(snapshotRef.snapshotDirRel)/\(relativePath)"
            let absolutePath = StandardizedPath.join(
                standardizedRoot: snapshotDirectoryPath,
                standardizedRelativePath: relativePath
            )
            return GitDiffPublishedArtifact(
                kind: kind,
                absolutePath: absolutePath,
                gitDataRelativePath: gitDataRelativePath,
                clientAlias: "_git_data/\(gitDataRelativePath)",
                selectionDisposition: disposition
            )
        }

        self.snapshotRef = snapshotRef
        self.snapshotDirectoryPath = snapshotDirectoryPath
        self.manifest = try makeArtifact(
            kind: .manifest,
            relativePath: "manifest.json",
            disposition: .authorizationDependency
        )
        map = try makeArtifact(
            kind: .map,
            relativePath: "MAP.txt",
            disposition: .primaryAutoSelect
        )
        if let allPatchRelativePath {
            guard allPatchRelativePath == "diff/all.patch" else {
                throw GitDiffPublishedArtifactError.unsafeRelativePath(allPatchRelativePath)
            }
            allPatch = try makeArtifact(
                kind: .allPatch,
                relativePath: allPatchRelativePath,
                disposition: .primaryAutoSelect
            )
        } else {
            allPatch = nil
        }

        var seenPerFilePaths = Set<String>()
        perFilePatches = try manifest.files.compactMap { entry in
            guard let rawPatchPath = entry.patchPath else { return nil }
            guard let patchPath = GitDiffArtifactPathPolicy.safeManifestPatchPath(rawPatchPath),
                  patchPath != "diff/all.patch"
            else {
                throw GitDiffPublishedArtifactError.unsafeRelativePath(rawPatchPath)
            }
            guard seenPerFilePaths.insert(patchPath).inserted else { return nil }
            return try makeArtifact(
                kind: .perFilePatch,
                relativePath: patchPath,
                disposition: .advertisedSelectable
            )
        }
    }

    var orderedArtifacts: [GitDiffPublishedArtifact] {
        [manifest, map] + (allPatch.map { [$0] } ?? []) + perFilePatches
    }

    var primarySelectionArtifacts: [GitDiffPublishedArtifact] {
        [map] + (allPatch.map { [$0] } ?? [])
    }

    /// Exact artifacts that the Git reply advertises as selectable. This deliberately excludes
    /// manifest/index dependencies; callers must still require the manifest to be cataloged.
    var advertisedSelectionArtifacts: [GitDiffPublishedArtifact] {
        primarySelectionArtifacts + perFilePatches
    }
}
