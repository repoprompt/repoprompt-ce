import Foundation
@testable import RepoPrompt
import XCTest

final class CodexNativeSessionControllerEventRecoveryTests: XCTestCase {
    private static let webSearchAliases = ["search", "web_search", "web_search_request", "google_web_search", "search_web"]

    func testStructuredErrorNotificationRetainsRetryMetadataAndScope() throws {
        let retrying = try XCTUnwrap(CodexNativeSessionController.test_parseErrorNotification(from: [
            "threadId": "thread-1",
            "turnId": "turn-1",
            "error": [
                "message": "reconnecting",
                "willRetry": true
            ]
        ]))
        XCTAssertEqual(retrying.message, "reconnecting")
        XCTAssertEqual(retrying.willRetry, true)
        XCTAssertEqual(retrying.threadID, "thread-1")
        XCTAssertEqual(retrying.turnID, "turn-1")

        let nestedRetry = try XCTUnwrap(CodexNativeSessionController.test_parseErrorNotification(from: [
            "error": [
                "message": "nested retry",
                "details": [
                    "will_retry": true,
                    "thread_id": "thread-2",
                    "turn_id": "turn-2",
                    "item_id": "item-2"
                ]
            ]
        ]))
        XCTAssertEqual(nestedRetry.willRetry, true)
        XCTAssertEqual(nestedRetry.threadID, "thread-2")
        XCTAssertEqual(nestedRetry.turnID, "turn-2")
        XCTAssertEqual(nestedRetry.itemID, "item-2")

        let terminal = try XCTUnwrap(CodexNativeSessionController.test_parseErrorNotification(from: [
            "message": "fatal",
            "will_retry": false
        ]))
        XCTAssertEqual(terminal.willRetry, false)

        let missingMetadata = try XCTUnwrap(CodexNativeSessionController.test_parseErrorNotification(from: [
            "message": "retrying from legacy text"
        ]))
        XCTAssertNil(missingMetadata.willRetry)
    }

    func testProgressOnlyNotificationsRetainLivenessCategoryScopeAndActiveFlags() throws {
        let rows: [(String, CodexNativeSessionController.LivenessActivity.Kind)] = [
            ("thread/status/changed", .threadStatusChanged),
            ("turn/plan/updated", .turnPlanUpdated),
            ("turn/diff/updated", .turnDiffUpdated),
            ("item/plan/delta", .itemPlanDelta),
            ("item/mcpToolCall/progress", .mcpToolProgress),
            ("command/exec/outputDelta", .commandOrProcessOutput),
            ("process/exited", .processExited),
            ("hook/started", .hookLifecycle),
            ("warning", .warning),
            ("deprecationNotice", .deprecationNotice),
            ("serverRequest/resolved", .serverRequestResolved)
        ]

        for (method, expectedKind) in rows {
            let activity = try XCTUnwrap(CodexNativeSessionController.test_parseLivenessActivity(
                method: method,
                params: [
                    "threadId": "thread-1",
                    "turnId": "turn-1",
                    "itemId": "item-1",
                    "status": [
                        "type": "active",
                        "activeFlags": ["waiting_for_user_input"]
                    ],
                    "message": "progress"
                ]
            ), method)
            XCTAssertEqual(activity.kind, expectedKind, method)
            XCTAssertEqual(activity.threadID, "thread-1", method)
            XCTAssertEqual(activity.turnID, "turn-1", method)
            XCTAssertEqual(activity.itemID, "item-1", method)
            XCTAssertEqual(activity.activeFlags, ["waiting_for_user_input"], method)
            XCTAssertEqual(activity.message, "progress", method)
        }
    }

    func testStaleScopedProgressNotificationIsRejectedByRouting() {
        XCTAssertTrue(CodexNativeSessionController.test_shouldDropNotificationForRouting(
            method: "turn/plan/updated",
            params: [
                "threadId": "stale-thread",
                "turnId": "stale-turn"
            ],
            activeThreadID: "active-thread",
            currentTurnID: "active-turn"
        ))
    }

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

    func testNativeWebActionTopLevelScalarsSurviveStartedAndCompletedEvents() throws {
        let controller = makeController()
        let started = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/started",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_search_open",
                "name": "web_search",
                "query": "docs",
                "url": "https://docs.example.com/a/b/c",
                "action": "open"
            ])
        ))
        XCTAssertEqual(started.kind, "call")
        XCTAssertEqual(started.name, "search")
        let startedArgs = try XCTUnwrap(jsonObject(from: started.argsJSON))
        XCTAssertEqual(startedArgs["query"] as? String, "docs")
        XCTAssertEqual(startedArgs["url"] as? String, "https://docs.example.com/a/b/c")
        XCTAssertEqual(startedArgs["action"] as? String, "open")

        let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_search_open",
                "name": "web_search",
                "status": "completed",
                "url": "https://docs.example.com/a/b/c",
                "action": "open",
                "title": "Docs page",
                "content": String(repeating: "full page body ", count: 80)
            ])
        ))
        XCTAssertEqual(completed.kind, "result")
        XCTAssertEqual(completed.name, "search")
        let completedResult = try XCTUnwrap(jsonObject(from: completed.resultJSON))
        XCTAssertEqual(completedResult["url"] as? String, "https://docs.example.com/a/b/c")
        XCTAssertEqual(completedResult["action"] as? String, "open")
        XCTAssertNil(completedResult["content"])
    }

    func testActualCodexWebSearchLifecycleShapesPreserveQueriesAndIgnoreRawDuplicate() throws {
        let controller = makeController()
        let started = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/started",
            params: toolParams(item: [
                "type": "webSearch",
                "id": "ws_actual",
                "query": "",
                "action": ["type": "other"]
            ])
        ))
        XCTAssertEqual(started.kind, "call")
        XCTAssertEqual(started.name, "search")
        XCTAssertNil(started.argsJSON)

        let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "webSearch",
                "id": "ws_actual",
                "query": "first query ...",
                "action": [
                    "type": "search",
                    "query": NSNull(),
                    "queries": ["first query", "second query"]
                ]
            ])
        ))
        XCTAssertEqual(completed.kind, "result")
        XCTAssertEqual(completed.name, "search")
        XCTAssertEqual(completed.invocationID, started.invocationID)
        XCTAssertNil(completed.isError)
        let args = try XCTUnwrap(jsonObject(from: completed.argsJSON))
        let result = try XCTUnwrap(jsonObject(from: completed.resultJSON))
        XCTAssertEqual(args["action"] as? String, "search")
        XCTAssertEqual(args["query"] as? String, "first query ...")
        XCTAssertEqual(args["queries"] as? [String], ["first query", "second query"])
        XCTAssertEqual(result["action"] as? String, "search")
        XCTAssertEqual(result["query"] as? String, "first query ...")
        XCTAssertEqual(result["queries"] as? [String], ["first query", "second query"])

        XCTAssertFalse(CodexNativeSessionController.test_isItemLifecycleNotificationMethod("rawResponseItem/completed"))
        XCTAssertNil(controller.test_parseToolLifecycleEvent(
            method: "rawResponseItem/completed",
            params: toolParams(item: [
                "type": "web_search_call",
                "status": "completed",
                "action": [
                    "type": "search",
                    "queries": ["first query", "second query"]
                ]
            ])
        ))

        let recovered = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "webSearch",
                "id": "ws_recovered_begin",
                "query": "",
                "action": NSNull()
            ])
        ))
        XCTAssertEqual(recovered.name, "search")
        XCTAssertNil(recovered.argsJSON)
    }

    func testNativeWebSearchNestedTaggedActionsPreserveCompactFieldsAcrossLifecycle() throws {
        let rows: [(label: String, action: [String: Any], expectedAction: String, expectedFields: [String: String])] = [
            (
                "search",
                ["type": "search", "query": "nested Codex query"],
                "search",
                ["query": "nested Codex query"]
            ),
            (
                "camel open page",
                ["type": "openPage", "url": "https://docs.example.com/open", "refId": "turn0search0"],
                "open_page",
                ["url": "https://docs.example.com/open", "refId": "turn0search0"]
            ),
            (
                "actual targetless find in page",
                ["type": "findInPage", "url": NSNull(), "pattern": "installation"],
                "find_in_page",
                ["pattern": "installation"]
            )
        ]

        for (index, row) in rows.enumerated() {
            let controller = makeController()
            let itemID = "call_nested_web_\(index)"
            let started = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/started",
                params: toolParams(item: [
                    "type": "webSearch",
                    "id": itemID,
                    "action": row.action
                ])
            ), row.label)
            XCTAssertEqual(started.kind, "call", row.label)
            XCTAssertEqual(started.name, "search", row.label)
            let startedArgs = try XCTUnwrap(jsonObject(from: started.argsJSON), row.label)
            XCTAssertEqual(startedArgs["action"] as? String, row.expectedAction, row.label)
            for (key, value) in row.expectedFields {
                XCTAssertEqual(startedArgs[key] as? String, value, "\(row.label) started \(key)")
            }

            let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/completed",
                params: toolParams(item: [
                    "type": "webSearch",
                    "id": itemID,
                    "status": "completed",
                    "action": row.action
                ])
            ), row.label)
            XCTAssertEqual(completed.kind, "result", row.label)
            XCTAssertEqual(completed.name, "search", row.label)
            XCTAssertEqual(completed.invocationID, started.invocationID, row.label)
            let completedArgs = try XCTUnwrap(jsonObject(from: completed.argsJSON), row.label)
            let completedResult = try XCTUnwrap(jsonObject(from: completed.resultJSON), row.label)
            XCTAssertEqual(completedArgs["action"] as? String, row.expectedAction, row.label)
            XCTAssertEqual(completedResult["action"] as? String, row.expectedAction, row.label)
            for (key, value) in row.expectedFields {
                XCTAssertEqual(completedArgs[key] as? String, value, "\(row.label) completed args \(key)")
                XCTAssertEqual(completedResult[key] as? String, value, "\(row.label) completed result \(key)")
            }
        }

        let bodyMarker = "wrapped nested web body"
        let wrappedController = makeController()
        let wrapped = try XCTUnwrap(wrappedController.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "webSearch",
                "id": "call_nested_wrapped_find",
                "status": "failed",
                "action": [
                    "type": "findInPage",
                    "url": "https://docs.example.com/wrapped-find",
                    "pattern": "installation"
                ],
                "response": [
                    "title": "Wrapped find page",
                    "matches": [["text": String(repeating: bodyMarker, count: 100)]],
                    "error": ["message": "wrapped find failed"],
                    "content": String(repeating: bodyMarker, count: 100)
                ]
            ])
        ))
        let wrappedResult = try XCTUnwrap(jsonObject(from: wrapped.resultJSON))
        XCTAssertEqual(wrappedResult["action"] as? String, "find_in_page")
        XCTAssertEqual(wrappedResult["url"] as? String, "https://docs.example.com/wrapped-find")
        XCTAssertEqual(wrappedResult["pattern"] as? String, "installation")
        XCTAssertEqual(wrappedResult["title"] as? String, "Wrapped find page")
        XCTAssertEqual(wrappedResult["match_count"] as? Int, 1)
        XCTAssertEqual((wrappedResult["error"] as? [String: Any])?["message"] as? String, "wrapped find failed")
        XCTAssertFalse(wrapped.resultJSON?.contains(bodyMarker) == true)
    }

    func testNativeWebReadAndFindEventsUseCanonicalWebReadNameAndCompactResults() throws {
        let controller = makeController()
        let started = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/started",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_webfetch",
                "name": "webfetch",
                "url": "https://docs.example.com/a/b/c",
                "needle": "install"
            ])
        ))
        XCTAssertEqual(started.kind, "call")
        XCTAssertEqual(started.name, "web_read")
        let args = try XCTUnwrap(jsonObject(from: started.argsJSON))
        XCTAssertEqual(args["url"] as? String, "https://docs.example.com/a/b/c")
        XCTAssertEqual(args["needle"] as? String, "install")

        let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_webfetch",
                "name": "webfetch",
                "status": "completed",
                "url": "https://docs.example.com/a/b/c",
                "needle": "install",
                "matches": [["text": String(repeating: "full page body ", count: 80)]],
                "content": String(repeating: "full page body ", count: 80)
            ])
        ))
        XCTAssertEqual(completed.kind, "result")
        XCTAssertEqual(completed.name, "web_read")
        let result = try XCTUnwrap(jsonObject(from: completed.resultJSON))
        XCTAssertEqual(result["url"] as? String, "https://docs.example.com/a/b/c")
        XCTAssertEqual(result["needle"] as? String, "install")
        XCTAssertEqual(result["match_count"] as? Int, 1)
        XCTAssertNil(result["matches"])
        XCTAssertNil(result["content"])
        XCTAssertFalse(completed.resultJSON?.contains("full page body") == true)
    }

    func testNativeWebReadWrapperResultsUnwrapCompactMetadataAndErrors() throws {
        for wrapperKey in ["result", "output", "response", "content"] {
            let bodyMarker = "full wrapped page body"
            let controller = makeController()
            let completed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/completed",
                params: toolParams(item: [
                    "type": "toolCall",
                    "id": "call_web_read_\(wrapperKey)",
                    "name": "web_fetch",
                    "url": "https://docs.example.com/wrapped",
                    wrapperKey: [
                        "status": "completed",
                        "title": "Wrapped docs",
                        "description": String(repeating: "compact metadata ", count: 80),
                        "error": [
                            "message": "bounded warning",
                            "code": 42,
                            "details": String(repeating: "unbounded detail ", count: 100)
                        ],
                        "content": String(repeating: bodyMarker, count: 100)
                    ]
                ])
            ), wrapperKey)

            XCTAssertEqual(completed.name, "web_read", wrapperKey)
            let result = try XCTUnwrap(jsonObject(from: completed.resultJSON), wrapperKey)
            XCTAssertEqual(result["url"] as? String, "https://docs.example.com/wrapped", wrapperKey)
            XCTAssertEqual(result["status"] as? String, "completed", wrapperKey)
            XCTAssertEqual(result["title"] as? String, "Wrapped docs", wrapperKey)
            XCTAssertLessThanOrEqual((result["description"] as? String)?.count ?? 0, 500, wrapperKey)
            let error = try XCTUnwrap(result["error"] as? [String: Any], wrapperKey)
            XCTAssertEqual(error["message"] as? String, "bounded warning", wrapperKey)
            XCTAssertEqual(error["code"] as? Int, 42, wrapperKey)
            XCTAssertNil(error["details"], wrapperKey)
            XCTAssertNil(result[wrapperKey], wrapperKey)
            XCTAssertFalse(completed.resultJSON?.contains(bodyMarker) == true, wrapperKey)

            let bodyOnly = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/completed",
                params: toolParams(item: [
                    "type": "toolCall",
                    "id": "call_web_read_body_only_\(wrapperKey)",
                    "name": "web_fetch",
                    wrapperKey: ["content": String(repeating: bodyMarker, count: 100)]
                ])
            ), "\(wrapperKey) body only")
            XCTAssertEqual(try XCTUnwrap(jsonObject(from: bodyOnly.resultJSON)).count, 0, wrapperKey)
            XCTAssertFalse(bodyOnly.resultJSON?.contains(bodyMarker) == true, wrapperKey)

            let successfulScalar = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/completed",
                params: toolParams(item: [
                    "type": "toolCall",
                    "id": "call_web_read_scalar_success_\(wrapperKey)",
                    "name": "web_fetch",
                    "status": "completed",
                    wrapperKey: String(repeating: bodyMarker, count: 100)
                ])
            ), "\(wrapperKey) successful scalar")
            let scalarResult = try XCTUnwrap(jsonObject(from: successfulScalar.resultJSON), wrapperKey)
            XCTAssertEqual(scalarResult.count, 1, wrapperKey)
            XCTAssertEqual(scalarResult["status"] as? String, "completed", wrapperKey)
            XCTAssertFalse(successfulScalar.resultJSON?.contains(bodyMarker) == true, wrapperKey)
        }

        for wrapperKey in ["result", "output", "response"] {
            let controller = makeController()
            let failed = try XCTUnwrap(controller.test_parseToolLifecycleEvent(
                method: "item/completed",
                params: toolParams(item: [
                    "type": "toolCall",
                    "id": "call_web_read_scalar_failure_\(wrapperKey)",
                    "name": "web_fetch",
                    "status": "failed",
                    wrapperKey: "request timed out"
                ])
            ), "\(wrapperKey) failed scalar")
            let failedResult = try XCTUnwrap(jsonObject(from: failed.resultJSON), wrapperKey)
            XCTAssertEqual(failedResult["status"] as? String, "failed", wrapperKey)
            XCTAssertEqual(failedResult["errorMessage"] as? String, "request timed out", wrapperKey)
        }

        let nestedFailureController = makeController()
        let nestedFailure = try XCTUnwrap(nestedFailureController.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_web_read_nested_failure",
                "name": "web_fetch",
                "result": [
                    "status": "failed",
                    "message": "request blocked"
                ]
            ])
        ))
        let nestedFailureResult = try XCTUnwrap(jsonObject(from: nestedFailure.resultJSON))
        XCTAssertEqual(nestedFailureResult["status"] as? String, "failed")
        XCTAssertEqual(nestedFailureResult["errorMessage"] as? String, "request blocked")

        let legacyMessageController = makeController()
        let legacyMessage = try XCTUnwrap(legacyMessageController.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "toolCall",
                "id": "call_web_read_legacy_message",
                "name": "web_fetch",
                "isError": true,
                "message": "legacy request failed"
            ])
        ))
        let legacyMessageResult = try XCTUnwrap(jsonObject(from: legacyMessage.resultJSON))
        XCTAssertEqual(legacyMessageResult["errorMessage"] as? String, "legacy request failed")
    }

    func testNativeWebSearchCompletionPayloadsPreserveCompactSearchFields() throws {
        let longQuery = String(repeating: "query", count: 140)
        let boundedController = makeController()
        let bounded = try XCTUnwrap(boundedController.test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "webSearch",
                "id": "call_search_bounded_query",
                "query": longQuery,
                "action": ["type": "search", "query": longQuery]
            ])
        ))
        let boundedArgs = try XCTUnwrap(jsonObject(from: bounded.argsJSON))
        let boundedResult = try XCTUnwrap(jsonObject(from: bounded.resultJSON))
        XCTAssertEqual((boundedArgs["query"] as? String)?.count, 500)
        XCTAssertEqual((boundedResult["query"] as? String)?.count, 500)
        XCTAssertTrue((boundedResult["query"] as? String)?.hasSuffix("…") == true)

        let rawQueries = (0 ..< 12).map { index in
            index == 0 ? longQuery : "query \(index)"
        }
        let boundedList = try XCTUnwrap(makeController().test_parseToolLifecycleEvent(
            method: "item/completed",
            params: toolParams(item: [
                "type": "webSearch",
                "id": "call_search_bounded_queries",
                "action": ["type": "search", "queries": rawQueries]
            ])
        ))
        let boundedListArgs = try XCTUnwrap(jsonObject(from: boundedList.argsJSON))
        let boundedListResult = try XCTUnwrap(jsonObject(from: boundedList.resultJSON))
        let argsQueries = try XCTUnwrap(boundedListArgs["queries"] as? [String])
        let resultQueries = try XCTUnwrap(boundedListResult["queries"] as? [String])
        XCTAssertEqual(argsQueries.count, 10)
        XCTAssertEqual(resultQueries, argsQueries)
        XCTAssertEqual(argsQueries.first?.count, 500)
        XCTAssertTrue(argsQueries.first?.hasSuffix("…") == true)

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
