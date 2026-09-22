import Foundation

/// File-backed store for copy/chat/model presets.
///
/// Primary location:
/// `~/Library/Application Support/RepoPrompt CE/Presets/workflowPresets.json`
/// `~/Library/Application Support/RepoPrompt CE/Presets/modelPresets.json`
final class PresetFileStore {
    static let shared = PresetFileStore()

    static let appSupportDirectoryName = "RepoPrompt CE"
    static let presetsDirectoryName = "Presets"
    static let workflowFilename = "workflowPresets.json"
    static let modelFilename = "modelPresets.json"
    static let workflowSchemaVersion = 1
    static let modelSchemaVersion = 2

    let workflowFileURL: URL
    let modelFileURL: URL
    private(set) var modelLoadWarning: String?

    private let fileManager: FileManager
    private let now: () -> Date
    private let writeData: (Data, URL) throws -> Void
    private var preservingUnsupportedFutureWorkflowDocument = false
    private var preservingUnsupportedFutureModelDocument = false
    private var preservingUnbackedCorruptWorkflowDocument = false
    private var preservingUnbackedCorruptModelDocument = false

    init(
        workflowFileURL: URL = PresetFileStore.defaultWorkflowFileURL(),
        modelFileURL: URL = PresetFileStore.defaultModelFileURL(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        writeData: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.workflowFileURL = workflowFileURL
        self.modelFileURL = modelFileURL
        self.fileManager = fileManager
        self.now = now
        self.writeData = writeData
    }

    static func defaultWorkflowFileURL(fileManager: FileManager = .default) -> URL {
        presetsDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(workflowFilename)
    }

    static func defaultModelFileURL(fileManager: FileManager = .default) -> URL {
        presetsDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(modelFilename)
    }

    static func presetsDirectoryURL(fileManager: FileManager = .default) -> URL {
        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return supportDirectory
            .appendingPathComponent(appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(presetsDirectoryName, isDirectory: true)
    }

    // MARK: - Workflow Presets

    func loadWorkflowPresets() -> WorkflowPresetDocument {
        preservingUnsupportedFutureWorkflowDocument = false
        preservingUnbackedCorruptWorkflowDocument = false
        if fileManager.fileExists(atPath: workflowFileURL.path) {
            do {
                return try loadWorkflowDocument()
            } catch let PresetFileStoreError.unsupportedFutureSchema(version) {
                preservingUnsupportedFutureWorkflowDocument = true
                print("⚠️ Workflow presets JSON schema v\(version) is newer than supported v\(Self.workflowSchemaVersion); preserving file and using in-memory defaults for this launch.")
                return WorkflowPresetDocument(updatedAt: now())
            } catch {
                let fallback = WorkflowPresetDocument(updatedAt: now())
                if backupCorruptFile(at: workflowFileURL, prefix: "workflowPresets", error: error) {
                    saveBootstrapWorkflowPresets(fallback)
                } else {
                    preservingUnbackedCorruptWorkflowDocument = true
                }
                return fallback
            }
        }

        let document = WorkflowPresetDocument(updatedAt: now())
        saveBootstrapWorkflowPresets(document)
        return document
    }

    func updateWorkflowPresets(
        _ mutation: (inout WorkflowPresetDocument) -> Void
    ) throws {
        var document = loadWorkflowPresets()
        mutation(&document)
        try saveWorkflowPresets(document)
    }

    func saveWorkflowPresets(_ document: WorkflowPresetDocument) throws {
        guard !preservingUnsupportedFutureWorkflowDocument else {
            let version = unsupportedFutureSchemaVersionOnDisk(
                at: workflowFileURL,
                supportedVersion: Self.workflowSchemaVersion
            ) ?? Self.workflowSchemaVersion + 1
            throw PresetFileStoreError.unsupportedFutureSchema(version)
        }
        guard !preservingUnbackedCorruptWorkflowDocument else {
            throw PresetFileStoreError.unbackedCorruptDocumentPreserved
        }
        if let version = unsupportedFutureSchemaVersionOnDisk(
            at: workflowFileURL,
            supportedVersion: Self.workflowSchemaVersion
        ) {
            preservingUnsupportedFutureWorkflowDocument = true
            print("⚠️ Workflow presets JSON schema v\(version) is newer than supported v\(Self.workflowSchemaVersion); preserving file and skipping save.")
            throw PresetFileStoreError.unsupportedFutureSchema(version)
        }

        var documentToWrite = document
        documentToWrite.schemaVersion = Self.workflowSchemaVersion
        documentToWrite.updatedAt = now()
        try ensurePresetDirectoryExists(for: workflowFileURL)
        let data = try Self.fileEncoder.encode(documentToWrite)
        try writeData(data, workflowFileURL)
    }

    func loadWorkflowDocument() throws -> WorkflowPresetDocument {
        let data = try Data(contentsOf: workflowFileURL)
        let header = try Self.fileDecoder.decode(DocumentHeader.self, from: data)
        guard header.schemaVersion >= 1 else {
            throw PresetFileStoreError.unsupportedPastSchema(header.schemaVersion)
        }
        guard header.schemaVersion <= Self.workflowSchemaVersion else {
            preservingUnsupportedFutureWorkflowDocument = true
            throw PresetFileStoreError.unsupportedFutureSchema(header.schemaVersion)
        }
        preservingUnsupportedFutureWorkflowDocument = false
        preservingUnbackedCorruptWorkflowDocument = false
        return try Self.fileDecoder.decode(WorkflowPresetDocument.self, from: data)
    }

    // MARK: - Model Presets

    func loadModelPresets() -> ModelPresetDocument {
        preservingUnsupportedFutureModelDocument = false
        preservingUnbackedCorruptModelDocument = false
        modelLoadWarning = nil
        if fileManager.fileExists(atPath: modelFileURL.path) {
            do {
                return try loadModelDocument()
            } catch let PresetFileStoreError.unsupportedFutureSchema(version) {
                preservingUnsupportedFutureModelDocument = true
                print("⚠️ Model presets JSON schema v\(version) is newer than supported v\(Self.modelSchemaVersion); preserving file and using in-memory defaults for this launch.")
                return ModelPresetDocument(updatedAt: now())
            } catch {
                let fallback = ModelPresetDocument(updatedAt: now())
                if backupCorruptFile(at: modelFileURL, prefix: "modelPresets", error: error) {
                    saveBootstrapModelPresets(fallback)
                } else {
                    preservingUnbackedCorruptModelDocument = true
                }
                return fallback
            }
        }

        let document = ModelPresetDocument(updatedAt: now())
        saveBootstrapModelPresets(document)
        return document
    }

    func saveModelPresets(_ document: ModelPresetDocument) throws {
        guard !preservingUnsupportedFutureModelDocument else {
            let version = unsupportedFutureSchemaVersionOnDisk(
                at: modelFileURL,
                supportedVersion: Self.modelSchemaVersion
            ) ?? Self.modelSchemaVersion + 1
            throw PresetFileStoreError.unsupportedFutureSchema(version)
        }
        guard !preservingUnbackedCorruptModelDocument else {
            throw PresetFileStoreError.unbackedCorruptDocumentPreserved
        }
        if let version = unsupportedFutureSchemaVersionOnDisk(
            at: modelFileURL,
            supportedVersion: Self.modelSchemaVersion
        ) {
            preservingUnsupportedFutureModelDocument = true
            print("⚠️ Model presets JSON schema v\(version) is newer than supported v\(Self.modelSchemaVersion); preserving file and skipping save.")
            throw PresetFileStoreError.unsupportedFutureSchema(version)
        }

        var documentToWrite = document
        documentToWrite.schemaVersion = Self.modelSchemaVersion
        documentToWrite.updatedAt = now()
        try ensurePresetDirectoryExists(for: modelFileURL)
        let data = try Self.fileEncoder.encode(documentToWrite)
        try writeData(data, modelFileURL)
        modelLoadWarning = nil
    }

    func loadModelDocument() throws -> ModelPresetDocument {
        let data = try Data(contentsOf: modelFileURL)
        let header = try Self.fileDecoder.decode(DocumentHeader.self, from: data)
        guard header.schemaVersion >= 1 else {
            throw PresetFileStoreError.unsupportedPastSchema(header.schemaVersion)
        }
        guard header.schemaVersion <= Self.modelSchemaVersion else {
            preservingUnsupportedFutureModelDocument = true
            throw PresetFileStoreError.unsupportedFutureSchema(header.schemaVersion)
        }
        preservingUnsupportedFutureModelDocument = false
        preservingUnbackedCorruptModelDocument = false
        guard header.schemaVersion == 1 else {
            return try Self.fileDecoder.decode(ModelPresetDocument.self, from: data)
        }

        let legacy = try Self.fileDecoder.decode(LegacyModelPresetDocument.self, from: data)
        let migrated = try ModelPresetDocument(
            schemaVersion: Self.modelSchemaVersion,
            updatedAt: legacy.updatedAt,
            modelPresets: legacy.modelPresets.map { try $0.migratedPreset() }
        )
        do {
            try saveModelPresets(migrated)
        } catch {
            modelLoadWarning = "Your model presets were loaded, but their schema migration could not be saved. \(error.localizedDescription)"
        }
        return migrated
    }

    // MARK: - Files

    private func saveBootstrapWorkflowPresets(_ document: WorkflowPresetDocument) {
        do {
            try saveWorkflowPresets(document)
        } catch {
            print("⚠️ Failed to create workflow presets JSON at \(workflowFileURL.path): \(error)")
        }
    }

    private func saveBootstrapModelPresets(_ document: ModelPresetDocument) {
        do {
            try saveModelPresets(document)
        } catch {
            print("⚠️ Failed to create model presets JSON at \(modelFileURL.path): \(error)")
        }
    }

    private func ensurePresetDirectoryExists(for fileURL: URL) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func backupCorruptFile(at fileURL: URL, prefix: String, error: Error) -> Bool {
        do {
            let backupDirectory = fileURL
                .deletingLastPathComponent()
                .appendingPathComponent("Backups", isDirectory: true)
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

            var backupURL = backupDirectory
                .appendingPathComponent("\(prefix).corrupt-\(Self.backupTimestamp(for: now())).json")
            if fileManager.fileExists(atPath: backupURL.path) {
                backupURL = backupDirectory
                    .appendingPathComponent("\(prefix).corrupt-\(Self.backupTimestamp(for: now()))-\(UUID().uuidString).json")
            }

            do {
                try fileManager.moveItem(at: fileURL, to: backupURL)
            } catch {
                try fileManager.copyItem(at: fileURL, to: backupURL)
                try? fileManager.removeItem(at: fileURL)
            }
            print("⚠️ Backed up corrupt preset JSON to \(backupURL.path): \(error)")
            return true
        } catch {
            print("⚠️ Failed to back up corrupt preset JSON at \(fileURL.path): \(error)")
            return false
        }
    }

    private func unsupportedFutureSchemaVersionOnDisk(
        at fileURL: URL,
        supportedVersion: Int
    ) -> Int? {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let header = try? Self.fileDecoder.decode(DocumentHeader.self, from: data),
              header.schemaVersion > supportedVersion
        else {
            return nil
        }
        return header.schemaVersion
    }

    private static func backupTimestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
    }

    private struct DocumentHeader: Decodable {
        let schemaVersion: Int
    }

    private struct LegacyModelPresetDocument: Decodable {
        let schemaVersion: Int
        let updatedAt: Date
        let modelPresets: [LegacyModelPreset]
    }

    private struct LegacyModelPreset: Decodable {
        let id: UUID
        let name: String
        let modelString: String
        let description: String?
        let supportedModes: SupportedModes?
        let proEditingOverride: ProEditingOverride
        let chatPresetMappings: ChatPresetMappings?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard !container.contains(.modelStrings) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .modelStrings,
                    in: container,
                    debugDescription: "Schema-1 model presets must not contain modelStrings"
                )
            }
            id = try container.decode(UUID.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            modelString = try container.decode(String.self, forKey: .modelString)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            supportedModes = try container.decodeIfPresent(SupportedModes.self, forKey: .supportedModes)
            proEditingOverride = try container.decodeIfPresent(ProEditingOverride.self, forKey: .proEditingOverride)
                ?? .useDefault
            chatPresetMappings = try container.decodeIfPresent(ChatPresetMappings.self, forKey: .chatPresetMappings)
        }

        func migratedPreset() throws -> ModelPreset {
            try ModelPreset(
                id: id,
                name: name,
                modelStrings: [modelString],
                description: description,
                supportedModes: supportedModes,
                proEditingOverride: proEditingOverride,
                chatPresetMappings: chatPresetMappings
            )
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, modelString, modelStrings, description, supportedModes, proEditingOverride, chatPresetMappings
        }
    }

    enum PresetFileStoreError: LocalizedError, Equatable {
        case unsupportedFutureSchema(Int)
        case unsupportedPastSchema(Int)
        case unbackedCorruptDocumentPreserved

        var errorDescription: String? {
            switch self {
            case let .unsupportedFutureSchema(version):
                "The preset file uses schema v\(version), which is newer than this build supports. The newer file was preserved."
            case let .unsupportedPastSchema(version):
                "The preset file uses unsupported schema v\(version)."
            case .unbackedCorruptDocumentPreserved:
                "The unreadable preset file could not be backed up, so it was preserved."
            }
        }
    }

    private static let fileEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let fileDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension PresetFileStore {
    struct WorkflowPresetDocument: Codable, Equatable {
        var schemaVersion: Int
        var updatedAt: Date
        var copyUserPresets: [CopyPreset]
        var copyVisibilityByPresetID: [String: Bool]
        var copyOverrides: [CopyPresetOverrides]
        var chatUserPresets: [ChatPreset]
        var chatVisibilityByPresetID: [String: Bool]
        var chatOverrides: [ChatPresetOverrides]

        init(
            schemaVersion: Int = PresetFileStore.workflowSchemaVersion,
            updatedAt: Date = Date(),
            copyUserPresets: [CopyPreset] = [],
            copyVisibility: [UUID: Bool] = [:],
            copyOverrides: [CopyPresetOverrides] = [],
            chatUserPresets: [ChatPreset] = [],
            chatVisibility: [UUID: Bool] = [:],
            chatOverrides: [ChatPresetOverrides] = []
        ) {
            self.schemaVersion = schemaVersion
            self.updatedAt = updatedAt
            self.copyUserPresets = copyUserPresets
            copyVisibilityByPresetID = PresetFileStore.encodeUUIDKeyedDictionary(copyVisibility)
            self.copyOverrides = copyOverrides
            self.chatUserPresets = chatUserPresets
            chatVisibilityByPresetID = PresetFileStore.encodeUUIDKeyedDictionary(chatVisibility)
            self.chatOverrides = chatOverrides
        }

        var copyVisibility: [UUID: Bool] {
            get { PresetFileStore.decodeUUIDKeyedDictionary(copyVisibilityByPresetID) }
            set { copyVisibilityByPresetID = PresetFileStore.encodeUUIDKeyedDictionary(newValue) }
        }

        var chatVisibility: [UUID: Bool] {
            get { PresetFileStore.decodeUUIDKeyedDictionary(chatVisibilityByPresetID) }
            set { chatVisibilityByPresetID = PresetFileStore.encodeUUIDKeyedDictionary(newValue) }
        }
    }

    struct ModelPresetDocument: Codable, Equatable {
        var schemaVersion: Int
        var updatedAt: Date
        var modelPresets: [ModelPreset]

        init(
            schemaVersion: Int = PresetFileStore.modelSchemaVersion,
            updatedAt: Date = Date(),
            modelPresets: [ModelPreset] = []
        ) {
            self.schemaVersion = schemaVersion
            self.updatedAt = updatedAt
            self.modelPresets = modelPresets
        }
    }

    private static func encodeUUIDKeyedDictionary<Value>(_ values: [UUID: Value]) -> [String: Value] {
        values.reduce(into: [String: Value]()) { result, entry in
            result[entry.key.uuidString] = entry.value
        }
    }

    private static func decodeUUIDKeyedDictionary<Value>(_ values: [String: Value]) -> [UUID: Value] {
        values.reduce(into: [UUID: Value]()) { result, entry in
            guard let uuid = UUID(uuidString: entry.key) else { return }
            result[uuid] = entry.value
        }
    }
}
