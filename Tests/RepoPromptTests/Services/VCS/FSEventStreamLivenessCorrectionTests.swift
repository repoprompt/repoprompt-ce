import CoreServices
import Foundation
@testable import RepoPromptApp
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
