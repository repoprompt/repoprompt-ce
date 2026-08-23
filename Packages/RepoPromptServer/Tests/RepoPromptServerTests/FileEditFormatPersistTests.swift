import Foundation
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class FileEditFormatPersistTests: XCTestCase {
    func testMissingAndInvalidRawResolveToDiffAndNonePassesThrough() throws {
        XCTAssertEqual(AdvancedServerSettings.default.fileEditFormat, "Diff")
        XCTAssertEqual(AdvancedServerSettings.default.resolvedFileEditFormat(), .diff)
        XCTAssertEqual(
            AdvancedServerSettings.default.packagedContextPreamble(selectionRevision: 3),
            [
                "# RepoPrompt Context",
                "selection-revision: 3",
                "file-edit-format: Diff",
            ]
        )

        let legacy = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"historyIdleThresholdMinutes":10}"#.utf8)
        )
        XCTAssertEqual(legacy.fileEditFormat, "Diff")
        XCTAssertEqual(legacy.resolvedFileEditFormat(), .diff)
        XCTAssertEqual(legacy.historyIdleThresholdMinutes, 10)

        let invalid = AdvancedServerSettings(fileEditFormat: "diff")
        XCTAssertEqual(invalid.fileEditFormat, "diff")
        XCTAssertEqual(invalid.resolvedFileEditFormat(), .diff)

        let none = AdvancedServerSettings(fileEditFormat: "None")
        XCTAssertEqual(none.resolvedFileEditFormat(), .none)
        XCTAssertEqual(none.resolvedFileEditFormat(modelCapableOfDiff: false), .none)
        XCTAssertEqual(
            AdvancedServerSettings(fileEditFormat: "Diff").resolvedFileEditFormat(modelCapableOfDiff: false),
            .whole
        )
        XCTAssertEqual(
            AdvancedServerSettings(fileEditFormat: "Whole").packagedContextPreamble(selectionRevision: 1).last,
            "file-edit-format: Whole"
        )
    }

    func testPersistAndPackagePreambleLiveReadStoredFormat() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: EmptyFileEditFormatCatalog(),
            projectCatalog: store
        )
        let attribution = SettingsMutationAttribution(actorID: "test", actorLabel: "Test", channel: "test")
        let written = try await service.replaceAdvanced(
            .init(expectedRevision: 0, settings: .init(fileEditFormat: "Whole")),
            attribution: attribution
        )
        XCTAssertEqual(written.settings.fileEditFormat, "Whole")
        XCTAssertEqual(written.settings.resolvedFileEditFormat(), .whole)
        XCTAssertEqual(
            written.settings.packagedContextPreamble(selectionRevision: 7).last,
            "file-edit-format: Whole"
        )

        let recovered = try await service.advanced()
        XCTAssertEqual(recovered.settings.resolvedFileEditFormat(), .whole)
        XCTAssertEqual(
            recovered.settings.packagedContextPreamble(selectionRevision: 7),
            written.settings.packagedContextPreamble(selectionRevision: 7)
        )
    }
}

private struct EmptyFileEditFormatCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [])
    }
}
