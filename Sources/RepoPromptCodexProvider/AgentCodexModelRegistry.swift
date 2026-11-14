import Foundation
import RepoPromptAIContracts

package final class AgentCodexModelRegistry {
    /// App storage and option policy stay authoritative; assembling these operations is pure.
    package struct Dependencies {
        package let canonicalRecords: ([CodexAppServerClient.RemoteModel]) -> [CodexDynamicModelRecord]
        package let save: ([CodexAppServerClient.RemoteModel]) -> Void
        package let load: () -> [CodexDynamicModelRecord]
        package let storedOptions: ([CodexDynamicModelRecord]) -> [AgentModelOption]
        /// (dynamicOptions, staticOptions, records) — the records snapshot that produced
        /// `dynamicOptions`; the whole projection must consult only this snapshot.
        package let resolveOptions: ([AgentModelOption], [AgentModelOption], [CodexDynamicModelRecord]) -> [AgentModelOption]

        package init(
            canonicalRecords: @escaping ([CodexAppServerClient.RemoteModel]) -> [CodexDynamicModelRecord],
            save: @escaping ([CodexAppServerClient.RemoteModel]) -> Void,
            load: @escaping () -> [CodexDynamicModelRecord],
            storedOptions: @escaping ([CodexDynamicModelRecord]) -> [AgentModelOption],
            resolveOptions: @escaping ([AgentModelOption], [AgentModelOption], [CodexDynamicModelRecord]) -> [AgentModelOption]
        ) {
            self.canonicalRecords = canonicalRecords
            self.save = save
            self.load = load
            self.storedOptions = storedOptions
            self.resolveOptions = resolveOptions
        }
    }

    private let dependencies: Dependencies
    private let invalidate: () -> Void
    private let lock = NSLock()
    private var liveModels: [CodexAppServerClient.RemoteModel] = []
    private var liveModelSignature: [CodexDynamicModelRecord] = []
    private struct DynamicOptionsCacheEntry {
        let input: [CodexDynamicModelRecord]
        let options: [AgentModelOption]
    }

    /// Preferred, live, and persisted model lists can differ. Keep a few exact
    /// input snapshots rather than treating the most recent sort as universal.
    private var cachedDynamicOptions: [DynamicOptionsCacheEntry] = []

    package init(dependencies: Dependencies, invalidate: @escaping () -> Void) {
        self.dependencies = dependencies
        self.invalidate = invalidate
    }

    @discardableResult
    package func updateLiveModels(_ models: [CodexAppServerClient.RemoteModel]) -> Bool {
        let signature = dependencies.canonicalRecords(models)
        let normalized = remoteModels(from: signature)

        lock.lock()
        let didChange = signature != liveModelSignature
        if didChange {
            liveModels = normalized
            liveModelSignature = signature
        }
        lock.unlock()

        guard didChange else { return false }
        invalidate()
        dependencies.save(normalized)
        return true
    }

    package func currentLiveModels() -> [CodexAppServerClient.RemoteModel] {
        lock.lock()
        defer { lock.unlock() }
        return liveModels
    }

    private func currentLiveRecords() -> [CodexDynamicModelRecord] {
        lock.lock()
        defer { lock.unlock() }
        return liveModelSignature
    }

    package func resolvedOptions(
        staticOptions: [AgentModelOption],
        preferredLiveModels: [CodexAppServerClient.RemoteModel]? = nil
    ) -> [AgentModelOption] {
        // Resolve one catalog snapshot for the whole projection. Nested parsing,
        // labels, sorting, and variant generation must not consult persistence
        // again or mix this window's catalog with a different persisted catalog.
        let liveRecords = preferredLiveModels.map { dependencies.canonicalRecords($0) }
            ?? currentLiveRecords()
        let records = liveRecords.isEmpty ? dependencies.load() : liveRecords
        let dynamicOptions = records.isEmpty ? [] : codexDynamicOptions(from: records)
        return dependencies.resolveOptions(dynamicOptions, staticOptions, records)
    }

    private func codexDynamicOptions(
        from records: [CodexDynamicModelRecord]
    ) -> [AgentModelOption] {
        cachedOptions(for: records) {
            dependencies.storedOptions(records)
        }
    }

    private func cachedOptions(
        for input: [CodexDynamicModelRecord],
        makeDynamicOptions: () -> [AgentModelOption]
    ) -> [AgentModelOption] {
        lock.lock()
        if let cached = cachedDynamicOptions.first(where: { $0.input == input }) {
            lock.unlock()
            return cached.options
        }
        lock.unlock()

        // Sorting may be expensive; do it outside the registry lock. A concurrent
        // miss can duplicate work, but an older result cannot overwrite a newer
        // catalog because each entry retains the input that produced it.
        let result = makeDynamicOptions()

        lock.lock()
        if !cachedDynamicOptions.contains(where: { $0.input == input }) {
            cachedDynamicOptions.insert(DynamicOptionsCacheEntry(input: input, options: result), at: 0)
            if cachedDynamicOptions.count > 3 {
                cachedDynamicOptions.removeLast()
            }
        }
        lock.unlock()

        return result
    }

    private func remoteModels(
        from records: [CodexDynamicModelRecord]
    ) -> [CodexAppServerClient.RemoteModel] {
        records.map { record in
            CodexAppServerClient.RemoteModel(
                id: record.id,
                model: record.model,
                displayName: record.displayName,
                description: record.description,
                isDefault: record.isDefault,
                supportedReasoningEfforts: record.supportedReasoningEfforts.map {
                    CodexAppServerClient.RemoteReasoningEffort(
                        reasoningEffort: $0.reasoningEffort,
                        description: $0.description
                    )
                },
                defaultReasoningEffort: record.defaultReasoningEffort,
                serviceTiers: record.serviceTiers
            )
        }
    }
}
