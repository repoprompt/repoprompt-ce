import Foundation

/// Core-owned compatibility surface for the existing runtime instrumentation
/// points. Events are forwarded through the Phase 3 diagnostics contract; the
/// app decides whether and how to persist, log, or correlate them.
package enum WorkspaceRuntimeDiagnosticsLog {
    package static var isEnabled: Bool {
        WorkspaceRuntimePerf.activeSink != nil
    }

    package static func timestampMSIfEnabled() -> Double? {
        guard isEnabled else { return nil }
        return timestampMS()
    }

    package static func timestampMS() -> Double {
        Date().timeIntervalSinceReferenceDate * 1000
    }

    package static func elapsedMS(since startMS: Double) -> Double {
        timestampMS() - startMS
    }

    package static func formatMS(_ value: Double) -> String {
        String(format: "%.1fms", value)
    }

    package static func formatElapsedMS(since startMS: Double) -> String {
        formatMS(elapsedMS(since: startMS))
    }

    package static func shortID(_ id: UUID?) -> String {
        id?.uuidString.prefix(8).description ?? "nil"
    }

    package static func event(
        _ name: String,
        fields: [String: String] = [:],
        bypassEnablement: Bool = false
    ) {
        let sink = bypassEnablement ? WorkspaceRuntimePerf.installedProcessSink : WorkspaceRuntimePerf.activeSink
        sink?.record(RuntimeDiagnosticEvent(
            subsystem: "workspace-engine",
            name: name,
            kind: .lifecycle,
            correlationID: WorkspaceRuntimePerf.currentLifecycleCorrelation?.id,
            fields: fields
        ))
    }
}

#if DEBUG
    package enum WorkspaceRootLoadDiagnostics {
        package static func rootRecordCreatedFields(forPath path: String) -> [String: String] {
            ["rootPath": (path as NSString).standardizingPath]
        }

        package static func firstPreparedChunkFields(forPath path: String) -> [String: String] {
            ["rootPath": (path as NSString).standardizingPath]
        }
    }

    package enum CodeMapInitialRootLoadDiagnostics {
        package static func start() -> Double? {
            WorkspaceRuntimeDiagnosticsLog.timestampMSIfEnabled()
        }

        package static func cacheRebuild(rootCount: Int, requestCount: Int, startMS: Double?) {
            record(
                "codemap.initialRootLoad.cacheRebuild",
                fields: ["rootCount": rootCount, "requestCount": requestCount],
                startMS: startMS
            )
        }

        package static func cacheCheck(
            requestCount: Int,
            queueableRequests: Int,
            droppedRequests: Int,
            startMS: Double?
        ) {
            record(
                "codemap.initialRootLoad.cacheCheck",
                fields: [
                    "requestCount": requestCount,
                    "queueableRequests": queueableRequests,
                    "droppedRequests": droppedRequests
                ],
                startMS: startMS
            )
        }

        package static func prune(rootCount: Int, startMS: Double?) {
            record("codemap.initialRootLoad.prune", fields: ["rootCount": rootCount], startMS: startMS)
        }

        package static func enqueue(queueableRequests: Int, startMS: Double?) {
            record(
                "codemap.initialRootLoad.enqueue",
                fields: ["queueableRequests": queueableRequests],
                startMS: startMS
            )
        }

        private static func record(_ name: String, fields: [String: Int], startMS: Double?) {
            var rendered = fields.mapValues(String.init)
            rendered["duration"] = startMS.map(WorkspaceRuntimeDiagnosticsLog.formatElapsedMS) ?? "notMeasured"
            WorkspaceRuntimeDiagnosticsLog.event(name, fields: rendered)
        }
    }

    package enum MCPToolWorkCountDiagnostics {
        package static func recordReadFileDiskRead(bytes: Int, decodeMicroseconds: Int) {
            WorkspaceRuntimeDiagnosticsLog.event(
                "mcp.readFile.diskRead",
                fields: [
                    "bytes": String(max(0, bytes)),
                    "decodeMicroseconds": String(max(0, decodeMicroseconds))
                ]
            )
        }
    }

    package enum MCPApplyEditsRebaseProbeRecorder {
        static func recordServicePublication(
            rootToken: UUID,
            source: FileSystemDeltaPublicationSource,
            deltas: [FileSystemDelta]
        ) {
            record(
                "applyEdits.servicePublication",
                fields: publicationFields(rootID: rootToken, source: source, deltas: deltas)
            )
        }

        static func recordPublisherIngress(
            rootID: UUID,
            source: FileSystemDeltaPublicationSource,
            deltas: [FileSystemDelta]
        ) {
            record(
                "applyEdits.publisherIngress",
                fields: publicationFields(rootID: rootID, source: source, deltas: deltas)
            )
        }

        static func recordStoreModification(rootID: UUID, fileID: UUID, generation: UInt64) {
            record(
                "applyEdits.storeModification",
                fields: [
                    "rootID": rootID.uuidString,
                    "fileID": fileID.uuidString,
                    "generation": String(generation)
                ]
            )
        }

        static func recordAppliedIndexModification(rootID: UUID, fileIDs: [UUID], generation: UInt64) {
            record(
                "applyEdits.appliedIndexModification",
                fields: [
                    "rootID": rootID.uuidString,
                    "fileIDs": fileIDs.map(\.uuidString).joined(separator: ","),
                    "generation": String(generation)
                ]
            )
        }

        private static func publicationFields(
            rootID: UUID,
            source: FileSystemDeltaPublicationSource,
            deltas: [FileSystemDelta]
        ) -> [String: String] {
            [
                "rootID": rootID.uuidString,
                "source": source.rawValue,
                "deltaCount": String(deltas.count),
                "modifiedPaths": deltas.compactMap { delta in
                    guard case let .fileModified(path, _) = delta else { return nil }
                    return StandardizedPath.relative(path)
                }.joined(separator: "\u{1F}")
            ]
        }

        private static func record(_ name: String, fields: [String: String]) {
            WorkspaceRuntimeDiagnosticsLog.event(name, fields: fields)
        }
    }
#endif

#if !DEBUG
    /// Release builds keep the Phase 4 read instrumentation call sites source-compatible
    /// without enabling debug history or app diagnostics.
    package enum MCPToolWorkCountDiagnostics {
        package static func recordReadFileDiskRead(bytes _: Int, decodeMicroseconds _: Int) {}
    }
#endif
