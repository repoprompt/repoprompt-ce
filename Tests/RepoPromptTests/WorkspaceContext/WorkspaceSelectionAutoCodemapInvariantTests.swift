@testable import RepoPrompt
import XCTest

final class WorkspaceSelectionAutoCodemapInvariantTests: XCTestCase {
    func testAutoCodemapInvariantAcrossSelectionMutations() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSelectionAutoCodemapInvariantTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let selectedA = root.appendingPathComponent("A.swift")
        let selectedB = root.appendingPathComponent("B.swift")
        let target = root.appendingPathComponent("Target.swift")
        try write("struct A {}", to: selectedA)
        try write("struct B {}", to: selectedB)
        try write("struct TargetType {}", to: target)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: selectedA.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(path: selectedA.path, symbolName: "aSymbol", referencedTypes: ["TargetType"])
            ),
            WorkspaceObservedCodemapResult(
                fullPath: selectedB.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(path: selectedB.path, symbolName: "bSymbol", referencedTypes: ["TargetType"])
            ),
            WorkspaceObservedCodemapResult(
                fullPath: target.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(path: target.path, symbolName: "targetSymbol", className: "TargetType")
            )
        ])

        let service = WorkspaceSelectionMutationService(store: store)

        let fullSelection = await service.addPaths(
            existing: StoredSelection(),
            paths: [selectedA.path],
            rawPaths: [selectedA.path],
            mode: "full"
        ).selection
        XCTAssertEqual(fullSelection.selectedPaths, [selectedA.path])
        XCTAssertEqual(fullSelection.autoCodemapPaths, [target.path])
        XCTAssertTrue(fullSelection.codemapAutoEnabled)

        let slicedSelection = await service.mutateSlices(
            base: StoredSelection(),
            entries: [
                WorkspaceSelectionSliceInput(
                    path: selectedA.path,
                    ranges: [LineRange(start: 1, end: 1)]
                )
            ],
            mode: .add
        ).selection
        XCTAssertEqual(slicedSelection.selectedPaths, [selectedA.path])
        XCTAssertEqual(slicedSelection.autoCodemapPaths, [target.path])
        XCTAssertEqual(slicedSelection.slices[selectedA.path], [LineRange(start: 1, end: 1)])
        XCTAssertTrue(slicedSelection.codemapAutoEnabled)

        let manualSelection = await service.removePaths(
            existing: fullSelection,
            paths: [target.path],
            rawPaths: [target.path],
            mode: "codemap_only"
        ).selection
        XCTAssertTrue(manualSelection.autoCodemapPaths.isEmpty)
        XCTAssertFalse(manualSelection.codemapAutoEnabled)

        let manualAfterAdd = await service.addPaths(
            existing: manualSelection,
            paths: [selectedB.path],
            rawPaths: [selectedB.path],
            mode: "full"
        ).selection
        XCTAssertEqual(manualAfterAdd.selectedPaths, [selectedA.path, selectedB.path])
        XCTAssertTrue(manualAfterAdd.autoCodemapPaths.isEmpty)
        XCTAssertFalse(manualAfterAdd.codemapAutoEnabled)

        let destructiveReplacement = await service.buildManageSelectionSet(
            paths: [selectedB.path],
            mode: "full",
            existing: manualAfterAdd
        ).selection
        XCTAssertEqual(destructiveReplacement.selectedPaths, [selectedB.path])
        XCTAssertTrue(destructiveReplacement.autoCodemapPaths.isEmpty)
        XCTAssertFalse(destructiveReplacement.codemapAutoEnabled)

        let ordinaryRemoval = await service.removePaths(
            existing: fullSelection,
            paths: [selectedA.path],
            rawPaths: [selectedA.path]
        ).selection
        XCTAssertTrue(ordinaryRemoval.selectedPaths.isEmpty)
        XCTAssertTrue(ordinaryRemoval.autoCodemapPaths.isEmpty)
        XCTAssertTrue(ordinaryRemoval.codemapAutoEnabled)
    }

    func testRecomputeHonorsSessionBoundScopeAndExcludesSelectedDependencies() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSelectionAutoCodemapScopeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let worktreeA = base.appendingPathComponent("WorktreeA", isDirectory: true)
        let worktreeB = base.appendingPathComponent("WorktreeB", isDirectory: true)
        let selected = worktreeA.appendingPathComponent("Selected.swift")
        let selectedDependency = worktreeA.appendingPathComponent("SelectedDependency.swift")
        let foreignDependency = worktreeB.appendingPathComponent("ForeignDependency.swift")
        try write("struct Selected {}", to: selected)
        try write("struct SelectedDependencyType {}", to: selectedDependency)
        try write("struct ForeignDependencyType {}", to: foreignDependency)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: worktreeA.path, kind: .sessionWorktree)
        _ = try await store.loadRoot(path: worktreeB.path, kind: .sessionWorktree)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: selected.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(
                    path: selected.path,
                    symbolName: "selectedSymbol",
                    referencedTypes: [
                        "SelectedDependencyType",
                        "SelectedDependencyAlias",
                        "ForeignDependencyType"
                    ]
                )
            ),
            WorkspaceObservedCodemapResult(
                fullPath: selectedDependency.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(
                    path: selectedDependency.path,
                    symbolName: "selectedDependencySymbol",
                    className: "SelectedDependencyType",
                    additionalClassNames: ["SelectedDependencyAlias"]
                )
            ),
            WorkspaceObservedCodemapResult(
                fullPath: foreignDependency.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(
                    path: foreignDependency.path,
                    symbolName: "foreignDependencySymbol",
                    className: "ForeignDependencyType"
                )
            )
        ])

        let service = WorkspaceSelectionMutationService(store: store)
        let scopeA = WorkspaceLookupRootScope.sessionBoundWorkspace(
            canonicalRootPaths: [],
            physicalRootPaths: [worktreeA.path]
        )
        let selectedOnly = await service.recomputeAutoCodemaps(
            StoredSelection(selectedPaths: [selected.path]),
            rootScope: scopeA
        )
        XCTAssertEqual(selectedOnly.autoCodemapPaths, [selectedDependency.path])
        XCTAssertEqual(Set(selectedOnly.autoCodemapPaths).count, selectedOnly.autoCodemapPaths.count)

        let dependencyAlreadySelected = await service.recomputeAutoCodemaps(
            StoredSelection(selectedPaths: [selected.path, selectedDependency.path]),
            rootScope: scopeA
        )
        XCTAssertTrue(dependencyAlreadySelected.autoCodemapPaths.isEmpty)
    }

    func testNoOpAddAndRemoveReportMutationOnlyWhenAutoCodemapsRefresh() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSelectionAutoCodemapRefreshTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let selected = root.appendingPathComponent("Selected.swift")
        let target = root.appendingPathComponent("Target.swift")
        let unrelated = root.appendingPathComponent("Unrelated.swift")
        try write("struct Selected {}", to: selected)
        try write("struct TargetType {}", to: target)
        try write("struct Unrelated {}", to: unrelated)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: selected.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(
                    path: selected.path,
                    symbolName: "selectedSymbol",
                    referencedTypes: ["TargetType"]
                )
            ),
            WorkspaceObservedCodemapResult(
                fullPath: target.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(path: target.path, symbolName: "targetSymbol", className: "TargetType")
            )
        ])

        let service = WorkspaceSelectionMutationService(store: store)
        let stale = StoredSelection(selectedPaths: [selected.path])

        let refreshedByAdd = await service.addPaths(
            existing: stale,
            paths: [selected.path],
            rawPaths: [selected.path],
            mode: "full"
        )
        XCTAssertTrue(refreshedByAdd.mutated)
        XCTAssertEqual(refreshedByAdd.selection.autoCodemapPaths, [target.path])

        let refreshedByRemove = await service.removePaths(
            existing: stale,
            paths: [unrelated.path],
            rawPaths: [unrelated.path]
        )
        XCTAssertTrue(refreshedByRemove.mutated)
        XCTAssertEqual(refreshedByRemove.selection.autoCodemapPaths, [target.path])

        let alreadyFreshAdd = await service.addPaths(
            existing: refreshedByAdd.selection,
            paths: [selected.path],
            rawPaths: [selected.path],
            mode: "full"
        )
        XCTAssertFalse(alreadyFreshAdd.mutated)

        let alreadyFreshRemove = await service.removePaths(
            existing: refreshedByRemove.selection,
            paths: [unrelated.path],
            rawPaths: [unrelated.path]
        )
        XCTAssertFalse(alreadyFreshRemove.mutated)
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeFileAPI(
        path: String,
        symbolName: String,
        className: String? = nil,
        additionalClassNames: [String] = [],
        referencedTypes: [String] = []
    ) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: [],
            classes: ([className].compactMap(\.self) + additionalClassNames)
                .map { ClassInfo(name: $0, methods: [], properties: []) },
            functions: [
                FunctionInfo(
                    name: symbolName,
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func \(symbolName)()",
                    lineNumber: 1
                )
            ],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: referencedTypes
        )
    }
}
