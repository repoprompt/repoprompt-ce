@testable import RepoPrompt
import XCTest

@MainActor
final class RepoPromptCoreHostLifecycleTests: XCTestCase {
    func testSessionLifecycleActivatesDrainsAndRetiresRoutingID() {
        let registry = MCPRuntimeSessionRegistry()
        let host = RepoPromptCoreHost(
            workspaceRepository: WorkspaceRepository(),
            workspaceAccessPolicy: UnrestrictedWorkspaceAccessPolicy(),
            runtimeSessionRegistry: registry,
            platformDependencies: MacOSRepoPromptCorePlatformDependencies.embeddedApp()
        )
        let handle = host.makeEmbeddedSession(routingSessionID: MCPRoutingSessionID(rawValue: 42))

        XCTAssertEqual(handle.snapshot.lifecycle, .created)
        XCTAssertFalse(registry.hasActiveWindow(id: 42))

        registry.setMCPEnabled(windowID: 42, enabled: true)
        host.activate(handle)
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

    func testDetachedWorkspaceSessionControllerReturnsNoBindingCandidates() {
        let controller = WorkspaceSessionController(accessPolicy: UnrestrictedWorkspaceAccessPolicy())

        XCTAssertNil(controller.activeWorkspace)
        XCTAssertNil(controller.bindingCandidate(forContextID: UUID()))
        XCTAssertTrue(controller.bindingCandidates(matchingWorkingDirs: ["/tmp"]).isEmpty)
    }
}
