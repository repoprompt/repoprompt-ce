import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class PresetJSONOnlyPersistenceTests: XCTestCase {
    func testDefaultPresetPathsUseCESupportRoot() {
        let workflowPath = PresetFileStore.defaultWorkflowFileURL().path
        let modelPath = PresetFileStore.defaultModelFileURL().path

        XCTAssertTrue(workflowPath.contains("/Application Support/RepoPrompt CE/Presets/workflowPresets.json"), workflowPath)
        XCTAssertTrue(modelPath.contains("/Application Support/RepoPrompt CE/Presets/modelPresets.json"), modelPath)
        XCTAssertFalse(workflowPath.contains("/Application Support/RepoPrompt/Presets/workflowPresets.json"), workflowPath)
        XCTAssertFalse(modelPath.contains("/Application Support/RepoPrompt/Presets/modelPresets.json"), modelPath)
    }

    func testMissingPresetJSONCreatesEmptyDocumentsAndIgnoresLegacyDefaults() throws {
        let legacyKeys = ["copyPresetsV1", "copyPresetVisibility", "chatPresetsV1", "modelPresets"]
        for key in legacyKeys {
            UserDefaults.standard.set(Data([1, 2, 3]), forKey: key)
        }
        defer { legacyKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = PresetFileStore(
            workflowFileURL: temp.appendingPathComponent("Presets/workflowPresets.json"),
            modelFileURL: temp.appendingPathComponent("Presets/modelPresets.json")
        )

        let workflow = store.loadWorkflowPresets()
        let model = store.loadModelPresets()

        XCTAssertTrue(workflow.copyUserPresets.isEmpty)
        XCTAssertTrue(workflow.chatUserPresets.isEmpty)
        XCTAssertTrue(model.modelPresets.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.workflowFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.modelFileURL.path))
    }

    func testPresetSaveWritesJSONOnlyAndDoesNotWriteLegacyMirrorKeys() throws {
        let legacyKeys = [
            "copyPresetsV1",
            "copyPresetVisibility",
            "copyPresetOverridesV1",
            "chatPresetsV1",
            "chatPresetVisibility",
            "chatPresetOverridesV1",
            "modelPresets",
            "modelPresets_migrated_v2",
            "presetFileStoreJSON.shadowHash.workflowV1",
            "presetFileStoreJSON.shadowHash.modelV1"
        ]
        legacyKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { legacyKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = PresetFileStore(
            workflowFileURL: temp.appendingPathComponent("Presets/workflowPresets.json"),
            modelFileURL: temp.appendingPathComponent("Presets/modelPresets.json")
        )

        try store.saveWorkflowPresets(.init())
        try store.saveModelPresets(.init())

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.workflowFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.modelFileURL.path))
        for key in legacyKeys {
            XCTAssertNil(UserDefaults.standard.object(forKey: key), key)
        }
    }

    func testPresetSaveReportsBlockedDestination() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let blockedParent = temp.appendingPathComponent("not-a-directory")
        try Data("blocking file".utf8).write(to: blockedParent)
        let store = PresetFileStore(
            workflowFileURL: blockedParent.appendingPathComponent("workflowPresets.json"),
            modelFileURL: blockedParent.appendingPathComponent("modelPresets.json")
        )

        XCTAssertThrowsError(try store.saveWorkflowPresets(.init()))
        XCTAssertThrowsError(try store.saveModelPresets(.init()))
    }

    @MainActor
    func testChatPresetManagerRollsBackFailedSaveAndPublishesError() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = try makeBlockedStore(in: temp)
        let manager = ChatPresetManager(presetFileStore: store)
        let preset = ChatPreset(name: "Unsaved chat", mode: .chat)

        manager.addPreset(preset)

        XCTAssertFalse(manager.userPresets.contains(where: { $0.id == preset.id }))
        XCTAssertNotNil(manager.persistenceErrorMessage)

        let blockedParent = store.workflowFileURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)
        manager.addPreset(preset)

        XCTAssertTrue(manager.userPresets.contains(where: { $0.id == preset.id }))
        XCTAssertNil(manager.persistenceErrorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.workflowFileURL.path))
    }

    @MainActor
    func testCopyPresetManagerRollsBackFailedSaveAndPublishesError() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = try makeBlockedStore(in: temp)
        let manager = CopyPresetManager(presetFileStore: store)
        let preset = CopyPreset(name: "Unsaved copy")

        manager.addPreset(preset)

        XCTAssertFalse(manager.userPresets.contains(where: { $0.id == preset.id }))
        XCTAssertNotNil(manager.persistenceErrorMessage)
    }

    @MainActor
    func testModelPresetManagerRollsBackFailedSaveAndPublishesError() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = try makeBlockedStore(in: temp)
        let manager = ModelPresetsManager(presetFileStore: store)
        let preset = try ModelPreset(name: "Unsaved model", model: .claude4Sonnet)

        XCTAssertFalse(manager.addPreset(preset))

        XCTAssertFalse(manager.presets.contains(where: { $0.id == preset.id }))
        XCTAssertNotNil(manager.persistenceErrorMessage)

        let blockedParent = store.modelFileURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)

        XCTAssertTrue(manager.addPreset(preset))
        XCTAssertTrue(manager.presets.contains(where: { $0.id == preset.id }))
        XCTAssertNil(manager.persistenceErrorMessage)
    }

    func testCorruptPresetJSONIsBackedUpAndReplacedWithEmptyDocument() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let workflowURL = temp.appendingPathComponent("Presets/workflowPresets.json")
        let modelURL = temp.appendingPathComponent("Presets/modelPresets.json")
        try FileManager.default.createDirectory(at: workflowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: workflowURL)
        try Data("not json".utf8).write(to: modelURL)

        let store = PresetFileStore(workflowFileURL: workflowURL, modelFileURL: modelURL, now: { Date(timeIntervalSince1970: 0) })
        let workflow = store.loadWorkflowPresets()
        let model = store.loadModelPresets()

        XCTAssertTrue(workflow.copyUserPresets.isEmpty)
        XCTAssertTrue(model.modelPresets.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(
            atPath: workflowURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true).path
        )
        XCTAssertTrue(backups.contains { $0.hasPrefix("workflowPresets.corrupt-") })
        XCTAssertTrue(backups.contains { $0.hasPrefix("modelPresets.corrupt-") })
    }

    func testUnbackedCorruptPresetDocumentIsPreservedAndSaveReportsFailure() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let presetsDirectory = temp.appendingPathComponent("Presets", isDirectory: true)
        let workflowURL = presetsDirectory.appendingPathComponent("workflowPresets.json")
        try FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: workflowURL)
        try Data("blocking file".utf8).write(to: presetsDirectory.appendingPathComponent("Backups"))
        let store = PresetFileStore(
            workflowFileURL: workflowURL,
            modelFileURL: presetsDirectory.appendingPathComponent("modelPresets.json")
        )

        XCTAssertTrue(store.loadWorkflowPresets().copyUserPresets.isEmpty)
        XCTAssertThrowsError(try store.saveWorkflowPresets(.init())) { error in
            XCTAssertEqual(error as? PresetFileStore.PresetFileStoreError, .unbackedCorruptDocumentPreserved)
        }
        XCTAssertEqual(try String(contentsOf: workflowURL, encoding: .utf8), "not json")
    }

    func testFuturePresetSchemaIsPreservedAndNotOverwritten() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let workflowURL = temp.appendingPathComponent("Presets/workflowPresets.json")
        let modelURL = temp.appendingPathComponent("Presets/modelPresets.json")
        try FileManager.default.createDirectory(at: workflowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let futureJSON = #"{"schemaVersion":999,"updatedAt":"2026-05-20T00:00:00Z"}"#
        try Data(futureJSON.utf8).write(to: workflowURL)
        try Data(futureJSON.utf8).write(to: modelURL)

        let store = PresetFileStore(workflowFileURL: workflowURL, modelFileURL: modelURL)
        XCTAssertTrue(store.loadWorkflowPresets().copyUserPresets.isEmpty)
        XCTAssertTrue(store.loadModelPresets().modelPresets.isEmpty)
        XCTAssertThrowsError(try store.saveWorkflowPresets(.init(copyVisibility: [UUID(): false]))) { error in
            XCTAssertEqual(error as? PresetFileStore.PresetFileStoreError, .unsupportedFutureSchema(999))
        }
        XCTAssertThrowsError(try store.saveModelPresets(.init())) { error in
            XCTAssertEqual(error as? PresetFileStore.PresetFileStoreError, .unsupportedFutureSchema(999))
        }

        XCTAssertEqual(try String(contentsOf: workflowURL, encoding: .utf8), futureJSON)
        XCTAssertEqual(try String(contentsOf: modelURL, encoding: .utf8), futureJSON)
    }

    func testDirectFuturePresetDocumentLoadProtectsLaterSave() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let workflowURL = temp.appendingPathComponent("Presets/workflowPresets.json")
        let modelURL = temp.appendingPathComponent("Presets/modelPresets.json")
        let store = PresetFileStore(workflowFileURL: workflowURL, modelFileURL: modelURL)
        try store.saveWorkflowPresets(.init(copyVisibility: [UUID(): true]))
        try store.saveModelPresets(.init())

        let futureJSON = #"{"schemaVersion":999,"updatedAt":"2026-05-20T00:00:00Z"}"#
        try Data(futureJSON.utf8).write(to: workflowURL)
        try Data(futureJSON.utf8).write(to: modelURL)

        XCTAssertThrowsError(try store.loadWorkflowDocument()) { error in
            XCTAssertEqual(error as? PresetFileStore.PresetFileStoreError, .unsupportedFutureSchema(999))
        }
        XCTAssertThrowsError(try store.loadModelDocument()) { error in
            XCTAssertEqual(error as? PresetFileStore.PresetFileStoreError, .unsupportedFutureSchema(999))
        }

        XCTAssertThrowsError(try store.saveWorkflowPresets(.init())) { error in
            XCTAssertEqual(error as? PresetFileStore.PresetFileStoreError, .unsupportedFutureSchema(999))
        }
        XCTAssertThrowsError(try store.saveModelPresets(.init())) { error in
            XCTAssertEqual(error as? PresetFileStore.PresetFileStoreError, .unsupportedFutureSchema(999))
        }

        XCTAssertEqual(try String(contentsOf: workflowURL, encoding: .utf8), futureJSON)
        XCTAssertEqual(try String(contentsOf: modelURL, encoding: .utf8), futureJSON)
    }

    @MainActor
    func testModelPresetConstructorsRoundTripAndRejectedCreationPreservesState() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let modelURL = temp.appendingPathComponent("modelPresets.json")
        let store = PresetFileStore(
            workflowFileURL: temp.appendingPathComponent("workflowPresets.json"),
            modelFileURL: modelURL
        )
        let presets = try [
            ModelPreset(name: "Single", model: .gpt54),
            ModelPreset(name: "Multiple", models: [.gpt54, .gpt54Mini]),
            ModelPreset.fromCurrentChatModel(.gpt54Mini)
        ]
        try store.saveModelPresets(.init(modelPresets: presets))
        let savedBytes = try Data(contentsOf: modelURL)

        XCTAssertEqual(try store.loadModelDocument().modelPresets, presets)

        let manager = ModelPresetsManager(presetFileStore: store)
        let oversizedModel = AIModel.customProvider(
            name: "Oversized",
            provider: "custom",
            model: String(repeating: "x", count: OracleRosterContract.maximumModelIdentifierLength)
        )
        XCTAssertThrowsError(try ModelPreset(name: "Rejected", model: oversizedModel))
        do {
            _ = try ModelPreset.fromCurrentChatModel(oversizedModel)
            XCTFail("Expected oversized current model rejection")
        } catch {
            manager.reportCreationError(error)
        }

        XCTAssertEqual(manager.presets, presets)
        XCTAssertEqual(try Data(contentsOf: modelURL), savedBytes)
        XCTAssertNotNil(manager.persistenceErrorMessage)
    }

    func testSchema1ModelPresetsMigrateToSchema2WithoutChangingWorkflowDocument() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let workflowURL = temp.appendingPathComponent("Presets/workflowPresets.json")
        let modelURL = temp.appendingPathComponent("Presets/modelPresets.json")
        try FileManager.default.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let workflowBytes = Data(#"{"schemaVersion":1,"updatedAt":"2026-09-10T00:00:00Z","copyUserPresets":[],"copyVisibilityByPresetID":{},"copyOverrides":[],"chatUserPresets":[],"chatVisibilityByPresetID":{},"chatOverrides":[]}"#.utf8)
        try workflowBytes.write(to: workflowURL)
        let presetID = UUID()
        let mappingID = UUID()
        let legacyBytes = legacyModelDocument(
            presetID: presetID,
            modelString: "  \(AIModel.gpt54Mini.rawValue)  ",
            extraFields: "\"description\":\"Keep me\",\"supportedModes\":{\"chat\":false,\"plan\":true,\"review\":true},\"chatPresetMappings\":{\"reviewPresetID\":\"\(mappingID.uuidString)\"}"
        )
        try legacyBytes.write(to: modelURL)
        let store = PresetFileStore(workflowFileURL: workflowURL, modelFileURL: modelURL)

        let document = store.loadModelPresets()

        XCTAssertEqual(document.modelPresets.count, 1)
        let preset = try XCTUnwrap(document.modelPresets.first)
        XCTAssertEqual(preset.id, presetID)
        XCTAssertEqual(preset.modelStrings, [AIModel.gpt54Mini.rawValue])
        XCTAssertEqual(preset.description, "Keep me")
        XCTAssertEqual(preset.supportedModes, SupportedModes(chat: false, plan: true, review: true))
        XCTAssertEqual(preset.chatPresetMappings?.reviewPresetID, mappingID)
        XCTAssertEqual(try Data(contentsOf: workflowURL), workflowBytes)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: modelURL)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, PresetFileStore.modelSchemaVersion)
        let records = try XCTUnwrap(object["modelPresets"] as? [[String: Any]])
        XCTAssertEqual(records.first?["modelStrings"] as? [String], [AIModel.gpt54Mini.rawValue])
        XCTAssertNil(records.first?["modelString"])
    }

    func testSchema2RejectsInvalidRosterDocumentsAsAWhole() throws {
        let invalidRosterValues = [
            "[]",
            "[\"valid\",\"valid\",\"valid\",\"valid\",\"valid\",\"valid\"]",
            "[\"   \"]",
            "[\"\(String(repeating: "x", count: 513))\"]",
            "\"not-an-array\""
        ]
        for rosterJSON in invalidRosterValues {
            let temp = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            let modelURL = temp.appendingPathComponent("modelPresets.json")
            let json = """
            {"schemaVersion":2,"updatedAt":"2026-09-10T00:00:00Z","modelPresets":[{"id":"\(UUID().uuidString)","name":"Invalid","modelStrings":\(rosterJSON)}]}
            """
            try Data(json.utf8).write(to: modelURL)
            let store = PresetFileStore(
                workflowFileURL: temp.appendingPathComponent("workflowPresets.json"),
                modelFileURL: modelURL
            )
            XCTAssertThrowsError(try store.loadModelDocument(), rosterJSON)
        }

        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let modelURL = temp.appendingPathComponent("modelPresets.json")
        let conflicting = """
        {"schemaVersion":2,"updatedAt":"2026-09-10T00:00:00Z","modelPresets":[{"id":"\(UUID().uuidString)","name":"Conflict","modelString":"old","modelStrings":["new"]}]}
        """
        try Data(conflicting.utf8).write(to: modelURL)
        let store = PresetFileStore(
            workflowFileURL: temp.appendingPathComponent("workflowPresets.json"),
            modelFileURL: modelURL
        )
        XCTAssertThrowsError(try store.loadModelDocument())
    }

    func testModelPresetDocumentsRejectUnsupportedPastAndInvalidLegacyRepresentations() throws {
        let documents = [
            #"{"schemaVersion":0,"updatedAt":"2026-09-10T00:00:00Z","modelPresets":[]}"#,
            #"{"schemaVersion":1,"updatedAt":"2026-09-10T00:00:00Z","modelPresets":[{"id":"00000000-0000-0000-0000-000000000001","name":"Wrong type","modelString":7}]}"#,
            #"{"schemaVersion":1,"updatedAt":"2026-09-10T00:00:00Z","modelPresets":[{"id":"00000000-0000-0000-0000-000000000001","name":"Conflict","modelString":"old","modelStrings":["new"]}]}"#,
            #"{"schemaVersion":2,"updatedAt":"2026-09-10T00:00:00Z","modelPresets":[{"id":"00000000-0000-0000-0000-000000000001","name":"Valid","modelStrings":["openai/gpt-5.4"]},{"id":"00000000-0000-0000-0000-000000000002","name":"Invalid","modelStrings":[]}]}"#
        ]

        for document in documents {
            let temp = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            let modelURL = temp.appendingPathComponent("modelPresets.json")
            try Data(document.utf8).write(to: modelURL)
            let store = PresetFileStore(
                workflowFileURL: temp.appendingPathComponent("workflowPresets.json"),
                modelFileURL: modelURL
            )
            XCTAssertThrowsError(try store.loadModelDocument(), document)
        }
    }

    @MainActor
    func testModelPresetManagerRollsBackUpdateDeleteAndReorderFailures() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let modelURL = temp.appendingPathComponent("modelPresets.json")
        let original = try [
            ModelPreset(name: "First", model: .gpt54),
            ModelPreset(name: "Second", model: .gpt54Mini)
        ]
        let seedStore = PresetFileStore(
            workflowFileURL: temp.appendingPathComponent("workflowPresets.json"),
            modelFileURL: modelURL
        )
        try seedStore.saveModelPresets(.init(modelPresets: original))
        let originalBytes = try Data(contentsOf: modelURL)
        let failingStore = PresetFileStore(
            workflowFileURL: temp.appendingPathComponent("workflowPresets.json"),
            modelFileURL: modelURL,
            writeData: { _, _ in throw TestWriteError.blocked }
        )
        let manager = ModelPresetsManager(presetFileStore: failingStore)

        let updated = try ModelPreset(
            id: original[0].id,
            name: "Updated",
            modelStrings: [AIModel.gpt54Mini.rawValue]
        )
        manager.updatePreset(updated)
        XCTAssertEqual(manager.presets, original)
        manager.removePreset(original[0])
        XCTAssertEqual(manager.presets, original)
        manager.movePresets(from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(manager.presets, original)
        XCTAssertEqual(try Data(contentsOf: modelURL), originalBytes)
        XCTAssertNotNil(manager.persistenceErrorMessage)
    }

    @MainActor
    func testMigrationWriteFailurePreservesLegacyBytesAndPublishesManagerWarning() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let modelURL = temp.appendingPathComponent("modelPresets.json")
        let legacyBytes = legacyModelDocument(
            presetID: UUID(),
            modelString: AIModel.gpt54Mini.rawValue,
            extraFields: "\"description\":\"Loaded despite write failure\""
        )
        try legacyBytes.write(to: modelURL)
        var shouldFailWrites = true
        let store = PresetFileStore(
            workflowFileURL: temp.appendingPathComponent("workflowPresets.json"),
            modelFileURL: modelURL,
            writeData: { data, url in
                if shouldFailWrites { throw TestWriteError.blocked }
                try data.write(to: url, options: .atomic)
            }
        )

        let manager = ModelPresetsManager(presetFileStore: store)

        XCTAssertEqual(manager.presets.map(\.modelStrings), [[AIModel.gpt54Mini.rawValue]])
        XCTAssertNotNil(manager.persistenceErrorMessage)
        XCTAssertEqual(try Data(contentsOf: modelURL), legacyBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("Backups").path))

        shouldFailWrites = false
        XCTAssertTrue(try manager.addPreset(ModelPreset(name: "Second", model: .gpt54)))
        XCTAssertNil(manager.persistenceErrorMessage)
        XCTAssertEqual(store.modelLoadWarning, nil)
    }

    private func legacyModelDocument(
        presetID: UUID,
        modelString: String,
        extraFields: String
    ) -> Data {
        let suffix = extraFields.isEmpty ? "" : ",\(extraFields)"
        return Data("""
        {"schemaVersion":1,"updatedAt":"2026-09-10T00:00:00Z","modelPresets":[{"id":"\(presetID.uuidString)","name":"Review-2","modelString":"\(modelString)"\(suffix)}]}
        """.utf8)
    }

    private enum TestWriteError: Error {
        case blocked
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetJSONOnlyPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBlockedStore(in directory: URL) throws -> PresetFileStore {
        let blockedParent = directory.appendingPathComponent("not-a-directory")
        try Data("blocking file".utf8).write(to: blockedParent)
        return PresetFileStore(
            workflowFileURL: blockedParent.appendingPathComponent("workflowPresets.json"),
            modelFileURL: blockedParent.appendingPathComponent("modelPresets.json")
        )
    }
}
