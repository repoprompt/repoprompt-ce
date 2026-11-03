import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptFileSystem
import RepoPromptFoundation
import RepoPromptSettingsCore
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceProjectionDecodeTests: XCTestCase {
        typealias Diagnostics = WorkspaceProjectionDecodeDiagnostics

        func testWorkspacePresetCodablePreservesComparisonPortFilenameBytes() throws {
            let paths = ["/repo/file ", "relative\n", " ", "/repo/caf\u{e9}", "/repo/cafe\u{301}"]
            let preset = WorkspacePreset(name: "Exact stored paths", selectedFilePaths: paths)
            let restored = try JSONDecoder().decode(WorkspacePreset.self, from: JSONEncoder().encode(preset))
            XCTAssertEqual(restored.selectedFilePaths.map { Array($0.utf8) }, paths.map { Array($0.utf8) })
            XCTAssertFalse(WorkspaceManagerViewModel.isPresetSelectionDirty(
                presetPaths: [restored.selectedFilePaths[0]], selectionPaths: [(absolute: paths[0], relative: "file ")]
            ))
            XCTAssertTrue(WorkspaceManagerViewModel.isPresetSelectionDirty(
                presetPaths: [restored.selectedFilePaths[0]], selectionPaths: [(absolute: "/repo/file", relative: "file")]
            ))
        }

        func testDirtyBytesAtSameURLProduceCurrentIsolatedValues() throws {
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            let first = try fixture.bytes(revision: 1)
            let second = try fixture.bytes(revision: 2)
            var left = try fixture.decode(first)
            let right = try fixture.decode(first)
            left.composeTabs[0].promptText = "local edit"
            left.composeTabs[0].selection = StoredSelection(selectedPaths: ["local selection"])
            left.presets[0].selectedFilePaths.removeAll()
            XCTAssertTrue(right == fixture.model(revision: 1), "Another consumer must retain its complete value")
            XCTAssertTrue(try fixture.decode(first) == right, "Local mutation must not affect a subsequent decode")
            XCTAssertTrue(try fixture.decode(second) == fixture.model(revision: 2), "Dirty bytes at the same URL must win")
        }

        func testDecodeFailureRetainsValueAndCorrectionUsesCurrentBytes() throws {
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            var current = try fixture.decode(fixture.bytes(revision: 1))
            XCTAssertThrowsError(current = try fixture.decode(Data("{".utf8)))
            XCTAssertTrue(current == fixture.model(revision: 1))
            current = try fixture.decode(fixture.bytes(revision: 2))
            XCTAssertTrue(current == fixture.model(revision: 2))
        }

        func testScopedRecordingIsBoundedAndPrivacySafe() throws {
            let recorder = Diagnostics.Recorder()
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            let bytes = try fixture.bytes(revision: 1)
            let context = Diagnostics.Context(
                recorder: recorder, contentOrdinal: 1, consumerOrdinal: 1,
                revision: 1, schemaVersion: 1, onMainActor: true
            )
            XCTAssertThrowsError(try Diagnostics.contextTaskLocal.withValue(context) {
                try fixture.decode(Data("{PRIVATE_PAYLOAD_AND_PATH".utf8))
            })
            XCTAssertNil(Diagnostics.context, "Throwing must restore the task-local scope")
            try Diagnostics.contextTaskLocal.withValue(context) {
                for _ in 0 ..< Diagnostics.Recorder.maximumSamples + 1 {
                    // The digest cache must not turn repeat decodes into hits:
                    // this test measures per-decode work, so decode fresh.
                    WorkspaceFileDecodeCache.shared.removeAllForTesting()
                    _ = try fixture.decode(bytes)
                }
            }
            let snapshot = recorder.snapshot()
            XCTAssertEqual(snapshot.samples.count, Diagnostics.Recorder.maximumSamples)
            XCTAssertEqual(snapshot.droppedCount, 2)
            XCTAssertFalse(try XCTUnwrap(snapshot.samples.first).succeeded)
            let success = try XCTUnwrap(snapshot.samples.last)
            XCTAssertTrue(success.succeeded)
            XCTAssertEqual(success.inputBytes, bytes.count)
            XCTAssertEqual(success.normalizationCount, 2)
            XCTAssertEqual(success.normalizationMutationCount, 0)
            XCTAssertEqual(success.mainActorNanoseconds, success.wallNanoseconds)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(success)) as? [String: Any])
            XCTAssertEqual(Set(json.keys), Set([
                "contentOrdinal", "consumerOrdinal", "revision", "schemaVersion", "normalizationVersion",
                "inputBytes", "succeeded", "wallNanoseconds", "mainActorNanoseconds", "normalizationCount",
                "normalizationMutationCount", "normalizationNanoseconds"
            ]))
            XCTAssertTrue(json.values.allSatisfy { $0 is NSNumber }, "Only numeric/boolean fields may be exported")
            _ = try fixture.decode(bytes)
            XCTAssertEqual(recorder.snapshot().droppedCount, 2, "Unscoped work must not enter an expired recorder")
        }

        func testLegacyNormalizationRecordsBothPassesWithoutChangingBehavior() throws {
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            var legacy = fixture.model(revision: 1)
            legacy.composeTabs = []
            legacy.activeComposeTabID = nil
            let bytes = try JSONEncoder().encode(legacy)
            let recorder = Diagnostics.Recorder()
            let decoded = try Diagnostics.contextTaskLocal.withValue(.init(
                recorder: recorder, contentOrdinal: 1, consumerOrdinal: 1,
                revision: 1, schemaVersion: 1, onMainActor: true
            )) { try fixture.decode(bytes) }
            XCTAssertEqual(decoded.composeTabs.count, 1)
            XCTAssertEqual(decoded.activeComposeTabID, decoded.composeTabs[0].id)
            XCTAssertTrue(decoded.normalizationRequiresSave)
            let sample = try XCTUnwrap(recorder.snapshot().samples.first)
            XCTAssertEqual(sample.normalizationCount, 2)
            XCTAssertEqual(sample.normalizationMutationCount, 1)
        }

        func testMeasurementMatrix() throws {
            try XCTSkipUnless(
                ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"] == "1",
                "Opt-in diagnostic: see docs/testing.md#workspace-projection-decode-diagnostics"
            )
            try WorkspaceProjectionDecodeMatrix.run()
        }
    }

    /// Synthetic persisted structures, built/encoded outside measurement. No actual files are read.
    struct WorkspaceProjectionDecodeFixture {
        enum Workload: String, CaseIterable, Codable {
            case ordinary, busy, large

            var dimensions: (tabs: Int, stashed: Int, paths: Int, presets: Int, promptBytes: Int) {
                switch self {
                case .ordinary: (2, 0, 20, 2, 2048)
                case .busy: (10, 5, 100, 10, 8192)
                case .large: (25, 20, 250, 20, 16384)
                }
            }
        }

        let workload: Workload
        /// Deliberately nonexistent, identical for every revision, never passed to a disk loader.
        private let fileURL = URL(fileURLWithPath: "/synthetic-workspace-projection/workspace.json")

        func model(revision: Int) -> WorkspaceModel {
            let dimensions = workload.dimensions
            let date = Date(timeIntervalSince1970: 100)
            let paths = (0 ..< dimensions.paths).map { "/synthetic-root/folder\($0 / 10)/file\($0).swift" }
            let folders = (0 ..< max(1, dimensions.paths / 10)).map { "/synthetic-root/folder\($0)" }
            let selection = StoredSelection(
                selectedPaths: paths, manualCodemapPaths: Array(paths.prefix(2)),
                slices: [paths[0]: [LineRange(start: 1, end: 10, description: "synthetic slice")]]
            )
            let tabs = (0 ..< dimensions.tabs + dimensions.stashed).map { index in
                ComposeTabState(
                    id: Self.id(index + 10), name: "Tab \(index)", lastModified: date,
                    selection: selection, expandedFolders: folders,
                    promptText: String(repeating: "p", count: dimensions.promptBytes - 1) + String(revision)
                )
            }
            let presets = (0 ..< dimensions.presets).map { index in
                WorkspacePreset(
                    id: Self.id(index + 100),
                    name: "Preset \(index)",
                    selectedFilePaths: paths,
                    expandedFolders: folders,
                    lastUpdated: date
                )
            }
            return WorkspaceModel(
                id: Self.id(1), dateModified: date, name: "Synthetic", repoPaths: ["/synthetic-root"],
                presets: presets, lastUsed: date, currentPromptText: "Revision \(revision)",
                composeTabs: Array(tabs.prefix(dimensions.tabs)), activeComposeTabID: tabs[0].id,
                stashedTabs: tabs.suffix(dimensions.stashed).enumerated().map { index, tab in
                    StashedTab(id: Self.id(index + 200), tab: tab, stashedAt: date)
                }
            )
        }

        func bytes(revision: Int) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return try encoder.encode(model(revision: revision))
        }

        func decode(_ bytes: Data) throws -> WorkspaceModel {
            try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(documentBytes: bytes, fileURL: fileURL)
        }

        private static func id(_ ordinal: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", ordinal))!
        }
    }

    /// Regression coverage for the digest-keyed decode cache behind
    /// `WorkspaceManagerViewModel.decodeDomainWorkspaceProjection` /
    /// `WorkspaceFileDecodeCache.decodeWorkspace(documentBytes:)`.
    ///
    /// The decode output is a pure function of the document bytes, so identical
    /// payloads (the same workspace projected into N windows, or a file whose
    /// metadata changed without content changes) must decode once process-wide.
    @MainActor
    final class WorkspaceDigestDecodeCacheTests: XCTestCase {
        private var savedLimits: (maxEntries: Int, maxInputBytes: Int)?

        override func setUp() async throws {
            let cache = WorkspaceFileDecodeCache.shared
            savedLimits = cache.decodeCacheLimitsForTesting()
            cache.removeAllForTesting()
        }

        override func tearDown() async throws {
            let cache = WorkspaceFileDecodeCache.shared
            if let savedLimits {
                cache.setDecodeCacheLimitsForTesting(
                    maxEntries: savedLimits.maxEntries,
                    maxInputBytes: savedLimits.maxInputBytes
                )
            }
            cache.removeAllForTesting()
        }

        /// A second decode of identical bytes must hit the cache and return an
        /// equal model — including across different file URLs (content, not
        /// location, is the key).
        func testIdenticalBytesDecodeOnceAndReturnEqualModels() throws {
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            let bytes = try fixture.bytes(revision: 1)
            let otherURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("other-\(UUID().uuidString).json")

            let first = try fixture.decode(bytes)
            let second = try fixture.decode(bytes)
            let third = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: bytes, fileURL: otherURL
            )

            XCTAssertEqual(first, fixture.model(revision: 1))
            XCTAssertEqual(second, first)
            XCTAssertEqual(third, first)

            let stats = WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting()
            XCTAssertEqual(stats.misses, 1)
            XCTAssertEqual(stats.hits, 2)
            XCTAssertEqual(stats.entries, 1)
        }

        /// Cache hits must return an independent value: mutating a decoded
        /// model must not corrupt the cached copy served to other consumers.
        func testCacheHitIsIsolatedFromCallerMutation() throws {
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            let bytes = try fixture.bytes(revision: 1)

            var first = try fixture.decode(bytes)
            first.name = "caller-mutated"
            first.composeTabs[0].promptText = "caller edit"

            let second = try fixture.decode(bytes)
            XCTAssertEqual(second, fixture.model(revision: 1))
            XCTAssertNotEqual(second.name, "caller-mutated")
        }

        /// Changed bytes must miss the cache and decode fresh content.
        func testChangedBytesMissCache() throws {
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            let rev1 = try fixture.bytes(revision: 1)
            let rev2 = try fixture.bytes(revision: 2)

            _ = try fixture.decode(rev1)
            let afterFirst = WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting()

            let second = try fixture.decode(rev2)
            XCTAssertEqual(second, fixture.model(revision: 2))

            let stats = WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting()
            XCTAssertEqual(stats.misses, afterFirst.misses + 1)
            XCTAssertEqual(stats.entries, 2)
        }

        /// Decode failures must not be cached: a later decode of the same bad
        /// bytes throws again rather than serving a cached result.
        func testFailedDecodeIsNotCached() throws {
            let bad = Data("{".utf8)
            let fileURL = URL(fileURLWithPath: "/tmp/x.json")
            XCTAssertThrowsError(
                try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: bad, fileURL: fileURL
                )
            )
            let stats = WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting()
            XCTAssertEqual(stats.entries, 0)
            XCTAssertThrowsError(
                try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: bad, fileURL: fileURL
                )
            )
            XCTAssertEqual(
                WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting().entries, 0
            )
        }

        /// The cache must stay bounded: with a small entry limit, decoding more
        /// distinct documents evicts the least-recently-used entries.
        func testEntryBoundEvictsLeastRecentlyUsed() throws {
            let cache = WorkspaceFileDecodeCache.shared
            cache.setDecodeCacheLimitsForTesting(maxEntries: 2, maxInputBytes: .max)
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)

            _ = try fixture.decode(fixture.bytes(revision: 1))
            _ = try fixture.decode(fixture.bytes(revision: 2))
            _ = try fixture.decode(fixture.bytes(revision: 3))

            var stats = cache.digestDecodeStatsForTesting()
            XCTAssertEqual(stats.entries, 2)

            // Rev. 1 was evicted; rev. 2 and 3 remain cached.
            _ = try fixture.decode(fixture.bytes(revision: 1))
            stats = cache.digestDecodeStatsForTesting()
            XCTAssertEqual(stats.entries, 2)
        }

        /// The byte bound holds even when many documents are cached.
        func testInputByteBoundIsEnforced() throws {
            let cache = WorkspaceFileDecodeCache.shared
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            let bytes = try fixture.bytes(revision: 1)
            cache.setDecodeCacheLimitsForTesting(
                maxEntries: 1000, maxInputBytes: bytes.count * 3
            )

            for revision in 1 ... 6 {
                _ = try fixture.decode(fixture.bytes(revision: revision))
            }

            let stats = cache.digestDecodeStatsForTesting()
            XCTAssertLessThanOrEqual(stats.inputBytes, bytes.count * 3)
            XCTAssertLessThanOrEqual(stats.entries, 3)
        }

        /// Minimal documents missing persisted identities are decoded with
        /// synthesized `UUID()`/`Date()` fallbacks. Those results must NOT be
        /// memoized: two independent decodes of identical minimal bytes (two
        /// different files) must still receive independent identities.
        func testSynthesizedIdentitiesAreNeverCached() async throws {
            let minimal = Data(#"{"name":"Legacy","repoPaths":[]}"#.utf8)
            let fileURL = URL(fileURLWithPath: "/tmp/minimal-a.json")
            let otherURL = URL(fileURLWithPath: "/tmp/minimal-b.json")

            let first = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: minimal, fileURL: fileURL
            )
            let second = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: minimal, fileURL: otherURL
            )

            // Each decode synthesizes a fresh workspace identity — including
            // under a detached task, proving the recorder binding holds for
            // non-main-actor decodes.
            XCTAssertNotEqual(first.id, second.id)
            XCTAssertNotEqual(
                first.composeTabs.first?.id, second.composeTabs.first?.id
            )

            let detached = try await Task.detached {
                try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: minimal, fileURL: fileURL
                )
            }.value
            XCTAssertNotEqual(detached.id, first.id)
            XCTAssertNotEqual(detached.id, second.id)

            let stats = WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting()
            XCTAssertEqual(stats.entries, 0)
            XCTAssertEqual(stats.hits, 0)
            XCTAssertEqual(stats.misses, 3)
        }

        /// Two concurrent cold misses on the same bytes must converge to a
        /// single cache entry charged once — the storeDecoded replacement path.
        func testConcurrentColdMissesConvergeToSingleEntry() async throws {
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            let bytes = try fixture.bytes(revision: 1)
            let expected = fixture.model(revision: 1)
            let fileURL = URL(fileURLWithPath: "/tmp/concurrent.json")

            async let left = Task.detached {
                try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: bytes, fileURL: fileURL
                )
            }.value
            async let right = Task.detached {
                try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: bytes, fileURL: fileURL
                )
            }.value
            let results = try await [left, right]

            XCTAssertEqual(results[0], expected)
            XCTAssertEqual(results[1], expected)

            let stats = WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting()
            XCTAssertEqual(stats.entries, 1)
            XCTAssertEqual(stats.inputBytes, bytes.count)
        }

        /// Each synthesis site must independently keep a decode out of the
        /// cache — a single marker is enough, so the combined minimal-document
        /// test alone cannot prove every site is marked. Strip one field at a
        /// time from otherwise complete bytes and verify no entry is created.
        func testEachSynthesisSiteIndependentlyPreventsCaching() throws {
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            let fullBytes = try fixture.bytes(revision: 1)
            let fileURL = URL(fileURLWithPath: "/tmp/stripped.json")

            func decodedJSON(_ bytes: Data) throws -> [String: Any] {
                try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            }

            // (a) Workspace `dateModified` fallback — timestamp-only synthesis
            // with otherwise valid compose invariants (proves admission depends
            // on synthesis, not on normalizationRequiresSave).
            var workspaceJSON = try decodedJSON(fullBytes)
            workspaceJSON.removeValue(forKey: "dateModified")
            // (b) A preset's `id` fallback.
            var presetIDJSON = try decodedJSON(fullBytes)
            var presetsByID = try XCTUnwrap(presetIDJSON["presets"] as? [[String: Any]])
            presetsByID[0].removeValue(forKey: "id")
            presetIDJSON["presets"] = presetsByID
            // (c) A preset's `lastUpdated` fallback.
            var presetDateJSON = try decodedJSON(fullBytes)
            var presetsByDate = try XCTUnwrap(presetDateJSON["presets"] as? [[String: Any]])
            presetsByDate[0].removeValue(forKey: "lastUpdated")
            presetDateJSON["presets"] = presetsByDate
            // (d) Empty `composeTabs` — normalization synthesizes a tab.
            var noTabsJSON = try decodedJSON(fullBytes)
            noTabsJSON.removeValue(forKey: "composeTabs")
            noTabsJSON.removeValue(forKey: "activeComposeTabID")
            // (e) A tab's `id` fallback.
            var tabIDJSON = try decodedJSON(fullBytes)
            var tabsByID = try XCTUnwrap(tabIDJSON["composeTabs"] as? [[String: Any]])
            tabsByID[0].removeValue(forKey: "id")
            tabIDJSON["composeTabs"] = tabsByID
            // (f) A tab's `lastModified` fallback.
            var tabDateJSON = try decodedJSON(fullBytes)
            var tabsByDate = try XCTUnwrap(tabDateJSON["composeTabs"] as? [[String: Any]])
            tabsByDate[0].removeValue(forKey: "lastModified")
            tabDateJSON["composeTabs"] = tabsByDate

            let cases = [workspaceJSON, presetIDJSON, presetDateJSON, noTabsJSON, tabIDJSON, tabDateJSON]
            for (index, json) in cases.enumerated() {
                WorkspaceFileDecodeCache.shared.removeAllForTesting()
                let stripped = try JSONSerialization.data(withJSONObject: json)
                _ = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: stripped, fileURL: fileURL
                )
                _ = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: stripped, fileURL: fileURL
                )
                let stats = WorkspaceFileDecodeCache.shared.digestDecodeStatsForTesting()
                XCTAssertEqual(stats.entries, 0, "case \(index) must never enter the digest cache")
                XCTAssertEqual(stats.hits, 0, "case \(index) must never hit")
                XCTAssertEqual(stats.misses, 2)
            }
        }

        /// Storing the same digest twice (the concurrent cold-miss path) must
        /// converge to one entry charged once.
        func testReplacementStoreChargesEntryOnce() throws {
            let cache = WorkspaceFileDecodeCache.shared
            let fixture = WorkspaceProjectionDecodeFixture(workload: .ordinary)
            let model = fixture.model(revision: 1)
            let bytes = try fixture.bytes(revision: 1)

            cache.storeDecodedForTesting(
                workspace: model, normalizationRequiresSave: false,
                digest: "duplicate-digest", inputByteCount: bytes.count
            )
            cache.storeDecodedForTesting(
                workspace: model, normalizationRequiresSave: false,
                digest: "duplicate-digest", inputByteCount: bytes.count
            )

            let stats = cache.digestDecodeStatsForTesting()
            XCTAssertEqual(stats.entries, 1)
            XCTAssertEqual(stats.orderCount, 1)
            XCTAssertEqual(stats.inputBytes, bytes.count)
        }
    }
#endif

#if DEBUG
    /// #335: a single unreadable compose tab must not collapse the workspace into a fresh `T1`, and a
    /// lossy decode must preserve the original document before anything can save over it.
    final class WorkspaceComposeTabsLossyDecodeTests: XCTestCase {
        private var temporaryRoot: URL!

        override func setUp() async throws {
            WorkspaceFileDecodeCache.shared.removeAllForTesting()
            temporaryRoot = FileManager.default.temporaryDirectory
                .resolvingSymlinksInPath()
                .appendingPathComponent("lossy-compose-tabs-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        }

        override func tearDown() async throws {
            WorkspaceFileDecodeCache.shared.removeAllForTesting()
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        func testCleanDocumentDecodesAllTabsWithoutLossFlag() throws {
            let decoded = try JSONDecoder().decode(WorkspaceModel.self, from: cleanDocument())
            XCTAssertEqual(decoded.composeTabs.map(\.name), ["Alpha", "Beta", "Gamma"])
            XCTAssertEqual(decoded.composeTabsDroppedDuringDecode, 0)
            XCTAssertFalse(decoded.composeTabsDecodeWasLossy)
        }

        func testSingleUnreadableTabIsDroppedWhileSiblingsAndActiveTabSurvive() throws {
            let decoded = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: document(mutating: { $0 = corruptingTab(at: 1, in: $0) })
            )
            XCTAssertEqual(decoded.composeTabs.map(\.name), ["Alpha", "Gamma"])
            XCTAssertEqual(decoded.composeTabsDroppedDuringDecode, 1)
            XCTAssertTrue(decoded.composeTabsDecodeWasLossy)
            XCTAssertEqual(decoded.activeComposeTabID, Self.tabID(0), "The surviving active tab keeps its identity")
            XCTAssertFalse(decoded.normalizationRequiresSave)
        }

        func testUnreadableArrayStillFallsBackToSingleTabButIsFlagged() throws {
            let decoded = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: document(mutating: { $0["composeTabs"] = "not-an-array" })
            )
            XCTAssertEqual(decoded.composeTabs.count, 1)
            XCTAssertEqual(decoded.composeTabs[0].name, "T1")
            XCTAssertTrue(decoded.composeTabsDecodeWasLossy)
        }

        func testLossFlagIsTransientAndDoesNotAffectEqualityOrEncoding() throws {
            var decoded = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: document(mutating: { $0 = corruptingTab(at: 2, in: $0) })
            )
            let reencoded = try JSONDecoder().decode(WorkspaceModel.self, from: JSONEncoder().encode(decoded))
            XCTAssertFalse(reencoded.composeTabsDecodeWasLossy)
            XCTAssertEqual(reencoded.composeTabs.map(\.name), ["Alpha", "Beta"])
            decoded.composeTabsDroppedDuringDecode = 0
            XCTAssertEqual(reencoded, decoded)
        }

        func testLossyFileLoadPreservesOriginalBytesOnceAndSkipsNormalizationWriteback() throws {
            let original = try document(mutating: { $0["composeTabs"] = "not-an-array" })
            let fileURL = temporaryRoot.appendingPathComponent("workspace.json")
            try original.write(to: fileURL)

            let first = try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(
                at: fileURL, scheduleNormalizationWriteback: true
            )
            XCTAssertTrue(first.workspace.composeTabsDecodeWasLossy)
            XCTAssertTrue(first.normalizationRequiresSave, "Normalization synthesized T1")
            XCTAssertNil(first.normalizationSaveTask, "A lossy decode must not write itself back")

            let backupURL = WorkspaceUnreadableDocumentBackup.backupURL(for: fileURL, documentBytes: original)
            XCTAssertEqual(try Data(contentsOf: backupURL), original)
            XCTAssertEqual(try Data(contentsOf: fileURL), original, "The original file is untouched")

            // A second load (cache cleared) finds the existing backup and does not add another.
            WorkspaceFileDecodeCache.shared.removeAllForTesting()
            let second = try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(
                at: fileURL, scheduleNormalizationWriteback: true
            )
            XCTAssertNil(second.normalizationSaveTask)
            XCTAssertEqual(try backupFiles().count, 1)
            XCTAssertEqual(try Data(contentsOf: fileURL), original)
        }

        func testCleanFileLoadWritesNoBackup() throws {
            let original = try cleanDocument()
            let fileURL = temporaryRoot.appendingPathComponent("workspace.json")
            try original.write(to: fileURL)
            _ = try WorkspaceManagerViewModel.loadWorkspaceFromFileResult(
                at: fileURL, scheduleNormalizationWriteback: false
            )
            XCTAssertEqual(try backupFiles().count, 0)
        }

        func testDomainProjectionDecodePreservesOriginalBytesForExistingDocument() throws {
            let original = try document(mutating: { $0 = corruptingTab(at: 0, in: $0) })
            let fileURL = temporaryRoot.appendingPathComponent("workspace.json")
            try original.write(to: fileURL)

            let projected = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: original, fileURL: fileURL
            )
            XCTAssertEqual(projected.composeTabs.map(\.name), ["Beta", "Gamma"])
            XCTAssertEqual(try backupFiles().count, 1)
            XCTAssertEqual(
                try Data(contentsOf: WorkspaceUnreadableDocumentBackup.backupURL(for: fileURL, documentBytes: original)),
                original
            )

            // Projections whose workspace directory does not exist (synthetic, deleted) write nothing.
            let missingURL = temporaryRoot.appendingPathComponent("missing").appendingPathComponent("workspace.json")
            _ = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(documentBytes: original, fileURL: missingURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.deletingLastPathComponent().path))
        }

        func testProjectionOfJournalBytesIsPreservedEvenWhenCanonicalDocumentIsMissing() throws {
            let original = try document(mutating: { $0 = corruptingTab(at: 1, in: $0) })
            let fileURL = temporaryRoot.appendingPathComponent("workspace.json")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

            _ = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(documentBytes: original, fileURL: fileURL)
            let backupURL = WorkspaceUnreadableDocumentBackup.backupURL(for: fileURL, documentBytes: original)
            XCTAssertEqual(try Data(contentsOf: backupURL), original)
            XCTAssertTrue(backupURL.lastPathComponent.contains(DomainContentDigest.sha256(original)), "Full-digest locator")
        }

        // MARK: - Replacement guard (#335 follow-up)

        func testGuardRefusesReplacingUnreadableOriginalUntilBackupSucceeds() throws {
            let original = try document(mutating: { $0 = corruptingTab(at: 1, in: $0) })
            let reduced = try JSONEncoder().encode(JSONDecoder().decode(WorkspaceModel.self, from: original))
            let fileURL = temporaryRoot.appendingPathComponent("workspace.json")
            try original.write(to: fileURL)
            // Occupy the backup locator with a directory: publication must fail without removing it.
            let backupURL = WorkspaceUnreadableDocumentBackup.backupURL(for: fileURL, documentBytes: original)
            try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: false)

            XCTAssertThrowsError(try WorkspaceUnreadableDocumentBackup.replaceDocument(reduced, at: fileURL)) { error in
                XCTAssertTrue(error is WorkspaceRecoveryBackupBlockedError)
            }
            XCTAssertEqual(try Data(contentsOf: fileURL), original, "The unreadable original is untouched")
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue, "A conflicting entry is never removed")

            try FileManager.default.removeItem(at: backupURL)
            try WorkspaceUnreadableDocumentBackup.replaceDocument(reduced, at: fileURL)
            XCTAssertEqual(try Data(contentsOf: fileURL), reduced)
            XCTAssertEqual(try Data(contentsOf: backupURL), original, "The backup was published before the replacement")
        }

        func testGuardDoesNotBackUpCleanDocumentsOrOrdinaryTabRemoval() throws {
            let clean = try cleanDocument()
            var model = try JSONDecoder().decode(WorkspaceModel.self, from: clean)
            model.composeTabs.removeLast()
            let withoutGamma = try JSONEncoder().encode(model)
            let fileURL = temporaryRoot.appendingPathComponent("workspace.json")
            try clean.write(to: fileURL)

            try WorkspaceUnreadableDocumentBackup.replaceDocument(withoutGamma, at: fileURL)
            XCTAssertEqual(try Data(contentsOf: fileURL), withoutGamma)
            XCTAssertEqual(try backupFiles().count, 0)
        }

        func testDiskWriterReceiptCarriesTheRecoveryBackupRefusalToTheCaller() async throws {
            let original = try document(mutating: { $0["composeTabs"] = "not-an-array" })
            let reduced = try JSONEncoder().encode(JSONDecoder().decode(WorkspaceModel.self, from: original))
            let fileURL = temporaryRoot.appendingPathComponent("workspace.json")
            try original.write(to: fileURL)
            let backupURL = WorkspaceUnreadableDocumentBackup.backupURL(for: fileURL, documentBytes: original)
            try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: false)
            let writer = WorkspaceDiskWriter(
                policy: WorkspaceAppDiskWritePolicy(),
                backend: WorkspaceDiskWriteBackend(
                    queuedAtomicWrite: { data, url in try WorkspaceUnreadableDocumentBackup.replaceDocument(data, at: url) },
                    normalizationAtomicWrite: { data, url in try WorkspaceUnreadableDocumentBackup.replaceDocument(data, at: url) }
                )
            )

            let receipt = await writer.enqueueWorkspaceAwaitingReceipt(data: reduced, url: fileURL, metadata: nil)
            XCTAssertNotNil(WorkspaceManagerViewModel.recoveryBackupBlock(in: receipt))
            XCTAssertEqual(try Data(contentsOf: fileURL), original)

            try FileManager.default.removeItem(at: backupURL)
            let retried = await writer.enqueueWorkspaceAwaitingReceipt(data: reduced, url: fileURL, metadata: nil)
            guard case .written = retried else { return XCTFail("Expected a durable write, got \(retried)") }
            XCTAssertNil(WorkspaceManagerViewModel.recoveryBackupBlock(in: retried))
            XCTAssertEqual(try Data(contentsOf: backupURL), original)
        }

        // MARK: - Fixtures

        private static func tabID(_ ordinal: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", ordinal + 1))!
        }

        private func model() -> WorkspaceModel {
            let date = Date(timeIntervalSince1970: 100)
            let tabs = ["Alpha", "Beta", "Gamma"].enumerated().map { index, name in
                ComposeTabState(id: Self.tabID(index), name: name, lastModified: date, promptText: "prompt \(index)")
            }
            return WorkspaceModel(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                dateModified: date,
                name: "Lossy Fixture",
                repoPaths: ["/synthetic-root"],
                lastUsed: date,
                composeTabs: tabs,
                activeComposeTabID: tabs[0].id
            )
        }

        private func cleanDocument() throws -> Data {
            try document(mutating: { _ in })
        }

        private func document(mutating mutate: (inout [String: Any]) -> Void) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoder.encode(model())) as? [String: Any]
            )
            mutate(&object)
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        /// Replaces one tab's `promptText` with a number, which the tab decoder rejects.
        private func corruptingTab(at index: Int, in object: [String: Any]) -> [String: Any] {
            var object = object
            var tabs = object["composeTabs"] as? [[String: Any]] ?? []
            tabs[index]["promptText"] = 42
            object["composeTabs"] = tabs
            return object
        }

        private func backupFiles() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(WorkspaceUnreadableDocumentBackup.fileNamePrefix) }
        }
    }

    /// Task 0 of the #335 follow-up: a save refused for a missing recovery backup keeps the latest
    /// draft through catalog reconciliation and a peer publication, and an explicit Retry saves it
    /// against the authority's current baseline.
    @MainActor
    final class WorkspaceRecoveryBackupBlockTests: XCTestCase {
        static let draftMarker = "RECOVERY-BLOCKED-DRAFT"

        func testBlockedDraftSurvivesReconciliationAndPeerPublicationThenRetrySavesIt() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("recovery-blocked-draft-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let probe = DraftRefusalProbe()
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "recovery-blocked-draft",
                storageDirectory: root.appendingPathComponent("authority", isDirectory: true),
                workspaceStorageDirectory: root.appendingPathComponent("storage", isDirectory: true),
                eventDirectory: root.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil,
                durableReplacementGuard: DomainDurableReplacementGuard { try probe.protect($0) }
            ))
            try await runtime.start()
            let previousStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
            UserDefaults.standard.set(root.appendingPathComponent("storage").path, forKey: "GlobalCustomStorageURL")
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState(domainRuntime: runtime)
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            defer {
                if let previousStoragePath {
                    UserDefaults.standard.set(previousStoragePath, forKey: "GlobalCustomStorageURL")
                } else {
                    UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
                }
            }
            addTeardownBlock { @MainActor in
                window.beginClose()
                await window.domainWorkspacePresentationBridgeForTesting?.stopAndJoinForTesting()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
                _ = await runtime.shutdown()
                await WorkspaceDiskWriterComposition.processWriter.removeAllForTesting()
                try? FileManager.default.removeItem(at: root)
            }

            let manager = window.workspaceManager
            await manager.awaitInitialized()
            let creation = try manager.createPersistentWorkspace(name: "Recovery Blocked", repoPaths: [root.path])
            let created = try await creation.publishedWorkspace()
            let switched = await manager.switchWorkspace(to: created, saveState: false, reason: "recoveryBackupBlockTest")
            XCTAssertTrue(switched.didSwitch)
            let workspaceID = created.id
            let bridge = try XCTUnwrap(window.domainWorkspacePresentationBridgeForTesting)
            let refreshedValue = await bridge.refreshForAgentAdmission()
            XCTAssertTrue(refreshedValue)
            let beforeValue = await runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
            let before = try XCTUnwrap(beforeValue)
            let canonicalBefore = try Data(contentsOf: before.document.fileURL)

            // 1. The draft's save is refused: nothing durable changes and the block is visible.
            var draft = try XCTUnwrap(manager.workspace(withID: workspaceID))
            draft.composeTabs[0].promptText = Self.draftMarker
            let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceID })
            manager.workspaces[index] = draft
            do {
                _ = try await manager.saveWorkspaceToFileAsync(draft, source: "recoveryBackupBlockTest")
                XCTFail("The save must be refused while the recovery backup cannot be made")
            } catch {}
            XCTAssertNotNil(manager.recoveryBackupBlocks[workspaceID])
            XCTAssertEqual(try Data(contentsOf: before.document.fileURL), canonicalBefore)
            XCTAssertTrue(
                WorkspaceRecoveryBackupBlockBanner.message(reason: "x").contains("kept only in this window"),
                "The banner must not imply the draft is durable"
            )

            // 2. A same-revision catalog refresh keeps the draft.
            let sameRevisionRefresh = await bridge.refreshForAgentAdmission()
            XCTAssertTrue(sameRevisionRefresh)
            XCTAssertEqual(manager.workspace(withID: workspaceID)?.composeTabs[0].promptText, Self.draftMarker)

            // 3. A peer publication advances the canonical document; the draft still survives. The
            // refused save may already have journaled the draft as working state, so the peer
            // publishes against the authority's current snapshot.
            let currentValue = await runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
            let current = try XCTUnwrap(currentValue)
            var peer = try JSONDecoder().decode(WorkspaceModel.self, from: before.document.documentBytes)
            peer.composeTabs[0].promptText = "peer publication"
            let peerDocument = try DomainWorkspaceAuthorityClient.document(for: peer, fileURL: before.document.fileURL)
            let peerClient = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -991)
            let peerSave = try await peerClient.saveFailClosed(
                peerDocument,
                expectedWorkspaceRevision: current.revisions.workingRevision,
                expectedContentDigest: current.document.contentDigest
            )
            XCTAssertEqual(peerSave.saved?.disposition, .applied)
            let peerRefresh = await bridge.refreshForAgentAdmission()
            XCTAssertTrue(peerRefresh)
            XCTAssertEqual(manager.workspace(withID: workspaceID)?.composeTabs[0].promptText, Self.draftMarker)
            XCTAssertNotNil(manager.recoveryBackupBlocks[workspaceID])
            XCTAssertEqual(try Data(contentsOf: before.document.fileURL), peerDocument.documentBytes)

            // 4. Once the backup can be made, one explicit Retry saves the latest draft against the
            // authority's current baseline and clears the block.
            probe.setRefusing(false)
            let retried = await manager.retryRecoveryBackupBlockedSave(workspaceID: workspaceID)
            XCTAssertTrue(retried)
            XCTAssertNil(manager.recoveryBackupBlocks[workspaceID])
            let saved = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: before.document.fileURL))
            XCTAssertEqual(saved.composeTabs[0].promptText, Self.draftMarker)
        }
    }

    /// Refuses every durable replacement whose new bytes carry this window's draft marker, as a
    /// missing recovery backup would; peer writes are admitted.
    private final class DraftRefusalProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var refusing = true

        func setRefusing(_ value: Bool) {
            lock.withLock { refusing = value }
        }

        func protect(_ replacement: DomainDurableReplacement) throws {
            guard lock.withLock({ refusing }),
                  String(decoding: replacement.replacementBytes, as: UTF8.self)
                  .contains(WorkspaceRecoveryBackupBlockTests.draftMarker)
            else { return }
            throw WorkspaceRecoveryBackupBlockedError(reason: "injected backup failure")
        }
    }
#endif
