/// Platform dependencies consumed by the staged reusable core host.
///
/// Item 5 gives this dependency record a physical SwiftPM owner while the host and
/// filesystem-runtime closure remain app-owned until their deferred stream split lands.
package struct RepoPromptCorePlatformDependencies {
    package let fileSystemWatcherFactory: any FileSystemWatcherCreating
    package let processLauncher: any ProcessLaunching
    package let secureStorageBackend: () -> any SecureKeyValueStorageBackend

    package init(
        fileSystemWatcherFactory: any FileSystemWatcherCreating,
        processLauncher: any ProcessLaunching,
        secureStorageBackend: @escaping () -> any SecureKeyValueStorageBackend
    ) {
        self.fileSystemWatcherFactory = fileSystemWatcherFactory
        self.processLauncher = processLauncher
        self.secureStorageBackend = secureStorageBackend
    }
}
