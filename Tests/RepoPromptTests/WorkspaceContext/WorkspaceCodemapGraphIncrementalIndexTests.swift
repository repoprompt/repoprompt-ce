import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

/// Regression coverage for #1082: graph-index publication and graph commits must scale with the
/// published batch, not with the resident graph, while producing the same deterministic graph.
final class WorkspaceCodemapGraphIncrementalIndexTests: XCTestCase {
    // MARK: - Ordering

    func testFastOrderingsMatchHistoricalOrderings() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("aAzZ09_/.-é漢😀")
        // NFC "é" (C3 A9) and NFD "e" + U+0301 (65 CC 81) are canonically equal Strings but differ
        // byte-wise; callers compare with `!=` first, then order by UTF-8 bytes.
        let composed = "Sources/Caf\u{E9}.swift"
        let decomposed = "Sources/Cafe\u{301}.swift"
        var strings = [
            "", "a", "ab", "abc", "b", "Sources/A.swift", "Sources/A.swift.bak", "Sources/a.swift",
            composed, decomposed, "\u{E9}", "e\u{301}", "\u{1E9B}\u{323}", "\u{17F}\u{323}\u{307}"
        ]
        for _ in 0 ..< 200 {
            let length = Int.random(in: 0 ... 12, using: &generator)
            strings.append(String((0 ..< length).map { _ in
                alphabet[Int.random(in: alphabet.indices, using: &generator)]
            }))
        }
        for lhs in strings {
            for rhs in strings {
                XCTAssertEqual(
                    WorkspaceCodemapGraphOrdering.utf8Precedes(lhs, rhs),
                    lhs.utf8.lexicographicallyPrecedes(rhs.utf8),
                    "\(lhs) vs \(rhs)"
                )
            }
        }
        XCTAssertEqual(composed, decomposed)
        XCTAssertTrue(WorkspaceCodemapGraphOrdering.utf8Precedes(decomposed, composed))
        XCTAssertFalse(WorkspaceCodemapGraphOrdering.utf8Precedes(composed, decomposed))
        // Bridged (non-native) strings take the fallback path and must agree too.
        let bridged = NSString(string: composed) as String
        XCTAssertEqual(
            WorkspaceCodemapGraphOrdering.utf8Precedes(bridged, decomposed),
            bridged.utf8.lexicographicallyPrecedes(decomposed.utf8)
        )

        let edgeUUIDs = [
            UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            UUID(uuid: (0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF)),
            UUID(uuid: (0, 0, 0, 0x0A, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            UUID(uuid: (0, 0, 0, 0x09, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        ]
        let uuids = (0 ..< 300).map { _ in UUID() } + edgeUUIDs
        for lhs in uuids {
            for rhs in uuids.prefix(40) {
                XCTAssertEqual(
                    WorkspaceCodemapGraphOrdering.uuidPrecedes(lhs, rhs),
                    lhs.uuidString < rhs.uuidString
                )
            }
        }
    }

    // MARK: - Persistent storage

    func testPersistentHashMapMatchesDictionaryAndIsolatesVersions() {
        struct CollidingKey: Hashable {
            let id: Int
            func hash(into hasher: inout Hasher) {
                hasher.combine(id % 7)
            }
        }
        var generator = SystemRandomNumberGenerator()
        var map = PersistentHashMap<CollidingKey, Int>()
        var reference: [CollidingKey: Int] = [:]
        var versions: [(PersistentHashMap<CollidingKey, Int>, [CollidingKey: Int])] = []
        for step in 0 ..< 4000 {
            let key = CollidingKey(id: Int.random(in: 0 ..< 300, using: &generator))
            if Int.random(in: 0 ..< 3, using: &generator) == 0 {
                XCTAssertEqual(map.removeValue(forKey: key), reference.removeValue(forKey: key))
            } else {
                XCTAssertEqual(map.updateValue(step, forKey: key), reference.updateValue(step, forKey: key))
            }
            XCTAssertEqual(map.count, reference.count)
            if step.isMultiple(of: 500) { versions.append((map, reference)) }
        }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: map.map { ($0.key, $0.value) }), reference)
        for key in (0 ..< 300).map(CollidingKey.init) {
            XCTAssertEqual(map[key], reference[key])
        }
        // Earlier versions share structure with the live map but never observe its mutations.
        for (version, expected) in versions {
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: version.map { ($0.key, $0.value) }), expected)
        }

        // Updating a shared version copies only one trie path, independent of the map size.
        var large = PersistentHashMap<Int, Int>()
        for value in 0 ..< 50000 {
            large[value] = value
        }
        _ = large.takeCopiedEntryCount()
        let pinned = large
        var copiedPerUpdate: [Int] = []
        for value in [3, 17001, 42424, 49999, 60000] {
            large[value] = -value
            copiedPerUpdate.append(large.takeCopiedEntryCount())
        }
        XCTAssertLessThanOrEqual(copiedPerUpdate.max() ?? 0, 32 * 5)
        XCTAssertEqual(pinned[3], 3)
        XCTAssertNil(pinned[60000])
        XCTAssertEqual(large[3], -3)
        XCTAssertEqual(pinned.count, 50000)
        XCTAssertEqual(large.count, 50001)
    }

    // MARK: - Per-commit work bound

    func testGraphIndexPublicationWorkStaysProportionalToBatchSize() async throws {
        // Far more files than the changed-set policy (4096) so acknowledgement pruning is exercised.
        let fileCount = 16384
        let batchSize = 64
        let harness = try await CodemapGraphIndexHarness(seed: 0x21)
        let files = try harness.makeFiles(count: fileCount)

        var overlayVisits: [UInt64] = []
        var diffSizes: [Int] = []
        var commitVisits: [UInt64] = []
        var commitComparisons: [UInt64] = []
        var commitCopies: [UInt64] = []
        var fullCopyEntries: [Int] = []
        var pinned: (snapshot: WorkspaceCodemapGraphCommittedSnapshot, materialized: CodemapMaterializedGraph)?
        var pageNanoseconds: [UInt64] = []
        let setupFinished = DispatchTime.now().uptimeNanoseconds
        for start in stride(from: 0, to: fileCount, by: batchSize) {
            let pageStarted = DispatchTime.now().uptimeNanoseconds
            defer { pageNanoseconds.append(DispatchTime.now().uptimeNanoseconds - pageStarted) }
            let page = Array(files[start ..< min(start + batchSize, fileCount)])
            for slots in [page.map(\.pending), page.map(\.contributed)] {
                let published = await harness.publish(slots, projectedTotal: UInt64(fileCount))
                XCTAssertTrue(published)
                let ledger = try await harness.ledger()
                overlayVisits.append(ledger.lastReconcileVisitCount)
                let disposition = await harness.pull()
                guard case .committed(_, _, _, _, false) = disposition else { continue }
                let accounting = await harness.graph.incrementalAccounting()
                commitVisits.append(accounting.lastCandidateVisitCount)
                commitComparisons.append(accounting.lastCandidateComparisonCount)
                commitCopies.append(accounting.lastCandidateCopiedEntryCount)
                let diffLedger = try await harness.ledger()
                diffSizes.append(diffLedger.lastDiffSlotCount)
                if start == fileCount / 4 {
                    let snapshot = try await harness.latestSnapshot()
                    fullCopyEntries.append(CodemapMaterializedGraph(snapshot).fullCopyEntryCount)
                }
                if pinned == nil, start >= fileCount / 4 {
                    let snapshot = try await harness.latestSnapshot()
                    pinned = (snapshot, CodemapMaterializedGraph(snapshot))
                }
            }
        }
        let loopFinished = DispatchTime.now().uptimeNanoseconds
        let lastPageSnapshot = try await harness.latestSnapshot()
        fullCopyEntries.append(CodemapMaterializedGraph(lastPageSnapshot).fullCopyEntryCount)
        let completionStarted = DispatchTime.now().uptimeNanoseconds
        let finished = await harness.publish([], enumerationFinished: true)
        XCTAssertTrue(finished)
        _ = await harness.pull()
        let completionFinished = DispatchTime.now().uptimeNanoseconds

        let ledger = try await harness.ledger()
        // Every page publication reconciles only its own paths; only enumeration completion
        // performs one full reconciliation.
        XCTAssertEqual(ledger.incrementalReconcileCount, UInt64(2 * fileCount / batchSize) + 1)
        XCTAssertLessThanOrEqual(ledger.fullReconcileCount, 1)
        XCTAssertEqual(ledger.incrementalFallbackCount, 0)
        XCTAssertLessThanOrEqual(ledger.maximumIncrementalReconcileVisitCount, UInt64(8 * batchSize))
        XCTAssertLessThanOrEqual(overlayVisits.max() ?? 0, UInt64(8 * batchSize))
        // The changed set outgrew policy, but acknowledged entries were pruned instead of forcing
        // a floor reset and a whole-graph checkpoint resync.
        XCTAssertGreaterThan(ledger.acknowledgedPruneCount, 0)
        XCTAssertEqual(ledger.floorResetCount, 0)

        let graphAccounting = await harness.graph.incrementalAccounting()
        XCTAssertEqual(graphAccounting.resyncCommitCount, 1, "Only the initial checkpoint may resync")
        XCTAssertTrue(graphAccounting.coverage?.isComplete == true)
        // Diffs carry only the latest publication, never the whole changed set since the floor.
        XCTAssertLessThanOrEqual(diffSizes.max() ?? 0, batchSize)

        // Per-commit work (visits, comparator calls, and copied/shifted storage entries) is bounded
        // by the batch and stays flat while the resident graph grows 16x after the first quarter.
        XCTAssertEqual(commitVisits.count, commitCopies.count)
        XCTAssertLessThanOrEqual(commitVisits.max() ?? 0, UInt64(48 * batchSize))
        XCTAssertLessThanOrEqual(commitComparisons.max() ?? 0, UInt64(64 * batchSize))
        XCTAssertLessThanOrEqual(commitCopies.max() ?? 0, UInt64(2048 * batchSize))
        let quarter = commitCopies.count / 4
        func average(_ values: ArraySlice<UInt64>) -> Double {
            Double(values.reduce(0, +)) / Double(max(values.count, 1))
        }
        for (name, series) in [("visits", commitVisits), ("comparisons", commitComparisons), ("copies", commitCopies)] {
            let early = average(series[quarter ..< 2 * quarter])
            let late = average(series[(3 * quarter)...])
            XCTAssertLessThanOrEqual(late, early * 1.5, "Per-commit \(name) must not grow with the graph")
        }
        // A copy-on-write commit of plain dictionaries copies every resident entry; persistent
        // storage copies a small, flat amount per commit instead.
        let finalFullCopy = fullCopyEntries.last ?? 0
        XCTAssertGreaterThan(finalFullCopy, 20 * fileCount / 4)
        XCTAssertLessThan(Double(commitCopies.max() ?? 0), Double(finalFullCopy) / 4)
        print(
            """
            [#1082] commits=\(commitCopies.count) \
            visits early/late avg=\(Int(average(commitVisits[quarter ..< 2 * quarter])))/\
            \(Int(average(commitVisits[(3 * quarter)...]))) max=\(commitVisits.max() ?? 0) \
            comparisons early/late avg=\(Int(average(commitComparisons[quarter ..< 2 * quarter])))/\
            \(Int(average(commitComparisons[(3 * quarter)...]))) max=\(commitComparisons.max() ?? 0) \
            copies early/late avg=\(Int(average(commitCopies[quarter ..< 2 * quarter])))/\
            \(Int(average(commitCopies[(3 * quarter)...]))) max=\(commitCopies.max() ?? 0) \
            full-copy entries per commit (COW dictionaries) first/last=\(fullCopyEntries.first ?? 0)/\(finalFullCopy) \
            page ms early/late avg=\(average(pageNanoseconds[16 ..< 32].map { $0 / 1000 }[...]) / 1000)/\
            \(average(pageNanoseconds[(pageNanoseconds.count - 16)...].map { $0 / 1000 }[...]) / 1000) \
            loop s=\(Double(loopFinished - setupFinished) / 1e9) completion s=\(Double(completionFinished - completionStarted) / 1e9)
            """
        )

        // A snapshot pinned mid-indexing is untouched by every later commit.
        let pinnedSnapshot = try XCTUnwrap(pinned)
        XCTAssertEqual(CodemapMaterializedGraph(pinnedSnapshot.snapshot), pinnedSnapshot.materialized)

        // Determinism: the incrementally maintained graph equals a from-scratch checkpoint build.
        let incremental = try await harness.latestSnapshot()
        let rebuilt = try await harness.rebuiltFromCheckpoint()
        assertSameGraph(incremental, rebuilt)
    }

    // MARK: - Path-scoped reconcile and graph parity across destructive steps

    func testIncrementalLedgerAndGraphMatchFullRebuildAcrossDestructiveSteps() async throws {
        let incremental = try await CodemapGraphIndexHarness(seed: 0x31, mode: .incremental)
        let full = try await CodemapGraphIndexHarness(seed: 0x31, mode: .alwaysFull)
        let files = try incremental.makeFiles(count: 240)
        let projected = UInt64(files.count + 8)
        var steps: [(label: String, slots: [WorkspaceCodemapGraphSlot])] = []
        for start in stride(from: 0, to: files.count, by: 32) {
            let batch = Array(files[start ..< min(start + 32, files.count)])
            steps.append(("pending \(start)", batch.map(\.pending)))
            steps.append(("contributed \(start)", batch.map(\.contributed)))
        }
        steps.append(("idempotent republish", Array(files[10 ..< 20]).map(\.contributed)))
        try steps.append(("rename", [incremental.makeSlot(
            fileID: files[5].fileID,
            path: "Sources/Moved/Renamed5.swift",
            definitions: ["Type5"],
            references: ["Type0"],
            requestGeneration: 2
        )]))
        try steps.append(("replace path with newer file", [incremental.makeSlot(
            fileID: incremental.fileID(7, lane: 0xEE),
            path: files[7].path,
            definitions: ["Replacement7"],
            references: ["Type1"],
            requestGeneration: 3
        )]))
        // Same path, equal generations: the higher file ID (byte order) wins in both modes.
        let tieLow = incremental.fileID(1, lane: 0x70)
        let tieHigh = incremental.fileID(2, lane: 0x70)
        try steps.append(("generation tie", [
            incremental.makeSlot(fileID: tieLow, path: "Sources/Tie.swift", definitions: ["TieLow"], references: ["Type0"]),
            incremental.makeSlot(fileID: tieHigh, path: "Sources/Tie.swift", definitions: ["TieHigh"], references: ["Type0"])
        ]))
        try steps.append(("tie loser republished", [
            incremental.makeSlot(fileID: tieLow, path: "Sources/Tie.swift", definitions: ["TieLow"], references: ["Type2"])
        ]))
        // NFC and NFD spellings are one path under String equality in every layer.
        try steps.append(("nfc", [incremental.makeSlot(
            fileID: incremental.fileID(1, lane: 0x71),
            path: "Sources/Caf\u{E9}.swift",
            definitions: ["Composed"],
            references: ["Type0"]
        )]))
        try steps.append(("nfd", [incremental.makeSlot(
            fileID: incremental.fileID(2, lane: 0x71),
            path: "Sources/Cafe\u{301}.swift",
            definitions: ["Decomposed"],
            references: ["Type0"]
        )]))

        for step in steps {
            for harness in [incremental, full] {
                let published = await harness.publish(step.slots, projectedTotal: projected)
                XCTAssertTrue(published, step.label)
                _ = await harness.pull()
            }
            try await assertParity(incremental, full, step: step.label, expectCheckpoint: true)
        }
        let tieCheckpoint = try await incremental.checkpoint()
        let tieWinner = tieCheckpoint.slots.first { $0.standardizedRelativePath == "Sources/Tie.swift" }
        XCTAssertEqual(tieWinner?.fileID, tieHigh)

        // A watcher-gap reconciliation pass drops files missing from the authoritative pass.
        for harness in [incremental, full] {
            let began = await harness.overlay.beginGraphReconciliation(rootEpoch: harness.rootEpoch)
            XCTAssertTrue(began)
        }
        let survivors = Array(files.prefix(200))
        for start in stride(from: 0, to: survivors.count, by: 50) {
            let slots = survivors[start ..< min(start + 50, survivors.count)].map(\.contributed)
            for harness in [incremental, full] {
                let published = await harness.publish(slots)
                XCTAssertTrue(published)
                _ = await harness.pull()
            }
            // Mid-pass coverage counts only re-seen slots, so a checkpoint is not constructible
            // (pre-existing); both modes must agree on that, and their graphs must still match.
            try await assertParity(incremental, full, step: "reconcile \(start)", expectCheckpoint: false)
        }
        for harness in [incremental, full] {
            let published = await harness.publish([], enumerationFinished: true)
            XCTAssertTrue(published)
            _ = await harness.pull()
        }
        try await assertParity(incremental, full, step: "reconciliation complete", expectCheckpoint: true)

        let incrementalLedger = try await incremental.ledger()
        let fullLedger = try await full.ledger()
        XCTAssertGreaterThan(incrementalLedger.incrementalReconcileCount, 0)
        XCTAssertEqual(fullLedger.incrementalReconcileCount, 0)
        let incrementalGraph = await incremental.graph.incrementalAccounting()
        let fullGraph = await full.graph.incrementalAccounting()
        XCTAssertGreaterThan(incrementalGraph.fencedFileCount, 0, "Deleted and renamed files were fenced")
        XCTAssertEqual(incrementalGraph.fencedFileCount, fullGraph.fencedFileCount)
        XCTAssertEqual(incrementalGraph.safetyCounter, fullGraph.safetyCounter)
    }

    // MARK: - Consumers, fences, cancellation, roots

    func testLateConsumersAcrossPruneBoundaryConverge() async throws {
        let policy = try XCTUnwrap(WorkspaceCodemapGraphPolicy(maximumChangedSetFileIDCount: 64))
        let harness = try await CodemapGraphIndexHarness(seed: 0x41, graphPolicy: policy)
        let lagging = WorkspaceCodemapSelectionGraph(rootEpoch: harness.rootEpoch, graphPolicy: policy)
        let follower = WorkspaceCodemapSelectionGraph(rootEpoch: harness.rootEpoch, graphPolicy: policy)
        let files = try harness.makeFiles(count: 640)
        var laggingStarted = false
        for start in stride(from: 0, to: files.count, by: 32) {
            let batch = Array(files[start ..< start + 32])
            for slots in [batch.map(\.pending), batch.map(\.contributed)] {
                let published = await harness.publish(slots, projectedTotal: UInt64(files.count))
                XCTAssertTrue(published)
                _ = await harness.pull()
                // A second consumer that keeps up (without acknowledging) stays on exact diffs.
                _ = await harness.pull(into: follower, acknowledge: false)
                if !laggingStarted {
                    _ = await harness.pull(into: lagging, acknowledge: false)
                    laggingStarted = true
                }
            }
        }
        let ledger = try await harness.ledger()
        XCTAssertGreaterThan(ledger.acknowledgedPruneCount, 0)
        let laggingBefore = await lagging.incrementalAccounting()
        XCTAssertLessThan(laggingBefore.appliedGeneration, ledger.floorGeneration)

        // The lagging consumer falls behind the pruned floor and must resync from a checkpoint.
        let resync = await harness.pull(into: lagging, acknowledge: false)
        guard case .committed(_, _, _, _, true) = resync else {
            return XCTFail("A consumer behind the floor must receive a checkpoint, got \(String(describing: resync))")
        }
        let primary = try await harness.latestSnapshot()
        let laggingSnapshot = try await harness.latestSnapshot(lagging)
        let followerSnapshot = try await harness.latestSnapshot(follower)
        assertSameGraph(laggingSnapshot, primary, "lagging")
        assertSameGraph(followerSnapshot, primary, "follower")
        let followerAccounting = await follower.incrementalAccounting()
        XCTAssertEqual(followerAccounting.resyncCommitCount, 1, "A keeping-up consumer never resyncs")
    }

    func testFenceReentrancyRevokesIdenticallyInBothModes() async throws {
        for mode in [WorkspaceCodemapGraphReconcileMode.incremental, .alwaysFull] {
            let harness = try await CodemapGraphIndexHarness(seed: 0x51, mode: mode)
            let files = try harness.makeFiles(count: 64)
            let published = await harness.publish(files.map(\.contributed), projectedTotal: 65)
            XCTAssertTrue(published)
            _ = await harness.pull()

            // A rename needs a destructive fence. While the publication awaits it, another
            // publication re-enters the overlay and advances the generation.
            let renamed = try harness.makeSlot(
                fileID: files[3].fileID,
                path: "Sources/Moved/File3.swift",
                definitions: ["Type3"],
                references: ["Type0"],
                requestGeneration: 2
            )
            let interloper = try harness.makeSlot(
                fileID: harness.fileID(1, lane: 0x72),
                path: "Sources/Interloper.swift",
                definitions: ["Interloper"],
                references: ["Type0"]
            )
            let overlay = harness.overlay
            let rootEpoch = harness.rootEpoch
            let catalogToken = harness.catalogToken
            let graph = harness.graph
            let outcome = await overlay.publishGraphIndexSlots(
                rootEpoch: rootEpoch,
                catalogToken: catalogToken,
                slots: [renamed],
                catalogSealed: true,
                reconciliationFence: { fileIDs, reason in
                    _ = await overlay.publishGraphIndexSlots(
                        rootEpoch: rootEpoch,
                        catalogToken: catalogToken,
                        slots: [interloper],
                        catalogSealed: true
                    )
                    return await graph.fenceFiles(fileIDs: fileIDs, reason: reason)
                }
            )
            XCTAssertFalse(outcome, "\(mode)")
            let checkpoint = await overlay.graphCheckpoint(rootEpoch: rootEpoch)
            XCTAssertEqual(checkpoint, .revoked(.reconciliationFailed), "\(mode)")
            let changes = await overlay.graphChanges(rootEpoch: rootEpoch, since: .init(rawValue: 0))
            XCTAssertEqual(changes, .revoked(.reconciliationFailed), "\(mode)")
        }
    }

    func testCancelledApplyLeavesPinnedSnapshotIntact() async throws {
        let gate = CodemapGraphIndexGate()
        let harness = try await CodemapGraphIndexHarness(seed: 0x61, gate: gate)
        let files = try harness.makeFiles(count: 256)
        for start in stride(from: 0, to: 192, by: 64) {
            let published = await harness.publish(
                files[start ..< start + 64].map(\.contributed),
                projectedTotal: 256
            )
            XCTAssertTrue(published)
            _ = await harness.pull()
        }
        let pinned = try await harness.latestSnapshot()
        let materialized = CodemapMaterializedGraph(pinned)

        await gate.close()
        let published = await harness.publish(files[192 ..< 256].map(\.contributed), projectedTotal: 256)
        XCTAssertTrue(published)
        let apply = Task { await harness.pull() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while await gate.waiterCount == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiterCount = await gate.waiterCount
        XCTAssertEqual(waiterCount, 1)
        await harness.graph.shutdown(reason: .rootUnloaded)
        await gate.open()
        let disposition = await apply.value
        XCTAssertEqual(disposition, .cancelled)

        XCTAssertEqual(CodemapMaterializedGraph(pinned), materialized)
        switch await harness.graph.latestSnapshot() {
        case .revoked(.rootUnloaded): break
        case let other: XCTFail("Expected revocation after shutdown, got \(other)")
        }
    }

    func testMultipleRootsInOneOverlayStayIndependent() async throws {
        let first = try await CodemapGraphIndexHarness(seed: 0x81)
        let second = try await CodemapGraphIndexHarness(seed: 0x82, overlay: first.overlay)
        let firstAlone = try await CodemapGraphIndexHarness(seed: 0x81)
        let secondAlone = try await CodemapGraphIndexHarness(seed: 0x82)
        let firstFiles = try first.makeFiles(count: 320)
        let secondFiles = try second.makeFiles(count: 192, prefix: "Other")
        for start in stride(from: 0, to: 320, by: 32) {
            for (shared, alone, files) in [(first, firstAlone, firstFiles), (second, secondAlone, secondFiles)]
                where start < files.count
            {
                let batch = Array(files[start ..< min(start + 32, files.count)])
                for slots in [batch.map(\.pending), batch.map(\.contributed)] {
                    for harness in [shared, alone] {
                        let published = await harness.publish(slots, projectedTotal: UInt64(files.count))
                        XCTAssertTrue(published)
                        _ = await harness.pull()
                    }
                }
            }
        }
        for harness in [first, second, firstAlone, secondAlone] {
            let published = await harness.publish([], enumerationFinished: true)
            XCTAssertTrue(published)
            _ = await harness.pull()
        }
        let firstShared = try await first.latestSnapshot()
        let firstIsolated = try await firstAlone.latestSnapshot()
        let secondShared = try await second.latestSnapshot()
        let secondIsolated = try await secondAlone.latestSnapshot()
        assertSameGraph(firstShared, firstIsolated, "first root")
        assertSameGraph(secondShared, secondIsolated, "second root")
        let firstCheckpoint = try await first.checkpoint()
        let secondCheckpoint = try await second.checkpoint()
        XCTAssertTrue(Set(firstCheckpoint.slots.map(\.fileID)).isDisjoint(with: secondCheckpoint.slots.map(\.fileID)))
    }

    // MARK: - Live layer

    func testPathScopedReconcileWorkIsIndependentOfLiveLayerSize() async throws {
        let liveCount = 384
        let repository = try ReviewGitRepositoryFixture(name: #function)
        var repositoryFiles: [String: String] = [:]
        for index in 0 ..< liveCount {
            repositoryFiles["Live/File\(index).swift"] = "struct Live\(index) {}\n"
        }
        let rootURL = try repository.makeRepository(named: "root", files: repositoryFiles)
        addTeardownBlock { repository.cleanup() }
        let service = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: Data(repeating: 0x6C, count: GitBlobRepositoryNamespace.saltByteCount),
            hooks: .none
        )
        let request = WorkspaceCodemapGitCapabilityRequest(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            loadedRootURL: rootURL
        )
        guard case let .eligible(capability) = await service.resolve(root: request) else {
            return XCTFail("The fixture repository must be codemap eligible")
        }

        var maximumVisits: [WorkspaceCodemapGraphReconcileMode: [Int: UInt64]] = [:]
        var checkpoints: [WorkspaceCodemapGraphCheckpointDisposition] = []
        for mode in [WorkspaceCodemapGraphReconcileMode.incremental, .alwaysFull] {
            for seededLiveCount in [0, liveCount] {
                let overlay = WorkspaceCodemapLiveOverlay(graphReconcileMode: mode)
                let harness = try await CodemapGraphIndexHarness(
                    seed: 0x91,
                    overlay: overlay,
                    capability: capability
                )
                let livePaths = (0 ..< seededLiveCount).map { "Live/File\($0).swift" }
                let authorities = await service.makeSourceAuthorities(
                    capability: capability,
                    observedRootEpoch: capability.rootEpoch,
                    observedRepositoryAuthority: capability.repositoryAuthority,
                    candidates: livePaths.map {
                        WorkspaceCodemapSourceAuthorityRequest(
                            candidateRepositoryRelativePath: $0,
                            observedPathGeneration: 1,
                            currentPathGeneration: 1,
                            observedIngressGeneration: 1,
                            currentIngressGeneration: 1
                        )
                    }
                )
                let locator = try GitBlobCodeMapLocatorIdentity(
                    repositoryNamespace: capability.repositoryNamespace,
                    objectFormat: capability.objectFormat,
                    blobOID: String(repeating: "a", count: 40),
                    pipelineIdentity: harness.pipeline
                )
                for (index, path) in livePaths.enumerated() {
                    let identity = try harness.makeIdentity(fileID: harness.fileID(index, lane: 0x50), path: path)
                    let authority = try XCTUnwrap(authorities[index])
                    let expectation = try XCTUnwrap(WorkspaceCodemapSourceExpectation.cleanGitBlob(
                        bindingIdentity: identity,
                        locatorIdentity: locator,
                        sourceAuthority: authority
                    ))
                    let token = try XCTUnwrap(WorkspaceCodemapArtifactRequestToken.issue(
                        identity: identity,
                        requestGeneration: 1,
                        catalogGeneration: 3,
                        sourceExpectation: expectation
                    ))
                    guard case .started = await overlay.beginDemand(owner: WorkspaceCodemapLiveDemandOwner(), token: token) else {
                        return XCTFail("Live demand \(path) did not start")
                    }
                }
                let seeded = try await harness.ledger()
                XCTAssertTrue(seeded.liveEntriesIndexedByPath)
                XCTAssertEqual(seeded.slotCount, seededLiveCount)

                // Index slots for 64 of the live paths (same file IDs: live state wins) and for
                // unrelated paths, in batches.
                let overlapping = try (0 ..< min(64, seededLiveCount)).map { index in
                    try harness.makeSlot(
                        fileID: harness.fileID(index, lane: 0x50),
                        path: "Live/File\(index).swift",
                        definitions: ["Live\(index)"],
                        references: ["Type0"]
                    )
                }
                let files = try harness.makeFiles(count: 1024)
                var visits: [UInt64] = []
                for start in stride(from: 0, to: files.count, by: 64) {
                    let published = await harness.publish(
                        files[start ..< start + 64].map(\.contributed),
                        projectedTotal: UInt64(files.count + seededLiveCount)
                    )
                    XCTAssertTrue(published)
                    let ledger = try await harness.ledger()
                    visits.append(ledger.lastReconcileVisitCount)
                }
                if !overlapping.isEmpty {
                    let published = await harness.publish(
                        overlapping,
                        projectedTotal: UInt64(files.count + seededLiveCount)
                    )
                    XCTAssertTrue(published)
                }
                maximumVisits[mode, default: [:]][seededLiveCount] = visits.max() ?? 0
                if seededLiveCount == liveCount {
                    let checkpoint = await overlay.graphCheckpoint(rootEpoch: harness.rootEpoch)
                    checkpoints.append(checkpoint)
                    let ledger = try await harness.ledger()
                    if mode == .incremental {
                        XCTAssertEqual(ledger.incrementalFallbackCount, 0)
                    }
                }
            }
        }
        // Path-scoped reconciliation resolves live state through the path index: its work does
        // not depend on how many live entries exist. Full reconciliation walks every layer.
        let incremental = try XCTUnwrap(maximumVisits[.incremental])
        XCTAssertEqual(incremental[0], incremental[liveCount])
        XCTAssertLessThanOrEqual(incremental[liveCount] ?? .max, 8 * 64)
        let full = try XCTUnwrap(maximumVisits[.alwaysFull])
        XCTAssertGreaterThan(full[liveCount] ?? 0, full[0] ?? 0)
        // Live precedence is identical in both modes.
        XCTAssertEqual(checkpoints.count, 2)
        XCTAssertEqual(checkpoints.first, checkpoints.last)
    }

    // MARK: - Engine diagnostics and warm relaunch

    func testGraphIndexReportsBatchTimingAndWarmRelaunchReusesArtifacts() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(
            named: "root",
            files: [
                "Sources/First.swift": "struct First { let second: Second }\n",
                "Sources/Second.swift": "struct Second {}\n",
                "Sources/Third.swift": "struct Third { let first: First }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let store = fixture.makeStore()
        addTeardownBlock {
            await fixture.shutdown()
            repository.cleanup()
        }

        let firstLoad = try await store.loadRoot(path: rootURL.path)
        let engine = try fixture.runtime().bindingEngine()
        let firstRun = try await waitForGraphCompletion(engine: engine, rootID: firstLoad.id)
        XCTAssertGreaterThan(firstRun.batchTiming.batchCount, 0)
        XCTAssertGreaterThanOrEqual(firstRun.batchTiming.publishedSlotCount, 3)
        XCTAssertGreaterThan(firstRun.batchTiming.totalBatchDurationNanoseconds, 0)
        XCTAssertGreaterThanOrEqual(
            firstRun.batchTiming.totalBatchDurationNanoseconds,
            firstRun.batchTiming.maximumBatchDurationNanoseconds
        )
        let afterFirst = await engine.accounting()
        XCTAssertGreaterThanOrEqual(afterFirst.counters.graphIndexPublishedSlots, 3)
        XCTAssertGreaterThan(afterFirst.counters.graphIndexBatchNanoseconds, 0)
        let buildsAfterFirst = fixture.builtSourceTexts.values.count
        XCTAssertGreaterThan(buildsAfterFirst, 0)

        // A warm relaunch of the unchanged root rebuilds the in-memory graph from durable
        // artifacts; it must not parse any source again.
        await store.unloadRoot(id: firstLoad.id)
        let secondLoad = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock { await store.unloadRoot(id: secondLoad.id) }
        let secondRun = try await waitForGraphCompletion(
            engine: engine,
            rootID: secondLoad.id,
            excluding: firstRun.rootEpoch
        )
        XCTAssertEqual(secondRun.progress.counts.processedCandidateCount, 3)
        XCTAssertEqual(fixture.builtSourceTexts.values.count, buildsAfterFirst)
        let afterSecond = await engine.accounting()
        XCTAssertEqual(
            afterSecond.counters.graphIndexArtifactBuildsStarted,
            afterFirst.counters.graphIndexArtifactBuildsStarted
        )
    }

    /// Completion is observable: once the engine reports a root complete, the selection graph must
    /// already expose full coverage, even while the pull loop is paused between commits (#1085).
    func testGraphIndexCompletionImpliesGraphCoverageWhilePullLoopIsPaused() async throws {
        let fileCount = 6
        var sources: [String: String] = [:]
        for index in 0 ..< fileCount {
            sources["Sources/File\(index).swift"] = "struct File\(index) { let next: File\((index + 1) % fileCount) }\n"
        }
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(named: "root", files: sources)
        // The gate never opens on its own: a pause ends only through a flush or cancellation.
        let gate = CodemapGraphIndexGate()
        await gate.close()
        let pauses = CodemapLockedValues<UInt64>()
        let fixture = try CodemapStoreFixture(
            name: #function,
            enginePolicy: WorkspaceCodemapBindingEnginePolicy(
                maximumGraphIndexCatalogPageEntryCount: 1,
                maximumGraphIndexBatchCandidateCount: 1
            ),
            graphPullPause: WorkspaceCodemapGraphPullPause { applyNanoseconds in
                pauses.append(applyNanoseconds)
                await gate.pass()
            }
        )
        let store = fixture.makeStore()
        addTeardownBlock {
            await gate.open()
            await fixture.shutdown()
            repository.cleanup()
        }

        let loaded = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock { await store.unloadRoot(id: loaded.id) }
        let engine = try fixture.runtime().bindingEngine()
        let rootEpoch = try await waitForGraphIndexRoot(engine: engine, rootID: loaded.id)

        // Hold further pages until the pull loop has committed and entered the gated pause, so
        // the completing publication provably arrives while the loop is paused.
        let hold = await engine.debugAcquireGraphIndexAdmissionHold(
            rootEpoch: rootEpoch,
            expiresAfterMilliseconds: 600_000
        )
        let holdID = try XCTUnwrap(hold?.holdID)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while pauses.values.isEmpty, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(pauses.values.isEmpty, "The pull loop must be paused before indexing completes")
        let completedBeforePause = await engine.accounting().graphIndexRoots
            .first { $0.rootEpoch == rootEpoch }?.phase == .complete
        XCTAssertFalse(completedBeforePause, "The admission hold must keep indexing incomplete")
        _ = await engine.debugReleaseGraphIndexAdmissionHold(holdID, rootEpoch: rootEpoch)

        let completed = try await waitForGraphCompletion(engine: engine, rootID: loaded.id)
        XCTAssertEqual(completed.progress.counts.processedCandidateCount, UInt64(fileCount))
        let maybeGraph = await engine.selectionGraph(rootEpoch: rootEpoch)
        let graph = try XCTUnwrap(maybeGraph)
        guard case let .ready(pinned) = await graph.latestSnapshot() else {
            return XCTFail("A completed root must publish a graph snapshot")
        }
        XCTAssertTrue(pinned.snapshot.coverage.isComplete)
        XCTAssertEqual(pinned.snapshot.coverage.pendingCount, 0)
        XCTAssertEqual(pinned.snapshot.nodesByFileID.count, fileCount)
    }

    // MARK: - Helpers

    private func waitForGraphIndexRoot(
        engine: WorkspaceCodemapBindingEngine,
        rootID: UUID
    ) async throws -> WorkspaceCodemapRootEpoch {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            let accounting = await engine.accounting()
            if let root = accounting.graphIndexRoots.first(where: { $0.rootEpoch.rootID == rootID }) {
                return root.rootEpoch
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CodemapGraphIndexHarnessError.timedOut
    }

    private func waitForGraphCompletion(
        engine: WorkspaceCodemapBindingEngine,
        rootID: UUID,
        excluding excludedRootEpoch: WorkspaceCodemapRootEpoch? = nil
    ) async throws -> WorkspaceCodemapBindingEngineGraphIndexRootAccounting {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            let accounting = await engine.accounting()
            if let root = accounting.graphIndexRoots.first(where: {
                $0.rootEpoch.rootID == rootID && $0.rootEpoch != excludedRootEpoch
            }),
                root.phase == .complete
            {
                return root
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CodemapGraphIndexHarnessError.timedOut
    }

    /// Compares the two overlays' ledgers and the graphs each one fed, and (when constructible)
    /// the incrementally applied graph against a from-scratch checkpoint rebuild.
    private func assertParity(
        _ incremental: CodemapGraphIndexHarness,
        _ full: CodemapGraphIndexHarness,
        step: String,
        expectCheckpoint: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let left = await incremental.overlay.graphCheckpoint(rootEpoch: incremental.rootEpoch)
        let right = await full.overlay.graphCheckpoint(rootEpoch: full.rootEpoch)
        XCTAssertEqual(left, right, step, file: file, line: line)
        if expectCheckpoint, case .revoked = left {
            XCTFail("Expected a constructible checkpoint at \(step)", file: file, line: line)
        }
        let leftLedger = try await incremental.ledger()
        let rightLedger = try await full.ledger()
        XCTAssertEqual(leftLedger.contributionGeneration, rightLedger.contributionGeneration, step, file: file, line: line)
        XCTAssertEqual(leftLedger.floorGeneration, rightLedger.floorGeneration, step, file: file, line: line)
        XCTAssertEqual(leftLedger.slotCount, rightLedger.slotCount, step, file: file, line: line)
        let leftChanges = await incremental.overlay.graphChanges(
            rootEpoch: incremental.rootEpoch,
            since: leftLedger.floorGeneration
        )
        let rightChanges = await full.overlay.graphChanges(rootEpoch: full.rootEpoch, since: rightLedger.floorGeneration)
        XCTAssertEqual(leftChanges, rightChanges, step, file: file, line: line)

        let incrementalGraph = try await incremental.latestSnapshot()
        let fullGraph = try await full.latestSnapshot()
        assertSameGraph(incrementalGraph, fullGraph, "graphs at \(step)", file: file, line: line)
        if case .checkpoint = left {
            let rebuilt = try await incremental.rebuiltFromCheckpoint()
            assertSameGraph(incrementalGraph, rebuilt, "rebuild at \(step)", file: file, line: line)
        }
    }
}
