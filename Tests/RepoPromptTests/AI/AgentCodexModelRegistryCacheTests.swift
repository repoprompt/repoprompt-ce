import Darwin
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

final class CodexMapperMemoTests: XCTestCase {
    private func records() -> [CodexDynamicModelRecord] {
        ["gpt-6.1-sol", "gpt-6-luna", "gpt-5.3-codex", "gpt-5.5", "gpt-5.4", "gpt-5.2", "o3", "o4-mini", "codex-mini", "future-model"].enumerated().map { index, id in
            CodexDynamicModelRecord(id: id, model: id, displayName: id, description: "Description \(index)", isDefault: index == 0, supportedReasoningEfforts: ["low", "medium", "high", "xhigh"].map { .init(reasoningEffort: $0, description: $0) }, defaultReasoningEffort: "high")
        }
    }

    func testRepeatedMappingAndPickerTiming() throws {
        let records = records()
        let key = "CodexDynamicModelRecords"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        try defaults.set(JSONEncoder().encode(records), forKey: key)
        func measure(_ name: String, _ body: () -> Void) {
            let start = ProcessInfo.processInfo.systemUptime
            let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            body()
            print("CODEX_BASELINE \(name) wall_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000) cpu_ms=\(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1_000_000)")
        }
        measure("mapper cold") { _ = CodexDynamicModelMapper.options(from: records) }
        measure("picker cold") { _ = CodexAIModelCatalog.modelsForPicker(staticModels: []) }
        for pair in 0 ..< 5 {
            for cached in pair.isMultiple(of: 2) ? [false, true] : [true, false] {
                measure(cached ? "cached 37" : "mapper repeated 37") {
                    for _ in 0 ..< 37 {
                        if cached { _ = CodexDynamicModelStore.modelOptions(defaults: defaults) }
                        else { _ = CodexDynamicModelMapper.options(from: records) }
                    }
                }
            }
        }
        measure("picker repeated 37") { for _ in 0 ..< 37 {
            _ = CodexAIModelCatalog.modelsForPicker(staticModels: [])
        } }
    }

    func testPayloadTransitionsAndConcurrentReplacement() throws {
        let suiteA = "CodexMapperMemoTests-A-\(UUID())"
        let suiteB = "CodexMapperMemoTests-B-\(UUID())"
        let a = try XCTUnwrap(UserDefaults(suiteName: suiteA))
        let b = try XCTUnwrap(UserDefaults(suiteName: suiteB))
        defer { a.removePersistentDomain(forName: suiteA)
            b.removePersistentDomain(forName: suiteB)
        }
        let key = "CodexDynamicModelRecords"
        let original = records()
        let duplicate = CodexDynamicModelRecord(id: "GPT-6.1-SOL", model: "other", displayName: "é", description: "changed", isDefault: false, supportedReasoningEfforts: [.init(reasoningEffort: "ultra", description: "extra")], defaultReasoningEffort: "ultra", serviceTiers: [.init(id: "ultrafast", name: "Fast", description: "speed")])
        func unicodeRecord(_ spelling: String) -> CodexDynamicModelRecord {
            CodexDynamicModelRecord(id: spelling, model: spelling, displayName: spelling, description: spelling, isDefault: true, supportedReasoningEfforts: [.init(reasoningEffort: spelling, description: spelling)], defaultReasoningEffort: spelling)
        }
        let composed = [unicodeRecord("é")]
        let decomposed = [unicodeRecord("e\u{301}")]
        XCTAssertNotEqual(try JSONEncoder().encode(composed), try JSONEncoder().encode(decomposed))
        let inputs = [original, [duplicate] + original, Array(original.reversed()) + [duplicate], [], composed, decomposed, composed]
        for input in inputs {
            try a.set(JSONEncoder().encode(input), forKey: key)
            let expected = CodexDynamicModelMapper.options(from: input)
            for _ in 0 ..< 2 {
                let actual = CodexDynamicModelStore.modelOptions(defaults: a)
                XCTAssertEqual(actual, expected)
                func bytes(_ options: [CodexDynamicModelOption]) -> [[[UInt8]]] {
                    options.map { option in
                        ([option.id, option.baseID, option.displayName, option.description] + option.supportedReasoningEffortRawValues + [option.defaultReasoningEffortRawValue].compactMap(\.self)).map { Array($0.utf8) }
                    }
                }
                XCTAssertEqual(bytes(actual), bytes(expected))
            }
        }
        a.set(Data("malformed".utf8), forKey: key)
        XCTAssertEqual(CodexDynamicModelStore.modelOptions(defaults: a), [])
        a.removeObject(forKey: key)
        XCTAssertEqual(CodexDynamicModelStore.modelOptions(defaults: a), [])
        let dataA = try JSONEncoder().encode(original)
        let dataB = try JSONEncoder().encode([duplicate])
        a.set(dataA, forKey: key)
        b.set(dataB, forKey: key)
        let expectedA = CodexDynamicModelMapper.options(from: original)
        let expectedB = CodexDynamicModelMapper.options(from: [duplicate])
        let lock = NSLock()
        var mismatches = 0
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            let result = CodexDynamicModelStore.modelOptions(defaults: index.isMultiple(of: 2) ? a : b)
            if result != (index.isMultiple(of: 2) ? expectedA : expectedB) { lock.lock()
                mismatches += 1
                lock.unlock()
            }
        }
        XCTAssertEqual(mismatches, 0)
        // Force a miss, then replace the exact store payload during computation.
        let capturedData = try JSONEncoder().encode([duplicate] + original)
        a.set(capturedData, forKey: key)
        let captured = CodexDynamicModelStore.test_modelOptions(defaults: a) { a.set(dataB, forKey: key) }
        XCTAssertEqual(captured, CodexDynamicModelMapper.options(from: [duplicate] + original))
        a.set(capturedData, forKey: key) // No store read between replacement and restoration.
        var recomputed = false
        XCTAssertEqual(CodexDynamicModelStore.test_modelOptions(defaults: a) { recomputed = true }, captured)
        XCTAssertTrue(recomputed, "A result computed for a replaced payload must not be installed")
        a.set(dataB, forKey: key)
        XCTAssertEqual(CodexDynamicModelStore.modelOptions(defaults: a), expectedB)
        recomputed = false
        XCTAssertEqual(CodexDynamicModelStore.test_modelOptions(defaults: a) { recomputed = true }, expectedB)
        XCTAssertFalse(recomputed)

        let oversized = [CodexDynamicModelRecord(id: "large", model: "large", displayName: "large", description: String(repeating: "x", count: 1_050_000), isDefault: false)]
        try a.set(JSONEncoder().encode(oversized), forKey: key)
        _ = CodexDynamicModelStore.modelOptions(defaults: a)
        recomputed = false
        _ = CodexDynamicModelStore.test_modelOptions(defaults: a) { recomputed = true }
        XCTAssertTrue(recomputed)
    }
}
