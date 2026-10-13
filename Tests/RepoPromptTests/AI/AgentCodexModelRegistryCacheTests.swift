import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentCodexModelRegistryCacheTests: XCTestCase {
    func testSpeedOnlyRefreshInvalidatesPickerAndPersistsCapabilities() {
        let registry = AgentCodexModelRegistry()
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

    func testPreferredModelSnapshotsDoNotReuseAnotherCatalogsOptions() {
        let registry = AgentCodexModelRegistry()
        let first = remoteModel(id: "future-alpha", displayName: "Alpha", isDefault: true)
        let second = remoteModel(id: "future-beta", displayName: "Beta", isDefault: false)
        let changedFirst = remoteModel(id: "future-alpha", displayName: "Alpha Updated", isDefault: false)

        let firstOptions = registry.resolvedOptions(staticOptions: [], preferredLiveModels: [first])
        XCTAssertEqual(discoveredOptions(firstOptions).map(\.rawValue), ["future-alpha"])
        XCTAssertEqual(discoveredOptions(firstOptions).map(\.displayName), ["Alpha"])
        XCTAssertEqual(discoveredOptions(firstOptions).map(\.isProviderDefault), [true])

        let secondOptions = registry.resolvedOptions(staticOptions: [], preferredLiveModels: [second])
        XCTAssertEqual(discoveredOptions(secondOptions).map(\.rawValue), ["future-beta"])
        XCTAssertEqual(discoveredOptions(secondOptions).map(\.displayName), ["Beta"])

        let changedOptions = registry.resolvedOptions(staticOptions: [], preferredLiveModels: [changedFirst])
        XCTAssertEqual(discoveredOptions(changedOptions).map(\.displayName), ["Alpha Updated"])
        XCTAssertEqual(discoveredOptions(changedOptions).map(\.isProviderDefault), [false])

        let repeatedOptions = registry.resolvedOptions(staticOptions: [], preferredLiveModels: [first])
        XCTAssertEqual(discoveredOptions(repeatedOptions).map(\.displayName), ["Alpha"])
        XCTAssertEqual(discoveredOptions(repeatedOptions).map(\.isProviderDefault), [true])
    }

    func testInvalidationRejectsPausedProducerWithoutOverwritingNewCatalogue() async throws {
        let registry = AgentCodexModelRegistry.shared
        let catalogue = AgentAdvertisedModelCatalog.shared
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
            let options = AgentCodexModelRegistry.shared.resolvedOptions(staticOptions: [])
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
            XCTAssertEqual(error as? AgentAdvertisedModelCatalog.AdmissionError, .catalogueUnavailable)
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

    private func discoveredOptions(_ options: [AgentModelOption]) -> [AgentModelOption] {
        options.filter { !$0.isPlaceholderDefault }
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
