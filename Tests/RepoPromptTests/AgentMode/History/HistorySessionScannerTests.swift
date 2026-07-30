import Foundation
@testable import RepoPromptApp
import XCTest

final class HistorySessionScannerTests: XCTestCase {
    // MARK: - Test Infrastructure

    private var tempDir: URL!
    private var workspacesRoot: URL!
    private var scanner: HistorySessionScanner!
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistorySessionScannerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        workspacesRoot = tempDir.appendingPathComponent("Workspaces", isDirectory: true)
        scanner = HistorySessionScanner(applicationSupportRoot: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Workspace Discovery

    func testScanAllWorkspaces_noWorkspacesDir_returnsEmpty() async throws {
        let results = try await scanner.scanAllWorkspaces()
        XCTAssertTrue(results.isEmpty)
    }

    func testScanAllWorkspaces_emptyWorkspacesDir_returnsEmpty() async throws {
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
        let results = try await scanner.scanAllWorkspaces()
        XCTAssertTrue(results.isEmpty)
    }

    func testScanAllWorkspaces_skipsHiddenDirectories() async throws {
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
        let hiddenDir = workspacesRoot.appendingPathComponent(".hiddenWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertTrue(results.isEmpty)
    }

    func testScanAllWorkspaces_discoversSingleWorkspace() async throws {
        let wsDir = try createWorkspaceDir(name: "MyProject", uuid: UUID())
        try createAgentSessionsIndex(in: wsDir, records: [makeMinimalRecord()])

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].workspaceName, "MyProject")
        XCTAssertEqual(results[0].records.count, 1)
        XCTAssertFalse(results[0].indexReadFailed)
    }

    func testScanAllWorkspaces_discoversMultipleWorkspaces() async throws {
        let ws1 = try createWorkspaceDir(name: "ProjectA", uuid: UUID())
        let ws2 = try createWorkspaceDir(name: "ProjectB", uuid: UUID())
        try createAgentSessionsIndex(in: ws1, records: [makeMinimalRecord(name: "Session1")])
        try createAgentSessionsIndex(in: ws2, records: [makeMinimalRecord(name: "Session2"), makeMinimalRecord(name: "Session3")])

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 2)

        let totalRecords = results.reduce(0) { $0 + $1.records.count }
        XCTAssertEqual(totalRecords, 3)
    }

    func testScanAllWorkspaces_cacheInvalidatesChangedIndexAfterTTL() async throws {
        scanner = HistorySessionScanner(applicationSupportRoot: tempDir, scanCacheTTL: 0)
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let first = makeMinimalRecord(name: "First")
        try createAgentSessionsIndex(in: wsDir, records: [first])

        var results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.records.map(\.name), ["First"])

        let second = makeMinimalRecord(name: "Second")
        try createAgentSessionsIndex(in: wsDir, records: [first, second])
        let indexFile = wsDir
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("AgentSessionIndex.json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: indexFile.path
        )

        results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.records.map(\.name), ["First", "Second"])
    }

    func testScanWorkspaces_coldFifteenThousandDirectoryShapeStopsAtWorkspaceBudget() async throws {
        let directories = (0 ..< 15000).map { index in
            workspacesRoot.appendingPathComponent("Workspace-Cold-\(index)", isDirectory: true)
        }
        scanner = HistorySessionScanner(
            applicationSupportRoot: tempDir,
            inventoryBudget: HistoryInventoryBudget(
                maxWorkspaces: 128,
                maxIndexDecodes: 128,
                maxIndexBytes: 1024 * 1024,
                maxElapsed: .seconds(20)
            ),
            workspaceDirectoryProvider: { _ in directories }
        )

        let inventory = try await scanner.scanWorkspaces(matching: nil)

        let inspected = await scanner.workspaceInspectionCountForTesting
        XCTAssertEqual(inspected, 128)
        XCTAssertEqual(inventory.diagnostics.map(\.kind), [.workspaceCount])
        XCTAssertEqual(inventory.diagnostics.first?.consumed, 128)
        XCTAssertEqual(inventory.diagnostics.first?.retryable, true)
    }

    func testLocateSession_findsTargetAtOrdinal14999WithoutBroadWorkspaceCap() async throws {
        let sessionID = UUID()
        let target = try createWorkspaceDir(name: "Target", uuid: UUID())
        try writeSessionFile(
            AgentSession(id: sessionID, name: "Direct Target", transcript: .empty, itemCount: 0),
            in: target
        )
        let directories = (0 ..< 14999).map { index in
            workspacesRoot.appendingPathComponent("Workspace-Synthetic-\(index)", isDirectory: true)
        } + [target]
        scanner = HistorySessionScanner(
            applicationSupportRoot: tempDir,
            workspaceDirectoryProvider: { _ in directories }
        )

        let lookup = try await scanner.locateSession(
            sessionID: sessionID,
            requestBudget: .standalone(maxElapsed: .seconds(20))
        )

        XCTAssertTrue(lookup.isComplete)
        XCTAssertEqual(lookup.location?.workspaceDir, target)
        XCTAssertTrue(lookup.diagnostics.isEmpty)
        let statCount = await scanner.directSessionFileStatCountForTesting
        XCTAssertEqual(statCount, 15000)
    }

    func testScanWorkspaces_exactUUIDZeroFallsBackToCanonicalWorkspaceIdentity() async throws {
        let targetID = UUID()
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
        let legacyDir = workspacesRoot.appendingPathComponent("Legacy-Storage", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try writeWorkspaceJSON(in: legacyDir, name: "Canonical Target", id: targetID)
        try createAgentSessionsIndex(in: legacyDir, records: [makeMinimalRecord(name: "Target")])

        let inventory = try await scanner.scanWorkspaces(matching: targetID.uuidString)

        XCTAssertFalse(inventory.isTruncated)
        XCTAssertEqual(inventory.workspaces.map(\.workspaceID), [targetID])
        XCTAssertEqual(inventory.workspaces.flatMap(\.records).map(\.name), ["Target"])
    }

    func testScanWorkspaces_oversizedIndexReturnsTypedNonRetryablePartial() async throws {
        let wsDir = try createWorkspaceDir(name: "Oversized", uuid: UUID())
        let agentSessions = wsDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessions, withIntermediateDirectories: true)
        try Data(repeating: 0x78, count: 128).write(
            to: agentSessions.appendingPathComponent("AgentSessionIndex.json")
        )
        scanner = HistorySessionScanner(
            applicationSupportRoot: tempDir,
            inventoryBudget: HistoryInventoryBudget(
                maxWorkspaces: 10,
                maxIndexDecodes: 10,
                maxIndexBytes: 1024,
                maxIndexFileBytes: 64
            )
        )

        let inventory = try await scanner.scanWorkspaces(matching: nil)

        XCTAssertEqual(inventory.diagnostics.map(\.kind), [.indexFileBytes])
        XCTAssertEqual(inventory.diagnostics.first?.retryable, false)
        XCTAssertEqual(inventory.diagnostics.first?.consumed, 128)
        XCTAssertTrue(inventory.isTruncated)

        let cached = try await scanner.scanWorkspaces(matching: nil)
        XCTAssertEqual(cached.diagnostics, inventory.diagnostics)
        let inspected = await scanner.workspaceInspectionCountForTesting
        XCTAssertEqual(inspected, 1, "Completed discovery with a persistent per-file failure should be TTL-cached")
    }

    func testScanWorkspaces_oversizedIndexDoesNotHideLaterValidWorkspace() async throws {
        let oversized = try createWorkspaceDir(name: "Oversized", uuid: UUID())
        let oversizedSessions = oversized.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: oversizedSessions, withIntermediateDirectories: true)
        try Data(repeating: 0x78, count: 4096).write(
            to: oversizedSessions.appendingPathComponent("AgentSessionIndex.json")
        )
        let valid = try createWorkspaceDir(name: "Valid", uuid: UUID())
        try createAgentSessionsIndex(in: valid, records: [makeMinimalRecord(name: "Survives")])
        scanner = HistorySessionScanner(
            applicationSupportRoot: tempDir,
            inventoryBudget: HistoryInventoryBudget(
                maxWorkspaces: 10,
                maxIndexDecodes: 10,
                maxIndexBytes: 1024 * 1024,
                maxIndexFileBytes: 2048
            ),
            workspaceDirectoryProvider: { _ in [oversized, valid] }
        )

        let inventory = try await scanner.scanWorkspaces(matching: nil)

        XCTAssertEqual(inventory.diagnostics.map(\.kind), [.indexFileBytes])
        XCTAssertEqual(inventory.workspaces.flatMap(\.records).map(\.name), ["Survives"])
        XCTAssertEqual(inventory.workspaces.first?.indexReadFailed, true)
    }

    func testScanWorkspaces_nonDirectoryEntriesDoNotConsumeWorkspaceBudget() async throws {
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
        let files = try (0 ..< 4).map { index -> URL in
            let file = workspacesRoot.appendingPathComponent("not-a-workspace-\(index)")
            try Data("file".utf8).write(to: file)
            return file
        }
        let valid = try createWorkspaceDir(name: "Valid", uuid: UUID())
        try createAgentSessionsIndex(in: valid, records: [makeMinimalRecord(name: "Visible")])
        scanner = HistorySessionScanner(
            applicationSupportRoot: tempDir,
            inventoryBudget: HistoryInventoryBudget(
                maxWorkspaces: 1,
                maxIndexDecodes: 1,
                maxIndexBytes: 1024 * 1024
            ),
            workspaceDirectoryProvider: { _ in files + [valid] }
        )

        let inventory = try await scanner.scanWorkspaces(matching: nil)

        XCTAssertFalse(inventory.isTruncated)
        XCTAssertEqual(inventory.workspaces.flatMap(\.records).map(\.name), ["Visible"])
        let inspected = await scanner.workspaceInspectionCountForTesting
        XCTAssertEqual(inspected, 1)
    }

    func testScanWorkspaces_oversizedWorkspaceJSONFallsBackWithTypedDiagnostic() async throws {
        let workspaceID = UUID()
        let workspace = try createWorkspaceDir(name: "Fallback", uuid: workspaceID)
        try Data(repeating: 0x78, count: 128).write(to: workspace.appendingPathComponent("workspace.json"))
        try createAgentSessionsIndex(in: workspace, records: [makeMinimalRecord()])
        scanner = HistorySessionScanner(
            applicationSupportRoot: tempDir,
            inventoryBudget: HistoryInventoryBudget(
                maxWorkspaces: 10,
                maxIndexDecodes: 10,
                maxIndexBytes: 1024 * 1024,
                maxWorkspaceMetadataFileBytes: 64
            )
        )

        let inventory = try await scanner.scanWorkspaces(matching: nil)

        XCTAssertEqual(inventory.workspaces.first?.workspaceName, "Fallback")
        XCTAssertEqual(inventory.workspaces.first?.workspaceID, workspaceID)
        XCTAssertEqual(inventory.diagnostics.map(\.kind), [.workspaceMetadataFileBytes])
        XCTAssertFalse(inventory.isTruncated, "Directory-identity fallback does not hide records")

        let cached = try await scanner.scanWorkspaces(matching: nil)
        XCTAssertEqual(cached.diagnostics, inventory.diagnostics)
        let inspected = await scanner.workspaceInspectionCountForTesting
        XCTAssertEqual(inspected, 1, "Warning-only metadata fallback should retain warm inventory caching")
    }

    func testLoadSession_oversizedTranscriptFailsBeforeDecode() async throws {
        let wsDir = try createWorkspaceDir(name: "Oversized", uuid: UUID())
        let sessionID = UUID()
        try writeSessionFile(
            AgentSession(
                id: sessionID,
                name: String(repeating: "oversized", count: 64),
                transcript: .empty,
                itemCount: 0
            ),
            in: wsDir
        )
        scanner = HistorySessionScanner(
            applicationSupportRoot: tempDir,
            inventoryBudget: HistoryInventoryBudget(
                maxWorkspaces: 10,
                maxIndexDecodes: 10,
                maxIndexBytes: 1024,
                maxTranscriptFileBytes: 64
            )
        )

        do {
            _ = try await scanner.loadSessionForHistory(
                sessionID: sessionID,
                workspaceDir: wsDir,
                requestBudget: .standalone(maxTranscriptFileBytes: 64)
            )
            XCTFail("Expected transcript byte budget failure")
        } catch let error as HistorySessionScannerError {
            XCTAssertEqual(error.scanDiagnostic?.kind, .transcriptFileBytes)
            XCTAssertEqual(error.scanDiagnostic?.retryable, false)
        }
        let decodeCount = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodeCount, 0)
    }

    func testLoadSession_insufficientProportionalDecodeTimeFailsBeforeDecode() async throws {
        let workspace = try createWorkspaceDir(name: "Decode", uuid: UUID())
        let sessionID = UUID()
        try writeSessionFile(
            AgentSession(id: sessionID, name: "Decode", transcript: .empty, itemCount: 0),
            in: workspace
        )
        let clock = ContinuousClock()
        let start = clock.now
        let now = HistoryScannerNowProvider(instants: [start, start, start + .seconds(19) + .milliseconds(975)])
        let budget = HistoryRequestBudget(
            startedAt: start,
            deadline: start + .seconds(20),
            maxTurns: 100,
            yieldEveryTurns: 1,
            maxIndexBytes: 1024,
            maxIndexFileBytes: 1024,
            maxTranscriptBytes: 1024 * 1024,
            maxTranscriptFileBytes: 1024 * 1024,
            nowProvider: { now.next() }
        )

        do {
            _ = try await scanner.loadSessionForHistory(
                sessionID: sessionID,
                workspaceDir: workspace,
                requestBudget: budget
            )
            XCTFail("Expected proportional decode-time guard")
        } catch let error as HistorySessionScannerError {
            XCTAssertEqual(error.scanDiagnostic?.kind, .elapsedTime)
            XCTAssertEqual(error.scanDiagnostic?.phase, "transcript_decode")
        }
        let decodeCount = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodeCount, 0)
    }

    func testTranscriptCache_usesDeterministicByteBoundedLRUEviction() async throws {
        let wsDir = try createWorkspaceDir(name: "Cache", uuid: UUID())
        let firstID = UUID()
        let secondID = UUID()
        try writeSessionFile(
            AgentSession(id: firstID, name: "First", transcript: .empty, itemCount: 0),
            in: wsDir
        )
        try writeSessionFile(
            AgentSession(id: secondID, name: "Second", transcript: .empty, itemCount: 0),
            in: wsDir
        )
        let sessionsDir = wsDir.appendingPathComponent("AgentSessions", isDirectory: true)
        let firstSize = try FileManager.default.attributesOfItem(
            atPath: sessionsDir.appendingPathComponent("AgentSession-\(firstID.uuidString).json").path
        )[.size] as? NSNumber
        let secondSize = try FileManager.default.attributesOfItem(
            atPath: sessionsDir.appendingPathComponent("AgentSession-\(secondID.uuidString).json").path
        )[.size] as? NSNumber
        let cacheLimit = max(firstSize?.int64Value ?? 1, secondSize?.int64Value ?? 1)
        scanner = HistorySessionScanner(
            applicationSupportRoot: tempDir,
            inventoryBudget: HistoryInventoryBudget(
                maxWorkspaces: 10,
                maxIndexDecodes: 10,
                maxIndexBytes: 1024,
                maxTranscriptCacheBytes: cacheLimit
            )
        )

        _ = try await scanner.loadTranscriptForSearch(sessionID: firstID, workspaceDir: wsDir)
        _ = try await scanner.loadTranscriptForSearch(sessionID: secondID, workspaceDir: wsDir)
        _ = try await scanner.loadTranscriptForSearch(sessionID: firstID, workspaceDir: wsDir)

        let decodeCount = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodeCount, 3, "The oldest byte-budget entry must be evicted deterministically")
    }

    func testScanWorkspaces_warmInventoryCacheAvoidsRepeatedIndexDecode() async throws {
        let wsDir = try createWorkspaceDir(name: "Warm", uuid: UUID())
        try createAgentSessionsIndex(in: wsDir, records: [makeMinimalRecord()])
        scanner = HistorySessionScanner(
            applicationSupportRoot: tempDir,
            scanCacheTTL: 3600,
            inventoryBudget: HistoryInventoryBudget(
                maxWorkspaces: 10,
                maxIndexDecodes: 1,
                maxIndexBytes: 1024 * 1024,
                maxElapsed: .seconds(20)
            )
        )

        let first = try await scanner.scanWorkspaces(matching: nil)
        let second = try await scanner.scanWorkspaces(matching: nil)

        XCTAssertFalse(first.isTruncated)
        XCTAssertEqual(second.workspaces, first.workspaces)
        let decodeCount = await scanner.indexDecodeCountForTesting
        XCTAssertEqual(decodeCount, 1)
    }

    func testScanWorkspaces_midScanCancellationPropagates() async throws {
        let directories = (0 ..< 15000).map { index in
            workspacesRoot.appendingPathComponent("Workspace-Cancel-\(index)", isDirectory: true)
        }
        scanner = HistorySessionScanner(
            applicationSupportRoot: tempDir,
            inventoryBudget: HistoryInventoryBudget(
                maxWorkspaces: 20000,
                maxIndexDecodes: 20000,
                maxIndexBytes: 1024 * 1024,
                maxElapsed: .seconds(20)
            ),
            workspaceDirectoryProvider: { _ in directories }
        )

        let task = Task { try await scanner.scanWorkspaces(matching: nil) }
        for _ in 0 ..< 10000 {
            if await scanner.workspaceInspectionCountForTesting >= 32 { break }
            await Task.yield()
        }
        let inspectedBeforeCancellation = await scanner.workspaceInspectionCountForTesting
        XCTAssertGreaterThanOrEqual(inspectedBeforeCancellation, 32)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected: the directory loop observes cancellation at a cooperative checkpoint.
        }
    }

    func testScanWorkspaces_indexBudgetIsTypedRetryableAndPartialScanIsNotTTLCached() async throws {
        let ws1 = try createWorkspaceDir(name: "A", uuid: UUID())
        let ws2 = try createWorkspaceDir(name: "B", uuid: UUID())
        try createAgentSessionsIndex(in: ws1, records: [makeMinimalRecord(name: "A")])
        try createAgentSessionsIndex(in: ws2, records: [makeMinimalRecord(name: "B")])
        scanner = HistorySessionScanner(
            applicationSupportRoot: tempDir,
            scanCacheTTL: 3600,
            inventoryBudget: HistoryInventoryBudget(
                maxWorkspaces: 10,
                maxIndexDecodes: 1,
                maxIndexBytes: 1024 * 1024,
                maxElapsed: .seconds(20)
            )
        )

        let partial = try await scanner.scanWorkspaces(matching: nil)
        XCTAssertEqual(partial.diagnostics.map(\.kind), [.indexCount])
        XCTAssertEqual(partial.diagnostics.first?.retryable, true)
        let decodeCount = await scanner.indexDecodeCountForTesting
        XCTAssertEqual(decodeCount, 1)

        // The first index is now signature-cached, so a retry can decode the remaining
        // index within the same per-call budget. A truncated inventory must not poison TTL.
        let retry = try await scanner.scanWorkspaces(matching: nil)
        XCTAssertFalse(retry.isTruncated)
        XCTAssertEqual(retry.workspaces.flatMap(\.records).count, 2)
        let decodeCountAfterRetry = await scanner.indexDecodeCountForTesting
        XCTAssertEqual(decodeCountAfterRetry, 2)
    }

    func testScanWorkspaces_exactWorkspaceUUIDPreNarrowsColdIndexWork() async throws {
        let targetID = UUID()
        let target = try createWorkspaceDir(name: "Target", uuid: targetID)
        let other = try createWorkspaceDir(name: "Other", uuid: UUID())
        try createAgentSessionsIndex(in: target, records: [makeMinimalRecord(name: "Target")])
        try createAgentSessionsIndex(in: other, records: [makeMinimalRecord(name: "Other")])

        let inventory = try await scanner.scanWorkspaces(matching: targetID.uuidString)

        XCTAssertEqual(inventory.workspaces.map(\.workspaceID), [targetID])
        let decodeCount = await scanner.indexDecodeCountForTesting
        XCTAssertEqual(decodeCount, 1)
    }

    func testIndexScanCache_repeatedExactScopesStayEntryAndByteBounded() async throws {
        let workspaceIDs = [UUID(), UUID(), UUID()]
        for (index, id) in workspaceIDs.enumerated() {
            let workspace = try createWorkspaceDir(name: "Exact\(index)", uuid: id)
            try createAgentSessionsIndex(in: workspace, records: [makeMinimalRecord(name: "S\(index)")])
        }
        scanner = HistorySessionScanner(
            applicationSupportRoot: tempDir,
            scanCacheTTL: 0,
            inventoryBudget: HistoryInventoryBudget(
                maxWorkspaces: 10,
                maxIndexDecodes: 10,
                maxIndexBytes: 1024 * 1024,
                maxIndexCacheEntries: 2,
                maxIndexCacheBytes: 1024 * 1024
            )
        )

        for id in workspaceIDs {
            _ = try await scanner.scanWorkspaces(matching: id.uuidString)
        }
        let entryCount = await scanner.indexScanCacheEntryCountForTesting
        let cacheBytes = await scanner.indexScanCacheBytesForTesting
        XCTAssertEqual(entryCount, 2)
        XCTAssertLessThanOrEqual(cacheBytes, 1024 * 1024)

        _ = try await scanner.scanWorkspaces(matching: workspaceIDs[0].uuidString)
        let decodeCount = await scanner.indexDecodeCountForTesting
        XCTAssertEqual(decodeCount, 4, "The deterministic LRU must evict the oldest exact scope")
    }

    func testIndexScanCache_repeatedPartialScansStayBounded() async throws {
        var workspaces: [URL] = []
        for index in 0 ..< 3 {
            let workspace = try createWorkspaceDir(name: "Partial\(index)", uuid: UUID())
            try createAgentSessionsIndex(in: workspace, records: [makeMinimalRecord(name: "S\(index)")])
            workspaces.append(workspace)
        }
        let rotations = HistoryRotatingWorkspaceProvider(values: workspaces.map { first in
            [first] + workspaces.filter { $0 != first }
        })
        scanner = HistorySessionScanner(
            applicationSupportRoot: tempDir,
            scanCacheTTL: 3600,
            inventoryBudget: HistoryInventoryBudget(
                maxWorkspaces: 1,
                maxIndexDecodes: 1,
                maxIndexBytes: 1024 * 1024,
                maxIndexCacheEntries: 2,
                maxIndexCacheBytes: 1024 * 1024
            ),
            workspaceDirectoryProvider: { _ in rotations.next() }
        )

        for _ in 0 ..< 3 {
            let partial = try await scanner.scanWorkspaces(matching: nil)
            XCTAssertEqual(partial.diagnostics.last?.kind, .workspaceCount)
        }

        let entryCount = await scanner.indexScanCacheEntryCountForTesting
        let cacheBytes = await scanner.indexScanCacheBytesForTesting
        XCTAssertEqual(entryCount, 2)
        XCTAssertLessThanOrEqual(cacheBytes, 1024 * 1024)
    }

    func testInventoryScanGate_cancelledWaitersLeaveNoTombstonesAndReleaseFIFO() async throws {
        let gate = HistoryInventoryScanGate()
        let holder = try await gate.acquire()
        let waiters = (0 ..< 100).map { _ in
            Task {
                let lease = try await gate.acquire()
                await gate.release(lease)
            }
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        waiters.forEach { $0.cancel() }
        await gate.release(holder)
        for waiter in waiters {
            do {
                try await waiter.value
            } catch is CancellationError {
                // Expected for queued waiters.
            }
        }

        let snapshot = await gate.snapshotForTesting()
        XCTAssertFalse(snapshot.hasHolder)
        XCTAssertEqual(snapshot.waiterCount, 0)
    }

    func testScanAllWorkspaces_workspaceWithoutAgentSessionsDir() async throws {
        _ = try createWorkspaceDir(name: "EmptyProject", uuid: UUID())
        // No AgentSessions directory created

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].records.isEmpty)
        XCTAssertFalse(results[0].indexReadFailed)
    }

    func testScanAllWorkspaces_workspaceWithoutIndexFile() async throws {
        let wsDir = try createWorkspaceDir(name: "NoIndex", uuid: UUID())
        let agentSessions = wsDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessions, withIntermediateDirectories: true)
        // No AgentSessionIndex.json created

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].records.isEmpty)
        XCTAssertFalse(results[0].indexReadFailed)
    }

    func testScanAllWorkspaces_corruptIndexFile_reportsReadFailed() async throws {
        let wsDir = try createWorkspaceDir(name: "Corrupt", uuid: UUID())
        let agentSessions = wsDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessions, withIntermediateDirectories: true)
        let indexFile = agentSessions.appendingPathComponent("AgentSessionIndex.json")
        try Data("{ invalid json".utf8).write(to: indexFile)

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].records.isEmpty)
        XCTAssertTrue(results[0].indexReadFailed)
    }

    // MARK: - Workspace Name Resolution

    func testWorkspaceNameResolution_fromWorkspaceJSON() async throws {
        let wsUUID = UUID()
        let wsDir = try createWorkspaceDir(name: "MyProject", uuid: wsUUID)
        try writeWorkspaceJSON(in: wsDir, name: "Canonical Name", id: wsUUID)
        try createAgentSessionsIndex(in: wsDir, records: [])

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].workspaceName, "Canonical Name")
        XCTAssertEqual(results[0].workspaceID, wsUUID)
    }

    func testWorkspaceNameResolution_fromDirNameWithoutJSON() async throws {
        let wsUUID = UUID()
        let wsDir = try createWorkspaceDir(name: "MyProject", uuid: wsUUID)
        // No workspace.json — name parsed from directory name
        try createAgentSessionsIndex(in: wsDir, records: [])

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].workspaceName, "MyProject")
        XCTAssertEqual(results[0].workspaceID, wsUUID)
    }

    func testWorkspaceNameResolution_dirNameWithoutUUID() async throws {
        let wsDir = try XCTUnwrap(workspacesRoot?.appendingPathComponent("Workspace-SimpleName", isDirectory: true))
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        try createAgentSessionsIndex(in: wsDir, records: [])

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].workspaceName, "SimpleName")
        XCTAssertNil(results[0].workspaceID)
    }

    func testWorkspaceNameResolution_nonStandardDirName() async throws {
        let wsDir = try XCTUnwrap(workspacesRoot?.appendingPathComponent("CustomDirectoryName", isDirectory: true))
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        try createAgentSessionsIndex(in: wsDir, records: [])

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].workspaceName, "CustomDirectoryName")
        XCTAssertNil(results[0].workspaceID)
    }

    // MARK: - Metadata Filtering

    func testSessionsMatchingFilters_noFilters_returnsAll() async throws {
        let ws1 = try createWorkspaceDir(name: "ProjectA", uuid: UUID())
        let ws2 = try createWorkspaceDir(name: "ProjectB", uuid: UUID())
        let r1 = makeMinimalRecord(name: "Session1", agentKindRaw: "claudeCode")
        let r2 = makeMinimalRecord(name: "Session2", agentKindRaw: "codexExec")
        let r3 = makeMinimalRecord(name: "Session3", agentKindRaw: "claudeCode")
        try createAgentSessionsIndex(in: ws1, records: [r1, r2])
        try createAgentSessionsIndex(in: ws2, records: [r3])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = scanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: nil, model: nil, filePath: nil, from: nil, to: nil)

        XCTAssertEqual(filtered.count, 3)
    }

    func testSessionsMatchingFilters_byWorkspaceName() async throws {
        let ws1 = try createWorkspaceDir(name: "ProjectA", uuid: UUID())
        let ws2 = try createWorkspaceDir(name: "ProjectB", uuid: UUID())
        let r1 = makeMinimalRecord(name: "Session1")
        let r2 = makeMinimalRecord(name: "Session2")
        try createAgentSessionsIndex(in: ws1, records: [r1])
        try createAgentSessionsIndex(in: ws2, records: [r2])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = scanner.sessionsMatchingFilters(scanResults, workspace: "projecta", agentKind: nil, model: nil, filePath: nil, from: nil, to: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, r1.id)
    }

    func testSessionsMatchingFilters_byWorkspaceStorageDirectoryName() async throws {
        let wsUUID = UUID()
        let ws1 = try createWorkspaceDir(name: "RepoPromptCE", uuid: wsUUID)
        let ws2 = try createWorkspaceDir(name: "OtherProject", uuid: UUID())
        let r1 = makeMinimalRecord(name: "Session1")
        let r2 = makeMinimalRecord(name: "Session2")
        try createAgentSessionsIndex(in: ws1, records: [r1])
        try createAgentSessionsIndex(in: ws2, records: [r2])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = scanner.sessionsMatchingFilters(
            scanResults,
            workspace: "Workspace-RepoPromptCE-",
            agentKind: nil,
            model: nil,
            filePath: nil,
            from: nil,
            to: nil
        )

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, r1.id)
    }

    func testSessionsMatchingFilters_byWorkspaceUUID() async throws {
        let wsUUID = UUID()
        let ws1 = try createWorkspaceDir(name: "ProjectA", uuid: wsUUID)
        let ws2 = try createWorkspaceDir(name: "ProjectB", uuid: UUID())
        let r1 = makeMinimalRecord(name: "Session1")
        let r2 = makeMinimalRecord(name: "Session2")
        try createAgentSessionsIndex(in: ws1, records: [r1])
        try createAgentSessionsIndex(in: ws2, records: [r2])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = scanner.sessionsMatchingFilters(scanResults, workspace: wsUUID.uuidString, agentKind: nil, model: nil, filePath: nil, from: nil, to: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, r1.id)
    }

    func testSessionsMatchingFilters_byAgentKind() async throws {
        let ws = try createWorkspaceDir(name: "Project", uuid: UUID())
        let r1 = makeMinimalRecord(name: "Session1", agentKindRaw: "claudeCode")
        let r2 = makeMinimalRecord(name: "Session2", agentKindRaw: "codexExec")
        let r3 = makeMinimalRecord(name: "Session3", agentKindRaw: nil)
        try createAgentSessionsIndex(in: ws, records: [r1, r2, r3])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = scanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: "claude", model: nil, filePath: nil, from: nil, to: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, r1.id)
    }

    func testSessionsMatchingFilters_byModel() async throws {
        let ws = try createWorkspaceDir(name: "Project", uuid: UUID())
        let r1 = makeMinimalRecord(name: "S1", agentModelRaw: "claude-sonnet-4-20250514")
        let r2 = makeMinimalRecord(name: "S2", agentModelRaw: "claude-opus-4-20250116")
        let r3 = makeMinimalRecord(name: "S3", agentModelRaw: nil)
        try createAgentSessionsIndex(in: ws, records: [r1, r2, r3])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = scanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: nil, model: "opus", filePath: nil, from: nil, to: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, r2.id)
    }

    func testSessionsMatchingFilters_byFilePath() async throws {
        let ws = try createWorkspaceDir(name: "Project", uuid: UUID())
        let r1 = makeMinimalRecord(name: "S1", keyPaths: ["src/main.swift", "lib/utils.swift"])
        let r2 = makeMinimalRecord(name: "S2", keyPaths: ["docs/README.md"])
        let r3 = makeMinimalRecord(name: "S3", keyPaths: [])
        try createAgentSessionsIndex(in: ws, records: [r1, r2, r3])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = scanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: nil, model: nil, filePath: "main.swift", from: nil, to: nil)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, r1.id)
    }

    func testSessionsMatchingFilters_filePathCaseInsensitive() async throws {
        let ws = try createWorkspaceDir(name: "Project", uuid: UUID())
        let r1 = makeMinimalRecord(name: "S1", keyPaths: ["Sources/Main.swift"])
        try createAgentSessionsIndex(in: ws, records: [r1])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = scanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: nil, model: nil, filePath: "main.SWIFT", from: nil, to: nil)

        XCTAssertEqual(filtered.count, 1)
    }

    func testSessionsMatchingFilters_byDateRange() async throws {
        let ws = try createWorkspaceDir(name: "Project", uuid: UUID())
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let r1 = makeMinimalRecord(name: "S1", savedAt: epoch)
        let r2 = makeMinimalRecord(name: "S2", savedAt: epoch.addingTimeInterval(3600))
        let r3 = makeMinimalRecord(name: "S3", savedAt: epoch.addingTimeInterval(7200))
        try createAgentSessionsIndex(in: ws, records: [r1, r2, r3])

        let scanResults = try await scanner.scanAllWorkspaces()
        let from = epoch.addingTimeInterval(1800) // 30min in
        let to = epoch.addingTimeInterval(5400) // 90min in

        let filtered = scanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: nil, model: nil, filePath: nil, from: from, to: to)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, r2.id)
    }

    func testSessionsMatchingFilters_dateRangeUsesTranscriptBoundsNotSidebarDate() async throws {
        // firstActivityAt/lastActivityAt (transcript bounds) differ from activityDate
        // (lastUserMessageAt ?? savedAt). The filter must use the transcript bounds so it
        // agrees with the response's first_activity_at / last_activity_at fields.
        let ws = try createWorkspaceDir(name: "Project", uuid: UUID())
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let record = AgentSessionMetadataRecord(
            id: UUID(),
            filename: "AgentSession-bounds.json",
            workspaceID: nil,
            composeTabID: nil,
            name: "S1",
            savedAt: savedAt,
            lastUserMessageAt: nil, // → activityDate == savedAt
            itemCount: 1,
            transcriptProjectionCounts: nil,
            hasUnknownConversationContent: false,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            lastRunStateRaw: nil,
            autoEditEnabled: true,
            parentSessionID: nil,
            isMCPOriginated: false,
            serializationVersion: nil,
            observedFileSize: nil,
            observedFileModificationDate: nil,
            lastIndexedAt: savedAt,
            firstActivityAt: savedAt.addingTimeInterval(-300), // 5 min before savedAt
            lastActivityAt: savedAt.addingTimeInterval(-60), // 1 min before savedAt
            keyPaths: [],
            coveredTurnDurationSeconds: 0,
            toolCallCount: 0
        )
        try createAgentSessionsIndex(in: ws, records: [record])
        let scanResults = try await scanner.scanAllWorkspaces()

        // Window brackets the transcript activity bounds but excludes savedAt (the old
        // activityDate-based filter would drop this session).
        let from = try XCTUnwrap(record.firstActivityAt?.addingTimeInterval(-10))
        let to = try XCTUnwrap(record.lastActivityAt?.addingTimeInterval(10))
        let filtered = scanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: nil, model: nil, filePath: nil, from: from, to: to)

        XCTAssertEqual(filtered.count, 1, "filter should use transcript activity bounds, not the sidebar date")
        XCTAssertEqual(filtered.first?.sessionID, record.id)
    }

    func testSessionsMatchingFilters_combinedFilters() async throws {
        let ws = try createWorkspaceDir(name: "Project", uuid: UUID())
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let r1 = makeMinimalRecord(name: "S1", agentKindRaw: "claudeCode", keyPaths: ["src/main.swift"], savedAt: epoch)
        let r2 = makeMinimalRecord(name: "S2", agentKindRaw: "claudeCode", keyPaths: ["docs/readme.md"], savedAt: epoch)
        let r3 = makeMinimalRecord(name: "S3", agentKindRaw: "codexExec", keyPaths: ["src/main.swift"], savedAt: epoch)
        try createAgentSessionsIndex(in: ws, records: [r1, r2, r3])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = scanner.sessionsMatchingFilters(
            scanResults,
            workspace: nil,
            agentKind: "claudeCode",
            model: nil,
            filePath: "main.swift",
            from: nil,
            to: nil
        )

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, r1.id)
    }

    func testSessionsMatchingFilters_emptyScanResults() {
        let filtered = scanner.sessionsMatchingFilters(
            [],
            workspace: "anything",
            agentKind: nil,
            model: nil,
            filePath: nil,
            from: nil,
            to: nil
        )
        XCTAssertTrue(filtered.isEmpty)
    }

    // MARK: - Transcript Loading

    func testLoadTranscriptForSearch_validSession() async throws {
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let sessionID = UUID()

        let turn = AgentTranscriptTurn(
            id: UUID(),
            summary: AgentTranscriptTurnSummary(
                requestText: "Fix the bug",
                conclusionText: nil,
                compactConclusionText: "Fixed the bug in main.swift",
                middleSummaryText: nil,
                toolCount: 2,
                notableToolNames: ["apply_edits"],
                keyPaths: ["src/main.swift"],
                compactedActivityCount: 0,
                hadWarning: false,
                hadError: false
            ),
            startedAt: Date(timeIntervalSince1970: 100),
            completedAt: Date(timeIntervalSince1970: 200)
        )
        let transcript = AgentTranscript(turns: [turn])
        let session = AgentSession(
            id: sessionID,
            name: "Test Session",
            transcript: transcript,
            itemCount: 1
        )
        try writeSessionFile(session, in: wsDir)

        let loaded = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
        XCTAssertEqual(loaded.turns.count, 1)
        XCTAssertEqual(loaded.turns[0].summary?.keyPaths, ["src/main.swift"])
    }

    func testLoadTranscriptForSearch_missingFile_throwsError() async throws {
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let sessionID = UUID()

        do {
            _ = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
            XCTFail("Expected error to be thrown")
        } catch let error as HistorySessionScannerError {
            if case .sessionFileNotFound = error {
                // Expected
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testLoadTranscriptForSearch_corruptFile_throwsError() async throws {
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let sessionID = UUID()
        let agentSessions = wsDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessions, withIntermediateDirectories: true)
        let file = agentSessions.appendingPathComponent("AgentSession-\(sessionID.uuidString).json")
        try Data("{ bad".utf8).write(to: file)

        do {
            _ = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
            XCTFail("Expected error to be thrown")
        } catch let error as HistorySessionScannerError {
            if case .transcriptDecodingFailed = error {
                // Expected
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLoadTranscriptForSearch_sessionWithoutTranscript_returnsEmpty() async throws {
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let sessionID = UUID()
        let session = AgentSession(
            id: sessionID,
            name: "Empty Session",
            transcript: nil,
            itemCount: 0
        )
        try writeSessionFile(session, in: wsDir)

        let loaded = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
        XCTAssertTrue(loaded.turns.isEmpty)
    }

    func testLoadTranscriptForSearch_cachesTranscriptAcrossCalls() async throws {
        // F5: a transcript decoded once is reused on the next load when the session
        // file is unchanged — the decode counter must not increment on the cache hit.
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let sessionID = UUID()
        let session = AgentSession(
            id: sessionID,
            name: "S",
            transcript: AgentTranscript(turns: [AgentTranscriptTurn(startedAt: Date(timeIntervalSince1970: 1000))]),
            itemCount: 1
        )
        try writeSessionFile(session, in: wsDir)

        let first = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
        XCTAssertEqual(first.turns.count, 1)
        let decodedAfterFirst = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodedAfterFirst, 1)

        // Second load, file unchanged → served from the signature cache; no re-decode.
        let cached = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
        XCTAssertEqual(cached.turns.count, 1)
        let decodedAfterSecond = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodedAfterSecond, 1, "Unchanged file must hit the cache (no re-decode)")
    }

    func testLoadTranscriptForSearch_invalidatesCacheWhenSessionFileChanges() async throws {
        // F5: modifying the session file (size+mtime change) must invalidate the cache
        // and re-decode on the next load.
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let sessionID = UUID()
        func writeTranscript(_ turnCount: Int) throws {
            let turns = (0 ..< turnCount).map { AgentTranscriptTurn(startedAt: Date(timeIntervalSince1970: 1000).addingTimeInterval(TimeInterval($0))) }
            try writeSessionFile(AgentSession(id: sessionID, name: "S", transcript: AgentTranscript(turns: turns), itemCount: turnCount), in: wsDir)
        }
        try writeTranscript(1)
        let first = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
        XCTAssertEqual(first.turns.count, 1)
        let decodedAfterFirst = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodedAfterFirst, 1)

        // Rewrite with more turns → different size+mtime → signature changes → re-decode.
        try writeTranscript(3)
        let refreshed = try await scanner.loadTranscriptForSearch(sessionID: sessionID, workspaceDir: wsDir)
        XCTAssertEqual(refreshed.turns.count, 3, "Changed file must re-decode (cache invalidated)")
        let decodedAfterRefresh = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(decodedAfterRefresh, 2)
    }

    func testScanAllWorkspacesRefreshing_bypassesTTLCacheAndRepopulates() async throws {
        // F6 mechanism: `scanAllWorkspacesRefreshing()` forces a fresh scan, ignoring the
        // TTL cache, while the cached scan still hides a freshly-saved session; and the
        // refresh repopulates the cache so later cached scans see it too.
        let wsDir = try createWorkspaceDir(name: "Project", uuid: UUID())
        let sessionA = UUID()
        try createAgentSessionsIndex(in: wsDir, records: [makeMinimalRecord(id: sessionA, name: "A")])

        let cachedScanner = HistorySessionScanner(applicationSupportRoot: tempDir, scanCacheTTL: 3600)
        _ = try await cachedScanner.scanAllWorkspaces() // warm the cache with [A]

        // App saves B: writes its file + updates the index.
        let sessionB = UUID()
        try writeSessionFile(AgentSession(id: sessionB, name: "B", transcript: nil, itemCount: 0), in: wsDir)
        try createAgentSessionsIndex(in: wsDir, records: [makeMinimalRecord(id: sessionA, name: "A"), makeMinimalRecord(id: sessionB, name: "B")])

        let cachedIDs = try await Set(cachedScanner.scanAllWorkspaces().flatMap(\.records).map(\.id))
        XCTAssertFalse(cachedIDs.contains(sessionB), "Cached scan within TTL hides the freshly-saved session")

        let refreshedIDs = try await Set(cachedScanner.scanAllWorkspacesRefreshing().flatMap(\.records).map(\.id))
        XCTAssertTrue(refreshedIDs.contains(sessionB), "Refreshing scan bypasses the TTL and sees the freshly-saved session")

        let postRefreshCachedIDs = try await Set(cachedScanner.scanAllWorkspaces().flatMap(\.records).map(\.id))
        XCTAssertTrue(postRefreshCachedIDs.contains(sessionB), "Refreshing repopulates the cache so later cached scans see B")
    }

    // MARK: - Cross-Workspace Unification

    func testScanAllWorkspaces_recordsIncludeWorkspaceContext() async throws {
        let wsUUID1 = UUID()
        let wsUUID2 = UUID()
        let ws1 = try createWorkspaceDir(name: "Alpha", uuid: wsUUID1)
        let ws2 = try createWorkspaceDir(name: "Beta", uuid: wsUUID2)
        let r1 = makeMinimalRecord(name: "S1")
        let r2 = makeMinimalRecord(name: "S2")
        try createAgentSessionsIndex(in: ws1, records: [r1])
        try createAgentSessionsIndex(in: ws2, records: [r2])

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = scanner.sessionsMatchingFilters(scanResults, workspace: nil, agentKind: nil, model: nil, filePath: nil, from: nil, to: nil)

        XCTAssertEqual(filtered.count, 2, "Expected 2 filtered records, got \(filtered.count)")
        let scanNames = scanResults.map(\.workspaceName)
        XCTAssertEqual(scanNames.sorted(), ["Alpha", "Beta"], "Scan result workspace names")

        let names = Set(filtered.map(\.workspaceName))
        XCTAssertEqual(names, Set(["Alpha", "Beta"]), "Filtered workspace names")

        let dirs = Set(filtered.map(\.workspaceDir.standardizedFileURL))
        XCTAssertTrue(dirs.contains(ws1.standardizedFileURL))
        XCTAssertTrue(dirs.contains(ws2.standardizedFileURL))
    }

    // MARK: - Stale Schema

    func testScanAllWorkspaces_staleSchemaVersion_returnsEmptyRecordsForWorkspace() async throws {
        let wsDir = try createWorkspaceDir(name: "StaleProject", uuid: UUID())
        let record = makeMinimalRecord(name: "OldSession")

        // Write an index with schemaVersion 3 (current is 5).
        let agentSessions = wsDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessions, withIntermediateDirectories: true)
        let staleIndex = AgentSessionMetadataIndex(
            schemaVersion: 3,
            entries: [record]
        )
        let data = try encoder.encode(staleIndex)
        let indexFile = agentSessions.appendingPathComponent("AgentSessionIndex.json")
        try data.write(to: indexFile, options: .atomic)

        let results = try await scanner.scanAllWorkspaces()
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].records.isEmpty, "Stale-schema workspace should have empty records")
        XCTAssertFalse(results[0].indexReadFailed)
        XCTAssertEqual(results[0].indexSchemaVersion, 3)
    }

    func testSessionsMatchingFilters_skipsStaleSchemaWorkspace() async throws {
        // Current-schema workspace with a session.
        let currentWS = try createWorkspaceDir(name: "CurrentProject", uuid: UUID())
        let currentRecord = makeMinimalRecord(name: "CurrentSession")
        try createAgentSessionsIndex(in: currentWS, records: [currentRecord])

        // Stale-schema workspace with a session (should be excluded from filtering).
        let staleWS = try createWorkspaceDir(name: "StaleProject", uuid: UUID())
        let staleRecord = makeMinimalRecord(name: "StaleSession")
        let staleAgentSessions = staleWS.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: staleAgentSessions, withIntermediateDirectories: true)
        let staleIndex = AgentSessionMetadataIndex(schemaVersion: 3, entries: [staleRecord])
        try encoder.encode(staleIndex).write(
            to: staleAgentSessions.appendingPathComponent("AgentSessionIndex.json"),
            options: .atomic
        )

        let scanResults = try await scanner.scanAllWorkspaces()
        let filtered = scanner.sessionsMatchingFilters(
            scanResults,
            workspace: nil,
            agentKind: nil,
            model: nil,
            filePath: nil,
            from: nil,
            to: nil
        )

        // Only the current-schema workspace's session should appear.
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, currentRecord.id)
        XCTAssertEqual(filtered[0].workspaceName, "CurrentProject")
    }

    // MARK: - Helpers

    private func createWorkspaceDir(name: String, uuid: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
        let dirName = "Workspace-\(name)-\(uuid.uuidString)"
        let wsDir = workspacesRoot.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        return wsDir
    }

    private func createAgentSessionsIndex(
        in workspaceDir: URL,
        records: [AgentSessionMetadataRecord]
    ) throws {
        let agentSessions = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessions, withIntermediateDirectories: true)

        let index = AgentSessionMetadataIndex(
            schemaVersion: AgentSessionMetadataIndex.currentSchemaVersion,
            entries: records
        )
        let data = try encoder.encode(index)
        let indexFile = agentSessions.appendingPathComponent("AgentSessionIndex.json")
        try data.write(to: indexFile, options: .atomic)
    }

    private func writeWorkspaceJSON(in workspaceDir: URL, name: String, id: UUID) throws {
        let json: [String: Any] = ["name": name, "id": id.uuidString]
        let data = try JSONSerialization.data(withJSONObject: json)
        let file = workspaceDir.appendingPathComponent("workspace.json")
        try data.write(to: file, options: .atomic)
    }

    private func writeSessionFile(_ session: AgentSession, in workspaceDir: URL) throws {
        let agentSessions = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agentSessions, withIntermediateDirectories: true)
        let filename = "AgentSession-\(session.id.uuidString).json"
        let fileURL = agentSessions.appendingPathComponent(filename)
        let data = try encoder.encode(session)
        try data.write(to: fileURL, options: .atomic)
    }

    private func makeMinimalRecord(
        id: UUID = UUID(),
        name: String = "Test Session",
        agentKindRaw: String? = nil,
        agentModelRaw: String? = nil,
        keyPaths: Set<String> = [],
        activeDurationSeconds: Int = 0,
        savedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> AgentSessionMetadataRecord {
        AgentSessionMetadataRecord(
            id: id,
            filename: "AgentSession-\(id.uuidString).json",
            workspaceID: nil,
            composeTabID: nil,
            name: name,
            savedAt: savedAt,
            lastUserMessageAt: nil,
            itemCount: 1,
            transcriptProjectionCounts: nil,
            hasUnknownConversationContent: false,
            agentKindRaw: agentKindRaw,
            agentModelRaw: agentModelRaw,
            agentReasoningEffortRaw: nil,
            lastRunStateRaw: nil,
            autoEditEnabled: true,
            parentSessionID: nil,
            isMCPOriginated: false,
            serializationVersion: nil,
            observedFileSize: nil,
            observedFileModificationDate: nil,
            lastIndexedAt: savedAt,
            keyPaths: keyPaths,
            coveredTurnDurationSeconds: activeDurationSeconds
        )
    }
}

private final class HistoryScannerNowProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let instants: [ContinuousClock.Instant]
    private var index = 0

    init(instants: [ContinuousClock.Instant]) {
        precondition(!instants.isEmpty)
        self.instants = instants
    }

    func next() -> ContinuousClock.Instant {
        lock.withLock {
            defer { index += 1 }
            return instants[min(index, instants.count - 1)]
        }
    }
}

private final class HistoryRotatingWorkspaceProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [[URL]]
    private var index = 0

    init(values: [[URL]]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    func next() -> [URL] {
        lock.withLock {
            defer { index += 1 }
            return values[min(index, values.count - 1)]
        }
    }
}
