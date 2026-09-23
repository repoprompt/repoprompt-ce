import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceProjectionDecodeTests: XCTestCase {
        typealias Diagnostics = WorkspaceProjectionDecodeDiagnostics

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
            XCTAssertThrowsError(try Diagnostics.$context.withValue(context) {
                try fixture.decode(Data("{PRIVATE_PAYLOAD_AND_PATH".utf8))
            })
            XCTAssertNil(Diagnostics.context, "Throwing must restore the task-local scope")
            try Diagnostics.$context.withValue(context) {
                for _ in 0 ..< Diagnostics.Recorder.maximumSamples + 1 {
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
            let decoded = try Diagnostics.$context.withValue(.init(
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
#endif
