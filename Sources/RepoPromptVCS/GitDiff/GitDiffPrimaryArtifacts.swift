import Foundation

package struct GitDiffPrimaryArtifacts: Equatable {
    package let map: String
    package let allPatch: String?

    package init(map: String, allPatch: String?) {
        self.map = map
        self.allPatch = allPatch
    }

    package init(publishedArtifacts: GitDiffPublishedArtifactSet) {
        map = publishedArtifacts.map.clientAlias ?? publishedArtifacts.map.absolutePath
        allPatch = publishedArtifacts.allPatch.map { $0.clientAlias ?? $0.absolutePath }
    }

    package var selectionCandidates: [String] {
        var paths = [map]
        if let allPatch {
            paths.append(allPatch)
        }
        return paths
    }
}

package struct GitDiffPerFilePatchArtifact: Equatable {
    package let jumpIndex: Int
    package let gitPath: String
    package let selectionPath: String
    package let status: String?
    package let additions: Int?
    package let deletions: Int?

    package init(
        jumpIndex: Int,
        gitPath: String,
        selectionPath: String,
        status: String? = nil,
        additions: Int? = nil,
        deletions: Int? = nil
    ) {
        self.jumpIndex = jumpIndex
        self.gitPath = gitPath
        self.selectionPath = selectionPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}

package extension GitDiffSnapshotStore {
    static func rootQualifiedArtifactPath(snapshotDir: String, relativePath: String) -> String {
        let components = ["_git_data", snapshotDir, relativePath]
            .map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            .filter { !$0.isEmpty }
        return components.joined(separator: "/")
    }

    static func primaryArtifacts(
        snapshotDir: String,
        mapRelativePath: String = "MAP.txt",
        allPatchRelativePath: String?
    ) -> GitDiffPrimaryArtifacts {
        GitDiffPrimaryArtifacts(
            map: rootQualifiedArtifactPath(snapshotDir: snapshotDir, relativePath: mapRelativePath),
            allPatch: allPatchRelativePath.map { rootQualifiedArtifactPath(snapshotDir: snapshotDir, relativePath: $0) }
        )
    }

    static func perFilePatchArtifacts(
        snapshotDir: String,
        files: [GitDiffSnapshotManifest.FileEntry]
    ) -> [GitDiffPerFilePatchArtifact] {
        displayOrderedFiles(files).enumerated().compactMap { offset, entry in
            guard let patchPath = entry.patchPath else { return nil }
            return GitDiffPerFilePatchArtifact(
                jumpIndex: offset + 1,
                gitPath: entry.gitPath,
                selectionPath: rootQualifiedArtifactPath(snapshotDir: snapshotDir, relativePath: patchPath),
                status: entry.status,
                additions: entry.additions,
                deletions: entry.deletions
            )
        }
    }
}
