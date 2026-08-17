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
