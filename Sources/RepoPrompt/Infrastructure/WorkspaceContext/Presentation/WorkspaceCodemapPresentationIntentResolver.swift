import Foundation

enum WorkspaceCodemapPresentationIntentResolver {
    static func plan(
        codeMapUsage: CodeMapUsage,
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        profile: PathLocateProfile
    ) async -> WorkspaceCodemapOperationPresentationPlan {
        guard codeMapUsage != .none else {
            return WorkspaceCodemapOperationPresentationPlan(intent: .none, preflightIssues: [])
        }

        let roots = await store.rootRefs(scope: rootScope)
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        var sourceFilesByID: [UUID: WorkspaceFileRecord] = [:]
        let sourcePaths: [String] = switch codeMapUsage {
        case .auto where !selection.codemapAutoEnabled:
            selection.manualCodemapPaths
        case .selected:
            selection.selectedPaths + selection.manualCodemapPaths
        case .auto, .complete, .none:
            selection.selectedPaths
        }
        let selectedRequests = sourcePaths.map {
            WorkspacePathLookupRequest(userPath: $0, profile: profile, rootScope: rootScope)
        }
        let selectedResults = await store.lookupPaths(selectedRequests)
        for path in sourcePaths {
            let result: WorkspacePathLookupResult? = if let batched = selectedResults[path] {
                batched
            } else {
                await store.lookupPath(path, profile: profile, rootScope: rootScope)
            }
            guard let result else { continue }
            if let file = result.file {
                sourceFilesByID[file.id] = file
            } else if let folder = result.folder {
                let prefix = folder.standardizedRelativePath
                for file in await store.files(inRoot: folder.rootID)
                    where prefix.isEmpty
                    || file.standardizedRelativePath == prefix
                    || file.standardizedRelativePath.hasPrefix(prefix + "/")
                {
                    sourceFilesByID[file.id] = file
                }
            }
        }
        if codeMapUsage != .auto || selection.codemapAutoEnabled {
            for path in selection.slices.keys.sorted(by: utf8Precedes) {
                if let file = await store.lookupPath(path, profile: profile, rootScope: rootScope)?.file {
                    sourceFilesByID[file.id] = file
                }
            }
        }

        let requestedFiles: [WorkspaceFileRecord]
        let completeRootSet: Bool
        if codeMapUsage == .complete {
            completeRootSet = true
            var completeFiles: [WorkspaceFileRecord] = []
            for root in roots {
                await completeFiles.append(contentsOf: store.files(inRoot: root.id).filter { file in
                    let fileExtension = (file.name as NSString).pathExtension.lowercased()
                    return !fileExtension.isEmpty
                        && SyntaxManager.supportsCodeMap(fileExtension: fileExtension)
                })
            }
            requestedFiles = completeFiles
        } else {
            completeRootSet = false
            requestedFiles = Array(sourceFilesByID.values)
        }

        let orderedFiles = requestedFiles.sorted { lhs, rhs in
            let lhsRoot = rootsByID[lhs.rootID]?.standardizedFullPath ?? ""
            let rhsRoot = rootsByID[rhs.rootID]?.standardizedFullPath ?? ""
            if lhsRoot != rhsRoot { return lhsRoot.utf8.lexicographicallyPrecedes(rhsRoot.utf8) }
            if lhs.standardizedRelativePath != rhs.standardizedRelativePath {
                return lhs.standardizedRelativePath.utf8.lexicographicallyPrecedes(
                    rhs.standardizedRelativePath.utf8
                )
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let fileIDs = orderedFiles.map(\.id)
        let intent: WorkspaceCodemapOperationPresentationIntent = if codeMapUsage == .auto,
                                                                     selection.codemapAutoEnabled
        {
            .automatic(sourceFileIDs: fileIDs)
        } else {
            .exact(fileIDs: fileIDs, completeRootSet: completeRootSet)
        }
        return WorkspaceCodemapOperationPresentationPlan(intent: intent, preflightIssues: [])
    }

    static func merging(
        _ presentation: WorkspaceCodemapOperationPresentation,
        preflightIssues: [WorkspaceCodemapOperationIssue]
    ) -> WorkspaceCodemapOperationPresentation {
        guard !preflightIssues.isEmpty else { return presentation }
        let issues = presentation.issues + preflightIssues
        let coverage: WorkspaceCodemapOperationPresentationCoverage = switch presentation.coverage {
        case .complete:
            presentation.orderedEntries.isEmpty ? .unavailable(issues) : .partial(issues)
        case .partial:
            .partial(issues)
        case .pending:
            .pending(issues)
        case .unavailable:
            .unavailable(issues)
        }
        return WorkspaceCodemapOperationPresentation(
            id: presentation.id,
            orderedEntries: presentation.orderedEntries,
            coverage: coverage,
            issues: issues,
            publicationReceipt: presentation.publicationReceipt
        )
    }

    private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
