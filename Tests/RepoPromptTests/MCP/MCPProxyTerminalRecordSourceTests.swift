import Foundation
import XCTest

final class MCPProxyTerminalRecordSourceTests: XCTestCase {
    func testProxyExitPersistsBridgeLedgerTerminalSnapshot() throws {
        let root = try RepoRoot.url()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RepoPromptMCP/main.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("await bridgeLedger.snapshot()"))
        XCTAssertTrue(source.contains("MCPTerminalRecordStore.writeBestEffort"))
        XCTAssertTrue(source.contains("layer: .proxy"))
        XCTAssertTrue(source.contains("localPID: Int(getpid())"))
        XCTAssertTrue(source.contains("peerPID: Int(initialPPID)"))
        XCTAssertTrue(source.contains("bridgeActiveRequestCount: snapshot.activeRequestCount"))
        XCTAssertTrue(source.contains("bridgeResponseInDeliveryCount: snapshot.responseInDeliveryCount"))
        XCTAssertTrue(source.contains("bridgePendingTransactionCount: snapshot.pendingTransactionCount"))
        XCTAssertTrue(source.contains("bridgeHasForwardedProtocolFrame: snapshot.hasForwardedProtocolFrame"))
        XCTAssertFalse(source.contains("bridgeCommitted:"))
        XCTAssertTrue(source.contains("reason: reason"))
        XCTAssertTrue(source.contains("case stdinClosed = \"stdin_closed\""))
        XCTAssertTrue(source.contains("case parentProcessChanged = \"parent_process_changed\""))
        XCTAssertTrue(source.contains("case stdoutBrokenPipe = \"stdout_broken_pipe\""))
        XCTAssertTrue(source.contains("bytesWritten: bytesWritten"))
        XCTAssertTrue(source.contains("totalBytes: totalBytes"))
        XCTAssertTrue(source.contains("reason: signal.reason"))
        XCTAssertTrue(source.contains("message: signal.message ?? CLIKillSignal.messageForReason(signal.reason)"))
        XCTAssertTrue(source.contains("return provenance.reason.rawValue"))
        XCTAssertTrue(source.contains("return provenance.stableReason"))
        XCTAssertTrue(source.contains("case .hostDisconnected, .terminatedByServer:"))
        XCTAssertTrue(source.contains("case .hostDisconnected:\n        .ok"))
        XCTAssertTrue(source.contains("case .terminatedByServer:\n        .terminatedByServer"))
    }
}
