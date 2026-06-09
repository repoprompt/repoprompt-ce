import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

final class PromptRenderingParityCharacterizationTests: XCTestCase {
    private let rootID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let rootPath = "/workspace/Alpha"
    private let modificationDate = Date(timeIntervalSince1970: 1000)

    func testPromptSectionIdentityAndDefaultOrderRemainFrozen() {
        XCTAssertEqual(PromptSection.allCases.map(\.rawValue), [
            "fileMap",
            "fileContents",
            "metaPrompts",
            "userInstructions",
            "gitDiff"
        ])
        XCTAssertEqual(PromptAssemblyBuilder.defaultSectionOrder, [
            .fileMap,
            .fileContents,
            .gitDiff,
            .metaPrompts,
            .userInstructions
        ])
    }

    func testPromptAssemblyFreezesDisabledSectionsSeparatorsTrailingNewlinesAndDuplicateUserPromptBehavior() {
        let order: [PromptSection] = [.metaPrompts, .fileContents, .userInstructions, .fileMap, .gitDiff]
        let snippets: [PromptSection: String] = [
            .fileMap: "MAP",
            .fileContents: "FILES\n\n",
            .metaPrompts: "META\n",
            .userInstructions: "USER\n\n",
            .gitDiff: ""
        ]

        XCTAssertEqual(
            PromptAssemblyBuilder.build(
                order: order,
                disabled: [.fileContents, .userInstructions],
                duplicateUserInstructionsAtTop: false,
                snippets: snippets
            ),
            "META\nMAP\n"
        )
        XCTAssertEqual(
            PromptAssemblyBuilder.build(
                order: order,
                disabled: [.fileContents, .userInstructions],
                duplicateUserInstructionsAtTop: true,
                snippets: snippets
            ),
            "USER\n\nMETA\nMAP\n"
        )
        XCTAssertEqual(
            PromptAssemblyBuilder.build(
                order: order,
                disabled: [.fileContents],
                duplicateUserInstructionsAtTop: true,
                snippets: snippets
            ),
            "USER\n\nMETA\nUSER\n\nMAP\n"
        )
    }

    func testResolvedEntryRenderingFreezesFullSliceCodemapAndMissingCodemapFallbackOrdering() {
        let full = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            relativePath: "Sources/Full.swift",
            content: "struct Full {}\n"
        )
        let sliced = makeEntry(
            id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            relativePath: "Sources/Sliced.swift",
            content: "one\ntwo\nthree\nfour\n",
            isCodemap: false,
            ranges: [
                LineRange(start: 3, end: 3, description: "third"),
                LineRange(start: 1, end: 1)
            ]
        )
        let codemap = makeEntry(
            id: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            relativePath: "Sources/Structure.swift",
            content: nil,
            isCodemap: true
        )
        let missingCodemap = makeEntry(
            id: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",
            relativePath: "Sources/MissingCodemap.swift",
            content: "struct MissingCodemapFallback {}\n",
            isCodemap: true
        )
        let codemapSnapshot = makeCodemapSnapshot(for: codemap)

        let records = PromptPackagingService.generateFileBlocksDetailed(
            files: [full, codemap, sliced, missingCodemap],
            filePathDisplay: .full,
            codemapSnapshots: [codemap.file.id: codemapSnapshot]
        )

        let expectedFull = "File: /workspace/Alpha/Sources/Full.swift\n```swift\nstruct Full {}\n\n```"
        let expectedCodemap = "File: /workspace/Alpha/Sources/Structure.swift\nImports:\n---\n\nFunctions:\n  - L7: func codemapOnlySymbol()\n---\n"
        let expectedSlice = "File: /workspace/Alpha/Sources/Sliced.swift\n(lines 1)\n```swift\none\n\n```\n\n(lines 3: third)\n```swift\nthree\n\n```"
        let expectedMissingCodemap = "File: /workspace/Alpha/Sources/MissingCodemap.swift\n```swift\nstruct MissingCodemapFallback {}\n\n```"

        XCTAssertEqual(records.map(\.file.relativePath), [
            "Sources/Full.swift",
            "Sources/Structure.swift",
            "Sources/Sliced.swift",
            "Sources/MissingCodemap.swift"
        ])
        XCTAssertEqual(records.map(\.isCodemap), [false, true, false, false])
        XCTAssertEqual(records.map(\.text), [
            expectedFull,
            expectedCodemap,
            expectedSlice,
            expectedMissingCodemap
        ])

        let partitioned = PromptPackagingService.generatePartitionedFileBlocks(
            [full, codemap, sliced, missingCodemap],
            filePathDisplay: .full,
            codemapSnapshots: [codemap.file.id: codemapSnapshot]
        )
        XCTAssertEqual(partitioned.codemapBlocks, [expectedCodemap])
        XCTAssertEqual(partitioned.contentBlocks, [expectedFull, expectedSlice, expectedMissingCodemap])
        XCTAssertEqual(occurrences(of: "codemapOnlySymbol", in: partitioned.codemapBlocks.joined()), 1)
        XCTAssertEqual(occurrences(of: "codemapOnlySymbol", in: partitioned.contentBlocks.joined()), 0)
        XCTAssertEqual(occurrences(of: "MissingCodemapFallback", in: partitioned.codemapBlocks.joined()), 0)
        XCTAssertEqual(occurrences(of: "MissingCodemapFallback", in: partitioned.contentBlocks.joined()), 1)
    }

    func testResolvedAdapterPreservesMultiRootLabelsResolverPrecedenceAndOmittedEntryIdentity() throws {
        let betaRootID = try XCTUnwrap(UUID(uuidString: "99999999-9999-9999-9999-999999999999"))
        let alpha = makeEntry(
            id: "22222222-2222-2222-2222-222222222222",
            relativePath: "Sources/Alpha.swift",
            content: "struct Alpha {}\n"
        )
        let omitted = makeEntry(
            id: "33333333-3333-3333-3333-333333333333",
            relativePath: "Sources/Omitted.swift",
            content: nil
        )
        let beta = makeEntry(
            id: "44444444-4444-4444-4444-444444444444",
            relativePath: "Sources/Beta.swift",
            content: "struct Beta {}\n",
            rootID: betaRootID,
            rootPath: "/workspace/Beta"
        )

        let records = PromptPackagingService.generateFileBlocksDetailed(
            files: [alpha, omitted, beta],
            filePathDisplay: .relative,
            displayPathResolver: { entry in
                entry.file.id == beta.file.id ? "override/Beta.swift" : nil
            }
        )

        XCTAssertEqual(records.map(\.file.relativePath), ["Sources/Alpha.swift", "Sources/Beta.swift"])
        XCTAssertEqual(records.map(\.text), [
            "File: Alpha/Sources/Alpha.swift\n```swift\nstruct Alpha {}\n\n```",
            "File: override/Beta.swift\n```swift\nstruct Beta {}\n\n```"
        ])

        let coreBlocks = PromptRenderingService.renderFileBlocks([
            PromptRenderingFileValue(
                displayPath: "Alpha/Sources/Alpha.swift",
                fileName: alpha.file.name,
                content: alpha.loadedContent
            ),
            PromptRenderingFileValue(
                displayPath: "Sources/Omitted.swift",
                fileName: omitted.file.name,
                content: omitted.loadedContent
            ),
            PromptRenderingFileValue(
                displayPath: "override/Beta.swift",
                fileName: beta.file.name,
                content: beta.loadedContent
            )
        ])
        XCTAssertEqual(records.map(\.text), coreBlocks.map(\.text))
    }

    @MainActor
    func testPromptFileEntryAdapterPreservesAsyncSlicesMultiRootLabelsAndCodemapProjection() async {
        let alpha = makeFileViewModel(
            rootPath: "/workspace/Alpha",
            relativePath: "Sources/Alpha.swift",
            content: "one\ntwo\nthree\n"
        )
        let beta = makeFileViewModel(
            rootPath: "/workspace/Beta",
            relativePath: "Sources/Beta.swift",
            content: "struct BetaFullContentMustNotRender {}\n"
        )
        beta.setCodeMap(makeFileAPI(path: beta.fullPath, symbol: "betaCodemapSymbol"))

        let records = await PromptPackagingService.generateFileBlocksDetailed(
            files: [
                PromptFileEntry(
                    file: alpha,
                    isCodemap: false,
                    ranges: [LineRange(start: 2, end: 2, description: "middle")]
                ),
                PromptFileEntry(file: beta, isCodemap: true, ranges: nil)
            ],
            filePathDisplay: .relative
        )

        XCTAssertEqual(records.map(\.file.id), [alpha.id, beta.id])
        XCTAssertEqual(records.map(\.isCodemap), [false, true])
        XCTAssertEqual(
            records[0].text,
            "File: Alpha/Sources/Alpha.swift\n(lines 2: middle)\n```swift\ntwo\n\n```"
        )
        XCTAssertTrue(records[1].text.contains("File: Beta/Sources/Beta.swift"), records[1].text)
        XCTAssertTrue(records[1].text.contains("betaCodemapSymbol"), records[1].text)
        XCTAssertFalse(records[1].text.contains("BetaFullContentMustNotRender"), records[1].text)
    }

    func testResolvedClipboardPackagingFreezesDiffArtifactOrderingAndNonDuplication() async {
        let full = makeEntry(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            relativePath: "Sources/Full.swift",
            content: "struct Full {}\n"
        )
        let diffOne = makeEntry(
            id: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
            relativePath: "_git_data/repos/demo/2026-06-05/diff/first.patch",
            content: "PATCH-ONE"
        )
        let codemap = makeEntry(
            id: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            relativePath: "Sources/Structure.swift",
            content: nil,
            isCodemap: true
        )
        let sliced = makeEntry(
            id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            relativePath: "Sources/Sliced.swift",
            content: "one\ntwo\nthree\nfour\n",
            ranges: [
                LineRange(start: 3, end: 3, description: "third"),
                LineRange(start: 1, end: 1)
            ]
        )
        let diffTwo = makeEntry(
            id: "11111111-1111-1111-1111-111111111111",
            relativePath: "_git_data/repos/demo/2026-06-05/diffs/second.DIFF",
            content: "PATCH-TWO"
        )
        let missingCodemap = makeEntry(
            id: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",
            relativePath: "Sources/MissingCodemap.swift",
            content: "struct MissingCodemapFallback {}\n",
            isCodemap: true
        )
        let entries = [full, diffOne, codemap, sliced, diffTwo, missingCodemap]
        let codemapSnapshot = makeCodemapSnapshot(for: codemap)

        let partitioned = PromptPackagingService.partitionPromptEntriesForGitDiff(entries)
        XCTAssertEqual(partitioned.diffEntries.map(\.file.relativePath), [
            "_git_data/repos/demo/2026-06-05/diff/first.patch",
            "_git_data/repos/demo/2026-06-05/diffs/second.DIFF"
        ])
        XCTAssertEqual(partitioned.codeEntries.map(\.file.relativePath), [
            "Sources/Full.swift",
            "Sources/Structure.swift",
            "Sources/Sliced.swift",
            "Sources/MissingCodemap.swift"
        ])
        XCTAssertEqual(PromptPackagingService.selectedGitDiffText(fromDiffEntries: partitioned.diffEntries), "PATCH-ONE\n\nPATCH-TWO")
        let resolvedDiff = await PromptPackagingService.resolveGitDiff(fromDiffEntries: partitioned.diffEntries) {
            "GENERATED-FALLBACK"
        }
        XCTAssertEqual(resolvedDiff, "PATCH-ONE\n\nPATCH-TWO")

        let content = await PromptPackagingService.generateClipboardContent(
            metaInstructions: [],
            userInstructions: "Ship it",
            files: entries,
            fileTreeContent: "ROOT TREE",
            gitDiff: "GENERATED-FALLBACK",
            includeSavedPrompts: true,
            includeFiles: true,
            includeUserPrompt: true,
            filePathDisplay: .full,
            codemapSnapshots: [codemap.file.id: codemapSnapshot],
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            duplicateUserInstructionsAtTop: false
        )

        let expectedFull = "File: /workspace/Alpha/Sources/Full.swift\n```swift\nstruct Full {}\n\n```"
        let expectedCodemap = "File: /workspace/Alpha/Sources/Structure.swift\nImports:\n---\n\nFunctions:\n  - L7: func codemapOnlySymbol()\n---\n"
        let expectedSlice = "File: /workspace/Alpha/Sources/Sliced.swift\n(lines 1)\n```swift\none\n\n```\n\n(lines 3: third)\n```swift\nthree\n\n```"
        let expectedMissingCodemap = "File: /workspace/Alpha/Sources/MissingCodemap.swift\n```swift\nstruct MissingCodemapFallback {}\n\n```"
        let expected = "<file_map>\nROOT TREE\n\n\(expectedCodemap)\n</file_map>\n"
            + "<file_contents>\n\(expectedFull)\n\n\(expectedSlice)\n\n\(expectedMissingCodemap)\n</file_contents>\n"
            + "<git_diff>\nPATCH-ONE\n\nPATCH-TWO\n</git_diff>\n"
            + "<user_instructions>\nShip it\n</user_instructions>\n"

        XCTAssertEqual(content, expected)
        XCTAssertEqual(occurrences(of: "codemapOnlySymbol", in: content), 1)
        XCTAssertEqual(occurrences(of: "struct Full", in: content), 1)
        XCTAssertEqual(occurrences(of: "MissingCodemapFallback", in: content), 1)
        XCTAssertEqual(occurrences(of: "PATCH-ONE", in: content), 1)
        XCTAssertEqual(occurrences(of: "PATCH-TWO", in: content), 1)
        XCTAssertEqual(occurrences(of: "GENERATED-FALLBACK", in: content), 0)
        XCTAssertEqual(occurrences(of: "_git_data/", in: content), 0)

        let exactPayload = PromptPackagingService.exactRenderedPayload(content, source: .immutableSnapshot)
        XCTAssertEqual(exactPayload.text, expected)
        XCTAssertEqual(exactPayload.projection.provenance.view, .userConfigured)
        XCTAssertEqual(exactPayload.projection.provenance.scope, .export)
        XCTAssertEqual(exactPayload.projection.provenance.source, .immutableSnapshot)
        XCTAssertEqual(exactPayload.projection.provenance.basis, .exactRenderedPayload)
        XCTAssertEqual(exactPayload.projection.components, .init())
        XCTAssertEqual(
            exactPayload.projection.total,
            TokenCalculationService.estimateTokens(for: expected)
        )
    }

    func testStandardAppPromptPayloadGoldensCaptureCurrentOwnershipBeforeMigration() async throws {
        let file = makeEntry(
            id: "77777777-7777-7777-7777-777777777777",
            relativePath: "Sources/App.swift",
            content: "print(\"hi\")\n"
        )
        let clipboard = await PromptPackagingService.generateClipboardContent(
            metaInstructions: [MetaInstruction(title: "Rules", content: "META")],
            userInstructions: "FINAL",
            files: [file],
            fileTreeContent: "TREE",
            gitDiff: "DIFF",
            includeSavedPrompts: true,
            includeFiles: true,
            includeUserPrompt: true,
            filePathDisplay: .relative,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            duplicateUserInstructionsAtTop: false
        )
        let expectedClipboard = """
        <file_map>
        TREE
        </file_map>
        <file_contents>
        File: Sources/App.swift
        ```swift
        print("hi")

        ```
        </file_contents>
        <git_diff>
        DIFF
        </git_diff>
        <meta prompt 1 = "Rules">
        META
        </meta prompt 1>
        <user_instructions>
        FINAL
        </user_instructions>

        """
        XCTAssertEqual(clipboard, expectedClipboard)
        let exactClipboard = PromptPackagingService.exactRenderedPayload(clipboard, source: .immutableSnapshot)
        XCTAssertEqual(Array(exactClipboard.text.utf8), Array(expectedClipboard.utf8))
        XCTAssertEqual(
            exactClipboard.projection.total,
            TokenCalculationService.estimateTokens(for: expectedClipboard)
        )

        let message = PromptPackagingService.buildAIMessage(
            systemPrompt: "SYSTEM",
            metaInstructions: [MetaInstruction(title: "Rules", content: "META")],
            fileTree: "TREE",
            fileContents: ["File: Sources/App.swift\n```swift\nprint(\"hi\")\n```"],
            gitDiff: "DIFF",
            conversation: [
                ConversationEntry(role: .user, content: "EARLY"),
                ConversationEntry(role: .assistant, content: "ASSISTANT"),
                ConversationEntry(role: .user, content: "FINAL")
            ],
            temperature: nil,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            duplicateUserInstructionsAtTop: false,
            tailAssemblyStrategy: .coreStandardChat
        )
        let expectedTail = """
        <file_tree>
        TREE
        </file_tree>

        <file_contents>
        File: Sources/App.swift
        ```swift
        print("hi")
        ```

        </file_contents>

        <git_diff>
        DIFF
        </git_diff>

        <meta prompt "Rules">
        META
        </meta prompt>
        """
        let expectedFinalUser = """
        <user_instructions>
        FINAL
        </user_instructions>
        """
        XCTAssertEqual(message.buildTail(embedSystemPrompt: false), expectedTail)
        XCTAssertEqual(message.fileTreeXML, "<file_tree>\nTREE\n</file_tree>")
        XCTAssertEqual(
            message.fileBlocksXML,
            "<file_contents>\nFile: Sources/App.swift\n```swift\nprint(\"hi\")\n```\n\n</file_contents>"
        )
        XCTAssertEqual(message.gitDiffXML, "<git_diff>\nDIFF\n</git_diff>")
        XCTAssertEqual(
            message.combinedXML,
            "<system_prompt>\nSYSTEM\n</system_prompt>\n\n<meta_prompts>\n<meta prompt \"Rules\">\nMETA\n</meta prompt>\n\n</meta_prompts>\n\n<file_tree>\nTREE\n</file_tree>\n\n<file_contents>\nFile: Sources/App.swift\n```swift\nprint(\"hi\")\n```\n\n</file_contents>\n\n<git_diff>\nDIFF\n</git_diff>"
        )

        let coreFactual = PromptRenderingService.renderFactualSnippets(
            fileTreeContent: "TREE",
            codemapBlocks: [],
            contentBlocks: ["File: Sources/App.swift\n```swift\nprint(\"hi\")\n```"],
            gitDiff: "DIFF",
            envelopePolicy: .chatStyleTree
        )
        XCTAssertEqual(
            try PromptAssemblyBuilder.build(
                order: PromptAssemblyBuilder.defaultSectionOrder,
                disabled: [],
                duplicateUserInstructionsAtTop: false,
                snippets: [
                    .fileMap: XCTUnwrap(coreFactual.fileMap),
                    .fileContents: XCTUnwrap(coreFactual.fileContents),
                    .gitDiff: XCTUnwrap(coreFactual.gitDiff),
                    .metaPrompts: "<meta prompt \"Rules\">\nMETA\n</meta prompt>"
                ],
                layout: .blankLineSeparatedFragments
            ),
            expectedTail
        )

        let chatMessages = message.openAIChatMessages(embedSystemPrompt: false)
        let chatRoleNames = chatMessages.map { String(describing: $0.role) }
        XCTAssertEqual(chatRoleNames, ["system", "user", "assistant", "user"])
        let finalChatText: String? = if let finalChatMessage = chatMessages.last {
            switch finalChatMessage.content {
            case let .text(text):
                text
            case let .contentArray(items):
                items.compactMap { item in
                    if case let .text(text) = item { return text }
                    return nil
                }.joined()
            }
        } else {
            nil
        }
        XCTAssertEqual(finalChatText, expectedTail + "\n" + expectedFinalUser)

        let responseMessages: [(role: String, text: String)] = switch message.openAIResponsesInput() {
        case let .array(items):
            items.compactMap { item in
                guard case let .message(message) = item else { return nil }
                guard case let .text(text) = message.content else {
                    return nil
                }
                return (role: message.role, text: text)
            }
        default:
            []
        }
        XCTAssertEqual(responseMessages.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(responseMessages.first?.text, expectedTail + "\n\nEARLY")
        XCTAssertEqual(responseMessages.last?.text, expectedFinalUser)

        let exactChat = PromptPackagingService.exactChatPayload(for: message, source: .activeLive)
        let expectedExactChatBytes = Array(
            ("SYSTEM" + "EARLY" + "ASSISTANT" + expectedTail + "\n" + expectedFinalUser).utf8
        )
        XCTAssertEqual(Array(exactChat.text.utf8), expectedExactChatBytes)
    }

    func testCompleteAlternateCodemapCandidatesMatchPromptAccountingEligibility() async throws {
        let root = try makeTemporaryRoot(name: "CompleteAlternateParity")
        defer { try? FileManager.default.removeItem(at: root) }

        let selectedURL = root.appendingPathComponent("Selected.swift")
        let autoURL = root.appendingPathComponent("Auto.swift")
        let completeOnlyURL = root.appendingPathComponent("CompleteOnly.swift")
        try write("selected content", to: selectedURL)
        try write("auto content", to: autoURL)
        try write("complete content", to: completeOnlyURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: selectedURL.path,
                modificationDate: modificationDate,
                fileAPI: makeFileAPI(path: selectedURL.path, symbol: "selectedSymbol")
            ),
            WorkspaceObservedCodemapResult(
                fullPath: autoURL.path,
                modificationDate: modificationDate,
                fileAPI: makeFileAPI(path: autoURL.path, symbol: "autoSymbol")
            ),
            WorkspaceObservedCodemapResult(
                fullPath: completeOnlyURL.path,
                modificationDate: modificationDate,
                fileAPI: makeFileAPI(path: completeOnlyURL.path, symbol: "completeOnlySymbol")
            )
        ])
        let selection = StoredSelection(
            selectedPaths: [selectedURL.path],
            autoCodemapPaths: [autoURL.path],
            codemapAutoEnabled: true
        )

        let accounting = try await RepoPromptCore.PromptContextAccountingService().resolveEntries(
            selection: selection,
            store: store,
            codeMapUsage: .complete
        )
        XCTAssertEqual(
            Set(accounting.entries.filter(\.isCodemap).map(\.file.standardizedRelativePath)),
            Set(["Auto.swift", "CompleteOnly.swift"])
        )

        let capture = try await store.captureWorkspaceFileContext(
            selection: selection,
            fileTreeRequest: WorkspaceFileTreeSnapshotRequest(
                mode: .none,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: false,
                rootScope: .allLoaded
            ),
            profile: .uiAssisted
        )
        let codemapsByFileID = Dictionary(uniqueKeysWithValues: capture.codemapSnapshots.map { ($0.fileID, $0) })
        let selectedRecord = try XCTUnwrap(capture.materializedFiles.first {
            $0.standardizedRelativePath == "Selected.swift"
        })
        let selectedCodemapTokens = try XCTUnwrap(codemapsByFileID[selectedRecord.id]?.fileAPI?.apiTokenCount)
        let accountingCodemapTokens = try accounting.entries.filter(\.isCodemap).reduce(into: 0) { total, entry in
            total += try XCTUnwrap(codemapsByFileID[entry.file.id]?.fileAPI?.apiTokenCount)
        }

        let normalizedAccounting = try await RepoPromptCore.PromptContextAccountingService().calculatePromptStats(
            request: PromptContextAccountingRequest(
                selection: selection,
                codeMapUsage: .auto,
                filePathDisplay: .relative
            ),
            store: store
        )
        let projection = try await WorkspacePromptProjectionAdapter(store: store).projectTokens(
            selection: selection,
            codeMapUsage: .auto,
            filePathDisplay: .relative,
            alternatePolicy: .init(includeFiles: true, codeMapUsage: .complete),
            resolvedEntries: normalizedAccounting.resolvedEntries,
            promptFileEntrySnapshots: normalizedAccounting.promptFileEntrySnapshots,
            tokenProjectionInput: .activeLive(.init(
                reportedTotal: normalizedAccounting.tokenResult.totalTokenCount,
                prompt: 0,
                fileTree: 0,
                meta: 0,
                git: 0
            ))
        )

        XCTAssertEqual(projection.selection.files.map(\.file.standardizedRelativePath), [
            "Selected.swift",
            "Auto.swift"
        ])
        XCTAssertEqual(
            projection.selection.alternate?.codemapTokens,
            selectedCodemapTokens + accountingCodemapTokens
        )
        XCTAssertEqual(
            projection.tokens.userConfigured?.components.codemaps,
            selectedCodemapTokens + accountingCodemapTokens
        )
    }

    private func makeEntry(
        id: String,
        relativePath: String,
        content: String?,
        isCodemap: Bool = false,
        ranges: [LineRange]? = nil,
        rootID: UUID? = nil,
        rootPath: String? = nil
    ) -> ResolvedPromptFileEntry {
        let fileID = UUID(uuidString: id)!
        let entryRootID = rootID ?? self.rootID
        let entryRootPath = rootPath ?? self.rootPath
        let file = WorkspaceFileRecord(
            id: fileID,
            rootID: entryRootID,
            name: (relativePath as NSString).lastPathComponent,
            relativePath: relativePath,
            fullPath: "\(entryRootPath)/\(relativePath)",
            parentFolderID: nil,
            modificationDate: modificationDate
        )
        return ResolvedPromptFileEntry(
            file: file,
            isCodemap: isCodemap,
            lineRanges: ranges,
            mode: ranges == nil ? (isCodemap ? .codemap : .fullFile) : .sliced,
            loadedContent: content,
            rootFolderPath: entryRootPath
        )
    }

    private func makeFileViewModel(
        rootPath: String,
        relativePath: String,
        content: String
    ) -> FileViewModel {
        let fullPath = "\(rootPath)/\(relativePath)"
        return FileViewModel(
            file: File(
                name: (relativePath as NSString).lastPathComponent,
                path: fullPath,
                modificationDate: modificationDate
            ),
            rootPath: rootPath,
            rootIdentifier: UUID(),
            rootFolderPath: rootPath,
            fileSystemService: nil,
            relativePathOverride: relativePath,
            contentProvider: PromptRenderingContentProvider(
                content: content,
                modificationDate: modificationDate,
                fullPath: fullPath
            )
        )
    }

    private func makeFileAPI(path: String, symbol: String) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: [],
            classes: [],
            functions: [
                FunctionInfo(
                    name: symbol,
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func \(symbol)()",
                    lineNumber: 7
                )
            ],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: []
        )
    }

    private func makeCodemapSnapshot(for entry: ResolvedPromptFileEntry) -> WorkspaceCodemapSnapshot {
        WorkspaceCodemapSnapshot(
            fileID: entry.file.id,
            rootID: entry.file.rootID,
            rootPath: rootPath,
            relativePath: entry.file.relativePath,
            fullPath: entry.file.fullPath,
            modificationDate: modificationDate,
            fileAPI: makeFileAPI(path: entry.file.fullPath, symbol: "codemapOnlySymbol")
        )
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

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}

private final class PromptRenderingContentProvider: FileViewModelContentProvider, @unchecked Sendable {
    private let content: String
    private let storedModificationDate: Date
    private let fullPath: String

    init(content: String, modificationDate: Date, fullPath: String) {
        self.content = content
        storedModificationDate = modificationDate
        self.fullPath = fullPath
    }

    func loadContentWithDate() async throws -> (content: String?, modificationDate: Date) {
        (content, storedModificationDate)
    }

    func regularFileExistsOnDisk() async -> Bool {
        true
    }

    func modificationDate() async throws -> Date {
        storedModificationDate
    }

    func fullPathForReveal() async -> String {
        fullPath
    }

    func editContent(_ newContent: String) async throws {}

    func move(toRelativePath newRelativePath: String) async throws {}

    func moveToTrash() async throws {}
}
