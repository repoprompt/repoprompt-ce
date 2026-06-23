import Foundation
@testable import RepoPromptCore
import RepoPromptCoreMacOS

func makeMacOSTestWorkspaceRuntimeDependencies(
    maxPendingWatcherEntries: Int = 50_000,
    maxParallelScans: Int? = nil,
    maxFoldersPerBatch: Int = 256,
    maxRecoveryScanAttempts: Int = 3,
    recoveryScanRetryBaseNanoseconds: UInt64 = 50_000_000
) -> WorkspaceRuntimeDependencies {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RepoPromptCoreMacOSTests-Runtime", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return WorkspaceRuntimeDependencies(
        watcherFactory: MacOSFSEventsWatcherFactory(),
        currentWatchEventID: { MacOSFSEventsJournal.currentEventID() },
        directoryAccess: MacOSWorkspaceDirectoryAccess(),
        contentSnapshotReader: MacOSFileContentSnapshotReader(),
        contentDecoder: MacOSFileContentDecoder(),
        mutationBackend: MacOSWorkspaceFileMutationBackend(),
        configuration: WorkspaceRuntimeConfiguration(
            maxPendingWatcherEntries: maxPendingWatcherEntries,
            maxParallelScans: maxParallelScans,
            maxFoldersPerBatch: maxFoldersPerBatch,
            maxRecoveryScanAttempts: maxRecoveryScanAttempts,
            recoveryScanRetryBaseNanoseconds: recoveryScanRetryBaseNanoseconds,
            runtimePaths: RuntimePaths(
                stateRoot: root,
                cacheRoot: root.appendingPathComponent("Cache", isDirectory: true),
                codeMapCacheRoot: root.appendingPathComponent("CodeMapCaches", isDirectory: true),
                agentSupportRoot: root.appendingPathComponent("Agents", isDirectory: true)
            )
        )
    )
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
            runtimeDependencies: makeMacOSTestWorkspaceRuntimeDependencies()
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
            maxPendingWatcherIngressEntriesOverride: Int? = nil,
            maxRecoveryScanAttemptsOverride: Int? = nil,
            recoveryScanRetryBaseNanosecondsOverride: UInt64? = nil,
            recoveryScanSleep: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
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
                maxRecoveryScanAttemptsOverride: maxRecoveryScanAttemptsOverride,
                recoveryScanRetryBaseNanosecondsOverride: recoveryScanRetryBaseNanosecondsOverride,
                recoveryScanSleep: recoveryScanSleep,
                runtimeDependencies: makeMacOSTestWorkspaceRuntimeDependencies(
                    maxPendingWatcherEntries: maxPendingWatcherIngressEntriesOverride ?? 50_000,
                    maxParallelScans: maxParallelScansOverride,
                    maxFoldersPerBatch: maxFoldersPerBatchOverride ?? 256,
                    maxRecoveryScanAttempts: maxRecoveryScanAttemptsOverride ?? 3,
                    recoveryScanRetryBaseNanoseconds: recoveryScanRetryBaseNanosecondsOverride ?? 50_000_000
                )
            )
        }
    #endif
}

#if DEBUG
    typealias EditFlowPerf = WorkspaceRuntimePerf
#endif
