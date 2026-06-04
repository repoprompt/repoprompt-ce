@testable import RepoPrompt
import XCTest

final class WebSearchToolCardTests: XCTestCase {
    func testWebSearchNamesStayDistinctFromFileSearchAndRouteAsKnownResult() {
        for alias in ["search", "web_search", "web_search_request", "google_web_search", "search_web"] {
            XCTAssertEqual(normalizedToolCardName(alias), "search", alias)
            XCTAssertEqual(AgentToolResultPersistencePolicy.normalizedToolName(alias), "search", alias)
        }
        for alias in ["file_search", "filesearch", "grep"] {
            XCTAssertEqual(AgentToolResultPersistencePolicy.normalizedToolName(alias), "file_search", alias)
        }
        XCTAssertTrue(ToolCardRouter.knownResultTools.contains("search"))
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

    private func jsonString(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object), file: file, line: line)
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
