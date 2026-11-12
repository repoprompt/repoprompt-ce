import Darwin
import Foundation
import RepoPromptShared

/// Ephemeral workspaces are excluded from the durable catalog and window restoration. Their
/// sessions still need file-backed storage while open (attachments, tab switching, and handoff).
/// Keep those files outside every profile/custom workspace root, with a stable identity across
/// model copies and renames. Do not delete on model deinit: queued sidecar writes can outlive it.
enum WorkspaceEphemeralStorage {
    private static let processRoot: URL = {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("RepoPromptEphemeralWorkspaces-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        // Only our unique process directory is removed. A killed process may leave temporary
        // files for the OS to reclaim; no profile data or another process's scratch is swept.
        // Exit cleanup is intentionally best-effort even if a final scratch write is still running.
        atexit {
            let root = WorkspaceEphemeralStorage.processRoot
            guard FileManager.default.fileExists(atPath: root.path) else { return }
            do {
                try AppProfileLocations.current.validateMetadataFile(root)
                try FileManager.default.removeItem(at: root)
            } catch {
                // Best effort at process exit. Never fall back to a durable directory.
            }
        }
        return root
    }()

    static func directory(for workspaceID: UUID) -> URL {
        processRoot.appendingPathComponent(workspaceID.uuidString, isDirectory: true)
    }
}
