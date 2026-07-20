@testable import RepoPromptApp
@testable import RepoPromptCodeMapCore
import XCTest

final class SyntaxHighlightingQueryTests: XCTestCase {
    func testEveryRegisteredHighlightingQueryCompilesAgainstItsGrammar() throws {
        let syntaxManager = SyntaxManager()
        let queries = syntaxManager.optimizedQueries

        XCTAssertEqual(Set(queries.keys), Set(LanguageType.allCases))

        for languageType in LanguageType.allCases.sorted() {
            XCTAssertNoThrow(
                try syntaxManager.compileHighlightQuery(for: languageType),
                languageType.rawValue
            )
        }
    }
}
