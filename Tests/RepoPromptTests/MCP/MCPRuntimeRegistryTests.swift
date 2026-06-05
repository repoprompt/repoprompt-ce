import Foundation
import JSONSchema
@testable import RepoPrompt
import XCTest

@MainActor
final class MCPRuntimeSessionRegistryTests: XCTestCase {
    func testPendingEnableInsertionOrderDrainingAndRetirement() {
        let registry = MCPRuntimeSessionRegistry()
        let repository = WorkspaceRepository()
        let policy = UnrestrictedWorkspaceAccessPolicy()
        let first = RepoPromptCoreSession(
            routingSessionID: MCPRoutingSessionID(rawValue: 1),
            workspaceRepository: repository,
            workspaceAccessPolicy: policy,
            platformDependencies: MacOSRepoPromptCorePlatformDependencies.embeddedApp()
        )
        let second = RepoPromptCoreSession(
            routingSessionID: MCPRoutingSessionID(rawValue: 2),
            workspaceRepository: repository,
            workspaceAccessPolicy: policy,
            platformDependencies: MacOSRepoPromptCorePlatformDependencies.embeddedApp()
        )

        registry.setMCPEnabled(windowID: first.routingSessionID.rawValue, enabled: true)
        registry.register(session: first)
        registry.register(session: second)
        registry.setMCPEnabled(windowID: second.routingSessionID.rawValue, enabled: true)

        var snapshot = registry.routingSnapshot()
        XCTAssertEqual(snapshot.orderedActiveWindowIDs, [1, 2])
        XCTAssertEqual(snapshot.firstMCPEnabledWindowID, 1)
        XCTAssertTrue(snapshot.isMultiWindowModeEffectivelyActive)

        registry.beginDraining(windowID: 1)
        snapshot = registry.routingSnapshot()
        XCTAssertEqual(snapshot.orderedActiveWindowIDs, [2])
        XCTAssertEqual(snapshot.firstMCPEnabledWindowID, 2)
        XCTAssertFalse(registry.isInvocationAllowed(windowID: 1))

        registry.remove(windowID: 1)
        registry.setMCPEnabled(windowID: 1, enabled: true)
        registry.register(session: first)
        XCTAssertFalse(registry.hasActiveWindow(id: 1))
        #if DEBUG
            XCTAssertTrue(registry.debugIsRetired(windowID: 1))
        #endif
    }
}

@MainActor
final class MCPServiceRegistryTests: XCTestCase {
    func testRegistriesAreInstanceOwnedAndIndexCanonicalNames() async {
        let firstRegistry = MCPServiceRegistry()
        let secondRegistry = MCPServiceRegistry()
        let service = StaticToolService(tools: [Self.makeTool(name: "discover_prompt")])

        firstRegistry.register(service)
        let firstSnapshot = await firstRegistry.awaitCurrentSnapshot()
        let secondSnapshot = secondRegistry.routeSnapshot()

        XCTAssertEqual(firstSnapshot.routes(forCanonicalName: "prompt").map(\.tool.name), ["discover_prompt"])
        XCTAssertTrue(secondSnapshot.orderedRoutes.isEmpty)
    }

    func testUnregisterSynchronouslyFiltersCommittedRoutes() async {
        let registry = MCPServiceRegistry()
        let service = StaticToolService(tools: [Self.makeTool(name: "read_file")])

        registry.register(service)
        _ = await registry.awaitCurrentSnapshot()
        XCTAssertEqual(registry.routeSnapshot().routes(forCanonicalName: "read_file").count, 1)

        registry.unregister(service)
        XCTAssertTrue(registry.routeSnapshot().routes(forCanonicalName: "read_file").isEmpty)
    }

    func testRegistrySourceKeepsGenerationGate() throws {
        let source = try String(
            contentsOf: RepoRoot.url().appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/ServiceRegistry.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("guard generation == requestedGeneration else { continue }"))
        XCTAssertTrue(source.contains("routesByCanonicalName[canonicalName, default: []].append(route)"))
        XCTAssertTrue(source.contains("committedSnapshot.orderedRoutes.filter { $0.serviceIdentity != serviceIdentity }"))
    }

    private static func makeTool(name: String) -> Tool {
        Tool(
            name: name,
            description: "test",
            inputSchema: .object(properties: [:])
        ) { _ in
            ["ok": true]
        }
    }
}

private final class StaticToolService: Service {
    let storedTools: [Tool]

    init(tools: [Tool]) {
        storedTools = tools
    }

    var tools: [Tool] {
        get async { storedTools }
    }
}
