import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class GitBlobIdentityServiceTests: XCTestCase {
    func testNestedRepositoryMarkersUseValidatedLeafBytesAndRetainOwnRootBlobEligibility() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let contents = "struct BoundaryOwned {}\n"
        let repository = try fixture.makeRepository(
            named: "outer",
            files: [
                "Nested/Sources/Feature.swift": contents,
                "Nested/Sources/Link.swift": contents,
                "GitFileBoundary/Sources/Feature.swift": contents
            ]
        )
        let nested = repository.appendingPathComponent("Nested", isDirectory: true)
        try fixture.initializeRepository(at: nested)
        try fixture.stage("Sources/Feature.swift", at: nested)
        try fixture.stage("Sources/Link.swift", at: nested)
        try fixture.commit("Nested repository", at: nested)
        let nestedLink = nested.appendingPathComponent("Sources/Link.swift")
        try FileManager.default.removeItem(at: nestedLink)
        try FileManager.default.createSymbolicLink(
            at: nestedLink,
            withDestinationURL: URL(fileURLWithPath: "Feature.swift")
        )
        try fixture.stage("Sources/Link.swift", at: nested)
        try fixture.commit("Nested symlink", at: nested)

        let pointerWorktree = repository.appendingPathComponent("GitFileBoundary", isDirectory: true)
        let pointerGitDirectory = fixture.sandbox.appendingPathComponent(
            "GitFileBoundary.git",
            isDirectory: true
        )
        try fixture.initializeRepository(
            at: pointerWorktree,
            separateGitDirectory: pointerGitDirectory
        )
        try fixture.stage("Sources/Feature.swift", at: pointerWorktree)
        try fixture.commit("Pointer repository", at: pointerWorktree)

        let service = GitBlobIdentityService()
        for root in [nested, pointerWorktree] {
            let batch = await service.classify(
                workspaceRoot: root,
                relativePaths: ["Sources/Feature.swift"]
            )
            let expectedOID = try fixture.headBlobOID(for: "Sources/Feature.swift", at: root)
            guard case let .oidEligible(oid)? = batch.classifications.first?.outcome else {
                return XCTFail("Nested repository root should retain its own Git blob eligibility")
            }
            XCTAssertEqual(oid.lowercaseHex, expectedOID)
        }

        for root in [nested, pointerWorktree] {
            try fixture.write(
                "Sources/*.swift filter=nested-owned\n",
                to: ".gitattributes",
                at: root
            )
            try fixture.stage(".gitattributes", at: root)
            try fixture.commit("Nested attributes", at: root)
        }

        let relativePaths = [
            "Nested/Sources/Feature.swift",
            "GitFileBoundary/Sources/Feature.swift"
        ]
        let outer = await service.classify(
            workspaceRoot: repository,
            relativePaths: relativePaths
        )

        XCTAssertNil(outer.failure)
        XCTAssertFalse(outer.retriedAfterInstability)
        XCTAssertEqual(
            outer.classifications.map(\.outcome),
            [
                .requiresValidatedWorktreeBytes(.nestedRepository),
                .requiresValidatedWorktreeBytes(.nestedRepository)
            ]
        )

        let markerURLs = [
            nested.appendingPathComponent(".git"),
            pointerWorktree.appendingPathComponent(".git")
        ]
        for (index, classification) in outer.classifications.enumerated() {
            let sourceURL = repository.appendingPathComponent(relativePaths[index])
            let sourceFingerprint = try XCTUnwrap(Self.fingerprint(at: sourceURL))
            let markerFingerprint = try XCTUnwrap(Self.fingerprint(at: markerURLs[index]))
            XCTAssertEqual(classification.validationTokens.preWorktree, sourceFingerprint)
            XCTAssertEqual(classification.validationTokens.postWorktree, sourceFingerprint)
            XCTAssertNotEqual(classification.validationTokens.postWorktree, markerFingerprint)
            XCTAssertEqual(classification.attributes, .unspecified)
            XCTAssertTrue(classification.indexEntries.contains { entry in
                entry.stage == 0 &&
                    entry.isRegularFile &&
                    entry.oid == (try? fixture.headBlobOID(
                        for: relativePaths[index],
                        at: repository
                    ))
            })
        }

        let terminalBatch = await service.classify(
            workspaceRoot: repository,
            relativePaths: ["Nested/Sources/Link.swift"]
        )
        let terminal = try XCTUnwrap(terminalBatch.classifications.first)
        XCTAssertNil(terminalBatch.failure)
        XCTAssertEqual(terminal.outcome, .securityExcluded(.symlinkLeaf))
        XCTAssertEqual(terminal.attributes, .unspecified)
        XCTAssertTrue(terminal.indexEntries.contains { $0.stage == 0 && $0.isRegularFile })
    }

    private static func fingerprint(at url: URL) -> GitBlobLStatFingerprint? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return nil }
        return GitBlobLStatFingerprint(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            mode: UInt16(value.st_mode),
            size: Int64(value.st_size),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changeSeconds: Int64(value.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }
}
