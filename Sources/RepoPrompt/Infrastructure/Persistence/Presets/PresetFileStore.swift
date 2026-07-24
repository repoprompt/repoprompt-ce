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
    static let currentSchemaVersion = 1

    let workflowFileURL: URL
    let modelFileURL: URL

    private let fileManager: FileManager
    private let now: () -> Date
    private var preservingUnsupportedFutureWorkflowDocument = false
    private var preservingUnsupportedFutureModelDocument = false
    private var preservingUnbackedCorruptWorkflowDocument = false
    private var preservingUnbackedCorruptModelDocument = false

    init(
        workflowFileURL: URL = PresetFileStore.defaultWorkflowFileURL(),
        modelFileURL: URL = PresetFileStore.defaultModelFileURL(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.workflowFileURL = workflowFileURL
        self.modelFileURL = modelFileURL
        self.fileManager = fileManager
        self.now = now
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
                print("⚠️ Workflow presets JSON schema v\(version) is newer than supported v\(Self.currentSchemaVersion); preserving file and using in-memory defaults for this launch.")
                return WorkflowPresetDocument(updatedAt: now())
            } catch {
                let fallback = WorkflowPresetDocument(updatedAt: now())
                if backupCorruptFile(at: workflowFileURL, prefix: "workflowPresets", error: error) {
                    saveWorkflowPresets(fallback)
                } else {
                    preservingUnbackedCorruptWorkflowDocument = true
                }
                return fallback
            }
        }

        let document = WorkflowPresetDocument(updatedAt: now())
        saveWorkflowPresets(document)
        return document
    }

    func updateWorkflowPresets(
        _ mutation: (inout WorkflowPresetDocument) -> Void
    ) {
        var document = loadWorkflowPresets()
        mutation(&document)
        saveWorkflowPresets(document)
    }

    func saveWorkflowPresets(_ document: WorkflowPresetDocument) {
        do {
            try saveWorkflowPresetsThrowing(document)
        } catch {
            print("⚠️ Failed to save workflow presets JSON at \(workflowFileURL.path): \(error)")
        }
    }

    func saveWorkflowPresetsThrowing(_ document: WorkflowPresetDocument) throws {
        guard !preservingUnsupportedFutureWorkflowDocument else {
            throw PresetFileStoreError.unsupportedFutureSchemaPreserved
        }
        guard !preservingUnbackedCorruptWorkflowDocument else {
            throw PresetFileStoreError.unbackedCorruptDocumentPreserved
        }
        if let version = unsupportedFutureSchemaVersionOnDisk(at: workflowFileURL) {
            preservingUnsupportedFutureWorkflowDocument = true
            throw PresetFileStoreError.unsupportedFutureSchema(version)
        }
        var documentToWrite = document
        documentToWrite.schemaVersion = Self.currentSchemaVersion
        documentToWrite.updatedAt = now()
        try ensurePresetDirectoryExists(for: workflowFileURL)
        let data = try Self.fileEncoder.encode(documentToWrite)
        try data.write(to: workflowFileURL, options: .atomic)
    }

    func loadWorkflowDocument() throws -> WorkflowPresetDocument {
        let data = try Data(contentsOf: workflowFileURL)
        let header = try Self.fileDecoder.decode(DocumentHeader.self, from: data)
        guard header.schemaVersion <= Self.currentSchemaVersion else {
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
        if fileManager.fileExists(atPath: modelFileURL.path) {
            do {
                return try loadModelDocument()
            } catch let PresetFileStoreError.unsupportedFutureSchema(version) {
                preservingUnsupportedFutureModelDocument = true
                print("⚠️ Model presets JSON schema v\(version) is newer than supported v\(Self.currentSchemaVersion); preserving file and using in-memory defaults for this launch.")
                return ModelPresetDocument(updatedAt: now())
            } catch {
                let fallback = ModelPresetDocument(updatedAt: now())
                if backupCorruptFile(at: modelFileURL, prefix: "modelPresets", error: error) {
                    saveModelPresets(fallback)
                } else {
                    preservingUnbackedCorruptModelDocument = true
                }
                return fallback
            }
        }

        let document = ModelPresetDocument(updatedAt: now())
        saveModelPresets(document)
        return document
    }

    func saveModelPresets(_ document: ModelPresetDocument) {
        do {
            try saveModelPresetsThrowing(document)
        } catch {
            print("⚠️ Failed to save model presets JSON at \(modelFileURL.path): \(error)")
        }
    }

    func saveModelPresetsThrowing(_ document: ModelPresetDocument) throws {
        guard !preservingUnsupportedFutureModelDocument else {
            throw PresetFileStoreError.unsupportedFutureSchemaPreserved
        }
        guard !preservingUnbackedCorruptModelDocument else {
            throw PresetFileStoreError.unbackedCorruptDocumentPreserved
        }
        if let version = unsupportedFutureSchemaVersionOnDisk(at: modelFileURL) {
            preservingUnsupportedFutureModelDocument = true
            throw PresetFileStoreError.unsupportedFutureSchema(version)
        }
        var documentToWrite = document
        documentToWrite.schemaVersion = Self.currentSchemaVersion
        documentToWrite.updatedAt = now()
        try ensurePresetDirectoryExists(for: modelFileURL)
        let data = try Self.fileEncoder.encode(documentToWrite)
        try data.write(to: modelFileURL, options: .atomic)
    }

    func loadModelDocument() throws -> ModelPresetDocument {
        let data = try Data(contentsOf: modelFileURL)
        let header = try Self.fileDecoder.decode(DocumentHeader.self, from: data)
        guard header.schemaVersion <= Self.currentSchemaVersion else {
            preservingUnsupportedFutureModelDocument = true
            throw PresetFileStoreError.unsupportedFutureSchema(header.schemaVersion)
        }
        preservingUnsupportedFutureModelDocument = false
        preservingUnbackedCorruptModelDocument = false
        return try Self.fileDecoder.decode(ModelPresetDocument.self, from: data)
    }

    // MARK: - Files

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

    private func unsupportedFutureSchemaVersionOnDisk(at fileURL: URL) -> Int? {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let header = try? Self.fileDecoder.decode(DocumentHeader.self, from: data),
              header.schemaVersion > Self.currentSchemaVersion
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

    enum PresetFileStoreError: Error, Equatable, LocalizedError {
        case unsupportedFutureSchema(Int)
        case unsupportedFutureSchemaPreserved
        case unbackedCorruptDocumentPreserved

        var errorDescription: String? {
            switch self {
            case let .unsupportedFutureSchema(version):
                "Preset schema v\(version) is newer than supported v\(PresetFileStore.currentSchemaVersion)."
            case .unsupportedFutureSchemaPreserved:
                "Preset file uses a newer unsupported schema and was preserved."
            case .unbackedCorruptDocumentPreserved:
                "Preset file is corrupt and could not be backed up for safe replacement."
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
            schemaVersion: Int = PresetFileStore.currentSchemaVersion,
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
            schemaVersion: Int = PresetFileStore.currentSchemaVersion,
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
