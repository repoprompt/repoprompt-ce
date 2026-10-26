import Foundation
@testable import RepoPromptApp
import RepoPromptFileSystem
import XCTest

final class HiddenSessionSlicePathIndexTests: XCTestCase {
    func testIndexedMatchesPreserveLegacyPathPredicate() {
        let paths = [
            "file.swift", "Sources/file.swift", "file.swift", "Other/file.swift",
            "a//b", "/leading", "", "é.swift", "日本語/名前.swift",
            "nested/trailing/", ".hidden", "./file.swift", "\u{301}name.swift"
        ]
        let files = Dictionary(uniqueKeysWithValues: paths.enumerated().map { (fileID($0.offset), $0.element) })
        let index = HiddenSessionSlicePathIndex(relativePathsByFileID: files)
        let slices = [
            "file.swift", "Sources/file.swift", "/workspace/Sources/file.swift",
            "root@token//Sources/file.swift", "prefixfile.swift", "Sources/file.swift.backup",
            "other/File.swift", "a//b", "root/a//b", "root/a/b",
            "/leading", "root//leading", "root/leading", "", "root/",
            "e\u{301}.swift", "root/日本語/名前.swift", "root/nested/trailing/",
            "root/.hidden", "root/./file.swift", "root/\u{301}name.swift", "missing.swift"
        ]

        for slice in slices {
            let expected = Set(files.compactMap { fileID, relativePath in
                slice == relativePath || slice.hasSuffix("/" + relativePath) ? fileID : nil
            })
            XCTAssertEqual(index.matchingFileIDs(for: [slice]), expected, "Slice: \(slice)")
        }
        XCTAssertTrue(index.matchingFileIDs(for: []).isEmpty)
    }

    func testLargeIndexPreservesDuplicateRelativePathsAcrossRoots() {
        let count = 2048
        var files: [UUID: String] = [:]
        for value in 0 ..< count {
            let path = "Sources/Feature\(value)/File.swift"
            files[fileID(value * 2)] = path
            files[fileID(value * 2 + 1)] = path
        }
        let index = HiddenSessionSlicePathIndex(relativePathsByFileID: files)
        let slices = (0 ..< count).map { "root@token//Sources/Feature\($0)/File.swift" }

        XCTAssertEqual(index.matchingFileIDs(for: slices), Set(files.keys))
        XCTAssertEqual(index.matchingFileIDs(for: [slices[0], slices[0]]), [fileID(0), fileID(1)])
        XCTAssertTrue(index.matchingFileIDs(for: ["root@token//Sources/Feature0/Other.swift"]).isEmpty)
    }

    private func fileID(_ value: Int) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(value >> 8), UInt8(value & 255)))
    }
}

@MainActor
final class HiddenSessionAppliedIndexHotPathTests: XCTestCase {
    func testIrrelevantEventsDoNotEnumerateRootRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = WorkspaceFileContextStore(codemapGraphIndexBuildLaunchPolicyForTesting: .disabled)
        let ordinary = try await store.loadRoot(path: directory.path)
        let hiddenDirectory = directory.appendingPathComponent("hidden")
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        let hidden = try await store.loadRoot(path: hiddenDirectory.path, kind: .sessionWorktree)
        addTeardownBlock {
            await store.unloadRoot(id: hidden.id)
            await store.unloadRoot(id: ordinary.id)
            try? FileManager.default.removeItem(at: directory)
        }
        let viewModel = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let hiddenLifetime = try await store.rootLifetimeIDForTesting(rootID: hidden.id)
        let ordinaryLifetime = try await store.rootLifetimeIDForTesting(rootID: ordinary.id)
        await store.resetFilesInRootRequestCountForTesting()
        await store.resetAppliedIndexRecordLookupDiagnosticsForTesting()

        for event in [
            WorkspaceAppliedIndexBatchEvent(rootID: ordinary.id, rootPath: ordinary.fullPath, generation: 1, rootLifetimeID: ordinaryLifetime),
            WorkspaceAppliedIndexBatchEvent(rootID: hidden.id, rootPath: directory.path, generation: 1, rootLifetimeID: hiddenLifetime),
            WorkspaceAppliedIndexBatchEvent(rootID: hidden.id, rootPath: hidden.fullPath, generation: 1, rootLifetimeID: hiddenLifetime),
            WorkspaceAppliedIndexBatchEvent(rootID: hidden.id, rootPath: hidden.fullPath, generation: 1, rootLifetimeID: hiddenLifetime)
        ] {
            await viewModel.applyWorkspaceAppliedIndexEventForTesting(event)
        }

        let enumerations = await store.fileEnumerationRequestCountForTesting()
        let lookups = await store.appliedIndexRecordLookupDiagnosticsForTesting()
        XCTAssertEqual(enumerations, 0)
        XCTAssertEqual(lookups.rootSnapshots, 0)
        // The empty first hidden event must advance handled generation: its replay
        // should be rejected before even a targeted lookup.
        XCTAssertEqual(lookups.lookupRequests, 1)
        XCTAssertEqual(lookups.requestedRecords, 0)
    }
}
