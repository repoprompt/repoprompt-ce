import Foundation
import RepoPromptShared

/// Title CAS and high-water reconciliation live on the existing shared data-service actor.
/// This extension adds no queue, persistence owner, or cross-window revision allocator.
extension AgentSessionDataService {
    func renameAgentSession(
        id: UUID,
        to newName: String,
        for workspace: WorkspaceModel
    ) async throws {
        let before = try prepareTitleState(id: id, workspace: workspace, fallbackName: "Agent Session")
        _ = try commitTitleMutation(
            id: id,
            workspace: workspace,
            expectedRevision: before.revision,
            fallbackName: before.name,
            command: .humanRename(newName)
        )
        guard let session = try await loadAgentSession(id: id, for: workspace) else { return }
        _ = try await saveAgentSession(session, for: workspace)
    }

    func observeTitle(metadata: AgentSessionTitleMetadata?, name: String, fileURL: URL) {
        guard let metadata else { return }
        let key = fileURL.standardizedFileURL
        if let current = titleHighWaterByFileURL[key] {
            // An old nil/opaque/transcript snapshot never revokes an accepted working mutation.
            guard let revision = metadata.revision, let currentRevision = current.metadata?.revision,
                  revision > currentRevision else { return }
        }
        titleHighWaterByFileURL[key] = .init(metadata: metadata, name: metadata.state?.displayName ?? name, persistenceState: "persisted")
        if titleHighWaterByFileURL.count > 1024 {
            // Pending/failed values are never evicted. A cold save re-reads the authoritative header
            // before accepting a snapshot, so eviction cannot resurrect an older title.
            let removable = titleHighWaterByFileURL.keys.filter { $0 != key && titleHighWaterByFileURL[$0]?.persistenceState == "persisted" && !hasPendingMetadataPublication(for: $0) }
            for url in removable.prefix(titleHighWaterByFileURL.count - 1024) {
                titleHighWaterByFileURL.removeValue(forKey: url)
            }
        }
    }

    func reconcileTitle(in session: AgentSession, fileURL: URL?) -> AgentSession {
        guard let fileURL = fileURL ?? session.fileURL else { return session }
        let key = fileURL.standardizedFileURL
        observeTitle(metadata: session.titleMetadata, name: session.name, fileURL: key)
        guard let title = titleHighWaterByFileURL[key] else { return session }
        var result = session
        result.titleMetadata = title.metadata
        result.name = title.name
        return result
    }

    func prepareTitleState(id: UUID, workspace: WorkspaceModel, fallbackName: String, fallbackMetadata: AgentSessionTitleMetadata? = nil) throws -> AgentSessionTitleSnapshot {
        let fileURL = try titleStateFileURL(id: id, workspace: workspace)
        if let current = titleHighWaterByFileURL[fileURL] { return current }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try AppProfileLocations.current.validateMetadataFile(fileURL)
            let header = try JSONDecoder().decode(AgentSessionHeader.self, from: Data(contentsOf: fileURL, options: .mappedIfSafe))
            guard header.id == id, header.workspaceID == nil || header.workspaceID == workspace.id else {
                throw AgentSessionTitleError.denied("session_identity_mismatch")
            }
            observeTitle(metadata: header.titleMetadata, name: header.name, fileURL: fileURL)
            return titleHighWaterByFileURL[fileURL] ?? .init(metadata: nil, name: header.name, persistenceState: "not_needed")
        }
        let initial = AgentSessionTitleSnapshot(metadata: fallbackMetadata, name: fallbackMetadata?.state?.displayName ?? fallbackName, persistenceState: "not_needed")
        if fallbackMetadata != nil { titleHighWaterByFileURL[fileURL] = initial }
        return initial
    }

    /// Synchronous check/policy/install region on the existing shared actor. Disk flushing is
    /// separate: a tool receipt never calls a working-state acceptance durable persistence.
    func commitTitleMutation(
        id: UUID,
        workspace: WorkspaceModel,
        expectedRevision: UInt64,
        fallbackName: String,
        command: AgentSessionTitleCommand
    ) throws -> AgentSessionTitleSnapshot {
        let before = try prepareTitleState(id: id, workspace: workspace, fallbackName: fallbackName)
        guard before.revision == expectedRevision else { throw AgentSessionTitleError.conflict }
        guard let metadata = try AgentSessionTitlePolicy.apply(command, to: before.metadata, name: before.name) else { return before }
        let fileURL = try titleStateFileURL(id: id, workspace: workspace)
        let after = AgentSessionTitleSnapshot(metadata: metadata, name: metadata.state?.displayName ?? before.name, persistenceState: "pending")
        titleHighWaterByFileURL[fileURL] = after
        return after
    }

    func resetMalformedTitle(id: UUID, workspace: WorkspaceModel, expectedRevision: UInt64) throws -> AgentSessionTitleSnapshot {
        let before = try prepareTitleState(id: id, workspace: workspace, fallbackName: "Agent Session")
        guard before.revision == expectedRevision else { throw AgentSessionTitleError.conflict }
        guard before.metadata?.isMalformedCurrentVersion == true else { throw AgentSessionTitleError.denied("unsupported_title_metadata") }
        let fileURL = try titleStateFileURL(id: id, workspace: workspace)
        let folder = fileURL.deletingLastPathComponent()
        try AppProfileLocations.current.validateMetadataFile(fileURL)
        let data = try Data(contentsOf: fileURL)
        let header = try JSONDecoder().decode(AgentSessionHeader.self, from: data)
        guard header.id == id, header.titleMetadata == before.metadata else { throw AgentSessionTitleError.conflict }
        let recovery = folder.appendingPathComponent(".title-metadata-recovery", isDirectory: true)
        try AppProfileLocations.current.validateMetadataFile(recovery)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let copy = recovery.appendingPathComponent("\(id.uuidString)-\(UUID().uuidString).json")
        try data.write(to: copy, options: .atomic)
        let snapshots = try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix(id.uuidString + "-") && $0.pathExtension == "json" }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        for old in snapshots.dropFirst(3) {
            try? FileManager.default.removeItem(at: old)
        }
        guard before.revision < UInt64.max else { throw AgentSessionTitleError.denied("title_revision_overflow") }
        var state = AgentSessionTitleState(baseTitle: before.name, source: "human")
        state.revision = before.revision + 1
        state.refinement.phase = "closed"
        let after = try AgentSessionTitleSnapshot(metadata: AgentSessionTitleMetadata(state), name: before.name, persistenceState: "pending")
        titleHighWaterByFileURL[fileURL] = after
        return after
    }
}
