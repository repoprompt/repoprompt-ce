import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

@MainActor
final class MCPAppRuntimeAdapterRegistryTests: XCTestCase {
    func testStagedMappingIsUnavailableUntilActivated() {
        let runtimeID = WorkspaceRuntimeID()
        let sessionID = WorkspaceSessionID()
        let adapter = makeAdapter()
        let registry = MCPAppRuntimeAdapterRegistry()
        let stageResult = registry.stage(
            windowID: 11,
            runtimeID: runtimeID,
            sessionID: sessionID,
            authoritativeSnapshot: makeSnapshot(sessionID: sessionID, sequence: 1),
            adapter: adapter
        )
        guard case let .staged(ticket) = stageResult else {
            return XCTFail("Expected staged mapping, got \(stageResult)")
        }

        XCTAssertNil(registry.routingSnapshot(windowID: 11))
        XCTAssertTrue(registry.latestRoutingTableSnapshot.mappings.isEmpty)
        XCTAssertEqual(registry.activate(ticket: ticket), .activated(ticket))
        XCTAssertEqual(registry.routingSnapshot(windowID: 11)?.ticket, ticket)
        XCTAssertTrue(registry.adapter(for: ticket) === adapter)
    }

    func testRoutingTableSnapshotsRemainImmutableAcrossNewerPublication() {
        let runtimeID = WorkspaceRuntimeID()
        let sessionID = WorkspaceSessionID()
        let adapter = makeAdapter()
        let registry = MCPAppRuntimeAdapterRegistry()
        let staged = registry.stage(
            windowID: 7,
            runtimeID: runtimeID,
            sessionID: sessionID,
            authoritativeSnapshot: makeSnapshot(
                sessionID: sessionID,
                sequence: 4,
                workspaceName: "Before",
                rootPaths: ["/logical/b", "/logical/a"]
            ),
            adapter: adapter
        )
        guard case let .staged(ticket) = staged else {
            return XCTFail("Expected staged mapping")
        }
        _ = registry.activate(ticket: ticket)
        let before = registry.latestRoutingTableSnapshot

        let stale = registry.updateSnapshot(
            runtimeID: runtimeID,
            sessionID: sessionID,
            authoritativeSnapshot: makeSnapshot(sessionID: sessionID, sequence: 4, workspaceName: "Ignored")
        )
        XCTAssertEqual(stale, .ignoredStaleOrDuplicate)

        let updated = registry.updateSnapshot(
            runtimeID: runtimeID,
            sessionID: sessionID,
            authoritativeSnapshot: makeSnapshot(
                sessionID: sessionID,
                sequence: 5,
                workspaceName: "After",
                rootPaths: ["/logical/a"]
            )
        )
        guard case let .updated(updatedTicket) = updated else {
            return XCTFail("Expected a newer snapshot to publish, got \(updated)")
        }
        let after = registry.latestRoutingTableSnapshot

        XCTAssertEqual(before.mapping(windowID: 7)?.authoritativeSnapshotSequence, 4)
        XCTAssertEqual(before.mapping(windowID: 7)?.workspaces.first?.name, "Before")
        XCTAssertEqual(before.mapping(windowID: 7)?.workspaces.first?.orderedRootPaths, ["/logical/b", "/logical/a"])
        XCTAssertEqual(before.mapping(windowID: 7)?.workspaces.first?.isSystemWorkspace, true)
        XCTAssertEqual(before.mapping(windowID: 7)?.workspaces.first?.isHiddenInMenus, true)
        XCTAssertEqual(
            before.mapping(windowID: 7)?.workspaces.first?.activeComposeTabID,
            before.mapping(windowID: 7)?.workspaces.first?.composeTabs.first?.id
        )
        XCTAssertEqual(after.mapping(windowID: 7)?.authoritativeSnapshotSequence, 5)
        XCTAssertEqual(after.mapping(windowID: 7)?.workspaces.first?.name, "After")
        XCTAssertGreaterThan(after.publicationSequence, before.publicationSequence)
        XCTAssertNil(registry.adapter(for: ticket), "A ticket fenced by an older authoritative sequence must be stale")
        XCTAssertTrue(registry.adapter(for: updatedTicket) === adapter)
    }

    func testReplacementRequiresClosingAndNeverRetargetsOldTicket() throws {
        let oldRuntimeID = WorkspaceRuntimeID()
        let newRuntimeID = WorkspaceRuntimeID()
        let oldSessionID = WorkspaceSessionID()
        let newSessionID = WorkspaceSessionID()
        let oldAdapter = makeAdapter()
        let newAdapter = makeAdapter()
        let registry = MCPAppRuntimeAdapterRegistry()

        guard case let .staged(oldTicket) = registry.stage(
            windowID: 3,
            runtimeID: oldRuntimeID,
            sessionID: oldSessionID,
            authoritativeSnapshot: makeSnapshot(sessionID: oldSessionID, sequence: 1),
            adapter: oldAdapter
        ) else {
            return XCTFail("Expected old mapping to stage")
        }
        _ = registry.activate(ticket: oldTicket)
        let admittedRoutingSnapshot = try XCTUnwrap(registry.routingSnapshot(windowID: 3))

        XCTAssertEqual(registry.stage(
            windowID: 3,
            runtimeID: newRuntimeID,
            sessionID: newSessionID,
            authoritativeSnapshot: makeSnapshot(sessionID: newSessionID, sequence: 1),
            adapter: newAdapter
        ), .windowOccupied)

        XCTAssertEqual(registry.beginClosing(ticket: oldTicket), .closing)
        XCTAssertEqual(registry.stage(
            windowID: 3,
            runtimeID: newRuntimeID,
            sessionID: newSessionID,
            authoritativeSnapshot: makeSnapshot(sessionID: newSessionID, sequence: 1),
            adapter: newAdapter
        ), .predecessorNotDraining)
        registry.confirmRuntimeDraining(runtimeID: oldRuntimeID)
        guard case let .staged(newTicket) = registry.stage(
            windowID: 3,
            runtimeID: newRuntimeID,
            sessionID: newSessionID,
            authoritativeSnapshot: makeSnapshot(sessionID: newSessionID, sequence: 1),
            adapter: newAdapter
        ) else {
            return XCTFail("Expected replacement mapping to stage after the predecessor closed")
        }
        _ = registry.activate(ticket: newTicket)

        XCTAssertEqual(admittedRoutingSnapshot.runtimeID, oldRuntimeID)
        XCTAssertEqual(admittedRoutingSnapshot.ticket, oldTicket)
        XCTAssertNil(registry.adapter(for: oldTicket))
        XCTAssertTrue(registry.adapter(for: newTicket) === newAdapter)
        XCTAssertEqual(registry.routingSnapshot(windowID: 3)?.runtimeID, newRuntimeID)
        XCTAssertGreaterThan(newTicket.mappingGeneration, oldTicket.mappingGeneration)
    }

    func testWeakAdapterLossClosesMappingAndRequestsExactRuntimeDrain() async throws {
        let runtimeID = WorkspaceRuntimeID()
        let sessionID = WorkspaceSessionID()
        var lostRuntimeIDs: [WorkspaceRuntimeID] = []
        let registry = MCPAppRuntimeAdapterRegistry { lostRuntimeIDs.append($0) }
        var adapter: MCPWindowRuntimeAdapter? = makeAdapter()
        weak var weakAdapter = adapter
        guard case let .staged(ticket) = try registry.stage(
            windowID: 5,
            runtimeID: runtimeID,
            sessionID: sessionID,
            authoritativeSnapshot: makeSnapshot(sessionID: sessionID, sequence: 1),
            adapter: XCTUnwrap(adapter)
        ) else {
            return XCTFail("Expected mapping to stage")
        }
        _ = registry.activate(ticket: ticket)

        adapter = nil
        XCTAssertNil(weakAdapter, "The registry must not retain the UI adapter")
        for _ in 0 ..< 20 where lostRuntimeIDs.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(lostRuntimeIDs, [runtimeID])
        XCTAssertEqual(registry.publicationState(runtimeID: runtimeID), .closing)
        XCTAssertNil(registry.routingSnapshot(windowID: 5))
        XCTAssertNil(registry.adapter(for: ticket))
        XCTAssertTrue(registry.latestRoutingTableSnapshot.mappings.isEmpty)
    }

    private func makeAdapter() -> MCPWindowRuntimeAdapter {
        MCPWindowRuntimeAdapter(windowState: nil, serverViewModel: nil)
    }

    private func makeSnapshot(
        sessionID: WorkspaceSessionID,
        sequence: UInt64,
        workspaceName: String = "Workspace",
        rootPaths: [String] = ["/logical/root"]
    ) -> WorkspaceSessionSnapshot {
        let tab = ComposeTabState(name: "Routing tab")
        let workspace = WorkspaceModel(
            name: workspaceName,
            repoPaths: rootPaths,
            isSystemWorkspace: true,
            isHiddenInMenus: true,
            composeTabs: [tab],
            activeComposeTabID: tab.id
        )
        return WorkspaceSessionSnapshot(
            sessionID: sessionID,
            snapshotSequence: sequence,
            stateGeneration: sequence,
            workspaces: [workspace],
            activeWorkspaceID: workspace.id,
            selectionRevisions: [:],
            dirtyGenerations: [workspace.id: 0],
            savedGenerations: [workspace.id: 0],
            switchState: .idle,
            readiness: WorkspaceSessionReadiness(generation: sequence, isReady: true),
            availability: .active
        )
    }
}
