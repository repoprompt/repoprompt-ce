import Foundation
@testable import RepoPromptMCP
import XCTest

final class PersistentMCPResponseDeliveryTests: XCTestCase {
    func testOutstandingReplayStateOnlyCachesReplayableSingleRequests() async {
        let replayState = MCPOutstandingRequestReplayState()
        let unsafeToolCall = line(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"apply_edits","arguments":{"path":"README.md","search":"a","replace":"b"}}}"#)
        let batchedSafeRequest = line(#"[{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}]"#)
        let safeToolCall = line(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"README.md"}}}"#)
        let safeMethodRequest = line(#"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{}}"#)
        let unsafeWorkspaceExport = line(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"workspace_context","arguments":{"op":"export","path":"context.txt"}}}"#)
        let safeWorkspaceSnapshot = line(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"workspace_context","arguments":{"op":"snapshot","include":["tokens"]}}}"#)

        await replayState.recordForwardedClientFrame(unsafeToolCall)
        await replayState.recordForwardedClientFrame(batchedSafeRequest)
        await replayState.recordForwardedClientFrame(unsafeWorkspaceExport)
        var frames = await replayState.replayFrames()
        XCTAssertEqual(frames, [])

        await replayState.recordForwardedClientFrame(safeToolCall)
        await replayState.recordForwardedClientFrame(safeMethodRequest)
        await replayState.recordForwardedClientFrame(safeWorkspaceSnapshot)
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames.count, 3)
        assertJSONLineEqual(frames[0], safeToolCall)
        assertJSONLineEqual(frames[1], safeMethodRequest)
        assertJSONLineEqual(frames[2], safeWorkspaceSnapshot)

        await replayState.recordForwardedClientFrame(line(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#))
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames.count, 2)

        await replayState.recordDeliveredServerFrame(line(#"{"jsonrpc":"2.0","id":4,"result":{"tools":[]}}"#))
        await replayState.recordDeliveredServerFrame(line(#"{"jsonrpc":"2.0","id":6,"result":{"prompt_tokens":0}}"#))
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames, [])
    }

    func testOutstandingReplayStateIgnoresClientResponseForAppOriginatedIDCollision() async {
        let replayState = MCPOutstandingRequestReplayState()
        let hostRequest = line(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"README.md"}}}"#)
        let clientResponse = line(#"{"jsonrpc":"2.0","id":7,"result":{"roots":[]}}"#)

        await replayState.recordForwardedClientFrame(hostRequest)
        await replayState.recordForwardedClientFrame(clientResponse)
        let frames = await replayState.replayFrames()
        XCTAssertEqual(frames.count, 1)
        assertJSONLineEqual(frames[0], hostRequest)

        await replayState.recordDeliveredServerFrame(line(#"{"jsonrpc":"2.0","id":7,"result":{"content":[]}}"#))
        let finalFrames = await replayState.replayFrames()
        XCTAssertEqual(finalFrames, [])
    }

    func testOutstandingReplayStateUsesStrictJSONRPCIDs() async {
        let replayState = MCPOutstandingRequestReplayState()
        let hostRequest = line(#"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}"#)

        await replayState.recordForwardedClientFrame(line(#"{"jsonrpc":"2.0","id":7.5,"method":"tools/list","params":{}}"#))
        var frames = await replayState.replayFrames()
        XCTAssertEqual(frames, [])

        await replayState.recordForwardedClientFrame(hostRequest)
        await replayState.recordForwardedClientFrame(line(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7.5}}"#))
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames.count, 1)

        await replayState.recordForwardedClientFrame(line(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#))
        frames = await replayState.replayFrames()
        XCTAssertEqual(frames, [])
    }

    func testInitializeReplayStateReportsUnsupportedResumeReasons() async throws {
        let replayState = MCPInitializeReplayState()
        let initialPlan = await replayState.replayPlan()
        XCTAssertEqual(initialPlan, .failure(.missingInitializeFrame))

        let initializeFrame = line(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"resume-test"}}}"#)
        await replayState.recordForwardedClientFrame(initializeFrame)
        let pendingResponse = try await replayState.replayPlan().get()
        XCTAssertTrue(pendingResponse.shouldForwardInitializeResponseToHost)
        XCTAssertNil(pendingResponse.initializeResultFingerprint)

        await replayState.recordDeliveredServerFrame(line(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25"}}"#))
        let missingInitialized = try await replayState.replayPlan().get()
        XCTAssertFalse(missingInitialized.shouldForwardInitializeResponseToHost)
        XCTAssertNotNil(missingInitialized.initializeResultFingerprint)
        XCTAssertNil(missingInitialized.initializedFrame)

        let initializedFrame = line(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#)
        await replayState.recordForwardedClientFrame(initializedFrame)
        let plan = try await replayState.replayPlan().get()
        XCTAssertEqual(plan.initializeFrame, initializeFrame)
        XCTAssertEqual(plan.initializeRequestID, .number(1))
        XCTAssertEqual(plan.initializedFrame, initializedFrame)
        XCTAssertFalse(plan.shouldForwardInitializeResponseToHost)
    }

    private func assertJSONLineEqual(
        _ actual: Data,
        _ expected: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let actualObject = try JSONSerialization.jsonObject(with: actual) as? NSDictionary
            let expectedObject = try JSONSerialization.jsonObject(with: expected) as? NSDictionary
            XCTAssertEqual(actualObject, expectedObject, file: file, line: line)
        } catch {
            XCTFail("Expected valid JSON lines: \(error)", file: file, line: line)
        }
    }

    private func line(_ string: String) -> Data {
        Data((string + "\n").utf8)
    }
}
