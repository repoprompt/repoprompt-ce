import Foundation
import os
import RepoPromptCore
import RepoPromptCoreMacOS
import RepoPromptShared

final class LegacyWorkspaceGlobalIgnoreDefaults: @unchecked Sendable {
    static let shared = LegacyWorkspaceGlobalIgnoreDefaults()

    private let lock = NSLock()
    private var value = IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults

    func update(_ value: String) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func current() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

struct LegacyWorkspaceRuntimeDiagnosticsSink: RuntimeDiagnosticsSink {
    private static let rootUnloadLogger = Logger(subsystem: "com.repoprompt.workspace", category: "root-unload")
    var installationPriority: Int {
        100
    }

    var isEnabled: Bool {
        #if DEBUG
            EditFlowPerf.isEnabled
                || EditFlowPerf.isDebugCaptureActive
                || WorkspaceRestorePerfLog.isEnabled
                || MCPApplyEditsRebaseProbeRecorder.isActive
                || MCPToolWorkCountDiagnostics.isReadFileInvocationActive
        #else
            EditFlowPerf.isEnabled
        #endif
    }

    func captureContext() -> [String: String] {
        guard let identity = MCPRequestTimelineContext.current else { return [:] }
        var context: [String: String] = [:]
        if let requestID = identity.jsonRPCRequestID { context["jsonRPCRequestID"] = requestID.description }
        if let connectionID = identity.connectionID { context["connectionID"] = connectionID }
        if let generation = identity.connectionGeneration { context["connectionGeneration"] = String(generation) }
        if let invocationID = identity.appInvocationID { context["appInvocationID"] = invocationID }
        if let ordinal = identity.requestOrdinal { context["requestOrdinal"] = String(ordinal) }
        return context
    }

    func record(_ event: RuntimeDiagnosticEvent) {
        if event.name == "workspace.rootUnload.publisherIngress" {
            Self.rootUnloadLogger.fault(
                "publisher ingress root=\(event.fields["rootID"] ?? "unknown", privacy: .private(mask: .hash)) outcome=\(event.fields["outcome"] ?? "unknown", privacy: .public) accepted=\(event.fields["acceptedSequence"] ?? "0", privacy: .public) applied=\(event.fields["appliedSequence"] ?? "0", privacy: .public)"
            )
            return
        }
        if event.name == "workspace.rootUnload.watcherStop" {
            Self.rootUnloadLogger.fault(
                "watcher stop timed out root=\(event.fields["rootID"] ?? "unknown", privacy: .private(mask: .hash)) path=\(event.fields["rootPath"] ?? "unknown", privacy: .private(mask: .hash))"
            )
            return
        }
        #if DEBUG
            if event.subsystem != "workspace-engine",
               event.kind == .intervalBegan || event.kind == .intervalEnded || event.kind == .lifecycle || event.kind == .counter
            {
                EditFlowPerf.recordCoreRuntimeEvent(event)
            }
            if event.name == "mcp.readFile.diskRead" {
                MCPToolWorkCountDiagnostics.recordReadFileDiskRead(
                    bytes: Int(event.fields["bytes"] ?? "") ?? 0,
                    decodeMicroseconds: Int(event.fields["decodeMicroseconds"] ?? "") ?? 0
                )
            }
            if event.name.hasPrefix("applyEdits.") {
                routeApplyEditsEvent(event)
                return
            }

            guard event.subsystem == "workspace-engine" else { return }
            var fields = event.fields
            if event.name == "store.rootLoad.rootRecordCreated",
               let rootPath = fields.removeValue(forKey: "rootPath")
            {
                fields.merge(
                    WorkspaceRootLoadDiagnostics.rootRecordCreatedFields(forPath: rootPath),
                    uniquingKeysWith: { _, canonical in canonical }
                )
            } else if event.name == "store.rootLoad.firstPreparedChunk",
                      let rootPath = fields.removeValue(forKey: "rootPath")
            {
                fields.merge(
                    WorkspaceRootLoadDiagnostics.firstPreparedChunkFields(forPath: rootPath),
                    uniquingKeysWith: { _, canonical in canonical }
                )
            }
            WorkspaceRestorePerfLog.event(event.name, fields: fields)
        #endif
    }

    #if DEBUG
        private func routeApplyEditsEvent(_ event: RuntimeDiagnosticEvent) {
            let fields = event.fields
            switch event.name {
            case "applyEdits.servicePublication", "applyEdits.publisherIngress":
                guard let rootID = UUID(uuidString: fields["rootID"] ?? ""),
                      let source = FileSystemDeltaPublicationSource(rawValue: fields["source"] ?? "")
                else { return }
                let deltas = (fields["modifiedPaths"] ?? "")
                    .split(separator: "\u{1F}")
                    .map { FileSystemDelta.fileModified(String($0), nil) }
                if event.name == "applyEdits.servicePublication" {
                    MCPApplyEditsRebaseProbeRecorder.recordServicePublication(
                        rootToken: rootID,
                        source: source,
                        deltas: deltas
                    )
                } else {
                    MCPApplyEditsRebaseProbeRecorder.recordPublisherIngress(
                        rootID: rootID,
                        source: source,
                        deltas: deltas
                    )
                }
            case "applyEdits.storeModification":
                guard let rootID = UUID(uuidString: fields["rootID"] ?? ""),
                      let fileID = UUID(uuidString: fields["fileID"] ?? ""),
                      let generation = UInt64(fields["generation"] ?? "")
                else { return }
                MCPApplyEditsRebaseProbeRecorder.recordStoreModification(
                    rootID: rootID,
                    fileID: fileID,
                    generation: generation
                )
            case "applyEdits.appliedIndexModification":
                guard let rootID = UUID(uuidString: fields["rootID"] ?? ""),
                      let generation = UInt64(fields["generation"] ?? "")
                else { return }
                let fileIDs = (fields["fileIDs"] ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) }
                MCPApplyEditsRebaseProbeRecorder.recordAppliedIndexModification(
                    rootID: rootID,
                    fileIDs: fileIDs,
                    generation: generation
                )
            default:
                break
            }
        }
    #endif
}

enum LegacyWorkspaceRuntimeFactory {
    static var applicationSupportRoot: URL {
        MCPFilesystemConstants.identity.applicationSupportRootURL()
    }

    static var partitionsRoot: URL {
        applicationSupportRoot.appendingPathComponent("Partitions", isDirectory: true)
    }

    static var codeMapCacheRoot: URL {
        applicationSupportRoot.appendingPathComponent("CodeMapCaches", isDirectory: true)
    }

    static func partitionStore() -> PartitionStore {
        PartitionStore(baseURL: partitionsRoot) { event in
            NotificationCenter.default.post(
                name: PartitionStore.didSaveNotification,
                object: nil,
                userInfo: [
                    PartitionStore.notifRootPathKey: event.rootPath,
                    PartitionStore.notifWorkspaceIDKey: event.workspaceID,
                    PartitionStore.notifTabIDKey: event.tabID as Any,
                    PartitionStore.notifSourceIDKey: event.sourceID
                ]
            )
        }
    }

    static func dependencies() -> WorkspaceRuntimeDependencies {
        CodeMapPerfRuntime.installBenchmarkMarkerRoot(MCPFilesystemConstants.identity.temporaryRootURL())
        #if DEBUG
            LegacyIgnoreDebugMetricsPolicy.install()
        #endif
        return WorkspaceRuntimeDependencies(
            watcherFactory: MacOSFSEventsWatcherFactory(),
            currentWatchEventID: { MacOSFSEventsJournal.currentEventID() },
            directoryAccess: MacOSWorkspaceDirectoryAccess(),
            contentSnapshotReader: MacOSFileContentSnapshotReader(),
            contentDecoder: MacOSFileContentDecoder(),
            mutationBackend: MacOSWorkspaceFileMutationBackend(),
            diagnostics: LegacyWorkspaceRuntimeDiagnosticsSink(),
            configuration: WorkspaceRuntimeConfiguration(
                runtimePaths: RuntimePaths(
                    stateRoot: applicationSupportRoot,
                    cacheRoot: applicationSupportRoot,
                    codeMapCacheRoot: codeMapCacheRoot,
                    agentSupportRoot: applicationSupportRoot
                ),
                globalIgnoreDefaults: { LegacyWorkspaceGlobalIgnoreDefaults.shared.current() }
            )
        )
    }
}

#if DEBUG
    extension RepoPromptCore.WorkspaceFileContextStore {
        init(
            searchLaneConfiguration: StoreBackedWorkspaceSearchLane.Configuration = .production,
            debugNowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
            unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy = .production,
            enableCatalogShardShadowValidation: Bool = true
        ) {
            self.init(
                runtimeDependencies: LegacyWorkspaceRuntimeFactory.dependencies(),
                searchLaneConfiguration: searchLaneConfiguration,
                debugNowNanoseconds: debugNowNanoseconds,
                unloadTerminationPolicy: unloadTerminationPolicy,
                enableCatalogShardShadowValidation: enableCatalogShardShadowValidation
            )
        }
    }
#else
    extension RepoPromptCore.WorkspaceFileContextStore {
        init(
            searchLaneConfiguration: StoreBackedWorkspaceSearchLane.Configuration = .production,
            unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy = .production
        ) {
            self.init(
                runtimeDependencies: LegacyWorkspaceRuntimeFactory.dependencies(),
                searchLaneConfiguration: searchLaneConfiguration,
                unloadTerminationPolicy: unloadTerminationPolicy
            )
        }
    }
#endif

extension RepoPromptCore.FileSystemService {
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
            runtimeDependencies: LegacyWorkspaceRuntimeFactory.dependencies()
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
                runtimeDependencies: LegacyWorkspaceRuntimeFactory.dependencies()
            )
        }
    #endif
}

extension RepoPromptCore.SelectionSliceCoordinator {
    init() {
        self.init(store: LegacyWorkspaceRuntimeFactory.partitionStore())
    }
}
