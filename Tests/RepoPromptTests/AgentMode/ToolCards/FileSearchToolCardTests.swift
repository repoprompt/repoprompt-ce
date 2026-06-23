@testable import RepoPrompt
import XCTest

final class FileSearchToolCardTests: XCTestCase {
    func testRetryableStructuredErrorsOverrideStoredZeroMatchSummary() {
        let scenarios: [(code: String, label: String)] = [
            ("workspace_readiness_unavailable", "Workspace readiness unavailable"),
            ("workspace_freshness_timeout", "Workspace freshness timed out"),
            ("workspace_readiness_timeout", "Workspace readiness timed out"),
            ("workspace_readiness_superseded", "Workspace changed during search"),
            ("worktree_scope_unavailable", "Worktree unavailable"),
            ("search_backpressure", "Temporarily busy")
        ]

        for scenario in scenarios {
            let presentation = FileSearchCardPresentationBuilder.build(
                pattern: "needle",
                toolIsError: false,
                raw: searchResultJSON(
                    errorCode: scenario.code,
                    errorMessage: "Retry the search",
                    retryable: true,
                    storedSummary: "0 matches in 0 files"
                )
            )

            XCTAssertEqual(presentation.subtitle, "\"needle\" • \(scenario.label)", scenario.code)
            XCTAssertEqual(presentation.status, .warning, scenario.code)
        }
    }

    func testUnknownStructuredErrorOverridesStoredCountsWithFailureLabel() {
        let presentation = FileSearchCardPresentationBuilder.build(
            pattern: "needle",
            toolIsError: false,
            raw: searchResultJSON(
                errorCode: "unexpected_search_failure",
                errorMessage: "The backend returned an unknown error",
                retryable: true,
                storedSummary: "0 matches in 0 files"
            )
        )

        XCTAssertEqual(presentation.subtitle, "\"needle\" • Search failed")
        XCTAssertEqual(presentation.status, .failure)
    }

    func testSuccessfulEmptySearchKeepsNeutralZeroResultSummary() {
        let presentation = FileSearchCardPresentationBuilder.build(
            pattern: "needle",
            toolIsError: false,
            raw: searchResultJSON()
        )

        XCTAssertEqual(presentation.subtitle, "\"needle\" • 0 matches in 0 files")
        XCTAssertEqual(presentation.status, .neutral)
    }

    private func searchResultJSON(
        errorCode: String? = nil,
        errorMessage: String? = nil,
        retryable: Bool? = nil,
        storedSummary: String? = nil
    ) -> String {
        var object: [String: Any] = [
            "total_matches": 0,
            "total_files": 0,
            "content_matches": 0,
            "path_matches": 0,
            "limit_hit": false,
            "per_file_counts": [],
            "path_match_lines": [],
            "content_match_groups": []
        ]
        object["error_code"] = errorCode
        object["error_message"] = errorMessage
        object["retryable"] = retryable
        if let storedSummary {
            object["summary_only"] = true
            object["summary_text"] = storedSummary
            object["status"] = "success"
        }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
