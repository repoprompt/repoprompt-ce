import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class MCPSelectionReplyFreshnessTests: XCTestCase {
    func testFullIssuePathReturnsAbsoluteForExactlyOneAuthorizedRoot() {
        let root = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/workspace/project")
        let path = "/workspace/project/Sources/Missing.swift"

        XCTAssertEqual(
            MCPServerViewModel.SelectionReplyAssembler.logicalIssuePath(
                path,
                roots: [root],
                rootDisplayNamesByRootID: [root.id: root.name],
                lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
                display: .full
            ),
            path
        )
    }

    func testFullIssuePathRedactsOutOfScopeAndCrossRootStaleSelections() {
        let authorizedRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/workspace/project")
        let nestedRoot = WorkspaceRootRef(id: UUID(), name: "Nested", fullPath: "/workspace/project/Packages/Nested")
        let labels = [authorizedRoot.id: authorizedRoot.name, nestedRoot.id: nestedRoot.name]
        let lookupContext = WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        let scenarios: [(path: String, roots: [WorkspaceRootRef], expected: String)] = [
            ("/private/outside/Secret.swift", [authorizedRoot], "unmapped:Secret.swift"),
            ("/workspace/other/Stale.swift", [authorizedRoot], "unmapped:Stale.swift"),
            (
                "/workspace/project/Packages/Nested/Ambiguous.swift",
                [authorizedRoot, nestedRoot],
                "unmapped:Ambiguous.swift"
            )
        ]

        for scenario in scenarios {
            XCTAssertEqual(
                MCPServerViewModel.SelectionReplyAssembler.logicalIssuePath(
                    scenario.path,
                    roots: scenario.roots,
                    rootDisplayNamesByRootID: labels,
                    lookupContext: lookupContext,
                    display: .full
                ),
                scenario.expected,
                scenario.path
            )
        }
    }

    func testSupportedMissingCodemapDiagnosticsArePending() async {
        let file = makeFileRecord(relativePath: "Sources/Pending.swift")
        let issue = WorkspaceCodemapOperationIssue.coordinationUnavailable
        let presentation = WorkspaceCodemapOperationPresentation(
            orderedEntries: [],
            coverage: .pending([issue]),
            issues: [issue],
            publicationReceipt: nil
        )

        let diagnostics = await MCPServerViewModel.SelectionReplyAssembler.missingCodemapDiagnostics(
            for: [file],
            presentation: presentation
        ) { file in
            file.standardizedRelativePath
        }

        XCTAssertEqual(diagnostics.pendingPaths, ["Sources/Pending.swift"])
        XCTAssertEqual(diagnostics.unmappedPaths, [])
    }

    func testUnsupportedMissingCodemapDiagnosticsRemainUnmapped() async {
        let file = makeFileRecord(relativePath: "README.txt")

        let diagnostics = await MCPServerViewModel.SelectionReplyAssembler.missingCodemapDiagnostics(
            for: [file],
            presentation: .empty
        ) { file in
            file.standardizedRelativePath
        }

        XCTAssertEqual(diagnostics.pendingPaths, [])
        XCTAssertEqual(diagnostics.unmappedPaths, ["README.txt"])
    }

    func testWorkspaceContextCodeStructureUsesUsageAwareAutoDiagnostics() async throws {
        let root = try makeTemporaryRoot(name: "WorkspaceCodeDiagnostics")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let tabID = UUID()
        let (window, _) = await makeWindow(root: root, tabID: tabID, selection: StoredSelection())
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let selectedFile = makeFileRecord(relativePath: "Sources/Selected.swift")
        let requestedCodemapFile = makeFileRecord(relativePath: "Sources/Requested.swift")
        let selectedEntry = MCPServerViewModel.SelectionReplyAssembler.SelectedEntry(
            entry: ResolvedPromptFileEntry(file: selectedFile)
        )
        let issue = WorkspaceCodemapOperationIssue.coordinationUnavailable
        let presentation = WorkspaceCodemapOperationPresentation(
            orderedEntries: [],
            coverage: .pending([issue]),
            issues: [issue],
            publicationReceipt: nil
        )
        let collections = MCPServerViewModel.SelectionReplyAssembler.SelectionCollections(
            selected: [selectedEntry],
            codemap: [],
            requestedCodemapFiles: [requestedCodemapFile],
            codemapAutoEnabled: true,
            codeMapUsage: .auto,
            invalid: [],
            codemapPresentation: presentation
        )

        let builder = MCPServerViewModel.CodeStructureBuilder(
            owner: window.mcpServer,
            lookupContext: .visibleWorkspace
        )
        let maybeDTO = await builder.build(for: collections)
        let dto = try XCTUnwrap(maybeDTO)

        XCTAssertEqual(dto.pendingPaths, ["Sources/Requested.swift"])
        XCTAssertNil(dto.unmappedPaths)
    }

    func testTerminalCodemapDispositionOverridesPendingRegardlessOfIssueOrder() async {
        let file = makeFileRecord(relativePath: "Sources/Terminal.swift")
        let ticket = makeCodemapTicket(fileID: file.id, rootID: file.rootID)
        let pending = WorkspaceCodemapOperationIssue.pending(fileID: file.id, ticket: ticket)
        let terminal = WorkspaceCodemapOperationIssue.unavailable(
            fileID: file.id,
            reason: .unsupportedFileType
        )

        for issues in [[terminal, pending], [pending, terminal]] {
            let presentation = WorkspaceCodemapOperationPresentation(
                orderedEntries: [],
                coverage: .pending(issues),
                issues: issues,
                publicationReceipt: nil
            )
            let diagnostics = await MCPServerViewModel.SelectionReplyAssembler.missingCodemapDiagnostics(
                for: [file],
                presentation: presentation
            ) { file in
                file.standardizedRelativePath
            }

            XCTAssertEqual(diagnostics.pendingPaths, [], "Issue order: \(issues)")
            XCTAssertEqual(diagnostics.unmappedPaths, ["Sources/Terminal.swift"], "Issue order: \(issues)")
        }
    }

    func testAutoUnsupportedNoTargetPresentationDoesNotMarkCodemapIncomplete() async throws {
        let root = try makeTemporaryRoot(name: "AutoUnsupportedNoTarget")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let readme = root.appendingPathComponent("README.txt")
        try write("plain text\n", to: readme)

        let tabID = UUID()
        let selection = StoredSelection(
            selectedPaths: [readme.path],
            codemapAutoEnabled: true
        )
        let (window, _) = await makeWindow(root: root, tabID: tabID, selection: selection)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: root.path
        )

        let issue = WorkspaceCodemapOperationIssue.automatic(.unavailable(.noReadySources))
        let presentation = WorkspaceCodemapOperationPresentation(
            orderedEntries: [],
            coverage: .pending([issue]),
            issues: [issue],
            publicationReceipt: nil
        )
        let reply = await window.mcpServer.buildBorrowedTabSelectionReply(
            codemapPresentation: presentation,
            from: selection,
            includeBlocks: true,
            display: .relative,
            lookupContext: .visibleWorkspace
        )

        XCTAssertFalse(
            reply.tokenAccounting?.incompleteComponents?.contains("codemap_presentation") == true,
            String(describing: reply.tokenAccounting?.incompleteComponents)
        )
        XCTAssertTrue(reply.codeStructure?.pendingPaths?.isEmpty ?? true)
        XCTAssertTrue(reply.codeStructure?.unmappedPaths?.isEmpty ?? true)
    }

    func testBorrowedAutoReplyReportsPendingAutomaticTargetCodemap() async throws {
        let root = try makeTemporaryRoot(name: "AutoPendingTarget")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let source = root.appendingPathComponent("Source.swift")
        let target = root.appendingPathComponent("Target.swift")
        try write("struct Source {}\n", to: source)
        try write("struct Target {}\n", to: target)

        let tabID = UUID()
        let selection = StoredSelection(
            selectedPaths: [source.path],
            codemapAutoEnabled: true
        )
        let (window, _) = await makeWindow(root: root, tabID: tabID, selection: selection)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let loadedRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: root.path
        )
        let maybeTargetRecord = await window.promptManager.workspaceFileContextStore.file(
            rootID: loadedRoot.id,
            relativePath: "Target.swift"
        )
        let targetRecord = try XCTUnwrap(maybeTargetRecord)
        let rootEpoch = makeRootEpoch(rootID: targetRecord.rootID)
        let issue = WorkspaceCodemapOperationIssue.automatic(.pending([
            .candidateDemand(
                rootEpoch: rootEpoch,
                fileID: targetRecord.id,
                ticket: makeCodemapTicket(fileID: targetRecord.id, rootID: targetRecord.rootID)
            )
        ]))
        let presentation = WorkspaceCodemapOperationPresentation(
            orderedEntries: [],
            coverage: .pending([issue]),
            issues: [issue],
            publicationReceipt: nil
        )

        let reply = await window.mcpServer.buildBorrowedTabSelectionReply(
            codemapPresentation: presentation,
            from: selection,
            includeBlocks: true,
            display: .full,
            lookupContext: .visibleWorkspace
        )

        XCTAssertTrue(
            reply.tokenAccounting?.incompleteComponents?.contains("codemap_presentation") == true,
            String(describing: reply.tokenAccounting?.incompleteComponents)
        )
        XCTAssertEqual(reply.codeStructure?.pendingPaths, [target.standardizedFileURL.path])
        XCTAssertTrue(reply.codeStructure?.unmappedPaths?.isEmpty ?? true)
    }

    func testActiveVisibleSelectionMarksMissingCachedFileTokensIncomplete() async throws {
        let root = try makeTemporaryRoot(name: "ActiveVisibleIncomplete")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let oldFile = root.appendingPathComponent("Old.swift")
        let newFile = root.appendingPathComponent("New.swift")
        try write("struct OldTokenBaseline {}\n", to: oldFile)
        try write("struct NewVisibleSelection {}\n", to: newFile)

        let tabID = UUID()
        let oldSelection = StoredSelection(selectedPaths: [oldFile.path])
        let newSelection = StoredSelection(selectedPaths: [newFile.path])
        let (window, workspaceID) = await makeWindow(root: root, tabID: tabID, selection: oldSelection)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: root.path
        )
        await window.promptManager.tokenCountingViewModel.forceImmediateRecount()

        var liveTab = try XCTUnwrap(window.workspaceManager.composeTab(with: tabID))
        liveTab.selection = newSelection
        XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(liveTab, inWorkspaceID: workspaceID))
        let context = makeContext(
            window: window,
            workspaceID: workspaceID,
            tabID: tabID,
            selection: newSelection
        )
        let activeResolution = MCPServerViewModel.ResolvedTabContextSnapshot(
            snapshot: context,
            usesActiveTabCompatibility: true
        )

        let reply = await window.mcpServer.buildCurrentSelectionReply(
            includeBlocks: false,
            display: .full,
            resolvedContext: activeResolution,
            lookupContext: .visibleWorkspace
        )

        XCTAssertEqual(reply.files?.map(\.path), [newFile.path])
        XCTAssertEqual(reply.tokenAccounting?.source, "active_tab_published")
        XCTAssertEqual(reply.tokenAccounting?.status, "incomplete")
        XCTAssertTrue(reply.tokenAccounting?.refreshPending == true)
        XCTAssertTrue(reply.tokenAccounting?.incompleteComponents?.contains("files") == true)
        XCTAssertEqual(reply.totalTokens, 0)
        let formatted = ToolOutputFormatter.formatSelectionReplyToString(reply)
        XCTAssertTrue(formatted.contains("- Total tokens: pending (Auto view)"), formatted)
        XCTAssertFalse(formatted.contains("- Total tokens: 0 (Auto view)"), formatted)
    }

    func testMutationReplyRereadsLiveTabSelectionAfterProviderStabilization() async throws {
        let root = try makeTemporaryRoot(name: "MutationReply")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let staleFile = root.appendingPathComponent("Stale.swift")
        let freshFile = root.appendingPathComponent("Fresh.swift")
        try write("struct Stale {}\n", to: staleFile)
        try write("struct Fresh {}\n", to: freshFile)

        let tabID = UUID()
        let staleSelection = StoredSelection(selectedPaths: [staleFile.path])
        let freshSelection = StoredSelection(selectedPaths: [freshFile.path])
        let (window, workspaceID) = await makeWindow(root: root, tabID: tabID, selection: staleSelection)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let loadedRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: root.path
        )

        let providerStabilizedContext = makeContext(
            window: window,
            workspaceID: workspaceID,
            tabID: tabID,
            selection: staleSelection
        )
        let ingressBeforeReply = await window.workspaceFileContextStore.scopedIngressBarrierStatsForTesting(
            rootID: loadedRoot.id
        )
        var liveTab = try XCTUnwrap(window.workspaceManager.composeTab(with: tabID))
        liveTab.selection = freshSelection
        XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(liveTab, inWorkspaceID: workspaceID))
        let reply = await window.mcpServer.buildSelectionMutationReply(
            from: staleSelection,
            includeBlocks: false,
            display: .full,
            virtualContext: providerStabilizedContext,
            lookupContext: .visibleWorkspace
        )

        let ingressAfterReply = await window.workspaceFileContextStore.scopedIngressBarrierStatsForTesting(
            rootID: loadedRoot.id
        )
        XCTAssertEqual(reply.files?.map(\.path), [freshFile.path])
        XCTAssertEqual(ingressAfterReply.launchCount, ingressBeforeReply.launchCount)
    }

    func testCurrentReplyRereadsLiveTabSelectionAfterProviderStabilization() async throws {
        let root = try makeTemporaryRoot(name: "CurrentReply")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let staleFile = root.appendingPathComponent("Stale.swift")
        let freshFile = root.appendingPathComponent("Fresh.swift")
        try write("struct Stale {}\n", to: staleFile)
        try write("struct Fresh {}\n", to: freshFile)

        let tabID = UUID()
        let staleSelection = StoredSelection(selectedPaths: [staleFile.path])
        let freshSelection = StoredSelection(selectedPaths: [freshFile.path])
        let (window, workspaceID) = await makeWindow(root: root, tabID: tabID, selection: staleSelection)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let loadedRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: root.path
        )

        let providerStabilizedContext = makeContext(
            window: window,
            workspaceID: workspaceID,
            tabID: tabID,
            selection: staleSelection
        )
        let resolvedContext = MCPServerViewModel.ResolvedTabContextSnapshot(
            snapshot: providerStabilizedContext,
            usesActiveTabCompatibility: false
        )
        let ingressBeforeReply = await window.workspaceFileContextStore.scopedIngressBarrierStatsForTesting(
            rootID: loadedRoot.id
        )
        var liveTab = try XCTUnwrap(window.workspaceManager.composeTab(with: tabID))
        liveTab.selection = freshSelection
        XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(liveTab, inWorkspaceID: workspaceID))
        let reply = await window.mcpServer.buildCurrentSelectionReply(
            includeBlocks: false,
            display: .full,
            resolvedContext: resolvedContext,
            lookupContext: .visibleWorkspace
        )

        let ingressAfterReply = await window.workspaceFileContextStore.scopedIngressBarrierStatsForTesting(
            rootID: loadedRoot.id
        )
        XCTAssertEqual(reply.files?.map(\.path), [freshFile.path])
        XCTAssertEqual(ingressAfterReply.launchCount, ingressBeforeReply.launchCount)
    }

    func testStabilizedVirtualContextRefreshesCanonicalSelectionAndRevisionTogether() async throws {
        let root = try makeTemporaryRoot(name: "StabilizedRevision")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let staleFile = root.appendingPathComponent("Stale.swift")
        let freshFile = root.appendingPathComponent("Fresh.swift")
        try write("struct Stale {}\n", to: staleFile)
        try write("struct Fresh {}\n", to: freshFile)

        let tabID = UUID()
        let staleSelection = StoredSelection(selectedPaths: [staleFile.path])
        let freshSelection = StoredSelection(selectedPaths: [freshFile.path])
        let (window, workspaceID) = await makeWindow(
            root: root,
            tabID: tabID,
            selection: staleSelection
        )
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        var staleContext = makeContext(
            window: window,
            workspaceID: workspaceID,
            tabID: tabID,
            selection: staleSelection
        )
        staleContext.selectionRevision = 0
        var liveTab = try XCTUnwrap(window.workspaceManager.composeTab(with: tabID))
        liveTab.selection = freshSelection
        XCTAssertTrue(
            window.workspaceManager.updateComposeTabStoredOnly(
                liveTab,
                inWorkspaceID: workspaceID
            )
        )

        let stabilized = await window.mcpServer.stabilizedVirtualContext(for: staleContext)
        let canonicalRevision = window.workspaceManager.selectionRevisionForMCP(
            workspaceID: workspaceID,
            tabID: tabID
        )
        XCTAssertEqual(stabilized.selection, freshSelection)
        XCTAssertEqual(stabilized.selectionRevision, canonicalRevision)
        XCTAssertGreaterThan(stabilized.selectionRevision, 0)
    }

    func testSelectedRecordReadStabilizesCanonicalPairWithoutMutatingRunSnapshot() async throws {
        let root = try makeTemporaryRoot(name: "SelectedRecordSnapshot")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let staleFile = root.appendingPathComponent("Stale.swift")
        let fullFile = root.appendingPathComponent("FreshFull.swift")
        let slicedFile = root.appendingPathComponent("FreshSlice.swift")
        let codemapFile = root.appendingPathComponent("FreshCodemap.swift")
        let laterFile = root.appendingPathComponent("Later.swift")
        try write("struct Stale {}\n", to: staleFile)
        try write("struct FreshFull {}\n", to: fullFile)
        try write("struct FreshSlice {}\n", to: slicedFile)
        try write("struct FreshCodemap {}\n", to: codemapFile)
        try write("struct Later {}\n", to: laterFile)

        let tabID = UUID()
        let staleSelection = StoredSelection(
            selectedPaths: [staleFile.path],
            codemapAutoEnabled: false
        )
        let freshSelection = StoredSelection(
            selectedPaths: [fullFile.path],
            slices: [slicedFile.path: [LineRange(start: 1, end: 1)]],
            codemapAutoEnabled: false
        )
        let laterSelection = StoredSelection(
            selectedPaths: [laterFile.path],
            codemapAutoEnabled: false
        )
        let (window, workspaceID) = await makeWindow(
            root: root,
            tabID: tabID,
            selection: staleSelection
        )
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: root.path
        )

        var staleContext = makeContext(
            window: window,
            workspaceID: workspaceID,
            tabID: tabID,
            selection: staleSelection
        )
        staleContext.selectionRevision = 0
        let connectionID = UUID()
        let clientName = "selection-read-snapshot"
        window.mcpServer.tabContextByConnectionID[connectionID] = staleContext
        window.mcpServer.windowIDByConnection[connectionID] = window.windowID
        window.mcpServer.connectionIDToRunID[connectionID] = try XCTUnwrap(staleContext.runID)
        window.mcpServer.setRequestMetadataOverrideForTesting(.init(
            connectionID: connectionID,
            clientName: clientName,
            windowID: window.windowID,
            runPurpose: .agentModeRun
        ))
        defer { window.mcpServer.setRequestMetadataOverrideForTesting(nil) }

        let selectionIdentity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID)
        _ = await window.selectionCoordinator.persistSelection(
            freshSelection,
            for: selectionIdentity,
            source: .mcpTabContext,
            mirrorToUIIfActive: true
        )
        let canonicalRevision = window.workspaceManager.selectionRevisionForMCP(
            workspaceID: workspaceID,
            tabID: tabID
        )
        XCTAssertGreaterThan(canonicalRevision, 0)

        let collections = try await window.mcpServer.selectionCollectionsForCurrentTabContext()
        XCTAssertEqual(
            Set(collections.selected.map(\.entry.file.standardizedFullPath)),
            Set([fullFile.standardizedFileURL.path, slicedFile.standardizedFileURL.path])
        )
        XCTAssertEqual(
            collections.selected.first(where: {
                $0.entry.file.standardizedFullPath == slicedFile.standardizedFileURL.path
            })?.entry.lineRanges,
            [LineRange(start: 1, end: 1)]
        )
        XCTAssertFalse(collections.selected.contains {
            $0.entry.file.standardizedFullPath == codemapFile.standardizedFileURL.path
        })
        let selectedRecords = try await window.mcpServer.selectedRecordsForCurrentTabContext()
        XCTAssertEqual(
            Set(selectedRecords.map(\.standardizedFullPath)),
            Set([fullFile.standardizedFileURL.path, slicedFile.standardizedFileURL.path])
        )
        await drainMainQueue()

        let cachedContext = try XCTUnwrap(window.mcpServer.tabContextByConnectionID[connectionID])
        XCTAssertEqual(cachedContext.selection, staleSelection)
        XCTAssertEqual(cachedContext.selectionRevision, 0)
        XCTAssertEqual(
            window.workspaceManager.composeTab(with: tabID)?.selection,
            freshSelection
        )
        XCTAssertEqual(
            window.workspaceManager.selectionRevisionForMCP(
                workspaceID: workspaceID,
                tabID: tabID
            ),
            canonicalRevision
        )

        let captured = try window.mcpServer.stabilizedSelectionReadSnapshot(.init(
            snapshot: staleContext,
            usesActiveTabCompatibility: false
        ))
        XCTAssertEqual(captured.snapshot.selection, freshSelection)
        XCTAssertEqual(captured.snapshot.selectionRevision, canonicalRevision)
        _ = await window.selectionCoordinator.persistSelection(
            laterSelection,
            for: selectionIdentity,
            source: .mcpTabContext,
            mirrorToUIIfActive: true
        )
        await drainMainQueue()

        let cachedContextAfterLaterSelection = try XCTUnwrap(window.mcpServer.tabContextByConnectionID[connectionID])
        XCTAssertEqual(cachedContextAfterLaterSelection.selection, staleSelection)
        XCTAssertEqual(cachedContextAfterLaterSelection.selectionRevision, 0)

        let capturedCollections = await window.mcpServer.selectionCollections(
            for: captured.snapshot,
            codeMapUsageOverride: .some(.none)
        )
        XCTAssertEqual(
            Set(capturedCollections.selected.map(\.entry.file.standardizedFullPath)),
            Set([fullFile.standardizedFileURL.path, slicedFile.standardizedFileURL.path])
        )
        XCTAssertFalse(capturedCollections.selected.contains {
            $0.entry.file.standardizedFullPath == laterFile.standardizedFileURL.path
        })

        let compatibilitySnapshot = try window.mcpServer.stabilizedSelectionReadSnapshot(.init(
            snapshot: staleContext,
            usesActiveTabCompatibility: true
        ))
        XCTAssertEqual(compatibilitySnapshot.snapshot.selection, staleSelection)
        XCTAssertEqual(compatibilitySnapshot.snapshot.selectionRevision, 0)

        let missingTabID = UUID()
        var missingCanonicalContext = makeContext(
            window: window,
            workspaceID: workspaceID,
            tabID: missingTabID,
            selection: staleSelection
        )
        missingCanonicalContext.selectionRevision = 0
        XCTAssertThrowsError(try window.mcpServer.stabilizedSelectionReadSnapshot(.init(
            snapshot: missingCanonicalContext,
            usesActiveTabCompatibility: false
        ))) { error in
            XCTAssertEqual(
                error as? MCPServerViewModel.StabilizedSelectionReadSnapshotError,
                .canonicalTabUnavailable(
                    workspaceID: workspaceID,
                    tabID: missingTabID
                )
            )
        }
        window.mcpServer.tabContextByConnectionID[connectionID] = missingCanonicalContext
        window.mcpServer.connectionIDToRunID[connectionID] = try XCTUnwrap(missingCanonicalContext.runID)
        do {
            _ = try await window.mcpServer.selectedRecordsForCurrentTabContext()
            XCTFail("Expected a missing canonical tab to fail closed")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Invalid params"), String(describing: error))
            XCTAssertTrue(
                String(describing: error).contains("Canonical selection is unavailable"),
                String(describing: error)
            )
        }
    }

    func testAlreadyAwaitedRepliesKeepProviderResolvedLookupContext() async throws {
        let workspaceRoot = try makeTemporaryRoot(name: "Workspace")
        let worktreeRoot = try makeTemporaryRoot(name: "Worktree")
        defer {
            try? FileManager.default.removeItem(at: workspaceRoot.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: worktreeRoot.deletingLastPathComponent())
        }
        try write("struct WorkspacePlaceholder {}\n", to: workspaceRoot.appendingPathComponent("Placeholder.swift"))
        let worktreeFile = worktreeRoot.appendingPathComponent("WorktreeOnly.swift")
        try write("struct WorktreeOnly {}\n", to: worktreeFile)

        let tabID = UUID()
        let logicalFile = workspaceRoot.appendingPathComponent(worktreeFile.lastPathComponent)
        let logicalSelection = StoredSelection(selectedPaths: [logicalFile.path])
        let (window, workspaceID) = await makeWindow(
            root: workspaceRoot,
            tabID: tabID,
            selection: logicalSelection
        )
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let loadedWorkspaceRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: workspaceRoot.path
        )
        let loadedWorktreeRoot = try await window.workspaceFileContextStore.loadRoot(
            path: worktreeRoot.path,
            kind: .sessionWorktree
        )
        let logicalRoot = WorkspaceRootRef(
            id: loadedWorkspaceRoot.id,
            name: loadedWorkspaceRoot.name,
            fullPath: loadedWorkspaceRoot.standardizedFullPath
        )
        let physicalRoot = WorkspaceRootRef(
            id: loadedWorktreeRoot.id,
            name: loadedWorkspaceRoot.name,
            fullPath: loadedWorktreeRoot.standardizedFullPath
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRoot,
                    physicalRoot: physicalRoot,
                    binding: makeBinding(logicalRoot: logicalRoot, physicalRoot: physicalRoot)
                )
            ],
            visibleLogicalRoots: [logicalRoot]
        )
        let providerResolvedLookupContext = WorkspaceLookupContext(
            rootScope: projection.lookupRootScope,
            bindingProjection: projection
        )
        let targetIdentity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID)
        let targetWorkspace = try XCTUnwrap(
            window.workspaceManager.workspaces.first(where: { $0.id == workspaceID })
        )
        let unrelatedSelection = StoredSelection(selectedPaths: ["/tmp/unrelated-duplicate-tab.swift"])
        let unrelatedWorkspace = WorkspaceModel(
            name: "Unrelated Duplicate Tab",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID, name: "Unrelated", selection: unrelatedSelection)],
            activeComposeTabID: tabID
        )
        window.workspaceManager.workspaces = [unrelatedWorkspace, targetWorkspace]
        var targetTab = try XCTUnwrap(window.workspaceManager.composeTab(for: targetIdentity))
        targetTab.selection = logicalSelection
        XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(targetTab, inWorkspaceID: workspaceID))
        XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.selection, unrelatedSelection)
        XCTAssertEqual(window.workspaceManager.composeTab(for: targetIdentity)?.selection, logicalSelection)

        let context = makeContext(
            window: window,
            workspaceID: workspaceID,
            tabID: tabID,
            selection: logicalSelection
        )
        let resolvedContext = MCPServerViewModel.ResolvedTabContextSnapshot(
            snapshot: context,
            usesActiveTabCompatibility: false
        )

        var liveTab = try XCTUnwrap(window.workspaceManager.composeTab(for: targetIdentity))
        liveTab.selection = logicalSelection
        XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(liveTab, inWorkspaceID: workspaceID))
        let currentReply = await window.mcpServer.buildCurrentSelectionReply(
            includeBlocks: false,
            display: .full,
            resolvedContext: resolvedContext,
            lookupContext: providerResolvedLookupContext
        )
        liveTab = try XCTUnwrap(window.workspaceManager.composeTab(for: targetIdentity))
        liveTab.selection = logicalSelection
        XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(liveTab, inWorkspaceID: workspaceID))
        let mutationReply = await window.mcpServer.buildSelectionMutationReply(
            from: logicalSelection,
            includeBlocks: false,
            display: .full,
            virtualContext: context,
            lookupContext: providerResolvedLookupContext
        )

        let projectedDisplayPath = "\(workspaceRoot.lastPathComponent)/\(worktreeFile.lastPathComponent)"
        XCTAssertEqual(currentReply.files?.map(\.path), [projectedDisplayPath])
        XCTAssertEqual(mutationReply.files?.map(\.path), [projectedDisplayPath])
    }

    func testWorktreeProjectedFullSelectionPathsUseDisambiguatedLogicalRootLabels() async throws {
        let firstLogicalRoot = try makeTemporaryRoot(name: "repo")
        let secondLogicalRoot = try makeTemporaryRoot(name: "repo")
        let firstWorktreeRoot = try makeTemporaryRoot(name: "worktree-one")
        let secondWorktreeRoot = try makeTemporaryRoot(name: "worktree-two")
        defer {
            try? FileManager.default.removeItem(at: firstLogicalRoot.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondLogicalRoot.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: firstWorktreeRoot.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondWorktreeRoot.deletingLastPathComponent())
        }
        try write("struct FirstLogicalPlaceholder {}\n", to: firstLogicalRoot.appendingPathComponent("Placeholder.swift"))
        try write("struct SecondLogicalPlaceholder {}\n", to: secondLogicalRoot.appendingPathComponent("Placeholder.swift"))
        let firstRelativePath = "Sources/First.swift"
        let secondRelativePath = "Sources/Second.swift"
        try write("struct FirstWorktreeOnly {}\n", to: firstWorktreeRoot.appendingPathComponent(firstRelativePath))
        try write("struct SecondWorktreeOnly {}\n", to: secondWorktreeRoot.appendingPathComponent(secondRelativePath))

        let tabID = UUID()
        let logicalSelection = StoredSelection(selectedPaths: [
            firstLogicalRoot.appendingPathComponent(firstRelativePath).path,
            secondLogicalRoot.appendingPathComponent(secondRelativePath).path
        ])
        let (window, _) = await makeWindow(
            roots: [firstLogicalRoot, secondLogicalRoot],
            tabID: tabID,
            selection: logicalSelection
        )
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let firstLogicalLoaded = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: firstLogicalRoot.path
        )
        let secondLogicalLoaded = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: secondLogicalRoot.path
        )
        let firstPhysicalLoaded = try await window.workspaceFileContextStore.loadRoot(
            path: firstWorktreeRoot.path,
            kind: .sessionWorktree
        )
        let secondPhysicalLoaded = try await window.workspaceFileContextStore.loadRoot(
            path: secondWorktreeRoot.path,
            kind: .sessionWorktree
        )
        let firstLogicalRef = WorkspaceRootRef(
            id: firstLogicalLoaded.id,
            name: firstLogicalLoaded.name,
            fullPath: firstLogicalLoaded.standardizedFullPath
        )
        let secondLogicalRef = WorkspaceRootRef(
            id: secondLogicalLoaded.id,
            name: secondLogicalLoaded.name,
            fullPath: secondLogicalLoaded.standardizedFullPath
        )
        let firstPhysicalRef = WorkspaceRootRef(
            id: firstPhysicalLoaded.id,
            name: firstPhysicalLoaded.name,
            fullPath: firstPhysicalLoaded.standardizedFullPath
        )
        let secondPhysicalRef = WorkspaceRootRef(
            id: secondPhysicalLoaded.id,
            name: secondPhysicalLoaded.name,
            fullPath: secondPhysicalLoaded.standardizedFullPath
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: firstLogicalRef,
                    physicalRoot: firstPhysicalRef,
                    binding: makeBinding(logicalRoot: firstLogicalRef, physicalRoot: firstPhysicalRef, suffix: "-first")
                ),
                .init(
                    logicalRoot: secondLogicalRef,
                    physicalRoot: secondPhysicalRef,
                    binding: makeBinding(logicalRoot: secondLogicalRef, physicalRoot: secondPhysicalRef, suffix: "-second")
                )
            ],
            visibleLogicalRoots: [firstLogicalRef, secondLogicalRef]
        )
        let lookupContext = WorkspaceLookupContext(
            rootScope: projection.lookupRootScope,
            bindingProjection: projection
        )
        let labels = await lookupContext.logicalRootDisplayNamesByRootID(store: window.workspaceFileContextStore)
        let firstLabel = try XCTUnwrap(labels[firstPhysicalLoaded.id])
        let secondLabel = try XCTUnwrap(labels[secondPhysicalLoaded.id])
        XCTAssertNotEqual(firstLabel, secondLabel)

        let firstPhysicalFiles = await window.workspaceFileContextStore.files(inRoot: firstPhysicalLoaded.id)
        let secondPhysicalFiles = await window.workspaceFileContextStore.files(inRoot: secondPhysicalLoaded.id)
        let firstFile = try XCTUnwrap(
            firstPhysicalFiles.first { $0.standardizedRelativePath == firstRelativePath }
        )
        let secondFile = try XCTUnwrap(
            secondPhysicalFiles.first { $0.standardizedRelativePath == secondRelativePath }
        )
        let formatter = MCPServerViewModel.PathFormatter(
            format: .full,
            owner: window.mcpServer,
            projection: projection,
            rootScope: projection.lookupRootScope
        )
        let firstPath = await formatter.displayPath(for: firstFile)
        let secondPath = await formatter.displayPath(for: secondFile)
        let paths = [firstPath, secondPath]
        XCTAssertEqual(Set(paths), [
            "\(firstLabel)/\(firstRelativePath)",
            "\(secondLabel)/\(secondRelativePath)"
        ])
        for path in paths {
            XCTAssertFalse(path.hasPrefix(firstLogicalRoot.path), path)
            XCTAssertFalse(path.hasPrefix(secondLogicalRoot.path), path)
            XCTAssertFalse(path.hasPrefix(firstWorktreeRoot.path), path)
            XCTAssertFalse(path.hasPrefix(secondWorktreeRoot.path), path)
        }
    }

    #if DEBUG
        func testActiveMCPTokenRepliesCompleteWhileBackgroundRecountIsBlockedAndCoalesce() async throws {
            let root = try makeTemporaryRoot(name: "ActiveTokenCache")
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let fileURL = root.appendingPathComponent("Cached.swift")
            try write("struct ActiveCachedTokenType {}\n", to: fileURL)

            let tabID = UUID()
            let selection = StoredSelection(selectedPaths: [fileURL.path])
            let (window, workspaceID) = await makeWindow(root: root, tabID: tabID, selection: selection)
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: root.path
            )
            let tokenCounter = window.promptManager.tokenCountingViewModel
            await tokenCounter.forceImmediateRecount()
            let recountGate = TokenAccountingGate()
            tokenCounter.setBeforeTokenCalculationForTesting {
                await recountGate.markStartedAndWaitForRelease()
            }
            defer {
                Task { @MainActor in
                    await recountGate.release()
                    tokenCounter.setBeforeTokenCalculationForTesting(nil)
                }
            }

            let baselineStarts = tokenCounter.tokenCalculationStartCountForTesting()
            tokenCounter.markDirty(.selection)
            await recountGate.waitUntilStarted()

            let context = makeContext(
                window: window,
                workspaceID: workspaceID,
                tabID: tabID,
                selection: selection
            )
            let activeResolution = MCPServerViewModel.ResolvedTabContextSnapshot(
                snapshot: context,
                usesActiveTabCompatibility: true
            )
            let repliesCompleted = expectation(description: "active token replies complete while recount is blocked")
            var selectionReply: ToolResultDTOs.SelectionReply?
            var workspaceReply: ToolResultDTOs.PromptContextDTO?
            var replyError: Error?
            Task { @MainActor in
                selectionReply = await window.mcpServer.buildCurrentSelectionReply(
                    includeBlocks: false,
                    display: .relative,
                    resolvedContext: activeResolution,
                    lookupContext: .visibleWorkspace
                )
                do {
                    workspaceReply = try await window.mcpServer.buildTabWorkspaceContext(
                        context: context,
                        include: ["selection", "tokens"],
                        display: .relative,
                        activeTabCompatibility: true
                    )
                } catch {
                    replyError = error
                }
                repliesCompleted.fulfill()
            }
            await fulfillment(of: [repliesCompleted], timeout: 1)
            if let replyError { throw replyError }
            let resolvedSelectionReply = try XCTUnwrap(selectionReply)
            let resolvedWorkspaceReply = try XCTUnwrap(workspaceReply)

            XCTAssertEqual(resolvedSelectionReply.tokenAccounting?.source, "active_tab_published")
            XCTAssertTrue(resolvedSelectionReply.tokenAccounting?.refreshPending == true)
            XCTAssertEqual(resolvedWorkspaceReply.tokenAccounting?.source, "active_tab_published")
            XCTAssertTrue(resolvedWorkspaceReply.tokenAccounting?.refreshPending == true)
            XCTAssertEqual(tokenCounter.tokenCalculationStartCountForTesting(), baselineStarts + 1)

            await recountGate.release()
            tokenCounter.setBeforeTokenCalculationForTesting(nil)
        }

        func testBoundMCPTokenRepliesCompleteWhileContentRefreshIsBlockedAndCoalesce() async throws {
            let root = try makeTemporaryRoot(name: "BoundTokenCache")
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let fileURL = root.appendingPathComponent("Bound.swift")
            try write("struct BoundCachedTokenType {}\n", to: fileURL)

            let tabID = UUID()
            let selection = StoredSelection(selectedPaths: [fileURL.path])
            let (window, workspaceID) = await makeWindow(root: root, tabID: tabID, selection: selection)
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: root.path
            )
            await window.promptManager.tokenCountingViewModel.forceImmediateRecount()
            let refreshGate = TokenAccountingGate()
            window.mcpServer.setBeforeVirtualTokenRefreshForTesting {
                await refreshGate.markStartedAndWaitForRelease()
            }
            defer {
                Task { @MainActor in
                    await refreshGate.release()
                    window.mcpServer.setBeforeVirtualTokenRefreshForTesting(nil)
                }
            }

            let context = makeContext(
                window: window,
                workspaceID: workspaceID,
                tabID: tabID,
                selection: selection
            )
            let boundResolution = MCPServerViewModel.ResolvedTabContextSnapshot(
                snapshot: context,
                usesActiveTabCompatibility: false
            )
            let baselineStarts = window.mcpServer.virtualTokenRefreshStartCountForTesting()
            let firstCompleted = expectation(description: "first bound token reply completes before refresh")
            var firstReply: ToolResultDTOs.SelectionReply?
            Task { @MainActor in
                firstReply = await window.mcpServer.buildCurrentSelectionReply(
                    includeBlocks: false,
                    display: .relative,
                    resolvedContext: boundResolution,
                    lookupContext: .visibleWorkspace
                )
                firstCompleted.fulfill()
            }
            await refreshGate.waitUntilStarted()
            await fulfillment(of: [firstCompleted], timeout: 1)

            let remainingCompleted = expectation(description: "coalesced bound token replies complete while refresh is blocked")
            var secondReply: ToolResultDTOs.SelectionReply?
            var workspaceReply: ToolResultDTOs.PromptContextDTO?
            var replyError: Error?
            Task { @MainActor in
                secondReply = await window.mcpServer.buildCurrentSelectionReply(
                    includeBlocks: false,
                    display: .relative,
                    resolvedContext: boundResolution,
                    lookupContext: .visibleWorkspace
                )
                do {
                    workspaceReply = try await window.mcpServer.buildTabWorkspaceContext(
                        context: context,
                        include: ["selection", "tokens"],
                        display: .relative,
                        activeTabCompatibility: false
                    )
                } catch {
                    replyError = error
                }
                remainingCompleted.fulfill()
            }
            await fulfillment(of: [remainingCompleted], timeout: 1)
            if let replyError { throw replyError }
            let resolvedFirstReply = try XCTUnwrap(firstReply)
            let resolvedSecondReply = try XCTUnwrap(secondReply)
            let resolvedWorkspaceReply = try XCTUnwrap(workspaceReply)

            XCTAssertEqual(resolvedFirstReply.tokenAccounting?.source, "bound_tab_cached_state")
            XCTAssertEqual(resolvedFirstReply.tokenAccounting?.status, "incomplete")
            XCTAssertTrue(resolvedFirstReply.tokenAccounting?.refreshPending == true)
            XCTAssertFalse(resolvedFirstReply.tokenAccounting?.incompleteComponents?.contains("files") == true)
            XCTAssertEqual(resolvedSecondReply.tokenAccounting?.source, "bound_tab_cached_state")
            XCTAssertEqual(resolvedSecondReply.tokenAccounting?.status, "incomplete")
            XCTAssertTrue(resolvedSecondReply.tokenAccounting?.refreshPending == true)
            XCTAssertFalse(resolvedSecondReply.tokenAccounting?.incompleteComponents?.contains("files") == true)
            XCTAssertEqual(resolvedWorkspaceReply.tokenAccounting?.source, "bound_tab_cached_state")
            XCTAssertEqual(resolvedWorkspaceReply.tokenAccounting?.status, "incomplete")
            XCTAssertTrue(resolvedWorkspaceReply.tokenAccounting?.refreshPending == true)
            XCTAssertFalse(resolvedWorkspaceReply.tokenAccounting?.incompleteComponents?.contains("files") == true)
            XCTAssertEqual(window.mcpServer.virtualTokenRefreshStartCountForTesting(), baselineStarts + 1)
            let refreshStartCount = await refreshGate.startCount()
            // Identical bound selection and workspace token requests share one signature,
            // so all cached replies coalesce onto the same background refresh.
            XCTAssertEqual(refreshStartCount, 1)

            await refreshGate.release()
            window.mcpServer.setBeforeVirtualTokenRefreshForTesting(nil)
        }

        func testBoundReplyUsesPublishedFileTokensWhileCodemapPresentationIsPending() async throws {
            let root = try makeTemporaryRoot(name: "BoundPublishedPendingCodemap")
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let source = root.appendingPathComponent("Source.swift")
            let target = root.appendingPathComponent("Target.swift")
            try write("struct SourceForPublishedTokens { func selected() {} }\n", to: source)
            try write("struct TargetForPendingCodemap { func related() {} }\n", to: target)

            let tabID = UUID()
            let selection = StoredSelection(
                selectedPaths: [source.path],
                codemapAutoEnabled: true
            )
            let (window, _) = await makeWindow(root: root, tabID: tabID, selection: selection)
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let loadedRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: root.path
            )
            await window.promptManager.tokenCountingViewModel.forceImmediateRecount()
            let targetRecordCandidate = await window.promptManager.workspaceFileContextStore.file(
                rootID: loadedRoot.id,
                relativePath: "Target.swift"
            )
            let targetRecord = try XCTUnwrap(targetRecordCandidate)
            let rootEpoch = makeRootEpoch(rootID: targetRecord.rootID)
            let issue = WorkspaceCodemapOperationIssue.automatic(.pending([
                .candidateDemand(
                    rootEpoch: rootEpoch,
                    fileID: targetRecord.id,
                    ticket: makeCodemapTicket(fileID: targetRecord.id, rootID: targetRecord.rootID)
                )
            ]))
            let presentation = WorkspaceCodemapOperationPresentation(
                orderedEntries: [],
                coverage: .pending([issue]),
                issues: [issue],
                publicationReceipt: nil
            )
            let baselineStarts = window.mcpServer.virtualTokenRefreshStartCountForTesting()

            let reply = await window.mcpServer.buildBorrowedTabSelectionReply(
                codemapPresentation: presentation,
                from: selection,
                includeBlocks: false,
                display: .full,
                lookupContext: .visibleWorkspace
            )

            XCTAssertEqual(reply.files?.map(\.path), [source.path])
            XCTAssertGreaterThan(reply.totalTokens ?? 0, 0)
            XCTAssertEqual(reply.summary?.fullCount, 1)
            XCTAssertGreaterThan(reply.summary?.fullTokens ?? 0, 0)
            XCTAssertEqual(reply.tokenAccounting?.source, "bound_tab_cached_state")
            XCTAssertEqual(reply.tokenAccounting?.status, "incomplete")
            XCTAssertTrue(reply.tokenAccounting?.refreshPending == false)
            XCTAssertFalse(reply.tokenAccounting?.incompleteComponents?.contains("files") == true)
            XCTAssertTrue(reply.tokenAccounting?.incompleteComponents?.contains("codemap_presentation") == true)
            XCTAssertEqual(window.mcpServer.virtualTokenRefreshStartCountForTesting(), baselineStarts)
        }

        func testBoundMCPTokenRefreshesForDistinctSignaturesDoNotCancelEachOther() async throws {
            let root = try makeTemporaryRoot(name: "BoundTokenSignatures")
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let fileURL = root.appendingPathComponent("Bound.swift")
            try write("struct BoundDistinctSignatureType {}\n", to: fileURL)

            let tabID = UUID()
            let selection = StoredSelection(selectedPaths: [fileURL.path])
            let (window, workspaceID) = await makeWindow(root: root, tabID: tabID, selection: selection)
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: root.path
            )
            await window.promptManager.tokenCountingViewModel.forceImmediateRecount()
            let refreshGate = TokenAccountingGate()
            window.mcpServer.setBeforeVirtualTokenRefreshForTesting {
                await refreshGate.markStartedAndWaitForRelease()
            }
            defer {
                Task { @MainActor in
                    await refreshGate.release()
                    window.mcpServer.setBeforeVirtualTokenRefreshForTesting(nil)
                }
            }

            let firstContext = makeContext(
                window: window,
                workspaceID: workspaceID,
                tabID: tabID,
                selection: selection,
                promptText: "First signature"
            )
            let secondContext = makeContext(
                window: window,
                workspaceID: workspaceID,
                tabID: tabID,
                selection: selection,
                promptText: "Second signature"
            )
            let firstResolution = MCPServerViewModel.ResolvedTabContextSnapshot(
                snapshot: firstContext,
                usesActiveTabCompatibility: false
            )
            let secondResolution = MCPServerViewModel.ResolvedTabContextSnapshot(
                snapshot: secondContext,
                usesActiveTabCompatibility: false
            )
            let baselineStarts = window.mcpServer.virtualTokenRefreshStartCountForTesting()

            let firstReply = await window.mcpServer.buildCurrentSelectionReply(
                includeBlocks: false,
                display: .relative,
                resolvedContext: firstResolution,
                lookupContext: .visibleWorkspace
            )
            await refreshGate.waitUntilStarted(count: 1)
            let secondReply = await window.mcpServer.buildCurrentSelectionReply(
                includeBlocks: false,
                display: .relative,
                resolvedContext: secondResolution,
                lookupContext: .visibleWorkspace
            )
            await refreshGate.waitUntilStarted(count: 2)

            XCTAssertEqual(firstReply.tokenAccounting?.source, "bound_tab_cached_state")
            XCTAssertEqual(secondReply.tokenAccounting?.source, "bound_tab_cached_state")
            XCTAssertEqual(window.mcpServer.virtualTokenRefreshStartCountForTesting(), baselineStarts + 2)
            let refreshStartCount = await refreshGate.startCount()
            XCTAssertEqual(refreshStartCount, 2)

            await refreshGate.release()
            window.mcpServer.setBeforeVirtualTokenRefreshForTesting(nil)
            for _ in 0 ..< 100 where window.mcpServer.virtualTokenRefreshTaskCountForTesting() > 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(window.mcpServer.virtualTokenRefreshTaskCountForTesting(), 0)

            let startsBeforeCacheHits = window.mcpServer.virtualTokenRefreshStartCountForTesting()
            let firstCachedReply = await window.mcpServer.buildCurrentSelectionReply(
                includeBlocks: false,
                display: .relative,
                resolvedContext: firstResolution,
                lookupContext: .visibleWorkspace
            )
            let secondCachedReply = await window.mcpServer.buildCurrentSelectionReply(
                includeBlocks: false,
                display: .relative,
                resolvedContext: secondResolution,
                lookupContext: .visibleWorkspace
            )
            XCTAssertEqual(firstCachedReply.tokenAccounting?.source, "bound_tab_cache")
            XCTAssertEqual(firstCachedReply.tokenAccounting?.status, "stale")
            XCTAssertTrue(firstCachedReply.tokenAccounting?.refreshPending == true)
            XCTAssertEqual(secondCachedReply.tokenAccounting?.source, "bound_tab_cache")
            XCTAssertEqual(secondCachedReply.tokenAccounting?.status, "stale")
            XCTAssertTrue(secondCachedReply.tokenAccounting?.refreshPending == true)
            XCTAssertEqual(window.mcpServer.virtualTokenRefreshStartCountForTesting(), startsBeforeCacheHits + 2)
        }
    #endif

    #if DEBUG
        func testFileToolLookupCacheCoalescesConcurrentCurrentMisses() async throws {
            let workspaceRoot = try makeTemporaryRoot(name: "LookupCacheCoalescingWorkspace")
            let worktreeRoot = try makeTemporaryRoot(name: "LookupCacheCoalescingWorktree")
            defer {
                try? FileManager.default.removeItem(at: workspaceRoot.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: worktreeRoot.deletingLastPathComponent())
            }
            let logicalFile = workspaceRoot.appendingPathComponent("Shared.swift")
            let physicalFile = worktreeRoot.appendingPathComponent("Shared.swift")
            try write("struct Canonical {}\n", to: logicalFile)
            try write("struct Worktree {}\n", to: physicalFile)

            let tabID = UUID()
            let sessionID = UUID()
            let connectionID = UUID()
            let (window, workspaceID) = await makeWindow(
                root: workspaceRoot,
                tabID: tabID,
                selection: StoredSelection()
            )
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: workspaceRoot.path
            )
            let physicalRoot = try await window.workspaceFileContextStore.loadRoot(
                path: worktreeRoot.path,
                kind: .sessionWorktree
            )
            let binding = makeBinding(
                logicalRoot: WorkspaceRootRef(
                    id: logicalRoot.id,
                    name: logicalRoot.name,
                    fullPath: logicalRoot.standardizedFullPath
                ),
                physicalRoot: WorkspaceRootRef(
                    id: physicalRoot.id,
                    name: physicalRoot.name,
                    fullPath: physicalRoot.standardizedFullPath
                )
            )

            var liveTab = try XCTUnwrap(window.workspaceManager.composeTab(with: tabID))
            liveTab.activeAgentSessionID = sessionID
            XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(liveTab, inWorkspaceID: workspaceID))
            window.mcpServer.registerAgentWorktreeBindingsProvider { requestedSessionID, requestedTabID in
                guard requestedSessionID == sessionID, requestedTabID == tabID else { return .unavailable }
                return .hydrated([binding])
            }
            try window.mcpServer.bindTabForConnection(
                connectionID: connectionID,
                clientName: "lookup-cache-coalescing-test",
                tabID: tabID,
                workspaceID: workspaceID,
                windowID: window.windowID
            )
            let metadata = MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: "lookup-cache-coalescing-test",
                windowID: window.windowID,
                runPurpose: .agentModeRun
            )

            let resolutionGate = TokenAccountingGate()
            let coalescingGate = TokenAccountingGate()
            window.mcpServer.setBeforeFileToolLookupContextResolutionForTesting {
                await resolutionGate.markStartedAndWaitForRelease()
            }
            window.mcpServer.setFileToolLookupContextDidCoalesceForTesting {
                await coalescingGate.markStartedAndWaitForRelease()
            }
            addTeardownBlock {
                await MainActor.run {
                    window.mcpServer.setBeforeFileToolLookupContextResolutionForTesting(nil)
                    window.mcpServer.setFileToolLookupContextDidCoalesceForTesting(nil)
                }
                await coalescingGate.release()
                await resolutionGate.release()
            }
            window.mcpServer.resetFileToolLookupContextCacheStatsForTesting()

            let firstLookup = Task { @MainActor in
                await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            }
            await resolutionGate.waitUntilStarted()
            let secondLookup = Task { @MainActor in
                await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            }
            addTeardownBlock {
                firstLookup.cancel()
                secondLookup.cancel()
                await coalescingGate.release()
                await resolutionGate.release()
                _ = await firstLookup.value
                _ = await secondLookup.value
            }
            await coalescingGate.waitUntilStarted()
            await coalescingGate.release()
            await resolutionGate.release()

            let first = await firstLookup.value
            let second = await secondLookup.value
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.translateInputPath(logicalFile.path), physicalFile.path)
            XCTAssertEqual(second.translateInputPath(logicalFile.path), physicalFile.path)
            XCTAssertEqual(
                window.mcpServer.fileToolLookupContextCacheStatsForTesting(),
                .init(hits: 0, misses: 1, coalescedWaits: 1, staleCompletions: 0)
            )
        }

        func testFileToolLookupCacheRejectsSessionRootReplacementBeforePublication() async throws {
            let workspaceRoot = try makeTemporaryRoot(name: "LookupCachePublicationWorkspace")
            let worktreeRoot = try makeTemporaryRoot(name: "LookupCachePublicationWorktree")
            defer {
                try? FileManager.default.removeItem(at: workspaceRoot.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: worktreeRoot.deletingLastPathComponent())
            }
            let logicalFile = workspaceRoot.appendingPathComponent("Shared.swift")
            try write("struct Canonical {}\n", to: logicalFile)
            try write("struct Worktree {}\n", to: worktreeRoot.appendingPathComponent("Shared.swift"))

            let tabID = UUID()
            let sessionID = UUID()
            let connectionID = UUID()
            let (window, workspaceID) = await makeWindow(
                root: workspaceRoot,
                tabID: tabID,
                selection: StoredSelection()
            )
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: workspaceRoot.path
            )
            let physicalRoot = try await window.workspaceFileContextStore.loadRoot(
                path: worktreeRoot.path,
                kind: .sessionWorktree
            )
            let binding = makeBinding(
                logicalRoot: WorkspaceRootRef(
                    id: logicalRoot.id,
                    name: logicalRoot.name,
                    fullPath: logicalRoot.standardizedFullPath
                ),
                physicalRoot: WorkspaceRootRef(
                    id: physicalRoot.id,
                    name: physicalRoot.name,
                    fullPath: physicalRoot.standardizedFullPath
                )
            )

            var liveTab = try XCTUnwrap(window.workspaceManager.composeTab(with: tabID))
            liveTab.activeAgentSessionID = sessionID
            XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(liveTab, inWorkspaceID: workspaceID))
            window.mcpServer.registerAgentWorktreeBindingsProvider { requestedSessionID, requestedTabID in
                guard requestedSessionID == sessionID, requestedTabID == tabID else { return .unavailable }
                return .hydrated([binding])
            }
            try window.mcpServer.bindTabForConnection(
                connectionID: connectionID,
                clientName: "lookup-cache-publication-test",
                tabID: tabID,
                workspaceID: workspaceID,
                windowID: window.windowID
            )
            let metadata = MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: "lookup-cache-publication-test",
                windowID: window.windowID,
                runPurpose: .agentModeRun
            )

            let postValidationGate = TokenAccountingGate()
            let coalescingGate = TokenAccountingGate()
            window.mcpServer.setAfterFileToolLookupContextRootValidationForTesting {
                await postValidationGate.markStartedAndWaitForRelease()
            }
            window.mcpServer.setFileToolLookupContextDidCoalesceForTesting {
                await coalescingGate.markStartedAndWaitForRelease()
            }
            addTeardownBlock {
                await MainActor.run {
                    window.mcpServer.setAfterFileToolLookupContextRootValidationForTesting(nil)
                    window.mcpServer.setFileToolLookupContextDidCoalesceForTesting(nil)
                }
                await coalescingGate.release()
                await postValidationGate.release()
            }
            window.mcpServer.resetFileToolLookupContextCacheStatsForTesting()

            let ownerLookup = Task { @MainActor in
                await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            }
            await postValidationGate.waitUntilStarted()
            let followerLookup = Task { @MainActor in
                await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            }
            addTeardownBlock {
                ownerLookup.cancel()
                followerLookup.cancel()
                await coalescingGate.release()
                await postValidationGate.release()
                _ = await ownerLookup.value
                _ = await followerLookup.value
            }
            await coalescingGate.waitUntilStarted()
            await coalescingGate.release()
            await postValidationGate.waitUntilStarted(count: 2)

            await window.workspaceFileContextStore.unloadRoot(id: physicalRoot.id)
            let replacementPhysicalRoot = try await window.workspaceFileContextStore.loadRoot(
                path: worktreeRoot.path,
                kind: .sessionWorktree
            )
            XCTAssertNotEqual(replacementPhysicalRoot.id, physicalRoot.id)
            await postValidationGate.release()

            let ownerResult = await ownerLookup.value
            let followerResult = await followerLookup.value
            XCTAssertEqual(ownerResult, AgentWorkspaceLookupContextResolver.failClosedLookupContext)
            XCTAssertEqual(followerResult, AgentWorkspaceLookupContextResolver.failClosedLookupContext)

            window.mcpServer.setAfterFileToolLookupContextRootValidationForTesting(nil)
            window.mcpServer.setFileToolLookupContextDidCoalesceForTesting(nil)
            let retry = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            XCTAssertEqual(retry.bindingProjection?.physicalRootRefs.map(\.id), [replacementPhysicalRoot.id])

            let cacheUseGate = TokenAccountingGate()
            window.mcpServer.setAfterFileToolLookupContextRootValidationForTesting {
                await cacheUseGate.markStartedAndWaitForRelease()
            }
            addTeardownBlock {
                await MainActor.run {
                    window.mcpServer.setAfterFileToolLookupContextRootValidationForTesting(nil)
                }
                await cacheUseGate.release()
            }
            let cachedLookup = Task { @MainActor in
                await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            }
            addTeardownBlock {
                cachedLookup.cancel()
                await cacheUseGate.release()
                _ = await cachedLookup.value
            }
            await cacheUseGate.waitUntilStarted()
            await window.workspaceFileContextStore.unloadRoot(id: replacementPhysicalRoot.id)
            let latestPhysicalRoot = try await window.workspaceFileContextStore.loadRoot(
                path: worktreeRoot.path,
                kind: .sessionWorktree
            )
            XCTAssertNotEqual(latestPhysicalRoot.id, replacementPhysicalRoot.id)
            await cacheUseGate.release()

            let cachedResult = await cachedLookup.value
            XCTAssertEqual(cachedResult, AgentWorkspaceLookupContextResolver.failClosedLookupContext)
            window.mcpServer.setAfterFileToolLookupContextRootValidationForTesting(nil)
            let latestRetry = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            XCTAssertEqual(latestRetry.bindingProjection?.physicalRootRefs.map(\.id), [latestPhysicalRoot.id])
            XCTAssertEqual(
                window.mcpServer.fileToolLookupContextCacheStatsForTesting(),
                .init(hits: 0, misses: 3, coalescedWaits: 1, staleCompletions: 3)
            )
        }

        func testFileToolLookupCacheInvalidatesWithoutLeakingStaleRoots() async throws {
            let workspaceRoot = try makeTemporaryRoot(name: "LookupCacheWorkspace")
            let replacementWorkspaceRoot = try makeTemporaryRoot(name: "LookupCacheReplacementWorkspace")
            let worktreeA = try makeTemporaryRoot(name: "LookupCacheWorktreeA")
            let worktreeB = try makeTemporaryRoot(name: "LookupCacheWorktreeB")
            defer {
                try? FileManager.default.removeItem(at: workspaceRoot.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: replacementWorkspaceRoot.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: worktreeA.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: worktreeB.deletingLastPathComponent())
            }
            try write("struct CanonicalA {}\n", to: workspaceRoot.appendingPathComponent("Shared.swift"))
            try write("struct CanonicalB {}\n", to: replacementWorkspaceRoot.appendingPathComponent("Shared.swift"))
            try write("struct WorktreeA {}\n", to: worktreeA.appendingPathComponent("Shared.swift"))
            try write("struct WorktreeB {}\n", to: worktreeB.appendingPathComponent("Shared.swift"))

            let tabID = UUID()
            let sessionID = UUID()
            let connectionID = UUID()
            let runB = UUID()
            let (window, workspaceID) = await makeWindow(
                root: workspaceRoot,
                tabID: tabID,
                selection: StoredSelection()
            )
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: workspaceRoot.path
            )
            let physicalRootA = try await window.workspaceFileContextStore.loadRoot(
                path: worktreeA.path,
                kind: .sessionWorktree
            )
            let physicalRootB = try await window.workspaceFileContextStore.loadRoot(
                path: worktreeB.path,
                kind: .sessionWorktree
            )
            let logicalRootRef = WorkspaceRootRef(
                id: logicalRoot.id,
                name: logicalRoot.name,
                fullPath: logicalRoot.standardizedFullPath
            )
            let physicalRootRefA = WorkspaceRootRef(
                id: physicalRootA.id,
                name: physicalRootA.name,
                fullPath: physicalRootA.standardizedFullPath
            )
            let physicalRootRefB = WorkspaceRootRef(
                id: physicalRootB.id,
                name: physicalRootB.name,
                fullPath: physicalRootB.standardizedFullPath
            )
            let bindingA = makeBinding(logicalRoot: logicalRootRef, physicalRoot: physicalRootRefA)
            let bindingB = makeBinding(logicalRoot: logicalRootRef, physicalRoot: physicalRootRefB)
            var currentBinding = bindingA

            var liveTab = try XCTUnwrap(window.workspaceManager.composeTab(with: tabID))
            liveTab.activeAgentSessionID = sessionID
            XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(liveTab, inWorkspaceID: workspaceID))
            window.mcpServer.registerAgentWorktreeBindingsProvider { requestedSessionID, requestedTabID in
                guard requestedSessionID == sessionID, requestedTabID == tabID else { return .unavailable }
                return .hydrated([currentBinding])
            }
            try window.mcpServer.bindTabForConnection(
                connectionID: connectionID,
                clientName: "lookup-cache-test",
                tabID: tabID,
                workspaceID: workspaceID,
                windowID: window.windowID,
                runID: nil
            )
            let metadata = MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: "lookup-cache-test",
                windowID: window.windowID,
                runPurpose: .agentModeRun
            )
            window.mcpServer.resetFileToolLookupContextCacheStatsForTesting()

            let first = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            let second = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            XCTAssertEqual(
                first.translateInputPath(workspaceRoot.appendingPathComponent("Shared.swift").path),
                worktreeA.appendingPathComponent("Shared.swift").path
            )
            XCTAssertEqual(second, first)
            XCTAssertEqual(
                window.mcpServer.fileToolLookupContextCacheStatsForTesting(),
                .init(hits: 1, misses: 1, coalescedWaits: 0, staleCompletions: 0)
            )

            currentBinding = bindingB
            let resolutionGate = TokenAccountingGate()
            let coalescingGate = TokenAccountingGate()
            window.mcpServer.setBeforeFileToolLookupContextResolutionForTesting {
                await resolutionGate.markStartedAndWaitForRelease()
            }
            window.mcpServer.setFileToolLookupContextDidCoalesceForTesting {
                await coalescingGate.markStartedAndWaitForRelease()
            }
            addTeardownBlock {
                await MainActor.run {
                    window.mcpServer.setBeforeFileToolLookupContextResolutionForTesting(nil)
                    window.mcpServer.setFileToolLookupContextDidCoalesceForTesting(nil)
                }
                await coalescingGate.release()
                await resolutionGate.release()
            }
            let staleLookup = Task { @MainActor in
                await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            }
            await resolutionGate.waitUntilStarted()
            let coalescedLookup = Task { @MainActor in
                await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            }
            addTeardownBlock {
                staleLookup.cancel()
                coalescedLookup.cancel()
                await coalescingGate.release()
                await resolutionGate.release()
                _ = await staleLookup.value
                _ = await coalescedLookup.value
            }
            await coalescingGate.waitUntilStarted()
            await coalescingGate.release()
            XCTAssertEqual(window.mcpServer.fileToolLookupContextCacheStatsForTesting().coalescedWaits, 1)
            try window.mcpServer.bindTabForConnection(
                connectionID: connectionID,
                clientName: "lookup-cache-test",
                tabID: tabID,
                workspaceID: workspaceID,
                windowID: window.windowID,
                runID: runB
            )
            await resolutionGate.release()
            let staleResult = await staleLookup.value
            let coalescedResult = await coalescedLookup.value
            XCTAssertEqual(staleResult, AgentWorkspaceLookupContextResolver.failClosedLookupContext)
            XCTAssertEqual(coalescedResult, AgentWorkspaceLookupContextResolver.failClosedLookupContext)
            window.mcpServer.setBeforeFileToolLookupContextResolutionForTesting(nil)
            window.mcpServer.setFileToolLookupContextDidCoalesceForTesting(nil)

            let rebound = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            let reboundHit = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            XCTAssertEqual(
                rebound.translateInputPath(workspaceRoot.appendingPathComponent("Shared.swift").path),
                worktreeB.appendingPathComponent("Shared.swift").path
            )
            XCTAssertEqual(reboundHit, rebound)
            XCTAssertEqual(
                window.mcpServer.fileToolLookupContextCacheStatsForTesting(),
                .init(hits: 2, misses: 3, coalescedWaits: 1, staleCompletions: 2)
            )

            try FileManager.default.removeItem(at: worktreeB)
            let afterWorktreeDeletion = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            XCTAssertEqual(afterWorktreeDeletion, AgentWorkspaceLookupContextResolver.failClosedLookupContext)
            try FileManager.default.createDirectory(at: worktreeB, withIntermediateDirectories: true)
            try write("struct WorktreeBRestored {}\n", to: worktreeB.appendingPathComponent("Shared.swift"))
            let afterWorktreeRestore = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            XCTAssertEqual(
                afterWorktreeRestore.translateInputPath(workspaceRoot.appendingPathComponent("Shared.swift").path),
                worktreeB.appendingPathComponent("Shared.swift").path
            )

            try window.mcpServer.bindTabForConnection(
                connectionID: connectionID,
                clientName: "lookup-cache-test",
                tabID: tabID,
                workspaceID: workspaceID,
                windowID: window.windowID,
                runID: nil
            )
            let nonRunContext = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            XCTAssertEqual(
                nonRunContext.translateInputPath(workspaceRoot.appendingPathComponent("Shared.swift").path),
                worktreeB.appendingPathComponent("Shared.swift").path
            )

            let replacementSessionID = UUID()
            var sessionChangedTab = try XCTUnwrap(window.workspaceManager.composeTab(with: tabID))
            sessionChangedTab.activeAgentSessionID = replacementSessionID
            XCTAssertTrue(
                window.workspaceManager.updateComposeTabStoredOnly(
                    sessionChangedTab,
                    inWorkspaceID: workspaceID
                )
            )
            let afterSessionChange = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            XCTAssertEqual(afterSessionChange, AgentWorkspaceLookupContextResolver.failClosedLookupContext)

            sessionChangedTab.activeAgentSessionID = sessionID
            XCTAssertTrue(
                window.workspaceManager.updateComposeTabStoredOnly(
                    sessionChangedTab,
                    inWorkspaceID: workspaceID
                )
            )
            let restoredSession = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            XCTAssertEqual(
                restoredSession.translateInputPath(workspaceRoot.appendingPathComponent("Shared.swift").path),
                worktreeB.appendingPathComponent("Shared.swift").path
            )

            let replacementWorkspace = WorkspaceModel(
                name: "Lookup Cache Replacement",
                repoPaths: [replacementWorkspaceRoot.path],
                ephemeralFlag: true,
                composeTabs: [ComposeTabState(name: "Replacement")]
            )
            window.workspaceManager.workspaces.append(replacementWorkspace)
            await window.workspaceManager.switchWorkspace(
                to: replacementWorkspace,
                saveState: false,
                reason: "fileToolLookupCacheInvalidationTest"
            )
            let switchedRoots = await window.workspaceFileContextStore.rootRefs(scope: .visibleWorkspace)
            XCTAssertTrue(switchedRoots.contains { $0.standardizedFullPath == StandardizedPath.absolute(replacementWorkspaceRoot.path) })
            XCTAssertFalse(switchedRoots.contains { $0.standardizedFullPath == StandardizedPath.absolute(workspaceRoot.path) })

            let afterWorkspaceSwitch = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
            XCTAssertEqual(afterWorkspaceSwitch, AgentWorkspaceLookupContextResolver.failClosedLookupContext)
            XCTAssertEqual(
                window.mcpServer.fileToolLookupContextCacheStatsForTesting(),
                .init(hits: 2, misses: 8, coalescedWaits: 1, staleCompletions: 2)
            )
        }
    #endif

    func testActiveCompatibilityLookupContextPreservesActiveSessionAuthority() async throws {
        let workspaceRoot = try makeTemporaryRoot(name: "CompatibilityWorkspace")
        let worktreeRoot = try makeTemporaryRoot(name: "CompatibilityWorktree")
        defer {
            try? FileManager.default.removeItem(at: workspaceRoot.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: worktreeRoot.deletingLastPathComponent())
        }
        try write("struct WorkspaceFile {}\n", to: workspaceRoot.appendingPathComponent("WorkspaceFile.swift"))
        try write("struct WorktreeFile {}\n", to: worktreeRoot.appendingPathComponent("WorktreeFile.swift"))

        let tabID = UUID()
        let sessionID = UUID()
        let (window, workspaceID) = await makeWindow(
            root: workspaceRoot,
            tabID: tabID,
            selection: StoredSelection()
        )
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let loadedWorkspaceRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: workspaceRoot.path
        )
        let loadedSessionWorktreeRoot = try await window.workspaceFileContextStore.loadRoot(
            path: worktreeRoot.path,
            kind: .sessionWorktree
        )
        addTeardownBlock {
            await window.workspaceFileContextStore.unloadRoot(id: loadedSessionWorktreeRoot.id)
        }
        let metadata = MCPServerViewModel.RequestMetadata(
            connectionID: nil,
            clientName: "selection-reply-compatibility-test",
            windowID: window.windowID
        )

        var bindingState = AgentSessionWorktreeBindingState.unavailable
        window.mcpServer.registerAgentWorktreeBindingsProvider { requestedSessionID, requestedTabID in
            guard requestedSessionID == sessionID, requestedTabID == tabID else { return .unavailable }
            return bindingState
        }

        let noSessionContext = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
        XCTAssertEqual(noSessionContext, .visibleWorkspace)

        let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID)
        var liveTab = try XCTUnwrap(window.workspaceManager.composeTab(for: identity))
        liveTab.activeAgentSessionID = sessionID
        XCTAssertTrue(window.workspaceManager.updateComposeTabStoredOnly(liveTab, inWorkspaceID: workspaceID))

        bindingState = .hydrated([])
        let emptyBindingContext = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
        XCTAssertEqual(emptyBindingContext, .visibleWorkspace)

        let logicalRoot = WorkspaceRootRef(
            id: loadedWorkspaceRoot.id,
            name: loadedWorkspaceRoot.name,
            fullPath: loadedWorkspaceRoot.standardizedFullPath
        )
        let physicalRoot = WorkspaceRootRef(
            id: UUID(),
            name: loadedWorkspaceRoot.name,
            fullPath: worktreeRoot.path
        )
        bindingState = .hydrated([makeBinding(logicalRoot: logicalRoot, physicalRoot: physicalRoot)])
        let boundContext = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
        XCTAssertNotNil(boundContext.bindingProjection)
        XCTAssertEqual(boundContext.rootScope, boundContext.bindingProjection?.lookupRootScope)
        XCTAssertEqual(
            boundContext.translateInputPath(workspaceRoot.appendingPathComponent("WorktreeFile.swift").path),
            worktreeRoot.appendingPathComponent("WorktreeFile.swift").path
        )

        bindingState = .unhydrated
        let unresolvedContext = await window.mcpServer.resolveFileToolLookupContext(from: metadata)
        XCTAssertEqual(
            unresolvedContext,
            WorkspaceLookupContext(
                rootScope: .sessionBoundWorkspace(canonicalRootPaths: [], physicalRootPaths: []),
                bindingProjection: nil
            )
        )
    }

    private func makeWindow(
        root: URL,
        tabID: UUID,
        selection: StoredSelection
    ) async -> (window: WindowState, workspaceID: UUID) {
        await makeWindow(roots: [root], tabID: tabID, selection: selection)
    }

    private func makeWindow(
        roots: [URL],
        tabID: UUID,
        selection: StoredSelection
    ) async -> (window: WindowState, workspaceID: UUID) {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = WorkspaceModel(
            name: "Selection Reply \(UUID().uuidString.prefix(8))",
            repoPaths: roots.map(\.path),
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID, name: "Agent", selection: selection)],
            activeComposeTabID: tabID
        )
        window.workspaceManager.workspaces = [workspace]
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "mcpSelectionReplyFreshnessTests"
        )
        window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
        return (window, workspace.id)
    }

    private func makeContext(
        window: WindowState,
        workspaceID: UUID,
        tabID: UUID,
        selection: StoredSelection,
        promptText: String = ""
    ) -> MCPServerViewModel.TabScopedContext {
        MCPServerViewModel.TabContextSnapshot(
            tabID: tabID,
            windowID: window.windowID,
            workspaceID: workspaceID,
            promptText: promptText,
            selection: selection,
            selectedMetaPromptIDs: [],
            tabName: "Agent",
            runID: UUID(),
            explicitlyBound: true
        )
    }

    private func makeBinding(
        logicalRoot: WorkspaceRootRef,
        physicalRoot: WorkspaceRootRef,
        suffix: String = ""
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "selection-reply-binding\(suffix)",
            repositoryID: "selection-reply-repository",
            repoKey: "selection-reply-repo-key",
            logicalRootPath: logicalRoot.standardizedFullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "selection-reply-worktree\(suffix)",
            worktreeRootPath: physicalRoot.standardizedFullPath,
            worktreeName: URL(fileURLWithPath: physicalRoot.standardizedFullPath).lastPathComponent,
            branch: "feature/selection-reply",
            source: "test"
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPSelectionReplyFreshnessTests-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL
    }

    private func makeFileRecord(
        relativePath: String,
        rootID: UUID = UUID()
    ) -> WorkspaceFileRecord {
        WorkspaceFileRecord(
            rootID: rootID,
            name: URL(fileURLWithPath: relativePath).lastPathComponent,
            relativePath: relativePath,
            fullPath: "/workspace/project/\(relativePath)",
            parentFolderID: nil
        )
    }

    private func makeRootEpoch(rootID: UUID = UUID()) -> WorkspaceCodemapRootEpoch {
        WorkspaceCodemapRootEpoch(rootID: rootID, rootLifetimeID: UUID())
    }

    private func makeCodemapTicket(
        fileID: UUID,
        rootID: UUID = UUID()
    ) -> WorkspaceCodemapArtifactDemandTicket {
        WorkspaceCodemapArtifactDemandTicket(
            retainID: UUID(),
            requestID: UUID(),
            rootEpoch: makeRootEpoch(rootID: rootID),
            fileID: fileID,
            requestGeneration: 1,
            catalogGeneration: 1,
            pathGeneration: 1,
            ingressGeneration: 1
        )
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async {
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 1.0)
    }
}

#if DEBUG
    private actor TokenAccountingGate {
        private var startedCount = 0
        private var released = false
        private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            startedCount += 1
            let readyWaiters = startWaiters.filter { $0.count <= startedCount }
            startWaiters.removeAll { $0.count <= startedCount }
            readyWaiters.forEach { $0.continuation.resume() }
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStarted(count: Int = 1) async {
            guard startedCount < count else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append((count, continuation))
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func startCount() -> Int {
            startedCount
        }
    }
#endif
