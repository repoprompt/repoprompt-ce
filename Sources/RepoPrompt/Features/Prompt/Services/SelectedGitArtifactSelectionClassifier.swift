import Foundation

/// Classifies every stored-selection representation that can carry a published Git artifact.
///
/// Classification is deliberately separate from authorization: callers still need
/// `SelectedGitDiffArtifactAuthorizationService` to prove catalog, manifest, checkout, and
/// delegation authority for every candidate.
enum SelectedGitArtifactSelectionClassifier {
    static func selectionCandidatePaths(from selection: StoredSelection) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func append(_ path: String) {
            guard seen.insert(path).inserted else { return }
            candidates.append(path)
        }

        selection.selectedPaths.forEach(append)
        selection.slices
            .filter { !$0.value.isEmpty }
            .map(\.key)
            .sorted()
            .forEach(append)
        return candidates
    }

    static func artifactCandidatePaths(
        from selection: StoredSelection,
        capability: SelectedGitArtifactCapability?
    ) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()
        for rawPath in selectionCandidatePaths(from: selection) {
            let isArtifact: Bool = if let capability {
                isWithinCapability(rawPath, capability: capability)
                    || isWorkspaceGitDataAlias(rawPath)
            } else {
                looksLikeWorkspaceGitDataPath(rawPath)
            }
            guard isArtifact else { continue }

            let identity = artifactIdentity(rawPath, capability: capability)
            guard seen.insert(identity).inserted else { continue }
            candidates.append(identity)
        }
        return candidates
    }

    private static func artifactIdentity(
        _ rawPath: String,
        capability: SelectedGitArtifactCapability?
    ) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return StandardizedPath.absolute(expanded)
        }
        if let capability, isWorkspaceGitDataAlias(rawPath) {
            let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
            let relativePath = String(normalized.dropFirst("_git_data/".count))
            return StandardizedPath.join(
                standardizedRoot: capability.gitDataRoot.standardizedFullPath,
                standardizedRelativePath: relativePath
            )
        }
        return StandardizedPath.relative(expanded)
    }

    private static func isWithinCapability(
        _ rawPath: String,
        capability: SelectedGitArtifactCapability
    ) -> Bool {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return false }
        let path = StandardizedPath.absolute(expanded)
        return StandardizedPath.isDescendant(
            path,
            of: capability.gitDataRoot.standardizedFullPath
        )
    }

    private static func looksLikeWorkspaceGitDataPath(_ rawPath: String) -> Bool {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        return normalized.hasPrefix("_git_data/") || normalized.contains("/_git_data/")
    }

    private static func isWorkspaceGitDataAlias(_ rawPath: String) -> Bool {
        rawPath.replacingOccurrences(of: "\\", with: "/").hasPrefix("_git_data/")
    }
}
