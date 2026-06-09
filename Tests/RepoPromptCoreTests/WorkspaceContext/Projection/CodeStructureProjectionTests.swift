import Foundation
@testable import RepoPromptCore
import XCTest

final class CodeStructureProjectionTests: XCTestCase {
    func testBudgetSelectionFreezesLimitsSeparatorCostAndOversizedFirstBehavior() {
        struct Case {
            let costs: [Int]
            let resultLimit: Int
            let included: [String]
            let omittedByResultLimit: Int
            let omittedByTokenBudget: Int
        }

        XCTAssertEqual(CodeStructureProjectionService.defaultTokenBudget, 6000)
        XCTAssertEqual(CodeStructureProjectionService.outputSeparator, "\n\n")
        XCTAssertEqual(
            CodeStructureProjectionService.defaultSeparatorTokenCost,
            TokenCalculationService.estimateTokens(for: "\n\n")
        )

        let cases = [
            Case(costs: [1000, 2000], resultLimit: 10, included: ["0", "1"], omittedByResultLimit: 0, omittedByTokenBudget: 0),
            Case(costs: [3000, 3000], resultLimit: 10, included: ["0", "1"], omittedByResultLimit: 0, omittedByTokenBudget: 0),
            Case(costs: [3000, 3001], resultLimit: 10, included: ["0"], omittedByResultLimit: 0, omittedByTokenBudget: 1),
            Case(costs: [6001, 1], resultLimit: 10, included: ["0"], omittedByResultLimit: 0, omittedByTokenBudget: 1),
            Case(costs: [100, 6000, 1], resultLimit: 10, included: ["0"], omittedByResultLimit: 0, omittedByTokenBudget: 2),
            Case(costs: [100, 100, 100], resultLimit: 2, included: ["0", "1"], omittedByResultLimit: 1, omittedByTokenBudget: 0),
            Case(costs: [100, 100], resultLimit: 0, included: [], omittedByResultLimit: 2, omittedByTokenBudget: 0),
            Case(costs: [100, 100], resultLimit: -1, included: [], omittedByResultLimit: 2, omittedByTokenBudget: 0)
        ]

        for testCase in cases {
            let result = CodeStructureProjectionService.selectBudgetedCandidates(
                testCase.costs.enumerated().map {
                    .init(key: String($0.offset), estimatedTokens: $0.element)
                },
                resultLimit: testCase.resultLimit
            )

            XCTAssertEqual(result.includedKeys, testCase.included)
            XCTAssertEqual(result.omissions.resultLimit, testCase.omittedByResultLimit)
            XCTAssertEqual(result.omissions.tokenBudget, testCase.omittedByTokenBudget)
            XCTAssertEqual(result.omissions.total, testCase.omittedByResultLimit + testCase.omittedByTokenBudget)
        }

        let separatorLimited = CodeStructureProjectionService.selectBudgetedCandidates(
            [
                .init(key: "first", estimatedTokens: 3),
                .init(key: "second", estimatedTokens: 3)
            ],
            resultLimit: 2,
            tokenBudget: 6,
            separatorTokenCost: 1
        )
        XCTAssertEqual(separatorLimited.includedKeys, ["first"])
        XCTAssertEqual(separatorLimited.omissions, .init(resultLimit: 0, tokenBudget: 1))

        let negativeSeparatorCost = CodeStructureProjectionService.selectBudgetedCandidates(
            [
                .init(key: "first", estimatedTokens: 3),
                .init(key: "second", estimatedTokens: 3)
            ],
            resultLimit: 2,
            tokenBudget: 6,
            separatorTokenCost: -10
        )
        XCTAssertEqual(negativeSeparatorCost.includedKeys, ["first", "second"])
    }

    func testProjectionFreezesPhysicalPathDedupDisplayOrderingRenderingAndOmissions() {
        let alpha = makeFileAPI(path: "/repo/Alpha/A.swift", typeName: "AlphaSymbol")
        let zeta = makeFileAPI(path: "/repo/Zeta/B.swift", typeName: "ZetaSymbol")
        let duplicateAlpha = makeFileAPI(path: "/repo/Alpha/A.swift", typeName: "DuplicateAlphaSymbol")
        let entries: [CodeStructureProjectionRequest.Entry] = [
            .init(physicalPath: zeta.filePath, displayPath: "Zeta/B.swift", fileAPI: zeta),
            .init(physicalPath: "/repo/Omega/Missing.swift", displayPath: "Omega/Missing.swift", fileAPI: nil),
            .init(physicalPath: alpha.filePath, displayPath: "Alpha/A.swift", fileAPI: alpha),
            .init(physicalPath: "/repo/Alpha/../Alpha/A.swift", displayPath: "Duplicate/A.swift", fileAPI: duplicateAlpha),
            .init(physicalPath: "/repo/Beta/Missing.swift", displayPath: "Beta/Missing.swift", fileAPI: nil)
        ]

        let full = CodeStructureProjectionService.project(.init(
            entries: entries,
            budget: .init(resultLimit: 10, tokenBudget: 100_000),
            includeUnmappedPaths: true
        ))

        XCTAssertEqual(full.renderedPaths, ["Alpha/A.swift", "Zeta/B.swift"])
        XCTAssertEqual(full.fileCount, 2)
        XCTAssertEqual(full.content, [
            alpha.getFullAPIDescription(displayPath: "Alpha/A.swift"),
            zeta.getFullAPIDescription(displayPath: "Zeta/B.swift")
        ].joined(separator: "\n\n"))
        XCTAssertFalse(full.content.contains("DuplicateAlphaSymbol"))
        XCTAssertEqual(full.unmappedPaths, ["Beta/Missing.swift", "Omega/Missing.swift"])
        XCTAssertEqual(full.omissions, .init(resultLimit: 0, tokenBudget: 0))
        XCTAssertFalse(full.tokenBudgetHit)

        let limited = CodeStructureProjectionService.project(.init(
            entries: entries,
            budget: .init(resultLimit: 1, tokenBudget: 100_000),
            includeUnmappedPaths: true
        ))
        XCTAssertEqual(limited.renderedPaths, ["Alpha/A.swift"])
        XCTAssertEqual(limited.omissions, .init(resultLimit: 1, tokenBudget: 0))

        let alphaCost = alpha.estimatedFullAPIDescriptionTokens(displayPath: "Alpha/A.swift")
        let zetaCost = zeta.estimatedFullAPIDescriptionTokens(displayPath: "Zeta/B.swift")
        let budgetLimited = CodeStructureProjectionService.project(.init(
            entries: entries,
            budget: .init(
                resultLimit: 10,
                tokenBudget: alphaCost + CodeStructureProjectionService.defaultSeparatorTokenCost + zetaCost - 1
            ),
            includeUnmappedPaths: false
        ))
        XCTAssertEqual(budgetLimited.renderedPaths, ["Alpha/A.swift"])
        XCTAssertEqual(budgetLimited.unmappedPaths, [])
        XCTAssertEqual(budgetLimited.omissions, .init(resultLimit: 0, tokenBudget: 1))
        XCTAssertTrue(budgetLimited.tokenBudgetHit)
    }

    func testProjectionUsesPhysicalPathAsDisplayPathTieBreakerWithoutChangingInputPathText() throws {
        let alpha = makeFileAPI(path: "/repo/A.swift", typeName: "AlphaSymbol")
        let zeta = makeFileAPI(path: "/repo/Z.swift", typeName: "ZetaSymbol")
        let result = CodeStructureProjectionService.project(.init(
            entries: [
                .init(physicalPath: zeta.filePath, displayPath: "Same.swift", fileAPI: zeta),
                .init(physicalPath: alpha.filePath, displayPath: "Same.swift", fileAPI: alpha)
            ],
            budget: .init(resultLimit: 10),
            includeUnmappedPaths: false
        ))

        XCTAssertEqual(result.renderedPaths, ["Same.swift", "Same.swift"])
        XCTAssertLessThan(
            try XCTUnwrap(result.content.range(of: "AlphaSymbol")?.lowerBound),
            try XCTUnwrap(result.content.range(of: "ZetaSymbol")?.lowerBound)
        )
        XCTAssertEqual(result.content.components(separatedBy: "File: Same.swift").count - 1, 2)
    }

    func testCompleteLocalDefinitionsPreserveFilteredInputOrderFirstPathWinsAndExactWrapper() throws {
        let selected = makeFileAPI(path: "/repo/Selected.swift", typeName: "SelectedSymbol")
        let zeta = makeFileAPI(path: "/repo/Zeta.swift", typeName: "ZetaFirst")
        let duplicateZeta = makeFileAPI(path: "/repo/Zeta.swift", typeName: "ZetaDuplicate")
        let alpha = makeFileAPI(path: "/repo/Alpha.swift", typeName: "AlphaSymbol")
        let outside = makeFileAPI(path: "/outside/Outside.swift", typeName: "OutsideSymbol")
        let roots = [
            LocalDefinitionProjectionRequest.Root(standardizedPath: "/repo", displayName: "Repo"),
            LocalDefinitionProjectionRequest.Root(standardizedPath: "/library", displayName: "Library")
        ]

        let result = CodeStructureProjectionService.projectLocalDefinitions(.init(
            codeMapUsage: .complete,
            selectedFiles: [makeFileRecord(path: selected.filePath)],
            availableFileAPIs: [zeta, duplicateZeta, alpha, selected, outside],
            pathDisplay: .relative,
            roots: roots
        ))
        let expected = "\n<Complete Definitions>\n"
            + zeta.getFullAPIDescription(displayPath: "Repo/Zeta.swift")
            + "\n\n"
            + alpha.getFullAPIDescription(displayPath: "Repo/Alpha.swift")
            + "\n</Complete Definitions>"

        XCTAssertEqual(result, .init(text: expected, fileCount: 2))
        XCTAssertFalse(result.text.contains("ZetaDuplicate"))
        XCTAssertFalse(result.text.contains("SelectedSymbol"))
        XCTAssertFalse(result.text.contains("OutsideSymbol"))
        XCTAssertLessThan(
            try XCTUnwrap(result.text.range(of: "ZetaFirst")?.lowerBound),
            try XCTUnwrap(result.text.range(of: "AlphaSymbol")?.lowerBound)
        )
    }

    func testAutoLocalDefinitionsSortReferencedPathsAndRenderThroughFileAPIPrimitive() {
        let selected = makeFileAPI(
            path: "/repo/Selected.swift",
            typeName: "SelectedSymbol",
            referencedTypes: ["ZetaType", "AlphaType", "ZetaType"]
        )
        let zeta = makeFileAPI(path: "/repo/Zeta.swift", typeName: "ZetaType")
        let alpha = makeFileAPI(path: "/repo/Alpha.swift", typeName: "AlphaType")
        let unused = makeFileAPI(path: "/repo/Unused.swift", typeName: "UnusedType")
        let roots = [LocalDefinitionProjectionRequest.Root(standardizedPath: "/repo", displayName: "Repo")]

        let result = CodeStructureProjectionService.projectLocalDefinitions(.init(
            codeMapUsage: .auto,
            selectedFiles: [makeFileRecord(path: selected.filePath)],
            availableFileAPIs: [selected, zeta, unused, alpha],
            pathDisplay: .relative,
            roots: roots
        ))
        let expected = "\n<Referenced APIs>\n"
            + alpha.getFullAPIDescription(displayPath: "Alpha.swift")
            + "\n\n"
            + zeta.getFullAPIDescription(displayPath: "Zeta.swift")
            + "\n</Referenced APIs>"

        XCTAssertEqual(result, .init(text: expected, fileCount: 2))
        XCTAssertFalse(result.text.contains("UnusedType"))
    }

    func testLocalDefinitionsKeepNoneSelectedAndEmptyAutoEmpty() {
        let api = makeFileAPI(path: "/repo/Only.swift", typeName: "OnlySymbol")
        let base = LocalDefinitionProjectionRequest(
            codeMapUsage: .none,
            selectedFiles: [makeFileRecord(path: api.filePath)],
            availableFileAPIs: [api],
            pathDisplay: .full,
            roots: [.init(standardizedPath: "/repo", displayName: "Repo")]
        )

        XCTAssertEqual(CodeStructureProjectionService.projectLocalDefinitions(base), .empty)
        XCTAssertEqual(CodeStructureProjectionService.projectLocalDefinitions(.init(
            codeMapUsage: .selected,
            selectedFiles: base.selectedFiles,
            availableFileAPIs: base.availableFileAPIs,
            pathDisplay: base.pathDisplay,
            roots: base.roots
        )), .empty)
        XCTAssertEqual(CodeStructureProjectionService.projectLocalDefinitions(.init(
            codeMapUsage: .auto,
            selectedFiles: base.selectedFiles,
            availableFileAPIs: base.availableFileAPIs,
            pathDisplay: base.pathDisplay,
            roots: base.roots
        )), .empty)
    }

    private func makeFileRecord(path: String) -> WorkspaceFileRecord {
        WorkspaceFileRecord(
            rootID: UUID(),
            name: (path as NSString).lastPathComponent,
            relativePath: String(path.dropFirst("/repo/".count)),
            fullPath: path,
            parentFolderID: nil
        )
    }

    private func makeFileAPI(
        path: String,
        typeName: String,
        referencedTypes: [String] = []
    ) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: [],
            classes: [.init(name: typeName, methods: [], properties: [])],
            functions: [],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: referencedTypes
        )
    }
}
