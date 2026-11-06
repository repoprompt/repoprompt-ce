import Foundation
import RepoPromptFileSystem
import RepoPromptShared

/// One process-owned serialization authority is injected into every workspace manager.
/// The library has no singleton and no workspace-model decoding policy.
enum WorkspaceDiskWriterComposition {
    static let processWriter = WorkspaceDiskWriter(
        policy: WorkspaceAppDiskWritePolicy(),
        backend: WorkspaceDiskWriteBackend(
            // Both paths refuse to discard an unreadable original without a verified recovery
            // backup (#335); the typed refusal reaches the caller through the write receipt.
            queuedAtomicWrite: { data, url in
                try WorkspaceUnreadableDocumentBackup.replaceDocument(data, at: url)
            },
            normalizationAtomicWrite: { data, url in
                try WorkspaceUnreadableDocumentBackup.replaceDocument(data, at: url)
            }
        )
    )
}
