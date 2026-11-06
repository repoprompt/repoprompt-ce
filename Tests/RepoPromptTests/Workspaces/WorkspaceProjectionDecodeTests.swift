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
    /// draft through reconciliation; newer canonical contents merge at compose-tab level, and a
    /// conflicting change fails closed instead of being overwritten.
    @MainActor
    final class WorkspaceRecoveryBackupBlockTests: XCTestCase {
        static let draftMarker = "RECOVERY-BLOCKED-DRAFT"

        func testPeerEditOnAnotherTabMergesAndRetrySavesBoth() async throws {
            let fixture = try await BlockedWindowFixture.make(testCase: self, probe: DraftRefusalProbe())
            let manager = fixture.manager
            try await fixture.blockDraft(promptText: Self.draftMarker)

            fixture.probe.setRefusing(false)
            try await fixture.publishPeer { peer in
                peer.composeTabs.append(ComposeTabState(id: UUID(), name: "Peer tab", lastModified: Date(), promptText: "peer"))
            }

            let local = try XCTUnwrap(manager.workspace(withID: fixture.workspaceID))
            XCTAssertEqual(local.composeTabs.first?.name, Self.draftMarker, "The draft's tab is kept")
            XCTAssertTrue(local.composeTabs.contains { $0.name == "Peer tab" }, "The peer's new tab is merged in")
            XCTAssertNotNil(manager.recoveryBackupBlocks[fixture.workspaceID], "Saving stays blocked until a save succeeds")
            // The merged draft descends from the newer canonical contents, so it is journaled as
            // working state instead of failing every commit with a stale baseline.
            let deadline = Date().addingTimeInterval(10)
            var journaled: WorkspaceModel?
            while Date() < deadline {
                let snapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspaceID)
                journaled = try snapshot.map { try JSONDecoder().decode(WorkspaceModel.self, from: $0.document.documentBytes) }
                if journaled?.composeTabs.first?.name == Self.draftMarker { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(journaled?.composeTabs.first?.name, Self.draftMarker)
            XCTAssertTrue(journaled?.composeTabs.contains { $0.name == "Peer tab" } ?? false)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            XCTAssertEqual(
                manager.workspace(withID: fixture.workspaceID)?.composeTabs.first?.name, Self.draftMarker,
                "A later projection never replaces the held draft"
            )

            let retried = await manager.retryRecoveryBackupBlockedSave(workspaceID: fixture.workspaceID)
            XCTAssertTrue(retried)
            XCTAssertNil(manager.recoveryBackupBlocks[fixture.workspaceID])
            let saved = try fixture.savedModel()
            XCTAssertEqual(saved.composeTabs.first?.name, Self.draftMarker)
            XCTAssertTrue(saved.composeTabs.contains { $0.name == "Peer tab" }, "Retry never drops the peer's edit")
        }

        func testConflictingPeerEditFailsClosedUntilTheDraftIsDiscarded() async throws {
            let fixture = try await BlockedWindowFixture.make(testCase: self, probe: DraftRefusalProbe())
            let manager = fixture.manager
            try await fixture.blockDraft(promptText: Self.draftMarker)

            let peerDocument = try await fixture.publishPeer { peer in
                peer.composeTabs[0].name = "peer publication"
            }

            let block = try XCTUnwrap(manager.recoveryBackupBlocks[fixture.workspaceID])
            XCTAssertTrue(block.isConflicted)
            XCTAssertEqual(manager.workspace(withID: fixture.workspaceID)?.composeTabs.first?.name, Self.draftMarker)
            XCTAssertTrue(WorkspaceRecoveryBackupBlockBanner.message(for: block).contains("won't overwrite"))

            fixture.probe.setRefusing(false)
            let retried = await manager.retryRecoveryBackupBlockedSave(workspaceID: fixture.workspaceID)
            XCTAssertFalse(retried, "A conflicted draft is never saved over the newer contents")
            XCTAssertEqual(try Data(contentsOf: peerDocument.fileURL), peerDocument.documentBytes)

            manager.discardRecoveryBlockedDraft(workspaceID: fixture.workspaceID)
            let refreshed = await fixture.bridge.refreshForAgentAdmission()
            XCTAssertTrue(refreshed)
            XCTAssertNil(manager.recoveryBackupBlocks[fixture.workspaceID])
            XCTAssertEqual(manager.workspace(withID: fixture.workspaceID)?.composeTabs.first?.name, "peer publication")
        }

        func testWorkingCommitDoesNotClearASavedPhaseBlock() {
            let window = WindowState()
            addTeardownBlock { @MainActor in
                window.beginClose()
                await window.tearDown()
            }
            let manager = window.workspaceManager
            let workspaceID = UUID()
            let draft = WorkspaceModel(name: "Phases", repoPaths: [NSTemporaryDirectory()])
            manager.recordRecoveryBackupBlockForTesting(workspaceID: workspaceID, draft: draft, stateVersion: 3, phase: .saved)
            manager.applyRecoveryBackupCommitForTesting(workspaceID: workspaceID, stateVersion: 3, committedPhase: .working)
            XCTAssertNotNil(manager.recoveryBackupBlocks[workspaceID], "A journaled working copy is not the saved document")
            manager.applyRecoveryBackupCommitForTesting(workspaceID: workspaceID, stateVersion: 2, committedPhase: .saved)
            XCTAssertNotNil(manager.recoveryBackupBlocks[workspaceID], "An older save does not cover the blocked draft")
            manager.applyRecoveryBackupCommitForTesting(workspaceID: workspaceID, stateVersion: 3, committedPhase: .saved)
            XCTAssertNil(manager.recoveryBackupBlocks[workspaceID])

            manager.recordRecoveryBackupBlockForTesting(workspaceID: workspaceID, draft: draft, stateVersion: 4, phase: .working)
            manager.applyRecoveryBackupCommitForTesting(workspaceID: workspaceID, stateVersion: 4, committedPhase: .working)
            XCTAssertNil(manager.recoveryBackupBlocks[workspaceID])
        }

        func testUnknownBaseNeverComesFromTheProjectedDraftAndFailsClosed() async throws {
            let fixture = try await BlockedWindowFixture.make(testCase: self, probe: DraftRefusalProbe())
            let manager = fixture.manager
            let gate = CaptureGate()
            manager.recoveryBackupBaseCaptureGateForTesting = { [gate] in await gate.hold() }
            defer {
                manager.recoveryBackupBaseCaptureGateForTesting = nil
                gate.release()
            }
            try await fixture.blockDraft(promptText: Self.draftMarker, waitForBase: false)
            XCTAssertEqual(manager.recoveryBackupBlocks[fixture.workspaceID]?.phase, .working)
            let deadline = Date().addingTimeInterval(10)
            while !gate.isHolding, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            // A reconciliation while the write baseline still matches may project the window's own
            // draft; it must not become the merge base.
            let refreshed = await fixture.bridge.refreshForAgentAdmission()
            XCTAssertTrue(refreshed)
            XCTAssertNil(manager.recoveryBackupBlocks[fixture.workspaceID]?.base)

            try await fixture.publishPeer { peer in
                peer.composeTabs[0].name = "peer rename"
            }
            let block = try XCTUnwrap(manager.recoveryBackupBlocks[fixture.workspaceID])
            XCTAssertTrue(block.isConflicted, "An unknown base never lets newer contents silently win")
            XCTAssertEqual(manager.workspace(withID: fixture.workspaceID)?.composeTabs.first?.name, Self.draftMarker)
            gate.release()
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertTrue(manager.recoveryBackupBlocks[fixture.workspaceID]?.isConflicted ?? false)
        }

        func testSavedDocumentRefusalRecordsTheSavedPhaseFromTheTypedLocation() async throws {
            let fixture = try await BlockedWindowFixture.make(testCase: self, probe: DraftRefusalProbe(savedDocumentOnly: true))
            try await fixture.blockDraft(promptText: Self.draftMarker)
            XCTAssertEqual(fixture.manager.recoveryBackupBlocks[fixture.workspaceID]?.phase, .saved)
        }

        func testMergeKeepsAnUnambiguousLocalReorderAndFailsClosedOnConflictingOrders() {
            let a = UUID(), b = UUID(), c = UUID()
            XCTAssertEqual(WorkspaceRecoveryDraftMerge.mergedTabOrder(base: [a, b], draft: [b, a], canonical: [a, b, c]), [b, a, c])
            XCTAssertEqual(WorkspaceRecoveryDraftMerge.mergedTabOrder(base: [a, b], draft: [a, b], canonical: [b, a, c]), [b, a, c])
            XCTAssertNil(WorkspaceRecoveryDraftMerge.mergedTabOrder(base: [a, b, c], draft: [b, a, c], canonical: [a, c, b]))

            let date = Date(timeIntervalSince1970: 1)
            func tab(_ id: UUID, _ name: String) -> ComposeTabState {
                ComposeTabState(id: id, name: name, lastModified: date, promptText: "")
            }
            let id = UUID()
            func model(_ tabs: [ComposeTabState]) -> WorkspaceModel {
                WorkspaceModel(id: id, dateModified: date, name: "W", repoPaths: [], lastUsed: date, composeTabs: tabs, activeComposeTabID: nil)
            }
            let result = WorkspaceRecoveryDraftMerge.merge(
                base: model([tab(a, "A"), tab(b, "B")]),
                draft: model([tab(b, "B"), tab(a, "A")]),
                canonical: model([tab(a, "A"), tab(b, "B"), tab(c, "C")])
            )
            guard case let .merged(merged) = result else { return XCTFail("Expected a merge, got \(result)") }
            XCTAssertEqual(merged.composeTabs.map(\.id), [b, a, c], "The local reorder survives the peer's new tab")
        }

        func testAppEncodedDocumentsSkipTheGuardDecode() throws {
            let model = WorkspaceModel(name: "Encoded \(UUID().uuidString)", repoPaths: ["/r"])
            let document = try DomainWorkspaceAuthorityClient.document(
                for: model,
                fileURL: URL(fileURLWithPath: "/tmp/encoded-\(UUID().uuidString)/workspace.json")
            )
            let before = WorkspaceUnreadableDocumentBackup.lossyDecodeCountForTesting.withLock { $0 }
            XCTAssertFalse(WorkspaceUnreadableDocumentBackup.documentRequiresPreservation(document.documentBytes))
            XCTAssertEqual(WorkspaceUnreadableDocumentBackup.lossyDecodeCountForTesting.withLock { $0 }, before)
        }

        /// End to end with the real app guard and a really corrupted tab (no probe).
        func testRealGuardRefusesDiscardingCorruptedTabUntilBackupSucceeds() async throws {
            let root = FileManager.default.temporaryDirectory
                .resolvingSymlinksInPath()
                .appendingPathComponent("real-guard-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let storage = root.appendingPathComponent("storage", isDirectory: true)
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "real-guard",
                storageDirectory: root.appendingPathComponent("authority", isDirectory: true),
                workspaceStorageDirectory: storage,
                eventDirectory: root.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil,
                durableReplacementGuard: WorkspaceUnreadableDocumentBackup.durableReplacementGuard
            ))
            try await runtime.start()
            addTeardownBlock {
                _ = await runtime.shutdown()
                try? FileManager.default.removeItem(at: root)
            }
            let date = Date(timeIntervalSince1970: 100)
            let model = WorkspaceModel(
                id: UUID(),
                dateModified: date,
                name: "Corrupted",
                repoPaths: [root.path],
                lastUsed: date,
                composeTabs: ["Alpha", "Beta"].map { ComposeTabState(id: UUID(), name: $0, lastModified: date, promptText: $0) },
                activeComposeTabID: nil
            )
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
            var tabs = try XCTUnwrap(object["composeTabs"] as? [[String: Any]])
            tabs[1]["promptText"] = 42
            object["composeTabs"] = tabs
            let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let fileURL = storage.appendingPathComponent("Corrupted-\(model.id.uuidString)/workspace.json")
            let originalDocument = try DomainWorkspaceDocument.decode(documentBytes: original, fileURL: fileURL)
            func run(_ command: DomainWorkspaceCommand) async -> DomainCommandOutcome {
                await runtime.workspaceStore.execute(.init(operationID: UUID(), origin: .appPresentation(windowID: 1), command: command))
            }
            let created = await run(.createWorkspace(originalDocument))
            XCTAssertEqual(created.disposition, .applied)
            let reduced = try JSONEncoder().encode(JSONDecoder().decode(WorkspaceModel.self, from: original))
            let reducedDocument = try DomainWorkspaceDocument.decode(documentBytes: reduced, fileURL: fileURL)
            let replaced = await run(.replaceWorkingDocument(reducedDocument))
            XCTAssertEqual(replaced.disposition, .applied)

            let locator = WorkspaceUnreadableDocumentBackup.backupURL(for: fileURL, documentBytes: original)
            try FileManager.default.createDirectory(at: locator, withIntermediateDirectories: false)
            let refused = await run(.saveWorkspaceDocument(workspaceID: model.id))
            XCTAssertEqual(refused.errorCode, .recoveryBackupRequired)
            XCTAssertEqual(try Data(contentsOf: fileURL), original)

            try FileManager.default.removeItem(at: locator)
            let saved = await run(.saveWorkspaceDocument(workspaceID: model.id))
            XCTAssertEqual(saved.disposition, .applied)
            XCTAssertEqual(try Data(contentsOf: fileURL), reduced)
            XCTAssertEqual(try Data(contentsOf: locator), original)
        }
    }

    @MainActor
    private final class CaptureGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var isHolding = false

        func hold() async {
            guard !released else { return }
            isHolding = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Simulates "this window's saves are blocked": refuses every durable replacement carrying the
    /// draft marker. The real discarded-bytes policy is covered end to end above.
    private final class DraftRefusalProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var refusing = true
        private let savedDocumentOnly: Bool

        init(savedDocumentOnly: Bool = false) {
            self.savedDocumentOnly = savedDocumentOnly
        }

        func setRefusing(_ value: Bool) {
            lock.withLock { refusing = value }
        }

        func protect(_ replacement: DomainDurableReplacement) throws {
            guard lock.withLock({ refusing }),
                  !savedDocumentOnly || replacement.location == .savedDocument,
                  String(decoding: replacement.replacementBytes, as: UTF8.self)
                  .contains(WorkspaceRecoveryBackupBlockTests.draftMarker)
            else { return }
            throw WorkspaceRecoveryBackupBlockedError(reason: "writeFailed(\"temp_open_failed_28\")")
        }
    }

    @MainActor
    private struct BlockedWindowFixture {
        let window: WindowState
        let runtime: MCPDomainRuntime
        let bridge: DomainWorkspacePresentationBridge
        let probe: DraftRefusalProbe
        let workspaceID: UUID
        let fileURL: URL
        let before: WorkspaceModel
        let beforeRevision: UInt64
        let beforeDigest: String

        var manager: WorkspaceManagerViewModel {
            window.workspaceManager
        }

        static func make(testCase: XCTestCase, probe: DraftRefusalProbe) async throws -> Self {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("recovery-blocked-draft-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
            testCase.addTeardownBlock { @MainActor in
                window.beginClose()
                await window.domainWorkspacePresentationBridgeForTesting?.stopAndJoinForTesting()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
                _ = await runtime.shutdown()
                await WorkspaceDiskWriterComposition.processWriter.removeAllForTesting()
                if let previousStoragePath {
                    UserDefaults.standard.set(previousStoragePath, forKey: "GlobalCustomStorageURL")
                } else {
                    UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
                }
                try? FileManager.default.removeItem(at: root)
            }
            let manager = window.workspaceManager
            await manager.awaitInitialized()
            let creation = try manager.createPersistentWorkspace(name: "Recovery Blocked", repoPaths: [root.path])
            let created = try await creation.publishedWorkspace()
            let switched = await manager.switchWorkspace(to: created, saveState: false, reason: "recoveryBackupBlockTest")
            XCTAssertTrue(switched.didSwitch)
            let bridge = try XCTUnwrap(window.domainWorkspacePresentationBridgeForTesting)
            let refreshed = await bridge.refreshForAgentAdmission()
            XCTAssertTrue(refreshed)
            // A peer journals a benign working edit, so the window's draft commit discards durable
            // working bytes and the probe can refuse it (a clean journal discards nothing).
            let cleanValue = await runtime.workspaceStore.canonicalWorkspaceSnapshot(created.id)
            let clean = try XCTUnwrap(cleanValue)
            var benign = try JSONDecoder().decode(WorkspaceModel.self, from: clean.document.documentBytes)
            benign.composeTabs[0].name = "benign working edit"
            let benignOutcome = try await DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -990)
                .replaceWorkingFailClosed(benign, fileURL: clean.document.fileURL, expectedWorkspaceRevision: clean.revisions.workingRevision)
            XCTAssertEqual(benignOutcome.disposition, .applied)
            let benignRefresh = await bridge.refreshForAgentAdmission()
            XCTAssertTrue(benignRefresh)
            XCTAssertEqual(manager.workspace(withID: created.id)?.composeTabs.first?.name, "benign working edit")
            let snapshotValue = await runtime.workspaceStore.canonicalWorkspaceSnapshot(created.id)
            let snapshot = try XCTUnwrap(snapshotValue)
            return try Self(
                window: window,
                runtime: runtime,
                bridge: bridge,
                probe: probe,
                workspaceID: created.id,
                fileURL: snapshot.document.fileURL,
                before: JSONDecoder().decode(WorkspaceModel.self, from: snapshot.document.documentBytes),
                beforeRevision: snapshot.revisions.workingRevision,
                beforeDigest: snapshot.document.contentDigest
            )
        }

        /// Renames the first tab (a field no view model mirrors back) and saves; the probe
        /// refuses it, so nothing durable changes.
        func blockDraft(promptText: String, waitForBase: Bool = true) async throws {
            var draft = try XCTUnwrap(manager.workspace(withID: workspaceID))
            draft.composeTabs[0].name = promptText
            let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceID })
            manager.workspaces[index] = draft
            let canonicalBefore = try Data(contentsOf: fileURL)
            do {
                _ = try await manager.saveWorkspaceToFileAsync(draft, source: "recoveryBackupBlockTest")
                XCTFail("The save must be refused while the recovery backup cannot be made")
            } catch {}
            XCTAssertNotNil(manager.recoveryBackupBlocks[workspaceID])
            XCTAssertEqual(try Data(contentsOf: fileURL), canonicalBefore)
            guard waitForBase else { return }
            let deadline = Date().addingTimeInterval(10)
            while manager.recoveryBackupBlocks[workspaceID]?.base == nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertNotNil(manager.recoveryBackupBlocks[workspaceID]?.base, "The draft's base is captured")
        }

        /// Another writer edits the authority's current contents and saves them.
        @discardableResult
        func publishPeer(_ mutate: (inout WorkspaceModel) -> Void) async throws -> DomainWorkspaceDocument {
            let currentValue = await runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
            let current = try XCTUnwrap(currentValue)
            var peer = try JSONDecoder().decode(WorkspaceModel.self, from: current.document.documentBytes)
            mutate(&peer)
            let peerDocument = try DomainWorkspaceAuthorityClient.document(for: peer, fileURL: fileURL)
            let peerClient = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -991)
            let peerSave = try await peerClient.saveFailClosed(
                peerDocument,
                expectedWorkspaceRevision: current.revisions.workingRevision,
                expectedContentDigest: current.document.contentDigest
            )
            XCTAssertEqual(peerSave.saved?.disposition, .applied)
            let refreshed = await bridge.refreshForAgentAdmission()
            XCTAssertTrue(refreshed)
            return peerDocument
        }

        func savedModel() throws -> WorkspaceModel {
            try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: fileURL))
        }
    }

    /// App-side policy edges from the #1619 review.
    final class WorkspaceRecoveryBackupPolicyTests: XCTestCase {
        private var root: URL!

        override func setUp() async throws {
            WorkspaceFileDecodeCache.shared.removeAllForTesting()
            root = FileManager.default.temporaryDirectory
                .resolvingSymlinksInPath()
                .appendingPathComponent("recovery-policy-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        override func tearDown() async throws {
            try? FileManager.default.removeItem(at: root)
        }

        func testWorkspaceIndexIsNotRoutedThroughThePreservationPolicy() throws {
            let indexURL = root.appendingPathComponent("workspacesIndex.json")
            try Data("[not a workspace]".utf8).write(to: indexURL)
            try WorkspaceUnreadableDocumentBackup.replaceDocument(Data("[]".utf8), at: indexURL)
            XCTAssertEqual(try Data(contentsOf: indexURL), Data("[]".utf8))
            XCTAssertTrue(try backups().isEmpty)
        }

        func testUnreadableOriginalIsNeverRenamedOver() throws {
            let fileURL = root.appendingPathComponent("workspace.json")
            let original = try corruptedDocument()
            try original.write(to: fileURL)
            XCTAssertEqual(chmod(fileURL.path, 0), 0)
            defer { chmod(fileURL.path, 0o600) }
            XCTAssertThrowsError(try WorkspaceUnreadableDocumentBackup.replaceDocument(Data("{}".utf8), at: fileURL)) {
                XCTAssertEqual(WorkspaceRecoveryBackupReason(raw: ($0 as? WorkspaceRecoveryBackupBlockedError)?.reason ?? "").kind, .unreadableOriginal)
            }
            XCTAssertEqual(chmod(fileURL.path, 0o600), 0)
            XCTAssertEqual(try Data(contentsOf: fileURL), original)
        }

        func testSameIDStashedCopyDoesNotHideAnUnreadableComposedTab() throws {
            let tabID = UUID()
            let date = Date(timeIntervalSince1970: 100)
            let olderValid = ComposeTabState(id: tabID, name: "Alpha", lastModified: date, promptText: "old")
            var model = WorkspaceModel(
                id: UUID(), dateModified: date, name: "Stash", repoPaths: ["/r"], lastUsed: date,
                composeTabs: [olderValid, ComposeTabState(id: UUID(), name: "Beta", lastModified: date, promptText: "b")],
                activeComposeTabID: nil
            )
            model.stashedTabs = [StashedTab(tab: olderValid, stashedAt: date)]
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
            var tabs = try XCTUnwrap(object["composeTabs"] as? [[String: Any]])
            tabs[0]["promptText"] = 42
            object["composeTabs"] = tabs
            let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let reduced = try JSONEncoder().encode(JSONDecoder().decode(WorkspaceModel.self, from: original))
            let fileURL = root.appendingPathComponent("workspace.json")
            try original.write(to: fileURL)
            let locator = WorkspaceUnreadableDocumentBackup.backupURL(for: fileURL, documentBytes: original)
            try FileManager.default.createDirectory(at: locator, withIntermediateDirectories: false)

            XCTAssertThrowsError(try WorkspaceUnreadableDocumentBackup.replaceDocument(reduced, at: fileURL))
            XCTAssertEqual(try Data(contentsOf: fileURL), original)
        }

        func testUnreadableStashCountsAsALossyDecode() throws {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
                WorkspaceModel(name: "Stash", repoPaths: ["/r"])
            )) as? [String: Any])
            object["stashedTabs"] = "not-an-array"
            let bytes = try JSONSerialization.data(withJSONObject: object)
            XCTAssertTrue(try JSONDecoder().decode(WorkspaceModel.self, from: bytes).composeTabsDecodeWasLossy)
            XCTAssertTrue(WorkspaceUnreadableDocumentBackup.documentRequiresPreservation(bytes))
        }

        func testBannerReasonsAreReadableAndGuidanceMatchesTheCause() {
            let diskFull = WorkspaceRecoveryBackupReason(raw: #"recoveryBackupRequired(location: "saved_document", reason: "writeFailed(\"temp_open_failed_28\")")"#)
            XCTAssertEqual(diskFull.kind, .diskFull)
            XCTAssertTrue(diskFull.guidance.contains("disk space"))
            let conflict = WorkspaceRecoveryBackupReason(raw: "conflictingEntry(\"workspace.unreadable-x.json\")")
            XCTAssertEqual(conflict.kind, .conflictingEntry)
            XCTAssertFalse(conflict.guidance.contains("disk space"))
            let block = WorkspaceRecoveryBackupBlock(
                workspaceID: UUID(), reason: #"writeFailed("temp_open_failed_13")"#, phase: .saved,
                draft: WorkspaceModel(name: "W", repoPaths: []), draftStateVersion: 0, baseDigest: nil
            )
            let message = WorkspaceRecoveryBackupBlockBanner.message(for: block)
            XCTAssertTrue(message.contains("permission"))
            XCTAssertFalse(message.contains("writeFailed"), "Raw diagnostics are not shown")
            XCTAssertTrue(message.contains("kept only in this window"))
        }

        @MainActor
        func testLegacySaveReportsNonRecoveryWriteFailures() async throws {
            let window = WindowState()
            addTeardownBlock { @MainActor in
                window.beginClose()
                await window.tearDown()
            }
            let manager = window.workspaceManager
            await manager.awaitInitialized()
            let workspace = WorkspaceModel(name: "Legacy Save", repoPaths: [root.path])
            let fileURL = try await manager.saveWorkspaceToFileAsync(workspace, baseRoot: root, metadata: nil)
            let directory = fileURL.deletingLastPathComponent()
            XCTAssertEqual(chmod(directory.path, 0o555), 0)
            defer { chmod(directory.path, 0o755) }
            do {
                _ = try await manager.saveWorkspaceToFileAsync(workspace, baseRoot: root, metadata: nil)
                XCTFail("A failed write must not be reported as a successful save")
            } catch {}
        }

        private func corruptedDocument() throws -> Data {
            let date = Date(timeIntervalSince1970: 100)
            let model = WorkspaceModel(
                id: UUID(), dateModified: date, name: "C", repoPaths: ["/r"], lastUsed: date,
                composeTabs: [ComposeTabState(id: UUID(), name: "A", lastModified: date, promptText: "a")],
                activeComposeTabID: nil
            )
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
            var tabs = try XCTUnwrap(object["composeTabs"] as? [[String: Any]])
            tabs[0]["promptText"] = 42
            object["composeTabs"] = tabs
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        private func backups() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(WorkspaceUnreadableDocumentBackup.fileNamePrefix) }
        }
    }
#endif
