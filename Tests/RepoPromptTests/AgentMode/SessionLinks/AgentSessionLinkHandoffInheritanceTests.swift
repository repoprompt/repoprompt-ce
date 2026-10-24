import Foundation
import RepoPromptSettingsCore
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

            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                // The source may also persist an adopted default; only the child's save fences inheritance.
                guard session.id != fixture.sourceSession.activeAgentSessionID else {
                    return fixture.rootURL.appendingPathComponent("source-session.json")
                }
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

    func testHandoffSaveFailureRetainsBlockedDestinationUntilExplicitRetry() async throws {
        enum ExpectedSaveFailure: Error { case failed }

        try await withFixture { fixture in
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            var inheritanceWasCalled = false
            var failedSaveSessionIDs: [UUID] = []

            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                failedSaveSessionIDs.append(session.id)
                throw ExpectedSaveFailure.failed
            }
            fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { _, _ in
                inheritanceWasCalled = true
                return .empty
            }

            var partialFailure: SessionAdminPartialForkError?
            do {
                _ = try await fixture.viewModel.prepareHandoffToNewTab(
                    upToItemID: cutoffItemID,
                    destinationAgent: fixture.sourceSession.selectedAgent,
                    destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                    destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
                )
                XCTFail("An unacknowledged first save must not report a completed Handoff.")
            } catch let failure as SessionAdminPartialForkError {
                partialFailure = failure
            }
            let failure = try XCTUnwrap(partialFailure)
            XCTAssertEqual(failure.code, "persist_failed")
            let destination = try XCTUnwrap(fixture.viewModel.sessions.values.first {
                $0.activeAgentSessionID == failure.sessionID
            })
            XCTAssertNotEqual(destination.tabID, fixture.sourceTabID)
            XCTAssertEqual(failedSaveSessionIDs.filter { $0 == failure.sessionID }, [failure.sessionID])
            XCTAssertEqual(
                fixture.window.workspaceManager.activeAgentSessionID(forTabID: destination.tabID),
                failure.sessionID
            )
            XCTAssertFalse(inheritanceWasCalled)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.sourceTabID)
            XCTAssertTrue(destination.qualifiedRestorationReadiness.isCreating)
            XCTAssertFalse(destination.permitsBoundOperationAndSave)
            XCTAssertNotNil(destination.operationAdmissionFailureMessage)
            XCTAssertNil(destination.saveDebounceTask, "Generic autosave cannot complete a failed configured creation.")
            let retry = try XCTUnwrap(fixture.viewModel.captureSessionCreationRetry(for: destination))
            XCTAssertTrue(retry.session === destination)
            XCTAssertEqual(retry.bindingToken.bindingIdentity.sessionID, failure.sessionID)
            XCTAssertEqual(retry.bindingToken, destination.currentRestorationBindingToken)
            XCTAssertNotNil(retry.expectedConfigurationStamp)

            let workspaceID = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspaceID)
            let genericSave = await fixture.viewModel.flushSaveRequired(for: destination.tabID, workspaceID: workspaceID)
            guard case .failure = genericSave else {
                return XCTFail("Only the captured creation owner may retry its configured first save.")
            }
            XCTAssertEqual(failedSaveSessionIDs.filter { $0 == failure.sessionID }, [failure.sessionID])
            let retryFile = fixture.rootURL.appendingPathComponent("handoff-retry.json")
            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                guard session.id != fixture.sourceSession.activeAgentSessionID else {
                    return fixture.rootURL.appendingPathComponent("source-session.json")
                }
                XCTAssertEqual(session.id, failure.sessionID)
                try JSONEncoder().encode(session).write(to: retryFile, options: .atomic)
                return retryFile
            }
            let retried = await fixture.viewModel.retrySessionInitialSave(retry)
            XCTAssertTrue(retried)
            let saved = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: retryFile))
            XCTAssertEqual(saved.id, failure.sessionID)
            XCTAssertEqual(saved.composeTabID, destination.tabID)
            XCTAssertEqual(saved.toLiveItems().map(\.text), destination.items.map(\.text))
            XCTAssertEqual(destination.qualifiedRestorationReadiness, .authoritative(retry.bindingToken, .freshBindingDurablyCreated))
            XCTAssertNil(fixture.viewModel.captureSessionCreationRetry(for: destination))
            XCTAssertFalse(inheritanceWasCalled, "Retrying persistence cannot manufacture oversight grants.")
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.sourceTabID)
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
            window.workspaceManager.workspaces[workspaceIndex].customStoragePath = rootURL.appendingPathComponent("sessions", isDirectory: true)
            let persistedSource = AgentSession(
                id: sourceSessionID,
                workspaceID: activeWorkspace.id,
                composeTabID: sourceTabID,
                name: "Source",
                items: [
                    AgentChatItemPersist(from: .user("Source user", sequenceIndex: 0)),
                    AgentChatItemPersist(from: .assistant("Source assistant", sequenceIndex: 1))
                ],
                autoEditEnabled: false
            )
            _ = try await AgentSessionDataService.shared.saveAgentSession(
                persistedSource, for: window.workspaceManager.workspaces[workspaceIndex]
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [sourceTab]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = sourceTabID
            window.promptManager.loadComposeTabsFromWorkspace(
                window.workspaceManager.workspaces[workspaceIndex],
                syncPromptText: true
            )

            let viewModel = window.agentModeViewModel
            let sourceSession = await viewModel.ensureSessionReady(tabID: sourceTabID)
            XCTAssertEqual(sourceSession.activeAgentSessionID, sourceSessionID)
            XCTAssertEqual(
                window.workspaceManager.activeAgentSessionID(forTabID: sourceTabID),
                sourceSessionID
            )
            let sourceToken = try XCTUnwrap(
                sourceSession.permitsBoundOperationAndSave ? sourceSession.currentRestorationBindingToken : nil,
                "Handoff requires a restored source payload."
            )
            XCTAssertEqual(sourceSession.qualifiedRestorationReadiness, .authoritative(sourceToken, .persistedPayloadApplied))
            XCTAssertEqual(sourceSession.items.count, 2)
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
