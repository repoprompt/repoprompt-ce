import Foundation
import RepoPromptAIContracts
@testable import RepoPromptCodexProvider
import XCTest

final class AgentCodexModelRegistryOwnershipTests: XCTestCase {
    func testInjectedInvalidatorRunsOnlyForChangedLiveModels() {
        let ports = RegistryPorts()
        let registry = ports.makeRegistry()
        let model = remoteModel(id: "injected-future", displayName: "Future", isDefault: false)
        XCTAssertTrue(registry.updateLiveModels([model]))
        XCTAssertFalse(registry.updateLiveModels([model]))
        XCTAssertEqual(ports.invalidationCount, 1)
        XCTAssertEqual(ports.saved, [[model]])
        XCTAssertEqual(registry.currentLiveModels(), [model])
        XCTAssertEqual(ports.events, ["invalidate", "save"])
        XCTAssertEqual(ports.loadCount, 0)
        XCTAssertEqual(ports.mappingCount, 0)
    }

    func testPreferredModelSnapshotsDoNotReuseAnotherCatalogsOptions() {
        let ports = RegistryPorts()
        let registry = ports.makeRegistry()
        let first = remoteModel(id: "future-alpha", displayName: "Alpha", isDefault: true)
        let second = remoteModel(id: "future-beta", displayName: "Beta", isDefault: false)
        let changedFirst = remoteModel(id: "future-alpha", displayName: "Alpha Updated", isDefault: false)

        let firstOptions = registry.resolvedOptions(staticOptions: [], preferredLiveModels: [first])
        XCTAssertEqual(firstOptions.map(\.rawValue), ["future-alpha"])
        XCTAssertEqual(firstOptions.map(\.displayName), ["Alpha"])
        XCTAssertEqual(firstOptions.map(\.isProviderDefault), [true])

        let secondOptions = registry.resolvedOptions(staticOptions: [], preferredLiveModels: [second])
        XCTAssertEqual(secondOptions.map(\.rawValue), ["future-beta"])
        XCTAssertEqual(secondOptions.map(\.displayName), ["Beta"])

        let changedOptions = registry.resolvedOptions(staticOptions: [], preferredLiveModels: [changedFirst])
        XCTAssertEqual(changedOptions.map(\.displayName), ["Alpha Updated"])
        XCTAssertEqual(changedOptions.map(\.isProviderDefault), [false])

        let repeatedOptions = registry.resolvedOptions(staticOptions: [], preferredLiveModels: [first])
        XCTAssertEqual(repeatedOptions.map(\.displayName), ["Alpha"])
        XCTAssertEqual(repeatedOptions.map(\.isProviderDefault), [true])
        XCTAssertEqual(ports.mappingCount, 3)
        // A fourth exact snapshot evicts the oldest entry, not another source's current result.
        _ = registry.resolvedOptions(staticOptions: [], preferredLiveModels: [remoteModel(id: "fourth", displayName: "Fourth", isDefault: false)])
        _ = registry.resolvedOptions(staticOptions: [], preferredLiveModels: [first])
        XCTAssertEqual(ports.mappingCount, 5)
        XCTAssertEqual(ports.loadCount, 0)
    }

    func testOneRecordsSnapshotDrivesTheWholeProjection() {
        let ports = RegistryPorts()
        let registry = ports.makeRegistry()
        let live = remoteModel(id: "live", displayName: "Live", isDefault: true)
        let stored = remoteModel(id: "stored", displayName: "Stored", isDefault: false)
        XCTAssertTrue(registry.updateLiveModels([live]))
        ports.stored = [modelRecord(stored)]
        let fallback = option(id: "static", displayName: "Static", isDefault: false)
        XCTAssertEqual(registry.resolvedOptions(staticOptions: [fallback]).map(\.rawValue), ["live", "static"])
        XCTAssertEqual(ports.loadCount, 0)
        // The records snapshot handed to resolveOptions is the one that produced the options.
        XCTAssertEqual(ports.resolvedRecords.last, [modelRecord(live)])
        // Explicit empty preferred input deliberately skips the known live source.
        XCTAssertEqual(registry.resolvedOptions(staticOptions: []).count, 1)
        XCTAssertEqual(registry.resolvedOptions(staticOptions: [], preferredLiveModels: []).map(\.rawValue), ["stored"])
        XCTAssertEqual(ports.loadCount, 1)
        XCTAssertEqual(ports.resolvedRecords.last, [modelRecord(stored)])
        // One catalog snapshot per projection: identical canonical records share one
        // cache entry whether they arrive as a preferred list or from persistence.
        let mappingsBeforeRepeat = ports.mappingCount
        _ = registry.resolvedOptions(staticOptions: [], preferredLiveModels: [stored])
        _ = registry.resolvedOptions(staticOptions: [], preferredLiveModels: [])
        XCTAssertEqual(ports.mappingCount, mappingsBeforeRepeat)
        // Empty records resolve static options against an empty snapshot without mapping.
        ports.stored = []
        XCTAssertEqual(registry.resolvedOptions(staticOptions: [fallback], preferredLiveModels: []), [fallback])
        XCTAssertEqual(ports.resolvedRecords.last, [])
        XCTAssertEqual(ports.mappingCount, mappingsBeforeRepeat)
    }

    private final class RegistryPorts {
        var stored: [CodexDynamicModelRecord] = []
        var saved: [[CodexAppServerClient.RemoteModel]] = []
        var events: [String] = []
        var invalidationCount = 0
        var loadCount = 0
        var mappingCount = 0
        var resolvedRecords: [[CodexDynamicModelRecord]] = []

        func makeRegistry() -> AgentCodexModelRegistry {
            AgentCodexModelRegistry(
                dependencies: .init(
                    canonicalRecords: { $0.map(modelRecord) },
                    save: { self.saved.append($0)
                        self.events.append("save")
                    },
                    load: { self.loadCount += 1
                        return self.stored
                    },
                    storedOptions: {
                        self.mappingCount += 1
                        return $0.map { option(id: $0.id, displayName: $0.displayName, isDefault: $0.isDefault) }
                    },
                    resolveOptions: { dynamicOptions, staticOptions, records in
                        self.resolvedRecords.append(records)
                        return dynamicOptions + staticOptions
                    }
                ),
                invalidate: { self.invalidationCount += 1
                    self.events.append("invalidate")
                }
            )
        }
    }
}

private func option(id: String, displayName: String, isDefault: Bool) -> AgentModelOption {
    AgentModelOption(rawValue: id, displayName: displayName, description: nil, isPlaceholderDefault: false, isProviderDefault: isDefault)
}

private func modelRecord(_ model: CodexAppServerClient.RemoteModel) -> CodexDynamicModelRecord {
    CodexDynamicModelRecord(
        id: model.id,
        model: model.model,
        displayName: model.displayName,
        description: model.description,
        isDefault: model.isDefault,
        supportedReasoningEfforts: model.supportedReasoningEfforts.map {
            .init(reasoningEffort: $0.reasoningEffort, description: $0.description)
        },
        defaultReasoningEffort: model.defaultReasoningEffort,
        serviceTiers: model.serviceTiers
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
