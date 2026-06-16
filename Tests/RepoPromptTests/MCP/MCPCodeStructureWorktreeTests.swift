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

    func testMissingWorktreeSnapshotReturnsPendingThenRendersRefreshedLogicalPath() async throws {
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
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
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
        let pendingDTO = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            maxResults: 10,
            includeUnmappedPaths: true,
            lookupContext: lookupContext
        )

        XCTAssertEqual(pendingDTO.fileCount, 0)
        XCTAssertEqual(pendingDTO.pendingPaths, ["Sources/App.swift"])
        XCTAssertNil(pendingDTO.unmappedPaths)
        _ = try await waitForCodemapSnapshot(store: store, fileID: file.id, timeout: .seconds(12))

        let refreshedDTO = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            maxResults: 10,
            includeUnmappedPaths: true,
            lookupContext: lookupContext
        )
        XCTAssertEqual(refreshedDTO.fileCount, 1)
        XCTAssertTrue(refreshedDTO.content.contains("WorktreeOnlyType"), refreshedDTO.content)
        XCTAssertFalse(refreshedDTO.content.contains("CanonicalOnlyType"), refreshedDTO.content)
        XCTAssertTrue(refreshedDTO.content.contains("Sources/App.swift"), refreshedDTO.content)
        XCTAssertFalse(refreshedDTO.content.contains(worktreeRoot.standardizedFullPath), refreshedDTO.content)
        XCTAssertNil(refreshedDTO.pendingPaths)
        XCTAssertEqual(refreshedDTO.worktreeScope?.rootMappings.first?.logicalRootPath, logicalRoot.standardizedFullPath)
        XCTAssertEqual(refreshedDTO.worktreeScope?.rootMappings.first?.effectiveRootPath, worktreeRoot.standardizedFullPath)
    }

    #if DEBUG
        func testNewlySubmittedCodeStructureScanDoesNotBlockPendingResponse() async throws {
            let logicalRootURL = try makeTemporaryRoot(name: "NonblockingLogical")
            let worktreeRootURL = try makeTemporaryRoot(name: "NonblockingWorktree")
            let fileURL = worktreeRootURL.appendingPathComponent("Sources/App.swift")
            try write("struct NonblockingCodeStructureType {}\n", to: fileURL)

            let window = try await makeWindow(root: logicalRootURL)
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let store = window.workspaceFileContextStore
            let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: logicalRootURL.path
            )
            let worktreeRoot = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
            let projection = makeProjection(logicalRoot: logicalRoot, physicalRoot: worktreeRoot, worktreeID: "nonblocking-code")
            let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
            let file = try await fileRecord(at: fileURL, store: store, rootScope: projection.lookupRootScope)
            let scanGate = AsyncGate()
            await store.setCodemapScanWillStartHandlerForTesting { scannedFileID in
                guard scannedFileID == file.id else { return }
                await scanGate.markStartedAndWaitForRelease()
            }
            defer {
                Task {
                    await scanGate.release()
                    await store.setCodemapScanWillStartHandlerForTesting(nil)
                }
            }

            let responseCompleted = expectation(description: "get_code_structure returns while scan is gated")
            var responseDTO: ToolResultDTOs.SelectedCodeStructureDTO?
            var responseError: Error?
            Task { @MainActor in
                defer { responseCompleted.fulfill() }
                do {
                    responseDTO = try await window.mcpServer.buildCodeStructureDTO(
                        fromRecords: [file],
                        maxResults: 10,
                        includeUnmappedPaths: false,
                        lookupContext: lookupContext
                    )
                } catch {
                    responseError = error
                }
            }

            await scanGate.waitUntilStarted()
            await fulfillment(of: [responseCompleted], timeout: 1)
            if let responseError { throw responseError }
            let dto = try XCTUnwrap(responseDTO)
            XCTAssertEqual(dto.fileCount, 0)
            XCTAssertEqual(dto.pendingPaths, ["Sources/App.swift"])
            XCTAssertNil(dto.unmappedPaths)
        }

        func testDefaultWorkspaceContextDoesNotBlockOnNewlySubmittedScan() async throws {
            let logicalRootURL = try makeTemporaryRoot(name: "ContextNonblockingLogical")
            let worktreeRootURL = try makeTemporaryRoot(name: "ContextNonblockingWorktree")
            let logicalFileURL = logicalRootURL.appendingPathComponent("Sources/App.swift")
            let physicalFileURL = worktreeRootURL.appendingPathComponent("Sources/App.swift")
            try write("struct CanonicalContextType {}\n", to: logicalFileURL)
            try write("struct WorktreeContextType {}\n", to: physicalFileURL)

            let window = try await makeWindow(root: logicalRootURL)
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let store = window.workspaceFileContextStore
            let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: logicalRootURL.path
            )
            let worktreeRoot = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
            let projection = makeProjection(logicalRoot: logicalRoot, physicalRoot: worktreeRoot, worktreeID: "nonblocking-context")
            let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
            let file = try await fileRecord(at: physicalFileURL, store: store, rootScope: projection.lookupRootScope)
            let context = MCPServerViewModel.TabContextSnapshot(
                tabID: UUID(),
                windowID: window.windowID,
                workspaceID: window.workspaceManager.activeWorkspace?.id,
                promptText: "Nonblocking context",
                selection: StoredSelection(selectedPaths: [logicalFileURL.path], codemapAutoEnabled: false),
                selectedMetaPromptIDs: [],
                tabName: "Agent",
                runID: nil,
                frozenLookupContext: lookupContext,
                explicitlyBound: true
            )
            let scanGate = AsyncGate()
            await store.setCodemapScanWillStartHandlerForTesting { scannedFileID in
                guard scannedFileID == file.id else { return }
                await scanGate.markStartedAndWaitForRelease()
            }
            defer {
                Task {
                    await scanGate.release()
                    await store.setCodemapScanWillStartHandlerForTesting(nil)
                }
            }

            let responseCompleted = expectation(description: "default workspace_context returns while scan is gated")
            var responseDTO: ToolResultDTOs.PromptContextDTO?
            var responseError: Error?
            Task { @MainActor in
                defer { responseCompleted.fulfill() }
                do {
                    responseDTO = try await window.mcpServer.buildTabWorkspaceContext(
                        context: context,
                        include: ["prompt", "selection", "code", "tokens"],
                        display: .relative,
                        activeTabCompatibility: false
                    )
                } catch {
                    responseError = error
                }
            }

            await scanGate.waitUntilStarted()
            await fulfillment(of: [responseCompleted], timeout: 1)
            if let responseError { throw responseError }
            let dto = try XCTUnwrap(responseDTO)
            XCTAssertEqual(dto.codeStructure?.fileCount, 0)
            XCTAssertEqual(dto.codeStructure?.pendingPaths, ["Sources/App.swift"])
            XCTAssertNil(dto.codeStructure?.unmappedPaths)
        }

        func testActiveWorktreeScanIsPreservedAndReportedPendingWithoutWaiting() async throws {
            let logicalRootURL = try makeTemporaryRoot(name: "ActiveScanLogical")
            let worktreeRootURL = try makeTemporaryRoot(name: "ActiveScanWorktree")
            let fileURL = worktreeRootURL.appendingPathComponent("Sources/App.swift")
            try write(
                "struct OriginalActiveType {\n    func originalMethod() {}\n}\n",
                to: fileURL
            )

            let window = try await makeWindow(root: logicalRootURL)
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let store = window.workspaceFileContextStore
            let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: logicalRootURL.path
            )
            let worktreeRoot = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
            let loadedWorktreeService = await store.fileSystemServiceForTesting(rootID: worktreeRoot.id)
            let worktreeService = try XCTUnwrap(loadedWorktreeService)
            await worktreeService.stopWatchingForChanges()
            let projection = makeProjection(logicalRoot: logicalRoot, physicalRoot: worktreeRoot, worktreeID: "active")
            let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
            let file = try await fileRecord(at: fileURL, store: store, rootScope: projection.lookupRootScope)
            let fileID = file.id
            let scanGate = AsyncGate()
            await store.setCodemapScanWillStartHandlerForTesting { scannedFileID in
                guard scannedFileID == fileID else { return }
                await scanGate.markStartedAndWaitForRelease()
            }
            defer {
                Task {
                    await scanGate.release()
                    await store.setCodemapScanWillStartHandlerForTesting(nil)
                }
            }

            let submittedRootIDs = try await store.requestInitialRootCodemapScans(rootIDs: [worktreeRoot.id])
            XCTAssertEqual(submittedRootIDs, [worktreeRoot.id])
            await scanGate.waitUntilStarted()
            try write(
                "struct ReplacementMustNotCancelActiveType {\n    func replacementMethod() {}\n}\n",
                to: fileURL
            )
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(2)],
                ofItemAtPath: fileURL.path
            )

            let clock = ContinuousClock()
            let start = clock.now
            let dto = try await window.mcpServer.buildCodeStructureDTO(
                fromRecords: [file],
                maxResults: 10,
                includeUnmappedPaths: false,
                lookupContext: lookupContext
            )
            let elapsed = start.duration(to: clock.now)

            XCTAssertLessThan(elapsed, .seconds(2))
            XCTAssertNil(dto.unmappedPaths)
            XCTAssertEqual(dto.pendingPaths, ["Sources/App.swift"])

            await scanGate.release()
            let snapshot = try await waitForCodemapSnapshot(store: store, fileID: fileID)
            await store.setCodemapScanWillStartHandlerForTesting(nil)
            XCTAssertTrue(snapshot.fileAPI?.apiDescription.contains("OriginalActiveType") == true)
            XCTAssertFalse(snapshot.fileAPI?.apiDescription.contains("ReplacementMustNotCancelActiveType") == true)
        }
    #endif

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
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
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
        // Materialization starts codemap scans asynchronously. Prime both snapshots so this test isolates scope filtering;
        // active-scan pending behavior is covered separately.
        let snapshotA = try await waitForCodemapSnapshot(store: store, fileID: fileA.id, timeout: .seconds(12))
        let snapshotB = try await waitForCodemapSnapshot(store: store, fileID: fileB.id, timeout: .seconds(12))
        XCTAssertTrue(snapshotA.fileAPI?.apiDescription.contains("WorktreeAType") == true)
        XCTAssertTrue(snapshotB.fileAPI?.apiDescription.contains("WorktreeBType") == true)

        let dtoA = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [fileA],
            maxResults: 10,
            includeUnmappedPaths: true,
            lookupContext: WorkspaceLookupContext(rootScope: projectionA.lookupRootScope, bindingProjection: projectionA)
        )
        XCTAssertTrue(dtoA.content.contains("WorktreeAType"), dtoA.content)

        let dtoB = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [fileA, fileB],
            maxResults: 10,
            includeUnmappedPaths: true,
            lookupContext: WorkspaceLookupContext(rootScope: projectionB.lookupRootScope, bindingProjection: projectionB)
        )

        XCTAssertEqual(dtoB.fileCount, 1)
        XCTAssertTrue(dtoB.content.contains("WorktreeBType"), dtoB.content)
        XCTAssertFalse(dtoB.content.contains("WorktreeAType"), dtoB.content)
        XCTAssertFalse(dtoB.content.contains("CanonicalSwitchType"), dtoB.content)
        XCTAssertEqual(dtoB.worktreeScope?.rootMappings.first?.worktreeID, "B")
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
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
        let worktreeRoot = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
        let projection = makeProjection(logicalRoot: logicalRoot, physicalRoot: worktreeRoot, worktreeID: "deleted")
        let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        let file = try await fileRecord(
            at: worktreeRootURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projection.lookupRootScope
        )

        _ = try await store.repairMissingCodemapSnapshots(for: [file], timeout: .seconds(12))
        let primed = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            maxResults: 10,
            includeUnmappedPaths: true,
            lookupContext: lookupContext
        )
        XCTAssertTrue(primed.content.contains("CachedDeletedWorktreeType"), primed.content)
        try FileManager.default.removeItem(at: worktreeRootURL)

        do {
            _ = try await window.mcpServer.buildCodeStructureDTO(
                fromRecords: [file],
                maxResults: 10,
                includeUnmappedPaths: true,
                lookupContext: lookupContext
            )
            XCTFail("Expected deleted worktree scope to fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stopped rather than reading the canonical checkout"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains(worktreeRootURL.standardizedFileURL.path), error.localizedDescription)
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
                "struct BoundedType\(index) {\n    func boundedMethod\(index)() {}\n}\n",
                to: worktreeRootURL.appendingPathComponent("Sources/File\(index).swift")
            )
        }

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
        let worktreeRoot = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
        let projection = makeProjection(logicalRoot: logicalRoot, physicalRoot: worktreeRoot, worktreeID: "bounded")
        let files = try await (1 ... 3).asyncMap { index in
            try await self.fileRecord(
                at: worktreeRootURL.appendingPathComponent("Sources/File\(index).swift"),
                store: store,
                rootScope: projection.lookupRootScope
            )
        }

        let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        let pendingDTO = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: files,
            maxResults: 1,
            includeUnmappedPaths: false,
            lookupContext: lookupContext
        )

        XCTAssertEqual(pendingDTO.fileCount, 0)
        XCTAssertEqual(pendingDTO.pendingPaths, ["Sources/File1.swift"])
        XCTAssertEqual(pendingDTO.unmappedPaths, ["Sources/File2.swift", "Sources/File3.swift"])
        _ = try await waitForCodemapSnapshot(store: store, fileID: files[0].id)
        let firstSnapshot = await store.codemapSnapshot(fileID: files[0].id)
        XCTAssertNotNil(firstSnapshot)
    }

    func testUnavailableWorktreeScopeFailsClosedBeforeCanonicalScan() async throws {
        let logicalRootURL = try makeTemporaryRoot(name: "UnavailableLogical")
        try write("struct CanonicalUnavailableType {}\n", to: logicalRootURL.appendingPathComponent("Sources/App.swift"))
        let missingWorktreeURL = logicalRootURL.deletingLastPathComponent()
            .appendingPathComponent("Missing-\(UUID().uuidString)", isDirectory: true)

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
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
                lookupContext: WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
            )
            XCTFail("Expected unavailable worktree scope to fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stopped rather than reading the canonical checkout"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains(missingWorktreeURL.standardizedFileURL.path), error.localizedDescription)
        }

        let availability = await store.rootScopeAvailability(projection.lookupRootScope)
        XCTAssertEqual(
            availability,
            .sessionWorktreeUnavailable(missingPhysicalRootPaths: [missingWorktreeURL.standardizedFileURL.path])
        )
    }

    private func waitForCodemapSnapshot(
        store: WorkspaceFileContextStore,
        fileID: UUID,
        timeout: Duration = .seconds(6)
    ) async throws -> WorkspaceCodemapSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let snapshot = await store.codemapSnapshot(fileID: fileID) {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for codemap snapshot")
        throw NSError(domain: "MCPCodeStructureWorktreeTests", code: 1)
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
        _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: root.path
        )
        addTeardownBlock { @MainActor in
            await window.workspaceFilesViewModel.cancelAllScans()
        }
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

#if DEBUG
    private actor AsyncGate {
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }

            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
#endif

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
