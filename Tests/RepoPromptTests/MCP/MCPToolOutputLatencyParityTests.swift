#if DEBUG
    import MCP
    @testable import RepoPromptApp
    import XCTest

    final class MCPToolOutputLatencyParityTests: XCTestCase {
        func testFileTreeRendererModesAndMarkersRemainByteExact() async throws {
            let selectedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000101"))
            let otherID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000102"))
            let sourceFolder = try WorkspaceFileTreeFolderPresentation(
                id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000201")),
                name: "Sources",
                fullPath: "/fixture/Project/Sources",
                standardizedFullPath: "/fixture/Project/Sources",
                standardizedRootPath: "/fixture/Project",
                children: [
                    .file(WorkspaceFileTreeFilePresentation(
                        id: selectedID,
                        name: "Selected.swift",
                        fileExtension: "swift",
                        hasCodeMap: true
                    )),
                    .file(WorkspaceFileTreeFilePresentation(
                        id: otherID,
                        name: "Other.swift",
                        fileExtension: "swift",
                        hasCodeMap: false
                    ))
                ]
            )
            let root = try WorkspaceFileTreeFolderPresentation(
                id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000301")),
                name: "Project",
                fullPath: "/fixture/Project",
                standardizedFullPath: "/fixture/Project",
                standardizedRootPath: "/fixture/Project",
                children: [
                    .folder(sourceFolder),
                    .file(WorkspaceFileTreeFilePresentation(
                        id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000103")),
                        name: "README.md",
                        fileExtension: "md",
                        hasCodeMap: false
                    ))
                ]
            )

            let unselectedRoot = try WorkspaceFileTreeFolderPresentation(
                id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000302")),
                name: "Unselected",
                fullPath: "/fixture/Unselected",
                standardizedFullPath: "/fixture/Unselected",
                standardizedRootPath: "/fixture/Unselected",
                children: [
                    .file(WorkspaceFileTreeFilePresentation(
                        id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000104")),
                        name: "Only.swift",
                        fileExtension: "swift",
                        hasCodeMap: false
                    ))
                ]
            )

            let expectedByMode = [
                "full": "Project\n├── Sources\n│   ├── Selected.swift * +\n│   └── Other.swift\n└── README.md\n\n\n(* denotes selected files)\n(+ denotes code-map available)",
                "folders": "Project\n└── Sources\n    └── Selected.swift * +\n\n\n(* denotes selected files)\n(+ denotes code-map available)",
                "selected": "Project\n└── Sources\n    └── Selected.swift * +\n\n\n(* denotes selected files)\n(+ denotes code-map available)",
                "auto": "Project\n├── Sources\n│   ├── Selected.swift * +\n│   └── Other.swift\n└── README.md\n\n\n(* denotes selected files)\n(+ denotes code-map available)"
            ]

            for mode in ["full", "folders", "selected", "auto"] {
                let snapshot = WorkspaceFileTreePresentationSnapshot(
                    roots: [root, unselectedRoot],
                    selectedFileIDs: [selectedID],
                    mode: mode,
                    showFullPaths: false,
                    onlyIncludeRootsWithSelectedFiles: true,
                    includeLegend: true,
                    showCodeMapMarkers: true
                )
                XCTAssertEqual(
                    WorkspaceFileTreePresentationRenderer.render(snapshot),
                    expectedByMode[mode],
                    mode
                )
            }

            let mcpTree = WorkspaceFileTreePresentationRenderer.render(WorkspaceFileTreePresentationSnapshot(
                roots: [root, unselectedRoot],
                selectedFileIDs: [selectedID],
                mode: "full",
                showFullPaths: false,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: true,
                showCodeMapMarkers: true
            ))
            XCTAssertEqual(
                mcpTree,
                "Project\n├── Sources\n│   ├── Selected.swift * +\n│   └── Other.swift\n└── README.md\n\n\nUnselected\n└── Only.swift\n\n\n(* denotes selected files)\n(+ denotes code-map available)"
            )

            let fullPathTree = WorkspaceFileTreePresentationRenderer.render(WorkspaceFileTreePresentationSnapshot(
                roots: [sourceFolder],
                selectedFileIDs: [],
                mode: "full",
                showFullPaths: true,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: false
            ))
            XCTAssertEqual(fullPathTree, "/fixture/Project/Sources\n├── Other.swift\n└── Selected.swift\n")

            let depthCapped = WorkspaceFileTreePresentationRenderer.render(WorkspaceFileTreePresentationSnapshot(
                roots: [root],
                selectedFileIDs: [selectedID],
                mode: "full",
                showFullPaths: false,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: true,
                showCodeMapMarkers: true,
                maxDepth: 0
            ))
            XCTAssertEqual(
                depthCapped,
                "Project\n├── Sources\n│   ├── Selected.swift * +\n│   ├── ...\n└── README.md\n\n\n(* denotes selected files)\n(+ denotes code-map available)"
            )

            let longName = String(repeating: "Long", count: 120)
            let generatedChildren: [WorkspaceFileTreeNodePresentation] = try (0 ..< 101).map { index in
                try .file(WorkspaceFileTreeFilePresentation(
                    id: XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", index))),
                    name: "\(longName)-\(index).swift",
                    fileExtension: "swift",
                    hasCodeMap: false
                ))
            }
            let cappedChildren: [WorkspaceFileTreeNodePresentation] = [
                .file(WorkspaceFileTreeFilePresentation(
                    id: selectedID,
                    name: "Selected.swift",
                    fileExtension: "swift",
                    hasCodeMap: false
                ))
            ] + generatedChildren
            let cappedRoot = try WorkspaceFileTreeFolderPresentation(
                id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000303")),
                name: "Capped",
                fullPath: "/fixture/Capped",
                standardizedFullPath: "/fixture/Capped",
                standardizedRootPath: "/fixture/Capped",
                children: cappedChildren
            )
            XCTAssertEqual(
                WorkspaceFileTreePresentationRenderer.render(WorkspaceFileTreePresentationSnapshot(
                    roots: [cappedRoot],
                    selectedFileIDs: [selectedID],
                    mode: "auto",
                    showFullPaths: false,
                    onlyIncludeRootsWithSelectedFiles: false,
                    includeLegend: true,
                    showCodeMapMarkers: false
                )),
                "Capped\n└── Selected.swift *\n\n\n(* denotes selected files)\nConfig: directory-only view; selected files shown."
            )

            let duplicateRoot = try WorkspaceFileTreeFolderPresentation(
                id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000304")),
                name: "DuplicateSafe",
                fullPath: "/fixture/DuplicateSafe",
                standardizedFullPath: "/fixture/DuplicateSafe",
                standardizedRootPath: "/fixture/DuplicateSafe",
                children: []
            )
            let duplicateChild = WorkspaceFileTreeFolderPresentation(
                id: duplicateRoot.id,
                name: "Cycle",
                fullPath: "/fixture/DuplicateSafe/Cycle",
                standardizedFullPath: "/fixture/DuplicateSafe/Cycle",
                standardizedRootPath: "/fixture/DuplicateSafe",
                children: []
            )
            let duplicateSafeRoot = WorkspaceFileTreeFolderPresentation(
                id: duplicateRoot.id,
                name: duplicateRoot.name,
                fullPath: duplicateRoot.fullPath,
                standardizedFullPath: duplicateRoot.standardizedFullPath,
                standardizedRootPath: duplicateRoot.standardizedRootPath,
                children: [.folder(duplicateChild)]
            )
            XCTAssertEqual(
                WorkspaceFileTreePresentationRenderer.render(WorkspaceFileTreePresentationSnapshot(
                    roots: [duplicateSafeRoot],
                    selectedFileIDs: [],
                    mode: "full",
                    showFullPaths: false,
                    onlyIncludeRootsWithSelectedFiles: false,
                    includeLegend: false,
                    showCodeMapMarkers: false
                )),
                "DuplicateSafe\n"
            )

            let cancelled = Task {
                try? await Task.sleep(for: .milliseconds(25))
                return WorkspaceFileTreePresentationRenderer.render(WorkspaceFileTreePresentationSnapshot(
                    roots: [root],
                    selectedFileIDs: [selectedID],
                    mode: "full",
                    showFullPaths: false,
                    onlyIncludeRootsWithSelectedFiles: false,
                    includeLegend: true,
                    showCodeMapMarkers: true
                ))
            }
            cancelled.cancel()
            let cancelledOutput = await cancelled.value
            XCTAssertEqual(cancelledOutput, "")
        }

        func testFileTreeFormattedRawLegacyAndMalformedContentBlocksRemainByteExact() throws {
            let dto = ToolResultDTOs.FileTreeDTO(
                rootsCount: 1,
                usesLegend: true,
                tree: "Project\n└── Sources\n    └── Selected.swift * +",
                note: "depth cap 3",
                wasTruncated: false
            )
            let value = try Value(dto)
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.buildContentBlocks(
                    toolName: "get_file_tree",
                    args: [:],
                    result: value,
                    emitResources: true
                )),
                """
                ## File Tree ✅
                - **Roots**: 1
                - **Selected markers**: yes
                - **Note**: '...' indicates truncated content
                - **Config**: depth cap 3

                (* denotes selected files)
                (+ denotes code-map available)

                Project
                └── Sources
                    └── Selected.swift * +
                """
            )
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.buildContentBlocks(
                    toolName: "get_file_tree",
                    args: ["_rawJSON": .bool(true)],
                    result: value,
                    emitResources: true
                )),
                #"{"note":"depth cap 3","roots_count":1,"tree":"Project\n└── Sources\n    └── Selected.swift * +","uses_legend":true,"was_truncated":false}"#
            )
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.formatFileTree(value: .string("legacy tree"))),
                "legacy tree"
            )
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.formatFileTree(value: .object(["unexpected": .bool(true)]))),
                """
                ```json
                {
                  "unexpected" : true
                }
                ```
                """
            )

            let missingPath = try Value(ToolResultDTOs.FileTreeDTO(
                rootsCount: 0,
                usesLegend: false,
                tree: "Loaded roots: Project → /fixture/Project",
                note: "Requested path is outside the loaded roots",
                wasTruncated: false,
                worktreeScope: scope()
            ))
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.formatFileTree(value: missingPath)),
                """
                ## File Tree ✅
                - **Roots**: 0
                - **Selected markers**: no
                - **Note**: '...' indicates truncated content
                - **Config**: Requested path is outside the loaded roots
                - **Scope**: session-bound worktree. Displayed paths use logical/canonical roots; filesystem reads use that bound checkout.
                - **Root remapping**:
                  - `Project` → session-bound worktree (worktree `wt_fixture`, name `feature`, branch `feature/latency`, label `Latency Fixture`)

                Loaded roots: Project → /fixture/Project
                """
            )

            let empty = try Value(ToolResultDTOs.FileTreeDTO(
                rootsCount: 0,
                usesLegend: false,
                tree: "",
                note: "No workspace loaded",
                wasTruncated: false
            ))
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.formatFileTree(value: empty)),
                """
                ## File Tree ✅
                - **Roots**: 0
                - **Selected markers**: no
                - **Note**: '...' indicates truncated content
                - **Config**: No workspace loaded
                """
            )
        }

        func testSearchFormattedRawErrorAndOrderingRemainByteExact() throws {
            let dto = ToolResultDTOs.SearchResultDTO(
                totalMatches: 2,
                totalFiles: 1,
                matchedFiles: 1,
                searchedFiles: 3,
                contentMatches: 1,
                pathMatches: 1,
                limitHit: false,
                perFileCounts: [.init(path: "Sources/A.swift", count: 1)],
                pathMatchLines: ["Sources/A.swift"],
                contentMatchGroups: [.init(
                    path: "Sources/A.swift",
                    lines: [.init(
                        lineNumber: 2,
                        lineText: "needle",
                        contextBefore: [.init(lineNumber: 1, lineText: "before")],
                        contextAfter: [.init(lineNumber: 4, lineText: "after")]
                    )]
                )],
                suggestion: "Use a narrower scope.",
                warning: "fixture warning",
                perFileTotals: [.init(path: "Sources/A.swift", count: 1)]
            )
            let value = try Value(dto)
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.buildContentBlocks(
                    toolName: "file_search",
                    args: [:],
                    result: value,
                    emitResources: true
                )),
                """
                ## Search Results ✅
                - **Total matches**: 2 across 1 matching file (searched 3 files)
                - **Content matches**: 1 • **Path matches**: 1
                - **Status**: Complete (limit not reached)
                - **Warning**: fixture warning
                - **Top files**: A.swift (1)

                ### Matches
                Sources/
                └── A.swift — 1 match (showing all) • path match
                                1 │   before
                                2 │ ▶ needle
                                  │   ⋮
                                4 │   after

                ### Suggestion
                Use a narrower scope.
                """
            )
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.buildContentBlocks(
                    toolName: "file_search",
                    args: ["_rawJSON": .bool(true)],
                    result: value,
                    emitResources: true
                )),
                "{\"content_match_groups\":[{\"lines\":[{\"context_after\":[{\"line_number\":4,\"line_text\":\"after\"}],\"context_before\":[{\"line_number\":1,\"line_text\":\"before\"}],\"line_number\":2,\"line_text\":\"needle\"}],\"path\":\"Sources/A.swift\"}],\"content_matches\":1,\"limit_hit\":false,\"matched_files\":1,\"path_match_lines\":[\"Sources/A.swift\"],\"path_matches\":1,\"per_file_counts\":[{\"count\":1,\"path\":\"Sources/A.swift\"}],\"per_file_totals\":[{\"count\":1,\"path\":\"Sources/A.swift\"}],\"searched_files\":3,\"suggestion\":\"Use a narrower scope.\",\"total_files\":1,\"total_matches\":2,\"warning\":\"fixture warning\"}"
            )

            let error = ToolResultDTOs.SearchResultDTO(
                totalMatches: 0,
                totalFiles: 0,
                contentMatches: 0,
                pathMatches: 0,
                limitHit: false,
                perFileCounts: [],
                pathMatchLines: [],
                contentMatchGroups: [],
                errorMessage: "Workspace is still settling.",
                errorCode: "workspace_freshness_timeout",
                retryable: true,
                retryAfterMilliseconds: 1000,
                suggestion: "Retry this call."
            )
            let errorValue = try Value(error)
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.formatSearch(value: errorValue)),
                """
                ## Search Results ⚠️
                - **Status**: Workspace freshness timed out
                - **Error**: Workspace is still settling.
                - **Code**: workspace_freshness_timeout
                - **Retryable**: yes
                - **Retry after**: 1000 ms
                - **Suggestion**: Retry this call.
                """
            )
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.buildContentBlocks(
                    toolName: "file_search",
                    args: ["_rawJSON": .bool(true)],
                    result: errorValue,
                    emitResources: true
                )),
                #"{"content_match_groups":[],"content_matches":0,"error":"Workspace is still settling.","error_code":"workspace_freshness_timeout","limit_hit":false,"path_match_lines":[],"path_matches":0,"per_file_counts":[],"retry_after_ms":1000,"retryable":true,"suggestion":"Retry this call.","total_files":0,"total_matches":0}"#
            )

            let countOnlyCapped = try Value(ToolResultDTOs.SearchResultDTO(
                totalMatches: 100,
                totalFiles: 2,
                matchedFiles: 2,
                searchedFiles: 500,
                contentMatches: 100,
                pathMatches: 0,
                limitHit: true,
                perFileCounts: [],
                pathMatchLines: [],
                contentMatchGroups: [],
                sizeLimitHit: true,
                omittedTotal: 95,
                omittedContentMatches: 95,
                omittedPathMatches: 0,
                perFileTotals: [
                    .init(path: "Sources/A.swift", count: 60),
                    .init(path: "Tests/B.swift", count: 40)
                ],
                worktreeScope: scope()
            ))
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.formatSearch(value: countOnlyCapped)),
                """
                ## Search Results ✅
                - **Total matches**: 100 across 2 matching files (searched 500 files)
                - **Content matches**: 100 • **Path matches**: 0
                - **Status**: Partial (limit reached)
                - **Scope**: session-bound worktree. Displayed paths use logical/canonical roots; filesystem searches use that bound checkout.
                - **Root remapping**:
                  - `Project` → session-bound worktree (worktree `wt_fixture`, name `feature`, branch `feature/latency`, label `Latency Fixture`)
                - **Top files**: A.swift (60), B.swift (40)
                - **Omitted**: 95 results trimmed by response size cap (95 content)
                """
            )
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.formatSearch(value: .string("legacy matches"))),
                "## Search Results ✅\nlegacy matches"
            )
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.formatSearch(value: .object(["unexpected": .bool(true)]))),
                """
                ```json
                {
                  "unexpected" : true
                }
                ```
                """
            )
        }

        @MainActor
        func testFileTreeArgumentErrorsPreserveBranchOrdering() throws {
            XCTAssertEqual(
                try MCPFileToolProvider.parseFileTreeRequest(args: [
                    "type": .string("roots"),
                    "max_depth": .string("not-an-integer")
                ]),
                .roots
            )

            XCTAssertThrowsError(try MCPFileToolProvider.parseFileTreeRequest(args: [
                "type": .string("bogus"),
                "max_depth": .string("not-an-integer")
            ])) { error in
                XCTAssertTrue(error.localizedDescription.contains("invalid type: bogus"))
                XCTAssertFalse(error.localizedDescription.contains("max_depth"))
            }

            XCTAssertThrowsError(try MCPFileToolProvider.parseFileTreeRequest(args: [
                "type": .string("files"),
                "max_depth": .string("not-an-integer")
            ])) { error in
                XCTAssertTrue(error.localizedDescription.contains("max_depth must be an integer"))
            }
        }

        func testMultiBlockAndObserverValueRemainByteExact() throws {
            let diff = "--- a/Sources/A.swift\n+++ b/Sources/A.swift\n@@ -1 +1 @@\n-old\n+new"
            let dto = ToolResultDTOs.EditSummary(
                status: "success",
                editsRequested: 1,
                editsApplied: 1,
                addedLines: 1,
                deletedLines: 1,
                totalLinesChanged: 2,
                totalChunks: 1,
                results: nil,
                unifiedDiff: diff,
                cardUnifiedDiff: diff,
                note: nil,
                fileCreated: false,
                fileOverwritten: false,
                reviewStatus: nil,
                rejectionReason: nil,
                requiresUserApproval: false
            )
            let value = try Value(dto)
            XCTAssertEqual(
                try textBlocks(ToolOutputFormatter.buildContentBlocks(
                    toolName: "apply_edits",
                    args: [:],
                    result: value,
                    emitResources: true
                )),
                [
                    """
                    ## Apply Edits ✅
                    - **Requested**: 1
                    - **Applied**: 1
                    - **Lines changed**: 2
                    - **Chunks**: 1

                    ### Unified Diff
                    ```diff
                    --- a/Sources/A.swift
                    +++ b/Sources/A.swift
                    @@ -1 +1 @@
                    -old
                    +new
                    ```
                    """,
                    """
                    ```diff
                    --- a/Sources/A.swift
                    +++ b/Sources/A.swift
                    @@ -1 +1 @@
                    -old
                    +new
                    ```
                    """
                ]
            )
            XCTAssertEqual(
                ToolOutputFormatter.rawJSONString(value),
                "{\"added_lines\":1,\"card_unified_diff\":\"--- a/Sources/A.swift\\n+++ b/Sources/A.swift\\n@@ -1 +1 @@\\n-old\\n+new\",\"deleted_lines\":1,\"edits_applied\":1,\"edits_requested\":1,\"file_created\":false,\"file_overwritten\":false,\"requires_user_approval\":false,\"status\":\"success\",\"total_chunks\":1,\"total_lines_changed\":2,\"unified_diff\":\"--- a/Sources/A.swift\\n+++ b/Sources/A.swift\\n@@ -1 +1 @@\\n-old\\n+new\"}"
            )
        }

        func testSearchMultiFileOmissionsDuplicateGroupsAndGapsRemainByteExact() throws {
            let dto = ToolResultDTOs.SearchResultDTO(
                totalMatches: 9,
                totalFiles: 3,
                matchedFiles: 3,
                searchedFiles: 12,
                contentMatches: 7,
                pathMatches: 2,
                limitHit: true,
                perFileCounts: [
                    .init(path: "Sources/A.swift", count: 2),
                    .init(path: "Sources/B.swift", count: 1)
                ],
                pathMatchLines: ["Sources/A.swift", "Sources/C.swift"],
                contentMatchGroups: [
                    .init(path: "Sources/A.swift", lines: [
                        .init(
                            lineNumber: 10,
                            lineText: "first needle",
                            contextBefore: [.init(lineNumber: 9, lineText: "before first")],
                            contextAfter: [.init(lineNumber: 11, lineText: "after first")]
                        )
                    ]),
                    .init(path: "Sources/A.swift", lines: [
                        .init(
                            lineNumber: 20,
                            lineText: "second needle",
                            contextBefore: [.init(lineNumber: 18, lineText: "before second")],
                            contextAfter: [.init(lineNumber: 22, lineText: "after second")]
                        )
                    ]),
                    .init(path: "Sources/B.swift", lines: [
                        .init(lineNumber: 3, lineText: "third needle", contextBefore: [], contextAfter: [])
                    ])
                ],
                omittedTotal: 4,
                omittedContentMatches: 4,
                omittedPathMatches: 0,
                perFileTotals: [
                    .init(path: "Sources/A.swift", count: 5),
                    .init(path: "Sources/B.swift", count: 2)
                ]
            )
            let value = try Value(dto)
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.formatSearch(value: value)),
                """
                ## Search Results ✅
                - **Total matches**: 9 across 3 matching files (searched 12 files)
                - **Content matches**: 7 • **Path matches**: 2
                - **Status**: Partial (limit reached)
                - **Top files**: A.swift (5), B.swift (2)

                ### Matches
                Sources/
                ├── A.swift — 5 matches (showing first 2) • path match
                    │           9 │   before first
                    │          10 │ ▶ first needle
                    │          11 │   after first
                    │\u{20}\u{20}\u{20}
                    │          18 │   before second
                    │             │   ⋮
                    │          20 │ ▶ second needle
                    │             │   ⋮
                    │          22 │   after second
                    │       [3 more matches in this file - use higher max_results to see all]
                ├── B.swift — 2 matches (showing first 1)
                    │           3 │ ▶ third needle
                    │       [1 more matches in this file - use higher max_results to see all]
                └── C.swift — path match
                """
            )
            XCTAssertEqual(
                ToolOutputFormatter.rawJSONString(value),
                try onlyText(ToolOutputFormatter.buildContentBlocks(
                    toolName: "file_search",
                    args: ["_rawJSON": .bool(true)],
                    result: value,
                    emitResources: true
                ))
            )
        }

        func testWorkspaceContextFormattedRawAndMalformedContentBlocksRemainByteExact() throws {
            let dto = ToolResultDTOs.PromptContextDTO(
                prompt: "freeze",
                selection: nil,
                fileBlocks: nil,
                codeStructure: nil,
                fileTree: nil,
                tokenStats: nil,
                userTokenStats: nil,
                tokenStatsNote: nil,
                copyPreset: nil,
                copyPresets: nil
            )
            let value = try Value(dto)
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.buildContentBlocks(
                    toolName: "workspace_context",
                    args: [:],
                    result: value,
                    emitResources: true
                )),
                """
                ## Prompt Context ✅

                ### Prompt
                ```text
                freeze
                ```
                """
            )
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.buildContentBlocks(
                    toolName: "workspace_context",
                    args: ["_rawJSON": .bool(true)],
                    result: value,
                    emitResources: true
                )),
                #"{"prompt":"freeze"}"#
            )
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.formatPromptState(value: .object(["unexpected": .string("value")]))),
                """
                ```json
                {
                  "unexpected" : "value"
                }
                ```
                """
            )

            let selectedFile = ToolResultDTOs.SelectedFileInfo(
                path: "Project/App.swift",
                tokens: 12,
                renderMode: "full",
                ranges: nil,
                isAuto: false,
                codemapOrigin: nil,
                copyPreset: nil,
                rootPath: "/fixture/Project",
                pathWithinRoot: "App.swift"
            )
            let selection = ToolResultDTOs.SelectedFilesReply(
                files: [selectedFile],
                totalTokens: 12,
                fileSlices: nil,
                summary: .init(
                    fullCount: 1,
                    sliceCount: 0,
                    codemapCount: 0,
                    fullTokens: 12,
                    sliceTokens: 0,
                    codemapTokens: 0
                )
            )
            let comprehensive = try Value(ToolResultDTOs.PromptContextDTO(
                prompt: "audit prompt",
                selection: selection,
                fileBlocks: ["File: Project/App.swift\n```swift\nstruct App {}\n```"],
                codeStructure: .init(fileCount: 1, content: "struct App {}"),
                fileTree: .init(
                    rootsCount: 1,
                    usesLegend: false,
                    tree: "Project\n└── App.swift *"
                ),
                tokenStats: .init(total: 0, files: 0, prompt: 2, fileTree: 3),
                userTokenStats: nil,
                tokenStatsNote: nil,
                tokenAccounting: .init(
                    status: "incomplete",
                    source: "active_tab_published",
                    refreshPending: true,
                    incompleteComponents: ["files", "codemap_presentation"]
                ),
                copyPreset: nil,
                copyPresets: nil,
                worktreeScope: scope()
            ))
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.formatPromptState(value: comprehensive)),
                """
                ## Prompt Context ✅
                - **Scope**: session-bound worktree. Displayed paths use logical/canonical roots; filesystem-derived sections use that bound checkout.
                - **Root remapping**:
                  - `Project` → session-bound worktree (worktree `wt_fixture`, name `feature`, branch `feature/latency`, label `Latency Fixture`)
                **Token accounting pending**

                - **Selection**: pending
                - Prompt: 2
                - File tree: 3
                - Token accounting: incomplete from active_tab_published; refresh pending; incomplete: files, codemap_presentation
                - **Selected files**: 1 total (1 full)
                - Token breakdown: full 12

                ### Prompt
                ```text
                audit prompt
                ```

                ### Selection
                1 files • 12 tokens (Auto view)

                ### Selected Files
                /fixture/Project/
                └── App.swift — 12 tokens (full)

                ### Selected File Tree
                Project
                └── App.swift *

                ### Code Maps
                - **Files with codemap**: 1

                ```text
                struct App {}
                ```

                ### Selected File Contents
                File: Project/App.swift
                ```swift
                struct App {}
                ```
                """
            )

            let promptEnvelope: Value = .object([
                "op": .string("get"),
                "prompt": .object([
                    "prompt": .string("enveloped prompt"),
                    "lines": .double(1)
                ])
            ])
            XCTAssertEqual(
                try onlyText(ToolOutputFormatter.formatPromptState(value: promptEnvelope)),
                """
                ## Prompt ✅
                - **Lines**: 1

                ### Prompt
                ```text
                enveloped prompt
                ```
                """
            )
        }

        private func scope() -> ToolResultDTOs.WorktreeScopeDTO {
            ToolResultDTOs.WorktreeScopeDTO(
                kind: "session_bound_worktree",
                displayIdentity: "logical_canonical_root",
                effectiveIdentity: "bound_worktree_root",
                rootMappings: [
                    .init(
                        logicalRootName: "Project",
                        logicalRootPath: "Project",
                        effectiveRootName: "feature",
                        effectiveRootPath: "session-bound",
                        worktreeID: "wt_fixture",
                        worktreeName: "feature",
                        branch: "feature/latency",
                        label: "Latency Fixture"
                    )
                ]
            )
        }

        private func textBlocks(_ blocks: [MCP.Tool.Content]) throws -> [String] {
            try blocks.map { block in
                guard case let .text(text, _, _) = block else {
                    throw NSError(domain: "MCPToolOutputLatencyParityTests", code: 2)
                }
                return text
            }
        }

        private func onlyText(_ blocks: [MCP.Tool.Content]) throws -> String {
            XCTAssertEqual(blocks.count, 1)
            guard case let .text(text, _, _) = try XCTUnwrap(blocks.first) else {
                throw NSError(domain: "MCPToolOutputLatencyParityTests", code: 1)
            }
            return text
        }
    }
#endif
