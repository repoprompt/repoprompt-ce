@testable import RepoPrompt
import XCTest

final class GitDiffDataMaintenanceTests: XCTestCase {
    func testPostPublishRetentionUsesLightweightIndexAndPreservesLimit() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitDiffDataMaintenanceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let store = GitDiffSnapshotStore()
        let repoKey = "repo-test"
        let policy = GitDiffDataMaintenance.Policy(
            maxSnapshotsPerWorkspace: 25,
            maxAgeDays: 7,
            minIntervalBetweenRuns: 6 * 3600
        )

        for index in 0 ..< 26 {
            let snapshotID = "2026-06-11/\(String(format: "%04d", index))"
            let snapshotDir = store.snapshotDir(
                workspaceDirectory: sandbox,
                repoKey: repoKey,
                snapshotID: snapshotID
            )
            try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
            await GitDiffDataMaintenance.shared.runAfterSnapshotPublish(
                workspaceDirectory: sandbox,
                repoKey: repoKey,
                snapshotID: snapshotID,
                generatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                policy: policy
            )
        }

        let oldest = store.snapshotDir(
            workspaceDirectory: sandbox,
            repoKey: repoKey,
            snapshotID: "2026-06-11/0000"
        )
        let newest = store.snapshotDir(
            workspaceDirectory: sandbox,
            repoKey: repoKey,
            snapshotID: "2026-06-11/0025"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))

        let indexURL = store.gitDataRoot(workspaceDirectory: sandbox)
            .appendingPathComponent("retention-index.json")
        let data = try Data(contentsOf: indexURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 25)
        XCTAssertFalse(entries.contains { $0["snapshotID"] as? String == "2026-06-11/0000" })
        XCTAssertTrue(entries.contains { $0["snapshotID"] as? String == "2026-06-11/0025" })
    }
}
