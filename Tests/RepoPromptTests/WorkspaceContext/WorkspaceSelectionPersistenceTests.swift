@testable import RepoPrompt
import XCTest

final class WorkspaceSelectionPersistenceTests: XCTestCase {
    override func tearDown() async throws {
        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
        try await super.tearDown()
    }

    func testDiskWriterPreservesNewerSelectionRevisionAgainstLaterStalePayload() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSelectionPersistenceTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let url = tempDir.appendingPathComponent("workspace.json")
        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()

        let workspaceID = UUID()
        let tabID = UUID()
        let correct = Self.workspace(
            id: workspaceID,
            tabID: tabID,
            selection: Self.selection(count: 7),
            dateModified: Date(timeIntervalSince1970: 100),
            promptText: "correct"
        )
        let correctData = try JSONEncoder().encode(correct)
        let correctMetadata = WorkspaceManagerViewModel.metadata(
            for: correct,
            source: "test.correctSelection",
            activeSelectionRevision: 1
        )

        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.enqueueWorkspace(data: correctData, url: url, metadata: correctMetadata)
        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: url)

        let stale = Self.workspace(
            id: workspaceID,
            tabID: tabID,
            selection: Self.selection(count: 15, includeSlices: true),
            dateModified: Date(timeIntervalSince1970: 200),
            promptText: "stale-non-selection-field"
        )
        let staleData = try JSONEncoder().encode(stale)
        let staleMetadata = WorkspaceManagerViewModel.metadata(
            for: stale,
            source: "test.staleSelection",
            activeSelectionRevision: 0
        )

        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.enqueueWorkspace(data: staleData, url: url, metadata: staleMetadata)
        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: url)

        let decoded = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: url))
        let activeSelection = try XCTUnwrap(decoded.composeTabs.first(where: { $0.id == tabID })?.selection)
        XCTAssertEqual(activeSelection, correct.composeTabs[0].selection)
        XCTAssertEqual(decoded.composeTabs[0].promptText, "stale-non-selection-field")
    }

    func testDiskWriterMergesNewerSelectionIntoNewerDiskInsteadOfSkipping() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSelectionPersistenceTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let url = tempDir.appendingPathComponent("workspace.json")
        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()

        let workspaceID = UUID()
        let tabID = UUID()
        let staleDisk = Self.workspace(
            id: workspaceID,
            tabID: tabID,
            selection: Self.selection(count: 15, includeSlices: true),
            dateModified: Date(timeIntervalSince1970: 300),
            promptText: "disk-field"
        )
        try JSONEncoder().encode(staleDisk).write(to: url, options: .atomic)

        let incoming = Self.workspace(
            id: workspaceID,
            tabID: tabID,
            selection: Self.selection(count: 7),
            dateModified: Date(timeIntervalSince1970: 200),
            promptText: "incoming-field"
        )
        let metadata = WorkspaceManagerViewModel.metadata(
            for: incoming,
            source: "test.newerSelectionOlderPayload",
            activeSelectionRevision: 2
        )

        try await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.enqueueWorkspace(
            data: JSONEncoder().encode(incoming),
            url: url,
            metadata: metadata
        )
        await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: url)

        let decoded = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded.composeTabs[0].selection, incoming.composeTabs[0].selection)
        XCTAssertEqual(decoded.composeTabs[0].promptText, "disk-field")
    }

    func testDiskWriterFlushAndAtomicWriteTelemetryCarryDurabilityAttributionWithoutPaths() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSelectionPersistenceTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let url = tempDir.appendingPathComponent("workspace.json")
        let writer = WorkspaceManagerViewModel.WorkspaceDiskWriter.shared
        await writer.removeAllForTesting()
        defer { EditFlowPerf.resetDebugCaptureForTesting() }

        switch EditFlowPerf.beginDebugCapture(label: "workspace-durability", maxSamples: 100) {
        case .started:
            break
        case .busy:
            XCTFail("Expected a fresh durability diagnostics capture")
        }
        let firstCorrelation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
        let secondCorrelation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
        let gate = WorkspacePersistenceAsyncGate()
        let flushFinished = WorkspacePersistenceAsyncSignal()
        await writer.setAtomicWriteGateForTesting {
            await gate.markStartedAndWaitForRelease()
        }

        await EditFlowPerf.$currentLifecycleCorrelation.withValue(firstCorrelation) {
            await writer.enqueue(data: Data("first durable payload".utf8), url: url)
        }
        await gate.waitUntilStarted()
        await EditFlowPerf.$currentLifecycleCorrelation.withValue(secondCorrelation) {
            await writer.enqueue(data: Data("second durable payload".utf8), url: url)
        }
        let flushTask = Task {
            await EditFlowPerf.$currentLifecycleCorrelation.withValue(secondCorrelation) {
                await writer.flush(url: url)
            }
            await flushFinished.mark()
        }
        await Task.yield()
        let finishedBeforeRelease = await flushFinished.isMarked()
        XCTAssertFalse(finishedBeforeRelease)

        await gate.release()
        await flushTask.value
        await writer.setAtomicWriteGateForTesting(nil)
        let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
        let stageNames = Set(snapshot.stages.map(\.stageName))
        XCTAssertTrue(stageNames.contains("EditFlow.WorkspaceDurability.FlushWait"))
        XCTAssertTrue(stageNames.contains("EditFlow.WorkspaceDurability.AtomicWrite"))
        let eventNames = snapshot.lifecycleEvents.map(\.eventName)
        XCTAssertTrue(eventNames.contains("WorkspaceDurability.FlushBegan"))
        XCTAssertTrue(eventNames.contains("WorkspaceDurability.FlushEnded"))
        XCTAssertTrue(eventNames.contains("WorkspaceDurability.WriteBegan"))
        XCTAssertTrue(eventNames.contains("WorkspaceDurability.WriteEnded"))
        let writeCorrelationIDs = snapshot.lifecycleEvents
            .filter { $0.eventName == "WorkspaceDurability.WriteBegan" }
            .map(\.correlationID)
        XCTAssertEqual(writeCorrelationIDs, [firstCorrelation.id.uuidString, secondCorrelation.id.uuidString])
        XCTAssertTrue(snapshot.stages.allSatisfy { !$0.sanitizedDimensions.contains("/") })
        XCTAssertTrue(snapshot.lifecycleEvents.allSatisfy { !$0.sanitizedDimensions.contains("/") })
    }

    func testApplySelectionToWorkspaceUpdatesActiveTabOnly() {
        let workspaceID = UUID()
        let tabID = UUID()
        let stale = Self.selection(count: 15, includeSlices: true)
        let latest = Self.selection(count: 7)
        let workspace = Self.workspace(
            id: workspaceID,
            tabID: tabID,
            selection: stale,
            dateModified: Date(timeIntervalSince1970: 100),
            promptText: "keep prompt"
        )

        let result = WorkspaceManagerViewModel.workspaceByApplyingSelection(latest, toActiveTab: tabID, in: workspace)

        XCTAssertTrue(result.applied)
        XCTAssertEqual(result.workspace.composeTabs[0].selection, latest)
        XCTAssertEqual(result.workspace.composeTabs[0].promptText, "keep prompt")
        XCTAssertEqual(result.workspace.repoPaths, workspace.repoPaths)
    }

    private static func workspace(
        id: UUID,
        tabID: UUID,
        selection: StoredSelection,
        dateModified: Date,
        promptText: String
    ) -> WorkspaceModel {
        let tab = ComposeTabState(id: tabID, name: "T1", selection: selection, promptText: promptText)
        return WorkspaceModel(
            id: id,
            dateModified: dateModified,
            name: "Selection Persistence",
            repoPaths: ["/tmp/root"],
            composeTabs: [tab],
            activeComposeTabID: tabID
        )
    }

    private static func selection(count: Int, includeSlices: Bool = false) -> StoredSelection {
        let paths = (0 ..< count).map { "/tmp/root/file\($0).swift" }
        let slices: [String: [LineRange]] = if includeSlices, let first = paths.first {
            [first: [LineRange(start: 1, end: 3), LineRange(start: 8, end: 13)]]
        } else {
            [:]
        }
        return StoredSelection(
            selectedPaths: paths,

            slices: slices,
            codemapAutoEnabled: !includeSlices
        )
    }
}

private actor WorkspacePersistenceAsyncGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWaitForRelease() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor WorkspacePersistenceAsyncSignal {
    private var marked = false

    func mark() {
        marked = true
    }

    func isMarked() -> Bool {
        marked
    }
}
