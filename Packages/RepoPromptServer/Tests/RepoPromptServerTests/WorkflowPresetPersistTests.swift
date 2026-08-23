import Foundation
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class WorkflowPresetPersistTests: XCTestCase {
    func testMissingCatalogFallsBackToStandardCopyAndChatBuiltIns() throws {
        XCTAssertEqual(AdvancedServerSettings.default.resolvedCopyPreset().id, CopyPresetRecord.standardID)
        XCTAssertEqual(AdvancedServerSettings.default.resolvedChatPreset().id, ChatPresetRecord.chatID)
        XCTAssertEqual(AdvancedServerSettings.default.resolvedChatPreset().mode, .chat)

        let legacy = try JSONDecoder.serviceDecoder.decode(
            AdvancedServerSettings.self,
            from: Data(#"{"historyIdleThresholdMinutes":10}"#.utf8)
        )
        XCTAssertEqual(legacy.resolvedCopyPreset().name, "Standard")
        XCTAssertEqual(legacy.resolvedChatPreset().name, "Chat")

        let unknown = AdvancedServerSettings(selectedCopyPresetID: UUID(), selectedChatPresetID: UUID())
        XCTAssertEqual(unknown.resolvedCopyPreset().id, CopyPresetRecord.standardID)
        XCTAssertEqual(unknown.resolvedChatPreset().id, ChatPresetRecord.chatID)

        let diffFollowUp = AdvancedServerSettings(selectedCopyPresetID: CopyPresetRecord.diffFollowUpID)
        XCTAssertEqual(diffFollowUp.resolvedCopyPreset().includeFiles, false)
        let omitted = diffFollowUp.packagedContext(
            selectionRevision: 1,
            snippets: [.fileContents: "FILE", .userInstructions: "ASK"],
            purpose: .copy
        )
        XCTAssertFalse(omitted.contains("FILE"))
        XCTAssertTrue(omitted.contains("ASK"))
        let chatKeepsFiles = diffFollowUp.packagedContext(
            selectionRevision: 1,
            snippets: [.fileContents: "FILE"],
            purpose: .chat
        )
        XCTAssertTrue(chatKeepsFiles.contains("FILE"))
    }

    func testPersistUserPresetsAndOverridesLiveReadThroughResolve() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: EmptyWorkflowPresetCatalog(),
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
                            .init(id: customID, name: "Custom Copy", includeFiles: false),
                        ],
                        copyOverrides: [
                            .init(presetID: CopyPresetRecord.standardID, includeFiles: false),
                        ],
                        chatUserPresets: [
                            .init(id: customID, name: "Custom Chat", mode: .plan),
                        ]
                    ),
                    selectedCopyPresetID: customID,
                    selectedChatPresetID: customID
                )
            ),
            attribution: attribution
        )
        XCTAssertEqual(written.settings.resolvedCopyPreset().name, "Custom Copy")
        XCTAssertEqual(written.settings.resolvedChatPreset().mode, .plan)

        let recovered = try await service.advanced()
        XCTAssertEqual(recovered.settings.resolvedCopyPreset().id, customID)
        XCTAssertEqual(recovered.settings.resolvedChatPreset().name, "Custom Chat")
        let packaged = recovered.settings.packagedContext(
            selectionRevision: 3,
            snippets: [.fileContents: "FILE"],
            purpose: .copy
        )
        XCTAssertFalse(packaged.contains("FILE"))

        let overriddenStandard = recovered.settings.replacing(selectedCopyPresetID: CopyPresetRecord.standardID)
        XCTAssertEqual(overriddenStandard.resolvedCopyPreset().includeFiles, false)
    }
}

private struct EmptyWorkflowPresetCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [])
    }
}
