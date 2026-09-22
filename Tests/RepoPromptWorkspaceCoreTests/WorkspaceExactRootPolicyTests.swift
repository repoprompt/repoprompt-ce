import Foundation
@testable import RepoPromptWorkspaceCore
import XCTest

final class WorkspaceExactRootPolicyTests: XCTestCase {
    func testRootSetNormalizesSpellingAndPreservesDeterministicCase() {
        let key = WorkspaceRootSetKey(paths: [
            "/tmp/z/",
            "  /tmp/A/../B  ",
            "/tmp/b",
            "/tmp/C/./",
            "\n\t"
        ])

        let reversed = WorkspaceRootSetKey(paths: [
            "/tmp/C/./",
            "/tmp/b",
            "/tmp/A/../B",
            "/tmp/z/"
        ])

        XCTAssertEqual(key.normalizedPaths, ["/tmp/B", "/tmp/C", "/tmp/z"])
        XCTAssertEqual(reversed.normalizedPaths, key.normalizedPaths)
    }

    func testRootSetExpandsTildeBeforeStandardizing() {
        let expected = URL(
            fileURLWithPath: ("~/Projects/../Repo" as NSString).expandingTildeInPath
        ).standardizedFileURL.path

        XCTAssertEqual(
            WorkspaceRootSetKey(paths: ["  ~/Projects/../Repo  "]).normalizedPaths,
            [expected]
        )
    }

    func testRootSetEqualityAndHashIgnoreCaseWhileKeepingCanonicalSpelling() {
        let uppercase = WorkspaceRootSetKey(paths: ["/tmp/Repo", "/tmp/Other"])
        let lowercase = WorkspaceRootSetKey(paths: ["/TMP/repo", "/TMP/other"])

        XCTAssertEqual(uppercase, lowercase)
        XCTAssertEqual(Set([uppercase, lowercase]).count, 1)
        XCTAssertEqual(uppercase.normalizedPaths, ["/tmp/Other", "/tmp/Repo"])
        XCTAssertEqual(lowercase.normalizedPaths, ["/TMP/other", "/TMP/repo"])
    }

    func testContainsExactRootMatchesOneRootRatherThanContainmentOrWholeSetEquality() {
        let rawWorkspaceRoots = ["/tmp/One", "/tmp/Two"]

        XCTAssertTrue(
            WorkspaceExactRootPath.contains(
                WorkspaceRootSetKey(paths: ["/TMP/two/"]),
                in: rawWorkspaceRoots
            )
        )
        XCTAssertFalse(
            WorkspaceExactRootPath.contains(
                WorkspaceRootSetKey(paths: ["/tmp/Two/Child"]),
                in: rawWorkspaceRoots
            )
        )
        XCTAssertFalse(
            WorkspaceExactRootPath.contains(
                WorkspaceRootSetKey(paths: ["/tmp/One", "/tmp/Two"]),
                in: rawWorkspaceRoots
            )
        )
        XCTAssertFalse(
            WorkspaceExactRootPath.contains(
                WorkspaceRootSetKey(paths: []),
                in: rawWorkspaceRoots
            )
        )
    }

    func testCanonicalComparisonPathIsNotSilentlyNormalizedAtRuntimeBoundary() {
        let rawPaths = ["  /tmp/Parent/../Root/  "]

        XCTAssertTrue(
            WorkspaceExactRootPath.contains(
                canonicalComparisonPath: "/tmp/root",
                in: rawPaths
            )
        )
        XCTAssertFalse(
            WorkspaceExactRootPath.contains(
                canonicalComparisonPath: "/tmp/Root/",
                in: rawPaths
            )
        )
        XCTAssertFalse(
            WorkspaceExactRootPath.contains(
                canonicalComparisonPath: " /tmp/root ",
                in: rawPaths
            )
        )
    }

    func testExactRootCandidateRankIsDeterministicAcrossEveryTieBreaker() throws {
        let earlierID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let laterID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let latestID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let timestamp = Date(timeIntervalSinceReferenceDate: 100)
        let ranks = [
            WorkspaceExactRootCandidateRank(
                lastUsed: timestamp,
                name: "alpha",
                workspaceID: laterID
            ),
            WorkspaceExactRootCandidateRank(
                lastUsed: timestamp.addingTimeInterval(1),
                name: "zeta",
                workspaceID: laterID
            ),
            WorkspaceExactRootCandidateRank(
                lastUsed: timestamp,
                name: "beta",
                workspaceID: earlierID
            ),
            WorkspaceExactRootCandidateRank(
                lastUsed: timestamp,
                name: "Alpha",
                workspaceID: latestID
            ),
            WorkspaceExactRootCandidateRank(
                lastUsed: timestamp,
                name: "alpha",
                workspaceID: earlierID
            )
        ]

        XCTAssertEqual(
            ranks.sorted().map(\.workspaceID),
            [laterID, earlierID, laterID, latestID, earlierID]
        )
        XCTAssertEqual(
            ranks.sorted().map(\.name),
            ["zeta", "alpha", "alpha", "Alpha", "beta"]
        )
    }
}
