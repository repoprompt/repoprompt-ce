@testable import RepoPromptApp
import XCTest

final class StoredPromptPersistenceBoundaryTests: XCTestCase {
    func testStoredRecordPreservesLegacyDecodingAndEqualitySemantics() throws {
        let id = UUID()
        let legacyJSON = """
        {
          "id": "\(id.uuidString)",
          "title": "Legacy",
          "content": "Prompt"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(StoredPromptRecord.self, from: legacyJSON)
        XCTAssertFalse(decoded.isUserEdited)
        XCTAssertEqual(
            decoded,
            StoredPromptRecord(
                id: id,
                title: "Legacy",
                content: "Prompt",
                isUserEdited: true
            ),
            "Stored prompt equality intentionally ignores the migration metadata flag"
        )

        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "title", "content", "isUserEdited"])
        XCTAssertEqual(object["id"] as? String, id.uuidString)
        XCTAssertEqual(object["title"] as? String, "Legacy")
        XCTAssertEqual(object["content"] as? String, "Prompt")
        XCTAssertEqual(object["isUserEdited"] as? Bool, false)
    }

    @MainActor
    func testConcreteServiceImportsUniquePromptsAndPersistsMergedSnapshot() throws {
        let directory = try makeTestDirectory()
        let storageURL = directory.appendingPathComponent("SavedPrompts.json")
        let importURL = directory.appendingPathComponent("Import.json")
        let storage = PromptStorage(fileURL: storageURL)
        let service = StoredPromptPersistenceService(storage: storage)
        let current = [
            StoredPromptRecord(id: UUID(), title: "Existing", content: "Keep")
        ]
        let external = [
            PromptExport(title: "Existing", content: "Keep"),
            PromptExport(title: "First", content: "New one"),
            PromptExport(title: "First", content: "New one"),
            PromptExport(title: "Second", content: "New two")
        ]
        try JSONEncoder().encode(external).write(to: importURL, options: .atomic)

        let result = try service.importPrompts(from: importURL, mergingInto: current)

        XCTAssertEqual(result.addedCount, 2)
        XCTAssertEqual(result.mergedPrompts.map(\.title), ["Existing", "First", "Second"])
        XCTAssertEqual(result.mergedPrompts.first?.id, current[0].id)
        XCTAssertFalse(result.mergedPrompts[1].isUserEdited)
        XCTAssertFalse(result.mergedPrompts[2].isUserEdited)
        XCTAssertNotEqual(result.mergedPrompts[1].id, result.mergedPrompts[2].id)

        let persisted = try storage.loadPrompts().get()
        XCTAssertEqual(persisted, result.mergedPrompts)
    }

    @MainActor
    func testViewModelLoadFailurePreservesCorruptionProtection() {
        let persistence = StoredPromptPersistenceSpy(loadResult: .failure(TestError.loadFailed))

        let viewModel = makePromptViewModel(persistence: persistence)

        XCTAssertTrue(viewModel.storedPrompts.isEmpty)
        XCTAssertTrue(persistence.savedSnapshots.isEmpty)
    }

    @MainActor
    func testViewModelImportDelegatesStateTransitionWithoutSecondSave() throws {
        let persistence = StoredPromptPersistenceSpy(loadResult: .success([]))
        let viewModel = makePromptViewModel(persistence: persistence)
        let original = viewModel.storedPrompts
        let imported = StoredPromptRecord(id: UUID(), title: "Imported", content: "Body")
        persistence.savedSnapshots.removeAll()
        persistence.importResult = StoredPromptImportResult(
            mergedPrompts: original + [imported],
            addedCount: 1
        )
        let importURL = URL(fileURLWithPath: "/tmp/StoredPromptPersistenceBoundaryTests-import.json")

        let addedCount = try viewModel.importPrompts(from: importURL)

        XCTAssertEqual(addedCount, 1)
        XCTAssertEqual(persistence.importedURL, importURL)
        XCTAssertEqual(persistence.importedCurrent, original)
        XCTAssertEqual(viewModel.storedPrompts, original + [imported])
        XCTAssertTrue(
            persistence.savedSnapshots.isEmpty,
            "The persistence command owns the import save; the view model must not enqueue a duplicate"
        )
    }

    @MainActor
    private func makePromptViewModel(
        persistence: any StoredPromptPersistenceServing
    ) -> PromptViewModel {
        let secureService = SecureKeysService(secureStorage: TestSecureStorageBackend(values: [:]))
        let keyManager = KeyManager(secureService: secureService)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        return PromptViewModel(
            fileManager: WorkspaceFilesViewModel(),
            apiSettingsViewModel: apiSettings,
            windowID: -902,
            settingsManager: WindowSettingsManager(windowID: -902),
            storedPromptPersistence: persistence
        )
    }
}

private enum TestError: Error {
    case loadFailed
}

@MainActor
private final class StoredPromptPersistenceSpy: StoredPromptPersistenceServing {
    var loadResult: Result<[StoredPromptRecord], Error>
    var savedSnapshots: [[StoredPromptRecord]] = []
    var exportedURL: URL?
    var exportedPrompts: [StoredPromptRecord] = []
    var importedURL: URL?
    var importedCurrent: [StoredPromptRecord] = []
    var importResult = StoredPromptImportResult(mergedPrompts: [], addedCount: 0)

    init(loadResult: Result<[StoredPromptRecord], Error>) {
        self.loadResult = loadResult
    }

    func loadPrompts() -> Result<[StoredPromptRecord], Error> {
        loadResult
    }

    func savePrompts(_ prompts: [StoredPromptRecord]) {
        savedSnapshots.append(prompts)
    }

    func exportPrompts(to url: URL, prompts: [StoredPromptRecord]) throws {
        exportedURL = url
        exportedPrompts = prompts
    }

    func importPrompts(
        from url: URL,
        mergingInto current: [StoredPromptRecord]
    ) throws -> StoredPromptImportResult {
        importedURL = url
        importedCurrent = current
        return importResult
    }
}
