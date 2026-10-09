import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSecureStorage
import XCTest

@MainActor
final class AgentSessionLifecycleAuthorityContractTests: XCTestCase {
    func testCanonicalPresenceRearmsMissingWorkspaceRepair() {
        let authority = AgentSessionLifecycleAuthority()
        let tab = ComposeTabState(isPinned: true)
        let workspace = WorkspaceModel(name: "Protected", repoPaths: [], composeTabs: [tab], activeComposeTabID: tab.id)
        let claim = AgentSessionLifecycleAuthority.ProtectionClaim(
            identity: .init(workspaceID: workspace.id, tabID: tab.id, sessionID: nil, persistentBindingGeneration: nil, bindingTransitionGeneration: 0),
            tab: tab, isLive: false, isActive: true, isPinned: true, hasActiveRun: false
        )
        func reconcile(_ projected: [WorkspaceModel], baseline: AgentSessionLifecycleAuthority.ProjectionRepairBaseline) -> AgentSessionLifecycleAuthority.ProjectionOutcome {
            authority.reconcileProjection(projectedWorkspaces: projected, currentWorkspaces: [workspace], claims: [claim], repairBaselines: [workspace.id: baseline])
        }
        XCTAssertEqual(reconcile([], baseline: .absent).newlyRequiredRepairWorkspaceIDs, [workspace.id])
        XCTAssertTrue(reconcile([], baseline: .absent).newlyRequiredRepairWorkspaceIDs.isEmpty)
        XCTAssertTrue(reconcile([workspace], baseline: .working(revision: 1, digest: "restored")).newlyRequiredRepairWorkspaceIDs.isEmpty)
        XCTAssertEqual(reconcile([], baseline: .absent).newlyRequiredRepairWorkspaceIDs, [workspace.id])
    }

    func testAlreadySavedWorkspaceIsAdmittedWhenBindingIsCurrent() {
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
    }

    func testPersistedTargetWorkspaceIsAdmittedWhenBindingIsCurrent() {
        let authority = AgentSessionLifecycleAuthority()
        let workspaceID = UUID()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .persisted(
                    workspaceID: workspaceID,
                    stateVersion: 7
                ),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: true
            ),
            .commit
        )
    }

    func testRejectedPersistenceRollsBack() {
        let authority = AgentSessionLifecycleAuthority()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .rejected(reason: "save rejected"),
                targetWorkspaceID: UUID(),
                bindingStillCurrent: true
            ),
            .rollback(.workspacePersistenceRejected)
        )
    }

    func testStaleBindingRollsBackAfterAcceptedPersistence() {
        let authority = AgentSessionLifecycleAuthority()
        let workspaceID = UUID()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .notRequired(workspaceID: workspaceID),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: false
            ),
            .rollback(.sessionIdentityChanged)
        )
    }

    func testPersistedDifferentWorkspaceRollsBack() {
        let authority = AgentSessionLifecycleAuthority()
        let workspaceID = UUID()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .persisted(
                    workspaceID: UUID(),
                    stateVersion: 7
                ),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: true
            ),
            .rollback(.workspaceChanged)
        )
    }
}

#if DEBUG
    @MainActor
    final class AgentProjectionRepairIdempotenceTests: XCTestCase {
        func testUnrelatedProjectionsNotifyAndDirtyOnlyChangedRepairs() {
            var canonical = catalog(count: 2)
            let manager = makeManager(canonical, windowID: -701)
            protect(manager, count: 1)
            let protectedID = canonical[0].id
            var events = 0
            AgentSessionLifecycleAuthority.setEventObserverForTesting { _ in events += 1 }
            defer { AgentSessionLifecycleAuthority.setEventObserverForTesting(nil) }
            let initialVersion = manager.debugStateVersionForWorkspace(protectedID)
            project(canonical, to: manager, sequence: 1)
            XCTAssertEqual(events, 1)
            XCTAssertEqual(manager.debugStateVersionForWorkspace(protectedID), initialVersion + 1)
            let firstRepair = manager.workspaces[0].composeTabs
            for sequence in 2 ... 6 {
                canonical[1].name = "Unrelated \(sequence)"
                project(canonical, to: manager, sequence: UInt64(sequence))
            }
            XCTAssertEqual(manager.workspaces[0].composeTabs, firstRepair)
            XCTAssertEqual(events, 1, "Identical outstanding repairs must not log again")
            XCTAssertEqual(manager.debugStateVersionForWorkspace(protectedID), initialVersion + 1)

            manager.workspaces[0].composeTabs[0].promptText = "Changed protected payload"
            project(canonical, to: manager, sequence: 7)
            XCTAssertEqual(events, 2)
            XCTAssertEqual(manager.debugStateVersionForWorkspace(protectedID), initialVersion + 2)
            project(canonical, to: manager, sequence: 8)
            XCTAssertEqual(events, 2)

            // Higher canonical revision must re-arm even when damaged bytes repeat.
            project(canonical, to: manager, sequence: 9, protectedRevision: 2)
            XCTAssertEqual(events, 3)
            XCTAssertEqual(manager.debugStateVersionForWorkspace(protectedID), initialVersion + 3)
        }

        func testUnpinExpiresProtectionWithoutResurrectingOverlay() {
            let canonical = catalog(count: 2)
            let manager = makeManager(canonical, windowID: -702)
            protect(manager, count: 1)
            let protectedID = canonical[0].id
            project(canonical, to: manager, sequence: 1)
            let repairedVersion = manager.debugStateVersionForWorkspace(protectedID)
            manager.workspaces[0].composeTabs[0].isPinned = false
            project(canonical, to: manager, sequence: 2)
            XCTAssertEqual(manager.workspaces[0].composeTabs, canonical[0].composeTabs)
            XCTAssertEqual(manager.debugStateVersionForWorkspace(protectedID), repairedVersion)
            // Reacquiring a claim starts a new protection lifetime at the same baseline.
            manager.workspaces[0].composeTabs[0].isPinned = true
            project(canonical, to: manager, sequence: 3)
            XCTAssertEqual(manager.debugStateVersionForWorkspace(protectedID), repairedVersion + 1)
        }

        func testRepeatedProjectionAtThreeWindowScaleStaysWithinBudget() {
            var canonical = catalog(count: 300)
            let managers = (0 ..< 3).map { makeManager(canonical, windowID: -710 - $0) }
            for manager in managers {
                protect(manager, count: 25, liveCount: 5)
                project(canonical, to: manager, sequence: 1)
            }
            let versions = managers.map { manager in
                canonical.prefix(25).map { manager.debugStateVersionForWorkspace($0.id) }
            }
            var events = 0
            AgentSessionLifecycleAuthority.setEventObserverForTesting { _ in events += 1 }
            defer { AgentSessionLifecycleAuthority.setEventObserverForTesting(nil) }
            let clock = ContinuousClock()
            let start = clock.now
            for sequence in 2 ... 21 {
                canonical[299].name = "Unrelated \(sequence)"
                for manager in managers {
                    project(canonical, to: manager, sequence: UInt64(sequence))
                }
            }
            let elapsed = start.duration(to: clock.now)
            let bumps = managers.enumerated().reduce(0) { total, item in
                total + canonical.prefix(25).enumerated().reduce(0) { subtotal, workspace in
                    subtotal + item.element.debugStateVersionForWorkspace(workspace.element.id) - versions[item.offset][workspace.offset]
                }
            }
            print("PROJECTION_SCALE windows=3 chats=300 protectedPerWindow=25 passes=60 elapsed=\(elapsed) diagnostics=\(events) dirtyBumps=\(bumps)")
            XCTAssertEqual(events, 0)
            XCTAssertEqual(bumps, 0)
            XCTAssertLessThan(elapsed, .seconds(5))
            for manager in managers {
                XCTAssertTrue(manager.workspaces.prefix(25).allSatisfy { $0.composeTabs[0].isPinned })
            }
        }

        private func catalog(count: Int) -> [WorkspaceModel] {
            (0 ..< count).map { index in
                var workspace = WorkspaceModel(name: "Workspace \(index)", repoPaths: [])
                let tab = ComposeTabState(
                    lastModified: Date(timeIntervalSince1970: 100),
                    activeChatSessionID: UUID(),
                    activeAgentSessionID: UUID(),
                    promptText: String(repeating: "Fixture prompt ", count: 20)
                )
                workspace.composeTabs = [tab, ComposeTabState(lastModified: tab.lastModified)]
                workspace.activeComposeTabID = tab.id
                return workspace
            }
        }

        private func protect(_ manager: WorkspaceManagerViewModel, count: Int, liveCount: Int = 0) {
            for index in 0 ..< count {
                manager.workspaces[index].composeTabs[0].isPinned = true
                manager.workspaces[index].composeTabs[0].lastModified = Date(timeIntervalSince1970: 200)
            }
            let authority = AgentSessionLifecycleAuthority()
            let liveIDs = Set(manager.workspaces.prefix(liveCount).map(\.id))
            manager.setAgentSessionProjectionReconciler { projected, current, repairBaselines in
                let claims = current.flatMap { workspace in
                    workspace.composeTabs.map { tab in
                        AgentSessionLifecycleAuthority.ProtectionClaim(
                            identity: .init(workspaceID: workspace.id, tabID: tab.id, sessionID: tab.activeAgentSessionID, persistentBindingGeneration: nil, bindingTransitionGeneration: 0),
                            tab: tab,
                            isLive: liveIDs.contains(workspace.id) && tab.id == workspace.activeComposeTabID,
                            isActive: tab.id == workspace.activeComposeTabID,
                            isPinned: tab.isPinned,
                            hasActiveRun: false
                        )
                    }
                }
                return authority.reconcileProjection(projectedWorkspaces: projected, currentWorkspaces: current, claims: claims, repairBaselines: repairBaselines)
            }
        }

        private func project(_ canonical: [WorkspaceModel], to manager: WorkspaceManagerViewModel, sequence: UInt64, protectedRevision: UInt64 = 1) {
            manager.applyDomainWorkspaceProjection(
                canonical,
                fileURLsByWorkspaceID: [:],
                revisionsByWorkspaceID: Dictionary(uniqueKeysWithValues: canonical.enumerated().map { index, workspace in
                    (workspace.id, DomainRevisionState(workingRevision: index == canonical.count - 1 ? sequence : protectedRevision, savedRevision: 0, dirtyRevision: 1))
                }),
                digestsByWorkspaceID: Dictionary(uniqueKeysWithValues: canonical.enumerated().map { index, workspace in
                    (workspace.id, index == canonical.count - 1 ? "unrelated-\(sequence)" : "protected-\(protectedRevision)")
                }),
                healthByWorkspaceID: [:],
                catalogRevision: sequence,
                preferredActiveWorkspaceID: nil,
                publicationSequence: sequence
            )
        }

        private func makeManager(_ workspaces: [WorkspaceModel], windowID: Int) -> WorkspaceManagerViewModel {
            let files = WorkspaceFilesViewModel()
            let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
            let settings = APISettingsViewModel(aiQueriesService: AIQueriesService(keyManager: keyManager), keyManager: keyManager, loadStoredDataOnInit: false)
            let prompt = PromptViewModel(fileManager: files, apiSettingsViewModel: settings, windowID: windowID, settingsManager: WindowSettingsManager(windowID: windowID))
            let manager = WorkspaceManagerViewModel(fileManager: files, promptViewModel: prompt, performInitialWorkspaceActivation: false)
            manager.workspaces = workspaces
            return manager
        }
    }
#endif
