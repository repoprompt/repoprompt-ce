import Foundation
@testable import RepoPromptHeadlessRuntime
import RepoPromptAgentRuntimeCore
@testable import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
final class ClaudeSysPromptPackagingTests: XCTestCase {
    func testPersistDefaultIsNativeSystemPromptWithoutLegacyNullBuiltinFlag() throws {
        let missing = try JSONDecoder.serviceDecoder.decode(
            DirectClaudeAgentPermissions.self,
            from: Data("{}".utf8)
        )
        XCTAssertEqual(missing.promptDelivery, .nativeSystemPrompt)

        let invalid = try JSONDecoder.serviceDecoder.decode(
            DirectClaudeAgentPermissions.self,
            from: Data(#"{"promptDelivery":"not-a-desktop-mode"}"#.utf8)
        )
        XCTAssertEqual(invalid.promptDelivery, .nativeSystemPrompt)
        XCTAssertEqual(ClaudeAgentModePromptDelivery.liveRead(stored: nil), .nativeSystemPrompt)
        XCTAssertEqual(
            ClaudeAgentModePromptDelivery.resolved(rawValue: nil),
            .nativeSystemPrompt
        )
    }

    func testEachDesktopModePersistsAndLiveReadsThroughTypedStore() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: EmptyProviderCatalog(),
            projectCatalog: store
        )
        let portal = PortalDesktopSettingsService(store: store)

        let empty = await service.directAgentPermissions()
        XCTAssertEqual(empty.revision, 0)
        XCTAssertEqual(empty.settings.claude.promptDelivery, .nativeSystemPrompt)
        let defaultRuntime = try await portal.runtimeDefaults(for: .claudeCompatible)
        XCTAssertEqual(defaultRuntime.providerSettings["claude.promptDelivery"], "nativeSystemPrompt")
        let defaultComposer = try await composerPromptDelivery(portal)
        XCTAssertEqual(defaultComposer, "nativeSystemPrompt")

        var revision: Int64 = 0
        for mode in ClaudeAgentModePromptDelivery.allCases {
            let written = try await service.replaceDirectAgentPermissions(
                .init(
                    expectedRevision: revision,
                    settings: .init(claude: .init(promptDelivery: mode))
                ),
                attribution: Self.attribution
            )
            revision = written.revision
            XCTAssertEqual(written.settings.claude.promptDelivery, mode)

            let recovered = await service.directAgentPermissions()
            XCTAssertEqual(recovered.settings.claude.promptDelivery, mode)
            let runtime = try await portal.runtimeDefaults(for: .claudeCompatible)
            XCTAssertEqual(runtime.providerSettings["claude.promptDelivery"], mode.rawValue)
            let composer = try await composerPromptDelivery(portal)
            XCTAssertEqual(composer, mode.rawValue)
            XCTAssertEqual(
                ClaudeAgentModePromptDelivery.liveRead(stored: recovered.settings.claude.promptDelivery),
                mode
            )
        }
    }

    func testLaunchArgvAndPayloadMatchDesktopForEachMode() throws {
        let prompt = "Do the work"
        let instructions = "Agent Mode instructions"

        let native = try packaging(
            delivery: .nativeSystemPrompt,
            prompt: prompt,
            instructions: instructions,
            composerOverride: "userMessageXML"
        )
        XCTAssertEqual(systemPromptValue(native.arguments), instructions)
        XCTAssertEqual(native.userMessage, prompt)
        XCTAssertFalse(native.userMessage.contains(ClaudeAgentModePromptDelivery.instructionsTag))

        let keepNative = try packaging(
            delivery: .userMessageXML,
            prompt: prompt,
            instructions: instructions,
            composerOverride: "nativeSystemPrompt"
        )
        XCTAssertNil(systemPromptValue(keepNative.arguments))
        XCTAssertEqual(
            keepNative.userMessage,
            ClaudeAgentModePromptDelivery.decoratedUserMessage(prompt, instructions: instructions)
        )
        XCTAssertTrue(keepNative.userMessage.contains("<claude_code_instructions>"))

        let emptyNative = try packaging(
            delivery: .userMessageXMLWithEmptySystemPrompt,
            prompt: prompt,
            instructions: instructions,
            composerOverride: "nativeSystemPrompt"
        )
        XCTAssertEqual(systemPromptValue(emptyNative.arguments), "")
        XCTAssertEqual(
            emptyNative.userMessage,
            ClaudeAgentModePromptDelivery.decoratedUserMessage(prompt, instructions: instructions)
        )
    }

    private func packaging(
        delivery: ClaudeAgentModePromptDelivery,
        prompt: String,
        instructions: String,
        composerOverride: String
    ) throws -> (arguments: [String], userMessage: String) {
        let stored = ClaudeAgentModePromptDelivery.liveRead(stored: delivery)
        XCTAssertNotEqual(stored.rawValue, composerOverride)
        return try ClaudeNativeProviderRuntime.launchPackaging(
            .init(
                kind: .claudeCompatible,
                model: "sonnet",
                prompt: prompt,
                workingDirectory: "/workspace",
                runID: UUID(),
                policy: .init(providerSettings: [
                    "claude.promptDelivery": stored.rawValue,
                    "claude.agentModeInstructions": instructions,
                    "claude.permissionMode": "default"
                ])
            )
        )
    }

    private func systemPromptValue(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--system-prompt"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private func composerPromptDelivery(_ portal: PortalDesktopSettingsService) async throws -> String? {
        let profile = try await portal.composerCatalogProfile(for: .claudeCompatible)
        for control in profile.toolControls {
            if case let .singleChoice(id, _, _, selectedID, _, _, _, _, _) = control, id == "claude.promptDelivery" {
                return selectedID
            }
        }
        return nil
    }

    private static let attribution = SettingsMutationAttribution(
        actorID: "claude-sys-prompt-test",
        actorLabel: "Claude Sys Prompt Test",
        channel: "test"
    )
}

private struct EmptyProviderCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [])
    }
}
