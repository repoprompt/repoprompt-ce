import Foundation
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class SavedPromptPersistTests: XCTestCase {
    func testMissingCatalogSeedsBuiltInsAndPlanCopyEmitsMetaPrompt() throws {
        let defaults = AdvancedServerSettings.default
        XCTAssertTrue(defaults.savedPrompts.isEmpty)
        XCTAssertTrue(defaults.includeSavedPromptsInClipboard)
        let resolved = defaults.resolvedSavedPrompts()
        XCTAssertEqual(resolved.map(\.id), SavedPromptRecord.builtIns.map(\.id))
        XCTAssertEqual(resolved.first { $0.id == SavedPromptRecord.architectID }?.title, "[Architect]")

        let legacy = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"historyIdleThresholdMinutes":10}"#.utf8)
        )
        XCTAssertTrue(legacy.savedPrompts.isEmpty)
        XCTAssertEqual(legacy.resolvedSavedPrompts().count, 5)

        let standard = defaults.packagedContext(selectionRevision: 1, snippets: [.fileContents: "FILE"], purpose: .copy)
        XCTAssertFalse(standard.contains("<meta prompt"))

        let plan = AdvancedServerSettings(selectedCopyPresetID: CopyPresetRecord.planID)
        let packaged = plan.packagedContext(selectionRevision: 1, snippets: [.fileContents: "FILE"], purpose: .copy)
        XCTAssertTrue(packaged.contains(#"<meta prompt 1 = "[Architect]">"#))
        XCTAssertTrue(packaged.contains("implementation-ready technical plan"))
        XCTAssertTrue(packaged.contains("</meta prompt 1>"))

        let clipboardOff = AdvancedServerSettings(
            selectedCopyPresetID: CopyPresetRecord.planID,
            includeSavedPromptsInClipboard: false
        )
        XCTAssertFalse(clipboardOff.packagedContext(selectionRevision: 1, snippets: [:], purpose: .copy).contains("<meta prompt"))

        let reviewChat = AdvancedServerSettings(selectedChatPresetID: ChatPresetRecord.reviewID)
        XCTAssertFalse(reviewChat.packagedContext(selectionRevision: 1, snippets: [:], purpose: .chat).contains("<meta prompt"))
        XCTAssertEqual(reviewChat.resolvedChatPreset().storedPromptIds, [SavedPromptRecord.reviewID])
    }

    func testPersistUserPromptAndEditedBuiltInLiveReadThroughPackage() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: EmptySavedPromptCatalog(),
            projectCatalog: store
        )
        let attribution = SettingsMutationAttribution(actorID: "test", actorLabel: "Test", channel: "test")
        let customID = UUID()
        let written = try await service.replaceAdvanced(
            .init(
                expectedRevision: 0,
                settings: .init(
                    workflowPresets: .init(
                        copyUserPresets: [
                            .init(id: customID, name: "Custom", includeMetaPrompts: true, storedPromptIds: [customID]),
                        ]
                    ),
                    selectedCopyPresetID: customID,
                    savedPrompts: [
                        .init(id: SavedPromptRecord.architectID, title: "[Architect]", content: "edited architect", isUserEdited: true),
                        .init(id: customID, title: "Custom Meta", content: "CUSTOM BODY"),
                    ]
                )
            ),
            attribution: attribution
        )
        let catalog = written.settings.resolvedSavedPrompts()
        XCTAssertEqual(catalog.first { $0.id == SavedPromptRecord.architectID }?.content, "edited architect")
        XCTAssertEqual(catalog.first { $0.id == customID }?.title, "Custom Meta")

        let recovered = try await service.advanced()
        let packaged = recovered.settings.packagedContext(selectionRevision: 3, snippets: [:], purpose: .copy)
        XCTAssertTrue(packaged.contains(#"<meta prompt 1 = "Custom Meta">"#))
        XCTAssertTrue(packaged.contains("CUSTOM BODY"))
        XCTAssertFalse(packaged.contains("edited architect"))
    }
}

private struct EmptySavedPromptCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [])
    }
}
