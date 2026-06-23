@testable import RepoPrompt
import XCTest

final class ZAIProviderEndpointTests: XCTestCase {
    func testGLM52ModelCatalogEntry() {
        XCTAssertEqual(AIModel.zaiGLM52.rawValue, "glm-5.2")
        XCTAssertEqual(AIModel.zaiGLM52.displayName, "Z.AI GLM-5.2")
        XCTAssertEqual(AIModel.fromModelName("glm-5.2"), .zaiGLM52)

        let zAIModels = AIModel.modelsForProvider(.zAI)
        XCTAssertTrue(zAIModels.contains(.zaiGLM52))
        XCTAssertTrue(zAIModels.contains(.zaiGLM5))
    }

    func testDefaultProviderUsesGeneralZAIEndpoint() {
        let provider = ZAIProvider(apiKey: "test-key")

        XCTAssertEqual(provider.endpoint, .generalAPI)
        XCTAssertEqual(provider.endpoint.baseURL.absoluteString, "https://api.z.ai/api/paas")
    }

    func testCodingPlanProviderUsesDedicatedCodingEndpoint() {
        let provider = ZAIProvider(apiKey: "test-key", endpoint: .codingPlan)

        XCTAssertEqual(provider.endpoint, .codingPlan)
        XCTAssertEqual(provider.endpoint.baseURL.absoluteString, "https://api.z.ai/api/coding/paas")
    }
}
