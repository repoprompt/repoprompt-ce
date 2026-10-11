import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
import XCTest

final class AgentModeMCPToolAdvertisementPolicyTests: XCTestCase {
    func testDelegationAdvertisementRequiresTopLevelNonExploreControl() {
        let roleCases: [(AgentModelCatalog.TaskLabelKind, String)] = [
            (.pair, "Pair"),
            (.engineer, "Engineer"),
            (.design, "Design")
        ]

        for (role, label) in roleCases {
            XCTAssertTrue(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentRun,
                    taskLabelKind: role,
                    allowsAgentExternalControlTools: true
                ),
                "\(label) top-level agent_run"
            )
            XCTAssertTrue(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentManage,
                    taskLabelKind: role,
                    allowsAgentExternalControlTools: true
                ),
                "\(label) top-level agent_manage"
            )
            XCTAssertTrue(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentExplore,
                    taskLabelKind: role,
                    allowsAgentExternalControlTools: true
                ),
                "\(label) top-level agent_explore"
            )

            XCTAssertFalse(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentRun,
                    taskLabelKind: role,
                    allowsAgentExternalControlTools: false
                ),
                "\(label) nested agent_run"
            )
            XCTAssertFalse(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentManage,
                    taskLabelKind: role,
                    allowsAgentExternalControlTools: false
                ),
                "\(label) nested agent_manage"
            )
            XCTAssertTrue(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentExplore,
                    taskLabelKind: role,
                    allowsAgentExternalControlTools: false
                ),
                "\(label) nested agent_explore"
            )
        }

        for allowsExternalControl in [false, true] {
            XCTAssertFalse(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentRun,
                    taskLabelKind: .explore,
                    allowsAgentExternalControlTools: allowsExternalControl
                )
            )
            XCTAssertFalse(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentManage,
                    taskLabelKind: .explore,
                    allowsAgentExternalControlTools: allowsExternalControl
                )
            )
            XCTAssertFalse(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: MCPWindowToolName.agentExplore,
                    taskLabelKind: .explore,
                    allowsAgentExternalControlTools: allowsExternalControl
                )
            )
        }
    }

    func testDirectConnectionDoesNotAdvertiseExploreControl() {
        XCTAssertTrue(
            AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                toolName: MCPWindowToolName.agentRun,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false
            )
        )
        XCTAssertTrue(
            AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                toolName: MCPWindowToolName.agentManage,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false
            )
        )
        XCTAssertFalse(
            AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                toolName: MCPWindowToolName.agentExplore,
                taskLabelKind: nil,
                allowsAgentExternalControlTools: false
            )
        )
    }
}

@MainActor
final class AgentSessionLinkToolSchemaCacheTests: XCTestCase {
    func testInterleavedSessionsAndRoleTransitionsDoNotReuseOtherSurfaceSchema() async throws {
        #if DEBUG
            let manager = ServerNetworkManager(domainHost: AppDomainRuntimeComposition.shared.runtime.domainHost)
            let full = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.agentSessionLink))
            let reduced = AgentSessionLinkToolSurface.overseenOnly.project(full)
            // Same tool and run purpose across sessions, including promotion and later unlink.
            // Both cache population orders must work without a cache-wide invalidation.
            for surface: AgentSessionLinkToolSurface in [.overseenOnly, .full, .overseenOnly, .full] {
                let actual = try await manager.debugCachedToolSchema(
                    definition: full, purpose: .agentModeRun, surface: surface
                )
                XCTAssertEqual(actual, surface == .full ? full.inputSchema : reduced.inputSchema)
            }
            let otherManager = ServerNetworkManager(domainHost: AppDomainRuntimeComposition.shared.runtime.domainHost)
            for surface: AgentSessionLinkToolSurface in [.full, .overseenOnly, .full] {
                let actual = try await otherManager.debugCachedToolSchema(
                    definition: full, purpose: .agentModeRun, surface: surface
                )
                XCTAssertEqual(actual, surface == .full ? full.inputSchema : reduced.inputSchema)
            }
        #else
            throw XCTSkip("Production cache testing seam is DEBUG-only")
        #endif
    }
}

#if DEBUG
    /// Uses the existing conductor test-env passthrough; no developer-tool configuration changes.
    enum DiscoveryArtifactConfiguration {
        static var options: [String: String] {
            guard let raw = ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"],
                  let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String]
            else { return [:] }
            return object
        }

        static var directory: String? {
            options["artifactDirectory"]
        }

        static var isBaseline: Bool {
            options["baseline"] == "true"
        }
    }

    /// One bounded actual Agent socket workload, shared verbatim with the pristine baseline.
    @MainActor
    final class AgentSessionLinkCatalogScaleTests: XCTestCase {
        func testWarmActualRouteCatalogAtApprovedScale() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                try await self.exerciseScale()
            }
        }

        private func exerciseScale() async throws {
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let manager = ServerNetworkManager.shared
            let bridge = AgentSessionLinkRuntimeBridge.shared
            let authority = AppDomainRuntimeComposition.shared.runtime.agentSessionLinkAuthority
            var windows: [WindowState] = []
            var registrations: [MCPDomainToolRegistrationResult] = []
            var sessions: [(WindowState, AgentTabSession)] = []
            var connections: [PersistentMCPTestEndpoint] = []
            var runs: [(WindowState, UUID, String)] = []
            var grants: [DomainAgentSessionLinkReference] = []
            let candidate = !DiscoveryArtifactConfiguration.isBaseline
            let cleanup: @MainActor () async -> Void = {
                AgentSessionLinkCatalogReadProbe.enabled = false
                for grant in grants {
                    await bridge.revokeLink(linkID: grant.linkID, generation: grant.generation)
                }
                for connection in connections {
                    connection.client.close()
                    await connection.connectionManager.stop()
                    await manager.debugRemoveConnection(connection.connectionID)
                }
                for (window, runID, clientName) in runs {
                    await manager.clearClientConnectionPolicy(for: clientName, windowID: window.windowID, runID: runID)
                    await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
                }
                for window in windows {
                    await window.tearDown()
                    WindowStatesManager.shared.unregisterWindowState(window)
                }
                for registration in registrations {
                    await AppDomainRuntimeComposition.shared.unregister(registration.handle)
                }
            }
            do {
                for index in 0 ..< 3 {
                    let window = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime)
                    windows.append(window)
                    WindowStatesManager.shared.registerWindowState(window)
                    try await registrations.append(AppDomainRuntimeComposition.shared.register(window.mcpServer.windowMCPToolCatalogService))
                    await window.workspaceManager.awaitInitialized()
                    var workspace = WorkspaceModel(name: "Scale window \(index)", repoPaths: [])
                    workspace.isEphemeral = true
                    workspace.composeTabs = (0 ..< 100).map { ComposeTabState(id: UUID(), name: "Scale chat \($0)") }
                    workspace.activeComposeTabID = workspace.composeTabs.first?.id
                    window.workspaceManager.workspaces.append(workspace)
                    let switched = await window.workspaceManager.switchWorkspace(to: workspace, saveState: false)
                    XCTAssertTrue(switched.didSwitch)
                    window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
                    window.agentModeViewModel.test_setAgentSessionSaver { _, _, _ in
                        FileManager.default.temporaryDirectory.appendingPathComponent("scale-\(UUID()).json")
                    }
                    for tab in workspace.composeTabs {
                        let session = window.agentModeViewModel.session(for: tab.id)
                        session.selectedAgent = .claudeCode
                        session.hasLoadedPersistedState = true
                        session.oversight.autoWakeOnUpdates = false
                        _ = try XCTUnwrap(window.agentModeViewModel.test_ensureSessionBoundToTab(session))
                        sessions.append((window, session))
                    }
                }
                WindowStatesManager.shared.attachAgentSessionLinkBridge()
                let participants = [0, 100, 200, 1, 201, 2, 202, 101, 102, 203, 3, 103, 204, 104, 205].map { sessions[$0] }
                // Exactly four outbound owners and ten grants; endpoint 1 is both-direction.
                for (source, target) in [(0, 4), (0, 1), (1, 5), (1, 6), (2, 7), (2, 8), (2, 9), (3, 10), (3, 11), (3, 12)] {
                    let sourceID = try XCTUnwrap(participants[source].1.activeAgentSessionID)
                    let targetID = try XCTUnwrap(participants[target].1.activeAgentSessionID)
                    guard case .added = await bridge.addMonitorLink(observerSessionID: sourceID, rawTargetSessionID: targetID.uuidString) else {
                        return XCTFail("Scale setup grant failed")
                    }
                    let inventory = await authority.links(forObserver: sourceID)
                    let item = try XCTUnwrap(inventory.items.first { $0.targetSessionID == targetID })
                    grants.append(.init(linkID: item.linkID, generation: item.generation))
                }
                await manager.setEnabled(true)
                // Identical warm request population on both heads, including an excluded route.
                for index in [0, 1, 4, 13, 14] {
                    let (window, session) = participants[index]
                    let runID = UUID()
                    let clientName = [1, 4, 13].contains(index) ? AgentProviderKind.codexMCPClientID : AgentProviderKind.claudeMCPClientID
                    runs.append((window, runID, clientName))
                    session.installRunID(runID)
                    await manager.installClientConnectionPolicy(
                        for: clientName, windowID: window.windowID,
                        restrictedTools: AgentModeMCPToolPolicy.restrictedTools, oneShot: true,
                        reason: "Bounded role catalog scale", ttl: 60, tabID: session.tabID,
                        runID: runID, additionalTools: nil, purpose: .agentModeRun,
                        taskLabelKind: index == 14 ? .explore : nil, allowsAgentExternalControlTools: false
                    )
                    try await connections.append(PersistentMCPTestEndpoint.make(
                        label: "scale-\(index)", networkManager: manager,
                        clientName: clientName, requiredToolNames: [MCPWindowToolName.readFile]
                    ))
                }
                for index in 0 ..< 10 {
                    _ = try await definitions(connections[index % connections.count])
                }
                let readsBefore = AgentSessionLinkCatalogReadProbe.snapshot
                let roleReadsBefore = AgentSessionLinkCatalogReadProbe.roleSnapshot
                let hydrationBefore = await manager.debugCatalogHydrationWorkCount
                AgentSessionLinkCatalogReadProbe.enabled = true
                let clock = ContinuousClock()
                var samples: [Double] = []
                for index in 0 ..< 100 {
                    let start = clock.now
                    _ = try await definitions(connections[index % connections.count])
                    samples.append(milliseconds(start.duration(to: clock.now)))
                }
                AgentSessionLinkCatalogReadProbe.enabled = false
                let readsAfter = AgentSessionLinkCatalogReadProbe.snapshot
                let roleReadsAfter = AgentSessionLinkCatalogReadProbe.roleSnapshot
                let hydrationAfter = await manager.debugCatalogHydrationWorkCount
                XCTAssertEqual(roleReadsAfter, roleReadsBefore, "No census/location/provider availability/subagent reads in catalog role lookup")
                XCTAssertEqual(hydrationAfter, hydrationBefore, "Installed warm route must not enter persisted hydration")
                let sorted = samples.sorted()
                // Shared CI timing varies; gate pathological stalls, not the isolated performance budget.
                XCTAssertLessThanOrEqual(sorted[94], 500, "Warm catalog p95 must stay below the CI pathology ceiling")
                print("ROLE_CATALOG_SCALE candidate=\(candidate) chats=300 windows=3 overseers=4 links=10 warm=10 requests=100 p50_ms=\(sorted[49]) p95_ms=\(sorted[94]) max_ms=\(sorted[99]) reads=\(zip(readsAfter, readsBefore).map { $0.0 - $0.1 }) role_reads=\(zip(roleReadsAfter, roleReadsBefore).map { $0.0 - $0.1 }) hydration=\(hydrationAfter - hydrationBefore) raw_ms=\(samples)")
                if let directory = DiscoveryArtifactConfiguration.directory {
                    let root = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let report: [String: Any] = ["candidate": candidate, "samples_ms": samples, "p50_ms": sorted[49], "p95_ms": sorted[94], "max_ms": sorted[99], "reads": zip(readsAfter, readsBefore).map { $0.0 - $0.1 }, "hydration": hydrationAfter - hydrationBefore, "role_reads": zip(roleReadsAfter, roleReadsBefore).map { $0.0 - $0.1 }]
                    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: root.appendingPathComponent("scale.json"))
                }
                // One role table; captures are actual returned definitions, not source projection.
                for (index, role) in ["outbound", "both", "inbound", "plain", "excluded"].enumerated() {
                    let tools = try await definitions(connections[index], wireCaptureName: role)
                    try capture(tools, name: role)
                    let link = tools.first { $0["name"] as? String == "agent_session_link" }
                    let bootstrap = tools.contains { $0["name"] as? String == "become_overseer" }
                    XCTAssertEqual(link != nil, index < 3, role)
                    XCTAssertEqual(bootstrap, candidate && index == 3, role)
                    if index == 2, candidate { XCTAssertEqual(operations(link), ["set_waiting_on", "request_attention", "create_lane"]) }
                    if index < 2 || (index == 2 && !candidate) { XCTAssertGreaterThan(operations(link).count, 3, role) }
                }
                let external = try await PersistentMCPTestEndpoint.make(label: "scale-external", networkManager: manager, clientName: "scale-external", requiredToolNames: [MCPWindowToolName.readFile])
                connections.append(external)
                await manager.debugSetAdditionalTools(for: external.connectionID, additionalTools: ["agent_session_link"])
                let externalTools = try await definitions(external, wireCaptureName: "external")
                try capture(externalTools, name: "external")
                XCTAssertGreaterThan(operations(externalTools.first { $0["name"] as? String == "agent_session_link" }).count, 3)
                XCTAssertFalse(externalTools.contains { $0["name"] as? String == "become_overseer" })
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
        }

        private func definitions(_ connection: PersistentMCPTestEndpoint, wireCaptureName: String? = nil) async throws -> [[String: Any]] {
            let response = try await connection.client.request(method: "tools/list", params: [:], timeoutSeconds: 2)
            if let name = wireCaptureName, let directory = DiscoveryArtifactConfiguration.directory {
                try Data(response.rawJSON.utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + "-wire.json"))
            }
            let object = try MCPExportWatchdogIntegrationTests.responseObject(from: response)
            return try XCTUnwrap((object["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        }

        private func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }

        private func operations(_ tool: [String: Any]?) -> [String] {
            let schema = tool?["inputSchema"] as? [String: Any]
            let properties = schema?["properties"] as? [String: Any]
            return (properties?["op"] as? [String: Any])?["enum"] as? [String] ?? []
        }

        private func capture(_ tools: [[String: Any]], name: String) throws {
            guard let directory = DiscoveryArtifactConfiguration.directory else { return }
            let family = tools.filter { ["agent_session_link", "become_overseer"].contains($0["name"] as? String ?? "") }
            let data = try JSONSerialization.data(withJSONObject: family, options: [.sortedKeys, .withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".json"))
        }
    }
#endif
