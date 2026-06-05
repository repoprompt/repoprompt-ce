/// Platform dependencies consumed by the staged reusable core host.
///
/// Item 4 keeps this contract inside the monolithic target. Item 5 moves it into the
/// physical core target and removes the macOS defaults from reusable initializers.
struct RepoPromptCorePlatformDependencies {
    let fileSystemWatcherFactory: any FileSystemWatcherCreating
    let processLauncher: any ProcessLaunching
    let secureStorageBackend: () -> any SecureKeyValueStorageBackend
}
