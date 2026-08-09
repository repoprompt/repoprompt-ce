import Darwin
import Foundation
import Logging
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import XCTest

final class DirectHeadlessChildEndpointTests: XCTestCase {
    func testSessionStartsUseFreshRunIDsWhileProviderContinuationsReuseCallerScope() {
        let parentRunID = UUID()
        let securityContext = DomainToolInvocationSecurityContext(
            principal: DomainClientPrincipal(
                principalID: UUID(),
                stableKey: "nested-parent",
                displayName: "Nested parent",
                kind: .runScoped,
                assurance: .hostLaunchToken,
                processID: nil,
                runID: parentRunID,
                provider: "test"
            ),
            connectionID: UUID(),
            connectionGeneration: 1,
            invocationID: UUID(),
            runtimeID: UUID(),
            runtimeGeneration: 1,
            ephemeralGrantedToolNames: []
        )

        let firstAgentRunID = DirectHeadlessChildLaunchCoordinator.resolvedRunID(
            toolName: "agent_run",
            arguments: ["op": .string("start")],
            securityContext: securityContext
        )
        let secondAgentRunID = DirectHeadlessChildLaunchCoordinator.resolvedRunID(
            toolName: "agent_run",
            arguments: ["op": .string("start")],
            securityContext: securityContext
        )
        XCTAssertNotEqual(firstAgentRunID, parentRunID)
        XCTAssertNotEqual(secondAgentRunID, parentRunID)
        XCTAssertNotEqual(firstAgentRunID, secondAgentRunID)
        XCTAssertNotEqual(
            DirectHeadlessChildLaunchCoordinator.resolvedRunID(
                toolName: "agent_explore",
                arguments: ["op": .string("start")],
                securityContext: securityContext
            ),
            parentRunID
        )

        for toolName in ["ask_oracle", "oracle_send", "context_builder"] {
            XCTAssertEqual(
                DirectHeadlessChildLaunchCoordinator.resolvedRunID(
                    toolName: toolName,
                    arguments: [:],
                    securityContext: securityContext
                ),
                parentRunID,
                toolName
            )
        }
    }

    func testExplicitCarrierBridgesNestedProcessThroughPrivateEndpoint() async throws {
        let directory = URL(fileURLWithPath: "/tmp/rpce-child-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = DirectHeadlessChildEndpoint(
            directory: directory,
            logger: Logger(label: "DirectHeadlessChildEndpointTests")
        )
        let runID = UUID()
        let probe = ChildEndpointProbe()
        try await endpoint.start { fd, peerPID, handshake in
            await probe.record(peerPID: peerPID, handshake: handshake)
            let response = Data("{\"nested\":true}\n".utf8)
            _ = response.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            Darwin.shutdown(fd, SHUT_RDWR)
        }

        let process = Process()
        process.executableURL = try executableURL()
        var environment = ProcessInfo.processInfo.environment
        environment[DomainChildLaunchCarrier.endpointEnvironmentKey] = endpoint.socketURL.path
        environment[DomainChildLaunchCarrier.launchTokenEnvironmentKey] = "single-use-token"
        environment[DomainChildLaunchCarrier.clientPrincipalEnvironmentKey] = "principal:test"
        environment[DomainChildLaunchCarrier.providerIdentifierEnvironmentKey] = "provider:test"
        environment[DomainChildLaunchCarrier.runIDEnvironmentKey] = runID.uuidString
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        try input.fileHandleForWriting.close()
        let exited = expectation(description: "nested child bridge exits")
        process.terminationHandler = { _ in exited.fulfill() }
        await fulfillment(of: [exited], timeout: 10)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "{\"nested\":true}\n")
        XCTAssertEqual(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "")
        let observed = await probe.snapshot()
        XCTAssertEqual(observed?.handshake.launchToken, "single-use-token")
        XCTAssertEqual(observed?.handshake.clientPrincipal, "principal:test")
        XCTAssertEqual(observed?.handshake.providerIdentifier, "provider:test")
        XCTAssertEqual(observed?.handshake.runID, runID)
        XCTAssertEqual(observed?.peerPID, process.processIdentifier)
        await endpoint.stop()
    }

    func testEndpointTeardownDoesNotUnlinkReplacementNode() async throws {
        let directory = URL(fileURLWithPath: "/tmp/rpce-child-fence-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = DirectHeadlessChildEndpoint(
            directory: directory,
            logger: Logger(label: "DirectHeadlessChildEndpointTests")
        )
        try await endpoint.start { _, _, _ in }
        let socketPath = endpoint.socketURL.path
        XCTAssertEqual(Darwin.unlink(socketPath), 0)
        try Data("replacement".utf8).write(to: endpoint.socketURL)
        await endpoint.stop()
        XCTAssertEqual(try String(contentsOf: endpoint.socketURL, encoding: .utf8), "replacement")
    }

    private func executableURL() throws -> URL {
        var cursor = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let candidate = cursor.appendingPathComponent("repoprompt-mcp")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/repoprompt-mcp")
        guard FileManager.default.isExecutableFile(atPath: fallback.path) else {
            throw XCTSkip("repoprompt-mcp product is not built")
        }
        return fallback
    }
}

private actor ChildEndpointProbe {
    struct Snapshot {
        let peerPID: Int32?
        let handshake: DirectHeadlessChildEndpoint.Handshake
    }

    private var value: Snapshot?

    func record(peerPID: Int32?, handshake: DirectHeadlessChildEndpoint.Handshake) {
        value = Snapshot(peerPID: peerPID, handshake: handshake)
    }

    func snapshot() -> Snapshot? {
        value
    }
}
