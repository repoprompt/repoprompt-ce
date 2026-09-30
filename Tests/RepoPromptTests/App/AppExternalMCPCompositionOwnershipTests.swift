import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AppExternalMCPCompositionOwnershipTests: XCTestCase {
    func testTwoWindowsReceiveTheSameAppOwnedFigmaGraph() async {
        let graph = FigmaMCPTestGraph.make()
        let first = WindowState(externalMCPComposition: graph)
        let second = WindowState(externalMCPComposition: graph)
        XCTAssertIdentical(first.externalMCPComposition, second.externalMCPComposition)
        XCTAssertIdentical(first.figmaMCPIntegrationCoordinator, graph.figmaCoordinator)
        XCTAssertIdentical(second.figmaMCPIntegrationCoordinator, graph.figmaCoordinator)
        XCTAssertIdentical(
            first.figmaMCPIntegrationCoordinator.runtimeAvailabilityAuthority,
            second.figmaMCPIntegrationCoordinator.runtimeAvailabilityAuthority
        )
        await first.tearDown()
        await second.tearDown()
    }

    func testSeparateGraphsDoNotShareAuthorityTerminalSessionsOrCursorObserver() {
        let first = FigmaMCPTestGraph.make()
        let second = FigmaMCPTestGraph.make()
        XCTAssertFalse(first.figmaCoordinator === second.figmaCoordinator)
        XCTAssertFalse(
            first.figmaCoordinator.runtimeAvailabilityAuthority
                === second.figmaCoordinator.runtimeAvailabilityAuthority
        )
        XCTAssertFalse(first.terminalSessionController === second.terminalSessionController)
        XCTAssertFalse(
            (first.cursorToolSurfaceObserver as AnyObject)
                === (second.cursorToolSurfaceObserver as AnyObject)
        )
    }

    func testInjectedRegistryAndConnectionCoordinatorRemainTheGraphOverrides() {
        let registry = ExternalMCPAdapterRegistry()
        let sessions = FigmaMCPProviderTerminalHandoff.SessionController(closeRunner: { _ in })
        let connection = FigmaMCPProviderConnectionCoordinator(
            registry: registry,
            sessionController: sessions
        )
        let graph = FigmaMCPTestGraph.make(
            registry: registry,
            providerConnectionCoordinator: connection,
            terminalSessionController: sessions
        )
        XCTAssertIdentical(graph.figmaProviderConnectionCoordinator, connection)
        XCTAssertIdentical(graph.terminalSessionController, sessions)
        XCTAssertTrue(graph.registry.registeredProviders.isEmpty)
    }
}
