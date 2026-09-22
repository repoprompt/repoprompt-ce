import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Handoff must not expose a child tab before the child is durable and its direct oversight grants
/// have been inherited. A failed first save remains recoverable, but cannot authorize inheritance.
@MainActor
final class AgentSessionLinkHandoffInheritanceTests: XCTestCase {
    func testHandoffDurablySavesBeforeInheritanceAndActivation() async throws {
        try await withFixture { fixture in
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            let parentEndpoint = try XCTUnwrap(
                fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.sourceTabID)
            )
            var events: [String] = []

            fixture.viewModel.test_setAgentSessionSaver { _, _, _ in
                XCTAssertEqual(
                    fixture.window.promptManager.activeComposeTabID,
                    fixture.sourceTabID,
                    "the child must remain inactive until its first durable save completes"
                )
                events.append("save")
                return fixture.rootURL.appendingPathComponent("handoff-session.json")
            }
            fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { parent, child in
                XCTAssertEqual(parent, parentEndpoint)
                XCTAssertNotEqual(child, parent)
                XCTAssertEqual(
                    fixture.window.promptManager.activeComposeTabID,
                    fixture.sourceTabID,
                    "inheritance must settle before child activation"
                )
                events.append("inherit")
                return .empty
            }

            let destinationTabID = try await fixture.viewModel.prepareHandoffToNewTab(
                upToItemID: cutoffItemID,
                destinationAgent: fixture.sourceSession.selectedAgent,
                destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
            )

            let destinationSession = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            let bindingToken = try XCTUnwrap(destinationSession.currentRestorationBindingToken)
            XCTAssertEqual(events, ["save", "inherit"])
            XCTAssertEqual(
                destinationSession.restorationReadiness,
                .authoritative(bindingToken, .freshBindingDurablyCreated)
            )
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, destinationTabID)
        }
    }

    func testHandoffSaveFailureSkipsInheritanceSchedulesRetryAndStillActivates() async throws {
        enum ExpectedSaveFailure: Error { case failed }

        try await withFixture { fixture in
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            var inheritanceWasCalled = false

            fixture.viewModel.test_setAgentSessionSaver { _, _, _ in
                throw ExpectedSaveFailure.failed
            }
            fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { _, _ in
                inheritanceWasCalled = true
                return .empty
            }

            let destinationTabID = try await fixture.viewModel.prepareHandoffToNewTab(
                upToItemID: cutoffItemID,
                destinationAgent: fixture.sourceSession.selectedAgent,
                destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
            )

            let destinationSession = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            XCTAssertFalse(inheritanceWasCalled)
            XCTAssertNotNil(
                destinationSession.saveDebounceTask,
                "the failed immediate save must schedule the existing deferred retry"
            )
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, destinationTabID)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await makeFixture()
        do {
            try await body(fixture)
        } catch {
            await cleanup(fixture)
            throw error
        }
        await cleanup(fixture)
    }

    private func makeFixture() async throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionLinkHandoffInheritanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Handoff inheritance \(UUID().uuidString.prefix(8))",
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "agentSessionLinkHandoffInheritanceTests"
            )

            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            let sourceTabID = UUID()
            let sourceSessionID = UUID()
            let sourceTab = ComposeTabState(
                id: sourceTabID,
                name: "Source",
                activeAgentSessionID: sourceSessionID
            )
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex(where: { $0.id == activeWorkspace.id })
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [sourceTab]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = sourceTabID
            window.promptManager.loadComposeTabsFromWorkspace(
                window.workspaceManager.workspaces[workspaceIndex],
                syncPromptText: true
            )

            let viewModel = window.agentModeViewModel
            let sourceSession = viewModel.session(for: sourceTabID)
            XCTAssertEqual(sourceSession.activeAgentSessionID, sourceSessionID)
            XCTAssertEqual(
                window.workspaceManager.activeAgentSessionID(forTabID: sourceTabID),
                sourceSessionID
            )
            sourceSession.hasLoadedPersistedState = true
            sourceSession.setItemsSilently(
                [
                    .user("Source user", sequenceIndex: 0),
                    .assistant("Source assistant", sequenceIndex: 1)
                ],
                reason: .testOverride
            )
            viewModel.refreshDerivedTranscriptState(for: sourceSession)
            viewModel.setAgentModeActive(true)

            return Fixture(
                window: window,
                rootURL: rootURL,
                viewModel: viewModel,
                sourceTabID: sourceTabID,
                sourceSession: sourceSession
            )
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    private func cleanup(_ fixture: Fixture) async {
        fixture.window.beginClose()
        await fixture.window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(fixture.window)
        try? FileManager.default.removeItem(at: fixture.rootURL)
    }

    private struct Fixture {
        let window: WindowState
        let rootURL: URL
        let viewModel: AgentModeViewModel
        let sourceTabID: UUID
        let sourceSession: AgentModeViewModel.TabSession
    }
}
