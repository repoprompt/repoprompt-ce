import Foundation

struct StoredPromptImportResult: Equatable {
    let mergedPrompts: [StoredPromptRecord]
    let addedCount: Int
}

enum StoredPromptPersistenceMutationStatus: Equatable {
    case created
    case updated
    case deleted
    case unchanged
    case targetMissing
    case targetChanged
    case targetProtected
}

struct StoredPromptPersistenceMutationResult: Equatable {
    let status: StoredPromptPersistenceMutationStatus
    let prompts: [StoredPromptRecord]
}

@MainActor
protocol StoredPromptPersistenceServing {
    func loadPrompts() -> Result<[StoredPromptRecord], Error>
    func savePrompts(_ prompts: [StoredPromptRecord])
    func createPrompt(_ prompt: StoredPromptRecord) -> Result<StoredPromptPersistenceMutationResult, Error>
    func updatePrompt(
        matching expected: StoredPromptRecord,
        replacement: StoredPromptRecord,
        protectedIDs: Set<UUID>
    ) -> Result<StoredPromptPersistenceMutationResult, Error>
    func deletePrompt(
        matching expected: StoredPromptRecord,
        protectedIDs: Set<UUID>
    ) -> Result<StoredPromptPersistenceMutationResult, Error>
    func exportPrompts(to url: URL, prompts: [StoredPromptRecord]) throws
    func importPrompts(from url: URL) throws -> StoredPromptImportResult
}

@MainActor
struct StoredPromptPersistenceService: StoredPromptPersistenceServing {
    private let storage: PromptStorage

    init(storage: PromptStorage = .shared) {
        self.storage = storage
    }

    func loadPrompts() -> Result<[StoredPromptRecord], Error> {
        storage.loadPrompts()
    }

    func savePrompts(_ prompts: [StoredPromptRecord]) {
        storage.savePrompts(prompts)
    }

    func createPrompt(_ prompt: StoredPromptRecord) -> Result<StoredPromptPersistenceMutationResult, Error> {
        storage.mutatePrompts { prompts in
            prompts.append(prompt)
            return (.created, true)
        }
        .map { StoredPromptPersistenceMutationResult(status: $0.value, prompts: $0.prompts) }
    }

    func updatePrompt(
        matching expected: StoredPromptRecord,
        replacement: StoredPromptRecord,
        protectedIDs: Set<UUID>
    ) -> Result<StoredPromptPersistenceMutationResult, Error> {
        storage.mutatePrompts { prompts in
            guard let index = prompts.firstIndex(where: { $0.id == expected.id }) else {
                return (.targetMissing, false)
            }
            let current = prompts[index]
            guard !protectedIDs.contains(current.id) else {
                return (.targetProtected, false)
            }
            guard exactlyMatches(current, expected) else {
                return (.targetChanged, false)
            }
            guard !exactlyMatches(current, replacement) else {
                return (.unchanged, false)
            }
            prompts[index] = replacement
            return (.updated, true)
        }
        .map { StoredPromptPersistenceMutationResult(status: $0.value, prompts: $0.prompts) }
    }

    func deletePrompt(
        matching expected: StoredPromptRecord,
        protectedIDs: Set<UUID>
    ) -> Result<StoredPromptPersistenceMutationResult, Error> {
        storage.mutatePrompts { prompts in
            guard let index = prompts.firstIndex(where: { $0.id == expected.id }) else {
                return (.targetMissing, false)
            }
            let current = prompts[index]
            guard !protectedIDs.contains(current.id) else {
                return (.targetProtected, false)
            }
            guard exactlyMatches(current, expected) else {
                return (.targetChanged, false)
            }
            prompts.remove(at: index)
            return (.deleted, true)
        }
        .map { StoredPromptPersistenceMutationResult(status: $0.value, prompts: $0.prompts) }
    }

    func exportPrompts(to url: URL, prompts: [StoredPromptRecord]) throws {
        try storage.exportPrompts(to: url, prompts: prompts)
    }

    func importPrompts(from url: URL) throws -> StoredPromptImportResult {
        let external = try storage.loadExternalPrompts(from: url)
        let result = try storage.mutatePrompts { prompts in
            let mergeResult = storage.mergeExternalPrompts(current: prompts, external: external)
            prompts = mergeResult.merged
            return (mergeResult.addedCount, mergeResult.addedCount > 0)
        }
        .get()
        return StoredPromptImportResult(
            mergedPrompts: result.prompts,
            addedCount: result.value
        )
    }

    private func exactlyMatches(_ lhs: StoredPromptRecord, _ rhs: StoredPromptRecord) -> Bool {
        lhs.id == rhs.id &&
            lhs.title == rhs.title &&
            lhs.content == rhs.content &&
            lhs.isUserEdited == rhs.isUserEdited
    }
}
