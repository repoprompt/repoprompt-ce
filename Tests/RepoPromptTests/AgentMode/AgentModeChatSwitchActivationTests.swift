import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class AgentModeChatSwitchActivationTests: XCTestCase {
    func testHandoffRebindsComposerAndRejectsStaleSourceSubmitTarget() async throws {
        try await withFixture { fixture in
            let sourceTarget = try XCTUnwrap(fixture.viewModel.ui.composer.props.submitTarget)
            XCTAssertEqual(sourceTarget.tabID, fixture.tabAID)
            let cutoffItemID = try XCTUnwrap(fixture.sessionA.items.last?.id)

            let destinationTabID = try await fixture.viewModel.prepareHandoffToNewTab(
                upToItemID: cutoffItemID,
                destinationAgent: fixture.sessionA.selectedAgent,
                destinationModelRaw: fixture.sessionA.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sessionA.selectedReasoningEffortRaw
            )

            let destinationSession = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            let destinationSessionID = try XCTUnwrap(destinationSession.activeAgentSessionID)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, destinationTabID)
            XCTAssertEqual(fixture.window.workspaceManager.activeAgentSessionID(forTabID: destinationTabID), destinationSessionID)
            XCTAssertNotEqual(destinationSessionID, fixture.sessionAID)
            XCTAssertEqual(destinationSession.items.map(\.text), fixture.tabATexts)
            XCTAssertTrue(destinationSession.pendingHandoff.hasPayload)
            XCTAssertEqual(destinationSession.pendingHandoff.sourceItemID, cutoffItemID)

            let composerProps = fixture.viewModel.ui.composer.props
            XCTAssertEqual(composerProps.currentTabID, destinationTabID)
            let destinationTarget = try XCTUnwrap(composerProps.submitTarget)
            XCTAssertEqual(destinationTarget.tabID, destinationTabID)
            XCTAssertEqual(destinationTarget.expectedSourceAgentSessionID, destinationSessionID)
            XCTAssertEqual(
                destinationTarget.expectedSourceTabSessionIdentity,
                ObjectIdentifier(destinationSession)
            )

            let staleAttempt = AgentComposerSubmitAttempt(
                id: UUID(),
                target: sourceTarget,
                inputRevision: 0,
                noticeRevision: 0,
                rawDraftSnapshot: "must not reach the source"
            )
            switch fixture.viewModel.claimComposerSubmitAttempt(staleAttempt) {
            case .claimed:
                XCTFail("The source composer target must not survive destination activation")
            case let .rejected(rejection):
                XCTAssertEqual(
                    rejection,
                    .targetRejected(reason: "inactive_composer_tab")
                )
            }
            XCTAssertNil(fixture.sessionA.activeComposerSubmitAttempt)
            XCTAssertEqual(fixture.viewModel.ui.composer.props.currentTabID, destinationTabID)

            let destinationAttempt = try AgentComposerSubmitAttempt(
                id: UUID(),
                target: XCTUnwrap(fixture.viewModel.ui.composer.props.submitTarget),
                inputRevision: 0,
                noticeRevision: 0,
                rawDraftSnapshot: "destination draft"
            )
            let destinationClaim: AgentModeViewModel.AgentComposerSubmitClaim
            switch fixture.viewModel.claimComposerSubmitAttempt(destinationAttempt) {
            case let .claimed(claim):
                destinationClaim = claim
            case let .rejected(rejection):
                return XCTFail("Expected destination composer recovery, got \(rejection)")
            }
            XCTAssertTrue(fixture.viewModel.releaseComposerSubmitClaim(destinationClaim))
            XCTAssertNotNil(fixture.viewModel.ui.composer.props.submitTarget)
        }
    }

    func testWarmSwitchPublishesDestinationTranscriptBeforeSwitchReturns() async throws {
        try await withFixture { fixture in
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabAID,
                sessionID: fixture.sessionAID,
                session: fixture.sessionA,
                expectedTexts: fixture.tabATexts
            )

            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)

            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.tabBID)
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabBID,
                sessionID: fixture.sessionBID,
                session: fixture.sessionB,
                expectedTexts: fixture.tabBTexts
            )
            XCTAssertNil(fixture.viewModel.activeSessionLoadInProgressTabID)
        }
    }

    func testBackToBackWarmSwitchesPublishLatestDestination() async throws {
        try await withFixture { fixture in
            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabBID,
                sessionID: fixture.sessionBID,
                session: fixture.sessionB,
                expectedTexts: fixture.tabBTexts
            )

            await fixture.window.promptManager.switchComposeTab(fixture.tabAID)

            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.tabAID)
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabAID,
                sessionID: fixture.sessionAID,
                session: fixture.sessionA,
                expectedTexts: fixture.tabATexts
            )
            XCTAssertNil(fixture.viewModel.activeSessionLoadInProgressTabID)
        }
    }

    func testWarmSwitchNotificationIsWindowScoped() async throws {
        try await withFixture { fixtureA in
            let initialPresentation = fixtureA.viewModel.activeTranscriptPresentation

            try await withFixture { fixtureB in
                XCTAssertEqual(fixtureA.viewModel.activeTranscriptPresentation, initialPresentation)

                await fixtureB.window.promptManager.switchComposeTab(fixtureB.tabBID)

                XCTAssertEqual(fixtureB.window.promptManager.activeComposeTabID, fixtureB.tabBID)
                assertPresentation(
                    fixtureB.viewModel.activeTranscriptPresentation,
                    tabID: fixtureB.tabBID,
                    sessionID: fixtureB.sessionBID,
                    session: fixtureB.sessionB,
                    expectedTexts: fixtureB.tabBTexts
                )
                XCTAssertEqual(fixtureA.window.promptManager.activeComposeTabID, fixtureA.tabAID)
                XCTAssertEqual(fixtureA.viewModel.activeTranscriptPresentation, initialPresentation)
                XCTAssertNil(fixtureA.viewModel.activeSessionLoadInProgressTabID)
            }
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
            .appendingPathComponent("AgentModeChatSwitchActivationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Agent Mode Chat Switch \(UUID().uuidString.prefix(8))",
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "agentModeChatSwitchActivationTests"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            XCTAssertEqual(activeWorkspace.id, workspace.id)

            let tabAID = UUID()
            let tabBID = UUID()
            let sessionAID = UUID()
            let sessionBID = UUID()
            let tabA = ComposeTabState(id: tabAID, name: "A", activeAgentSessionID: sessionAID)
            let tabB = ComposeTabState(id: tabBID, name: "B", activeAgentSessionID: sessionBID)

            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id })
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [tabA, tabB]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabAID
            window.promptManager.loadComposeTabsFromWorkspace(
                window.workspaceManager.workspaces[workspaceIndex],
                syncPromptText: true
            )

            let viewModel = window.agentModeViewModel
            let sessionA = viewModel.session(for: tabAID)
            let sessionB = viewModel.session(for: tabBID)
            XCTAssertEqual(sessionA.activeAgentSessionID, sessionAID)
            XCTAssertEqual(sessionB.activeAgentSessionID, sessionBID)
            XCTAssertEqual(window.workspaceManager.activeAgentSessionID(forTabID: tabAID), sessionAID)
            XCTAssertEqual(window.workspaceManager.activeAgentSessionID(forTabID: tabBID), sessionBID)

            let tabATexts = ["A user", "A assistant"]
            let tabBTexts = ["B user", "B assistant"]
            sessionA.hasLoadedPersistedState = true
            sessionA.setItemsSilently(
                [
                    .user(tabATexts[0], sequenceIndex: 0),
                    .assistant(tabATexts[1], sequenceIndex: 1)
                ],
                reason: .testOverride
            )
            viewModel.refreshDerivedTranscriptState(for: sessionA)

            sessionB.hasLoadedPersistedState = true
            sessionB.setItemsSilently(
                [
                    .user(tabBTexts[0], sequenceIndex: 0),
                    .assistant(tabBTexts[1], sequenceIndex: 1)
                ],
                reason: .testOverride
            )
            viewModel.refreshDerivedTranscriptState(for: sessionB)

            viewModel.setAgentModeActive(true)

            return Fixture(
                window: window,
                rootURL: rootURL,
                viewModel: viewModel,
                tabAID: tabAID,
                tabBID: tabBID,
                sessionAID: sessionAID,
                sessionBID: sessionBID,
                sessionA: sessionA,
                sessionB: sessionB,
                tabATexts: tabATexts,
                tabBTexts: tabBTexts
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

    private func assertPresentation(
        _ presentation: AgentTranscriptPresentationSnapshot,
        tabID: UUID,
        sessionID: UUID,
        session: AgentModeViewModel.TabSession,
        expectedTexts: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(presentation.tabID, tabID, file: file, line: line)
        XCTAssertTrue(presentation.bindingsHydrated, file: file, line: line)
        XCTAssertEqual(presentation.hydratedPersistentBinding?.tabID, tabID, file: file, line: line)
        XCTAssertEqual(presentation.hydratedPersistentBinding?.sessionID, sessionID, file: file, line: line)
        XCTAssertEqual(
            presentation.hydratedBindingTransitionGeneration,
            session.bindingTransitionGeneration,
            file: file,
            line: line
        )
        XCTAssertEqual(presentation.visibleRows.map(\.text), expectedTexts, file: file, line: line)
        XCTAssertEqual(presentation.workingRows.map(\.text), expectedTexts, file: file, line: line)
    }

    private struct Fixture {
        let window: WindowState
        let rootURL: URL
        let viewModel: AgentModeViewModel
        let tabAID: UUID
        let tabBID: UUID
        let sessionAID: UUID
        let sessionBID: UUID
        let sessionA: AgentModeViewModel.TabSession
        let sessionB: AgentModeViewModel.TabSession
        let tabATexts: [String]
        let tabBTexts: [String]
    }
}
