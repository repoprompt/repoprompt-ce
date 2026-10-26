import Foundation
import RepoPromptDomainRuntime

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
