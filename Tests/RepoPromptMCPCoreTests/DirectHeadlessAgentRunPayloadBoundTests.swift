import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import RepoPromptShared
import XCTest

/// Follow-up to #1598 (#399): the headless agent_run start/poll/wait responses must stay
/// bounded on the wire even when the child's final reply is huge. Drives the real direct
/// provider coordinator against a fake `codex exec` that prints one oversized message, then
/// JSON-encodes exactly the `Value` the headless backend returns to the MCP client.
final class DirectHeadlessAgentRunPayloadBoundTests: XCTestCase {
    private static let replyCharacters = 160_000

    func testOversizedFinalReplyIsBoundedInSerializedHeadlessWaitAndPollResponses() async throws {
        let prepared = try await makePreparedRuntime(replyCharacters: Self.replyCharacters)
        let coordinator = prepared.providerCoordinator
        let request = try await Self.request(prepared, arguments: [
            "op": .string("start"),
            "message": .string("Reply with a very long message."),
            "timeout": .double(60)
        ])

        let started = try await coordinator.startAgent(args: [
            "op": .string("start"),
            "message": .string("Reply with a very long message."),
            "model_id": .string("codexExec"),
            "timeout": .double(60)
        ], request: request)
        let startedObject = try assertBounded(started, label: "start (blocking wait)")

        let sessionID = try XCTUnwrap((startedObject["session_id"] as? String).flatMap(UUID.init(uuidString:)))
        try await assertBounded(coordinator.pollAgent(sessionID: sessionID, timeout: 0).toValue(), label: "poll")
        try await assertBounded(coordinator.waitAgent(sessionID: sessionID, timeout: 5).toValue(), label: "wait")
    }

    func testTerminalStatusTextIsAConciseLabelNotTheReply() {
        typealias Coordinator = DirectHeadlessProviderCoordinator
        XCTAssertEqual(Coordinator.terminalStatusText(for: .completed(assistantText: String(repeating: "x", count: 50))), "Completed")
        XCTAssertEqual(Coordinator.terminalStatusText(for: .cancelled()), "Cancelled")
        XCTAssertEqual(Coordinator.terminalStatusText(for: .failed(assistantText: nil)), "Failed")
        XCTAssertEqual(
            Coordinator.terminalStatusText(for: .failed(assistantText: "\n  codex exited 1: quota\nstack line 1\nstack line 2")),
            "Failed: codex exited 1: quota"
        )
        let longFailure = Coordinator.terminalStatusText(for: .failed(assistantText: String(repeating: "e", count: 50000)))
        XCTAssertTrue(longFailure.hasSuffix(DomainAgentRunSnapshot.statusTextTruncationMarker))
        XCTAssertLessThanOrEqual(longFailure.utf8.count, DomainAgentRunSnapshot.statusTextUTF8ByteLimit)
    }

    @discardableResult
    private func assertBounded(_ value: Value, label: String) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], label)
        XCTAssertEqual(object["status"] as? String, "completed", "\(label): \(String(decoding: data.prefix(600), as: UTF8.self))")
        let limit = DomainAgentRunSnapshot.assistantTextCharacterLimit
        XCTAssertLessThan(data.count, 2 * limit, "\(label) serialized response must stay bounded")
        let statusText = try XCTUnwrap(object["status_text"] as? String, label)
        XCTAssertLessThanOrEqual(statusText.count, 512, "\(label) status_text must be concise")
        XCTAssertEqual(object["assistant_text_truncated"] as? Bool, true, label)
        XCTAssertEqual(object["assistant_text_characters"] as? Int, Self.replyCharacters, label)
        return object
    }

    private func makePreparedRuntime(replyCharacters: Int) async throws -> DirectHeadlessMCPService.PreparedRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-payload-\(UUID().uuidString)", isDirectory: true)
        let root = directory.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data("fixture\n".utf8).write(to: root.appendingPathComponent("README.md"))

        // Fake `codex exec --json`: drain stdin, then emit one oversized agent_message item.
        let fakeCodex = directory.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/sh
        cat >/dev/null
        printf '{"type":"item.completed","item":{"type":"agent_message","text":"'
        head -c \(replyCharacters) /dev/zero | tr '\\0' 'x'
        printf '"}}\\n'
        """
        try Data(script.utf8).write(to: fakeCodex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let service = DirectHeadlessMCPService(environment: [
            "REPOPROMPT_MCP_HEADLESS_PROFILE": "agent-run-payload-bound",
            "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": directory.appendingPathComponent("profile").path,
            "REPOPROMPT_MCP_WORKING_DIRS": root.path,
            "REPOPROMPT_CODEX_COMMAND": fakeCodex.path,
            "PATH": "/usr/bin:/bin"
        ], currentDirectory: root, allowsProviderProcessLaunchForTesting: true)
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        return prepared
    }

    private static func request(
        _ prepared: DirectHeadlessMCPService.PreparedRuntime,
        arguments: [String: Value]
    ) async throws -> DomainPhysicalToolRequest {
        let snapshot = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        let security = DomainToolInvocationSecurityContext(
            principal: prepared.principal,
            connectionID: prepared.connectionID,
            connectionGeneration: prepared.connectionGeneration,
            invocationID: UUID(),
            runtimeID: prepared.runtime.identity.runtimeID,
            runtimeGeneration: prepared.runtime.identity.lifecycleGeneration,
            workspaceID: snapshot.identity.workspaceID,
            workspaceRevision: snapshot.workspace.revisions.workingRevision,
            authorizedCanonicalRoots: Set(snapshot.roots.map(\.path)),
            hasAuthoritativeRoutingContext: true,
            ephemeralGrantedToolNames: [],
            ephemeralGrantedOperations: []
        )
        return try DomainPhysicalToolRequest(argumentsJSON: JSONEncoder().encode(arguments), securityContext: security)
    }
}
