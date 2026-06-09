import Foundation

package enum CodeStructureProjectionService {
    package static let defaultTokenBudget = 6000
    package static let outputSeparator = "\n\n"
    package static let defaultSeparatorTokenCost = TokenCalculationService.estimateTokens(for: outputSeparator)

    private struct RenderableEntry {
        let key: String
        let displayPath: String
        let fileAPI: FileAPI
        let estimatedTokens: Int
    }

    package static func project(
        _ request: CodeStructureProjectionRequest
    ) -> CodeStructureProjection {
        var renderable: [RenderableEntry] = []
        var unmappedPaths: [String] = []
        var seenPaths = Set<String>()
        renderable.reserveCapacity(request.entries.count)
        unmappedPaths.reserveCapacity(request.entries.count)

        for entry in request.entries {
            let key = StandardizedPath.absolute(entry.physicalPath)
            guard seenPaths.insert(key).inserted else { continue }
            if let fileAPI = entry.fileAPI {
                renderable.append(RenderableEntry(
                    key: key,
                    displayPath: entry.displayPath,
                    fileAPI: fileAPI,
                    estimatedTokens: fileAPI.estimatedFullAPIDescriptionTokens(displayPath: entry.displayPath)
                ))
            } else if request.includeUnmappedPaths {
                unmappedPaths.append(entry.displayPath)
            }
        }

        renderable.sort { lhs, rhs in
            if lhs.displayPath == rhs.displayPath { return lhs.key < rhs.key }
            return lhs.displayPath < rhs.displayPath
        }

        let budgetSelection = selectBudgetedCandidates(
            renderable.map { .init(key: $0.key, estimatedTokens: $0.estimatedTokens) },
            resultLimit: request.budget.resultLimit,
            tokenBudget: request.budget.tokenBudget,
            separatorTokenCost: request.budget.separatorTokenCost
        )
        let renderableByKey = Dictionary(uniqueKeysWithValues: renderable.map { ($0.key, $0) })
        let included = budgetSelection.includedKeys.compactMap { renderableByKey[$0] }

        return CodeStructureProjection(
            content: included
                .map { $0.fileAPI.getFullAPIDescription(displayPath: $0.displayPath) }
                .joined(separator: outputSeparator),
            renderedPaths: included.map(\.displayPath),
            unmappedPaths: request.includeUnmappedPaths ? unmappedPaths.sorted() : [],
            omissions: budgetSelection.omissions
        )
    }

    package static func selectBudgetedCandidates(
        _ candidates: [CodeStructureProjection.BudgetCandidate],
        resultLimit: Int,
        tokenBudget: Int = defaultTokenBudget,
        separatorTokenCost: Int = defaultSeparatorTokenCost
    ) -> CodeStructureProjection.BudgetSelection {
        let effectiveResultLimit = max(0, resultLimit)
        let effectiveTokenBudget = max(0, tokenBudget)
        let countCapped = Array(candidates.prefix(effectiveResultLimit))
        let omittedByResultLimit = max(0, candidates.count - countCapped.count)

        var includedKeys: [String] = []
        var usedTokens = 0

        for candidate in countCapped {
            let isFirstEntry = includedKeys.isEmpty
            let entryCost = isFirstEntry
                ? candidate.estimatedTokens
                : candidate.estimatedTokens + max(0, separatorTokenCost)
            if !isFirstEntry, usedTokens + entryCost > effectiveTokenBudget {
                break
            }
            includedKeys.append(candidate.key)
            usedTokens += entryCost
        }

        return CodeStructureProjection.BudgetSelection(
            includedKeys: includedKeys,
            omissions: .init(
                resultLimit: omittedByResultLimit,
                tokenBudget: max(0, countCapped.count - includedKeys.count)
            )
        )
    }

    package static func projectLocalDefinitions(
        _ request: LocalDefinitionProjectionRequest
    ) -> LocalDefinitionProjection {
        guard request.codeMapUsage != .none else { return .empty }

        let selectedAPIs = acceptedFileAPIs(
            from: request.selectedFiles,
            availableFileAPIs: request.availableFileAPIs
        )
        let selectedPaths = Set(request.selectedFiles.map(\.standardizedFullPath))
        let rootFilteredAPIs = filterAPIsToCurrentRoots(
            request.availableFileAPIs,
            roots: request.roots
        )
        let unselectedAPIs = rootFilteredAPIs.filter {
            !selectedPaths.contains(standardizedAPIFilePath($0))
        }

        switch request.codeMapUsage {
        case .none, .selected:
            return .empty
        case .auto:
            let included = CodeMapExtractor.getAutoReferencedAPIs(
                selectedAPIs: selectedAPIs,
                unselectedAPIs: unselectedAPIs
            )
            guard !included.isEmpty else { return .empty }
            let ordered = included.sorted {
                standardizedAPIFilePath($0) < standardizedAPIFilePath($1)
            }
            var output = "\n<Referenced APIs>"
            for fileAPI in ordered {
                output += "\n"
                output += fileAPI.getFullAPIDescription(displayPath: displayPath(
                    for: fileAPI.filePath,
                    pathDisplay: request.pathDisplay,
                    roots: request.roots
                ))
                output += "\n"
            }
            output += "</Referenced APIs>"
            return LocalDefinitionProjection(text: output, fileCount: included.count)
        case .complete:
            guard !unselectedAPIs.isEmpty else { return .empty }
            var output = "\n<Complete Definitions>"
            for fileAPI in unselectedAPIs {
                output += "\n"
                output += fileAPI.getFullAPIDescription(displayPath: displayPath(
                    for: fileAPI.filePath,
                    pathDisplay: request.pathDisplay,
                    roots: request.roots
                ))
                output += "\n"
            }
            output += "</Complete Definitions>"
            return LocalDefinitionProjection(text: output, fileCount: unselectedAPIs.count)
        }
    }

    private static func acceptedFileAPIs(
        from files: [WorkspaceFileRecord],
        availableFileAPIs: [FileAPI]
    ) -> [FileAPI] {
        guard !files.isEmpty, !availableFileAPIs.isEmpty else { return [] }
        let fileAPIsByPath = Dictionary(grouping: availableFileAPIs, by: standardizedAPIFilePath)
        return files.compactMap { fileAPIsByPath[$0.standardizedFullPath]?.first }
    }

    private static func filterAPIsToCurrentRoots(
        _ fileAPIs: [FileAPI],
        roots: [LocalDefinitionProjectionRequest.Root]
    ) -> [FileAPI] {
        guard !fileAPIs.isEmpty, !roots.isEmpty else { return [] }

        var seen = Set<String>()
        var filtered: [FileAPI] = []
        filtered.reserveCapacity(fileAPIs.count)
        for fileAPI in fileAPIs {
            let standardizedPath = standardizedAPIFilePath(fileAPI)
            guard roots.contains(where: {
                StandardizedPath.isDescendant(standardizedPath, of: $0.standardizedPath)
            }), seen.insert(standardizedPath).inserted
            else { continue }
            filtered.append(fileAPI)
        }
        return filtered
    }

    private static func displayPath(
        for absolutePath: String,
        pathDisplay: LocalDefinitionProjectionRequest.PathDisplay,
        roots: [LocalDefinitionProjectionRequest.Root]
    ) -> String {
        guard pathDisplay == .relative else { return absolutePath }
        let standardizedAbsolutePath = StandardizedPath.absolute(absolutePath)
        let matchingRoots = roots
            .filter {
                standardizedAbsolutePath == $0.standardizedPath
                    || standardizedAbsolutePath.hasPrefix($0.standardizedPath + "/")
            }
            .sorted { $0.standardizedPath.count > $1.standardizedPath.count }

        guard let root = matchingRoots.first else {
            return (standardizedAbsolutePath as NSString).lastPathComponent
        }
        let relativePath: String
        if standardizedAbsolutePath == root.standardizedPath {
            relativePath = ""
        } else if standardizedAbsolutePath.hasPrefix(root.standardizedPath + "/") {
            let start = standardizedAbsolutePath.index(root.standardizedPath.endIndex, offsetBy: 1)
            relativePath = String(standardizedAbsolutePath[start...])
        } else {
            relativePath = standardizedAbsolutePath
        }

        guard roots.count > 1 else { return relativePath }
        guard !root.displayName.isEmpty else { return relativePath }
        return relativePath.isEmpty ? root.displayName : "\(root.displayName)/\(relativePath)"
    }

    @inline(__always)
    private static func standardizedAPIFilePath(_ fileAPI: FileAPI) -> String {
        StandardizedPath.absolute(fileAPI.filePath)
    }
}
