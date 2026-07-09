@testable import RepoPromptApp
import XCTest

final class RepoSearchQueryRecoveryTests: XCTestCase {
    func testFactoryNormalizesBoundsSlashAndWildcardSupport() {
        let wildcardQuery = RepoSearchQueryFactory.make("  Sources/App/*.swift  ", maxLength: 50, supportsWildcards: true)
        XCTAssertEqual(wildcardQuery.raw, "Sources/App/*.swift")
        XCTAssertEqual(wildcardQuery.lowered, "sources/app/*.swift")
        XCTAssertTrue(wildcardQuery.hasSlash)
        XCTAssertTrue(wildcardQuery.isWildcard)

        let literalQuery = RepoSearchQueryFactory.make("  Sources/App/*.swift?  ", maxLength: 14, supportsWildcards: false)
        XCTAssertEqual(literalQuery.raw, "Sources/App/.")
        XCTAssertEqual(literalQuery.lowered, "sources/app/.")
        XCTAssertTrue(literalQuery.hasSlash)
        XCTAssertFalse(literalQuery.isWildcard)

        let emptyAfterWildcardStripping = RepoSearchQueryFactory.make("  *?  ", supportsWildcards: false)
        XCTAssertTrue(emptyAfterWildcardStripping.isEmpty)
        XCTAssertFalse(emptyAfterWildcardStripping.hasSlash)
    }
}
