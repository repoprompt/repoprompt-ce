import AppKit
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
        _ = try service.createPrompt(current[0]).get()

        let result = try service.importPrompts(from: importURL)

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
    func testConcreteServiceSerializesCrossOwnerCompareAndMutate() throws {
        let directory = try makeTestDirectory()
        let storage = PromptStorage(fileURL: directory.appendingPathComponent("SavedPrompts.json"))
        let firstOwner = StoredPromptPersistenceService(storage: storage)
        let secondOwner = StoredPromptPersistenceService(storage: storage)
        let original = StoredPromptRecord(id: UUID(), title: "Original", content: "Body")
        _ = try firstOwner.createPrompt(original).get()
        let firstReplacement = StoredPromptRecord(id: original.id, title: "First", content: "First body")
        let secondReplacement = StoredPromptRecord(id: original.id, title: "Second", content: "Second body")

        let firstResult = try firstOwner.updatePrompt(
            matching: original,
            replacement: firstReplacement,
            protectedIDs: []
        ).get()
        let secondResult = try secondOwner.updatePrompt(
            matching: original,
            replacement: secondReplacement,
            protectedIDs: []
        ).get()

        XCTAssertEqual(firstResult.status, .updated)
        XCTAssertEqual(secondResult.status, .targetChanged)
        XCTAssertEqual(secondResult.prompts, [firstReplacement])
        XCTAssertEqual(try storage.loadPrompts().get(), [firstReplacement])
    }

    @MainActor
    func testConcreteImportRebasesOntoAuthoritativePrompts() throws {
        let directory = try makeTestDirectory()
        let importURL = directory.appendingPathComponent("Import.json")
        let storage = PromptStorage(fileURL: directory.appendingPathComponent("SavedPrompts.json"))
        let firstOwner = StoredPromptPersistenceService(storage: storage)
        let staleOwner = StoredPromptPersistenceService(storage: storage)
        let original = StoredPromptRecord(id: UUID(), title: "Original", content: "Body")
        let updated = StoredPromptRecord(id: original.id, title: "Updated", content: "New body")
        _ = try firstOwner.createPrompt(original).get()
        _ = try firstOwner.updatePrompt(matching: original, replacement: updated, protectedIDs: []).get()
        try JSONEncoder().encode([PromptExport(title: "Imported", content: "Import body")])
            .write(to: importURL, options: .atomic)

        let result = try staleOwner.importPrompts(from: importURL)

        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.mergedPrompts.first, updated)
        XCTAssertEqual(result.mergedPrompts.last?.title, "Imported")
        XCTAssertEqual(try storage.loadPrompts().get(), result.mergedPrompts)
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
        XCTAssertEqual(viewModel.storedPrompts, original + [imported])
        XCTAssertTrue(
            persistence.savedSnapshots.isEmpty,
            "The persistence command owns the import save; the view model must not enqueue a duplicate"
        )
    }

    @MainActor
    func testNoOpImportRebaseRefreshesSelectedPromptInstructions() throws {
        let persistence = StoredPromptPersistenceSpy(loadResult: .success([]))
        let viewModel = makePromptViewModel(persistence: persistence)
        let prompt = try XCTUnwrap(viewModel.addStoredPrompt(title: "Original", content: "Old body").prompt)
        viewModel.updatePromptSelection([prompt.id], for: .copy)
        let updated = StoredPromptRecord(id: prompt.id, title: "Updated", content: "New body")
        persistence.importResult = StoredPromptImportResult(
            mergedPrompts: viewModel.storedPrompts.map { $0.id == prompt.id ? updated : $0 },
            addedCount: 0
        )

        let addedCount = try viewModel.importPrompts(from: URL(fileURLWithPath: "/tmp/no-op-import.json"))

        XCTAssertEqual(addedCount, 0)
        XCTAssertTrue(viewModel.selectedInstructionsText.contains("New body"))
        XCTAssertFalse(viewModel.selectedInstructionsText.contains("Old body"))
    }

    @MainActor
    func testImportPersistenceFailureDoesNotPublishMergedPrompts() {
        let persistence = StoredPromptPersistenceSpy(loadResult: .success([]))
        let viewModel = makePromptViewModel(persistence: persistence)
        let original = viewModel.storedPrompts
        persistence.importError = TestError.saveFailed

        XCTAssertThrowsError(
            try viewModel.importPrompts(from: URL(fileURLWithPath: "/tmp/import-failure.json"))
        )
        XCTAssertEqual(viewModel.storedPrompts, original)
    }

    @MainActor
    func testCreatedPromptPersistsOnceAndCanBeSelectedWithoutResavingPrompts() throws {
        let persistence = StoredPromptPersistenceSpy(loadResult: .success([]))
        let viewModel = makePromptViewModel(persistence: persistence)
        persistence.savedSnapshots.removeAll()

        let prompt = try XCTUnwrap(viewModel.addStoredPrompt(title: "New prompt", content: "New body\n").prompt)
        viewModel.selectNewPrompt(prompt)

        XCTAssertEqual(viewModel.storedPrompts.last, prompt)
        XCTAssertEqual(viewModel.promptSelection(for: .copy), [prompt.id])
        XCTAssertEqual(persistence.savedSnapshots.count, 1)
        XCTAssertEqual(persistence.savedSnapshots[0].last, prompt)
    }

    @MainActor
    func testMatchingEditNormalizesTitleAndPersistsOnce() throws {
        let persistence = StoredPromptPersistenceSpy(loadResult: .success([]))
        let viewModel = makePromptViewModel(persistence: persistence)
        let prompt = try XCTUnwrap(viewModel.addStoredPrompt(title: "Original", content: "Old body").prompt)
        viewModel.updatePromptSelection([prompt.id], for: .copy)
        persistence.savedSnapshots.removeAll()

        let result = viewModel.updateStoredPrompt(
            matching: prompt,
            title: "  Updated title  ",
            content: "New body\n"
        )

        XCTAssertEqual(result, .updated)
        let updated = try XCTUnwrap(viewModel.storedPrompts.first { $0.id == prompt.id })
        XCTAssertEqual(updated.title, "Updated title")
        XCTAssertEqual(updated.content, "New body\n")
        XCTAssertEqual(viewModel.promptSelection(for: .copy), [prompt.id])
        XCTAssertEqual(persistence.savedSnapshots.count, 1)
        XCTAssertEqual(persistence.savedSnapshots[0].first { $0.id == prompt.id }, updated)
    }

    @MainActor
    func testMatchingEditRejectsInvalidUnchangedAndProtectedTargetsWithoutSaving() throws {
        let persistence = StoredPromptPersistenceSpy(loadResult: .success([]))
        let viewModel = makePromptViewModel(persistence: persistence)
        let prompt = try XCTUnwrap(viewModel.addStoredPrompt(title: "Custom", content: "Body").prompt)
        let builtIn = try XCTUnwrap(viewModel.builtInStoredPrompts.first)
        viewModel.updatePromptSelection([prompt.id], for: .copy)
        viewModel.updatePromptSelection([prompt.id], for: .chat)
        persistence.savedSnapshots.removeAll()

        XCTAssertEqual(
            viewModel.updateStoredPrompt(matching: prompt, title: " Custom ", content: "Body"),
            .unchanged
        )
        XCTAssertEqual(
            viewModel.updateStoredPrompt(matching: prompt, title: "\n\t", content: "Body"),
            .invalidTitle
        )
        XCTAssertEqual(viewModel.promptSelection(for: .copy), [prompt.id])
        XCTAssertEqual(viewModel.promptSelection(for: .chat), [prompt.id])

        viewModel.updatePromptSelection([builtIn.id], for: .copy)
        viewModel.updatePromptSelection([builtIn.id], for: .chat)

        XCTAssertEqual(
            viewModel.updateStoredPrompt(matching: builtIn, title: "Changed", content: builtIn.content),
            .targetProtected
        )
        XCTAssertEqual(viewModel.removeStoredPrompt(matching: builtIn), .targetProtected)
        XCTAssertEqual(viewModel.promptSelection(for: .copy), [builtIn.id])
        XCTAssertEqual(viewModel.promptSelection(for: .chat), [builtIn.id])
        XCTAssertTrue(persistence.savedSnapshots.isEmpty)
    }

    @MainActor
    func testMatchingMutationsRejectChangedAndMissingTargetsWithoutSaving() throws {
        let persistence = StoredPromptPersistenceSpy(loadResult: .success([]))
        let viewModel = makePromptViewModel(persistence: persistence)
        let prompt = try XCTUnwrap(viewModel.addStoredPrompt(title: "Custom", content: "Body").prompt)
        viewModel.updatePromptSelection([prompt.id], for: .copy)
        viewModel.updatePromptSelection([prompt.id], for: .chat)
        persistence.savedSnapshots.removeAll()

        persistence.replaceAuthoritativePrompt(
            StoredPromptRecord(
                id: prompt.id,
                title: prompt.title,
                content: prompt.content,
                isUserEdited: true
            )
        )

        XCTAssertEqual(
            viewModel.updateStoredPrompt(matching: prompt, title: "Changed", content: "Body"),
            .targetChanged
        )
        XCTAssertEqual(viewModel.removeStoredPrompt(matching: prompt), .targetChanged)

        persistence.removeAuthoritativePrompt(prompt.id)

        XCTAssertEqual(
            viewModel.updateStoredPrompt(matching: prompt, title: "Changed", content: "Body"),
            .targetMissing
        )
        XCTAssertEqual(viewModel.removeStoredPrompt(matching: prompt), .targetMissing)
        XCTAssertTrue(viewModel.promptSelection(for: .copy).isEmpty)
        XCTAssertTrue(viewModel.promptSelection(for: .chat).isEmpty)
        XCTAssertTrue(persistence.savedSnapshots.isEmpty)
    }

    @MainActor
    func testAuthoritativeMutationRebaseRemovesUnrelatedMissingSelections() throws {
        let persistence = StoredPromptPersistenceSpy(loadResult: .success([]))
        let viewModel = makePromptViewModel(persistence: persistence)
        let editedPrompt = try XCTUnwrap(viewModel.addStoredPrompt(title: "Edit", content: "Body").prompt)
        let deletedElsewhere = try XCTUnwrap(viewModel.addStoredPrompt(title: "Delete", content: "Body").prompt)
        viewModel.updatePromptSelection([editedPrompt.id, deletedElsewhere.id], for: .copy)
        viewModel.updatePromptSelection([deletedElsewhere.id], for: .chat)
        persistence.removeAuthoritativePrompt(deletedElsewhere.id)

        XCTAssertEqual(
            viewModel.updateStoredPrompt(matching: editedPrompt, title: "Edited", content: "New body"),
            .updated
        )
        XCTAssertEqual(viewModel.promptSelection(for: .copy), [editedPrompt.id])
        XCTAssertTrue(viewModel.promptSelection(for: .chat).isEmpty)
    }

    @MainActor
    func testSecondWindowCannotOverwriteFirstWindowStoredPromptEdit() throws {
        let persistence = StoredPromptPersistenceSpy(loadResult: .success([]))
        let firstWindow = makePromptViewModel(persistence: persistence)
        let prompt = try XCTUnwrap(firstWindow.addStoredPrompt(title: "Original", content: "Body").prompt)
        let secondWindow = makePromptViewModel(persistence: persistence)
        let secondWindowSnapshot = try XCTUnwrap(secondWindow.storedPrompts.first { $0.id == prompt.id })
        persistence.savedSnapshots.removeAll()

        XCTAssertEqual(
            firstWindow.updateStoredPrompt(matching: prompt, title: "First window", content: "First body"),
            .updated
        )
        XCTAssertEqual(
            secondWindow.updateStoredPrompt(
                matching: secondWindowSnapshot,
                title: "Second window",
                content: "Second body"
            ),
            .targetChanged
        )

        let authoritative = try XCTUnwrap(secondWindow.storedPrompts.first { $0.id == prompt.id })
        XCTAssertEqual(authoritative.title, "First window")
        XCTAssertEqual(authoritative.content, "First body")
        XCTAssertEqual(persistence.savedSnapshots.count, 1)
    }

    @MainActor
    func testPersistenceFailureDoesNotPublishStoredPromptMutation() throws {
        let persistence = StoredPromptPersistenceSpy(loadResult: .success([]))
        let viewModel = makePromptViewModel(persistence: persistence)
        let prompt = try XCTUnwrap(viewModel.addStoredPrompt(title: "Original", content: "Body").prompt)
        let originalPrompts = viewModel.storedPrompts
        persistence.savedSnapshots.removeAll()
        persistence.mutationError = TestError.saveFailed

        XCTAssertEqual(
            viewModel.updateStoredPrompt(matching: prompt, title: "Changed", content: "Changed body"),
            .persistenceFailed
        )
        XCTAssertEqual(viewModel.removeStoredPrompt(matching: prompt), .persistenceFailed)
        XCTAssertEqual(viewModel.addStoredPrompt(title: "Unsaved", content: "Body"), .persistenceFailed)
        XCTAssertEqual(viewModel.storedPrompts, originalPrompts)
        XCTAssertTrue(persistence.savedSnapshots.isEmpty)
    }

    @MainActor
    func testCopyToClipboardCannotOverwriteNewerStoredPromptCopy() async throws {
        try await assertPromptCopyCannotOverwriteNewerStoredPromptCopy { viewModel in
            viewModel.copyToClipboard()
        }
    }

    @MainActor
    func testPerformCopyCannotOverwriteNewerStoredPromptCopy() async throws {
        try await assertPromptCopyCannotOverwriteNewerStoredPromptCopy { viewModel in
            viewModel.performCopy(using: viewModel.currentCopyPreset())
        }
    }

    @MainActor
    func testMatchingDeleteCleansCopyAndChatSelectionsBeforeSavingOnce() throws {
        let persistence = StoredPromptPersistenceSpy(loadResult: .success([]))
        let viewModel = makePromptViewModel(persistence: persistence)
        let prompt = try XCTUnwrap(viewModel.addStoredPrompt(title: "Custom", content: "Body").prompt)
        viewModel.updatePromptSelection([prompt.id], for: .copy)
        viewModel.updatePromptSelection([prompt.id], for: .chat)
        persistence.savedSnapshots.removeAll()

        let result = viewModel.removeStoredPrompt(matching: prompt)

        XCTAssertEqual(result, .deleted)
        XCTAssertFalse(viewModel.storedPrompts.contains { $0.id == prompt.id })
        XCTAssertFalse(viewModel.promptSelection(for: .copy).contains(prompt.id))
        XCTAssertFalse(viewModel.promptSelection(for: .chat).contains(prompt.id))
        XCTAssertEqual(persistence.savedSnapshots.count, 1)
        XCTAssertFalse(persistence.savedSnapshots[0].contains { $0.id == prompt.id })
    }

    @MainActor
    private func assertPromptCopyCannotOverwriteNewerStoredPromptCopy(
        invokeCopy: (PromptViewModel) -> Void
    ) async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PromptViewModelIntent-\(UUID().uuidString)"))
        defer { pasteboard.clearContents() }
        let persistence = StoredPromptPersistenceSpy(loadResult: .success([]))
        let viewModel = makePromptViewModel(persistence: persistence, promptClipboardPasteboard: pasteboard)
        let buildFence = TestReleaseFence(name: "PromptViewModel clipboard builder")
        let completion = AsyncTestCondition<Bool?>(nil)
        let prompt = StoredPromptRecord(id: UUID(), title: "Latest", content: "newer stored prompt content")
        viewModel.clipboardContentBuilderOverrideForTesting = {
            await buildFence.enterAndWait()
            return "stale prompt context"
        }
        viewModel.clipboardCommitCompletionForTesting = { didWrite in
            completion.update { $0 = didWrite }
        }

        invokeCopy(viewModel)
        await buildFence.waitUntilEntered()
        XCTAssertTrue(AgentContextStoredPromptClipboard.write(prompt: prompt, to: pasteboard))
        buildFence.release()
        try await completion.waitUntil("PromptViewModel clipboard commit finished") { $0 != nil }

        XCTAssertEqual(completion.snapshot(), false)
        XCTAssertEqual(pasteboard.string(forType: .string), prompt.content)
    }

    @MainActor
    private func makePromptViewModel(
        persistence: any StoredPromptPersistenceServing,
        promptClipboardPasteboard: NSPasteboard = .general
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
            storedPromptPersistence: persistence,
            promptClipboardPasteboard: promptClipboardPasteboard
        )
    }
}

private enum TestError: Error {
    case loadFailed
    case saveFailed
}

private extension PromptViewModel.StoredPromptCreateResult {
    var prompt: PromptViewModel.StoredPrompt? {
        if case let .created(prompt) = self {
            return prompt
        }
        return nil
    }
}

@MainActor
private final class StoredPromptPersistenceSpy: StoredPromptPersistenceServing {
    var loadResult: Result<[StoredPromptRecord], Error>
    var savedSnapshots: [[StoredPromptRecord]] = []
    var exportedURL: URL?
    var exportedPrompts: [StoredPromptRecord] = []
    var importedURL: URL?
    var importResult = StoredPromptImportResult(mergedPrompts: [], addedCount: 0)
    var importError: Error?
    var mutationError: Error?
    private var authoritativePrompts: [StoredPromptRecord]

    init(loadResult: Result<[StoredPromptRecord], Error>) {
        self.loadResult = loadResult
        authoritativePrompts = (try? loadResult.get()) ?? []
    }

    func loadPrompts() -> Result<[StoredPromptRecord], Error> {
        switch loadResult {
        case .failure:
            loadResult
        case .success:
            .success(authoritativePrompts)
        }
    }

    func savePrompts(_ prompts: [StoredPromptRecord]) {
        savedSnapshots.append(prompts)
        authoritativePrompts = prompts
    }

    func createPrompt(_ prompt: StoredPromptRecord) -> Result<StoredPromptPersistenceMutationResult, Error> {
        if let mutationError { return .failure(mutationError) }
        authoritativePrompts.append(prompt)
        savedSnapshots.append(authoritativePrompts)
        return .success(.init(status: .created, prompts: authoritativePrompts))
    }

    func updatePrompt(
        matching expected: StoredPromptRecord,
        replacement: StoredPromptRecord,
        protectedIDs: Set<UUID>
    ) -> Result<StoredPromptPersistenceMutationResult, Error> {
        if let mutationError { return .failure(mutationError) }
        guard let index = authoritativePrompts.firstIndex(where: { $0.id == expected.id }) else {
            return .success(.init(status: .targetMissing, prompts: authoritativePrompts))
        }
        let current = authoritativePrompts[index]
        guard !protectedIDs.contains(current.id) else {
            return .success(.init(status: .targetProtected, prompts: authoritativePrompts))
        }
        guard exactlyMatches(current, expected) else {
            return .success(.init(status: .targetChanged, prompts: authoritativePrompts))
        }
        guard !exactlyMatches(current, replacement) else {
            return .success(.init(status: .unchanged, prompts: authoritativePrompts))
        }
        authoritativePrompts[index] = replacement
        savedSnapshots.append(authoritativePrompts)
        return .success(.init(status: .updated, prompts: authoritativePrompts))
    }

    func deletePrompt(
        matching expected: StoredPromptRecord,
        protectedIDs: Set<UUID>
    ) -> Result<StoredPromptPersistenceMutationResult, Error> {
        if let mutationError { return .failure(mutationError) }
        guard let index = authoritativePrompts.firstIndex(where: { $0.id == expected.id }) else {
            return .success(.init(status: .targetMissing, prompts: authoritativePrompts))
        }
        let current = authoritativePrompts[index]
        guard !protectedIDs.contains(current.id) else {
            return .success(.init(status: .targetProtected, prompts: authoritativePrompts))
        }
        guard exactlyMatches(current, expected) else {
            return .success(.init(status: .targetChanged, prompts: authoritativePrompts))
        }
        authoritativePrompts.remove(at: index)
        savedSnapshots.append(authoritativePrompts)
        return .success(.init(status: .deleted, prompts: authoritativePrompts))
    }

    func exportPrompts(to url: URL, prompts: [StoredPromptRecord]) throws {
        exportedURL = url
        exportedPrompts = prompts
    }

    func importPrompts(from url: URL) throws -> StoredPromptImportResult {
        importedURL = url
        if let importError { throw importError }
        authoritativePrompts = importResult.mergedPrompts
        return importResult
    }

    func replaceAuthoritativePrompt(_ prompt: StoredPromptRecord) {
        guard let index = authoritativePrompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        authoritativePrompts[index] = prompt
    }

    func removeAuthoritativePrompt(_ promptID: UUID) {
        authoritativePrompts.removeAll { $0.id == promptID }
    }

    private func exactlyMatches(_ lhs: StoredPromptRecord, _ rhs: StoredPromptRecord) -> Bool {
        lhs.id == rhs.id &&
            lhs.title == rhs.title &&
            lhs.content == rhs.content &&
            lhs.isUserEdited == rhs.isUserEdited
    }
}
