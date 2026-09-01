import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class GrokBuildModelRoutingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
    }

    override func tearDown() {
        AgentACPModelRegistry.shared.test_reset(providerID: .grokBuild)
        super.tearDown()
    }

    func testModelIdentityRoundTripsToGrokBuildProvider() {
        let model = AIModel.grokBuildCustom(name: "grok-4.6-high")

        XCTAssertEqual(model.rawValue, "grokbuild_custom_grok-4.6-high")
        XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)
        XCTAssertEqual(model.modelName, "grok-4.6-high")
        XCTAssertEqual(model.providerType, .grokBuild)
        XCTAssertEqual(AIProviderType.displayName(for: model.providerType), "Grok Build")
        XCTAssertEqual(ObjectIdentifier(model.provider), ObjectIdentifier(GrokBuildCLIProvider.self))
    }

    func testCatalogUsesDefaultAndDiscoveredGrokBuildModels() {
        XCTAssertEqual(
            AIModel.modelsForProvider(.grokBuild),
            [.grokBuildCustom(name: AgentModel.defaultModel.rawValue)]
        )

        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: "grok-4.6",
                        displayName: "Grok 4.6",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: false
                    )
                ],
                currentModelRaw: "grok-4.6"
            ),
            for: .grokBuild
        )

        let models = AIModel.modelsForProvider(.grokBuild)
        XCTAssertEqual(Set(models), [
            .grokBuildCustom(name: AgentModel.defaultModel.rawValue),
            .grokBuildCustom(name: "grok-4.6")
        ])
        XCTAssertEqual(
            models.first { $0.modelName == "grok-4.6" }?.displayName,
            "Grok 4.6"
        )
    }

    func testFactoryCreatesGrokBuildProviderWithoutStoredAPIKey() async throws {
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )

        let provider = try await AIProviderFactory.createProvider(
            for: .grokBuild,
            keyManager: keyManager
        )
        XCTAssertTrue(provider is GrokBuildCLIProvider)
        await provider.dispose()
    }

    func testNonAgentAdapterDisablesRepoPromptToolsAndPreservesModel() {
        let config = GrokBuildCLIProvider.test_makeHeadlessConfig(modelName: "grok-4.6")
        let message = GrokBuildCLIProvider.test_makeAgentMessage(
            from: AIMessage(systemPrompt: "", userMessage: "Hello")
        )

        XCTAssertEqual(config.modelString, "grok-4.6")
        XCTAssertFalse(config.includeRepoPromptMCPServer)
        XCTAssertFalse(config.alwaysApproveTools)
        XCTAssertTrue(message.systemPrompt.contains("Do not use any tools"))
    }

    func testOneShotTextPromptKeepsPromptFileArguments() throws {
        let arguments = try GrokBuildOneShotHeadlessAgentProvider.test_promptArguments(
            for: AgentMessage(systemPrompt: "system", userMessage: "text"),
            promptFilePath: "/tmp/prompt.txt"
        )

        XCTAssertEqual(Array(arguments.prefix(2)), ["--prompt-file", "/tmp/prompt.txt"])
        XCTAssertFalse(arguments.contains("--prompt-json"))
    }

    func testOneShotImagePromptUsesACPShapedPromptJSON() throws {
        let message = AgentMessage(
            systemPrompt: "system",
            userMessage: "inspect",
            transientImages: [
                .init(bytes: Data([1, 2, 3]), mediaType: .png, title: "Diagram")
            ]
        )
        let arguments = try GrokBuildOneShotHeadlessAgentProvider.test_promptArguments(
            for: message,
            promptFilePath: "/tmp/prompt.txt"
        )
        let jsonIndex = try XCTUnwrap(arguments.firstIndex(of: "--prompt-json"))
        let json = arguments[jsonIndex + 1]
        let blocks = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )

        XCTAssertFalse(arguments.contains("--prompt-file"))
        XCTAssertEqual(blocks.first?["type"] as? String, "text")
        XCTAssertEqual(blocks.first?["text"] as? String, "system\n\ninspect")
        XCTAssertEqual(blocks.last?["type"] as? String, "image")
        XCTAssertEqual(blocks.last?["mimeType"] as? String, "image/png")
        XCTAssertEqual(blocks.last?["data"] as? String, "AQID")
    }

    func testOneShotImagePromptRejectsUnsafeArgvSize() {
        let message = AgentMessage(
            userMessage: "inspect",
            transientImages: [
                .init(
                    bytes: Data(count: GrokBuildOneShotHeadlessAgentProvider.test_promptJSONArgumentByteLimit),
                    mediaType: .png,
                    title: nil
                )
            ]
        )

        XCTAssertThrowsError(try GrokBuildOneShotHeadlessAgentProvider.test_promptArguments(
            for: message,
            promptFilePath: "/tmp/prompt.txt"
        )) { error in
            guard case let AIProviderError.invalidConfiguration(detail) = error else {
                return XCTFail("Expected actionable provider configuration error, got \(error)")
            }
            XCTAssertTrue(detail.contains("safe macOS command-line launch"))
            XCTAssertTrue(detail.contains("Reduce the number or size of attached images"))
        }
    }

    func testNonAgentAdapterMapsNonSuccessfulStopsToIncomplete() {
        let incompleteStopReasons = [
            "max_tokens",
            "max_turn_requests",
            "cancelled",
            "refusal",
            "future_reason"
        ]
        for stopReason in incompleteStopReasons {
            let normalized = GrokBuildCLIProvider.test_normalizedTerminalResult(
                AIStreamResult(
                    type: "message_stop",
                    text: nil,
                    promptTokens: 11,
                    completionTokens: 7,
                    providerSessionID: "session-1",
                    stopReason: stopReason,
                    contextUsedTokens: 13
                )
            )

            XCTAssertEqual(normalized.type, AIStreamResult.incompleteType, stopReason)
            XCTAssertEqual(normalized.stopReason, stopReason, stopReason)
            XCTAssertEqual(normalized.promptTokens, 11, stopReason)
            XCTAssertEqual(normalized.completionTokens, 7, stopReason)
            XCTAssertEqual(normalized.providerSessionID, "session-1", stopReason)
            XCTAssertEqual(normalized.contextUsedTokens, 13, stopReason)
        }
    }

    func testNonAgentAdapterKeepsSuccessfulStopsCompleted() {
        let successfulStopReasons = [
            "end_turn",
            "stop",
            "stop_sequence",
            "completed",
            "complete"
        ]
        for stopReason in successfulStopReasons {
            let normalized = GrokBuildCLIProvider.test_normalizedTerminalResult(
                AIStreamResult(
                    type: "message_stop",
                    text: nil,
                    stopReason: stopReason
                )
            )

            XCTAssertEqual(normalized.type, "message_stop", stopReason)
            XCTAssertEqual(normalized.stopReason, stopReason, stopReason)
        }

        let missingReason = GrokBuildCLIProvider.test_normalizedTerminalResult(
            AIStreamResult(type: "message_stop", text: nil)
        )
        XCTAssertEqual(missingReason.type, "message_stop")
    }

    func testNonAgentCompletionPrefersAuthoritativeFinalContent() {
        XCTAssertEqual(
            GrokBuildCLIProvider.test_resolvedCompletionText(
                streamedParts: ["draft ", "answer"],
                finalContent: "final answer"
            ),
            "final answer"
        )
        XCTAssertEqual(
            GrokBuildCLIProvider.test_resolvedCompletionText(
                streamedParts: ["streamed ", "answer"],
                finalContent: nil
            ),
            "streamed answer"
        )
    }

    @MainActor
    func testDropdownDisplaysGrokBuildCatalogName() {
        let model = AIModel.grokBuildCustom(name: "grok-4.6")
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: model.modelName,
                        displayName: "Grok 4.6",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: false
                    )
                ],
                currentModelRaw: model.modelName
            ),
            for: .grokBuild
        )

        XCTAssertEqual(
            AIModelDropdown.displayName(
                forRawValue: model.rawValue,
                destinationID: "planningModel",
                availableModels: [model],
                customOpenRouterModels: []
            ),
            "Grok 4.6"
        )
    }
}
