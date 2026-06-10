import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class MCPCodeStructureWorktreeTests: XCTestCase {
    func testStoreCanScanSessionWorktreeRoot() async throws {
        let worktreeRootURL = try makeTemporaryRoot(name: "DirectScanWorktree")
        try write(
            "struct DirectSessionWorktreeType {\n    func directMethod() {}\n}\n",
            to: worktreeRootURL.appendingPathComponent("App.swift")
        )
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
        let content = try await store.readContent(rootID: root.id, relativePath: "App.swift", workloadClass: .codemap)
        XCTAssertTrue(content?.contains("DirectSessionWorktreeType") == true)
        let loadedFile = await store.file(rootID: root.id, relativePath: "App.swift")
        let file = try XCTUnwrap(loadedFile)

        let repair = try await store.repairMissingCodemapSnapshots(for: [file], timeout: .seconds(6))
        XCTAssertTrue(repair.pendingFileIDs.isEmpty)
        XCTAssertTrue(repair.snapshotsByFileID[file.id]?.fileAPI?.apiDescription.contains("DirectSessionWorktreeType") == true)
    }

    func testMissingWorktreeSnapshotSelfHealsFromPhysicalFileAndRendersLogicalPath() async throws {
        let logicalRootURL = try makeTemporaryRoot(name: "Logical")
        let worktreeRootURL = try makeTemporaryRoot(name: "Worktree")
        try write(
            "struct CanonicalOnlyType {\n    func canonicalMethod() {}\n}\n",
            to: logicalRootURL.appendingPathComponent("Sources/App.swift")
        )
        try write(
            "struct WorktreeOnlyType {\n    func worktreeMethod() {}\n}\n",
            to: worktreeRootURL.appendingPathComponent("Sources/App.swift")
        )

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await store.loadRoot(path: logicalRootURL.path)
        let worktreeRoot = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
        let projection = makeProjection(logicalRoot: logicalRoot, physicalRoot: worktreeRoot, worktreeID: "worktree")
        let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        let file = try await fileRecord(
            at: worktreeRootURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projection.lookupRootScope
        )

        let snapshotBeforeRepair = await store.codemapSnapshot(fileID: file.id)
        XCTAssertNil(snapshotBeforeRepair)
        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            maxResults: 10,
            includeUnmappedPaths: true,
            lookupContext: lookupContext,
            selfHealTimeout: .seconds(12)
        )

        XCTAssertEqual(dto.fileCount, 1)
        XCTAssertTrue(dto.content.contains("WorktreeOnlyType"), dto.content)
        XCTAssertFalse(dto.content.contains("CanonicalOnlyType"), dto.content)
        XCTAssertTrue(dto.content.contains("Sources/App.swift"), dto.content)
        XCTAssertFalse(dto.content.contains(worktreeRoot.standardizedFullPath), dto.content)
        XCTAssertNil(dto.pendingPaths)
        XCTAssertEqual(dto.worktreeScope?.rootMappings.first?.logicalRootPath, logicalRoot.standardizedFullPath)
        XCTAssertEqual(dto.worktreeScope?.rootMappings.first?.effectiveRootPath, worktreeRoot.standardizedFullPath)
        let snapshotAfterRepair = await store.codemapSnapshot(fileID: file.id)
        XCTAssertNotNil(snapshotAfterRepair)
    }

    func testSwitchingCodeStructureScopeFromWorktreeAToBDoesNotReuseA() async throws {
        let logicalRootURL = try makeTemporaryRoot(name: "SwitchLogical")
        let worktreeAURL = try makeTemporaryRoot(name: "SwitchA")
        let worktreeBURL = try makeTemporaryRoot(name: "SwitchB")
        try write("struct CanonicalSwitchType {}\n", to: logicalRootURL.appendingPathComponent("Sources/App.swift"))
        try write(
            "struct WorktreeAType {\n    func branchAMethod() {}\n}\n",
            to: worktreeAURL.appendingPathComponent("Sources/App.swift")
        )
        try write(
            "struct WorktreeBType {\n    func branchBMethod() {}\n}\n",
            to: worktreeBURL.appendingPathComponent("Sources/App.swift")
        )

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await store.loadRoot(path: logicalRootURL.path)
        let logicalRef = WorkspaceRootRef(
            id: logicalRoot.id,
            name: logicalRoot.name,
            fullPath: logicalRoot.standardizedFullPath
        )
        let sessionID = UUID()
        let materializedA = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: sessionID,
            bindings: [makeBinding(
                logicalRoot: logicalRef,
                physicalRoot: WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: worktreeAURL.path),
                worktreeID: "A"
            )]
        )
        let projectionA = try XCTUnwrap(materializedA)
        let materializedB = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: sessionID,
            bindings: [makeBinding(
                logicalRoot: logicalRef,
                physicalRoot: WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: worktreeBURL.path),
                worktreeID: "B"
            )]
        )
        let projectionB = try XCTUnwrap(materializedB)
        let fileA = try await fileRecord(
            at: worktreeAURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projectionA.lookupRootScope
        )
        let fileB = try await fileRecord(
            at: worktreeBURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projectionB.lookupRootScope
        )

        let dtoA = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [fileA],
            maxResults: 10,
            includeUnmappedPaths: true,
            lookupContext: WorkspaceLookupContext(rootScope: projectionA.lookupRootScope, bindingProjection: projectionA),
            selfHealTimeout: .seconds(12)
        )
        XCTAssertTrue(dtoA.content.contains("WorktreeAType"), dtoA.content)

        let dtoB = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [fileA, fileB],
            maxResults: 10,
            includeUnmappedPaths: true,
            lookupContext: WorkspaceLookupContext(rootScope: projectionB.lookupRootScope, bindingProjection: projectionB),
            selfHealTimeout: .seconds(12)
        )

        XCTAssertEqual(dtoB.fileCount, 1)
        XCTAssertTrue(dtoB.content.contains("WorktreeBType"), dtoB.content)
        XCTAssertFalse(dtoB.content.contains("WorktreeAType"), dtoB.content)
        XCTAssertFalse(dtoB.content.contains("CanonicalSwitchType"), dtoB.content)
        XCTAssertEqual(dtoB.worktreeScope?.rootMappings.first?.worktreeID, "B")
        let snapshotA = await store.codemapSnapshot(fileID: fileA.id)
        let snapshotB = await store.codemapSnapshot(fileID: fileB.id)
        XCTAssertNotNil(snapshotA)
        XCTAssertNotNil(snapshotB)
    }

    func testDeletedMaterializedWorktreeFailsClosedInsteadOfReturningCachedStructure() async throws {
        let logicalRootURL = try makeTemporaryRoot(name: "DeletedLogical")
        let worktreeRootURL = try makeTemporaryRoot(name: "DeletedWorktree")
        try write(
            "struct CanonicalDeletedType {\n    func canonicalMethod() {}\n}\n",
            to: logicalRootURL.appendingPathComponent("Sources/App.swift")
        )
        try write(
            "struct CachedDeletedWorktreeType {\n    func cachedMethod() {}\n}\n",
            to: worktreeRootURL.appendingPathComponent("Sources/App.swift")
        )

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await store.loadRoot(path: logicalRootURL.path)
        let worktreeRoot = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
        let projection = makeProjection(logicalRoot: logicalRoot, physicalRoot: worktreeRoot, worktreeID: "deleted")
        let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        let file = try await fileRecord(
            at: worktreeRootURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projection.lookupRootScope
        )

        let primed = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            maxResults: 10,
            includeUnmappedPaths: true,
            lookupContext: lookupContext,
            selfHealTimeout: .seconds(12)
        )
        XCTAssertTrue(primed.content.contains("CachedDeletedWorktreeType"), primed.content)
        try FileManager.default.removeItem(at: worktreeRootURL)

        do {
            _ = try await window.mcpServer.buildCodeStructureDTO(
                fromRecords: [file],
                maxResults: 10,
                includeUnmappedPaths: true,
                lookupContext: lookupContext,
                selfHealTimeout: .zero
            )
            XCTFail("Expected deleted worktree scope to fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stopped rather than reading the canonical checkout"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(worktreeRootURL.standardizedFileURL.path), error.localizedDescription)
        }

        let availability = await store.rootScopeAvailability(projection.lookupRootScope)
        XCTAssertEqual(
            availability,
            .sessionWorktreeUnavailable(missingPhysicalRootPaths: [worktreeRootURL.standardizedFileURL.path])
        )
    }

    func testTargetedSelfHealingIsBoundedByMaxResults() async throws {
        let logicalRootURL = try makeTemporaryRoot(name: "BoundedLogical")
        let worktreeRootURL = try makeTemporaryRoot(name: "BoundedWorktree")
        for index in 1 ... 3 {
            try write(
                "struct BoundedType\(index) {}\n",
                to: worktreeRootURL.appendingPathComponent("Sources/File\(index).swift")
            )
        }

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await store.loadRoot(path: logicalRootURL.path)
        let worktreeRoot = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
        let projection = makeProjection(logicalRoot: logicalRoot, physicalRoot: worktreeRoot, worktreeID: "bounded")
        let files = try await (1 ... 3).asyncMap { index in
            try await self.fileRecord(
                at: worktreeRootURL.appendingPathComponent("Sources/File\(index).swift"),
                store: store,
                rootScope: projection.lookupRootScope
            )
        }

        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: files,
            maxResults: 1,
            includeUnmappedPaths: false,
            lookupContext: WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection),
            selfHealTimeout: .seconds(6)
        )

        XCTAssertLessThanOrEqual(dto.fileCount, 1)
        XCTAssertNil(dto.pendingPaths)
        let firstSnapshot = await store.codemapSnapshot(fileID: files[0].id)
        let secondSnapshot = await store.codemapSnapshot(fileID: files[1].id)
        let thirdSnapshot = await store.codemapSnapshot(fileID: files[2].id)
        XCTAssertNotNil(firstSnapshot)
        XCTAssertNil(secondSnapshot)
        XCTAssertNil(thirdSnapshot)
    }

    func testUnavailableWorktreeScopeFailsClosedBeforeCanonicalScan() async throws {
        let logicalRootURL = try makeTemporaryRoot(name: "UnavailableLogical")
        try write("struct CanonicalUnavailableType {}\n", to: logicalRootURL.appendingPathComponent("Sources/App.swift"))
        let missingWorktreeURL = logicalRootURL.deletingLastPathComponent()
            .appendingPathComponent("Missing-\(UUID().uuidString)", isDirectory: true)

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await store.loadRoot(path: logicalRootURL.path)
        let logicalRef = WorkspaceRootRef(id: logicalRoot.id, name: logicalRoot.name, fullPath: logicalRoot.standardizedFullPath)
        let missingRef = WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: missingWorktreeURL.path)
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRef,
                    physicalRoot: missingRef,
                    binding: makeBinding(logicalRoot: logicalRef, physicalRoot: missingRef, worktreeID: "missing")
                )
            ],
            visibleLogicalRoots: [logicalRef]
        )

        do {
            _ = try await window.mcpServer.buildCodeStructureDTO(
                fromRecords: [],
                maxResults: 10,
                includeUnmappedPaths: true,
                lookupContext: WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection),
                selfHealTimeout: .zero
            )
            XCTFail("Expected unavailable worktree scope to fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stopped rather than reading the canonical checkout"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(missingWorktreeURL.standardizedFileURL.path), error.localizedDescription)
        }

        let availability = await store.rootScopeAvailability(projection.lookupRootScope)
        XCTAssertEqual(
            availability,
            .sessionWorktreeUnavailable(missingPhysicalRootPaths: [missingWorktreeURL.standardizedFileURL.path])
        )
    }

    private func makeWindow(root: URL) async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Code Structure Worktree \(UUID().uuidString.prefix(8))",
            repoPaths: [root.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "mcpCodeStructureWorktreeTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        _ = try await window.workspaceFileContextStore.loadRoot(path: root.path)
        return window
    }

    private func makeProjection(
        logicalRoot: WorkspaceRootRecord,
        physicalRoot: WorkspaceRootRecord,
        worktreeID: String
    ) -> WorkspaceRootBindingProjection {
        let logicalRef = WorkspaceRootRef(
            id: logicalRoot.id,
            name: logicalRoot.name,
            fullPath: logicalRoot.standardizedFullPath
        )
        let physicalRef = WorkspaceRootRef(
            id: physicalRoot.id,
            name: logicalRoot.name,
            fullPath: physicalRoot.standardizedFullPath
        )
        return WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRef,
                    physicalRoot: physicalRef,
                    binding: makeBinding(logicalRoot: logicalRef, physicalRoot: physicalRef, worktreeID: worktreeID)
                )
            ],
            visibleLogicalRoots: [logicalRef]
        )
    }

    private func makeBinding(
        logicalRoot: WorkspaceRootRef,
        physicalRoot: WorkspaceRootRef,
        worktreeID: String
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-\(worktreeID)",
            repositoryID: "repo-\(worktreeID)",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.standardizedFullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: worktreeID,
            worktreeRootPath: physicalRoot.standardizedFullPath,
            worktreeName: URL(fileURLWithPath: physicalRoot.standardizedFullPath).lastPathComponent,
            branch: "feature/\(worktreeID)",
            source: "test"
        )
    }

    private func fileRecord(
        at url: URL,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope
    ) async throws -> WorkspaceFileRecord {
        let result = await store.lookupPath(url.path, profile: .mcpRead, rootScope: rootScope)
        return try XCTUnwrap(result?.file)
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPCodeStructureWorktreeTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.standardizedFileURL
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        values.reserveCapacity(underestimatedCount)
        for element in self {
            try await values.append(transform(element))
        }
        return values
    }
}
