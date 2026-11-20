import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCPCore
import RepoPromptShared
import XCTest

private actor HeadlessStartupGate {
    private var registration: DomainAgentSessionRegistration?
    private var observers: [CheckedContinuation<DomainAgentSessionRegistration, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    func hold(_ registration: DomainAgentSessionRegistration) async {
        self.registration = registration
        let observers = observers
        self.observers.removeAll()
        for observer in observers {
            observer.resume(returning: registration)
        }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilHeld() async -> DomainAgentSessionRegistration {
        if let registration { return registration }
        return await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

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

    func testCancellationIsInstalledBeforeEpochPublicationAndJoinsPendingStartupRollback() async throws {
        let prepared = try await makePreparedRuntime(replyCharacters: 1)
        let gate = HeadlessStartupGate()
        let coordinator = makeHeldCoordinator(prepared, gate: gate)
        let cancelled = expectation(description: "Exact registered handler reached pending startup")
        await coordinator.test_observePendingStartCancellation { cancelled.fulfill() }
        let request = try await Self.request(prepared, arguments: [:])
        let start = Task {
            try await coordinator.startAgent(args: ["message": .string("Never launch"), "detach": .bool(true)], request: request)
        }
        let registration = await gate.waitUntilHeld()
        let owned = await prepared.runtime.agentSessionStore.test_shutdownOwnedState()
        XCTAssertEqual(owned.cancellationHandlerCount, 1, "Registration is already cancellable while epoch setup is held")
        let cancellation = Task {
            await prepared.runtime.agentSessionStore.test_invokeCancellationHandler(registration: registration)
        }
        await fulfillment(of: [cancelled], timeout: 3)
        await gate.release()
        do {
            _ = try await start.value
            XCTFail("Cancelled pending start must not publish running or launch a provider")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected startup error: \(error)")
        }
        let invoked = await cancellation.value
        XCTAssertTrue(invoked)
        let remaining = await prepared.runtime.agentSessionStore.test_shutdownOwnedState()
        XCTAssertEqual(remaining.recordCount, 0)
        XCTAssertEqual(remaining.cancellationHandlerCount, 0)
        let agents = await coordinator.listAgents()
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.objectValue?["status"], .string("dormant"))
        XCTAssertEqual(agents.first?.objectValue?["resumable"], .bool(true), "Preserve the domain store's existing durable cleanup policy")
        await coordinator.shutdown()
    }

    func testStoreShutdownDrainsHeldHeadlessStartupBeforeReturning() async throws {
        let prepared = try await makePreparedRuntime(replyCharacters: 1)
        let gate = HeadlessStartupGate()
        let coordinator = makeHeldCoordinator(prepared, gate: gate)
        let cancelled = expectation(description: "Store shutdown cancelled registered pending startup")
        await coordinator.test_observePendingStartCancellation { cancelled.fulfill() }
        let request = try await Self.request(prepared, arguments: [:])
        let start = Task {
            try await coordinator.startAgent(args: ["message": .string("Never launch"), "detach": .bool(true)], request: request)
        }
        let registration = await gate.waitUntilHeld()
        let shutdown = Task { await prepared.runtime.agentSessionStore.shutdown() }
        await fulfillment(of: [cancelled], timeout: 3)
        await gate.release()
        do {
            _ = try await start.value
            XCTFail("Shutdown must refuse the pending start")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected startup error: \(error)")
        }
        let shutdownResult = await shutdown.value
        XCTAssertEqual(shutdownResult.cooperativeSessionIDs, [registration.sessionID])
        XCTAssertTrue(shutdownResult.interruptedSessionIDs.isEmpty)
        let remaining = await prepared.runtime.agentSessionStore.test_shutdownOwnedState()
        XCTAssertEqual(remaining.recordCount, 0)
        XCTAssertEqual(remaining.cancellationHandlerCount, 0)
        let agents = await coordinator.listAgents()
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.objectValue?["status"], .string("dormant"))
        XCTAssertEqual(agents.first?.objectValue?["resumable"], .bool(true), "Preserve the domain store's existing durable cleanup policy")
        await coordinator.shutdown()
    }

    func testCallerCancellationAfterEpochAdmissionCleansRegistrationWithoutPublishingRunning() async throws {
        let prepared = try await makePreparedRuntime(replyCharacters: 1)
        let gate = HeadlessStartupGate()
        let coordinator = makeHeldCoordinator(prepared, gate: gate)
        let request = try await Self.request(prepared, arguments: [:])
        let start = Task {
            try await coordinator.startAgent(args: ["message": .string("Never launch"), "detach": .bool(true)], request: request)
        }
        _ = await gate.waitUntilHeld()
        start.cancel()
        await gate.release()
        do {
            _ = try await start.value
            XCTFail("Caller cancellation must roll back the admitted epoch")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected startup error: \(error)")
        }
        let remaining = await prepared.runtime.agentSessionStore.test_shutdownOwnedState()
        XCTAssertEqual(remaining.recordCount, 0)
        XCTAssertEqual(remaining.cancellationHandlerCount, 0)
        let agents = await coordinator.listAgents()
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.objectValue?["status"], .string("dormant"))
        XCTAssertEqual(agents.first?.objectValue?["resumable"], .bool(true), "Preserve the domain store's existing durable cleanup policy")
        await coordinator.shutdown()
    }

    func testPublishedRunningStartAlreadyOwnsCancellationBeforeProviderLaunch() async throws {
        let prepared = try await makePreparedRuntime(replyCharacters: 1)
        let coordinator = prepared.providerCoordinator
        let gate = HeadlessStartupGate()
        await coordinator.test_observeRunningPublication { await gate.hold($0) }
        let cancelled = expectation(description: "Published start is cancellable before task attachment")
        await coordinator.test_observePendingStartCancellation { cancelled.fulfill() }
        let request = try await Self.request(prepared, arguments: [:])
        let start = Task {
            try await coordinator.startAgent(args: ["message": .string("Never launch"), "detach": .bool(true)], request: request)
        }
        let registration = await gate.waitUntilHeld()
        let snapshot = await prepared.runtime.agentSessionStore.snapshot(for: registration)
        XCTAssertEqual(snapshot?.status, .running)
        let cancellation = Task {
            await prepared.runtime.agentSessionStore.test_invokeCancellationHandler(registration: registration)
        }
        await fulfillment(of: [cancelled], timeout: 3)
        await gate.release()
        do {
            _ = try await start.value
            XCTFail("Cancelled visible start must not launch its provider")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected startup error: \(error)")
        }
        let invoked = await cancellation.value
        XCTAssertTrue(invoked)
        let context = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        let root = try XCTUnwrap(context.activeRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("provider-launched").path))
        let remaining = await prepared.runtime.agentSessionStore.test_shutdownOwnedState()
        XCTAssertEqual(remaining.recordCount, 0)
        XCTAssertEqual(remaining.cancellationHandlerCount, 0)
    }

    func testCoordinatorShutdownJoinsPendingStartRollback() async throws {
        let prepared = try await makePreparedRuntime(replyCharacters: 1)
        let gate = HeadlessStartupGate()
        let coordinator = makeHeldCoordinator(prepared, gate: gate)
        let cancelled = expectation(description: "Coordinator shutdown retracts pending start")
        await coordinator.test_observePendingStartCancellation { cancelled.fulfill() }
        let request = try await Self.request(prepared, arguments: [:])
        let start = Task {
            try await coordinator.startAgent(args: ["message": .string("Never launch"), "detach": .bool(true)], request: request)
        }
        _ = await gate.waitUntilHeld()
        let shutdown = Task { await coordinator.shutdown() }
        await fulfillment(of: [cancelled], timeout: 3)
        await gate.release()
        await shutdown.value
        // Inspect immediately after shutdown, before joining the caller: rollback is part of drain.
        let remaining = await prepared.runtime.agentSessionStore.test_shutdownOwnedState()
        XCTAssertEqual(remaining.recordCount, 0)
        XCTAssertEqual(remaining.cancellationHandlerCount, 0)
        do {
            _ = try await start.value
            XCTFail("Coordinator shutdown must retract the pending start")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected startup error: \(error)")
        }
    }

    func testAlreadyShutDownStoreRefusesHeadlessStartAsCancellation() async throws {
        let prepared = try await makePreparedRuntime(replyCharacters: 1)
        _ = await prepared.runtime.agentSessionStore.shutdown()
        let request = try await Self.request(prepared, arguments: [:])
        do {
            _ = try await prepared.providerCoordinator.startAgent(
                args: ["message": .string("Never launch"), "detach": .bool(true)], request: request
            )
            XCTFail("A generation-zero registration must not become an epoch or running agent")
        } catch is CancellationError {} catch {
            XCTFail("Shutdown is cancellation, not an internal epoch error: \(error)")
        }
        let remaining = await prepared.runtime.agentSessionStore.test_shutdownOwnedState()
        XCTAssertEqual(remaining.recordCount, 0)
        XCTAssertEqual(remaining.cancellationHandlerCount, 0)
        let agents = await prepared.providerCoordinator.listAgents()
        XCTAssertTrue(agents.isEmpty)
    }

    private func makeHeldCoordinator(
        _ prepared: DirectHeadlessMCPService.PreparedRuntime,
        gate: HeadlessStartupGate
    ) -> DirectHeadlessProviderCoordinator {
        DirectHeadlessProviderCoordinator(
            runtime: prepared.runtime,
            context: prepared.context,
            settingsStore: prepared.settingsStore,
            environment: ["REPOPROMPT_CODEX_COMMAND": "/usr/bin/false", "PATH": "/usr/bin:/bin"],
            beginEpoch: { registration, activationID in
                let result = await prepared.runtime.agentSessionStore.beginEpoch(
                    registration: registration,
                    activationID: activationID,
                    expectedCurrentEpoch: nil,
                    transitionKind: .initial
                )
                await gate.hold(registration)
                return result
            }
        )
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
        XCTAssertEqual(object["status_text"] as? String, "Completed", "\(label) status_text must be the concise label")
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
        touch '\(root.appendingPathComponent("provider-launched").path)'
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
