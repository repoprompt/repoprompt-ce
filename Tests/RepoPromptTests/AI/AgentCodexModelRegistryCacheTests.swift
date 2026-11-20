import Foundation
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptCodexProvider
import XCTest

final class AgentCodexModelRegistryCacheTests: XCTestCase {
    func testPreferredCatalogOwnsFastVariantIdentityDespiteConflictingPersistence() {
        let key = "CodexDynamicModelRecords"
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }
        let base = CodexAppServerClient.RemoteModel(
            id: "gpt-5.5", model: "gpt-5.5", displayName: "GPT-5.5", description: "", isDefault: true,
            supportedReasoningEfforts: [.init(reasoningEffort: "max", description: "")], defaultReasoningEffort: "max"
        )
        let collision = remoteModel(id: "gpt-5.5-fast-max", displayName: "Separate model", isDefault: false)
        CodexDynamicModelStore.save([base, collision])
        let registry = AgentCodexModelRegistry()

        let preferred = registry.resolvedOptions(staticOptions: [], preferredLiveModels: [base])
        let fast = preferred.first { $0.rawValue == "gpt-5.5-fast-max" }
        XCTAssertEqual(fast?.effortVariant?.baseModelRaw, "gpt-5.5-fast")
        XCTAssertEqual(fast?.effortVariant?.reasoningEffort, .max)
        XCTAssertEqual(fast?.displayName, "GPT-5.5 Fast Max")

        CodexDynamicModelStore.save([])
        let withCollision = registry.resolvedOptions(staticOptions: [], preferredLiveModels: [base, collision])
        let exact = withCollision.first { $0.rawValue == collision.id }
        XCTAssertEqual(exact?.displayName, "Separate Model")
        XCTAssertNil(exact?.effortVariant, "An exact advertised ID must stay a separate model")
        XCTAssertFalse(withCollision.contains { $0.rawValue == "gpt-5.5-max-fast" })
    }

    func testSpeedOnlyRefreshInvalidatesPickerAndPersistsCapabilities() {
        let registry = AgentCodexModelRegistry(invalidate: { AgentModelCatalogRuntime.shared.invalidate(.codexExec) })
        let persistenceKey = "CodexDynamicModelRecords"
        let originalPersistence = UserDefaults.standard.object(forKey: persistenceKey)
        defer { UserDefaults.standard.set(originalPersistence, forKey: persistenceKey) }
        let standard = CodexAppServerClient.RemoteModel(
            id: "future-model", model: "future-model", displayName: "Future", description: "", isDefault: true,
            supportedReasoningEfforts: [
                .init(reasoningEffort: "low", description: ""),
                .init(reasoningEffort: "max", description: "")
            ], defaultReasoningEffort: "max"
        )
        var ultrafast = standard
        ultrafast.serviceTiers = [.init(id: "ultrafast", name: "Ultrafast", description: "")]
        XCTAssertTrue(registry.updateLiveModels([standard]))
        XCTAssertFalse(registry.resolvedOptions(staticOptions: []).contains { $0.rawValue.hasPrefix("future-model-ultrafast") })
        XCTAssertTrue(registry.updateLiveModels([ultrafast]))
        XCTAssertFalse(registry.updateLiveModels([ultrafast]))
        XCTAssertTrue(registry.resolvedOptions(staticOptions: []).contains { $0.rawValue.hasPrefix("future-model-ultrafast") })
        XCTAssertEqual(CodexDynamicModelStore.load().first?.serviceTiers, ultrafast.serviceTiers)
        XCTAssertEqual(
            registry.resolvedOptions(staticOptions: []).first {
                $0.rawValue == "future-model-ultrafast-low"
            }?.defaultReasoningEffort, .max
        )
        XCTAssertTrue(CodexAIModelCatalog.modelsForPicker(staticModels: []).contains {
            $0.modelName.hasPrefix("future-model-ultrafast")
        })
        XCTAssertTrue(registry.updateLiveModels([standard]))
        XCTAssertFalse(registry.resolvedOptions(staticOptions: []).contains { $0.rawValue.hasPrefix("future-model-ultrafast") })
    }

    func testInvalidationRejectsPausedProducerWithoutOverwritingNewCatalogue() async throws {
        let registry = AgentModelCatalogRuntime.shared.codexRegistry
        let catalogue = AgentModelCatalogRuntime.shared
        let originalModels = registry.currentLiveModels()
        let persistenceKey = "CodexDynamicModelRecords"
        let originalPersistence = UserDefaults.standard.object(forKey: persistenceKey)
        defer {
            registry.updateLiveModels(originalModels)
            UserDefaults.standard.set(originalPersistence, forKey: persistenceKey)
            catalogue.invalidate(.codexExec)
        }
        registry.updateLiveModels([remoteModel(id: "paused-old", displayName: "Old", isDefault: true)])
        let snapshotRead = expectation(description: "Producer has read the old registry snapshot")
        let resume = AsyncStream<Void>.makeStream()
        defer { resume.continuation.finish() }
        let producer = Task.detached {
            // The generation must precede the source read, exactly as in options(for:).
            let generation = catalogue.productionGeneration(for: .codexExec)
            let options = AgentModelCatalogRuntime.shared.codexRegistry.resolvedOptions(staticOptions: [])
            snapshotRead.fulfill()
            for await _ in resume.stream {
                break
            }
            return catalogue.record(options, for: .codexExec, generation: generation)
        }
        await fulfillment(of: [snapshotRead], timeout: 5)
        registry.updateLiveModels([remoteModel(id: "current-new", displayName: "New", isDefault: true)])
        let availability = AgentModelCatalog.AvailabilityContext()
        XCTAssertThrowsError(try catalogue.selection("codexExec:paused-old", availability: availability)) { error in
            XCTAssertEqual(error as? AgentModelCatalogRuntime.AdmissionError, .catalogueUnavailable)
        }
        _ = AgentModelCatalog.options(for: .codexExec, availability: availability)
        resume.continuation.yield(())
        let recorded = await producer.value
        XCTAssertFalse(recorded, "A stale producer must not resurrect or overwrite the current catalogue")
        XCTAssertThrowsError(try catalogue.selection("codexExec:paused-old", availability: availability))
        XCTAssertEqual(
            try catalogue.selection("codexExec:current-new", availability: availability).storedModelRaw,
            "current-new"
        )
    }

    private func remoteModel(id: String, displayName: String, isDefault: Bool) -> CodexAppServerClient.RemoteModel {
        CodexAppServerClient.RemoteModel(
            id: id,
            model: id,
            displayName: displayName,
            description: "",
            isDefault: isDefault,
            supportedReasoningEfforts: [],
            defaultReasoningEffort: nil
        )
    }
}

final class CodexModelPollingServiceTests: XCTestCase {
    private struct ResultClient: CodexModelListingClient {
        let models: [CodexAppServerClient.RemoteModel]
        let failure: (any Error)?

        func listModels(limit _: Int) async throws -> [CodexAppServerClient.RemoteModel] {
            if let failure { throw failure }
            return models
        }

        func stop() async {}
    }

    private actor GatedClient: CodexModelListingClient {
        private let models: [CodexAppServerClient.RemoteModel]
        private var resultContinuation: CheckedContinuation<[CodexAppServerClient.RemoteModel], any Error>?
        private var startedContinuation: CheckedContinuation<Void, Never>?
        private var hasStarted = false

        init(models: [CodexAppServerClient.RemoteModel]) {
            self.models = models
        }

        func listModels(limit _: Int) async throws -> [CodexAppServerClient.RemoteModel] {
            try await withCheckedThrowingContinuation { continuation in
                resultContinuation = continuation
                hasStarted = true
                startedContinuation?.resume()
                startedContinuation = nil
            }
        }

        func waitUntilStarted() async {
            guard !hasStarted else { return }
            await withCheckedContinuation { continuation in
                startedContinuation = continuation
            }
        }

        func complete() {
            resultContinuation?.resume(returning: models)
            resultContinuation = nil
        }

        func stop() async {}
    }

    @MainActor
    func testRefreshReportsUpdatedUnchangedEmptyAndFailure() async {
        let registry = AgentModelCatalogRuntime.shared.codexRegistry
        let previousModels = registry.currentLiveModels()
        let previousStoredRecords = CodexDynamicModelStore.load()
        let restoreModels = previousModels.isEmpty ? remoteModels(from: previousStoredRecords) : previousModels
        let models = [remoteModel(id: "future-codex", displayName: "Future Codex")]
        defer { _ = registry.updateLiveModels(restoreModels) }

        let service = CodexModelPollingService(client: ResultClient(models: models, failure: nil))
        let updated = await service.refreshNow()
        let unchanged = await service.refreshNow()
        XCTAssertEqual(updated, .updated)
        XCTAssertEqual(unchanged, .unchanged)
        await service.shutdown()

        let empty = CodexModelPollingService(client: ResultClient(models: [], failure: nil))
        let emptyOutcome = await empty.refreshNow()
        XCTAssertEqual(emptyOutcome, .noModelsAdvertised)
        await empty.shutdown()

        let failed = CodexModelPollingService(
            client: ResultClient(models: [], failure: AIProviderError.invalidConfiguration(detail: "offline"))
        )
        let failedOutcome = await failed.refreshNow()
        XCTAssertEqual(failedOutcome, .failed)
        XCTAssertEqual(registry.currentLiveModels(), models, "a failed refresh must retain the last known good models")
        await failed.shutdown()
    }

    @MainActor
    func testCancelledRefreshReportsCancellationWithoutPublishing() async {
        let previousModels = AgentModelCatalogRuntime.shared.codexRegistry.currentLiveModels()
        let client = GatedClient(models: [remoteModel(id: "cancelled-codex", displayName: "Cancelled Codex")])
        let service = CodexModelPollingService(client: client)
        let refresh = Task { await service.refreshNow() }

        await client.waitUntilStarted()
        await service.shutdown(finishSubscribers: false)
        await client.complete()

        let outcome = await refresh.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(AgentModelCatalogRuntime.shared.codexRegistry.currentLiveModels(), previousModels)
    }

    @MainActor
    func testLateRefreshReplyCannotPublishAfterManagedSignOutBegins() async {
        let fence = CodexManagedSessionFence.shared
        let previousModels = AgentModelCatalogRuntime.shared.codexRegistry.currentLiveModels()
        let resetToken = fence.beginLogout()
        fence.finishLogout(token: resetToken, succeeded: false)
        let client = GatedClient(models: [remoteModel(id: "late-codex", displayName: "Late Codex")])
        let service = CodexModelPollingService(client: client)
        let refresh = Task { await service.refreshNow() }

        await client.waitUntilStarted()
        _ = fence.beginLogout()
        await client.complete()

        let outcome = await refresh.value
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(
            AgentModelCatalogRuntime.shared.codexRegistry.currentLiveModels(),
            previousModels,
            "a model/list reply captured before sign-out must not repopulate the registry"
        )
        await service.shutdown()
        let logoutToken = fence.beginLogout()
        fence.finishLogout(token: logoutToken, succeeded: false)
    }

    private func remoteModels(from records: [CodexDynamicModelRecord]) -> [CodexAppServerClient.RemoteModel] {
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
                defaultReasoningEffort: record.defaultReasoningEffort
            )
        }
    }

    private func remoteModel(id: String, displayName: String) -> CodexAppServerClient.RemoteModel {
        CodexAppServerClient.RemoteModel(
            id: id,
            model: id,
            displayName: displayName,
            description: "",
            isDefault: false,
            supportedReasoningEfforts: [],
            defaultReasoningEffort: nil
        )
    }
}
