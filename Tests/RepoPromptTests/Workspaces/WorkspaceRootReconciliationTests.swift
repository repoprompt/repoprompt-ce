import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    private final class RootDirectoryProbeCheckpoint: @unchecked Sendable {
        let entered = XCTestExpectation(description: "detached directory probe entered")
        let finished = XCTestExpectation(description: "detached directory probe finished")

        private let lock = NSLock()
        private let heldPhase: WorkspaceRootDirectoryProbeTestEvent.Phase
        private var didHold = false
        private var heldWorkerID: UUID?
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        init(heldPhase: WorkspaceRootDirectoryProbeTestEvent.Phase) {
            self.heldPhase = heldPhase
            entered.assertForOverFulfill = false
            finished.assertForOverFulfill = false
        }

        var checkpoint: WorkspaceRootDirectoryProbe.Checkpoint {
            { [self] event in await receive(event) }
        }

        private func receive(_ event: WorkspaceRootDirectoryProbeTestEvent) async {
            if event.phase == .workerFinished {
                let finishedHeldWorker = lock.withLock { event.workerID == heldWorkerID }
                if finishedHeldWorker { finished.fulfill() }
                return
            }
            let shouldHold = lock.withLock {
                guard event.phase == heldPhase, !didHold else { return false }
                didHold = true
                heldWorkerID = event.workerID
                return true
            }
            guard shouldHold else { return }
            entered.fulfill()
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    if released { return true }
                    self.continuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func release() {
            let pending = lock.withLock {
                released = true
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume()
        }
    }

    @MainActor
    final class WorkspaceRootReconciliationTests: XCTestCase {
        func testUnchangedEditPreservesQueuedLifecycleBehindValidation() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let snapshot = try await self.attempt(fixture, paths: fixture.rootPaths)
                let gate = fixture.makeGate()
                let entered = XCTestExpectation(description: "validation held before unchanged edit")
                var armed = true
                fixture.manager.rootReconciliationGateForTesting = { event in
                    guard event.phase == .probeResponse, armed else { return }
                    armed = false
                    entered.fulfill()
                    await gate.wait()
                }
                let validationDone = XCTestExpectation(description: "validation survives edit block")
                fixture.startOwnedTask {
                    do {
                        try await fixture.manager.validatePrimaryRootSnapshot(snapshot, additionalDirectoryPaths: [fixture.base.path])
                    } catch { XCTFail("Unchanged edit lost validation: \(error)") }
                    validationDone.fulfill()
                }
                try await fixture.awaitGateEvent(entered)
                let ticket = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                let registered = XCTestExpectation(description: "queued lifecycle consumer registered")
                registered.assertForOverFulfill = false
                fixture.manager.rootReconciliationWaiterCountDidChangeForTesting = { count in
                    if count == 2 { registered.fulfill() }
                }
                let lifecycleDone = XCTestExpectation(description: "queued lifecycle survives edit block")
                fixture.startOwnedTask {
                    do {
                        let ready = try await fixture.manager.awaitRootReconciliationCompletion(ticket: ticket)
                        XCTAssertEqual(ready.roots, snapshot.roots)
                    } catch { XCTFail("Unchanged edit lost queued lifecycle: \(error)") }
                    lifecycleDone.fulfill()
                }
                try await fixture.awaitGateEvent(registered)
                let editID = UUID()
                fixture.manager.beginRootReconciliationEdit(workspaceID: fixture.workspace.id, operationID: editID)
                fixture.manager.acceptRootReconciliationTarget(workspaceID: fixture.workspace.id, repoPaths: fixture.rootPaths)
                fixture.manager.endRootReconciliationEdit(workspaceID: fixture.workspace.id, operationID: editID)
                gate.release()
                try await fixture.awaitGateEvent(validationDone)
                try await fixture.awaitGateEvent(lifecycleDone)
                let completed = try await fixture.manager.awaitRootReconciliationCompletion(ticket: ticket)
                XCTAssertEqual(completed.roots, snapshot.roots)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 0)
            }
        }

        func testRetiredProbeCapacityRejectsThirdReadAndRecoversAfterSlotRelease() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let checkpoints = [
                    RootDirectoryProbeCheckpoint(heldPhase: .afterFileSystem),
                    RootDirectoryProbeCheckpoint(heldPhase: .afterFileSystem)
                ]
                defer {
                    checkpoints.forEach { $0.release() }
                    fixture.manager.rootDirectoryProbeCheckpointForTesting = nil
                }
                for checkpoint in checkpoints {
                    fixture.manager.rootDirectoryProbeCheckpointForTesting = checkpoint.checkpoint
                    _ = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                    try await fixture.awaitGateEvent(checkpoint.entered)
                    fixture.manager.cancelRootReconciliationForLifecycleTransition()
                    await fixture.manager.awaitRootReconciliationShutdown()
                }
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.outstandingProbes, 2)
                fixture.manager.rootDirectoryProbeCheckpointForTesting = nil
                let denied = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                do {
                    _ = try await fixture.perform("probe capacity rejection") {
                        try await fixture.manager.awaitRootReconciliationCompletion(ticket: denied)
                    }
                    XCTFail("A third detached read exceeded the capacity")
                } catch let failure as WorkspaceRootReadinessFailure {
                    XCTAssertEqual(failure.reason, .rootsChanging)
                }
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.outstandingProbes, 2)
                checkpoints[0].release()
                try await fixture.awaitGateEvent(checkpoints[0].finished)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.outstandingProbes, 1)
                let ready = try await self.attempt(fixture, paths: fixture.rootPaths)
                let roots = await fixture.files.workspaceFileContextStore.roots()
                XCTAssertEqual(ready.roots.map(\.standardizedFullPath), fixture.rootPaths)
                checkpoints[1].release()
                try await fixture.awaitGateEvent(checkpoints[1].finished)
                let rootsAfterLateResult = await fixture.files.workspaceFileContextStore.roots()
                XCTAssertEqual(rootsAfterLateResult, roots)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.outstandingProbes, 0)
            }
        }

        func testCanonicalDeletionBeforePresentationRemovalDeniesReadinessAndAdmissionWithoutReload() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                await fixture.bridge.stopAndJoinForTesting()
                defer { fixture.bridge.start() }
                let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -945)
                let catalog = await client.snapshot()
                let observed = await client.canonicalWorkspaceSnapshot(fixture.workspace.id)
                let canonical = try XCTUnwrap(observed)
                let deletion = await client.delete(
                    workspaceID: fixture.workspace.id,
                    expectedCatalogRevision: catalog.catalogRevision,
                    expectedWorkspaceRevision: canonical.revisions.workingRevision
                )
                XCTAssertEqual(deletion.disposition, .applied)
                let refreshed = XCTestExpectation(description: "deletion notification refreshed canonical authority")
                fixture.manager.rootNotificationDidFinishForTesting = { id in
                    if id == fixture.workspace.id { refreshed.fulfill() }
                }
                NotificationCenter.default.post(name: .workspaceRepoPathsDidChange, object: nil, userInfo: ["managerID": UUID(), "workspaceID": fixture.workspace.id])
                try await fixture.awaitGateEvent(refreshed)
                fixture.manager.rootNotificationDidFinishForTesting = nil
                let deleted = await client.canonicalWorkspaceSnapshot(fixture.workspace.id)
                XCTAssertNil(deleted)
                let model = try XCTUnwrap(fixture.manager.workspace(withID: fixture.workspace.id), "Presentation deletion must still be held")
                let roots = await fixture.files.workspaceFileContextStore.roots()
                let shells = fixture.files.visibleRootShellProjections
                let attempts = fixture.manager.rootReconciliationStateForTesting.attemptStarts
                do {
                    _ = try await fixture.manager.readyPrimaryRootSnapshot(workspaceID: model.id, expectedRepoPaths: model.repoPaths)
                    XCTFail("Deleted canonical authority was recreated from presentation roots")
                } catch let failure as WorkspaceRootReadinessFailure {
                    XCTAssertEqual(failure.reason, .workspaceUnavailable)
                }
                let invocation = try MCPServerViewModel.TabContextSnapshot(
                    tabID: XCTUnwrap(model.activeComposeTabID), windowID: -944, workspaceID: model.id,
                    promptText: "", selection: StoredSelection(), selectedMetaPromptIDs: [], tabName: "Fixture",
                    runID: UUID(), activeAgentSessionID: UUID(), worktreeBindingState: .hydrated([]), explicitlyBound: true
                )
                do {
                    _ = try await ContextBuilderWorkspaceContext.resolve(
                        from: invocation, workspaceRepoPaths: model.repoPaths,
                        workspaceDirectoryPath: fixture.workspaceURL.deletingLastPathComponent().path,
                        workspaceManager: fixture.manager
                    )
                    XCTFail("Context Builder admitted a canonically deleted workspace")
                } catch {
                    guard case let .readiness(failure) = error as? ContextBuilderWorkspaceContextError else {
                        return XCTFail("Expected typed deletion readiness error: \(error)")
                    }
                    XCTAssertEqual(failure.reason, .workspaceUnavailable)
                }
                let afterRoots = await fixture.files.workspaceFileContextStore.roots()
                XCTAssertEqual(afterRoots, roots)
                XCTAssertEqual(fixture.files.visibleRootShellProjections, shells)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts, attempts)
            }
        }

        func testDelayedSnapshotRetainsUnrelatedWorkspaceUpdateAfterNewerLocalOutcome() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(configuration: { [$0[0]] }) { fixture in
                let other = try await fixture.createAdditionalWorkspace(name: "Other", repoPaths: [fixture.rootPaths[0]])
                let otherURL = fixture.manager.workspaceFileURL(for: other)
                await fixture.bridge.stopAndJoinForTesting()
                defer { fixture.bridge.start() }
                let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -945)
                let observed = await client.canonicalWorkspaceSnapshot(other.id)
                let canonicalOther = try XCTUnwrap(observed)
                var changedOther = other
                changedOther.currentPromptText = "unrelated current authority update"
                _ = try await client.saveFailClosed(
                    changedOther,
                    fileURL: otherURL,
                    expectedWorkspaceRevision: canonicalOther.revisions.workingRevision,
                    expectedContentDigest: canonicalOther.document.contentDigest
                )
                let delayed = await client.snapshot()
                let extra = WorkspaceModel(name: "CatalogAdvance", repoPaths: [fixture.rootPaths[0]])
                _ = try await client.create(extra, fileURL: fixture.manager.workspaceFileURL(for: extra))
                try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[1]), to: fixture.workspace)
                let current = await client.snapshot()
                XCTAssertGreaterThan(current.catalogRevision, delayed.catalogRevision)
                let decoded = try delayed.workspaces.map {
                    try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(documentBytes: $0.document.documentBytes, fileURL: $0.document.fileURL)
                }
                fixture.manager.applyDomainWorkspaceProjection(
                    decoded,
                    canonicalRepoPathsByWorkspaceID: Dictionary(uniqueKeysWithValues: delayed.workspaces.map { ($0.document.workspaceID, $0.document.metadata.repoPaths) }),
                    fileURLsByWorkspaceID: Dictionary(uniqueKeysWithValues: delayed.workspaces.map { ($0.document.workspaceID, $0.document.fileURL) }),
                    revisionsByWorkspaceID: Dictionary(uniqueKeysWithValues: delayed.workspaces.map { ($0.document.workspaceID, $0.revisions) }),
                    digestsByWorkspaceID: Dictionary(uniqueKeysWithValues: delayed.workspaces.map { ($0.document.workspaceID, $0.document.contentDigest) }),
                    healthByWorkspaceID: Dictionary(uniqueKeysWithValues: delayed.workspaces.map { ($0.document.workspaceID, $0.health) }),
                    catalogRevision: delayed.catalogRevision,
                    preferredActiveWorkspaceID: fixture.workspace.id,
                    publicationSequence: delayed.publicationSequence
                )
                XCTAssertEqual(fixture.manager.workspace(withID: other.id)?.currentPromptText, changedOther.currentPromptText)
                XCTAssertEqual(fixture.manager.activeWorkspace?.repoPaths, fixture.rootPaths)
            }
        }

        func testWindowCloseReleasesScopedDebugGateAndJoinsItsHeldAttempt() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(configuration: { [$0[0]] }) { fixture in
                let gate = try fixture.manager.armRootPreloadGateForTesting(
                    windowID: -944,
                    workspaceID: fixture.workspace.id,
                    rootIndex: 1,
                    expectedPath: fixture.rootPaths[1]
                )
                let entered = XCTestExpectation(description: "scoped DEBUG gate held before window close")
                let done = XCTestExpectation(description: "window close cancels active add consumer")
                gate.didHold = { entered.fulfill() }
                fixture.startOwnedTask {
                    do { try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[1]), to: fixture.workspace)
                        XCTFail("Closed add succeeded")
                    } catch is CancellationError {}
                    catch { XCTFail("Unexpected close error: \(error)") }
                    done.fulfill()
                }
                try await fixture.awaitGateEvent(entered)
                fixture.manager.prepareForWindowClose()
                try await fixture.awaitGateEvent(done)
                try await fixture.perform("window close joins scoped gate without manual release") { await fixture.manager.awaitRootReconciliationShutdown() }
                XCTAssertNil(fixture.manager.rootReconciliationStateForTesting.attemptID)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 0)
                XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), [fixture.rootPaths[0]])
            }
        }

        func testDelayedCanonicalProjectionCannotRegressNewerCommandOutcomeBaselineOrModel() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["A", "B", "C"], configuration: { Array($0.prefix(2)) }) { fixture in
                let before = try await fixture.capturePassive()
                let oldCatalog = await fixture.runtime.workspaceStore.snapshot()
                await fixture.bridge.stopAndJoinForTesting()
                defer { fixture.bridge.start() }
                try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[2]), to: fixture.workspace)
                let newerModel = try XCTUnwrap(fixture.manager.workspace(withID: fixture.workspace.id))
                let newer = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                XCTAssertGreaterThan(try XCTUnwrap(newer).revisions.workingRevision, before.canonical.revisions.workingRevision)
                // Deliver an actually captured canonical publication after the command outcome.
                // No synthetic domain outcome or persistence override is involved.
                fixture.manager.applyDomainWorkspaceProjection(
                    [before.model],
                    canonicalRepoPathsByWorkspaceID: [fixture.workspace.id: before.canonical.document.metadata.repoPaths],
                    fileURLsByWorkspaceID: [fixture.workspace.id: fixture.workspaceURL],
                    revisionsByWorkspaceID: [fixture.workspace.id: before.canonical.revisions],
                    digestsByWorkspaceID: [fixture.workspace.id: before.canonical.document.contentDigest],
                    healthByWorkspaceID: [fixture.workspace.id: before.canonical.health],
                    catalogRevision: oldCatalog.catalogRevision,
                    preferredActiveWorkspaceID: fixture.workspace.id,
                    publicationSequence: oldCatalog.publicationSequence
                )
                XCTAssertEqual(fixture.manager.workspace(withID: fixture.workspace.id), newerModel)
                XCTAssertEqual(fixture.manager.debugDomainAuthorityBaseline(for: fixture.workspace.id).revisions, newer?.revisions)
                XCTAssertEqual(fixture.manager.debugRepoPathBaselineForWorkspace(fixture.workspace.id), fixture.rootPaths)
                fixture.manager.applyDomainAuthorityMetadataProjection(
                    revisionsByWorkspaceID: [fixture.workspace.id: before.canonical.revisions],
                    digestsByWorkspaceID: [fixture.workspace.id: before.canonical.document.contentDigest],
                    healthByWorkspaceID: [fixture.workspace.id: before.canonical.health],
                    catalogRevision: oldCatalog.catalogRevision, publicationSequence: oldCatalog.publicationSequence
                )
                XCTAssertEqual(fixture.manager.debugDomainAuthorityBaseline(for: fixture.workspace.id).revisions, newer?.revisions)
            }
        }

        func testCanonicalRestorationDuringRealRemovalSupersedesHeldUnloadWithoutReplacingIDs() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let before = try await fixture.capturePassive()
                let entered = XCTestExpectation(description: "real removal held before unwanted-root unload")
                let gate = fixture.makeGate()
                var held = false
                fixture.manager.rootReconciliationGateForTesting = { event in
                    guard event.phase == .beforeUnload, !held else { return }
                    held = true
                    entered.fulfill()
                    await gate.wait()
                }
                let remove = fixture.startOwnedTask { await fixture.manager.removeActiveWorkspaceRoot(path: fixture.rootPaths[1]) }
                try await fixture.awaitGateEvent(entered)
                // Establish the second origin's current CAS after the ordinary removal
                // autosave has settled, while the explicit root flight remains held.
                try await fixture.settle()
                let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -945)
                let observed = await client.canonicalWorkspaceSnapshot(fixture.workspace.id)
                let canonical = try XCTUnwrap(observed)
                var restored = try XCTUnwrap(fixture.manager.activeWorkspace)
                restored.repoPaths = fixture.rootPaths
                let restoration = try await client.saveFailClosed(
                    restored,
                    fileURL: fixture.workspaceURL,
                    expectedWorkspaceRevision: canonical.revisions.workingRevision,
                    expectedContentDigest: canonical.document.contentDigest
                )
                XCTAssertEqual(restoration.finalOutcome?.disposition, .applied)
                try await fixture.settle()
                try await fixture.perform("obsolete removal consumer settles while worker still held") { await remove.value }
                XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), fixture.rootPaths)
                gate.release()
                let ticket = try XCTUnwrap(fixture.manager.currentRootReconciliationTicketForTesting)
                _ = try await fixture.perform("restored canonical attempt completes") { try await fixture.manager.awaitRootReconciliationCompletion(ticket: ticket) }
                let after = try await fixture.capturePassive()
                XCTAssertEqual(after.model.repoPaths, fixture.rootPaths)
                XCTAssertEqual(after.disk.repoPaths, fixture.rootPaths)
                XCTAssertEqual(after.readinessObservation.requestedRoots, before.readinessObservation.requestedRoots)
                XCTAssertNotNil(fixture.manager.domainWorkspaceAuthorityIssue)
            }
        }

        func testCanonicalDeletionDuringHeldActiveAddSettlesUnavailableBeforeCleanup() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(configuration: { [$0[0]] }) { fixture in
                let entered = XCTestExpectation(description: "active add held for canonical deletion")
                let done = XCTestExpectation(description: "deleted workspace add reports unavailable")
                let gate = fixture.makeGate()
                var held = false
                fixture.manager.rootReconciliationGateForTesting = { event in
                    guard event.phase == .beforeLoad, !held else { return }
                    held = true
                    entered.fulfill()
                    await gate.wait()
                }
                fixture.startOwnedTask {
                    do { try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[1]), to: fixture.workspace)
                        XCTFail("Deleted add succeeded")
                    } catch let failure as WorkspaceRootReadinessFailure { XCTAssertEqual(failure.reason, .workspaceUnavailable) }
                    catch { XCTFail("Unexpected deletion error: \(error)") }
                    done.fulfill()
                }
                try await fixture.awaitGateEvent(entered)
                let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -945)
                let before = await client.snapshot()
                let canonical = await client.canonicalWorkspaceSnapshot(fixture.workspace.id)
                let outcome = await client.delete(
                    workspaceID: fixture.workspace.id,
                    expectedCatalogRevision: before.catalogRevision,
                    expectedWorkspaceRevision: canonical?.revisions.workingRevision
                )
                XCTAssertEqual(outcome.disposition, .applied)
                let after = await client.snapshot()
                let projected = await fixture.bridge.waitUntilProjected(through: after.publicationSequence)
                XCTAssertTrue(projected)
                try await fixture.awaitGateEvent(done)
                XCTAssertNil(fixture.manager.workspace(withID: fixture.workspace.id))
                let deleted = await client.canonicalWorkspaceSnapshot(fixture.workspace.id)
                XCTAssertNil(deleted)
                gate.release()
                await fixture.manager.awaitRootReconciliationShutdown()
            }
        }

        func testScopedDebugPreloadGateKeepsActiveAddPendingPastAdmissionDeadlineAndCheckpointVerifiesSavedBytes() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(configuration: { [$0[0]] }) { fixture in
                let gate = try fixture.manager.armRootPreloadGateForTesting(
                    windowID: -944,
                    workspaceID: fixture.workspace.id,
                    rootIndex: 1,
                    expectedPath: fixture.rootPaths[1]
                )
                let entered = XCTestExpectation(description: "scoped asynchronous pre-load gate held")
                gate.didHold = { entered.fulfill() }
                var addFinished = false
                let add = fixture.startOwnedTask {
                    do { try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[1]), to: fixture.workspace) }
                    catch { XCTFail("Held active add failed: \(error)") }
                    addFinished = true
                }
                try await fixture.awaitGateEvent(entered)
                let event = try XCTUnwrap(gate.event)
                let start = ContinuousClock.now
                do {
                    _ = try await fixture.manager.readyPrimaryRootSnapshot(workspaceID: fixture.workspace.id, expectedRepoPaths: fixture.rootPaths)
                    XCTFail("Admission cannot bypass the delayed primary load")
                } catch let failure as WorkspaceRootReadinessFailure { XCTAssertEqual(failure.reason, .rootsChanging) }
                XCTAssertGreaterThanOrEqual(start.duration(to: .now), .seconds(1.8))
                XCTAssertLessThan(start.duration(to: .now), .seconds(3))
                XCTAssertFalse(addFinished, "Active root actions do not inherit admission's two-second deadline")
                XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), [fixture.rootPaths[0]])
                fixture.manager.clearRootPreloadGateForTesting()
                try await fixture.perform("active add completion after gate release") { await add.value }
                let checkpoint = try await fixture.perform("DEBUG canonical saved-byte checkpoint") {
                    try await fixture.manager.captureRootCheckpointForTesting(windowID: -944, ticket: event.ticket, expectedRepoPaths: fixture.rootPaths)
                }
                XCTAssertTrue(checkpoint.converged)
                XCTAssertEqual(checkpoint.workingRevision, checkpoint.savedRevision)
                let captured = try await fixture.capturePassive()
                XCTAssertEqual(checkpoint.rootIDs, captured.readinessObservation.requestedRoots.map(\.id))
                XCTAssertEqual(checkpoint.savedRevision, captured.savedState.revision)
                let safeRecord = String(describing: checkpoint)
                for path in fixture.rootPaths {
                    XCTAssertFalse(safeRecord.contains(path))
                }
                XCTAssertFalse(safeRecord.contains(fixture.workspace.name))
                FileHandle.standardError.write(Data("ISSUE944 W4 checkpoint=\(safeRecord)\n".utf8))
                do {
                    _ = try fixture.manager.armRootPreloadGateForTesting(
                        windowID: -945,
                        workspaceID: fixture.workspace.id,
                        rootIndex: 1,
                        expectedPath: fixture.rootPaths[1]
                    )
                    XCTFail("A different window cannot arm this manager")
                } catch let failure as WorkspaceManagerViewModel.RootCheckpointFailureForTesting {
                    guard case .scopeMismatch = failure else { return XCTFail("Unexpected DEBUG scope error") }
                }
            }
        }

        func testCheckpointRejectsUnverifiedSavedFileBytes() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let originalBytes = try Data(contentsOf: fixture.workspaceURL)
                var foreign = try JSONDecoder().decode(WorkspaceModel.self, from: originalBytes)
                foreign.repoPaths = [fixture.rootPaths[0]]
                defer { try? originalBytes.write(to: fixture.workspaceURL, options: .atomic) }
                try JSONEncoder().encode(foreign).write(to: fixture.workspaceURL, options: .atomic)
                // Preserve the setup operation's completion until its checkpoint is observed;
                // the fixture's separate Context Builder admission may replace that result.
                let ticket = try XCTUnwrap(fixture.manager.currentRootReconciliationTicketForTesting)
                do {
                    _ = try await fixture.manager.captureRootCheckpointForTesting(windowID: -944, ticket: ticket, expectedRepoPaths: fixture.rootPaths)
                    XCTFail("DEBUG checkpoint claimed an unverified saved document")
                } catch let failure as WorkspaceManagerViewModel.RootCheckpointFailureForTesting {
                    guard case .savedBytesUnverified = failure else { return XCTFail("Unexpected checkpoint classification") }
                }
                do {
                    _ = try await fixture.capturePassive()
                    XCTFail("A stable file is not proof it represents authority's saved revision")
                } catch let failure as WorkspaceAuthorityRootTestFixture.CheckpointFailure {
                    XCTAssertEqual(failure, .savedBytesUnverified)
                }
            }
        }

        func testSelfEchoOverlayCannotBecomeCanonicalRootsDuringOtherWorkspaceProjection() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["A", "B", "C"], configuration: { Array($0.prefix(2)) }) { fixture in
                let before = try await fixture.capturePassive()
                let entered = XCTestExpectation(description: "addition proposal held before persistence")
                let gate = fixture.makeGate()
                fixture.manager.rootEditDidApplyHandlerForTesting = { id, source in
                    guard id == fixture.workspace.id, source == .rootAdd else { return }
                    entered.fulfill()
                    await gate.wait()
                }
                let add = fixture.startOwnedTask {
                    do { try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[2]), to: fixture.workspace) }
                    catch { XCTFail("Held addition failed: \(error)") }
                }
                try await fixture.awaitGateEvent(entered)
                // Exercise the real bridge self-echo path with an original-window metadata commit.
                let originClient = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -944)
                var metadata = before.model
                metadata.currentPromptText = "same-window metadata"
                _ = try await originClient.replaceWorking(
                    metadata,
                    fileURL: fixture.workspaceURL,
                    expectedWorkspaceRevision: before.canonical.revisions.workingRevision
                )
                try await fixture.settle()
                let beforeOther = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                XCTAssertEqual(beforeOther?.document.metadata.repoPaths, before.model.repoPaths)
                _ = try await fixture.createAdditionalWorkspace(name: "Other", repoPaths: [fixture.rootPaths[0]])
                let canonical = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                XCTAssertEqual(canonical?.document.metadata.repoPaths, before.model.repoPaths)
                XCTAssertEqual(fixture.manager.activeWorkspace?.repoPaths, fixture.rootPaths)
                XCTAssertEqual(
                    fixture.manager.debugRepoPathBaselineForWorkspace(fixture.workspace.id),
                    before.model.repoPaths,
                    "Bridge's optimistic presentation cache is not canonical root authority"
                )
                gate.release()
                try await fixture.perform("held addition finishes") { await add.value }
            }
        }

        func testRealSwitchJoinsHeldAddBeforeTeardownAndBackUsesNewActivation() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["A", "B", "C"], configuration: { [$0[0]] }) { fixture in
                try await fixture.perform("switch lifecycle body") {
                    let other = try await fixture.createAdditionalWorkspace(name: "Other", repoPaths: [fixture.rootPaths[2]])
                    let before = try await fixture.manager.readyPrimaryRootSnapshot(workspaceID: fixture.workspace.id, expectedRepoPaths: [fixture.rootPaths[0]])
                    let entered = XCTestExpectation(description: "active add held before load")
                    let addFinished = XCTestExpectation(description: "old add consumer invalidated by real switch")
                    let gate = fixture.makeGate()
                    var held = false
                    var switchFinished = false
                    fixture.manager.rootReconciliationGateForTesting = { event in
                        guard event.phase == .beforeLoad, !held else { return }
                        held = true
                        entered.fulfill()
                        await gate.wait()
                    }
                    fixture.startOwnedTask {
                        do {
                            try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[1]), to: fixture.workspace)
                            XCTFail("Switch must invalidate the old active add")
                        } catch let failure as WorkspaceRootReadinessFailure {
                            XCTAssertEqual(failure.reason, .staleInvocation)
                        } catch { XCTFail("Unexpected add error: \(error)") }
                        addFinished.fulfill()
                    }
                    try await fixture.awaitGateEvent(entered)
                    let switching = fixture.startOwnedTask {
                        _ = await fixture.manager.switchWorkspace(to: other, saveState: false)
                        switchFinished = true
                    }
                    try await fixture.awaitGateEvent(addFinished)
                    XCTAssertFalse(switchFinished, "Switch must join the held flight before root teardown")
                    XCTAssertEqual(fixture.manager.activeWorkspaceID, fixture.workspace.id, "Switch cannot publish activation before joining old flight")
                    let heldRoots = await fixture.files.workspaceFileContextStore.roots()
                    XCTAssertEqual(heldRoots.map(\.standardizedFullPath), [fixture.rootPaths[0]])
                    gate.release()
                    try await fixture.perform("real switch completes after old flight join") { await switching.value }
                    XCTAssertEqual(fixture.manager.activeWorkspaceID, other.id)
                    await fixture.manager.waitUntilPostSwitchGitDataLoadComplete()
                    _ = try await fixture.perform("real switch back") {
                        try await fixture.manager.switchWorkspace(to: XCTUnwrap(fixture.manager.workspace(withID: fixture.workspace.id)), saveState: false)
                    }
                    let ready = try await fixture.manager.readyPrimaryRootSnapshot(workspaceID: fixture.workspace.id, expectedRepoPaths: Array(fixture.rootPaths.prefix(2)))
                    XCTAssertNotEqual(ready.ticket.activationGeneration, before.ticket.activationGeneration)
                    XCTAssertEqual(ready.roots.map(\.standardizedFullPath), Array(fixture.rootPaths.prefix(2)))
                    do { try await fixture.manager.validatePrimaryRootSnapshot(before)
                        XCTFail("Old activation revived")
                    } catch let failure as WorkspaceRootReadinessFailure { XCTAssertEqual(failure.reason, .staleInvocation) }
                }
            }
        }

        func testRealRefreshDefersNewCanonicalTargetAndDrainsAfterBlockedSwitch() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                try await fixture.perform("refresh lifecycle body") {
                    let other = try await fixture.createAdditionalWorkspace(name: "Other", repoPaths: [fixture.rootPaths[0]])
                    FileHandle.standardError.write(Data("ISSUE944 refresh phase=seeded\n".utf8))
                    let entered = XCTestExpectation(description: "refresh uses shared flight")
                    let successor = XCTestExpectation(description: "deferred canonical target drains through shared flight")
                    let gate = fixture.makeGate()
                    var held = false
                    var successorTicket: WorkspaceRootReconciliationTicket?
                    fixture.manager.rootReconciliationGateForTesting = { event in
                        if event.phase == .beforeCompletion, !held {
                            held = true
                            entered.fulfill()
                            await gate.wait()
                        } else if event.phase == .beforeUnload, successorTicket == nil {
                            successorTicket = event.ticket
                            successor.fulfill()
                        }
                    }
                    let refresh = fixture.startOwnedTask { await fixture.manager.refreshWorkspace(soft: true, for: fixture.workspace) }
                    try await fixture.awaitGateEvent(entered)
                    FileHandle.standardError.write(Data("ISSUE944 refresh phase=held\n".utf8))
                    let observed = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                    let snapshot = try XCTUnwrap(observed)
                    var changed = try XCTUnwrap(fixture.manager.workspace(withID: fixture.workspace.id))
                    changed.repoPaths = [fixture.rootPaths[0]]
                    let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -945)
                    _ = try await client.saveFailClosed(
                        changed,
                        fileURL: fixture.workspaceURL,
                        expectedWorkspaceRevision: snapshot.revisions.workingRevision,
                        expectedContentDigest: snapshot.document.contentDigest
                    )
                    try await fixture.settle()
                    FileHandle.standardError.write(Data("ISSUE944 refresh phase=canonicalProjected\n".utf8))
                    _ = await fixture.manager.switchWorkspace(to: other, saveState: false)
                    XCTAssertEqual(fixture.manager.activeWorkspaceID, fixture.workspace.id)
                    XCTAssertTrue(fixture.manager.isRefreshing)
                    gate.release()
                    try await fixture.perform("refresh relinquishes ownership") { await refresh.value }
                    try await fixture.awaitGateEvent(successor)
                    _ = try await fixture.manager.awaitRootReconciliationCompletion(ticket: XCTUnwrap(successorTicket))
                    let after = try await fixture.capturePassive()
                    XCTAssertEqual(after.model.repoPaths, changed.repoPaths)
                    XCTAssertEqual(after.shellPaths, changed.repoPaths)
                    XCTAssertEqual(after.disk.repoPaths, changed.repoPaths)
                }
            }
        }

        func testOrdinarySaveAfterWorkingOnlyRootTransitionDoesNotRestoreStaleSavedRoots() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let before = try await fixture.capturePassive()
                var changed = before.model
                changed.repoPaths = [fixture.rootPaths[0]]
                let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -945)
                _ = try await client.replaceWorking(
                    changed,
                    fileURL: fixture.workspaceURL,
                    expectedWorkspaceRevision: before.canonical.revisions.workingRevision
                )
                try await fixture.settle()
                _ = try await fixture.manager.readyPrimaryRootSnapshot(workspaceID: fixture.workspace.id, expectedRepoPaths: changed.repoPaths)
                await fixture.manager.pollAndSaveStateAsync()
                let after = try await fixture.capturePassive()
                XCTAssertEqual(after.canonical.document.metadata.repoPaths, changed.repoPaths)
                XCTAssertEqual(after.model.repoPaths, changed.repoPaths)
                XCTAssertEqual(after.disk.repoPaths, changed.repoPaths)
            }
        }

        func testRestorationProjectionThenRepeatedNotificationsSharesOneFlight() async throws {
            try await assertRestorationNotificationOrder(notificationFirst: false)
        }

        func testRestorationNotificationThenProjectionSharesOneFlight() async throws {
            try await assertRestorationNotificationOrder(notificationFirst: true)
        }

        private func assertRestorationNotificationOrder(notificationFirst: Bool) async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                await fixture.manager.removeActiveWorkspaceRoot(path: fixture.rootPaths[1])
                let before = try await fixture.capturePassive()
                let starts = fixture.manager.rootReconciliationStateForTesting.attemptStarts
                let entered = XCTestExpectation(description: "restoration flight owns missing-root load")
                let handled = XCTestExpectation(description: "coalesced notification completed")
                let gate = fixture.makeGate()
                var ticket: WorkspaceRootReconciliationTicket?
                fixture.manager.rootReconciliationGateForTesting = { event in
                    guard event.phase == .beforeLoad, ticket == nil else { return }
                    ticket = event.ticket
                    entered.fulfill()
                    await gate.wait()
                }
                fixture.manager.rootNotificationDidFinishForTesting = { id in if id == fixture.workspace.id { handled.fulfill() } }
                if notificationFirst { await fixture.bridge.stopAndJoinForTesting() }
                var restored = before.model
                restored.repoPaths = fixture.rootPaths
                let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -945)
                _ = try await client.saveFailClosed(
                    restored,
                    fileURL: fixture.workspaceURL,
                    expectedWorkspaceRevision: before.canonical.revisions.workingRevision,
                    expectedContentDigest: before.canonical.document.contentDigest
                )
                @MainActor func notify() {
                    NotificationCenter.default.post(
                        name: .workspaceRepoPathsDidChange,
                        object: nil,
                        userInfo: ["managerID": UUID(), "workspaceID": fixture.workspace.id]
                    )
                }
                if notificationFirst { notify() }
                try await fixture.awaitGateEvent(entered)
                if notificationFirst { fixture.bridge.start() }
                for _ in 0 ..< 3 {
                    notify()
                }
                try await fixture.settle()
                let heldRoots = await fixture.files.workspaceFileContextStore.roots()
                XCTAssertEqual(heldRoots.map(\.standardizedFullPath), [fixture.rootPaths[0]])
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts, starts + 1)
                gate.release()
                try await fixture.awaitGateEvent(handled)
                let ready = try await fixture.manager.awaitRootReconciliationCompletion(ticket: XCTUnwrap(ticket))
                // The passive checkpoint must not add independent admission attempts.
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts, starts + 1)
                let after = try await fixture.capturePassive()
                XCTAssertEqual(after.model.repoPaths, fixture.rootPaths)
                XCTAssertEqual(after.disk.repoPaths, fixture.rootPaths)
                XCTAssertEqual(after.shellPaths, fixture.rootPaths)
                XCTAssertEqual(after.readinessObservation.requestedRoots, ready.roots)
                XCTAssertEqual(ready.roots.first?.id, before.primaryRoots.first?.id)
            }
        }

        func testRuntimeNotificationCannotReplaceDirtyWorkingRootsFromStaleDisk() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let before = try await fixture.capturePassive()
                var working = before.model
                working.repoPaths = [fixture.rootPaths[0]]
                let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -945)
                _ = try await client.replaceWorking(working, fileURL: fixture.workspaceURL, expectedWorkspaceRevision: before.canonical.revisions.workingRevision)
                try await fixture.settle()
                _ = try await fixture.manager.readyPrimaryRootSnapshot(workspaceID: fixture.workspace.id, expectedRepoPaths: working.repoPaths)
                let handled = XCTestExpectation(description: "production root notification handled")
                fixture.manager.rootNotificationDidFinishForTesting = { id in if id == fixture.workspace.id { handled.fulfill() } }
                NotificationCenter.default.post(
                    name: .workspaceRepoPathsDidChange,
                    object: nil,
                    userInfo: ["managerID": UUID(), "workspaceID": fixture.workspace.id]
                )
                try await fixture.awaitGateEvent(handled)
                let after = try await fixture.capturePassive()
                XCTAssertEqual(after.canonical.document.metadata.repoPaths, working.repoPaths)
                XCTAssertEqual(after.model.repoPaths, working.repoPaths)
                XCTAssertEqual(after.shellPaths, working.repoPaths)
                XCTAssertEqual(after.readinessObservation.requestedRoots.map(\.standardizedFullPath), working.repoPaths)
                XCTAssertEqual(after.diskBytes, before.diskBytes)
                XCTAssertGreaterThan(after.canonical.revisions.workingRevision, after.canonical.revisions.savedRevision)
            }
        }

        func testCanonicalRestorationProjectionAloneStartsSharedReconciliation() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let previousLogging = WorkspaceRestorePerfLog.debugProcessOverrideEnabled
                WorkspaceRestorePerfLog.setDebugProcessOverrideEnabled(true)
                defer {
                    fixture.commandWillExecute = nil
                    let id = WorkspaceRestorePerfLog.shortID(fixture.workspace.id)
                    for line in WorkspaceRestorePerfLog.recentMetricLinesSnapshot(limit: 2000)
                        where line.contains(id) && line.contains("workspaceSave")
                    {
                        FileHandle.standardError.write(Data("ISSUE944 saveOrigin \(line)\n".utf8))
                    }
                    WorkspaceRestorePerfLog.setDebugProcessOverrideEnabled(previousLogging)
                }
                fixture.commandWillExecute = { envelope in
                    let phase: String
                    let payloadIsRemoval: Bool?
                    switch envelope.command {
                    case let .replaceWorkingDocument(document):
                        phase = "working"
                        payloadIsRemoval = document.metadata.repoPaths == [fixture.rootPaths[0]]
                    case .saveWorkspaceDocument:
                        phase = "saved"
                        payloadIsRemoval = nil
                    default: return
                    }
                    let canonical = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                    let baseline = fixture.manager.debugDomainAuthorityBaseline(for: fixture.workspace.id)
                    FileHandle.standardError.write(Data("ISSUE944 envelopeOrigin phase=\(phase) operation=\(envelope.operationID) policy=\(String(describing: envelope.conflictRecoveryPolicy)) payloadIsRemoval=\(String(describing: payloadIsRemoval)) expected=\(String(describing: envelope.expectedWorkspaceRevision)) canonicalRevision=\(String(describing: canonical?.revisions.workingRevision)) canonicalIsRemoval=\(canonical?.document.metadata.repoPaths == [fixture.rootPaths[0]]) canonicalRestored=\(canonical?.document.metadata.repoPaths == fixture.rootPaths) managerRevision=\(String(describing: baseline.revisions?.workingRevision)) baselineRestored=\(fixture.manager.debugRepoPathBaselineForWorkspace(fixture.workspace.id) == fixture.rootPaths) modelRestored=\(fixture.manager.activeWorkspace?.repoPaths == fixture.rootPaths) version=\(fixture.manager.debugStateVersionForWorkspace(fixture.workspace.id)) savedVersion=\(String(describing: fixture.manager.debugLastSavedVersionForWorkspace(fixture.workspace.id)))\n".utf8))
                }
                await fixture.manager.removeActiveWorkspaceRoot(path: fixture.rootPaths[1])
                let removed = try await fixture.capturePassive()
                XCTAssertEqual(removed.model.repoPaths, [fixture.rootPaths[0]])
                let entered = XCTestExpectation(description: "canonical projection requests missing root load")
                let gate = fixture.makeGate()
                var observedTicket: WorkspaceRootReconciliationTicket?
                fixture.manager.rootReconciliationGateForTesting = { event in
                    guard event.ticket.workspaceID == fixture.workspace.id,
                          event.phase == .beforeLoad, observedTicket == nil else { return }
                    observedTicket = event.ticket
                    entered.fulfill()
                    await gate.wait()
                }
                var restored = removed.model
                restored.repoPaths = fixture.rootPaths
                let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -945)
                let outcome = try await client.saveFailClosed(
                    restored, fileURL: fixture.workspaceURL,
                    expectedWorkspaceRevision: removed.canonical.revisions.workingRevision,
                    expectedContentDigest: removed.canonical.document.contentDigest
                )
                XCTAssertEqual(outcome.finalOutcome?.disposition, .applied)
                FileHandle.standardError.write(Data("ISSUE944 restorationDiagnostic phase=externalCommit working=\(String(describing: outcome.working?.disposition)) saved=\(String(describing: outcome.saved?.disposition))\n".utf8))
                try await fixture.settle()
                let diagnostic = await client.canonicalWorkspaceSnapshot(fixture.workspace.id)
                let diagnosticDisk = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: fixture.workspaceURL))
                FileHandle.standardError.write(Data("ISSUE944 restorationDiagnostic phase=afterSetupDrain canonicalRestored=\(diagnostic?.document.metadata.repoPaths == fixture.rootPaths) diskRestored=\(diagnosticDisk.repoPaths == fixture.rootPaths) modelRestored=\(fixture.manager.activeWorkspace?.repoPaths == fixture.rootPaths) revisions=\(String(describing: diagnostic?.revisions)) observedTicket=\(String(describing: observedTicket)) currentTicket=\(String(describing: fixture.manager.currentRootReconciliationTicketForTesting))\n".utf8))
                // No request/ready helper may manufacture the production trigger under test.
                try await fixture.awaitGateEvent(entered)
                gate.release()
                let ticket = try XCTUnwrap(observedTicket)
                let ready: WorkspacePrimaryRootSnapshot
                do { ready = try await fixture.manager.awaitRootReconciliationCompletion(ticket: ticket) }
                catch {
                    let terminal = await client.canonicalWorkspaceSnapshot(fixture.workspace.id)
                    let disk = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: fixture.workspaceURL))
                    FileHandle.standardError.write(Data("ISSUE944 restorationDiagnostic phase=completionFailure canonicalRestored=\(terminal?.document.metadata.repoPaths == fixture.rootPaths) diskRestored=\(disk.repoPaths == fixture.rootPaths) modelRestored=\(fixture.manager.activeWorkspace?.repoPaths == fixture.rootPaths) revisions=\(String(describing: terminal?.revisions)) error=\(error)\n".utf8))
                    throw error
                }
                let after = try await fixture.capturePassive()
                XCTAssertEqual(after.model.repoPaths, fixture.rootPaths)
                XCTAssertEqual(after.disk.repoPaths, fixture.rootPaths)
                XCTAssertEqual(after.readinessObservation.requestedRoots, ready.roots)
                XCTAssertEqual(after.shellPaths, fixture.rootPaths)
                XCTAssertEqual(after.canonical.revisions.workingRevision, after.canonical.revisions.savedRevision)
            }
        }

        func testAcceptedTargetRemovesUnwantedPrimaryAndReturnsOrderedQueryableIDs() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let before = try await fixture.capturePassive()
                XCTAssertEqual(before.readinessObservation.requestedRoots.map(\.standardizedFullPath), fixture.rootPaths)
                XCTAssertTrue(before.readinessObservation.nonqueryablePaths.isEmpty)
                fixture.manager.acceptRootReconciliationTarget(workspaceID: fixture.workspace.id, repoPaths: [fixture.rootPaths[0]])
                let ticket = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                let ready = try await fixture.perform("accepted target readiness") {
                    try await fixture.manager.awaitRootReconciliation(ticket: ticket, deadline: .now.advanced(by: .seconds(10)))
                }
                XCTAssertEqual(ready.roots.map(\.standardizedFullPath), [fixture.rootPaths[0]])
                XCTAssertEqual(ready.roots.map(\.id), before.primaryRoots.filter { $0.standardizedFullPath == fixture.rootPaths[0] }.map(\.id))
                XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), [fixture.rootPaths[0]])
                try await fixture.manager.validatePrimaryRootSnapshot(ready)
            }
        }

        func testRemovedCapturedIDFailsStaleWithoutRepairingInvocation() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let snapshot = try await fixture.manager.readyPrimaryRootSnapshot(workspaceID: fixture.workspace.id, expectedRepoPaths: fixture.rootPaths)
                await fixture.files.unloadRootFolderPath(fixture.rootPaths[1])
                do {
                    try await fixture.manager.validatePrimaryRootSnapshot(snapshot)
                    XCTFail("An invocation cannot substitute missing IDs")
                } catch let failure as WorkspaceRootReadinessFailure {
                    XCTAssertEqual(failure.reason, .staleInvocation)
                }
                let remaining = await fixture.files.workspaceFileContextStore.roots()
                XCTAssertEqual(remaining.map(\.standardizedFullPath), [fixture.rootPaths[0]])
            }
        }

        func testObservationAndProbeWaitersDetachWhileOneOwnedBatchRemainsHeld() async throws {
            for phase in [WorkspaceManagerViewModel.RootReconciliationTestEvent.Phase.observationResponse, .probeResponse] {
                try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                    let initial = try await fixture.manager.readyPrimaryRootSnapshot(workspaceID: fixture.workspace.id, expectedRepoPaths: fixture.rootPaths)
                    let entered = XCTestExpectation(description: "owned response held")
                    let gate = fixture.makeGate()
                    var armed = true
                    let starts = fixture.manager.rootReconciliationStateForTesting.attemptStarts
                    let probes = fixture.manager.rootReconciliationStateForTesting.probeBatches
                    fixture.manager.rootReconciliationGateForTesting = { event in
                        guard event.phase == phase, armed else { return }
                        armed = false
                        entered.fulfill()
                        await gate.wait()
                    }
                    let registered = XCTestExpectation(description: "four consumers registered")
                    var observedRegistration = false
                    fixture.manager.rootReconciliationWaiterCountDidChangeForTesting = { count in
                        if count == 4, !observedRegistration { observedRegistration = true
                            registered.fulfill()
                        }
                    }
                    let admissionDone = XCTestExpectation(description: "bounded admission detached")
                    let started = ContinuousClock.now
                    fixture.startOwnedTask {
                        do {
                            _ = try await fixture.manager.readyPrimaryRootSnapshot(workspaceID: fixture.workspace.id, expectedRepoPaths: fixture.rootPaths)
                            XCTFail("Held response cannot admit")
                        } catch let failure as WorkspaceRootReadinessFailure {
                            XCTAssertEqual(failure.reason, .rootsChanging)
                        } catch { XCTFail("Unexpected admission error: \(error)") }
                        admissionDone.fulfill()
                    }
                    try await fixture.awaitGateEvent(entered)
                    let validationDone = XCTestExpectation(description: "bounded validator detached")
                    fixture.startOwnedTask {
                        do {
                            try await fixture.manager.validatePrimaryRootSnapshot(initial)
                            XCTFail("Held response cannot validate")
                        } catch let failure as WorkspaceRootReadinessFailure {
                            XCTAssertEqual(failure.reason, .rootsChanging)
                        } catch { XCTFail("Unexpected validation error: \(error)") }
                        validationDone.fulfill()
                    }
                    let ticket = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                    let cancelled = XCTestExpectation(description: "cancelled waiter detached")
                    let task = fixture.startOwnedTask {
                        do { _ = try await fixture.manager.awaitRootReconciliationCompletion(ticket: ticket)
                            XCTFail("Cancelled waiter returned ready")
                        } catch is CancellationError {} catch { XCTFail("Cancellation was translated: \(error)") }
                        cancelled.fulfill()
                    }
                    let survivorDone = XCTestExpectation(description: "operation waiter survived admission budget")
                    var survivorReturned = false
                    fixture.startOwnedTask {
                        do {
                            let snapshot = try await fixture.manager.awaitRootReconciliationCompletion(ticket: ticket)
                            XCTAssertEqual(snapshot.roots, initial.roots)
                        } catch { XCTFail("Shared operation was cancelled: \(error)") }
                        survivorReturned = true
                        survivorDone.fulfill()
                    }
                    try await fixture.awaitGateEvent(registered)
                    task.cancel()
                    try await fixture.awaitGateEvent(cancelled)
                    try await fixture.awaitGateEvent(admissionDone)
                    try await fixture.awaitGateEvent(validationDone)
                    XCTAssertLessThan(started.duration(to: .now), .seconds(4))
                    XCTAssertFalse(survivorReturned)
                    XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 1)
                    XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts - starts, 1)
                    gate.release()
                    try await fixture.awaitGateEvent(survivorDone)
                    XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 0)
                    XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.probeBatches - probes, 1)
                    fixture.manager.rootReconciliationGateForTesting = nil
                }
            }
        }

        private func attempt(_ fixture: WorkspaceAuthorityRootTestFixture, paths: [String]) async throws -> WorkspacePrimaryRootSnapshot {
            fixture.manager.acceptRootReconciliationTarget(workspaceID: fixture.workspace.id, repoPaths: paths)
            let ticket = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
            return try await fixture.perform("terminal reconciliation") {
                try await fixture.manager.awaitRootReconciliation(ticket: ticket, deadline: .now.advanced(by: .seconds(10)))
            }
        }

        private func expectFailure(_ reason: WorkspaceRootReadinessFailure.Reason, _ operation: () async throws -> Void) async throws {
            do { try await operation()
                XCTFail("Expected \(reason)")
            } catch let failure as WorkspaceRootReadinessFailure { XCTAssertEqual(failure.reason, reason) }
        }

        func testWholeInvalidManifestAndWrongKindPreflightPreserveRootsOrderAndSelection() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                try await fixture.selectFixtureFiles([fixture.rootPaths[0] + "/README.md"])
                let before = try await fixture.capturePassive()
                for invalid in ["", " \n", "bad\0path", " file://bad", "FILE://bad"] {
                    try await self.expectFailure(.invalidConfiguration) {
                        _ = try await self.attempt(fixture, paths: [fixture.rootPaths[1], invalid])
                    }
                    XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), before.shellPaths)
                    XCTAssertEqual(fixture.files.snapshotSelection(), before.selection)
                    let roots = await fixture.files.workspaceFileContextStore.roots()
                    XCTAssertEqual(Set(roots.map(\.id)), Set(before.primaryRoots.map(\.id)))
                }
                try await self.expectFailure(.emptyConfiguration) { _ = try await self.attempt(fixture, paths: []) }
                await fixture.files.unloadRootFolderPath(fixture.rootPaths[1])
                try await fixture.files.loadFolder(at: URL(fileURLWithPath: fixture.rootPaths[1]), for: fixture.workspace, rootKind: .supplementalSystem)
                let beforeWrongKind = await fixture.files.workspaceFileContextStore.roots()
                try await self.expectFailure(.wrongRootKind) { _ = try await self.attempt(fixture, paths: [fixture.rootPaths[1]]) }
                let afterWrongKind = await fixture.files.workspaceFileContextStore.roots()
                XCTAssertEqual(Set(afterWrongKind), Set(beforeWrongKind))
                XCTAssertEqual(fixture.files.snapshotSelection(), before.selection)
                XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), [fixture.rootPaths[0]])
            }
        }

        func testTerminalMissingDirectoryDoesNotRetryUntilSameTicketExplicitRetry() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                await fixture.files.unloadRootFolderPath(fixture.rootPaths[1])
                try FileManager.default.removeItem(atPath: fixture.rootPaths[1])
                fixture.manager.acceptRootReconciliationTarget(workspaceID: fixture.workspace.id, repoPaths: fixture.rootPaths)
                let ticket = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                for _ in 0 ..< 2 {
                    try await self.expectFailure(.rootsUnavailable(.missingDirectory)) {
                        _ = try await fixture.manager.awaitRootReconciliation(ticket: ticket, deadline: .now.advanced(by: .seconds(10)))
                    }
                }
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts - fixture.initialRootAttemptStarts, 1)
                XCTAssertNil(fixture.manager.rootReconciliationStateForTesting.attemptID)
                try FileManager.default.createDirectory(atPath: fixture.rootPaths[1], withIntermediateDirectories: true)
                let entered = XCTestExpectation(description: "explicit retry load held")
                let gate = fixture.makeGate()
                fixture.manager.rootReconciliationGateForTesting = { event in
                    if event.phase == .beforeLoad { entered.fulfill()
                        await gate.wait()
                    }
                }
                let retry = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                XCTAssertEqual(retry, ticket)
                let done = XCTestExpectation(description: "retry returns new success not old failure")
                var finished = false
                fixture.startOwnedTask {
                    do {
                        let ready = try await fixture.manager.awaitRootReconciliation(ticket: retry, deadline: .now.advanced(by: .seconds(10)))
                        XCTAssertEqual(ready.roots.map(\.standardizedFullPath), fixture.rootPaths)
                    } catch { XCTFail("Retry reused terminal failure: \(error)") }
                    finished = true
                    done.fulfill()
                }
                try await fixture.awaitGateEvent(entered)
                XCTAssertFalse(finished)
                gate.release()
                try await fixture.awaitGateEvent(done)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts - fixture.initialRootAttemptStarts, 2)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 0)
            }
        }

        func testFreshInvocationRecapturesSamePathReplacementButOldSnapshotStaysStale() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let old = try await self.attempt(fixture, paths: fixture.rootPaths)
                await fixture.files.unloadRootFolderPath(fixture.rootPaths[1])
                try await fixture.files.loadFolder(at: URL(fileURLWithPath: fixture.rootPaths[1]), for: fixture.workspace)
                let fresh = try await fixture.manager.readyPrimaryRootSnapshot(workspaceID: fixture.workspace.id, expectedRepoPaths: fixture.rootPaths)
                XCTAssertEqual(old.ticket, fresh.ticket)
                XCTAssertEqual(old.roots[0].id, fresh.roots[0].id)
                XCTAssertNotEqual(old.roots[1].id, fresh.roots[1].id)
                try await self.expectFailure(.staleInvocation) { try await fixture.manager.validatePrimaryRootSnapshot(old) }
                try await fixture.manager.validatePrimaryRootSnapshot(fresh)
            }
        }

        func testAvailabilitySubreasonsAreTypedAndDoNotRewriteAcceptedIntent() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                for injected in [WorkspaceRootReadinessFailure.Availability.accessDenied, .loadFailed] {
                    fixture.manager.rootProbeFailureForTesting = injected
                    try await self.expectFailure(.rootsUnavailable(injected)) { _ = try await self.attempt(fixture, paths: fixture.rootPaths) }
                    XCTAssertEqual(fixture.manager.activeWorkspace?.repoPaths, fixture.rootPaths)
                }
                fixture.manager.rootProbeFailureForTesting = nil
                await fixture.files.unloadRootFolderPath(fixture.rootPaths[1])
                try FileManager.default.removeItem(atPath: fixture.rootPaths[1])
                try "not a directory".write(toFile: fixture.rootPaths[1], atomically: true, encoding: .utf8)
                try await self.expectFailure(.rootsUnavailable(.notDirectory)) { _ = try await self.attempt(fixture, paths: fixture.rootPaths) }
            }
        }

        func testAcceptedTargetSupersedesHeldLoadAndRetiringFinalizerCannotClearReplacement() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                await fixture.files.unloadRootFolderPath(fixture.rootPaths[1])
                fixture.manager.acceptRootReconciliationTarget(workspaceID: fixture.workspace.id, repoPaths: fixture.rootPaths)
                let entered = XCTestExpectation(description: "old B load held")
                let gate = fixture.makeGate()
                var oldAttempt: UUID?
                fixture.manager.rootReconciliationGateForTesting = { event in
                    if event.phase == .beforeLoad { oldAttempt = event.attemptID
                        entered.fulfill()
                        await gate.wait()
                    }
                }
                let old = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                let stale = XCTestExpectation(description: "superseded consumer settled before old cleanup")
                fixture.startOwnedTask {
                    do { _ = try await fixture.manager.awaitRootReconciliationCompletion(ticket: old)
                        XCTFail("Old intent completed ready")
                    } catch let failure as WorkspaceRootReadinessFailure { XCTAssertEqual(failure.reason, .staleInvocation) }
                    catch { XCTFail("Wrong supersession: \(error)") }
                    stale.fulfill()
                }
                try await fixture.awaitGateEvent(entered)
                fixture.manager.acceptRootReconciliationTarget(workspaceID: fixture.workspace.id, repoPaths: [fixture.rootPaths[0]])
                let latest = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                XCTAssertNotEqual(old.rootIntentGeneration, latest.rootIntentGeneration)
                try await fixture.awaitGateEvent(stale)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptID, oldAttempt)
                XCTAssertTrue(fixture.manager.rootReconciliationStateForTesting.hasPending)
                gate.release()
                let ready = try await fixture.perform("replacement survives retiring finalizer") {
                    try await fixture.manager.awaitRootReconciliationCompletion(ticket: latest)
                }
                XCTAssertEqual(ready.ticket, latest)
                XCTAssertEqual(ready.roots.map(\.standardizedFullPath), [fixture.rootPaths[0]])
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts - fixture.initialRootAttemptStarts, 2)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 0)
            }
        }

        func testCloseAndDeletionSettleWaitersBeforeHeldUnloadCleanupJoins() async throws {
            for deletion in [false, true] {
                try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                    let entered = XCTestExpectation(description: "unload ownership gate")
                    let gate = fixture.makeGate()
                    fixture.manager.rootReconciliationGateForTesting = { event in
                        if event.phase == .beforeUnload { entered.fulfill()
                            await gate.wait()
                        }
                    }
                    fixture.manager.acceptRootReconciliationTarget(workspaceID: fixture.workspace.id, repoPaths: [fixture.rootPaths[0]])
                    let ticket = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                    let settled = XCTestExpectation(description: "close/deletion waiter settled")
                    var settlements = 0
                    fixture.startOwnedTask {
                        do { _ = try await fixture.manager.awaitRootReconciliationCompletion(ticket: ticket)
                            XCTFail("Closed ownership returned ready")
                        } catch is CancellationError { XCTAssertFalse(deletion) }
                        catch let failure as WorkspaceRootReadinessFailure { XCTAssertTrue(deletion)
                            XCTAssertEqual(failure.reason, .workspaceUnavailable)
                        } catch { XCTFail("Unexpected close error: \(error)") }
                        settlements += 1
                        settled.fulfill()
                    }
                    try await fixture.awaitGateEvent(entered)
                    if deletion { fixture.manager.removeRootReconciliationTarget(workspaceID: fixture.workspace.id) }
                    else { fixture.manager.prepareForWindowClose() }
                    let joinStarted = XCTestExpectation(description: "shutdown join started")
                    let joinFinished = XCTestExpectation(description: "shutdown join finished")
                    var joined = false
                    fixture.startOwnedTask {
                        joinStarted.fulfill()
                        await fixture.manager.awaitRootReconciliationShutdown()
                        joined = true
                        joinFinished.fulfill()
                    }
                    try await fixture.awaitGateEvent(settled)
                    try await fixture.awaitGateEvent(joinStarted)
                    XCTAssertFalse(joined)
                    XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 0)
                    XCTAssertFalse(fixture.manager.rootReconciliationStateForTesting.hasPending)
                    XCTAssertFalse(fixture.manager.rootReconciliationStateForTesting.hasCompleted)
                    gate.release()
                    try await fixture.awaitGateEvent(joinFinished)
                    XCTAssertEqual(settlements, 1)
                    XCTAssertNil(fixture.manager.rootReconciliationStateForTesting.attemptID)
                    XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), fixture.rootPaths)
                }
            }
        }

        func testCompletionCancellationRaceSettlesExactlyOnce() async throws {
            for cancelFirst in [false, true] {
                try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                    let entered = XCTestExpectation(description: "completion boundary held")
                    let gate = fixture.makeGate()
                    fixture.manager.rootReconciliationGateForTesting = { event in
                        if event.phase == .beforeCompletion { entered.fulfill()
                            await gate.wait()
                        }
                    }
                    fixture.manager.acceptRootReconciliationTarget(workspaceID: fixture.workspace.id, repoPaths: fixture.rootPaths)
                    let ticket = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                    let done = XCTestExpectation(description: "completion/cancellation settles once")
                    var settlements = 0
                    let waiter = fixture.startOwnedTask {
                        do { _ = try await fixture.manager.awaitRootReconciliationCompletion(ticket: ticket) }
                        catch is CancellationError {} catch { XCTFail("Unexpected race outcome: \(error)") }
                        settlements += 1
                        done.fulfill()
                    }
                    try await fixture.awaitGateEvent(entered)
                    if cancelFirst { waiter.cancel()
                        gate.release()
                    } else { gate.release()
                        waiter.cancel()
                    }
                    try await fixture.awaitGateEvent(done)
                    await fixture.manager.awaitRootReconciliationShutdown()
                    XCTAssertEqual(settlements, 1)
                    XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 0)
                    XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts - fixture.initialRootAttemptStarts, 1)
                }
            }
        }

        func testAwayAndBackActivationInvalidatesHeldAttemptEvenWithSameManifest() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let alternate = try await fixture.createAdditionalWorkspace(name: "Other", repoPaths: [fixture.rootPaths[0]])
                let entered = XCTestExpectation(description: "activation response held")
                let gate = fixture.makeGate()
                var armed = true
                fixture.manager.rootReconciliationGateForTesting = { event in
                    if event.phase == .observationResponse, armed { armed = false
                        entered.fulfill()
                        await gate.wait()
                    }
                }
                fixture.manager.acceptRootReconciliationTarget(workspaceID: fixture.workspace.id, repoPaths: fixture.rootPaths)
                let old = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                let stale = XCTestExpectation(description: "activation waiter invalidated")
                fixture.startOwnedTask {
                    do { _ = try await fixture.manager.awaitRootReconciliationCompletion(ticket: old)
                        XCTFail("Old activation completed")
                    } catch let failure as WorkspaceRootReadinessFailure { XCTAssertEqual(failure.reason, .staleInvocation) }
                    catch { XCTFail("Unexpected activation failure: \(error)") }
                    stale.fulfill()
                }
                try await fixture.awaitGateEvent(entered)
                fixture.manager.activeWorkspace = alternate
                fixture.manager.activeWorkspace = fixture.manager.workspace(withID: fixture.workspace.id)
                let latest = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                XCTAssertEqual(latest.rootIntentGeneration, old.rootIntentGeneration)
                XCTAssertEqual(latest.activationGeneration, old.activationGeneration + 2)
                try await fixture.awaitGateEvent(stale)
                gate.release()
                let ready = try await fixture.perform("new activation ready") { try await fixture.manager.awaitRootReconciliationCompletion(ticket: latest) }
                XCTAssertEqual(ready.ticket, latest)
            }
        }

        func testEditBlockRetiresAttemptAndSameTicketResumesOnlyAfterResolution() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let entered = XCTestExpectation(description: "pre-edit response held")
                let gate = fixture.makeGate()
                var armed = true
                fixture.manager.rootReconciliationGateForTesting = { event in
                    if event.phase == .observationResponse, armed { armed = false
                        entered.fulfill()
                        await gate.wait()
                    }
                }
                fixture.manager.acceptRootReconciliationTarget(workspaceID: fixture.workspace.id, repoPaths: fixture.rootPaths)
                let ticket = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                try await fixture.awaitGateEvent(entered)
                let operation = UUID()
                fixture.manager.beginRootReconciliationEdit(workspaceID: fixture.workspace.id, operationID: operation)
                gate.release()
                await fixture.manager.awaitRootReconciliationShutdown()
                XCTAssertTrue(fixture.manager.rootReconciliationStateForTesting.hasPending)
                XCTAssertNil(fixture.manager.rootReconciliationStateForTesting.attemptID)
                try await self.expectFailure(.rootsChanging) {
                    _ = try await fixture.manager.awaitRootReconciliation(ticket: ticket, deadline: .now.advanced(by: .milliseconds(20)))
                }
                fixture.manager.endRootReconciliationEdit(workspaceID: fixture.workspace.id, operationID: operation)
                let ready = try await fixture.perform("resolved edit resumes same ticket") { try await fixture.manager.awaitRootReconciliationCompletion(ticket: ticket) }
                XCTAssertEqual(ready.ticket, ticket)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts - fixture.initialRootAttemptStarts, 2)
            }
        }

        func testBlockedAndFailedQueryableAuthorityRejectsCorrectPrimaryIDs() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let snapshot = try await self.attempt(fixture, paths: fixture.rootPaths)
                let store = fixture.files.workspaceFileContextStore
                for failure in [WorkspaceFileContextStore.PrimaryRootQueryabilityFailureForTesting.blocked, .failed] {
                    await store.setPrimaryRootQueryabilityFailureForTesting(rootID: snapshot.roots[1].id, failure: failure)
                    let observation = await store.primaryRootReadinessObservation(orderedPaths: fixture.rootPaths)
                    XCTAssertEqual(observation.requestedRoots, snapshot.roots)
                    XCTAssertEqual(observation.nonqueryablePaths, [fixture.rootPaths[1]])
                    let legacy = await store.rootScopeAvailability(.validatedSessionBoundWorkspace(canonicalRoots: Set(snapshot.roots), physicalRoots: []))
                    XCTAssertEqual(legacy, .sessionWorktreeUnavailable(missingPhysicalRootPaths: [fixture.rootPaths[1]]))
                    try await self.expectFailure(.incompleteProjection) { try await fixture.manager.validatePrimaryRootSnapshot(snapshot) }
                    try await self.expectFailure(.incompleteProjection) { _ = try await self.attempt(fixture, paths: fixture.rootPaths) }
                }
                await store.setPrimaryRootQueryabilityFailureForTesting(rootID: snapshot.roots[1].id, failure: nil)
                try await fixture.manager.validatePrimaryRootSnapshot(snapshot)
            }
        }

        func testRejectedExpectedManifestAndInactiveRequestDoNotDisplaceActiveFlight() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let alternate = try await fixture.createAdditionalWorkspace(name: "Inactive", repoPaths: [fixture.rootPaths[0]])
                let entered = XCTestExpectation(description: "active observation held")
                let gate = fixture.makeGate()
                var armed = true
                fixture.manager.rootReconciliationGateForTesting = { event in
                    if event.phase == .observationResponse, armed { armed = false
                        entered.fulfill()
                        await gate.wait()
                    }
                }
                fixture.manager.acceptRootReconciliationTarget(workspaceID: fixture.workspace.id, repoPaths: fixture.rootPaths)
                let active = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                try await fixture.awaitGateEvent(entered)
                try await self.expectFailure(.invalidConfiguration) {
                    _ = try await fixture.manager.readyPrimaryRootSnapshot(workspaceID: fixture.workspace.id, expectedRepoPaths: [fixture.rootPaths[0], ""])
                }
                let inactive = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: alternate.id))
                try await self.expectFailure(.workspaceInactive) {
                    _ = try await fixture.manager.awaitRootReconciliation(ticket: inactive, deadline: .now.advanced(by: .seconds(2)))
                }
                gate.release()
                let ready = try await fixture.manager.awaitRootReconciliation(ticket: active, deadline: .now.advanced(by: .seconds(2)))
                XCTAssertEqual(ready.ticket, active)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts - fixture.initialRootAttemptStarts, 1)
            }
        }

        func testFixtureShutdownDetachesBlockedWaiterBeforeJoiningOwnedTasks() async throws {
            var cancelled = false
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                fixture.manager.acceptRootReconciliationTarget(workspaceID: fixture.workspace.id, repoPaths: fixture.rootPaths)
                fixture.manager.beginRootReconciliationEdit(workspaceID: fixture.workspace.id, operationID: UUID())
                let ticket = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                let registered = XCTestExpectation(description: "edit-blocked waiter registered before fixture exit")
                fixture.manager.rootReconciliationWaiterCountDidChangeForTesting = { count in if count == 1 { registered.fulfill() } }
                fixture.startOwnedTask {
                    do { _ = try await fixture.manager.awaitRootReconciliation(ticket: ticket, deadline: .now.advanced(by: .milliseconds(500))) }
                    catch is CancellationError { cancelled = true }
                    catch { XCTFail("Cleanup waited for a deadline instead of detaching: \(error)") }
                }
                try await fixture.awaitGateEvent(registered)
            }
            XCTAssertTrue(cancelled)
        }

        func testCloseDuringActualDetachedUnloadJoinsRemainingLifecycleCleanup() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let store = fixture.files.workspaceFileContextStore
                let removedPath = fixture.rootPaths[1]
                let detached = XCTestExpectation(description: "real store unload detached B")
                let gate = fixture.makeGate()
                await store.setRootUnloadDidDetachHandler { paths in
                    if paths.contains(removedPath) { detached.fulfill()
                        await gate.wait()
                    }
                }
                fixture.manager.acceptRootReconciliationTarget(workspaceID: fixture.workspace.id, repoPaths: [fixture.rootPaths[0]])
                let ticket = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                let settled = XCTestExpectation(description: "consumer cancels while unload cleanup is in progress")
                fixture.startOwnedTask {
                    do { _ = try await fixture.manager.awaitRootReconciliationCompletion(ticket: ticket)
                        XCTFail("Closing attempt returned ready")
                    } catch is CancellationError {} catch { XCTFail("Unexpected teardown failure: \(error)") }
                    settled.fulfill()
                }
                try await fixture.awaitGateEvent(detached)
                let during = await store.roots()
                XCTAssertFalse(during.contains { $0.standardizedFullPath == removedPath })
                fixture.manager.prepareForWindowClose()
                try await fixture.awaitGateEvent(settled)
                XCTAssertNotNil(fixture.manager.rootReconciliationStateForTesting.attemptID)
                gate.release()
                await fixture.manager.awaitRootReconciliationShutdown()
                await store.setRootUnloadDidDetachHandler(nil)
                XCTAssertNil(fixture.manager.rootReconciliationStateForTesting.attemptID)
                XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), [fixture.rootPaths[0]])
                let final = await store.roots()
                XCTAssertEqual(final.map(\.standardizedFullPath), [fixture.rootPaths[0]])
            }
        }

        func testBlockedDirectoryProbeDoesNotBlockWindowCloseOrSwitch() async throws {
            for closesWindow in [false, true] {
                try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["A", "B", "C"]) { fixture in
                    let alternate = try await fixture.createAdditionalWorkspace(
                        name: "Alternate",
                        repoPaths: [fixture.rootPaths[2]]
                    )
                    let checkpoint = RootDirectoryProbeCheckpoint(heldPhase: .beforeFileSystem)
                    fixture.manager.rootDirectoryProbeCheckpointForTesting = checkpoint.checkpoint
                    defer {
                        checkpoint.release()
                        fixture.manager.rootDirectoryProbeCheckpointForTesting = nil
                    }
                    _ = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                    try await fixture.awaitGateEvent(checkpoint.entered)

                    let finished = XCTestExpectation(description: "lifecycle transition detached from immutable read")
                    fixture.startOwnedTask {
                        if closesWindow {
                            fixture.manager.prepareForWindowClose()
                            await fixture.manager.awaitRootReconciliationShutdown()
                        } else {
                            _ = await fixture.manager.switchWorkspace(to: alternate, saveState: false)
                        }
                        finished.fulfill()
                    }
                    await self.fulfillment(of: [finished], timeout: 1)
                    XCTAssertLessThanOrEqual(
                        fixture.manager.rootReconciliationStateForTesting.outstandingProbes,
                        2
                    )
                    XCTAssertGreaterThanOrEqual(
                        fixture.manager.rootReconciliationStateForTesting.outstandingProbes,
                        1
                    )
                    if closesWindow {
                        XCTAssertNil(fixture.manager.rootReconciliationStateForTesting.attemptID)
                    }

                    checkpoint.release()
                    await self.fulfillment(of: [checkpoint.finished], timeout: 1)
                    fixture.manager.rootDirectoryProbeCheckpointForTesting = nil
                }
            }
        }

        func testRetiredDirectoryProbeCannotPublishIntoNewActivation() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["A", "B", "C"]) { fixture in
                let alternate = try await fixture.createAdditionalWorkspace(
                    name: "Alternate",
                    repoPaths: [fixture.rootPaths[2]]
                )
                let checkpoint = RootDirectoryProbeCheckpoint(heldPhase: .afterFileSystem)
                fixture.manager.rootDirectoryProbeCheckpointForTesting = checkpoint.checkpoint
                defer {
                    checkpoint.release()
                    fixture.manager.rootDirectoryProbeCheckpointForTesting = nil
                }
                let oldTicket = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                let oldSettled = XCTestExpectation(description: "retired consumer settled before late read")
                fixture.startOwnedTask {
                    do {
                        _ = try await fixture.manager.awaitRootReconciliationCompletion(ticket: oldTicket)
                        XCTFail("Retired consumer returned ready")
                    } catch let failure as WorkspaceRootReadinessFailure {
                        XCTAssertEqual(failure.reason, .staleInvocation)
                    } catch {
                        XCTFail("Unexpected retired consumer error: \(error)")
                    }
                    oldSettled.fulfill()
                }
                try await fixture.awaitGateEvent(checkpoint.entered)
                _ = await fixture.manager.switchWorkspace(to: alternate, saveState: false)
                try await fixture.awaitGateEvent(oldSettled)
                _ = try await fixture.manager.readyPrimaryRootSnapshot(
                    workspaceID: alternate.id,
                    expectedRepoPaths: [fixture.rootPaths[2]]
                )

                let activeID = fixture.manager.activeWorkspaceID
                let rootsBeforeLateResult = await fixture.files.workspaceFileContextStore.roots()
                let shellsBeforeLateResult = fixture.files.visibleRootShellProjections
                XCTAssertLessThanOrEqual(
                    fixture.manager.rootReconciliationStateForTesting.outstandingProbes,
                    2
                )
                XCTAssertGreaterThanOrEqual(
                    fixture.manager.rootReconciliationStateForTesting.outstandingProbes,
                    1
                )

                checkpoint.release()
                await self.fulfillment(of: [checkpoint.finished], timeout: 1)
                try await fixture.settle()
                fixture.manager.rootDirectoryProbeCheckpointForTesting = nil

                let rootsAfterLateResult = await fixture.files.workspaceFileContextStore.roots()
                XCTAssertEqual(fixture.manager.activeWorkspaceID, activeID)
                XCTAssertEqual(rootsAfterLateResult, rootsBeforeLateResult)
                XCTAssertEqual(fixture.files.visibleRootShellProjections, shellsBeforeLateResult)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 0)
                XCTAssertLessThanOrEqual(
                    fixture.manager.rootReconciliationStateForTesting.outstandingProbes,
                    1
                )
            }
        }

        func testProbeAndCompletionResponsesReobserveExactIDsBeforePublishingSuccess() async throws {
            for phase in [WorkspaceManagerViewModel.RootReconciliationTestEvent.Phase.probeResponse, .beforeCompletion] {
                try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                    let old = try await self.attempt(fixture, paths: fixture.rootPaths)
                    let entered = XCTestExpectation(description: "probe response before exact ID reobservation")
                    let gate = fixture.makeGate()
                    fixture.manager.rootReconciliationGateForTesting = { event in
                        if event.phase == phase { entered.fulfill()
                            await gate.wait()
                        }
                    }
                    let ticket = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                    try await fixture.awaitGateEvent(entered)
                    await fixture.files.unloadRootFolderPath(fixture.rootPaths[1])
                    try await fixture.files.loadFolder(at: URL(fileURLWithPath: fixture.rootPaths[1]), for: fixture.workspace)
                    gate.release()
                    try await self.expectFailure(.staleInvocation) {
                        _ = try await fixture.manager.awaitRootReconciliation(ticket: ticket, deadline: .now.advanced(by: .seconds(10)))
                    }
                    fixture.manager.rootReconciliationGateForTesting = nil
                    let fresh = try await fixture.manager.readyPrimaryRootSnapshot(workspaceID: fixture.workspace.id, expectedRepoPaths: fixture.rootPaths)
                    XCTAssertNotEqual(old.roots[1].id, fresh.roots[1].id)
                }
            }
        }

        func testOrderedDuplicateManifestRetainsIDsAndAttachesCanonicalRootWithoutShell() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let original = try await self.attempt(fixture, paths: fixture.rootPaths)
                let reordered = try await self.attempt(fixture, paths: [" " + fixture.rootPaths[1] + "\n", fixture.rootPaths[0], fixture.rootPaths[1]])
                XCTAssertEqual(reordered.roots.map(\.id), [original.roots[1].id, original.roots[0].id])
                XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), [fixture.rootPaths[1], fixture.rootPaths[0]])
                await fixture.files.unloadRootFolderPath(fixture.rootPaths[1])
                // Deliberate canonical-only setup, not a readiness boundary: the worker must use
                // the real loadFolder attachment path and preserve this actor-owned ID.
                let canonical = try await fixture.files.workspaceFileContextStore.loadRoot(
                    path: fixture.rootPaths[1], isSystemRoot: false, kind: .primaryWorkspace,
                    respectRepoIgnore: fixture.files.respectRepoIgnore,
                    respectCursorignore: fixture.files.respectCursorignore,
                    skipSymlinks: fixture.files.skipSymlinks,
                    enableHierarchicalIgnores: fixture.files.enableHierarchicalIgnores
                )
                XCTAssertFalse(fixture.files.visibleRootShellProjections.contains { $0.fullPath == fixture.rootPaths[1] })
                let attached = try await self.attempt(fixture, paths: fixture.rootPaths)
                XCTAssertEqual(attached.roots[1].id, canonical.id)
                XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), fixture.rootPaths)
            }
        }

        func testAdditionalDirectoryValidationUsesOwnedBatchAndCannotReuseDifferentProbeResult() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let snapshot = try await self.attempt(fixture, paths: fixture.rootPaths)
                let directory = fixture.base.path
                let regularFile = fixture.rootPaths[0] + "/README.md"
                try await fixture.manager.validatePrimaryRootSnapshot(snapshot, additionalDirectoryPaths: [directory])
                let entered = XCTestExpectation(description: "first additional-directory probe held")
                let gate = fixture.makeGate()
                var armed = true
                fixture.manager.rootReconciliationGateForTesting = { event in
                    if event.phase == .probeResponse, armed { armed = false
                        entered.fulfill()
                        await gate.wait()
                    }
                }
                let firstDone = XCTestExpectation(description: "valid directory validation preserved")
                fixture.startOwnedTask {
                    do {
                        try await fixture.manager.validatePrimaryRootSnapshot(
                            snapshot,
                            additionalDirectoryPaths: [directory]
                        )
                    } catch { XCTFail("Valid validation was evicted: \(error)") }
                    firstDone.fulfill()
                }
                try await fixture.awaitGateEvent(entered)
                let attempts = fixture.manager.rootReconciliationStateForTesting.attemptStarts
                let queued = XCTestExpectation(description: "different-directory validation queued")
                queued.assertForOverFulfill = false
                fixture.manager.rootReconciliationWaiterCountDidChangeForTesting = { count in
                    if count >= 2 { queued.fulfill() }
                }
                let done = XCTestExpectation(description: "latest directory receives its own classified probe")
                fixture.startOwnedTask {
                    do { try await fixture.manager.validatePrimaryRootSnapshot(snapshot, additionalDirectoryPaths: [regularFile])
                        XCTFail("Regular file admitted as provider directory")
                    } catch let failure as WorkspaceRootReadinessFailure { XCTAssertEqual(failure.reason, .rootsUnavailable(.notDirectory)) }
                    catch { XCTFail("Unexpected provider directory error: \(error)") }
                    done.fulfill()
                }
                try await fixture.awaitGateEvent(queued)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts, attempts)
                XCTAssertTrue(fixture.manager.rootReconciliationStateForTesting.hasPending)
                gate.release()
                try await fixture.awaitGateEvent(firstDone)
                try await fixture.awaitGateEvent(done)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts, attempts + 1)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 0)
            }
        }

        func testConcurrentAdmissionDoesNotCancelSameTicketValidation() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let snapshot = try await self.attempt(fixture, paths: fixture.rootPaths)
                let entered = XCTestExpectation(description: "provider-directory validation held")
                let gate = fixture.makeGate()
                var armed = true
                fixture.manager.rootReconciliationGateForTesting = { event in
                    guard event.phase == .probeResponse, armed else { return }
                    armed = false
                    entered.fulfill()
                    await gate.wait()
                }

                let validationDone = XCTestExpectation(description: "same-ticket validation succeeds")
                fixture.startOwnedTask {
                    do {
                        try await fixture.manager.validatePrimaryRootSnapshot(
                            snapshot,
                            additionalDirectoryPaths: [fixture.base.path]
                        )
                    } catch { XCTFail("Admission cancelled healthy validation: \(error)") }
                    validationDone.fulfill()
                }
                try await fixture.awaitGateEvent(entered)

                let queued = XCTestExpectation(description: "same-ticket admission queued")
                queued.assertForOverFulfill = false
                fixture.manager.rootReconciliationWaiterCountDidChangeForTesting = { count in
                    if count >= 2 { queued.fulfill() }
                }
                let admissionDone = XCTestExpectation(description: "same-ticket admission succeeds")
                fixture.startOwnedTask {
                    do {
                        let admitted = try await fixture.manager.readyPrimaryRootSnapshot(
                            workspaceID: fixture.workspace.id,
                            expectedRepoPaths: fixture.rootPaths
                        )
                        XCTAssertEqual(admitted.ticket, snapshot.ticket)
                        XCTAssertEqual(admitted.roots, snapshot.roots)
                    } catch { XCTFail("Same-ticket admission failed: \(error)") }
                    admissionDone.fulfill()
                }
                try await fixture.awaitGateEvent(queued)
                XCTAssertTrue(fixture.manager.rootReconciliationStateForTesting.hasPending)
                gate.release()
                try await fixture.awaitGateEvent(validationDone)
                try await fixture.awaitGateEvent(admissionDone)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 0)
            }
        }

        func testCancelledQueuedValidationIsPrunedWithoutRetiringLifecycleRequest() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let snapshot = try await self.attempt(fixture, paths: fixture.rootPaths)
                let entered = XCTestExpectation(description: "lifecycle probe held")
                let gate = fixture.makeGate()
                var armed = true
                fixture.manager.rootReconciliationGateForTesting = { event in
                    guard event.phase == .probeResponse, armed else { return }
                    armed = false
                    entered.fulfill()
                    await gate.wait()
                }
                let ticket = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                try await fixture.awaitGateEvent(entered)

                let registered = XCTestExpectation(description: "queued validation waiter registered")
                registered.assertForOverFulfill = false
                fixture.manager.rootReconciliationWaiterCountDidChangeForTesting = { count in
                    if count == 1 { registered.fulfill() }
                }
                let cancelled = XCTestExpectation(description: "queued validation cancelled")
                let validation = fixture.startOwnedTask {
                    do {
                        try await fixture.manager.validatePrimaryRootSnapshot(
                            snapshot,
                            additionalDirectoryPaths: [fixture.base.path]
                        )
                        XCTFail("Cancelled validation returned ready")
                    } catch is CancellationError {} catch {
                        XCTFail("Unexpected queued cancellation error: \(error)")
                    }
                    cancelled.fulfill()
                }
                try await fixture.awaitGateEvent(registered)
                fixture.manager.rootReconciliationWaiterCountDidChangeForTesting = nil
                validation.cancel()
                try await fixture.awaitGateEvent(cancelled)
                XCTAssertFalse(fixture.manager.rootReconciliationStateForTesting.hasPending)
                XCTAssertNotNil(fixture.manager.rootReconciliationStateForTesting.attemptID)

                gate.release()
                _ = try await fixture.manager.awaitRootReconciliationCompletion(ticket: ticket)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 0)
            }
        }

        func testAdditionalValidationNeverRetiresSharedRootOperation() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let snapshot = try await self.attempt(fixture, paths: fixture.rootPaths)
                let gate = fixture.makeGate()
                let entered = XCTestExpectation(description: "root operation probe held")
                var armed = true
                fixture.manager.rootReconciliationGateForTesting = { event in
                    if event.phase == .probeResponse, armed { armed = false
                        entered.fulfill()
                        await gate.wait()
                    }
                }
                let ticket = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                let rootDone = XCTestExpectation(description: "shared root operation completed independently")
                fixture.startOwnedTask {
                    do { _ = try await fixture.manager.awaitRootReconciliationCompletion(ticket: ticket) }
                    catch { XCTFail("Validation cancelled shared lifecycle: \(error)") }
                    rootDone.fulfill()
                }
                try await fixture.awaitGateEvent(entered)
                let registered = XCTestExpectation(description: "validation registered behind operation")
                fixture.manager.rootReconciliationWaiterCountDidChangeForTesting = { count in
                    if count >= 1 { registered.fulfill() }
                }
                let validationDone = XCTestExpectation(description: "additional probe completes")
                fixture.startOwnedTask {
                    do { try await fixture.manager.validatePrimaryRootSnapshot(snapshot, additionalDirectoryPaths: [fixture.base.path]) }
                    catch { XCTFail("Validation did not finish: \(error)") }
                    validationDone.fulfill()
                }
                try await fixture.awaitGateEvent(registered)
                fixture.manager.rootReconciliationWaiterCountDidChangeForTesting = nil
                gate.release()
                try await fixture.awaitGateEvent(rootDone)
                try await fixture.awaitGateEvent(validationDone)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 0)
            }
        }

        func testOverlappingEditBlocksPreservePendingAttemptAndItsConsumers() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let gate = fixture.makeGate()
                let entered = XCTestExpectation(description: "attempt held before two edits")
                var armed = true
                fixture.manager.rootReconciliationGateForTesting = { event in
                    if event.phase == .observationResponse, armed { armed = false
                        entered.fulfill()
                        await gate.wait()
                    }
                }
                fixture.manager.acceptRootReconciliationTarget(workspaceID: fixture.workspace.id, repoPaths: fixture.rootPaths)
                let ticket = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                let done = XCTestExpectation(description: "original consumer survives both edit blocks")
                fixture.startOwnedTask {
                    do { _ = try await fixture.manager.awaitRootReconciliation(ticket: ticket, deadline: .now.advanced(by: .seconds(10))) }
                    catch { XCTFail("Second edit replaced the pending attempt: \(error)") }
                    done.fulfill()
                }
                try await fixture.awaitGateEvent(entered)
                let first = UUID(), second = UUID()
                fixture.manager.beginRootReconciliationEdit(workspaceID: fixture.workspace.id, operationID: first)
                fixture.manager.beginRootReconciliationEdit(workspaceID: fixture.workspace.id, operationID: second)
                fixture.manager.endRootReconciliationEdit(workspaceID: fixture.workspace.id, operationID: first)
                gate.release()
                await fixture.manager.awaitRootReconciliationShutdown()
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 1)
                fixture.manager.endRootReconciliationEdit(workspaceID: fixture.workspace.id, operationID: second)
                try await fixture.awaitGateEvent(done)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts - fixture.initialRootAttemptStarts, 2)
            }
        }

        func testDeliveredSuccessRechecksOwnershipBeforeReturningToConsumer() async throws {
            for closing in [false, true] {
                try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                    var armed = true
                    fixture.manager.rootReconciliationWaiterCountDidChangeForTesting = { count in
                        if count == 0, armed {
                            armed = false
                            if closing { fixture.manager.beginRootReconciliationShutdown() }
                            else { fixture.manager.acceptRootReconciliationTarget(workspaceID: fixture.workspace.id, repoPaths: [fixture.rootPaths[0]]) }
                        }
                    }
                    do {
                        _ = try await fixture.manager.readyPrimaryRootSnapshot(workspaceID: fixture.workspace.id, expectedRepoPaths: fixture.rootPaths)
                        XCTFail("Delivered success escaped the final ownership fence")
                    } catch is CancellationError { XCTAssertTrue(closing) }
                    catch let failure as WorkspaceRootReadinessFailure { XCTAssertFalse(closing)
                        XCTAssertEqual(failure.reason, .staleInvocation)
                    }
                    XCTAssertFalse(armed)
                    XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 0)
                }
            }
        }

        func testRemovedTargetCannotReviveAnEarlierTicketWhenAcceptedAgain() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let old = try await self.attempt(fixture, paths: fixture.rootPaths)
                fixture.manager.removeRootReconciliationTarget(workspaceID: fixture.workspace.id)
                try await self.expectFailure(.workspaceUnavailable) { try await fixture.manager.validatePrimaryRootSnapshot(old) }
                let replacement = try await self.attempt(fixture, paths: fixture.rootPaths)
                XCTAssertNotEqual(old.ticket, replacement.ticket)
                try await self.expectFailure(.staleInvocation) { try await fixture.manager.validatePrimaryRootSnapshot(old) }
                try await fixture.manager.validatePrimaryRootSnapshot(replacement)
            }
        }

        func testLifecycleAndEditClaimsCannotReturnAlreadyDeliveredReadiness() async throws {
            for edit in [false, true] {
                try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                    var armed = true
                    fixture.manager.rootReconciliationWaiterCountDidChangeForTesting = { count in
                        if count == 0, armed {
                            armed = false
                            if edit { fixture.manager.beginRootReconciliationEdit(workspaceID: fixture.workspace.id, operationID: UUID()) }
                            else { fixture.manager.cancelRootReconciliationForLifecycleTransition() }
                        }
                    }
                    try await self.expectFailure(edit ? .rootsChanging : .staleInvocation) {
                        _ = try await fixture.manager.readyPrimaryRootSnapshot(workspaceID: fixture.workspace.id, expectedRepoPaths: fixture.rootPaths)
                    }
                    XCTAssertFalse(armed)
                }
            }
        }
    }
#endif
