import Foundation
@testable import RepoPromptCore
import XCTest

final class WorkspaceContextProjectionServiceTests: XCTestCase {
    func testOmittedSectionsAreNilAndDoNotMaterialize() async throws {
        let capture = makeEmptyCapture()
        var materialized = false
        let service = WorkspaceContextProjectionService(
            capture: { capture },
            materializer: { request in
                materialized = true
                return .init(provenance: request.provenance, occurrences: [])
            }
        )

        let projection = try await service.project(.init(sections: []))

        XCTAssertNil(projection.prompt)
        XCTAssertNil(projection.selection)
        XCTAssertNil(projection.fileBlocks)
        XCTAssertNil(projection.codeStructure)
        XCTAssertNil(projection.fileTree)
        XCTAssertNil(projection.tokens)
        XCTAssertFalse(materialized)
    }

    func testRequestedEmptySectionsRemainPresentWithCaptureProvenance() async throws {
        let capture = makeEmptyCapture()
        let service = WorkspaceContextProjectionService(
            capture: { capture },
            materializer: { request in
                XCTAssertEqual(request.provenance, capture.provenance)
                XCTAssertEqual(request.occurrences, [])
                XCTAssertTrue(request.requiresContent)
                XCTAssertTrue(request.requiresTokenFacts)
                return .init(provenance: request.provenance, occurrences: [])
            }
        )

        let projection = try await service.project(.init())

        XCTAssertEqual(projection.prompt?.value, "")
        XCTAssertEqual(projection.selection?.value.files, [])
        XCTAssertEqual(projection.selection?.value.slices, [])
        XCTAssertEqual(projection.selection?.value.summary, .empty)
        XCTAssertEqual(projection.fileBlocks?.value, [])
        XCTAssertEqual(projection.codeStructure?.value.content, "")
        XCTAssertEqual(projection.codeStructure?.value.renderedPaths, [])
        XCTAssertEqual(projection.codeStructure?.value.unmappedPaths, [])
        XCTAssertEqual(projection.fileTree?.value.content, "")
        XCTAssertEqual(projection.fileTree?.value.rootCount, 0)
        XCTAssertEqual(projection.tokens?.value.normalized.total, 0)
        XCTAssertEqual(projection.tokens?.value.normalized.components.files, 0)
        XCTAssertNil(projection.tokens?.value.normalized.components.prompt)
        XCTAssertNil(projection.tokens?.value.normalized.components.filesContent)
        XCTAssertNil(projection.tokens?.value.normalized.components.codemaps)
        XCTAssertNil(projection.tokens?.value.userConfigured)
        assertAllPresentSections(projection, have: capture.provenance)
    }

    func testAllSectionsComposeFullSliceCodemapTreeCodeAndTokenViews() async throws {
        let fixture = makeFullSliceCodemapCapture()
        let codemapTokens = try XCTUnwrap(fixture.codemap.fileAPI?.apiTokenCount)
        let ranges = [LineRange(start: 2, end: 2, description: "middle")]
        let service = WorkspaceContextProjectionService(
            capture: { fixture.capture },
            materializer: { request in
                XCTAssertEqual(request.occurrences.map(\.file.standardizedRelativePath), [
                    "Full.swift",
                    "Slice.swift",
                    "Code.swift"
                ])
                XCTAssertEqual(request.occurrences.map(\.mode), [.full, .slice, .codemap])
                XCTAssertEqual(request.occurrences.map(\.ranges), [[], ranges, []])
                XCTAssertNil(request.occurrences[0].codemap)
                XCTAssertNil(request.occurrences[1].codemap)
                XCTAssertEqual(request.occurrences[2].codemap?.tokens, codemapTokens)
                XCTAssertTrue(request.requiresContent)
                XCTAssertTrue(request.requiresTokenFacts)
                return .init(
                    provenance: request.provenance,
                    occurrences: request.occurrences.reversed().map { occurrence in
                        let content: String? = switch occurrence.mode {
                        case .full: "full body"
                        case .slice: "one\ntwo\nthree"
                        case .codemap: "ignored live content"
                        }
                        let tokenFacts: WorkspaceContextProjectionMaterialization.TokenFacts = switch occurrence.mode {
                        case .full: .init(displayTokens: 12, fullTokens: 12)
                        case .slice: .init(displayTokens: 3, fullTokens: 30)
                        case .codemap: .init(displayTokens: codemapTokens, fullTokens: 20)
                        }
                        return .init(id: occurrence.id, content: content, tokenFacts: tokenFacts)
                    }
                )
            }
        )

        let projection = try await service.project(.init(
            promptText: "user prompt",
            alternatePolicy: .init(includeFiles: true, codeMapUsage: .none),
            nonFileTokenComponents: .init(prompt: 2, fileTree: 1, meta: 0, git: 0)
        ))

        XCTAssertEqual(projection.prompt?.value, "user prompt")
        XCTAssertEqual(projection.selection?.value.files.map(\.mode), [.full, .slice, .codemap])
        XCTAssertEqual(projection.selection?.value.files.map(\.tokens), [12, 3, codemapTokens])
        XCTAssertEqual(projection.selection?.value.slices.map(\.ranges), [ranges])
        XCTAssertEqual(projection.selection?.value.summary, .init(
            fullCount: 1,
            sliceCount: 1,
            codemapCount: 1,
            fullTokens: 12,
            sliceTokens: 3,
            codemapTokens: codemapTokens
        ))

        let blocks = try XCTUnwrap(projection.fileBlocks?.value)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertTrue(blocks[0].contains("File: Full.swift"))
        XCTAssertTrue(blocks[0].contains("full body"))
        XCTAssertTrue(blocks[1].contains("(lines 2: middle)"))
        XCTAssertTrue(blocks[1].contains("two"))
        XCTAssertFalse(blocks[1].contains("one"))
        XCTAssertTrue(blocks[2].contains("CodeSymbol"))

        let code = try XCTUnwrap(projection.codeStructure?.value)
        XCTAssertEqual(code.renderedPaths, ["Code.swift"])
        XCTAssertEqual(code.unmappedPaths, ["Full.swift", "Slice.swift"])
        XCTAssertTrue(code.content.contains("CodeSymbol"))

        let tree = try XCTUnwrap(projection.fileTree?.value)
        XCTAssertEqual(tree.rootCount, 1)
        XCTAssertTrue(tree.usesLegend)
        XCTAssertTrue(tree.content.contains("Full.swift"))

        let tokens = try XCTUnwrap(projection.tokens?.value)
        XCTAssertEqual(tokens.normalized.total, 12 + 3 + codemapTokens + 3)
        XCTAssertEqual(tokens.normalized.components.files, 12 + 3 + codemapTokens)
        XCTAssertEqual(tokens.normalized.components.filesContent, 15)
        XCTAssertEqual(tokens.normalized.components.codemaps, codemapTokens)
        XCTAssertEqual(tokens.normalized.components.prompt, 2)
        XCTAssertEqual(tokens.normalized.components.fileTree, 1)
        XCTAssertNil(tokens.normalized.components.meta)
        XCTAssertEqual(tokens.userConfigured?.total, 18)
        XCTAssertEqual(tokens.userConfigured?.components.files, 15)
        XCTAssertEqual(tokens.userConfigured?.components.codemaps, nil)
        assertAllPresentSections(projection, have: fixture.capture.provenance)
    }

    func testNilContentOmitsBlockWhileEmptyContentEmitsEmptyFence() async throws {
        let root = makeRoot()
        let nilFile = makeFile(root: root, path: "Nil.swift")
        let emptyFile = makeFile(root: root, path: "Empty.swift")
        let capture = makeCapture(
            root: root,
            files: [nilFile, emptyFile],
            selection: StoredSelection(selectedPaths: [nilFile.fullPath, emptyFile.fullPath]),
            selectedPaths: [
                .init(input: nilFile.fullPath, resolution: .file(nilFile)),
                .init(input: emptyFile.fullPath, resolution: .file(emptyFile))
            ]
        )
        let service = WorkspaceContextProjectionService(
            capture: { capture },
            materializer: { request in
                .init(
                    provenance: request.provenance,
                    occurrences: request.occurrences.map { occurrence in
                        .init(
                            id: occurrence.id,
                            content: occurrence.file.id == nilFile.id ? nil : "",
                            tokenFacts: nil
                        )
                    }
                )
            }
        )

        let projection = try await service.project(.init(sections: [.files]))
        let blocks = try XCTUnwrap(projection.fileBlocks?.value)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].contains("File: Empty.swift"))
        XCTAssertTrue(blocks[0].contains("```swift\n\n```"))
        XCTAssertFalse(blocks[0].contains("Nil.swift"))
    }

    func testProvenanceMismatchIsRejectedAndEveryPresentSectionUsesCaptureProvenance() async throws {
        let capture = makeSingleFileCapture()
        let mismatched = WorkspaceFileContextCapture.Provenance(
            captureGeneration: capture.provenance.captureGeneration + 1,
            catalogGeneration: capture.provenance.catalogGeneration,
            catalogValidationToken: capture.provenance.catalogValidationToken,
            rootScope: capture.provenance.rootScope,
            ingressSamples: capture.provenance.ingressSamples
        )
        let mismatchService = WorkspaceContextProjectionService(
            capture: { capture },
            materializer: { request in
                .init(
                    provenance: mismatched,
                    occurrences: request.occurrences.map {
                        .init(id: $0.id, content: "body", tokenFacts: nil)
                    }
                )
            }
        )

        do {
            _ = try await mismatchService.project(.init(sections: [.files]))
            XCTFail("Expected materialization provenance mismatch")
        } catch let error as WorkspaceContextProjectionError {
            XCTAssertEqual(error, .materializationProvenanceMismatch)
        }

        let invalidCapture = copyCapture(
            capture,
            provenance: .init(
                captureGeneration: capture.provenance.captureGeneration,
                catalogGeneration: capture.provenance.catalogGeneration + 1,
                catalogValidationToken: capture.provenance.catalogValidationToken,
                rootScope: capture.provenance.rootScope,
                ingressSamples: capture.provenance.ingressSamples
            )
        )
        let invalidCaptureService = WorkspaceContextProjectionService(
            capture: { invalidCapture },
            materializer: { request in .init(provenance: request.provenance, occurrences: []) }
        )
        do {
            _ = try await invalidCaptureService.project(.init(sections: []))
            XCTFail("Expected capture provenance mismatch")
        } catch let error as WorkspaceContextProjectionError {
            XCTAssertEqual(error, .captureProvenanceMismatch)
        }
    }

    func testMissingUnexpectedAndDuplicateMaterializationOccurrenceIDsAreRejected() async throws {
        let capture = makeSingleFileCapture()
        let expectedID = WorkspaceContextProjectionMaterializationRequest.OccurrenceID(rawValue: 0)
        let unexpectedID = WorkspaceContextProjectionMaterializationRequest.OccurrenceID(rawValue: 99)

        let missingService = WorkspaceContextProjectionService(
            capture: { capture },
            materializer: { request in .init(provenance: request.provenance, occurrences: []) }
        )
        do {
            _ = try await missingService.project(.init(sections: [.files]))
            XCTFail("Expected missing occurrence ID")
        } catch let error as WorkspaceContextProjectionError {
            XCTAssertEqual(error, .missingOccurrenceIDs([expectedID]))
        }

        let unexpectedService = WorkspaceContextProjectionService(
            capture: { capture },
            materializer: { request in
                .init(provenance: request.provenance, occurrences: [
                    .init(id: expectedID, content: "body", tokenFacts: nil),
                    .init(id: unexpectedID, content: "extra", tokenFacts: nil)
                ])
            }
        )
        do {
            _ = try await unexpectedService.project(.init(sections: [.files]))
            XCTFail("Expected unexpected occurrence ID")
        } catch let error as WorkspaceContextProjectionError {
            XCTAssertEqual(error, .unexpectedOccurrenceIDs([unexpectedID]))
        }

        let duplicateService = WorkspaceContextProjectionService(
            capture: { capture },
            materializer: { request in
                .init(provenance: request.provenance, occurrences: [
                    .init(id: expectedID, content: "first", tokenFacts: nil),
                    .init(id: expectedID, content: "second", tokenFacts: nil)
                ])
            }
        )
        do {
            _ = try await duplicateService.project(.init(sections: [.files]))
            XCTFail("Expected duplicate occurrence ID")
        } catch let error as WorkspaceContextProjectionError {
            XCTAssertEqual(error, .duplicateOccurrenceID(expectedID))
        }
    }

    func testRequiredAndModeBoundTokenFactsAreValidatedWithZeroSemantics() async throws {
        let capture = makeSingleFileCapture()
        let missingService = WorkspaceContextProjectionService(
            capture: { capture },
            materializer: { request in
                .init(
                    provenance: request.provenance,
                    occurrences: request.occurrences.map {
                        .init(id: $0.id, content: "body", tokenFacts: nil)
                    }
                )
            }
        )
        do {
            _ = try await missingService.project(.init(sections: [.selection]))
            XCTFail("Expected required token facts")
        } catch let error as WorkspaceContextProjectionError {
            XCTAssertEqual(error, .missingTokenFacts(.init(rawValue: 0)))
        }

        let invalidService = WorkspaceContextProjectionService(
            capture: { capture },
            materializer: { request in
                .init(
                    provenance: request.provenance,
                    occurrences: request.occurrences.map {
                        .init(
                            id: $0.id,
                            content: "body",
                            tokenFacts: .init(displayTokens: 1, fullTokens: 2)
                        )
                    }
                )
            }
        )
        do {
            _ = try await invalidService.project(.init(sections: [.selection]))
            XCTFail("Expected mode-bound token validation")
        } catch let error as WorkspaceContextProjectionError {
            XCTAssertEqual(error, .invalidTokenFacts(.init(rawValue: 0)))
        }

        let zeroService = WorkspaceContextProjectionService(
            capture: { capture },
            materializer: { request in
                .init(
                    provenance: request.provenance,
                    occurrences: request.occurrences.map {
                        .init(
                            id: $0.id,
                            content: "",
                            tokenFacts: .init(displayTokens: 0, fullTokens: 0)
                        )
                    }
                )
            }
        )
        let zero = try await zeroService.project(.init(sections: [.tokens]))
        XCTAssertEqual(zero.tokens?.value.normalized.total, 0)
        XCTAssertEqual(zero.tokens?.value.normalized.components.files, 0)
        XCTAssertNil(zero.tokens?.value.normalized.components.filesContent)
        XCTAssertNil(zero.tokens?.value.normalized.components.codemaps)
        XCTAssertNil(zero.tokens?.value.userConfigured)
    }

    func testRootAndCodemapAssociationsAreValidatedBeforeMaterialization() async throws {
        let base = makeSingleFileCapture(includeCodemap: true)
        let file = try XCTUnwrap(base.materializedFiles.first)
        let wrongRootFile = WorkspaceFileRecord(
            id: file.id,
            rootID: UUID(),
            name: file.name,
            relativePath: file.relativePath,
            fullPath: file.fullPath,
            parentFolderID: file.parentFolderID
        )
        let wrongRoot = copyCapture(
            base,
            selectedPaths: [.init(input: wrongRootFile.fullPath, resolution: .file(wrongRootFile))],
            materializedFiles: [wrongRootFile],
            codemapSnapshots: []
        )
        let wrongRootService = WorkspaceContextProjectionService(
            capture: { wrongRoot },
            materializer: { request in .init(provenance: request.provenance, occurrences: []) }
        )
        do {
            _ = try await wrongRootService.project(.init(sections: []))
            XCTFail("Expected root association failure")
        } catch let error as WorkspaceContextProjectionError {
            XCTAssertEqual(error, .rootAssociationMismatch(recordID: file.id, rootID: wrongRootFile.rootID))
        }

        let codemap = try XCTUnwrap(base.codemapSnapshots.first)
        let wrongCodemap = WorkspaceCodemapSnapshot(
            fileID: codemap.fileID,
            rootID: codemap.rootID,
            rootPath: "/wrong/root",
            relativePath: codemap.relativePath,
            fullPath: codemap.fullPath,
            modificationDate: codemap.modificationDate,
            fileAPI: codemap.fileAPI
        )
        let wrongCodemapCapture = copyCapture(base, codemapSnapshots: [wrongCodemap])
        let wrongCodemapService = WorkspaceContextProjectionService(
            capture: { wrongCodemapCapture },
            materializer: { request in .init(provenance: request.provenance, occurrences: []) }
        )
        do {
            _ = try await wrongCodemapService.project(.init(sections: []))
            XCTFail("Expected codemap association failure")
        } catch let error as WorkspaceContextProjectionError {
            XCTAssertEqual(error, .codemapAssociationMismatch(file.id))
        }
    }

    func testCaptureAndMaterializerErrorsPropagateUnchanged() async throws {
        enum Sentinel: Error, Equatable {
            case capture
            case materializer
        }

        let captureErrorService = WorkspaceContextProjectionService(
            capture: { throw Sentinel.capture },
            materializer: { request in .init(provenance: request.provenance, occurrences: []) }
        )
        do {
            _ = try await captureErrorService.project(.init())
            XCTFail("Expected capture error")
        } catch let error as Sentinel {
            XCTAssertEqual(error, .capture)
        }

        let capture = makeSingleFileCapture()
        let materializerErrorService = WorkspaceContextProjectionService(
            capture: { capture },
            materializer: { _ in throw Sentinel.materializer }
        )
        do {
            _ = try await materializerErrorService.project(.init(sections: [.files]))
            XCTFail("Expected materializer error")
        } catch let error as Sentinel {
            XCTAssertEqual(error, .materializer)
        }
    }

    func testCancellationIsCheckedAfterCaptureAndMaterialization() async throws {
        let capture = makeSingleFileCapture()
        var materializerCalled = false
        let captureCancelledService = WorkspaceContextProjectionService(
            capture: {
                withUnsafeCurrentTask { $0?.cancel() }
                return capture
            },
            materializer: { request in
                materializerCalled = true
                return .init(provenance: request.provenance, occurrences: [])
            }
        )
        let captureTask = Task {
            try await captureCancelledService.project(.init(sections: [.files]))
        }
        do {
            _ = try await captureTask.value
            XCTFail("Expected cancellation after capture")
        } catch is CancellationError {
            XCTAssertFalse(materializerCalled)
        }

        let materializerCancelledService = WorkspaceContextProjectionService(
            capture: { capture },
            materializer: { request in
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(
                    provenance: request.provenance,
                    occurrences: request.occurrences.map {
                        .init(id: $0.id, content: "body", tokenFacts: nil)
                    }
                )
            }
        )
        let materializerTask = Task {
            try await materializerCancelledService.project(.init(sections: [.files]))
        }
        do {
            _ = try await materializerTask.value
            XCTFail("Expected cancellation after materialization")
        } catch is CancellationError {}
    }

    func testDuplicateCaptureSelectionsUseFirstIdenticalOccurrenceButPreserveDistinctModes() async throws {
        let root = makeRoot()
        let rootFolder = makeRootFolder(root)
        let fileA = makeFile(root: root, path: "A.swift", parentFolderID: rootFolder.id)
        let fileB = makeFile(root: root, path: "B.swift", parentFolderID: rootFolder.id)
        let ranges = [LineRange(start: 2, end: 2)]
        let folderPath = WorkspaceFileContextCapture.SelectionPath(
            input: root.fullPath,
            resolution: .folder(rootFolder, descendantFiles: [fileA, fileB])
        )
        let capture = makeCapture(
            root: root,
            files: [fileA, fileB],
            folders: [rootFolder],
            selection: StoredSelection(
                selectedPaths: [fileB.fullPath, root.fullPath, root.fullPath],
                slices: [fileB.fullPath: ranges]
            ),
            selectedPaths: [
                .init(input: fileB.fullPath, resolution: .file(fileB)),
                folderPath,
                folderPath
            ],
            slices: [.init(path: fileB.fullPath, ranges: ranges, file: fileB, issue: nil)]
        )
        let service = WorkspaceContextProjectionService(
            capture: { capture },
            materializer: { request in
                XCTAssertEqual(request.occurrences.map(\.file.standardizedRelativePath), [
                    "B.swift",
                    "A.swift",
                    "B.swift"
                ])
                XCTAssertEqual(request.occurrences.map(\.mode), [.slice, .full, .full])
                return .init(
                    provenance: request.provenance,
                    occurrences: request.occurrences.map { occurrence in
                        let display = occurrence.mode == .slice ? 1 : 2
                        return .init(
                            id: occurrence.id,
                            content: "one\ntwo",
                            tokenFacts: .init(displayTokens: display, fullTokens: 2)
                        )
                    }
                )
            }
        )

        let projection = try await service.project(.init(sections: [.selection]))

        XCTAssertEqual(projection.selection?.value.files.map(\.file.standardizedRelativePath), [
            "B.swift",
            "A.swift",
            "B.swift"
        ])
        XCTAssertEqual(projection.selection?.value.files.map(\.mode), [.slice, .full, .full])
        XCTAssertEqual(projection.selection?.value.summary.sliceCount, 1)
        XCTAssertEqual(projection.selection?.value.summary.fullCount, 2)
    }

    private struct FullSliceCodemapFixture {
        let capture: WorkspaceFileContextCapture
        let codemap: WorkspaceCodemapSnapshot
    }

    private func makeFullSliceCodemapCapture() -> FullSliceCodemapFixture {
        let root = makeRoot()
        let rootFolder = makeRootFolder(root)
        let full = makeFile(root: root, path: "Full.swift", parentFolderID: rootFolder.id)
        let slice = makeFile(root: root, path: "Slice.swift", parentFolderID: rootFolder.id)
        let code = makeFile(root: root, path: "Code.swift", parentFolderID: rootFolder.id)
        let ranges = [LineRange(start: 2, end: 2, description: "middle")]
        let codemap = makeCodemap(file: code, root: root, symbol: "CodeSymbol")
        let tree = FileTreeSelectionSnapshot(
            roots: [.init(
                id: rootFolder.id,
                name: root.name,
                fullPath: root.fullPath,
                standardizedFullPath: root.standardizedFullPath,
                standardizedRootPath: root.standardizedFullPath,
                children: [full, slice, code].map {
                    .file(.init(
                        id: $0.id,
                        name: $0.name,
                        fileExtension: "swift",
                        hasCodeMap: $0.id == code.id
                    ))
                }
            )],
            selectedFileIDs: [full.id, slice.id, code.id],
            mode: "selected",
            showFullPaths: false,
            onlyIncludeRootsWithSelectedFiles: false,
            includeLegend: true
        )
        let capture = makeCapture(
            root: root,
            files: [full, slice, code],
            folders: [rootFolder],
            selection: StoredSelection(
                selectedPaths: [full.fullPath, slice.fullPath],
                autoCodemapPaths: [code.fullPath],
                slices: [slice.fullPath: ranges]
            ),
            selectedPaths: [
                .init(input: full.fullPath, resolution: .file(full)),
                .init(input: slice.fullPath, resolution: .file(slice))
            ],
            autoCodemapPaths: [.init(input: code.fullPath, resolution: .file(code))],
            slices: [.init(path: slice.fullPath, ranges: ranges, file: slice, issue: nil)],
            codemapSnapshots: [codemap],
            fileTree: tree
        )
        return FullSliceCodemapFixture(capture: capture, codemap: codemap)
    }

    private func makeSingleFileCapture(includeCodemap: Bool = false) -> WorkspaceFileContextCapture {
        let root = makeRoot()
        let file = makeFile(root: root, path: "Only.swift")
        let codemaps = includeCodemap ? [makeCodemap(file: file, root: root, symbol: "OnlySymbol")] : []
        return makeCapture(
            root: root,
            files: [file],
            selection: StoredSelection(selectedPaths: [file.fullPath]),
            selectedPaths: [.init(input: file.fullPath, resolution: .file(file))],
            codemapSnapshots: codemaps
        )
    }

    private func makeEmptyCapture() -> WorkspaceFileContextCapture {
        makeCapture(
            root: makeRoot(),
            files: [],
            selection: StoredSelection(),
            selectedPaths: []
        )
    }

    private func makeCapture(
        root: WorkspaceRootRecord,
        files: [WorkspaceFileRecord],
        folders: [WorkspaceFolderRecord] = [],
        selection: StoredSelection,
        selectedPaths: [WorkspaceFileContextCapture.SelectionPath],
        autoCodemapPaths: [WorkspaceFileContextCapture.SelectionPath] = [],
        slices: [WorkspaceFileContextCapture.Slice] = [],
        codemapSnapshots: [WorkspaceCodemapSnapshot] = [],
        fileTree: FileTreeSelectionSnapshot? = nil
    ) -> WorkspaceFileContextCapture {
        let generation: UInt64 = 7
        let provenance = WorkspaceFileContextCapture.Provenance(
            captureGeneration: 11,
            catalogGeneration: generation,
            catalogValidationToken: 13,
            rootScope: .visibleWorkspace,
            ingressSamples: []
        )
        let diagnostics = WorkspaceCatalogDiagnostics(
            generation: generation,
            rootScope: .visibleWorkspace,
            rootCount: 1,
            folderCount: folders.count,
            fileCount: files.count
        )
        let catalog = WorkspaceSearchCatalogSnapshot(
            generation: generation,
            rootScope: .visibleWorkspace,
            roots: [root],
            files: files,
            entries: files.map { WorkspaceSearchCatalogEntry(file: $0, root: root) },
            diagnostics: diagnostics
        )
        return WorkspaceFileContextCapture(
            provenance: provenance,
            storedSelection: selection,
            selectedPaths: selectedPaths,
            autoCodemapPaths: autoCodemapPaths,
            slices: slices,
            catalog: catalog,
            materializedFolders: folders,
            materializedFiles: files,
            codemapSnapshots: codemapSnapshots,
            fileTree: fileTree ?? .init(
                roots: [],
                selectedFileIDs: Set(files.map(\.id)),
                mode: "none",
                showFullPaths: false,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false
            )
        )
    }

    private func copyCapture(
        _ capture: WorkspaceFileContextCapture,
        provenance: WorkspaceFileContextCapture.Provenance? = nil,
        selectedPaths: [WorkspaceFileContextCapture.SelectionPath]? = nil,
        materializedFiles: [WorkspaceFileRecord]? = nil,
        codemapSnapshots: [WorkspaceCodemapSnapshot]? = nil
    ) -> WorkspaceFileContextCapture {
        WorkspaceFileContextCapture(
            provenance: provenance ?? capture.provenance,
            storedSelection: capture.storedSelection,
            selectedPaths: selectedPaths ?? capture.selectedPaths,
            autoCodemapPaths: capture.autoCodemapPaths,
            slices: capture.slices,
            catalog: capture.catalog,
            materializedFolders: capture.materializedFolders,
            materializedFiles: materializedFiles ?? capture.materializedFiles,
            codemapSnapshots: codemapSnapshots ?? capture.codemapSnapshots,
            fileTree: capture.fileTree
        )
    }

    private func makeRoot() -> WorkspaceRootRecord {
        WorkspaceRootRecord(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Repo",
            fullPath: "/repo"
        )
    }

    private func makeRootFolder(_ root: WorkspaceRootRecord) -> WorkspaceFolderRecord {
        WorkspaceFolderRecord(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            rootID: root.id,
            name: root.name,
            relativePath: "",
            fullPath: root.fullPath,
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

    private func assertAllPresentSections(
        _ projection: WorkspaceContextProjection,
        have provenance: WorkspaceFileContextCapture.Provenance,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(projection.prompt?.provenance, provenance, file: file, line: line)
        XCTAssertEqual(projection.selection?.provenance, provenance, file: file, line: line)
        XCTAssertEqual(projection.fileBlocks?.provenance, provenance, file: file, line: line)
        XCTAssertEqual(projection.codeStructure?.provenance, provenance, file: file, line: line)
        XCTAssertEqual(projection.fileTree?.provenance, provenance, file: file, line: line)
        XCTAssertEqual(projection.tokens?.provenance, provenance, file: file, line: line)
    }
}
