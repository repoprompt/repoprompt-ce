import Foundation
import RepoPromptAIContracts

package final class AgentCodexModelRegistry {
    /// App storage and option policy stay authoritative; assembling these operations is pure.
    package struct Dependencies {
        package let canonicalRecords: ([CodexAppServerClient.RemoteModel]) -> [CodexDynamicModelRecord]
        package let save: ([CodexAppServerClient.RemoteModel]) -> Void
        package let load: () -> [CodexDynamicModelRecord]
        package let remoteOptions: ([CodexAppServerClient.RemoteModel]) -> [AgentModelOption]
        package let storedOptions: ([CodexDynamicModelRecord]) -> [AgentModelOption]
        package let resolveOptions: ([AgentModelOption], [AgentModelOption]) -> [AgentModelOption]
        package let addingFastVariants: ([AgentModelOption]) -> [AgentModelOption]

        package init(
            canonicalRecords: @escaping ([CodexAppServerClient.RemoteModel]) -> [CodexDynamicModelRecord],
            save: @escaping ([CodexAppServerClient.RemoteModel]) -> Void,
            load: @escaping () -> [CodexDynamicModelRecord],
            remoteOptions: @escaping ([CodexAppServerClient.RemoteModel]) -> [AgentModelOption],
            storedOptions: @escaping ([CodexDynamicModelRecord]) -> [AgentModelOption],
            resolveOptions: @escaping ([AgentModelOption], [AgentModelOption]) -> [AgentModelOption],
            addingFastVariants: @escaping ([AgentModelOption]) -> [AgentModelOption]
        ) {
            self.canonicalRecords = canonicalRecords
            self.save = save
            self.load = load
            self.remoteOptions = remoteOptions
            self.storedOptions = storedOptions
            self.resolveOptions = resolveOptions
            self.addingFastVariants = addingFastVariants
        }
    }

    private let dependencies: Dependencies
    private let invalidate: () -> Void
    private let lock = NSLock()
    private var liveModels: [CodexAppServerClient.RemoteModel] = []
    private var liveModelSignature: [CodexDynamicModelRecord] = []
    private enum DynamicOptionsInput: Equatable {
        case remote([CodexAppServerClient.RemoteModel])
        case stored([CodexDynamicModelRecord])
    }

    private struct DynamicOptionsCacheEntry {
        let input: DynamicOptionsInput
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

    package func resolvedOptions(
        staticOptions: [AgentModelOption],
        preferredLiveModels: [CodexAppServerClient.RemoteModel]? = nil
    ) -> [AgentModelOption] {
        if let preferredLiveModels {
            if !preferredLiveModels.isEmpty {
                return dependencies.resolveOptions(
                    codexDynamicOptions(from: preferredLiveModels),
                    staticOptions
                )
            }
            let cachedRecords = dependencies.load()
            if !cachedRecords.isEmpty {
                return dependencies.resolveOptions(
                    codexDynamicOptions(from: cachedRecords),
                    staticOptions
                )
            }
            return dependencies.addingFastVariants(staticOptions)
        }

        let knownLiveModels = currentLiveModels()
        if !knownLiveModels.isEmpty {
            return dependencies.resolveOptions(
                codexDynamicOptions(from: knownLiveModels),
                staticOptions
            )
        }

        let cachedRecords = dependencies.load()
        if !cachedRecords.isEmpty {
            return dependencies.resolveOptions(
                codexDynamicOptions(from: cachedRecords),
                staticOptions
            )
        }

        return dependencies.addingFastVariants(staticOptions)
    }

    private func codexDynamicOptions(
        from models: [CodexAppServerClient.RemoteModel]
    ) -> [AgentModelOption] {
        cachedOptions(for: .remote(models)) {
            dependencies.remoteOptions(models)
        }
    }

    private func codexDynamicOptions(
        from records: [CodexDynamicModelRecord]
    ) -> [AgentModelOption] {
        cachedOptions(for: .stored(records)) {
            dependencies.storedOptions(records)
        }
    }

    private func cachedOptions(
        for input: DynamicOptionsInput,
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
