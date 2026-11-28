// Compatibility facade for desktop targets that historically imported
// RepoPromptShared. The remote contract itself lives in the shared package so
// macOS and iOS cannot accidentally ship divergent DTOs.
@_exported import RepoPromptRemoteProtocol
