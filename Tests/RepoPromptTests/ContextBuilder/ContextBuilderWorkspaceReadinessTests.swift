import Foundation
@testable import RepoPromptApp
import RepoPromptWorkspaceCore
import XCTest

#if DEBUG
    @MainActor
    final class ContextBuilderWorkspaceReadinessTests: XCTestCase {
        func testSiblingWorkspaceRootsInOneCheckoutElectAvailableReviewTarget() async throws {
            for staleRootIndex in 0 ..< 2 {
                try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["B", "C"]) { fixture in
                    let checkout = fixture.base.resolvingSymlinksInPath().standardizedFileURL
                    let roots = fixture.rootPaths.map {
                        URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL
                    }
                    let selectedPaths = roots.map { $0.appendingPathComponent("README.md").path }
                    let git = try ReviewGitRepositoryFixture(parentDirectory: checkout)
                    try git.initializeRepository(at: checkout)
                    for root in roots {
                        try git.stage(root.lastPathComponent + "/README.md", at: checkout)
                        let owner = try git.runGit(["rev-parse", "--show-toplevel"], at: root)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        XCTAssertEqual(URL(fileURLWithPath: owner).resolvingSymlinksInPath().path, checkout.path)
                    }
                    try git.write("original unselected content", to: "B/other.md", at: checkout)
                    try git.stage("B/other.md", at: checkout)
                    try git.commit("Initial sibling-root fixture", at: checkout)
                    try git.write("SELECTED_B_CHANGE", to: "B/README.md", at: checkout)
                    try git.write("SELECTED_C_CHANGE", to: "C/README.md", at: checkout)
                    try git.write("UNSELECTED_SIBLING_CHANGE", to: "B/other.md", at: checkout)
                    try await fixture.selectFixtureFiles(selectedPaths)

                    let selection = StoredSelection(selectedPaths: selectedPaths)
                    let store = fixture.files.workspaceFileContextStore
                    let rootsBeforeElection = await Set(store.rootRefs(scope: .visibleWorkspace))
                    XCTAssertEqual(Set(rootsBeforeElection.map(\.standardizedFullPath)), Set(roots.map(\.path)))
                    XCTAssertFalse(rootsBeforeElection.contains { $0.standardizedFullPath == checkout.path })
                    let context = try await self.resolve(fixture, selection: selection)
                    let rootsAfterElection = await Set(store.rootRefs(scope: .visibleWorkspace))
                    XCTAssertEqual(rootsAfterElection, rootsBeforeElection)
                    XCTAssertEqual(Set(context.reviewGitContext.displayContext.roots.map(\.logicalRootPath)), Set(roots.map(\.path)))
                    // Exact checkout ownership must not require one loaded root containing both contributors.
                    guard case let .available(target) = context.reviewTargetResolution else {
                        return XCTFail("Expected available review target for sibling roots B+C in one checkout; observed \(context.reviewTargetResolution)")
                    }
                    XCTAssertEqual(target.checkouts.count, 1)
                    XCTAssertEqual(target.primaryCheckout.checkoutRootPath, checkout.path)
                    XCTAssertEqual(Set(target.initialOrdinarySelectionIdentities), Set(selectedPaths))
                    XCTAssertEqual(Set(target.primaryCheckout.contributingRoots.map(\.physicalWorkspaceRoot.standardizedFullPath)), Set(roots.map(\.path)))
                    let final = try await context.authorizeFinalReviewSelection(
                        selection, workspaceID: fixture.workspace.id, tabID: context.tabID,
                        selectionRevision: target.sourceSelectionRevision, store: store
                    )
                    XCTAssertEqual(final.electionOrigin, .initiallyAvailable)
                    XCTAssertEqual(final.checkoutAuthorizations.count, 1)
                    XCTAssertEqual(Set(final.checkoutAuthorizations.flatMap(\.ordinaryPhysicalPaths)), Set(selectedPaths))
                    let diff = try await AutomaticReviewGitDiffCoordinator(dependencies: .live(store: store)).resolveStrict(
                        AutomaticReviewGitDiffRequest(
                            finalReviewAuthorization: final, compareIntent: context.reviewGitContext.compareIntent,
                            displayContext: context.reviewGitContext.displayContext
                        )
                    )
                    XCTAssertEqual(diff.completeness, .complete)
                    let text = try XCTUnwrap(diff.text)
                    XCTAssertTrue(text.contains("SELECTED_B_CHANGE"), text)
                    XCTAssertTrue(text.contains("SELECTED_C_CHANGE"), text)
                    XCTAssertFalse(text.contains("UNSELECTED_SIBLING_CHANGE"), text)
                    let input = ContextBuilderReviewTargetInput(
                        workspaceID: fixture.workspace.id, tabID: context.tabID,
                        selectionRevision: target.sourceSelectionRevision, selection: selection,
                        lookupContext: context.lookupContext, reviewGitContext: context.reviewGitContext
                    )
                    do {
                        _ = try await ContextBuilderReviewTargetResolver().finalizeSelection(
                            input: input, initialResolution: .unavailable(.ambiguousOwnership), store: store
                        )
                        XCTFail("Initial unavailability must remain terminal")
                    } catch let reason as ContextBuilderReviewTargetUnavailableReason {
                        XCTAssertEqual(reason, .ambiguousOwnership)
                    }
                    await fixture.files.unloadRootFolderPath(roots[staleRootIndex].path)
                    let reason = await ContextBuilderReviewTargetResolver().revalidate(target, store: store)
                    XCTAssertEqual(reason, .staleWorkspaceRoot, "Contributor \(staleRootIndex) must remain required")
                    do {
                        _ = try await context.authorizeFinalReviewSelection(
                            selection, workspaceID: fixture.workspace.id, tabID: context.tabID,
                            selectionRevision: target.sourceSelectionRevision, store: store
                        )
                        XCTFail("Finalization must reject the unloaded contributor")
                    } catch let reason as ContextBuilderReviewTargetUnavailableReason {
                        XCTAssertEqual(reason, .unresolvedSelection(count: 1))
                    }
                }
            }
        }

        func testLogicalAliasesOfOneOwnedWorktreeElectAndFinalizeReview() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["A", "B", "Worktree"], configuration: { Array($0.prefix(2)) }) { fixture in
                let firstBinding = try fixture.makeWorktreeBinding(logicalRootIndex: 0, worktreeRootIndex: 2)
                let alias = URL(fileURLWithPath: fixture.rootPaths[1], isDirectory: true)
                let git = try ReviewGitRepositoryFixture()
                try FileManager.default.removeItem(at: alias.appendingPathComponent("README.md"))
                try git.runGit(["worktree", "add", "--detach", alias.path, "HEAD"], at: URL(fileURLWithPath: fixture.rootPaths[0]))
                let secondBinding = AgentSessionWorktreeBinding(
                    id: "alias-binding", repositoryID: firstBinding.repositoryID, repoKey: firstBinding.repoKey,
                    logicalRootPath: alias.path, logicalRootName: "alias",
                    worktreeID: firstBinding.worktreeID, worktreeRootPath: firstBinding.worktreeRootPath,
                    commonGitDir: firstBinding.commonGitDir, isMainWorktree: firstBinding.isMainWorktree, source: "test"
                )
                // Selecting either logical alias must resolve through the same materialized physical authority.
                let selection = StoredSelection(selectedPaths: [alias.appendingPathComponent("README.md").path])
                let context = try await self.resolve(fixture, selection: selection, bindingState: .hydrated([secondBinding, firstBinding]))
                let store = fixture.files.workspaceFileContextStore
                let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
                defer {
                    fixture.startOwnedTask { await materializer.release(sessionID: context.parentAgentSessionID) }
                }
                let projection = try XCTUnwrap(context.lookupContext.bindingProjection)
                let boundRoots = projection.boundRootsForMetadata
                XCTAssertEqual(boundRoots.count, 2)
                XCTAssertEqual(projection.physicalRootRefs.count, 1)
                XCTAssertEqual(Set(projection.logicalRootRefs.map(\.standardizedFullPath)), Set(fixture.rootPaths.prefix(2)))
                let root = try XCTUnwrap(boundRoots.first)
                let authorization = try XCTUnwrap(root.sessionRootAuthorization)
                XCTAssertTrue(boundRoots.allSatisfy { $0.sessionRootAuthorization == authorization })
                guard case let .available(target) = context.reviewTargetResolution else {
                    return XCTFail("Compatible logical aliases must not be ambiguous: \(context.reviewTargetResolution)")
                }
                XCTAssertEqual(target.checkouts.count, 1)
                XCTAssertEqual(target.primaryCheckout.contributingRoots.count, 1)
                XCTAssertEqual(target.primaryCheckout.contributingRoots.first?.sessionRootAuthorization, authorization)
                let physicalPath = firstBinding.worktreeRootPath + "/README.md"
                XCTAssertEqual(target.initialOrdinarySelectionIdentities, [physicalPath])
                let final = try await context.authorizeFinalReviewSelection(
                    selection, workspaceID: fixture.workspace.id, tabID: context.tabID,
                    selectionRevision: target.sourceSelectionRevision, store: store
                )
                XCTAssertEqual(final.checkoutAuthorizations.flatMap(\.ordinaryPhysicalPaths), [physicalPath])

                // A conflicting lifetime on an alias must not be hidden by choosing the first binding.
                let other = try XCTUnwrap(boundRoots.last)
                let conflictingProjection = WorkspaceRootBindingProjection(
                    sessionID: projection.sessionID,
                    boundRoots: [root, .init(
                        logicalRoot: other.logicalRoot, physicalRoot: other.physicalRoot, binding: other.binding,
                        sessionRootAuthorization: WorkspaceSessionRootAuthorization(
                            sessionID: authorization.sessionID, ownershipGeneration: authorization.ownershipGeneration,
                            root: authorization.root, lifetimeID: UUID()
                        )
                    )],
                    visibleLogicalRoots: projection.visibleLogicalRootRefs
                )
                let conflicting = try await ContextBuilderReviewTargetResolver().resolve(
                    input: ContextBuilderReviewTargetInput(
                        workspaceID: fixture.workspace.id, tabID: context.tabID,
                        selectionRevision: target.sourceSelectionRevision, selection: StoredSelection(selectedPaths: [physicalPath]),
                        lookupContext: WorkspaceLookupContext(
                            rootScope: conflictingProjection.lookupRootScope, bindingProjection: conflictingProjection
                        ),
                        reviewGitContext: context.reviewGitContext
                    ), store: store
                )
                guard case .unavailable(.ambiguousOwnership) = conflicting else {
                    return XCTFail("Conflicting alias authority must remain ambiguous: \(conflicting)")
                }
                await materializer.release(sessionID: context.parentAgentSessionID)
                let reason = await ContextBuilderReviewTargetResolver().revalidate(target, store: store)
                XCTAssertEqual(reason, .staleWorkspaceRoot)
            }
        }

        func testInvalidWholeManifestReturnsSafeNonretryableMCPTextWithoutChangingRoots() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                try await fixture.selectFixtureFiles([fixture.rootPaths[0] + "/README.md"])
                let before = try await fixture.capturePassive()
                for paths in [[], [" \n"], [fixture.rootPaths[1], ""], ["sensitive\0path"], ["file://sensitive"]] {
                    do {
                        _ = try await self.resolve(fixture, paths: paths)
                        XCTFail("Invalid whole manifest was admitted")
                    } catch {
                        guard case let .readiness(failure) = error as? ContextBuilderWorkspaceContextError else {
                            return XCTFail("Expected typed Context Builder readiness error")
                        }
                        XCTAssertEqual(failure.reason, paths.isEmpty ? .emptyConfiguration : .invalidConfiguration)
                        XCTAssertFalse(failure.retryable)
                        XCTAssertTrue(error.localizedDescription.contains(paths.isEmpty ? "Configure at least one workspace root" : "Correct blank or invalid workspace root entries"))
                        let category = paths.isEmpty ? "empty_configuration" : "invalid_configuration"
                        XCTAssertTrue(error.localizedDescription.hasPrefix("context_builder_\(category); retryable=false."))
                        XCTAssertFalse(error.localizedDescription.contains("sensitive"))
                    }
                    XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), before.shellPaths)
                    XCTAssertEqual(fixture.files.snapshotSelection(), before.selection)
                    let roots = await fixture.files.workspaceFileContextStore.roots()
                    XCTAssertEqual(Set(roots.map(\.id)), Set(before.primaryRoots.map(\.id)))
                }
            }
        }

        func testReadinessSummariesAreRedactedAndEmittedOncePerPhase() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let events = ReadinessEvents()
                let context = try await self.resolve(fixture, readinessDiagnosticSink: events.sink)
                try await context.validateStartupAvailability(workspaceManager: fixture.manager)
                try await context.validateStartupAvailability(workspaceManager: fixture.manager, phase: .launchRevalidation)
                XCTAssertEqual(events.values.map(\.phase), [.admission, .resolved, .startupRevalidation, .launchRevalidation])
                XCTAssertTrue(events.values.allSatisfy { $0.outcome == .ready && $0.expectedCount == 2 && $0.loadedCount == 2 && $0.missingCount == 0 })
                for event in events.values {
                    XCTAssertEqual(event.workspaceID, fixture.workspace.id)
                    XCTAssertEqual(event.tabID, context.frozenTabContext.tabID)
                    XCTAssertEqual(event.runID, context.frozenTabContext.runID)
                    XCTAssertEqual(event.activationGeneration, context.primaryRootSnapshot?.ticket.activationGeneration)
                    XCTAssertEqual(event.rootIntentGeneration, context.primaryRootSnapshot?.ticket.rootIntentGeneration)
                    for sensitive in [fixture.base.path, "sensitive-prompt", "sensitive-name", "README.md"] {
                        XCTAssertFalse(event.description.contains(sensitive))
                    }
                }
            }
        }

        func testAdmissionAndStartupDeadlinesDetachFromHeldObservationAndProbeWithoutCancellingSharedWork() async throws {
            for phase in [WorkspaceManagerViewModel.RootReconciliationTestEvent.Phase.observationResponse, .probeResponse] {
                try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                    let events = ReadinessEvents()
                    let context = try await self.resolve(fixture, readinessDiagnosticSink: events.sink)
                    let initialEvents = events.values.count
                    let entered = XCTestExpectation(description: "resolver response held")
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
                    let registered = XCTestExpectation(description: "admission, validator, cancellation and survivor registered")
                    var registeredOnce = false
                    fixture.manager.rootReconciliationWaiterCountDidChangeForTesting = { count in
                        if count == 4, !registeredOnce { registeredOnce = true
                            registered.fulfill()
                        }
                    }
                    let admissionDone = XCTestExpectation(description: "admission deadline detached")
                    let started = ContinuousClock.now
                    fixture.startOwnedTask {
                        await self.expectReadiness(.rootsChanging, code: "roots_changing", retryable: true, guidance: "Retry this request shortly") {
                            _ = try await self.resolve(fixture, readinessDiagnosticSink: events.sink)
                        }
                        admissionDone.fulfill()
                    }
                    try await fixture.awaitGateEvent(entered)
                    let validationDone = XCTestExpectation(description: "startup deadline detached")
                    fixture.startOwnedTask {
                        await self.expectReadiness(.rootsChanging, code: "roots_changing", retryable: true, guidance: "Retry this request shortly") {
                            try await context.validateStartupAvailability(workspaceManager: fixture.manager)
                        }
                        validationDone.fulfill()
                    }
                    let cancelled = XCTestExpectation(description: "cancelled Context Builder consumer detached")
                    var cancellationSettlements = 0
                    let task = fixture.startOwnedTask {
                        do {
                            if phase == .observationResponse {
                                _ = try await self.resolve(fixture, readinessDiagnosticSink: events.sink)
                            } else {
                                try await context.validateStartupAvailability(workspaceManager: fixture.manager)
                            }
                            XCTFail("Cancelled consumer returned ready")
                        } catch is CancellationError {} catch { XCTFail("Cancellation was translated: \(error)") }
                        cancellationSettlements += 1
                        cancelled.fulfill()
                    }
                    let ticket = try XCTUnwrap(fixture.manager.requestRootReconciliation(workspaceID: fixture.workspace.id))
                    let survivorDone = XCTestExpectation(description: "shared root operation survived")
                    var survived = false
                    fixture.startOwnedTask {
                        do {
                            let ready = try await fixture.manager.awaitRootReconciliationCompletion(ticket: ticket)
                            XCTAssertEqual(ready, context.primaryRootSnapshot)
                        } catch { XCTFail("Shared operation failed: \(error)") }
                        survived = true
                        survivorDone.fulfill()
                    }
                    try await fixture.awaitGateEvent(registered)
                    let cancelStarted = ContinuousClock.now
                    task.cancel()
                    try await fixture.awaitGateEvent(cancelled)
                    XCTAssertLessThan(cancelStarted.duration(to: .now), .seconds(1))
                    try await fixture.awaitGateEvent(admissionDone)
                    try await fixture.awaitGateEvent(validationDone)
                    XCTAssertGreaterThanOrEqual(started.duration(to: .now), .seconds(1.8))
                    XCTAssertLessThan(started.duration(to: .now), .seconds(4))
                    XCTAssertFalse(survived)
                    XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 1)
                    XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts - starts, 1)
                    let summaries = Array(events.values.dropFirst(initialEvents))
                    XCTAssertEqual(summaries.count, 3)
                    XCTAssertEqual(summaries.count(where: { $0.outcome == .cancelled }), 1)
                    XCTAssertEqual(summaries.count(where: { $0.reason == .rootsChanging && $0.retryable == true }), 2)
                    gate.release()
                    try await fixture.awaitGateEvent(survivorDone)
                    XCTAssertEqual(cancellationSettlements, 1)
                    XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 0)
                    XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.probeBatches - probes, 1)
                    XCTAssertEqual(events.values.count, initialEvents + 3, "Expired invocations cannot publish late ready summaries")
                }
            }
        }

        func testUnrelatedPrimarySystemSessionAndGitDataRootsNeverEnterNestedScope() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(
                rootNames: ["A", "B", "Unrelated", "System", "Session", "GitData"], configuration: { Array($0.prefix(2)) }
            ) { fixture in
                let store = fixture.files.workspaceFileContextStore
                let expected = await store.primaryRootReadinessObservation(orderedPaths: Array(fixture.rootPaths.prefix(2)))
                try await fixture.files.loadFolder(at: URL(fileURLWithPath: fixture.rootPaths[2]), for: fixture.workspace)
                var auxiliaryIDs: [UUID] = []
                defer {
                    let ownedIDs = auxiliaryIDs
                    fixture.startOwnedTask { for id in ownedIDs {
                        await store.unloadRoot(id: id)
                    } }
                }
                for (index, kind) in [(3, WorkspaceRootKind.supplementalSystem), (4, .sessionWorktree), (5, .workspaceGitData)] {
                    let root = try await store.loadRoot(path: fixture.rootPaths[index], kind: kind)
                    auxiliaryIDs.append(root.id)
                }
                let before = await store.roots()
                let context = try await self.resolve(fixture)
                XCTAssertEqual(context.primaryRootSnapshot?.roots, expected.requestedRoots)
                let nested = context.nestedDiscoveryTabContext(runID: UUID())
                let scope = try XCTUnwrap(nested.frozenLookupContext).rootScope
                let after = await store.roots()
                XCTAssertEqual(Set(after.filter { $0.kind != .primaryWorkspace }), Set(before.filter { $0.kind != .primaryWorkspace }))
                // Reintroduce a different primary after admission: nested lookup must still use only frozen IDs.
                try await fixture.files.loadFolder(at: URL(fileURLWithPath: fixture.rootPaths[2]), for: fixture.workspace)
                for (index, path) in fixture.rootPaths.enumerated() {
                    let result = await store.lookupPath(path + "/README.md", profile: .uiAssisted, rootScope: scope)
                    if index < 2 { XCTAssertEqual(result?.file?.rootID, expected.requestedRoots[index].id) }
                    else { XCTAssertNil(result, "Unrelated root entered exact invocation scope") }
                }
                XCTAssertEqual(context.primaryRootSnapshot?.roots.map(\.standardizedFullPath), Array(fixture.rootPaths.prefix(2)))
            }
        }

        func testSamePathReplacementAdmitsFreshIDsButOldValidatorAndNestedLookupReject() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let old = try await self.resolve(fixture)
                let original = try XCTUnwrap(old.primaryRootSnapshot)
                await fixture.files.unloadRootFolderPath(fixture.rootPaths[1])
                try "sensitive-error replacement content".write(toFile: fixture.rootPaths[1] + "/README.md", atomically: true, encoding: .utf8)
                try await fixture.files.loadFolder(at: URL(fileURLWithPath: fixture.rootPaths[1]), for: fixture.workspace)
                let fresh = try await self.resolve(fixture)
                let replacement = try XCTUnwrap(fresh.primaryRootSnapshot)
                XCTAssertEqual(replacement.ticket, original.ticket)
                XCTAssertEqual(replacement.roots[0], original.roots[0])
                XCTAssertNotEqual(replacement.roots[1].id, original.roots[1].id)
                XCTAssertEqual(replacement.roots.map(\.standardizedFullPath), fixture.rootPaths)
                await self.expectReadiness(.staleInvocation, code: "stale_invocation", retryable: true, guidance: "Start a new Context Builder request") {
                    try await old.validateStartupAvailability(workspaceManager: fixture.manager)
                }
                let staleRead = await fixture.files.workspaceFileContextStore.lookupPath(
                    fixture.rootPaths[1] + "/README.md", profile: .uiAssisted, rootScope: old.lookupContext.rootScope
                )
                let freshRead = await fixture.files.workspaceFileContextStore.lookupPath(
                    fixture.rootPaths[1] + "/README.md", profile: .uiAssisted, rootScope: fresh.lookupContext.rootScope
                )
                XCTAssertNil(staleRead)
                XCTAssertEqual(freshRead?.file?.rootID, replacement.roots[1].id)
                XCTAssertEqual(old.primaryRootSnapshot, original)
                try await fresh.validateStartupAvailability(workspaceManager: fixture.manager)
            }
        }

        func testMissingRequestedRootCannotUseUnrelatedPrimaryAndSameTicketRetryRecovers() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["A", "B", "Unrelated"], configuration: { Array($0.prefix(2)) }) { fixture in
                let original = try await self.resolve(fixture)
                let ticket = try XCTUnwrap(original.primaryRootSnapshot).ticket
                await fixture.files.unloadRootFolderPath(fixture.rootPaths[1])
                let moved = fixture.base.appendingPathComponent("temporarily-moved")
                try FileManager.default.moveItem(atPath: fixture.rootPaths[1], toPath: moved.path)
                try await fixture.files.loadFolder(at: URL(fileURLWithPath: fixture.rootPaths[2]), for: fixture.workspace)
                let events = ReadinessEvents()
                await self.expectReadiness(.rootsUnavailable(.missingDirectory), code: "roots_unavailable", retryable: true, guidance: "Restore or remove the configured directory") {
                    _ = try await self.resolve(fixture, readinessDiagnosticSink: events.sink)
                }
                XCTAssertEqual(events.values.map(\.outcome), [.rejected])
                XCTAssertEqual(events.values.first?.reason, .rootsUnavailable(.missingDirectory))
                XCTAssertTrue(events.values.first?.description.contains("subreason=missingDirectory") == true)
                XCTAssertNil(fixture.manager.rootReconciliationStateForTesting.attemptID)
                try FileManager.default.moveItem(atPath: moved.path, toPath: fixture.rootPaths[1])
                let entered = XCTestExpectation(description: "same-ticket explicit admission retry held before load")
                let gate = fixture.makeGate()
                var held = false
                fixture.manager.rootReconciliationGateForTesting = { event in
                    if event.phase == .beforeLoad, !held { held = true
                        entered.fulfill()
                        await gate.wait()
                    }
                }
                let done = XCTestExpectation(description: "retry returns only new success")
                var finished = false
                fixture.startOwnedTask {
                    do {
                        let retry = try await self.resolve(fixture)
                        XCTAssertEqual(retry.primaryRootSnapshot?.ticket, ticket)
                        XCTAssertEqual(retry.primaryRootSnapshot?.roots.map(\.standardizedFullPath), Array(fixture.rootPaths.prefix(2)))
                    } catch { XCTFail("Retry inherited old failure: \(error)") }
                    finished = true
                    done.fulfill()
                }
                try await fixture.awaitGateEvent(entered)
                XCTAssertFalse(finished)
                gate.release()
                try await fixture.awaitGateEvent(done)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 0)
            }
        }

        func testUnhydratedBindingStateFailsClosed() async throws {
            try await assertBindingRejected(.unhydrated)
        }

        func testUnavailableBindingStateFailsClosed() async throws {
            try await assertBindingRejected(.unavailable)
        }

        func testNotApplicableBindingStateDoesNotMeanHydratedEmpty() async throws {
            try await assertBindingRejected(.notApplicable)
        }

        private func assertBindingRejected(_ state: AgentSessionWorktreeBindingState) async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let starts = fixture.manager.rootReconciliationStateForTesting.attemptStarts
                do { _ = try await self.resolve(fixture, bindingState: state)
                    XCTFail("Binding guard fell back to visible roots")
                } catch { XCTAssertEqual(error as? ContextBuilderWorkspaceContextError, .unavailableWorktreeBindingState) }
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts, starts)
            }
        }

        func testHydratedEmptyBindingUsesNormalizedSingleRootAndCollapsesDuplicatesInOrder() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(configuration: { [" " + $0[0] + "\n", $0[0]] }) { fixture in
                let context = try await self.resolve(fixture)
                XCTAssertTrue(context.worktreeBindings.isEmpty)
                XCTAssertEqual(context.primaryRootSnapshot?.roots.map(\.standardizedFullPath), [fixture.rootPaths[0]])
                XCTAssertEqual(context.providerWorkspacePath, fixture.rootPaths[0])
                XCTAssertNil(context.lookupContext.bindingProjection)
            }
        }

        func testBoundStartupProbeAllowsMainActorCancellationBeforeHeldFilesystemCompletes() async throws {
            for heldPhase in [ContextBuilderBoundWorkspaceProbe.Phase.beforeFileSystem, .afterFileSystem] {
                try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["A", "B", "Worktree"], configuration: { Array($0.prefix(2)) }) { fixture in
                    try await BoundWorkspaceProbeTestCheckpoint.withCheckpoint { checkpoint in
                        let binding = try fixture.makeWorktreeBinding(logicalRootIndex: 0, worktreeRootIndex: 2)
                        let events = ReadinessEvents()
                        let context = try await self.resolve(fixture, bindingState: .hydrated([binding]), readinessDiagnosticSink: events.sink, boundWorkspaceProbe: checkpoint.probe)
                        defer {
                            fixture.startOwnedTask {
                                await WorkspaceRootBindingProjectionMaterializer(store: fixture.files.workspaceFileContextStore).release(sessionID: context.parentAgentSessionID)
                            }
                        }
                        let starts = fixture.manager.rootReconciliationStateForTesting.attemptStarts
                        let initialEvents = events.values.count
                        checkpoint.arm(.availability, phase: heldPhase)
                        let settled = XCTestExpectation(description: "bound validation cancelled before probe release")
                        var cancellations = 0
                        let task = fixture.startOwnedTask {
                            do {
                                try await context.validateStartupAvailability(workspaceManager: fixture.manager)
                                XCTFail("Cancelled bound validation returned success")
                            } catch is CancellationError { cancellations += 1 }
                            catch { XCTFail("Unexpected bound validation failure: \(error)") }
                            settled.fulfill()
                        }
                        try await fixture.awaitGateEvent(checkpoint.entered)
                        XCTAssertTrue(checkpoint.wasOffMainActor, "Real bound filesystem work must not execute on MainActor")
                        XCTAssertFalse(checkpoint.didFinish)
                        let cancelledAt = ContinuousClock.now
                        task.cancel()
                        await self.fulfillment(of: [settled], timeout: 1)
                        XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(1))
                        XCTAssertEqual(cancellations, 1)
                        XCTAssertFalse(checkpoint.didFinish, "Cancellation must not wait for synchronous I/O")
                        XCTAssertEqual(events.values.dropFirst(initialEvents).map(\.outcome), [.cancelled])
                        checkpoint.release()
                        try await fixture.awaitGateEvent(checkpoint.finished)
                        await checkpoint.joinWorkers()
                        try await fixture.perform("cancelled bound validation joined") { await task.value }
                        XCTAssertEqual(events.values.dropFirst(initialEvents).map(\.outcome), [.cancelled], "Late success must not be published")
                        XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts, starts)
                        XCTAssertNil(context.primaryRootSnapshot)
                        XCTAssertEqual(context.worktreeBindings, [binding])
                        XCTAssertEqual(context.providerWorkspacePath, fixture.rootPaths[2])
                    }
                }
            }
        }

        func testBoundResolverFallbackProbeCancellationDoesNotReturnContext() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["A", "B", "Worktree"], configuration: { Array($0.prefix(2)) }) { fixture in
                try await BoundWorkspaceProbeTestCheckpoint.withCheckpoint { checkpoint in
                    let binding = try fixture.makeWorktreeBinding(logicalRootIndex: 0, worktreeRootIndex: 2)
                    let sessionID = UUID()
                    defer {
                        fixture.startOwnedTask {
                            await WorkspaceRootBindingProjectionMaterializer(store: fixture.files.workspaceFileContextStore).release(sessionID: sessionID)
                        }
                    }
                    let events = ReadinessEvents()
                    let starts = fixture.manager.rootReconciliationStateForTesting.attemptStarts
                    checkpoint.arm(.executionDirectory, phase: .afterFileSystem)
                    let settled = XCTestExpectation(description: "resolver cancelled before fallback result released")
                    var cancellations = 0
                    let task = fixture.startOwnedTask {
                        do {
                            _ = try await self.resolve(fixture, bindingState: .hydrated([binding]), readinessDiagnosticSink: events.sink, boundWorkspaceProbe: checkpoint.probe, sessionID: sessionID)
                            XCTFail("Cancelled resolver returned a context")
                        } catch is CancellationError { cancellations += 1 }
                        catch { XCTFail("Unexpected resolver failure: \(error)") }
                        settled.fulfill()
                    }
                    try await fixture.awaitGateEvent(checkpoint.entered)
                    XCTAssertTrue(checkpoint.wasOffMainActor)
                    XCTAssertFalse(checkpoint.didFinish)
                    task.cancel()
                    await self.fulfillment(of: [settled], timeout: 1)
                    XCTAssertEqual(cancellations, 1)
                    XCTAssertFalse(checkpoint.didFinish)
                    XCTAssertEqual(events.values.map(\.outcome), [.ready, .cancelled])
                    checkpoint.release()
                    try await fixture.awaitGateEvent(checkpoint.finished)
                    await checkpoint.joinWorkers()
                    try await fixture.perform("cancelled fallback resolver joined") { await task.value }
                    XCTAssertEqual(events.values.map(\.phase), [.admission, .resolved])
                    XCTAssertEqual(events.values.map(\.outcome), [.ready, .cancelled])
                    XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts, starts)
                }
            }
        }

        func testHydratedNonemptyBindingsKeepWorktreeProjectionAndNoPrimarySnapshot() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["A", "B", "Worktree"], configuration: { Array($0.prefix(2)) }) { fixture in
                let binding = try fixture.makeWorktreeBinding(logicalRootIndex: 0, worktreeRootIndex: 2)
                let starts = fixture.manager.rootReconciliationStateForTesting.attemptStarts
                let context = try await self.resolve(fixture, bindingState: .hydrated([binding]))
                defer {
                    fixture.startOwnedTask {
                        await WorkspaceRootBindingProjectionMaterializer(store: fixture.files.workspaceFileContextStore).release(sessionID: context.parentAgentSessionID)
                    }
                }
                XCTAssertNil(context.primaryRootSnapshot)
                XCTAssertEqual(context.worktreeBindings, [binding])
                XCTAssertEqual(context.providerWorkspacePath, fixture.rootPaths[2])
                XCTAssertEqual(context.lookupContext.bindingProjection?.sessionID, context.parentAgentSessionID)
                guard case let .validatedSessionBoundWorkspace(_, physicalRoots, _) = context.lookupContext.rootScope else {
                    return XCTFail("Bound projection lost validated scope")
                }
                XCTAssertEqual(physicalRoots.map(\.standardizedFullPath), [fixture.rootPaths[2]])
                try await context.validateStartupAvailability(workspaceManager: fixture.manager)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.attemptStarts, starts)
            }
        }

        func testInvalidNonemptyBindingNeverFallsBackToPrimarySnapshot() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let invalid = self.binding(logicalPath: fixture.rootPaths[0], worktreePath: fixture.rootPaths[0])
                do { _ = try await self.resolve(fixture, bindingState: .hydrated([invalid]))
                    XCTFail("Invalid binding fell back")
                } catch { XCTAssertEqual(error as? ContextBuilderWorkspaceContextError, .unavailableWorktreeProjection) }
            }
        }

        private func binding(logicalPath: String, worktreePath: String) -> AgentSessionWorktreeBinding {
            AgentSessionWorktreeBinding(
                id: "binding", repositoryID: "repository", repoKey: "repo-key", logicalRootPath: logicalPath,
                logicalRootName: "sensitive-name", worktreeID: "worktree", worktreeRootPath: worktreePath, source: "test"
            )
        }

        func testUnavailableInactiveAndChangedExpectedManifestHaveDistinctCategories() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                for paths in [[], ["invalid\0entry"], fixture.rootPaths] {
                    await self.expectReadiness(.workspaceUnavailable, code: "workspace_unavailable", retryable: false, guidance: "Open an existing workspace") {
                        _ = try await self.resolve(fixture, paths: paths, workspaceID: UUID())
                    }
                }
                let inactive = try await fixture.createAdditionalWorkspace(name: "Inactive", repoPaths: [fixture.rootPaths[0]])
                await self.expectReadiness(.workspaceInactive, code: "workspace_inactive", retryable: true, guidance: "Activate the invoking workspace") {
                    _ = try await self.resolve(fixture, paths: inactive.repoPaths, workspaceID: inactive.id)
                }
                XCTAssertEqual(fixture.manager.activeWorkspaceID, fixture.workspace.id)
                await self.expectReadiness(.staleInvocation, code: "stale_invocation", retryable: true, guidance: "Start a new Context Builder request") {
                    _ = try await self.resolve(fixture, paths: Array(fixture.rootPaths.reversed()))
                }
            }
        }

        func testWrongKindOnlyCoverageRejectsBeforeUnwantedUnloadReorderOrSelectionRemoval() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(rootNames: ["A", "B", "Unrelated"], configuration: { Array($0.prefix(2)) }) { fixture in
                await fixture.files.unloadRootFolderPath(fixture.rootPaths[1])
                try await fixture.files.loadFolder(at: URL(fileURLWithPath: fixture.rootPaths[1]), for: fixture.workspace, rootKind: .supplementalSystem)
                try await fixture.files.loadFolder(at: URL(fileURLWithPath: fixture.rootPaths[2]), for: fixture.workspace)
                try await fixture.selectFixtureFiles([fixture.rootPaths[2] + "/README.md"])
                let store = fixture.files.workspaceFileContextStore
                let before = await store.roots()
                let shells = fixture.files.visibleRootShellProjections
                let selection = fixture.files.snapshotSelection()
                await self.expectReadiness(.wrongRootKind, code: "wrong_root_kind", retryable: false, guidance: "Correct workspace root ownership") {
                    _ = try await self.resolve(fixture)
                }
                let after = await store.roots()
                XCTAssertEqual(Set(after), Set(before))
                XCTAssertEqual(fixture.files.visibleRootShellProjections, shells)
                XCTAssertEqual(fixture.files.snapshotSelection(), selection)
            }
        }

        func testTerminalAvailabilitySubreasonsReturnCorrectiveGuidanceWithoutRawErrors() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let events = ReadinessEvents()
                for (failure, guidance) in [(WorkspaceRootReadinessFailure.Availability.accessDenied, "Restore directory access"), (.loadFailed, "root loading issue")] {
                    fixture.manager.rootProbeFailureForTesting = failure
                    await self.expectReadiness(.rootsUnavailable(failure), code: "roots_unavailable", retryable: true, guidance: guidance) {
                        _ = try await self.resolve(fixture, readinessDiagnosticSink: events.sink)
                    }
                    XCTAssertEqual(events.values.last?.reason, .rootsUnavailable(failure))
                    XCTAssertEqual(events.values.last?.outcome, .rejected)
                    XCTAssertFalse(events.values.last?.description.contains(fixture.base.path) == true)
                }
                fixture.manager.rootProbeFailureForTesting = nil
                await fixture.files.unloadRootFolderPath(fixture.rootPaths[1])
                try FileManager.default.removeItem(atPath: fixture.rootPaths[1])
                try "sensitive-error".write(toFile: fixture.rootPaths[1], atomically: true, encoding: .utf8)
                await self.expectReadiness(.rootsUnavailable(.notDirectory), code: "roots_unavailable", retryable: true, guidance: "Replace the configured file with a directory") {
                    _ = try await self.resolve(fixture, readinessDiagnosticSink: events.sink)
                }
                XCTAssertEqual(events.values.map(\.reason), [.rootsUnavailable(.accessDenied), .rootsUnavailable(.loadFailed), .rootsUnavailable(.notDirectory)])
                XCTAssertEqual(fixture.manager.activeWorkspace?.repoPaths, fixture.rootPaths)
            }
        }

        func testPartialPrimaryCoverageReportsIncompleteProjectionNotEmptyConfiguration() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let events = ReadinessEvents()
                var removed = false
                fixture.manager.rootReconciliationGateForTesting = { event in
                    guard event.phase == .beforeReorder, !removed else { return }
                    removed = true
                    await fixture.files.unloadRootFolderPath(fixture.rootPaths[1])
                }
                await self.expectReadiness(.incompleteProjection, code: "incomplete_projection", retryable: true, guidance: "Not all configured primary roots are queryable") {
                    _ = try await self.resolve(fixture, readinessDiagnosticSink: events.sink)
                }
                XCTAssertEqual(events.values.first?.expectedCount, 2)
                XCTAssertEqual(events.values.first?.loadedCount, 1)
                XCTAssertEqual(events.values.first?.missingCount, 1)
            }
        }

        func testBlockedFailedAndPostProbeQueryableAuthorityRejectAdmissionAndDirectValidator() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let context = try await self.resolve(fixture)
                let snapshot = try XCTUnwrap(context.primaryRootSnapshot)
                let store = fixture.files.workspaceFileContextStore
                for fault in [WorkspaceFileContextStore.PrimaryRootQueryabilityFailureForTesting.blocked, .failed] {
                    await store.setPrimaryRootQueryabilityFailureForTesting(rootID: snapshot.roots[1].id, failure: fault)
                    let observation = await store.primaryRootReadinessObservation(orderedPaths: fixture.rootPaths)
                    XCTAssertEqual(observation.requestedRoots, snapshot.roots)
                    await self.expectReadiness(.incompleteProjection, code: "incomplete_projection", retryable: true, guidance: "Refresh the workspace and retry") {
                        _ = try await self.resolve(fixture)
                    }
                    await self.expectReadiness(.incompleteProjection, code: "incomplete_projection", retryable: true, guidance: "Refresh the workspace and retry") {
                        try await context.validateStartupAvailability(workspaceManager: fixture.manager)
                    }
                }
                await store.setPrimaryRootQueryabilityFailureForTesting(rootID: snapshot.roots[1].id, failure: nil)
                var denied = false
                fixture.manager.rootReconciliationGateForTesting = { event in
                    if event.phase == .beforeCompletion, !denied {
                        denied = true
                        await store.setPrimaryRootQueryabilityFailureForTesting(rootID: snapshot.roots[1].id, failure: .blocked)
                    }
                }
                await self.expectReadiness(.incompleteProjection, code: "incomplete_projection", retryable: true, guidance: "Refresh the workspace and retry") {
                    try await context.validateStartupAvailability(workspaceManager: fixture.manager)
                }
                fixture.manager.rootReconciliationGateForTesting = nil
                await store.setPrimaryRootQueryabilityFailureForTesting(rootID: snapshot.roots[1].id, failure: nil)
                try await context.validateStartupAvailability(workspaceManager: fixture.manager)
            }
        }

        func testProviderCWDUsesTheSameBoundedStartupProbeBatchAndResolvedFailurePhase() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let cwd = fixture.base.appendingPathComponent("sensitive-provider-cwd")
                try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
                let events = ReadinessEvents()
                let context = try await self.resolve(fixture, directoryPath: cwd.path, readinessDiagnosticSink: events.sink)
                try FileManager.default.removeItem(at: cwd)
                let entered = XCTestExpectation(description: "provider CWD probe response held")
                let gate = fixture.makeGate()
                var armed = true
                fixture.manager.rootReconciliationGateForTesting = { event in
                    if event.phase == .probeResponse, armed { armed = false
                        entered.fulfill()
                        await gate.wait()
                    }
                }
                let probes = fixture.manager.rootReconciliationStateForTesting.probeBatches
                let done = XCTestExpectation(description: "startup detaches while CWD probe response is held")
                fixture.startOwnedTask {
                    await self.expectReadiness(.rootsChanging, code: "roots_changing", retryable: true, guidance: "Retry this request shortly") {
                        try await context.validateStartupAvailability(workspaceManager: fixture.manager)
                    }
                    done.fulfill()
                }
                try await fixture.awaitGateEvent(entered)
                try await fixture.awaitGateEvent(done)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.probeBatches - probes, 1)
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.waiterCount, 0)
                gate.release()
                try await fixture.perform("expired validation batch joined") { await fixture.manager.awaitRootReconciliationShutdown() }
                await self.expectReadiness(.rootsUnavailable(.missingDirectory), code: "roots_unavailable", retryable: true, guidance: "Restore or remove the configured directory") {
                    try await context.validateStartupAvailability(workspaceManager: fixture.manager)
                }
                XCTAssertEqual(fixture.manager.rootReconciliationStateForTesting.probeBatches - probes, 2)
                let resolvedEvents = ReadinessEvents()
                await self.expectReadiness(.rootsUnavailable(.missingDirectory), code: "roots_unavailable", retryable: true, guidance: "Restore or remove the configured directory") {
                    _ = try await self.resolve(fixture, directoryPath: cwd.path, readinessDiagnosticSink: resolvedEvents.sink)
                }
                XCTAssertEqual(resolvedEvents.values.map(\.phase), [.admission, .resolved])
                XCTAssertEqual(resolvedEvents.values.map(\.outcome), [.ready, .rejected])
                XCTAssertFalse(resolvedEvents.values.last?.description.contains("sensitive-provider-cwd") == true)
            }
        }

        func testDirectValidatorNeverRecapturesChangedConfiguredOrder() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let context = try await self.resolve(fixture)
                let frozen = context.primaryRootSnapshot
                await fixture.manager.moveActiveWorkspaceRoot(path: fixture.rootPaths[1], direction: .up, visibleRootOrder: fixture.rootPaths)
                await self.expectReadiness(.staleInvocation, code: "stale_invocation", retryable: true, guidance: "Start a new Context Builder request") {
                    try await context.validateStartupAvailability(workspaceManager: fixture.manager)
                }
                XCTAssertEqual(context.primaryRootSnapshot, frozen)
                let fresh = try await self.resolve(fixture)
                XCTAssertEqual(fresh.primaryRootSnapshot?.roots.map(\.standardizedFullPath), Array(fixture.rootPaths.reversed()))
            }
        }

        func testAdmissionWaitsForTheCompleteManifestDuringActualDelayedRootAddition() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(configuration: { [$0[0]] }) { fixture in
                let gate = try fixture.manager.armRootPreloadGateForTesting(
                    windowID: -944, workspaceID: fixture.workspace.id, rootIndex: 1, expectedPath: fixture.rootPaths[1]
                )
                let entered = XCTestExpectation(description: "accepted two-root intent held before loading second root")
                gate.didHold = { entered.fulfill() }
                var addFinished = false
                let add = fixture.startOwnedTask {
                    do { try await fixture.manager.addFolder(URL(fileURLWithPath: fixture.rootPaths[1]), to: fixture.workspace) }
                    catch { XCTFail("Delayed fixture add failed: \(error)") }
                    addFinished = true
                }
                try await fixture.awaitGateEvent(entered)
                XCTAssertEqual(fixture.manager.activeWorkspace?.repoPaths, fixture.rootPaths)
                let events = ReadinessEvents()
                let started = ContinuousClock.now
                await self.expectReadiness(.rootsChanging, code: "roots_changing", retryable: true, guidance: "Retry this request shortly") {
                    _ = try await self.resolve(fixture, readinessDiagnosticSink: events.sink)
                }
                XCTAssertGreaterThanOrEqual(started.duration(to: .now), .seconds(1.8))
                XCTAssertLessThan(started.duration(to: .now), .seconds(4))
                XCTAssertFalse(addFinished)
                XCTAssertEqual(events.values.map(\.phase), [.admission])
                XCTAssertEqual(events.values.first?.expectedCount, 2)
                XCTAssertEqual(fixture.files.visibleRootShellProjections.map(\.fullPath), [fixture.rootPaths[0]])
                fixture.manager.clearRootPreloadGateForTesting()
                try await fixture.perform("delayed add cooperatively completes") { await add.value }
                let retry = try await self.resolve(fixture)
                XCTAssertEqual(retry.primaryRootSnapshot?.roots.map(\.standardizedFullPath), fixture.rootPaths)
            }
        }

        func testStillConfiguredDeletedDirectoryFailsValidationWithoutReplacingCapturedIDs() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture { fixture in
                let context = try await self.resolve(fixture)
                let original = context.primaryRootSnapshot
                let moved = fixture.base.appendingPathComponent("temporarily-unavailable")
                try FileManager.default.moveItem(atPath: fixture.rootPaths[1], toPath: moved.path)
                await self.expectReadiness(.rootsUnavailable(.missingDirectory), code: "roots_unavailable", retryable: true, guidance: "Restore or remove the configured directory") {
                    try await context.validateStartupAvailability(workspaceManager: fixture.manager)
                }
                XCTAssertEqual(context.primaryRootSnapshot, original)
                try FileManager.default.moveItem(atPath: moved.path, toPath: fixture.rootPaths[1])
                try await context.validateStartupAvailability(workspaceManager: fixture.manager)
                XCTAssertEqual(context.primaryRootSnapshot, original)
            }
        }

        private func expectReadiness(
            _ reason: WorkspaceRootReadinessFailure.Reason,
            code: String, retryable: Bool, guidance: String,
            file: StaticString = #filePath, line: UInt = #line,
            _ operation: () async throws -> Void
        ) async {
            do { try await operation()
                XCTFail("Expected a typed readiness rejection", file: file, line: line)
            } catch {
                guard case let .readiness(failure) = error as? ContextBuilderWorkspaceContextError else {
                    return XCTFail("Unexpected error type: \(error)", file: file, line: line)
                }
                XCTAssertEqual(failure.reason, reason, file: file, line: line)
                XCTAssertEqual(failure.retryable, retryable, file: file, line: line)
                let message = error.localizedDescription
                XCTAssertTrue(message.hasPrefix("context_builder_\(code); retryable=\(retryable)."), file: file, line: line)
                XCTAssertTrue(message.contains(guidance), file: file, line: line)
                if case let .rootsUnavailable(availability) = reason {
                    XCTAssertTrue(message.contains("subreason=\(availability.rawValue)"), file: file, line: line)
                }
                for sentinel in ["sensitive-prompt", "sensitive-name", "sensitive-error", "root-fixture-", "/private/tmp/"] {
                    XCTAssertFalse(message.contains(sentinel), file: file, line: line)
                }
            }
        }

        private final class ReadinessEvents: @unchecked Sendable {
            var sink: ContextBuilderWorkspaceReadinessDiagnosticSink {
                { [self] in append($0) }
            }

            private let lock = NSLock()
            private var storage: [ContextBuilderWorkspaceReadinessDiagnosticEvent] = []
            var values: [ContextBuilderWorkspaceReadinessDiagnosticEvent] {
                lock.withLock { storage }
            }

            func append(_ event: ContextBuilderWorkspaceReadinessDiagnosticEvent) {
                lock.withLock { storage.append(event) }
            }
        }

        private func resolve(
            _ fixture: WorkspaceAuthorityRootTestFixture,
            paths: [String]? = nil,
            selection: StoredSelection = StoredSelection(),
            bindingState: AgentSessionWorktreeBindingState = .hydrated([]),
            workspaceID: UUID? = nil,
            directoryPath: String? = nil,
            readinessDiagnosticSink: ContextBuilderWorkspaceReadinessDiagnosticSink? = nil,
            boundWorkspaceProbe: ContextBuilderBoundWorkspaceProbe = .init(),
            sessionID: UUID = UUID()
        ) async throws -> ContextBuilderWorkspaceContext {
            let model = try XCTUnwrap(fixture.manager.workspace(withID: fixture.workspace.id))
            let snapshot = try MCPServerViewModel.TabContextSnapshot(
                tabID: XCTUnwrap(model.activeComposeTabID), windowID: -944,
                workspaceID: workspaceID ?? model.id, promptText: "sensitive-prompt", selection: selection,
                selectedMetaPromptIDs: [], tabName: "sensitive-name", runID: UUID(), activeAgentSessionID: sessionID,
                worktreeBindingState: bindingState, explicitlyBound: true
            )
            return try await ContextBuilderWorkspaceContext.resolve(
                from: snapshot, workspaceRepoPaths: paths ?? model.repoPaths,
                workspaceDirectoryPath: directoryPath ?? fixture.workspaceURL.deletingLastPathComponent().path,
                workspaceManager: fixture.manager, readinessDiagnosticSink: readinessDiagnosticSink,
                boundWorkspaceProbe: boundWorkspaceProbe
            )
        }

        func testMultiRootAdmissionFreezesExactPrimaryIDsForNestedLookup() async throws {
            try await WorkspaceAuthorityRootTestFixture.withFixture(paddedConfiguration: true) { fixture in
                let capture = try await fixture.capturePassive()
                let context = try await fixture.admit()
                XCTAssertEqual(context.primaryRootSnapshot?.roots, capture.readinessObservation.requestedRoots)
                XCTAssertEqual(context.reviewGitContext.displayContext.roots.map(\.logicalRootPath), fixture.rootPaths)
                guard case let .validatedSessionBoundWorkspace(canonicalRoots, physicalRoots, _) = context.lookupContext.rootScope else {
                    return XCTFail("Admission must freeze validated root IDs, not only paths")
                }
                XCTAssertEqual(canonicalRoots, Set(capture.readinessObservation.requestedRoots))
                XCTAssertTrue(physicalRoots.isEmpty)
                XCTAssertEqual(context.providerWorkspacePath, fixture.workspaceURL.deletingLastPathComponent().path)
                XCTAssertEqual(context.nestedDiscoveryTabContext(runID: UUID()).frozenLookupContext, context.lookupContext)
            }
        }
    }
#endif

#if DEBUG
    /// Invocation-owned checkpoint: observes/holds real filesystem work, never substitutes a result.
    final class BoundWorkspaceProbeTestCheckpoint: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseSignal = DispatchSemaphore(value: 0)
        private var operation: ContextBuilderBoundWorkspaceProbe.Operation?
        private var heldID: UUID?
        private var heldPhase: ContextBuilderBoundWorkspaceProbe.Phase = .beforeFileSystem
        private var workers: [Task<Void, Never>] = []
        private var offMain = false
        private var completed = false
        private var providerDirectoryStarts = 0
        let entered = XCTestExpectation(description: "real bound filesystem worker held")
        let finished = XCTestExpectation(description: "late bound filesystem worker joined")

        @MainActor
        static func withCheckpoint(_ body: (BoundWorkspaceProbeTestCheckpoint) async throws -> Void) async throws {
            let checkpoint = BoundWorkspaceProbeTestCheckpoint()
            do {
                try await body(checkpoint)
                checkpoint.release()
                await checkpoint.joinWorkers()
            } catch {
                checkpoint.release()
                await checkpoint.joinWorkers()
                throw error
            }
        }

        var probe: ContextBuilderBoundWorkspaceProbe {
            ContextBuilderBoundWorkspaceProbe(checkpoint: { [self] event in observe(event) }, workerStarted: { [self] task in
                lock.withLock { workers.append(task) }
            })
        }

        var wasOffMainActor: Bool {
            lock.withLock { offMain }
        }

        var didFinish: Bool {
            lock.withLock { completed }
        }

        var providerDirectoryStartCount: Int {
            lock.withLock { providerDirectoryStarts }
        }

        func arm(_ operation: ContextBuilderBoundWorkspaceProbe.Operation, phase: ContextBuilderBoundWorkspaceProbe.Phase = .beforeFileSystem) {
            lock.withLock { self.operation = operation
                heldPhase = phase
            }
        }

        func release() {
            releaseSignal.signal()
        }

        func joinWorkers() async {
            let pending = lock.withLock { workers }
            for worker in pending {
                await worker.value
            }
        }

        private func observe(_ event: ContextBuilderBoundWorkspaceProbe.Event) {
            let operation = event.operation
            let phase = event.phase
            if operation == .providerDirectory, phase == .beforeFileSystem {
                lock.withLock { providerDirectoryStarts += 1 }
            }
            if phase != .workerFinished {
                let hold = lock.withLock {
                    guard self.operation == operation, heldPhase == phase, heldID == nil else { return false }
                    heldID = event.id
                    offMain = !Thread.isMainThread
                    return true
                }
                guard hold else { return }
                entered.fulfill()
                // RED stays bounded without deliberately freezing MainActor itself.
                if !Thread.isMainThread {
                    XCTAssertEqual(releaseSignal.wait(timeout: .now() + 5), .success, "Fixture must release the owned probe")
                }
            } else if phase == .workerFinished {
                let finish = lock.withLock {
                    guard heldID == event.id, !completed else { return false }
                    completed = true
                    return true
                }
                if finish { finished.fulfill() }
            }
        }
    }
#endif
