import Foundation
@testable import RepoPromptCore
import XCTest

final class WorkspacePersistenceWriterTests: XCTestCase {
    func testSerializesWritesPerURLAndFlushesThroughReceiptCut() async throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("workspace.json")
        let diagnostics = RecordingWorkspaceDiagnostics()
        let writer = WorkspacePersistenceWriter(diagnostics: diagnostics)
        let gate = FirstWorkspaceWriteGate()
        await writer.setAtomicWriteGateForTesting {
            await gate.waitIfFirstWrite()
        }
        let first = makeSlice1Workspace(name: "First", promptText: "first")
        let second = makeSlice1Workspace(id: first.id, name: "Second", promptText: "second", dateModified: Date(timeIntervalSince1970: 200))

        _ = try await writer.enqueueWorkspace(first, url: url, metadata: makeSlice1Metadata(for: first))
        await gate.waitUntilFirstWriteStarted()
        let secondReceipt = try await writer.enqueueWorkspace(second, url: url, metadata: makeSlice1Metadata(for: second))
        let completionTask = Task { await writer.flush(secondReceipt) }
        await Task.yield()
        XCTAssertFalse(completionTask.isCancelled)

        await gate.releaseFirstWrite()
        let completion = await completionTask.value
        await writer.setAtomicWriteGateForTesting(nil)

        XCTAssertTrue(completion.succeeded)
        let decoded = try EmbeddedWorkspaceCodecV1().decode(Data(contentsOf: url)).document
        XCTAssertEqual(decoded.name, "Second")
        XCTAssertEqual(decoded.composeTabs[0].promptText, "second")
        XCTAssertEqual(diagnostics.writeBeginSequences, ["1", "2"])
        XCTAssertEqual(diagnostics.writeEndSequences, ["1", "2"])
    }

    func testStaleDateModifiedPayloadCannotReplaceNewerDiskWorkspace() async throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("workspace.json")
        let writer = WorkspacePersistenceWriter()
        let workspaceID = UUID()
        let newer = makeSlice1Workspace(
            id: workspaceID,
            name: "Newer",
            promptText: "newer",
            dateModified: Date(timeIntervalSince1970: 300)
        )
        let older = makeSlice1Workspace(
            id: workspaceID,
            name: "Older",
            promptText: "older",
            dateModified: Date(timeIntervalSince1970: 200)
        )

        let newerReceipt = try await writer.enqueueWorkspace(newer, url: url, metadata: makeSlice1Metadata(for: newer))
        _ = await writer.flush(newerReceipt)
        let olderReceipt = try await writer.enqueueWorkspace(older, url: url, metadata: makeSlice1Metadata(for: older))
        let completion = await writer.flush(olderReceipt)

        XCTAssertTrue(completion.succeeded)
        let decoded = try EmbeddedWorkspaceCodecV1().decode(Data(contentsOf: url)).document
        XCTAssertEqual(decoded.name, "Newer")
        XCTAssertEqual(decoded.composeTabs[0].promptText, "newer")
    }

    func testSuccessfulReplacementClearsSupersededFailure() async throws {
        let root = try makeTemporaryDirectory()
        let directory = root.appendingPathComponent("created-after-failure", isDirectory: true)
        let url = directory.appendingPathComponent("workspace.json")
        let writer = WorkspacePersistenceWriter()
        let first = makeSlice1Workspace(name: "First")
        let firstReceipt = try await writer.enqueueWorkspace(first, url: url, metadata: makeSlice1Metadata(for: first))

        let firstCompletion = await writer.flush(firstReceipt)
        XCTAssertFalse(firstCompletion.succeeded)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let second = makeSlice1Workspace(
            id: first.id,
            name: "Second",
            dateModified: Date(timeIntervalSince1970: 200)
        )
        let secondReceipt = try await writer.enqueueWorkspace(second, url: url, metadata: makeSlice1Metadata(for: second))
        let secondCompletion = await writer.flush(secondReceipt)

        XCTAssertTrue(secondCompletion.succeeded)
        XCTAssertEqual(try EmbeddedWorkspaceCodecV1().decode(Data(contentsOf: url)).document.name, "Second")
    }

    func testEnqueuedWriteRemainsDurableWhenWaitingTaskIsCancelled() async throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("workspace.json")
        let writer = WorkspacePersistenceWriter()
        let workspace = makeSlice1Workspace(name: "Durable")
        let receipt = try await writer.enqueueWorkspace(workspace, url: url, metadata: makeSlice1Metadata(for: workspace))

        let waitingTask = Task { await writer.flush(receipt) }
        waitingTask.cancel()
        let completion = await waitingTask.value

        XCTAssertTrue(completion.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try EmbeddedWorkspaceCodecV1().decode(Data(contentsOf: url)).document.id, workspace.id)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspacePersistenceWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private final class RecordingWorkspaceDiagnostics: WorkspaceRepositoryDiagnosticsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var diagnostics: [WorkspaceRepositoryDiagnostic] = []

    var writeBeginSequences: [String] {
        eventSequences(named: "workspaceSave.write.begin")
    }

    var writeEndSequences: [String] {
        eventSequences(named: "workspaceSave.write.end")
    }

    func record(_ diagnostic: WorkspaceRepositoryDiagnostic) {
        lock.lock()
        diagnostics.append(diagnostic)
        lock.unlock()
    }

    private func eventSequences(named name: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return diagnostics.compactMap { diagnostic in
            guard case let .event(eventName, fields) = diagnostic, eventName == name else { return nil }
            return fields["sequence"]
        }
    }
}

private actor FirstWorkspaceWriteGate {
    private var writeCount = 0
    private var firstStarted = false
    private var firstReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitIfFirstWrite() async {
        writeCount += 1
        guard writeCount == 1 else { return }
        firstStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        guard !firstReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilFirstWriteStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstWrite() {
        firstReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
