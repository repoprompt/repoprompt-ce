import Foundation

package struct WorkspaceRuntimeConfiguration {
    package let maxPendingWatcherEntries: Int
    package let maxParallelScans: Int?
    package let maxFoldersPerBatch: Int
    package let agentSupportRoot: URL
    package let globalIgnoreDefaults: String

    package init(
        maxPendingWatcherEntries: Int = 50000,
        maxParallelScans: Int? = nil,
        maxFoldersPerBatch: Int = 256,
        agentSupportRoot: URL,
        globalIgnoreDefaults: String
    ) {
        self.maxPendingWatcherEntries = max(1, maxPendingWatcherEntries)
        self.maxParallelScans = maxParallelScans.map { max(1, $0) }
        self.maxFoldersPerBatch = max(1, maxFoldersPerBatch)
        self.agentSupportRoot = agentSupportRoot.standardizedFileURL
        self.globalIgnoreDefaults = globalIgnoreDefaults
    }
}

package struct WorkspaceRuntimeDependencies {
    package let watcherFactory: any FileSystemWatcherCreating
    package let directoryListingBackend: any WorkspaceDirectoryListingBackend
    package let fileContentSnapshotReader: any FileContentSnapshotReading
    package let mutationBackend: (any WorkspaceFileMutationBackend)?
    package let partitionRoot: URL
    package let partitionSaveEventSink: PartitionStoreSaveEventSink
    package let codeMapCacheRoot: URL
    package let configuration: WorkspaceRuntimeConfiguration
    package let diagnostics: any WorkspaceRuntimeDiagnosticsSink

    package init(
        watcherFactory: any FileSystemWatcherCreating,
        directoryListingBackend: any WorkspaceDirectoryListingBackend,
        fileContentSnapshotReader: any FileContentSnapshotReading,
        mutationBackend: (any WorkspaceFileMutationBackend)?,
        partitionRoot: URL,
        partitionSaveEventSink: @escaping PartitionStoreSaveEventSink = { _ in },
        codeMapCacheRoot: URL,
        configuration: WorkspaceRuntimeConfiguration,
        diagnostics: any WorkspaceRuntimeDiagnosticsSink = NoopWorkspaceRuntimeDiagnosticsSink()
    ) {
        self.watcherFactory = watcherFactory
        self.directoryListingBackend = directoryListingBackend
        self.fileContentSnapshotReader = fileContentSnapshotReader
        self.mutationBackend = mutationBackend
        self.partitionRoot = partitionRoot.standardizedFileURL
        self.partitionSaveEventSink = partitionSaveEventSink
        self.codeMapCacheRoot = codeMapCacheRoot.standardizedFileURL
        self.configuration = configuration
        self.diagnostics = diagnostics
    }
}
