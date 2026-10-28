import Foundation
import RepoPromptDomainRuntime
import RepoPromptFoundation

struct WorkspaceFileEditHost: FileEditHost {
    @MainActor
    final class WriteReceipt {
        private(set) var file: WorkspaceFileRecord?

        func record(_ file: WorkspaceFileRecord?) {
            self.file = file
        }
    }

    enum Target {
        case existing(WorkspaceFileRecord)
        case create(path: String)
    }

    let mutationService: WorkspaceFileMutationService
    let target: Target
    let selectionCoordinator: WorkspaceSelectionCoordinator?
    let lookupRootScope: WorkspaceLookupRootScope
    let createPathResolutionPolicy: WorkspaceFileCreatePathResolutionPolicy
    let selectCreatedFiles: Bool
    let mutationRootMappings: [DomainMutationPhysicalRootMapping]
    let writeReceipt: WriteReceipt?

    init(
        store: WorkspaceFileContextStore,
        target: Target,
        selectionCoordinator: WorkspaceSelectionCoordinator? = nil,
        lookupRootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        createPathResolutionPolicy: WorkspaceFileCreatePathResolutionPolicy = .literalPreferredIfStronger,
        selectCreatedFiles: Bool = true,
        mutationRootMappings: [DomainMutationPhysicalRootMapping] = [],
        writeReceipt: WriteReceipt? = nil
    ) {
        mutationService = WorkspaceFileMutationService(store: store)
        self.target = target
        self.selectionCoordinator = selectionCoordinator
        self.lookupRootScope = lookupRootScope
        self.createPathResolutionPolicy = createPathResolutionPolicy
        self.selectCreatedFiles = selectCreatedFiles
        self.mutationRootMappings = mutationRootMappings
        self.writeReceipt = writeReceipt
    }

    func fileExists(path _: String) async -> Bool {
        if case .existing = target { return true }
        return false
    }

    func readText(path _: String) async throws -> String {
        guard case let .existing(file) = target else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext("Cannot read a missing file before creation.")
        }
        guard let content = try await mutationService.readText(file: file) else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext(
                "The resolved file is no longer present or readable."
            )
        }
        return content
    }

    func writeTextIfUnchanged(path _: String, content: String, expectedOriginalText: String) async throws {
        guard case let .existing(file) = target else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext("Approved writes require an existing file.")
        }
        try Task.checkCancellation()
        try await mutationService.overwriteIfUnchanged(
            file: file,
            content: content,
            expectedOriginalContent: expectedOriginalText,
            mutationRootMappings: mutationRootMappings
        )
    }

    func writeText(path _: String, content: String, overwrite: Bool) async throws {
        switch target {
        case let .existing(file):
            guard overwrite else {
                throw FileManagerError.fileSystemServiceNotFoundWithContext("Existing file write requires overwrite semantics.")
            }
            try Task.checkCancellation()
            try await mutationService.overwrite(
                file: file,
                content: content,
                mutationRootMappings: mutationRootMappings
            )
            await writeReceipt?.record(file)

        case let .create(path):
            try Task.checkCancellation()
            let writeResult = try await mutationService.createFileWithPostcondition(
                userPath: path,
                content: content,
                overwrite: overwrite,
                rootScope: lookupRootScope,
                selectedFileFullPaths: (path as NSString).expandingTildeInPath.hasPrefix("/") ? [] : selectedFileFullPaths(),
                pathResolutionPolicy: createPathResolutionPolicy,
                mutationRootMappings: mutationRootMappings
            )
            await writeReceipt?.record(writeResult.materializedFile)
            if selectCreatedFiles, let selectionCoordinator, let created = writeResult.materializedFile {
                _ = await selectionCoordinator.addPathsToActiveSelection(
                    paths: [created.standardizedFullPath],
                    mode: "full",
                    rootScope: lookupRootScope
                )
            }
        }
    }

    @MainActor
    private func selectedFileFullPaths() -> Set<String> {
        guard let selectionCoordinator else { return [] }
        let snapshot = selectionCoordinator.activeSelectionSnapshot(flushPendingUI: true)
        return Set(StoredSelectionPathNormalization.standardizedPaths(snapshot.selection.selectedPaths))
    }
}
