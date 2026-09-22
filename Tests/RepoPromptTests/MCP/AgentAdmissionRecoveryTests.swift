@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class AgentAdmissionRecoveryTests: XCTestCase {
        private actor RecoveryCoalescingGate {
            private var firstCallerSuspended = false
            private var firstCallerReleased = false
            private var coalescedCallerObserved = false
            private var firstCallerSuspensionWaiters: [CheckedContinuation<Void, Never>] = []
            private var firstCallerReleaseWaiters: [CheckedContinuation<Void, Never>] = []
            private var coalescedCallerWaiters: [CheckedContinuation<Void, Never>] = []

            func suspendFirstCaller() async {
                firstCallerSuspended = true
                firstCallerSuspensionWaiters.forEach { $0.resume() }
                firstCallerSuspensionWaiters.removeAll()
                guard !firstCallerReleased else { return }
                await withCheckedContinuation { continuation in
                    firstCallerReleaseWaiters.append(continuation)
                }
            }

            func waitUntilFirstCallerIsSuspended() async {
                guard !firstCallerSuspended else { return }
                await withCheckedContinuation { continuation in
                    firstCallerSuspensionWaiters.append(continuation)
                }
            }

            func observeCoalescedCaller() {
                coalescedCallerObserved = true
                coalescedCallerWaiters.forEach { $0.resume() }
                coalescedCallerWaiters.removeAll()
            }

            func waitUntilCoalescedCallerIsObserved() async {
                guard !coalescedCallerObserved else { return }
                await withCheckedContinuation { continuation in
                    coalescedCallerWaiters.append(continuation)
                }
            }

            func releaseFirstCaller() {
                firstCallerReleased = true
                firstCallerReleaseWaiters.forEach { $0.resume() }
                firstCallerReleaseWaiters.removeAll()
            }
        }

        private actor RecoveryInterleavingGate {
            private var started = false
            private var released = false
            private var startWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func markStarted() {
                started = true
                let waiters = startWaiters
                startWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }

            func markStartedAndWaitForRelease() async {
                markStarted()
                guard !released else { return }
                await withCheckedContinuation { releaseWaiters.append($0) }
            }

            func waitUntilStarted() async {
                guard !started else { return }
                await withCheckedContinuation { startWaiters.append($0) }
            }

            func release() {
                released = true
                let waiters = releaseWaiters
                releaseWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        private actor CancellationIgnoringReleaseFence {
            private var entered = false
            private var released = false
            private var entryWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func enterAndWaitIgnoringCancellationUntilRelease() async {
                entered = true
                entryWaiters.forEach { $0.resume() }
                entryWaiters.removeAll()
                guard !released else { return }
                await withCheckedContinuation { releaseWaiters.append($0) }
            }

            func waitUntilEntered() async {
                guard !entered else { return }
                await withCheckedContinuation { entryWaiters.append($0) }
            }

            func release() {
                released = true
                releaseWaiters.forEach { $0.resume() }
                releaseWaiters.removeAll()
            }
        }

        private var originalMCPAutoStart = false
        private var originalStoragePath: String?
        private var storageRoot: URL!
        private var managers: [WorkspaceManagerViewModel] = []
        private var runtimes: [MCPDomainRuntime] = []

        override func setUp() async throws {
            try await super.setUp()
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            originalStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("AgentAdmissionRecoveryTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            UserDefaults.standard.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
        }

        override func tearDown() async throws {
            managers.forEach { $0.prepareForWindowClose() }
            managers.removeAll()
            for runtime in runtimes {
                _ = await runtime.shutdown()
            }
            runtimes.removeAll()
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
            try? FileManager.default.removeItem(at: storageRoot)
            if let originalStoragePath {
                UserDefaults.standard.set(originalStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
            }
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            try await super.tearDown()
        }

        func testDurableAdmissionDecisionUsesExactCommitBoundary() {
            let authority = AgentSessionLifecycleAuthority()
            let workspaceID = UUID()
            let saved = AgentAdmissionPersistenceReceipt(
                outcome: .rejected(reason: "cancelled"),
                commitEvidence: .saved(revision: 7, digest: "saved-digest")
            )
            let canonicalWorking = AgentAdmissionPersistenceReceipt(
                outcome: .rejected(reason: "persistence_failure"),
                commitEvidence: .canonicalWorking(revision: 8, digest: "working-digest")
            )
            let noCommit = AgentAdmissionPersistenceReceipt(
                outcome: .rejected(reason: "cancelled"),
                commitEvidence: .none
            )

            XCTAssertEqual(
                authority.decideDurableAdmission(
                    receipt: noCommit,
                    targetWorkspaceID: workspaceID,
                    bindingStillCurrent: true,
                    isCancelled: true
                ),
                .localRollback(.cancelled)
            )
            XCTAssertEqual(
                authority.decideDurableAdmission(
                    receipt: noCommit,
                    targetWorkspaceID: workspaceID,
                    bindingStillCurrent: true,
                    isCancelled: false
                ),
                .localRollback(.workspacePersistenceRejected)
            )
            XCTAssertEqual(
                authority.decideDurableAdmission(
                    receipt: AgentAdmissionPersistenceReceipt(
                        outcome: .persisted(workspaceID: workspaceID, stateVersion: 3),
                        commitEvidence: .none
                    ),
                    targetWorkspaceID: workspaceID,
                    bindingStillCurrent: true,
                    isCancelled: false
                ),
                .recoverWorkspace(.workspacePersistenceRejected),
                "A successful write with unavailable verification is durability-uncertain."
            )
            XCTAssertEqual(
                authority.decideDurableAdmission(
                    receipt: saved,
                    targetWorkspaceID: workspaceID,
                    bindingStillCurrent: true,
                    isCancelled: true
                ),
                .recoverWorkspace(.cancelled)
            )
            XCTAssertEqual(
                authority.decideDurableAdmission(
                    receipt: saved,
                    targetWorkspaceID: workspaceID,
                    bindingStillCurrent: false,
                    isCancelled: false
                ),
                .recoverWorkspace(.sessionIdentityChanged)
            )
            XCTAssertEqual(
                authority.decideDurableAdmission(
                    receipt: canonicalWorking,
                    targetWorkspaceID: workspaceID,
                    bindingStillCurrent: true,
                    isCancelled: false
                ),
                .recoverWorkspace(.workspacePersistenceRejected)
            )
            XCTAssertEqual(
                authority.decideDurableAdmission(
                    receipt: AgentAdmissionPersistenceReceipt(
                        outcome: .persisted(workspaceID: UUID(), stateVersion: 1),
                        commitEvidence: .saved(revision: 1, digest: "wrong-workspace")
                    ),
                    targetWorkspaceID: workspaceID,
                    bindingStillCurrent: true,
                    isCancelled: false
                ),
                .recoverWorkspace(.workspaceChanged)
            )
            XCTAssertEqual(
                authority.decideDurableAdmission(
                    receipt: AgentAdmissionPersistenceReceipt(
                        outcome: .notRequired(workspaceID: workspaceID),
                        commitEvidence: .none
                    ),
                    targetWorkspaceID: workspaceID,
                    bindingStillCurrent: true,
                    isCancelled: false
                ),
                .commit
            )
            XCTAssertEqual(
                authority.decideDurableAdmission(
                    receipt: saved,
                    targetWorkspaceID: workspaceID,
                    bindingStillCurrent: true,
                    isCancelled: false
                ),
                .commit,
                "Verified saved evidence must survive a lost or cancelled persistence response."
            )
        }

        func testPersistedStopResolutionRejectsWorkspaceSwitchAcrossSuspension() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let viewModel = makeAgentModeViewModel(for: fixture)
            let sessionID = UUID()
            _ = try await AgentSessionDataService.shared.saveAgentSession(
                AgentSession(
                    id: sessionID,
                    workspaceID: fixture.workspaceA.id,
                    composeTabID: fixture.rightTab.id,
                    name: "Persisted stop resolution",
                    savedAt: Date(timeIntervalSince1970: 1_800_000_600),
                    itemCount: 0,
                    autoEditEnabled: false
                ),
                for: fixture.workspaceA,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0
            )
            let gate = RecoveryInterleavingGate()
            viewModel.test_setAfterMCPPersistedSessionResolution { workspaceID in
                XCTAssertEqual(workspaceID, fixture.workspaceA.id)
                await gate.markStartedAndWaitForRelease()
            }
            defer { viewModel.test_setAfterMCPPersistedSessionResolution(nil) }

            let resolution = Task { @MainActor in
                try await viewModel.mcpResolveSessionID(
                    reference: sessionID.uuidString,
                    workspace: fixture.workspaceA
                )
            }
            await gate.waitUntilStarted()
            fixture.manager.activeWorkspace = fixture.workspaceB
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceB)
            await gate.release()

            do {
                _ = try await resolution.value
                XCTFail("A stop lookup must not survive an active-workspace switch.")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains("active workspace changed"),
                    String(describing: error)
                )
            }
        }

        func testProvisionalAdmissionClaimTransitionsAreClosedAndMonotonic() {
            let identity = AgentProvisionalAdmissionIdentity(
                recoveryID: UUID(),
                workspaceID: UUID(),
                tabID: UUID(),
                sessionID: UUID(),
                replacementTabID: UUID()
            )
            let recovered = AgentProvisionalAdmissionClaim(identity: identity)

            XCTAssertEqual(recovered.state, .provisional)
            XCTAssertTrue(recovered.beginWorkspaceRecovery())
            XCTAssertEqual(recovered.state, .recoveringWorkspace)
            XCTAssertFalse(recovered.beginWorkspaceRecovery())
            XCTAssertTrue(recovered.markWorkspaceRecovered())
            XCTAssertEqual(recovered.state, .workspaceRecovered)
            XCTAssertTrue(recovered.markComplete())
            XCTAssertEqual(recovered.state, .complete)
            XCTAssertFalse(recovered.markAccepted())
            XCTAssertFalse(recovered.beginWorkspaceRecovery())

            let accepted = AgentProvisionalAdmissionClaim(identity: AgentProvisionalAdmissionIdentity(
                recoveryID: UUID(),
                workspaceID: identity.workspaceID,
                tabID: UUID(),
                sessionID: UUID(),
                replacementTabID: UUID()
            ))
            XCTAssertTrue(accepted.markAccepted())
            XCTAssertEqual(accepted.state, .accepted)
            XCTAssertFalse(accepted.beginWorkspaceRecovery())
            XCTAssertFalse(accepted.markComplete())

            let blocked = AgentProvisionalAdmissionClaim(identity: identity)
            XCTAssertTrue(blocked.beginWorkspaceRecovery())
            XCTAssertTrue(blocked.markBlockedForManualRecovery(.unrecoverableDocument))
            XCTAssertEqual(blocked.state, .blockedManual(.unrecoverableDocument))
            XCTAssertFalse(blocked.markComplete())
            XCTAssertTrue(blocked.resumeBlockedWorkspaceRecovery())
            XCTAssertEqual(blocked.state, .recoveringWorkspace)
            XCTAssertTrue(blocked.markWorkspaceRecovered())
            XCTAssertTrue(blocked.markComplete())
        }

        func testPersistedAdmissionWithUnavailableVerificationEntersFencedRecovery() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            fixture.manager.setAgentAdmissionPersistenceVerificationHandlerForTesting { workspaceID in
                XCTAssertEqual(workspaceID, fixture.workspaceA.id)
                return false
            }

            let receipt = await fixture.manager.persistAgentAdmission(fixture.identity)

            guard case .persisted = receipt.outcome else {
                return XCTFail("Expected the injected verification loss after persistence: \(receipt.outcome)")
            }
            XCTAssertEqual(receipt.commitEvidence, .none)
            XCTAssertEqual(
                AgentSessionLifecycleAuthority().decideDurableAdmission(
                    receipt: receipt,
                    targetWorkspaceID: fixture.workspaceA.id,
                    bindingStillCurrent: true,
                    isCancelled: false
                ),
                .recoverWorkspace(.workspacePersistenceRejected)
            )

            fixture.manager.setAgentAdmissionPersistenceVerificationHandlerForTesting(nil)
            let recovered = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)
            guard case .recovered = recovered else {
                return XCTFail("Expected fenced recovery after verification loss, got \(recovered)")
            }
            let disk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            XCTAssertFalse(disk.composeTabs.contains {
                $0.id == fixture.identity.tabID
                    && $0.activeAgentSessionID == fixture.identity.sessionID
            })
        }

        func testActiveRecoveryIsStructurallyNarrowAndPersistsExactRemoval() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let unrelatedDiskBefore = try Data(contentsOf: fixture.workspaceBURL)
            let unrelatedBefore = fixture.manager.workspace(withID: fixture.workspaceB.id)

            let receipt = await fixture.manager.persistAgentAdmission(fixture.identity)
            guard case .saved = receipt.commitEvidence else {
                return XCTFail("Expected saved admission evidence, got \(receipt.commitEvidence)")
            }
            let canonicalBeforeRecovery = try await canonicalModel(fixture)

            let outcome = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)
            guard case .recovered = outcome else {
                return XCTFail("Expected recovery, got \(outcome)")
            }

            let canonical = try await canonicalModel(fixture)
            let disk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            let managerWorkspace = try XCTUnwrap(fixture.manager.workspace(withID: fixture.workspaceA.id))
            for recovered in [canonical, disk, managerWorkspace] {
                XCTAssertFalse(recovered.composeTabs.contains { $0.id == fixture.identity.tabID })
                XCTAssertFalse(recovered.composeTabs.contains {
                    $0.activeAgentSessionID == fixture.identity.sessionID
                })
                XCTAssertEqual(recovered.composeTabs.map(\.id), [fixture.leftTab.id, fixture.rightTab.id])
                XCTAssertEqual(recovered.activeComposeTabID, fixture.rightTab.id)
                assertNonComposeFieldsEqual(recovered, canonicalBeforeRecovery)
            }
            XCTAssertEqual(
                fixture.prompt.currentComposeTabs.map(\.id),
                [fixture.leftTab.id, fixture.rightTab.id]
            )
            XCTAssertEqual(fixture.prompt.activeComposeTabID, fixture.rightTab.id)
            XCTAssertEqual(fixture.manager.workspace(withID: fixture.workspaceB.id), unrelatedBefore)
            XCTAssertEqual(try Data(contentsOf: fixture.workspaceBURL), unrelatedDiskBefore)
            let snapshotValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let snapshot = try XCTUnwrap(snapshotValue)
            XCTAssertNil(snapshot.revisions.dirtyRevision)
        }

        func testInactiveRecoveryLeavesActivePromptAndWorkspaceUnchanged() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceB
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceB)
            let promptTabsBefore = fixture.prompt.currentComposeTabs
            let promptActiveBefore = fixture.prompt.activeComposeTabID
            let activeWorkspaceBefore = fixture.manager.workspace(withID: fixture.workspaceB.id)
            let activeDiskBefore = try Data(contentsOf: fixture.workspaceBURL)

            let outcome = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)
            guard case .recovered = outcome else {
                return XCTFail("Expected recovery, got \(outcome)")
            }

            XCTAssertEqual(fixture.prompt.currentComposeTabs, promptTabsBefore)
            XCTAssertEqual(fixture.prompt.activeComposeTabID, promptActiveBefore)
            XCTAssertEqual(fixture.manager.activeWorkspaceID, fixture.workspaceB.id)
            XCTAssertEqual(fixture.manager.workspace(withID: fixture.workspaceB.id), activeWorkspaceBefore)
            XCTAssertEqual(try Data(contentsOf: fixture.workspaceBURL), activeDiskBefore)
            let recoveredCanonical = try await canonicalModel(fixture)
            XCTAssertFalse(recoveredCanonical.composeTabs.contains {
                $0.id == fixture.identity.tabID
            })
        }

        func testActiveRecoveryPreservesUnrelatedLivePromptProjectionEdits() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            var liveWorkspace = fixture.workspaceA
            let rightIndex = try XCTUnwrap(liveWorkspace.composeTabs.firstIndex {
                $0.id == fixture.rightTab.id
            })
            let liveSelection = StoredSelection(selectedPaths: ["/tmp/live-selection"])
            liveWorkspace.composeTabs[rightIndex].promptText = "live tab prompt"
            liveWorkspace.composeTabs[rightIndex].selection = liveSelection
            liveWorkspace.composeTabs[rightIndex].isPinned = true
            liveWorkspace.composeTabs[rightIndex].contextOverrides = ContextBuilderOverrides(
                useOverridePrompt: true,
                overridePromptText: "live override"
            )
            let unrelatedStash = StashedTab(tab: ComposeTabState(
                name: "Live stash",
                promptText: "preserve stashed edit"
            ))
            liveWorkspace.stashedTabs = [unrelatedStash]
            fixture.prompt.loadComposeTabsFromWorkspace(liveWorkspace)

            let outcome = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)

            guard case .recovered = outcome else {
                return XCTFail("Expected recovery, got \(outcome)")
            }
            XCTAssertEqual(fixture.prompt.currentStashedTabs, [unrelatedStash])
            let preserved = try XCTUnwrap(fixture.prompt.currentComposeTabs.first {
                $0.id == fixture.rightTab.id
            })
            XCTAssertEqual(preserved.promptText, "live tab prompt")
            XCTAssertEqual(preserved.selection, liveSelection)
            XCTAssertTrue(preserved.isPinned)
            XCTAssertEqual(
                preserved.contextOverrides,
                ContextBuilderOverrides(
                    useOverridePrompt: true,
                    overridePromptText: "live override"
                )
            )
            XCTAssertFalse(fixture.prompt.currentComposeTabs.contains {
                $0.id == fixture.identity.tabID
            })
        }

        func testManagerProjectionConflictLeavesPromptAndSidebarProjectionsUnchanged() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let successorID = UUID()
            let managerIndex = try XCTUnwrap(fixture.manager.workspaces.firstIndex {
                $0.id == fixture.workspaceA.id
            })
            let tabIndex = try XCTUnwrap(fixture.manager.workspaces[managerIndex].composeTabs.firstIndex {
                $0.id == fixture.identity.tabID
            })
            fixture.manager.workspaces[managerIndex].composeTabs[tabIndex].activeAgentSessionID = successorID
            let managerBefore = fixture.manager.workspaces[managerIndex]
            let promptTabsBefore = fixture.prompt.currentComposeTabs
            let promptActiveBefore = fixture.prompt.activeComposeTabID
            let sidebarBefore = fixture.prompt.sidebarWorkspaceSnapshot

            let outcome = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)

            XCTAssertEqual(outcome, .ownershipChanged)
            XCTAssertEqual(fixture.manager.workspaces[managerIndex], managerBefore)
            XCTAssertEqual(fixture.prompt.currentComposeTabs, promptTabsBefore)
            XCTAssertEqual(fixture.prompt.activeComposeTabID, promptActiveBefore)
            XCTAssertEqual(fixture.prompt.sidebarWorkspaceSnapshot, sidebarBefore)
        }

        func testCurrentProjectionAlreadyAbsentStillReconcilesMatchingSidebarSnapshot() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let currentTabs = [fixture.leftTab, fixture.rightTab]
            fixture.prompt.setCurrentComposeTabsForAgentAdmissionRecoveryTesting(
                currentTabs,
                activeComposeTabID: fixture.rightTab.id
            )
            XCTAssertTrue(fixture.prompt.sidebarWorkspaceSnapshot?.composeTabs.contains {
                $0.id == fixture.identity.tabID
            } == true)

            let outcome = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)

            guard case .recovered = outcome else {
                return XCTFail("Expected recovery, got \(outcome)")
            }
            XCTAssertEqual(fixture.prompt.currentComposeTabs, currentTabs)
            XCTAssertEqual(fixture.prompt.activeComposeTabID, fixture.rightTab.id)
            XCTAssertEqual(
                fixture.prompt.sidebarWorkspaceSnapshot?.composeTabs.map(\.id),
                currentTabs.map(\.id)
            )
        }

        func testRecoveryPreservesSuccessorIdentityWithoutMutation() async throws {
            let fixture = try await makeFixture()
            let initialValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let initial = try XCTUnwrap(initialValue)
            let successorID = UUID()
            var successor = fixture.workspaceA
            let tabIndex = try XCTUnwrap(successor.composeTabs.firstIndex {
                $0.id == fixture.identity.tabID
            })
            successor.composeTabs[tabIndex].activeAgentSessionID = successorID
            let replaced = try await fixture.client.replaceWorking(
                successor,
                fileURL: fixture.workspaceAURL,
                expectedWorkspaceRevision: initial.revisions.workingRevision
            )
            let saved = try await fixture.client.save(
                successor,
                fileURL: fixture.workspaceAURL,
                expectedWorkspaceRevision: replaced.after?.workingRevision,
                expectedContentDigest: replaced.resultingDigest
            )
            XCTAssertEqual(saved.disposition, .applied)
            let managerIndex = try XCTUnwrap(fixture.manager.workspaces.firstIndex {
                $0.id == successor.id
            })
            fixture.manager.workspaces[managerIndex] = successor
            let beforeValue = await fixture.client.canonicalWorkspaceSnapshot(successor.id)
            let before = try XCTUnwrap(beforeValue)
            let digestBefore = before.document.contentDigest

            let outcome = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)

            XCTAssertEqual(outcome, .ownershipChanged)
            let afterValue = await fixture.client.canonicalWorkspaceSnapshot(successor.id)
            let after = try XCTUnwrap(afterValue)
            XCTAssertEqual(after.document.contentDigest, digestBefore)
            let successorCanonical = try await canonicalModel(fixture)
            XCTAssertEqual(successorCanonical.composeTabs.first {
                $0.id == fixture.identity.tabID
            }?.activeAgentSessionID, successorID)
        }

        func testCanonicalWorkingRecoveryRetriesSaveOnlyAndReplayIsIdempotent() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            var hookCount = 0
            fixture.manager.setAgentAdmissionRecoveryWorkingCommitHandlerForTesting { _, _ in
                hookCount += 1
                return false
            }

            let partialOutcome = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)
            guard case let .retryablePartial(owned) = partialOutcome else {
                return XCTFail("Expected retryable working commit, got \(partialOutcome)")
            }
            XCTAssertEqual(hookCount, 1)
            let dirtyValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let dirty = try XCTUnwrap(dirtyValue)
            XCTAssertEqual(dirty.revisions.workingRevision, owned.revision)
            XCTAssertEqual(dirty.document.contentDigest, owned.digest)
            XCTAssertEqual(dirty.revisions.dirtyRevision, owned.revision)
            let diskBeforeRetry = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            XCTAssertTrue(diskBeforeRetry.composeTabs.contains { $0.id == fixture.identity.tabID })

            let repeatedPartial = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)
            XCTAssertEqual(repeatedPartial, .retryablePartial(owned))
            XCTAssertEqual(hookCount, 2)

            fixture.manager.setAgentAdmissionRecoveryWorkingCommitHandlerForTesting(nil)
            let recovered = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)
            switch recovered {
            case .recovered, .alreadyRecovered:
                break
            default:
                return XCTFail("Expected save-only convergence, got \(recovered)")
            }
            let cleanValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let clean = try XCTUnwrap(cleanValue)
            XCTAssertEqual(clean.revisions.workingRevision, owned.revision)
            XCTAssertEqual(clean.revisions.savedRevision, owned.revision)
            XCTAssertNil(clean.revisions.dirtyRevision)
            XCTAssertEqual(clean.document.contentDigest, owned.digest)

            let replay = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)
            guard case .alreadyRecovered = replay else {
                return XCTFail("Expected idempotent replay, got \(replay)")
            }
            let replayedValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let replayed = try XCTUnwrap(replayedValue)
            XCTAssertEqual(replayed.revisions, clean.revisions)
            XCTAssertEqual(replayed.document.contentDigest, clean.document.contentDigest)
        }

        func testPromptCancellationRetainsExactFenceAcrossBoundedRetryBackoff() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let persistenceFence = CancellationIgnoringReleaseFence()
            let retryFence = CancellationIgnoringReleaseFence()
            let recoveryCompleted = expectation(description: "retained recovery completed")
            let coordinatorBaseline = WorkspaceAgentAdmissionCoordinator.shared.snapshot()
            let sessionID = UUID()
            var admissionIdentity: AgentProvisionalAdmissionIdentity?
            var recoveryOutcome: AgentAdmissionRecoveryOutcome?
            var admissionCompleted = false
            var workingAttemptCount = 0
            fixture.prompt.setAgentAdmissionPersistenceReceiptHandlerForTesting { identity, receipt in
                admissionIdentity = identity
                guard case .saved = receipt.commitEvidence else {
                    XCTFail("Cancellation gate requires saved evidence: \(receipt.commitEvidence)")
                    return
                }
                await persistenceFence.enterAndWaitIgnoringCancellationUntilRelease()
            }
            fixture.prompt.setAgentAdmissionRecoveryCompletedHandlerForTesting { _, outcome in
                recoveryOutcome = outcome
                switch outcome {
                case .recovered, .alreadyRecovered, .localOnly, .ownershipChanged:
                    recoveryCompleted.fulfill()
                case .retryablePartial, .failed, .blockedManual:
                    break
                }
            }
            fixture.prompt.setAgentAdmissionRecoveryRetryHandlerForTesting { attempt, outcome in
                XCTAssertEqual(attempt, 0)
                guard case .retryablePartial = outcome else {
                    return XCTFail("Expected a retained exact fence, got \(outcome)")
                }
                await retryFence.enterAndWaitIgnoringCancellationUntilRelease()
            }
            fixture.manager.setAgentAdmissionRecoveryWorkingCommitHandlerForTesting { workspaceID, _ in
                XCTAssertEqual(workspaceID, fixture.workspaceA.id)
                workingAttemptCount += 1
                return workingAttemptCount > 1
            }

            let admissionTask = Task { @MainActor in
                defer { admissionCompleted = true }
                return try await fixture.prompt.createDurableBackgroundAgentSessionTab(
                    name: "Persisted admission awaiting recovery",
                    sessionID: sessionID,
                    expectedWorkspaceID: fixture.workspaceA.id,
                    lifecycleAuthority: AgentSessionLifecycleAuthority()
                )
            }
            await persistenceFence.waitUntilEntered()
            admissionTask.cancel()
            await persistenceFence.release()
            await retryFence.waitUntilEntered()

            guard let identity = admissionIdentity else {
                await retryFence.release()
                _ = try? await admissionTask.value
                return XCTFail("Expected the persistence receipt to capture an admission identity")
            }
            XCTAssertEqual(workingAttemptCount, 1)
            do {
                _ = try await admissionTask.value
                XCTFail("Cancellation must not return a provider-facing target")
            } catch is CancellationError {
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }
            XCTAssertTrue(admissionCompleted)
            guard case .retryablePartial = recoveryOutcome else {
                await retryFence.release()
                return XCTFail("Expected retained recovery handoff, got \(String(describing: recoveryOutcome))")
            }
            XCTAssertEqual(
                WorkspaceAgentAdmissionCoordinator.shared.snapshot().retainedRecoveryCount,
                coordinatorBaseline.retainedRecoveryCount + 1
            )
            XCTAssertEqual(
                WorkspaceAgentAdmissionCoordinator.shared.activeCount(for: fixture.workspaceA.id),
                0,
                "The cancelled request must release its workspace lease before retained recovery retries."
            )

            let dirtySnapshotValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let dirtySnapshot = try XCTUnwrap(dirtySnapshotValue)
            XCTAssertNotNil(dirtySnapshot.revisions.dirtyRevision)
            let dirtyCanonical = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: dirtySnapshot.document.documentBytes,
                fileURL: dirtySnapshot.document.fileURL
            )
            XCTAssertFalse(dirtyCanonical.composeTabs.contains {
                $0.id == identity.tabID && $0.activeAgentSessionID == identity.sessionID
            })
            let diskBeforeSettlement = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            XCTAssertTrue(diskBeforeSettlement.composeTabs.contains {
                $0.id == identity.tabID && $0.activeAgentSessionID == identity.sessionID
            })

            let successorSessionID = UUID()
            let successor = ComposeTabState(
                id: identity.tabID,
                name: "Successor",
                activeAgentSessionID: successorSessionID,
                promptText: "preserve successor"
            )
            let workspaceIndex = try XCTUnwrap(fixture.manager.workspaces.firstIndex {
                $0.id == fixture.workspaceA.id
            })
            fixture.manager.workspaces[workspaceIndex].composeTabs.append(successor)
            fixture.manager.markWorkspaceDirty(workspaceID: fixture.workspaceA.id)
            fixture.prompt.setCurrentComposeTabsForAgentAdmissionRecoveryTesting(
                fixture.manager.workspaces[workspaceIndex].composeTabs,
                activeComposeTabID: fixture.manager.workspaces[workspaceIndex].activeComposeTabID
            )
            await fixture.manager.debugPublishWorkingDocumentToDomainAuthority(
                fixture.manager.workspaces[workspaceIndex]
            )
            let suppressedSave = await fixture.manager.pollAndSaveStateWithOutcomeAsync(
                workspaceID: fixture.workspaceA.id,
                source: WorkspaceSaveSource("promptRecoveryGap")
            )
            XCTAssertEqual(suppressedSave.normalizedFailureCategory, .durabilityUncertain)
            let stillOwnedValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let stillOwned = try XCTUnwrap(stillOwnedValue)
            XCTAssertEqual(stillOwned.revisions, dirtySnapshot.revisions)
            XCTAssertEqual(stillOwned.document.contentDigest, dirtySnapshot.document.contentDigest)

            await retryFence.release()
            await fulfillment(of: [recoveryCompleted], timeout: 5)

            switch recoveryOutcome {
            case .recovered, .alreadyRecovered:
                break
            default:
                XCTFail("Expected exact-fence recovery to settle, got \(String(describing: recoveryOutcome))")
            }
            XCTAssertEqual(workingAttemptCount, 2)
            XCTAssertEqual(
                WorkspaceAgentAdmissionCoordinator.shared.snapshot().retainedRecoveryCount,
                coordinatorBaseline.retainedRecoveryCount
            )
            let cleanSnapshotValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let cleanSnapshot = try XCTUnwrap(cleanSnapshotValue)
            XCTAssertNil(cleanSnapshot.revisions.dirtyRevision)
            let diskAfterSettlement = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            XCTAssertFalse(diskAfterSettlement.composeTabs.contains {
                $0.id == identity.tabID && $0.activeAgentSessionID == identity.sessionID
            })
            XCTAssertTrue(fixture.manager.workspaces[workspaceIndex].composeTabs.contains {
                $0.id == identity.tabID && $0.activeAgentSessionID == successorSessionID
            })
            XCTAssertTrue(fixture.prompt.currentComposeTabs.contains {
                $0.id == identity.tabID && $0.activeAgentSessionID == successorSessionID
            })

            await fixture.manager.debugPublishWorkingDocumentToDomainAuthority(
                fixture.manager.workspaces[workspaceIndex]
            )
            let successorSave = await fixture.manager.pollAndSaveStateWithOutcomeAsync(
                workspaceID: fixture.workspaceA.id,
                source: WorkspaceSaveSource("promptRecoverySuccessor")
            )
            XCTAssertTrue(successorSave.acceptedForLifecycleAdmission)
            let finalDisk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            XCTAssertTrue(finalDisk.composeTabs.contains {
                $0.id == identity.tabID && $0.activeAgentSessionID == successorSessionID
            })

            fixture.prompt.setAgentAdmissionPersistenceReceiptHandlerForTesting(nil)
            fixture.prompt.setAgentAdmissionRecoveryCompletedHandlerForTesting(nil)
            fixture.prompt.setAgentAdmissionRecoveryRetryHandlerForTesting(nil)
            fixture.manager.setAgentAdmissionRecoveryWorkingCommitHandlerForTesting(nil)
            let freshCanonical = try await withFreshRuntime(for: fixture) { client in
                let snapshotValue = await client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
                let snapshot = try XCTUnwrap(snapshotValue)
                return try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: snapshot.document.documentBytes,
                    fileURL: snapshot.document.fileURL
                )
            }
            XCTAssertTrue(freshCanonical.composeTabs.contains {
                $0.id == identity.tabID && $0.activeAgentSessionID == successorSessionID
            })
            XCTAssertFalse(freshCanonical.composeTabs.contains {
                $0.activeAgentSessionID == identity.sessionID
            })
        }

        func testNonRetryablePromptRecoveryRemainsBlockedUntilRepairedAuthoritySettles() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let persistenceFence = CancellationIgnoringReleaseFence()
            let recoveryCompleted = expectation(description: "non-retryable recovery blocked")
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let coordinatorBaseline = coordinator.snapshot()
            let failureCategory = WorkspacePersistenceFailureCategory.unrecoverableDocument
            var admissionIdentity: AgentProvisionalAdmissionIdentity?
            var recoveryOutcome: AgentAdmissionRecoveryOutcome?
            var retryAttemptCount = 0
            fixture.prompt.setAgentAdmissionPersistenceReceiptHandlerForTesting { identity, receipt in
                admissionIdentity = identity
                guard case .saved = receipt.commitEvidence else {
                    XCTFail("Cancellation gate requires saved evidence: \(receipt.commitEvidence)")
                    return
                }
                await persistenceFence.enterAndWaitIgnoringCancellationUntilRelease()
            }
            fixture.prompt.setAgentAdmissionRecoveryCompletedHandlerForTesting { _, outcome in
                recoveryOutcome = outcome
                guard case let .blockedManual(category) = outcome,
                      category == failureCategory
                else {
                    return XCTFail("Expected a typed blocked disposition, got \(outcome)")
                }
                recoveryCompleted.fulfill()
            }
            fixture.prompt.setAgentAdmissionRecoveryRetryHandlerForTesting { attempt, outcome in
                XCTAssertEqual(attempt, 0)
                guard case let .blockedManual(category) = outcome,
                      category == failureCategory
                else {
                    return XCTFail("Expected the retained blocked disposition, got \(outcome)")
                }
                retryAttemptCount += 1
            }
            fixture.manager.setAgentAdmissionRecoveryFailureCategoryHandlerForTesting { workspaceID in
                XCTAssertEqual(workspaceID, fixture.workspaceA.id)
                return failureCategory
            }

            let admissionTask = Task { @MainActor in
                try await fixture.prompt.createDurableBackgroundAgentSessionTab(
                    name: "Persisted admission with non-retryable recovery",
                    sessionID: UUID(),
                    expectedWorkspaceID: fixture.workspaceA.id,
                    lifecycleAuthority: AgentSessionLifecycleAuthority()
                )
            }
            await persistenceFence.waitUntilEntered()
            admissionTask.cancel()
            await persistenceFence.release()
            do {
                _ = try await admissionTask.value
                XCTFail("Cancellation must not return a provider-facing target")
            } catch is CancellationError {
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }
            await fulfillment(of: [recoveryCompleted], timeout: 5)
            guard let identity = admissionIdentity else {
                return XCTFail("Expected the persistence receipt to capture an admission identity")
            }
            XCTAssertEqual(recoveryOutcome, .blockedManual(failureCategory))
            XCTAssertEqual(coordinator.activeCount(for: fixture.workspaceA.id), 0)
            XCTAssertTrue(fixture.manager.debugAgentAdmissionRecoveryOwns(identity))
            XCTAssertTrue(coordinator.hasActiveProvisionalSession(
                workspaceID: identity.workspaceID,
                sessionID: identity.sessionID
            ))
            XCTAssertEqual(
                coordinator.snapshot().retainedRecoveryCount,
                coordinatorBaseline.retainedRecoveryCount + 1
            )

            let leasedSave = try await fixture.manager.withAgentSessionAdmission(
                workspaceID: fixture.workspaceA.id,
                admissionID: UUID()
            ) {
                await fixture.manager.persistAgentAdmission(
                    identity,
                    source: WorkspaceSaveSource("agentSessionLifecycleLeasedSave")
                )
            }
            XCTAssertEqual(leasedSave.outcome.normalizedFailureCategory, .durabilityUncertain)
            XCTAssertEqual(
                retryAttemptCount,
                0,
                "A leased admission save must not re-enter the retained recovery lease."
            )
            XCTAssertEqual(coordinator.activeCount(for: fixture.workspaceA.id), 0)

            let blockedCanonicalSnapshotValue = await fixture.client.canonicalWorkspaceSnapshot(
                fixture.workspaceA.id
            )
            let blockedCanonicalSnapshot = try XCTUnwrap(blockedCanonicalSnapshotValue)
            let canonicalBytesBeforeDirectSave = blockedCanonicalSnapshot.document.documentBytes
            let canonicalRevisionsBeforeDirectSave = blockedCanonicalSnapshot.revisions
            let diskBeforeDirectSave = try Data(contentsOf: fixture.workspaceAURL)
            let directWorkspace = try XCTUnwrap(
                fixture.manager.workspace(withID: fixture.workspaceA.id)
            )
            let retryAttemptCountBeforeDirectSave = retryAttemptCount
            var directSaveRejected = false
            do {
                _ = try await fixture.manager.saveWorkspaceToFileAsync(
                    directWorkspace,
                    source: WorkspaceSaveSource("directRecoverySuppressed")
                )
            } catch {
                directSaveRejected = true
            }
            XCTAssertTrue(
                directSaveRejected,
                "A direct save must fail closed while admission recovery owns the workspace."
            )
            let afterDirectSaveValue = await fixture.client.canonicalWorkspaceSnapshot(
                fixture.workspaceA.id
            )
            let afterDirectSave = try XCTUnwrap(afterDirectSaveValue)
            XCTAssertEqual(afterDirectSave.document.documentBytes, canonicalBytesBeforeDirectSave)
            XCTAssertEqual(afterDirectSave.revisions, canonicalRevisionsBeforeDirectSave)
            XCTAssertEqual(try Data(contentsOf: fixture.workspaceAURL), diskBeforeDirectSave)
            XCTAssertEqual(retryAttemptCount, retryAttemptCountBeforeDirectSave)
            XCTAssertTrue(fixture.manager.debugAgentAdmissionRecoveryOwns(identity))
            XCTAssertEqual(coordinator.activeCount(for: fixture.workspaceA.id), 0)
            XCTAssertEqual(
                coordinator.snapshot().retainedRecoveryCount,
                coordinatorBaseline.retainedRecoveryCount + 1
            )

            fixture.prompt.setAgentAdmissionRecoveryCompletedHandlerForTesting(nil)
            fixture.manager.setAgentAdmissionRecoveryFailureCategoryHandlerForTesting(nil)
            let corruptBytes = Data("corrupt workspace document".utf8)
            try corruptBytes.write(to: fixture.workspaceAURL, options: .atomic)
            _ = await fixture.client.reloadExternalChanges()
            let readOnlySnapshotValue = await fixture.client.canonicalWorkspaceSnapshot(
                fixture.workspaceA.id
            )
            let readOnlySnapshot = try XCTUnwrap(readOnlySnapshotValue)
            guard case .degradedReadOnly = readOnlySnapshot.health else {
                return XCTFail(
                    "Expected the actual external-document health gate to become read-only."
                )
            }
            let suppressedSave = await fixture.manager.pollAndSaveStateWithOutcomeAsync(
                workspaceID: fixture.workspaceA.id,
                source: WorkspaceSaveSource("nonRetryableRecoverySuppressed")
            )
            XCTAssertEqual(suppressedSave.normalizedFailureCategory, .durabilityUncertain)
            XCTAssertEqual(retryAttemptCount, retryAttemptCountBeforeDirectSave)
            let afterReadOnlyPollValue = await fixture.client.canonicalWorkspaceSnapshot(
                fixture.workspaceA.id
            )
            let afterReadOnlyPoll = try XCTUnwrap(afterReadOnlyPollValue)
            XCTAssertEqual(afterReadOnlyPoll.document.documentBytes, canonicalBytesBeforeDirectSave)
            XCTAssertEqual(afterReadOnlyPoll.revisions, canonicalRevisionsBeforeDirectSave)
            XCTAssertEqual(try Data(contentsOf: fixture.workspaceAURL), corruptBytes)
            XCTAssertTrue(fixture.manager.debugAgentAdmissionRecoveryOwns(identity))
            XCTAssertEqual(coordinator.activeCount(for: fixture.workspaceA.id), 0)
            XCTAssertEqual(
                coordinator.snapshot().retainedRecoveryCount,
                coordinatorBaseline.retainedRecoveryCount + 1
            )

            try diskBeforeDirectSave.write(to: fixture.workspaceAURL, options: .atomic)
            _ = await fixture.client.reloadExternalChanges()
            let repairedSnapshotValue = await fixture.client.canonicalWorkspaceSnapshot(
                fixture.workspaceA.id
            )
            let repairedSnapshot = try XCTUnwrap(repairedSnapshotValue)
            guard repairedSnapshot.health.acceptsMutations else {
                return XCTFail(
                    "Expected repaired authority health to re-enter the retained-recovery eligibility gate."
                )
            }
            _ = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: repairedSnapshot.document.documentBytes,
                fileURL: repairedSnapshot.document.fileURL
            )
            let issueAfterRepair = await fixture.manager.domainAuthorityAdmissionIssue(
                for: fixture.workspaceA.id
            )
            XCTAssertNil(issueAfterRepair)
            XCTAssertEqual(retryAttemptCount, retryAttemptCountBeforeDirectSave + 1)
            XCTAssertFalse(fixture.manager.debugAgentAdmissionRecoveryOwns(identity))
            XCTAssertFalse(coordinator.hasActiveProvisionalSession(
                workspaceID: identity.workspaceID,
                sessionID: identity.sessionID
            ))
            XCTAssertEqual(
                coordinator.snapshot().retainedRecoveryCount,
                coordinatorBaseline.retainedRecoveryCount
            )
            let settledCanonical = try await canonicalModel(fixture)
            XCTAssertFalse(settledCanonical.composeTabs.contains {
                $0.id == identity.tabID && $0.activeAgentSessionID == identity.sessionID
            })
            let settledDisk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            XCTAssertFalse(settledDisk.composeTabs.contains {
                $0.id == identity.tabID && $0.activeAgentSessionID == identity.sessionID
            })

            fixture.prompt.setAgentAdmissionPersistenceReceiptHandlerForTesting(nil)
            fixture.prompt.setAgentAdmissionRecoveryRetryHandlerForTesting(nil)
        }

        func testRetainedPromptRecoveryExhaustionRemainsBlockedUntilDurableSettlement() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let persistenceFence = CancellationIgnoringReleaseFence()
            let retainedRecoveryCompleted = expectation(description: "retained recovery exhausted")
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let coordinatorBaseline = coordinator.snapshot()
            var admissionIdentity: AgentProvisionalAdmissionIdentity?
            var notificationCount = 0
            var recoveryAttemptCount = 0
            fixture.prompt.setAgentAdmissionPersistenceReceiptHandlerForTesting { identity, receipt in
                admissionIdentity = identity
                guard case .saved = receipt.commitEvidence else {
                    XCTFail("Cancellation gate requires saved evidence: \(receipt.commitEvidence)")
                    return
                }
                await persistenceFence.enterAndWaitIgnoringCancellationUntilRelease()
            }
            fixture.prompt.setAgentAdmissionRecoveryCompletedHandlerForTesting { _, outcome in
                switch outcome {
                case let .failed(category):
                    XCTAssertEqual(category, .persistenceFailure)
                    notificationCount += 1
                case let .blockedManual(category):
                    XCTAssertEqual(category, .persistenceFailure)
                    notificationCount += 1
                    if notificationCount == 2 {
                        retainedRecoveryCompleted.fulfill()
                    }
                case .recovered, .alreadyRecovered, .localOnly, .ownershipChanged, .retryablePartial:
                    XCTFail("Expected failed then blocked recovery, got \(outcome)")
                }
            }
            fixture.prompt.setAgentAdmissionRecoveryRetryHandlerForTesting { attempt, outcome in
                XCTAssertEqual(attempt, recoveryAttemptCount)
                guard case .failed(.persistenceFailure) = outcome else {
                    return XCTFail("Expected failed retained recovery, got \(outcome)")
                }
                recoveryAttemptCount += 1
            }
            fixture.manager.setAgentAdmissionRecoveryReplacementPreparationHandlerForTesting { _ in false }

            let admissionTask = Task { @MainActor in
                try await fixture.prompt.createDurableBackgroundAgentSessionTab(
                    name: "Persisted admission with exhausted recovery",
                    sessionID: UUID(),
                    expectedWorkspaceID: fixture.workspaceA.id,
                    lifecycleAuthority: AgentSessionLifecycleAuthority()
                )
            }
            await persistenceFence.waitUntilEntered()
            admissionTask.cancel()
            await persistenceFence.release()
            do {
                _ = try await admissionTask.value
                XCTFail("Cancellation must not return a provider-facing target")
            } catch is CancellationError {
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }
            await fulfillment(of: [retainedRecoveryCompleted], timeout: 5)
            guard let identity = admissionIdentity else {
                return XCTFail("Expected the persistence receipt to capture an admission identity")
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            let expectedBlockedState: AgentAdmissionRetainedRecoveryState? =
                .blockedManual(.persistenceFailure)
            while coordinator.retainedRecoveryState(recoveryID: identity.recoveryID)
                != expectedBlockedState
            {
                guard clock.now < deadline else {
                    return XCTFail("Retained recovery did not preserve its blocked disposition after exhaustion.")
                }
                await Task.yield()
            }
            XCTAssertEqual(recoveryAttemptCount, 4)
            XCTAssertEqual(coordinator.activeCount(for: fixture.workspaceA.id), 0)
            XCTAssertTrue(fixture.manager.debugAgentAdmissionRecoveryOwns(identity))
            XCTAssertTrue(coordinator.hasActiveProvisionalSession(
                workspaceID: identity.workspaceID,
                sessionID: identity.sessionID
            ))
            XCTAssertEqual(
                coordinator.snapshot().retainedRecoveryCount,
                coordinatorBaseline.retainedRecoveryCount + 1
            )
            recoveryAttemptCount = 0

            let blockedCanonical = try await canonicalModel(fixture)
            XCTAssertTrue(blockedCanonical.composeTabs.contains {
                $0.id == identity.tabID && $0.activeAgentSessionID == identity.sessionID
            })
            let blockedDisk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            XCTAssertTrue(blockedDisk.composeTabs.contains {
                $0.id == identity.tabID && $0.activeAgentSessionID == identity.sessionID
            })
            fixture.prompt.setAgentAdmissionRecoveryCompletedHandlerForTesting(nil)
            let suppressedSave = await fixture.manager.pollAndSaveStateWithOutcomeAsync(
                workspaceID: fixture.workspaceA.id,
                source: WorkspaceSaveSource("retainedRecoveryExhaustionSuppressed")
            )
            XCTAssertEqual(suppressedSave.normalizedFailureCategory, .durabilityUncertain)
            XCTAssertEqual(recoveryAttemptCount, 4)

            fixture.manager.setAgentAdmissionRecoveryReplacementPreparationHandlerForTesting(nil)
            fixture.prompt.setAgentAdmissionRecoveryRetryHandlerForTesting(nil)
            let issueAfterRepair = await fixture.manager.domainAuthorityAdmissionIssue(
                for: fixture.workspaceA.id
            )
            XCTAssertNil(issueAfterRepair)
            XCTAssertFalse(fixture.manager.debugAgentAdmissionRecoveryOwns(identity))
            XCTAssertFalse(coordinator.hasActiveProvisionalSession(
                workspaceID: identity.workspaceID,
                sessionID: identity.sessionID
            ))
            XCTAssertEqual(
                coordinator.snapshot().retainedRecoveryCount,
                coordinatorBaseline.retainedRecoveryCount
            )
            let settledCanonical = try await canonicalModel(fixture)
            XCTAssertFalse(settledCanonical.composeTabs.contains {
                $0.id == identity.tabID && $0.activeAgentSessionID == identity.sessionID
            })
            let settledDisk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            XCTAssertFalse(settledDisk.composeTabs.contains {
                $0.id == identity.tabID && $0.activeAgentSessionID == identity.sessionID
            })
        }

        func testLostSaveResponseConvergesThroughCanonicalReread() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            var droppedResponseCount = 0
            fixture.manager.setAgentAdmissionRecoverySaveResponseHandlerForTesting { workspaceID, outcome in
                XCTAssertEqual(workspaceID, fixture.workspaceA.id)
                XCTAssertTrue(
                    outcome.disposition == .applied
                        || outcome.disposition == .unchanged
                        || outcome.disposition == .deduplicated
                )
                droppedResponseCount += 1
                return false
            }

            let outcome = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)

            guard case .recovered = outcome else {
                return XCTFail("Expected canonical re-read convergence, got \(outcome)")
            }
            XCTAssertEqual(droppedResponseCount, 1)
            let snapshotValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let snapshot = try XCTUnwrap(snapshotValue)
            XCTAssertNil(snapshot.revisions.dirtyRevision)
            let canonical = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: snapshot.document.documentBytes,
                fileURL: snapshot.document.fileURL
            )
            XCTAssertFalse(canonical.composeTabs.contains { $0.id == fixture.identity.tabID })
            let baseline = fixture.manager.debugDomainAuthorityBaseline(for: fixture.workspaceA.id)
            XCTAssertEqual(baseline.revisions, snapshot.revisions)
            XCTAssertEqual(baseline.digest, snapshot.document.contentDigest)
            let disk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            XCTAssertFalse(disk.composeTabs.contains { $0.id == fixture.identity.tabID })
        }

        func testReplacementPreparationFailureLeavesEveryProjectionAndCanonicalStateUnchanged() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let managerBefore = fixture.manager.workspace(withID: fixture.workspaceA.id)
            let promptTabsBefore = fixture.prompt.currentComposeTabs
            let promptActiveBefore = fixture.prompt.activeComposeTabID
            let sidebarBefore = fixture.prompt.sidebarWorkspaceSnapshot
            let canonicalBeforeValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let canonicalBefore = try XCTUnwrap(canonicalBeforeValue)
            let diskBefore = try Data(contentsOf: fixture.workspaceAURL)
            fixture.manager.setAgentAdmissionRecoveryReplacementPreparationHandlerForTesting { workspaceID in
                XCTAssertEqual(workspaceID, fixture.workspaceA.id)
                return false
            }

            let outcome = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)

            XCTAssertEqual(outcome, .failed(.persistenceFailure))
            XCTAssertEqual(fixture.manager.workspace(withID: fixture.workspaceA.id), managerBefore)
            XCTAssertEqual(fixture.prompt.currentComposeTabs, promptTabsBefore)
            XCTAssertEqual(fixture.prompt.activeComposeTabID, promptActiveBefore)
            XCTAssertEqual(fixture.prompt.sidebarWorkspaceSnapshot, sidebarBefore)
            let canonicalAfterValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let canonicalAfter = try XCTUnwrap(canonicalAfterValue)
            XCTAssertEqual(canonicalAfter.revisions, canonicalBefore.revisions)
            XCTAssertEqual(canonicalAfter.document.contentDigest, canonicalBefore.document.contentDigest)
            XCTAssertEqual(try Data(contentsOf: fixture.workspaceAURL), diskBefore)
        }

        func testLostReplacementResponseConvergesThroughCanonicalReread() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            var droppedResponseCount = 0
            fixture.manager.setAgentAdmissionRecoveryReplacementResponseHandlerForTesting { workspaceID, outcome in
                XCTAssertEqual(workspaceID, fixture.workspaceA.id)
                XCTAssertTrue(
                    outcome.disposition == .applied
                        || outcome.disposition == .unchanged
                        || outcome.disposition == .deduplicated
                )
                droppedResponseCount += 1
                return false
            }

            let outcome = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)

            guard case .recovered = outcome else {
                return XCTFail("Expected canonical re-read convergence, got \(outcome)")
            }
            XCTAssertEqual(droppedResponseCount, 1)
            let snapshotValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let snapshot = try XCTUnwrap(snapshotValue)
            XCTAssertNil(snapshot.revisions.dirtyRevision)
            let canonical = try await canonicalModel(fixture)
            XCTAssertFalse(canonical.composeTabs.contains {
                $0.id == fixture.identity.tabID
            })
            let baseline = fixture.manager.debugDomainAuthorityBaseline(for: fixture.workspaceA.id)
            XCTAssertEqual(baseline.revisions, snapshot.revisions)
            XCTAssertEqual(baseline.digest, snapshot.document.contentDigest)
        }

        func testUnavailablePostReplacementRereadRetainsAnticipatedFenceThenConverges() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let initialValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let initial = try XCTUnwrap(initialValue)
            var canonicalReadCount = 0
            fixture.manager.setAgentAdmissionRecoveryPostReplacementCanonicalReadHandlerForTesting { workspaceID in
                XCTAssertEqual(workspaceID, fixture.workspaceA.id)
                canonicalReadCount += 1
                return false
            }

            let partial = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)

            guard case let .retryablePartial(anticipated) = partial else {
                return XCTFail("Expected anticipated retry fence, got \(partial)")
            }
            XCTAssertEqual(anticipated.revision, initial.revisions.workingRevision &+ 1)
            XCTAssertEqual(canonicalReadCount, 1)
            let committedValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let committed = try XCTUnwrap(committedValue)
            XCTAssertEqual(committed.revisions.workingRevision, anticipated.revision)
            XCTAssertEqual(committed.document.contentDigest, anticipated.digest)
            XCTAssertEqual(committed.revisions.dirtyRevision, anticipated.revision)

            fixture.manager.setAgentAdmissionRecoveryPostReplacementCanonicalReadHandlerForTesting(nil)
            let retry = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)

            guard case .recovered = retry else {
                return XCTFail("Expected fenced save-only convergence, got \(retry)")
            }
            let finalValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let final = try XCTUnwrap(finalValue)
            XCTAssertEqual(final.revisions.workingRevision, anticipated.revision)
            XCTAssertEqual(final.revisions.savedRevision, anticipated.revision)
            XCTAssertNil(final.revisions.dirtyRevision)
            XCTAssertEqual(final.document.contentDigest, anticipated.digest)
        }

        func testReturnedReplacementNoncommitRetainsAnticipatedFenceThenRetriesOnce() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let initialValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let initial = try XCTUnwrap(initialValue)
            var dispatchCount = 0
            fixture.manager.setAgentAdmissionRecoveryReplacementDispatchHandlerForTesting { workspaceID, revision in
                XCTAssertEqual(workspaceID, fixture.workspaceA.id)
                XCTAssertEqual(revision, initial.revisions.workingRevision)
                dispatchCount += 1
                guard dispatchCount == 1 else { return nil }
                return DomainCommandOutcome(
                    operationID: UUID(),
                    disposition: .failed,
                    before: initial.revisions,
                    after: initial.revisions,
                    catalogRevision: 0,
                    resultingDigest: initial.document.contentDigest,
                    errorCode: .lockTimedOut,
                    diagnostic: "deterministic noncommit"
                )
            }

            let partial = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)

            guard case let .retryablePartial(anticipated) = partial else {
                return XCTFail("Expected anticipated retry fence, got \(partial)")
            }
            XCTAssertEqual(anticipated.revision, initial.revisions.workingRevision &+ 1)
            XCTAssertEqual(dispatchCount, 1)
            let unchangedValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let unchanged = try XCTUnwrap(unchangedValue)
            XCTAssertEqual(unchanged.revisions, initial.revisions)
            XCTAssertEqual(unchanged.document.contentDigest, initial.document.contentDigest)
            let unchangedModel = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: unchanged.document.documentBytes,
                fileURL: unchanged.document.fileURL
            )
            XCTAssertTrue(unchangedModel.composeTabs.contains {
                $0.id == fixture.identity.tabID
                    && $0.activeAgentSessionID == fixture.identity.sessionID
            })

            let retry = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)

            guard case .recovered = retry else {
                return XCTFail("Expected bounded replacement retry to converge, got \(retry)")
            }
            XCTAssertEqual(dispatchCount, 2)
            let finalValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let final = try XCTUnwrap(finalValue)
            XCTAssertEqual(final.revisions.workingRevision, anticipated.revision)
            XCTAssertEqual(final.revisions.savedRevision, anticipated.revision)
            XCTAssertNil(final.revisions.dirtyRevision)
            XCTAssertEqual(final.document.contentDigest, anticipated.digest)
        }

        func testReplacementCASConflictReconcilesDurableSuccessorBeforeOrdinarySave() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let competitor = try await makeCompetingClient(fixture)
            let successorSessionID = UUID()
            var competingCommitError: Error?
            var dispatchedRevision: UInt64?
            fixture.manager.setAgentAdmissionRecoveryReplacementDispatchHandlerForTesting { workspaceID, revision in
                XCTAssertEqual(workspaceID, fixture.workspaceA.id)
                dispatchedRevision = revision
                do {
                    _ = try await self.commitCanonicalSuccessor(
                        client: competitor,
                        fixture: fixture,
                        sessionID: successorSessionID,
                        marker: "replacement CAS successor"
                    )
                } catch {
                    competingCommitError = error
                }
                return nil
            }

            let outcome = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)

            XCTAssertNil(competingCommitError)
            XCTAssertNotNil(dispatchedRevision)
            XCTAssertEqual(outcome, .ownershipChanged)
            try assertSuccessorProjection(
                fixture,
                sessionID: successorSessionID,
                marker: "replacement CAS successor"
            )
            try await publishOrdinarySuccessorEdit(
                fixture,
                successorSessionID: successorSessionID,
                marker: "ordinary save after replacement conflict"
            )
        }

        func testSaveCASConflictReconcilesDurableSuccessorBeforeOrdinarySave() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let competitor = try await makeCompetingClient(fixture)
            let successorSessionID = UUID()
            var competingCommitError: Error?
            var interceptedWorkingCommit: AgentAdmissionRecoveryWorkingCommit?
            fixture.manager.setAgentAdmissionRecoveryWorkingCommitHandlerForTesting { workspaceID, owned in
                XCTAssertEqual(workspaceID, fixture.workspaceA.id)
                interceptedWorkingCommit = owned
                do {
                    let successor = try await self.commitCanonicalSuccessor(
                        client: competitor,
                        fixture: fixture,
                        sessionID: successorSessionID,
                        marker: "save CAS successor"
                    )
                    XCTAssertGreaterThan(successor.revisions.workingRevision, owned.revision)
                } catch {
                    competingCommitError = error
                }
                return true
            }

            let outcome = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)

            XCTAssertNil(competingCommitError)
            XCTAssertNotNil(interceptedWorkingCommit)
            XCTAssertEqual(outcome, .ownershipChanged)
            try assertSuccessorProjection(
                fixture,
                sessionID: successorSessionID,
                marker: "save CAS successor"
            )
            try await publishOrdinarySuccessorEdit(
                fixture,
                successorSessionID: successorSessionID,
                marker: "ordinary save after save conflict"
            )
        }

        func testRecoveryUsesDeterministicReplacementWhenProvisionalTabIsOnlyTab() async throws {
            let fixture = try await makeFixture()
            let initialValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let initial = try XCTUnwrap(initialValue)
            let provisional = try XCTUnwrap(fixture.workspaceA.composeTabs.first {
                $0.id == fixture.identity.tabID
            })
            var singleTabWorkspace = fixture.workspaceA
            singleTabWorkspace.composeTabs = [provisional]
            singleTabWorkspace.activeComposeTabID = provisional.id
            let working = try await fixture.client.replaceWorking(
                singleTabWorkspace,
                fileURL: fixture.workspaceAURL,
                expectedWorkspaceRevision: initial.revisions.workingRevision
            )
            _ = try await fixture.client.save(
                singleTabWorkspace,
                fileURL: fixture.workspaceAURL,
                expectedWorkspaceRevision: working.after?.workingRevision,
                expectedContentDigest: working.resultingDigest
            )
            let managerIndex = try XCTUnwrap(fixture.manager.workspaces.firstIndex {
                $0.id == fixture.workspaceA.id
            })
            fixture.manager.workspaces[managerIndex] = singleTabWorkspace
            fixture.manager.activeWorkspace = singleTabWorkspace
            fixture.prompt.loadComposeTabsFromWorkspace(singleTabWorkspace)

            let outcome = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)
            guard case .recovered = outcome else {
                return XCTFail("Expected recovery, got \(outcome)")
            }

            let canonical = try await canonicalModel(fixture)
            XCTAssertEqual(canonical.composeTabs.map(\.id), [fixture.identity.replacementTabID])
            XCTAssertEqual(canonical.activeComposeTabID, fixture.identity.replacementTabID)
            XCTAssertNil(canonical.composeTabs.first?.activeAgentSessionID)
        }

        func testFinalManagerReconciliationPreservesConcurrentLocalEdit() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            fixture.manager.setAgentAdmissionRecoveryWorkingCommitHandlerForTesting { workspaceID, _ in
                if let index = fixture.manager.workspaces.firstIndex(where: {
                    $0.id == workspaceID
                }) {
                    fixture.manager.workspaces[index].lastSearchQuery = "concurrent local edit"
                    fixture.manager.markWorkspaceDirty(workspaceID: workspaceID)
                }
                return true
            }

            let outcome = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)
            guard case .recovered = outcome else {
                return XCTFail("Expected recovery, got \(outcome)")
            }

            let managerWorkspace = try XCTUnwrap(
                fixture.manager.workspace(withID: fixture.workspaceA.id)
            )
            XCTAssertEqual(managerWorkspace.lastSearchQuery, "concurrent local edit")
            XCTAssertFalse(managerWorkspace.composeTabs.contains { $0.id == fixture.identity.tabID })
            XCTAssertNotEqual(
                fixture.manager.debugLastSavedVersionForWorkspace(fixture.workspaceA.id),
                fixture.manager.debugStateVersionForWorkspace(fixture.workspaceA.id)
            )
        }

        func testRetryablePartialRetainsOwnershipUntilExplicitTerminalFailure() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            fixture.manager.setAgentAdmissionRecoveryWorkingCommitHandlerForTesting { _, _ in false }
            let partial = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)
            guard case let .retryablePartial(owned) = partial else {
                return XCTFail("Expected retryable partial, got \(partial)")
            }
            fixture.manager.setAgentAdmissionRecoveryWorkingCommitHandlerForTesting(nil)
            let workspaceIndex = try XCTUnwrap(fixture.manager.workspaces.firstIndex {
                $0.id == fixture.workspaceA.id
            })
            fixture.manager.workspaces[workspaceIndex].lastSearchQuery = "legitimate later edit"
            fixture.manager.markWorkspaceDirty(workspaceID: fixture.workspaceA.id)

            await fixture.manager.debugPublishWorkingDocumentToDomainAuthority(
                fixture.manager.workspaces[workspaceIndex]
            )
            let suppressedWorkingValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let suppressedWorking = try XCTUnwrap(suppressedWorkingValue)
            XCTAssertEqual(suppressedWorking.revisions.workingRevision, owned.revision)
            XCTAssertEqual(suppressedWorking.document.contentDigest, owned.digest)
            let suppressedSave = await fixture.manager.pollAndSaveStateWithOutcomeAsync(
                workspaceID: fixture.workspaceA.id,
                source: WorkspaceSaveSource("recoveryPartialSuppressed")
            )
            XCTAssertEqual(suppressedSave.normalizedFailureCategory, .durabilityUncertain)

            fixture.manager.finishProvisionalAgentAdmissionRecovery(fixture.identity)
            await fixture.manager.debugPublishWorkingDocumentToDomainAuthority(
                fixture.manager.workspaces[workspaceIndex]
            )
            let working = try await canonicalModel(fixture)
            XCTAssertEqual(working.lastSearchQuery, "legitimate later edit")
            let saved = await fixture.manager.pollAndSaveStateWithOutcomeAsync(
                workspaceID: fixture.workspaceA.id,
                source: WorkspaceSaveSource("recoveryPartialSuccessor")
            )
            XCTAssertTrue(saved.acceptedForLifecycleAdmission)
            let disk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            XCTAssertEqual(disk.lastSearchQuery, "legitimate later edit")
        }

        func testSupersededRetryFenceCannotSaveNewerWorkingRevision() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            fixture.manager.setAgentAdmissionRecoveryWorkingCommitHandlerForTesting { _, _ in false }
            let partial = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)
            guard case .retryablePartial = partial else {
                return XCTFail("Expected retryable partial, got \(partial)")
            }
            fixture.manager.setAgentAdmissionRecoveryWorkingCommitHandlerForTesting(nil)
            fixture.manager.finishProvisionalAgentAdmissionRecovery(fixture.identity)
            let workspaceIndex = try XCTUnwrap(fixture.manager.workspaces.firstIndex {
                $0.id == fixture.workspaceA.id
            })
            fixture.manager.workspaces[workspaceIndex].lastSearchQuery = "newer working revision"
            fixture.manager.markWorkspaceDirty(workspaceID: fixture.workspaceA.id)
            await fixture.manager.debugPublishWorkingDocumentToDomainAuthority(
                fixture.manager.workspaces[workspaceIndex]
            )
            let newerValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let newer = try XCTUnwrap(newerValue)
            XCTAssertNotNil(newer.revisions.dirtyRevision)

            let retry = await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)

            XCTAssertEqual(retry, .ownershipChanged)
            let afterValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let after = try XCTUnwrap(afterValue)
            XCTAssertEqual(after.revisions, newer.revisions)
            XCTAssertEqual(after.document.contentDigest, newer.document.contentDigest)
            let canonical = try await canonicalModel(fixture)
            XCTAssertEqual(canonical.lastSearchQuery, "newer working revision")
        }

        func testLegacyRecoveryPersistsDurableProjectionAndFencesWorkspaceIdentity() async throws {
            let sessionID = UUID()
            let provisional = ComposeTabState(activeAgentSessionID: sessionID)
            let workspace = WorkspaceModel(
                name: "Legacy durable recovery",
                repoPaths: ["/tmp/legacy-durable"],
                lastSearchQuery: "memory value",
                composeTabs: [provisional],
                activeComposeTabID: provisional.id
            )
            let fileURL = try writeWorkspace(workspace)
            try writeIndex([workspace])
            let (manager, prompt) = makeManager(client: nil)
            await manager.awaitInitialized()
            manager.activeWorkspace = workspace
            prompt.loadComposeTabsFromWorkspace(workspace)
            var durableNewer = workspace
            durableNewer.lastSearchQuery = "durable newer value"
            let durableBytes = try JSONEncoder().encode(durableNewer)
            try durableBytes.write(to: fileURL, options: .atomic)
            let identity = AgentProvisionalAdmissionIdentity(
                recoveryID: UUID(),
                workspaceID: workspace.id,
                tabID: provisional.id,
                sessionID: sessionID,
                replacementTabID: UUID()
            )

            let recovered = await manager.recoverProvisionalAgentAdmission(identity)

            guard case .recovered = recovered else {
                return XCTFail("Expected legacy recovery, got \(recovered)")
            }
            let recoveredDisk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fileURL,
                scheduleNormalizationWriteback: false
            )
            XCTAssertEqual(recoveredDisk.lastSearchQuery, "durable newer value")
            XCTAssertFalse(recoveredDisk.composeTabs.contains { $0.id == provisional.id })
            XCTAssertEqual(
                manager.workspace(withID: workspace.id)?.lastSearchQuery,
                "durable newer value"
            )

            let foreign = WorkspaceModel(
                id: UUID(),
                name: durableNewer.name,
                repoPaths: durableNewer.repoPaths,
                lastSearchQuery: durableNewer.lastSearchQuery,
                composeTabs: [provisional],
                activeComposeTabID: provisional.id
            )
            let foreignBytes = try JSONEncoder().encode(foreign)
            try foreignBytes.write(to: fileURL, options: .atomic)
            let foreignOutcome = await manager.recoverProvisionalAgentAdmission(
                AgentProvisionalAdmissionIdentity(
                    recoveryID: UUID(),
                    workspaceID: workspace.id,
                    tabID: provisional.id,
                    sessionID: sessionID,
                    replacementTabID: UUID()
                )
            )
            XCTAssertEqual(foreignOutcome, .ownershipChanged)
            XCTAssertEqual(try Data(contentsOf: fileURL), foreignBytes)
        }

        func testLegacyRecoveryFailsClosedWhenPersistedWorkspaceCannotBeDecoded() async throws {
            let sessionID = UUID()
            let provisional = ComposeTabState(activeAgentSessionID: sessionID)
            let workspace = WorkspaceModel(
                name: "Legacy corrupt recovery",
                repoPaths: ["/tmp/legacy-recovery"],
                composeTabs: [provisional],
                activeComposeTabID: provisional.id
            )
            let fileURL = try writeWorkspace(workspace)
            try writeIndex([workspace])
            let (manager, prompt) = makeManager(client: nil)
            await manager.awaitInitialized()
            manager.activeWorkspace = workspace
            prompt.loadComposeTabsFromWorkspace(workspace)
            let corrupt = Data("{not-json".utf8)
            try corrupt.write(to: fileURL, options: .atomic)
            let identity = AgentProvisionalAdmissionIdentity(
                recoveryID: UUID(),
                workspaceID: workspace.id,
                tabID: provisional.id,
                sessionID: sessionID,
                replacementTabID: UUID()
            )

            let outcome = await manager.recoverProvisionalAgentAdmission(identity)

            XCTAssertEqual(outcome, .failed(.unrecoverableDocument))
            manager.finishProvisionalAgentAdmissionRecovery(identity)
            XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
            XCTAssertTrue(manager.workspace(withID: workspace.id)?.composeTabs.contains {
                $0.id == provisional.id && $0.activeAgentSessionID == sessionID
            } == true)
        }

        func testLegacyRecoveryWriteFailureLeavesInMemoryProjectionUnchanged() async throws {
            let sessionID = UUID()
            let provisional = ComposeTabState(activeAgentSessionID: sessionID)
            let workspace = WorkspaceModel(
                name: "Legacy failed durable recovery",
                repoPaths: ["/tmp/legacy-recovery-write-failure"],
                composeTabs: [provisional],
                activeComposeTabID: provisional.id
            )
            let fileURL = try writeWorkspace(workspace)
            try writeIndex([workspace])
            let (manager, prompt) = makeManager(client: nil)
            await manager.awaitInitialized()
            manager.activeWorkspace = workspace
            prompt.loadComposeTabsFromWorkspace(workspace)
            let managerBefore = manager.workspace(withID: workspace.id)
            let promptTabsBefore = prompt.currentComposeTabs
            let promptActiveBefore = prompt.activeComposeTabID
            let sidebarBefore = prompt.sidebarWorkspaceSnapshot
            let identity = AgentProvisionalAdmissionIdentity(
                recoveryID: UUID(),
                workspaceID: workspace.id,
                tabID: provisional.id,
                sessionID: sessionID,
                replacementTabID: UUID()
            )
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.setAtomicWriteGateForTesting {
                try? FileManager.default.removeItem(at: fileURL)
                try? FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
            }

            let outcome = await manager.recoverProvisionalAgentAdmission(identity)
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.setAtomicWriteGateForTesting(nil)

            XCTAssertEqual(outcome, .failed(.durabilityUncertain))
            XCTAssertEqual(manager.workspace(withID: workspace.id), managerBefore)
            XCTAssertEqual(prompt.currentComposeTabs, promptTabsBefore)
            XCTAssertEqual(prompt.activeComposeTabID, promptActiveBefore)
            XCTAssertEqual(prompt.sidebarWorkspaceSnapshot, sidebarBefore)
        }

        func testConcurrentRecoveryCallersCoalesceOneCanonicalMutation() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let gate = RecoveryCoalescingGate()
            var hookCount = 0
            fixture.manager.setAgentAdmissionRecoveryWorkingCommitHandlerForTesting { _, _ in
                hookCount += 1
                await gate.suspendFirstCaller()
                return true
            }
            fixture.manager.setAgentAdmissionRecoveryDidCoalesceHandlerForTesting { identity in
                XCTAssertEqual(identity, fixture.identity)
                await gate.observeCoalescedCaller()
            }

            let first = Task { @MainActor in
                await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)
            }
            await gate.waitUntilFirstCallerIsSuspended()
            let second = Task { @MainActor in
                await fixture.manager.recoverProvisionalAgentAdmission(fixture.identity)
            }
            await gate.waitUntilCoalescedCallerIsObserved()
            await gate.releaseFirstCaller()
            let outcomes = await [first.value, second.value]

            XCTAssertEqual(outcomes[0], outcomes[1])
            XCTAssertEqual(hookCount, 1)
            let finalSnapshot = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            XCTAssertNil(finalSnapshot?.revisions.dirtyRevision)
        }

        func testFrozenBoundAndExactSelectorsRejectBindingDriftWithoutRebinding() async throws {
            let beforeHydration = try await makeFixture()
            beforeHydration.manager.activeWorkspace = beforeHydration.workspaceA
            beforeHydration.prompt.loadComposeTabsFromWorkspace(beforeHydration.workspaceA)
            let boundViewModel = makeAgentModeViewModel(for: beforeHydration)
            let boundSession = boundViewModel.session(for: beforeHydration.identity.tabID)
            let boundIndexEntry = upsertIndexEntry(
                beforeHydration.identity.sessionID,
                tabID: beforeHydration.identity.tabID,
                in: boundViewModel
            )
            var authorityHookRan = false
            boundViewModel.test_setAfterMCPSessionTargetDiscardRetired { sessionID in
                guard sessionID == beforeHydration.identity.sessionID else { return }
                authorityHookRan = true
                _ = boundViewModel.test_installPersistentSessionBinding(
                    sessionID: nil,
                    on: boundSession,
                    compareAndSetInWorkspaceID: beforeHydration.workspaceA.id
                )
            }

            do {
                _ = try await boundViewModel.mcpResolveOrCreateSessionTarget(
                    tabID: beforeHydration.identity.tabID,
                    sessionID: nil,
                    createIfNeeded: true,
                    sessionName: nil,
                    expectedWorkspaceID: beforeHydration.workspaceA.id
                )
                XCTFail("A bound-tab selector must reject binding drift after authority acquisition.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("selector was frozen"), error.localizedDescription)
            }
            XCTAssertTrue(authorityHookRan)
            XCTAssertNil(boundSession.activeAgentSessionID)
            XCTAssertNil(beforeHydration.manager.activeAgentSessionID(
                forTabID: beforeHydration.identity.tabID,
                inWorkspaceID: beforeHydration.workspaceA.id
            ))
            XCTAssertEqual(
                boundViewModel.test_ownerValidatedSessionIndex[beforeHydration.identity.sessionID],
                boundIndexEntry,
                "Frozen selector rejection must not rewrite the stale index fallback."
            )
            boundViewModel.test_setAfterMCPSessionTargetDiscardRetired(nil)

            let afterHydration = try await makeFixture()
            afterHydration.manager.activeWorkspace = afterHydration.workspaceA
            afterHydration.prompt.loadComposeTabsFromWorkspace(afterHydration.workspaceA)
            let exactViewModel = makeAgentModeViewModel(for: afterHydration)
            let exactSession = exactViewModel.session(for: afterHydration.identity.tabID)
            let exactIndexEntry = upsertIndexEntry(
                afterHydration.identity.sessionID,
                tabID: afterHydration.identity.tabID,
                in: exactViewModel
            )
            var hydrationHookRan = false
            exactViewModel.test_setAfterExplicitTabSessionReady {
                hydrationHookRan = true
                _ = exactViewModel.test_installPersistentSessionBinding(
                    sessionID: nil,
                    on: exactSession,
                    compareAndSetInWorkspaceID: afterHydration.workspaceA.id
                )
            }

            do {
                _ = try await exactViewModel.mcpResolveOrCreateSessionTarget(
                    tabID: afterHydration.identity.tabID,
                    sessionID: afterHydration.identity.sessionID,
                    createIfNeeded: false,
                    sessionName: nil,
                    expectedWorkspaceID: afterHydration.workspaceA.id
                )
                XCTFail("An exact selector must reject binding drift after hydration.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("selector was frozen"), error.localizedDescription)
            }
            XCTAssertTrue(hydrationHookRan)
            XCTAssertNil(exactSession.activeAgentSessionID)
            XCTAssertNil(afterHydration.manager.activeAgentSessionID(
                forTabID: afterHydration.identity.tabID,
                inWorkspaceID: afterHydration.workspaceA.id
            ))
            XCTAssertEqual(
                exactViewModel.test_ownerValidatedSessionIndex[afterHydration.identity.sessionID],
                exactIndexEntry,
                "Exact selector rejection must not use the index to recreate the binding."
            )
            exactViewModel.test_setAfterExplicitTabSessionReady(nil)
        }

        func testIndexOnlySessionReconstructionIsClaimBearingAndRecoverable() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let viewModel = makeAgentModeViewModel(for: fixture)
            let reconstructedSessionID = UUID()
            let indexedTabID = fixture.leftTab.id
            let restoreEntry = upsertIndexEntry(
                reconstructedSessionID,
                tabID: indexedTabID,
                in: viewModel
            )
            var artifactDeletionCount = 0
            viewModel.test_setAgentSessionDeleter { _, _ in
                artifactDeletionCount += 1
            }

            let target = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: reconstructedSessionID,
                createIfNeeded: true,
                sessionName: "index-only reconstruction",
                expectedWorkspaceID: fixture.workspaceA.id
            )

            XCTAssertEqual(target.origin, .createdForSessionResume)
            XCTAssertNotNil(target.recoveryClaim)
            XCTAssertNotEqual(target.tabID, indexedTabID)
            XCTAssertNil(fixture.manager.activeAgentSessionID(
                forTabID: indexedTabID,
                inWorkspaceID: fixture.workspaceA.id
            ))
            let discard = await viewModel.mcpDiscardSessionTarget(target)
            XCTAssertEqual(discard, .complete)
            XCTAssertEqual(target.recoveryClaim?.state, .complete)
            XCTAssertEqual(viewModel.test_ownerValidatedSessionIndex[reconstructedSessionID], restoreEntry)
            XCTAssertEqual(artifactDeletionCount, 0)
            XCTAssertFalse(fixture.manager.workspace(withID: fixture.workspaceA.id)?.composeTabs.contains(where: {
                $0.id == target.tabID
            }) == true)
            XCTAssertNil(viewModel.session(for: target.tabID, createIfNeeded: false))
        }

        func testPostInstallCancellationRecoversCanonicalBindingWithoutLifecycleIdentity() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let viewModel = makeAgentModeViewModel(for: fixture)
            let targetTabID = fixture.leftTab.id
            let publicationGate = RecoveryInterleavingGate()
            var installedSessionID: UUID?
            var capturedTarget: AgentModeViewModel.MCPSessionTarget?
            viewModel.test_setAfterProvisionalExistingTabBindingInstalled {
                installedSessionID = fixture.manager.activeAgentSessionID(
                    forTabID: targetTabID,
                    inWorkspaceID: fixture.workspaceA.id
                )
                if let installedSessionID {
                    capturedTarget = viewModel.test_outstandingProvisionalMCPSessionTarget(
                        sessionID: installedSessionID
                    )
                }
                await publicationGate.markStartedAndWaitForRelease()
            }
            defer { viewModel.test_setAfterProvisionalExistingTabBindingInstalled(nil) }

            let resolution = Task { @MainActor in
                try await viewModel.mcpResolveOrCreateSessionTarget(
                    tabID: targetTabID,
                    sessionID: nil,
                    createIfNeeded: true,
                    sessionName: "post-install cancellation",
                    expectedWorkspaceID: fixture.workspaceA.id
                )
            }
            await publicationGate.waitUntilStarted()
            let sessionID = try XCTUnwrap(installedSessionID)
            let preLifecycleTarget = try XCTUnwrap(capturedTarget)
            let preLifecycleRuntime = try XCTUnwrap(viewModel.session(for: targetTabID, createIfNeeded: false))
            XCTAssertNil(preLifecycleTarget.lifecycleIdentity)
            let canonicalBeforeCancellation = try await canonicalModel(fixture)
            XCTAssertTrue(canonicalBeforeCancellation.composeTabs.contains {
                $0.id == targetTabID && $0.activeAgentSessionID == sessionID
            })

            resolution.cancel()
            await publicationGate.release()
            do {
                _ = try await resolution.value
                XCTFail("Cancellation after binding installation must reject the target.")
            } catch {
                XCTAssertTrue(error is CancellationError, String(describing: error))
            }

            XCTAssertEqual(preLifecycleTarget.recoveryClaim?.state, .complete)
            XCTAssertEqual(viewModel.test_pendingMCPSessionTargetDiscardCount, 0)
            XCTAssertEqual(viewModel.test_outstandingProvisionalMCPSessionTargetCount, 0)
            XCTAssertTrue(viewModel.session(for: targetTabID, createIfNeeded: false) === preLifecycleRuntime)
            XCTAssertNil(preLifecycleRuntime.activeAgentSessionID)
            let canonical = try await canonicalModel(fixture)
            let disk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            for workspace in try [
                XCTUnwrap(fixture.manager.workspace(withID: fixture.workspaceA.id)),
                canonical,
                disk
            ] {
                XCTAssertTrue(workspace.composeTabs.contains {
                    $0.id == targetTabID && $0.activeAgentSessionID == nil
                })
                XCTAssertFalse(workspace.composeTabs.contains {
                    $0.activeAgentSessionID == sessionID
                })
            }
        }

        func testCanonicalRecoveryPreservesRotatedRuntimeGeneration() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let viewModel = makeAgentModeViewModel(for: fixture)
            let target = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: fixture.leftTab.id,
                sessionID: nil,
                createIfNeeded: true,
                sessionName: "rotated runtime generation",
                expectedWorkspaceID: fixture.workspaceA.id
            )
            let sessionID = try XCTUnwrap(target.sessionID)
            let originalLifecycle = try XCTUnwrap(target.lifecycleIdentity)
            let runtime = viewModel.session(for: target.tabID)
            _ = viewModel.test_installPersistentSessionBinding(
                sessionID: nil,
                on: runtime,
                compareAndSetInWorkspaceID: fixture.workspaceA.id
            )
            let rotatedBinding = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(
                sessionID: sessionID,
                on: runtime,
                compareAndSetInWorkspaceID: fixture.workspaceA.id
            ))
            XCTAssertNotEqual(rotatedBinding.generation, originalLifecycle.persistentBindingGeneration)
            var artifactDeletionCount = 0
            viewModel.test_setAgentSessionDeleter { _, _ in
                artifactDeletionCount += 1
            }

            let discard = await viewModel.mcpDiscardSessionTarget(target)

            XCTAssertEqual(discard, .complete)
            XCTAssertEqual(target.recoveryClaim?.state, .complete)
            XCTAssertTrue(viewModel.session(for: target.tabID, createIfNeeded: false) === runtime)
            XCTAssertEqual(runtime.activeAgentSessionID, sessionID)
            XCTAssertEqual(runtime.persistentSessionBindingIdentity, rotatedBinding)
            XCTAssertEqual(artifactDeletionCount, 0)
            let canonical = try await canonicalModel(fixture)
            XCTAssertTrue(canonical.composeTabs.contains {
                $0.id == target.tabID && $0.activeAgentSessionID == nil
            })
            XCTAssertNil(fixture.manager.activeAgentSessionID(
                forTabID: target.tabID,
                inWorkspaceID: fixture.workspaceA.id
            ))
            XCTAssertEqual(viewModel.test_pendingMCPSessionTargetDiscardCount, 0)
            XCTAssertEqual(viewModel.test_outstandingProvisionalMCPSessionTargetCount, 0)
        }

        func testProvisionalParentIndexPublicationDoesNotBlockExactCleanup() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let viewModel = makeAgentModeViewModel(for: fixture)
            let targetTabID = fixture.rightTab.id
            let parentSessionID = fixture.identity.sessionID
            let target = try await viewModel.mcpResolveOrCreateSessionTarget(
                tabID: targetTabID,
                sessionID: nil,
                createIfNeeded: true,
                sessionName: "provisional indexed child",
                parentSessionID: parentSessionID,
                expectedWorkspaceID: fixture.workspaceA.id
            )
            let sessionID = try XCTUnwrap(target.sessionID)
            let provisionalIndexEntry = try XCTUnwrap(viewModel.test_ownerValidatedSessionIndex[sessionID])
            XCTAssertEqual(provisionalIndexEntry.tabID, targetTabID)
            XCTAssertEqual(provisionalIndexEntry.parentSessionID, parentSessionID)
            XCTAssertEqual(target.recoveryClaim?.state, .provisional)

            let artifactURL = try await AgentSessionDataService.shared.saveAgentSession(
                AgentSession(
                    id: sessionID,
                    workspaceID: fixture.workspaceA.id,
                    composeTabID: targetTabID,
                    name: "Provisional indexed child",
                    savedAt: Date(timeIntervalSince1970: 1_800_000_401),
                    itemCount: 0,
                    autoEditEnabled: false
                ),
                for: fixture.workspaceA,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0
            )
            let worktreeRoot = storageRoot.appendingPathComponent(
                "provisional-indexed-child-worktree",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
            let store = fixture.prompt.workspaceFileContextStore
            let preparation = try await store.prepareSessionWorktreeOwnership(
                ownerID: sessionID,
                bindingFingerprint: "provisional-indexed-child",
                physicalRootPaths: [worktreeRoot.path]
            )
            _ = try await store.commitSessionWorktreeOwnership(preparation)
            var exactArtifactDeletionCount = 0
            viewModel.test_setAgentSessionDeleter { deletedSessionID, workspace in
                XCTAssertEqual(deletedSessionID, sessionID)
                XCTAssertEqual(workspace.id, fixture.workspaceA.id)
                exactArtifactDeletionCount += 1
                try await AgentSessionDataService.shared.deleteAgentSession(id: deletedSessionID, for: workspace)
            }

            let discard = await viewModel.mcpDiscardSessionTarget(target)

            XCTAssertEqual(discard, .complete)
            XCTAssertEqual(target.recoveryClaim?.state, .complete)
            XCTAssertEqual(exactArtifactDeletionCount, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL.path))
            XCTAssertNil(viewModel.test_ownerValidatedSessionIndex[sessionID])
            XCTAssertNil(viewModel.session(for: targetTabID, createIfNeeded: false))
            let releasedOwnership = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
            XCTAssertEqual(releasedOwnership.installedOwnerCount, 0)
            XCTAssertEqual(releasedOwnership.rootClaimCount, 0)
            XCTAssertEqual(
                fixture.manager.activeAgentSessionID(
                    forTabID: fixture.identity.tabID,
                    inWorkspaceID: fixture.workspaceA.id
                ),
                parentSessionID
            )
            let canonical = try await canonicalModel(fixture)
            XCTAssertTrue(canonical.composeTabs.contains {
                $0.id == targetTabID && $0.activeAgentSessionID == nil
            })
            XCTAssertTrue(canonical.composeTabs.contains {
                $0.id == fixture.identity.tabID && $0.activeAgentSessionID == parentSessionID
            })
            XCTAssertEqual(viewModel.test_pendingMCPSessionTargetDiscardCount, 0)
            XCTAssertEqual(viewModel.test_outstandingProvisionalMCPSessionTargetCount, 0)
        }

        func testBindingOnlyRecoveryClearsExactSessionAndPreservesTabContent() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let originalTab = try XCTUnwrap(
                fixture.workspaceA.composeTabs.first { $0.id == fixture.identity.tabID }
            )

            let outcome = await fixture.manager.recoverProvisionalAgentSessionBinding(fixture.identity)

            guard case .recovered = outcome else {
                return XCTFail("Expected durable binding recovery, received \(outcome).")
            }
            let canonical = try await canonicalModel(fixture)
            let disk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            for workspace in try [
                XCTUnwrap(fixture.manager.workspace(withID: fixture.workspaceA.id)),
                canonical,
                disk
            ] {
                let recoveredTab = try XCTUnwrap(
                    workspace.composeTabs.first { $0.id == fixture.identity.tabID }
                )
                XCTAssertNil(recoveredTab.activeAgentSessionID)
                XCTAssertEqual(recoveredTab.name, originalTab.name)
                XCTAssertEqual(recoveredTab.promptText, originalTab.promptText)
                XCTAssertEqual(recoveredTab.selection, originalTab.selection)
                XCTAssertEqual(recoveredTab.isPinned, originalTab.isPinned)
                XCTAssertEqual(workspace.composeTabs.count, fixture.workspaceA.composeTabs.count)
            }
            let promptTab = try XCTUnwrap(
                fixture.prompt.currentComposeTabs.first { $0.id == fixture.identity.tabID }
            )
            XCTAssertNil(promptTab.activeAgentSessionID)
            XCTAssertEqual(promptTab.promptText, originalTab.promptText)
            XCTAssertEqual(fixture.prompt.activeComposeTabID, fixture.workspaceA.activeComposeTabID)
        }

        func testCancelledExplicitTabBindingRecoversExactlyAndPreservesAcceptedSuccessor() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let originalTab = fixture.leftTab
            let originalTabCount = fixture.workspaceA.composeTabs.count
            let agentModeVM = AgentModeViewModel(
                testWorkspacePath: storageRoot.path,
                codexControllerFactory: { _, _, _, _, _, _ in
                    AgentAdmissionNoopCodexController()
                },
                testWorkspaceFileContextStore: fixture.prompt.workspaceFileContextStore
            )
            agentModeVM.test_setSidebarAutoArchiveDependencies(
                promptManager: fixture.prompt,
                workspaceManager: fixture.manager
            )
            let indexOwner = AgentModeViewModel.SessionIndexOwner(
                workspaceID: fixture.workspaceA.id,
                activationEpoch: 1
            )
            agentModeVM.test_installSessionIndexSnapshot(
                [:],
                owner: indexOwner,
                latestOwner: indexOwner,
                activeWorkspace: fixture.workspaceA
            )

            let publicationGate = RecoveryInterleavingGate()
            let store = fixture.prompt.workspaceFileContextStore
            var cancelledSessionID: UUID?
            var staleTarget: AgentModeViewModel.MCPSessionTarget?
            var artifactURL: URL?
            var hookFailure: Error?
            var exactArtifactDeletionCount = 0
            let worktreeRoot = storageRoot.appendingPathComponent(
                "cancelled-explicit-tab-worktree",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
            agentModeVM.test_setAgentSessionDeleter { sessionID, workspace in
                XCTAssertEqual(sessionID, cancelledSessionID)
                XCTAssertEqual(workspace.id, fixture.workspaceA.id)
                exactArtifactDeletionCount += 1
                try await AgentSessionDataService.shared.deleteAgentSession(id: sessionID, for: workspace)
            }
            agentModeVM.test_setAfterDurableExplicitTabSessionBinding {
                do {
                    let sessionID = try XCTUnwrap(
                        fixture.manager.activeAgentSessionID(
                            forTabID: originalTab.id,
                            inWorkspaceID: fixture.workspaceA.id
                        )
                    )
                    cancelledSessionID = sessionID
                    staleTarget = agentModeVM.test_outstandingProvisionalMCPSessionTarget(
                        sessionID: sessionID
                    )
                    try await agentModeVM.mcpActivateControlContext(
                        forTabID: originalTab.id,
                        sessionID: sessionID,
                        originatingConnectionID: nil,
                        startPending: true
                    )
                    try agentModeVM.mcpStageAgentRunOracleReviewSource(
                        .captured(.init(
                            sourceTabID: fixture.rightTab.id,
                            workspaceID: fixture.workspaceA.id,
                            sourceSelectionRevision: 1,
                            promptText: "cancelled explicit binding source",
                            selection: StoredSelection(),
                            lookupContext: .visibleWorkspace,
                            reviewGitContext: .automaticOnly(
                                base: "HEAD",
                                workspaceRootPaths: fixture.workspaceA.repoPaths
                            ),
                            sourceAgentSessionID: nil,
                            sourceAgentRunID: nil,
                            sourceWorktreeBindings: []
                        )),
                        targetTabID: originalTab.id,
                        targetSessionID: sessionID,
                        expectedParentSessionID: nil
                    )
                    artifactURL = try await AgentSessionDataService.shared.saveAgentSession(
                        AgentSession(
                            id: sessionID,
                            workspaceID: fixture.workspaceA.id,
                            composeTabID: originalTab.id,
                            name: "Cancelled explicit binding",
                            savedAt: Date(timeIntervalSince1970: 1_800_000_400),
                            itemCount: 0,
                            autoEditEnabled: false
                        ),
                        for: fixture.workspaceA,
                        preparation: .alreadyCanonicalTranscript,
                        trustedCanonicalItemCount: 0
                    )
                    let preparation = try await store.prepareSessionWorktreeOwnership(
                        ownerID: sessionID,
                        bindingFingerprint: "cancelled-explicit-binding",
                        physicalRootPaths: [worktreeRoot.path]
                    )
                    _ = try await store.commitSessionWorktreeOwnership(preparation)
                } catch {
                    hookFailure = error
                }
                await publicationGate.markStartedAndWaitForRelease()
            }
            defer { agentModeVM.test_setAfterDurableExplicitTabSessionBinding(nil) }

            let resolution = Task { @MainActor in
                try await agentModeVM.mcpResolveOrCreateSessionTarget(
                    tabID: originalTab.id,
                    sessionID: nil,
                    createIfNeeded: true,
                    sessionName: "cancelled explicit binding",
                    expectedWorkspaceID: fixture.workspaceA.id
                )
            }
            await publicationGate.waitUntilStarted()
            XCTAssertNil(hookFailure)
            let sessionID = try XCTUnwrap(cancelledSessionID)
            let recoveredStaleTarget = try XCTUnwrap(staleTarget)
            XCTAssertTrue(try FileManager.default.fileExists(atPath: XCTUnwrap(artifactURL).path))
            XCTAssertTrue(agentModeVM.mcpHasAgentRunOracleReviewContextExpectation(tabID: originalTab.id))
            let installedOwnership = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
            XCTAssertEqual(installedOwnership.installedOwnerCount, 1)
            XCTAssertEqual(installedOwnership.rootClaimCount, 1)
            for competitor in [(originalTab.id as UUID?, nil as UUID?), (nil, sessionID as UUID?)] {
                do {
                    _ = try await agentModeVM.mcpResolveOrCreateSessionTarget(
                        tabID: competitor.0,
                        sessionID: competitor.1,
                        createIfNeeded: true,
                        sessionName: "must not adopt provisional binding",
                        expectedWorkspaceID: fixture.workspaceA.id
                    )
                    XCTFail("A competing selector must not adopt a provisional explicit-tab binding.")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("still provisional"), error.localizedDescription)
                }
            }

            resolution.cancel()
            await publicationGate.release()
            do {
                _ = try await resolution.value
                XCTFail("Cancellation after durable explicit-tab binding must reject resolution.")
            } catch {
                XCTAssertTrue(error is CancellationError, String(describing: error))
            }

            XCTAssertEqual(try XCTUnwrap(recoveredStaleTarget.recoveryClaim).state, .complete)
            XCTAssertEqual(exactArtifactDeletionCount, 1)
            XCTAssertFalse(try FileManager.default.fileExists(atPath: XCTUnwrap(artifactURL).path))
            XCTAssertNil(agentModeVM.session(for: originalTab.id, createIfNeeded: false))
            XCTAssertNil(agentModeVM.test_ownerValidatedSessionIndex[sessionID])
            XCTAssertFalse(agentModeVM.mcpHasAgentRunOracleReviewContextExpectation(tabID: originalTab.id))
            let cancelledRegistrationIsActive = await AgentRunSessionStore.hasActiveRegistration(
                sessionID: sessionID
            )
            XCTAssertFalse(cancelledRegistrationIsActive)
            let releasedOwnership = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
            XCTAssertEqual(releasedOwnership.installedOwnerCount, 0)
            XCTAssertEqual(releasedOwnership.rootClaimCount, 0)
            XCTAssertEqual(agentModeVM.test_outstandingProvisionalMCPSessionTargetCount, 0)
            XCTAssertEqual(agentModeVM.test_pendingMCPSessionTargetDiscardCount, 0)

            let canonical = try await canonicalModel(fixture)
            let disk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            let managerWorkspace = try XCTUnwrap(fixture.manager.workspace(withID: fixture.workspaceA.id))
            let promptWorkspace = try XCTUnwrap(fixture.prompt.sidebarWorkspaceSnapshot)
            for workspace in [managerWorkspace, canonical, disk] {
                XCTAssertEqual(workspace.composeTabs.count, originalTabCount)
                let recoveredTab = try XCTUnwrap(workspace.composeTabs.first { $0.id == originalTab.id })
                XCTAssertNil(recoveredTab.activeAgentSessionID)
                XCTAssertEqual(recoveredTab.name, originalTab.name)
                XCTAssertEqual(recoveredTab.promptText, originalTab.promptText)
                XCTAssertEqual(recoveredTab.selection, originalTab.selection)
                XCTAssertEqual(recoveredTab.isPinned, originalTab.isPinned)
            }
            XCTAssertEqual(promptWorkspace.composeTabs.count, originalTabCount)
            let sidebarTab = try XCTUnwrap(
                promptWorkspace.composeTabs.first { $0.id == originalTab.id }
            )
            XCTAssertNil(sidebarTab.activeAgentSessionID)
            XCTAssertEqual(sidebarTab.name, originalTab.name)
            XCTAssertEqual(sidebarTab.promptText, originalTab.promptText)
            XCTAssertEqual(sidebarTab.selection, originalTab.selection)
            XCTAssertEqual(sidebarTab.isPinned, originalTab.isPinned)
            let promptTab = try XCTUnwrap(
                fixture.prompt.currentComposeTabs.first { $0.id == originalTab.id }
            )
            XCTAssertNil(promptTab.activeAgentSessionID)
            XCTAssertEqual(promptTab.promptText, originalTab.promptText)
            XCTAssertEqual(promptTab.selection, originalTab.selection)

            agentModeVM.test_setAfterDurableExplicitTabSessionBinding(nil)
            let successor = try await agentModeVM.mcpResolveOrCreateSessionTarget(
                tabID: originalTab.id,
                sessionID: nil,
                createIfNeeded: true,
                sessionName: "accepted explicit-tab successor",
                expectedWorkspaceID: fixture.workspaceA.id
            )
            let successorSessionID = try XCTUnwrap(successor.sessionID)
            XCTAssertNotEqual(successorSessionID, sessionID)
            agentModeVM.mcpAcceptSessionTarget(successor)
            let staleReplay = await agentModeVM.mcpDiscardSessionTarget(recoveredStaleTarget)
            XCTAssertEqual(staleReplay, .complete)
            XCTAssertEqual(exactArtifactDeletionCount, 1)
            let successorCanonical = try await canonicalModel(fixture)
            let successorDisk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            for workspace in try [
                XCTUnwrap(fixture.manager.workspace(withID: fixture.workspaceA.id)),
                successorCanonical,
                successorDisk
            ] {
                XCTAssertTrue(workspace.composeTabs.contains {
                    $0.id == originalTab.id && $0.activeAgentSessionID == successorSessionID
                })
            }
            XCTAssertTrue(fixture.prompt.currentComposeTabs.contains {
                $0.id == originalTab.id && $0.activeAgentSessionID == successorSessionID
            })
            XCTAssertTrue(fixture.prompt.sidebarWorkspaceSnapshot?.composeTabs.contains {
                $0.id == originalTab.id && $0.activeAgentSessionID == successorSessionID
            } == true)
            let settledLookup = try await agentModeVM.mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: successorSessionID,
                createIfNeeded: false,
                sessionName: nil,
                expectedWorkspaceID: fixture.workspaceA.id
            )
            XCTAssertEqual(settledLookup.tabID, originalTab.id)
            XCTAssertNil(settledLookup.recoveryClaim)
            XCTAssertEqual(agentModeVM.test_outstandingProvisionalMCPSessionTargetCount, 0)
            XCTAssertEqual(agentModeVM.test_pendingMCPSessionTargetDiscardCount, 0)
            let freshCanonical = try await withFreshRuntime(for: fixture) { client in
                let snapshotValue = await client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
                let snapshot = try XCTUnwrap(snapshotValue)
                return try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: snapshot.document.documentBytes,
                    fileURL: snapshot.document.fileURL
                )
            }
            XCTAssertTrue(freshCanonical.composeTabs.contains {
                $0.id == originalTab.id && $0.activeAgentSessionID == successorSessionID
            })
            XCTAssertFalse(freshCanonical.composeTabs.contains {
                $0.activeAgentSessionID == sessionID
            })
        }

        func testInFlightCanonicalRecoveryRetiresBeforeSameSessionSuccessorAdmission() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let agentModeVM = AgentModeViewModel(
                testWorkspacePath: storageRoot.path,
                codexControllerFactory: { _, _, _, _, _, _ in
                    AgentAdmissionNoopCodexController()
                },
                testWorkspaceFileContextStore: fixture.prompt.workspaceFileContextStore
            )
            agentModeVM.test_setSidebarAutoArchiveDependencies(
                promptManager: fixture.prompt,
                workspaceManager: fixture.manager
            )
            let indexOwner = AgentModeViewModel.SessionIndexOwner(
                workspaceID: fixture.workspaceA.id,
                activationEpoch: 1
            )
            agentModeVM.test_installSessionIndexSnapshot(
                [:],
                owner: indexOwner,
                latestOwner: indexOwner,
                activeWorkspace: fixture.workspaceA
            )
            let staleSession = agentModeVM.session(for: fixture.identity.tabID)
            let staleBinding = try XCTUnwrap(agentModeVM.test_installPersistentSessionBinding(
                sessionID: fixture.identity.sessionID,
                on: staleSession
            ))
            let staleAuthorityID = UUID()
            agentModeVM.test_installMCPSessionTargetDiscardAuthority(
                staleAuthorityID,
                sessionID: fixture.identity.sessionID
            )
            agentModeVM.upsertSessionIndex(
                sessionID: fixture.identity.sessionID,
                tabID: fixture.identity.tabID,
                name: "Provisional",
                lastUserMessageAt: nil,
                savedAt: Date(timeIntervalSince1970: 1_800_000_000),
                lastRunStateRaw: AgentSessionRunState.idle.rawValue,
                itemCount: 0,
                agentKindRaw: "codex",
                agentModelRaw: "test-model",
                agentReasoningEffortRaw: nil,
                autoEditEnabled: false
            )
            let staleIndexEntry = try XCTUnwrap(
                agentModeVM.test_ownerValidatedSessionIndex[fixture.identity.sessionID]
            )
            let staleClaim = AgentProvisionalAdmissionClaim(identity: fixture.identity)
            let staleTarget = AgentModeViewModel.MCPSessionTarget(
                tabID: fixture.identity.tabID,
                sessionID: fixture.identity.sessionID,
                origin: .createdNewTab,
                lifecycleIdentity: .init(
                    workspaceID: fixture.identity.workspaceID,
                    tabID: fixture.identity.tabID,
                    sessionID: fixture.identity.sessionID,
                    persistentBindingGeneration: staleBinding.generation,
                    bindingTransitionGeneration: staleSession.bindingTransitionGeneration
                ),
                recoveryClaim: staleClaim,
                discardAuthorityID: staleAuthorityID
            )
            agentModeVM.test_registerOutstandingProvisionalMCPSessionTarget(staleTarget)
            guard agentModeVM.test_provisionalRuntimeTargetIdentityCount == 1 else {
                return XCTFail("The synthetic target must carry the exact registered runtime identity.")
            }
            let canonicalRecoveryGate = RecoveryInterleavingGate()
            fixture.manager.setAgentAdmissionRecoveryReplacementDispatchHandlerForTesting { workspaceID, _ in
                XCTAssertEqual(workspaceID, fixture.workspaceA.id)
                await canonicalRecoveryGate.markStartedAndWaitForRelease()
                return nil
            }
            defer {
                fixture.manager.setAgentAdmissionRecoveryReplacementDispatchHandlerForTesting(nil)
                agentModeVM.test_setBeforeMCPSessionTargetDiscardAuthorityEstablishment(nil)
                agentModeVM.test_setAfterMCPSessionTargetDiscardRetired(nil)
            }
            agentModeVM.test_setAgentSessionsDeleter { _, _ in }

            let staleDiscard = Task { @MainActor in
                await agentModeVM.mcpDiscardSessionTarget(staleTarget)
            }
            await canonicalRecoveryGate.waitUntilStarted()

            let successorAuthorityGate = RecoveryInterleavingGate()
            agentModeVM.test_setBeforeMCPSessionTargetDiscardAuthorityEstablishment { sessionID in
                guard sessionID == fixture.identity.sessionID else { return }
                await successorAuthorityGate.markStarted()
            }
            agentModeVM.test_setAfterMCPSessionTargetDiscardRetired { sessionID in
                XCTAssertEqual(sessionID, fixture.identity.sessionID)
                XCTAssertFalse(fixture.manager.workspaces.contains { workspace in
                    workspace.composeTabs.contains { $0.activeAgentSessionID == sessionID }
                })
                XCTAssertFalse(fixture.prompt.currentComposeTabs.contains {
                    $0.activeAgentSessionID == sessionID
                })
                if let preservedRuntime = agentModeVM.session(
                    for: fixture.identity.tabID,
                    createIfNeeded: false
                ) {
                    XCTAssertEqual(preservedRuntime.activeAgentSessionID, sessionID)
                    _ = agentModeVM.test_installPersistentSessionBinding(
                        sessionID: nil,
                        on: preservedRuntime
                    )
                }
                if let preservedIndexEntry = agentModeVM.test_ownerValidatedSessionIndex[sessionID] {
                    XCTAssertEqual(preservedIndexEntry, staleIndexEntry)
                }
            }
            var successorResolutionCompleted = false
            let successorResolution = Task { @MainActor in
                let target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
                    tabID: nil,
                    sessionID: fixture.identity.sessionID,
                    createIfNeeded: true,
                    sessionName: "canonical successor",
                    expectedWorkspaceID: fixture.workspaceA.id
                )
                successorResolutionCompleted = true
                return target
            }
            await successorAuthorityGate.waitUntilStarted()
            XCTAssertFalse(successorResolutionCompleted)

            await canonicalRecoveryGate.release()
            let staleDiscardResult = await staleDiscard.value
            XCTAssertEqual(staleDiscardResult, .complete)
            let successor = try await successorResolution.value
            let successorClaim = try XCTUnwrap(successor.recoveryClaim)
            let successorSession = try XCTUnwrap(agentModeVM.session(
                for: successor.tabID,
                createIfNeeded: false
            ))
            agentModeVM.upsertSessionIndex(
                sessionID: fixture.identity.sessionID,
                tabID: successor.tabID,
                name: "Canonical successor",
                lastUserMessageAt: nil,
                savedAt: Date(timeIntervalSince1970: 1_800_000_200),
                lastRunStateRaw: AgentSessionRunState.running.rawValue,
                itemCount: 1,
                agentKindRaw: "codex",
                agentModelRaw: "test-model",
                agentReasoningEffortRaw: nil,
                autoEditEnabled: false
            )
            try await agentModeVM.mcpActivateControlContext(
                forTabID: successor.tabID,
                sessionID: fixture.identity.sessionID,
                originatingConnectionID: nil,
                startPending: true
            )
            try agentModeVM.mcpStageAgentRunOracleReviewSource(
                .captured(.init(
                    sourceTabID: fixture.leftTab.id,
                    workspaceID: fixture.workspaceA.id,
                    sourceSelectionRevision: 1,
                    promptText: "canonical successor source",
                    selection: StoredSelection(),
                    lookupContext: .visibleWorkspace,
                    reviewGitContext: .automaticOnly(
                        base: "HEAD",
                        workspaceRootPaths: fixture.workspaceA.repoPaths
                    ),
                    sourceAgentSessionID: nil,
                    sourceAgentRunID: nil,
                    sourceWorktreeBindings: []
                )),
                targetTabID: successor.tabID,
                targetSessionID: fixture.identity.sessionID,
                expectedParentSessionID: nil
            )
            let successorRoot = storageRoot.appendingPathComponent("canonical-successor-root", isDirectory: true)
            try FileManager.default.createDirectory(at: successorRoot, withIntermediateDirectories: true)
            let store = fixture.prompt.workspaceFileContextStore
            let preparation = try await store.prepareSessionWorktreeOwnership(
                ownerID: fixture.identity.sessionID,
                bindingFingerprint: "canonical-successor-generation",
                physicalRootPaths: [successorRoot.path]
            )
            _ = try await store.commitSessionWorktreeOwnership(preparation)
            let successorIndexEntry = try XCTUnwrap(
                agentModeVM.test_ownerValidatedSessionIndex[fixture.identity.sessionID]
            )
            agentModeVM.mcpAcceptSessionTarget(successor)

            XCTAssertEqual(staleClaim.state, .complete)
            XCTAssertEqual(successorClaim.state, .accepted)
            XCTAssertTrue(agentModeVM.session(for: successor.tabID, createIfNeeded: false) === successorSession)
            XCTAssertTrue(agentModeVM.mcpHasAgentRunOracleReviewContextExpectation(tabID: successor.tabID))
            XCTAssertEqual(
                agentModeVM.test_ownerValidatedSessionIndex[fixture.identity.sessionID],
                successorIndexEntry
            )
            let ownership = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()
            XCTAssertEqual(ownership.installedOwnerCount, 1)
            XCTAssertEqual(ownership.rootClaimCount, 1)
            let canonical = try await canonicalModel(fixture)
            let disk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            for workspace in try [
                XCTUnwrap(fixture.manager.workspace(withID: fixture.workspaceA.id)),
                canonical,
                disk
            ] {
                XCTAssertTrue(workspace.composeTabs.contains {
                    $0.id == successor.tabID
                        && $0.activeAgentSessionID == fixture.identity.sessionID
                })
            }
        }

        func testFreshTargetReservesRecoveryAgainstSessionAndTabSelectorsBeforeResolverReturns() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let baselineTabIDs = fixture.workspaceA.composeTabs.map(\.id)
            let agentModeVM = AgentModeViewModel(
                testWorkspacePath: storageRoot.path,
                codexControllerFactory: { _, _, _, _, _, _ in
                    AgentAdmissionNoopCodexController()
                },
                testWorkspaceFileContextStore: fixture.prompt.workspaceFileContextStore
            )
            agentModeVM.test_setSidebarAutoArchiveDependencies(
                promptManager: fixture.prompt,
                workspaceManager: fixture.manager
            )
            let indexOwner = AgentModeViewModel.SessionIndexOwner(
                workspaceID: fixture.workspaceA.id,
                activationEpoch: 1
            )
            agentModeVM.test_installSessionIndexSnapshot(
                [:],
                owner: indexOwner,
                latestOwner: indexOwner,
                activeWorkspace: fixture.workspaceA
            )

            let publicationGate = RecoveryInterleavingGate()
            var publishedTabID: UUID?
            var publishedSessionID: UUID?
            var resolverReturned = false
            var artifactDeletionCount = 0
            agentModeVM.test_setAfterDurableChildTabCreation {
                let publishedTab = fixture.manager.workspace(withID: fixture.workspaceA.id)?.composeTabs.first(where: {
                    !baselineTabIDs.contains($0.id)
                })
                publishedTabID = publishedTab?.id
                publishedSessionID = publishedTab?.activeAgentSessionID
                XCTAssertNotNil(publishedTabID)
                XCTAssertNotNil(publishedSessionID)
                XCTAssertFalse(resolverReturned)
                XCTAssertEqual(agentModeVM.test_outstandingProvisionalMCPSessionTargetCount, 1)
                await publicationGate.markStartedAndWaitForRelease()
            }
            defer { agentModeVM.test_setAfterDurableChildTabCreation(nil) }
            agentModeVM.test_setAgentSessionsDeleter { tabID, workspace in
                XCTAssertEqual(tabID, publishedTabID)
                XCTAssertEqual(workspace.id, fixture.workspaceA.id)
                artifactDeletionCount += 1
            }

            let originalResolution = Task { @MainActor in
                let target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
                    tabID: nil,
                    sessionID: nil,
                    createIfNeeded: true,
                    sessionName: "cancelled after durable publication",
                    expectedWorkspaceID: fixture.workspaceA.id
                )
                resolverReturned = true
                return target
            }
            await publicationGate.waitUntilStarted()

            let sessionID = try XCTUnwrap(publishedSessionID)
            let tabID = try XCTUnwrap(publishedTabID)
            XCTAssertFalse(resolverReturned)
            XCTAssertEqual(agentModeVM.test_outstandingProvisionalMCPSessionTargetCount, 1)
            XCTAssertEqual(agentModeVM.test_pendingMCPSessionTargetDiscardCount, 0)
            do {
                _ = try await agentModeVM.mcpResolveOrCreateSessionTarget(
                    tabID: nil,
                    sessionID: sessionID,
                    createIfNeeded: true,
                    sessionName: "must not steal fresh recovery",
                    expectedWorkspaceID: fixture.workspaceA.id
                )
                XCTFail("A same-session resolver must not acquire a durably published provisional target.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("still provisional"), error.localizedDescription)
            }
            XCTAssertFalse(resolverReturned)
            XCTAssertEqual(agentModeVM.test_outstandingProvisionalMCPSessionTargetCount, 1)
            do {
                _ = try await agentModeVM.mcpResolveOrCreateSessionTarget(
                    tabID: tabID,
                    sessionID: nil,
                    createIfNeeded: true,
                    sessionName: "must not adopt fresh recovery by tab",
                    expectedWorkspaceID: fixture.workspaceA.id
                )
                XCTFail("A tab-only resolver must not adopt a durably published provisional target.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("still provisional"), error.localizedDescription)
            }
            XCTAssertFalse(resolverReturned)
            XCTAssertEqual(agentModeVM.test_outstandingProvisionalMCPSessionTargetCount, 1)

            originalResolution.cancel()
            await publicationGate.release()
            do {
                _ = try await originalResolution.value
                XCTFail("Cancellation after durable publication must fail the original resolution.")
            } catch {
                XCTAssertTrue(error is CancellationError, String(describing: error))
            }

            XCTAssertFalse(resolverReturned)
            XCTAssertEqual(agentModeVM.test_outstandingProvisionalMCPSessionTargetCount, 0)
            XCTAssertEqual(agentModeVM.test_pendingMCPSessionTargetDiscardCount, 0)
            XCTAssertNil(agentModeVM.session(for: tabID, createIfNeeded: false))
            XCTAssertNil(agentModeVM.test_ownerValidatedSessionIndex[sessionID])
            XCTAssertEqual(artifactDeletionCount, 1)
            let canonical = try await canonicalModel(fixture)
            let disk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            for workspace in try [
                XCTUnwrap(fixture.manager.workspace(withID: fixture.workspaceA.id)),
                canonical,
                disk
            ] {
                XCTAssertEqual(workspace.composeTabs.map(\.id), baselineTabIDs)
                XCTAssertFalse(workspace.composeTabs.contains { $0.activeAgentSessionID == sessionID })
            }
            XCTAssertEqual(fixture.prompt.currentComposeTabs.map(\.id), baselineTabIDs)

            agentModeVM.test_setAfterDurableChildTabCreation(nil)
            let successor = try await agentModeVM.mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: sessionID,
                createIfNeeded: true,
                sessionName: "accepted successor",
                expectedWorkspaceID: fixture.workspaceA.id
            )
            agentModeVM.mcpAcceptSessionTarget(successor)
            XCTAssertEqual(agentModeVM.test_outstandingProvisionalMCPSessionTargetCount, 0)
            let acceptedDiscardResult = await agentModeVM.mcpDiscardSessionTarget(successor)
            XCTAssertEqual(acceptedDiscardResult, .complete)
            XCTAssertNotNil(agentModeVM.session(for: successor.tabID, createIfNeeded: false))
            XCTAssertTrue(fixture.manager.workspace(withID: fixture.workspaceA.id)?.composeTabs.contains(where: {
                $0.id == successor.tabID && $0.activeAgentSessionID == sessionID
            }) == true)
            XCTAssertEqual(artifactDeletionCount, 1)

            let postAcceptanceLookup = try await agentModeVM.mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: sessionID,
                createIfNeeded: false,
                sessionName: nil,
                expectedWorkspaceID: fixture.workspaceA.id
            )
            XCTAssertEqual(postAcceptanceLookup.tabID, successor.tabID)
            XCTAssertNil(postAcceptanceLookup.recoveryClaim)
        }

        func testFixedSessionReconstructionPublishesRecoveryBeforeParentInvalidation() async throws {
            let fixture = try await makeFixture()
            fixture.manager.activeWorkspace = fixture.workspaceA
            fixture.prompt.loadComposeTabsFromWorkspace(fixture.workspaceA)
            let baselineTabIDs = fixture.workspaceA.composeTabs.map(\.id)
            let parentTabID = fixture.identity.tabID
            let parentSessionID = fixture.identity.sessionID
            let reconstructedSessionID = UUID()
            let restoredTabID = UUID()
            let agentModeVM = AgentModeViewModel(
                testWorkspacePath: storageRoot.path,
                codexControllerFactory: { _, _, _, _, _, _ in
                    AgentAdmissionNoopCodexController()
                },
                testWorkspaceFileContextStore: fixture.prompt.workspaceFileContextStore
            )
            agentModeVM.test_setSidebarAutoArchiveDependencies(
                promptManager: fixture.prompt,
                workspaceManager: fixture.manager
            )
            let indexOwner = AgentModeViewModel.SessionIndexOwner(
                workspaceID: fixture.workspaceA.id,
                activationEpoch: 1
            )
            agentModeVM.test_installSessionIndexSnapshot(
                [:],
                owner: indexOwner,
                latestOwner: indexOwner,
                activeWorkspace: fixture.workspaceA
            )
            agentModeVM.upsertSessionIndex(
                sessionID: reconstructedSessionID,
                tabID: restoredTabID,
                name: "Persisted reconstruction",
                lastUserMessageAt: nil,
                savedAt: Date(timeIntervalSince1970: 1_800_000_300),
                lastRunStateRaw: AgentSessionRunState.completed.rawValue,
                itemCount: 4,
                agentKindRaw: "codex",
                agentModelRaw: "test-model",
                agentReasoningEffortRaw: nil,
                autoEditEnabled: false
            )
            let restoreEntry = try XCTUnwrap(
                agentModeVM.test_ownerValidatedSessionIndex[reconstructedSessionID]
            )

            let publicationGate = RecoveryInterleavingGate()
            var publishedTabID: UUID?
            var staleTarget: AgentModeViewModel.MCPSessionTarget?
            var resolverReturned = false
            var artifactDeletionCount = 0
            agentModeVM.test_setAfterDurableChildTabCreation {
                let publishedTab = fixture.manager.workspace(withID: fixture.workspaceA.id)?.composeTabs.first(where: {
                    !baselineTabIDs.contains($0.id)
                })
                publishedTabID = publishedTab?.id
                staleTarget = agentModeVM.test_outstandingProvisionalMCPSessionTarget(
                    sessionID: reconstructedSessionID
                )
                XCTAssertEqual(publishedTab?.activeAgentSessionID, reconstructedSessionID)
                XCTAssertNotNil(staleTarget)
                XCTAssertFalse(resolverReturned)
                XCTAssertEqual(agentModeVM.test_outstandingProvisionalMCPSessionTargetCount, 1)
                await publicationGate.markStartedAndWaitForRelease()
            }
            defer { agentModeVM.test_setAfterDurableChildTabCreation(nil) }
            agentModeVM.test_setAgentSessionsDeleter { _, _ in
                artifactDeletionCount += 1
            }

            let reconstruction = Task { @MainActor in
                let target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
                    tabID: nil,
                    sessionID: reconstructedSessionID,
                    createIfNeeded: true,
                    sessionName: "reconstructed after persistence",
                    parentSessionID: parentSessionID,
                    expectedWorkspaceID: fixture.workspaceA.id
                )
                resolverReturned = true
                return target
            }
            await publicationGate.waitUntilStarted()

            let childTabID = try XCTUnwrap(publishedTabID)
            let persistedTabs = try XCTUnwrap(
                fixture.manager.workspace(withID: fixture.workspaceA.id)?.composeTabs
            )
            let invalidatedPromptTabs = persistedTabs.filter { $0.id != parentTabID }
            fixture.prompt.setCurrentComposeTabsForAgentAdmissionRecoveryTesting(
                invalidatedPromptTabs,
                activeComposeTabID: childTabID
            )
            XCTAssertFalse(fixture.prompt.currentComposeTabs.contains { tab in
                tab.activeAgentSessionID == parentSessionID
            })
            XCTAssertTrue(fixture.prompt.currentComposeTabs.contains { tab in
                tab.id == childTabID && tab.activeAgentSessionID == reconstructedSessionID
            })

            await publicationGate.release()
            do {
                _ = try await reconstruction.value
                XCTFail("A reconstructed child must reject when its represented parent disappears.")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains("parent Agent session was removed"),
                    error.localizedDescription
                )
            }

            XCTAssertFalse(resolverReturned)
            let recoveredStaleTarget = try XCTUnwrap(staleTarget)
            XCTAssertEqual(try XCTUnwrap(recoveredStaleTarget.recoveryClaim).state, .complete)
            XCTAssertEqual(agentModeVM.test_outstandingProvisionalMCPSessionTargetCount, 0)
            XCTAssertEqual(agentModeVM.test_pendingMCPSessionTargetDiscardCount, 0)
            if let preservedRuntime = agentModeVM.session(for: childTabID, createIfNeeded: false) {
                XCTAssertEqual(preservedRuntime.activeAgentSessionID, reconstructedSessionID)
                _ = agentModeVM.test_installPersistentSessionBinding(
                    sessionID: nil,
                    on: preservedRuntime
                )
            }
            let hasActiveRegistration = await AgentRunSessionStore.hasActiveRegistration(
                sessionID: reconstructedSessionID
            )
            XCTAssertFalse(hasActiveRegistration)
            XCTAssertEqual(
                agentModeVM.test_ownerValidatedSessionIndex[reconstructedSessionID],
                restoreEntry
            )
            XCTAssertEqual(
                artifactDeletionCount,
                0,
                "Reconstruction recovery preserves the pre-existing session artifact."
            )
            let canonical = try await canonicalModel(fixture)
            let disk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            for workspace in try [
                XCTUnwrap(fixture.manager.workspace(withID: fixture.workspaceA.id)),
                canonical,
                disk
            ] {
                XCTAssertEqual(workspace.composeTabs.map(\.id), baselineTabIDs)
                XCTAssertFalse(workspace.composeTabs.contains { tab in
                    tab.id == childTabID || tab.activeAgentSessionID == reconstructedSessionID
                })
            }
            XCTAssertEqual(
                fixture.prompt.currentComposeTabs.map(\.id),
                [fixture.leftTab.id, fixture.rightTab.id]
            )
            XCTAssertFalse(fixture.prompt.currentComposeTabs.contains { tab in
                tab.id == childTabID || tab.activeAgentSessionID == reconstructedSessionID
            })

            agentModeVM.test_setAfterDurableChildTabCreation(nil)
            let successor = try await agentModeVM.mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: reconstructedSessionID,
                createIfNeeded: true,
                sessionName: "accepted reconstructed successor",
                expectedWorkspaceID: fixture.workspaceA.id
            )
            agentModeVM.mcpAcceptSessionTarget(successor)
            XCTAssertEqual(agentModeVM.test_outstandingProvisionalMCPSessionTargetCount, 0)

            let staleDiscardResult = await agentModeVM.mcpDiscardSessionTarget(recoveredStaleTarget)
            XCTAssertEqual(staleDiscardResult, .complete)
            XCTAssertNotNil(agentModeVM.session(for: successor.tabID, createIfNeeded: false))
            XCTAssertTrue(fixture.manager.workspace(withID: fixture.workspaceA.id)?.composeTabs.contains(where: { tab in
                tab.id == successor.tabID && tab.activeAgentSessionID == reconstructedSessionID
            }) == true)
            XCTAssertEqual(artifactDeletionCount, 0)

            let postAcceptanceLookup = try await agentModeVM.mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: reconstructedSessionID,
                createIfNeeded: false,
                sessionName: nil,
                expectedWorkspaceID: fixture.workspaceA.id
            )
            XCTAssertEqual(postAcceptanceLookup.tabID, successor.tabID)
            XCTAssertNil(postAcceptanceLookup.recoveryClaim)
        }

        private struct Fixture {
            let runtime: MCPDomainRuntime
            let client: DomainWorkspaceAuthorityClient
            let manager: WorkspaceManagerViewModel
            let prompt: PromptViewModel
            let workspaceA: WorkspaceModel
            let workspaceB: WorkspaceModel
            let workspaceAURL: URL
            let workspaceBURL: URL
            let profileIdentifier: String
            let runtimeStorageDirectory: URL
            let identity: AgentProvisionalAdmissionIdentity
            let leftTab: ComposeTabState
            let rightTab: ComposeTabState
        }

        private func makeAgentModeViewModel(
            for fixture: Fixture,
            indexEntries: [UUID: AgentSessionIndexEntry] = [:]
        ) -> AgentModeViewModel {
            let viewModel = AgentModeViewModel(
                testWorkspacePath: storageRoot.path,
                codexControllerFactory: { _, _, _, _, _, _ in
                    AgentAdmissionNoopCodexController()
                },
                testWorkspaceFileContextStore: fixture.prompt.workspaceFileContextStore
            )
            viewModel.test_setSidebarAutoArchiveDependencies(
                promptManager: fixture.prompt,
                workspaceManager: fixture.manager
            )
            let owner = AgentModeViewModel.SessionIndexOwner(
                workspaceID: fixture.workspaceA.id,
                activationEpoch: 1
            )
            viewModel.test_installSessionIndexSnapshot(
                indexEntries,
                owner: owner,
                latestOwner: owner,
                activeWorkspace: fixture.workspaceA
            )
            return viewModel
        }

        private func upsertIndexEntry(
            _ sessionID: UUID,
            tabID: UUID,
            parentSessionID: UUID? = nil,
            in viewModel: AgentModeViewModel
        ) -> AgentSessionIndexEntry {
            viewModel.upsertSessionIndex(
                sessionID: sessionID,
                tabID: tabID,
                name: "Admission recovery test",
                lastUserMessageAt: nil,
                savedAt: Date(timeIntervalSince1970: 1_800_000_500),
                lastRunStateRaw: AgentSessionRunState.idle.rawValue,
                itemCount: 0,
                agentKindRaw: "codex",
                agentModelRaw: "test-model",
                agentReasoningEffortRaw: nil,
                autoEditEnabled: false,
                parentSessionID: parentSessionID
            )
            return viewModel.test_ownerValidatedSessionIndex[sessionID]!
        }

        private func makeFixture() async throws -> Fixture {
            let sessionID = UUID()
            let provisional = ComposeTabState(
                name: "Provisional",
                isPinned: true,
                activeAgentSessionID: sessionID,
                promptText: "remove only me"
            )
            let left = ComposeTabState(
                name: "Left",
                selection: StoredSelection(selectedPaths: ["/tmp/left"]),
                promptText: "left prompt"
            )
            let right = ComposeTabState(
                name: "Right",
                selection: StoredSelection(selectedPaths: ["/tmp/right"]),
                promptText: "right prompt"
            )
            let workspaceA = WorkspaceModel(
                name: "Recovery A",
                repoPaths: ["/tmp/recovery-a"],
                lastSearchQuery: "keep search",
                selectedMetaPromptIDs: [UUID()],
                isHiddenInMenus: true,
                composeTabs: [left, provisional, right],
                activeComposeTabID: provisional.id
            )
            let workspaceBTab = ComposeTabState(name: "Unrelated", promptText: "untouched")
            let workspaceB = WorkspaceModel(
                name: "Recovery B",
                repoPaths: ["/tmp/recovery-b"],
                currentPromptText: "unrelated workspace",
                composeTabs: [workspaceBTab],
                activeComposeTabID: workspaceBTab.id
            )
            let workspaceAURL = try writeWorkspace(workspaceA)
            let workspaceBURL = try writeWorkspace(workspaceB)
            try writeIndex([workspaceA, workspaceB])

            let profileIdentifier = "agent-admission-recovery-\(UUID().uuidString)"
            let runtimeStorageDirectory = storageRoot.appendingPathComponent(
                "runtime-state-\(UUID().uuidString)",
                isDirectory: true
            )
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: profileIdentifier,
                storageDirectory: runtimeStorageDirectory,
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events-\(UUID().uuidString)", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp-\(UUID().uuidString)", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            runtimes.append(runtime)
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -882)
            let (manager, prompt) = makeManager(client: client)
            await manager.awaitInitialized()
            return Fixture(
                runtime: runtime,
                client: client,
                manager: manager,
                prompt: prompt,
                workspaceA: workspaceA,
                workspaceB: workspaceB,
                workspaceAURL: workspaceAURL,
                workspaceBURL: workspaceBURL,
                profileIdentifier: profileIdentifier,
                runtimeStorageDirectory: runtimeStorageDirectory,
                identity: AgentProvisionalAdmissionIdentity(
                    recoveryID: UUID(),
                    workspaceID: workspaceA.id,
                    tabID: provisional.id,
                    sessionID: sessionID,
                    replacementTabID: UUID()
                ),
                leftTab: left,
                rightTab: right
            )
        }

        private func withFreshRuntime<T>(
            for fixture: Fixture,
            operation: (DomainWorkspaceAuthorityClient) async throws -> T
        ) async throws -> T {
            _ = await fixture.runtime.shutdown()
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: fixture.profileIdentifier,
                storageDirectory: fixture.runtimeStorageDirectory,
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent(
                    "events-fresh-\(UUID().uuidString)",
                    isDirectory: true
                ),
                temporaryDirectory: storageRoot.appendingPathComponent(
                    "tmp-fresh-\(UUID().uuidString)",
                    isDirectory: true
                ),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            runtimes.append(runtime)
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -884)
            do {
                let result = try await operation(client)
                _ = await runtime.shutdown()
                return result
            } catch {
                _ = await runtime.shutdown()
                throw error
            }
        }

        private func makeCompetingClient(
            _ fixture: Fixture
        ) async throws -> DomainWorkspaceAuthorityClient {
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: fixture.profileIdentifier,
                storageDirectory: fixture.runtimeStorageDirectory,
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent(
                    "events-competitor-\(UUID().uuidString)",
                    isDirectory: true
                ),
                temporaryDirectory: storageRoot.appendingPathComponent(
                    "tmp-competitor-\(UUID().uuidString)",
                    isDirectory: true
                ),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            runtimes.append(runtime)
            return DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -883)
        }

        private func commitCanonicalSuccessor(
            client: DomainWorkspaceAuthorityClient,
            fixture: Fixture,
            sessionID: UUID,
            marker: String
        ) async throws -> DomainWorkspaceSnapshot {
            for _ in 0 ..< 3 {
                _ = await client.reloadExternalChanges()
                let beforeValue = await client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
                let before = try XCTUnwrap(beforeValue)
                var successor = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: before.document.documentBytes,
                    fileURL: before.document.fileURL
                )
                if let provisionalIndex = successor.composeTabs.firstIndex(where: {
                    $0.id == fixture.identity.tabID
                }) {
                    successor.composeTabs[provisionalIndex].activeAgentSessionID = sessionID
                    successor.composeTabs[provisionalIndex].promptText = marker
                } else {
                    successor.composeTabs.insert(
                        ComposeTabState(
                            id: fixture.identity.tabID,
                            name: "Canonical successor",
                            activeAgentSessionID: sessionID,
                            promptText: marker
                        ),
                        at: min(1, successor.composeTabs.count)
                    )
                }
                successor.activeComposeTabID = fixture.identity.tabID
                let working = try await client.replaceWorking(
                    successor,
                    fileURL: fixture.workspaceAURL,
                    expectedWorkspaceRevision: before.revisions.workingRevision
                )
                if working.disposition == .conflict,
                   working.errorCode == .stateConflict
                {
                    continue
                }
                guard working.disposition == .applied || working.disposition == .unchanged else {
                    throw NSError(
                        domain: "AgentAdmissionRecoveryTests.CompetingWriter",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "working disposition \(working.disposition)"]
                    )
                }
                let saved = try await client.save(
                    successor,
                    fileURL: fixture.workspaceAURL,
                    expectedWorkspaceRevision: working.after?.workingRevision
                        ?? working.workspace?.revisions.workingRevision,
                    expectedContentDigest: working.resultingDigest
                )
                guard saved.disposition == .applied || saved.disposition == .unchanged else {
                    throw NSError(
                        domain: "AgentAdmissionRecoveryTests.CompetingWriter",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "save disposition \(saved.disposition)"]
                    )
                }
                let finalValue = await client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
                return try XCTUnwrap(finalValue)
            }
            throw NSError(
                domain: "AgentAdmissionRecoveryTests.CompetingWriter",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "unable to acquire successor revision"]
            )
        }

        private func assertSuccessorProjection(
            _ fixture: Fixture,
            sessionID: UUID,
            marker: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let managerWorkspace = try XCTUnwrap(
                fixture.manager.workspace(withID: fixture.workspaceA.id),
                file: file,
                line: line
            )
            XCTAssertTrue(managerWorkspace.composeTabs.contains {
                $0.id == fixture.identity.tabID
                    && $0.activeAgentSessionID == sessionID
                    && $0.promptText == marker
            }, file: file, line: line)
            XCTAssertTrue(fixture.prompt.currentComposeTabs.contains {
                $0.id == fixture.identity.tabID
                    && $0.activeAgentSessionID == sessionID
                    && $0.promptText == marker
            }, file: file, line: line)
            XCTAssertTrue(fixture.prompt.sidebarWorkspaceSnapshot?.composeTabs.contains {
                $0.id == fixture.identity.tabID
                    && $0.activeAgentSessionID == sessionID
                    && $0.promptText == marker
            } == true, file: file, line: line)
            XCTAssertFalse(managerWorkspace.composeTabs.contains {
                $0.activeAgentSessionID == fixture.identity.sessionID
            }, file: file, line: line)
            XCTAssertFalse(fixture.prompt.currentComposeTabs.contains {
                $0.activeAgentSessionID == fixture.identity.sessionID
            }, file: file, line: line)
        }

        private func publishOrdinarySuccessorEdit(
            _ fixture: Fixture,
            successorSessionID: UUID,
            marker: String
        ) async throws {
            let index = try XCTUnwrap(fixture.manager.workspaces.firstIndex {
                $0.id == fixture.workspaceA.id
            })
            fixture.manager.workspaces[index].lastSearchQuery = marker
            fixture.manager.markWorkspaceDirty(workspaceID: fixture.workspaceA.id)
            await fixture.manager.debugPublishWorkingDocumentToDomainAuthority(
                fixture.manager.workspaces[index]
            )
            let save = await fixture.manager.pollAndSaveStateWithOutcomeAsync(
                workspaceID: fixture.workspaceA.id,
                source: WorkspaceSaveSource("successorConflictOrdinarySave")
            )
            XCTAssertTrue(save.acceptedForLifecycleAdmission)

            let canonical = try await canonicalModel(fixture)
            let disk = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceAURL,
                scheduleNormalizationWriteback: false
            )
            for workspace in [canonical, disk] {
                XCTAssertEqual(workspace.lastSearchQuery, marker)
                XCTAssertTrue(workspace.composeTabs.contains {
                    $0.id == fixture.identity.tabID
                        && $0.activeAgentSessionID == successorSessionID
                })
                XCTAssertFalse(workspace.composeTabs.contains {
                    $0.activeAgentSessionID == fixture.identity.sessionID
                })
            }
        }

        private func makeManager(
            client: DomainWorkspaceAuthorityClient?
        ) -> (WorkspaceManagerViewModel, PromptViewModel) {
            let keyManager = KeyManager(
                secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
            )
            let aiQueriesService = AIQueriesService(keyManager: keyManager)
            let fileManager = WorkspaceFilesViewModel()
            let apiSettings = APISettingsViewModel(
                aiQueriesService: aiQueriesService,
                keyManager: keyManager,
                loadStoredDataOnInit: false
            )
            let prompt = PromptViewModel(
                fileManager: fileManager,
                apiSettingsViewModel: apiSettings,
                windowID: -882,
                settingsManager: WindowSettingsManager(windowID: -882)
            )
            let manager = WorkspaceManagerViewModel(
                fileManager: fileManager,
                promptViewModel: prompt,
                domainWorkspaceAuthorityClient: client,
                performInitialWorkspaceActivation: false
            )
            managers.append(manager)
            return (manager, prompt)
        }

        private func writeWorkspace(_ workspace: WorkspaceModel) throws -> URL {
            let url = storageRoot
                .appendingPathComponent(
                    DomainWorkspaceStoragePath.directoryName(name: workspace.name, id: workspace.id),
                    isDirectory: true
                )
                .appendingPathComponent("workspace.json")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(workspace).write(to: url, options: .atomic)
            return url
        }

        private func writeIndex(_ workspaces: [WorkspaceModel]) throws {
            let entries = workspaces.map {
                WorkspaceIndexEntry(
                    id: $0.id,
                    name: $0.name,
                    customStoragePath: $0.customStoragePath,
                    isSystemWorkspace: $0.isSystemWorkspace,
                    isHiddenInMenus: $0.isHiddenInMenus
                )
            }
            try JSONEncoder().encode(entries).write(
                to: storageRoot.appendingPathComponent("workspacesIndex.json"),
                options: .atomic
            )
        }

        private func canonicalModel(_ fixture: Fixture) async throws -> WorkspaceModel {
            let snapshotValue = await fixture.client.canonicalWorkspaceSnapshot(fixture.workspaceA.id)
            let snapshot = try XCTUnwrap(snapshotValue)
            return try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                documentBytes: snapshot.document.documentBytes,
                fileURL: snapshot.document.fileURL
            )
        }

        private func assertNonComposeFieldsEqual(
            _ recovered: WorkspaceModel,
            _ original: WorkspaceModel,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            var normalizedRecovered = recovered
            normalizedRecovered.composeTabs = original.composeTabs
            normalizedRecovered.activeComposeTabID = original.activeComposeTabID
            normalizedRecovered.dateModified = original.dateModified
            XCTAssertEqual(normalizedRecovered, original, file: file, line: line)
        }
    }

    private final class AgentAdmissionNoopCodexController: CodexSessionControlling {
        private(set) var hasActiveThread = false

        var events: AsyncStream<CodexNativeSessionController.Event> {
            AsyncStream { _ in }
        }

        func ensureEventsStreamReady() {}

        func startOrResume(
            existing: CodexNativeSessionController.SessionRef?,
            baseInstructions: String
        ) async throws -> CodexNativeSessionController.SessionRef {
            try await startOrResume(
                existing: existing,
                baseInstructions: baseInstructions,
                model: nil,
                reasoningEffort: nil,
                serviceTier: nil
            )
        }

        func startOrResume(
            existing: CodexNativeSessionController.SessionRef?,
            baseInstructions: String,
            model: String?,
            reasoningEffort: String?
        ) async throws -> CodexNativeSessionController.SessionRef {
            try await startOrResume(
                existing: existing,
                baseInstructions: baseInstructions,
                model: model,
                reasoningEffort: reasoningEffort,
                serviceTier: nil
            )
        }

        func startOrResume(
            existing _: CodexNativeSessionController.SessionRef?,
            baseInstructions _: String,
            model: String?,
            reasoningEffort: String?,
            serviceTier _: String?
        ) async throws -> CodexNativeSessionController.SessionRef {
            hasActiveThread = true
            return CodexNativeSessionController.SessionRef(
                conversationID: "agent-admission-test",
                rolloutPath: nil,
                model: model,
                reasoningEffort: reasoningEffort
            )
        }

        func readThreadSnapshot(
            includeTurns _: Bool,
            timeout _: TimeInterval?
        ) async throws -> CodexNativeSessionController.ThreadSnapshot {
            CodexNativeSessionController.ThreadSnapshot(
                conversationID: "agent-admission-test",
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

        func startUserTurn(
            text _: String,
            images _: [AgentImageAttachment],
            model _: String?,
            reasoningEffort _: String?,
            serviceTier _: String?
        ) async throws -> CodexTurnStartReceipt {
            CodexTurnStartReceipt(provisionalSubmissionID: "agent-admission-test")
        }

        func steerUserTurn(
            text _: String,
            images _: [AgentImageAttachment],
            expectedTurnID: String
        ) async throws -> CodexTurnSteerReceipt {
            CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
        }

        func prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(
            expectedCurrentTurnID _: String,
            acceptedDispatchTurnID _: String
        ) async -> Bool {
            true
        }

        func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
            CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
        }

        func reconcileAndInterruptCurrentTurn() async throws -> CodexTurnInterruptReceipt {
            CodexTurnInterruptReceipt(interruptedTurnID: "agent-admission-test")
        }

        func compactThread() async throws {}

        func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
            nil
        }

        func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
            throw CancellationError()
        }

        func setThreadGoalStatus(
            _: CodexNativeSessionController.ThreadGoalStatus
        ) async throws -> CodexNativeSessionController.ThreadGoal {
            throw CancellationError()
        }

        func clearThreadGoal() async throws -> Bool {
            false
        }

        func pendingTurnFailure(
            turnID _: String?
        ) async -> CodexNativeSessionController.TurnFailure? {
            nil
        }

        func acknowledgePendingTurnFailure(
            turnID _: String?,
            failure _: CodexNativeSessionController.TurnFailure
        ) async {}

        func cancelCurrentTurn() async {}
        func shutdown() async {}
        func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
    }
#endif
