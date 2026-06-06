import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

/// Characterizes the app-owned Slice 3 MCP projection behavior at checkpoint a0b968e.
@MainActor
final class MCPRenderingParityCharacterizationTests: XCTestCase {
    func testCodeStructureBudgetAlgorithmsFreezeLimitsAndOversizedFirstBehavior() {
        struct Case {
            let costs: [Int]
            let maxResults: Int
            let included: [String]
            let omittedByMaxResults: Int
            let omittedByTokenBudget: Int
        }

        let cases = [
            Case(costs: [1000, 2000], maxResults: 10, included: ["0", "1"], omittedByMaxResults: 0, omittedByTokenBudget: 0),
            Case(costs: [3000, 3000], maxResults: 10, included: ["0", "1"], omittedByMaxResults: 0, omittedByTokenBudget: 0),
            Case(costs: [3000, 3001], maxResults: 10, included: ["0"], omittedByMaxResults: 0, omittedByTokenBudget: 1),
            Case(costs: [6001, 1], maxResults: 10, included: ["0"], omittedByMaxResults: 0, omittedByTokenBudget: 1),
            Case(costs: [100, 6000, 1], maxResults: 10, included: ["0"], omittedByMaxResults: 0, omittedByTokenBudget: 2),
            Case(costs: [100, 100, 100], maxResults: 2, included: ["0", "1"], omittedByMaxResults: 1, omittedByTokenBudget: 0),
            Case(costs: [100, 100], maxResults: 0, included: [], omittedByMaxResults: 2, omittedByTokenBudget: 0),
            Case(costs: [100, 100], maxResults: -1, included: [], omittedByMaxResults: 2, omittedByTokenBudget: 0)
        ]

        for testCase in cases {
            let viewModelCandidates = testCase.costs.enumerated().map {
                MCPServerViewModel.CodeStructureBudgetCandidate(key: String($0.offset), estimatedTokens: $0.element)
            }
            let viewModelResult = MCPServerViewModel.applyCodeStructureOutputBudget(
                viewModelCandidates,
                maxResults: testCase.maxResults
            )

            let helperCandidates = testCase.costs.enumerated().map {
                MCPWindowWorkspaceToolHelpers.CodeStructureBudgetCandidate(key: String($0.offset), estimatedTokens: $0.element)
            }
            let helperResult = MCPWindowWorkspaceToolHelpers.applyCodeStructureOutputBudget(
                helperCandidates,
                maxResults: testCase.maxResults
            )

            XCTAssertEqual(viewModelResult.includedKeys, testCase.included)
            XCTAssertEqual(viewModelResult.omittedByMaxResults, testCase.omittedByMaxResults)
            XCTAssertEqual(viewModelResult.omittedByTokenBudget, testCase.omittedByTokenBudget)
            XCTAssertEqual(viewModelResult.omittedTotal, testCase.omittedByMaxResults + testCase.omittedByTokenBudget)
            XCTAssertEqual(helperResult.includedKeys, testCase.included)
            XCTAssertEqual(helperResult.omittedByMaxResults, testCase.omittedByMaxResults)
            XCTAssertEqual(helperResult.omittedByTokenBudget, testCase.omittedByTokenBudget)
            XCTAssertEqual(helperResult.omittedTotal, testCase.omittedByMaxResults + testCase.omittedByTokenBudget)
        }
    }

    func testCodeStructureDTOFreezesOrderingFullPathDedupAndOmissionCounts() async throws {
        let root = try makeTemporaryRoot(name: "CodeStructureParity")
        defer { try? FileManager.default.removeItem(at: root) }

        let alpha = root.appendingPathComponent("Alpha/A.swift")
        let zeta = root.appendingPathComponent("Zeta/B.swift")
        let missingBeta = root.appendingPathComponent("Beta/Missing.swift")
        let missingOmega = root.appendingPathComponent("Omega/Missing.swift")
        try write("func alpha() {}", to: alpha)
        try write("func zeta() {}", to: zeta)
        try write("struct MissingBeta {}", to: missingBeta)
        try write("struct MissingOmega {}", to: missingOmega)

        let window = makeWindowWithoutAutoStart()
        let store = window.workspaceFileContextStore
        let rootRecord = try await store.loadRoot(path: root.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: alpha.path, modificationDate: Date(timeIntervalSince1970: 1), fileAPI: makeFileAPI(path: alpha.path, symbolName: "symbolA")),
            WorkspaceObservedCodemapResult(fullPath: zeta.path, modificationDate: Date(timeIntervalSince1970: 2), fileAPI: makeFileAPI(path: zeta.path, symbolName: "symbolB"))
        ])

        let records = await store.files(inRoot: rootRecord.id)
        let alphaRecord = try XCTUnwrap(records.first { $0.standardizedRelativePath == "Alpha/A.swift" })
        let zetaRecord = try XCTUnwrap(records.first { $0.standardizedRelativePath == "Zeta/B.swift" })
        let missingBetaRecord = try XCTUnwrap(records.first { $0.standardizedRelativePath == "Beta/Missing.swift" })
        let missingOmegaRecord = try XCTUnwrap(records.first { $0.standardizedRelativePath == "Omega/Missing.swift" })
        let samePathDifferentID = try WorkspaceFileRecord(
            id: XCTUnwrap(UUID(uuidString: "44444444-4444-4444-4444-444444444444")),
            rootID: alphaRecord.rootID,
            name: alphaRecord.name,
            relativePath: "Alpha/../Alpha/A.swift",
            fullPath: root.appendingPathComponent("Alpha/../Alpha/A.swift").path,
            parentFolderID: alphaRecord.parentFolderID,
            modificationDate: alphaRecord.modificationDate
        )
        let unsortedWithDuplicate = [zetaRecord, missingOmegaRecord, alphaRecord, samePathDifferentID, missingBetaRecord]

        let full = await window.mcpServer.buildCodeStructureDTO(
            fromRecords: unsortedWithDuplicate,
            maxResults: 10,
            includeUnmappedPaths: true
        )

        XCTAssertEqual(full.fileCount, 2)
        XCTAssertLessThan(
            try XCTUnwrap(full.content.range(of: "File: Alpha/A.swift")?.lowerBound),
            try XCTUnwrap(full.content.range(of: "File: Zeta/B.swift")?.lowerBound)
        )
        XCTAssertEqual(occurrences(of: "symbolA", in: full.content), 1)
        XCTAssertEqual(occurrences(of: "symbolB", in: full.content), 1)
        XCTAssertEqual(full.unmappedPaths, ["Beta/Missing.swift", "Omega/Missing.swift"])
        XCTAssertNil(full.omittedCount)
        XCTAssertNil(full.omittedTotal)
        XCTAssertNil(full.tokenBudgetOmittedCount)
        XCTAssertNil(full.tokenBudgetHit)

        let limited = await window.mcpServer.buildCodeStructureDTO(
            fromRecords: unsortedWithDuplicate,
            maxResults: 1,
            includeUnmappedPaths: true
        )

        XCTAssertEqual(limited.fileCount, 1)
        XCTAssertTrue(limited.content.contains("symbolA"))
        XCTAssertFalse(limited.content.contains("symbolB"))
        XCTAssertEqual(limited.unmappedPaths, ["Beta/Missing.swift", "Omega/Missing.swift"])
        XCTAssertEqual(limited.omittedCount, 1)
        XCTAssertEqual(limited.omittedTotal, 1)
        XCTAssertNil(limited.tokenBudgetOmittedCount)
        XCTAssertNil(limited.tokenBudgetHit)
    }

    func testSelectionAndAlternateCopyPresetTokenProjectionsRemainFrozen() async throws {
        let root = try makeTemporaryRoot(name: "SelectionParity")
        defer { try? FileManager.default.removeItem(at: root) }

        let fullURL = root.appendingPathComponent("Sources/Full.swift")
        let slicedURL = root.appendingPathComponent("Sources/Sliced.swift")
        let codemapURL = root.appendingPathComponent("Sources/Auto.swift")
        try write("full content", to: fullURL)
        try write("one\ntwo\nthree", to: slicedURL)
        try write("func autoSource() {}", to: codemapURL)

        let window = makeWindowWithoutAutoStart()
        let store = window.workspaceFileContextStore
        _ = try await store.loadRoot(path: root.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(fullPath: fullURL.path, modificationDate: Date(timeIntervalSince1970: 1), fileAPI: makeFileAPI(path: fullURL.path, symbolName: "fullAPI")),
            WorkspaceObservedCodemapResult(fullPath: slicedURL.path, modificationDate: Date(timeIntervalSince1970: 2), fileAPI: makeFileAPI(path: slicedURL.path, symbolName: "sliceAPI")),
            WorkspaceObservedCodemapResult(fullPath: codemapURL.path, modificationDate: Date(timeIntervalSince1970: 3), fileAPI: makeFileAPI(path: codemapURL.path, symbolName: "autoAPI"))
        ])

        let range = LineRange(start: 2, end: 2, description: "middle")
        let source = MCPServerViewModel.StoredSelectionSource(
            stored: StoredSelection(
                selectedPaths: [fullURL.path, slicedURL.path],
                autoCodemapPaths: [codemapURL.path],
                slices: [slicedURL.path: [range]],
                codemapAutoEnabled: true
            ),
            codeMapUsage: .auto
        )
        let collections = await MCPServerViewModel.SelectionReplyAssembler.collect(from: source, owner: window.mcpServer)
        XCTAssertEqual(collections.selected.map(\.file.standardizedRelativePath), ["Sources/Full.swift", "Sources/Sliced.swift"])
        XCTAssertEqual(collections.selected.map(\.ranges), [nil, [range]])
        XCTAssertEqual(collections.codemap.map(\.file.standardizedRelativePath), ["Sources/Auto.swift"])
        XCTAssertEqual(collections.codemap.map(\.origin), [.auto])
        XCTAssertTrue(collections.codemapAutoEnabled)
        XCTAssertEqual(collections.codeMapUsage, .auto)
        XCTAssertEqual(collections.invalid, [])

        let full = try XCTUnwrap(collections.selected.first { $0.file.standardizedRelativePath == "Sources/Full.swift" }?.entry)
        let sliced = try XCTUnwrap(collections.selected.first { $0.file.standardizedRelativePath == "Sources/Sliced.swift" }?.entry)
        let codemap = try XCTUnwrap(collections.codemap.first?.entry)
        let entryResults: [UUID: PromptEntriesEvaluation.EntryResult] = [
            full.file.id: .init(fileID: full.file.id, renderMode: .full, displayTokens: 100, fullTokens: 100, codemapTokens: 10),
            sliced.file.id: .init(fileID: sliced.file.id, renderMode: .slice, displayTokens: 20, fullTokens: 200, codemapTokens: 11),
            codemap.file.id: .init(fileID: codemap.file.id, renderMode: .codemap, displayTokens: 12, fullTokens: 300, codemapTokens: 12)
        ]
        let formatter = MCPServerViewModel.PathFormatter(format: .full, owner: window.mcpServer)
        let tokenServices = MCPServerViewModel.TokenServices(owner: window.mcpServer)

        let selected = await makeSelectionReply(
            collections: collections,
            formatter: formatter,
            tokenServices: tokenServices,
            copyUsage: .selected,
            includeFiles: true,
            entryResults: entryResults
        )
        XCTAssertEqual(selected.files.map(\.path), [full.file.fullPath, sliced.file.fullPath, codemap.file.fullPath])
        XCTAssertEqual(selected.files.map(\.renderMode), ["full", "slice", "codemap"])
        XCTAssertEqual(selected.files.map(\.tokens), [100, 20, 12])
        XCTAssertEqual(selected.files.map(\.isAuto), [false, false, true])
        XCTAssertEqual(selected.totalTokens, 132)
        XCTAssertEqual(selected.summary, .init(fullCount: 1, sliceCount: 1, codemapCount: 1, fullTokens: 100, sliceTokens: 20, codemapTokens: 12))
        XCTAssertEqual(selected.fileSlices?.map(\.path), [sliced.file.fullPath])
        XCTAssertEqual(selected.files.map(\.copyPreset?.renderMode), ["codemap", "codemap", "hidden"])
        XCTAssertEqual(selected.files.map(\.copyPreset?.tokens), [10, 11, 0])
        XCTAssertEqual(selected.files.map(\.copyPreset?.codemapOrigin), ["selected_mode", "selected_mode", nil])
        XCTAssertEqual(selected.userCopyTokens, 21)
        XCTAssertEqual(selected.userCopyContentTokens, 0)
        XCTAssertEqual(selected.userCopyCodemapTokens, 21)
        XCTAssertEqual(selected.copyPresetProjection, .init(codeMapUsage: "selected", includesFiles: true, totalTokens: 21))

        let complete = await makeSelectionReply(
            collections: collections,
            formatter: formatter,
            tokenServices: tokenServices,
            copyUsage: .complete,
            includeFiles: true,
            entryResults: entryResults
        )
        XCTAssertEqual(complete.files.map(\.copyPreset?.tokens), [10, 11, nil])
        XCTAssertEqual(complete.userCopyTokens, 33)
        XCTAssertEqual(complete.userCopyContentTokens, 0)
        XCTAssertEqual(complete.userCopyCodemapTokens, 33)
        XCTAssertEqual(complete.copyPresetProjection, .init(codeMapUsage: "complete", includesFiles: true, totalTokens: 33))

        let none = await makeSelectionReply(
            collections: collections,
            formatter: formatter,
            tokenServices: tokenServices,
            copyUsage: .none,
            includeFiles: true,
            entryResults: entryResults
        )
        XCTAssertEqual(none.files.map(\.copyPreset?.renderMode), [nil, nil, "hidden"])
        XCTAssertEqual(none.userCopyTokens, 120)
        XCTAssertEqual(none.userCopyContentTokens, 120)
        XCTAssertEqual(none.userCopyCodemapTokens, 0)
        XCTAssertEqual(none.copyPresetProjection, .init(codeMapUsage: "none", includesFiles: true, totalTokens: 120))

        let selectedWithoutFiles = await makeSelectionReply(
            collections: collections,
            formatter: formatter,
            tokenServices: tokenServices,
            copyUsage: .selected,
            includeFiles: false,
            entryResults: entryResults
        )
        XCTAssertEqual(selectedWithoutFiles.copyPresetProjection, .init(codeMapUsage: "selected", includesFiles: false, totalTokens: 12))

        let noneWithoutFiles = await makeSelectionReply(
            collections: collections,
            formatter: formatter,
            tokenServices: tokenServices,
            copyUsage: .none,
            includeFiles: false,
            entryResults: entryResults
        )
        XCTAssertEqual(noneWithoutFiles.copyPresetProjection, .init(codeMapUsage: "none", includesFiles: false, totalTokens: 0))

        XCTAssertNil(MCPServerViewModel.SelectionReplyAssembler.computeCopyPresetProjection(
            autoRenderMode: "full",
            autoTokens: 100,
            hasCodemap: true,
            copyUsage: .auto,
            codemapTokens: 10
        ))
        XCTAssertNil(MCPServerViewModel.SelectionReplyAssembler.computeCopyPresetProjection(
            autoRenderMode: "slice",
            autoTokens: 20,
            hasCodemap: false,
            copyUsage: .selected,
            codemapTokens: 0
        ))
        XCTAssertEqual(
            MCPServerViewModel.SelectionReplyAssembler.computeCopyPresetProjection(
                autoRenderMode: "codemap",
                autoTokens: 12,
                hasCodemap: true,
                copyUsage: .none,
                codemapTokens: 12
            ),
            .init(tokens: 0, renderMode: "hidden", ranges: nil, codemapOrigin: nil)
        )
    }

    func testWorkspaceContextIncludeSetsFreezeEmptyComponentsAndAppEnvelope() async throws {
        let previousCodeMapsDisabled = GlobalSettingsStore.shared.globalCodeMapsDisabled()
        GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(false, commit: false)
        defer { GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(previousCodeMapsDisabled, commit: false) }

        let window = makeWindowWithoutAutoStart()
        let override = try CopyPreset(
            id: XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")),
            name: "Parity Override",
            includeFiles: true,
            includeUserPrompt: false,
            includeMetaPrompts: false,
            includeFileTree: false,
            fileTreeMode: FileTreeOption.none,
            codeMapUsage: CodeMapUsage.none,
            gitInclusion: GitInclusion.none
        )
        let context = try MCPServerViewModel.TabContextSnapshot(
            tabID: XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
            windowID: window.windowID,
            workspaceID: nil,
            promptText: "Frozen prompt",
            selection: StoredSelection(),
            selectedMetaPromptIDs: [],
            tabName: "Parity",
            runID: nil,
            explicitlyBound: true
        )

        let empty = await window.mcpServer.buildTabWorkspaceContext(
            context: context,
            include: [],
            display: .relative,
            copyPresetOverride: override
        )
        XCTAssertEqual(empty.prompt, "")
        XCTAssertNil(empty.selection)
        XCTAssertNil(empty.fileBlocks)
        XCTAssertNil(empty.codeStructure)
        XCTAssertNil(empty.fileTree)
        XCTAssertNil(empty.tokenStats)
        XCTAssertNil(empty.userTokenStats)
        XCTAssertNil(empty.tokenStatsNote)
        XCTAssertNil(empty.copyPresets)
        XCTAssertNil(empty.worktreeScope)
        XCTAssertEqual(empty.copyPreset?.effective.id, override.id.uuidString)
        XCTAssertEqual(empty.copyPreset?.effective.name, override.name)
        XCTAssertEqual(empty.copyPreset?.isOverridden, empty.copyPreset?.active.id != override.id.uuidString)

        let promptOnly = await window.mcpServer.buildTabWorkspaceContext(
            context: context,
            include: ["prompt"],
            display: .relative,
            copyPresetOverride: override
        )
        XCTAssertEqual(promptOnly.prompt, "Frozen prompt")
        XCTAssertNil(promptOnly.selection)
        XCTAssertNil(promptOnly.fileBlocks)
        XCTAssertNil(promptOnly.codeStructure)

        let filesOnly = await window.mcpServer.buildTabWorkspaceContext(
            context: context,
            include: ["files"],
            display: .relative,
            copyPresetOverride: override
        )
        XCTAssertEqual(filesOnly.prompt, "")
        XCTAssertNil(filesOnly.selection)
        XCTAssertEqual(filesOnly.fileBlocks, [])
        XCTAssertNil(filesOnly.codeStructure)

        let selectionAndCode = await window.mcpServer.buildTabWorkspaceContext(
            context: context,
            include: ["selection", "code"],
            display: .relative,
            copyPresetOverride: override
        )
        XCTAssertEqual(selectionAndCode.prompt, "")
        XCTAssertEqual(selectionAndCode.selection?.files, [])
        XCTAssertEqual(selectionAndCode.selection?.totalTokens, 0)
        XCTAssertEqual(selectionAndCode.selection?.summary, .init(fullCount: 0, sliceCount: 0, codemapCount: 0, fullTokens: 0, sliceTokens: 0, codemapTokens: 0))
        XCTAssertNil(selectionAndCode.fileBlocks)
        XCTAssertNil(selectionAndCode.codeStructure)
        XCTAssertEqual(selectionAndCode.copyPreset?.effective.id, override.id.uuidString)

        let tokensOnly = await window.mcpServer.buildTabWorkspaceContext(
            context: context,
            include: ["tokens"],
            display: .relative,
            copyPresetOverride: override
        )
        XCTAssertEqual(tokensOnly.prompt, "")
        XCTAssertNil(tokensOnly.selection)
        XCTAssertNil(tokensOnly.fileBlocks)
        XCTAssertNil(tokensOnly.codeStructure)
        XCTAssertEqual(tokensOnly.tokenStats, .init(total: 0, files: 0))
        XCTAssertNil(tokensOnly.userTokenStats)
        XCTAssertNil(tokensOnly.tokenStatsNote)
        XCTAssertEqual(tokensOnly.copyPreset?.effective.id, override.id.uuidString)
    }

    func testMCPDTOJSONFreezesNilZeroEmptyAndDistinctPromptEnvelopes() throws {
        let zeroStats = MCPServerViewModel.makeTokenStats(
            filesTokens: 0,
            breakdown: .init(prompt: 0, duplicatePrompt: 0, instructions: 0, fileTree: 0, gitDiff: 0, metadata: 0)
        )
        XCTAssertEqual(try json(zeroStats), #"{"files":0,"total":0}"#)

        let emptyCode = ToolResultDTOs.SelectedCodeStructureDTO(fileCount: 0, content: "", unmappedPaths: [])
        XCTAssertEqual(try json(emptyCode), #"{"content":"","file_count":0,"unmapped_paths":[]}"#)

        let emptySelection = ToolResultDTOs.SelectedFilesReply(
            files: [],
            totalTokens: 0,
            fileSlices: nil,
            summary: .init(fullCount: 0, sliceCount: 0, codemapCount: 0, fullTokens: 0, sliceTokens: 0, codemapTokens: 0)
        )
        XCTAssertEqual(
            try json(emptySelection),
            #"{"files":[],"summary":{"codemap_count":0,"codemap_tokens":0,"full_count":0,"full_tokens":0,"slice_count":0,"slice_tokens":0},"total_tokens":0}"#
        )

        let reply = ToolResultDTOs.SelectionReply(
            files: nil,
            totalTokens: nil,
            status: "",
            invalidPaths: [],
            blocks: [],
            codemapAutoEnabled: false
        )
        XCTAssertEqual(try json(reply), #"{"blocks":[],"codemap_auto_enabled":false,"invalid_paths":[],"status":""}"#)

        let context = ToolResultDTOs.PromptContextDTO(
            prompt: "",
            selection: nil,
            fileBlocks: [],
            codeStructure: nil,
            fileTree: nil,
            tokenStats: nil,
            userTokenStats: nil,
            tokenStatsNote: nil,
            copyPreset: nil,
            copyPresets: []
        )
        XCTAssertEqual(try json(context), #"{"copy_presets":[],"file_blocks":[],"prompt":""}"#)

        let descriptor = ToolResultDTOs.CopyPresetDescriptorDTO(id: "", name: "", kind: nil, isBuiltIn: false)
        let prompt = ToolResultDTOs.PromptReply(
            prompt: "",
            lines: 0,
            copyPresetName: nil,
            chatPresetName: nil,
            chatMode: nil,
            includesFiles: nil,
            includesFileTree: nil,
            includesCodemaps: nil,
            includesGitDiff: nil,
            includesUserPrompt: nil,
            includesMetaPrompts: nil,
            includesStoredPrompts: nil,
            fileTreeMode: nil,
            codeMapUsage: nil,
            gitInclusion: nil,
            effectiveTokens: nil,
            fullFilesTokens: nil,
            codeMapFileCount: nil,
            codeMapTokens: nil,
            codeMapFiles: nil
        )
        let export = ToolResultDTOs.PromptExportReply(path: "", tokens: 0, bytes: 0, files: [], copyPreset: nil)

        XCTAssertEqual(
            try json(ToolResultDTOs.PromptToolEnvelope.forPrompt(prompt, op: "get")),
            #"{"op":"get","prompt":{"lines":0,"prompt":""}}"#
        )
        XCTAssertEqual(
            try json(ToolResultDTOs.PromptToolEnvelope.forExport(export)),
            #"{"export":{"bytes":0,"files":[],"path":"","tokens":0},"op":"export"}"#
        )
        XCTAssertEqual(
            try json(ToolResultDTOs.PromptToolEnvelope.forPresetsList([])),
            #"{"op":"list_presets","presets_list":{"presets":[]}}"#
        )
        XCTAssertEqual(
            try json(ToolResultDTOs.PromptToolEnvelope.forSelectPreset(descriptor)),
            #"{"op":"select_preset","selected_preset":{"id":"","is_built_in":false,"name":""}}"#
        )
    }

    private func makeSelectionReply(
        collections: MCPServerViewModel.SelectionReplyAssembler.SelectionCollections,
        formatter: MCPServerViewModel.PathFormatter,
        tokenServices: MCPServerViewModel.TokenServices,
        copyUsage: CodeMapUsage,
        includeFiles: Bool,
        entryResults: [UUID: PromptEntriesEvaluation.EntryResult]
    ) async -> ToolResultDTOs.SelectedFilesReply {
        await MCPServerViewModel.SelectionReplyAssembler.buildSelectedFilesReply(
            collections: collections,
            formatter: formatter,
            tokens: tokenServices,
            userPresetState: .init(
                copyCodeMapUsage: copyUsage.rawValue,
                chatCodeMapUsage: CodeMapUsage.auto.rawValue,
                copyTokens: nil,
                chatTokens: nil,
                normalizedCodeMapUsage: CodeMapUsage.auto.rawValue
            ),
            copyUsage: copyUsage,
            projection: .init(includeFiles: includeFiles, codeMapUsage: copyUsage),
            entryResultsByFileID: entryResults
        )
    }

    private func makeFileAPI(path: String, symbolName: String) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: [],
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

    private func makeWindowWithoutAutoStart() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        return WindowState()
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try XCTUnwrap(String(data: encoder.encode(value), encoding: .utf8))
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
