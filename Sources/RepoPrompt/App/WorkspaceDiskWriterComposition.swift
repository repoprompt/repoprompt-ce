import Foundation
import RepoPromptFileSystem
import RepoPromptShared

/// One process-owned serialization authority is injected into every workspace manager.
/// The library has no singleton and no workspace-model decoding policy.
enum WorkspaceDiskWriterComposition {
    static let processWriter = WorkspaceDiskWriter(
        policy: WorkspaceAppDiskWritePolicy(),
        backend: WorkspaceDiskWriteBackend(
            queuedAtomicWrite: { data, url in
                try AppProfileLocations.current.validateMetadataFile(url)
                try data.write(to: url, options: .atomic)
            },
            normalizationAtomicWrite: { data, url in
                try AppProfileLocations.current.validateMetadataFile(url)
                try data.write(to: url, options: .atomic)
            }
        )
    )
}
