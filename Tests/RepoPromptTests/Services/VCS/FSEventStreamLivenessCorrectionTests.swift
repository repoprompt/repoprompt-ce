import CoreServices
import Foundation
@testable import RepoPromptApp
import RepoPromptVCS
import XCTest

final class FSEventStreamLivenessCorrectionTests: XCTestCase {
    func testMetadataWrappedCallbackInvalidatesOldHighCut() async throws {
        let repositoryRoot = try makeTestDirectory(name: "MetadataWrappedCallback")
        let gitDirectory = repositoryRoot.appendingPathComponent(".git", isDirectory: true)
        let headURL = gitDirectory.appendingPathComponent("HEAD")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: headURL, atomically: true, encoding: .utf8)

        let layout = GitRepositoryLayout(
            workTreeRoot: repositoryRoot,
            dotGitPath: gitDirectory,
            gitDir: gitDirectory,
            commonDir: gitDirectory,
            isWorktree: false
        )
        let repositoryKey = GitWorkspaceAuthorityRepositoryKey(layout: layout)
        let monitor = GitWorkspaceMetadataMonitor()
        let token = try await monitor.retain(
            repositoryKey: repositoryKey,
            paths: [headURL],
            onEvent: { _ in }
        )

        await monitor.injectEventForTesting(
            repositoryKey: repositoryKey,
            path: headURL.path,
            flags: 0,
            eventID: 100
        )
        await monitor.injectEventForTesting(
            repositoryKey: repositoryKey,
            path: headURL.path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped),
            eventID: 5
        )

        let expectedAcceptedWatermark = monitor.acceptedWatermark(for: repositoryKey)
        let isCurrent = await monitor.flushCoverageAndCheckCurrent(
            token,
            repositoryKey: repositoryKey,
            paths: [headURL],
            expectedAcceptedWatermark: expectedAcceptedWatermark
        )
        XCTAssertFalse(isCurrent)
        await monitor.release(token)
    }

    func testReceiptProductionCallbackRejectsWrappedLowCutAfterOldHighWatermark() async {
        let result = await WorkspaceRootCreationReceiptCoordinator.wrappedCallbackCutForTesting()

        XCTAssertFalse(result.cutDelivered)
        XCTAssertTrue(result.generationInvalidated)
    }

    func testReceiptRecorderAcceptsIdenticalBatchReplayWithoutRegressingItsCut() {
        let recorder = WorkspaceRootCreationReceiptCoordinator.Recorder(
            destinationPath: "/temporary-worktree/child",
            watchRootPath: "/temporary-worktree",
            startEventID: 100
        )
        let batch = receiptBatch()
        recorder.accept(batch)
        XCTAssertFalse(recorder.snapshot().eventIDRegressed)

        // Delivery is deliberately 101, 103, then 101, 103 again: the second
        // callback replays known events rather than introducing a journal gap.
        recorder.accept(batch)
        var snapshot = recorder.snapshot()
        XCTAssertFalse(snapshot.eventIDRegressed)
        XCTAssertEqual(snapshot.acceptedCallbackWatermark, 2)
        XCTAssertEqual(snapshot.acceptedCallbackCount, 2)
        XCTAssertEqual(snapshot.acceptedDestinationEventCount, 4)

        recorder.accept([
            WorkspaceRootCreationFSEvent(
                path: "/temporary-worktree/child/new.swift",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
                eventID: 105
            )
        ])
        snapshot = recorder.snapshot()
        XCTAssertFalse(snapshot.eventIDRegressed)
        XCTAssertEqual(snapshot.acceptedCallbackWatermark, 3)

        // An unseen event below the high watermark is still a real regression.
        recorder.accept([
            WorkspaceRootCreationFSEvent(
                path: "/temporary-worktree/child/unseen.swift",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
                eventID: 104
            )
        ])
        XCTAssertTrue(recorder.snapshot().eventIDRegressed)
    }

    func testReceiptRecorderRejectsLowerBatchesUnlessIDsPathsFlagsAndOrderMatch() {
        let original = receiptBatch()
        let changedPath = WorkspaceRootCreationFSEvent(
            path: "/temporary-worktree/child/different.swift",
            flags: original[0].flags,
            eventID: original[0].eventID
        )
        let changedFlags = WorkspaceRootCreationFSEvent(
            path: original[0].path,
            flags: original[0].flags | FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
            eventID: original[0].eventID
        )
        let changedID = WorkspaceRootCreationFSEvent(
            path: original[0].path,
            flags: original[0].flags,
            eventID: 102
        )
        let cases: [(String, [WorkspaceRootCreationFSEvent], Bool)] = [
            ("changed path", [changedPath, original[1]], false),
            ("changed flags", [changedFlags, original[1]], true),
            ("changed ID", [changedID, original[1]], false),
            ("changed order", Array(original.reversed()), false),
            ("partial replay", [original[0]], false)
        ]
        for (label, batch, mustScanSubDirs) in cases {
            let recorder = WorkspaceRootCreationReceiptCoordinator.Recorder(
                destinationPath: "/temporary-worktree/child",
                watchRootPath: "/temporary-worktree",
                startEventID: 100
            )
            recorder.accept(original)
            recorder.accept(batch)
            let snapshot = recorder.snapshot()
            XCTAssertTrue(snapshot.eventIDRegressed, label)
            XCTAssertEqual(snapshot.mustScanSubDirs, mustScanSubDirs, label)
        }
    }

    func testReceiptRecorderRejectsNonconsecutiveReplayAndKeepsRegressionSticky() {
        let recorder = WorkspaceRootCreationReceiptCoordinator.Recorder(
            destinationPath: "/temporary-worktree/child",
            watchRootPath: "/temporary-worktree",
            startEventID: 100
        )
        let batch = receiptBatch()
        recorder.accept(batch)
        recorder.accept([
            WorkspaceRootCreationFSEvent(
                path: "/temporary-worktree/child/new.swift",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
                eventID: 105
            )
        ])
        recorder.accept(batch)
        XCTAssertTrue(recorder.snapshot().eventIDRegressed)
        recorder.accept(batch)
        XCTAssertTrue(recorder.snapshot().eventIDRegressed)
        XCTAssertEqual(recorder.snapshot().acceptedCallbackWatermark, 4)
    }

    private func receiptBatch() -> [WorkspaceRootCreationFSEvent] {
        [
            WorkspaceRootCreationFSEvent(
                path: "/temporary-worktree/child/first.swift",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
                eventID: 101
            ),
            WorkspaceRootCreationFSEvent(
                path: "/temporary-worktree/child/second.swift",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
                eventID: 103
            )
        ]
    }

    func testReceiptRecorderRetainsWrappedClassificationWhileCutIsInvalid() {
        let recorder = WorkspaceRootCreationReceiptCoordinator.Recorder(
            destinationPath: "/temporary-worktree/child",
            watchRootPath: "/temporary-worktree",
            startEventID: 100
        )
        recorder.accept([
            WorkspaceRootCreationFSEvent(
                path: "/temporary-worktree/child",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped),
                eventID: 5
            )
        ])

        let snapshot = recorder.snapshot()
        XCTAssertTrue(snapshot.eventIDsWrapped)
        XCTAssertTrue(snapshot.eventIDRegressed)
    }
}
