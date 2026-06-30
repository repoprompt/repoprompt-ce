import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceRootSeedPlannerTests: XCTestCase {
    private typealias FixtureSupport = WorkspaceRootTargetSeedPlanTestSupport
    private typealias SeedSupport = WorkspaceRootSeedTestSupport
    private var roots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        roots.removeAll()
        try super.tearDownWithError()
    }

    func testStreamingReconciliationPreservesEmptyDirectoriesAndAllPlanDispositions() async throws {
        let root = try roots.makeRoot(suiteName: "WorkspaceRootSeedPlanner-exact-root")
        let storeRoot = try roots.makeRoot(suiteName: "WorkspaceRootSeedPlanner-exact-store")
        let snapshot = try await SeedSupport.snapshot(
            paths: [
                ("Deleted.swift", "100644"),
                ("Ignored/Tracked.swift", "100644"),
                ("Keep.swift", "100644")
            ],
            policyIgnoredPaths: ["Ignored/Tracked.swift"]
        )
        let deleted = snapshot.inventory.entries[0]
        let ignored = snapshot.inventory.entries[1]
        let keep = snapshot.inventory.entries[2]
        XCTAssertTrue(deleted.isSearchableFile)

        let fixture = try await FixtureSupport.makeFixture(
            root: root,
            storeRoot: storeRoot,
            snapshot: snapshot,
            namespaceRecords: [
                .init(relativePath: "Empty", kind: .directory, isSymbolicLink: false, fileSystemMode: 0o040755),
                .init(relativePath: "Empty/Deep", kind: .directory, isSymbolicLink: false, fileSystemMode: 0o040755),
                .init(relativePath: "Empty/Deep/Leaf", kind: .directory, isSymbolicLink: false, fileSystemMode: 0o040755),
                .init(relativePath: "Keep.swift", kind: .file, isSymbolicLink: false, fileSystemMode: 0o100644),
                .init(relativePath: "New.swift", kind: .file, isSymbolicLink: false, fileSystemMode: 0o100644)
            ],
            indexRecords: [
                FixtureSupport.indexRecord(path: ignored.relativePath, objectID: ignored.objectID),
                FixtureSupport.indexRecord(path: keep.relativePath, objectID: keep.objectID)
            ],
            statusRecords: [FixtureSupport.statusRecord(kind: .untracked, path: "New.swift")]
        )
        let records = try FixtureSupport.readAll(fixture.handle)
        let byPath = Dictionary(uniqueKeysWithValues: records.map {
            (String(decoding: $0.relativePathBytes, as: UTF8.self), $0)
        })

        XCTAssertEqual(byPath["Deleted.swift"]?.disposition, .baseTombstone)
        XCTAssertEqual(byPath["Deleted.swift"]?.baseAction, .tombstone)
        XCTAssertEqual(byPath["Ignored/Tracked.swift"]?.disposition, .policyIgnoredTrackedFile)
        XCTAssertEqual(byPath["Keep.swift"]?.disposition, .ordinaryFile)
        XCTAssertEqual(byPath["Keep.swift"]?.baseAction, .reuse)
        XCTAssertEqual(byPath["New.swift"]?.disposition, .ordinaryFile)
        XCTAssertEqual(byPath["New.swift"]?.baseAction, .overlay)
        XCTAssertNil(byPath["New.swift"]?.targetObjectIDBytes)
        for path in ["Empty", "Empty/Deep", "Empty/Deep/Leaf"] {
            XCTAssertEqual(byPath[path]?.disposition, .ordinaryDirectory)
        }
        XCTAssertEqual(fixture.plan.footer.ordinaryDirectoryCount, 3)
        XCTAssertEqual(fixture.plan.footer.reusedBaseFileCount, 1)
        XCTAssertEqual(fixture.plan.footer.overlayFileCount, 1)
        XCTAssertEqual(fixture.plan.footer.baseTombstoneCount, 1)
    }

    func testStreamingReconciliationPreservesByteDistinctUnicodePaths() async throws {
        let composed = "Caf\u{00E9}.swift"
        let decomposed = "Cafe\u{0301}.swift"
        let paths = [decomposed, composed].sorted {
            Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8))
        }
        do {
            _ = try await SeedSupport.snapshot(paths: paths.map { ($0, "100644") })
            XCTFail("Expected canonical-equivalent inventory paths to fail closed")
        } catch let error as WorkspaceRootReusableInventoryManifestError {
            XCTAssertEqual(error, .canonicalPathCollision)
        }
    }

    func testStreamingReconciliationFailsClosedForSparseAndAssumeUnchangedIndex() async throws {
        let root = try roots.makeRoot(suiteName: "WorkspaceRootSeedPlanner-flags-root")
        let storeRoot = try roots.makeRoot(suiteName: "WorkspaceRootSeedPlanner-flags-store")
        let snapshot = try await SeedSupport.snapshot(paths: [("A.swift", "100644")])
        let entry = snapshot.inventory.entries[0]
        let namespace = [WorkspaceRootNamespaceRecord(
            relativePath: "A.swift",
            kind: .file,
            isSymbolicLink: false,
            fileSystemMode: 0o100644
        )]

        do {
            _ = try await FixtureSupport.makeFixture(
                root: root,
                storeRoot: storeRoot,
                snapshot: snapshot,
                namespaceRecords: namespace,
                indexRecords: [FixtureSupport.indexRecord(path: "A.swift", objectID: entry.objectID)],
                sparseCheckoutEnabled: true
            )
            XCTFail("Expected sparse checkout to fail closed")
        } catch {}

        do {
            _ = try await FixtureSupport.makeFixture(
                root: root,
                storeRoot: storeRoot,
                snapshot: snapshot,
                namespaceRecords: namespace,
                indexRecords: [FixtureSupport.indexRecord(
                    path: "A.swift",
                    objectID: entry.objectID,
                    assumeUnchanged: true
                )]
            )
            XCTFail("Expected assume-unchanged to fail closed")
        } catch {}
    }

    func testStreamingReconciliationFailsClosedForSymlinkAndNestedRepositoryMarkers() async throws {
        let root = try roots.makeRoot(suiteName: "WorkspaceRootSeedPlanner-topology-root")
        let storeRoot = try roots.makeRoot(suiteName: "WorkspaceRootSeedPlanner-topology-store")
        let emptySnapshot = try await SeedSupport.snapshot(paths: [])

        do {
            _ = try await FixtureSupport.makeFixture(
                root: root,
                storeRoot: storeRoot,
                snapshot: emptySnapshot,
                namespaceRecords: [WorkspaceRootNamespaceRecord(
                    relativePath: "Link",
                    kind: .file,
                    isSymbolicLink: true,
                    fileSystemMode: 0o120777
                )],
                indexRecords: []
            )
            XCTFail("Expected symlink topology to fail closed")
        } catch {}

        do {
            _ = try await FixtureSupport.makeFixture(
                root: root,
                storeRoot: storeRoot,
                snapshot: emptySnapshot,
                namespaceRecords: [],
                indexRecords: [],
                statusRecords: [FixtureSupport.statusRecord(
                    kind: .untracked,
                    path: "Nested",
                    isDirectoryMarker: true
                )]
            )
            XCTFail("Expected nested repository marker to fail closed")
        } catch {}
    }
}
