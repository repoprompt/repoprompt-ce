import Foundation
@testable import RepoPromptApp
import XCTest

private let issue863GateWatchdogNanoseconds: UInt64 = 5_000_000_000

final class AgentSessionDataServiceLoadRepairDeletionTests: XCTestCase {
    func testLoadReconciliationDoesNotResurrectAfterDeletion() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storageURL = try XCTUnwrap(workspace.customStoragePath)
        let reconciliationGate = Issue863TestAsyncGate()
        let cleanup = Issue863TestRepairCleanup(service: service, gate: reconciliationGate)
        addTeardownBlock {
            await cleanup.finish()
            try? FileManager.default.removeItem(at: storageURL)
        }

        let sessionID = UUID()
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            name: "Reconciliation Delete Race",
            savedAt: Date(timeIntervalSinceReferenceDate: 10),
            itemCount: 0,
            autoEditEnabled: true,
            worktreeMergeOperations: [makeActiveMergeOperation()]
        )
        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        await service.test_setWorktreeMergeReconciliationHooks(
            AgentSessionWorktreeMergeReconciliationHooks { _ in
                await reconciliationGate.wait()
                return AgentSessionWorktreeMergeReconciliationInspection(
                    targetMergeInProgress: true,
                    targetHead: nil
                )
            }
        )

        let loadTask = Task {
            try await service.loadAgentSession(from: fileURL)
        }
        await cleanup.registerLoadTask(loadTask)
        await cleanup.registerWatchdog(makeGateWatchdog(for: reconciliationGate))
        guard await reconciliationGate.waitUntilEntered() else {
            XCTFail("Load reconciliation did not reach its deterministic gate")
            return
        }

        let deleteTask = Task {
            try await service.deleteAgentSession(id: sessionID, for: workspace)
        }
        await cleanup.registerDeleteTask(deleteTask)
        try await deleteTask.value
        await reconciliationGate.open()

        do {
            _ = try await loadTask.value
            XCTFail("A load repair resumed after deletion and unexpectedly succeeded")
        } catch {
            assertLoadFailedWithSessionDeleted(error, sessionID: sessionID)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(try metadataRecord(sessionID, nextTo: fileURL))
    }

    func testStubRecoveryDoesNotResurrectAfterDeletion() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storageURL = try XCTUnwrap(workspace.customStoragePath)
        let recoveryGate = Issue863TestAsyncGate()
        let cleanup = Issue863TestRepairCleanup(service: service, gate: recoveryGate)
        addTeardownBlock {
            await cleanup.finish()
            try? FileManager.default.removeItem(at: storageURL)
        }

        let sessionID = UUID()
        let fileURL = try await seedLegacySession(
            service: service,
            workspace: workspace,
            sessionID: sessionID
        )
        await service.test_setBeforeLoadRepairWriteHook { url in
            guard url == fileURL.standardizedFileURL else { return }
            await recoveryGate.wait()
        }

        let recoveryTask = Task {
            try await service.loadAgentSessionStub(
                from: fileURL,
                recoverMissingMetadata: true,
                persistRecoveredMetadata: true
            )
        }
        await cleanup.registerLoadTask(recoveryTask)
        await cleanup.registerWatchdog(makeGateWatchdog(for: recoveryGate))
        guard await recoveryGate.waitUntilEntered() else {
            XCTFail("Stub recovery did not reach its deterministic gate")
            return
        }

        let deleteTask = Task {
            try await service.deleteAgentSession(id: sessionID, for: workspace)
        }
        await cleanup.registerDeleteTask(deleteTask)
        try await deleteTask.value
        await recoveryGate.open()

        let recovered = try await recoveryTask.value
        XCTAssertEqual(recovered.id, sessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(try metadataRecord(sessionID, nextTo: fileURL))
    }

    func testStubRecoveryPersistsForNondeletedSession() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storageURL = try XCTUnwrap(workspace.customStoragePath)
        let recoveryGate = Issue863TestAsyncGate()
        let cleanup = Issue863TestRepairCleanup(service: service, gate: recoveryGate)
        addTeardownBlock {
            await cleanup.finish()
            try? FileManager.default.removeItem(at: storageURL)
        }

        let sessionID = UUID()
        let fileURL = try await seedLegacySession(
            service: service,
            workspace: workspace,
            sessionID: sessionID
        )
        try await removeMetadataIndex(for: service, nextTo: fileURL)
        XCTAssertNil(try metadataRecord(sessionID, nextTo: fileURL))

        await service.test_setBeforeLoadRepairWriteHook { url in
            guard url == fileURL.standardizedFileURL else { return }
            await recoveryGate.wait()
        }

        let recoveryTask = Task {
            try await service.loadAgentSessionStub(
                from: fileURL,
                recoverMissingMetadata: true,
                persistRecoveredMetadata: true
            )
        }
        await cleanup.registerLoadTask(recoveryTask)
        await cleanup.registerWatchdog(makeGateWatchdog(for: recoveryGate))
        guard await recoveryGate.waitUntilEntered() else {
            XCTFail("Stub recovery did not reach its deterministic gate")
            return
        }

        await recoveryGate.open()
        _ = try await recoveryTask.value

        let repaired = try JSONDecoder().decode(
            AgentSession.self,
            from: Data(contentsOf: fileURL)
        )
        XCTAssertEqual(repaired.serializationVersion, AgentSession.currentSerializationVersion)

        let record = try XCTUnwrap(try metadataRecord(sessionID, nextTo: fileURL))
        XCTAssertEqual(record.id, sessionID)
        XCTAssertEqual(record.filename, fileURL.lastPathComponent)
        XCTAssertEqual(record.serializationVersion, AgentSession.currentSerializationVersion)
        XCTAssertEqual(record.itemCount, repaired.effectiveItemCount)
    }

    func testLoadReconciliationPersistsForNondeletedSession() async throws {
        let service = AgentSessionDataService()
        let workspace = makeTemporaryWorkspace()
        let storageURL = try XCTUnwrap(workspace.customStoragePath)
        let repairGate = Issue863TestAsyncGate()
        let cleanup = Issue863TestRepairCleanup(service: service, gate: repairGate)
        addTeardownBlock {
            await cleanup.finish()
            try? FileManager.default.removeItem(at: storageURL)
        }

        let sessionID = UUID()
        let fileURL = try await service.saveAgentSession(
            AgentSession(
                id: sessionID,
                workspaceID: workspace.id,
                name: "Full Load Repair Control",
                savedAt: Date(timeIntervalSinceReferenceDate: 30),
                itemCount: 0,
                autoEditEnabled: true,
                worktreeMergeOperations: [makeActiveMergeOperation()]
            ),
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        try await removeMetadataIndex(for: service, nextTo: fileURL)
        XCTAssertNil(try metadataRecord(sessionID, nextTo: fileURL))

        await service.test_setWorktreeMergeReconciliationHooks(
            AgentSessionWorktreeMergeReconciliationHooks { _ in
                AgentSessionWorktreeMergeReconciliationInspection(
                    targetMergeInProgress: true,
                    targetHead: nil
                )
            }
        )
        await service.test_setBeforeLoadRepairWriteHook { url in
            guard url == fileURL.standardizedFileURL else { return }
            await repairGate.wait()
        }

        let loadTask = Task {
            try await service.loadAgentSession(from: fileURL)
        }
        await cleanup.registerLoadTask(loadTask)
        await cleanup.registerWatchdog(makeGateWatchdog(for: repairGate))
        guard await repairGate.waitUntilEntered() else {
            XCTFail("Full load repair did not reach its deterministic write gate")
            return
        }

        await repairGate.open()
        let loaded = try await loadTask.value
        XCTAssertEqual(loaded.worktreeMergeOperations.first?.status, .awaitingCommit)

        let repaired = try JSONDecoder().decode(
            AgentSession.self,
            from: Data(contentsOf: fileURL)
        )
        XCTAssertEqual(repaired.worktreeMergeOperations.first?.status, .awaitingCommit)

        let record = try XCTUnwrap(try metadataRecord(sessionID, nextTo: fileURL))
        XCTAssertEqual(record.id, sessionID)
        XCTAssertEqual(record.filename, fileURL.lastPathComponent)
        XCTAssertEqual(record.serializationVersion, AgentSession.currentSerializationVersion)
        XCTAssertEqual(record.activeWorktreeMergeSummaries.map(\.status), [.awaitingCommit])
    }

    private func seedLegacySession(
        service: AgentSessionDataService,
        workspace: WorkspaceModel,
        sessionID: UUID
    ) async throws -> URL {
        let seeded = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            name: "Legacy Stub Recovery",
            savedAt: Date(timeIntervalSinceReferenceDate: 20),
            itemCount: 0,
            autoEditEnabled: true
        )
        let fileURL = try await service.saveAgentSession(
            seeded,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        var legacy = seeded
        legacy.serializationVersion = AgentSession.currentSerializationVersion - 1
        legacy.itemCount = nil
        legacy.transcriptProjectionCounts = nil
        legacy.lastUserMessageAt = nil
        let data = try JSONEncoder().encode(legacy)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func removeMetadataIndex(
        for service: AgentSessionDataService,
        nextTo fileURL: URL
    ) async throws {
        let folder = fileURL.deletingLastPathComponent()
        let indexURL = folder.appendingPathComponent("AgentSessionIndex.json")
        try FileManager.default.removeItem(at: indexURL)
        await service.test_clearMetadataIndexCache(forAgentSessionsFolder: folder)
    }

    private func metadataRecord(
        _ sessionID: UUID,
        nextTo fileURL: URL
    ) throws -> AgentSessionMetadataRecord? {
        let indexURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("AgentSessionIndex.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        let data = try Data(contentsOf: indexURL)
        let index = try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: data)
        return index.entries.first { $0.id == sessionID }
    }

    private func assertLoadFailedWithSessionDeleted(
        _ error: Error,
        sessionID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let loadError = error as? AgentSessionDataError else {
            XCTFail("Expected AgentSessionDataError.loadFailed(sessionDeleted), got \(error)", file: file, line: line)
            return
        }
        guard case let .loadFailed(underlying) = loadError else {
            XCTFail("Expected AgentSessionDataError.loadFailed(sessionDeleted), got \(error)", file: file, line: line)
            return
        }
        guard let deletionError = underlying as? AgentSessionDataError else {
            XCTFail("Expected loadFailed to wrap sessionDeleted, got \(underlying)", file: file, line: line)
            return
        }
        guard case let .sessionDeleted(deletedSessionID) = deletionError else {
            XCTFail("Expected loadFailed to wrap sessionDeleted, got \(underlying)", file: file, line: line)
            return
        }
        XCTAssertEqual(deletedSessionID, sessionID, file: file, line: line)
    }

    private func makeGateWatchdog(for gate: Issue863TestAsyncGate) -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(nanoseconds: issue863GateWatchdogNanoseconds)
            } catch {
                return
            }
            await gate.expireEntryWaitIfNeeded()
        }
    }

    private func makeActiveMergeOperation() -> AgentSessionWorktreeMergeOperation {
        let source = GitWorktreeMergeEndpoint(
            worktreeID: "issue863-source",
            repositoryID: "issue863-repository",
            repoKey: "issue863",
            path: "/tmp/issue863-source",
            name: "source",
            branch: "feature/issue863",
            head: "source-head",
            isMain: false
        )
        let target = GitWorktreeMergeEndpoint(
            worktreeID: "issue863-target",
            repositoryID: "issue863-repository",
            repoKey: "issue863",
            path: "/tmp/issue863-target",
            name: "main",
            branch: "main",
            head: "target-head",
            isMain: true
        )
        return AgentSessionWorktreeMergeOperation(
            id: "issue863-merge",
            source: source,
            target: target,
            mergeBase: "merge-base",
            sourceHead: source.head,
            targetHeadBefore: target.head,
            status: .applying
        )
    }

    private func makeTemporaryWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionDataServiceLoadRepairDeletionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return WorkspaceModel(
            name: "Agent Session Load Repair",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
    }
}

private actor Issue863TestRepairCleanup {
    private let service: AgentSessionDataService
    private let gate: Issue863TestAsyncGate
    private var loadTask: Task<AgentSession, Error>?
    private var deleteTask: Task<Void, Error>?
    private var watchdogTask: Task<Void, Never>?
    private var hasFinished = false

    init(service: AgentSessionDataService, gate: Issue863TestAsyncGate) {
        self.service = service
        self.gate = gate
    }

    func registerLoadTask(_ task: Task<AgentSession, Error>) {
        loadTask = task
    }

    func registerDeleteTask(_ task: Task<Void, Error>) {
        deleteTask = task
    }

    func registerWatchdog(_ task: Task<Void, Never>) {
        watchdogTask = task
    }

    func finish() async {
        guard !hasFinished else { return }
        hasFinished = true

        await gate.open()

        watchdogTask?.cancel()
        if let watchdogTask {
            await watchdogTask.value
        }

        loadTask?.cancel()
        if let loadTask {
            _ = await loadTask.result
        }

        deleteTask?.cancel()
        if let deleteTask {
            _ = await deleteTask.result
        }

        await service.test_setWorktreeMergeReconciliationHooks(nil)
        await service.test_setBeforeLoadRepairWriteHook(nil)
    }
}

private actor Issue863TestAsyncGate {
    private var enteredContinuation: CheckedContinuation<Bool, Never>?
    private var enteredWaiterID: UUID?
    private var openContinuation: CheckedContinuation<Void, Never>?
    private var openWaiterID: UUID?
    private var hasEntered = false
    private var isOpen = false

    func wait() async {
        if !hasEntered {
            hasEntered = true
            let continuation = enteredContinuation
            enteredContinuation = nil
            enteredWaiterID = nil
            continuation?.resume(returning: true)
        }
        guard !isOpen, !Task.isCancelled else { return }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if isOpen || Task.isCancelled {
                    continuation.resume()
                } else {
                    openWaiterID = waiterID
                    openContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelOpenWaiter(id: waiterID) }
        }
    }

    func waitUntilEntered() async -> Bool {
        guard !hasEntered, !isOpen, !Task.isCancelled else {
            return hasEntered
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if hasEntered {
                    continuation.resume(returning: true)
                } else if isOpen || Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    enteredWaiterID = waiterID
                    enteredContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelEnteredWaiter(id: waiterID) }
        }
    }

    func expireEntryWaitIfNeeded() {
        guard !hasEntered else { return }
        open()
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true

        let entered = enteredContinuation
        enteredContinuation = nil
        enteredWaiterID = nil
        entered?.resume(returning: hasEntered)

        let open = openContinuation
        openContinuation = nil
        openWaiterID = nil
        open?.resume()
    }

    private func cancelEnteredWaiter(id: UUID) {
        guard enteredWaiterID == id else { return }
        let continuation = enteredContinuation
        enteredContinuation = nil
        enteredWaiterID = nil
        continuation?.resume(returning: false)
    }

    private func cancelOpenWaiter(id: UUID) {
        guard openWaiterID == id else { return }
        let continuation = openContinuation
        openContinuation = nil
        openWaiterID = nil
        continuation?.resume()
    }
}
