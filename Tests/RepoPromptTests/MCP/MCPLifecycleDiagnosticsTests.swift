import Foundation
@testable import RepoPromptApp
import XCTest

final class MCPLifecycleDiagnosticsTests: XCTestCase {
    /// The same recorder used by production remains inert until a sink is installed,
    /// and clearing it stops delivery without changing or spawning MCP work.
    func testSinkOptOutAndClosedSchema() {
        let recorder = MCPLifecycleDiagnostics.Recorder()
        let events = CapturedEvents()
        let connectionID = UUID()
        let invocationID = UUID()
        recorder.record(.requestEntered, connectionID: connectionID, invocationID: invocationID)
        recorder.setSink { events.append($0) }
        recorder.record(.providerEntered, connectionID: connectionID, invocationID: invocationID)
        recorder.record(.removalStarted, connectionID: connectionID)
        recorder.setSink(nil)
        recorder.record(.providerReturning, connectionID: connectionID, invocationID: invocationID)
        let captured = events.snapshot()
        XCTAssertEqual(captured.map(\.phase), [.providerEntered, .removalStarted])
        XCTAssertEqual(captured.map(\.sequence), [1, 2])
        XCTAssertEqual(captured.first?.data, [
            "schema": "mcp_lifecycle_v1", "phase": "provider_entered", "sequence": "1",
            "connection_id": connectionID.uuidString, "invocation_id": invocationID.uuidString
        ])
        XCTAssertEqual(captured.last?.data, [
            "schema": "mcp_lifecycle_v1", "phase": "removal_started", "sequence": "2",
            "connection_id": connectionID.uuidString
        ])
    }

    #if DEBUG
        func testCaptureIsConnectionScopedBoundedAndDoesNotInstallSink() {
            let recorder = MCPLifecycleDiagnostics.Recorder()
            let connectionID = UUID()
            let otherConnectionID = UUID()
            recorder.beginCapture(connectionID: connectionID)
            for _ in 0 ..< 140 {
                recorder.record(.requestEntered, connectionID: connectionID)
                recorder.record(.requestEntered, connectionID: otherConnectionID)
            }
            let events = recorder.snapshot(connectionID: connectionID)
            XCTAssertEqual(events.count, 128)
            XCTAssertEqual(events.first?.sequence, 13)
            XCTAssertEqual(events.last?.sequence, 140)
            XCTAssertTrue(recorder.snapshot(connectionID: otherConnectionID).isEmpty)
            recorder.endCapture(connectionID: connectionID)
            recorder.record(.handlerReturning, connectionID: connectionID)
            XCTAssertTrue(recorder.snapshot(connectionID: connectionID).isEmpty)
        }
    #endif
}

private final class CapturedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MCPLifecycleDiagnostics.Event] = []

    func append(_ event: MCPLifecycleDiagnostics.Event) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func snapshot() -> [MCPLifecycleDiagnostics.Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
