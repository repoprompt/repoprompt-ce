import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
@testable import RepoPromptCoreMacOS

func makeAppTestWorkspaceRuntimeDependencies(
    maxPendingWatcherEntries: Int = 50000,
    maxParallelScans: Int? = nil,
    maxFoldersPerBatch: Int = 256,
    diagnostics: (any WorkspaceRuntimeDiagnosticsSink)? = nil
) -> WorkspaceRuntimeDependencies {
    let diagnostics = diagnostics ?? EmbeddedWorkspaceRuntimeDiagnosticsSink()
    WorkspaceRuntimePerf.installProcessSink(diagnostics)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RepoPromptTests-Runtime", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return WorkspaceRuntimeDependencies(
        watcherFactory: MacOSFSEventsWatcherFactory(),
        directoryListingBackend: MacOSWorkspaceDirectoryListingBackend(),
        mutationBackend: EmbeddedWorkspaceFileMutationBackend(),
        partitionRoot: root.appendingPathComponent("Partitions", isDirectory: true),
        codeMapCacheRoot: root.appendingPathComponent("CodeMapCaches", isDirectory: true),
        configuration: WorkspaceRuntimeConfiguration(
            maxPendingWatcherEntries: maxPendingWatcherEntries,
            maxParallelScans: maxParallelScans,
            maxFoldersPerBatch: maxFoldersPerBatch,
            agentSupportRoot: root.appendingPathComponent("Agents", isDirectory: true),
            globalIgnoreDefaults: ""
        ),
        diagnostics: diagnostics
    )
}

extension WorkspaceFileContextStore {
    init() {
        self.init(runtimeDependencies: makeAppTestWorkspaceRuntimeDependencies())
    }
}

@MainActor
extension WorkspaceFilesViewModel {
    convenience init(workspaceFileContextStore: WorkspaceFileContextStore) {
        let runtime = RepoPromptEmbeddedWorkspaceRuntimeFactory().makeRuntime()
        self.init(
            workspaceFileContextStore: workspaceFileContextStore,
            selectionSliceCoordinator: runtime.selectionSliceCoordinator
        )
    }
}

extension FileSystemService {
    init(
        path: String,
        respectGitignore: Bool = true,
        respectRepoIgnore: Bool = true,
        respectCursorignore: Bool = true,
        skipSymlinks: Bool = true,
        enableHierarchicalIgnores: Bool = true
    ) async throws {
        try await self.init(
            path: path,
            respectGitignore: respectGitignore,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            skipSymlinks: skipSymlinks,
            enableHierarchicalIgnores: enableHierarchicalIgnores,
            dependencies: makeAppTestWorkspaceRuntimeDependencies()
        )
    }

    #if DEBUG
        init(
            path: String,
            respectGitignore: Bool = true,
            respectRepoIgnore: Bool = true,
            respectCursorignore: Bool = true,
            skipSymlinks: Bool = true,
            enableHierarchicalIgnores: Bool = true,
            testVisitedPaths: Set<String>? = nil,
            testVisitedItems: [String: Bool]? = nil,
            testIgnoreRules: IgnoreRules? = nil,
            isTestMode: Bool = false,
            fileManagerOverride: (any FileSystemProviding)? = nil,
            maxParallelScansOverride: Int? = nil,
            maxFoldersPerBatchOverride: Int? = nil,
            maxPendingWatcherIngressEntriesOverride: Int? = nil
        ) async throws {
            try await self.init(
                path: path,
                respectGitignore: respectGitignore,
                respectRepoIgnore: respectRepoIgnore,
                respectCursorignore: respectCursorignore,
                skipSymlinks: skipSymlinks,
                enableHierarchicalIgnores: enableHierarchicalIgnores,
                testVisitedPaths: testVisitedPaths,
                testVisitedItems: testVisitedItems,
                testIgnoreRules: testIgnoreRules,
                isTestMode: isTestMode,
                fileManagerOverride: fileManagerOverride,
                maxParallelScansOverride: maxParallelScansOverride,
                maxFoldersPerBatchOverride: maxFoldersPerBatchOverride,
                maxPendingWatcherIngressEntriesOverride: maxPendingWatcherIngressEntriesOverride,
                dependencies: makeAppTestWorkspaceRuntimeDependencies(
                    maxPendingWatcherEntries: maxPendingWatcherIngressEntriesOverride ?? 50000,
                    maxParallelScans: maxParallelScansOverride,
                    maxFoldersPerBatch: maxFoldersPerBatchOverride ?? 256
                )
            )
        }
    #endif
}
