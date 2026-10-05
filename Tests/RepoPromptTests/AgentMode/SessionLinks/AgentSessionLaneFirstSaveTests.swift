import Foundation
@testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

@MainActor
final class AgentSessionLaneFirstSaveTests: XCTestCase {
    private struct Fixture {
        let window: WindowState
        let root: URL
        let workspaceID: UUID
        let selection: AgentSessionLanePolicy.RoleSelection
    }

    private func withFixture(ephemeral: Bool = true, _ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-first-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
        if !ephemeral {
            UserDefaults.standard.set(root.appendingPathComponent("storage").path, forKey: "GlobalCustomStorageURL")
        }
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        let cleanup: @MainActor () async -> Void = {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            if !ephemeral {
                await WorkspaceDiskWriterComposition.processWriter.removeAllForTesting()
                if let previousStoragePath {
                    UserDefaults.standard.set(previousStoragePath, forKey: "GlobalCustomStorageURL")
                } else {
                    UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        do {
            await window.workspaceManager.awaitInitialized()
            let workspace = window.workspaceManager.createWorkspace(
                name: "Lane first save \(UUID().uuidString.prefix(8))",
                repoPaths: [root.path], ephemeral: ephemeral
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace, saveState: false, reason: "laneFirstSaveTest"
            )
            let selection = try AgentSessionLanePolicy.resolveRole(
                "pair", availability: .current, workspaceID: workspace.id
            )
            try await body(Fixture(
                window: window, root: root, workspaceID: workspace.id, selection: selection
            ))
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    private func withSecondRegisteredWindow(_ body: (WindowState) async throws -> Void) async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        do {
            await window.workspaceManager.awaitInitialized()
            try await body(window)
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            throw error
        }
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
    }

    func testDrivenFirstSaveWaitsForPreviouslyEnteredSaveAndPersistsProvenance() async throws {
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let creatorID = UUID()
            let fileURL = fixture.root.appendingPathComponent("lane.json")
            let firstSaveEntered = expectation(description: "ordinary save entered")
            let completed = expectation(description: "driven lane save settled")
            var provisionRelease: CheckedContinuation<Void, Never>?
            var staleSaveRelease: CheckedContinuation<Void, Never>?
            var saveCount = 0
            viewModel.test_afterOversightLaneProvision = { tabID in
                Task { @MainActor in await viewModel.flushSave(for: tabID) }
                await withCheckedContinuation { provisionRelease = $0 }
            }
            viewModel.test_setAgentSessionSaver { session, _, _ in
                saveCount += 1
                if saveCount == 1 {
                    provisionRelease?.resume()
                    firstSaveEntered.fulfill()
                    await withCheckedContinuation { staleSaveRelease = $0 }
                }
                let data = try JSONEncoder().encode(session)
                try data.write(to: fileURL, options: .atomic)
                return fileURL
            }
            var outcome: AgentModeViewModel.MCPOversightLaneCreationOutcome?
            Task { @MainActor in
                outcome = try? await viewModel.mcpCreateOversightLane(
                    creatorSessionID: creatorID, sessionName: "Persisted lane",
                    selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
                )
                completed.fulfill()
            }
            await fulfillment(of: [firstSaveEntered], timeout: 3)
            XCTAssertEqual(saveCount, 1)
            staleSaveRelease?.resume()
            await fulfillment(of: [completed], timeout: 5)
            guard let outcome, case let .created(sessionID, tabID, bindingToken) = outcome else {
                let lane = viewModel.sessions.values.first(where: {
                    $0.createdByOverseerSessionID == creatorID
                })
                return XCTFail("lane did not establish a durable first-save proof: \(String(describing: outcome)); saves=\(saveCount), readiness=\(String(describing: lane?.restorationReadiness)), model=\(String(describing: lane?.selectedModelRaw)), expected=\(fixture.selection.modelRaw), dirty=\(String(describing: lane?.isDirty))")
            }
            let saved = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))
            XCTAssertEqual(saved.id, sessionID)
            XCTAssertEqual(saved.createdByOverseerSessionID, creatorID)
            XCTAssertEqual(
                CodexModelSpecifier(raw: saved.agentModel).baseModel,
                CodexModelSpecifier(raw: fixture.selection.modelRaw).baseModel
            )
            XCTAssertEqual(saved.agentReasoningEffort, fixture.selection.reasoningEffortRaw)
            XCTAssertGreaterThanOrEqual(saveCount, 2)
            let lane = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertEqual(
                lane.restorationReadiness,
                .authoritative(bindingToken, .freshBindingDurablyCreated)
            )
            XCTAssertFalse(lane.runState.isActive)
            XCTAssertFalse(lane.isMCPOriginated)
        }
    }

    func testFailedFirstSaveKeepsTheLaneForRecoveryWithoutLinkProof() async throws {
        enum SaveFailure: Error { case expected }
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let creatorID = UUID()
            viewModel.test_setAgentSessionSaver { _, _, _ in throw SaveFailure.expected }
            let outcome = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: creatorID, sessionName: "Recoverable lane",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .creationIncomplete(sessionID, tabID) = outcome else {
                return XCTFail("save failure unexpectedly proved a lane")
            }
            let lane = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertEqual(lane.activeAgentSessionID, sessionID)
            XCTAssertEqual(lane.createdByOverseerSessionID, creatorID)
            XCTAssertFalse(lane.restorationReadiness.isAuthoritative)
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == tabID && $0.activeAgentSessionID == sessionID
            } == true)
        }
    }

    func testRebindDuringHydrationDoesNotMarkReplacementAsCreatorOwned() async throws {
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let originalTabs = Set(fixture.window.workspaceManager.activeWorkspace?.composeTabs.map(\.id) ?? [])
            let replacementID = UUID()
            let creatorID = UUID()
            var reboundTabID: UUID?
            viewModel.test_setAfterDurableChildTabCreation {
                guard let tabID = fixture.window.workspaceManager.activeWorkspace?.composeTabs.first(where: {
                    !originalTabs.contains($0.id)
                })?.id else { return XCTFail("fresh tab was not published") }
                reboundTabID = tabID
                do {
                    _ = try await viewModel.test_rebindPersistentSession(
                        replacementID, to: viewModel.session(for: tabID)
                    )
                } catch { XCTFail("test rebind failed: \(error)") }
            }
            defer { viewModel.test_setAfterDurableChildTabCreation(nil) }
            let outcome = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: creatorID, sessionName: "Rebound lane",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            let tabID = try XCTUnwrap(reboundTabID)
            guard case let .creationIncomplete(sessionID, publishedTabID) = outcome else {
                return XCTFail("rebound lane unexpectedly received a first-save proof")
            }
            XCTAssertEqual(publishedTabID, tabID)
            XCTAssertNotEqual(sessionID, replacementID)
            let replacement = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertEqual(replacement.activeAgentSessionID, replacementID)
            XCTAssertNil(replacement.createdByOverseerSessionID)
        }
    }

    func testConfigurationFailureAlsoRetainsTheCreatedLane() async throws {
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let creatorID = UUID()
            let invalidSelection = AgentSessionLanePolicy.RoleSelection(
                role: .pair, agentRaw: "unavailable-provider", modelRaw: "unavailable-model",
                reasoningEffortRaw: nil, modelParameterSelections: []
            )
            let outcome = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: creatorID, sessionName: "Recoverable configuration",
                selection: invalidSelection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .creationIncomplete(sessionID, tabID) = outcome else {
                return XCTFail("invalid configuration unexpectedly proved a lane")
            }
            let lane = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertEqual(lane.activeAgentSessionID, sessionID)
            XCTAssertEqual(lane.createdByOverseerSessionID, creatorID)
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == tabID && $0.activeAgentSessionID == sessionID
            } == true)
        }
    }

    func testCreatorLabelUsesLiveLaneBeforeSidebarIndexCatchesUp() async throws {
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let creatorID = UUID()
            var capturedLabel: String?
            viewModel.test_afterOversightLaneProvision = { tabID in
                guard let sessionID = viewModel.sessions[tabID]?.activeAgentSessionID else {
                    return XCTFail("published lane missing a session")
                }
                XCTAssertNil(viewModel.test_ownerValidatedSessionIndex[sessionID])
                capturedLabel = viewModel.agentSessionLinkLaneCreatorLabel(for: sessionID)
            }
            defer { viewModel.test_afterOversightLaneProvision = nil }
            _ = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: creatorID, sessionName: "Fresh label",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            XCTAssertEqual(capturedLabel, AgentMonitorSessionIDFormatter.short(creatorID))
        }
    }

    func testRetireBindingCountIgnoresInactiveWindowCopyButKeepsActivePeer() async throws {
        try await withFixture(ephemeral: false) { fixture in
            let outcome = try await fixture.window.agentModeViewModel.mcpCreateOversightLane(
                creatorSessionID: UUID(), sessionName: "Retirable lane",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .created(sessionID, tabID, _) = outcome else {
                return XCTFail("fresh lane did not establish its binding")
            }
            let viewModel = fixture.window.agentModeViewModel
            let endpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: tabID))
            let uniquelyBound = { WindowStatesManager.shared.agentSessionLinkBindingCount(sessionID: sessionID) == 1 }
            XCTAssertTrue(uniquelyBound())
            try await withSecondRegisteredWindow { second in
                let originalWorkspace = try XCTUnwrap(second.workspaceManager.activeWorkspace)
                let copy = try XCTUnwrap(second.workspaceManager.workspace(withID: fixture.workspaceID))
                XCTAssertNotEqual(second.workspaceManager.activeWorkspaceID, fixture.workspaceID)
                XCTAssertEqual(
                    WindowStatesManager.shared.agentSessionLinkBindingCount(sessionID: sessionID), 1,
                    "an inactive copy of the same workspace/tab is not a second binding"
                )
                await second.workspaceManager.switchWorkspace(
                    to: copy, saveState: false, reason: "retireBindingCountTest"
                )
                XCTAssertEqual(
                    WindowStatesManager.shared.agentSessionLinkBindingCount(sessionID: sessionID), 2,
                    "an active peer window must still block retirement"
                )
                let blocked = await WindowStatesManager.shared.agentSessionLinkRetireLane(
                    endpoint: endpoint, commit: false, isStillRetirable: uniquelyBound
                )
                XCTAssertFalse(blocked)
                await second.workspaceManager.switchWorkspace(
                    to: originalWorkspace, saveState: false, reason: "retireBindingCountTest"
                )
                XCTAssertTrue(uniquelyBound())
                let claim = try XCTUnwrap(WindowStatesManager.shared.agentSessionLinkClaimLaneRetirement(endpoint: endpoint))
                let retired = await WindowStatesManager.shared.agentSessionLinkRetireLane(
                    endpoint: endpoint, commit: true, isStillRetirable: uniquelyBound
                )
                WindowStatesManager.shared.agentSessionLinkReleaseLaneRetirement(endpoint: endpoint, claimID: claim)
                XCTAssertTrue(retired)
                XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.stashedTabs.contains(where: {
                    $0.tab.id == tabID
                }) == true)
                XCTAssertFalse(second.workspaceManager.workspace(withID: fixture.workspaceID)?.composeTabs.contains(where: {
                    $0.id == tabID
                }) == true, "retirement must reconcile the inactive peer before activation")
                let reopened = await second.workspaceManager.switchWorkspace(
                    to: copy, saveState: false, reason: "retireBindingCountTest"
                )
                XCTAssertEqual(reopened, .switched)
                XCTAssertEqual(second.workspaceManager.activeWorkspaceID, fixture.workspaceID)
                XCTAssertFalse(second.workspaceManager.activeWorkspace?.composeTabs.contains(where: {
                    $0.id == tabID
                }) == true, "activating a stale catalog copy must reload the retired binding")
            }
        }
    }

    func testRetirementClaimFencesPendingAndNewWorkspaceActivations() async throws {
        try await withFixture(ephemeral: false) { fixture in
            let outcome = try await fixture.window.agentModeViewModel.mcpCreateOversightLane(
                creatorSessionID: UUID(), sessionName: "Activation-fenced lane",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .created(_, tabID, _) = outcome else {
                return XCTFail("fresh lane did not establish its binding")
            }
            let endpoint = try XCTUnwrap(fixture.window.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: tabID))
            try await withSecondRegisteredWindow { second in
                let originalWorkspace = try XCTUnwrap(second.workspaceManager.activeWorkspace)
                let copy = try XCTUnwrap(second.workspaceManager.workspace(withID: fixture.workspaceID))
                let activationLoaded = expectation(description: "peer loaded workspace before publication")
                var releaseActivation: CheckedContinuation<Void, Never>?
                second.workspaceManager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting { id in
                    guard id == fixture.workspaceID else { return }
                    await withCheckedContinuation { continuation in
                        releaseActivation = continuation
                        activationLoaded.fulfill()
                    }
                }
                let switching = Task {
                    await second.workspaceManager.switchWorkspace(
                        to: copy, saveState: false, reason: "retirementActivationFenceTest"
                    )
                }
                await fulfillment(of: [activationLoaded], timeout: 3)
                XCTAssertNil(WindowStatesManager.shared.agentSessionLinkClaimLaneRetirement(endpoint: endpoint))
                releaseActivation?.resume()
                let firstSwitch = await switching.value
                XCTAssertEqual(firstSwitch, .switched)
                second.workspaceManager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting(nil)
                XCTAssertEqual(WindowStatesManager.shared.agentSessionLinkBindingCount(sessionID: endpoint.sessionID), 2)

                let switchedAway = await second.workspaceManager.switchWorkspace(
                    to: originalWorkspace, saveState: false, reason: "retirementActivationFenceTest"
                )
                XCTAssertEqual(switchedAway, .switched)
                let claim = try XCTUnwrap(WindowStatesManager.shared.agentSessionLinkClaimLaneRetirement(endpoint: endpoint))
                let blocked = await second.workspaceManager.switchWorkspace(
                    to: copy, saveState: false, reason: "retirementActivationFenceTest"
                )
                XCTAssertFalse(blocked.didSwitch)
                WindowStatesManager.shared.agentSessionLinkReleaseLaneRetirement(endpoint: endpoint, claimID: claim)
                let switchedAfterRelease = await second.workspaceManager.switchWorkspace(
                    to: copy, saveState: false, reason: "retirementActivationFenceTest"
                )
                XCTAssertEqual(switchedAfterRelease, .switched)
            }
        }
    }

    func testRetireBindingCountKeepsEphemeralInactiveWindowCopy() async throws {
        try await withFixture { fixture in
            let outcome = try await fixture.window.agentModeViewModel.mcpCreateOversightLane(
                creatorSessionID: UUID(), sessionName: "Ephemeral lane",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .created(sessionID, _, _) = outcome else {
                return XCTFail("fresh lane did not establish its binding")
            }
            try await withSecondRegisteredWindow { second in
                let copy = try XCTUnwrap(fixture.window.workspaceManager.workspace(withID: fixture.workspaceID))
                second.workspaceManager.workspaces.append(copy)
                XCTAssertEqual(
                    WindowStatesManager.shared.agentSessionLinkBindingCount(sessionID: sessionID), 2,
                    "an ephemeral copy can reopen without a canonical reload and must block retirement"
                )
            }
        }
    }

    func testBindingCountIncludesInactiveWorkspaceWithoutHydration() async throws {
        try await withFixture { fixture in
            let sessionID = UUID()
            let activeIndex = try XCTUnwrap(fixture.window.workspaceManager.workspaces.firstIndex {
                $0.id == fixture.workspaceID
            })
            fixture.window.workspaceManager.workspaces[activeIndex].composeTabs.append(
                ComposeTabState(id: UUID(), name: "Active", activeAgentSessionID: sessionID)
            )
            let inactive = fixture.window.workspaceManager.createWorkspace(
                name: "Inactive duplicate", repoPaths: [fixture.root.path], ephemeral: true
            )
            let inactiveIndex = try XCTUnwrap(fixture.window.workspaceManager.workspaces.firstIndex {
                $0.id == inactive.id
            })
            let hiddenTabID = UUID()
            fixture.window.workspaceManager.workspaces[inactiveIndex].composeTabs.append(
                ComposeTabState(id: hiddenTabID, name: "Hidden", activeAgentSessionID: sessionID)
            )
            XCTAssertEqual(fixture.window.workspaceManager.activeWorkspaceID, fixture.workspaceID)
            XCTAssertNil(fixture.window.agentModeViewModel.sessions[hiddenTabID])
            XCTAssertEqual(WindowStatesManager.shared.agentSessionLinkBindingCount(sessionID: sessionID), 2)
        }
    }

    func testChildRetirementInventoryKeepsActiveDuplicatesAndNestedDescendants() {
        let parentID = UUID()
        let childID = UUID()
        let grandchildID = UUID()
        let finished = AgentSessionLaneChildRetirementRecord(
            sessionID: childID, parentSessionID: parentID, blocksRetirement: false
        )
        let activeDuplicate = AgentSessionLaneChildRetirementRecord(
            sessionID: childID, parentSessionID: parentID, blocksRetirement: true
        )
        let activeGrandchild = AgentSessionLaneChildRetirementRecord(
            sessionID: grandchildID, parentSessionID: childID, blocksRetirement: true
        )
        XCTAssertFalse(AgentSessionLaneChildRetirementRecord.hasBlockingDescendant(of: parentID, in: [finished]))
        for records in [[finished, activeDuplicate], [activeDuplicate, finished], [finished, activeGrandchild]] {
            XCTAssertTrue(AgentSessionLaneChildRetirementRecord.hasBlockingDescendant(of: parentID, in: records))
        }
    }

    func testCreatedLaneRetirementStashesFinishedChildrenAndRefusesRunningChild() async throws {
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let created = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: UUID(), sessionName: "Parent lane",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .created(parentID, parentTabID, _) = created else {
                return XCTFail("fresh lane did not establish its binding")
            }
            let childTarget = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: nil, createIfNeeded: true, sessionName: "Child",
                parentSessionID: parentID, expectedWorkspaceID: fixture.workspaceID
            )
            viewModel.mcpAcceptSessionTarget(childTarget)
            let child = try XCTUnwrap(viewModel.sessions[childTarget.tabID])
            let childID = try XCTUnwrap(child.activeAgentSessionID)
            let endpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: parentTabID))
            let childrenSettled = {
                !WindowStatesManager.shared.agentSessionLinkHasActiveChildSessions(parentSessionID: parentID)
            }

            child.runState = .running
            XCTAssertFalse(childrenSettled())
            let blocked = await WindowStatesManager.shared.agentSessionLinkRetireLane(
                endpoint: endpoint, commit: true, isStillRetirable: childrenSettled
            )
            XCTAssertFalse(blocked)
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains {
                $0.id == parentTabID
            } == true)

            child.runState = .completed
            child.isDirty = true
            await viewModel.flushSave(for: child.tabID)
            let grandchildTarget = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: nil, createIfNeeded: true, sessionName: "Grandchild",
                parentSessionID: childID, expectedWorkspaceID: fixture.workspaceID
            )
            viewModel.mcpAcceptSessionTarget(grandchildTarget)
            let grandchild = try XCTUnwrap(viewModel.sessions[grandchildTarget.tabID])
            grandchild.runState = .waitingForApproval
            XCTAssertFalse(childrenSettled(), "an active grandchild must also block the stash cascade")
            grandchild.runState = .completed
            grandchild.isDirty = true
            await viewModel.flushSave(for: grandchild.tabID)
            XCTAssertTrue(childrenSettled(), "finished children must not block retirement")
            let persistedBlocker = await WindowStatesManager.shared.agentSessionLinkHasPersistedActiveChildSessions(
                parentSessionID: parentID
            )
            XCTAssertFalse(persistedBlocker)
            let retired = await WindowStatesManager.shared.agentSessionLinkRetireLane(
                endpoint: endpoint, commit: true, isStillRetirable: childrenSettled
            )
            XCTAssertTrue(retired)
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            XCTAssertTrue(workspace.stashedTabs.contains { $0.tab.id == parentTabID })
            XCTAssertTrue(workspace.stashedTabs.contains { $0.tab.id == child.tabID })
            XCTAssertTrue(workspace.stashedTabs.contains { $0.tab.id == grandchild.tabID })
            XCTAssertFalse(workspace.composeTabs.contains { $0.id == child.tabID || $0.id == grandchild.tabID })
            let savedChild = try await AgentSessionDataService.shared.loadAgentSession(id: childID, for: workspace)
            let persistedChild = try XCTUnwrap(savedChild)
            XCTAssertEqual(persistedChild.id, childID)
            XCTAssertEqual(persistedChild.parentSessionID, parentID)
        }
    }

    func testRetirementJoinsDiskOnlyAncestryWithLiveGrandchildState() async throws {
        try await withFixture { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let created = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: UUID(), sessionName: "Mixed lineage",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .created(parentID, parentTabID, _) = created else {
                return XCTFail("parent creation failed")
            }
            let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            var diskOnlyChild = AgentSession(id: UUID(), name: "Disk-only connector", savedAt: Date())
            diskOnlyChild.parentSessionID = parentID
            diskOnlyChild.lastRunState = AgentSessionRunState.completed.rawValue
            _ = try await AgentSessionDataService.shared.saveAgentSession(diskOnlyChild, for: workspace)
            let target = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: nil, createIfNeeded: true, sessionName: "Live grandchild",
                parentSessionID: diskOnlyChild.id, expectedWorkspaceID: fixture.workspaceID
            )
            viewModel.mcpAcceptSessionTarget(target)
            let grandchild = try XCTUnwrap(viewModel.sessions[target.tabID])
            grandchild.runState = .completed
            grandchild.isDirty = true
            await viewModel.flushSave(for: target.tabID)
            XCTAssertNil(viewModel.test_ownerValidatedSessionIndex[diskOnlyChild.id])
            let endpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: parentTabID))
            grandchild.runState = .running // Disk still says completed.
            let blocked = await WindowStatesManager.shared.agentSessionLinkHasPersistedActiveChildSessions(
                parentSessionID: parentID
            )
            XCTAssertTrue(blocked)
            let refused = await WindowStatesManager.shared.agentSessionLinkRetireLane(
                endpoint: endpoint, commit: true, isStillRetirable: { true }
            )
            XCTAssertFalse(refused)
            grandchild.runState = .completed
            let retired = await WindowStatesManager.shared.agentSessionLinkRetireLane(
                endpoint: endpoint, commit: true, isStillRetirable: { true }
            )
            XCTAssertTrue(retired)
            XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.stashedTabs.contains {
                $0.tab.id == target.tabID
            } == true, "disk-only connector must also connect the stash cascade")
        }
    }

    func testRetirementRefusesFinishedDescendantBoundInActivePeerWithoutParent() async throws {
        try await withFixture(ephemeral: false) { fixture in
            let viewModel = fixture.window.agentModeViewModel
            let created = try await viewModel.mcpCreateOversightLane(
                creatorSessionID: UUID(), sessionName: "Parent",
                selection: fixture.selection, expectedWorkspaceID: fixture.workspaceID
            )
            guard case let .created(parentID, parentTabID, _) = created else { return XCTFail("parent creation failed") }
            let target = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: nil, createIfNeeded: true, sessionName: "Finished child",
                parentSessionID: parentID, expectedWorkspaceID: fixture.workspaceID
            )
            viewModel.mcpAcceptSessionTarget(target)
            let child = try XCTUnwrap(viewModel.sessions[target.tabID])
            child.runState = .completed
            child.isDirty = true
            await viewModel.flushSave(for: target.tabID)
            _ = await fixture.window.workspaceManager.pollAndSaveStateWithOutcomeAsync(
                workspaceID: fixture.workspaceID, source: WorkspaceSaveSource("retireChildTest")
            )
            let endpoint = try XCTUnwrap(viewModel.agentSessionLinkObserverEndpoint(tabID: parentTabID))
            try await withSecondRegisteredWindow { peer in
                let copy = try XCTUnwrap(peer.workspaceManager.workspace(withID: fixture.workspaceID))
                _ = await peer.workspaceManager.switchWorkspace(to: copy, saveState: false, reason: "retireChildTest")
                var projected = peer.workspaceManager.workspaces
                let index = try XCTUnwrap(projected.firstIndex { $0.id == fixture.workspaceID })
                projected[index].composeTabs.removeAll { $0.id == parentTabID }
                peer.workspaceManager.workspaces = projected
                XCTAssertEqual(WindowStatesManager.shared.agentSessionLinkBindingCount(sessionID: parentID), 1)
                let retired = await WindowStatesManager.shared.agentSessionLinkRetireLane(
                    endpoint: endpoint, commit: true, isStillRetirable: { true }
                )
                XCTAssertFalse(retired)
                XCTAssertTrue(peer.workspaceManager.activeWorkspace?.composeTabs.contains { $0.id == target.tabID } == true)
                XCTAssertTrue(fixture.window.workspaceManager.activeWorkspace?.composeTabs.contains { $0.id == parentTabID } == true)
            }
        }
    }

    func testPersistedActiveChildAbsentFromLiveSessionsAndSidebarIndexStillBlocksRetirement() async throws {
        try await withFixture { fixture in
            let dataService = AgentSessionDataService.shared
            await dataService.test_setWorkspaceRootOverride(fixture.root)
            do {
                let parentID = UUID()
                var child = AgentSession(id: UUID(), name: "Unindexed child", savedAt: Date())
                child.parentSessionID = parentID
                child.lastRunState = AgentSessionRunState.running.rawValue
                let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
                _ = try await dataService.saveAgentSession(child, for: workspace)
                XCTAssertFalse(fixture.window.agentModeViewModel.sessions.values.contains {
                    $0.parentSessionID == parentID
                })
                XCTAssertFalse(fixture.window.agentModeViewModel.test_ownerValidatedSessionIndex.values.contains {
                    $0.parentSessionID == parentID
                })
                let hasPersistedChild = await WindowStatesManager.shared.agentSessionLinkHasPersistedActiveChildSessions(
                    parentSessionID: parentID
                )
                XCTAssertTrue(hasPersistedChild)
            } catch {
                await dataService.test_setWorkspaceRootOverride(nil)
                throw error
            }
            await dataService.test_setWorkspaceRootOverride(nil)
        }
    }

    func testUnreadablePersistedChildAncestorCannotProveRetirementSafe() async throws {
        try await withFixture { fixture in
            let dataService = AgentSessionDataService.shared
            let protectedRoot = fixture.root.appendingPathComponent("protected", isDirectory: true)
            try FileManager.default.createDirectory(at: protectedRoot, withIntermediateDirectories: true)
            await dataService.test_setWorkspaceRootOverride(protectedRoot)
            do {
                let parentID = UUID()
                var child = AgentSession(id: UUID(), name: "Unindexed child", savedAt: Date())
                child.parentSessionID = parentID
                child.lastRunState = AgentSessionRunState.running.rawValue
                let workspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
                _ = try await dataService.saveAgentSession(child, for: workspace)
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: protectedRoot.path)
                defer {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o700], ofItemAtPath: protectedRoot.path
                    )
                }
                do {
                    _ = try await dataService.persistedChildRetirementRecords(workspace: workspace)
                    XCTFail("inaccessible inventory was treated as child-free")
                } catch {}
                let retirementBlocked = await WindowStatesManager.shared.agentSessionLinkHasPersistedActiveChildSessions(
                    parentSessionID: parentID
                )
                XCTAssertTrue(retirementBlocked)
            } catch {
                await dataService.test_setWorkspaceRootOverride(nil)
                throw error
            }
            await dataService.test_setWorkspaceRootOverride(nil)
        }
    }
}
