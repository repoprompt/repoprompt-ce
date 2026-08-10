import Foundation

struct StoredPromptImportResult: Equatable {
    let mergedPrompts: [StoredPromptRecord]
    let addedCount: Int
}

@MainActor
protocol StoredPromptPersistenceServing {
    func loadPrompts() -> Result<[StoredPromptRecord], Error>
    func savePrompts(_ prompts: [StoredPromptRecord])
    func exportPrompts(to url: URL, prompts: [StoredPromptRecord]) throws
    func importPrompts(
        from url: URL,
        mergingInto current: [StoredPromptRecord]
    ) throws -> StoredPromptImportResult
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

    func exportPrompts(to url: URL, prompts: [StoredPromptRecord]) throws {
        try storage.exportPrompts(to: url, prompts: prompts)
    }

    func importPrompts(
        from url: URL,
        mergingInto current: [StoredPromptRecord]
    ) throws -> StoredPromptImportResult {
        let external = try storage.loadExternalPrompts(from: url)
        let (merged, addedCount) = storage.mergeExternalPrompts(
            current: current,
            external: external
        )
        if addedCount > 0 {
            storage.savePrompts(merged)
        }
        return StoredPromptImportResult(
            mergedPrompts: merged,
            addedCount: addedCount
        )
    }
}
