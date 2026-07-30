import Foundation

protocol GlobalSettingsFileStoring {
    var fileURL: URL { get }
    /// Non-nil when the on-disk file is blocked (unreadable or a newer schema); surfaced to the user.
    var blockReason: GlobalSettingsPersistenceBlockReason? { get }

    func load() throws -> GlobalSettingsDocument
    func loadOrCreateDefault() -> GlobalSettingsDocument
    func save(_ document: GlobalSettingsDocument) throws
    /// User-initiated recovery: backs up the offending file, writes a current-schema replacement, clears the block.
    @discardableResult
    func performUserInitiatedRecovery(replacementDocument: GlobalSettingsDocument) -> Bool
    /// User-initiated compatible import: backs up a foreign/incompatible file, imports CE-known
    /// fields, writes a current-schema document, and clears the block.
    @discardableResult
    func performUserInitiatedCompatibleImport() -> Bool
}

/// Why global-settings persistence is currently blocked: the store loads in-memory defaults
/// and refuses to overwrite the on-disk file. Surfaced to the user so they can take a recovery
/// action; RepoPrompt never auto-recovers from a schema it did not write.
enum GlobalSettingsPersistenceBlockReason: Equatable {
    /// On-disk schema is newer than this build supports (`onDiskVersion` > `supportedVersion`).
    case unsupportedFutureSchema(onDiskVersion: Int, supportedVersion: Int)
    /// On-disk settings are JSON, but belong to a different or unrecognized settings schema lineage.
    case incompatibleSchema
    /// The on-disk file is unreadable and could not be moved to the Backups folder.
    case corruptUnrecoverable
    /// The settings file could not be written, for example due to permissions or disk space.
    case saveFailed
    /// A same-lineage false-v4 file could not be safely verified, backed up, or atomically normalized.
    case automaticSchemaNormalizationFailed
}

/// File-backed store for the versioned global settings document.
///
/// Primary location:
/// `~/Library/Application Support/RepoPrompt CE/Settings/globalSettings.json`
///
/// Schema identity is `(schemaLineage, schemaVersion)`, not `schemaVersion` alone.
/// See `docs/architecture/settings-persistence.md` before changing the preservation rules.
final class GlobalSettingsFileStore: GlobalSettingsFileStoring {
    static let appSupportDirectoryName = "RepoPrompt CE"
    static let settingsDirectoryName = "Settings"
    static let filename = "globalSettings.json"

    let fileURL: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let normalizationBackupWriter: (Data, URL) throws -> Void
    private let normalizationAtomicWriter: (Data, URL) throws -> Void
    private var preservingUnsupportedFutureDocument = false
    private var preservingUnbackedCorruptDocument = false
    private var preservingFailedAutomaticNormalization = false

    /// Non-nil when the on-disk file cannot be safely read or overwritten, so the store falls
    /// back to in-memory defaults and refuses saves. Surfaced to the user (never auto-recovered).
    /// Cleared by `performUserInitiatedRecovery()`.
    private(set) var blockReason: GlobalSettingsPersistenceBlockReason?

    init(
        fileURL: URL = GlobalSettingsFileStore.defaultFileURL(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        normalizationBackupWriter: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        },
        normalizationAtomicWriter: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.now = now
        self.normalizationBackupWriter = normalizationBackupWriter
        self.normalizationAtomicWriter = normalizationAtomicWriter
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        settingsDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(filename)
    }

    static func settingsDirectoryURL(fileManager: FileManager = .default) -> URL {
        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return supportDirectory
            .appendingPathComponent(appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(settingsDirectoryName, isDirectory: true)
    }

    func load() throws -> GlobalSettingsDocument {
        let data = try Data(contentsOf: fileURL)
        let header: GlobalSettingsDocumentHeader
        do {
            header = try Self.decoder.decode(GlobalSettingsDocumentHeader.self, from: data)
        } catch {
            if Self.isJSONDocument(data) {
                preservingUnsupportedFutureDocument = true
                blockReason = .incompatibleSchema
                throw GlobalSettingsFileStoreError.incompatibleSchema
            }
            throw error
        }
        if let reason = Self.preservationBlockReason(for: header) {
            preservingUnsupportedFutureDocument = true
            blockReason = reason
            switch reason {
            case let .unsupportedFutureSchema(onDiskVersion, _):
                throw GlobalSettingsFileStoreError.unsupportedFutureSchema(onDiskVersion)
            case .incompatibleSchema:
                throw GlobalSettingsFileStoreError.incompatibleSchema
            case .corruptUnrecoverable, .saveFailed, .automaticSchemaNormalizationFailed:
                assertionFailure("Unexpected settings preservation reason during header load: \(reason)")
                throw GlobalSettingsFileStoreError.incompatibleSchema
            }
        }
        let document: GlobalSettingsDocument
        do {
            document = try Self.decoder.decode(GlobalSettingsDocument.self, from: data)
        } catch {
            if Self.shouldPreserveFailedFalseV4Decode(data: data, header: header) {
                preservingFailedAutomaticNormalization = true
                blockReason = .automaticSchemaNormalizationFailed
                throw GlobalSettingsFileStoreError.automaticSchemaNormalizationFailed
            }
            throw error
        }

        if Self.hasInvalidPresentAgentModelsField(data: data, header: header) {
            preservingFailedAutomaticNormalization = true
            blockReason = .automaticSchemaNormalizationFailed
            throw GlobalSettingsFileStoreError.automaticSchemaNormalizationFailed
        }

        if Self.shouldNormalizeFalseV4Document(data: data, header: header, document: document) {
            do {
                let normalizedData = try normalizeFalseV4Document(data)
                var normalizedDocument = try Self.decoder.decode(GlobalSettingsDocument.self, from: normalizedData)
                normalizedDocument.schemaVersion = GlobalSettingsDocument.baselineSchemaVersion
                preservingFailedAutomaticNormalization = false
                preservingUnsupportedFutureDocument = false
                preservingUnbackedCorruptDocument = false
                blockReason = nil
                return normalizedDocument
            } catch {
                preservingFailedAutomaticNormalization = true
                blockReason = .automaticSchemaNormalizationFailed
                throw GlobalSettingsFileStoreError.automaticSchemaNormalizationFailed
            }
        }

        preservingFailedAutomaticNormalization = false
        preservingUnsupportedFutureDocument = false
        preservingUnbackedCorruptDocument = false
        blockReason = nil
        return document
    }

    func loadOrCreateDefault() -> GlobalSettingsDocument {
        preservingUnsupportedFutureDocument = false
        preservingUnbackedCorruptDocument = false
        if preservingFailedAutomaticNormalization {
            blockReason = .automaticSchemaNormalizationFailed
            return defaultDocument()
        }
        blockReason = nil
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                return try load()
            } catch GlobalSettingsFileStoreError.automaticSchemaNormalizationFailed {
                preservingFailedAutomaticNormalization = true
                blockReason = .automaticSchemaNormalizationFailed
                print("⚠️ Global settings schema normalization could not complete safely; preserving the original file and using in-memory defaults for this launch.")
                return defaultDocument()
            } catch let GlobalSettingsFileStoreError.unsupportedFutureSchema(version) {
                preservingUnsupportedFutureDocument = true
                print("⚠️ Global settings JSON schema v\(version) is newer than supported v\(GlobalSettingsDocument.currentSchemaVersion); preserving file and using in-memory defaults for this launch.")
                return defaultDocument()
            } catch GlobalSettingsFileStoreError.incompatibleSchema {
                preservingUnsupportedFutureDocument = true
                blockReason = .incompatibleSchema
                print("⚠️ Global settings JSON was written by a different or unrecognized RepoPrompt settings schema; preserving file and using in-memory defaults for this launch.")
                return defaultDocument()
            } catch {
                let fallback = defaultDocument()
                if backupCorruptFile(error: error) {
                    writeFallbackDocument(fallback)
                } else {
                    preservingUnbackedCorruptDocument = true
                    blockReason = .corruptUnrecoverable
                }
                return fallback
            }
        }

        let document = defaultDocument()
        writeFallbackDocument(document)
        return document
    }

    /// User-initiated compatible import from a blocked foreign/incompatible settings file:
    /// decode the CE-known fields, back up the original byte-for-byte, then write a fresh
    /// current-schema document. Unknown newer fields remain in the backup and are not
    /// silently discarded without an explicit user action.
    @discardableResult
    func performUserInitiatedCompatibleImport() -> Bool {
        guard blockReason != .automaticSchemaNormalizationFailed else { return false }
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }
        let importedDocument: GlobalSettingsDocument
        do {
            let data = try Data(contentsOf: fileURL)
            let header = try Self.decoder.decode(GlobalSettingsDocumentHeader.self, from: data)
            guard Self.preservationBlockReason(for: header) == .incompatibleSchema else { return false }
            importedDocument = try Self.decoder.decode(GlobalSettingsDocument.self, from: data)
        } catch {
            print("⚠️ Failed to decode compatible global settings import at \(fileURL.path): \(error)")
            return false
        }

        guard supersedeExistingFileToBackup(label: "imported") != nil else {
            return false
        }

        preservingFailedAutomaticNormalization = false
        preservingUnsupportedFutureDocument = false
        preservingUnbackedCorruptDocument = false
        var documentToWrite = importedDocument
        documentToWrite.schemaLineage = GlobalSettingsDocument.schemaLineage
        do {
            try save(documentToWrite)
            blockReason = nil
            return true
        } catch {
            blockReason = .saveFailed
            print("⚠️ Failed to import compatible global settings JSON at \(fileURL.path): \(error)")
            return false
        }
    }

    /// User-initiated recovery from a blocked state (`blockReason != nil`): backs up the
    /// offending on-disk file into `Backups/`, writes fresh current-schema defaults, and
    /// clears the block so saves resume. Never runs automatically — the app surfaces the
    /// block and the user chooses to recover. Returns true only after both the backup (when
    /// a file exists) and replacement write succeed.
    @discardableResult
    func performUserInitiatedRecovery(replacementDocument: GlobalSettingsDocument) -> Bool {
        if fileManager.fileExists(atPath: fileURL.path),
           supersedeExistingFileToBackup(label: "superseded") == nil
        {
            return false
        }

        // Clear preservation flags only after the offending file has been moved aside so
        // `save()` can write the replacement defaults. If the replacement write fails, keep
        // persistence blocked and continue surfacing the banner.
        preservingUnsupportedFutureDocument = false
        preservingUnbackedCorruptDocument = false
        preservingFailedAutomaticNormalization = false
        do {
            var documentToWrite = replacementDocument
            documentToWrite.schemaLineage = GlobalSettingsDocument.schemaLineage
            try save(documentToWrite)
            blockReason = nil
            return true
        } catch {
            blockReason = .saveFailed
            print("⚠️ Failed to reset global settings JSON at \(fileURL.path): \(error)")
            return false
        }
    }

    func save(_ document: GlobalSettingsDocument) throws {
        guard !preservingFailedAutomaticNormalization else {
            blockReason = .automaticSchemaNormalizationFailed
            throw GlobalSettingsFileStoreError.automaticSchemaNormalizationPreserved
        }
        guard !preservingUnsupportedFutureDocument else {
            if blockReason == nil, let reason = preservationBlockReasonOnDisk() {
                blockReason = reason
            }
            if blockReason == .incompatibleSchema {
                throw GlobalSettingsFileStoreError.incompatibleSchemaPreserved
            }
            throw GlobalSettingsFileStoreError.unsupportedFutureSchemaPreserved
        }
        guard !preservingUnbackedCorruptDocument else {
            if blockReason != .saveFailed {
                blockReason = .corruptUnrecoverable
            }
            throw GlobalSettingsFileStoreError.corruptDocumentPreserved
        }
        if let reason = preservationBlockReasonOnDisk() {
            preservingUnsupportedFutureDocument = true
            blockReason = reason
            switch reason {
            case let .unsupportedFutureSchema(onDiskVersion, supportedVersion):
                print("⚠️ Global settings JSON schema v\(onDiskVersion) is newer than supported v\(supportedVersion); preserving file and skipping save.")
                throw GlobalSettingsFileStoreError.unsupportedFutureSchemaPreserved
            case .incompatibleSchema:
                print("⚠️ Global settings JSON was written by a different or unrecognized RepoPrompt settings schema; preserving file and skipping save.")
                throw GlobalSettingsFileStoreError.incompatibleSchemaPreserved
            case .corruptUnrecoverable, .saveFailed, .automaticSchemaNormalizationFailed:
                assertionFailure("Unexpected settings preservation reason during save: \(reason)")
                throw GlobalSettingsFileStoreError.incompatibleSchemaPreserved
            }
        }
        try ensureSettingsDirectoryExists()
        var documentToWrite = document
        documentToWrite.schemaVersion = documentToWrite.requiredSchemaVersion
        documentToWrite.schemaLineage = GlobalSettingsDocument.schemaLineage
        documentToWrite.updatedAt = now()
        let data = try Self.encoder.encode(documentToWrite)
        do {
            try data.write(to: fileURL, options: .atomic)
            blockReason = nil
        } catch {
            blockReason = .saveFailed
            throw error
        }
    }

    private func defaultDocument() -> GlobalSettingsDocument {
        GlobalSettingsDocument(
            schemaVersion: GlobalSettingsDocument.baselineSchemaVersion,
            updatedAt: now(),
            globalDefaults: GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
            scalarPreferences: GlobalScalarPreferences()
        )
    }

    private func writeFallbackDocument(_ document: GlobalSettingsDocument) {
        do {
            try save(document)
        } catch {
            print("⚠️ Failed to write global settings JSON at \(fileURL.path): \(error)")
        }
    }

    private func ensureSettingsDirectoryExists() throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    /// Moves (or copies + removes) the current on-disk file into `Backups/` with the given
    /// label. Returns the backup URL on success, or nil if there was no file to back up or the
    /// move failed. The original path is left empty so a following `save()` cannot re-trip the
    /// newer-schema guard.
    @discardableResult
    private func supersedeExistingFileToBackup(label: String) -> URL? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let backupDirectory = fileURL
                .deletingLastPathComponent()
                .appendingPathComponent("Backups", isDirectory: true)
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

            let stamp = Self.backupTimestamp(for: now())
            var backupURL = backupDirectory
                .appendingPathComponent("globalSettings.\(label)-\(stamp).json")
            if fileManager.fileExists(atPath: backupURL.path) {
                backupURL = backupDirectory
                    .appendingPathComponent("globalSettings.\(label)-\(stamp)-\(UUID().uuidString).json")
            }

            do {
                try fileManager.moveItem(at: fileURL, to: backupURL)
            } catch {
                try fileManager.copyItem(at: fileURL, to: backupURL)
                try? fileManager.removeItem(at: fileURL)
            }
            return backupURL
        } catch {
            print("⚠️ Failed to back up global settings JSON at \(fileURL.path): \(error)")
            return nil
        }
    }

    private func backupCorruptFile(error: Error) -> Bool {
        guard let backupURL = supersedeExistingFileToBackup(label: "corrupt") else { return false }
        print("⚠️ Backed up corrupt global settings JSON to \(backupURL.path): \(error)")
        return true
    }

    private enum RawAgentModelsFieldState: Equatable {
        case absent
        case emptyObject
        case nonemptyObject
        case invalidPresent
    }

    private static func falseV4RawAgentModelsFieldState(
        data: Data,
        header: GlobalSettingsDocumentHeader
    ) -> RawAgentModelsFieldState? {
        guard header.schemaVersion == GlobalSettingsDocument.workspaceAgentModelsSchemaVersion,
              header.schemaLineage?.trimmingCharacters(in: .whitespacesAndNewlines) == GlobalSettingsDocument.schemaLineage,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        guard let rawAgentModels = root["agentModelsSettingsByWorkspaceID"] else {
            return .absent
        }
        guard let object = rawAgentModels as? [String: Any] else {
            return .invalidPresent
        }
        return object.isEmpty ? .emptyObject : .nonemptyObject
    }

    private static func shouldPreserveFailedFalseV4Decode(
        data: Data,
        header: GlobalSettingsDocumentHeader
    ) -> Bool {
        guard let state = falseV4RawAgentModelsFieldState(data: data, header: header) else {
            return false
        }
        return state != .nonemptyObject
    }

    private static func hasInvalidPresentAgentModelsField(
        data: Data,
        header: GlobalSettingsDocumentHeader
    ) -> Bool {
        falseV4RawAgentModelsFieldState(data: data, header: header) == .invalidPresent
    }

    private static func shouldNormalizeFalseV4Document(
        data: Data,
        header: GlobalSettingsDocumentHeader,
        document: GlobalSettingsDocument
    ) -> Bool {
        guard document.requiredSchemaVersion == GlobalSettingsDocument.baselineSchemaVersion else {
            return false
        }
        switch falseV4RawAgentModelsFieldState(data: data, header: header) {
        case .absent, .emptyObject:
            return true
        case .nonemptyObject, .invalidPresent, nil:
            return false
        }
    }

    private func normalizeFalseV4Document(_ originalData: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: originalData) as? [String: Any],
              root["schemaVersion"] as? Int == GlobalSettingsDocument.workspaceAgentModelsSchemaVersion,
              (root["schemaLineage"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
              == GlobalSettingsDocument.schemaLineage
        else {
            throw GlobalSettingsFileStoreError.automaticSchemaNormalizationFailed
        }
        if let rawAgentModels = root["agentModelsSettingsByWorkspaceID"],
           (rawAgentModels as? [String: Any])?.isEmpty != true
        {
            throw GlobalSettingsFileStoreError.automaticSchemaNormalizationFailed
        }

        let backupURL = try falseV4BackupURL()
        try normalizationBackupWriter(originalData, backupURL)

        root["schemaVersion"] = GlobalSettingsDocument.baselineSchemaVersion
        let normalizedData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try normalizationAtomicWriter(normalizedData, fileURL)
        return normalizedData
    }

    private func falseV4BackupURL() throws -> URL {
        let backupDirectory = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let stamp = Self.backupTimestamp(for: now())
        var backupURL = backupDirectory
            .appendingPathComponent("globalSettings.false-v4-\(stamp).json")
        if fileManager.fileExists(atPath: backupURL.path) {
            backupURL = backupDirectory
                .appendingPathComponent("globalSettings.false-v4-\(stamp)-\(UUID().uuidString).json")
        }
        return backupURL
    }

    private func preservationBlockReasonOnDisk() -> GlobalSettingsPersistenceBlockReason? {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else {
            return nil
        }
        guard let header = try? Self.decoder.decode(GlobalSettingsDocumentHeader.self, from: data) else {
            return Self.isJSONDocument(data) ? .incompatibleSchema : nil
        }
        return Self.preservationBlockReason(for: header)
    }

    static func shouldPreserveWithoutLoading(
        schemaVersion: Int,
        schemaLineage: String?,
        supportedVersion: Int = GlobalSettingsDocument.currentSchemaVersion
    ) -> Bool {
        preservationBlockReason(
            schemaVersion: schemaVersion,
            schemaLineage: schemaLineage,
            supportedVersion: supportedVersion
        ) != nil
    }

    static func preservationBlockReason(
        schemaVersion: Int,
        schemaLineage: String?,
        supportedVersion: Int = GlobalSettingsDocument.currentSchemaVersion
    ) -> GlobalSettingsPersistenceBlockReason? {
        let normalizedLineage = schemaLineage?.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedLineage == GlobalSettingsDocument.schemaLineage {
            return schemaVersion > supportedVersion
                ? .unsupportedFutureSchema(onDiskVersion: schemaVersion, supportedVersion: supportedVersion)
                : nil
        }
        if normalizedLineage != nil { return .incompatibleSchema }

        // COMPATIBILITY INVARIANT — do not simplify this to `schemaVersion > supportedVersion`.
        // Numeric schema versions above the inherited v1/v2 CE baseline are ambiguous without a
        // lineage marker: classic/internal RepoPrompt wrote unlineaged v3/v4 globalSettings.json
        // into live Application Support folders before CE introduced `schemaLineage`. An
        // unlineaged version above the frozen ceiling is therefore foreign, permanently — even
        // after CE's own currentSchemaVersion catches up numerically. Guarded by
        // testLegacyUnlineagedCeilingIsFrozenAtTwo and
        // testUnlineagedHigherSchemaStaysBlockedAfterFutureNumericSchemaCatchup.
        // See docs/architecture/settings-persistence.md.
        return schemaVersion > GlobalSettingsDocument.legacyUnlineagedSchemaVersionCeiling ? .incompatibleSchema : nil
    }

    private static func preservationBlockReason(for header: GlobalSettingsDocumentHeader) -> GlobalSettingsPersistenceBlockReason? {
        preservationBlockReason(schemaVersion: header.schemaVersion, schemaLineage: header.schemaLineage)
    }

    private static func isJSONDocument(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func backupTimestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
    }

    private struct GlobalSettingsDocumentHeader: Decodable {
        let schemaVersion: Int
        let schemaLineage: String?
    }

    enum GlobalSettingsFileStoreError: Error, Equatable {
        case unsupportedFutureSchema(Int)
        case incompatibleSchema
        case unsupportedFutureSchemaPreserved
        case incompatibleSchemaPreserved
        case corruptDocumentPreserved
        case automaticSchemaNormalizationFailed
        case automaticSchemaNormalizationPreserved
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
