import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

final class WorkspacePromptProjectionAdapterTests: XCTestCase {
    private enum TestError: Error {
        case unexpectedCaptureRequest
    }

    private actor EvaluationBatchRecorder {
        private var counts: [Int] = []

        func record(_ count: Int) {
            counts.append(count)
        }

        func snapshot() -> [Int] {
            counts
        }
    }

    private actor SnapshotBatchRecorder {
        private var tokenCounts: [[Int]] = []

        func record(_ snapshots: [PromptFileEntrySnapshot]) {
            tokenCounts.append(snapshots.map { $0.cachedFullTokenCount ?? -1 })
        }

        func snapshot() -> [[Int]] {
            tokenCounts
        }
    }

    func testProjectionPreservesSelectedFolderSliceAndAutoCodemapOrderWithCaptureProvenance() async throws {
        let root = makeRoot()
        let folder = makeFolder(root: root, path: "Sources")
        let selected = makeFile(root: root, path: "Selected.swift")
        let folderSecond = makeFile(root: root, path: "Sources/Second.swift", parentFolderID: folder.id)
        let folderFirst = makeFile(root: root, path: "Sources/First.swift", parentFolderID: folder.id)
        let sliced = makeFile(root: root, path: "Sliced.swift")
        let auto = makeFile(root: root, path: "Auto.swift")
        let ranges = [LineRange(start: 4, end: 8, description: "body")]
        let selection = StoredSelection(
            selectedPaths: [selected.fullPath, folder.fullPath],
            autoCodemapPaths: [auto.fullPath],
            slices: [sliced.fullPath: ranges],
            codemapAutoEnabled: true
        )
        let capture = makeCapture(
            root: root,
            files: [auto, sliced, folderFirst, selected, folderSecond],
            folders: [folder],
            selection: selection,
            selectedPaths: [
                .init(input: selected.fullPath, resolution: .file(selected)),
                .init(input: folder.fullPath, resolution: .folder(
                    folder,
                    descendantFiles: [folderSecond, folderFirst, selected]
                ))
            ],
            autoCodemapPaths: [.init(input: auto.fullPath, resolution: .file(auto))],
            slices: [.init(path: sliced.fullPath, ranges: ranges, file: sliced, issue: nil)],
            codemapSnapshots: [makeCodemap(file: auto, root: root, symbol: "AutoSymbol")]
        )
        let adapter = WorkspacePromptProjectionAdapter { capturedSelection, request, profile, coverage in
            guard capturedSelection == selection,
                  request.mode == .none,
                  request.rootScope == .allLoaded,
                  profile == .uiAssisted,
                  coverage == .projection(codemapCoverage: .referenced)
            else { throw TestError.unexpectedCaptureRequest }
            return capture
        }

        let projection = try await adapter.project(
            selection: selection,
            codeMapUsage: .auto,
            filePathDisplay: .relative
        )

        XCTAssertEqual(projection.provenance, capture.provenance)
        XCTAssertEqual(projection.entries.map(\.file.id), [
            selected.id,
            folderSecond.id,
            folderFirst.id,
            sliced.id,
            auto.id
        ])
        XCTAssertEqual(projection.entries.map(\.mode), [.full, .full, .full, .slice, .codemap])
        XCTAssertEqual(projection.entries.map(\.ranges), [nil, nil, nil, ranges, nil])
        XCTAssertEqual(projection.entries.map(\.codemapOrigin), [nil, nil, nil, nil, .auto])
        XCTAssertEqual(projection.entries.map(\.metadata.displayPath), [
            "Selected.swift",
            "Sources/Second.swift",
            "Sources/First.swift",
            "Sliced.swift",
            "Auto.swift"
        ])
    }

    func testProjectionUsesCoreSelectedAndCompleteCodemapModesAndOrigins() async throws {
        let root = makeRoot()
        let selectedWithAPI = makeFile(root: root, path: "SelectedWithAPI.swift")
        let selectedWithoutAPI = makeFile(root: root, path: "SelectedWithoutAPI.swift")
        let completeSecond = makeFile(root: root, path: "CompleteSecond.swift")
        let completeFirst = makeFile(root: root, path: "CompleteFirst.swift")
        let selection = StoredSelection(selectedPaths: [selectedWithAPI.fullPath, selectedWithoutAPI.fullPath])
        let capture = makeCapture(
            root: root,
            files: [selectedWithAPI, selectedWithoutAPI, completeSecond, completeFirst],
            selection: selection,
            selectedPaths: [
                .init(input: selectedWithAPI.fullPath, resolution: .file(selectedWithAPI)),
                .init(input: selectedWithoutAPI.fullPath, resolution: .file(selectedWithoutAPI))
            ],
            codemapSnapshots: [
                makeCodemap(file: completeSecond, root: root, symbol: "SecondSymbol"),
                makeCodemap(file: selectedWithAPI, root: root, symbol: "SelectedSymbol"),
                makeCodemap(file: completeFirst, root: root, symbol: "FirstSymbol")
            ]
        )
        let adapter = WorkspacePromptProjectionAdapter { _, _, _, _ in capture }

        let selectedProjection = try await adapter.project(
            selection: selection,
            codeMapUsage: .selected,
            filePathDisplay: .full
        )
        XCTAssertEqual(selectedProjection.entries.map(\.file.id), [selectedWithAPI.id, selectedWithoutAPI.id])
        XCTAssertEqual(selectedProjection.entries.map(\.mode), [.codemap, .full])
        XCTAssertEqual(selectedProjection.entries.map(\.codemapOrigin), [.selectedMode, nil])

        let completeProjection = try await adapter.project(
            selection: selection,
            codeMapUsage: .complete,
            filePathDisplay: .full
        )
        XCTAssertEqual(completeProjection.entries.map(\.file.id), [
            selectedWithAPI.id,
            selectedWithoutAPI.id,
            completeSecond.id,
            completeFirst.id
        ])
        XCTAssertEqual(completeProjection.entries.map(\.mode), [.full, .full, .codemap, .codemap])
        XCTAssertEqual(completeProjection.entries.map(\.codemapOrigin), [nil, nil, .auto, .auto])
    }

    func testTokenProjectionMatchesFactsByOccurrenceIdentityAndBuildsAlternateViews() async throws {
        let root = makeRoot()
        let full = makeFile(root: root, path: "Full.swift")
        let sliced = makeFile(root: root, path: "Sliced.swift")
        let auto = makeFile(root: root, path: "Auto.swift")
        let ranges = [
            LineRange(start: 3, end: 3, description: "third"),
            LineRange(start: 1, end: 1)
        ]
        let fullCodemap = makeCodemap(file: full, root: root, symbol: "FullSymbol")
        let autoCodemap = makeCodemap(file: auto, root: root, symbol: "AutoSymbol")
        let selection = StoredSelection(
            selectedPaths: [full.fullPath],
            autoCodemapPaths: [auto.fullPath],
            slices: [sliced.fullPath: ranges],
            codemapAutoEnabled: true
        )
        let capture = makeCapture(
            root: root,
            files: [full, sliced, auto],
            selection: selection,
            selectedPaths: [.init(input: full.fullPath, resolution: .file(full))],
            autoCodemapPaths: [.init(input: auto.fullPath, resolution: .file(auto))],
            slices: [.init(path: sliced.fullPath, ranges: ranges, file: sliced, issue: nil)],
            codemapSnapshots: [fullCodemap, autoCodemap]
        )
        let fullContent = "struct Full { let value = 1 }\n"
        let slicedContent = "one\ntwo\nthree\nfour\n"
        let autoTokens = try XCTUnwrap(autoCodemap.fileAPI?.apiTokenCount)
        let fullCodemapTokens = try XCTUnwrap(fullCodemap.fileAPI?.apiTokenCount)
        let resolvedEntries = [
            ResolvedPromptFileEntry(file: full, loadedContent: fullContent, rootFolderPath: root.fullPath),
            ResolvedPromptFileEntry(
                file: sliced,
                lineRanges: ranges,
                mode: .sliced,
                loadedContent: slicedContent,
                rootFolderPath: root.fullPath
            ),
            ResolvedPromptFileEntry(file: auto, isCodemap: true, mode: .codemap, rootFolderPath: root.fullPath)
        ]
        let snapshots = [
            PromptFileEntrySnapshot(
                fileID: full.id,
                relativePath: full.relativePath,
                isCodemapRequested: false,
                ranges: nil,
                cachedFullTokenCount: TokenCalculationService.estimateTokens(for: fullContent),
                loadedContent: fullContent,
                codeMapContent: nil,
                availableCodeMapTokenCount: fullCodemapTokens
            ),
            PromptFileEntrySnapshot(
                fileID: sliced.id,
                relativePath: sliced.relativePath,
                isCodemapRequested: false,
                ranges: ranges,
                cachedFullTokenCount: TokenCalculationService.estimateTokens(for: slicedContent),
                loadedContent: slicedContent,
                codeMapContent: nil,
                availableCodeMapTokenCount: 0
            ),
            PromptFileEntrySnapshot(
                fileID: auto.id,
                relativePath: auto.relativePath,
                isCodemapRequested: true,
                ranges: nil,
                cachedFullTokenCount: nil,
                loadedContent: nil,
                codeMapContent: "Auto map",
                availableCodeMapTokenCount: autoTokens
            )
        ]
        let adapter = WorkspacePromptProjectionAdapter { _, _, _, _ in capture }

        let projection = try await adapter.projectTokens(
            selection: selection,
            codeMapUsage: .auto,
            filePathDisplay: .relative,
            alternatePolicy: .init(includeFiles: true, codeMapUsage: .selected),
            resolvedEntries: resolvedEntries,
            promptFileEntrySnapshots: snapshots,
            tokenProjectionInput: .activeLive(.init(
                reportedTotal: 1000,
                prompt: 7,
                fileTree: 5,
                meta: 3,
                git: 2
            ))
        )

        XCTAssertEqual(projection.provenance, capture.provenance)
        XCTAssertEqual(projection.selection.files.map(\.mode), [.full, .slice, .codemap])
        XCTAssertEqual(projection.selection.files.map(\.ranges), [nil, ranges, nil])
        XCTAssertEqual(projection.selection.files[0].alternate?.mode, .codemap)
        XCTAssertEqual(projection.selection.files[0].alternate?.tokens, fullCodemapTokens)
        XCTAssertNil(projection.selection.files[2].alternate)
        XCTAssertEqual(projection.tokens.normalized.components.files, projection.selection.summary.totalTokens)
        XCTAssertEqual(
            projection.tokens.normalized.components.filesContent,
            projection.selection.summary.fullTokens + projection.selection.summary.sliceTokens
        )
        XCTAssertEqual(projection.tokens.normalized.components.codemaps, autoTokens)
        XCTAssertEqual(projection.tokens.normalized.components.prompt, 7)
        XCTAssertEqual(projection.tokens.normalized.total, 1000)
        let normalizedComponentFloor = projection.selection.summary.totalTokens + 7 + 5 + 3 + 2
        XCTAssertEqual(projection.tokens.normalized.components.other, 1000 - normalizedComponentFloor)
        XCTAssertEqual(
            projection.tokens.userConfigured?.components.other,
            projection.tokens.normalized.components.other
        )
        XCTAssertEqual(projection.tokens.userConfigured?.components.codemaps, fullCodemapTokens + autoTokens)
        XCTAssertEqual(
            projection.tokens.userConfigured?.components.files,
            fullCodemapTokens + projection.selection.summary.sliceTokens + autoTokens
        )
        XCTAssertEqual(projection.selection.alternate?.includedFiles.map(\.file.id), [full.id, sliced.id, auto.id])
    }

    func testTokenProjectionIncludesCompleteOnlyCodemapsAndCanHideContent() async throws {
        let root = makeRoot()
        let selected = makeFile(root: root, path: "Selected.swift")
        let auto = makeFile(root: root, path: "Auto.swift")
        let completeOnly = makeFile(root: root, path: "CompleteOnly.swift")
        let selectedCodemap = makeCodemap(file: selected, root: root, symbol: "SelectedSymbol")
        let autoCodemap = makeCodemap(file: auto, root: root, symbol: "AutoSymbol")
        let completeCodemap = makeCodemap(file: completeOnly, root: root, symbol: "CompleteSymbol")
        let selection = StoredSelection(
            selectedPaths: [selected.fullPath],
            autoCodemapPaths: [auto.fullPath],
            codemapAutoEnabled: true
        )
        let capture = makeCapture(
            root: root,
            files: [selected, auto, completeOnly],
            selection: selection,
            selectedPaths: [.init(input: selected.fullPath, resolution: .file(selected))],
            autoCodemapPaths: [.init(input: auto.fullPath, resolution: .file(auto))],
            codemapSnapshots: [selectedCodemap, autoCodemap, completeCodemap]
        )
        let selectedContent = "struct Selected {}\n"
        let autoTokens = try XCTUnwrap(autoCodemap.fileAPI?.apiTokenCount)
        let selectedTokens = try XCTUnwrap(selectedCodemap.fileAPI?.apiTokenCount)
        let completeTokens = try XCTUnwrap(completeCodemap.fileAPI?.apiTokenCount)
        let adapter = WorkspacePromptProjectionAdapter { _, _, _, coverage in
            guard coverage == .projection(codemapCoverage: .allAvailable) else {
                throw TestError.unexpectedCaptureRequest
            }
            return capture
        }

        let projection = try await adapter.projectTokens(
            selection: selection,
            codeMapUsage: .auto,
            filePathDisplay: .relative,
            alternatePolicy: .init(includeFiles: false, codeMapUsage: .complete),
            resolvedEntries: [
                ResolvedPromptFileEntry(file: selected, loadedContent: selectedContent, rootFolderPath: root.fullPath),
                ResolvedPromptFileEntry(file: auto, isCodemap: true, mode: .codemap, rootFolderPath: root.fullPath)
            ],
            promptFileEntrySnapshots: [
                PromptFileEntrySnapshot(
                    fileID: selected.id,
                    relativePath: selected.relativePath,
                    isCodemapRequested: false,
                    ranges: nil,
                    cachedFullTokenCount: TokenCalculationService.estimateTokens(for: selectedContent),
                    loadedContent: selectedContent,
                    codeMapContent: nil,
                    availableCodeMapTokenCount: selectedTokens
                ),
                PromptFileEntrySnapshot(
                    fileID: auto.id,
                    relativePath: auto.relativePath,
                    isCodemapRequested: true,
                    ranges: nil,
                    cachedFullTokenCount: nil,
                    loadedContent: nil,
                    codeMapContent: "Auto map",
                    availableCodeMapTokenCount: autoTokens
                )
            ],
            tokenProjectionInput: .activeLive(.init(
                reportedTotal: 0,
                prompt: 4,
                fileTree: 0,
                meta: 0,
                git: 0
            ))
        )

        XCTAssertEqual(projection.selection.alternate?.codemapTokens, selectedTokens + autoTokens + completeTokens)
        XCTAssertEqual(projection.selection.alternate?.includedTotalTokens, autoTokens)
        XCTAssertEqual(projection.selection.alternate?.includedFiles.map(\.file.id), [auto.id])
        XCTAssertEqual(projection.tokens.userConfigured?.components.files, autoTokens)
        XCTAssertEqual(projection.tokens.userConfigured?.components.filesContent, nil)
        XCTAssertEqual(projection.tokens.userConfigured?.components.codemaps, autoTokens)
        XCTAssertEqual(projection.tokens.userConfigured?.total, autoTokens + 4)
    }

    func testTokenProjectionRejectsUnusedAccountingOccurrenceFacts() async throws {
        let root = makeRoot()
        let selected = makeFile(root: root, path: "Selected.swift")
        let extra = makeFile(root: root, path: "Extra.swift")
        let selection = StoredSelection(selectedPaths: [selected.fullPath])
        let capture = makeCapture(
            root: root,
            files: [selected, extra],
            selection: selection,
            selectedPaths: [.init(input: selected.fullPath, resolution: .file(selected))]
        )
        let selectedContent = "struct Selected {}\n"
        let extraContent = "struct Extra {}\n"
        let adapter = WorkspacePromptProjectionAdapter { _, _, _, _ in capture }

        do {
            _ = try await adapter.projectTokens(
                selection: selection,
                codeMapUsage: .none,
                filePathDisplay: .relative,
                alternatePolicy: nil,
                resolvedEntries: [
                    ResolvedPromptFileEntry(file: selected, loadedContent: selectedContent),
                    ResolvedPromptFileEntry(file: extra, loadedContent: extraContent)
                ],
                promptFileEntrySnapshots: [
                    PromptFileEntrySnapshot(
                        fileID: selected.id,
                        relativePath: selected.relativePath,
                        isCodemapRequested: false,
                        ranges: nil,
                        cachedFullTokenCount: TokenCalculationService.estimateTokens(for: selectedContent),
                        loadedContent: selectedContent,
                        codeMapContent: nil,
                        availableCodeMapTokenCount: 0
                    ),
                    PromptFileEntrySnapshot(
                        fileID: extra.id,
                        relativePath: extra.relativePath,
                        isCodemapRequested: false,
                        ranges: nil,
                        cachedFullTokenCount: TokenCalculationService.estimateTokens(for: extraContent),
                        loadedContent: extraContent,
                        codeMapContent: nil,
                        availableCodeMapTokenCount: 0
                    )
                ],
                tokenProjectionInput: .activeLive(.init(
                    reportedTotal: 0,
                    prompt: 0,
                    fileTree: 0,
                    meta: 0,
                    git: 0
                ))
            )
            XCTFail("Expected unused accounting occurrence facts")
        } catch let error as WorkspacePromptProjectionAdapter.Error {
            guard case let .unusedTokenFacts(identities) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(identities.map(\.fileID), [extra.id])
        }
    }

    func testTokenProjectionRejectsFactsFromAnOlderFileRevision() async throws {
        let root = makeRoot()
        let captured = WorkspaceFileRecord(
            rootID: root.id,
            name: "Selected.swift",
            relativePath: "Selected.swift",
            fullPath: root.fullPath + "/Selected.swift",
            parentFolderID: nil,
            modificationDate: Date(timeIntervalSince1970: 2)
        )
        let accounted = WorkspaceFileRecord(
            id: captured.id,
            rootID: captured.rootID,
            name: captured.name,
            relativePath: captured.relativePath,
            fullPath: captured.fullPath,
            parentFolderID: captured.parentFolderID,
            modificationDate: Date(timeIntervalSince1970: 1)
        )
        let selection = StoredSelection(selectedPaths: [captured.fullPath])
        let capture = makeCapture(
            root: root,
            files: [captured],
            selection: selection,
            selectedPaths: [.init(input: captured.fullPath, resolution: .file(captured))]
        )
        let content = "struct Selected {}\n"
        let adapter = WorkspacePromptProjectionAdapter { _, _, _, _ in capture }

        do {
            _ = try await adapter.projectTokens(
                selection: selection,
                codeMapUsage: .none,
                filePathDisplay: .relative,
                alternatePolicy: nil,
                resolvedEntries: [ResolvedPromptFileEntry(file: accounted, loadedContent: content)],
                promptFileEntrySnapshots: [
                    PromptFileEntrySnapshot(
                        fileID: accounted.id,
                        relativePath: accounted.relativePath,
                        isCodemapRequested: false,
                        ranges: nil,
                        cachedFullTokenCount: TokenCalculationService.estimateTokens(for: content),
                        loadedContent: content,
                        codeMapContent: nil,
                        availableCodeMapTokenCount: 0
                    )
                ],
                tokenProjectionInput: .activeLive(.init(
                    reportedTotal: 0,
                    prompt: 0,
                    fileTree: 0,
                    meta: 0,
                    git: 0
                ))
            )
            XCTFail("Expected stale occurrence token facts")
        } catch let error as WorkspacePromptProjectionAdapter.Error {
            guard case let .missingTokenFacts(identity) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(identity.fileID, captured.id)
            XCTAssertEqual(identity.standardizedPath, captured.standardizedFullPath)
        }
    }

    func testTokenProjectionThrowsWhenOccurrenceIdentityHasNoRequiredFact() async throws {
        let root = makeRoot()
        let selected = makeFile(root: root, path: "Selected.swift")
        let mismatched = WorkspaceFileRecord(
            id: selected.id,
            rootID: selected.rootID,
            name: selected.name,
            relativePath: "Renamed.swift",
            fullPath: root.fullPath + "/Renamed.swift",
            parentFolderID: nil
        )
        let selection = StoredSelection(selectedPaths: [selected.fullPath])
        let capture = makeCapture(
            root: root,
            files: [selected],
            selection: selection,
            selectedPaths: [.init(input: selected.fullPath, resolution: .file(selected))]
        )
        let content = "struct Selected {}\n"
        let adapter = WorkspacePromptProjectionAdapter { _, _, _, _ in capture }

        do {
            _ = try await adapter.projectTokens(
                selection: selection,
                codeMapUsage: .none,
                filePathDisplay: .relative,
                alternatePolicy: nil,
                resolvedEntries: [ResolvedPromptFileEntry(file: mismatched, loadedContent: content)],
                promptFileEntrySnapshots: [
                    PromptFileEntrySnapshot(
                        fileID: mismatched.id,
                        relativePath: mismatched.relativePath,
                        isCodemapRequested: false,
                        ranges: nil,
                        cachedFullTokenCount: TokenCalculationService.estimateTokens(for: content),
                        loadedContent: content,
                        codeMapContent: nil,
                        availableCodeMapTokenCount: 0
                    )
                ],
                tokenProjectionInput: .activeLive(.init(
                    reportedTotal: 0,
                    prompt: 0,
                    fileTree: 0,
                    meta: 0,
                    git: 0
                ))
            )
            XCTFail("Expected missing occurrence token facts")
        } catch let error as WorkspacePromptProjectionAdapter.Error {
            guard case let .missingTokenFacts(identity) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(identity.fileID, selected.id)
            XCTAssertEqual(identity.standardizedPath, selected.standardizedFullPath)
            XCTAssertEqual(identity.mode, .full)
            XCTAssertEqual(identity.ranges, [])
        }
    }

    func testIdenticalDuplicateSnapshotsAreConsumedFIFO() async throws {
        let root = makeRoot()
        let selected = makeFile(root: root, path: "Selected.swift")
        let selection = StoredSelection(selectedPaths: [selected.fullPath])
        let capture = makeCapture(
            root: root,
            files: [selected],
            selection: selection,
            selectedPaths: [.init(input: selected.fullPath, resolution: .file(selected))]
        )
        let recorder = SnapshotBatchRecorder()
        let tokenService = TokenCalculationService()
        let adapter = WorkspacePromptProjectionAdapter(
            capture: { _, _, _, _ in capture },
            evaluatePromptEntries: { snapshots in
                await recorder.record(snapshots)
                return await tokenService.evaluatePromptEntries(snapshots)
            }
        )
        let resolvedEntries = [
            ResolvedPromptFileEntry(file: selected),
            ResolvedPromptFileEntry(file: selected)
        ]
        let snapshots = [11, 22].map { tokens in
            PromptFileEntrySnapshot(
                fileID: selected.id,
                relativePath: selected.relativePath,
                isCodemapRequested: false,
                ranges: nil,
                cachedFullTokenCount: tokens,
                loadedContent: nil,
                codeMapContent: nil,
                availableCodeMapTokenCount: 0
            )
        }

        do {
            _ = try await adapter.projectTokens(
                selection: selection,
                codeMapUsage: .none,
                filePathDisplay: .relative,
                alternatePolicy: nil,
                resolvedEntries: resolvedEntries,
                promptFileEntrySnapshots: snapshots,
                tokenProjectionInput: .emptyVirtual
            )
            XCTFail("Expected one unused duplicate fact")
        } catch let error as WorkspacePromptProjectionAdapter.Error {
            guard case let .unusedTokenFacts(identities) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(identities.map(\.fileID), [selected.id])
        }
        let batches = await recorder.snapshot()
        XCTAssertEqual(batches, [[11], [22]])
    }

    func testEarlierEvaluationFailurePrecedesLaterMissingSnapshot() async throws {
        let root = makeRoot()
        let first = makeFile(root: root, path: "First.swift")
        let later = makeFile(root: root, path: "Later.swift")
        let selection = StoredSelection(selectedPaths: [first.fullPath])
        let adapter = WorkspacePromptProjectionAdapter(
            capture: { _, _, _, _ in throw TestError.unexpectedCaptureRequest },
            evaluatePromptEntries: { _ in .empty }
        )

        do {
            _ = try await adapter.projectTokens(
                selection: selection,
                codeMapUsage: .none,
                filePathDisplay: .relative,
                alternatePolicy: nil,
                resolvedEntries: [
                    ResolvedPromptFileEntry(file: first),
                    ResolvedPromptFileEntry(file: later)
                ],
                promptFileEntrySnapshots: [
                    PromptFileEntrySnapshot(
                        fileID: first.id,
                        relativePath: first.relativePath,
                        isCodemapRequested: false,
                        ranges: nil,
                        cachedFullTokenCount: 1,
                        loadedContent: nil,
                        codeMapContent: nil,
                        availableCodeMapTokenCount: 0
                    )
                ],
                tokenProjectionInput: .emptyVirtual
            )
            XCTFail("Expected the earlier evaluation failure")
        } catch let error as WorkspacePromptProjectionAdapter.Error {
            guard case let .missingTokenFacts(identity) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(identity.fileID, first.id)
        }
    }

    func testDuplicateAccountingFactsPreserveUnusedOrderAndUseOrdinalBatches() async throws {
        let root = makeRoot()
        let selected = makeFile(root: root, path: "Selected.swift")
        let duplicate = makeFile(root: root, path: "Duplicate.swift")
        let tail = makeFile(root: root, path: "Tail.swift")
        let ranges = [LineRange(start: 1, end: 1)]
        let selection = StoredSelection(selectedPaths: [selected.fullPath])
        let capture = makeCapture(
            root: root,
            files: [selected, duplicate, tail],
            selection: selection,
            selectedPaths: [.init(input: selected.fullPath, resolution: .file(selected))]
        )
        let recorder = EvaluationBatchRecorder()
        let tokenService = TokenCalculationService()
        let adapter = WorkspacePromptProjectionAdapter(
            capture: { _, _, _, _ in capture },
            evaluatePromptEntries: { snapshots in
                await recorder.record(snapshots.count)
                return await tokenService.evaluatePromptEntries(snapshots)
            }
        )
        let duplicateContent = "one\ntwo\n"
        let resolvedEntries = [
            ResolvedPromptFileEntry(file: selected, loadedContent: "selected"),
            ResolvedPromptFileEntry(file: duplicate, loadedContent: duplicateContent),
            ResolvedPromptFileEntry(
                file: duplicate,
                lineRanges: ranges,
                mode: .sliced,
                loadedContent: duplicateContent
            ),
            ResolvedPromptFileEntry(file: tail, loadedContent: "tail")
        ]
        let snapshots = [
            PromptFileEntrySnapshot(
                fileID: selected.id,
                relativePath: selected.relativePath,
                isCodemapRequested: false,
                ranges: nil,
                cachedFullTokenCount: 1,
                loadedContent: "selected",
                codeMapContent: nil,
                availableCodeMapTokenCount: 0
            ),
            PromptFileEntrySnapshot(
                fileID: duplicate.id,
                relativePath: duplicate.relativePath,
                isCodemapRequested: false,
                ranges: nil,
                cachedFullTokenCount: 2,
                loadedContent: duplicateContent,
                codeMapContent: nil,
                availableCodeMapTokenCount: 0
            ),
            PromptFileEntrySnapshot(
                fileID: duplicate.id,
                relativePath: duplicate.relativePath,
                isCodemapRequested: false,
                ranges: ranges,
                cachedFullTokenCount: 2,
                loadedContent: duplicateContent,
                codeMapContent: nil,
                availableCodeMapTokenCount: 0
            ),
            PromptFileEntrySnapshot(
                fileID: tail.id,
                relativePath: tail.relativePath,
                isCodemapRequested: false,
                ranges: nil,
                cachedFullTokenCount: 1,
                loadedContent: "tail",
                codeMapContent: nil,
                availableCodeMapTokenCount: 0
            )
        ]

        do {
            _ = try await adapter.projectTokens(
                selection: selection,
                codeMapUsage: .none,
                filePathDisplay: .relative,
                alternatePolicy: nil,
                resolvedEntries: resolvedEntries,
                promptFileEntrySnapshots: snapshots,
                tokenProjectionInput: .emptyVirtual
            )
            XCTFail("Expected unused duplicate token facts")
        } catch let error as WorkspacePromptProjectionAdapter.Error {
            guard case let .unusedTokenFacts(identities) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(identities.map(\.fileID), [duplicate.id, duplicate.id, tail.id])
            XCTAssertEqual(identities.map(\.mode), [.full, .slice, .full])
        }
        let batchCounts = await recorder.snapshot()
        XCTAssertEqual(batchCounts, [3, 1])
    }

    func testFiveThousandUniqueOccurrencesUseOneTokenEvaluationBatch() async throws {
        let root = makeRoot()
        let count = 5000
        let files = (0 ..< count).map { index in
            makeFile(root: root, path: String(format: "File%05d.swift", index))
        }
        let selection = StoredSelection(selectedPaths: files.map(\.fullPath))
        let capture = makeCapture(
            root: root,
            files: files,
            selection: selection,
            selectedPaths: files.map { .init(input: $0.fullPath, resolution: .file($0)) }
        )
        let snapshots = files.map { file in
            PromptFileEntrySnapshot(
                fileID: file.id,
                relativePath: file.relativePath,
                isCodemapRequested: false,
                ranges: nil,
                cachedFullTokenCount: 1,
                loadedContent: nil,
                codeMapContent: nil,
                availableCodeMapTokenCount: 0
            )
        }
        let recorder = EvaluationBatchRecorder()
        let tokenService = TokenCalculationService()
        let adapter = WorkspacePromptProjectionAdapter(
            capture: { _, _, _, coverage in
                guard coverage == .projection(codemapCoverage: .referenced) else {
                    throw TestError.unexpectedCaptureRequest
                }
                return capture
            },
            evaluatePromptEntries: { entries in
                await recorder.record(entries.count)
                return await tokenService.evaluatePromptEntries(entries)
            }
        )

        let projection = try await adapter.projectTokens(
            selection: selection,
            codeMapUsage: .none,
            filePathDisplay: .relative,
            alternatePolicy: nil,
            resolvedEntries: files.map { ResolvedPromptFileEntry(file: $0) },
            promptFileEntrySnapshots: snapshots,
            tokenProjectionInput: .emptyVirtual
        )

        XCTAssertEqual(projection.selection.files.count, count)
        let batchCounts = await recorder.snapshot()
        XCTAssertEqual(batchCounts, [count])
    }

    @MainActor
    func testLiveMappingRequiresCurrentRecordIdentityAndPreservesProjectedModeAndRanges() {
        let root = makeRoot()
        let sliced = makeFile(root: root, path: "Sliced.swift")
        let codemap = makeFile(root: root, path: "Codemap.swift")
        let stale = makeFile(root: root, path: "Stale.swift")
        let ranges = [LineRange(start: 2, end: 3)]
        let slicedViewModel = makeFileViewModel(sliced, root: root)
        let codemapViewModel = makeFileViewModel(codemap, root: root)
        let replacementAtStalePath = makeFileViewModel(
            WorkspaceFileRecord(
                id: UUID(),
                rootID: stale.rootID,
                name: stale.name,
                relativePath: stale.relativePath,
                fullPath: stale.fullPath,
                parentFolderID: stale.parentFolderID
            ),
            root: root
        )
        let projection = WorkspacePromptProjectionAdapter.Projection(
            provenance: makeProvenance(),
            entries: [
                .init(
                    file: sliced,
                    metadata: makeMetadata(file: sliced, root: root),
                    mode: .slice,
                    ranges: ranges,
                    codemapOrigin: nil
                ),
                .init(
                    file: codemap,
                    metadata: makeMetadata(file: codemap, root: root),
                    mode: .codemap,
                    ranges: nil,
                    codemapOrigin: .auto
                ),
                .init(
                    file: stale,
                    metadata: makeMetadata(file: stale, root: root),
                    mode: .full,
                    ranges: nil,
                    codemapOrigin: nil
                )
            ]
        )
        let filesByPath = [
            sliced.standardizedFullPath: slicedViewModel,
            codemap.standardizedFullPath: codemapViewModel,
            stale.standardizedFullPath: replacementAtStalePath
        ]
        let adapter = WorkspacePromptProjectionAdapter { _, _, _, _ in
            throw TestError.unexpectedCaptureRequest
        }

        let entries = adapter.mapToLivePromptEntries(projection) { file in
            filesByPath[file.standardizedFullPath]
        }

        XCTAssertEqual(entries.map(\.file.id), [sliced.id, codemap.id])
        XCTAssertEqual(entries.map(\.isCodemap), [false, true])
        XCTAssertEqual(entries.map(\.ranges), [ranges, nil])
    }

    private func makeCapture(
        root: WorkspaceRootRecord,
        files: [WorkspaceFileRecord],
        folders: [WorkspaceFolderRecord] = [],
        selection: StoredSelection,
        selectedPaths: [WorkspaceFileContextCapture.SelectionPath],
        autoCodemapPaths: [WorkspaceFileContextCapture.SelectionPath] = [],
        slices: [WorkspaceFileContextCapture.Slice] = [],
        codemapSnapshots: [WorkspaceCodemapSnapshot] = []
    ) -> WorkspaceFileContextCapture {
        let provenance = makeProvenance()
        let diagnostics = WorkspaceCatalogDiagnostics(
            generation: provenance.catalogGeneration,
            rootScope: provenance.rootScope,
            rootCount: 1,
            folderCount: folders.count,
            fileCount: files.count
        )
        return WorkspaceFileContextCapture(
            provenance: provenance,
            storedSelection: selection,
            selectedPaths: selectedPaths,
            autoCodemapPaths: autoCodemapPaths,
            slices: slices,
            catalog: WorkspaceSearchCatalogSnapshot(
                generation: provenance.catalogGeneration,
                rootScope: provenance.rootScope,
                roots: [root],
                files: files,
                entries: files.map { WorkspaceSearchCatalogEntry(file: $0, root: root) },
                diagnostics: diagnostics
            ),
            materializedFolders: folders,
            materializedFiles: files,
            codemapSnapshots: codemapSnapshots,
            fileTree: FileTreeSelectionSnapshot(
                roots: [],
                selectedFileIDs: Set(files.map(\.id)),
                mode: "none",
                showFullPaths: false,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false
            )
        )
    }

    private func makeProvenance() -> WorkspaceFileContextCapture.Provenance {
        WorkspaceFileContextCapture.Provenance(
            captureGeneration: 17,
            catalogGeneration: 11,
            catalogValidationToken: 23,
            rootScope: .allLoaded,
            ingressSamples: []
        )
    }

    private func makeRoot() -> WorkspaceRootRecord {
        WorkspaceRootRecord(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Repo",
            fullPath: "/repo"
        )
    }

    private func makeFolder(root: WorkspaceRootRecord, path: String) -> WorkspaceFolderRecord {
        WorkspaceFolderRecord(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            rootID: root.id,
            name: (path as NSString).lastPathComponent,
            relativePath: path,
            fullPath: root.fullPath + "/" + path,
            parentFolderID: nil
        )
    }

    private func makeFile(
        root: WorkspaceRootRecord,
        path: String,
        parentFolderID: UUID? = nil
    ) -> WorkspaceFileRecord {
        WorkspaceFileRecord(
            rootID: root.id,
            name: (path as NSString).lastPathComponent,
            relativePath: path,
            fullPath: root.fullPath + "/" + path,
            parentFolderID: parentFolderID
        )
    }

    private func makeCodemap(
        file: WorkspaceFileRecord,
        root: WorkspaceRootRecord,
        symbol: String
    ) -> WorkspaceCodemapSnapshot {
        WorkspaceCodemapSnapshot(
            fileID: file.id,
            rootID: root.id,
            rootPath: root.fullPath,
            relativePath: file.relativePath,
            fullPath: file.fullPath,
            modificationDate: Date(timeIntervalSince1970: 0),
            fileAPI: FileAPI(
                filePath: file.fullPath,
                imports: [],
                classes: [.init(name: symbol, methods: [], properties: [])],
                functions: [],
                enums: [],
                globalVars: [],
                macros: [],
                referencedTypes: []
            )
        )
    }

    private func makeMetadata(
        file: WorkspaceFileRecord,
        root: WorkspaceRootRecord
    ) -> WorkspaceSelectionProjection.PathMetadata {
        .init(
            displayPath: file.relativePath,
            rootPath: root.fullPath,
            pathWithinRoot: file.relativePath
        )
    }

    @MainActor
    private func makeFileViewModel(
        _ record: WorkspaceFileRecord,
        root: WorkspaceRootRecord
    ) -> FileViewModel {
        FileViewModel(
            file: File(
                id: record.id,
                name: record.name,
                path: record.fullPath,
                modificationDate: Date(timeIntervalSince1970: 0)
            ),
            rootPath: root.fullPath,
            rootIdentifier: root.id,
            rootFolderPath: root.fullPath,
            fileSystemService: nil,
            relativePathOverride: record.relativePath
        )
    }
}
