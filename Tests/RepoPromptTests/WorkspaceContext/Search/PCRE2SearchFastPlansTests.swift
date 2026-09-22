import Foundation
@testable import RepoPromptApp
import XCTest

final class PCRE2SearchFastPlansTests: XCTestCase {
    func testAnchoredRegexPrefilterPreservesAlternativesAcrossLongNonmatchingLines() async throws {
        let root = try makeTestDirectory(name: "PCRE2SearchFastPlans")
        let fileURL = root.appendingPathComponent("Declarations.swift")
        let longNoiseLines = (0 ..< 256).map { _ in String(repeating: "x", count: 2048) }
        let content = (
            longNoiseLines
                + [
                    "préfixé nonmatching",
                    "class MatchMe",
                    "STRUCT MatchMe",
                    "func matchMe",
                    "cla\u{017F}s UnicodeFoldMatch"
                ]
        ).joined(separator: "\n")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let result = try await StoreBackedWorkspaceSearch.search(
            pattern: #"^\s*(?:final\s+)?(?:class|struct|func)\s+[A-Za-z_][A-Za-z0-9_]*"#,
            mode: .content,
            isRegex: true,
            caseInsensitive: true,
            maxPaths: 10,
            maxMatches: 10,
            paths: [fileURL.path],
            countOnly: false,
            rootScope: .visibleWorkspace,
            store: store,
            workspaceManager: nil
        )

        XCTAssertEqual(result.matches?.map(\.lineNumber), [257, 258, 259, 260])
        XCTAssertEqual(result.contentFileCount, 1)

        let mixedEmptyPrefilter = PCRE2LinePrefilter(
            asciiRequiredAlternatives: ["", "class"],
            caseInsensitive: true
        )
        XCTAssertNil(
            PCRE2LinePrefilterMatcher(prefilter: mixedEmptyPrefilter),
            "Unsupported alternatives must disable the prefilter so every line reaches PCRE2."
        )

        let unsupportedNeedlePrefilter = PCRE2LinePrefilter(
            asciiRequiredAlternatives: ["class", "cla\u{017F}s"],
            caseInsensitive: true
        )
        XCTAssertNil(PCRE2LinePrefilterMatcher(prefilter: unsupportedNeedlePrefilter))
    }
}
