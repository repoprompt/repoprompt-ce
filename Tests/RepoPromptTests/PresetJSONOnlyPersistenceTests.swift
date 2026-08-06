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
        let preset = ModelPreset(name: "Unsaved model", model: .claude4Sonnet)

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
