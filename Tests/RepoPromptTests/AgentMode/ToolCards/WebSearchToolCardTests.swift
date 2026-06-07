@testable import RepoPrompt
import XCTest

final class WebSearchToolCardTests: XCTestCase {
    func testWebSearchNamesStayDistinctFromFileSearchAndRouteAsKnownResult() {
        for alias in ["search", "web_search", "web_search_request", "google_web_search", "search_web", "websearch"] {
            XCTAssertEqual(normalizedToolCardName(alias), "search", alias)
            XCTAssertEqual(AgentToolResultPersistencePolicy.normalizedToolName(alias), "search", alias)
        }
        for alias in ["webfetch", "web_fetch", "browser_open", "browser.open", "open_url"] {
            XCTAssertEqual(normalizedToolCardName(alias), "web_read", alias)
            XCTAssertEqual(AgentToolResultPersistencePolicy.normalizedToolName(alias), "web_read", alias)
        }
        for alias in ["file_search", "filesearch", "grep"] {
            XCTAssertEqual(AgentToolResultPersistencePolicy.normalizedToolName(alias), "file_search", alias)
        }
        XCTAssertTrue(ToolCardRouter.knownResultTools.contains("search"))
    }

    func testWebActionClassifierDistinguishesSearchReadFindAndCodeSearch() throws {
        XCTAssertEqual(webPresentation(toolName: "search", args: ["query": "native web search cards"])?.title, "Web Search")

        let searchWithSources = webPresentation(
            toolName: "search",
            args: ["query": "native web search cards"],
            result: ["sources": [["url": "https://example.com/source"]]]
        )
        XCTAssertEqual(searchWithSources?.title, "Web Search")

        let resultOnlyURL = webPresentation(toolName: "search", result: ["url": "https://example.com/page"])
        XCTAssertEqual(resultOnlyURL?.title, "Web Search")

        let read = try XCTUnwrap(webPresentation(toolName: "webfetch", args: ["url": "https://docs.example.com/a/b/c"]), "webfetch read")
        XCTAssertEqual(read.title, "Read Web Page")
        XCTAssertEqual(read.subtitle, "docs.example.com/…/c")

        XCTAssertEqual(webPresentation(toolName: "browser_open", args: ["url": "https://example.com/docs"])?.title, "Read Web Page")
        XCTAssertEqual(webPresentation(toolName: "browser.open", args: ["url": "https://example.com/docs"])?.title, "Read Web Page")
        XCTAssertEqual(webPresentation(toolName: "search", args: ["url": "https://example.com/docs", "action": "open"])?.title, "Read Web Page")

        let find = try XCTUnwrap(webPresentation(toolName: "search", args: ["url": "https://example.com/docs", "pattern": "install"]), "search find")
        XCTAssertEqual(find.title, "Find In Page")
        XCTAssertTrue(find.subtitle?.contains("example.com/docs") == true)
        XCTAssertTrue(find.subtitle?.contains("install") == true)
        XCTAssertEqual(webPresentation(toolName: "webfetch", args: ["url": "https://example.com/docs", "needle": "API"])?.title, "Find In Page")
        XCTAssertEqual(webPresentation(toolName: "search", args: ["pattern": "install"])?.title, "Web Search")
        XCTAssertNil(webPresentation(toolName: "file_search", args: ["pattern": "TODO", "path": "Sources"]))
        XCTAssertNil(webPresentation(toolName: "grep", args: ["pattern": "TODO"]))
        XCTAssertNil(webPresentation(toolName: "webfetch", args: ["uri": "file:///tmp/x", "pattern": "TODO"]))
        XCTAssertEqual(webPresentation(toolName: "search", result: ["results": [["url": "https://example.com/result"]]])?.title, "Web Search")
    }

    func testNestedTaggedWebActionsClassifySearchOpenAndFind() throws {
        let search = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["action": ["type": "search", "query": "nested query"]]
        ))
        XCTAssertEqual(search.title, "Web Search")
        XCTAssertEqual(search.subtitle, "\"nested query\"")

        let multiSearch = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["action": ["type": "search", "queries": ["first query", "second query"]]]
        ))
        XCTAssertEqual(multiSearch.title, "Web Search")
        XCTAssertEqual(multiSearch.subtitle, "\"first query ...\"")

        let open = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["action": ["type": "openPage", "url": "https://example.com/docs"]]
        ))
        XCTAssertEqual(open.title, "Read Web Page")
        XCTAssertEqual(open.subtitle, "example.com/docs")

        let find = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["action": ["type": "findInPage", "url": NSNull(), "pattern": "install"]]
        ))
        XCTAssertEqual(find.title, "Find In Page")
        XCTAssertEqual(find.subtitle, "\"install\"")
        XCTAssertEqual(
            webPresentation(toolName: "search", args: ["action": "find_in_page", "pattern": "install"])?.title,
            "Find In Page"
        )

        for query in [
            "https://example.com/docs",
            "'installation' in https://example.com/docs"
        ] {
            let authoritativeSearch = try XCTUnwrap(webPresentation(
                toolName: "search",
                args: ["query": query, "action": ["type": "search", "query": query]]
            ), query)
            XCTAssertEqual(authoritativeSearch.title, "Web Search", query)
            XCTAssertEqual(authoritativeSearch.op, "search", query)
        }
    }

    func testCodexSearchQueryGrammarRecognizesReadAndFindInPage() throws {
        let read = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["query": "https://www.theguardian.com/europe"]
        ))
        XCTAssertEqual(read.title, "Read Web Page")
        XCTAssertEqual(read.subtitle, "www.theguardian.com/europe")
        XCTAssertEqual(read.op, "read_web_page")

        let normalizedOnlyRead = try XCTUnwrap(AgentWebToolActionPresentation.classify(AgentWebToolActionInput(
            rawToolName: "codex_web_search",
            normalizedToolName: "search",
            argsObject: ["query": "https://example.com/docs"],
            resultObject: nil
        )))
        XCTAssertEqual(normalizedOnlyRead.title, "Read Web Page")
        XCTAssertEqual(normalizedOnlyRead.subtitle, "example.com/docs")

        let quotedFind = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["query": "'Netherlands' in https://www.theguardian.com/europe"]
        ))
        XCTAssertEqual(quotedFind.title, "Find In Page")
        XCTAssertEqual(quotedFind.subtitle, "www.theguardian.com/europe • \"Netherlands\"")
        XCTAssertEqual(quotedFind.op, "find_in_page")

        let unquotedFind = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["query": "Netherlands in https://www.theguardian.com/europe"]
        ))
        XCTAssertEqual(unquotedFind.title, "Find In Page")
        XCTAssertEqual(unquotedFind.subtitle, "www.theguardian.com/europe • \"Netherlands\"")

        let curlyPossessiveFind = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["query": "teachers’ in https://example.com"]
        ))
        XCTAssertEqual(curlyPossessiveFind.title, "Find In Page")
        XCTAssertEqual(curlyPossessiveFind.subtitle, "example.com • \"teachers’\"")

        let straightPossessiveFind = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["query": "dogs' in https://example.com"]
        ))
        XCTAssertEqual(straightPossessiveFind.title, "Find In Page")
        XCTAssertEqual(straightPossessiveFind.subtitle, "example.com • \"dogs'\"")
    }

    func testCodexSearchQueryGrammarKeepsOrdinaryURLMentionsAsWebSearchAndExcludesCodeSearch() throws {
        for query in [
            "Netherlands https://www.theguardian.com/europe",
            "https://www.theguardian.com/europe Netherlands",
            "site:https://www.theguardian.com/europe Netherlands",
            "Netherlands in https://www.theguardian.com/europe latest news"
        ] {
            let presentation = try XCTUnwrap(webPresentation(toolName: "search", args: ["query": query]), query)
            XCTAssertEqual(presentation.title, "Web Search", query)
            XCTAssertEqual(presentation.op, "search", query)
        }

        XCTAssertNil(webPresentation(toolName: "file_search", args: ["query": "https://example.com/docs"]))
        XCTAssertNil(webPresentation(toolName: "grep", args: ["query": "'needle' in https://example.com/docs"]))
    }

    func testWebActionSubtitleFormatting() throws {
        XCTAssertEqual(webPresentation(toolName: "webfetch", args: ["url": "https://example.com"])?.subtitle, "example.com")
        XCTAssertEqual(webPresentation(toolName: "webfetch", args: ["url": "https://example.com/docs/api?token=secret#section"])?.subtitle, "example.com/docs/api")
        XCTAssertEqual(webPresentation(toolName: "webfetch", args: ["url": "https://example.com/docs/api/"])?.subtitle, "example.com/docs/api")
        XCTAssertEqual(webPresentation(toolName: "webfetch", args: ["url": "https://example.com/a/b/c/d"])?.subtitle, "example.com/…/d")
        XCTAssertEqual(webPresentation(toolName: "webfetch", args: ["url": "https://example.com/docs/Swift%20API"])?.subtitle, "example.com/docs/Swift API")
        let longURL = "https://example.com/docs/" + String(repeating: "very-long-component-", count: 8)
        XCTAssertLessThanOrEqual(try XCTUnwrap(webPresentation(toolName: "webfetch", args: ["url": longURL])?.subtitle).count, 80)
        XCTAssertEqual(webPresentation(toolName: "webfetch", args: ["ref_id": "abc123"])?.subtitle, "ref abc123")
        XCTAssertTrue(try XCTUnwrap(webPresentation(toolName: "webfetch", args: ["ref_id": "abcdefghijklmnopqrstuvwxyz0123456789"])?.subtitle).contains("…"))
    }

    func testRunningCallPresentationUsesWebActionLabels() throws {
        let readItem = AgentChatItem(
            kind: .toolCall,
            text: "",
            toolName: "webfetch",
            toolArgsJSON: jsonString(["url": "https://docs.example.com/a/b/c"])
        )
        let read = try XCTUnwrap(ToolCardRouter.callPresentation(for: readItem))
        XCTAssertEqual(read.title, "Read Web Page")
        XCTAssertEqual(read.subtitle, "docs.example.com/…/c")

        let findItem = AgentChatItem(
            kind: .toolCall,
            text: "",
            toolName: "search",
            toolArgsJSON: jsonString(["url": "https://example.com/docs", "pattern": "needle"])
        )
        let find = try XCTUnwrap(ToolCardRouter.callPresentation(for: findItem))
        XCTAssertEqual(find.title, "Find In Page")

        let fileSearchItem = AgentChatItem(
            kind: .toolCall,
            text: "",
            toolName: "file_search",
            toolArgsJSON: jsonString(["pattern": "needle"])
        )
        XCTAssertNil(ToolCardRouter.callPresentation(for: fileSearchItem))
    }

    func testReadAndFindPresentationsCoverLiveAndSummaryOnlyPayloads() throws {
        let readArgs = jsonString(["url": "https://docs.example.com/a/b/c"])
        let readRaw = jsonString(["status": "completed", "title": "Docs page", "content": String(repeating: "body ", count: 200)])
        let readItem = AgentChatItem(kind: .toolResult, text: readRaw, toolName: "webfetch", toolArgsJSON: readArgs, toolResultJSON: readRaw, toolIsError: false)
        let read = try XCTUnwrap(NativeToolCardPresentationBuilder.build(item: readItem, normalizedToolName: "web_read"))
        XCTAssertEqual(read.toolName, "web_read")
        XCTAssertEqual(read.title, "Read Web Page")
        XCTAssertEqual(read.subtitle, "docs.example.com/…/c")
        XCTAssertEqual(read.detailText, "Docs page")
        XCTAssertFalse(read.dictionary.description.contains("body body"))

        let findArgs = jsonString(["url": "https://example.com/docs", "pattern": "needle"])
        let findRaw = jsonString(["status": "completed", "match_count": 3])
        let findItem = AgentChatItem(kind: .toolResult, text: findRaw, toolName: "search", toolArgsJSON: findArgs, toolResultJSON: findRaw, toolIsError: false)
        let find = try XCTUnwrap(NativeToolCardPresentationBuilder.build(item: findItem, normalizedToolName: "search"))
        XCTAssertEqual(find.toolName, "search")
        XCTAssertEqual(find.title, "Find In Page")
        XCTAssertEqual(find.op, "find_in_page")
        XCTAssertEqual(find.detailText, "3 matches")

        let minimalWebReadSummary = jsonString([
            "status": "success",
            "summary_only": true,
            "render_summary": ["schema_version": 1, "tool_name": "web_read", "status": "success", "subtitle": "example.com/docs"]
        ])
        let minimalStoredItem = AgentChatItem(kind: .toolResult, text: minimalWebReadSummary, toolName: "webfetch", toolResultJSON: minimalWebReadSummary, toolIsError: false)
        let minimalStored = try XCTUnwrap(NativeToolCardPresentationBuilder.build(item: minimalStoredItem, normalizedToolName: "web_read"))
        XCTAssertEqual(minimalStored.title, "Read Web Page")

        let summaryOnly = jsonString(["status": "success", "summary_only": true, "render_summary": find.dictionary])
        let storedItem = AgentChatItem(kind: .toolResult, text: summaryOnly, toolName: "search", toolArgsJSON: findArgs, toolResultJSON: summaryOnly, toolIsError: false)
        let stored = try XCTUnwrap(NativeToolCardPresentationBuilder.build(item: storedItem, normalizedToolName: "search"))
        XCTAssertEqual(stored.title, "Find In Page")
        XCTAssertEqual(stored.subtitle, find.subtitle)
    }

    func testLegacyWebReadSummaryAliasesRestoreByCanonicalEquivalenceWithoutSpoofing() throws {
        for alias in ["webfetch", "web_fetch"] {
            let renderSummary = AgentToolCardRenderSummary(
                toolName: alias,
                title: "Read Web Page",
                subtitle: "example.com/docs",
                detailText: "Legacy docs",
                status: .success,
                op: "read_web_page"
            )
            let summaryOnly = jsonString([
                "status": "success",
                "summary_only": true,
                "render_summary": renderSummary.dictionary
            ])
            let legacyItem = AgentChatItem(
                kind: .toolResult,
                text: summaryOnly,
                toolName: alias,
                toolResultJSON: summaryOnly,
                toolIsError: false
            )
            let restored = try XCTUnwrap(
                NativeToolCardPresentationBuilder.build(item: legacyItem, normalizedToolName: "web_read"),
                alias
            )
            XCTAssertEqual(restored.title, "Read Web Page", alias)
            XCTAssertEqual(restored.subtitle, "example.com/docs", alias)

            XCTAssertNil(NativeToolCardPresentationBuilder.build(
                item: AgentChatItem(
                    kind: .toolResult,
                    text: summaryOnly,
                    toolName: "weather_lookup",
                    toolResultJSON: summaryOnly
                ),
                normalizedToolName: "weather_lookup"
            ), alias)
        }
    }

    func testWebSearchPresentationCoversLiveAndSummaryOnlyPayloads() throws {
        let args = jsonString(["query": "native web search cards"])
        let raw = jsonString([
            "status": "completed",
            "query": "native web search cards",
            "total_results": 12,
            "response": [
                "web_results": [["title": "Native card", "snippet": "Readable web result"]],
                "citations": [["title": "Docs"]]
            ],
            "errorMessage": "stale retry warning"
        ])
        let liveItem = AgentChatItem(
            kind: .toolResult,
            text: raw,
            toolName: "search",
            toolArgsJSON: args,
            toolResultJSON: raw,
            toolIsError: false
        )

        let live = try XCTUnwrap(NativeToolCardPresentationBuilder.build(item: liveItem, normalizedToolName: "search"))
        XCTAssertEqual(live.title, "Web Search")
        XCTAssertEqual(live.status, .success)
        XCTAssertTrue(live.subtitle?.contains("native web search cards") == true)
        XCTAssertTrue(live.subtitle?.contains("12 results") == true)
        XCTAssertTrue(live.subtitle?.contains("1 source") == true)
        XCTAssertTrue(live.detailText?.contains("Native card") == true)
        XCTAssertFalse(live.detailText?.contains("stale retry") == true)

        let summaryOnly = jsonString([
            "status": "success",
            "summary_only": true,
            "render_summary": live.dictionary
        ])
        let storedItem = AgentChatItem(
            kind: .toolResult,
            text: summaryOnly,
            toolName: "search",
            toolArgsJSON: args,
            toolResultJSON: summaryOnly,
            toolIsError: false
        )
        let stored = try XCTUnwrap(NativeToolCardPresentationBuilder.build(item: storedItem, normalizedToolName: "search"))
        XCTAssertEqual(stored.title, "Web Search")
        XCTAssertEqual(stored.status, .success)
        XCTAssertEqual(stored.subtitle, live.subtitle)
        XCTAssertFalse(toolResultHasPayload(storedItem))
    }

    func testNativeFallbackRequiresSafeNameMatchingSummaryAndScalarSignals() throws {
        let spoofedSummary = AgentToolCardRenderSummary(
            toolName: "search",
            title: "Web Search",
            subtitle: "\"spoofed\"",
            detailText: "spoofed detail",
            status: .success,
            op: "search"
        )
        let spoofedRaw = jsonString([
            "status": "success",
            "summary_only": true,
            "render_summary": spoofedSummary.dictionary
        ])
        XCTAssertNil(NativeToolCardPresentationBuilder.build(
            item: AgentChatItem(kind: .toolResult, text: spoofedRaw, toolName: "mcp__RepoPrompt__unknown", toolResultJSON: spoofedRaw),
            normalizedToolName: "mcp__RepoPrompt__unknown"
        ))
        XCTAssertNil(NativeToolCardPresentationBuilder.build(
            item: AgentChatItem(kind: .toolResult, text: spoofedRaw, toolName: "weather_lookup", toolResultJSON: spoofedRaw),
            normalizedToolName: "weather_lookup"
        ))

        let safeItem = AgentChatItem(
            kind: .toolResult,
            text: jsonString(["status": "completed", "summary": "Sunny and mild"]),
            toolName: "weather_lookup",
            toolArgsJSON: jsonString(["query": "tomorrow weather"]),
            toolResultJSON: jsonString(["status": "completed", "summary": "Sunny and mild"]),
            toolIsError: false
        )
        let safe = try XCTUnwrap(NativeToolCardPresentationBuilder.build(item: safeItem, normalizedToolName: "weather_lookup"))
        XCTAssertEqual(safe.title, "Weather Lookup")
        XCTAssertEqual(safe.subtitle, "tomorrow weather")
        XCTAssertEqual(safe.detailText, "Sunny and mild")
        XCTAssertNil(NativeToolCardPresentationBuilder.build(item: safeItem, normalizedToolName: "tool"))
    }

    private func webPresentation(
        toolName: String,
        args: [String: Any]? = nil,
        result: [String: Any]? = nil
    ) -> AgentWebToolActionPresentation? {
        AgentWebToolActionPresentation.classify(AgentWebToolActionInput(
            rawToolName: toolName,
            normalizedToolName: normalizedToolCardName(toolName),
            argsObject: args,
            resultObject: result
        ))
    }

    private func jsonString(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object), file: file, line: line)
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
