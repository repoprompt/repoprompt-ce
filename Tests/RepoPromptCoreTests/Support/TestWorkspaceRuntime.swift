import Darwin
import Foundation
@testable import RepoPromptCore

private struct TestFileContentSnapshotReader: FileContentSnapshotReading {
    func fingerprint(atPath path: String) throws -> FileContentFingerprint {
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0 else { throw error(for: errno) }
        return try fingerprint(from: info)
    }

    func fingerprint(fileDescriptor: Int32) throws -> FileContentFingerprint {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else { throw error(for: errno) }
        return try fingerprint(from: info)
    }

    func openReadOnlyFileHandle(atPath path: String) throws -> FileHandle {
        let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw error(for: errno) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func fingerprint(from info: stat) throws -> FileContentFingerprint {
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw FileContentSnapshotAccessError.notRegularFile
        }
        return FileContentFingerprint(
            deviceID: UInt64(info.st_dev),
            fileNumber: UInt64(info.st_ino),
            byteSize: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(info.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    private func error(for number: Int32) -> FileContentSnapshotAccessError {
        .operationFailed(errorNumber: number)
    }
}

private final class TestEncodingDetectionSession: FileContentEncodingDetectionSession {
    func analyzeNextChunk(_: Data) -> Bool { true }
    func finishEncodingRawValue() -> UInt? { String.Encoding.utf8.rawValue }
}

private struct TestFileContentDecoder: FileContentDecoding {
    func decode(_ data: Data) -> DecodedFileContent? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        return DecodedFileContent(string: string, encodingRawValue: String.Encoding.utf8.rawValue)
    }

    func detectEncodingRawValue(in data: Data) -> UInt? {
        String(data: data, encoding: .utf8) == nil ? nil : String.Encoding.utf8.rawValue
    }

    func isProbablyBinary(_ data: Data) -> Bool { data.prefix(8192).contains(0) }
    func makeEncodingDetectionSession() -> any FileContentEncodingDetectionSession { TestEncodingDetectionSession() }
}

private final class TestFileSystemWatcher: FileSystemWatching, @unchecked Sendable {
    private let path: String
    private let initialPaths: Set<String>
    private(set) var isWatching = false
    private var eventID: FileSystemWatchEventID?

    init(path: String) {
        self.path = path
        initialPaths = Self.descendantPaths(at: path)
    }

    func start(
        from eventID: FileSystemWatchEventID,
        eventHandler: @escaping @Sendable (FileSystemWatchEventPayload) -> Void
    ) throws {
        self.eventID = eventID
        isWatching = true
        let added = Self.descendantPaths(at: path).subtracting(initialPaths).sorted()
        if !added.isEmpty {
            eventHandler(FileSystemWatchEventPayload(entries: added.enumerated().map { index, path in
                FileSystemWatchEvent(
                    path: path,
                    flags: [.itemCreated, .itemIsFile],
                    id: eventID &+ FileSystemWatchEventID(index + 1)
                )
            }))
        }
    }

    func flush() {}
    func latestEventID() -> FileSystemWatchEventID? { eventID }
    func stop() { isWatching = false }

    private static func descendantPaths(at path: String) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return [] }
        return Set(enumerator.compactMap { item in
            guard let relativePath = item as? String else { return nil }
            let absolutePath = URL(fileURLWithPath: path).appendingPathComponent(relativePath).path
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return nil }
            return absolutePath
        })
    }
}

private struct TestFileSystemWatcherFactory: FileSystemWatcherCreating {
    func makeWatcher(path: String) -> any FileSystemWatching { TestFileSystemWatcher(path: path) }
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

    func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }
    func trashItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }

    func fileExists(atPath path: String, isDirectory: inout Bool) -> Bool {
        var value = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &value)
        isDirectory = value.boolValue
        return exists
    }

    func isWritableFile(atPath path: String) -> Bool { FileManager.default.isWritableFile(atPath: path) }

    func isSymbolicLink(atPath path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    func modificationDate(at url: URL) throws -> Date {
        guard let date = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        return date
    }
}

private struct TestWorkspaceDirectoryAccess: WorkspaceDirectoryAccessing {
    func listDirectoryWithIgnoreDetection(at path: String) throws -> WorkspaceDirectoryScanResult {
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        var entries: [WorkspaceDirectoryEntry] = []
        entries.reserveCapacity(urls.count)
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            entries.append(WorkspaceDirectoryEntry(
                name: url.lastPathComponent,
                isDir: values.isDirectory == true,
                isSym: values.isSymbolicLink == true
            ))
        }
        entries.sort { $0.name < $1.name }
        let names = Set(entries.map(\.name))
        return WorkspaceDirectoryScanResult(
            entries: entries,
            hasGitignore: names.contains(".gitignore"),
            hasRepoIgnore: names.contains(".repoignore"),
            hasCursorignore: names.contains(".cursorignore")
        )
    }

    func directoryIdentity(followingSymlinksAt path: String) -> WorkspaceDirectoryIdentity? {
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0 else { return nil }
        return WorkspaceDirectoryIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    func canonicalPath(for path: String) -> String? {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return FileManager.default.fileExists(atPath: canonical) ? canonical : nil
    }
}

func makeTestWorkspaceRuntimeDependencies(
    maxPendingWatcherEntries: Int = 50_000,
    maxParallelScans: Int? = nil,
    maxFoldersPerBatch: Int = 256,
    maxRecoveryScanAttempts: Int = 3,
    recoveryScanRetryBaseNanoseconds: UInt64 = 50_000_000,
    diagnostics: any RuntimeDiagnosticsSink = NoOpRuntimeDiagnosticsSink()
) -> WorkspaceRuntimeDependencies {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RepoPromptCoreTests-Runtime", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let paths = RuntimePaths(
        stateRoot: root,
        cacheRoot: root.appendingPathComponent("Cache", isDirectory: true),
        codeMapCacheRoot: root.appendingPathComponent("CodeMapCaches", isDirectory: true),
        agentSupportRoot: root.appendingPathComponent("Agents", isDirectory: true)
    )
    return WorkspaceRuntimeDependencies(
        watcherFactory: TestFileSystemWatcherFactory(),
        currentWatchEventID: { 0 },
        directoryAccess: TestWorkspaceDirectoryAccess(),
        contentSnapshotReader: TestFileContentSnapshotReader(),
        contentDecoder: TestFileContentDecoder(),
        mutationBackend: TestWorkspaceFileMutationBackend(),
        diagnostics: diagnostics,
        configuration: WorkspaceRuntimeConfiguration(
            maxPendingWatcherEntries: maxPendingWatcherEntries,
            maxParallelScans: maxParallelScans,
            maxFoldersPerBatch: maxFoldersPerBatch,
            maxRecoveryScanAttempts: maxRecoveryScanAttempts,
            recoveryScanRetryBaseNanoseconds: recoveryScanRetryBaseNanoseconds,
            runtimePaths: paths
        )
    )
}

extension WorkspaceFileContextStore {
    init(
        searchLaneConfiguration: StoreBackedWorkspaceSearchLane.Configuration = .production,
        debugNowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy = .production,
        enableCatalogShardShadowValidation: Bool = true
    ) {
        self.init(
            runtimeDependencies: makeTestWorkspaceRuntimeDependencies(),
            searchLaneConfiguration: searchLaneConfiguration,
            debugNowNanoseconds: debugNowNanoseconds,
            unloadTerminationPolicy: unloadTerminationPolicy,
            enableCatalogShardShadowValidation: enableCatalogShardShadowValidation
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
            runtimeDependencies: makeTestWorkspaceRuntimeDependencies()
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
                runtimeDependencies: makeTestWorkspaceRuntimeDependencies(
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
