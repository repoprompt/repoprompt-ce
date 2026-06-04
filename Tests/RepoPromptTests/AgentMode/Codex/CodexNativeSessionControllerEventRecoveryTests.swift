import Foundation
@testable import RepoPrompt
import XCTest

final class CodexNativeSessionControllerEventRecoveryTests: XCTestCase {
    private static let webSearchAliases = ["search", "web_search", "web_search_request", "google_web_search", "search_web"]

    func testNormalizedCommandExecutionLifecycleParsesAsBashCallAndResult() throws {
        let controller = CodexNativeSessionController(
            client: CodexAppServerClient(),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil
        )

        let started = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/started",
            params: [
                "threadId": "thread-active",
                "turnId": "turn-current",
                "item": [
                    "type": "commandExecution",
                    "id": "call_exec_1",
                    "command": "echo hi",
                    "cwd": "/tmp/work",
                    "processId": "47551",
                    "commandActions": [["type": "unknown", "command": "echo hi"]]
                ]
            ]
        ))

        XCTAssertEqual(started.kind, "call")
        XCTAssertEqual(started.name, "bash")
        XCTAssertNotNil(started.invocationID)
        let argsObject = try XCTUnwrap(jsonObject(from: started.argsJSON))
        XCTAssertEqual(argsObject["command"] as? String, "echo hi")
        XCTAssertEqual(argsObject["cwd"] as? String, "/tmp/work")
        XCTAssertEqual(argsObject["processId"] as? String, "47551")
        XCTAssertEqual((argsObject["commandActions"] as? [[String: Any]])?.count, 1)

        let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: [
                "threadId": "thread-active",
                "turnId": "turn-current",
                "item": [
                    "type": "commandExecution",
                    "id": "call_exec_1",
                    "command": "echo hi",
                    "processId": "47551",
                    "status": "completed",
                    "exitCode": 0,
                    "aggregatedOutput": "hi\n"
                ]
            ]
        ))

        XCTAssertEqual(completed.kind, "result")
        XCTAssertEqual(completed.name, "bash")
        XCTAssertEqual(completed.invocationID, started.invocationID)
        XCTAssertEqual(completed.isError, false)
        let resultObject = try XCTUnwrap(jsonObject(from: completed.resultJSON))
        XCTAssertEqual(resultObject["type"] as? String, "commandExecution")
        XCTAssertEqual(resultObject["status"] as? String, "completed")
        XCTAssertEqual(resultObject["processId"] as? String, "47551")
        XCTAssertEqual(resultObject["aggregatedOutput"] as? String, "hi\n")
        XCTAssertEqual(resultObject["exitCode"] as? Int, 0)
    }

    func testNativeWebSearchAliasesPairStartedAndCompletedInvocations() throws {
        for alias in Self.webSearchAliases {
            let controller = makeController()
            let itemID = "call_pair_\(alias)"
            let started = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/started",
                params: toolParams(item: [
                    "type": "toolCall",
                    "id": itemID,
                    "name": alias,
                    "query": "paired alias \(alias)"
                ])
            ), alias)

            let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/completed",
                params: toolParams(item: [
                    "type": "toolCall",
                    "id": itemID,
                    "name": alias,
                    "status": "completed",
                    "query": "paired alias \(alias)",
                    "response": [
                        "results": [["title": "Paired", "snippet": alias]]
                    ]
                ])
            ), alias)

            XCTAssertEqual(started.kind, "call", alias)
            XCTAssertEqual(completed.kind, "result", alias)
            XCTAssertEqual(completed.name, "search", alias)
            XCTAssertEqual(completed.invocationID, started.invocationID, alias)
            XCTAssertEqual(completed.isError, false, alias)
        }
    }

    func testNativeWebSearchCompletionPayloadsPreserveCompactSearchFields() throws {
        let rows: [(label: String, alias: String, item: [String: Any], expectedResults: Int?, expectedSources: Int?, expectedDetailKey: String)] = [
            (
                "root results",
                "web_search",
                [
                    "type": "toolCall",
                    "id": "call_search_root",
                    "name": "web_search",
                    "status": "completed",
                    "query": "RepoPrompt CE",
                    "results": [["title": "RepoPrompt CE", "url": "https://example.com/repo", "snippet": "Native cards"]],
                    "sources": [["title": "Docs", "url": "https://example.com/docs"]]
                ],
                1,
                1,
                "results"
            ),
            (
                "wrapped response",
                "web_search_request",
                [
                    "type": "toolCall",
                    "id": "call_search_wrapped",
                    "name": "web_search_request",
                    "query": "macOS app search",
                    "response": [
                        "summary": "Search completed",
                        "items": [["title": "Result", "snippet": "Useful result"]]
                    ],
                    "sources": [["title": "Wrapped Source"]],
                    "total_results": 3,
                    "source_count": 4,
                    "citationCount": 2
                ],
                nil,
                1,
                "items"
            ),
            (
                "array content",
                "google_web_search",
                [
                    "type": "toolCall",
                    "id": "call_search_array",
                    "name": "google_web_search",
                    "query": "Codex native web search",
                    "content": [["title": "Codex", "snippet": "Web search result"]]
                ],
                1,
                nil,
                "results"
            )
        ]

        for row in rows {
            let controller = makeController()
            let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/completed",
                params: toolParams(item: row.item)
            ), row.label)

            XCTAssertEqual(completed.kind, "result", row.label)
            XCTAssertEqual(completed.name, "search", row.label)
            XCTAssertNotEqual(completed.isError, true, row.label)
            let resultObject = try XCTUnwrap(jsonObject(from: completed.resultJSON), row.label)
            XCTAssertEqual(resultObject["query"] as? String, row.item["query"] as? String, row.label)
            if let expectedResults = row.expectedResults {
                XCTAssertEqual((resultObject["results"] as? [[String: Any]])?.count, expectedResults, row.label)
            }
            if let expectedSources = row.expectedSources {
                XCTAssertEqual((resultObject["sources"] as? [[String: Any]])?.count, expectedSources, row.label)
            }
            XCTAssertNotNil(resultObject[row.expectedDetailKey], row.label)
            if row.label == "wrapped response" {
                XCTAssertEqual(resultObject["total_results"] as? Int, 3)
                XCTAssertEqual(resultObject["source_count"] as? Int, 4)
                XCTAssertEqual(resultObject["citationCount"] as? Int, 2)
            }
        }
    }

    func testNativeWebSearchWrappedPayloadMergesSiblingSearchFieldsAndSuccessfulStatusWins() throws {
        let controller = makeController()
        let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_search_completed_with_stale_error",
                "name": "web_search",
                "status": "completed",
                "query": "completed despite stale error field",
                "response": [
                    "items": [["title": "Completed", "snippet": "Usable result"]]
                ],
                "citations": [["title": "Citation"]],
                "total_results": 9,
                "errorMessage": "stale retry warning",
                "errors": [["message": "stale retry detail"]]
            ])
        ))

        XCTAssertEqual(completed.kind, "result")
        XCTAssertEqual(completed.name, "search")
        XCTAssertEqual(completed.isError, false)
        let resultObject = try XCTUnwrap(jsonObject(from: completed.resultJSON))
        XCTAssertEqual(resultObject["query"] as? String, "completed despite stale error field")
        XCTAssertEqual((resultObject["items"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((resultObject["citations"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(resultObject["total_results"] as? Int, 9)
        XCTAssertEqual(resultObject["errorMessage"] as? String, "stale retry warning")
        XCTAssertEqual((resultObject["errors"] as? [[String: Any]])?.count, 1)
    }

    func testNativeWebSearchErrorPayloadWithoutFailedStatusParsesAsFailure() throws {
        let controller = makeController()
        let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_search_error_without_status",
                "name": "web_search",
                "query": "transient web outage",
                "errorMessage": "web search timed out"
            ])
        ))

        XCTAssertEqual(completed.kind, "result")
        XCTAssertEqual(completed.name, "search")
        XCTAssertEqual(completed.isError, true)
        let resultObject = try XCTUnwrap(jsonObject(from: completed.resultJSON))
        XCTAssertEqual(resultObject["query"] as? String, "transient web outage")
        XCTAssertEqual(resultObject["errorMessage"] as? String, "web search timed out")
    }

    private func makeController() -> CodexNativeSessionController {
        CodexNativeSessionController(
            client: CodexAppServerClient(),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil
        )
    }

    private func toolParams(item: [String: Any]) -> [String: Any] {
        [
            "threadId": "thread-active",
            "turnId": "turn-current",
            "item": item
        ]
    }

    private func jsonObject(from raw: String?) -> [String: Any]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
