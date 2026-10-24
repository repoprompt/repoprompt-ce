import Foundation
@testable import RepoPromptApp
import XCTest

final class HistoryAnalyticsTests: XCTestCase {
    func testDurationUsesProviderCoverageButExcludesLongPauseInsideOneTurn() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let resumed = start.addingTimeInterval(86400)
        let turn = AgentTranscriptTurn(
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    lifecycle: .completed,
                    startedAt: start,
                    lastActivityAt: start.addingTimeInterval(120),
                    completedAt: start.addingTimeInterval(120)
                ),
                AgentTranscriptProviderResponseSpan(
                    lifecycle: .completed,
                    startedAt: resumed,
                    lastActivityAt: resumed.addingTimeInterval(60),
                    completedAt: resumed.addingTimeInterval(60)
                )
            ],
            terminalState: .completed,
            startedAt: start,
            lastActivityAt: resumed.addingTimeInterval(60),
            completedAt: resumed.addingTimeInterval(60)
        )

        let primitives = AgentSessionMetadataRecord.computeDurationPrimitives(from: [turn])

        XCTAssertEqual(primitives.coveredSeconds, 180)
        XCTAssertEqual(primitives.gapSeconds, [86280])
        XCTAssertEqual(
            AgentSessionMetadataRecord.activeDurationSeconds(
                intervals: AgentSessionMetadataRecord.activityIntervals(from: turn),
                thresholdMinutes: 10
            ),
            180
        )
    }

    func testTranscriptTurnCountIsIndependentFromProjectedItemCount() {
        let record = makeRecord(id: UUID(), freshness: 1, itemCount: 275)
        let enriched = record.enrichingTranscriptDerivedFields(from: [
            AgentTranscriptTurn(startedAt: Date(timeIntervalSinceReferenceDate: 1)),
            AgentTranscriptTurn(startedAt: Date(timeIntervalSinceReferenceDate: 2))
        ])

        XCTAssertEqual(enriched.transcriptTurnCount, 2)
        XCTAssertEqual(enriched.itemCount, 275)
    }

    func testCrossWorkspaceFilteringDeduplicatesSessionIDUsingFreshestProjection() {
        let sessionID = UUID()
        let stale = makeRecord(id: sessionID, freshness: 1, itemCount: 10)
        let fresh = makeRecord(id: sessionID, freshness: 2, itemCount: 20)
        let scanner = HistorySessionScanner(applicationSupportRoot: URL(fileURLWithPath: "/tmp/history-tests"))

        let matches = scanner.sessionsMatchingFilters(
            [
                HistoryWorkspaceScanResult(
                    workspaceDir: URL(fileURLWithPath: "/tmp/workspace-a"),
                    workspaceName: "A",
                    workspaceID: UUID(),
                    records: [stale],
                    indexReadFailed: false,
                    indexSchemaVersion: nil
                ),
                HistoryWorkspaceScanResult(
                    workspaceDir: URL(fileURLWithPath: "/tmp/workspace-b"),
                    workspaceName: "B",
                    workspaceID: UUID(),
                    records: [fresh],
                    indexReadFailed: false,
                    indexSchemaVersion: nil
                )
            ],
            workspace: nil,
            agentKind: nil,
            model: nil,
            filePath: nil,
            from: nil,
            to: nil
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.workspaceName, "B")
        XCTAssertEqual(matches.first?.record.itemCount, 20)
    }

    func testTokenUsageAttributionIsBackwardCompatibleAndRoundTripsIDs() throws {
        let legacy = AgentTokenUsagePersist(promptTokens: 11, completionTokens: 7)
        let legacyDecoded = try JSONDecoder().decode(
            AgentTokenUsagePersist.self,
            from: JSONEncoder().encode(legacy)
        )
        XCTAssertNil(legacyDecoded.runID)
        XCTAssertNil(legacyDecoded.turnID)

        let runID = UUID()
        let turnID = UUID()
        let attributed = AgentTokenUsagePersist(
            runID: runID,
            turnID: turnID,
            promptTokens: 13,
            completionTokens: 5,
            estimatedToolInputTokens: 3,
            estimatedToolOutputTokens: 2
        )
        let decoded = try JSONDecoder().decode(
            AgentTokenUsagePersist.self,
            from: JSONEncoder().encode(attributed)
        )

        XCTAssertEqual(decoded.runID, runID)
        XCTAssertEqual(decoded.turnID, turnID)
        XCTAssertEqual(decoded.estimatedToolInputTokens, 3)
        XCTAssertEqual(decoded.estimatedToolOutputTokens, 2)
    }

    func testMissingIndexNeverProvesEmptyWhenSessionStorageExists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MissingHistoryIndex-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for containsSession in [false, true] {
            let workspaceID = UUID()
            let folder = root.appendingPathComponent("Workspaces", isDirectory: true)
                .appendingPathComponent(WorkspaceDirectoryName.directoryName(name: "Unindexed", id: workspaceID), isDirectory: true)
                .appendingPathComponent("AgentSessions", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if containsSession {
                // Discovery must not open even this deliberately undecodable transcript.
                try Data("not a transcript".utf8).write(to: folder.appendingPathComponent("AgentSession-\(UUID()).json"))
            }
            let scanner = HistorySessionScanner(applicationSupportRoot: root)
            let scan = try await scanner.scanWorkspaces(matching: workspaceID.uuidString)
            XCTAssertTrue(scan.isTruncated, "existing storage without an index has unknown coverage")
            XCTAssertEqual(scan.workspaces.map(\.indexReadFailed), [true])
            XCTAssertEqual(scan.diagnostics.map(\.phase), ["index_missing"])
            let reply = try await HistoryMCPToolService.execute(
                args: ["op": .string("list_sessions"), "workspace": .string(workspaceID.uuidString)], scanner: scanner
            )
            guard case let .listSessions(list) = reply else { return XCTFail("expected list reply") }
            XCTAssertEqual(list.scanTruncated, true)
            XCTAssertEqual(list.totalsAreLowerBounds, true)
            let transcriptReads = await scanner.transcriptDecodeCountForTesting
            XCTAssertEqual(transcriptReads, 0)
        }
        let emptyID = UUID()
        let emptyWorkspace = root.appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent(WorkspaceDirectoryName.directoryName(name: "Empty", id: emptyID), isDirectory: true)
        try FileManager.default.createDirectory(at: emptyWorkspace, withIntermediateDirectories: true)
        let empty = try await HistorySessionScanner(applicationSupportRoot: root).scanWorkspaces(matching: emptyID.uuidString)
        XCTAssertFalse(empty.isTruncated, "absent session storage still proves zero saved sessions at this read")
        XCTAssertEqual(empty.workspaces.flatMap(\.records), [])
    }

    func testOwnerResolvedUUIDAndExactNameReadOnlyTheCustomWorkspaceIndex() async throws {
        let fixture = try SelectedHistoryFixture()
        defer { fixture.remove() }
        let record = makeRecord(id: UUID(), freshness: 1, itemCount: 1)
        try fixture.writeIndex([record])
        // Neither list operation may hydrate this deliberately malformed transcript.
        try Data("not a transcript".utf8).write(to: fixture.sessions.appendingPathComponent(record.filename))
        let owner = WorkspaceSelectionScript([.matched(fixture.location)])
        let scanner = fixture.scanner(owner: owner)

        for selector in [fixture.location.workspaceID.uuidString, fixture.location.name] {
            let scan = try await scanner.scanWorkspaces(matching: selector)
            XCTAssertFalse(scan.isTruncated, "\(scan.diagnostics)")
            XCTAssertEqual(scan.workspaces.map(\.workspaceID), [fixture.location.workspaceID])
            XCTAssertEqual(scan.workspaces.map(\.workspaceName), [fixture.location.name])
            XCTAssertEqual(scan.workspaces.flatMap(\.records).map(\.id), [record.id])
        }
        let selectors = await owner.capturedSelectors()
        XCTAssertEqual(selectors, [
            .id(fixture.location.workspaceID), .id(fixture.location.workspaceID),
            .exactName(fixture.location.name), .exactName(fixture.location.name)
        ])
        let transcriptReads = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(transcriptReads, 0)
    }

    func testUnresolvedOwnerSelectionNeverFallsBackToAnEmptyUUIDInventory() async throws {
        let fixture = try SelectedHistoryFixture()
        defer { fixture.remove() }
        let cases: [(HistoryWorkspaceSelection, String)] = [
            (.ambiguous, "ambiguous"), (.unavailable, "unavailable"),
            (.notReady, "not_ready"), (.notRegistered, "not_registered")
        ]
        for (selection, phase) in cases {
            let scanner = fixture.scanner(owner: WorkspaceSelectionScript([selection]))
            let scan = try await scanner.scanWorkspaces(matching: fixture.location.workspaceID.uuidString)
            XCTAssertTrue(scan.isTruncated, phase)
            XCTAssertTrue(scan.workspaces.isEmpty, phase)
            XCTAssertEqual(scan.diagnostics.map(\.kind), [.workspaceDiscovery], phase)
            XCTAssertEqual(scan.diagnostics.map(\.phase), ["workspace_selection_\(phase)"], phase)
        }
    }

    func testOwnerSelectionChangeDiscardsRowsReadBeforeTheFence() async throws {
        let fixture = try SelectedHistoryFixture()
        defer { fixture.remove() }
        try fixture.writeIndex([makeRecord(id: UUID(), freshness: 1, itemCount: 1)])
        let original = fixture.location
        let changed: [HistoryWorkspaceSelection] = [
            .notRegistered,
            .matched(.init(
                runtimeID: original.runtimeID,
                workspaceID: original.workspaceID,
                name: "Renamed",
                directory: original.directory
            )),
            .matched(.init(
                runtimeID: original.runtimeID,
                locationGeneration: 2,
                workspaceID: original.workspaceID,
                name: original.name,
                directory: original.directory
            )),
            .matched(.init(
                runtimeID: original.runtimeID,
                lifecycleGeneration: 2,
                workspaceID: original.workspaceID,
                name: original.name,
                directory: original.directory
            )),
            .matched(.init(
                runtimeID: UUID(),
                workspaceID: original.workspaceID,
                name: original.name,
                directory: original.directory
            ))
        ]
        for afterRead in changed {
            let scanner = fixture.scanner(owner: WorkspaceSelectionScript([.matched(original), afterRead]))
            let scan = try await scanner.scanWorkspaces(matching: original.workspaceID.uuidString)
            XCTAssertTrue(scan.workspaces.isEmpty, "rows selected under revoked placement must not escape")
            XCTAssertTrue(scan.isTruncated)
            XCTAssertEqual(scan.diagnostics.map(\.phase), ["workspace_selection_changed"])
        }
    }

    func testSelectedWorkspaceDistinguishesMissingRootFromConfirmedEmptySessionStorage() async throws {
        let fixture = try SelectedHistoryFixture()
        defer { fixture.remove() }
        let owner = WorkspaceSelectionScript([.matched(fixture.location)])
        let missingRoot = try await fixture.scanner(owner: owner)
            .scanWorkspaces(matching: fixture.location.workspaceID.uuidString)
        XCTAssertTrue(missingRoot.isTruncated)

        try FileManager.default.createDirectory(at: fixture.location.directory, withIntermediateDirectories: true)
        let absentStorage = try await fixture.scanner(owner: owner)
            .scanWorkspaces(matching: fixture.location.workspaceID.uuidString)
        XCTAssertFalse(absentStorage.isTruncated)
        XCTAssertEqual(absentStorage.workspaces.map(\.workspaceID), [fixture.location.workspaceID])
        XCTAssertTrue(absentStorage.workspaces.flatMap(\.records).isEmpty)

        try FileManager.default.createDirectory(at: fixture.sessions, withIntermediateDirectories: true)
        let unindexedStorage = try await fixture.scanner(owner: owner)
            .scanWorkspaces(matching: fixture.location.workspaceID.uuidString)
        XCTAssertTrue(unindexedStorage.isTruncated)
        XCTAssertEqual(unindexedStorage.diagnostics.map(\.phase), ["index_missing"])
    }

    func testSelectedIndexIdentityConflictsNeverBecomeCompleteRows() async throws {
        let fixture = try SelectedHistoryFixture()
        defer { fixture.remove() }
        let record = makeRecord(id: UUID(), freshness: 1, itemCount: 1)
        var misplaced = record
        misplaced.workspaceID = UUID()
        for records in [[misplaced], [record, record]] {
            try fixture.writeIndex(records)
            let scanner = fixture.scanner(owner: WorkspaceSelectionScript([.matched(fixture.location)]))
            let scan = try await scanner.scanWorkspaces(matching: fixture.location.workspaceID.uuidString)
            XCTAssertTrue(scan.isTruncated)
            XCTAssertTrue(scan.workspaces.flatMap(\.records).isEmpty)
            XCTAssertEqual(scan.diagnostics.map(\.phase), ["index_identity"])
        }
    }

    func testOwnerIssuedCustomLocationDoesNotAuthorizeSymlinkedStorage() async throws {
        for linkWorkspaceDirectory in [false, true] {
            let fixture = try SelectedHistoryFixture()
            defer { fixture.remove() }
            let outside = fixture.root.appendingPathComponent("OtherWorkspace")
            let outsideSessions = outside.appendingPathComponent("AgentSessions")
            try FileManager.default.createDirectory(at: outsideSessions, withIntermediateDirectories: true)
            try JSONEncoder().encode(AgentSessionMetadataIndex(entries: [makeRecord(id: UUID(), freshness: 1, itemCount: 1)]))
                .write(to: outsideSessions.appendingPathComponent("AgentSessionIndex.json"))
            if linkWorkspaceDirectory {
                try FileManager.default.createDirectory(at: fixture.location.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: fixture.location.directory, withDestinationURL: outside)
            } else {
                try FileManager.default.createDirectory(at: fixture.location.directory, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: fixture.sessions, withDestinationURL: outsideSessions)
            }
            let scanner = fixture.scanner(owner: WorkspaceSelectionScript([.matched(fixture.location)]))
            let scan = try await scanner.scanWorkspaces(matching: fixture.location.workspaceID.uuidString)
            XCTAssertTrue(scan.isTruncated)
            XCTAssertTrue(scan.workspaces.flatMap(\.records).isEmpty)
            let indexReads = await scanner.indexDecodeCountForTesting
            XCTAssertEqual(indexReads, 0, "owner-issued placement must not turn a linked directory into read authority")
        }
    }

    func testOwnerSelectedReadBypassesCompletedGlobalCache() async throws {
        let fixture = try SelectedHistoryFixture(customLocation: false)
        defer { fixture.remove() }
        let oldRecord = makeRecord(id: UUID(), freshness: 1, itemCount: 1)
        let newRecord = makeRecord(id: UUID(), freshness: 2, itemCount: 2)
        try fixture.writeIndex([oldRecord])
        let enumeration = WorkspaceEnumerationProbe([fixture.location.directory])
        let owner = WorkspaceSelectionScript([.matched(fixture.location)])
        let scanner = HistorySessionScanner(
            applicationSupportRoot: fixture.root, scanCacheTTL: 3600,
            workspaceDirectoryProvider: { _ in enumeration.enumerate() },
            workspaceLocations: .init(resolve: { await owner.resolve($0) })
        )
        let global = try await scanner.scanWorkspaces(matching: nil)
        XCTAssertFalse(global.isTruncated)
        XCTAssertEqual(global.workspaces.flatMap(\.records).map(\.id), [oldRecord.id])
        try fixture.writeIndex([oldRecord, newRecord])

        let selected = try await scanner.scanWorkspaces(matching: fixture.location.workspaceID.uuidString)
        XCTAssertFalse(selected.isTruncated)
        XCTAssertEqual(Set(selected.workspaces.flatMap(\.records).map(\.id)), [oldRecord.id, newRecord.id])
        XCTAssertEqual(enumeration.count, 1, "selected reads must neither reuse stale global rows nor re-enumerate roots")
    }

    func testExactNameMissRetainsLegacySubstringDiscovery() async throws {
        let fixture = try SelectedHistoryFixture(customLocation: false)
        defer { fixture.remove() }
        let record = makeRecord(id: UUID(), freshness: 1, itemCount: 1)
        try fixture.writeIndex([record])
        try JSONSerialization.data(withJSONObject: ["name": "Legacy substring workspace"])
            .write(to: fixture.location.directory.appendingPathComponent("workspace.json"))
        let enumeration = WorkspaceEnumerationProbe([fixture.location.directory])
        let scanner = HistorySessionScanner(
            applicationSupportRoot: fixture.root,
            workspaceDirectoryProvider: { _ in enumeration.enumerate() },
            workspaceLocations: .init(resolve: { _ in .notRegistered })
        )
        let scan = try await scanner.scanWorkspaces(matching: "substring")
        let matches = scanner.sessionsMatchingFilters(
            scan.workspaces, workspace: "substring", agentKind: nil, model: nil,
            filePath: nil, from: nil, to: nil
        )
        XCTAssertFalse(scan.isTruncated)
        XCTAssertEqual(matches.map(\.sessionID), [record.id])
        XCTAssertEqual(enumeration.count, 1)
    }

    func testCancellationDuringOwnerResolutionStopsBeforeIndexRead() async throws {
        let fixture = try SelectedHistoryFixture()
        defer { fixture.remove() }
        try fixture.writeIndex([makeRecord(id: UUID(), freshness: 1, itemCount: 1)])
        let gate = WorkspaceResolutionGate(selection: .matched(fixture.location))
        let scanner = HistorySessionScanner(
            applicationSupportRoot: fixture.root,
            workspaceDirectoryProvider: { _ in XCTFail("cancelled selected read must not enumerate roots")
                return []
            },
            workspaceLocations: .init(resolve: { _ in await gate.resolve() })
        )
        let task = Task { try await scanner.scanWorkspaces(matching: fixture.location.workspaceID.uuidString) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("cancelled owner lookup must propagate cancellation instead of returning an inventory")
        } catch is CancellationError {}
        let indexReads = await scanner.indexDecodeCountForTesting
        XCTAssertEqual(indexReads, 0)
    }

    func testOwnerAwaitConsumesSharedRequestDeadlineBeforePublishingRows() async throws {
        for pauseOnCall in [1, 2] {
            let fixture = try SelectedHistoryFixture()
            defer { fixture.remove() }
            try fixture.writeIndex([makeRecord(id: UUID(), freshness: 1, itemCount: 1)])
            let gate = WorkspaceResolutionGate(selection: .matched(fixture.location), pauseOnCall: pauseOnCall)
            let clock = WorkspaceBudgetClock()
            let budget = clock.budget()
            let scanner = HistorySessionScanner(
                applicationSupportRoot: fixture.root,
                workspaceDirectoryProvider: { _ in XCTFail("expired selected read must not enumerate roots")
                    return []
                },
                workspaceLocations: .init(resolve: { _ in await gate.resolve() })
            )
            let task = Task {
                try await scanner.scanWorkspaces(matching: fixture.location.workspaceID.uuidString, requestBudget: budget)
            }
            await gate.waitUntilEntered()
            clock.advance(by: .seconds(2))
            await gate.release()
            let scan = try await task.value
            XCTAssertTrue(scan.isTruncated)
            XCTAssertTrue(scan.workspaces.isEmpty, "expired owner response must not release previously read rows")
            XCTAssertEqual(scan.diagnostics.map(\.kind), [.elapsedTime])
            XCTAssertEqual(scan.diagnostics.map(\.phase), ["workspace_selection"])
            let indexReads = await scanner.indexDecodeCountForTesting
            XCTAssertEqual(indexReads, pauseOnCall == 1 ? 0 : 1)
        }
    }

    func testCancellationDuringFinalLocationCheckDiscardsDecodedTranscript() async throws {
        let fixture = try SelectedHistoryFixture()
        defer { fixture.remove() }
        let record = makeRecord(id: UUID(), freshness: 1, itemCount: 1)
        try fixture.writeIndex([record])
        try JSONEncoder().encode(AgentSession(id: record.id, name: "Cancelled read"))
            .write(to: fixture.sessions.appendingPathComponent(record.filename))
        // The first two calls establish the selected scan, then transcript loading checks
        // the same evidence before reading and once more immediately before publishing.
        let gate = WorkspaceResolutionGate(selection: .matched(fixture.location), pauseOnCall: 4)
        let scanner = HistorySessionScanner(
            applicationSupportRoot: fixture.root,
            workspaceDirectoryProvider: { _ in XCTFail("selected transcript read must not enumerate roots")
                return []
            },
            workspaceLocations: .init(resolve: { _ in await gate.resolve() })
        )
        let scan = try await scanner.scanWorkspaces(matching: fixture.location.workspaceID.uuidString)
        let evidence = try XCTUnwrap(scan.workspaces.first?.registeredLocation)
        let task = Task {
            try await scanner.loadSessionForHistory(
                sessionID: record.id, workspaceDir: fixture.location.directory,
                requestBudget: .standalone(), workspaceLocation: evidence
            )
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("a current owner response must not publish a transcript after the caller cancelled")
        } catch is CancellationError {}
        let transcriptReads = await scanner.transcriptDecodeCountForTesting
        XCTAssertEqual(transcriptReads, 1, "the gate must exercise the check after content was decoded")
    }

    func testLocationEvidenceSurvivesCacheChurnAndRevocationBlocksCachedTranscriptReads() async throws {
        for customLocation in [false, true] {
            let fixture = try SelectedHistoryFixture(customLocation: customLocation)
            defer { fixture.remove() }
            var record = makeRecord(id: UUID(), freshness: 1, itemCount: 1)
            // A recorded size makes the stale-field probe inspect storage rather than immediately
            // requesting enrichment for absent metadata.
            record.observedFileSize = 1
            try fixture.writeIndex([record])
            try JSONEncoder().encode(AgentSession(id: record.id, name: "Private selected transcript"))
                .write(to: fixture.sessions.appendingPathComponent(record.filename))
            let owner = WorkspaceSelectionScript([.matched(fixture.location)])
            let scanner = HistorySessionScanner(
                applicationSupportRoot: fixture.root,
                inventoryBudget: .init(maxWorkspaces: 2, maxIndexDecodes: 2, maxIndexBytes: 1_000_000, maxIndexCacheEntries: 1),
                workspaceDirectoryProvider: { _ in XCTFail("selected read must not enumerate roots")
                    return []
                },
                workspaceLocations: .init(resolve: { await owner.resolve($0) })
            )
            let scan = try await scanner.scanWorkspaces(matching: fixture.location.workspaceID.uuidString)
            let evidence = try XCTUnwrap(scan.workspaces.first?.registeredLocation)
            let loaded = try await scanner.loadSessionForHistory(
                sessionID: record.id, workspaceDir: fixture.location.directory,
                requestBudget: .standalone(), workspaceLocation: evidence
            )
            XCTAssertEqual(loaded.name, "Private selected transcript")
            let beforeRevocation = await scanner.transcriptDecodeCountForTesting

            let unrelatedID = UUID()
            let unrelated = HistoryWorkspaceLocation(
                runtimeID: fixture.location.runtimeID, workspaceID: unrelatedID, name: "Unrelated",
                directory: fixture.root.appendingPathComponent("Workspaces/Workspace-\(unrelatedID.uuidString)")
            )
            let unrelatedSessions = unrelated.directory.appendingPathComponent("AgentSessions")
            try FileManager.default.createDirectory(at: unrelatedSessions, withIntermediateDirectories: true)
            let unrelatedRecord = makeRecord(id: UUID(), freshness: 2, itemCount: 1)
            try JSONEncoder().encode(AgentSessionMetadataIndex(entries: [unrelatedRecord]))
                .write(to: unrelatedSessions.appendingPathComponent("AgentSessionIndex.json"))
            await owner.replace(with: .matched(unrelated))
            let otherScan = try await scanner.scanWorkspaces(matching: unrelatedID.uuidString)
            XCTAssertEqual(otherScan.workspaces.flatMap(\.records).map(\.id), [unrelatedRecord.id])
            let cachedIndexes = await scanner.indexScanCacheEntryCountForTesting
            XCTAssertEqual(cachedIndexes, 1)

            // Keep the evidence returned for the first selection even after another selected
            // index evicts it. A default-root path must not silently downgrade to a legacy read.
            await owner.replace(with: .notRegistered)
            do {
                _ = try await scanner.loadSessionForHistory(
                    sessionID: record.id, workspaceDir: fixture.location.directory,
                    requestBudget: .standalone(), workspaceLocation: evidence
                )
                XCTFail("cached transcript must not survive revocation of its selected location")
            } catch let HistorySessionScannerError.workBudgetExceeded(diagnostic) {
                XCTAssertEqual(diagnostic.phase, "workspace_selection_changed")
            }
            do {
                _ = try await scanner.transcriptDerivedFieldsAreStale(
                    for: record, sessionID: record.id, workspaceDir: fixture.location.directory,
                    requestBudget: .standalone(), workspaceLocation: evidence
                )
                XCTFail("signature probes must also respect revoked selected storage")
            } catch let HistorySessionScannerError.workBudgetExceeded(diagnostic) {
                XCTAssertEqual(diagnostic.phase, "workspace_selection_changed")
            }
            let afterRevocation = await scanner.transcriptDecodeCountForTesting
            XCTAssertEqual(afterRevocation, beforeRevocation)
        }
    }

    func testSelectedQuarantinedIndexPreservesKnownRowsButNeverClaimsCompleteCoverage() async throws {
        for seedWithGlobalScan in [false, true] {
            let fixture = try SelectedHistoryFixture(customLocation: false)
            defer { fixture.remove() }
            let record = makeRecord(id: UUID(), freshness: 1, itemCount: 1)
            let quarantine = AgentSessionMetadataQuarantineRecord(
                filename: "AgentSession-\(UUID()).json", observedFileSize: 1,
                observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 1),
                errorDescription: "unreadable test session", lastAttemptedAt: Date(timeIntervalSinceReferenceDate: 1)
            )
            try fixture.writeIndex([record])
            try JSONEncoder().encode(AgentSessionMetadataIndex(entries: [record], quarantinedFiles: [quarantine]))
                .write(to: fixture.sessions.appendingPathComponent("AgentSessionIndex.json"))
            let enumeration = WorkspaceEnumerationProbe([fixture.location.directory])
            let scanner = HistorySessionScanner(
                applicationSupportRoot: fixture.root,
                workspaceDirectoryProvider: { _ in enumeration.enumerate() },
                workspaceLocations: .init(resolve: { _ in .matched(fixture.location) })
            )
            if seedWithGlobalScan {
                _ = try await scanner.scanWorkspaces(matching: nil)
            }
            for _ in 0 ..< 2 {
                let scan = try await scanner.scanWorkspaces(matching: fixture.location.workspaceID.uuidString)
                XCTAssertTrue(scan.isTruncated, "quarantined sessions are unknown inventory, including on cache hits")
                XCTAssertEqual(scan.workspaces.flatMap(\.records).map(\.id), [record.id])
                XCTAssertEqual(scan.workspaces.map(\.indexReadFailed), [false], "valid known rows must remain usable")
                XCTAssertEqual(scan.diagnostics.map(\.phase), ["index_quarantined"])
            }
            let indexReads = await scanner.indexDecodeCountForTesting
            let transcriptReads = await scanner.transcriptDecodeCountForTesting
            XCTAssertEqual(indexReads, 1, "the second selected read must exercise cached quarantine coverage")
            XCTAssertEqual(transcriptReads, 0)
            XCTAssertEqual(enumeration.count, seedWithGlobalScan ? 1 : 0)
        }
    }

    func testSelectedTranscriptChecksEmbeddedWorkspaceEvenWhenLegacyReadWarmedItsCache() async throws {
        for warmLegacyCache in [false, true] {
            for placement in ["legacy", "matching", "mismatching"] {
                let fixture = try SelectedHistoryFixture(customLocation: !warmLegacyCache)
                defer { fixture.remove() }
                let record = makeRecord(id: UUID(), freshness: 1, itemCount: 1)
                try fixture.writeIndex([record])
                let embeddedWorkspaceID: UUID? = placement == "legacy" ? nil
                    : placement == "matching" ? fixture.location.workspaceID : UUID()
                try JSONEncoder().encode(AgentSession(
                    id: record.id, workspaceID: embeddedWorkspaceID, name: "Selected transcript"
                )).write(to: fixture.sessions.appendingPathComponent(record.filename))
                let scanner = fixture.scanner(owner: WorkspaceSelectionScript([.matched(fixture.location)]))
                if warmLegacyCache {
                    let legacy = try await scanner.loadSessionForHistory(sessionID: record.id, workspaceDir: fixture.location.directory)
                    XCTAssertEqual(legacy.name, "Selected transcript")
                }
                let scan = try await scanner.scanWorkspaces(matching: fixture.location.workspaceID.uuidString)
                let evidence = try XCTUnwrap(scan.workspaces.first?.registeredLocation)
                do {
                    let loaded = try await scanner.loadSessionForHistory(
                        sessionID: record.id, workspaceDir: fixture.location.directory,
                        requestBudget: .standalone(), workspaceLocation: evidence
                    )
                    XCTAssertNotEqual(placement, "mismatching", "a cached legacy read cannot bypass selected workspace identity")
                    XCTAssertEqual(loaded.name, "Selected transcript")
                } catch let HistorySessionScannerError.sessionAuthorityViolation(sessionID, _) {
                    XCTAssertEqual(placement, "mismatching", "legacy nil and matching identities must remain readable")
                    XCTAssertEqual(sessionID, record.id)
                }
                let transcriptReads = await scanner.transcriptDecodeCountForTesting
                XCTAssertEqual(transcriptReads, 1, "warm-cache identity checks must not depend on re-decoding the file")
            }
        }
    }

    private struct SelectedHistoryFixture {
        let root: URL
        let location: HistoryWorkspaceLocation
        var sessions: URL {
            location.directory.appendingPathComponent("AgentSessions", isDirectory: true)
        }

        init(customLocation: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("owner-history-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let workspaceID = UUID()
            let directory = customLocation
                ? root.appendingPathComponent("CustomStorage/Selected", isDirectory: true)
                : root.appendingPathComponent("Workspaces/Workspace-\(workspaceID.uuidString)", isDirectory: true)
            location = .init(runtimeID: UUID(), workspaceID: workspaceID, name: "Selected workspace", directory: directory)
        }

        func writeIndex(_ records: [AgentSessionMetadataRecord]) throws {
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            try JSONEncoder().encode(AgentSessionMetadataIndex(entries: records))
                .write(to: sessions.appendingPathComponent("AgentSessionIndex.json"))
        }

        func scanner(owner: WorkspaceSelectionScript) -> HistorySessionScanner {
            HistorySessionScanner(
                applicationSupportRoot: root,
                workspaceDirectoryProvider: { _ in XCTFail("owner-selected read must not enumerate roots")
                    return []
                },
                workspaceLocations: .init(resolve: { await owner.resolve($0) })
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private actor WorkspaceSelectionScript {
        private var selections: [HistoryWorkspaceSelection]
        private var selectors: [HistoryWorkspaceSelector] = []

        init(_ selections: [HistoryWorkspaceSelection]) {
            self.selections = selections
        }

        func resolve(_ selector: HistoryWorkspaceSelector) -> HistoryWorkspaceSelection {
            selectors.append(selector)
            return selections.count > 1 ? selections.removeFirst() : selections[0]
        }

        func replace(with selection: HistoryWorkspaceSelection) {
            selections = [selection]
        }

        func capturedSelectors() -> [HistoryWorkspaceSelector] {
            selectors
        }
    }

    private final class WorkspaceEnumerationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let directories: [URL]
        private var calls = 0

        init(_ directories: [URL]) {
            self.directories = directories
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        func enumerate() -> [URL] {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return directories
        }
    }

    private actor WorkspaceResolutionGate {
        private let selection: HistoryWorkspaceSelection
        private let pauseOnCall: Int
        private var calls = 0
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var resume: CheckedContinuation<Void, Never>?

        init(selection: HistoryWorkspaceSelection, pauseOnCall: Int = 1) {
            self.selection = selection
            self.pauseOnCall = pauseOnCall
        }

        func resolve() async -> HistoryWorkspaceSelection {
            calls += 1
            guard calls == pauseOnCall else { return selection }
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
            await withCheckedContinuation { resume = $0 }
            return selection
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }

        func release() {
            resume?.resume()
            resume = nil
        }
    }

    private final class WorkspaceBudgetClock: @unchecked Sendable {
        private let startedAt = ContinuousClock().now
        private let lock = NSLock()
        private var elapsed: Duration = .zero

        func advance(by duration: Duration) {
            lock.withLock { elapsed += duration }
        }

        private func now() -> ContinuousClock.Instant {
            lock.withLock { startedAt + elapsed }
        }

        func budget() -> HistoryRequestBudget {
            HistoryRequestBudget(
                startedAt: startedAt, deadline: startedAt + .seconds(1), maxTurns: 1000,
                yieldEveryTurns: 64, maxIndexBytes: 1_000_000, maxIndexFileBytes: 1_000_000,
                maxTranscriptBytes: 1_000_000, maxTranscriptFileBytes: 1_000_000,
                nowProvider: { self.now() }
            )
        }
    }

    // MARK: - Stale index budget isolation (#1091)

    /// Hundreds of stale-schema indexes enumerated ahead of a few current ones must not
    /// consume the index-count or index-byte budgets, must not trigger workspace.json reads,
    /// and must leave a narrow date query answerable without truncation.
    func testStaleSchemaIndexesDoNotConsumeScanBudgetsAtScale() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("rp-history-1091-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let staleVersions = [2, 5, 6, 7]
        XCTAssertFalse(staleVersions.contains(AgentSessionMetadataIndex.currentSchemaVersion))
        let padding = String(repeating: "x", count: 1024)
        var workspaceDirs: [URL] = []

        // 400 head-sniffable stale indexes (~1 KB each), each with an oversized workspace.json.
        for index in 0 ..< 400 {
            let version = staleVersions[index % staleVersions.count]
            let json = "{\"schemaVersion\":\(version),\"generatedAt\":0,\"entries\":[],\"padding\":\"\(padding)\"}"
            try workspaceDirs.append(makeHistoryWorkspace(
                root: root,
                name: "Workspace-Stale\(index)-\(UUID().uuidString)",
                indexData: Data(json.utf8),
                workspaceJSON: "{\"name\":\"stale-\(index)\",\"padding\":\"\(padding)\"}"
            ))
        }
        // Two stale indexes whose schemaVersion sits beyond the head window exercise the
        // full-read fallback, which may charge bytes but never an index-count slot.
        for index in 0 ..< 2 {
            let longPadding = String(repeating: "y", count: 6000)
            let json = "{\"generatedAt\":0,\"entries\":[],\"padding\":\"\(longPadding)\",\"schemaVersion\":6}"
            try workspaceDirs.append(makeHistoryWorkspace(
                root: root,
                name: "Workspace-LateStale\(index)-\(UUID().uuidString)",
                indexData: Data(json.utf8),
                workspaceJSON: nil
            ))
        }

        let inRange = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var expectedIDs: Set<UUID> = []
        for index in 0 ..< 3 {
            let recent = makeRecord(id: UUID(), freshness: inRange.timeIntervalSinceReferenceDate, itemCount: 4)
            let old = makeRecord(id: UUID(), freshness: inRange.timeIntervalSinceReferenceDate - 90 * 86400, itemCount: 4)
            expectedIDs.insert(recent.id)
            let indexData = try JSONEncoder().encode(AgentSessionMetadataIndex(entries: [recent, old]))
            try workspaceDirs.append(makeHistoryWorkspace(
                root: root,
                name: "Workspace-Current\(index)-\(UUID().uuidString)",
                indexData: indexData,
                workspaceJSON: "{\"name\":\"current-\(index)\"}"
            ))
        }

        let dirs = workspaceDirs
        let scanner = HistorySessionScanner(
            applicationSupportRoot: root,
            inventoryBudget: HistoryInventoryBudget(
                maxWorkspaces: 1000,
                maxIndexDecodes: 3,
                maxIndexBytes: 64 * 1024,
                maxWorkspaceMetadataFileBytes: 256
            ),
            workspaceDirectoryProvider: { _ in dirs }
        )

        let scan = try await scanner.scanWorkspaces(matching: nil)

        XCTAssertFalse(scan.isTruncated, "diagnostics: \(scan.diagnostics)")
        let diagnosticKinds = Set(scan.diagnostics.map(\.kind))
        XCTAssertFalse(diagnosticKinds.contains(.indexCount))
        XCTAssertFalse(diagnosticKinds.contains(.indexBytes))
        XCTAssertFalse(diagnosticKinds.contains(.workspaceMetadataFileBytes))
        let decodeCount = await scanner.indexDecodeCountForTesting
        XCTAssertEqual(decodeCount, 3)

        let staleResults = scan.workspaces.filter { $0.indexSchemaVersion != nil }
        XCTAssertEqual(staleResults.count, 402)
        XCTAssertEqual(Set(staleResults.compactMap(\.indexSchemaVersion)), Set(staleVersions))
        XCTAssertTrue(staleResults.allSatisfy(\.records.isEmpty))
        let currentResults = scan.workspaces.filter { $0.indexSchemaVersion == nil && !$0.records.isEmpty }
        XCTAssertEqual(Set(currentResults.map(\.workspaceName)), ["current-0", "current-1", "current-2"])

        let matches = scanner.sessionsMatchingFilters(
            scan.workspaces,
            workspace: nil,
            agentKind: nil,
            model: nil,
            filePath: nil,
            from: inRange.addingTimeInterval(-3600),
            to: inRange.addingTimeInterval(3600)
        )
        XCTAssertEqual(Set(matches.map(\.sessionID)), expectedIDs)
    }

    /// A head-sniffed stale entry caches only directory-derived identity. Direct lookup must
    /// still resolve `workspace.json`, and upgrading the index must surface its records.
    func testStaleCacheEntryDoesNotSupplyIdentityAndUpgradesToCurrentIndex() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("rp-history-1091-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let realName = "Real Workspace Name"
        let workspaceDir = try makeHistoryWorkspace(
            root: root,
            name: "Workspace-DirectoryName-\(UUID().uuidString)",
            indexData: Data("{\"schemaVersion\":5,\"generatedAt\":0,\"entries\":[]}".utf8),
            workspaceJSON: "{\"name\":\"\(realName)\"}"
        )
        let sessionsDir = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
        let record = makeRecord(id: UUID(), freshness: 800_000_000, itemCount: 3)
        try Data("{}".utf8).write(to: sessionsDir.appendingPathComponent(record.filename))

        let scanner = HistorySessionScanner(
            applicationSupportRoot: root,
            workspaceDirectoryProvider: { _ in [workspaceDir] }
        )

        let staleScan = try await scanner.scanWorkspaces(matching: nil)
        let stale = try XCTUnwrap(staleScan.workspaces.first)
        XCTAssertEqual(stale.indexSchemaVersion, 5)
        XCTAssertNotEqual(stale.workspaceName, realName, "stale skip must not read workspace.json")
        let staleCacheEntries = await scanner.indexScanCacheEntryCountForTesting
        XCTAssertEqual(staleCacheEntries, 1)

        let staleLookup = try await scanner.locateSession(sessionID: record.id)
        let staleLocation = try XCTUnwrap(staleLookup.location)
        XCTAssertEqual(staleLocation.workspaceName, realName)
        XCTAssertNil(staleLocation.record)

        let currentIndex = try JSONEncoder().encode(AgentSessionMetadataIndex(entries: [record]))
        try currentIndex.write(to: sessionsDir.appendingPathComponent("AgentSessionIndex.json"))

        let refreshed = try await scanner.scanWorkspacesRefreshing(matching: nil)
        let current = try XCTUnwrap(refreshed.workspaces.first)
        XCTAssertNil(current.indexSchemaVersion)
        XCTAssertEqual(current.workspaceName, realName)
        XCTAssertEqual(current.records.map(\.id), [record.id])

        let currentLookup = try await scanner.locateSession(sessionID: record.id)
        XCTAssertEqual(currentLookup.location?.record?.id, record.id)
        XCTAssertEqual(currentLookup.location?.workspaceName, realName)
    }

    private func makeHistoryWorkspace(
        root: URL,
        name: String,
        indexData: Data,
        workspaceJSON: String?
    ) throws -> URL {
        let workspaceDir = root.appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let sessionsDir = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try indexData.write(to: sessionsDir.appendingPathComponent("AgentSessionIndex.json"))
        if let workspaceJSON {
            try Data(workspaceJSON.utf8).write(to: workspaceDir.appendingPathComponent("workspace.json"))
        }
        return workspaceDir
    }

    private func makeRecord(id: UUID, freshness: TimeInterval, itemCount: Int) -> AgentSessionMetadataRecord {
        let date = Date(timeIntervalSinceReferenceDate: freshness)
        return AgentSessionMetadataRecord(
            id: id,
            filename: "AgentSession-\(id.uuidString).json",
            workspaceID: nil,
            composeTabID: nil,
            name: "Session",
            savedAt: date,
            lastUserMessageAt: nil,
            itemCount: itemCount,
            transcriptProjectionCounts: nil,
            hasUnknownConversationContent: false,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            lastRunStateRaw: nil,
            autoEditEnabled: true,
            parentSessionID: nil,
            isMCPOriginated: true,
            serializationVersion: nil,
            observedFileSize: nil,
            observedFileModificationDate: date,
            lastIndexedAt: date
        )
    }
}

// MARK: - HistoryInventoryScaleTests regressions

final class HistoryInventoryScaleTests: XCTestCase {
    func testScopedDiscoveryAuthorizesOnlyMatchingWorkspaceDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-scoped-scale-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedID = UUID()
        var directories: [URL] = []
        for index in 0 ..< 5501 {
            let id = index == 5500 ? selectedID : UUID()
            try directories.append(staleWorkspace(root: root, id: id))
        }
        let census = directories
        let scanner = HistorySessionScanner(applicationSupportRoot: root, workspaceDirectoryProvider: { _ in census })
        let result = try await scanner.scanWorkspaces(matching: selectedID.uuidString)
        XCTAssertFalse(result.isTruncated)
        XCTAssertEqual(result.workspaces.map(\.workspaceID), [selectedID])
        let statCount = await scanner.workspaceDirectoryStatCountForTesting
        let inspectionCount = await scanner.workspaceInspectionCountForTesting
        XCTAssertEqual(statCount, 1, "Unrelated directories must be rejected before lstat/authority work")
        XCTAssertEqual(inspectionCount, 1)
    }

    func testCyclicStaleIndexCensusAmortizesEvictionAndRetainsBounds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-eviction-scale-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var directories: [URL] = []
        for _ in 0 ..< 128 {
            try directories.append(staleWorkspace(root: root, id: UUID()))
        }
        let census = directories
        let scanner = HistorySessionScanner(
            applicationSupportRoot: root,
            scanCacheTTL: 0,
            inventoryBudget: HistoryInventoryBudget(
                maxWorkspaces: 256,
                maxIndexDecodes: 1,
                maxIndexBytes: 1024,
                maxIndexCacheEntries: 16,
                maxIndexCacheBytes: 1024
            ),
            workspaceDirectoryProvider: { _ in census }
        )
        for _ in 0 ..< 2 {
            let result = try await scanner.scanWorkspaces(matching: nil)
            XCTAssertFalse(result.isTruncated)
            XCTAssertEqual(result.workspaces.count, census.count)
            let entries = await scanner.indexScanCacheEntryCountForTesting
            let bytes = await scanner.indexScanCacheBytesForTesting
            XCTAssertLessThanOrEqual(entries, 16)
            XCTAssertLessThanOrEqual(bytes, 1024)
        }
        let visits = await scanner.indexCacheEvictionVisitsForTesting
        XCTAssertLessThan(visits, census.count * 2 * 5, "Eviction must not rescan the entire cache for every insert")
        let before = await scanner.indexScanCacheEntryCountForTesting
        let newest = try XCTUnwrap(census.last)
        let scoped = try await scanner.scanWorkspaces(matching: newest.lastPathComponent)
        XCTAssertEqual(scoped.workspaces.count, 1)
        let after = await scanner.indexScanCacheEntryCountForTesting
        XCTAssertEqual(after, before, "Newest cache entry must remain available after batch eviction")
    }

    func testUsableSessionsBeyondFiveThousandLegacyDirectoriesAndCacheOverflow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-usable-scale-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var directories: [URL] = []
        for _ in 0 ..< 5501 {
            try directories.append(staleWorkspace(root: root, id: UUID()))
        }
        let selectedID = UUID()
        let usable = try staleWorkspace(root: root, id: selectedID)
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let records = (0 ..< 251).map { _ in
            let id = UUID()
            return AgentSessionMetadataRecord(
                id: id, filename: "AgentSession-\(id).json", workspaceID: selectedID, composeTabID: nil,
                name: "Usable", savedAt: date, lastUserMessageAt: nil, itemCount: 1,
                transcriptProjectionCounts: nil, hasUnknownConversationContent: false,
                agentKindRaw: nil, agentModelRaw: nil, agentReasoningEffortRaw: nil, lastRunStateRaw: nil,
                autoEditEnabled: true, parentSessionID: nil, isMCPOriginated: true, serializationVersion: nil,
                observedFileSize: nil, observedFileModificationDate: date, lastIndexedAt: date
            )
        }
        try JSONEncoder().encode(AgentSessionMetadataIndex(entries: records))
            .write(to: usable.appendingPathComponent("AgentSessions/AgentSessionIndex.json"))
        directories.append(usable)
        let census = directories
        let scanner = HistorySessionScanner(
            applicationSupportRoot: root, scanCacheTTL: 0,
            inventoryBudget: HistoryInventoryBudget(maxWorkspaces: 6000, maxIndexDecodes: 2, maxIndexBytes: 8 * 1024 * 1024, maxIndexCacheEntries: 16),
            workspaceDirectoryProvider: { _ in census }
        )
        for _ in 0 ..< 2 {
            let scan = try await scanner.scanWorkspaces(matching: nil)
            XCTAssertFalse(scan.isTruncated)
            XCTAssertEqual(Set(scan.workspaces.flatMap(\.records).map(\.id)), Set(records.map(\.id)))
            let entries = await scanner.indexScanCacheEntryCountForTesting
            XCTAssertLessThanOrEqual(entries, 16)
        }
        let visits = await scanner.indexCacheEvictionVisitsForTesting
        XCTAssertLessThan(visits, census.count * 2 * 5)
        let before = await scanner.workspaceDirectoryStatCountForTesting
        let scoped = try await scanner.scanWorkspaces(matching: selectedID.uuidString)
        let after = await scanner.workspaceDirectoryStatCountForTesting
        XCTAssertEqual(after - before, 1)
        XCTAssertEqual(scoped.workspaces.count, 1)
        XCTAssertEqual(Set(scoped.workspaces.flatMap(\.records).map(\.id)), Set(records.map(\.id)))
    }

    func testBytePressureRetainsNewestFittingEntryButRejectsOversizedEntry() async {
        let scanner = HistorySessionScanner(inventoryBudget: HistoryInventoryBudget(
            maxWorkspaces: 16, maxIndexDecodes: 16, maxIndexBytes: 4096, maxIndexCacheEntries: 16, maxIndexCacheBytes: 1024
        ))
        for (key, bytes) in [("old", Int64(200)), ("new", Int64(900))] {
            await scanner.rememberIndexScan(key, indexSignature: .init(fileSize: bytes, modificationTime: 0), workspaceSignature: nil, identity: (key, nil), indexSchemaVersion: nil, records: [], estimatedByteCount: bytes)
        }
        let count = await scanner.indexScanCacheEntryCountForTesting
        let bytes = await scanner.indexScanCacheBytesForTesting
        XCTAssertEqual(count, 1)
        XCTAssertEqual(bytes, 900, "Low-water eviction must retain the newest index when it fits the hard cap")
        await scanner.rememberIndexScan("oversized", indexSignature: .init(fileSize: 1025, modificationTime: 0), workspaceSignature: nil, identity: ("oversized", nil), indexSchemaVersion: nil, records: [], estimatedByteCount: 1025)
        let boundedBytes = await scanner.indexScanCacheBytesForTesting
        XCTAssertLessThanOrEqual(boundedBytes, 1024)
    }

    private func staleWorkspace(root: URL, id: UUID) throws -> URL {
        let workspace = root.appendingPathComponent("Workspaces/Workspace-Scale-\(id.uuidString)")
        let sessions = workspace.appendingPathComponent("AgentSessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("{\"schemaVersion\":5,\"entries\":[]}".utf8)
            .write(to: sessions.appendingPathComponent("AgentSessionIndex.json"))
        return workspace
    }
}
