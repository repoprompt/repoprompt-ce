import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class MCPSelectionContentPackagingTests: XCTestCase {
    func testContentViewIncludesCanonicalCodemapBlocksExactlyOnce() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Selected.swift": "let selectedContentSentinel = true\n",
                "Canonical.swift": "func canonicalFullContentSentinel() {}\n"
            ]
        )
        defer { repositories.cleanup() }
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        _ = try await window.workspaceFileContextStore.loadRoot(path: root.path)
        let selectedLookup = await window.workspaceFileContextStore.lookupPath(
            root.appendingPathComponent("Selected.swift").path
        )
        let codemapLookup = await window.workspaceFileContextStore.lookupPath(
            root.appendingPathComponent("Canonical.swift").path
        )
        let selectedRecord = try XCTUnwrap(selectedLookup?.file)
        let codemapRecord = try XCTUnwrap(codemapLookup?.file)
        let selectedEntry = ResolvedPromptFileEntry(
            file: selectedRecord,
            isCodemap: false,
            mode: .fullFile,
            loadedContent: "let selectedContentSentinel = true\n",
            rootFolderPath: root.path
        )
        let codemapEntry = ResolvedPromptFileEntry(
            file: codemapRecord,
            isCodemap: true,
            mode: .codemap,
            loadedContent: "func canonicalFullContentSentinel() {}",
            rootFolderPath: root.path
        )
        let failClosed = PromptPackagingService.generateFileBlocksDetailed(
            files: [codemapEntry],
            filePathDisplay: .relative,
            codemapPresentation: .empty
        )
        XCTAssertTrue(failClosed.isEmpty)

        let codemapText = "File: Canonical.swift\nfunc canonicalCodemapSymbol()"
        let presentation = try makePresentation(file: codemapRecord, text: codemapText)
        let blocks = PromptPackagingService.generateFileBlocksDetailed(
            files: [selectedEntry, codemapEntry],
            filePathDisplay: .relative,
            codemapPresentation: presentation
        )
        let packaged = blocks.map(\.text).joined(separator: "\n")

        XCTAssertEqual(blocks.map(\.isCodemap), [false, true])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(packaged.components(separatedBy: "selectedContentSentinel").count - 1, 1, packaged)
        XCTAssertEqual(packaged.components(separatedBy: "canonicalCodemapSymbol").count - 1, 1, packaged)
        XCTAssertFalse(packaged.contains("canonicalFullContentSentinel"), packaged)
    }

    func testSelectionReplyCodemapTokensUseFrozenPresentationInsteadOfStaleEntryResults() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Nested/Frozen.swift": "import Foundation\nimport Combine\nfunc frozenReplyTokenSentinel() {}\n"
            ]
        )
        defer { repositories.cleanup() }
        let codemapURL = root.appendingPathComponent("Nested/Frozen.swift")

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        _ = try await window.workspaceFileContextStore.loadRoot(path: root.path)
        let codemapLookup = await window.workspaceFileContextStore.lookupPath(codemapURL.path)
        let codemapRecord = try XCTUnwrap(codemapLookup?.file)
        let frozenPresentation = try makePresentation(
            file: codemapRecord,
            text: "File: Nested/Frozen.swift\nimport Foundation\nimport Combine\nfunc frozenReplyTokenSentinel() {}"
        )
        let selection = StoredSelection(
            selectedPaths: [codemapURL.path],
            codemapAutoEnabled: false
        )
        let source = MCPServerViewModel.StoredSelectionSource(
            stored: selection,
            codeMapUsage: .selected
        )
        let collections = await MCPServerViewModel.SelectionReplyAssembler.collect(
            from: source,
            owner: window.mcpServer,
            rootScope: .visibleWorkspace,
            contentPolicy: .cachedOnly,
            codemapPresentation: frozenPresentation
        )
        let codemapEntry = try XCTUnwrap(collections.codemap.first)
        let frozenEntry = try XCTUnwrap(
            collections.codemapPresentation.renderedEntriesByFileID[codemapEntry.file.id]
        )
        let staleResult = PromptEntriesEvaluation.EntryResult(
            fileID: codemapEntry.file.id,
            renderMode: .codemap,
            displayTokens: 1,
            fullTokens: 1,
            codemapTokens: 1
        )
        let filesReply = await MCPServerViewModel.SelectionReplyAssembler.buildSelectedFilesReply(
            collections: collections,
            formatter: MCPServerViewModel.PathFormatter(
                format: .relative,
                owner: window.mcpServer
            ),
            tokens: MCPServerViewModel.TokenServices(owner: window.mcpServer),
            entryResultsByFileID: [codemapEntry.file.id: staleResult]
        )

        XCTAssertEqual(filesReply.summary?.codemapTokens, frozenEntry.tokenCount)
        XCTAssertEqual(filesReply.totalTokens, frozenEntry.tokenCount)
        XCTAssertNotEqual(filesReply.totalTokens, staleResult.displayTokens)
    }

    func testBorrowedSelectionReplyTokenAccountingUsesFrozenPresentationNotActiveSnapshot() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Nested/Borrowed.swift": "import Foundation\nfunc borrowedFrozenTokenSentinel() {}\n"
            ]
        )
        defer { repositories.cleanup() }
        let codemapURL = root.appendingPathComponent("Nested/Borrowed.swift")

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        _ = try await window.workspaceFileContextStore.loadRoot(path: root.path)
        let codemapLookup = await window.workspaceFileContextStore.lookupPath(codemapURL.path)
        let codemapRecord = try XCTUnwrap(codemapLookup?.file)
        let frozenText = "File: Nested/Borrowed.swift\nimport Foundation\nfunc borrowedFrozenTokenSentinel() {}"
        let frozenPresentation = try makePresentation(
            file: codemapRecord,
            text: frozenText
        )
        let frozenEntry = try XCTUnwrap(frozenPresentation.renderedEntriesByFileID[codemapRecord.id])
        let selection = StoredSelection(
            manualCodemapPaths: [codemapURL.path],
            codemapAutoEnabled: false
        )

        let reply = await window.mcpServer.buildBorrowedTabSelectionReply(
            codemapPresentation: frozenPresentation,
            from: selection,
            includeBlocks: true,
            display: .relative,
            lookupContext: .visibleWorkspace
        )

        XCTAssertNotEqual(reply.tokenAccounting?.source, "active_tab_published")
        XCTAssertEqual(reply.summary?.codemapTokens, frozenEntry.tokenCount)
        XCTAssertEqual(reply.totalTokens, frozenEntry.tokenCount)
        XCTAssertEqual(reply.tokenStats?.codemaps, frozenEntry.tokenCount)
        XCTAssertTrue(reply.blocks?.contains { $0.contains("borrowedFrozenTokenSentinel") } ?? false)
    }

    private func makePresentation(
        file: WorkspaceFileRecord,
        text: String
    ) throws -> WorkspaceCodemapOperationPresentation {
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "repository",
            standardizedRelativePath: file.standardizedRelativePath
        ))
        return WorkspaceCodemapOperationPresentation(
            orderedEntries: [
                WorkspaceCodemapOperationRenderedEntry(
                    bundleID: WorkspaceCodemapFrozenPresentationBundleID(),
                    fileID: file.id,
                    rootEpoch: WorkspaceCodemapRootEpoch(
                        rootID: file.rootID,
                        rootLifetimeID: UUID()
                    ),
                    artifactKey: CodeMapArtifactKey(
                        rawSHA256: CodeMapRawSourceDigest(bytes: Data(repeating: 7, count: 32)),
                        rawByteCount: UInt64(text.utf8.count),
                        pipelineIdentity: pipeline
                    ),
                    logicalPath: logicalPath,
                    text: text,
                    tokenCount: TokenCalculationService.estimateTokens(for: text)
                )
            ],
            coverage: .complete,
            issues: [],
            publicationReceipt: nil
        )
    }
}
