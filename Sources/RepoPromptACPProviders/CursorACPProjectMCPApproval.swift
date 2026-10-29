import Foundation
import RepoPromptDomainRuntime

/// App-owned physical approval authority. Cursor execution supplies the resolved
/// launch environment and retains the returned lease identity; it never owns a lease store.
package protocol CursorACPProjectMCPApproval: Sendable {
    var cleanupArtifactKind: String { get }

    func cursorDataDirectoryURL(workingDirectory: String, environment: [String: String]) -> URL
    func prepareProjectMCPApproval(
        workingDirectory: String,
        cursorDataDirectory: URL,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration,
        cleanupAfterRun: Bool
    ) throws -> ACPLaunchCleanupArtifact?
    func cleanupProjectMCPApproval(leaseID: UUID)
}
