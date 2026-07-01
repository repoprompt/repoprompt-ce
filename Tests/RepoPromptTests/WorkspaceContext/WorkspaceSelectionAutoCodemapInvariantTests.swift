@testable import RepoPrompt
import XCTest

final class WorkspaceSelectionAutoCodemapInvariantTests: XCTestCase {
    func testFullAndSliceMutationsPersistOnlyExplicitSelectionState() async throws {
        let root = try makeRoot(named: #function)
        defer { try? FileManager.default.removeItem(at: root) }

        let selectedA = root.appendingPathComponent("A.swift")
        let selectedB = root.appendingPathComponent("B.swift")
        let manual = root.appendingPathComponent("Manual.swift")
        try write("struct A {}", to: selectedA)
        try write("struct B {}", to: selectedB)
        try write("struct Manual {}", to: manual)

        let store = WorkspaceFileContextStore()
        let loaded = try await store.loadRoot(path: root.path)
        let service = WorkspaceSelectionMutationService(store: store)
        let initial = StoredSelection(
            selectedPaths: [selectedA.path],
            manualCodemapPaths: [manual.path],
            codemapAutoEnabled: false
        )

        let added = await service.addPaths(
            existing: initial,
            paths: [selectedB.path],
            rawPaths: [selectedB.path],
            mode: "full"
        )
        XCTAssertEqual(added.selection.selectedPaths, [selectedA.path, selectedB.path])
        XCTAssertEqual(added.selection.manualCodemapPaths, [manual.path])
        XCTAssertFalse(added.selection.codemapAutoEnabled)

        let sliced = await service.mutateSlices(
            base: added.selection,
            entries: [
                WorkspaceSelectionSliceInput(
                    path: selectedA.path,
                    ranges: [LineRange(start: 1, end: 1)]
                )
            ],
            mode: .add
        )
        XCTAssertEqual(
            sliced.selection.slices[selectedA.path],
            [LineRange(start: 1, end: 1)]
        )
        XCTAssertEqual(sliced.selection.manualCodemapPaths, [manual.path])
        await store.unloadRoot(id: loaded.id)
    }

    func testManualCodemapOnlyMutationsPersistAcrossAddPromoteDemoteAndRemove() async throws {
        let root = try makeRoot(named: #function)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Selected.swift")
        try write("struct Selected {}", to: file)

        let store = WorkspaceFileContextStore()
        let loaded = try await store.loadRoot(path: root.path)
        let service = WorkspaceSelectionMutationService(store: store)
        let initial = StoredSelection(selectedPaths: [file.path], codemapAutoEnabled: true)

        let built = await service.buildSelection(
            paths: [file.path],
            mode: "codemap_only",
            existing: initial
        )
        XCTAssertEqual(built.selection.selectedPaths, [])
        XCTAssertEqual(built.selection.manualCodemapPaths, [file.path])
        XCTAssertFalse(built.selection.codemapAutoEnabled)
        XCTAssertTrue(built.invalidPaths.isEmpty)

        let added = await service.addPaths(
            existing: initial,
            paths: [file.path],
            rawPaths: [file.path],
            mode: "codemap_only"
        )
        XCTAssertEqual(added.selection.manualCodemapPaths, [file.path])
        XCTAssertEqual(added.selection.selectedPaths, [])
        XCTAssertFalse(added.selection.codemapAutoEnabled)
        XCTAssertTrue(added.mutated)

        let promoted = await service.promotePaths(
            existing: added.selection,
            paths: [file.path],
            rawPaths: [file.path]
        )
        XCTAssertEqual(promoted.selection.selectedPaths, [file.path])
        XCTAssertTrue(promoted.selection.manualCodemapPaths.isEmpty)

        let demoted = await service.demotePaths(
            existing: promoted.selection,
            paths: [file.path],
            rawPaths: [file.path]
        )
        XCTAssertTrue(demoted.selection.selectedPaths.isEmpty)
        XCTAssertEqual(demoted.selection.manualCodemapPaths, [file.path])
        XCTAssertFalse(demoted.selection.codemapAutoEnabled)

        let removed = await service.removePaths(
            existing: demoted.selection,
            paths: [file.path],
            rawPaths: [file.path],
            mode: "codemap_only"
        )
        XCTAssertTrue(removed.selection.manualCodemapPaths.isEmpty)
        XCTAssertTrue(removed.mutated)
    }

    func testStoredSelectionPersistsManualPathsButDiscardsLegacyInferredPathKey() throws {
        let legacyJSON = try XCTUnwrap(
            """
            {
              "selectedPaths": ["/workspace/Source.swift"],
              "manualCodemapPaths": ["/workspace/Manual.swift"],
              "autoCodemapPaths": ["/workspace/Legacy.swift"],
              "slices": {},
              "codemapAutoEnabled": false
            }
            """.data(using: .utf8)
        )

        let decoded = try JSONDecoder().decode(StoredSelection.self, from: legacyJSON)
        XCTAssertEqual(decoded.selectedPaths, ["/workspace/Source.swift"])
        XCTAssertEqual(decoded.manualCodemapPaths, ["/workspace/Manual.swift"])
        XCTAssertFalse(decoded.codemapAutoEnabled)

        let encoded = try JSONEncoder().encode(decoded)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let encodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertFalse(encodedText.contains("autoCodemapPaths"))
        XCTAssertFalse(encodedText.contains("/workspace/Legacy.swift"))
        XCTAssertEqual(
            encodedObject["manualCodemapPaths"] as? [String],
            ["/workspace/Manual.swift"]
        )
    }

    func testSelectionProductionPathContainsNoLegacyRelationshipCalls() throws {
        let repoRoot = try RepoRoot.url()
        let sourceDirectories = [
            "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection",
            "Sources/RepoPrompt/Features/WorkspaceFiles"
        ]
        let forbiddenCalls = [
            "codemapFileAPIAggregate(",
            "CodeMapExtractor.resolveReferencedFilePaths(",
            "CodeMapExtractor.getAutoReferencedAPIs("
        ]
        var violations: [String] = []

        for directory in sourceDirectories {
            let directoryURL = repoRoot.appendingPathComponent(directory, isDirectory: true)
            let enumerator = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: directoryURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            )
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let contents = try String(contentsOf: fileURL, encoding: .utf8)
                for call in forbiddenCalls where contents.contains(call) {
                    violations.append("\(RepoRoot.relativePath(for: fileURL, relativeTo: repoRoot)): \(call)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Selection production paths must not call legacy codemap relationship APIs:\n\(violations.joined(separator: "\n"))"
        )
    }

    private func makeRoot(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSelectionAutoCodemapInvariantTests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
