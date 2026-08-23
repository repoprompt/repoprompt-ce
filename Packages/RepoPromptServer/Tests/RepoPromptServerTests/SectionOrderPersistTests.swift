import Foundation
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class SectionOrderPersistTests: XCTestCase {
    func testMissingAndInvalidRawFallBackToDesktopDefaultOrder() throws {
        XCTAssertEqual(AdvancedServerSettings.default.promptSectionsOrder, "")
        XCTAssertEqual(AdvancedServerSettings.default.resolvedPromptSectionOrder(), PromptSection.defaultOrder)

        let legacy = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"historyIdleThresholdMinutes":10}"#.utf8)
        )
        XCTAssertEqual(legacy.promptSectionsOrder, "")
        XCTAssertEqual(legacy.resolvedPromptSectionOrder(), PromptSection.defaultOrder)

        XCTAssertEqual(AdvancedServerSettings(promptSectionsOrder: "[]").resolvedPromptSectionOrder(), PromptSection.defaultOrder)
        XCTAssertEqual(AdvancedServerSettings(promptSectionsOrder: #"["fileContents"]"#).resolvedPromptSectionOrder(), PromptSection.defaultOrder)

        let custom = PromptSection.encode([.gitDiff, .fileContents, .fileMap, .metaPrompts, .userInstructions])
        let packaged = AdvancedServerSettings(promptSectionsOrder: custom).packagedContext(
            selectionRevision: 4,
            snippets: [
                .fileContents: "FILE",
                .gitDiff: "DIFF",
            ]
        )
        XCTAssertTrue(packaged.contains("DIFF\n\nFILE"))
        XCTAssertFalse(packaged.contains("FILE\n\nDIFF"))
        XCTAssertTrue(packaged.hasPrefix("# RepoPrompt Context\n\nselection-revision: 4\n\nfile-edit-format: Diff"))
    }

    func testPersistAndPackageConsumeLiveReadsStoredOrder() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: EmptySectionOrderCatalog(),
            projectCatalog: store
        )
        let attribution = SettingsMutationAttribution(actorID: "test", actorLabel: "Test", channel: "test")
        let order = PromptSection.encode([.userInstructions, .fileContents, .gitDiff, .fileMap, .metaPrompts])
        let written = try await service.replaceAdvanced(
            .init(expectedRevision: 0, settings: .init(promptSectionsOrder: order)),
            attribution: attribution
        )
        XCTAssertEqual(written.settings.resolvedPromptSectionOrder().map(\.rawValue), [
            "userInstructions", "fileContents", "gitDiff", "fileMap", "metaPrompts",
        ])

        let recovered = try await service.advanced()
        let packaged = recovered.settings.packagedContext(
            selectionRevision: 1,
            snippets: [
                .userInstructions: "ASK",
                .fileContents: "FILE",
            ]
        )
        XCTAssertTrue(packaged.contains("ASK\n\nFILE"))
        XCTAssertFalse(packaged.contains("FILE\n\nASK"))
    }
}

private struct EmptySectionOrderCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [])
    }
}
