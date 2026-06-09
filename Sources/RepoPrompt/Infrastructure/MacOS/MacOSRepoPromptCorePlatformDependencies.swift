import RepoPromptCore
import RepoPromptCoreMacOS

/// Embedded-app composition of macOS platform adapters.
enum MacOSRepoPromptCorePlatformDependencies {
    static func embeddedApp() -> RepoPromptCorePlatformDependencies {
        RepoPromptCorePlatformDependencies(
            fileSystemWatcherFactory: MacOSFSEventsWatcherFactory(),
            processLauncher: POSIXProcessLauncher(),
            secureStorageBackend: { SecureKeyValueStorageFactory.defaultBackend() }
        )
    }
}
