import Foundation
import RepoPromptFileSystem
import RepoPromptInstrumentation

/// Workspace decoding and selection authority remain app-owned. The injected
/// filesystem actor only serializes writes using this existing policy.
struct WorkspaceAppDiskWritePolicy: WorkspaceDiskWritePolicy {
    typealias Metadata = WorkspaceSavePayloadMetadata
    typealias Selection = StoredSelection
    typealias SelectionKey = WorkspaceTabSelectionKey
    private typealias WorkspacePayloadIdentity = WorkspaceDiskPayloadIdentity
    typealias LatestSelectionRecord = WorkspaceDiskSelectionRecord<SelectionKey, Selection, Metadata>
    private typealias EffectiveWritePayload = WorkspaceDiskEffectivePayload<Metadata, SelectionKey>

    private let restorePerfRecorderSlot = WorkspaceRestorePerfRecorderBox()
    private var workspaceSaveTracer: WorkspaceSaveTracer {
        WorkspaceSaveTracer(restorePerfRecorder: restorePerfRecorderSlot.snapshot())
    }

    func installRestorePerfRecorder(_ recorder: any WorkspaceRestorePerfRecording) {
        restorePerfRecorderSlot.install(recorder)
    }

    func payloadIdentity(metadata: Metadata?, data: Data) -> WorkspaceDiskPayloadIdentity? {
        Self.payloadIdentity(metadata: metadata, data: data)
    }

    func selectionKey(metadata: Metadata?) -> SelectionKey? {
        metadata?.selectionKey
    }

    func selectionRecord(metadata: Metadata?) -> LatestSelectionRecord? {
        guard let metadata, let key = metadata.selectionKey,
              let selection = metadata.activeSelection, metadata.activeSelectionRevision > 0
        else { return nil }
        return LatestSelectionRecord(
            key: key,
            revision: metadata.activeSelectionRevision,
            selection: selection,
            metadata: metadata
        )
    }

    func selectionRevision(metadata: Metadata) -> UInt64 {
        metadata.activeSelectionRevision
    }

    func shouldKeepExistingPayload(existing: WorkspaceDiskPayloadIdentity?, incoming: WorkspaceDiskPayloadIdentity?, metadata: Metadata?, url: URL) -> Bool {
        Self.shouldKeepExistingWorkspacePayload(
            existing: existing,
            incoming: incoming,
            incomingMetadata: metadata,
            url: url,
            restorePerfRecorder: restorePerfRecorderSlot.snapshot()
        )
    }

    func effectivePayloadForWrite(data: Data, identity: WorkspaceDiskPayloadIdentity?, url: URL, metadata: Metadata?, latestSelection: LatestSelectionRecord?, lastWrittenRevision: UInt64) -> WorkspaceDiskEffectivePayload<Metadata, SelectionKey> {
        Self.effectivePayloadForWrite(
            payload: data,
            incomingIdentity: identity,
            url: url,
            metadata: metadata,
            latestRecord: latestSelection,
            lastWrittenRevision: lastWrittenRevision,
            workspaceSaveTracer: workspaceSaveTracer
        )
    }

    func trace(_ event: String, metadata: Metadata?, url: URL, extra: [String: String]) {
        workspaceSaveTracer.event(event, metadata: metadata, url: url, extra: extra)
    }

    private struct WorkspacePayloadHeader: Decodable {
        let id: UUID
        let dateModified: Date

        var identity: WorkspacePayloadIdentity {
            WorkspacePayloadIdentity(workspaceID: id, dateModified: dateModified)
        }
    }

    private struct DecodeWork: Equatable {
        var identityPayloadCount = 0
        var fullWorkspacePayloadCount = 0
    }

    private static func payloadIdentity(
        metadata: WorkspaceSavePayloadMetadata?,
        data: Data
    ) -> WorkspacePayloadIdentity? {
        if let metadata {
            return WorkspacePayloadIdentity(
                workspaceID: metadata.workspaceID,
                dateModified: metadata.workspaceDateModified
            )
        }
        return decodedWorkspacePayloadIdentity(data)
    }

    private static func decodedWorkspacePayloadIdentity(_ data: Data) -> WorkspacePayloadIdentity? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(WorkspacePayloadHeader.self, from: data).identity
    }

    private static func decodedWorkspacePayloadIdentity(
        _ data: Data,
        decodeWork: inout DecodeWork
    ) -> WorkspacePayloadIdentity? {
        decodeWork.identityPayloadCount &+= 1
        return decodedWorkspacePayloadIdentity(data)
    }

    private static func decodedWorkspacePayload(
        _ data: Data,
        decodeWork: inout DecodeWork
    ) -> WorkspaceModel? {
        guard !data.isEmpty else { return nil }
        decodeWork.fullWorkspacePayloadCount &+= 1
        return try? JSONDecoder().decode(WorkspaceModel.self, from: data)
    }

    private static func shouldKeepExistingWorkspacePayload(
        existing: WorkspacePayloadIdentity?,
        incoming: WorkspacePayloadIdentity?,
        incomingMetadata: WorkspaceSavePayloadMetadata?,
        url: URL,
        restorePerfRecorder: any WorkspaceRestorePerfRecording
    ) -> Bool {
        guard let existing,
              let incoming,
              existing.workspaceID == incoming.workspaceID,
              existing.dateModified > incoming.dateModified
        else {
            return false
        }
        #if DEBUG
            restorePerfRecorder.event(
                "workspaceDiskWriter.skipStaleCoalescedPayload",
                fields: [
                    "workspaceID": restorePerfRecorder.shortID(incoming.workspaceID),
                    "workspaceName": incomingMetadata?.workspaceName ?? "unknown",
                    "url": url.lastPathComponent
                ]
            )
        #endif
        return true
    }

    private static func effectivePayloadForWrite(
        payload: Data,
        incomingIdentity: WorkspacePayloadIdentity?,
        url: URL,
        metadata: WorkspaceSavePayloadMetadata?,
        latestRecord: LatestSelectionRecord?,
        lastWrittenRevision: UInt64,
        workspaceSaveTracer: WorkspaceSaveTracer
    ) -> EffectiveWritePayload {
        var decodeWork = DecodeWork()
        func result(
            data: Data,
            metadata: WorkspaceSavePayloadMetadata?,
            selectionKey: WorkspaceTabSelectionKey?,
            effectiveSelectionRevision: UInt64,
            shouldWrite: Bool
        ) -> EffectiveWritePayload {
            EffectiveWritePayload(
                data: data,
                metadata: metadata,
                selectionKey: selectionKey,
                effectiveSelectionRevision: effectiveSelectionRevision,
                shouldWrite: shouldWrite,
                identityPayloadCount: decodeWork.identityPayloadCount,
                fullWorkspacePayloadCount: decodeWork.fullWorkspacePayloadCount
            )
        }

        guard let incomingIdentity else {
            return result(
                data: payload,
                metadata: metadata,
                selectionKey: metadata?.selectionKey,
                effectiveSelectionRevision: metadata?.activeSelectionRevision ?? 0,
                shouldWrite: true
            )
        }

        let key = metadata?.selectionKey
        let incomingRevision = metadata?.activeSelectionRevision ?? 0
        let latestRevision = latestRecord?.revision ?? incomingRevision
        let latestSelection = latestRecord?.selection ?? metadata?.activeSelection
        let latestMetadata = latestRecord?.metadata ?? metadata
        let diskData = FileManager.default.fileExists(atPath: url.path)
            ? try? Data(contentsOf: url)
            : nil
        let diskIdentity = diskData.flatMap {
            decodedWorkspacePayloadIdentity($0, decodeWork: &decodeWork)
        }

        if let diskData,
           let diskIdentity,
           diskIdentity.workspaceID == incomingIdentity.workspaceID,
           diskIdentity.dateModified > incomingIdentity.dateModified
        {
            if let metadata,
               latestRevision > lastWrittenRevision,
               let latestSelection,
               let activeTabID = metadata.activeTabID,
               let diskWorkspace = decodedWorkspacePayload(diskData, decodeWork: &decodeWork),
               diskWorkspace.id == incomingIdentity.workspaceID
            {
                let applied = WorkspaceManagerViewModel.workspaceByApplyingSelection(
                    latestSelection,
                    toActiveTab: activeTabID,
                    in: diskWorkspace
                )
                if applied.applied {
                    var merged = applied.workspace
                    merged.dateModified = Date()
                    if let encoded = try? JSONEncoder().encode(merged) {
                        workspaceSaveTracer.event(
                            "workspaceSave.write.newerSelectionMergedIntoNewerDisk",
                            metadata: metadata,
                            url: url,
                            extra: [
                                "latestSelectionRevision": "\(latestRevision)",
                                "lastWrittenSelectionRevision": "\(lastWrittenRevision)",
                                "latestPayloadID": latestMetadata?.payloadID.uuidString ?? "none"
                            ]
                        )
                        return result(
                            data: encoded,
                            metadata: latestMetadata,
                            selectionKey: key,
                            effectiveSelectionRevision: latestRevision,
                            shouldWrite: true
                        )
                    }
                }
            }
            workspaceSaveTracer.event("workspaceSave.write.skipStaleDiskPayload", metadata: metadata, url: url)
            return result(
                data: payload,
                metadata: metadata,
                selectionKey: key,
                effectiveSelectionRevision: incomingRevision,
                shouldWrite: false
            )
        }

        if let metadata,
           latestRevision > incomingRevision,
           let latestSelection,
           let activeTabID = metadata.activeTabID,
           let incomingWorkspace = decodedWorkspacePayload(payload, decodeWork: &decodeWork),
           incomingWorkspace.id == incomingIdentity.workspaceID
        {
            let applied = WorkspaceManagerViewModel.workspaceByApplyingSelection(
                latestSelection,
                toActiveTab: activeTabID,
                in: incomingWorkspace
            )
            if applied.applied,
               let encoded = try? JSONEncoder().encode(applied.workspace)
            {
                workspaceSaveTracer.event(
                    "workspaceSave.write.selectionPreservedFromLatest",
                    metadata: metadata,
                    url: url,
                    extra: [
                        "incomingSelectionRevision": "\(incomingRevision)",
                        "latestSelectionRevision": "\(latestRevision)",
                        "latestPayloadID": latestMetadata?.payloadID.uuidString ?? "none"
                    ]
                )
                return result(
                    data: encoded,
                    metadata: latestMetadata,
                    selectionKey: key,
                    effectiveSelectionRevision: latestRevision,
                    shouldWrite: true
                )
            }
        }

        return result(
            data: payload,
            metadata: metadata,
            selectionKey: key,
            effectiveSelectionRevision: incomingRevision,
            shouldWrite: true
        )
    }
}
