import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class MCPReadAutoSelectionRecoveryIntegrationTests: XCTestCase {
        func testParkedMirrorConnectionRemovalPreservesSameWindowOwnerAndSelectionMutations() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(
                    lease: lease,
                    domainRuntime: AppDomainRuntimeComposition.shared.runtime
                )
                let manager = fixture.networkManager
                let server = fixture.contextA.window.mcpServer
                let mirrorGate = MCPExecutionIgnoringCancellationGate()
                let secondRelativePath = "Sources/RecoverySurvivor.swift"
                let secondURL = fixture.contextA.rootURL.appendingPathComponent(secondRelativePath)
                var removedEndpoint: PersistentMCPTestEndpoint?
                var survivorEndpoint: PersistentMCPTestEndpoint?
                var firstReadTask: Task<PersistentMCPTestRPCResponse, Error>?

                _ = try await fixture.contextA.window.workspaceFileContextStore.createFile(
                    rootID: fixture.contextA.rootID,
                    relativePath: secondRelativePath,
                    content: SwiftFixtureSource.emptyStruct("RecoverySurvivor")
                )
                do {
                    try await fixture.registerDomainWorkspace(fixture.contextA)
                    try await Self.activateWorkspace(fixture.contextA)
                    let first = try await Self.makeBoundEndpoint(
                        label: "parked-owner",
                        fixture: fixture
                    )
                    removedEndpoint = first
                    let survivor = try await Self.makeBoundEndpoint(
                        label: "surviving-owner",
                        fixture: fixture
                    )
                    survivorEndpoint = survivor

                    _ = try await survivor.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: ["op": "clear"]
                    )
                    server.setReadFileAutoSelectionMirrorGateForTesting {
                        await mirrorGate.enterAndWait()
                    }
                    let activeFirstReadTask = Task {
                        try await first.callTool(
                            name: MCPWindowToolName.readFile,
                            arguments: ["path": fixture.contextA.fileURL.path]
                        )
                    }
                    firstReadTask = activeFirstReadTask
                    try await mirrorGate.waitUntilEntered(count: 1)

                    let removalTask = Task {
                        await manager.removeConnection(first.connectionID)
                    }
                    await mirrorGate.release()
                    await removalTask.value
                    _ = try? await activeFirstReadTask.value
                    firstReadTask = nil
                    removedEndpoint = nil
                    XCTAssertNil(server.tabContextByConnectionID[first.connectionID])
                    XCTAssertEqual(
                        server.tabContextByConnectionID[survivor.connectionID]?.tabID,
                        fixture.contextA.tabID
                    )

                    server.setReadFileAutoSelectionMirrorGateForTesting(nil)
                    let add = try await survivor.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: [
                            "op": "add",
                            "paths": [secondURL.path],
                            "view": "files"
                        ]
                    )
                    XCTAssertFalse(add.rawJSON.contains("\"isError\":true"), add.rawJSON)
                    let get = try await survivor.callTool(
                        name: MCPWindowToolName.manageSelection,
                        arguments: ["op": "get", "view": "files"]
                    )
                    let text = try Self.toolResultText(get)
                    XCTAssertTrue(text.contains(fixture.contextA.fileURL.lastPathComponent), text)
                    XCTAssertTrue(text.contains(secondURL.lastPathComponent), text)
                    XCTAssertEqual(
                        Set(server.tabContextByConnectionID[survivor.connectionID]?.selection.selectedPaths ?? []),
                        Set([fixture.contextA.fileURL.path, secondURL.path])
                    )

                    await Self.cleanupEndpoint(survivor, manager: manager)
                    survivorEndpoint = nil
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    firstReadTask?.cancel()
                    await mirrorGate.release()
                    server.setReadFileAutoSelectionMirrorGateForTesting(nil)
                    if let firstReadTask { _ = try? await firstReadTask.value }
                    if let removedEndpoint { await Self.cleanupEndpoint(removedEndpoint, manager: manager) }
                    if let survivorEndpoint { await Self.cleanupEndpoint(survivorEndpoint, manager: manager) }
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        private static func makeBoundEndpoint(
            label: String,
            fixture: PersistentMCPTestFixture
        ) async throws -> PersistentMCPTestEndpoint {
            let manager = fixture.networkManager
            let clientName = "read-recovery-\(label)-\(UUID().uuidString)"
            let endpoint = try await PersistentMCPTestEndpoint.make(
                label: label,
                networkManager: manager,
                clientName: clientName,
                requiredToolNames: [MCPWindowToolName.readFile, MCPWindowToolName.manageSelection]
            )
            await manager.debugSetDomainPeerIdentityForTesting(
                connectionID: endpoint.connectionID,
                identity: .verified(
                    processID: Int(getpid()),
                    fingerprint: "test:verified:read-auto-selection-recovery"
                )
            )
            let bind = try await endpoint.callTool(
                name: "bind_context",
                arguments: ["op": "bind", "context_id": fixture.contextA.tabID.uuidString]
            )
            XCTAssertFalse(bind.rawJSON.contains("\"isError\":true"), bind.rawJSON)
            await fixture.contextA.window.mcpServer.domainRoutingPublishTask?.value
            return endpoint
        }

        private static func activateWorkspace(_ context: PersistentMCPTestContext) async throws {
            let workspace = try XCTUnwrap(
                context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID }
            )
            await context.window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "MCPReadAutoSelectionRecoveryIntegrationTests"
            )
            context.window.promptManager.loadComposeTabsFromWorkspace(
                workspace,
                syncPromptText: true
            )
        }

        private static func cleanupEndpoint(
            _ endpoint: PersistentMCPTestEndpoint,
            manager: ServerNetworkManager
        ) async {
            await manager.debugSetDomainPeerIdentityForTesting(
                connectionID: endpoint.connectionID,
                identity: nil
            )
            endpoint.client.close()
            await endpoint.connectionManager.stop()
            await manager.debugRemoveConnection(endpoint.connectionID)
            await manager.clearClientConnectionPolicy(for: endpoint.clientName)
            await manager.debugClearPersistedRoutingState(for: endpoint.clientName)
        }

        private static func toolResultText(_ response: PersistentMCPTestRPCResponse) throws -> String {
            let object = try MCPExportWatchdogIntegrationTests.responseObject(from: response)
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return try XCTUnwrap(content.first?["text"] as? String)
        }
    }
#endif
