import Foundation

/// One-time migration utility for moving files from a legacy Application Support
/// subdirectory to the CE-branded path resolved by ``MCPFilesystemIdentity``.
///
/// Each call site provides:
/// - A unique ``UserDefaults`` key so the migration runs once per subsystem.
/// - The legacy subdirectory name (e.g. `"Workflows"`, `"Partitions"`).
/// - The ``MCPFilesystemIdentity`` that resolves the correct CE-branded root.
///
/// Idempotent — safe to call on every launch. Skips immediately when the
/// migration flag is already set or when no legacy directory exists on disk.
public enum AppSupportDirectoryMigration {
    /// Migrates files from the legacy `~/Library/Application Support/RepoPrompt/<subdir>/`
    /// path to `~/Library/Application Support/RepoPrompt CE/<subdir>/`.
    ///
    /// - Parameters:
    ///   - legacySubdirectory: The single path component under the old root (e.g. `"Workflows"`).
    ///   - migrationKey: A unique ``UserDefaults`` key that guards the one-time migration.
    ///   - identity: The ``MCPFilesystemIdentity`` used to resolve the CE-branded root.
    public static func migrate(
        legacySubdirectory: String,
        migrationKey: String,
        identity: MCPFilesystemIdentity
    ) {
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: migrationKey) }

        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacyDir = appSupport
            .appendingPathComponent("RepoPrompt", isDirectory: true)
            .appendingPathComponent(legacySubdirectory, isDirectory: true)

        guard fm.fileExists(atPath: legacyDir.path) else { return }

        let newDir = identity.applicationSupportRootURL()
            .appendingPathComponent(legacySubdirectory, isDirectory: true)
        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)

        let items = (try? fm.contentsOfDirectory(
            at: legacyDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []

        for item in items {
            let dest = newDir.appendingPathComponent(item.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.moveItem(at: item, to: dest)
            }
        }

        try? fm.removeItem(at: legacyDir)
    }
}
