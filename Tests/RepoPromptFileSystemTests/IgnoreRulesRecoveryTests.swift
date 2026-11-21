@testable import RepoPromptFileSystem
import XCTest

final class IgnoreRulesRecoveryTests: XCTestCase {
    func testIncrementalScansDiscoverNewGitignoreUnlessIgnored() async throws {
        for scanInParallel in [false, true] {
            for gitignoreIsExcluded in [false, true] {
                let fm = FileManager.default
                let url = fm.temporaryDirectory.appendingPathComponent("IncrementalGitignore-\(UUID())")
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: url) }
                let manager = IgnoreRulesManager(
                    globalIgnoreProvider: { gitignoreIsExcluded ? ".gitignore\n" : "" },
                    ignorePolicyResolver: { _ in .nonGitRoot },
                    repositoryRootValidator: { _ in false }
                )
                let service = try await FileSystemService(path: url.path, ignoreRulesManager: manager)

                try "# repository rules\n".write(to: url.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
                try "fixture\n".write(to: url.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)

                let deltas = if scanInParallel {
                    try await service.scanFoldersInParallel([""]).deltas
                } else {
                    try await service.scanOneLevelAndDiff("")
                }
                let additions = deltas.compactMap { delta -> String? in
                    guard case let .fileAdded(path) = delta else { return nil }
                    return path
                }
                XCTAssertEqual(Set(additions), gitignoreIsExcluded ? ["kept.txt"] : [".gitignore", "kept.txt"])
            }
        }
    }

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
            policy: .gitRoot(repositoryRelativeRootPrefix: IgnoreRootPrefix(value: ""))
        )
        gitRoot.addCompiledLayer(
            GitignoreCompiler.compile(content: "!.git/\n!.jj/\n"),
            authority: .secondary
        )
        XCTAssertTrue(gitRoot.isIgnored(relativePath: ".git", isDirectory: true))
        XCTAssertFalse(gitRoot.isIgnored(relativePath: ".jj", isDirectory: true))

        let unmodifiedGitRoot = try IgnoreRules(
            policy: .gitRoot(repositoryRelativeRootPrefix: IgnoreRootPrefix(value: ""))
        )
        XCTAssertFalse(unmodifiedGitRoot.isIgnored(relativePath: ".jj", isDirectory: true))
    }
}
