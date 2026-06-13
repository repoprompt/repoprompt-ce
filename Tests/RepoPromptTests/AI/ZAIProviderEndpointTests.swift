@testable import RepoPrompt
import XCTest

final class ZAIProviderEndpointTests: XCTestCase {
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
