@testable import RepoPrompt
import XCTest

final class IgnoreRulesRecoveryTests: XCTestCase {
    func testCompilerDistinguishesAnchoredDirectoryAndNegationPrecedence() {
        let compiled = GitignoreCompiler.compile(content: """
        /build/
        logs/
        !logs/keep.log
        """)

        XCTAssertEqual(compiled.outcome(for: "build", isDirectory: true), .ignore)
        XCTAssertEqual(compiled.outcome(for: "build/output.txt", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "src/build", isDirectory: true), .noMatch)

        XCTAssertEqual(compiled.outcome(for: "logs", isDirectory: true), .ignore)
        XCTAssertEqual(compiled.outcome(for: "src/logs/debug.log", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "logs/keep.log", isDirectory: false), .allow)
        XCTAssertTrue(compiled.requiresTraversal(for: "logs"))
    }

    func testBroadPackageJSONNegationDoesNotForceTraversalIntoIgnoredDirectories() {
        let compiled = GitignoreCompiler.compile(content: """
        **/node_modules/
        **/*.json
        !**/package.json
        """)

        XCTAssertEqual(compiled.outcome(for: "node_modules", isDirectory: true), .ignore)
        XCTAssertEqual(compiled.outcome(for: "hub/node_modules", isDirectory: true), .ignore)
        XCTAssertEqual(compiled.outcome(for: "package.json", isDirectory: false), .allow)
        XCTAssertEqual(compiled.outcome(for: "hub/package.json", isDirectory: false), .allow)
        XCTAssertFalse(compiled.requiresTraversal(for: "node_modules"))
        XCTAssertFalse(compiled.requiresTraversal(for: "hub/node_modules"))
    }

    func testDoubleStarNegationWithConcreteParentForcesTraversal() {
        let compiled = GitignoreCompiler.compile(content: """
        **/logs/
        **/*.log
        !**/logs/keep.log
        """)

        XCTAssertEqual(compiled.outcome(for: "logs", isDirectory: true), .ignore)
        XCTAssertEqual(compiled.outcome(for: "hub/logs", isDirectory: true), .ignore)
        XCTAssertEqual(compiled.outcome(for: "logs/keep.log", isDirectory: false), .allow)
        XCTAssertEqual(compiled.outcome(for: "hub/logs/keep.log", isDirectory: false), .allow)
        XCTAssertTrue(compiled.requiresTraversal(for: "logs"))
        XCTAssertTrue(compiled.requiresTraversal(for: "hub/logs"))
    }
}
