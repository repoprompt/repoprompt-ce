import Foundation
@testable import RepoPromptCore

private final class TestFileSystemWatcher: FileSystemWatching, @unchecked Sendable {
    private(set) var isWatching = false

    func start(eventHandler _: @escaping @Sendable (FileSystemWatchEventPayload) -> Void) -> Bool {
        isWatching = true
        return true
    }

    func stop() {
        isWatching = false
    }
}

private struct TestFileSystemWatcherFactory: FileSystemWatcherCreating {
    func makeWatcher(path _: String) -> any FileSystemWatching {
        TestFileSystemWatcher()
    }
}

private struct TestWorkspaceFileMutationBackend: WorkspaceFileMutationBackend {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func createFile(at url: URL, contents: Data?) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: contents) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func write(_ data: Data, to url: URL, atomically: Bool) throws {
        try data.write(to: url, options: atomically ? .atomic : [])
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func trashItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func fileExists(atPath path: String, isDirectory: inout Bool) -> Bool {
        var directoryFlag = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directoryFlag)
        isDirectory = directoryFlag.boolValue
        return exists
    }

    func modificationDate(at url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        return date
    }
}

private struct TestWorkspaceDirectoryListingBackend: WorkspaceDirectoryListingBackend {
    func listDirectoryWithIgnoreDetection(at path: String) throws -> WorkspaceDirectoryScanResult {
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        var hasGitignore = false
        var hasRepoIgnore = false
        var hasCursorignore = false
        var entries: [WorkspaceDirectoryEntry] = []
        entries.reserveCapacity(urls.count)
        for url in urls {
            var isDirectory = ObjCBool(false)
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let name = url.lastPathComponent
            hasGitignore = hasGitignore || name == ".gitignore"
            hasRepoIgnore = hasRepoIgnore || name == ".repoignore"
            hasCursorignore = hasCursorignore || name == ".cursorignore"
            entries.append(WorkspaceDirectoryEntry(
                name: name,
                isDirectory: isDirectory.boolValue,
                isSymbolicLink: attributes[.type] as? FileAttributeType == .typeSymbolicLink
            ))
        }
        entries.sort { $0.name < $1.name }
        return WorkspaceDirectoryScanResult(
            entries: entries,
            hasGitignore: hasGitignore,
            hasRepoIgnore: hasRepoIgnore,
            hasCursorignore: hasCursorignore
        )
    }

    func directoryIdentity(followingSymlinksAt path: String) -> WorkspaceDirectoryIdentity? {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: canonical) else { return nil }
        return WorkspaceDirectoryIdentity(device: 0, inode: canonical.testFNV1a64)
    }

    func canonicalPath(for path: String) -> String? {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return FileManager.default.fileExists(atPath: canonical) ? canonical : nil
    }
}

private extension String {
    var testFNV1a64: UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

func makeTestWorkspaceRuntimeDependencies(
    maxPendingWatcherEntries: Int = 50_000,
    maxParallelScans: Int? = nil,
    maxFoldersPerBatch: Int = 256,
    diagnostics: any WorkspaceRuntimeDiagnosticsSink = NoopWorkspaceRuntimeDiagnosticsSink()
) -> WorkspaceRuntimeDependencies {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RepoPromptCoreTests-Runtime", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return WorkspaceRuntimeDependencies(
        watcherFactory: TestFileSystemWatcherFactory(),
        directoryListingBackend: TestWorkspaceDirectoryListingBackend(),
        mutationBackend: TestWorkspaceFileMutationBackend(),
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
        self.init(runtimeDependencies: makeTestWorkspaceRuntimeDependencies())
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
            dependencies: makeTestWorkspaceRuntimeDependencies()
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
                dependencies: makeTestWorkspaceRuntimeDependencies(
                    maxPendingWatcherEntries: maxPendingWatcherIngressEntriesOverride ?? 50_000,
                    maxParallelScans: maxParallelScansOverride,
                    maxFoldersPerBatch: maxFoldersPerBatchOverride ?? 256
                )
            )
        }
    #endif
}
