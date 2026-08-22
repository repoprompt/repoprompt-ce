@testable import RepoPromptApp
import XCTest

@MainActor
final class BackgroundComposeTabAdmissionTests: XCTestCase {
    func testBackgroundCreationCrossesLegacyLimitWithoutMutatingExistingTabs() async throws {
        let fixture = makeFixture(initialTabCount: 499)
        let originalWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        let originalTabIDs = originalWorkspace.composeTabs.map(\.id)
        let originalSessionIDsByTabID = Dictionary(
            uniqueKeysWithValues: originalWorkspace.composeTabs.map { ($0.id, $0.activeAgentSessionID) }
        )
        let originalActiveTabID = try XCTUnwrap(originalWorkspace.activeComposeTabID)
        let originalStashedTabs = originalWorkspace.stashedTabs

        for expectedCount in 500 ... 502 {
            let created = await fixture.prompt.createBackgroundComposeTab(
                strategy: .blank,
                name: "Background \(expectedCount)"
            )

            XCTAssertNotNil(created, "Background creation should reach \(expectedCount) tabs")
            XCTAssertEqual(fixture.manager.activeWorkspace?.composeTabs.count, expectedCount)
        }

        let finalWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        let existingTabs = Array(finalWorkspace.composeTabs.prefix(originalTabIDs.count))
        XCTAssertEqual(existingTabs.map(\.id), originalTabIDs)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: existingTabs.map { ($0.id, $0.activeAgentSessionID) }),
            originalSessionIDsByTabID
        )
        XCTAssertEqual(finalWorkspace.activeComposeTabID, originalActiveTabID)
        XCTAssertEqual(finalWorkspace.stashedTabs, originalStashedTabs)
    }

    func testForegroundAgentCreationCrosses499Through502WithoutUnrelatedMutation() async throws {
        let fixture = makeFixture(initialTabCount: 499)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        let originalWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        let originalTabs = originalWorkspace.composeTabs
        let originalTabIDs = originalTabs.map(\.id)
        let originalPins = Dictionary(uniqueKeysWithValues: originalTabs.map { ($0.id, $0.isPinned) })
        let originalBindings = Dictionary(uniqueKeysWithValues: originalTabs.map { ($0.id, $0.activeAgentSessionID) })
        let originalStashedTabs = originalWorkspace.stashedTabs
        let originalDirtyTabIDs = Set(originalTabIDs.prefix(7))
        fixture.prompt.testSetDirtyTabIDs(originalDirtyTabIDs)

        let sideEffects = ComposeRemovalSideEffectRecorder()
        fixture.prompt.composeTabCascadeResolver = { tabIDs, _ in
            await sideEffects.recordCascade(tabIDs)
            return .init()
        }
        let closeToken = fixture.prompt.addComposeTabsWillCloseListener { tabIDs, _ in
            await sideEffects.recordClose(tabIDs)
        }
        defer { fixture.prompt.removeComposeTabsWillCloseListener(closeToken) }

        var createdIDs: [UUID] = []
        for expectedCount in 500 ... 502 {
            let creationResult = await viewModel.createAndActivateSessionTab()
            let createdID = try XCTUnwrap(creationResult)
            createdIDs.append(createdID)
            XCTAssertEqual(fixture.prompt.activeComposeTabID, createdID)
            XCTAssertEqual(fixture.manager.activeWorkspace?.activeComposeTabID, createdID)
            XCTAssertEqual(fixture.manager.activeWorkspace?.composeTabs.count, expectedCount)
            XCTAssertEqual(fixture.manager.composeTab(with: createdID)?.activeAgentSessionID, viewModel.sessions[createdID]?.activeAgentSessionID)
        }

        let finalWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        let existingTabs = Array(finalWorkspace.composeTabs.prefix(originalTabs.count))
        XCTAssertEqual(existingTabs.map(\.id), originalTabIDs)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: existingTabs.map { ($0.id, $0.isPinned) }), originalPins)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: existingTabs.map { ($0.id, $0.activeAgentSessionID) }), originalBindings)
        XCTAssertEqual(fixture.prompt.dirtyTabIDs.intersection(originalTabIDs), originalDirtyTabIDs)
        XCTAssertEqual(finalWorkspace.stashedTabs, originalStashedTabs)
        XCTAssertEqual(Array(finalWorkspace.composeTabs.suffix(createdIDs.count)).map(\.id), createdIDs)
        let recordedSideEffects = await sideEffects.snapshot()
        XCTAssertEqual(recordedSideEffects, .init())
    }

    func testFailedForegroundCreationDoesNotReturnOrMarkOldActiveTab() async throws {
        let fixture = makeFixture(initialTabCount: 1)
        let oldActiveTabID = try XCTUnwrap(fixture.prompt.activeComposeTabID)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        XCTAssertNil(viewModel.sessions[oldActiveTabID])

        fixture.manager.activeWorkspace = nil
        let createdID = await viewModel.createAndActivateSessionTab()

        XCTAssertNil(createdID)
        XCTAssertEqual(fixture.prompt.activeComposeTabID, oldActiveTabID)
        XCTAssertNil(viewModel.sessions[oldActiveTabID])
    }

    func testUnstashAboveFiftyRestoresRequestedTabWithoutUnrelatedMutation() async throws {
        let fixture = makeFixture(initialTabCount: 51)
        let originalWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        let originalTabs = originalWorkspace.composeTabs
        let originalIDs = originalTabs.map(\.id)
        let originalPins = Dictionary(uniqueKeysWithValues: originalTabs.map { ($0.id, $0.isPinned) })
        let originalBindings = Dictionary(uniqueKeysWithValues: originalTabs.map { ($0.id, $0.activeAgentSessionID) })
        let stashed = try XCTUnwrap(originalWorkspace.stashedTabs.first)
        let dirtyIDs = Set(originalIDs.prefix(5))
        fixture.prompt.testSetDirtyTabIDs(dirtyIDs)

        await fixture.prompt.unstashTab(stashed.id)

        let finalWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        XCTAssertEqual(finalWorkspace.composeTabs.count, 52)
        XCTAssertEqual(Array(finalWorkspace.composeTabs.prefix(originalIDs.count)).map(\.id), originalIDs)
        XCTAssertEqual(finalWorkspace.composeTabs.last?.id, stashed.tab.id)
        XCTAssertEqual(finalWorkspace.activeComposeTabID, stashed.tab.id)
        XCTAssertTrue(finalWorkspace.stashedTabs.isEmpty)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: finalWorkspace.composeTabs.prefix(originalIDs.count).map { ($0.id, $0.isPinned) }),
            originalPins
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: finalWorkspace.composeTabs.prefix(originalIDs.count).map { ($0.id, $0.activeAgentSessionID) }),
            originalBindings
        )
        XCTAssertEqual(fixture.prompt.dirtyTabIDs.intersection(originalIDs), dirtyIDs)
    }

    func testFailedRequiredFlushKeepsTabRuntimeAndProjection() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let tabID = try XCTUnwrap(fixture.prompt.activeComposeTabID)
        let sessionID = try XCTUnwrap(fixture.manager.composeTab(with: tabID)?.activeAgentSessionID)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        let session = viewModel.session(for: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.setItemsSilently([.user("must persist", sequenceIndex: 0)], reason: .testOverride)
        session.isDirty = true
        session.runState = .running

        let saveAttempts = SaveAttemptRecorder()
        viewModel.test_setAgentSessionSaver { _, _, _ in
            await saveAttempts.record()
            throw RequiredFlushTestError.injectedFailure
        }
        let preflightToken = fixture.prompt.setComposeTabsRemovalPreflight { tabIDs, reason, workspaceID in
            await viewModel.preflightComposeTabsRemoval(tabIDs, reason: reason, workspaceID: workspaceID)
        }
        defer { fixture.prompt.removeComposeTabsRemovalPreflight(preflightToken) }

        let originalOpenIDs = fixture.manager.activeWorkspace?.composeTabs.map(\.id)
        let originalStashedTabs = fixture.manager.activeWorkspace?.stashedTabs
        await fixture.prompt.closeComposeTab(tabID)

        let saveAttemptCount = await saveAttempts.count()
        XCTAssertEqual(saveAttemptCount, 1)
        XCTAssertEqual(fixture.manager.activeWorkspace?.composeTabs.map(\.id), originalOpenIDs)
        XCTAssertEqual(fixture.manager.activeWorkspace?.stashedTabs, originalStashedTabs)
        XCTAssertEqual(fixture.prompt.activeComposeTabID, tabID)
        XCTAssertTrue(viewModel.sessions[tabID] === session)
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(session.isDirty)
    }

    func testFailedDurableDeletionDoesNotResurrectRemovedComposeTab() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let tabID = try XCTUnwrap(fixture.prompt.activeComposeTabID)
        let sessionID = try XCTUnwrap(fixture.manager.composeTab(with: tabID)?.activeAgentSessionID)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        let session = viewModel.session(for: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.runState = .running
        viewModel.setAgentRunActive(tabID, isActive: true)

        var teardownTabIDs: [UUID] = []
        viewModel.test_setComposeTabRemovalTeardownObserver { removedTabID in
            XCTAssertFalse(fixture.manager.activeWorkspace?.composeTabs.contains(where: { $0.id == removedTabID }) == true)
            XCTAssertFalse(fixture.prompt.currentComposeTabs.contains(where: { $0.id == removedTabID }))
            teardownTabIDs.append(removedTabID)
        }
        viewModel.test_setAgentSessionsDeleter { _, _ in
            throw RequiredFlushTestError.injectedFailure
        }
        let didRemoveToken = installDidRemoveListener(prompt: fixture.prompt, viewModel: viewModel)
        defer { fixture.prompt.removeComposeTabsDidRemoveListener(didRemoveToken) }
        await fixture.prompt.closeComposeTab(tabID)

        XCTAssertFalse(fixture.manager.activeWorkspace?.composeTabs.contains(where: { $0.id == tabID }) == true)
        XCTAssertNil(viewModel.sessions[tabID])
        XCTAssertEqual(teardownTabIDs, [tabID])
    }

    func testRestoredTabDuringPostStashCleanupKeepsReplacementRuntime() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let tabID = try XCTUnwrap(fixture.prompt.activeComposeTabID)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        let removedSession = viewModel.session(for: tabID)
        var replacementSession = viewModel.sessions[UUID()]

        viewModel.test_setComposeTabRemovalTeardownObserver { removedTabID in
            guard let activeWorkspaceID = fixture.manager.activeWorkspaceID,
                  let workspaceIndex = fixture.manager.workspaces.firstIndex(where: { $0.id == activeWorkspaceID })
            else {
                XCTFail("Expected active workspace")
                return
            }
            guard let stashedIndex = fixture.manager.workspaces[workspaceIndex].stashedTabs.firstIndex(
                where: { $0.tab.id == removedTabID }
            ) else {
                XCTFail("Expected stashed tab")
                return
            }
            let restoredTab = fixture.manager.workspaces[workspaceIndex].stashedTabs.remove(at: stashedIndex).tab
            fixture.manager.workspaces[workspaceIndex].composeTabs.append(restoredTab)
            replacementSession = viewModel.session(for: removedTabID)
        }
        let didRemoveToken = installDidRemoveListener(prompt: fixture.prompt, viewModel: viewModel)
        defer { fixture.prompt.removeComposeTabsDidRemoveListener(didRemoveToken) }

        _ = await fixture.prompt.stashComposeTabs(withIDs: [tabID])

        XCTAssertFalse(viewModel.sessions[tabID] === removedSession)
        XCTAssertTrue(viewModel.sessions[tabID] === replacementSession)
    }

    func testFailedStashedDeletionDoesNotResurrectRemovedProjection() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let stashedTab = try XCTUnwrap(fixture.manager.activeWorkspace?.stashedTabs.first)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        _ = viewModel.session(for: stashedTab.tab.id)
        viewModel.test_setAgentSessionsDeleter { _, _ in
            throw RequiredFlushTestError.injectedFailure
        }
        let didRemoveToken = installDidRemoveListener(prompt: fixture.prompt, viewModel: viewModel)
        defer { fixture.prompt.removeComposeTabsDidRemoveListener(didRemoveToken) }

        await fixture.prompt.deleteStashedTab(stashedTab.id)

        XCTAssertFalse(fixture.prompt.currentStashedTabs.contains(where: { $0.id == stashedTab.id }))
        XCTAssertFalse(fixture.manager.activeWorkspace?.stashedTabs.contains(where: { $0.id == stashedTab.id }) == true)
        XCTAssertNil(viewModel.sessions[stashedTab.tab.id])
    }

    func testMultiTabDeletionFailureContinuesRemainingCleanup() async throws {
        let fixture = makeFixture(initialTabCount: 3)
        let tabs = try XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        for tab in tabs {
            _ = viewModel.session(for: tab.id)
        }
        let orderedTabIDs = tabs.map(\.id).sorted(by: { $0.uuidString < $1.uuidString })
        let attempts = DeletionAttemptRecorder(failingTabID: orderedTabIDs[1])
        viewModel.test_setAgentSessionsDeleter { tabID, _ in
            try await attempts.delete(tabID)
        }
        let didRemoveToken = installDidRemoveListener(prompt: fixture.prompt, viewModel: viewModel)
        defer { fixture.prompt.removeComposeTabsDidRemoveListener(didRemoveToken) }

        await fixture.prompt.closeAllComposeTabs()

        let attemptedTabIDs = await attempts.attempted()
        XCTAssertEqual(attemptedTabIDs, orderedTabIDs)
        for tab in tabs {
            XCTAssertNil(viewModel.sessions[tab.id])
        }
    }

    func testStashRunsPostProjectionTeardownWithoutDurableDeletion() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let tabID = try XCTUnwrap(fixture.prompt.activeComposeTabID)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        _ = viewModel.session(for: tabID)
        let attempts = DeletionAttemptRecorder(failingTabID: nil)
        viewModel.test_setAgentSessionsDeleter { deletedTabID, _ in
            try await attempts.delete(deletedTabID)
        }
        let didRemoveToken = installDidRemoveListener(prompt: fixture.prompt, viewModel: viewModel)
        defer { fixture.prompt.removeComposeTabsDidRemoveListener(didRemoveToken) }
        await fixture.prompt.stashTab(tabID)

        XCTAssertTrue(fixture.manager.activeWorkspace?.stashedTabs.contains(where: { $0.tab.id == tabID }) == true)
        XCTAssertNil(viewModel.sessions[tabID])
        let attemptedTabIDs = await attempts.attempted()
        XCTAssertTrue(attemptedTabIDs.isEmpty)
    }

    func testSingleStashOfLastTabCreatesReplacement() async throws {
        let fixture = makeFixture(initialTabCount: 1)
        let originalTab = try XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs.first)

        await fixture.prompt.stashTab(originalTab.id)

        let remainingTabs = try XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs)
        XCTAssertEqual(remainingTabs.count, 1)
        XCTAssertNotEqual(remainingTabs.first?.id, originalTab.id)
        XCTAssertTrue(fixture.prompt.currentStashedTabs.contains(where: { $0.tab.id == originalTab.id }))
    }

    func testBulkStashAllCreatesOneReplacementAndReportsRemovedTabs() async throws {
        let fixture = makeFixture(initialTabCount: 3)
        let originalIDs = try Set(XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs.map(\.id)))

        let report = await fixture.prompt.stashComposeTabs(withIDs: originalIDs)

        XCTAssertEqual(report.removedComposeTabIDs, originalIDs)
        XCTAssertTrue(report.rejections.isEmpty)
        let remainingTabs = try XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs)
        XCTAssertEqual(remainingTabs.count, 1)
        let replacement = try XCTUnwrap(remainingTabs.first)
        XCTAssertFalse(originalIDs.contains(replacement.id))
        XCTAssertEqual(fixture.prompt.activeComposeTabID, replacement.id)
        let finalStashedIDs = Set(fixture.manager.activeWorkspace?.stashedTabs.map(\.tab.id) ?? [])
        XCTAssertTrue(finalStashedIDs.isSuperset(of: originalIDs))
    }

    func testBatchPinUpdatesOnlyChangedTabs() throws {
        let fixture = makeFixture(initialTabCount: 3)
        let tabs = try XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs)
        fixture.prompt.setComposeTabPinned(true, for: tabs[0].id)

        let report = fixture.prompt.setComposeTabsPinned(true, for: Set(tabs.map(\.id)))

        XCTAssertEqual(report.updatedTabIDs, Set(tabs.dropFirst().map(\.id)))
        XCTAssertTrue(fixture.prompt.currentComposeTabs.allSatisfy(\.isPinned))
        XCTAssertTrue(fixture.prompt.setComposeTabsPinned(true, for: Set(tabs.map(\.id))).updatedTabIDs.isEmpty)
    }

    func testBatchPinRejectsMissingTargetWithoutPartialMutation() throws {
        let fixture = makeFixture(initialTabCount: 2)
        let tabID = try XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs.dropFirst().first?.id)

        let report = fixture.prompt.setComposeTabsPinned(true, for: [tabID, UUID()])

        XCTAssertTrue(report.contextRejected)
        XCTAssertFalse(fixture.prompt.currentComposeTabs.first(where: { $0.id == tabID })?.isPinned == true)
    }

    func testBulkDeletePreservesConcurrentSameWorkspacePinMutation() async throws {
        let fixture = makeFixture(initialTabCount: 3)
        let tabs = try XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs)
        let targetID = tabs[0].id
        let retainedID = tabs[1].id
        let gate = ComposeRemovalPreflightGate()
        let preflightToken = fixture.prompt.setComposeTabsRemovalPreflight { _, _, _ in
            await gate.markStartedAndWaitForRelease()
            return .proceed
        }
        defer { fixture.prompt.removeComposeTabsRemovalPreflight(preflightToken) }

        let deleteTask = Task { await fixture.prompt.closeComposeTabs(withIDs: [targetID]) }
        let preflightStarted = await gate.waitUntilStarted()
        XCTAssertTrue(preflightStarted)
        fixture.prompt.setComposeTabPinned(true, for: retainedID)
        await gate.release()
        _ = await deleteTask.value

        XCTAssertFalse(fixture.prompt.currentComposeTabs.contains(where: { $0.id == targetID }))
        XCTAssertEqual(fixture.prompt.currentComposeTabs.first(where: { $0.id == retainedID })?.isPinned, true)
    }

    func testCloseRejectsMissingRequestedRootBeforeCascadeResolution() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let activeTabID = try XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs.first?.id)
        let stashed = try XCTUnwrap(fixture.manager.activeWorkspace?.stashedTabs.first)

        let report = await fixture.prompt.closeComposeTabs(withIDs: [activeTabID, stashed.tab.id])

        XCTAssertTrue(report.rejections.contains(where: { $0.reason == .mutationContextChanged }))
        XCTAssertTrue(fixture.prompt.currentComposeTabs.contains(where: { $0.id == activeTabID }))
        XCTAssertTrue(fixture.prompt.currentStashedTabs.contains(where: { $0.id == stashed.id }))
    }

    func testArchivedDeleteRejectsSelectedIdentityReplacedDuringCascade() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let selected = try XCTUnwrap(fixture.manager.activeWorkspace?.stashedTabs.first)
        let replacementTab = ComposeTabState(id: UUID(), name: "Replacement")
        let gate = ComposeRemovalPreflightGate()
        fixture.prompt.stashedTabCascadeResolver = { _ in
            await gate.markStartedAndWaitForRelease()
            return PromptViewModel.AgentSessionCascadePlan()
        }
        let target = PromptViewModel.ArchivedTabMutationTarget(
            stashedTabID: selected.id,
            tabID: selected.tab.id
        )

        let deleteTask = Task {
            await fixture.prompt.deleteComposeAndStashedTabs(
                composeTabIDs: [],
                archivedTargets: [target]
            )
        }
        let cascadeStarted = await gate.waitUntilStarted()
        XCTAssertTrue(cascadeStarted)
        let workspaceID = try XCTUnwrap(fixture.manager.activeWorkspace?.id)
        let workspaceIndex = try XCTUnwrap(fixture.manager.workspaces.firstIndex(where: { $0.id == workspaceID }))
        let selectedIndex = try XCTUnwrap(
            fixture.manager.workspaces[workspaceIndex].stashedTabs.firstIndex(where: { $0.id == selected.id })
        )
        fixture.manager.workspaces[workspaceIndex].stashedTabs[selectedIndex] = StashedTab(
            id: selected.id,
            tab: replacementTab
        )
        await gate.release()
        let report = await deleteTask.value

        XCTAssertTrue(report.rejections.contains(where: { $0.reason == .mutationContextChanged }))
        XCTAssertTrue(fixture.manager.workspaces[workspaceIndex].stashedTabs.contains(where: {
            $0.id == selected.id && $0.tab.id == replacementTab.id
        }))
    }

    func testParentDeleteIncludesChildPausedAfterDurableAdmission() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let parentTab = try XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs.first)
        let parentSessionID = try XCTUnwrap(parentTab.activeAgentSessionID)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        let admissionGate = ComposeRemovalPreflightGate()
        viewModel.test_setAfterDurableChildTabCreation {
            await admissionGate.markStartedAndWaitForRelease()
        }

        let admissionTask = Task {
            try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: nil,
                createIfNeeded: true,
                sessionName: "Paused child",
                parentSessionID: parentSessionID
            )
        }
        let admissionPaused = await admissionGate.waitUntilStarted()
        XCTAssertTrue(admissionPaused)
        let childTabID = try XCTUnwrap(
            fixture.manager.activeWorkspace?.composeTabs.first(where: { $0.id != parentTab.id && $0.name == "Paused child" })?.id
        )

        let report = await fixture.prompt.deleteComposeAndStashedTabs(
            composeTabIDs: [parentTab.id],
            archivedTargets: []
        )
        await admissionGate.release()

        XCTAssertTrue(report.removedComposeTabIDs.contains(parentTab.id))
        XCTAssertTrue(report.removedComposeTabIDs.contains(childTabID))
        XCTAssertFalse(fixture.prompt.currentComposeTabs.contains(where: { $0.id == parentTab.id || $0.id == childTabID }))
        do {
            _ = try await admissionTask.value
            XCTFail("Expected paused child admission to reject after cascade deletion")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("removed before admission completed"))
        }
    }

    func testArchivedDeleteRejectsChildAdmittedDuringRequiredPersistence() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let archived = try XCTUnwrap(fixture.manager.activeWorkspace?.stashedTabs.first)
        let parentSessionID = try XCTUnwrap(archived.tab.activeAgentSessionID)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        let preflightGate = ComposeRemovalPreflightGate()
        let admissionGate = ComposeRemovalPreflightGate()
        viewModel.test_setAfterDurableChildTabCreation {
            await admissionGate.markStartedAndWaitForRelease()
        }
        let preflightToken = fixture.prompt.setComposeTabsRemovalPreflight { _, reason, _ in
            if reason == .deleteStashed {
                await preflightGate.markStartedAndWaitForRelease()
            }
            return .proceed
        }
        defer { fixture.prompt.removeComposeTabsRemovalPreflight(preflightToken) }
        let target = PromptViewModel.ArchivedTabMutationTarget(
            stashedTabID: archived.id,
            tabID: archived.tab.id
        )

        let deleteTask = Task {
            await fixture.prompt.deleteComposeAndStashedTabs(
                composeTabIDs: [],
                archivedTargets: [target]
            )
        }
        let preflightStarted = await preflightGate.waitUntilStarted()
        XCTAssertTrue(preflightStarted)
        let admissionTask = Task {
            try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: nil,
                createIfNeeded: true,
                sessionName: "Late archived child",
                parentSessionID: parentSessionID
            )
        }
        let admissionPaused = await admissionGate.waitUntilStarted()
        XCTAssertTrue(admissionPaused)
        let childTabID = try XCTUnwrap(
            fixture.manager.activeWorkspace?.composeTabs.first(where: { $0.name == "Late archived child" })?.id
        )
        await preflightGate.release()
        let report = await deleteTask.value
        await admissionGate.release()
        _ = try await admissionTask.value

        XCTAssertTrue(report.rejections.contains(where: { $0.reason == .mutationContextChanged }))
        XCTAssertTrue(fixture.prompt.currentStashedTabs.contains(where: { $0.id == archived.id }))
        XCTAssertTrue(fixture.prompt.currentComposeTabs.contains(where: { $0.id == childTabID }))
    }

    func testDeleteRejectsCascadeAddedArchivedIdentityReplacement() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let activeTabID = try XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs.first?.id)
        let archived = try XCTUnwrap(fixture.manager.activeWorkspace?.stashedTabs.first)
        let replacementTab = ComposeTabState(id: UUID(), name: "Replacement descendant")
        let gate = ComposeRemovalPreflightGate()
        fixture.prompt.composeTabCascadeResolver = { _, _ in
            await gate.markStartedAndWaitForRelease()
            return PromptViewModel.AgentSessionCascadePlan(archivedTargets: [
                .init(stashedTabID: archived.id, tabID: archived.tab.id)
            ])
        }

        let deleteTask = Task { await fixture.prompt.closeComposeTabs(withIDs: [activeTabID]) }
        let cascadeStarted = await gate.waitUntilStarted()
        XCTAssertTrue(cascadeStarted)
        let workspaceID = try XCTUnwrap(fixture.manager.activeWorkspace?.id)
        let workspaceIndex = try XCTUnwrap(fixture.manager.workspaces.firstIndex(where: { $0.id == workspaceID }))
        let archivedIndex = try XCTUnwrap(
            fixture.manager.workspaces[workspaceIndex].stashedTabs.firstIndex(where: { $0.id == archived.id })
        )
        fixture.manager.workspaces[workspaceIndex].stashedTabs[archivedIndex] = StashedTab(
            id: archived.id,
            tab: replacementTab
        )
        await gate.release()
        let report = await deleteTask.value

        XCTAssertTrue(report.rejections.contains(where: { $0.reason == .mutationContextChanged }))
        XCTAssertTrue(fixture.prompt.currentComposeTabs.contains(where: { $0.id == activeTabID }))
        XCTAssertTrue(fixture.manager.workspaces[workspaceIndex].stashedTabs.contains(where: {
            $0.id == archived.id && $0.tab.id == replacementTab.id
        }))
    }

    func testBulkCoordinatorAppliesExactMixedDeleteTargets() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let activeTabID = try XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs.first?.id)
        let stashed = try XCTUnwrap(fixture.manager.activeWorkspace?.stashedTabs.first)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        let didRemoveToken = installDidRemoveListener(prompt: fixture.prompt, viewModel: viewModel)
        defer { fixture.prompt.removeComposeTabsDidRemoveListener(didRemoveToken) }
        let targets = try AgentModeViewModel.SidebarBulkMutationTargets(
            workspaceID: XCTUnwrap(fixture.manager.activeWorkspace?.id),
            activeDeleteTabIDs: [activeTabID],
            archivedDeleteTargets: [.init(stashedTabID: stashed.id, tabID: stashed.tab.id)],
            stashTabIDs: [],
            pinTabIDs: [],
            unpinTabIDs: []
        )

        await viewModel.performSidebarBulkAction(.delete, targets: targets, promptManager: fixture.prompt)

        XCTAssertFalse(fixture.prompt.currentComposeTabs.contains(where: { $0.id == activeTabID }))
        XCTAssertFalse(fixture.prompt.currentStashedTabs.contains(where: { $0.id == stashed.id }))
        XCTAssertNil(viewModel.ui.sessionSidebar.selectionState.inFlightAction)
    }

    func testMixedDeleteDoesNotRetryArchivedTargetRejectedDuringActiveCascade() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let activeTabID = try XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs.first?.id)
        let stashed = try XCTUnwrap(fixture.manager.activeWorkspace?.stashedTabs.first)
        fixture.prompt.composeTabCascadeResolver = { _, _ in
            PromptViewModel.AgentSessionCascadePlan(archivedTargets: [
                .init(stashedTabID: stashed.id, tabID: stashed.tab.id)
            ])
        }
        fixture.prompt.stashedTabCascadeResolver = { _ in PromptViewModel.AgentSessionCascadePlan() }
        fixture.prompt.agentSessionCascadeSnapshotResolver = { _, _, _ in
            PromptViewModel.AgentSessionCascadePlan(archivedTargets: [
                .init(stashedTabID: stashed.id, tabID: stashed.tab.id)
            ])
        }
        let preflightRecorder = RemovalPreflightRecorder()
        let preflightToken = fixture.prompt.setComposeTabsRemovalPreflight { _, reason, _ in
            await preflightRecorder.record(reason)
            if reason == .deleteStashed {
                return .abort(.init(
                    stage: .requiredSessionFlush,
                    tabID: stashed.tab.id,
                    message: "Injected archived rejection."
                ))
            }
            return .proceed
        }
        defer { fixture.prompt.removeComposeTabsRemovalPreflight(preflightToken) }

        let report = await fixture.prompt.deleteComposeAndStashedTabs(
            composeTabIDs: [activeTabID],
            archivedTargets: [.init(stashedTabID: stashed.id, tabID: stashed.tab.id)]
        )

        let archivedPreflightCount = await preflightRecorder.count(for: .deleteStashed)
        XCTAssertEqual(archivedPreflightCount, 1)
        XCTAssertEqual(report.rejections.count(where: { $0.kind == .deleteStashed }), 1)
        XCTAssertTrue(report.removedComposeTabIDs.contains(activeTabID))
        XCTAssertTrue(fixture.prompt.currentStashedTabs.contains(where: { $0.id == stashed.id }))
    }

    func testMixedDeleteKeepsArchivedTargetWhenActiveCascadePreflightRejects() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let activeTabID = try XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs.first?.id)
        let stashed = try XCTUnwrap(fixture.manager.activeWorkspace?.stashedTabs.first)
        fixture.prompt.stashedTabCascadeResolver = { _ in
            PromptViewModel.AgentSessionCascadePlan(composeTabIDs: [activeTabID])
        }
        fixture.prompt.agentSessionCascadeSnapshotResolver = { _, _, _ in
            PromptViewModel.AgentSessionCascadePlan(composeTabIDs: [activeTabID])
        }
        let preflightRecorder = RemovalPreflightRecorder()
        let preflightToken = fixture.prompt.setComposeTabsRemovalPreflight { _, reason, _ in
            await preflightRecorder.record(reason)
            if reason == .close {
                return .abort(.init(
                    stage: .requiredSessionFlush,
                    tabID: activeTabID,
                    message: "Injected active rejection."
                ))
            }
            return .proceed
        }
        defer { fixture.prompt.removeComposeTabsRemovalPreflight(preflightToken) }

        let report = await fixture.prompt.deleteComposeAndStashedTabs(
            composeTabIDs: [],
            archivedTargets: [.init(stashedTabID: stashed.id, tabID: stashed.tab.id)]
        )

        let archivedPreflightCount = await preflightRecorder.count(for: .deleteStashed)
        XCTAssertEqual(archivedPreflightCount, 0)
        XCTAssertTrue(report.rejections.contains(where: { $0.kind == .close }))
        XCTAssertTrue(fixture.prompt.currentComposeTabs.contains(where: { $0.id == activeTabID }))
        XCTAssertTrue(fixture.prompt.currentStashedTabs.contains(where: { $0.id == stashed.id }))
    }

    func testArchivedDeleteReportPreservesActiveMutationWhenContextExpiresBeforeArchivedPreflight() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let activeTabID = try XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs.first?.id)
        let stashed = try XCTUnwrap(fixture.manager.activeWorkspace?.stashedTabs.first)
        fixture.prompt.stashedTabCascadeResolver = { _ in
            PromptViewModel.AgentSessionCascadePlan(composeTabIDs: [activeTabID])
        }
        fixture.prompt.agentSessionCascadeSnapshotResolver = { _, _, _ in
            PromptViewModel.AgentSessionCascadePlan(composeTabIDs: [activeTabID])
        }
        let context = MutationContextFlag()
        let didRemoveToken = fixture.prompt.addComposeTabsDidRemoveListener { _, _, _ in
            context.isCurrent = false
            return []
        }
        defer { fixture.prompt.removeComposeTabsDidRemoveListener(didRemoveToken) }

        let report = await fixture.prompt.deleteComposeAndStashedTabs(
            composeTabIDs: [],
            archivedTargets: [.init(stashedTabID: stashed.id, tabID: stashed.tab.id)],
            isMutationContextCurrent: { context.isCurrent }
        )

        XCTAssertEqual(report.removedComposeTabIDs, [activeTabID])
        XCTAssertTrue(report.rejections.contains(where: { $0.reason == .mutationContextChanged }))
        XCTAssertTrue(fixture.prompt.currentStashedTabs.contains(where: { $0.id == stashed.id }))
    }

    func testArchivedDeleteRejectsMissingTargetWithoutPartialMutation() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let target = try XCTUnwrap(fixture.manager.activeWorkspace?.stashedTabs.first)

        let report = await fixture.prompt.deleteStashedTabs(withIDs: [target.id, UUID()])

        XCTAssertTrue(report.rejections.contains(where: { $0.reason == .mutationContextChanged }))
        XCTAssertTrue(fixture.prompt.currentStashedTabs.contains(where: { $0.id == target.id }))
    }

    func testArchivedDeletePreservesConcurrentUnrelatedStashedMutation() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let target = try XCTUnwrap(fixture.manager.activeWorkspace?.stashedTabs.first)
        let unrelated = StashedTab(tab: ComposeTabState(id: UUID(), name: "Concurrent archive"))
        let gate = ComposeRemovalPreflightGate()
        let preflightToken = fixture.prompt.setComposeTabsRemovalPreflight { _, reason, _ in
            if reason == .deleteStashed {
                await gate.markStartedAndWaitForRelease()
            }
            return .proceed
        }
        defer { fixture.prompt.removeComposeTabsRemovalPreflight(preflightToken) }

        let deleteTask = Task { await fixture.prompt.deleteStashedTabs(withIDs: [target.id]) }
        let preflightStarted = await gate.waitUntilStarted()
        XCTAssertTrue(preflightStarted)
        let workspaceID = try XCTUnwrap(fixture.manager.activeWorkspace?.id)
        let workspaceIndex = try XCTUnwrap(fixture.manager.workspaces.firstIndex(where: { $0.id == workspaceID }))
        fixture.manager.workspaces[workspaceIndex].stashedTabs.append(unrelated)
        await gate.release()
        let report = await deleteTask.value

        XCTAssertEqual(report.removedStashedTabIDs, [target.id])
        XCTAssertTrue(report.rejections.isEmpty)
        XCTAssertTrue(fixture.prompt.currentStashedTabs.contains(where: { $0.id == unrelated.id }))
    }

    func testArchivedOnlyWorkspaceUnavailableUsesArchivedRejection() async {
        let fixture = makeFixture(initialTabCount: 2)
        fixture.manager.activeWorkspace = nil

        let report = await fixture.prompt.deleteStashedTabs(withIDs: [UUID()])

        XCTAssertEqual(report.rejections.map(\.kind), [.deleteStashed])
    }

    func testBulkActionRejectsTargetsCapturedFromPreviousWorkspace() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let sourceWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        let tabID = try XCTUnwrap(sourceWorkspace.composeTabs.dropFirst().first?.id)
        let destinationWorkspace = WorkspaceModel(
            name: "Destination",
            repoPaths: sourceWorkspace.repoPaths,
            ephemeralFlag: true,
            composeTabs: sourceWorkspace.composeTabs,
            activeComposeTabID: sourceWorkspace.activeComposeTabID,
            stashedTabs: sourceWorkspace.stashedTabs
        )
        fixture.manager.workspaces.append(destinationWorkspace)
        fixture.manager.activeWorkspace = destinationWorkspace
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        let targets = AgentModeViewModel.SidebarBulkMutationTargets(
            workspaceID: sourceWorkspace.id,
            activeDeleteTabIDs: [tabID],
            archivedDeleteTargets: [],
            stashTabIDs: [],
            pinTabIDs: [tabID],
            unpinTabIDs: []
        )

        await viewModel.performSidebarBulkAction(.pin, targets: targets, promptManager: fixture.prompt)

        XCTAssertFalse(fixture.manager.activeWorkspace?.composeTabs.first(where: { $0.id == tabID })?.isPinned == true)
        XCTAssertNil(viewModel.ui.sessionSidebar.selectionState.inFlightAction)
    }

    func testBulkNoticeReportsCleanupFailureAndRejectedGroup() {
        let fixture = makeFixture(initialTabCount: 2)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        let tabID = UUID()
        let report = PromptViewModel.ComposeTabMutationReport(
            removedComposeTabIDs: [tabID],
            rejections: [.init(
                kind: .deleteStashed,
                reason: .requiredSessionPreflight,
                tabID: UUID(),
                message: "Required persistence failed."
            )],
            cleanupIssues: [.init(tabID: tabID, reason: .close, message: "Cleanup failed.")]
        )

        let notice = viewModel.sidebarBulkActionNotice(for: report, action: .delete)

        XCTAssertEqual(notice?.severity, .error)
        XCTAssertTrue(notice?.message.contains("cleanup failed for 1") == true)
        XCTAssertTrue(notice?.message.contains("selected or related chats") == true)
    }

    func testPostRemovalClearsOnlyRemovedTabTranscriptRefreshSignature() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let removedTabID = try XCTUnwrap(fixture.prompt.activeComposeTabID)
        let retainedTabID = try XCTUnwrap(
            fixture.manager.activeWorkspace?.composeTabs.first(where: { $0.id != removedTabID })?.id
        )
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        _ = viewModel.session(for: removedTabID)

        AgentTranscriptDebugInstrumentation.reset()
        defer { AgentTranscriptDebugInstrumentation.reset() }
        var attempts: [AgentTranscriptRefreshAttemptMetrics] = []
        AgentTranscriptDebugInstrumentation.configure(.init(
            refreshAttemptHandler: { attempts.append($0) }
        ))

        emitTranscriptRefreshAttempt(tabID: removedTabID, inputSignature: "removed-signature")
        emitTranscriptRefreshAttempt(tabID: retainedTabID, inputSignature: "retained-signature")

        let didRemoveToken = installDidRemoveListener(prompt: fixture.prompt, viewModel: viewModel)
        defer { fixture.prompt.removeComposeTabsDidRemoveListener(didRemoveToken) }
        await fixture.prompt.stashTab(removedTabID)

        attempts.removeAll()
        emitTranscriptRefreshAttempt(tabID: removedTabID, inputSignature: "removed-signature")
        emitTranscriptRefreshAttempt(tabID: retainedTabID, inputSignature: "retained-signature")

        XCTAssertEqual(attempts.count, 2)
        XCTAssertNil(attempts[0].previousInputSignature)
        XCTAssertFalse(attempts[0].isConsecutiveDuplicateInput)
        XCTAssertEqual(attempts[1].previousInputSignature, "retained-signature")
        XCTAssertTrue(attempts[1].isConsecutiveDuplicateInput)
    }

    func testRejectedConcurrentAgentAdmissionsPreserveActiveLivePinnedSession() async throws {
        let fixture = makeFixture(initialTabCount: 2)
        let workspaceID = try XCTUnwrap(fixture.manager.activeWorkspaceID)
        fixture.manager.setWorkspaceEphemeral(workspaceID, false)
        let tabID = try XCTUnwrap(fixture.prompt.activeComposeTabID)
        fixture.prompt.setComposeTabPinned(true, for: tabID)
        let sessionID = try XCTUnwrap(fixture.manager.composeTab(with: tabID)?.activeAgentSessionID)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        let session = viewModel.session(for: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.runState = .running
        viewModel.setAgentRunActive(tabID, isActive: true)
        fixture.manager.setWorkspacePersistenceOutcomeOverrideForTesting(
            .rejected(reason: "workspace_not_writable")
        )
        defer { fixture.manager.setWorkspacePersistenceOutcomeOverrideForTesting(nil) }

        let originalWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        let originalTabs = originalWorkspace.composeTabs
        let originalStashedTabs = originalWorkspace.stashedTabs

        let first = Task { @MainActor in
            await self.admissionWasRejected(viewModel)
        }
        let second = Task { @MainActor in
            await self.admissionWasRejected(viewModel)
        }
        let rejections = await [first.value, second.value]

        XCTAssertEqual(rejections, [true, true])
        let finalWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        XCTAssertEqual(finalWorkspace.composeTabs.map(\.id), originalTabs.map(\.id))
        XCTAssertEqual(finalWorkspace.composeTabs.map(\.name), originalTabs.map(\.name))
        XCTAssertEqual(finalWorkspace.composeTabs.map(\.isPinned), originalTabs.map(\.isPinned))
        XCTAssertEqual(
            finalWorkspace.composeTabs.map(\.activeAgentSessionID),
            originalTabs.map(\.activeAgentSessionID)
        )
        XCTAssertEqual(finalWorkspace.stashedTabs, originalStashedTabs)
        XCTAssertEqual(finalWorkspace.activeComposeTabID, tabID)
        XCTAssertEqual(fixture.prompt.activeComposeTabID, tabID)
        XCTAssertTrue(fixture.prompt.currentComposeTabs.contains(where: {
            $0.id == tabID && $0.isPinned && $0.activeAgentSessionID == sessionID
        }))
        XCTAssertTrue(viewModel.sessions[tabID] === session)
        XCTAssertEqual(session.activeAgentSessionID, sessionID)
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(Set(viewModel.sessions.keys), Set([tabID]))
    }

    func testStaleProjectionCannotReplaceActiveLivePinnedSession() throws {
        let fixture = makeFixture(initialTabCount: 2)
        let tabID = try XCTUnwrap(fixture.prompt.activeComposeTabID)
        fixture.prompt.setComposeTabPinned(true, for: tabID)
        let sessionID = try XCTUnwrap(fixture.manager.composeTab(with: tabID)?.activeAgentSessionID)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        let session = viewModel.session(for: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.runState = .running
        viewModel.setAgentRunActive(tabID, isActive: true)

        let currentWorkspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        var staleWorkspace = currentWorkspace
        var staleTab = try XCTUnwrap(currentWorkspace.composeTabs.first(where: { $0.id == tabID }))
        staleTab.name = "Stale replacement"
        staleTab.isPinned = false
        staleTab.activeAgentSessionID = UUID()
        staleWorkspace.composeTabs.removeAll { $0.id == tabID }
        staleWorkspace.activeComposeTabID = staleWorkspace.composeTabs.first?.id
        staleWorkspace.stashedTabs.append(StashedTab(
            tab: staleTab,
            stashedAt: Date()
        ))

        fixture.manager.applyDomainWorkspaceProjection(
            [staleWorkspace],
            fileURLsByWorkspaceID: [:],
            revisionsByWorkspaceID: [:],
            digestsByWorkspaceID: [:],
            healthByWorkspaceID: [:],
            catalogRevision: 1,
            preferredActiveWorkspaceID: currentWorkspace.id,
            publicationSequence: 1
        )

        let reconciled = try XCTUnwrap(fixture.manager.activeWorkspace)
        let protectedTab = try XCTUnwrap(reconciled.composeTabs.first(where: { $0.id == tabID }))
        XCTAssertTrue(protectedTab.isPinned)
        XCTAssertEqual(protectedTab.activeAgentSessionID, sessionID)
        XCTAssertEqual(protectedTab.name, currentWorkspace.composeTabs.first(where: { $0.id == tabID })?.name)
        XCTAssertEqual(reconciled.activeComposeTabID, tabID)
        XCTAssertFalse(reconciled.stashedTabs.contains(where: { $0.tab.id == tabID }))
        XCTAssertTrue(viewModel.sessions[tabID] === session)
        XCTAssertEqual(session.runState, .running)
    }

    func testLateTitleProviderAndInteractionAttemptsCannotCrossChangedSessionIdentity() async throws {
        let fixture = makeFixture(initialTabCount: 1)
        let tabID = try XCTUnwrap(fixture.prompt.activeComposeTabID)
        fixture.prompt.setComposeTabPinned(true, for: tabID)
        let originalSessionID = try XCTUnwrap(fixture.manager.composeTab(with: tabID)?.activeAgentSessionID)
        let viewModel = makeAgentModeViewModel(prompt: fixture.prompt, manager: fixture.manager)
        let session = viewModel.session(for: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: originalSessionID, on: session)
        let target = try viewModel.resolveAgentSessionLifecycleMutationTarget(
            tabID: tabID,
            expectedSessionID: originalSessionID,
            intent: .setStatus
        )
        let runTarget = AgentModeViewModel.MCPSessionTarget(
            tabID: tabID,
            sessionID: originalSessionID,
            origin: .existingSession,
            lifecycleIdentity: target.identity
        )
        let originalName = fixture.manager.composeTab(with: tabID)?.name

        let replacementSessionID = UUID()
        _ = viewModel.test_installPersistentSessionBinding(
            sessionID: replacementSessionID,
            on: session,
            updateWorkspaceMetadata: true
        )

        XCTAssertThrowsError(try viewModel.renameSession(target: target, to: "Late stale title"))
        XCTAssertThrowsError(try viewModel.requireCurrentAgentSessionLifecycleAdmission(runTarget))
        let interaction = AgentAskUserInteraction(
            title: "Late question",
            questions: [
                AgentAskUserQuestion(
                    id: "answer",
                    question: "Should not be shown",
                    allowsMultiple: false,
                    allowsCustom: true
                )
            ]
        )
        await assertThrowsErrorAsync {
            try await viewModel.askUserInteraction(target: target, interaction: interaction)
        }
        await assertThrowsErrorAsync {
            try await viewModel.waitForNextUserInstruction(target: target)
        }
        XCTAssertEqual(fixture.manager.composeTab(with: tabID)?.name, originalName)
        XCTAssertEqual(fixture.manager.composeTab(with: tabID)?.activeAgentSessionID, replacementSessionID)
        XCTAssertEqual(session.activeAgentSessionID, replacementSessionID)
        XCTAssertNil(session.pendingAskUser)
        XCTAssertNil(session.instructionContinuation)
    }

    func testLifecycleAdmissionAcceptsCorrectAlreadySavedWorkspaceAndRejectsWrongWorkspace() {
        let authority = AgentSessionLifecycleAuthority()
        let workspaceID = UUID()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .notRequired(workspaceID: workspaceID),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: true
            ),
            .commit
        )
        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .persisted(workspaceID: UUID(), stateVersion: 7),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: true
            ),
            .rollback(.workspaceChanged)
        )
    }

    private func admissionWasRejected(_ viewModel: AgentModeViewModel) async -> Bool {
        do {
            _ = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: nil,
                createIfNeeded: true,
                sessionName: "Rejected concurrent workflow"
            )
            return false
        } catch {
            return true
        }
    }

    private func assertThrowsErrorAsync(
        _ expression: () async throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected expression to throw", file: file, line: line)
        } catch {}
    }

    private func makeFixture(initialTabCount: Int) -> (manager: WorkspaceManagerViewModel, prompt: PromptViewModel) {
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let tabs = (0 ..< initialTabCount).map { index in
            ComposeTabState(
                name: "Existing \(index)",
                lastModified: Date(timeIntervalSince1970: TimeInterval(index)),
                isPinned: index.isMultiple(of: 11),
                activeAgentSessionID: UUID()
            )
        }
        let stashed = StashedTab(
            tab: ComposeTabState(name: "Already stashed", activeAgentSessionID: UUID()),
            stashedAt: Date(timeIntervalSince1970: 1)
        )
        let workspace = WorkspaceModel(
            name: "Background compose admission",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: tabs,
            activeComposeTabID: tabs.last?.id,
            stashedTabs: [stashed]
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        prompt.loadComposeTabsFromWorkspace(workspace)
        return (manager, prompt)
    }

    private func makeAgentModeViewModel(
        prompt: PromptViewModel,
        manager: WorkspaceManagerViewModel
    ) -> AgentModeViewModel {
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in ComposeAdmissionFakeCodexController() }
        )
        viewModel.test_setSidebarAutoArchiveDependencies(promptManager: prompt, workspaceManager: manager)
        return viewModel
    }

    private func installDidRemoveListener(
        prompt: PromptViewModel,
        viewModel: AgentModeViewModel
    ) -> UUID {
        prompt.addComposeTabsDidRemoveListener { tabIDs, reason, workspaceID in
            await viewModel.handleComposeTabsDidRemove(tabIDs, reason: reason, workspaceID: workspaceID)
        }
    }

    private func emitTranscriptRefreshAttempt(tabID: UUID, inputSignature: String) {
        AgentTranscriptDebugInstrumentation.emitRefreshAttempt(
            tabID: tabID,
            reason: "test",
            sourceItemsRevision: 0,
            itemCount: 0,
            nextSequenceIndex: 0,
            runState: "idle",
            selectedAgent: "test",
            projectionProtection: "none",
            pendingMutationSummary: "none",
            incrementalPath: "test",
            inputSignature: inputSignature
        )
    }
}

private actor ComposeRemovalSideEffectRecorder {
    struct Snapshot: Equatable {
        var cascadeCount = 0
        var closeCount = 0
        var affectedTabIDs: Set<UUID> = []
    }

    private var value = Snapshot()

    func recordCascade(_ tabIDs: Set<UUID>) {
        value.cascadeCount += 1
        value.affectedTabIDs.formUnion(tabIDs)
    }

    func recordClose(_ tabIDs: Set<UUID>) {
        value.closeCount += 1
        value.affectedTabIDs.formUnion(tabIDs)
    }

    func snapshot() -> Snapshot {
        value
    }
}

private actor SaveAttemptRecorder {
    private var value = 0

    func record() {
        value += 1
    }

    func count() -> Int {
        value
    }
}

private actor DeletionAttemptRecorder {
    private let failingTabID: UUID?
    private var tabIDs: [UUID] = []

    init(failingTabID: UUID?) {
        self.failingTabID = failingTabID
    }

    func delete(_ tabID: UUID) throws {
        tabIDs.append(tabID)
        if tabID == failingTabID {
            throw RequiredFlushTestError.injectedFailure
        }
    }

    func attempted() -> [UUID] {
        tabIDs
    }
}

private enum RequiredFlushTestError: Error {
    case injectedFailure
}

private final class ComposeAdmissionFakeCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "fake", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        .init(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        .init(
            conversationID: "fake",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_: String, threadID _: String?) async throws {}
    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}

@MainActor
private final class MutationContextFlag {
    var isCurrent = true
}

private actor RemovalPreflightRecorder {
    private var reasons: [PromptViewModel.ComposeTabRemovalReason] = []

    func record(_ reason: PromptViewModel.ComposeTabRemovalReason) {
        reasons.append(reason)
    }

    func count(for reason: PromptViewModel.ComposeTabRemovalReason) -> Int {
        reasons.count { $0 == reason }
    }
}

private actor ComposeRemovalPreflightGate {
    private var started = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWaitForRelease() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !started, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return started
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
