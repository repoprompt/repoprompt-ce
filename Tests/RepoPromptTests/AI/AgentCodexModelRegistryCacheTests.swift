import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentCodexModelRegistryCacheTests: XCTestCase {
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
