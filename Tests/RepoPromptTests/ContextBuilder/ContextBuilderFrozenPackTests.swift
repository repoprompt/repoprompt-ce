@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class ContextBuilderFrozenPackTests: XCTestCase {
    func testCanonicalPackBytesAreStableAndReviewPromptIsAdviserOnly() throws {
        let prompt = ContextBuilderFrozenOraclePack.prompt(for: .review, prompt: "Review this change")
        XCTAssertTrue(prompt.contains("Review this change"))
        XCTAssertTrue(prompt.contains("Review the frozen package independently"))
        XCTAssertTrue(prompt.contains("Do not synthesize other Oracle answers"))

        let message = AIMessage(systemPrompt: "system", userMessage: prompt)
        let content = ContextBuilderFrozenOraclePack.render(message)
        let first = try OracleFrozenContextPack(mode: .review, content: content).canonicalData()
        let second = try OracleFrozenContextPack(mode: .review, content: content).canonicalData()
        XCTAssertEqual(first, second)
        XCTAssertEqual(try OracleFrozenContextPack.decodeCanonical(first).content, content)
    }

    func testNonReviewPromptIsUnchanged() {
        XCTAssertEqual(
            ContextBuilderFrozenOraclePack.prompt(for: .plan, prompt: "Make a plan"),
            "Make a plan"
        )
    }
}
