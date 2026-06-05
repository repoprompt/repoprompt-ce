import Foundation
import JSONSchema
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

@MainActor
final class MCPRuntimeSessionRegistryTests: XCTestCase {
    func testPendingEnableInsertionOrderDrainingAndRetirement() {
        let registry = MCPRuntimeSessionRegistry()
        let graph = EmbeddedWorkspaceRepositoryFactory.make()
        let repository = graph.repository
        let policy = UnrestrictedWorkspaceAccessPolicy()
        let first = RepoPromptCoreSession(
            routingSessionID: MCPRoutingSessionID(rawValue: 1),
            workspaceRepository: repository,
            workspacePersistenceWriter: graph.writer,
            workspaceAccessPolicy: policy,
            platformDependencies: MacOSRepoPromptCorePlatformDependencies.embeddedApp()
        )
        let second = RepoPromptCoreSession(
            routingSessionID: MCPRoutingSessionID(rawValue: 2),
            workspaceRepository: repository,
            workspacePersistenceWriter: graph.writer,
            workspaceAccessPolicy: policy,
            platformDependencies: MacOSRepoPromptCorePlatformDependencies.embeddedApp()
        )

        registry.setMCPEnabled(windowID: first.routingSessionID.rawValue, enabled: true)
        XCTAssertEqual(registry.register(session: first), .accepted)
        XCTAssertEqual(registry.register(session: second), .accepted)
        registry.setMCPEnabled(windowID: second.routingSessionID.rawValue, enabled: true)

        var snapshot = registry.routingSnapshot()
        XCTAssertEqual(snapshot.orderedActiveWindowIDs, [1, 2])
        XCTAssertEqual(snapshot.firstMCPEnabledWindowID, 1)
        XCTAssertTrue(snapshot.isMultiWindowModeEffectivelyActive)

        XCTAssertTrue(registry.beginDraining(windowID: 1, expectedSessionID: first.sessionID))
        snapshot = registry.routingSnapshot()
        XCTAssertEqual(snapshot.orderedActiveWindowIDs, [2])
        XCTAssertEqual(snapshot.firstMCPEnabledWindowID, 2)
        XCTAssertFalse(registry.isInvocationAllowed(windowID: 1))

        XCTAssertTrue(registry.remove(windowID: 1, expectedSessionID: first.sessionID))
        registry.setMCPEnabled(windowID: 1, enabled: true)
        XCTAssertEqual(registry.register(session: first), .retiredRoutingID)
        XCTAssertFalse(registry.hasActiveWindow(id: 1))
        #if DEBUG
            XCTAssertTrue(registry.debugIsRetired(windowID: 1))
        #endif
    }

    func testDuplicateRoutingIDCannotReplaceOrDrainOwningSession() {
        let registry = MCPRuntimeSessionRegistry()
        let graph = EmbeddedWorkspaceRepositoryFactory.make()
        let repository = graph.repository
        let policy = UnrestrictedWorkspaceAccessPolicy()
        let owner = RepoPromptCoreSession(
            routingSessionID: MCPRoutingSessionID(rawValue: 7),
            workspaceRepository: repository,
            workspacePersistenceWriter: graph.writer,
            workspaceAccessPolicy: policy,
            platformDependencies: MacOSRepoPromptCorePlatformDependencies.embeddedApp()
        )
        let duplicate = RepoPromptCoreSession(
            routingSessionID: MCPRoutingSessionID(rawValue: 7),
            workspaceRepository: repository,
            workspacePersistenceWriter: graph.writer,
            workspaceAccessPolicy: policy,
            platformDependencies: MacOSRepoPromptCorePlatformDependencies.embeddedApp()
        )

        XCTAssertEqual(registry.register(session: owner), .accepted)
        registry.setMCPEnabled(windowID: 7, enabled: true)
        XCTAssertEqual(registry.register(session: duplicate), .routingIDInUse)
        XCTAssertFalse(registry.beginDraining(windowID: 7, expectedSessionID: duplicate.sessionID))
        XCTAssertFalse(registry.remove(windowID: 7, expectedSessionID: duplicate.sessionID))
        XCTAssertFalse(registry.setMCPEnabled(
            windowID: 7,
            expectedSessionID: duplicate.sessionID,
            enabled: false
        ))
        XCTAssertTrue(registry.isInvocationAllowed(windowID: 7))
        XCTAssertEqual(registry.session(withRoutingID: 7)?.sessionID, owner.sessionID)
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

    func testPublicationBoundaryWaitsForCapturedServiceButNotLaterRegistration() async {
        let registry = MCPServiceRegistry()
        let first = StaticToolService(tools: [Self.makeTool(name: "first_tool")])
        registry.register(first)
        _ = await registry.awaitCurrentSnapshot()

        let capturedGate = CatalogBarrier()
        let captured = BarrierToolService(
            tools: [Self.makeTool(name: "captured_tool")],
            gate: capturedGate
        )
        registry.register(captured)
        let boundary = registry.capturePublicationBoundary()
        let completed = CompletionSignal()
        let snapshotTask = Task {
            let snapshot = await registry.snapshot(for: boundary)
            await completed.mark()
            return snapshot
        }
        await capturedGate.waitUntilStartedCount(2)
        let completedBeforeRelease = await completed.isMarked()
        XCTAssertFalse(completedBeforeRelease)

        let laterGate = CatalogBarrier()
        let later = BarrierToolService(
            tools: [Self.makeTool(name: "later_tool")],
            gate: laterGate
        )
        registry.register(later)
        await laterGate.waitUntilStartedCount(1)

        await capturedGate.release()
        let snapshot = await snapshotTask.value
        let completedAfterRelease = await completed.isMarked()
        XCTAssertTrue(completedAfterRelease)
        XCTAssertEqual(snapshot.routes(forCanonicalName: "first_tool").count, 1)
        XCTAssertEqual(snapshot.routes(forCanonicalName: "captured_tool").count, 1)
        XCTAssertTrue(snapshot.routes(forCanonicalName: "later_tool").isEmpty)

        await laterGate.release()
        _ = await registry.awaitCurrentSnapshot()
    }

    func testCatalogInvalidationStalesOnlyRoutesFromThatService() async throws {
        let registry = MCPServiceRegistry()
        let first = MutableToolService(tools: [Self.makeTool(name: "first_tool")])
        let second = MutableToolService(tools: [Self.makeTool(name: "second_tool")])
        registry.register(first)
        registry.register(second)
        let snapshot = await registry.awaitCurrentSnapshot()
        let firstRoute = try XCTUnwrap(snapshot.routes(forCanonicalName: "first_tool").first)
        let secondRoute = try XCTUnwrap(snapshot.routes(forCanonicalName: "second_tool").first)

        await second.replaceTools([Self.makeTool(name: "second_tool")])
        registry.invalidateCatalog(for: second)

        XCTAssertTrue(registry.isCurrent(firstRoute))
        XCTAssertFalse(registry.isCurrent(secondRoute))
        _ = await registry.awaitCurrentSnapshot()
    }

    func testUnregisterAndReregisterSameServiceCannotReviveOldRoute() async throws {
        let registry = MCPServiceRegistry()
        let service = MutableToolService(tools: [Self.makeTool(name: "revision_one")])
        registry.register(service)
        let firstSnapshot = await registry.awaitCurrentSnapshot()
        let oldRoute = try XCTUnwrap(firstSnapshot.routes(forCanonicalName: "revision_one").first)

        registry.unregister(service)
        await service.replaceTools([Self.makeTool(name: "revision_two")])
        registry.register(service)
        let secondSnapshot = await registry.awaitCurrentSnapshot()

        XCTAssertFalse(registry.isCurrent(oldRoute))
        XCTAssertEqual(secondSnapshot.routes(forCanonicalName: "revision_two").count, 1)
    }

    func testRegistrySourceKeepsGenerationGate() throws {
        let source = try String(
            contentsOf: RepoRoot.url().appendingPathComponent("Sources/RepoPrompt/Infrastructure/MCP/ServiceRegistry.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("guard boundary.generation == requestedGeneration"))
        XCTAssertTrue(source.contains("isCurrent(serviceIdentity: route.serviceIdentity, catalogRevision: route.catalogRevision)"))
        XCTAssertTrue(source.contains("nextCatalogRevision &+= 1"))
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

private actor MutableToolService: Service {
    private var storedTools: [Tool]

    init(tools: [Tool]) {
        storedTools = tools
    }

    var tools: [Tool] {
        get async { storedTools }
    }

    func replaceTools(_ tools: [Tool]) {
        storedTools = tools
    }
}

private final class BarrierToolService: Service {
    let storedTools: [Tool]
    let gate: CatalogBarrier

    init(tools: [Tool], gate: CatalogBarrier) {
        storedTools = tools
        self.gate = gate
    }

    var tools: [Tool] {
        get async {
            await gate.wait()
            return storedTools
        }
    }
}

private actor CatalogBarrier {
    private var startedCount = 0
    private var released = false
    private var startedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        startedCount += 1
        let ready = startedWaiters.filter { startedCount >= $0.count }
        startedWaiters.removeAll { startedCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStartedCount(_ count: Int) async {
        guard startedCount < count else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append((count, continuation))
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor CompletionSignal {
    private var marked = false

    func mark() {
        marked = true
    }

    func isMarked() -> Bool {
        marked
    }
}
