@testable import RepoPrompt
import XCTest

final class AgentSelectedFilePreviewLifecycleTests: XCTestCase {
    @MainActor
    func testPreviewLoadCompletionPublishesTextAndClearsLoadingState() async {
        let coordinator = AgentSelectedFilePreviewLoadCoordinator()
        let row = makeRow(displayName: "A.swift")
        let gate = PreviewLoadGate()
        let initialRevision = coordinator.contentRevision

        coordinator.openPreview(row: row) { row, purpose in
            await gate.load(row: row, purpose: purpose)
        }

        XCTAssertTrue(coordinator.isPreviewPresented(for: row))
        XCTAssertTrue(coordinator.isLoadingPreview(for: row))
        XCTAssertEqual(coordinator.activePreviewRowID, row.id)
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

        XCTAssertTrue(coordinator.isPreviewPresented(for: row))
        XCTAssertFalse(coordinator.isLoadingPreview(for: row))
        XCTAssertEqual(coordinator.previewText, "loaded preview text")
        XCTAssertEqual(coordinator.displayText(for: row), "loaded preview text")
        XCTAssertFalse(coordinator.hasPreviewLoadTask)
        let loadedRevision = coordinator.contentRevision
        XCTAssertGreaterThan(loadedRevision, loadingRevision)

        coordinator.handlePreviewPresentationChanged(row: row, isPresented: false)
        XCTAssertFalse(coordinator.isPreviewPresented(for: row))
        XCTAssertNil(coordinator.activePreviewRowID)
        XCTAssertNil(coordinator.previewText)
        XCTAssertGreaterThan(coordinator.contentRevision, loadedRevision)
    }

    @MainActor
    func testRowDisappearCancellationClearsActivePreviewAndLoadedText() async {
        let coordinator = AgentSelectedFilePreviewLoadCoordinator()
        let row = makeRow(displayName: "A.swift")
        let gate = PreviewLoadGate()

        coordinator.openPreview(row: row) { row, purpose in
            await gate.load(row: row, purpose: purpose)
        }

        XCTAssertTrue(coordinator.isPreviewPresented(for: row))
        XCTAssertTrue(coordinator.isLoadingPreview(for: row))
        XCTAssertNil(coordinator.previewText)
        XCTAssertTrue(coordinator.hasPreviewLoadTask)
        guard await gate.waitUntilStarted() else {
            XCTFail("Preview load did not start")
            return
        }

        coordinator.handleRowDisappear(row: row)

        XCTAssertFalse(coordinator.isPreviewPresented(for: row))
        XCTAssertNil(coordinator.activePreviewRowID)
        XCTAssertFalse(coordinator.isLoadingPreview(for: row))
        XCTAssertNil(coordinator.previewText)
        XCTAssertFalse(coordinator.hasPreviewLoadTask)

        await gate.release("loaded preview text")
        let didCompleteAfterDisappear = await gate.waitUntilCompleted()
        XCTAssertTrue(didCompleteAfterDisappear, "Preview load should resume after release")
        await drainCancelledTask()

        XCTAssertFalse(coordinator.isPreviewPresented(for: row))
        XCTAssertNil(coordinator.activePreviewRowID)
        XCTAssertFalse(coordinator.isLoadingPreview(for: row))
        XCTAssertNil(coordinator.previewText)
        XCTAssertFalse(coordinator.hasPreviewLoadTask)
    }

    @MainActor
    func testPreviewDismissalCancellationClearsActivePreviewAndLoadedText() async {
        let coordinator = AgentSelectedFilePreviewLoadCoordinator()
        let row = makeRow(displayName: "A.swift")
        let gate = PreviewLoadGate()

        coordinator.openPreview(row: row) { row, purpose in
            await gate.load(row: row, purpose: purpose)
        }

        XCTAssertTrue(coordinator.isPreviewPresented(for: row))
        XCTAssertTrue(coordinator.isLoadingPreview(for: row))
        XCTAssertTrue(coordinator.hasPreviewLoadTask)
        guard await gate.waitUntilStarted() else {
            XCTFail("Preview load did not start")
            return
        }

        coordinator.handlePreviewPresentationChanged(row: row, isPresented: false)

        XCTAssertFalse(coordinator.isPreviewPresented(for: row))
        XCTAssertNil(coordinator.activePreviewRowID)
        XCTAssertFalse(coordinator.isLoadingPreview(for: row))
        XCTAssertNil(coordinator.previewText)
        XCTAssertFalse(coordinator.hasPreviewLoadTask)

        await gate.release("loaded preview text")
        let didCompleteAfterDismissal = await gate.waitUntilCompleted()
        XCTAssertTrue(didCompleteAfterDismissal, "Preview load should resume after release")
        await drainCancelledTask()

        XCTAssertFalse(coordinator.isPreviewPresented(for: row))
        XCTAssertNil(coordinator.activePreviewRowID)
        XCTAssertFalse(coordinator.isLoadingPreview(for: row))
        XCTAssertNil(coordinator.previewText)
        XCTAssertFalse(coordinator.hasPreviewLoadTask)
    }

    @MainActor
    func testOpeningSecondPreviewCancelsFirstAndOnlyPublishesActiveRowText() async {
        let coordinator = AgentSelectedFilePreviewLoadCoordinator()
        let rowA = makeRow(displayName: "A.swift")
        let rowB = makeRow(displayName: "B.swift")
        let gate = MultiPreviewLoadGate()

        coordinator.openPreview(row: rowA) { row, purpose in
            await gate.load(row: row, purpose: purpose)
        }
        guard await gate.waitUntilStarted(rowA.displayName) else {
            XCTFail("First preview load did not start")
            return
        }

        coordinator.openPreview(row: rowB) { row, purpose in
            await gate.load(row: row, purpose: purpose)
        }
        guard await gate.waitUntilStarted(rowB.displayName) else {
            XCTFail("Second preview load did not start")
            return
        }

        XCTAssertFalse(coordinator.isPreviewPresented(for: rowA))
        XCTAssertTrue(coordinator.isPreviewPresented(for: rowB))
        XCTAssertEqual(coordinator.activePreviewRowID, rowB.id)

        coordinator.handlePreviewPresentationChanged(row: rowA, isPresented: false)
        XCTAssertTrue(coordinator.isPreviewPresented(for: rowB))
        XCTAssertEqual(coordinator.activePreviewRowID, rowB.id)

        await gate.release("A.swift", value: "late first text")
        let didCompleteRowA = await gate.waitUntilCompleted(rowA.displayName)
        XCTAssertTrue(didCompleteRowA)
        await drainCancelledTask()
        XCTAssertNil(coordinator.previewText)
        XCTAssertTrue(coordinator.isLoadingPreview(for: rowB))

        await gate.release("B.swift", value: "second text")
        let didCompleteRowB = await gate.waitUntilCompleted(rowB.displayName)
        XCTAssertTrue(didCompleteRowB)
        let didPublishSecondText = await waitForPreviewText("second text", in: coordinator)

        XCTAssertTrue(didPublishSecondText)
        XCTAssertEqual(coordinator.previewText, "second text")
        XCTAssertEqual(coordinator.displayText(for: rowB), "second text")
        XCTAssertFalse(coordinator.isPreviewPresented(for: rowA))
    }

    @MainActor
    func testReconcileVisibleRowsClearsPreviewWhenActiveRowIdentityChanges() async {
        let coordinator = AgentSelectedFilePreviewLoadCoordinator()
        let row = makeRow(displayName: "A.swift")
        let changedRow = makeRow(
            id: row.id,
            displayName: "A.swift",
            relativePath: "Sources/Renamed.swift"
        )
        let gate = PreviewLoadGate()

        coordinator.openPreview(row: row) { row, purpose in
            await gate.load(row: row, purpose: purpose)
        }
        guard await gate.waitUntilStarted() else {
            XCTFail("Preview load did not start")
            return
        }
        await gate.release("loaded preview text")
        let didComplete = await gate.waitUntilCompleted()
        XCTAssertTrue(didComplete)
        let didPublishText = await waitForPreviewText("loaded preview text", in: coordinator)
        XCTAssertTrue(didPublishText)

        coordinator.reconcileVisibleRows([changedRow])

        XCTAssertNil(coordinator.activePreviewRowID)
        XCTAssertNil(coordinator.previewText)
        XCTAssertFalse(coordinator.isPreviewPresented(for: row))
        XCTAssertFalse(coordinator.isPreviewPresented(for: changedRow))
    }

    func testPreviewPolicyBoundsLargeText() {
        let limit = AgentContextPreviewContentPolicy.maximumCharacters
        let text = String(repeating: "x", count: limit + 1)

        let bounded = AgentContextPreviewContentPolicy.boundedPreviewText(text)

        XCTAssertTrue(bounded.hasPrefix(String(repeating: "x", count: limit)))
        XCTAssertFalse(bounded.hasPrefix(text))
        XCTAssertTrue(bounded.contains("Preview truncated"))
    }

    private func makeRow(
        id: ResolvedPromptFileEntryID? = nil,
        displayName: String = "App.swift",
        kind: AgentContextExportRow.Kind = .full,
        mode: PromptFileEntryMode = .fullFile,
        lineRanges: [LineRange]? = nil,
        rootID: UUID = UUID(),
        relativePath: String? = nil
    ) -> AgentContextExportRow {
        let resolvedID = id ?? ResolvedPromptFileEntryID(fileID: UUID(), mode: mode, lineRanges: lineRanges)
        let resolvedRelativePath = relativePath ?? "Sources/\(displayName)"
        return AgentContextExportRow(
            id: resolvedID,
            kind: kind,
            rootID: rootID,
            relativePath: resolvedRelativePath,
            displayPath: resolvedRelativePath,
            displayName: displayName,
            directoryDisplay: "Sources",
            lineRanges: lineRanges,
            canRemove: true
        )
    }

    @MainActor
    private func waitForPreviewText(_ expected: String, in coordinator: AgentSelectedFilePreviewLoadCoordinator) async -> Bool {
        for _ in 0 ..< 500 {
            if coordinator.previewText == expected { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return coordinator.previewText == expected
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

private actor MultiPreviewLoadGate {
    private var started = Set<String>()
    private var completed = Set<String>()
    private var releaseContinuations: [String: CheckedContinuation<String?, Never>] = [:]

    func load(row: AgentContextExportRow, purpose _: AgentContextExportRow.ContentPurpose) async -> String? {
        await withCheckedContinuation { continuation in
            releaseContinuations[row.displayName] = continuation
            started.insert(row.displayName)
        }
    }

    func waitUntilStarted(_ displayName: String) async -> Bool {
        for _ in 0 ..< 500 {
            if started.contains(displayName) { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return started.contains(displayName)
    }

    func release(_ displayName: String, value: String?) {
        releaseContinuations.removeValue(forKey: displayName)?.resume(returning: value)
        completed.insert(displayName)
    }

    func waitUntilCompleted(_ displayName: String) async -> Bool {
        for _ in 0 ..< 500 {
            if completed.contains(displayName) { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return completed.contains(displayName)
    }
}
