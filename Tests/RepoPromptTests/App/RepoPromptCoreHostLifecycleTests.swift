@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

@MainActor
final class RepoPromptCoreHostLifecycleTests: XCTestCase {
    func testSessionLifecycleActivatesDrainsAndRetiresRoutingID() {
        let registry = MCPRuntimeSessionRegistry()
        let graph = EmbeddedWorkspaceRepositoryFactory.make()
        let host = RepoPromptCoreHost(
            workspaceRepository: graph.repository,
            workspacePersistenceWriter: graph.writer,
            workspaceAccessPolicy: UnrestrictedWorkspaceAccessPolicy(),
            runtimeSessionRegistry: registry,
            runtimeFactory: RepoPromptEmbeddedWorkspaceRuntimeFactory()
        )
        let handle = host.makeEmbeddedSession(routingSessionID: MCPRoutingSessionID(rawValue: 42))

        XCTAssertEqual(handle.snapshot.lifecycle, .created)
        XCTAssertFalse(registry.hasActiveWindow(id: 42))

        registry.setMCPEnabled(windowID: 42, enabled: true)
        XCTAssertTrue(host.activate(handle))
        XCTAssertEqual(handle.snapshot.lifecycle, .active)
        XCTAssertTrue(registry.isInvocationAllowed(windowID: 42))

        host.beginDraining(handle)
        host.beginDraining(handle)
        XCTAssertEqual(handle.snapshot.lifecycle, .draining)
        XCTAssertFalse(registry.isInvocationAllowed(windowID: 42))

        host.remove(handle)
        host.remove(handle)
        XCTAssertEqual(handle.snapshot.lifecycle, .removed)
        XCTAssertFalse(registry.hasActiveWindow(id: 42))
        #if DEBUG
            XCTAssertTrue(registry.debugIsRetired(windowID: 42))
        #endif
    }

    func testDuplicateRoutingIDActivationIsRejectedAndCannotTeardownOwner() {
        let registry = MCPRuntimeSessionRegistry()
        let graph = EmbeddedWorkspaceRepositoryFactory.make()
        let host = RepoPromptCoreHost(
            workspaceRepository: graph.repository,
            workspacePersistenceWriter: graph.writer,
            workspaceAccessPolicy: UnrestrictedWorkspaceAccessPolicy(),
            runtimeSessionRegistry: registry,
            runtimeFactory: RepoPromptEmbeddedWorkspaceRuntimeFactory()
        )
        let owner = host.makeEmbeddedSession(routingSessionID: MCPRoutingSessionID(rawValue: 84))
        let duplicate = host.makeEmbeddedSession(routingSessionID: MCPRoutingSessionID(rawValue: 84))

        registry.setMCPEnabled(windowID: 84, enabled: true)
        XCTAssertTrue(host.activate(owner))
        XCTAssertFalse(host.activate(duplicate))
        XCTAssertEqual(duplicate.snapshot.lifecycle, .created)
        XCTAssertTrue(registry.isInvocationAllowed(windowID: 84))

        host.beginDraining(duplicate)
        host.remove(duplicate)
        XCTAssertEqual(duplicate.snapshot.lifecycle, .removed)
        XCTAssertEqual(owner.snapshot.lifecycle, .active)
        XCTAssertTrue(registry.isInvocationAllowed(windowID: 84))

        host.beginDraining(owner)
        host.remove(owner)
        XCTAssertFalse(registry.hasActiveWindow(id: 84))
        #if DEBUG
            XCTAssertTrue(registry.debugIsRetired(windowID: 84))
        #endif
    }

    func testDetachedWorkspaceSessionControllerReturnsNoBindingCandidates() {
        let graph = EmbeddedWorkspaceRepositoryFactory.make()
        let controller = WorkspaceSessionController(
            repository: graph.repository,
            persistenceWriter: graph.writer,
            accessPolicy: UnrestrictedWorkspaceAccessPolicy()
        )

        XCTAssertNil(controller.activeWorkspace)
        XCTAssertNil(controller.bindingCandidate(forContextID: UUID()))
        XCTAssertTrue(controller.bindingCandidates(matchingWorkingDirs: ["/tmp"]).isEmpty)
    }
}
