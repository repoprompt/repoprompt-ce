import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceReadSelectionMirrorTests: XCTestCase {
        func testFocusChangeDuringMirrorPreservesIdentityAndCancellation() async throws {
            enum Transition: CaseIterable {
                case background, backgroundSelectionChanged, activeSelectionABA, removed, cancelled

                var expected: WorkspaceSelectionCoordinator.SelectionMirrorOutcome {
                    switch self {
                    case .background, .backgroundSelectionChanged, .activeSelectionABA: .converged
                    case .removed: .invalidated
                    case .cancelled: .cancelled
                    }
                }
            }

            for transition in Transition.allCases {
                try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                    let manager = try XCTUnwrap(fixture.manager)
                    let original = try XCTUnwrap(manager.activeWorkspace?.activeComposeTabID)
                    let created = await manager.promptViewModel.createBackgroundComposeTab(strategy: .blank, name: "Other")
                    let other = try XCTUnwrap(created)
                    await manager.debugDrainScheduledSaves()
                    try await fixture.settle()
                    let identity = WorkspaceSelectionIdentity(workspaceID: fixture.workspace.id, tabID: original)
                    let selection = StoredSelection(selectedPaths: [fixture.rootPaths[0] + "/README.md"])
                    var tab = try XCTUnwrap(manager.composeTab(for: identity))
                    tab.selection = selection
                    XCTAssertTrue(manager.updateComposeTabStoredOnly(tab, inWorkspaceID: identity.workspaceID))
                    let coordinator = WorkspaceSelectionCoordinator(workspaceManager: manager, store: fixture.files.workspaceFileContextStore)
                    manager.attachSelectionCoordinator(coordinator)
                    let before = fixture.files.snapshotSelection()
                    let gate = fixture.makeGate()
                    let entered = XCTestExpectation(description: "physical mirror entered")
                    manager.selectionMirrorWillApply = {
                        manager.selectionMirrorWillApply = nil
                        entered.fulfill()
                        await gate.wait()
                    }
                    defer { manager.selectionMirrorWillApply = nil }
                    let mirror = Task { await manager.applyStoredSelectionMirrorForReadFileAutoSelection(for: identity) }
                    do {
                        try await fixture.awaitGateEvent(entered)
                        let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == identity.workspaceID })
                        var expectedSelection = selection
                        if transition != .activeSelectionABA {
                            manager.workspaces[index].activeComposeTabID = other.id
                        }
                        switch transition {
                        case .background: break
                        case .backgroundSelectionChanged, .activeSelectionABA:
                            tab.selection = StoredSelection(selectedPaths: [fixture.rootPaths[1] + "/README.md"])
                            XCTAssertTrue(manager.updateComposeTabStoredOnly(tab, inWorkspaceID: identity.workspaceID))
                            if transition == .activeSelectionABA {
                                tab.selection = selection
                                XCTAssertTrue(manager.updateComposeTabStoredOnly(tab, inWorkspaceID: identity.workspaceID))
                            }
                            expectedSelection = tab.selection
                        case .removed:
                            manager.workspaces[index].composeTabs.removeAll { $0.id == original }
                        case .cancelled:
                            mirror.cancel()
                        }
                        gate.release()
                        let result = await mirror.value
                        try await fixture.perform("physical mirror cleanup") {
                            while coordinator.selectionMirrorDebugSnapshot().activePhysicalWorkerCount != 0 {
                                try Task.checkCancellation()
                                await Task.yield()
                            }
                        }
                        XCTAssertEqual(result, transition.expected, "\(transition)")
                        if transition == .activeSelectionABA {
                            XCTAssertEqual(Set(fixture.files.selectedFiles.map(\.fullPath)), Set(selection.selectedPaths))
                        } else {
                            XCTAssertEqual(fixture.files.snapshotSelection(), before, "\(transition)")
                        }
                        if transition != .removed {
                            XCTAssertEqual(manager.composeTab(for: identity)?.selection, expectedSelection, "\(transition)")
                        }
                    } catch {
                        mirror.cancel()
                        gate.release()
                        _ = await mirror.value
                        throw error
                    }
                    withExtendedLifetime(coordinator) {}
                }
            }
        }
    }
#endif
