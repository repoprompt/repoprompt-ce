import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class ConcurrentSameWorkspaceAgentRunAdmissionTests: XCTestCase {
        private var cleanupOperation: (@MainActor () async -> Void)?

        override func setUp() async throws {
            try await super.setUp()
            await AdmissionTestSuiteGate.shared.acquire()
        }

        override func tearDown() async throws {
            if let cleanupOperation {
                await cleanupOperation()
                self.cleanupOperation = nil
            }
            await AdmissionTestSuiteGate.shared.release()
            try await super.tearDown()
        }

        private func trackCleanup(_ operation: @escaping @MainActor () async -> Void) {
            precondition(cleanupOperation == nil)
            cleanupOperation = operation
        }

        func testSixOverlappingAgentRunStartsPersistUniqueIdentitiesAndDispatchProvidersExactlyOnce() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make()
            trackCleanup {
                await fixture.cleanup()
            }
            let workspaceID = fixture.workspaceID
            let initialWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            let initialTabs = initialWorkspace.composeTabs
            let initialTabIDs = Set(initialTabs.map(\.id))
            let initialActiveTabID = initialWorkspace.activeComposeTabID
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let coordinatorBaseline = coordinator.snapshot()
            let saveGate = AdmissionSaveGate()
            let providerRecorder = AdmissionProviderRecorder(expectedCount: 6)
            fixture.window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting {
                savedWorkspaceID,
                _,
                _ in
                guard savedWorkspaceID == workspaceID,
                      coordinator.activeCount(for: workspaceID) > 0
                else { return }
                await saveGate.enterFirstAndWait()
            }
            defer {
                fixture.window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
            }

            let service = makeAgentRunStartService(
                window: fixture.window,
                recorder: providerRecorder,
                validateBeforeProviderDispatch: { pair in
                    let canonicalSnapshot = await fixture.runtime.workspaceStore
                        .canonicalWorkspaceSnapshot(workspaceID)
                    let canonical = try XCTUnwrap(canonicalSnapshot)
                    let canonicalWorkspace = try JSONDecoder().decode(
                        WorkspaceModel.self,
                        from: canonical.document.documentBytes
                    )
                    guard canonicalWorkspace.composeTabs.containsIdentity(pair) else {
                        throw AdmissionTestError.fixtureSetup(
                            "provider reached dispatch before canonical identity \(pair)"
                        )
                    }
                    let savedWorkspace = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                        at: fixture.workspaceFileURL,
                        scheduleNormalizationWriteback: false
                    )
                    guard savedWorkspace.composeTabs.containsIdentity(pair) else {
                        throw AdmissionTestError.fixtureSetup(
                            "provider reached dispatch before disk identity \(pair)"
                        )
                    }
                }
            )
            let tasks = (0 ..< 6).map { index in
                Task { @MainActor in
                    try await service.execute(args: [
                        "op": .string("start"),
                        "message": .string("overlapping durable admission \(index)"),
                        "detach": .bool(true),
                        "timeout": .int(0)
                    ])
                }
            }

            do {
                try await waitUntil("first durable admission save to reach the gate") {
                    await saveGate.hasEntered()
                }
                do {
                    try await waitUntil("five same-workspace starts to queue") {
                        coordinator.snapshot().activeAdmissionCount == coordinatorBaseline.activeAdmissionCount + 1
                            && coordinator.waiterCount(for: workspaceID) == 5
                    }
                } catch {
                    throw AdmissionTestError.fixtureSetup(
                        "coordinator did not reach six-way overlap: baseline=\(coordinatorBaseline) current=\(coordinator.snapshot()) workspaceWaiters=\(coordinator.waiterCount(for: workspaceID))"
                    )
                }
                let heldWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
                XCTAssertEqual(
                    Set(heldWorkspace.composeTabs.map(\.id)).subtracting(initialTabIDs).count,
                    1,
                    "Queued siblings must not append provisional tabs before acquiring the workspace admission."
                )
                let providerCountWhileSaveBlocked = await providerRecorder.count()
                XCTAssertEqual(
                    providerCountWhileSaveBlocked,
                    0,
                    "No provider may start before the first durable save gate opens."
                )

                await saveGate.open()
                try await waitUntil("all six providers to overlap") {
                    await providerRecorder.count() == 6
                }

                let observations = await providerRecorder.observations()
                let acceptedPairs = observations.map { AdmissionIdentityPair(tabID: $0.tabID, sessionID: $0.sessionID) }
                XCTAssertEqual(observations.count, 6)
                XCTAssertEqual(Set(acceptedPairs).count, 6)
                XCTAssertEqual(Set(observations.compactMap(\.lifecycleIdentity)).count, 6)
                XCTAssertTrue(observations.allSatisfy { $0.lifecycleIdentity?.workspaceID == workspaceID })

                let projectedWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
                XCTAssertEqual(projectedWorkspace.activeComposeTabID, initialActiveTabID)
                assertExactAdmissionState(
                    in: projectedWorkspace.composeTabs,
                    initialTabs: initialTabs,
                    acceptedPairs: acceptedPairs
                )
                assertExactAdmissionState(
                    in: fixture.window.promptManager.currentComposeTabs,
                    initialTabs: initialTabs,
                    acceptedPairs: acceptedPairs
                )
                for observation in observations {
                    let live = try XCTUnwrap(
                        try fixture.window.agentModeViewModel.authoritativeLiveSession(for: observation.sessionID)
                    )
                    XCTAssertEqual(live.tabID, observation.tabID)
                    XCTAssertEqual(live.activeAgentSessionID, observation.sessionID)
                }

                let canonicalSnapshot = await fixture.runtime.workspaceStore
                    .canonicalWorkspaceSnapshot(workspaceID)
                let canonical = try XCTUnwrap(canonicalSnapshot)
                XCTAssertEqual(canonical.health, .writable)
                let canonicalWorkspace = try JSONDecoder().decode(
                    WorkspaceModel.self,
                    from: canonical.document.documentBytes
                )
                assertExactAdmissionState(
                    in: canonicalWorkspace.composeTabs,
                    initialTabs: initialTabs,
                    acceptedPairs: acceptedPairs
                )
                let savedWorkspace = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                    at: fixture.workspaceFileURL,
                    scheduleNormalizationWriteback: false
                )
                assertExactAdmissionState(
                    in: savedWorkspace.composeTabs,
                    initialTabs: initialTabs,
                    acceptedPairs: acceptedPairs
                )

                await providerRecorder.releaseAll()
                var values: [Value] = []
                for task in tasks {
                    try await values.append(task.value)
                }
                let responsePairs = try values.map { value -> AdmissionIdentityPair in
                    let object = try XCTUnwrap(value.objectValue)
                    let session = try XCTUnwrap(object["session"]?.objectValue)
                    return try AdmissionIdentityPair(
                        tabID: XCTUnwrap(session["context_id"]?.stringValue.flatMap(UUID.init(uuidString:))),
                        sessionID: XCTUnwrap(object["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
                    )
                }
                XCTAssertEqual(Set(responsePairs), Set(acceptedPairs))
                let providerAttemptCounts = await providerRecorder.attemptCounts()
                XCTAssertEqual(providerAttemptCounts, Dictionary(
                    uniqueKeysWithValues: acceptedPairs.map { ($0, 1) }
                ))

                await fixture.closeWindowAndRuntime()
                try await fixture.withFreshRuntime(generation: 2) { restarted in
                    let restartedCatalog = await restarted.workspaceStore.snapshot()
                    let restartedSnapshot = await restarted.workspaceStore
                        .canonicalWorkspaceSnapshot(workspaceID)
                    let restartedWorkspace = try XCTUnwrap(restartedSnapshot)
                    XCTAssertEqual(restartedCatalog.health, .writable)
                    XCTAssertEqual(restartedWorkspace.health, .writable)
                    let restartedModel = try JSONDecoder().decode(
                        WorkspaceModel.self,
                        from: restartedWorkspace.document.documentBytes
                    )
                    assertExactAdmissionState(
                        in: restartedModel.composeTabs,
                        initialTabs: initialTabs,
                        acceptedPairs: acceptedPairs
                    )
                }
                XCTAssertEqual(coordinator.snapshot(), coordinatorBaseline)
            } catch {
                await saveGate.open()
                await providerRecorder.releaseAll()
                tasks.forEach { $0.cancel() }
                var taskErrors: [String] = []
                for task in tasks {
                    do {
                        _ = try await task.value
                    } catch {
                        taskErrors.append(String(describing: error))
                    }
                }
                throw AdmissionTestError.fixtureSetup(
                    "\(error); taskErrors=\(taskErrors)"
                )
            }
        }

        func testSecondWindowRefreshesCanonicalAdmissionBeforePersistingItsOwnTarget() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make()
            trackCleanup {
                await fixture.cleanup()
            }
            let peer = try await fixture.makePeerWindow()
            let stalePeerWorkspace = try XCTUnwrap(
                peer.workspaceManager.workspace(withID: fixture.workspaceID)
            )
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let coordinatorBaseline = coordinator.snapshot()
            let saveGate = AdmissionSaveGate()
            fixture.window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting {
                workspaceID,
                _,
                _ in
                guard workspaceID == fixture.workspaceID,
                      coordinator.activeCount(for: workspaceID) > 0
                else { return }
                await saveGate.enterFirstAndWait()
            }
            defer {
                fixture.window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
                peer.workspaceManager.setAgentAdmissionCanonicalSnapshotHandlerForTesting(nil)
            }
            let firstRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            let firstService = makeAgentRunStartService(
                window: fixture.window,
                recorder: firstRecorder
            )
            let secondRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            let secondService = makeAgentRunStartService(window: peer, recorder: secondRecorder)
            var peerRefreshObserved = false
            peer.workspaceManager.setAgentAdmissionCanonicalSnapshotHandlerForTesting { workspaceID in
                peerRefreshObserved = true
                XCTAssertEqual(
                    coordinator.snapshot().activeAdmissionCount,
                    coordinatorBaseline.activeAdmissionCount + 1,
                    "The peer refresh must run while its admission lease is active."
                )
                XCTAssertEqual(
                    coordinator.waiterCount(for: workspaceID),
                    0,
                    "The peer must leave the queue before reading canonical state."
                )
                return await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
            }
            let firstTask = Task { @MainActor in
                try await firstService.execute(args: [
                    "op": .string("start"),
                    "message": .string("first window canonical admission"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            var secondTask: Task<Value, Error>?
            do {
                try await waitUntil("first window admission to hold the workspace lease") {
                    await saveGate.hasEntered()
                }
                XCTAssertFalse(peerRefreshObserved)
                peer.promptManager.loadComposeTabsFromWorkspace(stalePeerWorkspace)

                let queuedTask = Task { @MainActor in
                    try await secondService.execute(args: [
                        "op": .string("start"),
                        "message": .string("second window canonical admission"),
                        "detach": .bool(true),
                        "timeout": .int(0)
                    ])
                }
                secondTask = queuedTask
                try await waitUntil("peer admission to queue behind the first window") {
                    coordinator.waiterCount(for: fixture.workspaceID) == 1
                }
                XCTAssertFalse(peerRefreshObserved)
                let peerProviderCountWhileQueued = await secondRecorder.count()
                XCTAssertEqual(peerProviderCountWhileQueued, 0)

                await saveGate.open()
                _ = try await firstTask.value
                _ = try await queuedTask.value
            } catch {
                await saveGate.open()
                firstTask.cancel()
                secondTask?.cancel()
                _ = try? await firstTask.value
                if let secondTask {
                    _ = try? await secondTask.value
                }
                throw error
            }

            XCTAssertTrue(peerRefreshObserved)
            let firstObservations = await firstRecorder.observations()
            let firstObservation = try XCTUnwrap(firstObservations.first)
            let firstPair = AdmissionIdentityPair(
                tabID: firstObservation.tabID,
                sessionID: firstObservation.sessionID
            )
            let secondObservations = await secondRecorder.observations()
            let secondObservation = try XCTUnwrap(secondObservations.first)
            let secondPair = AdmissionIdentityPair(
                tabID: secondObservation.tabID,
                sessionID: secondObservation.sessionID
            )

            let firstAttemptCounts = await firstRecorder.attemptCounts()
            let secondAttemptCounts = await secondRecorder.attemptCounts()
            XCTAssertEqual(firstAttemptCounts[firstPair], 1)
            XCTAssertEqual(secondAttemptCounts[secondPair], 1)
            let canonicalSnapshotValue = await fixture.runtime.workspaceStore
                .canonicalWorkspaceSnapshot(fixture.workspaceID)
            let canonicalSnapshot = try XCTUnwrap(canonicalSnapshotValue)
            let canonical = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: canonicalSnapshot.document.documentBytes
            )
            XCTAssertTrue(canonical.composeTabs.containsIdentity(firstPair))
            XCTAssertTrue(canonical.composeTabs.containsIdentity(secondPair))
            XCTAssertEqual(Set([firstPair, secondPair]).count, 2)
        }

        func testCanonicalAdmissionRefreshReResolvesWorkspaceAfterReorder() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make()
            trackCleanup { await fixture.cleanup() }
            let peer = try await fixture.makePeerWindow()
            let staleWorkspace = try XCTUnwrap(peer.workspaceManager.workspace(withID: fixture.workspaceID))
            let firstRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            _ = try await makeAgentRunStartService(window: fixture.window, recorder: firstRecorder).execute(args: [
                "op": .string("start"),
                "message": .string("canonical identity before peer reorder"),
                "detach": .bool(true),
                "timeout": .int(0)
            ])
            let firstObservations = await firstRecorder.observations()
            let first = try XCTUnwrap(firstObservations.first)
            let firstPair = AdmissionIdentityPair(tabID: first.tabID, sessionID: first.sessionID)
            let peerIndex = try XCTUnwrap(peer.workspaceManager.workspaces.firstIndex { $0.id == fixture.workspaceID })
            peer.workspaceManager.workspaces[peerIndex] = staleWorkspace
            peer.promptManager.loadComposeTabsFromWorkspace(staleWorkspace)

            let gate = AdmissionHandoffGate()
            peer.workspaceManager.setAgentAdmissionCanonicalSnapshotHandlerForTesting { workspaceID in
                let snapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
                await gate.enterAndWait()
                return snapshot
            }
            defer { peer.workspaceManager.setAgentAdmissionCanonicalSnapshotHandlerForTesting(nil) }
            let secondRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            let task = Task { @MainActor in
                try await self.makeAgentRunStartService(window: peer, recorder: secondRecorder).execute(args: [
                    "op": .string("start"),
                    "message": .string("peer admission after reorder"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            await gate.waitUntilEntered()
            let target = peer.workspaceManager.workspaces.remove(at: peerIndex)
            peer.workspaceManager.workspaces.append(target)
            let unrelatedBefore = Array(peer.workspaceManager.workspaces.dropLast())
            await gate.open()
            _ = try await task.value

            XCTAssertEqual(Array(peer.workspaceManager.workspaces.dropLast()), unrelatedBefore)
            let refreshed = try XCTUnwrap(peer.workspaceManager.workspace(withID: fixture.workspaceID))
            XCTAssertTrue(refreshed.composeTabs.containsIdentity(firstPair))
            let secondProviderCount = await secondRecorder.count()
            XCTAssertEqual(secondProviderCount, 1)
        }

        func testCanonicalAdmissionRefreshMergesIntoReplacementWorkspaceAfterAuthorityRead() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make()
            trackCleanup { await fixture.cleanup() }
            let peer = try await fixture.makePeerWindow()
            let staleWorkspace = try XCTUnwrap(peer.workspaceManager.workspace(withID: fixture.workspaceID))
            let firstRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            _ = try await makeAgentRunStartService(window: fixture.window, recorder: firstRecorder).execute(args: [
                "op": .string("start"),
                "message": .string("canonical identity before local replacement"),
                "detach": .bool(true),
                "timeout": .int(0)
            ])
            let firstObservations = await firstRecorder.observations()
            let first = try XCTUnwrap(firstObservations.first)
            let firstPair = AdmissionIdentityPair(tabID: first.tabID, sessionID: first.sessionID)
            let peerIndex = try XCTUnwrap(peer.workspaceManager.workspaces.firstIndex { $0.id == fixture.workspaceID })
            peer.workspaceManager.workspaces[peerIndex] = staleWorkspace
            peer.promptManager.loadComposeTabsFromWorkspace(staleWorkspace)

            let gate = AdmissionHandoffGate()
            peer.workspaceManager.setAgentAdmissionCanonicalSnapshotHandlerForTesting { workspaceID in
                let snapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
                await gate.enterAndWait()
                return snapshot
            }
            defer { peer.workspaceManager.setAgentAdmissionCanonicalSnapshotHandlerForTesting(nil) }
            let secondRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            let task = Task { @MainActor in
                try await self.makeAgentRunStartService(window: peer, recorder: secondRecorder).execute(args: [
                    "op": .string("start"),
                    "message": .string("peer admission after replacement"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            await gate.waitUntilEntered()
            let replacementTab = ComposeTabState(name: "Replacement-local tab")
            var replacement = staleWorkspace
            replacement.name = "Replacement-local workspace"
            replacement.composeTabs = [replacementTab]
            replacement.activeComposeTabID = replacementTab.id
            peer.workspaceManager.workspaces[peerIndex] = replacement
            await gate.open()
            _ = try await task.value

            let refreshed = try XCTUnwrap(peer.workspaceManager.workspace(withID: fixture.workspaceID))
            XCTAssertEqual(refreshed.name, replacement.name)
            XCTAssertTrue(refreshed.composeTabs.contains { $0.id == replacementTab.id })
            XCTAssertTrue(refreshed.composeTabs.containsIdentity(firstPair))
            let secondProviderCount = await secondRecorder.count()
            XCTAssertEqual(secondProviderCount, 1)
        }

        func testCanonicalAdmissionRefreshRejectsWorkspaceRemovedDuringAuthorityRead() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make()
            trackCleanup { await fixture.cleanup() }
            let manager = fixture.window.workspaceManager
            let canonicalBeforeValue = await fixture.runtime.workspaceStore
                .canonicalWorkspaceSnapshot(fixture.workspaceID)
            let canonicalBefore = try XCTUnwrap(canonicalBeforeValue)
            let canonicalModelBefore = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: canonicalBefore.document.documentBytes
            )
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let provisionalCountBefore = coordinator.snapshot().provisionalSessionCount
            let gate = AdmissionHandoffGate()
            manager.setAgentAdmissionCanonicalSnapshotHandlerForTesting { workspaceID in
                let snapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
                await gate.enterAndWait()
                return snapshot
            }
            defer { manager.setAgentAdmissionCanonicalSnapshotHandlerForTesting(nil) }
            let recorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            let task = Task { @MainActor in
                try await self.makeAgentRunStartService(window: fixture.window, recorder: recorder).execute(args: [
                    "op": .string("start"),
                    "message": .string("removed while reading authority"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            await gate.waitUntilEntered()
            manager.workspaces.removeAll { $0.id == fixture.workspaceID }
            await gate.open()
            do {
                _ = try await task.value
                XCTFail("A removed target must reject before provisional publication.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("disappeared"), String(describing: error))
            }

            let providerCount = await recorder.count()
            XCTAssertEqual(providerCount, 0)
            XCTAssertEqual(coordinator.snapshot().provisionalSessionCount, provisionalCountBefore)
            let canonicalAfterValue = await fixture.runtime.workspaceStore
                .canonicalWorkspaceSnapshot(fixture.workspaceID)
            let canonicalAfter = try XCTUnwrap(canonicalAfterValue)
            XCTAssertEqual(
                try JSONDecoder().decode(WorkspaceModel.self, from: canonicalAfter.document.documentBytes),
                canonicalModelBefore
            )
        }

        func testCanonicalAdmissionRefreshHonorsCancellationDuringAuthorityRead() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make()
            trackCleanup { await fixture.cleanup() }
            let manager = fixture.window.workspaceManager
            let workspaceBefore = try XCTUnwrap(manager.workspace(withID: fixture.workspaceID))
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let provisionalCountBefore = coordinator.snapshot().provisionalSessionCount
            let gate = AdmissionHandoffGate()
            manager.setAgentAdmissionCanonicalSnapshotHandlerForTesting { workspaceID in
                let snapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
                await gate.enterAndWait()
                return snapshot
            }
            defer { manager.setAgentAdmissionCanonicalSnapshotHandlerForTesting(nil) }
            let recorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            let task = Task { @MainActor in
                try await self.makeAgentRunStartService(window: fixture.window, recorder: recorder).execute(args: [
                    "op": .string("start"),
                    "message": .string("cancelled while reading authority"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            await gate.waitUntilEntered()
            task.cancel()
            await gate.open()
            do {
                _ = try await task.value
                XCTFail("Cancellation during canonical refresh must prevent admission.")
            } catch is CancellationError {}

            let providerCount = await recorder.count()
            XCTAssertEqual(providerCount, 0)
            XCTAssertEqual(coordinator.snapshot().provisionalSessionCount, provisionalCountBefore)
            let workspaceAfter = try XCTUnwrap(manager.workspace(withID: fixture.workspaceID))
            XCTAssertEqual(workspaceAfter.composeTabs.map(\.id), workspaceBefore.composeTabs.map(\.id))
            XCTAssertEqual(
                workspaceAfter.composeTabs.map(\.activeAgentSessionID),
                workspaceBefore.composeTabs.map(\.activeAgentSessionID)
            )
            XCTAssertEqual(workspaceAfter.stashedTabs, workspaceBefore.stashedTabs)
        }

        func testCanonicalAdmissionRefreshReconcilesStashedIdentityBeforeCreatingUniqueTab() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make()
            trackCleanup { await fixture.cleanup() }
            let peer = try await fixture.makePeerWindow()
            let stalePeerWorkspace = try XCTUnwrap(peer.workspaceManager.workspace(withID: fixture.workspaceID))
            let firstRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            _ = try await makeAgentRunStartService(window: fixture.window, recorder: firstRecorder).execute(args: [
                "op": .string("start"),
                "message": .string("canonical identity moved to stash"),
                "detach": .bool(true),
                "timeout": .int(0)
            ])
            let firstObservations = await firstRecorder.observations()
            let firstObservation = try XCTUnwrap(firstObservations.first)
            let firstPair = AdmissionIdentityPair(
                tabID: firstObservation.tabID,
                sessionID: firstObservation.sessionID
            )
            let canonicalValue = await fixture.runtime.workspaceStore
                .canonicalWorkspaceSnapshot(fixture.workspaceID)
            let canonicalSnapshot = try XCTUnwrap(canonicalValue)
            var canonical = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: canonicalSnapshot.document.documentBytes
            )
            let movedIndex = try XCTUnwrap(canonical.composeTabs.firstIndex { $0.id == firstPair.tabID })
            let moved = canonical.composeTabs.remove(at: movedIndex)
            canonical.stashedTabs.append(StashedTab(tab: moved))
            if canonical.activeComposeTabID == moved.id {
                canonical.activeComposeTabID = canonical.composeTabs.first?.id
            }
            let stashedSnapshot = try WorkspaceManagerViewModel.replacingWorkspaceProjectionForTesting(
                canonical,
                in: canonicalSnapshot
            )
            let peerIndex = try XCTUnwrap(peer.workspaceManager.workspaces.firstIndex {
                $0.id == fixture.workspaceID
            })
            peer.workspaceManager.workspaces[peerIndex] = stalePeerWorkspace
            peer.promptManager.loadComposeTabsFromWorkspace(stalePeerWorkspace)
            peer.workspaceManager.setAgentAdmissionCanonicalSnapshotHandlerForTesting { _ in
                stashedSnapshot
            }
            defer { peer.workspaceManager.setAgentAdmissionCanonicalSnapshotHandlerForTesting(nil) }

            let peerRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            _ = try await makeAgentRunStartService(window: peer, recorder: peerRecorder).execute(args: [
                "op": .string("start"),
                "message": .string("new tab after stashed identity refresh"),
                "detach": .bool(true),
                "timeout": .int(0)
            ])

            let refreshed = try XCTUnwrap(peer.workspaceManager.workspace(withID: fixture.workspaceID))
            XCTAssertTrue(refreshed.stashedTabs.map(\.tab).containsIdentity(firstPair))
            XCTAssertFalse(refreshed.composeTabs.containsIdentity(firstPair))
            let allTabIDs = refreshed.composeTabs.map(\.id) + refreshed.stashedTabs.map(\.tab.id)
            XCTAssertEqual(Set(allTabIDs).count, allTabIDs.count)
            let peerProviderCount = await peerRecorder.count()
            XCTAssertEqual(peerProviderCount, 1)
        }

        func testCanonicalAdmissionRefreshRejectsDuplicateTabIDWithoutMutationOrDispatch() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make()
            trackCleanup { await fixture.cleanup() }
            let manager = fixture.window.workspaceManager
            let workspaceBefore = try XCTUnwrap(manager.workspace(withID: fixture.workspaceID))
            let canonicalValue = await fixture.runtime.workspaceStore
                .canonicalWorkspaceSnapshot(fixture.workspaceID)
            let canonicalSnapshot = try XCTUnwrap(canonicalValue)
            var malformed = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: canonicalSnapshot.document.documentBytes
            )
            let duplicate = try XCTUnwrap(malformed.composeTabs.first)
            malformed.stashedTabs.append(StashedTab(tab: duplicate))
            let malformedSnapshot = try WorkspaceManagerViewModel.replacingWorkspaceProjectionForTesting(
                malformed,
                in: canonicalSnapshot
            )
            manager.setAgentAdmissionCanonicalSnapshotHandlerForTesting { _ in malformedSnapshot }
            defer { manager.setAgentAdmissionCanonicalSnapshotHandlerForTesting(nil) }
            var operationRan = false

            do {
                try await manager.withAgentSessionAdmission(
                    workspaceID: fixture.workspaceID,
                    admissionID: UUID(),
                    refreshCanonicalState: true
                ) {
                    operationRan = true
                }
                XCTFail("Malformed canonical tab identity must reject admission.")
            } catch let error as AgentAdmissionCanonicalRefreshError {
                XCTAssertEqual(error, .duplicateTabID(duplicate.id))
            }

            XCTAssertFalse(operationRan)
            XCTAssertEqual(manager.workspace(withID: fixture.workspaceID), workspaceBefore)
        }

        func testRetainedRecoveryKeepsPeerProvisionalFenceUntilRecoveryTerminates() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make()
            trackCleanup { await fixture.cleanup() }
            let peer = try await fixture.makePeerWindow()
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let baseline = coordinator.snapshot()
            let workspaceID = fixture.workspaceID
            let sessionID = UUID()
            let initiatingOwnerID = UUID()
            let recoveryID = UUID()
            let gate = AdmissionHandoffGate()
            XCTAssertTrue(coordinator.reserveProvisionalSession(
                workspaceID: workspaceID,
                sessionID: sessionID,
                ownerID: initiatingOwnerID
            ))
            fixture.window.workspaceManager.retainProvisionalAgentAdmissionRecovery(
                recoveryID: recoveryID,
                workspaceID: workspaceID,
                sessionID: sessionID,
                reservationOwnerID: recoveryID
            ) {
                await gate.enterAndWait()
            }
            await gate.waitUntilEntered()

            coordinator.releaseProvisionalSession(
                workspaceID: workspaceID,
                sessionID: sessionID,
                ownerID: initiatingOwnerID
            )
            XCTAssertTrue(peer.workspaceManager.hasActiveProvisionalAgentSession(
                workspaceID: workspaceID,
                sessionID: sessionID
            ))
            XCTAssertEqual(coordinator.snapshot().retainedRecoveryCount, baseline.retainedRecoveryCount + 1)

            await gate.open()
            try await waitUntil("retained recovery to release the process-shared reservation") {
                let snapshot = coordinator.snapshot()
                return snapshot.retainedRecoveryCount == baseline.retainedRecoveryCount
                    && snapshot.provisionalSessionCount == baseline.provisionalSessionCount
            }
            XCTAssertFalse(peer.workspaceManager.hasActiveProvisionalAgentSession(
                workspaceID: workspaceID,
                sessionID: sessionID
            ))
        }

        func testSecondWindowCannotStartPublishedProvisionalSessionBeforeAcceptance() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make()
            trackCleanup {
                await fixture.cleanup()
            }
            let peer = try await fixture.makePeerWindow()
            let providerGate = AdmissionHandoffGate()
            let firstRecorder = AdmissionProviderRecorder(expectedCount: 1, blockProviders: false)
            var provisionalPair: AdmissionIdentityPair?
            let firstService = makeAgentRunStartService(
                window: fixture.window,
                recorder: firstRecorder,
                validateBeforeProviderDispatch: { pair in
                    provisionalPair = pair
                    await providerGate.enterAndWait()
                }
            )
            let firstTask = Task { @MainActor in
                try await firstService.execute(args: [
                    "op": .string("start"),
                    "message": .string("publish provisional cross-window target"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            await providerGate.waitUntilEntered()
            let pair = try XCTUnwrap(provisionalPair)

            let publishedSnapshotValue = await fixture.runtime.workspaceStore
                .canonicalWorkspaceSnapshot(fixture.workspaceID)
            let publishedSnapshot = try XCTUnwrap(publishedSnapshotValue)
            let publishedWorkspace = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: publishedSnapshot.document.documentBytes
            )
            XCTAssertTrue(publishedWorkspace.composeTabs.containsIdentity(pair))
            let peerIndex = try XCTUnwrap(peer.workspaceManager.workspaces.firstIndex {
                $0.id == fixture.workspaceID
            })
            peer.workspaceManager.workspaces[peerIndex] = publishedWorkspace
            peer.promptManager.loadComposeTabsFromWorkspace(publishedWorkspace)

            XCTAssertNil(
                try peer.agentModeViewModel.mcpSettledLiveSessionForStop(sessionID: pair.sessionID),
                "A peer must not stop a durably published session while its shared reservation is active."
            )

            do {
                _ = try await peer.agentModeViewModel.mcpResolveOrCreateSessionTarget(
                    tabID: pair.tabID,
                    sessionID: pair.sessionID,
                    createIfNeeded: true,
                    sessionName: nil,
                    expectedWorkspaceID: fixture.workspaceID
                )
                XCTFail("A second window must not resolve another window's provisional target.")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains("still provisional in another window"),
                    "Unexpected provisional-fence error: \(error)"
                )
            }
            let providerCountBeforeAcceptance = await firstRecorder.count()
            XCTAssertEqual(providerCountBeforeAcceptance, 0)

            await providerGate.open()
            _ = try await firstTask.value
            let firstAttemptCounts = await firstRecorder.attemptCounts()
            XCTAssertEqual(firstAttemptCounts[pair], 1)

            let accepted = try await peer.agentModeViewModel.mcpResolveOrCreateSessionTarget(
                tabID: pair.tabID,
                sessionID: pair.sessionID,
                createIfNeeded: true,
                sessionName: nil,
                expectedWorkspaceID: fixture.workspaceID
            )
            XCTAssertEqual(accepted.tabID, pair.tabID)
            XCTAssertEqual(accepted.sessionID, pair.sessionID)
            XCTAssertNil(accepted.recoveryClaim)
            let stoppable = try XCTUnwrap(
                try peer.agentModeViewModel.mcpSettledLiveSessionForStop(sessionID: pair.sessionID)
            )
            XCTAssertEqual(stoppable.tabID, pair.tabID)
        }

        func testAgentAdmissionsForDistinctDurableWorkspacesOverlap() async throws {
            let fixture = try await DistinctDurableAdmissionFixture.make()
            trackCleanup {
                await fixture.cleanup()
            }
            let first = fixture.first
            let second = fixture.second
            let initialTabsByWorkspace = try Dictionary(uniqueKeysWithValues: [first, second].map { context in
                try (
                    context.workspaceID,
                    XCTUnwrap(context.window.workspaceManager.activeWorkspace).composeTabs
                )
            })
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let baseline = coordinator.snapshot()
            let firstGate = AdmissionSaveGate()
            let secondGate = AdmissionSaveGate()
            let providerRecorder = AdmissionProviderRecorder(expectedCount: 2)
            first.window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting {
                workspaceID,
                _,
                _ in
                guard workspaceID == first.workspaceID,
                      coordinator.activeCount(for: workspaceID) > 0
                else { return }
                await firstGate.enterFirstAndWait()
            }
            second.window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting {
                workspaceID,
                _,
                _ in
                guard workspaceID == second.workspaceID,
                      coordinator.activeCount(for: workspaceID) > 0
                else { return }
                await secondGate.enterFirstAndWait()
            }
            defer {
                first.window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
                second.window.workspaceManager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
            }
            let firstService = makeAgentRunStartService(
                window: first.window,
                recorder: providerRecorder
            )
            let secondService = makeAgentRunStartService(
                window: second.window,
                recorder: providerRecorder
            )
            let firstTask = Task { @MainActor in
                try await firstService.execute(args: [
                    "op": .string("start"),
                    "message": .string("distinct workspace A"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            let secondTask = Task { @MainActor in
                try await secondService.execute(args: [
                    "op": .string("start"),
                    "message": .string("distinct workspace B"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }

            do {
                try await waitUntil("workspace A admission save to block") {
                    await firstGate.hasEntered()
                }
                try await waitUntil("workspace B admission save to overlap workspace A") {
                    await secondGate.hasEntered()
                }
                XCTAssertEqual(
                    coordinator.snapshot(),
                    .init(
                        activeAdmissionCount: baseline.activeAdmissionCount + 2,
                        waiterCount: baseline.waiterCount,
                        trackedWorkspaceCount: baseline.trackedWorkspaceCount + 2,
                        provisionalSessionCount: baseline.provisionalSessionCount + 2,
                        retainedRecoveryCount: baseline.retainedRecoveryCount
                    )
                )

                await firstGate.open()
                await secondGate.open()
                try await waitUntil("both distinct-workspace providers to overlap") {
                    await providerRecorder.count() == 2
                }
                let observations = await providerRecorder.observations()
                XCTAssertEqual(
                    Set(observations.compactMap { $0.lifecycleIdentity?.workspaceID }),
                    Set([first.workspaceID, second.workspaceID])
                )
                let observationsByWorkspace = Dictionary(
                    uniqueKeysWithValues: observations.compactMap { observation in
                        observation.lifecycleIdentity.map { ($0.workspaceID, observation) }
                    }
                )
                for context in [first, second] {
                    let observation = try XCTUnwrap(observationsByWorkspace[context.workspaceID])
                    let pair = AdmissionIdentityPair(
                        tabID: observation.tabID,
                        sessionID: observation.sessionID
                    )
                    let initialTabs = try XCTUnwrap(initialTabsByWorkspace[context.workspaceID])
                    let projected = try XCTUnwrap(context.window.workspaceManager.activeWorkspace)
                    assertExactAdmissionState(
                        in: projected.composeTabs,
                        initialTabs: initialTabs,
                        acceptedPairs: [pair]
                    )
                    assertExactAdmissionState(
                        in: context.window.promptManager.currentComposeTabs,
                        initialTabs: initialTabs,
                        acceptedPairs: [pair]
                    )
                    let canonicalSnapshot = await context.runtime.workspaceStore
                        .canonicalWorkspaceSnapshot(context.workspaceID)
                    let canonical = try XCTUnwrap(canonicalSnapshot)
                    let canonicalWorkspace = try JSONDecoder().decode(
                        WorkspaceModel.self,
                        from: canonical.document.documentBytes
                    )
                    assertExactAdmissionState(
                        in: canonicalWorkspace.composeTabs,
                        initialTabs: initialTabs,
                        acceptedPairs: [pair]
                    )
                    let saved = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                        at: context.workspaceFileURL,
                        scheduleNormalizationWriteback: false
                    )
                    assertExactAdmissionState(
                        in: saved.composeTabs,
                        initialTabs: initialTabs,
                        acceptedPairs: [pair]
                    )
                }

                await providerRecorder.releaseAll()
                let firstValue = try await firstTask.value
                let secondValue = try await secondTask.value
                let responseIDs = Set([firstValue, secondValue].compactMap {
                    $0.objectValue?["session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                })
                XCTAssertEqual(responseIDs, Set(observations.map(\.sessionID)))
                XCTAssertEqual(coordinator.snapshot(), baseline)

                await fixture.closeWindowsAndRuntime()
                for context in [first, second] {
                    try await fixture.withFreshRuntime(for: context, generation: 2) { restarted in
                        let observation = try XCTUnwrap(observationsByWorkspace[context.workspaceID])
                        let pair = AdmissionIdentityPair(
                            tabID: observation.tabID,
                            sessionID: observation.sessionID
                        )
                        let initialTabs = try XCTUnwrap(initialTabsByWorkspace[context.workspaceID])
                        let restartedSnapshot = await restarted.workspaceStore
                            .canonicalWorkspaceSnapshot(context.workspaceID)
                        let restartedWorkspace = try XCTUnwrap(restartedSnapshot)
                        let restartedModel = try JSONDecoder().decode(
                            WorkspaceModel.self,
                            from: restartedWorkspace.document.documentBytes
                        )
                        assertExactAdmissionState(
                            in: restartedModel.composeTabs,
                            initialTabs: initialTabs,
                            acceptedPairs: [pair]
                        )
                    }
                }
            } catch {
                await firstGate.open()
                await secondGate.open()
                await providerRecorder.releaseAll()
                firstTask.cancel()
                secondTask.cancel()
                var taskErrors: [String] = []
                for task in [firstTask, secondTask] {
                    do {
                        _ = try await task.value
                    } catch {
                        taskErrors.append(String(describing: error))
                    }
                }
                throw AdmissionTestError.fixtureSetup(
                    "\(error); taskErrors=\(taskErrors)"
                )
            }
        }

        func testTypedAdmissionRejectionLeavesNoIdentityAcrossRestartAndDispatchesNoProvider() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make()
            trackCleanup {
                await fixture.cleanup()
            }
            let workspaceID = fixture.workspaceID
            let initialWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            let initialTabs = initialWorkspace.composeTabs
            let initialTabIDs = Set(initialTabs.map(\.id))
            let provisionalIdentity = ProvisionalAdmissionIdentityRecorder()
            let beforeSaveToken = fixture.window.workspaceManager.addBeforeSaveListener { workspace in
                guard workspace.id == workspaceID,
                      let tab = workspace.composeTabs.first(where: {
                          !initialTabIDs.contains($0.id) && $0.activeAgentSessionID != nil
                      }), let sessionID = tab.activeAgentSessionID
                else { return }
                provisionalIdentity.record(.init(tabID: tab.id, sessionID: sessionID))
            }
            let providerRecorder = AdmissionProviderRecorder(
                expectedCount: 1,
                blockProviders: false
            )
            let lifecycleEvents = AdmissionLifecycleEventRecorder()
            AgentSessionLifecycleAuthority.setEventObserverForTesting { lifecycleEvents.record($0) }
            fixture.window.workspaceManager.setWorkspacePersistenceOutcomeOverrideForTesting(
                .rejected(
                    reason: "authority_revision_conflict",
                    category: .authorityRevisionConflict
                )
            )
            defer {
                fixture.window.workspaceManager.removeBeforeSaveListener(beforeSaveToken)
                fixture.window.workspaceManager.setWorkspacePersistenceOutcomeOverrideForTesting(nil)
                AgentSessionLifecycleAuthority.setEventObserverForTesting(nil)
            }
            let service = makeAgentRunStartService(
                window: fixture.window,
                recorder: providerRecorder
            )

            do {
                _ = try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("reject this durable admission"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
                XCTFail("A typed authority conflict must reject before provider dispatch.")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains("workspace binding was not durably accepted"),
                    error.localizedDescription
                )
            }

            let rejectionEvent = try XCTUnwrap(lifecycleEvents.snapshot().last { event in
                event.caller == .agentRunStart
                    && event.decision == .rejected
                    && event.reason == AgentSessionLifecycleAuthority.RejectionReason
                    .workspacePersistenceRejected.rawValue
            })
            XCTAssertEqual(
                rejectionEvent.workspaceSaveResult,
                WorkspacePersistenceFailureCategory.authorityRevisionConflict.rawValue
            )
            XCTAssertEqual(
                WorkspacePersistenceFailureCategory.classify(reason: rejectionEvent.workspaceSaveResult),
                .authorityRevisionConflict
            )

            let rejectedPair = try XCTUnwrap(provisionalIdentity.value())
            let providerCount = await providerRecorder.count()
            XCTAssertEqual(providerCount, 0)
            let projectedWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            assertExactAdmissionState(
                in: projectedWorkspace.composeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
            XCTAssertFalse(projectedWorkspace.composeTabs.containsIdentity(rejectedPair))
            assertExactAdmissionState(
                in: fixture.window.promptManager.currentComposeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
            XCTAssertFalse(fixture.window.promptManager.currentComposeTabs.containsIdentity(rejectedPair))
            XCTAssertNil(
                try fixture.window.agentModeViewModel.authoritativeLiveSession(
                    for: rejectedPair.sessionID
                )
            )

            let canonicalSnapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
            let canonical = try XCTUnwrap(canonicalSnapshot)
            let canonicalWorkspace = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: canonical.document.documentBytes
            )
            XCTAssertEqual(canonical.health, .writable)
            assertExactAdmissionState(
                in: canonicalWorkspace.composeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
            XCTAssertFalse(canonicalWorkspace.composeTabs.containsIdentity(rejectedPair))
            let savedWorkspace = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceFileURL,
                scheduleNormalizationWriteback: false
            )
            assertExactAdmissionState(
                in: savedWorkspace.composeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
            XCTAssertFalse(savedWorkspace.composeTabs.containsIdentity(rejectedPair))

            fixture.window.workspaceManager.removeBeforeSaveListener(beforeSaveToken)
            fixture.window.workspaceManager.setWorkspacePersistenceOutcomeOverrideForTesting(nil)
            await fixture.closeWindowAndRuntime()
            try await fixture.withFreshRuntime(generation: 2) { restarted in
                let restartedSnapshot = await restarted.workspaceStore
                    .canonicalWorkspaceSnapshot(workspaceID)
                let restartedWorkspace = try XCTUnwrap(restartedSnapshot)
                XCTAssertEqual(restartedWorkspace.health, .writable)
                let restartedModel = try JSONDecoder().decode(
                    WorkspaceModel.self,
                    from: restartedWorkspace.document.documentBytes
                )
                assertExactAdmissionState(
                    in: restartedModel.composeTabs,
                    initialTabs: initialTabs,
                    acceptedPairs: []
                )
                XCTAssertFalse(restartedModel.composeTabs.containsIdentity(rejectedPair))
            }
        }

        func testQueuedAgentRunCancellationMutatesNoDurableStateAndDispatchesNoProvider() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make()
            trackCleanup {
                await fixture.cleanup()
            }
            let workspaceID = fixture.workspaceID
            let initialWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            let initialTabs = initialWorkspace.composeTabs
            let providerRecorder = AdmissionProviderRecorder(
                expectedCount: 1,
                blockProviders: false
            )
            let service = makeAgentRunStartService(
                window: fixture.window,
                recorder: providerRecorder
            )
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let baseline = coordinator.snapshot()
            let holder = try await coordinator.acquire(
                workspaceID: workspaceID,
                admissionID: UUID()
            )
            defer { holder.release() }
            let startTask = Task { @MainActor in
                try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("cancel while queued"),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
            }
            do {
                try await waitUntil("agent_run.start to queue behind the workspace holder") {
                    coordinator.waiterCount(for: workspaceID) == 1
                }
            } catch {
                let queuePhaseError = error
                startTask.cancel()
                holder.release()
                do {
                    _ = try await startTask.value
                } catch {}
                throw queuePhaseError
            }
            startTask.cancel()
            do {
                _ = try await startTask.value
                XCTFail("A queued cancelled start must throw CancellationError.")
            } catch is CancellationError {}
            holder.release()

            let providerCount = await providerRecorder.count()
            XCTAssertEqual(providerCount, 0)
            XCTAssertEqual(coordinator.snapshot(), baseline)
            let projectedWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            assertExactAdmissionState(
                in: projectedWorkspace.composeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
            assertExactAdmissionState(
                in: fixture.window.promptManager.currentComposeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
            let canonicalSnapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(workspaceID)
            let canonical = try XCTUnwrap(canonicalSnapshot)
            let canonicalWorkspace = try JSONDecoder().decode(
                WorkspaceModel.self,
                from: canonical.document.documentBytes
            )
            assertExactAdmissionState(
                in: canonicalWorkspace.composeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
            let savedWorkspace = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.workspaceFileURL,
                scheduleNormalizationWriteback: false
            )
            assertExactAdmissionState(
                in: savedWorkspace.composeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )

            await fixture.closeWindowAndRuntime()
            try await fixture.withFreshRuntime(generation: 2) { restarted in
                let restartedSnapshot = await restarted.workspaceStore
                    .canonicalWorkspaceSnapshot(workspaceID)
                let restartedWorkspace = try XCTUnwrap(restartedSnapshot)
                let restartedModel = try JSONDecoder().decode(
                    WorkspaceModel.self,
                    from: restartedWorkspace.document.documentBytes
                )
                assertExactAdmissionState(
                    in: restartedModel.composeTabs,
                    initialTabs: initialTabs,
                    acceptedPairs: []
                )
            }
        }

        func testUnexpectedQueuePhaseFailureCancelsAndJoinsAgentRunStartBeforeRethrowingOriginalError() async throws {
            let fixture = try await DurableAgentAdmissionFixture.make()
            trackCleanup {
                await fixture.cleanup()
            }
            let workspaceID = fixture.workspaceID
            let initialWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            let initialTabs = initialWorkspace.composeTabs
            let providerRecorder = AdmissionProviderRecorder(
                expectedCount: 1,
                blockProviders: false
            )
            let service = makeAgentRunStartService(
                window: fixture.window,
                recorder: providerRecorder
            )
            let coordinator = WorkspaceAgentAdmissionCoordinator.shared
            let baseline = coordinator.snapshot()
            let holder = try await coordinator.acquire(
                workspaceID: workspaceID,
                admissionID: UUID()
            )
            defer { holder.release() }
            let terminationProbe = AdmissionStartTaskTerminationProbe()
            let startTask = Task { @MainActor in
                do {
                    let value = try await service.execute(args: [
                        "op": .string("start"),
                        "message": .string("unexpected queue-phase failure"),
                        "detach": .bool(true),
                        "timeout": .int(0)
                    ])
                    await terminationProbe.recordTermination()
                    return value
                } catch {
                    await terminationProbe.recordTermination()
                    throw error
                }
            }
            let sentinelID = UUID()

            do {
                do {
                    try await waitUntil("agent_run.start to queue before an unexpected queue-phase failure") {
                        coordinator.waiterCount(for: workspaceID) == 1
                    }
                    throw AdmissionTestError.queuePhaseSentinel(sentinelID)
                } catch {
                    let queuePhaseError = error
                    startTask.cancel()
                    holder.release()
                    do {
                        _ = try await startTask.value
                    } catch {}
                    throw queuePhaseError
                }
            } catch let AdmissionTestError.queuePhaseSentinel(observedID) {
                XCTAssertEqual(observedID, sentinelID)
            }

            let terminationCount = await terminationProbe.terminationCount()
            XCTAssertEqual(terminationCount, 1)
            let providerCount = await providerRecorder.count()
            XCTAssertEqual(providerCount, 0)
            XCTAssertEqual(coordinator.snapshot(), baseline)
            let projectedWorkspace = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace)
            assertExactAdmissionState(
                in: projectedWorkspace.composeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
            assertExactAdmissionState(
                in: fixture.window.promptManager.currentComposeTabs,
                initialTabs: initialTabs,
                acceptedPairs: []
            )
        }

        func testSameWorkspaceAdmissionsAcquireInFIFOOrderAndTeardownEmpty() async throws {
            let coordinator = WorkspaceAgentAdmissionCoordinator()
            let workspaceID = UUID()
            let holderID = UUID()
            let queuedIDs = (0 ..< 5).map { _ in UUID() }
            let recorder = AdmissionOrderRecorder()

            let holder = try await coordinator.acquire(
                workspaceID: workspaceID,
                admissionID: holderID
            )
            var queuedTasks: [Task<UUID, Error>] = []
            for (index, admissionID) in queuedIDs.enumerated() {
                queuedTasks.append(Task {
                    let lease = try await coordinator.acquire(
                        workspaceID: workspaceID,
                        admissionID: admissionID
                    )
                    await recorder.append(admissionID)
                    lease.release()
                    return admissionID
                })
                try await waitUntil("waiter \(index + 1) to enqueue") {
                    coordinator.waiterCount(for: workspaceID) == index + 1
                }
            }

            XCTAssertEqual(coordinator.activeCount(for: workspaceID), 1)
            XCTAssertTrue(holder.release())
            XCTAssertFalse(holder.release(), "Lease release must be idempotent.")
            for (task, expectedID) in zip(queuedTasks, queuedIDs) {
                let admittedID = try await task.value
                XCTAssertEqual(admittedID, expectedID)
            }

            let recordedOrder = await recorder.values()
            XCTAssertEqual(recordedOrder, queuedIDs)
            XCTAssertEqual(
                coordinator.snapshot(),
                WorkspaceAgentAdmissionCoordinator.Snapshot(
                    activeAdmissionCount: 0,
                    waiterCount: 0,
                    trackedWorkspaceCount: 0,
                    provisionalSessionCount: 0,
                    retainedRecoveryCount: 0
                )
            )
        }

        func testQueuedCancellationNeverAcquiresAndLeavesNoCoordinatorState() async throws {
            let coordinator = WorkspaceAgentAdmissionCoordinator()
            let workspaceID = UUID()
            let holder = try await coordinator.acquire(
                workspaceID: workspaceID,
                admissionID: UUID()
            )
            let cancelledID = UUID()
            let cancelledTask = Task {
                try await coordinator.acquire(
                    workspaceID: workspaceID,
                    admissionID: cancelledID
                )
            }
            try await waitUntil("cancelled waiter to enqueue") {
                coordinator.waiterCount(for: workspaceID) == 1
            }

            cancelledTask.cancel()
            do {
                _ = try await cancelledTask.value
                XCTFail("A cancelled queued admission must not acquire a lease.")
            } catch is CancellationError {}

            XCTAssertEqual(coordinator.waiterCount(for: workspaceID), 0)
            holder.release()
            XCTAssertEqual(coordinator.snapshot().trackedWorkspaceCount, 0)
        }

        func testCancellingFirstQueuedWaiterPreservesNextWaiterHandoff() async throws {
            let coordinator = WorkspaceAgentAdmissionCoordinator()
            let workspaceID = UUID()
            let holder = try await coordinator.acquire(
                workspaceID: workspaceID,
                admissionID: UUID()
            )
            let waiterA = Task {
                try await coordinator.acquire(
                    workspaceID: workspaceID,
                    admissionID: UUID()
                )
            }
            try await waitUntil("first waiter to enqueue") {
                coordinator.waiterCount(for: workspaceID) == 1
            }
            let waiterB = Task {
                try await coordinator.acquire(
                    workspaceID: workspaceID,
                    admissionID: UUID()
                )
            }
            try await waitUntil("both waiters to enqueue") {
                coordinator.waiterCount(for: workspaceID) == 2
            }

            waiterA.cancel()
            do {
                _ = try await waiterA.value
                XCTFail("The cancelled first waiter must not acquire a lease.")
            } catch is CancellationError {}

            XCTAssertEqual(
                coordinator.snapshot(),
                WorkspaceAgentAdmissionCoordinator.Snapshot(
                    activeAdmissionCount: 1,
                    waiterCount: 1,
                    trackedWorkspaceCount: 1,
                    provisionalSessionCount: 0,
                    retainedRecoveryCount: 0
                )
            )
            holder.release()
            let waiterBLease = try await waiterB.value
            waiterBLease.release()
            XCTAssertEqual(
                coordinator.snapshot(),
                WorkspaceAgentAdmissionCoordinator.Snapshot(
                    activeAdmissionCount: 0,
                    waiterCount: 0,
                    trackedWorkspaceCount: 0,
                    provisionalSessionCount: 0,
                    retainedRecoveryCount: 0
                )
            )
        }

        func testCancellationAfterHandoffReleasesBeforeReturning() async throws {
            let coordinator = WorkspaceAgentAdmissionCoordinator()
            let workspaceID = UUID()
            let holder = try await coordinator.acquire(
                workspaceID: workspaceID,
                admissionID: UUID()
            )
            let handoffGate = AdmissionHandoffGate()
            let handedOffID = UUID()
            coordinator.setDidResumeAfterHandoffHandlerForTesting { _, admissionID in
                guard admissionID == handedOffID else { return }
                await handoffGate.enterAndWait()
            }
            defer {
                coordinator.setDidResumeAfterHandoffHandlerForTesting(nil)
                Task { await handoffGate.open() }
            }

            let handedOffTask = Task {
                try await coordinator.acquire(
                    workspaceID: workspaceID,
                    admissionID: handedOffID
                )
            }
            try await waitUntil("handoff waiter to enqueue") {
                coordinator.waiterCount(for: workspaceID) == 1
            }
            holder.release()
            await handoffGate.waitUntilEntered()
            handedOffTask.cancel()
            await handoffGate.open()

            do {
                _ = try await handedOffTask.value
                XCTFail("Cancellation after handoff must reject the acquisition.")
            } catch is CancellationError {}

            XCTAssertEqual(
                coordinator.snapshot(),
                WorkspaceAgentAdmissionCoordinator.Snapshot(
                    activeAdmissionCount: 0,
                    waiterCount: 0,
                    trackedWorkspaceCount: 0,
                    provisionalSessionCount: 0,
                    retainedRecoveryCount: 0
                )
            )
        }

        func testDistinctWorkspaceAdmissionsOverlap() async throws {
            let coordinator = WorkspaceAgentAdmissionCoordinator()
            let workspaceA = UUID()
            let workspaceB = UUID()

            let leaseA = try await coordinator.acquire(
                workspaceID: workspaceA,
                admissionID: UUID()
            )
            let leaseB = try await coordinator.acquire(
                workspaceID: workspaceB,
                admissionID: UUID()
            )

            XCTAssertEqual(
                coordinator.snapshot(),
                WorkspaceAgentAdmissionCoordinator.Snapshot(
                    activeAdmissionCount: 2,
                    waiterCount: 0,
                    trackedWorkspaceCount: 2,
                    provisionalSessionCount: 0,
                    retainedRecoveryCount: 0
                )
            )
            leaseA.release()
            leaseB.release()
            XCTAssertEqual(coordinator.snapshot().trackedWorkspaceCount, 0)
        }

        func testManagerAdmissionHelperReleasesLeaseWhenOperationThrows() async throws {
            let coordinator = WorkspaceAgentAdmissionCoordinator()
            let fixture = makeManagerFixture(coordinator: coordinator)
            defer { fixture.manager.prepareForWindowClose() }

            do {
                _ = try await fixture.manager.withAgentSessionAdmission(
                    workspaceID: UUID(),
                    admissionID: UUID()
                ) {
                    throw AdmissionTestError.expected
                }
                XCTFail("The controlled operation must throw.")
            } catch AdmissionTestError.expected {}

            XCTAssertEqual(coordinator.snapshot().trackedWorkspaceCount, 0)
        }

        func testAgentAdmissionSaveRetriesOnceThenPersistsNewestState() async throws {
            let root = try makeTemporaryDirectory(named: "RetrySuccess")
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = makePersistentWorkspaceFixture(root: root)
            defer {
                fixture.manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
                fixture.manager.prepareForWindowClose()
            }
            fixture.manager.resetWorkspaceSaveDiagnosticsForTesting()
            fixture.manager.markWorkspaceDirty()
            fixture.manager.setWorkspaceSavePreparationDidFinishHandlerForTesting {
                workspaceID,
                _,
                remainingRetryCount in
                guard remainingRetryCount == 1 else { return }
                await MainActor.run {
                    guard let index = fixture.manager.workspaces.firstIndex(where: {
                        $0.id == workspaceID
                    }) else { return }
                    fixture.manager.workspaces[index].currentPromptText = "newest state"
                    fixture.manager.markWorkspaceDirty()
                }
            }

            let outcome = await fixture.manager.pollAndSaveStateWithOutcomeAsync(
                workspaceID: fixture.workspace.id,
                source: WorkspaceSaveSource("agentSessionLifecycleAdmissionTest")
            )

            guard case .persisted = outcome else {
                return XCTFail("The one allowed recapture must persist: \(outcome)")
            }
            XCTAssertEqual(
                fixture.manager.workspaceSaveDiagnosticsForTesting(
                    workspaceID: fixture.workspace.id
                ).attemptCount,
                2
            )
            let saved = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: fixture.manager.workspaceFileURL(for: fixture.workspace),
                scheduleNormalizationWriteback: false
            )
            XCTAssertEqual(saved.currentPromptText, "newest state")
        }

        func testAgentAdmissionSaveReportsLocalRetryExhaustionAfterTwoAttempts() async throws {
            let root = try makeTemporaryDirectory(named: "RetryExhaustion")
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = makePersistentWorkspaceFixture(root: root)
            defer {
                fixture.manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
                fixture.manager.prepareForWindowClose()
            }
            fixture.manager.resetWorkspaceSaveDiagnosticsForTesting()
            fixture.manager.markWorkspaceDirty()
            fixture.manager.setWorkspaceSavePreparationDidFinishHandlerForTesting {
                workspaceID,
                _,
                _ in
                await MainActor.run {
                    guard let index = fixture.manager.workspaces.firstIndex(where: {
                        $0.id == workspaceID
                    }) else { return }
                    var workspace = fixture.manager.workspaces[index]
                    workspace.currentPromptText = (workspace.currentPromptText ?? "") + "x"
                    fixture.manager.workspaces[index] = workspace
                    fixture.manager.markWorkspaceDirty()
                }
            }

            let outcome = await fixture.manager.pollAndSaveStateWithOutcomeAsync(
                workspaceID: fixture.workspace.id,
                source: WorkspaceSaveSource("agentSessionLifecycleAdmissionTest")
            )

            XCTAssertEqual(
                outcome,
                .rejected(
                    reason: "workspace_save_failed",
                    category: .localSavePreparationRetryExhausted
                )
            )
            XCTAssertEqual(
                outcome.normalizedFailureCategory,
                .localSavePreparationRetryExhausted
            )
            XCTAssertEqual(
                fixture.manager.workspaceSaveDiagnosticsForTesting(
                    workspaceID: fixture.workspace.id
                ).attemptCount,
                2
            )
            XCTAssertNil(
                fixture.manager.debugLastSavedVersionForWorkspace(fixture.workspace.id)
            )
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.manager.workspaceFileURL(for: fixture.workspace).path
            ))
        }

        func testNormalizedFailureLeavesRemainDistinct() {
            let reasonCases: [(String, WorkspacePersistenceFailureCategory)] = [
                ("local_save_retry_exhausted", .localSavePreparationRetryExhausted),
                ("authority_revision_conflict", .authorityRevisionConflict),
                ("authority_external_conflict", .authorityExternalConflict),
                ("workspace_not_writable", .authorityReadOnly),
                ("lock_timed_out", .lockTimedOut),
                ("cancelled", .cancelled),
                ("persistence_failure", .persistenceFailure),
                ("workspace_changed", .workspaceChanged),
                ("durability_uncertain", .durabilityUncertain)
            ]
            XCTAssertEqual(Set(reasonCases.map(\.1)).count, reasonCases.count)
            for (reason, expected) in reasonCases {
                XCTAssertEqual(
                    WorkspacePersistenceOutcome.rejected(reason: reason)
                        .normalizedFailureCategory,
                    expected
                )
            }

            let domainCases: [(DomainCommandErrorCode, WorkspacePersistenceFailureCategory)] = [
                (.stateConflict, .authorityRevisionConflict),
                (.workspaceExternalConflict, .authorityExternalConflict),
                (.runtimeReadOnlyDegraded, .authorityReadOnly),
                (.workspaceReadOnlyDegraded, .authorityReadOnly),
                (.lockTimedOut, .lockTimedOut),
                (.cancelled, .cancelled),
                (.workspaceUnavailable, .workspaceChanged),
                (.persistenceFailure, .persistenceFailure)
            ]
            for (domainCode, expected) in domainCases {
                XCTAssertEqual(
                    WorkspacePersistenceFailureCategory.classify(
                        domainErrorCode: domainCode
                    ),
                    expected
                )
            }
        }

        private func makeAgentRunStartService(
            window: WindowState,
            recorder: AdmissionProviderRecorder,
            validateBeforeProviderDispatch: ((AdmissionIdentityPair) async throws -> Void)? = nil
        ) -> AgentRunMCPToolService {
            var service = AgentRunMCPToolService(
                toolName: MCPWindowToolName.agentRun,
                captureRequestMetadata: {
                    MCPServerViewModel.RequestMetadata(
                        connectionID: nil,
                        clientName: "same-workspace-admission-test",
                        windowID: window.windowID
                    )
                },
                requireTargetWindow: { window },
                resolveRequestedTabID: { _ in nil },
                resolveSpawnParentSourceTabID: { _ in nil },
                resolveSpawnParentSessionID: { _, _ in nil },
                withHeartbeat: { _, _, _, _, operation in try await operation() },
                startRun: { target, _, _, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, _, _, _, _ in
                    let sessionID = try XCTUnwrap(target.sessionID)
                    let pair = AdmissionIdentityPair(tabID: target.tabID, sessionID: sessionID)
                    try await validateBeforeProviderDispatch?(pair)
                    try await recorder.recordAndWait(
                        .init(
                            tabID: target.tabID,
                            sessionID: sessionID,
                            lifecycleIdentity: target.lifecycleIdentity
                        )
                    )
                    let session = agentModeVM.session(for: target.tabID)
                    return AgentExternalMCPRunStarter.StartOutcome(
                        snapshot: AgentRunMCPSnapshot(
                            sessionID: sessionID,
                            tabID: target.tabID,
                            sessionName: "Concurrent admission",
                            agentRaw: agentRaw,
                            agentDisplayName: agentRaw.flatMap { AgentProviderKind(rawValue: $0)?.displayName },
                            modelRaw: modelRaw,
                            reasoningEffortRaw: reasoningEffortRaw,
                            status: .running,
                            statusText: "Provider admitted",
                            latestAssistantPreview: nil,
                            interaction: nil,
                            transcriptItemCount: 0,
                            updatedAt: Date(),
                            parentSessionID: session.parentSessionID,
                            failureReason: nil,
                            worktreeBindings: [],
                            activeWorktreeMerges: []
                        ),
                        delivery: .startedRun
                    )
                }
            )
            service.resolveOracleReviewLaunchSource = { _, targetWindow in
                let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
                let sourceTabID = try XCTUnwrap(workspace.activeComposeTabID)
                let selectionRevision = targetWindow.workspaceManager.selectionRevisionForMCP(
                    workspaceID: workspace.id,
                    tabID: sourceTabID
                )
                let snapshot = AgentRunOracleReviewLaunchSnapshot(
                    route: .explicitWindowActiveCompose,
                    windowID: targetWindow.windowID,
                    workspaceID: workspace.id,
                    tabID: sourceTabID,
                    selectionRevision: selectionRevision,
                    promptText: "",
                    selection: StoredSelection(),
                    sourceAgentSessionID: nil,
                    routedRunID: nil
                )
                return ResolvedAgentRunOracleReviewLaunchSource(
                    snapshot: snapshot,
                    source: .unavailable(.init(
                        delegationID: UUID(),
                        sourceTabID: sourceTabID,
                        workspaceID: workspace.id,
                        sourceAgentSessionID: nil,
                        sourceAgentRunID: nil,
                        reason: .sourceCaptureFailed("Synthetic durable admission fixture")
                    ))
                )
            }
            return service
        }

        private func assertExactAdmissionState(
            in tabs: [ComposeTabState],
            initialTabs: [ComposeTabState],
            acceptedPairs: [AdmissionIdentityPair],
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let expectedTabIDs = Set(initialTabs.map(\.id))
                .union(acceptedPairs.map(\.tabID))
            XCTAssertEqual(tabs.count, expectedTabIDs.count, file: file, line: line)
            XCTAssertEqual(Set(tabs.map(\.id)), expectedTabIDs, file: file, line: line)

            let initialPairs = initialTabs.compactMap { tab in
                tab.activeAgentSessionID.map {
                    AdmissionIdentityPair(tabID: tab.id, sessionID: $0)
                }
            }
            let expectedPairs = Set(initialPairs + acceptedPairs)
            let actualPairs = tabs.compactMap { tab in
                tab.activeAgentSessionID.map {
                    AdmissionIdentityPair(tabID: tab.id, sessionID: $0)
                }
            }
            XCTAssertEqual(actualPairs.count, expectedPairs.count, file: file, line: line)
            XCTAssertEqual(Set(actualPairs), expectedPairs, file: file, line: line)
        }

        private func waitUntil(
            _ description: String,
            timeout: Duration = .seconds(10),
            condition: () async -> Bool
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while await !condition() {
                guard clock.now < deadline else {
                    throw AdmissionTestError.timedOut(description)
                }
                await Task.yield()
            }
        }

        private func makePersistentWorkspaceFixture(
            root: URL
        ) -> (manager: WorkspaceManagerViewModel, workspace: WorkspaceModel) {
            let fixture = makeManagerFixture(
                coordinator: WorkspaceAgentAdmissionCoordinator()
            )
            let tab = ComposeTabState(name: "Admission")
            let workspace = WorkspaceModel(
                name: "Admission",
                repoPaths: [],
                customStoragePath: root,
                composeTabs: [tab],
                activeComposeTabID: tab.id
            )
            fixture.manager.workspaces = [workspace]
            fixture.manager.activeWorkspace = workspace
            fixture.prompt.loadComposeTabsFromWorkspace(workspace)
            return (fixture.manager, workspace)
        }

        private func makeManagerFixture(
            coordinator: WorkspaceAgentAdmissionCoordinator
        ) -> (
            manager: WorkspaceManagerViewModel,
            prompt: PromptViewModel
        ) {
            let fileManager = WorkspaceFilesViewModel()
            let keyManager = KeyManager(
                secureService: SecureKeysService(
                    secureStorage: TestSecureStorageBackend()
                )
            )
            let apiSettings = APISettingsViewModel(
                aiQueriesService: AIQueriesService(keyManager: keyManager),
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
                workspaceAgentAdmissionCoordinator: coordinator,
                performInitialWorkspaceActivation: false
            )
            return (manager, prompt)
        }

        private func makeTemporaryDirectory(named name: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ConcurrentSameWorkspaceAgentRunAdmissionTests-\(name)-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            return url
        }

        private func waitUntil(
            _ description: String,
            timeout: Duration = .seconds(5),
            condition: () -> Bool
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !condition() {
                guard clock.now < deadline else {
                    throw AdmissionTestError.timedOut(description)
                }
                await Task.yield()
            }
        }
    }

    @MainActor
    private struct DurableAdmissionWindow {
        let window: WindowState
        let runtime: MCPDomainRuntime
        let authorityRoot: URL
        let workspaceID: UUID
        let workspaceFileURL: URL
    }

    @MainActor
    private final class DistinctDurableAdmissionFixture {
        let first: DurableAdmissionWindow
        let second: DurableAdmissionWindow
        private let storageOverride: AdmissionWorkspaceStorageOverride
        private var isClosed = false
        private var isCleanedUp = false

        private init(
            first: DurableAdmissionWindow,
            second: DurableAdmissionWindow,
            storageOverride: AdmissionWorkspaceStorageOverride
        ) {
            self.first = first
            self.second = second
            self.storageOverride = storageOverride
        }

        static func make() async throws -> DistinctDurableAdmissionFixture {
            let container = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ConcurrentSameWorkspaceAgentRunAdmissionTests-Distinct-\(UUID().uuidString)",
                isDirectory: true
            )
            let authorityRoot = container.appendingPathComponent("state", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: authorityRoot, withIntermediateDirectories: true)
            } catch {
                try? FileManager.default.removeItem(at: container)
                throw error
            }
            let storageOverride = AdmissionWorkspaceStorageOverride(authorityRoot: authorityRoot)
            let firstAuthorityRoot = authorityRoot.appendingPathComponent("authority-A", isDirectory: true)
            let secondAuthorityRoot = authorityRoot.appendingPathComponent("authority-B", isDirectory: true)
            let firstRuntime = makeRuntime(authorityRoot: firstAuthorityRoot, label: "A")
            let secondRuntime = makeRuntime(authorityRoot: secondAuthorityRoot, label: "B")
            do {
                try await firstRuntime.start()
                try await secondRuntime.start()
            } catch {
                _ = await secondRuntime.shutdown()
                _ = await firstRuntime.shutdown()
                storageOverride.restore()
                throw error
            }
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let firstWindow = WindowState(domainRuntime: firstRuntime)
            let secondWindow = WindowState(domainRuntime: secondRuntime)
            WindowStatesManager.shared.registerWindowState(firstWindow)
            WindowStatesManager.shared.registerWindowState(secondWindow)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

            do {
                await firstWindow.workspaceManager.awaitInitialized()
                await secondWindow.workspaceManager.awaitInitialized()
                let first = try await makeDurableWindow(
                    firstWindow,
                    runtime: firstRuntime,
                    authorityRoot: firstAuthorityRoot,
                    label: "A"
                )
                let second = try await makeDurableWindow(
                    secondWindow,
                    runtime: secondRuntime,
                    authorityRoot: secondAuthorityRoot,
                    label: "B"
                )
                return DistinctDurableAdmissionFixture(
                    first: first,
                    second: second,
                    storageOverride: storageOverride
                )
            } catch {
                await close(firstWindow)
                await close(secondWindow)
                _ = await secondRuntime.shutdown()
                _ = await firstRuntime.shutdown()
                storageOverride.restore()
                throw error
            }
        }

        func withFreshRuntime<T>(
            for context: DurableAdmissionWindow,
            generation: UInt64,
            operation: (MCPDomainRuntime) async throws -> T
        ) async throws -> T {
            let restarted = MCPDomainRuntime(
                configuration: .init(
                    mode: .app,
                    profileIdentifier: "distinct-workspace-admission",
                    storageDirectory: context.authorityRoot,
                    eventDirectory: context.authorityRoot.appendingPathComponent("events-restart", isDirectory: true),
                    temporaryDirectory: context.authorityRoot.appendingPathComponent("tmp-restart", isDirectory: true),
                    externalReloadInterval: nil
                ),
                runtimeID: UUID(),
                lifecycleGeneration: generation
            )
            do {
                try await restarted.start()
                let result = try await operation(restarted)
                _ = await restarted.shutdown()
                return result
            } catch {
                _ = await restarted.shutdown()
                throw error
            }
        }

        func closeWindowsAndRuntime() async {
            guard !isClosed else { return }
            isClosed = true
            await Self.close(second.window)
            await Self.close(first.window)
            _ = await second.runtime.shutdown()
            _ = await first.runtime.shutdown()
        }

        func cleanup() async {
            guard !isCleanedUp else { return }
            isCleanedUp = true
            await closeWindowsAndRuntime()
            storageOverride.restore()
        }

        private static func makeRuntime(authorityRoot: URL, label: String) -> MCPDomainRuntime {
            MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "distinct-workspace-admission",
                storageDirectory: authorityRoot,
                eventDirectory: authorityRoot.appendingPathComponent("events-\(label)", isDirectory: true),
                temporaryDirectory: authorityRoot.appendingPathComponent("tmp-\(label)", isDirectory: true),
                externalReloadInterval: nil
            ))
        }

        private static func makeDurableWindow(
            _ window: WindowState,
            runtime: MCPDomainRuntime,
            authorityRoot: URL,
            label: String
        ) async throws -> DurableAdmissionWindow {
            let originalTab = ComposeTabState(name: "Distinct durable foreground \(label)")
            let workspace = WorkspaceModel(
                name: "Distinct durable admission \(label) \(UUID().uuidString.prefix(8))",
                repoPaths: [],
                composeTabs: [originalTab],
                activeComposeTabID: originalTab.id
            )
            window.workspaceManager.workspaces.append(workspace)
            let workspaceFileURL = try await window.workspaceManager.saveWorkspaceToFileAsync(
                workspace,
                source: .directUnknown
            )
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: workspaceFileURL)
            // A sibling window can publish a catalog projection while this synthetic workspace is
            // being created, so establish the local projection from the workspace just committed.
            if !window.workspaceManager.workspaces.contains(where: { $0.id == workspace.id }) {
                window.workspaceManager.workspaces.append(workspace)
            }
            let storedWorkspace = try XCTUnwrap(
                window.workspaceManager.workspaces.first { $0.id == workspace.id }
            )
            let switchResult = await window.workspaceManager.switchWorkspace(
                to: storedWorkspace,
                saveState: false,
                reason: "distinctWorkspaceAdmissionAcceptance"
            )
            guard switchResult.didSwitch else {
                throw AdmissionTestError.fixtureSetup(
                    switchResult.message ?? "distinct durable workspace did not become active"
                )
            }
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
            _ = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
                at: workspaceFileURL,
                scheduleNormalizationWriteback: false
            )
            return DurableAdmissionWindow(
                window: window,
                runtime: runtime,
                authorityRoot: authorityRoot,
                workspaceID: workspace.id,
                workspaceFileURL: workspaceFileURL
            )
        }

        private static func close(_ window: WindowState) async {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }
    }

    @MainActor
    private final class DurableAgentAdmissionFixture {
        let authorityRoot: URL
        let storageOverride: AdmissionWorkspaceStorageOverride
        let runtime: MCPDomainRuntime
        let window: WindowState
        let workspaceID: UUID
        let workspaceFileURL: URL
        private var peerWindows: [WindowState] = []
        private var isClosed = false
        private var isCleanedUp = false

        private init(
            authorityRoot: URL,
            storageOverride: AdmissionWorkspaceStorageOverride,
            runtime: MCPDomainRuntime,
            window: WindowState,
            workspaceID: UUID,
            workspaceFileURL: URL
        ) {
            self.authorityRoot = authorityRoot
            self.storageOverride = storageOverride
            self.runtime = runtime
            self.window = window
            self.workspaceID = workspaceID
            self.workspaceFileURL = workspaceFileURL
        }

        static func make() async throws -> DurableAgentAdmissionFixture {
            let container = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ConcurrentSameWorkspaceAgentRunAdmissionTests-Durable-\(UUID().uuidString)",
                isDirectory: true
            )
            let authorityRoot = container.appendingPathComponent("state", isDirectory: true)
            try FileManager.default.createDirectory(at: authorityRoot, withIntermediateDirectories: true)
            let storageOverride = AdmissionWorkspaceStorageOverride(authorityRoot: authorityRoot)
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "same-workspace-admission",
                storageDirectory: authorityRoot,
                eventDirectory: authorityRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: authorityRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            do {
                try await runtime.start()
            } catch {
                storageOverride.restore()
                throw error
            }

            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState(domainRuntime: runtime)
            WindowStatesManager.shared.registerWindowState(window)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            do {
                await window.workspaceManager.awaitInitialized()
                let originalTab = ComposeTabState(name: "Durable foreground")
                let workspace = WorkspaceModel(
                    name: "Concurrent durable admission \(UUID().uuidString.prefix(8))",
                    repoPaths: [],
                    composeTabs: [originalTab],
                    activeComposeTabID: originalTab.id
                )
                window.workspaceManager.workspaces.append(workspace)
                let workspaceFileURL = try await window.workspaceManager.saveWorkspaceToFileAsync(
                    workspace,
                    source: .directUnknown
                )
                await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: workspaceFileURL)
                // Catalog projection and fixture creation are independent publications; the test
                // window must expose the workspace that the authority has already committed.
                if !window.workspaceManager.workspaces.contains(where: { $0.id == workspace.id }) {
                    window.workspaceManager.workspaces.append(workspace)
                }
                let storedWorkspace = try XCTUnwrap(
                    window.workspaceManager.workspaces.first { $0.id == workspace.id }
                )
                let switchResult = await window.workspaceManager.switchWorkspace(
                    to: storedWorkspace,
                    saveState: false,
                    reason: "sameWorkspaceAdmissionAcceptance"
                )
                guard switchResult.didSwitch else {
                    throw AdmissionTestError.fixtureSetup(
                        switchResult.message ?? "durable workspace did not become active"
                    )
                }
                let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
                let canonicalSnapshot = await runtime.workspaceStore.canonicalWorkspaceSnapshot(workspace.id)
                let canonical = try XCTUnwrap(canonicalSnapshot)
                guard canonical.health == .writable else {
                    throw AdmissionTestError.fixtureSetup("canonical workspace was not writable")
                }
                return DurableAgentAdmissionFixture(
                    authorityRoot: authorityRoot,
                    storageOverride: storageOverride,
                    runtime: runtime,
                    window: window,
                    workspaceID: workspace.id,
                    workspaceFileURL: workspaceFileURL
                )
            } catch {
                window.beginClose()
                await window.tearDown()
                WindowStatesManager.shared.unregisterWindowState(window)
                _ = await runtime.shutdown()
                storageOverride.restore()
                throw error
            }
        }

        func makeFreshRuntime(generation: UInt64) -> MCPDomainRuntime {
            MCPDomainRuntime(
                configuration: .init(
                    mode: .app,
                    profileIdentifier: "same-workspace-admission",
                    storageDirectory: authorityRoot,
                    eventDirectory: authorityRoot.appendingPathComponent("events-restart", isDirectory: true),
                    temporaryDirectory: authorityRoot.appendingPathComponent("tmp-restart", isDirectory: true),
                    externalReloadInterval: nil
                ),
                runtimeID: UUID(),
                lifecycleGeneration: generation
            )
        }

        func makePeerWindow() async throws -> WindowState {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let peer = WindowState(domainRuntime: runtime)
            WindowStatesManager.shared.registerWindowState(peer)
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            peerWindows.append(peer)
            await peer.workspaceManager.awaitInitialized()

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while peer.workspaceManager.workspace(withID: workspaceID) == nil {
                guard clock.now < deadline else {
                    throw AdmissionTestError.timedOut("peer window workspace projection")
                }
                await Task.yield()
            }
            let workspace = try XCTUnwrap(peer.workspaceManager.workspace(withID: workspaceID))
            let switchResult = await peer.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "sameWorkspacePeerAdmissionAcceptance"
            )
            guard switchResult.didSwitch else {
                throw AdmissionTestError.fixtureSetup(
                    switchResult.message ?? "peer durable workspace did not become active"
                )
            }
            let activeWorkspace = try XCTUnwrap(peer.workspaceManager.activeWorkspace)
            peer.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
            return peer
        }

        func withFreshRuntime<T>(
            generation: UInt64,
            operation: (MCPDomainRuntime) async throws -> T
        ) async throws -> T {
            let restarted = makeFreshRuntime(generation: generation)
            do {
                try await restarted.start()
                let result = try await operation(restarted)
                _ = await restarted.shutdown()
                return result
            } catch {
                _ = await restarted.shutdown()
                throw error
            }
        }

        func closeWindowAndRuntime() async {
            guard !isClosed else { return }
            isClosed = true
            for peer in peerWindows.reversed() {
                peer.beginClose()
                await peer.tearDown()
                WindowStatesManager.shared.unregisterWindowState(peer)
            }
            peerWindows.removeAll()
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            _ = await runtime.shutdown()
        }

        func cleanup() async {
            guard !isCleanedUp else { return }
            isCleanedUp = true
            await closeWindowAndRuntime()
            storageOverride.restore()
        }
    }

    private final class AdmissionWorkspaceStorageOverride {
        private let defaults: UserDefaults
        private let priorStoragePath: String?
        private let cleanupRoot: URL
        private var isRestored = false

        init(authorityRoot: URL, defaults: UserDefaults = .standard) {
            self.defaults = defaults
            priorStoragePath = defaults.string(forKey: "GlobalCustomStorageURL")
            cleanupRoot = authorityRoot.deletingLastPathComponent()
            defaults.set(
                authorityRoot.appendingPathComponent("Workspaces", isDirectory: true).path,
                forKey: "GlobalCustomStorageURL"
            )
        }

        func restore() {
            guard !isRestored else { return }
            isRestored = true
            if let priorStoragePath {
                defaults.set(priorStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                defaults.removeObject(forKey: "GlobalCustomStorageURL")
            }
            try? FileManager.default.removeItem(at: cleanupRoot)
        }

        deinit {
            restore()
        }
    }

    private struct AdmissionIdentityPair: Hashable {
        let tabID: UUID
        let sessionID: UUID
    }

    private extension [ComposeTabState] {
        func containsIdentity(_ pair: AdmissionIdentityPair) -> Bool {
            contains { tab in
                tab.id == pair.tabID && tab.activeAgentSessionID == pair.sessionID
            }
        }
    }

    private final class AdmissionLifecycleEventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [AgentSessionLifecycleAuthority.Event] = []

        func record(_ event: AgentSessionLifecycleAuthority.Event) {
            lock.withLock { events.append(event) }
        }

        func snapshot() -> [AgentSessionLifecycleAuthority.Event] {
            lock.withLock { events }
        }
    }

    private final class ProvisionalAdmissionIdentityRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: AdmissionIdentityPair?

        func record(_ pair: AdmissionIdentityPair) {
            lock.withLock {
                if captured == nil {
                    captured = pair
                }
            }
        }

        func value() -> AdmissionIdentityPair? {
            lock.withLock { captured }
        }
    }

    private actor AdmissionProviderRecorder {
        struct Observation {
            let tabID: UUID
            let sessionID: UUID
            let lifecycleIdentity: AgentSessionLifecycleAuthority.Identity?
        }

        private let expectedCount: Int
        private let blockProviders: Bool
        private var values: [Observation] = []
        private var counts: [AdmissionIdentityPair: Int] = [:]
        private var isReleased = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        init(expectedCount: Int, blockProviders: Bool = true) {
            self.expectedCount = expectedCount
            self.blockProviders = blockProviders
        }

        func recordAndWait(_ observation: Observation) async throws {
            let pair = AdmissionIdentityPair(tabID: observation.tabID, sessionID: observation.sessionID)
            counts[pair, default: 0] += 1
            guard counts[pair] == 1 else {
                throw AdmissionTestError.duplicateProviderDispatch(pair)
            }
            guard values.count < expectedCount else {
                throw AdmissionTestError.excessProviderDispatch(expectedCount)
            }
            values.append(observation)
            guard blockProviders, !isReleased else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func count() -> Int {
            values.count
        }

        func observations() -> [Observation] {
            values
        }

        func attemptCounts() -> [AdmissionIdentityPair: Int] {
            counts
        }

        func releaseAll() {
            isReleased = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private actor AdmissionSaveGate {
        private var didEnter = false
        private var isOpen = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enterFirstAndWait() async {
            guard !didEnter else { return }
            didEnter = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            guard !isOpen else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func hasEntered() -> Bool {
            didEnter
        }

        func open() {
            isOpen = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private enum AdmissionTestError: Error {
        case expected
        case queuePhaseSentinel(UUID)
        case timedOut(String)
        case fixtureSetup(String)
        case duplicateProviderDispatch(AdmissionIdentityPair)
        case excessProviderDispatch(Int)
    }

    private actor AdmissionStartTaskTerminationProbe {
        private var count = 0

        func recordTermination() {
            count += 1
        }

        func terminationCount() -> Int {
            count
        }
    }

    private actor AdmissionOrderRecorder {
        private var recorded: [UUID] = []

        func append(_ id: UUID) {
            recorded.append(id)
        }

        func values() -> [UUID] {
            recorded
        }
    }

    private actor AdmissionHandoffGate {
        private var entered = false
        private var isOpen = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enterAndWait() async {
            entered = true
            let pendingEntryWaiters = entryWaiters
            entryWaiters.removeAll()
            pendingEntryWaiters.forEach { $0.resume() }
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { continuation in
                entryWaiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let pendingReleaseWaiters = releaseWaiters
            releaseWaiters.removeAll()
            pendingReleaseWaiters.forEach { $0.resume() }
        }
    }

    private actor AdmissionTestSuiteGate {
        static let shared = AdmissionTestSuiteGate()

        private var isHeld = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            guard isHeld else {
                isHeld = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            guard !waiters.isEmpty else {
                isHeld = false
                return
            }
            waiters.removeFirst().resume()
        }
    }
#endif
