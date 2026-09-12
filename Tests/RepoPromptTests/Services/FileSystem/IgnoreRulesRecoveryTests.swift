@testable import RepoPromptApp
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

    /// `.jj` is a low-priority secondary built-in, so a later secondary layer can still re-admit it
    /// for traversal and content. This covers filtering only; it implies nothing about Jujutsu
    /// discovery or repository support.
    func testJJSecondaryDefaultIgnoreCanBeOverridden() throws {
        let base = IgnoreRules(policy: .nonGitRoot)
        XCTAssertTrue(base.isIgnored(relativePath: ".jj", isDirectory: true))
        XCTAssertTrue(base.isIgnored(relativePath: ".jj/repo/store", isDirectory: false))
        XCTAssertTrue(base.snapshot().isIgnored(relativePath: ".jj", isDirectory: true))
        XCTAssertFalse(base.requiresTraversal(for: ".jj"))
        XCTAssertFalse(base.isIgnored(relativePath: "src/App.ts", isDirectory: false))

        let overridden = IgnoreRules(policy: .nonGitRoot)
        overridden.addCompiledLayer(
            GitignoreCompiler.compile(content: """
            !.jj/
            !.jj/**
            """),
            authority: .secondary
        )
        XCTAssertFalse(overridden.isIgnored(relativePath: ".jj", isDirectory: true))
        XCTAssertFalse(overridden.isIgnored(relativePath: ".jj/repo/store", isDirectory: false))
        XCTAssertTrue(overridden.requiresTraversal(for: ".jj"))
        let snapshot = overridden.snapshot()
        XCTAssertFalse(snapshot.isIgnored(relativePath: ".jj", isDirectory: true))
        XCTAssertFalse(snapshot.isIgnored(relativePath: ".jj/repo/store", isDirectory: false))
        XCTAssertTrue(snapshot.requiresTraversal(for: ".jj"))

        // Git's mandatory floor is unaffected by the same secondary override.
        let gitRoot = try IgnoreRules(
            policy: .gitRoot(repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix(""))
        )
        gitRoot.addCompiledLayer(
            GitignoreCompiler.compile(content: "!.git/\n!.jj/\n"),
            authority: .secondary
        )
        XCTAssertTrue(gitRoot.isIgnored(relativePath: ".git", isDirectory: true))
        XCTAssertFalse(gitRoot.isIgnored(relativePath: ".jj", isDirectory: true))
    }
}
