import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class MCPSelectionContentPackagingTests: XCTestCase {
    func testContentViewIncludesCanonicalCodemapBlocksExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("MCPSelectionContentPackaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let selectedURL = root.appendingPathComponent("Selected.swift")
        let codemapURL = root.appendingPathComponent("Canonical.swift")
        try "let selectedContentSentinel = true\n".write(to: selectedURL, atomically: true, encoding: .utf8)
        try "func canonicalFullContentSentinel() {}\n".write(to: codemapURL, atomically: true, encoding: .utf8)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        let previousCodeMapsDisabled = GlobalSettingsStore.shared.globalCodeMapsDisabled()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        defer {
            WindowStatesManager.shared.unregisterWindowState(window)
            GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(previousCodeMapsDisabled, commit: false)
        }

        _ = try await window.workspaceFileContextStore.loadRoot(path: root.path)
        let selection = StoredSelection(
            selectedPaths: [selectedURL.path],
            autoCodemapPaths: [codemapURL.path],
            codemapAutoEnabled: true
        )
        let missingSnapshotReply = await window.mcpServer.buildSelectionPreviewReply(
            selection: selection,
            includeBlocks: true,
            display: .relative,
            extraInvalid: [],
            viewMode: nil,
            codeMapUsageOverride: .auto
        )
        let missingSnapshotBlocks = try XCTUnwrap(missingSnapshotReply.blocks)
        let missingSnapshotPackaged = missingSnapshotBlocks.joined(separator: "\n")
        XCTAssertEqual(missingSnapshotReply.files?.map(\.renderMode), ["full"])
        XCTAssertEqual(missingSnapshotReply.summary?.codemapCount, 0)
        XCTAssertEqual(missingSnapshotBlocks.count, 1)
        XCTAssertFalse(missingSnapshotPackaged.contains("canonicalFullContentSentinel"), missingSnapshotPackaged)

        let codemapLookup = await window.workspaceFileContextStore.lookupPath(codemapURL.path)
        let codemapRecord = try XCTUnwrap(codemapLookup?.file)
        let malformedCodemapEntry = ResolvedPromptFileEntry(
            file: codemapRecord,
            isCodemap: true,
            mode: .codemap,
            loadedContent: "canonicalFullContentSentinel",
            rootFolderPath: root.path
        )
        let failClosedBlocks = PromptPackagingService.generateFileBlocksDetailed(
            files: [malformedCodemapEntry],
            filePathDisplay: .relative,
            codemapSnapshotBundle: .empty
        )
        XCTAssertTrue(failClosedBlocks.isEmpty)

        await window.workspaceFileContextStore.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: codemapURL.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(path: codemapURL.path, symbolName: "canonicalCodemapSymbol")
            )
        ])

        let reply = await window.mcpServer.buildSelectionPreviewReply(
            selection: selection,
            includeBlocks: true,
            display: .relative,
            extraInvalid: [],
            viewMode: nil,
            codeMapUsageOverride: .auto
        )
        let blocks = try XCTUnwrap(reply.blocks)
        let packaged = blocks.joined(separator: "\n")

        XCTAssertEqual(reply.files?.map(\.renderMode), ["full", "codemap"])
        XCTAssertEqual(reply.summary?.codemapCount, 1)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(packaged.components(separatedBy: "selectedContentSentinel").count - 1, 1, packaged)
        XCTAssertEqual(packaged.components(separatedBy: "canonicalCodemapSymbol").count - 1, 1, packaged)
        XCTAssertFalse(packaged.contains("canonicalFullContentSentinel"), packaged)
    }

    func testSelectionReplyCodemapTokensUseFrozenBundleInsteadOfStaleEntryResults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("MCPSelectionFrozenTokens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let codemapURL = root.appendingPathComponent("Nested/Frozen.swift")
        try FileManager.default.createDirectory(at: codemapURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "func fullContentMustNotAffectTokens() {}\n".write(to: codemapURL, atomically: true, encoding: .utf8)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        _ = try await window.workspaceFileContextStore.loadRoot(path: root.path)
        let api = makeFileAPI(
            path: codemapURL.path,
            symbolName: "frozenReplyTokenSentinel",
            imports: ["Foundation", "Combine"]
        )
        await window.workspaceFileContextStore.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: codemapURL.path,
                modificationDate: Date(),
                fileAPI: api
            )
        ])
        let selection = StoredSelection(
            autoCodemapPaths: [codemapURL.path],
            codemapAutoEnabled: true
        )
        let frozenBundle = await window.workspaceFileContextStore.codemapSnapshotBundle(
            rootScope: .visibleWorkspace
        )
        let source = MCPServerViewModel.StoredSelectionSource(
            stored: selection,
            codeMapUsage: .auto
        )
        let collections = await MCPServerViewModel.SelectionReplyAssembler.collect(
            from: source,
            owner: window.mcpServer,
            rootScope: .visibleWorkspace,
            codemapSnapshotBundle: frozenBundle,
            contentPolicy: .cachedOnly
        )
        let codemapEntry = try XCTUnwrap(collections.codemap.first)
        await window.workspaceFileContextStore.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: codemapURL.path,
                modificationDate: Date(),
                fileAPI: nil
            )
        ])
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

        let expectedText = api.getFullAPIDescription(displayPath: "Nested/Frozen.swift")
        let expectedTokens = TokenCalculationService.estimateTokens(for: expectedText)
        XCTAssertEqual(filesReply.summary?.codemapTokens, expectedTokens)
        XCTAssertEqual(filesReply.totalTokens, expectedTokens)
        XCTAssertNotEqual(filesReply.totalTokens, staleResult.displayTokens)
    }

    private func makeFileAPI(
        path: String,
        symbolName: String,
        imports: [String] = []
    ) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: imports,
            classes: [],
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
            referencedTypes: []
        )
    }
}
