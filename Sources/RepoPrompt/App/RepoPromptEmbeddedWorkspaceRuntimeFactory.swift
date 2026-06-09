import Foundation
import os
import RepoPromptCore
import RepoPromptCoreMacOS

struct RepoPromptEmbeddedWorkspaceRuntime {
    let dependencies: WorkspaceRuntimeDependencies
    let workspaceFileContextStore: WorkspaceFileContextStore
    let workspaceSearchService: WorkspaceSearchService
    let selectionMutationService: WorkspaceSelectionMutationService
    let selectionSliceCoordinator: SelectionSliceCoordinator
}

private final class EmbeddedWorkspaceRuntimeDiagnosticsState: @unchecked Sendable {
    private let lock = NSLock()
    private var intervals: [UUID: EditFlowPerf.ExternalIntervalState] = [:]

    func store(_ interval: EditFlowPerf.ExternalIntervalState?, id: UUID) {
        guard let interval else { return }
        lock.lock()
        intervals[id] = interval
        lock.unlock()
    }

    func take(id: UUID) -> EditFlowPerf.ExternalIntervalState? {
        lock.lock()
        defer { lock.unlock() }
        return intervals.removeValue(forKey: id)
    }
}

struct EmbeddedWorkspaceRuntimeDiagnosticsSink: WorkspaceRuntimeDiagnosticsSink {
    private let logger = Logger(subsystem: "com.pvncher.repoprompt", category: "WorkspaceRuntime")
    private let state = EmbeddedWorkspaceRuntimeDiagnosticsState()

    func record(_ event: WorkspaceRuntimeDiagnosticEvent) {
        let correlationID = event.correlationID ?? EditFlowPerf.currentLifecycleCorrelation?.id
        let correlation = correlationID?.uuidString ?? "none"
        let fields = event.fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        logger.debug(
            "\(event.subsystem, privacy: .public).\(event.name, privacy: .public) kind=\(event.kind.rawValue, privacy: .public) correlation=\(correlation, privacy: .public) \(fields, privacy: .public)"
        )

        let dimensions = event.fields["dimensions"] ?? fields
        switch event.kind {
        case .intervalBegan:
            guard let intervalID = event.intervalID else { return }
            state.store(
                EditFlowPerf.beginExternalInterval(
                    stageName: event.name,
                    sanitizedDimensions: dimensions
                ),
                id: intervalID
            )
        case .intervalEnded:
            guard let intervalID = event.intervalID else { return }
            EditFlowPerf.endExternalInterval(
                state.take(id: intervalID),
                sanitizedDimensions: dimensions
            )
        case .lifecycle, .counter:
            EditFlowPerf.recordExternalLifecycleEvent(
                eventName: event.name,
                correlationID: correlationID,
                sanitizedDimensions: dimensions
            )
        }
    }
}

@MainActor
final class RepoPromptEmbeddedWorkspaceRuntimeFactory {
    private let dependencies: WorkspaceRuntimeDependencies

    init(settingsStore: GlobalSettingsStore? = nil) {
        WorkspaceExternalFileReaderProvider.install { MacOSWorkspaceExternalFileReader() }
        let settingsStore = settingsStore ?? GlobalSettingsStore.shared
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        let legacyRuntimeRoot = applicationSupport.appendingPathComponent("RepoPrompt", isDirectory: true)
        let diagnostics = EmbeddedWorkspaceRuntimeDiagnosticsSink()
        WorkspaceRuntimePerf.installProcessSink(diagnostics)
        dependencies = WorkspaceRuntimeDependencies(
            watcherFactory: MacOSFSEventsWatcherFactory(),
            directoryListingBackend: MacOSWorkspaceDirectoryListingBackend(),
            fileContentSnapshotReader: MacOSFileContentSnapshotReader(),
            mutationBackend: EmbeddedWorkspaceFileMutationBackend(),
            partitionRoot: legacyRuntimeRoot.appendingPathComponent("Partitions", isDirectory: true),
            partitionSaveEventSink: EmbeddedPartitionStoreEventAdapter.sink,
            codeMapCacheRoot: legacyRuntimeRoot.appendingPathComponent("CodeMapCaches", isDirectory: true),
            configuration: WorkspaceRuntimeConfiguration(
                agentSupportRoot: fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".agents", isDirectory: true),
                globalIgnoreDefaults: settingsStore.globalIgnoreDefaults()
            ),
            diagnostics: diagnostics
        )
    }

    func makeRuntime() -> RepoPromptEmbeddedWorkspaceRuntime {
        let partitionStore = PartitionStore(
            baseURL: dependencies.partitionRoot,
            saveEventSink: dependencies.partitionSaveEventSink
        )
        let workspaceFileContextStore = WorkspaceFileContextStore(runtimeDependencies: dependencies)
        return RepoPromptEmbeddedWorkspaceRuntime(
            dependencies: dependencies,
            workspaceFileContextStore: workspaceFileContextStore,
            workspaceSearchService: WorkspaceSearchService(),
            selectionMutationService: WorkspaceSelectionMutationService(store: workspaceFileContextStore),
            selectionSliceCoordinator: SelectionSliceCoordinator(store: partitionStore)
        )
    }
}
