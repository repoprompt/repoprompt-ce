import Foundation
@testable import RepoPromptFileSystem
import XCTest

final class IgnoreMatcherContractTests: XCTestCase {
    func testSnapshotPreservesMandatoryFloorAndLayerPrecedence() {
        let rules = IgnoreRules(policy: .gitRoot(repositoryRelativeRootPrefix: IgnoreRootPrefix(value: "")))
        rules.addCompiledLayer(GitignoreCompiler.compile(content: "private/\n"), authority: .mandatoryGit)
        rules.addCompiledLayer(GitignoreCompiler.compile(content: "!private/**\n*.tmp\n!keep.tmp\n"), authority: .secondary)
        let matcher: any IgnoreMatcher = rules.snapshot()

        XCTAssertTrue(matcher.isIgnored(relativePath: "private/secret.txt", isDirectory: false))
        XCTAssertTrue(matcher.isIgnored(relativePath: "scratch.tmp", isDirectory: false))
        XCTAssertFalse(matcher.isIgnored(relativePath: "keep.tmp", isDirectory: false))
        XCTAssertTrue(matcher.isIgnored(relativePath: ".git/config", isDirectory: false))
    }

    func testSnapshotDoesNotObserveLaterLayerMutation() {
        let rules = IgnoreRules(policy: .nonGitRoot)
        let matcher: any IgnoreMatcher = rules.snapshot()
        rules.addCompiledLayer(GitignoreCompiler.compile(content: "later.txt\n"), authority: .secondary)

        XCTAssertFalse(matcher.isIgnored(relativePath: "later.txt", isDirectory: false))
        XCTAssertTrue(rules.isIgnored(relativePath: "later.txt", isDirectory: false))
    }

    func testInjectedDefaultsAreReadAgainOnRebuild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = LockedDefaults("first.txt\n")
        let manager = IgnoreRulesManager(
            globalIgnoreProvider: { defaults.snapshot() },
            ignorePolicyResolver: { _ in .nonGitRoot },
            repositoryRootValidator: { _ in false }
        )
        let first = try await manager.resolvedIgnoreRules(for: root.path, policy: .nonGitRoot)
        defaults.install("second.txt\n")
        let second = try await manager.resolvedIgnoreRules(for: root.path, policy: .nonGitRoot)

        XCTAssertTrue(first.rules.snapshot().isIgnored(relativePath: "first.txt", isDirectory: false))
        XCTAssertFalse(second.rules.snapshot().isIgnored(relativePath: "first.txt", isDirectory: false))
        XCTAssertTrue(second.rules.snapshot().isIgnored(relativePath: "second.txt", isDirectory: false))
        XCTAssertNotEqual(first.globalIgnoreDefaultsDigest, second.globalIgnoreDefaultsDigest)
    }
}

private final class LockedDefaults: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String) {
        self.value = value
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func install(_ value: String) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}
