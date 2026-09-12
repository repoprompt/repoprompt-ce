import Combine
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceRootRemovalTests: XCTestCase {
        @MainActor
        private final class OverlaySaveSchedule {
            var additionStarted = false
            var oldSaveObserved = false
        }

        func testPassiveCheckpointDetectsOmittedActionReconciliationBeforeSeparateAdmissionRepairsIt() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let before = try await fixture.capturePassive()
                fixture.manager.omitRootReconciliationRequests = true
                defer { fixture.manager.omitRootReconciliationRequests = false }
                try await fixture.perform("real removal returns with request triggers omitted") {
                    await fixture.manager.removeActiveWorkspaceRoot(path: fixture.rootPaths[1])
                }
                let attempts = fixture.manager.rootReconciliationStateForTesting.attemptStarts
                let after = try await fixture.capturePassive()
                XCTAssertEqual(after.model.repoPaths, [fixture.rootPaths[0]])
                XCTAssertEqual(after.canonical.document.metadata.repoPaths, [fixture.rootPaths[0]])
                XCTAssertEqual(after.disk.repoPaths, [fixture.rootPaths[0]])
                // The same store/shell dimensions required by positive convergence assertions
                // must expose failure here, not be repaired by the checkpoint observer.
                XCTAssertNotEqual(after.primaryRoots.map(\.standardizedFullPath), after.model.repoPaths)
                XCTAssertEqual(after.primaryRoots, before.primaryRoots)
                XCTAssertEqual(after.shellPaths, before.shellPaths)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts, attempts)
                let context = try await fixture.admit()
                XCTAssertEqual(context.primaryRootSnapshot?.roots.map(\.standardizedFullPath), [fixture.rootPaths[0]])
                let repaired = try await fixture.capturePassive()
                assertPassiveConvergence(repaired, paths: [fixture.rootPaths[0]])
                XCTAssertGreaterThan(fixture.manager.rootReconciliationStateForTesting.attemptStarts, attempts)
                print("ISSUE944 negativeControl=omittedActionRequest passiveMismatch=true passiveAttempts=0 separateAdmissionRepaired=true")
            }
        }

        func testRootOnlySaveLeavesOmittedLocalTabEditDirtyForItsOrdinaryOwner() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(configuration: { [$0[0]] }) { fixture in
                var tab = try XCTUnwrap(fixture.manager.activeWorkspace?.composeTabs.first)
                tab.promptText = "unsaved local tab work"
                XCTAssertTrue(fixture.manager.updateComposeTabStoredOnly(tab, inWorkspaceID: fixture.workspace.id))
                let gate = fixture.makeGate()
                let entered = XCTestExpectation(description: "root-only save finished before load dirties presentation")
                fixture.manager.rootReconciliationGateForTesting = { event in
                    guard event.phase == .beforeLoad else { return }
                    entered.fulfill()
                    await gate.wait()
                }
                let add = fixture.startOwnedTask {
                    do { try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[1]), to: fixture.workspace) }
                    catch { XCTFail("Root add failed: \(error)") }
                }
                try await fixture.awaitGateEvent(entered)
                XCTAssertEqual(fixture.manager.activeWorkspace?.composeTabs.first?.promptText, tab.promptText)
                let snapshot = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                let canonical = try XCTUnwrap(snapshot)
                let working = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(documentBytes: canonical.document.documentBytes, fileURL: canonical.document.fileURL)
                XCTAssertEqual(working.repoPaths, fixture.rootPaths)
                if working.composeTabs.first?.promptText != tab.promptText {
                    XCTAssertNotEqual(fixture.manager.debugLastSavedVersionForWorkspace(fixture.workspace.id), fixture.manager.debugStateVersionForWorkspace(fixture.workspace.id), "A root-only payload must not mark omitted local work saved")
                }
                gate.release()
                await add.value
                let current = try XCTUnwrap(fixture.manager.activeWorkspace)
                _ = try await fixture.manager.saveWorkspaceToFileAsync(current, source: .directUnknown)
                let saved = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: fixture.workspaceURL))
                XCTAssertEqual(saved.composeTabs.first?.promptText, tab.promptText, "Existing ordinary save still owns local non-root work")
            }
        }

        func testExplicitRootSavePreservesCanonicalNonRootContentWhileProjectionIsHeld() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(configuration: { [$0[0]] }) { fixture in
                await fixture.bridge.stopAndJoinForTesting()
                defer { fixture.bridge.start() }
                let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -945)
                let initial = await client.canonicalWorkspaceSnapshot(fixture.workspace.id)
                let before = try XCTUnwrap(initial)
                var external = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(documentBytes: before.document.documentBytes, fileURL: before.document.fileURL)
                external.currentPromptText = "external root-independent prompt"
                external.composeTabs[0].promptText = "external root-independent tab"
                let outcome = try await client.saveFailClosed(external, fileURL: before.document.fileURL, expectedWorkspaceRevision: before.revisions.workingRevision, expectedContentDigest: before.document.contentDigest)
                XCTAssertEqual(outcome.finalOutcome?.disposition, .applied)
                let refreshed = XCTestExpectation(description: "real notification refreshed canonical authority without full projection")
                fixture.manager.rootNotificationDidFinishForTesting = { id in
                    if id == fixture.workspace.id { refreshed.fulfill() }
                }
                NotificationCenter.default.post(name: .workspaceRepoPathsDidChange, object: nil, userInfo: ["managerID": UUID(), "workspaceID": fixture.workspace.id])
                try await fixture.awaitGateEvent(refreshed)
                fixture.manager.rootNotificationDidFinishForTesting = nil
                XCTAssertNotEqual(fixture.manager.activeWorkspace?.currentPromptText, external.currentPromptText, "Projection must still be held at the stale model")
                try await fixture.perform("explicit root add completes under held non-root projection") {
                    try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[1]), to: fixture.workspace)
                }
                let observed = await client.canonicalWorkspaceSnapshot(fixture.workspace.id)
                let after = try XCTUnwrap(observed)
                let saved = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: fixture.workspaceURL))
                let working = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(documentBytes: after.document.documentBytes, fileURL: after.document.fileURL)
                XCTAssertEqual(working.repoPaths, fixture.rootPaths)
                XCTAssertEqual(working.currentPromptText, external.currentPromptText)
                XCTAssertEqual(working.composeTabs[0].promptText, external.composeTabs[0].promptText)
                XCTAssertEqual(saved.currentPromptText, external.currentPromptText)
                XCTAssertEqual(saved.composeTabs[0].promptText, external.composeTabs[0].promptText)
            }
        }

        func testOlderPendingProposalCannotReappearAfterNewerPersistenceOrEraseThirdAddition() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["A", "B", "C", "D"], configuration: { [$0[0]] }) { fixture in
                let oldApplied = XCTestExpectation(description: "old add held before persistence")
                let newerWaiting = XCTestExpectation(description: "newer persisted add awaits older edit blocker")
                let thirdApplied = XCTestExpectation(description: "third add inherits newest accepted roots")
                let gate = fixture.makeGate()
                var editCount = 0
                var observedWaiter = false
                fixture.manager.rootEditDidApplyHandlerForTesting = { _, source in
                    guard source == .rootAdd else { return }
                    editCount += 1
                    if editCount == 1 {
                        oldApplied.fulfill()
                        await gate.wait()
                    } else if editCount == 3 {
                        XCTAssertEqual(fixture.manager.activeWorkspace?.repoPaths, fixture.rootPaths)
                        thirdApplied.fulfill()
                    }
                }
                fixture.manager.rootReconciliationWaiterCountDidChangeForTesting = { count in
                    if count > 0, !observedWaiter { observedWaiter = true
                        newerWaiting.fulfill()
                    }
                }
                let first = fixture.startOwnedTask {
                    do { try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[1]), to: fixture.workspace)
                        XCTFail("Old edit was superseded")
                    } catch let failure as WorkspaceRootReadinessFailure { XCTAssertEqual(failure.reason, .staleInvocation) }
                    catch { XCTFail("Unexpected first edit failure: \(error)") }
                }
                try await fixture.awaitGateEvent(oldApplied)
                let second = fixture.startOwnedTask {
                    do { try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[2]), to: fixture.workspace) }
                    catch let failure as WorkspaceRootReadinessFailure { XCTAssertEqual(failure.reason, .staleInvocation) }
                    catch { XCTFail("Unexpected second edit failure: \(error)") }
                }
                try await fixture.awaitGateEvent(newerWaiting)
                let accepted = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(fixture.workspace.id)
                XCTAssertEqual(accepted?.document.metadata.repoPaths, Array(fixture.rootPaths.prefix(3)))
                XCTAssertEqual(fixture.manager.activeWorkspace?.repoPaths, Array(fixture.rootPaths.prefix(3)), "Ending newer persistence must not resurrect an older unresolved proposal")
                let third = fixture.startOwnedTask {
                    do { try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[3]), to: fixture.workspace) }
                    catch { XCTFail("Newest addition failed: \(error)") }
                }
                try await fixture.awaitGateEvent(thirdApplied)
                gate.release()
                try await fixture.perform("all three explicit edits settle") { await first.value
                    await second.value
                    await third.value
                }
                let after = try await fixture.capturePassive()
                self.assertPassiveConvergence(after, paths: fixture.rootPaths)
                await self.assertAdmission(fixture, capture: after)
            }
        }

        func testRemovalRejectedBeforeWorkingCommitKeepsRootIDsAndSelection() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                try await fixture.selectFixtureFiles([URL(fileURLWithPath: fixture.rootPaths[1]).appendingPathComponent("README.md").path])
                let before = try await fixture.capturePassive()
                let entered = XCTestExpectation(description: "removal working envelope held")
                let proposalEntered = XCTestExpectation(description: "removal proposal held ahead of exact save")
                let ordinaryEntered = XCTestExpectation(description: "ordinary autosave independently held")
                let gate = fixture.makeGate()
                let proposalGate = fixture.makeGate()
                let ordinaryGate = fixture.makeGate()
                let schedule = OverlaySaveSchedule()
                fixture.manager.rootEditDidApplyHandlerForTesting = { _, source in
                    guard source == .rootRemove else { return }
                    proposalEntered.fulfill()
                    await proposalGate.wait()
                }
                fixture.manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { _, _, _ in
                    let hold = await MainActor.run {
                        guard !schedule.oldSaveObserved else { return false }
                        schedule.oldSaveObserved = true
                        ordinaryEntered.fulfill()
                        return true
                    }
                    if hold { await ordinaryGate.wait() }
                }
                var captured: DomainWorkspaceCommandEnvelope?
                fixture.commandWillExecute = { envelope in
                    guard case let .replaceWorkingDocument(document) = envelope.command,
                          document.metadata.repoPaths == [fixture.rootPaths[0]], captured == nil else { return }
                    captured = envelope
                    entered.fulfill()
                    await gate.wait()
                }
                fixture.manager.markWorkspaceDirty()
                let ordinarySave = fixture.startOwnedTask { _ = await fixture.manager.pollAndSaveStateWithOutcomeAsync() }
                try await fixture.awaitGateEvent(ordinaryEntered)
                let removal = fixture.startOwnedTask { await fixture.manager.removeActiveWorkspaceRoot(path: fixture.rootPaths[1]) }
                try await fixture.awaitGateEvent(proposalEntered)
                proposalGate.release()
                try await fixture.awaitGateEvent(entered)
                XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), fixture.rootPaths)
                let envelope = try XCTUnwrap(captured)
                XCTAssertEqual(envelope.conflictRecoveryPolicy, .failClosed)
                let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -945)
                let observed = await client.canonicalWorkspaceSnapshot(fixture.workspace.id)
                let canonical = try XCTUnwrap(observed)
                let model = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(documentBytes: canonical.document.documentBytes, fileURL: canonical.document.fileURL)
                _ = try await client.replaceWorking(
                    model,
                    fileURL: fixture.workspaceURL,
                    expectedWorkspaceRevision: canonical.revisions.workingRevision,
                    operationID: envelope.operationID
                )
                gate.release()
                try await fixture.perform("rejected removal returned") { await removal.value }
                let after = try await fixture.capturePassive()
                self.assertPassiveConvergence(after, paths: fixture.rootPaths)
                await self.assertAdmission(fixture, capture: after)
                XCTAssertEqual(after.primaryRoots.map(\.id), before.primaryRoots.map(\.id))
                XCTAssertEqual(after.selection, before.selection)
                XCTAssertNotNil(fixture.manager.domainWorkspaceAuthorityIssue)
                ordinaryGate.release()
                await ordinarySave.value
            }
        }

        func testActiveAddSupersededByRemovalThrowsStaleAndNeverLoadsRemovedRoot() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(configuration: { [$0[0]] }) { fixture in
                let entered = XCTestExpectation(description: "add's shared load held")
                let addDone = XCTestExpectation(description: "superseded add returns stale")
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
                        XCTFail("Superseded add returned success")
                    } catch let failure as WorkspaceRootReadinessFailure { XCTAssertEqual(failure.reason, .staleInvocation) }
                    catch { XCTFail("Unexpected superseded add error: \(error)") }
                    addDone.fulfill()
                }
                try await fixture.awaitGateEvent(entered)
                let remove = fixture.startOwnedTask { await fixture.manager.removeActiveWorkspaceRoot(path: fixture.rootPaths[1]) }
                try await fixture.awaitGateEvent(addDone)
                XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), [fixture.rootPaths[0]])
                gate.release()
                try await fixture.perform("superseding removal finishes") { await remove.value }
                let after = try await fixture.capturePassive()
                self.assertPassiveConvergence(after, paths: [fixture.rootPaths[0]])
                await self.assertAdmission(fixture, capture: after)
            }
        }

        func testCancelledAddAfterWorkingCommitAdoptsCanonicalRootsAndReportsCancellation() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(configuration: { [$0[0]] }) { fixture in
                let before = try await fixture.capturePassive()
                let entered = XCTestExpectation(description: "saved envelope held after accepted working add")
                let done = XCTestExpectation(description: "cancelled add returned cancellation")
                let gate = fixture.makeGate()
                var held = false
                fixture.commandWillExecute = { envelope in
                    guard case .saveWorkspaceDocument = envelope.command, !held else { return }
                    held = true
                    entered.fulfill()
                    await gate.wait()
                }
                let add = fixture.startOwnedTask {
                    do { try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[1]), to: fixture.workspace)
                        XCTFail("Cancelled add returned success")
                    } catch is CancellationError {}
                    catch { XCTFail("Expected cancellation, not \(error)") }
                    done.fulfill()
                }
                try await fixture.awaitGateEvent(entered)
                add.cancel()
                gate.release()
                try await fixture.awaitGateEvent(done)
                // A new independent consumer can await the accepted working root flight.
                _ = try await fixture.manager.readyPrimaryRootSnapshot(workspaceID: fixture.workspace.id, expectedRepoPaths: fixture.rootPaths)
                // Observe the operation checkpoint before independent resolver validation replaces its cached result.
                let ticket = try XCTUnwrap(fixture.manager.currentRootReconciliationTicketForTesting)
                let checkpoint = try await fixture.manager.captureRootCheckpointForTesting(windowID: -944, ticket: ticket, expectedRepoPaths: fixture.rootPaths)
                let after = try await fixture.capturePassive()
                XCTAssertEqual(after.canonical.document.metadata.repoPaths, fixture.rootPaths)
                XCTAssertEqual(after.model.repoPaths, fixture.rootPaths)
                XCTAssertEqual(after.shellPaths, fixture.rootPaths)
                XCTAssertEqual(after.diskBytes, before.diskBytes)
                XCTAssertGreaterThan(after.canonical.revisions.workingRevision, after.canonical.revisions.savedRevision)
                XCTAssertNotNil(fixture.manager.domainWorkspaceAuthorityIssue)
                XCTAssertTrue(checkpoint.workingMatchesExpected)
                XCTAssertFalse(checkpoint.savedMatchesExpected)
                XCTAssertTrue(checkpoint.diskMatchesSaved)
                XCTAssertFalse(checkpoint.converged)
            }
        }

        func testWorkingOnlyRemovalKeepsCanonicalIntentDiskDivergenceAndIssue() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let before = try await fixture.capturePassive()
                let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -945)
                fixture.commandWillExecute = { envelope in
                    guard case let .saveWorkspaceDocument(workspaceID) = envelope.command,
                          workspaceID == fixture.workspace.id else { return }
                    do {
                        let snapshot = await client.canonicalWorkspaceSnapshot(workspaceID)
                        let canonical = try XCTUnwrap(snapshot)
                        let model = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(documentBytes: canonical.document.documentBytes, fileURL: canonical.document.fileURL)
                        // Reserve this real saved operation ID with a different unchanged command.
                        _ = try await client.replaceWorking(
                            model,
                            fileURL: fixture.workspaceURL,
                            expectedWorkspaceRevision: canonical.revisions.workingRevision,
                            operationID: envelope.operationID
                        )
                    } catch { XCTFail("Failed to arrange saved-phase rejection: \(error)") }
                }
                await fixture.manager.removeActiveWorkspaceRoot(path: fixture.rootPaths[1])
                let after = try await fixture.capturePassive()
                XCTAssertEqual(after.canonical.document.metadata.repoPaths, [fixture.rootPaths[0]])
                XCTAssertEqual(after.model.repoPaths, [fixture.rootPaths[0]])
                XCTAssertEqual(after.diskBytes, before.diskBytes)
                XCTAssertGreaterThan(after.canonical.revisions.workingRevision, after.canonical.revisions.savedRevision)
                XCTAssertEqual(after.canonical.revisions.savedRevision, before.canonical.revisions.savedRevision)
                XCTAssertEqual(after.readinessObservation.requestedRoots.map(\.standardizedFullPath), [fixture.rootPaths[0]])
                XCTAssertEqual(after.shellPaths, [fixture.rootPaths[0]])
                XCTAssertEqual(fixture.manager.debugRepoPathBaselineForWorkspace(fixture.workspace.id), [fixture.rootPaths[0]])
                XCTAssertNotNil(fixture.manager.domainWorkspaceAuthorityIssue)
            }
        }

        func testActiveAddFailurePreservesAcceptedRootAndDuplicateAddRetriesWithoutWrite() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(configuration: { [$0[0]] }) { fixture in
                try FileManager.default.removeItem(atPath: fixture.rootPaths[1])
                do {
                    try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[1]), to: fixture.workspace)
                    XCTFail("Active add must report terminal load failure")
                } catch let failure as WorkspaceRootReadinessFailure {
                    XCTAssertEqual(failure.reason, .rootsUnavailable(.missingDirectory))
                }
                let failed = try await fixture.capturePassive()
                XCTAssertEqual(failed.model.repoPaths, fixture.rootPaths)
                XCTAssertEqual(failed.disk.repoPaths, fixture.rootPaths)
                XCTAssertEqual(failed.primaryRoots.map(\.standardizedFullPath), [fixture.rootPaths[0]])
                let starts = fixture.manager.rootReconciliationStateForTesting.attemptStarts
                let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -945)
                var metadata = failed.model
                metadata.currentPromptText = "not a root retry"
                _ = try await client.saveFailClosed(
                    metadata,
                    fileURL: fixture.workspaceURL,
                    expectedWorkspaceRevision: failed.canonical.revisions.workingRevision,
                    expectedContentDigest: failed.canonical.document.contentDigest
                )
                try await fixture.settle()
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts, starts)
                let beforeRetry = try await fixture.capturePassive()
                try FileManager.default.createDirectory(atPath: fixture.rootPaths[1], withIntermediateDirectories: true)
                try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[1]), to: fixture.workspace)
                let after = try await fixture.capturePassive()
                assertPassiveConvergence(after, paths: fixture.rootPaths)
                await assertAdmission(fixture, capture: after)
                XCTAssertEqual(after.diskBytes, beforeRetry.diskBytes)
                XCTAssertEqual(after.canonical.revisions, beforeRetry.canonical.revisions)
                // Attachment can legitimately dirty presentation state; it is not a root edit/write.
                XCTAssertEqual(after.model.repoPaths, beforeRetry.model.repoPaths)
                XCTAssertEqual(after.model.dateModified, beforeRetry.model.dateModified)
                XCTAssertEqual(after.rootNotificationCount, beforeRetry.rootNotificationCount)
            }
        }

        func testRejectedReorderNeverPublishesOptimisticShellOrderAndRetainsIssue() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let before = try await fixture.capturePassive()
                let entered = XCTestExpectation(description: "reorder working command captured")
                let done = XCTestExpectation(description: "reorder failure returned")
                let gate = fixture.makeGate()
                var captured: DomainWorkspaceCommandEnvelope?
                fixture.commandWillExecute = { envelope in
                    guard case let .replaceWorkingDocument(document) = envelope.command,
                          document.metadata.repoPaths == Array(fixture.rootPaths.reversed()), captured == nil else { return }
                    captured = envelope
                    entered.fulfill()
                    await gate.wait()
                }
                fixture.startOwnedTask {
                    await fixture.manager.moveActiveWorkspaceRoot(path: fixture.rootPaths[1], direction: .up, visibleRootOrder: fixture.rootPaths)
                    done.fulfill()
                }
                try await fixture.awaitGateEvent(entered)
                XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), fixture.rootPaths, "Unaccepted order must not bypass the shared flight")
                XCTAssertEqual(fixture.manager.debugRepoPathBaselineForWorkspace(fixture.workspace.id), fixture.rootPaths)
                let envelope = try XCTUnwrap(captured)
                XCTAssertEqual(envelope.conflictRecoveryPolicy, .failClosed)
                let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -945)
                _ = try await client.replaceWorking(
                    before.model,
                    fileURL: fixture.workspaceURL,
                    expectedWorkspaceRevision: before.canonical.revisions.workingRevision,
                    operationID: envelope.operationID
                )
                gate.release()
                try await fixture.awaitGateEvent(done)
                let after = try await fixture.capturePassive()
                assertPassiveConvergence(after, paths: fixture.rootPaths)
                await assertAdmission(fixture, capture: after)
                XCTAssertEqual(after.primaryRoots.map(\.id), before.primaryRoots.map(\.id))
                XCTAssertEqual(fixture.manager.debugRepoPathBaselineForWorkspace(fixture.workspace.id), fixture.rootPaths)
                XCTAssertNotNil(fixture.manager.domainWorkspaceAuthorityIssue)
            }
        }

        func testExactRootSaveConflictsBeforeWorkingAndAfterWorkingWithoutReplayingRestoration() async throws {
            for holdSavedPhase in [false, true] {
                try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["A", "B", "C"], configuration: { [$0[0]] }) { fixture in
                    let entered = XCTestExpectation(description: "captured root command held")
                    let completed = XCTestExpectation(description: "root action reported conflict")
                    let gate = fixture.makeGate()
                    var armed = true
                    fixture.commandWillExecute = { envelope in
                        let matches: Bool = switch envelope.command {
                        case let .replaceWorkingDocument(document):
                            !holdSavedPhase && document.workspaceID == fixture.workspace.id
                        case let .saveWorkspaceDocument(workspaceID):
                            holdSavedPhase && workspaceID == fixture.workspace.id
                        default: false
                        }
                        guard matches, armed else { return }
                        armed = false
                        XCTAssertEqual(envelope.conflictRecoveryPolicy, .failClosed, "Explicit root bytes must never enter ordinary durable replay")
                        entered.fulfill()
                        await gate.wait()
                    }
                    fixture.startOwnedTask {
                        do {
                            try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[2]), to: fixture.workspace)
                            XCTFail("Superseded root save cannot report convergence")
                        } catch let error as DomainWorkspaceAuthorityOperationError {
                            XCTAssertEqual(error.outcome.disposition, .conflict)
                            XCTAssertEqual(error.workingCommitted, holdSavedPhase)
                            FileHandle.standardError.write(Data("ISSUE944 case=43 phase=\(holdSavedPhase ? "savedAfterWorking" : "beforeWorking") disposition=\(error.outcome.disposition) workingCommitted=\(error.workingCommitted)\n".utf8))
                        } catch { XCTFail("Expected real domain conflict, got \(error)") }
                        completed.fulfill()
                    }
                    try await fixture.awaitGateEvent(entered)
                    let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -945)
                    let snapshot = await client.canonicalWorkspaceSnapshot(fixture.workspace.id)
                    let canonical = try XCTUnwrap(snapshot)
                    var restored = try WorkspaceManagerViewModel.decodeDomainWorkspaceProjection(documentBytes: canonical.document.documentBytes, fileURL: canonical.document.fileURL)
                    XCTAssertEqual(restored.repoPaths, holdSavedPhase ? [fixture.rootPaths[0], fixture.rootPaths[2]] : [fixture.rootPaths[0]])
                    FileHandle.standardError.write(Data("ISSUE944 case=43 phase=\(holdSavedPhase ? "savedAfterWorking" : "beforeWorking") heldWorkingRevision=\(canonical.revisions.workingRevision) heldSavedRevision=\(canonical.revisions.savedRevision) expectedWorkingRootsMatch=\(restored.repoPaths == (holdSavedPhase ? [fixture.rootPaths[0], fixture.rootPaths[2]] : [fixture.rootPaths[0]]))\n".utf8))
                    restored.repoPaths = Array(fixture.rootPaths.prefix(2))
                    restored.currentPromptText = "external restoration wins"
                    let outcome = try await client.saveFailClosed(
                        restored,
                        fileURL: fixture.workspaceURL,
                        expectedWorkspaceRevision: canonical.revisions.workingRevision,
                        expectedContentDigest: canonical.document.contentDigest
                    )
                    XCTAssertEqual(outcome.finalOutcome?.disposition, .applied)
                    let catalog = await client.snapshot()
                    let projected = await fixture.bridge.waitUntilProjected(through: catalog.publicationSequence)
                    XCTAssertTrue(projected)
                    XCTAssertEqual(fixture.manager.activeWorkspace?.repoPaths, Array(fixture.rootPaths.prefix(2)))
                    gate.release()
                    try await fixture.awaitGateEvent(completed)
                    let after = try await fixture.capturePassive()
                    assertPassiveConvergence(after, paths: Array(fixture.rootPaths.prefix(2)))
                    await assertAdmission(fixture, capture: after)
                    XCTAssertEqual(after.model.currentPromptText, "external restoration wins")
                    XCTAssertEqual(fixture.manager.debugRepoPathBaselineForWorkspace(fixture.workspace.id), Array(fixture.rootPaths.prefix(2)))
                    XCTAssertNotNil(fixture.manager.domainWorkspaceAuthorityIssue)
                }
            }
        }

        func testMetadataPublicationPreservesPendingRemovalAndNextAdditionProposal() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["A", "B", "C"], configuration: { Array($0.prefix(2)) }) { fixture in
                let before = try await fixture.capturePassive()
                let removeGate = fixture.makeGate()
                let savesGate = fixture.makeGate()
                let assigned = XCTestExpectation(description: "remove proposal assigned")
                let added = XCTestExpectation(description: "next addition derived")
                let addFinished = XCTestExpectation(description: "addition completed")
                let oldSavePrepared = XCTestExpectation(description: "ordinary save remains held independently")
                let schedule = OverlaySaveSchedule()
                fixture.manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { _, _, _ in
                    let hold = await MainActor.run {
                        guard !schedule.additionStarted else { return false }
                        if !schedule.oldSaveObserved { schedule.oldSaveObserved = true
                            oldSavePrepared.fulfill()
                        }
                        return true
                    }
                    if hold { await savesGate.wait() }
                }
                fixture.manager.rootEditDidApplyHandlerForTesting = { _, source in
                    if source == .rootRemove {
                        assigned.fulfill()
                        await removeGate.wait()
                    } else if source == .rootAdd {
                        schedule.additionStarted = true
                        XCTAssertEqual(fixture.manager.activeWorkspace?.repoPaths, [fixture.rootPaths[0], fixture.rootPaths[2]])
                        added.fulfill()
                    }
                }
                fixture.manager.markWorkspaceDirty()
                let ordinarySave = fixture.startOwnedTask { _ = await fixture.manager.pollAndSaveStateWithOutcomeAsync() }
                try await fixture.awaitGateEvent(oldSavePrepared)
                let removal = fixture.startOwnedTask { await fixture.manager.removeActiveWorkspaceRoot(path: fixture.rootPaths[1]) }
                try await fixture.awaitGateEvent(assigned)
                var metadataPublications: [[String]] = []
                let publicationObserver = fixture.manager.$workspaces.sink { models in
                    if let model = models.first(where: { $0.id == fixture.workspace.id }) { metadataPublications.append(model.repoPaths) }
                }
                var metadata = before.model
                metadata.currentPromptText = "metadata-only publication"
                let client = DomainWorkspaceAuthorityClient(store: fixture.runtime.workspaceStore, windowID: -945)
                let outcome = try await client.saveFailClosed(
                    metadata,
                    fileURL: fixture.workspaceURL,
                    expectedWorkspaceRevision: before.canonical.revisions.workingRevision,
                    expectedContentDigest: before.canonical.document.contentDigest
                )
                XCTAssertEqual(outcome.finalOutcome?.disposition, .applied)
                let catalog = await fixture.runtime.workspaceStore.snapshot()
                let projected = await fixture.bridge.waitUntilProjected(through: catalog.publicationSequence)
                XCTAssertTrue(projected)
                XCTAssertEqual(fixture.manager.activeWorkspace?.repoPaths, [fixture.rootPaths[0]])
                publicationObserver.cancel()
                XCTAssertTrue(metadataPublications.allSatisfy { $0 == [fixture.rootPaths[0]] }, "Full projection must overlay before publishing, not publish canonical then repair it")
                XCTAssertEqual(fixture.manager.debugRepoPathBaselineForWorkspace(fixture.workspace.id), Array(fixture.rootPaths.prefix(2)))
                XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), Array(fixture.rootPaths.prefix(2)))
                fixture.startOwnedTask {
                    do { try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[2]), to: fixture.workspace) }
                    catch { XCTFail("Newest proposal failed: \(error)") }
                    addFinished.fulfill()
                }
                try await fixture.awaitGateEvent(added)
                // The shared flight remains edit-blocked until both root operations resolve.
                removeGate.release()
                try await fixture.awaitGateEvent(addFinished)
                await removal.value
                let after = try await fixture.capturePassive()
                assertPassiveConvergence(after, paths: [fixture.rootPaths[0], fixture.rootPaths[2]])
                await assertAdmission(fixture, capture: after)
                XCTAssertEqual(fixture.manager.debugRepoPathBaselineForWorkspace(fixture.workspace.id), [fixture.rootPaths[0], fixture.rootPaths[2]])
                savesGate.release()
                await ordinarySave.value
            }
        }

        func testPaddedPersistedRootRemovedThroughVisibleShellConvergesAndAdmitsContextBuilder() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(paddedConfiguration: true) { fixture in
                let before = try await fixture.capturePassive()
                XCTAssertEqual(before.model.repoPaths, fixture.workspace.repoPaths)
                XCTAssertEqual(before.primaryRoots.map(\.standardizedFullPath), fixture.rootPaths)
                await assertAdmission(fixture, capture: before)
                // Same producer value as AgentWorkspaceRootsSidebarStore.removeRoot(rowID:).
                let shell = try XCTUnwrap(fixture.files.visibleRootShellProjections.first {
                    $0.fullPath == fixture.rootPaths[1]
                })
                XCTAssertNotEqual(before.model.repoPaths[1], shell.fullPath)
                try await fixture.perform("visible-shell removal returned") {
                    await fixture.manager.removeActiveWorkspaceRoot(path: shell.fullPath)
                }
                let after = try await fixture.capturePassive()
                print("ISSUE944 producer=visibleShell configured=\(after.model.repoPaths.count) primary=\(after.primaryRoots.count) sequence=\(after.publicationSequence) revisions=\(after.canonical.revisions) checkpoint=passive")
                assertPassiveConvergence(after, paths: [fixture.rootPaths[0]])
                await assertAdmission(fixture, capture: after)
                XCTAssertEqual(after.primaryRoots.map(\.id), [before.primaryRoots[0].id])
            }
        }

        func testOrdinaryRemovalConvergesAndAdmitsContextBuilder() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let before = try await fixture.capturePassive()
                assertPassiveConvergence(before, paths: fixture.rootPaths)
                await assertAdmission(fixture, capture: before)
                let shell = try XCTUnwrap(fixture.files.visibleRootShellProjections.first {
                    $0.fullPath == fixture.rootPaths[1]
                })
                try await fixture.perform("ordinary visible-shell removal returned") {
                    await fixture.manager.removeActiveWorkspaceRoot(path: shell.fullPath)
                }
                let after = try await fixture.capturePassive()
                assertPassiveConvergence(after, paths: [fixture.rootPaths[0]])
                await assertAdmission(fixture, capture: after)
                XCTAssertEqual(after.primaryRoots.map(\.id), [before.primaryRoots[0].id])
                print("ISSUE944 control=ordinary configured=\(after.model.repoPaths.count) primary=\(after.primaryRoots.count) sequence=\(after.publicationSequence) revisions=\(after.canonical.revisions) checkpoint=passive")
            }
        }

        func testUnknownRootRemovalIsANoOp() async throws {
            try await assertNoOpRemoval(label: "unknown") { fixture in
                fixture.base.appendingPathComponent("not-a-configured-root").path
            }
        }

        func testWhitespaceOnlyRootRemovalIsANoOp() async throws {
            try await assertNoOpRemoval(label: "whitespace") { _ in " \n\t " }
        }

        func testPaddedRemovalArgumentMatchesOrdinaryConfiguredRoot() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let before = try await fixture.capturePassive()
                try await fixture.perform("padded argument removal returned") {
                    await fixture.manager.removeActiveWorkspaceRoot(path: " \t" + fixture.rootPaths[1] + "\n")
                }
                let after = try await fixture.capturePassive()
                assertPassiveConvergence(after, paths: [fixture.rootPaths[0]])
                await assertAdmission(fixture, capture: after)
                XCTAssertEqual(after.primaryRoots.map(\.id), [before.primaryRoots[0].id])
            }
        }

        func testCaseOnlyMissIsANoOp() async throws {
            try await assertNoOpRemoval(label: "case-only") { fixture in
                fixture.base.appendingPathComponent("b").path
            }
        }

        func testInvalidFilesystemPathArgumentsAreNoOps() async throws {
            for argument in ["\0", " file:///tmp/root ", " FILE:///tmp/root "] {
                try await assertNoOpRemoval(label: "invalid") { _ in argument }
            }
        }

        func testActiveRemovalRereadsRootsAfterBeforeSaveListenerMutation() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(
                rootNames: ["A", "B", "C"], configuration: { Array($0.prefix(2)) }
            ) { fixture in
                var listenerCalls = 0
                let token = fixture.manager.addBeforeSaveListener { workspace in
                    guard workspace.id == fixture.workspace.id, listenerCalls == 0,
                          let index = fixture.manager.workspaces.firstIndex(where: { $0.id == workspace.id })
                    else { return }
                    listenerCalls += 1
                    fixture.manager.workspaces[index].repoPaths.append(fixture.rootPaths[2])
                    fixture.manager.markWorkspaceDirty(workspaceID: workspace.id)
                }
                defer { fixture.manager.removeBeforeSaveListener(token) }

                try await fixture.perform("removal preserves root added by before-save listener") {
                    await fixture.manager.removeActiveWorkspaceRoot(path: fixture.rootPaths[1])
                }

                XCTAssertEqual(listenerCalls, 1)
                let after = try await fixture.capturePassive()
                assertPassiveConvergence(after, paths: [fixture.rootPaths[0], fixture.rootPaths[2]])
                await assertAdmission(fixture, capture: after)
            }
        }

        func testStalePassedWorkspacePreservesNewerUnrelatedRoot() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(
                rootNames: ["A", "B", "C"], configuration: { Array($0.prefix(2)) }
            ) { fixture in
                let stale = try XCTUnwrap(fixture.manager.workspace(withID: fixture.workspace.id))
                try await fixture.perform("new unrelated root added") {
                    try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[2]), to: stale)
                }
                let before = try await fixture.capturePassive()
                assertPassiveConvergence(before, paths: fixture.rootPaths)
                await assertAdmission(fixture, capture: before)
                try await fixture.perform("removal with stale passed workspace returned") {
                    await fixture.manager.removeFolder(fixture.rootPaths[1], from: stale)
                }
                let after = try await fixture.capturePassive()
                assertPassiveConvergence(after, paths: [fixture.rootPaths[0], fixture.rootPaths[2]])
                await assertAdmission(fixture, capture: after)
                XCTAssertEqual(after.primaryRoots.map(\.id), [before.primaryRoots[0].id, before.primaryRoots[2].id])
            }
        }

        func testEquivalentDuplicateSpellingsRemovedAndSurvivorsPreserved() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(
                rootNames: ["A", "B", "C"],
                configuration: { [" " + $0[2] + "\n", $0[1], $0[0] + "/.", "\t" + $0[1] + "\n"] }
            ) { fixture in
                let before = try await fixture.capturePassive()
                XCTAssertEqual(before.shellPaths, [fixture.rootPaths[2], fixture.rootPaths[1], fixture.rootPaths[0]])
                let survivors = [" " + fixture.rootPaths[2] + "\n", fixture.rootPaths[0] + "/."]
                try await fixture.perform("duplicate identity removal returned") {
                    await fixture.manager.removeActiveWorkspaceRoot(path: fixture.rootPaths[1])
                }
                let after = try await fixture.capturePassive()
                XCTAssertEqual(after.model.repoPaths, survivors)
                XCTAssertEqual(after.disk.repoPaths, survivors)
                let canonical = try JSONDecoder().decode(WorkspaceModel.self, from: after.canonical.document.documentBytes)
                XCTAssertEqual(canonical.repoPaths, survivors)
                XCTAssertEqual(after.shellPaths, [fixture.rootPaths[2], fixture.rootPaths[0]])
                XCTAssertEqual(after.primaryRoots, before.primaryRoots.filter { $0.standardizedFullPath != fixture.rootPaths[1] })
                await assertAdmission(fixture, capture: after)
            }
        }

        func testFinalRootUsesActiveFallbackButUnmatchedRequestDoesNotSwitch() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(configuration: { [$0[0]] }) { fixture in
                let fallback = try await fixture.createAdditionalWorkspace(name: "Default", repoPaths: [fixture.rootPaths[1]])
                let before = try await fixture.capturePassive()
                try await fixture.perform("unmatched final-root removal returned") {
                    await fixture.manager.removeActiveWorkspaceRoot(path: fixture.rootPaths[1])
                }
                let unmatched = try await fixture.capturePassive()
                XCTAssertEqual(fixture.manager.activeWorkspaceID, fixture.workspace.id)
                XCTAssertEqual(unmatched.stateVersion, before.stateVersion)
                XCTAssertEqual(unmatched.selection, before.selection)
                XCTAssertEqual(unmatched.model, before.model)
                XCTAssertEqual(unmatched.canonical, before.canonical)
                XCTAssertEqual(unmatched.primaryRoots, before.primaryRoots)
                XCTAssertEqual(unmatched.diskBytes, before.diskBytes)
                XCTAssertEqual(unmatched.rootNotificationCount, before.rootNotificationCount)
                try await fixture.perform("final-root fallback completed") {
                    await fixture.manager.removeActiveWorkspaceRoot(path: fixture.rootPaths[0])
                }
                try await fixture.settle()
                XCTAssertEqual(fixture.manager.activeWorkspaceID, fallback.id)
                XCTAssertEqual(fixture.manager.workspace(withID: fixture.workspace.id)?.repoPaths, [fixture.rootPaths[0]])
                let disk = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: fixture.workspaceURL))
                XCTAssertEqual(disk.repoPaths, [fixture.rootPaths[0]], "Final removal does not persist empty configuration")
                XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), fallback.repoPaths)
            }
        }

        func testInactiveRemovalNeverCapturesOrUnloadsActiveWorkspace() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let inactive = try await fixture.createAdditionalWorkspace(name: "Inactive", repoPaths: fixture.rootPaths)
                let selected = URL(fileURLWithPath: fixture.rootPaths[1]).appendingPathComponent("README.md").path
                try await fixture.selectFixtureFiles([selected])
                let before = try await fixture.capturePassive()
                let inactiveVersion = fixture.manager.debugStateVersionForWorkspace(inactive.id)
                var mutations = 0
                fixture.manager.rootEditDidApplyHandlerForTesting = { id, source in
                    XCTAssertEqual(id, inactive.id)
                    XCTAssertEqual(source, .rootRemove)
                    mutations += 1
                    XCTAssertEqual(fixture.manager.debugStateVersionForWorkspace(id), inactiveVersion + 1)
                    XCTAssertEqual(fixture.manager.debugStateVersionForWorkspace(fixture.workspace.id), before.stateVersion)
                    XCTAssertGreaterThan(fixture.manager.workspace(withID: id)?.dateModified ?? .distantPast, inactive.dateModified)
                }
                var captures = 0
                let token = fixture.manager.addBeforeSaveListener { _ in captures += 1 }
                defer { fixture.manager.removeBeforeSaveListener(token) }
                try await fixture.perform("inactive removal returned") {
                    await fixture.manager.removeFolder(fixture.rootPaths[1], from: inactive)
                }
                let after = try await fixture.capturePassive()
                XCTAssertEqual(captures, 0)
                XCTAssertEqual(mutations, 1)
                XCTAssertEqual(fixture.manager.activeWorkspaceID, fixture.workspace.id)
                XCTAssertEqual(after.model, before.model)
                XCTAssertEqual(after.canonical, before.canonical)
                XCTAssertEqual(after.diskBytes, before.diskBytes)
                XCTAssertEqual(after.primaryRoots, before.primaryRoots)
                XCTAssertEqual(after.selection, before.selection)
                let remaining = try XCTUnwrap(fixture.manager.workspace(withID: inactive.id))
                XCTAssertEqual(remaining.repoPaths, [fixture.rootPaths[0]])
                let diskURL = fixture.manager.workspaceFileURL(for: remaining)
                let diskBytes = try Data(contentsOf: diskURL)
                XCTAssertEqual(try JSONDecoder().decode(WorkspaceModel.self, from: diskBytes).repoPaths, remaining.repoPaths)
                let canonical = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(inactive.id)
                let canonicalBeforeFinal = try XCTUnwrap(canonical)
                let version = fixture.manager.debugStateVersionForWorkspace(inactive.id)
                try await fixture.perform("inactive final-root no-op returned") {
                    await fixture.manager.removeFolder(fixture.rootPaths[0], from: inactive)
                }
                let canonicalAfterFinal = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(inactive.id)
                XCTAssertEqual(canonicalAfterFinal, canonicalBeforeFinal)
                XCTAssertEqual(fixture.manager.workspace(withID: inactive.id), remaining)
                XCTAssertEqual(fixture.manager.debugStateVersionForWorkspace(inactive.id), version)
                XCTAssertEqual(try Data(contentsOf: diskURL), diskBytes)
                XCTAssertEqual(fixture.manager.activeWorkspaceID, fixture.workspace.id)
                XCTAssertEqual(fixture.files.selectedFiles.map(\.fullPath), [selected])
                XCTAssertEqual(captures, 0)
                XCTAssertEqual(mutations, 1)
            }
        }

        func testPreparedSaveReleasedBeforeUnloadDirtyMarkRetriesSynchronousRootEdit() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let selected = URL(fileURLWithPath: fixture.rootPaths[1]).appendingPathComponent("README.md").path
                try await fixture.selectFixtureFiles([selected])
                let tabID = try XCTUnwrap(fixture.workspace.activeComposeTabID)
                fixture.manager.setSnapshotsSuspended(true, forTabID: tabID)
                defer { fixture.manager.setSnapshotsSuspended(false, forTabID: tabID) }
                let schedule = SaveSchedule(fixture: fixture)
                let selectionObserver = fixture.files.$selectedFiles.dropFirst().sink { _ in
                    schedule.record("selection-emission")
                }
                defer { selectionObserver.cancel() }
                fixture.manager.markWorkspaceDirty()
                fixture.manager.resetWorkspaceSaveDiagnosticsForTesting()
                fixture.manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { id, _, remaining in
                    await schedule.savePrepared(workspaceID: id, remaining: remaining)
                }
                let oldSave = fixture.startOwnedTask {
                    let outcome = await fixture.manager.pollAndSaveStateWithOutcomeAsync()
                    guard case .persisted = outcome else {
                        XCTFail("Old save did not complete persistence: \(outcome)")
                        return
                    }
                    schedule.record("old-save-returned")
                }
                try await fixture.awaitGateEvent(schedule.prepared)
                fixture.manager.dirtyMarkDidFinish = { schedule.dirtyMarkFinished() }
                fixture.manager.rootEditDidApplyHandlerForTesting = { id, source in
                    guard id == fixture.workspace.id, source == .rootRemove else { return }
                    schedule.record("root-assigned")
                    schedule.rootApplied.fulfill()
                    await schedule.rootGate.wait()
                }
                let removal = fixture.startOwnedTask {
                    await fixture.manager.removeActiveWorkspaceRoot(path: fixture.rootPaths[1])
                    schedule.record("removal-returned")
                }
                try await fixture.awaitGateEvent(schedule.rootApplied)
                let prepared = try XCTUnwrap(schedule.events.first { $0.name == "old-save-prepared" })
                let assigned = try XCTUnwrap(schedule.events.first { $0.name == "root-assigned" })
                XCTAssertEqual(assigned.paths, [fixture.rootPaths[0]])
                XCTAssertGreaterThan(assigned.version, prepared.version, "Explicit root edit invalidates prepared saves synchronously")
                XCTAssertGreaterThan(assigned.date, prepared.date, "Version and date advance at the root assignment")
                XCTAssertFalse(schedule.events.contains { $0.name == "selection-emission" || $0.name == "unload-dirty" })
                schedule.record("release-old-save")
                schedule.oldSaveGate.release()
                try await fixture.perform("earlier prepared save completed while removal held") { await oldSave.value }
                let retry = try XCTUnwrap(schedule.events.first { $0.name == "old-save-retry" }, "Existing version guard must retry before unload")
                XCTAssertEqual(retry.paths, [fixture.rootPaths[0]])
                XCTAssertGreaterThanOrEqual(retry.version, assigned.version)
                XCTAssertFalse(schedule.events.contains { $0.name == "selection-emission" || $0.name == "unload-dirty" })
                let held = try await fixture.capturePassive()
                XCTAssertEqual(held.disk.repoPaths, [fixture.rootPaths[0]], "Earlier save already persisted edited roots before unload")
                let canonical = try JSONDecoder().decode(WorkspaceModel.self, from: held.canonical.document.documentBytes)
                XCTAssertEqual(canonical.repoPaths, [fixture.rootPaths[0]])
                XCTAssertEqual(held.primaryRoots.map(\.standardizedFullPath), fixture.rootPaths, "No unload has occurred")
                XCTAssertEqual(fixture.files.selectedFiles.map(\.fullPath), [selected])
                schedule.rootGate.release()
                try await fixture.perform("removal completed after old save") { await removal.value }
                try await fixture.awaitGateEvent(schedule.unloadDirty)
                let after = try await fixture.capturePassive()
                assertPassiveConvergence(after, paths: [fixture.rootPaths[0]])
                await assertAdmission(fixture, capture: after)
                let names = schedule.events.map(\.name)
                assertEventOrder(["old-save-prepared", "root-assigned", "release-old-save", "old-save-resumed", "old-save-retry", "old-save-returned", "selection-emission", "unload-dirty"], in: names)
                XCTAssertEqual(fixture.manager.workspaceSaveDiagnosticsForTesting(workspaceID: fixture.workspace.id).capturePublicationCount, 0)
                print("ISSUE944 chronology=earlier snapshotsSuspended=true events=\(names.joined(separator: ","))")
            }
        }

        func testPreparedSaveReleasedAfterUnloadDirtyMark() async throws {
            try await assertPreparedSaveAfterDirtyMark(snapshotsSuspended: false)
        }

        func testPreparedSaveReleasedAfterUnloadDirtyMarkWithSnapshotsSuspended() async throws {
            try await assertPreparedSaveAfterDirtyMark(snapshotsSuspended: true)
        }

        func testAddAdvancesTargetVersionAndDateOnceAndDuplicateAddDoesNotWrite() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(
                rootNames: ["A", "B", "C"], configuration: { Array($0.prefix(2)) }
            ) { fixture in
                let before = try await fixture.capturePassive()
                var mutations = 0
                fixture.manager.rootEditDidApplyHandlerForTesting = { id, source in
                    XCTAssertEqual(id, fixture.workspace.id)
                    XCTAssertEqual(source, .rootAdd)
                    mutations += 1
                    let current = fixture.manager.workspace(withID: id)
                    XCTAssertEqual(current?.repoPaths, fixture.rootPaths)
                    XCTAssertEqual(fixture.manager.debugStateVersionForWorkspace(id), before.stateVersion + 1, "Version advances before the first root-add suspension")
                    XCTAssertGreaterThan(current?.dateModified ?? .distantPast, before.model.dateModified)
                    print("ISSUE944 mutation=add synchronousVersionDelta=\(fixture.manager.debugStateVersionForWorkspace(id) - before.stateVersion) dateAdvanced=\((current?.dateModified ?? .distantPast) > before.model.dateModified)")
                }
                try await fixture.perform("add persisted and loaded") {
                    try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[2]), to: before.model)
                }
                XCTAssertEqual(mutations, 1)
                let added = try await fixture.capturePassive()
                assertPassiveConvergence(added, paths: fixture.rootPaths)
                await assertAdmission(fixture, capture: added)
                try await fixture.perform("duplicate add returned") {
                    try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[2]), to: before.model)
                }
                let duplicate = try await fixture.capturePassive()
                XCTAssertEqual(mutations, 1)
                assertUnchanged(duplicate, added)
            }
        }

        func testReorderAdvancesVersionAndDateOnceAndUnchangedOrderDoesNotWrite() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let before = try await fixture.capturePassive()
                let order = [fixture.rootPaths[1], fixture.rootPaths[0]]
                var mutations = 0
                fixture.manager.rootEditDidApplyHandlerForTesting = { id, source in
                    XCTAssertEqual(id, fixture.workspace.id)
                    XCTAssertEqual(source, .rootReorder)
                    mutations += 1
                    let current = fixture.manager.workspace(withID: id)
                    XCTAssertEqual(current?.repoPaths, order)
                    XCTAssertEqual(fixture.manager.debugStateVersionForWorkspace(id), before.stateVersion + 1, "Version advances before the first root-reorder suspension")
                    XCTAssertGreaterThan(current?.dateModified ?? .distantPast, before.model.dateModified)
                    print("ISSUE944 mutation=reorder synchronousVersionDelta=\(fixture.manager.debugStateVersionForWorkspace(id) - before.stateVersion) dateAdvanced=\((current?.dateModified ?? .distantPast) > before.model.dateModified)")
                }
                try await fixture.perform("reorder persisted") {
                    await fixture.manager.moveActiveWorkspaceRoot(path: fixture.rootPaths[1], direction: .up, visibleRootOrder: before.shellPaths)
                }
                XCTAssertEqual(mutations, 1)
                let reordered = try await fixture.capturePassive()
                XCTAssertEqual(reordered.model.repoPaths, order)
                XCTAssertEqual(reordered.disk.repoPaths, order)
                XCTAssertEqual(try JSONDecoder().decode(WorkspaceModel.self, from: reordered.canonical.document.documentBytes).repoPaths, order)
                XCTAssertEqual(reordered.primaryRoots, before.primaryRoots)
                XCTAssertEqual(reordered.shellPaths, order)
                await assertAdmission(fixture, capture: reordered)
                for (path, direction) in [
                    (fixture.rootPaths[1], WorkspaceRootMoveDirection.up),
                    (fixture.rootPaths[0], .down),
                    (fixture.base.appendingPathComponent("unknown").path, .up)
                ] {
                    try await fixture.perform("unchanged reorder returned") {
                        await fixture.manager.moveActiveWorkspaceRoot(path: path, direction: direction, visibleRootOrder: order)
                    }
                    let unchanged = try await fixture.capturePassive()
                    assertUnchanged(unchanged, reordered)
                    XCTAssertEqual(mutations, 1)
                }
            }
        }

        func testInactiveAddAdvancesOnlyTargetVersionWithoutLoadingVisibleRoots() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(
                rootNames: ["A", "B", "C"], configuration: { Array($0.prefix(2)) }
            ) { fixture in
                let inactive = try await fixture.createAdditionalWorkspace(name: "Inactive", repoPaths: [fixture.rootPaths[0]])
                let before = try await fixture.capturePassive()
                let inactiveVersion = fixture.manager.debugStateVersionForWorkspace(inactive.id)
                var mutations = 0
                fixture.manager.rootEditDidApplyHandlerForTesting = { id, source in
                    XCTAssertEqual(id, inactive.id)
                    XCTAssertEqual(source, .rootAdd)
                    mutations += 1
                    XCTAssertEqual(fixture.manager.debugStateVersionForWorkspace(id), inactiveVersion + 1)
                    XCTAssertEqual(fixture.manager.debugStateVersionForWorkspace(fixture.workspace.id), before.stateVersion)
                    XCTAssertGreaterThan(fixture.manager.workspace(withID: id)?.dateModified ?? .distantPast, inactive.dateModified)
                }
                try await fixture.perform("inactive add persisted without loading") {
                    try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[2]), to: inactive)
                }
                XCTAssertEqual(mutations, 1)
                let after = try await fixture.capturePassive()
                XCTAssertEqual(fixture.manager.activeWorkspaceID, fixture.workspace.id)
                XCTAssertEqual(after.model, before.model)
                XCTAssertEqual(after.canonical, before.canonical)
                XCTAssertEqual(after.diskBytes, before.diskBytes)
                XCTAssertEqual(after.primaryRoots, before.primaryRoots)
                XCTAssertEqual(after.shellPaths, before.shellPaths)
                XCTAssertEqual(after.selection, before.selection)
                let updated = try XCTUnwrap(fixture.manager.workspace(withID: inactive.id))
                XCTAssertEqual(updated.repoPaths, [fixture.rootPaths[0], fixture.rootPaths[2]])
                let canonical = await fixture.runtime.workspaceStore.canonicalWorkspaceSnapshot(inactive.id)
                XCTAssertEqual(try JSONDecoder().decode(WorkspaceModel.self, from: XCTUnwrap(canonical).document.documentBytes).repoPaths, updated.repoPaths)
                let disk = try Data(contentsOf: fixture.manager.workspaceFileURL(for: updated))
                XCTAssertEqual(try JSONDecoder().decode(WorkspaceModel.self, from: disk).repoPaths, updated.repoPaths)
            }
        }

        private func assertUnchanged(
            _ after: WorkspaceAuthorityRootTestFixture.Capture,
            _ before: WorkspaceAuthorityRootTestFixture.Capture,
            file: StaticString = #filePath, line: UInt = #line
        ) {
            XCTAssertEqual(after.model, before.model, file: file, line: line)
            XCTAssertEqual(after.stateVersion, before.stateVersion, file: file, line: line)
            XCTAssertEqual(after.canonical, before.canonical, file: file, line: line)
            XCTAssertEqual(after.publicationSequence, before.publicationSequence, file: file, line: line)
            XCTAssertEqual(after.diskBytes, before.diskBytes, file: file, line: line)
            XCTAssertEqual(after.primaryRoots, before.primaryRoots, file: file, line: line)
            XCTAssertEqual(after.shellPaths, before.shellPaths, file: file, line: line)
            XCTAssertEqual(after.selection, before.selection, file: file, line: line)
            XCTAssertEqual(after.rootNotificationCount, before.rootNotificationCount, file: file, line: line)
        }

        private func assertPreparedSaveAfterDirtyMark(snapshotsSuspended: Bool) async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let selected = URL(fileURLWithPath: fixture.rootPaths[1]).appendingPathComponent("README.md").path
                try await fixture.selectFixtureFiles([selected])
                let tabID = try XCTUnwrap(fixture.workspace.activeComposeTabID)
                fixture.manager.setSnapshotsSuspended(snapshotsSuspended, forTabID: tabID)
                defer { fixture.manager.setSnapshotsSuspended(false, forTabID: tabID) }
                let schedule = SaveSchedule(fixture: fixture)
                let selectionObserver = fixture.files.$selectedFiles.dropFirst().sink { _ in schedule.record("selection-emission") }
                defer { selectionObserver.cancel() }
                fixture.manager.markWorkspaceDirty()
                fixture.manager.resetWorkspaceSaveDiagnosticsForTesting()
                fixture.manager.setWorkspaceSavePreparationDidFinishHandlerForTesting { id, _, remaining in
                    await schedule.savePrepared(workspaceID: id, remaining: remaining)
                }
                let oldSave = fixture.startOwnedTask {
                    let outcome = await fixture.manager.pollAndSaveStateWithOutcomeAsync()
                    guard case .persisted = outcome else {
                        XCTFail("Old save did not complete persistence: \(outcome)")
                        return
                    }
                    schedule.record("old-save-returned")
                }
                try await fixture.awaitGateEvent(schedule.prepared)
                fixture.manager.dirtyMarkDidFinish = { schedule.dirtyMarkFinished() }
                fixture.manager.rootEditDidApplyHandlerForTesting = { id, source in
                    guard id == fixture.workspace.id, source == .rootRemove else { return }
                    schedule.record("root-assigned")
                }
                try await fixture.perform("removal returned before old save release") {
                    await fixture.manager.removeActiveWorkspaceRoot(path: fixture.rootPaths[1])
                    schedule.record("removal-returned")
                }
                try await fixture.awaitGateEvent(schedule.unloadDirty)
                schedule.record("release-old-save")
                schedule.oldSaveGate.release()
                try await fixture.perform("late prepared save completed") { await oldSave.value }
                let after = try await fixture.capturePassive()
                assertPassiveConvergence(after, paths: [fixture.rootPaths[0]])
                await assertAdmission(fixture, capture: after)
                XCTAssertTrue(fixture.files.selectedFiles.isEmpty)
                let retry = try XCTUnwrap(schedule.events.first { $0.name == "old-save-retry" })
                XCTAssertEqual(retry.paths, [fixture.rootPaths[0]])
                let names = schedule.events.map(\.name)
                assertEventOrder(["old-save-prepared", "root-assigned", "selection-emission", "unload-dirty", "release-old-save", "old-save-resumed", "old-save-retry", "old-save-returned"], in: names)
                let captures = fixture.manager.workspaceSaveDiagnosticsForTesting(workspaceID: fixture.workspace.id).capturePublicationCount
                if snapshotsSuspended { XCTAssertEqual(captures, 0) }
                else { XCTAssertGreaterThan(captures, 0) }
                print("ISSUE944 chronology=afterDirty snapshotsSuspended=\(snapshotsSuspended) capturePublications=\(captures) events=\(names.joined(separator: ","))")
            }
        }

        private func assertEventOrder(_ expected: [String], in actual: [String], file: StaticString = #filePath, line: UInt = #line) {
            var previous = -1
            for name in expected {
                guard let index = actual.firstIndex(of: name) else {
                    XCTFail("Missing semantic event: \(name)", file: file, line: line)
                    return
                }
                XCTAssertGreaterThan(index, previous, "Event order: \(name)", file: file, line: line)
                previous = index
            }
        }

        @MainActor
        private final class SaveSchedule {
            struct Event {
                let name: String
                let version: Int
                let date: Date
                let paths: [String]
            }

            let fixture: WorkspaceAuthorityRootTestFixture
            let oldSaveGate: WorkspaceAuthorityRootTestFixture.Gate
            let rootGate: WorkspaceAuthorityRootTestFixture.Gate
            let prepared = XCTestExpectation(description: "old save prepared")
            let rootApplied = XCTestExpectation(description: "explicit root edit applied before persistence")
            let unloadDirty = XCTestExpectation(description: "unload selection reached real dirty observer")
            var events: [Event] = []
            private var claimedOldSave = false
            private var observedUnloadDirty = false

            init(fixture: WorkspaceAuthorityRootTestFixture) {
                self.fixture = fixture
                oldSaveGate = fixture.makeGate()
                rootGate = fixture.makeGate()
            }

            func record(_ name: String) {
                guard let model = fixture.manager.workspace(withID: fixture.workspace.id) else {
                    XCTFail("Chronology workspace disappeared")
                    return
                }
                let version = fixture.manager.debugStateVersionForWorkspace(model.id)
                events.append(Event(name: name, version: version, date: model.dateModified, paths: model.repoPaths))
                print("ISSUE944 event=\(name) version=\(version) modified=\(model.dateModified.timeIntervalSince1970) roots=\(model.repoPaths.count)")
            }

            func savePrepared(workspaceID: UUID, remaining: Int) async {
                guard workspaceID == fixture.workspace.id else { return }
                if !claimedOldSave {
                    claimedOldSave = true
                    record("old-save-prepared")
                    prepared.fulfill()
                    await oldSaveGate.wait()
                    record("old-save-resumed")
                } else {
                    record(remaining == 0 ? "old-save-retry" : "concurrent-save-prepared")
                }
            }

            func dirtyMarkFinished() {
                record("dirty-mark")
                guard !observedUnloadDirty, fixture.files.selectedFiles.isEmpty else { return }
                observedUnloadDirty = true
                record("unload-dirty")
                unloadDirty.fulfill()
            }
        }

        private func assertNoOpRemoval(
            label: String, path: (WorkspaceAuthorityRootTestFixture) -> String,
            file: StaticString = #filePath, line: UInt = #line
        ) async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let selectedPath = URL(fileURLWithPath: fixture.rootPaths[0]).appendingPathComponent("README.md").path
                try await fixture.selectFixtureFiles([selectedPath])
                XCTAssertEqual(fixture.files.selectedFiles.map(\.fullPath), [selectedPath], file: file, line: line)
                let before = try await fixture.capturePassive()
                assertPassiveConvergence(before, paths: fixture.rootPaths, file: file, line: line)
                await assertAdmission(fixture, capture: before)
                let argument = path(fixture)
                try await fixture.perform("unmatched removal returned") {
                    await fixture.manager.removeActiveWorkspaceRoot(path: argument)
                }
                let after = try await fixture.capturePassive()
                // Membership/admission controls remain useful even when baseline no-write checks fail.
                assertPassiveConvergence(after, paths: fixture.rootPaths, file: file, line: line)
                await assertAdmission(fixture, capture: after)
                XCTAssertEqual(after.primaryRoots, before.primaryRoots, "root identities", file: file, line: line)
                XCTAssertEqual(after.selection, before.selection, "selection", file: file, line: line)
                XCTAssertEqual(after.model, before.model, "workspace model", file: file, line: line)
                XCTAssertEqual(after.stateVersion, before.stateVersion, "state version", file: file, line: line)
                XCTAssertEqual(after.canonical, before.canonical, "canonical content/revisions", file: file, line: line)
                XCTAssertEqual(after.publicationSequence, before.publicationSequence, "authority publication", file: file, line: line)
                XCTAssertEqual(after.diskBytes, before.diskBytes, "saved bytes", file: file, line: line)
                XCTAssertEqual(after.rootNotificationCount, before.rootNotificationCount, "root notification count", file: file, line: line)
                print("ISSUE944 control=\(label) rootsUnchanged=\(after.primaryRoots == before.primaryRoots) selectionUnchanged=\(after.selection == before.selection) revisionsUnchanged=\(after.canonical.revisions == before.canonical.revisions) diskUnchanged=\(after.diskBytes == before.diskBytes) notifications=\(after.rootNotificationCount - before.rootNotificationCount) checkpoint=passive")
            }
        }

        private func assertAdmission(
            _ fixture: WorkspaceAuthorityRootTestFixture, capture: WorkspaceAuthorityRootTestFixture.Capture,
            file: StaticString = #filePath, line: UInt = #line
        ) async {
            do {
                let context = try await fixture.admit()
                XCTAssertEqual(context.primaryRootSnapshot?.roots, capture.readinessObservation.requestedRoots, file: file, line: line)
                XCTAssertEqual(context.primaryRootSnapshot?.ticket, capture.reconciliationTicket, file: file, line: line)
            } catch { XCTFail("Real unbound admission failed: \(error)", file: file, line: line) }
        }

        private func assertPassiveConvergence(
            _ capture: WorkspaceAuthorityRootTestFixture.Capture, paths: [String],
            file: StaticString = #filePath, line: UInt = #line
        ) {
            XCTAssertEqual(capture.model.repoPaths, paths, "manager roots", file: file, line: line)
            let working = try? JSONDecoder().decode(WorkspaceModel.self, from: capture.canonical.document.documentBytes)
            XCTAssertEqual(working?.repoPaths, paths, "canonical working roots", file: file, line: line)
            XCTAssertEqual(capture.disk.repoPaths, paths, "saved disk roots", file: file, line: line)
            XCTAssertEqual(capture.primaryRoots.map(\.standardizedFullPath), paths, "primary store roots", file: file, line: line)
            XCTAssertEqual(capture.shellPaths, paths, "visible shell order", file: file, line: line)
            XCTAssertEqual(capture.readinessObservation.requestedRoots.map(\.standardizedFullPath), paths, "passive ordered coverage", file: file, line: line)
            XCTAssertEqual(capture.shellIDs, capture.readinessObservation.requestedRoots.map(\.id), "passive exact shell/store IDs", file: file, line: line)
            XCTAssertTrue(capture.readinessObservation.missingPaths.isEmpty, "passive missing roots", file: file, line: line)
            XCTAssertTrue(capture.readinessObservation.wrongKindPaths.isEmpty, "passive wrong-kind roots", file: file, line: line)
            XCTAssertTrue(capture.readinessObservation.nonqueryablePaths.isEmpty, "passive queryable authority", file: file, line: line)
        }
    }
#endif
