import Foundation
@testable import RepoPrompt
import XCTest

final class MCPFileSearchDisplayPathTests: XCTestCase {
    func testCachedDisplayPathResolverPreservesSingleAndMultiRootAliasesAndLegacyParity() throws {
        do {
            let caseLabel = "testCachedDisplayPathResolverPreservesRepeatedMatchesAllRootFallbackAliasesAndLegacyParity"
            let visibleRoot = try Self.root(
                id: "00000000-0000-0000-0000-000000000001",
                name: "App",
                fullPath: "/tmp/RepoPromptDisplay/AppRoot",
                label: caseLabel
            )
            let hiddenRoot = try Self.root(
                id: "00000000-0000-0000-0000-000000000002",
                name: "Lib",
                fullPath: "/tmp/RepoPromptDisplay/LibRoot",
                label: caseLabel
            )
            let displayPath = MCPWindowWorkspaceToolHelpers.makeCachedMCPDisplayPathResolver(
                visibleRoots: [visibleRoot],
                allRoots: [visibleRoot, hiddenRoot]
            )
            let legacyDisplayPath = MCPServerViewModel.makeCachedMCPDisplayPathResolver(
                visibleRoots: [visibleRoot],
                allRoots: [visibleRoot, hiddenRoot]
            )

            let repeatedVisiblePath = "/tmp/RepoPromptDisplay/AppRoot/Sources/App.swift"
            let expectations = [
                (repeatedVisiblePath, "Sources/App.swift"),
                (repeatedVisiblePath, "Sources/App.swift"),
                ("/tmp/RepoPromptDisplay/LibRoot/Sources/Lib.swift", "Lib/Sources/Lib.swift")
            ]
            for (rawPath, expected) in expectations {
                XCTAssertEqual(displayPath(rawPath), expected, caseLabel)
                XCTAssertEqual(displayPath(rawPath), legacyDisplayPath(rawPath), caseLabel)
            }
        }

        do {
            let caseLabel = "testCachedDisplayPathResolverPreservesMultiRootLabels"
            let appRoot = try Self.root(
                id: "00000000-0000-0000-0000-000000000011",
                name: "App",
                fullPath: "/tmp/RepoPromptDisplay/AppRoot",
                label: caseLabel
            )
            let libRoot = try Self.root(
                id: "00000000-0000-0000-0000-000000000012",
                name: "Lib",
                fullPath: "/tmp/RepoPromptDisplay/LibRoot",
                label: caseLabel
            )
            let displayPath = MCPWindowWorkspaceToolHelpers.makeCachedMCPDisplayPathResolver(
                visibleRoots: [appRoot, libRoot],
                allRoots: [appRoot, libRoot]
            )

            XCTAssertEqual(displayPath(appRoot.fullPath), "App", caseLabel)
            XCTAssertEqual(displayPath(libRoot.fullPath), "Lib", caseLabel)
            XCTAssertEqual(displayPath(appRoot.fullPath + "/Sources/App.swift"), "App/Sources/App.swift", caseLabel)
            XCTAssertEqual(displayPath(libRoot.fullPath + "/Sources/Lib.swift"), "Lib/Sources/Lib.swift", caseLabel)
        }
    }

    func testCappedPathOnlyFixturePreservesEightyOrderedDisplayPathsAndScannedFileMetadata() throws {
        let appRoot = try Self.root(
            id: "00000000-0000-0000-0000-000000000021",
            name: "App",
            fullPath: "/tmp/RepoPromptDisplay/AppRoot"
        )
        let displayPath = MCPWindowWorkspaceToolHelpers.makeCachedMCPDisplayPathResolver(
            visibleRoots: [appRoot],
            allRoots: [appRoot]
        )
        let rawPaths = (0 ..< 80).map { index in
            appRoot.fullPath + "/Sources/File" + String(format: "%03d", index) + ".swift"
        }
        let expectedDisplayPaths = (0 ..< 80).map { index in
            "Sources/File" + String(format: "%03d", index) + ".swift"
        }
        let displayedPaths = rawPaths.map(displayPath)
        XCTAssertEqual(displayedPaths, expectedDisplayPaths)

        let dto = ToolResultDTOs.SearchResultDTO(
            totalMatches: displayedPaths.count,
            totalFiles: 0,
            matchedFiles: Set(displayedPaths).count,
            searchedFiles: 1630,
            contentMatches: 0,
            pathMatches: displayedPaths.count,
            limitHit: true,
            perFileCounts: [],
            pathMatchLines: displayedPaths,
            contentMatchGroups: []
        )

        XCTAssertEqual(dto.totalMatches, 80)
        XCTAssertEqual(dto.totalFiles, 0)
        XCTAssertEqual(dto.matchedFiles, 80)
        XCTAssertEqual(dto.searchedFiles, 1630)
        XCTAssertEqual(dto.contentMatches, 0)
        XCTAssertEqual(dto.pathMatches, 80)
        XCTAssertTrue(dto.limitHit)
        XCTAssertEqual(dto.pathMatchLines, expectedDisplayPaths)

        let markdown = ToolOutputFormatter.searchResults(dto: dto)
        XCTAssertTrue(markdown.contains("- **Total matches**: 80 across 80 matching files (searched 1630 files)"))
        XCTAssertTrue(markdown.contains("- **Content matches**: 0 • **Path matches**: 80"))
        XCTAssertTrue(markdown.contains("- **Status**: Partial (limit reached)"))
        let firstPath = try XCTUnwrap(markdown.range(of: "File000.swift"))
        let lastPath = try XCTUnwrap(markdown.range(of: "File079.swift"))
        XCTAssertLessThan(firstPath.lowerBound, lastPath.lowerBound)
    }

    func testWorktreeBoundDisplayCompositionProjectsLogicalPathsAndFallsBackForUnboundRoot() throws {
        let logicalRoot = try Self.root(
            id: "00000000-0000-0000-0000-000000000031",
            name: "Project",
            fullPath: "/repo/project"
        )
        let docsRoot = try Self.root(
            id: "00000000-0000-0000-0000-000000000032",
            name: "Docs",
            fullPath: "/repo/docs"
        )
        let physicalRoot = try Self.root(
            id: "00000000-0000-0000-0000-000000000033",
            name: "Project",
            fullPath: "/tmp/worktrees/project-agent"
        )
        let projection = try WorkspaceRootBindingProjection(
            sessionID: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000034")),
            boundRoots: [
                .init(
                    logicalRoot: logicalRoot,
                    physicalRoot: physicalRoot,
                    binding: Self.binding(logicalRoot: logicalRoot, physicalRoot: physicalRoot)
                )
            ],
            visibleLogicalRoots: [logicalRoot, docsRoot]
        )
        let baseDisplayPath = MCPWindowWorkspaceToolHelpers.makeCachedMCPDisplayPathResolver(
            visibleRoots: [logicalRoot, docsRoot],
            allRoots: [logicalRoot, docsRoot]
        )
        let displayPath: (String) -> String = { rawPath in
            projection.projectedLogicalDisplayPath(forPhysicalPath: rawPath) ?? baseDisplayPath(rawPath)
        }

        let physicalSourcePath = physicalRoot.fullPath + "/Sources/App.swift"
        XCTAssertEqual(displayPath(physicalSourcePath), "Project/Sources/App.swift")
        XCTAssertEqual(displayPath(physicalSourcePath), "Project/Sources/App.swift")
        XCTAssertEqual(displayPath(docsRoot.fullPath + "/README.md"), "Docs/README.md")
    }

    private static func root(
        id: String,
        name: String,
        fullPath: String,
        label: String = ""
    ) throws -> WorkspaceRootRef {
        try WorkspaceRootRef(
            id: XCTUnwrap(UUID(uuidString: id), label),
            name: name,
            fullPath: fullPath
        )
    }

    private static func binding(
        logicalRoot: WorkspaceRootRef,
        physicalRoot: WorkspaceRootRef
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-1",
            repositoryID: "repo-1",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "wt-1",
            worktreeRootPath: physicalRoot.fullPath,
            source: "test"
        )
    }
}
