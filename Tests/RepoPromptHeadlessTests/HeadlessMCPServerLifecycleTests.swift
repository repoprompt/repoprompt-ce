import Foundation
@testable import RepoPromptHeadless
import XCTest

final class HeadlessMCPServerLifecycleTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testInitializeOnceAndInitializedNotificationGate() async throws {
        let fixture = try makeFixture()

        let earlyInitialized = try await fixture.server.handle(frame: notification("notifications/initialized"))
        XCTAssertNil(earlyInitialized.responseData)
        XCTAssertFalse(earlyInitialized.shouldExit)
        try await assertError(fixture.server, frame: request("ping"), code: -32002)

        let initializeNotification = try await fixture.server.handle(frame: notification("initialize"))
        XCTAssertNil(initializeNotification.responseData)
        XCTAssertFalse(initializeNotification.shouldExit)

        let initialize = try await fixture.server.handle(frame: initializeRequest())
        let initializeResponse = try responseObject(initialize)
        XCTAssertNotNil(initializeResponse["result"] as? [String: Any])
        XCTAssertFalse(initialize.shouldExit)

        try await assertError(fixture.server, frame: initializeRequest(id: 2), code: -32600)
        try await assertError(
            fixture.server,
            frame: request("notifications/initialized", id: NSNull()),
            code: -32600
        )
        try await assertError(fixture.server, frame: request("ping", id: 3), code: -32002)

        let initialized = try await fixture.server.handle(frame: notification("notifications/initialized"))
        XCTAssertNil(initialized.responseData)
        XCTAssertFalse(initialized.shouldExit)

        let ping = try await fixture.server.handle(frame: request("ping", id: 4))
        XCTAssertNotNil(try responseObject(ping)["result"] as? [String: Any])
        try await assertError(fixture.server, frame: initializeRequest(id: 5), code: -32600)
    }

    func testRequestOnlyNotificationsAreIgnoredWithoutExecutingTools() async throws {
        let fixture = try makeFixture(configureAllowedRoot: true)
        let preReadyMutation = try request(
            "tools/call",
            id: 8,
            params: [
                "name": "prompt",
                "arguments": ["op": "set", "text": "pre-ready request executed"]
            ]
        )
        try await assertError(fixture.server, frame: preReadyMutation, code: -32002)
        try await makeReady(fixture.server)

        let afterPreReady = try await fixture.server.handle(
            frame: request(
                "tools/call",
                id: 9,
                params: ["name": "prompt", "arguments": ["op": "get"]]
            )
        )
        let afterPreReadyResult = try XCTUnwrap(try responseObject(afterPreReady)["result"] as? [String: Any])
        let afterPreReadyStructured = try XCTUnwrap(afterPreReadyResult["structuredContent"] as? [String: Any])
        XCTAssertEqual(afterPreReadyStructured["prompt"] as? String, "")

        let validMutation = try await fixture.server.handle(
            frame: request(
                "tools/call",
                id: 10,
                params: [
                    "name": "prompt",
                    "arguments": ["op": "set", "text": "baseline"]
                ]
            )
        )
        let validResult = try XCTUnwrap(try responseObject(validMutation)["result"] as? [String: Any])
        let validStructured = try XCTUnwrap(validResult["structuredContent"] as? [String: Any])
        XCTAssertEqual(validStructured["prompt"] as? String, "baseline")

        for method in ["initialize", "ping", "tools/list", "shutdown"] {
            let action = try await fixture.server.handle(frame: notification(method))
            XCTAssertNil(action.responseData, "\(method) notification must not receive a response")
            XCTAssertFalse(action.shouldExit, "\(method) notification must not alter exit state")
        }

        let mutation = try notification(
            "tools/call",
            params: [
                "name": "prompt",
                "arguments": ["op": "set", "text": "notification executed"]
            ]
        )
        let mutationAction = await fixture.server.handle(frame: mutation)
        XCTAssertNil(mutationAction.responseData)
        XCTAssertFalse(mutationAction.shouldExit)

        let ping = try await fixture.server.handle(frame: request("ping", id: 11))
        XCTAssertNotNil(try responseObject(ping)["result"] as? [String: Any])

        let promptGet = try await fixture.server.handle(
            frame: request(
                "tools/call",
                id: 12,
                params: ["name": "prompt", "arguments": ["op": "get"]]
            )
        )
        let promptResult = try XCTUnwrap(try responseObject(promptGet)["result"] as? [String: Any])
        let structured = try XCTUnwrap(promptResult["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["prompt"] as? String, "baseline")
    }

    func testMalformedAndNonObjectFramesPreserveJSONRPCErrors() async throws {
        let fixture = try makeFixture()

        let malformed = await fixture.server.handle(frame: Data("{".utf8))
        XCTAssertEqual(try errorCode(malformed), -32700)
        XCTAssertTrue(try responseObject(malformed)["id"] is NSNull)
        XCTAssertFalse(malformed.shouldExit)

        let nonObject = await fixture.server.handle(frame: Data("[]".utf8))
        XCTAssertEqual(try errorCode(nonObject), -32600)
        XCTAssertTrue(try responseObject(nonObject)["id"] is NSNull)
        XCTAssertFalse(nonObject.shouldExit)
    }

    func testShutdownWaitsForExitAndRejectsFurtherRequests() async throws {
        let fixture = try makeFixture()

        try await assertError(fixture.server, frame: request("shutdown"), code: -32002)
        try await makeReady(fixture.server)

        let earlyExit = try await fixture.server.handle(frame: notification("exit"))
        XCTAssertNil(earlyExit.responseData)
        XCTAssertFalse(earlyExit.shouldExit)
        try await assertError(fixture.server, frame: request("exit", id: 20), code: -32600)

        let shutdown = try await fixture.server.handle(frame: request("shutdown", id: 21))
        let shutdownResponse = try responseObject(shutdown)
        XCTAssertTrue(shutdownResponse["result"] is NSNull)
        XCTAssertFalse(shutdown.shouldExit)

        try await assertError(fixture.server, frame: request("ping", id: 22), code: -32600)
        let exitRequest = try await fixture.server.handle(frame: request("exit", id: 23))
        XCTAssertFalse(exitRequest.shouldExit)
        XCTAssertEqual(try errorCode(exitRequest), -32600)

        let exitNotification = try await fixture.server.handle(frame: notification("exit"))
        XCTAssertNil(exitNotification.responseData)
        XCTAssertTrue(exitNotification.shouldExit)
    }

    func testReadyUnknownRequestsStillErrorAndUnknownNotificationsStaySilent() async throws {
        let fixture = try makeFixture()
        try await makeReady(fixture.server)

        try await assertError(fixture.server, frame: request("unknown/method"), code: -32601)
        let notification = try await fixture.server.handle(frame: notification("unknown/method"))
        XCTAssertNil(notification.responseData)
        XCTAssertFalse(notification.shouldExit)
    }

    func testInvalidInitializeParamsDoNotAdvanceLifecycle() async throws {
        let fixture = try makeFixture()

        try await assertError(fixture.server, frame: request("initialize"), code: -32602)
        let valid = try await fixture.server.handle(frame: initializeRequest(id: 2))
        XCTAssertNotNil(try responseObject(valid)["result"])
    }

    func testMalformedNoIDEnvelopeReturnsInvalidRequestWithNullID() async throws {
        let fixture = try makeFixture()
        let missingVersion = try JSONSerialization.data(withJSONObject: ["method": "ping"])
        let action = await fixture.server.handle(frame: missingVersion)
        let response = try responseObject(action)
        XCTAssertTrue(response["id"] is NSNull)
        XCTAssertEqual(try errorCode(action), -32600)
    }

    func testCancellationNotificationCancelsTrackedToolRequestWhilePingRemainsResponsive() async throws {
        let gate = BlockingHeadlessToolCallGate()
        let fixture = try makeFixture(toolCallOverride: { _, _ in
            try await gate.run()
        })
        try await makeReady(fixture.server)

        let searchFrame = try request(
            "tools/call",
            id: 40,
            params: ["name": "file_search", "arguments": ["pattern": "needle"]]
        )
        let searchTask = Task {
            await fixture.server.handle(frame: searchFrame)
        }
        await gate.waitUntilStarted()
        let activeBeforeCancellation = await fixture.server.activeRequestCountForTesting()
        XCTAssertEqual(activeBeforeCancellation, 1)

        let ping = try await fixture.server.handle(frame: request("ping", id: 41))
        XCTAssertNotNil(try responseObject(ping)["result"] as? [String: Any])

        let cancellation = try await fixture.server.handle(
            frame: notification("notifications/cancelled", params: ["requestId": 40])
        )
        XCTAssertNil(cancellation.responseData)
        let cancelled = await searchTask.value
        XCTAssertEqual(try errorCode(cancelled), -32800)
        XCTAssertEqual(try responseObject(cancelled)["id"] as? Int, 40)
        let activeAfterCancellation = await fixture.server.activeRequestCountForTesting()
        XCTAssertEqual(activeAfterCancellation, 0)
    }

    func testShutdownRespondsWhileTrackedToolRequestRemainsExplicitlyCancellable() async throws {
        let gate = BlockingHeadlessToolCallGate()
        let fixture = try makeFixture(toolCallOverride: { _, _ in
            try await gate.run()
        })
        try await makeReady(fixture.server)

        let searchFrame = try request(
            "tools/call",
            id: 50,
            params: ["name": "file_search", "arguments": ["pattern": "needle"]]
        )
        let searchTask = Task {
            await fixture.server.handle(frame: searchFrame)
        }
        await gate.waitUntilStarted()

        let shutdown = try await fixture.server.handle(frame: request("shutdown", id: 51))
        XCTAssertTrue(try responseObject(shutdown)["result"] is NSNull)
        XCTAssertFalse(shutdown.shouldExit)
        let activeAfterShutdown = await fixture.server.activeRequestCountForTesting()
        XCTAssertEqual(activeAfterShutdown, 1)

        let cancellation = try await fixture.server.handle(
            frame: notification("notifications/cancelled", params: ["requestId": 50])
        )
        XCTAssertNil(cancellation.responseData)
        let cancelledSearch = await searchTask.value
        XCTAssertEqual(try errorCode(cancelledSearch), -32800)

        let exit = try await fixture.server.handle(frame: notification("exit"))
        XCTAssertTrue(exit.shouldExit)
    }

    func testDuplicateActiveRequestIDIsRejectedAndIDCanBeReusedAfterCancellation() async throws {
        let gate = BlockingHeadlessToolCallGate()
        let fixture = try makeFixture(toolCallOverride: { _, _ in
            try await gate.run()
        })
        try await makeReady(fixture.server)

        let frame = try request(
            "tools/call",
            id: 70,
            params: ["name": "file_search", "arguments": ["pattern": "needle"]]
        )
        let first = Task { await fixture.server.handle(frame: frame) }
        try await waitForActiveRequests(1, server: fixture.server)

        let duplicate = await fixture.server.handle(frame: frame)
        XCTAssertEqual(try errorCode(duplicate), -32600)
        _ = try await fixture.server.handle(
            frame: notification("notifications/cancelled", params: ["requestId": 70])
        )
        let firstCancelled = await first.value
        XCTAssertEqual(try errorCode(firstCancelled), -32800)

        let reused = Task { await fixture.server.handle(frame: frame) }
        try await waitForActiveRequests(1, server: fixture.server)
        _ = try await fixture.server.handle(frame: request("shutdown", id: 71))
        _ = try await fixture.server.handle(
            frame: notification("notifications/cancelled", params: ["requestId": 70])
        )
        let reusedCancelled = await reused.value
        XCTAssertEqual(try errorCode(reusedCancelled), -32800)
    }

    private func makeFixture(
        configureAllowedRoot: Bool = false,
        toolCallOverride: HeadlessMCPServer.ToolCallOverride? = nil
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-headless-mcp-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let store = HeadlessConfigurationStore(
            paths: HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        )
        if configureAllowedRoot {
            let rootURL = directory.appendingPathComponent("AllowedRoot", isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let root = HeadlessAllowedRoot(
                id: UUID(),
                name: "Fixture",
                path: rootURL.path,
                resolvedPath: rootURL.resolvingSymlinksInPath().standardizedFileURL.path,
                addedAt: Date()
            )
            try store.update { configuration in
                configuration.allowedRoots = [root]
            }
        }
        return Fixture(server: HeadlessMCPServer(
            configurationStore: store,
            toolCallOverride: toolCallOverride
        ))
    }

    private func waitForActiveRequests(_ expected: Int, server: HeadlessMCPServer) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await server.activeRequestCountForTesting() == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(expected) active request(s)")
    }

    private func makeReady(_ server: HeadlessMCPServer) async throws {
        let initialize = try await server.handle(frame: initializeRequest())
        XCTAssertNotNil(initialize.responseData)
        let initialized = try await server.handle(frame: notification("notifications/initialized"))
        XCTAssertNil(initialized.responseData)
    }

    private func request(
        _ method: String,
        id: Any = 1,
        params: [String: Any]? = nil
    ) throws -> Data {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if let params {
            object["params"] = params
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func notification(_ method: String, params: [String: Any]? = nil) throws -> Data {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params {
            object["params"] = params
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func initializeRequest(id: Any = 1) throws -> Data {
        try request(
            "initialize",
            id: id,
            params: [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "headless-tests", "version": "1"]
            ]
        )
    }

    private func responseObject(_ action: HeadlessRPCAction) throws -> [String: Any] {
        let data = try XCTUnwrap(action.responseData)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func errorCode(_ action: HeadlessRPCAction) throws -> Int {
        let error = try XCTUnwrap(try responseObject(action)["error"] as? [String: Any])
        return try XCTUnwrap(error["code"] as? Int)
    }

    private func assertError(
        _ server: HeadlessMCPServer,
        frame: @autoclosure () throws -> Data,
        code: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let action = try await server.handle(frame: frame())
        XCTAssertEqual(try errorCode(action), code, file: file, line: line)
        XCTAssertFalse(action.shouldExit, file: file, line: line)
    }

    private struct Fixture {
        let server: HeadlessMCPServer
    }
}

private actor BlockingHeadlessToolCallGate {
    private var started = false

    func run() async throws -> HeadlessJSONObject {
        started = true
        while true {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }
}
