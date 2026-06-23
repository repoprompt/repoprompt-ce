import Foundation

package struct WorkspaceRuntimeConfiguration {
    package let maxPendingWatcherEntries: Int
    package let maxParallelScans: Int?
    package let maxFoldersPerBatch: Int
    package let maxRecoveryScanAttempts: Int
    package let recoveryScanRetryBaseNanoseconds: UInt64
    package let runtimePaths: RuntimePaths
    package let globalIgnoreDefaults: @Sendable () -> String

    package init(
        maxPendingWatcherEntries: Int = 50000,
        maxParallelScans: Int? = nil,
        maxFoldersPerBatch: Int = 256,
        maxRecoveryScanAttempts: Int = 3,
        recoveryScanRetryBaseNanoseconds: UInt64 = 50_000_000,
        runtimePaths: RuntimePaths,
        globalIgnoreDefaults: @escaping @Sendable () -> String = { "" }
    ) {
        self.maxPendingWatcherEntries = max(1, maxPendingWatcherEntries)
        self.maxParallelScans = maxParallelScans.map { max(1, $0) }
        self.maxFoldersPerBatch = max(1, maxFoldersPerBatch)
        self.maxRecoveryScanAttempts = max(1, maxRecoveryScanAttempts)
        self.recoveryScanRetryBaseNanoseconds = recoveryScanRetryBaseNanoseconds
        self.runtimePaths = runtimePaths
        self.globalIgnoreDefaults = globalIgnoreDefaults
    }
}

package struct WorkspaceRuntimeDependencies {
    package let watcherFactory: any FileSystemWatcherCreating
    package let currentWatchEventID: @Sendable () -> FileSystemWatchEventID
    package let directoryAccess: any WorkspaceDirectoryAccessing
    package let contentSnapshotReader: any FileContentSnapshotReading
    package let contentDecoder: any FileContentDecoding
    package let mutationBackend: any WorkspaceFileMutationBackend
    package let diagnostics: any RuntimeDiagnosticsSink
    package let configuration: WorkspaceRuntimeConfiguration

    package init(
        watcherFactory: any FileSystemWatcherCreating,
        currentWatchEventID: @escaping @Sendable () -> FileSystemWatchEventID,
        directoryAccess: any WorkspaceDirectoryAccessing,
        contentSnapshotReader: any FileContentSnapshotReading,
        contentDecoder: any FileContentDecoding,
        mutationBackend: any WorkspaceFileMutationBackend,
        diagnostics: any RuntimeDiagnosticsSink = NoOpRuntimeDiagnosticsSink(),
        configuration: WorkspaceRuntimeConfiguration
    ) {
        self.watcherFactory = watcherFactory
        self.currentWatchEventID = currentWatchEventID
        self.directoryAccess = directoryAccess
        self.contentSnapshotReader = contentSnapshotReader
        self.contentDecoder = contentDecoder
        self.mutationBackend = mutationBackend
        self.diagnostics = diagnostics
        self.configuration = configuration
    }
}
