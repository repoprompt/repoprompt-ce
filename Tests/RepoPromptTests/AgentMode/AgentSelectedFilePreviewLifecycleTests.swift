@testable import RepoPrompt
import XCTest

final class AgentSelectedFilePreviewLifecycleTests: XCTestCase {
    @MainActor
    func testPreviewLoadCompletionPublishesTextAndClearsLoadingState() async {
        let coordinator = AgentSelectedFilePreviewLoadCoordinator()
        let row = makeRow()
        let gate = PreviewLoadGate()
        let initialRevision = coordinator.contentRevision

        coordinator.openPreview(row: row) { row, purpose in
            await gate.load(row: row, purpose: purpose)
        }

        XCTAssertTrue(coordinator.showPreview)
        XCTAssertTrue(coordinator.isLoadingPreview)
        XCTAssertNil(coordinator.previewText)
        XCTAssertTrue(coordinator.hasPreviewLoadTask)
        let loadingRevision = coordinator.contentRevision
        XCTAssertGreaterThan(loadingRevision, initialRevision)
        guard await gate.waitUntilStarted() else {
            XCTFail("Preview load did not start")
            return
        }

        await gate.release("loaded preview text")
        let didComplete = await gate.waitUntilCompleted()
        XCTAssertTrue(didComplete, "Preview load should complete")
        await drainCancelledTask()

        XCTAssertTrue(coordinator.showPreview)
        XCTAssertFalse(coordinator.isLoadingPreview)
        XCTAssertEqual(coordinator.previewText, "loaded preview text")
        XCTAssertFalse(coordinator.hasPreviewLoadTask)
        let loadedRevision = coordinator.contentRevision
        XCTAssertGreaterThan(loadedRevision, loadingRevision)

        coordinator.handlePreviewPresentationChanged(isPresented: false)
        XCTAssertGreaterThan(coordinator.contentRevision, loadedRevision)
    }

    @MainActor
    func testRowDisappearCancellationClearsPreviewLoadingState() async {
        let coordinator = AgentSelectedFilePreviewLoadCoordinator()
        let row = makeRow()
        let gate = PreviewLoadGate()

        coordinator.openPreview(row: row) { row, purpose in
            await gate.load(row: row, purpose: purpose)
        }

        XCTAssertTrue(coordinator.showPreview)
        XCTAssertTrue(coordinator.isLoadingPreview)
        XCTAssertNil(coordinator.previewText)
        XCTAssertTrue(coordinator.hasPreviewLoadTask)
        guard await gate.waitUntilStarted() else {
            XCTFail("Preview load did not start")
            return
        }

        coordinator.handleRowDisappear()

        XCTAssertFalse(coordinator.isLoadingPreview)
        XCTAssertNil(coordinator.previewText)
        XCTAssertFalse(coordinator.hasPreviewLoadTask)

        await gate.release("loaded preview text")
        let didCompleteAfterDisappear = await gate.waitUntilCompleted()
        XCTAssertTrue(didCompleteAfterDisappear, "Preview load should resume after release")
        await drainCancelledTask()

        XCTAssertFalse(coordinator.isLoadingPreview)
        XCTAssertNil(coordinator.previewText)
        XCTAssertFalse(coordinator.hasPreviewLoadTask)
    }

    @MainActor
    func testPreviewDismissalCancellationClearsLoadingState() async {
        let coordinator = AgentSelectedFilePreviewLoadCoordinator()
        let row = makeRow()
        let gate = PreviewLoadGate()

        coordinator.openPreview(row: row) { row, purpose in
            await gate.load(row: row, purpose: purpose)
        }

        XCTAssertTrue(coordinator.showPreview)
        XCTAssertTrue(coordinator.isLoadingPreview)
        XCTAssertTrue(coordinator.hasPreviewLoadTask)
        guard await gate.waitUntilStarted() else {
            XCTFail("Preview load did not start")
            return
        }

        coordinator.handlePreviewPresentationChanged(isPresented: false)

        XCTAssertFalse(coordinator.showPreview)
        XCTAssertFalse(coordinator.isLoadingPreview)
        XCTAssertNil(coordinator.previewText)
        XCTAssertFalse(coordinator.hasPreviewLoadTask)

        await gate.release("loaded preview text")
        let didCompleteAfterDismissal = await gate.waitUntilCompleted()
        XCTAssertTrue(didCompleteAfterDismissal, "Preview load should resume after release")
        await drainCancelledTask()

        XCTAssertFalse(coordinator.showPreview)
        XCTAssertFalse(coordinator.isLoadingPreview)
        XCTAssertNil(coordinator.previewText)
        XCTAssertFalse(coordinator.hasPreviewLoadTask)
    }

    private func makeRow(
        kind: AgentContextExportRow.Kind = .full,
        mode: PromptFileEntryMode = .fullFile,
        lineRanges: [LineRange]? = nil
    ) -> AgentContextExportRow {
        AgentContextExportRow(
            id: ResolvedPromptFileEntryID(fileID: UUID(), mode: mode, lineRanges: lineRanges),
            kind: kind,
            physicalPath: "/tmp/RepoPromptTests/Sources/App.swift",
            rootID: UUID(),
            relativePath: "Sources/App.swift",
            displayPath: "Sources/App.swift",
            displayName: "App.swift",
            directoryDisplay: "Sources",
            lineRanges: lineRanges,
            canRemove: true
        )
    }

    private func drainCancelledTask() async {
        for _ in 0 ..< 10 {
            await Task.yield()
        }
    }
}

private actor PreviewLoadGate {
    private var started = false
    private var completed = false
    private var releaseContinuation: CheckedContinuation<String?, Never>?

    func load(row _: AgentContextExportRow, purpose _: AgentContextExportRow.ContentPurpose) async -> String? {
        let value = await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            started = true
        }
        completed = true
        return value
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0 ..< 500 {
            if started { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return started
    }

    func release(_ value: String?) {
        releaseContinuation?.resume(returning: value)
        releaseContinuation = nil
    }

    func waitUntilCompleted() async -> Bool {
        for _ in 0 ..< 500 {
            if completed { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return completed
    }
}
