import Foundation
@testable import RepoPromptHeadless
import XCTest

final class HeadlessStdioTransportTests: XCTestCase {
    func testLongRunningRequestDoesNotBlockPingOrCancellationDelivery() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = TransportBlockingToolCallGate()
        let admissionController = makeAdmissionController()
        let server = HeadlessMCPServer(
            configurationStore: fixture.store,
            filesystemAdmissionController: admissionController,
            toolCallOverride: { _, _ in try await gate.run() }
        )
        let output = LockedTransportOutput()
        let transport = HeadlessStdioTransport(
            server: server,
            writer: HeadlessStdoutWriter(writeHandler: output.append)
        )

        let initializeStopped = try await transport.receive(line(initializeRequest(id: 1)))
        XCTAssertFalse(initializeStopped)
        let initializedStopped = try await transport.receive(line(notification("notifications/initialized")))
        XCTAssertFalse(initializedStopped)
        let searchStopped = try await transport.receive(line(request(
            "tools/call",
            id: 2,
            params: ["name": "file_search", "arguments": ["pattern": "needle"]]
        )))
        XCTAssertFalse(searchStopped)
        await gate.waitUntilStarted()

        let pingStopped = try await transport.receive(line(request("ping", id: 3)))
        XCTAssertFalse(pingStopped)
        let ping = try await output.waitForResponse(id: 3)
        XCTAssertNotNil(ping["result"] as? [String: Any])
        XCTAssertNil(output.response(id: 2), "The blocked search must not have produced a response yet")

        let cancellationStopped = try await transport.receive(line(notification(
            "notifications/cancelled",
            params: ["requestId": 2]
        )))
        XCTAssertFalse(cancellationStopped)
        let cancelled = try await output.waitForResponse(id: 2)
        XCTAssertEqual(errorCode(cancelled), -32800)

        let shutdownStopped = try await transport.receive(line(request("shutdown", id: 4)))
        XCTAssertFalse(shutdownStopped)
        let shutdown = try await output.waitForResponse(id: 4)
        XCTAssertTrue(shutdown["result"] is NSNull)
        let exitStopped = try await transport.receive(line(notification("exit")))
        XCTAssertTrue(exitStopped)
        await transport.waitForPendingResponses()
    }

    func testRequestOnlyToolNotificationIsSilentAndNeverExecutesBeforeShutdown() async throws {
        let fixture = try makeFixture(configureAllowedRoot: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let output = LockedTransportOutput()
        let transport = HeadlessStdioTransport(
            server: HeadlessMCPServer(
                configurationStore: fixture.store,
                filesystemAdmissionController: makeAdmissionController()
            ),
            writer: HeadlessStdoutWriter(writeHandler: output.append)
        )

        let frames = try [
            initializeRequest(id: 20),
            notification("notifications/initialized"),
            notification(
                "tools/call",
                params: [
                    "name": "prompt",
                    "arguments": ["op": "set", "text": "notification-must-not-run"]
                ]
            ),
            request(
                "tools/call",
                id: 21,
                params: ["name": "prompt", "arguments": ["op": "get"]]
            )
        ]
        let stopped = await transport.receive(framed(frames))
        XCTAssertFalse(stopped)

        let promptGet = try await output.waitForResponse(id: 21)
        let promptResult = try XCTUnwrap(promptGet["result"] as? [String: Any])
        let structured = try XCTUnwrap(promptResult["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["prompt"] as? String, "")

        let shutdownStopped = try await transport.receive(line(request("shutdown", id: 22)))
        XCTAssertFalse(shutdownStopped)
        let shutdown = try await output.waitForResponse(id: 22)
        XCTAssertTrue(shutdown["result"] is NSNull)
        let exitStopped = try await transport.receive(line(notification("exit")))
        XCTAssertTrue(exitStopped)
        await transport.waitForPendingResponses()
        XCTAssertEqual(output.allObjects().count, 3, "Only initialize, prompt get, and shutdown may respond")
    }

    func testShutdownRespondsBeforeExplicitCancellationAndFlushesExactlyOneResponse() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = TransportBlockingToolCallGate()
        let server = HeadlessMCPServer(
            configurationStore: fixture.store,
            filesystemAdmissionController: makeAdmissionController(),
            toolCallOverride: { _, _ in try await gate.run() }
        )
        let output = LockedTransportOutput()
        let transport = HeadlessStdioTransport(
            server: server,
            writer: HeadlessStdoutWriter(writeHandler: output.append)
        )

        _ = try await transport.receive(line(initializeRequest(id: 10)))
        _ = try await transport.receive(line(notification("notifications/initialized")))
        _ = try await transport.receive(line(request(
            "tools/call",
            id: 11,
            params: ["name": "file_search", "arguments": ["pattern": "needle"]]
        )))
        await gate.waitUntilStarted()

        let shutdownStopped = try await transport.receive(line(request("shutdown", id: 12)))
        XCTAssertFalse(shutdownStopped)
        let shutdown = try await output.waitForResponse(id: 12)
        XCTAssertTrue(shutdown["result"] is NSNull)
        XCTAssertNil(output.response(id: 11))

        let cancellationStopped = try await transport.receive(line(notification(
            "notifications/cancelled",
            params: ["requestId": 11]
        )))
        XCTAssertFalse(cancellationStopped)
        let exitStopped = try await transport.receive(line(notification("exit")))
        XCTAssertTrue(exitStopped)
        await transport.waitForPendingResponses()

        let cancelled = try await output.waitForResponse(id: 11)
        XCTAssertEqual(errorCode(cancelled), -32800)
        XCTAssertEqual(output.responses(id: 10).count, 1)
        XCTAssertEqual(output.responses(id: 11).count, 1)
        XCTAssertEqual(output.responses(id: 12).count, 1)
    }

    func testTerminalExitCancelsBlockedRequestAndCompletesResponseDrain() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = TransportBlockingToolCallGate()
        let server = HeadlessMCPServer(
            configurationStore: fixture.store,
            filesystemAdmissionController: makeAdmissionController(),
            toolCallOverride: { _, _ in try await gate.run() }
        )
        let output = LockedTransportOutput()
        let transport = HeadlessStdioTransport(
            server: server,
            writer: HeadlessStdoutWriter(writeHandler: output.append)
        )

        _ = try await transport.receive(line(initializeRequest(id: 30)))
        _ = try await transport.receive(line(notification("notifications/initialized")))
        _ = try await transport.receive(line(request(
            "tools/call",
            id: 31,
            params: ["name": "file_search", "arguments": ["pattern": "needle"]]
        )))
        await gate.waitUntilStarted()

        _ = try await transport.receive(line(request("shutdown", id: 32)))
        let shutdown = try await output.waitForResponse(id: 32)
        XCTAssertTrue(shutdown["result"] is NSNull)
        XCTAssertNil(output.response(id: 31))
        let exitStopped = try await transport.receive(line(notification("exit")))
        XCTAssertTrue(exitStopped)

        let drainCompleted = expectation(description: "terminal exit drains cancelled requests")
        Task {
            await transport.waitForPendingResponses()
            drainCompleted.fulfill()
        }
        await fulfillment(of: [drainCompleted], timeout: 1)
        await server.cancelActiveRequests()
        await transport.waitForPendingResponses()

        let cancelled = try await output.waitForResponse(id: 31)
        XCTAssertEqual(errorCode(cancelled), -32800)
        let activeRequestCount = await server.activeRequestCountForTesting()
        XCTAssertEqual(activeRequestCount, 0)
    }

    func testEOFCancelsAndDrainsActiveLightAndQueuedHeavyFilesystemRequests() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = TransportBlockingToolCallGate()
        let admissionController = makeAdmissionController()
        let server = HeadlessMCPServer(
            configurationStore: fixture.store,
            filesystemAdmissionController: admissionController,
            toolCallOverride: { _, _ in try await gate.run() }
        )
        let output = LockedTransportOutput()
        let transport = HeadlessStdioTransport(
            server: server,
            writer: HeadlessStdoutWriter(writeHandler: output.append)
        )

        _ = try await transport.receive(line(initializeRequest(id: 40)))
        _ = try await transport.receive(line(notification("notifications/initialized")))
        _ = try await transport.receive(line(request(
            "tools/call",
            id: 41,
            params: ["name": "read_file", "arguments": ["path": "Fixture/file.txt"]]
        )))
        await gate.waitUntilStarted()
        _ = try await transport.receive(line(request(
            "tools/call",
            id: 42,
            params: ["name": "file_search", "arguments": ["pattern": "needle"]]
        )))
        try await waitForAdmissionSnapshot(
            .init(activeWeight: 1, activeLeaseCount: 1, waitingWeights: [4]),
            controller: admissionController
        )

        let finishCompleted = expectation(description: "EOF drains active and queued weighted requests")
        Task {
            await transport.finish()
            finishCompleted.fulfill()
        }
        await fulfillment(of: [finishCompleted], timeout: 1)

        let activeResponse = try await output.waitForResponse(id: 41)
        let queuedResponse = try await output.waitForResponse(id: 42)
        XCTAssertEqual(errorCode(activeResponse), -32800)
        XCTAssertEqual(errorCode(queuedResponse), -32800)
        XCTAssertEqual(output.responses(id: 41).count, 1)
        XCTAssertEqual(output.responses(id: 42).count, 1)
        try await waitForAdmissionSnapshot(
            .init(activeWeight: 0, activeLeaseCount: 0, waitingWeights: []),
            controller: admissionController
        )
        let activeRequestCount = await server.activeRequestCountForTesting()
        XCTAssertEqual(activeRequestCount, 0)
    }

    private func makeAdmissionController() -> HeadlessFilesystemAdmissionController {
        HeadlessFilesystemAdmissionController(capacity: HeadlessFilesystemAdmissionPolicy.capacity)
    }

    private func waitForAdmissionSnapshot(
        _ expected: HeadlessFilesystemAdmissionController.Snapshot,
        controller: HeadlessFilesystemAdmissionController
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await controller.snapshotForTesting() == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for admission snapshot \(expected)")
    }

    private func makeFixture(configureAllowedRoot: Bool = false) throws -> (directory: URL, store: HeadlessConfigurationStore) {
        let directory = HeadlessTestTemporaryDirectory.baseURL
            .appendingPathComponent("rpce-headless-stdio-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = HeadlessConfigurationStore(
            paths: HeadlessStatePaths(rootDirectory: directory.appendingPathComponent("State", isDirectory: true))
        )
        _ = try store.loadOrCreate()
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
        return (directory, store)
    }

    private func request(_ method: String, id: Any, params: [String: Any]? = nil) throws -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params {
            object["params"] = params
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func notification(_ method: String, params: [String: Any]? = nil) throws -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params {
            object["params"] = params
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func initializeRequest(id: Any) throws -> Data {
        try request(
            "initialize",
            id: id,
            params: [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "transport-tests", "version": "1"]
            ]
        )
    }

    private func framed(_ frames: [Data]) -> Data {
        var data = Data()
        for frame in frames {
            data.append(frame)
            data.append(0x0A)
        }
        return data
    }

    private func line(_ data: Data) throws -> Data {
        var line = data
        line.append(0x0A)
        return line
    }

    private func errorCode(_ response: [String: Any]) -> Int? {
        (response["error"] as? [String: Any])?["code"] as? Int
    }
}

private actor TransportBlockingToolCallGate {
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

private final class LockedTransportOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func response(id: Int) -> [String: Any]? {
        responses(id: id).first
    }

    func responses(id: Int) -> [[String: Any]] {
        objects().filter { ($0["id"] as? Int) == id }
    }

    func waitForResponse(id: Int) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if let response = response(id: id) {
                return response
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TransportTestError.responseTimedOut(id)
    }

    func allObjects() -> [[String: Any]] {
        objects()
    }

    private func objects() -> [[String: Any]] {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return snapshot.split(separator: 0x0A).compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        }
    }
}

private enum TransportTestError: Error {
    case responseTimedOut(Int)
}
