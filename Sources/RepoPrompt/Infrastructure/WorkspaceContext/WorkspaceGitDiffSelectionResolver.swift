import Foundation

enum SelectedGitDiffFolderPolicy {
    case filesOnly
    case expandFolders
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
        let candidates = candidates(from: selection)
        guard !candidates.isEmpty else { return [] }

        switch folderPolicy {
        case .filesOnly:
            let resolvedFiles = await store.lookupFiles(atPaths: candidates, profile: profile, rootScope: rootScope)
            let resolvedMap = resolvedFiles.mapValues { $0.standardizedFullPath }
            return resolveFilesOnlyPaths(
                candidates: candidates,
                resolvedMap: resolvedMap,
                normalizeUserInput: normalizeUserInput,
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                allowFilesystemFallback: allowFilesystemFallback
            )
        case .expandFolders:
            return await resolveExpandingFolderPaths(
                candidates: candidates,
                store: store,
                rootScope: rootScope,
                profile: profile
            )
        }
    }

    static func resolveFilesOnlyPaths(
        candidates: [String],
        resolvedMap: [String: String],
        normalizeUserInput: (String) -> String,
        fileExists: (String) -> Bool,
        allowFilesystemFallback: Bool
    ) -> [String] {
        var seen = Set<String>()
        var results: [String] = []
        results.reserveCapacity(candidates.count)

        for raw in candidates {
            if let resolved = resolvedMap[raw] {
                append(StandardizedPath.absolute(resolved), to: &results, seen: &seen)
                continue
            }

            guard allowFilesystemFallback else { continue }
            let normalized = normalizeUserInput(raw)
            guard normalized.hasPrefix("/") else { continue }
            let standardized = StandardizedPath.absolute(normalized)
            if fileExists(standardized) {
                append(standardized, to: &results, seen: &seen)
            }
        }

        return results
    }

    private static func resolveExpandingFolderPaths(
        candidates: [String],
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        profile: PathLocateProfile
    ) async -> [String] {
        var seen = Set<String>()
        var selectedPaths: [String] = []

        let resolvedFiles = await store.lookupFiles(atPaths: candidates, profile: profile, rootScope: rootScope)

        for candidate in candidates {
            if let file = resolvedFiles[candidate] {
                append(file.standardizedFullPath, to: &selectedPaths, seen: &seen)
                continue
            }

            let expansion = await store.expandFolderInputToFiles(candidate, rootScope: rootScope, profile: profile)
            guard expansion.handled else { continue }
            for file in expansion.files {
                append(file.standardizedFullPath, to: &selectedPaths, seen: &seen)
            }
        }

        return selectedPaths
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
        case .visibleWorkspace, .visibleWorkspacePlusGitData, .allLoaded:
            true
        }
    }
}
