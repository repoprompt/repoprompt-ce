import Foundation
import RepoPromptDomainRuntime

struct WorkspaceFileEditHost: FileEditHost {
    let mutationService: WorkspaceFileMutationService
    let selectionCoordinator: WorkspaceSelectionCoordinator?
    let lookupRootScope: WorkspaceLookupRootScope
    let createPathResolutionPolicy: WorkspaceFileCreatePathResolutionPolicy
    let selectCreatedFiles: Bool
    let mutationRootMappings: [DomainMutationPhysicalRootMapping]

    init(
        store: WorkspaceFileContextStore,
        selectionCoordinator: WorkspaceSelectionCoordinator? = nil,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        createPathResolutionPolicy: WorkspaceFileCreatePathResolutionPolicy = .literalPreferredIfStronger,
        selectCreatedFiles: Bool = true,
        mutationRootMappings: [DomainMutationPhysicalRootMapping] = []
    ) {
        mutationService = WorkspaceFileMutationService(store: store)
        self.selectionCoordinator = selectionCoordinator
        self.lookupRootScope = lookupRootScope
        self.createPathResolutionPolicy = createPathResolutionPolicy
        self.selectCreatedFiles = selectCreatedFiles
        self.mutationRootMappings = mutationRootMappings
    }

    func fileExists(path: String) async -> Bool {
        await (mutationService.exactExistingFile(path, rootScope: lookupRootScope)) != nil
    }

    func readText(path: String) async throws -> String {
        let resolved = try await mutationService.resolveExactExistingFileForMutation(path, rootScope: lookupRootScope)
        return try await mutationService.readText(file: resolved) ?? ""
    }

    func writeText(path: String, content: String, overwrite: Bool) async throws {
        if overwrite {
            let resolved = await mutationService.exactExistingFile(path, rootScope: lookupRootScope)
            try Task.checkCancellation()
            if let resolved {
                try await mutationService.overwrite(
                    file: resolved,
                    content: content,
                    mutationRootMappings: mutationRootMappings
                )
                return
            }
        }

        try Task.checkCancellation()
        let writeResult = try await mutationService.createFileWithPostcondition(
            userPath: path,
            content: content,
            rootScope: lookupRootScope,
            selectedFileFullPaths: (path as NSString).expandingTildeInPath.hasPrefix("/") ? [] : selectedFileFullPaths(),
            pathResolutionPolicy: createPathResolutionPolicy,
            mutationRootMappings: mutationRootMappings
        )
        if selectCreatedFiles, let selectionCoordinator, let created = writeResult.materializedFile {
            _ = await selectionCoordinator.addPathsToActiveSelection(
                paths: [created.standardizedFullPath],
                mode: "full",
                rootScope: lookupRootScope
            )
        }
    }

    @MainActor
    private func selectedFileFullPaths() -> Set<String> {
        guard let selectionCoordinator else { return [] }
        let snapshot = selectionCoordinator.activeSelectionSnapshot(flushPendingUI: true)
        return Set(StoredSelectionPathNormalization.standardizedPaths(snapshot.selection.selectedPaths))
    }
}
