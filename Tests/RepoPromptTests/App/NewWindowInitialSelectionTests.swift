import Combine
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptFileSystem
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import XCTest

#if DEBUG
    /// #1128: an untouched new window stays on the workspace chooser while the catalog loads and
    /// the initial System Default activation runs. Catalog projection must never invent a first
    /// non-System selection; explicit intent, queued restore, and established-selection recovery
    /// keep their semantics.
    @MainActor
    final class NewWindowInitialSelectionTests: XCTestCase {
        private typealias Fixture = NewWindowInitialSelectionFixture

        // MARK: 1. Decisive production-composition regression

        func testUntouchedWindowNeverPublishesMainWhileInitialDefaultIsGated() async throws {
            // Aardvark sorts before Default in the runtime catalog: the discriminating order.
            try await Fixture.run { f in
                let window = f.makeWindow()
                let manager = window.workspaceManager
                let projectionObserver = f.projectionObserver(for: window)
                let defaultGate = f.makeGate()
                let defaultEntered = Signal("initial Default reached its publication gate")
                manager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting { workspaceID in
                    guard workspaceID == Fixture.defaultID else { return }
                    defaultEntered.fire()
                    await defaultGate.wait()
                }
                let (route, recorder) = f.makeRecordedRoute(for: window)
                let routeStart = recorder.routes.count
                route.evaluateInitialRouteIfNeeded()
                XCTAssertEqual(route.rootRoute, .workspaceEntry)

                let zeroCheckpoint = await projectionObserver.waitForProjection(afterGeneration: 0, through: 0)
                XCTAssertNotNil(zeroCheckpoint, "Sequence zero must still require a real bridge application")
                try await f.awaitCatalogProjection(window)
                XCTAssertTrue(Fixture.standardIDs.isSubset(of: Set(manager.workspaces.map(\.id))))
                try await f.acknowledgeRouteConsumption(recorder)
                guard f.assertNoUnsolicitedSelection(
                    recorder,
                    routeStart: routeStart,
                    context: "while Default is gated"
                ) else { return }

                try await f.wait(defaultEntered)
                XCTAssertEqual(manager.activeWorkspaceSwitch?.targetWorkspaceID, Fixture.defaultID)
                XCTAssertNil(manager.activeWorkspaceID)
                XCTAssertEqual(route.rootRoute, .workspaceEntry)

                defaultGate.release()
                await manager.awaitInitialWorkspaceActivationCompletion()
                await manager.awaitInitialized()
                try await f.acknowledgeRouteConsumption(recorder)
                XCTAssertEqual(manager.activeWorkspaceID, Fixture.defaultID)
                XCTAssertEqual(route.rootRoute, .workspaceEntry)
                f.assertNoUnsolicitedSelection(recorder, routeStart: routeStart, context: "after Default published")
            }

            // Control: Default sorts first; no publication gate is required for this order.
            try await Fixture.run(seeds: Fixture.defaultFirstSeeds) { f in
                let window = f.makeWindow()
                let manager = window.workspaceManager
                let projectionObserver = f.projectionObserver(for: window)
                let (route, recorder) = f.makeRecordedRoute(for: window)
                let routeStart = recorder.routes.count
                route.evaluateInitialRouteIfNeeded()
                await manager.awaitInitialWorkspaceActivationCompletion()
                await manager.awaitInitialized()
                try await f.awaitCatalogProjection(window)
                try await f.acknowledgeRouteConsumption(recorder)
                XCTAssertEqual(manager.activeWorkspaceID, Fixture.defaultID)
                XCTAssertEqual(route.rootRoute, .workspaceEntry)
                f.assertNoUnsolicitedSelection(recorder, routeStart: routeStart, context: "Default-first control")

                // Bridge checkpoint journeys: timeout, caller cancellation, stop, and restart.
                let applied = try XCTUnwrap(f.projectionState(for: window).checkpoint)
                XCTAssertEqual(applied.generation, f.projectionState(for: window).generation)
                // An unsatisfiable generation isolates the timeout path from unrelated self-echoes.
                let unsatisfiable = UInt64.max - 1
                let timedOut = await projectionObserver.waitForProjection(
                    afterGeneration: unsatisfiable, timeout: .milliseconds(50)
                )
                XCTAssertNil(timedOut, "A deadline resolves an unsatisfied wait with nil")
                XCTAssertEqual(projectionObserver.pendingWaiterCount, 0)
                let cancelledWait = f.startOwned {
                    await projectionObserver.waitForProjection(afterGeneration: unsatisfiable, timeout: .seconds(30))
                }
                try await f.awaitPendingProjectionWaiter(projectionObserver)
                cancelledWait.cancel()
                let cancelledResult = await cancelledWait.value
                XCTAssertNil(cancelledResult, "A registered waiter resolves nil on caller cancellation")
                let stoppedWait = f.startOwned {
                    await projectionObserver.waitForProjection(afterGeneration: unsatisfiable, timeout: .seconds(30))
                }
                try await f.awaitPendingProjectionWaiter(projectionObserver)
                let generation = f.projectionState(for: window).generation
                await window.joinDomainWorkspaceBridgeForTesting()
                let stoppedResult = await stoppedWait.value
                XCTAssertNil(stoppedResult, "Stop resolves a registered wait unsuccessfully")
                XCTAssertEqual(projectionObserver.pendingWaiterCount, 0)
                XCTAssertNil(f.projectionState(for: window).checkpoint, "Stop clears checkpoint validity")
                XCTAssertEqual(f.projectionState(for: window).generation, generation)
                window.restartDomainWorkspaceProjectionForTesting()
                let restartedCheckpoint = await projectionObserver.waitForProjection(
                    afterGeneration: generation, timeout: .seconds(15)
                )
                let restarted = try XCTUnwrap(restartedCheckpoint)
                XCTAssertNotEqual(restarted.runID, applied.runID, "A restarted incarnation is not credited to the old run")
                XCTAssertGreaterThan(restarted.generation, generation, "Generation stays monotonic across stop/start")
                XCTAssertEqual(manager.activeWorkspaceID, Fixture.defaultID)
            }
        }

        // MARK: 2. Explicit intent supersedes startup

        func testExplicitOpenSupersedesLateInitialDefault() async throws {
            // Pre-resolution hold: requested and direct opens complete without waiting for lookup.
            for useDirectSwitch in [false, true] {
                try await Fixture.run { f in
                    let window = f.makeWindow()
                    let manager = window.workspaceManager
                    let hold = f.holdInitialResolution(manager)
                    let recorder = f.makeRecorder(manager: manager)
                    try await f.wait(hold.entered)
                    try await f.awaitCatalogProjection(window)
                    let target = try XCTUnwrap(manager.workspace(withID: Fixture.requestedID))
                    // Owned + bounded: a regression that joins unresolved startup must fail, not hang.
                    let finished = Signal("explicit open finished while startup lookup is held")
                    let open = f.startOwned { () -> WorkspaceSwitchResult in
                        let result: WorkspaceSwitchResult = if useDirectSwitch {
                            await manager.switchWorkspace(to: target, saveState: false, reason: "test direct open")
                        } else {
                            await manager.requestWorkspaceSwitch(to: target)
                        }
                        finished.fire()
                        return result
                    }
                    try await f.wait(finished)
                    let result = await open.value
                    XCTAssertTrue(result.didSwitch, "\(result)")
                    let assignedAt = recorder.emittedIDs.count
                    hold.gate.release()
                    await manager.awaitInitialWorkspaceActivationCompletion()
                    await manager.awaitInitialized()
                    XCTAssertEqual(manager.activeWorkspaceID, Fixture.requestedID)
                    XCTAssertFalse(recorder.emittedIDs[assignedAt...].contains(Fixture.defaultID))
                }
            }

            // Rejected explicit request still revokes startup; only later System projection recovers.
            try await Fixture.run { f in
                let window = f.makeWindow()
                let manager = window.workspaceManager
                let hold = f.holdInitialResolution(manager)
                try await f.wait(hold.entered)
                try await f.awaitCatalogProjection(window)
                manager.setActiveConsolidatedRestoreProtectionForTesting(Fixture.requestedID, isProtected: true)
                let target = try XCTUnwrap(manager.workspace(withID: Fixture.requestedID))
                let result = await manager.requestWorkspaceSwitch(to: target)
                guard case .blocked = result else { return XCTFail("Expected blocked result, got \(result)") }
                manager.setActiveConsolidatedRestoreProtectionForTesting(Fixture.requestedID, isProtected: false)
                hold.gate.release()
                await manager.awaitInitialWorkspaceActivationCompletion()
                await manager.awaitInitialized()
                XCTAssertNil(manager.activeWorkspaceID, "Failed explicit intent never revives startup")
                XCTAssertFalse(manager.hasEstablishedWorkspaceSelectionForTesting)
                _ = try await f.commitWorkspace(named: "Later user record", window: window)
                XCTAssertEqual(manager.activeWorkspaceID, Fixture.defaultID, "Later System projection recovers")
            }

            // Admitted startup held before publication: the explicit open joins it, then wins.
            try await Fixture.run { f in
                let window = f.makeWindow()
                let manager = window.workspaceManager
                let hold = f.holdPublication(manager, of: Fixture.defaultID)
                let recovery = f.countRecoveryBegins(manager)
                let recorder = f.makeRecorder(manager: manager)
                try await f.wait(hold.entered)
                try await f.awaitCatalogProjection(window)
                let superseded = f.observeSupersession(manager)
                let target = try XCTUnwrap(manager.workspace(withID: Fixture.requestedID))
                let open = f.startOwned { await manager.requestWorkspaceSwitch(to: target) }
                try await f.wait(superseded)
                hold.gate.release()
                let result = await open.value
                XCTAssertTrue(result.didSwitch, "\(result)")
                await manager.awaitInitialWorkspaceActivationCompletion()
                XCTAssertEqual(manager.activeWorkspaceID, Fixture.requestedID)
                XCTAssertFalse(recorder.emittedIDs.contains(Fixture.defaultID))
                XCTAssertEqual(recovery.count, 0)
            }

            // Cancelling the explicit caller while it joins admitted startup: no activation, no revival.
            try await Fixture.run { f in
                let window = f.makeWindow()
                let manager = window.workspaceManager
                let hold = f.holdPublication(manager, of: Fixture.defaultID)
                try await f.wait(hold.entered)
                try await f.awaitCatalogProjection(window)
                let superseded = f.observeSupersession(manager)
                let target = try XCTUnwrap(manager.workspace(withID: Fixture.requestedID))
                let open = f.startOwned { await manager.requestWorkspaceSwitch(to: target) }
                try await f.wait(superseded)
                open.cancel()
                hold.gate.release()
                let result = await open.value
                guard case .cancelled = result else { return XCTFail("Expected cancellation, got \(result)") }
                await manager.awaitInitialWorkspaceActivationCompletion()
                XCTAssertNil(manager.activeWorkspaceID)
                XCTAssertNil(manager.pendingWorkspaceSwitchBlockedNotice)
            }

            // Synchronous setter while startup is held before publication.
            try await Fixture.run { f in
                let window = f.makeWindow()
                let manager = window.workspaceManager
                let hold = f.holdPublication(manager, of: Fixture.defaultID)
                let recovery = f.countRecoveryBegins(manager)
                let recorder = f.makeRecorder(manager: manager)
                try await f.wait(hold.entered)
                try await f.awaitCatalogProjection(window)
                manager.activeWorkspace = manager.workspace(withID: Fixture.requestedID)
                let assignedAt = recorder.emittedIDs.count
                hold.gate.release()
                await manager.awaitInitialWorkspaceActivationCompletion()
                await manager.awaitInitialized()
                XCTAssertEqual(manager.activeWorkspaceID, Fixture.requestedID)
                XCTAssertTrue(
                    recorder.emittedIDs[assignedAt...].allSatisfy { $0 == Fixture.requestedID },
                    "No different ID emitted after the setter"
                )
                XCTAssertEqual(recovery.count, 0)
            }

            // Published startup held at hydration spawn: explicit open joins hydration, then publishes.
            try await Fixture.run { f in
                let window = f.makeWindow()
                let manager = window.workspaceManager
                let hold = f.holdHydrationSpawn(manager, of: Fixture.defaultID)
                let recovery = f.countRecoveryBegins(manager)
                let recorder = f.makeRecorder(manager: manager)
                try await f.wait(hold.entered)
                try await f.awaitCatalogProjection(window)
                let superseded = f.observeSupersession(manager)
                let target = try XCTUnwrap(manager.workspace(withID: Fixture.requestedID))
                let open = f.startOwned { await manager.requestWorkspaceSwitch(to: target) }
                try await f.wait(superseded)
                hold.gate.release()
                let result = await open.value
                XCTAssertTrue(result.didSwitch, "\(result)")
                XCTAssertEqual(manager.activeWorkspaceID, Fixture.requestedID)
                XCTAssertEqual(recorder.emittedIDs.count(where: { $0 == Fixture.defaultID }), 1)
                XCTAssertEqual(recovery.count, 0)
            }

            // Same-ID reactivation of published startup joins instead of returning concurrent-blocked.
            try await Fixture.run { f in
                let window = f.makeWindow()
                let manager = window.workspaceManager
                let hold = f.holdHydrationSpawn(manager, of: Fixture.defaultID)
                try await f.wait(hold.entered)
                try await f.awaitCatalogProjection(window)
                let superseded = f.observeSupersession(manager)
                let target = try XCTUnwrap(manager.workspace(withID: Fixture.defaultID))
                let reactivate = f.startOwned { await manager.reactivateWorkspaceAfterReplacement(target) }
                try await f.wait(superseded)
                hold.gate.release()
                let result = await reactivate.value
                XCTAssertTrue(result.didSwitch, "\(result)")
                XCTAssertEqual(manager.activeWorkspaceID, Fixture.defaultID)
            }

            // Explicit intent retires a queued, not-yet-dispatched restore (successful and rejected).
            for rejectsExplicitTarget in [false, true] {
                try await Fixture.run { f in
                    let window = f.makeWindow()
                    let manager = window.workspaceManager
                    let hold = f.holdInitialResolution(manager)
                    let recorder = f.makeRecorder(manager: manager)
                    try await f.wait(hold.entered)
                    try await f.awaitCatalogProjection(window)
                    let entry = f.restoreEntry(for: Fixture.requestedID, window: window)
                    var completions = 0
                    window.applyWindowRestoreEntry(entry) { completions += 1 }
                    XCTAssertEqual(completions, 0)
                    if rejectsExplicitTarget {
                        manager.setActiveConsolidatedRestoreProtectionForTesting(Fixture.aardvarkID, isProtected: true)
                    }
                    let explicitTarget = try XCTUnwrap(manager.workspace(withID: Fixture.aardvarkID))
                    let result = await manager.requestWorkspaceSwitch(to: explicitTarget)
                    XCTAssertEqual(completions, 1, "Pending restore completes once without dispatch")
                    XCTAssertFalse(window.hasPendingRestoreEntryForTesting)
                    manager.setActiveConsolidatedRestoreProtectionForTesting(Fixture.aardvarkID, isProtected: false)
                    hold.gate.release()
                    await manager.awaitInitialWorkspaceActivationCompletion()
                    await manager.awaitInitialized()
                    try await f.acknowledgeWindowObservers(window)
                    XCTAssertEqual(completions, 1)
                    XCTAssertFalse(recorder.emittedIDs.contains(Fixture.requestedID), "Restore never dispatched")
                    if rejectsExplicitTarget {
                        guard case .blocked = result else { return XCTFail("Expected blocked, got \(result)") }
                        XCTAssertNil(manager.activeWorkspaceID)
                        XCTAssertEqual(window.protectedRestoreEntryForTesting?.workspaceID, Fixture.requestedID)
                        XCTAssertEqual(
                            window.sessionCaptureCandidate().entry?.workspaceID,
                            Fixture.requestedID
                        )
                    } else {
                        XCTAssertTrue(result.didSwitch, "\(result)")
                        XCTAssertEqual(manager.activeWorkspaceID, Fixture.aardvarkID)
                        XCTAssertNil(window.protectedRestoreEntryForTesting)
                    }
                }
            }
        }

        // MARK: 3. Failed startup converges only on later System projection

        func testFailedInitialDefaultWaitsForLaterSystemProjection() async throws {
            // Existing System: a later real canonical update selects only System.
            try await Fixture.run { f in
                let window = f.makeWindow()
                let manager = window.workspaceManager
                // Fail only after the first projection applied while startup still owned activation.
                let gate = f.makeGate()
                let entered = Signal("startup reached resolution")
                manager.setInitialDefaultResolutionHandlerForTesting {
                    entered.fire()
                    await gate.wait()
                    return .fail
                }
                let (route, recorder) = f.makeRecordedRoute(for: window)
                let routeStart = recorder.routes.count
                route.evaluateInitialRouteIfNeeded()
                try await f.wait(entered)
                try await f.awaitCatalogProjection(window)
                gate.release()
                await manager.awaitInitialWorkspaceActivationCompletion()
                await manager.awaitInitialized()
                try await f.acknowledgeRouteConsumption(recorder)
                XCTAssertNil(manager.activeWorkspaceID)
                XCTAssertEqual(route.rootRoute, .workspaceEntry)

                _ = try await f.commitWorkspace(named: "Later user record", window: window)
                try await f.acknowledgeRouteConsumption(recorder)
                XCTAssertEqual(manager.activeWorkspaceID, Fixture.defaultID)
                XCTAssertEqual(route.rootRoute, .workspaceEntry)
                f.assertNoUnsolicitedSelection(recorder, routeStart: routeStart, context: "failed startup recovery")
            }

            // No System: user-record updates stay nil; later System creation converges.
            try await Fixture.run(seeds: Fixture.userOnlySeeds) { f in
                let window = f.makeWindow()
                let manager = window.workspaceManager
                manager.setInitialDefaultResolutionHandlerForTesting { .fail }
                await manager.awaitInitialWorkspaceActivationCompletion()
                await manager.awaitInitialized()
                try await f.awaitCatalogProjection(window)
                // No System exists, so projection order relative to startup does not matter here.
                XCTAssertNil(manager.activeWorkspaceID)
                _ = try await f.commitWorkspace(named: "Another user record", window: window)
                XCTAssertNil(manager.activeWorkspaceID)
                let system = try await f.commitWorkspace(named: "Recovered System", isSystem: true, window: window)
                XCTAssertEqual(manager.activeWorkspaceID, system.id)
            }

            // Unchanged-digest publication through the real bridge: a never-established manager
            // converges on System via the metadata-only projection path, never on a user record.
            try await Fixture.run { f in
                // Dirty a user record before the window exists so its later save changes revisions
                // without changing any document digest.
                let author = DomainWorkspaceAuthorityClient(store: f.runtime.workspaceStore, windowID: -11281)
                let seeded = await f.runtime.workspaceStore.workspaceSnapshot(Fixture.aardvarkID)
                let before = try XCTUnwrap(seeded)
                var edited = Fixture.model(id: Fixture.aardvarkID, name: "Aardvark")
                edited.lastUsed = edited.lastUsed.addingTimeInterval(60)
                let working = try await author.replaceWorking(
                    edited,
                    fileURL: f.workspaceURL(for: edited),
                    expectedWorkspaceRevision: before.revisions.workingRevision
                )
                XCTAssertEqual(working.disposition, .applied, "\(working)")

                let window = f.makeWindow()
                let manager = window.workspaceManager
                let gate = f.makeGate()
                let entered = Signal("startup reached resolution")
                manager.setInitialDefaultResolutionHandlerForTesting {
                    entered.fire()
                    await gate.wait()
                    return .fail
                }
                let (route, recorder) = f.makeRecordedRoute(for: window)
                let routeStart = recorder.routes.count
                route.evaluateInitialRouteIfNeeded()
                try await f.wait(entered)
                try await f.awaitCatalogProjection(window)
                gate.release()
                await manager.awaitInitialWorkspaceActivationCompletion()
                await manager.awaitInitialized()
                try await f.acknowledgeRouteConsumption(recorder)
                XCTAssertNil(manager.activeWorkspaceID)
                XCTAssertFalse(manager.hasEstablishedWorkspaceSelectionForTesting)
                XCTAssertEqual(route.rootRoute, .workspaceEntry)

                let catalogBefore = await f.runtime.workspaceStore.snapshot()
                let dirty = try XCTUnwrap(catalogBefore.workspaces.first { $0.document.workspaceID == Fixture.aardvarkID })
                XCTAssertNotNil(dirty.revisions.dirtyRevision)
                let saved = await author.saveCommittedWorkingRevision(
                    workspaceID: Fixture.aardvarkID,
                    expectedWorkspaceRevision: dirty.revisions.workingRevision
                )
                XCTAssertEqual(saved.disposition, .applied, "\(saved)")
                let catalogAfter = await f.runtime.workspaceStore.snapshot()
                func digests(_ snapshot: DomainWorkspaceCatalogSnapshot) -> [UUID: String] {
                    Dictionary(uniqueKeysWithValues: snapshot.workspaces.map {
                        ($0.document.workspaceID, $0.document.contentDigest)
                    })
                }
                XCTAssertGreaterThan(catalogAfter.publicationSequence, catalogBefore.publicationSequence)
                XCTAssertEqual(digests(catalogAfter), digests(catalogBefore), "Publication must be metadata-only")
                try await f.awaitCatalogProjection(window)
                try await f.acknowledgeRouteConsumption(recorder)

                XCTAssertEqual(manager.activeWorkspaceID, Fixture.defaultID)
                XCTAssertTrue(manager.hasEstablishedWorkspaceSelectionForTesting)
                XCTAssertEqual(route.rootRoute, .workspaceEntry)
                f.assertNoUnsolicitedSelection(recorder, routeStart: routeStart, context: "metadata-only recovery")
            }
        }

        // MARK: 4. Never-established projection policy

        func testNeverEstablishedProjectionAdoptsOnlyEligibleCanonicalSystemWorkspace() async throws {
            try await Fixture.run(seeds: []) { f in
                let aardvark = Fixture.model(id: Fixture.aardvarkID, name: "Aardvark")
                let requested = Fixture.model(id: Fixture.requestedID, name: "Z requested")
                let system = Fixture.model(id: Fixture.defaultID, name: "Default", isSystem: true)
                let otherSystemID = UUID(uuidString: "5A000000-0000-0000-0000-000000000005")!
                let otherSystem = Fixture.model(id: otherSystemID, name: "Other System", isSystem: true)

                struct Row {
                    let name: String
                    let models: [WorkspaceModel]
                    var dirty: Set<UUID> = []
                    var preferred: UUID?
                    var pendingRestore: UUID?
                    var denyActivation: UUID?
                    let expected: UUID?
                }
                var consolidatedSystem = system
                consolidatedSystem.consolidatedIntoWorkspaceID = Fixture.aardvarkID
                var hiddenSystem = system
                hiddenSystem.isHiddenInMenus = true
                let rows: [Row] = [
                    Row(name: "no System", models: [aardvark, requested], expected: nil),
                    Row(name: "non-System preferred without System", models: [aardvark, requested], preferred: aardvark.id, expected: nil),
                    Row(name: "System after user records ignores preferred", models: [aardvark, system, requested], preferred: aardvark.id, expected: system.id),
                    Row(name: "dirty System", models: [aardvark, system], dirty: [system.id], expected: nil),
                    Row(name: "consolidated System", models: [aardvark, consolidatedSystem], expected: nil),
                    Row(name: "pending-restore System", models: [aardvark, system], pendingRestore: system.id, expected: nil),
                    Row(name: "hidden System stays eligible", models: [aardvark, hiddenSystem], expected: system.id),
                    Row(name: "multiple Systems keep supplied order", models: [aardvark, otherSystem, system], expected: otherSystemID),
                    Row(name: "System lease denial", models: [aardvark, system], denyActivation: system.id, expected: nil)
                ]
                for row in rows {
                    let coordinator = WorkspaceActivityCoordinator()
                    let manager = f.makeManager(coordinator: coordinator)
                    if let pendingRestore = row.pendingRestore {
                        manager.setActiveConsolidatedRestoreProtectionForTesting(pendingRestore, isProtected: true)
                    }
                    let claim = row.denyActivation.map { coordinator.claimDeletion(workspaceIDs: [$0]) }
                    f.project(manager, row.models, dirty: row.dirty, preferred: row.preferred)
                    XCTAssertEqual(manager.activeWorkspaceID, row.expected, row.name)
                    XCTAssertEqual(Set(manager.workspaces.map(\.id)), Set(row.models.map(\.id)), "\(row.name): catalog applied")
                    XCTAssertEqual(manager.hasEstablishedWorkspaceSelectionForTesting, row.expected != nil, row.name)
                    if let claim {
                        coordinator.releaseDeletion(claim.lease)
                        f.project(manager, row.models)
                        XCTAssertEqual(manager.activeWorkspaceID, system.id, "\(row.name): later projection recovers")
                    }
                    if let pendingRestore = row.pendingRestore {
                        manager.setActiveConsolidatedRestoreProtectionForTesting(pendingRestore, isProtected: false)
                    }
                }

                // Metadata entry point: canonical evidence must match a reconciled System model.
                let manager = f.makeManager()
                f.project(manager, [aardvark, system], dirty: [system.id])
                f.projectMetadata(manager, [aardvark, system], canonicalSystemIDs: [])
                XCTAssertNil(manager.activeWorkspaceID, "Empty canonical evidence fails closed")
                f.projectMetadata(manager, [aardvark, system], canonicalSystemIDs: [aardvark.id])
                XCTAssertNil(manager.activeWorkspaceID, "Canonical/reconciled classification mismatch")
                f.projectMetadata(manager, [aardvark, system], canonicalSystemIDs: [system.id])
                XCTAssertEqual(manager.activeWorkspaceID, system.id)

                // A closing manager never adopts.
                let closing = f.makeManager()
                closing.prepareForWindowClose()
                f.project(closing, [aardvark, system])
                XCTAssertNil(closing.activeWorkspaceID)
            }
        }

        // MARK: 5. Established-selection recovery is unchanged

        func testProjectionRecoversAfterEstablishedSelectionLoss() async throws {
            try await Fixture.run(seeds: []) { f in
                let aardvark = Fixture.model(id: Fixture.aardvarkID, name: "Aardvark")
                let requested = Fixture.model(id: Fixture.requestedID, name: "Z requested")
                let system = Fixture.model(id: Fixture.defaultID, name: "Default", isSystem: true)
                var consolidatedRequested = requested
                consolidatedRequested.consolidatedIntoWorkspaceID = Fixture.aardvarkID

                /// Establishes `requested` through the writable setter after a first projection.
                @MainActor
                func establishedManager(coordinator: WorkspaceActivityCoordinator? = nil) -> WorkspaceManagerViewModel {
                    let manager = f.makeManager(coordinator: coordinator)
                    // No System yet, so only the setter can establish history.
                    f.project(manager, [requested, aardvark])
                    XCTAssertNil(manager.activeWorkspaceID)
                    XCTAssertFalse(manager.hasEstablishedWorkspaceSelectionForTesting)
                    manager.activeWorkspace = manager.workspace(withID: requested.id)
                    XCTAssertTrue(manager.hasEstablishedWorkspaceSelectionForTesting)
                    XCTAssertEqual(manager.activeWorkspaceID, requested.id)
                    return manager
                }

                // Established via actual activation (no authority): omission recovers to first eligible.
                do {
                    let manager = f.makeManager(withAuthority: false)
                    f.project(manager, [requested, aardvark])
                    XCTAssertFalse(manager.hasEstablishedWorkspaceSelectionForTesting)
                    let target = try XCTUnwrap(manager.workspace(withID: requested.id))
                    let result = await manager.switchWorkspace(to: target, saveState: false)
                    XCTAssertTrue(result.didSwitch, "\(result)")
                    f.project(manager, [aardvark, system])
                    XCTAssertEqual(manager.activeWorkspaceID, aardvark.id, "First eligible fallback even though System follows")
                }

                var manager = establishedManager()
                f.project(manager, [aardvark, system])
                XCTAssertEqual(manager.activeWorkspaceID, aardvark.id, "omitted established ID")

                manager = establishedManager()
                manager.activeWorkspace = nil
                XCTAssertTrue(manager.hasEstablishedWorkspaceSelectionForTesting, "nil never erases history")
                f.project(manager, [aardvark, system])
                XCTAssertEqual(manager.activeWorkspaceID, aardvark.id, "cleared established ID")

                manager = establishedManager()
                f.project(manager, [consolidatedRequested, aardvark, system])
                XCTAssertEqual(manager.activeWorkspaceID, aardvark.id, "consolidated active record")

                manager = establishedManager()
                manager.setActiveConsolidatedRestoreProtectionForTesting(requested.id, isProtected: true)
                f.project(manager, [requested, aardvark, system])
                XCTAssertEqual(manager.activeWorkspaceID, aardvark.id, "pending-restore active record")
                manager.setActiveConsolidatedRestoreProtectionForTesting(requested.id, isProtected: false)

                manager = establishedManager()
                f.project(manager, [])
                XCTAssertNil(manager.activeWorkspaceID, "empty catalog")
                f.project(manager, [aardvark, system])
                XCTAssertEqual(manager.activeWorkspaceID, aardvark.id, "history survives the gap")

                let coordinator = WorkspaceActivityCoordinator()
                manager = establishedManager(coordinator: coordinator)
                let claim = coordinator.claimDeletion(workspaceIDs: [aardvark.id])
                f.project(manager, [aardvark, system])
                XCTAssertNil(manager.activeWorkspaceID, "denied first fallback clears; no skip-ahead")
                coordinator.releaseDeletion(claim.lease)
                f.project(manager, [aardvark, system])
                XCTAssertEqual(manager.activeWorkspaceID, aardvark.id, "later projection recovers")

                manager = establishedManager()
                f.project(manager, [aardvark, requested], dirty: [requested.id], preferred: requested.id)
                XCTAssertEqual(manager.activeWorkspaceID, requested.id, "dirty current preserved")

                manager = establishedManager()
                f.project(manager, [aardvark, requested], dirty: [aardvark.id], preferred: aardvark.id)
                XCTAssertEqual(manager.activeWorkspaceID, requested.id, "dirty non-current preferred rejected")

                manager = establishedManager()
                f.project(manager, [aardvark, requested], preferred: aardvark.id)
                XCTAssertEqual(manager.activeWorkspaceID, aardvark.id, "clean preferred adopted")

                manager = establishedManager()
                f.project(manager, [aardvark, system], dirty: [aardvark.id])
                XCTAssertEqual(manager.activeWorkspaceID, system.id, "dirty persistent first candidate skipped")

                manager = establishedManager()
                let ephemeral = manager.createEphemeralWorkspace(name: "Temporary fallback", repoPaths: [])
                f.project(manager, [aardvark], dirty: [aardvark.id])
                XCTAssertEqual(manager.activeWorkspaceID, ephemeral.id, "ephemeral fallback exception")
            }
        }

        // MARK: 6. Queued restore after startup

        func testQueuedRestoreRunsAfterInitialSelectionAttemptCompletes() async throws {
            for failsStartup in [false, true] {
                try await Fixture.run { f in
                    let window = f.makeWindow()
                    let manager = window.workspaceManager
                    let gate = f.makeGate()
                    let entered = Signal("startup reached resolution")
                    manager.setInitialDefaultResolutionHandlerForTesting {
                        entered.fire()
                        await gate.wait()
                        return failsStartup ? .fail : .proceed
                    }
                    let (route, routeRecorder) = f.makeRecordedRoute(for: window)
                    route.evaluateInitialRouteIfNeeded()
                    try await f.wait(entered)
                    try await f.awaitCatalogProjection(window)

                    let entry = f.restoreEntry(for: Fixture.requestedID, window: window)
                    let restored = Signal("restore completion")
                    window.applyWindowRestoreEntry(entry) { restored.fire() }
                    XCTAssertEqual(window.protectedRestoreEntryForTesting?.workspaceID, Fixture.requestedID, "armed at acceptance")
                    XCTAssertEqual(
                        window.sessionCaptureCandidate().entry?.workspaceID,
                        Fixture.requestedID,
                        "nil-active capture re-emits the protected entry"
                    )
                    XCTAssertEqual(restored.count, 0, "No restore before initialization")
                    XCTAssertTrue(window.hasPendingRestoreEntryForTesting)

                    gate.release()
                    await manager.awaitInitialWorkspaceActivationCompletion()
                    try await f.wait(restored)
                    try await f.acknowledgeRouteConsumption(routeRecorder)
                    try await f.acknowledgeWindowObservers(window)
                    XCTAssertEqual(restored.count, 1)
                    XCTAssertEqual(manager.activeWorkspaceID, Fixture.requestedID)
                    XCTAssertEqual(route.rootRoute, .main)
                    XCTAssertNil(window.protectedRestoreEntryForTesting)
                    XCTAssertEqual(
                        window.sessionCaptureCandidate().entry?.workspaceID,
                        Fixture.requestedID,
                        "successful selection captures its target"
                    )

                    _ = try await f.commitWorkspace(named: "Later user record", window: window)
                    XCTAssertEqual(manager.activeWorkspaceID, Fixture.requestedID, "Projection cannot restore Default over it")
                }
            }
        }

        /// A selection published before a restore acceptance must not release that acceptance's
        /// protection, even when the window's observer delivers the selection afterwards.
        func testSelectionPublishedBeforeRestoreAcceptanceKeepsItsProtection() async throws {
            try await Fixture.run { f in
                let window = f.makeWindow()
                let manager = window.workspaceManager
                let hold = f.holdInitialResolution(manager)
                try await f.wait(hold.entered)
                try await f.awaitCatalogProjection(window)

                // Publish a real selection and accept a restore in the same MainActor turn, so the
                // observer's RunLoop delivery lands after the acceptance. The setter publishes
                // synchronously; a requested switch suspends and could let the observer drain first.
                manager.activeWorkspace = try XCTUnwrap(manager.workspace(withID: Fixture.aardvarkID))
                let entry = f.restoreEntry(for: Fixture.requestedID, window: window)
                let restored = Signal("restore completion")
                window.applyWindowRestoreEntry(entry) { restored.fire() }
                XCTAssertTrue(window.hasPendingRestoreEntryForTesting)
                try await f.acknowledgeWindowObservers(window)

                XCTAssertEqual(
                    window.protectedRestoreEntryForTesting?.workspaceID,
                    Fixture.requestedID,
                    "A late-delivered pre-acceptance selection keeps the newer protection"
                )
                XCTAssertEqual(
                    window.sessionCaptureCandidate().entry?.workspaceID,
                    Fixture.aardvarkID,
                    "Protection never overrides a real live selection"
                )

                hold.gate.release()
                await manager.awaitInitialWorkspaceActivationCompletion()
                try await f.wait(restored)
                try await f.acknowledgeWindowObservers(window)
                XCTAssertEqual(restored.count, 1)
                XCTAssertEqual(manager.activeWorkspaceID, Fixture.requestedID)
                XCTAssertNil(window.protectedRestoreEntryForTesting, "Post-acceptance selection releases protection")
                XCTAssertEqual(window.sessionCaptureCandidate().entry?.workspaceID, Fixture.requestedID)
            }
        }

        /// A displaced completion runs after the newer acceptance is installed, so reentrant
        /// acceptance or close sees it, and every acceptance completes exactly once.
        func testDisplacedRestoreCompletionReentrancy() async throws {
            for reentrantClose in [false, true] {
                try await Fixture.run { f in
                    let window = f.makeWindow()
                    let manager = window.workspaceManager
                    let hold = f.holdInitialResolution(manager)
                    try await f.wait(hold.entered)
                    try await f.awaitCatalogProjection(window)

                    var log: [String] = []
                    let reentrantID = UUID()
                    window.applyWindowRestoreEntry(f.restoreEntry(for: Fixture.requestedID, window: window)) {
                        log.append("A")
                        XCTAssertEqual(
                            window.protectedRestoreEntryForTesting?.workspaceID,
                            Fixture.aardvarkID,
                            "Newer acceptance is visible to the displaced completion"
                        )
                        if reentrantClose {
                            window.beginClose()
                        } else {
                            window.applyWindowRestoreEntry(f.restoreEntry(for: reentrantID, window: window)) {
                                log.append("B")
                            }
                        }
                    }
                    window.applyWindowRestoreEntry(f.restoreEntry(for: Fixture.aardvarkID, window: window)) {
                        log.append("C")
                    }

                    XCTAssertEqual(log, ["A", "C"], "Displaced C completes once, by reentrant displacement or close")
                    XCTAssertEqual(window.hasPendingRestoreEntryForTesting, !reentrantClose)
                    XCTAssertEqual(
                        window.protectedRestoreEntryForTesting?.workspaceID,
                        reentrantClose ? Fixture.aardvarkID : reentrantID,
                        "Retirement by close keeps protection; reentrant acceptance replaces it"
                    )

                    await window.joinDomainWorkspaceBridgeForTesting()
                    let teardown = f.startOwned { await window.tearDown() }
                    f.markTornDown(window)
                    hold.gate.release()
                    await teardown.value
                    XCTAssertEqual(log, reentrantClose ? ["A", "C"] : ["A", "C", "B"], "Each acceptance completes exactly once")
                }
            }
        }

        // MARK: 7. Missing Default is created, then activated

        func testMissingDefaultIsCreatedBeforeInitialActivation() async throws {
            try await Fixture.run(seeds: Fixture.userOnlySeeds) { f in
                let window = f.makeWindow()
                let manager = window.workspaceManager
                let gate = f.makeGate()
                let entered = Signal("created System reached publication")
                var gatedID: UUID?
                manager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting { workspaceID in
                    guard gatedID == nil else { return }
                    gatedID = workspaceID
                    entered.fire()
                    await gate.wait()
                }
                let (route, recorder) = f.makeRecordedRoute(for: window)
                let routeStart = recorder.routes.count
                route.evaluateInitialRouteIfNeeded()
                try await f.wait(entered)
                try await f.awaitCatalogProjection(window)
                try await f.acknowledgeRouteConsumption(recorder)
                f.assertNoUnsolicitedSelection(recorder, routeStart: routeStart, context: "while created Default is gated")

                let createdID = try XCTUnwrap(gatedID)
                let canonical = await f.runtime.workspaceStore.snapshot()
                let created = try XCTUnwrap(canonical.workspaces.first { $0.document.workspaceID == createdID })
                XCTAssertTrue(created.document.metadata.isSystemWorkspace, "Canonical System exists before publication")
                for seed in Fixture.userOnlySeeds {
                    let record = canonical.workspaces.first { $0.document.workspaceID == seed.id }
                    XCTAssertEqual(record?.document.metadata.isSystemWorkspace, false)
                }

                gate.release()
                await manager.awaitInitialWorkspaceActivationCompletion()
                await manager.awaitInitialized()
                try await f.acknowledgeRouteConsumption(recorder)
                XCTAssertEqual(manager.activeWorkspaceID, createdID)
                XCTAssertEqual(manager.activeWorkspace?.isSystemWorkspace, true)
                XCTAssertEqual(route.rootRoute, .workspaceEntry)
                f.assertNoUnsolicitedSelection(recorder, routeStart: routeStart, context: "after created Default published")
            }
        }

        // MARK: 8. Non-System namesake is never automatically activated

        func testInitialDefaultUsesSystemIdentityInsteadOfNamesake() async throws {
            // Cover both creation beside a user namesake and reuse of a differently named System.
            for seeds in [
                Fixture.namesakeSeeds,
                Fixture.namesakeSeeds + [Fixture.model(id: Fixture.defaultID, name: "System", isSystem: true)]
            ] {
                try await Fixture.run(seeds: seeds) { f in
                    let window = f.makeWindow()
                    let manager = window.workspaceManager
                    await manager.awaitInitialWorkspaceActivationCompletion()
                    await manager.awaitInitialized()
                    try await f.awaitCatalogProjection(window)
                    let system = try XCTUnwrap(manager.activeWorkspace)
                    XCTAssertTrue(system.isSystemWorkspace)
                    XCTAssertNotEqual(system.id, Fixture.namesakeID)
                    XCTAssertNil(manager.domainWorkspaceAuthorityIssue, "A user namesake is not an authority failure")
                    if seeds.contains(where: \.isSystemWorkspace) {
                        XCTAssertEqual(system.id, Fixture.defaultID, "Reuse System regardless of its display name")
                        XCTAssertEqual(manager.workspaces.count, seeds.count, "Do not create a duplicate System")
                    } else {
                        XCTAssertEqual(manager.workspaces.count, seeds.count + 1, "Create System without replacing the user namesake")
                    }
                    let namesake = try XCTUnwrap(manager.workspace(withID: Fixture.namesakeID))
                    XCTAssertFalse(namesake.isSystemWorkspace, "Namesake is not reclassified")
                    XCTAssertEqual(namesake.name, "Default")
                    let canonical = await f.runtime.workspaceStore.snapshot()
                    XCTAssertEqual(
                        canonical.workspaces.first { $0.document.workspaceID == Fixture.namesakeID }?.document.metadata.isSystemWorkspace,
                        false
                    )
                    let result = await manager.requestWorkspaceSwitch(to: namesake)
                    XCTAssertTrue(result.didSwitch, "Explicit activation of the user namesake stays allowed: \(result)")
                }
            }

            // The bridge's initial catalog candidate uses the same identity rule and supplied order.
            try await Fixture.run(seeds: []) { f in
                let namesake = Fixture.model(id: Fixture.namesakeID, name: "Default")
                let system = Fixture.model(id: Fixture.defaultID, name: "System", isSystem: true)
                for hasSystem in [false, true] {
                    let manager = f.makeManager()
                    manager.workspaces = hasSystem ? [namesake, system] : [namesake]
                    let candidate = try XCTUnwrap(manager.runtimeOwnedDefaultWorkspaceCandidate())
                    XCTAssertTrue(candidate.isSystemWorkspace)
                    XCTAssertNotEqual(candidate.id, namesake.id)
                    XCTAssertEqual(manager.workspaces.count, 2)
                    XCTAssertEqual(manager.workspace(withID: namesake.id), namesake, "User namesake stays unchanged")
                    if hasSystem {
                        XCTAssertEqual(candidate.id, system.id)
                    }
                }
            }

            // A gate-time classification change is caught by the publication recheck.
            try await Fixture.run { f in
                let window = f.makeWindow()
                let manager = window.workspaceManager
                let hold = f.holdPublication(manager, of: Fixture.defaultID)
                try await f.wait(hold.entered)
                try await f.awaitCatalogProjection(window)
                let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == Fixture.defaultID })
                manager.workspaces[index].isSystemWorkspace = false
                hold.gate.release()
                await manager.awaitInitialWorkspaceActivationCompletion()
                await manager.awaitInitialized()
                XCTAssertNil(manager.activeWorkspaceID)
                XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.operation, "initial_default_selection")
            }
        }

        // MARK: 9. Close finishes pending restore without activation

        func testWindowCloseFinishesPendingRestoreWithoutActivation() async throws {
            enum Stage: CaseIterable { case preResolution, prePublication, postPublication }
            for stage in Stage.allCases {
                try await Fixture.run { f in
                    let window = f.makeWindow()
                    let manager = window.workspaceManager
                    let hold: Hold = switch stage {
                    case .preResolution: f.holdInitialResolution(manager)
                    case .prePublication: f.holdPublication(manager, of: Fixture.defaultID)
                    case .postPublication: f.holdHydrationSpawn(manager, of: Fixture.defaultID)
                    }
                    let recovery = f.countRecoveryBegins(manager)
                    let recorder = f.makeRecorder(manager: manager)
                    try await f.wait(hold.entered)
                    try await f.awaitCatalogProjection(window)

                    let entry = f.restoreEntry(for: Fixture.requestedID, window: window)
                    let closeCompleted = Signal("pending restore completed by close")
                    window.applyWindowRestoreEntry(entry) { closeCompleted.fire() }
                    XCTAssertEqual(
                        window.sessionCaptureCandidate().entry?.workspaceID,
                        Fixture.requestedID,
                        "\(stage): nil/System capture keeps the protected entry before close"
                    )

                    await window.joinDomainWorkspaceBridgeForTesting()
                    let teardown = f.startOwned { await window.tearDown() }
                    f.markTornDown(window)
                    try await f.wait(closeCompleted)
                    hold.gate.release()
                    await teardown.value
                    await manager.awaitInitialWorkspaceActivationCompletion()
                    await manager.awaitInitialized()

                    XCTAssertEqual(closeCompleted.count, 1, "\(stage): pending completion fires exactly once")
                    XCTAssertFalse(recorder.emittedIDs.contains(Fixture.requestedID), "\(stage): restore never dispatched")
                    XCTAssertEqual(recovery.count, 0, "\(stage): no recovery during close")
                    XCTAssertFalse(manager.test_isPollTimerActive, "\(stage): timers stay stopped")
                    if stage != .postPublication {
                        XCTAssertNil(manager.activeWorkspaceID, "\(stage): no late initial selection")
                    }
                    XCTAssertEqual(window.protectedRestoreEntryForTesting?.workspaceID, Fixture.requestedID)
                    let candidate = window.sessionCaptureCandidate()
                    XCTAssertEqual(candidate.entry?.workspaceID, Fixture.requestedID, "\(stage): protected entry survives close")
                    let snapshot = WindowSessionSnapshotBuilder.build(
                        version: 4,
                        candidates: [candidate],
                        excludedWindowIDs: [window.windowID]
                    )
                    XCTAssertTrue(snapshot.windows.isEmpty, "\(stage): explicitly closed windows stay excluded")

                    var lateCompletions = 0
                    window.applyWindowRestoreEntry(entry) { lateCompletions += 1 }
                    XCTAssertEqual(lateCompletions, 1, "\(stage): restore ingress after close completes immediately")
                    XCTAssertFalse(window.hasPendingRestoreEntryForTesting)
                }
            }

            // Close while published startup is suspended in recovery: the recovery target is a
            // different System, so only the closing fence prevents a late fallback publication.
            try await Fixture.run(seeds: Fixture.twoSystemSeeds) { f in
                let window = f.makeWindow()
                let manager = window.workspaceManager
                let resolution = f.holdInitialResolution(manager)
                let hydration = f.holdHydrationSpawn(manager, of: Fixture.defaultID)
                let recoveryGate = f.makeGate()
                let recoveryEntered = Signal("startup recovery began")
                manager.setWorkspaceSwitchRecoveryWillBeginHandlerForTesting {
                    recoveryEntered.fire()
                    await recoveryGate.wait()
                }
                let recorder = f.makeRecorder(manager: manager)
                try await f.wait(resolution.entered)
                try await f.awaitCatalogProjection(window)
                // Startup now uses the first System, not the name "Default". Supply Default first
                // for startup, then move the other System first to keep recovery discriminating.
                let defaultIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == Fixture.defaultID })
                let startupSystem = manager.workspaces.remove(at: defaultIndex)
                manager.workspaces.insert(startupSystem, at: 0)
                resolution.gate.release()
                try await f.wait(hydration.entered)
                try await f.awaitCatalogProjection(window)
                XCTAssertEqual(manager.activeWorkspaceID, Fixture.defaultID, "startup published before recovery")
                let otherIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == Fixture.earlierSystemID })
                let recoverySystem = manager.workspaces.remove(at: otherIndex)
                manager.workspaces.insert(recoverySystem, at: 0)

                let entry = f.restoreEntry(for: Fixture.requestedID, window: window)
                let closeCompleted = Signal("pending restore completed by close during recovery")
                window.applyWindowRestoreEntry(entry) { closeCompleted.fire() }

                // A user cancel of the published, uncommitted startup switch requests recovery.
                await manager.cancelCurrentWorkspaceSwitchAndReturnToSystem()
                hydration.gate.release()
                try await f.wait(recoveryEntered)

                await window.joinDomainWorkspaceBridgeForTesting()
                let teardown = f.startOwned { await window.tearDown() }
                f.markTornDown(window)
                try await f.wait(closeCompleted)
                recoveryGate.release()
                await teardown.value
                await manager.awaitInitialWorkspaceActivationCompletion()
                await manager.awaitInitialized()

                XCTAssertEqual(closeCompleted.count, 1)
                XCTAssertFalse(
                    recorder.emittedIDs.contains(Fixture.earlierSystemID),
                    "Recovery must not publish a fallback after close"
                )
                XCTAssertFalse(recorder.emittedIDs.contains(Fixture.requestedID), "Restore never dispatched")
                XCTAssertEqual(manager.activeWorkspaceID, Fixture.defaultID)
                XCTAssertNil(manager.activeWorkspaceSwitch)
                XCTAssertNil(manager.pendingWorkspaceSwitchBlockedNotice, "No blocked notice on close")
                XCTAssertFalse(manager.test_isPollTimerActive)
            }
        }
    }

    // MARK: - Fixture

    @MainActor
    private final class Signal {
        let expectation: XCTestExpectation
        private(set) var count = 0

        init(_ description: String) {
            expectation = XCTestExpectation(description: description)
        }

        func fire() {
            count += 1
            if count == 1 { expectation.fulfill() }
        }
    }

    @MainActor
    private final class Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    @MainActor
    private struct Hold {
        let gate: Gate
        let entered: Signal
    }

    @MainActor
    private final class Counter {
        private(set) var count = 0
        func increment() {
            count += 1
        }
    }

    /// Records publisher arguments (never getter snapshots inside willSet callbacks).
    @MainActor
    private final class SelectionRecorder {
        private(set) var emittedIDs: [UUID?] = []
        private(set) var routes: [AppRootRoute] = []
        private(set) var consumedIDs: [UUID?] = []
        private var consumptionWaiters: [(target: Int, signal: Signal)] = []
        private var cancellables: Set<AnyCancellable> = []

        init(manager: WorkspaceManagerViewModel, route: ContentViewModel?) {
            manager.$activeWorkspaceID
                .sink { [weak self] in self?.emittedIDs.append($0) }
                .store(in: &cancellables)
            guard let route else { return }
            route.$rootRoute
                .sink { [weak self] in self?.routes.append($0) }
                .store(in: &cancellables)
            route.setWorkspaceRouteConsumptionHandlerForTesting { [weak self] id in
                guard let self else { return }
                XCTAssertLessThan(consumedIDs.count, emittedIDs.count, "Route consumed without a matching active-ID emission")
                consumedIDs.append(id)
                let consumedCount = consumedIDs.count
                let ready = consumptionWaiters.filter { consumedCount >= $0.target }
                consumptionWaiters.removeAll { consumedCount >= $0.target }
                ready.forEach { $0.signal.fire() }
            }
        }

        func signalWhenConsumed(through target: Int) -> Signal? {
            guard consumedIDs.count < target else { return nil }
            let signal = Signal("route consumed active-ID emissions through count \(target)")
            consumptionWaiters.append((target, signal))
            return signal
        }

        func detach() {
            cancellables.removeAll()
            consumptionWaiters.removeAll()
        }
    }

    @MainActor
    private final class NewWindowInitialSelectionFixture {
        enum Failure: Error {
            case timedOut(String)
            case isolation(String)
            case seedMismatch(String)
        }

        static let defaultID = UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!
        static let aardvarkID = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!
        static let requestedID = UUID(uuidString: "E0000000-0000-0000-0000-000000000003")!
        static let namesakeID = UUID(uuidString: "B0000000-0000-0000-0000-000000000004")!
        private static let fixedDate = Date(timeIntervalSince1970: 1_780_000_000)

        static func model(id: UUID, name: String, isSystem: Bool = false) -> WorkspaceModel {
            let tabID = UUID(uuidString: "7AB00000-0000-0000-0000-" + String(id.uuidString.suffix(12)))!
            return WorkspaceModel(
                id: id,
                dateModified: fixedDate,
                name: name,
                repoPaths: [],
                lastUsed: fixedDate,
                isSystemWorkspace: isSystem,
                composeTabs: [ComposeTabState(id: tabID, name: "Fixture")],
                activeComposeTabID: tabID
            )
        }

        static var standardSeeds: [WorkspaceModel] {
            [
                model(id: defaultID, name: "Default", isSystem: true),
                model(id: aardvarkID, name: "Aardvark"),
                model(id: requestedID, name: "Z requested")
            ]
        }

        static var standardIDs: Set<UUID> {
            Set(standardSeeds.map(\.id))
        }

        static var defaultFirstSeeds: [WorkspaceModel] {
            [
                model(id: defaultID, name: "Default", isSystem: true),
                model(id: aardvarkID, name: "Mango"),
                model(id: requestedID, name: "Z requested")
            ]
        }

        static let earlierSystemID = UUID(uuidString: "5B000000-0000-0000-0000-000000000006")!

        /// A second System sorting before Default makes startup recovery target a different ID.
        static var twoSystemSeeds: [WorkspaceModel] {
            standardSeeds + [model(id: earlierSystemID, name: "Aaa System", isSystem: true)]
        }

        static var userOnlySeeds: [WorkspaceModel] {
            [model(id: aardvarkID, name: "Aardvark"), model(id: requestedID, name: "Z requested")]
        }

        static var namesakeSeeds: [WorkspaceModel] {
            [model(id: aardvarkID, name: "Aardvark"), model(id: namesakeID, name: "Default"), model(id: requestedID, name: "Z requested")]
        }

        let base: URL
        let storage: URL
        private let seeds: [WorkspaceModel]
        private(set) var runtime: MCPDomainRuntime!
        private let polling = CodexModelPollingService(client: EmptyModelClient())
        private var windows: [WindowState] = []
        private var projectionObserversByWindowID: [Int: DomainWorkspaceProjectionObserver] = [:]
        private var tornDownWindowIDs: Set<Int> = []
        private var routes: [ContentViewModel] = []
        private var recorders: [SelectionRecorder] = []
        private var managers: [WorkspaceManagerViewModel] = []
        private var gates: [Gate] = []
        private var ownedJoins: [() async -> Void] = []
        private var previousStoragePreference: Any?
        private var previousOnboardingPreference: Any?
        private var changedDefaults = false
        private var networkWasRunning = true
        private var publicationSequence: UInt64 = 0
        private var didShutdown = false

        private init(sandbox: URL, seeds: [WorkspaceModel]) {
            base = sandbox.appendingPathComponent("new-window-selection-\(UUID().uuidString)", isDirectory: true)
            storage = base.appendingPathComponent("Workspaces", isDirectory: true)
            self.seeds = seeds
        }

        static func run(
            seeds: [WorkspaceModel]? = nil,
            _ body: (NewWindowInitialSelectionFixture) async throws -> Void
        ) async throws {
            // Must precede settings, singleton, sidecar, key, and store access.
            let sandbox = try WorkspaceTestProcessSandbox.validate()
            let fixture = NewWindowInitialSelectionFixture(sandbox: sandbox, seeds: seeds ?? standardSeeds)
            do {
                try await fixture.setUp(sandbox: sandbox)
                try await body(fixture)
                await fixture.shutdown()
            } catch {
                await fixture.shutdown()
                throw error
            }
        }

        private func setUp(sandbox: URL) async throws {
            guard !GlobalSettingsStore.shared.mcpAutoStart() else { throw Failure.isolation("MCP auto-start enabled") }
            guard AppLaunchConfiguration.current.forcedRootRoute == nil,
                  !AppLaunchConfiguration.current.forcesMCPAutoStart
            else { throw Failure.isolation("forced launch configuration") }
            let agentStorage = await AgentSessionDataService.shared.test_workspaceRootURL().resolvingSymlinksInPath()
            let chatStorage = ChatDataService.test_workspaceRootURL().resolvingSymlinksInPath()
            guard agentStorage.path.hasPrefix(sandbox.path + "/"), chatStorage.path.hasPrefix(sandbox.path + "/") else {
                throw Failure.isolation("sidecar storage outside sandbox")
            }
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            previousStoragePreference = UserDefaults.standard.object(forKey: "GlobalCustomStorageURL")
            previousOnboardingPreference = UserDefaults.standard.object(forKey: "agentOnboardingHasSeen")
            changedDefaults = true
            UserDefaults.standard.set(storage.path, forKey: "GlobalCustomStorageURL")
            // Keep route evaluation off the process-wide onboarding presentation slot.
            UserDefaults.standard.set(true, forKey: "agentOnboardingHasSeen")
            networkWasRunning = await ServerNetworkManager.shared.isRunning()

            for seed in seeds {
                let url = workspaceURL(for: seed)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(seed).write(to: url, options: .atomic)
            }
            try JSONEncoder().encode(seeds.map {
                WorkspaceIndexEntry(
                    id: $0.id, name: $0.name, customStoragePath: nil,
                    isSystemWorkspace: $0.isSystemWorkspace, isHiddenInMenus: $0.isHiddenInMenus
                )
            }).write(to: indexURL, options: .atomic)

            runtime = MCPDomainRuntime(configuration: .init(
                mode: .app, profileIdentifier: "issue1128-\(UUID().uuidString)",
                storageDirectory: base.appendingPathComponent("runtime"), workspaceStorageDirectory: storage,
                eventDirectory: base.appendingPathComponent("events"), temporaryDirectory: base.appendingPathComponent("tmp"),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            // Verify the actual canonical import before any Window exists; otherwise the initial
            // bridge path could exit and turn the regression into a timeout.
            let snapshot = await runtime.workspaceStore.snapshot()
            guard snapshot.isBootstrapped else { throw Failure.seedMismatch("runtime not bootstrapped") }
            let imported = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.document.workspaceID, $0) })
            guard imported.count == seeds.count else { throw Failure.seedMismatch("imported \(imported.count) of \(seeds.count)") }
            for seed in seeds {
                guard let record = imported[seed.id],
                      record.document.metadata.isSystemWorkspace == seed.isSystemWorkspace,
                      record.revisions.dirtyRevision == nil
                else { throw Failure.seedMismatch(seed.name) }
            }
            if seeds.contains(where: { $0.id == Self.aardvarkID }), seeds.contains(where: { $0.id == Self.defaultID }) {
                let order = snapshot.workspaces.map(\.document.workspaceID)
                let expectsAardvarkFirst = seeds.first { $0.id == Self.aardvarkID }?.name == "Aardvark"
                guard (order.firstIndex(of: Self.aardvarkID)! < order.firstIndex(of: Self.defaultID)!) == expectsAardvarkFirst else {
                    throw Failure.seedMismatch("unexpected runtime catalog order")
                }
            }
        }

        private var indexURL: URL {
            storage.appendingPathComponent("workspacesIndex.json")
        }

        func workspaceURL(for workspace: WorkspaceModel) -> URL {
            storage.appendingPathComponent(DomainWorkspaceStoragePath.directoryName(name: workspace.name, id: workspace.id))
                .appendingPathComponent("workspace.json")
        }

        // MARK: Construction

        /// Production composition with its sole bridge; no NSWindow, registration, or server.
        func makeWindow() -> WindowState {
            let window = WindowState(
                contextBuilderProviderFactory: { _, _, _, _ in
                    UnsupportedHeadlessAgentProvider(reason: "NewWindowInitialSelection fixture never streams")
                },
                domainRuntime: runtime,
                keyManager: KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())),
                codexModelPollingService: polling,
                loadStoredAPISettingsDataOnInit: false
            )
            guard let bridge = window.domainWorkspacePresentationBridgeForTesting else {
                preconditionFailure("Window fixture requires a domain workspace presentation bridge")
            }
            projectionObserversByWindowID[window.windowID] = DomainWorkspaceProjectionObserver(bridge: bridge)
            windows.append(window)
            return window
        }

        func projectionObserver(for window: WindowState) -> DomainWorkspaceProjectionObserver {
            guard let observer = projectionObserversByWindowID[window.windowID] else {
                preconditionFailure("Window fixture is missing its projection observer")
            }
            return observer
        }

        func projectionState(
            for window: WindowState
        ) -> DomainWorkspacePresentationBridge.ProjectionObservationState {
            guard let bridge = window.domainWorkspacePresentationBridgeForTesting else {
                preconditionFailure("Window fixture is missing its projection bridge")
            }
            return bridge.projectionObservationStateForTesting
        }

        /// Constructs the route and installs its sole recorder synchronously, before any test yield
        /// can let the route's initial RunLoop.main delivery run.
        func makeRecordedRoute(for window: WindowState) -> (route: ContentViewModel, recorder: SelectionRecorder) {
            let route = ContentViewModel(state: window)
            let recorder = SelectionRecorder(manager: window.workspaceManager, route: route)
            routes.append(route)
            recorders.append(recorder)
            return (route, recorder)
        }

        func makeRecorder(manager: WorkspaceManagerViewModel) -> SelectionRecorder {
            let recorder = SelectionRecorder(manager: manager, route: nil)
            recorders.append(recorder)
            return recorder
        }

        /// Manager-level fixture with startup disabled and no competing live bridge.
        func makeManager(
            withAuthority: Bool = true,
            coordinator: WorkspaceActivityCoordinator? = nil
        ) -> WorkspaceManagerViewModel {
            let keys = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
            let files = WorkspaceFilesViewModel()
            let api = APISettingsViewModel(aiQueriesService: AIQueriesService(keyManager: keys), keyManager: keys, loadStoredDataOnInit: false)
            let windowID = -1128 - managers.count
            let prompt = PromptViewModel(
                fileManager: files, apiSettingsViewModel: api, windowID: windowID,
                settingsManager: WindowSettingsManager(windowID: windowID)
            )
            let manager = WorkspaceManagerViewModel(
                fileManager: files,
                promptViewModel: prompt,
                domainWorkspaceAuthorityClient: withAuthority
                    ? DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: windowID)
                    : nil,
                workspaceActivityCoordinator: coordinator ?? WorkspaceActivityCoordinator(),
                performInitialWorkspaceActivation: false
            )
            managers.append(manager)
            return manager
        }

        func makeGate() -> Gate {
            let gate = Gate()
            gates.append(gate)
            return gate
        }

        func startOwned<Value>(_ operation: @escaping @MainActor () async -> Value) -> Task<Value, Never> {
            let task = Task { await operation() }
            ownedJoins.append { _ = await task.value }
            return task
        }

        func markTornDown(_ window: WindowState) {
            tornDownWindowIDs.insert(window.windowID)
        }

        // MARK: Hooks

        func holdInitialResolution(_ manager: WorkspaceManagerViewModel) -> Hold {
            let hold = Hold(gate: makeGate(), entered: Signal("startup reached Default resolution"))
            manager.setInitialDefaultResolutionHandlerForTesting {
                hold.entered.fire()
                await hold.gate.wait()
                return .proceed
            }
            return hold
        }

        func holdPublication(_ manager: WorkspaceManagerViewModel, of workspaceID: UUID) -> Hold {
            let hold = Hold(gate: makeGate(), entered: Signal("startup reached publication"))
            manager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting { id in
                guard id == workspaceID, hold.entered.count == 0 else { return }
                hold.entered.fire()
                await hold.gate.wait()
            }
            return hold
        }

        func holdHydrationSpawn(_ manager: WorkspaceManagerViewModel, of workspaceID: UUID) -> Hold {
            let hold = Hold(gate: makeGate(), entered: Signal("published startup reached hydration spawn"))
            manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { id in
                guard id == workspaceID, hold.entered.count == 0 else { return }
                hold.entered.fire()
                await hold.gate.wait()
            }
            return hold
        }

        func observeSupersession(_ manager: WorkspaceManagerViewModel) -> Signal {
            let signal = Signal("explicit intent superseded startup")
            manager.setInitialDefaultActivationDidSupersedeHandlerForTesting { signal.fire() }
            return signal
        }

        func countRecoveryBegins(_ manager: WorkspaceManagerViewModel) -> Counter {
            let counter = Counter()
            manager.setWorkspaceSwitchRecoveryWillBeginHandlerForTesting { counter.increment() }
            return counter
        }

        // MARK: Observation

        /// A deadline detects failed progress; it never establishes ordering.
        func wait(_ signal: Signal, timeout: TimeInterval = 15) async throws {
            guard await XCTWaiter.fulfillment(of: [signal.expectation], timeout: timeout) == .completed else {
                releaseAllGates()
                throw Failure.timedOut(signal.expectation.expectationDescription)
            }
        }

        /// Acknowledges that a bridge waiter is registered (bounded; no sleeps).
        func awaitPendingProjectionWaiter(_ observer: DomainWorkspaceProjectionObserver) async throws {
            for _ in 0 ..< 10000 {
                if observer.pendingWaiterCount > 0 { return }
                await Task.yield()
            }
            releaseAllGates()
            throw Failure.timedOut("projection waiter registration")
        }

        /// Waits for a real bridge application through the runtime's current publication.
        func awaitCatalogProjection(_ window: WindowState) async throws {
            let catalog = await runtime.workspaceStore.snapshot()
            let checkpoint = await projectionObserver(for: window).waitForProjection(
                afterGeneration: 0,
                through: catalog.publicationSequence,
                timeout: .seconds(15)
            )
            guard checkpoint != nil else {
                releaseAllGates()
                throw Failure.timedOut("bridge projection through \(catalog.publicationSequence)")
            }
        }

        /// Captures the real active-ID emission count, then waits until the route subscription has
        /// consumed every emission through that fixed target.
        func acknowledgeRouteConsumption(_ recorder: SelectionRecorder) async throws {
            let target = recorder.emittedIDs.count
            if let signal = recorder.signalWhenConsumed(through: target) {
                try await wait(signal)
            }
            XCTAssertGreaterThanOrEqual(recorder.consumedIDs.count, target)
        }

        /// WindowState's active-ID observer also schedules on RunLoop.main. Enqueueing directly on
        /// that scheduler acknowledges all observer work scheduled before this call without adding
        /// another route model or relying on a final-state-only wait.
        func acknowledgeWindowObservers(_: WindowState) async throws {
            let acknowledged = Signal("window active-ID observers drained")
            RunLoop.main.schedule { acknowledged.fire() }
            try await wait(acknowledged)
        }

        @discardableResult
        func assertNoUnsolicitedSelection(
            _ recorder: SelectionRecorder,
            routeStart: Int,
            context: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) -> Bool {
            let nonSystemIDs = Set(seeds.filter { !$0.isSystemWorkspace }.map(\.id))
            let emitted = recorder.emittedIDs.compactMap(\.self).filter { nonSystemIDs.contains($0) }
            XCTAssertTrue(emitted.isEmpty, "\(context): unsolicited non-System emission \(emitted)", file: file, line: line)
            let consumed = recorder.consumedIDs.compactMap(\.self).filter { nonSystemIDs.contains($0) }
            XCTAssertTrue(consumed.isEmpty, "\(context): route consumed non-System \(consumed)", file: file, line: line)
            let routes = recorder.routes.dropFirst(routeStart)
            let publishedMain = routes.contains(.main)
            XCTAssertFalse(publishedMain, "\(context): post-chooser .main publication \(Array(routes))", file: file, line: line)
            return emitted.isEmpty && consumed.isEmpty && !publishedMain
        }

        // MARK: Canonical updates

        /// Commits a new canonical record through a distinct authority window (no self-echo bypass)
        /// and waits for the window's bridge to apply it.
        @discardableResult
        func commitWorkspace(named name: String, isSystem: Bool = false, window: WindowState) async throws -> WorkspaceModel {
            let model = Self.model(id: UUID(), name: name, isSystem: isSystem)
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -11280)
            _ = try await client.create(model, fileURL: workspaceURL(for: model), operationID: UUID())
            try await awaitCatalogProjection(window)
            return model
        }

        func restoreEntry(for workspaceID: UUID, window: WindowState) -> WindowSessionEntry {
            let seed = seeds.first { $0.id == workspaceID }
            return WindowSessionEntry(
                windowKind: window.kind,
                workspaceID: workspaceID,
                workspaceName: seed?.name,
                isSystemWorkspace: seed?.isSystemWorkspace ?? false,
                isEphemeral: false,
                primaryRepoPath: nil,
                lastFocused: true,
                workspaceInstanceNumber: nil
            )
        }

        private func nextSequence() -> UInt64 {
            publicationSequence += 1
            return publicationSequence
        }

        private func revisions(_ models: [WorkspaceModel], dirty: Set<UUID>, sequence: UInt64) -> [UUID: DomainRevisionState] {
            Dictionary(uniqueKeysWithValues: models.map { model in
                (model.id, DomainRevisionState(
                    workingRevision: sequence,
                    savedRevision: dirty.contains(model.id) ? sequence - 1 : sequence,
                    dirtyRevision: dirty.contains(model.id) ? sequence : nil
                ))
            })
        }

        /// Production full projection with explicit revision inputs and no file-URL mappings.
        func project(
            _ manager: WorkspaceManagerViewModel,
            _ models: [WorkspaceModel],
            dirty: Set<UUID> = [],
            preferred: UUID? = nil
        ) {
            let sequence = nextSequence()
            manager.applyDomainWorkspaceProjection(
                models,
                fileURLsByWorkspaceID: [:],
                revisionsByWorkspaceID: revisions(models, dirty: dirty, sequence: sequence),
                digestsByWorkspaceID: Dictionary(uniqueKeysWithValues: models.map { ($0.id, "digest-\($0.id)") }),
                healthByWorkspaceID: Dictionary(uniqueKeysWithValues: models.map { ($0.id, DomainAuthorityHealth.writable) }),
                catalogRevision: sequence,
                preferredActiveWorkspaceID: preferred,
                publicationSequence: sequence
            )
        }

        /// Metadata-only projection with unchanged digests and explicit canonical System evidence.
        func projectMetadata(
            _ manager: WorkspaceManagerViewModel,
            _ models: [WorkspaceModel],
            dirty: Set<UUID> = [],
            canonicalSystemIDs: Set<UUID>
        ) {
            let sequence = nextSequence()
            let revisions = revisions(models, dirty: dirty, sequence: sequence)
            let digests = Dictionary(uniqueKeysWithValues: models.map { ($0.id, "digest-\($0.id)") })
            let health = Dictionary(uniqueKeysWithValues: models.map { ($0.id, DomainAuthorityHealth.writable) })
            manager.applyDomainAuthorityMetadataProjection(
                revisionsByWorkspaceID: revisions, digestsByWorkspaceID: digests, healthByWorkspaceID: health,
                catalogRevision: sequence, publicationSequence: sequence,
                canonicalSystemWorkspaceIDs: canonicalSystemIDs
            )
        }

        // MARK: Cleanup

        func releaseAllGates() {
            gates.forEach { $0.release() }
        }

        /// Joined teardown on every exit: gates → hooks → owned work → observers → bridge →
        /// window teardown and drains → polling/runtime → writers → defaults → storage.
        func shutdown() async {
            guard !didShutdown else { return }
            didShutdown = true
            // Close before releasing startup so a failure path cannot dispatch late restore work.
            for window in windows where !tornDownWindowIDs.contains(window.windowID) {
                window.beginClose()
            }
            releaseAllGates()
            for manager in windows.map(\.workspaceManager) + managers {
                manager.setInitialDefaultResolutionHandlerForTesting(nil)
                manager.setInitialDefaultActivationDidSupersedeHandlerForTesting(nil)
                manager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting(nil)
                manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting(nil)
                manager.setWorkspaceSwitchRecoveryWillBeginHandlerForTesting(nil)
                for id in manager.pendingConsolidatedRestoreIDs {
                    manager.setActiveConsolidatedRestoreProtectionForTesting(id, isProtected: false)
                }
            }
            for join in ownedJoins {
                await join()
            }
            ownedJoins.removeAll()
            for window in windows {
                await window.workspaceManager.awaitInitialWorkspaceActivationCompletion()
                await window.workspaceManager.awaitInitialized()
            }
            recorders.forEach { $0.detach() }
            recorders.removeAll()
            for route in routes {
                route.setWorkspaceRouteConsumptionHandlerForTesting(nil)
            }
            routes.removeAll()
            for window in windows {
                let manager = window.workspaceManager
                await window.joinDomainWorkspaceBridgeForTesting()
                if !tornDownWindowIDs.contains(window.windowID) {
                    await window.tearDown()
                }
                await manager.waitUntilPostSwitchGitDataLoadComplete()
                await manager.debugDrainScheduledSaves()
                for workspace in manager.workspaces where !workspace.isEphemeral {
                    await manager.debugAwaitWorkingDocumentCommitToDomainAuthority(workspaceID: workspace.id)
                }
                for root in await window.workspaceFilesViewModel.workspaceFileContextStore.roots() {
                    await window.workspaceFilesViewModel.unloadRootFolderPath(root.standardizedFullPath)
                }
                let remaining = await window.workspaceFilesViewModel.workspaceFileContextStore.roots()
                XCTAssertTrue(remaining.isEmpty, "Window roots must be unloaded")
            }
            windows.removeAll()
            projectionObserversByWindowID.removeAll()
            for manager in managers {
                await manager.debugDrainScheduledSaves()
                manager.prepareForWindowClose()
                await manager.awaitRootReconciliationShutdown()
            }
            managers.removeAll()
            await polling.shutdown()
            if !networkWasRunning { await ServerNetworkManager.shared.stop() }
            if let runtime {
                let result = await runtime.shutdown()
                XCTAssertEqual(result.finalLifecycle, .stopped)
            }
            runtime = nil
            for seed in seeds {
                await WorkspaceDiskWriterComposition.processWriter.flush(url: workspaceURL(for: seed))
            }
            await WorkspaceDiskWriterComposition.processWriter.flush(url: indexURL)
            if changedDefaults {
                restore(previousStoragePreference, forKey: "GlobalCustomStorageURL")
                restore(previousOnboardingPreference, forKey: "agentOnboardingHasSeen")
            }
            do {
                if FileManager.default.fileExists(atPath: base.path) {
                    try FileManager.default.removeItem(at: base)
                }
            } catch {
                XCTFail("Fixture directory cleanup failed: \(error)")
            }
        }

        private func restore(_ value: Any?, forKey key: String) {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        private actor EmptyModelClient: CodexModelListingClient {
            func listModels(limit: Int) async throws -> [CodexAppServerClient.RemoteModel] {
                []
            }

            func stop() async {}
        }
    }
#endif

// MARK: - WindowRestoreLifetime contract

/// Contract tests for `WindowRestoreLifetime`: execution and protection are independent
/// lifetimes, protection is fenced by acceptance order, and capture follows the documented
/// precedence. Window/manager journeys live in `NewWindowInitialSelectionTests` above.
final class WindowRestoreLifetimeTests: XCTestCase {
    private func entry(_ id: UUID = UUID(), isSystem: Bool = false) -> WindowSessionEntry {
        WindowSessionEntry(
            windowKind: .standard,
            workspaceID: id,
            workspaceName: nil,
            isSystemWorkspace: isSystem,
            isEphemeral: false,
            primaryRepoPath: nil,
            lastFocused: false,
            workspaceInstanceNumber: nil
        )
    }

    private func preservedID(_ disposition: WindowRestoreLifetime.CaptureDisposition) -> UUID? {
        if case let .preserve(entry) = disposition { return entry.workspaceID }
        return nil
    }

    private func isOmit(_ disposition: WindowRestoreLifetime.CaptureDisposition) -> Bool {
        if case .omit = disposition { return true }
        return false
    }

    private func isCaptureLive(_ disposition: WindowRestoreLifetime.CaptureDisposition) -> Bool {
        if case .captureLive = disposition { return true }
        return false
    }

    func testRetirementEndsExecutionButKeepsProtection() {
        var lifetime = WindowRestoreLifetime()
        let requested = entry()
        var completions = 0
        XCTAssertNil(lifetime.accept(requested) { completions += 1 })

        let retired = lifetime.retirePending()
        retired?()
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(lifetime.hasPendingEntry)
        XCTAssertEqual(lifetime.protectedEntry?.workspaceID, requested.workspaceID, "Explicit intent wins over dispatch only")
        XCTAssertNil(lifetime.retirePending(), "Execution ends exactly once")
        XCTAssertNil(lifetime.takePendingForDispatch())
    }

    func testDispatchOwnsItsCompletionAcrossNewerAcceptance() throws {
        var lifetime = WindowRestoreLifetime()
        var log: [String] = []
        _ = lifetime.accept(entry()) { log.append("first") }
        let dispatch = try XCTUnwrap(lifetime.takePendingForDispatch())
        XCTAssertNil(lifetime.accept(entry()) { log.append("second") }, "A dispatched completion is never displaced")
        dispatch.completion?()
        let retired = lifetime.retirePending()
        retired?()
        XCTAssertEqual(log, ["first", "second"])
    }

    func testNewerAcceptanceReturnsDisplacedCompletionAndReplacesProtection() {
        var lifetime = WindowRestoreLifetime()
        var log: [String] = []
        _ = lifetime.accept(entry()) { log.append("displaced") }
        let newer = entry()
        let displaced = lifetime.accept(newer) { log.append("newer") }
        XCTAssertEqual(lifetime.protectedEntry?.workspaceID, newer.workspaceID, "Installed before the caller runs displaced")
        displaced?()
        XCTAssertEqual(log, ["displaced"])

        _ = lifetime.accept(entry(isSystem: true), completion: nil)
        XCTAssertNil(lifetime.protectedEntry, "A System-intended acceptance needs no protection")
    }

    func testSelectionPublishedBeforeAcceptanceCannotReleaseIt() {
        var lifetime = WindowRestoreLifetime()
        let staleWitness = lifetime.selectionWitness
        let requested = entry()
        _ = lifetime.accept(requested, completion: nil)

        lifetime.noteRealSelectionPublished(staleWitness)
        XCTAssertEqual(lifetime.protectedEntry?.workspaceID, requested.workspaceID)

        // Same target accepted twice: workspace identity is not acceptance identity.
        let witnessAfterFirst = lifetime.selectionWitness
        _ = lifetime.accept(requested, completion: nil)
        lifetime.noteRealSelectionPublished(witnessAfterFirst)
        XCTAssertNotNil(lifetime.protectedEntry, "A re-acceptance of the same target is still newer")

        lifetime.noteRealSelectionPublished(lifetime.selectionWitness)
        XCTAssertNil(lifetime.protectedEntry, "A selection published after acceptance releases it")
    }

    func testSystemResolutionReleasesOnlyItsOwnAcceptance() throws {
        var lifetime = WindowRestoreLifetime()
        _ = lifetime.accept(entry(), completion: nil)
        let dispatch = try XCTUnwrap(lifetime.takePendingForDispatch())
        let newer = entry()
        _ = lifetime.accept(newer, completion: nil)

        lifetime.releaseProtection(forDispatchedAcceptance: dispatch.acceptanceSequence)
        XCTAssertEqual(lifetime.protectedEntry?.workspaceID, newer.workspaceID)

        let newerDispatch = try XCTUnwrap(lifetime.takePendingForDispatch())
        lifetime.releaseProtection(forDispatchedAcceptance: newerDispatch.acceptanceSequence)
        XCTAssertNil(lifetime.protectedEntry)
    }

    func testCaptureDispositionPrecedence() {
        var lifetime = WindowRestoreLifetime()
        XCTAssertTrue(isOmit(lifetime.captureDisposition(for: .none)), "No selection, no protection: omit")
        XCTAssertTrue(isOmit(lifetime.captureDisposition(for: .ephemeral)))
        XCTAssertTrue(isCaptureLive(lifetime.captureDisposition(for: .system)))
        XCTAssertTrue(isCaptureLive(lifetime.captureDisposition(for: .persistent)))

        let requested = entry()
        _ = lifetime.accept(requested, completion: nil)
        XCTAssertEqual(preservedID(lifetime.captureDisposition(for: .none)), requested.workspaceID)
        XCTAssertTrue(isOmit(lifetime.captureDisposition(for: .ephemeral)), "Ephemeral exclusion wins over protection")
        XCTAssertEqual(preservedID(lifetime.captureDisposition(for: .system)), requested.workspaceID)
        XCTAssertTrue(
            isCaptureLive(lifetime.captureDisposition(for: .persistent)),
            "Protection never overrides a real live selection"
        )
    }
}
