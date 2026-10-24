import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import XCTest

final class DirectHeadlessFileReadDispatchTests: XCTestCase {
    func testCallToolReadWaitsForHostResourceAndReleasesItsLease() async throws {
        let fixture = try await makeFixture()
        let file = fixture.root.appendingPathComponent("file.txt")
        try Data("before".utf8).write(to: file)
        var blockers: [MCPDomainToolResourceAdmissionController.Lease] = []
        for _ in 0 ..< MCPDomainToolAdmissionLimits.fileReadPerWindow {
            try await blockers.append(fixture.prepared.runtime.domainHost.acquireFileReadResourceAdmission(windowID: 0))
        }
        defer { blockers.forEach { $0.release() } }
        let call = Task { try await fixture.client.callTool(name: "read_file", arguments: ["path": .string(file.path)]) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await fixture.prepared.runtime.domainHost.snapshot().resourceAdmissionWaiterCount == 0,
              ContinuousClock.now < deadline
        {
            await Task.yield()
        }
        let waiting = await fixture.prepared.runtime.domainHost.snapshot()
        XCTAssertEqual(waiting.resourceAdmissionWaiterCount, 1, "The real CallTool branch must acquire physical admission")
        XCTAssertEqual(waiting.activeInvocationCount, 0, "No provider may enter before resource admission")
        try Data("after-admission".utf8).write(to: file)
        blockers.forEach { $0.release() }
        let result = try await call.value
        XCTAssertNotEqual(result.isError, true)
        let text = try JSONDecoder().decode(String.self, from: Data(Self.text(result.content).utf8))
        XCTAssertEqual(text, "after-admission")
        let settled = await fixture.prepared.runtime.domainHost.snapshot()
        XCTAssertEqual(settled.activeResourceAdmissionLeaseCount, 0)
        XCTAssertEqual(settled.resourceAdmissionWaiterCount, 0)
    }

    func testCallToolMissingFileDoesNotExposePhysicalPath() async throws {
        let fixture = try await makeFixture()
        let file = fixture.root.appendingPathComponent("missing.txt")
        let result = try await fixture.client.callTool(name: "read_file", arguments: ["path": .string(file.path)])
        XCTAssertEqual(result.isError, true)
        let message = Self.text(result.content)
        XCTAssertTrue(message.contains("Cannot read requested file (POSIX 2:"), message)
        XCTAssertFalse(message.contains("/private/var/"), message)
        XCTAssertFalse(message.contains(fixture.root.path), message)
    }

    private static func text(_ content: [Tool.Content]) -> String {
        content.compactMap { content in
            if case let .text(value, _, _) = content { return value }
            return nil
        }.joined(separator: "\n")
    }

    private struct Fixture {
        let root: URL
        let client: Client
        let prepared: DirectHeadlessMCPService.PreparedRuntime
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("headless-read-dispatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let service = DirectHeadlessMCPService(environment: [
            "REPOPROMPT_MCP_HEADLESS_PROFILE": "read-dispatch",
            "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": root.appendingPathComponent("profile").path,
            "REPOPROMPT_MCP_WORKING_DIRS": root.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
        ], currentDirectory: root)
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let transports = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "Read admission test", version: "1", capabilities: .init(tools: .init()))
        await service.installHandlers(server: server, prepared: prepared, connection: .init(
            connectionID: prepared.connectionID, connectionGeneration: prepared.connectionGeneration,
            principal: prepared.principal, policyProfile: .direct, restrictedToolNames: [],
            additionalToolNames: [], ephemeralGrantedOperations: []
        ))
        try await server.start(transport: transports.server)
        addTeardownBlock { await server.stop() }
        let client = Client(name: "Read admission test client", version: "1")
        _ = try await client.connect(transport: transports.client)
        addTeardownBlock { await client.disconnect() }
        return Fixture(root: root, client: client, prepared: prepared)
    }
}
