import Foundation
import RepoPromptAIContracts
import XCTest

final class AIProviderErrorTests: XCTestCase {
    func testFixedAndDetailedDescriptionsRemainStable() {
        XCTAssertEqual(AIProviderError.missingAPIKey.localizedDescription, "Missing API key.")
        XCTAssertEqual(AIProviderError.invalidModel.localizedDescription, "Invalid model.")
        XCTAssertEqual(AIProviderError.invalidConfiguration(detail: "fixture detail").localizedDescription, "fixture detail")
        XCTAssertEqual(AIProviderError.invalidResponse(detail: "bad response").localizedDescription, "bad response")
    }

    func testUnderlyingErrorsPreserveTheirLocalizedDescription() {
        let source = NSError(domain: "fixture", code: 9, userInfo: [NSLocalizedDescriptionKey: "underlying failure"])
        XCTAssertEqual(AIProviderError.apiError(source: source).localizedDescription, "underlying failure")
        XCTAssertEqual(AIProviderError.unknown(source: source).localizedDescription, "underlying failure")
        if case let .apiError(actual) = AIProviderError.apiError(source: source) {
            XCTAssertEqual((actual as NSError?)?.domain, "fixture")
        } else {
            XCTFail("Expected original associated error")
        }
    }
}
