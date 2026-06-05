import Darwin
import Foundation
@testable import RepoPrompt
import RepoPromptShared
import XCTest

final class MCPBootstrapContractCharacterizationTests: XCTestCase {
    func testBootstrapRequestEncodingContract() throws {
        let request = MCPBootstrapRequest(
            sessionToken: "characterization-token",
            clientPid: 4242,
            clientName: "RepoPrompt CLI (Characterization)",
            protocolVersion: 2
        )

        let json = try jsonObject(request)

        XCTAssertEqual(Set(json.allKeys.compactMap { $0 as? String }), [
            "type",
            "sessionToken",
            "clientPid",
            "clientName",
            "protocolVersion"
        ])
        XCTAssertEqual(json["type"] as? String, "connect")
        XCTAssertEqual(json["sessionToken"] as? String, "characterization-token")
        XCTAssertEqual(json["clientPid"] as? Int, 4242)
        XCTAssertEqual(json["clientName"] as? String, "RepoPrompt CLI (Characterization)")
        XCTAssertEqual(json["protocolVersion"] as? Int, 2)
    }

    func testBootstrapResponseEncodingContract() throws {
        let accepted = try jsonObject(MCPBootstrapResponse.accepted())
        XCTAssertEqual(Set(accepted.allKeys.compactMap { $0 as? String }), ["type"])
        XCTAssertEqual(accepted["type"] as? String, "accepted")

        let rejected = try jsonObject(MCPBootstrapResponse.rejected(
            reason: "protocol mismatch",
            errorCode: MCPBootstrapErrorCode.protocolVersionMismatch.rawValue
        ))
        XCTAssertEqual(Set(rejected.allKeys.compactMap { $0 as? String }), ["type", "reason", "errorCode"])
        XCTAssertEqual(rejected["type"] as? String, "rejected")
        XCTAssertEqual(rejected["reason"] as? String, "protocol mismatch")
        XCTAssertEqual(rejected["errorCode"] as? String, "protocol_version_mismatch")
    }

    func testBootstrapVersionsErrorCodesAndProductionSocketPathRemainStable() {
        XCTAssertEqual(MCPBootstrapProtocol.currentVersion, 2)
        XCTAssertEqual(MCPConstants.bootstrapProtocolVersion, MCPBootstrapProtocol.currentVersion)
        XCTAssertEqual(MCPBootstrapTiming.initialResponseTimeout, 5)
        XCTAssertEqual(MCPBootstrapEndpoint.socketVersion, 6)
        XCTAssertEqual(MCPFilesystemConstants.socketVersion, MCPBootstrapEndpoint.socketVersion)

        let expectedPath = "/tmp/repoprompt-ce-mcp-\(getuid())/repoprompt-ce-6.sock"
        let sharedPath = MCPBootstrapEndpoint.bootstrapSocketURL(uid: getuid()).path
        let actualPath = MCPFilesystemConstants.bootstrapSocketURL().path
        XCTAssertEqual(sharedPath, expectedPath)
        XCTAssertEqual(actualPath, expectedPath)
        XCTAssertLessThan(actualPath.utf8.count, 104)

        XCTAssertEqual(MCPBootstrapErrorCode.approvalDenied.rawValue, "approval_denied")
        XCTAssertEqual(MCPBootstrapErrorCode.protocolVersionMismatch.rawValue, "protocol_version_mismatch")
        XCTAssertEqual(MCPBootstrapErrorCode.serverNotReady.rawValue, "server_not_ready")
        XCTAssertEqual(MCPBootstrapErrorCode.serverUnavailable.rawValue, "server_unavailable")
        XCTAssertEqual(MCPBootstrapErrorCode.connectionLimitReached.rawValue, "connection_limit_reached")
        XCTAssertEqual(MCPBootstrapErrorCode.capacityExceeded.rawValue, "capacity_exceeded")
        XCTAssertEqual(MCPBootstrapErrorCode.sessionBlocked.rawValue, "session_blocked")
        XCTAssertEqual(MCPBootstrapErrorCode.clientCooldown.rawValue, "client_cooldown")
    }

    func testHandshakeFallbackPIDRemainsDiagnosticOnly() {
        let forgedPID = 4242
        let identity = MCPPeerIdentity(socketObservedPID: nil, handshakeClaimedPID: forgedPID)

        XCTAssertNil(identity.trustedPID)
        XCTAssertEqual(identity.diagnosticPID, forgedPID)
        XCTAssertEqual(identity.provenance, .handshakeFallback)
    }

    func testHandshakeClaimedPIDValidationRejectsOutOfRangeValues() {
        XCTAssertFalse(MCPPeerIdentity.isValidHandshakeClaimedPID(0))
        XCTAssertFalse(MCPPeerIdentity.isValidHandshakeClaimedPID(-1))
        XCTAssertTrue(MCPPeerIdentity.isValidHandshakeClaimedPID(1))
        XCTAssertTrue(MCPPeerIdentity.isValidHandshakeClaimedPID(Int(Int32.max)))
        XCTAssertFalse(MCPPeerIdentity.isValidHandshakeClaimedPID(Int(Int32.max) + 1))
    }

    func testBootstrapHandshakeDTOsAreSingleSourcedInRepoPromptShared() throws {
        let root = try RepoRoot.url()
        let sharedMessages = root.appendingPathComponent("Sources/RepoPromptShared/MCP/MCPBootstrapMessages.swift")
        let appMessages = root.appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/AppShared/MCPBootstrapMessages.swift")
        let cliMessages = root.appendingPathComponent("Sources/RepoPromptMCP/Shared/MCPBootstrapMessages.swift")

        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedMessages.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: appMessages.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cliMessages.path))
    }

    func testNonImportableCLIProxyRetainsCharacterizedBootstrapEndpointAndEncodingSeams() throws {
        let root = try RepoRoot.url()
        let filesystemConstants = try sourceText(
            "Sources/RepoPromptMCP/Shared/MCPFilesystemConstants.swift",
            relativeTo: root
        )
        let proxy = try sourceText("Sources/RepoPromptMCP/main.swift", relativeTo: root)
        let interactive = try sourceText(
            "Sources/RepoPromptMCP/Interactive/InteractiveMCPClientSession.swift",
            relativeTo: root
        )

        XCTAssertTrue(filesystemConstants.contains("static let socketDirName = MCPBootstrapEndpoint.socketDirectoryName"))
        XCTAssertTrue(filesystemConstants.contains("MCPBootstrapEndpoint.socketDirectoryURL(uid: getuid())"))
        XCTAssertTrue(filesystemConstants.contains("static let socketVersion = MCPBootstrapEndpoint.socketVersion"))
        XCTAssertTrue(filesystemConstants.contains("MCPBootstrapEndpoint.bootstrapSocketName"))
        XCTAssertTrue(filesystemConstants.contains("MCPBootstrapEndpoint.bootstrapSocketURL(uid: getuid())"))

        XCTAssertTrue(proxy.contains("let kBootstrapProtocolVersion = MCPBootstrapProtocol.currentVersion"))
        XCTAssertTrue(proxy.contains("socketURL = MCPFilesystemConstants.bootstrapSocketURL()"))
        XCTAssertTrue(proxy.contains("protocolVersion: kBootstrapProtocolVersion"))
        XCTAssertTrue(proxy.contains("payload.append(UInt8(ascii: \"\\n\"))"))

        XCTAssertTrue(interactive.contains("let socketURL = MCPFilesystemConstants.bootstrapSocketURL()"))
        XCTAssertTrue(interactive.contains("protocolVersion: MCPBootstrapProtocol.currentVersion"))
        XCTAssertTrue(interactive.contains("payload.append(UInt8(ascii: \"\\n\"))"))
    }

    private func jsonObject(_ value: some Encodable) throws -> NSDictionary {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func sourceText(_ relativePath: String, relativeTo root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
