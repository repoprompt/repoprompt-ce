import Foundation
import RepoPromptDomainRuntime

private enum DomainWorkspaceModelEncoder {
    static func encode(_ workspace: WorkspaceModel) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(workspace)
    }
}

/// App-model encoding and its lossless-recovery verdict belong to workspace preparation, not
/// the generic domain authority transport. These synchronous helpers also serve digest receipts.
extension DomainWorkspaceAuthorityClient {
    /// The exact digest used by document submission, shared with presentation write receipts.
    static func documentDigest(for workspace: WorkspaceModel) throws -> String {
        try DomainContentDigest.sha256(DomainWorkspaceModelEncoder.encode(workspace))
    }

    static func document(for workspace: WorkspaceModel, fileURL: URL) throws -> DomainWorkspaceDocument {
        let bytes = try DomainWorkspaceModelEncoder.encode(workspace)
        let document = try DomainWorkspaceDocument.decode(documentBytes: bytes, fileURL: fileURL)
        // Bytes the app encodes from a model always decode back without loss; recording that here,
        // outside every domain lock, spares the recovery guard a full decode when they are later
        // discarded (#335).
        WorkspaceUnreadableDocumentBackup.recordAppEncodedDocument(bytes)
        return document
    }
}

/// CPU preparation only, never a persistence or presentation authority. Serializing work here
/// keeps several window subscriptions from concurrently decoding the same large document; the
/// existing digest cache remains the sole decode cache. No live view model is read or published here.
actor WorkspaceDocumentPreparation {
    struct Catalog {
        let models: [UUID: WorkspaceModel]
        let failedIDs: Set<UUID>
        let wasOnMainThread: Bool
    }

    func decode(_ records: [DomainWorkspaceSnapshot]) throws -> Catalog {
        #if DEBUG
            let start = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        var models: [UUID: WorkspaceModel] = [:]
        var failedIDs: Set<UUID> = []
        for record in records {
            try Task.checkCancellation()
            do {
                models[record.document.workspaceID] = try WorkspaceManagerViewModel.decodeDomainWorkspaceCatalogRecordBytes(record)
            } catch {
                failedIDs.insert(record.document.workspaceID)
            }
        }
        try Task.checkCancellation()
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent("workspace.prepare.decode", startMS: start, fields: [
                "recordCount": String(records.count),
                "inputBytes": String(records.reduce(0) { $0 + $1.document.documentBytes.count }),
                "failedCount": String(failedIDs.count),
                "onMainThread": String(Thread.isMainThread)
            ])
        #endif
        return Catalog(models: models, failedIDs: failedIDs, wasOnMainThread: Thread.isMainThread)
    }

    func document(for workspace: WorkspaceModel, fileURL: URL) throws -> DomainWorkspaceDocument {
        try Task.checkCancellation()
        #if DEBUG
            let start = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let document = try DomainWorkspaceAuthorityClient.document(for: workspace, fileURL: fileURL)
        try Task.checkCancellation()
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent("workspace.prepare.encode", startMS: start, fields: [
                "outputBytes": String(document.documentBytes.count),
                "onMainThread": String(Thread.isMainThread)
            ])
        #endif
        return document
    }
}
