import Foundation
@testable import RepoPrompt
import XCTest

final class NetworkMCPStreamableHTTPTransportTests: XCTestCase {
    func testNotificationOnlyPostReturnsAcceptedAndYieldsInboundMessage() async throws {
        let transport = MCPStreamableHTTPTransport(sessionID: "session-1", responseTimeout: 1)
        try await transport.connect()
        var iterator = await transport.receive().makeAsyncIterator()
        let body = jsonData(["jsonrpc": "2.0", "method": "notifications/initialized"])

        let response = await transport.handle(post(body: body, sessionID: "session-1"))
        let yielded = try await iterator.next()

        XCTAssertEqual(response.statusCode, 202)
        XCTAssertEqual(response.headers[MCPStreamableHTTPHeader.sessionID], "session-1")
        XCTAssertEqual(yielded, body)
    }

    func testRequestPostCorrelatesResponseByJSONRPCID() async throws {
        let transport = MCPStreamableHTTPTransport(sessionID: "session-2", responseTimeout: 1)
        try await transport.connect()
        var iterator = await transport.receive().makeAsyncIterator()
        let body = jsonData(["jsonrpc": "2.0", "id": 7, "method": "tools/list"])

        let responseTask = Task {
            await transport.handle(post(body: body, sessionID: "session-2"))
        }
        let yielded = try await iterator.next()
        XCTAssertEqual(yielded, body)

        let outbound = jsonData(["jsonrpc": "2.0", "id": 7, "result": ["tools": []]])
        try await transport.send(outbound)
        let response = await responseTask.value

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try JSONObject(response.body), try JSONObject(outbound))
        XCTAssertEqual(response.headers[MCPStreamableHTTPHeader.sessionID], "session-2")
    }

    func testBatchRequestWaitsForAllResponsesAndPreservesRequestOrder() async throws {
        let transport = MCPStreamableHTTPTransport(sessionID: "session-3", responseTimeout: 1)
        try await transport.connect()
        var iterator = await transport.receive().makeAsyncIterator()
        let body = jsonData([
            ["jsonrpc": "2.0", "id": "a", "method": "tools/list"],
            ["jsonrpc": "2.0", "id": "b", "method": "tools/call", "params": ["name": "x"]]
        ])

        let responseTask = Task {
            await transport.handle(post(body: body, sessionID: "session-3"))
        }
        _ = try await iterator.next()

        try await transport.send(jsonData(["jsonrpc": "2.0", "id": "b", "result": ["ok": "b"]]))
        try await transport.send(jsonData(["jsonrpc": "2.0", "id": "a", "result": ["ok": "a"]]))
        let response = await responseTask.value

        XCTAssertEqual(response.statusCode, 200)
        let responseArray = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(response.body)) as? [[String: Any]])
        XCTAssertEqual(responseArray.compactMap { $0["id"] as? String }, ["a", "b"])
    }

    func testMissingSessionHeaderFailsClosedForNonInitializePost() async throws {
        let transport = MCPStreamableHTTPTransport(sessionID: "session-4", responseTimeout: 1)
        try await transport.connect()
        let body = jsonData(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])

        let response = await transport.handle(post(body: body, sessionID: nil))

        XCTAssertEqual(response.statusCode, 400)
    }

    func testInitializeCanCreateSessionWithoutSessionHeader() async throws {
        let transport = MCPStreamableHTTPTransport(sessionID: "session-5", responseTimeout: 1)
        try await transport.connect()
        var iterator = await transport.receive().makeAsyncIterator()
        let body = jsonData([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": "2025-11-25", "clientInfo": ["name": "OpenClaw", "version": "test"]]
        ])

        let responseTask = Task {
            await transport.handle(post(body: body, sessionID: nil))
        }
        _ = try await iterator.next()
        let outbound = jsonData(["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2025-11-25"]])
        try await transport.send(outbound)
        let response = await responseTask.value

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers[MCPStreamableHTTPHeader.sessionID], "session-5")
    }

    func testGetUnsupportedAndDeleteTerminatesSession() async throws {
        let transport = MCPStreamableHTTPTransport(sessionID: "session-6", responseTimeout: 1)
        try await transport.connect()

        let getResponse = await transport.handle(.init(method: "GET", path: "/mcp", headers: [MCPStreamableHTTPHeader.sessionID: "session-6"]))
        XCTAssertEqual(getResponse.statusCode, 405)
        XCTAssertEqual(getResponse.headers[MCPStreamableHTTPHeader.allow], "POST, DELETE")

        let deleteResponse = await transport.handle(.init(method: "DELETE", path: "/mcp", headers: [MCPStreamableHTTPHeader.sessionID: "session-6"]))
        XCTAssertEqual(deleteResponse.statusCode, 200)

        let afterDelete = await transport.handle(post(body: jsonData(["jsonrpc": "2.0", "method": "notifications/initialized"]), sessionID: "session-6"))
        XCTAssertEqual(afterDelete.statusCode, 404)
    }

    func testPendingRequestTimesOutDeterministically() async throws {
        let transport = MCPStreamableHTTPTransport(sessionID: "session-7", responseTimeout: 0.01)
        try await transport.connect()
        let body = jsonData(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])

        let response = await transport.handle(post(body: body, sessionID: "session-7"))

        XCTAssertEqual(response.statusCode, 504)
    }

    func testHTTPConnectionManagerPreservesSharedHandlerRegistrationPath() throws {
        let managerSource = try String(
            contentsOf: RepoRoot.url()
                .appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/HTTP/MCPHTTPConnectionManager.swift"),
            encoding: .utf8
        )
        let transportSource = try String(
            contentsOf: RepoRoot.url()
                .appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/HTTP/MCPStreamableHTTPTransport.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(managerSource.contains("parentManager.registerHandlers(for: server, connectionID: connectionID)"))
        XCTAssertFalse(managerSource.contains("ServiceRegistry.services"))
        XCTAssertFalse(managerSource.contains("toolDef.callAsFunction"))
        XCTAssertFalse(transportSource.contains("ServiceRegistry.services"))
        XCTAssertFalse(transportSource.contains("toolDef.callAsFunction"))
    }

    private func post(body: Data, sessionID: String?) -> MCPStreamableHTTPRequest {
        var headers = [MCPStreamableHTTPHeader.contentType: "application/json"]
        if let sessionID {
            headers[MCPStreamableHTTPHeader.sessionID] = sessionID
        }
        return MCPStreamableHTTPRequest(method: "POST", path: "/mcp", headers: headers, body: body)
    }

    private func jsonData(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func JSONObject(_ data: Data?) throws -> NSDictionary {
        let body = try XCTUnwrap(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? NSDictionary)
    }
}
