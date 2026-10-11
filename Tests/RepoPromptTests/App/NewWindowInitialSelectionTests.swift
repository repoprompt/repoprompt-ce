import AppKit
import Combine
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptFileSystem
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import SwiftUI
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
                try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                    try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                    try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                    try await f.awaitCaughtUpWithCatalogBaseline(window)

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
                try await f.awaitCaughtUpWithCatalogBaseline(window)

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
                    try await f.awaitCaughtUpWithCatalogBaseline(window)

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
                try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                    try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                try await f.awaitCaughtUpWithCatalogBaseline(window)
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
                    try await f.awaitCaughtUpWithCatalogBaseline(window)

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
                try await f.awaitCaughtUpWithCatalogBaseline(window)
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

        // MARK: - Fixture gate cancellation

        func testGateCancellationLeavesOtherWaitersHeldUntilRelease() async {
            let gate = Gate()
            let entered = (0 ..< 3).map { Signal("gate waiter \($0) registered") }
            let completed = (0 ..< 3).map { Signal("gate waiter \($0) completed") }
            let tasks = (0 ..< 3).map { index in
                Task {
                    await gate.wait(onWaiting: { entered[index].fire() })
                    completed[index].fire()
                }
            }
            let registration = await XCTWaiter.fulfillment(of: entered.map(\.expectation), timeout: 15)
            XCTAssertEqual(registration, .completed)
            tasks[0].cancel()
            let cancellation = await XCTWaiter.fulfillment(of: [completed[0].expectation], timeout: 15)
            XCTAssertEqual(cancellation, .completed)
            XCTAssertEqual(completed.map(\.count), [1, 0, 0], "Cancellation must only resume its own waiter")
            gate.release()
            let released = await XCTWaiter.fulfillment(of: completed.dropFirst().map(\.expectation), timeout: 15)
            XCTAssertEqual(released, .completed, "Release must resume every remaining waiter")
            for task in tasks {
                await task.value
            }
            XCTAssertEqual(completed.map(\.count), [1, 1, 1])
        }

        func testGateReleaseCancellationRaceCompletesExactlyOnce() async {
            // Both actor orderings also exercise a queued cancellation handler arriving after release.
            for cancelFirst in [true, false] {
                let gate = Gate()
                let entered = Signal("race waiter registered, cancelFirst=\(cancelFirst)")
                let completed = Signal("race waiter completed, cancelFirst=\(cancelFirst)")
                let task = Task {
                    await gate.wait(onWaiting: { entered.fire() })
                    completed.fire()
                }
                let registration = await XCTWaiter.fulfillment(of: [entered.expectation], timeout: 15)
                XCTAssertEqual(registration, .completed)
                if cancelFirst {
                    task.cancel()
                    gate.release()
                } else {
                    gate.release()
                    task.cancel()
                }
                task.cancel()
                gate.release()
                let completion = await XCTWaiter.fulfillment(of: [completed.expectation], timeout: 15)
                XCTAssertEqual(completion, .completed, "cancelFirst=\(cancelFirst)")
                gate.release()
                await task.value
                XCTAssertEqual(completed.count, 1, "cancelFirst=\(cancelFirst)")
            }
        }

        func testGateRepeatedReleaseKeepsFutureWaitersUnblocked() async {
            let gate = Gate()
            gate.release()
            gate.release()
            let entered = Counter()
            let completed = Signal("wait after repeated release completed")
            let task = Task {
                await gate.wait(onWaiting: { entered.increment() })
                completed.fire()
            }
            let completion = await XCTWaiter.fulfillment(of: [completed.expectation], timeout: 15)
            XCTAssertEqual(completion, .completed)
            gate.release()
            await task.value
            XCTAssertEqual(entered.count, 0, "An open gate must not register new waiters")
            XCTAssertEqual(completed.count, 1)
        }

        func testGateCancellationBeforeRegistrationDoesNotEnterWait() async {
            let gate = Gate()
            let entered = Counter()
            let completed = Signal("pre-cancelled gate waiter completed")
            let task = Task {
                await gate.wait(onWaiting: { entered.increment() })
                completed.fire()
            }
            // MainActor cannot run the task body until this method yields.
            task.cancel()
            let cancellation = await XCTWaiter.fulfillment(of: [completed.expectation], timeout: 15)
            XCTAssertEqual(cancellation, .completed)
            XCTAssertEqual(entered.count, 0, "A pre-cancelled task must not register a waiter")
            gate.release()
            await task.value
            XCTAssertEqual(completed.count, 1)
        }

        // MARK: #1142 Actual chooser consumption (warm first application, not cold bootstrap)

        func testUnsuccessfulDefaultRereadAcceptsTrueEmptyAndRemovesLegacyGhostAndCandidate() async throws {
            let ghost = Fixture.model(id: Fixture.requestedID, name: "Deleted sole ghost")
            try await Fixture.run(seeds: [ghost]) { f in
                try await f.deleteAndRestoreLegacyGhost(ghost)
                let before = await f.runtime.workspaceStore.snapshot()
                XCTAssertEqual(before.health, .writable)
                XCTAssertTrue(before.workspaces.isEmpty)
                XCTAssertTrue(before.unavailableWorkspaceIDs.isEmpty)
                let window = f.makeWindow()
                let manager = window.workspaceManager
                let hold = f.holdInitialResolution(manager)
                let chooser = f.makeChooserRecorder(manager: manager)
                let bridge = try XCTUnwrap(window.domainWorkspacePresentationBridgeForTesting)
                XCTAssertNotNil(manager.workspace(withID: ghost.id))
                let failure = DomainCommandOutcome(
                    operationID: UUID(), disposition: .failed, before: nil, after: nil,
                    catalogRevision: before.catalogRevision, resultingDigest: nil
                )
                var candidateID: UUID?
                XCTAssertTrue(bridge.setInitialDefaultCreateOutcomeForTesting(failure) { candidate in
                    candidateID = candidate.id
                    XCTAssertTrue(candidate.isSystemWorkspace)
                    XCTAssertNotNil(manager.workspace(withID: candidate.id), "Proposed candidate actually entered the local array")
                })
                for disposition in [DomainCommandDisposition.applied, .unchanged, .deduplicated] {
                    XCTAssertFalse(bridge.setInitialDefaultCreateOutcomeForTesting(.init(
                        operationID: UUID(), disposition: disposition, before: nil, after: nil,
                        catalogRevision: before.catalogRevision, resultingDigest: nil
                    )), "Successful overrides must be rejected without replacing the unsuccessful override")
                }
                await window.joinDomainWorkspaceBridgeForTesting()
                window.restartDomainWorkspaceProjectionForTesting()
                let checkpoint = try await f.awaitCatalogProjection(window)
                let receipt = try XCTUnwrap(checkpoint.catalogReceipt)
                let reread = await f.runtime.workspaceStore.snapshot()
                XCTAssertEqual(reread.health, .writable)
                XCTAssertTrue(reread.workspaces.isEmpty)
                XCTAssertTrue(reread.unavailableWorkspaceIDs.isEmpty)
                XCTAssertEqual(reread.catalogRevision, before.catalogRevision, "Override must not mutate authority")
                XCTAssertEqual(reread.publicationSequence, before.publicationSequence)
                XCTAssertEqual(receipt.kind, .full)
                XCTAssertEqual(receipt.completeness, .complete)
                XCTAssertEqual(receipt.catalogRevision, reread.catalogRevision)
                XCTAssertEqual(receipt.publicationSequence, reread.publicationSequence)
                let proposed = try XCTUnwrap(candidateID)
                XCTAssertNil(manager.workspace(withID: proposed), "Unowned proposed Default is not a pending creation")
                XCTAssertNil(manager.workspace(withID: ghost.id))
                XCTAssertTrue(manager.workspaces.isEmpty)
                guard case let .ready(catalog, refresh) = try XCTUnwrap(chooser.emitted.last) else {
                    return XCTFail("True empty must emit ready, not catalog failure")
                }
                XCTAssertTrue(catalog.workspaces.isEmpty)
                XCTAssertEqual(refresh, .current)
                for query in [WorkspaceChooserQuery.compact(maxRecent: 5), .expanded(collection: .saved, searchText: "")] {
                    let value = try chooser.consume(query)
                    XCTAssertEqual(value.kind, .ready)
                    XCTAssertEqual(value.orderedIDs, [])
                    XCTAssertNil(value.failureID)
                    XCTAssertEqual(value.source, .authority(.init(
                        publicationSequence: receipt.publicationSequence, catalogRevision: receipt.catalogRevision,
                        reconciliationGeneration: receipt.reconciliationGeneration, isComplete: true
                    )))
                }
                XCTAssertFalse(chooser.emitted.contains {
                    if case let .ready(catalog, _) = $0 { return !catalog.workspaces.isEmpty }
                    return false
                })
                // Startup Default resolution is a separate owner and remains held throughout projection.
                try await f.wait(hold.entered)
                XCTAssertNil(manager.activeWorkspaceID)
            }
        }

        func testSuccessfulBridgeDefaultProducesSystemOnlyAuthorityAndVisibleEmptyChooser() async throws {
            try await Fixture.run(seeds: []) { f in
                let before = await f.runtime.workspaceStore.snapshot()
                XCTAssertEqual(before.health, .writable)
                XCTAssertTrue(before.workspaces.isEmpty)
                XCTAssertTrue(before.unavailableWorkspaceIDs.isEmpty)
                let window = f.makeWindow()
                let manager = window.workspaceManager
                let hold = f.holdInitialResolution(manager)
                let chooser = f.makeChooserRecorder(manager: manager)
                await window.joinDomainWorkspaceBridgeForTesting()
                window.restartDomainWorkspaceProjectionForTesting()
                let checkpoint = try await f.awaitCatalogProjection(window)
                let receipt = try XCTUnwrap(checkpoint.catalogReceipt)
                let reread = await f.runtime.workspaceStore.snapshot()
                XCTAssertEqual(reread.health, .writable)
                XCTAssertTrue(reread.unavailableWorkspaceIDs.isEmpty)
                XCTAssertEqual(reread.workspaces.count, 1, "Visible empty is NOT true empty authority")
                let system = try XCTUnwrap(reread.workspaces.first)
                XCTAssertTrue(system.document.metadata.isSystemWorkspace)
                XCTAssertEqual(system.document.metadata.name, "Default")
                XCTAssertGreaterThan(reread.catalogRevision, before.catalogRevision, "Default must be a real successful mutation")
                XCTAssertEqual(receipt.kind, .full)
                XCTAssertEqual(receipt.completeness, .complete)
                XCTAssertEqual(receipt.catalogRevision, reread.catalogRevision)
                XCTAssertEqual(receipt.publicationSequence, reread.publicationSequence)
                XCTAssertEqual(manager.workspaces.map(\.id), [system.document.workspaceID])
                guard case let .ready(catalog, refresh) = try XCTUnwrap(chooser.emitted.last) else {
                    return XCTFail("System-only authority must emit ready")
                }
                XCTAssertEqual(catalog.workspaces.map(\.id), [system.document.workspaceID])
                XCTAssertEqual(refresh, .current)
                for query in [WorkspaceChooserQuery.compact(maxRecent: 5), .expanded(collection: .saved, searchText: "")] {
                    let value = try chooser.consume(query)
                    XCTAssertEqual(value.kind, .ready)
                    XCTAssertEqual(value.orderedIDs, [])
                    XCTAssertNil(value.failureID)
                    XCTAssertEqual(value.source, .authority(.init(
                        publicationSequence: receipt.publicationSequence, catalogRevision: receipt.catalogRevision,
                        reconciliationGeneration: receipt.reconciliationGeneration, isComplete: true
                    )))
                }
                try await f.wait(hold.entered)
                XCTAssertNil(manager.activeWorkspaceID, "Separate startup owner is still held")
            }
        }

        // MARK: Genuine cold bootstrap (not warm Bridge first application)

        func testColdBootstrapKeepsRealWindowChoosersLoadingUntilSharedPersistenceCompletes() async throws {
            var checkedSeedBytes = false
            try await Fixture.run(deferredStart: true, beforeRuntimeStart: { f in
                XCTAssertEqual(try f.legacyIDs(), Fixture.standardIDs)
                let bytes = try Data(contentsOf: f.workspaceURL(for: Fixture.standardSeeds[1]))
                XCTAssertEqual(try JSONDecoder().decode(WorkspaceModel.self, from: bytes).id, Fixture.aardvarkID)
                checkedSeedBytes = true
            }) { f in
                XCTAssertTrue(checkedSeedBytes)
                let cold = await f.holdColdBootstrap()
                let windows = [f.makeWindow(), f.makeWindow()]
                let choosers = windows.map { f.makeChooserRecorder(manager: $0.workspaceManager) }
                let holds = windows.map { f.holdInitialResolution($0.workspaceManager) }
                f.startRuntime()
                guard await XCTWaiter.fulfillment(of: [cold.entered], timeout: 15) == .completed else {
                    throw Fixture.Failure.timedOut("cold bootstrap entry")
                }
                let heldEntries = await cold.gate.entries
                XCTAssertEqual(heldEntries, 1)
                for (window, chooser) in zip(windows, choosers) {
                    XCTAssertEqual(
                        Set(window.workspaceManager.workspaces.map(\.id)),
                        Fixture.standardIDs,
                        "Constructor rows must really exist while authority is held"
                    )
                    XCTAssertNil(f.projectionState(for: window).catalogCheckpoint)
                    XCTAssertEqual(chooser.emitted, [.loading])
                    XCTAssertTrue(window.workspaceManager.workspacesForMenu().isEmpty, "picker hides unaccepted constructor rows")
                    for query in [WorkspaceChooserQuery.compact(maxRecent: 5), .expanded(collection: .saved, searchText: "")] {
                        let value = try chooser.consume(query)
                        XCTAssertEqual(value.kind, .loading)
                        XCTAssertEqual(value.orderedIDs, [])
                        XCTAssertNil(value.source)
                        XCTAssertNil(value.failureID)
                    }
                }
                // Never snapshot before this release: snapshot is itself a bootstrap caller.
                await cold.gate.release()
                try await f.joinRuntimeStartAndValidateSeeds()
                for (window, chooser) in zip(windows, choosers) {
                    let checkpoint = try await f.awaitCatalogProjection(window)
                    let receipt = try XCTUnwrap(checkpoint.catalogReceipt)
                    XCTAssertEqual(receipt.kind, .full)
                    XCTAssertEqual(receipt.completeness, .complete)
                    for query in [WorkspaceChooserQuery.compact(maxRecent: 5), .expanded(collection: .saved, searchText: "")] {
                        let value = try chooser.consume(query)
                        XCTAssertEqual(value.kind, .ready)
                        XCTAssertEqual(Set(value.orderedIDs), [Fixture.aardvarkID, Fixture.requestedID])
                        XCTAssertEqual(value.source, .authority(.init(
                            publicationSequence: receipt.publicationSequence, catalogRevision: receipt.catalogRevision,
                            reconciliationGeneration: receipt.reconciliationGeneration, isComplete: true
                        )))
                        XCTAssertNil(value.failureID)
                    }
                }
                let completedEntries = await cold.gate.entries
                XCTAssertEqual(completedEntries, 1, "Runtime, both subscriptions and snapshots share one bootstrap task")
                for hold in holds {
                    try await f.wait(hold.entered)
                }
            }
        }

        func testClosingColdBootstrapSubscriberDoesNotCancelSurvivingWindow() async throws {
            try await Fixture.run(deferredStart: true) { f in
                let cold = await f.holdColdBootstrap()
                let closing = f.makeWindow()
                _ = f.holdInitialResolution(closing.workspaceManager)
                let closedChooser = f.makeChooserRecorder(manager: closing.workspaceManager)
                // Only this Window's Bridge can enter bootstrap: startup resolution is separately held
                // and the runtime-start task has not yet been created.
                guard await XCTWaiter.fulfillment(of: [cold.entered], timeout: 15) == .completed else {
                    throw Fixture.Failure.timedOut("cold bootstrap entry")
                }
                let survivor = f.makeWindow()
                let hold = f.holdInitialResolution(survivor.workspaceManager)
                let chooser = f.makeChooserRecorder(manager: survivor.workspaceManager)
                f.startRuntime()
                closing.beginClose()
                // beginClose fences publication; stopping its real Bridge cancels the waiting subscriber.
                closing.stopDomainWorkspaceProjectionForTesting()
                XCTAssertNil(f.projectionState(for: closing).runID)
                let closedEmissions = closedChooser.emitted
                XCTAssertEqual(try chooser.consume(.compact(maxRecent: 5)).kind, .loading)
                await cold.gate.release()
                try await f.joinRuntimeStartAndValidateSeeds()
                let checkpoint = try await f.awaitCatalogProjection(survivor)
                let receipt = try XCTUnwrap(checkpoint.catalogReceipt)
                XCTAssertEqual(receipt.kind, .full)
                XCTAssertEqual(receipt.completeness, .complete)
                XCTAssertEqual(
                    try Set(chooser.consume(.expanded(collection: .saved, searchText: "")).orderedIDs),
                    [Fixture.aardvarkID, Fixture.requestedID]
                )
                await closing.joinDomainWorkspaceBridgeForTesting()
                XCTAssertEqual(closedChooser.emitted, closedEmissions, "Closed subscriber cannot publish after release")
                XCTAssertNil(f.projectionState(for: closing).catalogCheckpoint)
                let entries = await cold.gate.entries
                XCTAssertEqual(entries, 1)
                let sharedTaskWasCancelled = await cold.gate.wasCancelled
                XCTAssertFalse(sharedTaskWasCancelled, "Closing a subscriber must not cancel the shared bootstrap hook")
                try await f.wait(hold.entered)
            }
        }

        func testColdBootstrapFailureExitReleasesAndJoinsEvenWhenOuterStartIsCancelled() async throws {
            enum ExpectedExit: Error { case held }
            for cancelOuterStart in [false, true] {
                var storage: URL?
                do {
                    try await Fixture.run(deferredStart: true) { f in
                        storage = f.base
                        let cold = await f.holdColdBootstrap()
                        let window = f.makeWindow()
                        _ = f.holdInitialResolution(window.workspaceManager)
                        f.startRuntime()
                        guard await XCTWaiter.fulfillment(of: [cold.entered], timeout: 15) == .completed else {
                            throw Fixture.Failure.timedOut("cold bootstrap entry")
                        }
                        if cancelOuterStart { f.cancelRuntimeStart() }
                        throw ExpectedExit.held
                    }
                    XCTFail("Expected fixture failure exit")
                } catch ExpectedExit.held {
                    let removed = try XCTUnwrap(storage)
                    XCTAssertFalse(
                        FileManager.default.fileExists(atPath: removed.path),
                        "Failure cleanup must release, join bootstrap, tear down and remove isolated storage"
                    )
                }
            }
        }

        func testActualChooserConsumesAuthorityOnlyWorkspaceAtItsExistingRank() async throws {
            var seeds = Fixture.standardSeeds
            for index in seeds.indices {
                seeds[index].lastUsed = Date(timeIntervalSince1970: Double(100 + index))
            }
            try await Fixture.run(seeds: seeds) { f in
                var c = Fixture.model(id: UUID(), name: "Authority-only C")
                c.lastUsed = Date(timeIntervalSince1970: 101.5)
                let author = DomainWorkspaceAuthorityClient(store: f.runtime.workspaceStore, windowID: -11420)
                _ = try await author.create(c, fileURL: f.workspaceURL(for: c), operationID: UUID())
                let canonical = await f.runtime.workspaceStore.snapshot()
                XCTAssertTrue(canonical.workspaces.contains { $0.document.workspaceID == c.id })
                XCTAssertFalse(try f.legacyIDs().contains(c.id), "C must discriminate authority from constructor membership")

                let window = f.makeWindow()
                let manager = window.workspaceManager
                let hold = f.holdInitialResolution(manager)
                let (route, selection) = f.makeRecordedRoute(for: window)
                route.evaluateInitialRouteIfNeeded()
                let routeStart = selection.routes.count
                let chooser = f.makeChooserRecorder(manager: manager)
                await window.joinDomainWorkspaceBridgeForTesting()
                XCTAssertFalse(manager.workspaces.contains { $0.id == c.id })
                XCTAssertEqual(chooser.emitted.last, .loading)
                for query in [WorkspaceChooserQuery.compact(maxRecent: 2), .expanded(collection: .saved, searchText: "")] {
                    let value = try chooser.consume(query)
                    XCTAssertEqual(value.kind, .loading)
                    XCTAssertEqual(value.orderedIDs, [])
                    XCTAssertNil(value.source)
                    XCTAssertNil(value.failureID)
                }
                window.restartDomainWorkspaceProjectionForTesting()
                let checkpoint = try await f.awaitCatalogProjection(window)
                let receipt = try XCTUnwrap(checkpoint.catalogReceipt)
                XCTAssertEqual(receipt.kind, .full)
                XCTAssertEqual(receipt.completeness, .complete)
                let expected = [Fixture.requestedID, c.id, Fixture.aardvarkID]
                for query in [WorkspaceChooserQuery.compact(maxRecent: 2), .expanded(collection: .saved, searchText: "")] {
                    let value = try chooser.consume(query)
                    XCTAssertEqual(value.kind, .ready)
                    XCTAssertEqual(value.orderedIDs, value.collection == .recent ? Array(expected.prefix(2)) : expected)
                    XCTAssertEqual(value.source, .authority(.init(
                        publicationSequence: receipt.publicationSequence, catalogRevision: receipt.catalogRevision,
                        reconciliationGeneration: receipt.reconciliationGeneration, isComplete: true
                    )))
                }
                XCTAssertFalse(chooser.emitted.contains { presentation in
                    guard case let .ready(catalog, _) = presentation else { return false }
                    return !catalog.workspaces.contains { $0.id == c.id }
                }, "Emitted arguments never expose the constructor-only list")
                try await f.acknowledgeRouteConsumption(selection)
                f.assertNoUnsolicitedSelection(selection, routeStart: routeStart, context: "authority-only chooser")
                XCTAssertEqual(route.rootRoute, .workspaceEntry)
                hold.gate.release()
            }
        }

        func testActualChooserNeverConsumesDeletedLegacyGhost() async throws {
            try await Fixture.run { f in
                let ghost = try XCTUnwrap(Fixture.standardSeeds.first { $0.id == Fixture.requestedID })
                try await f.deleteAndRestoreLegacyGhost(ghost)
                let window = f.makeWindow()
                let manager = window.workspaceManager
                let hold = f.holdInitialResolution(manager)
                let (route, selection) = f.makeRecordedRoute(for: window)
                route.evaluateInitialRouteIfNeeded()
                let routeStart = selection.routes.count
                let chooser = f.makeChooserRecorder(manager: manager)
                XCTAssertNotNil(manager.workspace(withID: ghost.id), "Constructor must actually load the stale ghost")
                await window.joinDomainWorkspaceBridgeForTesting()
                for query in [WorkspaceChooserQuery.compact(maxRecent: 5), .expanded(collection: .saved, searchText: "")] {
                    let value = try chooser.consume(query)
                    XCTAssertEqual(value.kind, .loading)
                    XCTAssertEqual(value.orderedIDs, [])
                }
                window.restartDomainWorkspaceProjectionForTesting()
                let checkpoint = try await f.awaitCatalogProjection(window)
                XCTAssertEqual(checkpoint.catalogReceipt?.kind, .full)
                for query in [WorkspaceChooserQuery.compact(maxRecent: 5), .expanded(collection: .saved, searchText: "")] {
                    let value = try chooser.consume(query)
                    XCTAssertEqual(value.kind, .ready)
                    XCTAssertEqual(value.orderedIDs, [Fixture.aardvarkID])
                }
                XCTAssertFalse(chooser.consumed.contains { $0.kind == .ready && $0.orderedIDs.contains(ghost.id) })
                XCTAssertFalse(chooser.emitted.contains {
                    if case let .ready(catalog, _) = $0 { return catalog.workspaces.contains { $0.id == ghost.id } }
                    return false
                })
                try await f.acknowledgeRouteConsumption(selection)
                f.assertNoUnsolicitedSelection(selection, routeStart: routeStart, context: "deleted ghost chooser")
                XCTAssertEqual(route.rootRoute, .workspaceEntry)
                hold.gate.release()
            }
        }

        func testOffscreenLandingLayoutsInvalidateFromLoadingToAcceptedRows() async throws {
            for layout in [WorkspaceLandingView.LayoutStyle.compact, .expanded] {
                try await Fixture.run { f in
                    let manager = f.makeManager()
                    let chooser = f.makeChooserRecorder(manager: manager)
                    var folderOpens = 0
                    let landing = WorkspaceLandingView(
                        workspaceManager: manager, onOpenWorkspace: { _ in }, onManageWorkspaces: {},
                        onSelectFolder: { folderOpens += 1 }, maxRecent: 1, maxWidth: 700, layoutStyle: layout
                    )
                    let host = NSHostingView(rootView: landing)
                    host.frame = NSRect(x: 0, y: 0, width: 800, height: 650)
                    host.layoutSubtreeIfNeeded()
                    XCTAssertNil(host.window, "Offscreen hosting must never create an NSWindow")
                    XCTAssertEqual(chooser.consumed.last?.kind, .loading, "Actual Landing descendant must consume loading")
                    XCTAssertEqual(chooser.consumed.last?.orderedIDs, [])
                    landing.onSelectFolder()
                    XCTAssertEqual(folderOpens, 1, "Open Folder remains callable during loading")

                    let snapshot = await f.runtime.workspaceStore.snapshot()
                    let receipt = try XCTUnwrap(try manager.applyDomainWorkspaceCatalog(
                        snapshot, projection: .full(f.decoded(snapshot)), preferredActiveWorkspaceID: nil, rootMapPolicy: .decodedModels
                    ).receipt)
                    XCTAssertEqual(receipt.completeness, .complete)
                    // Re-layout this SAME host: no root replacement or direct child-body evaluation.
                    for _ in 0 ..< 20 {
                        host.needsLayout = true
                        host.layoutSubtreeIfNeeded()
                        if chooser.consumed.last?.kind == .ready { break }
                        let drain = Signal("offscreen chooser run-loop drain")
                        RunLoop.main.schedule { drain.fire() }
                        try await f.wait(drain)
                    }
                    let value = chooser.consumed.last
                    XCTAssertEqual(value?.kind, .ready)
                    XCTAssertEqual(value?.orderedIDs, layout == .compact ? [Fixture.aardvarkID] : [Fixture.aardvarkID, Fixture.requestedID])
                    XCTAssertEqual(value?.layout, layout == .compact ? .compact : .expanded)
                    XCTAssertEqual(value?.collection, layout == .compact ? .recent : .saved)
                    XCTAssertEqual(value?.source, .authority(.init(
                        publicationSequence: receipt.publicationSequence, catalogRevision: receipt.catalogRevision,
                        reconciliationGeneration: receipt.reconciliationGeneration, isComplete: true
                    )))
                    XCTAssertTrue(chooser.emitted.allSatisfy {
                        if case let .ready(catalog, _) = $0 { return Set(catalog.workspaces.map(\.id)) == Fixture.standardIDs }
                        return $0 == .loading
                    }, "Unchanged authority/legacy control never invents a ready membership transition")
                }
            }
        }

        func testActualResultsQueriesPreserveIncompleteWarningEvenWithNoVisibleRows() async throws {
            let temporaryID = try XCTUnwrap(UUID(uuidString: "F0000000-0000-0000-0000-000000000005"))
            let hiddenID = try XCTUnwrap(UUID(uuidString: "F0000000-0000-0000-0000-000000000006"))
            var saved = Fixture.model(id: Fixture.aardvarkID, name: "Z Alpha saved")
            saved.repoPaths = ["/isolated/Folder-Path"]
            saved.lastUsed = Date(timeIntervalSince1970: 100)
            var temporary = Fixture.model(id: temporaryID, name: "Temporary project")
            temporary.isSavedWorkspace = false
            temporary.lastUsed = Date(timeIntervalSince1970: 200)
            var hidden = Fixture.model(id: hiddenID, name: "Hidden newest")
            hidden.isHiddenInMenus = true
            hidden.lastUsed = Date(timeIntervalSince1970: 300)
            let seeds = [Fixture.standardSeeds[0], saved, temporary, hidden, Fixture.standardSeeds[2]]
            try await Fixture.run(seeds: seeds, unavailableSeedIDs: [Fixture.requestedID]) { f in
                let manager = f.makeManager()
                let chooser = f.makeChooserRecorder(manager: manager)
                let snapshot = await f.runtime.workspaceStore.snapshot()
                let receipt = try XCTUnwrap(try manager.applyDomainWorkspaceCatalog(
                    snapshot, projection: .full(f.decoded(snapshot)), preferredActiveWorkspaceID: nil, rootMapPolicy: .decodedModels
                ).receipt)
                let failure = try XCTUnwrap(receipt.completeness.failure)
                let cases: [(WorkspaceChooserQuery, [UUID], String)] = [
                    (.compact(maxRecent: 1), [Fixture.aardvarkID], ""),
                    (.compact(maxRecent: 0), [], ""),
                    (.expanded(collection: .saved, searchText: "  aLPHa \n"), [Fixture.aardvarkID], "aLPHa"),
                    (.expanded(collection: .saved, searchText: "  folder-PATH  "), [Fixture.aardvarkID], "folder-PATH"),
                    (.expanded(collection: .temporary, searchText: ""), [temporaryID], ""),
                    (.expanded(collection: .saved, searchText: "not present"), [], "not present"),
                    (.expanded(collection: .temporary, searchText: "not present"), [], "not present")
                ]
                for (query, expected, trimmed) in cases {
                    let value = try chooser.consume(query)
                    XCTAssertEqual(value.kind, .ready)
                    XCTAssertEqual(value.orderedIDs, expected, "\(query)")
                    XCTAssertEqual(value.failureID, failure.id, "Zero filtered rows must not become healthy empty")
                    XCTAssertEqual(value.failure?.kind, .unavailableMembers([Fixture.requestedID]))
                    XCTAssertEqual(value.recovery, .idle)
                    XCTAssertEqual(value.source, .authority(.init(
                        publicationSequence: receipt.publicationSequence, catalogRevision: receipt.catalogRevision,
                        reconciliationGeneration: receipt.reconciliationGeneration, isComplete: false
                    )))
                    XCTAssertEqual(value.trimmedQuery, trimmed)
                    if case let .expanded(_, raw) = query { XCTAssertEqual(value.rawQuery, raw) }
                }
                XCTAssertEqual(manager.workspacesForMenu().map(\.id), [Fixture.aardvarkID], "Nonchooser forwarding retains default policy")
                XCTAssertEqual(manager.workspacesForMenu(.init(includeTemporary: true)).map(\.id), [temporaryID, Fixture.aardvarkID])
            }
        }

        // MARK: #1142 Accepted catalog application and completeness

        func testCatalogSnapshotReportsUnavailableMembersSeparatelyFromAggregateHealth() async throws {
            try await Fixture.run(unavailableSeedIDs: [Fixture.requestedID]) { f in
                let snapshot = await f.runtime.workspaceStore.snapshot()
                XCTAssertTrue(snapshot.isBootstrapped)
                XCTAssertEqual(snapshot.health, .writable, "A missing document does not degrade aggregate health")
                XCTAssertEqual(Set(snapshot.workspaces.map(\.document.workspaceID)), [Fixture.defaultID, Fixture.aardvarkID])
                XCTAssertEqual(snapshot.unavailableWorkspaceIDs, [Fixture.requestedID])
            }
            try await Fixture.run { f in
                let snapshot = await f.runtime.workspaceStore.snapshot()
                XCTAssertEqual(snapshot.unavailableWorkspaceIDs, [], "Complete control")
            }
        }

        func testCatalogApplicationReturnsReceiptsAndRejectsWithoutMutation() async throws {
            try await Fixture.run { f in
                let manager = f.makeManager()
                let base = await f.runtime.workspaceStore.snapshot()
                let models = try f.decoded(base)
                @MainActor func apply(
                    _ snapshot: DomainWorkspaceCatalogSnapshot,
                    _ projection: DomainCatalogProjection
                ) -> DomainCatalogApplicationResult {
                    manager.applyDomainWorkspaceCatalog(
                        snapshot, projection: projection, preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                    )
                }
                @MainActor func assertRejected(
                    _ result: @MainActor @autoclosure () -> DomainCatalogApplicationResult, _ reason: DomainCatalogRejection,
                    _ context: String, line: UInt = #line
                ) {
                    let before = (manager.workspaces, manager.domainCatalogReconciliationGeneration)
                    XCTAssertEqual(result(), .rejected(reason), context, line: line)
                    XCTAssertEqual(manager.workspaces, before.0, "\(context): rejection must not mutate", line: line)
                    XCTAssertEqual(manager.domainCatalogReconciliationGeneration, before.1, context, line: line)
                }
                let s5 = f.catalog(base, sequence: 5, catalogRevision: 5)
                assertRejected(apply(s5, .metadata(baselineGeneration: 0)), .fullProjectionRequired, "metadata cannot establish a first catalog")
                XCTAssertEqual(manager.domainCatalogReconciliationGeneration, 0)
                assertRejected(apply(s5, .full(Array(models.dropLast()))), .invalidCatalog("model_set_mismatch"), "partial model set")
                assertRejected(
                    apply(f.catalog(base, sequence: 5, catalogRevision: 5, bootstrapped: false), .full(models)),
                    .invalidCatalog("not_bootstrapped"),
                    "not bootstrapped"
                )

                let first = try XCTUnwrap(apply(s5, .full(models)).receipt)
                XCTAssertEqual(first, .init(kind: .full, publicationSequence: 5, catalogRevision: 5, reconciliationGeneration: 1, completeness: .complete))
                XCTAssertEqual(Set(manager.workspaces.map(\.id)), Fixture.standardIDs)
                XCTAssertEqual(apply(s5, .full(models)).receipt?.reconciliationGeneration, 2, "Equal-sequence recovery is accepted")
                assertRejected(apply(f.catalog(base, sequence: 4, catalogRevision: 5), .full(models)), .stalePublication, "older sequence")
                assertRejected(
                    apply(f.catalog(base, sequence: 6, catalogRevision: 4), .full(models)),
                    .staleCatalogRevision,
                    "older catalog revision with a newer sequence"
                )
                assertRejected(apply(s5, .metadata(baselineGeneration: 1)), .fullProjectionRequired, "stale metadata baseline")
                let withoutAardvark = f.catalog(base, sequence: 6, catalogRevision: 6, dropping: [Fixture.aardvarkID])
                assertRejected(
                    apply(withoutAardvark, .metadata(baselineGeneration: 2)),
                    .fullProjectionRequired,
                    "metadata cannot replace membership"
                )
                XCTAssertEqual(
                    apply(f.catalog(base, sequence: 6, catalogRevision: 6), .metadata(baselineGeneration: 2)).receipt,
                    .init(kind: .metadata, publicationSequence: 6, catalogRevision: 6, reconciliationGeneration: 3, completeness: .complete)
                )

                // Incompleteness never blocks internal reconciliation; completeness is a separate fact.
                let unavailable = f.catalog(base, sequence: 7, catalogRevision: 7, dropping: [Fixture.aardvarkID], unavailable: [Fixture.aardvarkID])
                let incomplete = try XCTUnwrap(try apply(unavailable, .full(f.decoded(unavailable))).receipt)
                guard case let .incomplete(failure) = incomplete.completeness else { return XCTFail("writable+unavailable is incomplete") }
                XCTAssertEqual(failure.kind, .unavailableMembers([Fixture.aardvarkID]))
                XCTAssertEqual(incomplete.reconciliationGeneration, 4)
                XCTAssertTrue(manager.workspaces.contains { $0.id == Fixture.aardvarkID }, "Unavailable authority member retains its last-known model")
                let degradedHealth = DomainAuthorityHealth.degradedReadOnly(reason: "workspace_index_decode_failed")
                let degraded = try XCTUnwrap(apply(f.catalog(base, sequence: 8, catalogRevision: 8, health: degradedHealth), .full(models)).receipt)
                XCTAssertEqual(degraded.completeness.failure?.kind, .authorityUnavailable(degradedHealth))
                XCTAssertEqual(Set(manager.workspaces.map(\.id)), Fixture.standardIDs, "Degraded aggregate still reconciles")

                manager.prepareForWindowClose()
                assertRejected(apply(f.catalog(base, sequence: 9, catalogRevision: 9), .full(models)), .closing, "closing")
            }
        }

        func testChooserPresentationPublishesOnlyAcceptedAuthorityRows() async throws {
            try await Fixture.run { f in
                let manager = f.makeManager()
                var emitted: [WorkspaceChooserPresentation] = []
                let token = manager.$workspaceChooserPresentation.sink { emitted.append($0) }
                defer { token.cancel() }
                XCTAssertEqual(emitted, [.loading], "Constructor-loaded legacy rows are not accepted membership")
                XCTAssertTrue(manager.workspacesForMenu().isEmpty)
                f.project(manager, Fixture.standardSeeds)
                XCTAssertEqual(emitted.last, .loading, "Direct low-level reconciliation cannot promote the chooser")

                let base = await f.runtime.workspaceStore.snapshot()
                /// Real changes emit one coherent value; equivalent retained warnings only refresh witnesses.
                @MainActor func accept(
                    _ snapshot: DomainWorkspaceCatalogSnapshot, expectPublication: Bool = true, line: UInt = #line
                ) throws -> (DomainCatalogApplicationReceipt, WorkspaceChooserCatalog, WorkspaceChooserRefresh) {
                    let start = emitted.count
                    let receipt = try XCTUnwrap(manager.applyDomainWorkspaceCatalog(
                        snapshot, projection: .full(f.decoded(snapshot)), preferredActiveWorkspaceID: nil,
                        rootMapPolicy: .snapshotMetadata
                    ).receipt, line: line)
                    let transition = emitted[start...]
                    let final: WorkspaceChooserPresentation
                    if expectPublication {
                        final = try XCTUnwrap(transition.last, "changed accepted catalog must publish", line: line)
                        XCTAssertTrue(transition.allSatisfy { $0 == final }, "no intermediate chooser value", line: line)
                    } else {
                        XCTAssertTrue(transition.isEmpty, "equivalent retained warning must not republish UI", line: line)
                        final = manager.workspaceChooserPresentation
                    }
                    guard case let .ready(catalog, refresh) = final else {
                        XCTFail("accepted catalog publishes ready rows, got \(final)", line: line)
                        throw Fixture.Failure.seedMismatch("not ready")
                    }
                    return (receipt, catalog, refresh)
                }
                func stamp(_ receipt: DomainCatalogApplicationReceipt, complete: Bool) -> WorkspaceChooserCatalog.Source {
                    .authority(.init(
                        publicationSequence: receipt.publicationSequence, catalogRevision: receipt.catalogRevision,
                        reconciliationGeneration: receipt.reconciliationGeneration, isComplete: complete
                    ))
                }

                // Initial incomplete: available authority rows, stamped incomplete with a warning.
                let missingRequested = f.catalog(
                    base,
                    sequence: 10,
                    catalogRevision: 10,
                    dropping: [Fixture.requestedID],
                    unavailable: [Fixture.requestedID]
                )
                let (r10, c10, refresh10) = try accept(missingRequested)
                XCTAssertEqual(c10.source, stamp(r10, complete: false))
                XCTAssertEqual(Set(c10.workspaces.map(\.id)), [Fixture.defaultID, Fixture.aardvarkID])
                XCTAssertEqual(refresh10, try .failed(XCTUnwrap(r10.completeness.failure)))
                // A later incomplete receipt before any complete baseline replaces the available subset.
                let missingTwo = f.catalog(
                    base,
                    sequence: 11,
                    catalogRevision: 11,
                    dropping: [Fixture.requestedID, Fixture.aardvarkID],
                    unavailable: [Fixture.requestedID, Fixture.aardvarkID]
                )
                let (r11, c11, refresh11) = try accept(missingTwo)
                XCTAssertEqual(c11.workspaces.map(\.id), [Fixture.defaultID])
                XCTAssertEqual(c11.source, stamp(r11, complete: false))
                XCTAssertEqual(refresh11, try .failed(XCTUnwrap(r11.completeness.failure)))

                // First complete baseline: final reconciled rows, current.
                let (r12, c12, refresh12) = try accept(f.catalog(base, sequence: 12, catalogRevision: 12))
                XCTAssertEqual(c12.source, stamp(r12, complete: true))
                XCTAssertEqual(c12.workspaces, manager.workspaces)
                XCTAssertEqual(Set(c12.workspaces.map(\.id)), Fixture.standardIDs)
                XCTAssertEqual(refresh12, .current)
                let readyComplete = emitted.last
                let rejectedStart = emitted.count
                XCTAssertNil(try manager.applyDomainWorkspaceCatalog(
                    missingTwo, projection: .full(f.decoded(missingTwo)), preferredActiveWorkspaceID: nil,
                    rootMapPolicy: .snapshotMetadata
                ).receipt)
                XCTAssertEqual(emitted.count, rejectedStart, "A rejection publishes nothing")
                XCTAssertEqual(manager.workspaceChooserPresentation, readyComplete)

                // Later incompleteness retains the last complete list (and stamp) with a warning.
                let missingAardvark = f.catalog(
                    base,
                    sequence: 13,
                    catalogRevision: 13,
                    dropping: [Fixture.aardvarkID],
                    unavailable: [Fixture.aardvarkID]
                )
                let (r13, c13, refresh13) = try accept(missingAardvark)
                XCTAssertEqual(c13, c12, "retained last-complete rows and stamp")
                XCTAssertTrue(manager.workspaces.contains { $0.id == Fixture.aardvarkID }, "unknown decode is not removal")
                let failure13 = try XCTUnwrap(r13.completeness.failure)
                XCTAssertEqual(refresh13, .failed(failure13))
                let (r14, _, refresh14) = try accept(f.catalog(
                    base,
                    sequence: 14,
                    catalogRevision: 14,
                    dropping: [Fixture.aardvarkID],
                    unavailable: [Fixture.aardvarkID]
                ), expectPublication: false)
                XCTAssertGreaterThan(try XCTUnwrap(r14.completeness.failure).reportVersion, failure13.reportVersion)
                let actualChooser = f.makeChooserRecorder(manager: manager)
                XCTAssertEqual(try actualChooser.consume(.compact(maxRecent: 5)).failure, r14.completeness.failure)
                XCTAssertEqual(r14.completeness.failure?.id, failure13.id, "an equivalent failure keeps its identity")
                XCTAssertEqual(refresh14, try .failed(XCTUnwrap(r14.completeness.failure)))

                // A local edit while retained updates only the touched row; untouched retained rows stay.
                let defaultIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == Fixture.defaultID })
                manager.workspaces[defaultIndex].currentPromptText = "local edit"
                guard case let .ready(edited, editedRefresh) = manager.workspaceChooserPresentation else {
                    return XCTFail("local edit must keep the ready chooser")
                }
                XCTAssertEqual(edited.source, c12.source)
                XCTAssertEqual(Set(edited.workspaces.map(\.id)), Fixture.standardIDs)
                XCTAssertEqual(edited.workspaces.first { $0.id == Fixture.defaultID }?.currentPromptText, "local edit")
                XCTAssertEqual(editedRefresh, refresh14)

                let (r15, c15, refresh15) = try accept(f.catalog(base, sequence: 15, catalogRevision: 15))
                XCTAssertEqual(c15.source, stamp(r15, complete: true))
                XCTAssertEqual(c15.workspaces, manager.workspaces)
                XCTAssertEqual(refresh15, .current)
            }
        }

        func testBridgeCheckpointCarriesAcceptedIncompleteReceipt() async throws {
            try await Fixture.run(unavailableSeedIDs: [Fixture.requestedID]) { f in
                let window = f.makeWindow()
                let manager = window.workspaceManager
                var emitted: [WorkspaceChooserPresentation] = []
                let token = manager.$workspaceChooserPresentation.sink { emitted.append($0) }
                defer { token.cancel() }
                let checkpoint = try await f.awaitCatalogProjection(window)
                let receipt = try XCTUnwrap(checkpoint.catalogReceipt)
                XCTAssertEqual(receipt.kind, .full, "The first application is a full reconciliation")
                XCTAssertEqual(receipt.completeness.failure?.kind, .unavailableMembers([Fixture.requestedID]))
                XCTAssertEqual(receipt.reconciliationGeneration, manager.domainCatalogReconciliationGeneration)
                guard case let .ready(catalog, refresh) = manager.workspaceChooserPresentation else {
                    return XCTFail("accepted incomplete rows are usable: \(manager.workspaceChooserPresentation)")
                }
                XCTAssertEqual(Set(catalog.workspaces.map(\.id)), [Fixture.defaultID, Fixture.aardvarkID])
                XCTAssertEqual(catalog.source, .authority(.init(
                    publicationSequence: receipt.publicationSequence, catalogRevision: receipt.catalogRevision,
                    reconciliationGeneration: receipt.reconciliationGeneration, isComplete: false
                )))
                XCTAssertEqual(refresh, try .failed(XCTUnwrap(receipt.completeness.failure)))
                XCTAssertEqual(emitted.first, .loading)
                let certifiedComplete = emitted.contains { value in
                    guard case let .ready(catalog, _) = value, case let .authority(stamp) = catalog.source else { return false }
                    return stamp.isComplete
                }
                XCTAssertFalse(certifiedComplete, "An incomplete catalog is never certified complete")
            }
        }

        func testBridgeStaleCatalogRejectionAdvancesNoCacheOrCheckpoint() async throws {
            try await Fixture.run { f in
                let window = f.makeWindow()
                let manager = window.workspaceManager
                await manager.awaitInitialWorkspaceActivationCompletion()
                await manager.awaitInitialized()
                let initialCheckpoint = try await f.awaitCatalogProjection(window)
                let initial = try XCTUnwrap(initialCheckpoint.catalogReceipt)
                XCTAssertEqual(initial.completeness, .complete)
                let events = f.recordProjectionEvents(window)
                let before = await f.runtime.workspaceStore.snapshot()
                let system = try XCTUnwrap(before.workspaces.first { $0.document.workspaceID == Fixture.defaultID })
                // A command outcome taught this manager a catalog baseline newer than the next publication.
                manager.applyDomainAuthorityBaseline(
                    workspaceID: Fixture.defaultID, revisions: system.revisions, digest: system.document.contentDigest,
                    health: system.health, catalogRevision: before.catalogRevision + 2
                )
                let stale = try await f.commitWorkspace(named: "Stale C", window: window, awaitProjection: false)
                let afterStale = await f.runtime.workspaceStore.snapshot()
                guard afterStale.catalogRevision == before.catalogRevision + 1 else {
                    throw Fixture.Failure.seedMismatch("create must advance the catalog revision by one")
                }
                try await f.wait(events.resolution(through: afterStale.publicationSequence))
                XCTAssertTrue(
                    events.catalogCheckpoints.isEmpty,
                    "A rejected application must not emit a checkpoint: \(events.events)"
                )
                XCTAssertTrue(try events.events.contains(.rejected(
                    runID: XCTUnwrap(f.projectionState(for: window).runID),
                    publicationSequence: afterStale.publicationSequence, reason: .staleCatalogRevision
                )))
                XCTAssertNil(manager.workspace(withID: stale.id))

                let current = try await f.commitWorkspace(named: "Current D", window: window)
                let accepted = try XCTUnwrap(events.catalogCheckpoints.last?.catalogReceipt)
                XCTAssertEqual(accepted.kind, .full)
                XCTAssertEqual(accepted.completeness, .complete)
                XCTAssertNotNil(manager.workspace(withID: stale.id), "the uncommitted cache still decodes C")
                XCTAssertNotNil(manager.workspace(withID: current.id))
                guard case let .ready(catalog, .current) = manager.workspaceChooserPresentation else {
                    return XCTFail("complete catalog is ready: \(manager.workspaceChooserPresentation)")
                }
                XCTAssertTrue(Set([stale.id, current.id]).isSubset(of: Set(catalog.workspaces.map(\.id))))
            }
        }

        func testAuthorityReloadAppliesNothingWhenAnyCatalogRecordFailsToDecode() async throws {
            struct InjectedDecodeFailure: Error {}
            try await Fixture.run { f in
                let manager = f.makeManager()
                manager.reloadWorkspacesFromDisk()
                await manager.awaitWorkspaceReloadForTesting()
                XCTAssertEqual(manager.domainCatalogReconciliationGeneration, 1, "a reload is an accepted full reconciliation")
                if case let .ready(catalog, .current) = manager.workspaceChooserPresentation {
                    XCTAssertEqual(Set(catalog.workspaces.map(\.id)), Fixture.standardIDs)
                } else {
                    XCTFail("complete reload publishes ready rows: \(manager.workspaceChooserPresentation)")
                }
                let presented = manager.workspaceChooserPresentation
                let generation = manager.domainCatalogReconciliationGeneration

                manager.setCatalogRecordDecodeFailureForTesting { $0 == Fixture.aardvarkID ? InjectedDecodeFailure() : nil }
                manager.reloadWorkspacesFromDisk()
                await manager.awaitWorkspaceReloadForTesting()
                XCTAssertNotNil(manager.workspace(withID: Fixture.aardvarkID), "a partial decode must not remove membership")
                XCTAssertEqual(manager.domainCatalogReconciliationGeneration, generation)
                // #1142 slice 5: the rejection keeps the accepted rows and attaches a scoped warning.
                guard case let .ready(previous, _) = presented,
                      case let .ready(retained, .failed(failure)) = manager.workspaceChooserPresentation,
                      case .modelProjection = failure.kind
                else { return XCTFail("later decode failure retains rows with a warning: \(manager.workspaceChooserPresentation)") }
                XCTAssertEqual(retained, previous)
                XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.kind, .projectionFailure)
                XCTAssertEqual(failure.legacyIssue?.issueID, manager.domainWorkspaceAuthorityIssue?.id)
            }
        }

        func testUnacceptedImportNeverReachesChooserUntilFullReconciliation() async throws {
            try await Fixture.run { f in
                let manager = f.makeManager()
                let base = await f.runtime.workspaceStore.snapshot()
                let models = try f.decoded(base)
                @MainActor func apply(_ sequence: UInt64, _ projection: DomainCatalogProjection) -> DomainCatalogApplicationResult {
                    manager.applyDomainWorkspaceCatalog(
                        f.catalog(base, sequence: sequence, catalogRevision: sequence), projection: projection,
                        preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                    )
                }
                let accepted = try XCTUnwrap(apply(5, .full(models)).receipt)
                let presented = manager.workspaceChooserPresentation
                XCTAssertTrue(manager.admitsDomainSelfEcho(baselineGeneration: accepted.reconciliationGeneration))

                let ghost = Fixture.model(id: UUID(), name: "Imported ghost")
                manager.replaceWorkspacesFromUnacceptedImport(models + [ghost])
                XCTAssertNotNil(manager.workspace(withID: ghost.id), "the internal assignment is unchanged")
                XCTAssertEqual(manager.workspaceChooserPresentation, presented, "unaccepted rows never reach the chooser")
                XCTAssertFalse(manager.admitsDomainSelfEcho(baselineGeneration: accepted.reconciliationGeneration))
                XCTAssertEqual(
                    Set(manager.workspacesForMenu(.init(includeSystem: true, includeTemporary: true)).map(\.id)),
                    Fixture.standardIDs,
                    "picker also hides imported ghost until acceptance"
                )
                XCTAssertEqual(apply(6, .metadata(baselineGeneration: accepted.reconciliationGeneration)), .rejected(.fullProjectionRequired))
                manager.workspaces[0].currentPromptText = "local edit after import"
                XCTAssertEqual(manager.workspaceChooserPresentation, presented, "the fence also holds local mirroring")

                let recovered = try XCTUnwrap(apply(7, .full(models)).receipt)
                XCTAssertNil(manager.workspace(withID: ghost.id))
                if case let .ready(catalog, .current) = manager.workspaceChooserPresentation {
                    XCTAssertEqual(catalog.workspaces, manager.workspaces)
                    XCTAssertEqual(Set(catalog.workspaces.map(\.id)), Fixture.standardIDs)
                } else {
                    XCTFail("accepted full reconciliation clears the fence: \(manager.workspaceChooserPresentation)")
                }
                XCTAssertTrue(manager.admitsDomainSelfEcho(baselineGeneration: recovered.reconciliationGeneration))
            }
        }

        // MARK: #1142 Failure identity and explicit recovery

        func testInitialDecodeFailureKeepsValidRowsAndReportsFailedMember() async throws {
            try await Fixture.run { f in
                let (window, manager, chooser, events) = await f.makeWindowWithHeldInitialProjection()
                var attempts = 0
                manager.setCatalogRecordDecodeFailureForTesting { id in
                    guard id == Fixture.aardvarkID else { return nil }
                    attempts += 1
                    return InjectedDecodeFailure()
                }
                window.restartDomainWorkspaceProjectionForTesting()
                let checkpoint = try await f.awaitCatalogProjection(window)
                XCTAssertEqual(checkpoint.catalogReceipt?.kind, .full)
                XCTAssertEqual(Set(manager.workspaces.map(\.id)), [Fixture.defaultID, Fixture.requestedID])
                let failure = try XCTUnwrap(manager.workspaceChooserPresentation.failure)
                XCTAssertEqual(failure.kind, .unavailableMembers([Fixture.aardvarkID]))
                XCTAssertEqual(failure.recovery, .idle)
                XCTAssertNil(manager.domainWorkspaceAuthorityIssue)
                for query in [WorkspaceChooserQuery.compact(maxRecent: 5), .expanded(collection: .saved, searchText: "")] {
                    let value = try chooser.consume(query)
                    XCTAssertEqual(value.kind, .ready)
                    XCTAssertEqual(value.orderedIDs, [Fixture.requestedID])
                    XCTAssertEqual(value.failureID, failure.id)
                    guard case let .authority(stamp) = value.source else { return XCTFail("authority subset") }
                    XCTAssertFalse(stamp.isComplete)
                }
                let before = attempts
                manager.retryWorkspaceChooser()
                await f.awaitCatalogRefresh(window)
                XCTAssertGreaterThan(attempts, before, "unchanged failed digest must not take the metadata fast path")
                XCTAssertEqual(events.catalogCheckpoints.last?.catalogReceipt?.kind, .full)
                XCTAssertEqual(manager.workspaceChooserPresentation.failure?.kind, failure.kind)
                let durable = await f.runtime.workspaceStore.snapshot()
                XCTAssertEqual(Set(durable.workspaces.map(\.document.workspaceID)), Fixture.standardIDs)
            }
        }

        func testEstablishedActiveMemberDecodeFailureRetainsModelSelectionAndDegradedChooser() async throws {
            try await Fixture.run { f in
                let (window, manager, chooser, _) = await f.makeWindowWithHeldInitialProjection()
                window.restartDomainWorkspaceProjectionForTesting()
                try await f.awaitCaughtUpWithCatalogBaseline(window)
                manager.activeWorkspace = manager.workspace(withID: Fixture.aardvarkID)
                let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == Fixture.aardvarkID })
                manager.workspaces[index].currentPromptText = "Last-known local prompt"
                let retained = try XCTUnwrap(manager.activeWorkspace)
                let acceptedChooser = manager.workspaceChooserPresentation
                var selections: [UUID?] = []
                let subscription = manager.$activeWorkspaceID.sink { selections.append($0) }
                defer { subscription.cancel() }
                var attempts = 0
                manager.setCatalogRecordDecodeFailureForTesting { id in
                    guard id == Fixture.aardvarkID else { return nil }
                    attempts += 1
                    return InjectedDecodeFailure()
                }
                let authority = DomainWorkspaceAuthorityClient(store: f.runtime.workspaceStore, windowID: -12050)
                let initialCatalog = await authority.snapshot()
                let initialRecord = try XCTUnwrap(initialCatalog.workspaces.first { $0.document.workspaceID == retained.id })
                var changed = Fixture.standardSeeds[1]
                changed.name = "Updated authoritative Aardvark"
                let changedOutcome = try await authority.replaceWorking(
                    changed, fileURL: initialRecord.document.fileURL,
                    expectedWorkspaceRevision: initialRecord.revisions.workingRevision
                )
                XCTAssertEqual(changedOutcome.disposition, .applied)
                let changedCheckpoint = try await f.awaitCatalogProjection(window)
                XCTAssertEqual(changedCheckpoint.catalogReceipt?.completeness.failure?.kind, .unavailableMembers([retained.id]))
                XCTAssertEqual(manager.activeWorkspaceID, retained.id)
                XCTAssertEqual(manager.workspace(withID: retained.id), retained, "changed-digest failure retains the local model")
                // A new subscription incarnation cannot reuse the previous decode cache.
                await window.joinDomainWorkspaceBridgeForTesting()
                window.restartDomainWorkspaceProjectionForTesting()
                let checkpoint = try await f.awaitCatalogProjection(window)
                XCTAssertEqual(checkpoint.catalogReceipt?.completeness.failure?.kind, .unavailableMembers([retained.id]))
                XCTAssertEqual(manager.activeWorkspaceID, retained.id)
                XCTAssertEqual(manager.workspace(withID: retained.id), retained)
                XCTAssertTrue(selections.allSatisfy { $0 == retained.id }, "no unload or replacement selection")
                guard case let .ready(previous, _) = acceptedChooser,
                      case let .ready(rows, .failed(failure)) = manager.workspaceChooserPresentation
                else { return XCTFail("last complete rows must remain degraded") }
                XCTAssertEqual(rows, previous)
                for query in [WorkspaceChooserQuery.compact(maxRecent: 5), .expanded(collection: .saved, searchText: "")] {
                    let value = try chooser.consume(query)
                    XCTAssertTrue(value.orderedIDs.contains(retained.id))
                    XCTAssertEqual(value.failureID, failure.id)
                }
                let beforeRetry = attempts
                manager.retryWorkspaceChooser()
                await f.awaitCatalogRefresh(window)
                XCTAssertGreaterThan(attempts, beforeRetry, "retaining a model must not cache a failed decode as successful")
                XCTAssertEqual(manager.activeWorkspaceID, retained.id)
                XCTAssertEqual(manager.workspace(withID: retained.id), retained)
                manager.setCatalogRecordDecodeFailureForTesting(nil)
                manager.retryWorkspaceChooser()
                await f.awaitCatalogRefresh(window)
                XCTAssertNil(manager.workspaceChooserPresentation.failure)
                XCTAssertEqual(manager.activeWorkspaceID, retained.id)
                XCTAssertEqual(manager.workspace(withID: retained.id)?.currentPromptText, Fixture.standardSeeds[1].currentPromptText, "successful decode replaces the retained model")
                let durable = await f.runtime.workspaceStore.snapshot()
                XCTAssertEqual(Set(durable.workspaces.map(\.document.workspaceID)), Fixture.standardIDs)
                XCTAssertEqual(manager.workspace(withID: retained.id)?.name, changed.name)
                let currentRecord = try XCTUnwrap(durable.workspaces.first { $0.document.workspaceID == retained.id })
                let deleted = await authority.delete(
                    workspaceID: retained.id, expectedCatalogRevision: durable.catalogRevision,
                    expectedWorkspaceRevision: currentRecord.revisions.workingRevision
                )
                XCTAssertEqual(deleted.disposition, .applied)
                try await f.awaitCatalogProjection(window)
                XCTAssertNil(manager.workspace(withID: retained.id), "a real authority deletion still removes the established model")
                XCTAssertEqual(manager.activeWorkspaceID, Fixture.defaultID)
                for query in [WorkspaceChooserQuery.compact(maxRecent: 5), .expanded(collection: .saved, searchText: "")] {
                    let value = try chooser.consume(query)
                    XCTAssertFalse(value.orderedIDs.contains(retained.id))
                    XCTAssertNil(value.failure)
                }
            }
        }

        func testUnavailableMemberRetainsAuthorityBaselineButTrueRemovalReconcilesSelection() async throws {
            try await Fixture.run { f in
                let manager = f.makeManager()
                let base = await f.runtime.workspaceStore.snapshot()
                let models = try f.decoded(base)
                XCTAssertNotNil(manager.applyDomainWorkspaceCatalog(
                    base, projection: .full(models), preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                ).receipt)
                manager.activeWorkspace = manager.workspace(withID: Fixture.aardvarkID)
                let retained = try XCTUnwrap(manager.activeWorkspace)
                let record = try XCTUnwrap(base.workspaces.first { $0.document.workspaceID == retained.id })
                let dirtyRevision = record.revisions.workingRevision + 1
                manager.applyDomainAuthorityBaseline(
                    workspaceID: retained.id,
                    revisions: .init(workingRevision: dirtyRevision, savedRevision: record.revisions.savedRevision, dirtyRevision: dirtyRevision),
                    digest: record.document.contentDigest, health: record.health, catalogRevision: base.catalogRevision
                )
                // Saved bytes cannot classify a member whose current projection is unknown.
                try Data("{unreadable saved phase".utf8).write(to: record.document.fileURL, options: .atomic)
                let baseline = manager.debugDomainAuthorityBaseline(for: retained.id)
                var repairBaselines: [UUID: AgentSessionLifecycleAuthority.ProjectionRepairBaseline] = [:]
                let lifecycle = AgentSessionLifecycleAuthority()
                manager.setAgentSessionProjectionReconciler { projected, current, baselines in
                    repairBaselines = baselines
                    return lifecycle.reconcileProjection(
                        projectedWorkspaces: projected, currentWorkspaces: current, claims: [], repairBaselines: baselines
                    )
                }
                let unavailable = f.catalog(
                    base, sequence: base.publicationSequence + 1, catalogRevision: base.catalogRevision + 1,
                    dropping: [retained.id], unavailable: [retained.id]
                )
                var receipt = try XCTUnwrap(try manager.applyDomainWorkspaceCatalog(
                    unavailable, projection: .full(f.decoded(unavailable)), preferredActiveWorkspaceID: retained.id,
                    rootMapPolicy: .snapshotMetadata
                ).receipt)
                await manager.awaitAuthorityIncompleteRestoreClassificationForTesting()
                XCTAssertFalse(manager.pendingConsolidatedRestoreIDs.contains(retained.id), "unknown projection must not create a restore guard from unreadable saved bytes")
                XCTAssertNil(repairBaselines[retained.id], "unknown is neither an absence nor a fresh working repair baseline")
                let metadata = f.catalog(
                    unavailable, sequence: unavailable.publicationSequence + 1, catalogRevision: unavailable.catalogRevision + 1,
                    unavailable: [retained.id]
                )
                receipt = try XCTUnwrap(manager.applyDomainWorkspaceCatalog(
                    metadata, projection: .metadata(baselineGeneration: receipt.reconciliationGeneration),
                    preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                ).receipt)
                await manager.awaitAuthorityIncompleteRestoreClassificationForTesting()
                XCTAssertFalse(manager.pendingConsolidatedRestoreIDs.contains(retained.id))
                let repeated = f.catalog(
                    metadata, sequence: metadata.publicationSequence + 1, catalogRevision: metadata.catalogRevision + 1,
                    unavailable: [retained.id]
                )
                XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                    repeated, projection: .full(f.decoded(repeated)), preferredActiveWorkspaceID: retained.id,
                    rootMapPolicy: .snapshotMetadata
                ).receipt)
                XCTAssertEqual(manager.activeWorkspaceID, retained.id)
                XCTAssertEqual(manager.workspace(withID: retained.id), retained)
                let preservedBaseline = manager.debugDomainAuthorityBaseline(for: retained.id)
                XCTAssertEqual(preservedBaseline.revisions, baseline.revisions)
                XCTAssertEqual(preservedBaseline.digest, baseline.digest)
                XCTAssertEqual(preservedBaseline.health, baseline.health)
                XCTAssertEqual(manager.workspaceFileURL(for: retained), base.workspaces.first { $0.document.workspaceID == retained.id }?.document.fileURL)

                // Same decoded records/digests, but the unavailable ID is now genuinely absent.
                let absent = f.catalog(
                    repeated, sequence: repeated.publicationSequence + 1, catalogRevision: repeated.catalogRevision + 1
                )
                XCTAssertEqual(manager.applyDomainWorkspaceCatalog(
                    absent, projection: .metadata(baselineGeneration: manager.domainCatalogReconciliationGeneration),
                    preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                ).rejection, .fullProjectionRequired, "changed unknown membership must not take the metadata fast path")

                // Another unavailable member must not hide the active member's genuine removal.
                let removed = f.catalog(
                    base, sequence: repeated.publicationSequence + 1, catalogRevision: repeated.catalogRevision + 1,
                    dropping: [retained.id, Fixture.requestedID], unavailable: [Fixture.requestedID]
                )
                XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                    removed, projection: .full(f.decoded(removed)), preferredActiveWorkspaceID: retained.id,
                    rootMapPolicy: .snapshotMetadata
                ).receipt)
                XCTAssertNil(manager.workspace(withID: retained.id))
                XCTAssertEqual(manager.activeWorkspaceID, Fixture.defaultID)
                XCTAssertEqual(repairBaselines[retained.id], .absent)
                XCTAssertNil(manager.debugDomainAuthorityBaseline(for: retained.id).revisions)
                XCTAssertNotNil(manager.workspace(withID: Fixture.requestedID), "only the still-authoritative unknown member is retained")
                let completeRemoval = f.catalog(
                    base, sequence: removed.publicationSequence + 1, catalogRevision: removed.catalogRevision + 1,
                    dropping: [retained.id]
                )
                XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                    completeRemoval, projection: .full(f.decoded(completeRemoval)), preferredActiveWorkspaceID: nil,
                    rootMapPolicy: .snapshotMetadata
                ).receipt)
                guard case let .ready(rows, .current) = manager.workspaceChooserPresentation else {
                    return XCTFail("complete removal must repair the degraded chooser")
                }
                XCTAssertFalse(rows.workspaces.contains { $0.id == retained.id })
            }
        }

        func testInventoryRefreshPreservesUnknownRestoreClassificationUntilDecodeRecovers() async throws {
            for initiallyPending in [true, false] {
                try await Fixture.run { f in
                    let manager = f.makeManager()
                    let client = DomainWorkspaceAuthorityClient(store: f.runtime.workspaceStore, windowID: -12051)
                    let base = await client.snapshot()
                    let record = try XCTUnwrap(base.workspaces.first { $0.document.workspaceID == Fixture.aardvarkID })
                    var working = try XCTUnwrap(f.decoded(base).first { $0.id == Fixture.aardvarkID })
                    working.currentPromptText = "Dirty working phase"
                    let outcome = try await client.replaceWorking(
                        working, fileURL: record.document.fileURL, expectedWorkspaceRevision: record.revisions.workingRevision
                    )
                    XCTAssertEqual(outcome.disposition, .applied)
                    let dirty = await client.snapshot()
                    XCTAssertNotNil(dirty.workspaces.first { $0.document.workspaceID == working.id }?.revisions.dirtyRevision)
                    var saved = working
                    saved.consolidatedIntoWorkspaceID = initiallyPending ? Fixture.requestedID : nil
                    try f.writeDocument(saved)
                    XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                        dirty, projection: .full(f.decoded(dirty)), preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                    ).receipt)
                    await manager.awaitAuthorityIncompleteRestoreClassificationForTesting()
                    XCTAssertEqual(manager.pendingConsolidatedRestoreIDs.contains(working.id), initiallyPending)

                    // Opposite saved-phase evidence is stale while this member cannot decode.
                    saved.consolidatedIntoWorkspaceID = initiallyPending ? nil : Fixture.requestedID
                    try f.writeDocument(saved)
                    manager.setCatalogRecordDecodeFailureForTesting { id in
                        id == working.id ? NSError(domain: "InjectedMemberDecode", code: 1) : nil
                    }
                    let inventory = await manager.loadWorkspaceSnapshotFromDisk()
                    XCTAssertFalse(inventory.contains { $0.id == working.id }, "inventory remains a decoded authority view")
                    XCTAssertEqual(
                        manager.pendingConsolidatedRestoreIDs.contains(working.id),
                        initiallyPending,
                        "an inventory read must neither clear nor invent unknown restore classification"
                    )

                    manager.setCatalogRecordDecodeFailureForTesting(nil)
                    let recovered = await manager.loadWorkspaceSnapshotFromDisk()
                    XCTAssertTrue(recovered.contains { $0.id == working.id })
                    XCTAssertEqual(
                        manager.pendingConsolidatedRestoreIDs.contains(working.id),
                        !initiallyPending,
                        "decoded recovery can classify the current saved phase again"
                    )
                }
            }
        }

        func testDuplicateCleanupRefreshPreservesUnknownRestoreClassificationWithoutReadingStaleSavedPhase() async throws {
            for initiallyPending in [true, false] {
                var seeds = Fixture.standardSeeds
                seeds[2].repoPaths = ["/tmp/decode-retain-cleanup-root"]
                var peer = Fixture.model(id: Fixture.namesakeID, name: "Cleanup peer")
                peer.repoPaths = seeds[2].repoPaths
                seeds.append(peer)
                try await Fixture.run(seeds: seeds, unavailableSeedIDs: [Fixture.aardvarkID]) { f in
                    let manager = f.makeManager()
                    let snapshot = await f.runtime.workspaceStore.snapshot()
                    XCTAssertEqual(snapshot.unavailableWorkspaceIDs, [Fixture.aardvarkID])
                    let retained = Fixture.standardSeeds[1]
                    var saved = retained
                    saved.consolidatedIntoWorkspaceID = initiallyPending ? Fixture.requestedID : nil
                    try f.writeDocument(saved)
                    let savedURL = f.workspaceURL(for: retained)
                    var fileURLs = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.document.workspaceID, $0.document.fileURL) })
                    var revisions = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.document.workspaceID, $0.revisions) })
                    var digests = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.document.workspaceID, $0.document.contentDigest) })
                    var health = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.document.workspaceID, $0.health) })
                    fileURLs[retained.id] = savedURL
                    revisions[retained.id] = .init(workingRevision: 2, savedRevision: 1, dirtyRevision: 2)
                    digests[retained.id] = "last-known-working-digest"
                    health[retained.id] = .writable
                    // Seed the previously accepted state from before the authority member became unknown.
                    XCTAssertTrue(try manager.applyDomainWorkspaceProjection(
                        f.decoded(snapshot) + [retained], fileURLsByWorkspaceID: fileURLs,
                        revisionsByWorkspaceID: revisions, digestsByWorkspaceID: digests, healthByWorkspaceID: health,
                        catalogRevision: snapshot.catalogRevision, preferredActiveWorkspaceID: nil,
                        publicationSequence: snapshot.publicationSequence
                    ))
                    await manager.awaitAuthorityIncompleteRestoreClassificationForTesting()
                    XCTAssertEqual(manager.pendingConsolidatedRestoreIDs.contains(retained.id), initiallyPending)
                    let baseline = manager.debugDomainAuthorityBaseline(for: retained.id)
                    saved.consolidatedIntoWorkspaceID = initiallyPending ? nil : Fixture.requestedID
                    try f.writeDocument(saved)
                    manager.setDuplicateCleanupBackupDirectoryForTesting(f.base.appendingPathComponent("cleanup-backups"))

                    // An unrelated real duplicate group drives the awaited cleanup refresh.
                    let result = await manager.consolidateDuplicateWorkspaces()
                    await manager.awaitAuthorityIncompleteRestoreClassificationForTesting()
                    XCTAssertEqual(result.groupsDetected, 1)
                    XCTAssertEqual(result.groupsConsolidated, 1, "known duplicate cleanup still operates")
                    XCTAssertEqual(manager.workspace(withID: retained.id), retained)
                    XCTAssertEqual(manager.debugDomainAuthorityBaseline(for: retained.id).revisions, baseline.revisions)
                    XCTAssertEqual(
                        manager.pendingConsolidatedRestoreIDs.contains(retained.id),
                        initiallyPending,
                        "cleanup must neither clear nor invent unknown restore classification from stale saved bytes"
                    )
                }
            }
        }

        func testIncompleteFullKeepsUnacceptedImportFenceUntilCompleteReconciliation() async throws {
            try await Fixture.run { f in
                let manager = f.makeManager()
                let base = await f.runtime.workspaceStore.snapshot()
                let models = try f.decoded(base)
                XCTAssertNotNil(manager.applyDomainWorkspaceCatalog(
                    base, projection: .full(models), preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                ).receipt)
                var imported = models
                let index = try XCTUnwrap(imported.firstIndex { $0.id == Fixture.aardvarkID })
                imported[index].currentPromptText = "Unaccepted imported prompt"
                manager.replaceWorkspacesFromUnacceptedImport(imported)
                let unknown = f.catalog(
                    base,
                    sequence: base.publicationSequence,
                    catalogRevision: base.catalogRevision,
                    dropping: [Fixture.aardvarkID],
                    unavailable: [Fixture.aardvarkID]
                )
                let receipt = try XCTUnwrap(try manager.applyDomainWorkspaceCatalog(
                    unknown, projection: .full(f.decoded(unknown)), preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                ).receipt)
                XCTAssertEqual(manager.workspace(withID: Fixture.aardvarkID), imported[index])
                XCTAssertTrue(manager.requiresFullCatalogReconciliation)
                XCTAssertFalse(manager.admitsDomainSelfEcho(baselineGeneration: receipt.reconciliationGeneration))
                XCTAssertEqual(manager.applyDomainWorkspaceCatalog(
                    unknown, projection: .metadata(baselineGeneration: receipt.reconciliationGeneration),
                    preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                ).rejection, .fullProjectionRequired, "even the current generation cannot certify unresolved imported state")
                let complete = try XCTUnwrap(manager.applyDomainWorkspaceCatalog(
                    base, projection: .full(models), preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                ).receipt)
                XCTAssertFalse(manager.requiresFullCatalogReconciliation)
                XCTAssertEqual(manager.workspace(withID: Fixture.aardvarkID), models[index])
                XCTAssertTrue(manager.admitsDomainSelfEcho(baselineGeneration: complete.reconciliationGeneration))
            }
        }

        /// Two real dirty authority members ensure the bulk read suspends even when A is unknown.
        private func prepareRestoreClassificationRace(
            _ f: Fixture,
            manager: WorkspaceManagerViewModel,
            initiallyPending: Bool
        ) async throws -> (DomainWorkspaceCatalogSnapshot, WorkspaceModel) {
            let client = DomainWorkspaceAuthorityClient(store: f.runtime.workspaceStore, windowID: -12052)
            let base = await client.snapshot()
            manager.workspaces = try f.decoded(base)
            manager.activeWorkspace = manager.workspace(withID: Fixture.defaultID)
            var target: WorkspaceModel?
            for id in [Fixture.aardvarkID, Fixture.requestedID] {
                let record = try XCTUnwrap(base.workspaces.first { $0.document.workspaceID == id })
                var working = try XCTUnwrap(f.decoded(base).first { $0.id == id })
                working.currentPromptText = "Dirty race working phase"
                let outcome = try await client.replaceWorking(
                    working, fileURL: record.document.fileURL, expectedWorkspaceRevision: record.revisions.workingRevision
                )
                XCTAssertEqual(outcome.disposition, .applied)
                var saved = working
                saved.consolidatedIntoWorkspaceID = id == Fixture.aardvarkID && initiallyPending ? Fixture.requestedID : nil
                try f.writeDocument(saved)
                if id == Fixture.aardvarkID { target = working }
            }
            let dirty = await client.snapshot()
            XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                dirty, projection: .full(f.decoded(dirty)), preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
            ).receipt)
            await manager.awaitAuthorityIncompleteRestoreClassificationForTesting()
            XCTAssertEqual(manager.pendingConsolidatedRestoreIDs.contains(Fixture.aardvarkID), initiallyPending)
            manager.activeWorkspace = manager.workspace(withID: Fixture.aardvarkID)
            return try (dirty, XCTUnwrap(target))
        }

        func testSameSequenceScopedRecoveryCannotBeOverwrittenByBulkClassification() async throws {
            for inventoryPath in [false, true] {
                for initiallyPending in [false, true] {
                    try await Fixture.run { f in
                        let manager = f.makeManager()
                        let (dirty, target) = try await prepareRestoreClassificationRace(f, manager: manager, initiallyPending: initiallyPending)
                        let unknown = f.catalog(
                            dirty,
                            sequence: dirty.publicationSequence,
                            catalogRevision: dirty.catalogRevision,
                            dropping: [target.id],
                            unavailable: [target.id]
                        )
                        if inventoryPath {
                            XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                                unknown, projection: .full(f.decoded(unknown)), preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                            ).receipt)
                            await manager.awaitAuthorityIncompleteRestoreClassificationForTesting()
                            manager.setCatalogRecordDecodeFailureForTesting { $0 == target.id ? InjectedDecodeFailure() : nil }
                        }
                        let entered = Signal("bulk saved-phase read captured same-sequence unknown")
                        let gate = f.makeGate()
                        manager.beforeAuthorityRestoreSavedReadForTesting = { id in
                            if id == nil { await gate.wait { entered.fire() } }
                        }
                        defer { manager.beforeAuthorityRestoreSavedReadForTesting = nil }
                        let operation: Task<Void, Never>
                        if inventoryPath {
                            operation = f.startOwned { _ = await manager.loadWorkspaceSnapshotFromDisk() }
                        } else {
                            XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                                unknown, projection: .full(f.decoded(unknown)), preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                            ).receipt)
                            let joining = Signal("join captured scheduled classifier")
                            operation = f.startOwned {
                                joining.fire()
                                await manager.awaitAuthorityIncompleteRestoreClassificationForTesting()
                            }
                            try await f.wait(joining)
                        }
                        try await f.wait(entered)
                        var saved = target
                        saved.consolidatedIntoWorkspaceID = initiallyPending ? nil : Fixture.requestedID
                        try f.writeDocument(saved)
                        manager.setCatalogRecordDecodeFailureForTesting(nil)
                        manager.activeWorkspace = manager.workspace(withID: target.id)
                        let result = await manager.requestWorkspaceSwitch(to: target, saveState: false)
                        XCTAssertFalse(result.didSwitch, "already-active or restore-blocked, without activation side effects")
                        XCTAssertEqual(manager.pendingConsolidatedRestoreIDs.contains(target.id), !initiallyPending)
                        gate.release()
                        await operation.value
                        XCTAssertEqual(
                            manager.pendingConsolidatedRestoreIDs.contains(target.id),
                            !initiallyPending,
                            "older bulk must not resurrect or erase the same-sequence scoped result (inventory=\(inventoryPath))"
                        )
                    }
                }
            }
        }

        func testSameSequenceUnknownAcceptanceRevokesAwaitedAvailableClassification() async throws {
            for initiallyPending in [false, true] {
                try await Fixture.run { f in
                    let manager = f.makeManager()
                    let (dirty, target) = try await prepareRestoreClassificationRace(f, manager: manager, initiallyPending: initiallyPending)
                    var saved = target
                    saved.consolidatedIntoWorkspaceID = initiallyPending ? nil : Fixture.requestedID
                    try f.writeDocument(saved)
                    let entered = Signal("inventory captured available candidate")
                    let gate = f.makeGate()
                    var holdFirst = true
                    manager.beforeAuthorityRestoreSavedReadForTesting = { id in
                        if id == nil, holdFirst {
                            holdFirst = false
                            await gate.wait { entered.fire() }
                        }
                    }
                    defer { manager.beforeAuthorityRestoreSavedReadForTesting = nil }
                    let inventory = f.startOwned { _ = await manager.loadWorkspaceSnapshotFromDisk() }
                    try await f.wait(entered)
                    let unknown = f.catalog(
                        dirty,
                        sequence: dirty.publicationSequence,
                        catalogRevision: dirty.catalogRevision,
                        dropping: [target.id],
                        unavailable: [target.id]
                    )
                    XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                        unknown, projection: .full(f.decoded(unknown)), preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                    ).receipt)
                    await manager.awaitAuthorityIncompleteRestoreClassificationForTesting()
                    XCTAssertEqual(manager.pendingConsolidatedRestoreIDs.contains(target.id), initiallyPending)
                    gate.release()
                    await inventory.value
                    XCTAssertEqual(
                        manager.pendingConsolidatedRestoreIDs.contains(target.id),
                        initiallyPending,
                        "a superseded inventory read cannot publish stale saved evidence for a now-unknown member"
                    )
                }
            }
        }

        func testSameSequenceBulkAcceptanceRevokesScopedSavedClassification() async throws {
            for initiallyPending in [false, true] {
                try await Fixture.run { f in
                    let manager = f.makeManager()
                    let (dirty, target) = try await prepareRestoreClassificationRace(f, manager: manager, initiallyPending: initiallyPending)
                    var saved = target
                    saved.consolidatedIntoWorkspaceID = initiallyPending ? nil : Fixture.requestedID
                    try f.writeDocument(saved)
                    let entered = Signal("scoped saved-phase read captured available candidate")
                    let gate = f.makeGate()
                    manager.beforeAuthorityRestoreSavedReadForTesting = { id in
                        if id == target.id { await gate.wait { entered.fire() } }
                    }
                    defer { manager.beforeAuthorityRestoreSavedReadForTesting = nil }
                    let scoped = f.startOwned { await manager.requestWorkspaceSwitch(to: target, saveState: false) }
                    try await f.wait(entered)
                    let unknown = f.catalog(
                        dirty,
                        sequence: dirty.publicationSequence,
                        catalogRevision: dirty.catalogRevision,
                        dropping: [target.id],
                        unavailable: [target.id]
                    )
                    XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                        unknown, projection: .full(f.decoded(unknown)), preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                    ).receipt)
                    await manager.awaitAuthorityIncompleteRestoreClassificationForTesting()
                    XCTAssertEqual(manager.pendingConsolidatedRestoreIDs.contains(target.id), initiallyPending)
                    manager.activeWorkspace = manager.workspace(withID: target.id)
                    gate.release()
                    let result = await scoped.value
                    XCTAssertFalse(result.didSwitch)
                    XCTAssertEqual(
                        manager.pendingConsolidatedRestoreIDs.contains(target.id),
                        initiallyPending,
                        "new accepted unknown evidence revokes an older same-sequence scoped saved read"
                    )
                }
            }
        }

        func testScopedUnknownResultRevokesOlderBulkSavedClassification() async throws {
            for inventoryPath in [false, true] {
                for missingRecord in [false, true] {
                    for initiallyPending in [false, true] {
                        try await Fixture.run { f in
                            let manager = f.makeManager()
                            let (dirty, target) = try await prepareRestoreClassificationRace(f, manager: manager, initiallyPending: initiallyPending)
                            let entered = Signal("bulk captured available target before scoped unknown result")
                            let gate = f.makeGate()
                            manager.beforeAuthorityRestoreSavedReadForTesting = { id in
                                if id == nil { await gate.wait { entered.fire() } }
                            }
                            defer { manager.beforeAuthorityRestoreSavedReadForTesting = nil }
                            let operation: Task<Void, Never>
                            if inventoryPath {
                                operation = f.startOwned { _ = await manager.loadWorkspaceSnapshotFromDisk() }
                            } else {
                                XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                                    dirty, projection: .full(f.decoded(dirty)), preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                                ).receipt)
                                let joining = Signal("joined older scheduled classifier")
                                operation = f.startOwned {
                                    joining.fire()
                                    await manager.awaitAuthorityIncompleteRestoreClassificationForTesting()
                                }
                                try await f.wait(joining)
                            }
                            try await f.wait(entered)
                            var saved = target
                            saved.consolidatedIntoWorkspaceID = initiallyPending ? nil : Fixture.requestedID
                            try f.writeDocument(saved)
                            if missingRecord {
                                let client = DomainWorkspaceAuthorityClient(store: f.runtime.workspaceStore, windowID: -12053)
                                let record = try XCTUnwrap(dirty.workspaces.first { $0.document.workspaceID == target.id })
                                let outcome = await client.delete(
                                    workspaceID: target.id,
                                    expectedCatalogRevision: dirty.catalogRevision,
                                    expectedWorkspaceRevision: record.revisions.workingRevision
                                )
                                XCTAssertEqual(outcome.disposition, .applied)
                                // Deletion removes the saved file. Recreate stale saved bytes so an
                                // obsolete bulk attempt can discriminate both guard directions.
                                try f.writeDocument(saved)
                            } else {
                                manager.setCatalogRecordDecodeFailureForTesting { $0 == target.id ? InjectedDecodeFailure() : nil }
                            }
                            manager.activeWorkspace = manager.workspace(withID: target.id)
                            let result = await manager.requestWorkspaceSwitch(to: target, saveState: false)
                            XCTAssertFalse(result.didSwitch)
                            XCTAssertEqual(manager.pendingConsolidatedRestoreIDs.contains(target.id), initiallyPending)
                            gate.release()
                            await operation.value
                            XCTAssertEqual(
                                manager.pendingConsolidatedRestoreIDs.contains(target.id),
                                initiallyPending,
                                "unknown scoped evidence revokes older bulk (inventory=\(inventoryPath), missing=\(missingRecord))"
                            )
                        }
                    }
                }
            }
        }

        func testRetainedUnavailableMemberReregistersScopedReadAfterCanonicalTransition() async throws {
            for metadataOnly in [false, true] {
                for pendingRegistration in [false, true] {
                    try await Fixture.run { f in
                        let (window, manager, _, _) = await f.makeWindowWithHeldInitialProjection()
                        let previousWindows = WindowStatesManager.shared.allWindows
                        WindowStatesManager.shared.allWindows = [window]
                        defer { WindowStatesManager.shared.allWindows = previousWindows }
                        let client = DomainWorkspaceAuthorityClient(store: f.runtime.workspaceStore, windowID: window.windowID)
                        let base = await client.snapshot()
                        XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                            base, projection: .full(f.decoded(base)), preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                        ).receipt)
                        manager.activeWorkspace = manager.workspace(withID: Fixture.aardvarkID)
                        let retained = try XCTUnwrap(manager.activeWorkspace)
                        // Establish the retained/unknown membership before registering D1. A
                        // subsequent unchanged membership can legitimately use the metadata path.
                        let initiallyUnavailable = f.catalog(
                            base, sequence: base.publicationSequence, catalogRevision: base.catalogRevision,
                            dropping: [retained.id], unavailable: [retained.id]
                        )
                        XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                            initiallyUnavailable, projection: .full(f.decoded(initiallyUnavailable)),
                            preferredActiveWorkspaceID: retained.id, rootMapPolicy: .snapshotMetadata
                        ).receipt)
                        let tabID = try XCTUnwrap(retained.activeComposeTabID)
                        let invocation = ToolInvocationContext.trustedLocal(
                            toolName: "workspace_context",
                            metadata: MCPRequestMetadata(
                                connectionID: UUID(), clientName: "Retained read fixture", windowID: window.windowID,
                                tabContextHint: MCPTabContextHint(tabID: tabID, workspaceID: retained.id, windowID: window.windowID)
                            )
                        )
                        let firstRead = try await window.mcpServer.resolveDomainReadContext(
                            toolName: "workspace_context", requirement: .workspaceRequired, invocationContext: invocation
                        )
                        window.mcpServer.releaseDomainReadAppExecutionContext(for: firstRead)
                        XCTAssertTrue(manager.debugDomainReadRegistrationStateExistsForWorkspace(retained.id))
                        var pending: WorkspaceManagerViewModel.DomainReadRegistrationToken?
                        if pendingRegistration {
                            manager.invalidateDomainReadRegistration(for: retained.id)
                            pending = manager.domainReadRegistrationToken(for: retained, fileURL: manager.workspaceFileURL(for: retained))
                            XCTAssertNotNil(pending)
                            _ = try await client.registerForRead(retained, fileURL: manager.workspaceFileURL(for: retained))
                        }
                        let original = try XCTUnwrap(base.workspaces.first { $0.document.workspaceID == retained.id })
                        var changed = retained
                        changed.currentPromptText = "Canonical D2 is not the retained window D1"
                        changed.composeTabs[0].name = "Canonical D2 context"
                        let outcome = try await client.replaceWorking(
                            changed, fileURL: original.document.fileURL, expectedWorkspaceRevision: original.revisions.workingRevision
                        )
                        XCTAssertEqual(outcome.disposition, .applied)
                        let beforeProjectionSnapshot = await client.workspaceSnapshot(retained.id)
                        let beforeProjectionRead = try XCTUnwrap(beforeProjectionSnapshot)
                        XCTAssertEqual(try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                            documentBytes: beforeProjectionRead.document.documentBytes, fileURL: beforeProjectionRead.document.fileURL
                        ).currentPromptText, changed.currentPromptText, "canonical transition removed the existing D1 read overlay")
                        let canonical = await client.snapshot()
                        let unavailable = f.catalog(
                            canonical, sequence: canonical.publicationSequence, catalogRevision: canonical.catalogRevision,
                            dropping: [retained.id], unavailable: [retained.id]
                        )
                        XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                            unavailable, projection: metadataOnly ? .metadata(baselineGeneration: manager.domainCatalogReconciliationGeneration) : .full(f.decoded(unavailable)),
                            preferredActiveWorkspaceID: retained.id, rootMapPolicy: .snapshotMetadata
                        ).receipt)
                        XCTAssertEqual(manager.activeWorkspaceID, retained.id)
                        XCTAssertEqual(manager.activeWorkspace?.currentPromptText, retained.currentPromptText)
                        XCTAssertNotNil(manager.workspaceChooserPresentation.failure)
                        XCTAssertFalse(manager.debugDomainReadRegistrationStateExistsForWorkspace(retained.id))
                        if let pending { manager.confirmDomainReadRegistration(pending) }
                        XCTAssertFalse(manager.debugDomainReadRegistrationStateExistsForWorkspace(retained.id), "old pending token cannot re-confirm after projection invalidation")
                        let nextRead = try await window.mcpServer.resolveDomainReadContext(
                            toolName: "workspace_context", requirement: .workspaceRequired, invocationContext: invocation
                        )
                        defer { window.mcpServer.releaseDomainReadAppExecutionContext(for: nextRead) }
                        let handle = try XCTUnwrap(nextRead.handle)
                        let contextSnapshot = await f.runtime.contextStore.snapshot(handle.context)
                        XCTAssertEqual(contextSnapshot?.metadata.name, retained.composeTabs[0].name, "real scoped context read must match retained window D1")
                        let routedSnapshot = await f.runtime.contextStore.workspaceSnapshot(retained.id)
                        let readSnapshot = try XCTUnwrap(routedSnapshot)
                        XCTAssertEqual(
                            try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                                documentBytes: readSnapshot.document.documentBytes, fileURL: readSnapshot.document.fileURL
                            ).currentPromptText,
                            retained.currentPromptText,
                            "scoped read must represent retained D1, not canonical D2 (metadata=\(metadataOnly), pending=\(pendingRegistration))"
                        )
                        XCTAssertNil(manager.domainReadRegistrationToken(
                            for: retained, fileURL: manager.workspaceFileURL(for: retained)
                        ), "steady reads still reuse the newly confirmed registration")
                        let canonicalRead = await client.canonicalWorkspaceSnapshot(retained.id)
                        let durable = try XCTUnwrap(canonicalRead)
                        XCTAssertEqual(durable.document.contentDigest, beforeProjectionRead.document.contentDigest, "read registration must not mutate canonical D2")
                    }
                }
            }
        }

        func testSupersededCleanupClassificationCannotRetireUnclassifiedOtherMember() async throws {
            for postSwitchValidation in [false, true] {
                for missingScopedRecord in [false, true] {
                    var a = Fixture.standardSeeds[1]
                    a.repoPaths = ["/tmp/decode-retain-independent-scope"]
                    var b = Fixture.standardSeeds[2]
                    b.repoPaths = ["/tmp/decode-retain-other-member-duplicate"]
                    var canonical = Fixture.model(id: Fixture.namesakeID, name: "Canonical B peer")
                    canonical.repoPaths = b.repoPaths
                    canonical.lastUsed = Date(timeIntervalSince1970: 200)
                    b.lastUsed = Date(timeIntervalSince1970: 100)
                    try await Fixture.run(seeds: [Fixture.standardSeeds[0], a, b, canonical]) { f in
                        let manager = f.makeManager()
                        let client = DomainWorkspaceAuthorityClient(store: f.runtime.workspaceStore, windowID: -12056)
                        let clean = await client.snapshot()
                        let models = try f.decoded(clean)
                        manager.workspaces = models
                        manager.activeWorkspace = manager.workspace(withID: Fixture.defaultID)
                        XCTAssertNotNil(manager.applyDomainWorkspaceCatalog(
                            clean, projection: .full(models), preferredActiveWorkspaceID: Fixture.defaultID, rootMapPolicy: .snapshotMetadata
                        ).receipt)
                        await manager.awaitAuthorityIncompleteRestoreClassificationForTesting()
                        let previousWindows = WindowStatesManager.shared.allWindows
                        WindowStatesManager.shared.allWindows = []
                        defer { WindowStatesManager.shared.allWindows = previousWindows }
                        let backupDirectory = f.base.appendingPathComponent("coverage-backups", isDirectory: true)
                        manager.setDuplicateCleanupBackupDirectoryForTesting(backupDirectory)
                        let group = try XCTUnwrap(manager.duplicateWorkspaceGroups().first)
                        XCTAssertEqual(group.duplicateWorkspaceIDs, [b.id])
                        XCTAssertFalse(manager.pendingConsolidatedRestoreIDs.contains(b.id))

                        let aRecord = try XCTUnwrap(clean.workspaces.first { $0.document.workspaceID == a.id })
                        var dirtyA = try XCTUnwrap(models.first { $0.id == a.id })
                        dirtyA.currentPromptText = "Scoped A dirty, saved phase unmarked"
                        let aOutcome = try await client.replaceWorking(
                            dirtyA, fileURL: aRecord.document.fileURL, expectedWorkspaceRevision: aRecord.revisions.workingRevision
                        )
                        XCTAssertEqual(aOutcome.disposition, .applied)
                        try f.writeDocument(dirtyA)
                        let bRecord = try XCTUnwrap(clean.workspaces.first { $0.document.workspaceID == b.id })
                        var dirtyB = try XCTUnwrap(models.first { $0.id == b.id })
                        dirtyB.currentPromptText = "B newly dirty, saved phase still marked"
                        var savedB = dirtyB
                        savedB.consolidatedIntoWorkspaceID = canonical.id
                        if !postSwitchValidation {
                            let bOutcome = try await client.replaceWorking(
                                dirtyB, fileURL: bRecord.document.fileURL, expectedWorkspaceRevision: bRecord.revisions.workingRevision
                            )
                            XCTAssertEqual(bOutcome.disposition, .applied)
                            try f.writeDocument(savedB)
                        }

                        let preEntered = Signal("cleanup first owned bulk read")
                        let postEntered = Signal("cleanup post-switch owned bulk read includes B")
                        let preGate = f.makeGate()
                        let postGate = f.makeGate()
                        var bulkReads = 0
                        manager.beforeAuthorityRestoreSavedReadForTesting = { id in
                            guard id == nil else { return }
                            bulkReads += 1
                            if bulkReads == 1 { await preGate.wait { preEntered.fire() } }
                            else { await postGate.wait { postEntered.fire() } }
                        }
                        defer { manager.beforeAuthorityRestoreSavedReadForTesting = nil }
                        let cleanup = f.startOwned { await manager.consolidateDuplicateWorkspaces() }
                        try await f.wait(preEntered)
                        if postSwitchValidation {
                            let bOutcome = try await client.replaceWorking(
                                dirtyB, fileURL: bRecord.document.fileURL, expectedWorkspaceRevision: bRecord.revisions.workingRevision
                            )
                            XCTAssertEqual(bOutcome.disposition, .applied)
                            try f.writeDocument(savedB)
                            preGate.release()
                            try await f.wait(postEntered)
                        }
                        XCTAssertFalse(manager.pendingConsolidatedRestoreIDs.contains(b.id), "B has not completed its marked saved-phase read")
                        if missingScopedRecord {
                            let beforeDelete = await client.snapshot()
                            let record = try XCTUnwrap(beforeDelete.workspaces.first { $0.document.workspaceID == a.id })
                            let deleted = await client.delete(
                                workspaceID: a.id, expectedCatalogRevision: beforeDelete.catalogRevision,
                                expectedWorkspaceRevision: record.revisions.workingRevision
                            )
                            XCTAssertEqual(deleted.disposition, .applied)
                        } else {
                            manager.setCatalogRecordDecodeFailureForTesting { $0 == a.id ? InjectedDecodeFailure() : nil }
                        }
                        let scoped = await manager.requestWorkspaceSwitch(to: dirtyA, saveState: false)
                        XCTAssertFalse(scoped.didSwitch)
                        let beforeCleanupContinuation = await client.snapshot()
                        preGate.release()
                        postGate.release()
                        let result = await cleanup.value
                        XCTAssertEqual(result.groupsConsolidated, 0, "superseded coverage is not completed pre/post validation")
                        XCTAssertFalse(result.retiredWorkspaceIDs.contains(b.id), "scoped A must not authorize retirement of unread B")
                        XCTAssertTrue(result.reassignedWindowIDs.isEmpty)
                        XCTAssertTrue(result.skipped.contains { $0.workspaceID == b.id && $0.reason.contains("superseded") })
                        if !postSwitchValidation {
                            XCTAssertNil(result.backupURL)
                            XCTAssertFalse(FileManager.default.fileExists(atPath: backupDirectory.path))
                        }
                        let after = await client.snapshot()
                        XCTAssertEqual(after.publicationSequence, beforeCleanupContinuation.publicationSequence, "no merge/save/retire after lost classification coverage")
                        let retainedB = try XCTUnwrap(manager.workspace(withID: b.id))
                        XCTAssertNil(retainedB.consolidatedIntoWorkspaceID)
                        let authorityB = try XCTUnwrap(after.workspaces.first { $0.document.workspaceID == b.id })
                        XCTAssertNil(try manager.decodeDomainWorkspaceCatalogRecord(authorityB).consolidatedIntoWorkspaceID)

                        // Control: a fresh, unsuperseded classification covers B and excludes it.
                        manager.beforeAuthorityRestoreSavedReadForTesting = nil
                        manager.setCatalogRecordDecodeFailureForTesting(nil)
                        let recovered = await manager.consolidateDuplicateWorkspaces()
                        XCTAssertEqual(recovered.groupsConsolidated, 0)
                        XCTAssertFalse(recovered.retiredWorkspaceIDs.contains(b.id))
                        XCTAssertTrue(manager.pendingConsolidatedRestoreIDs.contains(b.id), "completed fresh classification discovers unrelated B's real marker")
                        XCTAssertTrue(manager.duplicateWorkspaceGroups().isEmpty)
                    }
                }
            }
        }

        func testFirstCleanupDecodeFailurePrecedesBackupAndActiveDuplicateReassignment() async throws {
            var canonical = Fixture.standardSeeds[1]
            var duplicate = Fixture.standardSeeds[2]
            canonical.lastUsed = Date(timeIntervalSince1970: 200)
            duplicate.lastUsed = Date(timeIntervalSince1970: 100)
            try await Fixture.run(seeds: [Fixture.standardSeeds[0], canonical, duplicate], beforeRuntimeStart: { f in
                let root = f.base.appendingPathComponent("shared-project", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                for var model in [canonical, duplicate] {
                    model.repoPaths = [root.path]
                    try f.writeDocument(model)
                }
            }) { f in
                let (canonicalWindow, canonicalManager, _, _) = await f.makeWindowWithHeldInitialProjection()
                let (duplicateWindow, manager, _, _) = await f.makeWindowWithHeldInitialProjection()
                let snapshot = await f.runtime.workspaceStore.snapshot()
                let models = try f.decoded(snapshot)
                for (owner, id) in [(canonicalManager, canonical.id), (manager, duplicate.id)] {
                    owner.workspaces = models
                    owner.activeWorkspace = owner.workspace(withID: id)
                    XCTAssertNotNil(owner.applyDomainWorkspaceCatalog(
                        snapshot, projection: .full(models), preferredActiveWorkspaceID: id, rootMapPolicy: .snapshotMetadata
                    ).receipt)
                    await owner.awaitAuthorityIncompleteRestoreClassificationForTesting()
                    _ = try await owner.requestWorkspaceSwitch(to: XCTUnwrap(owner.workspace(withID: id)), saveState: false)
                }
                canonicalWindow.isCurrentlyFocused = true
                let previousWindows = WindowStatesManager.shared.allWindows
                WindowStatesManager.shared.allWindows = [canonicalWindow, duplicateWindow]
                defer { WindowStatesManager.shared.allWindows = previousWindows }
                let group = try XCTUnwrap(manager.duplicateWorkspaceGroups().first)
                XCTAssertEqual(group.canonicalWorkspaceID, canonical.id)
                XCTAssertEqual(group.duplicateWorkspaceIDs, [duplicate.id])
                let retained = try XCTUnwrap(manager.activeWorkspace)
                let selections = f.makeRecorder(manager: manager)
                let backupDirectory = f.base.appendingPathComponent("cleanup-backups", isDirectory: true)
                manager.setDuplicateCleanupBackupDirectoryForTesting(backupDirectory)
                var decodeFailures = 0
                manager.setCatalogRecordDecodeFailureForTesting { id in
                    guard id == duplicate.id else { return nil }
                    decodeFailures += 1
                    return InjectedDecodeFailure()
                }
                let result = await manager.consolidateDuplicateWorkspaces()
                XCTAssertGreaterThan(decodeFailures, 0, "cleanup itself must first observe the decode failure")
                XCTAssertEqual(manager.activeWorkspaceID, duplicate.id)
                XCTAssertEqual(manager.workspace(withID: duplicate.id), retained)
                XCTAssertTrue(selections.emittedIDs.allSatisfy { $0 == duplicate.id }, "no temporary unload or reassignment")
                XCTAssertTrue(result.reassignedWindowIDs.isEmpty)
                XCTAssertEqual(result.groupsConsolidated, 0)
                XCTAssertTrue(result.retiredWorkspaceIDs.isEmpty)
                XCTAssertNil(result.backupURL)
                XCTAssertFalse(FileManager.default.fileExists(atPath: backupDirectory.path))
                let unchanged = await f.runtime.workspaceStore.snapshot()
                XCTAssertEqual(unchanged.publicationSequence, snapshot.publicationSequence, "no save before failed prevalidation")

                manager.setCatalogRecordDecodeFailureForTesting(nil)
                let recovered = await manager.consolidateDuplicateWorkspaces()
                XCTAssertEqual(recovered.groupsConsolidated, 1, "decoded known-group cleanup still works")
                XCTAssertEqual(manager.activeWorkspaceID, canonical.id)
            }
        }

        func testScopedRestoreDecodeFailurePreservesGuardWithoutSavedRead() async throws {
            try await Fixture.run { f in
                let manager = f.makeManager()
                let (_, target) = try await prepareRestoreClassificationRace(f, manager: manager, initiallyPending: true)
                try f.writeDocument(target)
                var savedReads = 0
                manager.beforeAuthorityRestoreSavedReadForTesting = { id in if id == target.id { savedReads += 1 } }
                defer { manager.beforeAuthorityRestoreSavedReadForTesting = nil }
                manager.setCatalogRecordDecodeFailureForTesting { $0 == target.id ? InjectedDecodeFailure() : nil }
                let blocked = await manager.requestWorkspaceSwitch(to: target, saveState: false)
                XCTAssertFalse(blocked.didSwitch)
                XCTAssertTrue(manager.pendingConsolidatedRestoreIDs.contains(target.id))
                XCTAssertEqual(savedReads, 0, "unknown working identity cannot authorize saved-phase evidence")
                manager.setCatalogRecordDecodeFailureForTesting(nil)
                _ = await manager.requestWorkspaceSwitch(to: target, saveState: false)
                XCTAssertFalse(manager.pendingConsolidatedRestoreIDs.contains(target.id))
                XCTAssertEqual(savedReads, 1)
            }
        }

        func testUnknownCleanMemberIsExcludedFromKnownDuplicateGroup() async throws {
            var seeds = Fixture.standardSeeds
            seeds[1].repoPaths = ["/tmp/decode-retain-unknown-duplicate"]
            seeds[2].repoPaths = seeds[1].repoPaths
            var peer = Fixture.model(id: Fixture.namesakeID, name: "Known cleanup peer")
            peer.repoPaths = seeds[1].repoPaths
            seeds.append(peer)
            try await Fixture.run(seeds: seeds, unavailableSeedIDs: [Fixture.aardvarkID]) { f in
                let manager = f.makeManager()
                let snapshot = await f.runtime.workspaceStore.snapshot()
                let retained = seeds[1]
                try f.writeDocument(retained)
                var urls = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.document.workspaceID, $0.document.fileURL) })
                var revisions = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.document.workspaceID, $0.revisions) })
                urls[retained.id] = f.workspaceURL(for: retained)
                revisions[retained.id] = .init(workingRevision: 1, savedRevision: 1, dirtyRevision: nil)
                XCTAssertTrue(try manager.applyDomainWorkspaceProjection(
                    f.decoded(snapshot) + [retained], fileURLsByWorkspaceID: urls, revisionsByWorkspaceID: revisions,
                    digestsByWorkspaceID: [:], healthByWorkspaceID: [:],
                    catalogRevision: snapshot.catalogRevision, preferredActiveWorkspaceID: nil, publicationSequence: snapshot.publicationSequence
                ))
                XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                    snapshot, projection: .full(f.decoded(snapshot)), preferredActiveWorkspaceID: nil, rootMapPolicy: .snapshotMetadata
                ).receipt)
                await manager.awaitAuthorityIncompleteRestoreClassificationForTesting()
                XCTAssertFalse(manager.pendingConsolidatedRestoreIDs.contains(retained.id))
                let group = try XCTUnwrap(manager.duplicateWorkspaceGroups().first)
                XCTAssertEqual(Set(group.duplicateWorkspaceIDs + [group.canonicalWorkspaceID]), [Fixture.requestedID, Fixture.namesakeID])
                manager.setDuplicateCleanupBackupDirectoryForTesting(f.base.appendingPathComponent("cleanup-backups"))
                let result = await manager.consolidateDuplicateWorkspaces()
                XCTAssertEqual(result.groupsConsolidated, 1)
                XCTAssertEqual(manager.workspace(withID: retained.id), retained, "unknown member is neither canonical evidence nor a retirement target")
            }
        }

        func testStartupUnavailableMembersWithoutAcceptedModelsDoNotInventRows() async throws {
            try await Fixture.run { f in
                let manager = f.makeManager()
                XCTAssertNil(manager.activeWorkspaceID)
                let base = await f.runtime.workspaceStore.snapshot()
                let unknownID = UUID()
                let unavailable = f.catalog(
                    base, sequence: base.publicationSequence + 1, catalogRevision: base.catalogRevision + 1,
                    dropping: [Fixture.aardvarkID], unavailable: [Fixture.aardvarkID, unknownID]
                )
                XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                    unavailable, projection: .full(f.decoded(unavailable)), preferredActiveWorkspaceID: Fixture.aardvarkID,
                    rootMapPolicy: .snapshotMetadata
                ).receipt)
                XCTAssertNil(manager.workspace(withID: Fixture.aardvarkID), "a disk row is not an accepted model")
                XCTAssertNil(manager.workspace(withID: unknownID))
                XCTAssertEqual(manager.activeWorkspaceID, Fixture.defaultID, "only decoded canonical System evidence can recover startup")
                let chooser = f.makeChooserRecorder(manager: manager)
                for query in [WorkspaceChooserQuery.compact(maxRecent: 5), .expanded(collection: .saved, searchText: "")] {
                    let value = try chooser.consume(query)
                    XCTAssertEqual(value.orderedIDs, [Fixture.requestedID])
                    XCTAssertEqual(value.failure?.kind, .unavailableMembers([Fixture.aardvarkID, unknownID]))
                }
            }
        }

        func testCorruptWorkspaceFileAmongValidMembersKeepsAvailableChooserRows() async throws {
            try await Fixture.run(unavailableSeedIDs: [Fixture.aardvarkID], beforeRuntimeStart: { f in
                let url = f.workspaceURL(for: Fixture.standardSeeds[1])
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("{broken workspace".utf8).write(to: url, options: .atomic)
            }) { f in
                let (window, manager, chooser, _) = await f.makeWindowWithHeldInitialProjection()
                window.restartDomainWorkspaceProjectionForTesting()
                let checkpoint = try await f.awaitCatalogProjection(window)
                XCTAssertEqual(checkpoint.catalogReceipt?.completeness.failure?.kind, .unavailableMembers([Fixture.aardvarkID]))
                XCTAssertEqual(try chooser.consume(.compact(maxRecent: 5)).orderedIDs, [Fixture.requestedID])
                XCTAssertEqual(try chooser.consume(.expanded(collection: .saved, searchText: "")).orderedIDs, [Fixture.requestedID])
                try f.writeSeedDocument(Fixture.aardvarkID)
                manager.retryWorkspaceChooser()
                await f.awaitCatalogRefresh(window)
                XCTAssertNil(manager.workspaceChooserPresentation.failure)
                XCTAssertEqual(try chooser.consume(.compact(maxRecent: 5)).orderedIDs, [Fixture.aardvarkID, Fixture.requestedID])
            }
        }

        func testAllModelDecodesFailAsIncompleteEmptyWithoutCreatingDefault() async throws {
            try await Fixture.run { f in
                let (window, manager, chooser, _) = await f.makeWindowWithHeldInitialProjection()
                let bridge = try XCTUnwrap(window.domainWorkspacePresentationBridgeForTesting)
                var defaultCreations = 0
                XCTAssertTrue(bridge.setInitialDefaultCreateOutcomeForTesting(.init(
                    operationID: UUID(), disposition: .failed, before: nil, after: nil,
                    catalogRevision: 0, resultingDigest: nil
                )) { _ in defaultCreations += 1 })
                manager.setCatalogRecordDecodeFailureForTesting { _ in InjectedDecodeFailure() }
                window.restartDomainWorkspaceProjectionForTesting()
                let checkpoint = try await f.awaitCatalogProjection(window)
                XCTAssertEqual(checkpoint.catalogReceipt?.completeness.failure?.kind, .unavailableMembers(Fixture.standardIDs))
                let value = try chooser.consume(.compact(maxRecent: 5))
                XCTAssertEqual(value.kind, .ready)
                XCTAssertEqual(value.orderedIDs, [])
                XCTAssertEqual(value.failure?.kind, .unavailableMembers(Fixture.standardIDs))
                XCTAssertEqual(defaultCreations, 0)
                let durable = await f.runtime.workspaceStore.snapshot()
                XCTAssertEqual(Set(durable.workspaces.map(\.document.workspaceID)), Fixture.standardIDs)
            }
        }

        func testRetryAfterRepairReachesAcceptedMembershipAndRepeatedRequestsCoalesce() async throws {
            try await Fixture.run { f in
                let (window, manager, chooser, events) = await f.makeWindowWithHeldInitialProjection()
                manager.setCatalogRecordDecodeFailureForTesting { $0 == Fixture.aardvarkID ? InjectedDecodeFailure() : nil }
                window.restartDomainWorkspaceProjectionForTesting()
                let snapshot = await f.runtime.workspaceStore.snapshot()
                try await f.wait(events.resolution(through: snapshot.publicationSequence))
                let failure = try XCTUnwrap(manager.workspaceChooserPresentation.failure)

                manager.setCatalogRecordDecodeFailureForTesting(nil)
                manager.retryWorkspaceChooser()
                guard case let .ready(_, .failed(retrying)) = manager.workspaceChooserPresentation,
                      case let .retrying(retryID) = retrying.recovery
                else { return XCTFail("Retry must mark the failure retrying: \(manager.workspaceChooserPresentation)") }
                XCTAssertEqual(retrying.id, failure.id, "retrying keeps the failure identity")
                let consumed = try chooser.consume(.expanded(collection: .saved, searchText: ""))
                XCTAssertEqual(consumed.kind, .ready)
                XCTAssertEqual(consumed.orderedIDs, [Fixture.requestedID])
                XCTAssertEqual(consumed.recovery, .retrying(retryID))
                manager.retryWorkspaceChooser()
                XCTAssertEqual(manager.workspaceChooserPresentation.failure?.recovery, .retrying(retryID), "a repeated click coalesces")

                await f.awaitCatalogRefresh(window)
                let receipts = events.catalogCheckpoints.compactMap(\.catalogReceipt)
                XCTAssertEqual(receipts.count, 2, "initial incomplete plus one coalesced repair: \(receipts)")
                XCTAssertEqual(receipts.last?.kind, .full)
                XCTAssertEqual(receipts.last?.completeness, .complete)
                guard case let .ready(catalog, .current) = manager.workspaceChooserPresentation else {
                    return XCTFail("repaired retry reaches accepted membership: \(manager.workspaceChooserPresentation)")
                }
                XCTAssertEqual(Set(catalog.workspaces.map(\.id)), Fixture.standardIDs)
                XCTAssertNil(manager.domainWorkspaceAuthorityIssue, "the covered projection issue recovers")
                for query in [WorkspaceChooserQuery.compact(maxRecent: 5), .expanded(collection: .saved, searchText: "")] {
                    let value = try chooser.consume(query)
                    XCTAssertEqual(value.kind, .ready)
                    XCTAssertEqual(value.orderedIDs, [Fixture.aardvarkID, Fixture.requestedID])
                    XCTAssertNil(value.failure)
                }
            }
        }

        func testCatalogAttemptsOrderBySequenceThenGenerationAndClearOnlyTheirWitnesses() async throws {
            try await Fixture.run { f in
                let manager = f.makeManager()
                let base = await f.runtime.workspaceStore.snapshot()
                let models = try f.decoded(base)
                @MainActor func snapshot(_ sequence: UInt64, health: DomainAuthorityHealth = .writable) -> DomainWorkspaceCatalogSnapshot {
                    f.catalog(base, sequence: sequence, catalogRevision: sequence, health: health)
                }
                @MainActor func full(_ sequence: UInt64, _ attempt: DomainCatalogAttempt, health: DomainAuthorityHealth = .writable)
                    -> DomainCatalogApplicationResult
                {
                    manager.applyDomainWorkspaceCatalog(
                        snapshot(sequence, health: health), projection: .full(models), preferredActiveWorkspaceID: nil,
                        rootMapPolicy: .decodedModels, attempt: attempt
                    )
                }
                @MainActor func metadata(_ sequence: UInt64, _ attempt: DomainCatalogAttempt) -> DomainCatalogApplicationResult {
                    manager.applyDomainWorkspaceCatalog(
                        snapshot(sequence),
                        projection: .metadata(baselineGeneration: manager.domainCatalogReconciliationGeneration),
                        preferredActiveWorkspaceID: nil, rootMapPolicy: .decodedModels, attempt: attempt
                    )
                }
                @MainActor func report(_ diagnostic: String, _ sequence: UInt64, _ attempt: DomainCatalogAttempt) -> Bool {
                    manager.reportDomainCatalogFailure(.modelProjection(diagnostic), snapshot: snapshot(sequence), attempt: attempt)
                }
                var presentedFailure: WorkspaceChooserFailure? {
                    manager.workspaceChooserPresentation.failure
                }

                // Sequence first, then attempt generation: a late same-sequence attempt never replaces.
                let a1 = manager.beginDomainCatalogAttempt()
                let a2 = manager.beginDomainCatalogAttempt()
                XCTAssertTrue(report("cause", 5, a2))
                let f1 = try XCTUnwrap(presentedFailure)
                guard case .failed = manager.workspaceChooserPresentation else { return XCTFail("no accepted catalog: no rows") }
                let l1 = try XCTUnwrap(manager.domainWorkspaceAuthorityIssue?.id)
                XCTAssertEqual(f1.legacyIssue?.issueID, l1)
                XCTAssertFalse(report("other cause", 5, a1), "an older same-sequence attempt cannot replace a newer report")
                XCTAssertEqual(presentedFailure, f1)
                let a3 = manager.beginDomainCatalogAttempt()
                XCTAssertTrue(report("cause", 5, a3))
                let f1v2 = try XCTUnwrap(presentedFailure)
                XCTAssertEqual(f1v2.id, f1.id, "an equivalent cause keeps its stable ID")
                XCTAssertGreaterThan(f1v2.reportVersion, f1.reportVersion)
                XCTAssertEqual(f1v2.legacyIssue?.issueID, l1, "the deduplicated legacy issue keeps its actual ID")
                XCTAssertNotEqual(f1v2.legacyIssue?.reportGeneration, f1.legacyIssue?.reportGeneration)

                // An attempt that began before a newer equivalent report updates rows but cannot clear it.
                let a4 = manager.beginDomainCatalogAttempt()
                let a5 = manager.beginDomainCatalogAttempt()
                XCTAssertTrue(report("cause", 5, a5))
                let f1v3 = try XCTUnwrap(presentedFailure)
                XCTAssertTrue(full(6, a4).receipt?.completeness == .complete)
                guard case let .ready(catalog6, .failed(retained)) = manager.workspaceChooserPresentation else {
                    return XCTFail("old success must keep the newer warning: \(manager.workspaceChooserPresentation)")
                }
                XCTAssertEqual(Set(catalog6.workspaces.map(\.id)), Fixture.standardIDs, "accepted rows still update")
                XCTAssertEqual(retained, f1v3)
                XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.id, l1, "older full cannot clear the newer report")
                let a6 = manager.beginDomainCatalogAttempt()
                XCTAssertNotNil(full(6, a6).receipt, "equal-sequence retry is accepted")
                guard case .ready(_, .current) = manager.workspaceChooserPresentation else {
                    return XCTFail("a current witness clears: \(manager.workspaceChooserPresentation)")
                }
                XCTAssertNil(manager.domainWorkspaceAuthorityIssue, "matching full clears the chooser's projection issue")
                XCTAssertEqual(full(6, a4), .rejected(.superseded), "late older completion at the same sequence")

                // Legacy non-catalog projection issue: same-payload newer report survives an older witness.
                struct NonCatalogFailure: LocalizedError {
                    var errorDescription: String? {
                        "non-catalog folder projection failure"
                    }
                }
                manager.reportDomainProjectionFailure(NonCatalogFailure())
                let l2 = try XCTUnwrap(manager.domainWorkspaceAuthorityIssue?.id)
                let b1 = manager.beginDomainCatalogAttempt()
                manager.reportDomainProjectionFailure(NonCatalogFailure())
                XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.id, l2, "publisher deduplicates the same payload")
                XCTAssertNotNil(full(7, b1).receipt)
                XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.id, l2, "same-payload newer report survives")
                XCTAssertNotNil(full(7, manager.beginDomainCatalogAttempt()).receipt)
                XCTAssertNil(manager.domainWorkspaceAuthorityIssue, "prior non-catalog projection issue clears on matching full")

                // Command issues have their own owner; catalog success never clears them.
                manager.reportDomainAuthorityFailure(NonCatalogFailure(), workspaceID: nil, operation: "fixture_command")
                XCTAssertNotNil(full(8, manager.beginDomainCatalogAttempt()).receipt)
                XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.kind, .commandFailure)

                // Metadata clears only a chooser-owned recovered projection issue.
                manager.reportDomainProjectionFailure(NonCatalogFailure())
                let l3 = try XCTUnwrap(manager.domainWorkspaceAuthorityIssue?.id)
                XCTAssertEqual(metadata(9, manager.beginDomainCatalogAttempt()).receipt?.kind, .metadata)
                XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.id, l3, "metadata never clears a non-chooser issue")
                XCTAssertTrue(report("changed digest", 9, manager.beginDomainCatalogAttempt()))
                let owned = try XCTUnwrap(presentedFailure)
                XCTAssertEqual(owned.legacyIssue?.issueID, manager.domainWorkspaceAuthorityIssue?.id)
                guard case .ready(_, .failed) = manager.workspaceChooserPresentation else {
                    return XCTFail("later failure retains accepted rows with a warning")
                }
                XCTAssertEqual(metadata(10, manager.beginDomainCatalogAttempt()).receipt?.completeness, .complete)
                guard case .ready(_, .current) = manager.workspaceChooserPresentation else {
                    return XCTFail("unchanged-digest recovery clears the eligible failure")
                }
                XCTAssertNil(manager.domainWorkspaceAuthorityIssue, "metadata clears the chooser-owned recovered issue")

                // Health-only failure: an older attempt cannot clear it; a current metadata recovery can.
                let d0 = manager.beginDomainCatalogAttempt()
                let degraded = DomainAuthorityHealth.degradedReadOnly(reason: "workspace_index_decode_failed")
                XCTAssertEqual(
                    full(11, manager.beginDomainCatalogAttempt(), health: degraded).receipt?.completeness.failure?.kind,
                    .authorityUnavailable(degraded)
                )
                let healthFailure = try XCTUnwrap(presentedFailure)
                XCTAssertEqual(metadata(12, d0).receipt?.completeness, .complete)
                XCTAssertEqual(presentedFailure, healthFailure, "an older completion never clears a newer error")
                XCTAssertEqual(metadata(13, manager.beginDomainCatalogAttempt()).receipt?.kind, .metadata)
                guard case let .ready(recovered, .current) = manager.workspaceChooserPresentation else {
                    return XCTFail("current health recovery clears: \(manager.workspaceChooserPresentation)")
                }
                XCTAssertEqual(Set(recovered.workspaces.map(\.id)), Fixture.standardIDs)
            }
        }

        func testStaleFirstApplicationRefetchesOnceThenFailsVisiblyAndUnsuccessfulRetryReturnsIdle() async throws {
            try await Fixture.run { f in
                let (window, manager, chooser, events) = await f.makeWindowWithHeldInitialProjection()
                let before = await f.runtime.workspaceStore.snapshot()
                let system = try XCTUnwrap(before.workspaces.first { $0.document.workspaceID == Fixture.defaultID })
                // A baseline-only command outcome taught the manager a floor above the current catalog.
                manager.applyDomainAuthorityBaseline(
                    workspaceID: Fixture.defaultID, revisions: system.revisions, digest: system.document.contentDigest,
                    health: system.health, catalogRevision: before.catalogRevision + 2
                )
                window.restartDomainWorkspaceProjectionForTesting()
                try await f.wait(events.resolution(through: before.publicationSequence))
                XCTAssertTrue(events.catalogCheckpoints.isEmpty)
                XCTAssertEqual(
                    events.events.count(where: { if case .rejected = $0 { true } else { false } }),
                    1,
                    "one refetch, then one resolved rejection: \(events.events)"
                )
                guard case let .failed(failure) = manager.workspaceChooserPresentation else {
                    return XCTFail("a blocked first application must not stay loading: \(manager.workspaceChooserPresentation)")
                }
                XCTAssertEqual(failure.kind, .catalogChangedDuringRefresh)
                XCTAssertEqual(failure.recovery, .idle)
                XCTAssertEqual(try chooser.consume(.compact(maxRecent: 5)).orderedIDs, [])

                manager.retryWorkspaceChooser()
                XCTAssertEqual(manager.workspaceChooserPresentation.failure?.recovery.isRetrying, true)
                await f.awaitCatalogRefresh(window)
                guard case let .failed(again) = manager.workspaceChooserPresentation else {
                    return XCTFail("an unsuccessful retry keeps the failure without rows: \(manager.workspaceChooserPresentation)")
                }
                XCTAssertEqual(again.id, failure.id, "equivalent cause keeps its stable ID")
                XCTAssertGreaterThan(again.reportVersion, failure.reportVersion)
                XCTAssertEqual(again.recovery, .idle, "terminal failure returns to an enabled Retry")
                XCTAssertEqual(try chooser.consume(.expanded(collection: .saved, searchText: "")).recovery, .idle)

                // Real commits reach the floor; the event's current witness clears the covered failure.
                let c = try await f.commitWorkspace(named: "Floor C", window: window, awaitProjection: false)
                let d = try await f.commitWorkspace(named: "Floor D", window: window)
                XCTAssertEqual(events.catalogCheckpoints.last?.catalogReceipt?.completeness, .complete)
                guard case let .ready(catalog, .current) = manager.workspaceChooserPresentation else {
                    return XCTFail("accepted current catalog clears the failure: \(manager.workspaceChooserPresentation)")
                }
                XCTAssertEqual(Set(catalog.workspaces.map(\.id)), Fixture.standardIDs.union([c.id, d.id]))
                XCTAssertEqual(try chooser.consume(.compact(maxRecent: 10)).kind, .ready)
            }
        }

        func testInitialIncompleteCatalogRendersAvailableRowsInBothLayoutsAndRetryRepairsMissingDocuments() async throws {
            let missingCID = try XCTUnwrap(UUID(uuidString: "C0000000-0000-0000-0000-000000000007"))
            let ghostID = try XCTUnwrap(UUID(uuidString: "6B000000-0000-0000-0000-000000000008"))
            let missingC = Fixture.model(id: missingCID, name: "Missing C")
            let ghost = Fixture.model(id: ghostID, name: "Legacy ghost G")
            let seeds = Fixture.standardSeeds + [missingC, ghost]
            try await Fixture.run(seeds: seeds, unavailableSeedIDs: [Fixture.requestedID, missingCID]) { f in
                try await f.deleteAndRestoreLegacyGhost(ghost)
                let (window, manager, chooser, _) = await f.makeWindowWithHeldInitialProjection()
                XCTAssertNotNil(manager.workspace(withID: ghostID), "constructor really loads the decodable ghost")
                let hosts = [WorkspaceLandingView.LayoutStyle.compact, .expanded].map { layout in
                    let host = NSHostingView(rootView: WorkspaceLandingView(
                        workspaceManager: manager, onOpenWorkspace: { _ in }, onManageWorkspaces: {}, onSelectFolder: {},
                        maxRecent: 5, maxWidth: 700, layoutStyle: layout
                    ))
                    host.frame = NSRect(x: 0, y: 0, width: 800, height: 650)
                    return host
                }
                window.restartDomainWorkspaceProjectionForTesting()
                let initialCheckpoint = try await f.awaitCatalogProjection(window)
                let initial = try XCTUnwrap(initialCheckpoint.catalogReceipt)
                XCTAssertEqual(initial.kind, .full)
                let unavailable = try XCTUnwrap(initial.completeness.failure)
                XCTAssertEqual(unavailable.kind, .unavailableMembers([Fixture.requestedID, missingCID]))
                let catalogRevision = await f.runtime.workspaceStore.snapshot().catalogRevision

                /// Latest actual Landing consumption per layout after re-laying out the same hosts.
                @MainActor func landing(
                    _ expected: [UUID], failure: WorkspaceChooserFailure.Kind?, complete: Bool, _ context: String
                ) async throws {
                    try await f.relayout(hosts) {
                        [.compact, .expanded].allSatisfy { layout in
                            chooser.consumed.last { $0.layout == layout }.map {
                                $0.kind == .ready && $0.orderedIDs == expected && $0.failure?.kind == failure
                            } ?? false
                        }
                    }
                    for layout in [WorkspaceChooserConsumption.Layout.compact, .expanded] {
                        let value = try XCTUnwrap(chooser.consumed.last { $0.layout == layout }, context)
                        XCTAssertEqual(value.kind, .ready, "\(context) \(layout)")
                        XCTAssertEqual(value.orderedIDs, expected, "\(context) \(layout)")
                        XCTAssertEqual(value.failure?.kind, failure, "\(context) \(layout)")
                        guard case let .authority(stamp) = value.source else { return XCTFail("\(context): authority rows") }
                        XCTAssertEqual(stamp.isComplete, complete, "\(context) \(layout)")
                    }
                }
                try await landing([Fixture.aardvarkID], failure: unavailable.kind, complete: false, "initial incomplete")
                let afterAcceptance = chooser.consumed.count

                // A later rejected decode (real authority reload) retains the accepted subset and warning.
                manager.setCatalogRecordDecodeFailureForTesting { $0 == Fixture.aardvarkID ? InjectedDecodeFailure() : nil }
                manager.reloadWorkspacesFromDisk()
                await manager.awaitWorkspaceReloadForTesting()
                manager.setCatalogRecordDecodeFailureForTesting(nil)
                let rejected = WorkspaceChooserFailure.Kind.modelProjection(InjectedDecodeFailure.diagnostic)
                try await landing([Fixture.aardvarkID], failure: rejected, complete: false, "later rejection")

                // Retry after repairing B: the accepted subset gains B; C keeps the warning.
                try f.writeSeedDocument(Fixture.requestedID)
                manager.retryWorkspaceChooser()
                XCTAssertEqual(manager.workspaceChooserPresentation.failure?.recovery.isRetrying, true)
                await f.awaitCatalogRefresh(window)
                try await f.awaitCatalogProjection(window)
                try await landing(
                    [Fixture.aardvarkID, Fixture.requestedID], failure: .unavailableMembers([missingCID]), complete: false, "B repaired"
                )

                // Retry after repairing C: complete health removes the covered warning.
                try f.writeSeedDocument(missingCID)
                manager.retryWorkspaceChooser()
                await f.awaitCatalogRefresh(window)
                try await f.awaitCatalogProjection(window)
                try await landing(
                    [Fixture.aardvarkID, missingCID, Fixture.requestedID], failure: nil, complete: true, "C repaired"
                )
                let repaired = await f.runtime.workspaceStore.snapshot()
                XCTAssertEqual(repaired.catalogRevision, catalogRevision, "document recovery needs no catalog mutation")
                XCTAssertEqual(repaired.unavailableWorkspaceIDs, [])
                XCTAssertFalse(chooser.consumed.contains { $0.kind == .ready && $0.orderedIDs.contains(ghostID) }, "G never consumed")
                XCTAssertFalse(
                    chooser.consumed[afterAcceptance...].contains { $0.kind != .ready },
                    "after acceptance, rejection/retry never falls back to loading or row-less failure"
                )
            }
        }

        func testDegradedAndSystemOnlyIncompleteCatalogsNeverRenderHealthyEmpty() async throws {
            @MainActor func assertIncompleteEmpty(
                _ chooser: ChooserRecorder, _ kind: WorkspaceChooserFailure.Kind, _ context: String
            ) throws {
                for query in [
                    WorkspaceChooserQuery.compact(maxRecent: 5),
                    .expanded(collection: .saved, searchText: ""),
                    .expanded(collection: .temporary, searchText: ""),
                    .expanded(collection: .saved, searchText: "none")
                ] {
                    let value = try chooser.consume(query)
                    XCTAssertEqual(value.kind, .ready, "\(context) \(query)")
                    XCTAssertEqual(value.orderedIDs, [], "\(context) \(query)")
                    XCTAssertEqual(value.failure?.kind, kind, "\(context): available-empty keeps the warning")
                    guard case let .authority(stamp) = value.source else { return XCTFail("\(context): authority source") }
                    XCTAssertFalse(stamp.isComplete, "\(context): never healthy empty")
                }
            }
            // Malformed isolated legacy index before startup: aggregate degradation with zero records.
            try await Fixture.run(seeds: [], beforeRuntimeStart: { try $0.writeLegacyIndex(nil) }) { f in
                let (window, manager, chooser, _) = await f.makeWindowWithHeldInitialProjection()
                window.restartDomainWorkspaceProjectionForTesting()
                let checkpoint = try await f.awaitCatalogProjection(window)
                let degraded = DomainAuthorityHealth.degradedReadOnly(reason: "workspace_index_decode_failed")
                XCTAssertEqual(checkpoint.catalogReceipt?.completeness.failure?.kind, .authorityUnavailable(degraded))
                try assertIncompleteEmpty(chooser, .authorityUnavailable(degraded), "degraded aggregate")

                let repaired = Fixture.model(id: Fixture.aardvarkID, name: "Aardvark")
                try f.writeDocument(repaired)
                try f.writeLegacyIndex([repaired])
                manager.retryWorkspaceChooser()
                await f.awaitCatalogRefresh(window)
                try await f.awaitCatalogProjection(window)
                guard case let .ready(catalog, .current) = manager.workspaceChooserPresentation else {
                    return XCTFail("repaired aggregate recovers through Retry: \(manager.workspaceChooserPresentation)")
                }
                XCTAssertEqual(catalog.workspaces.map(\.id), [Fixture.aardvarkID])
            }
            // Writable aggregate whose only available record is System, with an unavailable member.
            try await Fixture.run(
                seeds: [Fixture.standardSeeds[0], Fixture.standardSeeds[1]], unavailableSeedIDs: [Fixture.aardvarkID]
            ) { f in
                let (window, _, chooser, _) = await f.makeWindowWithHeldInitialProjection()
                window.restartDomainWorkspaceProjectionForTesting()
                let checkpoint = try await f.awaitCatalogProjection(window)
                XCTAssertEqual(checkpoint.catalogReceipt?.completeness.failure?.kind, .unavailableMembers([Fixture.aardvarkID]))
                try assertIncompleteEmpty(chooser, .unavailableMembers([Fixture.aardvarkID]), "System-only incomplete")
            }
        }

        func testDuplicateCleanupNeverClassifiesAgainstARejectedCatalogApplication() async throws {
            var canonical = Fixture.model(id: Fixture.aardvarkID, name: "Aardvark")
            canonical.repoPaths = ["/tmp/issue1142-duplicate-root"]
            canonical.lastUsed = Date(timeIntervalSince1970: 200)
            var duplicate = Fixture.model(id: Fixture.requestedID, name: "Z requested")
            duplicate.repoPaths = canonical.repoPaths
            duplicate.lastUsed = Date(timeIntervalSince1970: 100)
            try await Fixture.run(seeds: [Fixture.standardSeeds[0], canonical, duplicate]) { f in
                let manager = f.makeManager()
                manager.setDuplicateCleanupBackupDirectoryForTesting(f.base.appendingPathComponent("backups", isDirectory: true))
                let previousWindows = WindowStatesManager.shared.allWindows
                WindowStatesManager.shared.allWindows = []
                defer { WindowStatesManager.shared.allWindows = previousWindows }
                let snapshot = await f.runtime.workspaceStore.snapshot()
                let system = try XCTUnwrap(snapshot.workspaces.first { $0.document.workspaceID == Fixture.defaultID })
                // A baseline-only floor above the authority makes the cleanup's own application stale.
                manager.applyDomainAuthorityBaseline(
                    workspaceID: Fixture.defaultID, revisions: system.revisions, digest: system.document.contentDigest,
                    health: system.health, catalogRevision: snapshot.catalogRevision + 5
                )
                let cleanup = await manager.consolidateDuplicateWorkspaces()
                XCTAssertEqual(cleanup.groupsDetected, 1)
                XCTAssertEqual(cleanup.groupsConsolidated, 0, "a rejected application is not a reconciliation")
                XCTAssertTrue(cleanup.retiredWorkspaceIDs.isEmpty)
                XCTAssertTrue(cleanup.skipped.contains {
                    $0.workspaceID == duplicate.id && $0.reason.hasPrefix("authority_snapshot_unavailable")
                }, "\(cleanup.skipped)")
                XCTAssertEqual(manager.domainCatalogReconciliationGeneration, 0)
                XCTAssertNotNil(manager.workspace(withID: duplicate.id))
                let after = await f.runtime.workspaceStore.snapshot()
                XCTAssertEqual(after.catalogRevision, snapshot.catalogRevision, "no authority mutation")
            }
        }

        func testRetryCancellationByStopOrClosePublishesNoArtificialError() async throws {
            // Stop before close: the matching retry returns to idle; rows/identity/version unchanged.
            try await Fixture.run { f in
                let (window, manager, chooser, events) = await f.makeWindowWithHeldInitialProjection()
                manager.setCatalogRecordDecodeFailureForTesting { $0 == Fixture.aardvarkID ? InjectedDecodeFailure() : nil }
                window.restartDomainWorkspaceProjectionForTesting()
                let snapshot = await f.runtime.workspaceStore.snapshot()
                try await f.wait(events.resolution(through: snapshot.publicationSequence))
                let idle = manager.workspaceChooserPresentation
                XCTAssertNotNil(idle.failure)
                manager.retryWorkspaceChooser()
                XCTAssertEqual(manager.workspaceChooserPresentation.failure?.recovery.isRetrying, true)
                await window.joinDomainWorkspaceBridgeForTesting()
                XCTAssertEqual(manager.workspaceChooserPresentation, idle, "cancellation preserves prior rows, warning, and witnesses")
                XCTAssertEqual(try chooser.consume(.compact(maxRecent: 5)).recovery, .idle)
            }
            // Close: cancellation runs after closing is marked; nothing publishes afterwards.
            try await Fixture.run { f in
                let (window, manager, chooser, events) = await f.makeWindowWithHeldInitialProjection()
                manager.setCatalogRecordDecodeFailureForTesting { $0 == Fixture.aardvarkID ? InjectedDecodeFailure() : nil }
                window.restartDomainWorkspaceProjectionForTesting()
                let snapshot = await f.runtime.workspaceStore.snapshot()
                try await f.wait(events.resolution(through: snapshot.publicationSequence))
                manager.retryWorkspaceChooser()
                let retrying = manager.workspaceChooserPresentation
                XCTAssertEqual(retrying.failure?.recovery.isRetrying, true)
                let emittedAtClose = chooser.emitted.count
                window.beginClose()
                manager.retryWorkspaceChooser()
                await window.joinDomainWorkspaceBridgeForTesting()
                XCTAssertEqual(chooser.emitted.count, emittedAtClose, "no post-close idle/error/retry publication")
                XCTAssertEqual(manager.workspaceChooserPresentation, retrying)
            }
        }

        func testUnacceptedImportRequestsOneRefreshThatReconcilesFully() async throws {
            try await Fixture.run { f in
                let (window, manager, chooser, events) = await f.makeWindowWithHeldInitialProjection()
                window.restartDomainWorkspaceProjectionForTesting()
                try await f.awaitCaughtUpWithCatalogBaseline(window)
                let accepted = manager.workspaceChooserPresentation
                let ghost = Fixture.model(id: UUID(), name: "Imported ghost")
                let acceptedBefore = events.catalogCheckpoints.count
                manager.replaceWorkspacesFromUnacceptedImport(manager.workspaces + [ghost])
                XCTAssertEqual(manager.workspaceChooserPresentation, accepted, "fence retains accepted rows")
                await f.awaitCatalogRefresh(window)
                let refreshed = events.catalogCheckpoints.dropFirst(acceptedBefore).compactMap(\.catalogReceipt)
                XCTAssertEqual(refreshed.map(\.kind), [.full], "the fence's one refresh is a full reconciliation")
                XCTAssertNil(manager.workspace(withID: ghost.id), "accepted full reconciliation replaces the import")
                guard case let .ready(catalog, .current) = manager.workspaceChooserPresentation else {
                    return XCTFail("refresh reconciles: \(manager.workspaceChooserPresentation)")
                }
                XCTAssertEqual(Set(catalog.workspaces.map(\.id)), Fixture.standardIDs)
                XCTAssertFalse(chooser.emitted.contains {
                    if case let .ready(catalog, _) = $0 { return catalog.workspaces.contains { $0.id == ghost.id } }
                    return false
                })
            }
        }

        // MARK: #1142 review regressions

        func testEquivalentFailureReportsAdvanceWitnessesWithoutRepublishingUnchangedChooser() async throws {
            for acceptedBaseline in [false, true] {
                try await Fixture.run { f in
                    let manager = f.makeManager()
                    let chooser = f.makeChooserRecorder(manager: manager)
                    let snapshot = await f.runtime.workspaceStore.snapshot()
                    let models = try f.decoded(snapshot)
                    if acceptedBaseline {
                        XCTAssertNotNil(manager.applyDomainWorkspaceCatalog(snapshot, projection: .full(models), preferredActiveWorkspaceID: nil, rootMapPolicy: .decodedModels).receipt)
                    }
                    XCTAssertTrue(manager.reportDomainCatalogFailure(.modelProjection("equivalent cause"), snapshot: snapshot, attempt: manager.beginDomainCatalogAttempt()))
                    let first = try XCTUnwrap(manager.workspaceChooserPresentation.failure)
                    let olderClearance = manager.beginDomainCatalogAttempt()
                    let emissions = chooser.emitted.count
                    var invalidations = 0
                    let objectChanges = manager.objectWillChange.sink { invalidations += 1 }
                    defer { objectChanges.cancel() }
                    let repeatedAttempt = manager.beginDomainCatalogAttempt()
                    XCTAssertTrue(manager.reportDomainCatalogFailure(.modelProjection("equivalent cause"), snapshot: snapshot, attempt: repeatedAttempt))
                    let latest = try XCTUnwrap(manager.workspaceChooserPresentation.failure)
                    XCTAssertEqual(latest.id, first.id)
                    XCTAssertGreaterThan(latest.reportVersion, first.reportVersion)
                    XCTAssertNotEqual(latest.legacyIssue, first.legacyIssue)
                    XCTAssertEqual(chooser.emitted.count, emissions, "witness-only report is not a chooser UI change")
                    XCTAssertEqual(invalidations, 0, "witness-only report must not invalidate SwiftUI")
                    XCTAssertEqual(try chooser.consume(.compact(maxRecent: 5)).failure, latest, "actual consumer reads fresh full witnesses")
                    var initialForNewSubscriber: WorkspaceChooserPresentation?
                    let newSubscriber = manager.$workspaceChooserPresentation.sink { initialForNewSubscriber = $0 }
                    newSubscriber.cancel()
                    XCTAssertEqual(initialForNewSubscriber?.failure, latest, "new subscriptions receive the latest stored value, not the last emitted value")

                    let covering = f.catalog(snapshot, sequence: snapshot.publicationSequence + 1, catalogRevision: snapshot.catalogRevision)
                    XCTAssertNotNil(manager.applyDomainWorkspaceCatalog(covering, projection: .full(models), preferredActiveWorkspaceID: nil, rootMapPolicy: .decodedModels, attempt: olderClearance).receipt)
                    XCTAssertEqual(manager.workspaceChooserPresentation.failure, latest, "old captured witness cannot clear the silent newer report")
                    XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.id, latest.legacyIssue?.issueID)
                    let beforeRetry = chooser.emitted.count
                    XCTAssertTrue(manager.beginWorkspaceChooserRetry(UUID()))
                    XCTAssertEqual(chooser.emitted.count, beforeRetry + 1)
                    XCTAssertTrue(try chooser.consume(.compact(maxRecent: 5)).recovery.isRetrying)
                    XCTAssertTrue(manager.reportDomainCatalogFailure(.modelProjection("equivalent cause"), snapshot: covering, attempt: manager.beginDomainCatalogAttempt()))
                    let idle = try XCTUnwrap(manager.workspaceChooserPresentation.failure)
                    XCTAssertEqual(idle.id, latest.id)
                    XCTAssertGreaterThan(idle.reportVersion, latest.reportVersion)
                    XCTAssertEqual(idle.recovery, .idle)
                    XCTAssertEqual(chooser.emitted.count, beforeRetry + 2, "retrying-to-idle is a real UI change")
                    XCTAssertEqual(try chooser.consume(.compact(maxRecent: 5)).recovery, .idle)
                    XCTAssertTrue(manager.beginWorkspaceChooserRetry(UUID()))
                    let currentRetry = manager.beginDomainCatalogAttempt()
                    XCTAssertNotNil(manager.applyDomainWorkspaceCatalog(covering, projection: .full(models), preferredActiveWorkspaceID: nil, rootMapPolicy: .decodedModels, attempt: currentRetry).receipt)
                    XCTAssertNil(manager.workspaceChooserPresentation.failure)
                    XCTAssertNil(manager.domainWorkspaceAuthorityIssue)
                    XCTAssertNil(try chooser.consume(.compact(maxRecent: 5)).failure)
                }
            }
        }

        func testReentrantTerminalReportDuringRetryEmissionKeepsNewestIdleWitness() async throws {
            try await Fixture.run { f in
                let manager = f.makeManager()
                let chooser = f.makeChooserRecorder(manager: manager)
                let snapshot = await f.runtime.workspaceStore.snapshot()
                XCTAssertTrue(manager.reportDomainCatalogFailure(.modelProjection("same cause"), snapshot: snapshot, attempt: manager.beginDomainCatalogAttempt()))
                let first = try XCTUnwrap(manager.workspaceChooserPresentation.failure)
                var newer: WorkspaceChooserFailure?
                var fired = false
                let subscription = manager.$workspaceChooserPresentation.dropFirst().sink { value in
                    guard value.failure?.recovery.isRetrying == true, !fired else { return }
                    fired = true
                    // Getter is still idle, but the announced retry must be reset by this newer report.
                    XCTAssertEqual(manager.workspaceChooserPresentation.failure?.recovery, .idle)
                    XCTAssertTrue(manager.reportDomainCatalogFailure(.modelProjection("same cause"), snapshot: snapshot, attempt: manager.beginDomainCatalogAttempt()))
                    newer = manager.workspaceChooserPresentation.failure
                }
                defer { subscription.cancel() }
                XCTAssertTrue(manager.beginWorkspaceChooserRetry(UUID()))
                XCTAssertTrue(fired)
                let latest = try XCTUnwrap(newer)
                XCTAssertEqual(latest.id, first.id)
                XCTAssertGreaterThan(latest.reportVersion, first.reportVersion)
                XCTAssertEqual(manager.workspaceChooserPresentation.failure, latest, "returning older setter cannot overwrite the reentrant report")
                XCTAssertEqual(try chooser.consume(.compact(maxRecent: 5)).failure, latest)
                XCTAssertEqual(latest.recovery, .idle)
                XCTAssertTrue(chooser.emitted.contains { $0.failure == latest }, "newer idle must be emitted after the announced retry, regardless of subscriber order")
                var initial: WorkspaceChooserPresentation?
                let newSubscription = manager.$workspaceChooserPresentation.sink { initial = $0 }
                newSubscription.cancel()
                XCTAssertEqual(initial?.failure, latest)
            }
        }

        func testSynchronousRestartFromReadyRequiresNewRunFirstFullCatalog() async throws {
            try await Fixture.run { f in
                let (window, manager, _, events) = await f.makeWindowWithHeldInitialProjection()
                let bridge = try XCTUnwrap(window.domainWorkspacePresentationBridgeForTesting)
                var retiredRun: UUID?
                let restarted = Signal("restart from ready emission")
                var didRestart = false
                let observation = manager.$workspaceChooserPresentation.sink { value in
                    guard case .ready = value, !didRestart else { return }
                    didRestart = true
                    retiredRun = bridge.projectionObservationStateForTesting.runID
                    bridge.stop()
                    bridge.start()
                    restarted.fire()
                }
                defer { observation.cancel() }
                bridge.start()
                try await f.wait(restarted)
                let checkpoint = try await f.awaitCatalogProjection(window)
                XCTAssertNotEqual(checkpoint.runID, retiredRun)
                XCTAssertEqual(checkpoint.catalogReceipt?.kind, .full)
                XCTAssertFalse(events.catalogCheckpoints.contains { $0.runID == retiredRun })
            }
        }

        func testCrossedCatalogDocumentIdentitiesRejectDecoderAndIncompleteAdmission() async throws {
            // Decoder/admission defense, not end-to-end authority ingestion: bootstrap already rejects crossed seed IDs.
            try await Fixture.run { f in
                let manager = f.makeManager()
                let snapshot = await f.runtime.workspaceStore.snapshot()
                var records: [DomainWorkspaceSnapshot] = []
                for record in snapshot.workspaces {
                    let id = record.document.workspaceID
                    let crossedID = id == Fixture.aardvarkID ? Fixture.requestedID : Fixture.aardvarkID
                    var bytes = try Data(contentsOf: record.document.fileURL)
                    if id != Fixture.defaultID {
                        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                        json["id"] = crossedID.uuidString
                        bytes = try JSONSerialization.data(withJSONObject: json)
                    }
                    let document = DomainWorkspaceDocument(workspaceID: id, fileURL: record.document.fileURL, documentBytes: bytes, metadata: record.document.metadata)
                    var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
                    envelope["document"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document))
                    try records.append(JSONDecoder().decode(DomainWorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: envelope)))
                }
                let unchecked = try records.map {
                    try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(documentBytes: $0.document.documentBytes, fileURL: $0.document.fileURL)
                }
                XCTAssertEqual(Set(unchecked.map(\.id)), Fixture.standardIDs, "set equality alone cannot detect crossed identities")
                for record in records where record.document.workspaceID != Fixture.defaultID {
                    XCTAssertThrowsError(try manager.decodeDomainWorkspaceCatalogRecord(record))
                }
                let decoded = records.compactMap { try? manager.decodeDomainWorkspaceCatalogRecord($0) }
                let result = manager.applyDomainWorkspaceCatalog(snapshot, projection: .full(decoded), preferredActiveWorkspaceID: nil, rootMapPolicy: .decodedModels)
                XCTAssertEqual(result.rejection, .invalidCatalog("model_set_mismatch"))
                XCTAssertEqual(manager.domainCatalogReconciliationGeneration, 0)
                XCTAssertNotNil(manager.workspaceChooserPresentation.failure)
            }
        }

        func testCatalogFailureRechecksCloseAndCancellationAfterLegacyIssueEmission() async throws {
            for closes in [true, false] {
                try await Fixture.run { f in
                    let (window, manager, chooser, events) = await f.makeWindowWithHeldInitialProjection()
                    let snapshot = await f.runtime.workspaceStore.snapshot()
                    let interrupted = Signal("failure legacy issue reentered lifetime")
                    var emissionsAtInterruption: Int?
                    let observation = manager.$domainWorkspaceAuthorityIssue.sink { issue in
                        guard issue != nil else { return }
                        if closes { window.beginClose() } else { withUnsafeCurrentTask { $0?.cancel() } }
                        emissionsAtInterruption = chooser.emitted.count
                        interrupted.fire()
                    }
                    defer { observation.cancel() }
                    let report = Task { @MainActor in
                        manager.reportDomainCatalogFailure(
                            .modelProjection("catalog-wide failure"),
                            snapshot: snapshot,
                            attempt: manager.beginDomainCatalogAttempt()
                        )
                    }
                    let reported = await report.value
                    XCTAssertFalse(reported)
                    try await f.wait(interrupted)
                    await window.joinDomainWorkspaceBridgeForTesting()
                    XCTAssertEqual(chooser.emitted.count, emissionsAtInterruption)
                    XCTAssertEqual(manager.workspaceChooserPresentation, .loading)
                    XCTAssertEqual(try chooser.consume(.compact(maxRecent: 5)).kind, .loading)
                    XCTAssertTrue(events.catalogCheckpoints.isEmpty)
                }
            }
        }

        func testHeldOlderReloadCannotReportDecodeFailureAfterRealSelfEcho() async throws {
            try await Fixture.run { f in
                let (window, manager, chooser, _) = await f.makeWindowWithHeldInitialProjection()
                window.restartDomainWorkspaceProjectionForTesting()
                let initial = try await f.awaitCatalogProjection(window)
                let bridge = try XCTUnwrap(window.domainWorkspacePresentationBridgeForTesting)
                let before = await f.runtime.workspaceStore.snapshot()
                let record = try XCTUnwrap(before.workspaces.first { $0.document.workspaceID == Fixture.aardvarkID })
                let gate = f.makeGate()
                let entered = Signal("older real reload held before application")
                let heldIO = f.startOwned { await gate.wait() }
                bridge.afterCatalogReloadForTesting = { entered.fire()
                    await heldIO.value
                }
                bridge.requestCatalogRefresh(isRetry: false)
                try await f.wait(entered)
                var edited = try XCTUnwrap(manager.workspace(withID: Fixture.aardvarkID))
                edited.name = "Newer self echo"
                let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == edited.id })
                manager.workspaces[index] = edited
                let client = DomainWorkspaceAuthorityClient(store: f.runtime.workspaceStore, windowID: window.windowID)
                _ = try await client.replaceWorking(edited, fileURL: record.document.fileURL, expectedWorkspaceRevision: record.revisions.workingRevision, operationID: UUID())
                let current = await f.runtime.workspaceStore.snapshot()
                let echo = await f.projectionObserver(for: window).waitForProjection(afterGeneration: initial.generation, through: current.publicationSequence)
                XCTAssertEqual(echo?.application, .selfEchoBaseline)
                let caughtUp = try await f.awaitCaughtUpWithCatalogBaseline(window)
                XCTAssertEqual(caughtUp.publicationSequence, current.publicationSequence)
                XCTAssertEqual(caughtUp.application, .selfEchoBaseline)
                let currentCatalog = await f.projectionObserver(for: window).waitForProjection(afterGeneration: 0, through: current.publicationSequence, requireCatalogApplication: true, timeout: .zero)
                XCTAssertNil(currentCatalog, "current catch-up is not a current completeness receipt")
                var staleDecodes = 0
                manager.setCatalogRecordDecodeFailureForTesting { id in
                    guard id == Fixture.aardvarkID else { return nil }
                    staleDecodes += 1
                    return InjectedDecodeFailure()
                }
                gate.release()
                await f.awaitCatalogRefresh(window)
                XCTAssertEqual(staleDecodes, 0, "stale snapshot must be rejected before decode, then refetch current cache")
                XCTAssertNil(manager.workspaceChooserPresentation.failure)
                XCTAssertNil(manager.domainWorkspaceAuthorityIssue)
                XCTAssertEqual(try chooser.consume(.compact(maxRecent: 5)).kind, .ready)
                XCTAssertEqual(bridge.projectionObservationStateForTesting.catalogCheckpoint?.publicationSequence, initial.publicationSequence, "valid self echo catches up without certifying a newer catalog")
                bridge.afterCatalogReloadForTesting = nil
            }
        }

        func testOrdinaryCatalogFailureRejectsManagerPublicationAndCatalogFloors() async throws {
            for publicationFloor in [true, false] {
                try await Fixture.run { f in
                    let manager = f.makeManager()
                    let snapshot = await f.runtime.workspaceStore.snapshot()
                    let receipt = try XCTUnwrap(try manager.applyDomainWorkspaceCatalog(snapshot, projection: .full(f.decoded(snapshot)), preferredActiveWorkspaceID: nil, rootMapPolicy: .decodedModels).receipt)
                    let before = manager.workspaceChooserPresentation
                    let staleAttempt = manager.beginDomainCatalogAttempt()
                    let record = try XCTUnwrap(snapshot.workspaces.first)
                    if publicationFloor {
                        XCTAssertTrue(manager.acceptDomainAuthoritySelfEchoBaseline(
                            workspaceID: record.document.workspaceID, revisions: record.revisions,
                            digest: record.document.contentDigest, health: record.health, catalogRevision: snapshot.catalogRevision,
                            publicationSequence: snapshot.publicationSequence + 1, baselineGeneration: receipt.reconciliationGeneration
                        ))
                    } else {
                        manager.applyDomainAuthorityBaseline(workspaceID: record.document.workspaceID, revisions: record.revisions, digest: record.document.contentDigest, health: record.health, catalogRevision: snapshot.catalogRevision + 1)
                    }
                    XCTAssertFalse(manager.reportDomainCatalogFailure(.modelProjection("older decode"), snapshot: snapshot, attempt: staleAttempt))
                    XCTAssertEqual(manager.workspaceChooserPresentation, before)
                    XCTAssertNil(manager.domainWorkspaceAuthorityIssue)
                }
            }
        }

        func testFailedSaveFenceInvalidatesCachedRecordsWhenUnrelatedDigestChanges() async throws {
            try await Fixture.run { f in
                let (window, manager, chooser, events) = await f.makeWindowWithHeldInitialProjection()
                window.restartDomainWorkspaceProjectionForTesting()
                try await f.awaitCaughtUpWithCatalogBaseline(window)
                let snapshot = await f.runtime.workspaceStore.snapshot()
                let record = try XCTUnwrap(snapshot.workspaces.first)
                manager.beforeFailedSaveCatalogApplicationForTesting = { actual in
                    manager.applyDomainAuthorityBaseline(workspaceID: record.document.workspaceID, revisions: record.revisions, digest: record.document.contentDigest, health: record.health, catalogRevision: actual.catalogRevision + 1)
                }
                let reconciled = await manager.reconcileDuplicateCleanupAuthorityAfterFailedSaveForTesting()
                XCTAssertFalse(reconciled)
                manager.beforeFailedSaveCatalogApplicationForTesting = nil
                let applications = events.catalogCheckpoints.count
                var fencedDecodes = 0
                manager.setCatalogRecordDecodeFailureForTesting { id in
                    guard id == Fixture.aardvarkID else { return nil }
                    fencedDecodes += 1
                    return InjectedDecodeFailure()
                }
                let unrelated = try await f.commitWorkspace(named: "Unrelated changed record", window: window, awaitProjection: false)
                let changed = await f.runtime.workspaceStore.snapshot()
                try await f.wait(events.resolution(through: changed.publicationSequence))
                XCTAssertGreaterThan(fencedDecodes, 0, "the independent full-required fence must invalidate unchanged cached records")
                XCTAssertEqual(events.catalogCheckpoints.count, applications + 1, "available subset is accepted with a warning")
                XCTAssertNotNil(manager.workspaceChooserPresentation.failure)
                XCTAssertFalse(try chooser.consume(.compact(maxRecent: 10)).orderedIDs.contains(unrelated.id))
                manager.setCatalogRecordDecodeFailureForTesting(nil)
                manager.retryWorkspaceChooser()
                await f.awaitCatalogRefresh(window)
                XCTAssertNil(manager.workspaceChooserPresentation.failure)
                XCTAssertTrue(try chooser.consume(.compact(maxRecent: 10)).orderedIDs.contains(unrelated.id))
            }
        }

        func testFailureReportCannotOverwriteNewerFailureFromLegacyIssueSubscriber() async throws {
            try await Fixture.run { f in
                let manager = f.makeManager()
                let snapshot = await f.runtime.workspaceStore.snapshot()
                let older = manager.beginDomainCatalogAttempt()
                var newer: WorkspaceChooserFailure?
                var issueID: UUID?
                var fired = false
                let subscription = manager.$domainWorkspaceAuthorityIssue.dropFirst().sink { issue in
                    guard issue != nil, !fired else { return }
                    fired = true
                    XCTAssertTrue(manager.reportDomainCatalogFailure(.modelProjection("newer nested failure"), snapshot: snapshot, attempt: manager.beginDomainCatalogAttempt()))
                    newer = manager.workspaceChooserPresentation.failure
                    issueID = manager.domainWorkspaceAuthorityIssue?.id
                }
                defer { subscription.cancel() }
                XCTAssertFalse(manager.reportDomainCatalogFailure(.modelProjection("older outer failure"), snapshot: snapshot, attempt: older))
                XCTAssertTrue(fired)
                XCTAssertEqual(manager.workspaceChooserPresentation.failure, newer)
                XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.id, issueID)
                XCTAssertNotNil(issueID)
            }
        }

        func testReentrantNewerFailureSurvivesRecoveryReconciliationAndIssueClearance() async throws {
            for duringIssueClearance in [true, false] {
                try await Fixture.run { f in
                    let manager = f.makeManager()
                    let snapshot = await f.runtime.workspaceStore.snapshot()
                    let models = try f.decoded(snapshot)
                    XCTAssertNotNil(manager.applyDomainWorkspaceCatalog(snapshot, projection: .full(models), preferredActiveWorkspaceID: nil, rootMapPolicy: .decodedModels).receipt)
                    XCTAssertTrue(manager.reportDomainCatalogFailure(.modelProjection("same failure"), snapshot: snapshot, attempt: manager.beginDomainCatalogAttempt()))
                    var issueEmissions: [DomainWorkspaceAuthorityIssue?] = []
                    let issueObserver = manager.$domainWorkspaceAuthorityIssue.sink { issueEmissions.append($0) }
                    defer { issueObserver.cancel() }
                    let recovery = manager.beginDomainCatalogAttempt()
                    let intermediate = manager.beginDomainCatalogAttempt()
                    let generation = manager.domainCatalogReconciliationGeneration
                    var newer: WorkspaceChooserFailure?
                    var issueID: UUID?
                    var fired = false
                    @MainActor func reportNewer() {
                        guard !fired else { return }
                        fired = true
                        XCTAssertTrue(manager.reportDomainCatalogFailure(.modelProjection("same failure"), snapshot: snapshot, attempt: manager.beginDomainCatalogAttempt()))
                        newer = manager.workspaceChooserPresentation.failure
                        issueID = manager.domainWorkspaceAuthorityIssue?.id
                    }
                    let subscription: AnyCancellable = if duringIssueClearance {
                        manager.$domainWorkspaceAuthorityIssue.dropFirst().sink { issue in
                            if issue == nil { reportNewer() }
                        }
                    } else {
                        manager.$workspaces.dropFirst().sink { _ in reportNewer() }
                    }
                    defer { subscription.cancel() }
                    let result = manager.applyDomainWorkspaceCatalog(snapshot, projection: .full(models), preferredActiveWorkspaceID: nil, rootMapPolicy: .decodedModels, attempt: recovery)
                    XCTAssertTrue(fired)
                    XCTAssertEqual(result.rejection, .superseded)
                    XCTAssertEqual(manager.domainCatalogReconciliationGeneration, generation)
                    XCTAssertEqual(manager.workspaceChooserPresentation.failure, newer)
                    XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.id, issueID)
                    XCTAssertNotNil(issueID)
                    let finalEmission = issueEmissions.last ?? nil
                    XCTAssertEqual(finalEmission?.id, issueID, "clearance must replay the nested same-payload report")
                    XCTAssertFalse(manager.reportDomainCatalogFailure(.modelProjection("intermediate must remain superseded"), snapshot: snapshot, attempt: intermediate))
                    XCTAssertEqual(manager.workspaceChooserPresentation.failure, newer)
                    XCTAssertEqual(manager.domainWorkspaceAuthorityIssue?.id, issueID)
                }
            }
        }

        // MARK: #1142 Slice 7 — independent lifecycle fences

        func testHeldRetryCancellationReturnsMatchingFailureToIdleBeforeIOCompletes() async throws {
            try await Fixture.run { f in
                let (window, manager, chooser, events) = await f.makeWindowWithHeldInitialProjection()
                manager.setCatalogRecordDecodeFailureForTesting { $0 == Fixture.aardvarkID ? InjectedDecodeFailure() : nil }
                window.restartDomainWorkspaceProjectionForTesting()
                let snapshot = await f.runtime.workspaceStore.snapshot()
                try await f.wait(events.resolution(through: snapshot.publicationSequence))
                let idle = manager.workspaceChooserPresentation
                XCTAssertNotNil(idle.failure)
                let bridge = try XCTUnwrap(window.domainWorkspacePresentationBridgeForTesting)
                let gate = f.makeGate()
                let entered = Signal("real retry reload returned; completion held")
                let heldIO = f.startOwned { await gate.wait() }
                bridge.afterCatalogReloadForTesting = {
                    entered.fire()
                    await heldIO.value
                }
                manager.retryWorkspaceChooser()
                try await f.wait(entered)
                XCTAssertTrue(manager.workspaceChooserPresentation.failure?.recovery.isRetrying == true)
                bridge.cancelCatalogRefresh()
                XCTAssertEqual(manager.workspaceChooserPresentation, idle, "idle must publish before held I/O returns")
                XCTAssertEqual(try chooser.consume(.compact(maxRecent: 5)).recovery, .idle)
                bridge.afterCatalogReloadForTesting = nil
                gate.release()
                await window.joinDomainWorkspaceBridgeForTesting()
                XCTAssertEqual(manager.workspaceChooserPresentation, idle)
            }
        }

        func testCloseWhileRetryHeldRejectsNewRefreshAndSubscriptionRevival() async throws {
            try await Fixture.run { f in
                let (window, manager, chooser, events) = await f.makeWindowWithHeldInitialProjection()
                let (route, recorder) = f.makeRecordedRoute(for: window)
                route.evaluateInitialRouteIfNeeded()
                let routeStart = recorder.routes.count
                manager.setCatalogRecordDecodeFailureForTesting { $0 == Fixture.aardvarkID ? InjectedDecodeFailure() : nil }
                window.restartDomainWorkspaceProjectionForTesting()
                let snapshot = await f.runtime.workspaceStore.snapshot()
                try await f.wait(events.resolution(through: snapshot.publicationSequence))
                let bridge = try XCTUnwrap(window.domainWorkspacePresentationBridgeForTesting)
                let gate = f.makeGate()
                let entered = Signal("retry runtime I/O completed before close")
                let heldIO = f.startOwned { await gate.wait() }
                bridge.afterCatalogReloadForTesting = {
                    entered.fire()
                    await heldIO.value
                }
                manager.retryWorkspaceChooser()
                try await f.wait(entered)
                let presentationAtClose = manager.workspaceChooserPresentation
                let emissionCount = chooser.emitted.count
                let generationAtClose = bridge.projectionObservationStateForTesting.generation
                let activeAtClose = manager.activeWorkspaceID
                window.beginClose()
                var newRefreshes = 0
                bridge.afterCatalogReloadForTesting = { newRefreshes += 1 }
                bridge.requestCatalogRefresh(isRetry: false)
                manager.retryWorkspaceChooser()
                await f.awaitCatalogRefresh(window)
                XCTAssertEqual(newRefreshes, 0, "even nonretry refresh must be rejected before runtime I/O")
                bridge.stop()
                bridge.start()
                XCTAssertFalse(bridge.hasActiveSubscriptionForTesting, "close cannot revive the subscription")
                bridge.afterCatalogReloadForTesting = nil
                gate.release()
                await window.joinDomainWorkspaceBridgeForTesting()
                try await f.acknowledgeRouteConsumption(recorder)
                XCTAssertEqual(chooser.emitted.count, emissionCount)
                XCTAssertEqual(manager.workspaceChooserPresentation, presentationAtClose)
                XCTAssertEqual(bridge.projectionObservationStateForTesting.generation, generationAtClose)
                XCTAssertEqual(manager.activeWorkspaceID, activeAtClose)
                XCTAssertFalse(manager.test_isPollTimerActive)
                XCTAssertEqual(try chooser.consume(.expanded(collection: .saved, searchText: "")).kind, .ready)
                f.assertNoUnsolicitedSelection(recorder, routeStart: routeStart, context: "closed held retry")
            }
        }

        func testHeldOldRunRetryCannotCreditRestartedRun() async throws {
            try await Fixture.run { f in
                let (window, manager, chooser, events) = await f.makeWindowWithHeldInitialProjection()
                manager.setCatalogRecordDecodeFailureForTesting { $0 == Fixture.aardvarkID ? InjectedDecodeFailure() : nil }
                window.restartDomainWorkspaceProjectionForTesting()
                let snapshot = await f.runtime.workspaceStore.snapshot()
                try await f.wait(events.resolution(through: snapshot.publicationSequence))
                let bridge = try XCTUnwrap(window.domainWorkspacePresentationBridgeForTesting)
                let oldRun = try XCTUnwrap(bridge.projectionObservationStateForTesting.runID)
                let gate = f.makeGate()
                let entered = Signal("old run real retry reload returned")
                let heldIO = f.startOwned { await gate.wait() }
                bridge.afterCatalogReloadForTesting = {
                    entered.fire()
                    await heldIO.value
                }
                manager.retryWorkspaceChooser()
                try await f.wait(entered)
                bridge.stop()
                XCTAssertEqual(manager.workspaceChooserPresentation.failure?.recovery, .idle)
                bridge.afterCatalogReloadForTesting = nil
                manager.setCatalogRecordDecodeFailureForTesting(nil)
                window.restartDomainWorkspaceProjectionForTesting()
                let checkpoint = try await f.awaitCatalogProjection(window)
                XCTAssertNotEqual(checkpoint.runID, oldRun)
                XCTAssertEqual(checkpoint.catalogReceipt?.kind, .full)
                let presentation = manager.workspaceChooserPresentation
                let emissions = chooser.emitted.count
                let applications = events.catalogCheckpoints.count
                XCTAssertEqual(try chooser.consume(.compact(maxRecent: 5)).orderedIDs, [Fixture.aardvarkID, Fixture.requestedID])
                gate.release()
                await window.joinDomainWorkspaceBridgeForTesting()
                XCTAssertEqual(bridge.projectionObservationStateForTesting.generation, checkpoint.generation)
                XCTAssertEqual(events.catalogCheckpoints.count, applications, "old completion cannot credit the new run")
                XCTAssertEqual(chooser.emitted.count, emissions)
                XCTAssertEqual(manager.workspaceChooserPresentation, presentation)
            }
        }

        func testFailedSaveReconciliationRejectsStaleApplicationsAndKeepsFullRequiredFence() async throws {
            // Delegates to the real reconciliation routine; does not simulate a persistence save failure.
            try await Fixture.run { f in
                let (window, manager, chooser, events) = await f.makeWindowWithHeldInitialProjection()
                window.restartDomainWorkspaceProjectionForTesting()
                try await f.awaitCaughtUpWithCatalogBaseline(window)
                await window.joinDomainWorkspaceBridgeForTesting()
                let before = manager.workspaceChooserPresentation
                let generation = manager.domainCatalogReconciliationGeneration
                let applications = events.catalogCheckpoints.count
                let snapshot = await f.runtime.workspaceStore.snapshot()
                let system = try XCTUnwrap(snapshot.workspaces.first { $0.document.workspaceID == Fixture.defaultID })
                var reads = 0
                manager.beforeFailedSaveCatalogApplicationForTesting = { actual in
                    reads += 1
                    // A real baseline-only outcome can raise the floor without reconciling membership.
                    manager.applyDomainAuthorityBaseline(
                        workspaceID: Fixture.defaultID, revisions: system.revisions, digest: system.document.contentDigest,
                        health: system.health, catalogRevision: actual.catalogRevision + 1
                    )
                }
                let reconciled = await manager.reconcileDuplicateCleanupAuthorityAfterFailedSaveForTesting()
                manager.beforeFailedSaveCatalogApplicationForTesting = nil
                XCTAssertFalse(reconciled, "rejected applications must not be reported as reconciled")
                XCTAssertEqual(reads, 2, "one current refetch, then terminal rejection")
                XCTAssertEqual(manager.domainCatalogReconciliationGeneration, generation)
                XCTAssertEqual(events.catalogCheckpoints.count, applications)
                XCTAssertEqual(manager.workspaceChooserPresentation.failure?.kind, .catalogChangedDuringRefresh)
                guard case let .ready(retained, .failed(failure)) = manager.workspaceChooserPresentation,
                      case let .ready(original, _) = before
                else { return XCTFail("rejection must retain accepted rows with a warning") }
                XCTAssertEqual(retained, original)
                XCTAssertEqual(failure.recovery, .idle)
                XCTAssertEqual(try chooser.consume(.compact(maxRecent: 5)).orderedIDs, [Fixture.aardvarkID, Fixture.requestedID])
                let covering = f.catalog(snapshot, sequence: snapshot.publicationSequence, catalogRevision: snapshot.catalogRevision + 1)
                let metadata = manager.applyDomainWorkspaceCatalog(
                    covering, projection: .metadata(baselineGeneration: generation), preferredActiveWorkspaceID: nil,
                    rootMapPolicy: .decodedModels
                )
                XCTAssertEqual(metadata.rejection, .fullProjectionRequired, "rejected repair must leave self-echo/metadata fenced")
                let full = try manager.applyDomainWorkspaceCatalog(
                    covering, projection: .full(f.decoded(covering)), preferredActiveWorkspaceID: nil,
                    rootMapPolicy: .decodedModels
                )
                XCTAssertEqual(full.receipt?.kind, .full)
                XCTAssertNil(manager.workspaceChooserPresentation.failure)
                XCTAssertNotNil(manager.applyDomainWorkspaceCatalog(
                    covering, projection: .metadata(baselineGeneration: manager.domainCatalogReconciliationGeneration),
                    preferredActiveWorkspaceID: nil, rootMapPolicy: .decodedModels
                ).receipt, "only accepted full reconciliation clears the fence")
            }
        }

        func testCloseBeforeFirstCatalogRejectsProjectionAndKeepsLoadingCaptureIndependent() async throws {
            try await Fixture.run { f in
                let (window, manager, chooser, _) = await f.makeWindowWithHeldInitialProjection()
                let (route, recorder) = f.makeRecordedRoute(for: window)
                route.evaluateInitialRouteIfNeeded()
                let routeStart = recorder.routes.count
                let snapshot = await f.runtime.workspaceStore.snapshot()
                let models = try f.decoded(snapshot)
                let beforeIDs = manager.workspaces.map(\.id)
                let emissions = chooser.emitted.count
                let entry = f.restoreEntry(for: Fixture.requestedID, window: window)
                var restoreCompletions = 0
                window.applyWindowRestoreEntry(entry) { restoreCompletions += 1 }
                XCTAssertEqual(window.sessionCaptureCandidate().entry?.workspaceID, Fixture.requestedID)
                window.beginClose()
                XCTAssertEqual(restoreCompletions, 1)
                XCTAssertEqual(manager.applyDomainWorkspaceCatalog(
                    snapshot, projection: .full(models), preferredActiveWorkspaceID: Fixture.requestedID,
                    rootMapPolicy: .decodedModels
                ).rejection, .closing)
                XCTAssertFalse(manager.applyDomainWorkspaceProjection(
                    [], fileURLsByWorkspaceID: [:], revisionsByWorkspaceID: [:], digestsByWorkspaceID: [:],
                    healthByWorkspaceID: [:], catalogRevision: snapshot.catalogRevision,
                    preferredActiveWorkspaceID: Fixture.requestedID, publicationSequence: snapshot.publicationSequence
                ))
                XCTAssertFalse(manager.applyDomainAuthorityMetadataProjection(
                    revisionsByWorkspaceID: [:], digestsByWorkspaceID: [:], healthByWorkspaceID: [:],
                    catalogRevision: snapshot.catalogRevision, publicationSequence: snapshot.publicationSequence,
                    canonicalSystemWorkspaceIDs: [Fixture.defaultID]
                ))
                manager.reportDomainCatalogFailure(.catalogChangedDuringRefresh, snapshot: snapshot, attempt: manager.beginDomainCatalogAttempt())
                manager.retryWorkspaceChooser()
                window.restartDomainWorkspaceProjectionForTesting()
                await window.joinDomainWorkspaceBridgeForTesting()
                try await f.acknowledgeRouteConsumption(recorder)
                XCTAssertEqual(manager.workspaces.map(\.id), beforeIDs)
                XCTAssertEqual(manager.domainCatalogReconciliationGeneration, 0)
                XCTAssertEqual(chooser.emitted.count, emissions)
                for query in [WorkspaceChooserQuery.compact(maxRecent: 5), .expanded(collection: .saved, searchText: "")] {
                    XCTAssertEqual(try chooser.consume(query).kind, .loading)
                    XCTAssertEqual(try chooser.consume(query).orderedIDs, [])
                }
                XCTAssertNil(manager.activeWorkspaceID)
                XCTAssertFalse(manager.test_isPollTimerActive)
                XCTAssertNil(f.projectionState(for: window).runID)
                XCTAssertNil(f.projectionState(for: window).catalogCheckpoint)
                let candidate = window.sessionCaptureCandidate()
                XCTAssertEqual(candidate.entry?.workspaceID, Fixture.requestedID, "loading cannot overwrite protected capture")
                XCTAssertTrue(WindowSessionSnapshotBuilder.build(
                    version: 4, candidates: [candidate], excludedWindowIDs: [window.windowID]
                ).windows.isEmpty, "explicit close remains excluded from capture")
                f.assertNoUnsolicitedSelection(recorder, routeStart: routeStart, context: "close before first catalog")
            }
        }

        func testReentrantCloseDuringIssueClearanceCannotPublishReadyOrCreditCheckpoint() async throws {
            try await Fixture.run { f in
                let (window, manager, chooser, events) = await f.makeWindowWithHeldInitialProjection()
                manager.setCatalogRecordDecodeFailureForTesting { $0 == Fixture.aardvarkID ? InjectedDecodeFailure() : nil }
                window.restartDomainWorkspaceProjectionForTesting()
                let snapshot = await f.runtime.workspaceStore.snapshot()
                try await f.wait(events.resolution(through: snapshot.publicationSequence))
                XCTAssertTrue(manager.reportDomainCatalogFailure(
                    .modelProjection("catalog-wide failure"),
                    snapshot: snapshot,
                    attempt: manager.beginDomainCatalogAttempt()
                ))
                XCTAssertNotNil(manager.domainWorkspaceAuthorityIssue)
                let acceptedCount = events.catalogCheckpoints.count
                let generation = f.projectionState(for: window).generation
                let bridge = try XCTUnwrap(window.domainWorkspacePresentationBridgeForTesting)
                let closed = Signal("close reentered during covered issue clearance")
                var emissionsAtClose: Int?
                var presentationAtClose: WorkspaceChooserPresentation?
                let observation = manager.$domainWorkspaceAuthorityIssue.sink { issue in
                    guard issue == nil else { return }
                    window.beginClose()
                    emissionsAtClose = chooser.emitted.count
                    presentationAtClose = manager.workspaceChooserPresentation
                    closed.fire()
                }
                defer { observation.cancel() }
                manager.setCatalogRecordDecodeFailureForTesting(nil)
                manager.retryWorkspaceChooser()
                try await f.wait(closed)
                await window.joinDomainWorkspaceBridgeForTesting()
                XCTAssertEqual(chooser.emitted.count, emissionsAtClose)
                XCTAssertEqual(manager.workspaceChooserPresentation, presentationAtClose)
                XCTAssertEqual(events.catalogCheckpoints.count, acceptedCount, "close must fence the returning caller's acceptance checkpoint")
                XCTAssertEqual(bridge.projectionObservationStateForTesting.generation, generation)
                XCTAssertNil(manager.activeWorkspaceID)
                XCTAssertFalse(manager.test_isPollTimerActive)
                XCTAssertEqual(try chooser.consume(.compact(maxRecent: 5)).kind, .ready)
            }
        }

        func testCloseFromReadyEmissionDoesNotCreditReturningBridgeCheckpoint() async throws {
            try await Fixture.run { f in
                let (window, manager, chooser, events) = await f.makeWindowWithHeldInitialProjection()
                let bridge = try XCTUnwrap(window.domainWorkspacePresentationBridgeForTesting)
                let closed = Signal("close from accepted chooser emission")
                var acceptedBeforeClose: WorkspaceChooserPresentation?
                var emissionCount: Int?
                var observed: [WorkspaceChooserPresentation] = []
                let observation = manager.$workspaceChooserPresentation.sink { value in
                    observed.append(value)
                    guard case .ready = value else { return }
                    acceptedBeforeClose = value
                    emissionCount = observed.count
                    window.beginClose()
                    closed.fire()
                }
                defer { observation.cancel() }
                window.restartDomainWorkspaceProjectionForTesting()
                try await f.wait(closed)
                await window.joinDomainWorkspaceBridgeForTesting()
                XCTAssertEqual(manager.workspaceChooserPresentation, acceptedBeforeClose, "the ready emission preceded close")
                XCTAssertEqual(observed.count, emissionCount, "no further chooser publication after close")
                XCTAssertEqual(chooser.emitted, observed, "subscriber order cannot change the emitted content")
                XCTAssertTrue(events.catalogCheckpoints.isEmpty, "the returning Bridge cannot credit an application after close")
                XCTAssertEqual(bridge.projectionObservationStateForTesting.generation, 0)
                XCTAssertFalse(manager.test_isPollTimerActive)
                XCTAssertEqual(try chooser.consume(.compact(maxRecent: 5)).orderedIDs, [Fixture.aardvarkID, Fixture.requestedID])
            }
        }

        func testCloseDuringInitialDefaultResultFencesReturningRunBeforeErrorPublication() async throws {
            try await Fixture.run(seeds: []) { f in
                let (window, manager, chooser, events) = await f.makeWindowWithHeldInitialProjection()
                let bridge = try XCTUnwrap(window.domainWorkspacePresentationBridgeForTesting)
                let snapshot = await f.runtime.workspaceStore.snapshot()
                let closed = Signal("close during initial Default outcome")
                var issuesAfterClose = 0
                let observation = manager.$domainWorkspaceAuthorityIssue.sink { issue in
                    if manager.isPreparingForWindowClose, issue != nil { issuesAfterClose += 1 }
                }
                defer { observation.cancel() }
                XCTAssertTrue(bridge.setInitialDefaultCreateOutcomeForTesting(.init(
                    operationID: UUID(), disposition: .failed, before: nil, after: nil,
                    catalogRevision: snapshot.catalogRevision, resultingDigest: nil
                )) { _ in
                    window.beginClose()
                    closed.fire()
                })
                window.restartDomainWorkspaceProjectionForTesting()
                try await f.wait(closed)
                await window.joinDomainWorkspaceBridgeForTesting()
                XCTAssertEqual(issuesAfterClose, 0, "the returning run must check close before reporting command failure")
                XCTAssertNil(manager.domainWorkspaceAuthorityIssue)
                XCTAssertEqual(manager.workspaceChooserPresentation, .loading)
                XCTAssertTrue(chooser.emitted.allSatisfy { $0 == .loading })
                XCTAssertTrue(events.catalogCheckpoints.isEmpty)
                XCTAssertNil(manager.activeWorkspaceID)
                XCTAssertFalse(manager.test_isPollTimerActive)
            }
        }

        // MARK: #1142 Slice 6 — production mutations and chooser policy

        func testRealAuthorityMembershipAndLibraryOpenUpdateBothChooserQueries() async throws {
            try await Fixture.run { f in
                let (window, manager, chooser, _) = await f.makeWindowWithHeldInitialProjection()
                window.restartDomainWorkspaceProjectionForTesting()
                try await f.awaitCaughtUpWithCatalogBaseline(window)
                let compact = WorkspaceChooserQuery.compact(maxRecent: 10)
                let expanded = WorkspaceChooserQuery.expanded(collection: .saved, searchText: "")
                for query in [compact, expanded] {
                    XCTAssertEqual(try chooser.consume(query).orderedIDs, [Fixture.aardvarkID, Fixture.requestedID])
                }

                let inserted = try await f.commitWorkspace(named: "M inserted", window: window)
                for query in [compact, expanded] {
                    XCTAssertEqual(try chooser.consume(query).orderedIDs, [Fixture.aardvarkID, inserted.id, Fixture.requestedID])
                }
                f.releaseAllGates()
                await manager.awaitInitialWorkspaceActivationCompletion()
                let requested = try XCTUnwrap(manager.workspace(withID: Fixture.requestedID))
                let oldRecency = requested.lastUsed
                let opened = await manager.openWorkspaceFromLibrary(requested)
                XCTAssertTrue(opened.didSwitch)
                XCTAssertGreaterThan(try XCTUnwrap(manager.workspace(withID: requested.id)).lastUsed, oldRecency)
                for query in [compact, expanded] {
                    XCTAssertEqual(try chooser.consume(query).orderedIDs, [requested.id, Fixture.aardvarkID, inserted.id])
                }
                let deleted = try await manager.deleteWorkspaceAsync(XCTUnwrap(manager.workspace(withID: inserted.id)))
                XCTAssertTrue(deleted)
                try await f.awaitCaughtUpWithCatalogBaseline(window)
                for query in [compact, expanded] {
                    XCTAssertEqual(try chooser.consume(query).orderedIDs, [requested.id, Fixture.aardvarkID])
                }
            }
        }

        func testProductionChooserRankingSearchVisibilityAndLibraryCollectionTransitions() async throws {
            var newest = Fixture.model(id: UUID(), name: "Z newest")
            newest.lastUsed = Date(timeIntervalSince1970: 1_780_000_020)
            var alphaLow = try Fixture.model(id: XCTUnwrap(UUID(uuidString: "10000000-0000-0000-0000-000000000001")), name: "alpha")
            var alphaHigh = try Fixture.model(id: XCTUnwrap(UUID(uuidString: "20000000-0000-0000-0000-000000000001")), name: "ALPHA")
            var beta = Fixture.model(id: UUID(), name: "Beta")
            alphaLow.lastUsed = Date(timeIntervalSince1970: 1_780_000_010)
            alphaHigh.lastUsed = alphaLow.lastUsed
            beta.lastUsed = alphaLow.lastUsed
            beta.repoPaths = ["/isolated/CaseNeedle"]
            var hidden = Fixture.model(id: UUID(), name: "Hidden")
            hidden.isHiddenInMenus = true
            hidden.lastUsed = Date(timeIntervalSince1970: 1_780_000_050)
            var temporary = Fixture.model(id: UUID(), name: "Temporary")
            temporary.isSavedWorkspace = false
            temporary.lastUsed = Date(timeIntervalSince1970: 1_780_000_060)
            let seeds = [Fixture.standardSeeds[0], alphaHigh, hidden, beta, newest, temporary, alphaLow]
            try await Fixture.run(seeds: seeds) { f in
                let (window, manager, chooser, _) = await f.makeWindowWithHeldInitialProjection()
                window.restartDomainWorkspaceProjectionForTesting()
                try await f.awaitCaughtUpWithCatalogBaseline(window)
                let saved = WorkspaceChooserQuery.expanded(collection: .saved, searchText: "")
                let temp = WorkspaceChooserQuery.expanded(collection: .temporary, searchText: "")
                let ranked = [newest.id, alphaLow.id, alphaHigh.id, beta.id]
                XCTAssertEqual(try chooser.consume(saved).orderedIDs, ranked, "recency, localized name, then UUID")
                XCTAssertEqual(try chooser.consume(.compact(maxRecent: 2)).orderedIDs, [newest.id, alphaLow.id])
                XCTAssertEqual(try chooser.consume(.compact(maxRecent: 0)).orderedIDs, [])
                XCTAssertEqual(try chooser.consume(temp).orderedIDs, [temporary.id])
                let name = try chooser.consume(.expanded(collection: .saved, searchText: " \nAlPhA\t "))
                XCTAssertEqual(name.orderedIDs, [alphaLow.id, alphaHigh.id])
                XCTAssertEqual(name.trimmedQuery, "AlPhA")
                let path = try chooser.consume(.expanded(collection: .saved, searchText: "  caseneedle\n"))
                XCTAssertEqual(path.orderedIDs, [beta.id])
                let noMatch = try chooser.consume(.expanded(collection: .saved, searchText: "  absent  "))
                XCTAssertEqual(noMatch.kind, .ready)
                XCTAssertEqual(noMatch.orderedIDs, [])
                XCTAssertEqual(noMatch.collection, .saved)
                XCTAssertEqual(noMatch.trimmedQuery, "absent")
                XCTAssertNil(noMatch.failure)
                XCTAssertEqual(try chooser.consume(.expanded(collection: .saved, searchText: " \n\t")).orderedIDs, ranked)

                try await manager.setWorkspaceLibraryMembership(XCTUnwrap(manager.workspace(withID: newest.id)), saved: false)
                try await f.awaitCaughtUpWithCatalogBaseline(window)
                XCTAssertEqual(try chooser.consume(saved).orderedIDs, [alphaLow.id, alphaHigh.id, beta.id])
                XCTAssertEqual(try chooser.consume(temp).orderedIDs, [temporary.id, newest.id])
                XCTAssertEqual(try chooser.consume(.compact(maxRecent: 2)).orderedIDs, [alphaLow.id, alphaHigh.id])
                try await manager.setWorkspaceLibraryMembership(XCTUnwrap(manager.workspace(withID: newest.id)), saved: true)
                try await f.awaitCaughtUpWithCatalogBaseline(window)
                XCTAssertEqual(try chooser.consume(saved).orderedIDs, ranked)
                XCTAssertEqual(try chooser.consume(temp).orderedIDs, [temporary.id])
            }
        }

        func testLocalDeltasPreserveIncompleteWarningsAndUntouchedRetainedMembership() async throws {
            let introduced = Fixture.model(id: UUID(), name: "C partial-only")
            for retainsComplete in [false, true] {
                try await Fixture.run(seeds: Fixture.standardSeeds + [introduced]) { f in
                    let manager = f.makeManager()
                    let chooser = f.makeChooserRecorder(manager: manager)
                    let base = await f.runtime.workspaceStore.snapshot()
                    if retainsComplete {
                        let complete = f.catalog(base, sequence: 10, catalogRevision: 10, dropping: [introduced.id])
                        XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                            complete, projection: .full(f.decoded(complete)), preferredActiveWorkspaceID: nil,
                            rootMapPolicy: .snapshotMetadata
                        ).receipt)
                    }
                    let partial = f.catalog(
                        base, sequence: 11, catalogRevision: 11,
                        dropping: [Fixture.requestedID], unavailable: [Fixture.requestedID]
                    )
                    let receipt = try XCTUnwrap(try manager.applyDomainWorkspaceCatalog(
                        partial, projection: .full(f.decoded(partial)), preferredActiveWorkspaceID: nil,
                        rootMapPolicy: .snapshotMetadata
                    ).receipt)
                    let failure = try XCTUnwrap(receipt.completeness.failure)
                    let saved = WorkspaceChooserQuery.expanded(collection: .saved, searchText: "")
                    let compact = WorkspaceChooserQuery.compact(maxRecent: 10)
                    let expected = retainsComplete ? [Fixture.aardvarkID, Fixture.requestedID] : [Fixture.aardvarkID, introduced.id]
                    let before = try chooser.consume(saved)
                    XCTAssertEqual(before.orderedIDs, expected)
                    XCTAssertEqual(before.failureID, failure.id)
                    XCTAssertEqual(manager.workspaces.contains { $0.id == Fixture.requestedID }, retainsComplete, "retain only a last-known accepted unavailable member")
                    XCTAssertTrue(manager.workspaces.contains { $0.id == introduced.id })

                    let a = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == Fixture.aardvarkID })
                    manager.workspaces[a].lastUsed = Date(timeIntervalSince1970: 1_780_000_100)
                    let local = manager.createWorkspace(name: "Local temporary", repoPaths: [], ephemeral: true, savedInLibrary: false)
                    for query in [saved, compact] {
                        let consumed = try chooser.consume(query)
                        XCTAssertEqual(consumed.orderedIDs, expected)
                        XCTAssertEqual(consumed.source, before.source)
                        XCTAssertEqual(consumed.failure, failure, "local deltas never recertify the incomplete reconciliation")
                    }
                    XCTAssertEqual(try chooser.consume(.expanded(collection: .temporary, searchText: "")).orderedIDs, [local.id])
                    guard case let .ready(rows, .failed(warning)) = manager.workspaceChooserPresentation else {
                        return XCTFail("local changes must preserve warning and accepted rows")
                    }
                    XCTAssertEqual(rows.workspaces.first { $0.id == Fixture.aardvarkID }?.lastUsed, Date(timeIntervalSince1970: 1_780_000_100))
                    XCTAssertEqual(warning, failure)

                    // The partial-only row is not a local insertion; editing it must not add it to retained membership.
                    let c = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == introduced.id })
                    manager.workspaces[c].currentPromptText = "local edit to partial row"
                    manager.workspaces.removeAll { $0.id == Fixture.aardvarkID }
                    let remaining = retainsComplete ? [Fixture.requestedID] : [introduced.id]
                    for query in [saved, compact] {
                        let consumed = try chooser.consume(query)
                        XCTAssertEqual(consumed.orderedIDs, remaining, "remove only touched ID; preserve absent untouched retained row")
                        XCTAssertEqual(consumed.source, before.source)
                        XCTAssertEqual(consumed.failure, failure)
                    }
                }
            }
        }

        func testAcceptedCatalogPreservesOwnedEphemeralsAndPendingCreationButNotLegacyGhost() async throws {
            let ghost = Fixture.model(id: UUID(), name: "Legacy ghost")
            try await Fixture.run(seeds: Fixture.standardSeeds + [ghost]) { f in
                try await f.deleteAndRestoreLegacyGhost(ghost)
                let manager = f.makeManager()
                let chooser = f.makeChooserRecorder(manager: manager)
                XCTAssertNotNil(manager.workspace(withID: ghost.id), "the constructor really loads the ghost")
                let base = await f.runtime.workspaceStore.snapshot()
                let gate = f.makeGate()
                let prepared = Signal("pending creation stopped before authority publication")
                manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { _, _, _ in
                    await prepared.fire()
                    await gate.wait()
                }
                defer { manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil) }
                let pending = manager.createWorkspace(name: "Pending saved", repoPaths: [])
                let join = f.startOwned { await manager.finishWorkspaceCreation(workspaceIDs: [pending.id]) }
                try await f.wait(prepared)
                let local = manager.createWorkspace(name: "Local temporary", repoPaths: [], ephemeral: true, savedInLibrary: false)
                var decoded = try f.decoded(base)
                let incoming = try XCTUnwrap(decoded.firstIndex { $0.id == Fixture.requestedID })
                decoded[incoming].isEphemeral = true
                let receipt = try XCTUnwrap(manager.applyDomainWorkspaceCatalog(
                    base, projection: .full(decoded), preferredActiveWorkspaceID: nil, rootMapPolicy: .decodedModels
                ).receipt)
                XCTAssertEqual(receipt.completeness, .complete)
                XCTAssertNil(manager.workspace(withID: ghost.id), "legacy membership is not a pending creation")
                XCTAssertNil(manager.workspace(withID: Fixture.requestedID), "incoming ephemeral is excluded")
                XCTAssertNotNil(manager.workspace(withID: pending.id), "owned pending publication survives")
                XCTAssertNotNil(manager.workspace(withID: local.id), "local ephemeral survives")
                for query in [WorkspaceChooserQuery.compact(maxRecent: 10), .expanded(collection: .saved, searchText: "")] {
                    XCTAssertEqual(try chooser.consume(query).orderedIDs, [pending.id, Fixture.aardvarkID])
                }
                XCTAssertEqual(try chooser.consume(.expanded(collection: .temporary, searchText: "")).orderedIDs, [local.id])
                gate.release()
                await join.value
                manager.setWorkspaceSavePreparationDidFinishHandlerForTesting(nil)
                let current = await f.runtime.workspaceStore.snapshot()
                XCTAssertTrue(current.workspaces.contains { $0.document.workspaceID == pending.id }, "the real creation completes")
            }
        }

        func testCallerRootMapContractsAndProductionLifecycleOverlayReachChooser() async throws {
            try await Fixture.run { f in
                let base = await f.runtime.workspaceStore.snapshot()
                for policy in [DomainCatalogRootMapPolicy.snapshotMetadata, .decodedModels] {
                    let manager = f.makeManager()
                    let chooser = f.makeChooserRecorder(manager: manager)
                    let a = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == Fixture.aardvarkID })
                    var protectedTab = try XCTUnwrap(manager.workspaces[a].composeTabs.first)
                    protectedTab.name = "Protected local tab"
                    protectedTab.activeAgentSessionID = UUID()
                    manager.workspaces[a].composeTabs[0] = protectedTab
                    let lifecycle = AgentSessionLifecycleAuthority()
                    let claim = AgentSessionLifecycleAuthority.ProtectionClaim(
                        identity: .init(
                            workspaceID: Fixture.aardvarkID, tabID: protectedTab.id,
                            sessionID: protectedTab.activeAgentSessionID, persistentBindingGeneration: nil,
                            bindingTransitionGeneration: 0
                        ),
                        tab: protectedTab, isLive: true, isActive: true, isPinned: false, hasActiveRun: true
                    )
                    manager.setAgentSessionProjectionReconciler { projected, current, repairBaselines in
                        lifecycle.reconcileProjection(
                            projectedWorkspaces: projected, currentWorkspaces: current, claims: [claim], repairBaselines: repairBaselines
                        )
                    }
                    var models = try f.decoded(base)
                    let projectedA = try XCTUnwrap(models.firstIndex { $0.id == Fixture.aardvarkID })
                    models[projectedA].repoPaths = ["/isolated/cached-overlay"]
                    let receipt = try XCTUnwrap(manager.applyDomainWorkspaceCatalog(
                        base, projection: .full(models), preferredActiveWorkspaceID: nil, rootMapPolicy: policy
                    ).receipt)
                    XCTAssertEqual(receipt.completeness, .complete)
                    let expectedRoots = policy == .snapshotMetadata ? [] : ["/isolated/cached-overlay"]
                    let reconciled = try XCTUnwrap(manager.workspace(withID: Fixture.aardvarkID))
                    XCTAssertEqual(reconciled.repoPaths, expectedRoots, "Bridge uses metadata; manager callers preserve decoded roots")
                    XCTAssertEqual(reconciled.composeTabs.first, protectedTab, "real lifecycle policy preserves the owned live tab")
                    guard case let .ready(catalog, .current) = manager.workspaceChooserPresentation else {
                        return XCTFail("accepted overlay must reach the coherent chooser catalog")
                    }
                    let row = try XCTUnwrap(catalog.workspaces.first { $0.id == Fixture.aardvarkID })
                    XCTAssertEqual(row.repoPaths, expectedRoots)
                    XCTAssertEqual(row.composeTabs.first, protectedTab)
                    for query in [WorkspaceChooserQuery.compact(maxRecent: 10), .expanded(collection: .saved, searchText: "")] {
                        XCTAssertEqual(try chooser.consume(query).orderedIDs, [Fixture.aardvarkID, Fixture.requestedID])
                    }
                    let pathMatch = try chooser.consume(.expanded(collection: .saved, searchText: " cached-overlay "))
                    XCTAssertEqual(pathMatch.orderedIDs, policy == .snapshotMetadata ? [] : [Fixture.aardvarkID])
                }
            }
        }

        func testImportFenceSuppressesLocalMirroringUntilAvailableCatalogAcceptance() async throws {
            try await Fixture.run { f in
                let (window, manager, chooser, events) = await f.makeWindowWithHeldInitialProjection()
                window.restartDomainWorkspaceProjectionForTesting()
                try await f.awaitCaughtUpWithCatalogBaseline(window)
                let saved = WorkspaceChooserQuery.expanded(collection: .saved, searchText: "")
                let compact = WorkspaceChooserQuery.compact(maxRecent: 10)
                let before = try chooser.consume(saved)
                let ghost = Fixture.model(id: UUID(), name: "Imported ghost")
                let generation = manager.domainCatalogReconciliationGeneration
                let acceptedCount = events.catalogCheckpoints.count
                manager.setCatalogRecordDecodeFailureForTesting { id in
                    id == Fixture.aardvarkID ? InjectedDecodeFailure() : nil
                }
                manager.replaceWorkspacesFromUnacceptedImport(manager.workspaces + [ghost])
                XCTAssertEqual(try chooser.consume(saved), before, "unaccepted replacement never mirrors")
                let a = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == Fixture.aardvarkID })
                manager.workspaces[a].name = "Unaccepted local rename"
                let local = manager.createWorkspace(name: "Local during fence", repoPaths: [], ephemeral: true, savedInLibrary: false)
                XCTAssertEqual(try chooser.consume(saved), before, "subsequent local mutations stay fenced")
                XCTAssertEqual(try chooser.consume(.expanded(collection: .temporary, searchText: "")).orderedIDs, [])
                await f.awaitCatalogRefresh(window)
                XCTAssertEqual(events.catalogCheckpoints.count, acceptedCount + 1, "valid members are accepted independently of a decode failure")
                XCTAssertEqual(manager.domainCatalogReconciliationGeneration, generation + 1)
                let failure = try XCTUnwrap(manager.workspaceChooserPresentation.failure)
                XCTAssertEqual(failure.kind, .unavailableMembers([Fixture.aardvarkID]))
                let snapshot = await f.runtime.workspaceStore.snapshot()
                XCTAssertEqual(manager.applyDomainWorkspaceCatalog(
                    snapshot, projection: .metadata(baselineGeneration: generation), preferredActiveWorkspaceID: nil,
                    rootMapPolicy: .snapshotMetadata
                ).rejection, .fullProjectionRequired, "metadata cannot repair an import baseline")
                for query in [saved, compact] {
                    let consumed = try chooser.consume(query)
                    XCTAssertEqual(consumed.orderedIDs, before.orderedIDs)
                    XCTAssertEqual(consumed.source, before.source)
                    XCTAssertEqual(consumed.failureID, failure.id)
                }

                manager.setCatalogRecordDecodeFailureForTesting(nil)
                manager.retryWorkspaceChooser()
                XCTAssertTrue(manager.workspaceChooserPresentation.failure?.recovery.isRetrying == true)
                await f.awaitCatalogRefresh(window)
                let applications = events.catalogCheckpoints.dropFirst(acceptedCount).compactMap(\.catalogReceipt)
                XCTAssertEqual(applications.map(\.kind), [.full, .full], "Retry must force full, not reuse Bridge metadata caches")
                XCTAssertNil(manager.workspace(withID: ghost.id))
                XCTAssertEqual(manager.workspace(withID: Fixture.aardvarkID)?.name, "Aardvark")
                for query in [saved, compact] {
                    let consumed = try chooser.consume(query)
                    XCTAssertEqual(consumed.orderedIDs, [Fixture.aardvarkID, Fixture.requestedID])
                    XCTAssertNil(consumed.failure)
                }
                XCTAssertEqual(try chooser.consume(.expanded(collection: .temporary, searchText: "")).orderedIDs, [local.id])
                XCTAssertFalse(chooser.emitted.contains {
                    if case let .ready(catalog, _) = $0 { return catalog.workspaces.contains { $0.id == ghost.id } }
                    return false
                })
            }
        }

        func testNonAuthorityManagerIsLocallyReadyWithoutBridgeAndKeepsLocalMutationsVisible() async throws {
            try await Fixture.run { f in
                let manager = f.makeManager(withAuthority: false)
                let chooser = f.makeChooserRecorder(manager: manager)
                let saved = WorkspaceChooserQuery.expanded(collection: .saved, searchText: "")
                let temp = WorkspaceChooserQuery.expanded(collection: .temporary, searchText: "")
                for query in [WorkspaceChooserQuery.compact(maxRecent: 10), saved] {
                    let initial = try chooser.consume(query)
                    XCTAssertEqual(initial.kind, .ready)
                    XCTAssertEqual(initial.source, .local)
                    XCTAssertNil(initial.failure)
                    XCTAssertEqual(initial.orderedIDs, [Fixture.aardvarkID, Fixture.requestedID])
                }
                let local = manager.createWorkspace(name: "Local temporary", repoPaths: [], ephemeral: true, savedInLibrary: false)
                XCTAssertEqual(try chooser.consume(temp).orderedIDs, [local.id])
                try await manager.setWorkspaceLibraryMembership(XCTUnwrap(manager.workspace(withID: Fixture.aardvarkID)), saved: false)
                XCTAssertEqual(try chooser.consume(saved).orderedIDs, [Fixture.requestedID])
                XCTAssertEqual(try chooser.consume(temp).orderedIDs, [local.id, Fixture.aardvarkID])
                manager.reloadWorkspacesFromDisk()
                let reloaded = try chooser.consume(saved)
                XCTAssertEqual(reloaded.source, .local)
                XCTAssertNil(reloaded.failure)
                XCTAssertEqual(reloaded.orderedIDs, [Fixture.requestedID])
                XCTAssertEqual(try chooser.consume(temp).orderedIDs, [local.id, Fixture.aardvarkID])
            }
        }

        func testDegradedAcceptedCatalogsAdmitSelfEchoWithoutClearingWarnings() async throws {
            for state in 0 ..< 3 {
                try await Fixture.run { f in
                    let manager = f.makeManager()
                    XCTAssertFalse(manager.admitsDomainSelfEcho(baselineGeneration: 0))
                    let base = await f.runtime.workspaceStore.snapshot()
                    let snapshot = f.catalog(
                        base, sequence: 5, catalogRevision: 5,
                        health: state == 1 ? .degradedReadOnly(reason: "aggregate_unavailable") : .writable,
                        dropping: state == 0 ? [Fixture.requestedID] : [],
                        unavailable: state == 0 ? [Fixture.requestedID] : []
                    )
                    let receipt = try XCTUnwrap(try manager.applyDomainWorkspaceCatalog(
                        snapshot, projection: .full(f.decoded(snapshot)), preferredActiveWorkspaceID: nil,
                        rootMapPolicy: .decodedModels
                    ).receipt)
                    if state == 2 {
                        XCTAssertTrue(manager.reportDomainCatalogFailure(.catalogChangedDuringRefresh, snapshot: snapshot, attempt: manager.beginDomainCatalogAttempt()))
                    }
                    let presented = manager.workspaceChooserPresentation
                    XCTAssertNotNil(presented.failure)
                    let record = try XCTUnwrap(snapshot.workspaces.first { $0.document.workspaceID == Fixture.aardvarkID })
                    XCTAssertTrue(manager.admitsDomainSelfEcho(baselineGeneration: receipt.reconciliationGeneration))
                    XCTAssertFalse(manager.admitsDomainSelfEcho(baselineGeneration: receipt.reconciliationGeneration + 1))
                    XCTAssertTrue(manager.acceptDomainAuthoritySelfEchoBaseline(
                        workspaceID: Fixture.aardvarkID, revisions: record.revisions, digest: record.document.contentDigest,
                        health: record.health, catalogRevision: 6, publicationSequence: 6,
                        baselineGeneration: receipt.reconciliationGeneration
                    ))
                    XCTAssertEqual(manager.domainCatalogReconciliationGeneration, receipt.reconciliationGeneration, "an echo is not a catalog reconciliation")
                    XCTAssertEqual(manager.workspaceChooserPresentation, presented, "an echo cannot erase degradation or certify freshness")
                    let recovered = f.catalog(base, sequence: 7, catalogRevision: 7)
                    XCTAssertNotNil(try manager.applyDomainWorkspaceCatalog(
                        recovered, projection: .full(f.decoded(recovered)), preferredActiveWorkspaceID: nil,
                        rootMapPolicy: .decodedModels
                    ).receipt)
                    XCTAssertNil(manager.workspaceChooserPresentation.failure)
                    manager.prepareForWindowClose()
                    XCTAssertFalse(manager.admitsDomainSelfEcho(baselineGeneration: manager.domainCatalogReconciliationGeneration))
                }
            }
        }

        func testRealSelfEchoWithUnavailableMemberAndFailedRefreshAvoidsCatalogReconciliation() async throws {
            try await Fixture.run(unavailableSeedIDs: [Fixture.requestedID]) { f in
                let (window, manager, _, events) = await f.makeWindowWithHeldInitialProjection()
                window.restartDomainWorkspaceProjectionForTesting()
                var checkpoint = try await f.awaitCatalogProjection(window)
                let initial = await f.runtime.workspaceStore.snapshot()
                XCTAssertEqual(manager.workspaceChooserPresentation.failure?.kind, .unavailableMembers([Fixture.requestedID]))
                let client = DomainWorkspaceAuthorityClient(store: f.runtime.workspaceStore, windowID: window.windowID)
                for failRefresh in [false, true] {
                    if failRefresh {
                        let snapshot = await client.snapshot()
                        XCTAssertTrue(manager.reportDomainCatalogFailure(.catalogChangedDuringRefresh, snapshot: snapshot, attempt: manager.beginDomainCatalogAttempt()))
                    }
                    let failure = manager.workspaceChooserPresentation.failure
                    let generation = manager.domainCatalogReconciliationGeneration
                    let applications = events.catalogCheckpoints.count
                    let canonical = await client.canonicalWorkspaceSnapshot(Fixture.aardvarkID)
                    let record = try XCTUnwrap(canonical)
                    var edited = try XCTUnwrap(manager.workspace(withID: Fixture.aardvarkID))
                    edited.name = failRefresh ? "Echo after failed refresh" : "Echo with missing peer"
                    let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == edited.id })
                    manager.workspaces[index] = edited
                    _ = try await client.replaceWorking(
                        edited,
                        fileURL: record.document.fileURL,
                        expectedWorkspaceRevision: record.revisions.workingRevision,
                        operationID: UUID()
                    )
                    let current = await client.snapshot()
                    let echo = await f.projectionObserver(for: window).waitForProjection(
                        afterGeneration: checkpoint.generation, through: current.publicationSequence
                    )
                    checkpoint = try XCTUnwrap(echo)
                    XCTAssertEqual(checkpoint.application, .selfEchoBaseline)
                    XCTAssertEqual(events.catalogCheckpoints.count, applications)
                    XCTAssertEqual(manager.domainCatalogReconciliationGeneration, generation)
                    XCTAssertEqual(manager.workspaceChooserPresentation.failure, failure)
                }
                XCTAssertEqual(initial.unavailableWorkspaceIDs, [Fixture.requestedID])
            }
        }

        func testSelfEchoBaselineRequiresCatalogFloorAndUncancelledAdmission() async throws {
            try await Fixture.run { f in
                let manager = f.makeManager()
                let base = await f.runtime.workspaceStore.snapshot()
                let current = f.catalog(base, sequence: 5, catalogRevision: 5)
                let receipt = try XCTUnwrap(try manager.applyDomainWorkspaceCatalog(
                    current, projection: .full(f.decoded(current)), preferredActiveWorkspaceID: nil, rootMapPolicy: .decodedModels
                ).receipt)
                let record = try XCTUnwrap(base.workspaces.first { $0.document.workspaceID == Fixture.aardvarkID })
                @MainActor func accept(catalogRevision: UInt64, sequence: UInt64) -> Bool {
                    manager.acceptDomainAuthoritySelfEchoBaseline(
                        workspaceID: Fixture.aardvarkID, revisions: record.revisions, digest: record.document.contentDigest,
                        health: record.health, catalogRevision: catalogRevision, publicationSequence: sequence,
                        baselineGeneration: receipt.reconciliationGeneration
                    )
                }
                XCTAssertFalse(accept(catalogRevision: 4, sequence: 6), "an echo below the catalog floor is stale")
                let cancelled = Task { @MainActor in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return accept(catalogRevision: 6, sequence: 6)
                }
                let cancelledResult = await cancelled.value
                XCTAssertFalse(cancelledResult, "cancelled admission never advances the baseline")
                XCTAssertTrue(accept(catalogRevision: 6, sequence: 6), "current, uncancelled control")
            }
        }
    }

    private struct InjectedDecodeFailure: LocalizedError {
        static let diagnostic = "injected catalog record decode failure"
        var errorDescription: String? {
            Self.diagnostic
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
        private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

        func wait(onWaiting: (() -> Void)? = nil) async {
            guard !opened else { return }
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    guard !opened, !Task.isCancelled else {
                        $0.resume()
                        return
                    }
                    waiters[id] = $0
                    onWaiting?()
                }
            } onCancel: {
                Task { @MainActor in
                    self.waiters.removeValue(forKey: id)?.resume()
                }
            }
        }

        func release() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            pending.values.forEach { $0.resume() }
        }
    }

    /// Sendable, instance-owned adaptation of Gate for the runtime's non-MainActor bootstrap hook.
    private actor BootstrapGate {
        private var opened = false
        private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        private(set) var entries = 0
        private(set) var wasCancelled = false

        func wait(onWaiting: @Sendable () -> Void) async {
            entries += 1
            guard !opened else { return }
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    guard !opened, !Task.isCancelled else {
                        $0.resume()
                        return
                    }
                    waiters[id] = $0
                    onWaiting()
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
            wasCancelled = Task.isCancelled
        }

        private func cancel(_ id: UUID) {
            waiters.removeValue(forKey: id)?.resume()
        }

        func release() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            pending.values.forEach { $0.resume() }
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
    /// Records every bridge observation event; resolves when an attempt through a sequence was
    /// either accepted (checkpoint) or rejected, so absence of a checkpoint is never inferred by time.
    @MainActor
    private final class ProjectionEventRecorder {
        private(set) var events: [DomainWorkspacePresentationBridge.ProjectionObservationEvent] = []
        private var token: AnyCancellable?
        private var pending: (sequence: UInt64, signal: Signal)?

        init(bridge: DomainWorkspacePresentationBridge) {
            token = bridge.projectionObservationPublisherForTesting.sink { [weak self] event in
                guard let self else { return }
                events.append(event)
                if let pending, Self.resolves(event, through: pending.sequence) { pending.signal.fire() }
            }
        }

        var catalogCheckpoints: [DomainWorkspacePresentationBridge.ProjectionCheckpoint] {
            events.compactMap { if case let .applied(checkpoint) = $0, checkpoint.catalogReceipt != nil { checkpoint } else { nil } }
        }

        func resolution(through sequence: UInt64) -> Signal {
            let signal = Signal("bridge resolved publication \(sequence)")
            if events.contains(where: { Self.resolves($0, through: sequence) }) { signal.fire() }
            pending = (sequence, signal)
            return signal
        }

        func detach() {
            token?.cancel()
            token = nil
        }

        private static func resolves(
            _ event: DomainWorkspacePresentationBridge.ProjectionObservationEvent, through sequence: UInt64
        ) -> Bool {
            switch event {
            case let .applied(checkpoint): checkpoint.publicationSequence >= sequence
            case let .rejected(_, rejectedSequence, _): rejectedSequence >= sequence
            case .stopped: false
            }
        }
    }

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
    private final class ChooserRecorder {
        let manager: WorkspaceManagerViewModel
        private(set) var emitted: [WorkspaceChooserPresentation] = []
        private(set) var consumed: [WorkspaceChooserConsumption] = []
        private var token: AnyCancellable?

        init(manager: WorkspaceManagerViewModel) {
            self.manager = manager
            token = manager.$workspaceChooserPresentation.sink { [weak self] value in
                self?.emitted.append(value)
            }
            manager.setWorkspaceChooserConsumptionHandlerForTesting { [weak self] value in
                self?.consumed.append(value)
            }
        }

        func consume(_ query: WorkspaceChooserQuery) throws -> WorkspaceChooserConsumption {
            let start = consumed.count
            _ = WorkspaceChooserResultsView(workspaceManager: manager, query: query, onOpenWorkspace: { _ in }).body
            XCTAssertGreaterThan(consumed.count, start, "The real results body must emit its branch inputs")
            return try XCTUnwrap(consumed.last)
        }

        func detach() {
            manager.setWorkspaceChooserConsumptionHandlerForTesting(nil)
            token?.cancel()
            token = nil
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
        /// Indexed seeds written without a document: the runtime imports them as unavailable members.
        private let unavailableSeedIDs: Set<UUID>
        private(set) var runtime: MCPDomainRuntime!
        private let polling = CodexModelPollingService(client: EmptyModelClient())
        private var windows: [WindowState] = []
        private var projectionObserversByWindowID: [Int: DomainWorkspaceProjectionObserver] = [:]
        private var tornDownWindowIDs: Set<Int> = []
        private var routes: [ContentViewModel] = []
        private var recorders: [SelectionRecorder] = []
        private var chooserRecorders: [ChooserRecorder] = []
        private var projectionEventRecorders: [ProjectionEventRecorder] = []
        private var managers: [WorkspaceManagerViewModel] = []
        private var gates: [Gate] = []
        private var ownedJoins: [() async -> Void] = []
        private var bootstrapGate: BootstrapGate?
        private var runtimeStartTask: Task<Void, Error>?
        private var previousStoragePreference: Any?
        private var previousOnboardingPreference: Any?
        private var changedDefaults = false
        private var networkWasRunning = true
        private var publicationSequence: UInt64 = 0
        private var didShutdown = false

        private init(sandbox: URL, seeds: [WorkspaceModel], unavailableSeedIDs: Set<UUID>) {
            base = sandbox.appendingPathComponent("new-window-selection-\(UUID().uuidString)", isDirectory: true)
            storage = base.appendingPathComponent("Workspaces", isDirectory: true)
            self.seeds = seeds
            self.unavailableSeedIDs = unavailableSeedIDs
        }

        static func run(
            seeds: [WorkspaceModel]? = nil,
            unavailableSeedIDs: Set<UUID> = [],
            deferredStart: Bool = false,
            beforeRuntimeStart: ((NewWindowInitialSelectionFixture) throws -> Void)? = nil,
            _ body: (NewWindowInitialSelectionFixture) async throws -> Void
        ) async throws {
            // Must precede settings, singleton, sidecar, key, and store access.
            let sandbox = try WorkspaceTestProcessSandbox.validate()
            let fixture = NewWindowInitialSelectionFixture(
                sandbox: sandbox, seeds: seeds ?? standardSeeds, unavailableSeedIDs: unavailableSeedIDs
            )
            do {
                try await fixture.setUp(sandbox: sandbox, deferredStart: deferredStart, beforeRuntimeStart: beforeRuntimeStart)
                try await body(fixture)
                await fixture.shutdown()
            } catch {
                await fixture.shutdown()
                throw error
            }
        }

        private func setUp(
            sandbox: URL, deferredStart: Bool,
            beforeRuntimeStart: ((NewWindowInitialSelectionFixture) throws -> Void)?
        ) async throws {
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

            for seed in seeds where !unavailableSeedIDs.contains(seed.id) {
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

            try beforeRuntimeStart?(self)
            runtime = MCPDomainRuntime(configuration: .init(
                mode: .app, profileIdentifier: "issue1128-\(UUID().uuidString)",
                storageDirectory: base.appendingPathComponent("runtime"), workspaceStorageDirectory: storage,
                eventDirectory: base.appendingPathComponent("events"), temporaryDirectory: base.appendingPathComponent("tmp"),
                externalReloadInterval: nil
            ))
            if !deferredStart {
                startRuntime()
                try await joinRuntimeStartAndValidateSeeds()
            }
        }

        func holdColdBootstrap() async -> (gate: BootstrapGate, entered: XCTestExpectation) {
            precondition(runtimeStartTask == nil)
            let gate = BootstrapGate()
            let entered = XCTestExpectation(description: "shared bootstrap entered before persistence")
            bootstrapGate = gate
            await runtime.workspaceStore.testSetBeforeBootstrapPersistence {
                await gate.wait { entered.fulfill() }
            }
            return (gate, entered)
        }

        func startRuntime() {
            precondition(runtimeStartTask == nil)
            let runtime = runtime!
            runtimeStartTask = Task { try await runtime.start() }
        }

        func cancelRuntimeStart() {
            runtimeStartTask?.cancel()
        }

        func joinRuntimeStartAndValidateSeeds() async throws {
            try await runtimeStartTask?.value
            // Verify canonical import only after the held bootstrap gate has been released.
            // A snapshot also joins shared bootstrap if the outer runtime-start task was cancelled.
            try await validateBootstrapSeeds()
        }

        private func validateBootstrapSeeds() async throws {
            // Verify the actual canonical import before any Window exists in warm fixtures; otherwise the initial
            // bridge path could exit and turn the regression into a timeout.
            let snapshot = await runtime.workspaceStore.snapshot()
            guard snapshot.isBootstrapped else { throw Failure.seedMismatch("runtime not bootstrapped") }
            let imported = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.document.workspaceID, $0) })
            let available = seeds.filter { !unavailableSeedIDs.contains($0.id) }
            guard imported.count == available.count else { throw Failure.seedMismatch("imported \(imported.count) of \(available.count)") }
            for seed in available {
                guard let record = imported[seed.id],
                      record.document.metadata.isSystemWorkspace == seed.isSystemWorkspace,
                      record.revisions.dirtyRevision == nil
                else { throw Failure.seedMismatch(seed.name) }
            }
            if available.contains(where: { $0.id == Self.aardvarkID }), available.contains(where: { $0.id == Self.defaultID }) {
                let order = snapshot.workspaces.map(\.document.workspaceID)
                let expectsAardvarkFirst = seeds.first { $0.id == Self.aardvarkID }?.name == "Aardvark"
                guard (order.firstIndex(of: Self.aardvarkID)! < order.firstIndex(of: Self.defaultID)!) == expectsAardvarkFirst else {
                    throw Failure.seedMismatch("unexpected runtime catalog order")
                }
            }
        }

        /// Restore only this fixture's stale migration index/document after a real tombstoned delete.
        func deleteAndRestoreLegacyGhost(_ ghost: WorkspaceModel) async throws {
            let indexBytes = try Data(contentsOf: indexURL)
            let documentURL = workspaceURL(for: ghost)
            let documentBytes = try Data(contentsOf: documentURL)
            XCTAssertEqual(try JSONDecoder().decode(WorkspaceModel.self, from: documentBytes).id, ghost.id)
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -11421)
            let catalog = await client.snapshot()
            let record = await client.canonicalWorkspaceSnapshot(ghost.id)
            let canonical = try XCTUnwrap(record)
            let outcome = await client.delete(
                workspaceID: ghost.id, expectedCatalogRevision: catalog.catalogRevision,
                expectedWorkspaceRevision: canonical.revisions.workingRevision
            )
            XCTAssertEqual(outcome.disposition, .applied)
            let deleted = await client.snapshot()
            XCTAssertFalse(deleted.workspaces.contains { $0.document.workspaceID == ghost.id })
            XCTAssertFalse(deleted.unavailableWorkspaceIDs.contains(ghost.id))
            let missing = await client.canonicalWorkspaceSnapshot(ghost.id)
            XCTAssertNil(missing)
            try FileManager.default.createDirectory(at: documentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try documentBytes.write(to: documentURL, options: .atomic)
            try indexBytes.write(to: indexURL, options: .atomic)
            XCTAssertTrue(try legacyIDs().contains(ghost.id))
        }

        func legacyIDs() throws -> Set<UUID> {
            try Set(JSONDecoder().decode([WorkspaceIndexEntry].self, from: Data(contentsOf: indexURL)).map(\.id))
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

        /// Real Window with startup Default resolution held and its sole Bridge stopped/joined, so DEBUG
        /// seams are installed before the restarted Bridge's first projection.
        func makeWindowWithHeldInitialProjection() async -> (
            WindowState, WorkspaceManagerViewModel, ChooserRecorder, ProjectionEventRecorder
        ) {
            let window = makeWindow()
            _ = holdInitialResolution(window.workspaceManager)
            let chooser = makeChooserRecorder(manager: window.workspaceManager)
            await window.joinDomainWorkspaceBridgeForTesting()
            return (window, window.workspaceManager, chooser, recordProjectionEvents(window))
        }

        /// Re-lays out the SAME offscreen hosts until `done` (bounded; drains the run loop, no sleeps).
        func relayout(_ hosts: [NSView], until done: () -> Bool) async throws {
            for _ in 0 ..< 20 {
                for host in hosts {
                    host.needsLayout = true
                    host.layoutSubtreeIfNeeded()
                }
                if done() { return }
                let drain = Signal("offscreen chooser run-loop drain")
                RunLoop.main.schedule { drain.fire() }
                try await wait(drain)
            }
        }

        /// Repairs an unavailable seed by writing its document bytes into isolated storage.
        func writeSeedDocument(_ id: UUID) throws {
            try writeDocument(XCTUnwrap(seeds.first { $0.id == id }))
        }

        func writeDocument(_ workspace: WorkspaceModel) throws {
            let url = workspaceURL(for: workspace)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(workspace).write(to: url, options: .atomic)
        }

        /// Writes the isolated legacy index; nil writes malformed bytes (aggregate degradation).
        func writeLegacyIndex(_ workspaces: [WorkspaceModel]?) throws {
            let bytes = try workspaces.map { workspaces in
                try JSONEncoder().encode(workspaces.map {
                    WorkspaceIndexEntry(
                        id: $0.id, name: $0.name, customStoragePath: nil,
                        isSystemWorkspace: $0.isSystemWorkspace, isHiddenInMenus: $0.isHiddenInMenus
                    )
                })
            } ?? Data("not-a-workspace-index".utf8)
            try bytes.write(to: indexURL, options: .atomic)
        }

        func awaitCatalogRefresh(_ window: WindowState) async {
            await window.domainWorkspacePresentationBridgeForTesting?.awaitCatalogRefreshForTesting()
        }

        func makeChooserRecorder(manager: WorkspaceManagerViewModel) -> ChooserRecorder {
            let recorder = ChooserRecorder(manager: manager)
            chooserRecorders.append(recorder)
            return recorder
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

        /// Requires an accepted catalog THROUGH the current authority sequence. Receipt/completeness
        /// assertions must use this, never a silently older receipt beneath a later self echo.
        @discardableResult
        func awaitCatalogProjection(
            _ window: WindowState
        ) async throws -> DomainWorkspacePresentationBridge.ProjectionCheckpoint {
            let catalog = await runtime.workspaceStore.snapshot()
            guard let accepted = await projectionObserver(for: window).waitForProjection(
                afterGeneration: 0, through: catalog.publicationSequence,
                requireCatalogApplication: true, timeout: .seconds(15)
            ) else {
                releaseAllGates()
                throw Failure.timedOut("bridge catalog projection through \(catalog.publicationSequence)")
            }
            return accepted
        }

        /// Route/lifecycle journeys need current catch-up over an existing accepted baseline, not a
        /// new catalog receipt for a valid self echo. Returns the actual current checkpoint, not the baseline.
        @discardableResult
        func awaitCaughtUpWithCatalogBaseline(
            _ window: WindowState
        ) async throws -> DomainWorkspacePresentationBridge.ProjectionCheckpoint {
            let catalog = await runtime.workspaceStore.snapshot()
            guard let caughtUp = await projectionObserver(for: window).waitForProjection(
                afterGeneration: 0, through: catalog.publicationSequence, timeout: .seconds(15)
            ), projectionState(for: window).catalogCheckpoint != nil else {
                releaseAllGates()
                throw Failure.timedOut("bridge catch-up with catalog baseline through \(catalog.publicationSequence)")
            }
            return caughtUp
        }

        func recordProjectionEvents(_ window: WindowState) -> ProjectionEventRecorder {
            guard let bridge = window.domainWorkspacePresentationBridgeForTesting else {
                preconditionFailure("Window fixture is missing its projection bridge")
            }
            let recorder = ProjectionEventRecorder(bridge: bridge)
            projectionEventRecorders.append(recorder)
            return recorder
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
        func commitWorkspace(
            named name: String, isSystem: Bool = false, window: WindowState, awaitProjection: Bool = true
        ) async throws -> WorkspaceModel {
            let model = Self.model(id: UUID(), name: name, isSystem: isSystem)
            let client = DomainWorkspaceAuthorityClient(store: runtime.workspaceStore, windowID: -11280)
            _ = try await client.create(model, fileURL: workspaceURL(for: model), operationID: UUID())
            if awaitProjection { try await awaitCatalogProjection(window) }
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

        /// Re-stamps a real runtime snapshot so ordering/completeness permutations keep real records.
        func catalog(
            _ base: DomainWorkspaceCatalogSnapshot,
            sequence: UInt64,
            catalogRevision: UInt64,
            bootstrapped: Bool = true,
            health: DomainAuthorityHealth = .writable,
            dropping: Set<UUID> = [],
            unavailable: Set<UUID> = []
        ) -> DomainWorkspaceCatalogSnapshot {
            DomainWorkspaceCatalogSnapshot(
                runtimeIdentity: base.runtimeIdentity, isBootstrapped: bootstrapped, publicationSequence: sequence,
                catalogRevision: catalogRevision, health: health,
                workspaces: base.workspaces.filter { !dropping.contains($0.document.workspaceID) },
                unavailableWorkspaceIDs: unavailable
            )
        }

        func decoded(_ snapshot: DomainWorkspaceCatalogSnapshot) throws -> [WorkspaceModel] {
            try snapshot.workspaces.map {
                try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(
                    documentBytes: $0.document.documentBytes, fileURL: $0.document.fileURL
                )
            }
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
            await bootstrapGate?.release()
            if let runtime { await runtime.workspaceStore.testSetBeforeBootstrapPersistence(nil) }
            for manager in windows.map(\.workspaceManager) + managers {
                manager.setInitialDefaultResolutionHandlerForTesting(nil)
                manager.setInitialDefaultActivationDidSupersedeHandlerForTesting(nil)
                manager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting(nil)
                manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting(nil)
                manager.setWorkspaceSwitchRecoveryWillBeginHandlerForTesting(nil)
                manager.setCatalogRecordDecodeFailureForTesting(nil)
                manager.beforeAuthorityRestoreSavedReadForTesting = nil
                manager.beforeFailedSaveCatalogApplicationForTesting = nil
                for id in manager.pendingConsolidatedRestoreIDs {
                    manager.setActiveConsolidatedRestoreProtectionForTesting(id, isProtected: false)
                }
            }
            for window in windows {
                window.domainWorkspacePresentationBridgeForTesting?.afterCatalogReloadForTesting = nil
            }
            if let runtimeStartTask {
                do { try await runtimeStartTask.value } catch { XCTFail("Fixture runtime start failed: \(error)") }
            }
            if bootstrapGate != nil, let runtime {
                let joined = await runtime.workspaceStore.snapshot()
                XCTAssertTrue(joined.isBootstrapped, "Released shared bootstrap must join before storage removal")
            }
            runtimeStartTask = nil
            bootstrapGate = nil
            for join in ownedJoins {
                await join()
            }
            ownedJoins.removeAll()
            for window in windows {
                await window.workspaceManager.awaitInitialWorkspaceActivationCompletion()
                await window.workspaceManager.awaitInitialized()
            }
            chooserRecorders.forEach { $0.detach() }
            chooserRecorders.removeAll()
            recorders.forEach { $0.detach() }
            recorders.removeAll()
            projectionEventRecorders.forEach { $0.detach() }
            projectionEventRecorders.removeAll()
            for route in routes {
                route.setWorkspaceRouteConsumptionHandlerForTesting(nil)
            }
            routes.removeAll()
            for window in windows {
                let manager = window.workspaceManager
                await window.joinDomainWorkspaceBridgeForTesting()
                window.domainWorkspacePresentationBridgeForTesting?.setInitialDefaultCreateOutcomeForTesting(nil)
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
