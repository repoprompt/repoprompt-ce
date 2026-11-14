import Darwin
import Foundation
import RepoPromptShared

/// A strict, non-repairing metadata-index read. Unlike sidebar/history loading, this path never
/// creates folders, backfills an index, reads a session payload, or enriches transcript metadata.
actor CommandCenterInventoryReader {
    /// Serialize disk reads off MainActor. A cancelled queued load never opens its index.
    func load(workspaceID: UUID, directory: URL, limit: Int) -> CommandCenterProjection.SavedInventory {
        guard !Task.isCancelled else { return .init(entries: [], totalCount: 0, coverage: "Inventory read cancelled") }
        return CommandCenterSavedInventory.load(workspaceID: workspaceID, directory: directory, limit: limit)
    }
}

enum CommandCenterSavedInventory {
    static let maximumIndexBytes = 16 * 1024 * 1024

    static func load(workspaceID: UUID, directory: URL, limit: Int) -> CommandCenterProjection.SavedInventory {
        let indexURL = directory.appendingPathComponent("AgentSessions/AgentSessionIndex.json")
        do {
            try AppProfileLocations.current.validateMetadataFile(indexURL)
            let parent = indexURL.deletingLastPathComponent()
            let directoryDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard directoryDescriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
            defer { close(directoryDescriptor) }
            let descriptor = openat(directoryDescriptor, indexURL.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size <= maximumIndexBytes
            else {
                return .init(entries: [], totalCount: 0, coverage: "Metadata index unsupported or exceeds 16 MiB read budget")
            }
            // Bound the actual read too: a concurrently growing file must not defeat the stat cap.
            let data = try handle.read(upToCount: maximumIndexBytes + 1) ?? Data()
            guard data.count <= maximumIndexBytes else {
                return .init(entries: [], totalCount: 0, coverage: "Metadata index exceeds read budget")
            }
            let decoder = JSONDecoder()
            let index = try decoder.decode(AgentSessionMetadataIndex.self, from: data)
            guard index.schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                return .init(entries: [], totalCount: 0, coverage: "Unsupported metadata index version; open workspace to repair")
            }
            let entries = index.entries.filter { $0.workspaceID == nil || $0.workspaceID == workspaceID }
                .sorted { $0.activityDate == $1.activityDate ? $0.id.uuidString < $1.id.uuidString : $0.activityDate > $1.activityDate }
            let duplicateIDs = Set(entries.map(\.id)).count != entries.count
            let incomplete = duplicateIDs || entries.count != index.entries.count || !index.quarantinedFiles.isEmpty
            return .init(
                entries: entries.prefix(max(0, limit)).map {
                    .init(
                        id: $0.id,
                        tabID: $0.composeTabID,
                        name: $0.name,
                        provider: $0.agentKindRaw,
                        recordedAt: $0.savedAt,
                        parentSessionID: $0.parentSessionID,
                        createdByOverseerSessionID: $0.createdByOverseerSessionID,
                        lastUserMessageAt: $0.lastUserMessageAt
                    )
                },
                totalCount: entries.count,
                coverage: incomplete ? "Metadata index has quarantined, duplicate or foreign records" : nil
            )
        } catch {
            return .init(entries: [], totalCount: 0, coverage: "Saved inventory unavailable (missing or unreadable index); open workspace to repair")
        }
    }
}
