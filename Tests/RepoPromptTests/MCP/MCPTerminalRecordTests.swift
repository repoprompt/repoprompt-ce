import Foundation
@testable import RepoPrompt
import RepoPromptShared
import XCTest

final class MCPTerminalRecordTests: XCTestCase {
    func testRecordRoundTripUsesTerminalPrefixAndExcludesRawSecrets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPTerminalRecordTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rawSessionToken = "raw-session-token-never-persist"
        let record = try MCPTerminalRecord(
            id: XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")),
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            monotonicUptime: 1234.5,
            layer: .proxy,
            initiator: .peer,
            reason: "read_error token=reason-secret",
            sessionToken: rawSessionToken,
            localPID: 101,
            peerPID: 202,
            appConnectionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
            connectionGeneration: 7,
            errno: 54,
            errorDescription: "Authorization: Bearer bearer-secret url=https://user:pass@example.test/path request_payload={\"token\":\"json-secret\"} environment=env-secret cookie=session-cookie session=\(rawSessionToken)",
            bridgeActiveRequestCount: 3,
            bridgeResponseInDeliveryCount: 2,
            bridgeCancellationTombstoneCount: 1,
            bridgeRecentCompletionCount: 4,
            bridgePendingTransactionCount: 5,
            bridgeHasForwardedProtocolFrame: true
        )

        let fileURL = try MCPTerminalRecordStore.write(record, to: directory)
        XCTAssertTrue(fileURL.lastPathComponent.hasPrefix("terminal-"))

        let data = try Data(contentsOf: fileURL)
        let persistedText = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(persistedText.contains(rawSessionToken))
        XCTAssertFalse(persistedText.contains("reason-secret"))
        XCTAssertFalse(persistedText.contains("bearer-secret"))
        XCTAssertFalse(persistedText.contains("user:pass"))
        XCTAssertFalse(persistedText.contains("json-secret"))
        XCTAssertFalse(persistedText.contains("env-secret"))
        XCTAssertFalse(persistedText.contains("session-cookie"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MCPTerminalRecord.self, from: data)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.reason, "read_error token=<redacted>")
        XCTAssertNotNil(decoded.errorDescription)
        XCTAssertFalse(decoded.errorDescription?.contains("bearer-secret") == true)
        XCTAssertFalse(decoded.errorDescription?.contains("user:pass") == true)
        XCTAssertFalse(decoded.errorDescription?.contains("json-secret") == true)
        XCTAssertFalse(decoded.errorDescription?.contains("env-secret") == true)
        XCTAssertFalse(decoded.errorDescription?.contains("session-cookie") == true)
        XCTAssertFalse(decoded.errorDescription?.contains(rawSessionToken) == true)
    }

    func testStoreRetainsNewestTerminalRecordsWithoutTouchingCLIEvents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPTerminalRecordRetentionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let cliEventURL = directory.appendingPathComponent("cli-preserve-me.json")
        try Data("cli-event".utf8).write(to: cliEventURL)

        var writtenURLs: [URL] = []
        for index in 0 ..< 260 {
            let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", index)))
            let record = MCPTerminalRecord(
                id: id,
                timestamp: Date(timeIntervalSince1970: 1_750_000_000 + TimeInterval(index)),
                monotonicUptime: TimeInterval(index),
                layer: .proxy,
                initiator: .transport,
                reason: "retention_test",
                sessionToken: nil,
                localPID: 1,
                peerPID: nil,
                appConnectionID: nil,
                connectionGeneration: UInt64(index),
                errno: nil,
                errorDescription: nil
            )
            try writtenURLs.append(MCPTerminalRecordStore.write(record, to: directory))
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let terminalFiles = files.filter {
            $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("terminal-")
        }
        XCTAssertEqual(terminalFiles.count, 256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cliEventURL.path))
        for staleURL in writtenURLs.prefix(4) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        }
        for retainedURL in writtenURLs.dropFirst(4) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))
        }
    }

    func testFirstTerminalRecordClaimRetriesOriginalRecordWithoutSubstitutingNewCause() {
        let firstRecord = MCPTerminalRecord(
            layer: .appAcceptedSocket,
            initiator: .peer,
            reason: "peer_eof",
            sessionToken: "first-cause-session",
            localPID: 1,
            peerPID: 2,
            appConnectionID: UUID(),
            connectionGeneration: 3,
            errno: nil,
            errorDescription: nil
        )
        let laterRecord = MCPTerminalRecord(
            layer: .appAcceptedSocket,
            initiator: .app,
            reason: "local_disconnect",
            sessionToken: "first-cause-session",
            localPID: 1,
            peerPID: 2,
            appConnectionID: firstRecord.appConnectionID,
            connectionGeneration: 3,
            errno: nil,
            errorDescription: "later cleanup"
        )

        var claim = MCPFirstTerminalRecordClaim()
        XCTAssertEqual(claim.claim(firstRecord), firstRecord)
        XCTAssertEqual(claim.claim(laterRecord), firstRecord)
        XCTAssertEqual(claim.record, firstRecord)
        XCTAssertFalse(claim.didPersist)

        claim.markPersisted()
        XCTAssertTrue(claim.didPersist)
        XCTAssertNil(claim.claim(laterRecord))
        XCTAssertEqual(claim.record, firstRecord)
    }

    func testDebugFingerprintMatchesDurableTerminalFingerprint() async {
        #if DEBUG
            let token = "shared-fingerprint-session"
            let manager = ServerNetworkManager()
            let debugFingerprint = await manager.debugSessionFingerprint(forToken: token)
            XCTAssertEqual(
                debugFingerprint,
                MCPTerminalFingerprint.session(token)?.description
            )
        #else
            throw XCTSkip("DEBUG connection history is unavailable in release builds")
        #endif
    }

    func testSaltedFingerprintIsStableAndDoesNotExposeToken() {
        let token = "sensitive-session-token"
        let first = MCPTerminalFingerprint.session(token)
        let second = MCPTerminalFingerprint.session(token)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first?.description.hasPrefix("sha256:") == true)
        XCTAssertFalse(first?.description.contains(token) == true)
        XCTAssertNotEqual(first, MCPTerminalFingerprint.session("different-token"))
        XCTAssertNil(MCPTerminalFingerprint.session(nil))
    }
}
