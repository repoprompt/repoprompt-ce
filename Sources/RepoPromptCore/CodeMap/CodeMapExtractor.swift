import Foundation

/// Neutral code-map relationship extraction used by selection and prompt adapters.
package enum CodeMapExtractor {
    @inline(__always)
    private static func standardizedAPIFilePath(_ api: FileAPI) -> String {
        StandardizedPath.absolute(api.filePath)
    }

    private static func acceptedFileAPIs(
        from files: [WorkspaceFileRecord],
        allFileAPIs: [FileAPI]
    ) -> [FileAPI] {
        guard !files.isEmpty, !allFileAPIs.isEmpty else { return [] }
        let pathGrouping = WorkspaceRuntimePerf.begin(
            WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.pathGrouping
        )
        let apisByPath = Dictionary(grouping: allFileAPIs, by: standardizedAPIFilePath)
        WorkspaceRuntimePerf.end(
            WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.pathGrouping,
            pathGrouping
        )
        let selectedRecordProjection = WorkspaceRuntimePerf.begin(
            WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection
        )
        let selectedAPIs = files.compactMap { apisByPath[$0.standardizedFullPath]?.first }
        WorkspaceRuntimePerf.end(
            WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection,
            selectedRecordProjection
        )
        return selectedAPIs
    }

    private static func acceptedFileAPIs(
        from files: [WorkspaceFileRecord],
        firstFileAPIByStandardizedNestedPath: [String: FileAPI]
    ) -> [FileAPI] {
        guard !files.isEmpty, !firstFileAPIByStandardizedNestedPath.isEmpty else { return [] }
        let selectedRecordProjection = WorkspaceRuntimePerf.begin(
            WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection
        )
        let selectedAPIs = files.compactMap { firstFileAPIByStandardizedNestedPath[$0.standardizedFullPath] }
        WorkspaceRuntimePerf.end(
            WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection,
            selectedRecordProjection
        )
        return selectedAPIs
    }

    package static func getAutoReferencedAPIs(
        selectedAPIs: [FileAPI],
        unselectedAPIs: [FileAPI]
    ) -> [FileAPI] {
        guard !selectedAPIs.isEmpty else { return [] }
        var typeToFileAPI: [String: FileAPI] = [:]
        for api in unselectedAPIs {
            for type in api.definedTypeNames {
                typeToFileAPI[type] = api
            }
        }

        let referencedTypes = Set(selectedAPIs.flatMap(\.referencedTypes))
        let localRefs = referencedTypes.compactMap { typeToFileAPI[$0] }
        var seen = Set<String>()
        var included: [FileAPI] = []
        for api in localRefs where seen.insert(standardizedAPIFilePath(api)).inserted {
            included.append(api)
        }
        return included
    }

    package static func resolveReferencedFilePaths(
        from selectedFiles: [WorkspaceFileRecord],
        among allFileAPIs: [FileAPI]
    ) -> [String] {
        guard !selectedFiles.isEmpty else { return [] }
        let acceptedFileAPIFilter = WorkspaceRuntimePerf.begin(
            WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.acceptedFileAPIFilter
        )
        let selectedAPIs = acceptedFileAPIs(from: selectedFiles, allFileAPIs: allFileAPIs)
        WorkspaceRuntimePerf.end(
            WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.acceptedFileAPIFilter,
            acceptedFileAPIFilter
        )
        return resolveReferencedFilePaths(
            from: selectedFiles,
            selectedAPIs: selectedAPIs,
            among: allFileAPIs
        )
    }

    package static func resolveReferencedFilePaths(
        from selectedFiles: [WorkspaceFileRecord],
        among allFileAPIs: [FileAPI],
        firstFileAPIByStandardizedNestedPath: [String: FileAPI]
    ) -> [String] {
        guard !selectedFiles.isEmpty else { return [] }
        let acceptedFileAPIFilter = WorkspaceRuntimePerf.begin(
            WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.acceptedFileAPIFilter
        )
        let selectedAPIs = acceptedFileAPIs(
            from: selectedFiles,
            firstFileAPIByStandardizedNestedPath: firstFileAPIByStandardizedNestedPath
        )
        WorkspaceRuntimePerf.end(
            WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.acceptedFileAPIFilter,
            acceptedFileAPIFilter
        )
        return resolveReferencedFilePaths(
            from: selectedFiles,
            selectedAPIs: selectedAPIs,
            among: allFileAPIs
        )
    }

    private static func resolveReferencedFilePaths(
        from selectedFiles: [WorkspaceFileRecord],
        selectedAPIs: [FileAPI],
        among allFileAPIs: [FileAPI]
    ) -> [String] {
        guard !selectedAPIs.isEmpty else { return [] }
        let selectedPaths = Set(selectedFiles.map(\.standardizedFullPath))
        let unselectedAPIs = allFileAPIs.filter { !selectedPaths.contains(standardizedAPIFilePath($0)) }
        let computation = WorkspaceRuntimePerf.begin(
            WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.autoReferencedAPIComputation
        )
        let referencedAPIs = getAutoReferencedAPIs(
            selectedAPIs: selectedAPIs,
            unselectedAPIs: unselectedAPIs
        )
        WorkspaceRuntimePerf.end(
            WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.autoReferencedAPIComputation,
            computation
        )

        var seen = Set<String>()
        var ordered: [String] = []
        for api in referencedAPIs {
            let standardized = standardizedAPIFilePath(api)
            if seen.insert(standardized).inserted {
                ordered.append(standardized)
            }
        }
        return ordered
    }
}
