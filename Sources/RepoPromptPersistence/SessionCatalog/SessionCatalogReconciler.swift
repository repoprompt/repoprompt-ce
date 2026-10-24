import Foundation

/// A lifecycle-owned background job. Queries receive the catalog, not this worker; they never
/// wait for migration or trigger storage enumeration. A finished durable checkpoint costs one
/// indexed read on a later start, regardless of the number of classified directories.
package actor SessionCatalogReconciler {
    package enum State: Equatable {
        case idle
        case running(UUID)
        case finished(SessionCatalogReconciliation)
        case blocked(SessionCatalogReconciliation?, SessionCatalogError?)
        case cancelled(SessionCatalogReconciliation?)
    }

    private struct Active {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let catalog: SessionCatalogStore
    private let source: any SessionCatalogReconciliationSource
    private var active: Active?
    package private(set) var state: State = .idle

    package init(catalog: SessionCatalogStore, source: any SessionCatalogReconciliationSource) {
        self.catalog = catalog
        self.source = source
    }

    package func start(restart: Bool = false) {
        guard active == nil else { return }
        let id = UUID()
        let catalog = catalog
        let source = source
        state = .running(id)
        let task = Task.detached(priority: .background) { [weak self] in
            let result = await Self.drive(catalog: catalog, source: source, restart: restart)
            await self?.finished(id: id, result: result)
        }
        active = Active(id: id, task: task)
    }

    /// Lifecycle/validation barrier only. No discovery service may call this method.
    package func wait() async {
        await active?.task.value
    }

    package func stop() async {
        guard let active else { return }
        active.task.cancel()
        await active.task.value
    }

    private func finished(id: UUID, result: State) {
        guard active?.id == id else { return }
        active = nil
        state = result
    }

    private static func drive(
        catalog: SessionCatalogStore,
        source: any SessionCatalogReconciliationSource,
        restart: Bool
    ) async -> State {
        var progress: SessionCatalogReconciliation?
        do {
            try Task.checkCancellation()
            var current = try await catalog.beginReconciliation(restart: restart)
            progress = current
            while !current.finished {
                try Task.checkCancellation()
                // The source must do bounded IO and cooperate with cancellation. No catalog lock
                // is held while it discovers/decodes a directory, index, or transcript header.
                let batch = try await source.nextBatch(after: current, maximumItems: SessionCatalogReconciliationBatch.maximumItems)
                try Task.checkCancellation()
                let receipt = try await catalog.applyReconciliationBatch(batch, expected: current)
                current = receipt.progress
                progress = current
                // Deliberately yield between bounded transactions; no tight root-sized job monopolizes
                // a reader executor, and there is no polling loop after completion or failure.
                if !current.finished { try await Task.sleep(for: .milliseconds(20)) }
            }
            return .finished(current)
        } catch is CancellationError {
            return .cancelled(progress)
        } catch {
            // Keep the last durable checkpoint, including incomplete coverage. A later lifecycle or
            // explicit drift-repair event may resume it; a query never retries a failed source.
            return .blocked(progress, error as? SessionCatalogError)
        }
    }
}
