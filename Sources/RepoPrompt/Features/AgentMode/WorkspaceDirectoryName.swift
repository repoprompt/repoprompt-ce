import Foundation

/// On-disk workspace directory naming convention: `Workspace-{name}-{uuid}`.
///
/// The format is written by `AgentSessionDataService` (workspace folder creation) and
/// parsed by `HistorySessionScanner` (cross-workspace discovery). Centralizing it here
/// keeps the single writer and the single reader in agreement on one shape, so the
/// reader never drifts from how directories are actually laid down on disk.
enum WorkspaceDirectoryName {
    static let prefix = "Workspace-"

    /// Build a directory name from a workspace name and UUID.
    static func directoryName(name: String, id: UUID) -> String {
        "\(prefix)\(name)-\(id.uuidString)"
    }

    /// Parse `Workspace-{name}-{uuid}` into `(name, id)`. Workspace names may contain
    /// hyphens, so the UUID is matched as the trailing hyphen-delimited segment that
    /// parses. Falls back to the raw directory name (with no id) when parsing fails.
    static func parse(_ dirName: String) -> (name: String, id: UUID?) {
        guard dirName.hasPrefix(prefix) else {
            return (name: dirName, id: nil)
        }

        let withoutPrefix = String(dirName.dropFirst(prefix.count))

        // The UUID is the last hyphen-delimited segment that parses as a UUID.
        // Workspace names may contain hyphens, so scan from the end.
        let components = withoutPrefix.components(separatedBy: "-")
        for i in stride(from: components.count - 1, through: 1, by: -1) {
            // UUID format: 8-4-4-4-12 = 5 components joined by hyphens
            let potentialUUID = components[i...].joined(separator: "-")
            if let uuid = UUID(uuidString: potentialUUID) {
                let namePart = components[..<i].joined(separator: "-")
                return (name: namePart.isEmpty ? dirName : namePart, id: uuid)
            }
        }

        return (name: withoutPrefix, id: nil)
    }
}
