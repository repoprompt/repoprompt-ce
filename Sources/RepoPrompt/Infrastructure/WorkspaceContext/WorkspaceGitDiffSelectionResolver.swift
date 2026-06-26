import Foundation

enum SelectedGitDiffFolderPolicy {
    case filesOnly
    case expandFolders
}

struct WorkspaceSelectedGitPathResolution: Equatable {
    let paths: [String]
    let unresolvedCandidates: [String]
}

enum WorkspaceGitDiffSelectionResolver {
    static func candidates(from selection: StoredSelection) -> [String] {
        var candidates = StoredSelectionPathNormalization.standardizedPaths(selection.selectedPaths)
        var seen = Set(candidates)
        for (path, ranges) in StoredSelectionPathNormalization.standardizedSlices(selection.slices) where !ranges.isEmpty {
            guard seen.insert(path).inserted else { continue }
            candidates.append(path)
        }
        return candidates
    }

    static func selectedGitDiffPaths(
        for selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        folderPolicy: SelectedGitDiffFolderPolicy,
        profile: PathLocateProfile,
        allowFilesystemFallback: Bool
    ) async -> [String] {
        await resolveSelectedGitDiffPaths(
            for: selection,
            store: store,
            rootScope: rootScope,
            folderPolicy: folderPolicy,
            profile: profile,
            allowFilesystemFallback: allowFilesystemFallback,
            excluding: []
        ).paths
    }

    static func resolveSelectedGitDiffPaths(
        for selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        folderPolicy: SelectedGitDiffFolderPolicy,
        profile: PathLocateProfile,
        allowFilesystemFallback: Bool,
        excluding excludedPaths: Set<String>
    ) async -> WorkspaceSelectedGitPathResolution {
        let excluded = Set(excludedPaths.compactMap(StoredSelectionPathNormalization.standardizedPath))
        let candidates = candidates(from: selection).filter { !excluded.contains($0) }
        guard !candidates.isEmpty else {
            return WorkspaceSelectedGitPathResolution(paths: [], unresolvedCandidates: [])
        }

        switch folderPolicy {
        case .filesOnly:
            let resolvedFiles = await store.lookupFiles(atPaths: candidates, profile: profile, rootScope: rootScope)
            let resolvedMap = resolvedFiles.mapValues { $0.standardizedFullPath }
            return resolveFilesOnlyPathResolution(
                candidates: candidates,
                resolvedMap: resolvedMap,
                excludedPaths: excluded,
                normalizeUserInput: normalizeUserInput,
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                allowFilesystemFallback: allowFilesystemFallback
            )
        case .expandFolders:
            return await resolveExpandingFolderPaths(
                candidates: candidates,
                excludedPaths: excluded,
                store: store,
                rootScope: rootScope,
                profile: profile
            )
        }
    }

    static func resolveFilesOnlyPathResolution(
        candidates: [String],
        resolvedMap: [String: String],
        excludedPaths: Set<String>,
        normalizeUserInput: (String) -> String,
        fileExists: (String) -> Bool,
        allowFilesystemFallback: Bool
    ) -> WorkspaceSelectedGitPathResolution {
        var seen = Set<String>()
        var results: [String] = []
        var unresolved: [String] = []
        results.reserveCapacity(candidates.count)
        unresolved.reserveCapacity(candidates.count)

        for raw in candidates {
            if let resolved = resolvedMap[raw] {
                let standardized = StandardizedPath.absolute(resolved)
                if !excludedPaths.contains(standardized) {
                    append(standardized, to: &results, seen: &seen)
                }
                continue
            }

            guard allowFilesystemFallback else {
                unresolved.append(raw)
                continue
            }
            let normalized = normalizeUserInput(raw)
            guard normalized.hasPrefix("/") else {
                unresolved.append(raw)
                continue
            }
            let standardized = StandardizedPath.absolute(normalized)
            if excludedPaths.contains(standardized) {
                continue
            }
            if fileExists(standardized) {
                append(standardized, to: &results, seen: &seen)
            } else {
                unresolved.append(raw)
            }
        }

        return WorkspaceSelectedGitPathResolution(paths: results, unresolvedCandidates: unresolved)
    }

    private static func resolveExpandingFolderPaths(
        candidates: [String],
        excludedPaths: Set<String>,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        profile: PathLocateProfile
    ) async -> WorkspaceSelectedGitPathResolution {
        var seen = Set<String>()
        var selectedPaths: [String] = []
        var unresolved: [String] = []

        let resolvedFiles = await store.lookupFiles(atPaths: candidates, profile: profile, rootScope: rootScope)

        for candidate in candidates {
            if let file = resolvedFiles[candidate] {
                let standardized = StandardizedPath.absolute(file.standardizedFullPath)
                if !excludedPaths.contains(standardized) {
                    append(standardized, to: &selectedPaths, seen: &seen)
                }
                continue
            }

            let expansion = await store.expandFolderInputToFiles(candidate, rootScope: rootScope, profile: profile)
            guard expansion.handled else {
                unresolved.append(candidate)
                continue
            }
            for file in expansion.files {
                let standardized = StandardizedPath.absolute(file.standardizedFullPath)
                guard !excludedPaths.contains(standardized) else { continue }
                append(standardized, to: &selectedPaths, seen: &seen)
            }
        }

        return WorkspaceSelectedGitPathResolution(paths: selectedPaths, unresolvedCandidates: unresolved)
    }

    private static func normalizeUserInput(_ raw: String) -> String {
        (raw as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func append(_ path: String, to results: inout [String], seen: inout Set<String>) {
        let standardized = StandardizedPath.absolute(path)
        guard seen.insert(standardized).inserted else { return }
        results.append(standardized)
    }
}

extension WorkspaceLookupRootScope {
    var allowsSelectedGitDiffFilesystemFallback: Bool {
        switch self {
        case .sessionBoundWorkspace, .validatedSessionBoundWorkspace:
            false
        case .visibleWorkspace, .visibleWorkspacePlusGitData, .allLoaded, .allLoadedExcludingGitData:
            true
        }
    }
}
