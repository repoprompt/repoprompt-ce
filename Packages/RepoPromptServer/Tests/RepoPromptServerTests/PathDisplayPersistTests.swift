import Foundation
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class PathDisplayPersistTests: XCTestCase {
    func testMissingPathDisplayIsFullAndDatetimeOffWrapsWhenEnabled() throws {
        XCTAssertEqual(AdvancedServerSettings.default.filePathDisplayOption, "Full")
        XCTAssertEqual(AdvancedServerSettings.default.resolvedFilePathDisplay(), .full)
        XCTAssertFalse(AdvancedServerSettings.default.includeDatetimeInUserInstructions)
        XCTAssertEqual(
            AdvancedServerSettings.default.displayedFilePath(logicalPath: "src/a.swift", fullPath: "/work/src/a.swift"),
            "/work/src/a.swift"
        )

        let legacy = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"historyIdleThresholdMinutes":10}"#.utf8)
        )
        XCTAssertEqual(legacy.resolvedFilePathDisplay(), .full)
        XCTAssertFalse(legacy.includeDatetimeInUserInstructions)

        let invalid = AdvancedServerSettings(filePathDisplayOption: "relative")
        XCTAssertEqual(invalid.resolvedFilePathDisplay(), .full)
        let relative = AdvancedServerSettings(filePathDisplayOption: "Relative")
        XCTAssertEqual(
            relative.displayedFilePath(logicalPath: "src/a.swift", fullPath: "/work/src/a.swift"),
            "src/a.swift"
        )
        XCTAssertEqual(
            AdvancedServerSettings.FilePathDisplay.joinedFullPath(rootPath: "/work/", logicalPath: "src/a.swift"),
            "/work/src/a.swift"
        )

        let now = Date(timeIntervalSince1970: 1_776_700_800)
        let dated = AdvancedServerSettings(includeDatetimeInUserInstructions: true).packagedContext(
            selectionRevision: 1,
            snippets: [.userInstructions: "ASK"],
            now: now
        )
        XCTAssertTrue(dated.contains(#"<user_instructions date="#))
        XCTAssertTrue(dated.contains("ASK"))
        XCTAssertTrue(dated.contains("</user_instructions>"))
        let off = AdvancedServerSettings.default.packagedContext(
            selectionRevision: 1,
            snippets: [.userInstructions: "ASK"],
            now: now
        )
        XCTAssertFalse(off.contains("date="))
        XCTAssertTrue(off.contains("ASK"))
    }

    func testPersistPathDisplayAndDatetimeLiveReadThroughPackage() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: EmptyPathDisplayCatalog(),
            projectCatalog: store
        )
        let attribution = SettingsMutationAttribution(actorID: "test", actorLabel: "Test", channel: "test")
        let written = try await service.replaceAdvanced(
            .init(
                expectedRevision: 0,
                settings: .init(
                    filePathDisplayOption: "Relative",
                    includeDatetimeInUserInstructions: true
                )
            ),
            attribution: attribution
        )
        XCTAssertEqual(written.settings.resolvedFilePathDisplay(), .relative)
        XCTAssertTrue(written.settings.includeDatetimeInUserInstructions)

        let recovered = try await service.advanced()
        XCTAssertEqual(recovered.settings.resolvedFilePathDisplay(), .relative)
        XCTAssertEqual(
            recovered.settings.displayedFilePath(logicalPath: "src/a.swift", fullPath: "/work/src/a.swift"),
            "src/a.swift"
        )
        let now = Date(timeIntervalSince1970: 1_776_700_800)
        let packaged = recovered.settings.packagedContext(
            selectionRevision: 4,
            snippets: [.userInstructions: "ASK"],
            now: now
        )
        XCTAssertTrue(packaged.contains("date="))
        XCTAssertTrue(packaged.contains("ASK"))
    }
}

private struct EmptyPathDisplayCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [])
    }
}
