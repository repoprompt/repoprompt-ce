import RepoPromptFileSystem

/// One process-owned serialization authority is injected into every workspace manager.
/// The library has no singleton and no workspace-model decoding policy.
enum WorkspaceDiskWriterComposition {
    static let processWriter = WorkspaceDiskWriter(policy: WorkspaceAppDiskWritePolicy())
}
