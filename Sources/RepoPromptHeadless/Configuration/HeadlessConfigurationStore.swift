import Foundation

final class HeadlessConfigurationStore {
    let paths: HeadlessStatePaths
    private let fileManager: FileManager

    init(paths: HeadlessStatePaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func loadOrCreate() throws -> HeadlessConfigurationDocument {
        try HeadlessFileLock.withExclusiveLock(path: paths.configLockFile, stateRoot: paths.rootDirectory) {
            try loadOrCreateUnlocked()
        }
    }

    /// Runs a state transaction while holding the cross-process catalog lock.
    ///
    /// Lock ordering is always `config.lock` first, followed by zero or more
    /// workspace UUID locks. Code holding a workspace lock must never acquire
    /// `config.lock`. This boundary serializes configuration mutations with
    /// workspace catalog checks and updates across processes.
    func withStateTransaction<T>(
        _ body: (inout HeadlessConfigurationDocument) throws -> T
    ) throws -> (configuration: HeadlessConfigurationDocument, value: T) {
        try HeadlessFileLock.withExclusiveLock(path: paths.configLockFile, stateRoot: paths.rootDirectory) {
            var document = try loadOrCreateUnlocked()
            let original = document
            let value = try body(&document)
            if document != original {
                document.touch()
                try saveUnlocked(document)
            }
            return (document, value)
        }
    }

    @discardableResult
    func update(_ body: (inout HeadlessConfigurationDocument) throws -> Void) throws -> HeadlessConfigurationDocument {
        try withStateTransaction(body).configuration
    }

    private func loadOrCreateUnlocked() throws -> HeadlessConfigurationDocument {
        try paths.ensureBaseDirectories(fileManager: fileManager)
        guard let data = try HeadlessStateFileSecurity.readPrivateFileIfPresent(at: paths.configFile, stateRoot: paths.rootDirectory) else {
            let document = HeadlessConfigurationDocument()
            try saveUnlocked(document)
            return document
        }
        let document = try HeadlessJSONFormatting.decoder().decode(HeadlessConfigurationDocument.self, from: data)
        guard document.schemaVersion == HeadlessConfigurationDocument.currentSchemaVersion else {
            throw HeadlessCommandError(
                "Unsupported headless config schema_version \(document.schemaVersion); expected \(HeadlessConfigurationDocument.currentSchemaVersion).",
                exitCode: 2
            )
        }
        return document
    }

    private func saveUnlocked(_ document: HeadlessConfigurationDocument) throws {
        try paths.ensureBaseDirectories(fileManager: fileManager)
        let data = try HeadlessJSONFormatting.encoder(prettyPrinted: true).encode(document)
        try HeadlessStateFileSecurity.writePrivateFile(
            data,
            to: paths.configFile,
            stateRoot: paths.rootDirectory,
            fileManager: fileManager
        )
    }
}
