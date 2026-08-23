import Foundation
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class DuplicateUserInstructionsPersistTests: XCTestCase {
    func testMissingDefaultsOffAndOnPrependsThenKeepsOrderedCopy() throws {
        XCTAssertFalse(AdvancedServerSettings.default.duplicateUserInstructionsAtTop)

        let legacy = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"historyIdleThresholdMinutes":10}"#.utf8)
        )
        XCTAssertFalse(legacy.duplicateUserInstructionsAtTop)

        let off = AdvancedServerSettings.default.packagedContext(
            selectionRevision: 1,
            snippets: [
                .fileContents: "FILE",
                .userInstructions: "ASK",
            ]
        )
        XCTAssertTrue(off.contains("FILE\n\nASK"))
        XCTAssertFalse(off.contains("ASK\n\nFILE"))

        let on = AdvancedServerSettings(duplicateUserInstructionsAtTop: true).packagedContext(
            selectionRevision: 1,
            snippets: [
                .fileContents: "FILE",
                .userInstructions: "ASK",
            ]
        )
        XCTAssertTrue(on.contains("ASK\n\nFILE\n\nASK"))
    }

    func testPersistAndPackageConsumeLiveReadsDuplicateFlag() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: EmptyDuplicateInstructionsCatalog(),
            projectCatalog: store
        )
        let attribution = SettingsMutationAttribution(actorID: "test", actorLabel: "Test", channel: "test")
        let written = try await service.replaceAdvanced(
            .init(expectedRevision: 0, settings: .init(duplicateUserInstructionsAtTop: true)),
            attribution: attribution
        )
        XCTAssertTrue(written.settings.duplicateUserInstructionsAtTop)

        let recovered = try await service.advanced()
        XCTAssertTrue(recovered.settings.duplicateUserInstructionsAtTop)
        let packaged = recovered.settings.packagedContext(
            selectionRevision: 2,
            snippets: [
                .fileContents: "FILE",
                .userInstructions: "ASK",
            ]
        )
        XCTAssertTrue(packaged.contains("ASK\n\nFILE\n\nASK"))
    }
}

private struct EmptyDuplicateInstructionsCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [])
    }
}
