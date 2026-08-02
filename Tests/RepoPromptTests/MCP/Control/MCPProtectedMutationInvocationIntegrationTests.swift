import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class MCPProtectedMutationInvocationIntegrationTests: XCTestCase {
        func testPromptStateMutationsCommitWithoutPhysicalPathAdmission() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await makeFixture(lease: lease)
                let endpoint = try fixture.endpointA()
                let manager = fixture.networkManager
                do {
                    try await registerDomainWorkspace(fixture.contextA)
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: .verified(processID: Int(getpid()), fingerprint: "test:verified:prompt-state")
                    )
                    try await bind(endpoint, to: fixture.contextA)

                    let runtime = AppDomainRuntimeComposition.shared.runtime
                    var journalKeys = try await Set(runtime.mutationJournal.snapshot().recordSnapshots.map(\.key))
                    let preset = fixture.contextA.window.promptManager.currentCopyPreset()
                    let mutations: [(toolName: String, action: String, arguments: [String: Any])] = [
                        ("prompt", "set", ["op": "set", "text": "alpha"]),
                        ("prompt", "append", ["op": "append", "text": " beta"]),
                        ("prompt", "clear", ["op": "clear"]),
                        ("prompt", "select_preset", ["op": "select_preset", "preset": preset.id.uuidString]),
                        ("workspace_context", "select_preset", ["op": "select_preset", "preset": preset.id.uuidString])
                    ]

                    for (index, mutation) in mutations.enumerated() {
                        var arguments = mutation.arguments
                        arguments["operation_id"] = "prompt-state-\(index)"
                        let response = try await endpoint.callTool(name: mutation.toolName, arguments: arguments)
                        let result = try toolResult(response)
                        XCTAssertFalse(result.isError, "\(mutation.toolName).\(mutation.action): \(result.text)")
                        let capture = try await captureJournalRecord(
                            runtime: runtime,
                            excluding: journalKeys,
                            toolName: mutation.toolName,
                            action: mutation.action
                        )
                        journalKeys = capture.allKeys
                        XCTAssertEqual(capture.record.status.rawValue, DomainMutationJournalStatus.applied.rawValue)
                        XCTAssertNil(capture.record.pathFence)
                    }
                    XCTAssertEqual(fixture.contextA.window.promptManager.promptText, "")

                    await manager.debugSetDomainPeerIdentityForTesting(connectionID: endpoint.connectionID, identity: nil)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await manager.debugSetDomainPeerIdentityForTesting(connectionID: endpoint.connectionID, identity: nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testFileActionRevalidatesFenceAfterCommitAtBlockingIOBoundary() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await makeFixture(lease: lease)
                let endpoint = try fixture.endpointA()
                let manager = fixture.networkManager
                let store = fixture.contextA.window.workspaceFileContextStore
                let parent = fixture.contextA.rootURL.appendingPathComponent("late-swap-parent", isDirectory: true)
                let outside = fixture.rootURL.appendingPathComponent("late-swap-outside", isDirectory: true)
                let target = parent.appendingPathComponent("nested/blocked.txt")
                let escapedTarget = outside.appendingPathComponent("nested/blocked.txt")
                let swap = MutationBoundarySwapRecorder()
                do {
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                    try await store.startWatchingRoot(id: fixture.contextA.rootID)
                    let loadedService = await store.fileSystemServiceForTesting(rootID: fixture.contextA.rootID)
                    let service = try XCTUnwrap(loadedService)
                    await service.setMutationIOWillExecuteHandlerForTesting { operation in
                        guard operation == .create else { return }
                        swap.perform {
                            try FileManager.default.removeItem(at: parent)
                            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
                        }
                    }

                    try await registerDomainWorkspace(fixture.contextA)
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: .verified(processID: Int(getpid()), fingerprint: "test:verified:late-fence")
                    )
                    try await bind(endpoint, to: fixture.contextA)
                    let runtime = AppDomainRuntimeComposition.shared.runtime
                    let journalKeys = try await Set(runtime.mutationJournal.snapshot().recordSnapshots.map(\.key))

                    let response = try await endpoint.callTool(
                        name: "file_actions",
                        arguments: [
                            "action": "create",
                            "path": target.path,
                            "content": "must not escape",
                            "operation_id": "late-fence-swap"
                        ]
                    )
                    let result = try toolResult(response)
                    XCTAssertTrue(result.isError, result.text)
                    XCTAssertTrue(swap.didPerform)
                    XCTAssertNil(swap.error)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: escapedTarget.path))
                    let capture = try await captureJournalRecord(
                        runtime: runtime,
                        excluding: journalKeys,
                        toolName: "file_actions",
                        action: "create"
                    )
                    XCTAssertEqual(
                        capture.record.status.rawValue,
                        DomainMutationJournalStatus.indeterminateAfterCommit.rawValue
                    )

                    await service.setMutationIOWillExecuteHandlerForTesting(nil)
                    try? FileManager.default.removeItem(at: parent)
                    try? FileManager.default.removeItem(at: outside)
                    await manager.debugSetDomainPeerIdentityForTesting(connectionID: endpoint.connectionID, identity: nil)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    if let service = await store.fileSystemServiceForTesting(rootID: fixture.contextA.rootID) {
                        await service.setMutationIOWillExecuteHandlerForTesting(nil)
                    }
                    try? FileManager.default.removeItem(at: parent)
                    try? FileManager.default.removeItem(at: outside)
                    await manager.debugSetDomainPeerIdentityForTesting(connectionID: endpoint.connectionID, identity: nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        func testRunScopedInvocationUsesAuthoritativeRegistrationAndVerifiedIdentity() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await makeFixture(lease: lease)
                let endpoint = try fixture.endpointA()
                let manager = fixture.networkManager
                do {
                    try await registerDomainWorkspace(fixture.contextA)
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: .verified(processID: Int(getpid()), fingerprint: "test:verified:app")
                    )
                    try await bind(endpoint, to: fixture.contextA)
                    let initial = try await authoritativeContext(
                        manager: manager,
                        endpoint: endpoint,
                        toolName: "manage_selection"
                    )

                    _ = await AppDomainRuntimeComposition.shared.runtime.routingCoordinator.registerConnection(
                        connectionID: endpoint.connectionID,
                        operationID: UUID()
                    )
                    let reRegistered = await manager.debugDomainInvocationSecurityContextForTesting(
                        connectionID: endpoint.connectionID,
                        toolName: "manage_selection"
                    )
                    XCTAssertGreaterThan(reRegistered.connectionGeneration, initial.connectionGeneration)
                    XCTAssertFalse(reRegistered.hasAuthoritativeRoutingContext)
                    XCTAssertTrue(reRegistered.authorizedCanonicalRoots.isEmpty)

                    let currentRegistration = try await AppDomainRuntimeComposition.shared.runtime
                        .routingCoordinator.currentRegistration(connectionID: endpoint.connectionID)
                    let reboundOutcome = await AppDomainRuntimeComposition.shared.runtime.routingCoordinator.bind(
                        connection: currentRegistration,
                        binding: .context(
                            .init(
                                workspaceID: fixture.contextA.workspaceID,
                                contextID: fixture.contextA.tabID
                            ),
                            explicit: true
                        ),
                        operationID: UUID()
                    )
                    XCTAssertEqual(reboundOutcome.disposition, .applied)
                    let rebound = try await authoritativeContext(
                        manager: manager,
                        endpoint: endpoint,
                        toolName: "manage_selection"
                    )
                    XCTAssertEqual(rebound.workspaceID, fixture.contextA.workspaceID)
                    XCTAssertTrue(rebound.authorizedCanonicalRoots.contains(fixture.contextA.rootURL.path))

                    await manager.setRunPurpose(.agentModeRun, for: endpoint.connectionID)
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: .unverified
                    )
                    let denied = try await endpoint.callTool(
                        name: "manage_selection",
                        arguments: ["op": "clear"]
                    )
                    let deniedResult = try toolResult(denied)
                    XCTAssertTrue(deniedResult.isError)
                    XCTAssertTrue(deniedResult.text.contains("principalUnverified"), deniedResult.text)

                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: .verified(processID: Int(getpid()), fingerprint: "test:verified:app")
                    )
                    let allowed = try await endpoint.callTool(
                        name: "manage_selection",
                        arguments: ["op": "clear"]
                    )
                    XCTAssertFalse(try toolResult(allowed).isError)

                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: nil
                    )
                    await manager.setRunPurpose(.unknown, for: endpoint.connectionID)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await manager.debugSetDomainPeerIdentityForTesting(
                        connectionID: endpoint.connectionID,
                        identity: nil
                    )
                    await manager.setRunPurpose(.unknown, for: endpoint.connectionID)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private func makeFixture(
            lease: MCPSharedServerTestLease.Ownership
        ) async throws -> PersistentMCPTestFixture {
            try await PersistentMCPTestFixture.make(
                lease: lease,
                domainRuntime: AppDomainRuntimeComposition.shared.runtime
            )
        }

        private func captureJournalRecord(
            runtime: MCPDomainRuntime,
            excluding priorKeys: Set<String>,
            toolName: String,
            action: String
        ) async throws -> (record: DomainMutationJournalRecord, allKeys: Set<String>) {
            let document = try await runtime.mutationJournal.snapshot()
            let matches = document.recordSnapshots.filter {
                !priorKeys.contains($0.key) && $0.toolName == toolName && $0.action == action
            }
            let allKeys = Set(document.recordSnapshots.map(\.key))
            XCTAssertEqual(matches.count, 1, "new journal records=\(allKeys.sorted())")
            return try (XCTUnwrap(matches.first), allKeys)
        }

        private func registerDomainWorkspace(_ context: PersistentMCPTestContext) async throws {
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID }
            )
            let client = DomainWorkspaceAuthorityClient(
                store: AppDomainRuntimeComposition.shared.runtime.workspaceStore,
                windowID: context.window.windowID
            )
            _ = try await client.registerForRead(
                workspace,
                fileURL: context.rootURL.appendingPathComponent("fixture.repoprompt-workspace")
            )
        }

        private func bind(
            _ endpoint: PersistentMCPTestEndpoint,
            to context: PersistentMCPTestContext
        ) async throws {
            let response = try await endpoint.callTool(
                name: "bind_context",
                arguments: ["op": "bind", "context_id": context.tabID.uuidString]
            )
            let result = try toolResult(response)
            XCTAssertFalse(result.isError, result.text)
            await context.window.mcpServer.domainRoutingPublishTask?.value
        }

        private func authoritativeContext(
            manager: ServerNetworkManager,
            endpoint: PersistentMCPTestEndpoint,
            toolName: String
        ) async throws -> DomainToolInvocationSecurityContext {
            let context = await manager.debugDomainInvocationSecurityContextForTesting(
                connectionID: endpoint.connectionID,
                toolName: toolName
            )
            guard context.hasAuthoritativeRoutingContext, context.workspaceID != nil,
                  !context.authorizedCanonicalRoots.isEmpty
            else {
                throw NSError(
                    domain: "MCPProtectedMutationInvocationIntegrationTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "domain routing context was not authoritative after binding publication completed"]
                )
            }
            return context
        }

        private func toolResult(_ response: PersistentMCPTestRPCResponse) throws -> (isError: Bool, text: String) {
            let data = try XCTUnwrap(response.rawJSON.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((object["id"] as? NSNumber)?.intValue, response.id)
            XCTAssertNil(object["error"])
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return (
                result["isError"] as? Bool == true,
                content.compactMap { $0["text"] as? String }.joined()
            )
        }
    }

    private final class MutationBoundarySwapRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedDidPerform = false
        private var storedError: (any Error)?

        var didPerform: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storedDidPerform
        }

        var error: (any Error)? {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }

        func perform(_ operation: @Sendable () throws -> Void) {
            lock.lock()
            guard !storedDidPerform else {
                lock.unlock()
                return
            }
            storedDidPerform = true
            lock.unlock()
            do {
                try operation()
            } catch {
                lock.lock()
                storedError = error
                lock.unlock()
            }
        }
    }
#endif
